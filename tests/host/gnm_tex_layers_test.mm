// Array slices of T#s with POW2PAD (ps4_gnm_resources.mm DecodeImage, TextureCache): the guest
// layout of such a T# pads its slice count to a power of two (shadPS4 Image::NumLayers), but its
// slices are depth + 1 (cube: 6 per cube), and those are the ones the Metal texture holds. Before,
// the padded count was the texture's too: inFAMOUS Second Son's 256-cube BC6 cube array (1536
// faces, padded to 2048) was more than a Metal cube array holds (341 cubes, 2046 faces; 2048 faces
// is not even whole cubes) and was bound as null.
//   (a) The inFAMOUS T# (as logged by the renderer) decodes as a valid cube array of 1536 layers
//       whose layout has 2048 slices, not counted as a texture Metal cannot create, and the cache
//       makes a 256-cube BC6H cube array of 6 levels of it.
//   (b) A 4x4 RGBA8 linear cube array T# of 256 cubes with POW2PAD and 2 levels: the texture is a
//       cube array of 256 cubes, and faces 0, 1000 and 1535 of level 0 and face 1535 of level 1
//       hold the guest texels at their padded-layout offsets (level 1 starts after 2048 slices of
//       level 0).
//   (c) A 2D array of 3 slices with POW2PAD (layout 4 slices) makes a 3-slice texture; one of
//       2049 slices (without POW2PAD) is still one Metal cannot create (2048 is the 2D array limit).
// Runs on the backend PS4_GNM_METAL names (test_backend.h).
#import <Metal/Metal.h>
#include <stdio.h>
#include <string.h>
#include <sys/mman.h>

#include "ps4_gnm_resources.h"
#include "test_backend.h"

// Runtime symbols ps4_gnm_resources.mm uses (the hitch counters and the Neo mode query).
extern "C" uint64_t ps4_hitch_now_ns(void) { return 0; }
extern "C" void ps4_hitch_add_ns(int, uint64_t) {}
extern "C" void ps4_gnm_hitch_note_upload(double) {}
extern "C" int32_t sceKernelIsNeoMode(void) { return 0; }

using namespace ps4gnm;

static int g_fail;

static void check(bool ok, const char* what) {
    printf("%s: %s\n", ok ? "ok" : "FAIL", what);
    if (!ok) g_fail = 1;
}

static const uint64_t kGuestSize = 5ull << 30; // the inFAMOUS T# lies at 0xfe632000

static void Attach(TextureCache& tc, TestTextureResidency& res) {
    TextureCache::TextureHooks h;
    h.ctx = &res;
    h.created = TestTextureResidency::Created;
    h.released = TestTextureResidency::Released;
    tc.SetHooks(h);
}

// (a)
static void test_infamous(TextureCache& tc) {
    const uint32_t t[8] = {0x00fe6320, 0x02800000, 0x703fc0ff, 0xb6d503ac, 0x001fe0ff, 0x00bfe000, 0, 0};
    const uint64_t n0 = UncreatableImageCount();
    ImageDesc d;
    const bool ok = DecodeImage(t, 8, &d);
    printf("inFAMOUS T#: valid %d type %u %ux%u levels %u layers %u layout layers %u pow2pad %d mtl type %u\n", ok,
           (uint32_t)d.type, d.width, d.height, d.num_levels, d.num_layers, d.ToSurfaceDesc(false).layers,
           (int)d.pow2pad, d.mtl_texture_type);
    check(ok && d.valid, "the inFAMOUS 2048-slice cube T# decodes as valid");
    check(UncreatableImageCount() == n0, "it is not counted as a texture Metal cannot create");
    check(d.mtl_texture_type == MTLTextureTypeCubeArray, "it is a cube array");
    check(d.num_layers == 1536, "its texture holds 256 cubes (1536 faces)");
    check(d.ToSurfaceDesc(false).layers == 2048, "its guest layout keeps the 2048 padded slices");
    check(d.NumViewLayers(true) == 1536, "its view covers the 1536 faces (last_array 1535)");
    @autoreleasepool {
        id<MTLTexture> tex = tc.GetTexture(d);
        check(tex != nil, "the cache makes a texture of it");
        if (tex) {
            printf("  texture: type %lu %lux%lu arrayLength %lu levels %lu format %lu\n",
                   (unsigned long)tex.textureType, (unsigned long)tex.width, (unsigned long)tex.height,
                   (unsigned long)tex.arrayLength, (unsigned long)tex.mipmapLevelCount,
                   (unsigned long)tex.pixelFormat);
            check(tex.textureType == MTLTextureTypeCubeArray && tex.arrayLength == 256 && tex.width == 256 &&
                      tex.mipmapLevelCount == 6,
                  "the texture is a 256x256 cube array of 256 cubes and 6 levels");
            check(tex.pixelFormat == MTLPixelFormatBC6H_RGBUfloat || tex.pixelFormat == MTLPixelFormatBC6H_RGBFloat,
                  "the texture is BC6H");
        }
    }
}

