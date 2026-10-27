// Host test: the direct memory size comes from the process's memory parameters, as the kernel
// sets it up at process start (the rule shadPS4 follows in linker.cpp and memory.cpp
// SetupMemoryRegions). What it checks:
//  - the rule: 5248 MiB in total (5888 MiB in Neo mode), minus the flexible memory (the param's
//    flexible_memory_size plus 64 MiB, else 512 MiB), minus 128 MiB in base mode without
//    extended memory 2 and 256 MiB in Neo mode without extended memory 1; before SDK 5.00 the
//    extended memory flags come from the param, from 5.00 on both are on;
//  - a guest SceProcParam built like inFAMOUS Second Son's (size 0x48, SDK 0x04008061,
//    SceKernelMemParam of size 0x18, no flexible size) gives 4608 MiB through
//    recomp_init_process_param, and the free direct memory before any allocation is the same;
//  - SceKernelMemParam fields past the param's size are not read;
//  - flexible_memory_size and the extended memory flags are read through their pointers;
//  - Neo mode;
//  - missing parameters (no SceKernelMemParam, a short SceProcParam, none at all), and the size
//    before the configuration;
//  - PS4_DIRECT_MEM_SIZE overrides the size, also before the configuration;
//  - direct memory never grows past the size: allocations beyond what remains fail with EAGAIN
//    (ENOMEM for sceKernelMemoryPoolExpand), and the free memory stays within the size.
#define RUNTIME_STUBS_HAVE_NEO_MODE // the test sets the mode itself
#include "runtime_stubs.h"
#include "ps4_direct_mem.h"

#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>

// GPU hooks of the direct-memory code; no GPU here.
void ps4_gnm_guest_remapped(uint64_t addr, uint64_t size) { (void)addr; (void)size; }
void ps4_gnm_notify_cpu_write(uint64_t addr, uint64_t size) { (void)addr; (void)size; }

static int32_t g_neo;
int32_t sceKernelIsNeoMode(void) { return g_neo; }

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

#define MIB ((size_t)1 << 20)
#define MEM_SIZE 0x100000ULL
#define PROC_PARAM 0x1000ULL
#define MEM_PARAM 0x2000ULL
#define FLEX_SIZE 0x3000ULL // u64 flexible_memory_size
#define EXT1_FLAG 0x3100ULL // u8 extended_memory_1
#define EXT2_FLAG 0x3200ULL // u8 extended_memory_2

static void put64(GuestContext *ctx, uint64_t addr, uint64_t v) { memcpy(ctx->mem_base + addr, &v, 8); }

static GuestContext *new_ctx(void) {
  GuestContext *ctx = (GuestContext *)calloc(1, sizeof(GuestContext));
  void *mem = mmap(NULL, MEM_SIZE, PROT_READ | PROT_WRITE, MAP_ANON | MAP_PRIVATE, -1, 0);
  if (!ctx || mem == MAP_FAILED) {
    perror("new_ctx");
    exit(2);
  }
  ctx->mem_base = (uint8_t *)mem;
  ctx->mem_size = MEM_SIZE;
  ctx->process_ctx = ctx;
  pthread_mutex_init(&ctx->vm_mutex, NULL);
  return ctx;
}

// A SceProcParam of size 0x48 ("ORBI", SDK `sdk`) whose SceKernelMemParam has size `mp_size`.
static void build_params(GuestContext *ctx, uint64_t sdk, uint64_t mp_size) {
  memset(ctx->mem_base, 0, MEM_SIZE);
  put64(ctx, PROC_PARAM + 0x00, 0x48);
  memcpy(ctx->mem_base + PROC_PARAM + 0x08, "ORBI", 4);
  put64(ctx, PROC_PARAM + 0x10, sdk);
  put64(ctx, PROC_PARAM + 0x40, MEM_PARAM);
  put64(ctx, MEM_PARAM + 0x00, mp_size);
}

