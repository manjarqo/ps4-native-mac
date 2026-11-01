// Host test of the libkernel semaphores (sceKernel*Sema, ps4_semaphore.c):
//  - token hand-off: with max_count 1 and a thread blocked in WaitSema, two SignalSema calls in
//    a row both succeed (the first hands its token to the waiter at once), and the second
//    token stays for the next waiter. Sonic Origins' job pool depends on it: with the token
//    left in the count until the waiter ran, the second signal failed with EINVAL and a worker
//    slept with work queued;
//  - a waiter that needs more tokens than the count holds stays queued while a later one that
//    fits takes them;
//  - a timed-out waiter leaves the queue and its timeout reads 0; a later signal is not lost;
//  - DeleteSema wakes waiters with EACCES, CancelSema with ECANCELED and reports their number;
//  - argument errors: count above max_count, need_count above max_count, unknown id.
#include "ps4_semaphore.h"

#include <pthread.h>
#include <stdio.h>
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

#define EINVAL_K ((int)0x80020016)
#define ESRCH_K ((int)0x80020003)
#define EACCES_K ((int)0x8002000d)
#define EBUSY_K ((int)0x80020010)
#define ETIMEDOUT_K ((int)0x8002003c)
#define ECANCELED_K ((int)0x80020055)

typedef struct Waiter {
  OrbisKernelSema sem;
  int32_t need;
  int has_timeout;
  uint32_t timeout;
  int rc;
  pthread_t th;
} Waiter;

static void *wait_main(void *arg) {
  Waiter *w = (Waiter *)arg;
  w->rc = sceKernelWaitSema(w->sem, w->need, w->has_timeout ? &w->timeout : NULL);
  return NULL;
}

static void start_waiter(Waiter *w, OrbisKernelSema sem, int32_t need) {
  w->sem = sem;
  w->need = need;
  w->rc = 12345;
  pthread_create(&w->th, NULL, wait_main, w);
  usleep(50000); // let it block
}

static void test_handoff(void) {
  OrbisKernelSema s = 0;
  CHECK(sceKernelCreateSema(&s, "handoff", 1, 0, 1, NULL) == 0, "create");
  Waiter w = {0};
  start_waiter(&w, s, 1);
  const int r1 = sceKernelSignalSema(s, 1);
  const int r2 = sceKernelSignalSema(s, 1);
  CHECK(r1 == 0 && r2 == 0, "two signals with a waiter: 0x%x 0x%x", r1, r2);
  pthread_join(w.th, NULL);
  CHECK(w.rc == 0, "waiter 0x%x", w.rc);
  CHECK(sceKernelPollSema(s, 1) == 0, "second token kept");
  CHECK(sceKernelPollSema(s, 1) == EBUSY_K, "no third token");
  CHECK(sceKernelSignalSema(s, 2) == EINVAL_K, "count above max");
  CHECK(sceKernelDeleteSema(s) == 0, "delete");
  CHECK(sceKernelSignalSema(s, 1) == ESRCH_K, "deleted id");
}

static void test_need_count_order(void) {
  OrbisKernelSema s = 0;
  CHECK(sceKernelCreateSema(&s, "need", 1, 0, 4, NULL) == 0, "create");
  CHECK(sceKernelWaitSema(s, 5, NULL) == EINVAL_K, "need above max");
  Waiter big = {0}, small = {0};
  start_waiter(&big, s, 3);
  start_waiter(&small, s, 1);
  CHECK(sceKernelSignalSema(s, 1) == 0, "signal 1");
  pthread_join(small.th, NULL);
  CHECK(small.rc == 0, "small waiter 0x%x", small.rc);
  CHECK(big.rc == 12345, "big waiter still waits");
  CHECK(sceKernelSignalSema(s, 3) == 0, "signal 3");
  pthread_join(big.th, NULL);
  CHECK(big.rc == 0, "big waiter 0x%x", big.rc);
  CHECK(sceKernelPollSema(s, 1) == EBUSY_K, "all tokens taken");
  sceKernelDeleteSema(s);
}

static void test_timeout(void) {
  OrbisKernelSema s = 0;
  CHECK(sceKernelCreateSema(&s, "timeout", 1, 0, 1, NULL) == 0, "create");
  uint32_t t = 0;
  CHECK(sceKernelWaitSema(s, 1, &t) == ETIMEDOUT_K, "zero timeout");
  t = 20000;
  CHECK(sceKernelWaitSema(s, 1, &t) == ETIMEDOUT_K && t == 0, "timeout %u", t);
  CHECK(sceKernelSignalSema(s, 1) == 0, "signal after timeout");
  CHECK(sceKernelPollSema(s, 1) == 0, "token not given to the timed-out waiter");
  Waiter w = {0};
  w.has_timeout = 1;
  w.timeout = 2000000;
  start_waiter(&w, s, 1);
  CHECK(sceKernelSignalSema(s, 1) == 0, "signal");
  pthread_join(w.th, NULL);
  CHECK(w.rc == 0 && w.timeout > 0 && w.timeout < 2000000, "timed waiter 0x%x left %u", w.rc, w.timeout);
  sceKernelDeleteSema(s);
}

