// Every copy and fill of GnmBackend on the backend PS4_GNM_METAL selects (both run it), with the
// results read back on the CPU: buffer copy at offsets, a byte fill, a buffer into two levels and
// two slices of a texture array (row pitches), a buffer into a 3D texture (row and a padded image
// pitch), a texture region between levels and
// slices, a whole-texture copy; the upload target (a copy recorded there runs before the main
// command buffer's copy that reads its result, in the same seq); and dependent copies inside one
// copy group (a 64 MiB copy, then a copy of its last MiB; a buffer into a texture, then a region
// of that texture), which the backend must order. With PS4_GNM_METAL=4 the same work also runs on
// a Metal3Backend, and every output byte must equal Metal 3's. Every texture starts filled with a
// known pattern, so texels no copy writes compare equal for a reason (and show if one did).
// Metal 4 only (its copies run on compute encoders, so both can share one): a copy after a slow
// dispatch that writes its source in reverse order, and a dispatch after a copy that writes its
// input, in one encoder, ordered by the backend's barriers.
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>

#include <vector>

#include "backend_harness.h"
#include "ps4_gnm_util_passes.h"

using namespace ps4gnm;

// Everything the copies wrote, read back (buffers, then every level and slice of each texture).
struct Outputs {
    std::vector<uint8_t> dst, fill, big_tail, dep_tex;
    std::vector<std::vector<uint8_t>> tex; // arr, region, whole, up_copy, vol
};

static std::vector<uint8_t> Bytes(id<MTLBuffer> b, size_t off, size_t n) {
    const uint8_t* p = (const uint8_t*)b.contents + off;
    return std::vector<uint8_t>(p, p + n);
}

// The extent of level l of t (R32Uint: 4 bytes a texel).
static MTLSize LevelSize(id<MTLTexture> t, NSUInteger l) {
    return MTLSizeMake(std::max<NSUInteger>(t.width >> l, 1), std::max<NSUInteger>(t.height >> l, 1),
                       std::max<NSUInteger>(t.depth >> l, 1));
}

static std::vector<uint8_t> TexBytes(id<MTLTexture> t) {
    std::vector<uint8_t> out;
    for (NSUInteger s = 0; s < t.arrayLength; ++s)
        for (NSUInteger l = 0; l < t.mipmapLevelCount; ++l) {
            const MTLSize e = LevelSize(t, l);
            std::vector<uint8_t> px(e.width * e.height * e.depth * 4);
            [t getBytes:px.data() bytesPerRow:e.width * 4 bytesPerImage:e.width * e.height * 4
                 fromRegion:MTLRegionMake3D(0, 0, 0, e.width, e.height, e.depth) mipmapLevel:l slice:s];
            out.insert(out.end(), px.begin(), px.end());
        }
    return out;
}

// Fills every level and slice of t with 0xDEAD0000 + level * 256 + slice.
static void Prefill(id<MTLTexture> t) {
    for (NSUInteger s = 0; s < t.arrayLength; ++s)
        for (NSUInteger l = 0; l < t.mipmapLevelCount; ++l) {
            const MTLSize e = LevelSize(t, l);
            std::vector<uint32_t> px(e.width * e.height * e.depth, 0xDEAD0000u + (uint32_t)(l * 256 + s));
            [t replaceRegion:MTLRegionMake3D(0, 0, 0, e.width, e.height, e.depth) mipmapLevel:l slice:s
                   withBytes:px.data() bytesPerRow:e.width * 4 bytesPerImage:e.width * e.height * 4];
        }
}

static uint32_t Texel(id<MTLTexture> t, uint32_t x, uint32_t y, uint32_t level, uint32_t slice) {
    uint32_t v = 0;
    [t getBytes:&v bytesPerRow:64 bytesPerImage:0 fromRegion:MTLRegionMake2D(x, y, 1, 1) mipmapLevel:level slice:slice];
    return v;
}

