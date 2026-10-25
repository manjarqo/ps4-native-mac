// GnmResidency (ps4_gnm_residency.h): allocations stay in their set until the seq of their
// removal completed; a removal is cancelled by an Add before it completes; the set keeps a
// strong reference (an allocation released by its owner while in a set stays alive, and is freed
// once retired); texture views count as their parent, and as themselves when added on their own;
// removals retire in seq order and a second removal keeps the later seq; misuse aborts (an Add
// with another class, Add/Remove before Init; run in a child process); concurrent use from three
// threads; on Metal 4, GPU writes into a no-copy window land when it is in a set and are lost
// without one (the negative control). Task 5.1 adds the bind-time check.
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>

#include <mach-o/dyld.h>
#include <signal.h>
#include <spawn.h>
#include <stdio.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/wait.h>
#include <unistd.h>

#include <atomic>
#include <string>
#include <thread>
#include <vector>

#include "backend_harness.h"
#include "ps4_gnm_backend_metal4.h"
#include "ps4_gnm_residency.h"
#include "ps4_gnm_util_passes.h"

using namespace ps4gnm;

static void TestSetLogic(id<MTLDevice> dev) {
    GnmResidency r;
    std::string why;
    CHECK(r.Init(dev, &why), "Init: %s", why.c_str());
    id<MTLBuffer> a = [dev newBufferWithLength:65536 options:MTLResourceStorageModeShared];
    id<MTLBuffer> b = [dev newBufferWithLength:65536 options:MTLResourceStorageModeShared];
    MTLTextureDescriptor* td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm
                                                                                  width:64 height:64 mipmapped:NO];
    td.usage = MTLTextureUsageShaderRead | MTLTextureUsagePixelFormatView;
    id<MTLTexture> t = [dev newTextureWithDescriptor:td];
    r.Add(a, GnmResidencyClass::Guest);
    r.Add(b, GnmResidencyClass::Builtin);
    r.Add(t, GnmResidencyClass::Texture);
    r.Commit();
    CHECK(r.Count() == 3 && r.PendingCount() == 0, "count %zu pending %zu", r.Count(), r.PendingCount());
    CHECK(r.Count(GnmResidencyClass::Texture) == 1 && r.Count(GnmResidencyClass::Guest) == 1 &&
              r.Count(GnmResidencyClass::Builtin) == 1,
          "per-class counts %zu %zu %zu, want 1 each", r.Count(GnmResidencyClass::Texture),
          r.Count(GnmResidencyClass::Guest), r.Count(GnmResidencyClass::Builtin));
    CHECK(r.Contains(a) && r.Contains(b) && r.Contains(t), "added allocations not contained");
    CHECK([r.Set(GnmResidencyClass::Guest) containsAllocation:a] && ![r.Set(GnmResidencyClass::Guest) containsAllocation:b],
          "an allocation is in its class's set only");
    CHECK(r.AllocatedSize() > 0, "allocatedSize 0 after commit");
    id<MTLTexture> view = [t newTextureViewWithPixelFormat:MTLPixelFormatRGBA8Unorm_sRGB];
    CHECK(r.Contains(view), "a view of a resident texture counts as resident");
    // deferred removal
    r.Remove(a, 5);
    CHECK(r.Contains(a) && r.PendingCount() == 1, "removed before its seq completed");
    r.Retire(4);
    CHECK(r.Contains(a), "retired at seq 4 for a removal after seq 5");
    r.Retire(5);
    CHECK(!r.Contains(a) && r.Count() == 2, "not retired at seq 5 (count %zu)", r.Count());
    r.Commit();
    CHECK(![r.Set(GnmResidencyClass::Guest) containsAllocation:a], "still in the Metal set after retire + commit");
    // a removal cancelled by an Add before it completed
    r.Remove(b, 8);
    r.Add(b, GnmResidencyClass::Builtin);
    r.Retire(9);
    CHECK(r.Contains(b) && r.PendingCount() == 0, "re-added allocation removed by its old removal");
    r.Remove(id<MTLBuffer>([dev newBufferWithLength:16 options:0]), 1); // unknown: ignored
    CHECK(r.Count() == 2, "unknown removal changed the count");
}

// The strong reference: an allocation whose owner let it go stays alive while in a set and is
// freed when it is retired.
static void TestStrongReference(id<MTLDevice> dev) {
    GnmResidency r;
    std::string why;
    r.Init(dev, &why);
    __weak id<MTLBuffer> weak = nil;
    @autoreleasepool {
        id<MTLBuffer> x = [dev newBufferWithLength:4096 options:MTLResourceStorageModeShared];
        weak = x;
        r.Add(x, GnmResidencyClass::Guest);
        r.Remove(x, 1);
    }
    CHECK(weak != nil, "an allocation waiting for its removal was freed");
    @autoreleasepool {
        r.Retire(1);
        CHECK(r.Count() == 0, "retired allocation still counted before the commit (count %zu)", r.Count());
        r.Commit();
    }
    CHECK(weak == nil, "a retired allocation is still alive (the set holds it)");
}

