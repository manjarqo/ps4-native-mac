// ps4_avplayer.c — PS4 libSceAvPlayer implementation for ps4-recomp.
//
// Implements:
//   - ISO BMFF / MP4 container demuxer (ftyp, moov, mvhd, trak, tkhd, mdia,
//     mdhd, hdlr, minf, stbl, stsd, avc1/avcC, mp4a/esds, stts, ctts, stsc,
//     stsz, stco, co64) over host VFS (ps4_vfs_resolve) or guest
//     SceAvPlayerFileReplacement callbacks (via recomp_call_guest).
//   - Hardware H.264 video decoding via macOS VideoToolbox (H264VtDecoder)
//     into guest NV12 texture buffers allocated through
//     SceAvPlayerMemAllocator::allocate_texture.
//   - AAC-LC audio decoding via macOS AudioToolbox (AudioConverterRef)
//     into guest interleaved S16 PCM buffers allocated through
//     SceAvPlayerMemAllocator::allocate.
//   - Thread-safe instance lifecycle protected by recursive pthread_mutex_t,
//     preventing use-after-free or race conditions between GetVideoDataEx /
//     GetAudioData and Stop / Close (fixes bloodborne_mac_port race #46/#84).

#include "ps4_avplayer.h"
#include "ps4_h264_vt.h"
#include "ps4_vfs.h"

#include <AudioToolbox/AudioToolbox.h>
#include <CoreFoundation/CoreFoundation.h>
#include <CoreMedia/CoreMedia.h>
#include <CoreVideo/CoreVideo.h>
#include <VideoToolbox/VideoToolbox.h>

#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

void ps4_gnm_notify_cpu_write(uint64_t addr, uint64_t size) __attribute__((weak));

// ---------------------------------------------------------------------------
// Constants & Helpers
// ---------------------------------------------------------------------------

#define AVP_MAX_STREAMS          8
#define AVP_MAX_VIDEO_FB         8
#define AVP_MAX_AUDIO_BUFS       4
#define AVP_DEFAULT_VIDEO_FB     4
#define AVP_AUDIO_SAMPLES_PER_AU 1024
#define AVP_FOURCC(a, b, c, d) \
    (((uint32_t)(uint8_t)(a) << 24) | ((uint32_t)(uint8_t)(b) << 16) | \
     ((uint32_t)(uint8_t)(c) << 8)  |  (uint32_t)(uint8_t)(d))

#define AVP_RETURN(val)                  \
    do {                                 \
        ctx->rax = (uint64_t)(val);      \
        SHIM_RETURN();                   \
    } while (0)

static inline uint16_t avp_be16(const uint8_t *p) {
    return (uint16_t)(((uint16_t)p[0] << 8) | (uint16_t)p[1]);
}

static inline uint32_t avp_be32(const uint8_t *p) {
    return ((uint32_t)p[0] << 24) | ((uint32_t)p[1] << 16) |
           ((uint32_t)p[2] << 8)  |  (uint32_t)p[3];
}

static inline uint64_t avp_be64(const uint8_t *p) {
    return ((uint64_t)avp_be32(p) << 32) | (uint64_t)avp_be32(p + 4);
}

// Translate a guest address (or direct host pointer in standalone host tests)
// to a usable host pointer.
static inline void *avp_gptr(GuestContext *ctx, uint64_t addr) {
    if (addr == 0) {
        return NULL;
    }
    if (ctx != NULL && ctx->mem_base != NULL && addr < ctx->mem_size) {
        return (void *)(ctx->mem_base + addr);
    }
    return (void *)(uintptr_t)addr;
}

// Resolve a guest URI or path to a host filesystem path, stripping any
// leading "file://" prefix first.
static int ps4_vfs_resolve_path(const char *uri_or_path, char *host_path, size_t host_path_sz) {
    if (!uri_or_path || !host_path || host_path_sz == 0) {
        return -1;
    }

    const char *clean = uri_or_path;
    if (strncmp(clean, "file://", 7) == 0) {
        clean += 7;
    }

    int rc = ps4_vfs_resolve(clean, host_path, host_path_sz);
    if (rc == 0 && access(host_path, R_OK) == 0) {
        return 0;
    }

    // Fallback: if the caller passed a direct host path (e.g. in host tests)
    // and the file exists directly on disk, use it.
    if (access(clean, R_OK) == 0) {
        snprintf(host_path, host_path_sz, "%s", clean);
        return 0;
    }

    return rc;
}

// ---------------------------------------------------------------------------
// Guest Callback Invocation Helper (recomp_call_guest)
// ---------------------------------------------------------------------------

static inline bool avplayer_is_registered_guest_fn(uint64_t target) {
    if (target == 0 || target >= (1ULL << 48)) {
        return false;
    }
    uint64_t l1_idx = (target >> DISPATCH_L1_SHIFT) & DISPATCH_LEVEL_MASK;
    recomp_fn_t **l2 = g_dispatch_l1[l1_idx];
    if (!l2) {
        return false;
    }
    uint64_t l2_idx = (target >> DISPATCH_L2_SHIFT) & DISPATCH_LEVEL_MASK;
    recomp_fn_t *l3 = l2[l2_idx];
    if (!l3) {
        return false;
    }
    return l3[target & DISPATCH_LEVEL_MASK] != NULL;
}

static uint64_t avplayer_call_guest(GuestContext *ctx, uint64_t fn_addr,
                                    uint64_t arg0, uint64_t arg1,
                                    uint64_t arg2, uint64_t arg3,
                                    uint64_t arg4, uint64_t arg5) {
    if (fn_addr == 0) {
        return 0;
    }

    // If fn_addr is registered in the recomp guest dispatch table, invoke it
    // through recomp_call_guest(ctx, fn_addr) while preserving caller registers.
    if (ctx != NULL && avplayer_is_registered_guest_fn(fn_addr)) {
        uint64_t saved_rax = ctx->rax;
        uint64_t saved_rbx = ctx->rbx;
        uint64_t saved_rcx = ctx->rcx;
        uint64_t saved_rdx = ctx->rdx;
        uint64_t saved_rsi = ctx->rsi;
        uint64_t saved_rdi = ctx->rdi;
        uint64_t saved_rbp = ctx->rbp;
        uint64_t saved_rsp = ctx->rsp;
        uint64_t saved_r8  = ctx->r8;
        uint64_t saved_r9  = ctx->r9;
        uint64_t saved_r10 = ctx->r10;
        uint64_t saved_r11 = ctx->r11;
        uint64_t saved_r12 = ctx->r12;
        uint64_t saved_r13 = ctx->r13;
        uint64_t saved_r14 = ctx->r14;
        uint64_t saved_r15 = ctx->r15;
        uint64_t saved_rip = ctx->rip;

        uint8_t temp_stack[4096] __attribute__((aligned(16)));
        if (ctx->mem_base == NULL || saved_rsp < 256 || saved_rsp >= ctx->mem_size) {
            uintptr_t sp_host = ((uintptr_t)(temp_stack + sizeof(temp_stack) - 128)) & ~(uintptr_t)0xF;
            ctx->rsp = (uint64_t)(sp_host - (uintptr_t)ctx->mem_base);
        } else {
            ctx->rsp = (saved_rsp - 128) & ~0xFULL;
        }

        ctx->rdi = arg0;
        ctx->rsi = arg1;
        ctx->rdx = arg2;
        ctx->rcx = arg3;
        ctx->r8  = arg4;
        ctx->r9  = arg5;

        recomp_call_guest(ctx, fn_addr);
        uint64_t ret = ctx->rax;

        ctx->rax = saved_rax;
        ctx->rbx = saved_rbx;
        ctx->rcx = saved_rcx;
        ctx->rdx = saved_rdx;
        ctx->rsi = saved_rsi;
        ctx->rdi = saved_rdi;
        ctx->rbp = saved_rbp;
        ctx->rsp = saved_rsp;
        ctx->r8  = saved_r8;
        ctx->r9  = saved_r9;
        ctx->r10 = saved_r10;
        ctx->r11 = saved_r11;
        ctx->r12 = saved_r12;
        ctx->r13 = saved_r13;
        ctx->r14 = saved_r14;
        ctx->r15 = saved_r15;
        ctx->rip = saved_rip;

        return ret;
    }

    // Fallback for standalone host tests that pass native C function pointers
    // directly in SceAvPlayerInitData without registering them in g_dispatch_l1.
    typedef uint64_t (*HostCallbackFn)(uint64_t, uint64_t, uint64_t, uint64_t, uint64_t, uint64_t);
    HostCallbackFn fn = (HostCallbackFn)(uintptr_t)fn_addr;
    return fn(arg0, arg1, arg2, arg3, arg4, arg5);
}

// ---------------------------------------------------------------------------
// MP4 Demuxer Structures
// ---------------------------------------------------------------------------

typedef struct AvMp4Sample {
    uint64_t offset;
    uint32_t size;
    uint64_t dts_ms;
    uint64_t pts_ms;
    bool     is_sync;
} AvMp4Sample;

typedef struct AvMp4SttsEntry {
    uint32_t count;
    uint32_t delta;
} AvMp4SttsEntry;

typedef struct AvMp4CttsEntry {
    uint32_t count;
    int32_t  offset;
} AvMp4CttsEntry;

typedef struct AvMp4StscEntry {
    uint32_t first_chunk;
    uint32_t samples_per_chunk;
    uint32_t sample_desc_idx;
} AvMp4StscEntry;

typedef struct AvMp4Track {
    bool                  valid;
    bool                  enabled;
    SceAvPlayerStreamType type;
    uint32_t              timescale;
    uint64_t              duration_ms;
    uint64_t              start_time_ms;
    uint8_t               language_code[4];

    // Video metadata (H.264 / avc1)
    uint32_t              width;
    uint32_t              height;
    float                 aspect_ratio;
    uint32_t              framerate;
    uint8_t               nal_length_size;
    uint8_t              *sps_pps_annexb;
    size_t                sps_pps_len;
    bool                  sent_sps_pps;

    // Audio metadata (AAC / mp4a)
    uint16_t              channel_count;
    uint32_t              sample_rate;
    uint8_t               asc_data[64];
    size_t                asc_len;

    // Demuxed sample table
    AvMp4Sample          *samples;
    uint32_t              sample_count;
    uint32_t              sample_cursor;
} AvMp4Track;

// ---------------------------------------------------------------------------
// Player Instance State
// ---------------------------------------------------------------------------

typedef struct AvPlayerInstance {
    bool                    allocated;
    int32_t                 handle_id;
    pthread_mutex_t         mutex;

    SceAvPlayerInitData     init_data;
    SceAvPlayerPostInitData post_init_data;
    bool                    has_post_init;

    // Source / File I/O state
    char                    source_uri[1024];
    char                    host_path[1024];
    FILE                   *host_fp;
    bool                    using_guest_file_io;
    bool                    guest_file_opened;
    uint64_t                file_size;
    uint64_t                guest_io_scratch_ptr;
    uint32_t                guest_io_scratch_size;

    // Demuxed tracks
    AvMp4Track              tracks[AVP_MAX_STREAMS];
    uint32_t                track_count;
    int32_t                 active_video_track;
    int32_t                 active_audio_track;

    // Playback state
    SceAvPlayerState        state;
    bool                    is_active;
    bool                    is_paused;
    bool                    is_looping;
    uint64_t                current_time_ms;
    int32_t                 trick_speed;
    SceAvPlayerAvSyncMode   sync_mode;

    // Guest-allocated video texture framebuffers (NV12)
    uint64_t                video_tex_ptrs[AVP_MAX_VIDEO_FB];
    uint32_t                video_tex_size;
    uint32_t                video_tex_count;
    uint32_t                video_tex_cursor;

    // Guest-allocated audio PCM buffers (S16 interleaved)
    uint64_t                audio_buf_ptrs[AVP_MAX_AUDIO_BUFS];
    uint32_t                audio_buf_size;
    uint32_t                audio_buf_count;
    uint32_t                audio_buf_cursor;

    // Hardware H.264 decoder (VideoToolbox via ps4_h264_vt)
    H264VtDecoder          *vt_dec;
    uint8_t                *annexb_scratch;
    size_t                  annexb_scratch_cap;

    // AAC AudioToolbox decoder
    AudioConverterRef       audio_converter;
    bool                    audio_converter_ready;
    const uint8_t          *aac_curr_pkt;
    uint32_t                aac_curr_pkt_size;
    AudioStreamPacketDescription aac_pkt_desc;
} AvPlayerInstance;