static bool Run(id<MTLDevice> dev, GnmBackend& be, uint64_t seq, Outputs* out) {
    const auto buffer = [&](size_t n, uint8_t fill) {
        id<MTLBuffer> b = [dev newBufferWithLength:n options:MTLResourceStorageModeShared];
        memset(b.contents, fill, n);
        be.MakeResident(b, GnmResidencyClass::Builtin);
        return b;
    };
    const auto texture = [&](MTLTextureType type, uint32_t w, uint32_t h, uint32_t levels, uint32_t slices,
                             uint32_t depth = 1) {
        MTLTextureDescriptor* td = [MTLTextureDescriptor new];
        td.textureType = type;
        td.pixelFormat = MTLPixelFormatR32Uint;
        td.width = w;
        td.height = h;
        td.depth = depth;
        td.mipmapLevelCount = levels;
        td.arrayLength = slices;
        td.storageMode = MTLStorageModeShared;
        td.usage = MTLTextureUsageShaderRead;
        id<MTLTexture> t = [dev newTextureWithDescriptor:td];
        Prefill(t);
        be.MakeResident(t, GnmResidencyClass::Texture);
        return t;
    };
    id<MTLBuffer> src = buffer(1 << 16, 0), dst = buffer(1 << 16, 0xEE), fill = buffer(4096, 0);
    for (uint32_t i = 0; i < (1u << 14); ++i) ((uint32_t*)src.contents)[i] = 0x01000000u + i;
    constexpr size_t kBig = 64u << 20, kTail = 1u << 20;
    id<MTLBuffer> big_src = buffer(kBig, 0), big_mid = buffer(kBig, 0x33), big_tail = buffer(kTail, 0x44);
    for (size_t i = 0; i < kBig / 4; ++i) ((uint32_t*)big_src.contents)[i] = (uint32_t)i * 2654435761u;
    id<MTLTexture> arr = texture(MTLTextureType2DArray, 16, 8, 2, 2);
    id<MTLTexture> region = texture(MTLTextureType2DArray, 16, 8, 2, 2);
    id<MTLTexture> whole = texture(MTLTextureType2DArray, 16, 8, 2, 2);
    id<MTLTexture> up = texture(MTLTextureType2D, 16, 8, 1, 1), up_copy = texture(MTLTextureType2D, 16, 8, 1, 1);
    // 8x4x3 from byte 8192: row 32 bytes, image 160 (one padding row of 32 bytes between images)
    id<MTLTexture> vol = texture(MTLTextureType3D, 8, 4, 1, 1, 3);
    id<MTLTexture> dep_mid = texture(MTLTextureType2D, 1024, 1024, 1, 1), dep_out = texture(MTLTextureType2D, 64, 64, 1, 1);
    id<MTLBuffer> dep_src = buffer(1024 * 1024 * 4, 0);
    for (uint32_t i = 0; i < 1024 * 1024; ++i) ((uint32_t*)dep_src.contents)[i] = i ^ 0x5A5A0000u;
    be.BeginCmd(GnmCmdTarget::Main, @"copies", false);
    be.BeginCopies();
    be.CopyBuffer(src, 256, dst, 1024, 4096);
    be.FillBuffer(fill, 512, 1024, 0x5A);
    // level 0: 16x8, row 64 bytes; level 1: 8x4, row 32; two slices each; image pitch 0: one 2D image
    be.CopyBufferToTexture(src, 0, 64, 0, MTLSizeMake(16, 8, 1), arr, 0, 0, MTLOriginMake(0, 0, 0));
    be.CopyBufferToTexture(src, 512, 64, 0, MTLSizeMake(16, 8, 1), arr, 1, 0, MTLOriginMake(0, 0, 0));
    be.CopyBufferToTexture(src, 1024, 32, 0, MTLSizeMake(8, 4, 1), arr, 0, 1, MTLOriginMake(0, 0, 0));
    be.CopyBufferToTexture(src, 1152, 32, 0, MTLSizeMake(8, 4, 1), arr, 1, 1, MTLOriginMake(0, 0, 0));
    be.CopyBufferToTexture(src, 8192, 32, 160, MTLSizeMake(8, 4, 3), vol, 0, 0, MTLOriginMake(0, 0, 0));
    be.EndEncoder();
    be.BeginCopies(); // reads what the previous encoder wrote
    be.CopyTextureRegion(arr, 1, 0, MTLOriginMake(4, 2, 0), MTLSizeMake(8, 4, 1), region, 0, 1, MTLOriginMake(0, 0, 0));
    be.CopyTexture(arr, whole);
    be.EndEncoder();
    // dependent copies inside one group: the second reads what the first writes (its last MiB,
    // written last), so only an ordering between them gives the source's bytes
    be.BeginCopies();
    be.CopyBuffer(big_src, 0, big_mid, 0, kBig);
    be.CopyBuffer(big_mid, kBig - kTail, big_tail, 0, kTail);
    be.CopyBufferToTexture(dep_src, 0, 4096, 0, MTLSizeMake(1024, 1024, 1), dep_mid, 0, 0, MTLOriginMake(0, 0, 0));
    be.CopyTextureRegion(dep_mid, 0, 0, MTLOriginMake(960, 960, 0), MTLSizeMake(64, 64, 1), dep_out, 0, 0,
                         MTLOriginMake(0, 0, 0));
    be.EndEncoder();
    // the upload target: committed before the main command buffer, in this seq
    be.BeginCmd(GnmCmdTarget::Upload, @"uploads", false);
    be.UseTarget(GnmCmdTarget::Upload);
    be.BeginCopies();
    be.CopyBufferToTexture(src, 4096, 64, 0, MTLSizeMake(16, 8, 1), up, 0, 0, MTLOriginMake(0, 0, 0));
    be.EndEncoder();
    be.UseTarget(GnmCmdTarget::Main);
    be.BeginCopies();
    be.CopyTexture(up, up_copy);
    be.EndEncoder();
    if (!CommitAndWait(be, seq)) return false;
    const uint32_t* s = (const uint32_t*)src.contents;
    const char* kind = BackendName(be.Kind());
    CHECK(!memcmp((uint8_t*)dst.contents + 1024, (uint8_t*)src.contents + 256, 4096), "%s: CopyBuffer", kind);
    CHECK(((uint8_t*)dst.contents)[1023] == 0xEE && ((uint8_t*)dst.contents)[1024 + 4096] == 0xEE,
          "%s: CopyBuffer outside its range", kind);
    bool fill_ok = true;
    for (int i = 0; i < 4096; ++i) fill_ok &= ((uint8_t*)fill.contents)[i] == (i >= 512 && i < 1536 ? 0x5A : 0);
    CHECK(fill_ok, "%s: FillBuffer", kind);
    CHECK(Texel(arr, 5, 3, 0, 0) == s[3 * 16 + 5], "%s: buffer -> texture level 0 slice 0", kind);
    CHECK(Texel(arr, 5, 3, 0, 1) == s[128 + 3 * 16 + 5], "%s: buffer -> texture level 0 slice 1", kind);
    CHECK(Texel(arr, 2, 1, 1, 0) == s[256 + 1 * 8 + 2], "%s: buffer -> texture level 1 slice 0", kind);
    CHECK(Texel(arr, 7, 3, 1, 1) == s[288 + 3 * 8 + 7], "%s: buffer -> texture level 1 slice 1", kind);
    CHECK(Texel(region, 3, 2, 1, 0) == Texel(arr, 7, 4, 0, 1), "%s: texture region (slice 1 level 0 -> slice 0 level 1)",
          kind);
    CHECK(Texel(whole, 7, 3, 1, 1) == Texel(arr, 7, 3, 1, 1) && Texel(whole, 0, 0, 0, 0) == s[0], "%s: whole-texture copy",
          kind);
    {
        uint32_t v = 0; // (5, 2, 2): 8192 / 4 + 2 * 40 + 2 * 8 + 5
        [vol getBytes:&v bytesPerRow:32 bytesPerImage:128 fromRegion:MTLRegionMake3D(5, 2, 2, 1, 1, 1) mipmapLevel:0
                slice:0];
        CHECK(v == s[2048 + 2 * 40 + 2 * 8 + 5], "%s: buffer -> 3D texture with an image pitch (%08x)", kind, v);
    }
    CHECK(Texel(region, 0, 0, 0, 0) == 0xDEAD0000u && Texel(region, 15, 7, 0, 1) == 0xDEAD0001u,
          "%s: texels outside the region copy keep the pattern", kind);
    CHECK(Texel(up_copy, 9, 6, 0, 0) == s[1024 + 6 * 16 + 9], "%s: upload target before the main command buffer", kind);
    CHECK(!memcmp(big_tail.contents, (uint8_t*)big_src.contents + kBig - kTail, kTail),
          "%s: a copy read its source before the earlier copy of the group wrote it (buffer -> buffer)", kind);
    std::vector<uint32_t> dep(64 * 64);
    [dep_out getBytes:dep.data() bytesPerRow:256 fromRegion:MTLRegionMake2D(0, 0, 64, 64) mipmapLevel:0];
    size_t dep_bad = 0;
    for (uint32_t y = 0; y < 64; ++y)
        for (uint32_t x = 0; x < 64; ++x) dep_bad += dep[y * 64 + x] != (((960 + y) * 1024 + 960 + x) ^ 0x5A5A0000u);
    CHECK(dep_bad == 0, "%s: a region copy read %zu of 4096 texels before the buffer copy of the group wrote them", kind,
          dep_bad);
    out->dst = Bytes(dst, 0, dst.length);
    out->fill = Bytes(fill, 0, fill.length);
    out->big_tail = Bytes(big_tail, 0, kTail);
    out->dep_tex = TexBytes(dep_out);
    out->tex = {TexBytes(arr), TexBytes(region), TexBytes(whole), TexBytes(up_copy), TexBytes(vol)};
    return true;
}

