// Host test of ps4_fiber_endpoint_host_thread against the fiber runtime (ps4_fiber.c): the
// lookup runs in signal handlers (guest exception delivery, sceKernelRaiseException) while
// guest threads that ran fibers exit (their FiberWorker is freed) and fibers are finalized
// (their FiberHost and GuestContext are freed). Reader threads send themselves SIGUSR1 in a
// loop and the handler scans the worker table; worker threads meanwhile create, run and
// finalize fibers and exit. Built with AddressSanitizer, a lookup that reads a freed worker
// or fiber is reported. Afterwards (more thread lifetimes than the table has slots) a new
// thread that runs a fiber must still be found by the lookup.
// Usage: fiber_lookup_test [seconds]; PS4_FIBER_THREADS=1 selects fiber thread mode.
#include "ps4_fiber.h"
#include "ps4_threading.h"

#include <signal.h>
#include <stdatomic.h>

// What ps4_fiber.c needs from the rest of the runtime.
_Thread_local GuestContext *g_current_ctx;
recomp_fn_t **g_dispatch_l1[DISPATCH_LEVEL_SIZE];
RecompThread *recomp_get_current_thread(void) { return NULL; }
void recomp_set_current_thread(RecompThread *t) { (void)t; }

#define MEM_SIZE (64ULL << 20)
#define FIBER_ENTRY 0x10000ULL
#define WORKER_REGION 0x100000ULL // per concurrent worker: 1 MB of guest memory
#define CONCURRENT 16
#define FIBERS 6
#define CTX_SIZE 0x4000ULL
#define READERS 4
#define TOTAL_THREADS 3000 // more than the 1024 table slots

static uint8_t *g_mem;
static _Atomic int g_stop;
static _Atomic long g_lookups, g_signals;
static _Atomic int g_failures;

static void fail(const char *what, long a, long b) {
  printf("FAIL: %s (%ld, %ld)\n", what, a, b);
  atomic_fetch_add(&g_failures, 1);
}

// Guest entry of every fiber: return to the thread, forever (sceFiberReturnToThread(0, NULL)).
static void fiber_body(GuestContext *ctx) {
  for (;;) {
    ctx->rdi = 0;
    ctx->rsi = 0;
    ctx->rsp -= 8; // the return address the shim pops
    shim_sceFiberReturnToThread(ctx);
  }
}

static void register_entry(void) {
  static recomp_fn_t l3[DISPATCH_LEVEL_SIZE];
  static recomp_fn_t *l2[DISPATCH_LEVEL_SIZE];
  l3[FIBER_ENTRY & DISPATCH_LEVEL_MASK] = (recomp_fn_t)fiber_body;
  l2[(FIBER_ENTRY >> DISPATCH_L2_SHIFT) & DISPATCH_LEVEL_MASK] = l3;
  g_dispatch_l1[(FIBER_ENTRY >> DISPATCH_L1_SHIFT) & DISPATCH_LEVEL_MASK] = l2;
}

// Calls a fiber shim with System V arguments; the shim pops a return address from rsp.
static uint64_t call_shim(GuestContext *ctx, void (*shim)(GuestContext *), uint64_t a1, uint64_t a2, uint64_t a3,
                          uint64_t a4, uint64_t a5, uint64_t a6) {
  const uint64_t rsp = ctx->rsp;
  ctx->rsp -= 16;
  memset(ctx->mem_base + ctx->rsp, 0, 16); // return address, 7th argument (opt param) NULL
  ctx->rdi = a1;
  ctx->rsi = a2;
  ctx->rdx = a3;
  ctx->rcx = a4;
  ctx->r8 = a5;
  ctx->r9 = a6;
  shim(ctx);
  ctx->rsp = rsp;
  return ctx->rax;
}

static GuestContext *new_thread_ctx(uint64_t region) {
  GuestContext *ctx = (GuestContext *)calloc(1, sizeof(GuestContext));
  ctx->mem_base = g_mem;
  ctx->mem_size = MEM_SIZE;
  ctx->rsp = region + WORKER_REGION - 0x100; // guest stack at the top of the region
  return ctx;
}

// One guest thread: runs fibers (which creates its FiberWorker), finalizes them, exits.
static void run_fibers(GuestContext *ctx, uint64_t region, int rounds) {
  const uint64_t name = region;
  strcpy((char *)g_mem + name, "f");
  for (int r = 0; r < rounds; r++) {
    for (int i = 0; i < FIBERS; i++) {
      const uint64_t f = region + 0x100 + (uint64_t)i * 0x100;
      const uint64_t c = region + 0x1000 + (uint64_t)i * CTX_SIZE;
      if (call_shim(ctx, shim_sceFiberInitializeImpl, f, name, FIBER_ENTRY, 0, c, CTX_SIZE) != 0)
        fail("sceFiberInitialize", i, 0);
    }
    for (int k = 0; k < 2; k++)
      for (int i = 0; i < FIBERS; i++)
        if (call_shim(ctx, shim_sceFiberRun, region + 0x100 + (uint64_t)i * 0x100, 0, 0, 0, 0, 0) != 0)
          fail("sceFiberRun", i, k);
    for (int i = 0; i < FIBERS; i++)
      if (call_shim(ctx, shim_sceFiberFinalize, region + 0x100 + (uint64_t)i * 0x100, 0, 0, 0, 0, 0) != 0)
        fail("sceFiberFinalize", i, 0);
  }
}

