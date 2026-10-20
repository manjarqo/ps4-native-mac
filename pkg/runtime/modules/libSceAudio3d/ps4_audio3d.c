// libSceAudio3d HLE: ports, objects, beds and their mix onto libSceAudioOut.
//
// Port parameter validation, the object id scheme, the error codes and the
// AudioOut-association model follow shadPS4's src/core/libraries/audio3d/
// audio3d.{h,cpp} and audio3d_error.h (Copyright 2024-2026 shadPS4 Emulator
// Project, GPL-2.0-or-later). The attribute ids and the layouts of the guest
// structures were checked against Uncharted 4's call sites (eboot
// 0x15d930-0x15f330, "brbDriverBase::Initialize3D/Pump3D"); shadPS4 numbers the
// attributes differently (its GAIN = 3 is POSITION in the game's calls).
//
// ---------------------------------------------------------------- contract
// [V] = verified at the Uncharted 4 call sites, [S] = from shadPS4,
// [I] = inferred (SDK naming / behaviour, not verifiable without a console).
//
// Structures (x86-64 SysV):
//   SceAudio3dOpenParameters [V offsets 0..0x18, size_this 0x20]
//     +0x00 u64 size_this   (0x10 / 0x18 / 0x20 / 0x28, low 3 bits ignored [S])
//     +0x08 u32 granularity (frames per grain; >= 0x100, multiple of 0x100 [S],
//                            <= 2048 here: the AudioOut grain limit)
//     +0x0c u32 rate        (0 = 48 kHz, the only rate)
//     +0x10 u32 max_objects (clamped to 512 [S])
//     +0x14 u32 queue_depth (mixed grains a port can hold)
//     +0x18 u32 buffer_mode (0 NO_ADVANCE, 1 ADVANCE_NO_PUSH, 2 ADVANCE_AND_PUSH)
//     +0x20 u32 num_beds    (size_this 0x28 only; must be 2 or 3 [S])
//     Older sizes imply defaults: 0x10 -> 512 objects, depth 2, NO_ADVANCE;
//     0x18 -> ADVANCE_NO_PUSH [S].
//   SceAudio3dAttribute [V] { +0 u32 attribute_id; +8 void *value; +0x10 u64 value_size } (0x18)
//   SceAudio3dPcm [V] { +0 u32 format (0 S16, 1 FLOAT); +8 void *sample_buffer;
//                       +0x10 u32 num_samples } (0x18); mono samples.
//   SceAudioOutOutputParam [V] { +0 s32 handle; +8 void *ptr } (0x10)
//
// Object attributes [V ids and sizes from the game, I semantics]:
//   1 PCM (0x18 struct)        mono grain(s) queued on the object; longer than
//                              a grain is split, longer than queue_depth grains
//                              INVALID_PARAMETER, no room NOT_READY
//   2 PRIORITY (u32)           stored; every object is mixed, so unused
//   3 POSITION (3 x float)     x right, y up, z forward [I axes]
//   4 SPREAD (float)           angular width in radians [I unit]
//   5 GAIN (float)             linear, >= 0; default 0 = silent [S]
//   6 PASSTHROUGH (u32)        0 none, 1 left, 2 right: straight to FL / FR
//   7 RESET_STATE (no value)   drops queued PCM, restores default attributes;
//                              applied before the other attributes of the call
//   8 APPLICATION_SPECIFIC     opaque, accepted and ignored (no consumer)
//   9 AMBISONICS (u32)         only NONE (0xFFFFFFFF) accepted; other values
//                              NOT_SUPPORTED (not advertised by
//                              PortGetAttributesSupported, so the game keeps
//                              its non-ambisonic path)
//   10 RESTRICTED, 11 OUTPUT_ROUTE (u32) stored; there is one output
// Port attributes: 0x10001 LATE_REVERB_LEVEL (float >= 0) [V id: the game
//   fails Initialize3D if it is rejected], 0x10002 DOWNMIX_SPREAD_RADIUS
//   (float), 0x10003 DOWNMIX_SPREAD_HEIGHT_AWARE (u32) [I]: stored; the mixer
//   renders no reverb.
//
// Call order used by the game [V]: Initialize(0) -> GetDefaultOpenParameters
//   -> PortOpen(0xFF, {0x20, gran, 0, N, 2, ADVANCE_AND_PUSH}) ->
//   PortSetAttribute(0x10001, float) -> ObjectReserve x (2 passthrough
//   + optional 8 ambisonic + N) -> AudioOutOpen(port, 0xFF, type, 0, len,
//   freq, param) [7th argument on the stack] for its plain AudioOut buses;
//   per tick: ObjectSetAttributes (dynamic objects: POSITION, SPREAD, GAIN,
//   PRIORITY, PASSTHROUGH, PCM [+ RESET_STATE]; passthrough objects: GAIN,
//   PRIORITY, PASSTHROUGH 1/2, PCM) -> AudioOutOutputs -> PortAdvance ->
//   PortPush(SYNC); every third tick PortGetAttributesSupported (looks for
//   POSITION and AMBISONICS). Shutdown: AudioOutClose, ObjectUnreserve,
//   PortClose, Terminate.
//
// Pacing [I, consistent with the game's loop]: PortAdvance mixes one grain
//   (bed + every object with queued PCM) into the port queue; NOT_READY when
//   queue_depth grains are waiting. PortPush first submits the grains queued
//   on the associated AudioOut ports, then the mixed grains to the port's own
//   AudioOut port (type 126, FLOAT_8CH_STD, opened on first push). SYNC
//   submits everything, each submission blocking on the AudioOut ring (device
//   clock); ASYNC submits only what AudioOut accepts without blocking.
//   No lock is held while blocked: PortClose / Terminate close the AudioOut
//   ports (waking the submission), wait for it to leave, and the push returns
//   INVALID_PORT.
//   GetQueueLevel reports the waiting mixed grains and the free slots. In
//   ADVANCE_NO_PUSH mode Advance submits like a SYNC push; NO_ADVANCE (the
//   library advancing by itself) is not implemented: Advance/Push return
//   NOT_SUPPORTED [S].
//
// Return codes [S]: INVALID_PORT for unknown ports / handles, INVALID_OBJECT
//   for unknown or unreserved objects [I: shadPS4 returns OK for unknown ids],
//   INVALID_PARAMETER for bad arguments, OUT_OF_RESOURCES for no free port /
//   object, NOT_READY for full queues, uninitialised library and double
//   Initialize, NOT_SUPPORTED as above. A failing ObjectSetAttributes applies
//   nothing (all attributes are validated first) [I].
//
// Mixing: see ps4_audio3d_mix.c (pairwise constant-power 7.1 panner). The
//   port mixes in 7.1; libSceAudioOut folds it to the stereo host device.
//
// Debug: PS4_AUDIO_LOG=1 logs per-port statistics every ~2 s.

