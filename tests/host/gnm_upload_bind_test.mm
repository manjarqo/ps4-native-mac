// A texture upload encoded while a draw is being bound (the per-target serial, ps4_gnm_backend.h
// EncoderSerial): the draw's pixel shader reads a sampled texture that is not cached yet, so
// SampledTexture copies it from guest memory on the GPU, inside BindStage, into the texture-upload
// command buffer (GnmCmdTarget::Upload, its own blit encoder). The draw's render encoder stays open,
// and Main's encoder serial must not change: DrawEncode skips a draw whose encoder serial changed
// during its binding ("encoder restarted after a hazard flush"). Replayed through the real renderer
// (tools/gnm_replay) with a pass written by ps4gnm_capture::Writer.
//
// The pass: color target 0 is a GPU-owned RGBA8 unorm 64x8 surface adopted with A = (10, 20, 30,
// 40); a triangle covers it; the pixel shader image_loads texel (13, 5) of a 64x8 RGBA8 surface
// whose texel (x, y) holds P(x, y) = (4x, 30y, 77, 255) and exports it. Two cases: the texture is
// linear (the upload is a blit), or 1D-tiled (Thin1DThin: the upload is the detile compute
// dispatch, then the blit, both on the upload command buffer). Expected for each: the draw ran
// (not skipped), its one upload happened while binding, and every texel of the target is P(13, 5).
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>

#include <string>
#include <vector>

#include "gcn_recompiler.h"
#include "gnm_replay.h"
#include "ps4_gnm_capture.h"
#include "ps4_gnm_draw.h"
#include "ps4_gnm_resources.h"

using namespace ps4gnm_capture;