// A view added on its own (its parent is in no set) is contained, and leaves with its own removal.
static void TestViewOwnEntry(id<MTLDevice> dev) {
    GnmResidency r;
    std::string why;
    r.Init(dev, &why);
    MTLTextureDescriptor* td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm
                                                                                  width:16 height:16 mipmapped:NO];
    td.usage = MTLTextureUsageShaderRead | MTLTextureUsagePixelFormatView;
    id<MTLTexture> t = [dev newTextureWithDescriptor:td];
    id<MTLTexture> view = [t newTextureViewWithPixelFormat:MTLPixelFormatRGBA8Unorm_sRGB];
    r.Add(view, GnmResidencyClass::Texture);
    CHECK(r.Contains(view), "a view added on its own is not contained");
    CHECK(!r.Contains(t), "the parent of a view added on its own counts as contained");
    r.Remove(view, 1);
    r.Retire(1);
    CHECK(!r.Contains(view) && r.Count() == 0, "a view's own removal did not retire it");
}

// Removals retire in seq order, not in call order; a second removal keeps the later seq.
static void TestRemovalOrder(id<MTLDevice> dev) {
    GnmResidency r;
    std::string why;
    r.Init(dev, &why);
    id<MTLBuffer> a = [dev newBufferWithLength:4096 options:0];
    id<MTLBuffer> b = [dev newBufferWithLength:4096 options:0];
    id<MTLBuffer> c = [dev newBufferWithLength:4096 options:0];
    r.Add(b, GnmResidencyClass::Guest);
    r.Add(c, GnmResidencyClass::Guest);
    r.Remove(b, 8);
    r.Remove(c, 4);
    r.Retire(5);
    CHECK(!r.Contains(c), "a removal after seq 4 waits behind one after seq 8 (Retire(5))");
    CHECK(r.Contains(b), "removed after seq 8 at Retire(5)");
    r.Retire(8);
    CHECK(!r.Contains(b), "not removed at Retire(8)");
    // twice, the later seq first: the earlier seq must not remove it
    r.Add(a, GnmResidencyClass::Guest);
    r.Remove(a, 12);
    r.Remove(a, 10);
    r.Retire(10);
    CHECK(r.Contains(a), "a second removal (seq 10) cut short the first (seq 12)");
    r.Retire(12);
    CHECK(!r.Contains(a), "not removed at Retire(12)");
    // twice, the earlier seq first
    r.Add(a, GnmResidencyClass::Guest);
    r.Remove(a, 14);
    r.Remove(a, 16);
    r.Retire(15);
    CHECK(r.Contains(a), "removed at Retire(15) after a second removal after seq 16");
    r.Retire(16);
    CHECK(!r.Contains(a) && r.Count() == 0 && r.PendingCount() == 0, "count %zu pending %zu after the last retire",
          r.Count(), r.PendingCount());
    r.Retire(0);
    CHECK(r.Count() == 0, "Retire(0) changed the count");
}

// Three threads: two add, query and remove their own buffers with growing seqs while the third
// retires and commits. Every buffer is gone after the last retire.
static void TestConcurrency(id<MTLDevice> dev) {
    GnmResidency r;
    std::string why;
    r.Init(dev, &why);
    constexpr int kN = 256, kRounds = 20;
    std::vector<id<MTLBuffer>> bufs[2];
    for (auto& v : bufs)
        for (int i = 0; i < kN; ++i) v.push_back([dev newBufferWithLength:256 options:0]);
    std::atomic<uint64_t> seq{0};
    std::atomic<int> missing{0}, running{2};
    auto worker = [&](int w) {
        for (int round = 0; round < kRounds; ++round)
            for (int i = 0; i < kN; ++i) {
                id<MTLBuffer> b = bufs[w][i];
                r.Add(b, w ? GnmResidencyClass::Guest : GnmResidencyClass::Texture);
                if (!r.Contains(b)) missing.fetch_add(1);
                r.Remove(b, seq.load() + 1);
            }
        running.fetch_sub(1);
    };
    std::thread t0(worker, 0), t1(worker, 1);
    while (running.load()) {
        r.Retire(seq.fetch_add(1) + 1);
        r.Commit();
    }
    t0.join();
    t1.join();
    r.Retire(seq.load() + 1);
    r.Commit();
    CHECK(missing.load() == 0, "%d added buffers not contained right after their Add", missing.load());
    CHECK(r.Count() == 0 && r.PendingCount() == 0, "count %zu pending %zu after the last retire", r.Count(),
          r.PendingCount());
}

