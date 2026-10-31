// A clear presented and read back on the backend PS4_GNM_METAL selects (both run it), as the
// renderer presents: a clear of a game target, the present conversion (FullscreenPass with the
// utility present pipeline, ps4_gnm_util_passes.h) into a slot texture, the
// copy into a second slot (the presenter's copy when the frame is not an acquired slot), and the
// ready signal after the work. ready must not be signalled while the work it follows is not
// committed yet (a signal issued at once would be), and the slot copy is read as soon as ready is
// seen, before the seq's completion: it holds the clear colour on both backends.
// Then the other render bindings of a draw: vertex and fragment BindBytes (more than one bytes
// chunk of them on Metal 4, so the arena moves to a new chunk inside the seq), a fragment
// BindBuffer and a BindBufferOffset between two draws of one pass; each half of the target holds
// the sum its draw's bindings name.
// A sampled full-screen pass of the game target (render bindings of a texture and a sampler) into
// a third texture checks the sampler binding the present pipeline does not use.
// Last, bytes-arena chunks are not reused before their seq completed (Metal 4): a gated seq's draw
// reads its constant from a chunk that the next seq's binds would overwrite if it were freed early.
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>

#include <unistd.h>

#include <atomic>
#include <thread>
#include <vector>

#include "backend_harness.h"
#include "ps4_gnm_util_passes.h"

using namespace ps4gnm;

namespace ps4gnm {
id<MTLTexture> PresentTextureView(id<MTLTexture> src, uint32_t pixel_format);
}

// A compute shader may write display bytes through a uint storage image. VideoOut
// interprets those bytes as BGRA UNORM, regardless of the shader's image type.
static void TestUintDisplay(id<MTLDevice> dev, GnmBackend& be) {
    const uint8_t bytes[] = {192, 128, 64, 255, 8, 32, 240, 255};
    MTLTextureDescriptor* td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Uint
                                                                               width:2 height:1 mipmapped:NO];
    td.usage = MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite | MTLTextureUsagePixelFormatView;
    td.storageMode = MTLStorageModeShared;
    id<MTLTexture> src = [dev newTextureWithDescriptor:td];
    [src replaceRegion:MTLRegionMake2D(0, 0, 2, 1) mipmapLevel:0 withBytes:bytes bytesPerRow:8];
    id<MTLTexture> view = PresentTextureView(src, 0x80000000);
    CHECK(view && view.pixelFormat == MTLPixelFormatBGRA8Unorm, "uint display must be viewed as normalized BGRA");
    td.pixelFormat = MTLPixelFormatBGRA8Unorm;
    td.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
    id<MTLTexture> dst = [dev newTextureWithDescriptor:td];
    be.MakeResident(src, GnmResidencyClass::Texture);
    be.MakeResident(dst, GnmResidencyClass::Texture);
    GnmUtil util;
    std::string why;
    CHECK(MakeGnmUtil(dev, &util, &why), "present utility: %s", why.c_str());
    be.BeginCmd(GnmCmdTarget::Main, @"uint display", false);
    GnmPassDesc pd;
    pd.color[0] = {dst, nil, 0, GnmLoad::DontCare, GnmStore::Store};
    CHECK(FullscreenPass(be, pd, util.present, nil, view), "uint display pass");
    CHECK(CommitAndWait(be, 100), "uint display GPU completion");
    uint8_t got[8] = {};
    [dst getBytes:got bytesPerRow:8 fromRegion:MTLRegionMake2D(0, 0, 2, 1) mipmapLevel:0];
    CHECK(memcmp(bytes, got, 8) == 0, "uint display must preserve encoded BGRA bytes (got %u %u %u %u)",
          got[0], got[1], got[2], got[3]);
}