static const char* kMixedMsl = R"(
#include <metal_stdlib>
using namespace metal;
// thread i writes element n - 1 - i after a busy loop: the lowest elements land last
kernel void k_write_slow(device uint* out [[buffer(0)]], constant uint& n [[buffer(1)]], uint i [[thread_position_in_grid]]) {
    uint h = i;
    for (uint k = 0; k < 512u; ++k) h = h * 1664525u + 1013904223u;
    const uint j = n - 1u - i;
    out[j] = j + 1u + (h & (n >> 31u)); // n < 2^31: adds 0, but the compiler cannot drop the loop
}
// reads from the end first (thread i reads element n - 1 - i): what a forward copy writes last
kernel void k_double(device const uint* in [[buffer(0)]], device uint* out [[buffer(1)]], constant uint& n [[buffer(2)]],
                     uint i [[thread_position_in_grid]]) {
    const uint j = n - 1u - i;
    out[j] = in[j] * 2u;
}
)";

static void TestMixedEncoder(id<MTLDevice> dev, GnmBackend& be, uint64_t seq) {
    NSError* err = nil;
    id<MTLLibrary> lib = [dev newLibraryWithSource:@(kMixedMsl) options:nil error:&err];
    id<MTLComputePipelineState> slow =
        lib ? [dev newComputePipelineStateWithFunction:[lib newFunctionWithName:@"k_write_slow"] error:&err] : nil;
    id<MTLComputePipelineState> dbl =
        lib ? [dev newComputePipelineStateWithFunction:[lib newFunctionWithName:@"k_double"] error:&err] : nil;
    CHECK(slow && dbl, "mixed-encoder pipelines: %s", err.localizedDescription.UTF8String);
    if (!slow || !dbl) return;
    constexpr uint32_t kN = 1u << 22;
    constexpr size_t kHead = 1u << 20; // the copy reads the first MiB: written last by the slow writer
    const auto buffer = [&](size_t n, uint8_t fill) {
        id<MTLBuffer> b = [dev newBufferWithLength:n options:MTLResourceStorageModeShared];
        memset(b.contents, fill, n);
        be.MakeResident(b, GnmResidencyClass::Builtin);
        return b;
    };
    id<MTLBuffer> a = buffer(kN * 4, 0), head = buffer(kHead, 0x77), src = buffer(kN * 4, 0), a2 = buffer(kN * 4, 0),
                  b2 = buffer(kN * 4, 0);
    for (uint32_t i = 0; i < kN; ++i) ((uint32_t*)src.contents)[i] = i + 1u;
    be.BeginCmd(GnmCmdTarget::Main, @"mixed", false);
    be.BeginCompute(false);
    const uint32_t n = kN;
    be.SetComputePipeline(slow);
    be.BindBuffer(GnmStage::Compute, 0, a, 0);
    be.BindBytes(GnmStage::Compute, 1, &n, sizeof(n));
    be.Dispatch(MTLSizeMake(kN / 256, 1, 1), MTLSizeMake(256, 1, 1));
    be.CopyBuffer(a, 0, head, 0, kHead); // after the dispatch
    // a 16 MiB copy, then a dispatch that reads all of it, the end first
    be.CopyBuffer(src, 0, a2, 0, kN * 4);
    be.SetComputePipeline(dbl);
    be.BindBuffer(GnmStage::Compute, 0, a2, 0);
    be.BindBuffer(GnmStage::Compute, 1, b2, 0);
    be.BindBytes(GnmStage::Compute, 2, &n, sizeof(n));
    be.Dispatch(MTLSizeMake(kN / 256, 1, 1), MTLSizeMake(256, 1, 1)); // after the copy
    be.EndEncoder();
    CHECK(CommitAndWait(be, seq), "mixed seq failed");
    const uint32_t* h = (const uint32_t*)head.contents;
    size_t bad = 0;
    for (uint32_t i = 0; i < kHead / 4; ++i) bad += h[i] != i + 1u;
    CHECK(bad == 0, "a copy read %zu of %zu dwords before the dispatch before it wrote them", bad, kHead / 4);
    const uint32_t* o = (const uint32_t*)b2.contents;
    bad = 0;
    for (uint32_t i = 0; i < kN; ++i) bad += o[i] != (i + 1u) * 2u;
    CHECK(bad == 0, "a dispatch read %zu of %u dwords before the copy before it wrote them", bad, kN);
}