static pthread_mutex_t  g_avplayer_table_mutex = PTHREAD_MUTEX_INITIALIZER;
static AvPlayerInstance g_players[SCE_AVPLAYER_MAX_INSTANCES];
static bool             g_avplayer_table_inited = false;
static uint64_t         g_avplayer_log_cb = 0;

static void avplayer_ensure_table_init(void) {
    if (g_avplayer_table_inited) {
        return;
    }
    for (int i = 0; i < SCE_AVPLAYER_MAX_INSTANCES; i++) {
        memset(&g_players[i], 0, sizeof(AvPlayerInstance));
        g_players[i].handle_id = i + 1;
        g_players[i].active_video_track = -1;
        g_players[i].active_audio_track = -1;
        pthread_mutexattr_t attr;
        pthread_mutexattr_init(&attr);
        pthread_mutexattr_settype(&attr, PTHREAD_MUTEX_RECURSIVE);
        pthread_mutex_init(&g_players[i].mutex, &attr);
        pthread_mutexattr_destroy(&attr);
    }
    g_avplayer_table_inited = true;
}

static AvPlayerInstance *avplayer_lookup(uint64_t handle) {
    if (handle == 0) {
        return NULL;
    }
    pthread_mutex_lock(&g_avplayer_table_mutex);
    avplayer_ensure_table_init();
    AvPlayerInstance *found = NULL;
    if (handle >= 1 && handle <= SCE_AVPLAYER_MAX_INSTANCES) {
        AvPlayerInstance *cand = &g_players[handle - 1];
        if (cand->allocated) {
            found = cand;
        }
    } else {
        for (int i = 0; i < SCE_AVPLAYER_MAX_INSTANCES; i++) {
            if (g_players[i].allocated && (uint64_t)(uintptr_t)&g_players[i] == handle) {
                found = &g_players[i];
                break;
            }
        }
    }
    pthread_mutex_unlock(&g_avplayer_table_mutex);
    return found;
}

static void avplayer_emit_event(GuestContext *ctx, AvPlayerInstance *p, int32_t event_id) {
    if (p->init_data.event_replacement.event_callback != 0) {
        avplayer_call_guest(ctx,
                            p->init_data.event_replacement.event_callback,
                            p->init_data.event_replacement.object_ptr,
                            (uint64_t)(uint32_t)event_id,
                            0,
                            0,
                            0,
                            0);
    }
}

// ---------------------------------------------------------------------------
// File I/O Abstraction (Host VFS or Guest SceAvPlayerFileReplacement)
// ---------------------------------------------------------------------------

static bool avplayer_io_open(GuestContext *ctx, AvPlayerInstance *p, const char *uri) {
    const SceAvPlayerFileReplacement *fr = &p->init_data.file_replacement;
    if (fr->open != 0 && fr->read_offset != 0 && fr->size != 0) {
        uint32_t scratch_sz = 65536;
        if (p->init_data.memory_replacement.allocate != 0 && p->guest_io_scratch_ptr == 0) {
            p->guest_io_scratch_ptr = avplayer_call_guest(
                ctx, p->init_data.memory_replacement.allocate,
                p->init_data.memory_replacement.object_ptr, 16, scratch_sz, 0, 0, 0);
            if (p->guest_io_scratch_ptr != 0) {
                p->guest_io_scratch_size = scratch_sz;
            }
        }

        uint64_t uri_guest_ptr = (uint64_t)(uintptr_t)uri;
        void *scratch_host = avp_gptr(ctx, p->guest_io_scratch_ptr);
        if (scratch_host != NULL && p->guest_io_scratch_size > 0) {
            size_t ulen = strlen(uri);
            if (ulen + 1 <= p->guest_io_scratch_size) {
                memcpy(scratch_host, uri, ulen + 1);
                uri_guest_ptr = p->guest_io_scratch_ptr;
            }
        }

        int32_t rc = (int32_t)avplayer_call_guest(ctx, fr->open, fr->object_ptr, uri_guest_ptr, 0, 0, 0, 0);
        if (rc >= 0) {
            p->using_guest_file_io = true;
            p->guest_file_opened = true;
            p->file_size = avplayer_call_guest(ctx, fr->size, fr->object_ptr, 0, 0, 0, 0, 0);
            return p->file_size > 0;
        }
    }

    // Host VFS resolution
    if (ps4_vfs_resolve_path(uri, p->host_path, sizeof(p->host_path)) != 0) {
        return false;
    }

    p->host_fp = fopen(p->host_path, "rb");
    if (!p->host_fp) {
        return false;
    }
    if (fseeko(p->host_fp, 0, SEEK_END) != 0) {
        fclose(p->host_fp);
        p->host_fp = NULL;
        return false;
    }
    off_t sz = ftello(p->host_fp);
    if (sz <= 0) {
        fclose(p->host_fp);
        p->host_fp = NULL;
        return false;
    }
    fseeko(p->host_fp, 0, SEEK_SET);
    p->file_size = (uint64_t)sz;
    p->using_guest_file_io = false;
    return true;
}

static bool avplayer_io_read(GuestContext *ctx, AvPlayerInstance *p,
                             uint64_t offset, void *dst, size_t len) {
    if (len == 0) {
        return true;
    }
    if (offset + len > p->file_size) {
        return false;
    }

    if (p->using_guest_file_io) {
        const SceAvPlayerFileReplacement *fr = &p->init_data.file_replacement;
        uint8_t *out = (uint8_t *)dst;
        size_t remaining = len;
        uint64_t pos = offset;
        void *scratch_host = avp_gptr(ctx, p->guest_io_scratch_ptr);
        while (remaining > 0) {
            uint32_t chunk = (uint32_t)remaining;
            uint64_t target_buf = (uint64_t)(uintptr_t)out;
            if (scratch_host != NULL && p->guest_io_scratch_size > 0) {
                if (chunk > p->guest_io_scratch_size) {
                    chunk = p->guest_io_scratch_size;
                }
                target_buf = p->guest_io_scratch_ptr;
            }
            int32_t nread = (int32_t)avplayer_call_guest(
                ctx, fr->read_offset, fr->object_ptr, target_buf, pos, chunk, 0, 0);
            if (nread <= 0) {
                return false;
            }
            if (target_buf == p->guest_io_scratch_ptr && scratch_host != NULL) {
                memcpy(out, scratch_host, (size_t)nread);
            }
            out += (size_t)nread;
            pos += (uint64_t)nread;
            remaining -= (size_t)nread;
        }
        return true;
    }

    if (!p->host_fp) {
        return false;
    }
    if (fseeko(p->host_fp, (off_t)offset, SEEK_SET) != 0) {
        return false;
    }
    return fread(dst, 1, len, p->host_fp) == len;
}

static void avplayer_io_close(GuestContext *ctx, AvPlayerInstance *p) {
    if (p->using_guest_file_io && p->guest_file_opened) {
        if (p->init_data.file_replacement.close != 0) {
            avplayer_call_guest(ctx, p->init_data.file_replacement.close,
                                p->init_data.file_replacement.object_ptr, 0, 0, 0, 0, 0);
        }
        p->guest_file_opened = false;
        p->using_guest_file_io = false;
    }
    if (p->guest_io_scratch_ptr != 0) {
        if (p->init_data.memory_replacement.deallocate != 0) {
            avplayer_call_guest(ctx, p->init_data.memory_replacement.deallocate,
                                p->init_data.memory_replacement.object_ptr,
                                p->guest_io_scratch_ptr, 0, 0, 0, 0);
        }
        p->guest_io_scratch_ptr = 0;
        p->guest_io_scratch_size = 0;
    }
    if (p->host_fp) {
        fclose(p->host_fp);
        p->host_fp = NULL;
    }
}

// ---------------------------------------------------------------------------
// MP4 Container Parser (moov / trak / mdia / minf / stbl)
// ---------------------------------------------------------------------------

typedef struct AvMp4TempTables {
    AvMp4SttsEntry *stts;
    uint32_t        stts_count;
    AvMp4CttsEntry *ctts;
    uint32_t        ctts_count;
    AvMp4StscEntry *stsc;
    uint32_t        stsc_count;
    uint32_t        default_sample_size;
    uint32_t        sample_count;
    uint32_t       *sample_sizes;
    uint64_t       *chunk_offsets;
    uint32_t        chunk_count;
    uint32_t       *stss_sync_samples;
    uint32_t        stss_count;
} AvMp4TempTables;

static void avp_free_temp_tables(AvMp4TempTables *t) {
    if (!t) return;
    free(t->stts);
    free(t->ctts);
    free(t->stsc);
    free(t->sample_sizes);
    free(t->chunk_offsets);
    free(t->stss_sync_samples);
    memset(t, 0, sizeof(*t));
}

// Parse avcC (AVCDecoderConfigurationRecord) into Annex-B SPS/PPS buffer
static void avp_parse_avcc(AvMp4Track *trk, const uint8_t *data, size_t len) {
    if (len < 7) {
        return;
    }
    trk->nal_length_size = (uint8_t)((data[4] & 0x03) + 1);
    uint8_t num_sps = data[5] & 0x1F;
    size_t pos = 6;

    size_t total_annexb = 0;
    size_t scan = pos;
    for (uint8_t i = 0; i < num_sps && scan + 2 <= len; i++) {
        uint16_t sps_len = avp_be16(data + scan);
        scan += 2;
        if (scan + sps_len > len) break;
        total_annexb += 4 + sps_len;
        scan += sps_len;
    }
    if (scan < len) {
        uint8_t num_pps = data[scan++];
        for (uint8_t i = 0; i < num_pps && scan + 2 <= len; i++) {
            uint16_t pps_len = avp_be16(data + scan);
            scan += 2;
            if (scan + pps_len > len) break;
            total_annexb += 4 + pps_len;
            scan += pps_len;
        }
    }

    if (total_annexb == 0) {
        return;
    }

    free(trk->sps_pps_annexb);
    trk->sps_pps_annexb = (uint8_t *)malloc(total_annexb);
    if (!trk->sps_pps_annexb) {
        return;
    }

    size_t out = 0;
    for (uint8_t i = 0; i < num_sps && pos + 2 <= len; i++) {
        uint16_t sps_len = avp_be16(data + pos);
        pos += 2;
        if (pos + sps_len > len) break;
        trk->sps_pps_annexb[out++] = 0x00;
        trk->sps_pps_annexb[out++] = 0x00;
        trk->sps_pps_annexb[out++] = 0x00;
        trk->sps_pps_annexb[out++] = 0x01;
        memcpy(trk->sps_pps_annexb + out, data + pos, sps_len);
        out += sps_len;
        pos += sps_len;
    }
    if (pos < len) {
        uint8_t num_pps = data[pos++];
        for (uint8_t i = 0; i < num_pps && pos + 2 <= len; i++) {
            uint16_t pps_len = avp_be16(data + pos);
            pos += 2;
            if (pos + pps_len > len) break;
            trk->sps_pps_annexb[out++] = 0x00;
            trk->sps_pps_annexb[out++] = 0x00;
            trk->sps_pps_annexb[out++] = 0x00;
            trk->sps_pps_annexb[out++] = 0x01;
            memcpy(trk->sps_pps_annexb + out, data + pos, pps_len);
            out += pps_len;
            pos += pps_len;
        }
    }
    trk->sps_pps_len = out;
}

static const uint32_t kAacSampleRates[16] = {
    96000, 88200, 64000, 48000, 44100, 32000, 24000, 22050,
    16000, 12000, 11025, 8000,  7350,  0,     0,     0
};