static const char* kShaders = R"(
#include <metal_stdlib>
using namespace metal;
struct V { float4 pos [[position]]; float2 uv; };
// a quad (triangle strip of 4) covering k.xy-scaled, k.zw-offset clip space
static V Quad(uint vid, float4 k) {
    const float2 p = float2(vid & 1, vid >> 1);
    V o;
    o.pos = float4((p * 2 - 1) * k.xy + k.zw, 0, 1);
    o.uv = float2(p.x, 1 - p.y);
    return o;
}
vertex V vs_full(uint vid [[vertex_id]]) { return Quad(vid, float4(1, 1, 0, 0)); }
vertex V vs_placed(uint vid [[vertex_id]], constant float4& k [[buffer(0)]]) { return Quad(vid, k); }
fragment float4 fs_sample(V in [[stage_in]], texture2d<float> t [[texture(0)]], sampler s [[sampler(0)]]) {
    return t.sample(s, in.uv);
}
fragment float4 fs_sum(V in [[stage_in]], constant float4& c [[buffer(0)]], device const float4* b [[buffer(1)]]) {
    return c + b[0];
}
)";

static id<MTLTexture> Tex(id<MTLDevice> dev, GnmBackend& be, MTLPixelFormat f, uint32_t w, uint32_t h, MTLStorageMode m) {
    MTLTextureDescriptor* td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:f width:w height:h mipmapped:NO];
    td.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
    td.storageMode = m;
    id<MTLTexture> t = [dev newTextureWithDescriptor:td];
    be.MakeResident(t, GnmResidencyClass::Texture);
    return t;
}

static id<MTLRenderPipelineState> Pipeline(id<MTLDevice> dev, id<MTLLibrary> lib, NSString* vs, NSString* fs,
                                           MTLPixelFormat f) {
    MTLRenderPipelineDescriptor* d = [MTLRenderPipelineDescriptor new];
    d.vertexFunction = [lib newFunctionWithName:vs];
    d.fragmentFunction = [lib newFunctionWithName:fs];
    d.colorAttachments[0].pixelFormat = f;
    NSError* err = nil;
    id<MTLRenderPipelineState> p = [dev newRenderPipelineStateWithDescriptor:d error:&err];
    CHECK(p != nil, "pipeline %s/%s: %s", vs.UTF8String, fs.UTF8String, err.localizedDescription.UTF8String);
    return p;
}

// Bytes of a BGRA8 / RGBA8 texture that differ from want (4 bytes per pixel) in columns [x0, x1).
static size_t BadPixels(id<MTLTexture> t, uint32_t x0, uint32_t x1, const uint8_t want[4], uint8_t first[4]) {
    const uint32_t w = (uint32_t)t.width, h = (uint32_t)t.height;
    std::vector<uint8_t> px((size_t)w * h * 4);
    [t getBytes:px.data() bytesPerRow:w * 4 fromRegion:MTLRegionMake2D(0, 0, w, h) mipmapLevel:0];
    size_t bad = 0;
    bool got = false;
    for (uint32_t y = 0; y < h; ++y)
        for (uint32_t x = x0; x < x1; ++x) {
            const uint8_t* p = &px[((size_t)y * w + x) * 4];
            if (memcmp(p, want, 4) == 0) continue;
            if (!got) memcpy(first, p, 4), got = true;
            ++bad;
        }
    return bad;
}

// Completions counted in static storage: a late one of a failed run never writes to a dead frame.
static std::atomic<int> g_done{0};
static void CountDone(void*, const GnmCompletion& c) {
    if (!c.failed) g_done.fetch_add(1);
}

// Opens gate (value 1) 50 ms from now, on another thread.
static std::thread OpenLater(id<MTLSharedEvent> gate) {
    return std::thread([gate] {
        usleep(50000);
        gate.signaledValue = 1;
    });
}

