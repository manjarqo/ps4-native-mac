// Frame capture on the real TextureCache (ps4_gnm_resources.mm) and Metal: the identity of
// GPU-owned entries (DescribeGpuTextures / DescribeGpuTexture / FindGpuTexture, PackSurface),
// an entry re-created from its identity in another cache (what pass replay does), and the raw
// layout of ReadRaw / WriteRaw (ps4gnm_capture::RawSize: levels, then slices, depth and stencil
// planes of Depth32Float_Stencil8), checked against per-level / per-slice reads of the texture.
// The caches run on the renderer backend PS4_GNM_METAL names (test_backend.h): command buffers on
// its SideQueue, textures through its residency; on Metal 4 none is left resident at the end.
#import <Metal/Metal.h>
#include <stdio.h>
#include <string.h>
#include <sys/mman.h>

#include <vector>

#include "ps4_gnm_resources.h"
#include "test_backend.h"

// Runtime symbols ps4_gnm_resources.mm uses (the hitch counters and the Neo mode query).
extern "C" uint64_t ps4_hitch_now_ns(void) { return 0; }
extern "C" void ps4_hitch_add_ns(int, uint64_t) {}
extern "C" void ps4_gnm_hitch_note_upload(double) {}
extern "C" int32_t sceKernelIsNeoMode(void) { return 0; }

using namespace ps4gnm;
namespace cap = ps4gnm_capture;

static int g_fail;

static void check(bool ok, const char* what) {
    printf("%s: %s\n", ok ? "ok" : "FAIL", what);
    if (!ok) g_fail = 1;
}

// The renderer's residency hooks on a cache (TestTextureResidency).
static void Attach(TextureCache& tc, TestTextureResidency& res) {
    TextureCache::TextureHooks h;
    h.ctx = &res;
    h.created = TestTextureResidency::Created;
    h.released = TestTextureResidency::Released;
    tc.SetHooks(h);
}

static ColorTarget Rt(uint64_t addr) {
    ColorTarget c;
    c.bound = true;
    c.address = addr;
    c.pitch = 64;
    c.height = 32;
    c.slice_bytes = 64 * 32 * 4;
    c.num_slices = 1;
    c.num_samples = 1;
    c.bpp = 32;
    c.dfmt = DataFormat::Format8_8_8_8;
    c.nfmt = NumberFormat::Unorm;
    c.mtl_format = MTLPixelFormatRGBA8Unorm;
    c.tile_mode = TileMode::DisplayLinearAligned;
    return c;
}

static DepthTarget Db(uint64_t addr) {
    DepthTarget d;
    d.bound = true;
    d.z_read_address = addr;
    d.pitch = 64;
    d.height = 64;
    d.slice_bytes = 64 * 64 * 4;
    d.num_slices = 1;
    d.num_samples = 1;
    d.bpp = 32;
    d.mtl_format = MTLPixelFormatDepth32Float;
    return d;
}

static std::vector<uint8_t> Pattern(size_t n, uint32_t seed) {
    std::vector<uint8_t> v(n);
    uint32_t x = seed;
    for (size_t i = 0; i < n; ++i) {
        x = x * 1664525u + 1013904223u;
        v[i] = (uint8_t)(x >> 24);
    }
    return v;
}

static bool SameId(const cap::GpuTextureId& a, const cap::GpuTextureId& b) {
    return a.kind == b.kind && a.address == b.address && a.size == b.size && a.mtl_format == b.mtl_format &&
           a.entry_format == b.entry_format && a.tex_type == b.tex_type && a.width == b.width && a.height == b.height &&
           a.depth == b.depth && a.levels == b.levels && a.layers == b.layers && a.samples == b.samples &&
           a.dfmt == b.dfmt && a.nfmt == b.nfmt && !memcmp(a.swizzle, b.swizzle, 4) &&
           !memcmp(a.cb_swizzle, b.cb_swizzle, 4) && a.mtl_type == b.mtl_type && a.mtl_width == b.mtl_width &&
           a.mtl_height == b.mtl_height && a.mtl_depth == b.mtl_depth && a.mtl_levels == b.mtl_levels &&
           a.mtl_array == b.mtl_array && a.mtl_samples == b.mtl_samples && a.usage == b.usage &&
           a.storage_mode == b.storage_mode && a.surface == b.surface;
}

