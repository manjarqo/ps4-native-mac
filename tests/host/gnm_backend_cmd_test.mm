// Command buffers and the seq timeline on the backend PS4_GNM_METAL selects (both run it):
//  - the encoder state the renderer reads (OpenEncoder, EncoderSerial) per target across opens,
//    ends and target switches; Upload encoders never change Main's serial;
//  - queue-level events in order: a signal before a wait happens before the wait is satisfied,
//    work after the wait waits for it, and the seq completes once (Metal 3 encodes the events
//    into the command buffer; Metal 4 issues them on the queue);
//  - a backend destroyed with work in flight (twice in a row, the second time with a command
//    buffer still open) does not crash; Metal 4's destructor returns only after every completion;
//  - compute work: dispatches ordered by an explicit Barrier and by a serial encoder, DispatchThreads,
//    DispatchIndirect, BindBufferOffset, compute texture and sampler bindings;
//  - Metal 4: a queue-level event that would split the seq with Upload current is FATAL (a child
//    process; the renderer issues events on Main only);
//  - every completion runs once CompletedSeq() has reached its seq, and completions run in seq
//    order (3000 seqs at the renderer's pace);
//  - a queue-level signal and wait between two render passes of one seq (the split: Metal 4
//    commits the first pass there), a signal followed by more work in the same seq, and a signal
//    on Main after copies recorded on Upload (it follows them, as on Metal 3);
//  - texture views dropped by the caller right after their use (a sampled view, a colour
//    attachment view, a copy source view), before the commit, with hundreds of new views of another
//    texture made before the GPU runs (they may take a dropped view's resource ID): each view stays
//    alive until its seq completed and is released after, and the pass and the copy read the
//    dropped views' texels. Metal 3's command buffer retains what is encoded; a Metal 4 command
//    buffer retains nothing, so the backend keeps every texture an encoder used until its seq completes;
//  - the asynchronous compute queue (kGnmCapAsyncCompute, both backends): with a main seq
//    committed and held by an event, async seqs complete and their completions run (in seq order)
//    while CompletedSeq stays below the held main seq; with a main seq open (not committed), async
//    seqs that complete and recycle bytes chunks do not overwrite its setBytes, and a buffer it
//    writes that is evicted meanwhile (after the last committed seq, as the renderer does) stays
//    resident until it is committed and completed, and its write lands;
//  - Metal 4 only: the feedback dispatch queue is freed with its backend (no leak); no command
//    allocator is reset before its seq completed, one is reused once its seq completed, the
//    allocator count stays bounded over 1000 seqs, the allocator trim (oversized allocators
//    released after their reset, at most a few kept; surplus free ones released after the
//    in-flight peak falls; no churn at a steady depth), and WaitForRoom reports a GPU that makes
//    no progress.
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>

#include <mach-o/dyld.h>
#include <signal.h>
#include <spawn.h>
#include <sys/wait.h>
#include <unistd.h>

#include <atomic>
#include <mutex>
#include <thread>
#include <vector>

#include "backend_harness.h"
#include "ps4_gnm_backend_metal4.h"
#include "ps4_gnm_util_passes.h"

using namespace ps4gnm;

static uint64_t g_seq = 0;

static void Count(void* p, const GnmCompletion&) { static_cast<std::atomic<int>*>(p)->fetch_add(1); }
static void Ignore(void*, const GnmCompletion&) {}

static void TestEncoderTracking(GnmBackend& be) {
    CheckEncoderTracking(be);
    const uint64_t seq = ++g_seq;
    CHECK(CommitAndWait(be, seq), "encoder tracking seq %llu failed", (unsigned long long)seq);
}

static void TestEventOrder(id<MTLDevice> dev, GnmBackend& be) {
    id<MTLSharedEvent> a = [dev newSharedEvent], gate = [dev newSharedEvent], c = [dev newSharedEvent];
    be.BeginCmd(GnmCmdTarget::Main, @"events", false);
    be.QueueSignal(a, 1);
    be.QueueWait(gate, 1);
    be.QueueSignal(c, 1);
    const uint64_t seq = ++g_seq;
    static std::atomic<int> calls; // static: a late completion of a failed run finds it alive
    calls = 0;
    be.Commit(seq, Count, &calls);
    CHECK([a waitUntilSignaledValue:1 timeoutMS:2000], "the signal before the wait did not happen");
    usleep(200000);
    CHECK(c.signaledValue == 0, "work after a wait for an unsignalled event ran");
    CHECK(be.CompletedSeq() < seq, "seq %llu completed before its wait was satisfied", (unsigned long long)seq);
    gate.signaledValue = 1;
    CHECK([c waitUntilSignaledValue:1 timeoutMS:2000], "the signal after the wait did not happen");
    for (int i = 0; i < 200 && be.CompletedSeq() < seq; ++i) usleep(10000);
    CHECK(be.CompletedSeq() >= seq, "seq not complete after its wait was satisfied");
    for (int i = 0; i < 200 && calls.load() == 0; ++i) usleep(10000);
    usleep(50000); // a second (wrong) call would come right after the first
    CHECK(calls.load() == 1, "completion called %d times", calls.load());
}

static id<MTLTexture> SharedRgba(id<MTLDevice> dev, GnmBackend& be, uint32_t rgba) {
    MTLTextureDescriptor* td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm
                                                                                  width:8 height:8 mipmapped:NO];
    td.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
    td.storageMode = MTLStorageModeShared;
    id<MTLTexture> t = [dev newTextureWithDescriptor:td];
    uint32_t px[64];
    for (uint32_t& p : px) p = rgba;
    [t replaceRegion:MTLRegionMake2D(0, 0, 8, 8) mipmapLevel:0 withBytes:px bytesPerRow:32];
    be.MakeResident(t, GnmResidencyClass::Texture);
    return t;
}

static uint32_t Pixel(id<MTLTexture> t) {
    uint32_t p = 0;
    [t getBytes:&p bytesPerRow:32 fromRegion:MTLRegionMake2D(3, 3, 1, 1) mipmapLevel:0];
    return p;
}

static void ClearPass(GnmBackend& be, id<MTLTexture> t, MTLClearColor c) {
    GnmPassDesc pd;
    pd.color[0].tex = t;
    pd.color[0].load = GnmLoad::Clear;
    pd.clear_color[0] = c;
    CHECK(be.BeginRender(pd), "no render encoder");
    CHECK(be.OpenEncoder() == GnmEncoder::Render, "render encoder not reported (%d)", (int)be.OpenEncoder());
    be.EndEncoder();
}

// A queue-level signal between two render passes of one seq: the first pass's result is visible
// when the signal is (Metal 4 commits the first part there: split_commits + 1), the second pass
// waits for the event the wait names, and the seq completes once, after both.
static void TestSplit(id<MTLDevice> dev, GnmBackend& be) {
    id<MTLTexture> a = SharedRgba(dev, be, 0xFF0000FFu), b = SharedRgba(dev, be, 0xFFFF0000u); // red, blue (ABGR in memory)
    id<MTLSharedEvent> after_a = [dev newSharedEvent], gate = [dev newSharedEvent];
    const uint64_t split0 = be.Stats().split_commits;
    be.BeginCmd(GnmCmdTarget::Main, @"split", false);
    ClearPass(be, a, MTLClearColorMake(0, 1, 0, 1)); // a: green
    be.QueueSignal(after_a, 1);
    be.QueueWait(gate, 1);
    ClearPass(be, b, MTLClearColorMake(1, 1, 1, 1)); // b: white
    const uint64_t seq = ++g_seq;
    static std::atomic<int> calls; // static: a late completion of a failed run finds it alive
    calls = 0;
    be.Commit(seq, Count, &calls);
    CHECK([after_a waitUntilSignaledValue:1 timeoutMS:2000], "the signal after the first pass did not happen");
    CHECK(Pixel(a) == 0xFF00FF00u, "the first pass's clear is not visible at its signal: %08x", Pixel(a));
    usleep(100000);
    CHECK(Pixel(b) == 0xFFFF0000u, "the second pass ran before its wait was satisfied: %08x", Pixel(b));
    CHECK(be.CompletedSeq() < seq && calls.load() == 0, "seq %llu completed before its second part ran",
          (unsigned long long)seq);
    gate.signaledValue = 1;
    for (int i = 0; i < 200 && (be.CompletedSeq() < seq || calls.load() == 0); ++i) usleep(10000);
    CHECK(be.CompletedSeq() >= seq && Pixel(b) == 0xFFFFFFFFu, "the second pass did not run: %08x", Pixel(b));
    usleep(50000);
    CHECK(calls.load() == 1, "completion of the split seq called %d times", calls.load());
    if (be.Kind() == GnmBackendKind::Metal4)
        CHECK(be.Stats().split_commits == split0 + 1, "split commits %llu, want %llu",
              (unsigned long long)be.Stats().split_commits, (unsigned long long)(split0 + 1));
}

