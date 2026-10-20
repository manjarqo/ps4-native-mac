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
// and libSceVideodec.
#include "recomp_runtime.h"
#include "ps4_h264_vt.h"

#include <CoreMedia/CoreMedia.h>
#include <CoreVideo/CoreVideo.h>
#include <VideoToolbox/VideoToolbox.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

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

static void make_stream(Stream *st, const char *name, int n, int gop, bool reorder) {
    memset(st, 0, sizeof(*st));
    st->name = name;
    VTCompressionSessionRef s = NULL;
    OSStatus rc = VTCompressionSessionCreate(NULL, W, H, kCMVideoCodecType_H264, NULL, NULL, NULL, enc_cb, st, &s);
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
        CVPixelBufferCreate(NULL, W, H, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, NULL, &pb);
        CVPixelBufferLockBaseAddress(pb, 0);
        uint8_t *y = (uint8_t *)CVPixelBufferGetBaseAddressOfPlane(pb, 0);
        uint8_t *c = (uint8_t *)CVPixelBufferGetBaseAddressOfPlane(pb, 1);
        for (int r = 0; r < H; r++)
            memset(y + r * CVPixelBufferGetBytesPerRowOfPlane(pb, 0), r < H / 2 ? level_top(i) : level_bottom(i), W);
        for (int r = 0; r < H / 2; r++) memset(c + r * CVPixelBufferGetBytesPerRowOfPlane(pb, 1), 128, W);
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

static Stream S1, S2, S3, S4;

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

int main(void) {
    make_stream(&S1, "S1", 30, 1000, true);
    make_stream(&S2, "S2", 30, 10, false);
    make_stream(&S3, "S3", 40, 10, true);
    make_stream(&S4, "S4", MAXN, 1000, true);
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
    test_videodec();
    if (atomic_load(&failures)) {
        fprintf(stderr, "vdecsw_test: %d failure(s)\n", atomic_load(&failures));
        return 1;
    }
    printf("vdecsw_test: PASS\n");
    return 0;
}