// GPU writes into a no-copy buffer over host memory (as a guest memory window) by a Metal 4
// dispatch: they land when the buffer is in a residency set (positive), and are lost without an
// error when it is in none (the negative control, probe P4: the reason every window, arena chunk
// and built-in buffer must be added; if Metal ever reports this or makes the buffer resident by
// itself, this check fails and the residency rules must be revisited). The constant comes from
// BindBytes (the bytes arena, itself resident).
static const char* kWriteMsl = R"(
#include <metal_stdlib>
using namespace metal;
kernel void fill(device uint* out [[buffer(0)]], constant uint& k [[buffer(1)]], uint i [[thread_position_in_grid]]) {
    out[i] = i * 3u + k;
}
kernel void copy(device const uint* src [[buffer(0)]], device uint* dst [[buffer(1)]], uint i [[thread_position_in_grid]]) {
    dst[i] = src[i];
}
)";

static bool RunFill(Metal4Backend& be, id<MTLComputePipelineState> pso, id<MTLBuffer> buf, uint64_t seq) {
    const uint32_t k = 7;
    be.BeginCmd(GnmCmdTarget::Main, @"residency", false);
    be.BeginCompute(false);
    be.SetComputePipeline(pso);
    be.BindBuffer(GnmStage::Compute, 0, buf, 0);
    be.BindBytes(GnmStage::Compute, 1, &k, sizeof(k));
    be.Dispatch(MTLSizeMake(64, 1, 1), MTLSizeMake(64, 1, 1));
    be.EndEncoder();
    return CommitAndWait(be, seq);
}

static void TestGpuWrites(id<MTLDevice> dev) {
    if (!RequireMetal4(dev, "gnm_residency_test (GPU writes)")) return;
    NSError* err = nil;
    id<MTLLibrary> lib = [dev newLibraryWithSource:[NSString stringWithUTF8String:kWriteMsl] options:nil error:&err];
    id<MTLComputePipelineState> pso =
        lib ? [dev newComputePipelineStateWithFunction:[lib newFunctionWithName:@"fill"] error:&err] : nil;
    CHECK(pso, "pipeline: %s", err.localizedDescription.UTF8String);
    if (!pso) return;
    const size_t n = 1u << 20;
    uint32_t* mem[2] = {};
    @autoreleasepool {
        Metal4Backend be;
        std::string why;
        CHECK(be.Init(dev, &why), "Metal 4 backend: %s", why.c_str());
        for (int resident = 1; resident >= 0; --resident) {
            uint32_t* m = (uint32_t*)mmap(nullptr, n, PROT_READ | PROT_WRITE, MAP_ANON | MAP_PRIVATE, -1, 0);
            mem[resident] = m;
            id<MTLBuffer> buf = [dev newBufferWithBytesNoCopy:m length:n options:MTLResourceStorageModeShared
                                                  deallocator:nil];
            if (resident) be.MakeResident(buf, GnmResidencyClass::Guest);
            const uint64_t seq = resident ? 1 : 2;
            CHECK(RunFill(be, pso, buf, seq), "the dispatch's seq failed or hung (resident %d)", resident);
            uint32_t right = 0;
            for (uint32_t i = 0; i < 4096; ++i) right += m[i] == i * 3u + 7u;
            if (resident) CHECK(right == 4096, "resident window: %u of 4096 dwords written", right);
            else CHECK(right == 0, "negative control: %u of 4096 dwords written into a window in no residency set; "
                                   "the control shows nothing (Metal made it resident?)", right);
            if (resident) be.Evict(buf, seq);
        }
    } // the backend (and its sets) go before the memory under the windows
    for (uint32_t* m : mem)
        if (m) munmap(m, n);
}