static void test_identity(id<MTLDevice> dev, TestTextureResidency& res, uint8_t* base, uint64_t size) {
    id<MTLCommandQueue> q = res.be->SideQueue();
    TextureCache tc(dev, q, base, size);
    Attach(tc, res);
    const uint64_t C = 0x100000, D = 0x200000;
    id<MTLTexture> ct = tc.GetColorTarget(Rt(C), false);
    id<MTLTexture> dt = tc.GetDepthTarget(Db(D));
    check(ct && dt, "color and depth targets created");
    std::vector<cap::GpuTextureId> ids;
    tc.DescribeGpuTextures(C, &ids);
    check(ids.size() == 1 && ids[0].kind == 1 && ids[0].address == C && ids[0].mtl_width == 64 &&
              ids[0].mtl_height == 32 && ids[0].mtl_format == MTLPixelFormatRGBA8Unorm,
          "DescribeGpuTextures: the color target's identity");
    check(ids.size() == 1 && ids[0].surface.size() == kPackedSurfaceWords, "identity carries the packed surface");
    cap::GpuTextureId g;
    check(tc.DescribeGpuTexture(ct, &g) && ids.size() == 1 && SameId(g, ids[0]), "DescribeGpuTexture agrees");
    check(tc.FindGpuTexture(g, false) == ct, "FindGpuTexture finds the entry by identity");
    cap::GpuTextureId gd;
    check(tc.DescribeGpuTexture(dt, &gd) && gd.kind == 2 && gd.address == D && gd.mtl_format == MTLPixelFormatDepth32Float,
          "the depth target's identity");
    id<MTLTexture> view = [ct newTextureViewWithPixelFormat:MTLPixelFormatRGBA8Unorm_sRGB];
    cap::GpuTextureId gv;
    check(!tc.DescribeGpuTexture(view, &gv), "a view of an entry is not an entry");
    cap::GpuTextureId other = g;
    other.width = 128;
    check(tc.FindGpuTexture(other, false) == nil, "another identity at the same address is not found");

    // PackSurface / UnpackSurface round trip
    SurfaceDesc sd;
    SurfaceLayout sl;
    check(cap::RawSize(g) == 64 * 32 * 4 && cap::RawSize(gd) == 64 * 64 * 4, "RawSize of the targets");
    check(UnpackSurface(g.surface, &sd, &sl), "UnpackSurface accepts PackSurface output");
    std::vector<uint32_t> again;
    PackSurface(sd, sl, &again);
    check(again == g.surface, "PackSurface(UnpackSurface(x)) == x");
    check(!UnpackSurface(std::vector<uint32_t>(3), &sd, &sl), "UnpackSurface refuses a short vector");

    // the contents as raw bytes, then the same entry made from the identity in a second cache
    const std::vector<uint8_t> px = Pattern(cap::RawSize(g), 7);
    check(tc.WriteRaw(ct, px), "WriteRaw color target");
    std::vector<uint8_t> back;
    check(tc.ReadRaw(ct, &back) && back == px, "ReadRaw returns what WriteRaw wrote");
    TextureCache tc2(dev, q, base, size);
    Attach(tc2, res);
    check(tc2.FindGpuTexture(g, false) == nil, "a fresh cache has no entry");
    id<MTLTexture> made = tc2.FindGpuTexture(g, true);
    cap::GpuTextureId gm;
    check(made && tc2.DescribeGpuTexture(made, &gm) && SameId(gm, g), "an entry re-created from its identity is identical");
    check(tc2.FindGpuTexture(g, true) == made, "a second create finds the re-created entry");
    check(made && tc2.FindColorTarget(C) == made, "the renderer's lookup finds the re-created entry");
    std::vector<uint8_t> back2;
    check(made && tc2.WriteRaw(made, px) && tc2.ReadRaw(made, &back2) && back2 == px, "re-created entry round trip");
}

