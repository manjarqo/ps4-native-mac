// SPDX-License-Identifier: GPL-2.0-or-later
//
// libSceVideodec2 (H.264/AVC, used by CRI Sofdec in Sonic Origins) on the shared VideoToolbox
// core (ps4_h264_vt.c). HEVC is refused.
//
// Struct layouts and error codes follow shadPS4 (src/core/libraries/videodec/videodec2.{h,cpp},
// videodec2_impl.cpp, videodec_error.h, Copyright 2024-2026 shadPS4 Emulator Project,
// GPL-2.0-or-later). Offsets are hex.
//
// DecoderConfigInfo 0x48: 00 this_size 08 resource_type u32 0C codec_type u32 (1 = AVC,
//   974921 = HEVC) 10 profile 14 max_level 18 max_frame_width s32 1C max_frame_height s32
//   20 max_dpb_frame_count 24 decode_pipeline_depth 28 compute_queue 30 cpu_affinity_mask
//   38 cpu_thread_priority 3C optimize_progressive_video u8 3D check_memory_type u8 40 extra.
// DecoderMemoryInfo 0x48: as libSceVdecsw's (cpu, gpu and cpu_gpu blocks, max_frame_buffer_size,
//   frame_buffer_alignment). The decoder needs no guest memory: 64 KiB each is reported.
//   max_frame_buffer_size = align(NV12 size of max_frame_width x max_frame_height, 256) + 0x4000,
//   room for the picture-info trailer, as shadPS4.
// ComputeConfigInfo 0x10 / ComputeMemoryInfo 0x18: bookkeeping; the queue handle is the
//   cpu_gpu_memory address, as shadPS4.
// InputData 0x30 {00 this_size, 08 au_data, 10 au_size, 18 pts, 20 dts, 28 attached_data}.
// FrameBuffer 0x20 {00 this_size, 08 frame_buffer, 10 frame_buffer_size, 18 is_accepted u8}.
// OutputInfo 0x38 (old 0x30) {00 this_size, 08 is_valid, 09 is_error_frame, 0A picture_count,
//   0C codec_type, 10 frame_width, 14 frame_pitch, 18 frame_height, 20 frame_buffer,
//   28 frame_buffer_size, [0x38 only: 30 frame_format, 34 frame_pitch_in_bytes]}.
//
// Decode decodes the access unit synchronously and hands out at most one picture, in display
// order; Flush releases the pictures held for reordering and hands out one per call, is_valid 0
// once none is left. A picture is linear NV12 (see ps4_h264_vt.h) followed by the AVC picture
// information (H264AvcPictureInfo) at frame_buffer + frame_buffer_size, as shadPS4 writes it.
// An access unit that cannot be decoded gives an error picture, as in libSceVdecsw: is_valid 1,
// is_error_frame 1, the frame buffer left as it is but the trailer written. A picture larger than
// the frame buffer stays queued and the call returns FRAME_BUFFER_SIZE (is_accepted 0).
// Decoder handles carry a generation, so a deleted decoder's handle never names a newer one, and
// a call in progress on another thread keeps its decoder alive until it returns (as libSceVdecsw).
#include "recomp_runtime.h"
#include "ps4_h264_vt.h"
#include <pthread.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define VDEC2_OK 0
#define VDEC2_ERROR_API_FAIL ((int32_t)0x811D0100)
#define VDEC2_ERROR_STRUCT_SIZE ((int32_t)0x811D0101)
#define VDEC2_ERROR_ARGUMENT_POINTER ((int32_t)0x811D0102)
#define VDEC2_ERROR_DECODER_INSTANCE ((int32_t)0x811D0103)
#define VDEC2_ERROR_MEMORY_SIZE ((int32_t)0x811D0104)
#define VDEC2_ERROR_MEMORY_POINTER ((int32_t)0x811D0105)
#define VDEC2_ERROR_FRAME_BUFFER_SIZE ((int32_t)0x811D0106)
#define VDEC2_ERROR_FRAME_BUFFER_POINTER ((int32_t)0x811D0107)
#define VDEC2_ERROR_ACCESS_UNIT_SIZE ((int32_t)0x811D010D)
#define VDEC2_ERROR_ACCESS_UNIT_POINTER ((int32_t)0x811D010E)
#define VDEC2_ERROR_CONFIG_INFO ((int32_t)0x811D0200)
#define VDEC2_ERROR_COMPUTE_PIPE_ID ((int32_t)0x811D0201)
#define VDEC2_ERROR_COMPUTE_QUEUE_ID ((int32_t)0x811D0202)
#define VDEC2_ERROR_CODEC_TYPE ((int32_t)0x811D0204)

