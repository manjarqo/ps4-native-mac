// Host test of sem_timedwait (ps4_semaphore.c) through the guest ABI:
//  - a token that is available is taken immediately, even with an invalid timespec;
//  - without a token the wait ends at the absolute CLOCK_REALTIME deadline with -1/ETIMEDOUT
//    (FreeBSD errno 60), neither much too early nor much too late;
//  - a post from another thread wakes the waiter long before the deadline;
//  - argument errors: NULL or destroyed semaphore and tv_nsec outside [0, 1e9) are EINVAL;
//  - NULL abs_timeout waits for the post, a deadline in the past times out at once.
#include "ps4_semaphore.h"

#include <pthread.h>
#include <stdio.h>
#include <string.h>
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
#define SEM_ADDR 0x2000
#define TS_ADDR 0x2100
#define ERRNO_SLOT(ctx) (*(int *)((ctx)->mem_base + (ctx)->fs_base + 0x100))
#define ETIMEDOUT_FREEBSD 60
#define EINVAL_FREEBSD 22

static uint8_t g_mem[MEM_SIZE];

static GuestContext *new_ctx(void) {
  GuestContext *ctx = (GuestContext *)calloc(1, sizeof(GuestContext));
  ctx->mem_base = g_mem;
  ctx->mem_size = MEM_SIZE;
  ctx->fs_base = 0x400;
  return ctx;
}

static double now_s(void) {
  struct timespec t;
  clock_gettime(CLOCK_REALTIME, &t);
  return (double)t.tv_sec + (double)t.tv_nsec * 1e-9;
}

static void set_deadline(uint64_t addr, double abs_s) {
  int64_t *ts = (int64_t *)(g_mem + addr);
  ts[0] = (int64_t)abs_s;
  ts[1] = (int64_t)((abs_s - (double)(int64_t)abs_s) * 1e9);
}

static int64_t call(GuestContext *ctx, void (*shim)(GuestContext *), uint64_t a1, uint64_t a2, uint64_t a3) {
  ctx->rsp = 0x8000;
  ctx->rdi = a1;
  ctx->rsi = a2;
  ctx->rdx = a3;
  ERRNO_SLOT(ctx) = 0;
  shim(ctx);
  CHECK(ctx->rsp == 0x8008, "shim popped its return address");
  return (int64_t)ctx->rax;
}

struct poster {
  uint64_t sem_addr;
  useconds_t delay_us;
};

static void *post_later(void *arg) {
  struct poster *p = (struct poster *)arg;
  usleep(p->delay_us);
  GuestContext *ctx = new_ctx();
  call(ctx, shim_sem_post, p->sem_addr, 0, 0);
  free(ctx);
  return NULL;
}