// Parse esds box for AAC AudioSpecificConfig (tag 0x05)
static void avp_parse_esds(AvMp4Track *trk, const uint8_t *data, size_t len) {
    if (len < 6) {
        return;
    }
    size_t i = 4;
    while (i + 2 <= len) {
        uint8_t tag = data[i++];
        uint32_t desc_len = 0;
        for (int b = 0; b < 4 && i < len; b++) {
            uint8_t c = data[i++];
            desc_len = (desc_len << 7) | (c & 0x7F);
            if ((c & 0x80) == 0) break;
        }
        if (tag == 0x03) { // ES_DescrTag
            if (i + 3 > len) break;
            uint8_t flags = data[i + 2];
            i += 3;
            if (flags & 0x80) i += 2;
            if (flags & 0x40) {
                if (i < len) i += 1 + data[i];
            }
            if (flags & 0x20) i += 2;
        } else if (tag == 0x04) { // DecoderConfigDescrTag
            if (i + 13 > len) break;
            i += 13;
        } else if (tag == 0x05) { // DecSpecificInfoTag (AudioSpecificConfig)
            if (desc_len > 0 && i + desc_len <= len) {
                size_t copy_len = desc_len < sizeof(trk->asc_data) ? desc_len : sizeof(trk->asc_data);
                memcpy(trk->asc_data, data + i, copy_len);
                trk->asc_len = copy_len;

                if (copy_len >= 2) {
                    uint8_t b0 = data[i];
                    uint8_t b1 = data[i + 1];
                    uint8_t sr_idx = (uint8_t)(((b0 & 0x07) << 1) | ((b1 >> 7) & 0x01));
                    uint8_t ch_cfg = (uint8_t)((b1 >> 3) & 0x0F);
                    if (sr_idx < 13 && kAacSampleRates[sr_idx] > 0) {
                        trk->sample_rate = kAacSampleRates[sr_idx];
                    }
                    if (ch_cfg > 0 && ch_cfg <= 8) {
                        trk->channel_count = ch_cfg;
                    }
                }
            }
            break;
        } else {
            i += desc_len;
        }
    }
}

// Parse stsd box (sample descriptions: avc1/avc3/mp4a)
static void avp_parse_stsd(AvMp4Track *trk, const uint8_t *data, size_t len) {
    if (len < 8) {
        return;
    }
    uint32_t entry_count = avp_be32(data + 4);
    size_t pos = 8;
    for (uint32_t e = 0; e < entry_count && pos + 8 <= len; e++) {
        uint32_t esize = avp_be32(data + pos);
        uint32_t etype = avp_be32(data + pos + 4);
        if (esize < 8 || pos + esize > len) {
            break;
        }
        const uint8_t *entry = data + pos;

        if (etype == AVP_FOURCC('a', 'v', 'c', '1') ||
            etype == AVP_FOURCC('a', 'v', 'c', '3') ||
            etype == AVP_FOURCC('e', 'n', 'c', 'v')) {
            trk->type = SCE_AVPLAYER_VIDEO;
            if (esize >= 86) {
                uint16_t w = avp_be16(entry + 32);
                uint16_t h = avp_be16(entry + 34);
                if (w > 0) trk->width = w;
                if (h > 0) trk->height = h;
                if (trk->width > 0 && trk->height > 0) {
                    trk->aspect_ratio = (float)trk->width / (float)trk->height;
                }

                size_t sub = 86;
                while (sub + 8 <= esize) {
                    uint32_t bsz = avp_be32(entry + sub);
                    uint32_t bty = avp_be32(entry + sub + 4);
                    if (bsz < 8 || sub + bsz > esize) break;
                    if (bty == AVP_FOURCC('a', 'v', 'c', 'C')) {
                        avp_parse_avcc(trk, entry + sub + 8, bsz - 8);
                    } else if (bty == AVP_FOURCC('p', 'a', 's', 'p') && bsz >= 16) {
                        uint32_t h_sp = avp_be32(entry + sub + 8);
                        uint32_t v_sp = avp_be32(entry + sub + 12);
                        if (h_sp > 0 && v_sp > 0 && trk->width > 0 && trk->height > 0) {
                            trk->aspect_ratio = ((float)trk->width * (float)h_sp) /
                                                ((float)trk->height * (float)v_sp);
                        }
                    }
                    sub += bsz;
                }
            }
        } else if (etype == AVP_FOURCC('m', 'p', '4', 'a') ||
                   etype == AVP_FOURCC('e', 'n', 'c', 'a')) {
            trk->type = SCE_AVPLAYER_AUDIO;
            if (esize >= 36) {
                uint16_t version = avp_be16(entry + 16);
                uint16_t ch = avp_be16(entry + 24);
                uint32_t sr = avp_be32(entry + 32) >> 16;
                if (ch > 0) trk->channel_count = ch;
                if (sr > 0) trk->sample_rate = sr;

                size_t sub = 36;
                if (version == 1 && esize >= 52) sub = 52;
                else if (version == 2 && esize >= 72) sub = 72;

                while (sub + 8 <= esize) {
                    uint32_t bsz = avp_be32(entry + sub);
                    uint32_t bty = avp_be32(entry + sub + 4);
                    if (bsz < 8 || sub + bsz > esize) break;
                    if (bty == AVP_FOURCC('e', 's', 'd', 's')) {
                        avp_parse_esds(trk, entry + sub + 8, bsz - 8);
                    }
                    sub += bsz;
                }
            }
        }

        pos += esize;
    }
}

// Build flat sample table from stts, ctts, stsc, stsz, stco/co64
static void avp_build_track_samples(AvMp4Track *trk, const AvMp4TempTables *tbl) {
    if (!trk || !tbl || tbl->sample_count == 0 || tbl->chunk_count == 0 || tbl->stsc_count == 0) {
        return;
    }

    uint32_t n = tbl->sample_count;
    AvMp4Sample *samples = (AvMp4Sample *)calloc(n, sizeof(AvMp4Sample));
    if (!samples) {
        return;
    }

    uint32_t ts = trk->timescale > 0 ? trk->timescale : 1000;

    // 1. Sample sizes (stsz)
    for (uint32_t i = 0; i < n; i++) {
        samples[i].size = (tbl->default_sample_size != 0)
                              ? tbl->default_sample_size
                              : (tbl->sample_sizes ? tbl->sample_sizes[i] : 0);
        samples[i].is_sync = (tbl->stss_count == 0);
    }

    for (uint32_t i = 0; i < tbl->stss_count; i++) {
        uint32_t idx1 = tbl->stss_sync_samples[i];
        if (idx1 >= 1 && idx1 <= n) {
            samples[idx1 - 1].is_sync = true;
        }
    }
    if (n > 0) {
        samples[0].is_sync = true;
    }

    // 2. Sample file offsets (stsc + stco/co64)
    uint32_t sample_idx = 0;
    for (uint32_t c = 0; c < tbl->chunk_count && sample_idx < n; c++) {
        uint32_t chunk_num_1based = c + 1;
        uint32_t spc = tbl->stsc[0].samples_per_chunk;
        for (uint32_t s = 0; s < tbl->stsc_count; s++) {
            if (tbl->stsc[s].first_chunk <= chunk_num_1based) {
                spc = tbl->stsc[s].samples_per_chunk;
            } else {
                break;
            }
        }
        uint64_t cur_off = tbl->chunk_offsets[c];
        for (uint32_t k = 0; k < spc && sample_idx < n; k++) {
            samples[sample_idx].offset = cur_off;
            cur_off += samples[sample_idx].size;
            sample_idx++;
        }
    }

    // 3. Decoding timestamps (stts)
    uint64_t cur_dts_ticks = 0;
    uint32_t total_delta_ticks = 0;
    sample_idx = 0;
    for (uint32_t i = 0; i < tbl->stts_count && sample_idx < n; i++) {
        uint32_t cnt = tbl->stts[i].count;
        uint32_t delta = tbl->stts[i].delta;
        for (uint32_t k = 0; k < cnt && sample_idx < n; k++) {
            samples[sample_idx].dts_ms = (cur_dts_ticks * 1000ULL) / ts;
            samples[sample_idx].pts_ms = samples[sample_idx].dts_ms;
            cur_dts_ticks += delta;
            if (sample_idx == 0) {
                total_delta_ticks = delta;
            }
            sample_idx++;
        }
    }

    if (trk->type == SCE_AVPLAYER_VIDEO && trk->framerate == 0) {
        if (total_delta_ticks > 0 && ts >= total_delta_ticks) {
            trk->framerate = (ts + (total_delta_ticks / 2)) / total_delta_ticks;
        } else {
            trk->framerate = 30;
        }
    }

    // 4. Composition timestamp offsets (ctts)
    if (tbl->ctts && tbl->ctts_count > 0) {
        sample_idx = 0;
        for (uint32_t i = 0; i < tbl->ctts_count && sample_idx < n; i++) {
            uint32_t cnt = tbl->ctts[i].count;
            int32_t off = tbl->ctts[i].offset;
            for (uint32_t k = 0; k < cnt && sample_idx < n; k++) {
                int64_t pts_ms = (int64_t)samples[sample_idx].dts_ms +
                                 ((int64_t)off * 1000LL) / (int64_t)ts;
                samples[sample_idx].pts_ms = pts_ms > 0 ? (uint64_t)pts_ms : 0;
                sample_idx++;
            }
        }
    }

    if (trk->duration_ms == 0 && cur_dts_ticks > 0) {
        trk->duration_ms = (cur_dts_ticks * 1000ULL) / ts;
    }

    trk->samples = samples;
    trk->sample_count = n;
    trk->sample_cursor = 0;
}

