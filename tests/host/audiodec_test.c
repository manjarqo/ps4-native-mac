// Host test of libSceAudiodec (MPEG-4 AAC on AudioToolbox).
//
// The test makes its own AAC-LC streams with AudioToolbox's encoder: a stereo 48 kHz stream
// (chirps 200 -> 2000 Hz left, 3000 -> 600 Hz right) and a mono 44.1 kHz one (300 -> 3000 Hz).
// Every packet is wrapped in an ADTS header (U4's config 1 path checks for one) and fed through
// the guest API on a fake guest memory, with the ctrl block built exactly as Uncharted 4's movie
// player builds it on its stack (eboot 0x16cd74f-0x16cd7ce): param {0x18, float, ADTS, freq
// index, 2 ch, no HE-AAC}, bsi info 0x14, au info 0x18, pcm item 0x18 with a 0x4000-byte buffer.
//
// Checks: one 1024-sample frame per access unit and the PCM size U4 reads back; the decoded
// signal matches the source after the encoder's delay (chirps, so the delay is unambiguous;
// per-channel SNR, RMS and a sum-of-magnitudes checksum within tolerance; channels not swapped);
// s16 and s32 output agree with float output; the raw (config 2) mode gives the same samples as
// ADTS; ADTS with a CRC field; a damaged frame fails without breaking the decoder; parameter,
// size, handle and channel errors; Decode racing DeleteDecoder.
#include "ps4_audiodec.h"

#include <AudioToolbox/AudioToolbox.h>
#include <math.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static atomic_int failures;
#define CHECK(cond, ...)                                                                       \
    do {                                                                                       \
        if (!(cond)) {                                                                         \
            fprintf(stderr, "FAIL %s:%d: ", __FILE__, __LINE__);                               \
            fprintf(stderr, __VA_ARGS__);                                                      \
            fprintf(stderr, "\n");                                                             \
            atomic_fetch_add(&failures, 1);                                                    \
        }                                                                                      \
    } while (0)

#define FRAME 1024
#define MAXPKT 128

// ---------------------------------------------------------------------------------------------
// Encoder
// ---------------------------------------------------------------------------------------------

typedef struct {
    uint32_t rate, channels, frames;
    float *pcm;          // source, interleaved
    uint8_t *pkt[MAXPKT]; // raw AAC packets
    uint32_t pkt_size[MAXPKT];
    uint32_t npkt;
} Stream;

typedef struct {
    const Stream *s;
    uint32_t pos;
} EncInput;

static OSStatus enc_input(AudioConverterRef conv, UInt32 *packets, AudioBufferList *data,
                          AudioStreamPacketDescription **desc, void *user) {
    (void)conv;
    (void)desc;
    EncInput *in = (EncInput *)user;
    uint32_t n = in->s->frames - in->pos;
    if (n > *packets) n = *packets;
    data->mBuffers[0].mData = in->s->pcm + (size_t)in->pos * in->s->channels;
    data->mBuffers[0].mDataByteSize = n * in->s->channels * 4;
    data->mBuffers[0].mNumberChannels = in->s->channels;
    in->pos += n;
    *packets = n; // 0 at the end: the encoder flushes
    return noErr;
}

