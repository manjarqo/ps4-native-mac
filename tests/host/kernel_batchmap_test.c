// Host test of sceKernelBatchMap and sceKernelMtypeprotect against the real VM extent
// manager (recomp_runtime.c) and the real direct-memory code (ps4_direct_mem.c), with a host
// mmap standing in for guest memory. What it checks:
//  - every operation (map direct, map flexible, protect, type protect, unmap) has its effect
//    on the extents, and map operations write the mapped address back into the entry;
//  - the processed count: it counts the entries that completed, also on failure, and the
//    failed entry and the ones after it are not run;
//  - the failure rules: length 0, unknown operation, NULL array, a failing operation;
//  - type protect splits extents at the range edges and fails on an unmapped range;
//  - the guest-ABI shim reads the entries and the out count from guest memory.
#include "ps4_direct_mem.h"

#include <pthread.h>
#include <stdio.h>
#include <sys/mman.h>

#include "runtime_stubs.h"

// GPU hooks of the direct-memory code (weak in the runtime). The remap hook is not needed; the
// CPU-write hook records what sceKernelMtypeprotect invalidates.
void ps4_gnm_guest_remapped(uint64_t addr, uint64_t size) { (void)addr; (void)size; }
static uint64_t g_inval_addr, g_inval_size;
static int g_inval_calls;
void ps4_gnm_notify_cpu_write(uint64_t addr, uint64_t size) {
  g_inval_addr = addr;
  g_inval_size = size;
  g_inval_calls++;
}

#define MEM_SIZE (8ULL << 30)
#define VM_START 0x10000000ULL
#define VM_SIZE 0x70000000ULL
#define EINVAL_ORBIS ((int)0x80020016)
#define MB (1ULL << 20)

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

static GuestContext *new_ctx(void) {
  GuestContext *ctx = (GuestContext *)calloc(1, sizeof(GuestContext));
  void *mem = mmap(NULL, MEM_SIZE, PROT_READ | PROT_WRITE, MAP_ANON | MAP_PRIVATE | MAP_NORESERVE, -1, 0);
  if (mem == MAP_FAILED) {
    perror("mmap");
    exit(2);
  }
  ctx->mem_base = (uint8_t *)mem;
  ctx->mem_size = MEM_SIZE;
  ctx->process_ctx = ctx;
  pthread_mutex_init(&ctx->vm_mutex, NULL);
  GuestVMExtent *root = (GuestVMExtent *)calloc(1, sizeof(GuestVMExtent));
  root->addr = VM_START;
  root->size = VM_SIZE;
  root->is_free = true;
  ctx->vm_extents = root;
  ctx->rsp = 0x1000;
  ctx->fs_base = 0x2000; // errno slot at fs_base + 0x100
  return ctx;
}

static OrbisKernelBatchMapEntry entry(uint64_t start, uint64_t offset, uint64_t length, int prot, int type, int op) {
  OrbisKernelBatchMapEntry e;
  memset(&e, 0, sizeof(e));
  e.start = start;
  e.offset = offset;
  e.length = length;
  e.protection = (int8_t)prot;
  e.type = (int8_t)type;
  e.operation = op;
  return e;
}

static GuestVMExtent *find(GuestContext *ctx, uint64_t addr) { return recomp_vm_find(ctx, addr); }

static int count_used_extents(GuestContext *ctx) {
  int n = 0;
  for (GuestVMExtent *e = ctx->vm_extents; e; e = e->next) n += !e->is_free;
  return n;
}