#include "ps4_audio3d.h"
#include "ps4_audio3d_mix.h"
#include "ps4_audioout_internal.h"
#include <math.h>
#include <pthread.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#define A3D_MAX_PORTS 4u
#define A3D_MAX_OBJECTS 512u
#define A3D_SLOT_BITS 9u
#define A3D_MAX_ASSOC 32u
#define A3D_OUT_CH 8u
#define A3D_MAX_GRANULARITY 2048u
#define A3D_OBJECT_INVALID 0xFFFFFFFFu
#define A3D_PORT_INVALID 0xFFFFFFFFu

typedef struct {
  uint32_t id; // 0 = free slot
  bool unreserved;
  Ps4A3dPanParams pan;
  uint32_t priority;
  uint32_t restricted;
  uint32_t output_route;
  float *pcm; // queue_depth grains of granularity mono samples
  uint32_t pcm_read, pcm_count;
} A3dObject;

typedef struct {
  int32_t handle; // 0 = free
  uint32_t bytes; // one grain
  bool is_float;
  uint8_t *pending; // queue_depth grains
  uint32_t pend_read, pend_count;
} A3dAssoc;

typedef struct {
  bool open;
  uint32_t gen; // changes on every open, detects close during a blocking push
  uint32_t granularity, max_objects, queue_depth, buffer_mode, num_beds;
  float late_reverb_level, downmix_spread_radius;
  uint32_t downmix_height_aware;
  A3dObject *objects; // max_objects slots
  uint32_t object_count;
  uint32_t next_id_gen;
  float *bed; // queue_depth grains in the output layout
  uint32_t bed_read, bed_count;
  float *mixed; // queue_depth grains in the output layout
  uint32_t mix_read, mix_count;
  int32_t out_handle; // -1 until the first push
  A3dAssoc assoc[A3D_MAX_ASSOC];
  uint32_t pushing; // threads inside a submission with the lock released
  // statistics (PS4_AUDIO_LOG)
  uint64_t advances, pushes, grains_out, obj_grains;
  double out_sq;
  float out_peak;
  uint64_t out_frames;
  uint64_t last_log_us;
} A3dPort;

static pthread_mutex_t g_lock = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t g_cond = PTHREAD_COND_INITIALIZER;
static bool g_initialized;
static uint32_t g_gen;
static A3dPort g_ports[A3D_MAX_PORTS];
static int g_log = -1;

static bool a3d_log(void) {
  if (g_log < 0) {
    const char *e = getenv("PS4_AUDIO_LOG");
    g_log = (e && *e && strcmp(e, "0") != 0) ? 1 : 0;
  }
  return g_log == 1;
}

static uint64_t now_us(void) {
  struct timespec ts;
  clock_gettime(CLOCK_MONOTONIC, &ts);
  return (uint64_t)ts.tv_sec * 1000000ULL + (uint64_t)ts.tv_nsec / 1000ULL;
}

static A3dPort *port_get(uint32_t id) {
  if (!g_initialized || id >= A3D_MAX_PORTS || !g_ports[id].open) {
    return NULL;
  }
  return &g_ports[id];
}

static A3dObject *object_get(A3dPort *p, uint32_t id) {
  if (id == 0 || id == A3D_OBJECT_INVALID) return NULL;
  uint32_t slot = id & ((1u << A3D_SLOT_BITS) - 1);
  if (slot >= p->max_objects || p->objects[slot].id != id) return NULL;
  return &p->objects[slot];
}

static void object_defaults(A3dObject *o) {
  memset(&o->pan, 0, sizeof(o->pan));
  o->pan.gain = 0.0f; // shadPS4: objects without GAIN are silent
  o->priority = 0;
  o->restricted = 0;
  o->output_route = 0;
  o->pcm_read = 0;
  o->pcm_count = 0;
}

static size_t grain_floats(const A3dPort *p) { return (size_t)p->granularity * A3D_OUT_CH; }

static void port_free(A3dPort *p) {
  if (p->objects) {
    for (uint32_t i = 0; i < p->max_objects; i++) free(p->objects[i].pcm);
  }
  free(p->objects);
  free(p->bed);
  free(p->mixed);
  for (uint32_t i = 0; i < A3D_MAX_ASSOC; i++) free(p->assoc[i].pending);
  memset(p, 0, sizeof(*p));
  p->out_handle = -1;
}

static void port_stats_maybe_log(uint32_t id, A3dPort *p) {
  if (!a3d_log()) return;
  uint64_t t = now_us();
  if (p->last_log_us == 0) {
    p->last_log_us = t;
    return;
  }
  if (t - p->last_log_us < 2000000ULL) return;
  p->last_log_us = t;
  uint32_t active = 0;
  for (uint32_t i = 0; i < p->max_objects; i++) active += p->objects[i].id != 0;
  double rms = p->out_frames ? sqrt(p->out_sq / ((double)p->out_frames * A3D_OUT_CH)) : 0.0;
  fprintf(stderr,
          "[Audio3d] port %u: advances=%llu pushes=%llu grains_out=%llu objects=%u "
          "object_grains=%llu mix_rms=%.5f mix_peak=%.5f queue=%u/%u\n",
          id, (unsigned long long)p->advances, (unsigned long long)p->pushes,
          (unsigned long long)p->grains_out, active, (unsigned long long)p->obj_grains, rms,
          p->out_peak, p->mix_count, p->queue_depth);
  p->out_sq = 0.0;
  p->out_peak = 0.0f;
  p->out_frames = 0;
  p->obj_grains = 0;
}

// ---------------------------------------------------------------- library

int32_t ps4_audio3d_initialize(int64_t reserved) {
  if (reserved != 0) return PS4_AUDIO3D_ERROR_INVALID_PARAMETER;
  pthread_mutex_lock(&g_lock);
  if (g_initialized) {
    pthread_mutex_unlock(&g_lock);
    return PS4_AUDIO3D_ERROR_NOT_READY;
  }
  g_initialized = true;
  for (uint32_t i = 0; i < A3D_MAX_PORTS; i++) {
    memset(&g_ports[i], 0, sizeof(g_ports[i]));
    g_ports[i].out_handle = -1;
  }
  pthread_mutex_unlock(&g_lock);
  fprintf(stderr, "[Audio3d] initialized\n");
  return 0;
}

int32_t ps4_audio3d_get_default_open_parameters(void *params) {
  if (!params) return PS4_AUDIO3D_ERROR_INVALID_PARAMETER;
  Ps4Audio3dOpenParameters d;
  memset(&d, 0, sizeof(d));
  d.size_this = 0x20;
  d.granularity = 0x100;
  d.rate = 0;
  d.max_objects = 512;
  d.queue_depth = 2;
  d.buffer_mode = PS4_AUDIO3D_BUFFER_ADVANCE_AND_PUSH;
  memcpy(params, &d, 0x20);
  return 0;
}

