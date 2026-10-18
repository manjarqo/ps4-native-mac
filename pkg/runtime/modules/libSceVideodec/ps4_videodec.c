// libSceVideodec (H.264/AVC) on top of VideoToolbox.
//
// The guest feeds Annex-B access units; SPS/PPS are pulled out of the stream to build the
// format description, the remaining NAL units are re-packed as AVCC samples and decoded
// with temporal processing enabled so VideoToolbox emits pictures in display order (the
// movies use B-frames). Decoded pictures are queued and handed out one per Decode/Flush
// call as linear NV12 (pitch = align(width, 64), height = align(height, 16)), matching
// what shadPS4 returns. Struct layouts follow shadPS4 videodec.
#include "recomp_runtime.h"
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#if defined(__APPLE__)
#include <CoreMedia/CoreMedia.h>
#include <CoreVideo/CoreVideo.h>
#include <VideoToolbox/VideoToolbox.h>
#define VIDEODEC_HAVE_VT 1
#endif

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

#if VIDEODEC_HAVE_VT
typedef struct VdecFrame {
    CVPixelBufferRef pb;
    int64_t pts;
    uint64_t attached;
    struct VdecFrame *next;
} VdecFrame;

typedef struct Vdec {
    uint32_t magic;
    VTDecompressionSessionRef session;
    CMVideoFormatDescriptionRef fmt;
    uint8_t sps[512];
    size_t sps_len;
    uint8_t pps[512];
    size_t pps_len;
    bool params_dirty;
    pthread_mutex_t lock;
    VdecFrame *head;
    VdecFrame *tail;
    int queued;
    uint8_t *avcc;
    size_t avcc_cap;
    uint64_t frames_out;
} Vdec;

#define VDEC_MAGIC 0x56444543u /* "VDEC" */

static void vdec_output_cb(void *refcon, void *frame_refcon, OSStatus status, VTDecodeInfoFlags flags,
                           CVImageBufferRef image, CMTime pts, CMTime duration) {
    (void)flags;
    (void)duration;
    Vdec *d = (Vdec *)refcon;
    if (status != noErr || !image) {
        static int warned;
        if (warned++ < 8) fprintf(stderr, "[libSceVideodec] decode error %d\n", (int)status);
        return;
    }
    VdecFrame *f = (VdecFrame *)calloc(1, sizeof(*f));
    if (!f) return;
    f->pb = CVPixelBufferRetain(image);
    f->pts = CMTIME_IS_VALID(pts) ? pts.value : 0;
    f->attached = (uint64_t)(uintptr_t)frame_refcon;
    pthread_mutex_lock(&d->lock);
    if (d->tail) d->tail->next = f;
    else d->head = f;
    d->tail = f;
    d->queued++;
    pthread_mutex_unlock(&d->lock);
}

static VdecFrame *vdec_pop(Vdec *d) {
    pthread_mutex_lock(&d->lock);
    VdecFrame *f = d->head;
    if (f) {
        d->head = f->next;
        if (!d->head) d->tail = NULL;
        d->queued--;
    }
    pthread_mutex_unlock(&d->lock);
    return f;
}

static void vdec_free_frame(VdecFrame *f) {
    if (!f) return;
    if (f->pb) CVPixelBufferRelease(f->pb);
    free(f);
}

static void vdec_drop_queue(Vdec *d) {
    VdecFrame *f;
    while ((f = vdec_pop(d)) != NULL) vdec_free_frame(f);
}

static void vdec_destroy_session(Vdec *d) {
    if (d->session) {
        VTDecompressionSessionFinishDelayedFrames(d->session);
        VTDecompressionSessionWaitForAsynchronousFrames(d->session);
        VTDecompressionSessionInvalidate(d->session);
        CFRelease(d->session);
        d->session = NULL;
    }
    if (d->fmt) {
        CFRelease(d->fmt);
        d->fmt = NULL;
    }
}