int main(void) {
  GuestContext *ctx = new_ctx();
  CHECK(call(ctx, shim_sem_init, SEM_ADDR, 0, 0) == 0, "sem_init");

  // Timeout: 200 ms from now, no token.
  double t0 = now_s();
  set_deadline(TS_ADDR, t0 + 0.2);
  int64_t r = call(ctx, shim_sem_timedwait, SEM_ADDR, TS_ADDR, 0);
  double dt = now_s() - t0;
  CHECK(r == -1 && ERRNO_SLOT(ctx) == ETIMEDOUT_FREEBSD, "timeout result %lld errno %d", (long long)r, ERRNO_SLOT(ctx));
  CHECK(dt >= 0.19 && dt < 0.6, "timed out after %.3f s, wanted ~0.2", dt);

  // A deadline in the past with no token times out at once.
  t0 = now_s();
  set_deadline(TS_ADDR, t0 - 5.0);
  r = call(ctx, shim_sem_timedwait, SEM_ADDR, TS_ADDR, 0);
  CHECK(r == -1 && ERRNO_SLOT(ctx) == ETIMEDOUT_FREEBSD && now_s() - t0 < 0.1, "past deadline");

  // A post from another thread wakes the waiter early.
  struct poster po = {SEM_ADDR, 150000};
  pthread_t th;
  pthread_create(&th, NULL, post_later, &po);
  t0 = now_s();
  set_deadline(TS_ADDR, t0 + 10.0);
  r = call(ctx, shim_sem_timedwait, SEM_ADDR, TS_ADDR, 0);
  dt = now_s() - t0;
  pthread_join(th, NULL);
  CHECK(r == 0, "woken wait result %lld errno %d", (long long)r, ERRNO_SLOT(ctx));
  CHECK(dt >= 0.1 && dt < 2.0, "woken after %.3f s, wanted ~0.15", dt);
  // The token was consumed: the next wait times out.
  set_deadline(TS_ADDR, now_s() + 0.05);
  CHECK(call(ctx, shim_sem_timedwait, SEM_ADDR, TS_ADDR, 0) == -1, "token consumed once");

  // NULL timeout: blocks until the post.
  struct poster po2 = {SEM_ADDR, 100000};
  pthread_create(&th, NULL, post_later, &po2);
  t0 = now_s();
  r = call(ctx, shim_sem_timedwait, SEM_ADDR, 0, 0);
  pthread_join(th, NULL);
  CHECK(r == 0 && now_s() - t0 >= 0.08, "NULL timeout waits for the post");

  // An available token wins over a bad timespec; without one the bad timespec is EINVAL.
  int64_t *ts = (int64_t *)(g_mem + TS_ADDR);
  ts[0] = 0;
  ts[1] = 2000000000LL;
  CHECK(call(ctx, shim_sem_post, SEM_ADDR, 0, 0) == 0, "post");
  CHECK(call(ctx, shim_sem_timedwait, SEM_ADDR, TS_ADDR, 0) == 0, "token taken despite bad timespec");
  t0 = now_s();
  CHECK(call(ctx, shim_sem_timedwait, SEM_ADDR, TS_ADDR, 0) == -1 && ERRNO_SLOT(ctx) == EINVAL_FREEBSD, "bad tv_nsec");
  ts[1] = -1;
  CHECK(call(ctx, shim_sem_timedwait, SEM_ADDR, TS_ADDR, 0) == -1 && ERRNO_SLOT(ctx) == EINVAL_FREEBSD && now_s() - t0 < 0.1,
        "negative tv_nsec fails at once");

  // Counting: two posts, two successful waits, the third times out.
  call(ctx, shim_sem_post, SEM_ADDR, 0, 0);
  call(ctx, shim_sem_post, SEM_ADDR, 0, 0);
  set_deadline(TS_ADDR, now_s() + 0.05);
  CHECK(call(ctx, shim_sem_timedwait, SEM_ADDR, TS_ADDR, 0) == 0, "first token");
  CHECK(call(ctx, shim_sem_timedwait, SEM_ADDR, TS_ADDR, 0) == 0, "second token");
  CHECK(call(ctx, shim_sem_timedwait, SEM_ADDR, TS_ADDR, 0) == -1 && ERRNO_SLOT(ctx) == ETIMEDOUT_FREEBSD, "third times out");

  // Bad semaphores.
  CHECK(call(ctx, shim_sem_timedwait, 0, TS_ADDR, 0) == -1 && ERRNO_SLOT(ctx) == EINVAL_FREEBSD, "NULL semaphore");
  *(uint64_t *)(g_mem + 0x3000) = 999; // never initialised
  CHECK(call(ctx, shim_sem_timedwait, 0x3000, TS_ADDR, 0) == -1 && ERRNO_SLOT(ctx) == EINVAL_FREEBSD, "unknown semaphore");
  CHECK(call(ctx, shim_sem_destroy, SEM_ADDR, 0, 0) == 0, "destroy");
  CHECK(call(ctx, shim_sem_timedwait, SEM_ADDR, TS_ADDR, 0) == -1 && ERRNO_SLOT(ctx) == EINVAL_FREEBSD, "destroyed semaphore");

  fflush(stdout);
  if (g_failures) {
    printf("sem_timedwait_test: %d FAILED\n", g_failures);
    return 1;
  }
  printf("sem_timedwait_test: PASS\n");
  return 0;
}
