#include "ps4_semaphore.h"
#include <errno.h>
#include <pthread.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#define MAX_SEMS 1024
#define SEM_MAGIC 0x53454d31 // 'SEM1'

typedef struct {
  uint32_t magic;
  int in_use;
  int value;
  pthread_mutex_t mutex;
  pthread_cond_t cond;
} RecompInternalSem;

static RecompInternalSem g_sem_table[MAX_SEMS];
static pthread_mutex_t g_sem_table_lock = PTHREAD_MUTEX_INITIALIZER;

static int alloc_sem_slot(void) {
  pthread_mutex_lock(&g_sem_table_lock);
  for (int i = 1; i < MAX_SEMS; i++) {
    if (!g_sem_table[i].in_use) {
      g_sem_table[i].in_use = 1;
      pthread_mutex_unlock(&g_sem_table_lock);
      return i;
    }
  }
  pthread_mutex_unlock(&g_sem_table_lock);
  return -1;
}

static RecompInternalSem *get_sem(uint32_t id) {
  if (id == 0 || id >= MAX_SEMS) {
    return NULL;
  }
  RecompInternalSem *s = &g_sem_table[id];
  if (!s->in_use || s->magic != SEM_MAGIC) {
    return NULL;
  }
  return s;
}

// sem_init(sem_t *sem, int pshared, unsigned int value)
void shim_sem_init(GuestContext *ctx) {
  uint64_t sem_addr = ctx->rdi;
  int pshared = (int)ctx->rsi;
  unsigned int value = (unsigned int)ctx->rdx;
  (void)pshared;

  if (!sem_addr) {
    set_guest_errno(ctx, EFAULT);
    ctx->rax = (uint64_t)-1;
    SHIM_RETURN();
  }

  int slot = alloc_sem_slot();
  if (slot < 0) {
    set_guest_errno(ctx, ENOSPC);
    ctx->rax = (uint64_t)-1;
    SHIM_RETURN();
  }

  RecompInternalSem *s = &g_sem_table[slot];
  s->magic = SEM_MAGIC;
  s->value = (int)value;
  pthread_mutex_init(&s->mutex, NULL);
  pthread_cond_init(&s->cond, NULL);

  // Store slot id in guest sem_t (both 32-bit and 64-bit safe)
  *(uint64_t *)(ctx->mem_base + sem_addr) = (uint64_t)slot;

  ctx->rax = 0;
  SHIM_RETURN();
}

// sem_destroy(sem_t *sem)
void shim_sem_destroy(GuestContext *ctx) {
  uint64_t sem_addr = ctx->rdi;
  if (!sem_addr) {
    set_guest_errno(ctx, EFAULT);
    ctx->rax = (uint64_t)-1;
    SHIM_RETURN();
  }

  uint32_t id = *(uint32_t *)(ctx->mem_base + sem_addr);
  RecompInternalSem *s = get_sem(id);
  if (!s) {
    set_guest_errno(ctx, EINVAL);
    ctx->rax = (uint64_t)-1;
    SHIM_RETURN();
  }

  pthread_mutex_lock(&s->mutex);
  s->magic = 0;
  pthread_cond_broadcast(&s->cond);
  pthread_mutex_unlock(&s->mutex);

  pthread_mutex_destroy(&s->mutex);
  pthread_cond_destroy(&s->cond);

  pthread_mutex_lock(&g_sem_table_lock);
  s->in_use = 0;
  pthread_mutex_unlock(&g_sem_table_lock);

  ctx->rax = 0;
  SHIM_RETURN();
}

// sem_wait(sem_t *sem)
void shim_sem_wait(GuestContext *ctx) {
  uint64_t sem_addr = ctx->rdi;
  if (!sem_addr) {
    set_guest_errno(ctx, EFAULT);
    ctx->rax = (uint64_t)-1;
    SHIM_RETURN();
  }

  uint32_t id = *(uint32_t *)(ctx->mem_base + sem_addr);
  RecompInternalSem *s = get_sem(id);
  if (!s) {
    set_guest_errno(ctx, EINVAL);
    ctx->rax = (uint64_t)-1;
    SHIM_RETURN();
  }

  pthread_mutex_lock(&s->mutex);
  while (s->value <= 0) {
    pthread_cond_wait(&s->cond, &s->mutex);
  }
  s->value--;
  pthread_mutex_unlock(&s->mutex);

  ctx->rax = 0;
  SHIM_RETURN();
}