// Linear chirps (f0 -> f1 over the stream), so the decoder delay is unambiguous.
static void make_stream(Stream *s, uint32_t rate, uint32_t channels, double seconds, const double *f0,
                        const double *f1, const double *amp) {
    memset(s, 0, sizeof(*s));
    s->rate = rate;
    s->channels = channels;
    s->frames = (uint32_t)(rate * seconds);
    s->pcm = (float *)calloc((size_t)s->frames * channels, sizeof(float));
    for (uint32_t i = 0; i < s->frames; i++)
        for (uint32_t c = 0; c < channels; c++)
        {
            const double t = (double)i / rate;
            s->pcm[(size_t)i * channels + c] =
                (float)(amp[c] * sin(2 * M_PI * (f0[c] * t + (f1[c] - f0[c]) * t * t / (2 * seconds))));
        }
    AudioStreamBasicDescription in = {0}, out = {0};
    in.mSampleRate = rate;
    in.mFormatID = kAudioFormatLinearPCM;
    in.mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked;
    in.mBitsPerChannel = 32;
    in.mChannelsPerFrame = channels;
    in.mFramesPerPacket = 1;
    in.mBytesPerFrame = in.mBytesPerPacket = 4 * channels;
    out.mSampleRate = rate;
    out.mFormatID = kAudioFormatMPEG4AAC;
    out.mFormatFlags = kMPEG4Object_AAC_LC;
    out.mFramesPerPacket = FRAME;
    out.mChannelsPerFrame = channels;
    AudioConverterRef conv;
    OSStatus st = AudioConverterNew(&in, &out, &conv);
    if (st != noErr) {
        fprintf(stderr, "encoder: AudioConverterNew failed %d\n", (int)st);
        exit(1);
    }
    UInt32 bitrate = 128000 * channels;
    AudioConverterSetProperty(conv, kAudioConverterEncodeBitRate, sizeof(bitrate), &bitrate);
    EncInput ei = {s, 0};
    for (;;) {
        uint8_t buf[6144];
        AudioBufferList list;
        list.mNumberBuffers = 1;
        list.mBuffers[0].mNumberChannels = channels;
        list.mBuffers[0].mDataByteSize = sizeof(buf);
        list.mBuffers[0].mData = buf;
        AudioStreamPacketDescription desc;
        UInt32 n = 1;
        st = AudioConverterFillComplexBuffer(conv, enc_input, &ei, &n, &list, &desc);
        if (st != noErr || n == 0) break;
        if (s->npkt == MAXPKT) {
            fprintf(stderr, "encoder: too many packets\n");
            exit(1);
        }
        s->pkt_size[s->npkt] = desc.mDataByteSize;
        s->pkt[s->npkt] = (uint8_t *)malloc(desc.mDataByteSize);
        memcpy(s->pkt[s->npkt], buf + desc.mStartOffset, desc.mDataByteSize);
        s->npkt++;
    }
    AudioConverterDispose(conv);
}

static void free_stream(Stream *s) {
    free(s->pcm);
    for (uint32_t i = 0; i < s->npkt; i++) free(s->pkt[i]);
}

static uint32_t freq_index(uint32_t rate) {
    static const uint32_t r[] = {96000, 88200, 64000, 48000, 44100, 32000, 24000, 22050, 16000, 12000, 11025, 8000, 7350};
    for (uint32_t i = 0; i < 13; i++)
        if (r[i] == rate) return i;
    return 15;
}

// ADTS header (MPEG-4, AAC-LC) + payload; with crc a 2-byte CRC field follows the header.
static uint32_t adts_wrap(uint8_t *out, const Stream *s, uint32_t i, int crc) {
    const uint32_t hdr = crc ? 9 : 7, len = hdr + s->pkt_size[i], fi = freq_index(s->rate), ch = s->channels;
    out[0] = 0xFF;
    out[1] = (uint8_t)(0xF0 | (crc ? 0 : 1));
    out[2] = (uint8_t)((1u << 6) | (fi << 2) | (ch >> 2));
    out[3] = (uint8_t)(((ch & 3) << 6) | (len >> 11));
    out[4] = (uint8_t)(len >> 3);
    out[5] = (uint8_t)(((len & 7) << 5) | 0x1F);
    out[6] = 0xFC;
    if (crc) out[7] = out[8] = 0;
    memcpy(out + hdr, s->pkt[i], s->pkt_size[i]);
    return len;
}

// ---------------------------------------------------------------------------------------------
// Guest side
// ---------------------------------------------------------------------------------------------

static GuestContext g;
static uint64_t g_brk = 0x10000;