static bool vdec_create_session(Vdec *d) {
    const uint8_t *sets[2] = {d->sps, d->pps};
    const size_t sizes[2] = {d->sps_len, d->pps_len};
    CMVideoFormatDescriptionRef fmt = NULL;
    OSStatus st = CMVideoFormatDescriptionCreateFromH264ParameterSets(kCFAllocatorDefault, 2, sets, sizes, 4, &fmt);
    if (st != noErr) {
        fprintf(stderr, "[libSceVideodec] CMVideoFormatDescriptionCreateFromH264ParameterSets failed: %d\n", (int)st);
        return false;
    }
    if (d->session && d->fmt && VTDecompressionSessionCanAcceptFormatDescription(d->session, fmt)) {
        CFRelease(d->fmt);
        d->fmt = fmt;
        return true;
    }
    vdec_destroy_session(d);
    d->fmt = fmt;

    int32_t pixfmt = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange;
    CFNumberRef pf = CFNumberCreate(kCFAllocatorDefault, kCFNumberSInt32Type, &pixfmt);
    const void *keys[] = {kCVPixelBufferPixelFormatTypeKey};
    const void *vals[] = {pf};
    CFDictionaryRef attrs = CFDictionaryCreate(kCFAllocatorDefault, keys, vals, 1, &kCFTypeDictionaryKeyCallBacks,
                                               &kCFTypeDictionaryValueCallBacks);
    CFRelease(pf);
    VTDecompressionOutputCallbackRecord cb = {vdec_output_cb, d};
    st = VTDecompressionSessionCreate(kCFAllocatorDefault, d->fmt, NULL, attrs, &cb, &d->session);
    CFRelease(attrs);
    if (st != noErr) {
        fprintf(stderr, "[libSceVideodec] VTDecompressionSessionCreate failed: %d\n", (int)st);
        d->session = NULL;
        return false;
    }
    CMVideoDimensions dim = CMVideoFormatDescriptionGetDimensions(d->fmt);
    fprintf(stderr, "[libSceVideodec] VideoToolbox H.264 session %dx%d\n", dim.width, dim.height);
    return true;
}

