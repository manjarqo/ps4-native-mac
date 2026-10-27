// Host test of libSceAudioOut's final-mix dump (PS4_AUDIO_DUMP) on the headless device
// (PS4_AUDIO_NULL=1), one fresh child process per case (the module opens the dump once per
// process):
//   stall:       the parent stops the child (SIGSTOP) for 500 ms while it plays silence, then
//                lets it go on (SIGCONT) and the child plays a sine. The device must not re-base
//                its clock: the dump stays as long as the wall time since `frame 0 at mono`, and
//                the sine's first sample, mapped through that line, plays when the port's
//                counters predict. A device that resynchronises without writing the stalled
//                periods loses 500 ms of dump and maps the sine 500 ms early.
//   open-error:  a dump path in a missing directory: one line names the path and the errno;
//                output goes on.
//   write-error: a file size limit (RLIMIT_FSIZE) stops the dump: one line, naming the path and
//                the error, however many writes fail after it; output goes on.
//   exit-header: a run shorter than the once-per-second header update exits normally: the
//                header written at exit names every data byte in the file.
//   slow-io:     every 20th write to the dump file takes 120 ms (the test's own fwrite stands in
//                for libc's, as a filesystem that stalls on a commit). The guest's grains must
//                keep the device pace: no gap over two grains and no underrun, and the dump
//                still holds every frame. A dump written under the mixer lock, or on the
//                device's thread, stops the device for each stalled write. The bound is three
//                quarters of one stall (90 ms), not two grains, so a loaded host's scheduling
//                jitter cannot fail it; a stalled write under the lock still does.
#define _GNU_SOURCE
#include "ps4_audioout_internal.h"
#include <dlfcn.h>
#include <errno.h>
#include <math.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/resource.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