static void TestPresent(id<MTLDevice> dev, GnmBackend& be, id<MTLLibrary> lib) {
    GnmUtil util;
    std::string why;
    CHECK(MakeGnmUtil(dev, &util, &why) && util.present, "utility pipelines: %s", why.c_str());
    id<MTLRenderPipelineState> sampled_pso = Pipeline(dev, lib, @"vs_full", @"fs_sample", MTLPixelFormatBGRA8Unorm);
    MTLSamplerDescriptor* sd = [MTLSamplerDescriptor new];
    sd.minFilter = sd.magFilter = MTLSamplerMinMagFilterNearest;
    sd.supportArgumentBuffers = YES; // what gpuResourceID needs (the renderer's samplers set it too)
    id<MTLSamplerState> smp = [dev newSamplerStateWithDescriptor:sd];
    id<MTLTexture> game = Tex(dev, be, MTLPixelFormatBGRA8Unorm, 64, 32, MTLStorageModePrivate);
    id<MTLTexture> slot = Tex(dev, be, MTLPixelFormatBGRA8Unorm, 64, 32, MTLStorageModeShared);
    id<MTLTexture> slot2 = Tex(dev, be, MTLPixelFormatBGRA8Unorm, 64, 32, MTLStorageModeShared);
    id<MTLTexture> sampled = Tex(dev, be, MTLPixelFormatBGRA8Unorm, 64, 32, MTLStorageModeShared);
    id<MTLSharedEvent> ready = [dev newSharedEvent];
    std::vector<uint8_t> old(64 * 32 * 4, 0x11); // what slot2 holds before the copy
    [slot2 replaceRegion:MTLRegionMake2D(0, 0, 64, 32) mipmapLevel:0 withBytes:old.data() bytesPerRow:64 * 4];
    if (!util.present || !sampled_pso) return;
    be.BeginCmd(GnmCmdTarget::Main, @"present test", false);
    GnmPassDesc clear;
    clear.color[0].tex = game;
    clear.color[0].load = GnmLoad::Clear;
    clear.clear_color[0] = MTLClearColorMake(64.0 / 255, 128.0 / 255, 192.0 / 255, 1); // r, g, b, a
    CHECK(be.BeginRender(clear), "clear pass");
    be.EndEncoder();
    GnmPassDesc conv;
    conv.color[0].tex = slot;
    conv.color[0].load = GnmLoad::DontCare;
    conv.label = @"present conversion";
    CHECK(FullscreenPass(be, conv, util.present, nil, game), "present conversion pass");
    GnmPassDesc sp;
    sp.color[0].tex = sampled;
    sp.color[0].load = GnmLoad::DontCare;
    CHECK(be.BeginRender(sp), "sampled pass");
    be.SetRenderPipeline(sampled_pso);
    be.BindTexture(GnmStage::Fragment, 0, game);
    be.BindSampler(GnmStage::Fragment, 0, smp);
    GnmDraw quad;
    quad.prim = MTLPrimitiveTypeTriangleStrip;
    quad.count = 4;
    be.Draw(quad);
    be.EndEncoder();
    be.BeginCopies();
    be.CopyTexture(slot, slot2);
    be.EndEncoder();
    be.QueueSignal(ready, 1);
    usleep(50000);
    CHECK(ready.signaledValue == 0, "ready signalled before the work it follows was committed");
    const uint64_t seq = 1;
    g_done = 0;
    be.Commit(seq, CountDone, nullptr);
    const uint8_t want[4] = {192, 128, 64, 255}; // BGRA in memory
    CHECK([ready waitUntilSignaledValue:1 timeoutMS:2000], "ready not signalled");
    {
        uint8_t first[4] = {};
        const size_t bad = BadPixels(slot2, 0, 64, want, first); // at the signal, before the seq's completion
        CHECK(bad == 0, "slot copy at the ready signal: %zu of 2048 pixels are not the clear colour (first %u %u %u %u)",
              bad, first[0], first[1], first[2], first[3]);
    }
    for (int i = 0; i < 200 && g_done.load() == 0; ++i) usleep(10000);
    CHECK(g_done.load() == 1, "the present seq failed or hung");
    for (id<MTLTexture> t : {slot, slot2, sampled}) {
        uint8_t first[4] = {};
        const size_t bad = BadPixels(t, 0, 64, want, first);
        CHECK(bad == 0, "%s: %zu of 2048 pixels are not the clear colour (first %u %u %u %u)",
              t == slot ? "slot" : t == slot2 ? "slot copy" : "sampled pass", bad, first[0], first[1], first[2], first[3]);
    }
}