// The renderer's guest memory views: a 64 MiB window and a buffer spanning
// several windows are two no-copy buffers over the same pages, so the same memory has two GPU
// virtual addresses. A dispatch writes through one, the next encoder reads through the other
// (encoder-start barrier), then the other way round, every round with new values. Metal 4.
static void TestAliasedViews(id<MTLDevice> dev) {
    if (!RequireMetal4(dev, "gnm_residency_test (aliased views)")) return;
    NSError* err = nil;
    id<MTLLibrary> lib = [dev newLibraryWithSource:[NSString stringWithUTF8String:kWriteMsl] options:nil error:&err];
    id<MTLComputePipelineState> fill = lib ? [dev newComputePipelineStateWithFunction:[lib newFunctionWithName:@"fill"] error:&err] : nil;
    id<MTLComputePipelineState> copy = lib ? [dev newComputePipelineStateWithFunction:[lib newFunctionWithName:@"copy"] error:&err] : nil;
    CHECK(fill && copy, "pipelines: %s", err.localizedDescription.UTF8String);
    if (!fill || !copy) return;
    const size_t win = 1u << 20, dwords = win / 4;
    uint32_t* m = (uint32_t*)mmap(nullptr, 2 * win, PROT_READ | PROT_WRITE, MAP_ANON | MAP_PRIVATE, -1, 0);
    CHECK(m != MAP_FAILED, "memory");
    if (m == MAP_FAILED) return;
    uint64_t wrong_rounds = 0, wrong_dwords = 0;
    @autoreleasepool {
        Metal4Backend be;
        std::string why;
        CHECK(be.Init(dev, &why), "Metal 4 backend: %s", why.c_str());
        // the second window, and a buffer spanning both windows (the window's bytes at offset win)
        id<MTLBuffer> window = [dev newBufferWithBytesNoCopy:(uint8_t*)m + win length:win
                                                     options:MTLResourceStorageModeShared deallocator:nil];
        id<MTLBuffer> span = [dev newBufferWithBytesNoCopy:m length:2 * win options:MTLResourceStorageModeShared
                                               deallocator:nil];
        id<MTLBuffer> out = [dev newBufferWithLength:win options:MTLResourceStorageModeShared];
        be.MakeResident(window, GnmResidencyClass::Guest);
        be.MakeResident(span, GnmResidencyClass::Guest);
        be.MakeResident(out, GnmResidencyClass::Builtin);
        for (uint32_t round = 0; round < 32; ++round) {
            const bool via_window = round % 2 == 0;
            const uint32_t k = 1000 + round;
            be.BeginCmd(GnmCmdTarget::Main, @"aliased views", false);
            be.BeginCompute(false);
            be.SetComputePipeline(fill);
            if (via_window) be.BindBuffer(GnmStage::Compute, 0, window, 0);
            else be.BindBuffer(GnmStage::Compute, 0, span, win);
            be.BindBytes(GnmStage::Compute, 1, &k, sizeof(k));
            be.Dispatch(MTLSizeMake(dwords / 256, 1, 1), MTLSizeMake(256, 1, 1));
            be.EndEncoder();
            be.BeginCompute(false); // a new encoder: its start barrier orders the read after the write
            be.SetComputePipeline(copy);
            if (via_window) be.BindBuffer(GnmStage::Compute, 0, span, win);
            else be.BindBuffer(GnmStage::Compute, 0, window, 0);
            be.BindBuffer(GnmStage::Compute, 1, out, 0);
            be.Dispatch(MTLSizeMake(dwords / 256, 1, 1), MTLSizeMake(256, 1, 1));
            be.EndEncoder();
            CHECK(CommitAndWait(be, round + 1), "round %u failed or hung", round);
            const uint32_t* o = (const uint32_t*)out.contents;
            uint64_t bad = 0;
            for (uint32_t i = 0; i < dwords; ++i) bad += o[i] != i * 3u + k;
            wrong_rounds += bad != 0;
            wrong_dwords += bad;
        }
        be.Evict(window, 32);
        be.Evict(span, 32);
        be.Evict(out, 32);
    }
    CHECK(wrong_rounds == 0, "aliased views: %llu of 32 rounds read stale data (%llu dwords)",
          (unsigned long long)wrong_rounds, (unsigned long long)wrong_dwords);
    munmap(m, 2 * win);
}

// A view of a resident texture, sampled in a Metal 4 render pass, reads the parent's texels: the
// renderer makes only the textures it creates resident, never their views (AdaptTexture, aliases).
static void TestViews(id<MTLDevice> dev) {
    if (!RequireMetal4(dev, "gnm_residency_test (views)")) return;
    Metal4Backend be;
    std::string why;
    GnmUtil util;
    CHECK(be.Init(dev, &why) && MakeGnmUtil(dev, &util, &why), "%s", why.c_str());
    MTLTextureDescriptor* td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm
                                                                                  width:32 height:32 mipmapped:NO];
    td.usage = MTLTextureUsageShaderRead | MTLTextureUsagePixelFormatView;
    td.storageMode = MTLStorageModeShared;
    id<MTLTexture> parent = [dev newTextureWithDescriptor:td];
    std::vector<uint32_t> px(32 * 32, 0xFF4080C0u); // ABGR in memory: r = 0xC0, g = 0x80, b = 0x40
    [parent replaceRegion:MTLRegionMake2D(0, 0, 32, 32) mipmapLevel:0 withBytes:px.data() bytesPerRow:128];
    id<MTLTexture> view = [parent newTextureViewWithPixelFormat:MTLPixelFormatRGBA8Unorm];
    td.pixelFormat = MTLPixelFormatBGRA8Unorm;
    td.usage = MTLTextureUsageRenderTarget;
    id<MTLTexture> rt = [dev newTextureWithDescriptor:td];
    be.MakeResident(parent, GnmResidencyClass::Texture);
    be.MakeResident(rt, GnmResidencyClass::Texture);
    be.BeginCmd(GnmCmdTarget::Main, @"view", false);
    GnmPassDesc pd;
    pd.color[0].tex = rt;
    pd.color[0].load = GnmLoad::DontCare;
    CHECK(FullscreenPass(be, pd, util.present, nil, view), "pass");
    CHECK(CommitAndWait(be, 1), "seq failed");
    uint32_t got = 0;
    [rt getBytes:&got bytesPerRow:128 fromRegion:MTLRegionMake2D(7, 9, 1, 1) mipmapLevel:0];
    CHECK(got == 0xFFC08040u, "view of a resident texture read %08x, want ffc08040 (BGRA of the parent's texel)", got);
    be.Evict(parent, 1);
    be.Evict(rt, 1);
}

