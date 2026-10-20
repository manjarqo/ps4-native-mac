// SPDX-License-Identifier: GPL-2.0-or-later
//
// Host test of libSceVdecsw and libSceVideodec on the shared VideoToolbox H.264 core.
//
// The test makes its own H.264 stream: VideoToolbox's encoder (High profile, B-frames allowed)
// encodes N flat frames whose luma level encodes the display index, at a size that is not a
// multiple of 16 in height (so cropping and padding are exercised). The samples are turned into
// Annex-B access units (AUD, SPS/PPS before key frames, 00 00 00 01 start codes) as U4's player
// does. The access units are then fed through the guest API on a fake guest memory, in U4's call
// order (QueryComputeMemoryInfo, AllocateComputeQueue, QueryDecoderMemoryInfo, CreateDecoder,
// SetDecodeInput / TrySyncDecodeInput / SetDecodeOutput / TrySyncDecodeOutput /
// GetAvcPictureInfo, FinalizeDecodeSequence, ResetDecoder, DeleteDecoder), and the frame count,
// display order, dimensions, pixel data, OutputInfo and picture-info fields are checked.
#include "recomp_runtime.h"
#include "ps4_h264_vt.h"

#include <CoreMedia/CoreMedia.h>
#include <CoreVideo/CoreVideo.h>
#include <VideoToolbox/VideoToolbox.h>
#include <pthread.h>
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
#define N 30
#define PITCH 384     // align(352, 64)
#define AH 208        // align(200, 16)
#define FRAME_SIZE (PITCH * AH * 3 / 2)

#define E_STRUCT_SIZE ((int32_t)0x81510101)
#define E_DECODER_INSTANCE ((int32_t)0x81510103)
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

