// SPDX-License-Identifier: GPL-2.0-or-later
/*
 * PS4Recomp - native Metal rendering backend for the GNM command processor (see ps4_gnm_draw.h).
 *
 * The draw / dispatch logic follows shadPS4's Vulkan renderer:
 *   src/video_core/renderer_vulkan/vk_rasterizer.cpp      (Draw, DispatchDirect, BindResources,
 *                                                          BindBuffers, BindTextures,
 *                                                          BeginRendering, FilterDraw,
 *                                                          UpdateViewportScissorState)
 *   src/video_core/renderer_vulkan/vk_pipeline_cache.cpp  (shader permutations, runtime info)
 *   src/video_core/renderer_vulkan/vk_graphics_pipeline.cpp (vertex inputs, pipeline state)
 *   src/video_core/renderer_vulkan/liverpool_to_vk.cpp    (ColorBufferClearValue, quad lists)
 *   src/video_core/amdgpu/regs.cpp                        (Regs::SetDefaults)
 * SPDX-FileCopyrightText: Copyright 2024-2026 shadPS4 Emulator Project
 * SPDX-License-Identifier: GPL-2.0-or-later
 *
 * Environment:
 *   PS4_GNM_METAL_DRAW=0     disable GPU work (fences/interrupts still produced)
 *   PS4_GNM_TRACE=<n>        log every draw/dispatch of the first n submits that contain work
 *   PS4_GNM_MSL_DUMP=<dir>   write the generated MSL of every compiled shader
 *   PS4_GNM_GPU_TIMEOUT=<ms> command buffer watchdog (default 4000)
 */

#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <ImageIO/ImageIO.h>
#import <CoreGraphics/CoreGraphics.h>

#include <dispatch/dispatch.h>
#include <dirent.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <pthread.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>

#include <algorithm>
#include <atomic>
#include <deque>
#include <memory>
#include <condition_variable>
#include <deque>
#include <mutex>
#include <thread>
#include <string>
#include <unordered_map>
#include <unordered_set>
#include <vector>
#include <unistd.h>

#include <set>

#include "gcn_recompiler.h"
#include "ps4_gnm_draw.h"
#include "ps4_gnm_guest_window.h"
#include "ps4_gnm_membudget.h"
#include "ps4_gnm_resources.h"
#include "ps4_gnm_shader_cache.h"
#include "ps4_gnm_pipeline_archive.h"
#include "ps4_gnm_library_store.h"
#include "ps4_gnm_kernel_compile.h"
#include "ps4_metal_screen.h"
#include "ps4_hitch.h"

extern "C" void* ps4_metal_screen_acquire_frame(int width, int height);
extern "C" int ps4_metal_screen_encode_present(void* command_buffer, void* texture);
extern "C" uint64_t ps4_gnm_take_cp_ns(void);
extern "C" void ps4_gnm_print_sync_stats(void);
extern "C" void ps4_fiber_print_stats(int frames);
extern "C" void ps4_sync_print_stats(int frames);

// Debug request from PS4_PAD_CTL: bit 0 = dump render targets of the next present, bit 1 =
// dump the color target after every draw of the next present (needs PS4_SCREENSHOT_DIR),
// bit 2 = trace the work of the next present ([gnm-trace] lines).
extern "C" volatile int g_ps4_gnm_dump_request;
volatile int g_ps4_gnm_dump_request;

extern "C" void ps4_host_quit(int code) __attribute__((noreturn));

namespace ps4draw {
using namespace ps4gnm;

namespace {

// =====================================================================================
// Logging (rate limited per key: first 8 occurrences, then at powers of two)
// =====================================================================================
std::mutex g_log_mu;
std::unordered_map<std::string, uint64_t> g_log_counts;

void RLog(const char* key, const char* fmt, ...) __attribute__((format(printf, 2, 3)));
void RLog(const char* key, const char* fmt, ...) {
    uint64_t n;
    {
        std::lock_guard<std::mutex> lk(g_log_mu);
        n = ++g_log_counts[key];
    }
    if (n > 8 && (n & (n - 1)) != 0) return;
    char buf[2048];
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(buf, sizeof(buf), fmt, ap);
    va_end(ap);
    if (n > 8)
        fprintf(stderr, "[gnm-draw] %s (x%llu)\n", buf, (unsigned long long)n);
    else
        fprintf(stderr, "[gnm-draw] %s\n", buf);
}

// The registers a draw / dispatch reads after it is handed to the encoder thread: the CP keeps
// changing the live register file meanwhile. Reads outside these ranges are logged.
struct RegSnapRange {
    uint16_t lo, hi;
};
constexpr RegSnapRange kRegSnapRanges[] = {{0xA000, 0xA020}, {0xA100, 0xA190}, {0xA200, 0xA210}, {0xA2D0, 0xA310}};
// index in RegSnap::a of the context registers 0xA000..0xA30F (0xFFFF: not captured)
struct RegSnapIndex {
    uint16_t at[0x310];
    constexpr RegSnapIndex() : at() {
        for (uint32_t i = 0; i < 0x310; ++i) at[i] = 0xFFFF;
        uint32_t o = 0;
        for (const RegSnapRange& g : kRegSnapRanges) {
            for (uint32_t r = g.lo; r < g.hi; ++r) at[r - 0xA000] = (uint16_t)(o + r - g.lo);
            o += g.hi - g.lo;
        }
    }
};
constexpr RegSnapIndex kRegSnapIndex{};

struct RegSnap {
    using Range = RegSnapRange;
    static constexpr const auto& kRanges = kRegSnapRanges;
    static constexpr uint32_t kSize = 0x20 + 0x90 + 0x10 + 0x40;
    uint32_t a[kSize];
    uint32_t cs_num_thread[3]; // COMPUTE_NUM_THREAD_X/Y/Z
    void Capture(const uint32_t* r) {
        uint32_t o = 0;
        for (const Range& g : kRanges) {
            memcpy(a + o, r + g.lo, (g.hi - g.lo) * 4u);
            o += g.hi - g.lo;
        }
        memcpy(cs_num_thread, r + 0x2E07, sizeof(cs_num_thread));
    }
    uint32_t operator[](uint32_t reg) const {
        if (reg - 0xA000u < 0x310u) {
            const uint16_t o = kRegSnapIndex.at[reg - 0xA000u];
            if (o != 0xFFFF) return a[o];
        }
        if (reg >= 0x2E07 && reg < 0x2E0A) return cs_num_thread[reg - 0x2E07];
        RLog("regsnap", "register 0x%x read after the draw left the CP (not in the snapshot); read as 0", reg);
        return 0;
    }
};

// =====================================================================================
// Encoder thread. The CP thread parses the command stream and prepares draws and dispatches
// (render state, shader lookup, resource table walks: work that only reads registers and guest
// memory); everything that touches Metal or the texture cache runs here, in stream order.
// Operations whose result the CP or the guest observes (waits, CPU writes of guest memory,
// presents) wait for the queue to drain. PS4_GNM_SYNC_ENCODE=1 runs everything inline.
// =====================================================================================
namespace encq {
std::mutex mu;
std::condition_variable cv_work, cv_idle;
std::vector<std::function<void()>> q;
bool busy = false, sleeping = false;
std::atomic<uint64_t> pushed{0}, done{0}, busy_ns{0};
std::atomic<bool> async{false};
thread_local bool t_worker = false;
constexpr size_t kMaxQueued = 16384;

inline bool Inline() {
    return t_worker || !async.load(std::memory_order_relaxed);
}

void Worker() {
    t_worker = true;
    pthread_setname_np("GNM Encoder");
    // on the frame's critical path: keep it off the efficiency cores
    pthread_set_qos_class_self_np(QOS_CLASS_USER_INTERACTIVE, 0);
    std::vector<std::function<void()>> batch; // swapped with q: both keep their capacity
    for (;;) {
        batch.clear();
        {
            std::unique_lock<std::mutex> lk(mu);
            while (q.empty()) {
                sleeping = true;
                cv_work.wait(lk);
                sleeping = false;
            }
            batch.swap(q);
            busy = true;
        }
        cv_idle.notify_all(); // room for producers waiting on kMaxQueued
        const double t0 = CFAbsoluteTimeGetCurrent();
        size_t n = 0;
        while (n < batch.size()) {
            @autoreleasepool {
                for (size_t k = 0; k < 64 && n < batch.size(); ++k, ++n) {
                    batch[n]();
                    batch[n] = nullptr;
                }
            }
        }
        busy_ns.fetch_add((uint64_t)((CFAbsoluteTimeGetCurrent() - t0) * 1e9), std::memory_order_relaxed);
        {
            std::lock_guard<std::mutex> lk(mu);
            done.fetch_add(n, std::memory_order_release);
            if (q.empty()) busy = false;
        }
        cv_idle.notify_all();
    }
}

void Start() {
    if (getenv("PS4_GNM_SYNC_ENCODE")) {
        fprintf(stderr, "[gnm-draw] encoder thread disabled (PS4_GNM_SYNC_ENCODE)\n");
        return;
    }
    std::thread th(Worker);
    // the encoder is on the frame's critical path like the CP thread
    th.detach();
    async.store(true, std::memory_order_release);
    fprintf(stderr, "[gnm-draw] encoder thread started\n");
}

void Defer(std::function<void()> f) {
    if (Inline()) {
        f();
        return;
    }
    bool wake;
    {
        std::unique_lock<std::mutex> lk(mu);
        if (q.size() >= kMaxQueued) cv_idle.wait(lk, [] { return q.size() < kMaxQueued; });
        q.push_back(std::move(f));
        pushed.fetch_add(1, std::memory_order_relaxed);
        wake = sleeping;
    }
    if (wake) cv_work.notify_one(); // a running worker takes the new work with its next batch
}

// Waits until everything queued so far has run.
void Sync() {
    if (Inline()) return;
    std::unique_lock<std::mutex> lk(mu);
    cv_idle.wait(lk, [] { return q.empty() && !busy; });
}

// Runs f on the encoder after the queued work and returns once it ran.
void Run(const std::function<void()>& f) {
    if (Inline()) {
        f();
        return;
    }
    Defer(f);
    Sync();
}

// Work handed to the encoder that has not run yet.
bool Pending() {
    return !Inline() && pushed.load(std::memory_order_relaxed) != done.load(std::memory_order_acquire);
}
} // namespace encq

inline uint64_t Fnv(const void* data, size_t n, uint64_t h = 1469598103934665603ull) {
    const uint8_t* p = (const uint8_t*)data;
    for (size_t i = 0; i < n; ++i) {
        h ^= p[i];
        h *= 1099511628211ull;
    }
    return h;
}

inline float AsF(uint32_t v) {
    float f;
    memcpy(&f, &v, 4);
    return f;
}

// =====================================================================================
// Global state
// =====================================================================================
struct UploadArena {
    static const size_t kChunk = 4u << 20;
    struct Chunk {
        id<MTLBuffer> buf;
        size_t used;
    };
    std::vector<Chunk> cur;
    std::mutex free_mu;
    std::vector<id<MTLBuffer>> free_list;

    bool Alloc(id<MTLDevice> dev, size_t size, size_t align, __strong id<MTLBuffer>* out, size_t* off,
               void** ptr) {
        if (size == 0) size = 4;
        if (!cur.empty()) {
            Chunk& c = cur.back();
            size_t o = (c.used + align - 1) & ~(align - 1);
            if (o + size <= c.buf.length) {
                c.used = o + size;
                *out = c.buf;
                *off = o;
                *ptr = (uint8_t*)c.buf.contents + o;
                return true;
            }
        }
        id<MTLBuffer> b = nil;
        if (size <= kChunk) {
            std::lock_guard<std::mutex> lk(free_mu);
            if (!free_list.empty()) {
                b = free_list.back();
                free_list.pop_back();
            }
        }
        if (!b) b = [dev newBufferWithLength:std::max(size, kChunk) options:MTLResourceStorageModeShared];
        if (!b) return false;
        cur.push_back({b, size});
        *out = b;
        *off = 0;
        *ptr = b.contents;
        return true;
    }
};

struct Shader {
    gcn_shader* sh = nullptr;
    gcn_shader_info info{};
    uint32_t hw = 0;
    uint64_t code_addr = 0;
    uint64_t uid = 0;
    uint64_t msl_hash = 0;    // hash of the final MSL (stable across sessions)
    ps4gnm_lib_store::Key lib_key; // the MSL's key in the library store (lib_key.h1 == msl_hash)
    uint32_t lib_stage = 0;        // ps4gnm_lib_store::Stage of the function, 0: not stored
    bool from_store = false;       // fn was loaded from the library store
    id<MTLFunction> fn = nil;
    bool pending = false;     // Metal library still compiling (fn not yet available)
    // Compute kernel compiling in the background (fn stays nil): the encoder waits for it at the
    // shader's first dispatch (ps4_gnm_kernel_compile.h)
    std::shared_ptr<ps4gnm_kernels::Job> kjob;
    uint64_t fail_key = 0;    // permutation key recorded in shader_fail if compilation fails
    std::vector<gcn_buffer_binding> bufs;
    std::vector<gcn_image_binding> imgs;
    std::vector<gcn_sampler_binding> samps;
    std::vector<gcn_vertex_attrib> attrs;
};

struct PassKey {
    __unsafe_unretained id<MTLTexture> color[8] = {};
    __unsafe_unretained id<MTLTexture> depth = nil;
    uint32_t depth_slice = 0; // DB_DEPTH_VIEW.SLICE_START
    uint32_t width = 0, height = 0;
    uint32_t sample_locs = 0; // PA_SC_AA_SAMPLE_LOCS_PIXEL_X0Y0_0 of multisampled passes
    bool operator==(const PassKey& o) const {
        for (int i = 0; i < 8; ++i)
            if (color[i] != o.color[i]) return false;
        return depth == o.depth && depth_slice == o.depth_slice && width == o.width && height == o.height &&
               sample_locs == o.sample_locs;
    }
};

struct MetaState {
    bool cleared = false;
    uint64_t cleared_seq = 0; // command buffer the clear (CMASK/HTILE fill) belongs to
};

// Compact record of the work encoded into a command buffer, printed when it fails or hangs
// (formatting text for every draw would cost more than encoding the draw).
struct WorkRec {
    const char* what = "";
    uint64_t a = 0, b = 0;     // draw: VS / PS address; dispatch: CS address
    uint32_t n = 0, inst = 0;  // draw: count / instances; dispatch: groups x / y
    uint32_t extra = 0;        // dispatch: groups z
    bool dispatch = false;
};
struct WorkLog {
    // The most recent records are kept: 64, or 512 with the debug options that print whole
    // command buffers (PS4_GNM_ENCODER_STATUS, PS4_GNM_HANG_REPORT_MS, PS4_GNM_COMMIT_EACH).
    static constexpr size_t kAll = ~size_t(0); // Print(): every record kept
    static size_t Capacity() {
        static const size_t cap = getenv("PS4_GNM_ENCODER_STATUS") || getenv("PS4_GNM_HANG_REPORT_MS") ||
                                          getenv("PS4_GNM_COMMIT_EACH") ? 512 : 64;
        return cap;
    }
    std::vector<WorkRec> rec = std::vector<WorkRec>(Capacity());
    uint64_t count = 0;
    void Add(const WorkRec& r) { rec[count++ % rec.size()] = r; }
    void Print(const char* prefix, size_t last) const {
        const uint64_t kCap = rec.size();
        const uint64_t first = count > std::min<uint64_t>(last, kCap) ? count - std::min<uint64_t>(last, kCap) : 0;
        for (uint64_t i = first; i < count; ++i) {
            const WorkRec& r = rec[i % kCap];
            if (r.dispatch)
                fprintf(stderr, "[gnm-draw]   %s[%llu]: %s dispatch CS=0x%llx groups=%ux%ux%u\n", prefix,
                        (unsigned long long)i, r.what, (unsigned long long)r.a, r.n, r.inst, r.extra);
            else if (r.a)
                fprintf(stderr, "[gnm-draw]   %s[%llu]: %s VS=0x%llx PS=0x%llx n=%u inst=%u\n", prefix,
                        (unsigned long long)i, r.what, (unsigned long long)r.a, (unsigned long long)r.b, r.n, r.inst);
            else
                fprintf(stderr, "[gnm-draw]   %s[%llu]: %s\n", prefix, (unsigned long long)i, r.what);
        }
    }
};

// Guest memory written by GPU work; epochs order the writes against GPU texture uploads.
using GpuWrite = TextureCache::WriteRange;

// A no-copy MTLBuffer over guest windows and the time it was last bound (g_mem.tick).
struct GuestWin {
    id<MTLBuffer> buf = nil;
    uint64_t last_use = 0;
};

struct State {
    bool init_tried = false;
    bool enabled = false;
    bool hung = false;
    GuestContext* ctx = nullptr;
    id<MTLDevice> dev = nil;
    id<MTLCommandQueue> queue = nil;
    TextureCache* tex = nullptr;
    gcn_profile profile{};
    gcn_msl_options msl{};
    id<MTLBuffer> dummy = nil;
    id<MTLBuffer> gds_buf = nil;
    uint8_t* gds = nullptr;

    // recording
    id<MTLCommandBuffer> cmd = nil;
    id<MTLCommandBuffer> upload_cmd = nil; // GPU texture uploads for the work in cmd (committed first)
    id<MTLRenderCommandEncoder> renc = nil;
    id<MTLComputeCommandEncoder> cenc = nil;
    PassKey pass;
    id<MTLTexture> pass_hold[9]; // keeps the textures of `pass` alive
    std::vector<id<MTLCommandBuffer>> inflight;
    std::shared_ptr<WorkLog> cmd_log;
    std::vector<uint32_t> flat_scratch[3]; // per-stage flattened user data (VS, PS, CS)
    // flat_scratch[i] already holds this draw's flattened user data, built by GetShader with
    // the SRT program of the shader recorded here (all permutations of a program share it)
    const Shader* flat_from[3] = {};
    bool pending = false;
    UploadArena arena;
    std::vector<GpuWrite> gpu_written; // guest ranges written by work in `cmd`
    uint32_t gpu_written_slot[64] = {}; // NoteGpuWrite: index of a range in gpu_written, by hash
    // ranges written by committed command buffers, by sequence number (dropped once completed)
    std::deque<std::pair<uint64_t, std::vector<GpuWrite>>> inflight_written;
    uint64_t write_epoch = 0; // last epoch handed out by NoteGpuWrite
    // first write epoch of the work recorded since the last Commit (S.cmd): copies in upload_cmd
    // run before all of it, so they are current only for writes with smaller epochs
    uint64_t cmd_start_epoch = 1;
    // GPU texture uploads: detile maps and staging buffers per surface layout
    id<MTLComputePipelineState> detile_pso = nil;
    std::unordered_map<uint64_t, id<MTLBuffer>> detile_maps;
    std::unordered_map<uint32_t, id<MTLBuffer>> detile_staging; // by size class (log2 of the length)

    // caches
    std::unordered_map<uint64_t, std::vector<Shader*>> shaders;
    std::unordered_set<uint64_t> shader_fail;
    std::unordered_map<uint64_t, id<MTLLibrary>> libs;
    // Asynchronous shader/pipeline compilation: Metal completion handlers push results here and
    // the submitting thread applies them (DrainAsyncCompiles) before each draw/dispatch.
    struct AsyncLib { uint64_t mh; id<MTLLibrary> lib; NSString* err; };
    // retry_vs/retry_ps: the pipeline failed with a function from the library store; the encoder
    // compiles that shader's MSL and builds the pipeline again instead of keeping the failure.
    struct AsyncPso {
        std::string key;
        id<MTLRenderPipelineState> pso;
        NSString* err;
        const Shader* retry_vs = nullptr;
        const Shader* retry_ps = nullptr;
    };
    std::mutex async_mu;
    std::vector<AsyncLib> async_libs_done;
    std::vector<AsyncPso> async_psos_done;
    // results waiting in async_*_done (checked without taking async_mu on every draw)
    std::atomic<uint32_t> async_shaders_ready{0}, async_psos_ready{0};
    std::unordered_map<uint64_t, std::vector<Shader*>> libs_pending;   // mh -> waiting shaders
    std::unordered_set<std::string> psos_pending;
    struct GcnJob {
        gcn_hw_stage hw;
        gcn_sw_stage sw;
        gcn_runtime_info rt;
        uint64_t code_addr = 0, key = 0, fail_key = 0, pend_key = 0;
        uint32_t ud[16];
        gcn_shader* sh = nullptr;
        std::string err;
        int status = 0;
        bool cache_store = false; // store the translation in the on-disk cache under cache_key
        ps4gnm_shader_cache::Key cache_key;
    };
    std::vector<std::shared_ptr<GcnJob>> async_gcn_done;
    std::unordered_set<uint64_t> gcn_pending;
    Shader pending_shader; // returned while a translation is in flight (fn == nil)
    // Shaders made ready ahead of time by the warm-up threads, by MSL hash: functions loaded from
    // the library store (fn) or libraries compiled from the on-disk MSL cache (lib). h2 is the
    // second hash of the store key (0 for a compiled library, whose source hash is h1 itself).
    struct Prewarmed {
        uint64_t h2 = 0;
        id<MTLLibrary> lib = nil;
        id<MTLFunction> fn = nil;
    };
    std::unordered_map<uint64_t, Prewarmed> prewarmed;
    // MSL hashes the CP thread resolved without the warm-up: the warm-up skips them (async_mu).
    std::unordered_set<uint64_t> prewarm_taken;
    // Functions loaded from the library store, by MSL hash (CP thread).
    std::unordered_map<uint64_t, id<MTLFunction>> store_fns;
    // Functions compiled from MSL for shaders whose stored function failed in a pipeline, by MSL
    // hash (encoder thread only: pipelines are built there; see PipelineFn).
    std::unordered_map<uint64_t, id<MTLFunction>> fallback_fns;
    // Pipelines built in earlier sessions (hashes in <cache>/pipelines.bin): Metal's own
    // pipeline cache makes rebuilding them cheap, so they are built synchronously.
    std::unordered_set<uint64_t> known_psos;
    std::string pso_list_path;
    std::unordered_set<uint64_t> msl_on_disk; // hashes of <msl_cache_dir>/<hash>.metal (CP thread)
    std::string msl_cache_dir;
    bool async_compile = true;
    std::unordered_map<std::string, id<MTLRenderPipelineState>> gfx_pipes;
    std::unordered_map<uint64_t, id<MTLComputePipelineState>> cs_pipes;
    // compute kernels compiled in the background (null: on the CP thread, PS4_GNM_SYNC_KERNELS=1)
    std::unique_ptr<ps4gnm_kernels::Compiler> kernels;
    // kernels of dispatches handed to the encoder in the current command stream run that were
    // still compiling (CP thread; WaitKernelCompiles)
    std::vector<std::shared_ptr<ps4gnm_kernels::Job>> kernels_open;
    std::unordered_map<uint64_t, id<MTLDepthStencilState>> ds_states;
    std::unordered_map<uint64_t, id<MTLSamplerState>> samplers;
    std::unordered_map<uint64_t, GuestWin> guest_bufs; // key: window base | windows << 48
    std::unordered_map<uint64_t, MetaState> meta; // cmask / htile address -> state
    uint64_t next_uid = 1;
    // textures with mip chains whose levels were rendered as separate render targets
    struct MipChain {
        id<MTLTexture> tex;
        uint64_t built_submit = ~0ull;
    };
    std::unordered_map<uint64_t, MipChain> mip_chains; // key: hash of T# identity
    uint32_t cb_extent[8] = {};
    uint32_t db_extent = 0;

    // depth surfaces read as color (R32F companions) and depth-copy tracking. The maps keyed by a
    // texture pointer here (depth_comp, depth_version, depth_last_write, eqaa_twin, eqaa_orig) are
    // erased by ForgetTexture when the texture cache drops the texture: add any new one there.
    struct Companion {
        id<MTLTexture> tex;
        uint64_t version = ~0ull;
    };
    std::unordered_map<void*, Companion> depth_comp;
    std::unordered_map<void*, uint64_t> depth_version;
    // order of the last depth write per depth texture (for copies between sample counts)
    // EQAA emulation: multisampled stand-ins ("twins") of single-sample targets, and the twins
    // of the open render pass that are written back when it ends
    std::unordered_map<void*, id<MTLTexture>> eqaa_twin;     // target -> twin
    std::unordered_map<void*, id<MTLTexture>> eqaa_orig;     // twin -> target
    std::vector<std::pair<id<MTLTexture>, id<MTLTexture>>> eqaa_open; // (twin, target)
    std::unordered_map<uint64_t, id<MTLRenderPipelineState>> eqaa_psos;
    // storage images bound by the current dispatch (address, texture)
    std::vector<std::pair<uint64_t, id<MTLTexture>>> storage_bound;
    std::unordered_map<uint32_t, id<MTLRenderPipelineState>> depth_from_color_psos;
    std::unordered_map<void*, uint64_t> depth_last_write;
    uint64_t depth_write_clock = 0;
    std::unordered_map<uint64_t, id<MTLRenderPipelineState>> depth_copy_psos;
    id<MTLDepthStencilState> depth_copy_dss = nil;
    id<MTLLibrary> util_lib = nil;
    std::unordered_map<uint64_t, uint64_t> stencil_to_z;
    id<MTLRenderPipelineState> depth2color_pso = nil;

    // present
    id<MTLRenderPipelineState> present_pso = nil;
    id<MTLTexture> present_tex = nil;