// The renderer's texture cache alias copy (ps4_gnm_draw.mm AliasCopy through TextureCache::
// GpuCopyHook) on the renderer's timeline: the upload command buffer of the open seq, which runs
// after every committed seq. Seq 1 waits for a gate and clears the target green; it is committed
// and not waited for. Seq 2 copies the target into a smaller texture on the upload target (as
// AliasCopy: Upload, BeginCopies, CopyTextureRegion, EndEncoder), then samples the copy in a Main
// pass. The gate opens after both commits: the copy and the sampled output must be green. A copy
// on a queue of its own (the cache's own command buffer, the old behaviour) runs before the gate
// opens and reads the target's earlier contents.
static void TestAliasCopyOrder(id<MTLDevice> dev) {
    std::string why;
    std::unique_ptr<GnmBackend> be = MakeTestBackend(dev, &why);
    GnmUtil util;
    CHECK(be && MakeGnmUtil(dev, &util, &why), "alias copy order: %s", why.c_str());
    if (!be || !util.present) return;
    auto tex = [&](NSUInteger w, MTLTextureUsage usage) {
        MTLTextureDescriptor* td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                                                                                      width:w height:w mipmapped:NO];
        td.usage = usage;
        td.storageMode = MTLStorageModeShared;
        id<MTLTexture> t = [dev newTextureWithDescriptor:td];
        be->MakeResident(t, GnmResidencyClass::Texture);
        return t;
    };
    id<MTLTexture> target = tex(32, MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead);
    id<MTLTexture> copy = tex(16, MTLTextureUsageShaderRead);
    id<MTLTexture> out = tex(16, MTLTextureUsageRenderTarget);
    std::vector<uint32_t> red(32 * 32, 0xFFFF0000u); // BGRA8 in memory: b, g, r, a = 0x00, 0x00, 0xFF, 0xFF
    [target replaceRegion:MTLRegionMake2D(0, 0, 32, 32) mipmapLevel:0 withBytes:red.data() bytesPerRow:128];
    id<MTLSharedEvent> gate = [dev newSharedEvent];
    // seq 1: behind the gate, the target cleared green
    be->BeginCmd(GnmCmdTarget::Main, @"behind the gate", false);
    be->QueueWait(gate, 1);
    GnmPassDesc clear;
    clear.color[0] = {target, nil, 0, GnmLoad::Clear, GnmStore::Store};
    clear.clear_color[0] = MTLClearColorMake(0, 1, 0, 1);
    CHECK(be->BeginRender(clear), "clear pass");
    be->EndEncoder();
    be->Commit(1, [](void*, const GnmCompletion&) {}, nullptr);
    // seq 2: the alias copy on the upload target, then a Main pass that samples it
    be->BeginCmd(GnmCmdTarget::Main, @"samples the alias", false);
    be->BeginCmd(GnmCmdTarget::Upload, @"texture uploads", false);
    be->UseTarget(GnmCmdTarget::Upload);
    be->BeginCopies();
    be->CopyTextureRegion(target, 0, 0, MTLOriginMake(0, 0, 0), MTLSizeMake(16, 16, 1), copy, 0, 0, MTLOriginMake(0, 0, 0));
    be->EndEncoder();
    be->UseTarget(GnmCmdTarget::Main);
    GnmPassDesc pd;
    pd.color[0] = {out, nil, 0, GnmLoad::DontCare, GnmStore::Store};
    CHECK(FullscreenPass(*be, pd, util.present, nil, copy), "sampling pass");
    // static: on the timeout path a late completion still finds it
    static struct W {
        dispatch_semaphore_t done = dispatch_semaphore_create(0);
        bool failed = false;
    } w;
    be->Commit(2, [](void* p, const GnmCompletion& c) {
        static_cast<W*>(p)->failed = c.failed;
        dispatch_semaphore_signal(static_cast<W*>(p)->done);
    }, &w);
    usleep(100000); // a copy not ordered behind seq 1 has run by now
    gate.signaledValue = 1;
    const bool done = dispatch_semaphore_wait(w.done, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC)) == 0;
    CHECK(done && !w.failed, "alias copy order: seq 2 failed or hung");
    if (!done) return;
    uint32_t c = 0, o = 0;
    [copy getBytes:&c bytesPerRow:64 fromRegion:MTLRegionMake2D(5, 7, 1, 1) mipmapLevel:0];
    [out getBytes:&o bytesPerRow:64 fromRegion:MTLRegionMake2D(5, 7, 1, 1) mipmapLevel:0];
    CHECK(c == 0xFF00FF00u, "alias copy order (%s): the copy read %08x, want ff00ff00 (the green of seq 1)",
          BackendName(be->Kind()), c);
    CHECK(o == 0xFF00FF00u, "alias copy order (%s): the sampled copy is %08x, want ff00ff00", BackendName(be->Kind()), o);
}

