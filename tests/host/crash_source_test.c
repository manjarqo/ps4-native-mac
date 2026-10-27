// Host test: the crash handler says which host thread it runs on and whether the signal is a
// fault of that thread or was sent to the process (kill or pthread_kill).
//
// A fault is delivered to the thread that faulted, so its name identifies the faulting thread. A
// signal sent with kill() goes to any thread that does not block it, usually the main thread in
// its run loop, and macOS fills the siginfo of a sent SIGSEGV like a fault at address 0
// (si_code SEGV_ACCERR, si_addr 0, si_pid 0). Only the exception state tells them apart: a fault
// has an abort syndrome (ESR) whose fault address (FAR) is si_addr; a sent signal finds the
// syndrome of the thread's last system call.
//
// Each case runs in a child (this program with the case name); the parent checks its exit status
// and its report.
//   fault  a thread named "crash-fault" writes to address 8 while the main thread waits for it
//   null   the main thread writes to address 0
//   sent   another process sends SIGSEGV while the main thread ("crash-main") waits in pause()
#include "runtime_stubs.h"

#include <pthread.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/wait.h>
#include <unistd.h>

// Runtime hooks the crash handler does not use.
void ps4_direct_mem_destroy(void) {}
void ps4_direct_mem_configure(GuestContext *ctx, uint64_t proc_param_addr) {
  (void)ctx;
  (void)proc_param_addr;
}
void ps4_direct_mem_on_unmap(GuestContext *ctx, uint64_t addr, size_t size) {
  (void)ctx;
  (void)addr;
  (void)size;
}

static void *fault_thread(void *arg) {
  (void)arg;
  pthread_setname_np("crash-fault");
  *(volatile int *)(uintptr_t)8 = 1;
  return NULL;
}

static int child(const char *mode) {
  recomp_install_crash_handler();
  if (strcmp(mode, "fault") == 0) {
    pthread_t t;
    pthread_create(&t, NULL, fault_thread, NULL);
    pthread_join(t, NULL);
  } else if (strcmp(mode, "null") == 0) {
    pthread_setname_np("crash-main");
    *(volatile int *)(uintptr_t)0 = 1;
  } else if (strcmp(mode, "sent") == 0) {
    pthread_setname_np("crash-main");
    const pid_t self = getpid();
    if (fork() == 0) {
      usleep(200000);
      kill(self, SIGSEGV);
      _exit(0);
    }
    for (;;) pause();
  }
  return 3; // not reached: the handler ends the process with exit(1)
}

static int g_failures;

// Runs one case; returns its report (stderr), or NULL.
static char *run_case(const char *self, const char *mode, int *status) {
  int p[2];
  if (pipe(p) != 0) return NULL;
  const pid_t pid = fork();
  if (pid == 0) {
    dup2(p[1], 2);
    close(p[0]);
    close(p[1]);
    execl(self, self, mode, (char *)NULL);
    _exit(4);
  }
  close(p[1]);
  size_t cap = 1 << 16, len = 0;
  char *buf = malloc(cap);
  ssize_t n;
  while (buf && (n = read(p[0], buf + len, cap - 1 - len)) > 0) len += (size_t)n;
  close(p[0]);
  waitpid(pid, status, 0);
  if (buf) buf[len] = 0;
  return buf;
}

static void expect(const char *mode, const char *report, const char *text, int present) {
  if ((strstr(report, text) != NULL) != present) {
    printf("crash_source_test: FAIL: case %s: the report %s \"%s\"\n", mode, present ? "lacks" : "has", text);
    g_failures++;
  }
}

static void check(const char *self, const char *mode, const char *const *has, const char *const *lacks) {
  int status = 0;
  char *report = run_case(self, mode, &status);
  if (!report) {
    printf("crash_source_test: FAIL: case %s did not run\n", mode);
    g_failures++;
    return;
  }
  if (!WIFEXITED(status) || WEXITSTATUS(status) != 1) {
    printf("crash_source_test: FAIL: case %s ended with status 0x%x, not exit(1)\n", mode, status);
    g_failures++;
  }
  for (; *has; has++) expect(mode, report, *has, 1);
  for (; *lacks; lacks++) expect(mode, report, *lacks, 0);
  if (g_failures) printf("--- report of case %s ---\n%s---\n", mode, report);
  free(report);
}

int main(int argc, char **argv) {
  if (argc > 1) return child(argv[1]);
  check(argv[0], "fault",
        (const char *const[]){"FATAL: Signal 11", "on host thread", "'crash-fault'", "Cause: a fault of this thread",
                              "FAR 0x8", NULL},
        (const char *const[]){"sent to the process", NULL});
  check(argv[0], "null",
        (const char *const[]){"FATAL: Signal 11", "'crash-main' (the main thread)", "Cause: a fault of this thread",
                              "FAR 0x0", NULL},
        (const char *const[]){"sent to the process", NULL});
  check(argv[0], "sent",
        (const char *const[]){"FATAL: Signal 11", "'crash-main' (the main thread)", "sent to the process", NULL},
        (const char *const[]){"Cause: a fault of this thread", NULL});
  if (g_failures) return 1;
  printf("crash_source_test: PASS\n");
  return 0;
}
