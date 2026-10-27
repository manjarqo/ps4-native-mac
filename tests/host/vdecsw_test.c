// SPDX-License-Identifier: GPL-2.0-or-later
//
// Host test of libSceVdecsw and libSceVideodec on the shared VideoToolbox H.264 core.
//
// The test makes its own H.264 streams with VideoToolbox's encoder (High profile): flat frames
// whose luma encodes the display index (top half: index % 30, bottom half: index / 30), at a
// size that is not a multiple of 16 in height (so cropping and padding are exercised). The
// samples become Annex-B access units (AUD, SPS/PPS before key frames, 00 00 00 01 start codes)
// as U4's player builds them, and are fed through the guest API on a fake guest memory in U4's
// call order (QueryComputeMemoryInfo, AllocateComputeQueue, QueryDecoderMemoryInfo,
// CreateDecoder, SetDecodeInput / TrySyncDecodeInput / SetDecodeOutput / TrySyncDecodeOutput /
// GetAvcPictureInfo, FinalizeDecodeSequence, ResetDecoder, DeleteDecoder).
//
// Streams: S1 B-frames, one IDR; S2 no reordering, IDR every 10 frames (zero delay); S3
// B-frames, IDR every 10 frames (flush at each IDR); S4 B-frames, 120 frames, one IDR (POC lsb
// wraps). Also: corrupt access units, a stream without parameter sets and a rejected SPS (error
// pictures, one picture per access unit), a too-small output buffer, guest ranges that wrap
// around, two decoders interleaved, DeleteDecoder racing calls on another thread, stale handles,
// and libSceVideodec. S5 (640x368, software encoder) has 5 slices per picture: it checks the
// access-unit census (h264_au_census) and libSceVideodec's per-decoder counts
// (ps4_videodec_stats). With the local fixture given as argv[1] (inFAMOUS's
// splash_europe.bsf, game data, git-ignored), the movie is split into access units, fed through
// libSceVideodec and must give 309 pictures in display order.
#include "recomp_runtime.h"
#include "ps4_h264_vt.h"
#include "ps4_videodec.h"

#include <CoreMedia/CoreMedia.h>
#include <CoreVideo/CoreVideo.h>
#include <VideoToolbox/VideoToolbox.h>
#include <dirent.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

void shim_sceVdecswQueryComputeMemoryInfo(GuestContext *ctx);
void shim_sceVdecswAllocateComputeQueue(GuestContext *ctx);
void shim_sceVdecswReleaseComputeQueue(GuestContext *ctx);
void shim_sceVdecswQueryDecoderMemoryInfo(GuestContext *ctx);
void shim_sceVdecswCreateDecoder(GuestContext *ctx);
void shim_sceVdecswDeleteDecoder(GuestContext *ctx);
void shim_sceVdecswResetDecoder(GuestContext *ctx);
void shim_sceVdecswSetDecodeInput(GuestContext *ctx);
void shim_sceVdecswTrySyncDecodeInput(GuestContext *ctx);
void shim_sceVdecswSetDecodeOutput(GuestContext *ctx);
void shim_sceVdecswTrySyncDecodeOutput(GuestContext *ctx);
void shim_sceVdecswFinalizeDecodeSequence(GuestContext *ctx);
void shim_sceVdecswGetAvcPictureInfo(GuestContext *ctx);
void shim_sceVideodecQueryResourceInfo(GuestContext *ctx);
void shim_sceVideodecCreateDecoder(GuestContext *ctx);
void shim_sceVideodecDecode(GuestContext *ctx);
void shim_sceVideodecFlush(GuestContext *ctx);
void shim_sceVideodecReset(GuestContext *ctx);
void shim_sceVideodecDeleteDecoder(GuestContext *ctx);

#define W 352
#define H 200
#define MAXN 120
#define PITCH 384 // align(352, 64)
#define AH 208    // align(200, 16)
#define FRAME_SIZE (PITCH * AH * 3 / 2)
#define AU_BUF 0x40000

#define E_STRUCT_SIZE ((int32_t)0x81510101)
#define E_DECODER_INSTANCE ((int32_t)0x81510103)
#define E_FRAME_BUFFER_SIZE ((int32_t)0x81510106)
#define E_AU_SIZE ((int32_t)0x8151010D)
#define E_INPUT_QUEUE_FULL ((int32_t)0x81510113)
#define E_OUTPUT_BUFFER_FULL ((int32_t)0x81510114)
#define E_INPUT_QUEUE_EMPTY ((int32_t)0x81510116)
#define E_DECODE_PENDING ((int32_t)0x81510117)
#define E_OUTPUT_BUFFER_EMPTY ((int32_t)0x81510118)
#define E_CODEC_TYPE ((int32_t)0x81510204)

// The GPU write hook of the runtime: records the last range so the test can check it.
static uint64_t g_notify_addr, g_notify_size;
void ps4_gnm_notify_cpu_write(uint64_t addr, uint64_t size) {
    g_notify_addr = addr;
    g_notify_size = size;
}