static void avp_parse_boxes_in_memory(const uint8_t *buf, size_t len,
                                      AvMp4Track *cur_trk, AvMp4TempTables *cur_tbl,
                                      AvPlayerInstance *player, uint32_t *movie_timescale,
                                      uint64_t *movie_duration_ms) {
    size_t pos = 0;
    while (pos + 8 <= len) {
        uint64_t bsize = avp_be32(buf + pos);
        uint32_t btype = avp_be32(buf + pos + 4);
        size_t hdr_len = 8;

        if (bsize == 1) {
            if (pos + 16 > len) break;
            bsize = avp_be64(buf + pos + 8);
            hdr_len = 16;
        } else if (bsize == 0) {
            bsize = len - pos;
        }

        if (bsize < hdr_len || pos + bsize > len) {
            break;
        }

        const uint8_t *payload = buf + pos + hdr_len;
        size_t plen = (size_t)(bsize - hdr_len);

        switch (btype) {
            case AVP_FOURCC('m', 'o', 'o', 'v'):
            case AVP_FOURCC('m', 'd', 'i', 'a'):
            case AVP_FOURCC('m', 'i', 'n', 'f'):
            case AVP_FOURCC('s', 't', 'b', 'l'):
                avp_parse_boxes_in_memory(payload, plen, cur_trk, cur_tbl,
                                          player, movie_timescale, movie_duration_ms);
                break;

            case AVP_FOURCC('t', 'r', 'a', 'k'): {
                if (player->track_count < AVP_MAX_STREAMS) {
                    AvMp4Track *trk = &player->tracks[player->track_count];
                    memset(trk, 0, sizeof(*trk));
                    trk->type = SCE_AVPLAYER_UNKNOWN;
                    trk->nal_length_size = 4;
                    memcpy(trk->language_code, "und", 4);

                    AvMp4TempTables tbl;
                    memset(&tbl, 0, sizeof(tbl));

                    avp_parse_boxes_in_memory(payload, plen, trk, &tbl,
                                              player, movie_timescale, movie_duration_ms);
                    avp_build_track_samples(trk, &tbl);
                    avp_free_temp_tables(&tbl);

                    if (trk->type == SCE_AVPLAYER_VIDEO || trk->type == SCE_AVPLAYER_AUDIO) {
                        if (trk->type == SCE_AVPLAYER_VIDEO) {
                            if (trk->width == 0) trk->width = 1920;
                            if (trk->height == 0) trk->height = 1080;
                            if (trk->aspect_ratio <= 0.0f) {
                                trk->aspect_ratio = (float)trk->width / (float)trk->height;
                            }
                            if (trk->framerate == 0) trk->framerate = 30;
                        } else if (trk->type == SCE_AVPLAYER_AUDIO) {
                            if (trk->channel_count == 0) trk->channel_count = 2;
                            if (trk->sample_rate == 0) trk->sample_rate = 48000;
                        }
                        if (trk->duration_ms == 0 && *movie_duration_ms > 0) {
                            trk->duration_ms = *movie_duration_ms;
                        }
                        trk->valid = true;
                        player->track_count++;
                    } else {
                        free(trk->sps_pps_annexb);
                        free(trk->samples);
                        memset(trk, 0, sizeof(*trk));
                    }
                }
                break;
            }

            case AVP_FOURCC('m', 'v', 'h', 'd'): {
                if (plen >= 20) {
                    uint8_t ver = payload[0];
                    if (ver == 1 && plen >= 32) {
                        uint32_t ts = avp_be32(payload + 20);
                        uint64_t dur = avp_be64(payload + 24);
                        if (ts > 0) {
                            *movie_timescale = ts;
                            *movie_duration_ms = (dur * 1000ULL) / ts;
                        }
                    } else {
                        uint32_t ts = avp_be32(payload + 12);
                        uint32_t dur = avp_be32(payload + 16);
                        if (ts > 0) {
                            *movie_timescale = ts;
                            *movie_duration_ms = ((uint64_t)dur * 1000ULL) / ts;
                        }
                    }
                }
                break;
            }

            case AVP_FOURCC('t', 'k', 'h', 'd'): {
                if (cur_trk && plen >= 84) {
                    uint32_t w_fixed = avp_be32(payload + plen - 8);
                    uint32_t h_fixed = avp_be32(payload + plen - 4);
                    uint32_t w = w_fixed >> 16;
                    uint32_t h = h_fixed >> 16;
                    if (w > 0 && cur_trk->width == 0) cur_trk->width = w;
                    if (h > 0 && cur_trk->height == 0) cur_trk->height = h;
                }
                break;
            }

            case AVP_FOURCC('m', 'd', 'h', 'd'): {
                if (cur_trk && plen >= 24) {
                    uint8_t ver = payload[0];
                    uint32_t ts = 0;
                    uint64_t dur = 0;
                    uint16_t lang = 0;
                    if (ver == 1 && plen >= 36) {
                        ts = avp_be32(payload + 20);
                        dur = avp_be64(payload + 24);
                        lang = avp_be16(payload + 32);
                    } else {
                        ts = avp_be32(payload + 12);
                        dur = avp_be32(payload + 16);
                        lang = avp_be16(payload + 20);
                    }
                    if (ts > 0) {
                        cur_trk->timescale = ts;
                        if (dur != 0xFFFFFFFFULL && dur != UINT64_MAX) {
                            cur_trk->duration_ms = (dur * 1000ULL) / ts;
                        }
                    }
                    char c0 = (char)(((lang >> 10) & 0x1F) + 0x60);
                    char c1 = (char)(((lang >> 5)  & 0x1F) + 0x60);
                    char c2 = (char)((lang         & 0x1F) + 0x60);
                    if (c0 >= 'a' && c0 <= 'z' && c1 >= 'a' && c1 <= 'z' && c2 >= 'a' && c2 <= 'z') {
                        cur_trk->language_code[0] = (uint8_t)c0;
                        cur_trk->language_code[1] = (uint8_t)c1;
                        cur_trk->language_code[2] = (uint8_t)c2;
                        cur_trk->language_code[3] = 0;
                    }
                }
                break;
            }

            case AVP_FOURCC('h', 'd', 'l', 'r'): {
                if (cur_trk && plen >= 12) {
                    uint32_t htype = avp_be32(payload + 8);
                    if (htype == AVP_FOURCC('v', 'i', 'd', 'e')) {
                        cur_trk->type = SCE_AVPLAYER_VIDEO;
                    } else if (htype == AVP_FOURCC('s', 'o', 'u', 'n')) {
                        cur_trk->type = SCE_AVPLAYER_AUDIO;
                    } else if (htype == AVP_FOURCC('t', 'e', 'x', 't') ||
                               htype == AVP_FOURCC('s', 'b', 't', 'l') ||
                               htype == AVP_FOURCC('s', 'u', 'b', 'p')) {
                        cur_trk->type = SCE_AVPLAYER_TIMED_TEXT;
                    }
                }
                break;
            }

            case AVP_FOURCC('s', 't', 's', 'd'): {
                if (cur_trk) {
                    avp_parse_stsd(cur_trk, payload, plen);
                }
                break;
            }

            case AVP_FOURCC('s', 't', 't', 's'): {
                if (cur_tbl && plen >= 8) {
                    uint32_t cnt = avp_be32(payload + 4);
                    if (cnt > 0 && 8 + (size_t)cnt * 8 <= plen) {
                        free(cur_tbl->stts);
                        cur_tbl->stts = (AvMp4SttsEntry *)calloc(cnt, sizeof(AvMp4SttsEntry));
                        if (cur_tbl->stts) {
                            cur_tbl->stts_count = cnt;
                            for (uint32_t i = 0; i < cnt; i++) {
                                cur_tbl->stts[i].count = avp_be32(payload + 8 + i * 8);
                                cur_tbl->stts[i].delta = avp_be32(payload + 12 + i * 8);
                            }
                        }
                    }
                }
                break;
            }

            case AVP_FOURCC('c', 't', 't', 's'): {
                if (cur_tbl && plen >= 8) {
                    uint32_t cnt = avp_be32(payload + 4);
                    if (cnt > 0 && 8 + (size_t)cnt * 8 <= plen) {
                        free(cur_tbl->ctts);
                        cur_tbl->ctts = (AvMp4CttsEntry *)calloc(cnt, sizeof(AvMp4CttsEntry));
                        if (cur_tbl->ctts) {
                            cur_tbl->ctts_count = cnt;
                            for (uint32_t i = 0; i < cnt; i++) {
                                cur_tbl->ctts[i].count  = avp_be32(payload + 8 + i * 8);
                                cur_tbl->ctts[i].offset = (int32_t)avp_be32(payload + 12 + i * 8);
                            }
                        }
                    }
                }
                break;
            }

            case AVP_FOURCC('s', 't', 's', 'c'): {
                if (cur_tbl && plen >= 8) {
                    uint32_t cnt = avp_be32(payload + 4);
                    if (cnt > 0 && 8 + (size_t)cnt * 12 <= plen) {
                        free(cur_tbl->stsc);
                        cur_tbl->stsc = (AvMp4StscEntry *)calloc(cnt, sizeof(AvMp4StscEntry));
                        if (cur_tbl->stsc) {
                            cur_tbl->stsc_count = cnt;
                            for (uint32_t i = 0; i < cnt; i++) {
                                cur_tbl->stsc[i].first_chunk       = avp_be32(payload + 8 + i * 12);
                                cur_tbl->stsc[i].samples_per_chunk = avp_be32(payload + 12 + i * 12);
                                cur_tbl->stsc[i].sample_desc_idx   = avp_be32(payload + 16 + i * 12);
                            }
                        }
                    }
                }
                break;
            }

            case AVP_FOURCC('s', 't', 's', 'z'): {
                if (cur_tbl && plen >= 12) {
                    uint32_t def_sz = avp_be32(payload + 4);
                    uint32_t cnt    = avp_be32(payload + 8);
                    cur_tbl->default_sample_size = def_sz;
                    cur_tbl->sample_count = cnt;
                    if (def_sz == 0 && cnt > 0 && 12 + (size_t)cnt * 4 <= plen) {
                        free(cur_tbl->sample_sizes);
                        cur_tbl->sample_sizes = (uint32_t *)calloc(cnt, sizeof(uint32_t));
                        if (cur_tbl->sample_sizes) {
                            for (uint32_t i = 0; i < cnt; i++) {
                                cur_tbl->sample_sizes[i] = avp_be32(payload + 12 + i * 4);
                            }
                        }
                    }
                }
                break;
            }

            case AVP_FOURCC('s', 't', 'c', 'o'): {
                if (cur_tbl && plen >= 8) {
                    uint32_t cnt = avp_be32(payload + 4);
                    if (cnt > 0 && 8 + (size_t)cnt * 4 <= plen) {
                        free(cur_tbl->chunk_offsets);
                        cur_tbl->chunk_offsets = (uint64_t *)calloc(cnt, sizeof(uint64_t));
                        if (cur_tbl->chunk_offsets) {
                            cur_tbl->chunk_count = cnt;
                            for (uint32_t i = 0; i < cnt; i++) {
                                cur_tbl->chunk_offsets[i] = avp_be32(payload + 8 + i * 4);
                            }
                        }
                    }
                }
                break;
            }

            case AVP_FOURCC('c', 'o', '6', '4'): {
                if (cur_tbl && plen >= 8) {
                    uint32_t cnt = avp_be32(payload + 4);
                    if (cnt > 0 && 8 + (size_t)cnt * 8 <= plen) {
                        free(cur_tbl->chunk_offsets);
                        cur_tbl->chunk_offsets = (uint64_t *)calloc(cnt, sizeof(uint64_t));
                        if (cur_tbl->chunk_offsets) {
                            cur_tbl->chunk_count = cnt;
                            for (uint32_t i = 0; i < cnt; i++) {
                                cur_tbl->chunk_offsets[i] = avp_be64(payload + 8 + i * 8);
                            }
                        }
                    }
                }
                break;
            }

            case AVP_FOURCC('s', 't', 's', 's'): {
                if (cur_tbl && plen >= 8) {
                    uint32_t cnt = avp_be32(payload + 4);
                    if (cnt > 0 && 8 + (size_t)cnt * 4 <= plen) {
                        free(cur_tbl->stss_sync_samples);
                        cur_tbl->stss_sync_samples = (uint32_t *)calloc(cnt, sizeof(uint32_t));
                        if (cur_tbl->stss_sync_samples) {
                            cur_tbl->stss_count = cnt;
                            for (uint32_t i = 0; i < cnt; i++) {
                                cur_tbl->stss_sync_samples[i] = avp_be32(payload + 8 + i * 4);
                            }
                        }
                    }
                }
                break;
            }

            default:
                break;
        }

        pos += (size_t)bsize;
    }
}

static bool avp_demux_mp4(GuestContext *ctx, AvPlayerInstance *p) {
    uint64_t offset = 0;
    bool found_moov = false;
    uint32_t movie_timescale = 1000;
    uint64_t movie_duration_ms = 0;

    while (offset + 8 <= p->file_size) {
        uint8_t hdr[16];
        if (!avplayer_io_read(ctx, p, offset, hdr, 8)) {
            break;
        }
        uint64_t bsize = avp_be32(hdr);
        uint32_t btype = avp_be32(hdr + 4);
        uint64_t hdr_len = 8;

        if (bsize == 1) {
            if (offset + 16 > p->file_size || !avplayer_io_read(ctx, p, offset + 8, hdr + 8, 8)) {
                break;
            }
            bsize = avp_be64(hdr + 8);
            hdr_len = 16;
        } else if (bsize == 0) {
            bsize = p->file_size - offset;
        }

        if (bsize < hdr_len || offset + bsize > p->file_size) {
            break;
        }

        if (btype == AVP_FOURCC('m', 'o', 'o', 'v')) {
            uint64_t plen = bsize - hdr_len;
            if (plen > 0 && plen <= (128ULL * 1024ULL * 1024ULL)) {
                uint8_t *moov_buf = (uint8_t *)malloc((size_t)plen);
                if (moov_buf) {
                    if (avplayer_io_read(ctx, p, offset + hdr_len, moov_buf, (size_t)plen)) {
                        avp_parse_boxes_in_memory(moov_buf, (size_t)plen, NULL, NULL,
                                                  p, &movie_timescale, &movie_duration_ms);
                        found_moov = (p->track_count > 0);
                    }
                    free(moov_buf);
                }
            }
            break;
        }

        offset += bsize;
    }

    return found_moov;
}

// ---------------------------------------------------------------------------
// Guest Memory Buffer Management & Decoder Setup
// ---------------------------------------------------------------------------

