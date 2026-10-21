// RectList draws on Metal: a GCN vertex shader translated by libgcn_recompiler
// (3rdparty/gcn-recompiler), drawn as rectangles through gcn_shader_rectlist_msl and the
// renderer's encoder (pkg/runtime/modules/libSceGnmDriver/ps4_gnm_rectlist.h).
//
// Each rectangle gives 3 vertices with a position (screen space, clip disabled as for every
// RectList draw) and a colour; the GPU makes the 4th vertex. The test renders into a float
// target and checks the colour at all 4 corners of every rectangle (the 4th corner's colour is
// the sum of its neighbours' minus the corner's), the centre, and that nothing is drawn outside.
// Rectangles have their corner at vertex 0, 1 and 2, in both windings; draws are non-indexed
// from vertex 0, non-indexed from a later vertex, indexed (16-bit indices, base vertex),
// instanced, and with back faces culled (a rectangle is drawn whole or not at all).
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>

#include <cmath>
#include <cstdio>
#include <cstring>
#include <string>
#include <vector>

#include "gcn_recompiler.h"
#include "ps4_gnm_rectlist.h"

namespace {

int g_fail = 0;
#define CHECK(c, ...)                                                                    \
    do {                                                                                 \
        if (!(c)) {                                                                      \
            std::fprintf(stderr, "gnm_rectlist_test: FAIL %s:%d: ", __FILE__, __LINE__); \
            std::fprintf(stderr, __VA_ARGS__);                                           \
            std::fprintf(stderr, "\n");                                                  \
            g_fail++;                                                                    \
        }                                                                                \
    } while (0)

constexpr uint64_t kGuestBase = 0x10000000;
constexpr uint64_t kGuestSize = 1u << 20;
constexpr uint32_t kSize = 64; // render target width and height

struct Guest {
    id<MTLBuffer> buf;
    uint8_t* p(uint64_t a) { return static_cast<uint8_t*>(buf.contents) + (a - kGuestBase); }
    static bool Read(void* ctx, uint64_t addr, void* dst, uint64_t size) {
        auto* g = static_cast<Guest*>(ctx);
        if (addr < kGuestBase || addr + size > kGuestBase + kGuestSize) return false;
        std::memcpy(dst, g->p(addr), size);
        return true;
    }
};

std::vector<uint32_t> WithFooter(const std::vector<uint32_t>& body, uint64_t hash) {
    std::vector<uint32_t> code = {0xBEEB03FF, 0};
    code.insert(code.end(), body.begin(), body.end());
    while (code.size() % 2) code.push_back(0xBF800000); // s_nop
    code[1] = uint32_t(code.size() / 2 - 1);
    uint8_t bi[32] = {'O', 'r', 'b', 'S', 'h', 'd', 'r', 7};
    const uint32_t w = (uint32_t(code.size() * 4) & 0xFFFFFF) << 8;
    std::memcpy(bi + 8, &w, 4);
    std::memcpy(bi + 16, &hash, 8);
    const size_t at = code.size();
    code.resize(at + 8);
    std::memcpy(&code[at], bi, 32);
    return code;
}

// V# of an array of 32-byte vertices (float4 position, float4 colour), 32-bit float elements.
void VertexSharp(uint32_t* v, uint64_t base, uint32_t num) {
    v[0] = uint32_t(base);
    v[1] = (uint32_t(base >> 32) & 0xFFF) | (32u << 16); // stride
    v[2] = num;                                          // num_records (elements)
    v[3] = 4 | (5 << 3) | (6 << 6) | (7 << 9) | (7 << 12) | (14 << 15); // xyzw, NUM_FORMAT float, DATA_FORMAT 32
}

struct Vertex {
    float pos[4];
    float color[4];
};

struct TestRect {
    float x[3], y[3];
    float c[3][4];
};

id<MTLLibrary> Lib(id<MTLDevice> dev, const char* msl) {
    NSError* e = nil;
    MTLCompileOptions* o = [MTLCompileOptions new];
    o.languageVersion = MTLLanguageVersion2_3;
    id<MTLLibrary> lib = [dev newLibraryWithSource:[NSString stringWithUTF8String:msl] options:o error:&e];
    if (!lib) std::fprintf(stderr, "MSL: %s\n%s\n", e.localizedDescription.UTF8String, msl);
    return lib;
}

const char* kFragment = R"(
#include <metal_stdlib>
using namespace metal;
struct In { float4 color [[user(locn0)]]; };
fragment float4 main0(In in [[stage_in]]) { return in.color; }
)";