    // stats
    uint64_t submit_idx = 0;
    uint64_t present_idx = 0;    // presents so far
    bool trace_by_present = false;
    uint64_t trace_start = 0, trace_count = 0;
    std::unordered_map<void*, std::shared_ptr<WorkLog>> inflight_logs;
    uint64_t n_draws = 0, n_dispatches = 0, n_cmdbufs = 0;
    std::atomic<uint64_t> n_skipped{0}; // both threads (see EncodeQueue)
    double gpu_timeout_ms = 4000;
    uint64_t n_waits = 0, n_commits = 0;
    // GPU-timeline fence actions
    std::mutex fence_mu;
    std::recursive_mutex fence_run_mu;
    std::deque<std::pair<uint64_t, std::function<void()>>> fence_q;
    uint64_t committed_seq = 0;            // guarded by fence_mu
    uint64_t completed_seq = 0;            // guarded by fence_mu
    double wait_ms = 0;
    std::atomic<uint64_t> gpu_ns{0}; // GPU busy time (union of command buffer execution intervals)
    std::mutex gpu_time_mu;
    double gpu_last_end = 0;
    uint64_t n_passes = 0, n_depth_loads = 0, n_cencs = 0, n_cbarriers = 0, n_cdisp = 0; // per stats period
    double screen_ms = 0; // time spent handing frames to the window (drawable acquisition)
};

State S;

// Frame pacing diagnostics: CPU time spent in operations that can stall a frame,
// accumulated between presents and reported for long frames (hitches).
struct HitchStats {
    double shader_ms = 0, gcn_ms = 0, mtl_ms = 0, pso_ms = 0, upload_ms = 0, wait_ms = 0;
    double lookup_ms = 0, fn_ms = 0; // translation cache lookup; MTLFunction creation
    // blocked on background kernel compiles: the CP at the end of a submission, the encoder at a
    // dispatch (both may wait for the same compile at the same time)
    double kernel_wait_ms = 0, kernel_enc_wait_ms = 0;
    uint32_t kernel_waits = 0;
    uint32_t shaders = 0, psos = 0, uploads = 0, gpu_uploads = 0, pending_draws = 0;
};
HitchStats g_hitch;

// Session totals of Metal compile work by where it ran (printed with the frame-time lines):
// synchronous work runs on the CP or encoder thread inside a frame and is what hitches.
struct CompileCounter {
    std::atomic<uint64_t> n{0}, us{0}, max_us{0}, over8{0};
    void Add(double ms) {
        const uint64_t u = (uint64_t)(ms * 1000.0);
        n.fetch_add(1, std::memory_order_relaxed);
        us.fetch_add(u, std::memory_order_relaxed);
        if (u > 8000) over8.fetch_add(1, std::memory_order_relaxed);
        for (uint64_t m = max_us.load(std::memory_order_relaxed);
             u > m && !max_us.compare_exchange_weak(m, u, std::memory_order_relaxed);) {
        }
    }
};
struct CompileStats {
    CompileCounter lib_sync, lib_store, pso_sync, cpso_sync;
    // dispatches whose kernel was still compiling when the encoder reached them (time blocked)
    CompileCounter kernel_wait;
    // command stream runs whose end waited for kernels still compiling (time blocked, CP thread)
    CompileCounter kernel_cp_wait;
    std::atomic<uint64_t> kernel_ready{0}; // first dispatches whose kernel was compiled in time
    std::atomic<uint64_t> lib_async{0}, lib_prewarmed{0}, pso_async{0}, store_fallbacks{0};
};
CompileStats g_compile;

void PrintCompileStats() {
    auto c = [](const CompileCounter& k, char* out, size_t n) {
        snprintf(out, n, "%llu (%.0f ms, max %.1f ms, %llu over 8 ms)", (unsigned long long)k.n.load(),
                 k.us.load() / 1000.0, k.max_us.load() / 1000.0, (unsigned long long)k.over8.load());
    };
    char a[96], b[96], d[96], l[96];
    c(g_compile.lib_sync, a, sizeof(a));
    c(g_compile.lib_store, l, sizeof(l));
    c(g_compile.pso_sync, b, sizeof(b));
    c(g_compile.cpso_sync, d, sizeof(d));
    fprintf(stderr, "[gnm-compile] session: libraries in frame %s, loaded from the store in frame %s, in background %llu, "
                    "from warm-up %llu; render pipelines in frame %s, in background %llu; compute pipelines in frame %s; "
                    "stored libraries replaced after a pipeline failure %llu\n",
            a, l, (unsigned long long)g_compile.lib_async.load(), (unsigned long long)g_compile.lib_prewarmed.load(), b,
            (unsigned long long)g_compile.pso_async.load(), d, (unsigned long long)g_compile.store_fallbacks.load());
    if (S.kernels) {
        char w[96], cw[96];
        c(g_compile.kernel_wait, w, sizeof(w));
        c(g_compile.kernel_cp_wait, cw, sizeof(cw));
        using KC = ps4gnm_kernels::Compiler;
        fprintf(stderr, "[gnm-compile] session: compute kernels compiled in the background %llu (%.0f ms, %llu failed), "
                        "%llu ready at their first dispatch, waited for by the encoder %s, by the CP at the end of a "
                        "submission %s; draw shaders through the same queue %llu (%.0f ms, %llu failed); %llu compiles "
                        "at once at most\n",
                (unsigned long long)S.kernels->Started(KC::kDispatch), S.kernels->CompileMs(KC::kDispatch),
                (unsigned long long)S.kernels->Failed(KC::kDispatch), (unsigned long long)g_compile.kernel_ready.load(), w,
                cw, (unsigned long long)S.kernels->Started(KC::kDraw), S.kernels->CompileMs(KC::kDraw),
                (unsigned long long)S.kernels->Failed(KC::kDraw), (unsigned long long)S.kernels->PeakRunning());
    }
    ps4gnm_lib_store::PrintStats();
}

bool g_trace_reads = false;
bool ReadGuest(void* c, uint64_t addr, void* dst, uint64_t size) {
    GuestContext* ctx = (GuestContext*)c;
    if (!ctx || !ctx->mem_base || addr == 0 || addr >= ctx->mem_size || size > ctx->mem_size - addr)
        return false;
    memcpy(dst, ctx->mem_base + addr, size);
    if (g_trace_reads) fprintf(stderr, "[gnm-trace]      read 0x%llx +%llu\n", (unsigned long long)addr, (unsigned long long)size);
    return true;
}

// =====================================================================================
// Guest memory as MTLBuffers (UMA, zero copy). Guest memory is one 512 GiB anonymous
// mapping, far larger than a Metal buffer may be, so it is exposed in 64 MiB aligned windows
// (created lazily with newBufferWithBytesNoCopy). A range crossing windows gets a buffer
// spanning all windows it touches. Window 0 starts at PS4_GNM_WINDOW0_BASE, above the guest
// NULL page area (ps4_gnm_guest_window.h).
// =====================================================================================
const uint64_t kWindow = PS4_GNM_WINDOW_SIZE;

// Guest ranges whose host pages were replaced (direct memory remapped/unmapped by the
// kernel layer). A no-copy MTLBuffer keeps referencing the pages it was created over,
// so windows overlapping such a range are dropped and re-created on next use.
std::mutex g_remap_mutex;
std::vector<std::pair<uint64_t, uint64_t>> g_remapped;
std::atomic<bool> g_remap_pending{false};

// The windows looked up last: most draws hit the same few.
struct GuestBufMru {
    uint64_t key = ~0ull;
    GuestWin* win = nullptr; // into S.guest_bufs (the MRU is reset whenever entries are erased)
};
GuestBufMru g_guest_buf_mru[4];

// GPU memory telemetry and budget (ps4_gnm_membudget.h, docs/gpu-memory-budget.md). A sampler
// thread measures wired memory, the process footprint, MTLDevice.currentAllocatedSize and the
// live no-copy guest buffers once a second and keeps the budget state; it runs apart from the
// renderer so it keeps reporting while the GPU or the encoder is stuck. PS4_GNM_MEM_LOG=<seconds>:
// one "[gnm-mem]" line per period (default 10, 0 = off) and whenever a value grew by 256 MiB.
// The encoder thread releases idle windows (and, over budget, every window not bound in the last
// 250 ms plus the transient staging caches) in SweepGuestWindows.
struct GpuMem {
    ps4_gpumem_policy policy{};
    ps4_gpumem_windows wins{};
    uint64_t wired_base = 0;
    bool on = false;
    std::atomic<bool> over{false};          // charged > budget (with hysteresis), set by the sampler
    std::atomic<uint64_t> charged{0};       // latest charged total, set by the sampler
    uint64_t tick = 0;                      // encoder thread: time of the current Commit
    uint64_t last_sweep = 0, last_refused_clear = 0; // encoder thread
    ps4_gpumem_purge_state purge{};         // encoder thread
    // Released buffers stay alive while a command buffer in flight references them, so their
    // accounting is removed only once every command buffer up to `seq` has completed.
    struct Pending {
        uint64_t key, length, seq;
    };
    std::deque<Pending> pending;            // encoder thread, in seq order
    // Window spans refused at creation (key -> ps4_gpumem_admit), so later binds neither walk the
    // VM regions again nor retry; cleared on remaps and every policy.idle_ns.
    std::unordered_map<uint64_t, uint8_t> refused;
    // Read-only copies made in the open command buffer (they live in its upload chunks), keyed by
    // the exact guest range: one copy per range and command buffer.
    struct Copy {
        uint64_t addr, size;
        id<MTLBuffer> buf;
        uint64_t off;
    };
    std::unordered_map<uint64_t, Copy> copies_open;
    std::atomic<uint64_t> released{0}, released_bytes{0}, purges{0}, large{0};
    // Texture cache eviction (EvictTextures, encoder thread)
    ps4_texcache_policy texpol{};
    uint64_t last_tex_evict = 0, last_gpu_evict = 0;
    bool tex_purge = false; // the over-budget sweep purged: evict idle sampled textures too
    // time Commit spends in SweepGuestWindows + EvictTextures (encoder thread writes, sampler reads)
    std::atomic<uint64_t> sweep_ns{0}, sweep_max_ns{0};
    std::atomic<uint64_t> refused_large{0}, refused_holes{0}, refused_written{0}, copies{0}, copy_bytes{0};
};
GpuMem g_mem;
// The texture cache as seen by the sampler thread (set once the cache exists).
std::atomic<TextureCache*> g_mem_tex{nullptr};

// Window span of a guest_bufs key (base | windows << 48).
inline void KeyWindows(uint64_t key, uint64_t* first, uint64_t* n) {
    *first = (key & ((1ull << 48) - 1)) / kWindow;
    *n = key >> 48;
}

void TakeGpuMemSample(ps4_gpumem_sample* s) {
    memset(s, 0, sizeof(*s));
    s->t_ns = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
    s->wired = ps4_gpumem_wired_bytes();
    s->footprint = ps4_gpumem_footprint_bytes();
    s->device = S.dev ? (uint64_t)S.dev.currentAllocatedSize : 0;
    ps4_gpumem_windows_read(&g_mem.wins, s);
}

void StartGpuMemSampler(uint64_t mem_size) {
    // the policy is needed by GuestBuffer even if the accounting below cannot start
    ps4_gpumem_policy_init(&g_mem.policy, ps4_gpumem_mem_total(), getenv("PS4_GNM_GPU_BUDGET_PCT"),
                           getenv("PS4_GNM_GPU_BUDGET_MB"), getenv("PS4_GNM_GPU_WINDOW_IDLE_S"));
    ps4_texcache_policy_init(&g_mem.texpol, &g_mem.policy, getenv("PS4_GNM_TEX_CACHE_MB"), getenv("PS4_GNM_TEX_KEEP_MS"));
    if (!ps4_gpumem_windows_init(&g_mem.wins, mem_size, kWindow)) return;
    g_mem.wired_base = ps4_gpumem_wired_bytes();
    g_mem.on = true;
    const char* lv = getenv("PS4_GNM_MEM_LOG");
    const uint64_t period_s = lv ? strtoull(lv, nullptr, 10) : 10;
    std::thread([period_s] {
        pthread_setname_np("gnm-mem");
        ps4_gpumem_log_state log{};
        ps4_gpumem_budget_state budget{};
        uint64_t peak_charged = 0, peak_wired = 0, peak_tex = 0;
        const uint64_t t_start = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
        for (;;) {
            ps4_gpumem_sample s;
            @autoreleasepool {
                TakeGpuMemSample(&s);
            }
            const uint64_t charged = ps4_gpumem_charged(&s);
            peak_charged = std::max(peak_charged, charged);
            peak_wired = std::max(peak_wired, s.wired);
            TextureCache* tc = g_mem_tex.load(std::memory_order_acquire);
            const TextureCache::MemStats ts = tc ? tc->GetMemStats() : TextureCache::MemStats{};
            peak_tex = std::max(peak_tex, ts.sampled_bytes);
            char line[512];
            const int change = ps4_gpumem_budget_update(&budget, &g_mem.policy, charged);
            g_mem.charged.store(charged, std::memory_order_relaxed);
            g_mem.over.store(budget.over != 0, std::memory_order_release);
            if (change) {
                ps4_gpumem_format(line, sizeof(line), &s, g_mem.wired_base, &g_mem.policy);
                if (change > 0 && budget.times_over == 1)
                    fprintf(stderr, "[gnm-mem] WARNING: over the GPU memory budget (%llu%% of RAM): releasing "
                                    "guest windows not in use and purging staging caches; %s\n",
                            (unsigned long long)(g_mem.policy.budget * 100 / std::max<uint64_t>(1, g_mem.policy.mem_total)),
                            line);
                else if (change > 0)
                    RLog("gpumem-over", "[gnm-mem] over the GPU memory budget again (%llu times): %s",
                         (unsigned long long)budget.times_over, line);
                else
                    RLog("gpumem-under", "[gnm-mem] back under the GPU memory budget: %s", line);
            }
            if (period_s && ps4_gpumem_log_due(&log, &s, period_s * 1000000000ull, 256ull << 20)) {
                ps4_gpumem_format(line, sizeof(line), &s, g_mem.wired_base, &g_mem.policy);
                fprintf(stderr, "[gnm-mem] %s; peak charged %llu MiB, peak wired %llu MiB; released %llu windows "
                                "(%llu MiB), purges %llu, large %llu, refused %llu too large / %llu with holes / %llu "
                                "written, copies %llu (%llu MiB)%s\n",
                        line, (unsigned long long)(peak_charged >> 20), (unsigned long long)(peak_wired >> 20),
                        (unsigned long long)g_mem.released.load(), (unsigned long long)(g_mem.released_bytes.load() >> 20),
                        (unsigned long long)g_mem.purges.load(), (unsigned long long)g_mem.large.load(),
                        (unsigned long long)g_mem.refused_large.load(), (unsigned long long)g_mem.refused_holes.load(),
                        (unsigned long long)g_mem.refused_written.load(), (unsigned long long)g_mem.copies.load(),
                        (unsigned long long)(g_mem.copy_bytes.load() >> 20), budget.over ? "; OVER BUDGET" : "");
                if (tc) {
                    fprintf(stderr, "[gnm-mem] texture cache at %llu s: sampled %llu (%llu MiB, peak %llu MiB, budget %llu MiB), "
                                    "GPU-owned %llu (%llu MiB); evicted %llu (%llu MiB), superseded GPU-owned %llu (%llu MiB)\n",
                            (unsigned long long)((s.t_ns - t_start) / 1000000000ull),
                            (unsigned long long)ts.sampled_count, (unsigned long long)(ts.sampled_bytes >> 20),
                            (unsigned long long)(peak_tex >> 20),
                            (unsigned long long)(g_mem.texpol.budget == UINT64_MAX ? 0 : g_mem.texpol.budget >> 20),
                            (unsigned long long)ts.gpu_count, (unsigned long long)(ts.gpu_bytes >> 20),
                            (unsigned long long)tc->EvictedCount(), (unsigned long long)(tc->EvictedBytes() >> 20),
                            (unsigned long long)tc->EvictedGpuCount(), (unsigned long long)(tc->EvictedGpuBytes() >> 20));
                }
                if (tc) {
                    const TextureCache::GpuOwnedStats go = tc->GetGpuOwnedStats(10000000000ull);
                    fprintf(stderr, "[gnm-mem] GPU-owned surfaces: %llu (%llu MiB) overlapped by newer surfaces, %llu (%llu MiB) "
                                    "unused for 10 s\n",
                            (unsigned long long)go.superseded_count, (unsigned long long)(go.superseded_bytes >> 20),
                            (unsigned long long)go.idle_count, (unsigned long long)(go.idle_bytes >> 20));
                }
                fprintf(stderr, "[gnm-mem] sweeps: %.1f ms total, longest %.2f ms since the last line\n",
                        g_mem.sweep_ns.exchange(0, std::memory_order_relaxed) / 1e6,
                        g_mem.sweep_max_ns.exchange(0, std::memory_order_relaxed) / 1e6);
            }
            usleep(1000000);
        }
    }).detach();
}

uint64_t CompletedSeq();

// Drops a window from guest_bufs; its accounting goes when the GPU can no longer use it.
std::unordered_map<uint64_t, GuestWin>::iterator ReleaseWindow(std::unordered_map<uint64_t, GuestWin>::iterator it) {
    if (g_mem.on) g_mem.pending.push_back({it->first, (uint64_t)it->second.buf.length, S.committed_seq + 1});
    return S.guest_bufs.erase(it);
}

// Removes the accounting of released windows whose command buffers have all completed.
void RetirePendingWindows() {
    if (g_mem.pending.empty()) return;
    const uint64_t done = CompletedSeq();
    while (!g_mem.pending.empty() && g_mem.pending.front().seq <= done) {
        const GpuMem::Pending& p = g_mem.pending.front();
        uint64_t first, n;
        KeyWindows(p.key, &first, &n);
        ps4_gpumem_windows_remove(&g_mem.wins, first, n, p.length);
        g_mem.pending.pop_front();
    }
}

void DropRemappedWindows() {
    const uint64_t mb_t0 = ps4_hitch_now_ns();
    std::vector<std::pair<uint64_t, uint64_t>> ranges;
    {
        std::lock_guard<std::mutex> lk(g_remap_mutex);
        ranges.swap(g_remapped);
        g_remap_pending.store(false, std::memory_order_release);
    }
    for (auto it = S.guest_bufs.begin(); it != S.guest_bufs.end();) {
        const uint64_t base = it->first & ((1ull << 48) - 1);
        const uint64_t end = (base & ~(kWindow - 1)) + (it->first >> 48) * kWindow;
        bool hit = false;
        for (auto& r : ranges)
            if (r.first < end && r.first + r.second > base) { hit = true; break; }
        if (hit) it = ReleaseWindow(it);
        else ++it;
    }
    if (!ranges.empty()) g_mem.refused.clear(); // the new mapping may have no holes
    for (auto& m : g_guest_buf_mru) m = GuestBufMru{};
    ps4_hitch_add_ns(PS4_HITCH_MTLBUF, ps4_hitch_now_ns() - mb_t0);
}

// Lazy residency and the budget (encoder thread, from Commit): releases windows not bound for
// policy.idle_ns, and while over budget every window not bound for policy.press_ns plus the
// transient staging caches (with a back-off once purging stops helping). A released buffer still
// referenced by a command buffer in flight lives (and stays wired) until that command buffer
// completes; the next use re-creates it.
void SweepGuestWindows() {
    g_mem.copies_open.clear(); // their upload chunks are recycled once this command buffer is done
    if (!g_mem.on) return;
    RetirePendingWindows();
    const bool over = g_mem.over.load(std::memory_order_acquire);
    const uint64_t now = g_mem.tick;
    // once a second; over budget at every commit until a sweep has run in this state
    static bool swept_over = false;
    if (now - g_mem.last_sweep < 1000000000ull && !(over && !swept_over)) return;
    g_mem.last_sweep = now;
    swept_over = over;
    if (g_mem.policy.idle_ns && now - g_mem.last_refused_clear >= g_mem.policy.idle_ns) {
        g_mem.refused.clear();
        g_mem.last_refused_clear = now;
    }
    uint64_t n_rel = 0, bytes = 0;
    for (auto it = S.guest_bufs.begin(); it != S.guest_bufs.end();) {
        if (ps4_gpumem_should_release(&g_mem.policy, now, it->second.last_use, over)) {
            bytes += it->second.buf.length;
            it = ReleaseWindow(it);
            n_rel++;
        } else {
            ++it;
        }
    }
    if (n_rel) {
        for (auto& m : g_guest_buf_mru) m = GuestBufMru{};
        g_mem.released.fetch_add(n_rel, std::memory_order_relaxed);
        g_mem.released_bytes.fetch_add(bytes, std::memory_order_relaxed);
        RLog("gpumem-release", "[gnm-mem] released %llu guest window buffers (%llu MiB)%s", (unsigned long long)n_rel,
             (unsigned long long)(bytes >> 20), over ? " (over budget)" : " (idle)");
    }
    if (ps4_gpumem_purge_due(&g_mem.purge, over, g_mem.charged.load(std::memory_order_relaxed))) {
        // staging caches are re-created on demand
        S.detile_staging.clear();
        S.detile_maps.clear();
        std::lock_guard<std::mutex> lk(S.arena.free_mu);
        S.arena.free_list.clear();
        g_mem.purges.fetch_add(1, std::memory_order_relaxed);
        g_mem.tex_purge = true;
    } else if (over && g_mem.purge.futile == 10) {
        RLog("gpumem-futile", "[gnm-mem] purging does not lower the charged total (%llu MiB): the memory over "
                              "budget is the device's own (textures); purges paused",
             (unsigned long long)(g_mem.charged.load() >> 20));
    }
}

// Texture cache eviction (encoder thread, from Commit, after SweepGuestWindows): while the
// sampled textures exceed their budget, at most every 100 ms, least recently used first among
// those not used for texpol.keep_ns; when the over-budget sweep purged the transient caches (with
// its back-off), every sampled texture not used for texpol.press_ns. Only textures whose last
// command buffer has completed are evicted (TextureCache::EvictSampled).
// Renderer state keyed by a texture pointer must not outlive the texture: a new texture can get
// the same address. Every such map is erased here (keep this list complete when adding one).
void ForgetTexture(void* key) {
    S.depth_comp.erase(key);
    S.depth_version.erase(key);
    S.depth_last_write.erase(key);
    auto tw = S.eqaa_twin.find(key);
    if (tw != S.eqaa_twin.end()) {
        S.eqaa_orig.erase((__bridge void*)tw->second);
        S.eqaa_twin.erase(tw);
    }
}

// Textures the cache dropped (superseded evictions, grown depth arrays): forget them, then let
// them go (command buffers that still use them keep them alive).
void ForgetRetiredTextures(TextureCache* tc) {
    std::vector<id<MTLTexture>> gone;
    tc->TakeRetired(&gone);
    for (id<MTLTexture> t : gone) ForgetTexture((__bridge void*)t);
}

void EvictTextures() {
    TextureCache* tc = S.tex;
    if (!tc) return;
    ForgetRetiredTextures(tc);
    const bool gpu_purge = g_mem.tex_purge;
    g_mem.tex_purge = false;
    const uint64_t now = g_mem.tick;
    // superseded GPU-owned surfaces: once a second (with the purge too), idle 10 s (2 s over budget)
    if (gpu_purge || now - g_mem.last_gpu_evict >= 1000000000ull) {
        g_mem.last_gpu_evict = now;
        const TextureCache::EvictResult gr =
            tc->EvictSuperseded(gpu_purge ? 2000000000ull : 10000000000ull, now, CompletedSeq());
        if (gr.count)
            RLog("tex-evict-gpu", "[gnm-mem] evicted %llu superseded GPU-owned surfaces (%llu MiB)",
                 (unsigned long long)gr.count, (unsigned long long)(gr.bytes >> 20));
        ForgetRetiredTextures(tc);
    }
    if (!gpu_purge && (now - g_mem.last_tex_evict < 100000000ull ||
                       !ps4_texcache_evict_due(&g_mem.texpol, tc->GetMemStats().sampled_bytes, 0)))
        return;
    g_mem.last_tex_evict = now;
    const TextureCache::EvictResult r = tc->EvictSampled(g_mem.texpol, gpu_purge, now, CompletedSeq());
    if (r.count)
        RLog("tex-evict", "[gnm-mem] evicted %llu sampled textures (%llu MiB)%s", (unsigned long long)r.count,
             (unsigned long long)(r.bytes >> 20), gpu_purge ? " (over the GPU budget)" : " (over the cache budget)");
}

// How a binding uses guest memory. A GPU-written binding must be the guest memory itself: a copy
// would drop its writes.
enum class GuestAccess { Read, Write };

// Read-only stand-in for a range no no-copy buffer may cover (one with unmapped or unreadable
// pages): a copy of its readable bytes in upload memory, holes as zero, made once per range and
// command buffer (guest writes after the first bind in that command buffer are not seen, as with
// any snapshot). 256 zero bytes follow it, since shader bounds round the size up to the V# end
// (debug bounds modes PS4_GNM_BOUNDS=raw/off can still read past that). The caller decides
// (ps4_gpumem_refused_copy) which ranges may be copied.
bool GuestCopy(uint64_t addr, uint64_t size, __strong id<MTLBuffer>* out, uint64_t* offset) {
    const uint64_t ck = addr ^ (size * 0x9E3779B97F4A7C15ull);
    auto cit = g_mem.copies_open.find(ck);
    if (cit != g_mem.copies_open.end() && cit->second.addr == addr && cit->second.size == size) {
        *out = cit->second.buf;
        *offset = cit->second.off;
        return true;
    }
    void* ptr = nullptr;
    size_t off = 0;
    id<MTLBuffer> b = nil;
    if (!S.arena.Alloc(S.dev, size + 256, 256, &b, &off, &ptr)) return false;
    memset(ptr, 0, size + 256);
    struct Ctx {
        uint8_t* dst;
        const uint8_t* src;
    } c = {(uint8_t*)ptr, S.ctx->mem_base + addr};
    ps4_gpumem_for_each_readable(c.src, size, [](void* p, uint64_t o, uint64_t n) {
        Ctx* x = (Ctx*)p;
        memcpy(x->dst + o, x->src + o, n);
    }, &c);
    g_mem.copies.fetch_add(1, std::memory_order_relaxed);
    g_mem.copy_bytes.fetch_add(size, std::memory_order_relaxed);
    g_mem.copies_open[ck] = {addr, size, b, off};
    *out = b;
    *offset = off;
    return true;
}

// A guest range whose window span got no no-copy buffer (adm: why). Reads of ranges with holes
// get a copy; GPU-written ranges and spans over policy.nocopy_max are not bound (false), as
// before the budget existed.
bool RefusedGuestBuffer(uint64_t addr, uint64_t size, uint64_t base, uint64_t end, enum ps4_gpumem_admit adm,
                        GuestAccess access, __strong id<MTLBuffer>* out, uint64_t* offset) {
    const bool holes = adm == PS4_GPUMEM_REFUSE_HOLES;
    const bool copied =
        ps4_gpumem_refused_copy(adm, access == GuestAccess::Write, size) && GuestCopy(addr, size, out, offset);
    if (holes && access == GuestAccess::Write) g_mem.refused_written.fetch_add(1, std::memory_order_relaxed);
    RLog(!holes ? "guestbuf-big" : access == GuestAccess::Write ? "guestbuf-holes-written" : "guestbuf-holes",
         "[gnm-mem] no no-copy buffer over guest 0x%llx+0x%llx (for 0x%llx+0x%llx): %s; %s",
         (unsigned long long)base, (unsigned long long)(end - base), (unsigned long long)addr,
         (unsigned long long)size, holes ? "range has holes" : "larger than 2 GiB",
         copied ? "bound a read-only copy"
         : !holes ? "not bound"
         : access == GuestAccess::Write ? "not bound (GPU-written: a copy would drop the writes)"
                                        : "not bound (over 64 MiB)");
    return copied;
}

// `out` is a strong pointer: an (implicitly autoreleasing) plain one would retain and autorelease
// the buffer on every call. `access`: whether the GPU writes the range (a written range is only
// ever bound in place).
bool GuestBuffer(uint64_t addr, uint64_t size, GuestAccess access, __strong id<MTLBuffer>* out, uint64_t* offset) {
    GuestContext* ctx = S.ctx;
    if (g_remap_pending.load(std::memory_order_acquire)) DropRemappedWindows();
    if (!ctx) return false;
    uint64_t base, end, nwin;
    if (!ps4_gnm_guest_window_range(addr, size, ctx->mem_size, &base, &end, &nwin)) return false;
    const uint64_t key = base | (nwin << 48);
    GuestBufMru& mru = g_guest_buf_mru[(base / kWindow + nwin) & 3];
    if (mru.key == key) {
        mru.win->last_use = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
        *out = mru.win->buf;
        *offset = addr - base;
        return true;
    }
    auto it = S.guest_bufs.find(key);
    if (it == S.guest_bufs.end()) {
        auto rit = g_mem.refused.find(key);
        if (rit != g_mem.refused.end())
            return RefusedGuestBuffer(addr, size, base, end, (enum ps4_gpumem_admit)rit->second, access, out, offset);
        const uint64_t mb_t0 = ps4_hitch_now_ns();
        // size first: a too large span is refused without walking its VM regions
        enum ps4_gpumem_admit adm = ps4_gpumem_admit_nocopy(&g_mem.policy, end - base, 0);
        if (adm != PS4_GPUMEM_REFUSE_TOO_LARGE)
            adm = ps4_gpumem_admit_nocopy(&g_mem.policy, end - base,
                                          ps4_gpumem_range_has_holes(ctx->mem_base + base, end - base));
        if (adm == PS4_GPUMEM_REFUSE_TOO_LARGE || adm == PS4_GPUMEM_REFUSE_HOLES) {
            ps4_hitch_add_ns(PS4_HITCH_MTLBUF, ps4_hitch_now_ns() - mb_t0);
            (adm == PS4_GPUMEM_REFUSE_TOO_LARGE ? g_mem.refused_large : g_mem.refused_holes)
                .fetch_add(1, std::memory_order_relaxed);
            g_mem.refused[key] = (uint8_t)adm;
            return RefusedGuestBuffer(addr, size, base, end, adm, access, out, offset);
        }
        if (adm == PS4_GPUMEM_ADMIT_LARGE) {
            g_mem.large.fetch_add(1, std::memory_order_relaxed);
            RLog("guestbuf-large", "[gnm-mem] no-copy buffer over guest 0x%llx+0x%llx is larger than 1 GiB: it pins "
                                   "(and wires) all of it while bound",
                 (unsigned long long)base, (unsigned long long)(end - base));
        }
        id<MTLBuffer> b = [S.dev newBufferWithBytesNoCopy:ctx->mem_base + base
                                                   length:end - base
                                                  options:MTLResourceStorageModeShared
                                              deallocator:nil];
        ps4_hitch_add_ns(PS4_HITCH_MTLBUF, ps4_hitch_now_ns() - mb_t0);
        if (!b) {
            RLog("guestbuf", "newBufferWithBytesNoCopy failed for 0x%llx+0x%llx",
                 (unsigned long long)base, (unsigned long long)(end - base));
            return false;
        }
        it = S.guest_bufs.emplace(key, GuestWin{b, 0}).first;
        if (g_mem.on) ps4_gpumem_windows_add(&g_mem.wins, base / kWindow, nwin, end - base);
    }
    it->second.last_use = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
    mru.key = key;
    mru.win = &it->second;
    *out = it->second.buf;
    *offset = addr - base;
    return true;
}

bool ShouldTrace();
void BuildFlat(const struct Shader* s, const uint32_t ud[16], std::vector<uint32_t>* flat);
id<MTLTexture> DepthCompanion(id<MTLTexture> dt, bool encode);
bool HasStencil(MTLPixelFormat f);
id<MTLTexture> DepthFromMemory(const ImageDesc& img, bool encode);
id<MTLTexture> MipChainFor(const ImageDesc& img, bool encode);
id<MTLComputeCommandEncoder> ComputeEncoder();
id<MTLTexture> SampledTexture(const ImageDesc& img);

void NoteGpuWrite(uint64_t addr, uint64_t size) {
    if (!size) return;
    // the same range written again by this command buffer: only its latest write matters (the
    // hazard check and the texture invalidation both take the latest epoch of a range)
    uint32_t& slot = S.gpu_written_slot[((addr >> 8) ^ size) & 63];
    if (slot < S.gpu_written.size() && S.gpu_written[slot].addr == addr && S.gpu_written[slot].size == size) {
        S.gpu_written[slot].epoch = ++S.write_epoch;
        return;
    }
    slot = (uint32_t)S.gpu_written.size();
    S.gpu_written.push_back({addr, size, ++S.write_epoch});
}

uint64_t CompletedSeq() {
    std::lock_guard<std::mutex> lk(S.fence_mu);
    return S.completed_seq;
}

// True if GPU work that has not completed yet writes guest memory in [addr, addr + size).
void PruneCompletedWrites() {
    if (S.inflight_written.empty()) return;
    const uint64_t done = CompletedSeq();
    while (!S.inflight_written.empty() && S.inflight_written.front().first <= done) S.inflight_written.pop_front();
}

// `hit` (optional) receives an overlapping write with the latest epoch among the overlaps.
bool OverlapsPendingWrite(uint64_t addr, uint64_t size, GpuWrite* hit = nullptr) {
    bool any = false;
    auto check = [&](const GpuWrite& r) {
        if (r.addr < addr + size && addr < r.addr + r.size) {
            if (hit && (!any || r.epoch > hit->epoch)) *hit = r;
            any = true;
        }
    };
    for (auto& r : S.gpu_written) check(r);
    for (auto& w : S.inflight_written)
        for (auto& r : w.second) check(r);
    return any;
}

// =====================================================================================
// Command buffer management
// =====================================================================================
void ResolveEqaaPass();

void EndEncoders() {
    if (S.renc) {
        [S.renc endEncoding];
        S.renc = nil;
        ResolveEqaaPass();
    }
    if (S.cenc) {
        [S.cenc endEncoding];
        S.cenc = nil;
    }
    S.pass = PassKey{};
    for (auto& t : S.pass_hold) t = nil;
}

std::atomic<bool> g_cmd_open{false}; // S.cmd != nil, readable from the CP thread

// PS4_GNM_ENCODER_STATUS=1 (debug): command buffers report per-encoder execution status, and
// every encoder is labelled with the index of its first work record, so a failed command buffer
// names the encoder that faulted (see LogEncoderStatus). Costs GPU time; off by default.
bool EncoderStatusEnabled() {
    static const bool on = getenv("PS4_GNM_ENCODER_STATUS") != nullptr;
    return on;
}

NSString* WorkLabel(const char* kind) {
    const uint64_t first = S.cmd_log ? S.cmd_log->count : 0;
    return [NSString stringWithFormat:@"%s from work[%llu]", kind, (unsigned long long)first];
}

void LogEncoderStatus(id<MTLCommandBuffer> done) {
    NSArray* infos = done.error.userInfo[MTLCommandBufferEncoderInfoErrorKey];
    for (id<MTLCommandBufferEncoderInfo> info in infos) {
        const MTLCommandEncoderErrorState st = info.errorState;
        if (st != MTLCommandEncoderErrorStateFaulted && st != MTLCommandEncoderErrorStateAffected) continue;
        fprintf(stderr, "[gnm-draw]   encoder '%s': %s\n", (info.label ?: @"unlabelled").UTF8String,
                st == MTLCommandEncoderErrorStateFaulted ? "FAULTED" : "affected");
    }
}

void EnsureCmd() {
    if (!S.cmd) {
        if (EncoderStatusEnabled()) {
            MTLCommandBufferDescriptor* d = [MTLCommandBufferDescriptor new];
            d.errorOptions = MTLCommandBufferErrorOptionEncoderExecutionStatus;
            S.cmd = [S.queue commandBufferWithDescriptor:d];
        } else {
            S.cmd = [S.queue commandBuffer];
        }
        g_cmd_open.store(true, std::memory_order_release);
        S.cmd.label = [NSString stringWithFormat:@"gnm-%llu", (unsigned long long)S.n_cmdbufs++];
        S.cmd_log = std::make_shared<WorkLog>();
    }
}

void LogWork(const WorkRec& r) {
    if (S.cmd_log) S.cmd_log->Add(r);
}
void LogWork(const char* what) {
    WorkRec r;
    r.what = what;
    LogWork(r);
}

// Runs queued fence actions whose command buffers completed (in order).
void RunFences(uint64_t upto) {
    std::lock_guard<std::recursive_mutex> run(S.fence_run_mu);
    for (;;) {
        std::function<void()> fn;
        {
            std::lock_guard<std::mutex> lk(S.fence_mu);
            if (upto > S.completed_seq) S.completed_seq = upto;
            if (S.fence_q.empty() || S.fence_q.front().first > S.completed_seq) return;
            fn = std::move(S.fence_q.front().second);
            S.fence_q.pop_front();
        }
        if (fn) fn();
    }
}

void Commit() {
    EndEncoders();
    g_mem.tick = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
    SweepGuestWindows();
    EvictTextures();
    {
        const uint64_t d = clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - g_mem.tick;
        g_mem.sweep_ns.fetch_add(d, std::memory_order_relaxed);
        if (d > g_mem.sweep_max_ns.load(std::memory_order_relaxed)) g_mem.sweep_max_ns.store(d, std::memory_order_relaxed);
    }
    if (S.upload_cmd) {
        // texture copies used by the work of S.cmd: same queue, committed first
        [S.upload_cmd commit];
        S.upload_cmd = nil;
    }
    if (!S.cmd) {
        // later lookups belong to the next command buffer (an upload_cmd committed just now
        // completes before it: same queue)
        if (S.tex) S.tex->SetUse(S.committed_seq + 1, g_mem.tick);
        return;
    }
    id<MTLCommandBuffer> cb = S.cmd;
    S.cmd = nil;
    S.cmd_start_epoch = S.write_epoch + 1; // writes noted from now on belong to the next command buffer
    g_cmd_open.store(false, std::memory_order_release);
    // recycle upload chunks when the GPU is done with them
    auto chunks = std::make_shared<std::vector<id<MTLBuffer>>>();
    for (auto& c : S.arena.cur) chunks->push_back(c.buf);
    S.arena.cur.clear();
    std::shared_ptr<WorkLog> log = std::move(S.cmd_log);
    S.cmd_log.reset();
    UploadArena* arena = &S.arena;
    uint64_t seq;
    {
        std::lock_guard<std::mutex> lk(S.fence_mu);
        seq = ++S.committed_seq;
    }
    // textures looked up from now on are used by the next command buffer
    if (S.tex) S.tex->SetUse(seq + 1, g_mem.tick);
    // Guest memory written by this command buffer: sampled textures created from it are stale
    // once the GPU is done (TextureCache is thread-safe).
    std::shared_ptr<std::vector<GpuWrite>> written;
    if (!S.gpu_written.empty()) {
        written = std::make_shared<std::vector<GpuWrite>>(S.gpu_written);
        S.inflight_written.push_back({seq, std::move(S.gpu_written)});
        S.gpu_written.clear();
    }
    TextureCache* tex_cache = S.tex;
    [cb addCompletedHandler:^(id<MTLCommandBuffer> done) {
        if (written && tex_cache) tex_cache->InvalidateWrites(*written);
        {
            // GPU busy time: union of the command buffers' execution intervals (they may overlap)
            const double gs = done.GPUStartTime, ge = done.GPUEndTime;
            std::lock_guard<std::mutex> lk(S.gpu_time_mu);
            const double from = std::max(gs, S.gpu_last_end);
            if (ge > from) S.gpu_ns.fetch_add((uint64_t)((ge - from) * 1e9), std::memory_order_relaxed);
            S.gpu_last_end = std::max(S.gpu_last_end, ge);
        }
        RunFences(seq);
        if (done.status == MTLCommandBufferStatusError) {
            fprintf(stderr, "[gnm-draw] command buffer %s failed: %s\n", done.label.UTF8String,
                    done.error.localizedDescription.UTF8String);
            if (EncoderStatusEnabled()) LogEncoderStatus(done);
            if (log) log->Print("work", EncoderStatusEnabled() ? WorkLog::kAll : 12);
        }
        std::lock_guard<std::mutex> lk(arena->free_mu);
        for (auto& b : *chunks)
            if (b.length == UploadArena::kChunk && arena->free_list.size() < 16)
                arena->free_list.push_back(b);
    }];
    [cb commit];
    S.n_commits++;
    // PS4_GNM_HANG_REPORT_MS=<ms> (debug): name the work of a command buffer that has not
    // completed that long after its commit. A shader that never ends shows no error until
    // something else needs the GPU (then macOS kills it as "Impacting Interactivity").
    static const long hang_ms = getenv("PS4_GNM_HANG_REPORT_MS") ? atol(getenv("PS4_GNM_HANG_REPORT_MS")) : 0;
    if (hang_ms > 0) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, hang_ms * NSEC_PER_MSEC),
                       dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            if (cb.status >= MTLCommandBufferStatusCompleted) return;
            fprintf(stderr, "[gnm-draw] GPU hang report: command buffer %s not complete %ld ms after commit\n",
                    cb.label.UTF8String, hang_ms);
            if (log) log->Print("pending work", WorkLog::kAll);
        });
    }
    // drop references to completed command buffers
    if (S.inflight.size() >= 8) {
        size_t n = 0;
        for (size_t i = 0; i < S.inflight.size(); ++i) {
            if (S.inflight[i].status < MTLCommandBufferStatusCompleted) S.inflight[n++] = S.inflight[i];
            else S.inflight_logs.erase((__bridge void*)S.inflight[i]);
        }
        S.inflight.resize(n);
    }
    S.inflight.push_back(cb);
    S.inflight_logs[(__bridge void*)cb] = log;
}

void WaitAll() {
    const double t0 = CFAbsoluteTimeGetCurrent();
    if (!S.inflight.empty()) S.n_waits++;
    for (auto& cb : S.inflight) {
        if (cb.status >= MTLCommandBufferStatusCompleted) continue;
        if (S.hung) continue;
        // watchdog: poll with timeout so a GPU hang can never block the guest forever
        const double deadline_ms = S.gpu_timeout_ms;
        double waited = 0;
        while (cb.status < MTLCommandBufferStatusCompleted && waited < deadline_ms) {
            usleep(200);
            waited += 0.2;
        }
        if (cb.status < MTLCommandBufferStatusCompleted) {
            fprintf(stderr,
                    "[gnm-draw] GPU watchdog: command buffer %s did not complete in %.0f ms; "
                    "disabling GPU rendering (fences keep being signaled)\n",
                    cb.label.UTF8String, deadline_ms);
            S.hung = true;
            auto lit = S.inflight_logs.find((__bridge void*)cb);
            if (lit != S.inflight_logs.end() && lit->second) lit->second->Print("hung work", WorkLog::kAll);
        }
    }
    S.inflight.clear();
    S.inflight_logs.clear();
    {
        uint64_t upto;
        {
            std::lock_guard<std::mutex> lk(S.fence_mu);
            upto = S.committed_seq;
        }
        RunFences(upto);
    }
    // everything committed has completed; its completion handlers may still be pending, so
    // drop stale sampled textures here as well
    if (S.tex && !S.inflight_written.empty()) {
        std::vector<GpuWrite> all;
        for (auto& w : S.inflight_written) all.insert(all.end(), w.second.begin(), w.second.end());
        S.tex->InvalidateWrites(all);
    }
    S.inflight_written.clear();
    S.pending = false;
    g_hitch.wait_ms += (CFAbsoluteTimeGetCurrent() - t0) * 1000.0;
    S.wait_ms += (CFAbsoluteTimeGetCurrent() - t0) * 1000.0;
}

// =====================================================================================
// Shaders
// =====================================================================================
void DumpMsl(const Shader* s, const char* msl) {
    static const char* dir = getenv("PS4_GNM_MSL_DUMP");
    if (!dir || !msl) return;
    char path[1024];
    snprintf(path, sizeof(path), "%s/%s_%llx_%llu.metal", dir,
             s->hw == GCN_HW_VS ? "vs" : s->hw == GCN_HW_PS ? "ps" : s->hw == GCN_HW_CS ? "cs" : "xx",
             (unsigned long long)s->code_addr, (unsigned long long)s->uid);
    FILE* f = fopen(path, "w");
    if (!f) return;
    fputs(msl, f);
    fclose(f);
    // the GCN binary next to it (for gcn_dis)
    if (s->info.code_size && s->info.code_size <= (1u << 22)) {
        std::vector<uint8_t> code(s->info.code_size);
        if (ReadGuest(S.ctx, s->code_addr, code.data(), code.size())) {
            snprintf(path + strlen(path) - 6, 8, ".bin");
            if (FILE* b = fopen(path, "wb")) {
                fwrite(code.data(), 1, code.size(), b);
                fclose(b);
            }
        }
    }
}

// ---- On-disk MSL cache + warm-up -------------------------------------------------------
// Every MSL source compiled is stored as <cache>/<fnv64>.metal. At startup background threads
// compile the cached sources so shaders seen in earlier sessions are ready (and the system Metal
// shader cache is warm) before the game needs them.
// Returns true if the MSL was new (not in the disk cache yet).
bool StoreMslInDiskCache(uint64_t mh, const char* msl) {
    if (S.msl_cache_dir.empty()) return true;
    const uint64_t fs_t0 = ps4_hitch_now_ns();
    char path[1200];
    snprintf(path, sizeof(path), "%s/%016llx.metal", S.msl_cache_dir.c_str(), (unsigned long long)mh);
    const bool is_new = S.msl_on_disk.insert(mh).second; // CP thread only, filled at startup
    if (!is_new) {
        ps4gnm_shader_cache::MarkUsed(path); // asynchronous
    } else {
        // The frame does not wait for the disk. A write still pending at quit is lost; the
        // shader is then translated again in the next session.
        // Utility QoS: otherwise the queue would run at the QoS of the CP thread that submits.
        static dispatch_queue_t writer = dispatch_queue_create(
            "ps4.gnm.msl_cache.writer", dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL, QOS_CLASS_UTILITY, 0));
        auto* job = new std::pair<std::string, std::string>(path, msl);
        dispatch_async(writer, ^{
            char tmp[1300];
            snprintf(tmp, sizeof(tmp), "%s.tmp%d", job->first.c_str(), (int)getpid());
            bool ok = false;
            if (FILE* f = fopen(tmp, "w")) {
                const bool put_ok = fputs(job->second.c_str(), f) >= 0;
                const bool close_ok = fclose(f) == 0;
                ok = put_ok && close_ok;
            }
            if (ok && rename(tmp, job->first.c_str()) != 0) ok = false;
            if (!ok) {
                const int err = errno;
                unlink(tmp);
                fprintf(stderr, "[gnm-draw] msl cache write failed: %s: %s\n", job->first.c_str(), strerror(err));
            }
            delete job;
        });
    }
    ps4_hitch_add_ns(PS4_HITCH_SHADER_FS, ps4_hitch_now_ns() - fs_t0);
    return is_new;
}

MTLCompileOptions* CompileOptions() {
    MTLCompileOptions* opt = [MTLCompileOptions new];
    // Kept as before (not mathMode): the options are part of the system Metal cache's key, so a
    // different spelling of the same options could make the player's cache miss once.
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    opt.fastMathEnabled = NO;
#pragma clang diagnostic pop
    opt.preserveInvariance = YES;
    return opt;
}

uint32_t StoreStage(uint32_t hw) {
    return hw == GCN_HW_VS ? ps4gnm_lib_store::kVertex
           : hw == GCN_HW_PS ? ps4gnm_lib_store::kFragment
           : hw == GCN_HW_CS ? ps4gnm_lib_store::kKernel
                             : 0;
}

// Warm-up: background threads make the shaders of earlier sessions ready before the game asks
// for them. Libraries in the store are loaded first (about a millisecond each), then cached MSL
// without a store entry is compiled (hundreds of ms each when the system Metal cache misses).
// Within each group the shaders the game met first in its history (oldest file creation time:
// title screen and menus) come first.
void StartShaderWarmup() {
    if (getenv("PS4_GNM_NO_SHADER_CACHE")) return;
    const std::string title_dir = ps4gnm_shader_cache::TitleDir();
    if (title_dir.empty()) return;
    S.msl_cache_dir = title_dir + "/msl";
    [[NSFileManager defaultManager] createDirectoryAtPath:[NSString stringWithUTF8String:S.msl_cache_dir.c_str()]
                              withIntermediateDirectories:YES attributes:nil error:nil];
    S.pso_list_path = S.msl_cache_dir + "/pipelines.bin";
    // MSL of older recompiler builds is never asked for again; the size limit drops it
    ps4gnm_shader_cache::PruneDir(S.msl_cache_dir, ".metal", ps4gnm_shader_cache::BudgetBytes(48), "MSL");
    if (FILE* pf = fopen(S.pso_list_path.c_str(), "rb")) {
        uint64_t h;
        while (fread(&h, sizeof(h), 1, pf) == 1) S.known_psos.insert(h);
        fclose(pf);
    }
    {
        // PS4_GNM_LIB_STORE_MB: size budget of the library store; not a positive number -> 256
        const char* mb = getenv("PS4_GNM_LIB_STORE_MB");
        char* end = nullptr;
        long long v = mb ? strtoll(mb, &end, 10) : 0;
        if (!mb || end == mb || *end || v <= 0 || v > (1ll << 20)) v = 256;
        // the configuration is derived from these options (ps4gnm_lib_store::OptionsTag)
        ps4gnm_lib_store::Open(S.dev, title_dir, CompileOptions(), (uint64_t)v << 20);
    }
    struct Item {
        std::string path;
        ps4gnm_lib_store::Key key; // store entries: h1/h2 from the file name
        bool store = false;
        struct timespec born;
    };
    auto by_birth = [](const Item& a, const Item& b) {
        return a.born.tv_sec != b.born.tv_sec ? a.born.tv_sec < b.born.tv_sec : a.born.tv_nsec < b.born.tv_nsec;
    };
    std::vector<Item> stored, sources;
    std::unordered_set<uint64_t> stored_h1;
    struct stat st;
    if (ps4gnm_lib_store::Enabled()) {
        const std::string& sd = ps4gnm_lib_store::Dir();
        if (DIR* d = opendir(sd.c_str())) {
            while (dirent* de = readdir(d)) {
                Item it;
                if (!ps4gnm_lib_store::ParseFileName(de->d_name, &it.key)) continue;
                it.path = sd + "/" + de->d_name;
                if (stat(it.path.c_str(), &st) != 0) continue;
                it.store = true;
                it.born = st.st_birthtimespec;
                stored_h1.insert(it.key.h1);
                stored.push_back(it);
            }
            closedir(d);
        }
    }
    if (DIR* d = opendir(S.msl_cache_dir.c_str())) {
        while (dirent* de = readdir(d)) {
            const size_t n = strlen(de->d_name);
            if (n != 22 || strcmp(de->d_name + 16, ".metal") != 0) continue;
            char* end = nullptr;
            const uint64_t h = strtoull(de->d_name, &end, 16);
            if (end != de->d_name + 16) continue;
            S.msl_on_disk.insert(h);
            if (stored_h1.count(h)) continue; // loaded from the store instead
            Item it;
            it.path = S.msl_cache_dir + "/" + de->d_name;
            if (stat(it.path.c_str(), &st) != 0) continue;
            it.key.h1 = h;
            it.born = st.st_birthtimespec;
            sources.push_back(it);
        }
        closedir(d);
    }
    std::sort(stored.begin(), stored.end(), by_birth);
    std::sort(sources.begin(), sources.end(), by_birth);
    const size_t n_stored = stored.size();
    auto items = std::make_shared<std::vector<Item>>(std::move(stored));
    items->insert(items->end(), sources.begin(), sources.end());
    if (items->empty()) return;
    fprintf(stderr, "[gnm-draw] warming up %zu cached shaders in the background (%zu from the library store, %zu from MSL)\n",
            items->size(), n_stored, items->size() - n_stored);
    id<MTLDevice> dev = S.dev;
    const NSUInteger workers = std::max<NSUInteger>(1, [[NSProcessInfo processInfo] activeProcessorCount] / 2);
    auto next = std::make_shared<std::atomic<size_t>>(0);
    auto done = std::make_shared<std::atomic<size_t>>(0);
    auto store_done = std::make_shared<std::atomic<size_t>>(0);
    const double t0 = CFAbsoluteTimeGetCurrent();
    for (NSUInteger w = 0; w < workers; ++w) {
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            for (size_t i; (i = next->fetch_add(1)) < items->size();) {
                const Item& it = (*items)[i];
                @autoreleasepool {
                    bool skip;
                    {
                        std::lock_guard<std::mutex> lk(S.async_mu);
                        skip = S.prewarm_taken.count(it.key.h1) != 0;
                    }
                    if (skip) {
                    } else if (it.store) {
                        ps4gnm_lib_store::Key full;
                        uint32_t stage = 0;
                        id<MTLFunction> fn = nil;
                        if (ps4gnm_lib_store::Peek(it.key, &full, &stage)) fn = ps4gnm_lib_store::Load(full, stage, nullptr);
                        if (fn) {
                            std::lock_guard<std::mutex> lk(S.async_mu);
                            if (!S.prewarm_taken.count(full.h1)) S.prewarmed[full.h1] = {full.h2, nil, fn};
                        }
                    } else {
                        NSString* src = [NSString stringWithContentsOfFile:[NSString stringWithUTF8String:it.path.c_str()]
                                                                  encoding:NSUTF8StringEncoding error:nil];
                        const char* c = src ? src.UTF8String : nullptr;
                        const uint64_t mh = c ? Fnv(c, strlen(c)) : 0;
                        id<MTLLibrary> lib = c ? [dev newLibraryWithSource:src options:CompileOptions() error:nil] : nil;
                        if (lib) {
                            std::lock_guard<std::mutex> lk(S.async_mu);
                            if (!S.prewarm_taken.count(mh)) S.prewarmed[mh] = {0, lib, nil};
                        }
                    }
                }
                if (i < n_stored && store_done->fetch_add(1) + 1 == n_stored)
                    fprintf(stderr, "[gnm-draw] shader warm-up: %zu libraries from the store ready in %.2f s\n", n_stored,
                            CFAbsoluteTimeGetCurrent() - t0);
                if (done->fetch_add(1) + 1 == items->size())
                    fprintf(stderr, "[gnm-draw] shader warm-up finished: %zu shaders in %.1f s\n", items->size(),
                            CFAbsoluteTimeGetCurrent() - t0);
            }
        });
    }
}