// A signal after a pass with more work after it in the same seq: the signal follows the first
// pass (its result is visible at the signal), the work after it still runs, and the seq completes
// once. Metal 4 splits the seq when the work starts again (BeforeWork): split_commits + 1.
static void TestSignalThenWork(id<MTLDevice> dev, GnmBackend& be) {
    id<MTLTexture> a = SharedRgba(dev, be, 0xFF0000FFu), b = SharedRgba(dev, be, 0xFF0000FFu);
    id<MTLSharedEvent> after_a = [dev newSharedEvent];
    const uint64_t split0 = be.Stats().split_commits;
    be.BeginCmd(GnmCmdTarget::Main, @"signal then work", false);
    ClearPass(be, a, MTLClearColorMake(0, 1, 0, 1));
    be.QueueSignal(after_a, 1);
    ClearPass(be, b, MTLClearColorMake(0, 0, 1, 1));
    const uint64_t seq = ++g_seq;
    CHECK(CommitAndWait(be, seq), "seq %llu failed", (unsigned long long)seq);
    CHECK(after_a.signaledValue == 1, "the signal after the first pass did not happen");
    CHECK(Pixel(a) == 0xFF00FF00u && Pixel(b) == 0xFFFF0000u, "pass results %08x %08x", Pixel(a), Pixel(b));
    if (be.Kind() == GnmBackendKind::Metal4)
        CHECK(be.Stats().split_commits == split0 + 1, "split commits %llu, want %llu (no split before the second pass)",
              (unsigned long long)be.Stats().split_commits, (unsigned long long)(split0 + 1));
}

// A signal on Main while the Upload command buffer holds recorded (uncommitted) copies follows
// those copies, as on Metal 3, where the upload command buffer is committed first. Main then waits
// for a gate, so uploads committed only with the seq would still be held when the signal is seen.
static void TestSignalAfterUploads(id<MTLDevice> dev, GnmBackend& be) {
    id<MTLTexture> src = SharedRgba(dev, be, 0xFF00FF00u), dst = SharedRgba(dev, be, 0xFF0000FFu); // green, red
    id<MTLSharedEvent> ev = [dev newSharedEvent], gate = [dev newSharedEvent];
    be.BeginCmd(GnmCmdTarget::Main, @"signal after uploads", false);
    be.UseTarget(GnmCmdTarget::Upload);
    be.BeginCmd(GnmCmdTarget::Upload, @"uploads before the signal", false);
    be.BeginCopies();
    be.CopyTexture(src, dst);
    be.EndEncoder();
    be.UseTarget(GnmCmdTarget::Main);
    be.QueueSignal(ev, 1);
    be.QueueWait(gate, 1);
    const uint64_t seq = ++g_seq;
    static std::atomic<int> calls; // static: a late completion of a failed run finds it alive
    calls = 0;
    be.Commit(seq, Count, &calls);
    CHECK([ev waitUntilSignaledValue:1 timeoutMS:2000], "the signal after the uploads did not happen");
    CHECK(Pixel(dst) == 0xFF00FF00u, "the signal came before the recorded upload copy: %08x", Pixel(dst));
    gate.signaledValue = 1;
    for (int i = 0; i < 200 && calls.load() == 0; ++i) usleep(10000);
    CHECK(calls.load() == 1 && be.CompletedSeq() >= seq, "seq %llu did not complete", (unsigned long long)seq);
}

static const char* kComputeMsl = R"(
#include <metal_stdlib>
using namespace metal;
kernel void k_write(device uint* out [[buffer(0)]], uint i [[thread_position_in_grid]]) { out[i] = i + 1u; }
// k_write's values, written slowly and last for the lowest indices (thread i writes element
// n - 1 - i after a busy loop): a reader that overlaps it reads the low elements before they land
kernel void k_write_slow(device uint* out [[buffer(0)]], constant uint& n [[buffer(1)]], uint i [[thread_position_in_grid]]) {
    uint h = i;
    for (uint k = 0; k < 512u; ++k) h = h * 1664525u + 1013904223u;
    const uint j = n - 1u - i;
    out[j] = j + 1u + (h & (n >> 31u)); // n < 2^31: adds 0, but the compiler cannot drop the loop
}
kernel void k_chain(device const uint* in [[buffer(0)]], device uint* out [[buffer(1)]], uint i [[thread_position_in_grid]]) {
    out[i] = in[i] * 2u;
}
kernel void k_const(device uint* out [[buffer(0)]], constant uint& v [[buffer(1)]], uint i [[thread_position_in_grid]]) {
    out[i] = v;
}
kernel void k_tex(texture2d<float, access::read> t [[texture(0)]], texture2d<float> u [[texture(1)]],
                  sampler s [[sampler(0)]], device float* out [[buffer(0)]], uint i [[thread_position_in_grid]]) {
    if (i == 0) out[0] = t.read(uint2(1, 0)).x;
    if (i == 1) out[1] = u.sample(s, float2(0.625, 0.5)).y;
}
)";

static id<MTLBuffer> Zeroed(id<MTLDevice> dev, GnmBackend& be, NSUInteger n) {
    id<MTLBuffer> b = [dev newBufferWithLength:n options:MTLResourceStorageModeShared];
    memset(b.contents, 0, n);
    be.MakeResident(b, GnmResidencyClass::Guest);
    return b;
}

static size_t Wrong(id<MTLBuffer> b, uint32_t first, uint32_t count, uint32_t (*want)(uint32_t)) {
    const uint32_t* p = (const uint32_t*)b.contents;
    size_t bad = 0;
    for (uint32_t i = 0; i < count; ++i) bad += p[first + i] != want(i);
    return bad;
}

