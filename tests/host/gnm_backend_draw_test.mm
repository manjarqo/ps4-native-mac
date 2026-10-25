// Draws and render-pass state on the backend PS4_GNM_METAL selects (both run it); with
// PS4_GNM_METAL=4 the same work also runs on a Metal3Backend and every output byte must equal
// Metal 3's (the TLOU captures hold none of these, so replays do not cover them):
//  - an instanced indexed draw (16-bit, at index_offset 256 behind other indices, base vertex,
//    base instance 3);
//  - a 32-bit indexed draw whose indices exceed 65535;
//  - an indexed-indirect draw whose last index is the last one of index_length (ib_len);
//  - an indirect draw;
//  - fixed-function state through SetFixed: viewport, scissor, cull mode and winding, triangle fill
//    mode, depth clip mode, blend colour, stencil reference; depth bias in its own pass (a rect
//    drawn twice at the same depth with depth Less: only the bias brings the second one in front);
//  - render passes with a depth and a stencil clear (draws behind the depth and with an unequal
//    stencil reference stay hidden), a 4x MSAA colour resolved into a single-sample texture with
//    programmable sample positions, and slice 2 of a 2D array target (slices 0 and 1 untouched);
//  - an indirect dispatch.
// Each case also checks a few pixels against their expected value, so that two backends drawing
// nothing would not pass.
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>

#include <string>
#include <vector>

#include "backend_harness.h"

using namespace ps4gnm;

static const char* kMsl = R"(
#include <metal_stdlib>
using namespace metal;
struct Vtx { float4 pos; float4 col; };
struct V { float4 pos [[position]]; float4 col; };
vertex V vs(uint vid [[vertex_id]], uint iid [[instance_id]], device const Vtx* v [[buffer(0)]],
            constant float4& step [[buffer(1)]]) {
    V o;
    o.pos = v[vid].pos + float4(step.xy * float(iid), 0, 0);
    o.col = float4(v[vid].col.rgb, float(iid + 1u) / 16.0);
    return o;
}
fragment float4 fs(V in [[stage_in]]) { return in.col; }
kernel void k_count(device atomic_uint* out [[buffer(0)]], uint i [[thread_position_in_grid]]) {
    atomic_fetch_add_explicit(&out[i % 4u], i + 1u, memory_order_relaxed);
}
)";

struct Vtx {
    float pos[4];
    float col[4];
};

constexpr uint32_t kSize = 64;

struct Pipes {
    id<MTLRenderPipelineState> color, ds, blend, msaa;
    id<MTLComputePipelineState> count;
    id<MTLDepthStencilState> less, always_eq, none;
};

static bool MakePipes(id<MTLDevice> dev, Pipes* p) {
    NSError* err = nil;
    id<MTLLibrary> lib = [dev newLibraryWithSource:@(kMsl) options:nil error:&err];
    CHECK(lib != nil, "shaders: %s", err.localizedDescription.UTF8String);
    if (!lib) return false;
    const auto pipe = [&](bool ds, bool blend, int samples) {
        MTLRenderPipelineDescriptor* d = [MTLRenderPipelineDescriptor new];
        d.vertexFunction = [lib newFunctionWithName:@"vs"];
        d.fragmentFunction = [lib newFunctionWithName:@"fs"];
        d.colorAttachments[0].pixelFormat = MTLPixelFormatRGBA8Unorm;
        if (blend) { // colour = src * blend colour + dst * (1 - blend colour)
            d.colorAttachments[0].blendingEnabled = YES;
            d.colorAttachments[0].sourceRGBBlendFactor = MTLBlendFactorBlendColor;
            d.colorAttachments[0].destinationRGBBlendFactor = MTLBlendFactorOneMinusBlendColor;
            d.colorAttachments[0].sourceAlphaBlendFactor = MTLBlendFactorOne;
            d.colorAttachments[0].destinationAlphaBlendFactor = MTLBlendFactorZero;
        }
        if (ds) {
            d.depthAttachmentPixelFormat = MTLPixelFormatDepth32Float_Stencil8;
            d.stencilAttachmentPixelFormat = MTLPixelFormatDepth32Float_Stencil8;
        }
        d.rasterSampleCount = samples;
        NSError* e = nil;
        id<MTLRenderPipelineState> s = [dev newRenderPipelineStateWithDescriptor:d error:&e];
        CHECK(s != nil, "pipeline: %s", e.localizedDescription.UTF8String);
        return s;
    };
    p->color = pipe(false, false, 1);
    p->ds = pipe(true, false, 1);
    p->blend = pipe(true, true, 1);
    p->msaa = pipe(false, false, 4);
    p->count = [dev newComputePipelineStateWithFunction:[lib newFunctionWithName:@"k_count"] error:&err];
    MTLDepthStencilDescriptor* dd = [MTLDepthStencilDescriptor new];
    dd.depthCompareFunction = MTLCompareFunctionLess;
    dd.depthWriteEnabled = YES;
    p->less = [dev newDepthStencilStateWithDescriptor:dd];
    dd = [MTLDepthStencilDescriptor new];
    dd.depthCompareFunction = MTLCompareFunctionAlways;
    MTLStencilDescriptor* sd = [MTLStencilDescriptor new];
    sd.stencilCompareFunction = MTLCompareFunctionEqual;
    dd.frontFaceStencil = sd;
    dd.backFaceStencil = sd;
    p->always_eq = [dev newDepthStencilStateWithDescriptor:dd];
    p->none = [dev newDepthStencilStateWithDescriptor:[MTLDepthStencilDescriptor new]];
    return p->color && p->ds && p->blend && p->msaa && p->count;
}

