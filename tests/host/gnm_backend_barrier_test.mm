// Barrier coverage (docs/metal4-backend.md, "Synchronisation"): a render pass that samples a
// texture a compute pass just wrote, in one seq, sees every texel the compute pass wrote, on the
// backend PS4_GNM_METAL selects (Metal 3 orders the two encoders by its hazard tracking, Metal 4
// by the barrier at the render encoder's start). The compute pass is slow on purpose (a long
// dependent loop per texel), so an unordered render pass would read texels not written yet. The
// teeth: on Metal 4 with PS4_GNM_MTL4_NO_BARRIERS=1 at least one of 8 tries must read wrong texels.
// The render pass is the renderer's FullscreenPass (ps4_gnm_util_passes.h) with this test's
// pipeline (an R32Uint read of the compute pass's texture).
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>

#include <algorithm>
#include <vector>

#include "backend_harness.h"
#include "ps4_gnm_util_passes.h"

using namespace ps4gnm;

static const char* kMsl = R"(
#include <metal_stdlib>
using namespace metal;
kernel void slow_write(texture2d<uint, access::write> out [[texture(0)]], constant uint& n [[buffer(0)]],
                       uint2 p [[thread_position_in_grid]]) {
    uint v = p.x * 131u + p.y;
    for (uint i = 0; i < n; ++i) v = v * 1664525u + 1013904223u;
    out.write(uint4(v, 0, 0, 0), p);
}
struct VOut { float4 pos [[position]]; };
vertex VOut tri_vs(uint vid [[vertex_id]]) {
    VOut o;
    float2 uv = float2((vid << 1) & 2, vid & 2);
    o.pos = float4(uv * 2.0 - 1.0, 0.0, 1.0);
    return o;
}
fragment uint4 sample_fs(VOut in [[stage_in]], texture2d<uint> src [[texture(0)]]) {
    return uint4(src.read(uint2(in.pos.xy)).r, 0, 0, 1);
}
)";

constexpr uint32_t kW = 128, kH = 128, kLoop = 200000;

static uint32_t Expected(uint32_t x, uint32_t y) {
    uint32_t v = x * 131u + y;
    for (uint32_t i = 0; i < kLoop; ++i) v = v * 1664525u + 1013904223u;
    return v;
}

// One seq: compute writes `tex`, the render pass copies it into `rt`; returns the wrong texels of rt.
static uint32_t RunOnce(GnmBackend& be, id<MTLComputePipelineState> cs, id<MTLRenderPipelineState> rs, id<MTLTexture> tex,
                        id<MTLTexture> rt, const std::vector<uint32_t>& want, uint64_t seq) {
    std::vector<uint32_t> zero(kW * kH, 0);
    [tex replaceRegion:MTLRegionMake2D(0, 0, kW, kH) mipmapLevel:0 withBytes:zero.data() bytesPerRow:kW * 4];
    [rt replaceRegion:MTLRegionMake2D(0, 0, kW, kH) mipmapLevel:0 withBytes:zero.data() bytesPerRow:kW * 4];
    const uint32_t n = kLoop;
    be.BeginCmd(GnmCmdTarget::Main, @"barrier", false);
    be.BeginCompute(false);
    be.SetComputePipeline(cs);
    be.BindTexture(GnmStage::Compute, 0, tex);
    be.BindBytes(GnmStage::Compute, 0, &n, sizeof(n));
    be.Dispatch(MTLSizeMake(kW / 8, kH / 8, 1), MTLSizeMake(8, 8, 1));
    be.EndEncoder();
    GnmPassDesc pd;
    pd.color[0].tex = rt;
    pd.color[0].load = GnmLoad::DontCare;
    if (!FullscreenPass(be, pd, rs, nil, tex)) return kW * kH;
    if (!CommitAndWait(be, seq)) return kW * kH;
    std::vector<uint32_t> got(kW * kH);
    [rt getBytes:got.data() bytesPerRow:kW * 4 fromRegion:MTLRegionMake2D(0, 0, kW, kH) mipmapLevel:0];
    uint32_t bad = 0;
    for (size_t i = 0; i < got.size(); ++i) bad += got[i] != want[i];
    return bad;
}