static bool avp_allocate_stream_buffers_locked(GuestContext *ctx, AvPlayerInstance *p) {
    if (p->active_video_track >= 0 && p->active_video_track < (int32_t)p->track_count &&
        p->video_tex_count == 0) {
        AvMp4Track *vtrk = &p->tracks[p->active_video_track];
        uint32_t w = vtrk->width > 0 ? vtrk->width : 1920;
        uint32_t h = vtrk->height > 0 ? vtrk->height : 1080;
        uint64_t nv12_sz = h264vt_nv12_size(w, h);
        uint32_t num_fb = (p->init_data.num_output_video_framebuffers >= 2 &&
                           p->init_data.num_output_video_framebuffers <= AVP_MAX_VIDEO_FB)
                              ? (uint32_t)p->init_data.num_output_video_framebuffers
                              : AVP_DEFAULT_VIDEO_FB;

        if (p->init_data.memory_replacement.allocate_texture != 0) {
            for (uint32_t i = 0; i < num_fb; i++) {
                uint64_t ptr = avplayer_call_guest(
                    ctx, p->init_data.memory_replacement.allocate_texture,
                    p->init_data.memory_replacement.object_ptr,
                    256, (uint32_t)nv12_sz, 0, 0, 0);
                if (ptr == 0) {
                    return false;
                }
                p->video_tex_ptrs[p->video_tex_count++] = ptr;
            }
            p->video_tex_size = (uint32_t)nv12_sz;
            p->video_tex_cursor = 0;
        }
    }

    if (p->active_audio_track >= 0 && p->active_audio_track < (int32_t)p->track_count &&
        p->audio_buf_count == 0) {
        AvMp4Track *atrk = &p->tracks[p->active_audio_track];
        uint32_t ch = atrk->channel_count > 0 ? atrk->channel_count : 2;
        uint32_t pcm_sz = AVP_AUDIO_SAMPLES_PER_AU * ch * sizeof(int16_t);
        if (p->init_data.memory_replacement.allocate != 0) {
            for (uint32_t i = 0; i < AVP_MAX_AUDIO_BUFS; i++) {
                uint64_t ptr = avplayer_call_guest(
                    ctx, p->init_data.memory_replacement.allocate,
                    p->init_data.memory_replacement.object_ptr,
                    16, pcm_sz, 0, 0, 0);
                if (ptr == 0) {
                    return false;
                }
                p->audio_buf_ptrs[p->audio_buf_count++] = ptr;
            }
            p->audio_buf_size = pcm_sz;
            p->audio_buf_cursor = 0;
        }
    }

    return true;
}

static void avp_release_decoders_and_buffers_locked(GuestContext *ctx, AvPlayerInstance *p) {
    // 1. Destroy hardware H.264 VideoToolbox decoder & AAC AudioConverter FIRST
    //    so no decoder can access guest memory during or after deallocation.
    if (p->vt_dec) {
        h264vt_destroy(p->vt_dec);
        p->vt_dec = NULL;
    }
    if (p->audio_converter) {
        AudioConverterDispose(p->audio_converter);
        p->audio_converter = NULL;
        p->audio_converter_ready = false;
    }
    free(p->annexb_scratch);
    p->annexb_scratch = NULL;
    p->annexb_scratch_cap = 0;

    // 2. Deallocate guest video texture buffers via deallocate_texture
    for (uint32_t i = 0; i < p->video_tex_count; i++) {
        uint64_t ptr = p->video_tex_ptrs[i];
        p->video_tex_ptrs[i] = 0;
        if (ptr != 0 && p->init_data.memory_replacement.deallocate_texture != 0) {
            avplayer_call_guest(ctx, p->init_data.memory_replacement.deallocate_texture,
                                p->init_data.memory_replacement.object_ptr, ptr, 0, 0, 0, 0);
        }
    }
    p->video_tex_count = 0;
    p->video_tex_size = 0;
    p->video_tex_cursor = 0;

    // 3. Deallocate guest audio buffers via deallocate
    for (uint32_t i = 0; i < p->audio_buf_count; i++) {
        uint64_t ptr = p->audio_buf_ptrs[i];
        p->audio_buf_ptrs[i] = 0;
        if (ptr != 0 && p->init_data.memory_replacement.deallocate != 0) {
            avplayer_call_guest(ctx, p->init_data.memory_replacement.deallocate,
                                p->init_data.memory_replacement.object_ptr, ptr, 0, 0, 0, 0);
        }
    }
    p->audio_buf_count = 0;
    p->audio_buf_size = 0;
    p->audio_buf_cursor = 0;
}

static void avp_free_tracks_locked(AvPlayerInstance *p) {
    for (uint32_t i = 0; i < p->track_count; i++) {
        free(p->tracks[i].sps_pps_annexb);
        free(p->tracks[i].samples);
        memset(&p->tracks[i], 0, sizeof(AvMp4Track));
    }
    p->track_count = 0;
    p->active_video_track = -1;
    p->active_audio_track = -1;
}

static void avp_stop_locked(GuestContext *ctx, AvPlayerInstance *p) {
    p->is_active = false;
    p->is_paused = false;
    p->state = SCE_AVPLAYER_STATE_STOP;
    p->current_time_ms = 0;

    avp_release_decoders_and_buffers_locked(ctx, p);
    avp_free_tracks_locked(p);
    avplayer_io_close(ctx, p);
}

// ---------------------------------------------------------------------------
// Video Frame Decoding (MP4 AVCC/Annex-B -> VideoToolbox H264VtDecoder -> NV12)
// ---------------------------------------------------------------------------

static size_t avp_sample_to_annexb(AvPlayerInstance *p, AvMp4Track *vtrk,
                                   const uint8_t *sample_data, uint32_t sample_size,
                                   bool prepend_sps_pps) {
    size_t needed = (prepend_sps_pps ? vtrk->sps_pps_len : 0) + (size_t)sample_size + 64;
    if (needed > p->annexb_scratch_cap) {
        size_t new_cap = needed * 2;
        uint8_t *nbuf = (uint8_t *)realloc(p->annexb_scratch, new_cap);
        if (!nbuf) {
            return 0;
        }
        p->annexb_scratch = nbuf;
        p->annexb_scratch_cap = new_cap;
    }

    size_t out = 0;
    if (prepend_sps_pps && vtrk->sps_pps_annexb && vtrk->sps_pps_len > 0) {
        memcpy(p->annexb_scratch, vtrk->sps_pps_annexb, vtrk->sps_pps_len);
        out += vtrk->sps_pps_len;
    }

    // Check if the sample is already Annex-B start-code prefixed
    if (sample_size >= 4 &&
        ((sample_data[0] == 0 && sample_data[1] == 0 && sample_data[2] == 0 && sample_data[3] == 1) ||
         (sample_data[0] == 0 && sample_data[1] == 0 && sample_data[2] == 1))) {
        memcpy(p->annexb_scratch + out, sample_data, sample_size);
        out += sample_size;
        return out;
    }

    // Otherwise parse length-prefixed AVCC NAL units
    uint8_t nlen_sz = vtrk->nal_length_size ? vtrk->nal_length_size : 4;
    size_t pos = 0;
    while (pos + nlen_sz <= sample_size) {
        uint32_t nal_len = 0;
        for (uint8_t b = 0; b < nlen_sz; b++) {
            nal_len = (nal_len << 8) | sample_data[pos + b];
        }
        pos += nlen_sz;
        if (nal_len == 0 || pos + nal_len > sample_size) {
            break;
        }
        if (out + 4 + nal_len > p->annexb_scratch_cap) {
            size_t new_cap = (out + 4 + nal_len) * 2;
            uint8_t *nbuf = (uint8_t *)realloc(p->annexb_scratch, new_cap);
            if (!nbuf) break;
            p->annexb_scratch = nbuf;
            p->annexb_scratch_cap = new_cap;
        }
        p->annexb_scratch[out++] = 0x00;
        p->annexb_scratch[out++] = 0x00;
        p->annexb_scratch[out++] = 0x00;
        p->annexb_scratch[out++] = 0x01;
        memcpy(p->annexb_scratch + out, sample_data + pos, nal_len);
        out += nal_len;
        pos += nal_len;
    }

    return out;
}

static bool avp_decode_next_video_frame_locked(GuestContext *ctx, AvPlayerInstance *p,
                                               SceAvPlayerFrameInfoEx *out_info) {
    if (!p->is_active || p->is_paused || p->active_video_track < 0 ||
        p->active_video_track >= (int32_t)p->track_count) {
        return false;
    }

    AvMp4Track *vtrk = &p->tracks[p->active_video_track];
    if (vtrk->sample_count == 0) {
        p->is_active = false;
        return false;
    }

    if (p->video_tex_count == 0) {
        if (!avp_allocate_stream_buffers_locked(ctx, p) || p->video_tex_count == 0) {
            return false;
        }
    }

    if (!p->vt_dec) {
        p->vt_dec = h264vt_create("libSceAvPlayer");
        if (!p->vt_dec) {
            return false;
        }
    }

    H264VtFrame *vt_frame = h264vt_pop(p->vt_dec);
    uint64_t fallback_pts_ms = p->current_time_ms;
    bool fed_any = false;

    int max_feed_iters = 8;
    while (vt_frame == NULL && max_feed_iters-- > 0) {
        if (vtrk->sample_cursor >= vtrk->sample_count) {
            h264vt_finish(p->vt_dec);
            vt_frame = h264vt_pop(p->vt_dec);
            if (vt_frame == NULL) {
                if (p->is_looping) {
                    vtrk->sample_cursor = 0;
                    vtrk->sent_sps_pps = false;
                    h264vt_reset(p->vt_dec);
                    if (p->active_audio_track >= 0 &&
                        p->active_audio_track < (int32_t)p->track_count) {
                        p->tracks[p->active_audio_track].sample_cursor = 0;
                    }
                    continue;
                } else {
                    p->is_active = false;
                    p->state = SCE_AVPLAYER_STATE_STOP;
                    avplayer_emit_event(ctx, p, SCE_AVPLAYER_STATE_STOP);
                    return false;
                }
            }
            break;
        }

        const AvMp4Sample *smp = &vtrk->samples[vtrk->sample_cursor++];
        fallback_pts_ms = smp->pts_ms;
        if (smp->size == 0) {
            continue;
        }

        uint8_t *raw_sample = (uint8_t *)malloc(smp->size);
        if (!raw_sample) {
            break;
        }
        bool ok_read = avplayer_io_read(ctx, p, smp->offset, raw_sample, smp->size);
        if (ok_read) {
            bool need_hdr = (!vtrk->sent_sps_pps || smp->is_sync);
            size_t annexb_len = avp_sample_to_annexb(p, vtrk, raw_sample, smp->size, need_hdr);
            if (annexb_len > 0) {
                vtrk->sent_sps_pps = true;
                fed_any = true;
                h264vt_decode(p->vt_dec, p->annexb_scratch, annexb_len,
                              (int64_t)smp->pts_ms, (int64_t)smp->dts_ms, 0, NULL);
            }
        }
        free(raw_sample);

        if (vtrk->sample_cursor >= vtrk->sample_count) {
            h264vt_finish(p->vt_dec);
        }
        vt_frame = h264vt_pop(p->vt_dec);
    }

    uint64_t dst_tex = p->video_tex_ptrs[p->video_tex_cursor % p->video_tex_count];
    uint8_t *dst_host = (uint8_t *)avp_gptr(ctx, dst_tex);
    if (!dst_host) {
        if (vt_frame) h264vt_frame_free(vt_frame);
        return false;
    }
    p->video_tex_cursor++;

    uint32_t raw_w = vtrk->width > 0 ? vtrk->width : 1920;
    uint32_t raw_h = vtrk->height > 0 ? vtrk->height : 1080;
    uint64_t frame_pts_ms = fallback_pts_ms;

    if (vt_frame != NULL) {
        if (vt_frame->width > 0) raw_w = vt_frame->width;
        if (vt_frame->height > 0) raw_h = vt_frame->height;
        frame_pts_ms = (uint64_t)vt_frame->pts;
        if (!vt_frame->error && vt_frame->pixbuf != NULL &&
            h264vt_nv12_size(raw_w, raw_h) <= p->video_tex_size) {
            h264vt_copy_nv12(vt_frame, dst_host);
        } else {
            uint32_t pitch = h264vt_pitch(raw_w);
            uint32_t aligned_h = h264vt_aligned_height(raw_h);
            size_t y_sz = (size_t)pitch * aligned_h;
            size_t uv_sz = (size_t)pitch * (aligned_h / 2);
            if (y_sz + uv_sz <= p->video_tex_size) {
                memset(dst_host, 16, y_sz);
                memset(dst_host + y_sz, 128, uv_sz);
            }
        }
        h264vt_frame_free(vt_frame);
    } else if (fed_any) {
        uint32_t pitch = h264vt_pitch(raw_w);
        uint32_t aligned_h = h264vt_aligned_height(raw_h);
        size_t y_sz = (size_t)pitch * aligned_h;
        size_t uv_sz = (size_t)pitch * (aligned_h / 2);
        if (y_sz + uv_sz <= p->video_tex_size) {
            memset(dst_host, 16, y_sz);
            memset(dst_host + y_sz, 128, uv_sz);
        }
    } else {
        return false;
    }

    if (ps4_gnm_notify_cpu_write) {
        ps4_gnm_notify_cpu_write(dst_tex, p->video_tex_size);
    }
    p->current_time_ms = frame_pts_ms;

    uint32_t pitch = h264vt_pitch(raw_w);
    uint32_t aligned_w = (raw_w + 15u) & ~15u;
    uint32_t aligned_h = h264vt_aligned_height(raw_h);

    memset(out_info, 0, sizeof(*out_info));
    out_info->p_data = dst_tex;
    out_info->timestamp = frame_pts_ms;
    out_info->details.video.width = aligned_w;
    out_info->details.video.height = aligned_h;
    out_info->details.video.aspect_ratio = vtrk->aspect_ratio > 0.0f
                                               ? vtrk->aspect_ratio
                                               : ((float)raw_w / (float)raw_h);
    memcpy(out_info->details.video.language_code, vtrk->language_code, 4);
    out_info->details.video.framerate = vtrk->framerate > 0 ? vtrk->framerate : 30;
    out_info->details.video.crop_left_offset = 0;
    out_info->details.video.crop_right_offset = pitch >= raw_w ? (pitch - raw_w) : 0;
    out_info->details.video.crop_top_offset = 0;
    out_info->details.video.crop_bottom_offset = aligned_h >= raw_h ? (aligned_h - raw_h) : 0;
    out_info->details.video.pitch = pitch;
    out_info->details.video.luma_bit_depth = 8;
    out_info->details.video.chroma_bit_depth = 8;
    out_info->details.video.video_full_range_flag = 0;

    return true;
}

