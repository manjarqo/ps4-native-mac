# inFAMOUS Second Son Bring-up Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** inFAMOUS Second Son (CUSA00004 v01.00) is playable on an M1 Pro Mac to the TLOU bar, with fixes that are correct console behaviour for any game.

**Architecture:** The TLOU / Uncharted 4 bring-up loop: run the game time-bounded, find the first failure, find its root cause, fix it where it lives (runtime, lifter, renderer, translator) with a host test, re-run. Phase 1 is planned in full here. Phases 2–5 have their gate and method; each begins with a planning task that writes that phase's tasks into this file from the previous gate's findings.

**Tech Stack:** Go (lifter, emitter: `pkg/`), C / Objective-C++ HLE runtime (`pkg/runtime`), Metal renderer (`libSceGnmDriver`), gcn-recompiler (`3rdparty/gcn-recompiler`), host tests (`tests/host/run_host_tests.sh`), `tools/heavy_lock.sh`.

**Spec:** `docs/superpowers/specs/2026-10-25-infamous-second-son-bringup-design.md`

## Global Constraints

- English in the repository; no fake tests, no stubs that return 0, no game-specific code paths (AGENTS.md).
- Go: `go vet ./...`, `gofmt -l cmd pkg` (empty) and `go test ./...` pass after every Go change.
- Runtime and renderer: `bash tests/host/run_host_tests.sh` passes after every runtime change. It ends `host tests: PASS` (with the count of skipped game-fixture cases).
- Game data never enters the repository: inFAMOUS shader dumps, captures and memory snapshots are local fixtures under `tests/host/data/game/` (git-ignored); their tests print `SKIP: <case>: needs local fixture <path> (game data, not distributed)` without them.
- Automated runs use their own `PS4RECOMP_DATA_DIR` and cache dir, are time-bounded with the game killed by PID, watch WindowServer (stop at +300 MB RSS), never start while `pgrep -x eboot` finds the owner's game, and never touch real saves or `~/ps4recomp-work/tlou_build`, `~/ps4recomp-work/u4_build`.
- Heavy jobs (game builds, game runs, the host suite) run under `~/ps4recomp-work/tools/heavy_lock.sh`; one game at a time.
- inFAMOUS build dir: `~/ps4recomp-work/infamous_build`. App dir: `<your-inFAMOUS-dump>/CUSA00004`. Research dir: `~/ps4recomp-work/infamous_research`.
- No regression: every runtime or lifter change re-runs a 120 s TLOU route with fatal 0 and fps within noise of the last number. Every phase gate also runs a 120 s Uncharted 4 boot with fatal 0. Metal 3 stays the default backend; Metal 4 is checked at each phase gate.
- Downloads (reference footage, tools) are asked for first.
- The PC port github.com/HayatoG/iss_pc (CUSA00223 v1.07, no license) is a source of facts about the game only: its code is never copied. Notes: `~/ps4recomp-work/infamous_research/iss_pc_notes/FINDINGS.md`.

## Shared commands

These are used by several tasks. `$W` is `~/ps4recomp-work`, `$R` the worktree `$W/PS4Recomp-infamous`, and `$G` is `"<your-inFAMOUS-dump>/CUSA00004"`.

Build the generator and the game:

```bash
cd $R && go build -buildvcs=false -o ps4-recomp ./cmd/ps4-recomp
$W/tools/heavy_lock.sh ./ps4-recomp "$G/eboot.bin" --app-dir "$G" -o $W/infamous_build -c -j 6 > $W/infamous_research/gen.log 2>&1; echo gen=$?
```

Expected: `gen=0` and the log ends `All tasks completed successfully`.

Run the game time-bounded with `infamous_research/probe_run.sh`. It is created in Task 1, Step 1, from the recon script, with `B` pointing at `$W/infamous_build`:

```bash
$W/tools/heavy_lock.sh $W/infamous_research/probe_run.sh <tag> <seconds>
tail -5 $W/infamous_research/runs/<tag>/mon.txt; grep -n "FATAL\|abort stub\|Unresolved" $W/infamous_research/runs/<tag>/game.log | head
```

TLOU regression check: `tools/metal4_route.sh` with a build of this branch in `$W/infamous_research/tlou_check`:

```bash
cd $R && $W/tools/heavy_lock.sh ./ps4-recomp "<your-TLOU-dump>/CUSA00557/eboot.bin" \
  --app-dir "<your-TLOU-dump>/CUSA00557" -o $W/infamous_research/tlou_check -c -j 6 > $W/infamous_research/tlou_gen.log 2>&1
HEAVY_EXCLUSIVE=1 $W/tools/heavy_lock.sh env BUILD=$W/infamous_research/tlou_check TAG=iss_tlou_<task> SECS=120 EVERY=0 \
  OUT=$W/infamous_research/runs tools/metal4_route.sh
python3 tools/metal4_route_report.py $W/infamous_research/runs/iss_tlou_<task>.log
```

Expected: fatal 0, gpu_err 0, watchdog 0, and fps within ±3 of the previous TLOU check in the ledger (the first check sets the baseline).

---

## Phase 1: boot on the CPU side

### Task 1: Sync objects in guest memory

On Orbis a `ScePthreadMutex` (and Cond, Rwlock) variable holds a pointer to an object in the process's memory. FreeBSD libthr's `struct pthread_mutex` starts with a 32-byte `struct umutex`, followed by `m_flags` at +0x20: the type in the low byte, and `PMUTEX_FLAG_PRIVATE = 0x100`.

inFAMOUS's own `libc.prx` malloc replacement calls `scePthreadMutexInit` and then sets that flag directly. The code is at guest 0x819d815: `mov rax,[r15]; or dword [rax+0x20],0x100`.

Our runtime stores a tagged id `0x5EC0000000000000 | id<<3` in the variable, so the game dereferences a non-canonical value and crashes 6 s after start. Evidence: `$W/infamous_research/infamous-boot-recon.md` and `runs/r1/game.log`.

The fix gives every sync object a zeroed 0x80-byte slot in a guest-memory arena, and the handle is the slot's guest address. The lock state stays in the host tables, which are now indexed by slot.

**Files:**
- Create: `pkg/runtime/kernel/sync/ps4_sync_objects.h`, `pkg/runtime/kernel/sync/ps4_sync_objects.c`
- Modify: `pkg/runtime/kernel/sync/ps4_sync.c`. The handle helpers are at lines 19–51, `gm_id` at line 201, `shim_pthread_mutex_init` at 483–493 and `shim_pthread_mutex_destroy` at 558–585. The cond map is at 715–749, `shim_pthread_cond_destroy` at 840–858, the rwlock map at 860–889 and `shim_pthread_rwlock_destroy` at 957–975.
- Modify: `tests/host/runtime_stubs.h` (guard `ps4_sync_destroy`), `tests/host/run_host_tests.sh`
- Create: `tests/host/sync_objects_test.c`
- Create (outside the repo): `$W/infamous_research/probe_run.sh`. Copy the recon script with `B=$W/infamous_build`.

**Interfaces:**
- Produces (`ps4_sync_objects.h`):
  - `uint64_t sync_obj_alloc(GuestContext *ctx)`: a zeroed object; returns its guest address, or 0 when the arena is full or unmappable.
  - `int64_t sync_obj_slot(uint64_t v)`: the slot of the object at guest address `v`, or -1 if `v` is no live object address.
  - `void sync_obj_free(uint64_t v)`: returns a live object's slot; double frees and non-object values are ignored.
  - `uint64_t sync_obj_hash(uint64_t v)`: `v / SYNC_OBJ_STRIDE`, for hash buckets.
  - The constants `SYNC_OBJ_STRIDE` (0x80), `SYNC_OBJ_SLOTS` (1 << 20) and `SYNC_OBJ_MUTEX_FLAGS` (0x20).
- Consumes: `recomp_vm_alloc_named(GuestContext*, size_t, int prot, int flags, const char *name)` (`pkg/runtime/core/recomp_runtime.h`; returns `(uint64_t)-1` on failure).

- [ ] **Step 1: Write the failing test**

Create `tests/host/sync_objects_test.c`:

```c
// Host test of the guest-memory sync objects (ps4_sync_objects.c) and of the mutex, cond and
// rwlock shims on top of them (ps4_sync.c), against the real VM extent manager:
//  - scePthreadMutexInit stores the guest address of a zeroed object in the variable; the
//    object's m_flags (+0x20) holds the mutex type; the game may write into the object
//    (inFAMOUS's libc sets PMUTEX_FLAG_PRIVATE = 0x100 at +0x20) and the mutex still works;
//  - lock/unlock through a copy of the handle (another variable holding the same value) is the
//    same mutex; ERRORCHECK relock is EDEADLK (0x8002000b through scePthread*);
//  - destroy clears the variable and frees the slot, a second destroy is harmless, the next
//    init reuses the slot with a zeroed object;
//  - cond wait/signal between two threads and rwlock init/lock/unlock/destroy use the same objects;
//  - sync_obj_slot rejects 0, values outside the arena, misaligned values and freed slots.
#define RUNTIME_STUBS_HAVE_SYNC
#include "runtime_stubs.h"
#include "ps4_sync.h"
#include "ps4_sync_objects.h"
#include "ps4_threading.h"

#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>

RecompThread *recomp_get_current_thread(void) { return NULL; }

void shim_scePthreadMutexInit(GuestContext *ctx);
void shim_scePthreadMutexLock(GuestContext *ctx);
void shim_scePthreadMutexUnlock(GuestContext *ctx);
void shim_scePthreadMutexDestroy(GuestContext *ctx);
void shim_scePthreadMutexattrInit(GuestContext *ctx);
void shim_scePthreadMutexattrSettype(GuestContext *ctx);
void shim_scePthreadCondInit(GuestContext *ctx);
void shim_scePthreadCondWait(GuestContext *ctx);
void shim_scePthreadCondSignal(GuestContext *ctx);
void shim_scePthreadCondDestroy(GuestContext *ctx);
void shim_pthread_rwlock_init(GuestContext *ctx);
void shim_pthread_rwlock_wrlock(GuestContext *ctx);
void shim_pthread_rwlock_unlock(GuestContext *ctx);
void shim_pthread_rwlock_destroy(GuestContext *ctx);

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
// guest variables used by the test, below the VM range
#define VAR_MTX 0x1000
#define VAR_MTX_COPY 0x1008
#define VAR_ATTR 0x1010
#define VAR_COND 0x1018
#define VAR_RW 0x1020
#define VAR_NAME 0x1100
#define STACK_TOP 0x8000

static uint8_t *g_mem;

static GuestContext *new_ctx(void) {
  GuestContext *ctx = (GuestContext *)calloc(1, sizeof(GuestContext));
  ctx->mem_base = g_mem;
  ctx->mem_size = MEM_SIZE;
  ctx->process_ctx = ctx;
  ctx->thread_id = 1000;
  pthread_mutex_init(&ctx->vm_mutex, NULL);
  GuestVMExtent *root = (GuestVMExtent *)calloc(1, sizeof(GuestVMExtent));
  root->addr = VM_START;
  root->size = VM_SIZE;
  root->is_free = true;
  ctx->vm_extents = root;
  return ctx;
}

static uint64_t var(uint64_t addr) { return *(uint64_t *)(g_mem + addr); }

static int32_t call(GuestContext *ctx, void (*shim)(GuestContext *), uint64_t a1, uint64_t a2, uint64_t a3) {
  ctx->rsp = STACK_TOP;
  ctx->rdi = a1;
  ctx->rsi = a2;
  ctx->rdx = a3;
  shim(ctx);
  if (ctx->rsp != STACK_TOP + 8) {
    printf("FAIL: shim did not pop its return address\n");
    g_failures++;
  }
  return (int32_t)ctx->rax;
}

static void test_mutex_object(GuestContext *ctx) {
  strcpy((char *)g_mem + VAR_NAME, "malloc");
  CHECK(call(ctx, shim_scePthreadMutexattrInit, VAR_ATTR, 0, 0) == 0, "attr init");
  CHECK(call(ctx, shim_scePthreadMutexattrSettype, VAR_ATTR, 1, 0) == 0, "attr settype ERRORCHECK");
  CHECK(call(ctx, shim_scePthreadMutexInit, VAR_MTX, VAR_ATTR, VAR_NAME) == 0, "mutex init");
  const uint64_t h = var(VAR_MTX);
  CHECK(h >= VM_START && h + SYNC_OBJ_STRIDE <= VM_START + VM_SIZE, "handle 0x%llx is a guest address", (unsigned long long)h);
  CHECK(h % SYNC_OBJ_STRIDE == 0 && sync_obj_slot(h) >= 0, "handle is an object slot");
  uint32_t *flags = (uint32_t *)(g_mem + h + SYNC_OBJ_MUTEX_FLAGS);
  CHECK((*flags & 0xff) == 1, "m_flags type %u", *flags & 0xff);
  // what inFAMOUS's libc does right after init (guest 0x819d81c)
  *flags |= 0x100;
  CHECK(call(ctx, shim_scePthreadMutexLock, VAR_MTX, 0, 0) == 0, "lock");
  *(uint64_t *)(g_mem + VAR_MTX_COPY) = h;
  CHECK((uint32_t)call(ctx, shim_scePthreadMutexLock, VAR_MTX_COPY, 0, 0) == 0x8002000bu, "relock through a copy is EDEADLK");
  CHECK(call(ctx, shim_scePthreadMutexUnlock, VAR_MTX_COPY, 0, 0) == 0, "unlock through the copy");
  *(uint32_t *)(g_mem + h + 0x40) = 0xdeadbeef; // a word the next user of the slot must not see
  CHECK(call(ctx, shim_scePthreadMutexDestroy, VAR_MTX, 0, 0) == 0, "destroy");
  CHECK(var(VAR_MTX) == 0 && sync_obj_slot(h) < 0, "destroy clears the variable and frees the slot");
  CHECK(call(ctx, shim_scePthreadMutexDestroy, VAR_MTX, 0, 0) == 0, "second destroy");
  CHECK(call(ctx, shim_scePthreadMutexInit, VAR_MTX, 0, VAR_NAME) == 0, "init again");
  CHECK(var(VAR_MTX) == h, "the freed slot is reused");
  CHECK(*(uint32_t *)(g_mem + h + 0x40) == 0, "a reused object is zeroed");
  CHECK(*flags == 0, "m_flags of a mutex without attributes is type 0 (%#x)", *flags);
  CHECK(call(ctx, shim_scePthreadMutexDestroy, VAR_MTX, 0, 0) == 0, "destroy again");
}

static GuestContext *g_waiter_ctx;
static volatile int g_woken;

static void *waiter(void *arg) {
  (void)arg;
  GuestContext *ctx = g_waiter_ctx;
  call(ctx, shim_scePthreadMutexLock, VAR_MTX, 0, 0);
  while (!g_woken) call(ctx, shim_scePthreadCondWait, VAR_COND, VAR_MTX, 0);
  call(ctx, shim_scePthreadMutexUnlock, VAR_MTX, 0, 0);
  return NULL;
}

static void test_cond_and_rwlock(GuestContext *ctx) {
  CHECK(call(ctx, shim_scePthreadMutexInit, VAR_MTX, 0, VAR_NAME) == 0, "mutex init");
  CHECK(call(ctx, shim_scePthreadCondInit, VAR_COND, 0, VAR_NAME) == 0, "cond init");
  CHECK(sync_obj_slot(var(VAR_COND)) >= 0 && var(VAR_COND) != var(VAR_MTX), "cond is its own object");
  g_waiter_ctx = new_ctx();
  g_waiter_ctx->thread_id = 1001;
  pthread_t t;
  pthread_create(&t, NULL, waiter, NULL);
  usleep(20000);
  call(ctx, shim_scePthreadMutexLock, VAR_MTX, 0, 0);
  g_woken = 1;
  CHECK(call(ctx, shim_scePthreadCondSignal, VAR_COND, 0, 0) == 0, "signal");
  call(ctx, shim_scePthreadMutexUnlock, VAR_MTX, 0, 0);
  pthread_join(t, NULL);
  CHECK(call(ctx, shim_scePthreadCondDestroy, VAR_COND, 0, 0) == 0 && var(VAR_COND) == 0, "cond destroy");
  CHECK(call(ctx, shim_scePthreadMutexDestroy, VAR_MTX, 0, 0) == 0, "mutex destroy");

  CHECK(call(ctx, shim_pthread_rwlock_init, VAR_RW, 0, 0) == 0, "rwlock init");
  const uint64_t rw = var(VAR_RW);
  CHECK(sync_obj_slot(rw) >= 0, "rwlock handle is an object");
  CHECK(call(ctx, shim_pthread_rwlock_wrlock, VAR_RW, 0, 0) == 0, "wrlock");
  CHECK(call(ctx, shim_pthread_rwlock_unlock, VAR_RW, 0, 0) == 0, "unlock");
  CHECK(call(ctx, shim_pthread_rwlock_destroy, VAR_RW, 0, 0) == 0 && sync_obj_slot(rw) < 0, "rwlock destroy frees");
}

static void test_slot_rejects(void) {
  CHECK(sync_obj_slot(0) < 0, "0");
  CHECK(sync_obj_slot(0x5EC0000000000008ULL) < 0, "an old tagged id");
  CHECK(sync_obj_slot(VAR_MTX) < 0, "an address below the arena");
}

int main(void) {
  g_mem = (uint8_t *)mmap(NULL, MEM_SIZE, PROT_READ | PROT_WRITE, MAP_ANON | MAP_PRIVATE | MAP_NORESERVE, -1, 0);
  if (g_mem == MAP_FAILED) return 2;
  GuestContext *ctx = new_ctx();
  test_slot_rejects();
  test_mutex_object(ctx);
  test_cond_and_rwlock(ctx);
  const uint64_t a = sync_obj_alloc(ctx);
  CHECK(sync_obj_slot(a + 8) < 0, "a misaligned value");
  sync_obj_free(a);
  sync_obj_free(a);
  CHECK(sync_obj_alloc(ctx) == a, "a double free does not push the slot twice");
  CHECK(sync_obj_alloc(ctx) != a, "the next object is another slot");
  if (g_failures) {
    printf("sync_objects_test: %d failure(s)\n", g_failures);
    return 1;
  }
  printf("sync_objects_test: PASS\n");
  return 0;
}
```

In `tests/host/runtime_stubs.h`, replace the line `void ps4_sync_destroy(void) {}` with:

```c
#ifndef RUNTIME_STUBS_HAVE_SYNC // a test that links ps4_sync.c defines it
void ps4_sync_destroy(void) {}
#endif
```

In `tests/host/run_host_tests.sh`, after the `sem_timedwait_test` lines (the line `"$T/sem_timedwait_test"`), add:

```bash
# Sync objects in guest memory (ps4_sync_objects.c) under the mutex, cond and rwlock shims.
clang -std=gnu11 -Wall -Werror -g "${RT[@]}" "$R/tests/host/sync_objects_test.c" "$R/pkg/runtime/kernel/sync/ps4_sync.c" \
  "$R/pkg/runtime/kernel/sync/ps4_sync_objects.c" "$R/pkg/runtime/core/recomp_runtime.c" -o "$T/sync_objects_test"
"$T/sync_objects_test" | grep -v '^\[ps4'
```

Copy `$W/infamous_research/probe_run.sh` from the recon version, set `B=$W/infamous_build` and `chmod +x` it. It is outside the repository and not committed.

- [ ] **Step 2: Run the test to verify it fails**

Run this one compile, the same command the suite uses:

```bash
cd $R && RT=(); while IFS= read -r d; do RT+=(-I "$d"); done < <(find pkg/runtime -type d)
clang -std=gnu11 -Wall -Werror -g "${RT[@]}" tests/host/sync_objects_test.c pkg/runtime/kernel/sync/ps4_sync.c \
  pkg/runtime/kernel/sync/ps4_sync_objects.c pkg/runtime/core/recomp_runtime.c -o /tmp/sync_objects_test
```

Expected: FAIL. The compile error is `'ps4_sync_objects.h' file not found`.

- [ ] **Step 3: Write `ps4_sync_objects.h` and `ps4_sync_objects.c`**

`pkg/runtime/kernel/sync/ps4_sync_objects.h`:

```c
// Guest-visible objects behind ScePthreadMutex, ScePthreadCond and ScePthreadRwlock handles.
//
// On Orbis such a variable holds a pointer to an object in the process's memory, and game
// libraries write into it: FreeBSD libthr's struct pthread_mutex starts with a 32-byte
// struct umutex followed by m_flags (the type in the low byte, PMUTEX_FLAG_PRIVATE = 0x100),
// and inFAMOUS Second Son's libc malloc sets that flag right after scePthreadMutexInit. So
// every sync object is a zeroed SYNC_OBJ_STRIDE-byte slot of an arena in guest memory, and the
// handle is the slot's guest address. The lock state lives in the host tables of ps4_sync.c,
// indexed by slot.
#ifndef PS4_SYNC_OBJECTS_H
#define PS4_SYNC_OBJECTS_H

#include <stdint.h>
#include "recomp_runtime.h"

#define SYNC_OBJ_STRIDE 0x80ULL
#define SYNC_OBJ_SLOTS (1ULL << 20)
#define SYNC_OBJ_MUTEX_FLAGS 0x20 // libthr struct pthread_mutex: m_flags

// A zeroed object: its guest address, or 0 when the arena is full or cannot be mapped.
uint64_t sync_obj_alloc(GuestContext *ctx);
// The slot of the live object at guest address v, or -1 when v is not one.
int64_t sync_obj_slot(uint64_t v);
// Frees the live object at v; anything else (0, a freed slot, another value) is ignored.
void sync_obj_free(uint64_t v);
// Spreads object addresses over hash buckets (the low bits of an address are all zero).
static inline uint64_t sync_obj_hash(uint64_t v) { return v / SYNC_OBJ_STRIDE; }

#endif
```

`pkg/runtime/kernel/sync/ps4_sync_objects.c`:

```c
#include "ps4_sync_objects.h"

#include <pthread.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>

static pthread_mutex_t g_lock = PTHREAD_MUTEX_INITIALIZER;
static _Atomic uint64_t g_base; // guest address of the arena; 0 until the first object
static uint8_t *g_host;         // the arena in host memory
static uint64_t g_next;         // slots from here on were never used
static uint32_t *g_free;        // freed slots, a stack
static uint64_t g_nfree;
static _Atomic uint8_t *g_live; // 1 per slot holding a live object

uint64_t sync_obj_alloc(GuestContext *ctx) {
  pthread_mutex_lock(&g_lock);
  uint64_t base = atomic_load_explicit(&g_base, memory_order_relaxed);
  if (!base) {
    const uint64_t a = recomp_vm_alloc_named(ctx, SYNC_OBJ_STRIDE * SYNC_OBJ_SLOTS, PROT_READ | PROT_WRITE, 0,
                                             "sync_objects");
    g_free = (uint32_t *)malloc(sizeof(uint32_t) * SYNC_OBJ_SLOTS);
    g_live = (_Atomic uint8_t *)calloc(SYNC_OBJ_SLOTS, 1);
    if (a == (uint64_t)-1 || !g_free || !g_live) {
      pthread_mutex_unlock(&g_lock);
      return 0;
    }
    g_host = ctx->mem_base + a;
    base = a;
    atomic_store_explicit(&g_base, base, memory_order_release);
  }
  uint64_t slot;
  if (g_nfree) {
    slot = g_free[--g_nfree];
  } else if (g_next < SYNC_OBJ_SLOTS) {
    slot = g_next++;
  } else {
    pthread_mutex_unlock(&g_lock);
    return 0;
  }
  memset(g_host + slot * SYNC_OBJ_STRIDE, 0, SYNC_OBJ_STRIDE);
  atomic_store_explicit(&g_live[slot], 1, memory_order_release);
  pthread_mutex_unlock(&g_lock);
  return base + slot * SYNC_OBJ_STRIDE;
}

int64_t sync_obj_slot(uint64_t v) {
  const uint64_t base = atomic_load_explicit(&g_base, memory_order_acquire);
  if (!base || v < base) return -1;
  const uint64_t off = v - base;
  if (off >= SYNC_OBJ_STRIDE * SYNC_OBJ_SLOTS || off % SYNC_OBJ_STRIDE) return -1;
  const uint64_t slot = off / SYNC_OBJ_STRIDE;
  return atomic_load_explicit(&g_live[slot], memory_order_acquire) ? (int64_t)slot : -1;
}

void sync_obj_free(uint64_t v) {
  pthread_mutex_lock(&g_lock);
  const int64_t slot = sync_obj_slot(v);
  if (slot >= 0) {
    atomic_store_explicit(&g_live[slot], 0, memory_order_release);
    g_free[g_nfree++] = (uint32_t)slot;
  }
  pthread_mutex_unlock(&g_lock);
}
```

- [ ] **Step 4: Switch `ps4_sync.c` to the objects**

1. Add `#include "ps4_sync_objects.h"` after `#include "ps4_sync.h"`.
2. Replace the comment block and code from `// Guest sync objects are identified by the value stored` through the end of `sync_handle_take` (lines 19–51) with:

```c
// Guest sync objects are identified by the value stored in the guest handle variable, not by
// its address: games copy handles around (e.g. Scream passes the address of a stack copy to
// scePthreadMutexUnlock). The value is the guest address of the object (ps4_sync_objects.h).
// Init stores a fresh object in the variable; an uninitialized (static initializer, 0) variable
// is given one on first use.
static pthread_mutex_t g_sync_handle_lock = PTHREAD_MUTEX_INITIALIZER;

static uint64_t sync_handle(GuestContext *ctx, uint64_t addr, int fresh) {
  if (!addr) return 0;
  uint64_t *p = (uint64_t *)(ctx->mem_base + addr);
  uint64_t v = __atomic_load_n(p, __ATOMIC_ACQUIRE);
  if (!fresh && sync_obj_slot(v) >= 0) return v;
  pthread_mutex_lock(&g_sync_handle_lock);
  v = *p;
  if (fresh || sync_obj_slot(v) < 0) {
    v = sync_obj_alloc(ctx);
    if (!v) {
      fprintf(stderr, "FATAL: no guest memory for sync objects (%llu in use at most)\n",
              (unsigned long long)SYNC_OBJ_SLOTS);
      abort();
    }
    __atomic_store_n(p, v, __ATOMIC_RELEASE);
  }
  pthread_mutex_unlock(&g_sync_handle_lock);
  return v;
}

// Returns the object held by the guest variable (0 if none) and clears the variable.
static uint64_t sync_handle_take(GuestContext *ctx, uint64_t addr) {
  if (!addr) return 0;
  uint64_t *p = (uint64_t *)(ctx->mem_base + addr);
  uint64_t v = __atomic_exchange_n(p, 0, __ATOMIC_ACQ_REL);
  return sync_obj_slot(v) >= 0 ? v : 0;
}
```

3. Replace `gm_id` (line 201) with the line below. Slot k is id k + 1, and a NULL handle keeps id 0, as before:

```c
static inline uint64_t gm_id(uint64_t handle) {
  const int64_t slot = sync_obj_slot(handle);
  return slot >= 0 ? (uint64_t)slot + 1 : 0;
}
```

4. In `shim_pthread_mutex_init`, replace `(void)get_host_mutex_with_type(sync_handle(ctx, mtx_addr, 1), guest_type);` with the code below. libthr keeps the type in m_flags' low byte:

```c
  const uint64_t h = sync_handle(ctx, mtx_addr, 1);
  (void)get_host_mutex_with_type(h, guest_type);
  *(uint32_t *)(ctx->mem_base + h + SYNC_OBJ_MUTEX_FLAGS) = (uint32_t)guest_type & 0xff;
```

5. In `shim_pthread_mutex_destroy`, after `pthread_mutex_unlock(&g_mutex_map_lock);`, add `sync_obj_free(handle);`. Then:
   - in `shim_pthread_cond_destroy`, after `pthread_mutex_unlock(&g_cond_map_lock);`, add `sync_obj_free(cond_addr);`;
   - in `shim_pthread_rwlock_destroy`, after `pthread_mutex_unlock(&g_rwlock_map_lock);`, add `sync_obj_free(rw_addr);`.
6. The hash buckets: there are four sites for each map. In `get_host_cond` and `shim_pthread_cond_destroy`, replace `(cond_addr >> 3) % COND_MAP_SIZE` / `(guest_addr >> 3) % COND_MAP_SIZE` with `sync_obj_hash(<same variable>) % COND_MAP_SIZE`. In `get_host_rwlock` and `shim_pthread_rwlock_destroy`, replace `(... >> 3) % RWLOCK_MAP_SIZE` the same way. In `gm_get_locked` and `shim_pthread_mutex_destroy`, replace `(handle >> 3) % MUTEX_MAP_SIZE` with `sync_obj_hash(handle) % MUTEX_MAP_SIZE`.
7. Check that nothing else uses the old tag: `grep -n "SYNC_HANDLE\|0x5EC0" pkg/runtime -r` prints nothing.

- [ ] **Step 5: Run the test and the suite**

```bash
cd $R && clang -std=gnu11 -Wall -Werror -g "${RT[@]}" tests/host/sync_objects_test.c pkg/runtime/kernel/sync/ps4_sync.c \
  pkg/runtime/kernel/sync/ps4_sync_objects.c pkg/runtime/core/recomp_runtime.c -o /tmp/sync_objects_test && /tmp/sync_objects_test | grep -v '^\[ps4'
$W/tools/heavy_lock.sh bash tests/host/run_host_tests.sh > $W/infamous_research/host_t1.log 2>&1; echo host=$?; tail -1 $W/infamous_research/host_t1.log
```

Expected: `sync_objects_test: PASS`, `host=0`, and a last line starting `host tests: PASS`.

- [ ] **Step 6: Check in the game and in TLOU**

Rebuild inFAMOUS (Shared commands) and run `probe_run.sh t1 120`. Expected: the game gets past the crash at `fn_0x819cfc0`; `game.log` has no `FATAL: Signal 11` with a fault address `0x5ec0…`. Record the new first failure (or 120 s without one) in the ledger. Run the TLOU regression check with tag `iss_tlou_t1`. Expected: fatal 0 and fps within ±3 of 98.

- [ ] **Step 7: Commit**

```bash
git add pkg/runtime/kernel/sync/ps4_sync_objects.h pkg/runtime/kernel/sync/ps4_sync_objects.c pkg/runtime/kernel/sync/ps4_sync.c \
  tests/host/sync_objects_test.c tests/host/runtime_stubs.h tests/host/run_host_tests.sh
git commit -m "sync: pthread objects live in guest memory; handles are their addresses

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

### Task 2: The unresolved imports the game links

`hle_report.txt` lists five imports bound to the abort stub. This task implements the four whose console behaviour is known. `sigreturn` is implemented only once a run reaches it: its behaviour depends on how the game uses it (Task 5 rules on it then).

- `sigfillset(sigset_t *set)`: FreeBSD's `sigset_t` is four 32-bit words. All bits are set; the call returns 0, or -1 with errno EINVAL (22) for NULL.
- `sceNpSetNpTitleId(const SceNpTitleId *id, const SceNpTitleSecret *secret)`: the title id (12 characters plus NUL and padding, 16 bytes) and the 128-byte secret are kept for later Np requests. It returns 0, or `ORBIS_NP_ERROR_INVALID_ARGUMENT` for a NULL id or secret.
- `sceNpRegisterGamePresenceCallbackA(callback, userdata)`: it registers and returns a callback id ≥ 1. A NULL callback is `ORBIS_NP_ERROR_INVALID_ARGUMENT`. While signed out there is no presence, so the callback is never called; `sceNpCheckCallback` dispatches nothing for it.
- `scePlayGoSetToDoList(handle, const ScePlayGoToDo *list, uint32_t numEntries)`: every chunk is installed, so the order of a to-do list changes nothing. A NULL list with `numEntries > 0` is an error. The module's convention is `-EINVAL`, as in `scePlayGoGetToDoList`. Otherwise it returns 0.

**Files:**
- Create: `pkg/runtime/kernel/syscalls/ps4_sigset.c`, `pkg/runtime/kernel/syscalls/ps4_sigset.h`
- Modify: `pkg/runtime/modules/libSceNp/ps4_np.c`, `pkg/runtime/modules/libSceNp/ps4_np.h`, `pkg/runtime/modules/libScePlayGo/ps4_playgo.c`, `pkg/runtime/modules/libScePlayGo/ps4_playgo.h`
- Modify: `pkg/emitter/shims.go` (`knownDirectShims`: add `"sigfillset"` after `"sigprocmask"`, `"sceNpSetNpTitleId"` and `"sceNpRegisterGamePresenceCallbackA"` after `"sceNpCheckCallback"`, and `"scePlayGoSetToDoList"` after `"scePlayGoGetToDoList"`)
- Test: `pkg/emitter/shim_test.go` (new `TestInfamousBootImportShims`), `tests/host/boot_hle_test.c` (the Np pair), new `tests/host/playgo_sigset_test.c`, `tests/host/run_host_tests.sh`

**Interfaces:**
- Produces:
  - `void shim_sigfillset(GuestContext*)`;
  - `void shim_sceNpSetNpTitleId(GuestContext*)`;
  - `void shim_sceNpRegisterGamePresenceCallbackA(GuestContext*)`;
  - `void shim_scePlayGoSetToDoList(GuestContext*)`;
  - `int ps4_np_title_id(char out[13])`, for tests: 1 once a title id is set, and the id is copied out.

- [ ] **Step 1: Write the failing Go test**

In `pkg/emitter/shim_test.go`, add:

```go
// The imports inFAMOUS Second Son (CUSA00004) links that had no shim: each NID resolves to its shim.
func TestInfamousBootImportShims(t *testing.T) {
	for _, name := range []string{"sigfillset", "sceNpSetNpTitleId", "sceNpRegisterGamePresenceCallbackA", "scePlayGoSetToDoList"} {
		got, ok := LookupShim(name)
		if !ok || got != "shim_"+name {
			t.Errorf("LookupShim(%q) = %q, %v; want shim_%s", name, got, ok, name)
		}
	}
}
```

Run: `cd $R && go test ./pkg/emitter -run TestInfamousBootImportShims`. Expected: FAIL. The four names are not found.

- [ ] **Step 2: Write the failing host tests**

Append to `tests/host/boot_hle_test.c`, before `int main`:

```c
void shim_sceNpSetNpTitleId(GuestContext *ctx);
void shim_sceNpRegisterGamePresenceCallbackA(GuestContext *ctx);

// inFAMOUS: the title id is kept; presence callbacks register while signed out.
static void test_np_title_and_presence(void) {
  char *id = (char *)g_mem + 0x5000;
  memset(id, 0, 16);
  memcpy(id, "CUSA00004_00", 12);
  memset(g_mem + 0x5100, 0xab, 128);
  CHECK(call(shim_sceNpSetNpTitleId, 0, 0x5100, 0) == (int32_t)ORBIS_NP_ERROR_INVALID_ARGUMENT, "NULL title id");
  CHECK(call(shim_sceNpSetNpTitleId, 0x5000, 0, 0) == (int32_t)ORBIS_NP_ERROR_INVALID_ARGUMENT, "NULL secret");
  CHECK(call(shim_sceNpSetNpTitleId, 0x5000, 0x5100, 0) == 0, "set title id");
  char got[13];
  CHECK(ps4_np_title_id(got) == 1 && !strcmp(got, "CUSA00004_00"), "title id kept");
  CHECK(call(shim_sceNpRegisterGamePresenceCallbackA, 0, 0, 0) == (int32_t)ORBIS_NP_ERROR_INVALID_ARGUMENT, "NULL callback");
  const int32_t a = call(shim_sceNpRegisterGamePresenceCallbackA, 0x6000, 0x6100, 0);
  const int32_t b = call(shim_sceNpRegisterGamePresenceCallbackA, 0x6000, 0x6200, 0);
  CHECK(a >= 1 && b >= 1 && a != b, "callback ids %d %d", a, b);
}
```

Then call `test_np_title_and_presence();` in `main` before the failure check. If `boot_hle_test.c` names its memory differently from `g_mem`, use its name: it defines `MEM_SIZE 0x100000` and a context `g_ctx` over a static buffer.

Create `tests/host/playgo_sigset_test.c`:

```c
// Host test of sigfillset (FreeBSD sigset_t: four 32-bit words) and scePlayGoSetToDoList,
// called through the guest ABI.
#include "ps4_playgo.h"
#include "ps4_sigset.h"

#include <stdio.h>
#include <string.h>

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
static uint8_t g_mem[MEM_SIZE];
static GuestContext g_ctx;

static int64_t call(void (*shim)(GuestContext *), uint64_t a1, uint64_t a2, uint64_t a3) {
  g_ctx.rsp = 0x1000;
  g_ctx.rdi = a1;
  g_ctx.rsi = a2;
  g_ctx.rdx = a3;
  shim(&g_ctx);
  if (g_ctx.rsp != 0x1008) {
    printf("FAIL: shim did not pop its return address\n");
    g_failures++;
  }
  return (int64_t)g_ctx.rax;
}

int main(void) {
  g_ctx.mem_base = g_mem;
  g_ctx.mem_size = MEM_SIZE;
  g_ctx.fs_base = 0x400;
  uint32_t *set = (uint32_t *)(g_mem + 0x2000);
  memset(set, 0, 16);
  set[4] = 0x12345678; // the word after the set must not change
  CHECK(call(shim_sigfillset, 0x2000, 0, 0) == 0, "sigfillset");
  CHECK(set[0] == 0xffffffffu && set[1] == 0xffffffffu && set[2] == 0xffffffffu && set[3] == 0xffffffffu,
        "all 128 bits set");
  CHECK(set[4] == 0x12345678u, "no write past the set");
  CHECK((int32_t)call(shim_sigfillset, 0, 0, 0) == -1, "NULL set");
  CHECK(*(int *)(g_mem + g_ctx.fs_base + 0x100) == 22, "errno EINVAL");

  uint32_t handle_var = 0;
  memcpy(g_mem + 0x3000, &handle_var, 4);
  CHECK(call(shim_scePlayGoOpen, 0x3000, 0, 0) == 0, "open");
  const uint32_t h = *(uint32_t *)(g_mem + 0x3000);
  OrbisPlayGoToDo *todo = (OrbisPlayGoToDo *)(g_mem + 0x3100);
  todo[0].chunkId = 3;
  todo[0].locus = ORBIS_PLAYGO_LOCUS_LOCAL_FAST;
  CHECK(call(shim_scePlayGoSetToDoList, h, 0x3100, 1) == 0, "set a to-do list");
  CHECK(call(shim_scePlayGoSetToDoList, h, 0, 0) == 0, "empty list");
  CHECK((int32_t)call(shim_scePlayGoSetToDoList, h, 0, 2) == -EINVAL, "NULL list with entries");
  uint32_t n = 99;
  memcpy(g_mem + 0x3200, &n, 4);
  g_ctx.rcx = 0x3200;
  CHECK(call(shim_scePlayGoGetToDoList, h, 0x3100, 4) == 0 && *(uint32_t *)(g_mem + 0x3200) == 0,
        "nothing left to install after a to-do list");
  if (g_failures) {
    printf("playgo_sigset_test: %d failure(s)\n", g_failures);
    return 1;
  }
  printf("playgo_sigset_test: PASS\n");
  return 0;
}
```

In `tests/host/run_host_tests.sh`, after the `boot_hle_test` run line, add:

```bash
# sigfillset and scePlayGoSetToDoList through the guest ABI (inFAMOUS boot imports).
clang -std=gnu11 -Wall -Werror -g "${RT[@]}" "$R/tests/host/playgo_sigset_test.c" "$M/libScePlayGo/ps4_playgo.c" \
  "$R/pkg/runtime/kernel/syscalls/ps4_sigset.c" -o "$T/playgo_sigset_test"