namespace {

int g_fail = 0;
#define CHECK(c, ...)                                                                    \
    do {                                                                                 \
        if (!(c)) {                                                                      \
            fprintf(stderr, "gnm_upload_bind_test: FAIL %s:%d: ", __FILE__, __LINE__); \
            fprintf(stderr, __VA_ARGS__);                                                \
            fprintf(stderr, "\n");                                                       \
            g_fail++;                                                                    \
        }                                                                                \
    } while (0)

constexpr uint64_t kMemSize = 1ull << 32;
constexpr uint64_t kVs = 0x140000, kPs = 0x150000, kVb = 0x160000, kRt = 0x300000;
constexpr uint32_t kW = 64, kH = 8;
constexpr uint32_t kEnd = 0xBF810000;
constexpr uint32_t kTexelX = 13, kTexelY = 5; // the texel the pixel shader loads
constexpr uint32_t kLinear = 8, kTiled1D = 13; // tiling indices (TileMode)

void Pattern(uint32_t x, uint32_t y, uint8_t out[4]) {
    out[0] = uint8_t(4 * x);
    out[1] = uint8_t(30 * y);
    out[2] = 77;
    out[3] = 255;
}

// T# of a surface at `addr`: FMT_8_8_8_8 unorm, 64 x 8, dst_sel xyzw, tiling index `tile`, 2D,
// pitch 64
std::vector<uint32_t> Tsharp(uint64_t addr, uint32_t tile) {
    return {uint32_t(addr >> 8), (10u << 20), 63 | (7u << 14),
            4 | (5 << 3) | (6 << 6) | (7 << 9) | (tile << 20) | (9u << 28), (63u << 13), 0, 0, 0};
}

// GCN program with the OrbShdr footer the translator looks for (as in gnm_replay_test).
std::vector<uint32_t> WithFooter(const std::vector<uint32_t>& body, uint64_t hash) {
    std::vector<uint32_t> code = {0xBEEB03FF, 0};
    code.insert(code.end(), body.begin(), body.end());
    while (code.size() % 2) code.push_back(0xBF800000);
    code[1] = uint32_t(code.size() / 2 - 1);
    uint8_t bi[32] = {'O', 'r', 'b', 'S', 'h', 'd', 'r', 7};
    const uint32_t w = (uint32_t(code.size() * 4) & 0xFFFFFF) << 8;
    memcpy(bi + 8, &w, 4);
    memcpy(bi + 16, &hash, 8);
    const size_t at = code.size();
    code.resize(at + 8);
    memcpy(&code[at], bi, 32);
    return code;
}

// VS: buffer_load_format_xyzw v[1:4], v0, s[0:3] idxen; exp param0, pos0 done (gnm_replay_test)
const std::vector<uint32_t> kProgVs = WithFooter({0xE00C2000, 0x80000100, 0xBF8C0F70, 0xF800020F, 0x04030201,
                                                  0xF80008CF, 0x04030201, kEnd},
                                                 0x5CA1AB1E000004B1ull);
// PS: v4 = 13; v5 = 5; image_load v[0:3], v[4:5], s[8:15] dmask:0xf unorm (a sampled image: not
// written); s_waitcnt; exp mrt0 v0, v1, v2, v3 done vm
const std::vector<uint32_t> kProgPs = WithFooter({0x7E08028D, 0x7E0A0285, 0xF0001F00, 0x00020004, 0xBF8C0F70,
                                                  0xF800180F, 0x03020100, kEnd},
                                                 0x5CA1AB1E000004B2ull);

// Color target 0 at kRt (8_8_8_8 unorm, linear aligned, 64 x 8); the VS reads 3 float4 vertices
// at kVb; the PS gets the T# of the texture (tex, tile) in user data 8-15.
std::vector<uint32_t> DrawRegs(uint64_t tex = 0, uint32_t tile = kLinear) {
    std::vector<uint32_t> regs(kNumRegs, 0);
    ps4draw::SetRegDefaults(regs.data());
    regs[0x2C48] = uint32_t(kVs >> 8); // SPI_SHADER_PGM_LO_VS
    regs[0x2C4A] = 1 | (1 << 6);       // RSRC1_VS: 8 VGPRs, 16 SGPRs
    regs[0x2C4B] = 4 << 1;             // RSRC2_VS: 4 user SGPRs
    uint32_t* vud = &regs[0x2C4C];     // V# of the vertices: float4, stride 16, 3 records
    vud[0] = uint32_t(kVb);
    vud[1] = 16u << 16;
    vud[2] = 3;
    vud[3] = 4 | (5 << 3) | (6 << 6) | (7 << 9) | (7 << 12) | (14 << 15);
    regs[0x2C08] = uint32_t(kPs >> 8); // SPI_SHADER_PGM_LO_PS
    regs[0x2C0A] = 1 | (1 << 6);       // RSRC1_PS: 8 VGPRs, 16 SGPRs
    regs[0x2C0B] = 16 << 1;            // RSRC2_PS: 16 user SGPRs
    const std::vector<uint32_t> t = Tsharp(tex, tile);
    memcpy(&regs[0x2C0C + 8], t.data(), 32); // SPI_SHADER_USER_DATA_PS_8..15
    regs[0xA1B3] = regs[0xA1B4] = 2;         // SPI_PS_INPUT_ENA / ADDR: PERSP_CENTER
    regs[0xA1B6] = 0;
    regs[0xA1B1] = 0;
    regs[0xA1C3] = 4; // SPI_SHADER_POS_FORMAT: POS0 4 components
    regs[0xA1C5] = 9; // SPI_SHADER_COL_FORMAT: MRT0 32_ABGR
    regs[0xA08E] = regs[0xA08F] = 0xF;
    regs[0xA202] = (1 << 4) | (0xCC << 16); // CB_COLOR_CONTROL: normal, copy
    regs[0xA206] = 0x43F;                  // PA_CL_VTE_CNTL
    const float vp[6] = {kW / 2.0f, kW / 2.0f, kH / 2.0f, kH / 2.0f, 0.5f, 0.5f};
    memcpy(&regs[0xA10F], vp, sizeof(vp));
    regs[0xA205] = 0; // no culling
    regs[0xC242] = 4; // triangle list
    uint32_t* cb = &regs[0xA318]; // CB_COLOR0_*
    cb[0] = uint32_t(kRt >> 8);
    cb[1] = kW / 8 - 1;       // PITCH: 64
    cb[2] = kW * kH / 64 - 1; // SLICE: 64 x 8
    cb[4] = (10u << 2);       // INFO: 8_8_8_8, unorm
    cb[5] = 8;                // ATTRIB: linear aligned
    return regs;
}

// The identity GetColorTarget gives color target 0 of DrawRegs().
GpuTextureId ColorId() {
    const std::vector<uint32_t> regs = DrawRegs();
    ps4gnm::ColorTarget ct;
    ps4gnm::DecodeColorTarget(regs.data(), 0, &ct);
    GpuTextureId g;
    g.kind = 1;
    g.address = ct.address;
    g.mtl_format = g.entry_format = ct.mtl_format;
    g.tex_type = g.mtl_type = (uint32_t)MTLTextureType2D;
    g.width = g.mtl_width = kW;
    g.height = g.mtl_height = kH;
    g.dfmt = (uint32_t)ct.dfmt;
    g.nfmt = (uint32_t)ct.nfmt;
    for (uint32_t k = 0; k < 4; ++k) g.cb_swizzle[k] = (uint8_t)ct.swizzle[k];
    g.usage = (uint32_t)(MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite |
                         MTLTextureUsagePixelFormatView);
    g.storage_mode = (uint32_t)MTLStorageModeShared;
    ps4gnm::SurfaceDesc sd = ct.ToSurfaceDesc();
    sd.width = kW;
    sd.height = kH;
    ps4gnm::SurfaceLayout l;
    ct.GetLayout(&l);
    g.size = l.total_size;
    ps4gnm::PackSurface(sd, l, &g.surface);
    return g;
}

// Writes <root>/frame_1 with the one draw pass, sampling the texture at `tex` with tiling `tile`.
std::string WriteFrame(const std::string& root, uint64_t tex, uint32_t tile) {
    uint8_t* mem = (uint8_t*)mmap(nullptr, kMemSize, PROT_READ | PROT_WRITE, MAP_ANON | MAP_PRIVATE, -1, 0);
    const std::string dir = root + "/frame_1";
    Writer w(dir, 1, kMemSize, false, gcn_shader_cache_id());
    std::string err;
    CHECK(w.Begin(&err), "%s", err.c_str());
    memcpy(mem + kVs, kProgVs.data(), kProgVs.size() * 4);
    memcpy(mem + kPs, kProgPs.data(), kProgPs.size() * 4);
    const float verts[12] = {-3, -3, 0.5f, 1, -3, 9, 0.5f, 1, 9, -3, 0.5f, 1}; // covers the whole target
    memcpy(mem + kVb, verts, sizeof(verts));
    // P in the texture's guest memory, at each texel's (tiled) address
    ps4gnm::ImageDesc img;
    const std::vector<uint32_t> ts = Tsharp(tex, tile);
    CHECK(ps4gnm::DecodeImage(ts.data(), 8, &img) && img.valid, "T# of tiling %u does not decode", tile);
    const ps4gnm::SurfaceDesc sd = img.ToSurfaceDesc();
    ps4gnm::SurfaceLayout layout;
    CHECK(ps4gnm::ComputeSurfaceLayout(sd, &layout), "no layout for tiling %u", tile);
    CHECK(layout.total_size <= kPage, "tiling %u: %llu bytes, more than one snapshot page", tile,
          (unsigned long long)layout.total_size);
    for (uint32_t y = 0; y < kH; ++y)
        for (uint32_t x = 0; x < kW; ++x) {
            const uint64_t at = tile == kLinear ? (uint64_t)(y * kW + x) * 4
                                                : ps4gnm::TiledElementOffset(sd, layout, 0, x, y, 0);
            Pattern(x, y, mem + tex + at);
        }
    const std::vector<uint32_t> regs = DrawRegs(tex, tile);
    PassRec p;
    p.index = 0;
    p.replayable = true;
    p.type = "draw";
    p.queue = "gfx";
    p.name = "DRAW_INDEX_AUTO";
    p.count = 3;
    p.cb_extent[0] = kW | kH << 16;
    p.regs_file = w.SaveRegs(regs.data(), &p.regs_hash);
    p.inputs.push_back(w.Snapshot(mem, kVs, kPage));
    p.inputs.push_back(w.Snapshot(mem, kPs, kPage));
    p.inputs.push_back(w.Snapshot(mem, kVb, kPage));
    p.inputs.push_back(w.Snapshot(mem, tex, kPage));
    const GpuTextureId tid = ColorId();
    std::vector<uint8_t> a(RawSize(tid)), c(RawSize(tid));
    uint8_t want[4];
    Pattern(kTexelX, kTexelY, want);
    for (size_t i = 0; i + 3 < a.size(); i += 4) {
        const uint8_t av[4] = {10, 20, 30, 40};
        memcpy(&a[i], av, 4);
        memcpy(&c[i], want, 4);
    }
    TextureRec t;
    t.role = "t0_color0";
    t.written = true;
    t.id = tid;
    t.pre_file = w.SaveTexture(p.index, t.role, "pre", a, &t.pre_hash);
    t.post_file = w.SaveTexture(p.index, t.role, "post", c, &t.post_hash);
    p.textures.push_back(t);
    w.AddPass(std::move(p));
    CHECK(w.Finish(&err), "%s", err.c_str());
    munmap(mem, kMemSize);
    return dir;
}

} // namespace