#define VDEC2_CODEC_AVC 1u

typedef struct Vdec2DecoderConfigInfo {
    uint64_t this_size;
    uint32_t resource_type;
    uint32_t codec_type;
    uint32_t profile;
    uint32_t max_level;
    int32_t max_frame_width;
    int32_t max_frame_height;
    int32_t max_dpb_frame_count;
    uint32_t decode_pipeline_depth;
    uint64_t compute_queue;
    uint64_t cpu_affinity_mask;
    int32_t cpu_thread_priority;
    uint8_t optimize_progressive_video;
    uint8_t check_memory_type;
    uint8_t reserved0;
    uint8_t reserved1;
    uint64_t extra_config_info;
} Vdec2DecoderConfigInfo;
_Static_assert(sizeof(Vdec2DecoderConfigInfo) == 0x48, "DecoderConfigInfo");

typedef struct Vdec2DecoderMemoryInfo {
    uint64_t this_size;
    uint64_t cpu_memory_size;
    uint64_t cpu_memory;
    uint64_t gpu_memory_size;
    uint64_t gpu_memory;
    uint64_t cpu_gpu_memory_size;
    uint64_t cpu_gpu_memory;
    uint64_t max_frame_buffer_size;
    uint32_t frame_buffer_alignment;
    uint32_t reserved0;
} Vdec2DecoderMemoryInfo;
_Static_assert(sizeof(Vdec2DecoderMemoryInfo) == 0x48, "DecoderMemoryInfo");

typedef struct Vdec2InputData {
    uint64_t this_size;
    uint64_t au_data;
    uint64_t au_size;
    uint64_t pts_data;
    uint64_t dts_data;
    uint64_t attached_data;
} Vdec2InputData;
_Static_assert(sizeof(Vdec2InputData) == 0x30, "InputData");

typedef struct Vdec2FrameBuffer {
    uint64_t this_size;
    uint64_t frame_buffer;
    uint64_t frame_buffer_size;
    uint8_t is_accepted;
} Vdec2FrameBuffer;
_Static_assert(sizeof(Vdec2FrameBuffer) == 0x20, "FrameBuffer");

typedef struct Vdec2OutputInfo {
    uint64_t this_size;
    uint8_t is_valid;
    uint8_t is_error_frame;
    uint8_t picture_count;
    uint32_t codec_type;
    uint32_t frame_width;
    uint32_t frame_pitch;
    uint32_t frame_height;
    uint64_t frame_buffer;
    uint64_t frame_buffer_size;
    uint32_t frame_format;         // 0x38 layout only
    uint32_t frame_pitch_in_bytes; // 0x38 layout only
} Vdec2OutputInfo;
_Static_assert(sizeof(Vdec2OutputInfo) == 0x38, "OutputInfo");
_Static_assert(offsetof(Vdec2OutputInfo, frame_buffer) == 0x20, "OutputInfo.frame_buffer");
_Static_assert(offsetof(Vdec2OutputInfo, frame_format) == 0x30, "OutputInfo old size");

typedef struct Vdec2ComputeMemoryInfo {
    uint64_t this_size;
    uint64_t cpu_gpu_memory_size;
    uint64_t cpu_gpu_memory;
} Vdec2ComputeMemoryInfo;
_Static_assert(sizeof(Vdec2ComputeMemoryInfo) == 0x18, "ComputeMemoryInfo");