// ---------------------------------------------------------------- ports

int32_t ps4_audio3d_port_open(int32_t user_id, const void *params, uint32_t *port_id) {
  if (port_id) *port_id = A3D_PORT_INVALID;
  if (user_id != 0xFF || !params || !port_id) return PS4_AUDIO3D_ERROR_INVALID_PARAMETER;
  Ps4Audio3dOpenParameters in;
  memset(&in, 0, sizeof(in));
  memcpy(&in, params, 0x10);
  uint64_t size = in.size_this & ~7ull;
  if (size >= 0x18) memcpy((uint8_t *)&in + 0x10, (const uint8_t *)params + 0x10, 8);
  if (size >= 0x20) memcpy((uint8_t *)&in + 0x18, (const uint8_t *)params + 0x18, 8);
  if (size >= 0x28) memcpy((uint8_t *)&in + 0x20, (const uint8_t *)params + 0x20, 4);

  uint32_t gran = in.granularity, max_obj = 512, depth = 2, mode = PS4_AUDIO3D_BUFFER_NO_ADVANCE,
           beds = 2;
  switch (size) {
  case 0x10: break;
  case 0x18: max_obj = in.max_objects; depth = in.queue_depth; mode = PS4_AUDIO3D_BUFFER_ADVANCE_NO_PUSH; break;
  case 0x20: max_obj = in.max_objects; depth = in.queue_depth; mode = in.buffer_mode; break;
  case 0x28: max_obj = in.max_objects; depth = in.queue_depth; mode = in.buffer_mode; beds = in.num_beds; break;
  default: return PS4_AUDIO3D_ERROR_INVALID_PARAMETER;
  }
  if (in.rate != 0 || gran < 0x100 || (gran & 0xFF) != 0 || gran > A3D_MAX_GRANULARITY ||
      max_obj == 0 || depth == 0 || (gran == 0x100 && depth > 0x40) ||
      (gran == 0x200 && depth > 0x1F) || (gran == 0x300 && depth > 0x14) ||
      (gran > 0x3FF && depth > 0xF) || mode > PS4_AUDIO3D_BUFFER_ADVANCE_AND_PUSH ||
      (beds & ~1u) != 2) {
    return PS4_AUDIO3D_ERROR_INVALID_PARAMETER;
  }
  if (max_obj > A3D_MAX_OBJECTS) max_obj = A3D_MAX_OBJECTS;

  pthread_mutex_lock(&g_lock);
  if (!g_initialized) {
    pthread_mutex_unlock(&g_lock);
    return PS4_AUDIO3D_ERROR_NOT_READY;
  }
  uint32_t id = A3D_PORT_INVALID;
  for (uint32_t i = 0; i < A3D_MAX_PORTS; i++) {
    // A port being closed still has threads leaving a push: not reusable yet.
    if (!g_ports[i].open && g_ports[i].pushing == 0) {
      id = i;
      break;
    }
  }
  if (id == A3D_PORT_INVALID) {
    pthread_mutex_unlock(&g_lock);
    return PS4_AUDIO3D_ERROR_OUT_OF_RESOURCES;
  }
  A3dPort *p = &g_ports[id];
  memset(p, 0, sizeof(*p));
  p->granularity = gran;
  p->max_objects = max_obj;
  p->queue_depth = depth;
  p->buffer_mode = mode;
  p->num_beds = beds;
  p->out_handle = -1;
  p->objects = (A3dObject *)calloc(max_obj, sizeof(A3dObject));
  p->bed = (float *)calloc((size_t)depth * grain_floats(p), sizeof(float));
  p->mixed = (float *)calloc((size_t)depth * grain_floats(p), sizeof(float));
  if (!p->objects || !p->bed || !p->mixed) {
    port_free(p);
    pthread_mutex_unlock(&g_lock);
    return PS4_AUDIO3D_ERROR_OUT_OF_MEMORY;
  }
  p->gen = ++g_gen;
  p->open = true;
  *port_id = id;
  pthread_mutex_unlock(&g_lock);
  fprintf(stderr,
          "[Audio3d] port %u open: granularity=%u max_objects=%u queue_depth=%u buffer_mode=%u "
          "num_beds=%u\n",
          id, gran, max_obj, depth, mode, beds);
  return 0;
}

// Lock held; closes the AudioOut ports, waits for blocked pushes, frees.
static void port_close_locked(uint32_t id, A3dPort *p) {
  p->open = false;
  if (p->out_handle >= 0) ps4_audioout_port_close(p->out_handle);
  p->out_handle = -1;
  for (uint32_t i = 0; i < A3D_MAX_ASSOC; i++) {
    if (p->assoc[i].handle > 0) ps4_audioout_port_close(p->assoc[i].handle);
    p->assoc[i].handle = 0;
  }
  // Closing the AudioOut ports wakes submissions blocked on them.
  while (p->pushing > 0) pthread_cond_wait(&g_cond, &g_lock);
  port_free(p);
  fprintf(stderr, "[Audio3d] port %u closed\n", id);
}

int32_t ps4_audio3d_port_close(uint32_t port_id) {
  pthread_mutex_lock(&g_lock);
  A3dPort *p = port_get(port_id);
  if (!p) {
    pthread_mutex_unlock(&g_lock);
    return PS4_AUDIO3D_ERROR_INVALID_PORT;
  }
  port_close_locked(port_id, p);
  pthread_mutex_unlock(&g_lock);
  return 0;
}

int32_t ps4_audio3d_terminate(void) {
  pthread_mutex_lock(&g_lock);
  if (!g_initialized) {
    pthread_mutex_unlock(&g_lock);
    return PS4_AUDIO3D_ERROR_NOT_READY;
  }
  for (uint32_t i = 0; i < A3D_MAX_PORTS; i++) {
    if (g_ports[i].open) port_close_locked(i, &g_ports[i]);
  }
  g_initialized = false;
  pthread_mutex_unlock(&g_lock);
  fprintf(stderr, "[Audio3d] terminated\n");
  return 0;
}

static bool finite_nonneg(float v) { return isfinite(v) && v >= 0.0f; }

