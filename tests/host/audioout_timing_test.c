// Host test of libSceAudioOut's port timing counters and of the final-mix dump's place on the
// CLOCK_MONOTONIC timeline, on the real module with its headless device. The runner sets
// PS4_AUDIO_NULL=1, PS4_AUDIO_LOG=1 and PS4_AUDIO_DUMP=<file>.
//
// A FLOAT_8CH_STD port with 1024-frame grains gets 40 silent grains, then 60 grains of a 440 Hz
// sine, at the device pace (each call blocks), then nothing for 300 ms, then 20 more grains.
// Checked through ps4_audioout_port_stats: 120 outputs, the 300 ms hole as the longest gap, a
// late output (the ring had run empty), the silence the device filled in, and the first sound
// at the 41st output. Checked through the dump: it is as long as the run's wall time, its
// `frame 0 at mono` line parses, and its first non-zero sample, mapped through that line, plays
// when the counters say the first sound reaches the device.
#define _GNU_SOURCE
#include "ps4_audioout_internal.h"
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

static int g_fail;
#define CHECK(c, ...)                                                                              \
  do {                                                                                             \
    if (!(c)) {                                                                                    \
      fprintf(stderr, "audioout_timing_test:%d: CHECK failed: %s: ", __LINE__, #c);               \
      fprintf(stderr, __VA_ARGS__);                                                                \
      fprintf(stderr, "\n");                                                                       \
      g_fail = 1;                                                                                  \
    }                                                                                              \
  } while (0)

enum { LEN = 1024, RATE = 48000, PERIOD = 512 };

static uint64_t mono_us(void) {
  struct timespec ts;
  clock_gettime(CLOCK_MONOTONIC, &ts);
  return (uint64_t)ts.tv_sec * 1000000ULL + (uint64_t)ts.tv_nsec / 1000ULL;
}

static float g_buf[LEN * 8];
static double g_phase;

static void fill_sine(void) {
  for (int f = 0; f < LEN; f++) {
    float v = 0.5f * (float)sin(g_phase);
    g_phase += 2.0 * M_PI * 440.0 / RATE;
    for (int c = 0; c < 8; c++) g_buf[f * 8 + c] = (c < 2) ? v : 0.0f;
  }
}

// The module's stderr goes to a file so the test can read its lines; it is copied to the real
// stderr at the end.
static FILE *g_err_file;
static int g_real_err = -1;

static void capture_stderr(void) {
  g_err_file = tmpfile();
  fflush(stderr);
  g_real_err = dup(2);
  dup2(fileno(g_err_file), 2);
}

static char *release_stderr(void) {
  fflush(stderr);
  dup2(g_real_err, 2);
  close(g_real_err);
  long n = ftell(g_err_file);
  char *text = (char *)calloc(1, (size_t)n + 1);
  fseek(g_err_file, 0, SEEK_SET);
  if (n > 0 && fread(text, 1, (size_t)n, g_err_file) != (size_t)n) text[0] = 0;
  fclose(g_err_file);
  fputs(text, stderr);
  return text;
}

int main(void) {
  const char *dump = getenv("PS4_AUDIO_DUMP");
  if (!dump || !*dump || !getenv("PS4_AUDIO_NULL") || !getenv("PS4_AUDIO_LOG")) {
    fprintf(stderr, "audioout_timing_test: run with PS4_AUDIO_NULL, PS4_AUDIO_LOG and PS4_AUDIO_DUMP set\n");
    return 1;
  }
  unsetenv("PS4_AUDIO_MUTE");
  capture_stderr();

  int32_t h = ps4_audioout_port_open(0xFF, PS4_AUDIO_OUT_PORT_MAIN, 0, LEN, RATE,
                                     PS4_AUDIO_OUT_FMT_FLOAT_8CH_STD);
  CHECK(h > 0, "open returned %d", h);
  uint64_t done[120]; // CLOCK_MONOTONIC time each output returned
  int k = 0;
  memset(g_buf, 0, sizeof(g_buf));
  for (int i = 0; i < 40; i++, k++) {
    CHECK(ps4_audioout_port_output(h, g_buf) == LEN, "silent grain %d", i);
    done[k] = mono_us();
  }
  for (int i = 0; i < 60; i++, k++) {
    fill_sine();
    CHECK(ps4_audioout_port_output(h, g_buf) == LEN, "sine grain %d", i);
    done[k] = mono_us();
  }
  usleep(300 * 1000);
  for (int i = 0; i < 20; i++, k++) {
    fill_sine();
    CHECK(ps4_audioout_port_output(h, g_buf) == LEN, "late sine grain %d", i);
    done[k] = mono_us();
  }
  usleep(150 * 1000); // the last grains play out

  Ps4AudioPortStats st;
  CHECK(ps4_audioout_port_stats(h, &st) == 0, "stats");
  CHECK(ps4_audioout_port_stats(h, NULL) == PS4_AUDIO_OUT_ERROR_INVALID_POINTER, "stats without out");
  CHECK(ps4_audioout_port_stats(h + 1, &st) == PS4_AUDIO_OUT_ERROR_INVALID_PORT, "stats of a closed port");
  CHECK(ps4_audioout_port_stats(h, &st) == 0, "stats");
  uint64_t now = mono_us();
  // Read the dump's length at the same moment.
  FILE *fp = fopen(dump, "rb");
  long dump_frames = 0;
  if (fp) {
    fseek(fp, 0, SEEK_END);
    dump_frames = (ftell(fp) - 44) / 8;
  }

  CHECK(st.outputs == 120, "outputs %llu", (unsigned long long)st.outputs);
  CHECK(st.max_gap_us >= 290000, "max_gap_us %llu", (unsigned long long)st.max_gap_us);
  CHECK(st.late_outputs >= 1, "late_outputs %llu", (unsigned long long)st.late_outputs);
  const uint64_t hole = 300ULL * RATE / 1000;
  CHECK(st.ring_frames > 0 && st.ring_frames < hole, "ring_frames %u", st.ring_frames);
  CHECK(st.underrun_frames >= hole - st.ring_frames, "underrun_frames %llu, want >= %llu",
        (unsigned long long)st.underrun_frames, (unsigned long long)(hole - st.ring_frames));
  CHECK(st.underruns >= 1, "underruns %llu", (unsigned long long)st.underruns);
  CHECK(st.first_sound_us >= done[39] && st.first_sound_us <= done[40],
        "first_sound_us %llu not between the 40th (%llu) and 41st (%llu) outputs",
        (unsigned long long)st.first_sound_us, (unsigned long long)done[39],
        (unsigned long long)done[40]);
  CHECK(st.first_sound_outputs == 40, "first sound after %llu outputs",
        (unsigned long long)st.first_sound_outputs);
  // 40 grains were queued ahead of the sine; at most the ring's worth was still waiting.
  CHECK(st.first_sound_play_us >= st.first_sound_us &&
            st.first_sound_play_us <= st.first_sound_us + (uint64_t)st.ring_frames * 1000000ULL / RATE,
        "first_sound_play_us %llu (queued at %llu)", (unsigned long long)st.first_sound_play_us,
        (unsigned long long)st.first_sound_us);
  CHECK(st.last_output_us >= done[118] && st.last_output_us <= done[119], "last_output_us %llu",
        (unsigned long long)st.last_output_us);

  char *err = release_stderr();
  // [AudioOut] dump frame 0 at mono <s>
  double frame0 = -1.0;
  const char *l = strstr(err, "frame 0 at mono ");
  CHECK(l && sscanf(l, "frame 0 at mono %lf", &frame0) == 1, "no 'frame 0 at mono' line");
  // [AudioOut] port N first non-silent grain at mono X (after K outputs)
  int port = 0, after = -1;
  double first_line = -1.0;
  l = strstr(err, "first non-silent grain at mono ");
  CHECK(l && sscanf(l, "first non-silent grain at mono %lf (after %d outputs)", &first_line, &after) == 2,
        "no 'first non-silent grain' line");
  CHECK(after == 40, "first non-silent line says after %d outputs", after);
  CHECK(fabs(first_line * 1e6 - (double)st.first_sound_us) < 2000.0,
        "first non-silent line at %.6f, stats %.6f", first_line, st.first_sound_us / 1e6);
  // A stats line with the window and its expectation.
  unsigned long long o = 0, w = 0, late = 0, under = 0, uframes = 0;
  double e = -1.0, gap = -1.0, mono_line = -1.0;
  l = strstr(err, "] port ");
  int stat_lines = 0;
  for (; l; l = strstr(l + 1, "] port ")) {
    const char *q = strstr(l, " outputs=");
    const char *eol = strchr(l, '\n');
    if (!q || (eol && q > eol)) continue;
    if (sscanf(l, "] port %d", &port) == 1 &&
        sscanf(q, " outputs=%llu (window %llu, expected %lf) max_gap_ms=%lf late=%llu underruns=%llu "
                  "underrun_frames=%llu mono=%lf",
               &o, &w, &e, &gap, &late, &under, &uframes, &mono_line) == 8) {
      stat_lines++;
    }
  }
  CHECK(stat_lines >= 1, "no stats line with the timing fields parses");
  if (stat_lines) {
    CHECK(port == h && e > 0.0 && mono_line > frame0, "stats line: port %d expected %.1f mono %.3f",
          port, e, mono_line);
  }
  free(err);

  if (fp && frame0 > 0) {
    // The dump covers the run's wall time. Two device periods (2 x 512 frames): the headless
    // device adds a period at a time (the reading falls between two), and the dump's writer
    // thread writes and flushes it after the device hands it on (the reading can fall between
    // the two).
    long want = (long)(((double)now / 1e6 - frame0) * RATE);
    fprintf(stderr, "audioout_timing_test: dump %ld frames, wall %ld frames\n", dump_frames, want);
    CHECK(labs(dump_frames - want) <= 2 * PERIOD, "dump %ld frames, wall time %ld frames", dump_frames,
          want);
    // The first non-zero sample plays when the counters say.
    fseek(fp, 44, SEEK_SET);
    float fr[2];
    long n = 0, first = -1;
    while (fread(fr, sizeof(float), 2, fp) == 2) {
      if (fr[0] != 0.0f || fr[1] != 0.0f) {
        first = n;
        break;
      }
      n++;
    }
    CHECK(first >= 0, "the dump has no sound");
    double at = frame0 + (double)first / RATE;
    double d_ms = (at * 1e6 - (double)st.first_sound_play_us) / 1000.0;
    fprintf(stderr,
            "audioout_timing_test: first sound in the dump at mono %.4f (frame %ld): %.2f ms from the "
            "predicted play time, %.2f ms after it was queued\n",
            at, first, d_ms, (at * 1e6 - (double)st.first_sound_us) / 1000.0);
    CHECK(fabs(d_ms) <= 25.0, "first sound %.2f ms from first_sound_play_us", d_ms);
  }
  if (fp) fclose(fp);
  ps4_audioout_port_close(h);

  if (g_fail) {
    fprintf(stderr, "audioout_timing_test: FAIL\n");
    return 1;
  }
  fprintf(stderr,
          "audioout_timing_test: PASS (max gap %.1f ms, late %llu, underrun frames %llu, first sound "
          "after %llu outputs)\n",
          st.max_gap_us / 1000.0, (unsigned long long)st.late_outputs,
          (unsigned long long)st.underrun_frames, (unsigned long long)st.first_sound_outputs);
  return 0;
}
