// sceGnmSubmitAndFlipCommandBuffers must not wait for the display (u4_research/crash_0x1ceb9d0.md).
//
// On the PS4 the call only enqueues the command buffer and the flip; the flip completes when the
// display takes the buffer, and the game paces itself on flip events. The runtime used to wait
// inside the call for a present slot of the Metal screen. With PS4_GNM_SYNC_ENCODE that wait
// ran on the guest's submitting thread after the frame was on the GPU, so the frame's EOP label
// was written while the guest was still in the call. Uncharted 4 then recycled memory that its
// submit thread reads right after the call returns.
//
// Through the real runtime (command processor, renderer, VideoOut, presenter); argv[1] "sync"
// (PS4_GNM_SYNC_ENCODE=1) or "async" (encoder thread). The test holds the present slot the
// presenter grants, which puts the display "behind":
//   1. a frame (a draw into display buffer 0, then EVENT_WRITE_EOP to a label) flips normally;
//   2. with the display behind, SubmitAndFlip returns at once (a warm-up round within 250 ms,
//      then within 5 ms), the EOP label is written, the flip stays pending; with the encoder
//      thread, draining it (ps4_gnm_metal_wait_gpu_idle) does not wait for the display either;
//      once the slot is given back, the held frame reaches the presenter and its flip completes;
//   3. a held frame the display never takes is dropped after 1 s (the held-frame timer) and its
//      flip completes, without reaching the presenter;
//   4. the hold depth follows the guest's display buffers (min(3, buffers - 1)): with 2 buffers,
//      a second frame while the display is behind drops the first; with 4 buffers, 4 frames drop
//      the oldest at once (3 are held), the other 3 are shown after the slot is given back, and
//      the flips complete in order;
//   5. display buffer 1 is never a GPU target (written by the CPU): it is copied on the GPU
//      and presented without a wait, and the saved screenshot has the CPU's pixels;
//   6. frames whose conversion hangs on the GPU: a held frame the display never takes is dropped
//      and flipped by the 1 s timeout; once the watchdog gives the renderer up, a held frame the
//      presenter took flips, with the flips after it, and the drawables the presenter kept for a
//      hung slot frame come back, so later frames are still presented. The frames after the held
//      one are flipped only while the presenter has a drawable for them: the number of drawables
//      the system keeps for the display depends on the window's visibility, not on the runtime.
// With "nohooks" (PS4_TEST_HOOKS unset) it checks that the GPU stall hook refuses and that frames
// still flip.
// On 199a6e9 the held SubmitAndFlip takes about 1 s (the slot acquire timeout): the test fails.
#import <Cocoa/Cocoa.h>
#import <Metal/Metal.h>

#include <dlfcn.h>
#include <pthread.h>
#include <stdlib.h>
#include <sys/stat.h>
#include <unistd.h>

#include <cstdio>
#include <cstring>
#include <filesystem>
#include <string>
#include <vector>

#include "recomp_runtime.h"
#include "ps4_gnmdriver.h"
#include "ps4_gnm_metal.h"
#include "ps4_metal_screen.h"
#include "ps4_videoout.h"
#include <ImageIO/ImageIO.h>

// The generated game code is not linked; nothing in this test enters guest code.
extern "C" void recomp_enter_guest(void) {
    fprintf(stderr, "gnm_submit_flip_nonblocking_test: recomp_enter_guest called\n");
    abort();
}