static uint64_t galloc(uint64_t size) {
    g_brk = (g_brk + 15) & ~15ULL;
    const uint64_t a = g_brk;
    g_brk += size;
    if (g_brk > g.mem_size) {
        fprintf(stderr, "guest memory exhausted\n");
        exit(1);
    }
    memset(g.mem_base + a, 0, size);
    return a;
}
static void *gp(uint64_t a) { return g.mem_base + a; }
static void wr32(uint64_t a, uint32_t v) { memcpy(gp(a), &v, 4); }
static void wr64(uint64_t a, uint64_t v) { memcpy(gp(a), &v, 8); }
static uint32_t rd32(uint64_t a) {
    uint32_t v;
    memcpy(&v, gp(a), 4);
    return v;
}

static int32_t call(void (*fn)(GuestContext *), uint64_t a, uint64_t b) {
    g.rdi = a;
    g.rsi = b;
    g.rax = 0xdeadbeef;
    fn(&g);
    return (int32_t)g.rax;
}

// The player's stack frame: offsets from RBP as in U4 (ctrl at -0x890, param -0x70, bsi -0x90,
// au -0x40, pcm -0x58).
typedef struct {
    uint64_t rbp, ctrl, param, bsi, au, pcm, pcm_buf, au_buf;
} Frame;

static Frame make_frame(uint32_t word, uint32_t config, uint32_t fi, uint32_t max_ch, uint32_t pcm_size) {
    Frame f;
    const uint64_t base = galloc(0x900);
    f.rbp = base + 0x890;
    f.ctrl = f.rbp - 0x890;
    f.param = f.rbp - 0x70;
    f.bsi = f.rbp - 0x90;
    f.au = f.rbp - 0x40;
    f.pcm = f.rbp - 0x58;
    f.pcm_buf = galloc(0x8000);
    f.au_buf = galloc(0x4000);
    wr64(f.param, 0x200000018ULL); // MOV [RBP-0x70], 0x200000018
    wr32(f.param + 8, config);
    wr32(f.param + 0xc, fi);
    wr32(f.param + 0x10, max_ch);
    wr32(f.param + 0x14, 0);
    wr32(f.param + 4, word);
    wr32(f.bsi, 0x14);
    wr32(f.au, 0x18);
    wr32(f.pcm, 0x18);
    wr64(f.pcm + 8, f.pcm_buf);
    wr32(f.pcm + 0x10, pcm_size);
    wr64(f.ctrl, f.param);
    wr64(f.ctrl + 8, f.bsi);
    wr64(f.ctrl + 0x10, f.au);
    wr64(f.ctrl + 0x18, f.pcm);
    return f;
}

static void set_au(const Frame *f, const uint8_t *data, uint32_t size, uint32_t pcm_size) {
    memcpy(gp(f->au_buf), data, size);
    wr64(f->au + 8, f->au_buf);
    wr32(f->au + 0x10, size);
    wr32(f->pcm + 0x10, pcm_size);
}