// 4x4 RGBA8 linear-aligned cube array T# (pitch 64) of `cubes` cubes at addr, POW2PAD, 2 levels.
static void CubeTsharp(uint32_t* t, uint64_t addr, uint32_t cubes) {
    memset(t, 0, 32);
    t[0] = (uint32_t)(addr >> 8);
    t[1] = (uint32_t)((addr >> 40) & 0xff) | (10u << 20); // 8_8_8_8 unorm
    t[2] = 3 | (3u << 14);                                // 4 x 4
    t[3] = 4u | (5u << 3) | (6u << 6) | (7u << 9) | (1u << 16) /* last_level 1 */ | (8u << 20) /* linear aligned */ |
           (1u << 25) /* pow2pad */ | (11u << 28) /* cube */;
    t[4] = (cubes - 1) | (63u << 13); // depth: cubes - 1, pitch 64
    t[5] = (cubes * 6 - 1) << 13;     // last_array
}

// Texel (0, 0) of slice `slice` of level `level` of tex (any storage mode) as RGBA8.
static uint32_t ReadTexel(id<MTLDevice> dev, id<MTLCommandQueue> q, id<MTLTexture> tex, uint32_t slice,
                          uint32_t level) {
    id<MTLBuffer> b = [dev newBufferWithLength:256 options:MTLResourceStorageModeShared];
    id<MTLCommandBuffer> cb = [q commandBuffer];
    id<MTLBlitCommandEncoder> bl = [cb blitCommandEncoder];
    [bl copyFromTexture:tex
                     sourceSlice:slice
                     sourceLevel:level
                    sourceOrigin:MTLOriginMake(0, 0, 0)
                      sourceSize:MTLSizeMake(1, 1, 1)
                        toBuffer:b
               destinationOffset:0
          destinationBytesPerRow:4
        destinationBytesPerImage:4];
    [bl endEncoding];
    [cb commit];
    [cb waitUntilCompleted];
    uint32_t v;
    memcpy(&v, b.contents, 4);
    return v;
}

// (b)
static void test_cube_content(id<MTLDevice> dev, id<MTLCommandQueue> q, TextureCache& tc, uint8_t* mem) {
    const uint64_t addr = 0x10000000;
    uint32_t t[8];
    CubeTsharp(t, addr, 256);
    ImageDesc d;
    check(DecodeImage(t, 8, &d) && d.valid, "the 256-cube POW2PAD RGBA8 cube array T# decodes as valid");
    const SurfaceDesc sd = d.ToSurfaceDesc(false);
    SurfaceLayout l;
    check(sd.layers == 2048 && ComputeSurfaceLayout(sd, &l) && l.num_mips == 2 && l.mips[0].slices == 2048,
          "its layout has 2 levels of 2048 slices");
    const uint32_t slice0 = l.mips[0].size / l.mips[0].slices, slice1 = l.mips[1].size / l.mips[1].slices;
    // texel (0, 0) of each slice of a level: a value naming the level and slice
    for (uint32_t s = 0; s < 1536; ++s) {
        const uint32_t v0 = 0xFF000000u | s, v1 = 0xFE000000u | s;
        memcpy(mem + addr + l.mips[0].offset + (uint64_t)s * slice0, &v0, 4);
        memcpy(mem + addr + l.mips[1].offset + (uint64_t)s * slice1, &v1, 4);
    }
    @autoreleasepool {
        id<MTLTexture> tex = tc.GetTexture(d);
        check(tex != nil, "the cache makes a texture of it");
        if (!tex) return;
        check(tex.textureType == MTLTextureTypeCubeArray && tex.arrayLength == 256 && tex.mipmapLevelCount == 2,
              "it is a cube array of 256 cubes and 2 levels");
        const uint32_t s0 = ReadTexel(dev, q, tex, 0, 0), s1000 = ReadTexel(dev, q, tex, 1000, 0),
                       s1535 = ReadTexel(dev, q, tex, 1535, 0), l1 = ReadTexel(dev, q, tex, 1535, 1);
        printf("  level 0 faces 0 / 1000 / 1535: %08x %08x %08x, level 1 face 1535: %08x\n", s0, s1000, s1535, l1);
        check(s0 == 0xFF000000u && s1000 == (0xFF000000u | 1000) && s1535 == (0xFF000000u | 1535),
              "level 0 faces hold their guest texels");
        check(l1 == (0xFE000000u | 1535), "level 1 is read after the 2048 padded slices of level 0");
    }
}

