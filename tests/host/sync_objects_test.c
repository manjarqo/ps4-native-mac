// Host test of the guest-memory sync objects (ps4_sync_objects.c) and of the mutex, cond and
// rwlock shims on top of them (ps4_sync.c), against the real VM extent manager:
//  - scePthreadMutexInit stores the guest address of a zeroed object in the variable; the
//    object's m_flags (+0x20) holds the mutex type; the game may write into the object
//    (inFAMOUS's libc sets PMUTEX_FLAG_PRIVATE = 0x100 at +0x20) and the mutex still works;
//  - lock/unlock through a copy of the handle (another variable holding the same value) is the
//    same mutex; ERRORCHECK relock is EDEADLK (0x8002000b through scePthread*);
//  - destroy clears the variable and frees the slot, a second destroy is harmless, the next
//    init reuses the slot with a zeroed object;
//  - a thread relocking a mutex it owns: ADAPTIVE_NP (4) and ERRORCHECK (1) get EDEADLK from lock,
//    EBUSY from trylock and ETIMEDOUT from a timed lock after the timeout, and the one unlock frees
//    the mutex for another thread (inFAMOUS's movie lock counts its own nesting on top of an
//    adaptive mutex and unlocks once); RECURSIVE (2) counts, and needs as many unlocks; a mutex
//    without a type stays recursive (a known divergence); each relock is counted by type;
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
#include <time.h>
#include <unistd.h>

RecompThread *recomp_get_current_thread(void) { return NULL; }
// recomp_runtime.c calls these on VM release; no direct memory is mapped here.
void ps4_direct_mem_destroy(void) {}
void ps4_direct_mem_configure(GuestContext *ctx, uint64_t proc_param_addr) { (void)ctx; (void)proc_param_addr; }
void ps4_direct_mem_on_unmap(GuestContext *ctx, uint64_t addr, size_t size) { (void)ctx; (void)addr; (void)size; }

void shim_scePthreadMutexInit(GuestContext *ctx);
void shim_scePthreadMutexLock(GuestContext *ctx);
void shim_scePthreadMutexUnlock(GuestContext *ctx);
void shim_scePthreadMutexTrylock(GuestContext *ctx);
void shim_scePthreadMutexTimedlock(GuestContext *ctx);
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

#define SCE_EDEADLK 0x8002000bu
#define SCE_EBUSY 0x80020010u
#define SCE_ETIMEDOUT 0x8002003cu

static uint64_t now_us(void) {
  struct timespec ts;
  clock_gettime(CLOCK_MONOTONIC, &ts);
  return (uint64_t)ts.tv_sec * 1000000u + (uint64_t)ts.tv_nsec / 1000u;
}

// Whether a second guest thread can take the mutex now (and gives it back).
static int other_thread_takes(GuestContext *other) {
  if ((uint32_t)call(other, shim_scePthreadMutexTrylock, VAR_MTX, 0, 0) != 0) return 0;
  call(other, shim_scePthreadMutexUnlock, VAR_MTX, 0, 0);
  return 1;
}