// Compute work on the backend's encoders. A slow write and a dependent read of 4M dwords, ordered
// by Barrier (concurrent encoder), by the encoder itself (BeginCompute(true)), or by the start of
// the next encoder (Metal 4: its start barrier);
// DispatchThreads; DispatchIndirect with its arguments at an offset; a buffer rebound at an
// offset (BindBufferOffset); a texture read and a sampled texture.
static void TestComputeOps(id<MTLDevice> dev, GnmBackend& be) {
    NSError* err = nil;
    id<MTLLibrary> lib = [dev newLibraryWithSource:@(kComputeMsl) options:nil error:&err];
    CHECK(lib != nil, "compute shaders: %s", err.localizedDescription.UTF8String);
    if (!lib) return;
    id<MTLComputePipelineState> wr = [dev newComputePipelineStateWithFunction:[lib newFunctionWithName:@"k_write"] error:&err];
    id<MTLComputePipelineState> slow =
        [dev newComputePipelineStateWithFunction:[lib newFunctionWithName:@"k_write_slow"] error:&err];
    id<MTLComputePipelineState> ch = [dev newComputePipelineStateWithFunction:[lib newFunctionWithName:@"k_chain"] error:&err];
    id<MTLComputePipelineState> tx = [dev newComputePipelineStateWithFunction:[lib newFunctionWithName:@"k_tex"] error:&err];
    CHECK(wr && slow && ch && tx, "compute pipelines: %s", err.localizedDescription.UTF8String);
    if (!wr || !slow || !ch || !tx) return;
    constexpr uint32_t kN = 1u << 22;
    id<MTLBuffer> a = Zeroed(dev, be, kN * 4), b = Zeroed(dev, be, kN * 4), a2 = Zeroed(dev, be, kN * 4),
                  b2 = Zeroed(dev, be, kN * 4), d = Zeroed(dev, be, 4096), args = Zeroed(dev, be, 64),
                  out = Zeroed(dev, be, 16);
    const uint32_t groups[3] = {4, 1, 1}; // 4 x 64 threads, at byte 16
    memcpy((uint8_t*)args.contents + 16, groups, sizeof(groups));
    MTLTextureDescriptor* td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA32Float
                                                                                  width:4 height:1 mipmapped:NO];
    td.usage = MTLTextureUsageShaderRead;
    td.storageMode = MTLStorageModeShared;
    id<MTLTexture> t = [dev newTextureWithDescriptor:td];
    const float texels[16] = {0, 0, 0, 0, 5, 0, 0, 0, 0, 9, 0, 0, 0, 0, 0, 0}; // t[1].x = 5, t[2].y = 9
    [t replaceRegion:MTLRegionMake2D(0, 0, 4, 1) mipmapLevel:0 withBytes:texels bytesPerRow:64];
    be.MakeResident(t, GnmResidencyClass::Texture);
    MTLSamplerDescriptor* sd = [MTLSamplerDescriptor new];
    sd.minFilter = sd.magFilter = MTLSamplerMinMagFilterNearest;
    sd.supportArgumentBuffers = YES;
    id<MTLSamplerState> smp = [dev newSamplerStateWithDescriptor:sd];

    be.BeginCmd(GnmCmdTarget::Main, @"compute ops", false);
    // a concurrent encoder, the dependency ordered by Barrier
    be.BeginCompute(false);
    CHECK(be.OpenEncoder() == GnmEncoder::Compute, "compute encoder not reported (%d)", (int)be.OpenEncoder());
    const uint32_t n = kN;
    be.SetComputePipeline(slow);
    be.BindBuffer(GnmStage::Compute, 0, a, 0);
    be.BindBytes(GnmStage::Compute, 1, &n, sizeof(n));
    be.DispatchThreads(MTLSizeMake(kN, 1, 1), MTLSizeMake(256, 1, 1));
    be.Barrier(kGnmStageDispatch, kGnmStageDispatch, kGnmScopeBuffers);
    be.SetComputePipeline(ch);
    be.BindBuffer(GnmStage::Compute, 0, a, 0);
    be.BindBuffer(GnmStage::Compute, 1, b, 0);
    be.Dispatch(MTLSizeMake(kN / 256, 1, 1), MTLSizeMake(256, 1, 1));
    be.EndEncoder();
    // a serial encoder: the same dependency without a Barrier call
    be.BeginCompute(true);
    be.SetComputePipeline(slow);
    be.BindBuffer(GnmStage::Compute, 0, a2, 0);
    be.BindBytes(GnmStage::Compute, 1, &n, sizeof(n));
    be.Dispatch(MTLSizeMake(kN / 256, 1, 1), MTLSizeMake(256, 1, 1));
    be.SetComputePipeline(ch);
    be.BindBuffer(GnmStage::Compute, 0, a2, 0);
    be.BindBuffer(GnmStage::Compute, 1, b2, 0);
    be.Dispatch(MTLSizeMake(kN / 256, 1, 1), MTLSizeMake(256, 1, 1));
    be.EndEncoder();
    // across two encoders: the second one's start orders it after the first. A missing start
    // barrier showed in about 1 of 6 single tries here, so the pair runs kPairs times.
    constexpr int kPairs = 4;
    id<MTLBuffer> a3[kPairs], b3[kPairs];
    for (int k = 0; k < kPairs; ++k) {
        a3[k] = Zeroed(dev, be, kN * 4);
        b3[k] = Zeroed(dev, be, kN * 4);
        be.BeginCompute(false);
        be.SetComputePipeline(slow);
        be.BindBuffer(GnmStage::Compute, 0, a3[k], 0);
        be.BindBytes(GnmStage::Compute, 1, &n, sizeof(n));
        be.Dispatch(MTLSizeMake(kN / 256, 1, 1), MTLSizeMake(256, 1, 1));
        be.EndEncoder();
        be.BeginCompute(false);
        be.SetComputePipeline(ch);
        be.BindBuffer(GnmStage::Compute, 0, a3[k], 0);
        be.BindBuffer(GnmStage::Compute, 1, b3[k], 0);
        be.Dispatch(MTLSizeMake(kN / 256, 1, 1), MTLSizeMake(256, 1, 1));
        be.EndEncoder();
    }
    // indirect, into d at byte 256 (BindBufferOffset); then textures and a sampler
    be.BeginCompute(false);
    be.SetComputePipeline(wr);
    be.BindBuffer(GnmStage::Compute, 0, d, 0);
    be.BindBufferOffset(GnmStage::Compute, 0, 256);
    be.DispatchIndirect(args, 16, MTLSizeMake(64, 1, 1));
    be.SetComputePipeline(tx);
    be.BindTexture(GnmStage::Compute, 0, t);
    be.BindTexture(GnmStage::Compute, 1, t);
    be.BindSampler(GnmStage::Compute, 0, smp);
    be.BindBuffer(GnmStage::Compute, 0, out, 0);
    be.Dispatch(MTLSizeMake(1, 1, 1), MTLSizeMake(2, 1, 1));
    be.EndEncoder();
    const uint64_t seq = ++g_seq;
    CHECK(CommitAndWait(be, seq), "compute seq %llu failed", (unsigned long long)seq);
    size_t bad = Wrong(b, 0, kN, [](uint32_t i) { return (i + 1u) * 2u; });
    CHECK(bad == 0, "Barrier: %zu of %u dwords read before the write they depend on", bad, kN);
    bad = Wrong(b2, 0, kN, [](uint32_t i) { return (i + 1u) * 2u; });
    CHECK(bad == 0, "serial encoder: %zu of %u dwords read before the write they depend on", bad, kN);
    for (int k = 0; k < kPairs; ++k) {
        bad = Wrong(b3[k], 0, kN, [](uint32_t i) { return (i + 1u) * 2u; });
        CHECK(bad == 0, "next encoder (pair %d): %zu of %u dwords read before the previous encoder's write", k, bad, kN);
    }
    CHECK(Wrong(d, 0, 64, [](uint32_t) { return 0u; }) == 0, "DispatchIndirect wrote below the bound offset");
    bad = Wrong(d, 64, 256, [](uint32_t i) { return i + 1u; });
    CHECK(bad == 0, "DispatchIndirect at BindBufferOffset 256: %zu of 256 dwords wrong", bad);
    const float* o = (const float*)out.contents;
    CHECK(o[0] == 5.0f && o[1] == 9.0f, "compute texture read %g, sample %g (want 5, 9)", o[0], o[1]);
}

// The second queue beside the main one. See the file comment.
struct AsyncDone {
    std::atomic<int> n{0};
    std::mutex mu;
    std::vector<uint64_t> order; // under mu: the seqs of the completions, as they ran
    static void Fn(void* p, const GnmCompletion& c) {
        AsyncDone* d = static_cast<AsyncDone*>(p);
        {
            std::lock_guard<std::mutex> lk(d->mu);
            d->order.push_back(c.seq);
        }
        d->n.fetch_add(1);
    }
};

// `count` async seqs, each binding kBytesPerSeq setBytes values (enough to fill a 256 KiB chunk of
// 256-byte slots) and writing the last into out[k]; each is waited for before the next begins (its
// BeginCmd recycles what completed). Leaves Main current.
static void RunAsyncSeqs(GnmBackend& be, id<MTLComputePipelineState> kc, __strong id<MTLBuffer> const* out, int count,
                         AsyncDone& done) {
    constexpr int kBytesPerSeq = 1200;
    be.UseTarget(GnmCmdTarget::AsyncCompute);
    for (int k = 0; k < count; ++k) {
        be.BeginCmd(GnmCmdTarget::AsyncCompute, @"async test async", false);
        be.BeginCompute(false);
        be.SetComputePipeline(kc);
        be.BindBuffer(GnmStage::Compute, 0, out[k], 0);
        const uint32_t v = 0xA5000000u + (uint32_t)k;
        for (int i = 0; i < kBytesPerSeq; ++i) be.BindBytes(GnmStage::Compute, 1, &v, sizeof(v));
        be.Dispatch(MTLSizeMake(1, 1, 1), MTLSizeMake(64, 1, 1));
        be.EndEncoder();
        const int want = done.n.load() + 1;
        be.CommitAsync(++g_seq, AsyncDone::Fn, &done);
        for (int i = 0; i < 1000 && done.n.load() < want; ++i) usleep(1000);
    }
    be.UseTarget(GnmCmdTarget::Main);
    for (int k = 0; k < count; ++k)
        CHECK(((const uint32_t*)out[k].contents)[0] == 0xA5000000u + (uint32_t)k, "async seq %d wrote 0x%x", k,
              ((const uint32_t*)out[k].contents)[0]);
}