typedef struct Vdec2ComputeConfigInfo {
    uint64_t this_size;
    uint16_t compute_pipe_id;
    uint16_t compute_queue_id;
    uint8_t check_memory_type;
    uint8_t reserved0;
    uint16_t reserved1;
} Vdec2ComputeConfigInfo;
_Static_assert(sizeof(Vdec2ComputeConfigInfo) == 0x10, "ComputeConfigInfo");

#define VDEC2_DECODER_MEM_SIZE 0x10000ULL
#define VDEC2_COMPUTE_MEM_SIZE 0x4000ULL
#define VDEC2_FRAME_BUFFER_ALIGN 0x100u
#define VDEC2_MAX_DECODERS 16
#define VDEC2_HANDLE_TAG 0x5644433200000000ULL /* "VDC2" */

void ps4_gnm_notify_cpu_write(uint64_t addr, uint64_t size) __attribute__((weak));

typedef struct Vdec2 {
    int refs;        // the table's reference + one per call in progress (g_table_lock)
    int slot;
    uint64_t handle; // tag | generation << 8 | slot + 1
    H264VtDecoder *core;
    pthread_mutex_t lock; // serialises Decode / Flush / Reset and guards the counts
    uint64_t pictures;    // handed to the guest, error pictures included
    uint64_t errors;
} Vdec2;

static pthread_mutex_t g_table_lock = PTHREAD_MUTEX_INITIALIZER;
static uint32_t g_generation;
static Vdec2 *g_decoders[VDEC2_MAX_DECODERS];

static inline void *gptr(GuestContext *ctx, uint64_t addr) { return addr ? ctx->mem_base + addr : NULL; }

static inline bool grange_ok(GuestContext *ctx, uint64_t addr, uint64_t size) {
    return addr <= ctx->mem_size && size <= ctx->mem_size - addr;
}

#define VDEC2_RETURN(rc)                                                                       \
    do {                                                                                       \
        ctx->rax = (uint64_t)(int64_t)(int32_t)(rc);                                           \
        SHIM_RETURN();                                                                         \
        return;                                                                                \
    } while (0)

static void vdec2_free(Vdec2 *d) {
    h264vt_destroy(d->core);
    pthread_mutex_destroy(&d->lock);
    free(d);
}

// Takes a reference on the decoder behind a guest handle (NULL if none).
static Vdec2 *vdec2_acquire(uint64_t handle) {
    if ((handle & 0xFFFFFFFF00000000ULL) != VDEC2_HANDLE_TAG) return NULL;
    const uint64_t slot = (handle & 0xFF) - 1;
    if (slot >= VDEC2_MAX_DECODERS) return NULL;
    pthread_mutex_lock(&g_table_lock);
    Vdec2 *d = g_decoders[slot];
    if (d && d->handle != handle) d = NULL;
    if (d) d->refs++;
    pthread_mutex_unlock(&g_table_lock);
    return d;
}

static void vdec2_release(Vdec2 *d) {
    pthread_mutex_lock(&g_table_lock);
    const bool last = --d->refs == 0;
    pthread_mutex_unlock(&g_table_lock);
    if (last) vdec2_free(d);
}

// Runs fn on the decoder named by ctx->rdi under its lock, with a reference held for the call.
#define VDEC2_WITH_DECODER(fn)                                                                 \
    do {                                                                                       \
        Vdec2 *d_ = vdec2_acquire(ctx->rdi);                                                   \
        if (!d_) VDEC2_RETURN(VDEC2_ERROR_DECODER_INSTANCE);                                   \
        pthread_mutex_lock(&d_->lock);                                                         \
        const int32_t rc_ = fn(ctx, d_);                                                       \
        pthread_mutex_unlock(&d_->lock);                                                       \
        vdec2_release(d_);                                                                     \
        VDEC2_RETURN(rc_);                                                                     \
    } while (0)