// Applies finished background compilations (called on the submitting thread).
Shader* FinishShader(gcn_shader* sh, gcn_hw_stage hw, uint64_t code_addr, uint64_t key, uint64_t fail_key,
                     bool allow_async, double t0);

void DrainAsyncCompiles() {
    // shader side (CP thread); finished pipelines are taken by DrainAsyncPsos (encoder)
    std::vector<State::AsyncLib> libs;
    std::vector<State::AsyncPso> psos;
    std::vector<std::shared_ptr<State::GcnJob>> jobs;
    if (S.async_shaders_ready.load(std::memory_order_acquire) == 0) return;
    {
        std::lock_guard<std::mutex> lk(S.async_mu);
        S.async_shaders_ready.store(0, std::memory_order_relaxed);
        if (S.async_libs_done.empty() && S.async_gcn_done.empty()) return;
        libs.swap(S.async_libs_done);
        jobs.swap(S.async_gcn_done);
    }
    for (auto& j : jobs) {
        S.gcn_pending.erase(j->pend_key);
        if (!j->sh) {
            RLog("compile-fail", "shader 0x%llx (hw %u) failed to compile: status %d: %s",
                 (unsigned long long)j->code_addr, j->hw, j->status, j->err.c_str());
            S.shader_fail.insert(j->fail_key);
            continue;
        }
        FinishShader(j->sh, j->hw, j->code_addr, j->key, j->fail_key, true, CFAbsoluteTimeGetCurrent());
    }
    for (auto& r : libs) {
        auto it = S.libs_pending.find(r.mh);
        if (it == S.libs_pending.end()) continue;
        if (r.lib) S.libs[r.mh] = r.lib;
        for (Shader* sh : it->second) {
            sh->pending = false;
            if (r.lib) sh->fn = [r.lib newFunctionWithName:@"main0"];
            if (!sh->fn) {
                RLog("msl-fail", "Metal rejected MSL of shader 0x%llx (hw %u): %s", (unsigned long long)sh->code_addr,
                     sh->hw, r.err ? r.err.UTF8String : "no main0");
                S.shader_fail.insert(sh->fail_key);
            }
        }
        S.libs_pending.erase(it);
    }
}

bool UsesStoredFn(const Shader* s);
bool ReplaceStoredFns(const Shader* vs, const Shader* ps);

void DrainAsyncPsos() {
    std::vector<State::AsyncPso> psos;
    if (S.async_psos_ready.load(std::memory_order_acquire) == 0) return;
    {
        std::lock_guard<std::mutex> lk(S.async_mu);
        S.async_psos_ready.store(0, std::memory_order_relaxed);
        if (S.async_psos_done.empty()) return;
        psos.swap(S.async_psos_done);
    }
    for (auto& r : psos) {
        S.psos_pending.erase(r.key);
        if (!r.pso && (r.retry_vs || r.retry_ps)) {
            // built with a stored function: compile its MSL; the next draw builds the pipeline again
            if (ReplaceStoredFns(r.retry_vs, r.retry_ps)) continue;
        }
        if (!r.pso)
            RLog("pso-fail", "render pipeline failed: %s", r.err ? r.err.UTF8String : "unknown error");
        S.gfx_pipes[r.key] = r.pso;
    }
}

bool StoreMslInDiskCache(uint64_t mh, const char* msl);

// The MSL that is compiled for a translated shader: the recompiler's output after the renderer's
// post-processing (its hash keys the MSL cache, the library store and the pipelines).
std::string FinalMsl(const gcn_shader* sh, uint32_t hw) {
    // SPIRV-Cross implements SPIR-V NoContraction with [[clang::optnone]] helper functions
    // (spvFMul/spvFAdd/...), i.e. a real function call per float op on the GPU. Dropping the
    // attribute lets the compiler inline them (fma contraction may change the last ulp).
    static const bool keep_optnone = getenv("PS4_GNM_KEEP_OPTNONE") != nullptr;
    std::string msl_str = gcn_shader_msl(sh);
    if (!keep_optnone) {
        const std::string tag = "[[clang::optnone]] ";
        for (size_t pos; (pos = msl_str.find(tag)) != std::string::npos;) msl_str.erase(pos, tag.size());
    }
    // Vertex positions must be bit-identical between pipelines that draw the same geometry
    // (depth pre-pass followed by a depth-EQUAL pass), like invariant/precise positions on the
    // console: mark the position output invariant (compiled with preserveInvariance).
    if (hw == GCN_HW_VS) {
        const std::string pos = "[[position]]";
        for (size_t at = 0; (at = msl_str.find(pos, at)) != std::string::npos; at += 23)
            msl_str.replace(at, pos.size(), "[[position, invariant]]");
    }
    return msl_str;
}

// The function a pipeline is built with (encoder thread): the shader's own, or the one compiled
// from MSL after its stored function failed in a pipeline.
id<MTLFunction> PipelineFn(const Shader* s) {
    if (!s) return nil;
    if (s->kjob) return s->kjob->Wait(); // DispatchEncode waited for it already
    if (s->from_store)
        if (auto it = S.fallback_fns.find(s->msl_hash); it != S.fallback_fns.end()) return it->second;
    return s->fn;
}

// True if the shader's pipelines are built with a function loaded from the library store.
bool UsesStoredFn(const Shader* s) {
    return s && s->from_store && !S.fallback_fns.count(s->msl_hash);
}

// Compiles a shader's MSL for its pipelines (encoder thread); false if it does not compile.
bool CompileFallbackFn(const Shader* s) {
    const std::string msl = FinalMsl(s->sh, s->hw);
    NSError* e = nil;
    const double t0 = CFAbsoluteTimeGetCurrent();
    id<MTLLibrary> lib = [S.dev newLibraryWithSource:@(msl.c_str()) options:CompileOptions() error:&e];
    g_compile.lib_sync.Add((CFAbsoluteTimeGetCurrent() - t0) * 1000.0);
    id<MTLFunction> fn = [lib newFunctionWithName:@"main0"];
    S.fallback_fns[s->msl_hash] = fn; // nil too: the shader is not retried again
    g_compile.store_fallbacks++;
    if (!fn)
        RLog("msl-fail", "shader 0x%llx: MSL of a failed stored library does not compile: %s",
             (unsigned long long)s->code_addr, e ? e.localizedDescription.UTF8String : "no main0");
    return fn != nil;
}

// One pipeline failed (encoder thread). Of its shaders, those whose pipelines are built with a
// stored function get their MSL compiled instead, and their store entries are deleted and
// reported as one failure toward the store's session circuit breaker
// (ps4gnm_lib_store::ReportPipelineFailure). False if no shader used a stored function (the
// failure is not the store's) or an MSL does not compile; true: build the pipeline again.
bool ReplaceStoredFns(const Shader* vs, const Shader* ps) {
    const bool v = UsesStoredFn(vs), f = UsesStoredFn(ps);
    if (!v && !f) return false;
    ps4gnm_lib_store::ReportPipelineFailure(v ? &vs->lib_key : nullptr, f ? &ps->lib_key : nullptr);
    bool ok = true;
    if (v) ok = CompileFallbackFn(vs) && ok;
    if (f) ok = CompileFallbackFn(ps) && ok;
    return ok;
}

// Second half of shader creation: reflection, MSL post-processing and the Metal library
// (from the cache, the warm-up set, a background compile, or synchronously).
Shader* FinishShader(gcn_shader* sh, gcn_hw_stage hw, uint64_t code_addr, uint64_t key, uint64_t fail_key,
                     bool allow_async, double t0) {
    auto& vec = S.shaders[key];
    Shader* s = new Shader();
    s->sh = sh;
    s->hw = hw;
    s->code_addr = code_addr;
    s->uid = S.next_uid++;
    gcn_shader_get_info(sh, &s->info);
    s->bufs.resize(s->info.num_buffers);
    for (uint32_t i = 0; i < s->info.num_buffers; ++i) gcn_shader_get_buffer(sh, i, &s->bufs[i]);
    s->imgs.resize(s->info.num_images);
    for (uint32_t i = 0; i < s->info.num_images; ++i) gcn_shader_get_image(sh, i, &s->imgs[i]);
    s->samps.resize(s->info.num_samplers);
    for (uint32_t i = 0; i < s->info.num_samplers; ++i) gcn_shader_get_sampler(sh, i, &s->samps[i]);
    s->attrs.resize(s->info.num_vertex_attribs);
    for (uint32_t i = 0; i < s->info.num_vertex_attribs; ++i)
        gcn_shader_get_vertex_attrib(sh, i, &s->attrs[i]);

    const std::string msl_str = FinalMsl(sh, hw);
    const char* msl = msl_str.c_str();
    DumpMsl(s, msl);
    const uint64_t mh = Fnv(msl, msl_str.size());
    s->msl_hash = mh;
    s->lib_key = ps4gnm_lib_store::MakeKey(msl, msl_str.size());
    s->lib_stage = StoreStage(hw);
    s->fail_key = fail_key;
    // The function, in this order: built earlier in the session, made ready by the warm-up, loaded
    // from the library store (about a millisecond, no compiler), compiled from the MSL.
    id<MTLLibrary> lib = nil;
    id<MTLFunction> stored_fn = nil;
    const bool store_on = ps4gnm_lib_store::Enabled(); // false once its circuit breaker tripped
    if (auto fit = S.store_fns.find(mh); store_on && fit != S.store_fns.end()) {
        stored_fn = fit->second;
    } else if (auto lit = S.libs.find(mh); lit != S.libs.end()) {
        lib = lit->second;
    } else {
        {
            std::lock_guard<std::mutex> lk(S.async_mu);
            auto pit = S.prewarmed.find(mh);
            if (pit != S.prewarmed.end()) {
                if (pit->second.fn ? store_on && pit->second.h2 == s->lib_key.h2 : pit->second.lib != nil) {
                    lib = pit->second.lib;
                    stored_fn = pit->second.fn;
                    g_compile.lib_prewarmed++;
                }
                S.prewarmed.erase(pit);
            }
        }
        if (!lib && !stored_fn && s->lib_stage && ps4gnm_lib_store::Has(s->lib_key)) {
            const double ld_t0 = CFAbsoluteTimeGetCurrent();
            stored_fn = ps4gnm_lib_store::Load(s->lib_key, s->lib_stage, nullptr);
            const double ld_ms = (CFAbsoluteTimeGetCurrent() - ld_t0) * 1000.0;
            g_hitch.mtl_ms += ld_ms;
            g_compile.lib_store.Add(ld_ms);
        }
        if (stored_fn) {
            S.store_fns[mh] = stored_fn;
        } else if (lib) {
            S.libs[mh] = lib;
        }
        {
            std::lock_guard<std::mutex> lk(S.async_mu);
            S.prewarm_taken.insert(mh);
        }
        if (lib || stored_fn) {
            char path[1200];
            snprintf(path, sizeof(path), "%s/%016llx.metal", S.msl_cache_dir.c_str(), (unsigned long long)mh);
            ps4gnm_shader_cache::MarkUsed(path);
        }
    }
    bool msl_known = false;
    if (!lib && !stored_fn) msl_known = !StoreMslInDiskCache(mh, msl);
    // MSL compiled in an earlier session is cheap to compile again (Metal's shader cache), so
    // only new shaders are compiled in the background. The same MSL already compiling in the
    // background (another permutation or address of the program, in this session) waits for
    // that compile instead of compiling it again inside the frame.
    const bool compiling = !lib && !stored_fn && S.libs_pending.count(mh) != 0;
    if (!lib && !stored_fn && allow_async && S.async_compile && (!msl_known || compiling)) {
        // Compile the Metal library in the background; draws using this shader are skipped
        // until it is ready instead of stalling the frame (a cold Metal compile can take
        // 100+ ms per shader, and new areas bring dozens at once).
        s->pending = true;
        auto& waiters = S.libs_pending[mh];
        const bool first = waiters.empty();
        waiters.push_back(s);
        if (first) {
            g_compile.lib_async++;
            auto done = [mh](id<MTLLibrary> l, NSString* err) {
                std::lock_guard<std::mutex> lk(S.async_mu);
                S.async_libs_done.push_back({mh, l, l ? nil : err});
                S.async_shaders_ready.fetch_add(1, std::memory_order_release);
            };
            if (S.kernels) {
                // the shared compile queue: bounded, behind the kernels dispatches wait for
                bool started = false;
                auto job = S.kernels->Start(mh, msl_str, &started, ps4gnm_kernels::Compiler::kDraw,
                                            [done](const ps4gnm_kernels::Job& j) {
                                                id<MTLLibrary> l = j.Library();
                                                done(l, l ? nil : @(j.Error().c_str()));
                                            });
                // compiled before in this session (a failed library is not cached in S.libs):
                // the waiters take that result (the job of an MSL is never in flight here,
                // libs_pending holds its waiters until it is done)
                if (!started && job->Done()) {
                    done(job->Library(), job->Library() ? nil : @(job->Error().c_str()));
                } else if (!started) {
                    // not expected (see above); its draws would wait for a callback that never comes
                    RLog("msl-fail", "shader MSL %016llx: compile job of another caller still in flight; draws skipped",
                         (unsigned long long)mh);
                }
            } else {
                [S.dev newLibraryWithSource:[NSString stringWithUTF8String:msl]
                                    options:CompileOptions()
                          completionHandler:^(id<MTLLibrary> l, NSError* e) {
                              done(l, l ? nil : e.localizedDescription);
                          }];
            }
        }
    } else if (!lib && !stored_fn && hw == GCN_HW_CS && S.kernels) {
        // A dispatch is not optional (later passes read its results), so it is not skipped
        // while its kernel compiles: the compile starts here, and the encoder waits for it when
        // it reaches the dispatch. The CP thread goes on with the command stream meanwhile, and
        // kernels met before the encoder catches up compile in parallel.
        s->kjob = S.kernels->Start(mh, msl_str);
        if (s->kjob->Done() && !s->kjob->Wait()) {
            // the same MSL failed before in this session
            RLog("msl-fail", "Metal rejected MSL of shader 0x%llx (hw %u): %s", (unsigned long long)code_addr, hw,
                 s->kjob->Error().c_str());
            gcn_shader_destroy(sh);
            delete s;
            S.shader_fail.insert(fail_key);
            return nullptr;
        }
    } else if (!lib && !stored_fn) {
        NSError* e = nil;
        const double mtl_t0 = CFAbsoluteTimeGetCurrent();
        lib = [S.dev newLibraryWithSource:[NSString stringWithUTF8String:msl] options:CompileOptions() error:&e];
        g_hitch.mtl_ms += (CFAbsoluteTimeGetCurrent() - mtl_t0) * 1000.0;
        g_compile.lib_sync.Add((CFAbsoluteTimeGetCurrent() - mtl_t0) * 1000.0);
        if (!lib) {
            RLog("msl-fail", "Metal rejected MSL of shader 0x%llx (hw %u): %s",
                 (unsigned long long)code_addr, hw, e.localizedDescription.UTF8String);
            gcn_shader_destroy(sh);
            delete s;
            S.shader_fail.insert(fail_key);
            return nullptr;
        }
        S.libs[mh] = lib;
    }
    if (stored_fn) {
        s->fn = stored_fn;
        s->from_store = true;
    } else if (lib) {
        const double fn_t0 = CFAbsoluteTimeGetCurrent();
        s->fn = [lib newFunctionWithName:@"main0"];
        g_hitch.fn_ms += (CFAbsoluteTimeGetCurrent() - fn_t0) * 1000.0;
    }
    if (!s->fn && !s->pending && !s->kjob) {
        RLog("msl-fail", "shader 0x%llx: no main0", (unsigned long long)code_addr);
        gcn_shader_destroy(sh);
        delete s;
        S.shader_fail.insert(fail_key);
        return nullptr;
    }
    const double ms = (CFAbsoluteTimeGetCurrent() - t0) * 1000.0;
    g_hitch.shader_ms += ms;
    g_hitch.shaders++;
    RLog("compiled", "compiled %s shader 0x%llx perm %zu: %u bufs %u imgs %u samplers %u attribs%s "
                     "(%.0f ms)",
         hw == GCN_HW_VS ? "VS" : hw == GCN_HW_PS ? "PS" : hw == GCN_HW_CS ? "CS" : "??",
         (unsigned long long)code_addr, vec.size(), s->info.num_buffers, s->info.num_images,
         s->info.num_samplers, s->info.num_vertex_attribs,
         s->info.translation_failed ? " [translation incomplete]" : "", ms);
    vec.push_back(s);
    return s;
}

// Identifies the program currently stored at a shader address. Games reuse shader memory for
// different programs (e.g. when they switch render paths), so the address alone is not a key.
// Compiled PS4 shaders start with "s_mov_b32 vcc_hi, <offset>" pointing at the OrbShdr binary
// info, which holds the shader hash; other code is identified by its first 64 bytes.
uint64_t CodeSignature(uint64_t code_addr) {
    uint32_t head[2];
    if (!ReadGuest(S.ctx, code_addr, head, sizeof(head))) return 0;
    if (head[0] == 0xBEEB03FFu) {
        uint32_t size = 0;
        uint64_t hash = 0;
        if (gcn_find_binary_info(ReadGuest, S.ctx, code_addr, &size, &hash) && hash)
            return hash ^ ((uint64_t)size << 32);
    }
    uint8_t prefix[64];
    if (!ReadGuest(S.ctx, code_addr, prefix, sizeof(prefix))) return 0;
    return Fnv(prefix, sizeof(prefix));
}

Shader* GetShader(gcn_hw_stage hw, gcn_sw_stage sw, const gcn_runtime_info& rt, uint64_t code_addr,
                  const uint32_t ud[16], bool allow_async = false) {
    if (code_addr == 0 || code_addr >= S.ctx->mem_size) return nullptr;
    const uint64_t sig = CodeSignature(code_addr);
    const uint64_t key = Fnv(&sig, sizeof(sig), code_addr ^ ((uint64_t)hw << 58));
    auto& vec = S.shaders[key];
    const int fi = hw == GCN_HW_VS ? 0 : hw == GCN_HW_PS ? 1 : hw == GCN_HW_CS ? 2 : -1;
    if (fi >= 0) S.flat_from[fi] = nullptr;
    if (!vec.empty()) {
        const gcn_shader* list[64];
        const uint32_t n = (uint32_t)std::min<size_t>(vec.size(), 64);
        for (uint32_t i = 0; i < n; ++i) list[i] = vec[i]->sh;
        int hit;
        if (fi >= 0) {
            // walk the pointer chains once: the flattened user data serves the check here and
            // the binding of the draw
            BuildFlat(vec[0], ud, &S.flat_scratch[fi]);
            S.flat_from[fi] = vec[0];
            hit = gcn_shader_find_compatible_flat(list, n, ud, S.flat_scratch[fi].data(), S.flat_scratch[fi].size(),
                                                  &rt, ReadGuest, S.ctx);
        } else {
            hit = gcn_shader_find_compatible(list, n, ud, &rt, ReadGuest, S.ctx);
        }
        if (hit >= 0) return vec[hit];
    }
    const uint64_t fail_key = Fnv(&rt, sizeof(rt), key * 1000003ull);
    if (S.shader_fail.count(fail_key)) return nullptr;
    if (vec.size() >= 48) {
        RLog("perm", "too many permutations for shader 0x%llx stage %u", (unsigned long long)code_addr, hw);
        return nullptr;
    }

    // A translation of this permutation is already in flight.
    const uint64_t pend_key = Fnv(ud, 64, Fnv(&rt, sizeof(rt), key));
    if (allow_async && S.async_compile && S.gcn_pending.count(pend_key)) return &S.pending_shader;

    // Persistent translation cache: a permutation translated in an earlier session that is
    // compatible with this draw replaces the translation (synchronously, it is cheap).
    namespace sc = ps4gnm_shader_cache;
    sc::Key ckey;
    const bool cacheable = sc::Enabled() && sc::MakeKey(hw, sw, rt, code_addr, ReadGuest, S.ctx, &ckey);
    if (cacheable) {
        const double t0 = CFAbsoluteTimeGetCurrent();
        gcn_shader* sh = sc::Lookup(ckey, code_addr, ud, ReadGuest, S.ctx);
        g_hitch.lookup_ms += (CFAbsoluteTimeGetCurrent() - t0) * 1000.0;
        if (sh) {
            if (sc::VerifyMode()) {
                // Debug: the cached shader must equal a fresh translation of this draw.
                static double cache_ms = 0, gcn_ms = 0;
                const double t1 = CFAbsoluteTimeGetCurrent();
                cache_ms += (t1 - t0) * 1000.0;
                gcn_compile_desc vd{};
                vd.hw_stage = hw;
                vd.sw_stage = sw;
                vd.code_addr = code_addr;
                memcpy(vd.user_data, ud, 64);
                vd.runtime = &rt;
                vd.profile = &S.profile;
                vd.read_guest = ReadGuest;
                vd.read_ctx = S.ctx;
                vd.flags = GCN_COMPILE_EMIT_MSL;
                vd.msl = &S.msl;
                char verr[256] = {0};
                gcn_shader* fresh = nullptr;
                std::string why;
                const gcn_status vst = gcn_compile(&vd, &fresh, verr, sizeof(verr));
                gcn_ms += (CFAbsoluteTimeGetCurrent() - t1) * 1000.0;
                if (vst != GCN_OK)
                    why = std::string("fresh translation failed: ") + verr;
                else if (!sc::SameTranslation(sh, fresh, &why))
                    why = "differs in " + why;
                if (fresh) gcn_shader_destroy(fresh);
                if (why.empty())
                    RLog("gcn-cache-verify",
                         "cached %s shader 0x%llx matches a fresh translation (so far: cache %.1f ms, "
                         "translation %.1f ms)",
                         hw == GCN_HW_VS ? "VS" : hw == GCN_HW_PS ? "PS" : hw == GCN_HW_CS ? "CS" : "??",
                         (unsigned long long)code_addr, cache_ms, gcn_ms);
                else
                    fprintf(stderr, "[gnm-draw] gcn cache verify: shader 0x%llx (hw %u): %s\n",
                            (unsigned long long)code_addr, hw, why.c_str());
            }
            return FinishShader(sh, hw, code_addr, key, fail_key, allow_async, t0);
        }
    }

    // A further permutation of a program is translated here, for this draw. Translated on the
    // worker, Uncharted 4's UI vertex shader got permutations that did not fit the draws that
    // asked for them (buffer stride 12 for a stride 32 draw): one new permutation per draw up to
    // the cap of 48, then its draws were skipped (~60 per frame at the first-boot menu). A
    // translation specializes on sharps read through the draw's pointer chains, in memory the
    // game rewrites per draw, so read later they likely belong to another draw (a copy of the
    // existing permutation's SRT reads did not cover them). New programs, the bulk of a new
    // area, still go to the worker.
    if (allow_async && S.async_compile && vec.empty()) {
        // Translate GCN -> MSL on a worker thread (1-2 ms per shader, but new areas bring
        // hundreds at once); draws using it are skipped until the result is applied.
        S.gcn_pending.insert(pend_key);
        auto job = std::make_shared<State::GcnJob>();
        job->hw = hw;
        job->sw = sw;
        job->rt = rt;
        job->code_addr = code_addr;
        memcpy(job->ud, ud, 64);
        job->key = key;
        job->fail_key = fail_key;
        job->pend_key = pend_key;
        job->cache_store = cacheable;
        if (cacheable) job->cache_key = ckey;
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            gcn_compile_desc jd{};
            jd.hw_stage = job->hw;
            jd.sw_stage = job->sw;
            jd.code_addr = job->code_addr;
            memcpy(jd.user_data, job->ud, 64);
            jd.runtime = &job->rt;
            jd.profile = &S.profile;
            jd.read_guest = ReadGuest;
            jd.read_ctx = S.ctx;
            jd.flags = GCN_COMPILE_EMIT_MSL;
            jd.msl = &S.msl;
            char jerr[1024] = {0};
            gcn_status st = gcn_compile(&jd, &job->sh, jerr, sizeof(jerr));
            if (st != GCN_OK) {
                if (job->sh) gcn_shader_destroy(job->sh);
                job->sh = nullptr;
                job->err = jerr;
                job->status = (int)st;
            } else if (job->cache_store) {
                ps4gnm_shader_cache::Store(job->cache_key, job->sh);
            }
            std::lock_guard<std::mutex> lk(S.async_mu);
            S.async_gcn_done.push_back(job);
            S.async_shaders_ready.fetch_add(1, std::memory_order_release);
        });
        return &S.pending_shader;
    }

    gcn_compile_desc d{};
    d.hw_stage = hw;
    d.sw_stage = sw;
    d.code_addr = code_addr;
    memcpy(d.user_data, ud, 64);
    d.runtime = &rt;
    d.profile = &S.profile;
    d.read_guest = ReadGuest;
    d.read_ctx = S.ctx;
    d.flags = GCN_COMPILE_EMIT_MSL;
    d.msl = &S.msl;
    char err[1024] = {0};
    gcn_shader* sh = nullptr;
    const double t0 = CFAbsoluteTimeGetCurrent();
    const gcn_status st = gcn_compile(&d, &sh, err, sizeof(err));
    g_hitch.gcn_ms += (CFAbsoluteTimeGetCurrent() - t0) * 1000.0;
    if (st != GCN_OK) {
        RLog("compile-fail", "shader 0x%llx (hw %u) failed to compile: status %d: %s",
             (unsigned long long)code_addr, hw, (int)st, err);
        if (sh) gcn_shader_destroy(sh);
        S.shader_fail.insert(fail_key);
        return nullptr;
    }
    if (cacheable) sc::Store(ckey, sh);
    return FinishShader(sh, hw, code_addr, key, fail_key, allow_async, t0);
}


// =====================================================================================
// Resource binding (shadPS4 Rasterizer::BindBuffers / BindTextures)
// =====================================================================================
enum class Stage { Vertex, Fragment, Compute };

// The state last set on the open render / compute encoder (S.renc / S.cenc), so that draws and
// dispatches skip identical calls: each is an Objective-C message into the driver, and resource
// bindings also add the resource to the command buffer's list. Reset when the encoder is
// created and by code that sets state on it directly. The objects compared by address are
// alive: the command buffer retains everything bound to its encoders.
struct EncoderState {
    struct Slot {
        const void* p = nullptr;
        NSUInteger off = 0;
        uint32_t gen = 0;
    };
    const void* enc = nullptr; // the encoder described
    uint32_t gen = 1;          // slots of other generations are unknown
    Slot buf[3][31], tex[3][128], samp[3][16];
    Slot pso, dss;
    // fixed-function state of a render encoder
    struct Fixed {
        MTLViewport vp;
        MTLScissorRect sc;
        uint32_t stencil_ref[2];
        uint32_t cull, winding, fill, clip;
        float bias[3];
        float blend[4];
    } fixed;
    uint32_t fixed_gen = 0;
    bool fixed_stencil = false; // fixed.stencil_ref is set
    struct Used {
        const void* p;
        uint32_t how;
    } used[32];
    uint32_t n_used = 0;

    void Reset(id e) {
        enc = (__bridge const void*)e;
        ++gen;
        n_used = 0;
    }
    bool Tracks(id e) const { return e && (__bridge const void*)e == enc; }
    // true if the slot already holds p; records p otherwise
    bool Same(Slot& sl, const void* p) {
        if (sl.gen == gen && sl.p == p) return true;
        sl.p = p;
        sl.gen = gen;
        return false;
    }
};
EncoderState g_rstate, g_cstate;

struct Binder {
    Stage stage;
    id<MTLRenderCommandEncoder> r;
    id<MTLComputeCommandEncoder> c;
    EncoderState* Tracked() const {
        if (stage == Stage::Compute) return g_cstate.Tracks(c) ? &g_cstate : nullptr;
        return g_rstate.Tracks(r) ? &g_rstate : nullptr;
    }
    void Buffer(id<MTLBuffer> b, NSUInteger off, uint32_t slot) {
        if (slot > 30) return;
        if (EncoderState* es = Tracked()) {
            EncoderState::Slot& sl = es->buf[(int)stage][slot];
            if (sl.gen == es->gen && sl.p == (__bridge const void*)b) {
                if (sl.off == off || !b) return;
                sl.off = off;
                if (stage == Stage::Vertex) [r setVertexBufferOffset:off atIndex:slot];
                else if (stage == Stage::Fragment) [r setFragmentBufferOffset:off atIndex:slot];
                else [c setBufferOffset:off atIndex:slot];
                return;
            }
            sl.p = (__bridge const void*)b;
            sl.off = off;
            sl.gen = es->gen;
        }
        if (stage == Stage::Vertex) [r setVertexBuffer:b offset:off atIndex:slot];
        else if (stage == Stage::Fragment) [r setFragmentBuffer:b offset:off atIndex:slot];
        else [c setBuffer:b offset:off atIndex:slot];
    }
    // Residency (+ hazard tracking) of a buffer reached through an argument buffer.
    void Use(id<MTLBuffer> b, bool written) {
        const MTLResourceUsage u = written ? (MTLResourceUsageRead | MTLResourceUsageWrite) : MTLResourceUsageRead;
        if (EncoderState* es = Tracked()) {
            const uint32_t how = (uint32_t)u | ((uint32_t)stage << 8);
            for (uint32_t i = 0; i < es->n_used; ++i)
                if (es->used[i].p == (__bridge const void*)b && es->used[i].how == how) return;
            if (es->n_used < 32) es->used[es->n_used++] = {(__bridge const void*)b, how};
        }
        if (stage == Stage::Compute) [c useResource:b usage:u];
        else [r useResource:b usage:u stages:(stage == Stage::Vertex ? MTLRenderStageVertex : MTLRenderStageFragment)];
    }
    void Bytes(const void* p, size_t n, uint32_t slot) {
        if (slot > 30) return;
        if (EncoderState* es = Tracked()) es->buf[(int)stage][slot].gen = 0; // replaced by the bytes
        if (n > 4096) {
            id<MTLBuffer> b;
            size_t off;
            void* ptr;
            if (!S.arena.Alloc(S.dev, n, 256, &b, &off, &ptr)) return;
            memcpy(ptr, p, n);
            Buffer(b, off, slot);
            return;
        }
        if (stage == Stage::Vertex) [r setVertexBytes:p length:n atIndex:slot];
        else if (stage == Stage::Fragment) [r setFragmentBytes:p length:n atIndex:slot];
        else [c setBytes:p length:n atIndex:slot];
    }
    void Texture(id<MTLTexture> t, uint32_t slot) {
        if (slot > 127) return;
        if (EncoderState* es = Tracked(); es && es->Same(es->tex[(int)stage][slot], (__bridge const void*)t)) return;
        if (stage == Stage::Vertex) [r setVertexTexture:t atIndex:slot];
        else if (stage == Stage::Fragment) [r setFragmentTexture:t atIndex:slot];
        else [c setTexture:t atIndex:slot];
    }
    void Sampler(id<MTLSamplerState> s, uint32_t slot) {
        if (slot > 15) return;
        if (EncoderState* es = Tracked(); es && es->Same(es->samp[(int)stage][slot], (__bridge const void*)s)) return;
        if (stage == Stage::Vertex) [r setVertexSamplerState:s atIndex:slot];
        else if (stage == Stage::Fragment) [r setFragmentSamplerState:s atIndex:slot];
        else [c setSamplerState:s atIndex:slot];
    }
};

MTLTextureType ShaderTextureType(const gcn_image_binding& b) {
    switch (b.view_type) {
    case 8: return MTLTextureType1D;
    case 12: return MTLTextureType1DArray;
    case 10: return MTLTextureType3D;
    case 11: return b.post_op == GCN_POSTOP_CUBE_TO_2D_ARRAY ? MTLTextureType2DArray : MTLTextureTypeCube;
    case 13: return MTLTextureType2DArray;
    case 14: return MTLTextureType2DMultisample;
    case 15: return MTLTextureType2DMultisampleArray;
    case 9:
    default: return b.is_array ? MTLTextureType2DArray : MTLTextureType2D;
    }
}

id<MTLTexture> AdaptTextureUncached(id<MTLTexture> t, MTLTextureType want, const ImageDesc& img,
                                    uint32_t level, uint32_t nlevels) {
    if (!t) return nil;
    const bool type_ok = t.textureType == want;
    const bool level_ok = (level == 0 && (nlevels == 0 || nlevels >= t.mipmapLevelCount));
    // T# BASE_ARRAY / LAST_ARRAY select the slices of a 2D array the shader sees (e.g. one
    // layer of a shadow map array sampled as a plain 2D texture).
    const bool arr = t.textureType == MTLTextureType2DArray &&
                     (want == MTLTextureType2D || want == MTLTextureType2DArray);
    const NSUInteger first = arr ? std::min<NSUInteger>(img.base_array, t.arrayLength - 1) : 0;
    const NSUInteger last = arr ? std::min<NSUInteger>(std::max(img.last_array, img.base_array), t.arrayLength - 1)
                                : 0;
    const bool slices_ok = !arr || (first == 0 && last == t.arrayLength - 1);
    if (type_ok && level_ok && slices_ok) return t;
    // compatible view types (Metal texture view rules)
    auto compatible = [&](MTLTextureType from, MTLTextureType to) {
        if (from == to) return true;
        const bool from2d = from == MTLTextureType2D || from == MTLTextureType2DArray ||
                            from == MTLTextureTypeCube || from == MTLTextureTypeCubeArray;
        const bool to2d = to == MTLTextureType2D || to == MTLTextureType2DArray ||
                          to == MTLTextureTypeCube || to == MTLTextureTypeCubeArray;
        if (from2d && to2d) {
            const NSUInteger nslices = (from == MTLTextureTypeCube || from == MTLTextureTypeCubeArray)
                                           ? t.arrayLength * 6 : t.arrayLength;
            if ((to == MTLTextureTypeCube || to == MTLTextureTypeCubeArray) && nslices < 6) return false;
            return true;
        }
        const bool from1d = from == MTLTextureType1D || from == MTLTextureType1DArray;
        const bool to1d = to == MTLTextureType1D || to == MTLTextureType1DArray;
        return from1d && to1d;
    };
    if (!compatible(t.textureType, want)) {
        RLog("tex-type", "texture type mismatch: have %lu want %lu (T# type %u, %ux%u)",
             (unsigned long)t.textureType, (unsigned long)want, (uint32_t)img.type, img.width, img.height);
        return nil;
    }
    NSUInteger slices = t.textureType == MTLTextureTypeCube ? 6
                        : t.textureType == MTLTextureTypeCubeArray ? t.arrayLength * 6
                                                                    : t.arrayLength;
    if (want == MTLTextureType2D || want == MTLTextureType1D) slices = 1;
    if (want == MTLTextureTypeCube) slices = 6;
    if (want == MTLTextureTypeCubeArray) slices = (slices / 6) * 6;
    if (slices == 0) return nil;
    if (arr) slices = want == MTLTextureType2D ? 1 : last - first + 1;
    const NSUInteger lv = std::min<NSUInteger>(level, t.mipmapLevelCount - 1);
    const NSUInteger nl = nlevels ? std::min<NSUInteger>(nlevels, t.mipmapLevelCount - lv) : t.mipmapLevelCount - lv;
    id<MTLTexture> v = [t newTextureViewWithPixelFormat:t.pixelFormat
                                            textureType:want
                                                 levels:NSMakeRange(lv, nl)
                                                 slices:NSMakeRange(first, slices)];
    return v;
}

// AdaptTexture results by (texture, view type, levels, T# slice range): creating a view on every
// draw shows up in profiles. Cached views keep their textures alive, so the cache is emptied
// every 60 presents (and when it grows large) to let evicted textures go.
struct ViewKey {
    void* tex;
    uint32_t want, level, nlevels, base_array, last_array;
    bool operator==(const ViewKey& o) const {
        return tex == o.tex && want == o.want && level == o.level && nlevels == o.nlevels &&
               base_array == o.base_array && last_array == o.last_array;
    }
};
struct ViewKeyHash {
    size_t operator()(const ViewKey& k) const { return (size_t)Fnv(&k, sizeof(k)); }
};
std::unordered_map<ViewKey, id<MTLTexture>, ViewKeyHash> g_view_cache;
uint64_t g_view_cache_gen = 0, g_present_gen = 0;

id<MTLTexture> AdaptTexture(id<MTLTexture> t, MTLTextureType want, const ImageDesc& img, uint32_t level,
                            uint32_t nlevels) {
    if (!t) return nil;
    if (g_present_gen - g_view_cache_gen >= 60 || g_view_cache.size() > 4096) {
        g_view_cache.clear();
        g_view_cache_gen = g_present_gen;
    }
    ViewKey k;
    memset(&k, 0, sizeof(k)); // padding is hashed
    k.tex = (__bridge void*)t;
    k.want = (uint32_t)want;
    k.level = level;
    k.nlevels = nlevels;
    k.base_array = img.base_array;
    k.last_array = img.last_array;
    auto it = g_view_cache.find(k);
    if (it != g_view_cache.end()) return it->second;
    id<MTLTexture> v = AdaptTextureUncached(t, want, img, level, nlevels);
    if (v) g_view_cache.emplace(k, v);
    return v;
}

id<MTLSamplerState> GetSampler(const uint32_t ss[4], bool compare) {
    uint64_t h = Fnv(ss, 16, compare ? 7 : 3);
    auto it = S.samplers.find(h);
    if (it != S.samplers.end()) return it->second;
    SamplerDesc sd;
    DecodeSampler(ss, &sd);
    MTLSamplerDescriptor* d = MakeSamplerDescriptor(sd, compare);
    id<MTLSamplerState> st = [S.dev newSamplerStateWithDescriptor:d];
    S.samplers[h] = st;
    return st;
}

// Image descriptor i of a stage (see StageImages below).
bool StageImage(const Shader* s, const std::vector<uint32_t>& flat, uint32_t i, ImageDesc* img,
                uint64_t* approx = nullptr);

struct BindCtx {
    const RegSnap* regs;
    uint32_t num_workgroups = 1; // compute: for the LDS-spill buffer
};

