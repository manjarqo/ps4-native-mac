// Host test for the stall profile aggregation (kernel/threading/ps4_stall_profile.c).
#include "ps4_stall_profile.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

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
  printf("stall_profile_test: %s\n", ok ? "PASS" : "FAIL");
  return ok ? 0 : 1;
}
