// Host test: the static TLS area holds a block per TLS module (the executable and every linked
// PRX), laid out as FreeBSD's rtld does (variant II, elfloader.LayoutStaticTLS), and
// __tls_get_addr({module, offset}) reaches the module's own block, in the main thread and in a
// new thread. The layout is inFAMOUS Second Son's: the eboot (memsz 0x30, its .tdata starts with
// 0xffffffff), libSceFios2 (0x40 bytes of .tbss: a "thread default op attr set" flag at offset 0,
// the attr at 8) and libc (0x490 bytes, 0x1a0 of .tdata). Fios must read its flag as 0 and libc
// must see its own .tdata; neither may land in the eboot's block or the TCB.
#define RUNTIME_STUBS_HAVE_THREADING
#include "runtime_stubs.h"
#include "ps4_threading.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>

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

#define MEM_SIZE (8ULL << 30)
#define VM_START 0x10000000ULL
#define VM_SIZE 0x70000000ULL
#define EBOOT_TDATA 0x100000ULL
#define LIBC_TDATA 0x200000ULL
#define TLS_INDEX 0x300000ULL // guest tls_index {module, offset}
#define MAIN_TCB 0x400000ULL

// Direct memory is not exercised here; recomp_runtime.c only needs the symbols to link.
void ps4_direct_mem_destroy(void) {}
void ps4_direct_mem_configure(GuestContext *ctx, uint64_t proc_param_addr) {
  (void)ctx;
  (void)proc_param_addr;
}
void ps4_direct_mem_on_unmap(GuestContext *ctx, uint64_t addr, size_t size) {
  (void)ctx; (void)addr; (void)size;
}

static GuestContext *new_process(void) {
  GuestContext *ctx = (GuestContext *)calloc(1, sizeof(GuestContext));
  void *mem = mmap(NULL, MEM_SIZE, PROT_READ | PROT_WRITE, MAP_ANON | MAP_PRIVATE | MAP_NORESERVE, -1, 0);
  if (mem == MAP_FAILED) exit(2);
  ctx->mem_base = (uint8_t *)mem;
  ctx->mem_size = MEM_SIZE;
  ctx->process_ctx = ctx;
  ctx->fs_base = MAIN_TCB;
  pthread_mutex_init(&ctx->vm_mutex, NULL);
  GuestVMExtent *root = (GuestVMExtent *)calloc(1, sizeof(GuestVMExtent));
  root->addr = VM_START;
  root->size = VM_SIZE;
  root->is_free = true;
  ctx->vm_extents = root;
  return ctx;
}

static uint64_t tls_get_addr(GuestContext *ctx, uint64_t module, uint64_t offset) {
  uint64_t *ti = (uint64_t *)(ctx->mem_base + TLS_INDEX);
  ti[0] = module;
  ti[1] = offset;
  ctx->rdi = TLS_INDEX;
  ctx->rsp = 0x1000;
  shim___tls_get_addr(ctx);
  CHECK(ctx->rsp == 0x1008, "__tls_get_addr pops its return address");
  return ctx->rax;
}

static uint32_t u32_at(GuestContext *ctx, uint64_t addr) { return *(uint32_t *)(ctx->mem_base + addr); }