static uint64_t max_frame_buffer_size(const Vdec2DecoderConfigInfo *cfg) {
    int32_t w = cfg->max_frame_width, h = cfg->max_frame_height;
    if (w <= 0 || h <= 0) {
        w = 1920;
        h = 1080;
        if (cfg->max_level >= 150) {
            w = 3840;
            h = 2160;
        }
    }
    const uint64_t frame = h264vt_nv12_size((uint32_t)w, (uint32_t)h);
    return ((frame + 255) & ~255ULL) + 0x4000;
}

// int sceVideodec2QueryComputeMemoryInfo(SceVideodec2ComputeMemoryInfo *info)
void shim_sceVideodec2QueryComputeMemoryInfo(GuestContext *ctx) {
    Vdec2ComputeMemoryInfo *mi = (Vdec2ComputeMemoryInfo *)gptr(ctx, ctx->rdi);
    if (!mi) VDEC2_RETURN(VDEC2_ERROR_ARGUMENT_POINTER);
    if (mi->this_size != sizeof(*mi)) VDEC2_RETURN(VDEC2_ERROR_STRUCT_SIZE);
    mi->cpu_gpu_memory_size = VDEC2_COMPUTE_MEM_SIZE;
    mi->cpu_gpu_memory = 0;
    VDEC2_RETURN(VDEC2_OK);
}

// int sceVideodec2AllocateComputeQueue(const SceVideodec2ComputeConfigInfo *cfg,
//                                      const SceVideodec2ComputeMemoryInfo *mem,
//                                      SceVideodec2ComputeQueue *queue)
void shim_sceVideodec2AllocateComputeQueue(GuestContext *ctx) {
    const Vdec2ComputeConfigInfo *cfg = (const Vdec2ComputeConfigInfo *)gptr(ctx, ctx->rdi);
    const Vdec2ComputeMemoryInfo *mi = (const Vdec2ComputeMemoryInfo *)gptr(ctx, ctx->rsi);
    uint64_t *queue = (uint64_t *)gptr(ctx, ctx->rdx);
    if (!cfg || !mi || !queue) VDEC2_RETURN(VDEC2_ERROR_ARGUMENT_POINTER);
    if (cfg->this_size != sizeof(*cfg) || mi->this_size != sizeof(*mi)) VDEC2_RETURN(VDEC2_ERROR_STRUCT_SIZE);
    if (cfg->reserved0 || cfg->reserved1) VDEC2_RETURN(VDEC2_ERROR_CONFIG_INFO);
    if (cfg->compute_pipe_id > 4) VDEC2_RETURN(VDEC2_ERROR_COMPUTE_PIPE_ID);
    if (cfg->compute_queue_id > 7) VDEC2_RETURN(VDEC2_ERROR_COMPUTE_QUEUE_ID);
    if (!mi->cpu_gpu_memory) VDEC2_RETURN(VDEC2_ERROR_MEMORY_POINTER);
    if (mi->cpu_gpu_memory_size < VDEC2_COMPUTE_MEM_SIZE) VDEC2_RETURN(VDEC2_ERROR_MEMORY_SIZE);
    *queue = mi->cpu_gpu_memory;
    VDEC2_RETURN(VDEC2_OK);
}

// int sceVideodec2ReleaseComputeQueue(SceVideodec2ComputeQueue queue)
void shim_sceVideodec2ReleaseComputeQueue(GuestContext *ctx) {
    VDEC2_RETURN(ctx->rdi ? VDEC2_OK : VDEC2_ERROR_ARGUMENT_POINTER);
}

static int32_t check_config(const Vdec2DecoderConfigInfo *cfg, const Vdec2DecoderMemoryInfo *mi) {
    if (!cfg || !mi) return VDEC2_ERROR_ARGUMENT_POINTER;
    if (cfg->this_size != sizeof(*cfg) || mi->this_size != sizeof(*mi)) return VDEC2_ERROR_STRUCT_SIZE;
    if (cfg->codec_type != VDEC2_CODEC_AVC) {
        fprintf(stderr, "[libSceVideodec2] codec type %u refused: only H.264/AVC is decoded\n", cfg->codec_type);
        return VDEC2_ERROR_CODEC_TYPE;
    }
    return VDEC2_OK;
}