struct Fixture {
    id<MTLDevice> dev;
    id<MTLCommandQueue> q;
    Guest g;
    gcn_shader* vs = nullptr;
    gcn_shader_info info{};
    gcn_rectlist_msl rect{};
    id<MTLRenderPipelineState> capture, expand;
    uint32_t ud[16] = {};
    uint64_t code_addr = kGuestBase, vtx_addr = kGuestBase + 0x1000;
};

bool Setup(Fixture& f) {
    f.q = [f.dev newCommandQueue];
    f.g.buf = [f.dev newBufferWithLength:kGuestSize options:MTLResourceStorageModeShared];
    std::memset(f.g.buf.contents, 0, kGuestSize);
    // user data s[4:7]: V# of the vertices; v0: vertex index
    //   buffer_load_dwordx4 v[1:4], v0, s[4:7], 0 idxen            ; position
    //   buffer_load_dwordx4 v[5:8], v0, s[4:7], 0 idxen offset:16  ; colour
    //   s_waitcnt vmcnt(0)
    //   exp pos0 v1, v2, v3, v4 done
    //   exp param0 v5, v6, v7, v8
    //   s_endpgm
    const auto prog = WithFooter({0xE0382000, 0x80010100, 0xE0382010, 0x80010500, 0xBF8C0F70, 0xF80008CF,
                                  0x04030201, 0xF800020F, 0x08070605, 0xBF810000},
                                 0x5EC71157D0000001ULL);
    std::memcpy(f.g.p(f.code_addr), prog.data(), prog.size() * 4);
    VertexSharp(&f.ud[4], f.vtx_addr, 64);

    gcn_profile prof;
    gcn_profile_default_metal(&prof);
    gcn_runtime_info rt{};
    rt.hw_stage = GCN_HW_VS;
    rt.sw_stage = GCN_SW_VERTEX;
    rt.num_allocated_vgprs = 12;
    rt.num_user_data = 8;
    rt.vs.clip_disable = true; // RectList: screen-space positions
    gcn_compile_desc d{};
    d.hw_stage = GCN_HW_VS;
    d.sw_stage = GCN_SW_VERTEX;
    d.code_addr = f.code_addr;
    std::memcpy(d.user_data, f.ud, sizeof(f.ud));
    d.runtime = &rt;
    d.profile = &prof;
    d.read_guest = Guest::Read;
    d.read_ctx = &f.g;
    d.flags = GCN_COMPILE_EMIT_MSL;
    char err[512] = {};
    const gcn_status st = gcn_compile(&d, &f.vs, err, sizeof(err));
    CHECK(st == GCN_OK && f.vs, "vertex shader does not compile: %s", err);
    if (st != GCN_OK) return false;
    gcn_shader_get_info(f.vs, &f.info);
    const gcn_status rs = gcn_shader_rectlist_msl(f.vs, nullptr, &f.rect, err, sizeof(err));
    CHECK(rs == GCN_OK, "gcn_shader_rectlist_msl: %s", err);
    if (rs != GCN_OK) return false;
    CHECK(f.rect.vertex_stride == 32, "captured vertex stride %u, expected 32 (two float4)", f.rect.vertex_stride);

    id<MTLLibrary> cl = Lib(f.dev, f.rect.capture_msl), el = Lib(f.dev, f.rect.expand_msl), fl = Lib(f.dev, kFragment);
    CHECK(cl && el && fl, "Metal rejected the RectList shaders");
    if (!cl || !el || !fl) return false;
    NSError* e = nil;
    MTLRenderPipelineDescriptor* cd = [MTLRenderPipelineDescriptor new];
    cd.vertexFunction = [cl newFunctionWithName:@"main0"];
    cd.rasterizationEnabled = NO;
    cd.colorAttachments[0].pixelFormat = MTLPixelFormatRGBA32Float;
    f.capture = [f.dev newRenderPipelineStateWithDescriptor:cd error:&e];
    CHECK(f.capture, "capture pipeline: %s", e.localizedDescription.UTF8String);
    MTLRenderPipelineDescriptor* ed = [MTLRenderPipelineDescriptor new];
    ed.vertexFunction = [el newFunctionWithName:@"main0"];
    ed.fragmentFunction = [fl newFunctionWithName:@"main0"];
    ed.colorAttachments[0].pixelFormat = MTLPixelFormatRGBA32Float;
    f.expand = [f.dev newRenderPipelineStateWithDescriptor:ed error:&e];
    CHECK(f.expand, "expansion pipeline: %s", e.localizedDescription.UTF8String);
    return f.capture && f.expand;
}

