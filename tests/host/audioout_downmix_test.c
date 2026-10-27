// Host test of libSceAudioOut's 8-channel -> stereo fold (audio_convert in ps4_audioout.c) on
// the real module with its headless device (PS4_AUDIO_NULL=1) and the final-mix WAV dump
// (PS4_AUDIO_DUMP). Every channel of a FLOAT_8CH_STD grain gets a distinct constant, so the
// played frame identifies each channel's destination and gain:
//   L = FL + 0.7071 * (FC + BL + SL),  R = FR + 0.7071 * (FC + BR + SR),  LFE dropped.
// A swapped pair, a lost centre, LFE leaking in or a wrong surround gain all change the frame.
// A PADSPK (controller speaker) port is mixed into both sides at its mix level: -9 dB
// (11626 / 32768) as opened, the level sceAudioOutSetMixLevelPadSpk sets after that; and the
// call's errors carry the SDK's codes.
#include "ps4_audioout_internal.h"
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static int g_fail;
#define CHECK(c)                                                                                   \
  do {                                                                                             \
    if (!(c)) {                                                                                    \
      fprintf(stderr, "audioout_downmix_test:%d: CHECK failed: %s\n", __LINE__, #c);              \
      g_fail = 1;                                                                                  \
    }                                                                                              \
  } while (0)

enum { LEN = 256, GRAINS = 100 };

// Plays GRAINS grains of one constant frame on a fresh port and counts the dumped frames that
// equal (want_l, want_r); returns that count, *other gets the non-silent mismatches.
// type: the port type; level >= 0: the PADSPK mix level to set before playing.
static long play_port(const char *dump, int32_t type, int32_t level, uint32_t fmt,
                      const float *frame, int ch, float want_l, float want_r, long *other,
                      long start) {
  int32_t h = ps4_audioout_port_open(0xFF, type, 0, LEN, 48000, fmt);
  CHECK(h > 0);
  if (level >= 0) CHECK(ps4_audioout_port_set_mix_level_padspk(h, level) == 0);
  static float buf[LEN * 8];
  for (int f = 0; f < LEN; f++) memcpy(buf + f * ch, frame, (size_t)ch * sizeof(float));
  for (int g = 0; g < GRAINS; g++) CHECK(ps4_audioout_port_output(h, buf) == LEN);
  usleep(1300 * 1000); // play out; the dump header is rewritten once per second of audio
  ps4_audioout_port_close(h);
  FILE *fp = fopen(dump, "rb");
  CHECK(fp != NULL);
  if (!fp) return 0;
  fseek(fp, 44 + start * 8, SEEK_SET);
  float fr[2];
  long match = 0;
  *other = 0;
  while (fread(fr, sizeof(float), 2, fp) == 2) {
    if (fr[0] == 0.0f && fr[1] == 0.0f) continue;
    if (fabsf(fr[0] - want_l) < 1e-6f && fabsf(fr[1] - want_r) < 1e-6f) match++;
    else (*other)++;
  }
  fclose(fp);
  return match;
}

static long play(const char *dump, uint32_t fmt, const float *frame, int ch, float want_l,
                 float want_r, long *other, long start) {
  return play_port(dump, PS4_AUDIO_OUT_PORT_MAIN, -1, fmt, frame, ch, want_l, want_r, other, start);
}

static long dump_frames(const char *dump) {
  FILE *fp = fopen(dump, "rb");
  if (!fp) return 0;
  fseek(fp, 0, SEEK_END);
  long n = (ftell(fp) - 44) / 8;
  fclose(fp);
  return n < 0 ? 0 : n;
}

int main(void) {
  char dump[] = "/tmp/audioout_downmix_XXXXXX";
  int fd = mkstemp(dump);
  if (fd < 0) return 1;
  close(fd);
  setenv("PS4_AUDIO_NULL", "1", 1);
  setenv("PS4_AUDIO_DUMP", dump, 1);
  unsetenv("PS4_AUDIO_MUTE");
  unsetenv("PS4_AUDIO_PADSPK");
  const float k = 0.7071f;

  // 8 channels, FL FR FC LFE BL BR SL SR, distinct values.
  const float c8[8] = {0.10f, 0.02f, 0.20f, 0.40f, 0.05f, 0.03f, 0.01f, 0.07f};
  const float l8 = c8[0] + k * c8[2] + k * c8[4] + k * c8[6];
  const float r8 = c8[1] + k * c8[2] + k * c8[5] + k * c8[7];
  long other = 0;
  long m = play(dump, PS4_AUDIO_OUT_FMT_FLOAT_8CH_STD, c8, 8, l8, r8, &other, 0);
  fprintf(stderr, "audioout_downmix_test: 8ch: %ld frames (%.6f, %.6f), %ld other\n", m, l8, r8, other);
  CHECK(m >= (long)GRAINS * LEN * 9 / 10 && m <= (long)GRAINS * LEN);
  CHECK(other == 0);

  // Centre alone: -3 dB into both sides, equal.
  const float fc[8] = {0, 0, 0.5f, 0, 0, 0, 0, 0};
  long start = dump_frames(dump);
  m = play(dump, PS4_AUDIO_OUT_FMT_FLOAT_8CH_STD, fc, 8, k * 0.5f, k * 0.5f, &other, start);
  CHECK(m >= (long)GRAINS * LEN * 9 / 10 && other == 0);

  // LFE alone: dropped, nothing audible.
  const float lfe[8] = {0, 0, 0, 0.9f, 0, 0, 0, 0};
  start = dump_frames(dump);
  m = play(dump, PS4_AUDIO_OUT_FMT_FLOAT_8CH_STD, lfe, 8, 0.0f, 0.0f, &other, start);
  CHECK(other == 0);

  // Stereo float keeps L and R apart.
  const float st[2] = {0.3f, -0.15f};
  start = dump_frames(dump);
  m = play(dump, PS4_AUDIO_OUT_FMT_FLOAT_STEREO, st, 2, 0.3f, -0.15f, &other, start);
  CHECK(m >= (long)GRAINS * LEN * 9 / 10 && other == 0);

  // PADSPK, mono: -9 dB as opened, into both sides.
  const float pad[1] = {0.8f};
  const float g9 = 0.8f * 11626.0f / 32768.0f;
  start = dump_frames(dump);
  m = play_port(dump, PS4_AUDIO_OUT_PORT_PADSPK, -1, PS4_AUDIO_OUT_FMT_FLOAT_MONO, pad, 1, g9, g9,
                &other, start);
  fprintf(stderr,
          "audioout_downmix_test: padspk at its default mix level: %ld frames (%.6f), %ld other\n",
          m, g9, other);
  CHECK(m >= (long)GRAINS * LEN * 9 / 10 && other == 0);
  // At the 0 dB mix level, as it comes.
  start = dump_frames(dump);
  m = play_port(dump, PS4_AUDIO_OUT_PORT_PADSPK, 32768, PS4_AUDIO_OUT_FMT_FLOAT_MONO, pad, 1, 0.8f,
                0.8f, &other, start);
  CHECK(m >= (long)GRAINS * LEN * 9 / 10 && other == 0);

  // sceAudioOutSetMixLevelPadSpk's errors, and the stats call's, by their SDK numbers.
  int32_t hm = ps4_audioout_port_open(0xFF, PS4_AUDIO_OUT_PORT_MAIN, 0, LEN, 48000,
                                      PS4_AUDIO_OUT_FMT_FLOAT_STEREO);
  int32_t hp = ps4_audioout_port_open(0xFF, PS4_AUDIO_OUT_PORT_PADSPK, 0, LEN, 48000,
                                      PS4_AUDIO_OUT_FMT_FLOAT_MONO);
  CHECK(hm > 0 && hp > 0);
  CHECK(ps4_audioout_port_set_mix_level_padspk(hm, 11626) == (int32_t)0x8026000A); // port type
  CHECK(ps4_audioout_port_set_mix_level_padspk(hp, 32769) == (int32_t)0x80260014); // mix level
  CHECK(ps4_audioout_port_set_mix_level_padspk(0x7FFFFFFF, 0) == (int32_t)0x80260003); // port
  CHECK(ps4_audioout_port_stats(hm, NULL) == (int32_t)0x80260004);                 // pointer
  CHECK(ps4_audioout_port_set_mix_level_padspk(hp, 0) == 0);
  ps4_audioout_port_close(hp);
  ps4_audioout_port_close(hm);

  unlink(dump);
  if (g_fail) {
    fprintf(stderr, "audioout_downmix_test: FAIL\n");
    return 1;
  }
  fprintf(stderr, "audioout_downmix_test: PASS\n");
  return 0;
}