static atomic_int failures;
#define CHECK(cond, ...)                                                                       \
    do {                                                                                       \
        if (!(cond)) {                                                                         \
            atomic_fetch_add(&failures, 1);                                                    \
            fprintf(stderr, "FAIL %s:%d: %s: ", __FILE__, __LINE__, #cond);                    \
            fprintf(stderr, __VA_ARGS__);                                                      \
            fprintf(stderr, "\n");                                                             \
            if (atomic_load(&failures) > 40) exit(1);                                          \
        }                                                                                      \
    } while (0)

static int level_top(int i) { return 40 + 5 * (i % 30); }
static int level_bottom(int i) { return 40 + 40 * (i / 30); }

// ---------------------------------------------------------------------------------------------
// Test streams
// ---------------------------------------------------------------------------------------------

typedef struct Au {
    uint8_t *data;
    size_t size;
    int display; // presentation index
    bool key;
} Au;

typedef struct Stream {
    const char *name;
    Au aus[MAXN];
    int count;
    uint8_t sps[256], pps[256];
    size_t sps_len, pps_len;
    int keys, reordered;
    uint32_t max_slices; // most slices in one access unit (census)
} Stream;

static pthread_mutex_t g_enc_lock = PTHREAD_MUTEX_INITIALIZER;

static void put(uint8_t **buf, size_t *len, const void *p, size_t n) {
    *buf = (uint8_t *)realloc(*buf, *len + n);
    memcpy(*buf + *len, p, n);
    *len += n;
}

static void put_nal(uint8_t **buf, size_t *len, const uint8_t *nal, size_t n) {
    static const uint8_t sc[4] = {0, 0, 0, 1};
    put(buf, len, sc, 4);
    put(buf, len, nal, n);
}

static void enc_cb(void *refcon, void *frame_refcon, OSStatus status, VTEncodeInfoFlags flags, CMSampleBufferRef sb) {
    (void)frame_refcon, (void)flags;
    Stream *st = (Stream *)refcon;
    if (status != noErr || !sb) {
        fprintf(stderr, "encoder error %d\n", (int)status);
        exit(1);
    }
    CMFormatDescriptionRef fmt = CMSampleBufferGetFormatDescription(sb);
    int nal_len_size = 4;
    size_t count = 0;
    const uint8_t *ps;
    size_t psz;
    pthread_mutex_lock(&g_enc_lock);
    if (CMVideoFormatDescriptionGetH264ParameterSetAtIndex(fmt, 0, &ps, &psz, &count, &nal_len_size) == noErr) {
        memcpy(st->sps, ps, psz);
        st->sps_len = psz;
    }
    if (CMVideoFormatDescriptionGetH264ParameterSetAtIndex(fmt, 1, &ps, &psz, NULL, NULL) == noErr) {
        memcpy(st->pps, ps, psz);
        st->pps_len = psz;
    }
    bool key = true;
    CFArrayRef att = CMSampleBufferGetSampleAttachmentsArray(sb, false);
    if (att && CFArrayGetCount(att) > 0) {
        CFDictionaryRef d = (CFDictionaryRef)CFArrayGetValueAtIndex(att, 0);
        CFBooleanRef ns = (CFBooleanRef)CFDictionaryGetValue(d, kCMSampleAttachmentKey_NotSync);
        key = !(ns && CFBooleanGetValue(ns));
    }
    CMBlockBufferRef bb = CMSampleBufferGetDataBuffer(sb);
    size_t total = CMBlockBufferGetDataLength(bb);
    uint8_t *raw = (uint8_t *)malloc(total);
    CMBlockBufferCopyDataBytes(bb, 0, total, raw);
    Au *au = &st->aus[st->count++];
    static const uint8_t aud[2] = {0x09, 0xF0};
    put_nal(&au->data, &au->size, aud, sizeof(aud));
    if (key) {
        put_nal(&au->data, &au->size, st->sps, st->sps_len);
        put_nal(&au->data, &au->size, st->pps, st->pps_len);
    }
    for (size_t o = 0; o + (size_t)nal_len_size <= total;) {
        size_t n = 0;
        for (int k = 0; k < nal_len_size; k++) n = (n << 8) | raw[o + k];
        o += (size_t)nal_len_size;
        put_nal(&au->data, &au->size, raw + o, n);
        o += n;
    }
    free(raw);
    au->display = (int)CMSampleBufferGetPresentationTimeStamp(sb).value;
    au->key = key;
    pthread_mutex_unlock(&g_enc_lock);
}

// Encoder options beyond the defaults of make_stream (352x200, default encoder).
// kVTCompressionPropertyKey_MaxH264SliceBytes is refused by both encoders of the macOS this was
// written on (kVTPropertyNotSupportedErr), but Apple's software encoder cuts a 640x368 picture
// into 5 slices by itself; the hardware encoder makes one. The slice count is checked where the
// stream is used (test_au_census), so the test never runs on single-slice pictures.
typedef struct StreamOpts {
    int w, h;
    bool software; // kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder = false
} StreamOpts;

static void make_stream_opts(Stream *st, const char *name, int n, int gop, bool reorder, const StreamOpts *o) {
    memset(st, 0, sizeof(*st));
    st->name = name;
    const int w = o->w, h = o->h;
    VTCompressionSessionRef s = NULL;
    CFMutableDictionaryRef spec = NULL;
    if (o->software) {
        spec = CFDictionaryCreateMutable(NULL, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
        CFDictionarySetValue(spec, kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder, kCFBooleanFalse);
    }
    OSStatus rc = VTCompressionSessionCreate(NULL, w, h, kCMVideoCodecType_H264, spec, NULL, NULL, enc_cb, st, &s);
    if (spec) CFRelease(spec);
    if (rc != noErr) {
        fprintf(stderr, "VTCompressionSessionCreate: %d\n", (int)rc);
        exit(1);
    }
    VTSessionSetProperty(s, kVTCompressionPropertyKey_ProfileLevel, kVTProfileLevel_H264_High_AutoLevel);
    VTSessionSetProperty(s, kVTCompressionPropertyKey_AllowFrameReordering, reorder ? kCFBooleanTrue : kCFBooleanFalse);
    VTSessionSetProperty(s, kVTCompressionPropertyKey_RealTime, kCFBooleanFalse);
    CFNumberRef g = CFNumberCreate(NULL, kCFNumberSInt32Type, &gop);
    VTSessionSetProperty(s, kVTCompressionPropertyKey_MaxKeyFrameInterval, g);
    CFRelease(g);
    for (int i = 0; i < n; i++) {
        CVPixelBufferRef pb = NULL;
        CVPixelBufferCreate(NULL, w, h, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, NULL, &pb);
        CVPixelBufferLockBaseAddress(pb, 0);
        uint8_t *y = (uint8_t *)CVPixelBufferGetBaseAddressOfPlane(pb, 0);
        uint8_t *c = (uint8_t *)CVPixelBufferGetBaseAddressOfPlane(pb, 1);
        const size_t ys = CVPixelBufferGetBytesPerRowOfPlane(pb, 0);
        for (int r = 0; r < h; r++) memset(y + r * ys, r < h / 2 ? level_top(i) : level_bottom(i), (size_t)w);
        for (int r = 0; r < h / 2; r++) memset(c + r * CVPixelBufferGetBytesPerRowOfPlane(pb, 1), 128, (size_t)w);
        CVPixelBufferUnlockBaseAddress(pb, 0);
        rc = VTCompressionSessionEncodeFrame(s, pb, CMTimeMake(i, 30), CMTimeMake(1, 30), NULL, NULL, NULL);
        CVPixelBufferRelease(pb);
        if (rc != noErr) {
            fprintf(stderr, "VTCompressionSessionEncodeFrame: %d\n", (int)rc);
            exit(1);
        }
    }
    VTCompressionSessionCompleteFrames(s, kCMTimeInvalid);
    VTCompressionSessionInvalidate(s);
    CFRelease(s);
    for (int j = 1; j < st->count; j++)
        if (st->aus[j].display < st->aus[j - 1].display) st->reordered++;
    for (int j = 0; j < st->count; j++) st->keys += st->aus[j].key;
    H264SpsInfo sps;
    h264_parse_sps(st->sps, st->sps_len, &sps);
    fprintf(stderr,
            "stream %s: %d access units, %d key, %d out of display order, poc type %u lsb bits %u, "
            "bitstream_restriction %u reorder %u\n",
            name, st->count, st->keys, st->reordered, sps.pic_order_cnt_type, sps.log2_max_pic_order_cnt_lsb,
            sps.bitstream_restriction_flag, sps.max_num_reorder_frames);
    CHECK(st->count == n, "%s: encoder produced %d samples", name, st->count);
}

static void make_stream(Stream *st, const char *name, int n, int gop, bool reorder) {
    const StreamOpts o = {W, H, false};
    make_stream_opts(st, name, n, gop, reorder, &o);
}

// ---------------------------------------------------------------------------------------------
// Guest side
// ---------------------------------------------------------------------------------------------

static GuestContext g;
static uint64_t g_brk = 0x10000;
static pthread_mutex_t g_alloc_lock = PTHREAD_MUTEX_INITIALIZER;

static uint64_t galloc(uint64_t size, uint64_t align) {
    pthread_mutex_lock(&g_alloc_lock);
    g_brk = (g_brk + align - 1) & ~(align - 1);
    uint64_t a = g_brk;
    g_brk += size;
    uint64_t end = g_brk;
    pthread_mutex_unlock(&g_alloc_lock);
    if (end > g.mem_size) {
        fprintf(stderr, "guest memory exhausted\n");
        exit(1);
    }
    memset(g.mem_base + a, 0, size);
    return a;
}

static void *gp(uint64_t a) { return g.mem_base + a; }
static uint64_t rd64(uint64_t a) {
    uint64_t v;
    memcpy(&v, gp(a), 8);
    return v;
}
static uint32_t rd32(uint64_t a) {
    uint32_t v;
    memcpy(&v, gp(a), 4);
    return v;
}
static uint8_t rd8(uint64_t a) { return *(uint8_t *)gp(a); }
static void wr64(uint64_t a, uint64_t v) { memcpy(gp(a), &v, 8); }
static void wr32(uint64_t a, uint32_t v) { memcpy(gp(a), &v, 4); }
static void wr16(uint64_t a, uint16_t v) { memcpy(gp(a), &v, 2); }
static void wr8(uint64_t a, uint8_t v) { *(uint8_t *)gp(a) = v; }

static int32_t call_on(GuestContext *c, void (*fn)(GuestContext *), uint64_t a, uint64_t b, uint64_t cc, uint64_t d) {
    c->rdi = a;
    c->rsi = b;
    c->rdx = cc;
    c->rcx = d;
    c->rax = 0xdeadbeefdeadbeefULL;
    c->rsp = 0x8000;
    fn(c);
    if (c->rsp != 0x8008) {
        fprintf(stderr, "shim did not return through SHIM_RETURN\n");
        exit(1);
    }
    return (int32_t)c->rax;
}
static int32_t call(void (*fn)(GuestContext *), uint64_t a, uint64_t b, uint64_t c, uint64_t d) {
    return call_on(&g, fn, a, b, c, d);
}

static int luma_at(uint64_t fb, int x, int y) { return rd8(fb + (uint64_t)y * PITCH + x); }
static int luma_avg(uint64_t fb, int y0, int y1) {
    long sum = 0, n = 0;
    for (int y = y0; y < y1; y += 7)
        for (int x = 20; x < W - 20; x += 7) {
            sum += luma_at(fb, x, y);
            n++;
        }
    return (int)(sum / n);
}
// Display index shown by a decoded picture, -1 if the pixels match no frame.
static int display_of(uint64_t fb) {
    int top = luma_avg(fb, 20, H / 2 - 20), bot = luma_avg(fb, H / 2 + 20, H - 20);
    int lo = (top - 40 + 2) / 5, hi = (bot - 40 + 20) / 40;
    int i = hi * 30 + lo;
    if (lo < 0 || lo >= 30 || hi < 0 || abs(top - level_top(i)) > 3 || abs(bot - level_bottom(i)) > 3) return -1;
    return i;
}

// One guest decoder with its buffers.
typedef struct Dec {
    uint64_t handle, in, res, au_buf, fb_desc, oi, pic, fbs[2];
    int fb_next;
    bool output_set;
    uint64_t fb_size;
} Dec;

typedef struct Collected {
    int count;
    int display[MAXN];
    uint64_t attached[MAXN];
    bool error[MAXN];
    int errors;
    int last_flag_at;
} Collected;

static uint64_t g_q; // compute queue handle
static int g_expected_level_idc;

static void create_dec(Dec *d, int pipeline_depth, bool frame_buffers) {
    uint64_t cfg = galloc(0x50, 16), mem = galloc(0x48, 16), out = galloc(8, 8);
    wr64(cfg, 0x48);
    wr32(cfg + 0x08, 1);
    wr32(cfg + 0x0c, 1);
    wr32(cfg + 0x10, 100);
    wr32(cfg + 0x14, 42);
    wr32(cfg + 0x18, W);
    wr32(cfg + 0x1c, H);
    wr32(cfg + 0x20, 4);
    wr32(cfg + 0x24, (uint32_t)pipeline_depth);
    wr64(cfg + 0x28, g_q);
    wr64(cfg + 0x30, 0x3f);
    wr8(cfg + 0x3c, 1);
    wr8(cfg + 0x3d, 1);
    wr8(cfg + 0x3f, 1);
    wr64(mem, 0x48);
    CHECK(call(shim_sceVdecswQueryDecoderMemoryInfo, cfg, mem, 0, 0) == 0, "QueryDecoderMemoryInfo");
    wr64(mem + 0x10, galloc(rd64(mem + 0x08), 16));
    wr64(mem + 0x20, galloc(rd64(mem + 0x18), 0x10000));
    wr64(mem + 0x30, galloc(rd64(mem + 0x28), 0x10000));
    CHECK(call(shim_sceVdecswCreateDecoder, cfg, mem, out, 0) == 0, "CreateDecoder");
    memset(d, 0, sizeof(*d));
    d->handle = rd64(out);
    d->in = galloc(0x30, 16);
    d->res = galloc(0x18, 16);
    d->au_buf = galloc(AU_BUF, 0x100);
    d->fb_desc = galloc(0x18, 16);
    d->oi = galloc(0x40, 16);
    d->pic = galloc(0x80, 16);
    d->fb_size = 0x100000; // > FRAME_SIZE + trailer
    if (frame_buffers) {
        d->fbs[0] = galloc(d->fb_size, 0x1000);
        d->fbs[1] = galloc(d->fb_size, 0x1000);
    }
}

#define PIC_SIZE_REQ 0x68 // the size U4 asks for

// Checks one picture (OutputInfo at d->oi, frame buffer fb) and records it.
static void check_picture(Dec *d, const Stream *st, uint64_t fb, Collected *col, int mode) {
    const uint64_t oi = d->oi, pic = d->pic;
    const bool err = rd8(oi + 0x0a) != 0;
    CHECK(rd8(oi + 0x08) == 1, "is_valid %d", rd8(oi + 0x08));
    CHECK(rd8(oi + 0x0b) == 1, "picture_count %d", rd8(oi + 0x0b));
    CHECK(rd32(oi + 0x0c) == 1, "codec_type %u", rd32(oi + 0x0c));
    CHECK(rd8(oi + 0x1c) == 0, "is_discarded_frame");
    CHECK(rd64(oi + 0x20) == fb, "frame_buffer 0x%llx", (unsigned long long)rd64(oi + 0x20));
    // OutputInfo this_size 0x30: the 8 bytes after it belong to the caller (U4 keeps its picture
    // info there) and must not be touched.
    CHECK(rd64(oi + 0x30) == 0x1111111111111111ULL, "bytes past OutputInfo.this_size were written");
    const uint64_t fsize = rd64(oi + 0x28);
    int display = -1;
    if (!err) {
        CHECK(rd32(oi + 0x10) == W, "frame_width %u", rd32(oi + 0x10));
        CHECK(rd32(oi + 0x14) == PITCH, "frame_pitch %u", rd32(oi + 0x14));
        CHECK(rd32(oi + 0x18) == AH, "frame_height %u", rd32(oi + 0x18));
        CHECK(fsize == FRAME_SIZE, "frame_buffer_size 0x%llx", (unsigned long long)fsize);
        CHECK(g_notify_addr == fb && g_notify_size == FRAME_SIZE + 0x78, "GPU notified of 0x%llx+0x%llx",
              (unsigned long long)g_notify_addr, (unsigned long long)g_notify_size);
        display = display_of(fb);
        CHECK(display >= 0, "%s: pixels match no frame", st->name);
        CHECK(luma_at(fb, 100, AH - 1) == luma_at(fb, 100, H - 1), "padding row differs from the last row");
        int cb = rd8(fb + (uint64_t)PITCH * AH + (uint64_t)(H / 4) * PITCH + 100);
        CHECK(abs(cb - 128) <= 3, "chroma %d", cb);
    } else {
        // Error picture: the frame buffer is untouched, only the trailer is written.
        // (With no SPS the size is 0 and the trailer sits at the start of the buffer.)
        const uint64_t first_free = fsize >= 0x1000 ? 0 : fsize + 0x78;
        CHECK(rd8(fb + first_free) == 0x5A && rd8(fb + 0xFFF) == 0x5A, "error picture wrote the frame buffer");
        CHECK(g_notify_addr == fb + fsize && g_notify_size == 0x78, "error picture notify");
    }
    const uint64_t tr = fb + fsize;
    CHECK(rd64(tr) == 0x78, "trailer this_size 0x%llx", (unsigned long long)rd64(tr));

    // GetAvcPictureInfo with U4's 0x68 size: copies 0x60 bytes after this_size, nothing more.
    memset(gp(pic), 0x22, 0x78);
    wr64(pic, PIC_SIZE_REQ);
    CHECK(call(shim_sceVdecswGetAvcPictureInfo, oi, pic, 0, 0) == 0, "GetAvcPictureInfo");
    CHECK(rd64(pic) == PIC_SIZE_REQ, "caller's this_size changed");
    CHECK(rd8(pic + PIC_SIZE_REQ) == 0x22, "GetAvcPictureInfo wrote past this_size");
    CHECK(rd8(pic + 0x08) == 1, "pic.is_valid");
    const int64_t pts = (int64_t)rd64(pic + 0x10);
    const int64_t dts = (int64_t)rd64(pic + 0x18);
    const uint64_t attached = rd64(pic + 0x20);
    CHECK(attached < (uint64_t)st->count, "attached %llu", (unsigned long long)attached);
    if (attached < (uint64_t)st->count) {
        const Au *au = &st->aus[attached];
        // mode 0 = U4 player A (pts and dts -1), mode 1 = player B (pts, dts -1).
        if (mode == 0) CHECK(pts == -1, "pts %lld", (long long)pts);
        else CHECK(pts == (int64_t)au->display * 3003, "pts %lld for frame %d", (long long)pts, au->display);
        CHECK(dts == -1, "dts %lld", (long long)dts);
        if (!err) {
            CHECK(rd8(pic + 0x29) == 100, "profile_idc %d", rd8(pic + 0x29));
            CHECK(rd8(pic + 0x2a) == g_expected_level_idc, "level_idc %d", rd8(pic + 0x2a));
            CHECK(rd32(pic + 0x2c) == W / 16 - 1, "pic_width_in_mbs_minus1 %u", rd32(pic + 0x2c));
            CHECK(rd32(pic + 0x30) == AH / 16 - 1, "pic_height_in_map_units_minus1 %u", rd32(pic + 0x30));
            CHECK(rd8(pic + 0x34) == 1, "frame_mbs_only_flag");
            CHECK(rd8(pic + 0x35) == 1, "frame_cropping_flag");
            CHECK(rd32(pic + 0x38) == 0 && rd32(pic + 0x40) == 0, "crop left/top");
            CHECK(rd32(pic + 0x3c) == PITCH - W, "crop right %u", rd32(pic + 0x3c));
            CHECK(rd32(pic + 0x44) == AH - H, "crop bottom %u", rd32(pic + 0x44));
            CHECK(au->display == display, "%s: picture of AU %llu shows frame %d, the AU holds frame %d", st->name,
                  (unsigned long long)attached, display, au->display);
            CHECK(rd8(pic + 0x28) == (au->key ? 1 : 0), "idr_pictureflag %d for AU %llu", rd8(pic + 0x28),
                  (unsigned long long)attached);
            CHECK(rd8(pic + 0x67) == (au->key ? 1 : 0), "sequence_parameter_set_present_flag %d", rd8(pic + 0x67));
            CHECK(rd8(tr + 0x68) == (au->key ? 1 : 0), "picture_parameter_set_present_flag");
            CHECK(rd8(tr + 0x69) == 1, "au_delimiter_present_flag");
            CHECK(rd8(tr + 0x6a) == 0 && rd8(tr + 0x6b) == 0, "end of sequence/stream flags");
        }
    }
    if (col->count < MAXN) {
        col->display[col->count] = err ? (attached < (uint64_t)st->count ? st->aus[attached].display : -1) : display;
        col->attached[col->count] = attached;
        col->error[col->count] = err;
    }
    col->errors += err;
    col->count++;
}

// One output attempt (SetDecodeOutput if needed + TrySyncDecodeOutput). Returns the result code.
static int32_t try_output(Dec *d, const Stream *st, Collected *col, int mode) {
    if (!d->output_set) {
        uint64_t fb = d->fbs[d->fb_next];
        memset(gp(fb), 0x5A, 0x1000); // marks an untouched buffer (error pictures)
        wr64(d->fb_desc, 0x18);
        wr64(d->fb_desc + 8, fb);
        wr64(d->fb_desc + 0x10, d->fb_size);
        int32_t rc = call(shim_sceVdecswSetDecodeOutput, d->handle, d->fb_desc, 0, 0);
        CHECK(rc == 0, "SetDecodeOutput 0x%x", rc);
        d->output_set = true;
        // A second buffer while one is pending is refused.
        CHECK(call(shim_sceVdecswSetDecodeOutput, d->handle, d->fb_desc, 0, 0) == E_OUTPUT_BUFFER_FULL, "second output");
    }
    memset(gp(d->oi), 0x11, 0x40);
    wr64(d->oi, 0x30);
    int32_t rc = call(shim_sceVdecswTrySyncDecodeOutput, d->handle, d->oi, 0, 0);
    if (rc == E_DECODE_PENDING) {
        CHECK(rd8(d->oi + 0x08) == 0, "is_valid on DECODE_PENDING");
        return rc;
    }
    CHECK(rc == 0, "TrySyncDecodeOutput 0x%x", rc);
    if (rc != 0) return rc;
    d->output_set = false;
    if (rd8(d->oi + 0x08)) {
        check_picture(d, st, d->fbs[d->fb_next], col, mode);
        d->fb_next ^= 1;
    } else {
        CHECK(rd8(d->oi + 0x09) == 1, "empty output without is_last_frame");
        CHECK(rd8(d->oi + 0x0b) == 0, "picture_count on an empty output");
    }
    if (rd8(d->oi + 0x09)) col->last_flag_at = col->count - (rd8(d->oi + 0x08) ? 1 : 0);
    return rc;
}

static void drain_outputs(Dec *d, const Stream *st, Collected *col, int mode) {
    while (try_output(d, st, col, mode) == 0 && col->last_flag_at < 0) {
    }
}

// Feeds one access unit (retrying on INPUT_QUEUE_FULL / OUTPUT_BUFFER_FULL), syncs one input
// and pulls the pictures that are ready. Returns output_frame_count of the synced input(s).
static uint32_t feed(Dec *d, const Stream *st, const uint8_t *data, size_t size, int j, int64_t pts, Collected *col,
                     int mode) {
    uint32_t frames = 0;
    // U4 rebuilds every access unit in the same buffer; the API must have copied the previous one.
    memset(gp(d->au_buf), 0xEE, AU_BUF);
    memcpy(gp(d->au_buf), data, size);
    wr64(d->in, 0x30);
    wr64(d->in + 0x08, d->au_buf);
    wr64(d->in + 0x10, size);
    wr64(d->in + 0x18, (uint64_t)pts);
    wr64(d->in + 0x20, (uint64_t)-1);
    wr64(d->in + 0x28, (uint64_t)j);
    int32_t rc;
    while ((rc = call(shim_sceVdecswSetDecodeInput, d->handle, d->in, 0, 0)) != 0) {
        CHECK(rc == E_INPUT_QUEUE_FULL || rc == E_OUTPUT_BUFFER_FULL, "SetDecodeInput 0x%x", rc);
        if (rc == E_INPUT_QUEUE_FULL) {
            wr64(d->res, 0x18);
            CHECK(call(shim_sceVdecswTrySyncDecodeInput, d->handle, d->res, 0, 0) == 0, "sync after INPUT_QUEUE_FULL");
            frames += rd32(d->res + 0x10);
        } else if (rc == E_OUTPUT_BUFFER_FULL) {
            drain_outputs(d, st, col, mode);
        } else {
            break;
        }
    }
    wr64(d->res, 0x18);
    rc = call(shim_sceVdecswTrySyncDecodeInput, d->handle, d->res, 0, 0);
    CHECK(rc == 0, "TrySyncDecodeInput 0x%x", rc);
    if (rc == 0) {
        CHECK(rd64(d->res + 0x08) == d->au_buf, "decoded_au 0x%llx", (unsigned long long)rd64(d->res + 0x08));
        frames += rd32(d->res + 0x10);
    }
    while (try_output(d, st, col, mode) == 0) {
    }
    return frames;
}

static void finish(Dec *d, const Stream *st, Collected *col, int mode) {
    CHECK(call(shim_sceVdecswFinalizeDecodeSequence, d->handle, 0, 0, 0) == 0, "FinalizeDecodeSequence");
    drain_outputs(d, st, col, mode);
}

static void check_display_order(const Stream *st, const Collected *col, const char *what) {
    CHECK(col->count == st->count, "%s %s: %d pictures for %d access units", st->name, what, col->count, st->count);
    for (int k = 0; k < col->count && k < MAXN; k++)
        CHECK(col->display[k] == k, "%s %s: output %d shows frame %d", st->name, what, k, col->display[k]);
}

static void run_stream(Dec *d, const Stream *st, int mode) {
    Collected col = {0};
    col.last_flag_at = -1;
    d->output_set = false;
    uint32_t reported = 0;
    for (int j = 0; j < st->count; j++)
        reported +=
            feed(d, st, st->aus[j].data, st->aus[j].size, j, mode == 0 ? -1 : st->aus[j].display * 3003, &col, mode);
    wr64(d->res, 0x18);
    CHECK(call(shim_sceVdecswTrySyncDecodeInput, d->handle, d->res, 0, 0) == E_INPUT_QUEUE_EMPTY, "inputs left");
    const int before_finalize = col.count;
    CHECK(reported == (uint32_t)before_finalize, "output_frame_count total %u, pictures before finalize %d", reported,
          before_finalize);
    finish(d, st, &col, mode);
    check_display_order(st, &col, mode == 0 ? "mode 0" : "mode 1");
    CHECK(col.errors == 0, "%s: %d error pictures", st->name, col.errors);
    CHECK(col.last_flag_at == st->count - 1 || col.last_flag_at == st->count, "is_last_frame at %d", col.last_flag_at);
    if (!d->output_set) {
        memset(gp(d->oi), 0x11, 0x40);
        wr64(d->oi, 0x30);
        CHECK(call(shim_sceVdecswTrySyncDecodeOutput, d->handle, d->oi, 0, 0) == E_OUTPUT_BUFFER_EMPTY,
              "no buffer -> EMPTY");
    }
    fprintf(stderr, "%s mode %d: %d pictures, %d before finalize\n", st->name, mode, col.count, before_finalize);
}

static void delete_dec(Dec *d) {
    CHECK(call(shim_sceVdecswDeleteDecoder, d->handle, 0, 0, 0) == 0, "DeleteDecoder");
    CHECK(call(shim_sceVdecswDeleteDecoder, d->handle, 0, 0, 0) == E_DECODER_INSTANCE, "deleted handle");
}

static void set_input(Dec *d, const Au *au, int j) {
    memcpy(gp(d->au_buf), au->data, au->size);
    wr64(d->in, 0x30);
    wr64(d->in + 0x08, d->au_buf);
    wr64(d->in + 0x10, au->size);
    wr64(d->in + 0x18, (uint64_t)-1);
    wr64(d->in + 0x20, (uint64_t)-1);
    wr64(d->in + 0x28, (uint64_t)j);
}

// ---------------------------------------------------------------------------------------------

static Stream S1, S2, S3, S4, S5;

static void test_setup_and_errors(void) {
    // Compute queue, as U4 does at 0x16993c3.
    uint64_t cmi = galloc(0x18, 16), cci = galloc(0x10, 16), q = galloc(8, 8);
    wr64(cmi, 0x18);
    CHECK(call(shim_sceVdecswQueryComputeMemoryInfo, cmi, 0, 0, 0) == 0, "QueryComputeMemoryInfo");
    uint64_t csize = rd64(cmi + 8);
    CHECK(csize > 0 && csize <= 0x100000, "compute memory size 0x%llx", (unsigned long long)csize);
    wr64(cmi + 0x10, galloc(csize, 0x4000));
    wr64(cci, 0x10);
    wr16(cci + 8, 3);
    wr16(cci + 10, 3);
    wr8(cci + 12, 1);
    CHECK(call(shim_sceVdecswAllocateComputeQueue, cci, cmi, q, 0) == 0, "AllocateComputeQueue");
    CHECK(rd64(q) == rd64(cmi + 0x10), "queue handle");
    g_q = rd64(q);
    wr16(cci + 8, 5);
    CHECK(call(shim_sceVdecswAllocateComputeQueue, cci, cmi, q, 0) == (int32_t)0x81510201, "pipe 5 refused");
    wr64(cmi, 0x10);
    CHECK(call(shim_sceVdecswQueryComputeMemoryInfo, cmi, 0, 0, 0) == E_STRUCT_SIZE, "struct size");

    // Decoder config, V1 layout (0x48) as U4 builds it (0x16993ad / rodata 0x1dadae0).
    uint64_t cfg = galloc(0x50, 16), mem = galloc(0x48, 16), out = galloc(8, 8);
    wr64(cfg, 0x48);
    wr32(cfg + 0x0c, 1);
    wr32(cfg + 0x18, W);
    wr32(cfg + 0x1c, H);
    wr32(cfg + 0x24, 3);
    wr64(mem, 0x48);
    CHECK(call(shim_sceVdecswQueryDecoderMemoryInfo, cfg, mem, 0, 0) == 0, "QueryDecoderMemoryInfo");
    uint64_t want_fb = ((uint64_t)FRAME_SIZE + 255) / 256 * 256 + 0x4000;
    CHECK(rd64(mem + 0x38) == want_fb, "max_frame_buffer_size 0x%llx", (unsigned long long)rd64(mem + 0x38));
    CHECK(rd32(mem + 0x40) == 0x100, "frame_buffer_alignment");
    // U4's own sizing check: 1920x1088 rounds to its fixed 4 MiB frame buffers.
    wr32(cfg + 0x18, 1920);
    wr32(cfg + 0x1c, 1088);
    CHECK(call(shim_sceVdecswQueryDecoderMemoryInfo, cfg, mem, 0, 0) == 0, "QueryDecoderMemoryInfo 1080p");
    CHECK(((rd64(mem + 0x38) + 0x1fffff) & ~0x1fffffULL) == 0x400000, "1080p max_frame_buffer_size 0x%llx",
          (unsigned long long)rd64(mem + 0x38));
    wr32(cfg + 0x18, W);
    wr32(cfg + 0x1c, H);
    wr64(mem + 0x10, galloc(rd64(mem + 0x08), 16));
    wr64(mem + 0x20, galloc(rd64(mem + 0x18), 0x10000));
    wr64(mem + 0x30, galloc(rd64(mem + 0x28), 0x10000));
    wr32(cfg + 0x0c, 974921);
    CHECK(call(shim_sceVdecswCreateDecoder, cfg, mem, out, 0) == E_CODEC_TYPE, "HEVC refused");
    wr32(cfg + 0x0c, 1);
    wr64(cfg, 0x40);
    CHECK(call(shim_sceVdecswCreateDecoder, cfg, mem, out, 0) == E_STRUCT_SIZE, "config size refused");

    Dec d;
    create_dec(&d, 3, true);
    CHECK(call(shim_sceVdecswSetDecodeInput, d.handle ^ 0x40, 0, 0, 0) == E_DECODER_INSTANCE, "bad handle");
    wr64(d.res, 0x18);
    CHECK(call(shim_sceVdecswTrySyncDecodeInput, d.handle, d.res, 0, 0) == E_INPUT_QUEUE_EMPTY, "empty input queue");
    wr64(d.oi, 0x30);
    CHECK(call(shim_sceVdecswTrySyncDecodeOutput, d.handle, d.oi, 0, 0) == E_OUTPUT_BUFFER_EMPTY, "no output buffer");

    // Guest ranges that wrap around the 64-bit address space are refused, not read.
    wr64(d.in, 0x30);
    wr64(d.in + 0x08, g.mem_size - 0x10);
    wr64(d.in + 0x10, (uint64_t)0 - (g.mem_size - 0x10) + 0x20); // au_data + au_size wraps to 0x10
    CHECK(call(shim_sceVdecswSetDecodeInput, d.handle, d.in, 0, 0) == E_AU_SIZE, "wrapping access unit");
    wr64(d.in + 0x08, g.mem_size + 0x1000);
    wr64(d.in + 0x10, 0x10);
    CHECK(call(shim_sceVdecswSetDecodeInput, d.handle, d.in, 0, 0) == E_AU_SIZE, "access unit past guest memory");
    wr64(d.fb_desc, 0x18);
    wr64(d.fb_desc + 8, g.mem_size - 0x10);
    wr64(d.fb_desc + 0x10, (uint64_t)0 - (g.mem_size - 0x10) + 0x20);
    CHECK(call(shim_sceVdecswSetDecodeOutput, d.handle, d.fb_desc, 0, 0) == E_FRAME_BUFFER_SIZE, "wrapping frame buffer");

    // Pipeline depth 3: the fourth unsynced input is refused.
    for (int j = 0; j < 3; j++) {
        set_input(&d, &S1.aus[j], j);
        CHECK(call(shim_sceVdecswSetDecodeInput, d.handle, d.in, 0, 0) == 0, "input %d", j);
    }
    CHECK(call(shim_sceVdecswSetDecodeInput, d.handle, d.in, 0, 0) == E_INPUT_QUEUE_FULL, "input queue full");
    CHECK(call(shim_sceVdecswFinalizeDecodeSequence, d.handle, 0, 0, 0) == 0, "finalize");

    // A buffer too small for the picture: the call fails and both the picture and the pending
    // buffer stay (the next call fails the same way, a second SetDecodeOutput is refused).
    uint64_t small = galloc(0x10000, 0x100);
    wr64(d.fb_desc, 0x18);
    wr64(d.fb_desc + 8, small);
    wr64(d.fb_desc + 0x10, 0x10000);
    CHECK(call(shim_sceVdecswSetDecodeOutput, d.handle, d.fb_desc, 0, 0) == 0, "small SetDecodeOutput");
    wr64(d.oi, 0x30);
    CHECK(call(shim_sceVdecswTrySyncDecodeOutput, d.handle, d.oi, 0, 0) == E_FRAME_BUFFER_SIZE, "small buffer refused");
    CHECK(call(shim_sceVdecswTrySyncDecodeOutput, d.handle, d.oi, 0, 0) == E_FRAME_BUFFER_SIZE,
          "small buffer was consumed by the failed call");
    CHECK(call(shim_sceVdecswSetDecodeOutput, d.handle, d.fb_desc, 0, 0) == E_OUTPUT_BUFFER_FULL, "buffer still pending");

    // Reset drops everything; then the stream decodes from the start in both pts modes.
    CHECK(call(shim_sceVdecswResetDecoder, d.handle, 0, 0, 0) == 0, "ResetDecoder");
    CHECK(call(shim_sceVdecswTrySyncDecodeInput, d.handle, d.res, 0, 0) == E_INPUT_QUEUE_EMPTY, "inputs after reset");
    CHECK(call(shim_sceVdecswTrySyncDecodeOutput, d.handle, d.oi, 0, 0) == E_OUTPUT_BUFFER_EMPTY, "buffer after reset");
    run_stream(&d, &S1, 0);
    CHECK(call(shim_sceVdecswResetDecoder, d.handle, 0, 0, 0) == 0, "ResetDecoder");
    run_stream(&d, &S1, 1);
    delete_dec(&d);
}

// S2: no reordering, IDR every 10 frames: every access unit gives its picture at once.
static void test_zero_delay(void) {
    Dec d;
    create_dec(&d, 3, true);
    Collected col = {0};
    col.last_flag_at = -1;
    for (int j = 0; j < S2.count; j++) {
        uint32_t frames = feed(&d, &S2, S2.aus[j].data, S2.aus[j].size, j, S2.aus[j].display * 3003, &col, 1);
        CHECK(frames == 1, "S2: AU %d reported %u pictures", j, frames);
        CHECK(col.count == j + 1, "S2: %d pictures after AU %d", col.count, j);
    }
    finish(&d, &S2, &col, 1);
    check_display_order(&S2, &col, "zero delay");
    delete_dec(&d);
}

// S3: B-frames with an IDR every 10 frames: at each IDR every earlier picture is released.
// S4: 120 frames with one IDR: the POC lsb wraps and the order survives it.
static void test_reorder_streams(void) {
    Dec d;
    create_dec(&d, 3, true);
    Collected col = {0};
    col.last_flag_at = -1;
    int idr_checks = 0;
    for (int j = 0; j < S3.count; j++) {
        feed(&d, &S3, S3.aus[j].data, S3.aus[j].size, j, S3.aus[j].display * 3003, &col, 1);
        if (S3.aus[j].key && j > 0) {
            // AUs 0..j-1 went in before the IDR; it releases all of their pictures.
            CHECK(col.count >= j, "S3: %d pictures out after the IDR at AU %d", col.count, j);
            idr_checks++;
        }
    }
    finish(&d, &S3, &col, 1);
    check_display_order(&S3, &col, "IDR every 10");
    CHECK(idr_checks >= 2, "S3 has %d mid-stream IDRs", idr_checks);
    CHECK(call(shim_sceVdecswResetDecoder, d.handle, 0, 0, 0) == 0, "ResetDecoder");
    H264SpsInfo sps;
    h264_parse_sps(S4.sps, S4.sps_len, &sps);
    // POC grows by 2 per frame here; 2 * frames must exceed MaxPicOrderCntLsb for a wrap.
    CHECK(sps.pic_order_cnt_type == 0 && (2 * S4.count) > (1 << sps.log2_max_pic_order_cnt_lsb),
          "S4 does not wrap the POC lsb (type %u, %u bits)", sps.pic_order_cnt_type, sps.log2_max_pic_order_cnt_lsb);
    run_stream(&d, &S4, 0);
    delete_dec(&d);
}

// Two decoders fed alternately (S1 and S3) keep their streams apart.
static void test_interleaved(void) {
    Dec a, b;
    create_dec(&a, 3, true);
    create_dec(&b, 4, true);
    Collected ca = {0}, cb = {0};
    ca.last_flag_at = cb.last_flag_at = -1;
    int n = S1.count > S3.count ? S1.count : S3.count;
    for (int j = 0; j < n; j++) {
        if (j < S1.count) feed(&a, &S1, S1.aus[j].data, S1.aus[j].size, j, -1, &ca, 0);
        if (j < S3.count) feed(&b, &S3, S3.aus[j].data, S3.aus[j].size, j, S3.aus[j].display * 3003, &cb, 1);
    }
    finish(&a, &S1, &ca, 0);
    finish(&b, &S3, &cb, 1);
    check_display_order(&S1, &ca, "interleaved A");
    check_display_order(&S3, &cb, "interleaved B");
    delete_dec(&a);
    delete_dec(&b);
}

// Offset of the n-th start code (1-based) in an access unit, 0 if none.
static size_t nth_start(const Au *au, int n) {
    int k = 0;
    for (size_t i = 0; i + 4 < au->size; i++)
        if (au->data[i] == 0 && au->data[i + 1] == 0 && au->data[i + 2] == 0 && au->data[i + 3] == 1 && ++k == n)
            return i;
    return 0;
}

// Corrupt access units, a stream without parameter sets and a rejected SPS: every access unit
// still gives one picture, the undecodable ones flagged is_error_frame, in display order.
static void test_error_pictures(void) {
    // (a) Garbage slice data (after the first bytes of the slice header) in two access units.
    Dec d;
    create_dec(&d, 3, true);
    Collected col = {0};
    col.last_flag_at = -1;
    for (int j = 0; j < S1.count; j++) {
        uint8_t *buf = (uint8_t *)malloc(S1.aus[j].size);
        memcpy(buf, S1.aus[j].data, S1.aus[j].size);
        if (j == 5 || j == 12) {
            size_t s = nth_start(&S1.aus[j], 2) + 4; // the slice NAL (after the AUD)
            for (size_t i = s + 3; i < S1.aus[j].size; i++) buf[i] = (uint8_t)(0xA5 ^ (i * 7));
        }
        feed(&d, &S1, buf, S1.aus[j].size, j, S1.aus[j].display * 3003, &col, 1);
        free(buf);
    }
    finish(&d, &S1, &col, 1);
    fprintf(stderr, "corrupt access units: %d pictures, %d error pictures\n", col.count, col.errors);
    CHECK(col.count == S1.count, "corrupt: %d pictures for %d access units", col.count, S1.count);
    CHECK(col.errors >= 1, "corrupt access units produced no error picture");
    for (int k = 0; k < col.count && k < MAXN; k++)
        CHECK(col.display[k] == k, "corrupt: output %d is frame %d", k, col.display[k]);
    delete_dec(&d);

    // (b) No parameter sets at all (non-key access units only): no session, error pictures.
    create_dec(&d, 3, true);
    Collected c2 = {0};
    c2.last_flag_at = -1;
    for (int j = 1; j <= 8; j++) {
        const Au *au = &S2.aus[j];
        uint32_t frames = feed(&d, &S2, au->data, au->size, j, au->display * 3003, &c2, 1);
        CHECK(frames == 1, "no session: AU %d reported %u pictures", j, frames);
    }
    finish(&d, &S2, &c2, 1);
    CHECK(c2.count == 8 && c2.errors == 8, "no session: %d pictures, %d errors", c2.count, c2.errors);
    delete_dec(&d);

    // (c) A rejected SPS with S2's PPS and IDR slices: session creation fails.
    create_dec(&d, 3, true);
    Collected c3 = {0};
    c3.last_flag_at = -1;
    static const uint8_t bad_sps[] = {0x67, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF};
    uint8_t *buf = NULL;
    size_t len = 0;
    put_nal(&buf, &len, bad_sps, sizeof(bad_sps));
    put_nal(&buf, &len, S2.pps, S2.pps_len);
    const Au *k0 = &S2.aus[0];
    size_t off = nth_start(k0, 4); // AUD, SPS, PPS, then the slices
    CHECK(off > 0, "IDR access unit layout");
    put(&buf, &len, k0->data + off, k0->size - off);
    uint32_t frames = feed(&d, &S2, buf, len, 0, 0, &c3, 1);
    free(buf);
    finish(&d, &S2, &c3, 1);
    CHECK(frames == 1 && c3.count == 1 && c3.errors == 1, "rejected SPS: %u frames, %d pictures, %d errors", frames,
          c3.count, c3.errors);
    delete_dec(&d);
}

// DeleteDecoder while another thread is inside calls on the same decoder: no use after free
// (AddressSanitizer), and the other thread sees either a result or DECODER_INSTANCE.
typedef struct Racer {
    uint64_t handle, in, res, oi;
    atomic_int calls;
    atomic_bool stop;
    int bad;
} Racer;

static void *racer_main(void *arg) {
    Racer *r = (Racer *)arg;
    GuestContext c = g;
    while (!atomic_load(&r->stop)) {
        int32_t rc = call_on(&c, shim_sceVdecswSetDecodeInput, r->handle, r->in, 0, 0);
        if (rc != 0 && rc != E_DECODER_INSTANCE && rc != E_INPUT_QUEUE_FULL && rc != E_OUTPUT_BUFFER_FULL) r->bad++;
        wr64(r->res, 0x18);
        rc = call_on(&c, shim_sceVdecswTrySyncDecodeInput, r->handle, r->res, 0, 0);
        if (rc != 0 && rc != E_DECODER_INSTANCE && rc != E_INPUT_QUEUE_EMPTY) r->bad++;
        wr64(r->oi, 0x30);
        rc = call_on(&c, shim_sceVdecswTrySyncDecodeOutput, r->handle, r->oi, 0, 0);
        if (rc != E_DECODER_INSTANCE && rc != E_OUTPUT_BUFFER_EMPTY) r->bad++;
        atomic_fetch_add(&r->calls, 1);
        if (rc == E_DECODER_INSTANCE) break;
    }
    return NULL;
}

static void test_delete_race(void) {
    for (int it = 0; it < 40; it++) {
        Dec d;
        create_dec(&d, 32, false);
        set_input(&d, &S1.aus[0], 0);
        Racer r = {.handle = d.handle, .in = d.in, .res = galloc(0x18, 16), .oi = galloc(0x40, 16)};
        pthread_t t;
        pthread_create(&t, NULL, racer_main, &r);
        while (atomic_load(&r.calls) < 1 + it % 3) {
        }
        CHECK(call(shim_sceVdecswDeleteDecoder, d.handle, 0, 0, 0) == 0, "DeleteDecoder during calls");
        atomic_store(&r.stop, true);
        pthread_join(t, NULL);
        CHECK(r.bad == 0, "racer saw %d unexpected codes", r.bad);
        CHECK(call(shim_sceVdecswSetDecodeInput, d.handle, d.in, 0, 0) == E_DECODER_INSTANCE, "stale handle");
    }
    // A stale handle never names a decoder created later in the same slot.
    Dec a, b;
    create_dec(&a, 3, false);
    uint64_t old = a.handle;
    delete_dec(&a);
    create_dec(&b, 3, false);
    CHECK((b.handle & 0xFF) == (old & 0xFF), "slot reuse expected for this check");
    CHECK(call(shim_sceVdecswResetDecoder, old, 0, 0, 0) == E_DECODER_INSTANCE, "stale handle reaches the new decoder");
    delete_dec(&b);
    fprintf(stderr, "delete race: 40 rounds\n");
}

// ResetDecoder on one thread while another pulls pictures (SetDecodeOutput/TrySyncDecodeOutput):
// a reset drops queued pictures, and the output side must never touch one after that.
typedef struct OutRacer {
    uint64_t handle, fb_desc, oi;
    atomic_bool stop;
    atomic_int pictures;
    int bad;
} OutRacer;

static void *out_racer_main(void *arg) {
    OutRacer *r = (OutRacer *)arg;
    GuestContext c = g;
    while (!atomic_load(&r->stop)) {
        int32_t rc = call_on(&c, shim_sceVdecswSetDecodeOutput, r->handle, r->fb_desc, 0, 0);
        if (rc != 0 && rc != E_OUTPUT_BUFFER_FULL) r->bad++;
        wr64(r->oi, 0x30);
        rc = call_on(&c, shim_sceVdecswTrySyncDecodeOutput, r->handle, r->oi, 0, 0);
        if (rc == 0) atomic_fetch_add(&r->pictures, 1);
        else if (rc != E_DECODE_PENDING && rc != E_OUTPUT_BUFFER_EMPTY) r->bad++;
    }
    return NULL;
}

static void test_reset_race(void) {
    Dec d;
    create_dec(&d, 32, true);
    OutRacer r = {.handle = d.handle, .fb_desc = galloc(0x18, 16), .oi = galloc(0x40, 16)};
    wr64(r.fb_desc, 0x18);
    wr64(r.fb_desc + 8, d.fbs[0]);
    wr64(r.fb_desc + 0x10, d.fb_size);
    pthread_t t;
    pthread_create(&t, NULL, out_racer_main, &r);
    for (int round = 0; round < 60; round++) {
        for (int j = 0; j < 6; j++) {
            set_input(&d, &S1.aus[j], j);
            int32_t rc = call(shim_sceVdecswSetDecodeInput, d.handle, d.in, 0, 0);
            CHECK(rc == 0 || rc == E_OUTPUT_BUFFER_FULL, "reset race: SetDecodeInput 0x%x", rc);
            wr64(d.res, 0x18);
            call(shim_sceVdecswTrySyncDecodeInput, d.handle, d.res, 0, 0);
        }
        CHECK(call(shim_sceVdecswResetDecoder, d.handle, 0, 0, 0) == 0, "reset race: ResetDecoder");
    }
    atomic_store(&r.stop, true);
    pthread_join(t, NULL);
    CHECK(r.bad == 0, "reset race: %d unexpected codes", r.bad);
    fprintf(stderr, "reset race: 60 resets, %d pictures pulled meanwhile\n", atomic_load(&r.pictures));
    delete_dec(&d);
}

// After a reset the decoder must not release a picture early because its POC is the old
// sequence's last POC + 1 (S1 decode order: POC 0,4,2,1,3 then 8,6,5,...).
static void test_reset_forgets_last_poc(void) {
    Dec d;
    create_dec(&d, 8, true);
    Collected col = {0};
    col.last_flag_at = -1;
    int seen = 0;
    for (int j = 0; j < 5; j++) {
        feed(&d, &S1, S1.aus[j].data, S1.aus[j].size, j, -1, &col, 0);
        seen |= 1 << S1.aus[j].display;
    }
    CHECK(seen == 0x1f, "precondition: S1 AUs 0..4 hold frames 0..4 (mask 0x%x)", seen);
    CHECK(call(shim_sceVdecswResetDecoder, d.handle, 0, 0, 0) == 0, "ResetDecoder");
    d.output_set = false;
    Collected after = {0};
    after.last_flag_at = -1;
    int fed = 0;
    for (int j = 5; j < S1.count && fed < 6; j++) {
        feed(&d, &S1, S1.aus[j].data, S1.aus[j].size, j, -1, &after, 0);
        fed++;
        if (S1.aus[j].display == 5) break;
    }
    CHECK(after.count == 0, "after reset %d picture(s) left early after %d access units (stale last POC)", after.count,
          fed);
    finish(&d, &S1, &after, 0);
    CHECK(after.count == fed, "after reset: %d pictures for %d access units", after.count, fed);
    for (int k = 1; k < after.count && k < MAXN; k++)
        CHECK(after.display[k] > after.display[k - 1], "after reset: output %d frame %d after %d", k, after.display[k],
              after.display[k - 1]);
    delete_dec(&d);
}

// An IDR that cannot be decoded still ends the previous sequence: held pictures come out first.
static void test_idr_error_flush(void) {
    Dec d;
    create_dec(&d, 8, true);
    Collected col = {0};
    col.last_flag_at = -1;
    feed(&d, &S1, S1.aus[0].data, S1.aus[0].size, 0, -1, &col, 0); // IDR, out at once
    feed(&d, &S1, S1.aus[1].data, S1.aus[1].size, 1, -1, &col, 0); // a later frame, held
    CHECK(col.count == 1, "precondition: %d pictures out before the bad IDR", col.count);
    static const uint8_t bad_sps[] = {0x67, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF};
    uint8_t *buf = NULL;
    size_t len = 0;
    put_nal(&buf, &len, bad_sps, sizeof(bad_sps));
    put_nal(&buf, &len, S2.pps, S2.pps_len);
    const Au *k0 = &S2.aus[0];
    size_t off = nth_start(k0, 4);
    put(&buf, &len, k0->data + off, k0->size - off);
    feed(&d, &S1, buf, len, 2, -1, &col, 0);
    free(buf);
    finish(&d, &S1, &col, 0);
    CHECK(col.count == 3, "bad IDR: %d pictures", col.count);
    CHECK(!col.error[0] && !col.error[1] && col.error[2], "bad IDR: error flags %d %d %d", col.error[0], col.error[1],
          col.error[2]);
    CHECK(col.display[1] == S1.aus[1].display, "bad IDR: the held frame came out as output %d", col.display[1]);
    delete_dec(&d);
}

// libSceVideodec (TLOU's API) on S1: one picture per Decode/Flush, display order.
static void test_videodec(void) {
    uint64_t cfg = galloc(0x30, 16), ri = galloc(0x40, 16), ctrl = galloc(0x18, 16);
    uint64_t in = galloc(0x30, 16), fb = galloc(0x18, 16), pic = galloc(0x70, 16);
    uint64_t buf = galloc(0x100000, 0x100), au_buf = galloc(AU_BUF, 0x100);
    wr64(cfg, 0x30);
    wr32(cfg + 0x14, W);
    wr32(cfg + 0x18, H);
    CHECK(call(shim_sceVideodecQueryResourceInfo, cfg, ri, 0, 0) == 0, "QueryResourceInfo");
    CHECK(rd64(ri + 0x28) >= FRAME_SIZE, "maxFrameBufferSize");
    wr64(ctrl, 0x18);
    CHECK(call(shim_sceVideodecCreateDecoder, cfg, ri, ctrl, 0) == 0, "Videodec CreateDecoder");
    int got = 0, order_ok = 1;
    // Decode hands out at most one picture per call; Flush drains the rest one per call.
    for (int j = 0; j <= S1.count + MAXN; j++) {
        wr64(fb, 0x18);
        wr64(fb + 8, buf);
        wr64(fb + 0x10, 0x100000);
        int32_t rc;
        if (j < S1.count) {
            memcpy(gp(au_buf), S1.aus[j].data, S1.aus[j].size);
            wr64(in, 0x30);
            wr64(in + 0x08, au_buf);
            wr64(in + 0x10, S1.aus[j].size);
            wr64(in + 0x18, (uint64_t)S1.aus[j].display * 3003);
            wr64(in + 0x20, (uint64_t)j * 3003);
            wr64(in + 0x28, (uint64_t)j);
            rc = call(shim_sceVideodecDecode, ctrl, in, fb, pic);
        } else {
            rc = call(shim_sceVideodecFlush, ctrl, fb, pic, 0);
        }
        CHECK(rc == 0, "Videodec Decode/Flush 0x%x", rc);
        if (!rd32(pic + 0x08)) {
            if (j >= S1.count) break;
            continue;
        }
        int display = display_of(buf);
        if (display != got) order_ok = 0;
        CHECK(rd32(pic + 0x10) == W && rd32(pic + 0x14) == PITCH && rd32(pic + 0x18) == AH, "Videodec dims");
        CHECK(rd64(pic + 0x20) == (uint64_t)display * 3003, "Videodec pts %llu", (unsigned long long)rd64(pic + 0x20));
        CHECK(rd64(pic + 0x28) < (uint64_t)S1.count && S1.aus[rd64(pic + 0x28)].display == display,
              "Videodec attachedData");
        got++;
    }
    CHECK(got == S1.count, "Videodec decoded %d pictures, expected %d", got, S1.count);
    CHECK(order_ok, "Videodec display order");
    CHECK(call(shim_sceVideodecDeleteDecoder, ctrl, 0, 0, 0) == 0, "Videodec DeleteDecoder");
    fprintf(stderr, "videodec: %d pictures\n", got);
}

// ---------------------------------------------------------------------------------------------
// Access-unit census, per-decoder counts (Ps4VideodecStats) and the inFAMOUS splash fixture
// ---------------------------------------------------------------------------------------------

// Calls fn for each NAL unit of an Annex-B buffer (start code excluded, trailing zeros trimmed).
typedef void (*NalFn)(void *u, const uint8_t *nal, size_t n, size_t sc_off);
static void for_each_nal(const uint8_t *p, size_t size, NalFn fn, void *u) {
    size_t i = 0;
    while (i + 3 <= size && !(p[i] == 0 && p[i + 1] == 0 && p[i + 2] == 1)) i++;
    while (i + 3 <= size) {
        const size_t s = i + 3;
        size_t e = s;
        while (e + 3 <= size && !(p[e] == 0 && p[e + 1] == 0 && p[e + 2] == 1)) e++;
        if (e + 3 > size) e = size;
        const size_t next = e;
        while (e > s && p[e - 1] == 0) e--;
        if (e > s) fn(u, p + s, e - s, i);
        i = next;
    }
}

typedef struct NthSlice {
    int want, seen;
    const uint8_t *nal;
    size_t n;
} NthSlice;
static void nth_slice_fn(void *u, const uint8_t *nal, size_t n, size_t sc_off) {
    (void)sc_off;
    NthSlice *t = (NthSlice *)u;
    const int type = nal[0] & 0x1f;
    if (type >= 1 && type <= 5 && ++t->seen == t->want) {
        t->nal = nal;
        t->n = n;
    }
}

static void test_au_census(void) {
    H264AuCensus c;
    // S1's first access unit as built by enc_cb: AUD, SPS, PPS, then the encoder's IDR slice.
    h264_au_census(S1.aus[0].data, S1.aus[0].size, &c);
    fprintf(stderr, "census S1 au 0: %u NAL units [", c.nal_count);
    for (uint32_t k = 0; k < c.nal_count && k < 32; k++) fprintf(stderr, "%s%u", k ? " " : "", c.nal_types[k]);
    fprintf(stderr, "], slices %u, first_mb %d\n", c.slices, c.first_mb_first_slice);
    CHECK(c.nal_count >= 4 && c.nal_types[0] == 9 && c.nal_types[1] == 7 && c.nal_types[2] == 8 &&
              c.nal_types[c.nal_count - 1] == 5,
          "S1 au 0 NAL types");
    for (uint32_t k = 3; k + 1 < c.nal_count; k++) CHECK(c.nal_types[k] == 6, "S1 au 0 NAL %u type %u", k, c.nal_types[k]);
    CHECK(c.slices == 1 && c.first_mb_first_slice == 0 && c.has_idr && c.has_sps, "S1 au 0: slices %u first_mb %d",
          c.slices, c.first_mb_first_slice);
    h264_au_census(S1.aus[1].data, S1.aus[1].size, &c);
    CHECK(c.slices == 1 && c.first_mb_first_slice == 0 && !c.has_idr && !c.has_sps, "S1 au 1: slices %u", c.slices);

    // S5: multi-slice pictures. Without them the test proves nothing, so it fails.
    uint32_t min_slices = UINT32_MAX, max_slices = 0;
    for (int j = 0; j < S5.count; j++) {
        h264_au_census(S5.aus[j].data, S5.aus[j].size, &c);
        if (c.slices < min_slices) min_slices = c.slices;
        if (c.slices > max_slices) max_slices = c.slices;
        CHECK(c.first_mb_first_slice == 0, "S5 au %d: first_mb %d", j, c.first_mb_first_slice);
    }
    fprintf(stderr, "census S5: slices per picture %u..%u\n", min_slices, max_slices);
    CHECK(min_slices >= 4, "S5: the encoder made %u slices in a picture; the test needs >= 4", min_slices);
    S5.max_slices = max_slices;
    S1.max_slices = 1;

    // S5's second slice NAL alone: one slice that starts mid-picture.
    NthSlice t = {2, 0, NULL, 0};
    for_each_nal(S5.aus[0].data, S5.aus[0].size, nth_slice_fn, &t);
    CHECK(t.nal != NULL, "S5 au 0 has no second slice");
    if (t.nal) {
        uint8_t *buf = NULL;
        size_t len = 0;
        put_nal(&buf, &len, t.nal, t.n);
        h264_au_census(buf, len, &c);
        CHECK(c.nal_count == 1 && c.slices == 1 && c.first_mb_first_slice > 0, "S5 slice 2: slices %u first_mb %d",
              c.slices, c.first_mb_first_slice);
        free(buf);
    }

    // An SPS alone: no slice.
    uint8_t *buf = NULL;
    size_t len = 0;
    put_nal(&buf, &len, S1.sps, S1.sps_len);
    static const uint8_t zeros[3] = {0, 0, 0};
    put(&buf, &len, zeros, sizeof(zeros)); // trailing_zero_8bits are not a NAL unit
    h264_au_census(buf, len, &c);
    CHECK(c.nal_count == 1 && c.nal_types[0] == 7 && c.slices == 0 && c.first_mb_first_slice == -1 && c.has_sps &&
              !c.has_idr,
          "SPS only: %u NAL units, slices %u, first_mb %d", c.nal_count, c.slices, c.first_mb_first_slice);
    free(buf);
    h264_au_census(NULL, 0, &c);
    CHECK(c.nal_count == 0 && c.slices == 0 && c.first_mb_first_slice == -1, "empty AU");

    // 3-byte start codes (00 00 01) between all NAL units, as some muxers write them.
    buf = NULL;
    len = 0;
    static const uint8_t sc3[3] = {0, 0, 1};
    static const uint8_t aud[2] = {0x09, 0xF0};
    put(&buf, &len, sc3, 3);
    put(&buf, &len, aud, 2);
    put(&buf, &len, sc3, 3);
    put(&buf, &len, S1.sps, S1.sps_len);
    put(&buf, &len, sc3, 3);
    put(&buf, &len, S1.pps, S1.pps_len);
    NthSlice t1 = {1, 0, NULL, 0};
    for_each_nal(S1.aus[0].data, S1.aus[0].size, nth_slice_fn, &t1);
    put(&buf, &len, sc3, 3);
    put(&buf, &len, t1.nal, t1.n);
    h264_au_census(buf, len, &c);
    CHECK(c.nal_count == 4 && c.nal_types[0] == 9 && c.nal_types[1] == 7 && c.nal_types[2] == 8 && c.nal_types[3] == 5 &&
              c.slices == 1 && c.first_mb_first_slice == 0,
          "3-byte start codes: %u NAL units, slices %u, first_mb %d", c.nal_count, c.slices, c.first_mb_first_slice);
    free(buf);

    // An emulation-prevention byte inside first_mb_in_slice: ue(v) with 30 leading zeros (the
    // first three RBSP bytes are 00, so the NAL carries 00 00 03 00). Hand-built: the value is
    // only right if the census strips the 03 and reads the 61 bits of the ue(v) in full.
    const uint32_t big = (1u << 30) - 1 + 0x2ABCDEFu;
    uint8_t rbsp[16] = {0};
    size_t bit = 0;
    for (int k = 0; k < 30; k++) bit++; // leading zeros
    rbsp[bit >> 3] |= (uint8_t)(0x80 >> (bit & 7)), bit++;
    const uint32_t suffix = big + 1 - (1u << 30);
    for (int k = 29; k >= 0; k--, bit++)
        if ((suffix >> k) & 1) rbsp[bit >> 3] |= (uint8_t)(0x80 >> (bit & 7));
    rbsp[bit >> 3] |= (uint8_t)(0x80 >> (bit & 7)), bit++; // slice_type ue 0, then padding
    const size_t rbsp_len = (bit + 7) / 8 + 4;
    uint8_t nal[32];
    size_t nn = 0, ep_zeros = 0;
    nal[nn++] = 0x01; // nal_ref_idc 0, type 1
    for (size_t k = 0; k < rbsp_len; k++) {
        if (ep_zeros >= 2 && rbsp[k] <= 3) {
            nal[nn++] = 3;
            ep_zeros = 0;
        }
        nal[nn++] = rbsp[k];
        ep_zeros = rbsp[k] == 0 ? ep_zeros + 1 : 0;
    }
    CHECK(nal[1] == 0 && nal[2] == 0 && nal[3] == 3, "the hand-built NAL has no emulation-prevention byte");
    buf = NULL;
    len = 0;
    put_nal(&buf, &len, nal, nn);
    h264_au_census(buf, len, &c);
    CHECK(c.slices == 1 && c.first_mb_first_slice == (int32_t)big, "emulation prevention: first_mb %d, want %u",
          c.first_mb_first_slice, big);
    free(buf);
}

// One libSceVideodec decoder on the fake guest memory.
typedef struct VRun {
    uint64_t cfg, ri, ctrl, in, fb, pic, buf, au_buf, buf_size, au_cap;
    int32_t expect_rc; // what Decode/Flush must return (0, or an error a test provokes)
    int32_t last_rc;
} VRun;

static void vrun_open(VRun *r, int w, int h, uint64_t buf_size, uint64_t au_cap) {
    memset(r, 0, sizeof(*r));
    r->cfg = galloc(0x30, 16);
    r->ri = galloc(0x40, 16);
    r->ctrl = galloc(0x18, 16);
    r->in = galloc(0x30, 16);
    r->fb = galloc(0x18, 16);
    r->pic = galloc(0x70, 16);
    r->buf_size = buf_size;
    r->au_cap = au_cap;
    r->buf = galloc(buf_size, 0x100);
    r->au_buf = galloc(au_cap, 0x100);
    wr64(r->cfg, 0x28);
    wr32(r->cfg + 0x0c, 0x64);
    wr32(r->cfg + 0x10, 0x2a);
    wr32(r->cfg + 0x14, (uint32_t)w);
    wr32(r->cfg + 0x18, (uint32_t)h);
    wr32(r->cfg + 0x1c, (uint32_t)-1);
    CHECK(call(shim_sceVideodecQueryResourceInfo, r->cfg, r->ri, 0, 0) == 0, "QueryResourceInfo");
    wr64(r->ctrl, 0x18);
    CHECK(call(shim_sceVideodecCreateDecoder, r->cfg, r->ri, r->ctrl, 0) == 0, "Videodec CreateDecoder");
}

static void vrun_fb(VRun *r) {
    wr64(r->fb, 0x18);
    wr64(r->fb + 8, r->buf);
    wr64(r->fb + 0x10, r->buf_size);
}

// Decodes one access unit; returns whether a picture came out.
static bool vrun_decode(VRun *r, const uint8_t *au, size_t n, uint64_t pts, uint64_t dts, uint64_t attached) {
    CHECK(n <= r->au_cap, "access unit of %zu bytes", n);
    if (n > r->au_cap) return false;
    vrun_fb(r);
    memcpy(gp(r->au_buf), au, n);
    wr64(r->in, 0x30);
    wr64(r->in + 0x08, r->au_buf);
    wr64(r->in + 0x10, n);
    wr64(r->in + 0x18, pts);
    wr64(r->in + 0x20, dts);
    wr64(r->in + 0x28, attached);
    const int32_t rc = r->last_rc = call(shim_sceVideodecDecode, r->ctrl, r->in, r->fb, r->pic);
    CHECK(rc == 0 || rc == r->expect_rc, "Videodec Decode 0x%x", rc);
    return rd32(r->pic + 0x08) != 0;
}

static bool vrun_flush(VRun *r) {
    vrun_fb(r);
    const int32_t rc = r->last_rc = call(shim_sceVideodecFlush, r->ctrl, r->fb, r->pic, 0);
    CHECK(rc == 0 || rc == r->expect_rc, "Videodec Flush 0x%x", rc);
    return rd32(r->pic + 0x08) != 0;
}

static Ps4VideodecStats vrun_stats(VRun *r) {
    Ps4VideodecStats st;
    memset(&st, 0xEE, sizeof(st));
    CHECK(ps4_videodec_stats(g.mem_base, r->ctrl, &st) == 0, "ps4_videodec_stats");
    return st;
}

static void vrun_close(VRun *r) {
    CHECK(call(shim_sceVideodecDeleteDecoder, r->ctrl, 0, 0, 0) == 0, "Videodec DeleteDecoder");
    Ps4VideodecStats st;
    CHECK(ps4_videodec_stats(g.mem_base, r->ctrl, &st) != 0, "ps4_videodec_stats on a deleted decoder");
}

// Display index of a picture of size w x h at pitch (luma levels as level_top/level_bottom).
static int display_of_dims(uint64_t fb, int w, int h, int pitch) {
    long st = 0, nt = 0, sb = 0, nb = 0;
    for (int y = 20; y < h - 20; y += 7)
        for (int x = 20; x < w - 20; x += 7) {
            if (y < h / 2 - 20) st += rd8(fb + (uint64_t)y * (uint64_t)pitch + (uint64_t)x), nt++;
            else if (y >= h / 2 + 20) sb += rd8(fb + (uint64_t)y * (uint64_t)pitch + (uint64_t)x), nb++;
        }
    const int top = (int)(st / nt), bot = (int)(sb / nb);
    const int lo = (top - 40 + 2) / 5, hi = (bot - 40 + 20) / 40;
    const int i = hi * 30 + lo;
    if (lo < 0 || lo >= 30 || hi < 0 || abs(top - level_top(i)) > 3 || abs(bot - level_bottom(i)) > 3) return -1;
    return i;
}

// Feeds a whole stream through Decode then Flush; checks display order and the counters.
static void videodec_counts(const Stream *s, int w, int h) {
    VRun r;
    const uint64_t buf_size = 0x200000;
    vrun_open(&r, w, h, buf_size, AU_BUF);
    const int pitch = (int)h264vt_pitch((uint32_t)w);
    int got = 0, order_ok = 1;
    for (int j = 0; j < s->count + MAXN; j++) {
        const bool pic = j < s->count ? vrun_decode(&r, s->aus[j].data, s->aus[j].size,
                                                    (uint64_t)s->aus[j].display * 3003, (uint64_t)j * 3003, (uint64_t)j)
                                      : vrun_flush(&r);
        if (!pic) {
            if (j >= s->count) break;
            continue;
        }
        if (display_of_dims(r.buf, w, h, pitch) != got || rd64(r.pic + 0x20) != (uint64_t)got * 3003) order_ok = 0;
        got++;
    }
    const Ps4VideodecStats st = vrun_stats(&r);
    fprintf(stderr,
            "videodec counts %s: AUs %llu (slices %llu, max per AU %u, mid-picture %llu), pictures %llu (flushed %llu, "
            "error %llu), mono %.3f..%.3f, pts %lld..%lld, fb min 0x%llx need 0x%llx\n",
            s->name, (unsigned long long)st.aus, (unsigned long long)st.slices, st.max_slices_per_au,
            (unsigned long long)st.mid_picture_aus, (unsigned long long)st.pictures,
            (unsigned long long)st.flush_pictures, (unsigned long long)st.error_pictures, st.first_picture_mono,
            st.last_picture_mono, (long long)st.first_pts, (long long)st.last_pts, (unsigned long long)st.min_fb_size,
            (unsigned long long)st.need_fb_size);
    CHECK(got == s->count && order_ok, "%s: %d pictures (order %d)", s->name, got, order_ok);
    CHECK(st.aus == (uint64_t)s->count, "%s: aus %llu", s->name, (unsigned long long)st.aus);
    CHECK(st.pictures == (uint64_t)s->count, "%s: pictures %llu", s->name, (unsigned long long)st.pictures);
    CHECK(st.flush_pictures >= 1 && st.flush_pictures < st.pictures, "%s: flushed %llu", s->name,
          (unsigned long long)st.flush_pictures);
    CHECK(st.error_pictures == 0 && st.mid_picture_aus == 0, "%s: error %llu mid-picture %llu", s->name,
          (unsigned long long)st.error_pictures, (unsigned long long)st.mid_picture_aus);
    CHECK(st.max_slices_per_au == s->max_slices, "%s: max slices per AU %u, census %u", s->name, st.max_slices_per_au,
          s->max_slices);
    CHECK(st.min_fb_size == buf_size, "%s: min_fb_size 0x%llx", s->name, (unsigned long long)st.min_fb_size);
    CHECK(st.need_fb_size == h264vt_nv12_size((uint32_t)w, (uint32_t)h), "%s: need_fb_size 0x%llx", s->name,
          (unsigned long long)st.need_fb_size);
    CHECK(st.first_pts == 0 && st.last_pts == (int64_t)(s->count - 1) * 3003, "%s: pts %lld..%lld", s->name,
          (long long)st.first_pts, (long long)st.last_pts);
    CHECK(st.first_picture_mono > 0 && st.last_picture_mono >= st.first_picture_mono, "%s: mono %.3f..%.3f", s->name,
          st.first_picture_mono, st.last_picture_mono);
    vrun_close(&r);
}

// Two corrupt access units of S1, made as in test_error_pictures (a): two error pictures,
// dropped. They are the last two in decode order: after bad data VideoToolbox fails every access
// unit up to the next IDR, also ones that do not predict from it (test_error_pictures (a) gets
// 25 error pictures from two corrupt ones in a one-IDR stream).
static void videodec_error_counts(void) {
    const int bad[2] = {S1.count - 2, S1.count - 1};
    VRun r;
    vrun_open(&r, W, H, 0x100000, AU_BUF);
    int got = 0;
    for (int j = 0; j < S1.count + MAXN; j++) {
        bool pic;
        if (j < S1.count) {
            uint8_t *buf = (uint8_t *)malloc(S1.aus[j].size);
            memcpy(buf, S1.aus[j].data, S1.aus[j].size);
            if (j == bad[0] || j == bad[1]) {
                size_t s = nth_start(&S1.aus[j], 2) + 4;
                for (size_t i = s + 3; i < S1.aus[j].size; i++) buf[i] = (uint8_t)(0xA5 ^ (i * 7));
            }
            pic = vrun_decode(&r, buf, S1.aus[j].size, (uint64_t)S1.aus[j].display * 3003, (uint64_t)j * 3003,
                              (uint64_t)j);
            free(buf);
        } else {
            pic = vrun_flush(&r);
            if (!pic) break;
        }
        got += pic;
    }
    const Ps4VideodecStats st = vrun_stats(&r);
    fprintf(stderr, "videodec corrupt AUs %d and %d: pictures %llu, error %llu\n", bad[0], bad[1],
            (unsigned long long)st.pictures, (unsigned long long)st.error_pictures);
    CHECK(st.error_pictures == 2, "corrupt: error_pictures %llu", (unsigned long long)st.error_pictures);
    CHECK(st.pictures == (uint64_t)S1.count - 2 && got == S1.count - 2, "corrupt: pictures %llu (got %d)",
          (unsigned long long)st.pictures, got);
    vrun_close(&r);
}

// PS4_VIDEODEC_DUMP=<dir>:5 writes S1's picture 5 (display order) as dec<n>_pic5.nv12: a 16-byte
// header (u16 width, u16 height, u32 pitch, i64 pts, little-endian) and the NV12 bytes the guest
// frame buffer received.
static void videodec_dump(void) {
    char dir[] = "/tmp/vdecsw_dump_XXXXXX";
    CHECK(mkdtemp(dir) != NULL, "mkdtemp");
    char env[64];
    snprintf(env, sizeof(env), "%s:5", dir);
    setenv("PS4_VIDEODEC_DUMP", env, 1);
    VRun r;
    vrun_open(&r, W, H, 0x100000, AU_BUF);
    unsetenv("PS4_VIDEODEC_DUMP"); // read when the decoder is created
    uint8_t *want = (uint8_t *)malloc(FRAME_SIZE);
    int got = 0;
    for (int j = 0; j < S1.count + MAXN; j++) {
        const bool pic = j < S1.count ? vrun_decode(&r, S1.aus[j].data, S1.aus[j].size,
                                                    (uint64_t)S1.aus[j].display * 3003, (uint64_t)j * 3003, (uint64_t)j)
                                      : vrun_flush(&r);
        if (!pic) {
            if (j >= S1.count) break;
            continue;
        }
        if (got == 5) memcpy(want, gp(r.buf), FRAME_SIZE);
        got++;
    }
    vrun_close(&r);
    CHECK(got == S1.count, "dump run: %d pictures", got);
    // Exactly one file, dec<n>_pic5.nv12.
    char path[256] = "";
    int files = 0;
    DIR *dd = opendir(dir);
    for (struct dirent *e; dd && (e = readdir(dd)) != NULL;) {
        if (e->d_name[0] == '.') continue;
        files++;
        unsigned n;
        char tail[32];
        CHECK(sscanf(e->d_name, "dec%u_pic5%31s", &n, tail) == 2 && strcmp(tail, ".nv12") == 0, "dump file %s",
              e->d_name);
        snprintf(path, sizeof(path), "%s/%s", dir, e->d_name);
    }
    if (dd) closedir(dd);
    CHECK(files == 1, "%d dump files", files);
    FILE *f = files == 1 ? fopen(path, "rb") : NULL;
    if (f) {
        uint8_t hdr[16];
        uint8_t *data = (uint8_t *)malloc(FRAME_SIZE + 1);
        const size_t nh = fread(hdr, 1, sizeof(hdr), f);
        const size_t nd = fread(data, 1, FRAME_SIZE + 1, f);
        fclose(f);
        uint16_t w, h;
        uint32_t pitch;
        int64_t pts;
        memcpy(&w, hdr, 2);
        memcpy(&h, hdr + 2, 2);
        memcpy(&pitch, hdr + 4, 4);
        memcpy(&pts, hdr + 8, 8);
        CHECK(nh == 16 && w == W && h == H && pitch == PITCH && pts == 5 * 3003, "dump header %ux%u pitch %u pts %lld",
              w, h, pitch, (long long)pts);
        CHECK(nd == FRAME_SIZE, "dump data %zu bytes", nd);
        CHECK(memcmp(data, want, FRAME_SIZE) == 0, "dump differs from the guest frame buffer");
        // The luma levels: the dump shows display index 5, as the guest frame buffer did.
        const uint64_t scratch = galloc(FRAME_SIZE, 0x100);
        memcpy(gp(scratch), data, FRAME_SIZE);
        CHECK(display_of_dims(scratch, W, H, PITCH) == 5, "dump shows frame %d", display_of_dims(scratch, W, H, PITCH));
        free(data);
    }
    if (path[0]) unlink(path);
    rmdir(dir);
    free(want);
}

// Captures stderr into a temporary file between cap_begin and cap_end.
typedef struct Cap {
    int saved;
    char path[64];
} Cap;
static void cap_begin(Cap *c) {
    fflush(stderr);
    snprintf(c->path, sizeof(c->path), "/tmp/vdecsw_err_XXXXXX");
    const int fd = mkstemp(c->path);
    c->saved = dup(2);
    dup2(fd, 2);
    close(fd);
}
static char *cap_end(Cap *c) {
    fflush(stderr);
    dup2(c->saved, 2);
    close(c->saved);
    FILE *f = fopen(c->path, "rb");
    char *text = (char *)calloc(1, 1 << 20);
    if (f) {
        fread(text, 1, (1 << 20) - 1, f);
        fclose(f);
    }
    unlink(c->path);
    fputs(text, stderr); // still in the test output
    return text;
}

static int count_files(const char *dir) {
    int n = 0;
    DIR *dd = opendir(dir);
    for (struct dirent *e; dd && (e = readdir(dd)) != NULL;) n += e->d_name[0] != '.';
    if (dd) closedir(dd);
    return n;
}

// A PS4_VIDEODEC_DUMP that cannot be used: no file, the reason in the log, decoding unchanged.
static void videodec_dump_bad(const char *value, const char *dir_to_check, const char *expect) {
    setenv("PS4_VIDEODEC_DUMP", value, 1);
    Cap cap;
    cap_begin(&cap);
    VRun r;
    vrun_open(&r, W, H, 0x100000, AU_BUF);
    unsetenv("PS4_VIDEODEC_DUMP");
    int got = 0, order_ok = 1;
    for (int j = 0; j < S1.count + MAXN; j++) {
        const bool pic = j < S1.count ? vrun_decode(&r, S1.aus[j].data, S1.aus[j].size,
                                                    (uint64_t)S1.aus[j].display * 3003, (uint64_t)j * 3003, (uint64_t)j)
                                      : vrun_flush(&r);
        if (!pic) {
            if (j >= S1.count) break;
            continue;
        }
        if (display_of_dims(r.buf, W, H, PITCH) != got) order_ok = 0;
        got++;
    }
    const Ps4VideodecStats st = vrun_stats(&r);
    vrun_close(&r);
    char *log = cap_end(&cap);
    CHECK(got == S1.count && order_ok && st.pictures == (uint64_t)S1.count && st.error_pictures == 0,
          "dump %s: %d pictures (order %d)", value, got, order_ok);
    CHECK(strstr(log, expect) != NULL, "dump %s: no \"%s\" in the log", value, expect);
    CHECK(count_files(dir_to_check) == 0, "dump %s: files written in %s", value, dir_to_check);
    free(log);
}

static void videodec_dump_failures(void) {
    char dir[] = "/tmp/vdecsw_dump_XXXXXX";
    CHECK(mkdtemp(dir) != NULL, "mkdtemp");
    char v[128], missing[96];
    snprintf(missing, sizeof(missing), "%s/missing", dir);
    snprintf(v, sizeof(v), "%s:5", missing); // a directory that does not exist
    videodec_dump_bad(v, dir, "could not write");
    snprintf(v, sizeof(v), "%s:abc", dir);
    videodec_dump_bad(v, dir, "PS4_VIDEODEC_DUMP");
    snprintf(v, sizeof(v), "%s:-1", dir);
    videodec_dump_bad(v, dir, "PS4_VIDEODEC_DUMP");
    rmdir(dir);
}

// A frame buffer too small for the picture: Decode and Flush report the error, the picture is
// dropped and counted, so access units and pictures reconcile.
static void videodec_refused(void) {
    VRun r;
    vrun_open(&r, W, H, 0x1000, AU_BUF);
    r.expect_rc = (int32_t)0x80C10008; // SCE_VIDEODEC_ERROR_FRAME_BUFFER_SIZE
    int errors = 0;
    for (int j = 0; j < S1.count; j++) {
        CHECK(!vrun_decode(&r, S1.aus[j].data, S1.aus[j].size, (uint64_t)S1.aus[j].display * 3003, (uint64_t)j * 3003,
                           (uint64_t)j),
              "a picture in a 4 KiB buffer");
        errors += r.last_rc != 0;
    }
    for (int k = 0; k < MAXN; k++) {
        const bool pic = vrun_flush(&r);
        CHECK(!pic, "a flushed picture in a 4 KiB buffer");
        if (r.last_rc == 0) break;
        errors++;
    }
    const Ps4VideodecStats st = vrun_stats(&r);
    fprintf(stderr, "videodec refused: AUs %llu, pictures %llu, error %llu, refused %llu (%d calls failed)\n",
            (unsigned long long)st.aus, (unsigned long long)st.pictures, (unsigned long long)st.error_pictures,
            (unsigned long long)st.refused_pictures, errors);
    CHECK(st.pictures == 0 && st.error_pictures == 0 && st.refused_pictures == (uint64_t)S1.count &&
              errors == S1.count,
          "refused: %llu pictures, %llu refused, %d failed calls", (unsigned long long)st.pictures,
          (unsigned long long)st.refused_pictures, errors);
    CHECK(st.pictures + st.error_pictures + st.refused_pictures == st.aus, "AUs and pictures do not reconcile");
    CHECK(st.min_fb_size == 0x1000 && st.need_fb_size == FRAME_SIZE, "refused: fb min 0x%llx need 0x%llx",
          (unsigned long long)st.min_fb_size, (unsigned long long)st.need_fb_size);
    vrun_close(&r);
}

// ---- The inFAMOUS splash (tests/host/data/game/infamous/splash_europe.bsf, game data) ----

typedef struct MiniBits {
    const uint8_t *p;
    size_t n, pos; // pos in bits over the RBSP
    bool bad;
} MiniBits;
static uint32_t mb_u(MiniBits *b, int k) {
    uint32_t v = 0;
    while (k--) {
        if (b->pos >= b->n * 8) {
            b->bad = true;
            return 0;
        }
        v = (v << 1) | ((b->p[b->pos >> 3] >> (7 - (b->pos & 7))) & 1u);
        b->pos++;
    }
    return v;
}
static uint32_t mb_ue(MiniBits *b) {
    int lz = 0;
    while (mb_u(b, 1) == 0 && !b->bad)
        if (++lz > 31) b->bad = true;
    return lz ? ((1u << lz) - 1u) + mb_u(b, lz) : 0;
}
static size_t to_rbsp(const uint8_t *src, size_t n, uint8_t *dst, size_t cap) {
    size_t o = 0;
    int z = 0;
    for (size_t i = 0; i < n && o < cap; i++) {
        if (z >= 2 && src[i] == 3) {
            z = 0;
            continue;
        }
        z = src[i] == 0 ? z + 1 : 0;
        dst[o++] = src[i];
    }
    return o;
}

// The splash's split into access units (7.4.1.2.3) and its display order, from the test's own
// slice-header reading (POC type 0, frames only; the x264 encode of the splash is that).
typedef struct Splash {
    const uint8_t *data;
    size_t *start, *end; // access unit byte ranges
    int *rank;           // display index of each access unit
    int count, cap;
    uint32_t max_slices;
    // parser state
    bool in_au, after_slice;
    size_t au_start;
    uint32_t log2_max_frame_num, log2_max_poc_lsb, poc_type;
    bool frame_mbs_only, pps_bottom_field_poc;
    int32_t prev_msb, prev_lsb;
    int64_t *key; // (IDR period << 32) + POC, per access unit
    int64_t period;
    bool bad;
} Splash;

static void splash_sps(Splash *sp, const uint8_t *nal, size_t n) {
    uint8_t r[64];
    MiniBits b = {r, to_rbsp(nal + 1, n - 1, r, sizeof(r)), 0, false};
    const uint32_t profile = mb_u(&b, 8);
    mb_u(&b, 16); // constraint flags, level_idc
    mb_ue(&b);    // seq_parameter_set_id
    if (profile == 100) {
        if (mb_ue(&b) == 3) mb_u(&b, 1); // chroma_format_idc, separate_colour_plane_flag
        mb_ue(&b);
        mb_ue(&b);
        mb_u(&b, 1);
        if (mb_u(&b, 1)) sp->bad = true; // seq_scaling_matrix_present_flag: not in the splash
    }
    sp->log2_max_frame_num = mb_ue(&b) + 4;
    sp->poc_type = mb_ue(&b);
    if (sp->poc_type == 0) sp->log2_max_poc_lsb = mb_ue(&b) + 4;
    else sp->bad = true;
    mb_ue(&b);   // max_num_ref_frames
    mb_u(&b, 1); // gaps_in_frame_num_value_allowed_flag
    mb_ue(&b);
    mb_ue(&b);
    sp->frame_mbs_only = mb_u(&b, 1);
    if (!sp->frame_mbs_only) sp->bad = true;
    if (b.bad) sp->bad = true;
}

static void splash_pps(Splash *sp, const uint8_t *nal, size_t n) {
    uint8_t r[16];
    MiniBits b = {r, to_rbsp(nal + 1, n - 1, r, sizeof(r)), 0, false};
    mb_ue(&b); // pic_parameter_set_id
    mb_ue(&b); // seq_parameter_set_id
    mb_u(&b, 1); // entropy_coding_mode_flag
    sp->pps_bottom_field_poc = mb_u(&b, 1);
    if (b.bad) sp->bad = true;
}

// Room for the access unit being opened (index count).
static void splash_grow(Splash *sp) {
    if (sp->count < sp->cap) return;
    sp->cap = sp->cap ? sp->cap * 2 : 512;
    sp->start = (size_t *)realloc(sp->start, sizeof(size_t) * (size_t)sp->cap);
    sp->end = (size_t *)realloc(sp->end, sizeof(size_t) * (size_t)sp->cap);
    sp->key = (int64_t *)realloc(sp->key, sizeof(int64_t) * (size_t)sp->cap);
}

static void splash_close_au(Splash *sp, size_t end) {
    if (!sp->in_au) return;
    sp->start[sp->count] = sp->au_start;
    sp->end[sp->count] = end;
    sp->count++;
    sp->in_au = false;
}

static void splash_nal(void *u, const uint8_t *nal, size_t n, size_t sc_off) {
    Splash *sp = (Splash *)u;
    const int type = nal[0] & 0x1f;
    const bool vcl = type >= 1 && type <= 5;
    int32_t first_mb = -1;
    H264AuCensus c;
    if (vcl) {
        // The census of the NAL alone gives first_mb_in_slice.
        uint8_t hdr[4 + 32];
        const size_t k = n < 32 ? n : 32;
        hdr[0] = hdr[1] = hdr[2] = 0;
        hdr[3] = 1;
        memcpy(hdr + 4, nal, k);
        h264_au_census(hdr, 4 + k, &c);
        first_mb = c.first_mb_first_slice;
    }
    const bool starts = sp->after_slice && ((type >= 6 && type <= 9) || (type >= 14 && type <= 18) || (vcl && first_mb == 0));
    // A leading zero byte belongs to the start code of the new access unit.
    const size_t sc = sc_off > 0 && sp->data[sc_off - 1] == 0 ? sc_off - 1 : sc_off;
    if (starts) splash_close_au(sp, sc);
    if (!sp->in_au) {
        splash_grow(sp);
        sp->key[sp->count] = INT64_MAX; // an access unit without a first slice sorts last
        sp->in_au = true;
        sp->au_start = sc;
        sp->after_slice = false;
    }
    if (type == 7) splash_sps(sp, nal, n);
    if (type == 8) splash_pps(sp, nal, n);
    if (vcl && first_mb == 0) {
        uint8_t r[48];
        MiniBits b = {r, to_rbsp(nal + 1, n - 1, r, sizeof(r)), 0, false};
        mb_ue(&b); // first_mb_in_slice
        mb_ue(&b); // slice_type
        mb_ue(&b); // pic_parameter_set_id
        mb_u(&b, (int)sp->log2_max_frame_num);
        if (type == 5) mb_ue(&b); // idr_pic_id
        const int32_t lsb = (int32_t)mb_u(&b, (int)sp->log2_max_poc_lsb);
        if (b.bad || sp->log2_max_poc_lsb == 0) sp->bad = true;
        const int32_t max_lsb = 1 << sp->log2_max_poc_lsb;
        if (type == 5) {
            sp->period++;
            sp->prev_msb = sp->prev_lsb = 0;
        }
        int32_t msb = sp->prev_msb;
        if (lsb < sp->prev_lsb && sp->prev_lsb - lsb >= max_lsb / 2) msb += max_lsb;
        else if (lsb > sp->prev_lsb && lsb - sp->prev_lsb > max_lsb / 2) msb -= max_lsb;
        if (nal[0] >> 5) { // reference picture
            sp->prev_msb = msb;
            sp->prev_lsb = lsb;
        }
        sp->key[sp->count] = (sp->period << 32) + (int64_t)(msb + lsb);
    }
    if (vcl) sp->after_slice = true;
}

static const int64_t *g_sort_key;
static int cmp_key(const void *a, const void *b) {
    const int64_t x = g_sort_key[*(const int *)a], y = g_sort_key[*(const int *)b];
    return x < y ? -1 : x > y;
}

static void test_videodec_splash(const char *path) {
    FILE *f = path ? fopen(path, "rb") : NULL;
    if (!f) {
        printf("SKIP: videodec splash fixture: needs local fixture tests/host/data/game/infamous/splash_europe.bsf (game "
               "data, not distributed)\n");
        return;
    }
    fseek(f, 0, SEEK_END);
    const long size = ftell(f);
    fseek(f, 0, SEEK_SET);
    uint8_t *data = (uint8_t *)malloc((size_t)size);
    CHECK(fread(data, 1, (size_t)size, f) == (size_t)size, "read %s", path);
    fclose(f);
    Splash sp;
    memset(&sp, 0, sizeof(sp));
    sp.data = data;
    for_each_nal(data, (size_t)size, splash_nal, &sp);
    splash_close_au(&sp, (size_t)size);
    CHECK(!sp.bad, "splash: slice headers the test does not read");
    // Display order: by IDR period, then POC. The first access unit (SEI, SPS, PPS, the first
    // IDR's slices) is a picture too, so every access unit has a key.
    int *order = (int *)malloc(sizeof(int) * (size_t)sp.count);
    sp.rank = (int *)malloc(sizeof(int) * (size_t)sp.count);
    for (int i = 0; i < sp.count; i++) order[i] = i;
    g_sort_key = sp.key;
    qsort(order, (size_t)sp.count, sizeof(int), cmp_key);
    for (int i = 0; i < sp.count; i++) sp.rank[order[i]] = i;
    uint32_t max_slices = 0;
    uint64_t slices = 0, max_au = 0;
    for (int i = 0; i < sp.count; i++) {
        H264AuCensus c;
        h264_au_census(data + sp.start[i], sp.end[i] - sp.start[i], &c);
        slices += c.slices;
        if (c.slices > max_slices) max_slices = c.slices;
        if (sp.end[i] - sp.start[i] > max_au) max_au = sp.end[i] - sp.start[i];
        CHECK(c.slices >= 1 && c.first_mb_first_slice == 0, "splash au %d: slices %u first_mb %d", i, c.slices,
              c.first_mb_first_slice);
    }
    fprintf(stderr, "splash census: %d access units, %llu slices, max per AU %u, largest AU %llu bytes\n", sp.count,
            (unsigned long long)slices, max_slices, (unsigned long long)max_au);

    VRun r;
    const uint64_t fb_size = h264vt_nv12_size(1920, 1080);
    vrun_open(&r, 1920, 1088, fb_size, (max_au + 0xFFFF) & ~0xFFFFULL);
    int got = 0, order_ok = 1;
    for (int i = 0; i < sp.count + 64; i++) {
        bool pic;
        if (i < sp.count)
            pic = vrun_decode(&r, data + sp.start[i], sp.end[i] - sp.start[i], (uint64_t)sp.rank[i] * 3003,
                              (uint64_t)i * 3003, (uint64_t)i);
        else if (!(pic = vrun_flush(&r)))
            break;
        if (!pic) continue;
        if (rd64(r.pic + 0x20) != (uint64_t)got * 3003) order_ok = 0;
        CHECK(rd32(r.pic + 0x10) == 1920 && rd32(r.pic + 0x14) == 1920 && rd32(r.pic + 0x18) == 1088,
              "splash picture %d: %ux%u pitch %u", got, rd32(r.pic + 0x10), rd32(r.pic + 0x18), rd32(r.pic + 0x14));
        got++;
    }
    const Ps4VideodecStats st = vrun_stats(&r);
    fprintf(stderr, "splash decode: pictures %llu (flushed %llu, error %llu), max slices per AU %u, mid-picture %llu\n",
            (unsigned long long)st.pictures, (unsigned long long)st.flush_pictures,
            (unsigned long long)st.error_pictures, st.max_slices_per_au, (unsigned long long)st.mid_picture_aus);
    CHECK(sp.count == 309 && st.aus == 309, "splash: %d access units (%llu fed)", sp.count, (unsigned long long)st.aus);
    CHECK(st.pictures == 309 && got == 309, "splash: %llu pictures (%d seen)", (unsigned long long)st.pictures, got);
    CHECK(st.error_pictures == 0 && st.mid_picture_aus == 0, "splash: error %llu mid-picture %llu",
          (unsigned long long)st.error_pictures, (unsigned long long)st.mid_picture_aus);
    CHECK(order_ok, "splash: pictures not in display order");
    CHECK(st.max_slices_per_au == 17 && max_slices == 17, "splash: max slices per AU %u (census %u)",
          st.max_slices_per_au, max_slices);
    CHECK(st.first_pts == 0 && st.last_pts == 308 * 3003, "splash: pts %lld..%lld", (long long)st.first_pts,
          (long long)st.last_pts);
    vrun_close(&r);
    free(order);
    free(sp.rank);
    free(sp.start);
    free(sp.end);
    free(sp.key);
    free(data);
}

int main(int argc, char **argv) {
    make_stream(&S1, "S1", 30, 1000, true);
    make_stream(&S2, "S2", 30, 10, false);
    make_stream(&S3, "S3", 40, 10, true);
    make_stream(&S4, "S4", MAXN, 1000, true);
    // S5: multi-slice pictures (the inFAMOUS movies have about 17 per picture), from the
    // software encoder (see StreamOpts).
    const StreamOpts s5 = {640, 368, true};
    make_stream_opts(&S5, "S5", 30, 1000, true, &s5);
    // The test is about display reordering: the encoder must have produced B-frames.
    CHECK(S1.reordered > 0 && S3.reordered > 0 && S4.reordered > 0, "the encoder produced no B-frames");
    CHECK(S2.reordered == 0 && S2.keys >= 3, "S2: %d reordered, %d keys", S2.reordered, S2.keys);
    CHECK(S3.keys >= 3, "S3: %d keys", S3.keys);

    H264SpsInfo sps;
    CHECK(h264_parse_sps(S1.sps, S1.sps_len, &sps), "SPS parse");
    CHECK(sps.profile_idc == 100, "SPS profile %u", sps.profile_idc);
    CHECK((sps.pic_width_in_mbs_minus1 + 1) * 16 - 2 * (sps.frame_crop_left_offset + sps.frame_crop_right_offset) == W,
          "SPS width");
    CHECK((sps.pic_height_in_map_units_minus1 + 1) * 16 - 2 * (sps.frame_crop_top_offset + sps.frame_crop_bottom_offset) ==
              H,
          "SPS height");
    g_expected_level_idc = S1.sps[3];

    g.mem_size = 128ULL << 20;
    g.mem_base = (uint8_t *)calloc(1, g.mem_size);
    test_setup_and_errors();
    test_zero_delay();
    test_reorder_streams();
    test_interleaved();
    test_error_pictures();
    test_delete_race();
    test_reset_race();
    test_reset_forgets_last_poc();
    test_idr_error_flush();
    test_videodec();
    test_au_census();
    videodec_counts(&S1, W, H);
    setenv("PS4_VIDEODEC_LOG", "1", 1); // the trace path runs too (under ASan)
    videodec_counts(&S5, 640, 368);
    unsetenv("PS4_VIDEODEC_LOG");
    videodec_error_counts();
    videodec_dump();
    videodec_dump_failures();
    videodec_refused();
    test_videodec_splash(argc > 1 ? argv[1] : NULL);
    if (atomic_load(&failures)) {
        fprintf(stderr, "vdecsw_test: %d failure(s)\n", atomic_load(&failures));
        return 1;
    }
    printf("vdecsw_test: PASS\n");
    return 0;
}
