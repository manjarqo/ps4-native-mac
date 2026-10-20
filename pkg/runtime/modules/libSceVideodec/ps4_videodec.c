// libSceVideodec (H.264/AVC) on top of the shared VideoToolbox core (ps4_h264_vt.c).
//
// The guest feeds Annex-B access units; the core decodes them in display order (the movies use
// B-frames). Decoded pictures are queued and handed out one per Decode/Flush call as linear
// NV12 (pitch = align(width, 64), height = align(height, 16)), matching what shadPS4 returns.
// Struct layouts follow shadPS4 videodec.
#include "recomp_runtime.h"
#include "ps4_h264_vt.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define VIDEODEC_ERROR_API_FAIL          ((int32_t)0x80C10000)
#define VIDEODEC_ERROR_HANDLE            ((int32_t)0x80C10003)
#define VIDEODEC_ERROR_ARGUMENT_POINTER  ((int32_t)0x80C1000F)
#define VIDEODEC_ERROR_AU_POINTER        ((int32_t)0x80C1000A)
#define VIDEODEC_ERROR_AU_SIZE           ((int32_t)0x80C1000B)
#define VIDEODEC_ERROR_FRAME_BUFFER_SIZE ((int32_t)0x80C10008)

typedef struct VideodecConfigInfo {
    uint64_t thisSize;
    uint32_t codecType;
    uint32_t profile;
    uint32_t maxLevel;
    int32_t maxFrameWidth;
    int32_t maxFrameHeight;
    int32_t maxDpbFrameCount;
    uint64_t videodecFlags;
} VideodecConfigInfo;

typedef struct VideodecResourceInfo {
    uint64_t thisSize;
    uint64_t cpuMemorySize;
    uint64_t pCpuMemory;
    uint64_t cpuGpuMemorySize;
    uint64_t pCpuGpuMemory;
    uint64_t maxFrameBufferSize;
    uint32_t frameBufferAlignment;
    uint32_t reserved0;
} VideodecResourceInfo;

typedef struct VideodecCtrl {
    uint64_t thisSize;
    uint64_t handle;
    uint64_t version;
} VideodecCtrl;

typedef struct VideodecFrameBuffer {
    uint64_t thisSize;
    uint64_t pFrameBuffer;
    uint64_t frameBufferSize;
} VideodecFrameBuffer;

typedef struct VideodecInputData {
    uint64_t thisSize;
    uint64_t pAuData;
    uint64_t auSize;
    uint64_t ptsData;
    uint64_t dtsData;
    uint64_t attachedData;
} VideodecInputData;

typedef struct VideodecAvcInfo {
    uint32_t numUnitsInTick;
    uint32_t timeScale;
    uint8_t fixedFrameRateFlag;
    uint8_t aspectRatioIdc;
    uint16_t sarWidth;
    uint16_t sarHeight;
    uint8_t colourPrimaries;
    uint8_t transferCharacteristics;
    uint8_t matrixCoefficients;
    uint8_t videoFullRangeFlag;
    uint32_t frameCropLeftOffset;
    uint32_t frameCropRightOffset;
    uint32_t frameCropTopOffset;
    uint32_t frameCropBottomOffset;
} VideodecAvcInfo;

typedef struct VideodecPictureInfo {
    uint64_t thisSize;
    uint32_t isValid;
    uint32_t codecType;
    uint32_t frameWidth;
    uint32_t framePitch;
    uint32_t frameHeight;
    uint32_t isErrorPic;
    uint64_t ptsData;
    uint64_t attachedData;
    union {
        uint8_t reserved[64];
        VideodecAvcInfo avc;
    } codec;
} VideodecPictureInfo;

#define VIDEODEC_MEM_SIZE 0x10000ULL

void ps4_gnm_notify_cpu_write(uint64_t addr, uint64_t size) __attribute__((weak));

static inline uint32_t align_up(uint32_t v, uint32_t a) { return (v + a - 1) & ~(a - 1); }

static void videodec_mark_no_picture(GuestContext *ctx, uint64_t pic_info) {
    if (pic_info) ((VideodecPictureInfo *)(ctx->mem_base + pic_info))->isValid = 0;
}

typedef struct Vdec {
    uint32_t magic;
    H264VtDecoder *core;
    uint64_t frames_out;
} Vdec;

#define VDEC_MAGIC 0x56444543u /* "VDEC" */

