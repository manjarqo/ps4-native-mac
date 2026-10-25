// Guest windows that alias (docs/gnm-ordering.md, "Aliasing guest windows"): the renderer's no-copy windows
// over guest memory are keyed by base and window count, so a range crossing a 64 MiB boundary gets
// a two-window buffer and a range inside the second window another buffer over the same memory.
// Metal 3 orders encoders by object: accesses of the same bytes through the two buffers were not
// ordered. The renderer now has each encoder that accesses a window update a fence at its end
// (AccessFence) and has a later encoder that accesses the same bytes through another window wait
// for it (WaitAccessFence). Here, on the backend PS4_GNM_METAL selects, through `wide` (the
// two-window buffer) and `narrow` (the one-window buffer), in the same seq and in the next one
// behind a gate:
//  - compute: a slow compute write through wide, a compute copy through narrow (RAW);
//  - blit: the same write, a blit copy through narrow;
//  - vertex: the same write, read by a render pass's vertex shader through narrow (a point per
//    word, stored to a render target);
//  - fragment: a slow fragment shader writes through wide (a full-screen pass), a compute copy
//    through narrow;
//  - blit write: a blit fills 60 MiB through wide, ending at the words, a compute copy reads
//    them through narrow;
//  - war: a slow compute pass reads through narrow (late in each thread), then a blit fill
//    writes the same bytes through wide (write after read: the read must see the old bytes).
// Every ordered try must be right. The teeth: unordered, on Metal 3 at least one of 8 tries of
// each case goes wrong. Metal 4 leaves AccessFence at 0: its encoder-start barriers order the
// tries (with PS4_GNM_MTL4_NO_BARRIERS=1 the tries fail).
#include <sys/mman.h>

#include <algorithm>
#include <vector>

#include "backend_harness.h"
#include "ps4_gnm_guest_window.h"

using namespace ps4gnm;

static const char* kMsl = R"(
#include <metal_stdlib>
using namespace metal;
kernel void slow_write(device uint* out [[buffer(0)]], constant uint& n [[buffer(1)]],
                       uint i [[thread_position_in_grid]]) {
    uint v = i * 131u + 7u;
    for (uint k = 0; k < n; ++k) v = v * 1664525u + 1013904223u;
    out[i] = v;
}
kernel void copy_words(device const uint* src [[buffer(0)]], device uint* dst [[buffer(1)]],
                       uint i [[thread_position_in_grid]]) {
    dst[i] = src[i];
}
// reads src[i] only after the loop (the index depends on its result)
kernel void slow_read(device const uint* src [[buffer(0)]], device uint* dst [[buffer(1)]],
                      constant uint& n [[buffer(2)]], uint i [[thread_position_in_grid]]) {
    uint v = i * 131u + 7u;
    for (uint k = 0; k < n; ++k) v = v * 1664525u + 1013904223u;
    dst[i] = src[v == 7u ? 0u : i];
}
struct PV {
    float4 pos [[position]];
    float size [[point_size]];
    uint val [[flat]];
};
vertex PV point_vs(uint vid [[vertex_id]], device const uint* src [[buffer(0)]]) {
    PV o;
    const float x = float(vid % 64u), y = float(vid / 64u);
    o.pos = float4((x + 0.5) / 32.0 - 1.0, 1.0 - (y + 0.5) / 32.0, 0.0, 1.0);
    o.size = 1.0;
    o.val = src[vid];
    return o;
}
fragment uint4 point_fs(PV in [[stage_in]]) { return uint4(in.val, 0, 0, 1); }
struct VOut { float4 pos [[position]]; };
vertex VOut tri_vs(uint vid [[vertex_id]]) {
    VOut o;
    float2 uv = float2((vid << 1) & 2, vid & 2);
    o.pos = float4(uv * 2.0 - 1.0, 0.0, 1.0);
    return o;
}
fragment uint4 slow_write_fs(VOut in [[stage_in]], device uint* out [[buffer(0)]], constant uint& n [[buffer(1)]]) {
    const uint2 p = uint2(in.pos.xy);
    const uint i = p.y * 64u + p.x;
    uint v = i * 131u + 7u;
    for (uint k = 0; k < n; ++k) v = v * 1664525u + 1013904223u;
    out[i] = v;
    return uint4(v, 0, 0, 1);
}
)";

