// Host test of the libkernel event flags (sceKernel*EventFlag, ps4_event_flag.c):
//  - PollEventFlag reports the current pattern also when it fails with EBUSY;
//  - Sonic Origins' job-group wait: a flag created with 0x3 (bit 1: waits must not clear),
//    cleared to bit 1 while jobs run, set to bit 0 when they are done; the waiter polls
//    pattern 3 (EBUSY), reads bit 1 from the reported pattern and waits for bit 0 without
//    clearing. A thread that starts waiting while the jobs run (the EBUSY path) must leave bit 0
//    set, so a second wait on the same group returns at once;
//  - AND / OR conditions, CLEAR_PAT and CLEAR_ALL, a wait with timeout that ends ETIMEDOUT
//    with the pattern, a SetEventFlag from another thread waking a waiter.
#include "ps4_event_flag.h"

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

#define EBUSY_K ((int32_t)0x80020010)
#define ETIMEDOUT_K ((int32_t)0x8002003c)

// The game's wait for a job group's "done" bit (fn 0xa69820 in CUSA30448 v1.00).
static int32_t group_wait(OrbisKernelEventFlag ef) {
  uint64_t pat = 0;
  const int32_t rc = sceKernelPollEventFlag(ef, 3, SCE_KERNEL_EVF_WAITMODE_AND, &pat);
  if (rc != 0 && rc != EBUSY_K) return rc;
  uint32_t mode = SCE_KERNEL_EVF_WAITMODE_AND | SCE_KERNEL_EVF_WAITMODE_CLEAR_PAT;
  if (pat & 2) {
    mode = SCE_KERNEL_EVF_WAITMODE_AND;
    if (pat & 1) return 0;
  }
  OrbisKernelUseconds t = 1000;
  return sceKernelWaitEventFlag(ef, 1, mode, NULL, &t);
}

static void test_poll_reports_pattern(void) {
  OrbisKernelEventFlag ef = 0;
  CHECK(sceKernelCreateEventFlag(&ef, "poll", 0x21, 0x6, NULL) == 0, "create");
  uint64_t pat = 0;
  CHECK(sceKernelPollEventFlag(ef, 1, SCE_KERNEL_EVF_WAITMODE_AND, &pat) == EBUSY_K, "busy");
  CHECK(pat == 0x6, "pattern on EBUSY %#llx", (unsigned long long)pat);
  CHECK(sceKernelPollEventFlag(ef, 3, SCE_KERNEL_EVF_WAITMODE_OR | SCE_KERNEL_EVF_WAITMODE_CLEAR_PAT, &pat) == 0 &&
            pat == 0x6,
        "OR poll %#llx", (unsigned long long)pat);
  CHECK(sceKernelPollEventFlag(ef, 4, SCE_KERNEL_EVF_WAITMODE_AND | SCE_KERNEL_EVF_WAITMODE_CLEAR_ALL, &pat) == 0 &&
            pat == 0x4,
        "CLEAR_PAT left %#llx", (unsigned long long)pat);
  CHECK(sceKernelPollEventFlag(ef, 4, SCE_KERNEL_EVF_WAITMODE_OR, &pat) == EBUSY_K && pat == 0, "CLEAR_ALL");
  sceKernelDeleteEventFlag(ef);
}

// Retries group_wait as the game's loop does (it runs queued jobs between the 1 ms waits).
static void *group_waiter(void *arg) {
  OrbisKernelEventFlag ef = *(OrbisKernelEventFlag *)arg;
  intptr_t rc = ETIMEDOUT_K;
  for (int i = 0; i < 2000 && rc == ETIMEDOUT_K; i++) rc = group_wait(ef);
  return (void *)rc;
}

static void test_job_group(void) {
  OrbisKernelEventFlag ef = 0;
  CHECK(sceKernelCreateEventFlag(&ef, "RsdxCreateEvent", 0x21, 0x3, NULL) == 0, "create");
  CHECK(group_wait(ef) == 0, "idle group");
  CHECK(sceKernelClearEventFlag(ef, 2) == 0, "jobs start");
  CHECK(group_wait(ef) == ETIMEDOUT_K, "running group");
  pthread_t th;
  pthread_create(&th, NULL, group_waiter, &ef);
  usleep(20000); // the waiter polls while the jobs run
  CHECK(sceKernelSetEventFlag(ef, 1) == 0, "jobs done");
  void *rc = NULL;
  pthread_join(th, &rc);
  CHECK((intptr_t)rc == 0, "waiter during the jobs 0x%x", (int)(intptr_t)rc);
  CHECK(group_wait(ef) == 0, "second wait on the same group");
  uint64_t pat = 0;
  CHECK(sceKernelPollEventFlag(ef, 3, SCE_KERNEL_EVF_WAITMODE_AND, &pat) == 0 && pat == 3, "done bit kept");
  sceKernelDeleteEventFlag(ef);
}

static OrbisKernelEventFlag g_ef;
static void *set_later(void *arg) {
  (void)arg;
  usleep(30000);
  sceKernelSetEventFlag(g_ef, 0x10);
  return NULL;
}

static void test_wait(void) {
  CHECK(sceKernelCreateEventFlag(&g_ef, "wait", 0x21, 0x1, NULL) == 0, "create");
  uint64_t pat = 0;
  OrbisKernelUseconds t = 20000;
  CHECK(sceKernelWaitEventFlag(g_ef, 0x11, SCE_KERNEL_EVF_WAITMODE_AND, &pat, &t) == ETIMEDOUT_K && pat == 1 && t == 0,
        "AND timeout %#llx %u", (unsigned long long)pat, t);
  pthread_t th;
  pthread_create(&th, NULL, set_later, NULL);
  CHECK(sceKernelWaitEventFlag(g_ef, 0x11, SCE_KERNEL_EVF_WAITMODE_AND | SCE_KERNEL_EVF_WAITMODE_CLEAR_PAT, &pat,
                               NULL) == 0 &&
            pat == 0x11,
        "woken %#llx", (unsigned long long)pat);
  pthread_join(th, NULL);
  CHECK(sceKernelPollEventFlag(g_ef, 0x11, SCE_KERNEL_EVF_WAITMODE_OR, &pat) == EBUSY_K && pat == 0, "cleared");
  sceKernelDeleteEventFlag(g_ef);
}

int main(void) {
  test_poll_reports_pattern();
  test_job_group();
  test_wait();
  if (g_failures) {
    printf("kernel_evf_test: %d failure(s)\n", g_failures);
    return 1;
  }
  printf("kernel_evf_test: PASS\n");
  return 0;
}
