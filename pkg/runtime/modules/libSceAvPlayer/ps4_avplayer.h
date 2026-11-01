// ps4_avplayer.h — PS4 libSceAvPlayer high-level media player module.
//
// Provides MP4 container demuxing (ftyp/moov/trak/mdia/minf/stbl/stsd/avcC/
// esds/stts/ctts/stsc/stsz/stco/co64), VideoToolbox hardware H.264 decoding
// into guest NV12 texture buffers allocated via SceAvPlayerMemAllocator, and
// AudioToolbox AAC decoding into guest PCM S16 buffers.

#ifndef PS4_AVPLAYER_H
#define PS4_AVPLAYER_H

#include "recomp_runtime.h"
#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// ---------------------------------------------------------------------------
// Error codes (0x806A0000 = libSceAvPlayer facility)
// ---------------------------------------------------------------------------
#define SCE_AVPLAYER_OK                     0
#define SCE_AVPLAYER_ERROR_INVALID_PARAMS   ((int32_t)0x806A0001)
#define SCE_AVPLAYER_ERROR_OPERATION_FAILED ((int32_t)0x806A0002)
#define SCE_AVPLAYER_ERROR_NO_MEMORY        ((int32_t)0x806A0003)
#define SCE_AVPLAYER_ERROR_NOT_SUPPORTED    ((int32_t)0x806A0004)

#define SCE_AVPLAYER_MAX_INSTANCES 8

// ---------------------------------------------------------------------------
// Enumerations (Orbis ABI)
// ---------------------------------------------------------------------------
typedef enum SceAvPlayerStreamType {
    SCE_AVPLAYER_VIDEO      = 0,
    SCE_AVPLAYER_AUDIO      = 1,
    SCE_AVPLAYER_TIMED_TEXT = 2,
    SCE_AVPLAYER_UNKNOWN    = 3,
} SceAvPlayerStreamType;

typedef enum SceAvPlayerUriType {
    SCE_AVPLAYER_URI_TYPE_SOURCE = 0,
} SceAvPlayerUriType;

typedef enum SceAvPlayerSourceType {
    SCE_AVPLAYER_SOURCE_TYPE_UNKNOWN      = 0,
    SCE_AVPLAYER_SOURCE_TYPE_FILE_MP4     = 1,
    SCE_AVPLAYER_SOURCE_TYPE_HLS          = 8,
} SceAvPlayerSourceType;

typedef enum SceAvPlayerState {
    SCE_AVPLAYER_STATE_STOP       = 0x01,
    SCE_AVPLAYER_STATE_READY      = 0x02,
    SCE_AVPLAYER_STATE_PLAY       = 0x03,
    SCE_AVPLAYER_STATE_PAUSE      = 0x04,
    SCE_AVPLAYER_STATE_BUFFERING  = 0x05,
    SCE_AVPLAYER_STATE_TIMED_TEXT = 0x10,
    SCE_AVPLAYER_STATE_WARNING    = 0x20,
    SCE_AVPLAYER_STATE_C0         = 0xFF,
} SceAvPlayerState;

typedef enum SceAvPlayerAvSyncMode {
    SCE_AVPLAYER_AV_SYNC_DEFAULT = 0,
    SCE_AVPLAYER_AV_SYNC_NONE    = 1,
} SceAvPlayerAvSyncMode;

// ---------------------------------------------------------------------------
// Guest callback tables & initialization structs (Orbis x86_64 layout)
// ---------------------------------------------------------------------------

// Size: 40 bytes (0x28)
typedef struct SceAvPlayerMemAllocator {
    uint64_t object_ptr;         // +0x00: void *
    uint64_t allocate;           // +0x08: void *(*)(void *p, uint32_t align, uint32_t size)
    uint64_t deallocate;         // +0x10: void (*)(void *p, void *mem)
    uint64_t allocate_texture;   // +0x18: void *(*)(void *p, uint32_t align, uint32_t size)
    uint64_t deallocate_texture; // +0x20: void (*)(void *p, void *mem)
} SceAvPlayerMemAllocator;

// Size: 40 bytes (0x28)
typedef struct SceAvPlayerFileReplacement {
    uint64_t object_ptr;  // +0x00: void *
    uint64_t open;        // +0x08: int32_t (*)(void *p, const char *name)
    uint64_t close;       // +0x10: int32_t (*)(void *p)
    uint64_t read_offset; // +0x18: int32_t (*)(void *p, uint8_t *buf, uint64_t pos, uint32_t len)
    uint64_t size;        // +0x20: uint64_t (*)(void *p)
} SceAvPlayerFileReplacement;

// Size: 16 bytes (0x10)
typedef struct SceAvPlayerEventReplacement {
    uint64_t object_ptr;     // +0x00: void *
    uint64_t event_callback; // +0x08: void (*)(void *p, int32_t event_id, int32_t source_id, void *event_data)
} SceAvPlayerEventReplacement;