constexpr uint32_t kWords = 4096, kSide = 64, kLoop = 200000, kFillByte = 0x5A;
// the bytes: in the second window, reached at this offset through the two-window buffer
constexpr uint64_t kAt = PS4_GNM_WINDOW_SIZE + 0x100000;

static uint32_t Expected(uint32_t i) {
    uint32_t v = i * 131u + 7u;
    for (uint32_t k = 0; k < kLoop; ++k) v = v * 1664525u + 1013904223u;
    return v;
}

enum class Case { Compute, Blit, Vertex, Fragment, BlitWrite, War };
constexpr uint64_t kFillLen = 60ull << 20; // the blit write's fill, ending at the words' end
static const char* Name(Case c) {
    switch (c) {
    case Case::Compute: return "compute";
    case Case::Blit: return "blit";
    case Case::Vertex: return "vertex";
    case Case::Fragment: return "fragment";
    case Case::BlitWrite: return "blit write";
    case Case::War: return "war";
    }
    return "?";
}

struct Ctx {
    GnmBackend* be;
    id<MTLComputePipelineState> write, copy, slow_read;
    id<MTLRenderPipelineState> points, frag_write;
    uint8_t* mem;
    id<MTLBuffer> wide, narrow, out;
    id<MTLTexture> rt;
    std::vector<uint32_t> want;
    uint64_t seq = 0;
};