// int sem_timedwait(sem_t *sem, const struct timespec *abs_timeout)
//
// Order of checks as in libkernel (see shadPS4 libraries/kernel/threads/semaphore.cpp,
// posix_sem_timedwait / PthreadSemWait): a NULL or unknown semaphore fails with EINVAL; a
// token that is available is taken before the timeout is looked at, so a bad timespec does not
// fail a wait that would succeed; then tv_nsec outside [0, 1e9) fails with EINVAL; otherwise
// the thread sleeps until the absolute CLOCK_REALTIME deadline and a miss returns -1 with
// errno ETIMEDOUT (FreeBSD value 60, same as the host). A NULL abs_timeout waits without
// limit, like sem_wait. A deadline more than 30 years away is treated the same way, which
// keeps far-future values from overflowing the host's timed wait.
void shim_sem_timedwait(GuestContext *ctx) {
  uint64_t sem_addr = ctx->rdi;
  uint64_t ts_addr = ctx->rsi;
  RecompInternalSem *s = NULL;
  if (sem_addr) {
    s = get_sem(*(uint32_t *)(ctx->mem_base + sem_addr));
  }
  if (!s) {
    set_guest_errno(ctx, EINVAL);
    ctx->rax = (uint64_t)-1;
    SHIM_RETURN();
  }

  pthread_mutex_lock(&s->mutex);
  if (s->value > 0) {
    s->value--;
    pthread_mutex_unlock(&s->mutex);
    ctx->rax = 0;
    SHIM_RETURN();
  }

  struct timespec deadline = {0, 0};
  int timed = 0;
  if (ts_addr) {
    const int64_t *ts = (const int64_t *)(ctx->mem_base + ts_addr);
    int64_t sec = ts[0], nsec = ts[1];
    if (nsec < 0 || nsec >= 1000000000LL) {
      pthread_mutex_unlock(&s->mutex);
      set_guest_errno(ctx, EINVAL);
      ctx->rax = (uint64_t)-1;
      SHIM_RETURN();
    }
    struct timespec now;
    clock_gettime(CLOCK_REALTIME, &now);
    if (sec < (int64_t)now.tv_sec + 30LL * 365 * 86400) {
      deadline.tv_sec = (time_t)sec;
      deadline.tv_nsec = (long)nsec;
      timed = 1;
    }
  }

  while (s->value <= 0 && s->magic == SEM_MAGIC) {
    if (!timed) {
      pthread_cond_wait(&s->cond, &s->mutex);
    } else if (pthread_cond_timedwait(&s->cond, &s->mutex, &deadline) != 0) {
      break; // ETIMEDOUT, or an error that would otherwise spin (EINVAL): report a timeout
    }
  }
  if (s->magic != SEM_MAGIC) { // destroyed while waiting
    pthread_mutex_unlock(&s->mutex);
    set_guest_errno(ctx, EINVAL);
    ctx->rax = (uint64_t)-1;
    SHIM_RETURN();
  }
  if (s->value > 0) { // a post that raced the timeout still wins
    s->value--;
    pthread_mutex_unlock(&s->mutex);
    ctx->rax = 0;
    SHIM_RETURN();
  }
  pthread_mutex_unlock(&s->mutex);
  set_guest_errno(ctx, ETIMEDOUT);
  ctx->rax = (uint64_t)-1;
  SHIM_RETURN();
}