int32_t ps4_audio3d_port_set_attribute(uint32_t port_id, uint32_t attribute_id, const void *value,
                                       uint64_t size) {
  pthread_mutex_lock(&g_lock);
  A3dPort *p = port_get(port_id);
  int32_t r = 0;
  if (!p) {
    r = PS4_AUDIO3D_ERROR_INVALID_PORT;
  } else if (!value || size != 4) {
    r = PS4_AUDIO3D_ERROR_INVALID_PARAMETER;
  } else {
    float f;
    uint32_t u;
    memcpy(&f, value, 4);
    memcpy(&u, value, 4);
    switch (attribute_id) {
    case PS4_AUDIO3D_PORT_ATTR_LATE_REVERB_LEVEL:
      if (finite_nonneg(f)) p->late_reverb_level = f;
      else r = PS4_AUDIO3D_ERROR_INVALID_PARAMETER;
      break;
    case PS4_AUDIO3D_PORT_ATTR_DOWNMIX_SPREAD_RADIUS:
      if (finite_nonneg(f)) p->downmix_spread_radius = f;
      else r = PS4_AUDIO3D_ERROR_INVALID_PARAMETER;
      break;
    case PS4_AUDIO3D_PORT_ATTR_DOWNMIX_SPREAD_HEIGHT_AWARE:
      p->downmix_height_aware = u;
      break;
    default:
      r = PS4_AUDIO3D_ERROR_INVALID_PARAMETER;
      break;
    }
  }
  pthread_mutex_unlock(&g_lock);
  if (a3d_log()) {
    fprintf(stderr, "[Audio3d] PortSetAttribute(port %u, 0x%x, size %llu) -> 0x%x\n", port_id,
            attribute_id, (unsigned long long)size, (uint32_t)r);
  }
  return r;
}

// Attributes the mixer renders or honours.
static const uint32_t k_caps[] = {
    PS4_AUDIO3D_ATTR_PCM,        PS4_AUDIO3D_ATTR_PRIORITY,    PS4_AUDIO3D_ATTR_POSITION,
    PS4_AUDIO3D_ATTR_SPREAD,     PS4_AUDIO3D_ATTR_GAIN,        PS4_AUDIO3D_ATTR_PASSTHROUGH,
    PS4_AUDIO3D_ATTR_RESET_STATE,
};
#define A3D_NUM_CAPS ((uint32_t)(sizeof(k_caps) / sizeof(k_caps[0])))

int32_t ps4_audio3d_port_get_attributes_supported(uint32_t port_id, uint32_t *caps, uint32_t *num) {
  if (!num) return PS4_AUDIO3D_ERROR_INVALID_PARAMETER;
  pthread_mutex_lock(&g_lock);
  A3dPort *p = port_get(port_id);
  pthread_mutex_unlock(&g_lock);
  if (!p) return PS4_AUDIO3D_ERROR_INVALID_PORT;
  if (!caps) {
    *num = A3D_NUM_CAPS;
    return 0;
  }
  uint32_t n = *num < A3D_NUM_CAPS ? *num : A3D_NUM_CAPS;
  memcpy(caps, k_caps, n * sizeof(uint32_t));
  *num = n;
  return 0;
}

int32_t ps4_audio3d_port_get_queue_level(uint32_t port_id, uint32_t *level, uint32_t *available) {
  if (!level && !available) return PS4_AUDIO3D_ERROR_INVALID_PARAMETER;
  pthread_mutex_lock(&g_lock);
  A3dPort *p = port_get(port_id);
  if (!p) {
    pthread_mutex_unlock(&g_lock);
    return PS4_AUDIO3D_ERROR_INVALID_PORT;
  }
  if (level) *level = p->mix_count;
  if (available) *available = p->queue_depth - p->mix_count;
  pthread_mutex_unlock(&g_lock);
  return 0;
}

// ---------------------------------------------------------------- mixing

// Lock held. Mixes one grain into the port queue (caller checked room).
static void port_mix_grain(A3dPort *p) {
  const uint32_t gran = p->granularity;
  float *dst = p->mixed + ((p->mix_read + p->mix_count) % p->queue_depth) * grain_floats(p);
  memset(dst, 0, grain_floats(p) * sizeof(float));
  if (p->bed_count) {
    const float *b = p->bed + p->bed_read * grain_floats(p);
    for (size_t i = 0; i < grain_floats(p); i++) dst[i] += b[i];
    p->bed_read = (p->bed_read + 1) % p->queue_depth;
    p->bed_count--;
  }
  for (uint32_t s = 0; s < p->max_objects; s++) {
    A3dObject *o = &p->objects[s];
    if (!o->id || !o->pcm_count) continue;
    float g[8];
    ps4_a3d_pan_gains(A3D_OUT_CH, &o->pan, g);
    ps4_a3d_mix_mono(dst, A3D_OUT_CH, o->pcm + (size_t)o->pcm_read * gran, gran, g);
    o->pcm_read = (o->pcm_read + 1) % p->queue_depth;
    o->pcm_count--;
    p->obj_grains++;
    if (o->unreserved && o->pcm_count == 0) {
      o->id = 0;
      p->object_count--;
    }
  }
  if (a3d_log()) {
    for (size_t i = 0; i < grain_floats(p); i++) {
      float a = fabsf(dst[i]);
      if (a > p->out_peak) p->out_peak = a;
      p->out_sq += (double)dst[i] * dst[i];
    }
    p->out_frames += gran;
  }
  p->mix_count++;
  p->advances++;
}

static __thread float *tl_buf;
static __thread size_t tl_cap;

static void *scratch(size_t bytes) {
  if (bytes > tl_cap) {
    free(tl_buf);
    tl_buf = (float *)malloc(bytes);
    tl_cap = tl_buf ? bytes : 0;
  }
  return tl_buf;
}

// Lock held on entry and exit; releases it around each blocking AudioOut
// submission. Submits the associated AudioOut grains, then the mixed grains.
static int32_t port_submit_locked(A3dPort *p, uint32_t blocking) {
  const uint32_t gen = p->gen;
  if (p->out_handle < 0) {
    int32_t h = ps4_audioout_port_open(0xFF, PS4_AUDIO_OUT_PORT_AUDIO3D, 0, p->granularity, 48000,
                                       PS4_AUDIO_OUT_FMT_FLOAT_8CH_STD);
    if (h < 0) return h;
    p->out_handle = h;
  }
  const bool sync = blocking == PS4_AUDIO3D_BLOCKING_SYNC;
  int32_t r = 0;
  p->pushing++;
  for (uint32_t i = 0; i < A3D_MAX_ASSOC && r >= 0; i++) {
    for (;;) {
      A3dAssoc *a = &p->assoc[i];
      if (!p->open || p->gen != gen || a->handle <= 0 || a->pend_count == 0) break;
      int32_t h = a->handle;
      if (!sync && ps4_audioout_port_writable(h) <= 0) break;
      void *buf = scratch(a->bytes);
      if (!buf) {
        r = PS4_AUDIO3D_ERROR_OUT_OF_MEMORY;
        break;
      }
      memcpy(buf, a->pending + (size_t)a->pend_read * a->bytes, a->bytes);
      a->pend_read = (a->pend_read + 1) % p->queue_depth;
      a->pend_count--;
      pthread_mutex_unlock(&g_lock);
      int32_t o = ps4_audioout_port_output(h, buf);
      pthread_mutex_lock(&g_lock);
      if (o < 0) {
        r = o;
        break;
      }
    }
  }
  while (r >= 0 && p->open && p->gen == gen && p->mix_count > 0) {
    int32_t h = p->out_handle;
    if (!sync && ps4_audioout_port_writable(h) <= 0) break;
    size_t bytes = grain_floats(p) * sizeof(float);
    void *buf = scratch(bytes);
    if (!buf) {
      r = PS4_AUDIO3D_ERROR_OUT_OF_MEMORY;
      break;
    }
    memcpy(buf, p->mixed + (size_t)p->mix_read * grain_floats(p), bytes);
    p->mix_read = (p->mix_read + 1) % p->queue_depth;
    p->mix_count--;
    p->grains_out++;
    pthread_mutex_unlock(&g_lock);
    int32_t o = ps4_audioout_port_output(h, buf);
    pthread_mutex_lock(&g_lock);
    if (o < 0) r = o;
  }
  // A port closed during the submission reports INVALID_PORT, whatever error the AudioOut
  // submission it interrupted returned (NOT_OPENED / INVALID_PORT of the closed AudioOut port).
  if (!p->open || p->gen != gen) r = PS4_AUDIO3D_ERROR_INVALID_PORT;
  p->pushing--;
  pthread_cond_broadcast(&g_cond);
  return r < 0 ? r : 0;
}