// The bind-time residency check (PS4_GNM_RESIDENCY_CHECK=1): each path that hands the GPU a
// resource reports one that is in no residency set, and nothing for a resident one or with the
// check off. One fresh non-resident resource per path (each must count one assert; a path that
// loses its check counts none): bound buffer (twice: counted twice, printed once), texture, view
// of a non-resident texture (a view of a resident one is resident, also a view of a view of one),
// argument-buffer buffer (use),
// colour, resolve, depth and stencil attachments, index buffer, draw indirect buffer, dispatch
// indirect buffer, and the source and destination of each copy and fill. The bad resources are
// made resident after encoding, before the commit, so the GPU never touches a non-resident one.
// Then the early eviction: a buffer evicted after a seq still in flight (gated on an event) and
// bound in the next seq leaves its set when the earlier one completes, maybe while the later one
// runs: it counts as not resident (the bind is checked against the seq being recorded); one
// evicted after the seq being recorded is resident for it.
static const char* kCheckMsl = R"(
#include <metal_stdlib>
using namespace metal;
struct VOut { float4 pos [[position]]; };
vertex VOut tri_vs(uint vid [[vertex_id]]) {
    VOut o;
    float2 uv = float2((vid << 1) & 2, vid & 2);
    o.pos = float4(uv * 2.0 - 1.0, 0.0, 1.0);
    return o;
}
fragment float4 one_fs(VOut in [[stage_in]]) { return float4(1.0); }
kernel void nop(device uint* out [[buffer(0)]], uint i [[thread_position_in_grid]]) { if (i == 0) out[0] = 1u; }
)";

static void NoCompletion(void*, const GnmCompletion&) {}