static int failures;
#define CHECK(cond, ...)                                                                       \
    do {                                                                                       \
        if (!(cond)) {                                                                         \
            failures++;                                                                        \
            fprintf(stderr, "FAIL %s:%d: %s: ", __FILE__, __LINE__, #cond);                    \
            fprintf(stderr, __VA_ARGS__);                                                      \
            fprintf(stderr, "\n");                                                             \
            if (failures > 40) exit(1);                                                        \
        }                                                                                      \
    } while (0)

static int level_of(int display_index) { return 40 + 5 * display_index; }

// ---------------------------------------------------------------------------------------------
// Test stream
// ---------------------------------------------------------------------------------------------

typedef struct Au {
    uint8_t *data;
    size_t size;
    int display; // presentation index
    bool key;
} Au;

static Au g_aus[N];
static int g_au_count;
static uint8_t g_sps[256], g_pps[256];
static size_t g_sps_len, g_pps_len;
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
    (void)refcon, (void)frame_refcon, (void)flags;
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
        memcpy(g_sps, ps, psz);
        g_sps_len = psz;
    }
    if (CMVideoFormatDescriptionGetH264ParameterSetAtIndex(fmt, 1, &ps, &psz, NULL, NULL) == noErr) {
        memcpy(g_pps, ps, psz);
        g_pps_len = psz;
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
    Au *au = &g_aus[g_au_count++];
    static const uint8_t aud[2] = {0x09, 0xF0};
    put_nal(&au->data, &au->size, aud, sizeof(aud));
    if (key) {
        put_nal(&au->data, &au->size, g_sps, g_sps_len);
        put_nal(&au->data, &au->size, g_pps, g_pps_len);
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

static void make_stream(void) {
    VTCompressionSessionRef s = NULL;
    OSStatus st = VTCompressionSessionCreate(NULL, W, H, kCMVideoCodecType_H264, NULL, NULL, NULL, enc_cb, NULL, &s);
    if (st != noErr) {
        fprintf(stderr, "VTCompressionSessionCreate: %d\n", (int)st);
        exit(1);
    }
    VTSessionSetProperty(s, kVTCompressionPropertyKey_ProfileLevel, kVTProfileLevel_H264_High_AutoLevel);
    VTSessionSetProperty(s, kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanTrue);
    VTSessionSetProperty(s, kVTCompressionPropertyKey_RealTime, kCFBooleanFalse);
    int32_t gop = 1000;
    CFNumberRef g = CFNumberCreate(NULL, kCFNumberSInt32Type, &gop);
    VTSessionSetProperty(s, kVTCompressionPropertyKey_MaxKeyFrameInterval, g);
    CFRelease(g);
    for (int i = 0; i < N; i++) {
        CVPixelBufferRef pb = NULL;
        CVPixelBufferCreate(NULL, W, H, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, NULL, &pb);
        CVPixelBufferLockBaseAddress(pb, 0);
        uint8_t *y = (uint8_t *)CVPixelBufferGetBaseAddressOfPlane(pb, 0);
        uint8_t *c = (uint8_t *)CVPixelBufferGetBaseAddressOfPlane(pb, 1);
        for (int r = 0; r < H; r++) memset(y + r * CVPixelBufferGetBytesPerRowOfPlane(pb, 0), level_of(i), W);
        for (int r = 0; r < H / 2; r++) memset(c + r * CVPixelBufferGetBytesPerRowOfPlane(pb, 1), 128, W);
        CVPixelBufferUnlockBaseAddress(pb, 0);
        st = VTCompressionSessionEncodeFrame(s, pb, CMTimeMake(i, 30), CMTimeMake(1, 30), NULL, NULL, NULL);
        CVPixelBufferRelease(pb);
        if (st != noErr) {
            fprintf(stderr, "VTCompressionSessionEncodeFrame: %d\n", (int)st);
            exit(1);
        }
    }
    VTCompressionSessionCompleteFrames(s, kCMTimeInvalid);
    VTCompressionSessionInvalidate(s);
    CFRelease(s);
}

// ---------------------------------------------------------------------------------------------
// Guest side
// ---------------------------------------------------------------------------------------------

static GuestContext g;
static uint64_t g_brk = 0x10000;

static uint64_t galloc(uint64_t size, uint64_t align) {
    g_brk = (g_brk + align - 1) & ~(align - 1);
    uint64_t a = g_brk;
    g_brk += size;
    if (g_brk > g.mem_size) {
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

static int32_t call(void (*fn)(GuestContext *), uint64_t a, uint64_t b, uint64_t c, uint64_t d) {
    g.rdi = a;
    g.rsi = b;
    g.rdx = c;
    g.rcx = d;
    g.rax = 0xdeadbeefdeadbeefULL;
    g.rsp = 0x8000;
    fn(&g);
    if (g.rsp != 0x8008) {
        fprintf(stderr, "shim did not return through SHIM_RETURN\n");
        exit(1);
    }
    return (int32_t)g.rax;
}

static int luma_at(uint64_t fb, int x, int y) { return rd8(fb + (uint64_t)y * PITCH + x); }

// Average luma of the picture interior.
static int luma_avg(uint64_t fb) {
    long sum = 0, n = 0;
    for (int y = 20; y < H - 20; y += 7)
        for (int x = 20; x < W - 20; x += 7) {
            sum += luma_at(fb, x, y);
            n++;
        }
    return (int)(sum / n);
}

// Expected display index of each access unit (decode order) and the SPS fields.
static int g_expected_level_idc;

typedef struct Collected {
    int count;
    int display[N];   // display index derived from the pixel data
    uint64_t attached[N];
    int64_t pts[N];
    int last_flag_at; // output index that had is_last_frame, -1 if none
} Collected;

#define PIC_SIZE_REQ 0x68 // the size U4 asks for

// Checks one decoded picture (OutputInfo at oi, frame buffer fb) and records its display index.
static void check_picture(uint64_t oi, uint64_t fb, uint64_t pic, Collected *col, int mode) {
    CHECK(rd8(oi + 0x08) == 1, "is_valid %d", rd8(oi + 0x08));
    CHECK(rd8(oi + 0x0a) == 0, "is_error_frame");
    CHECK(rd8(oi + 0x0b) == 1, "picture_count %d", rd8(oi + 0x0b));
    CHECK(rd32(oi + 0x0c) == 1, "codec_type %u", rd32(oi + 0x0c));
    CHECK(rd32(oi + 0x10) == W, "frame_width %u", rd32(oi + 0x10));
    CHECK(rd32(oi + 0x14) == PITCH, "frame_pitch %u", rd32(oi + 0x14));
    CHECK(rd32(oi + 0x18) == AH, "frame_height %u", rd32(oi + 0x18));
    CHECK(rd8(oi + 0x1c) == 0, "is_discarded_frame");
    CHECK(rd64(oi + 0x20) == fb, "frame_buffer 0x%llx", (unsigned long long)rd64(oi + 0x20));
    CHECK(rd64(oi + 0x28) == FRAME_SIZE, "frame_buffer_size 0x%llx", (unsigned long long)rd64(oi + 0x28));
    // OutputInfo this_size 0x30: the 8 bytes after it belong to the caller (U4 keeps its picture
    // info there) and must not be touched.
    CHECK(rd64(oi + 0x30) == 0x1111111111111111ULL, "bytes past OutputInfo.this_size were written");

    // Pixel data: flat luma level, neutral chroma, padding rows repeat the last picture row.
    int avg = luma_avg(fb);
    int display = (avg - 40 + 2) / 5;
    CHECK(abs(avg - level_of(display)) <= 3 && display >= 0 && display < N, "luma %d is no frame level", avg);
    CHECK(luma_at(fb, 100, AH - 1) == luma_at(fb, 100, H - 1), "padding row differs from the last row");
    int cb = rd8(fb + (uint64_t)PITCH * AH + (uint64_t)(H / 4) * PITCH + 100);
    CHECK(abs(cb - 128) <= 3, "chroma %d", cb);

    CHECK(g_notify_addr == fb && g_notify_size == FRAME_SIZE + 0x78, "GPU notified of 0x%llx+0x%llx",
          (unsigned long long)g_notify_addr, (unsigned long long)g_notify_size);
    // The trailer is at frame_buffer + frame_buffer_size and is the full 0x78-byte layout.
    uint64_t tr = fb + FRAME_SIZE;
    CHECK(rd64(tr) == 0x78, "trailer this_size 0x%llx", (unsigned long long)rd64(tr));

    // GetAvcPictureInfo with U4's 0x68 size: copies 0x60 bytes after this_size, nothing more.
    memset(gp(pic), 0x22, 0x78);
    wr64(pic, PIC_SIZE_REQ);
    CHECK(call(shim_sceVdecswGetAvcPictureInfo, oi, pic, 0, 0) == 0, "GetAvcPictureInfo");
    CHECK(rd64(pic) == PIC_SIZE_REQ, "caller's this_size changed");
    CHECK(rd8(pic + PIC_SIZE_REQ) == 0x22, "GetAvcPictureInfo wrote past this_size");
    CHECK(rd8(pic + 0x08) == 1, "pic.is_valid");
    int64_t pts = (int64_t)rd64(pic + 0x10);
    int64_t dts = (int64_t)rd64(pic + 0x18);
    uint64_t attached = rd64(pic + 0x20);
    CHECK(rd8(pic + 0x29) == 100, "profile_idc %d", rd8(pic + 0x29));
    CHECK(rd8(pic + 0x2a) == g_expected_level_idc, "level_idc %d", rd8(pic + 0x2a));
    CHECK(rd32(pic + 0x2c) == W / 16 - 1, "pic_width_in_mbs_minus1 %u", rd32(pic + 0x2c));
    CHECK(rd32(pic + 0x30) == AH / 16 - 1, "pic_height_in_map_units_minus1 %u", rd32(pic + 0x30));
    CHECK(rd8(pic + 0x34) == 1, "frame_mbs_only_flag");
    CHECK(rd8(pic + 0x35) == 1, "frame_cropping_flag");
    CHECK(rd32(pic + 0x38) == 0 && rd32(pic + 0x40) == 0, "crop left/top");
    CHECK(rd32(pic + 0x3c) == PITCH - W, "crop right %u", rd32(pic + 0x3c));
    CHECK(rd32(pic + 0x44) == AH - H, "crop bottom %u", rd32(pic + 0x44));
    // The access unit this picture came from (decode index = attached data).
    CHECK(attached < N, "attached %llu", (unsigned long long)attached);
    if (attached < N) {
        const Au *au = &g_aus[attached];
        CHECK(au->display == display, "picture of AU %llu shows frame %d, the AU holds frame %d",
              (unsigned long long)attached, display, au->display);
        CHECK(rd8(pic + 0x28) == (attached == 0 ? 1 : 0), "idr_pictureflag %d for AU %llu", rd8(pic + 0x28),
              (unsigned long long)attached);
        CHECK(rd8(pic + 0x67) == (au->key ? 1 : 0), "sequence_parameter_set_present_flag %d", rd8(pic + 0x67));
        // pts as passed: mode 0 = U4 player A (pts and dts -1), mode 1 = player B (pts, dts -1).
        if (mode == 0) CHECK(pts == -1, "pts %lld", (long long)pts);
        else CHECK(pts == (int64_t)au->display * 3003, "pts %lld for frame %d", (long long)pts, au->display);
        CHECK(dts == -1, "dts %lld", (long long)dts);
    }
    // Full trailer fields past U4's 0x68 bytes.
    CHECK(rd8(tr + 0x68) == (attached < N && g_aus[attached].key ? 1 : 0), "picture_parameter_set_present_flag");
    CHECK(rd8(tr + 0x69) == 1, "au_delimiter_present_flag");
    CHECK(rd8(tr + 0x6a) == 0 && rd8(tr + 0x6b) == 0, "end of sequence/stream flags");
    if (col->count < N) {
        col->display[col->count] = display;
        col->attached[col->count] = attached;
        col->pts[col->count] = pts;
    }
    col->count++;
}

// One output attempt (SetDecodeOutput if needed + TrySyncDecodeOutput). Returns the result code.
static uint64_t g_fb_desc, g_oi, g_pic, g_fbs[2];
static int g_fb_next;
static bool g_output_set;

static int32_t try_output(uint64_t dec, Collected *col, int mode) {
    if (!g_output_set) {
        wr64(g_fb_desc, 0x18);
        wr64(g_fb_desc + 8, g_fbs[g_fb_next]);
        wr64(g_fb_desc + 0x10, 0x400000);
        int32_t rc = call(shim_sceVdecswSetDecodeOutput, dec, g_fb_desc, 0, 0);
        CHECK(rc == 0, "SetDecodeOutput 0x%x", rc);
        g_output_set = true;
        // A second buffer while one is pending is refused.
        CHECK(call(shim_sceVdecswSetDecodeOutput, dec, g_fb_desc, 0, 0) == E_OUTPUT_BUFFER_FULL, "second output");
    }
    memset(gp(g_oi), 0x11, 0x40);
    wr64(g_oi, 0x30);
    int32_t rc = call(shim_sceVdecswTrySyncDecodeOutput, dec, g_oi, 0, 0);
    if (rc == E_DECODE_PENDING) {
        CHECK(rd8(g_oi + 0x08) == 0, "is_valid on DECODE_PENDING");
        return rc;
    }
    CHECK(rc == 0, "TrySyncDecodeOutput 0x%x", rc);
    if (rc != 0) return rc;
    g_output_set = false;
    if (rd8(g_oi + 0x08)) {
        check_picture(g_oi, g_fbs[g_fb_next], g_pic, col, mode);
        g_fb_next ^= 1;
    } else {
        CHECK(rd8(g_oi + 0x09) == 1, "empty output without is_last_frame");
        CHECK(rd8(g_oi + 0x0b) == 0, "picture_count on an empty output");
    }
    if (rd8(g_oi + 0x09)) col->last_flag_at = col->count - (rd8(g_oi + 0x08) ? 1 : 0);
    return rc;
}

static void drain_outputs(uint64_t dec, Collected *col, int mode) {
    while (try_output(dec, col, mode) == 0 && col->last_flag_at < 0) {
    }
}

static void run_stream(uint64_t dec, uint64_t in, uint64_t res, uint64_t au_buf, int mode) {
    Collected col = {0};
    col.last_flag_at = -1;
    g_output_set = false;
    uint32_t frames_reported = 0;
    int synced = 0;
    for (int j = 0; j < g_au_count; j++) {
        // U4 rebuilds every access unit in the same buffer; the API must have copied the previous one.
        memset(gp(au_buf), 0xEE, 0x100000);
        memcpy(gp(au_buf), g_aus[j].data, g_aus[j].size);
        wr64(in, 0x30);
        wr64(in + 0x08, au_buf);
        wr64(in + 0x10, g_aus[j].size);
        wr64(in + 0x18, mode == 0 ? (uint64_t)-1 : (uint64_t)g_aus[j].display * 3003);
        wr64(in + 0x20, (uint64_t)-1);
        wr64(in + 0x28, (uint64_t)j);
        int32_t rc;
        while ((rc = call(shim_sceVdecswSetDecodeInput, dec, in, 0, 0)) != 0) {
            CHECK(rc == E_INPUT_QUEUE_FULL || rc == E_OUTPUT_BUFFER_FULL, "SetDecodeInput 0x%x", rc);
            if (rc == E_INPUT_QUEUE_FULL) {
                wr64(res, 0x18);
                CHECK(call(shim_sceVdecswTrySyncDecodeInput, dec, res, 0, 0) == 0, "sync after INPUT_QUEUE_FULL");
                frames_reported += rd32(res + 0x10);
                synced++;
            } else {
                drain_outputs(dec, &col, mode);
            }
        }
        // Player B style: sync one input, then pull pictures while they are ready.
        wr64(res, 0x18);
        rc = call(shim_sceVdecswTrySyncDecodeInput, dec, res, 0, 0);
        CHECK(rc == 0, "TrySyncDecodeInput 0x%x", rc);
        if (rc == 0) {
            CHECK(rd64(res + 0x08) == au_buf, "decoded_au 0x%llx", (unsigned long long)rd64(res + 0x08));
            frames_reported += rd32(res + 0x10);
            synced++;
        }
        while (try_output(dec, &col, mode) == 0) {
        }
    }
    int32_t rc = call(shim_sceVdecswTrySyncDecodeInput, dec, res, 0, 0);
    CHECK(rc == E_INPUT_QUEUE_EMPTY, "TrySyncDecodeInput on an empty queue 0x%x", rc);
    CHECK(synced == g_au_count, "synced %d inputs of %d", synced, g_au_count);
    CHECK(frames_reported <= (uint32_t)g_au_count, "output_frame_count total %u", frames_reported);
    const int before_finalize = col.count;
    CHECK(frames_reported == (uint32_t)before_finalize, "output_frame_count total %u, pictures before finalize %d",
          frames_reported, before_finalize);

    CHECK(call(shim_sceVdecswFinalizeDecodeSequence, dec, 0, 0, 0) == 0, "FinalizeDecodeSequence");
    drain_outputs(dec, &col, mode);
    CHECK(col.count == N, "decoded %d pictures, expected %d", col.count, N);
    CHECK(col.last_flag_at == N - 1 || col.last_flag_at == N, "is_last_frame at %d", col.last_flag_at);
    for (int k = 0; k < col.count && k < N; k++) CHECK(col.display[k] == k, "output %d shows frame %d", k, col.display[k]);
    // Nothing is left: the next output attempt reports the end again (buffer set) or EMPTY.
    if (!g_output_set) {
        memset(gp(g_oi), 0x11, 0x40);
        wr64(g_oi, 0x30);
        CHECK(call(shim_sceVdecswTrySyncDecodeOutput, dec, g_oi, 0, 0) == E_OUTPUT_BUFFER_EMPTY, "no buffer -> EMPTY");
    }
    fprintf(stderr, "vdecsw mode %d: %d pictures, %d before finalize, display order ok=%d\n", mode, col.count,
            before_finalize, failures == 0);
}

static void test_vdecsw(void) {
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
    wr16(cci + 8, 5);
    CHECK(call(shim_sceVdecswAllocateComputeQueue, cci, cmi, q, 0) == (int32_t)0x81510201, "pipe 5 refused");
    wr16(cci + 8, 3);
    wr64(cmi, 0x10);
    CHECK(call(shim_sceVdecswQueryComputeMemoryInfo, cmi, 0, 0, 0) == E_STRUCT_SIZE, "struct size");
    wr64(cmi, 0x18);

    // Decoder config, V1 layout (0x48) as U4 builds it (0x16993ad / rodata 0x1dadae0).
    uint64_t cfg = galloc(0x50, 16), mem = galloc(0x48, 16), dec_out = galloc(8, 8);
    wr64(cfg, 0x48);
    wr32(cfg + 0x08, 1);
    wr32(cfg + 0x0c, 1);
    wr32(cfg + 0x10, 100);
    wr32(cfg + 0x14, 42);
    wr32(cfg + 0x18, W);
    wr32(cfg + 0x1c, H);
    wr32(cfg + 0x20, 4);
    wr32(cfg + 0x24, 3);
    wr64(cfg + 0x28, rd64(q));
    wr64(cfg + 0x30, 0x3f);
    wr8(cfg + 0x3c, 1);
    wr8(cfg + 0x3d, 1);
    wr8(cfg + 0x3f, 1);
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
    CHECK(call(shim_sceVdecswQueryDecoderMemoryInfo, cfg, mem, 0, 0) == 0, "QueryDecoderMemoryInfo");
    wr64(mem + 0x10, galloc(rd64(mem + 0x08), 16));
    wr64(mem + 0x20, galloc(rd64(mem + 0x18), 0x200000));
    wr64(mem + 0x30, galloc(rd64(mem + 0x28), 0x200000));
    // HEVC is refused, a wrong config size too.
    wr32(cfg + 0x0c, 974921);
    CHECK(call(shim_sceVdecswCreateDecoder, cfg, mem, dec_out, 0) == E_CODEC_TYPE, "HEVC refused");
    wr32(cfg + 0x0c, 1);
    wr64(cfg, 0x40);
    CHECK(call(shim_sceVdecswCreateDecoder, cfg, mem, dec_out, 0) == E_STRUCT_SIZE, "config size refused");
    wr64(cfg, 0x48);
    CHECK(call(shim_sceVdecswCreateDecoder, cfg, mem, dec_out, 0) == 0, "CreateDecoder");
    uint64_t dec = rd64(dec_out);
    CHECK(dec != 0, "decoder handle");
    CHECK(call(shim_sceVdecswSetDecodeInput, dec ^ 0x40, 0, 0, 0) == E_DECODER_INSTANCE, "bad handle");

    uint64_t in = galloc(0x30, 16), res = galloc(0x18, 16), au_buf = galloc(0x100000, 0x100);
    g_fb_desc = galloc(0x18, 16);
    g_oi = galloc(0x40, 16);
    g_pic = galloc(0x80, 16);
    g_fbs[0] = galloc(0x400000, 0x200000);
    g_fbs[1] = galloc(0x400000, 0x200000);
    wr64(res, 0x18);
    CHECK(call(shim_sceVdecswTrySyncDecodeInput, dec, res, 0, 0) == E_INPUT_QUEUE_EMPTY, "empty input queue");
    wr64(g_oi, 0x30);
    CHECK(call(shim_sceVdecswTrySyncDecodeOutput, dec, g_oi, 0, 0) == E_OUTPUT_BUFFER_EMPTY, "no output buffer");

    // Pipeline depth 3: the fourth unsynced input is refused.
    for (int j = 0; j < 3; j++) {
        memcpy(gp(au_buf), g_aus[j].data, g_aus[j].size);
        wr64(in, 0x30);
        wr64(in + 0x08, au_buf);
        wr64(in + 0x10, g_aus[j].size);
        wr64(in + 0x18, (uint64_t)-1);
        wr64(in + 0x20, (uint64_t)-1);
        wr64(in + 0x28, (uint64_t)j);
        CHECK(call(shim_sceVdecswSetDecodeInput, dec, in, 0, 0) == 0, "input %d", j);
    }
    CHECK(call(shim_sceVdecswSetDecodeInput, dec, in, 0, 0) == E_INPUT_QUEUE_FULL, "input queue full");
    // Reset drops everything; the stream then decodes from the start.
    CHECK(call(shim_sceVdecswResetDecoder, dec, 0, 0, 0) == 0, "ResetDecoder");
    CHECK(call(shim_sceVdecswTrySyncDecodeInput, dec, res, 0, 0) == E_INPUT_QUEUE_EMPTY, "inputs after reset");

    run_stream(dec, in, res, au_buf, 0);
    CHECK(call(shim_sceVdecswResetDecoder, dec, 0, 0, 0) == 0, "ResetDecoder");
    run_stream(dec, in, res, au_buf, 1);

    CHECK(call(shim_sceVdecswDeleteDecoder, dec, 0, 0, 0) == 0, "DeleteDecoder");
    CHECK(call(shim_sceVdecswDeleteDecoder, dec, 0, 0, 0) == E_DECODER_INSTANCE, "deleted handle");
    CHECK(call(shim_sceVdecswReleaseComputeQueue, rd64(q), 0, 0, 0) == 0, "ReleaseComputeQueue");
}

// libSceVideodec (TLOU's API) on the same stream: one picture per Decode/Flush, display order.
static void test_videodec(void) {
    uint64_t cfg = galloc(0x30, 16), ri = galloc(0x40, 16), ctrl = galloc(0x18, 16);
    uint64_t in = galloc(0x30, 16), fb = galloc(0x18, 16), pic = galloc(0x70, 16);
    uint64_t buf = galloc(0x400000, 0x100), au_buf = galloc(0x100000, 0x100);
    wr64(cfg, 0x30);
    wr32(cfg + 0x14, W);
    wr32(cfg + 0x18, H);
    CHECK(call(shim_sceVideodecQueryResourceInfo, cfg, ri, 0, 0) == 0, "QueryResourceInfo");
    CHECK(rd64(ri + 0x28) >= FRAME_SIZE, "maxFrameBufferSize");
    wr64(ctrl, 0x18);
    CHECK(call(shim_sceVideodecCreateDecoder, cfg, ri, ctrl, 0) == 0, "Videodec CreateDecoder");
    int got = 0, order_ok = 1;
    // Decode hands out at most one picture per call; Flush drains the rest one per call.
    for (int j = 0; j <= g_au_count + N; j++) {
        wr64(fb, 0x18);
        wr64(fb + 8, buf);
        wr64(fb + 0x10, 0x400000);
        int32_t rc;
        if (j < g_au_count) {
            memcpy(gp(au_buf), g_aus[j].data, g_aus[j].size);
            wr64(in, 0x30);
            wr64(in + 0x08, au_buf);
            wr64(in + 0x10, g_aus[j].size);
            wr64(in + 0x18, (uint64_t)g_aus[j].display * 3003);
            wr64(in + 0x20, (uint64_t)j * 3003);
            wr64(in + 0x28, (uint64_t)j);
            rc = call(shim_sceVideodecDecode, ctrl, in, fb, pic);
        } else {
            rc = call(shim_sceVideodecFlush, ctrl, fb, pic, 0);
        }
        CHECK(rc == 0, "Videodec Decode/Flush 0x%x", rc);
        if (!rd32(pic + 0x08)) {
            if (j >= g_au_count) break;
            continue;
        }
        int display = (luma_avg(buf) - 40 + 2) / 5;
        if (display != got) order_ok = 0;
        CHECK(rd32(pic + 0x10) == W && rd32(pic + 0x14) == PITCH && rd32(pic + 0x18) == AH, "Videodec dims");
        CHECK(rd64(pic + 0x20) == (uint64_t)display * 3003, "Videodec pts %llu", (unsigned long long)rd64(pic + 0x20));
        CHECK(rd64(pic + 0x28) < N && g_aus[rd64(pic + 0x28)].display == display, "Videodec attachedData");
        got++;
    }
    CHECK(got == N, "Videodec decoded %d pictures, expected %d", got, N);
    CHECK(order_ok, "Videodec display order");
    CHECK(call(shim_sceVideodecDeleteDecoder, ctrl, 0, 0, 0) == 0, "Videodec DeleteDecoder");
    fprintf(stderr, "videodec: %d pictures\n", got);
}

int main(void) {
    make_stream();
    CHECK(g_au_count == N, "encoder produced %d samples", g_au_count);
    int reordered = 0, keys = 0;
    for (int j = 1; j < g_au_count; j++)
        if (g_aus[j].display < g_aus[j - 1].display) reordered++;
    for (int j = 0; j < g_au_count; j++) keys += g_aus[j].key;
    fprintf(stderr, "stream: %d access units, %d key, %d out of display order\n", g_au_count, keys, reordered);
    // The test is about display reordering: the encoder must have produced B-frames.
    CHECK(reordered > 0, "the encoder produced no B-frames");

    H264SpsInfo sps;
    CHECK(h264_parse_sps(g_sps, g_sps_len, &sps), "SPS parse");
    CHECK(sps.profile_idc == 100, "SPS profile %u", sps.profile_idc);
    CHECK((sps.pic_width_in_mbs_minus1 + 1) * 16 - 2 * (sps.frame_crop_left_offset + sps.frame_crop_right_offset) == W,
          "SPS width");
    CHECK((sps.pic_height_in_map_units_minus1 + 1) * 16 - 2 * (sps.frame_crop_top_offset + sps.frame_crop_bottom_offset) ==
              H,
          "SPS height");
    g_expected_level_idc = g_sps[3];

    g.mem_size = 64ULL << 20;
    g.mem_base = (uint8_t *)calloc(1, g.mem_size);
    test_vdecsw();
    test_videodec();
    if (failures) {
        fprintf(stderr, "vdecsw_test: %d failure(s)\n", failures);
        return 1;
    }
    printf("vdecsw_test: PASS\n");
    return 0;
}