// sem_trywait(sem_t *sem)
void shim_sem_trywait(GuestContext *ctx) {
  uint64_t sem_addr = ctx->rdi;
  if (!sem_addr) {
    set_guest_errno(ctx, EFAULT);
    ctx->rax = (uint64_t)-1;
    SHIM_RETURN();
  }

  uint32_t id = *(uint32_t *)(ctx->mem_base + sem_addr);
  RecompInternalSem *s = get_sem(id);
  if (!s) {
    set_guest_errno(ctx, EINVAL);
    ctx->rax = (uint64_t)-1;
    SHIM_RETURN();
  }

  pthread_mutex_lock(&s->mutex);
  if (s->value > 0) {
    s->value--;
    pthread_mutex_unlock(&s->mutex);
    ctx->rax = 0;
  } else {
    pthread_mutex_unlock(&s->mutex);
    set_guest_errno(ctx, EAGAIN);
    ctx->rax = (uint64_t)-1;
  }
  SHIM_RETURN();
}

// sem_post(sem_t *sem)
void shim_sem_post(GuestContext *ctx) {
  uint64_t sem_addr = ctx->rdi;
  if (!sem_addr) {
    set_guest_errno(ctx, EFAULT);
    ctx->rax = (uint64_t)-1;
    SHIM_RETURN();
  }

  uint32_t id = *(uint32_t *)(ctx->mem_base + sem_addr);
  RecompInternalSem *s = get_sem(id);
  if (!s) {
    set_guest_errno(ctx, EINVAL);
    ctx->rax = (uint64_t)-1;
    SHIM_RETURN();
  }

  pthread_mutex_lock(&s->mutex);
  s->value++;
  pthread_cond_signal(&s->cond);
  pthread_mutex_unlock(&s->mutex);

  ctx->rax = 0;
  SHIM_RETURN();
}

// sem_getvalue(sem_t *sem, int *sval)
void shim_sem_getvalue(GuestContext *ctx) {
  uint64_t sem_addr = ctx->rdi;
  uint64_t sval_addr = ctx->rsi;
  if (!sem_addr || !sval_addr) {
    set_guest_errno(ctx, EFAULT);
    ctx->rax = (uint64_t)-1;
    SHIM_RETURN();
  }

  uint32_t id = *(uint32_t *)(ctx->mem_base + sem_addr);
  RecompInternalSem *s = get_sem(id);
  if (!s) {
    set_guest_errno(ctx, EINVAL);
    ctx->rax = (uint64_t)-1;
    SHIM_RETURN();
  }

  pthread_mutex_lock(&s->mutex);
  int cur_val = s->value;
  pthread_mutex_unlock(&s->mutex);

  *(int *)(ctx->mem_base + sval_addr) = cur_val;
  ctx->rax = 0;
  SHIM_RETURN();
}

// scePthread semaphore implementations
void shim_scePthreadSemInit(GuestContext *ctx) {
  uint64_t sem_addr = ctx->rdi;
  int flag = (int)ctx->rsi;
  unsigned int value = (unsigned int)ctx->rdx;

  if (flag != 0) {
    ctx->rax = 0x80020016; // ORBIS_KERNEL_ERROR_EINVAL
    SHIM_RETURN();
  }
  if (!sem_addr) {
    ctx->rax = 0x8002000e; // ORBIS_KERNEL_ERROR_EFAULT
    SHIM_RETURN();
  }

  int slot = alloc_sem_slot();
  if (slot < 0) {
    ctx->rax = 0x8002001c; // ORBIS_KERNEL_ERROR_ENOSPC
    SHIM_RETURN();
  }

  RecompInternalSem *s = &g_sem_table[slot];
  s->magic = SEM_MAGIC;
  s->value = (int)value;
  pthread_mutex_init(&s->mutex, NULL);
  pthread_cond_init(&s->cond, NULL);

  *(uint64_t *)(ctx->mem_base + sem_addr) = (uint64_t)slot;
  ctx->rax = 0;
  SHIM_RETURN();
}