// A screen-space triangle (clip space x, y in [-1, 1], y up) with one colour.
static void Tri(std::vector<Vtx>& v, float x0, float y0, float x1, float y1, float x2, float y2, float z, float r, float g,
                float b) {
    for (auto [x, y] : {std::pair<float, float>{x0, y0}, {x1, y1}, {x2, y2}})
        v.push_back(Vtx{{x, y, z, 1}, {r, g, b, 1}});
}
// A rectangle as two counter-clockwise triangles (front-facing with the default winding).
static void AddRect(std::vector<Vtx>& v, float x0, float y0, float x1, float y1, float z, float r, float g, float b) {
    Tri(v, x0, y0, x1, y0, x1, y1, z, r, g, b);
    Tri(v, x0, y0, x1, y1, x0, y1, z, r, g, b);
}

struct Out {
    std::vector<std::string> names;
    std::vector<std::vector<uint8_t>> bytes;
};

static std::vector<uint8_t> Read(id<MTLTexture> t, NSUInteger slice = 0) {
    std::vector<uint8_t> px(t.width * t.height * 4);
    [t getBytes:px.data() bytesPerRow:t.width * 4 bytesPerImage:0 fromRegion:MTLRegionMake2D(0, 0, t.width, t.height)
        mipmapLevel:0 slice:slice];
    return px;
}

static const uint8_t* At(const std::vector<uint8_t>& px, uint32_t w, uint32_t x, uint32_t y) {
    return &px[((size_t)y * w + x) * 4];
}

// The pixel at (x, y) of a kSize target, y down, is (r, g, b, a) within 1.
static bool Is(const std::vector<uint8_t>& px, uint32_t x, uint32_t y, int r, int g, int b, int a) {
    const uint8_t* p = At(px, kSize, x, y);
    const int want[4] = {r, g, b, a};
    for (int i = 0; i < 4; ++i)
        if (abs((int)p[i] - want[i]) > 1) return false;
    return true;
}