// One try; ordered: the renderer's calls. split: the second access in the next seq, both seqs
// held behind a gate until it is committed. Returns the wrong words.
static uint32_t Try(Ctx& c, Case k, bool ordered, bool split) {
    GnmBackend& be = *c.be;
    const uint32_t n = kLoop;
    const uint64_t off_wide = kAt - PS4_GNM_WINDOW0_BASE, off_narrow = kAt - PS4_GNM_WINDOW_SIZE;
    if (k == Case::War) memcpy(c.mem + kAt, c.want.data(), kWords * 4);
    else memset(c.mem + kAt, 0, kWords * 4);
    memset(c.out.contents, 0, kWords * 4);
    std::vector<uint32_t> zero(kWords, 0);
    [c.rt replaceRegion:MTLRegionMake2D(0, 0, kSide, kSide) mipmapLevel:0 withBytes:zero.data() bytesPerRow:kSide * 4];
    id<MTLSharedEvent> gate = split ? [be.Device() newSharedEvent] : nil;
    be.BeginCmd(GnmCmdTarget::Main, @"alias", false);
    if (gate) be.QueueWait(gate, 1);
    // the first access
    if (k == Case::Fragment) {
        GnmPassDesc pd;
        pd.color[0].tex = c.rt;
        pd.color[0].load = GnmLoad::DontCare;
        if (!be.BeginRender(pd)) return kWords;
        be.SetRenderPipeline(c.frag_write);
        be.BindBuffer(GnmStage::Fragment, 0, c.wide, off_wide);
        be.BindBytes(GnmStage::Fragment, 1, &n, sizeof(n));
    } else if (k == Case::BlitWrite) {
        be.BeginCopies();
    } else if (k == Case::War) {
        be.BeginCompute(false);
        be.SetComputePipeline(c.slow_read);
        be.BindBuffer(GnmStage::Compute, 0, c.narrow, off_narrow);
        be.BindBuffer(GnmStage::Compute, 1, c.out, 0);
        be.BindBytes(GnmStage::Compute, 2, &n, sizeof(n));
    } else {
        be.BeginCompute(false);
        be.SetComputePipeline(c.write);
        be.BindBuffer(GnmStage::Compute, 0, c.wide, off_wide);
        be.BindBytes(GnmStage::Compute, 1, &n, sizeof(n));
    }
    const uint64_t fence = ordered ? be.AccessFence() : 0;
    if (k == Case::Fragment) {
        GnmDraw d;
        d.count = 3;
        be.Draw(d);
    } else if (k == Case::BlitWrite) {
        be.FillBuffer(c.wide, off_wide + kWords * 4 - kFillLen, kFillLen, kFillByte);
    } else {
        be.Dispatch(MTLSizeMake(kWords / 64, 1, 1), MTLSizeMake(64, 1, 1));
    }
    be.EndEncoder();
    if (split) {
        be.Commit(++c.seq, [](void*, const GnmCompletion&) {}, nullptr);
        be.BeginCmd(GnmCmdTarget::Main, @"alias second", false);
    }
    // the second access, through the other window
    switch (k) {
    case Case::Compute:
    case Case::Fragment:
    case Case::BlitWrite:
        be.BeginCompute(false);
        be.SetComputePipeline(c.copy);
        if (ordered) be.WaitAccessFence(fence);
        be.BindBuffer(GnmStage::Compute, 0, c.narrow, off_narrow);
        be.BindBuffer(GnmStage::Compute, 1, c.out, 0);
        be.Dispatch(MTLSizeMake(kWords / 64, 1, 1), MTLSizeMake(64, 1, 1));
        break;
    case Case::Blit:
        be.BeginCopies();
        if (ordered) be.WaitAccessFence(fence);
        be.CopyBuffer(c.narrow, off_narrow, c.out, 0, kWords * 4);
        break;
    case Case::Vertex: {
        GnmPassDesc pd;
        pd.color[0].tex = c.rt;
        pd.color[0].load = GnmLoad::Load;
        if (!be.BeginRender(pd)) return kWords;
        be.SetRenderPipeline(c.points);
        if (ordered) be.WaitAccessFence(fence);
        be.BindBuffer(GnmStage::Vertex, 0, c.narrow, off_narrow);
        GnmDraw d;
        d.prim = MTLPrimitiveTypePoint;
        d.count = kWords;
        be.Draw(d);
        break;
    }
    case Case::War:
        be.BeginCopies();
        if (ordered) be.WaitAccessFence(fence);
        be.FillBuffer(c.wide, off_wide, kWords * 4, kFillByte);
        break;
    }
    be.EndEncoder();
    if (gate) gate.signaledValue = 1;
    if (!CommitAndWait(be, ++c.seq)) return kWords;
    std::vector<uint32_t> got(kWords);
    if (k == Case::Vertex)
        [c.rt getBytes:got.data() bytesPerRow:kSide * 4 fromRegion:MTLRegionMake2D(0, 0, kSide, kSide) mipmapLevel:0];
    else
        memcpy(got.data(), c.out.contents, kWords * 4);
    const uint32_t filled = kFillByte * 0x01010101u;
    uint32_t bad = 0;
    for (uint32_t i = 0; i < kWords; ++i) bad += got[i] != (k == Case::BlitWrite ? filled : c.want[i]);
    return bad;
}