static void TestBindings(id<MTLDevice> dev, GnmBackend& be, id<MTLLibrary> lib) {
    id<MTLRenderPipelineState> pso = Pipeline(dev, lib, @"vs_placed", @"fs_sum", MTLPixelFormatRGBA8Unorm);
    id<MTLTexture> t = Tex(dev, be, MTLPixelFormatRGBA8Unorm, 8, 4, MTLStorageModeShared);
    id<MTLBuffer> buf = [dev newBufferWithLength:256 options:MTLResourceStorageModeShared];
    be.MakeResident(buf, GnmResidencyClass::Guest);
    float* v = (float*)buf.contents;
    const float b0[4] = {0, 128.0f / 255, 0, 0}, b1[4] = {0, 0, 192.0f / 255, 0}; // at offsets 0 and 16
    memcpy(v, b0, 16);
    memcpy(v + 4, b1, 16);
    if (!pso) return;
    be.BeginCmd(GnmCmdTarget::Main, @"bindings test", false);
    GnmPassDesc pd;
    pd.color[0].tex = t;
    pd.color[0].load = GnmLoad::Clear;
    pd.clear_color[0] = MTLClearColorMake(0, 0, 0, 0);
    CHECK(be.BeginRender(pd), "bindings pass");
    be.SetRenderPipeline(pso);
    // 1100 earlier binds of 16 bytes: on Metal 4 at 256-byte steps, past one 256 KiB chunk
    const float junk[4] = {1, 1, 1, 1};
    for (int i = 0; i < 1100; ++i) be.BindBytes(GnmStage::Fragment, 0, junk, sizeof(junk));
    const float c[4] = {64.0f / 255, 0, 0, 1};
    const float left[4] = {0.5f, 1, -0.5f, 0}, right[4] = {0.5f, 1, 0.5f, 0};
    be.BindBytes(GnmStage::Fragment, 0, c, sizeof(c));
    be.BindBuffer(GnmStage::Fragment, 1, buf, 0);
    be.BindBytes(GnmStage::Vertex, 0, left, sizeof(left));
    GnmDraw quad;
    quad.prim = MTLPrimitiveTypeTriangleStrip;
    quad.count = 4;
    be.Draw(quad);
    be.BindBufferOffset(GnmStage::Fragment, 1, 16);
    be.BindBytes(GnmStage::Vertex, 0, right, sizeof(right));
    be.Draw(quad);
    be.EndEncoder();
    CHECK(CommitAndWait(be, 2), "the bindings seq failed or hung");
    const uint8_t want_l[4] = {64, 128, 0, 255}, want_r[4] = {64, 0, 192, 255}; // RGBA in memory
    uint8_t first[4] = {};
    size_t bad = BadPixels(t, 0, 4, want_l, first);
    CHECK(bad == 0, "left half (bytes + buffer at offset 0): %zu of 16 pixels wrong (first %u %u %u %u)", bad, first[0],
          first[1], first[2], first[3]);
    bad = BadPixels(t, 4, 8, want_r, first);
    CHECK(bad == 0, "right half (bytes + buffer at offset 16): %zu of 16 pixels wrong (first %u %u %u %u)", bad, first[0],
          first[1], first[2], first[3]);
}