int32_t ps4_audio3d_port_advance(uint32_t port_id) {
  pthread_mutex_lock(&g_lock);
  A3dPort *p = port_get(port_id);
  int32_t r = 0;
  if (!p) {
    r = PS4_AUDIO3D_ERROR_INVALID_PORT;
  } else if (p->buffer_mode == PS4_AUDIO3D_BUFFER_NO_ADVANCE) {
    r = PS4_AUDIO3D_ERROR_NOT_SUPPORTED;
  } else if (p->mix_count >= p->queue_depth) {
    r = PS4_AUDIO3D_ERROR_NOT_READY;
  } else {
    port_mix_grain(p);
    port_stats_maybe_log(port_id, p);
    if (p->buffer_mode == PS4_AUDIO3D_BUFFER_ADVANCE_NO_PUSH) {
      r = port_submit_locked(p, PS4_AUDIO3D_BLOCKING_SYNC);
    }
  }
  pthread_mutex_unlock(&g_lock);
  return r;
}

int32_t ps4_audio3d_port_push(uint32_t port_id, uint32_t blocking) {
  if (blocking > PS4_AUDIO3D_BLOCKING_SYNC) return PS4_AUDIO3D_ERROR_INVALID_PARAMETER;
  pthread_mutex_lock(&g_lock);
  A3dPort *p = port_get(port_id);
  int32_t r;
  if (!p) {
    r = PS4_AUDIO3D_ERROR_INVALID_PORT;
  } else if (p->buffer_mode != PS4_AUDIO3D_BUFFER_ADVANCE_AND_PUSH) {
    r = PS4_AUDIO3D_ERROR_NOT_SUPPORTED;
  } else {
    p->pushes++;
    r = port_submit_locked(p, blocking);
  }
  pthread_mutex_unlock(&g_lock);
  return r;
}

// ---------------------------------------------------------------- objects

int32_t ps4_audio3d_object_reserve(uint32_t port_id, uint32_t *object_id) {
  if (!object_id) return PS4_AUDIO3D_ERROR_INVALID_PARAMETER;
  *object_id = A3D_OBJECT_INVALID;
  pthread_mutex_lock(&g_lock);
  A3dPort *p = port_get(port_id);
  if (!p) {
    pthread_mutex_unlock(&g_lock);
    return PS4_AUDIO3D_ERROR_INVALID_PORT;
  }
  uint32_t slot = 0;
  while (slot < p->max_objects && p->objects[slot].id != 0) slot++;
  if (slot == p->max_objects) {
    pthread_mutex_unlock(&g_lock);
    return PS4_AUDIO3D_ERROR_OUT_OF_RESOURCES;
  }
  A3dObject *o = &p->objects[slot];
  if (!o->pcm) {
    o->pcm = (float *)malloc((size_t)p->queue_depth * p->granularity * sizeof(float));
    if (!o->pcm) {
      pthread_mutex_unlock(&g_lock);
      return PS4_AUDIO3D_ERROR_OUT_OF_MEMORY;
    }
  }
  // id = generation << 9 | slot; generation in [1, 0x7FFFFE] keeps ids away
  // from 0 and 0xFFFFFFFF.
  if (++p->next_id_gen > 0x7FFFFEu) p->next_id_gen = 1;
  o->id = (p->next_id_gen << A3D_SLOT_BITS) | slot;
  o->unreserved = false;
  object_defaults(o);
  p->object_count++;
  *object_id = o->id;
  pthread_mutex_unlock(&g_lock);
  return 0;
}

int32_t ps4_audio3d_object_unreserve(uint32_t port_id, uint32_t object_id) {
  pthread_mutex_lock(&g_lock);
  A3dPort *p = port_get(port_id);
  int32_t r = 0;
  A3dObject *o = p ? object_get(p, object_id) : NULL;
  if (!p) {
    r = PS4_AUDIO3D_ERROR_INVALID_PORT;
  } else if (!o || o->unreserved) {
    r = PS4_AUDIO3D_ERROR_INVALID_OBJECT;
  } else if (o->pcm_count) {
    o->unreserved = true; // plays its queued PCM, freed by the advance that drains it
  } else {
    o->id = 0;
    p->object_count--;
  }
  pthread_mutex_unlock(&g_lock);
  return r;
}