static void test_rule(void) {
  struct {
    uint32_t sdk;
    int neo, has_flex;
    uint64_t flex;
    int ext1, ext2;
    uint64_t want_mib;
  } cases[] = {
      {0x04008061, 0, 0, 0, 0, 0, 4608},
      {0x04008061, 1, 0, 0, 0, 0, 5120},
      {0x04008061, 0, 0, 0, 0, 1, 4736},
      {0x05050001, 0, 0, 0, 0, 0, 4736},
      {0x05050001, 1, 0, 0, 0, 0, 5376},
      {0x05050001, 0, 1, 448 * MIB, 0, 0, 4736},
      {0x05050001, 0, 1, 1024 * MIB, 0, 0, 4160},
  };
  for (size_t i = 0; i < sizeof(cases) / sizeof(cases[0]); i++) {
    uint64_t got = ps4_direct_mem_size_rule(cases[i].sdk, cases[i].neo, cases[i].has_flex, cases[i].flex,
                                            cases[i].ext1, cases[i].ext2);
    CHECK(got == cases[i].want_mib * MIB, "case %zu: %llu MiB, want %llu MiB", i,
          (unsigned long long)(got / MIB), (unsigned long long)cases[i].want_mib);
  }
}

// Before ps4_direct_mem_configure runs, the size is the rule's for a process without parameters,
// in the current mode, and PS4_DIRECT_MEM_SIZE overrides it. Runs first: configuring is one-way.
static void test_before_configure(void) {
  g_neo = 0;
  CHECK(sceKernelGetDirectMemorySize() == 4608 * MIB, "unconfigured: %zu MiB, want 4608", sceKernelGetDirectMemorySize() / MIB);
  g_neo = 1;
  CHECK(sceKernelGetDirectMemorySize() == 5120 * MIB, "unconfigured Neo: %zu MiB, want 5120",
        sceKernelGetDirectMemorySize() / MIB);
  g_neo = 0;
  setenv("PS4_DIRECT_MEM_SIZE", "5000m", 1);
  CHECK(sceKernelGetDirectMemorySize() == 5000 * MIB, "unconfigured override: %zu MiB, want 5000",
        sceKernelGetDirectMemorySize() / MIB);
  unsetenv("PS4_DIRECT_MEM_SIZE");
}

// inFAMOUS Second Son: proc param size 0x48, SDK 0x04008061, mem_param size 0x18 with a NULL
// flexible_memory_size, through the process start path.
static void test_infamous_param(GuestContext *ctx) {
  g_neo = 0;
  build_params(ctx, 0x04008061, 0x18);
  // Fields past the param's size: a reader that ignores the size would take extended memory 2.
  ctx->mem_base[EXT2_FLAG] = 1;
  put64(ctx, MEM_PARAM + 0x28, EXT2_FLAG);
  recomp_init_process_param(ctx, PROC_PARAM);
  CHECK(sceKernelGetDirectMemorySize() == 4608 * MIB, "size %zu MiB, want 4608", sceKernelGetDirectMemorySize() / MIB);
  CHECK(sceKernelAvailableDirectMemorySize() == 4608 * MIB, "available %zu MiB, want 4608",
        sceKernelAvailableDirectMemorySize() / MIB);
}

// The fields read through their pointers: flexible_memory_size (+0x10), extended_memory_1 (+0x18)
// and extended_memory_2 (+0x28), each within the param's size.
static void test_param_fields(GuestContext *ctx) {
  g_neo = 0;
  build_params(ctx, 0x05050001, 0x38);
  put64(ctx, FLEX_SIZE, 1024 * MIB);
  put64(ctx, MEM_PARAM + 0x10, FLEX_SIZE);
  ps4_direct_mem_configure(ctx, PROC_PARAM);
  CHECK(sceKernelGetDirectMemorySize() == 4160 * MIB, "flexible 1024 MiB: %zu MiB, want 4160",
        sceKernelGetDirectMemorySize() / MIB);
  CHECK(sceKernelAvailableDirectMemorySize() == 4160 * MIB, "available %zu MiB, want 4160",
        sceKernelAvailableDirectMemorySize() / MIB);

  build_params(ctx, 0x04008061, 0x30);
  ctx->mem_base[EXT2_FLAG] = 1;
  put64(ctx, MEM_PARAM + 0x28, EXT2_FLAG);
  ps4_direct_mem_configure(ctx, PROC_PARAM);
  CHECK(sceKernelGetDirectMemorySize() == 4736 * MIB, "extended memory 2: %zu MiB, want 4736",
        sceKernelGetDirectMemorySize() / MIB);

  g_neo = 1;
  build_params(ctx, 0x04008061, 0x30);
  ctx->mem_base[EXT1_FLAG] = 1;
  put64(ctx, MEM_PARAM + 0x18, EXT1_FLAG);
  ps4_direct_mem_configure(ctx, PROC_PARAM);
  CHECK(sceKernelGetDirectMemorySize() == 5376 * MIB, "Neo, extended memory 1: %zu MiB, want 5376",
        sceKernelGetDirectMemorySize() / MIB);
  build_params(ctx, 0x04008061, 0x18);
  ps4_direct_mem_configure(ctx, PROC_PARAM);
  CHECK(sceKernelGetDirectMemorySize() == 5120 * MIB, "Neo: %zu MiB, want 5120", sceKernelGetDirectMemorySize() / MIB);
  CHECK(sceKernelAvailableDirectMemorySize() == 5120 * MIB, "Neo available %zu MiB, want 5120",
        sceKernelAvailableDirectMemorySize() / MIB);
  g_neo = 0;
}

