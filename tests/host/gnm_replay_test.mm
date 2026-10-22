// Pass replay (tools/gnm_replay) through the real renderer on a synthetic capture written with
// ps4gnm_capture::Writer: a compute dispatch storing out[i] = i is translated, bound and encoded
// by ps4draw::Dispatch and its output matches the captured bytes; a capture whose output was
// altered is reported as a mismatch at the altered byte; a pass that is not replayable is
// refused with its reason; GPU-owned textures created from captured identities hold the
// captured contents (mip levels, depth and stencil planes); replay_props decodes and measures
// replayed outputs.
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>

#include <string>
#include <vector>

#include "gcn_recompiler.h"
#include "gcn_stores.h"
#include "gnm_replay.h"
#include "ps4_gnm_capture.h"
#include "ps4_gnm_draw.h"
#include "ps4_gnm_resources.h"
#include "replay_props.h"

using namespace ps4gnm_capture;

namespace {

int g_fail = 0;
#define CHECK(c, ...)                                                               \
    do {                                                                            \
        if (!(c)) {                                                                 \
            fprintf(stderr, "gnm_replay_test: FAIL %s:%d: ", __FILE__, __LINE__);   \
            fprintf(stderr, __VA_ARGS__);                                           \
            fprintf(stderr, "\n");                                                  \
            g_fail++;                                                               \
        }                                                                           \
    } while (0)

constexpr uint64_t kMemSize = 1ull << 32;
constexpr uint64_t kCode = 0x100000, kOut = 0x200000;
constexpr uint32_t kEnd = 0xBF810000;

// GCN program with the OrbShdr footer the translator looks for (as in gcn_wave_exec_test).
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

// Writes <root>/frame_1 with one replayable dispatch: v2 = v0 << 2; v1 = v0;
// buffer_store_dword v1, v2, s[4:7] offen (64 threads, out[i] = i). corrupt_at >= 0: the
// captured output has byte corrupt_at changed.
std::string WriteCapture(const std::string& root, int corrupt_at) {
    uint8_t* mem = (uint8_t*)mmap(nullptr, kMemSize, PROT_READ | PROT_WRITE, MAP_ANON | MAP_PRIVATE, -1, 0);
    const auto prog = WithFooter({0x34040082, 0x7E020300, 0xE0701000, 0x80010102, kEnd}, 0x5CA1AB1E000000A1ull);
    memcpy(mem + kCode, prog.data(), prog.size() * 4);
    memset(mem + kOut, 0xAB, kPage); // the output's memory before the pass
    std::vector<uint32_t> regs(kNumRegs, 0);
    regs[0x2E07] = 64; // COMPUTE_NUM_THREAD_X
    regs[0x2E08] = regs[0x2E09] = 1;
    regs[0x2E0C] = uint32_t(kCode >> 8); // COMPUTE_PGM_LO
    regs[0x2E12] = 1;                    // RSRC1: 8 VGPRs
    regs[0x2E13] = 8 << 1;               // RSRC2: 8 user SGPRs
    uint32_t* ud = &regs[0x2E40];        // COMPUTE_USER_DATA_0..
    ud[4] = uint32_t(kOut);              // V#: base, stride 0, 256 bytes, 32-bit uint
    ud[5] = 0;
    ud[6] = 256;
    ud[7] = 4 | (5 << 3) | (6 << 6) | (7 << 9) | (4 << 12) | (4 << 15);
    const std::string dir = root + "/frame_1";
    Writer w(dir, 1, kMemSize, false, gcn_shader_cache_id());
    std::string err;
    CHECK(w.Begin(&err), "%s", err.c_str());
    PassRec p;
    p.index = 0;
    p.replayable = true;
    p.type = "dispatch";
    p.queue = p.name = "gfx";
    p.regs_file = w.SaveRegs(regs.data(), &p.regs_hash);
    p.dim[0] = p.dim[1] = p.dim[2] = 1;
    BufferRec b;
    b.stage = "cs";
    b.addr = kOut;
    b.size = 256;
    b.written = true;
    memcpy(b.vsharp, &ud[4], 16);
    p.buffers.push_back(b);
    p.inputs.push_back(w.Snapshot(mem, kCode, kPage));
    p.inputs.push_back(w.Snapshot(mem, kOut, kPage));
    for (uint32_t i = 0; i < 64; ++i) memcpy(mem + kOut + 4 * i, &i, 4); // what the pass must leave
    if (corrupt_at >= 0) mem[kOut + corrupt_at] ^= 0x40;
    p.outputs.push_back(w.Snapshot(mem, kOut, 256));
    w.AddPass(std::move(p));
    PassRec skipped;
    skipped.index = 1;
    skipped.type = "dispatch";
    skipped.skipped = "meta clear";
    w.AddPass(std::move(skipped));
    CHECK(w.Finish(&err), "%s", err.c_str());
    munmap(mem, kMemSize);
    return dir;
}

void TestDispatchReplay(const std::string& root) {
    ps4replay::Options o;
    o.frame_dir = WriteCapture(root + "/good", -1);
    o.keep_outputs = true;
    ps4replay::Result r = ps4replay::ReplayPass(o);
    CHECK(r.ran, "not replayed: %s", r.error.c_str());
    CHECK(r.outputs.size() == 1 && r.AllMatch(), "replay differs from the capture (%zu outputs, %llu bytes differ)",
          r.outputs.size(), r.outputs.empty() ? 0ull : (unsigned long long)r.outputs[0].diff_bytes);
    if (r.outputs.size() == 1 && r.outputs[0].bytes.size() == 256) {
        uint32_t v[64];
        memcpy(v, r.outputs[0].bytes.data(), 256);
        CHECK(v[0] == 0 && v[17] == 17 && v[63] == 63, "out = %u %u %u", v[0], v[17], v[63]);
    }
    // the same pass against an altered capture: one byte differs, at offset 4 * 9 + 1
    o.frame_dir = WriteCapture(root + "/bad", 4 * 9 + 1);
    r = ps4replay::ReplayPass(o);
    CHECK(r.ran && r.outputs.size() == 1 && !r.AllMatch(), "altered capture not reported");
    if (r.outputs.size() == 1)
        CHECK(r.outputs[0].compared && r.outputs[0].diff_bytes == 1 && r.outputs[0].first_diff == 37,
              "diff %llu bytes, first at %llu", (unsigned long long)r.outputs[0].diff_bytes,
              (unsigned long long)r.outputs[0].first_diff);
    o.pass = 1;
    r = ps4replay::ReplayPass(o);
    CHECK(!r.ran && r.error.find("meta clear") != std::string::npos, "skipped pass: %s", r.error.c_str());
}

// The extractor's output is a frame the replay accepts: tools/gnm_capture_extract.py cuts the
// dispatch of WriteCapture out of its frame (pass 0 of 2), and the extracted frame replays like
// the original, byte for byte with --keep-outputs and with nothing compared without.
void TestExtractedFixture(const std::string& root) {
    const std::string tool = std::string(PS4_REPO_ROOT) + "/tools/gnm_capture_extract.py"; // set by build.sh
    const std::string src = WriteCapture(root + "/ex_src", -1);
    for (int keep = 1; keep >= 0; --keep) {
        const std::string out = root + (keep ? "/ex_keep" : "/ex_drop");
        const std::string cmd = "python3 '" + tool + "' '" + src + "' 0 '" + out + "'" + (keep ? " --keep-outputs" : "") +
                                " > /dev/null";
        CHECK(system(cmd.c_str()) == 0, "extractor failed: %s", cmd.c_str());
        ps4replay::Options o;
        o.frame_dir = out;
        o.pass = 0;
        o.keep_outputs = true;
        const ps4replay::Result r = ps4replay::ReplayPass(o);
        CHECK(r.ran, "extracted frame not replayed: %s", r.error.c_str());
        if (keep) {
            CHECK(r.outputs.size() == 1 && r.AllMatch(), "extracted frame differs from its capture");
            uint32_t v[64];
            CHECK(r.outputs.size() == 1 && r.outputs[0].bytes.size() == 256 &&
                      (memcpy(v, r.outputs[0].bytes.data(), 256), v[0] == 0 && v[63] == 63),
                  "extracted frame output");
        } else {
            CHECK(r.outputs.size() == 1 && !r.outputs[0].compared && r.outputs[0].bytes.size() == 256,
                  "fixture without outputs: replayed output missing or compared");
        }
    }
}

void TestTextureSeeding() {
    // a color target with two mip levels
    GpuTextureId c;
    c.kind = 1;
    c.address = 0x30000000;
    c.mtl_format = c.entry_format = kRGBA16Float;
    c.tex_type = c.mtl_type = (uint32_t)MTLTextureType2D;
    c.width = c.mtl_width = 8;
    c.height = c.mtl_height = 8;
    c.levels = c.mtl_levels = 2;
    c.usage = (uint32_t)(MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite | MTLTextureUsageRenderTarget |
                         MTLTextureUsagePixelFormatView);
    c.storage_mode = (uint32_t)MTLStorageModeShared;
    c.surface.assign(ps4gnm::kPackedSurfaceWords, 0);
    std::vector<uint8_t> raw(RawSize(c));
    for (size_t i = 0; i < raw.size(); ++i) raw[i] = (uint8_t)(i * 7 + 3);
    std::vector<uint8_t> back;
    CHECK(ps4draw::ReplayAdoptTexture(c, &raw), "color texture not created");
    CHECK(ps4draw::ReplayReadTexture(c, &back) && back == raw, "color contents differ (%zu bytes)", back.size());
    // a depth+stencil target (private storage): both planes
    GpuTextureId d = c;
    d.kind = 2;
    d.address = 0x31000000;
    d.mtl_format = d.entry_format = kDepth32Float_Stencil8;
    d.width = d.mtl_width = 16;
    d.height = d.mtl_height = 4;
    d.levels = d.mtl_levels = 1;
    d.usage = (uint32_t)(MTLTextureUsageShaderRead | MTLTextureUsageRenderTarget);
    d.storage_mode = (uint32_t)MTLStorageModePrivate;
    std::vector<uint8_t> draw_(RawSize(d));
    for (size_t i = 0; i < 64; ++i) {
        const float z = i / 64.0f;
        memcpy(&draw_[i * 4], &z, 4);
        draw_[256 + i] = (uint8_t)(i + 1);
    }
    CHECK(ps4draw::ReplayAdoptTexture(d, &draw_), "depth texture not created");
    CHECK(ps4draw::ReplayReadTexture(d, &back) && back == draw_, "depth/stencil contents differ");
    // another identity at the same address is not that texture
    GpuTextureId other = c;
    other.width = other.mtl_width = 4;
    CHECK(!ps4draw::ReplayReadTexture(other, &back), "texture found under another identity");
}

// ---- A draw that samples an adopted texture, with and without a pending fast clear ----
// 8x8 RGBA16Float target T (kind 1 entry, as GetColorTarget makes it) and 8x8 RGBA16Float
// sampled texture A (a GPU-owned entry: GetTexture aliases it). The VS draws a triangle whose
// right edge is the vertical line x = 4 (NDC 0) and that covers the whole left half; the PS
// samples A at the centre of texel (2, 2) (point filter, level 0) and exports it. Columns 0-3
// become A's texel (2, 2); columns 4-7 keep T's contents before the pass or, with the CMASK fast
// clear pending (PassRec::meta_cleared), get the clear colour of CB_COLOR0_CLEAR_WORD0/1.
constexpr uint64_t kVs = 0x110000, kPs = 0x120000, kVb = 0x130000;
constexpr uint64_t kTarget = 0x32000000, kSampled = 0x33000000, kCmask = 0x34000000;
constexpr uint16_t kClear[4] = {0x3400, 0x3800, 0x3A00, 0x3C00}; // 0.25 0.5 0.75 1.0

std::vector<uint32_t> DrawRegs() {
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
    regs[0x2C0A] = 1 | (1 << 6);
    regs[0x2C0B] = 12 << 1; // T# s[0:7], S# s[8:11]
    uint32_t* pud = &regs[0x2C0C];
    pud[0] = uint32_t(kSampled >> 8);
    pud[1] = (12u << 20) | (7u << 26);       // 16_16_16_16, float
    pud[2] = 7 | (7u << 14);                 // 8 x 8
    pud[3] = 4 | (5 << 3) | (6 << 6) | (7 << 9) | (8u << 20) | (9u << 28); // xyzw, linear aligned, 2D
    pud[4] = 7u << 13;                       // pitch 8
    // pud[8..11]: S# all zero = wrap, point filters, LOD 0
    regs[0xA1B3] = regs[0xA1B4] = 2; // SPI_PS_INPUT_ENA / ADDR: PERSP_CENTER
    regs[0xA1B6] = 0;                // SPI_PS_IN_CONTROL: no interpolants
    regs[0xA1B1] = 0;                // SPI_VS_OUT_CONFIG: 1 parameter
    regs[0xA1C3] = 4;                // SPI_SHADER_POS_FORMAT: POS0 4 components
    regs[0xA1C5] = 9;                // SPI_SHADER_COL_FORMAT: MRT0 32_ABGR
    regs[0xA08E] = regs[0xA08F] = 0xF; // CB_TARGET_MASK / CB_SHADER_MASK
    regs[0xA202] = (1 << 4) | (0xCC << 16); // CB_COLOR_CONTROL: normal, copy
    regs[0xA206] = 0x43F;                  // PA_CL_VTE_CNTL
    const float vp[6] = {4, 4, 4, 4, 0.5f, 0.5f}; // 8 x 8 viewport, z in [0, 1]
    memcpy(&regs[0xA10F], vp, sizeof(vp));
    regs[0xA205] = 0;    // PA_SU_SC_MODE_CNTL: no culling
    regs[0xC242] = 4;    // VGT_PRIMITIVE_TYPE: triangle list
    uint32_t* cb = &regs[0xA318]; // CB_COLOR0_*
    cb[0] = uint32_t(kTarget >> 8);
    cb[1] = 0;                          // PITCH: 8
    cb[2] = 0;                          // SLICE: 8 x 8
    cb[4] = (12u << 2) | (7u << 8) | (1u << 13); // INFO: 16_16_16_16, float, FAST_CLEAR
    cb[5] = 8;                          // ATTRIB: linear aligned
    cb[7] = uint32_t(kCmask >> 8);      // CMASK
    cb[11] = kClear[0] | uint32_t(kClear[1]) << 16;
    cb[12] = kClear[2] | uint32_t(kClear[3]) << 16;
    return regs;
}

// The identities GetColorTarget / the texture cache give T and A (ps4_gnm_resources).
GpuTextureId TargetId(const std::vector<uint32_t>& regs) {
    ps4gnm::ColorTarget ct;
    ps4gnm::DecodeColorTarget(regs.data(), 0, &ct);
    GpuTextureId g;
    g.kind = 1;
    g.address = ct.address;
    g.mtl_format = g.entry_format = ct.mtl_format;
    g.tex_type = g.mtl_type = (uint32_t)MTLTextureType2D;
    g.width = g.mtl_width = 8;
    g.height = g.mtl_height = 8;
    g.dfmt = (uint32_t)ct.dfmt;
    g.nfmt = (uint32_t)ct.nfmt;
    for (uint32_t k = 0; k < 4; ++k) g.cb_swizzle[k] = (uint8_t)ct.swizzle[k];
    g.usage = (uint32_t)(MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite |
                         MTLTextureUsagePixelFormatView);
    g.storage_mode = (uint32_t)MTLStorageModeShared;
    ps4gnm::SurfaceDesc sd = ct.ToSurfaceDesc();
    sd.width = 8;
    sd.height = 8;
    ps4gnm::SurfaceLayout l;
    ct.GetLayout(&l);
    g.size = l.total_size;
    ps4gnm::PackSurface(sd, l, &g.surface);
    return g;
}

GpuTextureId SampledId() {
    GpuTextureId g;
    g.kind = 1;
    g.address = kSampled;
    g.mtl_format = g.entry_format = kRGBA16Float;
    g.tex_type = g.mtl_type = (uint32_t)MTLTextureType2D;
    g.width = g.mtl_width = g.height = g.mtl_height = 8;
    g.size = 8 * 8 * 8;
    g.dfmt = 12;
    g.nfmt = 7;
    g.usage = (uint32_t)(MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite | MTLTextureUsageRenderTarget |
                         MTLTextureUsagePixelFormatView);
    g.storage_mode = (uint32_t)MTLStorageModeShared;
    g.surface.assign(ps4gnm::kPackedSurfaceWords, 0);
    return g;
}

// Writes <root>/frame_1 with the draw as pass 0; `pending`: the CMASK fast clear is pending.
std::string WriteDrawCapture(const std::string& root, bool pending, std::vector<uint8_t>* want) {
    uint8_t* mem = (uint8_t*)mmap(nullptr, kMemSize, PROT_READ | PROT_WRITE, MAP_ANON | MAP_PRIVATE, -1, 0);
    // VS: buffer_load_format_xyzw v[1:4], v0, s[0:3] idxen; exp param0, pos0 done
    const auto vs = WithFooter({0xE00C2000, 0x80000100, 0xBF8C0F70, 0xF800020F, 0x04030201, 0xF80008CF, 0x04030201,
                                kEnd},
                               0x5CA1AB1E000000B1ull);
    // PS: v0 = v1 = 0.3125; image_sample_lz v[0:3], v[0:1], s[0:7], s[8:11] dmask 0xf; exp mrt0 done vm
    const auto ps = WithFooter({0x7E0002FF, 0x3EA00000, 0x7E0202FF, 0x3EA00000, 0xF09C0F00, 0x00400000, 0xBF8C0F70,
                                0xF800180F, 0x03020100, kEnd},
                               0x5CA1AB1E000000B2ull);
    memcpy(mem + kVs, vs.data(), vs.size() * 4);
    memcpy(mem + kPs, ps.data(), ps.size() * 4);
    const float verts[12] = {0, -3, 0.5f, 1, 0, 3, 0.5f, 1, -4, 0, 0.5f, 1};
    memcpy(mem + kVb, verts, sizeof(verts));
    const std::vector<uint32_t> regs = DrawRegs();
    const GpuTextureId tid = TargetId(regs), sid = SampledId();
    std::vector<uint8_t> tpre(RawSize(tid)), sraw(RawSize(sid));
    for (size_t i = 0; i < tpre.size(); ++i) tpre[i] = (uint8_t)(i * 13 + 5);
    for (size_t i = 0; i < sraw.size(); i += 2) { // finite halves: exponent bits never all ones
        const uint16_t h = (uint16_t)(0x2000 + i * 37 % 0x3000);
        memcpy(&sraw[i], &h, 2);
    }
    // what the pass must leave
    *want = tpre;
    for (uint32_t y = 0; y < 8; ++y)
        for (uint32_t x = 0; x < 8; ++x) {
            uint8_t* px = want->data() + (y * 8 + x) * 8;
            if (x < 4) memcpy(px, &sraw[(2 * 8 + 2) * 8], 8);
            else if (pending) memcpy(px, kClear, 8);
        }
    const std::string dir = root + "/frame_1";
    Writer w(dir, 1, kMemSize, false, gcn_shader_cache_id());
    std::string err;
    CHECK(w.Begin(&err), "%s", err.c_str());
    PassRec p;
    p.index = 0;
    p.replayable = true;
    p.type = "draw";
    p.queue = "gfx";
    p.name = "DRAW_INDEX_AUTO";
    p.count = 3;
    p.cb_extent[0] = 8 | 8 << 16;
    p.regs_file = w.SaveRegs(regs.data(), &p.regs_hash);
    if (pending) p.meta_cleared.push_back(kCmask);
    TextureRec t;
    t.role = "t0_color0";
    t.written = true;
    t.id = tid;
    t.pre_file = w.SaveTexture(0, t.role, "pre", tpre, &t.pre_hash);
    t.post_file = w.SaveTexture(0, t.role, "post", *want, &t.post_hash);
    p.textures.push_back(t);
    TextureRec a;
    a.role = "t1_sampled";
    a.id = sid;
    a.pre_file = w.SaveTexture(0, a.role, "pre", sraw, &a.pre_hash);
    p.textures.push_back(a);
    p.inputs.push_back(w.Snapshot(mem, kVs, kPage));
    p.inputs.push_back(w.Snapshot(mem, kPs, kPage));
    p.inputs.push_back(w.Snapshot(mem, kVb, kPage));
    w.AddPass(std::move(p));
    CHECK(w.Finish(&err), "%s", err.c_str());
    munmap(mem, kMemSize);
    return dir;
}

void TestDrawReplay(const std::string& root) {
    for (int pending = 0; pending < 2; ++pending) {
        ps4replay::Options o;
        std::vector<uint8_t> want;
        o.frame_dir = WriteDrawCapture(root + (pending ? "/draw_clear" : "/draw"), pending, &want);
        o.keep_outputs = true;
        const ps4replay::Result r = ps4replay::ReplayPass(o);
        CHECK(r.ran, "draw (fast clear pending %d) not replayed: %s", pending, r.error.c_str());
        const ps4replay::OutputResult* c = replay_props::Find(r, "_color0");
        CHECK(c && c->compared && c->match, "draw (fast clear pending %d): %llu bytes differ, first at %llu", pending,
              c ? (unsigned long long)c->diff_bytes : 0ull, c ? (unsigned long long)c->first_diff : 0ull);
        if (c && c->bytes.size() == want.size() && !c->match) {
            uint16_t got[4], exp[4];
            memcpy(got, c->bytes.data() + (3 * 8 + 1) * 8, 8);
            memcpy(exp, want.data() + (3 * 8 + 1) * 8, 8);
            fprintf(stderr, "  texel (1, 3): %04x %04x %04x %04x, expected %04x %04x %04x %04x\n", got[0], got[1],
                    got[2], got[3], exp[0], exp[1], exp[2], exp[3]);
            memcpy(got, c->bytes.data() + (3 * 8 + 6) * 8, 8);
            memcpy(exp, want.data() + (3 * 8 + 6) * 8, 8);
            fprintf(stderr, "  texel (6, 3): %04x %04x %04x %04x, expected %04x %04x %04x %04x\n", got[0], got[1],
                    got[2], got[3], exp[0], exp[1], exp[2], exp[3]);
        }
    }
    // the target's contents after the pass did not fit the raw budget (no post file, readback
    // "budget") while its contents before the pass were stored: the pass still replays, and that
    // output is reported as not captured
    std::vector<uint8_t> want;
    const std::string dir = WriteDrawCapture(root + "/draw_budget", 0, &want);
    FrameRec f;
    std::string err;
    CHECK(LoadFrame(dir, &f, &err) && !f.passes.empty(), "draw_budget manifest: %s", err.c_str());
    if (f.passes.empty()) return;
    bool budgeted = false;
    for (TextureRec& t : f.passes[0].textures)
        if (t.written && !t.pre_file.empty()) {
            t.post_file.clear();
            t.readback = kReadbackBudget;
            budgeted = true;
        }
    const std::string text = WriteManifest(f);
    CHECK(budgeted && WriteFile(dir + "/manifest.json", text.data(), text.size()), "draw_budget: no written target");
    ps4replay::Options o;
    o.frame_dir = dir;
    o.pass = f.passes[0].index;
    const ps4replay::Result r = ps4replay::ReplayPass(o);
    CHECK(r.ran, "draw whose target after the pass was over budget not replayed: %s", r.error.c_str());
    const ps4replay::OutputResult* c = replay_props::Find(r, "_color0");
    CHECK(c && !c->compared, "draw_budget: the target is compared although nothing was captured after the pass");
    // any other reason (the contents could not be read back) refuses the pass, pre file or not
    for (TextureRec& t : f.passes[0].textures)
        if (t.readback == kReadbackBudget) t.readback = "readback failed";
    const std::string text2 = WriteManifest(f);
    CHECK(WriteFile(dir + "/manifest.json", text2.data(), text2.size()), "draw_budget: manifest");
    const ps4replay::Result r2 = ps4replay::ReplayPass(o);
    CHECK(!r2.ran && r2.error.find("readback failed") != std::string::npos,
          "a target whose contents could not be read back replayed: %s", r2.error.c_str());
}

// ScanGcnStores (the replay's note on passes with no recorded output) on the programs above:
// the dispatch's buffer_store_dword is found; the pixel shader (image_sample_lz, export) and the
// vertex shader (buffer_load_format) write no memory; an image_store is found as one. The scan is
// given the code without the footer, as the replay does (code_size).
void TestStoreScan() {
    constexpr size_t kFooter = 8; // dwords of OrbShdr footer WithFooter appends
    const auto cs = WithFooter({0x34040082, 0x7E020300, 0xE0701000, 0x80010102, kEnd}, 1);
    const auto ps = WithFooter({0x7E0002FF, 0x3EA00000, 0x7E0202FF, 0x3EA00000, 0xF09C0F00, 0x00400000, 0xBF8C0F70,
                                0xF800180F, 0x03020100, kEnd}, 2);
    const auto vs = WithFooter({0xE00C2000, 0x80000100, 0xBF8C0F70, 0xF800020F, 0x04030201, 0xF80008CF, 0x04030201,
                                kEnd}, 3);
    const auto st = WithFooter({0xF0200F00, 0x00000000, kEnd}, 4); // image_store v[0:3], v[0:1], s[0:7]
    const ps4replay::GcnStores a = ps4replay::ScanGcnStores(cs.data(), cs.size() - kFooter);
    const ps4replay::GcnStores b = ps4replay::ScanGcnStores(ps.data(), ps.size() - kFooter);
    const ps4replay::GcnStores c = ps4replay::ScanGcnStores(vs.data(), vs.size() - kFooter);
    const ps4replay::GcnStores d = ps4replay::ScanGcnStores(st.data(), st.size() - kFooter);
    CHECK(a.complete && a.buffer == 1 && a.Total() == 1, "dispatch: %s", a.Describe().c_str());
    CHECK(b.complete && b.Total() == 0, "pixel shader: %s", b.Describe().c_str());
    CHECK(c.complete && c.Total() == 0, "vertex shader: %s", c.Describe().c_str());
    CHECK(d.complete && d.image == 1 && d.Total() == 1, "image_store: %s", d.Describe().c_str());

    // opcode ranges: the last MIMG atomic (31) and the last FLAT store (31) count; the opcodes
    // next to the ranges do not (MIMG 14 and 32, FLAT 23 and 32). Each program is one instruction.
    auto mimg = [](uint32_t op) { return std::vector<uint32_t>{(0x3Cu << 26) | (op << 18) | 0xF00, 0u, kEnd}; };
    auto flat = [](uint32_t op) { return std::vector<uint32_t>{(0x37u << 26) | (op << 18), 0u, kEnd}; };
    auto mubuf = [](uint32_t op) { return std::vector<uint32_t>{(0x38u << 26) | (op << 18), 0u, kEnd}; };
    auto scan = [](const std::vector<uint32_t>& v) { return ps4replay::ScanGcnStores(v.data(), v.size()); };
    CHECK(scan(mimg(15)).image == 1 && scan(mimg(31)).image == 1, "MIMG atomics 15 and 31 counted");
    CHECK(scan(mimg(14)).image == 0 && scan(mimg(32)).image == 0, "MIMG 14 and 32 not counted");
    CHECK(scan(flat(24)).flat == 1 && scan(flat(31)).flat == 1, "FLAT stores 24 and 31 counted");
    CHECK(scan(flat(23)).flat == 0 && scan(flat(32)).flat == 0, "FLAT 23 and 32 not counted");

    // CI ISA: the atomics run 48-64 and 80-96 (FMIN_X2 95, FMAX_X2 96); 47, 97 are not atomics
    CHECK(scan(mubuf(48)).buffer == 1 && scan(mubuf(95)).buffer == 1 && scan(mubuf(96)).buffer == 1,
          "MUBUF atomics 48, 95 and 96 counted");
    CHECK(scan(mubuf(47)).buffer == 0 && scan(mubuf(97)).buffer == 0, "MUBUF 47 and 97 not counted");
    CHECK(scan(flat(48)).flat == 1 && scan(flat(95)).flat == 1 && scan(flat(96)).flat == 1,
          "FLAT atomics 48, 95 and 96 counted");
    CHECK(scan(flat(47)).flat == 0 && scan(flat(97)).flat == 0, "FLAT 47 and 97 not counted");

    // a program with several s_endpgm (a branch to an early exit): the stores behind the first
    // one are found, and the scan reports it reached the end of the code
    const std::vector<uint32_t> two = {kEnd, 0xE0701000, 0x80010102, kEnd, 0xF0200F00, 0x00000000, kEnd};
    const ps4replay::GcnStores t = scan(two);
    CHECK(t.complete && t.buffer == 1 && t.image == 1, "stores behind the first s_endpgm: %s", t.Describe().c_str());
    // an unknown encoding stops the scan and is reported as incomplete
    const std::vector<uint32_t> bad = {0xE0701000, 0x80010102, 0xFFFFFFFF, 0xE0701000, 0x80010102};
    const ps4replay::GcnStores u = scan(bad);
    CHECK(!u.complete && u.buffer == 1, "unknown encoding: %s", u.Describe().c_str());
}

// replay_props (the fix tests' view of replayed outputs) on a known 2x2 RGBA16Float output:
// texel decoding, region statistics with a NaN texel left out, lookup by role suffix.
void TestProps() {
    ps4replay::Result r;
    r.ran = true;
    ps4replay::OutputResult o;
    o.what = "t0_color0";
    o.is_texture = o.compared = o.match = true;
    o.tex.mtl_format = kRGBA16Float;
    o.tex.mtl_width = o.tex.mtl_height = 2;
    // (1, 1, 1, 1), (0.5, 0, 0, 1), (0, 2, 0, 1), (NaN, 0, 0, 1): halves 0x3C00 1.0, 0x3800 0.5, 0x4000 2.0, 0x7E00 NaN
    const uint16_t h[16] = {0x3C00, 0x3C00, 0x3C00, 0x3C00, 0x3800, 0, 0, 0x3C00,
                            0, 0x4000, 0, 0x3C00, 0x7E00, 0, 0, 0x3C00};
    o.bytes.assign((const uint8_t*)h, (const uint8_t*)h + sizeof(h));
    r.outputs.push_back(o);
    const ps4replay::OutputResult* f = replay_props::Find(r, "_color0");
    CHECK(f == &r.outputs[0] && !replay_props::Find(r, "_depth"), "Find by role suffix");
    float c[4];
    CHECK(f && replay_props::Texel(*f, 1, 0, c) && c[0] == 0.5f && c[1] == 0 && c[3] == 1, "texel (1, 0)");
    CHECK(f && !replay_props::Texel(*f, 2, 0, c), "texel outside the image decoded");
    if (!f) return;
    const replay_props::Stats st = replay_props::RegionStats(*f);
    const double l0 = 1.0, l1 = 0.2126 * 0.5, l2 = 0.7152 * 2;
    const double mean = (l0 + l1 + l2) / 3;
    CHECK(st.texels == 4 && st.non_finite == 1, "texels %llu non-finite %llu", (unsigned long long)st.texels,
          (unsigned long long)st.non_finite);
    CHECK(fabs(st.mean_luma - mean) < 1e-6 && fabs(st.max_luma - l2) < 1e-6, "luma mean %f max %f", st.mean_luma,
          st.max_luma);
    CHECK(fabs(st.mean[0] - 0.5) < 1e-6 && fabs(st.mean[1] - 1.0) < 1e-6, "channel means %f %f", st.mean[0], st.mean[1]);
    const double sd = sqrt((l0 * l0 + l1 * l1 + l2 * l2) / 3 - mean * mean);
    CHECK(fabs(st.luma_stddev - sd) < 1e-6, "luma stddev %f, expected %f", st.luma_stddev, sd);
    const replay_props::Stats one = replay_props::RegionStats(*f, 1, 1, 1, 1);
    CHECK(one.texels == 1 && one.non_finite == 1, "region of the NaN texel");
}

} // namespace

int main() {
    @autoreleasepool {
        char tmpl[] = "/tmp/gnm_replay_test.XXXXXX";
        const char* root = mkdtemp(tmpl);
        if (!root) return 1;
        TestDispatchReplay(root);
        TestExtractedFixture(root);
        TestDrawReplay(root);
        TestTextureSeeding();
        TestProps();
        TestStoreScan();
        const std::string cmd = std::string("rm -rf '") + root + "'";
        if (system(cmd.c_str()) != 0) g_fail++;
        if (g_fail) {
            fprintf(stderr, "gnm_replay_test: %d failure(s)\n", g_fail);
            return 1;
        }
        printf("gnm_replay_test: PASS\n");
        return 0;
    }
}