// Size: 120 bytes (0x78)
typedef struct SceAvPlayerInitData {
    SceAvPlayerMemAllocator     memory_replacement;            // +0x00 (40B)
    SceAvPlayerFileReplacement  file_replacement;              // +0x28 (40B)
    SceAvPlayerEventReplacement event_replacement;             // +0x50 (16B)
    int32_t                     debug_level;                   // +0x60
    uint32_t                    base_priority;                 // +0x64
    int32_t                     num_output_video_framebuffers; // +0x68
    uint8_t                     auto_start;                    // +0x6C
    uint8_t                     reserved[3];                   // +0x6D
    uint64_t                    default_language;              // +0x70 (const char *)
} SceAvPlayerInitData;

// Size: 160 bytes (0xA0)
typedef struct SceAvPlayerInitDataEx {
    uint64_t                    this_size;                     // +0x00
    SceAvPlayerMemAllocator     memory_replacement;            // +0x08 (40B)
    SceAvPlayerFileReplacement  file_replacement;              // +0x30 (40B)
    SceAvPlayerEventReplacement event_replacement;             // +0x58 (16B)
    uint64_t                    default_language;              // +0x68
    int32_t                     debug_level;                   // +0x70
    uint32_t                    audio_decoder_priority;        // +0x74
    uint32_t                    audio_decoder_affinity;        // +0x78
    uint32_t                    audio_decoder_stack_size;      // +0x7C
    uint32_t                    demuxer_priority;              // +0x80
    uint32_t                    demuxer_affinity;              // +0x84
    uint32_t                    demuxer_stack_size;            // +0x88
    uint32_t                    video_decoder_priority;        // +0x8C
    uint32_t                    video_decoder_affinity;        // +0x90
    uint32_t                    video_decoder_stack_size;      // +0x94
    int32_t                     num_output_video_framebuffers; // +0x98
    uint8_t                     auto_start;                    // +0x9C
    uint8_t                     reserved[3];                   // +0x9D
} SceAvPlayerInitDataEx;

// Size: 80 bytes (0x50)
typedef struct SceAvPlayerPostInitData {
    uint32_t demux_video_buffer_size; // +0x00
    uint32_t video_decoder_init_type; // +0x04
    uint8_t  video_decoder_params[56];// +0x08
    uint32_t audio_decoder_type;      // +0x40
    uint8_t  audio_decoder_params[12];// +0x44
} SceAvPlayerPostInitData;

// Size: 16 bytes (0x10)
typedef struct SceAvPlayerUri {
    uint64_t name;   // +0x00: const char *
    uint32_t length; // +0x08
    uint32_t pad;    // +0x0C
} SceAvPlayerUri;

// Size: 80 bytes (0x50)
typedef struct SceAvPlayerSourceDetails {
    SceAvPlayerUri uri;           // +0x00 (16B)
    uint8_t        reserved1[64]; // +0x10 (64B)
    uint32_t       source_type;   // +0x50
    uint8_t        reserved2[44]; // +0x54
} SceAvPlayerSourceDetails;

// ---------------------------------------------------------------------------
// Stream & Frame descriptor structs (Orbis ABI)
// ---------------------------------------------------------------------------

// Size: 16 bytes (0x10)
typedef struct SceAvPlayerAudio {
    uint16_t channel_count;    // +0x00
    uint8_t  reserved1[2];     // +0x02
    uint32_t sample_rate;      // +0x04
    uint32_t size;             // +0x08
    uint8_t  language_code[4]; // +0x0C
} SceAvPlayerAudio;

// Size: 16 bytes (0x10)
typedef struct SceAvPlayerVideo {
    uint32_t width;            // +0x00
    uint32_t height;           // +0x04
    float    aspect_ratio;     // +0x08
    uint8_t  language_code[4]; // +0x0C
} SceAvPlayerVideo;

// Size: 16 bytes (0x10)
typedef union SceAvPlayerStreamDetails {
    uint8_t          reserved[16];
    SceAvPlayerAudio audio;
    SceAvPlayerVideo video;
} SceAvPlayerStreamDetails;

// Size: 40 bytes (0x28)
typedef struct SceAvPlayerStreamInfo {
    uint32_t                 type;       // +0x00: SceAvPlayerStreamType
    uint8_t                  reserved[4];// +0x04
    SceAvPlayerStreamDetails details;    // +0x08 (16B)
    uint64_t                 duration;   // +0x18 (ms)
    uint64_t                 start_time; // +0x20 (ms)
} SceAvPlayerStreamInfo;

// Size: 40 bytes (0x28)
typedef struct SceAvPlayerFrameInfo {
    uint64_t                 p_data;     // +0x00: uint8_t *
    uint8_t                  reserved[4];// +0x08
    uint32_t                 pad;        // +0x0C (8-byte alignment for timestamp)
    uint64_t                 timestamp;  // +0x10 (ms)
    SceAvPlayerStreamDetails details;    // +0x18 (16B)
} SceAvPlayerFrameInfo;

// Size: 80 bytes (0x50)
typedef struct SceAvPlayerAudioEx {
    uint16_t channel_count;    // +0x00
    uint8_t  reserved[2];      // +0x02
    uint32_t sample_rate;      // +0x04
    uint32_t size;             // +0x08
    uint8_t  language_code[4]; // +0x0C
    uint8_t  reserved1[64];    // +0x10
} SceAvPlayerAudioEx;