// 2D RGBA8 linear-aligned array T# of `slices` slices (pitch 64), one level.
static ImageDesc ArrayTsharp(uint64_t addr, uint32_t slices, bool pow2pad) {
    uint32_t t[8] = {};
    t[0] = (uint32_t)(addr >> 8);
    t[1] = 10u << 20;
    t[2] = 3 | (3u << 14);
    t[3] = 4u | (5u << 3) | (6u << 6) | (7u << 9) | (8u << 20) | ((pow2pad ? 1u : 0u) << 25) | (13u << 28);
    t[4] = (slices - 1) | (63u << 13);
    t[5] = (slices - 1) << 13;
    ImageDesc d;
    DecodeImage(t, 8, &d);
    return d;
}

// (c)
static void test_arrays(TextureCache& tc) {
    const ImageDesc a = ArrayTsharp(0x20000000, 3, true);
    check(a.valid && a.num_layers == 3 && a.ToSurfaceDesc(false).layers == 4,
          "a 3-slice POW2PAD 2D array has 3 layers and a 4-slice layout");
    @autoreleasepool {
        id<MTLTexture> tex = tc.GetTexture(a);
        check(tex && tex.textureType == MTLTextureType2DArray && tex.arrayLength == 3,
              "the cache makes a 3-slice 2D array of it");
    }
    const uint64_t n0 = UncreatableImageCount();
    const ImageDesc b = ArrayTsharp(0x20000000, 2049, false);
    check(!b.valid && UncreatableImageCount() == n0 + 1,
          "a 2049-slice 2D array is a texture Metal cannot create (counted, bound as null)");
}

int main() {
    const char* backend = "none";
    @autoreleasepool {
        id<MTLDevice> dev = MTLCreateSystemDefaultDevice();
        if (!dev) {
            printf("FAIL: no Metal device\n");
            return 1;
        }
        const char* env = getenv("PS4_GNM_METAL");
        if (env && !strcmp(env, "4") && !RequireMetal4(dev, "gnm_tex_layers_test")) return 0;
        std::string why;
        std::unique_ptr<GnmBackend> be = MakeTestBackend(dev, &why);
        if (!be) {
            printf("FAIL: no backend: %s\n", why.c_str());
            return 1;
        }
        backend = BackendName(be->Kind());
        TestTextureResidency res;
        res.be = be.get();
        uint8_t* mem = (uint8_t*)mmap(nullptr, kGuestSize, PROT_READ | PROT_WRITE, MAP_ANON | MAP_PRIVATE | MAP_NORESERVE,
                                      -1, 0);
        if (mem == MAP_FAILED) {
            printf("FAIL: guest memory not mapped\n");
            return 1;
        }
        id<MTLCommandQueue> q = be->SideQueue();
        {
            TextureCache tc(dev, q, mem, kGuestSize);
            Attach(tc, res);
            test_infamous(tc);
            test_cube_content(dev, q, tc, mem);
            test_arrays(tc);
        }
        res.Retire();
        munmap(mem, kGuestSize);
    }
    printf("gnm_tex_layers_test: %s [%s]\n", g_fail ? "FAIL" : "PASS", backend);
    return g_fail;
}