static void TestAsyncQueue(id<MTLDevice> dev, GnmBackend& be) {
    if (!(be.Caps() & kGnmCapAsyncCompute)) return;
    NSError* err = nil;
    id<MTLLibrary> lib = [dev newLibraryWithSource:@(kComputeMsl) options:nil error:&err];
    id<MTLComputePipelineState> kc =
        lib ? [dev newComputePipelineStateWithFunction:[lib newFunctionWithName:@"k_const"] error:&err] : nil;
    CHECK(kc != nil, "k_const: %s", err.localizedDescription.UTF8String);
    if (!kc) return;
    constexpr int kSeqs = 6;
    id<MTLBuffer> out[kSeqs];
    for (auto& b : out) b = Zeroed(dev, be, 256);

    // (1) main seq A committed and held by an event: the async seqs complete and their completions
    // run in seq order; CompletedSeq stays below A
    {
        id<MTLSharedEvent> gate = [dev newSharedEvent];
        std::atomic<int> main_done{0};
        be.UseTarget(GnmCmdTarget::Main);
        be.BeginCmd(GnmCmdTarget::Main, @"async test main A", false);
        be.QueueWait(gate, 1);
        const uint64_t seq_a = ++g_seq;
        be.Commit(seq_a, Count, &main_done);
        AsyncDone done;
        RunAsyncSeqs(be, kc, out, kSeqs, done);
        CHECK(done.n.load() == kSeqs, "%d of %d async seqs completed (their completions ran) beside held main seq %llu",
              done.n.load(), kSeqs, (unsigned long long)seq_a);
        {
            std::lock_guard<std::mutex> lk(done.mu);
            for (size_t i = 0; i < done.order.size(); ++i)
                CHECK(done.order[i] == seq_a + 1 + i, "async completion %zu has seq %llu, want %llu", i,
                      (unsigned long long)done.order[i], (unsigned long long)(seq_a + 1 + i));
        }
        CHECK(main_done.load() == 0 && be.CompletedSeq() == seq_a - 1,
              "CompletedSeq %llu with main seq %llu held (want the prefix %llu)", (unsigned long long)be.CompletedSeq(),
              (unsigned long long)seq_a, (unsigned long long)(seq_a - 1));
        gate.signaledValue = 1;
        for (int i = 0; i < 2500 && main_done.load() == 0; ++i) usleep(2000);
        CHECK(main_done.load() == 1 && be.CompletedSeq() == g_seq, "after the gate: main seq A done %d, CompletedSeq %llu "
              "(want %llu)", main_done.load(), (unsigned long long)be.CompletedSeq(), (unsigned long long)g_seq);
    }
    // (2) main seq B open: it writes 0x5EED0001 (setBytes) into `written`, which is then evicted after
    // the last committed seq (+1, as ReleasedTexture does). Async seqs commit and complete past that
    // seq, recycling bytes chunks: B's bytes and B's buffer stay until B is committed and completed.
    {
        for (auto& b : out) memset(b.contents, 0, 256);
        id<MTLBuffer> written = Zeroed(dev, be, 256);
        be.UseTarget(GnmCmdTarget::Main);
        be.BeginCmd(GnmCmdTarget::Main, @"async test main B", false);
        be.BeginCompute(false);
        be.SetComputePipeline(kc);
        be.BindBuffer(GnmStage::Compute, 0, written, 0);
        const uint32_t main_v = 0x5EED0001u;
        be.BindBytes(GnmStage::Compute, 1, &main_v, sizeof(main_v));
        be.Dispatch(MTLSizeMake(1, 1, 1), MTLSizeMake(64, 1, 1));
        be.EndEncoder();
        be.Evict(written, g_seq + 1);
        AsyncDone done;
        RunAsyncSeqs(be, kc, out, kSeqs, done);
        CHECK(done.n.load() == kSeqs && be.CompletedSeq() == g_seq, "%d of %d async seqs completed, CompletedSeq %llu "
              "(want %llu)", done.n.load(), kSeqs, (unsigned long long)be.CompletedSeq(), (unsigned long long)g_seq);
        if (be.Kind() == GnmBackendKind::Metal4)
            CHECK(be.IsResident(written), "the buffer open main seq B writes left its residency set while async seqs "
                                          "completed");
        const uint64_t seq_b = ++g_seq;
        CHECK(CommitAndWait(be, seq_b), "main seq %llu failed", (unsigned long long)seq_b);
        CHECK(((const uint32_t*)written.contents)[0] == main_v, "main seq B wrote 0x%x into the evicted buffer, want "
              "0x%x (its bytes overwritten, or the buffer not resident)", ((const uint32_t*)written.contents)[0], main_v);
        // the next seq's start retires the eviction (Metal 4)
        be.BeginCmd(GnmCmdTarget::Main, @"async test after", false);
        const uint64_t s2 = ++g_seq;
        CHECK(CommitAndWait(be, s2), "seq %llu failed", (unsigned long long)s2);
        be.BeginCmd(GnmCmdTarget::Main, @"async test after 2", false);
        const uint64_t s3 = ++g_seq;
        CHECK(CommitAndWait(be, s3), "seq %llu failed", (unsigned long long)s3);
        if (be.Kind() == GnmBackendKind::Metal4)
            CHECK(!be.IsResident(written), "the evicted buffer is still resident after its main seq completed");
    }
}

// Two backends in a row destroyed while their seqs wait on the GPU for an event a thread signals
// 200 ms later; the second also has a command buffer open (never committed) at its destruction.
static void TestDestroyInFlight(id<MTLDevice> dev) {
    for (int round = 0; round < 2; ++round) {
        std::string why;
        std::unique_ptr<GnmBackend> be = MakeTestBackend(dev, &why);
        CHECK(be != nullptr, "round %d: no backend: %s", round, why.c_str());
        if (!be) return;
        const GnmBackendKind kind = be->Kind();
        id<MTLSharedEvent> gate = [dev newSharedEvent];
        static std::atomic<int> calls_of_round[2]; // static: a late completion of a failed run finds it alive
        std::atomic<int>& calls = calls_of_round[round];
        calls = 0;
        be->BeginCmd(GnmCmdTarget::Main, @"in flight 1", false);
        be->QueueWait(gate, 1);
        be->Commit(1, Count, &calls);
        be->BeginCmd(GnmCmdTarget::Main, @"in flight 2", false);
        be->Commit(2, Count, &calls);
        if (round == 1) be->BeginCmd(GnmCmdTarget::Main, @"left open", false);
        std::thread signaller([gate] {
            usleep(200000);
            gate.signaledValue = 1;
        });
        be.reset();
        const int at_destroy = calls.load();
        signaller.join();
        (void)kind;
        CHECK(at_destroy == 2, "round %d: the destructor returned before every completion ran (%d of 2)", round,
              at_destroy);
        for (int i = 0; i < 200 && calls.load() < 2; ++i) usleep(10000);
        CHECK(calls.load() == 2, "round %d: %d of 2 completions after the destruction", round, calls.load());
    }
    // A completion still running once CompletedSeq reached its seq (Metal 3 counts a seq when its
    // handler starts): the destructor waits for it to return, so the renderer state it uses is alive.
    std::string why;
    std::unique_ptr<GnmBackend> be = MakeTestBackend(dev, &why);
    CHECK(be != nullptr, "no backend: %s", why.c_str());
    if (!be) return;
    static std::atomic<int> slow_done{0};
    slow_done = 0;
    be->BeginCmd(GnmCmdTarget::Main, @"slow completion", false);
    be->Commit(1, [](void* p, const GnmCompletion&) {
        usleep(200000);
        static_cast<std::atomic<int>*>(p)->store(1);
    }, &slow_done);
    for (int i = 0; i < 500 && be->CompletedSeq() < 1; ++i) usleep(1000);
    CHECK(be->CompletedSeq() >= 1, "seq 1 not completed");
    be.reset();
    CHECK(slow_done.load() == 1, "the destructor returned while a completion was still running");
    for (int i = 0; i < 100 && slow_done.load() == 0; ++i) usleep(10000);
}

// What the renderer relies on (WaitAll's predicate, RunFences up to the seq): when a seq's
// completion runs, CompletedSeq() has reached it, and completions arrive in seq order.
struct Order {
    GnmBackend* be = nullptr;
    std::atomic<uint64_t> last{0};
    std::atomic<int> calls{0}, early{0}, out_of_order{0}, failed{0};
};
static void OrderFn(void* p, const GnmCompletion& c) {
    Order* o = static_cast<Order*>(p);
    if (o->be->CompletedSeq() < c.seq) o->early.fetch_add(1);
    if (c.seq != o->last.load() + 1) o->out_of_order.fetch_add(1);
    if (c.failed) o->failed.fetch_add(1);
    o->last.store(c.seq);
    o->calls.fetch_add(1);
}

static void TestCompletionOrder(GnmBackend& be) {
    constexpr int kSeqs = 3000;
    static Order o; // static: a late completion of a failed run finds it alive
    o.be = &be;
    o.last.store(g_seq);
    o.calls = 0;
    o.early = 0;
    o.out_of_order = 0;
    o.failed = 0;
    for (int i = 0; i < kSeqs; ++i) {
        CHECK(be.WaitForRoom(g_seq, kGnmMaxCommandBuffers, 5000), "WaitForRoom timed out at seq %d", i);
        be.BeginCmd(GnmCmdTarget::Main, nil, false);
        be.Commit(++g_seq, OrderFn, &o);
    }
    for (int i = 0; i < 500 && o.calls.load() < kSeqs; ++i) usleep(10000);
    CHECK(o.calls.load() == kSeqs, "%d of %d completions", o.calls.load(), kSeqs);
    CHECK(o.early.load() == 0, "%d of %d completions ran while CompletedSeq() was below their seq", o.early.load(), kSeqs);
    CHECK(o.out_of_order.load() == 0, "%d completions out of seq order", o.out_of_order.load());
    CHECK(o.failed.load() == 0, "%d failed seqs", o.failed.load());
}