static bool Run(id<MTLDevice> dev, GnmBackend& be, const Pipes& p, Out* out) {
    const char* kind = BackendName(be.Kind());
    const auto buffer = [&](const void* data, size_t n) {
        id<MTLBuffer> b = [dev newBufferWithLength:n options:MTLResourceStorageModeShared];
        if (data) memcpy(b.contents, data, n);
        else memset(b.contents, 0, n);
        be.MakeResident(b, GnmResidencyClass::Guest);
        return b;
    };
    const auto target = [&](MTLPixelFormat f, MTLTextureType type, uint32_t slices, int samples, MTLStorageMode mode) {
        MTLTextureDescriptor* td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:f width:kSize height:kSize
                                                                                  mipmapped:NO];
        td.textureType = type;
        td.arrayLength = slices;
        td.sampleCount = samples;
        td.storageMode = mode;
        td.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
        id<MTLTexture> t = [dev newTextureWithDescriptor:td];
        be.MakeResident(t, GnmResidencyClass::Texture);
        return t;
    };
    const auto rgba = [&]() { return target(MTLPixelFormatRGBA8Unorm, MTLTextureType2D, 1, 1, MTLStorageModeShared); };
    const float no_step[4] = {0, 0, 0, 0};

    // vertices: [0, 6) a rect, [6, 9) a triangle, from 65536 on a triangle reached by 32-bit indices
    std::vector<Vtx> v;
    AddRect(v, -0.9f, -0.9f, -0.8f, -0.5f, 0.5f, 1, 0, 0);                 // 0..5: red, columns 3..5, rows 48..60
    Tri(v, 0.1f, 0.1f, 0.9f, 0.1f, 0.5f, 0.9f, 0.5f, 0, 1, 0);          // 6..8: green, upper right
    v.resize(65536 + 3, Vtx{{0, 0, 0, 1}, {0, 0, 0, 1}});
    Tri(v, -0.9f, 0.1f, -0.1f, 0.1f, -0.5f, 0.9f, 0.5f, 0, 0, 1);       // 65539..65541: blue, upper left
    id<MTLBuffer> vb = buffer(v.data(), v.size() * sizeof(Vtx));
    const float step[4] = {0.25f, 0, 0, 0}; // each instance 8 px to the right
    std::vector<uint16_t> idx16 = {0, 1, 2, 3, 4, 5};
    for (auto& i : idx16) i += 2;                                      // base vertex -2 brings them back
    // at byte 256, as index data sits inside a guest window: before it 128 indices of the green
    // triangle, which a draw ignoring index_offset would draw instead
    std::vector<uint16_t> ib16_bytes(128, 0);
    for (size_t i = 0; i < ib16_bytes.size(); ++i) ib16_bytes[i] = uint16_t(6 + 2 + i % 3); // base vertex -2
    ib16_bytes.insert(ib16_bytes.end(), idx16.begin(), idx16.end());
    id<MTLBuffer> ib16 = buffer(ib16_bytes.data(), ib16_bytes.size() * 2);
    const uint32_t idx32[3] = {65539, 65540, 65541};
    id<MTLBuffer> ib32 = buffer(idx32, sizeof(idx32));
    // 1024 16-bit indices: all 0 (degenerate) except the last three, the green triangle
    std::vector<uint16_t> idx_tail(1024, 0);
    idx_tail[1021] = 6, idx_tail[1022] = 7, idx_tail[1023] = 8;
    id<MTLBuffer> ib_tail = buffer(idx_tail.data(), idx_tail.size() * 2);
    const MTLDrawIndexedPrimitivesIndirectArguments ia = {3, 1, 765, 0, 0}; // from index 256: 256 + 765 = 1021
    const MTLDrawPrimitivesIndirectArguments da = {6, 2, 0, 1};             // the red rect, instances 1 and 2
    std::vector<uint8_t> argbytes(256, 0);
    memcpy(&argbytes[16], &ia, sizeof(ia));
    memcpy(&argbytes[64], &da, sizeof(da));
    id<MTLBuffer> args = buffer(argbytes.data(), argbytes.size());

    GnmDraw draw;
    be.BeginCmd(GnmCmdTarget::Main, @"draw test", false);

    // ---- the draw kinds, one target each
    id<MTLTexture> t_inst = rgba(), t_32 = rgba(), t_tail = rgba(), t_ind = rgba();
    const auto pass = [&](id<MTLTexture> t, id<MTLRenderPipelineState> ps) {
        GnmPassDesc pd;
        pd.color[0].tex = t;
        pd.color[0].load = GnmLoad::Clear;
        pd.width = kSize; // renderTargetWidth / Height as the renderer sets them
        pd.height = kSize;
        CHECK(be.BeginRender(pd), "%s: no render encoder", kind);
        be.SetRenderPipeline(ps);
        be.BindBuffer(GnmStage::Vertex, 0, vb, 0);
    };
    pass(t_inst, p.color);
    be.BindBytes(GnmStage::Vertex, 1, step, sizeof(step));
    draw = GnmDraw{};
    draw.kind = GnmDrawKind::Indexed;
    draw.count = 6;
    draw.instances = 2;
    draw.base_instance = 3;
    draw.base_vertex = -2;
    draw.index_type = MTLIndexTypeUInt16;
    draw.index_buffer = ib16;
    draw.index_offset = 256;
    draw.index_length = idx16.size() * 2;
    be.Draw(draw);
    be.EndEncoder();
    pass(t_32, p.color);
    be.BindBytes(GnmStage::Vertex, 1, no_step, sizeof(no_step));
    draw = GnmDraw{};
    draw.kind = GnmDrawKind::Indexed;
    draw.count = 3;
    draw.index_type = MTLIndexTypeUInt32;
    draw.index_buffer = ib32;
    draw.index_length = sizeof(idx32);
    be.Draw(draw);
    be.EndEncoder();
    pass(t_tail, p.color);
    be.BindBytes(GnmStage::Vertex, 1, no_step, sizeof(no_step));
    draw = GnmDraw{};
    draw.kind = GnmDrawKind::IndexedIndirect;
    draw.index_type = MTLIndexTypeUInt16;
    draw.index_buffer = ib_tail;
    draw.index_offset = 512;                      // index 256
    draw.index_length = idx_tail.size() * 2 - 512; // exactly up to the last index
    draw.indirect_buffer = args;
    draw.indirect_offset = 16;
    be.Draw(draw);
    be.EndEncoder();
    pass(t_ind, p.color);
    be.BindBytes(GnmStage::Vertex, 1, step, sizeof(step));
    draw = GnmDraw{};
    draw.kind = GnmDrawKind::Indirect;
    draw.indirect_buffer = args;
    draw.indirect_offset = 64;
    be.Draw(draw);
    be.EndEncoder();

    // ---- fixed-function state, depth and stencil
    id<MTLTexture> t_fixed = rgba();
    id<MTLTexture> ds = target(MTLPixelFormatDepth32Float_Stencil8, MTLTextureType2D, 1, 1, MTLStorageModePrivate);
    std::vector<Vtx> fv; // a full-screen rect at z 0.5, at z 0.1, a clockwise (back-facing) and a ccw triangle
    AddRect(fv, -1, -1, 1, 1, 0.5f, 1, 1, 1);                       // 0..5
    AddRect(fv, -1, -1, 1, 1, 0.1f, 0, 1, 0);                       // 6..11
    // winding in clip space (y up)
    Tri(fv, 0.2f, -0.2f, 0.9f, -0.2f, 0.6f, -0.9f, 0.1f, 1, 0, 1); // 12..14: magenta, bottom right, clockwise
    Tri(fv, 0.2f, 0.3f, 0.55f, 0.0f, 0.9f, 0.3f, 0.1f, 1, 1, 0);   // 15..17: yellow, right, rows 22..32, counter-clockwise
    Tri(fv, -0.9f, -0.2f, -0.2f, -0.2f, -0.55f, -0.9f, 1.5f, 0, 1, 1); // 18..20: z 1.5, beyond the far plane
    Tri(fv, 0.5f, 0.55f, 0.98f, 0.98f, 0.5f, 0.98f, 0.1f, 1, 0, 1);    // 21..23: magenta, over the white top right
    id<MTLBuffer> fvb = buffer(fv.data(), fv.size() * sizeof(Vtx));
    GnmPassDesc pd;
    pd.color[0].tex = t_fixed;
    pd.color[0].load = GnmLoad::Clear;
    pd.depth.tex = ds;
    pd.depth.load = GnmLoad::Clear;
    pd.clear_depth = 0.25;
    pd.stencil.tex = ds;
    pd.stencil.load = GnmLoad::Clear;
    pd.clear_stencil = 7;
    CHECK(be.BeginRender(pd), "%s: no depth-stencil render encoder", kind);
    be.SetRenderPipeline(p.ds);
    be.BindBuffer(GnmStage::Vertex, 0, fvb, 0);
    be.BindBytes(GnmStage::Vertex, 1, no_step, sizeof(no_step));
    GnmFixedState fx{};
    fx.vp = MTLViewport{0, 0, kSize, kSize, 0, 1};
    fx.sc = MTLScissorRect{0, 0, kSize, kSize};
    fx.cull = MTLCullModeNone;
    fx.winding = MTLWindingCounterClockwise;
    fx.fill = MTLTriangleFillModeFill;
    fx.clip = MTLDepthClipModeClip;
    fx.stencil_ref[0] = fx.stencil_ref[1] = 7;
    be.SetFixed(fx, kGnmFixedViewport | kGnmFixedScissor | kGnmFixedCull | kGnmFixedWinding | kGnmFixedFill |
                        kGnmFixedClip | kGnmFixedStencilRef);
    GnmDraw d6;
    d6.count = 6;
    be.SetDepthStencil(p.less);
    be.Draw(d6); // z 0.5 behind the cleared 0.25: hidden
    fx.vp = MTLViewport{0, 0, kSize / 2, kSize, 0, 1}; // the left half
    be.SetFixed(fx, kGnmFixedViewport);
    d6.vertex_start = 6;
    be.Draw(d6); // z 0.1: green, left half
    fx.vp = MTLViewport{0, 0, kSize, kSize, 0, 1};
    fx.sc = MTLScissorRect{kSize / 2, 0, kSize / 2, kSize / 4}; // top right
    be.SetFixed(fx, kGnmFixedViewport | kGnmFixedScissor);
    be.SetDepthStencil(p.always_eq);
    d6.vertex_start = 0;
    be.Draw(d6); // stencil 7 == ref 7: white in the scissor
    fx.stencil_ref[0] = fx.stencil_ref[1] = 3;
    fx.sc = MTLScissorRect{kSize / 2, kSize / 4, kSize / 2, kSize / 4};
    be.SetFixed(fx, kGnmFixedStencilRef | kGnmFixedScissor);
    be.Draw(d6); // stencil 7 != ref 3: hidden
    fx.sc = MTLScissorRect{0, 0, kSize, kSize};
    fx.cull = MTLCullModeBack;
    fx.stencil_ref[0] = fx.stencil_ref[1] = 7;
    be.SetFixed(fx, kGnmFixedScissor | kGnmFixedCull | kGnmFixedStencilRef);
    be.SetDepthStencil(p.none);
    GnmDraw d3;
    d3.count = 3;
    d3.vertex_start = 12;
    be.Draw(d3); // back-facing: culled
    d3.vertex_start = 15;
    be.Draw(d3); // front-facing: yellow
    fx.cull = MTLCullModeNone;
    fx.clip = MTLDepthClipModeClamp;
    fx.fill = MTLTriangleFillModeLines;
    be.SetFixed(fx, kGnmFixedCull | kGnmFixedClip | kGnmFixedFill);
    d3.vertex_start = 18;
    be.Draw(d3); // beyond the far plane, kept by the clamp, outlined only: cyan edges
    // the blend colour: half of a magenta triangle over the white of the stencil draw
    be.SetRenderPipeline(p.blend);
    fx.fill = MTLTriangleFillModeFill;
    fx.clip = MTLDepthClipModeClip;
    fx.blend[0] = 0.5f, fx.blend[1] = 0.5f, fx.blend[2] = 0.5f, fx.blend[3] = 1;
    be.SetFixed(fx, kGnmFixedFill | kGnmFixedClip | kGnmFixedBlend);
    d3.vertex_start = 21;
    be.Draw(d3);
    be.EndEncoder();

    // ---- depth bias: the same red-then-green rect at z 0.5, depth Less; only a negative constant
    // bias puts the green one in front of the red one's depth
    id<MTLTexture> t_bias = rgba();
    id<MTLTexture> ds_bias = target(MTLPixelFormatDepth32Float_Stencil8, MTLTextureType2D, 1, 1, MTLStorageModePrivate);
    std::vector<Vtx> bv;
    AddRect(bv, -0.5f, -0.5f, 0.5f, 0.5f, 0.5f, 1, 0, 0);
    AddRect(bv, -0.5f, -0.5f, 0.5f, 0.5f, 0.5f, 0, 1, 0);
    id<MTLBuffer> bvb = buffer(bv.data(), bv.size() * sizeof(Vtx));
    pd = GnmPassDesc{};
    pd.color[0].tex = t_bias;
    pd.color[0].load = GnmLoad::Clear;
    pd.depth.tex = ds_bias;
    pd.depth.load = GnmLoad::Clear;
    pd.clear_depth = 1.0;
    pd.stencil.tex = ds_bias; // the pipeline has a stencil format
    pd.stencil.load = GnmLoad::Clear;
    CHECK(be.BeginRender(pd), "%s: no depth-bias render encoder", kind);
    be.SetRenderPipeline(p.ds);
    be.SetDepthStencil(p.less);
    be.BindBuffer(GnmStage::Vertex, 0, bvb, 0);
    be.BindBytes(GnmStage::Vertex, 1, no_step, sizeof(no_step));
    d6 = GnmDraw{};
    d6.count = 6;
    be.Draw(d6); // red at 0.5
    GnmFixedState bx{};
    bx.bias[0] = -1000, bx.bias[1] = 0, bx.bias[2] = 0; // 1000 depth units nearer
    be.SetFixed(bx, kGnmFixedBias);
    d6.vertex_start = 6;
    be.Draw(d6); // green at 0.5 - bias: passes Less
    be.EndEncoder();

    // ---- 4x MSAA resolved, programmable sample positions
    id<MTLTexture> msaa = target(MTLPixelFormatRGBA8Unorm, MTLTextureType2DMultisample, 1, 4, MTLStorageModePrivate);
    id<MTLTexture> t_resolve = rgba();
    pd = GnmPassDesc{};
    pd.color[0].tex = msaa;
    pd.color[0].load = GnmLoad::Clear;
    pd.color[0].store = GnmStore::MultisampleResolve;
    pd.color[0].resolve = t_resolve;
    pd.num_sample_positions = 4;
    pd.sample_positions[0] = MTLSamplePositionMake(0.125f, 0.125f);
    pd.sample_positions[1] = MTLSamplePositionMake(0.875f, 0.25f);
    pd.sample_positions[2] = MTLSamplePositionMake(0.25f, 0.875f);
    pd.sample_positions[3] = MTLSamplePositionMake(0.625f, 0.625f);
    CHECK(be.BeginRender(pd), "%s: no MSAA render encoder", kind);
    be.SetRenderPipeline(p.msaa);
    be.BindBuffer(GnmStage::Vertex, 0, vb, 0);
    be.BindBytes(GnmStage::Vertex, 1, no_step, sizeof(no_step));
    GnmDraw dg;
    dg.count = 3;
    dg.vertex_start = 6;
    be.Draw(dg); // the green triangle: its slanted edges are resolved partial coverage
    be.EndEncoder();

    // ---- slice 2 of a 2D array target
    id<MTLTexture> arr = target(MTLPixelFormatRGBA8Unorm, MTLTextureType2DArray, 3, 1, MTLStorageModeShared);
    pd = GnmPassDesc{};
    pd.color[0].tex = arr;
    pd.color[0].slice = 2;
    pd.color[0].load = GnmLoad::Clear;
    pd.clear_color[0] = MTLClearColorMake(0, 0, 1, 1);
    CHECK(be.BeginRender(pd), "%s: no array-slice render encoder", kind);
    be.SetRenderPipeline(p.color);
    be.BindBuffer(GnmStage::Vertex, 0, vb, 0);
    be.BindBytes(GnmStage::Vertex, 1, no_step, sizeof(no_step));
    be.Draw(dg);
    be.EndEncoder();

    // ---- an indirect dispatch
    id<MTLBuffer> counts = buffer(nullptr, 16);
    const uint32_t groups[3] = {4, 1, 1};
    id<MTLBuffer> dargs = buffer(nullptr, 64);
    memcpy((uint8_t*)dargs.contents + 32, groups, sizeof(groups));
    be.BeginCompute(false);
    be.SetComputePipeline(p.count);
    be.BindBuffer(GnmStage::Compute, 0, counts, 0);
    be.DispatchIndirect(dargs, 32, MTLSizeMake(64, 1, 1));
    be.EndEncoder();

    if (!CommitAndWait(be, 1)) return false;

    const auto inst = Read(t_inst), b32 = Read(t_32), tail = Read(t_tail), ind = Read(t_ind), fixed = Read(t_fixed),
               res = Read(t_resolve), bias = Read(t_bias), s0 = Read(arr, 0), s2 = Read(arr, 2);
    // y down, every draw's alpha is (instance + 1) / 16: the red rect is at columns 3..5, rows 48..60
    CHECK(Is(inst, 4 + 24, 54, 255, 0, 0, 64) && Is(inst, 4 + 32, 54, 255, 0, 0, 80) && Is(inst, 4, 54, 0, 0, 0, 0),
          "%s: instanced indexed draw (instances 3 and 4 at +24 and +32 px)", kind);
    CHECK(Is(b32, 16, 20, 0, 0, 255, 16), "%s: 32-bit indexed draw", kind);
    CHECK(Is(tail, 48, 20, 0, 255, 0, 16), "%s: indexed-indirect draw of the last indices of index_length", kind);
    CHECK(Is(ind, 4 + 8, 54, 255, 0, 0, 32) && Is(ind, 4 + 16, 54, 255, 0, 0, 48) && Is(ind, 4, 54, 0, 0, 0, 0),
          "%s: indirect draw (instances 1 and 2)", kind);
    CHECK(Is(fixed, 8, 20, 0, 255, 0, 16), "%s: depth: the z 0.1 rect in the left-half viewport", kind);
    CHECK(Is(fixed, 60, 14, 255, 255, 255, 16), "%s: stencil equal and scissor: white top right", kind);
    CHECK(Is(fixed, 60, 20, 0, 0, 0, 0), "%s: stencil unequal: nothing", kind);
    CHECK(Is(fixed, 48, 27, 255, 255, 0, 16) && Is(fixed, 48, 44, 0, 0, 0, 0),
          "%s: cull back with counter-clockwise front faces: the yellow triangle drawn, the magenta one culled", kind);
    CHECK(Is(fixed, 52, 3, 255, 128, 255, 16), "%s: blend colour (magenta at 0.5 over white)", kind);
    bool edge = false; // the triangle's top edge (clip y -0.2) crosses column 14 at row 38
    for (uint32_t y = 36; y <= 40; ++y) edge |= Is(fixed, 14, y, 0, 255, 255, 16);
    CHECK(edge && Is(fixed, 14, 46, 0, 255, 0, 16),
          "%s: depth clamp and line fill: the far triangle outlined, its inside left as it was", kind);
    CHECK(Is(bias, 32, 32, 0, 255, 0, 16), "%s: depth bias: the second rect at the same depth in front", kind);
    CHECK(Is(res, 48, 20, 0, 255, 0, 16), "%s: MSAA resolve inside the triangle", kind);
    CHECK(Is(s0, 32, 32, 0, 0, 0, 0) && Is(s2, 2, 2, 0, 0, 255, 255) && Is(s2, 40, 20, 0, 255, 0, 16),
          "%s: array slice 2 cleared and drawn, slice 0 untouched", kind);
    const uint32_t* c = (const uint32_t*)counts.contents;
    uint32_t want[4] = {};
    for (uint32_t i = 0; i < 256; ++i) want[i % 4] += i + 1;
    CHECK(c[0] == want[0] && c[1] == want[1] && c[2] == want[2] && c[3] == want[3], "%s: indirect dispatch sums", kind);
    out->names = {"instanced indexed", "32-bit indexed", "indexed-indirect tail", "indirect", "fixed state + depth/stencil", "depth bias",
                  "MSAA resolve with sample positions", "array slice 0", "array slice 2", "indirect dispatch"};
    out->bytes = {inst, b32, tail, ind, fixed, bias, res, s0, s2,
                  std::vector<uint8_t>((const uint8_t*)c, (const uint8_t*)c + 16)};
    return true;
}