static void TestBindCheck(id<MTLDevice> dev) {
    if (!RequireMetal4(dev, "gnm_residency_test (bind check)")) return;
    NSError* err = nil;
    id<MTLLibrary> lib = [dev newLibraryWithSource:[NSString stringWithUTF8String:kCheckMsl] options:nil error:&err];
    MTLRenderPipelineDescriptor* rd = [MTLRenderPipelineDescriptor new];
    rd.vertexFunction = [lib newFunctionWithName:@"tri_vs"];
    rd.fragmentFunction = [lib newFunctionWithName:@"one_fs"];
    rd.colorAttachments[0].pixelFormat = MTLPixelFormatRGBA8Unorm;
    id<MTLRenderPipelineState> rps = lib ? [dev newRenderPipelineStateWithDescriptor:rd error:&err] : nil;
    id<MTLComputePipelineState> cps = lib ? [dev newComputePipelineStateWithFunction:[lib newFunctionWithName:@"nop"] error:&err] : nil;
    CHECK(rps && cps, "pipelines: %s", err.localizedDescription.UTF8String);
    if (!rps || !cps) return;
    auto buf = [&](const void* init, size_t n) {
        return init ? [dev newBufferWithBytes:init length:n options:MTLResourceStorageModeShared]
                    : [dev newBufferWithLength:n options:MTLResourceStorageModeShared];
    };
    auto tex = [&](MTLPixelFormat f, NSUInteger samples, MTLTextureUsage u) {
        MTLTextureDescriptor* td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:f width:8 height:8 mipmapped:NO];
        if (samples > 1) {
            td.textureType = MTLTextureType2DMultisample;
            td.sampleCount = samples;
        }
        td.storageMode = MTLStorageModePrivate;
        td.usage = u;
        return [dev newTextureWithDescriptor:td];
    };
    const MTLTextureUsage kRt = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
    const uint16_t idx[4] = {0, 1, 2, 0};
    const uint32_t draw_args[4] = {3, 1, 0, 0}, dispatch_args[3] = {1, 1, 1};
    for (int on = 1; on >= 0; --on) {
        if (on) setenv("PS4_GNM_RESIDENCY_CHECK", "1", 1);
        Metal4Backend be;
        std::string why;
        CHECK(be.Init(dev, &why), "%s", why.c_str());
        unsetenv("PS4_GNM_RESIDENCY_CHECK");
        std::vector<id<MTLAllocation>> bad; // made resident before the commit
        auto Bad = [&](id<MTLAllocation> a) {
            bad.push_back(a);
            return a;
        };
        auto Good = [&](id<MTLAllocation> a) {
            be.MakeResident(a, GnmResidencyClass::Builtin);
            return a;
        };
        // one op on a fresh non-resident resource: one assert with the check on, none off
        auto expect = [&](const char* path, uint64_t want, auto op) {
            const uint64_t a0 = be.Stats().residency_asserts;
            op();
            const uint64_t n = be.Stats().residency_asserts - a0;
            CHECK(n == (on ? want : 0), "check %s, %s: %llu asserts, want %llu", on ? "on" : "off", path,
                  (unsigned long long)n, (unsigned long long)(on ? want : 0));
        };
        id<MTLBuffer> in = (id<MTLBuffer>)Good(buf(nullptr, 4096));
        id<MTLTexture> rt = (id<MTLTexture>)Good(tex(MTLPixelFormatRGBA8Unorm, 1, kRt));
        id<MTLTexture> rt2 = (id<MTLTexture>)Good(tex(MTLPixelFormatRGBA8Unorm, 1, kRt));
        id<MTLTexture> msaa = (id<MTLTexture>)Good(tex(MTLPixelFormatRGBA8Unorm, 4, MTLTextureUsageRenderTarget));
        id<MTLBuffer> ib = (id<MTLBuffer>)Good(buf(idx, sizeof(idx)));
        id<MTLBuffer> dargs = (id<MTLBuffer>)Good(buf(draw_args, sizeof(draw_args)));
        id<MTLTexture> parent = (id<MTLTexture>)Good(tex(MTLPixelFormatRGBA8Unorm, 1, kRt | MTLTextureUsagePixelFormatView));
        be.BeginCmd(GnmCmdTarget::Main, @"check", false);

        be.BeginCompute(false);
        be.SetComputePipeline(cps);
        be.BindBuffer(GnmStage::Compute, 0, in, 0);
        expect("resident buffer", 0, [&] { be.BindBuffer(GnmStage::Compute, 1, in, 0); });
        id<MTLBuffer> out = (id<MTLBuffer>)Bad(buf(nullptr, 4096));
        expect("bind buffer, twice", 2, [&] {
            be.BindBuffer(GnmStage::Compute, 1, out, 0);
            be.BindBuffer(GnmStage::Compute, 2, out, 256);
        });
        expect("bind texture", 1, [&] { be.BindTexture(GnmStage::Compute, 0, (id<MTLTexture>)Bad(tex(MTLPixelFormatRGBA8Unorm, 1, kRt))); });
        id<MTLTexture> vparent = (id<MTLTexture>)Bad(tex(MTLPixelFormatRGBA8Unorm, 1, kRt | MTLTextureUsagePixelFormatView));
        expect("view of a non-resident texture", 1,
               [&] { be.BindTexture(GnmStage::Compute, 1, [vparent newTextureViewWithPixelFormat:MTLPixelFormatRGBA8Unorm_sRGB]); });
        expect("view of a resident texture", 0,
               [&] { be.BindTexture(GnmStage::Compute, 2, [parent newTextureViewWithPixelFormat:MTLPixelFormatRGBA8Unorm_sRGB]); });
        // a view of a view (AdaptTexture's array view of the texture cache's format view, U4's title):
        // its parentTexture is the inner view, which is in no set; the root is
        auto view_of_view = [](id<MTLTexture> root) {
            id<MTLTexture> inner = [root newTextureViewWithPixelFormat:MTLPixelFormatRGBA8Unorm_sRGB];
            return [inner newTextureViewWithPixelFormat:inner.pixelFormat textureType:MTLTextureType2DArray
                                                 levels:NSMakeRange(0, 1) slices:NSMakeRange(0, 1)];
        };
        expect("view of a view of a resident texture", 0, [&] { be.BindTexture(GnmStage::Compute, 3, view_of_view(parent)); });
        id<MTLTexture> vvparent = (id<MTLTexture>)Bad(tex(MTLPixelFormatRGBA8Unorm, 1, kRt | MTLTextureUsagePixelFormatView));
        expect("view of a view of a non-resident texture", 1, [&] { be.BindTexture(GnmStage::Compute, 3, view_of_view(vvparent)); });
        expect("use (argument-buffer buffer)", 1, [&] { be.UseResource(GnmStage::Compute, (id<MTLBuffer>)Bad(buf(nullptr, 256)), false); });
        expect("dispatch indirect buffer", 1,
               [&] { be.DispatchIndirect((id<MTLBuffer>)Bad(buf(dispatch_args, sizeof(dispatch_args))), 0, MTLSizeMake(1, 1, 1)); });
        be.EndEncoder();

        auto pass = [&](const char* path, uint64_t want, GnmPassDesc pd) {
            expect(path, want, [&] { CHECK(be.BeginRender(pd), "%s: BeginRender", path); });
            be.EndEncoder();
        };
        GnmPassDesc pd;
        pd.color[0].tex = (id<MTLTexture>)Bad(tex(MTLPixelFormatRGBA8Unorm, 1, kRt));
        pass("colour attachment", 1, pd);
        pd = GnmPassDesc();
        pd.color[0].tex = msaa;
        pd.color[0].store = GnmStore::MultisampleResolve;
        pd.color[0].resolve = (id<MTLTexture>)Bad(tex(MTLPixelFormatRGBA8Unorm, 1, kRt));
        pass("resolve attachment", 1, pd);
        pd = GnmPassDesc();
        pd.depth.tex = (id<MTLTexture>)Bad(tex(MTLPixelFormatDepth32Float, 1, MTLTextureUsageRenderTarget));
        pass("depth attachment", 1, pd);
        pd = GnmPassDesc();
        pd.stencil.tex = (id<MTLTexture>)Bad(tex(MTLPixelFormatStencil8, 1, MTLTextureUsageRenderTarget));
        pass("stencil attachment", 1, pd);

        pd = GnmPassDesc();
        pd.color[0].tex = rt;
        CHECK(be.BeginRender(pd), "draw pass");
        be.SetRenderPipeline(rps);
        GnmDraw d;
        d.kind = GnmDrawKind::Indexed;
        d.count = 3;
        d.index_buffer = (id<MTLBuffer>)Bad(buf(idx, sizeof(idx)));
        d.index_length = sizeof(idx);
        expect("index buffer", 1, [&] { be.Draw(d); });
        d = GnmDraw();
        d.kind = GnmDrawKind::Indirect;
        d.indirect_buffer = (id<MTLBuffer>)Bad(buf(draw_args, sizeof(draw_args)));
        expect("draw indirect buffer", 1, [&] { be.Draw(d); });
        d = GnmDraw();
        d.kind = GnmDrawKind::IndexedIndirect;
        d.index_buffer = ib;
        d.index_length = sizeof(idx);
        d.indirect_buffer = dargs;
        expect("resident index and indirect buffers", 0, [&] { be.Draw(d); });
        be.EndEncoder();

        be.BeginCopies();
        expect("copy buffer source", 1, [&] { be.CopyBuffer((id<MTLBuffer>)Bad(buf(nullptr, 256)), 0, in, 0, 256); });
        expect("copy buffer destination", 1, [&] { be.CopyBuffer(in, 0, (id<MTLBuffer>)Bad(buf(nullptr, 256)), 0, 256); });
        expect("fill destination", 1, [&] { be.FillBuffer((id<MTLBuffer>)Bad(buf(nullptr, 256)), 0, 256, 0); });
        expect("copy texture source", 1, [&] { be.CopyTexture((id<MTLTexture>)Bad(tex(MTLPixelFormatRGBA8Unorm, 1, kRt)), rt2); });
        expect("copy texture destination", 1, [&] { be.CopyTexture(rt2, (id<MTLTexture>)Bad(tex(MTLPixelFormatRGBA8Unorm, 1, kRt))); });
        expect("copy texture region source", 1, [&] {
            be.CopyTextureRegion((id<MTLTexture>)Bad(tex(MTLPixelFormatRGBA8Unorm, 1, kRt)), 0, 0, MTLOriginMake(0, 0, 0),
                                 MTLSizeMake(4, 4, 1), rt2, 0, 0, MTLOriginMake(0, 0, 0));
        });
        expect("copy texture region destination", 1, [&] {
            be.CopyTextureRegion(rt2, 0, 0, MTLOriginMake(0, 0, 0), MTLSizeMake(4, 4, 1),
                                 (id<MTLTexture>)Bad(tex(MTLPixelFormatRGBA8Unorm, 1, kRt)), 0, 0, MTLOriginMake(0, 0, 0));
        });
        expect("buffer to texture source", 1, [&] {
            be.CopyBufferToTexture((id<MTLBuffer>)Bad(buf(nullptr, 4096)), 0, 32, 256, MTLSizeMake(8, 8, 1), rt2, 0, 0,
                                   MTLOriginMake(0, 0, 0));
        });
        expect("buffer to texture destination", 1, [&] {
            be.CopyBufferToTexture(in, 0, 32, 256, MTLSizeMake(8, 8, 1),
                                   (id<MTLTexture>)Bad(tex(MTLPixelFormatRGBA8Unorm, 1, kRt)), 0, 0, MTLOriginMake(0, 0, 0));
        });
        be.EndEncoder();
        for (id<MTLAllocation> a : bad) be.MakeResident(a, GnmResidencyClass::Builtin);
        CHECK(CommitAndWait(be, 1), "check %s: seq 1 failed", on ? "on" : "off");

        // the early eviction: b2 evicted after seq 2, which waits on an event, and bound in seq 3
        id<MTLBuffer> b2 = (id<MTLBuffer>)Good(buf(nullptr, 4096));
        id<MTLSharedEvent> gate = [dev newSharedEvent];
        be.BeginCmd(GnmCmdTarget::Main, @"check gated", false);
        be.QueueWait(gate, 1);
        be.BeginCopies();
        be.FillBuffer(b2, 0, 4096, 1);
        be.EndEncoder();
        be.Commit(2, NoCompletion, nullptr);
        be.Evict(b2, 2);
        be.BeginCmd(GnmCmdTarget::Main, @"check after the eviction", false);
        be.BeginCopies();
        expect("buffer evicted after an unfinished seq, bound in the next", 1, [&] { be.FillBuffer(b2, 0, 4096, 2); });
        // evicted after the seq being recorded (as the renderer does: committed + 1): resident for it
        id<MTLBuffer> b3 = (id<MTLBuffer>)Good(buf(nullptr, 4096));
        be.Evict(b3, 3);
        expect("buffer evicted after the seq being recorded, bound in it", 0, [&] { be.FillBuffer(b3, 0, 4096, 3); });
        be.EndEncoder();
        be.MakeResident(b2, GnmResidencyClass::Builtin); // cancels the removal: seq 3 may run safely
        gate.signaledValue = 1;
        CHECK(CommitAndWait(be, 3), "check %s: seq 3 failed", on ? "on" : "off");
    }
}

