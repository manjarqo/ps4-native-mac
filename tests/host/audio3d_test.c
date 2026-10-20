// Host test of libSceAudio3d (modules/libSceAudio3d) on the real libSceAudioOut HLE with its
// headless output device (PS4_AUDIO_NULL=1: a 48 kHz clock thread consumes and mixes the port
// rings, PS4_AUDIO_DUMP captures the final stereo mix). Covers the panner, attribute validation,
// queue levels and device pacing of PortAdvance / PortPush / GetQueueLevel, the AudioOut
// association, and a bed plus an object mixed to a known output sample.
#include "ps4_audio3d.h"
#include "ps4_audio3d_mix.h"
#include "ps4_audioout_internal.h"
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

static int g_fail;
#define CHECK(c)                                                                                   \
  do {                                                                                             \
    if (!(c)) {                                                                                    \
      fprintf(stderr, "audio3d_test:%d: CHECK failed: %s\n", __LINE__, #c);                       \
      g_fail = 1;                                                                                  \
    }                                                                                              \
  } while (0)
#define CHECK_EQ(a, b)                                                                             \
  do {                                                                                             \
    long long _a = (long long)(a), _b = (long long)(b);                                            \
    if (_a != _b) {                                                                                \
      fprintf(stderr, "audio3d_test:%d: %s = 0x%llx, want 0x%llx\n", __LINE__, #a, _a, _b);       \
      g_fail = 1;                                                                                  \
    }                                                                                              \
  } while (0)
#define NEAR(a, b) (fabs((double)(a) - (double)(b)) < 1e-6)

static double now_s(void) {
  struct timespec ts;
  clock_gettime(CLOCK_MONOTONIC, &ts);
  return (double)ts.tv_sec + (double)ts.tv_nsec / 1e9;
}

static void check_gains(const float g[8], const float want[8], int line) {
  for (int c = 0; c < 8; c++) {
    if (!NEAR(g[c], want[c])) {
      fprintf(stderr, "audio3d_test:%d: gain[%d] = %.7f, want %.7f\n", line, c, g[c], want[c]);
      g_fail = 1;
    }
  }
}

static void pan_case(uint32_t ch, float x, float z, float spread, uint32_t pass, float gain,
                     const float want[8], int line) {
  Ps4A3dPanParams p = {{x, 0.0f, z}, gain, spread, pass};
  float g[8];
  ps4_a3d_pan_gains(ch, &p, g);
  check_gains(g, want, line);
}

static void test_panner(void) {
  const float h = (float)cos(M_PI / 4); // equal-power midpoint
  const float e7 = (float)(1.0 / sqrt(7.0));
  // 7.1: FL FR FC LFE BL BR SL SR
  pan_case(8, 0, 1, 0, 0, 1, (float[8]){0, 0, 1, 0, 0, 0, 0, 0}, __LINE__);  // front
  pan_case(8, 1, 0, 0, 0, 1, (float[8]){0, 0, 0, 0, 0, 0, 0, 1}, __LINE__);  // right
  pan_case(8, -1, 0, 0, 0, 1, (float[8]){0, 0, 0, 0, 0, 0, 1, 0}, __LINE__); // left
  pan_case(8, (float)sin(M_PI / 3), (float)cos(M_PI / 3), 0, 0, 1, (float[8]){0, h, 0, 0, 0, 0, 0, h},
           __LINE__);                                                         // 60 deg: FR/SR
  pan_case(8, 0, -1, 0, 0, 0.5f, (float[8]){0, 0, 0, 0, 0.5f * h, 0.5f * h, 0, 0}, __LINE__); // behind
  pan_case(8, 0, 0, 0, 0, 1, (float[8]){e7, e7, e7, 0, e7, e7, e7, e7}, __LINE__); // at listener
  pan_case(8, 0, 1, (float)(2 * M_PI), 0, 1, (float[8]){e7, e7, e7, 0, e7, e7, e7, e7}, __LINE__);
  pan_case(8, 1, 0, 0, PS4_A3D_PASSTHROUGH_LEFT, 0.25f, (float[8]){0.25f, 0, 0, 0, 0, 0, 0, 0},
           __LINE__);
  pan_case(8, 1, 0, 0, PS4_A3D_PASSTHROUGH_RIGHT, 1, (float[8]){0, 1, 0, 0, 0, 0, 0, 0}, __LINE__);
  // stereo
  pan_case(2, 0, 1, 0, 0, 1, (float[8]){h, h, 0, 0, 0, 0, 0, 0}, __LINE__);
  pan_case(2, 1, 0, 0, 0, 1, (float[8]){0, 1, 0, 0, 0, 0, 0, 0}, __LINE__);
  pan_case(2, 0, -1, 0, 0, 1, (float[8]){h, h, 0, 0, 0, 0, 0, 0}, __LINE__); // mirrored to front
  pan_case(2, -1, 0, 0, 0, 1, (float[8]){1, 0, 0, 0, 0, 0, 0, 0}, __LINE__);

  // mono mix and bed mapping
  float out[4 * 8] = {0};
  float ramp[4] = {0.1f, 0.2f, 0.3f, 0.4f};
  float g[8] = {0, 0.5f, 0, 0, 0, 0, 0, 2.0f};
  ps4_a3d_mix_mono(out, 8, ramp, 4, g);
  for (int f = 0; f < 4; f++) {
    CHECK(NEAR(out[f * 8 + 1], ramp[f] * 0.5f) && NEAR(out[f * 8 + 7], ramp[f] * 2.0f));
    CHECK(out[f * 8 + 0] == 0 && out[f * 8 + 2] == 0);
  }
  float bed6[6] = {1, 2, 3, 4, 5, 6}; // FL FR FC LFE SL SR
  float o8[8] = {0};
  ps4_a3d_mix_bed(o8, 8, bed6, 6, 1);
  check_gains(o8, (float[8]){1, 2, 3, 4, 0, 0, 5, 6}, __LINE__);
  float o2[2] = {0};
  ps4_a3d_mix_bed(o2, 2, bed6, 6, 1);
  CHECK(NEAR(o2[0], 1 + 0.7071f * 3 + 0.7071f * 5) && NEAR(o2[1], 2 + 0.7071f * 3 + 0.7071f * 6));
  int16_t s16[2] = {16384, -32768};
  float cv[2];
  ps4_a3d_convert(cv, s16, PS4_AUDIO3D_FORMAT_S16, 2);
  CHECK(cv[0] == 0.5f && cv[1] == -1.0f);
}

static uint32_t open_port(uint32_t gran, uint32_t depth, uint32_t mode, uint32_t max_objects) {
  uint8_t raw[0x28];
  ps4_audio3d_get_default_open_parameters(raw);
  Ps4Audio3dOpenParameters p;
  memcpy(&p, raw, 0x20);
  p.granularity = gran;
  p.queue_depth = depth;
  p.buffer_mode = mode;
  p.max_objects = max_objects;
  uint32_t id = 0;
  CHECK_EQ(ps4_audio3d_port_open(0xFF, &p, &id), 0);
  return id;
}

static Ps4Audio3dAttribute attr(uint32_t id, const void *v, uint64_t size) {
  Ps4Audio3dAttribute a = {id, 0, (uint64_t)(uintptr_t)v, size};
  return a;
}

static void test_contract(void) {
  Ps4Audio3dOpenParameters p;
  uint32_t port = 7;
  CHECK_EQ(ps4_audio3d_get_default_open_parameters(&p), 0);
  CHECK_EQ(ps4_audio3d_port_open(0xFF, &p, &port), PS4_AUDIO3D_ERROR_NOT_READY);
  CHECK_EQ(port, 0xFFFFFFFFu);
  CHECK_EQ(ps4_audio3d_terminate(), PS4_AUDIO3D_ERROR_NOT_READY);
  CHECK_EQ(ps4_audio3d_initialize(1), PS4_AUDIO3D_ERROR_INVALID_PARAMETER);
  CHECK_EQ(ps4_audio3d_initialize(0), 0);
  CHECK_EQ(ps4_audio3d_initialize(0), PS4_AUDIO3D_ERROR_NOT_READY);

  // Defaults: size 0x20, granularity 0x100, 48 kHz, 512 objects, depth 2, ADVANCE_AND_PUSH.
  uint8_t raw[0x28];
  memset(raw, 0xAB, sizeof(raw));
  CHECK_EQ(ps4_audio3d_get_default_open_parameters(raw), 0);
  uint32_t w[6];
  memcpy(w, raw + 8, sizeof(w));
  CHECK(raw[0] == 0x20 && w[0] == 0x100 && w[1] == 0 && w[2] == 512 && w[3] == 2 && w[4] == 2);
  CHECK(raw[0x20] == 0xAB); // writes 0x20 bytes only
  CHECK_EQ(ps4_audio3d_get_default_open_parameters(NULL), PS4_AUDIO3D_ERROR_INVALID_PARAMETER);

  // Open parameter validation.
  struct {
    uint64_t size;
    uint32_t gran, rate, depth, mode;
  } bad[] = {{0x20, 0x80, 0, 2, 2},  {0x20, 0x180, 0, 2, 2}, {0x20, 0x100, 1, 2, 2},
             {0x30, 0x100, 0, 2, 2}, {0x20, 0x100, 0, 0x41, 2}, {0x20, 0x100, 0, 0, 2},
             {0x20, 0x100, 0, 2, 3}, {0x20, 0x1000, 0, 2, 2}};
  for (size_t i = 0; i < sizeof(bad) / sizeof(bad[0]); i++) {
    ps4_audio3d_get_default_open_parameters(&p);
    p.size_this = bad[i].size;
    p.granularity = bad[i].gran;
    p.rate = bad[i].rate;
    p.queue_depth = bad[i].depth;
    p.buffer_mode = bad[i].mode;
    CHECK_EQ(ps4_audio3d_port_open(0xFF, &p, &port), PS4_AUDIO3D_ERROR_INVALID_PARAMETER);
  }
  ps4_audio3d_get_default_open_parameters(&p);
  CHECK_EQ(ps4_audio3d_port_open(1, &p, &port), PS4_AUDIO3D_ERROR_INVALID_PARAMETER);
  CHECK_EQ(ps4_audio3d_port_open(0xFF, NULL, &port), PS4_AUDIO3D_ERROR_INVALID_PARAMETER);

  // Four ports, ids 0..3, then OUT_OF_RESOURCES.
  uint32_t ids[4];
  for (int i = 0; i < 4; i++) {
    CHECK_EQ(ps4_audio3d_port_open(0xFF, &p, &ids[i]), 0);
    CHECK_EQ(ids[i], (uint32_t)i);
  }
  CHECK_EQ(ps4_audio3d_port_open(0xFF, &p, &port), PS4_AUDIO3D_ERROR_OUT_OF_RESOURCES);
  for (int i = 0; i < 4; i++) CHECK_EQ(ps4_audio3d_port_close(ids[i]), 0);
  CHECK_EQ(ps4_audio3d_port_close(0), PS4_AUDIO3D_ERROR_INVALID_PORT);

  // Port attributes: the game's LATE_REVERB_LEVEL is accepted, bad values are not.
  port = open_port(256, 2, PS4_AUDIO3D_BUFFER_ADVANCE_AND_PUSH, 4);
  float lvl = 0.5f, neg = -1.0f;
  CHECK_EQ(ps4_audio3d_port_set_attribute(port, 0x10001, &lvl, 4), 0);
  CHECK_EQ(ps4_audio3d_port_set_attribute(port, 0x10001, &neg, 4), PS4_AUDIO3D_ERROR_INVALID_PARAMETER);
  CHECK_EQ(ps4_audio3d_port_set_attribute(port, 0x10001, &lvl, 8), PS4_AUDIO3D_ERROR_INVALID_PARAMETER);
  CHECK_EQ(ps4_audio3d_port_set_attribute(port, 0x10001, NULL, 4), PS4_AUDIO3D_ERROR_INVALID_PARAMETER);
  CHECK_EQ(ps4_audio3d_port_set_attribute(port, 0x1234, &lvl, 4), PS4_AUDIO3D_ERROR_INVALID_PARAMETER);
  CHECK_EQ(ps4_audio3d_port_set_attribute(3, 0x10001, &lvl, 4), PS4_AUDIO3D_ERROR_INVALID_PORT);

  // Supported attributes: POSITION yes, AMBISONICS no.
  uint32_t caps[0x20], n = 0x20;
  CHECK_EQ(ps4_audio3d_port_get_attributes_supported(port, NULL, &n), 0);
  CHECK_EQ(n, 7);
  n = 0x20;
  CHECK_EQ(ps4_audio3d_port_get_attributes_supported(port, caps, &n), 0);
  CHECK_EQ(n, 7);
  int has_pos = 0, has_amb = 0;
  for (uint32_t i = 0; i < n; i++) {
    has_pos |= caps[i] == PS4_AUDIO3D_ATTR_POSITION;
    has_amb |= caps[i] == PS4_AUDIO3D_ATTR_AMBISONICS;
  }
  CHECK(has_pos && !has_amb);
  n = 2;
  CHECK_EQ(ps4_audio3d_port_get_attributes_supported(port, caps, &n), 0);
  CHECK_EQ(n, 2);
  CHECK_EQ(ps4_audio3d_port_get_attributes_supported(port, caps, NULL), PS4_AUDIO3D_ERROR_INVALID_PARAMETER);
  CHECK_EQ(ps4_audio3d_port_get_attributes_supported(3, caps, &n), PS4_AUDIO3D_ERROR_INVALID_PORT);

  // Objects: unique ids, max_objects enforced.
  uint32_t obj[4], extra = 0;
  for (int i = 0; i < 4; i++) {
    CHECK_EQ(ps4_audio3d_object_reserve(port, &obj[i]), 0);
    CHECK(obj[i] != 0 && obj[i] != 0xFFFFFFFFu);
    for (int j = 0; j < i; j++) CHECK(obj[i] != obj[j]);
  }
  CHECK_EQ(ps4_audio3d_object_reserve(port, &extra), PS4_AUDIO3D_ERROR_OUT_OF_RESOURCES);
  CHECK_EQ(extra, 0xFFFFFFFFu);
  CHECK_EQ(ps4_audio3d_object_reserve(3, &extra), PS4_AUDIO3D_ERROR_INVALID_PORT);
  CHECK_EQ(ps4_audio3d_object_reserve(port, NULL), PS4_AUDIO3D_ERROR_INVALID_PARAMETER);

  // Attribute validation.
  static float pcm_buf[512];
  for (int i = 0; i < 512; i++) pcm_buf[i] = 0.1f;
  Ps4Audio3dPcm pcm = {PS4_AUDIO3D_FORMAT_FLOAT, 0, (uint64_t)(uintptr_t)pcm_buf, 256, 0};
  Ps4Audio3dPcm pcm_fmt = pcm, pcm_null = pcm, pcm_mis = pcm, pcm_zero = pcm, pcm_two = pcm;
  pcm_fmt.format = 2;
  pcm_null.sample_buffer = 0;
  pcm_mis.sample_buffer += 2;
  pcm_zero.num_samples = 0;
  pcm_two.num_samples = 512; // two grains
  float gain1 = 1.0f, gain_neg = -0.5f, gain_nan = NAN, pos[3] = {0, 0, 1}, pos_inf[3] = {INFINITY, 0, 0};
  uint32_t pass_bad = 3, amb_w = 0, amb_none = 0xFFFFFFFFu, prio = 1;
  struct {
    Ps4Audio3dAttribute a;
    int32_t want;
  } cases[] = {
      {attr(PS4_AUDIO3D_ATTR_GAIN, &gain1, 4), 0},
      {attr(PS4_AUDIO3D_ATTR_GAIN, &gain_neg, 4), PS4_AUDIO3D_ERROR_INVALID_PARAMETER},
      {attr(PS4_AUDIO3D_ATTR_GAIN, &gain_nan, 4), PS4_AUDIO3D_ERROR_INVALID_PARAMETER},
      {attr(PS4_AUDIO3D_ATTR_GAIN, &gain1, 8), PS4_AUDIO3D_ERROR_INVALID_PARAMETER},
      {attr(PS4_AUDIO3D_ATTR_GAIN, NULL, 4), PS4_AUDIO3D_ERROR_INVALID_PARAMETER},
      {attr(PS4_AUDIO3D_ATTR_POSITION, pos, 12), 0},
      {attr(PS4_AUDIO3D_ATTR_POSITION, pos, 8), PS4_AUDIO3D_ERROR_INVALID_PARAMETER},
      {attr(PS4_AUDIO3D_ATTR_POSITION, pos_inf, 12), PS4_AUDIO3D_ERROR_INVALID_PARAMETER},
      {attr(PS4_AUDIO3D_ATTR_PASSTHROUGH, &pass_bad, 4), PS4_AUDIO3D_ERROR_INVALID_PARAMETER},
      {attr(PS4_AUDIO3D_ATTR_PRIORITY, &prio, 4), 0},
      {attr(PS4_AUDIO3D_ATTR_AMBISONICS, &amb_none, 4), 0},
      {attr(PS4_AUDIO3D_ATTR_AMBISONICS, &amb_w, 4), PS4_AUDIO3D_ERROR_NOT_SUPPORTED},
      {attr(PS4_AUDIO3D_ATTR_RESET_STATE, NULL, 0), 0},
      {attr(PS4_AUDIO3D_ATTR_PCM, &pcm, 0x10), PS4_AUDIO3D_ERROR_INVALID_PARAMETER},
      {attr(PS4_AUDIO3D_ATTR_PCM, &pcm_fmt, 0x18), PS4_AUDIO3D_ERROR_INVALID_PARAMETER},
      {attr(PS4_AUDIO3D_ATTR_PCM, &pcm_null, 0x18), PS4_AUDIO3D_ERROR_INVALID_PARAMETER},
      {attr(PS4_AUDIO3D_ATTR_PCM, &pcm_mis, 0x18), PS4_AUDIO3D_ERROR_INVALID_PARAMETER},
      {attr(PS4_AUDIO3D_ATTR_PCM, &pcm_zero, 0x18), PS4_AUDIO3D_ERROR_INVALID_PARAMETER},
      {attr(99, &prio, 4), PS4_AUDIO3D_ERROR_INVALID_PARAMETER},
  };
  for (size_t i = 0; i < sizeof(cases) / sizeof(cases[0]); i++) {
    int32_t r = ps4_audio3d_object_set_attributes(port, obj[0], 1, &cases[i].a, 0);
    if (r != cases[i].want) {
      fprintf(stderr, "audio3d_test: attribute case %zu (id %u) -> 0x%x, want 0x%x\n", i,
              cases[i].a.attribute_id, (uint32_t)r, (uint32_t)cases[i].want);
      g_fail = 1;
    }
  }
  Ps4Audio3dAttribute ok = attr(PS4_AUDIO3D_ATTR_GAIN, &gain1, 4);
  CHECK_EQ(ps4_audio3d_object_set_attributes(port, obj[0], 0, &ok, 0), PS4_AUDIO3D_ERROR_INVALID_PARAMETER);
  CHECK_EQ(ps4_audio3d_object_set_attributes(port, obj[0], 1, NULL, 0), PS4_AUDIO3D_ERROR_INVALID_PARAMETER);
  CHECK_EQ(ps4_audio3d_object_set_attributes(port, 0x12345, 1, &ok, 0), PS4_AUDIO3D_ERROR_INVALID_OBJECT);
  CHECK_EQ(ps4_audio3d_object_set_attributes(3, obj[0], 1, &ok, 0), PS4_AUDIO3D_ERROR_INVALID_PORT);

  // A failing call applies nothing: PCM + bad GAIN queues no PCM, so a full queue_depth (2)
  // of PCM still fits afterwards, and one grain more does not.
  Ps4Audio3dAttribute mixed[2] = {attr(PS4_AUDIO3D_ATTR_PCM, &pcm, 0x18),
                                  attr(PS4_AUDIO3D_ATTR_GAIN, &gain_neg, 4)};
  CHECK_EQ(ps4_audio3d_object_set_attributes(port, obj[1], 2, mixed, 0), PS4_AUDIO3D_ERROR_INVALID_PARAMETER);
  Ps4Audio3dAttribute two = attr(PS4_AUDIO3D_ATTR_PCM, &pcm_two, 0x18);
  Ps4Audio3dAttribute one = attr(PS4_AUDIO3D_ATTR_PCM, &pcm, 0x18);
  CHECK_EQ(ps4_audio3d_object_set_attributes(port, obj[1], 1, &two, 0), 0);
  CHECK_EQ(ps4_audio3d_object_set_attributes(port, obj[1], 1, &one, 0), PS4_AUDIO3D_ERROR_NOT_READY);
  // PCM longer than the whole queue (queue_depth * granularity) is rejected outright; the grain
  // count must not wrap for lengths near UINT32_MAX.
  Ps4Audio3dPcm pcm_huge = pcm, pcm_long = pcm;
  pcm_huge.num_samples = 0xFFFFFFFFu;
  pcm_long.num_samples = 2 * 256 + 1;
  Ps4Audio3dAttribute huge = attr(PS4_AUDIO3D_ATTR_PCM, &pcm_huge, 0x18);
  Ps4Audio3dAttribute lng = attr(PS4_AUDIO3D_ATTR_PCM, &pcm_long, 0x18);
  Ps4Audio3dAttribute reset_only = attr(PS4_AUDIO3D_ATTR_RESET_STATE, NULL, 0);
  Ps4Audio3dAttribute reset_huge[2] = {reset_only, huge};
  CHECK_EQ(ps4_audio3d_object_set_attributes(port, obj[1], 2, reset_huge, 0), PS4_AUDIO3D_ERROR_INVALID_PARAMETER);
  Ps4Audio3dAttribute reset_long[2] = {reset_only, lng};
  CHECK_EQ(ps4_audio3d_object_set_attributes(port, obj[1], 2, reset_long, 0), PS4_AUDIO3D_ERROR_INVALID_PARAMETER);
  // RESET_STATE in the same call drops the queue first, so PCM fits again.
  Ps4Audio3dAttribute reset_pcm[2] = {one, attr(PS4_AUDIO3D_ATTR_RESET_STATE, NULL, 0)};
  CHECK_EQ(ps4_audio3d_object_set_attributes(port, obj[1], 2, reset_pcm, 0), 0);

  // Unreserve with queued PCM: the object is gone for the game at once, its slot is freed by the
  // advance that plays the last grain.
  CHECK_EQ(ps4_audio3d_object_unreserve(port, obj[1]), 0);
  CHECK_EQ(ps4_audio3d_object_unreserve(port, obj[1]), PS4_AUDIO3D_ERROR_INVALID_OBJECT);
  CHECK_EQ(ps4_audio3d_object_set_attributes(port, obj[1], 1, &ok, 0), PS4_AUDIO3D_ERROR_INVALID_OBJECT);
  CHECK_EQ(ps4_audio3d_object_reserve(port, &extra), PS4_AUDIO3D_ERROR_OUT_OF_RESOURCES);
  CHECK_EQ(ps4_audio3d_port_advance(port), 0);
  CHECK_EQ(ps4_audio3d_object_reserve(port, &extra), 0);
  CHECK(extra != obj[1]);
  CHECK_EQ(ps4_audio3d_object_unreserve(port, extra), 0);
  CHECK_EQ(ps4_audio3d_object_unreserve(port, 0xFFFFFFFFu), PS4_AUDIO3D_ERROR_INVALID_OBJECT);

  // Bed validation.
  CHECK_EQ(ps4_audio3d_bed_write(port, 3, 1, pcm_buf, 128), PS4_AUDIO3D_ERROR_INVALID_PARAMETER);
  CHECK_EQ(ps4_audio3d_bed_write(port, 2, 2, pcm_buf, 128), PS4_AUDIO3D_ERROR_INVALID_PARAMETER);
  CHECK_EQ(ps4_audio3d_bed_write(port, 2, 1, pcm_buf, 257), PS4_AUDIO3D_ERROR_INVALID_PARAMETER);
  CHECK_EQ(ps4_audio3d_bed_write(port, 2, 1, (uint8_t *)pcm_buf + 2, 128), PS4_AUDIO3D_ERROR_INVALID_PARAMETER);
  CHECK_EQ(ps4_audio3d_bed_write(3, 2, 1, pcm_buf, 128), PS4_AUDIO3D_ERROR_INVALID_PORT);
  CHECK_EQ(ps4_audio3d_port_close(port), 0);
}

static void test_pacing(void) {
  uint32_t port = open_port(256, 2, PS4_AUDIO3D_BUFFER_ADVANCE_AND_PUSH, 8);
  uint32_t level = 9, avail = 9;
  CHECK_EQ(ps4_audio3d_port_get_queue_level(port, &level, &avail), 0);
  CHECK(level == 0 && avail == 2);
  CHECK_EQ(ps4_audio3d_port_get_queue_level(port, NULL, NULL), PS4_AUDIO3D_ERROR_INVALID_PARAMETER);
  CHECK_EQ(ps4_audio3d_port_get_queue_level(3, &level, NULL), PS4_AUDIO3D_ERROR_INVALID_PORT);
  CHECK_EQ(ps4_audio3d_port_advance(port), 0);
  ps4_audio3d_port_get_queue_level(port, &level, &avail);
  CHECK(level == 1 && avail == 1);
  CHECK_EQ(ps4_audio3d_port_advance(port), 0);
  ps4_audio3d_port_get_queue_level(port, &level, &avail);
  CHECK(level == 2 && avail == 0);
  CHECK_EQ(ps4_audio3d_port_advance(port), PS4_AUDIO3D_ERROR_NOT_READY);
  CHECK_EQ(ps4_audio3d_port_push(port, 2), PS4_AUDIO3D_ERROR_INVALID_PARAMETER);

  // ASYNC submits what the AudioOut ring takes without blocking (its limit is 2 grains + 1024
  // frames = 6 grains of 256), so the first pushes empty the queue at once...
  CHECK_EQ(ps4_audio3d_port_push(port, PS4_AUDIO3D_BLOCKING_ASYNC), 0);
  ps4_audio3d_port_get_queue_level(port, &level, NULL);
  CHECK_EQ(level, 0);
  // ...and once the ring is full it returns at once with the grains still queued.
  int saw_full = 0;
  for (int i = 0; i < 20 && !saw_full; i++) {
    ps4_audio3d_port_advance(port);
    double t0 = now_s();
    CHECK_EQ(ps4_audio3d_port_push(port, PS4_AUDIO3D_BLOCKING_ASYNC), 0);
    double dt = now_s() - t0;
    ps4_audio3d_port_get_queue_level(port, &level, NULL);
    if (level > 0) {
      // Returned with the grain still queued instead of waiting for the device (a blocking
      // submission would take ~5 ms per grain and leave the queue empty); the time bound only
      // catches gross blocking and leaves room for a loaded machine.
      saw_full = 1;
      CHECK(dt < 0.020);
    }
  }
  CHECK(saw_full);

  // SYNC is paced by the device clock: 375 grains of 256 frames are 2.0 s of audio. It can't
  // be faster (minus the ~32 ms the AudioOut ring holds); it may be slower on a loaded machine,
  // where the headless device resynchronises after stalls instead of catching up.
  ps4_audio3d_port_push(port, PS4_AUDIO3D_BLOCKING_SYNC);
  double t0 = now_s();
  for (int i = 0; i < 375; i++) {
    CHECK_EQ(ps4_audio3d_port_advance(port), 0);
    CHECK_EQ(ps4_audio3d_port_push(port, PS4_AUDIO3D_BLOCKING_SYNC), 0);
  }
  double dt = now_s() - t0;
  ps4_audio3d_port_get_queue_level(port, &level, &avail);
  CHECK(level == 0 && avail == 2);
  fprintf(stderr, "audio3d_test: 375 SYNC grains took %.3f s (2.000 s of audio)\n", dt);
  CHECK(dt > 1.90 && dt < 2.60);

  // Associated AudioOut ports: grain length must be the port granularity; their grains queue
  // up to queue_depth and are drained by the next push.
  CHECK_EQ(ps4_audio3d_audioout_open(port, 0xFF, 0, 0, 512, 48000, PS4_AUDIO_OUT_FMT_FLOAT_STEREO),
           PS4_AUDIO3D_ERROR_INVALID_PARAMETER);
  CHECK_EQ(ps4_audio3d_audioout_open(3, 0xFF, 0, 0, 256, 48000, PS4_AUDIO_OUT_FMT_FLOAT_STEREO),
           PS4_AUDIO3D_ERROR_INVALID_PORT);
  int32_t h = ps4_audio3d_audioout_open(port, 0xFF, 0, 0, 256, 48000, PS4_AUDIO_OUT_FMT_FLOAT_STEREO);
  CHECK(h > 0);
  static float st[256 * 2];
  Ps4Audio3dAudioOutParam op = {h, 0, (uint64_t)(uintptr_t)st};
  Ps4Audio3dAudioOutParam bad = {h + 1000, 0, (uint64_t)(uintptr_t)st};
  Ps4Audio3dAudioOutParam mis = {h, 0, (uint64_t)(uintptr_t)st + 2};
  CHECK_EQ(ps4_audio3d_audioout_outputs(&bad, 1, 0), PS4_AUDIO3D_ERROR_INVALID_PORT);
  CHECK_EQ(ps4_audio3d_audioout_outputs(&mis, 1, 0), PS4_AUDIO3D_ERROR_INVALID_PARAMETER);
  CHECK_EQ(ps4_audio3d_audioout_outputs(NULL, 1, 0), PS4_AUDIO3D_ERROR_INVALID_PARAMETER);
  // The same handle repeated in one call counts once per entry: three grains for a depth-2
  // queue are refused as a whole, and nothing is queued.
  Ps4Audio3dAudioOutParam rep3[3] = {op, op, op};
  CHECK_EQ(ps4_audio3d_audioout_outputs(rep3, 3, 0), PS4_AUDIO3D_ERROR_NOT_READY);
  Ps4Audio3dAudioOutParam rep2[2] = {op, op};
  CHECK_EQ(ps4_audio3d_audioout_outputs(rep2, 2, 0), 0);
  CHECK_EQ(ps4_audio3d_audioout_outputs(&op, 1, 0), PS4_AUDIO3D_ERROR_NOT_READY);
  CHECK_EQ(ps4_audio3d_port_push(port, PS4_AUDIO3D_BLOCKING_SYNC), 0);
  CHECK_EQ(ps4_audio3d_audioout_outputs(&op, 1, 0), 0);
  CHECK_EQ(ps4_audio3d_audioout_outputs(&op, 1, 0), 0);
  CHECK_EQ(ps4_audio3d_audioout_outputs(&op, 1, 0), PS4_AUDIO3D_ERROR_NOT_READY);
  CHECK_EQ(ps4_audio3d_port_push(port, PS4_AUDIO3D_BLOCKING_SYNC), 0);
  CHECK_EQ(ps4_audio3d_audioout_outputs(&op, 1, 0), 0);
  CHECK_EQ(ps4_audio3d_audioout_close(h + 1000), PS4_AUDIO3D_ERROR_INVALID_PORT);
  CHECK_EQ(ps4_audio3d_audioout_close(h), 0);
  CHECK_EQ(ps4_audio3d_audioout_close(h), PS4_AUDIO3D_ERROR_INVALID_PORT);
  CHECK_EQ(ps4_audio3d_port_close(port), 0);

  // Other buffer modes.
  uint32_t nopush = open_port(256, 2, PS4_AUDIO3D_BUFFER_ADVANCE_NO_PUSH, 8);
  CHECK_EQ(ps4_audio3d_port_push(nopush, PS4_AUDIO3D_BLOCKING_SYNC), PS4_AUDIO3D_ERROR_NOT_SUPPORTED);
  CHECK_EQ(ps4_audio3d_port_advance(nopush), 0); // advances and submits
  ps4_audio3d_port_get_queue_level(nopush, &level, NULL);
  CHECK_EQ(level, 0);
  CHECK_EQ(ps4_audio3d_port_close(nopush), 0);
  Ps4Audio3dOpenParameters p;
  ps4_audio3d_get_default_open_parameters(&p);
  p.size_this = 0x10; // implies NO_ADVANCE
  CHECK_EQ(ps4_audio3d_port_open(0xFF, &p, &port), 0);
  CHECK_EQ(ps4_audio3d_port_advance(port), PS4_AUDIO3D_ERROR_NOT_SUPPORTED);
  CHECK_EQ(ps4_audio3d_port_push(port, PS4_AUDIO3D_BLOCKING_SYNC), PS4_AUDIO3D_ERROR_NOT_SUPPORTED);
  CHECK_EQ(ps4_audio3d_port_close(port), 0);
}

// A stereo bed (L = 0.25) and one object (0.5, gain 1, hard right) through PortAdvance /
// PortPush, AudioOut's 7.1 -> stereo fold and the headless device: every played frame must be
// (0.25, 0.7071 * 0.5). Constant signals make the check independent of where the device period
// boundaries fall.
static void test_bed_plus_object(const char *dump) {
  const uint32_t gran = 256, ticks = 120;
  uint32_t port = open_port(gran, 2, PS4_AUDIO3D_BUFFER_ADVANCE_AND_PUSH, 4);
  uint32_t obj;
  CHECK_EQ(ps4_audio3d_object_reserve(port, &obj), 0);
  static float bed[256 * 2], mono[256];
  for (uint32_t i = 0; i < gran; i++) {
    bed[i * 2] = 0.25f;
    bed[i * 2 + 1] = 0.0f;
    mono[i] = 0.5f;
  }
  float gain = 1.0f, pos[3] = {2.0f, 0.0f, 0.0f};
  Ps4Audio3dPcm pcm = {PS4_AUDIO3D_FORMAT_FLOAT, 0, (uint64_t)(uintptr_t)mono, gran, 0};
  Ps4Audio3dAttribute a[3] = {attr(PS4_AUDIO3D_ATTR_POSITION, pos, 12),
                              attr(PS4_AUDIO3D_ATTR_GAIN, &gain, 4),
                              attr(PS4_AUDIO3D_ATTR_PCM, &pcm, 0x18)};
  for (uint32_t t = 0; t < ticks; t++) {
    CHECK_EQ(ps4_audio3d_bed_write(port, 2, PS4_AUDIO3D_FORMAT_FLOAT, bed, gran), 0);
    CHECK_EQ(ps4_audio3d_object_set_attributes(port, obj, 3, a, 0), 0);
    CHECK_EQ(ps4_audio3d_port_advance(port), 0);
    CHECK_EQ(ps4_audio3d_port_push(port, PS4_AUDIO3D_BLOCKING_SYNC), 0);
  }
  usleep(1300 * 1000); // play out, then the dump header is rewritten (once per second of audio)
  CHECK_EQ(ps4_audio3d_port_close(port), 0);

  FILE *f = fopen(dump, "rb");
  CHECK(f != NULL);
  if (!f) return;
  fseek(f, 44, SEEK_SET);
  float fr[2];
  const float want_l = 0.25f, want_r = 0.7071f * 0.5f;
  uint64_t match = 0, silent = 0, other = 0;
  while (fread(fr, sizeof(float), 2, f) == 2) {
    if (fr[0] == 0.0f && fr[1] == 0.0f) silent++;
    else if (NEAR(fr[0], want_l) && NEAR(fr[1], want_r)) match++;
    else other++;
  }
  fclose(f);
  fprintf(stderr, "audio3d_test: dump frames: %llu bed+object, %llu silent, %llu other\n",
          (unsigned long long)match, (unsigned long long)silent, (unsigned long long)other);
  // Every pushed frame is played once; AudioOut drops audio only when its device stops for
  // 250 ms, which a heavily loaded machine can cause, hence the 90% floor. Wrong samples are
  // never acceptable.
  CHECK(match >= (uint64_t)ticks * gran * 9 / 10 && match <= (uint64_t)ticks * gran);
  CHECK_EQ(other, 0);
}

int main(void) {
  char dump[] = "/tmp/audio3d_test_XXXXXX";
  int fd = mkstemp(dump);
  if (fd < 0) return 1;
  close(fd);
  setenv("PS4_AUDIO_NULL", "1", 1);
  setenv("PS4_AUDIO_DUMP", dump, 1);
  unsetenv("PS4_AUDIO_MUTE");
  test_panner();
  test_contract();
  test_pacing();
  test_bed_plus_object(dump);
  CHECK_EQ(ps4_audio3d_terminate(), 0);
  CHECK_EQ(ps4_audio3d_terminate(), PS4_AUDIO3D_ERROR_NOT_READY);
  CHECK_EQ(ps4_audio3d_port_advance(0), PS4_AUDIO3D_ERROR_INVALID_PORT);
  unlink(dump);
  if (g_fail) {
    fprintf(stderr, "audio3d_test: FAIL\n");
    return 1;
  }
  fprintf(stderr, "audio3d_test: PASS\n");
  return 0;
}
