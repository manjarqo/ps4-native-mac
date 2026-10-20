// Host test of recomp_vm_free (the guest munmap) against the real VM extent manager.
//  - a range that crosses a free hole and then a live neighbour frees both live extents;
//  - a range that starts or ends inside a live extent leaves the remainder with all attributes
//    (name, protection, memory type), so e.g. a partly unmapped "flexible" mapping still counts
//    as flexible memory;
//  - a second free of the same range changes nothing, a range with no mapping is a no-op;
//  - direct-memory detach (ps4_direct_mem_on_unmap, replaced here by a recording hook) runs
//    once per mapped range, never over the hole;
//  - a mapping another thread creates in the hole while a multi-extent free is in flight is
//    not freed by that free (the hook makes the interleaving deterministic);
//  - after concurrent frees and allocations the extent list is still sorted, contiguous and
//    fully merged.
#include "runtime_stubs.h"

#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>

#define MEM_SIZE (8ULL << 30)
#define VM_START 0x10000000ULL
#define VM_SIZE 0x70000000ULL
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

// ---- the direct-memory hook ----------------------------------------------------------
static struct {
  uint64_t addr, size;
} g_unmaps[64];
static int g_unmap_calls;
static void (*g_unmap_hook)(GuestContext *, int call_no);

void ps4_direct_mem_destroy(void) {}
void ps4_direct_mem_on_unmap(GuestContext *ctx, uint64_t addr, size_t size) {
  int n = g_unmap_calls++;
  if (n < 64) {
    g_unmaps[n].addr = addr;
    g_unmaps[n].size = size;
  }
  if (g_unmap_hook) g_unmap_hook(ctx, n);
}

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
  return ctx;
}

static void map(GuestContext *ctx, uint64_t addr, uint64_t size, const char *name, int prot, int mtype) {
  CHECK(recomp_vm_alloc_fixed(ctx, addr, size, prot, 0, name) == addr, "map %s", name);
  GuestVMExtent *e = recomp_vm_find(ctx, addr);
  e->mtype = mtype;
}

static GuestVMExtent *ext(GuestContext *ctx, uint64_t addr) { return recomp_vm_find(ctx, addr); }

static int used_extents(GuestContext *ctx) {
  int n = 0;
  for (GuestVMExtent *e = ctx->vm_extents; e; e = e->next) n += !e->is_free;
  return n;
}

// Sorted, contiguous over the whole space, nothing zero-sized, no two free extents touching.
static int check_list(GuestContext *ctx, const char *when) {
  GuestVMExtent *prev = NULL;
  uint64_t total = 0;
  for (GuestVMExtent *e = ctx->vm_extents; e; prev = e, e = e->next) {
    if (e->prev != prev) { printf("FAIL %s: prev link broken at 0x%llx\n", when, (unsigned long long)e->addr); return 0; }
    if (e->size == 0) { printf("FAIL %s: empty extent\n", when); return 0; }
    if (prev && prev->addr + prev->size != e->addr) { printf("FAIL %s: gap or overlap at 0x%llx\n", when, (unsigned long long)e->addr); return 0; }
    if (prev && prev->is_free && e->is_free) { printf("FAIL %s: two free extents touch at 0x%llx\n", when, (unsigned long long)e->addr); return 0; }
    total += e->size;
  }
  if (total != VM_SIZE) { printf("FAIL %s: extents cover 0x%llx, want 0x%llx\n", when, (unsigned long long)total, (unsigned long long)VM_SIZE); return 0; }
  return 1;
}

static void reset_hook(void) {
  g_unmap_calls = 0;
  g_unmap_hook = NULL;
}