// int sceVideodec2QueryDecoderMemoryInfo(const SceVideodec2DecoderConfigInfo *cfg,
//                                        SceVideodec2DecoderMemoryInfo *mem)
void shim_sceVideodec2QueryDecoderMemoryInfo(GuestContext *ctx) {
    const Vdec2DecoderConfigInfo *cfg = (const Vdec2DecoderConfigInfo *)gptr(ctx, ctx->rdi);
    Vdec2DecoderMemoryInfo *mi = (Vdec2DecoderMemoryInfo *)gptr(ctx, ctx->rsi);
    const int32_t rc = check_config(cfg, mi);
    if (rc != VDEC2_OK) VDEC2_RETURN(rc);
    mi->cpu_memory_size = VDEC2_DECODER_MEM_SIZE;
    mi->cpu_memory = 0;
    mi->gpu_memory_size = VDEC2_DECODER_MEM_SIZE;
    mi->gpu_memory = 0;
    mi->cpu_gpu_memory_size = VDEC2_DECODER_MEM_SIZE;
    mi->cpu_gpu_memory = 0;
    mi->max_frame_buffer_size = max_frame_buffer_size(cfg);
    mi->frame_buffer_alignment = VDEC2_FRAME_BUFFER_ALIGN;
    mi->reserved0 = 0;
    VDEC2_RETURN(VDEC2_OK);
}

// int sceVideodec2CreateDecoder(const SceVideodec2DecoderConfigInfo *cfg,
//                               const SceVideodec2DecoderMemoryInfo *mem, SceVideodec2Decoder *decoder)
void shim_sceVideodec2CreateDecoder(GuestContext *ctx) {
    const Vdec2DecoderConfigInfo *cfg = (const Vdec2DecoderConfigInfo *)gptr(ctx, ctx->rdi);
    const Vdec2DecoderMemoryInfo *mi = (const Vdec2DecoderMemoryInfo *)gptr(ctx, ctx->rsi);
    uint64_t *out = (uint64_t *)gptr(ctx, ctx->rdx);
    if (!out) VDEC2_RETURN(VDEC2_ERROR_ARGUMENT_POINTER);
    const int32_t rc = check_config(cfg, mi);
    if (rc != VDEC2_OK) VDEC2_RETURN(rc);
    if (!mi->cpu_memory || !mi->gpu_memory || !mi->cpu_gpu_memory) VDEC2_RETURN(VDEC2_ERROR_MEMORY_POINTER);
    if (mi->cpu_memory_size < VDEC2_DECODER_MEM_SIZE || mi->gpu_memory_size < VDEC2_DECODER_MEM_SIZE ||
        mi->cpu_gpu_memory_size < VDEC2_DECODER_MEM_SIZE)
        VDEC2_RETURN(VDEC2_ERROR_MEMORY_SIZE);
    Vdec2 *d = (Vdec2 *)calloc(1, sizeof(Vdec2));
    if (d) d->core = h264vt_create("libSceVideodec2");
    if (!d || !d->core) {
        free(d);
        VDEC2_RETURN(VDEC2_ERROR_API_FAIL);
    }
    pthread_mutex_init(&d->lock, NULL);
    int slot = -1;
    pthread_mutex_lock(&g_table_lock);
    for (int i = 0; i < VDEC2_MAX_DECODERS; i++)
        if (!g_decoders[i]) {
            g_decoders[i] = d;
            slot = i;
            d->slot = i;
            d->refs = 1;
            d->handle = VDEC2_HANDLE_TAG | (uint64_t)(++g_generation & 0xFFFFFF) << 8 | (uint64_t)(i + 1);
            break;
        }
    pthread_mutex_unlock(&g_table_lock);
    if (slot < 0) {
        vdec2_free(d);
        VDEC2_RETURN(VDEC2_ERROR_API_FAIL);
    }
    fprintf(stderr, "[libSceVideodec2] decoder %d: profile %u level %u max %dx%d dpb %d depth %u\n", slot, cfg->profile,
            cfg->max_level, cfg->max_frame_width, cfg->max_frame_height, cfg->max_dpb_frame_count,
            cfg->decode_pipeline_depth);
    *out = d->handle;
    VDEC2_RETURN(VDEC2_OK);
}

