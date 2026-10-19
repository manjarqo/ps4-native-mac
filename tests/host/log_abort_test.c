// Output written through the asynchronous stdout/stderr (core/ps4_log.c) must survive abort()
// and exit(). Linked with ps4_log.c, whose constructor redirects fd 1/2 when they are files.
// usage: log_abort_test <abort|exit>   (stdout and stderr redirected by the caller)
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

int main(int argc, char **argv) {
  setvbuf(stdout, NULL, _IONBF, 0); // as the generated main() does
  setvbuf(stderr, NULL, _IONBF, 0);
  for (int i = 0; i < 200; i++) {
    fprintf(i % 2 ? stderr : stdout, "line %d\n", i);
  }
  fprintf(stderr, "FATAL last line\n");
  if (argc > 1 && strcmp(argv[1], "exit") == 0) exit(0);
  abort();
}