void shim_scePthreadSemDestroy(GuestContext *ctx) {
  uint64_t sem_addr = ctx->rdi;
  if (!sem_addr) {
    ctx->rax = 0x8002000e; // ORBIS_KERNEL_ERROR_EFAULT
    SHIM_RETURN();
  }

  uint32_t id = *(uint32_t *)(ctx->mem_base + sem_addr);
  RecompInternalSem *s = get_sem(id);
  if (!s) {
    ctx->rax = 0x80020016; // ORBIS_KERNEL_ERROR_EINVAL
    SHIM_RETURN();
  }

  pthread_mutex_lock(&s->mutex);
  s->magic = 0;
  pthread_cond_broadcast(&s->cond);
  pthread_mutex_unlock(&s->mutex);

  pthread_mutex_destroy(&s->mutex);
  pthread_cond_destroy(&s->cond);

  pthread_mutex_lock(&g_sem_table_lock);
  s->in_use = 0;
  pthread_mutex_unlock(&g_sem_table_lock);

  ctx->rax = 0;
  SHIM_RETURN();
}

void shim_scePthreadSemWait(GuestContext *ctx) {
  uint64_t sem_addr = ctx->rdi;
  if (!sem_addr) {
    ctx->rax = 0x8002000e; // ORBIS_KERNEL_ERROR_EFAULT
    SHIM_RETURN();
  }

  uint32_t id = *(uint32_t *)(ctx->mem_base + sem_addr);
  RecompInternalSem *s = get_sem(id);
  if (!s) {
    ctx->rax = 0x80020016; // ORBIS_KERNEL_ERROR_EINVAL
    SHIM_RETURN();
  }

  pthread_mutex_lock(&s->mutex);
  while (s->magic == SEM_MAGIC && s->value <= 0) {
    pthread_cond_wait(&s->cond, &s->mutex);
  }
  if (s->magic != SEM_MAGIC) {
    pthread_mutex_unlock(&s->mutex);
    ctx->rax = 0x80020016; // ORBIS_KERNEL_ERROR_EINVAL
    SHIM_RETURN();
  }
  s->value--;
  pthread_mutex_unlock(&s->mutex);

  ctx->rax = 0;
  SHIM_RETURN();
}

void shim_scePthreadSemTrywait(GuestContext *ctx) {
  uint64_t sem_addr = ctx->rdi;
  if (!sem_addr) {
    ctx->rax = 0x8002000e; // ORBIS_KERNEL_ERROR_EFAULT
    SHIM_RETURN();
  }

  uint32_t id = *(uint32_t *)(ctx->mem_base + sem_addr);
  RecompInternalSem *s = get_sem(id);
  if (!s) {
    ctx->rax = 0x80020016; // ORBIS_KERNEL_ERROR_EINVAL
    SHIM_RETURN();
  }

  pthread_mutex_lock(&s->mutex);
  if (s->value > 0) {
    s->value--;
    pthread_mutex_unlock(&s->mutex);
    ctx->rax = 0;
  } else {
    pthread_mutex_unlock(&s->mutex);
    ctx->rax = 0x80020023; // ORBIS_KERNEL_ERROR_EAGAIN
  }
  SHIM_RETURN();
}

void shim_scePthreadSemTimedwait(GuestContext *ctx) {
  uint64_t sem_addr = ctx->rdi;
  uint32_t usec = (uint32_t)ctx->rsi;
  if (!sem_addr) {
    ctx->rax = 0x8002000e; // ORBIS_KERNEL_ERROR_EFAULT
    SHIM_RETURN();
  }

  uint32_t id = *(uint32_t *)(ctx->mem_base + sem_addr);
  RecompInternalSem *s = get_sem(id);
  if (!s) {
    ctx->rax = 0x80020016; // ORBIS_KERNEL_ERROR_EINVAL
    SHIM_RETURN();
  }

  struct timespec now;
  clock_gettime(CLOCK_REALTIME, &now);
  struct timespec ts;
  ts.tv_sec = now.tv_sec + (time_t)(usec / 1000000ULL);
  ts.tv_nsec = now.tv_nsec + (long)((usec % 1000000ULL) * 1000ULL);
  if (ts.tv_nsec >= 1000000000L) {
    ts.tv_sec += 1;
    ts.tv_nsec -= 1000000000L;
  }

  pthread_mutex_lock(&s->mutex);
  while (s->magic == SEM_MAGIC && s->value <= 0) {
    int rc = pthread_cond_timedwait(&s->cond, &s->mutex, &ts);
    if (rc == ETIMEDOUT) {
      pthread_mutex_unlock(&s->mutex);
      ctx->rax = 0x8002003c; // ORBIS_KERNEL_ERROR_ETIMEDOUT
      SHIM_RETURN();
    }
  }
  if (s->magic != SEM_MAGIC) {
    pthread_mutex_unlock(&s->mutex);
    ctx->rax = 0x80020016; // ORBIS_KERNEL_ERROR_EINVAL
    SHIM_RETURN();
  }
  s->value--;
  pthread_mutex_unlock(&s->mutex);

  ctx->rax = 0;
  SHIM_RETURN();
}

