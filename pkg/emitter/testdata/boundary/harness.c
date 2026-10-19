// Guest-state boundary tests of the ARM64 assembly backend (boundary_test.go builds this with
// the emitted trampoline, the generated shim stubs, guest.s and the runtime sources).
// Usage: harness <case>; prints "PASS <case>" and exits 0, or prints what differs and exits 1.
#include "recomp_runtime.h"
#include "ps4_fiber.h"
#include "ps4_threading.h"
#include "ps4_kernel_sys.h"

#include <stdarg.h>
#include <stdatomic.h>

// Guest data layout (guest.s has the same addresses).
#define D 0x1000000ULL
#define FIBER_A (D + 0x000)
#define FIBER_B (D + 0x100)
#define NAME_A (D + 0x200)
#define NAME_B (D + 0x210)
#define ARGRET1 (D + 0x300)
#define ARGRET2 (D + 0x308)
#define ARGRUN_A (D + 0x310)
#define ARGRUN_A2 (D + 0x318)
#define ARGRUN_B (D + 0x320)
#define ARGRUN_A3 (D + 0x328)
#define STACK_A 0x1100000ULL
#define STACK_B 0x1200000ULL
#define FIBER_STACK_SIZE 0x10000ULL

enum {
  RES_M1, RES_A1, RES_A2, RES_B1, RES_M2, RES_A_ARGS, RES_B_ARGS, RES_A_PRE, RES_B_PRE, RES_M1_PRE, RES_M2_PRE,
  RES_EXC_PRE, RES_EXC, RES_EXC_HANDLER, RES_GPRS_PRE, RES_GPRS,
};
// Result block words (guest.s STORE_REGS).
enum { W_RAX, W_RBX, W_RCX, W_RDX, W_RSI, W_RDI, W_RBP, W_RSP, W_R8, W_R15 = W_R8 + 7, W_FS, W_MEM };

// Guest addresses of the guest functions.
#define ADDR_FIBER_MAIN1 0x400000ULL
#define ADDR_FIBER_MAIN2 0x400100ULL
#define ADDR_FIBER_A 0x400200ULL
#define ADDR_FIBER_B 0x400300ULL
#define ADDR_EXC_MAIN 0x400400ULL
#define ADDR_EXC_HANDLER 0x400500ULL
#define ADDR_GPRS 0x400600ULL
#define ADDR_XMM 0x400700ULL
#define ADDR_XMM_CALLBACK 0x400800ULL
#define RES_XMM_ADDR (D + 0x1000 + 0x1000)

void guest_fiber_main1(void);
void guest_fiber_main2(void);
void guest_fiber_a(void);
void guest_fiber_b(void);
void guest_exc_main(void);
void guest_exc_handler(void);
void guest_gprs(void);
void guest_xmm(void);
void guest_xmm_callback(void);

static GuestContext *g_proc;
static int g_failures;

static uint64_t *gmem64(uint64_t addr) { return (uint64_t *)(g_proc->mem_base + addr); }
static uint64_t *res(int n) { return gmem64(D + 0x1000 + (uint64_t)n * 0x100); }

static void fail(const char *fmt, ...) {
  va_list ap;
  va_start(ap, fmt);
  printf("FAIL: ");
  vprintf(fmt, ap);
  printf("\n");
  va_end(ap);
  g_failures++;
}

static void expect(const char *what, uint64_t got, uint64_t want) {
  if (got != want) fail("%s = 0x%llx, want 0x%llx", what, (unsigned long long)got, (unsigned long long)want);
}

// The registers guest.s SET_PATTERN set (only those a call must preserve are checked) and the
// guest stack pointer, FS base and memory base of block n.
static void check_pattern(const char *name, int n, uint64_t p, uint64_t rsp, uint64_t fs) {
  char what[64];
  const uint64_t *r = res(n);
  snprintf(what, sizeof what, "%s rbx", name);
  expect(what, r[W_RBX], p + 0x01);
  snprintf(what, sizeof what, "%s rbp", name);
  expect(what, r[W_RBP], p + 0x02);
  for (int i = 12; i <= 15; i++) {
    snprintf(what, sizeof what, "%s r%d", name, i);
    expect(what, r[W_R8 + i - 8], p + (uint64_t)i);
  }
  snprintf(what, sizeof what, "%s rsp", name);
  expect(what, r[W_RSP], rsp);
  snprintf(what, sizeof what, "%s FS base (x27)", name);
  expect(what, r[W_FS], fs);
  snprintf(what, sizeof what, "%s memory base (x28)", name);
  expect(what, r[W_MEM], (uint64_t)(uintptr_t)g_proc->mem_base);
}