"$T/playgo_sigset_test"
```

Run the host suite. Expected: FAIL at the compile of `boot_hle_test` (`shim_sceNpSetNpTitleId` undeclared) or of `playgo_sigset_test` (`ps4_sigset.h` not found).

- [ ] **Step 3: Implement**

`pkg/runtime/kernel/syscalls/ps4_sigset.h`:

```c
#ifndef PS4_SIGSET_H
#define PS4_SIGSET_H
#include "recomp_runtime.h"
// FreeBSD sigset_t operations on the guest's four-word set.
void shim_sigfillset(GuestContext *ctx);
#endif
```

`pkg/runtime/kernel/syscalls/ps4_sigset.c`:

```c
#include "ps4_sigset.h"

#include <stdint.h>

#define GUEST_SIGSET_WORDS 4 // FreeBSD: struct __sigset { __uint32_t __bits[4]; }
#define GUEST_EINVAL 22

// sigfillset(set): every signal in the set; -1 with errno EINVAL for NULL.
void shim_sigfillset(GuestContext *ctx) {
  const uint64_t set = ctx->rdi;
  if (!set) {
    *(int *)(ctx->mem_base + ctx->fs_base + 0x100) = GUEST_EINVAL;
    ctx->rax = (uint64_t)-1;
    SHIM_RETURN();
  }
  uint32_t *bits = (uint32_t *)(ctx->mem_base + set);
  for (int i = 0; i < GUEST_SIGSET_WORDS; i++) bits[i] = 0xffffffffu;
  ctx->rax = 0;
  SHIM_RETURN();
}
```

Check that the guest errno slot is `fs_base + 0x100` the way `set_guest_errno` (`ps4_syscalls.c`) writes it. If `set_guest_errno` is exported from a header, call it instead of writing the slot.

In `ps4_np.c`, after `sceNpCheckCallback`:

```c
// sceNpSetNpTitleId: the title id (12 characters, 16 bytes with padding) and its 128-byte
// secret identify the title to later Np requests.
static char g_np_title_id[13];
static uint8_t g_np_title_secret[128];
static int g_np_title_set;

int ps4_np_title_id(char out[13]) {
  if (!g_np_title_set) return 0;
  memcpy(out, g_np_title_id, sizeof g_np_title_id);
  return 1;
}

void shim_sceNpSetNpTitleId(GuestContext *ctx) {
  if (!ctx->rdi || !ctx->rsi) {
    ctx->rax = (uint64_t)(int64_t)ORBIS_NP_ERROR_INVALID_ARGUMENT;
    SHIM_RETURN();
  }
  memcpy(g_np_title_id, ctx->mem_base + ctx->rdi, 12);
  g_np_title_id[12] = 0;
  memcpy(g_np_title_secret, ctx->mem_base + ctx->rsi, sizeof g_np_title_secret);
  g_np_title_set = 1;
  ctx->rax = 0;
  SHIM_RETURN();
}

// sceNpRegisterGamePresenceCallbackA: registered with a fresh id. While signed out there is no
// game presence, so the callback is never called.
static int32_t g_np_presence_next = 1;

void shim_sceNpRegisterGamePresenceCallbackA(GuestContext *ctx) {
  if (!ctx->rdi) {
    ctx->rax = (uint64_t)(int64_t)ORBIS_NP_ERROR_INVALID_ARGUMENT;
    SHIM_RETURN();
  }
  ctx->rax = (uint64_t)(int64_t)__atomic_fetch_add(&g_np_presence_next, 1, __ATOMIC_RELAXED);
  SHIM_RETURN();
}
```

Declare `ps4_np_title_id` and both shims in `ps4_np.h`, and include `<string.h>` in `ps4_np.c` if it is not already included.

In `ps4_playgo.c`, after `scePlayGoGetToDoList`:

```c
// Every chunk is installed, so a to-do list (the order to install chunks in) changes nothing.
int32_t scePlayGoSetToDoList(OrbisPlayGoHandle handle, const OrbisPlayGoToDo *toDoList, uint32_t numEntries) {
    (void)handle;
    if (!toDoList && numEntries > 0) {
        return -EINVAL;
    }
    return 0;
}
```

Its shim goes after `shim_scePlayGoGetToDoList`:

```c
void shim_scePlayGoSetToDoList(GuestContext *ctx) {
    OrbisPlayGoHandle handle = (OrbisPlayGoHandle)ctx->rdi;
    uint64_t toDoGuest = ctx->rsi;
    uint32_t numEntries = (uint32_t)ctx->rdx;
    const OrbisPlayGoToDo *toDo = toDoGuest ? (const OrbisPlayGoToDo *)(ctx->mem_base + toDoGuest) : NULL;
    int32_t ret = scePlayGoSetToDoList(handle, toDo, numEntries);
    ctx->rax = (uint64_t)(int64_t)ret;
    SHIM_RETURN();
}
```

Declare both in `ps4_playgo.h`. Add the four names to `knownDirectShims` in `shims.go` at the places listed under Files.

- [ ] **Step 4: Verify**

```bash
cd $R && go test ./pkg/emitter -run TestInfamousBootImportShims && go vet ./... && gofmt -l cmd pkg && go test ./...
$W/tools/heavy_lock.sh bash tests/host/run_host_tests.sh > $W/infamous_research/host_t2.log 2>&1; echo host=$?; tail -1 $W/infamous_research/host_t2.log
```

Expected: the Go tests pass, `gofmt` prints nothing, `host=0`. Rebuild inFAMOUS. `gen.log` reports `Unresolved imports bound to the abort stub: 1 calls` (only `sigreturn`).

- [ ] **Step 5: Commit**

```bash
git add pkg/runtime/kernel/syscalls/ps4_sigset.c pkg/runtime/kernel/syscalls/ps4_sigset.h pkg/runtime/modules/libSceNp/ps4_np.c \
  pkg/runtime/modules/libSceNp/ps4_np.h pkg/runtime/modules/libScePlayGo/ps4_playgo.c pkg/runtime/modules/libScePlayGo/ps4_playgo.h \
  pkg/emitter/shims.go pkg/emitter/shim_test.go tests/host/boot_hle_test.c tests/host/playgo_sigset_test.c tests/host/run_host_tests.sh
git commit -m "hle: sigfillset, sceNpSetNpTitleId, sceNpRegisterGamePresenceCallbackA, scePlayGoSetToDoList

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

### Task 3: New threads inherit the creator's MXCSR and x87 control word

FreeBSD's `cpu_copy_thread` (amd64), which runs at `thr_new` under libthr's `pthread_create`, copies
the creating thread's user FPU state into the new thread. The control words come with it: MXCSR
(rounding, FTZ, DAZ, exception masks) and the x87 control word.

According to the PC port, inFAMOUS relies on this. It sets MXCSR.FTZ in one thread and creates its
job workers from it. Without FTZ the particle and light code divides by denormals, and fire and smoke
are overexposed and headlights flicker (FINDINGS.md, from `port/src/runtime_thread.c`).

`recomp_create_thread_context` (`pkg/runtime/core/recomp_runtime.c`, near line 1404) sets the
defaults (`fpu_cw = 0x037F`, `mxcsr = 0x1F80`) instead. The guest entry trampoline already maps
`ctx->mxcsr` to FPCR RMode/FZ (`pkg/emitter/asm_trampoline.go:138`). Copying the creator's values is
therefore enough.

`ctx->mxcsr` of the creator is current: the lifted LDMXCSR stores it (`pkg/lifter/arm64_lifter_ext.go`).

**Files:**
- Modify: `pkg/runtime/core/recomp_runtime.c`, in `recomp_create_thread_context`, the two lines `t_ctx->fpu_cw = 0x037F;` and `t_ctx->mxcsr = 0x1F80;`
- Create: `tests/host/thread_fpstate_test.c`
- Modify: `tests/host/run_host_tests.sh`

**Interfaces:**
- Consumes: `GuestContext *recomp_create_thread_context(GuestContext *parent, uint64_t stack_size)` (`recomp_runtime.h`).

- [ ] **Step 1: Write the failing test**

`tests/host/thread_fpstate_test.c`:

```c
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
```

In `tests/host/run_host_tests.sh`, after the `kernel_vmfree_test` run line, add:

```bash
# New thread contexts inherit the creator's MXCSR and x87 control word (FreeBSD cpu_copy_thread).
clang -std=gnu11 -Wall -Werror -g "${RT[@]}" "$R/tests/host/thread_fpstate_test.c" "$R/pkg/runtime/core/recomp_runtime.c" \
  -o "$T/thread_fpstate_test"
"$T/thread_fpstate_test" | grep -v '^\[ps4'
```

If `recomp_create_thread_context` needs more of the process context (`tls_*`, TCB placement), set
those fields in `new_parent` the way `recomp_runtime.c` sets them for the main thread. Look for the
caller that creates the main thread's context.

- [ ] **Step 2: Run it to verify it fails**

Run the suite or the single compile. Expected: `FAIL ... MXCSR inherited (got 0x1f80)` and `x87 control word inherited (got 0x37f)`.

- [ ] **Step 3: Implement**

In `recomp_create_thread_context`, replace

```c
  t_ctx->fpu_cw = 0x037F;
  t_ctx->mxcsr = 0x1F80; // x86 default: all exceptions masked, round to nearest
```

with

```c
  // The creator's control words, as FreeBSD's cpu_copy_thread copies the user FPU state at
  // thr_new; the guest entry trampoline applies mxcsr to FPCR (RMode, FZ).
  t_ctx->fpu_cw = parent->fpu_cw;
  t_ctx->mxcsr = parent->mxcsr;
```

Check that the main thread's context still starts at 0x1F80 / 0x037F (`recomp_runtime.c:369` sets
`ctx->mxcsr` for the main context). Check that a parent context created with `calloc` elsewhere,
with mxcsr 0, is not a creator: grep the callers of `recomp_create_thread_context`. Each passes the
creating guest thread's ctx.

- [ ] **Step 4: Verify**