void shim_scePthreadSemPost(GuestContext *ctx) {
  uint64_t sem_addr = ctx->rdi;
  if (!sem_addr) {
    ctx->rax = 0x8002000e; // ORBIS_KERNEL_ERROR_EFAULT
    SHIM_RETURN();
  }

  uint32_t id = *(uint32_t *)(ctx->mem_base + sem_addr);
  RecompInternalSem *s = get_sem(id);
  if (!s) {
    ctx->rax = 0x80020016; // ORBIS_KERNEL_ERROR_EINVAL
    SHIM_RETURN();
  }

  pthread_mutex_lock(&s->mutex);
  s->value++;
  pthread_cond_signal(&s->cond);
  pthread_mutex_unlock(&s->mutex);

  ctx->rax = 0;
  SHIM_RETURN();
}

void shim_scePthreadSemGetvalue(GuestContext *ctx) {
  uint64_t sem_addr = ctx->rdi;
  uint64_t sval_addr = ctx->rsi;
  if (!sem_addr || !sval_addr) {
    ctx->rax = 0x8002000e; // ORBIS_KERNEL_ERROR_EFAULT
    SHIM_RETURN();
  }

  uint32_t id = *(uint32_t *)(ctx->mem_base + sem_addr);
  RecompInternalSem *s = get_sem(id);
  if (!s) {
    ctx->rax = 0x80020016; // ORBIS_KERNEL_ERROR_EINVAL
    SHIM_RETURN();
  }

  pthread_mutex_lock(&s->mutex);
  int cur_val = s->value;
  pthread_mutex_unlock(&s->mutex);

  *(int *)(ctx->mem_base + sval_addr) = cur_val;
  ctx->rax = 0;
  SHIM_RETURN();
}

// Orbis Kernel Semaphore implementations
//
// As the console kernel does (and shadPS4's OrbisSem), sceKernelSignalSema hands the tokens to
// the waiting threads at once: in queue order, each waiter whose need_count the count covers
// takes its tokens and is woken, the others stay queued. A thread blocked in sceKernelWaitSema
// therefore owns its tokens before it runs again, so a second signal that comes before it wakes
// sees the count the first one left (with max_count 1, one waiter and two signals, both
// succeed: one wakes the waiter, the other leaves the count at 1). Waiters queue in arrival
// order for both SCE_KERNEL_SEMA_ATTR_TH_FIFO and _TH_PRIO (the runtime keeps no guest
// priority to sort by). A waiter woken by sceKernelDeleteSema returns EACCES, one woken by
// sceKernelCancelSema ECANCELED, as shadPS4.
#define MAX_KSEMS 1024
#define KSEM_MAGIC 0x4b53454d // 'KSEM'

#define KSEM_ERROR_ESRCH 0x80020003
#define KSEM_ERROR_EACCES 0x8002000d
#define KSEM_ERROR_EBUSY 0x80020010
#define KSEM_ERROR_EINVAL 0x80020016
#define KSEM_ERROR_ENFILE 0x80020018
#define KSEM_ERROR_ETIMEDOUT 0x8002003c
#define KSEM_ERROR_ECANCELED 0x80020055

enum { KSEM_WAITING = 0, KSEM_SIGNALED, KSEM_DELETED, KSEM_CANCELED };

typedef struct KsemWaiter {
  int32_t need_count;
  int state; // KSEM_WAITING until Signal / Delete / Cancel decides
  struct KsemWaiter *next;
} KsemWaiter;