// ---------------------------------------------------------------------------
// Audio Frame Decoding (MP4 AAC -> AudioToolbox AudioConverter -> PCM S16)
// ---------------------------------------------------------------------------

static OSStatus avp_aac_input_proc(AudioConverterRef inAudioConverter,
                                   UInt32 *ioNumberDataPackets,
                                   AudioBufferList *ioData,
                                   AudioStreamPacketDescription **outDataPacketDescription,
                                   void *inUserData) {
    (void)inAudioConverter;
    AvPlayerInstance *p = (AvPlayerInstance *)inUserData;
    if (!p || !p->aac_curr_pkt || p->aac_curr_pkt_size == 0) {
        *ioNumberDataPackets = 0;
        return -1;
    }

    ioData->mNumberBuffers = 1;
    ioData->mBuffers[0].mNumberChannels =
        p->tracks[p->active_audio_track].channel_count > 0
            ? p->tracks[p->active_audio_track].channel_count
            : 2;
    ioData->mBuffers[0].mDataByteSize = p->aac_curr_pkt_size;
    ioData->mBuffers[0].mData = (void *)(uintptr_t)p->aac_curr_pkt;

    if (outDataPacketDescription) {
        p->aac_pkt_desc.mStartOffset = 0;
        p->aac_pkt_desc.mVariableFramesInPacket = 0;
        p->aac_pkt_desc.mDataByteSize = p->aac_curr_pkt_size;
        *outDataPacketDescription = &p->aac_pkt_desc;
    }

    *ioNumberDataPackets = 1;
    p->aac_curr_pkt = NULL;
    p->aac_curr_pkt_size = 0;
    return noErr;
}

static void avp_ensure_audio_converter(AvPlayerInstance *p, const AvMp4Track *atrk) {
    if (p->audio_converter_ready) {
        return;
    }
    p->audio_converter_ready = true;

    AudioStreamBasicDescription in_fmt;
    memset(&in_fmt, 0, sizeof(in_fmt));
    in_fmt.mSampleRate = (Float64)(atrk->sample_rate > 0 ? atrk->sample_rate : 48000);
    in_fmt.mFormatID = kAudioFormatMPEG4AAC;
    in_fmt.mFramesPerPacket = AVP_AUDIO_SAMPLES_PER_AU;
    in_fmt.mChannelsPerFrame = atrk->channel_count > 0 ? atrk->channel_count : 2;

    AudioStreamBasicDescription out_fmt;
    memset(&out_fmt, 0, sizeof(out_fmt));
    out_fmt.mSampleRate = in_fmt.mSampleRate;
    out_fmt.mFormatID = kAudioFormatLinearPCM;
    out_fmt.mFormatFlags = kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked;
    out_fmt.mBitsPerChannel = 16;
    out_fmt.mChannelsPerFrame = in_fmt.mChannelsPerFrame;
    out_fmt.mBytesPerFrame = out_fmt.mChannelsPerFrame * sizeof(int16_t);
    out_fmt.mFramesPerPacket = 1;
    out_fmt.mBytesPerPacket = out_fmt.mBytesPerFrame;

    OSStatus st = AudioConverterNew(&in_fmt, &out_fmt, &p->audio_converter);
    if (st == noErr && p->audio_converter != NULL && atrk->asc_len > 0) {
        AudioConverterSetProperty(p->audio_converter,
                                  kAudioConverterDecompressionMagicCookie,
                                  (UInt32)atrk->asc_len,
                                  atrk->asc_data);
    }
}

static bool avp_decode_next_audio_frame_locked(GuestContext *ctx, AvPlayerInstance *p,
                                               SceAvPlayerFrameInfo *out_info) {
    if (!p->is_active || p->is_paused || p->active_audio_track < 0 ||
        p->active_audio_track >= (int32_t)p->track_count) {
        return false;
    }

    AvMp4Track *atrk = &p->tracks[p->active_audio_track];
    if (atrk->sample_count == 0) {
        return false;
    }

    if (atrk->sample_cursor >= atrk->sample_count) {
        if (p->is_looping) {
            atrk->sample_cursor = 0;
        } else {
            return false;
        }
    }

    if (p->audio_buf_count == 0) {
        if (!avp_allocate_stream_buffers_locked(ctx, p) || p->audio_buf_count == 0) {
            return false;
        }
    }

    const AvMp4Sample *smp = &atrk->samples[atrk->sample_cursor++];
    uint64_t dst_buf = p->audio_buf_ptrs[p->audio_buf_cursor % p->audio_buf_count];
    void *dst_host = avp_gptr(ctx, dst_buf);
    if (!dst_host) {
        return false;
    }
    p->audio_buf_cursor++;

    uint16_t ch = atrk->channel_count > 0 ? atrk->channel_count : 2;
    uint32_t sr = atrk->sample_rate > 0 ? atrk->sample_rate : 48000;
    uint32_t pcm_bytes = AVP_AUDIO_SAMPLES_PER_AU * (uint32_t)ch * sizeof(int16_t);
    if (pcm_bytes > p->audio_buf_size) {
        pcm_bytes = p->audio_buf_size;
    }

    bool decoded_hw = false;
    if (smp->size > 0) {
        uint8_t *aac_pkt = (uint8_t *)malloc(smp->size);
        if (aac_pkt) {
            if (avplayer_io_read(ctx, p, smp->offset, aac_pkt, smp->size)) {
                avp_ensure_audio_converter(p, atrk);
                if (p->audio_converter != NULL) {
                    p->aac_curr_pkt = aac_pkt;
                    p->aac_curr_pkt_size = smp->size;

                    AudioBufferList out_abl;
                    out_abl.mNumberBuffers = 1;
                    out_abl.mBuffers[0].mNumberChannels = ch;
                    out_abl.mBuffers[0].mDataByteSize = pcm_bytes;
                    out_abl.mBuffers[0].mData = dst_host;

                    UInt32 io_frames = AVP_AUDIO_SAMPLES_PER_AU;
                    OSStatus st = AudioConverterFillComplexBuffer(
                        p->audio_converter, avp_aac_input_proc, p, &io_frames, &out_abl, NULL);
                    if (st == noErr && io_frames > 0) {
                        pcm_bytes = out_abl.mBuffers[0].mDataByteSize;
                        decoded_hw = true;
                    }
                }
            }
            free(aac_pkt);
        }
    }

    if (!decoded_hw) {
        memset(dst_host, 0, pcm_bytes);
    }

    if (p->active_video_track < 0) {
        p->current_time_ms = smp->pts_ms;
    }

    memset(out_info, 0, sizeof(*out_info));
    out_info->p_data = dst_buf;
    out_info->timestamp = smp->pts_ms;
    out_info->details.audio.channel_count = ch;
    out_info->details.audio.sample_rate = sr;
    out_info->details.audio.size = pcm_bytes;
    memcpy(out_info->details.audio.language_code, atrk->language_code, 4);

    return true;
}

// ---------------------------------------------------------------------------
// 1. shim_sceAvPlayerInit (NID: aS66RI0gGgo)
// ---------------------------------------------------------------------------
static int32_t avp_init_internal(const SceAvPlayerInitData *init_data) {
    if (!init_data) {
        return SCE_AVPLAYER_ERROR_INVALID_PARAMS;
    }
    if (init_data->memory_replacement.allocate == 0 ||
        init_data->memory_replacement.deallocate == 0 ||
        init_data->memory_replacement.allocate_texture == 0 ||
        init_data->memory_replacement.deallocate_texture == 0) {
        return SCE_AVPLAYER_ERROR_INVALID_PARAMS;
    }

    pthread_mutex_lock(&g_avplayer_table_mutex);
    avplayer_ensure_table_init();

    AvPlayerInstance *p = NULL;
    for (int i = 0; i < SCE_AVPLAYER_MAX_INSTANCES; i++) {
        if (!g_players[i].allocated) {
            p = &g_players[i];
            p->allocated = true;
            break;
        }
    }
    pthread_mutex_unlock(&g_avplayer_table_mutex);

    if (!p) {
        return SCE_AVPLAYER_ERROR_NO_MEMORY;
    }

    pthread_mutex_lock(&p->mutex);
    p->init_data = *init_data;
    if (p->init_data.num_output_video_framebuffers < 2) {
        p->init_data.num_output_video_framebuffers = AVP_DEFAULT_VIDEO_FB;
    }
    p->has_post_init = false;
    p->track_count = 0;
    p->active_video_track = -1;
    p->active_audio_track = -1;
    p->state = SCE_AVPLAYER_STATE_STOP;
    p->is_active = false;
    p->is_paused = false;
    p->is_looping = false;
    p->current_time_ms = 0;
    p->trick_speed = 100;
    p->sync_mode = SCE_AVPLAYER_AV_SYNC_DEFAULT;
    pthread_mutex_unlock(&p->mutex);

    return p->handle_id;
}

void shim_sceAvPlayerInit(GuestContext *ctx) {
    const SceAvPlayerInitData *init_data = (const SceAvPlayerInitData *)avp_gptr(ctx, ctx->rdi);
    int32_t rc = avp_init_internal(init_data);
    AVP_RETURN((int64_t)rc);
}

// ---------------------------------------------------------------------------
// shim_sceAvPlayerInitEx (NID: jr9CF83l3fc)
// ---------------------------------------------------------------------------
void shim_sceAvPlayerInitEx(GuestContext *ctx) {
    const SceAvPlayerInitDataEx *ex = (const SceAvPlayerInitDataEx *)avp_gptr(ctx, ctx->rdi);
    if (!ex) {
        AVP_RETURN((int64_t)SCE_AVPLAYER_ERROR_INVALID_PARAMS);
    }

    SceAvPlayerInitData conv;
    memset(&conv, 0, sizeof(conv));
    conv.memory_replacement = ex->memory_replacement;
    conv.file_replacement = ex->file_replacement;
    conv.event_replacement = ex->event_replacement;
    conv.default_language = ex->default_language;
    conv.debug_level = ex->debug_level;
    conv.num_output_video_framebuffers = ex->num_output_video_framebuffers;
    conv.auto_start = ex->auto_start;

    int32_t rc = avp_init_internal(&conv);
    AVP_RETURN((int64_t)rc);
}