// The three blocks of one thread whose TCB is at fs.
static void check_thread(GuestContext *ctx, const char *who) {
  const uint64_t fs = ctx->fs_base;
  // eboot (module 1): its block ends at FS, where its fs-relative accesses expect it.
  CHECK(tls_get_addr(ctx, 1, 0) == fs - 0x30, "%s: eboot block at fs-0x30", who);
  CHECK(u32_at(ctx, fs - 0x30) == 0xffffffffu, "%s: eboot .tdata copied (0x%x)", who, u32_at(ctx, fs - 0x30));
  // libSceFios2 (module 2): round(0x30 + 0x40, 8) = 0x70.
  const uint64_t fios_flag = tls_get_addr(ctx, 2, 0);
  const uint64_t fios_attr = tls_get_addr(ctx, 2, 8);
  CHECK(fios_flag == fs - 0x70 && fios_attr == fs - 0x68, "%s: Fios block at fs-0x70 (flag 0x%llx attr 0x%llx)", who,
        (unsigned long long)fios_flag, (unsigned long long)fios_attr);
  CHECK(u32_at(ctx, fios_flag) == 0, "%s: Fios thread-default flag reads 0 (0x%x)", who, u32_at(ctx, fios_flag));
  CHECK(*(uint64_t *)(ctx->mem_base + fios_attr + 8) == 0, "%s: Fios default attr callback reads NULL", who);
  // libc (module 3): round(0x70 + 0x490, 16) = 0x500; its .tdata at the block start, .tbss zero.
  const uint64_t libc = tls_get_addr(ctx, 3, 0);
  CHECK(libc == fs - 0x500, "%s: libc block at fs-0x500 (0x%llx)", who, (unsigned long long)libc);
  CHECK(memcmp(ctx->mem_base + libc, ctx->mem_base + LIBC_TDATA, 0x1a0) == 0, "%s: libc .tdata copied", who);
  CHECK(u32_at(ctx, libc + 0x1a0) == 0 && u32_at(ctx, libc + 0x48c) == 0, "%s: libc .tbss zero", who);
  CHECK(libc + 0x490 <= fs - 0x70 && fios_flag + 0x40 <= fs - 0x30, "%s: blocks do not overlap", who);
}

int main(void) {
  GuestContext *proc = new_process();
  *(uint32_t *)(proc->mem_base + EBOOT_TDATA) = 0xffffffffu;
  for (int i = 0; i < 0x1a0; i++) proc->mem_base[LIBC_TDATA + i] = (uint8_t)(0x40 + i);
  // TCB words recomp_init_runtime sets; the TLS setup must not touch them.
  *(uint64_t *)(proc->mem_base + MAIN_TCB) = MAIN_TCB;
  *(uint64_t *)(proc->mem_base + MAIN_TCB + 0x28) = 0x595e9fbd94fda766ULL;
  // Garbage below the TCB, as guest memory may hold before the TLS setup.
  memset(proc->mem_base + MAIN_TCB - 0x600, 0xcc, 0x600);

  static const RecompTlsModule mods[] = {
      {1, EBOOT_TDATA, 0x4, 0x30, 0x8, 0x30},
      {2, 0, 0x0, 0x40, 0x8, 0x70},
      {3, LIBC_TDATA, 0x1a0, 0x490, 0x10, 0x500},
  };
  recomp_init_tls_modules(proc, mods, 3);
  CHECK(proc->static_tls_size == 0x500, "static TLS size 0x%llx", (unsigned long long)proc->static_tls_size);
  CHECK(recomp_tls_module_offset(0) == 0 && recomp_tls_module_offset(4) == 0, "no block for modules 0 and 4");
  CHECK(*(uint64_t *)(proc->mem_base + MAIN_TCB) == MAIN_TCB &&
            *(uint64_t *)(proc->mem_base + MAIN_TCB + 0x28) == 0x595e9fbd94fda766ULL,
        "TCB words untouched");
  check_thread(proc, "main thread");

  // The main thread's TLS changes; a new thread still starts from the templates.
  *(uint32_t *)(proc->mem_base + MAIN_TCB - 0x70) = 1;
  *(uint32_t *)(proc->mem_base + MAIN_TCB - 0x500) = 0x12345678;
  GuestContext *t = recomp_create_thread_context(proc, 0x10000);
  CHECK(t != NULL, "thread context");
  if (t) {
    CHECK(t->static_tls_size == 0x500, "thread static TLS size");
    check_thread(t, "new thread");
    CHECK(u32_at(proc, MAIN_TCB - 0x70) == 1, "the main thread keeps its own Fios flag");
  }

  if (g_failures) {
    printf("tls_modules_test: %d failure(s)\n", g_failures);
    return 1;
  }
  printf("tls_modules_test: PASS\n");
  return 0;
}