// Size: 80 bytes (0x50)
typedef struct SceAvPlayerVideoEx {
    uint32_t width;                 // +0x00
    uint32_t height;                // +0x04
    float    aspect_ratio;          // +0x08
    uint8_t  language_code[4];      // +0x0C
    uint32_t framerate;             // +0x10
    uint32_t crop_left_offset;      // +0x14
    uint32_t crop_right_offset;     // +0x18
    uint32_t crop_top_offset;       // +0x1C
    uint32_t crop_bottom_offset;    // +0x20
    uint32_t pitch;                 // +0x24
    uint8_t  luma_bit_depth;        // +0x28
    uint8_t  chroma_bit_depth;      // +0x29
    uint8_t  video_full_range_flag; // +0x2A
    uint8_t  reserved1[37];         // +0x2B
} SceAvPlayerVideoEx;

// Size: 80 bytes (0x50)
typedef union SceAvPlayerStreamDetailsEx {
    SceAvPlayerAudioEx audio;
    SceAvPlayerVideoEx video;
    uint8_t            reserved1[80];
} SceAvPlayerStreamDetailsEx;

// Size: 104 bytes (0x68)
typedef struct SceAvPlayerFrameInfoEx {
    uint64_t                   p_data;     // +0x00: void *
    uint8_t                    reserved[4];// +0x08
    uint32_t                   pad;        // +0x0C
    uint64_t                   timestamp;  // +0x10 (ms)
    SceAvPlayerStreamDetailsEx details;    // +0x18 (80B)
} SceAvPlayerFrameInfoEx;

#if !defined(__cplusplus)
_Static_assert(sizeof(SceAvPlayerMemAllocator) == 0x28, "SceAvPlayerMemAllocator size");
_Static_assert(sizeof(SceAvPlayerFileReplacement) == 0x28, "SceAvPlayerFileReplacement size");
_Static_assert(sizeof(SceAvPlayerEventReplacement) == 0x10, "SceAvPlayerEventReplacement size");
_Static_assert(sizeof(SceAvPlayerInitData) == 0x78, "SceAvPlayerInitData size");
_Static_assert(sizeof(SceAvPlayerInitDataEx) == 0xA0, "SceAvPlayerInitDataEx size");
_Static_assert(sizeof(SceAvPlayerPostInitData) == 0x50, "SceAvPlayerPostInitData size");
_Static_assert(sizeof(SceAvPlayerStreamInfo) == 0x28, "SceAvPlayerStreamInfo size");
_Static_assert(sizeof(SceAvPlayerFrameInfo) == 0x28, "SceAvPlayerFrameInfo size");
_Static_assert(sizeof(SceAvPlayerFrameInfoEx) == 0x68, "SceAvPlayerFrameInfoEx size");
#endif

// ---------------------------------------------------------------------------
// Required 16 libSceAvPlayer Shims (plus common companion shims)
// ---------------------------------------------------------------------------
void shim_sceAvPlayerInit(GuestContext *ctx);
void shim_sceAvPlayerInitEx(GuestContext *ctx);
void shim_sceAvPlayerPostInit(GuestContext *ctx);
void shim_sceAvPlayerAddSource(GuestContext *ctx);
void shim_sceAvPlayerAddSourceEx(GuestContext *ctx);
void shim_sceAvPlayerStreamCount(GuestContext *ctx);
void shim_sceAvPlayerGetStreamInfo(GuestContext *ctx);
void shim_sceAvPlayerEnableStream(GuestContext *ctx);
void shim_sceAvPlayerDisableStream(GuestContext *ctx);
void shim_sceAvPlayerStart(GuestContext *ctx);
void shim_sceAvPlayerStop(GuestContext *ctx);
void shim_sceAvPlayerClose(GuestContext *ctx);
void shim_sceAvPlayerPause(GuestContext *ctx);
void shim_sceAvPlayerResume(GuestContext *ctx);
void shim_sceAvPlayerSetLooping(GuestContext *ctx);
void shim_sceAvPlayerIsActive(GuestContext *ctx);
void shim_sceAvPlayerGetVideoData(GuestContext *ctx);
void shim_sceAvPlayerGetVideoDataEx(GuestContext *ctx);
void shim_sceAvPlayerGetAudioData(GuestContext *ctx);
void shim_sceAvPlayerCurrentTime(GuestContext *ctx);
void shim_sceAvPlayerJumpToTime(GuestContext *ctx);
void shim_sceAvPlayerSetTrickSpeed(GuestContext *ctx);
void shim_sceAvPlayerSetAvSyncMode(GuestContext *ctx);
void shim_sceAvPlayerChangeStream(GuestContext *ctx);
void shim_sceAvPlayerSetLogCallback(GuestContext *ctx);
void shim_sceAvPlayerPrintf(GuestContext *ctx);
void shim_sceAvPlayerVprintf(GuestContext *ctx);

#ifdef __cplusplus
}
#endif

#endif // PS4_AVPLAYER_H