// Relocking a mutex the thread already owns, per type (FreeBSD libthr mutex_self_lock and
// mutex_self_trylock; shadPS4 PthreadMutex::SelfLock and SelfTryLock as the fact source).
static void test_mutex_self_lock(GuestContext *ctx) {
  uint64_t r0[6], r1[6];
  ps4_sync_relocks_by_type(r0);
  GuestContext *other = new_ctx();
  other->thread_id = 1002;
  static const int nonrecursive[] = {4, 1};
  for (int i = 0; i < 2; i++) {
    const int type = nonrecursive[i];
    CHECK(call(ctx, shim_scePthreadMutexattrInit, VAR_ATTR, 0, 0) == 0, "attr init");
    CHECK(call(ctx, shim_scePthreadMutexattrSettype, VAR_ATTR, (uint64_t)type, 0) == 0, "settype %d", type);
    CHECK(call(ctx, shim_scePthreadMutexInit, VAR_MTX, VAR_ATTR, VAR_NAME) == 0, "init type %d", type);
    CHECK(call(ctx, shim_scePthreadMutexLock, VAR_MTX, 0, 0) == 0, "type %d: lock", type);
    uint32_t r = (uint32_t)call(ctx, shim_scePthreadMutexLock, VAR_MTX, 0, 0);
    CHECK(r == SCE_EDEADLK, "type %d: relock is EDEADLK, got %#x", type, r);
    r = (uint32_t)call(ctx, shim_scePthreadMutexTrylock, VAR_MTX, 0, 0);
    CHECK(r == SCE_EBUSY, "type %d: trylock by the owner is EBUSY, got %#x", type, r);
    const uint64_t t0 = now_us();
    r = (uint32_t)call(ctx, shim_scePthreadMutexTimedlock, VAR_MTX, 20000, 0);
    const uint64_t waited = now_us() - t0;
    CHECK(r == SCE_ETIMEDOUT, "type %d: timed relock is ETIMEDOUT, got %#x", type, r);
    CHECK(waited >= 19000, "type %d: timed relock returned after %llu us, before its 20 ms", type,
          (unsigned long long)waited);
    CHECK(!other_thread_takes(other), "type %d: another thread cannot take it while it is owned", type);
    // inFAMOUS's movie lock (eboot 0x28d720 -> 0x28eea0): the nested level does not unlock,
    // the outermost unlocks once.
    CHECK(call(ctx, shim_scePthreadMutexUnlock, VAR_MTX, 0, 0) == 0, "type %d: unlock", type);
    CHECK(other_thread_takes(other), "type %d: after the one unlock another thread takes it", type);
    r = (uint32_t)call(ctx, shim_scePthreadMutexUnlock, VAR_MTX, 0, 0);
    CHECK(r != 0, "type %d: unlocking a free mutex fails, got %#x", type, r);
    CHECK(call(ctx, shim_scePthreadMutexDestroy, VAR_MTX, 0, 0) == 0, "destroy type %d", type);
  }

  CHECK(call(ctx, shim_scePthreadMutexattrSettype, VAR_ATTR, 2, 0) == 0, "settype RECURSIVE");
  CHECK(call(ctx, shim_scePthreadMutexInit, VAR_MTX, VAR_ATTR, VAR_NAME) == 0, "init RECURSIVE");
  CHECK(call(ctx, shim_scePthreadMutexLock, VAR_MTX, 0, 0) == 0, "recursive: lock");
  CHECK(call(ctx, shim_scePthreadMutexLock, VAR_MTX, 0, 0) == 0, "recursive: relock");
  CHECK(call(ctx, shim_scePthreadMutexTrylock, VAR_MTX, 0, 0) == 0, "recursive: trylock by the owner");
  CHECK(call(ctx, shim_scePthreadMutexUnlock, VAR_MTX, 0, 0) == 0, "recursive: unlock 1");
  CHECK(call(ctx, shim_scePthreadMutexUnlock, VAR_MTX, 0, 0) == 0, "recursive: unlock 2");
  CHECK(!other_thread_takes(other), "recursive: still owned after 2 of 3 unlocks");
  CHECK(call(ctx, shim_scePthreadMutexUnlock, VAR_MTX, 0, 0) == 0, "recursive: unlock 3");
  CHECK(other_thread_takes(other), "recursive: free after the third unlock");
  CHECK(call(ctx, shim_scePthreadMutexDestroy, VAR_MTX, 0, 0) == 0, "destroy RECURSIVE");

  // No type set: still recursive here (a known divergence; Orbis makes it ERRORCHECK).
  CHECK(call(ctx, shim_scePthreadMutexInit, VAR_MTX, 0, VAR_NAME) == 0, "init without attributes");
  CHECK(call(ctx, shim_scePthreadMutexLock, VAR_MTX, 0, 0) == 0, "type 0: lock");
  CHECK(call(ctx, shim_scePthreadMutexLock, VAR_MTX, 0, 0) == 0, "type 0: relock counts");
  CHECK(call(ctx, shim_scePthreadMutexUnlock, VAR_MTX, 0, 0) == 0, "type 0: unlock 1");
  CHECK(call(ctx, shim_scePthreadMutexUnlock, VAR_MTX, 0, 0) == 0, "type 0: unlock 2");
  CHECK(call(ctx, shim_scePthreadMutexDestroy, VAR_MTX, 0, 0) == 0, "destroy type 0");

  // Every relock above is counted under its type (lock, trylock and timed lock for 4 and 1).
  ps4_sync_relocks_by_type(r1);
  static const uint64_t want[6] = {1, 3, 2, 0, 3, 0};
  for (int t = 0; t < 6; t++)
    CHECK(r1[t] - r0[t] == want[t], "relocks of type %d: %llu, want %llu", t, (unsigned long long)(r1[t] - r0[t]),
          (unsigned long long)want[t]);
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
  test_mutex_self_lock(ctx);
  test_cond_and_rwlock(ctx);
  const uint64_t a = sync_obj_alloc(ctx);
  CHECK(sync_obj_slot(a + 8) < 0, "a misaligned value");
  sync_obj_free(a);
  CHECK(sync_obj_index(a) == sync_obj_index(a + SYNC_OBJ_STRIDE) - 1 && sync_obj_index(a) >= 0, "index of a freed slot");
  CHECK(sync_obj_index(a + 8) < 0 && sync_obj_index(0) < 0 && sync_obj_index(VAR_MTX) < 0, "index rejects misaligned and outside");
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