// Decodes the whole stream (ADTS or raw) and returns the interleaved float output (as floats,
// converted from the word size).
static float *decode_all(const Stream *s, uint32_t word, uint32_t config, int crc, uint32_t *out_frames) {
    Frame f = make_frame(word, config, freq_index(s->rate), 2, 0x4000);
    uint8_t au[8192];
    uint32_t n = config == 1 ? adts_wrap(au, s, 0, crc) : s->pkt_size[0];
    if (config != 1) memcpy(au, s->pkt[0], n);
    set_au(&f, au, n, 0x4000);
    const int32_t h = call(shim_sceAudiodecCreateDecoder, f.ctrl, 3);
    CHECK(h > 0, "CreateDecoder returned 0x%08x", (uint32_t)h);
    float *pcm = (float *)calloc((size_t)s->npkt * FRAME * s->channels, sizeof(float));
    uint32_t total = 0;
    for (uint32_t i = 0; i < s->npkt && h > 0; i++) {
        if (config == 1)
            n = adts_wrap(au, s, i, crc);
        else
            memcpy(au, s->pkt[i], n = s->pkt_size[i]);
        set_au(&f, au, n, 0x4000);
        const int32_t rc = call(shim_sceAudiodecDecode, (uint32_t)h, f.ctrl);
        CHECK(rc == 0, "Decode packet %u returned 0x%08x", i, (uint32_t)rc);
        if (rc) break;
        const uint32_t wb = word == 0 ? 2 : 4, bytes = rd32(f.pcm + 0x10);
        CHECK(bytes == FRAME * s->channels * wb, "packet %u: pcm size %u", i, bytes);
        CHECK(rd32(f.au + 0x10) == n, "packet %u: consumed %u of %u", i, rd32(f.au + 0x10), n);
        CHECK(rd32(f.bsi + 4) == s->rate && rd32(f.bsi + 8) == s->channels && rd32(f.bsi + 0xc) == FRAME,
              "packet %u: bsi {%u Hz, %u ch, %u}", i, rd32(f.bsi + 4), rd32(f.bsi + 8), rd32(f.bsi + 0xc));
        const uint32_t samples = bytes / wb;
        for (uint32_t k = 0; k < samples; k++) {
            float v;
            if (word == 2) {
                memcpy(&v, (uint8_t *)gp(f.pcm_buf) + 4 * k, 4);
            } else if (word == 1) {
                int32_t x;
                memcpy(&x, (uint8_t *)gp(f.pcm_buf) + 4 * k, 4);
                v = (float)(x / 2147483647.0);
            } else {
                int16_t x;
                memcpy(&x, (uint8_t *)gp(f.pcm_buf) + 2 * k, 2);
                v = x / 32767.0f;
            }
            pcm[(size_t)total * s->channels + k] = v;
        }
        total += samples / s->channels;
    }
    CHECK(call(shim_sceAudiodecDeleteDecoder, (uint32_t)h, 0) == 0, "DeleteDecoder");
    *out_frames = total;
    return pcm;
}

// Delay of the decoded signal against the source (cross-correlation over 0..4096 samples), and
// the SNR of the delayed comparison over the middle of the stream.
static void compare(const Stream *s, const float *dec, uint32_t frames, uint32_t c, int *lag_out, double *snr_out,
                    double *rms_out) {
    const uint32_t ch = s->channels, start = 4096, len = s->frames - 8192;
    double best = -1e30;
    int lag = 0;
    for (int l = 0; l <= 4096; l++) {
        double acc = 0;
        for (uint32_t i = start; i < start + 4096; i++) acc += (double)s->pcm[(size_t)i * ch + c] * dec[(size_t)(i + l) * ch + c];
        if (acc > best) {
            best = acc;
            lag = l;
        }
    }
    double sig = 0, err = 0, rms = 0;
    for (uint32_t i = start; i < start + len && i + lag < frames; i++) {
        const double a = s->pcm[(size_t)i * ch + c], b = dec[(size_t)(i + lag) * ch + c];
        sig += a * a;
        err += (a - b) * (a - b);
        rms += b * b;
    }
    *lag_out = lag;
    *snr_out = 10 * log10(sig / (err + 1e-30));
    *rms_out = sqrt(rms / len);
}