// Calls a shim from C the way guest code does: return address and a stack argument on the
// guest stack, integer arguments in the System V registers.
static uint64_t call_shim(GuestContext *ctx, void (*shim)(GuestContext *), uint64_t a1, uint64_t a2, uint64_t a3,
                          uint64_t a4, uint64_t a5, uint64_t a6, uint64_t stack7) {
  const uint64_t rsp = ctx->rsp;
  ctx->rsp -= 16;
  *gmem64(ctx->rsp) = 0;
  *gmem64(ctx->rsp + 8) = stack7;
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

// A shim that does nothing: it only makes the bridge store and reload the guest registers.
void shim_test_noop(GuestContext *ctx) { SHIM_RETURN(); }

static uint64_t tcb_slot(const GuestContext *t) { return *gmem64(t->fs_base + 0x70); }

static void *run_fiber_main2(void *arg) {
  GuestContext *t2 = (GuestContext *)arg;
  g_current_ctx = t2;
  recomp_call_guest(t2, ADDR_FIBER_MAIN2);
  return NULL;
}

// sceFiberRun/Switch/ReturnToThread: every context resumes with its own registers, also
// when a fiber resumes on another guest thread (FS base of that thread).
static void test_fiber(void) {
  GuestContext *t1 = g_proc;
  strcpy((char *)g_proc->mem_base + NAME_A, "A");
  strcpy((char *)g_proc->mem_base + NAME_B, "B");
  expect("init A", call_shim(t1, shim_sceFiberInitializeImpl, FIBER_A, NAME_A, ADDR_FIBER_A, 0xa1a1, STACK_A,
                             FIBER_STACK_SIZE, 0), 0);
  expect("init B", call_shim(t1, shim_sceFiberInitializeImpl, FIBER_B, NAME_B, ADDR_FIBER_B, 0xb1b1, STACK_B,
                             FIBER_STACK_SIZE, 0), 0);
  recomp_call_guest(t1, ADDR_FIBER_MAIN1);

  GuestContext *t2 = recomp_create_thread_context(t1, 0x10000);
  pthread_t th;
  pthread_create(&th, NULL, run_fiber_main2, t2);
  pthread_join(th, NULL);

  const uint64_t fs1 = t1->fs_base, fs2 = t2->fs_base;
  expect("A argOnInitialize", res(RES_A_ARGS)[W_RDI], 0xa1a1);
  expect("A argOnRun", res(RES_A_ARGS)[W_RSI], 0x5150);
  expect("B argOnInitialize", res(RES_B_ARGS)[W_RDI], 0xb1b1);
  expect("B argOnRun", res(RES_B_ARGS)[W_RSI], 0x5151);
  check_pattern("A after Switch(B) on thread 1", RES_A1, 0xa000, res(RES_A_PRE)[W_RSP], fs1);
  expect("A argOnRun from B", *gmem64(ARGRUN_A), 0x5353);
  expect("A rax after Switch", res(RES_A1)[W_RAX], 0);
  check_pattern("thread 1 after Run(A)", RES_M1, 0x1100, res(RES_M1_PRE)[W_RSP], fs1);
  expect("thread 1 argOnReturn", *gmem64(ARGRET1), 0x77);
  check_pattern("A after ReturnToThread, resumed on thread 2", RES_A2, 0xa000, res(RES_A_PRE)[W_RSP], fs2);
  expect("A argOnRun from thread 2", *gmem64(ARGRUN_A2), 0x5250);
  check_pattern("B after Switch(A), resumed on thread 2", RES_B1, 0xb000, res(RES_B_PRE)[W_RSP], fs2);
  expect("B argOnRun from A", *gmem64(ARGRUN_B), 0x5252);
  check_pattern("thread 2 after Run(A)", RES_M2, 0x2200, res(RES_M2_PRE)[W_RSP], fs2);
  expect("thread 2 argOnReturn", *gmem64(ARGRET2), 0x88);
  expect("thread 1 TCB slot", tcb_slot(t1), (uint64_t)(uintptr_t)t1);
  expect("thread 2 TCB slot", tcb_slot(t2), (uint64_t)(uintptr_t)t2);
}

// 0: the guest thread has not reached shim_test_wait_signal; 1: it waits in it; 2: released.
static atomic_int g_wait_state;

// Blocks until released, the way a shim blocks in a wait. Host code keeps host values in the
// registers that hold the guest registers in guest code: x8-x15 and x19-x25 hold other values
// while the signal arrives, x26 and x28 hold the guest stack pointer and memory base, as they
// do in any shim that does not reuse them.
void shim_test_wait_signal(GuestContext *ctx) {
  atomic_store(&g_wait_state, 1);
  __asm__ volatile("mov x26, %1\n"
                   "mov x28, %2\n"
                   "mov x8, #0xdead\n mov x9, #0xdead\n mov x10, #0xdead\n mov x11, #0xdead\n"
                   "mov x12, #0xdead\n mov x13, #0xdead\n mov x14, #0xdead\n mov x15, #0xdead\n"
                   "mov x19, #0xdead\n mov x20, #0xdead\n mov x21, #0xdead\n mov x22, #0xdead\n"
                   "mov x23, #0xdead\n mov x24, #0xdead\n mov x25, #0xdead\n"
                   "1: ldar w16, [%0]\n"
                   "cmp w16, #2\n"
                   "b.ne 1b\n"
                   :
                   : "r"(&g_wait_state), "r"(ctx->rsp), "r"(ctx->mem_base)
                   : "x8", "x9", "x10", "x11", "x12", "x13", "x14", "x15", "x16", "x19", "x20", "x21", "x22",
                     "x23", "x24", "x25", "x26", "x28", "cc", "memory");
  ctx->rax = 0;
  SHIM_RETURN();
}

static void *raise_exception_in_wait(void *arg) {
  (void)arg;
  while (atomic_load(&g_wait_state) != 1) usleep(100);
  expect("sceKernelRaiseException", (uint64_t)(int64_t)sceKernelRaiseException(1000, 30), 0);
  volatile uint64_t *signum = &res(RES_EXC_HANDLER)[W_RDI];
  for (int i = 0; i < 20000 && *signum != 30; i++) usleep(100);
  atomic_store(&g_wait_state, 2);
  return NULL;
}

// A guest exception handler (sceKernelRaiseException, SIGUSR1) runs while the thread waits
// in a shim: it sees the guest registers of the interrupted call, and the guest registers the
// shim returns with are unchanged.
static void test_exception(void) {
  GuestContext *t = g_proc;
  expect("sceKernelInstallExceptionHandler", (uint64_t)(int64_t)sceKernelInstallExceptionHandler(30, ADDR_EXC_HANDLER), 0);
  pthread_t th;
  pthread_create(&th, NULL, raise_exception_in_wait, NULL);
  recomp_call_guest(t, ADDR_EXC_MAIN);
  pthread_join(th, NULL);
  expect("handler signum", res(RES_EXC_HANDLER)[W_RDI], 30);
  const uint64_t uc = res(RES_EXC_HANDLER)[W_RSI];
  expect("ucontext r12", *gmem64(uc + 0xa0), 0xe00c);
  expect("ucontext rbx", *gmem64(uc + 0x80), 0xe001);
  expect("ucontext rbp", *gmem64(uc + 0x88), 0xe002);
  check_pattern("after the shim the handler interrupted", RES_EXC, 0xe000, res(RES_EXC_PRE)[W_RSP], t->fs_base);
}

// Sets every GPR but rsp to 0x5100 + its result-block index; rsp gets the usual return.
void shim_test_set_gprs(GuestContext *ctx) {
  uint64_t *gpr[] = {&ctx->rax, &ctx->rbx, &ctx->rcx, &ctx->rdx, &ctx->rsi, &ctx->rdi, &ctx->rbp, NULL,
                     &ctx->r8,  &ctx->r9,  &ctx->r10, &ctx->r11, &ctx->r12, &ctx->r13, &ctx->r14, &ctx->r15};
  for (int i = 0; i < 16; i++)
    if (gpr[i]) *gpr[i] = 0x5100 + (uint64_t)i;
  SHIM_RETURN();
}

// Guest code continues with every GPR a shim wrote to ctx.
static void test_gprs(void) {
  static const char *names[] = {"rax", "rbx", "rcx", "rdx", "rsi", "rdi", "rbp", "rsp",
                                "r8",  "r9",  "r10", "r11", "r12", "r13", "r14", "r15"};
  recomp_call_guest(g_proc, ADDR_GPRS);
  for (int i = 0; i < 16; i++) {
    char what[32];
    snprintf(what, sizeof what, "%s after the shim", names[i]);
    expect(what, res(RES_GPRS)[i], i == W_RSP ? res(RES_GPRS_PRE)[W_RSP] : 0x5100 + (uint64_t)i);
  }
  expect("FS base after the shim", res(RES_GPRS)[W_FS], g_proc->fs_base);
}

static xmm_reg_t g_shim_saw_xmm[8];
static float g_callback_result;

// Records xmm0-7 as the shim sees them, calls a guest callback(float) through ctx->xmm[0] and
// returns the double 2.5 in xmm0.
void shim_test_xmm(GuestContext *ctx) {
  memcpy(g_shim_saw_xmm, ctx->xmm, sizeof g_shim_saw_xmm);
  ctx->xmm[0].f32[0] = 3.0f;
  recomp_call_guest(ctx, ADDR_XMM_CALLBACK);
  g_callback_result = ctx->xmm[0].f32[0];
  memset(&ctx->xmm[0], 0, sizeof ctx->xmm[0]);
  ctx->xmm[0].f64[0] = 2.5;
  SHIM_RETURN();
}

static const uint8_t kXmmByte[8] = {0x01, 0x12, 0x23, 0x34, 0x45, 0x56, 0x67, 0x78};

static void expect_xmm(const char *what, int i, const xmm_reg_t *got, uint8_t byte) {
  for (int b = 0; b < 16; b++) {
    if (got->u8[b] != byte) {
      fail("%s xmm%d byte %d = 0x%02x, want 0x%02x", what, i, b, got->u8[b], byte);
      return;
    }
  }
}

// A shim sees the guest's xmm0-7, a callback gets its float argument and returns its float
// result through ctx, and the guest gets the shim's xmm0 result and its other xmm1-7 back.
static void test_xmm(void) {
  recomp_call_guest(g_proc, ADDR_XMM);
  for (int i = 0; i < 8; i++) expect_xmm("shim argument", i, &g_shim_saw_xmm[i], kXmmByte[i]);
  if (g_callback_result != 6.0f) fail("callback(3.0f) result in ctx->xmm[0] = %g, want 6", g_callback_result);
  const xmm_reg_t *after = (const xmm_reg_t *)(g_proc->mem_base + RES_XMM_ADDR);
  if (after[0].f64[0] != 2.5 || after[0].u64[1] != 0)
    fail("xmm0 after the shim = %g (0x%016llx 0x%016llx), want 2.5", after[0].f64[0],
         (unsigned long long)after[0].u64[0], (unsigned long long)after[0].u64[1]);
  for (int i = 1; i < 8; i++) expect_xmm("after the shim", i, &after[i], kXmmByte[i]);
}

int main(int argc, char **argv) {
  setvbuf(stdout, NULL, _IONBF, 0);
  if (argc < 2) {
    fprintf(stderr, "usage: %s <case>\n", argv[0]);
    return 2;
  }
  g_proc = recomp_init_runtime(256ULL << 20, NULL, 0, "boundary_test");
  if (!g_proc) return 2;
  recomp_init_main_thread(g_proc);
  recomp_register_fn(ADDR_FIBER_MAIN1, (recomp_fn_t)guest_fiber_main1);
  recomp_register_fn(ADDR_FIBER_MAIN2, (recomp_fn_t)guest_fiber_main2);
  recomp_register_fn(ADDR_FIBER_A, (recomp_fn_t)guest_fiber_a);
  recomp_register_fn(ADDR_FIBER_B, (recomp_fn_t)guest_fiber_b);
  recomp_register_fn(ADDR_EXC_MAIN, (recomp_fn_t)guest_exc_main);
  recomp_register_fn(ADDR_EXC_HANDLER, (recomp_fn_t)guest_exc_handler);
  recomp_register_fn(ADDR_GPRS, (recomp_fn_t)guest_gprs);
  recomp_register_fn(ADDR_XMM, (recomp_fn_t)guest_xmm);
  recomp_register_fn(ADDR_XMM_CALLBACK, (recomp_fn_t)guest_xmm_callback);

  const char *c = argv[1];
  if (strcmp(c, "fiber") == 0) {
    test_fiber();
  } else if (strcmp(c, "exception") == 0) {
    test_exception();
  } else if (strcmp(c, "gprs") == 0) {
    test_gprs();
  } else if (strcmp(c, "xmm") == 0) {
    test_xmm();
  } else {
    fprintf(stderr, "unknown case %s\n", c);
    return 2;
  }
  if (g_failures) return 1;
  printf("PASS %s\n", c);
  return 0;
}