// Returns false if the draw/dispatch must be skipped.
// Flattened user data of a shader stage for the current draw/dispatch (user SGPRs plus the
// values its SRT program fetches from guest memory). Built once per stage and shared by the
// hazard check, depth companions and binding.
void BuildFlat(const Shader* s, const uint32_t ud[16], std::vector<uint32_t>* flat);

// BuildFlat for the shader chosen by GetShader, unless GetShader already built it.
void StageFlat(int fi, const Shader* s, const uint32_t ud[16]) {
    const Shader* from = S.flat_from[fi];
    S.flat_from[fi] = nullptr;
    if (from && from->info.flatbuf_size_dw == s->info.flatbuf_size_dw &&
        S.flat_scratch[fi].size() == std::max<uint32_t>(s->info.flatbuf_size_dw, 16) && !ShouldTrace())
        return;
    BuildFlat(s, ud, &S.flat_scratch[fi]);
}

void BuildFlat(const Shader* s, const uint32_t ud[16], std::vector<uint32_t>* flat) {
    flat->assign(std::max<uint32_t>(s->info.flatbuf_size_dw, 16), 0);
    static const bool dumpflat = getenv("PS4_GNM_TRACE_BUFS") != nullptr;
    g_trace_reads = dumpflat && ShouldTrace();
    gcn_shader_build_flatbuf(s->sh, ud, ReadGuest, S.ctx, flat->data(), flat->size());
    g_trace_reads = false;
}

bool BindStage(const Shader* s, const uint32_t ud[16], const std::vector<uint32_t>& flat, Binder& b,
               const BindCtx& bc, const gcn_push_data& push, std::string* why) {
    (void)ud;
    static const bool dumpflat = getenv("PS4_GNM_TRACE_BUFS") != nullptr;
    if (ShouldTrace()) {
        if (dumpflat) {
            fprintf(stderr, "[gnm-trace]    flatbuf (%u dw):", s->info.flatbuf_size_dw);
            for (uint32_t k = 0; k < flat.size() && k < 128; ++k)
                fprintf(stderr, "%s%08x", (k % 16) ? " " : "\n[gnm-trace]      ", flat[k]);
            fprintf(stderr, "\n");
        }
    }

    // Per-stage copy: buf_sizes holds this shader's guest buffer sizes. The shaders range
    // check every buffer access against them like GCN does (OOB stores/atomics dropped, OOB
    // loads return 0) - games rely on it, e.g. compute dispatches rounded up to whole thread
    // groups whose extra threads store past the end of the buffer (TLOU cloth simulation
    // clobbering the next heap block's header -> crash on world reload).
    gcn_push_data pd = push;
    static const char* bounds_mode = getenv("PS4_GNM_BOUNDS"); // debug: off | raw
    const bool bounds_off = bounds_mode && !strcmp(bounds_mode, "off");
    memset(pd.buf_sizes, bounds_off ? 0xff : 0, sizeof(pd.buf_sizes));
    // Shaders with more buffers than Metal slots reach their guest buffers through an argument
    // buffer: a table of GPU addresses (gcn_shader_info.msl_argument_buffer).
    std::vector<uint64_t> argtab(s->info.msl_argument_buffer >= 0 ? s->info.msl_argument_buffer_entries : 0,
                                 S.dummy.gpuAddress);
    if (!argtab.empty()) b.Use(S.dummy, false);
    for (uint32_t i = 0; i < s->bufs.size(); ++i) {
        const gcn_buffer_binding& bb = s->bufs[i];
        if (bb.num_msl_buffers == 0 && bb.msl_arg_index >= argtab.size()) continue;
        id<MTLBuffer> mb = nil;
        uint64_t off = 0;
        switch (bb.type) {
        case GCN_BUFFER_GUEST: {
            uint32_t v[4];
            gcn_buffer_desc bd{};
            if (gcn_shader_fetch_buffer_sharp(s->sh, i, flat.data(), s->code_addr, v)) {
                gcn_decode_buffer(v, &bd);
            }
            if (bd.base_address == 0 || bd.size_bytes == 0) {
                mb = S.dummy;
                break;
            }
            uint64_t base = bd.base_address;
            if (static const bool lb = getenv("PS4_GNM_LOG_BIGBUF") != nullptr; lb && bd.size_bytes > (1u << 20)) {
                static std::set<uint64_t> seen;
                if (seen.insert(s->code_addr * 64 + i).second)
                    fprintf(stderr, "[gnm-bigbuf] shader 0x%llx buf %u: base 0x%llx size 0x%x stride %u nrec 0x%x%s\n",
                            (unsigned long long)s->code_addr, i, (unsigned long long)bd.base_address, bd.size_bytes,
                            bd.stride, bd.num_records, bb.is_written ? " written" : "");
            }
            if (bd.size_bytes >= 0x80000000u) bd.size_bytes = 64u << 20; // "unbounded" V#
            if (base & 3) {
                RLog("buf-align", "shader 0x%llx: buffer %u not dword aligned (0x%llx)",
                     (unsigned long long)s->code_addr, i, (unsigned long long)base);
                base &= ~3ull;
            }
            if (!GuestBuffer(base, bd.size_bytes, bb.is_written ? GuestAccess::Write : GuestAccess::Read, &mb, &off)) {
                RLog("buf-range", "shader 0x%llx: buffer %u out of range (0x%llx+0x%x)",
                     (unsigned long long)s->code_addr, i, (unsigned long long)base, bd.size_bytes);
                mb = S.dummy;
                off = 0;
                break;
            }
            if (ShouldTrace()) {
                fprintf(stderr, "[gnm-trace]    buf[%u] 0x%llx size %u stride %u%s\n", i, (unsigned long long)base,
                        bd.size_bytes, bd.stride, bb.is_written ? " written" : "");
                static const bool dumpbufs = getenv("PS4_GNM_TRACE_BUFS") != nullptr;
                if (dumpbufs && bd.size_bytes <= 512) {
                    const uint32_t* w = (const uint32_t*)(S.ctx->mem_base + base);
                    for (uint32_t k = 0; k < bd.size_bytes / 4; k += 8) {
                        fprintf(stderr, "[gnm-trace]      %3u:", k);
                        for (uint32_t j = k; j < k + 8 && j < bd.size_bytes / 4; ++j) fprintf(stderr, " %08x(%g)", w[j], AsF(w[j]));
                        fprintf(stderr, "\n");
                    }
                }
            }
            if (bb.buffer_slot < GCN_MAX_BUFFERS) {
                uint32_t lim = bd.size_bytes + (uint32_t)(bd.base_address - base);
                if (bounds_off) lim = 0xffffffffu;
                else if (bounds_mode && !strcmp(bounds_mode, "raw") && bd.stride != 0) lim = 64u << 20;
                pd.buf_sizes[bb.buffer_slot] = lim;
            }
            if (static const char* ww = getenv("PS4_GNM_WATCH_WRITES"); ww && bb.is_written) {
                // debug: which shaders write a buffer containing (or ending right below) addr
                static const uint64_t wa = strtoull(ww, nullptr, 16);
                static int nlog = 0;
                if (nlog < 200 && wa >= bd.base_address && wa < bd.base_address + bd.size_bytes + 0x100000) {
                    nlog++;
                    fprintf(stderr, "[gnm-watchw] submit %llu shader 0x%llx buf %u: base 0x%llx size 0x%x stride %u "
                            "nrec %u swz %d tid %d groups %u thr %u%s\n", (unsigned long long)S.submit_idx,
                            (unsigned long long)s->code_addr, i, (unsigned long long)bd.base_address, bd.size_bytes,
                            bd.stride, bd.num_records, (int)bd.swizzle_enable, (int)bd.add_tid_enable,
                            bc.num_workgroups, (*bc.regs)[0x2E07] & 0xffff, wa < bd.base_address + bd.size_bytes ? " (inside)" : " (just past end)");
                }
            }
            if (bb.is_written) {
                NoteGpuWrite(base, bd.size_bytes);
                auto mit = S.meta.find(base);
                if (mit != S.meta.end() && b.stage == Stage::Compute) {
                    mit->second.cleared = true;
                    mit->second.cleared_seq = S.committed_seq + 1;
                }
            }
            break;
        }
        case GCN_BUFFER_FLATBUF:
            for (uint32_t k = 0; k < bb.num_msl_buffers; ++k)
                b.Bytes(flat.data(), flat.size() * 4, bb.msl_buffers[k]);
            continue;
        case GCN_BUFFER_GDS:
            mb = S.gds_buf;
            break;
        case GCN_BUFFER_SHARED_MEMORY: {
            // shadPS4: lds_size = SharedMemSize * NumWorkgroups, zero filled
            uint32_t lds = s->info.shared_memory_size ? s->info.shared_memory_size : 32768;
            size_t sz = (size_t)lds * std::max(1u, bc.num_workgroups);
            if (sz > (256u << 20)) {
                if (why) *why = "LDS spill buffer too large";
                return false;
            }
            void* ptr;
            size_t aoff;
            if (!S.arena.Alloc(S.dev, sz, 256, &mb, &aoff, &ptr)) return false;
            memset(ptr, 0, sz);
            off = aoff;
            break;
        }
        case GCN_BUFFER_CLIP_PLANES: {
            float planes[24];
            for (int k = 0; k < 24; ++k) planes[k] = AsF((*bc.regs)[0xA16F + k]);
            for (uint32_t k = 0; k < bb.num_msl_buffers; ++k) b.Bytes(planes, sizeof(planes), bb.msl_buffers[k]);
            continue;
        }
        default:
            mb = S.dummy;
            break;
        }
        for (uint32_t k = 0; k < bb.num_msl_buffers; ++k) b.Buffer(mb, off, bb.msl_buffers[k]);
        if (bb.msl_arg_index < argtab.size() && mb) {
            argtab[bb.msl_arg_index] = mb.gpuAddress + off;
            if (mb != S.dummy) b.Use(mb, bb.is_written);
        }
    }
    if (!argtab.empty()) b.Bytes(argtab.data(), argtab.size() * sizeof(uint64_t), (uint32_t)s->info.msl_argument_buffer);

    for (uint32_t i = 0; i < s->imgs.size(); ++i) {
        const gcn_image_binding& ib = s->imgs[i];
        const uint32_t nb = std::max(1u, ib.num_bindings);
        id<MTLTexture> tex = nil;
        ImageDesc img;
        const bool have = StageImage(s, flat, i, &img) && img.valid && img.address && img.address < S.ctx->mem_size;
        if (have) {
            if (ib.is_depth) {
                tex = S.tex->FindDepthTarget(img.address);
                if (!tex) tex = DepthFromMemory(img, false);
                if (!tex) RLog("depth-tex", "depth texture at 0x%llx (fmt %u/%u %ux%u tile %u) not a known depth target",
                               (unsigned long long)img.address, img.raw_dfmt, img.raw_nfmt, img.width, img.height,
                               (uint32_t)img.tile_mode);
            } else if (ib.is_storage) {
                tex = S.tex->GetStorageTexture(img);
                if (tex) {
                    // storage writes go to a GPU-owned texture
                    S.storage_bound.emplace_back(img.address, tex);
                } else {
                    RLog("storage-tex", "storage image unsupported (fmt %u/%u %ux%u type %u)",
                         img.raw_dfmt, img.raw_nfmt, img.width, img.height, (uint32_t)img.type);
                }
            } else if (auto sz = S.stencil_to_z.find(img.address);
                       sz != S.stencil_to_z.end() && S.tex->FindDepthTarget(sz->second) &&
                       S.tex->FindDepthTarget(sz->second).pixelFormat == MTLPixelFormatDepth32Float_Stencil8) {
                // the stencil plane of a depth target, read as an 8-bit integer image
                id<MTLTexture> dt = S.tex->FindDepthTarget(sz->second);
                tex = [dt newTextureViewWithPixelFormat:MTLPixelFormatX32_Stencil8];
            } else if (id<MTLTexture> dt = S.tex->FindDepthTarget(img.address)) {
                tex = DepthCompanion(dt, false);
                if (!tex) RLog("depth-as-color", "depth surface 0x%llx sampled as color: no companion",
                               (unsigned long long)img.address);
            } else if (id<MTLTexture> mc = MipChainFor(img, false)) {
                tex = (mc.pixelFormat == (MTLPixelFormat)img.pixel.mtl_format)
                          ? [mc newTextureViewWithPixelFormat:mc.pixelFormat textureType:MTLTextureType2D
                                                       levels:NSMakeRange(0, mc.mipmapLevelCount) slices:NSMakeRange(0, 1)
                                                      swizzle:ToMTLSwizzle(img.view_swizzle)]
                          : mc;
            } else {
                tex = SampledTexture(img);
                static const bool texdbg3d = getenv("PS4_GNM_TEXDBG3D") != nullptr;
                if (texdbg3d && tex && tex.textureType == MTLTextureType3D && tex.storageMode == MTLStorageModeShared) {
                    static std::unordered_set<uint64_t> seen3d;
                    if (seen3d.insert(img.address).second) {
                        const size_t w = tex.width, h = tex.height, d = tex.depth;
                        std::vector<uint8_t> px(w * h * d * 4);
                        [tex getBytes:px.data() bytesPerRow:w * 4 bytesPerImage:w * h * 4
                           fromRegion:MTLRegionMake3D(0, 0, 0, w, h, d) mipmapLevel:0 slice:0];
                        uint64_t sum = 0;
                        for (uint8_t v : px) sum += v;
                        fprintf(stderr, "[gnm-draw] 3D tex 0x%llx %zux%zux%zu fmt %lu: avg byte %.2f first px %02x%02x%02x%02x last %02x%02x%02x%02x\n",
                                (unsigned long long)img.address, w, h, d, (unsigned long)tex.pixelFormat, (double)sum / px.size(),
                                px[0], px[1], px[2], px[3], px[px.size() - 4], px[px.size() - 3], px[px.size() - 2], px[px.size() - 1]);
                        const uint8_t* g = S.ctx->mem_base + img.address;
                        fprintf(stderr, "[gnm-draw]   guest bytes: %02x%02x%02x%02x %02x%02x%02x%02x ...\n", g[0], g[1], g[2], g[3], g[4], g[5], g[6], g[7]);
                    }
                }
                if (!tex) RLog("tex-fail", "texture unsupported (fmt %u/%u %ux%u type %u tile %u)",
                               img.raw_dfmt, img.raw_nfmt, img.width, img.height, (uint32_t)img.type,
                               (uint32_t)img.tile_mode);
            }
        }
        if (ShouldTrace())
            fprintf(stderr, "[gnm-trace]    %s img[%u] slot %u %s%s addr=0x%llx fmt=%u/%u %ux%u type=%u tile=%u -> %s\n",
                    b.stage == Stage::Vertex ? "VS" : b.stage == Stage::Fragment ? "PS" : "CS", i, ib.msl_texture,
                    ib.is_storage ? "storage" : "sampled", ib.is_depth ? " depth" : "", (unsigned long long)img.address,
                    img.raw_dfmt, img.raw_nfmt, img.width, img.height, (uint32_t)img.type, (uint32_t)img.tile_mode,
                    tex ? "ok" : "nil");
        const MTLTextureType want = ShaderTextureType(ib);
        for (uint32_t k = 0; k < nb; ++k) {
            id<MTLTexture> v = nil;
            if (tex) {
                uint32_t level = 0, nlevels = 0;
                if (ib.mip_fallback_mode == 1) {
                    level = k;
                    nlevels = 1;
                } else if (ib.mip_fallback_mode == 2) {
                    level = ib.constant_mip_index;
                    nlevels = 1;
                } else if (ib.is_storage) {
                    nlevels = 1;
                }
                v = AdaptTexture(tex, want, img, level, nlevels);
            }
            b.Texture(v, ib.msl_texture + k);
        }
    }

    for (uint32_t i = 0; i < s->samps.size(); ++i) {
        const gcn_sampler_binding& sb = s->samps[i];
        uint32_t ss[4] = {};
        gcn_shader_fetch_sampler_sharp(s->sh, i, flat.data(), ss);
        b.Sampler(GetSampler(ss, sb.is_depth), sb.msl_sampler);
    }

    if (s->info.msl_push_constant_buffer >= 0)
        b.Bytes(&pd, sizeof(pd), (uint32_t)s->info.msl_push_constant_buffer);
    return true;
}

// Guest bytes a T# covers: the exact surface layout (as uploaded by TextureCache), or a
// conservative estimate if it cannot be computed.
uint64_t ApproxImageBytes(const ImageDesc& img);

// The image descriptors of a stage, decoded by the CP thread while preparing the draw /
// dispatch, so the encoder's hazard check, depth companions and binding do not decode them
// again. StageImage() falls back to decoding when no table of the stage is installed.
struct StageImages {
    const Shader* s = nullptr;
    const uint32_t* flat = nullptr;
    std::vector<ImageDesc> img;
    std::vector<uint8_t> ok;      // fetch and decode succeeded (img.valid is checked by the users)
    std::vector<uint64_t> approx; // ApproxImageBytes
    void Clear() {
        s = nullptr;
        flat = nullptr;
        img.clear();
        ok.clear();
        approx.clear();
    }
};
thread_local const StageImages* t_stage_images[3] = {};

void DecodeStageImages(const Shader* s, const std::vector<uint32_t>& flat, StageImages* out) {
    out->s = s;
    out->flat = flat.data();
    const size_t n = s->imgs.size();
    out->img.resize(n);
    out->ok.assign(n, 0);
    out->approx.assign(n, 0);
    for (uint32_t i = 0; i < n; ++i) {
        uint32_t t[8] = {};
        if (!gcn_shader_fetch_image_sharp(s->sh, i, flat.data(), t)) continue;
        if (!DecodeImage(t, s->imgs[i].is_r128 ? 4 : 8, &out->img[i])) continue;
        out->ok[i] = 1;
        if (out->img[i].valid) out->approx[i] = ApproxImageBytes(out->img[i]);
    }
}

bool StageImage(const Shader* s, const std::vector<uint32_t>& flat, uint32_t i, ImageDesc* img,
                uint64_t* approx) {
    for (const StageImages* p : t_stage_images) {
        if (p && p->s == s && p->flat == flat.data() && i < p->img.size()) {
            if (!p->ok[i]) return false;
            *img = p->img[i];
            if (approx) *approx = p->approx[i];
            return true;
        }
    }
    uint32_t t[8] = {};
    if (!gcn_shader_fetch_image_sharp(s->sh, i, flat.data(), t)) return false;
    if (!DecodeImage(t, s->imgs[i].is_r128 ? 4 : 8, img)) return false;
    if (approx) *approx = img->valid ? ApproxImageBytes(*img) : 0;
    return true;
}

// Installs the tables of a draw / dispatch for the encoder while it is being encoded.
struct StageImagesScope {
    StageImagesScope(const StageImages* a, const StageImages* b, const StageImages* c) {
        t_stage_images[0] = a;
        t_stage_images[1] = b;
        t_stage_images[2] = c;
    }
    ~StageImagesScope() { t_stage_images[0] = t_stage_images[1] = t_stage_images[2] = nullptr; }
};

uint64_t ApproxImageBytes(const ImageDesc& img) {
    SurfaceLayout layout;
    if (ComputeSurfaceLayout(img.ToSurfaceDesc(), &layout) && layout.total_size) return layout.total_size;
    return (uint64_t)img.pitch * std::max(1u, img.height) * std::max(1u, NumBitsPerElement(img.dfmt)) / 8 *
               std::max(1u, img.num_layers) * std::max(1u, img.depth) * 2 + 65536;
}

void BumpDepthVersion(id<MTLTexture> t) {
    if (!t) return;
    S.depth_version[(__bridge void*)t]++;
    S.depth_last_write[(__bridge void*)t] = ++S.depth_write_clock;
}

bool HasStencil(MTLPixelFormat f);
id<MTLTexture> DepthFromMemory(const ImageDesc& img, bool encode);

// Depth copy between sample counts: a fullscreen triangle writing [[depth(any)]] from sample 0 of
// a multisampled depth texture (to 1x) or from a 1x depth texture to every sample (to Nx).
id<MTLRenderPipelineState> DepthCopyPso(MTLPixelFormat fmt, NSUInteger samples, bool from_ms) {
    const uint64_t key = ((uint64_t)fmt << 16) | (samples << 1) | (from_ms ? 1 : 0);
    auto it = S.depth_copy_psos.find(key);
    if (it != S.depth_copy_psos.end()) return it->second;
    id<MTLRenderPipelineState> pso = nil;
    if (S.util_lib) {
        MTLRenderPipelineDescriptor* pd = [MTLRenderPipelineDescriptor new];
        pd.vertexFunction = [S.util_lib newFunctionWithName:@"present_vs"];
        pd.fragmentFunction = [S.util_lib newFunctionWithName:from_ms ? @"depth_from_ms_fs" : @"depth_to_ms_fs"];
        pd.depthAttachmentPixelFormat = fmt;
        if (HasStencil(fmt)) pd.stencilAttachmentPixelFormat = fmt;
        pd.rasterSampleCount = samples;
        NSError* err = nil;
        pso = [S.dev newRenderPipelineStateWithDescriptor:pd error:&err];
        if (!pso) RLog("depth-copy", "depth copy pipeline failed: %s", err.localizedDescription.UTF8String);
    }
    S.depth_copy_psos[key] = pso;
    return pso;
}