// Metal 4: the feedback dispatch queue dies with its backend. The extra +1 Init gives the queue
// descriptor (it releases a property declared assign) would show here as a leak on an SDK that
// no longer releases it.
static void TestFeedbackQueueFreed(id<MTLDevice> dev) {
    __weak dispatch_queue_t weak = nil;
    @autoreleasepool {
        std::string why;
        std::unique_ptr<GnmBackend> be = MakeTestBackend(dev, &why);
        CHECK(be != nullptr, "no backend: %s", why.c_str());
        if (!be) return;
        weak = static_cast<Metal4Backend&>(*be).FeedbackQueue();
        CHECK(weak != nil, "no feedback queue");
        CHECK(CommitAndWait(*be, 1), "seq 1 failed");
        be.reset();
    }
    for (int i = 0; i < 100 && weak != nil; ++i) usleep(10000); // Metal's own blocks on it may still finish
    CHECK(weak == nil, "the feedback dispatch queue outlived its backend (leaked)");
}

// Metal 4: no allocator reset before its seq completed, reuse after it, bounded allocator count.
static void TestAllocators(id<MTLDevice> dev, Metal4Backend& be) {
    id<MTLSharedEvent> gate = [dev newSharedEvent];
    // s0 after "held" got its part: that may legitimately reuse the allocator of a completed seq
    be.BeginCmd(GnmCmdTarget::Main, @"held", false);
    const GnmBackendStats s0 = be.Stats();
    be.QueueWait(gate, 1); // everything committed from here on waits for the gate
    const uint64_t held = ++g_seq;
    be.Commit(held, Ignore, nullptr);
    be.BeginCmd(GnmCmdTarget::Main, @"behind", false);
    const uint64_t behind = ++g_seq;
    be.Commit(behind, Ignore, nullptr);
    be.BeginCmd(GnmCmdTarget::Main, @"third", false);
    const GnmBackendStats s1 = be.Stats();
    CHECK(be.CompletedSeq() < held, "the gate did not hold seq %llu (CompletedSeq %llu)", (unsigned long long)held,
          (unsigned long long)be.CompletedSeq());
    CHECK(s1.allocator_resets == s0.allocator_resets,
          "%llu allocator resets while seqs %llu and %llu had not completed",
          (unsigned long long)(s1.allocator_resets - s0.allocator_resets), (unsigned long long)held,
          (unsigned long long)behind);
    CHECK(be.PartsInUse() == 3, "%zu command buffer parts in use, want 3 (held, behind, third)", be.PartsInUse());
    gate.signaledValue = 1;
    const uint64_t third = ++g_seq;
    CHECK(CommitAndWait(be, third), "seq %llu failed", (unsigned long long)third);
    be.BeginCmd(GnmCmdTarget::Main, @"reuse", false);
    const GnmBackendStats s2 = be.Stats();
    CHECK(s2.allocator_resets > s1.allocator_resets, "no allocator reused after its seq completed");
    CHECK(s2.allocators_created == s1.allocators_created, "a new allocator while completed ones were free (%llu -> %llu)",
          (unsigned long long)s1.allocators_created, (unsigned long long)s2.allocators_created);
    CHECK(CommitAndWait(be, ++g_seq), "reuse seq failed");
    // 1000 seqs at the renderer's pace: WaitForRoom before each main command buffer, as the renderer does
    const uint64_t n0 = be.Stats().allocators_created;
    for (int i = 0; i < 1000; ++i) {
        CHECK(be.WaitForRoom(g_seq, kGnmMaxCommandBuffers, 5000), "WaitForRoom timed out at loop %d", i);
        be.BeginCmd(GnmCmdTarget::Main, nil, false);
        if (i % 100 == 99) CHECK(CommitAndWait(be, ++g_seq), "seq of loop %d failed", i);
        else be.Commit(++g_seq, Ignore, nullptr);
    }
    const GnmBackendStats s3 = be.Stats();
    CHECK(s3.allocators_created - n0 <= kGnmMaxCommandBuffers, "%llu allocators created for 1000 seqs",
          (unsigned long long)(s3.allocators_created - n0));
    CHECK(s3.allocators == s3.allocators_created - s3.allocators_released, "allocators alive %llu, created %llu, released %llu",
          (unsigned long long)s3.allocators, (unsigned long long)s3.allocators_created,
          (unsigned long long)s3.allocators_released);
    CHECK(s3.allocator_resets - s2.allocator_resets >= 1000 - kGnmMaxCommandBuffers, "only %llu resets over 1000 seqs",
          (unsigned long long)(s3.allocator_resets - s2.allocator_resets));
    // Stats().allocator_bytes (an atomic, any thread) follows the allocators' allocatedSize: after
    // seqs that recorded work, with no command buffer open, it equals their sum taken now
    id<MTLBuffer> buf = [dev newBufferWithLength:1 << 16 options:MTLResourceStorageModePrivate];
    be.MakeResident(buf, GnmResidencyClass::Builtin);
    for (int i = 0; i < 8; ++i) {
        be.BeginCmd(GnmCmdTarget::Main, @"fills", false);
        be.BeginCopies();
        for (uint32_t k = 0; k < 64; ++k) be.FillBuffer(buf, k * 1024, 1024, (uint8_t)(i + k));
        be.EndEncoder();
        CHECK(CommitAndWait(be, ++g_seq), "fill seq %d failed", i);
    }
    be.BeginCmd(GnmCmdTarget::Main, @"after fills", false); // recycles (resets) the completed parts
    CHECK(CommitAndWait(be, ++g_seq), "seq after the fills failed");
    const uint64_t walked = be.AllocatorBytesNow(), counted = be.Stats().allocator_bytes;
    CHECK(walked > 0, "the allocators report no allocated bytes after recorded work");
    CHECK(counted == walked, "Stats().allocator_bytes %llu, the allocators' allocatedSize sums to %llu",
          (unsigned long long)counted, (unsigned long long)walked);
}

// Metal 4: the allocator trim (docs/metal4-backend.md, "Command allocators"). On a backend of its own:
//  - 64 small seqs (one fill each) with up to 48 in flight: the trim's size estimate comes from
//    them (each first ran on a fresh allocator);
//  - kTrimLargeKeep + 4 large seqs held in flight together (gated), each 20 copy encoders with 50
//    barriers and a render pass, the first 4 with 40 (about twice as large): that many allocators
//    grow over the trim threshold;
//  - once they all completed, at the next part: at most kTrimLargeKeep allocators over the threshold
//    remain, at least 4 were released at their reset (the large list full; not the surplus
//    release), the 4 twice as large among them (the largest of the list and the candidate goes),
//    and the accounted bytes follow the releases; then 64 small seqs;
//  - at depth 48 again (48 small seqs held in flight by a gate) the released allocators are
//    replaced once, and 4 more such batches then create no allocator (no churn);
//  - then 2 x kTrimPeakWindow small seqs with at most 2 in flight: the free allocators beyond the
//    new in-flight peak plus kTrimPeakMargin are released.
static void TrimSmallSeq(Metal4Backend& be, id<MTLBuffer> buf, uint64_t* seq, uint64_t depth) {
    CHECK(be.WaitForRoom(*seq, depth, 5000), "WaitForRoom timed out at seq %llu", (unsigned long long)*seq);
    be.BeginCmd(GnmCmdTarget::Main, nil, false);
    be.BeginCopies();
    be.FillBuffer(buf, 0, 1024, (uint8_t)*seq);
    be.EndEncoder();
    be.Commit(++*seq, Ignore, nullptr);
}