// Seq A waits for a gate, then binds two chunks of bytes after its draw's constant; seq B, recorded
// while A is still held, binds two more chunks of other values. If A's chunks were reused for B
// before A completed, A's draw would read B's bytes.
static void TestArenaReuse(id<MTLDevice> dev, GnmBackend& be, id<MTLLibrary> lib, uint64_t seq_a) {
    id<MTLRenderPipelineState> pso = Pipeline(dev, lib, @"vs_placed", @"fs_sum", MTLPixelFormatRGBA8Unorm);
    id<MTLTexture> ta = Tex(dev, be, MTLPixelFormatRGBA8Unorm, 4, 4, MTLStorageModeShared);
    id<MTLTexture> tb = Tex(dev, be, MTLPixelFormatRGBA8Unorm, 4, 4, MTLStorageModeShared);
    id<MTLBuffer> zero = [dev newBufferWithLength:256 options:MTLResourceStorageModeShared];
    memset(zero.contents, 0, 256);
    be.MakeResident(zero, GnmResidencyClass::Guest);
    id<MTLSharedEvent> gate = [dev newSharedEvent];
    if (!pso) return;
    const float full[4] = {1, 1, 0, 0};
    const float ca[4] = {64.0f / 255, 128.0f / 255, 0, 1}, cb[4] = {0, 0, 192.0f / 255, 1};
    GnmDraw quad;
    quad.prim = MTLPrimitiveTypeTriangleStrip;
    quad.count = 4;
    auto pass = [&](id<MTLTexture> t, const float* c, int binds_after) {
        GnmPassDesc pd;
        pd.color[0].tex = t;
        pd.color[0].load = GnmLoad::Clear;
        CHECK(be.BeginRender(pd), "arena pass");
        be.SetRenderPipeline(pso);
        be.BindBytes(GnmStage::Fragment, 0, c, 16);
        be.BindBuffer(GnmStage::Fragment, 1, zero, 0);
        be.BindBytes(GnmStage::Vertex, 0, full, sizeof(full));
        be.Draw(quad);
        for (int i = 0; i < binds_after; ++i) be.BindBytes(GnmStage::Fragment, 0, c, 16); // filled with the same value
        be.EndEncoder();
    };
    g_done = 0;
    be.BeginCmd(GnmCmdTarget::Main, @"arena A (gated)", false);
    be.QueueWait(gate, 1);
    pass(ta, ca, 2100); // about two 256 KiB chunks after the draw's constant
    be.Commit(seq_a, CountDone, nullptr);
    be.BeginCmd(GnmCmdTarget::Main, @"arena B", false);
    pass(tb, cb, 2100);
    be.Commit(seq_a + 1, CountDone, nullptr);
    std::thread opener = OpenLater(gate);
    opener.join();
    for (int i = 0; i < 300 && g_done.load() < 2; ++i) usleep(10000);
    CHECK(g_done.load() == 2, "%d of the 2 arena seqs completed", g_done.load());
    const uint8_t want_a[4] = {64, 128, 0, 255}, want_b[4] = {0, 0, 192, 255};
    uint8_t first[4] = {};
    size_t bad = BadPixels(ta, 0, 4, want_a, first);
    CHECK(bad == 0, "seq A's draw read other bytes: %zu of 16 pixels wrong (first %u %u %u %u; B's value is 0 0 192 255)",
          bad, first[0], first[1], first[2], first[3]);
    bad = BadPixels(tb, 0, 4, want_b, first);
    CHECK(bad == 0, "seq B: %zu of 16 pixels wrong (first %u %u %u %u)", bad, first[0], first[1], first[2], first[3]);
}

int main() {
    @autoreleasepool {
        id<MTLDevice> dev = MTLCreateSystemDefaultDevice();
        const char* env = getenv("PS4_GNM_METAL");
        if (dev && env && !strcmp(env, "4") && !RequireMetal4(dev, "gnm_backend_present_test")) return 0;
        std::string why;
        std::unique_ptr<GnmBackend> be = dev ? MakeTestBackend(dev, &why) : nullptr;
        if (!be) {
            printf("gnm_backend_present_test: FAIL: no backend: %s\n", dev ? why.c_str() : "no Metal device");
            return 1;
        }
        printf("gnm_backend_present_test: backend %s\n", BackendName(be->Kind()));
        NSError* err = nil;
        id<MTLLibrary> lib = [dev newLibraryWithSource:@(kShaders) options:nil error:&err];
        if (!lib) {
            printf("gnm_backend_present_test: FAIL: shaders: %s\n", err.localizedDescription.UTF8String);
            return 1;
        }
        TestPresent(dev, *be, lib);
        TestBindings(dev, *be, lib);
        TestArenaReuse(dev, *be, lib, 3);
        TestUintDisplay(dev, *be);
    }
    printf("gnm_backend_present_test: %s\n", g_fail ? "FAIL" : "PASS");
    return g_fail ? 1 : 0;
}
