// Host test for the stall profile aggregation (kernel/threading/ps4_stall_profile.c).
#include "ps4_stall_profile.h"
#include <stdio.h>
#include <stdlib.h>
#include <pthread.h>
#include <signal.h>
#include <string.h>
#include <time.h>
#include <sys/wait.h>
#include <unistd.h>

// Fixed address map standing in for dladdr: [start, start + 0x1000) -> name.
static int fake_symbolize(uint64_t pc, uint64_t *start, const char **name) {
  static const struct { uint64_t start; const char *name; } map[] = {
      {0x1000, "fn_0x1000"}, {0x2000, "__psynch_cvwait"}, {0x3000, "fn_0x3000"}, {0x4000, "memcpy"}};
  for (size_t i = 0; i < sizeof map / sizeof map[0]; i++)
    if (pc >= map[i].start && pc < map[i].start + 0x1000) {
      *start = map[i].start;
      *name = map[i].name;
      return 1;
    }
  return 0;
}

static double now_ms(void) {
  struct timespec ts;
  clock_gettime(CLOCK_MONOTONIC, &ts);
  return (double)ts.tv_sec * 1e3 + (double)ts.tv_nsec / 1e6;
}

static volatile int g_stop;

static void *spin_main(void *arg) {
  (void)arg;
  volatile uint64_t x = 0;
  while (!g_stop) x++;
  return NULL;
}

static void *sleep_main(void *arg) {
  (void)arg;
  while (!g_stop) usleep(2000); // wakes up 500 times a second, does nothing
  return NULL;
}

// Extracts the value after `key` in the line that contains `line_key`; -1 when absent.
static double field_after(const char *text, const char *line_key, const char *key) {
  const char *l = strstr(text, line_key);
  if (!l) return -1;
  const char *eol = strchr(l, '\n');
  const char *k = strstr(l, key);
  if (!k || (eol && k > eol)) return -1;
  return atof(k + strlen(key));
}

// Samples a spinning and a sleeping thread for ~250 ms, plus a child process that spins, and
// checks that the reported CPU brackets the truth: the spinner got about the whole window, the
// sleeper about nothing, the process total about one core, other processes about one core.
static int cpu_test(int final_attempt) {
  StallProfile *p = stall_profile_create(fake_symbolize);
  g_stop = 0;
  pthread_t spin, slp;
  pthread_create(&spin, NULL, spin_main, NULL);
  pthread_create(&slp, NULL, sleep_main, NULL);
  const pid_t child = fork();
  if (child == 0) {
    volatile uint64_t x = 0;
    for (;;) x++;
  }
  stall_profile_cpu_begin(p);
  const uint64_t pcs[] = {0x1010, 0x3010};
  double first = 0, last = 0;
  for (int i = 0; i < 250; i++) {
    stall_profile_add(p, 0, "Spinner", pcs, 2);
    stall_profile_thread_cpu(p, 0, stall_profile_thread_cpu_us(spin));
    stall_profile_add(p, 1, "Frame Submission", pcs, 2);
    stall_profile_thread_cpu(p, 1, stall_profile_thread_cpu_us(slp));
    if (i == 0) first = now_ms();
    last = now_ms();
    usleep(1000);
  }
  stall_profile_cpu_end(p);
  const double window = last - first;
  g_stop = 1;
  pthread_join(spin, NULL);
  pthread_join(slp, NULL);
  kill(child, SIGKILL);
  waitpid(child, NULL, 0);

  char *buf = NULL;
  size_t len = 0;
  FILE *out = open_memstream(&buf, &len);
  stall_profile_report(p, out, 300.0, 6);
  fclose(out);
  const double spin_cpu = field_after(buf, "Spinner:", "cpu ");
  const double slp_cpu = field_after(buf, "Frame Submission:", "cpu ");
  const double proc_cpu = field_after(buf, "stall 300 ms", "process cpu ");
  const double others = field_after(buf, "stall 300 ms", "other processes ");
  int ok = 1;
  // The spinner runs on one core for the whole window; the process total also holds the
  // sampling loop itself (a few ms), the sleeper and the spinner.
  if (!(spin_cpu > 0.7 * window && spin_cpu < 1.3 * window)) ok = 0;
  if (!(slp_cpu >= 0 && slp_cpu < 0.1 * window)) ok = 0;
  if (!(proc_cpu > 0.7 * window && proc_cpu < 1.3 * window + 30)) ok = 0;
  // The upper bound of other processes is machine wide (anything else running adds to it).
  if (!(others > 0.7 * window && others < 50 * window)) ok = 0;
  if (!ok && final_attempt) printf("cpu_test window %.0f ms: spinner %.1f, sleeper %.1f, process %.1f, others %.1f\n%s", window, spin_cpu,
                  slp_cpu, proc_cpu, others, buf);
  free(buf);

  // Deterministic format check: readings given by hand, first reading is the baseline.
  stall_profile_reset(p);
  for (int i = 0; i < 4; i++) {
    stall_profile_add(p, 2, "NdJobWorkerThread 1", pcs, 2);
    stall_profile_thread_cpu(p, 2, 1000 + (uint64_t)i * 4000); // 12000 us over the stall
  }
  stall_profile_add(p, 3, "SceFiosIO", pcs, 2);
  stall_profile_thread_cpu(p, 3, 5000); // one reading only: no cpu field
  stall_profile_thread_cpu(p, 2, 0); // an unreadable thread must not reset the readings
  buf = NULL;
  out = open_memstream(&buf, &len);
  stall_profile_report(p, out, 40.0, 6);
  fclose(out);
  if (!strstr(buf, "[stall-profile]   NdJobWorkerThread 1: busy 100%, cpu 12.0 ms: fn_0x1000 100%\n")) {
    printf("format check got:\n%s", buf);
    ok = 0;
  }
  if (strstr(buf, "SceFiosIO: busy 100%, cpu")) {
    printf("a single cpu reading was reported:\n%s", buf);
    ok = 0;
  }
  free(buf);
  stall_profile_destroy(p);
  return ok;
}