// Child modes: each misuse must abort. Returning 0 means it was accepted.
static int RunMisuse(const char* mode) {
    id<MTLDevice> dev = MTLCreateSystemDefaultDevice();
    id<MTLBuffer> a = [dev newBufferWithLength:4096 options:0];
    GnmResidency r;
    std::string why;
    if (!strcmp(mode, "class")) {
        r.Init(dev, &why);
        r.Add(a, GnmResidencyClass::Guest);
        r.Add(a, GnmResidencyClass::Texture);
    } else if (!strcmp(mode, "add-uninit")) {
        r.Add(a, GnmResidencyClass::Guest);
    } else if (!strcmp(mode, "remove-uninit")) {
        r.Remove(a, 1);
    }
    return 0;
}

static void TestMisuseAborts() {
    char path[4096];
    uint32_t size = sizeof(path);
    if (_NSGetExecutablePath(path, &size) != 0) {
        CHECK(false, "no executable path");
        return;
    }
    for (const char* mode : {"class", "add-uninit", "remove-uninit"}) {
        int fds[2];
        if (pipe(fds) != 0) {
            CHECK(false, "pipe");
            return;
        }
        posix_spawn_file_actions_t fa;
        posix_spawn_file_actions_init(&fa);
        posix_spawn_file_actions_adddup2(&fa, fds[1], 2);
        posix_spawn_file_actions_addclose(&fa, fds[0]);
        char* argv[] = {path, (char*)"--misuse", (char*)mode, nullptr};
        pid_t pid = 0;
        const int rc = posix_spawn(&pid, path, &fa, nullptr, argv, nullptr);
        posix_spawn_file_actions_destroy(&fa);
        close(fds[1]);
        std::string err;
        char buf[512];
        for (ssize_t n; (n = read(fds[0], buf, sizeof(buf))) > 0;) err.append(buf, (size_t)n);
        close(fds[0]);
        int st = 0;
        if (rc != 0 || waitpid(pid, &st, 0) != pid) {
            CHECK(false, "%s: spawn failed", mode);
            continue;
        }
        CHECK(WIFEXITED(st) && WEXITSTATUS(st) == kAbortExit, "%s: the misuse did not abort (status 0x%x)", mode, st);
        CHECK(err.find("FATAL: GnmResidency") != std::string::npos, "%s: no FATAL message (stderr: %s)", mode, err.c_str());
    }
}

int main(int argc, char** argv) {
    if (argc == 3 && !strcmp(argv[1], "--misuse")) {
        @autoreleasepool {
            ExitOnAbort();
            return RunMisuse(argv[2]);
        }
    }
    @autoreleasepool {
        id<MTLDevice> dev = MTLCreateSystemDefaultDevice();
        if (!dev) {
            printf("gnm_residency_test: FAIL: no Metal device\n");
            return 1;
        }
        TestSetLogic(dev);
        TestStrongReference(dev);
        TestViewOwnEntry(dev);
        TestRemovalOrder(dev);
        TestConcurrency(dev);
        TestMisuseAborts();
        TestGpuWrites(dev);
        TestAliasedViews(dev);
        TestViews(dev);
        TestBindCheck(dev);
    }
    printf("gnm_residency_test: %s\n", g_fail ? "FAIL" : "PASS");
    return g_fail ? 1 : 0;
}