// Missing parameters: no SceKernelMemParam, a SceProcParam too short to hold its pointer, no
// SceProcParam at all. Each case follows one that gives another size.
static void test_missing_params(GuestContext *ctx) {
  g_neo = 0;
  build_params(ctx, 0x05050001, 0x18);
  put64(ctx, PROC_PARAM + 0x40, 0); // mem_param NULL; the SDK still counts (5.00+: both extended)
  ps4_direct_mem_configure(ctx, PROC_PARAM);
  CHECK(sceKernelGetDirectMemorySize() == 4736 * MIB, "mem_param NULL: %zu MiB, want 4736",
        sceKernelGetDirectMemorySize() / MIB);

  // Size 0x40: mem_param at +0x40 is past the end, so its flexible size of 1024 MiB is not read.
  build_params(ctx, 0x05050001, 0x18);
  put64(ctx, PROC_PARAM, 0x40);
  put64(ctx, FLEX_SIZE, 1024 * MIB);
  put64(ctx, MEM_PARAM + 0x10, FLEX_SIZE);
  ps4_direct_mem_configure(ctx, PROC_PARAM);
  CHECK(sceKernelGetDirectMemorySize() == 4736 * MIB, "proc param size 0x40: %zu MiB, want 4736",
        sceKernelGetDirectMemorySize() / MIB);
  put64(ctx, PROC_PARAM, 0x48);
  ps4_direct_mem_configure(ctx, PROC_PARAM);
  CHECK(sceKernelGetDirectMemorySize() == 4160 * MIB, "proc param size 0x48: %zu MiB, want 4160",
        sceKernelGetDirectMemorySize() / MIB);

  ps4_direct_mem_configure(ctx, 0); // no SceProcParam: SDK 0, no memory parameters
  CHECK(sceKernelGetDirectMemorySize() == 4608 * MIB, "no proc param: %zu MiB, want 4608",
        sceKernelGetDirectMemorySize() / MIB);
  CHECK(sceKernelAvailableDirectMemorySize() == 4608 * MIB, "no proc param available: %zu MiB, want 4608",
        sceKernelAvailableDirectMemorySize() / MIB);
}