typedef struct {
  uint32_t magic;
  int in_use;
  int sync_inited; // mutex and cond are created once per slot and kept (see DeleteSema)
  char name[32];
  int32_t current_count;
  int32_t init_count;
  int32_t max_count;
  uint32_t attr;
  KsemWaiter *waiters; // queue order; each waiter lives on its waiting thread's stack
  pthread_mutex_t mutex;
  pthread_cond_t cond;
} RecompKernelSema;

static RecompKernelSema g_ksem_table[MAX_KSEMS];
static pthread_mutex_t g_ksem_table_lock = PTHREAD_MUTEX_INITIALIZER;

static int alloc_ksem_slot(void) {
  pthread_mutex_lock(&g_ksem_table_lock);
  for (int i = 1; i < MAX_KSEMS; i++) {
    if (!g_ksem_table[i].in_use) {
      g_ksem_table[i].in_use = 1;
      pthread_mutex_unlock(&g_ksem_table_lock);
      return i;
    }
  }
  pthread_mutex_unlock(&g_ksem_table_lock);
  return -1;
}

static RecompKernelSema *get_ksem(OrbisKernelSema id) {
  if (id <= 0 || id >= MAX_KSEMS) return NULL;
  RecompKernelSema *s = &g_ksem_table[id];
  if (!s->in_use || s->magic != KSEM_MAGIC) return NULL;
  return s;
}

static void ksem_unlink(RecompKernelSema *s, KsemWaiter *w) {
  for (KsemWaiter **pp = &s->waiters; *pp; pp = &(*pp)->next) {
    if (*pp == w) {
      *pp = w->next;
      return;
    }
  }
}

// Ends every queued wait with `state` (Delete / Cancel). Called with s->mutex held.
static int ksem_release_all(RecompKernelSema *s, int state) {
  int n = 0;
  for (KsemWaiter *w = s->waiters; w; w = w->next) {
    w->state = state;
    n++;
  }
  s->waiters = NULL;
  if (n) pthread_cond_broadcast(&s->cond);
  return n;
}

int sceKernelCreateSema(OrbisKernelSema *sem, const char *pName, uint32_t attr, int32_t initCount, int32_t maxCount, const void *pOptParam) {
  (void)pOptParam;
  if (!sem || !pName || attr > 2 || initCount < 0 || maxCount <= 0 || initCount > maxCount) {
    return KSEM_ERROR_EINVAL;
  }
  int slot = alloc_ksem_slot();
  if (slot < 0) return KSEM_ERROR_ENFILE;

  RecompKernelSema *s = &g_ksem_table[slot];
  s->magic = KSEM_MAGIC;
  strncpy(s->name, pName, sizeof(s->name) - 1);
  s->name[sizeof(s->name) - 1] = '\0';
  s->init_count = initCount;
  s->max_count = maxCount;
  s->current_count = initCount;
  s->attr = attr;
  s->waiters = NULL;
  if (!s->sync_inited) {
    pthread_mutex_init(&s->mutex, NULL);
    pthread_cond_init(&s->cond, NULL);
    s->sync_inited = 1;
  }

  *sem = (OrbisKernelSema)slot;
  return 0;
}

int sceKernelDeleteSema(OrbisKernelSema sem) {
  RecompKernelSema *s = get_ksem(sem);
  if (!s) return KSEM_ERROR_ESRCH;

  pthread_mutex_lock(&s->mutex);
  s->magic = 0;
  ksem_release_all(s, KSEM_DELETED);
  pthread_mutex_unlock(&s->mutex);

  // A woken waiter still takes the mutex to read its state, so the slot keeps its mutex and
  // cond for good; a later CreateSema in this slot reuses them.
  pthread_mutex_lock(&g_ksem_table_lock);
  s->in_use = 0;
  pthread_mutex_unlock(&g_ksem_table_lock);
  return 0;
}