static void TestAllocatorTrim(id<MTLDevice> dev) {
    Metal4Backend be;
    std::string why;
    CHECK(be.Init(dev, &why), "trim backend: %s", why.c_str());
    id<MTLBuffer> buf = [dev newBufferWithLength:1 << 16 options:MTLResourceStorageModePrivate];
    be.MakeResident(buf, GnmResidencyClass::Builtin);
    MTLTextureDescriptor* td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm
                                                                                  width:256 height:256 mipmapped:NO];
    td.storageMode = MTLStorageModePrivate;
    td.usage = MTLTextureUsageRenderTarget;
    id<MTLTexture> rt = [dev newTextureWithDescriptor:td];
    be.MakeResident(rt, GnmResidencyClass::Texture);
    uint64_t seq = 0;
    for (int i = 0; i < 64; ++i) TrimSmallSeq(be, buf, &seq, 48);
    CHECK(CommitAndWait(be, ++seq), "trim: warm-up seq failed");
    id<MTLSharedEvent> gate = [dev newSharedEvent];
    const int n_large = (int)Metal4Backend::kTrimLargeKeep + 4;
    for (int i = 0; i < n_large; ++i) {
        be.BeginCmd(GnmCmdTarget::Main, @"large", false);
        if (i == 0) be.QueueWait(gate, 1); // all stay in flight: each allocator holds a large part
        for (int e = 0; e < (i < 4 ? 40 : 20); ++e) {
            be.BeginCopies();
            for (int k = 0; k < 50; ++k) {
                be.FillBuffer(buf, (uint64_t)k * 1024, 1024, (uint8_t)k);
                be.Barrier(kGnmStageBlit, kGnmStageBlit, kGnmScopeBuffers);
            }
            be.EndEncoder();
        }
        GnmPassDesc pd;
        pd.color[0].tex = rt;
        pd.color[0].load = GnmLoad::Clear;
        CHECK(be.BeginRender(pd), "trim: large part's render pass");
        be.EndEncoder();
        be.Commit(++seq, Ignore, nullptr);
    }
    CHECK(be.LargeAllocatorsNow() >= (size_t)n_large, "trim: %zu allocators over the threshold (%llu KiB) after %d large parts",
          be.LargeAllocatorsNow(), (unsigned long long)(be.TrimThreshold() >> 10), n_large);
    const uint64_t bytes_large = be.Stats().allocator_bytes;
    gate.signaledValue = 1;
    // all large parts complete before the next part is taken: one Recycle resets them in a row,
    // so the large list fills and the rest are released at their reset (taken one by one, the
    // surplus release would see them first)
    CHECK(CommitAndWait(be, ++seq), "trim: seq after the large parts failed");
    be.BeginCmd(GnmCmdTarget::Main, nil, false); // recycles every completed part
    const GnmBackendStats s1 = be.Stats();
    CHECK(be.LargeAllocatorsNow() <= Metal4Backend::kTrimLargeKeep, "trim: %zu allocators over the threshold remain, want <= %zu",
          be.LargeAllocatorsNow(), Metal4Backend::kTrimLargeKeep);
    CHECK(be.FreeLargeCount() <= Metal4Backend::kTrimLargeKeep, "trim: large free list %zu", be.FreeLargeCount());
    CHECK(be.ReleasedAtReset() >= 4, "trim: %llu allocators released at their reset, want >= 4",
          (unsigned long long)be.ReleasedAtReset());
    // the 4 twice as large ones went: the kept ones are within a factor 1.5 of each other
    const auto kept = be.FreeSizes(true);
    CHECK(kept.second * 2 < kept.first * 3, "trim: the large list keeps %llu to %llu KiB (a twice as large part stayed)",
          (unsigned long long)(kept.first >> 10), (unsigned long long)(kept.second >> 10));
    CHECK(s1.allocator_bytes == be.AllocatorBytesNow(), "trim: accounted %llu bytes, the allocators hold %llu",
          (unsigned long long)s1.allocator_bytes, (unsigned long long)be.AllocatorBytesNow());
    CHECK(s1.allocator_bytes < bytes_large, "trim: %llu KiB of allocators after the releases, %llu KiB before",
          (unsigned long long)(s1.allocator_bytes >> 10), (unsigned long long)(bytes_large >> 10));
    CHECK(CommitAndWait(be, ++seq), "trim: seq failed");
    for (int i = 0; i < 64; ++i) TrimSmallSeq(be, buf, &seq, 48);
    CHECK(CommitAndWait(be, ++seq), "trim: small seqs after the large parts failed");
    // back at depth 48, the released allocators are replaced once; after that, none is created.
    // The depth is exact (a gate holds all 48 in flight): at the GPU's own pace the depth a batch
    // reaches depends on timing, and a deeper second batch would need allocators the first did not.
    auto gated_batch = [&](const char* what) {
        id<MTLSharedEvent> hold = [dev newSharedEvent];
        for (int i = 0; i < 48; ++i) {
            be.BeginCmd(GnmCmdTarget::Main, nil, false);
            if (i == 0) be.QueueWait(hold, 1);
            be.BeginCopies();
            be.FillBuffer(buf, 0, 1024, (uint8_t)i);
            be.EndEncoder();
            be.Commit(++seq, Ignore, nullptr);
        }
        hold.signaledValue = 1;
        CHECK(CommitAndWait(be, ++seq), "trim: %s batch failed", what);
    };
    gated_batch("first steady");
    const uint64_t created_steady = be.Stats().allocators_created;
    for (int k = 0; k < 4; ++k) gated_batch("steady");
    const GnmBackendStats s2 = be.Stats();
    CHECK(s2.allocators_created == created_steady, "trim: %llu allocators created by 4 batches of 48 at a steady depth (churn)",
          (unsigned long long)(s2.allocators_created - created_steady));
    const uint64_t alive_deep = s2.allocators;
    for (uint64_t i = 0; i < 2 * Metal4Backend::kTrimPeakWindow + 64; ++i) TrimSmallSeq(be, buf, &seq, 2);
    CHECK(CommitAndWait(be, ++seq), "trim: shallow seq failed");
    be.BeginCmd(GnmCmdTarget::Main, nil, false);
    const GnmBackendStats s3 = be.Stats();
    CHECK(s3.allocators <= 2 + 2 + Metal4Backend::kTrimPeakMargin,
          "trim: %llu allocators alive at 2 seqs in flight (%llu at 48), want <= %zu", (unsigned long long)s3.allocators,
          (unsigned long long)alive_deep, 2 + 2 + Metal4Backend::kTrimPeakMargin);
    CHECK(s3.allocator_bytes == be.AllocatorBytesNow(), "trim: accounted %llu bytes after the surplus release, held %llu",
          (unsigned long long)s3.allocator_bytes, (unsigned long long)be.AllocatorBytesNow());
    CHECK(CommitAndWait(be, ++seq), "trim: last seq failed");
    printf("gnm_backend_cmd_test: trim: threshold %llu KiB; %llu KiB with 16 large parts, %llu KiB after; "
           "%llu alive at depth 48, %llu at depth 2; %llu created, %llu released\n",
           (unsigned long long)(be.TrimThreshold() >> 10), (unsigned long long)(bytes_large >> 10),
           (unsigned long long)(s1.allocator_bytes >> 10), (unsigned long long)alive_deep,
           (unsigned long long)s3.allocators, (unsigned long long)s3.allocators_created,
           (unsigned long long)s3.allocators_released);
}

// Metal 4: which allocators the trim learns from and reuses. 24 compute-only parts (one fill)
// and 24 parts with a render pass (about 2.4 MiB) held in flight together, each on a fresh
// allocator: only the compute-only ones feed the size median, so the threshold stays at its
// minimum (with the render parts sampled, the median is a render part's size and the threshold
// twice that). Then a compute part of 40 fills with barriers (a small allocator larger than the
// others) and, once everything completed, a compute part: it takes the smallest small allocator.
static void TestAllocatorChoice(id<MTLDevice> dev) {
    Metal4Backend be;
    std::string why;
    CHECK(be.Init(dev, &why), "choice backend: %s", why.c_str());
    id<MTLBuffer> buf = [dev newBufferWithLength:1 << 16 options:MTLResourceStorageModePrivate];
    be.MakeResident(buf, GnmResidencyClass::Builtin);
    MTLTextureDescriptor* td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm
                                                                                  width:256 height:256 mipmapped:NO];
    td.storageMode = MTLStorageModePrivate;
    td.usage = MTLTextureUsageRenderTarget;
    id<MTLTexture> rt = [dev newTextureWithDescriptor:td];
    be.MakeResident(rt, GnmResidencyClass::Texture);
    uint64_t seq = 0;
    id<MTLSharedEvent> hold = [dev newSharedEvent];
    for (int i = 0; i < 48; ++i) {
        be.BeginCmd(GnmCmdTarget::Main, nil, false);
        if (i == 0) be.QueueWait(hold, 1);
        if (i % 2) {
            GnmPassDesc pd;
            pd.color[0].tex = rt;
            pd.color[0].load = GnmLoad::Clear;
            CHECK(be.BeginRender(pd), "choice: render pass");
        } else {
            be.BeginCopies();
            be.FillBuffer(buf, 0, 1024, (uint8_t)i);
        }
        be.EndEncoder();
        be.Commit(++seq, Ignore, nullptr);
    }
    hold.signaledValue = 1;
    CHECK(CommitAndWait(be, ++seq), "choice: batch failed");
    CHECK(be.TrimThreshold() == Metal4Backend::kTrimMinBytes, "choice: threshold %llu KiB, want %llu (render parts sampled?)",
          (unsigned long long)(be.TrimThreshold() >> 10), (unsigned long long)(Metal4Backend::kTrimMinBytes >> 10));
    be.BeginCmd(GnmCmdTarget::Main, nil, false);
    be.BeginCopies();
    for (int k = 0; k < 40; ++k) {
        be.FillBuffer(buf, (uint64_t)k * 1024, 1024, (uint8_t)k);
        be.Barrier(kGnmStageBlit, kGnmStageBlit, kGnmScopeBuffers);
    }
    be.EndEncoder();
    CHECK(CommitAndWait(be, ++seq), "choice: medium part failed");
    be.BeginCmd(GnmCmdTarget::Main, nil, false); // recycles everything, then takes one
    const auto small = be.FreeSizes(false);
    const uint64_t got = be.OpenAllocatorBytes(GnmCmdTarget::Main);
    CHECK(small.second > small.first, "choice: the small allocators are all %llu bytes (no larger one to avoid)",
          (unsigned long long)small.first);
    CHECK(got <= small.first, "choice: a compute part took a %llu-byte allocator, the smallest free is %llu",
          (unsigned long long)got, (unsigned long long)small.first);
    CHECK(CommitAndWait(be, ++seq), "choice: last seq failed");
    printf("gnm_backend_cmd_test: choice: threshold %llu KiB; small allocators %llu..%llu bytes, took %llu\n",
           (unsigned long long)(be.TrimThreshold() >> 10), (unsigned long long)small.first,
           (unsigned long long)small.second, (unsigned long long)got);
}