// Copy a decoded picture into the guest frame buffer and fill the picture info.
static int32_t vdec_emit(GuestContext *ctx, VdecFrame *f, uint64_t fb_addr, uint64_t pic_addr) {
    VideodecFrameBuffer *fb = (VideodecFrameBuffer *)(ctx->mem_base + fb_addr);
    VideodecPictureInfo *pic = pic_addr ? (VideodecPictureInfo *)(ctx->mem_base + pic_addr) : NULL;
    CVPixelBufferRef pb = f->pb;
    const uint32_t w = (uint32_t)CVPixelBufferGetWidth(pb);
    const uint32_t h = (uint32_t)CVPixelBufferGetHeight(pb);
    const uint32_t pitch = align_up(w, 64);
    const uint32_t ah = align_up(h, 16);
    const uint64_t need = (uint64_t)pitch * ah * 3 / 2;
    if (!fb->pFrameBuffer || fb->frameBufferSize < need) {
        fprintf(stderr, "[libSceVideodec] frame buffer too small (0x%llx < 0x%llx)\n",
                (unsigned long long)fb->frameBufferSize, (unsigned long long)need);
        return VIDEODEC_ERROR_FRAME_BUFFER_SIZE;
    }
    uint8_t *dst = ctx->mem_base + fb->pFrameBuffer;
    uint8_t *dst_c = dst + (uint64_t)pitch * ah;
    CVPixelBufferLockBaseAddress(pb, kCVPixelBufferLock_ReadOnly);
    const uint8_t *y = (const uint8_t *)CVPixelBufferGetBaseAddressOfPlane(pb, 0);
    const uint8_t *c = (const uint8_t *)CVPixelBufferGetBaseAddressOfPlane(pb, 1);
    const size_t ys = CVPixelBufferGetBytesPerRowOfPlane(pb, 0);
    const size_t cs = CVPixelBufferGetBytesPerRowOfPlane(pb, 1);
    for (uint32_t r = 0; r < ah; r++) memcpy(dst + (uint64_t)r * pitch, y + (size_t)(r < h ? r : h - 1) * ys, w);
    for (uint32_t r = 0; r < ah / 2; r++)
        memcpy(dst_c + (uint64_t)r * pitch, c + (size_t)(r < h / 2 ? r : h / 2 - 1) * cs, w);
    CVPixelBufferUnlockBaseAddress(pb, kCVPixelBufferLock_ReadOnly);
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

static bool vdec_append_nal(Vdec *d, size_t *len, const uint8_t *nal, size_t n) {
    if (*len + n + 4 > d->avcc_cap) {
        size_t cap = (*len + n + 4) * 2;
        uint8_t *p = (uint8_t *)realloc(d->avcc, cap);
        if (!p) return false;
        d->avcc = p;
        d->avcc_cap = cap;
    }
    uint8_t *o = d->avcc + *len;
    o[0] = (uint8_t)(n >> 24);
    o[1] = (uint8_t)(n >> 16);
    o[2] = (uint8_t)(n >> 8);
    o[3] = (uint8_t)n;
    memcpy(o + 4, nal, n);
    *len += n + 4;
    return true;
}

// Position of the next 00 00 01 start code at or after i (size if none).
static size_t next_start(const uint8_t *p, size_t i, size_t size) {
    while (i + 3 <= size) {
        if (p[i] == 0 && p[i + 1] == 0 && p[i + 2] == 1) return i;
        i++;
    }
    return size;
}

// Splits the Annex-B access unit, records SPS/PPS and returns the length of the AVCC
// sample (in d->avcc) holding the other NAL units.
static size_t vdec_parse_au(Vdec *d, const uint8_t *au, size_t size) {
    size_t out = 0;
    size_t sc = next_start(au, 0, size);
    while (sc < size) {
        size_t s = sc + 3;
        size_t nsc = next_start(au, s, size);
        size_t e = nsc;
        while (e > s && au[e - 1] == 0) e--; // zero bytes before the next start code
        size_t n = e - s;
        if (n > 0) {
            uint8_t type = au[s] & 0x1f;
            if (type == 7) {
                if (n <= sizeof(d->sps) && (n != d->sps_len || memcmp(d->sps, au + s, n) != 0)) {
                    memcpy(d->sps, au + s, n);
                    d->sps_len = n;
                    d->params_dirty = true;
                }
            } else if (type == 8) {
                if (n <= sizeof(d->pps) && (n != d->pps_len || memcmp(d->pps, au + s, n) != 0)) {
                    memcpy(d->pps, au + s, n);
                    d->pps_len = n;
                    d->params_dirty = true;
                }
            } else if (type != 9 && type != 10 && type != 11) {
                vdec_append_nal(d, &out, au + s, n);
            }
        }
        sc = nsc;
    }
    return out;
}
#endif // VIDEODEC_HAVE_VT

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
#if VIDEODEC_HAVE_VT
    Vdec *d = (Vdec *)calloc(1, sizeof(Vdec));
    if (!d) {
        ctx->rax = (uint64_t)(int64_t)VIDEODEC_ERROR_API_FAIL;
        SHIM_RETURN();
    }
    d->magic = VDEC_MAGIC;
    pthread_mutex_init(&d->lock, NULL);
    c->handle = (uint64_t)(uintptr_t)d;
#else
    c->handle = 0x5644454300000001ULL;
#endif
    c->version = 0;
    ctx->rax = 0;
    SHIM_RETURN();
}