// All five operations in one batch, in order, on real mappings.
static void test_all_operations(GuestContext *ctx) {
  off_t phys = 0;
  CHECK(sceKernelAllocateDirectMemory(0, PS4_DIRECT_MEM_TOTAL_SIZE, 4 * MB, 2 * MB, 0, &phys) == 0, "alloc");
  const uint64_t direct = 0x20000000, flex = 0x30000000;
  OrbisKernelBatchMapEntry e[6] = {
      entry(direct, (uint64_t)phys, 4 * MB, 3, 0, ORBIS_KERNEL_BATCH_MAP_DIRECT),
      entry(flex, 0, 2 * MB, 3, 0, ORBIS_KERNEL_BATCH_MAP_FLEXIBLE),
      entry(direct, 0, 2 * MB, 0x33, 3, ORBIS_KERNEL_BATCH_MAP_TYPE_PROTECT),
      entry(flex, 0, 2 * MB, 1, 0, ORBIS_KERNEL_BATCH_MAP_PROTECT),
      entry(flex, 0, 2 * MB, 0, 0, ORBIS_KERNEL_BATCH_MAP_UNMAP),
      entry(direct, 0, 4 * MB, 0, 0, ORBIS_KERNEL_BATCH_MAP_UNMAP),
  };
  int done = -1;

  // Step through the first four to look at the intermediate state.
  CHECK(sceKernelBatchMap(ctx, e, 2, &done) == 0 && done == 2, "map done=%d", done);
  CHECK(e[0].start == direct && e[1].start == flex, "start written back 0x%llx 0x%llx", (unsigned long long)e[0].start,
        (unsigned long long)e[1].start);
  GuestVMExtent *d = find(ctx, direct), *f = find(ctx, flex);
  CHECK(d && !d->is_free && d->addr == direct && d->size == 4 * MB && d->prot == 3, "direct extent");
  CHECK(f && !f->is_free && f->addr == flex && f->size == 2 * MB && f->prot == 3, "flexible extent");
  // The direct mapping is physically backed: a write through it is visible at the physical
  // offset, which a second mapping of the same physical range then shows.
  *(volatile uint32_t *)(ctx->mem_base + direct + 0x40) = 0xC0FFEE42;

  OrbisKernelBatchMapEntry tp[2] = {e[2], e[3]};
  CHECK(sceKernelBatchMap(ctx, tp, 2, &done) == 0 && done == 2, "protect done=%d", done);
  d = find(ctx, direct);
  CHECK(d && d->addr == direct && d->size == 2 * MB && d->prot == 0x33 && d->mtype == 3, "type protect head: size=0x%zx prot=0x%x mtype=%d",
        d ? d->size : 0, d ? d->prot : 0, d ? d->mtype : -1);
  GuestVMExtent *rest = find(ctx, direct + 2 * MB);
  CHECK(rest && rest->addr == direct + 2 * MB && rest->size == 2 * MB && rest->prot == 3 && rest->mtype == 0,
        "type protect left the tail alone: prot=0x%x mtype=%d", rest ? rest->prot : 0, rest ? rest->mtype : -1);
  f = find(ctx, flex);
  CHECK(f && f->prot == 1, "flexible protect prot=%d", f ? f->prot : -1);

  CHECK(sceKernelBatchMap(ctx, &e[4], 2, &done) == 0 && done == 2, "unmap done=%d", done);
  CHECK(find(ctx, flex)->is_free && find(ctx, direct)->is_free && find(ctx, direct + 3 * MB)->is_free, "unmapped");
  CHECK(count_used_extents(ctx) == 0, "no extent left, got %d", count_used_extents(ctx));

  // Same physical range mapped again elsewhere: the contents written above are still there.
  uint64_t again = 0x40000000;
  OrbisKernelBatchMapEntry m = entry(again, (uint64_t)phys, 4 * MB, 3, 0, ORBIS_KERNEL_BATCH_MAP_DIRECT);
  CHECK(sceKernelBatchMap(ctx, &m, 1, &done) == 0 && done == 1, "remap");
  CHECK(*(volatile uint32_t *)(ctx->mem_base + again + 0x40) == 0xC0FFEE42, "physical contents survive unmap and remap");
  OrbisKernelBatchMapEntry u = entry(again, 0, 4 * MB, 0, 0, ORBIS_KERNEL_BATCH_MAP_UNMAP);
  CHECK(sceKernelBatchMap(ctx, &u, 1, &done) == 0, "unmap again");
  CHECK(sceKernelReleaseDirectMemory(phys, 4 * MB) == 0, "release");
}