// Direct memory never grows past the size: an allocation larger than what remains fails with
// EAGAIN (shadPS4's sceKernelAllocateDirectMemory), sceKernelAllocateMainDirectMemory searches the
// whole size, and the free memory never exceeds the size.
#define ORBIS_EINVAL ((int)0x80020016)
#define ORBIS_EAGAIN ((int)0x80020023)
#define ORBIS_ENOMEM ((int)0x8002000c)
static void test_allocation_bounds(GuestContext *ctx) {
  g_neo = 0;
  build_params(ctx, 0x04008061, 0x18);
  ps4_direct_mem_configure(ctx, PROC_PARAM);
  const size_t size = sceKernelGetDirectMemorySize();
  CHECK(size == 4608 * MIB, "size %zu MiB, want 4608", size / MIB);
  off_t phys = -1;
  // inFAMOUS's start: 1152 MiB, 512 MiB, then "the rest" of type 3.
  CHECK(sceKernelAllocateMainDirectMemory(1152 * MIB, 64 << 10, 0, &phys) == 0 && phys == 0, "main 1152 MiB: phys 0x%llx",
        (unsigned long long)phys);
  CHECK(sceKernelAllocateDirectMemory(0, (off_t)size, 512 * MIB, 64 << 10, 0, &phys) == 0 && phys == (off_t)(1152 * MIB),
        "512 MiB: phys 0x%llx", (unsigned long long)phys);
  const size_t rest = sceKernelAvailableDirectMemorySize();
  CHECK(rest == 2944 * MIB, "rest %zu MiB, want 2944", rest / MIB);
  int rc = sceKernelAllocateMainDirectMemory(rest + (64 << 10), 64 << 10, 3, &phys);
  CHECK(rc == ORBIS_EAGAIN, "main past the size: rc 0x%x, want EAGAIN", rc);
  rc = sceKernelAllocateDirectMemory(0, (off_t)(64ULL << 30), rest + (64 << 10), 64 << 10, 3, &phys);
  CHECK(rc == ORBIS_EAGAIN, "search end past the size: rc 0x%x, want EAGAIN", rc);
  rc = sceKernelMemoryPoolExpand(ctx, 0, (off_t)(64ULL << 30), rest + (64 << 10), 64 << 10, &phys);
  CHECK(rc == ORBIS_ENOMEM, "pool expand past the size: rc 0x%x, want ENOMEM", rc);
  CHECK(sceKernelGetDirectMemorySize() == size && sceKernelAvailableDirectMemorySize() == rest,
        "a failed allocation changed the size (%zu MiB) or the free memory (%zu MiB)", sceKernelGetDirectMemorySize() / MIB,
        sceKernelAvailableDirectMemorySize() / MIB);
  // Bounds: a negative end is invalid, an empty range has nothing to give.
  rc = sceKernelAllocateDirectMemory(0, -1, 64 << 10, 64 << 10, 0, &phys);
  CHECK(rc == ORBIS_EINVAL, "search end -1: rc 0x%x, want EINVAL", rc);
  rc = sceKernelAllocateDirectMemory(0, 0, 64 << 10, 64 << 10, 0, &phys);
  CHECK(rc == ORBIS_EAGAIN, "search end 0: rc 0x%x, want EAGAIN", rc);
  // The search starts inside a free block, not only at block starts.
  rc = sceKernelAllocateDirectMemory((off_t)(2048 * MIB), (off_t)size, 64 * MIB, 64 << 10, 0, &phys);
  CHECK(rc == 0 && phys == (off_t)(2048 * MIB), "start inside a block: rc 0x%x phys 0x%llx", rc, (unsigned long long)phys);
  CHECK(sceKernelAvailableDirectMemorySize() == rest - 64 * MIB, "available %zu MiB, want %zu",
        sceKernelAvailableDirectMemorySize() / MIB, (rest - 64 * MIB) / MIB);
  // The rest, in two parts around that block, then nothing.
  CHECK(sceKernelAllocateMainDirectMemory(2048 * MIB - 1664 * MIB, 64 << 10, 3, &phys) == 0, "below");
  CHECK(sceKernelAllocateMainDirectMemory(size - 2112 * MIB, 64 << 10, 3, &phys) == 0, "above");
  CHECK(sceKernelAvailableDirectMemorySize() == 0, "available %zu MiB, want 0", sceKernelAvailableDirectMemorySize() / MIB);
  rc = sceKernelAllocateMainDirectMemory(64 << 10, 64 << 10, 3, &phys);
  CHECK(rc == ORBIS_EAGAIN, "full: rc 0x%x, want EAGAIN", rc);
  CHECK(sceKernelAvailableDirectMemorySize() <= sceKernelGetDirectMemorySize(), "available exceeds the size");
}

static void test_override(GuestContext *ctx) {
  build_params(ctx, 0x04008061, 0x18);
  setenv("PS4_DIRECT_MEM_SIZE", "6g", 1);
  ps4_direct_mem_configure(ctx, PROC_PARAM);
  CHECK(sceKernelGetDirectMemorySize() == 6144 * MIB, "override: %zu MiB, want 6144", sceKernelGetDirectMemorySize() / MIB);
  unsetenv("PS4_DIRECT_MEM_SIZE");
}

int main(void) {
  GuestContext *ctx = new_ctx();
  test_rule();
  test_before_configure();
  test_infamous_param(ctx);
  test_param_fields(ctx);
  test_missing_params(ctx);
  test_override(ctx);
  test_allocation_bounds(ctx); // last: allocated direct memory cannot be resized

  fflush(stdout);
  if (g_failures) {
    printf("direct_mem_size_test: %d FAILED\n", g_failures);
    return 1;
  }
  printf("direct_mem_size_test: PASS\n");
  return 0;
}