// int sceVideodecDecode(SceVideodecCtrl *ctrl, const SceVideodecInputData *in,
//                       SceVideodecFrameBuffer *fb, SceVideodecPictureInfo *pic)
void shim_sceVideodecDecode(GuestContext *ctx) {
    videodec_mark_no_picture(ctx, ctx->rcx);
#if VIDEODEC_HAVE_VT
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
    size_t len = vdec_parse_au(d, ctx->mem_base + in->pAuData, (size_t)in->auSize);
    if (d->params_dirty && d->sps_len && d->pps_len) {
        d->params_dirty = false;
        vdec_create_session(d);
    }
    if (d->session && len) {
        CMBlockBufferRef bb = NULL;
        OSStatus st = CMBlockBufferCreateWithMemoryBlock(kCFAllocatorDefault, NULL, len, kCFAllocatorDefault, NULL,
                                                         0, len, kCMBlockBufferAssureMemoryNowFlag, &bb);
        if (st == noErr) st = CMBlockBufferReplaceDataBytes(d->avcc, bb, 0, len);
        CMSampleBufferRef sb = NULL;
        if (st == noErr) {
            CMSampleTimingInfo timing = {kCMTimeInvalid, CMTimeMake((int64_t)in->ptsData, 90000),
                                         CMTimeMake((int64_t)in->dtsData, 90000)};
            const size_t ssz = len;
            st = CMSampleBufferCreateReady(kCFAllocatorDefault, bb, d->fmt, 1, 1, &timing, 1, &ssz, &sb);
        }
        if (st == noErr) {
            VTDecodeInfoFlags info = 0;
            st = VTDecompressionSessionDecodeFrame(d->session, sb, kVTDecodeFrame_EnableTemporalProcessing,
                                                   (void *)(uintptr_t)in->attachedData, &info);
            if (st != noErr) {
                static int warned;
                if (warned++ < 8) fprintf(stderr, "[libSceVideodec] VTDecompressionSessionDecodeFrame: %d\n", (int)st);
            }
        }
        if (sb) CFRelease(sb);
        if (bb) CFRelease(bb);
    }
    int32_t rc = 0;
    VdecFrame *f = vdec_pop(d);
    if (f) {
        rc = vdec_emit(ctx, f, ctx->rdx, ctx->rcx);
        if (d->frames_out++ == 0) fprintf(stderr, "[libSceVideodec] first picture decoded\n");
        vdec_free_frame(f);
    }
    ctx->rax = (uint64_t)(int64_t)rc;
#else
    ctx->rax = ctx->rdi ? (uint64_t)(int64_t)VIDEODEC_ERROR_API_FAIL : (uint64_t)(int64_t)VIDEODEC_ERROR_HANDLE;
#endif
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
#if VIDEODEC_HAVE_VT
    Vdec *d = vdec_from_ctrl(ctx, ctx->rdi);
    if (d) {
        if (d->session) {
            VTDecompressionSessionFinishDelayedFrames(d->session);
            VTDecompressionSessionWaitForAsynchronousFrames(d->session);
        }
        VdecFrame *f = ctx->rsi ? vdec_pop(d) : NULL;
        if (f) {
            rc = vdec_emit(ctx, f, ctx->rsi, ctx->rdx);
            vdec_free_frame(f);
        }
    }
#endif
    ctx->rax = (uint64_t)(int64_t)rc;
    SHIM_RETURN();
}

// int sceVideodecReset(SceVideodecCtrl *ctrl)
void shim_sceVideodecReset(GuestContext *ctx) {
    if (!ctx->rdi) {
        ctx->rax = (uint64_t)(int64_t)VIDEODEC_ERROR_ARGUMENT_POINTER;
        SHIM_RETURN();
    }
#if VIDEODEC_HAVE_VT
    Vdec *d = vdec_from_ctrl(ctx, ctx->rdi);
    if (d) {
        if (d->session) {
            VTDecompressionSessionFinishDelayedFrames(d->session);
            VTDecompressionSessionWaitForAsynchronousFrames(d->session);
        }
        vdec_drop_queue(d);
    }
#endif
    ctx->rax = 0;
    SHIM_RETURN();
}

// int sceVideodecDeleteDecoder(SceVideodecCtrl *ctrl)
void shim_sceVideodecDeleteDecoder(GuestContext *ctx) {
    if (!ctx->rdi) {
        ctx->rax = (uint64_t)(int64_t)VIDEODEC_ERROR_ARGUMENT_POINTER;
        SHIM_RETURN();
    }
#if VIDEODEC_HAVE_VT
    Vdec *d = vdec_from_ctrl(ctx, ctx->rdi);
    if (d) {
        vdec_destroy_session(d);
        vdec_drop_queue(d);
        d->magic = 0;
        free(d->avcc);
        pthread_mutex_destroy(&d->lock);
        free(d);
    }
#endif
    ((VideodecCtrl *)(ctx->mem_base + ctx->rdi))->handle = 0;
    ctx->rax = 0;
    SHIM_RETURN();
}