// int sceVideodec2DeleteDecoder(SceVideodec2Decoder decoder)
void shim_sceVideodec2DeleteDecoder(GuestContext *ctx) {
    Vdec2 *d = vdec2_acquire(ctx->rdi);
    if (!d) VDEC2_RETURN(VDEC2_ERROR_DECODER_INSTANCE);
    pthread_mutex_lock(&g_table_lock);
    const bool mine = g_decoders[d->slot] == d; // a concurrent Delete may have won
    if (mine) {
        g_decoders[d->slot] = NULL;
        d->refs--; // the table's reference
    }
    pthread_mutex_unlock(&g_table_lock);
    if (mine) {
        pthread_mutex_lock(&d->lock);
        fprintf(stderr, "[libSceVideodec2] decoder %d deleted: %llu pictures (%llu error pictures)\n", d->slot,
                (unsigned long long)d->pictures, (unsigned long long)d->errors);
        pthread_mutex_unlock(&d->lock);
    }
    vdec2_release(d);
    VDEC2_RETURN(mine ? VDEC2_OK : VDEC2_ERROR_DECODER_INSTANCE);
}

// Checks the frame buffer and output info and clears the "no picture" fields.
static int32_t begin_output(GuestContext *ctx, Vdec2FrameBuffer *fb, Vdec2OutputInfo *info) {
    if (!fb || !info) return VDEC2_ERROR_ARGUMENT_POINTER;
    if (fb->this_size != sizeof(*fb) || (info->this_size | 8) != sizeof(*info)) return VDEC2_ERROR_STRUCT_SIZE;
    fb->is_accepted = 0;
    info->is_valid = 0;
    info->is_error_frame = 0;
    info->picture_count = 0;
    if (!fb->frame_buffer) return VDEC2_ERROR_FRAME_BUFFER_POINTER;
    if (!grange_ok(ctx, fb->frame_buffer, fb->frame_buffer_size)) return VDEC2_ERROR_FRAME_BUFFER_SIZE;
    return VDEC2_OK;
}

// Hands the next picture to the guest, if one is ready: NV12 into the frame buffer, the AVC
// picture information after it, and OutputInfo.
static int32_t emit_picture(GuestContext *ctx, Vdec2 *d, Vdec2FrameBuffer *fb, Vdec2OutputInfo *info) {
    H264VtFrame *f = NULL;
    uint64_t need = 0;
    const int pr = h264vt_pop_fitting(d->core, fb->frame_buffer_size, sizeof(H264AvcPictureInfo), &f, &need);
    if (pr == H264VT_POP_EMPTY) return VDEC2_OK;
    if (pr == H264VT_POP_TOO_SMALL) {
        static int warned;
        if (warned++ < 8)
            fprintf(stderr, "[libSceVideodec2] picture does not fit the frame buffer (0x%llx < 0x%llx)\n",
                    (unsigned long long)fb->frame_buffer_size, (unsigned long long)need);
        return VDEC2_ERROR_FRAME_BUFFER_SIZE;
    }
    const uint64_t frame_size = h264vt_nv12_size(f->width, f->height);
    uint8_t *dst = ctx->mem_base + fb->frame_buffer;
    if (!f->error) h264vt_copy_nv12(f, dst);
    H264AvcPictureInfo pic;
    h264vt_fill_picture_info(&pic, f);
    memcpy(dst + frame_size, &pic, sizeof(pic));
    if (ps4_gnm_notify_cpu_write) {
        if (f->error) ps4_gnm_notify_cpu_write(fb->frame_buffer + frame_size, sizeof(pic));
        else ps4_gnm_notify_cpu_write(fb->frame_buffer, frame_size + sizeof(pic));
    }
    fb->is_accepted = 1;
    info->is_valid = 1;
    info->is_error_frame = f->error ? 1 : 0;
    info->picture_count = 1;
    info->codec_type = VDEC2_CODEC_AVC;
    info->frame_width = (f->width + 15u) & ~15u;
    info->frame_pitch = h264vt_pitch(f->width);
    info->frame_height = h264vt_aligned_height(f->height);
    info->frame_buffer = fb->frame_buffer;
    info->frame_buffer_size = frame_size;
    if (info->this_size == sizeof(*info)) {
        info->frame_format = 0;
        info->frame_pitch_in_bytes = info->frame_pitch;
    }
    if (f->error) {
        d->errors++;
    } else if (d->pictures - d->errors == 0) {
        fprintf(stderr, "[libSceVideodec2] first picture decoded (%ux%u)\n", f->width, f->height);
    }
    d->pictures++;
    h264vt_frame_free(f);
    return VDEC2_OK;
}