// Before rendering with depth texture t: if the same depth memory was last written through a
// texture of another sample count, copy that depth into t first.
void SyncDepthSibling(const DepthTarget& db, id<MTLTexture> t) {
    id<MTLTexture> sib = S.tex->FindDepthSibling(db, t);
    if (!sib) return;
    const uint64_t sw = S.depth_last_write[(__bridge void*)sib];
    uint64_t& tw = S.depth_last_write[(__bridge void*)t];
    if (sw <= tw) return;
    const bool from_ms = sib.sampleCount > 1;
    if (from_ms == (t.sampleCount > 1)) return;
    id<MTLRenderPipelineState> pso = DepthCopyPso(t.pixelFormat, t.sampleCount, from_ms);
    if (!pso) return;
    if (!S.depth_copy_dss) {
        MTLDepthStencilDescriptor* dd = [MTLDepthStencilDescriptor new];
        dd.depthCompareFunction = MTLCompareFunctionAlways;
        dd.depthWriteEnabled = YES;
        S.depth_copy_dss = [S.dev newDepthStencilStateWithDescriptor:dd];
    }
    EndEncoders();
    EnsureCmd();
    MTLRenderPassDescriptor* rp = [MTLRenderPassDescriptor renderPassDescriptor];
    rp.depthAttachment.texture = t;
    rp.depthAttachment.loadAction = MTLLoadActionDontCare;
    rp.depthAttachment.storeAction = MTLStoreActionStore;
    if (HasStencil(t.pixelFormat)) {
        rp.stencilAttachment.texture = t;
        rp.stencilAttachment.loadAction = MTLLoadActionLoad;
        rp.stencilAttachment.storeAction = MTLStoreActionStore;
    }
    rp.renderTargetWidth = t.width;
    rp.renderTargetHeight = t.height;
    id<MTLRenderCommandEncoder> e = [S.cmd renderCommandEncoderWithDescriptor:rp];
    [e setRenderPipelineState:pso];
    [e setDepthStencilState:S.depth_copy_dss];
    [e setFragmentTexture:sib atIndex:0];
    [e drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
    [e endEncoding];
    S.pending = true;
    tw = sw;
    S.depth_version[(__bridge void*)t]++;
    LogWork("depth sample-count copy");
}

// A compute shader wrote a depth surface's memory through a 32-bit float storage image (e.g. the
// PS4 Pro resolve of the 2x checkerboard depth into a 1x depth buffer): move the values into the
// depth target used for rendering.
void SyncStorageToStencil(uint64_t z_addr, id<MTLTexture> src) {
    id<MTLTexture> dt = S.tex->FindDepthTarget(z_addr);
    if (!dt || dt.sampleCount > 1 || dt.textureType != MTLTextureType2D || !HasStencil(dt.pixelFormat)) return;
    static std::unordered_map<uint32_t, id<MTLRenderPipelineState>> psos;
    static id<MTLDepthStencilState> dss = nil;
    __strong id<MTLRenderPipelineState>& pso = psos[(uint32_t)dt.pixelFormat];
    if (!pso && S.util_lib) {
        MTLRenderPipelineDescriptor* pd = [MTLRenderPipelineDescriptor new];
        pd.vertexFunction = [S.util_lib newFunctionWithName:@"present_vs"];
        pd.fragmentFunction = [S.util_lib newFunctionWithName:@"stencil_from_color_fs"];
        pd.depthAttachmentPixelFormat = dt.pixelFormat;
        pd.stencilAttachmentPixelFormat = dt.pixelFormat;
        NSError* err = nil;
        pso = [S.dev newRenderPipelineStateWithDescriptor:pd error:&err];
        if (!pso) RLog("stencil-from-color", "pipeline failed: %s", err.localizedDescription.UTF8String);
    }
    if (!pso) return;
    if (!dss) {
        MTLStencilDescriptor* sd = [MTLStencilDescriptor new];
        sd.stencilCompareFunction = MTLCompareFunctionAlways;
        sd.depthStencilPassOperation = MTLStencilOperationReplace;
        sd.readMask = 0xFF;
        sd.writeMask = 0xFF;
        MTLDepthStencilDescriptor* dd = [MTLDepthStencilDescriptor new];
        dd.depthCompareFunction = MTLCompareFunctionAlways;
        dd.depthWriteEnabled = NO;
        dd.frontFaceStencil = sd;
        dd.backFaceStencil = sd;
        dss = [S.dev newDepthStencilStateWithDescriptor:dd];
    }
    EndEncoders();
    EnsureCmd();
    MTLRenderPassDescriptor* rp = [MTLRenderPassDescriptor renderPassDescriptor];
    rp.depthAttachment.texture = dt;
    rp.depthAttachment.loadAction = MTLLoadActionLoad;
    rp.depthAttachment.storeAction = MTLStoreActionStore;
    rp.stencilAttachment.texture = dt;
    rp.stencilAttachment.loadAction = MTLLoadActionLoad;
    rp.stencilAttachment.storeAction = MTLStoreActionStore;
    rp.renderTargetWidth = std::min(dt.width, src.width);
    rp.renderTargetHeight = std::min(dt.height, src.height);
    id<MTLRenderCommandEncoder> e = [S.cmd renderCommandEncoderWithDescriptor:rp];
    [e setRenderPipelineState:pso];
    [e setDepthStencilState:dss];
    [e setFragmentTexture:src atIndex:0];
    [e drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
    [e endEncoding];
    S.pending = true;
    BumpDepthVersion(dt);
    LogWork("storage -> stencil copy");
}

void SyncStorageToDepth() {
    for (auto& [addr, src] : S.storage_bound) {
        if (src.pixelFormat == MTLPixelFormatR8Uint && src.sampleCount == 1) {
            if (auto sz = S.stencil_to_z.find(addr); sz != S.stencil_to_z.end()) SyncStorageToStencil(sz->second, src);
            continue;
        }
        if (src.pixelFormat != MTLPixelFormatR32Float || src.sampleCount > 1) continue;
        id<MTLTexture> dt = S.tex->FindDepthTarget(addr);
        if (!dt || dt.sampleCount > 1 || dt.textureType != MTLTextureType2D) continue;
        __strong id<MTLRenderPipelineState>& pso = S.depth_from_color_psos[(uint32_t)dt.pixelFormat];
        if (!pso && S.util_lib) {
            MTLRenderPipelineDescriptor* pd = [MTLRenderPipelineDescriptor new];
            pd.vertexFunction = [S.util_lib newFunctionWithName:@"present_vs"];
            pd.fragmentFunction = [S.util_lib newFunctionWithName:@"depth_from_color_fs"];
            pd.depthAttachmentPixelFormat = dt.pixelFormat;
            if (HasStencil(dt.pixelFormat)) pd.stencilAttachmentPixelFormat = dt.pixelFormat;
            NSError* err = nil;
            pso = [S.dev newRenderPipelineStateWithDescriptor:pd error:&err];
            if (!pso) RLog("depth-from-color", "pipeline failed: %s", err.localizedDescription.UTF8String);
        }
        if (!pso) continue;
        if (!S.depth_copy_dss) {
            MTLDepthStencilDescriptor* dd = [MTLDepthStencilDescriptor new];
            dd.depthCompareFunction = MTLCompareFunctionAlways;
            dd.depthWriteEnabled = YES;
            S.depth_copy_dss = [S.dev newDepthStencilStateWithDescriptor:dd];
        }
        EndEncoders();
        EnsureCmd();
        MTLRenderPassDescriptor* rp = [MTLRenderPassDescriptor renderPassDescriptor];
        rp.depthAttachment.texture = dt;
        rp.depthAttachment.loadAction = MTLLoadActionLoad;
        rp.depthAttachment.storeAction = MTLStoreActionStore;
        if (HasStencil(dt.pixelFormat)) {
            rp.stencilAttachment.texture = dt;
            rp.stencilAttachment.loadAction = MTLLoadActionLoad;
            rp.stencilAttachment.storeAction = MTLStoreActionStore;
        }
        rp.renderTargetWidth = std::min(dt.width, src.width);
        rp.renderTargetHeight = std::min(dt.height, src.height);
        id<MTLRenderCommandEncoder> e = [S.cmd renderCommandEncoderWithDescriptor:rp];
        [e setRenderPipelineState:pso];
        [e setDepthStencilState:S.depth_copy_dss];
        [e setFragmentTexture:src atIndex:0];
        [e drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
        [e endEncoding];
        S.pending = true;
        BumpDepthVersion(dt);
        LogWork("storage -> depth copy");
    }
    S.storage_bound.clear();
}

// R32F copy of a depth target for shaders that sample the depth surface as a color texture.
// Encodes a conversion pass into the current command buffer when the depth changed.
id<MTLRenderPipelineState> Depth2ColorMsPso(NSUInteger samples) {
    static std::unordered_map<NSUInteger, id<MTLRenderPipelineState>> psos;
    auto it = psos.find(samples);
    if (it != psos.end()) return it->second;
    id<MTLRenderPipelineState> pso = nil;
    if (S.util_lib) {
        MTLRenderPipelineDescriptor* pd = [MTLRenderPipelineDescriptor new];
        pd.vertexFunction = [S.util_lib newFunctionWithName:@"present_vs"];
        pd.fragmentFunction = [S.util_lib newFunctionWithName:@"depth2color_ms_fs"];
        pd.colorAttachments[0].pixelFormat = MTLPixelFormatR32Float;
        pd.rasterSampleCount = samples;
        NSError* err = nil;
        pso = [S.dev newRenderPipelineStateWithDescriptor:pd error:&err];
        if (!pso) RLog("depth-ms", "MSAA depth companion pipeline failed: %s", err.localizedDescription.UTF8String);
    }
    psos[samples] = pso;
    return pso;
}

id<MTLTexture> DepthCompanion(id<MTLTexture> dt, bool encode) {
    if (!dt || !S.depth2color_pso) return nil;
    const bool ms = dt.sampleCount > 1;
    if (ms && dt.textureType != MTLTextureType2DMultisample) return nil;
    if (!ms && dt.textureType != MTLTextureType2D && dt.textureType != MTLTextureType2DArray) return nil;
    void* key = (__bridge void*)dt;
    auto& c = S.depth_comp[key];
    const uint64_t ver = S.depth_version[key];
    if (c.tex && c.version == ver) return c.tex;
    if (!encode) return c.tex;
    id<MTLRenderPipelineState> pso = ms ? Depth2ColorMsPso(dt.sampleCount) : S.depth2color_pso;
    if (!pso) return nil;
    if (!c.tex) {
        MTLTextureDescriptor* td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatR32Float
                                                                                      width:dt.width
                                                                                     height:dt.height
                                                                                  mipmapped:NO];
        td.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
        td.storageMode = MTLStorageModePrivate;
        if (ms) {
            // per-sample copy (the fragment shader reads [[sample_id]]) for texture2d_ms reads
            td.textureType = MTLTextureType2DMultisample;
            td.sampleCount = dt.sampleCount;
        }
        c.tex = [S.dev newTextureWithDescriptor:td];
        if (!c.tex) return nil;
    }
    id<MTLTexture> src = dt;
    if (!ms && dt.textureType != MTLTextureType2D)
        src = [dt newTextureViewWithPixelFormat:dt.pixelFormat textureType:MTLTextureType2D
                                         levels:NSMakeRange(0, 1) slices:NSMakeRange(0, 1)];
    EndEncoders();
    EnsureCmd();
    MTLRenderPassDescriptor* rp = [MTLRenderPassDescriptor renderPassDescriptor];
    rp.colorAttachments[0].texture = c.tex;
    rp.colorAttachments[0].loadAction = MTLLoadActionDontCare;
    rp.colorAttachments[0].storeAction = MTLStoreActionStore;
    id<MTLRenderCommandEncoder> e = [S.cmd renderCommandEncoderWithDescriptor:rp];
    [e setRenderPipelineState:pso];
    [e setFragmentTexture:src atIndex:0];
    [e drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
    [e endEncoding];
    c.version = ver;
    S.pending = true;
    LogWork("depth->color companion");
    return c.tex;
}

uint64_t MipChainKey(const ImageDesc& img) {
    uint64_t k[4] = {img.address, ((uint64_t)img.width << 32) | img.height,
                     ((uint64_t)img.pixel.mtl_format << 32) | img.NumViewLevels(), (uint64_t)img.tile_mode};
    return Fnv(k, sizeof(k));
}

// A sampled 2D texture with several mip levels whose base level is a GPU render target: the game
// rendered each level separately (bloom/downsample chains). Assemble a mipmapped copy from the
// render targets found at the mip addresses (blits encoded into the current command buffer).
id<MTLTexture> MipChainFor(const ImageDesc& img, bool encode) {
    if (img.mtl_texture_type != MTLTextureType2D || img.NumViewLevels() < 2 || img.pixel.compressed) return nil;
    id<MTLTexture> base = S.tex->FindColorTarget(img.address);
    if (!base || base.sampleCount > 1 || base.width != img.width || base.height != img.height) return nil;
    const uint64_t key = MipChainKey(img);
    auto it = S.mip_chains.find(key);
    if (!encode) return it != S.mip_chains.end() ? it->second.tex : nil;
    State::MipChain& mc = S.mip_chains[key];
    if (mc.tex && mc.built_submit == S.submit_idx + (S.n_draws << 20)) return mc.tex;
    SurfaceLayout layout;
    const SurfaceDesc sd = img.ToSurfaceDesc();
    if (!ComputeSurfaceLayout(sd, &layout)) return nil;
    const uint32_t levels = std::min<uint32_t>(img.NumViewLevels(), layout.num_mips);
    if (!mc.tex || mc.tex.mipmapLevelCount != levels) {
        MTLTextureDescriptor* td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:base.pixelFormat
                                                                                      width:img.width
                                                                                     height:img.height
                                                                                  mipmapped:YES];
        td.mipmapLevelCount = levels;
        td.usage = MTLTextureUsageShaderRead | MTLTextureUsagePixelFormatView;
        td.storageMode = MTLStorageModePrivate;
        mc.tex = [S.dev newTextureWithDescriptor:td];
        if (!mc.tex) return nil;
    }
    EndEncoders();
    EnsureCmd();
    id<MTLBlitCommandEncoder> bl = [S.cmd blitCommandEncoder];
    for (uint32_t m = 0; m < levels; ++m) {
        const uint32_t w = std::max(1u, img.width >> m), h = std::max(1u, img.height >> m);
        id<MTLTexture> src = m == 0 ? base : S.tex->FindColorTarget(img.address + layout.mips[m].offset);
        if (!src || src.pixelFormat != base.pixelFormat || src.sampleCount > 1 || src.width < w || src.height < h) continue;
        [bl copyFromTexture:src sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0, 0, 0)
                 sourceSize:MTLSizeMake(w, h, 1) toTexture:mc.tex destinationSlice:0 destinationLevel:m
          destinationOrigin:MTLOriginMake(0, 0, 0)];
    }
    [bl endEncoding];
    S.pending = true;
    mc.built_submit = S.submit_idx + (S.n_draws << 20);
    LogWork("mip chain assembly");
    return mc.tex;
}

// A depth texture (sampled with depth compare) that is not a GPU depth target: 16/32-bit data
// the game loaded or wrote itself. Metal needs a depth pixel format for depth2d bindings, so
// the sampled texture from guest memory is converted into a depth texture (once per frame).
id<MTLTexture> DepthFromMemory(const ImageDesc& img, bool encode) {
    static std::unordered_map<uint64_t, std::pair<id<MTLTexture>, uint64_t>> cache;
    const uint64_t key = img.address ^ ((uint64_t)img.width << 40) ^ ((uint64_t)img.height << 52) ^
                         ((uint64_t)img.raw_dfmt << 32);
    auto& ent = cache[key];
    if (ent.first && (ent.second == S.present_idx || !encode)) return ent.first;
    if (!encode) return nil;
    MTLPixelFormat df;
    if (img.raw_dfmt == 2) df = MTLPixelFormatDepth16Unorm;      // Format16
    else if (img.raw_dfmt == 4) df = MTLPixelFormatDepth32Float; // Format32
    else return nil;
    id<MTLTexture> src = S.tex->GetTexture(img);
    if (!src || src.textureType != MTLTextureType2D) return nil;
    if (!ent.first || ent.first.width != src.width || ent.first.height != src.height || ent.first.pixelFormat != df) {
        MTLTextureDescriptor* td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:df width:src.width
                                                                                     height:src.height mipmapped:NO];
        td.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
        td.storageMode = MTLStorageModePrivate;
        ent.first = [S.dev newTextureWithDescriptor:td];
        if (!ent.first) return nil;
    }
    __strong id<MTLRenderPipelineState>& pso = S.depth_from_color_psos[(uint32_t)df];
    if (!pso && S.util_lib) {
        MTLRenderPipelineDescriptor* pd = [MTLRenderPipelineDescriptor new];
        pd.vertexFunction = [S.util_lib newFunctionWithName:@"present_vs"];
        pd.fragmentFunction = [S.util_lib newFunctionWithName:@"depth_from_color_fs"];
        pd.depthAttachmentPixelFormat = df;
        NSError* err = nil;
        pso = [S.dev newRenderPipelineStateWithDescriptor:pd error:&err];
        if (!pso) RLog("depth-from-color", "pipeline failed: %s", err.localizedDescription.UTF8String);
    }
    if (!pso) return nil;
    if (!S.depth_copy_dss) {
        MTLDepthStencilDescriptor* dd = [MTLDepthStencilDescriptor new];
        dd.depthCompareFunction = MTLCompareFunctionAlways;
        dd.depthWriteEnabled = YES;
        S.depth_copy_dss = [S.dev newDepthStencilStateWithDescriptor:dd];
    }
    EndEncoders();
    EnsureCmd();
    MTLRenderPassDescriptor* rp = [MTLRenderPassDescriptor renderPassDescriptor];
    rp.depthAttachment.texture = ent.first;
    rp.depthAttachment.loadAction = MTLLoadActionDontCare;
    rp.depthAttachment.storeAction = MTLStoreActionStore;
    id<MTLRenderCommandEncoder> e = [S.cmd renderCommandEncoderWithDescriptor:rp];
    [e setRenderPipelineState:pso];
    [e setDepthStencilState:S.depth_copy_dss];
    [e setFragmentTexture:src atIndex:0];
    [e drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
    [e endEncoding];
    S.pending = true;
    ent.second = S.present_idx;
    LogWork("depth texture from memory");
    return ent.first;
}

// Before encoding a draw/dispatch: refresh R32F companions of depth targets that the shader
// samples as color textures, and depth copies of depth textures that live in guest memory.
void PrepareDepthCompanions(const Shader* s, const std::vector<uint32_t>& flat) {
    if (s->imgs.empty()) return;
    for (uint32_t i = 0; i < s->imgs.size(); ++i) {
        if (s->imgs[i].is_storage) continue;
        ImageDesc img;
        if (!StageImage(s, flat, i, &img) || !img.valid) continue;
        if (s->imgs[i].is_depth) {
            if (!S.tex->FindDepthTarget(img.address)) DepthFromMemory(img, true);
            continue;
        }
        if (id<MTLTexture> dt = S.tex->FindDepthTarget(img.address)) DepthCompanion(dt, true);
        else MipChainFor(img, true);
    }
}

// Encodes the copy of a texture's guest memory into up.tex on the GPU: compute detile for tiled
// surfaces, then blit. side == nil: into the current command buffer (ends the open encoders;
// a barrier orders the detile after the writing dispatches). side != nil: into that command
// buffer with its own encoders; the current encoders stay open.
bool EncodeGpuUpload(const ImageDesc& img, const TextureCache::GpuUpload& up, id<MTLCommandBuffer> side) {
    if (!S.detile_pso || !up.tex || img.address >= S.ctx->mem_size) return false;
    const SurfaceDesc sd = img.ToSurfaceDesc();
    SurfaceLayout layout;
    if (sd.bpp == 0 || (sd.bpp & 7) || !ComputeSurfaceLayout(sd, &layout) || !layout.total_size) return false;
    const uint64_t avail = std::min<uint64_t>(layout.total_size, S.ctx->mem_size - img.address);
    id<MTLBuffer> gbuf = nil;
    uint64_t goff = 0;
    if (!GuestBuffer(img.address, avail, GuestAccess::Read, &gbuf, &goff)) return false;
    const bool tiled = sd.tile_mode != TileMode::DisplayLinearAligned && sd.tile_mode != TileMode::DisplayLinearGeneral;
    const uint32_t bpe = sd.bpp / 8;
    id<MTLTexture> tex = up.tex;
    if (up.surf.bpp != sd.bpp || up.layout.total_size != layout.total_size) {
        RLog("gpu-upload", "texture 0x%llx: cached layout differs from the T#", (unsigned long long)img.address);
    }
    // validate every copy before encoding anything: a surface the copies cannot cover completely
    // is left to the CPU path (the caller marks the texture stale) instead of being marked
    // current with partial contents
    const bool is3d = up.tex_type == MTLTextureType3D;
    const bool is1d = up.tex_type == MTLTextureType1D || up.tex_type == MTLTextureType1DArray;
    const NSUInteger tex_slices = (tex.textureType == MTLTextureTypeCube || tex.textureType == MTLTextureTypeCubeArray)
                                      ? tex.arrayLength * 6 : tex.arrayLength;
    const uint64_t src_size = tiled ? up.layout.total_size : avail; // bytes readable from the copy source
    for (uint32_t m = 0; m < up.levels; ++m) {
        bool bad = m >= up.layout.num_mips;
        uint64_t row = 0, rows = 0, rowbytes = 0, need = 0;
        if (!bad) {
            const MipLayout& ml = up.layout.mips[m];
            const uint32_t w = std::max(1u, up.width >> m), h = is1d ? 1u : std::max(1u, up.height >> m);
            row = (uint64_t)ml.pitch * bpe;
            const uint64_t image = row * ml.height;
            rowbytes = (uint64_t)((w + up.block_width - 1) / up.block_width) * up.bytes_per_block;
            rows = (h + up.block_height - 1) / up.block_height;
            const uint32_t d = is3d ? std::max(1u, up.depth >> m) : 1u;
            const uint32_t slices = is3d ? 1u : std::min<uint32_t>(std::min(up.layers, ml.slices), (uint32_t)tex_slices);
            need = slices ? ml.offset + (uint64_t)(slices - 1) * image + (uint64_t)(d - 1) * image + (rows - 1) * row + rowbytes
                          : 0;
            bad = rowbytes > row || !rows || need > src_size;
        }
        if (bad) {
            static int warned = 0;
            if (warned++ < 16)
                fprintf(stderr, "[gnm-tex] GPU upload of 0x%llx mip %u out of bounds (fmt %u %ux%u levels %u/%u row %llu "
                                "rowbytes %llu rows %llu need %llu have %llu); CPU upload\n",
                        (unsigned long long)img.address, m, img.pixel.mtl_format, up.width, up.height, up.levels,
                        up.layout.num_mips, (unsigned long long)row, (unsigned long long)rowbytes,
                        (unsigned long long)rows, (unsigned long long)need, (unsigned long long)src_size);
            return false;
        }
    }
    id<MTLBuffer> src = gbuf;
    uint64_t src_base = goff;
    if (tiled) {
        const SurfaceDesc& u = up.surf;
        const uint32_t kf[14] = {(uint32_t)u.tile_mode, u.bpp, u.num_samples, u.width, u.height, u.depth, u.pitch,
                                 u.levels, u.layers, (uint32_t)u.is_block | ((uint32_t)u.is_pow2 << 1) |
                                 ((uint32_t)u.alt_tile << 2), u.bank_swizzle, up.levels, (uint32_t)avail,
                                 (uint32_t)(avail >> 32)};
        uint64_t key = Fnv(kf, sizeof(kf));
        id<MTLBuffer> map = nil;
        auto mit = S.detile_maps.find(key);
        if (mit != S.detile_maps.end()) {
            map = mit->second;
        } else {
            std::vector<uint32_t> m;
            if (!BuildDetileMap(up.surf, up.layout, avail, 0, up.levels, &m) || m.empty()) return false;
            if (S.detile_maps.size() >= 64) S.detile_maps.clear();
            map = [S.dev newBufferWithBytes:m.data() length:m.size() * 4 options:MTLResourceStorageModeShared];
            if (!map) return false;
            S.detile_maps[key] = map;
        }
        // one private staging buffer per power-of-two size class, shared by all surfaces of that
        // class: every use (detile write, blit read) is ordered by Metal's hazard tracking (same
        // tracked buffer, same queue), also between upload_cmd and the current command buffer
        uint32_t cls = 16; // 64 KiB minimum
        while (cls < 40 && (1ull << cls) < up.layout.total_size) ++cls;
        if ((1ull << cls) < up.layout.total_size) return false;
        id<MTLBuffer> staging = nil;
        auto sit = S.detile_staging.find(cls);
        if (sit != S.detile_staging.end()) {
            staging = sit->second;
        } else {
            staging = [S.dev newBufferWithLength:(NSUInteger)(1ull << cls) options:MTLResourceStorageModePrivate];
            if (!staging) return false;
            S.detile_staging[cls] = staging;
        }
        const uint32_t count = (uint32_t)(map.length / 4);
        const uint32_t params[4] = {bpe, count, (uint32_t)avail, 0};
        id<MTLComputeCommandEncoder> enc;
        if (side) {
            enc = [side computeCommandEncoder];
        } else {
            enc = ComputeEncoder();
            [enc memoryBarrierWithScope:MTLBarrierScopeBuffers]; // order after the writing dispatches
        }
        [enc setComputePipelineState:S.detile_pso];
        [enc setBuffer:gbuf offset:goff atIndex:0];
        [enc setBuffer:staging offset:0 atIndex:1];
        [enc setBuffer:map offset:0 atIndex:2];
        [enc setBytes:params length:sizeof(params) atIndex:3];
        [enc dispatchThreads:MTLSizeMake(count, 1, 1) threadsPerThreadgroup:MTLSizeMake(256, 1, 1)];
        if (side) [enc endEncoding];
        else g_cstate.Reset(enc); // state set behind the dispatches' back
        src = staging;
        src_base = 0;
    }
    id<MTLBlitCommandEncoder> bl;
    if (side) {
        bl = [side blitCommandEncoder];
    } else {
        EndEncoders();
        EnsureCmd();
        bl = [S.cmd blitCommandEncoder];
    }
    for (uint32_t m = 0; m < up.levels; ++m) { // bounds validated above
        const MipLayout& ml = up.layout.mips[m];
        const uint32_t w = std::max(1u, up.width >> m), h = is1d ? 1u : std::max(1u, up.height >> m);
        const uint64_t row = (uint64_t)ml.pitch * bpe, image = row * ml.height;
        const uint64_t rowbytes = (uint64_t)((w + up.block_width - 1) / up.block_width) * up.bytes_per_block;
        const uint64_t rows = (h + up.block_height - 1) / up.block_height;
        const uint32_t d = is3d ? std::max(1u, up.depth >> m) : 1u;
        const uint32_t slices = is3d ? 1u : std::min<uint32_t>(std::min(up.layers, ml.slices), (uint32_t)tex_slices);
        for (uint32_t sl = 0; sl < slices; ++sl) {
            const uint64_t off = src_base + ml.offset + (uint64_t)sl * image;
            [bl copyFromBuffer:src
                       sourceOffset:off
                  sourceBytesPerRow:row
                sourceBytesPerImage:is3d ? image : 0
                         sourceSize:MTLSizeMake(w, h, d)
                          toTexture:tex
                   destinationSlice:sl
                   destinationLevel:m
                  destinationOrigin:MTLOriginMake(0, 0, 0)];
        }
    }
    [bl endEncoding];
    if (!side) {
        S.pending = true;
        LogWork("GPU texture upload");
    }
    return true;
}

// Hazard path: the texture's guest memory is written by GPU work that has not completed yet,
// so the copy goes into the current command buffer behind that work. Returns false if nothing
// was encoded and the caller must fall back to draining the GPU.
bool GpuUploadTexture(const ImageDesc& img, uint64_t write_epoch) {
    if (!S.detile_pso || img.address >= S.ctx->mem_size) return false;
    TextureCache::GpuUpload up;
    if (!S.tex->GetTextureForGpuUpload(img, write_epoch, S.write_epoch + 1, &up)) return false;
    if (!up.tex) return true; // already current (or a GPU-owned surface)
    if (EncodeGpuUpload(img, up, nil)) return true;
    S.tex->MarkStale(img.address, up.tex);
    return false;
}

const bool g_verify_gpu_upload = getenv("PS4_GNM_VERIFY_GPU_UPLOAD") != nullptr;

// Debug: compares a GPU copy with a CPU upload of the same guest memory once the GPU is done,
// over every mip level and every array/cube/depth slice the uploads write. The game rewriting
// the memory between encoding and execution also shows as a difference, so a single report at
// an address needs a second look.
void VerifyGpuUpload(const ImageDesc& img, const TextureCache::GpuUpload& up) {
    id<MTLTexture> tex = up.tex;
    MTLTextureDescriptor* td = [MTLTextureDescriptor new];
    td.textureType = tex.textureType;
    td.pixelFormat = tex.pixelFormat;
    td.width = tex.width;
    td.height = tex.height;
    td.depth = tex.depth;
    td.mipmapLevelCount = tex.mipmapLevelCount;
    td.arrayLength = tex.arrayLength;
    td.usage = MTLTextureUsageShaderRead;
    td.storageMode = MTLStorageModeShared;
    id<MTLTexture> ref = [S.dev newTextureWithDescriptor:td];
    if (!ref || !S.tex->DebugCpuUploadInto(img, ref)) return;
    // subresources written by both uploads (same limits as EncodeGpuUpload / UploadLockedImpl)
    const NSUInteger tex_slices = (tex.textureType == MTLTextureTypeCube || tex.textureType == MTLTextureTypeCubeArray)
                                      ? tex.arrayLength * 6 : tex.arrayLength;
    std::vector<uint32_t> slices_per_level;
    for (uint32_t m = 0; m < up.levels && m < up.layout.num_mips && m < tex.mipmapLevelCount; ++m)
        slices_per_level.push_back(up.tex_type == MTLTextureType3D
                                       ? 1u
                                       : std::min<uint32_t>(std::min(up.layers, up.layout.mips[m].slices),
                                                            (uint32_t)tex_slices));
    const uint64_t addr = img.address;
    const uint32_t bpb = img.pixel.bytes_per_block, bw = std::max(1u, img.pixel.block_width),
                   bh = std::max(1u, img.pixel.block_height);
    const uint32_t fmt = img.pixel.mtl_format, tile = (uint32_t)img.tile_mode, type = (uint32_t)up.tex_type;
    AfterGpu([tex, ref, addr, bpb, bw, bh, fmt, tile, type, slices_per_level] {
        static std::atomic<uint32_t> n_same{0}, n_diff{0};
        static std::atomic<uint64_t> n_sub{0};
        const bool is3d = tex.textureType == MTLTextureType3D;
        const bool is1d = tex.textureType == MTLTextureType1D || tex.textureType == MTLTextureType1DArray;
        uint32_t bad_subs = 0, first_m = 0, first_sl = 0, subs = 0;
        uint64_t bad_bytes = 0;
        std::vector<uint8_t> a, b;
        for (uint32_t m = 0; m < slices_per_level.size(); ++m) {
            const NSUInteger w = std::max<NSUInteger>(1, tex.width >> m), h = is1d ? 1 : std::max<NSUInteger>(1, tex.height >> m);
            const NSUInteger d = is3d ? std::max<NSUInteger>(1, tex.depth >> m) : 1;
            const NSUInteger row = (w + bw - 1) / bw * bpb, image = row * ((h + bh - 1) / bh);
            a.resize(image * d);
            b.resize(image * d);
            const MTLRegion r = MTLRegionMake3D(0, 0, 0, w, h, d);
            for (uint32_t sl = 0; sl < slices_per_level[m]; ++sl) {
                [tex getBytes:a.data() bytesPerRow:row bytesPerImage:image fromRegion:r mipmapLevel:m slice:sl];
                [ref getBytes:b.data() bytesPerRow:row bytesPerImage:image fromRegion:r mipmapLevel:m slice:sl];
                ++subs;
                if (a == b) continue;
                if (!bad_subs++) first_m = m, first_sl = sl;
                for (size_t i = 0; i < a.size(); ++i) bad_bytes += a[i] != b[i];
            }
        }
        n_sub += subs;
        if (!bad_subs) {
            n_same++;
        } else {
            n_diff++;
            fprintf(stderr, "[gnm-verify] GPU upload of 0x%llx differs from the CPU upload: fmt %u tile %u type %u "
                            "%lux%lux%lu (depth or array length) levels %zu, %u of %u subresources (first: mip %u slice %u), %llu bytes\n",
                    (unsigned long long)addr, fmt, tile, type, (unsigned long)tex.width, (unsigned long)tex.height,
                    (unsigned long)(is3d ? tex.depth : tex.arrayLength), slices_per_level.size(), bad_subs, subs,
                    first_m, first_sl, (unsigned long long)bad_bytes);
        }
        if ((n_same + n_diff) % 50 == 0)
            fprintf(stderr, "[gnm-verify] GPU uploads checked: %u equal, %u different (%llu subresources)\n",
                    n_same.load(), n_diff.load(), (unsigned long long)n_sub.load());
    });
}

// Sampled texture for BindStage. A large texture that needs an upload from guest memory is
// copied on the GPU in the upload command buffer (committed before the current one): the CPU
// detile of a big texture costs milliseconds on the encoder thread. Small textures, and copies
// that cannot be encoded, keep the CPU upload. PS4_GNM_GPU_UPLOAD_MIN_KB: threshold (default
// 256; 0: every size; -1: off). -1 turns off only this bind-time GPU path: the hazard path
// (GpuUploadTexture, for memory with GPU writes still pending) still copies on the GPU through
// the shared staging pool (S.detile_staging) with EncodeGpuUpload's up-front bounds check.
id<MTLTexture> SampledTexture(const ImageDesc& img) {
    static const int64_t min_kb = [] {
        const char* v = getenv("PS4_GNM_GPU_UPLOAD_MIN_KB");
        return v ? (int64_t)atoll(v) : (int64_t)256;
    }();
    if (min_kb < 0 || !S.detile_pso) return S.tex->GetTexture(img);
    // upload_cmd runs before all of S.cmd: the copy is current only for the writes before S.cmd,
    // so every write recorded in S.cmd (also earlier in this draw) still invalidates it
    TextureCache::GpuUpload up;
    id<MTLTexture> tex =
        S.tex->GetTextureForGpuRefresh(img, S.cmd_start_epoch, std::max<uint64_t>(1, (uint64_t)min_kb << 10), &up);
    if (!up.tex) return tex;
    // guest memory with GPU writes not yet executed (encoded or in flight), or overlapping a
    // GPU-owned surface: keep the CPU upload at bind time, as before the GPU path
    if (OverlapsPendingWrite(img.address, up.layout.total_size) ||
        S.tex->OverlapsGpuTexture(img.address, up.layout.total_size)) {
        S.tex->MarkStale(img.address, up.tex);
        return S.tex->GetTexture(img);
    }
    if (!S.upload_cmd) {
        S.upload_cmd = [S.queue commandBuffer];
        S.upload_cmd.label = @"texture uploads";
        [S.upload_cmd addCompletedHandler:^(id<MTLCommandBuffer> done) {
            if (done.status == MTLCommandBufferStatusError)
                fprintf(stderr, "[gnm-draw] texture upload command buffer failed: %s\n",
                        done.error.localizedDescription.UTF8String);
        }];
    }
    if (EncodeGpuUpload(img, up, S.upload_cmd)) {
        g_hitch.gpu_uploads++;
        if (g_verify_gpu_upload) VerifyGpuUpload(img, up);
        return tex;
    }
    S.tex->MarkStale(img.address, up.tex);
    return S.tex->GetTexture(img);
}

// Sampled textures are uploaded from guest memory by the CPU when bound. If encoded (not yet
// executed) GPU work writes that memory, the texture is copied on the GPU instead (or, if that
// is not possible, the GPU is drained first). Must run before encoding starts.
void ResolveTextureHazards(const Shader* s, const std::vector<uint32_t>& flat) {
    if (s->imgs.empty()) return;
    PruneCompletedWrites();
    if (S.gpu_written.empty() && S.inflight_written.empty()) return;
    for (uint32_t i = 0; i < s->imgs.size(); ++i) {
        if (s->imgs[i].is_storage || s->imgs[i].is_depth) continue;
        ImageDesc img;
        uint64_t approx = 0;
        if (!StageImage(s, flat, i, &img, &approx) || !img.valid) continue;
        GpuWrite hit{};
        if (OverlapsPendingWrite(img.address, approx, &hit)) {
            if (S.tex->OverlapsGpuTexture(img.address, 1)) continue; // GPU-owned: no CPU upload
            // copy the texture on the GPU behind the writing work; drain only if that fails
            if (GpuUploadTexture(img, hit.epoch)) continue;
            RLog("hazard", "texture 0x%llx (fmt %u/%u %ux%ux%u pitch %u levels %u layers %u tile %u type %u) written by pending GPU work (0x%llx+0x%llx): draining",
                 (unsigned long long)img.address, img.raw_dfmt, img.raw_nfmt, img.width, img.height, img.depth, img.pitch,
                 img.num_levels, img.num_layers, (uint32_t)img.tile_mode, (uint32_t)img.type,
                 (unsigned long long)hit.addr, (unsigned long long)hit.size);
            Commit();
            WaitAll();
            return;
        }
    }
}

template <class Regs>
gcn_push_data MakePushData(const Regs& regs) {
    // shadPS4 MakeUserData
    gcn_push_data p{};
    const uint32_t vte = regs[0xA206];
    p.xscale = (vte & 1) ? AsF(regs[0xA10F]) : 1.f;
    p.xoffset = (vte & 2) ? AsF(regs[0xA110]) : 0.f;
    p.yscale = (vte & 4) ? AsF(regs[0xA111]) : 1.f;
    p.yoffset = (vte & 8) ? AsF(regs[0xA112]) : 0.f;
    return p;
}

// =====================================================================================
// Render passes
// =====================================================================================
struct ClearReq {
    bool color[8] = {};
    MTLClearColor color_value[8];
    bool depth = false;
    double depth_value = 0;
    bool stencil = false;
    uint32_t stencil_value = 0;
    bool any() const {
        for (bool c : color)
            if (c) return true;
        return depth || stencil;
    }
};

bool HasStencil(MTLPixelFormat f) {
    return f == MTLPixelFormatDepth32Float_Stencil8 || f == MTLPixelFormatStencil8 ||
           f == MTLPixelFormatX32_Stencil8;
}

// ---- EQAA (PA_SC_AA_CONFIG multisampled rasterization into single-sample targets) ----------
// The console evaluates coverage and depth of such a pass at sample 0 of the programmed sample
// pattern. PS4 Pro checkerboard rendering depends on that being bit-exact: a 2x depth pre-pass
// is copied (sample 0) into a 1x buffer and the G-buffer pass then tests depth EQUAL against
// it. Metal cannot rasterize a single-sample pass at a custom position with the same depth
// interpolation as a multisampled one, so the pass is drawn into multisampled stand-ins of
// its targets with the same sample positions, and sample 0 is written back afterwards.

static bool IsUintFormat(MTLPixelFormat f) {
    switch (f) {
    case MTLPixelFormatR8Uint: case MTLPixelFormatRG8Uint: case MTLPixelFormatRGBA8Uint:
    case MTLPixelFormatR16Uint: case MTLPixelFormatRG16Uint: case MTLPixelFormatRGBA16Uint:
    case MTLPixelFormatR32Uint: case MTLPixelFormatRG32Uint: case MTLPixelFormatRGBA32Uint:
    case MTLPixelFormatRGB10A2Uint:
        return true;
    default:
        return false;
    }
}

static bool IsSintFormat(MTLPixelFormat f) {
    switch (f) {
    case MTLPixelFormatR8Sint: case MTLPixelFormatRG8Sint: case MTLPixelFormatRGBA8Sint:
    case MTLPixelFormatR16Sint: case MTLPixelFormatRG16Sint: case MTLPixelFormatRGBA16Sint:
    case MTLPixelFormatR32Sint: case MTLPixelFormatRG32Sint: case MTLPixelFormatRGBA32Sint:
        return true;
    default:
        return false;
    }
}

static bool IsDepthFormat(MTLPixelFormat f) {
    return f == MTLPixelFormatDepth16Unorm || f == MTLPixelFormatDepth32Float ||
           f == MTLPixelFormatDepth32Float_Stencil8;
}

id<MTLRenderPipelineState> DepthCopyPso(MTLPixelFormat fmt, NSUInteger samples, bool from_ms);

// Multisampled stand-in of a single-sample color or depth target.
id<MTLTexture> EqaaTwin(id<MTLTexture> t, uint32_t samples) {
    auto it = S.eqaa_twin.find((__bridge void*)t);
    if (it != S.eqaa_twin.end() && it->second.sampleCount == samples) return it->second;
    MTLTextureDescriptor* td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:t.pixelFormat width:t.width
                                                                                 height:t.height mipmapped:NO];
    td.textureType = MTLTextureType2DMultisample;
    td.sampleCount = samples;
    td.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
    td.storageMode = MTLStorageModePrivate;
    id<MTLTexture> twin = [S.dev newTextureWithDescriptor:td];
    if (!twin) return nil;
    if (it != S.eqaa_twin.end()) S.eqaa_orig.erase((__bridge void*)it->second);
    S.eqaa_twin[(__bridge void*)t] = twin;
    S.eqaa_orig[(__bridge void*)twin] = t;
    return twin;
}

// Copies src into dst where one of them is multisampled: every sample from the single-sample
// texture, or sample 0 of the multisampled one.
void EqaaCopy(id<MTLTexture> src, id<MTLTexture> dst) {
    const bool to_ms = dst.sampleCount > 1;
    const MTLPixelFormat f = dst.pixelFormat;
    id<MTLRenderPipelineState> pso = nil;
    if (IsDepthFormat(f)) {
        pso = DepthCopyPso(f, dst.sampleCount, !to_ms);
    } else {
        const int kind = IsUintFormat(f) ? 1 : IsSintFormat(f) ? 2 : 0;
        const uint64_t key = ((uint64_t)f << 8) | (dst.sampleCount << 3) | (to_ms ? 4 : 0) | kind;
        __strong id<MTLRenderPipelineState>& p = S.eqaa_psos[key];
        if (!p && S.util_lib) {
            static const char* names[2][3] = {{"eqaa_resolve_f", "eqaa_resolve_u", "eqaa_resolve_i"},
                                              {"eqaa_spread_f", "eqaa_spread_u", "eqaa_spread_i"}};
            MTLRenderPipelineDescriptor* pd = [MTLRenderPipelineDescriptor new];
            pd.vertexFunction = [S.util_lib newFunctionWithName:@"present_vs"];
            pd.fragmentFunction = [S.util_lib newFunctionWithName:[NSString stringWithUTF8String:names[to_ms][kind]]];
            pd.colorAttachments[0].pixelFormat = f;
            pd.rasterSampleCount = dst.sampleCount;
            NSError* err = nil;
            p = [S.dev newRenderPipelineStateWithDescriptor:pd error:&err];
            if (!p) RLog("eqaa-pso", "EQAA copy pipeline failed: %s", err.localizedDescription.UTF8String);
        }
        pso = p;
    }
    if (!pso) return;
    EnsureCmd();
    MTLRenderPassDescriptor* rp = [MTLRenderPassDescriptor renderPassDescriptor];
    if (IsDepthFormat(f)) {
        if (!S.depth_copy_dss) {
            MTLDepthStencilDescriptor* dd = [MTLDepthStencilDescriptor new];
            dd.depthCompareFunction = MTLCompareFunctionAlways;
            dd.depthWriteEnabled = YES;
            S.depth_copy_dss = [S.dev newDepthStencilStateWithDescriptor:dd];
        }
        rp.depthAttachment.texture = dst;
        rp.depthAttachment.loadAction = MTLLoadActionDontCare;
        rp.depthAttachment.storeAction = MTLStoreActionStore;
        if (HasStencil(f)) {
            rp.stencilAttachment.texture = dst;
            rp.stencilAttachment.loadAction = MTLLoadActionLoad;
            rp.stencilAttachment.storeAction = MTLStoreActionStore;
        }
    } else {
        rp.colorAttachments[0].texture = dst;
        rp.colorAttachments[0].loadAction = MTLLoadActionDontCare;
        rp.colorAttachments[0].storeAction = MTLStoreActionStore;
    }
    id<MTLRenderCommandEncoder> e = [S.cmd renderCommandEncoderWithDescriptor:rp];
    [e setRenderPipelineState:pso];
    if (IsDepthFormat(f)) [e setDepthStencilState:S.depth_copy_dss];
    [e setFragmentTexture:src atIndex:0];
    [e drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
    [e endEncoding];
    S.pending = true;
}

// Writes sample 0 of the stand-ins of the render pass that just ended back to their targets.
void ResolveEqaaPass() {
    if (S.eqaa_open.empty()) return;
    auto open = std::move(S.eqaa_open);
    S.eqaa_open.clear();
    for (auto& [twin, target] : open) {
        EqaaCopy(twin, target);
        if (IsDepthFormat(target.pixelFormat)) BumpDepthVersion(target);
    }
    LogWork("EQAA write-back");
}

id<MTLRenderCommandEncoder> BeginPass(const PassKey& key, const ClearReq& clr, id<MTLTexture> const* hold) {
    if (S.cenc) {
        [S.cenc endEncoding];
        S.cenc = nil;
    }
    if (S.renc && S.pass == key && !clr.any()) return S.renc;
    if (S.renc) {
        [S.renc endEncoding];
        S.renc = nil;
        ResolveEqaaPass();
    }
    // EQAA stand-ins start with the contents of their targets (unless cleared by this pass)
    for (int i = 0; i < 9; ++i) {
        id<MTLTexture> t = i < 8 ? key.color[i] : key.depth;
        if (!t) continue;
        auto it = S.eqaa_orig.find((__bridge void*)t);
        if (it == S.eqaa_orig.end()) continue;
        const bool cleared = i < 8 ? clr.color[i] : clr.depth;
        if (!cleared) EqaaCopy(it->second, t);
        S.eqaa_open.emplace_back(t, it->second);
    }
    EnsureCmd();
    MTLRenderPassDescriptor* rp = [MTLRenderPassDescriptor renderPassDescriptor];
    bool any = false;
    for (int i = 0; i < 8; ++i) {
        if (!key.color[i]) continue;
        any = true;
        rp.colorAttachments[i].texture = key.color[i];
        rp.colorAttachments[i].loadAction = clr.color[i] ? MTLLoadActionClear : MTLLoadActionLoad;
        if (clr.color[i]) rp.colorAttachments[i].clearColor = clr.color_value[i];
        rp.colorAttachments[i].storeAction = MTLStoreActionStore;
    }
    if (key.depth) {
        any = true;
        rp.depthAttachment.texture = key.depth;
        rp.depthAttachment.slice = key.depth_slice;
        rp.depthAttachment.loadAction = clr.depth ? MTLLoadActionClear : MTLLoadActionLoad;
        rp.depthAttachment.clearDepth = std::min(1.0, std::max(0.0, clr.depth_value));
        rp.depthAttachment.storeAction = MTLStoreActionStore;
        if (HasStencil(key.depth.pixelFormat)) {
            rp.stencilAttachment.texture = key.depth;
            rp.stencilAttachment.slice = key.depth_slice;
            rp.stencilAttachment.loadAction = clr.stencil ? MTLLoadActionClear : MTLLoadActionLoad;
            rp.stencilAttachment.clearStencil = clr.stencil_value;
            rp.stencilAttachment.storeAction = MTLStoreActionStore;
        }
    }
    if (!any) {
        rp.renderTargetWidth = std::max(1u, key.width);
        rp.renderTargetHeight = std::max(1u, key.height);
        rp.defaultRasterSampleCount = 1;
    }
    // Programmable sample locations (PA_SC_AA_SAMPLE_LOCS): e.g. PS4 Pro checkerboard rendering
    // places the two samples of a 2x target side by side, which later passes rely on.
    if (key.sample_locs && S.dev.programmableSamplePositionsSupported) {
        id<MTLTexture> t = key.depth;
        for (int i = 0; !t && i < 8; ++i) t = key.color[i];
        const NSUInteger n = t ? t.sampleCount : 1;
        if (n > 1 && n <= 4) {
            MTLSamplePosition pos[4];
            for (NSUInteger i = 0; i < n; ++i) {
                const uint32_t b = (key.sample_locs >> (8 * i)) & 0xFF;
                const int sx = (int)((b & 0xF) ^ 8) - 8, sy = (int)(((b >> 4) & 0xF) ^ 8) - 8;
                pos[i] = MTLSamplePositionMake(std::min(15, 8 + sx) / 16.0f, std::min(15, 8 + sy) / 16.0f);
            }
            [rp setSamplePositions:pos count:n];
        }
    }
    S.renc = [S.cmd renderCommandEncoderWithDescriptor:rp];
    g_rstate.Reset(S.renc);
    if (EncoderStatusEnabled()) S.renc.label = WorkLabel("render");
    static const bool labels = getenv("PS4_GNM_LABELS") != nullptr;
    if (labels) {
        // profiling aid: name passes after their targets (shown by Metal System Trace)
        id<MTLTexture> t0 = key.color[0] ? key.color[0] : key.depth;
        int ncol = 0;
        for (int i = 0; i < 8; ++i) ncol += key.color[i] != nil;
        S.renc.label = [NSString stringWithFormat:@"pass %llu: %d color%s %lux%lu fmt %lu depth %s%s",
                                                  (unsigned long long)S.n_passes, ncol, ncol == 1 ? "" : "s",
                                                  (unsigned long)(t0 ? t0.width : key.width),
                                                  (unsigned long)(t0 ? t0.height : key.height),
                                                  (unsigned long)(key.color[0] ? key.color[0].pixelFormat : 0),
                                                  key.depth ? (clr.depth ? "clear" : "load") : "none",
                                                  t0 && t0.sampleCount > 1 ? " msaa" : ""];
    }
    S.n_passes++;
    if (key.depth && !clr.depth) S.n_depth_loads++;
    S.pass = key;
    for (int i = 0; i < 9; ++i) S.pass_hold[i] = hold ? hold[i] : nil;
    return S.renc;
}

id<MTLComputeCommandEncoder> ComputeEncoder() {
    if (S.renc) {
        [S.renc endEncoding];
        S.renc = nil;
        ResolveEqaaPass(); // EQAA stand-ins write sample 0 back before compute reads the targets
        S.pass = PassKey{};
        for (auto& t : S.pass_hold) t = nil;
    }
    EnsureCmd();
    if (!S.cenc) {
        static const bool serial = getenv("PS4_GNM_SERIAL_COMPUTE") != nullptr;
        S.cenc = serial ? [S.cmd computeCommandEncoder]
                        : [S.cmd computeCommandEncoderWithDispatchType:MTLDispatchTypeConcurrent];
        if (EncoderStatusEnabled()) S.cenc.label = WorkLabel("compute");
        g_cstate.Reset(S.cenc);
        S.n_cencs++;
    }
    return S.cenc;
}


// Raw clear words -> MTLClearColor for the attachment's Metal format (the texture has the
// same memory layout as the guest surface, so the raw bits decode directly; cf. shadPS4
// LiverpoolToVK::ColorBufferClearValue).
inline double SrgbToLinear(double c) {
    return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4);
}
inline float Half(uint32_t h) {
    __fp16 v;
    uint16_t x = (uint16_t)h;
    memcpy(&v, &x, 2);
    return (float)v;
}
inline float UFloat(uint32_t v, int mbits) { // unsigned small float with 5 bit exponent
    const uint32_t e = (v >> mbits) & 31, m = v & ((1u << mbits) - 1);
    if (e == 0) return ldexpf((float)m, -14 - mbits);
    if (e == 31) return m ? NAN : INFINITY;
    return ldexpf(1.0f + (float)m / (float)(1u << mbits), (int)e - 15);
}

bool ClearColorFor(MTLPixelFormat f, uint32_t w0, uint32_t w1, MTLClearColor* out) {
    double r = 0, g = 0, b = 0, a = 1;
    switch (f) {
    case MTLPixelFormatRGBA8Unorm:
    case MTLPixelFormatRGBA8Unorm_sRGB:
        r = (w0 & 255) / 255.0; g = ((w0 >> 8) & 255) / 255.0; b = ((w0 >> 16) & 255) / 255.0; a = (w0 >> 24) / 255.0;
        break;
    case MTLPixelFormatBGRA8Unorm:
    case MTLPixelFormatBGRA8Unorm_sRGB:
        b = (w0 & 255) / 255.0; g = ((w0 >> 8) & 255) / 255.0; r = ((w0 >> 16) & 255) / 255.0; a = (w0 >> 24) / 255.0;
        break;
    case MTLPixelFormatRGB10A2Unorm:
        r = (w0 & 1023) / 1023.0; g = ((w0 >> 10) & 1023) / 1023.0; b = ((w0 >> 20) & 1023) / 1023.0; a = (w0 >> 30) / 3.0;
        break;
    case MTLPixelFormatBGR10A2Unorm:
        b = (w0 & 1023) / 1023.0; g = ((w0 >> 10) & 1023) / 1023.0; r = ((w0 >> 20) & 1023) / 1023.0; a = (w0 >> 30) / 3.0;
        break;
    case MTLPixelFormatRG11B10Float:
        r = UFloat(w0 & 2047, 6); g = UFloat((w0 >> 11) & 2047, 6); b = UFloat(w0 >> 22, 5);
        break;
    case MTLPixelFormatRGBA16Float:
        r = Half(w0); g = Half(w0 >> 16); b = Half(w1); a = Half(w1 >> 16);
        break;
    case MTLPixelFormatRGBA16Unorm:
        r = (w0 & 65535) / 65535.0; g = (w0 >> 16) / 65535.0; b = (w1 & 65535) / 65535.0; a = (w1 >> 16) / 65535.0;
        break;
    case MTLPixelFormatRG16Float:
        r = Half(w0); g = Half(w0 >> 16);
        break;
    case MTLPixelFormatRG16Unorm:
        r = (w0 & 65535) / 65535.0; g = (w0 >> 16) / 65535.0;
        break;
    case MTLPixelFormatR16Float:
        r = Half(w0);
        break;
    case MTLPixelFormatR16Unorm:
        r = (w0 & 65535) / 65535.0;
        break;
    case MTLPixelFormatR32Float:
        r = AsF(w0);
        break;
    case MTLPixelFormatRG32Float:
        r = AsF(w0); g = AsF(w1);
        break;
    case MTLPixelFormatRGBA32Float:
        r = g = b = AsF(w0); a = AsF(w1);
        break;
    case MTLPixelFormatR8Unorm:
        r = (w0 & 255) / 255.0;
        break;
    case MTLPixelFormatRG8Unorm:
        r = (w0 & 255) / 255.0; g = ((w0 >> 8) & 255) / 255.0;
        break;
    case MTLPixelFormatR32Uint:
    case MTLPixelFormatR32Sint:
        r = (double)w0;
        break;
    default:
        return false;
    }
    if (f == MTLPixelFormatRGBA8Unorm_sRGB || f == MTLPixelFormatBGRA8Unorm_sRGB) {
        r = SrgbToLinear(r);
        g = SrgbToLinear(g);
        b = SrgbToLinear(b);
    }
    *out = MTLClearColorMake(r, g, b, a);
    return true;
}

void RegisterMeta(uint64_t addr) {
    if (addr) S.meta.emplace(addr, MetaState{});
}

// seq (optional): the command buffer the clear belongs to.
bool TakeMetaCleared(uint64_t addr, uint64_t* seq = nullptr) {
    auto it = S.meta.find(addr);
    if (it == S.meta.end() || !it->second.cleared) return false;
    it->second.cleared = false;
    if (seq) *seq = it->second.cleared_seq;
    return true;
}

// =====================================================================================
// Pipelines
// =====================================================================================
struct VertexAttr {
    uint32_t format, offset, buffer, stride, step_fn, step_rate;
};

// Puts the shader libraries of a pipeline that was just built into the library store, unless
// they are there already (any thread).
void StoreLibraries(const ps4gnm_lib_store::Key* vs, const ps4gnm_lib_store::Key* ps, MTLRenderPipelineDescriptor* d) {
    if (!ps4gnm_lib_store::Enabled()) return;
    if (vs && ps4gnm_lib_store::Has(*vs)) vs = nullptr;
    if (ps && ps4gnm_lib_store::Has(*ps)) ps = nullptr;
    if (vs || ps) ps4gnm_lib_store::StoreRender(vs, ps, d);
}

// Appends a pipeline hash to the list of pipelines built so far (any thread).
void RememberPipeline(uint64_t stable) {
    static std::mutex mu;
    std::lock_guard<std::mutex> lk(mu);
    if (S.pso_list_path.empty()) return;
    if (FILE* f = fopen(S.pso_list_path.c_str(), "ab")) {
        fwrite(&stable, sizeof(stable), 1, f);
        fclose(f);
    }
}