static void test_partial_failure(GuestContext *ctx) {
  const uint64_t a = 0x50000000, b = 0x51000000, c = 0x52000000;
  OrbisKernelBatchMapEntry e[4] = {
      entry(a, 0, MB, 3, 0, ORBIS_KERNEL_BATCH_MAP_FLEXIBLE),
      entry(b, 0, MB, 3, 0, ORBIS_KERNEL_BATCH_MAP_FLEXIBLE),
      entry(c, 0, 0, 3, 0, ORBIS_KERNEL_BATCH_MAP_FLEXIBLE), // length 0
      entry(c, 0, MB, 3, 0, ORBIS_KERNEL_BATCH_MAP_FLEXIBLE),
  };
  int done = -1;
  CHECK(sceKernelBatchMap(ctx, e, 4, &done) == EINVAL_ORBIS, "length 0 must fail with EINVAL");
  CHECK(done == 2, "two entries completed before the failure, got %d", done);
  CHECK(!find(ctx, a)->is_free && !find(ctx, b)->is_free, "the first two stay mapped");
  CHECK(find(ctx, c)->is_free, "the entry after the failure was not run");

  // A failing operation (not an invalid entry): unmap-able but type protect of an unmapped range.
  OrbisKernelBatchMapEntry f[3] = {
      entry(a, 0, MB, 0x33, 3, ORBIS_KERNEL_BATCH_MAP_TYPE_PROTECT), // ok
      entry(c, 0, MB, 0x33, 3, ORBIS_KERNEL_BATCH_MAP_TYPE_PROTECT), // unmapped
      entry(b, 0, MB, 0, 0, ORBIS_KERNEL_BATCH_MAP_UNMAP),
  };
  CHECK(sceKernelBatchMap(ctx, f, 3, &done) == EINVAL_ORBIS && done == 1, "unmapped type protect: done=%d", done);
  CHECK(!find(ctx, b)->is_free, "unmap after the failure did not run");
  CHECK(find(ctx, a)->mtype == 3 && find(ctx, a)->prot == 0x33, "first entry took effect");

  // The count is also written when every entry fails at once, and NULL is accepted.
  OrbisKernelBatchMapEntry bad = entry(a, 0, MB, 3, 0, 5); // unknown operation
  CHECK(sceKernelBatchMap(ctx, &bad, 1, &done) == EINVAL_ORBIS && done == 0, "op 5: done=%d", done);
  bad.operation = -1;
  CHECK(sceKernelBatchMap(ctx, &bad, 1, &done) == EINVAL_ORBIS && done == 0, "op -1: done=%d", done);
  CHECK(sceKernelBatchMap(ctx, &bad, 1, NULL) == EINVAL_ORBIS, "NULL out count");
  CHECK(sceKernelBatchMap(ctx, NULL, 1, &done) == EINVAL_ORBIS && done == 0, "NULL entries with count 1: done=%d", done);
  done = -1;
  CHECK(sceKernelBatchMap(ctx, NULL, 0, &done) == 0 && done == 0, "no entries: done=%d", done);

  OrbisKernelBatchMapEntry cleanup[2] = {entry(a, 0, MB, 0, 0, ORBIS_KERNEL_BATCH_MAP_UNMAP),
                                         entry(b, 0, MB, 0, 0, ORBIS_KERNEL_BATCH_MAP_UNMAP)};
  CHECK(sceKernelBatchMap(ctx, cleanup, 2, &done) == 0 && done == 2, "cleanup");
}

// A map entry whose requested (MAP_FIXED) address is taken fails; the allocator's fallback
// mapping elsewhere is undone.
static void test_fixed_address_taken(GuestContext *ctx) {
  const uint64_t a = 0x54000000;
  int done = -1;
  OrbisKernelBatchMapEntry first = entry(a, 0, 2 * MB, 3, 0, ORBIS_KERNEL_BATCH_MAP_FLEXIBLE);
  CHECK(sceKernelBatchMap(ctx, &first, 1, &done) == 0, "first map");
  int used = count_used_extents(ctx);
  OrbisKernelBatchMapEntry again[2] = {entry(a + MB, 0, 2 * MB, 3, 0, ORBIS_KERNEL_BATCH_MAP_FLEXIBLE),
                                       entry(0x55000000, 0, MB, 3, 0, ORBIS_KERNEL_BATCH_MAP_FLEXIBLE)};
  CHECK(sceKernelBatchMap(ctx, again, 2, &done) == (int)0x8002000c && done == 0, "taken address fails: done=%d", done);
  CHECK(count_used_extents(ctx) == used, "no stray mapping left (%d vs %d)", count_used_extents(ctx), used);
  CHECK(find(ctx, 0x55000000)->is_free, "entries after the failure did not run");
  CHECK(recomp_vm_free(ctx, a, 2 * MB) == 0, "cleanup");
}