int main() {
    @autoreleasepool {
        id<MTLDevice> dev = MTLCreateSystemDefaultDevice();
        const char* env = getenv("PS4_GNM_METAL");
        if (dev && env && !strcmp(env, "4") && !RequireMetal4(dev, "gnm_backend_draw_test")) return 0;
        std::string why;
        std::unique_ptr<GnmBackend> be = dev ? MakeTestBackend(dev, &why) : nullptr;
        if (!be) {
            printf("gnm_backend_draw_test: FAIL: no backend: %s\n", dev ? why.c_str() : "no Metal device");
            return 1;
        }
        printf("gnm_backend_draw_test: backend %s\n", BackendName(be->Kind()));
        Pipes p;
        if (!MakePipes(dev, &p)) return 1;
        Out got;
        CHECK(Run(dev, *be, p, &got), "the seq failed or hung");
        if (be->Kind() == GnmBackendKind::Metal4) {
            std::unique_ptr<GnmBackend> m3 = MakeMetal3Backend();
            CHECK(m3->Init(dev, &why), "Metal 3 backend: %s", why.c_str());
            Out ref;
            CHECK(Run(dev, *m3, p, &ref), "the Metal 3 seq failed or hung");
            for (size_t i = 0; i < got.bytes.size() && i < ref.bytes.size(); ++i) {
                size_t diff = 0;
                for (size_t k = 0; k < got.bytes[i].size() && k < ref.bytes[i].size(); ++k) diff += got.bytes[i][k] != ref.bytes[i][k];
                CHECK(got.bytes[i].size() == ref.bytes[i].size() && diff == 0, "%s: %zu bytes differ from Metal 3",
                      got.names[i].c_str(), diff);
            }
        }
    }
    printf("gnm_backend_draw_test: %s\n", g_fail ? "FAIL" : "PASS");
    return g_fail ? 1 : 0;
}