id<MTLRenderPipelineState> GetGfxPipeline(const Shader* vs, const Shader* ps, const RenderState& rs,
                                          const uint32_t color_fmt[8], const uint32_t write_mask[8],
                                          uint32_t depth_fmt, uint32_t samples,
                                          const std::vector<VertexAttr>& attrs,
                                          const std::vector<uint32_t>& attr_locs, bool alpha_to_cov) {
    // only the encoder looks pipelines up (S.gfx_pipes is not locked either)
    static std::string key; // reused: no allocation per draw
    key.clear();
    auto put = [&](const void* p, size_t n) { key.append((const char*)p, n); };
    put(&vs->uid, 8);
    uint64_t psu = ps ? ps->uid : 0;
    put(&psu, 8);
    for (int i = 0; i < 8; ++i) {
        put(&color_fmt[i], 4);
        if (!color_fmt[i]) continue;
        put(&write_mask[i], 4);
        const BlendState& b = rs.blend[i];
        uint32_t bl[7] = {b.enable, b.src_rgb, b.dst_rgb, b.op_rgb, b.src_alpha, b.dst_alpha, b.op_alpha};
        put(bl, sizeof(bl));
    }
    put(&depth_fmt, 4);
    put(&samples, 4);
    uint32_t a2c = alpha_to_cov, rd = rs.raster.rasterizer_discard;
    put(&a2c, 4);
    put(&rd, 4);
    for (size_t i = 0; i < attrs.size(); ++i) {
        put(&attrs[i], sizeof(VertexAttr));
        put(&attr_locs[i], 4);
    }
    // consecutive draws mostly use the same pipeline
    static std::string last_key;
    static id<MTLRenderPipelineState> last_pso;
    if (last_pso && key == last_key) return last_pso;
    auto it = S.gfx_pipes.find(key);
    if (it != S.gfx_pipes.end()) {
        if (it->second) {
            last_key = key;
            last_pso = it->second;
        }
        return it->second;
    }
    // the same key with the shaders' MSL hashes instead of their session ids
    std::string stable_key = key;
    memcpy(&stable_key[0], &vs->msl_hash, 8);
    const uint64_t ps_mh = ps ? ps->msl_hash : 0;
    memcpy(&stable_key[8], &ps_mh, 8);
    const uint64_t stable = Fnv(stable_key.data(), stable_key.size());
    const bool known = S.known_psos.count(stable) != 0;

    MTLRenderPipelineDescriptor* d = [MTLRenderPipelineDescriptor new];
    d.vertexFunction = PipelineFn(vs);
    d.fragmentFunction = ps ? PipelineFn(ps) : nil;
    for (int i = 0; i < 8; ++i) {
        if (!color_fmt[i]) continue;
        MTLRenderPipelineColorAttachmentDescriptor* ca = d.colorAttachments[i];
        BlendState b = rs.blend[i];
        if (b.unsupported) b.enable = false;
        ApplyBlend(b, color_fmt[i], ca);
        ca.writeMask = (MTLColorWriteMask)write_mask[i];
        // integer formats cannot blend
        if (ca.pixelFormat == MTLPixelFormatR32Uint || ca.pixelFormat == MTLPixelFormatR32Sint ||
            ca.pixelFormat == MTLPixelFormatRG32Uint || ca.pixelFormat == MTLPixelFormatRGBA32Uint ||
            ca.pixelFormat == MTLPixelFormatR16Uint || ca.pixelFormat == MTLPixelFormatRGBA16Uint ||
            ca.pixelFormat == MTLPixelFormatR8Uint || ca.pixelFormat == MTLPixelFormatRGBA8Uint ||
            ca.pixelFormat == MTLPixelFormatRG16Uint || ca.pixelFormat == MTLPixelFormatRG8Uint)
            ca.blendingEnabled = NO;
    }
    if (depth_fmt) {
        d.depthAttachmentPixelFormat = (MTLPixelFormat)depth_fmt;
        if (HasStencil((MTLPixelFormat)depth_fmt)) d.stencilAttachmentPixelFormat = (MTLPixelFormat)depth_fmt;
    }
    d.rasterSampleCount = samples;
    d.alphaToCoverageEnabled = alpha_to_cov;
    d.rasterizationEnabled = !rs.raster.rasterizer_discard;
    if (!attrs.empty()) {
        MTLVertexDescriptor* vd = [MTLVertexDescriptor vertexDescriptor];
        for (size_t i = 0; i < attrs.size(); ++i) {
            const VertexAttr& a = attrs[i];
            const uint32_t loc = attr_locs[i];
            vd.attributes[loc].format = (MTLVertexFormat)a.format;
            vd.attributes[loc].offset = a.offset;
            vd.attributes[loc].bufferIndex = a.buffer;
            vd.layouts[a.buffer].stride = a.stride;
            vd.layouts[a.buffer].stepFunction = (MTLVertexStepFunction)a.step_fn;
            vd.layouts[a.buffer].stepRate = a.step_rate;
        }
        d.vertexDescriptor = vd;
    }
    ps4gnm_pso_archive::Attach(d);
    if (S.async_compile && !known) {
        // Build a new pipeline in the background; the draw is skipped until it is ready.
        if (S.psos_pending.insert(key).second) {
            const std::string k = key;
            const ps4gnm_lib_store::Key vk = vs->lib_key, pk = ps ? ps->lib_key : ps4gnm_lib_store::Key{};
            const bool vstore = vs->lib_stage != 0, pstore = ps && ps->lib_stage != 0;
            const Shader* rvs = UsesStoredFn(vs) ? vs : nullptr;
            const Shader* rps = UsesStoredFn(ps) ? ps : nullptr;
            [S.dev newRenderPipelineStateWithDescriptor:d
                                      completionHandler:^(id<MTLRenderPipelineState> ps_, NSError* err) {
                                          if (ps_) {
                                              RememberPipeline(stable);
                                              ps4gnm_pso_archive::Add(stable, d);
                                              StoreLibraries(vstore ? &vk : nullptr, pstore ? &pk : nullptr, d);
                                          }
                                          std::lock_guard<std::mutex> lk(S.async_mu);
                                          S.async_psos_done.push_back(
                                              {k, ps_, ps_ ? nil : err.localizedDescription, ps_ ? nullptr : rvs, ps_ ? nullptr : rps});
                                          S.async_psos_ready.fetch_add(1, std::memory_order_release);
                                      }];
            g_hitch.psos++;
            g_compile.pso_async++;
        }
        return nil;
    }
    NSError* e = nil;
    const double pso_t0 = CFAbsoluteTimeGetCurrent();
    id<MTLRenderPipelineState> p = [S.dev newRenderPipelineStateWithDescriptor:d error:&e];
    if (!p) {
        // built with a stored function: compile the MSL of the stored shader(s) and retry once
        if (ReplaceStoredFns(vs, ps)) {
            d.vertexFunction = PipelineFn(vs);
            d.fragmentFunction = ps ? PipelineFn(ps) : nil;
            e = nil;
            p = [S.dev newRenderPipelineStateWithDescriptor:d error:&e];
        }
    }
    g_hitch.pso_ms += (CFAbsoluteTimeGetCurrent() - pso_t0) * 1000.0;
    g_hitch.psos++;
    g_compile.pso_sync.Add((CFAbsoluteTimeGetCurrent() - pso_t0) * 1000.0);
    if (p && !known) RememberPipeline(stable);
    // known pipelines missing from the archive are added once (the next session loads them fast)
    if (p && !ps4gnm_pso_archive::Contains(stable)) ps4gnm_pso_archive::Add(stable, d);
    if (p) StoreLibraries(vs->lib_stage ? &vs->lib_key : nullptr, ps && ps->lib_stage ? &ps->lib_key : nullptr, d);
    if (!p) {
        RLog("pso-fail", "render pipeline (VS 0x%llx PS 0x%llx) failed: %s",
             (unsigned long long)vs->code_addr, (unsigned long long)(ps ? ps->code_addr : 0),
             e.localizedDescription.UTF8String);
    }
    S.gfx_pipes[key] = p;
    return p;
}

id<MTLDepthStencilState> GetDepthStencil(const DepthStencilState& ds, bool has_depth, bool has_stencil) {
    DepthStencilState k = ds;
    if (!has_depth) {
        k.depth_test = false;
        k.depth_write = false;
    }
    if (!has_stencil) k.stencil_test = false;
    uint32_t raw[16] = {k.depth_test, k.depth_write, k.depth_compare, k.stencil_test,
                        k.front.compare, k.front.fail, k.front.depth_fail, k.front.pass,
                        (uint32_t)k.front.read_mask | ((uint32_t)k.front.write_mask << 8),
                        k.back.compare, k.back.fail, k.back.depth_fail, k.back.pass,
                        (uint32_t)k.back.read_mask | ((uint32_t)k.back.write_mask << 8), 0, 0};
    const uint64_t h = Fnv(raw, sizeof(raw));
    auto it = S.ds_states.find(h);
    if (it != S.ds_states.end()) return it->second;
    id<MTLDepthStencilState> st = [S.dev newDepthStencilStateWithDescriptor:MakeDepthStencilDescriptor(k)];
    S.ds_states[h] = st;
    return st;
}

// =====================================================================================
// Primitive emulation (quad lists -> triangle lists), cf. shadPS4 liverpool_to_vk.cpp
// =====================================================================================
bool BuildQuadListIndices(const DrawArgs& a, uint32_t count, __strong id<MTLBuffer>* out, size_t* off,
                          uint32_t* out_count) {
    const uint32_t quads = count / 4;
    if (quads == 0) return false;
    if (count > (8u << 20)) {
        RLog("quad-count", "quad list with %u vertices rejected", count);
        return false;
    }
    const uint32_t n = quads * 6;
    void* ptr;
    if (!S.arena.Alloc(S.dev, (size_t)n * 4, 16, out, off, &ptr)) return false;
    uint32_t* dst = (uint32_t*)ptr;
    const bool i32 = a.index_type == 1;
    const uint8_t* src = nullptr;
    if (a.indexed) {
        const uint64_t isz = i32 ? 4 : 2;
        const uint64_t addr = a.index_base + (uint64_t)a.index_offset * isz;
        if (!a.index_base || addr >= S.ctx->mem_size || (uint64_t)count * isz > S.ctx->mem_size - addr)
            return false;
        src = S.ctx->mem_base + addr;
    }
    auto idx = [&](uint32_t i) -> uint32_t {
        if (!src) return i;
        return i32 ? ((const uint32_t*)src)[i] : ((const uint16_t*)src)[i];
    };
    for (uint32_t q = 0; q < quads; ++q) {
        const uint32_t v0 = idx(q * 4 + 0), v1 = idx(q * 4 + 1), v2 = idx(q * 4 + 2), v3 = idx(q * 4 + 3);
        dst[q * 6 + 0] = v0;
        dst[q * 6 + 1] = v1;
        dst[q * 6 + 2] = v2;
        dst[q * 6 + 3] = v0;
        dst[q * 6 + 4] = v2;
        dst[q * 6 + 5] = v3;
    }
    *out_count = n;
    return true;
}

// =====================================================================================
// Fast clear elimination / resolve passes (shadPS4 Rasterizer::FilterDraw)
// =====================================================================================
// A clear writes every byte of the cleared slices of a color target: an exactly known write
// (TextureCache::NoteExactWrite). Only the first slice of the view (base_slice) is credited, which
// is always a subset of what the PS4 clears.
// seq: the command buffer of the CMASK clear, which can precede the draw that resolves it.
void NoteClearedColor(const ColorTarget& c, id<MTLTexture> t, uint64_t seq) {
    if (!c.slice_bytes || !seq) return;
    const uint64_t lo = c.address + (uint64_t)c.base_slice * c.slice_bytes;
    S.tex->NoteExactWrite(c.address, t, lo, lo + c.slice_bytes, seq);
}

void EliminateFastClear(const RenderState& rs) {
    const ColorTarget& c = rs.color[0];
    if (!c.bound || !c.fast_clear) return;
    uint64_t clear_seq = 0;
    if (!TakeMetaCleared(c.cmask_address, &clear_seq)) return;
    id<MTLTexture> t = S.tex->GetColorTarget(c);
    if (!t) return;
    ClearReq clr;
    if (!ClearColorFor(t.pixelFormat, c.clear_word0, c.clear_word1, &clr.color_value[0])) {
        RLog("clear-fmt", "fast clear: unsupported format %lu", (unsigned long)t.pixelFormat);
        return;
    }
    clr.color[0] = true;
    NoteClearedColor(c, t, clear_seq);
    PassKey k;
    k.color[0] = t;
    id<MTLTexture> hold[9] = {t};
    BeginPass(k, clr, hold);
    EndEncoders();
    S.pending = true;
    LogWork("fast-clear-elim");
}

void ResolvePass(const RenderState& rs) {
    const ColorTarget& src = rs.color[0];
    const ColorTarget& dst = rs.color[1];
    if (!src.bound || !dst.bound) return;
    id<MTLTexture> s = S.tex->GetColorTarget(src);
    id<MTLTexture> d = S.tex->GetColorTarget(dst);
    if (!s || !d) return;
    EndEncoders();
    EnsureCmd();
    if (s.sampleCount > 1 && d.sampleCount == 1 && s.pixelFormat == d.pixelFormat) {
        MTLRenderPassDescriptor* rp = [MTLRenderPassDescriptor renderPassDescriptor];
        rp.colorAttachments[0].texture = s;
        rp.colorAttachments[0].loadAction = MTLLoadActionLoad;
        rp.colorAttachments[0].storeAction = MTLStoreActionMultisampleResolve;
        rp.colorAttachments[0].resolveTexture = d;
        id<MTLRenderCommandEncoder> e = [S.cmd renderCommandEncoderWithDescriptor:rp];
        [e endEncoding];
    } else if (s.sampleCount == d.sampleCount && s.pixelFormat == d.pixelFormat) {
        id<MTLBlitCommandEncoder> bl = [S.cmd blitCommandEncoder];
        [bl copyFromTexture:s sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0, 0, 0)
                 sourceSize:MTLSizeMake(std::min(s.width, d.width), std::min(s.height, d.height), 1)
                  toTexture:d destinationSlice:0 destinationLevel:0 destinationOrigin:MTLOriginMake(0, 0, 0)];
        [bl endEncoding];
    } else {
        RLog("resolve", "resolve between incompatible targets skipped");
        return;
    }
    S.pending = true;
    LogWork("resolve");
}

bool WriteTexturePng(id<MTLTexture> t, const char* path) {
    std::vector<uint8_t> px;
    if (!S.tex->ReadTextureBGRA8(t, DataFormat::FormatInvalid, NumberFormat::Unorm, CompMapping{}, &px)) return false;
    const size_t w = t.width, h = t.height;
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGContextRef bc = CGBitmapContextCreate(px.data(), w, h, 8, w * 4, cs, kCGImageAlphaNoneSkipFirst | kCGBitmapByteOrder32Little);
    CGImageRef img = bc ? CGBitmapContextCreateImage(bc) : NULL;
    bool ok = false;
    if (img) {
        CGImageDestinationRef dst = CGImageDestinationCreateWithURL(
            (__bridge CFURLRef)[NSURL fileURLWithPath:[NSString stringWithUTF8String:path]], CFSTR("public.png"), 1, NULL);
        if (dst) {
            CGImageDestinationAddImage(dst, img, NULL);
            ok = CGImageDestinationFinalize(dst);
            CFRelease(dst);
        }
        CGImageRelease(img);
    }
    if (bc) CGContextRelease(bc);
    CGColorSpaceRelease(cs);
    return ok;
}

// PS4_GNM_DUMP_DRAWS=<submit>: after every draw/dispatch of that submit, write the bound
// color target 0 (draws) as PNG (slow; debugging).
// Present whose draws / render targets were requested at runtime (PS4_PAD_CTL "dumpdraws" /
// "dumprt" debug commands, see g_ps4_gnm_dump_request), UINT64_MAX = none.
static uint64_t s_req_draws_present = UINT64_MAX, s_req_rt_present = UINT64_MAX;

void DumpAfterWork(id<MTLTexture> rt, const char* what) {
    static const char* env = getenv("PS4_GNM_DUMP_DRAWS");
    static const char* dir = getenv("PS4_SCREENSHOT_DIR");
    if (!dir || !rt) return;
    const bool requested = S.present_idx == s_req_draws_present;
    if (!env && !requested) return;
    if (!requested) {
        const bool by_present = env[0] == 'p';
        const uint64_t first = strtoull(env + (by_present ? 1 : 0), nullptr, 0);
        const char* c = strchr(env, ':');
        const uint64_t count = c ? strtoull(c + 1, nullptr, 0) : 1;
        const uint64_t idx = by_present ? S.present_idx : S.submit_idx;
        if (idx < first || idx >= first + count) return;
    }
    static int n = 0;
    Commit();
    WaitAll();
    char path[1024];
    snprintf(path, sizeof(path), "%s/draw_%llu_%03d_%s.png", dir, (unsigned long long)S.submit_idx, n++, what);
    if (!WriteTexturePng(rt, path)) fprintf(stderr, "[gnm-draw] dump draw: cannot write %s\n", path);
}

// PS4_GNM_DUMP_RT=<present index>: write every GPU color target as PNG (debugging)
void DumpTargets(uint64_t present_idx) {
    static const char* env = getenv("PS4_GNM_DUMP_RT");
    static const char* dir = getenv("PS4_SCREENSHOT_DIR");
    if (const int req = g_ps4_gnm_dump_request) {
        g_ps4_gnm_dump_request = 0;
        if (req & 1) s_req_rt_present = present_idx + 1;
        if (req & 2) s_req_draws_present = present_idx + 1;
        if (req & 4) { // trace the work of the next present (like PS4_GNM_TRACE=p<next>:1)
            S.trace_by_present = true;
            S.trace_start = present_idx + 1;
            S.trace_count = 1;
        }
    }
    if (!dir || (present_idx != s_req_rt_present && (!env || strtoull(env, nullptr, 0) != present_idx))) return;
    Commit();
    WaitAll();
    TextureCache* tc = S.tex;
    tc->ForEachGpuTexture(^(uint64_t addr, int kind, id<MTLTexture> t) {
        if (t.sampleCount > 1) return;
        if (kind != 1 && (t.pixelFormat == MTLPixelFormatDepth16Unorm || t.pixelFormat == MTLPixelFormatDepth32Float ||
                          t.pixelFormat == MTLPixelFormatDepth32Float_Stencil8)) {
            // depth targets as grayscale, normalized to their value range
            const size_t w = t.width, h = t.height;
            const bool d16 = t.pixelFormat == MTLPixelFormatDepth16Unorm;
            const size_t bpp = d16 ? 2 : 4;
            id<MTLBuffer> b = [S.dev newBufferWithLength:w * h * bpp options:MTLResourceStorageModeShared];
            id<MTLCommandBuffer> cb = [S.queue commandBuffer];
            id<MTLBlitCommandEncoder> bl = [cb blitCommandEncoder];
            [bl copyFromTexture:t sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0, 0, 0)
                     sourceSize:MTLSizeMake(w, h, 1) toBuffer:b destinationOffset:0 destinationBytesPerRow:w * bpp
                destinationBytesPerImage:w * h * bpp
                         options:t.pixelFormat == MTLPixelFormatDepth32Float_Stencil8 ? MTLBlitOptionDepthFromDepthStencil
                                                                                       : MTLBlitOptionNone];
            [bl endEncoding];
            [cb commit];
            [cb waitUntilCompleted];
            std::vector<float> v(w * h);
            for (size_t i = 0; i < w * h; ++i)
                v[i] = d16 ? ((const uint16_t*)b.contents)[i] / 65535.f : ((const float*)b.contents)[i];
            float lo = 1e30f, hi = -1e30f;
            size_t n1 = 0, n0 = 0;
            for (float f : v) {
                lo = std::min(lo, f), hi = std::max(hi, f);
                n1 += f >= 1.f;
                n0 += f <= 0.f;
            }
            fprintf(stderr, "[gnm-draw] dump depth 0x%llx kind %d type %lu layers %lu %zux%zu fmt %lu: min %g max %g, %.1f%% at 1, %.1f%% at 0\n",
                    (unsigned long long)addr, kind, (unsigned long)t.textureType, (unsigned long)t.arrayLength, w, h, (unsigned long)t.pixelFormat, lo, hi, 100.0 * n1 / v.size(),
                    100.0 * n0 / v.size());
            std::vector<uint8_t> g(w * h);
            const float sc = hi > lo ? 255.f / (hi - lo) : 0.f;
            for (size_t i = 0; i < w * h; ++i) g[i] = (uint8_t)((v[i] - lo) * sc);
            CGColorSpaceRef cs = CGColorSpaceCreateDeviceGray();
            CGContextRef bc = CGBitmapContextCreate(g.data(), w, h, 8, w, cs, kCGImageAlphaNone);
            CGImageRef img = bc ? CGBitmapContextCreateImage(bc) : NULL;
            if (img) {
                NSString* path = [NSString stringWithFormat:@"%s/depth_%llu_%llx_%zux%zu.png", dir,
                                                            (unsigned long long)present_idx, (unsigned long long)addr, w, h];
                CGImageDestinationRef dst = CGImageDestinationCreateWithURL(
                    (__bridge CFURLRef)[NSURL fileURLWithPath:path], CFSTR("public.png"), 1, NULL);
                if (dst) {
                    CGImageDestinationAddImage(dst, img, NULL);
                    CGImageDestinationFinalize(dst);
                    CFRelease(dst);
                }
                CGImageRelease(img);
            }
            if (bc) CGContextRelease(bc);
            CGColorSpaceRelease(cs);
            return;
        }
        if (kind != 1) return;
        std::vector<uint8_t> px;
        if (!tc->ReadTextureBGRA8(t, DataFormat::FormatInvalid, NumberFormat::Unorm, CompMapping{}, &px)) {
            fprintf(stderr, "[gnm-draw] dump: cannot read 0x%llx fmt %lu\n", (unsigned long long)addr, (unsigned long)t.pixelFormat);
            return;
        }
        const size_t w = t.width, h = t.height;
        CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
        CGContextRef bc = CGBitmapContextCreate(px.data(), w, h, 8, w * 4, cs,
                                                kCGImageAlphaNoneSkipFirst | kCGBitmapByteOrder32Little);
        CGImageRef img = bc ? CGBitmapContextCreateImage(bc) : NULL;
        if (img) {
            NSString* path = [NSString stringWithFormat:@"%s/rt_%llu_%llx_f%lu_%zux%zu.png", dir,
                                                        (unsigned long long)present_idx, (unsigned long long)addr,
                                                        (unsigned long)t.pixelFormat, w, h];
            CGImageDestinationRef dst = CGImageDestinationCreateWithURL((__bridge CFURLRef)[NSURL fileURLWithPath:path],
                                                                        CFSTR("public.png"), 1, NULL);
            if (dst) {
                CGImageDestinationAddImage(dst, img, NULL);
                CGImageDestinationFinalize(dst);
                CFRelease(dst);
            }
            CGImageRelease(img);
        }
        if (bc) CGContextRelease(bc);
        CGColorSpaceRelease(cs);
    });
    fprintf(stderr, "[gnm-draw] dumped render targets of present %llu\n", (unsigned long long)present_idx);
    if (const char* peek = getenv("PS4_GNM_PEEK")) { // hex address: print 16 floats there
        const uint64_t a = strtoull(peek, nullptr, 16);
        float f[16];
        if (ReadGuest(S.ctx, a, f, sizeof(f))) {
            fprintf(stderr, "[gnm-draw] peek 0x%llx:", (unsigned long long)a);
            for (float v : f) fprintf(stderr, " %g", v);
            fprintf(stderr, "\n");
        }
    }
}

bool ShouldTrace() {
    const uint64_t idx = S.trace_by_present ? S.present_idx : S.submit_idx;
    return S.trace_count && idx >= S.trace_start && idx < S.trace_start + S.trace_count;
}

} // namespace

// =====================================================================================
// Public API
// =====================================================================================
bool Init(GuestContext* ctx) {
    if (S.init_tried) return S.enabled;
    S.init_tried = true;
    const char* e = getenv("PS4_GNM_METAL_DRAW");
    if (e && strcmp(e, "0") == 0) {
        fprintf(stderr, "[gnm-draw] GPU rendering disabled (PS4_GNM_METAL_DRAW=0)\n");
        return false;
    }
    if (!ctx || !ctx->mem_base) return false;
    GuestContext* proc = ctx->process_ctx ? ctx->process_ctx : ctx;
    S.ctx = proc;
    // ReadGuest is a bounds-checked copy from mem_base: let the recompiler read directly
    // (pointer walks of resource tables run for every draw); not while tracing the reads
    if (!getenv("PS4_GNM_TRACE_BUFS")) gcn_set_direct_guest_memory(ReadGuest, proc, proc->mem_base, proc->mem_size);
    @autoreleasepool {
        S.dev = (__bridge id<MTLDevice>)ps4_metal_screen_get_device();
        if (!S.dev) S.dev = MTLCreateSystemDefaultDevice();
        // New shaders and pipelines are built in the background and draws using them are
        // skipped until they are ready (building them inline stalls for seconds when an area
        // is entered for the first time). Shaders and pipelines seen in an earlier session are
        // cheap to rebuild and are built inline, so work the game renders only once (e.g. its
        // static shadow cache) is not lost once the caches are warm. PS4_GNM_SYNC_COMPILE=1
        // builds everything inline.
        S.async_compile = getenv("PS4_GNM_SYNC_COMPILE") == nullptr;
        if (!S.dev) return false;
        // Compute kernels compile in the background and their dispatches wait for them on the
        // encoder thread (ps4_gnm_kernel_compile.h); PS4_GNM_SYNC_KERNELS=1 (or
        // PS4_GNM_SYNC_COMPILE=1) compiles them on the CP thread as before.
        if (S.async_compile && !getenv("PS4_GNM_SYNC_KERNELS"))
        {
            // PS4_GNM_KERNEL_COMPILES: compiles at once (default 4)
            const char* e = getenv("PS4_GNM_KERNEL_COMPILES");
            const int n = e ? atoi(e) : 0;
            S.kernels = std::make_unique<ps4gnm_kernels::Compiler>(S.dev, CompileOptions,
                                                                   n > 0 && n <= 64 ? (unsigned)n : 4u);
        }
        StartGpuMemSampler(proc->mem_size);
        S.queue = [S.dev newCommandQueueWithMaxCommandBufferCount:64];
        S.queue.label = @"gnm";
        S.tex = new TextureCache(S.dev, S.queue, proc->mem_base, proc->mem_size);
        g_mem_tex.store(S.tex, std::memory_order_release);
        S.dummy = [S.dev newBufferWithLength:65536 options:MTLResourceStorageModeShared];
        S.gds = (uint8_t*)mmap(nullptr, 0x10000, PROT_READ | PROT_WRITE, MAP_ANON | MAP_PRIVATE, -1, 0);
        if (S.gds == MAP_FAILED) S.gds = nullptr;
        if (S.gds)
            S.gds_buf = [S.dev newBufferWithBytesNoCopy:S.gds length:0x10000
                                                options:MTLResourceStorageModeShared deallocator:nil];
        if (!S.gds_buf) S.gds_buf = S.dummy;
        gcn_profile_default_metal(&S.profile);
        // PS4_GNM_QUIT_AFTER_S=<s> (benchmarks): quit through the normal quit path after <s>
        // seconds, so the caches are saved as when the player quits (a killed process loses the
        // pipeline archive additions since its last save).
        if (const char* q = getenv("PS4_GNM_QUIT_AFTER_S"); q && atof(q) > 0) {
            const double secs = atof(q);
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(secs * NSEC_PER_SEC)),
                           dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
                               fprintf(stderr, "[gnm-draw] PS4_GNM_QUIT_AFTER_S: quitting after %.0f s\n", secs);
                               PrintCompileStats();
                               ps4_host_quit(0);
                           });
        }
        StartShaderWarmup();
        if (!S.msl_cache_dir.empty()) {
            // PS4_GNM_PSO_ARCHIVE_MB: archive size budget; not a positive number -> 384
            const char* mb = getenv("PS4_GNM_PSO_ARCHIVE_MB");
            char* mb_end = nullptr;
            long long mb_v = mb ? strtoll(mb, &mb_end, 10) : 0;
            if (!mb || mb_end == mb || *mb_end || mb_v <= 0 || mb_v > (1ll << 20)) mb_v = 384;
            const uint64_t budget = (uint64_t)mb_v << 20;
            if (ps4gnm_pso_archive::Open(S.dev, S.msl_cache_dir, budget)) ps4gnm_pso_archive::StartPeriodicSave(300);
        }
        if (getenv("PS4_GNM_NO_BOUNDS_EMIT")) S.profile.needs_buffer_bounds_checks = false; // debug A/B
        gcn_msl_options_default(&S.msl);
        ps4gnm_shader_cache::Start(S.profile, S.msl);
        gcn_set_log_level(4);
        if (const char* t = getenv("PS4_GNM_TRACE")) {
            // "<count>", "<first_submit>:<count>" or "p<first_present>:<count>" (present indices)
            if (t[0] == 'p') {
                S.trace_by_present = true;
                t++;
            }
            const char* c = strchr(t, ':');
            if (c) {
                S.trace_start = strtoull(t, nullptr, 0);
                S.trace_count = strtoull(c + 1, nullptr, 0);
            } else {
                S.trace_count = strtoull(t, nullptr, 0);
            }
        }
        if (const char* t = getenv("PS4_GNM_GPU_TIMEOUT")) S.gpu_timeout_ms = std::max(100, atoi(t));

        // presentation converter: fullscreen triangle, texel fetch from the source target
        static const char* kPresent = R"(
#include <metal_stdlib>
using namespace metal;
struct VOut { float4 pos [[position]]; };
vertex VOut present_vs(uint vid [[vertex_id]]) {
    VOut o;
    float2 uv = float2((vid << 1) & 2, vid & 2);
    o.pos = float4(uv * 2.0 - 1.0, 0.0, 1.0);
    return o;
}
struct DepthOutC { float depth [[depth(any)]]; };
fragment float4 depth2color_ms_fs(VOut in [[stage_in]], uint sid [[sample_id]], depth2d_ms<float> src [[texture(0)]]) {
    uint2 p = min(uint2(in.pos.xy), uint2(src.get_width() - 1, src.get_height() - 1));
    return float4(src.read(p, sid), 0.0, 0.0, 1.0);
}
fragment DepthOutC depth_from_color_fs(VOut in [[stage_in]], texture2d<float> src [[texture(0)]]) {
    uint2 p = min(uint2(in.pos.xy), uint2(src.get_width() - 1, src.get_height() - 1));
    DepthOutC o;
    o.depth = src.read(p).r;
    return o;
}
fragment float4 eqaa_resolve_f(VOut in [[stage_in]], texture2d_ms<float> src [[texture(0)]]) {
    return src.read(uint2(in.pos.xy), 0);
}
fragment uint4 eqaa_resolve_u(VOut in [[stage_in]], texture2d_ms<uint> src [[texture(0)]]) {
    return src.read(uint2(in.pos.xy), 0);
}
fragment int4 eqaa_resolve_i(VOut in [[stage_in]], texture2d_ms<int> src [[texture(0)]]) {
    return src.read(uint2(in.pos.xy), 0);
}
fragment float4 eqaa_spread_f(VOut in [[stage_in]], texture2d<float> src [[texture(0)]]) {
    return src.read(uint2(in.pos.xy));
}
fragment uint4 eqaa_spread_u(VOut in [[stage_in]], texture2d<uint> src [[texture(0)]]) {
    return src.read(uint2(in.pos.xy));
}
fragment int4 eqaa_spread_i(VOut in [[stage_in]], texture2d<int> src [[texture(0)]]) {
    return src.read(uint2(in.pos.xy));
}
struct StencilOut { uint stencil [[stencil]]; };
fragment StencilOut stencil_from_color_fs(VOut in [[stage_in]], texture2d<uint> src [[texture(0)]]) {
    uint2 p = min(uint2(in.pos.xy), uint2(src.get_width() - 1, src.get_height() - 1));
    StencilOut o;
    o.stencil = src.read(p).r;
    return o;
}
struct DepthOut { float depth [[depth(any)]]; };
fragment DepthOut depth_from_ms_fs(VOut in [[stage_in]], depth2d_ms<float> src [[texture(0)]]) {
    uint2 p = min(uint2(in.pos.xy), uint2(src.get_width() - 1, src.get_height() - 1));
    DepthOut o;
    o.depth = src.read(p, 0);
    return o;
}
fragment DepthOut depth_to_ms_fs(VOut in [[stage_in]], depth2d<float> src [[texture(0)]]) {
    uint2 p = min(uint2(in.pos.xy), uint2(src.get_width() - 1, src.get_height() - 1));
    DepthOut o;
    o.depth = src.read(p);
    return o;
}
fragment float4 depth2color_fs(VOut in [[stage_in]], depth2d<float> src [[texture(0)]]) {
    uint2 p = min(uint2(in.pos.xy), uint2(src.get_width() - 1, src.get_height() - 1));
    return float4(src.read(p), 0.0, 0.0, 1.0);
}
// GPU texture upload: linear element i <- tiled element at byte offset map[i]
kernel void detile_gather(device const uchar* src [[buffer(0)]], device uchar* dst [[buffer(1)]],
                          device const uint* map [[buffer(2)]], constant uint4& p [[buffer(3)]],
                          uint i [[thread_position_in_grid]]) {
    if (i >= p.y) return;
    const uint o = map[i];
    if (o == 0xffffffffu) return;
    const uint bpe = p.x;
    const ulong d = ulong(i) * bpe;
    switch (bpe) {
    case 1: dst[d] = src[o]; break;
    case 2: *(device ushort*)(dst + d) = *(device const ushort*)(src + o); break;
    case 4: *(device uint*)(dst + d) = *(device const uint*)(src + o); break;
    case 8: *(device uint2*)(dst + d) = *(device const uint2*)(src + o); break;
    case 16: *(device uint4*)(dst + d) = *(device const uint4*)(src + o); break;
    default: for (uint k = 0; k < bpe; ++k) dst[d + k] = src[o + k]; break;
    }
}
fragment float4 present_fs(VOut in [[stage_in]], texture2d<float> src [[texture(0)]]) {
    uint2 p = uint2(in.pos.xy);
    p = min(p, uint2(src.get_width() - 1, src.get_height() - 1));
    return float4(src.read(p).rgb, 1.0);
}
)";
        NSError* err = nil;
        id<MTLLibrary> lib = [S.dev newLibraryWithSource:[NSString stringWithUTF8String:kPresent]
                                                 options:nil error:&err];
        S.util_lib = lib;
        if (lib) {
            MTLRenderPipelineDescriptor* pd = [MTLRenderPipelineDescriptor new];
            pd.vertexFunction = [lib newFunctionWithName:@"present_vs"];
            pd.fragmentFunction = [lib newFunctionWithName:@"present_fs"];
            pd.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
            S.present_pso = [S.dev newRenderPipelineStateWithDescriptor:pd error:&err];
            MTLRenderPipelineDescriptor* dd = [MTLRenderPipelineDescriptor new];
            dd.vertexFunction = pd.vertexFunction;
            dd.fragmentFunction = [lib newFunctionWithName:@"depth2color_fs"];
            dd.colorAttachments[0].pixelFormat = MTLPixelFormatR32Float;
            S.depth2color_pso = [S.dev newRenderPipelineStateWithDescriptor:dd error:&err];
            if (id<MTLFunction> f = [lib newFunctionWithName:@"detile_gather"])
                S.detile_pso = [S.dev newComputePipelineStateWithFunction:f error:&err];
        }
        if (!S.present_pso)
            fprintf(stderr, "[gnm-draw] present pipeline failed: %s\n", err.localizedDescription.UTF8String);
    }
    S.enabled = true;
    fprintf(stderr, "[gnm-draw] native Metal renderer enabled on %s (%s)\n", S.dev.name.UTF8String,
            gcn_version());
    encq::Start();
    return true;
}

bool Enabled() {
    return S.enabled && !S.hung;
}

uint8_t* Gds() {
    static uint8_t fallback[0x10000];
    return S.gds ? S.gds : fallback;
}

void ComputeBarrierImpl() {
    if (S.cenc) [S.cenc memoryBarrierWithScope:MTLBarrierScopeBuffers | MTLBarrierScopeTextures], S.n_cbarriers++;
}

void ComputeBarrier() {
    encq::Defer([] { ComputeBarrierImpl(); });
}

bool GpuDmaImpl(bool src_gds, bool src_fill, uint64_t src, uint32_t fill_value, bool dst_gds, uint64_t dst, uint32_t n) {
    if (!S.enabled || S.hung || !S.gds || n == 0 || (n & 3) || (dst & 3) || (!src_fill && (src & 3))) return false;
    // Metal blits on macOS need 4-byte aligned offsets and sizes
    id<MTLBuffer> db = nil, sb = nil;
    uint64_t doff = 0, soff = 0;
    if (dst_gds) {
        if (dst + n > 0x10000) return false;
        db = S.gds_buf;
        doff = dst;
    } else if (!GuestBuffer(dst, n, GuestAccess::Write, &db, &doff)) {
        return false;
    }
    if (src_fill) {
        const uint8_t b0 = fill_value & 0xFF;
        const bool bytes_equal = fill_value == b0 * 0x01010101u;
        if (!bytes_equal) {
            if (n > 0x10000) return false;
            std::vector<uint32_t> pat(n / 4, fill_value);
            sb = [S.dev newBufferWithBytes:pat.data() length:n options:MTLResourceStorageModeShared];
            if (!sb) return false;
        }
    } else if (src_gds) {
        if (src + n > 0x10000) return false;
        sb = S.gds_buf;
        soff = src;
    } else if (!GuestBuffer(src, n, GuestAccess::Read, &sb, &soff)) {
        return false;
    }
    EndEncoders();
    EnsureCmd();
    id<MTLBlitCommandEncoder> bl = [S.cmd blitCommandEncoder];
    if (src_fill && !sb)
        [bl fillBuffer:db range:NSMakeRange(doff, n) value:(uint8_t)(fill_value & 0xFF)];
    else
        [bl copyFromBuffer:sb sourceOffset:soff toBuffer:db destinationOffset:doff size:n];
    [bl endEncoding];
    LogWork("dma");
    if (!dst_gds) NoteGpuWrite(dst, n);
    return true;
}

bool GuestRangeOk(uint64_t addr, uint64_t size);

// Decides on the CP thread (the caller falls back to a CPU copy) whether GpuDmaImpl can do it.
bool GpuDma(bool src_gds, bool src_fill, uint64_t src, uint32_t fill_value, bool dst_gds, uint64_t dst, uint32_t n) {
    if (!S.enabled || S.hung || !S.gds || n == 0 || (n & 3) || (dst & 3) || (!src_fill && (src & 3))) return false;
    if (dst_gds ? (uint64_t)dst + n > 0x10000 : !GuestRangeOk(dst, n)) return false;
    if (src_fill) {
        if (fill_value != (fill_value & 0xFF) * 0x01010101u && n > 0x10000) return false;
    } else if (src_gds ? (uint64_t)src + n > 0x10000 : !GuestRangeOk(src, n)) {
        return false;
    }
    encq::Defer([=] {
        if (!GpuDmaImpl(src_gds, src_fill, src, fill_value, dst_gds, dst, n))
            RLog("dma-fail", "GPU DMA 0x%llx -> 0x%llx (%u bytes) failed on the encoder", (unsigned long long)src,
                 (unsigned long long)dst, n);
    });
    return true;
}

