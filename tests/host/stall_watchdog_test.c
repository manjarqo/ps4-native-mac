// Host test: the stall watchdog (PS4_STALL_WATCHDOG) counts a stall from the moment VideoOut opens,
// so a boot that never presents still gets its thread report. Arming twice starts one watchdog
// thread and yields one report per stall; a present afterwards ends the stall.
#define RUNTIME_STUBS_HAVE_THREADING
#include "runtime_stubs.h"
#include "ps4_threading.h"

#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

// Runtime hooks the watchdog does not exercise.
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

static int count_reports(int fd) {
  char buf[8192];
  const ssize_t n = pread(fd, buf, sizeof(buf) - 1, 0);
  if (n <= 0) return 0;
  buf[n] = 0;
  int count = 0;
  for (const char *p = buf; (p = strstr(p, "[stall] no frame for")) != NULL; p++) count++;
  return count;
}

int main(void) {
  setenv("PS4_STALL_WATCHDOG", "100", 1);
  char path[] = "/tmp/stall_watchdog_test.XXXXXX";
  const int fd = mkstemp(path);
  if (fd < 0) {
    printf("stall_watchdog_test: cannot create the capture file\n");
    return 1;
  }
  unlink(path);
  fflush(stderr);
  const int saved = dup(2);
  dup2(fd, 2);

  ps4_stall_watchdog_arm();
  ps4_stall_watchdog_arm();
  usleep(400 * 1000);
  const int armed_reports = count_reports(fd);

  ps4_stall_watchdog_note_present();
  usleep(50 * 1000);
  const int after_present = count_reports(fd);

  fflush(stderr);
  dup2(saved, 2);
  CHECK(armed_reports == 1, "armed with no present: %d reports, want exactly 1", armed_reports);
  CHECK(after_present == armed_reports, "a present ended the stall but the count went %d -> %d", armed_reports,
        after_present);
  if (g_failures) return 1;
  printf("stall_watchdog_test: PASS\n");
  return 0;
}
