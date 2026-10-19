// Output written through the asynchronous stdout/stderr (core/ps4_log.c) must survive abort()
// and exit(), also when the consumer is slower than the writer. Linked with ps4_log.c, whose
// constructor redirects fd 1/2 when they are not terminals.
//   log_abort_test <abort|exit> [lines]                  child: stdout/stderr redirected by the caller
//   log_abort_test drive <abort|exit> <lines> <outfile>  runs the child with stdout and stderr on one
//       pipe read by a slow consumer (512 bytes every 0.5 ms) that appends to <outfile>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

static void nap(long ns) { nanosleep(&(struct timespec){0, ns}, NULL); }

static int child(const char *mode, int lines) {
  setvbuf(stdout, NULL, _IONBF, 0); // as the generated main() does
  setvbuf(stderr, NULL, _IONBF, 0);
  for (int i = 0; i < lines; i++) fprintf(i % 2 ? stderr : stdout, "line %d\n", i);
  fprintf(stderr, "FATAL last line\n");
  if (strcmp(mode, "exit") == 0) exit(0);
  abort();
}

static int drive(char *self, const char *mode, const char *lines, const char *outfile) {
  int p[2];
  if (pipe(p) != 0) return 2;
  pid_t reader = fork();
  if (reader == 0) {
    close(p[1]);
    FILE *out = fopen(outfile, "w");
    if (!out) _exit(2);
    char buf[512];
    ssize_t n;
    while ((n = read(p[0], buf, sizeof buf)) > 0) {
      fwrite(buf, 1, (size_t)n, out);
      nap(500000);
    }
    fclose(out);
    _exit(0);
  }
  pid_t writer = fork();
  if (writer == 0) {
    dup2(p[1], 1);
    dup2(p[1], 2);
    close(p[0]);
    close(p[1]);
    execl(self, self, mode, lines, (char *)NULL);
    _exit(3);
  }
  close(p[0]);
  close(p[1]);
  waitpid(writer, NULL, 0);
  waitpid(reader, NULL, 0);
  return 0;
}

int main(int argc, char **argv) {
  if (argc >= 5 && strcmp(argv[1], "drive") == 0) return drive(argv[0], argv[2], argv[3], argv[4]);
  return child(argc > 1 ? argv[1] : "abort", argc > 2 ? atoi(argv[2]) : 200);
}