// One draw of `rects`. Every instance draws the same rectangles (the shader ignores the
// instance), so the instanced case checks the per-instance capture indexing.
struct DrawCase {
    const char* name;
    std::vector<TestRect> rects;
    uint32_t first = 0;          // first vertex of a non-indexed draw
    bool indexed = false;        // vertices stored in reverse order, drawn through indices
    int32_t base_vertex = 0;
    uint32_t instances = 1;
    bool cull_back = false;      // cull back faces, clockwise (in screen space, y down) is front
};

std::vector<float> Render(Fixture& f, const DrawCase& c) {
    // vertex data
    const uint32_t nv = uint32_t(c.rects.size() * 3);
    std::vector<Vertex> verts(64);
    std::vector<uint16_t> idx;
    for (uint32_t r = 0; r < c.rects.size(); r++) {
        for (uint32_t k = 0; k < 3; k++) {
            const uint32_t i = r * 3 + k;
            const uint32_t at = c.indexed ? uint32_t(c.base_vertex) + (nv - 1 - i) : c.first + i;
            Vertex& v = verts[at];
            v = {{c.rects[r].x[k], c.rects[r].y[k], 0.5f, 1.f},
                 {c.rects[r].c[k][0], c.rects[r].c[k][1], c.rects[r].c[k][2], c.rects[r].c[k][3]}};
            if (c.indexed) idx.push_back(uint16_t(nv - 1 - i));
        }
    }
    std::memcpy(f.g.p(f.vtx_addr), verts.data(), verts.size() * sizeof(Vertex));

    MTLTextureDescriptor* td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA32Float
                                                                                  width:kSize height:kSize mipmapped:NO];
    td.usage = MTLTextureUsageRenderTarget;
    td.storageMode = MTLStorageModeShared;
    id<MTLTexture> rt = [f.dev newTextureWithDescriptor:td];
    MTLRenderPassDescriptor* pd = [MTLRenderPassDescriptor renderPassDescriptor];
    pd.colorAttachments[0].texture = rt;
    pd.colorAttachments[0].loadAction = MTLLoadActionClear;
    pd.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0);
    pd.colorAttachments[0].storeAction = MTLStoreActionStore;
    id<MTLCommandBuffer> cb = [f.q commandBuffer];
    id<MTLRenderCommandEncoder> enc = [cb renderCommandEncoderWithDescriptor:pd];
    // Clip disabled: the shader maps screen space [0, 16384) to NDC with y down (Vulkan's
    // convention); the renderer's viewport for such draws (DecodeRenderState) maps it back with a
    // negative height. Winding stays that of screen space.
    [enc setViewport:MTLViewport{0, 16384, 16384, -16384, 0, 1}];
    if (c.cull_back) {
        [enc setCullMode:MTLCullModeBack];
        [enc setFrontFacingWinding:MTLWindingClockwise];
    }

    // the vertex shader's resources, as the renderer binds them
    std::vector<uint32_t> flat(f.info.flatbuf_size_dw);
    gcn_shader_build_flatbuf(f.vs, f.ud, Guest::Read, &f.g, flat.data(), flat.size());
    gcn_push_data push{};
    push.xscale = push.yscale = 1.f;
    for (uint32_t i = 0; i < f.info.num_buffers; i++) {
        gcn_buffer_binding b;
        gcn_shader_get_buffer(f.vs, i, &b);
        for (uint32_t k = 0; k < b.num_msl_buffers; k++) {
            if (b.type == GCN_BUFFER_FLATBUF) {
                [enc setVertexBytes:flat.data() length:flat.size() * 4 atIndex:b.msl_buffers[k]];
            } else if (b.type == GCN_BUFFER_GUEST) {
                uint32_t v[4];
                gcn_buffer_desc bd{};
                gcn_shader_fetch_buffer_sharp(f.vs, i, flat.data(), f.code_addr, v);
                gcn_decode_buffer(v, &bd);
                [enc setVertexBuffer:f.g.buf offset:bd.base_address - kGuestBase atIndex:b.msl_buffers[k]];
                if (b.buffer_slot < GCN_MAX_BUFFERS) push.buf_sizes[b.buffer_slot] = bd.size_bytes;
            } else {
                // clip planes etc.: unused by this shader, any buffer
                [enc setVertexBuffer:f.g.buf offset:0 atIndex:b.msl_buffers[k]];
            }
        }
    }
    if (f.info.msl_push_constant_buffer >= 0)
    {
        // the MSL struct is padded to 16 bytes
        uint8_t pb[(sizeof(push) + 15) / 16 * 16] = {};
        std::memcpy(pb, &push, sizeof(push));
        [enc setVertexBytes:pb length:sizeof(pb) atIndex:(NSUInteger)f.info.msl_push_constant_buffer];
    }

    // the renderer's encoding
    std::vector<uint32_t> slots(nv);
    const uint32_t per_instance = ps4gnm_rect::BuildSlots(c.indexed ? idx.data() : nullptr, false, nv, slots.data());
    CHECK(per_instance > 0, "%s: BuildSlots rejected %u vertices", c.name, nv);
    id<MTLBuffer> ib = c.indexed ? [f.dev newBufferWithBytes:idx.data() length:idx.size() * 2
                                                     options:MTLResourceStorageModeShared]
                                 : nil;
    id<MTLBuffer> sb = [f.dev newBufferWithBytes:slots.data() length:slots.size() * 4 options:MTLResourceStorageModeShared];
    id<MTLBuffer> pb = [f.dev newBufferWithBytes:&per_instance length:4 options:MTLResourceStorageModeShared];
    // a stale pattern: anything not written by the capture draw shows up as garbage
    const size_t cap_bytes = size_t(per_instance + c.first) * c.instances * f.rect.vertex_stride;
    id<MTLBuffer> vb = [f.dev newBufferWithLength:cap_bytes options:MTLResourceStorageModeShared];
    std::memset(vb.contents, 0x7F, cap_bytes);
    ps4gnm_rect::Geometry geo;
    geo.count = nv;
    geo.instances = c.instances;
    geo.vertex_start = c.first;
    geo.base_vertex = c.base_vertex;
    geo.index_buffer = ib;
    geo.index_type = MTLIndexTypeUInt16;
    ps4gnm_rect::Buffers bufs{vb, 0, sb, 0, pb, 0, f.rect.capture_buffer, f.rect.params_buffer};
    ps4gnm_rect::Encode(enc, f.capture, f.expand, geo, bufs);
    [enc endEncoding];
    [cb commit];
    [cb waitUntilCompleted];
    CHECK(cb.status == MTLCommandBufferStatusCompleted, "%s: command buffer failed: %s", c.name,
          cb.error.localizedDescription.UTF8String);
    std::vector<float> px(kSize * kSize * 4);
    [rt getBytes:px.data() bytesPerRow:kSize * 16 fromRegion:MTLRegionMake2D(0, 0, kSize, kSize) mipmapLevel:0];
    return px;
}