static _Atomic int g_region_busy[CONCURRENT];

static void *worker_main(void *arg) {
  const int slot = (int)(intptr_t)arg;
  const uint64_t region = WORKER_REGION * (uint64_t)(slot + 1);
  GuestContext *ctx = new_thread_ctx(region);
  run_fibers(ctx, region, 2);
  free(ctx); // the worker keeps the pointer only to compare it
  atomic_store(&g_region_busy[slot], 0);
  return NULL;
}

// Lookups of a context no worker has: every one scans the whole table and reads each worker's
// current fiber.
static GuestContext g_probe;

static void on_sigusr1(int sig) {
  (void)sig;
  pthread_t t;
  for (int i = 0; i < 32; i++) {
    if (ps4_fiber_endpoint_host_thread(&g_probe, &t)) atomic_fetch_add(&g_failures, 1);
    atomic_fetch_add_explicit(&g_lookups, 1, memory_order_relaxed);
  }
}

static void *reader_main(void *arg) {
  (void)arg;
  while (!atomic_load(&g_stop)) {
    pthread_kill(pthread_self(), SIGUSR1);
    atomic_fetch_add_explicit(&g_signals, 1, memory_order_relaxed);
  }
  return NULL;
}

int main(int argc, char **argv) {
  setvbuf(stdout, NULL, _IONBF, 0);
  const int seconds = argc > 1 ? atoi(argv[1]) : 20;
  g_mem = (uint8_t *)calloc(1, MEM_SIZE);
  register_entry();
  struct sigaction sa;
  memset(&sa, 0, sizeof sa);
  sa.sa_handler = on_sigusr1;
  sa.sa_flags = SA_RESTART;
  sigemptyset(&sa.sa_mask);
  sigaction(SIGUSR1, &sa, NULL);

  pthread_t readers[READERS];
  for (int i = 0; i < READERS; i++) pthread_create(&readers[i], NULL, reader_main, NULL);
  const time_t until = time(NULL) + seconds;
  int started = 0;
  while (started < TOTAL_THREADS && time(NULL) < until) {
    for (int s = 0; s < CONCURRENT && started < TOTAL_THREADS; s++) {
      int idle = 0;
      if (!atomic_compare_exchange_strong(&g_region_busy[s], &idle, 1)) continue;
      pthread_t th;
      pthread_attr_t attr;
      pthread_attr_init(&attr);
      pthread_attr_setdetachstate(&attr, PTHREAD_CREATE_DETACHED);
      if (pthread_create(&th, &attr, worker_main, (void *)(intptr_t)s) != 0) {
        fail("pthread_create", started, 0);
        atomic_store(&g_region_busy[s], 0);
      } else {
        started++;
      }
      pthread_attr_destroy(&attr);
    }
    usleep(200);
  }
  for (int s = 0; s < CONCURRENT; s++)
    while (atomic_load(&g_region_busy[s])) usleep(1000);
  atomic_store(&g_stop, 1);
  for (int i = 0; i < READERS; i++) pthread_join(readers[i], NULL);
  if (started < TOTAL_THREADS) fail("worker threads started in time", started, TOTAL_THREADS);

  // After more thread lifetimes than table slots, a thread that runs fibers is still found
  // (freed slots are reused), here while the main thread runs a fiber.
  const uint64_t region = WORKER_REGION * (CONCURRENT + 1);
  GuestContext *ctx = new_thread_ctx(region);
  run_fibers(ctx, region, 1);
  pthread_t t;
  if (!ps4_fiber_endpoint_host_thread(ctx, &t))
    fail("lookup of a thread that ran fibers after many thread exits", 0, 0);
  else if (!ps4_fiber_threads_mode() && !pthread_equal(t, pthread_self()))
    fail("lookup result is the thread's host thread", 0, 0);

  printf("fiber_lookup_test (%s): %d worker threads, %ld signals, %ld lookups\n",
         ps4_fiber_threads_mode() ? "fiber threads" : "coroutines", started, atomic_load(&g_signals),
         atomic_load(&g_lookups));
  if (atomic_load(&g_failures)) return 1;
  printf("fiber_lookup_test: PASS\n");
  return 0;
}
