// Render targets whose guest memory is written by a buffer store or DMA
// (TextureCache::NoteBufferWrite / TakeGuestNewer in ps4_gnm_resources.mm).
//
// A render target is owned by the GPU: sampling it returns the target texture and never reads
// guest memory. Uncharted 4's chapter 1 has a compute write a surface (0x1311380000) as a
// buffer every frame, while the lighting samples it as an image. Sampling returned the render
// target a cutscene had left at that address, so the lighting read old contents. A buffer write
// over a target's range must mark it ("guest newer"), and the next sample must take a refresh
// from guest memory (copied on the GPU by the renderer behind the writing work). Any overlap
// counts. Drawing into the target again before it is sampled drops the mark.
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>

#include <cstdio>
#include <cstring>

#include "ps4_gnm_resources.h"

using namespace ps4gnm;

extern "C" int32_t sceKernelIsNeoMode(void) { return 0; }
extern "C" void ps4_gnm_hitch_note_upload(double) {}
extern "C" uint64_t ps4_hitch_now_ns(void) { return 0; }
extern "C" void ps4_hitch_add_ns(int, uint64_t) {}

namespace {

int g_fail = 0;
#define CHECK(c, ...)                                                                        \
    do {                                                                                     \
        if (!(c)) {                                                                          \
            std::fprintf(stderr, "gnm_guest_newer_test: FAIL %s:%d: ", __FILE__, __LINE__); \
            std::fprintf(stderr, __VA_ARGS__);                                               \
            std::fprintf(stderr, "\n");                                                      \
            g_fail++;                                                                        \
        }                                                                                    \
    } while (0)

constexpr uint64_t kRt = 0x100000;
constexpr uint32_t kW = 64, kH = 64;

// R32 uint color target, linear, kW x kH at kRt
ColorTarget Target() {
    static uint32_t regs[0x10000];
    std::memset(regs, 0, sizeof(regs));
    const uint32_t b = reg::CB_COLOR0_BASE;
    regs[b + 0] = uint32_t(kRt >> 8);
    regs[b + reg::CB_COLOR_PITCH] = kW / 8 - 1;
    regs[b + reg::CB_COLOR_SLICE] = kW * kH / 64 - 1;
    regs[b + reg::CB_COLOR_INFO] = (4u << 2) | (4u << 8); // format 32, number type uint
    regs[b + reg::CB_COLOR_ATTRIB] = 8;                    // linear aligned
    regs[reg::CB_TARGET_MASK] = 0xF;
    ColorTarget c;
    DecodeColorTarget(regs, 0, &c);
    return c;
}

// T# of the same surface (or another size)
ImageDesc Image(uint32_t w = kW, uint32_t h = kH) {
    uint32_t t[8] = {};
    t[0] = uint32_t(kRt >> 8);
    t[1] = (4u << 20) | (4u << 26); // dfmt 32, nfmt uint
    t[2] = (w - 1) | ((h - 1) << 14);
    t[3] = 4 | (5 << 3) | (6 << 6) | (7 << 9) | (8u << 20) | (9u << 28); // xyzw, linear aligned, 2D
    t[4] = (w - 1) << 13;                                              // pitch
    ImageDesc img;
    DecodeImage(t, 8, &img);
    return img;
}

} // namespace

int main() {
    @autoreleasepool {
        id<MTLDevice> dev = MTLCreateSystemDefaultDevice();
        if (!dev) {
            std::fprintf(stderr, "gnm_guest_newer_test: no Metal device\n");
            return 1;
        }
        id<MTLCommandQueue> q = [dev newCommandQueue];
        id<MTLBuffer> mem = [dev newBufferWithLength:4 << 20 options:MTLResourceStorageModeShared];
        TextureCache tc(dev, q, static_cast<uint8_t*>(mem.contents), mem.length);

        const ColorTarget cb = Target();
        CHECK(cb.bound && cb.mtl_format == MTLPixelFormatR32Uint, "test target not decoded (fmt %u)", cb.mtl_format);
        id<MTLTexture> rt = tc.GetColorTarget(cb);
        CHECK(rt != nil, "no render target texture");
        const ImageDesc img = Image();
        CHECK(img.valid && img.width == kW && img.height == kH, "test T# not decoded");
        CHECK(tc.GetTexture(img) != nil, "sampling the target returns nothing");
        CHECK(tc.GuestNewerCount() == 0, "a new target is not guest newer");

        TextureCache::GpuUpload up;
        CHECK(!tc.TakeGuestNewer(img, &up) && !up.tex, "nothing to refresh before any buffer write");

        // a write just past the target does not touch it
        tc.NoteBufferWrite(kRt + kW * kH * 4, 64, 3);
        CHECK(tc.GuestNewerCount() == 0, "a write past the end marked the target");

        // any overlap marks it; the next sample takes one refresh into the target texture
        tc.NoteBufferWrite(kRt + 4096 - 8, 16, 4);
        CHECK(tc.GuestNewerCount() == 1, "a buffer write over the target did not mark it");
        bool mismatch = false;
        CHECK(tc.TakeGuestNewer(img, &up, &mismatch) && up.tex == rt, "the marked target gives no refresh");
        CHECK(!mismatch, "matching T# reported as mismatch");
        CHECK(up.width == kW && up.height == kH && up.levels == 1 && up.layers == 1 && up.bytes_per_block == 4,
              "refresh: %ux%u levels %u layers %u bpb %u", up.width, up.height, up.levels, up.layers, up.bytes_per_block);
        CHECK(up.layout.total_size == kW * kH * 4, "refresh layout covers %llu bytes, expected %u",
              (unsigned long long)up.layout.total_size, kW * kH * 4);
        CHECK(tc.GuestNewerCount() == 0 && !tc.TakeGuestNewer(img, &up), "the refresh is taken once");

        // a T# that does not match the target: not refreshed, reported
        tc.NoteBufferWrite(kRt, 4, 5);
        CHECK(!tc.TakeGuestNewer(Image(32, 32), &up, &mismatch) && mismatch, "a 32x32 view took the 64x64 refresh");
        // drawn into again before it is sampled: the mark is dropped
        const uint64_t dropped = tc.stats.guest_newer_dropped;
        CHECK(tc.GetColorTarget(cb) == rt, "rebinding the target gave another texture");
        CHECK(tc.GuestNewerCount() == 0 && tc.stats.guest_newer_dropped == dropped + 1,
              "drawing into the target did not drop the mark");

        if (g_fail) {
            std::fprintf(stderr, "gnm_guest_newer_test: %d failure(s)\n", g_fail);
            return 1;
        }
        std::printf("gnm_guest_newer_test: PASS\n");
        return 0;
    }
}