// sceKernelMtypeprotect on a range inside a larger mapping: split in three, edges untouched.
static void test_mtypeprotect_split(GuestContext *ctx) {
  const uint64_t base = 0x60000000;
  void *p = (void *)base;
  CHECK(sceKernelMapNamedFlexibleMemory(ctx, &p, 8 * MB, 3, 0x10, "big") == 0, "map");
  // Unaligned request is widened to 16 KiB pages: [base+2MB+0x1000, +0x2000) -> [+0, +0x4000).
  g_inval_calls = 0;
  CHECK(sceKernelMtypeprotect(ctx, (void *)(base + 2 * MB + 0x1000), 0x2000, 10, 0x13) == 0, "mtypeprotect");
  CHECK(g_inval_calls == 1 && g_inval_addr == base + 2 * MB && g_inval_size == 0x4000,
        "GPU invalidation of the widened range: calls=%d addr=0x%llx size=0x%llx", g_inval_calls,
        (unsigned long long)g_inval_addr, (unsigned long long)g_inval_size);
  GuestVMExtent *lo = find(ctx, base), *mid = find(ctx, base + 2 * MB), *hi = find(ctx, base + 2 * MB + 0x4000);
  CHECK(lo && lo->addr == base && lo->size == 2 * MB && lo->prot == 3 && lo->mtype == 0, "low part");
  CHECK(mid && mid->addr == base + 2 * MB && mid->size == 0x4000 && mid->prot == 0x13 && mid->mtype == 10,
        "middle: size=0x%zx prot=0x%x mtype=%d", mid ? mid->size : 0, mid ? mid->prot : 0, mid ? mid->mtype : -1);
  CHECK(hi && hi->addr == base + 2 * MB + 0x4000 && hi->size == 8 * MB - 2 * MB - 0x4000 && hi->prot == 3 && hi->mtype == 0,
        "high part");
  CHECK(!strcmp(mid->name, "big") && !strcmp(hi->name, "big"), "split parts keep the name");
  // Zero length is a no-op, a range with no mapping at all fails.
  CHECK(sceKernelMtypeprotect(ctx, (void *)0x70000000, 0, 0, 3) == 0, "zero length");
  g_inval_calls = 0;
  CHECK(sceKernelMtypeprotect(ctx, (void *)0x70000000, MB, 0, 3) == EINVAL_ORBIS, "unmapped range");
  CHECK(g_inval_calls == 0, "a failed call invalidates nothing");
  CHECK(sceKernelMtypeprotect(ctx, (void *)(MEM_SIZE - 0x1000), 0x10000, 0, 3) == EINVAL_ORBIS, "beyond guest memory");
  CHECK(recomp_vm_free(ctx, base, 8 * MB) == 0, "free");
}

// The guest-ABI shim: entries and the out count live in guest memory.
static void test_shim(GuestContext *ctx) {
  const uint64_t entries_gaddr = 0x8000, out_gaddr = 0x9000;
  OrbisKernelBatchMapEntry *e = (OrbisKernelBatchMapEntry *)(ctx->mem_base + entries_gaddr);
  e[0] = entry(0x58000000, 0, 2 * MB, 3, 0, ORBIS_KERNEL_BATCH_MAP_FLEXIBLE);
  e[1] = entry(0x58000000, 0, 2 * MB, 0x33, 3, ORBIS_KERNEL_BATCH_MAP_TYPE_PROTECT);
  e[2] = entry(0x59000000, 0, 2 * MB, 0x33, 3, ORBIS_KERNEL_BATCH_MAP_TYPE_PROTECT); // unmapped
  *(int32_t *)(ctx->mem_base + out_gaddr) = -7;
  ctx->rdi = entries_gaddr;
  ctx->rsi = 3;
  ctx->rdx = out_gaddr;
  ctx->rsp = 0x1000;
  shim_sceKernelBatchMap(ctx);
  CHECK((int32_t)ctx->rax == EINVAL_ORBIS, "shim result 0x%llx", (unsigned long long)ctx->rax);
  CHECK(*(int32_t *)(ctx->mem_base + out_gaddr) == 2, "shim out count %d", *(int32_t *)(ctx->mem_base + out_gaddr));
  CHECK(ctx->rsp == 0x1008, "shim pops the return address");
  CHECK(find(ctx, 0x58000000)->mtype == 3, "shim executed the first two entries");
  CHECK(recomp_vm_free(ctx, 0x58000000, 2 * MB) == 0, "free");

  ctx->rdi = 0;
  ctx->rsi = 1;
  ctx->rdx = 0;
  shim_sceKernelBatchMap(ctx);
  CHECK((int32_t)ctx->rax == EINVAL_ORBIS, "shim NULL entries");

  ctx->rdi = 0x58000000;
  ctx->rsi = MB;
  ctx->rdx = 0;
  ctx->rcx = 3;
  shim_sceKernelMtypeprotect(ctx);
  CHECK((int32_t)ctx->rax == EINVAL_ORBIS, "mtypeprotect shim on an unmapped range");
}

int main(void) {
  GuestContext *ctx = new_ctx();
  test_all_operations(ctx);
  test_partial_failure(ctx);
  test_fixed_address_taken(ctx);
  test_mtypeprotect_split(ctx);
  test_shim(ctx);
  fflush(stdout);
  if (g_failures) {
    printf("kernel_batchmap_test: %d FAILED\n", g_failures);
    return 1;
  }
  printf("kernel_batchmap_test: PASS\n");
  return 0;
}