static void test_stereo(const Stream *s) {
    uint32_t frames = 0;
    float *f32 = decode_all(s, 2, 1, 0, &frames);
    CHECK(frames == s->npkt * FRAME, "stereo: %u frames for %u access units", frames, s->npkt);
    CHECK(frames >= s->frames, "stereo: %u frames < source %u", frames, s->frames);
    const double amp[2] = {0.5, 0.3};
    int lags[2];
    for (uint32_t c = 0; c < 2; c++) {
        int lag;
        double snr, rms;
        compare(s, f32, frames, c, &lag, &snr, &rms);
        lags[c] = lag;
        printf("audiodec_test: stereo ch%u lag %d, SNR %.1f dB, RMS %.4f\n", c, lag, snr, rms);
        // The encoder's priming delay (2112 samples for AudioToolbox's AAC encoder).
        CHECK(lag >= 1024 && lag <= 3072, "stereo ch%u: delay %d", c, lag);
        CHECK(snr > 25.0, "stereo ch%u: SNR %.1f dB", c, snr);
        CHECK(fabs(rms - amp[c] / sqrt(2)) < 0.05 * amp[c] / sqrt(2), "stereo ch%u: RMS %.4f", c, rms);
    }
    CHECK(lags[0] == lags[1], "stereo: channel delays differ (%d, %d)", lags[0], lags[1]);
    // A checksum with tolerance: the sum of |sample| over the stream within 2% of the source's.
    double src_sum = 0, dec_sum = 0;
    for (size_t i = 0; i < (size_t)s->frames * 2; i++) src_sum += fabs(s->pcm[i]);
    for (size_t i = 0; i < (size_t)frames * 2; i++) dec_sum += fabs(f32[i]);
    printf("audiodec_test: stereo sum|x| source %.1f decoded %.1f\n", src_sum, dec_sum);
    CHECK(fabs(dec_sum - src_sum) < 0.02 * src_sum, "stereo checksum %.1f vs %.1f", dec_sum, src_sum);

    // Word sizes: s16 within one LSB of float, s32 within float rounding.
    float *s16 = decode_all(s, 0, 1, 0, &frames);
    float *s32 = decode_all(s, 1, 1, 0, &frames);
    double d16 = 0, d32 = 0;
    for (size_t i = 0; i < (size_t)frames * 2; i++) {
        float ref = f32[i] > 1 ? 1 : f32[i] < -1 ? -1 : f32[i];
        d16 = fmax(d16, fabs(s16[i] - ref));
        d32 = fmax(d32, fabs(s32[i] - ref));
    }
    CHECK(d16 <= 1.0 / 32767 + 1e-6, "s16 output differs by %g", d16);
    CHECK(d32 <= 1e-6, "s32 output differs by %g", d32);
    // Raw mode (config 2) gives the same samples as ADTS.
    float *raw = decode_all(s, 2, 2, 0, &frames);
    CHECK(memcmp(raw, f32, (size_t)frames * 2 * 4) == 0, "raw mode differs from ADTS");
    free(s16);
    free(s32);
    free(raw);
    free(f32);
}

static void test_mono(const Stream *s) {
    uint32_t frames = 0;
    float *f32 = decode_all(s, 2, 1, 1, &frames); // ADTS with CRC field
    CHECK(frames == s->npkt * FRAME, "mono: %u frames for %u access units", frames, s->npkt);
    int lag;
    double snr, rms;
    compare(s, f32, frames, 0, &lag, &snr, &rms);
    printf("audiodec_test: mono 44.1 kHz lag %d, SNR %.1f dB, RMS %.4f\n", lag, snr, rms);
    CHECK(lag >= 1024 && lag <= 3072, "mono: delay %d", lag);
    CHECK(snr > 25.0, "mono: SNR %.1f dB", snr);
    CHECK(fabs(rms - 0.6 / sqrt(2)) < 0.03, "mono: RMS %.4f", rms);
    free(f32);
    float *raw = decode_all(s, 2, 2, 0, &frames); // raw mode detects one channel (SCE)
    CHECK(frames == s->npkt * FRAME, "mono raw: %u frames", frames);
    free(raw);
}