int main(void) {
  StallProfile *p = stall_profile_create(fake_symbolize);
  const uint64_t busy[] = {0x1010, 0x3010};
  const uint64_t copy[] = {0x4010, 0x1020};
  const uint64_t wait[] = {0x2010, 0x2014, 0x3040};
  for (int i = 0; i < 6; i++) stall_profile_add(p, 0, "NdJobWorkerThread 0", busy, 2);
  for (int i = 0; i < 3; i++) stall_profile_add(p, 0, "NdJobWorkerThread 0", copy, 2);
  stall_profile_add(p, 0, "NdJobWorkerThread 0", wait, 3);
  for (int i = 0; i < 10; i++) stall_profile_add(p, 1, "Frame Submission", wait, 3);
  for (int i = 0; i < 10; i++) stall_profile_add(p, 2, "SceFiosIO", wait, 3); // idle, not printed

  char *buf = NULL;
  size_t len = 0;
  FILE *out = open_memstream(&buf, &len);
  stall_profile_report(p, out, 250.0, 6);
  fclose(out);
  const char *expected =
      "[stall-profile] stall 250 ms, 10 samples\n"
      "[stall-profile]   NdJobWorkerThread 0: busy 90%: fn_0x1000 60%, memcpy 30%, __psynch_cvwait in fn_0x3000 10%\n"
      "[stall-profile]   Frame Submission: busy 0%: __psynch_cvwait in fn_0x3000 100%\n";
  int ok = strcmp(buf, expected) == 0;
  if (!ok) printf("expected:\n%sgot:\n%s", expected, buf);

  stall_profile_reset(p);
  free(buf);
  buf = NULL;
  out = open_memstream(&buf, &len);
  stall_profile_report(p, out, 10.0, 6);
  fclose(out);
  if (strcmp(buf, "[stall-profile] stall 10 ms, 0 samples\n") != 0) {
    printf("after reset got:\n%s", buf);
    ok = 0;
  }
  free(buf);
  stall_profile_destroy(p);
  // A loaded machine can starve the spinner; retry the timing measurement before failing.
  int cpu_ok = 0;
  for (int attempt = 1; attempt <= 3 && !cpu_ok; attempt++) cpu_ok = cpu_test(attempt == 3);
  if (!cpu_ok) ok = 0;
  printf("stall_profile_test: %s\n", ok ? "PASS" : "FAIL");
  return ok ? 0 : 1;
}