// int sceVideodec2Decode(SceVideodec2Decoder decoder, const SceVideodec2InputData *in,
//                        SceVideodec2FrameBuffer *fb, SceVideodec2OutputInfo *info)
static int32_t vdec2_Decode(GuestContext *ctx, Vdec2 *d) {
    const Vdec2InputData *in = (const Vdec2InputData *)gptr(ctx, ctx->rsi);
    Vdec2FrameBuffer *fb = (Vdec2FrameBuffer *)gptr(ctx, ctx->rdx);
    Vdec2OutputInfo *info = (Vdec2OutputInfo *)gptr(ctx, ctx->rcx);
    if (!in) return VDEC2_ERROR_ARGUMENT_POINTER;
    if (in->this_size != sizeof(*in)) return VDEC2_ERROR_STRUCT_SIZE;
    const int32_t rc = begin_output(ctx, fb, info);
    if (rc != VDEC2_OK) return rc;
    if (!in->au_data) return VDEC2_ERROR_ACCESS_UNIT_POINTER;
    if (in->au_size == 0 || !grange_ok(ctx, in->au_data, in->au_size)) return VDEC2_ERROR_ACCESS_UNIT_SIZE;
    // A failed access unit gives an error picture (the core logs it); the call itself succeeds.
    h264vt_decode(d->core, ctx->mem_base + in->au_data, (size_t)in->au_size, (int64_t)in->pts_data,
                  (int64_t)in->dts_data, in->attached_data, NULL);
    return emit_picture(ctx, d, fb, info);
}
void shim_sceVideodec2Decode(GuestContext *ctx) { VDEC2_WITH_DECODER(vdec2_Decode); }

// int sceVideodec2Flush(SceVideodec2Decoder decoder, SceVideodec2FrameBuffer *fb,
//                       SceVideodec2OutputInfo *info)
static int32_t vdec2_Flush(GuestContext *ctx, Vdec2 *d) {
    Vdec2FrameBuffer *fb = (Vdec2FrameBuffer *)gptr(ctx, ctx->rsi);
    Vdec2OutputInfo *info = (Vdec2OutputInfo *)gptr(ctx, ctx->rdx);
    const int32_t rc = begin_output(ctx, fb, info);
    if (rc != VDEC2_OK) return rc;
    h264vt_finish(d->core);
    return emit_picture(ctx, d, fb, info);
}
void shim_sceVideodec2Flush(GuestContext *ctx) { VDEC2_WITH_DECODER(vdec2_Flush); }

// int sceVideodec2Reset(SceVideodec2Decoder decoder)
static int32_t vdec2_Reset(GuestContext *ctx, Vdec2 *d) {
    (void)ctx;
    h264vt_reset(d->core);
    return VDEC2_OK;
}
void shim_sceVideodec2Reset(GuestContext *ctx) { VDEC2_WITH_DECODER(vdec2_Reset); }
