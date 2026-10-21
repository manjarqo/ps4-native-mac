// Fast-clear colours (pkg/runtime/modules/libSceGnmDriver/ps4_gnm_clear_color.h) on Metal.
//
// A fast-cleared colour target is cleared by the renderer with the colour decoded from the
// CB_COLOR*_CLEAR_WORD registers. Integer and snorm formats were not decoded ("fast clear:
// unsupported format 13" = R8Uint in Uncharted 4's chapter 1): the clear was skipped and the
// target kept stale contents. Each case clears a 4x4 target with a render pass load action and
// reads the texel back; the bits must be those of the clear words.
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>

#include <cstdio>
#include <cstring>

#include "ps4_gnm_clear_color.h"

namespace {

int g_fail = 0;

struct Case {
    const char* name;
    MTLPixelFormat fmt;
    uint32_t w0, w1;
    uint32_t bytes;    // texel size
    uint8_t want[16];  // expected texel bytes
};

void Run(id<MTLDevice> dev, id<MTLCommandQueue> q, const Case& c) {
    MTLClearColor cc;
    if (!ps4gnm_clear::ClearColorFor(c.fmt, c.w0, c.w1, &cc)) {
        std::fprintf(stderr, "gnm_clear_color_test: FAIL %s: format %lu not decoded\n", c.name, (unsigned long)c.fmt);
        g_fail++;
        return;
    }
    MTLTextureDescriptor* td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:c.fmt width:4 height:4 mipmapped:NO];
    td.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
    td.storageMode = MTLStorageModeShared;
    id<MTLTexture> t = [dev newTextureWithDescriptor:td];
    MTLRenderPassDescriptor* rp = [MTLRenderPassDescriptor renderPassDescriptor];
    rp.colorAttachments[0].texture = t;
    rp.colorAttachments[0].loadAction = MTLLoadActionClear;
    rp.colorAttachments[0].clearColor = cc;
    rp.colorAttachments[0].storeAction = MTLStoreActionStore;
    id<MTLCommandBuffer> cb = [q commandBuffer];
    [[cb renderCommandEncoderWithDescriptor:rp] endEncoding];
    [cb commit];
    [cb waitUntilCompleted];
    uint8_t px[16] = {};
    [t getBytes:px bytesPerRow:4 * c.bytes fromRegion:MTLRegionMake2D(1, 2, 1, 1) mipmapLevel:0];
    if (memcmp(px, c.want, c.bytes) != 0) {
        std::fprintf(stderr, "gnm_clear_color_test: FAIL %s: texel", c.name);
        for (uint32_t i = 0; i < c.bytes; i++) std::fprintf(stderr, " %02x", px[i]);
        std::fprintf(stderr, ", expected");
        for (uint32_t i = 0; i < c.bytes; i++) std::fprintf(stderr, " %02x", c.want[i]);
        std::fprintf(stderr, "\n");
        g_fail++;
    }
}

} // namespace

int main() {
    @autoreleasepool {
        id<MTLDevice> dev = MTLCreateSystemDefaultDevice();
        if (!dev) {
            std::fprintf(stderr, "gnm_clear_color_test: no Metal device\n");
            return 1;
        }
        id<MTLCommandQueue> q = [dev newCommandQueue];
        const Case cases[] = {
            {"R8Uint", MTLPixelFormatR8Uint, 0x000000C5, 0, 1, {0xC5}},
            {"R8Sint", MTLPixelFormatR8Sint, 0x000000F6, 0, 1, {0xF6}},
            {"RG8Uint", MTLPixelFormatRG8Uint, 0x00002A81, 0, 2, {0x81, 0x2A}},
            {"RGBA8Uint", MTLPixelFormatRGBA8Uint, 0x04030201, 0, 4, {1, 2, 3, 4}},
            {"RGBA8Sint", MTLPixelFormatRGBA8Sint, 0x80FF7F01, 0, 4, {0x01, 0x7F, 0xFF, 0x80}},
            {"R8Snorm", MTLPixelFormatR8Snorm, 0x00000081, 0, 1, {0x81}},
            {"RGBA8Snorm", MTLPixelFormatRGBA8Snorm, 0xC0817F00, 0, 4, {0x00, 0x7F, 0x81, 0xC0}},
            {"R16Uint", MTLPixelFormatR16Uint, 0x0000BEEF, 0, 2, {0xEF, 0xBE}},
            {"RG16Sint", MTLPixelFormatRG16Sint, 0x8001FFFE, 0, 4, {0xFE, 0xFF, 0x01, 0x80}},
            {"RGBA16Uint", MTLPixelFormatRGBA16Uint, 0x00020001, 0x00040003, 8, {1, 0, 2, 0, 3, 0, 4, 0}},
            {"RG32Uint", MTLPixelFormatRG32Uint, 0xDEADBEEF, 0x01234567, 8, {0xEF, 0xBE, 0xAD, 0xDE, 0x67, 0x45, 0x23, 0x01}},
            {"R32Sint", MTLPixelFormatR32Sint, 0xFFFFFFF0, 0, 4, {0xF0, 0xFF, 0xFF, 0xFF}},
            // formats decoded before: unchanged
            {"RGBA8Unorm", MTLPixelFormatRGBA8Unorm, 0x80FF4000, 0, 4, {0x00, 0x40, 0xFF, 0x80}},
            {"R32Uint", MTLPixelFormatR32Uint, 0x89ABCDEF, 0, 4, {0xEF, 0xCD, 0xAB, 0x89}},
        };
        for (const Case& c : cases) Run(dev, q, c);
        if (g_fail) {
            std::fprintf(stderr, "gnm_clear_color_test: %d failure(s)\n", g_fail);
            return 1;
        }
        std::printf("gnm_clear_color_test: PASS\n");
        return 0;
    }
}