static int32_t validate_attribute(const A3dPort *p, const Ps4Audio3dAttribute *a, uintptr_t base,
                                  uint64_t *pcm_grains) {
  const void *v = a->value ? (const void *)(base + (uintptr_t)a->value) : NULL;
  float f;
  uint32_t u;
  switch (a->attribute_id) {
  case PS4_AUDIO3D_ATTR_RESET_STATE:
  case PS4_AUDIO3D_ATTR_APPLICATION_SPECIFIC:
    return 0;
  case PS4_AUDIO3D_ATTR_PCM: {
    if (!v || a->value_size < sizeof(Ps4Audio3dPcm)) return PS4_AUDIO3D_ERROR_INVALID_PARAMETER;
    Ps4Audio3dPcm pcm;
    memcpy(&pcm, v, sizeof(pcm));
    if (pcm.format > PS4_AUDIO3D_FORMAT_FLOAT || !pcm.sample_buffer || pcm.num_samples == 0) {
      return PS4_AUDIO3D_ERROR_INVALID_PARAMETER;
    }
    uintptr_t sb = base + (uintptr_t)pcm.sample_buffer;
    if (sb & (pcm.format == PS4_AUDIO3D_FORMAT_FLOAT ? 3u : 1u)) {
      return PS4_AUDIO3D_ERROR_INVALID_PARAMETER;
    }
    // More samples than the whole object queue can hold can never be accepted. 64-bit
    // arithmetic: num_samples + granularity would wrap near UINT32_MAX.
    if ((uint64_t)pcm.num_samples > (uint64_t)p->queue_depth * p->granularity) {
      return PS4_AUDIO3D_ERROR_INVALID_PARAMETER;
    }
    *pcm_grains += ((uint64_t)pcm.num_samples + p->granularity - 1) / p->granularity;
    return 0;
  }
  case PS4_AUDIO3D_ATTR_POSITION: {
    if (!v || a->value_size != 12) return PS4_AUDIO3D_ERROR_INVALID_PARAMETER;
    float xyz[3];
    memcpy(xyz, v, 12);
    if (!isfinite(xyz[0]) || !isfinite(xyz[1]) || !isfinite(xyz[2])) {
      return PS4_AUDIO3D_ERROR_INVALID_PARAMETER;
    }
    return 0;
  }
  case PS4_AUDIO3D_ATTR_GAIN:
  case PS4_AUDIO3D_ATTR_SPREAD:
    if (!v || a->value_size != 4) return PS4_AUDIO3D_ERROR_INVALID_PARAMETER;
    memcpy(&f, v, 4);
    return finite_nonneg(f) ? 0 : PS4_AUDIO3D_ERROR_INVALID_PARAMETER;
  case PS4_AUDIO3D_ATTR_PASSTHROUGH:
    if (!v || a->value_size != 4) return PS4_AUDIO3D_ERROR_INVALID_PARAMETER;
    memcpy(&u, v, 4);
    return u <= PS4_A3D_PASSTHROUGH_RIGHT ? 0 : PS4_AUDIO3D_ERROR_INVALID_PARAMETER;
  case PS4_AUDIO3D_ATTR_AMBISONICS:
    if (!v || a->value_size != 4) return PS4_AUDIO3D_ERROR_INVALID_PARAMETER;
    memcpy(&u, v, 4);
    return u == PS4_AUDIO3D_AMBISONICS_NONE ? 0 : PS4_AUDIO3D_ERROR_NOT_SUPPORTED;
  case PS4_AUDIO3D_ATTR_PRIORITY:
  case PS4_AUDIO3D_ATTR_RESTRICTED:
  case PS4_AUDIO3D_ATTR_OUTPUT_ROUTE:
    if (!v || a->value_size != 4) return PS4_AUDIO3D_ERROR_INVALID_PARAMETER;
    return 0;
  default:
    return PS4_AUDIO3D_ERROR_INVALID_PARAMETER;
  }
}

static void apply_attribute(const A3dPort *p, A3dObject *o, const Ps4Audio3dAttribute *a,
                            uintptr_t base) {
  const void *v = a->value ? (const void *)(base + (uintptr_t)a->value) : NULL;
  switch (a->attribute_id) {
  case PS4_AUDIO3D_ATTR_PCM: {
    Ps4Audio3dPcm pcm;
    memcpy(&pcm, v, sizeof(pcm));
    const uint8_t *src = (const uint8_t *)(base + (uintptr_t)pcm.sample_buffer);
    const uint32_t ssize = pcm.format == PS4_AUDIO3D_FORMAT_FLOAT ? 4 : 2;
    uint32_t left = pcm.num_samples;
    while (left > 0) {
      uint32_t n = left < p->granularity ? left : p->granularity;
      float *dst = o->pcm + (size_t)((o->pcm_read + o->pcm_count) % p->queue_depth) * p->granularity;
      ps4_a3d_convert(dst, src, pcm.format, n);
      if (n < p->granularity) memset(dst + n, 0, (size_t)(p->granularity - n) * sizeof(float));
      o->pcm_count++;
      src += (size_t)n * ssize;
      left -= n;
    }
    break;
  }
  case PS4_AUDIO3D_ATTR_POSITION: memcpy(o->pan.pos, v, 12); break;
  case PS4_AUDIO3D_ATTR_GAIN: memcpy(&o->pan.gain, v, 4); break;
  case PS4_AUDIO3D_ATTR_SPREAD: memcpy(&o->pan.spread, v, 4); break;
  case PS4_AUDIO3D_ATTR_PASSTHROUGH: memcpy(&o->pan.passthrough, v, 4); break;
  case PS4_AUDIO3D_ATTR_PRIORITY: memcpy(&o->priority, v, 4); break;
  case PS4_AUDIO3D_ATTR_RESTRICTED: memcpy(&o->restricted, v, 4); break;
  case PS4_AUDIO3D_ATTR_OUTPUT_ROUTE: memcpy(&o->output_route, v, 4); break;
  default: break; // RESET_STATE (applied first), APPLICATION_SPECIFIC, AMBISONICS NONE
  }
}

int32_t ps4_audio3d_object_set_attributes(uint32_t port_id, uint32_t object_id, uint64_t num,
                                          const Ps4Audio3dAttribute *attrs, uintptr_t base) {
  pthread_mutex_lock(&g_lock);
  A3dPort *p = port_get(port_id);
  int32_t r = 0;
  A3dObject *o = p ? object_get(p, object_id) : NULL;
  if (!p) {
    r = PS4_AUDIO3D_ERROR_INVALID_PORT;
  } else if (num == 0 || !attrs) {
    r = PS4_AUDIO3D_ERROR_INVALID_PARAMETER;
  } else if (!o || o->unreserved) {
    r = PS4_AUDIO3D_ERROR_INVALID_OBJECT;
  } else {
    bool reset = false;
    uint64_t grains = 0;
    for (uint64_t i = 0; i < num && r == 0; i++) {
      r = validate_attribute(p, &attrs[i], base, &grains);
      reset |= attrs[i].attribute_id == PS4_AUDIO3D_ATTR_RESET_STATE;
    }
    if (r == 0 && (reset ? 0 : (uint64_t)o->pcm_count) + grains > p->queue_depth) {
      r = PS4_AUDIO3D_ERROR_NOT_READY;
    }
    if (r == 0) {
      if (reset) object_defaults(o);
      for (uint64_t i = 0; i < num; i++) apply_attribute(p, o, &attrs[i], base);
    }
  }
  pthread_mutex_unlock(&g_lock);
  return r;
}

// ---------------------------------------------------------------- beds