namespace {

int g_fail = 0;
#define CHECK(c, ...)                                                        \
    do {                                                                     \
        if (!(c)) {                                                          \
            fprintf(stderr, "gnm_submit_flip_nonblocking_test: FAIL: ");    \
            fprintf(stderr, __VA_ARGS__);                                    \
            fprintf(stderr, "\n");                                           \
            g_fail++;                                                        \
        }                                                                    \
    } while (0)

double NowMs() {
    return clock_gettime_nsec_np(CLOCK_UPTIME_RAW) / 1e6;
}

constexpr uint32_t kW = 256, kH = 256;

uint32_t Type3(uint32_t op, uint32_t payload_dw) {
    return (3u << 30) | ((payload_dw - 1) << 16) | (op << 8);
}

struct Dcb {
    std::vector<uint32_t> w;
    void Reg(uint32_t op, uint32_t base, uint32_t reg, uint32_t value) {
        w.push_back(Type3(op, 2));
        w.push_back(reg - base);
        w.push_back(value);
    }
    void Ctx(uint32_t reg, uint32_t v) { Reg(0x69, 0xA000, reg, v); }  // SET_CONTEXT_REG
    void Sh(uint32_t reg, uint32_t v) { Reg(0x76, 0x2C00, reg, v); }   // SET_SH_REG
    void Ucfg(uint32_t reg, uint32_t v) { Reg(0x79, 0xC000, reg, v); } // SET_UCONFIG_REG
};

uint32_t F(float f) {
    uint32_t u;
    memcpy(&u, &f, 4);
    return u;
}

// GCN program + OrbShdr binary info (the renderer finds the program's length there).
void WriteProgram(uint8_t* dst, const std::vector<uint32_t>& code, uint64_t hash) {
    memcpy(dst, code.data(), code.size() * 4);
    uint8_t* bi = dst + code.size() * 4;
    memcpy(bi, "OrbShdr", 7);
    bi[7] = 0;                                         // version
    const uint32_t bits = (uint32_t)(code.size() * 4) << 8; // length[31:8]
    memcpy(bi + 8, &bits, 4);
    memset(bi + 12, 0, 4);
    memcpy(bi + 16, &hash, 8);
    memset(bi + 24, 0, 8);
}

struct Guest {
    GuestContext* ctx = nullptr;
    uint64_t vs = 0, ps = 0, display = 0, display_cpu = 0, label = 0, dcb = 0;
    uint32_t dcb_bytes = 0;
    int32_t vo = -1;
    uint32_t base = 0; // VideoOut index of the display buffer (the set the test flips)
};

// One frame: default state, then (draw) a triangle into display buffer 0 (a draw with CB0 =
// the display buffer makes it a GPU render target, which the GPU present path presents), then
// EVENT_WRITE_EOP writing `value` to the label.
void BuildFrame(Guest& g, uint32_t value, bool draw = true) {
    uint32_t* mem = (uint32_t*)(g.ctx->mem_base + g.dcb);
    const uint32_t init = sceGnmDrawInitDefaultHardwareState350(mem, 0x1000);
    Dcb d;
    d.w.assign(mem, mem + init);
    if (draw) {
        // shaders
        d.Sh(0x2C48, (uint32_t)(g.vs >> 8));  // SPI_SHADER_PGM_LO_VS
        d.Sh(0x2C49, (uint32_t)(g.vs >> 40)); // SPI_SHADER_PGM_HI_VS
        d.Sh(0x2C4A, 0);                      // SPI_SHADER_PGM_RSRC1_VS: 4 VGPRs, 8 SGPRs
        d.Sh(0x2C4B, 0);                      // SPI_SHADER_PGM_RSRC2_VS: no user data
        d.Sh(0x2C08, (uint32_t)(g.ps >> 8));  // SPI_SHADER_PGM_LO_PS
        d.Sh(0x2C09, (uint32_t)(g.ps >> 40));
        d.Sh(0x2C0A, 0);
        d.Sh(0x2C0B, 0);
        d.Ctx(0xA1B1, 0);          // SPI_VS_OUT_CONFIG
        d.Ctx(0xA1B3, 2);          // SPI_PS_INPUT_ENA: PERSP_CENTER
        d.Ctx(0xA1B4, 2);          // SPI_PS_INPUT_ADDR
        d.Ctx(0xA1B6, 0);          // SPI_PS_IN_CONTROL: no interpolants
        d.Ctx(0xA1C3, 4);          // SPI_SHADER_POS_FORMAT: 4 components
        d.Ctx(0xA1C4, 0);          // SPI_SHADER_Z_FORMAT
        d.Ctx(0xA1C5, 9);          // SPI_SHADER_COL_FORMAT: MRT0 32_ABGR
        d.Ctx(0xA2D5, 0);          // VGT_SHADER_STAGES_EN: VS + PS only
        // colour target 0 = display buffer 0, linear, 8_8_8_8 unorm
        d.Ctx(0xA318, (uint32_t)(g.display >> 8)); // CB_COLOR0_BASE
        d.Ctx(0xA319, kW / 8 - 1);                 // CB_COLOR0_PITCH
        d.Ctx(0xA31A, kW * kH / 64 - 1);           // CB_COLOR0_SLICE
        d.Ctx(0xA31B, 0);                          // CB_COLOR0_VIEW
        d.Ctx(0xA31C, 0xA << 2);                   // CB_COLOR0_INFO: COLOR_8_8_8_8, UNORM
        d.Ctx(0xA31D, 8);                          // CB_COLOR0_ATTRIB: DisplayLinearAligned
        d.Ctx(0xA08E, 0xF);                        // CB_TARGET_MASK
        d.Ctx(0xA08F, 0xF);                        // CB_SHADER_MASK
        d.Ctx(0xA202, 0x00CC0010);                 // CB_COLOR_CONTROL: normal, ROP3 copy
        // raster state
        d.Ctx(0xA00C, 0);                          // PA_SC_SCREEN_SCISSOR_TL
        d.Ctx(0xA00D, kW | (kH << 16));            // PA_SC_SCREEN_SCISSOR_BR
        d.Ctx(0xA081, 0x80000000);                 // PA_SC_WINDOW_SCISSOR_TL (no window offset)
        d.Ctx(0xA082, kW | (kH << 16));            // PA_SC_WINDOW_SCISSOR_BR
        d.Ctx(0xA090, 0x80000000);                 // PA_SC_GENERIC_SCISSOR_TL
        d.Ctx(0xA091, kW | (kH << 16));            // PA_SC_GENERIC_SCISSOR_BR
        d.Ctx(0xA10F, F(kW / 2.f));                // PA_CL_VPORT_XSCALE
        d.Ctx(0xA110, F(kW / 2.f));                // PA_CL_VPORT_XOFFSET
        d.Ctx(0xA111, F(kH / 2.f));                // PA_CL_VPORT_YSCALE
        d.Ctx(0xA112, F(kH / 2.f));                // PA_CL_VPORT_YOFFSET
        d.Ctx(0xA113, F(0.5f));                    // PA_CL_VPORT_ZSCALE
        d.Ctx(0xA114, F(0.5f));                    // PA_CL_VPORT_ZOFFSET
        d.Ctx(0xA206, 0x43F);                      // PA_CL_VTE_CNTL: scale/offset on, W0 format
        d.Ctx(0xA204, 0);                          // PA_CL_CLIP_CNTL
        d.Ctx(0xA205, 0);                          // PA_SU_SC_MODE_CNTL: no culling
        d.Ucfg(0xC242, 4);                         // VGT_PRIMITIVE_TYPE: triangle list
        d.w.push_back(Type3(0x2D, 2));             // DRAW_INDEX_AUTO
        d.w.push_back(3);
        d.w.push_back(2);                          // auto-generated indices
    }
    d.w.push_back(Type3(0x47, 5));             // EVENT_WRITE_EOP
    d.w.push_back(0x14 | (5u << 8));           // CACHE_FLUSH_AND_INV_TS_EVENT
    d.w.push_back((uint32_t)g.label);
    d.w.push_back((uint32_t)((g.label >> 32) & 0xFFFF) | (1u << 29)); // data_sel 32-bit, no interrupt
    d.w.push_back(value);
    d.w.push_back(0);
    memcpy(mem, d.w.data(), d.w.size() * 4);
    g.dcb_bytes = (uint32_t)(d.w.size() * 4);
}

// Returns the time the call took, in ms.
double SubmitAndFlip(Guest& g, int64_t flip_arg, int buffer = -1) {
    if (buffer < 0) buffer = (int)g.base;
    const uint64_t addrs[1] = {g.dcb};
    const uint32_t sizes[1] = {g.dcb_bytes};
    const double t0 = NowMs();
    const int32_t r = sceGnmSubmitAndFlipCommandBuffers(g.ctx, 1, addrs, sizes, nullptr, nullptr, (uint32_t)g.vo,
                                                        (uint32_t)buffer, 1 /* vsync */, flip_arg);
    const double ms = NowMs() - t0;
    CHECK(r == 0, "sceGnmSubmitAndFlipCommandBuffers returned 0x%x", (unsigned)r);
    return ms;
}

uint32_t Label(const Guest& g) {
    return __atomic_load_n((const uint32_t*)(g.ctx->mem_base + g.label), __ATOMIC_ACQUIRE);
}

OrbisVideoOutFlipStatus Flips(const Guest& g) {
    OrbisVideoOutFlipStatus st{};
    sceVideoOutGetFlipStatus(g.vo, &st);
    return st;
}

template <class F>
bool WaitFor(double ms, F&& done) {
    const double end = NowMs() + ms;
    while (NowMs() < end) {
        if (done()) return true;
        usleep(1000);
    }
    return done();
}

// Takes a present slot the way the renderer does. The runtime before the fix only has the
// blocking acquire (it waits up to 1 s for a slot); with the fix, the non-blocking one. Both are
// looked up at run time so the same test runs against either.
void* TakeSlot() {
    using Try = void* (*)(int, int);
    if (auto t = (Try)dlsym(RTLD_DEFAULT, "ps4_metal_screen_try_acquire_frame")) {
        void* s = nullptr;
        WaitFor(2000, [&] { return (s = t(kW, kH)) != nullptr; }); // the presenter grants a slot once it has a drawable
        return s;
    }
    if (auto a = (Try)dlsym(RTLD_DEFAULT, "ps4_metal_screen_acquire_frame")) return a(kW, kH);
    return nullptr;
}

// Gives the test's slot to the presenter (the display catches up).
void GiveBack(void* held) {
    if (!held) return;
    id<MTLCommandQueue> q = (__bridge id<MTLCommandQueue>)ps4_metal_screen_get_command_queue();
    id<MTLCommandBuffer> cb = [q commandBuffer];
    ps4_metal_screen_encode_present((__bridge void*)cb, held);
    [cb commit];
}

// Counters of the fixed runtime (looked up at run time like TakeSlot): frames the presenter put
// on a drawable, held frames dropped. 0 on the old runtime.
uint64_t Counter(const char* name) {
    using Get = uint64_t (*)(void);
    auto f = (Get)dlsym(RTLD_DEFAULT, name);
    return f ? f() : 0;
}
uint64_t Presented() {
    return Counter("ps4_metal_screen_presented_count");
}
uint64_t HeldDrops() {
    return Counter("ps4_metal_screen_held_drop_count");
}
uint64_t HeldCount() {
    return Counter("ps4_metal_screen_held_count");
}

// Pixel (x, y) of a saved screenshot as BGRA bytes; false if it cannot be read.
bool ShotPixel(const std::string& path, uint32_t x, uint32_t y, uint8_t bgra[4]) {
    CGImageSourceRef src = CGImageSourceCreateWithURL((__bridge CFURLRef)[NSURL fileURLWithPath:@(path.c_str())], nullptr);
    if (!src) return false;
    CGImageRef img = CGImageSourceCreateImageAtIndex(src, 0, nullptr);
    CFRelease(src);
    if (!img) return false;
    const size_t w = CGImageGetWidth(img), h = CGImageGetHeight(img);
    std::vector<uint8_t> px(w * h * 4);
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGContextRef bc = CGBitmapContextCreate(px.data(), w, h, 8, w * 4, cs,
                                            kCGImageAlphaNoneSkipFirst | kCGBitmapByteOrder32Little);
    CGColorSpaceRelease(cs);
    if (bc) CGContextDrawImage(bc, CGRectMake(0, 0, w, h), img);
    CGImageRelease(img);
    if (!bc || x >= w || y >= h) {
        if (bc) CGContextRelease(bc);
        return false;
    }
    CGContextRelease(bc);
    memcpy(bgra, &px[(y * w + x) * 4], 4);
    return true;
}

void* const* set_pair(const Guest& g) {
    static void* pair[2];
    pair[0] = pair[1] = (void*)(uintptr_t)g.display;
    return pair;
}

// sceVideoOutRegisterBuffers / UnregisterBuffers / SubmitFlip error codes (the system library's
// SCE_VIDEO_OUT_ERROR_* values). Sets 0 (indices 0..1) and 1 (2..5) are registered; the sets this
// adds are unregistered again.
void CheckBufferSetErrors(Guest& g, const OrbisVideoOutBufferAttribute& attr) {
    auto rc = [](int32_t r) { return (uint32_t)r; };
    void* one[1] = {(void*)(uintptr_t)g.display};
    OrbisVideoOutBufferAttribute a = attr;
    CHECK(rc(sceVideoOutRegisterBuffers(g.vo, 6, nullptr, 1, &attr)) == ORBIS_VIDEO_OUT_ERROR_INVALID_ADDRESS,
          "register: no buffer array");
    CHECK(rc(sceVideoOutRegisterBuffers(g.vo, 6, one, 1, nullptr)) == ORBIS_VIDEO_OUT_ERROR_INVALID_ADDRESS,
          "register: no attribute");
    CHECK(rc(sceVideoOutRegisterBuffers(g.vo + 100, 6, one, 1, &attr)) == ORBIS_VIDEO_OUT_ERROR_INVALID_HANDLE,
          "register: bad handle");
    CHECK(rc(sceVideoOutRegisterBuffers(g.vo, 1, one, 1, &attr)) == ORBIS_VIDEO_OUT_ERROR_SLOT_OCCUPIED,
          "register: index 1 is in set 0");
    CHECK(rc(sceVideoOutRegisterBuffers(g.vo, 15, set_pair(g), 2, &attr)) == ORBIS_VIDEO_OUT_ERROR_INVALID_VALUE,
          "register: indices past 15");
    CHECK(rc(sceVideoOutRegisterBuffers(g.vo, -1, one, 1, &attr)) == ORBIS_VIDEO_OUT_ERROR_INVALID_VALUE,
          "register: negative index");
    a = attr;
    a.aspect = 1;
    CHECK(rc(sceVideoOutRegisterBuffers(g.vo, 6, one, 1, &a)) == ORBIS_VIDEO_OUT_ERROR_INVALID_ASPECT_RATIO,
          "register: aspect ratio");
    a = attr;
    a.pixelPitch = a.width - 1;
    CHECK(rc(sceVideoOutRegisterBuffers(g.vo, 6, one, 1, &a)) == ORBIS_VIDEO_OUT_ERROR_INVALID_PITCH,
          "register: width above the pitch");
    a = attr;
    a.tmode = 2;
    CHECK(rc(sceVideoOutRegisterBuffers(g.vo, 6, one, 1, &a)) == ORBIS_VIDEO_OUT_ERROR_INVALID_TILING_MODE,
          "register: tiling mode");
    a = attr;
    a.reserved[0] = 1;
    CHECK(rc(sceVideoOutRegisterBuffers(g.vo, 6, one, 1, &a)) == ORBIS_VIDEO_OUT_ERROR_INVALID_VALUE,
          "register: reserved field");
    // 4 sets at most
    CHECK(sceVideoOutRegisterBuffers(g.vo, 6, one, 1, &attr) == 2, "register: set 2");
    CHECK(sceVideoOutRegisterBuffers(g.vo, 7, one, 1, &attr) == 3, "register: set 3");
    CHECK(rc(sceVideoOutRegisterBuffers(g.vo, 8, one, 1, &attr)) == ORBIS_VIDEO_OUT_ERROR_NO_EMPTY_SLOT,
          "register: a fifth set");
    // unregistering frees the set and its indices
    CHECK(sceVideoOutUnregisterBuffers(g.vo, 3) == 0, "unregister set 3");
    CHECK(rc(sceVideoOutUnregisterBuffers(g.vo, 3)) == ORBIS_VIDEO_OUT_ERROR_INVALID_VALUE, "unregister set 3 twice");
    CHECK(rc(sceVideoOutUnregisterBuffers(g.vo, 4)) == ORBIS_VIDEO_OUT_ERROR_INVALID_VALUE, "unregister set 4");
    CHECK(rc(sceVideoOutUnregisterBuffers(g.vo + 100, 2)) == ORBIS_VIDEO_OUT_ERROR_INVALID_HANDLE,
          "unregister: bad handle");
    CHECK(rc(sceVideoOutSubmitFlip(g.ctx, g.vo, 7, 1, 0)) == ORBIS_VIDEO_OUT_ERROR_INVALID_INDEX,
          "flip of an unregistered index");
    CHECK(rc(sceVideoOutSubmitFlip(g.ctx, g.vo, 16, 1, 0)) == ORBIS_VIDEO_OUT_ERROR_INVALID_INDEX,
          "flip of index 16");
    CHECK(rc(sceVideoOutSubmitFlip(g.ctx, g.vo + 100, 0, 1, 0)) == ORBIS_VIDEO_OUT_ERROR_INVALID_HANDLE,
          "flip: bad handle");
    CHECK(sceVideoOutRegisterBuffers(g.vo, 7, one, 1, &attr) == 3, "register: set 3 again after unregistering");
    CHECK(sceVideoOutUnregisterBuffers(g.vo, 3) == 0 && sceVideoOutUnregisterBuffers(g.vo, 2) == 0,
          "unregister sets 2 and 3");
}

extern "C" volatile int g_ps4_screenshot_request;
std::string g_shot_dir;
enum class Mode { Sync, Async, NoHooks };
Mode g_mode = Mode::Sync;

void* TestThread(void* argp) {
    const bool async = argp != nullptr;
    @autoreleasepool {
        Guest g;
        g.ctx = recomp_init_runtime(0x40000000, nullptr, 0, "gnm_submit_flip_nonblocking_test");
        CHECK(g.ctx && g.ctx->mem_base, "runtime init");
        if (g_fail) exit(1);
        ps4_gnmdriver_init(g.ctx);
        CHECK(ps4_gnm_metal_init(g.ctx) == 0, "renderer init");
        g.vs = recomp_vm_alloc(g.ctx, 0x1000);
        g.ps = recomp_vm_alloc(g.ctx, 0x1000);
        g.display = recomp_vm_alloc(g.ctx, kW * kH * 4);
        g.display_cpu = recomp_vm_alloc(g.ctx, kW * kH * 4);
        g.label = recomp_vm_alloc(g.ctx, 0x1000);
        g.dcb = recomp_vm_alloc(g.ctx, 0x10000);
        CHECK(g.vs && g.ps && g.display && g.display_cpu && g.label && g.dcb, "guest allocations");
        if (g_fail) exit(1);
        // VS: position (0, 0, 0, 1) for every vertex (the triangle covers no pixel; the draw
        // still binds the display buffer as colour target 0). PS: colour (1, 1, 1, 1).
        WriteProgram(g.ctx->mem_base + g.vs,
                     {0x7E000280u,               // v_mov_b32 v0, 0
                      0x7E0202F2u,               // v_mov_b32 v1, 1.0
                      0xF80008CFu, 0x01000000u,  // exp pos0 v0, v0, v0, v1 done
                      0xBF810000u},              // s_endpgm
                     0x5f1c0de5000001ull);
        WriteProgram(g.ctx->mem_base + g.ps,
                     {0x7E0002F2u,               // v_mov_b32 v0, 1.0
                      0xF800180Fu, 0x00000000u,  // exp mrt0 v0, v0, v0, v0 done vm
                      0xBF810000u},              // s_endpgm
                     0x5f1c0de5000002ull);

        g.vo = sceVideoOutOpen(255, 0, 0, nullptr);
        CHECK(g.vo >= 0, "sceVideoOutOpen");
        OrbisVideoOutBufferAttribute attr{};
        sceVideoOutSetBufferAttribute(&attr, 0x80000000u /* A8R8G8B8 sRGB */, 1 /* linear */, 0, kW, kH, kW);
        void* bufs[2] = {(void*)(uintptr_t)g.display, (void*)(uintptr_t)g.display_cpu};
        CHECK(sceVideoOutRegisterBuffers(g.vo, 0, bufs, 2, &attr) == 0, "sceVideoOutRegisterBuffers");
        if (g_fail) exit(1);
        uint32_t value = 0;
        uint64_t flips = 0;
        int slot_frames = 0; // scenario 6: slot frames flipped after the held one (1 or 2)

        // 1. the display keeps up: the frame and its flip complete
        BuildFrame(g, ++value);
        SubmitAndFlip(g, value);
        ++flips;
        CHECK(WaitFor(5000, [&] { return Label(g) == value && Flips(g).num == flips; }),
              "frame 1: label %u, flips %llu (want 1, 1)", Label(g), (unsigned long long)Flips(g).num);
        CHECK(WaitFor(2000, [&] { return Presented() >= 1; }) || !Counter("ps4_metal_screen_presented_count"),
              "frame 1 never reached the presenter");
        if (g_mode == Mode::NoHooks) {
            CHECK(ps4_gnm_metal_debug_stall_gpu() == -1, "nohooks: the GPU stall hook ran without PS4_TEST_HOOKS=1");
            BuildFrame(g, ++value);
            SubmitAndFlip(g, value);
            ++flips;
            CHECK(WaitFor(3000, [&] { return Label(g) == value && Flips(g).num == flips; }),
                  "nohooks: the frame after the refused stall did not complete");
            if (g_fail) {
                fprintf(stderr, "gnm_submit_flip_nonblocking_test nohooks: %d failure(s)\n", g_fail);
                exit(1);
            }
            printf("gnm_submit_flip_nonblocking_test nohooks: PASS (the GPU stall hook refused)\n");
            fflush(stdout);
            exit(0);
        }

        // 2. the display is behind: the test holds the slot the presenter grants. The first round
        // also creates the held-frame texture (limit 250 ms, far below the old 1 s wait); the
        // second is timed against 5 ms.
        double ms = 0;
        for (int round = 0; round < 2 && !g_fail; ++round) {
            const double limit = round == 0 ? 250.0 : 5.0;
            void* held = TakeSlot();
            CHECK(held != nullptr, "round %d: no present slot to hold", round);
            const uint64_t shown = Presented(), heldn = HeldCount();
            BuildFrame(g, ++value);
            ms = SubmitAndFlip(g, value);
            CHECK(ms < limit, "round %d: SubmitAndFlip took %.1f ms while the display was behind (limit %.0f ms)", round,
                  ms, limit);
            CHECK(WaitFor(2000, [&] { return Label(g) == value; }), "round %d: EOP label %u, want %u", round, Label(g),
                  value);
            if (async) {
                // the encoder thread does not wait for the display either: draining it returns
                const double t0 = NowMs();
                ps4_gnm_metal_wait_gpu_idle();
                const double idle_ms = NowMs() - t0;
                CHECK(idle_ms < 200.0, "round %d: draining the encoder took %.1f ms while the display was behind", round,
                      idle_ms);
            }
            usleep(100 * 1000);
            CHECK(HeldCount() == heldn + 1, "round %d: %llu frames held, want 1", round,
                  (unsigned long long)(HeldCount() - heldn));
            const OrbisVideoOutFlipStatus st = Flips(g);
            CHECK(st.num == flips && st.numFlipPending == 1,
                  "round %d: the frame flipped while no slot was free: flips %llu, pending %d (want %llu, 1)", round,
                  (unsigned long long)st.num, st.numFlipPending, (unsigned long long)flips);
            CHECK(Presented() == shown, "round %d: the presenter showed a frame while its slot was held", round);
            GiveBack(held);
            ++flips;
            // taken by the presenter at its next drawable (not dropped by the 1 s timer)
            CHECK(WaitFor(500, [&] { return Flips(g).num == flips; }),
                  "round %d: the frame did not flip within 500 ms of the slot being given back: flips %llu", round,
                  (unsigned long long)Flips(g).num);
            // the test's slot and the held frame
            CHECK(WaitFor(2000, [&] { return Presented() >= shown + 2; }), "round %d: presenter showed %llu frames, want 2",
                  round, (unsigned long long)(Presented() - shown));
        }

        // 3. the slot never comes back in time: the held frame is dropped after 1 s and flips
        if (!g_fail) {
            void* held = TakeSlot();
            CHECK(held != nullptr, "timeout: no present slot to hold");
            const uint64_t shown = Presented(), drops = HeldDrops();
            BuildFrame(g, ++value);
            const double t0 = NowMs();
            SubmitAndFlip(g, value);
            ++flips;
            const bool flipped = WaitFor(2500, [&] { return Flips(g).num == flips; });
            const double after = NowMs() - t0;
            CHECK(flipped, "timeout: the held frame never flipped (the held-frame timer did not drop it)");
            CHECK(after > 900.0, "timeout: the held frame flipped after %.0f ms, before the 1 s timeout", after);
            CHECK(HeldDrops() == drops + 1, "timeout: %llu held frames dropped, want 1",
                  (unsigned long long)(HeldDrops() - drops));
            CHECK(Presented() == shown, "timeout: the dropped frame was shown");
            GiveBack(held);
            CHECK(WaitFor(2000, [&] { return Presented() >= shown + 1; }), "timeout: the test's slot was not shown");
        }

        // A second buffer set of 4 (indices 2..5: the same 2 buffers and 2 more). The hold depth
        // follows the set of the flipped buffer: set 0 (2 buffers) still allows 1 held frame.
        uint64_t extra[2] = {recomp_vm_alloc(g.ctx, kW * kH * 4), recomp_vm_alloc(g.ctx, kW * kH * 4)};
        void* set1[4] = {(void*)(uintptr_t)g.display, (void*)(uintptr_t)g.display_cpu, (void*)(uintptr_t)extra[0],
                         (void*)(uintptr_t)extra[1]};
        CHECK(sceVideoOutRegisterBuffers(g.vo, 2, set1, 4, &attr) == 1, "sceVideoOutRegisterBuffers (set 1 at 2..5)");
        CheckBufferSetErrors(g, attr);

        // 4a. set 0 (2 display buffers): at most 1 frame held, a second one drops the first
        if (!g_fail) {
            void* held = TakeSlot();
            CHECK(held != nullptr, "depth 1: no present slot to hold");
            const uint64_t shown = Presented(), drops = HeldDrops();
            const uint32_t first = value + 1;
            for (int k = 0; k < 2; ++k) {
                BuildFrame(g, ++value);
                SubmitAndFlip(g, value);
            }
            CHECK(WaitFor(1000, [&] { return Flips(g).num == flips + 1; }) && Flips(g).flipArg == (int64_t)first,
                  "depth 1: the first frame was not dropped: flips %llu (want %llu), last %lld (want %u)",
                  (unsigned long long)Flips(g).num, (unsigned long long)(flips + 1), (long long)Flips(g).flipArg, first);
            CHECK(HeldDrops() == drops + 1, "depth 1: %llu held frames dropped, want 1",
                  (unsigned long long)(HeldDrops() - drops));
            GiveBack(held);
            flips += 2;
            CHECK(WaitFor(2000, [&] { return Flips(g).num == flips; }) && Flips(g).flipArg == (int64_t)value,
                  "depth 1: the held frame never flipped");
            CHECK(WaitFor(2000, [&] { return Presented() >= shown + 2; }), "depth 1: presenter showed %llu frames, want 2",
                  (unsigned long long)(Presented() - shown));
        }
        // set 1 (4 display buffers) from here on: up to 3 held
        g.base = 2;

        // 4b. four frames while the display is behind: the oldest is dropped, 3 are held, then
        // shown, and the flips complete in order
        if (!g_fail) {
            void* held = TakeSlot();
            CHECK(held != nullptr, "overflow: no present slot to hold");
            const uint64_t shown = Presented(), drops = HeldDrops();
            const uint32_t first = value + 1;
            for (int k = 0; k < 4; ++k) {
                BuildFrame(g, ++value);
                const double t = SubmitAndFlip(g, value);
                CHECK(t < 50.0, "overflow: SubmitAndFlip %d took %.1f ms", k, t);
            }
            CHECK(WaitFor(1000, [&] { return Flips(g).num == flips + 1; }),
                  "overflow: the oldest frame was not dropped: flips %llu, want %llu", (unsigned long long)Flips(g).num,
                  (unsigned long long)(flips + 1));
            CHECK(Flips(g).flipArg == (int64_t)first, "overflow: flip %lld completed first, want %u (the oldest)",
                  (long long)Flips(g).flipArg, first);
            CHECK(HeldDrops() == drops + 1, "overflow: %llu held frames dropped, want 1",
                  (unsigned long long)(HeldDrops() - drops));
            usleep(100 * 1000);
            CHECK(Flips(g).num == flips + 1 && Flips(g).numFlipPending == 3,
                  "overflow: flips %llu, pending %d (want %llu, 3)", (unsigned long long)Flips(g).num,
                  Flips(g).numFlipPending, (unsigned long long)(flips + 1));
            GiveBack(held);
            int64_t last = first;
            bool in_order = true;
            const bool all = WaitFor(4000, [&] {
                const OrbisVideoOutFlipStatus st = Flips(g);
                if (st.flipArg < last) in_order = false;
                last = st.flipArg;
                return st.num == flips + 4;
            });
            flips += 4;
            CHECK(all, "overflow: the held frames never all flipped: flips %llu, want %llu",
                  (unsigned long long)Flips(g).num, (unsigned long long)flips);
            CHECK(in_order && Flips(g).flipArg == (int64_t)value, "overflow: flips out of order (last %lld, want %u)",
                  (long long)Flips(g).flipArg, value);
            CHECK(WaitFor(2000, [&] { return Presented() >= shown + 4; }),
                  "overflow: presenter showed %llu frames, want 4 (the test's slot and 3 held frames)",
                  (unsigned long long)(Presented() - shown));
        }

        // 5. display buffer 1 is written by the CPU and never rendered to: copied on the GPU,
        // presented without a wait while the display is behind, with the CPU's pixels
        if (!g_fail) {
            uint32_t* px = (uint32_t*)(g.ctx->mem_base + g.display_cpu);
            for (uint32_t y = 0; y < kH; ++y)
                for (uint32_t x = 0; x < kW; ++x) px[y * kW + x] = x < kW / 2 ? 0xFFFF0000u : 0xFF0000FFu; // ARGB
            void* held = TakeSlot();
            CHECK(held != nullptr, "guest memory: no present slot to hold");
            BuildFrame(g, ++value, false);
            __atomic_store_n(&g_ps4_screenshot_request, 1, __ATOMIC_RELEASE); // save this frame
            const double t = SubmitAndFlip(g, value, (int)g.base + 1);
            CHECK(t < 50.0, "guest memory: SubmitAndFlip took %.1f ms while the display was behind", t);
            usleep(100 * 1000);
            CHECK(Flips(g).num == flips, "guest memory: the frame flipped while no slot was free");
            GiveBack(held);
            ++flips;
            CHECK(WaitFor(3000, [&] { return Flips(g).num == flips; }), "guest memory: the frame never flipped");
            // the PNG is written on the screenshot queue: read it once it is complete
            std::string shot;
            uint8_t left[4] = {}, right[4] = {};
            const bool read = WaitFor(3000, [&] {
                for (NSString* f in [[NSFileManager defaultManager] contentsOfDirectoryAtPath:@(g_shot_dir.c_str()) error:nil])
                    if (![f isEqualToString:@"frame_000000.png"]) shot = g_shot_dir + "/" + f.UTF8String;
                return !shot.empty() && ShotPixel(shot, kW / 4, kH / 2, left) && ShotPixel(shot, 3 * kW / 4, kH / 2, right);
            });
            CHECK(read, "guest memory: no screenshot of the frame");
            // BGRA bytes: left red, right blue
            CHECK(left[2] > 200 && left[1] < 40 && left[0] < 40, "guest memory: left half is %u,%u,%u (BGR), want red",
                  left[0], left[1], left[2]);
            CHECK(right[0] > 200 && right[1] < 40 && right[2] < 40, "guest memory: right half is %u,%u,%u (BGR), want blue",
                  right[0], right[1], right[2]);
        }

        // 6. the GPU hangs under a slot frame's and held frames' conversions (last: the renderer
        // stays given up)
        if (!g_fail) {
            // the renderer's GPU work from here on never completes (looked up at run time: the
            // old runtime has no such hook, and fails the scenarios before this one)
            auto stall = (int (*)(void))dlsym(RTLD_DEFAULT, "ps4_gnm_metal_debug_stall_gpu");
            CHECK(stall != nullptr && stall() == 0, "hung: the GPU could not be stalled (PS4_TEST_HOOKS=1)");
            void* held = TakeSlot();
            CHECK(held != nullptr, "hung: no present slot to hold");
            const uint64_t drops = HeldDrops();
            BuildFrame(g, ++value);
            SubmitAndFlip(g, value); // held; its conversion never runs
            // the display stays behind: dropped after 1 s and flipped although its conversion
            // never finished
            ++flips;
            CHECK(WaitFor(1600, [&] { return Flips(g).num == flips; }) && HeldDrops() == drops + 1,
                  "hung: a held frame with a hung conversion was not dropped by the 1 s timeout: flips %llu, want %llu",
                  (unsigned long long)Flips(g).num, (unsigned long long)flips);
            const uint64_t before = flips;
            BuildFrame(g, ++value);
            SubmitAndFlip(g, value); // held; its conversion never runs either
            const uint64_t shown6 = Presented();
            GiveBack(held); // the presenter takes the held frame and waits for it on the GPU
            CHECK(WaitFor(1000, [&] { return Presented() >= shown6 + 2; }),
                  "hung: the presenter took %llu frames after the slot was given back, want 2 (the test's slot "
                  "and the held frame)",
                  (unsigned long long)(Presented() - shown6));
            const uint64_t heldn = HeldCount();
            // the next frames are slot frames again (no frame is queued as held any more): a frame
            // flipped while the presenter has a drawable for it gets a slot, and the presenter's
            // command buffer for it waits for its hung conversion. Each frame is flipped once the
            // presenter has got a drawable (a slot is ready), until it gets no more: then the hung
            // command buffers (the held frame's and the slot frames') and the drawable the system
            // still keeps for the display hold all 3. How many drawables the system keeps depends
            // on the window (an occluded window's are returned on the system's own schedule), so
            // the number of slot frames is 1 or 2; the first comes from the test's slot, whose
            // present does not hang.
            auto ready = (bool (*)(void))dlsym(RTLD_DEFAULT, "ps4_metal_screen_slot_ready");
            CHECK(ready != nullptr, "hung: ps4_metal_screen_slot_ready is missing");
            for (int k = 0; k < 2 && ready && !g_fail; ++k) {
                if (!WaitFor(1000, [&] { return ready(); })) break; // the presenter has no drawable left
                const uint64_t shown_k = Presented();
                BuildFrame(g, ++value);
                SubmitAndFlip(g, value); // its flip is behind the held one
                ++slot_frames;
                // the presenter takes it as a slot frame (a held frame would need a drawable the
                // presenter does not have)
                CHECK(WaitFor(1000, [&] { return Presented() > shown_k; }) && HeldCount() == heldn,
                      "hung: frame %d after the held one did not take the ready slot (presented %llu, held %llu; "
                      "want 1, 0)",
                      k, (unsigned long long)(Presented() - shown_k), (unsigned long long)(HeldCount() - heldn));
            }
            CHECK(slot_frames >= 1, "hung: the presenter got no drawable for a frame after the held one");
            usleep(200 * 1000);
            CHECK(HeldCount() == heldn, "hung: the frames after the held one were held, not slot frames");
            CHECK(Flips(g).num == before, "hung: a flip completed before the watchdog gave the GPU up");
            ps4_gnm_metal_wait_gpu_idle(); // the watchdog (PS4_GNM_GPU_TIMEOUT) gives the renderer up
            flips += 1 + slot_frames;
            // at once (well before Metal's own GPU timeout fails the hung command buffers, seconds later)
            CHECK(WaitFor(500, [&] { return Flips(g).num == flips; }),
                  "hung: flips %llu within 500 ms of the watchdog, want %llu (the held frame's flip waits)",
                  (unsigned long long)Flips(g).num, (unsigned long long)flips);
            // the presenter's command buffers for the hung slot frames complete and give their
            // drawables back
            auto idle = (bool (*)(void))dlsym(RTLD_DEFAULT, "ps4_metal_screen_presenter_idle");
            CHECK(idle && WaitFor(500, [&] { return idle(); }),
                  "hung: the presenter still waits for the hung slot frames (their drawables are pinned)");
            // without the renderer: presented on the CPU, flipped in order. The presenter's command
            // buffers for the hung slot frames must have completed and given their drawables and
            // slots back: a CPU present waits up to 1 s for a busy presenter, so a frame that takes
            // longer than 600 ms means they did not.
            for (int k = 0; k < 3 && !g_fail; ++k) {
                const uint64_t shown_k = Presented();
                BuildFrame(g, ++value);
                SubmitAndFlip(g, value);
                ++flips;
                CHECK(WaitFor(600, [&] { return Flips(g).num == flips && Flips(g).flipArg == (int64_t)value; }),
                      "hung: later frame %d did not flip within 600 ms: flips %llu, want %llu (the presenter is still "
                      "busy with the hung slot frames)",
                      k, (unsigned long long)Flips(g).num, (unsigned long long)flips);
                CHECK(Presented() > shown_k, "hung: later frame %d got no drawable (the hung slot frame pins them)", k);
            }
        }

        if (g_fail) {
            fprintf(stderr, "gnm_submit_flip_nonblocking_test %s: %d failure(s)\n", async ? "async" : "sync", g_fail);
            exit(1);
        }
        printf("gnm_submit_flip_nonblocking_test %s: PASS (SubmitAndFlip %.2f ms with the display behind; %d hung slot "
               "frame(s))\n",
               async ? "async" : "sync", ms, slot_frames);
        fflush(stdout);
        exit(0);
    }
}

} // namespace