static void test_delete_cancel(void) {
  OrbisKernelSema s = 0;
  CHECK(sceKernelCreateSema(&s, "cancel", 1, 0, 2, NULL) == 0, "create");
  Waiter a = {0}, b = {0};
  start_waiter(&a, s, 1);
  start_waiter(&b, s, 2);
  int32_t n = -1;
  CHECK(sceKernelCancelSema(s, 3, &n) == EINVAL_K, "cancel above max");
  CHECK(sceKernelCancelSema(s, 1, &n) == 0 && n == 2, "cancel: %d waiters", n);
  pthread_join(a.th, NULL);
  pthread_join(b.th, NULL);
  CHECK(a.rc == ECANCELED_K && b.rc == ECANCELED_K, "canceled 0x%x 0x%x", a.rc, b.rc);
  CHECK(sceKernelPollSema(s, 1) == 0, "count set by cancel");
  Waiter c = {0};
  start_waiter(&c, s, 1);
  CHECK(sceKernelDeleteSema(s) == 0, "delete");
  pthread_join(c.th, NULL);
  CHECK(c.rc == EACCES_K, "deleted 0x%x", c.rc);
  // Monotonic non-reused ID: the next semaphore gets a strictly higher ID and the old ID stays ESRCH.
  OrbisKernelSema s2 = 0;
  CHECK(sceKernelCreateSema(&s2, "reuse", 1, 1, 1, NULL) == 0 && s2 > s && sceKernelPollSema(s2, 1) == 0, "monotonic id");
  CHECK(sceKernelPollSema(s, 1) == ESRCH_K, "stale deleted id still fails with ESRCH");
  sceKernelDeleteSema(s2);
}

static void test_64bit_wire_abi(void) {
  static uint8_t mem[0x10000];
  GuestContext ctx = {0};
  ctx.mem_base = mem;
  ctx.mem_size = sizeof(mem);
  strcpy((char *)(mem + 0x200), "bb_sema");

  // pOptParam != 0 is checked first and returns EINVAL (0x80020016), even if maxCount <= 0.
  *(uint64_t *)(mem + 0x100) = 0xDEADBEEF12345678ULL;
  ctx.rsp = 0x1000;
  ctx.rdi = 0x100;
  ctx.rsi = 0x200;
  ctx.rdx = 1;
  ctx.rcx = 0;
  ctx.r8 = 0; // maxCount == 0
  ctx.r9 = 0x300; // non-null pOptParam
  shim_sceKernelCreateSema(&ctx);
  CHECK((int)ctx.rax == EINVAL_K && ctx.rsp == 0x1008, "pOptParam != 0 rejected with EINVAL");

  // Invalid maxCount zeroes full 64-bit *pSema and returns EINVAL.
  *(uint64_t *)(mem + 0x100) = 0xDEADBEEF12345678ULL;
  ctx.rsp = 0x1000;
  ctx.rdi = 0x100;
  ctx.rsi = 0x200;
  ctx.rdx = 1;
  ctx.rcx = 0;
  ctx.r8 = 0;
  ctx.r9 = 0;
  shim_sceKernelCreateSema(&ctx);
  CHECK((int)ctx.rax == EINVAL_K && *(uint64_t *)(mem + 0x100) == 0, "invalid create zeroes 64-bit *pSema");

  // Valid create overwrites upper 32 bits of *pSema with 0 (full 64-bit write).
  *(uint64_t *)(mem + 0x100) = 0xDEADBEEF00000000ULL;
  ctx.rsp = 0x1000;
  ctx.rdi = 0x100;
  ctx.rsi = 0x200;
  ctx.rdx = 1;
  ctx.rcx = 1;
  ctx.r8 = 2;
  ctx.r9 = 0;
  shim_sceKernelCreateSema(&ctx);
  uint64_t handle = *(uint64_t *)(mem + 0x100);
  CHECK((int)ctx.rax == 0 && handle > 0 && (handle >> 32) == 0, "64-bit handle written: 0x%llx", (unsigned long long)handle);

  // Corrupted upper 32 bits in rdi must be rejected with ESRCH (0x80020003) across all operations.
  uint64_t corrupted = handle | 0xdead00000000ULL;
  ctx.rsp = 0x1000; ctx.rdi = corrupted; ctx.rsi = 1; ctx.rdx = 0;
  shim_sceKernelWaitSema(&ctx);
  CHECK((int)ctx.rax == ESRCH_K, "WaitSema rejects corrupted upper 32 bits");

  ctx.rsp = 0x1000; ctx.rdi = corrupted; ctx.rsi = 1;
  shim_sceKernelPollSema(&ctx);
  CHECK((int)ctx.rax == ESRCH_K, "PollSema rejects corrupted upper 32 bits");

  ctx.rsp = 0x1000; ctx.rdi = corrupted; ctx.rsi = 1;
  shim_sceKernelSignalSema(&ctx);
  CHECK((int)ctx.rax == ESRCH_K, "SignalSema rejects corrupted upper 32 bits");

  ctx.rsp = 0x1000; ctx.rdi = corrupted; ctx.rsi = 0; ctx.rdx = 0;
  shim_sceKernelCancelSema(&ctx);
  CHECK((int)ctx.rax == ESRCH_K, "CancelSema rejects corrupted upper 32 bits");

  ctx.rsp = 0x1000; ctx.rdi = corrupted;
  shim_sceKernelDeleteSema(&ctx);
  CHECK((int)ctx.rax == ESRCH_K, "DeleteSema rejects corrupted upper 32 bits");

  // Clean 64-bit handle succeeds.
  ctx.rsp = 0x1000; ctx.rdi = handle; ctx.rsi = 1;
  shim_sceKernelPollSema(&ctx);
  CHECK((int)ctx.rax == 0, "PollSema with clean 64-bit handle succeeds");

  ctx.rsp = 0x1000; ctx.rdi = handle;
  shim_sceKernelDeleteSema(&ctx);
  CHECK((int)ctx.rax == 0, "DeleteSema with clean 64-bit handle succeeds");
}

int main(void) {
  test_handoff();
  test_need_count_order();
  test_timeout();
  test_delete_cancel();
  test_64bit_wire_abi();
  if (g_failures) {
    printf("kernel_sema_test: %d failure(s)\n", g_failures);
    return 1;
  }
  printf("kernel_sema_test: PASS\n");
  return 0;
}