int main() {
    @autoreleasepool {
        id<MTLDevice> dev = MTLCreateSystemDefaultDevice();
        const char* env = getenv("PS4_GNM_METAL");
        if (dev && env && !strcmp(env, "4") && !RequireMetal4(dev, "gnm_backend_copy_test")) return 0;
        std::string why;
        std::unique_ptr<GnmBackend> be = dev ? MakeTestBackend(dev, &why) : nullptr;
        if (!be) {
            printf("gnm_backend_copy_test: FAIL: no backend: %s\n", dev ? why.c_str() : "no Metal device");
            return 1;
        }
        printf("gnm_backend_copy_test: backend %s\n", BackendName(be->Kind()));
        TestAliasCopyOrder(dev);
        Outputs got;
        CHECK(Run(dev, *be, 1, &got), "the seq failed or hung");
        if (be->Kind() == GnmBackendKind::Metal4) {
            std::unique_ptr<GnmBackend> m3 = MakeMetal3Backend();
            CHECK(m3->Init(dev, &why), "Metal 3 backend: %s", why.c_str());
            Outputs ref;
            CHECK(Run(dev, *m3, 1, &ref), "the Metal 3 seq failed or hung");
            CHECK(got.dst == ref.dst, "CopyBuffer output differs from Metal 3");
            CHECK(got.fill == ref.fill, "FillBuffer output differs from Metal 3");
            CHECK(got.big_tail == ref.big_tail, "the dependent buffer copy differs from Metal 3");
            CHECK(got.dep_tex == ref.dep_tex, "the dependent region copy differs from Metal 3");
            const char* names[5] = {"buffer -> texture array", "texture region", "whole texture", "upload copy",
                                    "buffer -> 3D texture"};
            for (size_t i = 0; i < 5 && i < got.tex.size() && i < ref.tex.size(); ++i)
                CHECK(got.tex[i] == ref.tex[i], "%s output differs from Metal 3", names[i]);
            TestMixedEncoder(dev, *be, 2);
        }
    }
    printf("gnm_backend_copy_test: %s\n", g_fail ? "FAIL" : "PASS");
    return g_fail ? 1 : 0;
}