int32_t ps4_audio3d_bed_write(uint32_t port_id, uint32_t num_channels, uint32_t format,
                              const void *buffer, uint32_t num_samples) {
  if (format > PS4_AUDIO3D_FORMAT_FLOAT || (num_channels != 2 && num_channels != 6 &&
                                            num_channels != 8) ||
      !buffer || num_samples == 0) {
    return PS4_AUDIO3D_ERROR_INVALID_PARAMETER;
  }
  if ((uintptr_t)buffer & (format == PS4_AUDIO3D_FORMAT_FLOAT ? 3u : 1u)) {
    return PS4_AUDIO3D_ERROR_INVALID_PARAMETER;
  }
  pthread_mutex_lock(&g_lock);
  A3dPort *p = port_get(port_id);
  int32_t r = 0;
  if (!p) {
    r = PS4_AUDIO3D_ERROR_INVALID_PORT;
  } else if (num_samples > p->granularity) {
    r = PS4_AUDIO3D_ERROR_INVALID_PARAMETER;
  } else if (p->bed_count >= p->queue_depth) {
    r = PS4_AUDIO3D_ERROR_NOT_READY;
  } else {
    size_t in_count = (size_t)num_samples * num_channels;
    float *tmp = (float *)scratch(in_count * sizeof(float));
    if (!tmp) {
      r = PS4_AUDIO3D_ERROR_OUT_OF_MEMORY;
    } else {
      ps4_a3d_convert(tmp, buffer, format, (uint32_t)in_count);
      float *dst = p->bed + (size_t)((p->bed_read + p->bed_count) % p->queue_depth) * grain_floats(p);
      memset(dst, 0, grain_floats(p) * sizeof(float));
      ps4_a3d_mix_bed(dst, A3D_OUT_CH, tmp, num_channels, num_samples);
      p->bed_count++;
    }
  }
  pthread_mutex_unlock(&g_lock);
  return r;
}

// ---------------------------------------------------------------- AudioOut association

static uint32_t audioout_grain_bytes(uint32_t param, uint32_t len) {
  switch (param & 0xFF) {
  case 0: return len * 2;      // S16 mono
  case 1: return len * 4;      // S16 stereo
  case 2: case 6: return len * 16; // S16 8ch
  case 3: return len * 4;      // float mono
  case 4: return len * 8;      // float stereo
  case 5: case 7: return len * 32; // float 8ch
  default: return 0;
  }
}

int32_t ps4_audio3d_audioout_open(uint32_t port_id, int32_t user_id, int32_t type, int32_t index,
                                  uint32_t len, uint32_t freq, uint32_t param) {
  pthread_mutex_lock(&g_lock);
  A3dPort *p = port_get(port_id);
  int32_t r;
  if (!p) {
    r = PS4_AUDIO3D_ERROR_INVALID_PORT;
  } else if (len != p->granularity) {
    r = PS4_AUDIO3D_ERROR_INVALID_PARAMETER;
  } else {
    uint32_t slot = 0;
    while (slot < A3D_MAX_ASSOC && p->assoc[slot].handle > 0) slot++;
    uint32_t bytes = audioout_grain_bytes(param, len);
    if (slot == A3D_MAX_ASSOC) {
      r = PS4_AUDIO3D_ERROR_OUT_OF_RESOURCES;
    } else if (bytes == 0) {
      r = PS4_AUDIO_OUT_ERROR_INVALID_FORMAT;
    } else {
      A3dAssoc *a = &p->assoc[slot];
      uint8_t *pend = (uint8_t *)realloc(a->pending, (size_t)bytes * p->queue_depth);
      if (!pend) {
        r = PS4_AUDIO3D_ERROR_OUT_OF_MEMORY;
      } else {
        a->pending = pend;
        r = ps4_audioout_port_open(user_id, type, index, len, freq, param);
        if (r > 0) {
          a->handle = r;
          a->bytes = bytes;
          uint32_t fmt = param & 0xFF;
          a->is_float = fmt == 3 || fmt == 4 || fmt == 5 || fmt == 7;
          a->pend_read = 0;
          a->pend_count = 0;
        }
      }
    }
  }
  pthread_mutex_unlock(&g_lock);
  fprintf(stderr,
          "[Audio3d] AudioOutOpen(port %u, user 0x%x, type %d, index %d, len %u, freq %u, "
          "param 0x%x) -> 0x%x\n",
          port_id, (uint32_t)user_id, type, index, len, freq, param, (uint32_t)r);
  return r;
}

static A3dAssoc *assoc_find(int32_t handle, A3dPort **port) {
  if (handle <= 0) return NULL;
  for (uint32_t i = 0; i < A3D_MAX_PORTS; i++) {
    A3dPort *p = port_get(i);
    if (!p) continue;
    for (uint32_t j = 0; j < A3D_MAX_ASSOC; j++) {
      if (p->assoc[j].handle == handle) {
        *port = p;
        return &p->assoc[j];
      }
    }
  }
  return NULL;
}

int32_t ps4_audio3d_audioout_close(int32_t handle) {
  pthread_mutex_lock(&g_lock);
  A3dPort *p = NULL;
  A3dAssoc *a = assoc_find(handle, &p);
  int32_t r = PS4_AUDIO3D_ERROR_INVALID_PORT;
  if (a) {
    a->handle = 0;
    a->pend_count = 0;
    r = ps4_audioout_port_close(handle);
  }
  pthread_mutex_unlock(&g_lock);
  return r;
}

int32_t ps4_audio3d_audioout_outputs(const Ps4Audio3dAudioOutParam *params, uint32_t num,
                                     uintptr_t base) {
  if (!params || num == 0) return PS4_AUDIO3D_ERROR_INVALID_PARAMETER;
  pthread_mutex_lock(&g_lock);
  int32_t r = 0;
  // Validate every entry first so a failing call queues nothing.
  for (uint32_t i = 0; i < num && r == 0; i++) {
    A3dPort *p = NULL;
    A3dAssoc *a = assoc_find(params[i].handle, &p);
    if (!a) {
      r = PS4_AUDIO3D_ERROR_INVALID_PORT;
    } else if (params[i].ptr &&
               ((base + (uintptr_t)params[i].ptr) & (a->is_float ? 3u : 1u)) != 0) {
      r = PS4_AUDIO3D_ERROR_INVALID_PARAMETER; // samples must be naturally aligned
    } else {
      // Entries earlier in this call for the same handle also take a pending slot.
      uint32_t adds = 1;
      for (uint32_t j = 0; j < i; j++) adds += params[j].handle == params[i].handle;
      if ((uint64_t)a->pend_count + adds > p->queue_depth) r = PS4_AUDIO3D_ERROR_NOT_READY;
    }
  }
  for (uint32_t i = 0; i < num && r == 0; i++) {
    A3dPort *p = NULL;
    A3dAssoc *a = assoc_find(params[i].handle, &p);
    uint8_t *dst = a->pending + (size_t)((a->pend_read + a->pend_count) % p->queue_depth) * a->bytes;
    if (params[i].ptr) {
      memcpy(dst, (const void *)(base + (uintptr_t)params[i].ptr), a->bytes);
    } else {
      memset(dst, 0, a->bytes); // NULL submits silence for this grain
    }
    a->pend_count++;
  }
  pthread_mutex_unlock(&g_lock);
  return r;
}