// Raw layout: level-major, then slices; checked against getBytes of each level and slice.
static void test_layout(id<MTLDevice> dev, TestTextureResidency& res, uint8_t* base, uint64_t size) {
    id<MTLCommandQueue> q = res.be->SideQueue();
    TextureCache tc(dev, q, base, size);
    Attach(tc, res);
    MTLTextureDescriptor* td = [MTLTextureDescriptor new];
    td.textureType = MTLTextureType2DArray;
    td.pixelFormat = MTLPixelFormatRGBA16Float;
    td.width = 16;
    td.height = 8;
    td.mipmapLevelCount = 3;
    td.arrayLength = 2;
    td.storageMode = MTLStorageModeShared;
    id<MTLTexture> t = [dev newTextureWithDescriptor:td];
    cap::GpuTextureId g;
    g.mtl_format = MTLPixelFormatRGBA16Float;
    g.mtl_type = MTLTextureType2DArray;
    g.mtl_width = 16;
    g.mtl_height = 8;
    g.mtl_levels = 3;
    g.mtl_array = 2;
    const uint64_t n = cap::RawSize(g);
    check(n == (16 * 8 + 8 * 4 + 4 * 2) * 2 * 8, "RawSize of a mipmapped array");
    const std::vector<uint8_t> px = Pattern(n, 11);
    check(tc.WriteRaw(t, px), "WriteRaw mipmapped array");
    bool ok = true;
    size_t off = 0;
    for (uint32_t l = 0; l < 3; ++l)
        for (uint32_t s = 0; s < 2; ++s) {
            const uint32_t w = 16 >> l, h = 8 >> l;
            std::vector<uint8_t> got(w * h * 8);
            [t getBytes:got.data() bytesPerRow:w * 8 bytesPerImage:w * h * 8 fromRegion:MTLRegionMake2D(0, 0, w, h)
             mipmapLevel:l slice:s];
            ok &= !memcmp(got.data(), px.data() + off, got.size());
            off += got.size();
        }
    check(ok && off == n, "each level / slice sits at its RawSize offset");
    std::vector<uint8_t> back;
    check(tc.ReadRaw(t, &back) && back == px, "ReadRaw of the mipmapped array");

    // depth + stencil: the depth plane, then the stencil plane
    td = [MTLTextureDescriptor new];
    td.textureType = MTLTextureType2D;
    td.pixelFormat = MTLPixelFormatDepth32Float_Stencil8;
    td.width = 8;
    td.height = 4;
    td.storageMode = MTLStorageModePrivate;
    td.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead | MTLTextureUsagePixelFormatView;
    id<MTLTexture> ds = [dev newTextureWithDescriptor:td];
    std::vector<uint8_t> raw(8 * 4 * 5);
    for (int i = 0; i < 32; ++i) {
        const float d = i / 32.0f;
        memcpy(&raw[i * 4], &d, 4);
        raw[32 * 4 + i] = (uint8_t)(200 + i);
    }
    check(tc.WriteRaw(ds, raw), "WriteRaw depth+stencil");
    std::vector<uint8_t> dsb;
    check(tc.ReadRaw(ds, &dsb) && dsb == raw, "ReadRaw depth+stencil: depth plane then stencil plane");
    // the stencil plane seen through a stencil view, rendered nowhere: copied out by a blit
    id<MTLBuffer> sb = [dev newBufferWithLength:32 options:MTLResourceStorageModeShared];
    id<MTLCommandBuffer> cb = [q commandBuffer];
    id<MTLBlitCommandEncoder> bl = [cb blitCommandEncoder];
    [bl copyFromTexture:ds sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0, 0, 0) sourceSize:MTLSizeMake(8, 4, 1)
               toBuffer:sb destinationOffset:0 destinationBytesPerRow:8 destinationBytesPerImage:32
                options:MTLBlitOptionStencilFromDepthStencil];
    [bl endEncoding];
    [cb commit];
    [cb waitUntilCompleted];
    check(((const uint8_t*)sb.contents)[5] == 205, "the stencil plane holds the stencil bytes");

    td = [MTLTextureDescriptor new];
    td.pixelFormat = MTLPixelFormatRGBA8Unorm;
    td.width = 8;
    td.height = 8;
    td.textureType = MTLTextureType2DMultisample;
    td.sampleCount = 4;
    td.storageMode = MTLStorageModePrivate;
    td.usage = MTLTextureUsageRenderTarget;
    std::vector<uint8_t> none;
    check(!tc.ReadRaw([dev newTextureWithDescriptor:td], &none), "multisampled textures are refused");
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
        if (env && !strcmp(env, "4") && !RequireMetal4(dev, "gnm_capture_tex_test")) return 0;
        std::string why;
        std::unique_ptr<GnmBackend> be = MakeTestBackend(dev, &why);
        if (!be) {
            printf("FAIL: no backend: %s\n", why.c_str());
            return 1;
        }
        backend = BackendName(be->Kind());
        TestTextureResidency res;
        res.be = be.get();
        const uint64_t size = 16ull << 20;
        uint8_t* base = (uint8_t*)mmap(nullptr, size, PROT_READ | PROT_WRITE, MAP_ANON | MAP_PRIVATE, -1, 0);
        test_identity(dev, res, base, size);
        test_layout(dev, res, base, size);
        const size_t leaked = res.Leaked();
        if (leaked) printf("%zu cache textures left resident\n", leaked);
        check(leaked == 0, "no texture of a destroyed cache left in the backend's residency");
    }
    printf("gnm_capture_tex_test: %s [%s]\n", g_fail ? "FAIL" : "PASS", backend);
    return g_fail;
}