static bool Build(id<MTLDevice> dev, id<MTLComputePipelineState>* cs, id<MTLRenderPipelineState>* rs) {
    NSError* e = nil;
    id<MTLLibrary> lib = [dev newLibraryWithSource:[NSString stringWithUTF8String:kMsl] options:nil error:&e];
    if (!lib) return false;
    *cs = [dev newComputePipelineStateWithFunction:[lib newFunctionWithName:@"slow_write"] error:&e];
    MTLRenderPipelineDescriptor* d = [MTLRenderPipelineDescriptor new];
    d.vertexFunction = [lib newFunctionWithName:@"tri_vs"];
    d.fragmentFunction = [lib newFunctionWithName:@"sample_fs"];
    d.colorAttachments[0].pixelFormat = MTLPixelFormatR32Uint;
    *rs = [dev newRenderPipelineStateWithDescriptor:d error:&e];
    return *cs && *rs;
}

static id<MTLTexture> Tex(id<MTLDevice> dev, GnmBackend& be, MTLTextureUsage u) {
    MTLTextureDescriptor* td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatR32Uint width:kW
                                                                                 height:kH mipmapped:NO];
    td.usage = u;
    td.storageMode = MTLStorageModeShared;
    id<MTLTexture> t = [dev newTextureWithDescriptor:td];
    be.MakeResident(t, GnmResidencyClass::Texture);
    return t;
}

int main() {
    @autoreleasepool {
        id<MTLDevice> dev = MTLCreateSystemDefaultDevice();
        const char* env = getenv("PS4_GNM_METAL");
        if (dev && env && !strcmp(env, "4") && !RequireMetal4(dev, "gnm_backend_barrier_test")) return 0;
        std::string why;
        std::unique_ptr<GnmBackend> be = dev ? MakeTestBackend(dev, &why) : nullptr;
        id<MTLComputePipelineState> cs = nil;
        id<MTLRenderPipelineState> rs = nil;
        if (!be || !Build(dev, &cs, &rs)) {
            printf("gnm_backend_barrier_test: FAIL: %s\n", be ? "pipelines" : why.c_str());
            return 1;
        }
        printf("gnm_backend_barrier_test: backend %s\n", BackendName(be->Kind()));
        std::vector<uint32_t> want(kW * kH);
        for (uint32_t y = 0; y < kH; ++y)
            for (uint32_t x = 0; x < kW; ++x) want[y * kW + x] = Expected(x, y);
        id<MTLTexture> tex = Tex(dev, *be, MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite);
        id<MTLTexture> rt = Tex(dev, *be, MTLTextureUsageRenderTarget);
        uint64_t seq = 0;
        for (int i = 0; i < 4; ++i) {
            const uint32_t bad = RunOnce(*be, cs, rs, tex, rt, want, ++seq);
            CHECK(bad == 0, "try %d: %u of %u texels wrong: the render pass ran before the compute pass's writes", i, bad,
                  kW * kH);
        }
        if (be->Kind() == GnmBackendKind::Metal4) {
            setenv("PS4_GNM_MTL4_NO_BARRIERS", "1", 1);
            std::unique_ptr<GnmBackend> nb = MakeTestBackend(dev, &why);
            unsetenv("PS4_GNM_MTL4_NO_BARRIERS");
            CHECK(nb != nullptr, "no-barrier backend: %s", why.c_str());
            if (nb) {
                id<MTLTexture> tex2 = Tex(dev, *nb, MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite);
                id<MTLTexture> rt2 = Tex(dev, *nb, MTLTextureUsageRenderTarget);
                uint32_t worst = 0;
                int tries = 0;
                uint64_t s2 = 0;
                for (; tries < 8 && worst == 0; ++tries) worst = std::max(worst, RunOnce(*nb, cs, rs, tex2, rt2, want, ++s2));
                CHECK(worst > 0, "without encoder barriers every try was right: the test cannot see a missing barrier "
                                 "(make the compute pass slower: kLoop)");
                printf("gnm_backend_barrier_test: without encoder barriers try %d read %u of %u texels wrong (the teeth)\n",
                       tries, worst, kW * kH);
            }
        }
    }
    printf("gnm_backend_barrier_test: %s\n", g_fail ? "FAIL" : "PASS");
    return g_fail ? 1 : 0;
}