int sceKernelSignalSema(OrbisKernelSema sem, int32_t signalCount) {
  if (signalCount <= 0) return KSEM_ERROR_EINVAL;
  RecompKernelSema *s = get_ksem(sem);
  if (!s) return KSEM_ERROR_ESRCH;

  pthread_mutex_lock(&s->mutex);
  if (s->current_count + signalCount > s->max_count) {
    pthread_mutex_unlock(&s->mutex);
    return KSEM_ERROR_EINVAL;
  }
  s->current_count += signalCount;
  bool woke = false;
  for (KsemWaiter **pp = &s->waiters; *pp;) {
    KsemWaiter *w = *pp;
    if (w->need_count > s->current_count) {
      pp = &w->next;
      continue;
    }
    *pp = w->next;
    s->current_count -= w->need_count;
    w->state = KSEM_SIGNALED;
    woke = true;
  }
  if (woke) pthread_cond_broadcast(&s->cond);
  pthread_mutex_unlock(&s->mutex);
  return 0;
}

int sceKernelWaitSema(OrbisKernelSema sem, int32_t needCount, uint32_t *pTimeout) {
  if (needCount <= 0) return KSEM_ERROR_EINVAL;
  RecompKernelSema *s = get_ksem(sem);
  if (!s) return KSEM_ERROR_ESRCH;

  pthread_mutex_lock(&s->mutex);
  if (needCount > s->max_count) {
    pthread_mutex_unlock(&s->mutex);
    return KSEM_ERROR_EINVAL;
  }
  if (s->current_count >= needCount) {
    s->current_count -= needCount;
    pthread_mutex_unlock(&s->mutex);
    return 0;
  }
  if (pTimeout && *pTimeout == 0) {
    pthread_mutex_unlock(&s->mutex);
    return KSEM_ERROR_ETIMEDOUT;
  }

  struct timespec start, deadline;
  if (pTimeout) {
    clock_gettime(CLOCK_REALTIME, &start);
    const uint64_t usec = *pTimeout;
    deadline.tv_sec = start.tv_sec + (time_t)(usec / 1000000ULL);
    deadline.tv_nsec = start.tv_nsec + (long)((usec % 1000000ULL) * 1000ULL);
    if (deadline.tv_nsec >= 1000000000L) {
      deadline.tv_sec += 1;
      deadline.tv_nsec -= 1000000000L;
    }
  }

  KsemWaiter w = {needCount, KSEM_WAITING, NULL};
  KsemWaiter **tail = &s->waiters;
  while (*tail) tail = &(*tail)->next;
  *tail = &w;

  while (w.state == KSEM_WAITING) {
    if (!pTimeout) {
      pthread_cond_wait(&s->cond, &s->mutex);
    } else if (pthread_cond_timedwait(&s->cond, &s->mutex, &deadline) == ETIMEDOUT && w.state == KSEM_WAITING) {
      ksem_unlink(s, &w);
      *pTimeout = 0;
      pthread_mutex_unlock(&s->mutex);
      return KSEM_ERROR_ETIMEDOUT;
    }
  }
  pthread_mutex_unlock(&s->mutex);

  if (pTimeout) { // the time left, as the console reports it
    struct timespec now;
    clock_gettime(CLOCK_REALTIME, &now);
    const int64_t used = (int64_t)(now.tv_sec - start.tv_sec) * 1000000 + (now.tv_nsec - start.tv_nsec) / 1000;
    *pTimeout = used >= (int64_t)*pTimeout ? 0 : *pTimeout - (uint32_t)used;
  }
  switch (w.state) {
  case KSEM_SIGNALED: return 0;
  case KSEM_DELETED: return KSEM_ERROR_EACCES;
  default: return KSEM_ERROR_ECANCELED;
  }
}

int sceKernelPollSema(OrbisKernelSema sem, int32_t needCount) {
  if (needCount <= 0) return KSEM_ERROR_EINVAL;
  RecompKernelSema *s = get_ksem(sem);
  if (!s) return KSEM_ERROR_ESRCH;

  pthread_mutex_lock(&s->mutex);
  if (s->current_count >= needCount) {
    s->current_count -= needCount;
    pthread_mutex_unlock(&s->mutex);
    return 0;
  }
  pthread_mutex_unlock(&s->mutex);
  return KSEM_ERROR_EBUSY;
}

