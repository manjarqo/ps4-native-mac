// Host test: a thread context made by recomp_create_thread_context starts with its creator's
// MXCSR and x87 control word, as FreeBSD's cpu_copy_thread copies them at thr_new; the creator
// keeps its own values; a creator with the defaults gives the defaults.
#include "runtime_stubs.h"

#include <stdio.h>
#include <stdlib.h>
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

// Direct memory is not exercised here; recomp_runtime.c only needs the symbols to link.
void ps4_direct_mem_destroy(void) {}
void ps4_direct_mem_configure(GuestContext *ctx, uint64_t proc_param_addr) {
  (void)ctx;
  (void)proc_param_addr;
}
void ps4_direct_mem_on_unmap(GuestContext *ctx, uint64_t addr, size_t size) {
  (void)ctx; (void)addr; (void)size;
}

static GuestContext *new_parent(void) {
  GuestContext *ctx = (GuestContext *)calloc(1, sizeof(GuestContext));
  void *mem = mmap(NULL, MEM_SIZE, PROT_READ | PROT_WRITE, MAP_ANON | MAP_PRIVATE | MAP_NORESERVE, -1, 0);
  if (mem == MAP_FAILED) exit(2);
  ctx->mem_base = (uint8_t *)mem;
  ctx->mem_size = MEM_SIZE;
  ctx->process_ctx = ctx;
  pthread_mutex_init(&ctx->vm_mutex, NULL);
  GuestVMExtent *root = (GuestVMExtent *)calloc(1, sizeof(GuestVMExtent));
  root->addr = VM_START;
  root->size = VM_SIZE;
  root->is_free = true;
  ctx->vm_extents = root;
  ctx->mxcsr = 0x1F80;
  ctx->fpu_cw = 0x037F;
  return ctx;
}

int main(void) {
  GuestContext *parent = new_parent();
  GuestContext *a = recomp_create_thread_context(parent, 0x10000);
  CHECK(a && a->mxcsr == 0x1F80 && a->fpu_cw == 0x037F, "defaults from a default creator");
  parent->mxcsr = 0x9FC0;  // FTZ | DAZ | all exceptions masked
  parent->fpu_cw = 0x027F; // x87 double precision
  GuestContext *b = recomp_create_thread_context(parent, 0x10000);
  CHECK(b && b->mxcsr == 0x9FC0, "MXCSR inherited (got %#x)", b ? b->mxcsr : 0);
  CHECK(b && b->fpu_cw == 0x027F, "x87 control word inherited (got %#x)", b ? b->fpu_cw : 0);
  CHECK(parent->mxcsr == 0x9FC0 && a->mxcsr == 0x1F80, "creator and older threads unchanged");
  parent->mxcsr = 0x7F80;  // round toward zero
  GuestContext *c = recomp_create_thread_context(b, 0x10000);
  CHECK(c && c->mxcsr == 0x9FC0, "a thread created by b inherits b's MXCSR, not the process's");
  if (g_failures) {
    printf("thread_fpstate_test: %d failure(s)\n", g_failures);
    return 1;
  }
  printf("thread_fpstate_test: PASS\n");
  return 0;
}