char g_tmp[] = "/tmp/gnm_flip_test.XXXXXX";

void RemoveTmp() {
    std::error_code ec;
    std::filesystem::remove_all(g_tmp, ec);
}

int main(int argc, char** argv) {
    const bool async = argc > 1 && !strcmp(argv[1], "async");
    g_mode = async ? Mode::Async : argc > 1 && !strcmp(argv[1], "nohooks") ? Mode::NoHooks : Mode::Sync;
    const char* tmp = mkdtemp(g_tmp);
    if (!tmp) return 1;
    atexit(RemoveTmp);
    // own data and cache directories: the shader cache and pipeline archive are written there
    setenv("PS4RECOMP_DATA_DIR", tmp, 1);
    setenv("PS4RECOMP_CACHE_DIR", tmp, 1);
    if (async)
        unsetenv("PS4_GNM_SYNC_ENCODE");
    else
        setenv("PS4_GNM_SYNC_ENCODE", "1", 1);
    setenv("PS4_GNM_SYNC_COMPILE", "1", 1); // the first draw is translated, not skipped
    setenv("PS4_GNM_GPU_TIMEOUT", "500", 1); // the watchdog gives a hung GPU up after 500 ms
    if (g_mode == Mode::NoHooks)
        unsetenv("PS4_TEST_HOOKS");
    else
        setenv("PS4_TEST_HOOKS", "1", 1); // ps4_gnm_metal_debug_stall_gpu
    setenv("PS4_BACKGROUND_WINDOW", "1", 1);
    setenv("PS4_NO_DIALOGS", "1", 1); // no settings dialog (it would block the presenter on AppKit)
    setenv("PS4_UPSCALE", "0", 1);
    unsetenv("PS4_PRESENT_MODE");
    // screenshots only on request (frame 0 is always saved)
    g_shot_dir = std::string(tmp) + "/shots";
    mkdir(g_shot_dir.c_str(), 0755);
    setenv("PS4_SCREENSHOT_DIR", g_shot_dir.c_str(), 1);
    setenv("PS4_SCREENSHOT_EVERY", "1000000000", 1);
    pthread_t th;
    pthread_create(&th, nullptr, TestThread, async ? (void*)1 : nullptr);
    // AppKit (the Metal screen's window) runs on the main thread, as in the game
    ps4_host_run_main_loop();
}