// (a) hole then live neighbour; the start is inside A.
static void test_hole_and_neighbour(GuestContext *ctx) {
  const uint64_t A = 0x20000000, B = 0x20200000;
  map(ctx, A, MB, "A", 3, 2);
  map(ctx, B, MB, "B", 3, 0);
  reset_hook();
  CHECK(recomp_vm_free(ctx, A + 0x80000, B + MB - (A + 0x80000)) == 0, "free");
  GuestVMExtent *a = ext(ctx, A);
  CHECK(!a->is_free && a->addr == A && a->size == 0x80000 && !strcmp(a->name, "A") && a->prot == 3 && a->mtype == 2,
        "head of A survives with its attributes: size=0x%zx name=%s prot=%d mtype=%d", a->size, a->name, a->prot, a->mtype);
  GuestVMExtent *f = ext(ctx, A + 0x80000);
  CHECK(f->is_free && f->addr == A + 0x80000 && f->addr + f->size == VM_START + VM_SIZE, "everything after A's head is one free extent");
  CHECK(!ext(ctx, B)->is_free ? 0 : 1, "B freed");
  CHECK(g_unmap_calls == 2 && g_unmaps[0].addr == A + 0x80000 && g_unmaps[0].size == 0x80000 && g_unmaps[1].addr == B &&
            g_unmaps[1].size == MB,
        "detach once per mapped range, not over the hole: %d calls", g_unmap_calls);
  CHECK(check_list(ctx, "(a)"), "list");
  CHECK(recomp_vm_free(ctx, A, MB) == 0 && used_extents(ctx) == 0, "cleanup");
}

// (b) the range ends inside a live neighbour; plus a partial unmap from the middle.
static void test_partial_keeps_attributes(GuestContext *ctx) {
  const uint64_t C = 0x30000000, D = 0x30200000;
  map(ctx, C, 2 * MB, "flexible", 3, 5);
  map(ctx, D, MB, "D", 1, 7);
  CHECK(recomp_vm_free(ctx, C + MB, MB + 0x40000) == 0, "free");
  GuestVMExtent *c = ext(ctx, C);
  CHECK(!c->is_free && c->size == MB && !strcmp(c->name, "flexible") && c->prot == 3 && c->mtype == 5, "C head: name=%s mtype=%d", c->name, c->mtype);
  GuestVMExtent *d = ext(ctx, D + 0x40000);
  CHECK(!d->is_free && d->addr == D + 0x40000 && d->size == MB - 0x40000 && !strcmp(d->name, "D") && d->prot == 1 && d->mtype == 7,
        "D remainder: addr=0x%llx name=%s prot=%d mtype=%d", (unsigned long long)d->addr, d->name, d->prot, d->mtype);
  CHECK(ext(ctx, C + MB)->is_free && ext(ctx, D)->is_free, "the middle is free");
  CHECK(check_list(ctx, "(b)"), "list");

  // From the middle of one extent: both remainders keep name and memory type.
  map(ctx, 0x30800000, 4 * MB, "flexible", 3, 9);
  CHECK(recomp_vm_free(ctx, 0x30800000 + MB, MB) == 0, "free middle");
  GuestVMExtent *lo = ext(ctx, 0x30800000), *hi = ext(ctx, 0x30800000 + 2 * MB);
  CHECK(!lo->is_free && lo->size == MB && !strcmp(lo->name, "flexible") && lo->mtype == 9, "low remainder");
  CHECK(!hi->is_free && hi->size == 2 * MB && !strcmp(hi->name, "flexible") && hi->mtype == 9 && hi->prot == 3, "high remainder: name=%s mtype=%d", hi->name, hi->mtype);
  CHECK(check_list(ctx, "(b2)"), "list");
  CHECK(recomp_vm_free(ctx, C, MB) == 0 && recomp_vm_free(ctx, D + 0x40000, MB) == 0 && recomp_vm_free(ctx, 0x30800000, MB) == 0 &&
            recomp_vm_free(ctx, 0x30800000 + 2 * MB, 2 * MB) == 0 && used_extents(ctx) == 0,
        "cleanup, used=%d", used_extents(ctx));
}

// (c) double free and unmapped ranges.
static void test_double_free(GuestContext *ctx) {
  const uint64_t E = 0x38000000;
  map(ctx, E, MB, "E", 3, 0);
  map(ctx, E + MB, MB, "F", 3, 0);
  CHECK(recomp_vm_free(ctx, E, 2 * MB) == 0 && used_extents(ctx) == 0, "free");
  reset_hook();
  CHECK(recomp_vm_free(ctx, E, 2 * MB) == 0, "second free");
  CHECK(used_extents(ctx) == 0 && check_list(ctx, "(c)") && g_unmap_calls == 0, "second free changed nothing and detached nothing (%d calls)", g_unmap_calls);
  CHECK(recomp_vm_free(ctx, 0x6f000000, MB) == 0 && g_unmap_calls == 0, "range with no mapping");
  CHECK(recomp_vm_free(ctx, 0, MB) == -1 && recomp_vm_free(ctx, E, 0) == -1 && recomp_vm_free(NULL, E, MB) == -1, "bad arguments");
}