int main() {
    @autoreleasepool {
        id<MTLDevice> dev = MTLCreateSystemDefaultDevice();
        const char* env = getenv("PS4_GNM_METAL");
        if (dev && env && !strcmp(env, "4") && !RequireMetal4(dev, "gnm_backend_alias_test")) return 0;
        std::string why;
        std::unique_ptr<GnmBackend> be = dev ? MakeTestBackend(dev, &why) : nullptr;
        if (!be) {
            printf("gnm_backend_alias_test: FAIL: %s\n", why.c_str());
            return 1;
        }
        printf("gnm_backend_alias_test: backend %s\n", BackendName(be->Kind()));
        NSError* e = nil;
        id<MTLLibrary> lib = [dev newLibraryWithSource:[NSString stringWithUTF8String:kMsl] options:nil error:&e];
        CHECK(lib, "library: %s", e.localizedDescription.UTF8String);
        if (g_fail) return 1;
        Ctx c;
        c.be = be.get();
        c.write = [dev newComputePipelineStateWithFunction:[lib newFunctionWithName:@"slow_write"] error:&e];
        c.copy = [dev newComputePipelineStateWithFunction:[lib newFunctionWithName:@"copy_words"] error:&e];
        c.slow_read = [dev newComputePipelineStateWithFunction:[lib newFunctionWithName:@"slow_read"] error:&e];
        MTLRenderPipelineDescriptor* d = [MTLRenderPipelineDescriptor new];
        d.vertexFunction = [lib newFunctionWithName:@"point_vs"];
        d.fragmentFunction = [lib newFunctionWithName:@"point_fs"];
        d.colorAttachments[0].pixelFormat = MTLPixelFormatR32Uint;
        c.points = [dev newRenderPipelineStateWithDescriptor:d error:&e];
        d.vertexFunction = [lib newFunctionWithName:@"tri_vs"];
        d.fragmentFunction = [lib newFunctionWithName:@"slow_write_fs"];
        c.frag_write = [dev newRenderPipelineStateWithDescriptor:d error:&e];
        CHECK(c.write && c.copy && c.slow_read && c.points && c.frag_write, "pipelines");
        const uint64_t mem_size = 2 * PS4_GNM_WINDOW_SIZE;
        c.mem = (uint8_t*)mmap(nullptr, mem_size, PROT_READ | PROT_WRITE, MAP_ANON | MAP_PRIVATE, -1, 0);
        CHECK(c.mem != MAP_FAILED, "mmap");
        if (g_fail) return 1;
        // as GuestBuffer makes them: [WINDOW0_BASE, 2 windows) and [WINDOW_SIZE, 1 window)
        c.wide = [dev newBufferWithBytesNoCopy:c.mem + PS4_GNM_WINDOW0_BASE length:mem_size - PS4_GNM_WINDOW0_BASE
                                       options:MTLResourceStorageModeShared
                                   deallocator:nil];
        c.narrow = [dev newBufferWithBytesNoCopy:c.mem + PS4_GNM_WINDOW_SIZE length:PS4_GNM_WINDOW_SIZE
                                         options:MTLResourceStorageModeShared
                                     deallocator:nil];
        c.out = [dev newBufferWithLength:kWords * 4 options:MTLResourceStorageModeShared];
        MTLTextureDescriptor* td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatR32Uint
                                                                                      width:kSide
                                                                                     height:kSide
                                                                                  mipmapped:NO];
        td.usage = MTLTextureUsageRenderTarget;
        td.storageMode = MTLStorageModeShared;
        c.rt = [dev newTextureWithDescriptor:td];
        CHECK(c.wide && c.narrow && c.out && c.rt, "buffers");
        if (g_fail) return 1;
        be->MakeResident(c.wide, GnmResidencyClass::Guest);
        be->MakeResident(c.narrow, GnmResidencyClass::Guest);
        be->MakeResident(c.out, GnmResidencyClass::Builtin);
        be->MakeResident(c.rt, GnmResidencyClass::Texture);
        c.want.resize(kWords);
        for (uint32_t i = 0; i < kWords; ++i) {
            c.want[i] = Expected(i);
            CHECK(c.want[i] != 7u, "word %u: slow_read's index needs a value other than 7", i);
        }
        for (Case k : {Case::Compute, Case::Blit, Case::Vertex, Case::Fragment, Case::BlitWrite, Case::War}) {
            for (int i = 0; i < 8; ++i) {
                const bool split = i % 2;
                const uint32_t bad = Try(c, k, true, split);
                CHECK(bad == 0, "%s, try %d (%s): %u of %u words wrong", Name(k), i, split ? "next seq" : "same seq", bad,
                      kWords);
            }
            // the teeth: unordered, the second access overtakes the first (Metal 3 tracks objects)
            if (be->Kind() == GnmBackendKind::Metal3) {
                uint32_t worst = 0;
                int tries = 0;
                for (; tries < 8 && worst == 0; ++tries) worst = std::max(worst, Try(c, k, false, tries % 2));
                CHECK(worst > 0, "%s, unordered: every try was right: the test cannot see the race (make kLoop larger)",
                      Name(k));
                printf("gnm_backend_alias_test: %s unordered, try %d: %u of %u words wrong (the teeth)\n", Name(k), tries,
                       worst, kWords);
            }
        }
    }
    printf("gnm_backend_alias_test: %s\n", g_fail ? "FAIL" : "PASS");
    return g_fail ? 1 : 0;
}