// Metal 4: the trim's prediction of a part's kind. 30 frames of TLOU's shape (the size probe in
// docs/metal4-backend.md, "Command allocators"): 46 parts, a run of 6 with a render pass (about 2.4
// MiB each, over the threshold) starting 0, 1 or 2 parts into the frame (the run shifts from frame
// to frame, as TLOU's do), the others compute-only (one fill), the whole frame held in flight by a
// gate, NoteFrameEnd after each frame. A part is predicted to have a render pass when the previous
// frame had one within kFrameSlack positions of it, so after 10 frames of warm-up no render part
// lands on a small allocator and no allocator is created. Predicting from the exact position, a
// shifted run's first parts grow small allocators, which the reset releases (each replacement a
// fresh allocator whose memory is faulted in again): 6 in 20 frames; from the previous part only,
// one per frame; without any prediction, 6 per frame. The allocators over the threshold stay within
// the render parts in flight plus the large list.
static void TestAllocatorPrediction(id<MTLDevice> dev) {
    Metal4Backend be;
    std::string why;
    CHECK(be.Init(dev, &why), "prediction backend: %s", why.c_str());
    id<MTLBuffer> buf = [dev newBufferWithLength:1 << 16 options:MTLResourceStorageModePrivate];
    be.MakeResident(buf, GnmResidencyClass::Builtin);
    MTLTextureDescriptor* td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm
                                                                                  width:256 height:256 mipmapped:NO];
    td.storageMode = MTLStorageModePrivate;
    td.usage = MTLTextureUsageRenderTarget;
    id<MTLTexture> rt = [dev newTextureWithDescriptor:td];
    be.MakeResident(rt, GnmResidencyClass::Texture);
    uint64_t seq = 0, created_warm = 0;
    for (int f = 0; f < 30; ++f) {
        if (f == 10) created_warm = be.Stats().allocators_created;
        // a gate holds the whole frame in flight, so the depth (and the allocators it needs) does
        // not depend on the GPU's pace
        id<MTLSharedEvent> hold = [dev newSharedEvent];
        be.BeginCmd(GnmCmdTarget::Main, nil, false);
        be.QueueWait(hold, 1);
        be.Commit(++seq, Ignore, nullptr);
        // the run starts 0, 1 or 2 parts into the frame: frames shift by up to 2 parts
        for (int i = 0; i < f % 3; ++i) TrimSmallSeq(be, buf, &seq, 48);
        for (int i = 0; i < 6; ++i) {
            CHECK(be.WaitForRoom(seq, 48, 5000), "prediction: WaitForRoom timed out");
            be.BeginCmd(GnmCmdTarget::Main, nil, false);
            GnmPassDesc pd;
            pd.color[0].tex = rt;
            pd.color[0].load = GnmLoad::Clear;
            CHECK(be.BeginRender(pd), "prediction: render pass");
            be.EndEncoder();
            be.Commit(++seq, Ignore, nullptr);
        }
        for (int i = f % 3; i < 40; ++i) TrimSmallSeq(be, buf, &seq, 48);
        hold.signaledValue = 1;
        CHECK(CommitAndWait(be, ++seq), "prediction: frame %d failed", f);
        be.NoteFrameEnd(); // the renderer's present
    }
    CHECK(CommitAndWait(be, ++seq), "prediction: last seq failed");
    const GnmBackendStats s = be.Stats();
    const uint64_t created = s.allocators_created - created_warm;
    CHECK(created == 0, "prediction: %llu allocators created in 20 frames (want 0)", (unsigned long long)created);
    CHECK(be.LargeAllocatorsNow() <= 7 + Metal4Backend::kTrimLargeKeep,
          "prediction: %zu allocators over the threshold", be.LargeAllocatorsNow());
    printf("gnm_backend_cmd_test: prediction: %llu created in 20 frames; %llu alive (%llu KiB), %zu over the threshold\n",
           (unsigned long long)created, (unsigned long long)s.allocators, (unsigned long long)(s.allocator_bytes >> 10),
           be.LargeAllocatorsNow());
}

// Metal 4: WaitForRoom gives up on a GPU that completes nothing.
static void TestWaitForRoom(id<MTLDevice> dev, Metal4Backend& be) {
    id<MTLSharedEvent> gate = [dev newSharedEvent];
    const uint64_t first = g_seq + 1;
    be.BeginCmd(GnmCmdTarget::Main, @"stalled", false);
    be.QueueWait(gate, 1);
    be.Commit(++g_seq, Ignore, nullptr);
    for (uint64_t i = 1; i < 4; ++i) {
        be.BeginCmd(GnmCmdTarget::Main, nil, false);
        be.Commit(++g_seq, Ignore, nullptr);
    }
    CHECK(!be.WaitForRoom(g_seq, 4, 300), "WaitForRoom returned with 4 of 4 seqs stalled");
    gate.signaledValue = 1;
    CHECK(be.WaitForRoom(g_seq, 4, 2000), "WaitForRoom timed out after the GPU went on");
    CHECK(be.CompletedSeq() >= first, "no progress");
    for (int i = 0; i < 200 && be.CompletedSeq() < g_seq; ++i) usleep(10000);
    CHECK(be.CompletedSeq() == g_seq, "CompletedSeq %llu, %llu committed", (unsigned long long)be.CompletedSeq(),
          (unsigned long long)g_seq);
}

// Child mode --split-on-upload: work recorded on Upload, then a wait with Upload current. Returns
// 0 if that did not abort.
static int SplitOnUpload() {
    id<MTLDevice> dev = MTLCreateSystemDefaultDevice();
    std::string why;
    std::unique_ptr<GnmBackend> be = MakeTestBackend(dev, &why);
    if (!be) return 3;
    id<MTLSharedEvent> ev = [dev newSharedEvent];
    be->BeginCmd(GnmCmdTarget::Main, @"main", false);
    be->UseTarget(GnmCmdTarget::Upload);
    be->BeginCmd(GnmCmdTarget::Upload, @"upload", false);
    be->BeginCopies();
    be->EndEncoder();
    be->QueueWait(ev, 1);
    return 0;
}

extern char** environ;

static void TestSplitOnUploadFatal() {
    char path[4096];
    uint32_t size = sizeof(path);
    CHECK(_NSGetExecutablePath(path, &size) == 0, "no executable path");
    int fds[2];
    CHECK(pipe(fds) == 0, "pipe");
    posix_spawn_file_actions_t fa;
    posix_spawn_file_actions_init(&fa);
    posix_spawn_file_actions_adddup2(&fa, fds[1], 2);
    posix_spawn_file_actions_addclose(&fa, fds[0]);
    char* argv[] = {path, (char*)"--split-on-upload", nullptr};
    pid_t pid = 0;
    const int rc = posix_spawn(&pid, path, &fa, nullptr, argv, environ); // with PS4_GNM_METAL=4
    posix_spawn_file_actions_destroy(&fa);
    close(fds[1]);
    std::string err;
    char buf[512];
    for (ssize_t n; (n = read(fds[0], buf, sizeof(buf))) > 0;) err.append(buf, (size_t)n);
    close(fds[0]);
    int st = 0;
    CHECK(rc == 0 && waitpid(pid, &st, 0) == pid, "spawn failed");
    CHECK(WIFEXITED(st) && WEXITSTATUS(st) == kAbortExit, "a split with Upload current did not abort (status 0x%x)", st);
    CHECK(err.find("splits the seq on the Upload target") != std::string::npos, "no FATAL message (stderr: %s)",
          err.c_str());
}