// shadPS4 src/video_core/amdgpu/regs.cpp: Regs::SetDefaults (values from fpPS4)
void SetRegDefaults(uint32_t* regs) {
    static const uint32_t kDefaults[] = {
        0x00000000u, 0x80000000u, 0x40004000u, 0xdeadbeefu, 0x00000000u, 0x40004000u, 0x00000000u,
        0x40004000u, 0x00000000u, 0x40004000u, 0x00000000u, 0x40004000u, 0xaa99aaaau, 0x00000000u,
        0xdeadbeefu, 0xdeadbeefu, 0x80000000u, 0x40004000u, 0x00000000u, 0x00000000u, 0x80000000u,
        0x40004000u, 0x80000000u, 0x40004000u, 0x80000000u, 0x40004000u, 0x80000000u, 0x40004000u,
        0x80000000u, 0x40004000u, 0x80000000u, 0x40004000u, 0x80000000u, 0x40004000u, 0x80000000u,
        0x40004000u, 0x80000000u, 0x40004000u, 0x80000000u, 0x40004000u, 0x80000000u, 0x40004000u,
        0x80000000u, 0x40004000u, 0x80000000u, 0x40004000u, 0x80000000u, 0x40004000u, 0x80000000u,
        0x40004000u, 0x80000000u, 0x40004000u, 0x00000000u, 0x3f800000u, 0x00000000u, 0x3f800000u,
        0x00000000u, 0x3f800000u, 0x00000000u, 0x3f800000u, 0x00000000u, 0x3f800000u, 0x00000000u,
        0x3f800000u, 0x00000000u, 0x3f800000u, 0x00000000u, 0x3f800000u, 0x00000000u, 0x3f800000u,
        0x00000000u, 0x3f800000u, 0x00000000u, 0x3f800000u, 0x00000000u, 0x3f800000u, 0x00000000u,
        0x3f800000u, 0x00000000u, 0x3f800000u, 0x00000000u, 0x3f800000u, 0x00000000u, 0x3f800000u,
        0x2a00161au,
    };
    // CLEAR_STATE resets the context registers only (SH/uconfig state persists on hardware;
    // shadPS4 clears the whole array, which loses shader programs set before the clear).
    memset(&regs[0xA000], 0, 0x2000 * sizeof(uint32_t));
    memcpy(&regs[0xA000 + 0x80], kDefaults, sizeof(kDefaults));
    regs[0xA000 + 0x000d] = 0x40004000u;
    regs[0xA000 + 0x01b6] = 0x00000002u;
    regs[0xA000 + 0x0204] = 0x00090000u;
    regs[0xA000 + 0x0205] = 0x00000004u;
    regs[0xA000 + 0x0295] = 0x00000100u;
    regs[0xA000 + 0x0296] = 0x00000080u;
    regs[0xA000 + 0x0297] = 0x00000002u;
    regs[0xA000 + 0x02aa] = 0x00001000u;
    regs[0xA000 + 0x02f7] = 0x00001000u;
    regs[0xA000 + 0x02f9] = 0x00000005u;
    regs[0xA000 + 0x02fa] = 0x3f800000u;
    regs[0xA000 + 0x02fb] = 0x3f800000u;
    regs[0xA000 + 0x02fc] = 0x3f800000u;
    regs[0xA000 + 0x02fd] = 0x3f800000u;
    regs[0xA000 + 0x0316] = 0x0000000eu;
    regs[0xA000 + 0x0317] = 0x00000010u;
}

void AfterGpuImpl(std::function<void()> fn) {
    if (!S.enabled || S.hung) {
        if (S.hung) RunFences(~0ull >> 1);
        fn();
        return;
    }
    // The action belongs to the end of everything encoded so far. Work still being recorded
    // goes into the open command buffer, which gets sequence number committed_seq + 1 when it
    // is committed; tag the action with that number instead of committing right away, so a
    // stream with many fences (one per compute dispatch, occlusion query, ...) still ends up in
    // a few command buffers. Every CP entry point commits the open buffer before returning
    // (ps4_gnm_metal.mm), so the action cannot be stranded.
    bool now = false;
    {
        std::lock_guard<std::mutex> lk(S.fence_mu);
        const uint64_t seq = S.committed_seq + (S.cmd ? 1 : 0);
        if (!S.cmd && S.fence_q.empty() && S.completed_seq >= S.committed_seq) now = true;
        else S.fence_q.push_back({seq, std::move(fn)});
    }
    if (now) {
        std::lock_guard<std::recursive_mutex> run(S.fence_run_mu);
        fn();
    } else if (!S.cmd) {
        // the command buffers may already have completed before the push (otherwise the
        // completion handler of the last one runs the action)
        uint64_t done;
        bool ready;
        {
            std::lock_guard<std::mutex> lk(S.fence_mu);
            done = S.completed_seq;
            ready = !S.fence_q.empty() && S.fence_q.front().first <= done;
        }
        if (ready) RunFences(done);
    }
}

// Fence actions belong behind the work handed to the encoder before them.
void AfterGpu(std::function<void()> fn) {
    if (encq::Inline()) {
        AfterGpuImpl(std::move(fn));
        return;
    }
    encq::Defer([f = std::move(fn)]() mutable { AfterGpuImpl(std::move(f)); });
}

void SetExtentHints(const uint32_t cb[8], uint32_t db) {
    memcpy(S.cb_extent, cb, sizeof(S.cb_extent));
    S.db_extent = db;
}

void OnSubmit() {
    S.submit_idx++;
}

bool HasPendingWork() {
    if (encq::Pending() || g_cmd_open.load(std::memory_order_acquire)) return true;
    std::lock_guard<std::mutex> lk(S.fence_mu);
    return S.completed_seq < S.committed_seq;
}

void FlushImpl(bool wait) {
    if (!S.enabled) return;
    @autoreleasepool {
        Commit();
        if (wait) {
            WaitAll();
        }
    }
}

// Flush(true) returns once the GPU finished everything submitted so far (CPU reads follow).
void Flush(bool wait) {
    if (wait) encq::Run([] { FlushImpl(true); });
    else encq::Defer([] { FlushImpl(false); });
}

void NotifyGuestWriteImpl(uint64_t addr, uint64_t size, bool is_fill, uint32_t fill_value);

// The guest memory was just written by the CPU: the texture cache must see it before any
// later draw, and after the earlier ones (the callers drained the GPU first).
void NotifyGuestWrite(uint64_t addr, uint64_t size, bool is_fill, uint32_t fill_value) {
    encq::Run([=] { NotifyGuestWriteImpl(addr, size, is_fill, fill_value); });
}

void NotifyGuestWriteImpl(uint64_t addr, uint64_t size, bool is_fill, uint32_t fill_value) {
    if (!S.enabled) return;
    (void)fill_value;
    if (is_fill) {
        auto it = S.meta.find(addr);
        if (it != S.meta.end()) {
            it->second.cleared = true;
            it->second.cleared_seq = S.committed_seq + 1;
        }
    }
    if (S.tex) S.tex->InvalidateRange(addr, size, false);
}

// A draw prepared by the CP thread (Draw) for the encoder thread (DrawEncode).
struct VtxIn {
    BufferDesc bd;
    VertexFormatInfo vf;
};
struct DrawRec {
    DrawArgs args;
    RenderState rs;
    RegSnap regs;
    bool trace = false;
    Shader* vs = nullptr;
    Shader* ps = nullptr;
    uint64_t vs_addr = 0, ps_addr = 0;
    uint32_t vs_ud[16] = {}, ps_ud[16] = {};
    std::vector<uint32_t> vs_flat, ps_flat;
    std::vector<VtxIn> vtx;
    StageImages vs_img, ps_img;
    // ready for the next draw, keeping the capacity of the vectors. Draw() sets everything else
    // (rs is reset by DecodeRenderState, regs entirely written by Capture).
    void Recycle() {
        args = DrawArgs{};
        trace = false;
        vs = ps = nullptr;
        vs_addr = ps_addr = 0;
        memset(vs_ud, 0, sizeof(vs_ud));
        memset(ps_ud, 0, sizeof(ps_ud));
        vs_flat.clear();
        ps_flat.clear();
        vtx.clear();
        vs_img.Clear();
        ps_img.Clear();
    }
};
void DrawEncode(DrawRec& r);

// Draw and dispatch records are reused, so preparing and retiring one does not allocate. Taken
// by the CP thread, returned by the encoder.
template <class T>
struct RecPool {
    static constexpr size_t kBatch = 64;
    std::mutex mu;
    std::vector<T*> free; // batches returned by Put
    T* Get() {
        static thread_local std::vector<T*> mine;
        if (mine.empty()) {
            std::lock_guard<std::mutex> lk(mu);
            mine.swap(free);
        }
        if (mine.empty()) return new T();
        T* p = mine.back();
        mine.pop_back();
        return p;
    }
    void Put(T* p) {
        p->Recycle();
        static thread_local std::vector<T*> back;
        back.push_back(p);
        if (back.size() < kBatch) return;
        std::lock_guard<std::mutex> lk(mu);
        if (free.size() < 8 * kBatch) free.insert(free.end(), back.begin(), back.end());
        else
            for (T* q : back) delete q;
        back.clear();
    }
    // returns a record that did not reach the encoder
    struct Back {
        RecPool* pool;
        void operator()(T* p) const { pool->Put(p); }
    };
};
RecPool<DrawRec> g_draw_recs;

bool GuestRangeOk(uint64_t addr, uint64_t size) {
    const GuestContext* ctx = S.ctx;
    return ctx && addr && size && addr < ctx->mem_size && size <= ctx->mem_size - addr;
}

bool Draw(GuestContext* ctx, const uint32_t* regs, const DrawArgs& args) {
    if (!Init(ctx) || S.hung) return true;
    @autoreleasepool {
        std::unique_ptr<DrawRec, RecPool<DrawRec>::Back> rp(g_draw_recs.Get(), {&g_draw_recs});
        DrawRec& r = *rp;
        r.args = args;
        RenderState& rs = r.rs;
        DecodeRenderState(regs, &rs);
        for (int i = 0; i < 8; ++i) {
            rs.color[i].extent_width = S.cb_extent[i] & 0xFFFF;
            rs.color[i].extent_height = S.cb_extent[i] >> 16;
        }
        rs.depth.extent_width = S.db_extent & 0xFFFF;
        rs.depth.extent_height = S.db_extent >> 16;
        const bool trace = r.trace = ShouldTrace();

        // ---- FilterDraw
        if (trace && rs.color_mode != 1)
            fprintf(stderr, "[gnm-trace] %s color_mode=%u cb0=0x%llx %ux%u s%u fmt %u/%u fc=%d cmask=0x%llx cb1=0x%llx %ux%u s%u\n",
                    args.name, rs.color_mode, (unsigned long long)rs.color[0].address, rs.color[0].pitch,
                    rs.color[0].height, rs.color[0].num_samples, rs.color[0].raw_format, rs.color[0].raw_number_type,
                    rs.color[0].fast_clear, (unsigned long long)rs.color[0].cmask_address,
                    (unsigned long long)rs.color[1].address, rs.color[1].pitch, rs.color[1].height,
                    rs.color[1].num_samples);
        if (rs.color_mode == 2 || rs.color_mode == 5) { // EliminateFastClear / FmaskDecompress
            encq::Defer([rec = rp.release()] {
                EliminateFastClear(rec->rs);
                g_draw_recs.Put(rec);
            });
            return true;
        }
        if (rs.color_mode == 3) {
            encq::Defer([rec = rp.release()] {
                ResolvePass(rec->rs);
                g_draw_recs.Put(rec);
            });
            return true;
        }
        const bool indirect = args.indirect_addr != 0;
        if (rs.raster.prim == PrimitiveType::None || (!indirect && args.count == 0)) return true;
        if (args.count > (16u << 20) || args.num_instances > (1u << 20)) {
            RLog("draw-count", "%s: implausible draw (count %u instances %u); skipped", args.name, args.count,
                 args.num_instances);
            S.n_skipped++;
            return true;
        }
        const uint32_t stages = regs[0xA2D5]; // VGT_SHADER_STAGES_EN
        if (stages & 0x3F) {
            RLog("stages", "%s: unsupported shader stages enabled (VGT_SHADER_STAGES_EN=0x%x)", args.name, stages);
            S.n_skipped++;
            return true;
        }
        if (rs.raster.cull_front_and_back) return true;

        // ---- shaders
        gcn_runtime_info vs_rt{}, ps_rt{};
        gcn_runtime_info_from_regs(regs, 0x10000, GCN_HW_VS, GCN_SW_VERTEX, &S.profile, &vs_rt);
        vs_rt.vs_sw.tess_emulated_primitive = false; // quad lists are expanded to triangles here
        uint64_t& vs_addr = r.vs_addr;
        uint64_t& ps_addr = r.ps_addr;
        uint32_t* const vs_ud = r.vs_ud;
        uint32_t* const ps_ud = r.ps_ud;
        gcn_stage_from_regs(regs, 0x10000, GCN_HW_VS, &vs_addr, vs_ud);
        gcn_stage_from_regs(regs, 0x10000, GCN_HW_PS, &ps_addr, ps_ud);
        DrainAsyncCompiles();
        Shader* vs = GetShader(GCN_HW_VS, GCN_SW_VERTEX, vs_rt, vs_addr, vs_ud, true);
        if (vs && !vs->fn) { // still compiling in the background
            S.n_skipped++;
            g_hitch.pending_draws++;
            return true;
        }
        if (!vs) {
            S.n_skipped++;
            RLog("skip-vs", "%s skipped: VS 0x%llx unavailable", args.name, (unsigned long long)vs_addr);
            return true;
        }
        if (indirect) {
            // The GPU path cannot write baseVertex / startInstance into user SGPRs. It is exact
            // when those SGPRs only feed the fetch shader's index offsets, which the recompiled
            // shader takes from Metal's base vertex / base instance instead.
            const auto& in = vs->info;
            if ((args.base_vertex_ud >= 0 && (!in.has_fetch_shader || args.base_vertex_ud != in.vertex_offset_sgpr)) ||
                (args.start_instance_ud >= 0 &&
                 (!in.has_fetch_shader || args.start_instance_ud != in.instance_offset_sgpr)) ||
                regs[0xA102] != 0 || (args.indexed && !args.max_index))
                return false;
        }
        Shader* ps = nullptr;
        if (ps_addr) {
            gcn_runtime_info_from_regs(regs, 0x10000, GCN_HW_PS, GCN_SW_FRAGMENT, &S.profile, &ps_rt);
            // Metal attachments absorb BGRA component swaps; only the remainder is applied by
            // the shader export.
            for (int i = 0; i < 8; ++i) {
                if (!ps_rt.fs.color_buffers[i].data_format) continue;
                const CompMapping& ex = rs.color[i].export_swizzle;
                for (int k = 0; k < 4; ++k) ps_rt.fs.color_buffers[i].swizzle[k] = (uint8_t)ex[k];
            }
            ps = GetShader(GCN_HW_PS, GCN_SW_FRAGMENT, ps_rt, ps_addr, ps_ud, true);
            if (ps && !ps->fn) { // still compiling in the background
                S.n_skipped++;
                g_hitch.pending_draws++;
                return true;
            }
            if (!ps) {
                S.n_skipped++;
                RLog("skip-ps", "%s skipped: PS 0x%llx unavailable", args.name, (unsigned long long)ps_addr);
                return true;
            }
        }

        if (indirect) {
            // what the encoder's GuestBuffer calls need (CPU fallback otherwise)
            const uint64_t isz = args.index_type == 1 ? 4 : 2;
            if (rs.raster.needs_emulation || !GuestRangeOk(args.indirect_addr, args.indexed ? 20 : 16) ||
                (args.indirect_addr & 3))
                return false;
            if (args.indexed && (!args.index_base || !GuestRangeOk(args.index_base, (uint64_t)args.max_index * isz) ||
                                 (args.index_base & 3)))
                return false;
        }

        // ---- vertex input sharps (guest memory; the encoder binds the buffers)
        const uint32_t vb_first = vs->info.msl_first_free_buffer;
        r.vtx.resize(vs->attrs.size());
        for (uint32_t i = 0; i < vs->attrs.size(); ++i) {
            VtxIn& vi = r.vtx[i];
            uint32_t v[4] = {};
            gcn_shader_fetch_vertex_attrib_sharp(vs->sh, i, vs_ud, ReadGuest, S.ctx, v);
            DecodeBuffer(v, &vi.bd);
            vi.vf = GetVertexFormat(vi.bd.raw_dfmt, vi.bd.raw_nfmt);
            const uint32_t slot = vb_first + i;
            if (slot > 30 || !vi.vf.mtl_vertex_format) {
                RLog("vtx-fmt", "%s: VS 0x%llx attribute %u unsupported (fmt %u/%u slot %u)", args.name,
                     (unsigned long long)vs->code_addr, i, vi.bd.raw_dfmt, vi.bd.raw_nfmt, slot);
                S.n_skipped++;
                return true;
            }
            if (vi.bd.stride & 3) {
                RLog("vtx-stride", "%s: vertex stride %u not a multiple of 4", args.name, vi.bd.stride);
                S.n_skipped++;
                return true;
            }
        }

        // ---- resource tables (flattened user data)
        StageFlat(0, vs, vs_ud);
        r.vs_flat = S.flat_scratch[0];
        if (ps) {
            StageFlat(1, ps, ps_ud);
            r.ps_flat = S.flat_scratch[1];
        }
        DecodeStageImages(vs, r.vs_flat, &r.vs_img);
        if (ps) DecodeStageImages(ps, r.ps_flat, &r.ps_img);
        r.vs = vs;
        r.ps = ps;
        r.regs.Capture(regs);
        encq::Defer([rec = rp.release()] {
            DrawEncode(*rec);
            g_draw_recs.Put(rec);
        });
    }
    return true;
}

// PS4_GNM_COMMIT_EACH=1 (debug): one command buffer per draw or dispatch, so a failing or
// hanging command buffer (PS4_GNM_HANG_REPORT_MS, PS4_GNM_ENCODER_STATUS) names one shader.
void CommitEachForDebug() {
    static const bool each = getenv("PS4_GNM_COMMIT_EACH") != nullptr;
    if (each && S.cmd) Commit();
}

void DrawEncode(DrawRec& r) {
    CommitEachForDebug();
    if (S.hung) return;
    DrainAsyncPsos();
    const DrawArgs& args = r.args;
    RenderState& rs = r.rs;
    const RegSnap& regs = r.regs;
    const bool trace = r.trace;
    Shader* const vs = r.vs;
    Shader* const ps = r.ps;
    const uint64_t vs_addr = r.vs_addr, ps_addr = r.ps_addr;
    const uint32_t* const vs_ud = r.vs_ud;
    const uint32_t* const ps_ud = r.ps_ud;
    const bool indirect = args.indirect_addr != 0;
    char desc[512];
    StageImagesScope images(&r.vs_img, &r.ps_img, nullptr);
    {

        PassKey key;
        id<MTLTexture> hold[9] = {};
        uint32_t color_fmt[8] = {}, write_mask[8] = {};
        ClearReq clr;
        uint32_t rt_w = 16384, rt_h = 16384, samples = 0;
        bool any_rt = false;
        const uint32_t mrt_mask = ps ? ps->info.mrt_mask : 0;
        for (int i = 0; i < 8; ++i) {
            const ColorTarget& c = rs.color[i];
            if (!c.enabled || !(mrt_mask & (1u << i))) continue;
            if (!c.mtl_format) {
                RLog("rt-fmt", "%s: color target %d format %u/%u unsupported", args.name, i, c.raw_format, c.raw_number_type);
                continue;
            }
            if (c.fast_clear || c.compression) RegisterMeta(c.cmask_address);
            id<MTLTexture> t = S.tex->GetColorTarget(c);
            if (!t) continue;
            if (samples && t.sampleCount != samples) {
                RLog("rt-samples", "%s: mixed sample counts", args.name);
                continue;
            }
            samples = (uint32_t)t.sampleCount;
            key.color[i] = t;
            hold[i] = t;
            color_fmt[i] = (uint32_t)t.pixelFormat;
            write_mask[i] = c.mtl_write_mask;
            rt_w = std::min<uint32_t>(rt_w, (uint32_t)t.width);
            rt_h = std::min<uint32_t>(rt_h, (uint32_t)t.height);
            any_rt = true;
            uint64_t clear_seq = 0;
            if (c.fast_clear && TakeMetaCleared(c.cmask_address, &clear_seq)) {
                if (ClearColorFor(t.pixelFormat, c.clear_word0, c.clear_word1, &clr.color_value[i])) {
                    clr.color[i] = true;
                    NoteClearedColor(c, t, clear_seq);
                }
            }
        }
        uint32_t depth_fmt = 0;
        const DepthTarget& db = rs.depth;
        const bool want_depth = rs.ds.depth_test || rs.ds.stencil_test;
        if (trace)
            fprintf(stderr, "[gnm-trace]    AA config 0x%08x locs %08x %08x %08x %08x %08x %08x %08x %08x mask %08x %08x\n",
                    regs[0xA2F8], regs[0xA2FE], regs[0xA2FF], regs[0xA302], regs[0xA303], regs[0xA306], regs[0xA307],
                    regs[0xA30A], regs[0xA30B], regs[0xA30E], regs[0xA30F]);
        if (trace && ((regs[0xA000] & 0xC) || regs[0xA012] != regs[0xA014]))
            fprintf(stderr, "[gnm-trace]    DB copy: render_control 0x%08x z_info 0x%08x z_read 0x%llx z_write 0x%llx eqaa 0x%08x\n",
                    regs[0xA000], regs[0xA010], (unsigned long long)regs[0xA012] << 8,
                    (unsigned long long)regs[0xA014] << 8, regs[0xA201]);
        if (want_depth && db.bound && db.mtl_format) {
            if (db.htile_enable) RegisterMeta(db.htile_address);
            id<MTLTexture> grown_from = nil;
            id<MTLTexture> t = S.tex->GetDepthTarget(db, &grown_from);
            if (t && grown_from) {
                // The array grew (a view selected a later slice): keep the slices written so far.
                EndEncoders();
                EnsureCmd();
                id<MTLBlitCommandEncoder> bl = [S.cmd blitCommandEncoder];
                for (NSUInteger sl = 0; sl < grown_from.arrayLength && sl < t.arrayLength; ++sl)
                    [bl copyFromTexture:grown_from sourceSlice:sl sourceLevel:0 sourceOrigin:MTLOriginMake(0, 0, 0)
                             sourceSize:MTLSizeMake(t.width, t.height, 1) toTexture:t destinationSlice:sl
                       destinationLevel:0 destinationOrigin:MTLOriginMake(0, 0, 0)];
                [bl endEncoding];
            }
            if (trace)
                fprintf(stderr, "[gnm-trace]    depth target z=0x%llx s=0x%llx %ux%u zfmt %u sfmt %u samples %u htile %d (0x%llx) "
                                "func %u test %d write %d clear %d -> %s\n",
                        (unsigned long long)db.z_read_address, (unsigned long long)db.stencil_read_address, db.pitch,
                        db.height, (uint32_t)db.z_format, (uint32_t)db.stencil_format, db.num_samples, db.htile_enable,
                        (unsigned long long)db.htile_address, (regs[0xA200] >> 4) & 7, (regs[0xA200] >> 1) & 1,
                        (regs[0xA200] >> 2) & 1, db.depth_clear_enable, t ? "ok" : "nil");
            if (trace)
                fprintf(stderr, "[gnm-trace]    stencil enable %u depth_control 0x%08x stencil_control 0x%08x refmask 0x%08x 0x%08x clear %d\n",
                        regs[0xA200] & 1, regs[0xA200], regs[0xA10B], regs[0xA10C], regs[0xA10D], db.stencil_clear_enable);
            if (t && (!samples || t.sampleCount == samples)) {
                SyncDepthSibling(db, t);
                samples = (uint32_t)t.sampleCount;
                key.depth = t;
                key.depth_slice = t.textureType == MTLTextureType2DArray
                                      ? std::min<uint32_t>(db.base_slice, (uint32_t)t.arrayLength - 1)
                                      : 0;
                hold[8] = t;
                depth_fmt = (uint32_t)t.pixelFormat;
                rt_w = std::min<uint32_t>(rt_w, (uint32_t)t.width);
                rt_h = std::min<uint32_t>(rt_h, (uint32_t)t.height);
                any_rt = true;
                if (db.stencil_read_address) S.stencil_to_z[db.stencil_read_address] = db.z_read_address;
                const uint32_t dc = regs[0xA200];
                const bool depth_enable = (dc >> 1) & 1, depth_write = (dc >> 2) & 1;
                if (depth_write || rs.ds.stencil_test || db.depth_clear_enable || db.stencil_clear_enable)
                    BumpDepthVersion(t);
                uint64_t htile_seq = 0;
                const bool htile_clear = db.htile_enable && TakeMetaCleared(db.htile_address, &htile_seq);
                if ((db.depth_clear_enable && depth_enable && depth_write) || htile_clear) {
                    clr.depth = true;
                    clr.depth_value = db.depth_clear;
                    // a clear writes every depth byte of the bound slice (the stencil plane is its
                    // own surface on the PS4); only that slice is credited
                    const uint64_t za = db.z_read_address ? db.z_read_address : db.stencil_read_address;
                    // the register clear belongs to this draw; an HTILE clear to its fill
                    const uint64_t seq = (db.depth_clear_enable && depth_enable && depth_write) ? S.committed_seq + 1
                                                                                                 : htile_seq;
                    if (db.z_read_address && db.slice_bytes && seq)
                        S.tex->NoteExactWrite(za, t, za + (uint64_t)db.base_slice * db.slice_bytes,
                                              za + (uint64_t)(db.base_slice + 1) * db.slice_bytes, seq);
                }
                if (db.stencil_clear_enable && HasStencil(t.pixelFormat)) {
                    clr.stencil = true;
                    clr.stencil_value = db.stencil_clear;
                }
            }
        }
        if (!samples) samples = 1;
        const uint32_t aa_samples = 1u << (regs[0xA2F8] & 7); // PA_SC_AA_CONFIG.MSAA_NUM_SAMPLES
        static const bool eqaa_twins = getenv("PS4_GNM_EQAA_VIEWPORT") == nullptr;
        if (eqaa_twins && aa_samples > 1 && aa_samples <= 4 && samples == 1 && key.depth && !rs.ds.stencil_test &&
            S.dev.programmableSamplePositionsSupported) {
            // EQAA: draw into multisampled stand-ins (see EqaaTwin)
            bool ok = true;
            id<MTLTexture> tw[9] = {};
            for (int i = 0; i < 9 && ok; ++i) {
                id<MTLTexture> t = i < 8 ? key.color[i] : key.depth;
                if (!t) continue;
                if (t.textureType != MTLTextureType2D) ok = false;
                else if (!(tw[i] = EqaaTwin(t, aa_samples))) ok = false;
            }
            if (ok) {
                for (int i = 0; i < 8; ++i)
                    if (tw[i]) key.color[i] = hold[i] = tw[i];
                key.depth = hold[8] = tw[8];
                samples = aa_samples;
            }
        }
        // MSAA passes use the game's sample locations (PA_SC_AA_SAMPLE_LOCS)
        if (samples > 1 && aa_samples > 1) key.sample_locs = regs[0xA2FE];
        if (!any_rt) {
            // UAV-only rendering: size the pass from the screen scissor
            rt_w = std::max(1u, std::min(16384u, rs.scissor.x + rs.scissor.width));
            rt_h = std::max(1u, std::min(16384u, rs.scissor.y + rs.scissor.height));
        }
        key.width = any_rt ? 0 : rt_w;
        key.height = any_rt ? 0 : rt_h;

        // ---- vertex inputs (shadPS4 GraphicsPipeline::GetVertexInputs / BindVertexBuffers)
        // reused from draw to draw (only the encoder runs DrawEncode)
        static std::vector<VertexAttr> vattrs;
        static std::vector<uint32_t> vlocs;
        static std::vector<std::pair<id<MTLBuffer>, uint64_t>> vbufs;
        vattrs.clear();
        vlocs.clear();
        vbufs.clear();
        const uint32_t vb_first = vs->info.msl_first_free_buffer;
        for (uint32_t i = 0; i < vs->attrs.size(); ++i) {
            const gcn_vertex_attrib& a = vs->attrs[i];
            const BufferDesc& bd = r.vtx[i].bd; // read and checked by Draw
            const VertexFormatInfo& vf = r.vtx[i].vf;
            const uint32_t slot = vb_first + i;
            VertexAttr va{};
            va.format = vf.mtl_vertex_format;
            va.offset = 0;
            va.buffer = slot;
            uint32_t stride = bd.stride;
            id<MTLBuffer> mb = S.dummy;
            uint64_t off = 0;
            if (bd.address && bd.size) {
                if (!GuestBuffer(bd.address & ~3ull, bd.size + 4, GuestAccess::Read, &mb, &off)) {
                    mb = S.dummy;
                    off = 0;
                }
            }
            if (a.step_rate == 0) {
                va.step_fn = stride ? MTLVertexStepFunctionPerVertex : MTLVertexStepFunctionConstant;
                va.step_rate = stride ? 1 : 0;
            } else {
                va.step_fn = MTLVertexStepFunctionPerInstance;
                va.step_rate = std::max(1u, a.divisor);
            }
            if (stride == 0) va.step_fn = MTLVertexStepFunctionConstant, va.step_rate = 0;
            va.stride = stride;
            vattrs.push_back(va);
            vlocs.push_back(a.location);
            vbufs.push_back({mb, off});
        }

        // ---- pipeline
        const bool a2c = (regs[0xA2DC] & 1) != 0; // DB_ALPHA_TO_MASK
        id<MTLRenderPipelineState> pso =
            GetGfxPipeline(vs, ps, rs, color_fmt, write_mask, depth_fmt, samples, vattrs, vlocs, a2c);
        if (!pso) {
            S.n_skipped++;
            g_hitch.pending_draws++;
            return;
        }

        // ---- viewport / scissor
        MTLViewport vp;
        MTLScissorRect sc;
        const uint32_t pw = any_rt ? rt_w : key.width, ph = any_rt ? rt_h : key.height;
        if (rs.num_viewports > 0) {
            const Viewport& v = rs.viewports[0];
            if (v.flip_y) RLog("flip-y", "%s: positive viewport yscale (y flip) not supported; drawn mirrored", args.name);
            vp = ToMTLViewport(v);
            vp.znear = std::min(1.0, std::max(0.0, vp.znear));
            vp.zfar = std::min(1.0, std::max(0.0, vp.zfar));
            sc = ToMTLScissor(rs.scissors[0], pw, ph);
        } else {
            vp = MTLViewport{0, 0, (double)pw, (double)ph, 0, 1};
            sc = ToMTLScissor(rs.scissor, pw, ph);
        }
        // EQAA (multisampled rasterization, single-sample targets): coverage and depth are
        // evaluated at the location of sample 0, so rasterize the single-sample pass there
        // (Metal has no custom sample positions for single-sample passes).
        if (aa_samples > 1 && samples == 1) {
            const uint32_t b = regs[0xA2FE] & 0xFF;
            const int sx = (int)((b & 0xF) ^ 8) - 8, sy = (int)(((b >> 4) & 0xF) ^ 8) - 8;
            vp.originX -= sx / 16.0;
            vp.originY -= sy / 16.0;
        }
        if (sc.width == 0 || sc.height == 0) {
            RLog("scissor-empty", "%s: empty scissor (%u,%u %ux%u) on %ux%u target; skipped", args.name,
                 rs.scissor.x, rs.scissor.y, rs.scissor.width, rs.scissor.height, pw, ph);
            S.n_skipped++;
            return;
        }

        // ---- index data / primitive emulation
        MTLPrimitiveType prim = (MTLPrimitiveType)rs.raster.mtl_primitive;
        id<MTLBuffer> ib = nil;
        uint64_t ib_off = 0;
        uint32_t draw_count = args.count;
        MTLIndexType itype = args.index_type == 1 ? MTLIndexTypeUInt32 : MTLIndexTypeUInt16;
        bool indexed = args.indexed;
        id<MTLBuffer> arg_buf = nil;
        uint64_t arg_off = 0;
        if (indirect) {
            const uint64_t isz = args.index_type == 1 ? 4 : 2;
            if (rs.raster.needs_emulation ||
                !GuestBuffer(args.indirect_addr, indexed ? 20 : 16, GuestAccess::Read, &arg_buf, &arg_off) || (arg_off & 3))
                { S.n_skipped++; return; }
            if (indexed &&
                (!args.index_base || !GuestBuffer(args.index_base, (uint64_t)args.max_index * isz, GuestAccess::Read, &ib, &ib_off) ||
                 (ib_off & 3)))
                { S.n_skipped++; return; }
        } else if (rs.raster.needs_emulation) {
            if (rs.raster.prim == PrimitiveType::QuadList) {
                size_t aoff;
                if (!BuildQuadListIndices(args, args.count, &ib, &aoff, &draw_count)) {
                    S.n_skipped++;
                    return;
                }
                ib_off = aoff;
                itype = MTLIndexTypeUInt32;
                indexed = true;
                prim = MTLPrimitiveTypeTriangle;
            } else {
                RLog("prim", "%s: primitive type %s not supported yet; skipped", args.name, NameOf(rs.raster.prim));
                S.n_skipped++;
                return;
            }
        } else if (indexed) {
            const uint64_t isz = args.index_type == 1 ? 4 : 2;
            const uint64_t addr = args.index_base + (uint64_t)args.index_offset * isz;
            const uint64_t bytes = (uint64_t)args.count * isz;
            if (!args.index_base || !GuestBuffer(addr, bytes, GuestAccess::Read, &ib, &ib_off)) {
                RLog("ib", "%s: index buffer 0x%llx unavailable", args.name, (unsigned long long)addr);
                S.n_skipped++;
                return;
            }
            if (ib_off & 3) { // Metal wants 4 byte aligned index buffer offsets
                void* ptr;
                size_t aoff;
                if (!S.arena.Alloc(S.dev, bytes, 16, &ib, &aoff, &ptr)) return;
                memcpy(ptr, S.ctx->mem_base + addr, bytes);
                ib_off = aoff;
            }
        }

        // ---- vertex / instance offsets (shadPS4 GetDrawOffsets)
        uint32_t vertex_offset = regs[0xA102]; // VGT_INDX_OFFSET
        uint32_t instance_offset = 0;
        if (vs->info.has_fetch_shader) {
            if (vertex_offset == 0 && vs->info.vertex_offset_sgpr >= 0 && vs->info.vertex_offset_sgpr < 16)
                vertex_offset = vs_ud[vs->info.vertex_offset_sgpr];
            if (vs->info.instance_offset_sgpr >= 0 && vs->info.instance_offset_sgpr < 16)
                instance_offset = vs_ud[vs->info.instance_offset_sgpr];
        }

        // ---- encode
        std::vector<uint32_t>& vs_flat = r.vs_flat;
        std::vector<uint32_t>& ps_flat = r.ps_flat;
        ResolveTextureHazards(vs, vs_flat);
        if (ps) ResolveTextureHazards(ps, ps_flat);
        PrepareDepthCompanions(vs, vs_flat);
        if (ps) PrepareDepthCompanions(ps, ps_flat);
        id<MTLRenderCommandEncoder> enc = BeginPass(key, clr, hold);
        if (!enc) return;
        EncoderState* es = g_rstate.Tracks(enc) ? &g_rstate : nullptr;
        if (!es || !es->Same(es->pso, (__bridge const void*)pso)) [enc setRenderPipelineState:pso];
        const bool has_depth = depth_fmt != 0;
        const bool has_stencil = has_depth && HasStencil((MTLPixelFormat)depth_fmt);
        static const int dbg_nodepth = getenv("PS4_GNM_DBG_NODEPTH") ? atoi(getenv("PS4_GNM_DBG_NODEPTH")) : 0;
        id<MTLDepthStencilState> dss;
        if (dbg_nodepth) {
            DepthStencilState d0 = rs.ds;
            d0.depth_test = false;
            d0.depth_write = false;
            d0.stencil_test = false;
            dss = GetDepthStencil(d0, has_depth, has_stencil);
        } else {
            dss = GetDepthStencil(rs.ds, has_depth, has_stencil);
        }
        if (!es || !es->Same(es->dss, (__bridge const void*)dss)) [enc setDepthStencilState:dss];
        {
            EncoderState::Fixed f;
            memset(&f, 0, sizeof(f)); // padding is compared
            f.vp = vp;
            f.sc = sc;
            f.stencil_ref[0] = rs.ds.front.reference;
            f.stencil_ref[1] = rs.ds.back.reference;
            f.cull = dbg_nodepth >= 2 ? (uint32_t)MTLCullModeNone : (uint32_t)rs.raster.cull_mode;
            f.winding = (uint32_t)rs.raster.winding;
            f.fill = (uint32_t)rs.raster.fill_mode;
            f.clip = rs.raster.depth_clip ? (uint32_t)MTLDepthClipModeClip : (uint32_t)MTLDepthClipModeClamp;
            if (rs.raster.depth_bias) {
                f.bias[0] = rs.raster.bias_constant;
                f.bias[1] = rs.raster.bias_slope;
                f.bias[2] = rs.raster.bias_clamp;
            }
            for (int i = 0; i < 4; ++i) f.blend[i] = rs.blend_constants[i];
            const bool known = es && es->fixed_gen == es->gen;
            const EncoderState::Fixed* o = known ? &es->fixed : nullptr;
            if (has_stencil && (!o || !es->fixed_stencil || memcmp(o->stencil_ref, f.stencil_ref, sizeof(f.stencil_ref))))
                [enc setStencilFrontReferenceValue:f.stencil_ref[0] backReferenceValue:f.stencil_ref[1]];
            if (!o || memcmp(&o->vp, &f.vp, sizeof(f.vp))) [enc setViewport:f.vp];
            if (!o || memcmp(&o->sc, &f.sc, sizeof(f.sc))) [enc setScissorRect:f.sc];
            if (!o || o->cull != f.cull) [enc setCullMode:(MTLCullMode)f.cull];
            if (!o || o->winding != f.winding) [enc setFrontFacingWinding:(MTLWinding)f.winding];
            if (!o || o->fill != f.fill) [enc setTriangleFillMode:(MTLTriangleFillMode)f.fill];
            if (!o || o->clip != f.clip) [enc setDepthClipMode:(MTLDepthClipMode)f.clip];
            if (!o || memcmp(o->bias, f.bias, sizeof(f.bias))) [enc setDepthBias:f.bias[0] slopeScale:f.bias[1] clamp:f.bias[2]];
            if (!o || memcmp(o->blend, f.blend, sizeof(f.blend)))
                [enc setBlendColorRed:f.blend[0] green:f.blend[1] blue:f.blend[2] alpha:f.blend[3]];
            if (es) {
                if (!has_stencil && known && es->fixed_stencil) {
                    // keep the reference values last set on the encoder
                    f.stencil_ref[0] = es->fixed.stencil_ref[0];
                    f.stencil_ref[1] = es->fixed.stencil_ref[1];
                }
                es->fixed_stencil = has_stencil || (known && es->fixed_stencil);
                es->fixed = f;
                es->fixed_gen = es->gen;
            }
        }

        const gcn_push_data push = MakePushData(regs);
        BindCtx bc{&regs, 1};
        std::string why;
        Binder vb{Stage::Vertex, enc, nil};
        if (!BindStage(vs, vs_ud, vs_flat, vb, bc, push, &why)) {
            RLog("bind", "%s: VS bind failed: %s", args.name, why.c_str());
            S.n_skipped++;
            return;
        }
        if (ps) {
            Binder fb{Stage::Fragment, enc, nil};
            if (!BindStage(ps, ps_ud, ps_flat, fb, bc, push, &why)) {
                RLog("bind", "%s: PS bind failed: %s", args.name, why.c_str());
                S.n_skipped++;
                return;
            }
        }
        // BindStage may have flushed (texture hazard) and closed the encoder
        if (S.renc != enc) {
            RLog("reencode", "%s: encoder restarted after a hazard flush; skipped this draw", args.name);
            S.n_skipped++;
            return;
        }
        for (size_t i = 0; i < vbufs.size(); ++i) vb.Buffer(vbufs[i].first, vbufs[i].second, vattrs[i].buffer);

        const uint32_t inst = std::max(1u, args.num_instances);
        if (indirect) {
            if (indexed)
                [enc drawIndexedPrimitives:prim indexType:itype indexBuffer:ib indexBufferOffset:ib_off
                            indirectBuffer:arg_buf indirectBufferOffset:arg_off];
            else
                [enc drawPrimitives:prim indirectBuffer:arg_buf indirectBufferOffset:arg_off];
        } else if (indexed) {
            [enc drawIndexedPrimitives:prim indexCount:draw_count indexType:itype indexBuffer:ib
                     indexBufferOffset:ib_off instanceCount:inst baseVertex:(NSInteger)(int32_t)vertex_offset
                          baseInstance:instance_offset];
        } else {
            [enc drawPrimitives:prim vertexStart:vertex_offset vertexCount:draw_count instanceCount:inst
                   baseInstance:instance_offset];
        }
        S.pending = true;
        S.n_draws++;
        {
            WorkRec wr;
            wr.what = args.name;
            wr.a = vs_addr;
            wr.b = ps_addr;
            wr.n = args.count;
            wr.inst = inst;
            LogWork(wr);
        }
        if (trace)
            snprintf(desc, sizeof(desc),
                     "%s VS=0x%llx PS=0x%llx prim=%s n=%u inst=%u rt0=%s 0x%llx %ux%u depth=%s vp=(%.0f,%.0f %.0fx%.0f) sc=(%lu,%lu %lux%lu)%s%s",
                     args.name, (unsigned long long)vs_addr, (unsigned long long)ps_addr, NameOf(rs.raster.prim),
                     args.count, inst, key.color[0] ? "yes" : "no", (unsigned long long)rs.color[0].address,
                     key.color[0] ? (uint32_t)key.color[0].width : 0, key.color[0] ? (uint32_t)key.color[0].height : 0,
                     key.depth ? "yes" : "no", vp.originX, vp.originY, vp.width, vp.height,
                     (unsigned long)sc.x, (unsigned long)sc.y, (unsigned long)sc.width, (unsigned long)sc.height,
                     clr.any() ? " CLEAR" : "", rs.raster.clip_disabled ? " clipdis" : "");
        static const bool dump_draws = getenv("PS4_GNM_DUMP_DRAWS") != nullptr;
        if (dump_draws && key.color[0]) {
            char what[64];
            snprintf(what, sizeof(what), "ps%llx_rt%llx", (unsigned long long)ps_addr, (unsigned long long)rs.color[0].address);
            DumpAfterWork(key.color[0], what);
        }
        if (trace) {
            fprintf(stderr, "[gnm-trace] %s\n", desc);
            for (int i = 0; i < 8; ++i) {
                const ColorTarget& c = rs.color[i];
                if (!c.bound) continue;
                fprintf(stderr, "[gnm-trace]    MRT%d 0x%llx %ux%u s%u fmt %u/%u swap %u mask %x enabled %d ps_exports %d bound_tex %s blend %d\n",
                        i, (unsigned long long)c.address, c.pitch, c.height, c.num_samples, c.raw_format,
                        c.raw_number_type, c.comp_swap, c.target_mask, c.enabled, (mrt_mask >> i) & 1,
                        key.color[i] ? "yes" : "no", rs.blend[i].enable);
            }
        }
    }
    return;
}