// ---------------------------------------------------------------------------
// 2. shim_sceAvPlayerPostInit (NID: R31418407aI / HD1YKVU26-M)
// ---------------------------------------------------------------------------
void shim_sceAvPlayerPostInit(GuestContext *ctx) {
    AvPlayerInstance *p = avplayer_lookup(ctx->rdi);
    const SceAvPlayerPostInitData *post = (const SceAvPlayerPostInitData *)avp_gptr(ctx, ctx->rsi);
    if (!p || !post) {
        AVP_RETURN((int64_t)SCE_AVPLAYER_ERROR_INVALID_PARAMS);
    }

    pthread_mutex_lock(&p->mutex);
    p->post_init_data = *post;
    p->has_post_init = true;
    pthread_mutex_unlock(&p->mutex);

    AVP_RETURN(SCE_AVPLAYER_OK);
}

// ---------------------------------------------------------------------------
// 3. shim_sceAvPlayerAddSource (NID: PG956B4722A / KMcEa+rHsIo)
// ---------------------------------------------------------------------------
static int32_t avp_add_source_internal(GuestContext *ctx, AvPlayerInstance *p, const char *uri) {
    if (!p || !uri || uri[0] == '\0') {
        return SCE_AVPLAYER_ERROR_INVALID_PARAMS;
    }

    pthread_mutex_lock(&p->mutex);

    avp_stop_locked(ctx, p);

    snprintf(p->source_uri, sizeof(p->source_uri), "%s", uri);
    if (!avplayer_io_open(ctx, p, uri)) {
        pthread_mutex_unlock(&p->mutex);
        return SCE_AVPLAYER_ERROR_OPERATION_FAILED;
    }

    if (!avp_demux_mp4(ctx, p)) {
        avplayer_io_close(ctx, p);
        pthread_mutex_unlock(&p->mutex);
        return SCE_AVPLAYER_ERROR_OPERATION_FAILED;
    }

    p->state = SCE_AVPLAYER_STATE_READY;
    avplayer_emit_event(ctx, p, SCE_AVPLAYER_STATE_READY);

    if (p->init_data.auto_start) {
        for (uint32_t i = 0; i < p->track_count; i++) {
            if (p->tracks[i].type == SCE_AVPLAYER_VIDEO && p->active_video_track < 0) {
                p->tracks[i].enabled = true;
                p->active_video_track = (int32_t)i;
            } else if (p->tracks[i].type == SCE_AVPLAYER_AUDIO && p->active_audio_track < 0) {
                p->tracks[i].enabled = true;
                p->active_audio_track = (int32_t)i;
            }
        }
        avp_allocate_stream_buffers_locked(ctx, p);
        p->is_active = true;
        p->is_paused = false;
        p->state = SCE_AVPLAYER_STATE_PLAY;
        avplayer_emit_event(ctx, p, SCE_AVPLAYER_STATE_PLAY);
    }

    pthread_mutex_unlock(&p->mutex);
    return SCE_AVPLAYER_OK;
}

void shim_sceAvPlayerAddSource(GuestContext *ctx) {
    AvPlayerInstance *p = avplayer_lookup(ctx->rdi);
    const char *uri = (const char *)avp_gptr(ctx, ctx->rsi);
    int32_t rc = avp_add_source_internal(ctx, p, uri);
    AVP_RETURN((int64_t)rc);
}

void shim_sceAvPlayerAddSourceEx(GuestContext *ctx) {
    AvPlayerInstance *p = avplayer_lookup(ctx->rdi);
    SceAvPlayerUriType uri_type = (SceAvPlayerUriType)ctx->rsi;
    const SceAvPlayerSourceDetails *details = (const SceAvPlayerSourceDetails *)avp_gptr(ctx, ctx->rdx);
    if (!p || uri_type != SCE_AVPLAYER_URI_TYPE_SOURCE || !details || details->uri.name == 0) {
        AVP_RETURN((int64_t)SCE_AVPLAYER_ERROR_INVALID_PARAMS);
    }
    const char *uri = (const char *)avp_gptr(ctx, details->uri.name);
    int32_t rc = avp_add_source_internal(ctx, p, uri);
    AVP_RETURN((int64_t)rc);
}

// ---------------------------------------------------------------------------
// 4. shim_sceAvPlayerStreamCount (NID: V71625415sA / hdTyRzCXQeQ)
// ---------------------------------------------------------------------------
void shim_sceAvPlayerStreamCount(GuestContext *ctx) {
    AvPlayerInstance *p = avplayer_lookup(ctx->rdi);
    if (!p) {
        AVP_RETURN((int64_t)SCE_AVPLAYER_ERROR_INVALID_PARAMS);
    }

    pthread_mutex_lock(&p->mutex);
    int32_t count = (p->track_count > 0) ? (int32_t)p->track_count : SCE_AVPLAYER_ERROR_OPERATION_FAILED;
    pthread_mutex_unlock(&p->mutex);

    AVP_RETURN((int64_t)count);
}

// ---------------------------------------------------------------------------
// 5. shim_sceAvPlayerGetStreamInfo (NID: d59555094aM / d8FcbzfAdQw)
// ---------------------------------------------------------------------------
void shim_sceAvPlayerGetStreamInfo(GuestContext *ctx) {
    AvPlayerInstance *p = avplayer_lookup(ctx->rdi);
    uint32_t stream_id = (uint32_t)ctx->rsi;
    SceAvPlayerStreamInfo *info = (SceAvPlayerStreamInfo *)avp_gptr(ctx, ctx->rdx);
    if (!p || !info) {
        AVP_RETURN((int64_t)SCE_AVPLAYER_ERROR_INVALID_PARAMS);
    }

    pthread_mutex_lock(&p->mutex);
    if (stream_id >= p->track_count || !p->tracks[stream_id].valid) {
        pthread_mutex_unlock(&p->mutex);
        AVP_RETURN((int64_t)SCE_AVPLAYER_ERROR_INVALID_PARAMS);
    }

    const AvMp4Track *trk = &p->tracks[stream_id];
    memset(info, 0, sizeof(*info));
    info->type = (uint32_t)trk->type;
    info->duration = trk->duration_ms;
    info->start_time = trk->start_time_ms;

    if (trk->type == SCE_AVPLAYER_VIDEO) {
        info->details.video.width = trk->width;
        info->details.video.height = trk->height;
        info->details.video.aspect_ratio = trk->aspect_ratio;
        memcpy(info->details.video.language_code, trk->language_code, 4);
    } else if (trk->type == SCE_AVPLAYER_AUDIO) {
        info->details.audio.channel_count = trk->channel_count;
        info->details.audio.sample_rate = trk->sample_rate;
        info->details.audio.size =
            AVP_AUDIO_SAMPLES_PER_AU * (uint32_t)trk->channel_count * sizeof(int16_t);
        memcpy(info->details.audio.language_code, trk->language_code, 4);
    }
    pthread_mutex_unlock(&p->mutex);

    AVP_RETURN(SCE_AVPLAYER_OK);
}

// ---------------------------------------------------------------------------
// 6. shim_sceAvPlayerEnableStream (NID: K06187451bQ / ODJK2sn9w4A)
// ---------------------------------------------------------------------------
void shim_sceAvPlayerEnableStream(GuestContext *ctx) {
    AvPlayerInstance *p = avplayer_lookup(ctx->rdi);
    uint32_t stream_id = (uint32_t)ctx->rsi;
    if (!p) {
        AVP_RETURN((int64_t)SCE_AVPLAYER_ERROR_INVALID_PARAMS);
    }

    pthread_mutex_lock(&p->mutex);
    if (stream_id >= p->track_count || !p->tracks[stream_id].valid) {
        pthread_mutex_unlock(&p->mutex);
        AVP_RETURN((int64_t)SCE_AVPLAYER_ERROR_INVALID_PARAMS);
    }

    AvMp4Track *trk = &p->tracks[stream_id];
    trk->enabled = true;
    if (trk->type == SCE_AVPLAYER_VIDEO) {
        p->active_video_track = (int32_t)stream_id;
    } else if (trk->type == SCE_AVPLAYER_AUDIO) {
        p->active_audio_track = (int32_t)stream_id;
    }
    pthread_mutex_unlock(&p->mutex);

    AVP_RETURN(SCE_AVPLAYER_OK);
}

void shim_sceAvPlayerDisableStream(GuestContext *ctx) {
    AvPlayerInstance *p = avplayer_lookup(ctx->rdi);
    uint32_t stream_id = (uint32_t)ctx->rsi;
    if (!p) {
        AVP_RETURN((int64_t)SCE_AVPLAYER_ERROR_INVALID_PARAMS);
    }

    pthread_mutex_lock(&p->mutex);
    if (stream_id >= p->track_count || !p->tracks[stream_id].valid) {
        pthread_mutex_unlock(&p->mutex);
        AVP_RETURN((int64_t)SCE_AVPLAYER_ERROR_INVALID_PARAMS);
    }
    p->tracks[stream_id].enabled = false;
    if (p->active_video_track == (int32_t)stream_id) {
        p->active_video_track = -1;
    }
    if (p->active_audio_track == (int32_t)stream_id) {
        p->active_audio_track = -1;
    }
    pthread_mutex_unlock(&p->mutex);

    AVP_RETURN(SCE_AVPLAYER_OK);
}

// ---------------------------------------------------------------------------
// 7. shim_sceAvPlayerStart (NID: k81794772hI / ET4Gr-Uu07s)
// ---------------------------------------------------------------------------
void shim_sceAvPlayerStart(GuestContext *ctx) {
    AvPlayerInstance *p = avplayer_lookup(ctx->rdi);
    if (!p) {
        AVP_RETURN((int64_t)SCE_AVPLAYER_ERROR_INVALID_PARAMS);
    }

    pthread_mutex_lock(&p->mutex);
    if (p->track_count == 0) {
        pthread_mutex_unlock(&p->mutex);
        AVP_RETURN((int64_t)SCE_AVPLAYER_ERROR_OPERATION_FAILED);
    }

    if (p->active_video_track < 0 && p->active_audio_track < 0) {
        for (uint32_t i = 0; i < p->track_count; i++) {
            if (p->tracks[i].type == SCE_AVPLAYER_VIDEO && p->active_video_track < 0) {
                p->tracks[i].enabled = true;
                p->active_video_track = (int32_t)i;
            } else if (p->tracks[i].type == SCE_AVPLAYER_AUDIO && p->active_audio_track < 0) {
                p->tracks[i].enabled = true;
                p->active_audio_track = (int32_t)i;
            }
        }
    }

    if (!avp_allocate_stream_buffers_locked(ctx, p)) {
        pthread_mutex_unlock(&p->mutex);
        AVP_RETURN((int64_t)SCE_AVPLAYER_ERROR_NO_MEMORY);
    }

    for (uint32_t i = 0; i < p->track_count; i++) {
        p->tracks[i].sample_cursor = 0;
        p->tracks[i].sent_sps_pps = false;
    }
    if (p->vt_dec) {
        h264vt_reset(p->vt_dec);
    }

    p->current_time_ms = 0;
    p->is_active = true;
    p->is_paused = false;
    p->state = SCE_AVPLAYER_STATE_PLAY;
    avplayer_emit_event(ctx, p, SCE_AVPLAYER_STATE_PLAY);
    pthread_mutex_unlock(&p->mutex);

    AVP_RETURN(SCE_AVPLAYER_OK);
}

