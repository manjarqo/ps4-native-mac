// Pass replay (tools/gnm_replay) through the real renderer on a synthetic capture written with
// ps4gnm_capture::Writer: a compute dispatch storing out[i] = i is translated, bound and encoded
// by ps4draw::Dispatch and its output matches the captured bytes; a capture whose output was
// altered is reported as a mismatch at the altered byte; a pass that is not replayable is
// refused with its reason; GPU-owned textures created from captured identities hold the
// captured contents (mip levels, depth and stencil planes); replay_props decodes and measures
// replayed outputs; each draw kind (32-bit indexed with a start index and base vertex, instanced
// with a start instance, indexed indirect up to max_index, indirect) draws exactly its columns,
// and an indirect dispatch takes its dimensions from the argument record; a settled replay (--settle)
// reports a first replay that differs as UNSTABLE-FIRST and never a stable one.
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <CommonCrypto/CommonDigest.h>

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/stat.h>

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
// ghost_texture: the pass also lists a written color target that no one creates (no pre file, not
// touched by the shader), so the replay cannot read it back.
// lds_spill: the value goes through LDS (ds_write_b32 / ds_read_b32 at v2) in a workgroup that
// declares 48 KiB of LDS, more than Metal's threadgroup memory: the translator moves the LDS into a
// storage buffer the renderer allocates in its upload arena. Same output.
// accumulate: out[i] += i (buffer_load_dword, v_add_i32, buffer_store_dword) on an output whose
// first half is captured as an input (1000 each) and whose second half is not in the capture (0 in
// the replay's guest memory): what the pass leaves is 1000 + i, then i. Replaying it twice gives the
// same result only if the replay zeroes what the previous call wrote (the second half is no input).
std::string WriteCapture(const std::string& root, int corrupt_at, bool ghost_texture = false, bool lds_spill = false,
                         bool accumulate = false) {
    uint8_t* mem = (uint8_t*)mmap(nullptr, kMemSize, PROT_READ | PROT_WRITE, MAP_ANON | MAP_PRIVATE, -1, 0);
    const auto prog = accumulate
        ? WithFooter({0x34040082,             // v2 = v0 << 2
                      0xE0301000, 0x80010302, // buffer_load_dword v3, v2, s[4:7] offen
                      0xBF8C0000,             // s_waitcnt 0
                      0x4A060700,             // v_add_i32 v3, vcc, v0, v3
                      0xE0701000, 0x80010302, // buffer_store_dword v3, v2, s[4:7] offen
                      kEnd},
                     0x5CA1AB1E000000A3ull)
        : lds_spill
        ? WithFooter({0x34040082, 0x7E020300,             // v2 = v0 << 2; v1 = v0
                      0xD8340000, 0x00000102, 0xBF8C0000, // ds_write_b32 v2, v1; s_waitcnt 0
                      0xD8D80000, 0x05000002, 0xBF8C0000, // ds_read_b32 v5, v2; s_waitcnt 0
                      0xE0701000, 0x80010502, kEnd},      // buffer_store_dword v5, v2, s[4:7] offen
                     0x5CA1AB1E000000A2ull)
        : WithFooter({0x34040082, 0x7E020300, 0xE0701000, 0x80010102, kEnd}, 0x5CA1AB1E000000A1ull);
    memcpy(mem + kCode, prog.data(), prog.size() * 4);
    memset(mem + kOut, accumulate ? 0 : 0xAB, kPage); // the output's memory before the pass
    if (accumulate)
        for (uint32_t i = 0; i < 32; ++i) {
            const uint32_t v = 1000;
            memcpy(mem + kOut + 4 * i, &v, 4);
        }
    std::vector<uint32_t> regs(kNumRegs, 0);
    regs[0x2E07] = 64; // COMPUTE_NUM_THREAD_X
    regs[0x2E08] = regs[0x2E09] = 1;
    regs[0x2E0C] = uint32_t(kCode >> 8); // COMPUTE_PGM_LO
    regs[0x2E12] = 1;                    // RSRC1: 8 VGPRs
    regs[0x2E13] = 8 << 1;               // RSRC2: 8 user SGPRs
    if (lds_spill) regs[0x2E13] |= 96u << 15; // LDS_SIZE: 96 x 128 dwords = 48 KiB
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
    if (ghost_texture) {
        TextureRec t;
        t.role = "color0";
        t.written = true;
        t.id.kind = 1;
        t.id.address = 0x30000000;
        t.id.mtl_format = t.id.entry_format = (uint32_t)MTLPixelFormatRGBA8Unorm;
        t.id.tex_type = t.id.mtl_type = (uint32_t)MTLTextureType2D;
        t.id.width = t.id.mtl_width = 8;
        t.id.height = t.id.mtl_height = 8;
        t.id.usage = (uint32_t)(MTLTextureUsageShaderRead | MTLTextureUsageRenderTarget);
        t.id.storage_mode = (uint32_t)MTLStorageModeShared;
        t.id.surface.assign(ps4gnm::kPackedSurfaceWords, 0);
        p.textures.push_back(t);
    }
    p.inputs.push_back(w.Snapshot(mem, kCode, kPage));
    p.inputs.push_back(w.Snapshot(mem, kOut, accumulate ? 128 : kPage));
    for (uint32_t i = 0; i < 64; ++i) { // what the pass must leave
        const uint32_t v = (accumulate && i < 32 ? 1000 : 0) + i;
        memcpy(mem + kOut + 4 * i, &v, 4);
    }
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
// A dispatch whose LDS lives in a buffer of the renderer's upload arena (WriteCapture lds_spill:
// 48 KiB is over the Metal profile's 32 KiB, so SharedMemoryToStoragePass moves it to a storage
// buffer). It checks the spill's binding and translation, not the arena's residency: each thread
// reads back only the dword it has just written, which the GPU can return from its cache, and an
// arena chunk left out of the residency sets keeps this test green. TestArenaGpuWrite covers that.
void TestLdsSpill(const std::string& root) {
    ps4replay::Options o;
    o.frame_dir = WriteCapture(root + "/lds", -1, false, true);
    o.keep_outputs = true;
    ps4replay::Result r = ps4replay::ReplayPass(o);
    CHECK(r.ran, "LDS spill: not replayed: %s", r.error.c_str());
    CHECK(r.outputs.size() == 1 && r.AllMatch(), "LDS spill: replay differs from the capture (%zu outputs, %llu bytes differ)",
          r.outputs.size(), r.outputs.empty() ? 0ull : (unsigned long long)r.outputs[0].diff_bytes);
}

// The GPU writes a fresh chunk of the renderer's upload arena (DebugArenaGpuFill): on Metal 4 the
// chunk is resident from its creation (UploadArena::on_new), or the fill is lost and the CPU reads
// the zeros it wrote before.
void TestArenaGpuWrite() {
    std::vector<uint8_t> got;
    CHECK(ps4draw::DebugArenaGpuFill(0x5A, 1 << 20, &got), "arena fill: no renderer");
    size_t right = 0;
    for (uint8_t b : got) right += b == 0x5A;
    CHECK(right == got.size() && !got.empty(), "arena fill: %zu of %zu bytes written by the GPU", right, got.size());
}

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
// pending: 0 no fast clear pending, 1 pending (a capture without meta_cleared_slices), 2 pending
// with the slice that took it recorded (slice 0)
std::string WriteDrawCapture(const std::string& root, int pending, std::vector<uint8_t>* want) {
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
    if (pending == 2) p.meta_cleared_slices.push_back(0);
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
    for (int pending = 0; pending < 3; ++pending) {
        ps4replay::Options o;
        std::vector<uint8_t> want;
        o.frame_dir = WriteDrawCapture(root + (pending == 2 ? "/draw_clear_slice" : pending ? "/draw_clear" : "/draw"),
                                       pending, &want);
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

// ---- The draw kinds and an indirect dispatch, replayed through ps4draw::Draw / Dispatch ----
// The 8x8 RGBA16Float target of DrawRegs, cut into 8 one-column rectangles: vertices 6r..6r+5 of
// the vertex buffer cover column r. The VS calls a fetch shader (s_swappc_b64) that loads the
// position per vertex (v0 + s4, the base vertex) and an x offset per instance (v3 + s5, the start
// instance) from the V# table at s[2:3], and adds the offset (whole columns) to x; the PS exports
// (1, 0.5, 0, 1). Each case draws its columns with every argument mattering: the columns of a
// renderer that ignored one of them are named in the case. The translator turns the fetch shader
// into vertex attributes (the offset steps per instance), so base vertex and base instance reach
// Metal as the draw's baseVertex / baseInstance, and for the indirect kinds come from the GPU.
constexpr uint64_t kVs2 = 0x190000, kPs2 = 0x1A0000, kFetch = 0x1B0000, kVsharps = 0x1C0000;
constexpr uint64_t kOffs = 0x1D0000, kIb = 0x1E0000, kArgs = 0x1F0000;
constexpr float kColOffset[8] = {0, 6, 1, 3, 5, 2, 4, 0}; // instance i moves its rectangle this many columns

struct DrawCase {
    const char* name;
    const char* pm4; // the PassRec name
    bool indexed;
    uint32_t index_type; // 0: 16 bit, 1: 32 bit
    bool indirect;
    uint32_t count, index_offset, max_index, instances;
    uint32_t s4, s5; // user data: base vertex, start instance (direct draws)
    std::vector<uint32_t> indices;
    std::vector<uint32_t> args; // the indirect record (MTLDraw[Indexed]PrimitivesIndirectArguments)
    uint8_t columns;            // the columns drawn, bit c = column c
};

std::vector<uint32_t> KindRegs(const DrawCase& c) {
    std::vector<uint32_t> regs = DrawRegs();
    regs[0x2C48] = uint32_t(kVs2 >> 8);
    regs[0x2C4A] = 2 | (2 << 6) | (3u << 24); // 12 VGPRs, 24 SGPRs, VGPR_COMP_CNT 3: v3 = instance id
    regs[0x2C4B] = 6 << 1;                    // 6 user SGPRs
    uint32_t* vud = &regs[0x2C4C];
    vud[0] = uint32_t(kFetch);
    vud[1] = uint32_t(kFetch >> 32);
    vud[2] = uint32_t(kVsharps);
    vud[3] = uint32_t(kVsharps >> 32);
    vud[4] = c.indirect ? 0 : c.s4; // an indirect draw's come from its record (the CP's writes)
    vud[5] = c.indirect ? 0 : c.s5;
    regs[0x2C08] = uint32_t(kPs2 >> 8);
    regs[0x2C0B] = 0; // no user SGPRs
    return regs;
}

std::string WriteKindCapture(const std::string& root, const DrawCase& c, std::vector<uint8_t>* want) {
    uint8_t* mem = (uint8_t*)mmap(nullptr, kMemSize, PROT_READ | PROT_WRITE, MAP_ANON | MAP_PRIVATE, -1, 0);
    // fetch shader: s_load_dwordx4 s[8:11], s[2:3], 0; s_load_dwordx4 s[12:15], s[2:3], 4;
    // v_add_i32 v0, s4, v0; v_add_i32 v3, s5, v3; s_waitcnt lgkmcnt(0);
    // buffer_load_format_xyzw v[4:7], v0, s[8:11] idxen; buffer_load_format_x v8, v3, s[12:15] idxen;
    // s_waitcnt vmcnt(0); s_setpc_b64 s[16:17]
    const uint32_t fetch[] = {0xC0840300, 0xC0860304, 0x4A000004, 0x4A060605, 0xBF8C007F, 0xE00C2000,
                              0x80020400, 0xE0002000, 0x80030803, 0xBF8C0F70, 0xBE802010};
    // VS: s_swappc_b64 s[16:17], s[0:1]; v_add_f32 v4, v8, v4; exp param0 v[4:7]; exp pos0 v[4:7] done
    const auto vs = WithFooter({0xBE902100, 0x06080908, 0xF800020F, 0x07060504, 0xF80008CF, 0x07060504, kEnd},
                               0x5CA1AB1E000000B3ull);
    // PS: v0 = 1.0; v1 = 0.5; v2 = 0; v3 = 1.0; exp mrt0 v[0:3] done vm
    const auto ps = WithFooter({0x7E0002F2, 0x7E0202F0, 0x7E040280, 0x7E0602F2, 0xF800180F, 0x03020100, kEnd},
                               0x5CA1AB1E000000B4ull);
    memcpy(mem + kFetch, fetch, sizeof(fetch));
    memcpy(mem + kVs2, vs.data(), vs.size() * 4);
    memcpy(mem + kPs2, ps.data(), ps.size() * 4);
    for (uint32_t r = 0; r < 8; ++r) { // column r: x in [r / 4 - 1, (r + 1) / 4 - 1], two triangles
        const float x0 = r * 0.25f - 1, x1 = x0 + 0.25f;
        const float v[6][4] = {{x0, -1, 0.5f, 1}, {x1, -1, 0.5f, 1}, {x0, 1, 0.5f, 1},
                               {x1, -1, 0.5f, 1}, {x1, 1, 0.5f, 1},  {x0, 1, 0.5f, 1}};
        memcpy(mem + kVb + r * sizeof(v), v, sizeof(v));
    }
    for (uint32_t i = 0; i < 8; ++i) {
        const float x = kColOffset[i] * 0.25f;
        memcpy(mem + kOffs + 4 * i, &x, 4);
    }
    uint32_t vsharp[8] = {uint32_t(kVb), 16u << 16, 48, 4 | (5 << 3) | (6 << 6) | (7 << 9) | (7 << 12) | (14 << 15),
                          uint32_t(kOffs), 4u << 16, 8, 4 | (5 << 3) | (6 << 6) | (7 << 9) | (7 << 12) | (4 << 15)};
    memcpy(mem + kVsharps, vsharp, sizeof(vsharp));
    for (size_t i = 0; i < c.indices.size(); ++i) {
        if (c.index_type) memcpy(mem + kIb + 4 * i, &c.indices[i], 4);
        else {
            const uint16_t h = (uint16_t)c.indices[i];
            memcpy(mem + kIb + 2 * i, &h, 2);
        }
    }
    if (!c.args.empty()) memcpy(mem + kArgs, c.args.data(), c.args.size() * 4);
    const std::vector<uint32_t> regs = KindRegs(c);
    const GpuTextureId tid = TargetId(regs);
    std::vector<uint8_t> tpre(RawSize(tid));
    for (size_t i = 0; i < tpre.size(); ++i) tpre[i] = (uint8_t)(i * 13 + 5);
    *want = tpre;
    const uint16_t color[4] = {0x3C00, 0x3800, 0x0000, 0x3C00};
    for (uint32_t y = 0; y < 8; ++y)
        for (uint32_t x = 0; x < 8; ++x)
            if (c.columns >> x & 1) memcpy(want->data() + (y * 8 + x) * 8, color, 8);
    const std::string dir = root + "/frame_1";
    Writer w(dir, 1, kMemSize, false, gcn_shader_cache_id());
    std::string err;
    CHECK(w.Begin(&err), "%s", err.c_str());
    PassRec p;
    p.index = 0;
    p.replayable = true;
    p.type = "draw";
    p.queue = "gfx";
    p.name = c.pm4;
    p.indexed = c.indexed;
    p.index_base = c.indexed ? kIb : 0;
    p.index_type = c.index_type;
    p.index_offset = c.index_offset;
    p.count = c.count;
    p.max_index = c.max_index;
    p.num_instances = c.instances;
    if (c.indirect) {
        p.indirect_addr = kArgs;
        p.base_vertex_ud = 4;
        p.start_instance_ud = 5;
    }
    p.cb_extent[0] = 8 | 8 << 16;
    p.regs_file = w.SaveRegs(regs.data(), &p.regs_hash);
    TextureRec t;
    t.role = "t0_color0";
    t.written = true;
    t.id = tid;
    t.pre_file = w.SaveTexture(0, t.role, "pre", tpre, &t.pre_hash);
    t.post_file = w.SaveTexture(0, t.role, "post", *want, &t.post_hash);
    p.textures.push_back(t);
    for (uint64_t a : {kVs2, kPs2, kFetch, kVsharps, kVb, kOffs, kIb, kArgs}) p.inputs.push_back(w.Snapshot(mem, a, kPage));
    w.AddPass(std::move(p));
    CHECK(w.Finish(&err), "%s", err.c_str());
    munmap(mem, kMemSize);
    return dir;
}

std::vector<uint32_t> Rect(uint32_t r) { return {6 * r, 6 * r + 1, 6 * r + 2, 6 * r + 3, 6 * r + 4, 6 * r + 5}; }
std::vector<uint32_t> Cat(std::initializer_list<std::vector<uint32_t>> parts) {
    std::vector<uint32_t> v;
    for (const auto& x : parts) v.insert(v.end(), x.begin(), x.end());
    return v;
}

void TestDrawKinds(const std::string& root) {
    const DrawCase cases[] = {
        // 32-bit indices from index 6 (the first 6 are a decoy, rectangle 7), base vertex 6: the
        // indices name rectangles 1 and 4, drawn as 2 and 5. Without the base vertex: 1, 4; read
        // as 16-bit indices or from index 0: other vertices.
        {"indexed, 32-bit indices, start index and base vertex", "DRAW_INDEX_2", true, 1, false, 12, 6, 18, 1, 6, 0,
         Cat({Rect(7), Rect(1), Rect(4)}), {}, (1 << 2) | (1 << 5)},
        // rectangle 0, 3 instances from instance 2: offsets 1, 3, 5. From instance 0: 0, 6, 1.
        {"instanced with a start instance", "DRAW_INDEX_AUTO", false, 0, false, 6, 0, 0, 3, 0, 2, {}, {},
         (1 << 1) | (1 << 3) | (1 << 5)},
        // 16-bit indices, the record's start index 12 is the last 6 of max_index 18 (the first 12
        // are a decoy, rectangle 7), base vertex 6 (rectangle 0 drawn as 1), 2 instances from
        // instance 4 (offsets 5, 2): columns 6, 3. From instance 0: 1, 7; no base vertex: 5, 2.
        {"indexed indirect", "DRAW_INDEX_INDIRECT", true, 0, true, 0, 0, 18, 1, 0, 0,
         Cat({Rect(7), Rect(7), Rect(0)}), {6, 2, 12, 6, 4}, (1 << 3) | (1 << 6)},
        // 6 vertices from vertex 12 (rectangle 2), 1 instance from instance 3 (offset 3): column 5.
        // From vertex 0: 3; from instance 0: 2.
        {"indirect", "DRAW_INDIRECT", false, 0, true, 0, 0, 0, 1, 0, 0, {}, {6, 1, 12, 3}, 1 << 5},
    };
    int k = 0;
    for (const DrawCase& c : cases) {
        ps4replay::Options o;
        std::vector<uint8_t> want;
        o.frame_dir = WriteKindCapture(root + "/kind" + std::to_string(k++), c, &want);
        o.keep_outputs = true;
        const ps4replay::Result r = ps4replay::ReplayPass(o);
        CHECK(r.ran, "%s: not replayed: %s", c.name, r.error.c_str());
        const ps4replay::OutputResult* out = replay_props::Find(r, "_color0");
        CHECK(out && out->compared && out->match, "%s: %llu bytes differ", c.name,
              out ? (unsigned long long)out->diff_bytes : 0ull);
        if (out && out->bytes.size() == want.size() && !out->match) {
            char drawn[9] = "........";
            for (uint32_t x = 0; x < 8; ++x) {
                uint16_t h[4];
                memcpy(h, out->bytes.data() + (4 * 8 + x) * 8, 8);
                if (h[0] == 0x3C00 && h[1] == 0x3800 && h[2] == 0 && h[3] == 0x3C00) drawn[x] = 'x';
            }
            fprintf(stderr, "  %s: columns drawn in row 4: %s, want %02x\n", c.name, drawn, c.columns);
        }
    }
}

// An indirect dispatch: 2 workgroups from the argument record while the PM4 dimensions (the pass's
// dim) say 1, each thread storing its global index (s8 = workgroup id x: s9 = s8 << 6; v1 = s9 + v0;
// buffer_store_dword v1 at 4 * v1). Read from the dimensions instead, the second half keeps 0xAB.
std::string WriteIndirectDispatchCapture(const std::string& root) {
    uint8_t* mem = (uint8_t*)mmap(nullptr, kMemSize, PROT_READ | PROT_WRITE, MAP_ANON | MAP_PRIVATE, -1, 0);
    const auto prog = WithFooter({0x8F098608, 0x4A020009, 0x34040282, 0xE0701000, 0x80010102, kEnd}, 0x5CA1AB1E000000A3ull);
    memcpy(mem + kCode, prog.data(), prog.size() * 4);
    memset(mem + kOut, 0xAB, kPage);
    const uint32_t dims[3] = {2, 1, 1};
    memcpy(mem + kArgs, dims, sizeof(dims));
    std::vector<uint32_t> regs(kNumRegs, 0);
    regs[0x2E07] = 64;
    regs[0x2E08] = regs[0x2E09] = 1;
    regs[0x2E0C] = uint32_t(kCode >> 8);
    regs[0x2E12] = 1 | (1 << 6);        // RSRC1: 8 VGPRs, 16 SGPRs
    regs[0x2E13] = (8 << 1) | (1 << 7); // RSRC2: 8 user SGPRs, TGID_X_EN (s8)
    uint32_t* ud = &regs[0x2E40];
    ud[4] = uint32_t(kOut); // V#: 512 bytes, 32-bit uint
    ud[5] = 0;
    ud[6] = 512;
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
    p.indirect_addr = kArgs;
    BufferRec b;
    b.stage = "cs";
    b.addr = kOut;
    b.size = 512;
    b.written = true;
    memcpy(b.vsharp, &ud[4], 16);
    p.buffers.push_back(b);
    p.inputs.push_back(w.Snapshot(mem, kCode, kPage));
    p.inputs.push_back(w.Snapshot(mem, kOut, kPage));
    p.inputs.push_back(w.Snapshot(mem, kArgs, kPage));
    for (uint32_t i = 0; i < 128; ++i) memcpy(mem + kOut + 4 * i, &i, 4);
    p.outputs.push_back(w.Snapshot(mem, kOut, 512));
    w.AddPass(std::move(p));
    CHECK(w.Finish(&err), "%s", err.c_str());
    munmap(mem, kMemSize);
    return dir;
}

void TestIndirectDispatch(const std::string& root) {
    ps4replay::Options o;
    o.frame_dir = WriteIndirectDispatchCapture(root + "/indirect_dispatch");
    o.keep_outputs = true;
    const ps4replay::Result r = ps4replay::ReplayPass(o);
    CHECK(r.ran, "indirect dispatch: not replayed: %s", r.error.c_str());
    CHECK(r.outputs.size() == 1 && r.AllMatch(), "indirect dispatch: %llu bytes differ, first at %llu",
          r.outputs.empty() ? 0ull : (unsigned long long)r.outputs[0].diff_bytes,
          r.outputs.empty() ? 0ull : (unsigned long long)r.outputs[0].first_diff);
}

// PS4_GNM_MTL4_ONLY_CLEARS=1 (debug, Metal 4; run_host_tests.sh runs the "only-clears" mode with
// it): the draw of WriteDrawCapture with its fast clear pending is skipped once its render pass
// began, so the pass's clear happens and the draw does not: every texel holds the clear colour
// (the draw would have put the sampled texel in columns 0-3), the draw is counted as skipped by
// the mode and not as a skipped pass.
void TestOnlyClearsDraw(const std::string& root) {
    const char* oc = getenv("PS4_GNM_MTL4_ONLY_CLEARS");
    CHECK(oc && !strcmp(oc, "1"), "only-clears: run with PS4_GNM_MTL4_ONLY_CLEARS=1");
    std::vector<uint8_t> want;
    ps4replay::Options o;
    o.frame_dir = WriteDrawCapture(root + "/only_clears", 1, &want);
    o.keep_outputs = true;
    const uint64_t before = ps4draw::OnlyClearsSkippedCount();
    const ps4replay::Result r = ps4replay::ReplayPass(o);
    CHECK(r.ran, "only-clears: not replayed: %s", r.error.c_str());
    const uint64_t skipped = ps4draw::OnlyClearsSkippedCount() - before;
    CHECK(skipped == 1, "only-clears: %llu draws skipped by the mode, want 1", (unsigned long long)skipped);
    const ps4replay::OutputResult* c = replay_props::Find(r, "_color0");
    CHECK(c && c->bytes.size() == want.size(), "only-clears: no target read back");
    if (!c || c->bytes.size() != want.size()) return;
    size_t cleared = 0;
    for (size_t i = 0; i < 64; ++i) cleared += !memcmp(c->bytes.data() + i * 8, kClear, 8);
    CHECK(cleared == 64, "only-clears: %zu of 64 texels hold the clear colour", cleared);
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

// ReplayPasses: every pass of the frame in one call, with one SHA-256 per output; the hash is
// that of the replayed bytes (out[i] = i), a pass the renderer skipped is reported with its reason, and
// a range past the frame's end reports the pass.
void TestRange(const std::string& root) {
    const std::string frame = WriteCapture(root + "/range", -1);
    ps4replay::Options o;
    o.frame_dir = frame;
    o.sha256 = true;
    const std::vector<ps4replay::PassResult> all = ps4replay::ReplayPasses(o, 0, UINT32_MAX);
    // WriteCapture's frame holds the dispatch (pass 0) and a pass the renderer encoded nothing for
    CHECK(all.size() == 2, "range: %zu passes, want 2", all.size());
    if (all.size() != 2) return;
    CHECK(all[1].pass == 1 && !all[1].r.ran && all[1].r.error.find("meta clear") != std::string::npos,
          "range: pass 1 not reported as skipped: %s", all[1].r.error.c_str());
    CHECK(all[0].pass == 0 && all[0].type == "dispatch", "range: pass %u type %s", all[0].pass, all[0].type.c_str());
    CHECK(all[0].r.ran && all[0].r.outputs.size() == 1, "range: not replayed: %s", all[0].r.error.c_str());
    if (!all[0].r.ran || all[0].r.outputs.size() != 1) return;
    uint32_t want[64];
    for (uint32_t i = 0; i < 64; ++i) want[i] = i;
    unsigned char md[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(want, sizeof(want), md);
    char hex[2 * CC_SHA256_DIGEST_LENGTH + 1];
    for (int i = 0; i < CC_SHA256_DIGEST_LENGTH; ++i) snprintf(hex + 2 * i, 3, "%02x", md[i]);
    CHECK(all[0].r.outputs[0].sha256 == hex, "range: sha %s, want %s", all[0].r.outputs[0].sha256.c_str(), hex);
    const std::vector<ps4replay::PassResult> past = ps4replay::ReplayPasses(o, 1, 2);
    CHECK(past.size() == 2 && !past[1].r.ran && past[1].type.empty() &&
              past[1].r.error.find("no pass 2") != std::string::npos,
          "range: pass 2 of a 2-pass frame not reported");

    // a huge last pass number ends at the first pass the frame does not have
    const std::vector<ps4replay::PassResult> huge = ps4replay::ReplayPasses(o, 0, 4000000000u);
    CHECK(huge.size() == 3 && huge[2].pass == 2 && !huge[2].r.ran, "range: %zu results for 0-4000000000, want 3",
          huge.size());

    // the hook brackets the renderer calls of the replayed pass only: one pair, begin first
    struct Hook {
        int begins = 0, ends = 0;
        bool order_ok = true;
    } hook;
    ps4replay::Options oh = o;
    oh.around_ctx = &hook;
    oh.around_render = [](void* c, bool begin) {
        Hook* h = static_cast<Hook*>(c);
        if (begin) {
            h->order_ok &= h->begins == h->ends;
            h->begins++;
        } else {
            h->order_ok &= h->begins == h->ends + 1;
            h->ends++;
        }
    };
    ps4replay::ReplayPasses(oh, 0, UINT32_MAX); // pass 0 renders, pass 1 is skipped before the renderer
    CHECK(hook.begins == 1 && hook.ends == 1 && hook.order_ok, "range: hook begin %d end %d order %d", hook.begins,
          hook.ends, (int)hook.order_ok);

    // the output lines, in the grammar of the comparison tool: P <pass> <type> RAN|NOT ..., then
    // exactly five words per O line
    const std::string lines = ps4replay::FormatPassResult(all[0]) + ps4replay::FormatPassResult(all[1]);
    const std::string want_p = "P 0 dispatch RAN 1 1\nO 0 buffer_0x";
    CHECK(lines.compare(0, want_p.size(), want_p) == 0, "range: lines\n%s", lines.c_str());
    CHECK(lines.find(std::string(" 256 ") + hex + "\nP 1 dispatch NOT ") != std::string::npos,
          "range: O line lacks size and hash\n%s", lines.c_str());

    // outputs of a range go to one directory per pass
    ps4replay::Options oo = o;
    oo.out_dir = root + "/range_out";
    ps4replay::ReplayPasses(oo, 0, 0);
    struct stat st;
    CHECK(stat((oo.out_dir + "/pass_0").c_str(), &st) == 0 && S_ISDIR(st.st_mode), "range: no pass_0 directory");

    // a texture the renderer has no identity for: the hash says so, in every run alike
    ps4replay::Options og;
    og.frame_dir = WriteCapture(root + "/range_ghost", -1, true);
    og.sha256 = true;
    const std::vector<ps4replay::PassResult> ghost = ps4replay::ReplayPasses(og, 0, 0);
    CHECK(ghost.size() == 1 && ghost[0].r.ran, "range: ghost capture not replayed: %s",
          ghost.empty() ? "" : ghost[0].r.error.c_str());
    if (ghost.size() == 1 && ghost[0].r.ran) {
        const std::string gl = ps4replay::FormatPassResult(ghost[0]);
        CHECK(gl.find("_(the_renderer_made_no_texture_with_the_captured_identity) 0 MISSING\n") != std::string::npos,
              "range: missing texture line\n%s", gl.c_str());
    }
}

// SHA-256 of out[i] = i (the dispatch of WriteCapture), lowercase hex; flip_byte >= 0: with that
// byte's bit 0x10 flipped.
std::string IotaSha(int flip_byte) {
    uint8_t want[256];
    for (uint32_t i = 0; i < 64; ++i) memcpy(want + 4 * i, &i, 4);
    if (flip_byte >= 0) want[flip_byte] ^= 0x10;
    unsigned char md[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(want, sizeof(want), md);
    char hex[2 * CC_SHA256_DIGEST_LENGTH + 1];
    for (int i = 0; i < CC_SHA256_DIGEST_LENGTH; ++i) snprintf(hex + 2 * i, 3, "%02x", md[i]);
    return hex;
}

// --settle (Options::settle). A stable pass is replayed twice, both hashes equal, never reported
// unstable, in a single replay and in a range. A first replay made to differ (the test-only hook
// flips one byte of its output) is reported UNSTABLE-FIRST with both hashes, while the verdict is
// the second, correct replay's. Without settle the hook is never called.
void TestSettle(const std::string& root) {
    const std::string frame = WriteCapture(root + "/settle", -1);
    const std::string good = IotaSha(-1), flipped = IotaSha(9);
    ps4replay::Options o;
    o.frame_dir = frame;
    o.settle = true;
    for (int k = 0; k < 3; ++k) {
        const ps4replay::Result r = ps4replay::ReplayPass(o);
        CHECK(r.ran && r.settled && !r.unstable_first && r.first_only.empty() && r.AllMatch(),
              "settle (stable) %d: ran %d settled %d unstable %d match %d: %s", k, (int)r.ran, (int)r.settled,
              (int)r.unstable_first, (int)r.AllMatch(), r.error.c_str());
        if (r.outputs.size() == 1)
            CHECK(r.outputs[0].sha256 == good && r.outputs[0].first_sha256 == good && !r.outputs[0].unstable_first,
                  "settle (stable): hashes %s / %s", r.outputs[0].first_sha256.c_str(), r.outputs[0].sha256.c_str());
        else
            CHECK(false, "settle (stable): %zu outputs", r.outputs.size());
    }
    const std::vector<ps4replay::PassResult> range = ps4replay::ReplayPasses(o, 0, UINT32_MAX);
    std::string lines;
    for (const ps4replay::PassResult& p : range) lines += ps4replay::FormatPassResult(p);
    CHECK(range.size() == 2 && lines.find("\nU ") == std::string::npos &&
              lines.find(std::string(" 256 ") + good + "\n") != std::string::npos,
          "settle (stable range): lines\n%s", lines.c_str());

    struct Flip {
        int calls = 0;
        std::string what;
    } flip;
    ps4replay::Options of = o;
    of.test_settle_ctx = &flip;
    of.test_settle_first = [](void* c, std::string* what, std::vector<uint8_t>* bytes) {
        Flip* f = static_cast<Flip*>(c);
        f->calls++;
        f->what = *what;
        if (bytes->size() > 9) (*bytes)[9] ^= 0x10;
    };
    const ps4replay::Result u = ps4replay::ReplayPass(of);
    CHECK(flip.calls == 1 && flip.what == "buffer 0x200000", "settle hook: %d calls, output '%s'", flip.calls,
          flip.what.c_str());
    CHECK(u.ran && u.settled && u.unstable_first && u.AllMatch(),
          "settle (perturbed first): ran %d settled %d unstable %d match %d", (int)u.ran, (int)u.settled,
          (int)u.unstable_first, (int)u.AllMatch());
    if (u.outputs.size() == 1) {
        CHECK(u.outputs[0].unstable_first && u.outputs[0].first_sha256 == flipped && u.outputs[0].sha256 == good,
              "settle (perturbed first): hashes %s / %s", u.outputs[0].first_sha256.c_str(),
              u.outputs[0].sha256.c_str());
        ps4replay::PassResult pr;
        pr.pass = 0;
        pr.type = "dispatch";
        pr.r = u;
        const std::string ul = ps4replay::FormatPassResult(pr);
        const std::string want = "U 0 UNSTABLE-FIRST buffer_0x200000 " + flipped + " " + good + "\n";
        CHECK(ul.find("\nO 0 buffer_0x200000 256 " + good + "\n" + want) != std::string::npos,
              "settle (perturbed first): lines\n%s", ul.c_str());
    } else {
        CHECK(false, "settle (perturbed first): %zu outputs", u.outputs.size());
    }

    // the default replay is one replay: the hook is not called, nothing is settled
    ps4replay::Options od = of;
    od.settle = false;
    flip.calls = 0;
    const ps4replay::Result d = ps4replay::ReplayPass(od);
    CHECK(flip.calls == 0 && d.ran && !d.settled && !d.unstable_first && d.AllMatch() && d.outputs.size() == 1 &&
              d.outputs[0].first_sha256.empty(),
          "default replay: hook calls %d settled %d unstable %d", flip.calls, (int)d.settled, (int)d.unstable_first);
}

// --settle restores between its two replays: a pass that accumulates into memory outside its
// captured inputs settles stable and byte-exact (and so do two plain replays in a row). A pass that
// writes a texture it creates is not settled: replayed once, the reason given, the hook not called.
// An output only the first replay wrote is unstable (first_only, S/U lines), alone too.
void TestSettleRestore(const std::string& root) {
    ps4replay::Options o;
    o.frame_dir = WriteCapture(root + "/settle_acc", -1, false, false, true);
    for (int k = 0; k < 2; ++k) {
        const ps4replay::Result r = ps4replay::ReplayPass(o);
        CHECK(r.ran && r.AllMatch(), "accumulate (plain %d): ran %d match %d %s", k, (int)r.ran, (int)r.AllMatch(),
              r.error.c_str());
    }
    o.settle = true;
    const ps4replay::Result r = ps4replay::ReplayPass(o);
    CHECK(r.ran && r.settled && !r.unstable_first && r.AllMatch(),
          "accumulate (settle): ran %d settled %d unstable %d match %d", (int)r.ran, (int)r.settled,
          (int)r.unstable_first, (int)r.AllMatch());

    // a written texture without contents before the pass: not settled
    int calls = 0;
    ps4replay::Options og;
    og.frame_dir = WriteCapture(root + "/settle_ghost", -1, true);
    og.settle = true;
    og.sha256 = true;
    og.test_settle_ctx = &calls;
    og.test_settle_first = [](void* c, std::string*, std::vector<uint8_t>*) { ++*static_cast<int*>(c); };
    const ps4replay::Result g = ps4replay::ReplayPass(og);
    CHECK(g.ran && !g.settled && !g.unstable_first && calls == 0 &&
              g.not_settled.find("color0, a texture the pass creates") != std::string::npos,
          "not settled: ran %d settled %d hook %d reason '%s'", (int)g.ran, (int)g.settled, calls,
          g.not_settled.c_str());
    ps4replay::PassResult gp;
    gp.pass = 0;
    gp.type = "dispatch";
    gp.r = g;
    const std::string gl = ps4replay::FormatPassResult(gp);
    CHECK(gl.find("\nS 0 NOT-SETTLED writes color0, a texture") != std::string::npos, "not settled: lines\n%s",
          gl.c_str());

    // the first replay's output under another name: the real one is ABSENT in the first replay, the
    // renamed one only in the first
    ps4replay::Options orn;
    orn.frame_dir = WriteCapture(root + "/settle_rename", -1);
    orn.settle = true;
    orn.test_settle_first = [](void*, std::string* what, std::vector<uint8_t>*) { *what += " renamed"; };
    const ps4replay::Result rn = ps4replay::ReplayPass(orn);
    const std::string good = IotaSha(-1);
    CHECK(rn.ran && rn.unstable_first && rn.AllMatch() && rn.outputs.size() == 1 && rn.outputs[0].first_sha256 == "ABSENT" &&
              rn.first_only.size() == 1 && rn.first_only[0].first == "buffer 0x200000 renamed" &&
              rn.first_only[0].second == good,
          "renamed first output: unstable %d first_only %zu", (int)rn.unstable_first, rn.first_only.size());
    ps4replay::PassResult rp;
    rp.pass = 0;
    rp.type = "dispatch";
    rp.r = rn;
    const std::string rl = ps4replay::FormatPassResult(rp);
    CHECK(rl.find("U 0 UNSTABLE-FIRST buffer_0x200000 ABSENT " + good + "\n") != std::string::npos &&
              rl.find("U 0 UNSTABLE-FIRST buffer_0x200000_renamed " + good + " ABSENT\n") != std::string::npos,
          "renamed first output: lines\n%s", rl.c_str());

    // an extra output of the first replay alone (every other output equal) still makes the pass unstable
    ps4replay::Result first, second;
    ps4replay::OutputResult a;
    a.what = "buffer 0x1000";
    a.sha256 = "aa";
    first.outputs.push_back(a);
    second.outputs.push_back(a);
    a.what = "buffer 0x2000";
    a.sha256 = "bb";
    first.outputs.push_back(a);
    ps4replay::MarkUnstableFirst(first, &second);
    CHECK(second.settled && second.unstable_first && !second.outputs[0].unstable_first &&
              second.outputs[0].first_sha256 == "aa" && second.first_only.size() == 1 &&
              second.first_only[0].first == "buffer 0x2000" && second.first_only[0].second == "bb",
          "first-only output: unstable %d first_only %zu", (int)second.unstable_first, second.first_only.size());
    ps4replay::Result same;
    same.outputs = second.outputs;
    first.outputs.pop_back();
    ps4replay::MarkUnstableFirst(first, &same);
    CHECK(same.settled && !same.unstable_first && same.first_only.empty(), "equal outputs reported unstable");
}

void TestPassSpec() {
    struct Case {
        const char* s;
        bool ok, range;
        uint32_t first, last;
    } cases[] = {{"7", true, false, 7, 7},          {"2-4", true, true, 2, 4},   {"3-3", true, true, 3, 3},
                 {"all", true, true, 0, UINT32_MAX}, {"5-", false, 0, 0, 0},     {"5-3", false, 0, 0, 0},
                 {"-3", false, 0, 0, 0},            {"foo-bar", false, 0, 0, 0}, {"", false, 0, 0, 0},
                 {"1-2-3", false, 0, 0, 0},         {"x", false, 0, 0, 0},       {"4294967295", false, 0, 0, 0}};
    for (const Case& c : cases) {
        uint32_t a = 99, b = 99;
        bool range = false;
        const bool ok = ps4replay::ParsePassSpec(c.s, &a, &b, &range);
        CHECK(ok == c.ok && (!ok || (range == c.range && a == c.first && b == c.last)),
              "pass spec '%s': ok %d range %d %u-%u", c.s, (int)ok, (int)range, a, b);
    }
}

} // namespace

int main(int argc, char** argv) {
    @autoreleasepool {
        // write-capture <dir>: only writes the synthetic dispatch capture (<dir>/frame_1), for
        // run_host_tests.sh to replay through tools/gnm_replay under other settings.
        if (argc == 3 && !strcmp(argv[1], "write-capture")) {
            WriteCapture(argv[2], -1);
            return g_fail ? 1 : 0;
        }
        // only-clears: the draw under PS4_GNM_MTL4_ONLY_CLEARS=1 alone (run_host_tests.sh sets it)
        const bool only_clears = argc == 2 && !strcmp(argv[1], "only-clears");
        if (argc > 1 && !only_clears) {
            fprintf(stderr, "usage: gnm_replay_test [only-clears | write-capture <dir>]\n");
            return 2;
        }
        char tmpl[] = "/tmp/gnm_replay_test.XXXXXX";
        const char* root = mkdtemp(tmpl);
        if (!root) return 1;
        if (only_clears) {
            TestOnlyClearsDraw(root);
            const std::string rm = std::string("rm -rf '") + root + "'";
            if (system(rm.c_str()) != 0) g_fail++;
            printf("gnm_replay_test only-clears: %s\n", g_fail ? "FAIL" : "PASS");
            return g_fail ? 1 : 0;
        }
        TestDispatchReplay(root);
        TestLdsSpill(root);
        TestArenaGpuWrite(); // after the first replay: the renderer is running
        TestExtractedFixture(root);
        TestIndirectDispatch(root);
        TestDrawReplay(root);
        TestDrawKinds(root);
        TestRange(root);
        TestSettle(root);
        TestSettleRestore(root);
        TestPassSpec();
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