static int g_fail;
static const char *g_case = "";
#define CHECK(c, ...)                                                                              \
  do {                                                                                             \
    if (!(c)) {                                                                                    \
      fprintf(stderr, "audioout_dump_test %s:%d: CHECK failed: %s: ", g_case, __LINE__, #c);      \
      fprintf(stderr, __VA_ARGS__);                                                                \
      fprintf(stderr, "\n");                                                                       \
      g_fail = 1;                                                                                  \
    }                                                                                              \
  } while (0)

enum { LEN = 1024, RATE = 48000, PERIOD = 512 };

// slow-io: libSceAudioOut's fwrite calls bind to this definition (same image); it forwards to
// the C library's, and with g_slow_every set, every g_slow_every-th write to a file other than
// the standard streams first sleeps g_slow_us.
static int g_slow_every;
static useconds_t g_slow_us;
static int g_slow_writes, g_slow_stalls;
size_t fwrite(const void *restrict ptr, size_t size, size_t n, FILE *restrict f) {
  static size_t (*real)(const void *restrict, size_t, size_t, FILE *restrict);
  if (!real) {
    real = (size_t(*)(const void *restrict, size_t, size_t, FILE *restrict))dlsym(RTLD_NEXT,
                                                                                  "fwrite");
  }
  if (g_slow_every && f != stderr && f != stdout && ++g_slow_writes % g_slow_every == 0) {
    g_slow_stalls++;
    usleep(g_slow_us);
  }
  return real(ptr, size, n, f);
}

static uint64_t mono_us(void) {
  struct timespec ts;
  clock_gettime(CLOCK_MONOTONIC, &ts);
  return (uint64_t)ts.tv_sec * 1000000ULL + (uint64_t)ts.tv_nsec / 1000ULL;
}

static float g_buf[LEN * 2];
static double g_phase;

static void fill(int sine) {
  for (int f = 0; f < LEN; f++) {
    float v = sine ? 0.5f * (float)sin(g_phase) : 0.0f;
    if (sine) g_phase += 2.0 * M_PI * 440.0 / RATE;
    g_buf[f * 2] = g_buf[f * 2 + 1] = v;
  }
}

static char *read_file(const char *path, long *size) {
  FILE *f = fopen(path, "rb");
  if (!f) return NULL;
  fseek(f, 0, SEEK_END);
  long n = ftell(f);
  fseek(f, 0, SEEK_SET);
  char *b = (char *)calloc(1, (size_t)n + 1);
  if (n > 0 && fread(b, 1, (size_t)n, f) != (size_t)n) n = 0;
  fclose(f);
  if (size) *size = n;
  return b;
}

static int count(const char *text, const char *needle) {
  int n = 0;
  for (const char *p = strstr(text, needle); p; p = strstr(p + 1, needle)) n++;
  return n;
}

static int32_t open_port(void) {
  int32_t h = ps4_audioout_port_open(0xFF, PS4_AUDIO_OUT_PORT_MAIN, 0, LEN, RATE,
                                     PS4_AUDIO_OUT_FMT_FLOAT_STEREO);
  CHECK(h > 0, "open returned %d", h);
  return h;
}

// --- the children; each returns its exit status ---

static int child_stall(const char *dump, const char *err_path) {
  int32_t h = open_port();
  uint64_t t0 = mono_us();
  fill(0);
  while (mono_us() - t0 < 1600000) CHECK(ps4_audioout_port_output(h, g_buf) == LEN, "silent grain");
  for (int i = 0; i < 40; i++) {
    fill(1);
    CHECK(ps4_audioout_port_output(h, g_buf) == LEN, "sine grain");
  }
  usleep(150 * 1000);
  Ps4AudioPortStats st;
  CHECK(ps4_audioout_port_stats(h, &st) == 0, "stats");
  uint64_t now = mono_us();
  long size = 0;
  char *wav = read_file(dump, &size);
  fflush(stderr);
  char *err = read_file(err_path, NULL);
  double frame0 = -1.0;
  const char *l = err ? strstr(err, "frame 0 at mono ") : NULL;
  CHECK(l && sscanf(l, "frame 0 at mono %lf", &frame0) == 1, "no frame 0 line");
  // The parent's stop shows as a gap in the port's grains.
  CHECK(st.max_gap_us >= 400000, "max gap %llu us: the stop did not happen while the port ran",
        (unsigned long long)st.max_gap_us);
  if (wav && frame0 > 0) {
    long frames = (size - 44) / 8;
    long want = (long)(((double)now / 1e6 - frame0) * RATE);
    // Two device periods: the dump grows a period at a time, and the writer thread writes and
    // flushes each one after the device hands it on.
    fprintf(stderr, "audioout_dump_test stall: dump %ld frames, wall %ld frames, max gap %.1f ms\n",
            frames, want, st.max_gap_us / 1000.0);
    CHECK(labs(frames - want) <= 2 * PERIOD, "dump %ld frames, wall time %ld frames", frames, want);
    long first = -1;
    const float *s = (const float *)(wav + 44);
    for (long n = 0; n < frames; n++) {
      if (s[n * 2] != 0.0f || s[n * 2 + 1] != 0.0f) {
        first = n;
        break;
      }
    }
    CHECK(first >= 0, "no sound in the dump");
    double d_ms = ((frame0 + (double)first / RATE) * 1e6 - (double)st.first_sound_play_us) / 1000.0;
    fprintf(stderr, "audioout_dump_test stall: first sound %.2f ms from its predicted play time\n", d_ms);
    CHECK(fabs(d_ms) <= 25.0, "first sound %.2f ms from first_sound_play_us", d_ms);
  }
  free(wav);
  free(err);
  ps4_audioout_port_close(h);
  return g_fail;
}

static int child_open_error(void) {
  int32_t h = open_port();
  fill(1);
  for (int i = 0; i < 10; i++) CHECK(ps4_audioout_port_output(h, g_buf) == LEN, "grain %d", i);
  ps4_audioout_port_close(h);
  return g_fail;
}

static int child_write_error(void) {
  struct rlimit rl = {128 * 1024, 128 * 1024};
  signal(SIGXFSZ, SIG_IGN);
  setrlimit(RLIMIT_FSIZE, &rl);
  int32_t h = open_port();
  fill(1);
  // 1.5 s of audio is 576 KB of dump.
  for (int i = 0; i < 70; i++) CHECK(ps4_audioout_port_output(h, g_buf) == LEN, "grain %d", i);
  ps4_audioout_port_close(h);
  return g_fail;
}

static int child_exit_header(void) {
  int32_t h = open_port();
  fill(1);
  for (int i = 0; i < 20; i++) CHECK(ps4_audioout_port_output(h, g_buf) == LEN, "grain %d", i);
  usleep(100 * 1000);
  ps4_audioout_port_close(h);
  return g_fail; // a normal exit: the module's exit handler writes the final header
}

static int child_slow_io(const char *dump) {
  g_slow_every = 20;
  g_slow_us = 120 * 1000;
  int32_t h = open_port();
  fill(0);
  // The ring's worth of grains goes in at once; from there each call waits for the device.
  for (int i = 0; i < 4; i++) CHECK(ps4_audioout_port_output(h, g_buf) == LEN, "grain %d", i);
  Ps4AudioPortStats st0;
  CHECK(ps4_audioout_port_stats(h, &st0) == 0, "stats");
  uint64_t t0 = mono_us();
  while (mono_us() - t0 < 2000000) {
    fill(1);
    CHECK(ps4_audioout_port_output(h, g_buf) == LEN, "sine grain");
  }
  Ps4AudioPortStats st;
  CHECK(ps4_audioout_port_stats(h, &st) == 0, "stats");
  int stalls = g_slow_stalls;
  fprintf(stderr,
          "audioout_dump_test slow-io: %d stalled writes of 120 ms, %llu grains, max gap %.1f ms, "
          "underrun frames %llu\n",
          stalls, (unsigned long long)(st.outputs - st0.outputs), st.max_gap_us / 1000.0,
          (unsigned long long)st.underrun_frames);
  CHECK(stalls >= 3, "only %d stalled writes: the case did not stall the dump", stalls);
  // Under three quarters of one stalled write (cfbee12, writing under the lock: 150 ms).
  CHECK(st.max_gap_us < (uint64_t)g_slow_us * 3 / 4, "max gap %.1f ms, a stalled write is %u ms",
        st.max_gap_us / 1000.0, (unsigned)(g_slow_us / 1000));
  CHECK(st.underrun_frames == 0, "underrun frames %llu", (unsigned long long)st.underrun_frames);
  ps4_audioout_port_close(h);
  (void)dump;
  return g_fail; // the exit handler writes the rest of the ring and the final header
}

// Runs one case in a child with `dump` as PS4_AUDIO_DUMP; the child's stderr goes to err_path.
// With stall_us, the parent stops the child for that long after stop_after_us.
static int run(const char *name, int (*fn)(const char *, const char *), const char *dump,
               const char *err_path, uint64_t stop_after_us, uint64_t stall_us) {
  fflush(stderr);
  pid_t pid = fork();
  if (pid == 0) {
    g_case = name;
    g_fail = 0;
    FILE *e = freopen(err_path, "w", stderr);
    if (!e) _exit(2);
    setvbuf(stderr, NULL, _IONBF, 0);
    setenv("PS4_AUDIO_NULL", "1", 1);
    setenv("PS4_AUDIO_DUMP", dump, 1);
    unsetenv("PS4_AUDIO_MUTE");
    exit(fn(dump, err_path));
  }
  if (stall_us) {
    usleep((useconds_t)stop_after_us);
    kill(pid, SIGSTOP);
    usleep((useconds_t)stall_us);
    kill(pid, SIGCONT);
  }
  int status = 0;
  waitpid(pid, &status, 0);
  return WIFEXITED(status) ? WEXITSTATUS(status) : 128 + WTERMSIG(status);
}

static int wrap_stall(const char *d, const char *e) { return child_stall(d, e); }
static int wrap_open(const char *d, const char *e) { (void)d; (void)e; return child_open_error(); }
static int wrap_write(const char *d, const char *e) { (void)d; (void)e; return child_write_error(); }
static int wrap_exit(const char *d, const char *e) { (void)d; (void)e; return child_exit_header(); }
static int wrap_slow(const char *d, const char *e) { (void)e; return child_slow_io(d); }

int main(int argc, char **argv) {
  const char *dir = argc > 1 ? argv[1] : "/tmp";
  char dump[1024], err[1024];
  char *text;

  // --- stall ---
  g_case = "stall";
  snprintf(dump, sizeof dump, "%s/dump_stall.wav", dir);
  snprintf(err, sizeof err, "%s/dump_stall.txt", dir);
  int rc = run("stall", wrap_stall, dump, err, 600000, 500000);
  text = read_file(err, NULL);
  if (text) fputs(text, stderr);
  CHECK(rc == 0, "stall child exited %d", rc);
  free(text);
  unlink(dump);

  // --- open error ---
  g_case = "open-error";
  snprintf(dump, sizeof dump, "%s/no_such_dir_%d/dump.wav", dir, (int)getpid());
  snprintf(err, sizeof err, "%s/dump_open.txt", dir);
  rc = run("open-error", wrap_open, dump, err, 0, 0);
  text = read_file(err, NULL);
  CHECK(rc == 0, "open-error child exited %d", rc);
  if (text) {
    char want[1200];
    snprintf(want, sizeof want, "PS4_AUDIO_DUMP: cannot open %s: %s (errno %d)", dump, strerror(ENOENT),
             ENOENT);
    CHECK(count(text, want) == 1, "no line '%s' in:\n%s", want, text);
    fprintf(stderr, "audioout_dump_test open-error: %s\n", want);
  }
  free(text);

  // --- write error ---
  g_case = "write-error";
  snprintf(dump, sizeof dump, "%s/dump_write.wav", dir);
  snprintf(err, sizeof err, "%s/dump_write.txt", dir);
  rc = run("write-error", wrap_write, dump, err, 0, 0);
  text = read_file(err, NULL);
  CHECK(rc == 0, "write-error child exited %d", rc);
  if (text) {
    char want[1200];
    snprintf(want, sizeof want, "PS4_AUDIO_DUMP: writing %s failed", dump);
    int n = count(text, want);
    CHECK(n == 1, "%d lines '%s' in:\n%s", n, want, text);
    CHECK(strstr(text, strerror(EFBIG)) != NULL, "the line does not name '%s':\n%s", strerror(EFBIG), text);
    const char *l = strstr(text, want);
    if (l) fprintf(stderr, "audioout_dump_test write-error: %.*s\n", (int)strcspn(l, "\n"), l);
  }
  free(text);
  unlink(dump);

  // --- final header at exit ---
  g_case = "exit-header";
  snprintf(dump, sizeof dump, "%s/dump_exit.wav", dir);
  snprintf(err, sizeof err, "%s/dump_exit.txt", dir);
  rc = run("exit-header", wrap_exit, dump, err, 0, 0);
  CHECK(rc == 0, "exit-header child exited %d", rc);
  long size = 0;
  char *wav = read_file(dump, &size);
  CHECK(wav && size > 44 + 8 * 1024, "dump of %ld bytes", size);
  if (wav && size > 44) {
    uint32_t riff, data;
    memcpy(&riff, wav + 4, 4);
    memcpy(&data, wav + 40, 4);
    fprintf(stderr, "audioout_dump_test exit-header: file %ld bytes, header data %u, riff %u\n", size,
            data, riff);
    CHECK(data == (uint32_t)(size - 44), "header data size %u, file holds %ld", data, size - 44);
    CHECK(riff == (uint32_t)(size - 8), "RIFF size %u, file %ld", riff, size);
  }
  free(wav);
  unlink(dump);

  // --- slow writes ---
  g_case = "slow-io";
  snprintf(dump, sizeof dump, "%s/dump_slow.wav", dir);
  snprintf(err, sizeof err, "%s/dump_slow.txt", dir);
  rc = run("slow-io", wrap_slow, dump, err, 0, 0);
  text = read_file(err, NULL);
  if (text) fputs(text, stderr);
  CHECK(rc == 0, "slow-io child exited %d", rc);
  free(text);
  wav = read_file(dump, &size);
  if (wav && size > 44) {
    uint32_t data;
    memcpy(&data, wav + 40, 4);
    // 2 s of grains after 4 queued ones: at least 2 s of frames, whatever the stalls.
    long frames = (size - 44) / 8;
    fprintf(stderr, "audioout_dump_test slow-io: dump %ld frames, header data %u bytes\n", frames,
            data);
    CHECK(data == (uint32_t)(size - 44), "header data size %u, file holds %ld", data, size - 44);
    CHECK(frames >= 2 * RATE, "dump %ld frames for a 2 s run", frames);
  } else {
    CHECK(0, "no slow-io dump (%ld bytes)", size);
  }
  free(wav);
  unlink(dump);

  g_case = "";
  if (g_fail) {
    fprintf(stderr, "audioout_dump_test: FAIL\n");
    return 1;
  }
  fprintf(stderr, "audioout_dump_test: PASS (stall, open error, write error, header at exit, slow writes)\n");
  return 0;
}