bool Near(const float* a, const float* b) {
    for (int i = 0; i < 4; i++)
        if (std::fabs(a[i] - b[i]) > 0.06f) return false;
    return true;
}

// The colour the rectangle's affine interpolation gives at pixel centre (px, py).
void Expected(const TestRect& r, float px, float py, float* out) {
    // c(x, y) = c0 + (x - x0) * dc/dx + (y - y0) * dc/dy, solved from the three vertices
    const float x1 = r.x[1] - r.x[0], y1 = r.y[1] - r.y[0], x2 = r.x[2] - r.x[0], y2 = r.y[2] - r.y[0];
    const float det = x1 * y2 - x2 * y1;
    const float u = ((px - r.x[0]) * y2 - (py - r.y[0]) * x2) / det;
    const float v = ((py - r.y[0]) * x1 - (px - r.x[0]) * y1) / det;
    for (int i = 0; i < 4; i++) out[i] = r.c[0][i] + u * (r.c[1][i] - r.c[0][i]) + v * (r.c[2][i] - r.c[0][i]);
}

void CheckRects(const DrawCase& c, const std::vector<float>& px) {
    std::vector<bool> inside(kSize * kSize, false);
    for (size_t ri = 0; ri < c.rects.size(); ri++) {
        const TestRect& r = c.rects[ri];
        // clockwise on screen (y down): front facing; both triangles must keep that winding
        const bool cw = (r.x[1] - r.x[0]) * (r.y[2] - r.y[0]) - (r.y[1] - r.y[0]) * (r.x[2] - r.x[0]) > 0;
        if (c.cull_back && !cw) continue; // culled: every one of its pixels must stay empty
        float x0 = r.x[0], x1 = r.x[0], y0 = r.y[0], y1 = r.y[0];
        for (int k = 1; k < 3; k++) {
            x0 = std::min(x0, r.x[k]), x1 = std::max(x1, r.x[k]);
            y0 = std::min(y0, r.y[k]), y1 = std::max(y1, r.y[k]);
        }
        for (uint32_t y = uint32_t(y0); y < uint32_t(y1); y++)
            for (uint32_t x = uint32_t(x0); x < uint32_t(x1); x++) inside[y * kSize + x] = true;
        // the four corner pixels (centres half a pixel inside) and the centre
        const float pts[5][2] = {{x0 + 0.5f, y0 + 0.5f}, {x1 - 0.5f, y0 + 0.5f}, {x0 + 0.5f, y1 - 0.5f},
                                 {x1 - 0.5f, y1 - 0.5f}, {(x0 + x1) / 2 + 0.5f, (y0 + y1) / 2 + 0.5f}};
        static const char* const kWhere[5] = {"top-left", "top-right", "bottom-left", "bottom-right", "centre"};
        for (int p = 0; p < 5; p++) {
            float want[4];
            Expected(r, pts[p][0], pts[p][1], want);
            const float* got = &px[(uint32_t(pts[p][1]) * kSize + uint32_t(pts[p][0])) * 4];
            CHECK(Near(got, want), "%s: rect %zu %s pixel (%u,%u) is %.3f %.3f %.3f %.3f, expected %.3f %.3f %.3f %.3f",
                  c.name, ri, kWhere[p], uint32_t(pts[p][0]), uint32_t(pts[p][1]), got[0], got[1], got[2], got[3],
                  want[0], want[1], want[2], want[3]);
        }
    }
    uint32_t stray = 0, holes = 0;
    for (uint32_t i = 0; i < kSize * kSize; i++) {
        const bool drawn = px[i * 4 + 3] != 0.f;
        if (drawn && !inside[i]) stray++;
        if (!drawn && inside[i]) holes++;
    }
    CHECK(stray == 0, "%s: %u pixels drawn outside the rectangles", c.name, stray);
    CHECK(holes == 0, "%s: %u pixels of the rectangles not drawn", c.name, holes);
}

} // namespace