Run the host suite (expected `host=0`), rebuild inFAMOUS, and run `probe_run.sh t3 120`. Expected: no
new failure compared with the run after Task 2. Then run the TLOU regression check with tag
`iss_tlou_t3`: fatal 0 and fps within ±3, and the screenshots match those of the previous check by
eye (TLOU's threads may now start with FTZ too).

- [ ] **Step 5: Commit**

```bash
git add pkg/runtime/core/recomp_runtime.c tests/host/thread_fpstate_test.c tests/host/run_host_tests.sh
git commit -m "threads: a new thread starts with its creator's MXCSR and x87 control word

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

### Task 4: SSE4A sites in the eboot

The PC port counts 96 SSE4A sites (EXTRQ/INSERTQ, register and immediate forms) in the US 1.07 code
(FINDINGS.md, `port/docs/isa_rewrite.md`). Our code is the same as 1.07 at least where checked: the
port's 13 F16C sites at 0x612da8–0x61300e appear at exactly those addresses in our build (10 of them
lifted).

Our generation decoded no EXTRQ/INSERTQ, and also no VMREAD/VMWRITE (what `0F 78/79` means without
SSE4A). The eboot file has 73 occurrences of the bytes `66 0F 79`. golang.org/x/arch x86asm may not
know AMD's SSE4A. A reachable site would then be decoded as something else, or would cut a function
short, silently.

The scan must explain the 96.

**Files:**
- No new command: the check is a one-off scan (outside the repository) recorded in the ledger, and Go tests if the decoder or lifter changes
- Modify: `pkg/disasm` and `pkg/lifter` only if the scan finds reachable sites
- Test: `pkg/lifter/arm64_sse4a_test.go` (only if a lifter change is needed)

- [ ] **Step 1: Scan.** Write a throwaway Go program under `$W/infamous_research/sse4a_scan/` (outside the repository). It:
  - loads the eboot with `pkg/elfloader`;
  - for every executable segment, finds `66 0F 78`, `66 0F 79`, `F2 0F 78` and `F2 0F 79`;
  - reports, for each hit, whether the address is an instruction boundary inside a function that generation discovered. Use `build_probe`'s `code_*.s` guest-address comments (`// 0x<addr>:`) as the list of lifted instruction addresses.

  Expected output: the count of hits in executable segments and the count on lifted instruction boundaries.
- [ ] **Step 2: Rule.**
  - **0 hits on lifted boundaries:** record "SSE4A not reachable in CUSA00004 v01.00 code (N byte matches, all data or mid-instruction)" in the ledger and in the recon file. The task ends without a code change.
  - **Otherwise:** add EXTRQ and INSERTQ (both the imm and the register forms) to the decoder and the lifter, TDD, in the style of the F16C lifting in `pkg/lifter/arm64_lifter_fp.go:1278–1300`:
    - semantics from the AMD manual: a bit-field extract or insert of the low quadword, with the length and index from imm8 or from the source register bits 5:0 and 13:8, and the high quadword undefined (left unchanged);
    - one test per form against hand-computed values, plus a `cmd/lifter-difftest-asm` run on the functions that contain the sites;
    - commit `lifter: SSE4A EXTRQ and INSERTQ`.

### Task 5: The boot loop to Gate 1

Repeat until Gate 1 holds:
1. Rebuild inFAMOUS.
2. Run `probe_run.sh t4_<n> 120`.
3. Triage the first failure.
4. Fix it in its own commit with a test.

**Triage**, in order:
- **A FATAL signal in guest code.** Map the host PC to the guest instruction, the way Task 1 did: `objdump --disassemble-symbols=_fn_<addr>` on `ps4_app`, then the `// 0x<addr>:` comments in the matching `code_*.s`.
  - Find which value is wrong and where it came from: an HLE call's output, guest memory or a lifted instruction.
  - If an HLE call's output, check the call against FreeBSD or Orbis behaviour (shadPS4's kernel and the PC port's FINDINGS.md are references for facts, not code).
  - If a lifted instruction is suspected, run `cmd/lifter-difftest-asm` on the function.
- **The abort stub (`Unresolved import <name>`).** Implement the import: real behaviour, the console's error code where the feature is absent offline, or a documented no-op only where the console does nothing observable. Add it to `knownDirectShims` and to a host test.
  - `sigreturn`: first read the call site with REA (rea-targeted-use: a single question, "what does the game pass to sigreturn and from where"). Then rule in the ledger.
- **A hang** (the stall watchdog, `PS4_STALL_WATCHDOG=10000`, prints thread stacks). Find what the waiting thread waits for (an event, a semaphore, a file, a GPU label) and why it never comes.
- **An `[ps4-…] ERROR` or unimplemented-feature log line** before the failure. Treat it as a candidate cause first.

Facts from the PC port (FINDINGS.md) to check first when a failure touches them. Each is a
console behaviour to confirm, not a fix to copy:
- **libthr's static initializers and destroyed markers.** A mutex variable holding 1 is
  `THR_ADAPTIVE_MUTEX_INITIALIZER` (create an ADAPTIVE mutex on first use), and 2 is
  `THR_MUTEX_DESTROYED` (EINVAL). For cond and rwlock, 1 is the destroyed marker. After Task 1 our
  runtime treats any non-object value as "create on first use".
- **Memory.** Direct memory is 5056 MiB, the flexible limit 448 MiB and the page size 16 KiB. User VA
  runs from 0x1000000000 to 0xfc00000000, and the system window from 0x700000000 to 0x800000000.
  Our VM places mappings without a fixed address below 0x800000000 (`recomp_vm_alloc_named_aligned`).
  A pointer-tagging or range assumption in game code would show up here.
- **File reads.** A short read, or a positioned read that moves the file offset, makes the game
  report a corrupted disc.
- **AppContent add-ons.** `sceAppContentGetAddcontInfo` takes a 16-character label; the info record
  is 24 bytes, with status at +20 (4 = installed); an unknown label returns 0x80d90005.
- **Np.** The "A" variants return 0x80550006 while signed out.
- **The red zone.** 196 functions use `[rsp-k]`. Our signal handling must not write below the guest
  RSP.

Each fix:
- has a host test, or a Go test for lifter and emitter changes;
- passes `go vet`, `gofmt`, `go test` and the host suite;
- passes the TLOU regression check;
- is committed on its own as `<area>: <what>`;
- gets one ledger line: `Boot <n>: <symptom> -> <root cause> -> <fix commit>`.

The investigation notes go into `$W/infamous_research/infamous-boot-recon.md` under a new heading per failure.

A failure that needs more than a contained fix (a new subsystem, a lifter redesign, a codec) is not fixed inside this loop. Rule on it in the ledger, then write it into this plan as Task 5.<k> with full steps before starting it.

Gate 1 holds when `probe_run.sh` reaches its 120 s limit with `fatal 0` in `game.log` and no abort-stub call.

### Task 6: Gate 1

- [ ] **Step 1:** Run three runs of `probe_run.sh gate1_<i> 120`. Expected: each `mon.txt` ends `(time limit)` and none has a FATAL line.
- [ ] **Step 2:** Run the TLOU regression check with tag `iss_tlou_gate1`, then a 120 s Uncharted 4 boot with a build of this branch in `$W/infamous_research/u4_check`:
  - use the route script with `DATASRC=$(mktemp -d)`, as in `task-2.6-brief.md` of the Metal 4 plan;
  - Expected: fatal 0.
  - Repeat the TLOU check with `METAL=4`. Expected: fatal 0.
- [ ] **Step 3:** Run `go vet ./...`, `gofmt -l cmd pkg`, `go test ./...` and the host suite.
  - Expected: all pass.
- [ ] **Step 4:** Update `infamous-boot-recon.md` with "Gate 1" and these facts:
  - the furthest point reached (log lines, screenshots);
  - the memory footprint (the last `game_rss` in `mon.txt`);
  - the imports reached.
- [ ] **Step 5:** Commit the ledger reference in a docs commit to `docs/superpowers/plans/2026-10-25-infamous-second-son-bringup.md`: a short "Gate 1 result" paragraph under this task.

**Gate 1 result (961be55).** inFAMOUS probe `gate1_1`: 120 s, `(time limit)`, no FATAL, no abort stub; it reaches one flip and then polls `sceNpCheckCallback` (game_rss 518,192 KB). TLOU at this commit: Metal 3 with MetalFX 2560x1440 82.4 fps, Metal 4 72.4 fps, both fatal 0, gpu_err 0, watchdog 0; U4 120 s boot fatal 0, reaches its first-launch brightness menu. `go vet`, `gofmt`, `go test ./...` and the host suite pass. Details: `infamous_research/infamous-boot-recon.md` ("Gate 1") and `task-6-report.md`.

## Phase 2: first frame, menus (gate 2: the main menu renders and is navigable; a save directory is created in the test data dir)

### Task 7: Plan Phase 2

- [ ] **Step 1:** From the Gate 1 findings, list what stands between the boot and the main menu:
  - the VideoOut and GNM calls the log shows;
  - the translator gaps counted per shader;
  - the skipped draws;
  - the file I/O errors;
  - SaveData, UserService and SystemService calls.
- [ ] **Step 2:** Write them into this file as Tasks 7.1…7.n in this plan's task format. Each needs exact files, a failing test first, the implementation, the verification commands with expected output, and a commit. Add one more task for Gate 2 with the same checks as Task 6, plus a screenshot of the menu from `PS4_SCREENSHOT_EVERY_SEC=20` and a pad navigation check through `PS4_PAD_SCRIPT`.
- [ ] **Step 3:** Commit the plan update (`docs: inFAMOUS Phase 2 tasks`). The controller reviews it before the first task of the phase is dispatched.

**Findings (Task 7).** Details and evidence: `infamous_research/infamous-boot-recon.md`, "Phase 2 diagnosis", and `task-7-report.md`.

- The game never presents a frame because `sceVideoOutRegisterBuffers` rejects its buffer attribute. After `sceVideoOutSetBufferAttribute` the game writes 8 (`OPTION_STRICT_COLORIMETRY`) at attribute+0x18 (guest 0x1efd7b and 0x1f0fba). The SDK struct has `u32 option; u32 reserved0; u64 reserved1` there. Ours has `uint64_t reserved[2]`, and `reserved[0]` (option and reserved0) must be 0 (`ps4_videoout.c:242`), so the call returns 0x80290001.
- With no buffer registered, every `sceGnmSubmitAndFlipCommandBuffers` runs its DCB and then fails the flip with INVALID_INDEX, presenting nothing. "SubmitFlip flip mode 1" is printed once per mode, not per flip. The game loop runs unthrottled: in p2diag_2 there were 73,800 DCB submits and 74,000 `sceNpCheckCallback` calls in 55 s, about 1,340/s each. The Np poll is the main loop, not a wait on Np.
- Other gaps the log shows:
  - the stall watchdog only arms on the first present, so it never fired;
  - the first frames' pixel shader samples a 1x1 BC1 1D T#, which is bound as null;
  - `sceKernelGetDirectMemorySize` reports 32 GiB, so the game maps 31,104 MiB of type 3;
  - `sceNpSetContentRestriction` is a stub returning 0.
- SaveData, UserService and SystemService: only `sceSaveDataInitialize3` and `DirNameSearch('infamousss%')` (0 hits, as on a fresh console) have been reached. No file I/O error so far: the two `delete_me.snt` opens fail with EROFS, as on a console.

Order: Task 7.1 gates everything (no frame is ever presented). Tasks 7.2–7.5 are known gaps on the path. Task 7.6 is the loop to the menu. Task 7.7 is Gate 2.

TLOU and U4 runs: as ruled for Task 5, the loop's fixes are batched into Gate 2's regression runs. Tasks 7.1 (VideoOut, used by every game) and 7.5 (the direct memory size every game allocates against) run the TLOU check in their own task.

### Task 7.1: The buffer attribute's option word; rejected flips are logged

The SDK's `SceVideoOutBufferAttribute` (0x28 bytes) is laid out as follows, with shadPS4's `videoout/buffer.h` as the fact source:
- `pixelFormat`, `tilingMode`, `aspectRatio`, `width`, `height`, `pitchInPixel`;
- `u32 option` at +0x18;
- `u32 reserved0` at +0x1c;
- `u64 reserved1` at +0x20.

`option` takes the values NONE 0, VR 7 and STRICT_COLORIMETRY 8. The system library rejects nonzero reserved words (INVALID_VALUE), not `option`. No console fact says which option values it rejects, so `option` is stored with the buffer set and not checked. STRICT_COLORIMETRY asks the display path to output the buffer's colorimetry without system adjustment. Our presenter applies none, so it reads nothing from `option`.

A rejected flip is now logged: the first one per error code in full, then counted at powers of two. A boot whose flips all fail can no longer look like "one flip".

**Files:**
- Modify: `pkg/runtime/modules/libSceVideoOut/ps4_videoout.h`:
  - lines 27–35 (`OrbisVideoOutBufferAttribute`): replace `uint64_t reserved[2]` with `uint32_t option; uint32_t reserved0; uint64_t reserved1;`, and add `_Static_assert(sizeof(OrbisVideoOutBufferAttribute) == 0x28, ...)`;
  - add `ORBIS_VIDEO_OUT_BUFFER_ATTRIBUTE_OPTION_NONE` (0), `_VR` (7) and `_STRICT_COLORIMETRY` (8);
  - update the RegisterBuffers comment at lines 78–83: the reserved words, not option.
- Modify: `pkg/runtime/modules/libSceVideoOut/ps4_videoout.c`:
  - `sceVideoOutSetBufferAttribute` at 204–214: memset the whole struct to 0, then set the fields, `option = NONE`;
  - `sceVideoOutRegisterBuffers` at 242: check `reserved0 || reserved1`;
  - the success log line at 261: add `option 0x%x`;
  - `sceVideoOutSubmitFlip`, the INVALID_HANDLE and INVALID_INDEX returns at 361–373: log `[videoout] SubmitFlip(handle=%d, index=%d) rejected: 0x%08x` the first time per code, then with ` (x<n>)` at powers of two (an atomic counter per code, no lock, no allocation).
- Modify: `tests/host/gnm_submit_flip_nonblocking_test.mm`, `CheckBufferSetErrors` at 298–354. The `reserved[0]` case at 326–329 becomes three cases.

- [ ] **Step 1: Write the failing test.** In `ps4_videoout.h`, change only the struct, the static assert and the option constants. In `ps4_videoout.c:242`, keep today's behaviour with the new names: `if (attr->option || attr->reserved0 || attr->reserved1)`. In the test, replace lines 326–329 with:

```cpp
    a = attr;
    a.option = ORBIS_VIDEO_OUT_BUFFER_ATTRIBUTE_OPTION_STRICT_COLORIMETRY; // what inFAMOUS sets
    {
        const int32_t set = sceVideoOutRegisterBuffers(g.vo, 6, one, 1, &a);
        CHECK(set == 2, "register: option STRICT_COLORIMETRY is accepted (got 0x%08x)", (uint32_t)set);
        if (set >= 0) CHECK(sceVideoOutUnregisterBuffers(g.vo, set) == 0, "unregister the option set");
    }
    a = attr;
    a.reserved0 = 1;
    CHECK(rc(sceVideoOutRegisterBuffers(g.vo, 6, one, 1, &a)) == ORBIS_VIDEO_OUT_ERROR_INVALID_VALUE,
          "register: reserved0");
    a = attr;
    a.reserved1 = 1;
    CHECK(rc(sceVideoOutRegisterBuffers(g.vo, 6, one, 1, &a)) == ORBIS_VIDEO_OUT_ERROR_INVALID_VALUE,
          "register: reserved1");
    // SetBufferAttribute clears option and the reserved words of a dirty struct
    memset(&a, 0xff, sizeof a);
    sceVideoOutSetBufferAttribute(&a, 0x80000000u, 1, 0, attr.width, attr.height, attr.pixelPitch);
    CHECK(a.option == 0 && a.reserved0 == 0 && a.reserved1 == 0, "SetBufferAttribute: option and reserved are 0");
```

- [ ] **Step 2: Run it and see it fail.**

```bash
cd $R && tests/host/build_runtime_test.sh $W/infamous_research/t71_rt tests/host/gnm_submit_flip_nonblocking_test.mm > /dev/null && \
  PS4_GNM_METAL=3 $W/infamous_research/t71_rt/gnm_submit_flip_nonblocking_test sync 2>&1 | grep "FAIL\|PASS"
```

Expected: `gnm_submit_flip_nonblocking_test: FAIL: register: option STRICT_COLORIMETRY is accepted (got 0x80290001)` and no PASS line.

- [ ] **Step 3: Implement.** Make the remaining `ps4_videoout.c` changes listed under Files: SetBufferAttribute, the reserved-only check, the log fields, and the rejected-flip log.

- [ ] **Step 4: Run the test and the suite.**
  - The Step 2 command. Expected: `gnm_submit_flip_nonblocking_test sync: PASS (...)`.
  - `$W/tools/heavy_lock.sh bash tests/host/run_host_tests.sh > $W/infamous_research/host_t71.log 2>&1; echo host=$?`. Expected: `host=0`, and the log's last line is `capture tools: PASS (Ran <n> tests)`.

- [ ] **Step 5: Check the game.** Rebuild inFAMOUS (Shared commands), then run `probe_run.sh p2_71 120`. Expected:
  - `mon.txt` ends `(time limit)`, with no FATAL or abort stub.
  - `grep "RegisterBuffers" game.log` shows two `: set 0, ...` / `: set 1, ...` lines with `fmt 0x80000000, tmode 0, option 0x8`, and no `failed` line.
  - `grep -c "rejected:" game.log` is 0.
  - `[videoout] Presenting frame` lines are present, and `runs/p2_71/shots/` holds `sec_*.png`. Look at them and note what they show.
  - The `sceNpCheckCallback:266:` count at 120 s is below 10,000 (one per frame at 60 fps is 7,200; it was 162,000). If it is not, the flip pacing is the first item of Task 7.6. Do not fix it here.
- [ ] **Step 6: TLOU check.** Run the TLOU regression check (Shared commands) with tag `iss_tlou_t71`. Expected: fatal 0, gpu_err 0, watchdog 0, and fps within ±3 of the Gate 1 number (82.4 with MetalFX, or the plain-route ledger number for the same settings).
- [ ] **Step 7: Commit.** Commit `pkg/runtime/modules/libSceVideoOut/ps4_videoout.h`, `ps4_videoout.c` and `tests/host/gnm_submit_flip_nonblocking_test.mm` by path. Message: `videoout: the buffer attribute's option word; log rejected flips`. Add a ledger line: `P2 1: no frame presented -> RegisterBuffers rejected option=8 (reserved[0] covered option) -> <commit>`.

### Task 7.2: The stall watchdog arms when VideoOut opens

`PS4_STALL_WATCHDOG=<ms>` starts in `ps4_stall_watchdog_note_present` (`ps4_threading.c:1375–1394`), the first presented frame. A boot that never presents, as Gate 1 did, gets no thread report. The watchdog must also start at `sceVideoOutOpen`, counting the stall from the open.

**Files:**
- Modify: `pkg/runtime/kernel/threading/ps4_threading.c:1375–1394`:
  - factor the one-time start (environment, profile, thread) into `static void stall_watchdog_start_once(void)`, guarded by `pthread_once`;
  - add `void ps4_stall_watchdog_arm(void)`: start it, and set `g_last_present_ns` to now if it is still 0;
  - `ps4_stall_watchdog_note_present` calls the start and then sets the time.
- Modify: `pkg/runtime/core/recomp_runtime.h:102`: declare `ps4_stall_watchdog_arm`.
- Modify: `pkg/runtime/modules/libSceVideoOut/ps4_videoout.c`: `sceVideoOutOpen` calls `ps4_stall_watchdog_arm()` after the handle is made, before `ps4_metal_screen_init`.
- Create: `tests/host/stall_watchdog_test.c`.
- Modify: `tests/host/run_host_tests.sh`. After the `tls_modules_test` block (lines 128–132), build it with the same sources (`ps4_threading.c`, `ps4_stall_profile.c`, `recomp_runtime.c`) and run it.

- [ ] **Step 1: Write the failing test.** The test does the following:
  - sets `PS4_STALL_WATCHDOG=100`;
  - redirects fd 2 to a temporary file (`dup2`), calls `ps4_stall_watchdog_arm()` twice and sleeps 400 ms with no present;
  - reads the file and checks that exactly one `[stall] no frame for` line was written (one report per stall, one watchdog thread);
  - calls `ps4_stall_watchdog_note_present()`, sleeps 50 ms and checks that no new line was written;
  - prints `stall_watchdog_test: PASS` or the failures, and exits 1 on a failure.
- [ ] **Step 2: Run it.** `bash tests/host/run_host_tests.sh 2>&1 | grep -m3 "stall_watchdog\|Undefined"`. Expected: a link error, `Undefined symbols ... _ps4_stall_watchdog_arm`.
- [ ] **Step 3: Implement** as listed under Files.
- [ ] **Step 4: Run the suite.** Expected: `stall_watchdog_test: PASS`, `host=0`, and the last line is `capture tools: PASS (...)`.
- [ ] **Step 5: Commit** `threading: arm the stall watchdog at sceVideoOutOpen`, with the four files by path.

### Task 7.3: sceNpSetContentRestriction

The game calls it at boot (`[ps4-stub] sceNpSetContentRestriction -> 0 (no-op)`, from `ps4_noop_stubs.c:43`). It takes a `SceNpContentRestriction`:
- `u64 size` (0x18);
- `s8 defaultAgeRestriction`, then 3 bytes of padding;
- `s32 ageRestrictionCount`;
- `const SceNpAgeRestriction *ageRestriction`.

Each `SceNpAgeRestriction` is a country code (2 characters, terminator, pad) and an `s8 age`, 8 bytes in all.

The Np library validates the struct and keeps the restriction for later availability checks (shadPS4 `np_manager.cpp:748` as the fact source for the checks):
- NULL is `ORBIS_NP_ERROR_INVALID_ARGUMENT` (0x80550003);
- a size other than 0x18 is `ORBIS_NP_ERROR_INVALID_SIZE` (0x80550011);
- a default age below 0, or a count above 0x100, is INVALID_ARGUMENT;
- a count above 0 with a NULL array is INVALID_ARGUMENT.

While the user is signed out, `sceNpCheckNpAvailability(A)` returns SIGNED_OUT before any age check, so the stored restriction changes no result today. It is still kept, so that it is real state rather than a discarded call.

**Files:**
- Modify: `pkg/runtime/modules/libSceNp/ps4_np.h`: the two structs (with static size asserts), `void shim_sceNpSetContentRestriction(GuestContext *ctx)`, and `int ps4_np_content_restriction(int8_t *default_age, int32_t *count)` (returns 0 when none is set).
- Modify: `pkg/runtime/modules/libSceNp/ps4_np.c`: after `shim_sceNpRegisterGamePresenceCallbackA` (line 460), add the shim. It validates the struct, copies the default age and up to 0x100 entries into a static table under a mutex (no heap allocation), logs the first call, and returns 0.
- Modify: `pkg/runtime/modules/libSceNoopStubs/ps4_noop_stubs.c:43`: remove `NOOP_SHIM(sceNpSetContentRestriction)`.
- Modify: `pkg/emitter/shims.go:602`: move the name from the "No-op stubs" group to the libSceNp entries of `knownDirectShims`. It stays a direct shim.
- Modify: `tests/host/boot_hle_test.c`: add `test_np_content_restriction()` next to the `sceNpSetNpTitleId` checks (lines 200–211), and call it from `main`.

- [ ] **Step 1: Write the failing test.** Through `call(shim_sceNpSetContentRestriction, addr, 0, 0)`, with the struct at guest 0x5200 and one entry `{"us", age 17}` at 0x5300. The test checks:
  - NULL returns 0x80550003;
  - size 0x10 returns 0x80550011;
  - default age -1 returns 0x80550003;
  - count 0x101 returns 0x80550003;
  - count 1 with a NULL array returns 0x80550003;
  - the valid struct returns 0, and `ps4_np_content_restriction` then reports default age 0 and count 1.
- [ ] **Step 2: Run** `bash tests/host/run_host_tests.sh 2>&1 | grep -m5 "FAIL line\|Undefined"`. Expected: the link fails on `_ps4_np_content_restriction` (the no-op shim returns 0 for every case, so the NULL check is the first that fails once it links).
- [ ] **Step 3: Implement** as listed under Files.
- [ ] **Step 4: Verify.**
  - The host suite gives `host=0`.
  - `go vet ./...`, `gofmt -l cmd pkg` (empty) and `go test ./...` pass, which covers `shim_test.go` and the shim tables.
  - `grep -c "NOOP_SHIM(sceNpSetContentRestriction)" pkg/runtime/modules/libSceNoopStubs/ps4_noop_stubs.c` is 0.
- [ ] **Step 5: Commit** `np: sceNpSetContentRestriction validates and keeps the restriction`, with the files by path.

### Task 7.4: Block-compressed and mipmapped 1D textures

The first frames' pixel shader 0x1085ab2f00 reads the T# `1091e093 02300000 00000000 84d00fac 0003e000 00000000 00000000 00000000`: Color1D, 1x1, dfmt 35 (BC1). Metal cannot make 1D textures with a block-compressed format or with mips. So the renderer (`ps4_gnm_resources.mm:1628–1645`) and the translator (`IsCreatableImage`, `3rdparty/gcn-recompiler/src/shader_recompiler/resource.h:162–186`) bind it as null, and the shader reads 0. FINDINGS: BC 1D textures occur in this game.

GCN samples a 1D image along x. The same texels are a 2D image of height 1 (or a 2D array of height 1 for Color1DArray). Coordinates map as follows:
- a sample at u becomes (u, 0.5);
- a load at x becomes (x, 0);
- derivatives become (du, 0);
- offsets become (o, 0).

Made that way, the image and its reads are exact. 1D T#s that Metal can make as 1D (one level, not block-coded) stay 1D.

**Files:**
- Modify: `3rdparty/gcn-recompiler/src/video_core/amdgpu/resource.h`, `Image::GetViewType` (lines 307–319): for Color1D / Color1DArray with `last_level > 0` or a block-coded format, return Color2D / Color2DArray. Add the predicate `Image::Is1DAs2D()`.
- Modify: `3rdparty/gcn-recompiler/src/shader_recompiler/resource.h:162–186` (`IsCreatableImage`): such 1D images are creatable. Keep the comment in step with the renderer's.
- Modify: `3rdparty/gcn-recompiler/src/shader_recompiler/ir/passes/resource_patching_pass.cpp`. Where the view type selects coordinate, offset and derivative components (around lines 605, 1673, 1694, 1750, 1833), read the 1D component layout from the instruction and build the 2D layout for `Is1DAs2D` images, as mapped above.
- Modify: `pkg/runtime/modules/libSceGnmDriver/ps4_gnm_resources.mm:1609–1645`:
  - such T#s get `MTLTextureType2D` / `MTLTextureType2DArray` with height 1, and stay valid;
  - the uncreatable check keeps the other cases;
  - the upload and detiling use the 2D path with height 1. BC blocks smaller than 4 rows are padded, as for any level smaller than a block.
- Create: `tests/host/gnm_tex1d_test.mm`, modelled on `tests/host/gnm_tsharp_table_test.mm`: hand-assembled compute shaders through `ps4draw::Dispatch`, with results written by `buffer_store_dwordx4`.
- Modify: `tests/host/run_host_tests.sh`: add the source to the replay build list (lines 269–270), and add `for m in 3 4; do rtest $m "$T/replay/gnm_tex1d_test"; done` next to line 389.
- Rebuild `libgcn_recompiler.a` the way the README describes for translator changes.

- [ ] **Step 1: Write the failing test.** Three textures and their checks:
  - **(a) BC1 Color1D, 8x1.** Block 0 is all red (color0 0xF800, indices 0) and block 1 all blue (0x001F). `image_load_mip` of texels 1 and 5 at level 0 gives red and blue. `image_sample_lz` at u = 0.75 with a point S# gives blue.
  - **(b) RGBA8 Color1D with 3 levels (4, 2, 1 texels).** Each level has its own colour. `image_load_mip` at level 2 gives the level-2 colour. `image_sample_l` at lod 1 gives the level-1 colour.
  - **(c) The inFAMOUS T# above**, decoded through `DecodeImage`: valid, `MTLTextureType2D`, 1x1, and no `not a texture Metal can create` line in the output.
  - **Translation:** the `gcn_image_binding.view_type` of (a) is Color2D (9).

  Today the reads are 0 and (c) is invalid.
- [ ] **Step 2: Run.**

```bash
cd $R && $W/tools/heavy_lock.sh bash tests/host/run_host_tests.sh > $W/infamous_research/host_t74.log 2>&1; grep -m5 "gnm_tex1d_test" $W/infamous_research/host_t74.log
```

Expected: FAIL lines for (a), (b) and (c) on Metal 3.
- [ ] **Step 3: Implement** as listed under Files.
- [ ] **Step 4: Verify.** The host suite gives `host=0` with `gnm_tex1d_test: PASS [metal3]` and `[metal4]`. Also re-run the `gnm_tsharp_table_test` and `gcn_runtime_sharp_test` lines (in the same log): they still PASS.
- [ ] **Step 5: Check the game.** Rebuild, then run `probe_run.sh p2_74 120`. Expected: `grep -c "not a texture Metal can create" game.log` is 0 for type 8 or 12 with dfmt 35–41. Look at the screenshots and note any change.
- [ ] **Step 6: Commit** `gnm, gcn: block-compressed and mipmapped 1D textures as 2D of height 1`, with the files by path.

### Task 7.5: Direct memory size from the process's memory parameters

`sceKernelGetDirectMemorySize` returns 32 GiB (`ps4_direct_mem.h:13`, `ps4_direct_mem.c:155–169`). The game takes "the rest" after its 1,152 + 512 MiB, which is 31,104 MiB of type 3.

The kernel derives the size from the process's `SceKernelMemParam`. The rule below comes from shadPS4's `linker.cpp:114–147` and `memory.cpp` `SetupMemoryRegions`, as the fact source:
- total = 5248 MiB, or 5888 MiB in Neo mode (`PS4_PRO=1`);
- flexible = `*flexible_memory_size + 64 MiB` when the param holds that pointer, else 512 MiB;
- for SDK < 0x05000000, extended memory 1 and 2 come from the param's `u8` flags (false when absent); from 5.00 on, both are on;
- without extended memory 2 (base mode) subtract 128 MiB; without extended memory 1 (Neo) subtract 256 MiB;
- direct = total − flexible.

For inFAMOUS (proc param 0xda0000: SDK 0x04008061; mem_param 0xd7c028 of size 0x18; flexible pointer NULL) this gives 4608 MiB in base mode. The PC port's 5056 MiB is its own configured default, not a derivation. Record the disagreement in the ledger.

`PS4_DIRECT_MEM_SIZE` stays as an explicit override, documented as not console behaviour. Flexible memory (`sceKernelConfiguredFlexibleMemorySize`, a 4 GiB minimum at `ps4_direct_mem.c:498`) is out of scope here. It goes in the ledger as the next item of the same kind.

**Files:**
- Modify: `pkg/runtime/kernel/memory/ps4_direct_mem.h:13`:
  - remove the 32 GiB constant;
  - add the MiB constants of the rule;
  - add `uint64_t ps4_direct_mem_size_rule(uint32_t sdk, int neo, int has_flex, uint64_t flex, int ext1, int ext2)` (pure);
  - add `void ps4_direct_mem_configure(GuestContext *ctx, uint64_t proc_param_addr)`, which reads the proc param (size, sdk at +0x10, mem_param at +0x40) and the mem_param fields within its size (+0x10, +0x18, +0x28), and logs `[ps4-mem] direct memory <n> MiB (sdk 0x.., flexible <m> MiB, ext1 <0|1>, ext2 <0|1>)`.
- Modify: `pkg/runtime/kernel/memory/ps4_direct_mem.c:155–169`: `get_total_direct_mem_size` returns the configured size, or the override, before `ps4_direct_mem_init` builds the free block.
- Modify: `pkg/runtime/core/recomp_runtime.c:612`: `recomp_init_process_param` calls `ps4_direct_mem_configure` first, before the guest's malloc init allocates direct memory.
- Modify: the tests that define their own `ps4_direct_mem_*` stubs, so they link: `tests/host/kernel_vmfree_test.c`, `sync_objects_test.c`, `thread_fpstate_test.c` and `tls_modules_test.c`, plus `tests/host/runtime_stubs.h`.
- Create: `tests/host/direct_mem_size_test.c`, and add it to `run_host_tests.sh` next to `vfs_readonly_test`, linked with `ps4_direct_mem.c` and `recomp_runtime.c`.

- [ ] **Step 1: Write the failing test.**
  - The rule table:
    - (0x04008061, base, no flexible, no ext) is 4608 MiB;
    - the same in Neo is 5120 MiB;
    - (0x04008061, base, ext2 = 1) is 4736 MiB;
    - (0x05050001, base) is 4736 MiB;
    - (0x05050001, Neo) is 5376 MiB;
    - (0x05050001, base, flexible 448 MiB) is 4736 MiB;
    - (0x05050001, base, flexible 1024 MiB) is 4160 MiB.
  - Through a guest proc param built like inFAMOUS's (size 0x48, mem_param size 0x18), after `ps4_direct_mem_configure`, `sceKernelGetDirectMemorySize()` is 4608 MiB, and `sceKernelAvailableDirectMemorySize()` is the same before any allocation.
- [ ] **Step 2: Run** the host suite. Expected: a link error on `_ps4_direct_mem_size_rule` (today the size is 32 GiB whatever the parameters).
- [ ] **Step 3: Implement** as listed under Files.
- [ ] **Step 4: Verify.**
  - The host suite gives `host=0`.
  - Rebuild inFAMOUS and run `probe_run.sh p2_75 120`. Expected: `direct memory 4608 MiB (sdk 0x4008061, flexible 512 MiB, ext1 0, ext2 0)`; the type 3 allocation is 2944 MiB; fatal 0.
  - Run the TLOU regression check with tag `iss_tlou_t75`. Expected: its `direct memory` line, fatal 0, fps within ±3.
  - Also run a 120 s U4 boot as in Task 7.7, Step 3. Expected: fatal 0.
  - If TLOU or U4 then fails an allocation, the cause is in our direct or flexible memory accounting, not in the size. Find it (the allocation, its size and type, and what is already mapped). Rule in the ledger before any further change. A per-game size is not a fix.
- [ ] **Step 5: Commit** `kernel: direct memory size from the process's memory parameters`, with the files by path, and add the ledger line.

### Task 7.6: The loop to the main menu

Repeat until the main menu is on screen and reacts to the pad:
1. Rebuild inFAMOUS.
2. Run `probe_run.sh p2_<n> 120`.
3. Triage the first failure.
4. Fix it in its own commit with a test.
5. Rule as in Task 5: one probe per fix; TLOU and U4 at Gate 2, except changes to shared presentation or memory paths, which run the TLOU check in the fix.

Budget: Gate 2, or about 6 fixes. After that, stop and report to the controller.

**After every probe once frames flow, count** (`L=$W/infamous_research/runs/p2_<n>/game.log`):

```bash
grep -c "compiled [A-Z]S shader" $L                                   # shaders translated
grep -o "shader 0x[0-9a-f]* (hw [0-9]*): [0-9]* [a-zA-Z_ -]*" $L | sort | uniq -c   # translator gaps per shader and kind
grep -c "translation failed\|msl-fail" $L                             # shaders that did not translate
grep "not a texture Metal can create" $L | tail -1                    # uncreatable T#s (xN)
grep "\[gnm-draw\] present #" $L | tail -1                            # totals: draws, dispatches, skipped
grep "\[gnm-draw\].*skipped" $L | grep -v "present #" | sed 's/^\[gnm-draw\] //;s/ (x[0-9]*)$//' | cut -c1-60 | sort | uniq -c
```

Write one ledger line per probe: `P2 probe <tag>: shaders S (failed F), gap shaders G by kind, skipped K of D draws by reason, uncreatable T# U, furthest screen <shot>`. A count that grows from one probe to the next is a candidate cause before anything else.

**Triage**, in order:
- **A FATAL signal or an abort-stub call.** Handle it as in Task 5.
- **The presented frames stop, or a screen never changes** (the watchdog `[stall] no frame for`, or two screenshots alike past a loading screen). Find what the waiting thread waits for: a flip, a label, an equeue event, a file, or a movie frame (see below).
  - Flip pacing comes first: the game's only flip path is `sceGnmSubmitAndFlipCommandBuffers` plus `sceVideoOutIsFlipPending`, and the DCB's `WAIT_REG_MEM` from `sceGnmInsertWaitFlipDone` (`ps4_gnmdriver.c:409`).
- **A frame that presents but is black or wrong.** Use the counts above first. Then capture the frame (`PS4_GNM_CAPTURE_DIR`, `PS4_GNM_CAPTURE_FRAME`), replay it with `gnm_replay` and the pass overview, and localise the first wrong pass. Fix the translator or the renderer, with a host test from the shader dump as a local fixture under `tests/host/data/game/` (SKIP without it).
- **A file I/O error.** Look for `fd=-1` other than the two `delete_me.snt`, a short read, or a positioned read that moves the offset (FINDINGS: the game reports "disc corrupted").
- **SaveData, UserService and SystemService calls.** Check each new call in the log against console behaviour, with shadPS4 as the fact source.
  - Gate 2 needs a save directory under `data/saves/`. Find the call that creates it (`sceSaveDataMount2` with a create mode, or SaveDataDialog), and why it does not come.
  - `PS4_NO_DIALOGS=1` must answer dialogs the way a console user would, never by skipping them silently.
- **A reached import that is still a `NOOP_SHIM` or logs `(stub`** (`sceNetSocketAbort` is one the game imports). Implement it as in Task 7.3.
- **An `ERROR` line or an unimplemented-feature line** before the failure. Treat it as a candidate cause first.

**Movies.** The boot opens `art/movies/cutscene/splash_europe.bsf`, with MoviePlayer and MovieDecoder threads. If the path to the menu waits on a movie the runtime cannot decode, that work belongs to Phase 3. Rule in the ledger first: identify the decoder path from the first call, then decide whether a Phase 3 task moves forward. Do not stub the movie away.

Each fix:
- has a host test, or a Go test for lifter and emitter changes;
- passes `go vet`, `gofmt`, `go test` and the host suite;
- is committed on its own as `<area>: <what>`;
- gets one ledger line: `P2 <n>: <symptom> -> <root cause> -> <fix commit>`.

The notes go into `infamous-boot-recon.md`, under one heading per failure.

A failure that needs more than a contained fix (a new subsystem, a codec, a renderer redesign) is not fixed inside this loop. Rule on it in the ledger, then write it into this plan as Task 7.6.<k> with full steps before starting it.

The loop ends when a probe's screenshots show the main menu. The deliverable is `T_menu` in the ledger: the `sec_<s>.png` where the menu first appears, the `[pad] script started at` reference, and the `PS4_PAD_AUTOPRESS` presses needed to get there.

### Task 7.6.1: The movie manager does not schedule the splash movie

After fix 46c30c4 the flips are paced, but the screen stays black (probes p2_2..p2_14, `infamous-boot-recon.md` "Task 7.6, failure 2"). The frame is black on purpose: the splash state machine sits in state 3 and waits for the splash movie.

What is known:
- State 3 creates the movie (fn 0x28e160 opens `art/movies/cutscene/splash_europe.bsf`) and requests playback (fn 0x28f5a0). The request goes through insert fn 0x28fd00 into the movie manager at 0x1d1faa0: array +0x70, count +0x78 = 1. Then comes a CondBroadcast on cond 0x1d1faf8 (mutex 0x1d1faf0).
- The state-3 update then polls fn 0x28ad00 ("is done") forever.
- The MoviePlayer thread (fn 0x2908f0) pops manager+0xc8 (fn 0x28ea60) and waits on the cond otherwise. manager+0xc8 is never set.
- The MovieDecoder thread (fn 0x28e8f0) also sleeps. Its helper at 0x28e960 reads the lists +0x98/+0xa8/+0xb8/+0xc8/+0xd8/+0xe8/+0xf8.
- `sceVideodec*` is never called. No HLE call blocks.
- The `.bsf` is raw H.264 Annex B, decoded through sceVideodec (implemented on VideoToolbox, used by TLOU).

So the requested movie is never moved from +0x70 into the lists. This task finds what moves it and what that code waits for, and fixes the runtime side.

- [ ] **Step 1: Find the mover.** Find the code that reads manager+0x70/+0x78 and writes the lists +0x98..+0xf8: xrefs to the manager global 0x1d1faa0 and to the list offsets in the movie code (fn 0x28a000..0x291000). Use REA, one focused question at a time, on the eboot or the generated build's ELF. Confirm at run time with lldb breakpoints on the generated `fn_0x...` symbols and with `PS4_WATCH` on manager+0x70..+0x100.
- [ ] **Step 2: Find what the mover waits for or checks.** Candidates, in order:
  - the movie fd's results: `sceKernelFstat` size, `sceKernelLseek`, `sceKernelPread` offsets and lengths, short reads;
  - an asynchronous read or streaming completion (the game's own IO thread, an equeue or event flag it waits on);
  - a time or vblank source (process time, `sceKernelGetProcessTime`, VideoOut vblank events);
  - a PlayGo chunk status of the movie file;
  - the Wwise audio resources the movie starts (`MovieStarted`).
  For each, record the call, its arguments and the runtime's result next to console behaviour (shadPS4 as the fact source).
- [ ] **Step 3: Rule.**
  - If an HLE call differs from console behaviour, that is the root cause. Fix it in the runtime, as console behaviour for any game: never a game-specific path, never by stubbing the movie away.
  - If the cause needs a new subsystem, stop. Write it up as its own task, with the evidence.
- [ ] **Step 4: Test first.** Write a host test that reproduces the wrong result through the guest entry of the call, and see it fail (RED). Implement, and see it pass (GREEN).
- [ ] **Step 5: Verify.**
  - `go vet ./...`, `gofmt -l cmd pkg` (empty), `go test ./...`, and the host suite (exit 0, ends `capture tools: PASS (Ran N tests)`).
  - Rebuild inFAMOUS and run one probe (`p2_<n>`, next free tag). Expected: `[libSceVideodec] first picture decoded`, and splash pictures in the screenshots.
  - If the fix is on a shared path (file I/O, memory, timing), run the TLOU regression check from the Shared commands, and note the machine load.
- [ ] **Step 6: Commit** `<area>: <what>`, with the files by path. Add the ledger line `P2 <n>: <symptom> -> <root cause> -> <fix commit>`, and the notes in `infamous-boot-recon.md` under the failure's heading.
- [ ] **Step 7: Continue the Task 7.6 loop** from the splash: decoder output (sceVideodecDecode on VideoToolbox), splash frames, then the title and the main menu. Budget: the main menu, or about 3 fixes after the movie. Then report.

### Task 7.6.2: Pad motion sensors

The tutorial at the billboard (probe p2d_8, second boot from p2_22's saves) shows "Hold Wireless Controller Sideways" and never clears (`task-7.6-loop2-report.md`, "Current first failure"). The runtime's scePadSetMotionSensorState, scePadSetTiltCorrectionState, scePadSetAngularVelocityDeadbandState and scePadResetOrientation return 0 without doing anything (the game itself imports none of them: only scePadOpen and scePadReadState, so on a console the sensor reports from scePadOpen on), and scePadRead/scePadReadState never fill the orientation, angular velocity or acceleration of ScePadData: they stay all zero, which is not even a unit quaternion. A still DualShock 4 reports the unit quaternion and gravity of about 1 g.

Files: `pkg/runtime/modules/libScePad/ps4_pad.{h,m}` (and its host input), `tests/host/pad_test.m`, `README.md` (pad script format).

- [ ] **Step 1: Facts.** From shadPS4 (`src/core/libraries/pad/pad.cpp`, `src/input/controller*.cpp`, and the SDL3 GameController backend it uses on macOS, `externals/sdl3/src/joystick/apple/SDL_mfijoystick.m`): the ScePadData offsets of orientation (quaternion x,y,z,w), angularVelocity (rad/s) and acceleration (g); the axes (x right, y out of the top face, z toward the player; a pad lying flat reports +1 g on y); the orientation is integrated from the gyro and starts at (0,0,0,1) at open and at ResetOrientation; the GCMotion -> pad axis conversion. Record which setter semantics have no public source, and the choice made for them.
- [ ] **Step 2: Test first (RED).** Extend `tests/host/pad_test.m`, through the guest shims:
  - an unknown handle gives ORBIS_PAD_ERROR_INVALID_HANDLE from all four calls;
  - with no motion device and the sensor on: orientation (0,0,0,1), acceleration (0,1,0) g, angular velocity 0;
  - motion sensor off: the values defined for "off";
  - a scripted roll of 90 degrees: orientation is the 90-degree rotation about z, gravity is on x, with tilt correction on and off; angular velocity during the turn has the scripted rate, and the deadband zeroes a rate below its threshold;
  - ResetOrientation after the roll: orientation is (0,0,0,1) again while gravity stays on x.
  Run it against the no-op setters and see it fail.
- [ ] **Step 3: Implement (GREEN).** Per-handle state (sensor on/off, tilt correction, deadband, orientation, its reference gravity, last update time). Every read path fills the three fields from one motion source, in order: a connected motion-capable controller through GameController (GCMotion with `sensorsActive`, converted to the pad's axes and units); the scripted pose of `PS4_PAD_SCRIPT` tilt steps (and a documented keyboard key that turns the virtual pad sideways); else a pad at rest. No allocation on the read path.
- [ ] **Step 4: Document** the `PS4_PAD_SCRIPT` tilt step and the key in `README.md` and in the comment at the parser.
- [ ] **Step 5: Verify.** `go vet ./...`, `gofmt -l cmd pkg` (empty), `go test ./...`, the host suite through heavy_lock (exit 0, ends `capture tools: PASS (Ran N tests)`). The pad is a shared input path: one TLOU check from the Shared commands (owner's config, Metal 3, warm cache); at rest TLOU must behave as before.
- [ ] **Step 6: Commit** `pad: <what>`, files by path.
- [ ] **Step 7: Probe.** Rebuild inFAMOUS; `heavy_lock.sh probe_run.sh p2_23 240 SEED_DATA=<p2_22's data dir> PS4_PAD_SCRIPT=<tilt script>`. Expected: the sideways prompt clears and the tutorial goes on. Ledger lines as in Task 7.6.
- [ ] **Step 8: Continue the Task 7.6 loop** toward Gate 2 as redefined: first gameplay controllable past the tutorial, the pause menu navigable, a save directory created. Budget: about 3 more fixes. Movie/codec or renderer-redesign-size failures are written up, not fixed here.

### Task 7.7: Gate 2

- [ ] **Step 1: One inFAMOUS probe** from the Phase 2 head. Rebuild first. Use `T_menu` (in seconds) from Task 7.6. The autopress (Cross every 4 s) stops 5 s before the menu, then the script presses Down (0x40) at `T_menu`+10 s and again at `T_menu`+30 s, each for 100 ms:

```bash
TM=<T_menu in ms>
$W/tools/heavy_lock.sh $W/infamous_research/probe_run.sh gate2_1 120 PS4_PAD_AUTOPRESS_UNTIL=$((TM - 5000)) \
  PS4_PAD_SCRIPT="$((TM + 10000)):40:100,$((TM + 30000)):40:100"
tail -2 $W/infamous_research/runs/gate2_1/mon.txt; grep -n "FATAL\|abort stub\|Unresolved" $W/infamous_research/runs/gate2_1/game.log | head
find $W/infamous_research/runs/gate2_1/data/saves -mindepth 3 -maxdepth 3 -type d
```

  The probe takes `PS4_SCREENSHOT_EVERY_SEC=20`. `T_menu` must be 60 s or less, so that both presses fall inside 120 s. Otherwise run 180 s.

  Expected:
  - `(time limit)`, with no FATAL, abort stub or Unresolved line;
  - a `sec_<s>.png` showing the main menu;
  - the shot after the first press shows the highlighted item one place lower than the shot before it, and the shot after the second press one more;
  - `find` lists at least one save directory (`<Title [CUSA00004]>/user_<uid>/<dirName>`).

  Look at every shot named here and describe it in the report.
- [ ] **Step 2: TLOU, with a build of the Phase 2 head in `$W/infamous_research/tlou_check`** (Shared commands). Expected for both runs: fatal 0, gpu_err 0, watchdog 0; fps within ±3 of Gate 1 (82.4 on Metal 3 with MetalFX, 72.4 on Metal 4).

  Metal 3 with MetalFX at 2560x1440 and gameplay screenshots:

```bash
HEAVY_EXCLUSIVE=1 $W/tools/heavy_lock.sh env BUILD=$W/infamous_research/tlou_check TAG=iss_tlou_gate2 SECS=120 EVERY=100000 \
  OUT=$W/infamous_research/runs tools/metal4_route.sh PS4_UPSCALE=metalfx PS4_SCREENSHOT_EVERY_SEC=20
python3 tools/metal4_route_report.py $W/infamous_research/runs/iss_tlou_gate2.log
```

  Then the same with `METAL=4` and tag `iss_tlou_gate2_m4`. Look at `shots_iss_tlou_gate2/sec_000060.png` and `sec_000100.png`: normal gameplay, no artefacts.
- [ ] **Step 3: One Uncharted 4 boot of 120 s.**
  - Generate `$W/infamous_research/u4_check` from this branch: `./ps4-recomp "<your-U4-dump>/CUSA04529/eboot.bin" --app-dir "<your-U4-dump>/CUSA04529" -o $W/infamous_research/u4_check -c -j 6` under `heavy_lock`, with the log in `u4_gen.log`.
  - Run `HEAVY_EXCLUSIVE=1 $W/tools/heavy_lock.sh env BUILD=$W/infamous_research/u4_check TAG=iss_u4_gate2 SECS=120 DATASRC=$(mktemp -d) SCRIPT=/dev/null OUT=$W/infamous_research/runs tools/metal4_route.sh`.
  - Expected: fatal 0, and `sec_000100.png` shows the first-launch brightness screen as at Gate 1.
- [ ] **Step 4: Go and the host suite.** `go vet ./...`, `gofmt -l cmd pkg` (empty), `go test ./...` and the host suite. Expected: all pass, and the suite exits 0 with the last line `capture tools: PASS (...)`.
- [ ] **Step 5: Ledger.** Update `infamous-boot-recon.md` with "Gate 2": the menu shot, the pad check, the save directory, the last probe's counts line, game_rss, and the imports reached.
- [ ] **Step 6: Commit** a "Gate 2 result" paragraph under this task, in a docs commit of this plan file only.

**Gate 2 result (62fcaf5).** inFAMOUS probe `gate2_2` (520 s, fresh data dir, scripted tilt/shake/L2 route): `(time limit)`, no FATAL, abort stub or Unresolved; the tutorial clears, Delsin is controllable in the fish cannery ("Find the back door out of the fish cannery", then "ESCAPE SHERIFF"; the view changes with stick input), the OPTIONS pause menu opens and two Down presses move the cursor from Save Game to Load Game, Circle closes it, and `infamousssAuto0/1` exist under `saves/<title> [CUSA00004]/user_10000000`. game_rss 1.19 GB; the headless audio.wav (199 MB) is non-silent. Open issues for Phase 4: 14% of draws skipped (1,578,587 of 10,960,800, reason `DRAW_INDEX_2` vertex address not a multiple of 4), corrupted frames around the cutscene, 12 fps. The first route (`gate2_1`) missed the rattle prompt because a fresh boot's intro is 30-40 s longer. TLOU: Metal 3 with MetalFX 85.4 fps, Metal 4 72.4 -> 75.3 fps, fatal 0, gpu_err 0, watchdog 0; U4 120 s fatal 0 at the brightness screen; `go vet`, `gofmt`, `go test ./...` and the host suite pass (the stale `libgcn_recompiler.a` was rebuilt). Details: `infamous_research/infamous-boot-recon.md` ("Gate 2") and `task-7.7-report.md`.

## Phase 3: movies, audio, new game (gate 3: the intro movie plays with sound; the prologue is controllable; a save is written and loads back)

### Task 8: Plan Phase 3

- [ ] **Step 1:** From the Gate 2 findings, identify:
  - the movie container and codec from the first video call: `libSceVideodec`, `libSceVdecsw` or the game's own decoder (FINDINGS.md says what the PC port uses);
  - the audio codecs from the first `sceAjm` calls;
  - the input path for the motion sensor prompts (the PC port lists a graffiti motion sensor; on a Mac controller without one, the console's behaviour for a pad without motion data is what we emulate).
- [ ] **Step 2:** Write Tasks 8.1…8.n and the Gate 3 task as in Task 7, Step 2. The save test writes in a scratch data dir, restarts and loads.
- [ ] **Step 3:** Commit the plan update.

**Findings (Task 8).** Sources: the probe logs `runs/p2_22`, `p2_30`, `p2_32`, `p2_33`, `p2_762c`, `geom_f2`, `geom_f2_cold`, their screenshots, `phase3-media-recon.md` and the reports of Tasks 7.6.1, 7.6.2 and 7.6 loop 3. No game was run for this task. Details: `task-8-report.md`.

- **Movies.**
  - The codec and the path are settled. `.bsf` is raw H.264 Annex B (High@4.2, 29.97 fps, no audio, no access unit delimiters). The game demuxes it in its own code and decodes through `sceVideodec` (six imports), which runs on our VideoToolbox core.
  - Since p2_18, every probe opens the splash (`splash_europe.bsf`) and then the opening (`v_vor_opening_no_text.bsf`). Each gets one decoder: `VideoToolbox H.264 session 1920x1080` and `first picture decoded`, twice per log. No probe logs a VideoToolbox error, an error picture or `frame buffer too small`.
  - The splash is on screen at p2_21 `sec_000002`–`sec_000012`; `sec_000006` is the SP logo. The text crawl (`geom_f2 sec_000060`) and the convoy (`sec_000100`) come after the opening movie is opened.
  - At 1920 the pitch is right. The splash is not sheared, so the game's NV12 pass uses the reported `framePitch` (1920, align 64), not the 256-aligned pitch of `QueryResourceInfo`'s sizing (2048).
  - **Not known:**
    - how many pictures are decoded: the runtime logs only the first;
    - whether each `sceVideodecDecode` gets a whole access unit (the files have 17 slices per picture and no AUD to split on);
    - the pace of the pictures.
  - The streams have 309 pictures (splash, 10.3 s) and 1,691 pictures (opening, 56.4 s), counted on slices with first_mb_in_slice = 0. Both have at most 17 slices per picture and only NAL types 1, 5, 6, 7 and 8.
  - During the movies the game flips at 117.7 fps (geom_f2 perf lines), so a picture spans about 4 flips and the game must pace the movie by its own clock.
- **Audio.**
  - The two AudioOut ports open in all 69 inFAMOUS logs. Port 1 is the main port (8ch float, 1024-sample grains, 48 kHz) and port 2 is PADSPK (mono float).
  - `host output started (default device ...)`: the probes played on the owner's speakers, with nobody listening.
  - No probe set `PS4_AUDIO_LOG` or `PS4_AUDIO_DUMP`, so the outputs, RMS and underruns are unknown. Both features exist in `ps4_audioout.c` (per-port RMS, peak and `underruns` every 2 s, a final-mix float WAV, and the headless clock device `PS4_AUDIO_NULL`). What they lack is a clock shared with the movie and screenshot timelines, and gap/late counters.
  - The Wwise threads are `AK::BankManager` (entry 0x80b830) and `AK::EventManager` (0x8571a0). Which thread calls `sceAudioOutOutput` is unknown.
  - Ajm has no line in any log: the runtime logs only errors, so whether the ATRAC9 instance (create at 0x858000) is ever created or run is unknown.
  - No probe up to 365 s hit `FATAL: Unsupported guest instruction`, so the lifted Wwise Vorbis code has not reached an unlifted instruction on the paths run so far.
- **Motion sensor input.** Done in Task 7.6.2: the sensor reports from `scePadOpen`, through GCMotion or a virtual pad, with `tilt` and `shake` script steps.
- **Saves.**
  - First boot (p2_22):
    - `sceSaveDataInitialize3`;
    - `DirNameSearch('infamousss%')` gives 0 hits;
    - `Mount2` mode 0x6 (CREATE|RDWR) of `infamousssAuto1`, then of `infamousssAuto0`;
    - `SaveIcon` and `SetParam`;
    - `dis.dat` opened with 0x601 (O_WRONLY|O_CREAT|O_TRUNC); it is 131,072 bytes in each directory.
  - Second boot (p2_32, seeded from p2_22):
    - `DirNameSearch` gives 2 hits;
    - `Mount2` mode 0x1 (RDONLY) of `infamousssAuto1`, and `dis.dat` opened with flags 0x0: **the boot load path is exercised**;
    - after that the autosaves alternate between Auto0 and Auto1, with mode 0x2 (~238 s, ~312 s).
  - **Not exercised:**
    - a manual save;
    - Load Game from the pause menu: p2_32 `sec_000330` highlights it but does not open it;
    - any `sceSaveDataDialog*` call.
  - **Not shown:** that a load restores progress. The seed is an autosave of p2_22's opening, so resuming at the billboard cannot tell a load from a new game.
  - The save root is `________________ __________ [CUSA00004]`: `sanitize_filename` (`ps4_savedata.c:76`) turns every byte of the non-ASCII `TITLE` into `_`. It is stable from run to run, so this is cosmetic.

**Order.**
- Task 8.1 gives the movie counts and the timeline that every other check uses.
- Tasks 8.2 and 8.3 are decided by 8.1's trace.
- Tasks 8.4 and 8.5 make audio measurable; 8.6 measures it and fixes what it finds; 8.7 checks A/V sync.
- Task 8.8 runs a new game through the prologue from an empty data dir; 8.9 is the save/load round trip.
- Task 8.10 is Gate 3.

TLOU and U4 runs: changes to `libSceVideodec` and `libSceAjm` reach TLOU's movie and audio paths. Each such fix runs the TLOU check in its own task. The trace-only changes (logging behind an env var, a summary line) are batched into Gate 3's runs.

### Task 8.1: Videodec trace: picture counts, access-unit census, a shared clock

The runtime logs only `first picture decoded`. Without a count, a cadence and the shape of each input, neither movie playback nor A/V sync can be checked. This task adds:
- an always-on one-line summary per decoder;
- a trace behind `PS4_VIDEODEC_LOG=1`;
- timestamps on the clock the screenshot cadence uses.

**Files:**
- Modify: `pkg/runtime/modules/libSceVideodec/ps4_h264_vt.h` and `ps4_h264_vt.c`. Add `H264AuCensus` and `h264_au_census()`: a portable Annex-B scan that uses the existing `next_start` (line 289) and `BitReader` (lines 30–66).
- Modify: `pkg/runtime/modules/libSceVideodec/ps4_videodec.c`:
  - `Vdec` (line 106) gets a `Ps4VideodecStats`;
  - `shim_sceVideodecCreateDecoder` logs the config and the resource info;
  - `shim_sceVideodecDecode` and `shim_sceVideodecFlush` count;
  - `shim_sceVideodecDeleteDecoder` prints the summary.
- Create: `pkg/runtime/modules/libSceVideodec/ps4_videodec.h` with `Ps4VideodecStats` and `int ps4_videodec_stats(const void *mem_base, uint64_t ctrl_addr, Ps4VideodecStats *out)`, for the test and for the summary.
- Modify: `pkg/runtime/modules/libSceVideoOut/ps4_metal_screen.m` (line 309). The `time cadence: ... first flip at %.3f s after start` line also prints the first flip's raw `CLOCK_MONOTONIC` seconds (`mono %.3f`), so trace times map onto `sec_<s>.png` names.
- Modify: `tests/host/vdecsw_test.c` (the stream maker `make_stream` at line 179, and the Videodec section at lines 980–1025), `tests/host/run_host_tests.sh` (the vdecsw block at line 186), and `README.md` (the debug env table at line 310).

**Interfaces:**
- `typedef struct { uint32_t nal_count; uint8_t nal_types[32]; uint32_t slices; int32_t first_mb_first_slice; bool has_idr; bool has_sps; } H264AuCensus;`
  - `first_mb_first_slice` is -1 when the AU has no slice;
  - `nal_types` holds the first 32 types in stream order.
- `void h264_au_census(const uint8_t *au, size_t size, H264AuCensus *out);` makes no allocation.
- `Ps4VideodecStats`: `aus`, `slices`, `max_slices_per_au`, `mid_picture_aus` (an AU whose first slice has first_mb_in_slice != 0, which means slice-by-slice input), `pictures`, `error_pictures`, `flush_pictures`, `first_picture_mono`, `last_picture_mono` (seconds, `CLOCK_MONOTONIC`), `first_pts`, `last_pts`, `min_fb_size` (the smallest `frameBufferSize` the guest passed) and `need_fb_size` (the largest NV12 size emitted).
- Log lines (stderr). `<n>` is the decoder's ordinal in the process, and `mono` is raw `CLOCK_MONOTONIC` seconds:
  - always: `[libSceVideodec] decoder <n> deleted: AUs A (slices S, max per AU M, mid-picture K), pictures P (flushed F, error E), first picture mono X, last mono Y, pts first..last, frame buffer min B need N`;
  - `PS4_VIDEODEC_LOG=1`:
    - `[libSceVideodec] decoder <n> created: codec C profile 0xPP level 0xLL max WxH dpb D -> rsrc cpu 0x.. cpuGpu 0x.. maxFrameBuffer 0x.. align 0x..`;
    - for each of the first 8 AUs of a decoder: `[libSceVideodec] decoder <n> au <i>: <size> bytes, NAL [7 8 6 5 5 ...], slices S, first_mb F, pts P dts D`;
    - every 2 s per live decoder: `[libSceVideodec] decoder <n> at mono X: AUs A, pictures P, last pts T`.

- [ ] **Step 1: Write the failing test.** Extend `tests/host/vdecsw_test.c`:
  - **Census.** Run `h264_au_census` on:
    - an AU of S1: NAL types as built (AUD, SPS, PPS, IDR), slices 1, first_mb 0;
    - a multi-slice stream S5, made by `make_stream` with the software encoder (`kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder = false`) and `kVTCompressionPropertyKey_MaxH264SliceBytes = 1500` at 640x368. The test asserts that the encoder honoured the property: at least 4 slices per picture. If it did not, the test fails; it never passes without a multi-slice stream;
    - S5's second slice NAL alone: slices 1, first_mb > 0;
    - an SPS-only AU: slices 0, first_mb -1.
  - **Counts through the guest API.** Decode S1 and S5 through `shim_sceVideodecDecode` and `Flush` as at line 1006. Then `ps4_videodec_stats` gives:
    - `aus` = the AUs fed, `pictures` = the frames encoded, `error_pictures` 0, `mid_picture_aus` 0;
    - `max_slices_per_au` = S5's census;
    - `min_fb_size` = the buffer size passed;
    - `first_pts` < `last_pts`, and `last_picture_mono` ≥ `first_picture_mono`.
    Feeding two corrupt AUs (line 758) gives `error_pictures` 2.
  - **Local fixture.** With `tests/host/data/game/infamous/splash_europe.bsf` (a copy of the game file, git-ignored):
    - split it into access units by H.264 7.4.1.2.3: a new AU starts at an SPS, PPS or SEI after a slice, or at a slice with first_mb_in_slice = 0 after a slice;
    - feed it through the guest API with pts = 3003·i;
    - expect 309 pictures, 0 error pictures, display order (pts rising after the reorder) and `max_slices_per_au` 17.
    - Without the file, print `SKIP: videodec splash fixture: needs local fixture tests/host/data/game/infamous/splash_europe.bsf (game data, not distributed)`.

  Run the vdecsw block of `run_host_tests.sh`. Expected: a compile error (no `ps4_videodec.h`, no `h264_au_census`). That is the RED state.
- [ ] **Step 2: Implement.**
  - The census runs once per Decode, on the guest bytes, with no allocation.
  - The counters live in `Vdec` and are written on the guest thread that calls Decode. `ps4_videodec_stats` reads them under the decoder's existing `dec_lock`.
  - The 2 s line uses the Decode call's own time check, with no thread.
  - `mono` comes from `clock_gettime(CLOCK_MONOTONIC)`.
  - The summary is printed before `h264vt_destroy`.
- [ ] **Step 3: Verify (GREEN).**
  - `bash tests/host/run_host_tests.sh` through heavy_lock: exit 0, `vdecsw_test` PASS (and the SKIP line without the fixture), ending `capture tools: PASS (Ran N tests)`.
  - Copy the fixture locally, run `vdecsw_test` again, and record the census line.
  - `go vet ./...`, `gofmt -l cmd pkg` (empty), `go test ./...`.
- [ ] **Step 4: Commit** `videodec: per-decoder counts, access-unit census and a trace behind PS4_VIDEODEC_LOG` with the files by path.
- [ ] **Step 5: Probe.**
  - Rebuild inFAMOUS.
  - Add to `probe_run.sh` (outside the repo) `PS4_AUDIO_NULL=1 PS4_AUDIO_DUMP=$O/audio.wav` as defaults, so that probes no longer play on the owner's speakers and every probe leaves its audio. Arguments after the tag still override them.
  - Run `heavy_lock.sh probe_run.sh p3_1 150 PS4_VIDEODEC_LOG=1 PS4_SCREENSHOT_EVERY_SEC=2` from an empty data dir.
  - Expected:
    - two `decoder <n> deleted` lines, or one plus a live opening decoder at the kill;
    - splash: `pictures 309 (... error 0)`, `mid-picture 0`;
    - `first picture mono` maps, through the cadence line's `mono`, to the shot where the SP logo first shows;
    - opening: pictures rising toward 1,691 in the 2 s lines.

  Record, from `last − first` mono against the picture count, the decode rate in pictures per second (29.97 expected).
- [ ] **Step 6: Rule** in the ledger. Each ruling decides the task after it:
  - `mid-picture K > 0`, or `slices per AU` = 1 while the census of the file says 17: the game feeds slices, and Task 8.2 applies;
  - `min_fb_size < need_fb_size`, or the game's `maxFrameBuffer` differs from what it allocates: Task 8.3 applies;
  - a decode rate off 29.97 by more than 2 %, or pictures < 309 for the splash: triage as in Task 7.6 (what the MovieDecoder thread waits for), with a contained fix and a host test.

  Ledger: `P3 probe p3_1: splash pictures P (error E, mid-picture K), opening pictures P2 by kill, decode rate R/s, first picture at sec_<s>, fb min/need B/N`.

### Task 8.2: Access units from slices (decided by Task 8.1)

**If Task 8.1 shows one AU per Decode (`mid-picture 0`):**
- Rule in the ledger: `Task 8.2: not needed: the game passes whole access units (p3_1: M slices per AU, mid-picture 0)`.
- No code. Task 8.1's S5 and fixture tests stay as the guard.

**Otherwise** (the game feeds a slice, or a group of slices, per call):

**Files:** `pkg/runtime/modules/libSceVideodec/ps4_h264_vt.c` (`parse_au` at line 697 and `h264vt_decode` at line 783), `ps4_h264_vt.h`, `ps4_videodec.c`, `tests/host/vdecsw_test.c`.

- [ ] **Step 1: Facts.**
  - On the console, `sceVideodecDecode` takes one AU (shadPS4 `videodec_impl.cpp`, which feeds FFmpeg's parser-less decoder).
  - What does it do with a slice? It either returns no picture until the next AU starts, or reports an error. Find out from shadPS4 and from the game's call site at 0x28bec3: what it does with the return value and with `isValid == 0`.
  - Record the source of each fact.
- [ ] **Step 2: Test first (RED).** Feed S5 slice by slice through `shim_sceVideodecDecode`, with the pts on the first slice of each picture. Expect:
  - the same pictures, in the same display order and with the same luma levels, as whole-AU decoding;
  - no error pictures;
  - `isValid == 0` on calls that complete no picture.

  Run it and see it fail: the current core makes one VideoToolbox sample per call.
- [ ] **Step 3: Implement (GREEN).**
  - The core buffers the slices of the current picture (one reusable buffer per decoder, grown to the largest AU seen; it is not freed per AU).
  - It submits that buffer when the next picture's first VCL NAL arrives. The test is H.264 7.4.1.2.4: first_mb_in_slice = 0, or a change of frame_num, pps_id, nal_ref_idc, POC lsb or idr_pic_id.
  - `h264vt_finish` submits it too.
  - The buffered AU carries the pts of its first slice.
- [ ] **Step 4: Verify.**
  - Host suite: exit 0, with all existing vdecsw streams (S1–S4) unchanged.
  - The TLOU check from the Shared commands (Videodec is TLOU's movie path), and a U4 120 s boot (Vdecsw shares the core).
  - Probe `p3_<n>`: `mid-picture` may stay > 0, since it counts the input, but `pictures 309, error 0`.
- [ ] **Step 5: Commit** `h264: access units assembled from slices`, with the files by path.

### Task 8.3: Frame-buffer size, pitch and colour of the movie pictures (decided by Task 8.1)

**Known facts:**
- `QueryResourceInfo` sizes the buffer with pitch align(w, 256), height align(h, 16) and NV12, rounded up to 64 KiB.
- `vdec_emit` writes pitch align(w, 64).
- shadPS4 (`videodec.cpp` `ComputeFrameSizeBytes`, `videodec_impl.cpp`) does the same, but pads with +0x4000 instead of rounding to 64 KiB.
- The console's own numbers are not public.

At 1920 the splash shows the game honours `framePitch`. The 640x360 (`tv/*`) and 544x304 (`ui/powerk_*`) movies have pitches where the two rules differ (640/768, 576/768), and none has been reached yet.

- [ ] **Step 1: From p3_1's trace:**
  - check that the game's `frameBufferSize` ≥ `need`, and that its allocation equals the `maxFrameBuffer` we reported (the guest reads `rsrc->maxFrameBufferSize`);
  - if both hold, rule `Task 8.3 size: consistent (min B ≥ need N)`.
  - Otherwise write the RED test in `vdecsw_test.c`: a config of each of the three sizes, where Decode into a buffer of exactly the reported size must succeed with the picture fields as emitted. Then fix `shim_sceVideodecQueryResourceInfo` (`ps4_videodec.c:164`) so that its size covers what `vdec_emit` writes, from the same `h264vt_pitch` and `h264vt_aligned_height`.
- [ ] **Step 2: Pitch at the small sizes.** When a probe reaches a 640x360 or 544x304 movie (ledger: the first `decoder <n> created: ... max 640x...`):
  - capture that frame (`PS4_GNM_CAPTURE_FRAME` at a present inside the movie);
  - read the T# the game's NV12 pass binds over the frame buffer, in `manifest.json`;
  - its pitch must equal our `framePitch`.

  If it does not, the game derives the pitch from a rule we do not follow. Rule on it with the capture as evidence, and fix it with a host test that decodes that size and checks the reported pitch. No such movie is expected before Seattle; the gate does not wait for it.
- [ ] **Step 3: Colour.**
  - Add `PS4_VIDEODEC_DUMP=<dir>:<picture index>` to `ps4_videodec.c`: Videodec writes that picture of each decoder as `<dir>/dec<n>_pic<i>.nv12`, with a 16-byte header (width, height, pitch, pts). The write happens once, from `vdec_emit`. Test first in `vdecsw_test.c`: S1's picture 5 is dumped, and the file's luma levels are those `display_of` reads from the guest frame buffer. It is RED until the env var exists.
  - `tools/nv12_to_png.py` converts the dump to PNG with BT.709 limited range. Its test goes in `tools/tests/test_nv12_to_png.py`: a synthetic NV12 of known Y/Cb/Cr bars against hand-computed RGB.
  - Compare the dump of an opening picture with the screenshot of the flip that shows it (its mono time against the cadence line): `python3 tools/refcompare.py <shot> <picture.png> --max-mean-dy 8 --max-hist-l1 0.25`.
  - A tint, a range or a matrix error shows here before Phase 4. Fix it in the renderer with a test, or rule that it is the game's own grading.
- [ ] **Step 4: Commit** each change on its own (`videodec: ...`, `tools: nv12_to_png`), with the TLOU check for any change to `ps4_videodec.c` outside the trace.

### Task 8.4: AudioOut on the shared clock, with gap and late counters; a WAV activity tool

The final-mix WAV dump (`PS4_AUDIO_DUMP`) and the headless device (`PS4_AUDIO_NULL`) exist and have a host test (`audioout_downmix_test.c`). What a probe cannot see yet:
- where WAV sample 0 sits on the movie and screenshot timeline;
- whether a port's grains came in real time. `underruns` counts mix periods that found the ring short. It does not count how much silence went in, how late the game was, or the outputs a window should have had.

**Files:**
- Modify: `pkg/runtime/modules/libSceAudioOut/ps4_audioout.c`:
  - `Ps4AudioPort` (lines 78–106): `last_output_us`, `max_gap_us`, `late_outputs`, `underrun_frames`, `win_outputs`, `win_start_us`, `first_sound_us`;
  - `dump_open` (line 190): prints `frame 0 at mono %.3f`;
  - `audio_mix` (line 275): counts underrun frames;
  - `ps4_audioout_port_output` (line 686): records the gap, a late output (the ring was empty after the port's first output) and the first grain with a non-zero sample;
  - `audio_stats_maybe_log` (line 217): the new fields and `mono`.
- Modify: `pkg/runtime/modules/libSceAudioOut/ps4_audioout_internal.h`: `Ps4AudioPortStats` and `int32_t ps4_audioout_port_stats(int32_t handle, Ps4AudioPortStats *out)`.
- Create: `tests/host/audioout_timing_test.c`, registered in `tests/host/run_host_tests.sh` after the downmix test (line 79).
- Create: `tools/wav_activity.py` and `tools/tests/test_wav_activity.py`.
- Modify: `README.md` (the debug env table).

**Interfaces:**
- Stats line (`PS4_AUDIO_LOG=1`, every ~2 s): `[AudioOut] port N ... outputs=O (window W, expected E) max_gap_ms=G late=L underruns=U underrun_frames=F mono=X`. E is the window length × freq / len.
- Once per port: `[AudioOut] port N first non-silent grain at mono X (after K outputs)`.
- `tools/wav_activity.py <wav> [--window S] [--threshold-db D] [--require-sound A-B] [--onset-after T] [--cut A-B <out.wav>]`. It reads PCM16, PCM32 and float32 WAV. When the header's data size is stale (a killed run), it uses the file size and says so.
  - It prints the duration, then one line per window: start, RMS dBFS, peak, and the clipped share (|x| ≥ 0.999).
  - `--require-sound A-B`: exit 1 unless at least 90 % of the windows in [A, B) are above D (default −50 dBFS).
  - `--onset-after T`: the first 10 ms window at or after T above D.
  - `--cut` writes an excerpt for listening.
  - Only the standard library is used.

- [ ] **Step 1: Write the failing tests.**
  - `audioout_timing_test.c` runs with `PS4_AUDIO_NULL=1`, `PS4_AUDIO_LOG=1` and `PS4_AUDIO_DUMP=$T/timing.wav` in its environment (set by the script):
    - open a FLOAT_8CH port with 1024-frame grains;
    - output 40 silent grains, then 60 grains of a 440 Hz sine, at the device pace (each call blocks);
    - then sleep 300 ms, then 20 more grains.
  - It checks `ps4_audioout_port_stats`:
    - `outputs` 120;
    - `max_gap_us` ≥ 290,000;
    - `late_outputs` ≥ 1;
    - `underrun_frames` ≥ 300 ms × 48 kHz minus the ring capacity;
    - `first_sound_us` between the 40th and 41st output's times.
  - It checks the dump:
    - its length matches the wall time of the run within 2 device periods;
    - the stderr line `frame 0 at mono` parses;
    - the first non-zero sample, mapped through that mono, lies within 25 ms of `first_sound_us`.
  - `test_wav_activity.py`:
    - synthetic WAVs: silence plus a sine burst at 2.0–3.0 s, in float32 and PCM16, and a file whose header says 0 data bytes;
    - checks the window RMS, `--onset-after 1` = 2.00 s ±0.01, `--require-sound 2-3` exit 0, `--require-sound 0-2` exit 1, the clipped share of a full-scale square, and that `--cut` round-trips.

  Expected: the C test does not compile (no `ps4_audioout_port_stats`), and the Python test fails on import (no module).
- [ ] **Step 2: Implement.**
  - All counters are updated under the existing `g_audio_lock`.
  - Times come from `get_time_micros()` (mach time is monotonic, like the cadence clock).
  - The `mono` printed is `CLOCK_MONOTONIC` seconds, so all three timelines agree.
  - The render callback and `ps4_audioout_port_output` make no allocation and no extra system call.
- [ ] **Step 3: Verify (GREEN).** Host suite through heavy_lock: exit 0, with `audioout_timing_test: PASS`, `audioout_downmix_test` unchanged, and `capture tools: PASS (Ran N tests)`, N up by the new tool tests. Then `go vet ./...`, `gofmt -l cmd pkg`, `go test ./...`.
- [ ] **Step 4: Commit** `audioout: port timing counters and the dump on the monotonic clock` and `tools: wav_activity`, each with its files by path.

### Task 8.5: Ajm trace

Whether inFAMOUS's ATRAC9 instance ever runs cannot be seen: `ps4_ajm.c` logs only errors.

**Files:** `pkg/runtime/modules/libSceAjm/ps4_ajm.c`, which is touched in these places:
- `shim_sceAjmModuleRegister` (line 836);
- `shim_sceAjmInstanceCreate` (890) and `shim_sceAjmInstanceDestroy` (960);
- the batch worker's job loop;
- `shim_sceAjmBatchWait` (1397).

Also `ps4_ajm.h` (`PS4AjmInstanceStats`, `int ps4_ajm_instance_stats(uint32_t context, uint32_t instance, PS4AjmInstanceStats *out)`), `tests/host/ajm_test.c` and `README.md`.

**Interfaces:**
- With `PS4_AJM_LOG=1`:
  - `[AJM] register codec C`;
  - `[AJM] instance I created: codec C flags 0x..`;
  - every 2 s per live instance: `[AJM] instance I: jobs J, frames F, samples S, errors E (last 0x..)`.
- Always: `[AJM] instance I destroyed: jobs J, frames F, errors E`.
- `PS4AjmInstanceStats`: `jobs`, `frames_decoded`, `samples_out`, `errors` and `last_error`, all updated by the worker under the existing batch lock.

- [ ] **Step 1: Test first.** In `ajm_test.c`:
  - create an ATRAC9 instance;
  - run a batch of one decode job over a zeroed 372-byte frame with the config FE 72 2E 70;
  - then a batch of two jobs, the second naming a missing instance (the existing case).

  `ps4_ajm_instance_stats` must report `jobs` 1 for the first batch. `frames_decoded` and `errors` must match the job's result sideband, whatever libatrac9 makes of the zero frame. The second batch must not count against the first instance. Expected: a compile error, which is RED.
- [ ] **Step 2: Implement (GREEN).** The counters go in the existing instance slot, with no allocation. The 2 s line is printed from the worker after a batch, not from a thread of its own.
- [ ] **Step 3: Verify.** Host suite exit 0 (`ajm_test` PASS), `go vet`, `gofmt`, `go test`. Ajm is TLOU's and U4's audio path, but this change adds only counters and lines, so it is batched into Gate 3's runs.
- [ ] **Step 4: Commit** `ajm: per-instance counts and a trace behind PS4_AJM_LOG`.

### Task 8.6: Audio health: is there sound, does it keep real time

- [ ] **Step 1: Probe.** Rebuild inFAMOUS, then run from an empty data dir:

```bash
$W/tools/heavy_lock.sh $W/infamous_research/probe_run.sh p3_a1 180 PS4_AUDIO_LOG=1 PS4_AJM_LOG=1 PS4_VIDEODEC_LOG=1 PS4_SCREENSHOT_EVERY_SEC=5
L=$W/infamous_research/runs/p3_a1/game.log
grep "first non-silent grain\|dumping final mix" $L
grep "\[AudioOut\] port 1 " $L | tail -20
grep "\[AJM\]" $L | head -20
python3 tools/wav_activity.py $W/infamous_research/runs/p3_a1/audio.wav --window 1
```

  Then do the same on the seeded route into the cannery: `p3_a2`, 380 s, `SEED_DATA=runs/p2_22/data`, the Gate 2 pad script.
- [ ] **Step 2: Measure and record**, per phase (splash, opening, loading, the billboard tutorial, cannery gameplay):
  - **Sound.** The window RMS of `audio.wav`, mapped to the phase by `frame 0 at mono` and the cadence line, and port 1's `in_rms` and `nonzero_bufs`. A phase whose windows are below −50 dBFS is silent.
  - **Real time.** Over the windows where port 1 has started:
    - `outputs` per window against `expected`, which should be within 2 %;
    - `max_gap_ms`, which should stay at or below 2 grains (42.7 ms) outside loading screens;
    - `late` and `underrun_frames`, which should be 0 in gameplay windows.
  - **The thread.** Which guest thread calls `sceAudioOutOutput`. Take an lldb thread backtrace at 60 s: the thread blocked in `ps4_audioout_port_output`. Name its entry (expected: `AK::EventManager`, 0x8571a0).
  - **Ajm.** Whether an ATRAC9 instance is created, and its jobs, frames and errors.
  - **Lifter.** No `FATAL: Unsupported guest instruction` in either log.
  - **By ear.** Cut three 10 s excerpts with `--cut` (splash, opening, cannery) into the probe dir. Ask the owner to listen to them, and record his verdict, or that he has not listened yet.
  - Ledger: `P3 probe p3_a<n>: port 1 rms by phase ..., outputs/expected ..., max gap ..., late L, underrun frames F; Ajm instances ...; audio thread <name>`.
- [ ] **Step 3: The loop.** Repeat until both probes show sound in every phase and real time in gameplay. Budget: about 3 fixes; then report.

  **Triage**, in order:
  - **Port 1 gets only zeros.** Wwise renders silence. Check, in this order:
    - the bank loads: the opens and reads of `*.xpps` and `psarc/*` (short reads, offsets);
    - the Wwise job waits: FINDINGS says the game needs `cond_wait` to return EPERM for a mutex the caller does not hold (guest 0x803e90);
    - `sceAudioOutSetVolume` values, in the log;
    - an Ajm error line.
  - **Underruns or gaps in gameplay.** The audio thread does not keep 21.3 ms. Sample the process for 10 s (`sample <pid> 10`, under heavy_lock while the probe runs) and list the hot guest functions on that thread.
    - A lifting-quality problem in a hot function (Vorbis inverse MDCT, the mixer) is written up as a lifter task with the function and its share.
    - A runtime wait on the path (a mutex, a cond, a semaphore with a wrong timeout) is fixed in the runtime.
  - **Sound in the wrong channels, or distorted** (clipped share > 0.1 %, or by ear). Check the 8ch fold with `audioout_downmix_test`'s rule and the port's `SetVolume` per channel.

  Each fix gets a host test, `go vet`/`gofmt`/`go test`/the host suite, its own commit `<area>: <what>`, a ledger line `P3 <n>: <symptom> -> <root cause> -> <fix commit>`, and the TLOU check if it is on a shared path (AudioOut, Ajm, sync, the lifter). A failure that needs more than a contained fix is written up as Task 8.6.<k> before it is started.

### Task 8.7: Movie A/V sync

The `.bsf` files have no audio. The sound under a movie is a Wwise event the game starts with the movie (`MovieStarted`, an inference from the strings in `phase3-media-recon.md`).

- [ ] **Step 1: The timelines.** From p3_a1 (or the next probe with all three traces):
  - picture times: the 2 s `decoder` lines, `first picture mono`, `last picture mono`, and the pts step (the median difference gives the pts unit: 3003 is 90 kHz at 29.97 fps);
  - the audio onset: `wav_activity.py --onset-after <first picture − dump mono0 − 1 s>`;
  - the shots of the movie at 2 s cadence.
- [ ] **Step 2: Check.**
  - (a) **Onset.** |audio onset − first picture| ≤ 100 ms for the splash and the opening. Decode runs ahead of display by the game's picture queue, so the bound is a few frames, not one.
  - (b) **Drift.** Over the opening (56.4 s): |(last − first picture mono) − (last − first pts in seconds)| ≤ 33 ms, the length of one frame. The audio clock of the headless device is wall time by construction (`audio_null_device_main`), so a video clock off by more than that is drift.
  - (c) **By eye and ear.** If the opening has narration or a hard cut with a sound (a door, an impact), the shot at that time and the WAV excerpt line up. Cut a 6 s excerpt around it for the owner.

  Ledger: `P3 sync: onset splash Δ ms, opening Δ ms; drift over the opening D ms`.
- [ ] **Step 3: If (a) or (b) fails**, find which clock is off:
  - the game's movie clock: `sceKernelGetProcessTime`, `sceKernelReadTsc` against `sceKernelGetTscFrequency`, or the vblank events at our 120 Hz flips against the console's 60 Hz;
  - or Wwise's playback position, which follows the AudioOut grains it has written.

  Fix the HLE clock that differs from the console with a host test (a clock read twice across a known sleep). TLOU check: timing is a shared path. Budget: 2 fixes; then report.

### Task 8.8: A new game through the prologue from an empty data dir

Gate 2 reached the cannery from a seeded data dir. Gate 3 needs a new game from nothing: splash, the opening movie with sound, then the prologue under control.

- [ ] **Step 1: The route.**
  - Copy the pad scripts into `$W/infamous_research/routes/` (outside the repo, where scratchpads do not reach): Task 7.6.2's `spray_script5.txt`, and Gate 2's free-movement and pause steps from its result paragraph.
  - Build `prologue.txt` from them, timed for a first boot. The first boot has the opening movie before the tutorial, so take the tutorial's prompt time from p3_1's shots (`[pad] script started at` + the shot of the "Hold Wireless Controller Sideways" prompt).
  - Add a no-input pause of 10 s, then a stick move, in the cannery, as Gate 2's control check.
- [ ] **Step 2: Probe** `p3_p<n>`, 480 s, `PS4_PAD_SCRIPT="$(cat $W/infamous_research/routes/prologue.txt)"`, `PS4_AUDIO_LOG=1`, `PS4_SCREENSHOT_EVERY_SEC=10`. Expected:
  - `(time limit)`, with no FATAL, abort stub or Unresolved line;
  - the shots pass, in order: splash, opening, billboard tutorial passed, night harbour, the cannery objective;
  - the two shots of the no-input pause are identical, and the shot after the stick move differs;
  - `wav_activity --require-sound` passes over the opening's interval;
  - autosaves are written, with Mount2 mode 0x6 on the first boot.
- [ ] **Step 3: The loop.** Same as Task 7.6, with the ledger prefix `P3`. Budget: about 3 fixes; then report. Renderer artefacts that do not block the route (bloom, ghosting) are Phase 4, and are not fixed here.

### Task 8.9: Save and load round trip

**What is known:** the boot reads the latest autosave (Mount2 RDONLY, `dis.dat` read). **What is not known:** whether the game resumes from it, and whether a manual save and Load Game work.

**Files** (only if the loop finds a defect): `pkg/runtime/modules/libSceSaveData/ps4_savedata.c`, `pkg/runtime/modules/libSceSaveDataDialog/ps4_savedata_dialog.m`, and their host tests.

- [ ] **Step 1: Facts.** For each SaveData and SaveDataDialog call the run reaches, write down its console behaviour, with shadPS4 (`src/core/libraries/save_data/`) as the fact source:
  - the Mount2 modes and the results for a missing directory;
  - DirNameSearch's sort order and the info it fills;
  - the dialog's list result (`SaveDataDialogResult`: mode, result, dirName, buttonId);
  - what the auto answer of `PS4_SAVEDATA_DIALOG=auto` (`sdd_auto_pick`) returns for a save list and a load list.
- [ ] **Step 2: Run A (write).** `p3_save_a`: the prologue route to the cannery.
  - Then Options (0x8), Cross on Save Game (the first item, p2_32 `sec_000320`).
  - The dialog is answered by `PS4_SAVEDATA_DIALOG=auto PS4_SAVEDATA_DIALOG_PICK=new`; then Circle.
  - Keep playing until an autosave after the manual save.
  - Expected in the log:
    - `sceSaveDataDialog*` calls;
    - a Mount2 with the CREATE bit for a new dirName (not `infamousssAuto*`);
    - `SetParam`, and the `dis.dat` write;
    - Umount.
  - Record the dirName, the shot before the save (`T_save`) and the md5 of every `dis.dat`.
- [ ] **Step 3: Run B (load at boot).** `p3_save_b`, with `SEED_DATA=runs/p3_save_a/data`, no route input except the autopress until the first gameplay.
  - Expected:
    - DirNameSearch hits = the directories of A;
    - Mount2 RDONLY of the directory the game picks (record which one, and its mtime order);
    - `dis.dat` read in full: the opens and reads, with no short read;
    - the first gameplay shot is in the cannery at A's last save point, not at the billboard. **That is the proof that the load restored progress.**
  - Compare it with A's shot at that point by eye; the camera may differ. Then check that the md5 of the `dis.dat` files A wrote equals that of B's seed copy.
- [ ] **Step 4: Run C (Load Game from the pause menu).** `p3_save_c`, with the same seed.
  - From the first gameplay: Options, Down twice (Load Game), Cross. The dialog is answered with `PS4_SAVEDATA_DIALOG_PICK=<A's manual dirName>`; then confirm.
  - Expected:
    - Mount2 RDONLY of the manual directory, and its `dis.dat` read;
    - a loading screen, then gameplay at `T_save`'s place.
- [ ] **Step 5: The loop** for any step that fails:
  - the game hangs in the dialog (it polls `sceSaveDataDialogUpdateStatus` forever);
  - a Mount2 or read error code;
  - the resumed place is wrong.

  Triage the call's result against Step 1's facts. Fix it with a host test through the guest entry, as in Task 7.6. Budget: about 3 fixes; then report. A fix to SaveData or the dialog runs the TLOU check (TLOU saves through the same module).
- [ ] **Step 6: Ledger.** `P3 save: manual dir <name> written at T_save (sec_<s>); boot load resumes at <place> (p3_save_b sec_<s>); Load Game resumes at <place> (p3_save_c sec_<s>)`.

### Task 8.10: Gate 3

- [ ] **Step 1: inFAMOUS.** Rebuild from the Phase 3 head.
  - Run `gate3_1`, 480 s, from an empty data dir, with the Task 8.8 route plus Task 8.9's manual save, and `PS4_AUDIO_LOG=1 PS4_VIDEODEC_LOG=1 PS4_AJM_LOG=1`.
  - Then run `gate3_2`, 240 s, with `SEED_DATA=runs/gate3_1/data` and Task 8.9's Load Game steps.

```bash
G1=$W/infamous_research/runs/gate3_1
tail -2 $G1/mon.txt; grep -n "FATAL\|abort stub\|Unresolved" $G1/game.log | head
grep "decoder [0-9]* deleted\|first non-silent grain\|frame 0 at mono" $G1/game.log
python3 tools/wav_activity.py $G1/audio.wav --require-sound <opening first..last picture, WAV seconds>
grep "ps4-savedata\] Mount2" $G1/game.log $W/infamous_research/runs/gate3_2/game.log
```

  Expected:
  - both runs end `(time limit)`, with no FATAL, abort stub or Unresolved line;
  - **the intro movie plays with sound:**
    - splash `pictures 309 (... error 0)`, and the opening's picture count reaches 1,691 (or its live count at the kill matches the time since its first picture at 29.97 fps ±2 %);
    - the shots show both movies;
    - `--require-sound` exits 0 over the opening;
    - onset and drift are within Task 8.7's bounds;
    - the owner's by-ear verdict on the excerpts is recorded;
  - **the prologue is controllable:** the no-input shots are identical, and the shot after input differs (as Task 8.8);
  - **a save is written and loads back:**
    - gate3_1 has the manual save's Mount2 with CREATE, and its `dis.dat` write;
    - gate3_2 loads it (Mount2 RDONLY of that dirName), and its shot after the load is at gate3_1's save point;
  - audio real time in gameplay windows: `late` 0, `underrun_frames` 0, `max_gap_ms` ≤ 42.7.

  Look at every shot named here and describe it in the report.
- [ ] **Step 2: TLOU,** with a build of the Phase 3 head in `$W/infamous_research/tlou_check`, run as in Task 7.7, Step 2:
  - Metal 3 with MetalFX at 2560x1440, warm cache, tag `iss_tlou_gate3`;
  - Metal 4, tag `iss_tlou_gate3_m4`.

  Expected for both: fatal 0, gpu_err 0, watchdog 0, and fps within ±3 of Gate 2's numbers (Task 7.7's result paragraph). Look at `sec_000060.png` and `sec_000100.png`: normal gameplay. TLOU plays movies through `sceVideodec` and audio through Ajm, so its intro movie must still decode: `decoder 1 deleted: ... error 0` in its log.
- [ ] **Step 3: Uncharted 4,** 120 s, run as in Task 7.7, Step 3 (`u4_check`, tag `iss_u4_gate3`). Expected: fatal 0, and `sec_000100.png` shows the first-launch brightness screen.
- [ ] **Step 4: Go and the host suite.** `go vet ./...`, `gofmt -l cmd pkg` (empty), `go test ./...`, and the host suite through heavy_lock. Expected: all pass; the suite exits 0 and ends `capture tools: PASS (...)`.
- [ ] **Step 5: Ledger.** Update `infamous-boot-recon.md` with "Gate 3":
  - the movie counts, the sync numbers and the audio numbers by phase;
  - the save dirName and the load shots;
  - the last probe's counts line, game_rss, and the imports reached.
- [ ] **Step 6: Commit** a "Gate 3 result" paragraph under this task, in a docs commit of this plan file only.

## Phase 4: graphics fidelity (gate 4: the reference scenes have no obvious artefact)

### Task 9: Plan Phase 4

- [ ] **Step 1:** Ask the owner for permission to download PS4 reference footage of the prologue and the first Seattle district. Take time-matched screenshots of the same scenes.
- [ ] **Step 2:** For each visible difference, capture the frame (`PS4_GNM_CAPTURE_FRAME`), find the first wrong pass with `tools/gnm_capture_view.py` and replay it. Record the pass, shader and suspected gap.
  - FINDINGS.md lists what the PC port needed: GPU readbacks for particles and drains, occlusion queries for lights, and others. Check each against our renderer first.
  - Check these first, from the PC port:
    - **Occlusion.** EVENT_WRITE ZPASS_DONE begin/end pairs of u64 values, bit 63 valid, waited on
      with WAIT_REG_MEM; light flares are sized from them. With fake counts, headlights flicker. The
      count is taken with depth attached even with depth test off. On Metal this means
      visibility-result buffers.
    - **Readbacks.** GPU-simulated particles (drain smoke, drones) need their results read back by
      the CPU.
    - **Compute copies.** Shader `3d5ebf4e` copies render-target memory with a dword memcpy (a 1080p
      depth buffer as R32F, G-buffer targets), and the result is sampled in another format.
    - **Translator.** Wave64 ballots on the odd half; separate stencil test and op values;
      S_WQM_B64; V_RCP/V_LOG without clamping; saturate keeping NaN; BC 1D textures; MSAA passes.
- [ ] **Step 3:** Write Tasks 9.1…9.n, one per root cause, each with a replay fixture as its failing test (a local game fixture), and the Gate 4 task. Commit.

**Draft (Task 8): the known artefacts.** Task 9 Step 3 turns these into final tasks once Gate 3 holds and the reference shots exist. They come from the Phase 2 probes, as of the merge of infamous-geom (62fcaf5):
- **A white bloom disc over the centre** of every gameplay frame. It is a soft-edged disc covering about a third of the screen: p2_33 `sec_000340` (cannery) and p2_762c `sec_000250` (night harbour).
- **Ghosted double images and banding** (Task 7.6 loop 3 report).
- **Half-drawn night frames with black quadrants** (p2_31 `sec_000250`, `sec_000270`).
- **Does the geometry work change these?** The geom fixes (vertex stride 2 as inlined buffer loads, the 2048-layer cube T#, cube faces) are in 62fcaf5. p2_762c and p2_33 ran before that merge, and still show 18–23k stride-2 skips and the null 2048-layer T#.
  - geom_f2 and geom_f2_cold (the geom build) show 0 stride-2 skips and no uncreatable T#.
  - But they run 120 s from an empty data dir and end at the opening (text crawl `sec_000060`, convoy `sec_000100`).
  - **No gameplay shot exists on a build with the geom fixes.** Whether the three artefacts remain is the first step of each task below.
- **Movie colour** (Task 8.3, Step 3) joins this list if the NV12 check found a difference that the game's grading does not explain.

The method is the same for every artefact:
1. a time-matched shot on the seeded route;
2. a capture of one frame that shows it (`PS4_GNM_SYNC_ENCODE=1 PS4_GNM_CAPTURE_FRAME=<present> PS4_GNM_CAPTURE_DIR=$W/infamous_research/captures/<tag>`);
3. the pass overview (`python3 tools/gnm_capture_view.py <frame_dir>`);
4. the first pass whose output is wrong, replayed with `tools/gnm_replay` (`gnm_replay <frame_dir> <pass> --out <dir>`, after a capture with `PS4_GNM_CAPTURE_REPLAY=<a>-<b>`);
5. the gap named (translator, renderer state or format);
6. a fix with a host test from that pass as a local fixture under `tests/host/data/game/infamous/` (SKIP without it), or from a synthetic shader when the gap is generic.

Each fix runs the TLOU check: the translator and the renderer are shared.

### Task 9.1: Reference shots (draft)

- [ ] **Step 1: Ask the owner** for permission to download PS4 reference footage of:
  - the opening convoy;
  - the billboard tutorial (day);
  - the night harbour;
  - the fish cannery;
  - the first Seattle district.

  Name the source, the files and their sizes in the question. Nothing is downloaded before he says yes.
- [ ] **Step 2: Build the shot pairs.**
  - With consent: cut one still per scene from the footage at a moment that is easy to recognise (a fixed camera in a cutscene, or an objective text on screen). Store them in `$W/infamous_research/reference/` (outside the repo, never committed).
  - Match each still with our shot of the same moment. The seeded route makes it reproducible: `PS4_SCREENSHOT_EVERY_SEC` plus a `PS4_PAD_CTL` "shot" request at the cue.
  - Without consent: the gate falls back to the owner judging our shots by eye. The plan says so, and the gate is not claimed without his verdict.
- [ ] **Step 3: Compare.** Run `python3 tools/refcompare.py <ours.png> <ref.png> --json <out>` per pair (exposure, tint, sky) and look at each pair by eye. List every visible difference in the ledger: `P4 ref <scene>: <difference>`.

### Task 9.2: The white bloom disc (draft)

- [ ] **Step 1: Is it still there?** Run a seeded probe on the Phase 3 head into the cannery (Gate 2 route, 360 s, shots every 10 s). If the disc is gone, rule it fixed by 62fcaf5 and stop.
- [ ] **Step 2: Capture** a cannery frame with the disc.
  - Mark the passes after the lighting pass replayable (`PS4_GNM_CAPTURE_REPLAY=<lighting pass>-<last>`).
  - In the overview, find the first pass whose output has the disc: the bright-pass downsample, the blur chain, the lens-flare composite, or the luminance adaptation.
- [ ] **Step 3: Check the PC port's facts first.**
  - **Occlusion queries.** Light flares are sized from ZPASS_DONE counts (FINDINGS: begin/end u64 pairs, bit 63 valid, waited on with WAIT_REG_MEM, counted with depth attached even when the depth test is off). A query that reads back "all visible", or a garbage count, gives a full-size flare at the screen centre. Check what our renderer writes for ZPASS_DONE pairs: Metal visibility-result buffers, or nothing.
  - **The translator's float semantics.** V_RCP and V_LOG without clamping, and saturate keeping NaN. Adaptation that computes 1/avg(luminance) with an avg of 0 gives inf.
- [ ] **Step 4: Fix** what the replay shows, with a host test, as above. Expected: the shot at the same route time has no disc, and the replay of the pass matches the corrected output. The TLOU check comes with it, plus a look at a TLOU flare scene.

### Task 9.3: Ghosting and banding (draft)

- [ ] **Step 1: Is it still there?** Look at the Task 9.2 probe's shots for double edges on moving objects and on camera turns, and for bands in skies and fog.
- [ ] **Step 2: Capture and find the pass.**
  - **Ghosting:** a temporal pass (TAA or motion blur) that blends the history buffer. Check:
    - whether history is the previous frame's target (aliasing of a GPU-owned surface across frames, the `[gnm-mem] GPU-owned surfaces ... overlapped` lines);
    - whether the velocity buffer's format and values are right;
    - whether the jitter offsets are applied.
  - **Banding:** the format of the lighting targets. A R11G11B10 or RGBA16F target demoted to an 8-bit format, a dither or noise texture bound as null, or a sRGB mismatch in a view.
- [ ] **Step 3: Fix** with a host test per root cause.

### Task 9.4: Half-drawn night frames and black quadrants (draft)

- [ ] **Step 1: Is it still there?** The night harbour on the seeded route (p2_31's time, ~250–280 s), on the Phase 3 head. The geom fixes (no more skipped stride-2 draws, the cube T# bound) are the likely cure. If it is gone, rule it fixed by 62fcaf5 with the shot.
- [ ] **Step 2: Otherwise capture.**
  - A black quadrant is usually a compute dispatch over a quarter of the screen that did not run or wrote elsewhere: the screen-space tiled lighting, or the compute copy `3d5ebf4e` of a render target as R32F (FINDINGS), sampled in another format.
  - Look for skipped dispatches (`[gnm-draw] ... skipped` reasons) in that frame first.
- [ ] **Step 3: Fix** with a host test (a replay fixture of the dispatch).

### Task 9.5: The PC port's renderer facts, checked one by one (draft)

For each of these, write a host test that shows whether our renderer has the behaviour, then fix the ones it lacks, one commit per fact:
- GPU readbacks of compute-simulated particles (drain smoke, drones): the CPU reads results the GPU wrote;
- wave64 ballots on the odd half;
- separate stencil test and op values (Delsin's drain glow);
- S_WQM_B64;
- float atomics;
- workgroups of 96 and 192 with LDS barriers;
- BC 1D textures (Task 7.4 covers some);
- MSAA passes;
- the 1536-layer image (geom's cube array; check that it is not truncated).

Most are generic and some may already be covered by U4 work: the test decides.

### Task 9.6: Gate 4 (draft)

- [ ] **Step 1:**
  - Every reference pair from Task 9.1 shows no obvious artefact by eye: lighting, shadows, particles, UI.
  - `refcompare.py` is within the limits recorded per scene in Task 9.1.
  - The owner's verdict is recorded.
- [ ] **Step 2:** The same regression checks as Gate 3 (Task 8.10, Steps 2–4): TLOU on Metal 3 with MetalFX (warm) and on Metal 4, U4 120 s, Go and the host suite.
- [ ] **Step 3:** Commit a "Gate 4 result" paragraph.

## Phase 5: performance and stability (gate 5 = the spec's Acceptance)

### Task 10: Plan Phase 5

- [ ] **Step 1:** Write a fixed scripted route for the first open-world district, a pad script plus a copy of a save in the test data dir, in the style of `tools/metal4_route.sh`. Measure 3 runs: fps, the `[gnm-draw] perf:` breakdown and the memory footprint.
- [ ] **Step 2:** Write Tasks 10.1…10.n:
  - one per measured bottleneck, each an alternating A/B with `tools/metal4_perf_ab.sh` as its acceptance;
  - the 30-minute soak;
  - the exit tests (close button and Cmd+Q, 3/3 each, no crash report);
  - the final gate: every item of the spec's Acceptance, plus TLOU and Uncharted 4 regressions and the full Go and host suites.
- [ ] **Step 3:** Commit.

**Note (Task 8): measured performance, for Step 1.** In the cannery (p2_32, p2_33, before the geom merge) the game runs at 8–12 fps. A frame has about 128 commits and 120 GPU waits, with 75 ms spent waiting, 52 ms of GPU busy, 100–109 ms of CP CPU time and 94–98 ms in the encoder (`[gnm-draw] perf:` lines of p2_33). At the night harbour (p2_762c) it is 13 fps, with 86 commits and 79 waits. During the movies it is 117.7 fps, with 3 commits per frame.
- The waits per frame (one per commit) point first at CPU-GPU round trips: a WAIT_REG_MEM or label wait on each submit, or readbacks.
- The CP and encoder times point at command processing.

Measure both on the fixed route before choosing. FINDINGS reports +19–32 % for the PC port from splitting command processing into two stages, and +22 % from a 64 KiB write-tracking window. Those are hints to measure, not changes to copy. game_rss was 3.0 GB with shots every 5 s against 1.6 GB at 10 s (Task 7.6 loop 3), so the screenshot path may hold memory. Check it before the memory footprint is measured.