int main() {
    // every sampled texture not cached yet is copied on the GPU (not only those of 256 KiB and up)
    setenv("PS4_GNM_GPU_UPLOAD_MIN_KB", "0", 1);
    @autoreleasepool {
        char tmpl[] = "/tmp/gnm_upload_bind_test.XXXXXX";
        const char* root = mkdtemp(tmpl);
        if (!root) return 1;
        uint8_t want[4];
        Pattern(kTexelX, kTexelY, want);
        const struct {
            const char* name;
            uint64_t tex;
            uint32_t tile;
        } cases[] = {{"linear", 0x340000, kLinear}, {"1D tiled (detile on the upload command buffer)", 0x380000, kTiled1D}};
        for (const auto& k : cases) {
            const std::string dir = WriteFrame(std::string(root) + "/" + std::to_string(k.tile), k.tex, k.tile);
            ps4replay::Options o;
            o.frame_dir = dir;
            o.keep_outputs = true;
            o.pass = 0;
            const uint64_t uploads0 = ps4draw::BindUploadCount();
            const ps4replay::Result r = ps4replay::ReplayPass(o);
            const uint64_t uploads = ps4draw::BindUploadCount() - uploads0;
            CHECK(r.ran, "%s: the draw was not replayed: %s", k.name, r.error.c_str());
            CHECK(uploads == 1, "%s: %llu GPU uploads while binding, want 1 (the case is not reached)", k.name,
                  (unsigned long long)uploads);
            bool found = false;
            for (const ps4replay::OutputResult& out : r.outputs) {
                if (!out.is_texture || out.what != "t0_color0") continue;
                found = true;
                uint32_t bad = 0, first = 0;
                for (uint32_t i = 0; i + 3 < out.bytes.size(); i += 4)
                    if (memcmp(&out.bytes[i], want, 4)) {
                        if (!bad) first = i / 4;
                        bad++;
                    }
                const uint8_t* f = out.bytes.empty() ? want : &out.bytes[first * 4];
                CHECK(!out.bytes.empty() && !bad, "%s: %u of %u texels are not P(%u, %u); texel %u is %u %u %u %u", k.name,
                      bad, kW * kH, kTexelX, kTexelY, first, f[0], f[1], f[2], f[3]);
                CHECK(out.compared && out.match, "%s: the target differs from the expected one (%llu bytes)", k.name,
                      (unsigned long long)out.diff_bytes);
            }
            CHECK(!r.ran || found, "%s: the color target was not returned", k.name);
        }
        const std::string cmd = std::string("rm -rf '") + root + "'";
        if (system(cmd.c_str()) != 0) g_fail++;
        if (g_fail) {
            fprintf(stderr, "gnm_upload_bind_test: %d failure(s)\n", g_fail);
            return 1;
        }
        printf("gnm_upload_bind_test: PASS\n");
        return 0;
    }
}