// A dispatch prepared by the CP thread for the encoder thread.
struct DispatchRec {
    gcn_runtime_info rt{};
    RegSnap regs;
    uint64_t addr = 0;
    uint32_t ud[16] = {};
    Shader* cs = nullptr;
    uint32_t dim_x = 0, dim_y = 0, dim_z = 0;
    uint64_t indirect_addr = 0;
    const char* queue = "";
    std::vector<uint32_t> flat;
    StageImages img;
    // ready for the next dispatch (Dispatch() sets rt, addr, ud, regs), keeping the vectors
    void Recycle() {
        cs = nullptr;
        dim_x = dim_y = dim_z = 0;
        indirect_addr = 0;
        queue = "";
        flat.clear();
        img.Clear();
    }
};
void DispatchEncode(DispatchRec& r);
RecPool<DispatchRec> g_dispatch_recs;

void Dispatch(GuestContext* ctx, const uint32_t* regs, uint32_t dim_x, uint32_t dim_y, uint32_t dim_z,
              uint64_t indirect_addr, const char* queue) {
    if (!Init(ctx) || S.hung) return;
    @autoreleasepool {
        if (!indirect_addr && (dim_x == 0 || dim_y == 0 || dim_z == 0)) return;
        std::unique_ptr<DispatchRec, RecPool<DispatchRec>::Back> rp(g_dispatch_recs.Get(), {&g_dispatch_recs});
        DispatchRec& r = *rp;
        gcn_runtime_info& rt = r.rt;
        gcn_runtime_info_from_regs(regs, 0x10000, GCN_HW_CS, GCN_SW_COMPUTE, &S.profile, &rt);
        uint64_t& addr = r.addr;
        uint32_t* const ud = r.ud;
        gcn_stage_from_regs(regs, 0x10000, GCN_HW_CS, &addr, ud);
        DrainAsyncCompiles();
        Shader* cs = GetShader(GCN_HW_CS, GCN_SW_COMPUTE, rt, addr, ud);
        if (!cs) {
            S.n_skipped++;
            RLog("skip-cs", "%s dispatch skipped: CS 0x%llx unavailable", queue, (unsigned long long)addr);
            return;
        }
        StageFlat(2, cs, ud);
        r.flat = S.flat_scratch[2];
        DecodeStageImages(cs, r.flat, &r.img);
        r.cs = cs;
        r.dim_x = dim_x;
        r.dim_y = dim_y;
        r.dim_z = dim_z;
        r.indirect_addr = indirect_addr;
        r.queue = queue;
        r.regs.Capture(regs);
        if (cs->kjob && !cs->kjob->Done()) S.kernels_open.push_back(cs->kjob);
        encq::Defer([rec = rp.release()] {
            DispatchEncode(*rec);
            g_dispatch_recs.Put(rec);
        });
    }
}

// End of a command stream run (CP thread): waits for the kernels its dispatches still compile.
// Within the run the CP thread went on while they compiled in parallel; it does not go on into
// the next submission, so it never gets further ahead of the encoder (and of the GPU's writes to
// guest memory, which the CP reads for resource tables) than without background kernels.
// Measured without this: in a TLOU loading burst the CP ran seconds ahead and met twice the
// shader permutations.
void WaitKernelCompiles() {
    if (S.kernels_open.empty()) return;
    double total = 0;
    for (auto& j : S.kernels_open) {
        double w = 0;
        j->Wait(&w);
        total += w;
    }
    S.kernels_open.clear();
    if (total > 0) {
        g_compile.kernel_cp_wait.Add(total);
        g_hitch.kernel_wait_ms += total;
        g_hitch.kernel_waits++;
    }
}

void DispatchEncode(DispatchRec& r) {
    CommitEachForDebug();
    if (S.hung) return;
    const RegSnap& regs = r.regs;
    const gcn_runtime_info& rt = r.rt;
    const uint64_t addr = r.addr;
    const uint32_t* const ud = r.ud;
    Shader* const cs = r.cs;
    const uint32_t dim_x = r.dim_x, dim_y = r.dim_y, dim_z = r.dim_z;
    const uint64_t indirect_addr = r.indirect_addr;
    const char* const queue = r.queue;
    StageImagesScope images(nullptr, nullptr, &r.img);
    {
        id<MTLComputePipelineState> pso = nil;
        auto it = S.cs_pipes.find(cs->uid);
        if (it != S.cs_pipes.end()) {
            pso = it->second;
        } else {
            NSError* e = nil;
            // Ask the Metal compiler to fit the full GCN workgroup (up to 1024 threads); without
            // the hint register-heavy kernels get a lower limit and the dispatch had to be skipped.
            const uint64_t wg = (uint64_t)std::max(1u, rt.cs.workgroup_size[0]) * std::max(1u, rt.cs.workgroup_size[1]) *
                                std::max(1u, rt.cs.workgroup_size[2]);
            if (cs->kjob) {
                // first dispatch of a kernel compiled in the background: wait for it here, in
                // stream order (the dispatch's results are read by the work after it)
                double waited = 0;
                id<MTLFunction> kfn = cs->kjob->Wait(&waited);
                if (waited > 0) {
                    g_compile.kernel_wait.Add(waited);
                    g_hitch.kernel_enc_wait_ms += waited;
                } else {
                    g_compile.kernel_ready++;
                }
                if (!kfn) {
                    RLog("msl-fail", "Metal rejected MSL of shader 0x%llx (hw %u): %s", (unsigned long long)addr,
                         cs->hw, cs->kjob->Error().c_str());
                    S.cs_pipes[cs->uid] = nil;
                    S.n_skipped++;
                    return;
                }
            }
            MTLComputePipelineDescriptor* cpd = [MTLComputePipelineDescriptor new];
            cpd.computeFunction = PipelineFn(cs);
            if (wg > 0 && wg <= 1024) cpd.maxTotalThreadsPerThreadgroup = (NSUInteger)wg;
            const uint64_t ck[2] = {cs->msl_hash, wg};
            const uint64_t cstable = Fnv(ck, sizeof(ck), 0x5ca1ab1e5ca1ab1eull);
            ps4gnm_pso_archive::Attach(cpd);
            const double cpso_t0 = CFAbsoluteTimeGetCurrent();
            pso = [S.dev newComputePipelineStateWithDescriptor:cpd options:MTLPipelineOptionNone reflection:nil error:&e];
            if (!pso && ReplaceStoredFns(cs, nullptr)) {
                // built with a stored function: retry once with the function compiled from MSL
                cpd.computeFunction = PipelineFn(cs);
                e = nil;
                pso = [S.dev newComputePipelineStateWithDescriptor:cpd options:MTLPipelineOptionNone reflection:nil error:&e];
            }
            if (pso && !ps4gnm_pso_archive::Contains(cstable)) ps4gnm_pso_archive::Add(cstable, cpd);
            if (pso && cs->lib_stage == ps4gnm_lib_store::kKernel && !ps4gnm_lib_store::Has(cs->lib_key))
                ps4gnm_lib_store::StoreCompute(cs->lib_key, cpd);
            if (!pso) pso = [S.dev newComputePipelineStateWithFunction:PipelineFn(cs) error:&e];
            g_hitch.pso_ms += (CFAbsoluteTimeGetCurrent() - cpso_t0) * 1000.0;
            g_hitch.psos++;
            g_compile.cpso_sync.Add((CFAbsoluteTimeGetCurrent() - cpso_t0) * 1000.0);
            if (!pso)
                RLog("cpso-fail", "compute pipeline 0x%llx failed: %s", (unsigned long long)addr,
                     e.localizedDescription.UTF8String);
            S.cs_pipes[cs->uid] = pso;
        }
        if (!pso) {
            S.n_skipped++;
            return;
        }
        const uint32_t wx = std::max(1u, rt.cs.workgroup_size[0]), wy = std::max(1u, rt.cs.workgroup_size[1]),
                       wz = std::max(1u, rt.cs.workgroup_size[2]);
        static std::unordered_map<void*, NSUInteger> max_threads; // per pipeline (an Objective-C call)
        auto mt = max_threads.find((__bridge void*)pso);
        if (mt == max_threads.end()) mt = max_threads.emplace((__bridge void*)pso, pso.maxTotalThreadsPerThreadgroup).first;
        if ((uint64_t)wx * wy * wz > mt->second) {
            RLog("cs-wg", "%s CS 0x%llx workgroup %ux%ux%u exceeds Metal limit %lu (NUM_THREAD regs %08x %08x %08x, dims %u %u %u)",
                 queue, (unsigned long long)addr, wx, wy, wz, (unsigned long)pso.maxTotalThreadsPerThreadgroup,
                 regs[0x2E07], regs[0x2E08], regs[0x2E09], dim_x, dim_y, dim_z);
            S.n_skipped++;
            return;
        }

        // Metadata clears (CMASK/HTILE written by a compute shader): track instead of running
        // (shadPS4 Rasterizer::IsComputeMetaClear)
        std::vector<uint32_t>& flat = r.flat;
        {
            bool reads_meta = false;
            uint64_t meta_written = 0;
            for (uint32_t i = 0; i < cs->bufs.size(); ++i) {
                if (cs->bufs[i].type != GCN_BUFFER_GUEST) continue;
                uint32_t v[4];
                gcn_buffer_desc bd{};
                if (!gcn_shader_fetch_buffer_sharp(cs->sh, i, flat.data(), cs->code_addr, v)) continue;
                gcn_decode_buffer(v, &bd);
                if (!S.meta.count(bd.base_address)) continue;
                if (cs->bufs[i].is_written) meta_written = bd.base_address;
                else reads_meta = true;
            }
            // Surface copies through buffers (shadPS4 Rasterizer::IsComputeImageCopy): one read and
            // one written buffer of the same size, the source being a GPU-owned surface.
            {
                int n_read = 0, n_written = 0;
                gcn_buffer_desc rd{}, wr{};
                for (uint32_t i = 0; i < cs->bufs.size(); ++i) {
                    if (cs->bufs[i].type != GCN_BUFFER_GUEST) continue;
                    uint32_t v[4];
                    gcn_buffer_desc bd{};
                    if (!gcn_shader_fetch_buffer_sharp(cs->sh, i, flat.data(), cs->code_addr, v)) continue;
                    gcn_decode_buffer(v, &bd);
                    if (cs->bufs[i].is_written) n_written++, wr = bd;
                    else n_read++, rd = bd;
                }
                if (n_read == 1 && n_written == 1 && rd.size_bytes == wr.size_bytes && rd.base_address &&
                    wr.base_address && rd.size_bytes > 4096) {
                    id<MTLTexture> src = nil, dst = nil;
                    int kind = 0;
                    if (S.tex->CloneGpuTexture(rd.base_address, wr.base_address, wr.size_bytes, &src, &dst, &kind)) {
                        EndEncoders();
                        EnsureCmd();
                        id<MTLBlitCommandEncoder> bl = [S.cmd blitCommandEncoder];
                        [bl copyFromTexture:src toTexture:dst];
                        [bl endEncoding];
                        S.pending = true;
                        if (kind == 2) BumpDepthVersion(dst);
                        LogWork("surface copy (compute copy shader)");
                        if (ShouldTrace())
                            fprintf(stderr, "[gnm-trace] %s CS 0x%llx: surface copy 0x%llx -> 0x%llx (%s)\n", queue,
                                    (unsigned long long)addr, (unsigned long long)rd.base_address,
                                    (unsigned long long)wr.base_address, kind == 2 ? "depth" : "color");
                        // remember the stencil plane of the copied depth so its copy is skipped too
                        return;
                    }
                    if (S.stencil_to_z.count(rd.base_address) || S.meta.count(rd.base_address)) {
                        // stencil plane (copied with its depth texture) or HTILE/CMASK metadata
                        if (S.meta.count(rd.base_address)) S.meta.emplace(wr.base_address, MetaState{});
                        if (ShouldTrace())
                            fprintf(stderr, "[gnm-trace] %s CS 0x%llx: stencil/meta copy 0x%llx -> 0x%llx skipped\n",
                                    queue, (unsigned long long)addr, (unsigned long long)rd.base_address,
                                    (unsigned long long)wr.base_address);
                        return;
                    }
                }
            }
            if (meta_written && !reads_meta) {
                S.meta[meta_written].cleared = true;
                if (ShouldTrace()) fprintf(stderr, "[gnm-trace] %s CS 0x%llx: meta clear of 0x%llx\n", queue,
                                           (unsigned long long)addr, (unsigned long long)meta_written);
                return;
            }
        }

        ResolveTextureHazards(cs, flat);
        PrepareDepthCompanions(cs, flat);
        static const bool labels = getenv("PS4_GNM_LABELS") != nullptr;
        if (labels && S.cenc) { // profiling aid: one encoder per dispatch, named after the shader
            [S.cenc endEncoding];
            S.cenc = nil;
        }
        id<MTLComputeCommandEncoder> enc = ComputeEncoder();
        if (labels)
            enc.label = [NSString stringWithFormat:@"CS 0x%llx %ux%ux%u x %ux%ux%u%s", (unsigned long long)addr, dim_x,
                                                   dim_y, dim_z, wx, wy, wz, indirect_addr ? " indirect" : ""];
        if (!g_cstate.Tracks(enc) || !g_cstate.Same(g_cstate.pso, (__bridge const void*)pso))
            [enc setComputePipelineState:pso];
        gcn_push_data push = MakePushData(regs);
        BindCtx bc{&regs, indirect_addr ? 1024u : dim_x * dim_y * dim_z};
        Binder b{Stage::Compute, nil, enc};
        std::string why;
        S.storage_bound.clear();
        if (!BindStage(cs, ud, flat, b, bc, push, &why)) {
            RLog("bind", "%s CS 0x%llx bind failed: %s", queue, (unsigned long long)addr, why.c_str());
            S.n_skipped++;
            return;
        }
        if (S.cenc != enc) { // hazard flush inside BindStage
            enc = ComputeEncoder();
            if (!g_cstate.Tracks(enc) || !g_cstate.Same(g_cstate.pso, (__bridge const void*)pso))
                [enc setComputePipelineState:pso];
            Binder b2{Stage::Compute, nil, enc};
            if (!BindStage(cs, ud, flat, b2, bc, push, &why)) return;
        }
        const MTLSize tg = MTLSizeMake(wx, wy, wz);
        if (indirect_addr) {
            id<MTLBuffer> ab;
            uint64_t off;
            if (!GuestBuffer(indirect_addr, 12, GuestAccess::Read, &ab, &off)) return;
            [enc dispatchThreadgroupsWithIndirectBuffer:ab indirectBufferOffset:off threadsPerThreadgroup:tg];
        } else {
            [enc dispatchThreadgroups:MTLSizeMake(dim_x, dim_y, dim_z) threadsPerThreadgroup:tg];
        }
        S.pending = true;
        S.n_dispatches++;
        S.n_cdisp++;
        WorkRec wr;
        wr.what = queue;
        wr.a = addr;
        wr.n = dim_x;
        wr.inst = dim_y;
        wr.extra = dim_z;
        wr.dispatch = true;
        LogWork(wr);
        if (!S.storage_bound.empty()) SyncStorageToDepth();
        if (ShouldTrace())
            fprintf(stderr, "[gnm-trace] %s dispatch CS=0x%llx groups=%ux%ux%u wg=%ux%ux%u%s\n", queue,
                    (unsigned long long)addr, dim_x, dim_y, dim_z, wx, wy, wz, indirect_addr ? " indirect" : "");
    }
}

bool PresentImpl(GuestContext* ctx, uint64_t addr, uint32_t width, uint32_t height, uint32_t pitch,
                 uint32_t tiling_mode, uint32_t pixel_format, std::function<void()> on_done);

// Without a GPU target for the display buffer the caller would show the guest memory itself;
// with the encoder thread that happens there instead (the CP does not wait for the answer):
// the same CPU detile as VideoOut's fallback, then the flip is completed.
extern "C" int ps4_gnm_read_display_cpu(GuestContext* ctx, uint64_t addr, uint32_t width, uint32_t height,
                                        uint32_t pitch, uint32_t tiling_mode, uint32_t pixel_format, uint8_t* out_bgra);

void PresentFromGuestMemory(GuestContext* ctx, uint64_t addr, uint32_t width, uint32_t height, uint32_t pitch,
                            uint32_t tiling_mode, uint32_t pixel_format) {
    thread_local std::vector<uint8_t> buf; // the encoder and the CPU present queue both come here
    buf.resize((size_t)width * height * 4);
    if (ps4_gnm_read_display_cpu(ctx, addr, width, height, pitch, tiling_mode, pixel_format, buf.data()))
        ps4_metal_screen_present_frame(buf.data(), (size_t)width * 4, (int)width, (int)height);
    else
        ps4_metal_screen_present_frame(ctx->mem_base + addr, (size_t)pitch * 4, (int)width, (int)height);
}

// Display buffers that are not GPU targets are read from guest memory once the GPU work written
// so far has finished. By default the encoder thread does that synchronously (Commit + WaitAll,
// then detile and present). PS4_GNM_ASYNC_CPU_PRESENT=1 moves the read, the detile and the present
// to this serial queue instead:
// - the read waits for the frame's fence (AfterGpu), so it runs after every earlier fence action:
//   the previous frames' flips and this frame's EOP / label writes;
// - every flip completes on this queue, in order, while such a frame is pending (GPU-presented
//   frames and the fallback path go through it too), so present_frame runs on one thread only;
// - the encoder stays at most one frame ahead: before queueing the next guest-memory frame it
//   waits for the previous one, so frame N's read is done before frame N+1's present is queued and
//   N+2's work (which reuses buffer N with two buffers) is encoded after the read
//   (sceGnmInsertWaitFlipDone is not a real wait yet); a GPU that does not finish turns into
//   S.hung through WaitAll's watchdog. A GPU-presented frame after a guest-memory one waits for
//   it too, so the images are shown in order. Writes the CP thread executes itself
//   (DMA_DATA / WRITE_DATA) are not ordered against the read: one reason this stays opt-in.
dispatch_queue_t CpuPresentQueue() {
    static dispatch_queue_t q = dispatch_queue_create(
        "gnm.cpu-present", dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL, QOS_CLASS_USER_INTERACTIVE, 0));
    return q;
}
std::mutex g_cpu_present_mu;
std::condition_variable g_cpu_present_cv;
std::atomic<int> g_cpu_present_pending{0}; // queued or running jobs of CpuPresentQueue

bool AsyncCpuPresent() {
    static const bool on = [] {
        const char* v = getenv("PS4_GNM_ASYNC_CPU_PRESENT");
        return v && v[0] == '1';
    }();
    return on;
}

// Encoder thread: waits until no guest-memory present is pending (the one-frame bound).
void WaitCpuPresentIdle() {
    auto idle = [] { return g_cpu_present_pending.load() == 0; };
    const auto limit = std::chrono::milliseconds((int64_t)S.gpu_timeout_ms);
    std::unique_lock<std::mutex> lk(g_cpu_present_mu);
    if (g_cpu_present_cv.wait_for(lk, limit, idle)) return;
    // the previous frame's GPU work has not finished: the watchdog decides (S.hung, fences run)
    lk.unlock();
    WaitAll();
    lk.lock();
    if (!g_cpu_present_cv.wait_for(lk, limit, idle))
        fprintf(stderr, "[gnm-draw] CPU present: the previous frame is still being presented after the GPU watchdog\n");
}

// Encoder thread: queues fn behind everything already on CpuPresentQueue, after the GPU work
// encoded so far (after_gpu) or right away.
void QueueCpuPresentJob(std::function<void()> fn, bool after_gpu) {
    WaitCpuPresentIdle();
    g_cpu_present_pending.fetch_add(1);
    auto job = std::make_shared<std::function<void()>>(std::move(fn));
    auto dispatch = [job] {
        dispatch_async(CpuPresentQueue(), ^{
            (*job)();
            {
                std::lock_guard<std::mutex> lk(g_cpu_present_mu);
                g_cpu_present_pending.fetch_sub(1);
            }
            g_cpu_present_cv.notify_all();
        });
    };
    if (after_gpu) {
        AfterGpu(std::move(dispatch)); // tagged with the open command buffer's sequence number
        Commit();
    } else {
        dispatch();
    }
}

void QueuePresentFromGuestMemory(GuestContext* ctx, uint64_t addr, uint32_t width, uint32_t height, uint32_t pitch,
                                 uint32_t tiling_mode, uint32_t pixel_format, std::function<void()> on_done,
                                 bool after_gpu) {
    QueueCpuPresentJob(
        [=, done = std::move(on_done)] {
            PresentFromGuestMemory(ctx, addr, width, height, pitch, tiling_mode, pixel_format);
            if (done) done();
        },
        after_gpu);
}

bool Present(GuestContext* ctx, uint64_t addr, uint32_t width, uint32_t height, uint32_t pitch,
             uint32_t tiling_mode, uint32_t pixel_format, std::function<void()> on_done) {
    if (encq::Inline()) return PresentImpl(ctx, addr, width, height, pitch, tiling_mode, pixel_format, std::move(on_done));
    std::function<void()> done = on_done; // completes the flip if PresentImpl cannot
    static const bool dbg_cpu_present = getenv("PS4_GNM_DBG_CPU_PRESENT") != nullptr; // tests the fallback
    encq::Defer([=, f = std::move(on_done)]() mutable {
        if (!dbg_cpu_present && PresentImpl(ctx, addr, width, height, pitch, tiling_mode, pixel_format, std::move(f)))
            return;
        if (g_cpu_present_pending.load() > 0) {
            // earlier guest-memory presents are still queued: stay behind them, on their thread
            QueuePresentFromGuestMemory(ctx, addr, width, height, pitch, tiling_mode, pixel_format, done, false);
            return;
        }
        PresentFromGuestMemory(ctx, addr, width, height, pitch, tiling_mode, pixel_format);
        if (done) done();
    });
    return true;
}

bool PresentImpl(GuestContext* ctx, uint64_t addr, uint32_t width, uint32_t height, uint32_t pitch,
                 uint32_t tiling_mode, uint32_t pixel_format, std::function<void()> on_done) {
    g_present_gen++;
    (void)ctx;
    (void)pitch;
    (void)tiling_mode;
    if (!S.enabled || S.hung || !S.present_pso || !width || !height) return false;
    @autoreleasepool {
        id<MTLTexture> src = S.tex->FindColorTarget(addr, width, height);
        if (!src) src = S.tex->FindColorTarget(addr);
        if (src && (src.sampleCount > 1 ||
                    (src.textureType != MTLTextureType2D && src.textureType != MTLTextureType2DArray)))
            src = nil;
        // A render target of another size at the display address is a stale surface that
        // shared the memory earlier (e.g. a 3200x1800 scene target before a 3840x2160 flip
        // buffer that is written by compute shaders): the display buffer itself is not a GPU
        // target then, so take the guest-memory path below.
        if (src && (src.width != width || src.height != height)) {
            RLog("present-size", "GPU target at display buffer 0x%llx is %lux%lu, the display buffer is %ux%u",
                 (unsigned long long)addr, (unsigned long)src.width, (unsigned long)src.height, width, height);
            src = nil;
        }
        if (!src) {
            RLog("present-miss", "display buffer 0x%llx is not a GPU target (draws %llu dispatches %llu skipped %llu)",
                 (unsigned long long)addr, (unsigned long long)S.n_draws, (unsigned long long)S.n_dispatches,
                 (unsigned long long)S.n_skipped);
            // the frame is read from guest memory on the CPU once all GPU work has landed: here
            // (default), or on the CPU present queue with PS4_GNM_ASYNC_CPU_PRESENT=1
            if (encq::t_worker && AsyncCpuPresent()) {
                QueuePresentFromGuestMemory(ctx, addr, width, height, pitch, tiling_mode, pixel_format,
                                            std::move(on_done), true);
                return true;
            }
            Commit();
            WaitAll();
            return false;
        }
        // read the raw (non-sRGB) values: the display buffer holds encoded pixels
        MTLPixelFormat f = src.pixelFormat;
        MTLPixelFormat lin = f == MTLPixelFormatBGRA8Unorm_sRGB ? MTLPixelFormatBGRA8Unorm
                             : f == MTLPixelFormatRGBA8Unorm_sRGB ? MTLPixelFormatRGBA8Unorm
                                                                  : f;
        id<MTLTexture> view = src;
        // VideoOut A2R10G10B10 formats (0x88xxxxxx) keep R in the high bits, i.e. Metal's
        // RGB10A2 blue channel: swap R/B when sampling (8-bit A8R8G8B8 targets are already
        // stored as BGRA8, see GetColorTargetPixelFormat).
        const bool rgb10 = f == MTLPixelFormatRGB10A2Unorm;
        const bool swap_rb = rgb10 && (pixel_format & 0xFF000000u) == 0x88000000u;
        if (swap_rb) {
            const MTLTextureSwizzleChannels sw =
                MTLTextureSwizzleChannelsMake(MTLTextureSwizzleBlue, MTLTextureSwizzleGreen, MTLTextureSwizzleRed,
                                              MTLTextureSwizzleAlpha);
            view = [src newTextureViewWithPixelFormat:lin textureType:MTLTextureType2D
                                               levels:NSMakeRange(0, 1) slices:NSMakeRange(0, 1) swizzle:sw];
        } else if (lin != f || src.textureType != MTLTextureType2D)
            view = [src newTextureViewWithPixelFormat:lin textureType:MTLTextureType2D
                                               levels:NSMakeRange(0, 1) slices:NSMakeRange(0, 1)];
        // Convert into a present slot of the window's presenter (it waits here while every slot
        // is queued or on screen: back-pressure from the display) and queue it behind the frame's
        // work: the CPU does not wait for the GPU, so the next frame's command processing
        // overlaps this frame's GPU execution and the presenter's wait for a drawable.
        const double tp0 = CFAbsoluteTimeGetCurrent();
        // PS4_GNM_ASYNC_CPU_PRESENT only: a guest-memory frame before this one is shown first
        if (g_cpu_present_pending.load() > 0) WaitCpuPresentIdle();
        id<MTLTexture> dst = (__bridge id<MTLTexture>)ps4_metal_screen_acquire_frame((int)width, (int)height);
        if (!dst) { // no slot: the presenter copies this texture if it can, or drops the frame
            if (!S.present_tex || S.present_tex.width != width || S.present_tex.height != height) {
                MTLTextureDescriptor* td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                                                                                              width:width
                                                                                             height:height
                                                                                          mipmapped:NO];
                td.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
                td.storageMode = MTLStorageModePrivate;
                S.present_tex = [S.dev newTextureWithDescriptor:td];
            }
            dst = S.present_tex;
        }
        EndEncoders();
        EnsureCmd();
        MTLRenderPassDescriptor* rp = [MTLRenderPassDescriptor renderPassDescriptor];
        rp.colorAttachments[0].texture = dst;
        rp.colorAttachments[0].loadAction = MTLLoadActionDontCare;
        rp.colorAttachments[0].storeAction = MTLStoreActionStore;
        id<MTLRenderCommandEncoder> e = [S.cmd renderCommandEncoderWithDescriptor:rp];
        [e setRenderPipelineState:S.present_pso];
        [e setFragmentTexture:view atIndex:0];
        [e drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
        [e endEncoding];
        LogWork("present");
        if (ps4_metal_screen_encode_present((__bridge void*)S.cmd, (__bridge void*)dst) != 0)
            RLog("present-screen", "the Metal screen could not take the frame");
        S.screen_ms += (CFAbsoluteTimeGetCurrent() - tp0) * 1000.0; // includes waiting for a present slot
        if (on_done) {
            if (g_cpu_present_pending.load() > 0) {
                // keep flips in order behind the guest-memory presents still queued
                auto f = std::make_shared<std::function<void()>>(std::move(on_done));
                AfterGpu([f] { dispatch_async(CpuPresentQueue(), ^{ (*f)(); }); });
            } else {
                AfterGpu(std::move(on_done));
            }
        }
        Commit();
        static const bool writeback_all = getenv("PS4_GNM_WRITEBACK_ALL") != nullptr;
        if (writeback_all) { // experiment: make every GPU surface CPU-visible
            WaitAll();
            TextureCache* tc = S.tex;
            tc->ForEachGpuTexture(^(uint64_t a, int kind, id<MTLTexture> t) {
                if (kind == 1 && t.sampleCount == 1) tc->WriteBackColorTarget(a);
            });
        }
        {
            // Frame-time distribution (present-to-present on the submitting thread) and a
            // breakdown of every hitch (> 50 ms) so stutter causes are visible in the log.
            static double last_present = 0;
            static std::vector<float> intervals;
            const double now_t = CFAbsoluteTimeGetCurrent();
            if (last_present > 0) {
                const double dt = (now_t - last_present) * 1000.0;
                intervals.push_back((float)dt);
                // PS4_GNM_LOG_LONG_FRAMES=<ms>: one line per frame longer than <ms> (walking
                // benchmark: counts long frames inside its own time window)
                static const double long_ms = [] {
                    const char* v = getenv("PS4_GNM_LOG_LONG_FRAMES");
                    return v ? atof(v) : 0.0;
                }();
                if (long_ms > 0 && dt > long_ms)
                    fprintf(stderr, "[gnm-draw] long frame %.1f ms (present %llu)\n", dt,
                            (unsigned long long)S.present_idx + 1);
                double host_ms[PS4_HITCH_KINDS];
                for (int k = 0; k < PS4_HITCH_KINDS; ++k) host_ms[k] = ps4_hitch_take_ns(k) / 1e6;
                if (dt > (long_ms > 0 && long_ms < 50.0 ? long_ms : 50.0))
                    fprintf(stderr, "[gnm-draw] hitch: frame %.1f ms; shaders %u (%.1f ms: gcn %.1f, metal %.1f, lookup %.1f, fn %.1f), pipelines %u (%.1f ms), "
                                    "texture uploads %u (%.1f ms), gpu uploads %u, gpu waits %.1f ms, draws waiting for shaders %u, "
                                    "kernel waits %u (%.1f ms CP, %.1f ms encoder); io %.1f, vm %.1f, mtlbuf %.1f, texlock %.1f, shader_fs %.1f ms\n",
                            dt, g_hitch.shaders, g_hitch.shader_ms, g_hitch.gcn_ms, g_hitch.mtl_ms, g_hitch.lookup_ms, g_hitch.fn_ms, g_hitch.psos, g_hitch.pso_ms, g_hitch.uploads,
                            g_hitch.upload_ms, g_hitch.gpu_uploads, g_hitch.wait_ms, g_hitch.pending_draws, g_hitch.kernel_waits,
                            g_hitch.kernel_wait_ms, g_hitch.kernel_enc_wait_ms, host_ms[PS4_HITCH_IO], host_ms[PS4_HITCH_VM],
                            host_ms[PS4_HITCH_MTLBUF], host_ms[PS4_HITCH_TEXLOCK], host_ms[PS4_HITCH_SHADER_FS]);
            } else {
                for (int k = 0; k < PS4_HITCH_KINDS; ++k) ps4_hitch_take_ns(k);
            }
            last_present = now_t;
            g_hitch = HitchStats{};
            if (intervals.size() >= 600) {
                std::vector<float> v = intervals;
                std::sort(v.begin(), v.end());
                auto pct = [&](double q) { return v[std::min(v.size() - 1, (size_t)(q * v.size()))]; };
                size_t over33 = 0, over50 = 0, over100 = 0;
                for (float x : v) {
                    over33 += x > 33.4f;
                    over50 += x > 50.0f;
                    over100 += x > 100.0f;
                }
                fprintf(stderr, "[gnm-draw] frame times over %zu frames: p50 %.1f p95 %.1f p99 %.1f max %.1f ms; "
                                ">33ms %zu, >50ms %zu, >100ms %zu\n",
                        v.size(), pct(0.50), pct(0.95), pct(0.99), v.back(), over33, over50, over100);
                ps4gnm_shader_cache::PrintStats();
                PrintCompileStats();
                intervals.clear();
            }
        }
        static uint64_t presents = 0;
        static double last_t = CFAbsoluteTimeGetCurrent();
        S.present_idx = presents + 1;
        if ((presents + 1) % 300 == 0) {
            const double now = CFAbsoluteTimeGetCurrent();
            fprintf(stderr, "[gnm-draw] perf: %.1f fps over last 300 presents; per frame: %.1f commits, %.1f waits, %.1f ms waiting, %.1f ms GPU busy, %.1f ms CP (CPU), %.1f ms encoder, %.1f ms screen\n",
                    300.0 / (now - last_t), S.n_commits / 300.0, S.n_waits / 300.0, S.wait_ms / 300.0,
                    S.gpu_ns.exchange(0) / 1e6 / 300.0, ps4_gnm_take_cp_ns() / 1e6 / 300.0, encq::busy_ns.exchange(0) / 1e6 / 300.0, S.screen_ms / 300.0);
            S.screen_ms = 0;
            fprintf(stderr, "[gnm-draw] per frame: %.1f render passes (%.1f loading depth), %.1f compute encoders, %.1f dispatches, %.1f compute barriers\n",
                    S.n_passes / 300.0, S.n_depth_loads / 300.0, S.n_cencs / 300.0, S.n_cdisp / 300.0, S.n_cbarriers / 300.0);
            S.n_passes = S.n_depth_loads = S.n_cencs = S.n_cbarriers = S.n_cdisp = 0;
            last_t = now;
            S.n_commits = S.n_waits = 0;
            ps4_gnm_print_sync_stats();
            ps4_fiber_print_stats(300);
            ps4_sync_print_stats(300);
            S.wait_ms = 0;
        }
        DumpTargets(presents + 1);
        if (++presents % 300 == 1)
            fprintf(stderr, "[gnm-draw] present #%llu from GPU target 0x%llx (%lux%lu fmt %lu); totals: draws %llu "
                            "dispatches %llu skipped %llu shaders %zu pipelines %zu submit %llu\n",
                    (unsigned long long)presents, (unsigned long long)addr, (unsigned long)src.width,
                    (unsigned long)src.height, (unsigned long)src.pixelFormat, (unsigned long long)S.n_draws,
                    (unsigned long long)S.n_dispatches, (unsigned long long)S.n_skipped, S.shaders.size(),
                    S.gfx_pipes.size(), (unsigned long long)S.submit_idx);
        return true;
    }
}

void Shutdown() {
    if (!S.enabled) return;
    Flush(true);
}

} // namespace ps4draw

extern "C" void ps4_gnm_guest_remapped(uint64_t addr, uint64_t size) {
    std::lock_guard<std::mutex> lk(ps4draw::g_remap_mutex);
    ps4draw::g_remapped.push_back({addr, size});
    ps4draw::g_remap_pending.store(true, std::memory_order_release);
}

// CPU-side producers (e.g. the video decoder) report guest memory they rewrote so sampled
// textures created from it are re-uploaded. Thread-safe (TextureCache has its own lock).
extern "C" void ps4_gnm_notify_cpu_write(uint64_t addr, uint64_t size) {
    if (ps4draw::S.enabled && ps4draw::S.tex) ps4draw::S.tex->InvalidateRange(addr, size, false);
}

// Called by the texture cache (ps4_gnm_resources.mm) for every CPU texture upload.
extern "C" void ps4_gnm_hitch_note_upload(double ms) {
    ps4draw::g_hitch.upload_ms += ms;
    ps4draw::g_hitch.uploads++;
}