// (d) a mapping created in the hole while the free is in flight must survive.
static const uint64_t H = 0x40100000;
static void create_in_hole(GuestContext *ctx, int call_no) {
  if (call_no == 1) { // after the first mapped range was handled, before the second
    CHECK(recomp_vm_alloc_fixed(ctx, H, MB, 3, 0, "G") == H, "alloc in the hole while a free is in flight");
  }
}
static void test_hole_not_freed_by_inflight_free(GuestContext *ctx) {
  const uint64_t X = 0x40000000, Y = 0x40200000;
  map(ctx, X, MB, "X", 3, 0);
  map(ctx, Y, MB, "Y", 3, 0);
  reset_hook();
  g_unmap_hook = create_in_hole;
  CHECK(recomp_vm_free(ctx, X, 3 * MB) == 0, "free");
  g_unmap_hook = NULL;
  GuestVMExtent *g = ext(ctx, H);
  CHECK(!g->is_free && g->addr == H && g->size == MB && !strcmp(g->name, "G"), "the mapping made in the hole survives: free=%d size=0x%zx", g->is_free, g->size);
  CHECK(ext(ctx, X)->is_free && ext(ctx, Y)->is_free, "X and Y are free");
  CHECK(check_list(ctx, "(d)"), "list");
  CHECK(recomp_vm_free(ctx, H, MB) == 0 && used_extents(ctx) == 0, "cleanup");
}

// ---- concurrency ---------------------------------------------------------------------
struct stress {
  GuestContext *ctx;
  int id;
  int rounds;
};

static void *stress_free(void *arg) {
  struct stress *s = (struct stress *)arg;
  const uint64_t base = 0x50000000ULL + (uint64_t)s->id * 64 * MB;
  unsigned seed = (unsigned)s->id * 7919u + 1;
  for (int r = 0; r < s->rounds; r++) {
    // Four adjacent mappings with different attributes, then one free over a random span.
    for (int i = 0; i < 4; i++) {
      uint64_t a = base + (uint64_t)i * MB;
      // The allocating threads may be using part of the window right now: skip such a slot.
      if (recomp_vm_alloc_fixed(s->ctx, a, MB, 3, 0, i & 1 ? "odd" : "even") == a) recomp_vm_find(s->ctx, a)->mtype = i;
    }
    uint64_t from = base + (uint64_t)(rand_r(&seed) % 4) * MB + (uint64_t)(rand_r(&seed) % 16) * 0x10000;
    uint64_t to = base + (uint64_t)(1 + rand_r(&seed) % 4) * MB;
    if (to > from) recomp_vm_free(s->ctx, from, to - from);
    recomp_vm_free(s->ctx, base, 4 * MB);
  }
  return NULL;
}

static void *stress_alloc(void *arg) {
  struct stress *s = (struct stress *)arg;
  for (int r = 0; r < s->rounds; r++) {
    uint64_t a = recomp_vm_alloc_named_aligned(s->ctx, 0x40000, 0x10000, 3, 0, "dyn");
    if (a != (uint64_t)-1) recomp_vm_free(s->ctx, a, 0x40000);
  }
  return NULL;
}

static void test_concurrent(GuestContext *ctx) {
  pthread_t t[6];
  struct stress s[6];
  for (int i = 0; i < 6; i++) {
    s[i] = (struct stress){ctx, i, i < 4 ? 3000 : 6000};
    pthread_create(&t[i], NULL, i < 4 ? stress_free : stress_alloc, &s[i]);
  }
  for (int i = 0; i < 6; i++) pthread_join(t[i], NULL);
  CHECK(check_list(ctx, "concurrent") && used_extents(ctx) == 0, "extent list after the stress, used=%d", used_extents(ctx));
}

int main(void) {
  GuestContext *ctx = new_ctx();
  test_hole_and_neighbour(ctx);
  test_partial_keeps_attributes(ctx);
  test_double_free(ctx);
  test_hole_not_freed_by_inflight_free(ctx);
  test_concurrent(ctx);
  fflush(stdout);
  if (g_failures) {
    printf("kernel_vmfree_test: %d FAILED\n", g_failures);
    return 1;
  }
  printf("kernel_vmfree_test: PASS\n");
  return 0;
}
