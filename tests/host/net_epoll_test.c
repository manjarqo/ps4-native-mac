// Host test of sceNetEpoll{Create,Control,Wait,Abort,Destroy} over real sockets. Guest socket
// ids are host descriptors, so a socketpair and a localhost listener stand in for the game's
// sockets. Everything is called through the guest ABI (registers in, rax out, errno in guest
// memory) as the recompiled game calls it.
#include "ps4_net.h"

#include <arpa/inet.h>
#include <netinet/in.h>
#include <fcntl.h>
#include <pthread.h>
#include <signal.h>
#include <stdio.h>
#include <string.h>
#include <sys/socket.h>
#include <time.h>
#include <unistd.h>

static int g_failures;
#define CHECK(cond, ...)                                                       \
  do {                                                                         \
    if (!(cond)) {                                                             \
      printf("FAIL line %d: %s  ", __LINE__, #cond);                           \
      printf(__VA_ARGS__);                                                     \
      printf("\n");                                                            \
      g_failures++;                                                            \
    }                                                                          \
  } while (0)

#define MEM_SIZE 0x10000
#define FS_BASE 0x200
#define EV_ADDR 0x1000
#define NAME_ADDR 0x800
static uint8_t g_mem[MEM_SIZE];

enum { CTL_ADD = 1, CTL_MOD = 2, CTL_DEL = 3 };
enum { IN = 1, OUT = 2, ERR = 8, HUP = 0x10 };
enum { E_PERM = 1, E_INTR = 4, E_BADF = 9, E_NOTBLK = 15, E_EXIST = 17, E_INVAL = 22, E_NAMETOOLONG = 63 };

typedef struct {
  uint32_t events;
  uint32_t reserved;
  uint64_t ident;
  uint64_t data;
} Ev;

static void ctx_init(GuestContext *c) {
  memset(c, 0, sizeof *c);
  c->mem_base = g_mem;
  c->fs_base = FS_BASE;
}

static int32_t sys(GuestContext *c, void (*shim)(GuestContext *), uint64_t a1, uint64_t a2, uint64_t a3, uint64_t a4) {
  c->rsp = 0x1000;
  c->rdi = a1;
  c->rsi = a2;
  c->rdx = a3;
  c->rcx = a4;
  shim(c);
  CHECK(c->rsp == 0x1008, "shim did not pop its return address");
  return (int32_t)c->rax;
}

static int guest_errno(void) { return *(int *)(g_mem + FS_BASE + 0x100); }

static GuestContext g_c;

// A descriptor number that was open and is closed now (never a hard-coded number).
static int closed_fd(void) {
  int sp[2];
  socketpair(AF_UNIX, SOCK_STREAM, 0, sp);
  close(sp[0]);
  close(sp[1]);
  return sp[1];
}

static Ev *evs(void) { return (Ev *)(g_mem + EV_ADDR); }
static int32_t ctl(int ep, int op, int fd, uint32_t events, uint64_t data) {
  Ev *e = (Ev *)(g_mem + 0x900);
  e->events = events;
  e->reserved = 0;
  e->ident = 0;
  e->data = data;
  return sys(&g_c, shim_sceNetEpollControl, (uint64_t)ep, (uint64_t)op, (uint64_t)fd, op == CTL_DEL ? 0 : 0x900);
}
static int32_t wait_us(int ep, int max, int32_t us) {
  return sys(&g_c, shim_sceNetEpollWait, (uint64_t)ep, EV_ADDR, (uint64_t)max, (uint64_t)(uint32_t)us);
}
static uint64_t now_us(void) {
  struct timespec t;
  clock_gettime(CLOCK_MONOTONIC, &t);
  return (uint64_t)t.tv_sec * 1000000 + (uint64_t)t.tv_nsec / 1000;
}

static void test_basic(void) {
  strcpy((char *)g_mem + NAME_ADDR, "test");
  int ep = sys(&g_c, shim_sceNetEpollCreate, NAME_ADDR, 0, 0, 0);
  CHECK(ep >= 0, "create returned %d", ep);
  int sp[2];
  CHECK(socketpair(AF_UNIX, SOCK_STREAM, 0, sp) == 0, "socketpair");

  CHECK(ctl(ep, CTL_ADD, sp[0], IN, 0xAABBCCDD11223344ULL) == 0, "add errno=%d", guest_errno());
  CHECK(ctl(ep, CTL_ADD, sp[0], IN, 0xAABBCCDD11223344ULL) == -1 && guest_errno() == E_EXIST, "second add is EEXIST, errno=%d", guest_errno());

  // Nothing written: timeout 0 returns 0 events; a short timeout waits about that long.
  CHECK(wait_us(ep, 8, 0) == 0, "timeout 0 on an idle socket");
  uint64_t t0 = now_us();
  CHECK(wait_us(ep, 8, 50000) == 0, "timeout 50 ms on an idle socket");
  uint64_t dt = now_us() - t0;
  CHECK(dt >= 45000 && dt < 1000000, "50 ms timeout took %llu us", (unsigned long long)dt);

  // A write on the peer makes the registered socket readable; the layout is the console's.
  CHECK(write(sp[1], "x", 1) == 1, "write");
  memset(g_mem + EV_ADDR, 0xEE, sizeof(Ev) * 2);
  CHECK(wait_us(ep, 8, 0) == 1, "readable after write");
  CHECK(evs()[0].events == IN, "events=%x", evs()[0].events);
  CHECK(evs()[0].reserved == 0, "reserved=%x", evs()[0].reserved);
  CHECK(evs()[0].ident == (uint64_t)sp[0], "ident=%llu", (unsigned long long)evs()[0].ident);
  CHECK(evs()[0].data == 0xAABBCCDD11223344ULL, "user data round trip %llx", (unsigned long long)evs()[0].data);
  CHECK(((uint8_t *)evs())[sizeof(Ev)] == 0xEE, "wrote past event 0");

  // MOD to OUT: a drained socket is writable, no longer reported readable, new data word.
  char c;
  CHECK(read(sp[0], &c, 1) == 1, "drain");
  CHECK(write(sp[1], "y", 1) == 1, "write again");
  CHECK(ctl(ep, CTL_MOD, sp[0], OUT, 77) == 0, "mod errno=%d", guest_errno());
  CHECK(wait_us(ep, 8, 0) == 1, "writable");
  CHECK(evs()[0].events == OUT && evs()[0].data == 77, "events=%x data=%llu", evs()[0].events, (unsigned long long)evs()[0].data);

  // IN|OUT on one descriptor is one merged event.
  CHECK(ctl(ep, CTL_MOD, sp[0], IN | OUT | ERR | HUP, 5) == 0, "mod both");
  CHECK(wait_us(ep, 8, 0) == 1, "merged into one event");
  CHECK(evs()[0].events == (IN | OUT), "merged events=%x", evs()[0].events);
  // maxevents 1 still reports the descriptor once.
  CHECK(wait_us(ep, 1, 0) == 1, "maxevents 1");

  // DEL stops reports; a second DEL is EBADF; MOD of an unregistered descriptor registers it.
  CHECK(ctl(ep, CTL_DEL, sp[0], 0, 0) == 0, "del");
  CHECK(wait_us(ep, 8, 0) == 0, "no events after del");
  CHECK(ctl(ep, CTL_DEL, sp[0], 0, 0) == -1 && guest_errno() == E_BADF, "del twice, errno=%d", guest_errno());
  CHECK(ctl(ep, CTL_MOD, sp[0], IN, 9) == 0, "mod of an unregistered fd adds it");
  CHECK(wait_us(ep, 8, 0) == 1 && evs()[0].data == 9, "re-registered by mod");

  // Peer closed: the socket is readable (read returns 0) and keeps being reported.
  close(sp[1]);
  CHECK(wait_us(ep, 8, 0) == 1 && evs()[0].events == (IN | HUP), "readable and hung up on peer close, events=%x", evs()[0].events);

  close(sp[0]);
  CHECK(sys(&g_c, shim_sceNetEpollDestroy, (uint64_t)ep, 0, 0, 0) == 0, "destroy");
  CHECK(wait_us(ep, 8, 0) == -1 && guest_errno() == E_BADF, "wait on destroyed epoll, errno=%d", guest_errno());
}

static void test_listener(void) {
  // inFAMOUS: a listening socket with no client, polled every frame.
  int ep = sys(&g_c, shim_sceNetEpollCreate, 0, 0, 0, 0);
  int ls = socket(AF_INET, SOCK_STREAM, 0);
  struct sockaddr_in a = {0};
  a.sin_family = AF_INET;
  a.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
  CHECK(bind(ls, (struct sockaddr *)&a, sizeof a) == 0, "bind");
  CHECK(listen(ls, 4) == 0, "listen");
  socklen_t l = sizeof a;
  CHECK(getsockname(ls, (struct sockaddr *)&a, &l) == 0, "getsockname");
  CHECK(ctl(ep, CTL_ADD, ls, IN, 3) == 0, "add listener");
  CHECK(wait_us(ep, 4, 0) == 0, "no client, no event");
  int cs = socket(AF_INET, SOCK_STREAM, 0);
  CHECK(connect(cs, (struct sockaddr *)&a, sizeof a) == 0, "connect");
  CHECK(wait_us(ep, 4, 1000000) == 1 && evs()[0].events == IN && evs()[0].ident == (uint64_t)ls, "client pending");
  close(cs);
  close(ls);
  sys(&g_c, shim_sceNetEpollDestroy, (uint64_t)ep, 0, 0, 0);
}

static void test_error_events(void) {
  int ep = sys(&g_c, shim_sceNetEpollCreate, 0, 0, 0, 0);
  // A refused non-blocking connect to a closed localhost port reports ERR (and HUP).
  int ls = socket(AF_INET, SOCK_STREAM, 0);
  struct sockaddr_in a = {0};
  a.sin_len = sizeof a;
  a.sin_family = AF_INET;
  a.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
  CHECK(bind(ls, (struct sockaddr *)&a, sizeof a) == 0, "bind");
  socklen_t l = sizeof a;
  getsockname(ls, (struct sockaddr *)&a, &l);
  close(ls); // nobody listens on that port now
  int cs = socket(AF_INET, SOCK_STREAM, 0);
  fcntl(cs, F_SETFL, O_NONBLOCK);
  connect(cs, (struct sockaddr *)&a, sizeof a);
  CHECK(ctl(ep, CTL_ADD, cs, IN | OUT, 4) == 0, "add connecting socket");
  CHECK(wait_us(ep, 4, 1000000) == 1, "refused connect is reported");
  CHECK((evs()[0].events & ERR) && (evs()[0].events & HUP), "refused connect events=%x", evs()[0].events);
  CHECK(ctl(ep, CTL_DEL, cs, 0, 0) == 0, "del");
  close(cs);

  // Only ERR|HUP asked: accepted, plain data is not reported, the peer closing is, DEL works.
  int sp[2];
  CHECK(socketpair(AF_UNIX, SOCK_STREAM, 0, sp) == 0, "socketpair");
  CHECK(ctl(ep, CTL_ADD, sp[0], ERR | HUP, 6) == 0, "add with ERR|HUP only, errno=%d", guest_errno());
  CHECK(ctl(ep, CTL_ADD, sp[0], ERR | HUP, 6) == -1 && guest_errno() == E_EXIST, "registered, so a second add is EEXIST");
  CHECK(write(sp[1], "x", 1) == 1, "write");
  CHECK(wait_us(ep, 4, 0) == 0, "data readiness is not reported to an ERR|HUP registration");
  close(sp[1]);
  CHECK(wait_us(ep, 4, 0) == 1 && evs()[0].events == HUP && evs()[0].data == 6, "hangup reported, events=%x", evs()[0].events);
  CHECK(ctl(ep, CTL_DEL, sp[0], 0, 0) == 0, "del of an ERR|HUP registration");
  CHECK(wait_us(ep, 4, 0) == 0, "nothing after del");
  close(sp[0]);
  sys(&g_c, shim_sceNetEpollDestroy, (uint64_t)ep, 0, 0, 0);
}

static void test_errors(void) {
  int ep = sys(&g_c, shim_sceNetEpollCreate, 0, 0, 0, 0);
  int sp[2];
  CHECK(socketpair(AF_UNIX, SOCK_STREAM, 0, sp) == 0, "socketpair");
  int bad = closed_fd();
  CHECK(ctl(bad, CTL_ADD, sp[0], IN, 0) == -1 && guest_errno() == E_BADF, "control on a bad epfd, errno=%d", guest_errno());
  CHECK(ctl(sp[1], CTL_ADD, sp[0], IN, 0) == -1 && guest_errno() == E_BADF, "control on a socket as epfd, errno=%d", guest_errno());
  CHECK(wait_us(bad, 4, 0) == -1 && guest_errno() == E_BADF, "wait on a bad epfd, errno=%d", guest_errno());
  CHECK(wait_us(sp[1], 4, 0) == -1 && guest_errno() == E_BADF, "wait on a socket as epfd");
  CHECK(sys(&g_c, shim_sceNetEpollDestroy, (uint64_t)bad, 0, 0, 0) == -1 && guest_errno() == E_BADF, "destroy bad");
  CHECK(sys(&g_c, shim_sceNetEpollDestroy, (uint64_t)sp[1], 0, 0, 0) == -1 && guest_errno() == E_PERM, "destroy a socket: EPERM");
  CHECK(ctl(ep, CTL_ADD, closed_fd(), IN, 0) == -1 && guest_errno() == E_BADF, "bad target fd");
  int ep2 = sys(&g_c, shim_sceNetEpollCreate, 0, 0, 0, 0);
  CHECK(ctl(ep, CTL_ADD, ep2, IN, 0) == -1 && guest_errno() == E_PERM, "epoll as target: EPERM, errno=%d", guest_errno());
  CHECK(ctl(ep, 7, sp[0], IN, 0) == -1 && guest_errno() == E_INVAL, "bad op");
  CHECK(ctl(ep, CTL_ADD, sp[0], 0, 0) == -1 && guest_errno() == E_INVAL, "no event bits");
  CHECK(sys(&g_c, shim_sceNetEpollControl, (uint64_t)ep, CTL_ADD, (uint64_t)sp[0], 0) == -1 && guest_errno() == E_INVAL, "ADD without event");
  CHECK(wait_us(ep, 0, 0) == -1 && guest_errno() == E_INVAL, "maxevents 0");
  CHECK(sys(&g_c, shim_sceNetEpollWait, (uint64_t)ep, 0, 4, 0) == -1 && guest_errno() == E_INVAL, "no event buffer");
  CHECK(sys(&g_c, shim_sceNetEpollCreate, 0, 1, 0, 0) == -1 && guest_errno() == E_INVAL, "create flags");
  memset(g_mem + NAME_ADDR, 'n', 40);
  g_mem[NAME_ADDR + 40] = 0;
  CHECK(sys(&g_c, shim_sceNetEpollCreate, NAME_ADDR, 0, 0, 0) == -1 && guest_errno() == E_NAMETOOLONG, "long name");
  CHECK(sys(&g_c, shim_sceNetEpollAbort, (uint64_t)bad, 0, 0, 0) == -1 && guest_errno() == E_BADF, "abort bad epfd");
  CHECK(sys(&g_c, shim_sceNetEpollAbort, (uint64_t)ep, 2, 0, 0) == -1 && guest_errno() == E_INVAL, "abort bad flags");
  CHECK(sys(&g_c, shim_sceNetEpollAbort, (uint64_t)ep, 0, 0, 0) == -1 && guest_errno() == E_NOTBLK, "abort with nobody waiting, errno=%d", guest_errno());
  // Preserve: the abort waits for the next wait, once.
  CHECK(sys(&g_c, shim_sceNetEpollAbort, (uint64_t)ep, 1, 0, 0) == 0, "preserved abort");
  CHECK(wait_us(ep, 4, 0) == -1 && guest_errno() == E_INTR, "next wait is aborted, errno=%d", guest_errno());
  CHECK(wait_us(ep, 4, 0) == 0, "the abort was consumed");
  close(sp[0]);
  close(sp[1]);
  sys(&g_c, shim_sceNetEpollDestroy, (uint64_t)ep, 0, 0, 0);
  sys(&g_c, shim_sceNetEpollDestroy, (uint64_t)ep2, 0, 0, 0);
}

typedef struct {
  int ep;
  int32_t ret;
  int err;
  uint64_t took_us;
} WaitArgs;

static void *waiter(void *p) {
  WaitArgs *w = p;
  GuestContext c;
  ctx_init(&c);
  uint64_t t0 = now_us();
  w->ret = sys(&c, shim_sceNetEpollWait, (uint64_t)w->ep, EV_ADDR + 0x400, 4, (uint64_t)(uint32_t)-1);
  w->took_us = now_us() - t0;
  w->err = guest_errno();
  return NULL;
}

static void on_usr1(int sig) { (void)sig; }

static void *waiter_with_timeout(void *p) {
  WaitArgs *w = p;
  GuestContext c;
  ctx_init(&c);
  uint64_t t0 = now_us();
  w->ret = sys(&c, shim_sceNetEpollWait, (uint64_t)w->ep, EV_ADDR + 0x400, 4, 300000);
  w->took_us = now_us() - t0;
  w->err = guest_errno();
  return NULL;
}

// A host signal during the wait does not end it: it goes on for the time left.
static void test_signal_retry(void) {
  struct sigaction sa;
  memset(&sa, 0, sizeof sa);
  sa.sa_handler = on_usr1;
  sigaction(SIGUSR1, &sa, NULL); // no SA_RESTART
  int ep = sys(&g_c, shim_sceNetEpollCreate, 0, 0, 0, 0);
  WaitArgs w = {ep, 12345, 0, 0};
  pthread_t th;
  pthread_create(&th, NULL, waiter_with_timeout, &w);
  usleep(80000);
  pthread_kill(th, SIGUSR1);
  usleep(50000);
  pthread_kill(th, SIGUSR1);
  pthread_join(th, NULL);
  CHECK(w.ret == 0, "wait interrupted by a signal returned %d errno %d", w.ret, w.err);
  CHECK(w.took_us >= 280000, "wait ended after %llu us instead of 300 ms", (unsigned long long)w.took_us);
  sys(&g_c, shim_sceNetEpollDestroy, (uint64_t)ep, 0, 0, 0);
}

static void test_abort_wakes_all(void) {
  int ep = sys(&g_c, shim_sceNetEpollCreate, 0, 0, 0, 0);
  WaitArgs w[3];
  pthread_t th[3];
  for (int i = 0; i < 3; i++) {
    w[i] = (WaitArgs){ep, 12345, 0, 0};
    pthread_create(&th[i], NULL, waiter, &w[i]);
  }
  usleep(300000);
  CHECK(sys(&g_c, shim_sceNetEpollAbort, (uint64_t)ep, 0, 0, 0) == 0, "abort");
  for (int i = 0; i < 3; i++) {
    pthread_join(th[i], NULL);
    CHECK(w[i].ret == -1 && w[i].err == E_INTR, "waiter %d returned %d errno %d", i, w[i].ret, w[i].err);
  }
  CHECK(wait_us(ep, 4, 0) == 0, "all aborts consumed, the next wait is normal");
  // Destroy wakes all of them too.
  for (int i = 0; i < 3; i++) {
    w[i] = (WaitArgs){ep, 12345, 0, 0};
    pthread_create(&th[i], NULL, waiter, &w[i]);
  }
  usleep(300000);
  CHECK(sys(&g_c, shim_sceNetEpollDestroy, (uint64_t)ep, 0, 0, 0) == 0, "destroy");
  for (int i = 0; i < 3; i++) {
    pthread_join(th[i], NULL);
    CHECK(w[i].ret == -1, "waiter %d woken by destroy returned %d", i, w[i].ret);
  }
}

static void test_abort_wakes_waiter(void) {
  int ep = sys(&g_c, shim_sceNetEpollCreate, 0, 0, 0, 0);
  int sp[2];
  CHECK(socketpair(AF_UNIX, SOCK_STREAM, 0, sp) == 0, "socketpair");
  CHECK(ctl(ep, CTL_ADD, sp[0], IN, 1) == 0, "add");
  WaitArgs w = {ep, 12345, 0, 0};
  pthread_t th;
  pthread_create(&th, NULL, waiter, &w);
  // Abort without the preserve flag succeeds only once a thread is blocked in the wait.
  int rc = -1;
  for (int i = 0; i < 500 && rc != 0; i++) {
    usleep(10000);
    rc = sys(&g_c, shim_sceNetEpollAbort, (uint64_t)ep, 0, 0, 0);
  }
  CHECK(rc == 0, "abort never saw the waiter");
  pthread_join(th, NULL);
  CHECK(w.ret == -1 && w.err == E_INTR, "aborted wait returned %d errno %d", w.ret, w.err);
  CHECK(w.took_us < 4000000, "the infinite wait ended in %llu us", (unsigned long long)w.took_us);

  // Destroy also wakes a waiter.
  WaitArgs w2 = {ep, 12345, 0, 0};
  pthread_create(&th, NULL, waiter, &w2);
  usleep(200000);
  CHECK(sys(&g_c, shim_sceNetEpollDestroy, (uint64_t)ep, 0, 0, 0) == 0, "destroy");
  pthread_join(th, NULL);
  CHECK(w2.ret == -1, "wait woken by destroy returned %d", w2.ret);
  close(sp[0]);
  close(sp[1]);
}

int main(void) {
  ctx_init(&g_c);
  test_basic();
  test_listener();
  test_error_events();
  test_errors();
  test_signal_retry();
  test_abort_wakes_all();
  test_abort_wakes_waiter();
  if (g_failures) {
    printf("net_epoll_test: %d FAILURES\n", g_failures);
    return 1;
  }
  printf("net_epoll_test: PASS\n");
  return 0;
}