static void test_errors(const Stream *s) {
    uint8_t au[8192];
    const uint32_t fi = freq_index(s->rate);
    CHECK(call(shim_sceAudiodecTermLibrary, 3, 0) == PS4_AUDIODEC_ERROR_NOT_INITIALIZED, "Term without Init");
    CHECK(call(shim_sceAudiodecInitLibrary, 1, 0) == PS4_AUDIODEC_ERROR_INVALID_TYPE, "Init type 1");
    CHECK(call(shim_sceAudiodecInitLibrary, 3, 0) == 0, "Init type 3");

    Frame f = make_frame(2, 1, fi, 2, 0x4000);
    CHECK(call(shim_sceAudiodecCreateDecoder, f.ctrl, 2) == PS4_AUDIODEC_ERROR_INVALID_TYPE, "Create type 2");
    CHECK(call(shim_sceAudiodecCreateDecoder, 0, 3) == PS4_AUDIODEC_ERROR_INVALID_PTR, "Create NULL ctrl");
    CHECK(call(shim_sceAudiodecCreateDecoder, g.mem_size - 8, 3) == PS4_AUDIODEC_ERROR_INVALID_PTR, "Create ctrl at end");
    wr32(f.param, 0x14);
    CHECK(call(shim_sceAudiodecCreateDecoder, f.ctrl, 3) == PS4_AUDIODEC_ERROR_INVALID_SIZE, "param size");
    wr32(f.param, 0x18);
    wr32(f.param + 4, 3);
    CHECK(call(shim_sceAudiodecCreateDecoder, f.ctrl, 3) == PS4_AUDIODEC_ERROR_INVALID_WORD_LENGTH, "word size 3");
    wr32(f.param + 4, 2);
    wr32(f.param + 8, 0);
    CHECK(call(shim_sceAudiodecCreateDecoder, f.ctrl, 3) == PS4_AUDIODEC_ERROR_UNSUPPORTED, "config 0");
    wr32(f.param + 8, 1);
    wr32(f.param + 0x14, 1);
    CHECK(call(shim_sceAudiodecCreateDecoder, f.ctrl, 3) == PS4_AUDIODEC_ERROR_UNSUPPORTED, "HE-AAC");
    wr32(f.param + 0x14, 0);
    wr32(f.param + 0xc, 13);
    CHECK(call(shim_sceAudiodecCreateDecoder, f.ctrl, 3) == PS4_AUDIODEC_ERROR_INVALID_INIT_PARAM, "freq index 13");
    wr32(f.param + 0xc, fi);

    const int32_t h = call(shim_sceAudiodecCreateDecoder, f.ctrl, 3);
    CHECK(h > 0, "Create: 0x%08x", (uint32_t)h);
    CHECK(call(shim_sceAudiodecDecode, 0, f.ctrl) == PS4_AUDIODEC_ERROR_INVALID_HANDLE, "Decode handle 0");
    CHECK(call(shim_sceAudiodecDecode, (uint32_t)h + 16, f.ctrl) == PS4_AUDIODEC_ERROR_INVALID_HANDLE, "Decode other id");
    // Not ADTS.
    memset(au, 0x5A, 64);
    set_au(&f, au, 64, 0x4000);
    CHECK(call(shim_sceAudiodecDecode, (uint32_t)h, f.ctrl) == PS4_AUDIODEC_ERROR_INVALID_SIZE, "no syncword");
    // frame_length beyond the access unit.
    uint32_t n = adts_wrap(au, s, 3, 0);
    set_au(&f, au, n - 1, 0x4000);
    CHECK(call(shim_sceAudiodecDecode, (uint32_t)h, f.ctrl) == PS4_AUDIODEC_ERROR_INVALID_SIZE, "truncated frame");
    // PCM buffer smaller than one frame.
    set_au(&f, au, n, FRAME * 2 * 4 - 4);
    CHECK(call(shim_sceAudiodecDecode, (uint32_t)h, f.ctrl) == PS4_AUDIODEC_ERROR_INVALID_SIZE, "small pcm buffer");
    // Struct sizes.
    set_au(&f, au, n, 0x4000);
    wr32(f.au, 0x10);
    CHECK(call(shim_sceAudiodecDecode, (uint32_t)h, f.ctrl) == PS4_AUDIODEC_ERROR_INVALID_SIZE, "au info size");
    wr32(f.au, 0x18);
    wr32(f.bsi, 0x10);
    CHECK(call(shim_sceAudiodecDecode, (uint32_t)h, f.ctrl) == PS4_AUDIODEC_ERROR_INVALID_SIZE, "bsi size");
    wr32(f.bsi, 0x14);
    // AU address + size wrapping around guest memory.
    wr64(f.au + 8, g.mem_size - 0x10);
    wr32(f.au + 0x10, 0x20);
    CHECK(call(shim_sceAudiodecDecode, (uint32_t)h, f.ctrl) == PS4_AUDIODEC_ERROR_INVALID_PTR, "au out of range");
    // An access unit holding two ADTS frames: one frame is consumed.
    n = adts_wrap(au, s, 3, 0);
    const uint32_t n2 = adts_wrap(au + n, s, 4, 0);
    set_au(&f, au, n + n2, 0x4000);
    CHECK(call(shim_sceAudiodecDecode, (uint32_t)h, f.ctrl) == 0, "two frames");
    CHECK(rd32(f.au + 0x10) == n, "two frames: consumed %u, frame %u", rd32(f.au + 0x10), n);
    CHECK(rd32(f.pcm + 0x10) == FRAME * 2 * 4, "two frames: pcm %u", rd32(f.pcm + 0x10));
    // A damaged payload fails (or decodes to something), and the next good frame decodes.
    n = adts_wrap(au, s, 5, 0);
    for (uint32_t i = 7; i < n; i++) au[i] = (uint8_t)(i * 37 + 11);
    set_au(&f, au, n, 0x4000);
    const int32_t bad = call(shim_sceAudiodecDecode, (uint32_t)h, f.ctrl);
    CHECK(bad == 0 || bad == PS4_AUDIODEC_ERROR_API_FAIL, "damaged frame: 0x%08x", (uint32_t)bad);
    n = adts_wrap(au, s, 6, 0);
    set_au(&f, au, n, 0x4000);
    CHECK(call(shim_sceAudiodecDecode, (uint32_t)h, f.ctrl) == 0, "good frame after a damaged one");
    CHECK(rd32(f.pcm + 0x10) == FRAME * 2 * 4, "good frame after damage: pcm %u", rd32(f.pcm + 0x10));

    // Stereo stream into a decoder limited to one channel.
    Frame m = make_frame(2, 1, fi, 1, 0x4000);
    const int32_t hm = call(shim_sceAudiodecCreateDecoder, m.ctrl, 3);
    CHECK(hm > 0 && hm != h, "Create mono: 0x%08x", (uint32_t)hm);
    set_au(&m, au, n, 0x4000);
    CHECK(call(shim_sceAudiodecDecode, (uint32_t)hm, m.ctrl) == PS4_AUDIODEC_ERROR_CH_SHORTAGE, "channel shortage");
    CHECK(call(shim_sceAudiodecDeleteDecoder, (uint32_t)hm, 0) == 0, "Delete mono");

    CHECK(call(shim_sceAudiodecDeleteDecoder, (uint32_t)h, 0) == 0, "Delete");
    CHECK(call(shim_sceAudiodecDeleteDecoder, (uint32_t)h, 0) == PS4_AUDIODEC_ERROR_INVALID_HANDLE, "Delete twice");
    CHECK(call(shim_sceAudiodecDecode, (uint32_t)h, f.ctrl) == PS4_AUDIODEC_ERROR_INVALID_HANDLE, "Decode stale");
    // The slot is reused with a new generation: the stale handle stays invalid.
    const int32_t h2 = call(shim_sceAudiodecCreateDecoder, f.ctrl, 3);
    CHECK(h2 > 0 && h2 != h, "Create again: 0x%08x (old 0x%08x)", (uint32_t)h2, (uint32_t)h);
    CHECK(call(shim_sceAudiodecDecode, (uint32_t)h, f.ctrl) == PS4_AUDIODEC_ERROR_INVALID_HANDLE, "stale after reuse");
    CHECK(call(shim_sceAudiodecDecode, (uint32_t)h2, f.ctrl) == 0, "Decode new handle");
    CHECK(call(shim_sceAudiodecDeleteDecoder, (uint32_t)h2, 0) == 0, "Delete new");
    // All handles in use.
    int32_t hs[17];
    int ok = 0;
    for (int i = 0; i < 17; i++) {
        hs[i] = call(shim_sceAudiodecCreateDecoder, f.ctrl, 3);
        if (hs[i] > 0) ok++;
    }
    CHECK(ok == 16 && hs[16] == PS4_AUDIODEC_ERROR_ALL_HANDLES_IN_USE, "%d handles, last 0x%08x", ok, (uint32_t)hs[16]);
    for (int i = 0; i < 16; i++) call(shim_sceAudiodecDeleteDecoder, (uint32_t)hs[i], 0);

    CHECK(call(shim_sceAudiodecTermLibrary, 3, 0) == 0, "Term");
    // CreateDecoder does not require InitLibrary (U4 calls Term per player shutdown).
    const int32_t h3 = call(shim_sceAudiodecCreateDecoder, f.ctrl, 3);
    CHECK(h3 > 0, "Create after Term: 0x%08x", (uint32_t)h3);
    call(shim_sceAudiodecDeleteDecoder, (uint32_t)h3, 0);
}