// ---------------------------------------------------------------------------
// 8. shim_sceAvPlayerStop (NID: m07190335gM / ZC17w3vB5Lo)
// ---------------------------------------------------------------------------
void shim_sceAvPlayerStop(GuestContext *ctx) {
    AvPlayerInstance *p = avplayer_lookup(ctx->rdi);
    if (!p) {
        AVP_RETURN((int64_t)SCE_AVPLAYER_ERROR_INVALID_PARAMS);
    }

    pthread_mutex_lock(&p->mutex);
    avp_stop_locked(ctx, p);
    avplayer_emit_event(ctx, p, SCE_AVPLAYER_STATE_STOP);
    pthread_mutex_unlock(&p->mutex);

    AVP_RETURN(SCE_AVPLAYER_OK);
}

// ---------------------------------------------------------------------------
// 9. shim_sceAvPlayerClose (NID: P49291243sU / NkJwDzKmIlw)
// ---------------------------------------------------------------------------
void shim_sceAvPlayerClose(GuestContext *ctx) {
    AvPlayerInstance *p = avplayer_lookup(ctx->rdi);
    if (!p) {
        AVP_RETURN((int64_t)SCE_AVPLAYER_ERROR_INVALID_PARAMS);
    }

    pthread_mutex_lock(&p->mutex);
    avp_stop_locked(ctx, p);
    memset(&p->init_data, 0, sizeof(p->init_data));
    memset(&p->post_init_data, 0, sizeof(p->post_init_data));
    p->has_post_init = false;
    pthread_mutex_unlock(&p->mutex);

    pthread_mutex_lock(&g_avplayer_table_mutex);
    p->allocated = false;
    pthread_mutex_unlock(&g_avplayer_table_mutex);

    AVP_RETURN(SCE_AVPLAYER_OK);
}

// ---------------------------------------------------------------------------
// 10. shim_sceAvPlayerPause (NID: i81972914dA / 9y5v+fGN4Wk)
// ---------------------------------------------------------------------------
void shim_sceAvPlayerPause(GuestContext *ctx) {
    AvPlayerInstance *p = avplayer_lookup(ctx->rdi);
    if (!p) {
        AVP_RETURN((int64_t)SCE_AVPLAYER_ERROR_INVALID_PARAMS);
    }

    pthread_mutex_lock(&p->mutex);
    p->is_paused = true;
    p->state = SCE_AVPLAYER_STATE_PAUSE;
    avplayer_emit_event(ctx, p, SCE_AVPLAYER_STATE_PAUSE);
    pthread_mutex_unlock(&p->mutex);

    AVP_RETURN(SCE_AVPLAYER_OK);
}

// ---------------------------------------------------------------------------
// 11. shim_sceAvPlayerResume (NID: x12301577fU / w5moABNwnRY)
// ---------------------------------------------------------------------------
void shim_sceAvPlayerResume(GuestContext *ctx) {
    AvPlayerInstance *p = avplayer_lookup(ctx->rdi);
    if (!p) {
        AVP_RETURN((int64_t)SCE_AVPLAYER_ERROR_INVALID_PARAMS);
    }

    pthread_mutex_lock(&p->mutex);
    p->is_paused = false;
    if (p->is_active) {
        p->state = SCE_AVPLAYER_STATE_PLAY;
        avplayer_emit_event(ctx, p, SCE_AVPLAYER_STATE_PLAY);
    }
    pthread_mutex_unlock(&p->mutex);

    AVP_RETURN(SCE_AVPLAYER_OK);
}

// ---------------------------------------------------------------------------
// 12. shim_sceAvPlayerSetLooping (NID: z54285402pM / OVths0xGfho)
// ---------------------------------------------------------------------------
void shim_sceAvPlayerSetLooping(GuestContext *ctx) {
    AvPlayerInstance *p = avplayer_lookup(ctx->rdi);
    bool loop_flag = (ctx->rsi != 0);
    if (!p) {
        AVP_RETURN((int64_t)SCE_AVPLAYER_ERROR_INVALID_PARAMS);
    }

    pthread_mutex_lock(&p->mutex);
    p->is_looping = loop_flag;
    pthread_mutex_unlock(&p->mutex);

    AVP_RETURN(SCE_AVPLAYER_OK);
}

// ---------------------------------------------------------------------------
// 13. shim_sceAvPlayerIsActive (NID: j64954090eQ / UbQoYawOsfY)
// ---------------------------------------------------------------------------
void shim_sceAvPlayerIsActive(GuestContext *ctx) {
    AvPlayerInstance *p = avplayer_lookup(ctx->rdi);
    if (!p) {
        AVP_RETURN(0);
    }

    pthread_mutex_lock(&p->mutex);
    bool active = p->is_active;
    pthread_mutex_unlock(&p->mutex);

    AVP_RETURN(active ? 1 : 0);
}

// ---------------------------------------------------------------------------
// 14. shim_sceAvPlayerGetVideoDataEx (NID: W48540749tM / JdksQu8pNdQ)
//     and shim_sceAvPlayerGetVideoData (NID: HzLLpc32+0M)
// ---------------------------------------------------------------------------
void shim_sceAvPlayerGetVideoDataEx(GuestContext *ctx) {
    AvPlayerInstance *p = avplayer_lookup(ctx->rdi);
    SceAvPlayerFrameInfoEx *frame_info = (SceAvPlayerFrameInfoEx *)avp_gptr(ctx, ctx->rsi);
    if (!p || !frame_info) {
        AVP_RETURN(0);
    }

    pthread_mutex_lock(&p->mutex);
    bool ok = avp_decode_next_video_frame_locked(ctx, p, frame_info);
    pthread_mutex_unlock(&p->mutex);

    AVP_RETURN(ok ? 1 : 0);
}

void shim_sceAvPlayerGetVideoData(GuestContext *ctx) {
    AvPlayerInstance *p = avplayer_lookup(ctx->rdi);
    SceAvPlayerFrameInfo *frame_info = (SceAvPlayerFrameInfo *)avp_gptr(ctx, ctx->rsi);
    if (!p || !frame_info) {
        AVP_RETURN(0);
    }

    SceAvPlayerFrameInfoEx ex;
    memset(&ex, 0, sizeof(ex));

    pthread_mutex_lock(&p->mutex);
    bool ok = avp_decode_next_video_frame_locked(ctx, p, &ex);
    pthread_mutex_unlock(&p->mutex);

    if (ok) {
        memset(frame_info, 0, sizeof(*frame_info));
        frame_info->p_data = ex.p_data;
        frame_info->timestamp = ex.timestamp;
        frame_info->details.video.width = ex.details.video.width;
        frame_info->details.video.height = ex.details.video.height;
        frame_info->details.video.aspect_ratio = ex.details.video.aspect_ratio;
        memcpy(frame_info->details.video.language_code, ex.details.video.language_code, 4);
    }

    AVP_RETURN(ok ? 1 : 0);
}

// ---------------------------------------------------------------------------
// 15. shim_sceAvPlayerGetAudioData (NID: A72521052xI / Wnp1OVcrZgk)
// ---------------------------------------------------------------------------
void shim_sceAvPlayerGetAudioData(GuestContext *ctx) {
    AvPlayerInstance *p = avplayer_lookup(ctx->rdi);
    SceAvPlayerFrameInfo *frame_info = (SceAvPlayerFrameInfo *)avp_gptr(ctx, ctx->rsi);
    if (!p || !frame_info) {
        AVP_RETURN(0);
    }

    pthread_mutex_lock(&p->mutex);
    bool ok = avp_decode_next_audio_frame_locked(ctx, p, frame_info);
    pthread_mutex_unlock(&p->mutex);

    AVP_RETURN(ok ? 1 : 0);
}

// ---------------------------------------------------------------------------
// 16. shim_sceAvPlayerCurrentTime (NID: u11931214aE / wwM99gjFf1Y)
// ---------------------------------------------------------------------------
void shim_sceAvPlayerCurrentTime(GuestContext *ctx) {
    AvPlayerInstance *p = avplayer_lookup(ctx->rdi);
    if (!p) {
        AVP_RETURN(0);
    }

    pthread_mutex_lock(&p->mutex);
    uint64_t t = p->current_time_ms;
    pthread_mutex_unlock(&p->mutex);

    AVP_RETURN(t);
}

// ---------------------------------------------------------------------------
// Additional Companion libSceAvPlayer Shims
// ---------------------------------------------------------------------------

void shim_sceAvPlayerJumpToTime(GuestContext *ctx) {
    AvPlayerInstance *p = avplayer_lookup(ctx->rdi);
    uint64_t target_ms = ctx->rsi;
    if (!p) {
        AVP_RETURN((int64_t)SCE_AVPLAYER_ERROR_INVALID_PARAMS);
    }

    pthread_mutex_lock(&p->mutex);
    p->current_time_ms = target_ms;
    for (uint32_t i = 0; i < p->track_count; i++) {
        AvMp4Track *trk = &p->tracks[i];
        uint32_t best = 0;
        for (uint32_t s = 0; s < trk->sample_count; s++) {
            if (trk->samples[s].pts_ms <= target_ms) {
                if (trk->type != SCE_AVPLAYER_VIDEO || trk->samples[s].is_sync) {
                    best = s;
                }
            } else {
                break;
            }
        }
        trk->sample_cursor = best;
        trk->sent_sps_pps = false;
    }
    if (p->vt_dec) {
        h264vt_reset(p->vt_dec);
    }
    pthread_mutex_unlock(&p->mutex);

    AVP_RETURN(SCE_AVPLAYER_OK);
}

void shim_sceAvPlayerSetTrickSpeed(GuestContext *ctx) {
    AvPlayerInstance *p = avplayer_lookup(ctx->rdi);
    int32_t speed = (int32_t)ctx->rsi;
    if (!p) {
        AVP_RETURN((int64_t)SCE_AVPLAYER_ERROR_INVALID_PARAMS);
    }

    pthread_mutex_lock(&p->mutex);
    p->trick_speed = speed;
    pthread_mutex_unlock(&p->mutex);

    AVP_RETURN(SCE_AVPLAYER_OK);
}

void shim_sceAvPlayerSetAvSyncMode(GuestContext *ctx) {
    AvPlayerInstance *p = avplayer_lookup(ctx->rdi);
    SceAvPlayerAvSyncMode mode = (SceAvPlayerAvSyncMode)ctx->rsi;
    if (!p) {
        AVP_RETURN((int64_t)SCE_AVPLAYER_ERROR_INVALID_PARAMS);
    }

    pthread_mutex_lock(&p->mutex);
    p->sync_mode = mode;
    pthread_mutex_unlock(&p->mutex);

    AVP_RETURN(SCE_AVPLAYER_OK);
}

void shim_sceAvPlayerChangeStream(GuestContext *ctx) {
    AvPlayerInstance *p = avplayer_lookup(ctx->rdi);
    uint32_t old_id = (uint32_t)ctx->rsi;
    uint32_t new_id = (uint32_t)ctx->rdx;
    if (!p) {
        AVP_RETURN((int64_t)SCE_AVPLAYER_ERROR_INVALID_PARAMS);
    }

    pthread_mutex_lock(&p->mutex);
    if (old_id >= p->track_count || new_id >= p->track_count) {
        pthread_mutex_unlock(&p->mutex);
        AVP_RETURN((int64_t)SCE_AVPLAYER_ERROR_INVALID_PARAMS);
    }
    p->tracks[old_id].enabled = false;
    p->tracks[new_id].enabled = true;
    if (p->tracks[new_id].type == SCE_AVPLAYER_VIDEO) {
        p->active_video_track = (int32_t)new_id;
    } else if (p->tracks[new_id].type == SCE_AVPLAYER_AUDIO) {
        p->active_audio_track = (int32_t)new_id;
    }
    pthread_mutex_unlock(&p->mutex);

    AVP_RETURN(SCE_AVPLAYER_OK);
}

void shim_sceAvPlayerSetLogCallback(GuestContext *ctx) {
    g_avplayer_log_cb = ctx->rdi;
    (void)g_avplayer_log_cb;
    AVP_RETURN(SCE_AVPLAYER_OK);
}

void shim_sceAvPlayerPrintf(GuestContext *ctx) {
    AVP_RETURN(SCE_AVPLAYER_OK);
}

void shim_sceAvPlayerVprintf(GuestContext *ctx) {
    AVP_RETURN(SCE_AVPLAYER_OK);
}