// Views dropped by the caller (their last reference) before the draw is encoded and before the
// commit: a sampled view (bound, then dropped), a colour attachment that is a view of the render
// target, and the source of a texture copy. After the drops, 256 views of another texture are made
// and kept until the seq completed: a dead view's gpuResourceID can be handed to one of them, and
// the argument table would then point at the other texture (or at nothing). Checked every round:
//  - each view object (weak references): alive after the drop, after the work was encoded, and
//    after the commit while the GPU is held back by a queue wait on an event (the seq in flight);
//    and released once the seq completed and the backend recycled the part (no leak). This is the
//    deterministic check: the driver does not reliably reuse a dead view's ID (without the keep
//    list the texel checks below still passed on an M1 Pro; the lifetime checks fail at once);
//  - the pass sampled the dropped view's texels into the attachment, and the copy copied them.
static void TestDroppedViews(id<MTLDevice> dev, GnmBackend& be) {
    GnmUtil util;
    std::string why;
    CHECK(MakeGnmUtil(dev, &util, &why) && util.present, "util passes: %s", why.c_str());
    if (!util.present) return;
    id<MTLTexture> src = SharedRgba(dev, be, 0xFF4080C0u);   // r = 0xC0, g = 0x80, b = 0x40
    id<MTLTexture> decoy = SharedRgba(dev, be, 0xFF00FF00u); // g = 0xFF
    id<MTLTexture> copied = SharedRgba(dev, be, 0);
    MTLTextureDescriptor* td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                                                                                  width:8 height:8 mipmapped:NO];
    td.usage = MTLTextureUsageRenderTarget;
    td.storageMode = MTLStorageModeShared;
    id<MTLTexture> rt = [dev newTextureWithDescriptor:td];
    be.MakeResident(rt, GnmResidencyClass::Texture);
    constexpr int kRounds = 16, kViews = 3; // sampled, attachment, copy source
    uint32_t wrong = 0, last = 0, wrong_copy = 0, dead_early = 0, leaked = 0;
    for (int round = 0; round < kRounds; ++round) {
        __weak id<MTLTexture> weak[kViews] = {nil, nil, nil};
        auto dead = [&](int made) { // of the first `made` views
            uint32_t n = 0;
            @autoreleasepool {
                for (int v = 0; v < made; ++v) n += weak[v] == nil;
            }
            return n;
        };
        NSMutableArray* decoys = [NSMutableArray arrayWithCapacity:256];
        id<MTLSharedEvent> gate = [dev newSharedEvent];
        be.BeginCmd(GnmCmdTarget::Main, @"dropped views", false);
        be.QueueWait(gate, 1); // the work runs only once the views were checked in flight
        GnmPassDesc pd;
        pd.color[0].load = GnmLoad::DontCare;
        @autoreleasepool {
            id<MTLTexture> att = [rt newTextureViewWithPixelFormat:MTLPixelFormatBGRA8Unorm];
            pd.color[0].tex = att;
            CHECK(be.BeginRender(pd), "no render encoder");
            weak[1] = att;
            pd.color[0].tex = nil;
            att = nil;
        }
        be.SetRenderPipeline(util.present);
        @autoreleasepool {
            id<MTLTexture> view = [src newTextureViewWithPixelFormat:MTLPixelFormatRGBA8Unorm];
            be.BindTexture(GnmStage::Fragment, 0, view);
            weak[0] = view;
            view = nil;
        }
        dead_early += dead(2); // the copy source is not made yet
        @autoreleasepool {
            for (int i = 0; i < 256; ++i) [decoys addObject:[decoy newTextureViewWithPixelFormat:MTLPixelFormatRGBA8Unorm]];
        }
        GnmDraw d;
        d.count = 3;
        be.Draw(d);
        be.EndEncoder();
        be.BeginCopies();
        @autoreleasepool {
            id<MTLTexture> from = [src newTextureViewWithPixelFormat:MTLPixelFormatRGBA8Unorm];
            be.CopyTexture(from, copied);
            weak[2] = from;
            from = nil;
        }
        be.EndEncoder();
        const uint64_t seq = ++g_seq;
        dead_early += dead(kViews); // after the work was encoded
        dispatch_semaphore_t done = dispatch_semaphore_create(0);
        be.Commit(seq, [](void* p, const GnmCompletion&) { dispatch_semaphore_signal((__bridge dispatch_semaphore_t)p); },
                  (__bridge void*)done);
        usleep(2000);
        dead_early += dead(kViews); // committed, held behind the gate
        gate.signaledValue = 1;
        CHECK(dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC)) == 0,
              "dropped views seq %llu did not complete", (unsigned long long)seq);
        const uint32_t got = Pixel(rt);
        if (got != 0xFFC08040u) wrong++, last = got;
        wrong_copy += Pixel(copied) != 0xFF4080C0u;
        decoys = nil;
        // released after completion: an empty seq makes Metal 4 recycle the completed part; Metal 3's
        // command buffer drops its references after its completion handlers
        for (int i = 0; i < 2; ++i) {
            be.BeginCmd(GnmCmdTarget::Main, @"recycle", false);
            CHECK(CommitAndWait(be, ++g_seq), "recycle seq failed");
        }
        uint32_t alive = kViews;
        for (int i = 0; i < 200 && alive; ++i) {
            alive = kViews - dead(kViews);
            if (alive) usleep(10000);
        }
        leaked += alive;
    }
    CHECK(!dead_early, "views dropped after their use were freed before their seq completed (%u of %d checks)", dead_early,
          (2 + 2 * kViews) * kRounds);
    CHECK(!wrong, "a view dropped after its bind: %u of %d passes read %08x, want ffc08040 (the view's texels)", wrong,
          kRounds, last);
    CHECK(!wrong_copy, "a copy from a view dropped before the commit: %u of %d copies wrong", wrong_copy, kRounds);
    CHECK(!leaked, "dropped views still alive 2 s after their seq completed (%u of %d)", leaked, kViews * kRounds);
    be.Evict(rt, g_seq);
}

int main(int argc, char** argv) {
    if (argc == 2 && !strcmp(argv[1], "--split-on-upload")) {
        @autoreleasepool {
            ExitOnAbort();
            return SplitOnUpload();
        }
    }
    @autoreleasepool {
        id<MTLDevice> dev = MTLCreateSystemDefaultDevice();
        const char* env = getenv("PS4_GNM_METAL");
        if (dev && env && !strcmp(env, "4") && !RequireMetal4(dev, "gnm_backend_cmd_test")) return 0;
        std::string why;
        std::unique_ptr<GnmBackend> be = dev ? MakeTestBackend(dev, &why) : nullptr;
        if (!be) {
            printf("gnm_backend_cmd_test: FAIL: no backend: %s\n", dev ? why.c_str() : "no Metal device");
            return 1;
        }
        printf("gnm_backend_cmd_test: backend %s\n", BackendName(be->Kind()));
        TestEncoderTracking(*be);
        TestEventOrder(dev, *be);
        TestCompletionOrder(*be);
        TestSplit(dev, *be);
        TestSignalThenWork(dev, *be);
        TestSignalAfterUploads(dev, *be);
        TestComputeOps(dev, *be);
        TestDroppedViews(dev, *be);
        TestAsyncQueue(dev, *be);
        if (be->Kind() == GnmBackendKind::Metal4) {
            Metal4Backend& m4 = static_cast<Metal4Backend&>(*be);
            CHECK(m4.Residency().Set(GnmResidencyClass::Guest) != nil, "no residency sets after Init");
            TestAllocators(dev, m4);
            TestAllocatorTrim(dev);
            TestAllocatorPrediction(dev);
            TestAllocatorChoice(dev);
            TestWaitForRoom(dev, m4);
            TestSplitOnUploadFatal();
        }
        be.reset();
        TestDestroyInFlight(dev);
        if (env && !strcmp(env, "4")) TestFeedbackQueueFreed(dev);
    }
    printf("gnm_backend_cmd_test: %s\n", g_fail ? "FAIL" : "PASS");
    return g_fail ? 1 : 0;
}