// Decode on one thread while another deletes the decoder: no use after free (ASan), every call
// either decodes or reports an invalid handle.
typedef struct {
    const Stream *s;
    Frame f;
    int32_t h;
    atomic_int done;
} Race;

static void *race_decoder(void *arg) {
    Race *r = (Race *)arg;
    GuestContext c = g;
    uint8_t au[8192];
    for (uint32_t i = 0;; i = (i + 1) % r->s->npkt) {
        const uint32_t n = adts_wrap(au, r->s, i, 0);
        memcpy(gp(r->f.au_buf), au, n);
        wr32(r->f.au + 0x10, n);
        wr32(r->f.pcm + 0x10, 0x4000);
        c.rdi = (uint32_t)r->h;
        c.rsi = r->f.ctrl;
        shim_sceAudiodecDecode(&c);
        const int32_t rc = (int32_t)c.rax;
        if (rc == PS4_AUDIODEC_ERROR_INVALID_HANDLE) break;
        CHECK(rc == 0, "race decode: 0x%08x", (uint32_t)rc);
        atomic_fetch_add(&r->done, 1);
    }
    return NULL;
}

static void test_delete_race(const Stream *s) {
    for (int round = 0; round < 20; round++) {
        Race r = {.s = s};
        r.f = make_frame(2, 1, freq_index(s->rate), 2, 0x4000);
        wr64(r.f.au + 8, r.f.au_buf);
        r.h = call(shim_sceAudiodecCreateDecoder, r.f.ctrl, 3);
        CHECK(r.h > 0, "race create");
        pthread_t t;
        pthread_create(&t, NULL, race_decoder, &r);
        while (atomic_load(&r.done) < 2 + round) sched_yield();
        CHECK(call(shim_sceAudiodecDeleteDecoder, (uint32_t)r.h, 0) == 0, "race delete");
        pthread_join(t, NULL);
    }
}

int main(void) {
    g.mem_size = 64ULL << 20;
    g.mem_base = (uint8_t *)calloc(1, g.mem_size);
    const double s0[2] = {200, 3000}, s1[2] = {2000, 600}, a2[2] = {0.5, 0.3};
    const double m0[1] = {300}, m1[1] = {3000}, a1[1] = {0.6};
    Stream st, mono;
    make_stream(&st, 48000, 2, 1.0, s0, s1, a2);
    make_stream(&mono, 44100, 1, 1.0, m0, m1, a1);
    printf("audiodec_test: stereo 48 kHz %u access units, mono 44.1 kHz %u\n", st.npkt, mono.npkt);
    CHECK(st.npkt >= 47 && mono.npkt >= 44, "encoder produced %u / %u packets", st.npkt, mono.npkt);
    test_stereo(&st);
    test_mono(&mono);
    test_errors(&st);
    test_delete_race(&st);
    free_stream(&st);
    free_stream(&mono);
    free(g.mem_base);
    if (atomic_load(&failures)) {
        fprintf(stderr, "audiodec_test: %d failure(s)\n", atomic_load(&failures));
        return 1;
    }
    printf("audiodec_test: PASS\n");
    return 0;
}