// Copy a decoded picture into the guest frame buffer and fill the picture info.
static int32_t vdec_emit(GuestContext *ctx, const H264VtFrame *f, uint64_t fb_addr, uint64_t pic_addr) {
    VideodecFrameBuffer *fb = (VideodecFrameBuffer *)(ctx->mem_base + fb_addr);
    VideodecPictureInfo *pic = pic_addr ? (VideodecPictureInfo *)(ctx->mem_base + pic_addr) : NULL;
    const uint32_t w = f->width;
    const uint32_t h = f->height;
    const uint32_t pitch = h264vt_pitch(w);
    const uint32_t ah = h264vt_aligned_height(h);
    const uint64_t need = h264vt_nv12_size(w, h);
    if (!fb->pFrameBuffer || fb->frameBufferSize < need) {
        fprintf(stderr, "[libSceVideodec] frame buffer too small (0x%llx < 0x%llx)\n",
                (unsigned long long)fb->frameBufferSize, (unsigned long long)need);
        return VIDEODEC_ERROR_FRAME_BUFFER_SIZE;
    }
    h264vt_copy_nv12(f, ctx->mem_base + fb->pFrameBuffer);
    if (ps4_gnm_notify_cpu_write) ps4_gnm_notify_cpu_write(fb->pFrameBuffer, need);
    if (pic) {
        memset(&pic->codec, 0, sizeof(pic->codec));
        pic->isValid = 1;
        pic->codecType = 0;
        pic->frameWidth = align_up(w, 16);
        pic->framePitch = pitch;
        pic->frameHeight = ah;
        pic->isErrorPic = 0;
        pic->ptsData = (uint64_t)f->pts;
        pic->attachedData = f->attached;
        pic->codec.avc.colourPrimaries = 1;
        pic->codec.avc.transferCharacteristics = 1;
        pic->codec.avc.matrixCoefficients = 1;
        pic->codec.avc.frameCropRightOffset = pitch - w;
        pic->codec.avc.frameCropBottomOffset = ah - h;
    }
    return 0;
}

static Vdec *vdec_from_ctrl(GuestContext *ctx, uint64_t ctrl_addr) {
    if (!ctrl_addr) return NULL;
    Vdec *d = (Vdec *)(uintptr_t)((VideodecCtrl *)(ctx->mem_base + ctrl_addr))->handle;
    return (d && d->magic == VDEC_MAGIC) ? d : NULL;
}

// int sceVideodecQueryResourceInfo(const SceVideodecConfigInfo *cfg, SceVideodecResourceInfo *rsrc)
void shim_sceVideodecQueryResourceInfo(GuestContext *ctx) {
    if (!ctx->rdi || !ctx->rsi) {
        ctx->rax = (uint64_t)(int64_t)VIDEODEC_ERROR_ARGUMENT_POINTER;
        SHIM_RETURN();
    }
    const VideodecConfigInfo *cfg = (const VideodecConfigInfo *)(ctx->mem_base + ctx->rdi);
    VideodecResourceInfo *ri = (VideodecResourceInfo *)(ctx->mem_base + ctx->rsi);
    uint64_t w = cfg->maxFrameWidth > 0 ? (uint64_t)cfg->maxFrameWidth : 1920;
    uint64_t h = cfg->maxFrameHeight > 0 ? (uint64_t)cfg->maxFrameHeight : 1088;
    uint64_t pitch = (w + 255) & ~255ULL;
    uint64_t fb = (pitch * ((h + 15) & ~15ULL) * 3) / 2; // NV12
    ri->thisSize = sizeof(*ri);
    ri->cpuMemorySize = VIDEODEC_MEM_SIZE;
    ri->pCpuMemory = 0;
    ri->cpuGpuMemorySize = VIDEODEC_MEM_SIZE;
    ri->pCpuGpuMemory = 0;
    ri->maxFrameBufferSize = (fb + 0xFFFF) & ~0xFFFFULL;
    ri->frameBufferAlignment = 0x100;
    ri->reserved0 = 0;
    ctx->rax = 0;
    SHIM_RETURN();
}

// int sceVideodecCreateDecoder(const SceVideodecConfigInfo *cfg, const SceVideodecResourceInfo *rsrc,
//                              SceVideodecCtrl *ctrl)
void shim_sceVideodecCreateDecoder(GuestContext *ctx) {
    if (!ctx->rdi || !ctx->rsi || !ctx->rdx) {
        ctx->rax = (uint64_t)(int64_t)VIDEODEC_ERROR_ARGUMENT_POINTER;
        SHIM_RETURN();
    }
    VideodecCtrl *c = (VideodecCtrl *)(ctx->mem_base + ctx->rdx);
    Vdec *d = (Vdec *)calloc(1, sizeof(Vdec));
    if (d) d->core = h264vt_create("libSceVideodec");
    if (!d || !d->core) {
        free(d);
        ctx->rax = (uint64_t)(int64_t)VIDEODEC_ERROR_API_FAIL;
        SHIM_RETURN();
    }
    d->magic = VDEC_MAGIC;
    c->handle = (uint64_t)(uintptr_t)d;
    c->version = 0;
    ctx->rax = 0;
    SHIM_RETURN();
}