// ---------------------------------------------------------------- guest shims

#define A3D_RET(ctx, v) ((ctx)->rax = (uint64_t)(int64_t)(int32_t)(v))
#define GPTR(ctx, a) ((a) ? (void *)((ctx)->mem_base + (a)) : NULL)

void shim_sceAudio3dInitialize(GuestContext *ctx) {
  A3D_RET(ctx, ps4_audio3d_initialize((int64_t)ctx->rdi));
  SHIM_RETURN();
}

void shim_sceAudio3dTerminate(GuestContext *ctx) {
  A3D_RET(ctx, ps4_audio3d_terminate());
  SHIM_RETURN();
}

void shim_sceAudio3dGetDefaultOpenParameters(GuestContext *ctx) {
  A3D_RET(ctx, ps4_audio3d_get_default_open_parameters(GPTR(ctx, ctx->rdi)));
  SHIM_RETURN();
}

void shim_sceAudio3dPortOpen(GuestContext *ctx) {
  // The open parameters are read up to their size_this; port_open checks it.
  A3D_RET(ctx, ps4_audio3d_port_open((int32_t)ctx->rdi, GPTR(ctx, ctx->rsi),
                                     (uint32_t *)GPTR(ctx, ctx->rdx)));
  SHIM_RETURN();
}

void shim_sceAudio3dPortClose(GuestContext *ctx) {
  A3D_RET(ctx, ps4_audio3d_port_close((uint32_t)ctx->rdi));
  SHIM_RETURN();
}

void shim_sceAudio3dPortSetAttribute(GuestContext *ctx) {
  A3D_RET(ctx, ps4_audio3d_port_set_attribute((uint32_t)ctx->rdi, (uint32_t)ctx->rsi,
                                              GPTR(ctx, ctx->rdx), ctx->rcx));
  SHIM_RETURN();
}

void shim_sceAudio3dPortGetAttributesSupported(GuestContext *ctx) {
  A3D_RET(ctx, ps4_audio3d_port_get_attributes_supported(
                   (uint32_t)ctx->rdi, (uint32_t *)GPTR(ctx, ctx->rsi), (uint32_t *)GPTR(ctx, ctx->rdx)));
  SHIM_RETURN();
}

void shim_sceAudio3dPortGetQueueLevel(GuestContext *ctx) {
  A3D_RET(ctx, ps4_audio3d_port_get_queue_level((uint32_t)ctx->rdi, (uint32_t *)GPTR(ctx, ctx->rsi),
                                                (uint32_t *)GPTR(ctx, ctx->rdx)));
  SHIM_RETURN();
}

void shim_sceAudio3dPortAdvance(GuestContext *ctx) {
  A3D_RET(ctx, ps4_audio3d_port_advance((uint32_t)ctx->rdi));
  SHIM_RETURN();
}

void shim_sceAudio3dPortPush(GuestContext *ctx) {
  A3D_RET(ctx, ps4_audio3d_port_push((uint32_t)ctx->rdi, (uint32_t)ctx->rsi));
  SHIM_RETURN();
}

void shim_sceAudio3dObjectReserve(GuestContext *ctx) {
  A3D_RET(ctx, ps4_audio3d_object_reserve((uint32_t)ctx->rdi, (uint32_t *)GPTR(ctx, ctx->rsi)));
  SHIM_RETURN();
}

void shim_sceAudio3dObjectUnreserve(GuestContext *ctx) {
  A3D_RET(ctx, ps4_audio3d_object_unreserve((uint32_t)ctx->rdi, (uint32_t)ctx->rsi));
  SHIM_RETURN();
}

void shim_sceAudio3dObjectSetAttributes(GuestContext *ctx) {
  A3D_RET(ctx, ps4_audio3d_object_set_attributes(
                   (uint32_t)ctx->rdi, (uint32_t)ctx->rsi, ctx->rdx,
                   (const Ps4Audio3dAttribute *)GPTR(ctx, ctx->rcx), (uintptr_t)ctx->mem_base));
  SHIM_RETURN();
}

void shim_sceAudio3dBedWrite(GuestContext *ctx) {
  A3D_RET(ctx, ps4_audio3d_bed_write((uint32_t)ctx->rdi, (uint32_t)ctx->rsi, (uint32_t)ctx->rdx,
                                     GPTR(ctx, ctx->rcx), (uint32_t)ctx->r8));
  SHIM_RETURN();
}

// sceAudio3dBedWrite2(port, channels, format, buffer, samples, output_route,
// restricted): there is a single output, so the route (0 both, 1 HMU only, 2
// TV only) and the restricted flag (7th argument, on the stack) only get
// validated.
void shim_sceAudio3dBedWrite2(GuestContext *ctx) {
  if ((uint32_t)ctx->r9 > 2) {
    A3D_RET(ctx, PS4_AUDIO3D_ERROR_INVALID_PARAMETER);
    SHIM_RETURN();
  }
  A3D_RET(ctx, ps4_audio3d_bed_write((uint32_t)ctx->rdi, (uint32_t)ctx->rsi, (uint32_t)ctx->rdx,
                                     GPTR(ctx, ctx->rcx), (uint32_t)ctx->r8));
  SHIM_RETURN();
}

void shim_sceAudio3dAudioOutOpen(GuestContext *ctx) {
  // (port, user, type, index, len, freq, param): param is the 7th argument,
  // [rsp + 8] at entry (rsp points at the return address).
  uint32_t param = *(uint32_t *)(ctx->mem_base + ctx->rsp + 8);
  int32_t r = ps4_audio3d_audioout_open((uint32_t)ctx->rdi, (int32_t)ctx->rsi, (int32_t)ctx->rdx,
                                        (int32_t)ctx->rcx, (uint32_t)ctx->r8, (uint32_t)ctx->r9,
                                        param);
  A3D_RET(ctx, r);
  SHIM_RETURN();
}

void shim_sceAudio3dAudioOutClose(GuestContext *ctx) {
  A3D_RET(ctx, ps4_audio3d_audioout_close((int32_t)ctx->rdi));
  SHIM_RETURN();
}

void shim_sceAudio3dAudioOutOutputs(GuestContext *ctx) {
  A3D_RET(ctx, ps4_audio3d_audioout_outputs((const Ps4Audio3dAudioOutParam *)GPTR(ctx, ctx->rdi),
                                            (uint32_t)ctx->rsi, (uintptr_t)ctx->mem_base));
  SHIM_RETURN();
}