int main() {
    @autoreleasepool {
        Fixture f;
        f.dev = MTLCreateSystemDefaultDevice();
        if (!f.dev) {
            std::fprintf(stderr, "gnm_rectlist_test: no Metal device\n");
            return 1;
        }
        if (!Setup(f)) return 1;
        // Corner at vertex 0, 1 and 2 (each with the other two in either order); colours chosen
        // so that the 4th vertex's colour (neighbours minus corner) stays in [0, 1].
        const TestRect a{{8, 24, 8}, {8, 8, 20}, {{0.5f, 0.5f, 0.5f, 1}, {1, 0.5f, 0.5f, 1}, {0.5f, 1, 0.5f, 1}}};
        const TestRect b{{56, 36, 36}, {30, 30, 50}, {{0.2f, 0.9f, 0.1f, 1}, {0.4f, 0.4f, 0.4f, 1}, {0.6f, 0.2f, 0.9f, 1}}};
        const TestRect cr{{30, 46, 46}, {4, 22, 4}, {{0.6f, 0.3f, 0.5f, 1}, {0.8f, 0.6f, 0.4f, 1}, {0.5f, 0.4f, 0.3f, 1}}};
        const TestRect d{{4, 4, 20}, {60, 44, 60}, {{0.9f, 0.1f, 0.1f, 1}, {0.7f, 0.6f, 0.3f, 1}, {0.3f, 0.2f, 0.6f, 1}}};
        const DrawCase cases[] = {
            {"non-indexed", {a, b, cr, d}, 0, false, 0, 1},
            {"non-indexed from vertex 9", {a, b, cr, d}, 9, false, 0, 1},
            {"indexed with base vertex", {b, d, a}, 0, true, 5, 1},
            {"instanced", {cr, a}, 0, false, 0, 3},
            {"back faces culled", {a, b, cr, d}, 0, false, 0, 1, true},
        };
        for (const DrawCase& c : cases) CheckRects(c, Render(f, c));
        gcn_rectlist_msl_free(&f.rect);
        gcn_shader_destroy(f.vs);
        if (g_fail) return 1;
        std::printf("gnm_rectlist_test: PASS\n");
    }
    return 0;
}