// int sceVideodecDecode(SceVideodecCtrl *ctrl, const SceVideodecInputData *in,
//                       SceVideodecFrameBuffer *fb, SceVideodecPictureInfo *pic)
void shim_sceVideodecDecode(GuestContext *ctx) {
    videodec_mark_no_picture(ctx, ctx->rcx);
    Vdec *d = vdec_from_ctrl(ctx, ctx->rdi);
    if (!d) {
        ctx->rax = (uint64_t)(int64_t)VIDEODEC_ERROR_HANDLE;
        SHIM_RETURN();
    }
    if (!ctx->rsi || !ctx->rdx) {
        ctx->rax = (uint64_t)(int64_t)VIDEODEC_ERROR_ARGUMENT_POINTER;
        SHIM_RETURN();
    }
    const VideodecInputData *in = (const VideodecInputData *)(ctx->mem_base + ctx->rsi);
    if (!in->pAuData) {
        ctx->rax = (uint64_t)(int64_t)VIDEODEC_ERROR_AU_POINTER;
        SHIM_RETURN();
    }
    if (in->auSize == 0) {
        ctx->rax = (uint64_t)(int64_t)VIDEODEC_ERROR_AU_SIZE;
        SHIM_RETURN();
    }
    // A failed access unit is logged by the core; like before the refactor, Decode still hands
    // out a picture decoded earlier and reports success.
    h264vt_decode(d->core, ctx->mem_base + in->pAuData, (size_t)in->auSize, (int64_t)in->ptsData,
                  (int64_t)in->dtsData, in->attachedData, NULL);
    int32_t rc = 0;
    H264VtFrame *f = h264vt_pop(d->core);
    if (f) {
        rc = vdec_emit(ctx, f, ctx->rdx, ctx->rcx);
        if (d->frames_out++ == 0) fprintf(stderr, "[libSceVideodec] first picture decoded\n");
        h264vt_frame_free(f);
    }
    ctx->rax = (uint64_t)(int64_t)rc;
    SHIM_RETURN();
}

// int sceVideodecFlush(SceVideodecCtrl *ctrl, SceVideodecFrameBuffer *fb, SceVideodecPictureInfo *pic)
// Drains delayed pictures, one per call.
void shim_sceVideodecFlush(GuestContext *ctx) {
    if (!ctx->rdi) {
        ctx->rax = (uint64_t)(int64_t)VIDEODEC_ERROR_ARGUMENT_POINTER;
        SHIM_RETURN();
    }
    videodec_mark_no_picture(ctx, ctx->rdx);
    int32_t rc = 0;
    Vdec *d = vdec_from_ctrl(ctx, ctx->rdi);
    if (d) {
        h264vt_finish(d->core);
        H264VtFrame *f = ctx->rsi ? h264vt_pop(d->core) : NULL;
        if (f) {
            rc = vdec_emit(ctx, f, ctx->rsi, ctx->rdx);
            h264vt_frame_free(f);
        }
    }
    ctx->rax = (uint64_t)(int64_t)rc;
    SHIM_RETURN();
}

// int sceVideodecReset(SceVideodecCtrl *ctrl)
void shim_sceVideodecReset(GuestContext *ctx) {
    if (!ctx->rdi) {
        ctx->rax = (uint64_t)(int64_t)VIDEODEC_ERROR_ARGUMENT_POINTER;
        SHIM_RETURN();
    }
    Vdec *d = vdec_from_ctrl(ctx, ctx->rdi);
    if (d) h264vt_reset(d->core);
    ctx->rax = 0;
    SHIM_RETURN();
}

// int sceVideodecDeleteDecoder(SceVideodecCtrl *ctrl)
void shim_sceVideodecDeleteDecoder(GuestContext *ctx) {
    if (!ctx->rdi) {
        ctx->rax = (uint64_t)(int64_t)VIDEODEC_ERROR_ARGUMENT_POINTER;
        SHIM_RETURN();
    }
    Vdec *d = vdec_from_ctrl(ctx, ctx->rdi);
    if (d) {
        d->magic = 0;
        h264vt_destroy(d->core);
        free(d);
    }
    ((VideodecCtrl *)(ctx->mem_base + ctx->rdi))->handle = 0;
    ctx->rax = 0;
    SHIM_RETURN();
}