int sceKernelCancelSema(OrbisKernelSema sem, int32_t setCount, int32_t *pNumWaitThreads) {
  RecompKernelSema *s = get_ksem(sem);
  if (!s) return KSEM_ERROR_ESRCH;

  pthread_mutex_lock(&s->mutex);
  if (setCount > s->max_count) {
    pthread_mutex_unlock(&s->mutex);
    return KSEM_ERROR_EINVAL;
  }
  const int n = ksem_release_all(s, KSEM_CANCELED);
  if (pNumWaitThreads) *pNumWaitThreads = n;
  s->current_count = (setCount < 0) ? s->init_count : setCount;
  pthread_mutex_unlock(&s->mutex);
  return 0;
}

// Guest shims for Kernel Semaphores
void shim_sceKernelCreateSema(GuestContext *ctx) {
  uint64_t semGuest = ctx->rdi;
  uint64_t pNameGuest = ctx->rsi;
  uint32_t attr = (uint32_t)ctx->rdx;
  int32_t initCount = (int32_t)ctx->rcx;
  int32_t maxCount = (int32_t)ctx->r8;
  uint64_t optGuest = ctx->r9;

  const char *pName = pNameGuest ? (const char *)(ctx->mem_base + pNameGuest) : NULL;
  const void *opt = optGuest ? (const void *)(ctx->mem_base + optGuest) : NULL;

  OrbisKernelSema sem = 0;
  int rc = sceKernelCreateSema(&sem, pName, attr, initCount, maxCount, opt);
  if (rc == 0 && semGuest != 0) {
    *(int32_t *)(ctx->mem_base + semGuest) = sem;
  }
  ctx->rax = (uint64_t)(int64_t)rc;
  SHIM_RETURN();
}

void shim_sceKernelDeleteSema(GuestContext *ctx) {
  OrbisKernelSema sem = (OrbisKernelSema)ctx->rdi;
  int rc = sceKernelDeleteSema(sem);
  ctx->rax = (uint64_t)(int64_t)rc;
  SHIM_RETURN();
}

void shim_sceKernelWaitSema(GuestContext *ctx) {
  OrbisKernelSema sem = (OrbisKernelSema)ctx->rdi;
  int32_t needCount = (int32_t)ctx->rsi;
  uint64_t timeoutGuest = ctx->rdx;

  uint32_t *pTimeout = timeoutGuest ? (uint32_t *)(ctx->mem_base + timeoutGuest) : NULL;
  int rc = sceKernelWaitSema(sem, needCount, pTimeout);
  ctx->rax = (uint64_t)(int64_t)rc;
  SHIM_RETURN();
}

void shim_sceKernelSignalSema(GuestContext *ctx) {
  OrbisKernelSema sem = (OrbisKernelSema)ctx->rdi;
  int32_t signalCount = (int32_t)ctx->rsi;
  int rc = sceKernelSignalSema(sem, signalCount);
  ctx->rax = (uint64_t)(int64_t)rc;
  SHIM_RETURN();
}

void shim_sceKernelPollSema(GuestContext *ctx) {
  OrbisKernelSema sem = (OrbisKernelSema)ctx->rdi;
  int32_t needCount = (int32_t)ctx->rsi;
  int rc = sceKernelPollSema(sem, needCount);
  ctx->rax = (uint64_t)(int64_t)rc;
  SHIM_RETURN();
}

void shim_sceKernelCancelSema(GuestContext *ctx) {
  OrbisKernelSema sem = (OrbisKernelSema)ctx->rdi;
  int32_t setCount = (int32_t)ctx->rsi;
  uint64_t numWaitGuest = ctx->rdx;

  int32_t *pNumWait = numWaitGuest ? (int32_t *)(ctx->mem_base + numWaitGuest) : NULL;
  int rc = sceKernelCancelSema(sem, setCount, pNumWait);
  ctx->rax = (uint64_t)(int64_t)rc;
  SHIM_RETURN();
}

