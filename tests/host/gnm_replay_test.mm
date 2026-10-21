// Pass replay (tools/gnm_replay) through the real renderer on a synthetic capture written with
// ps4gnm_capture::Writer: a compute dispatch storing out[i] = i is translated, bound and encoded
// by ps4draw::Dispatch and its output matches the captured bytes; a capture whose output was
// altered is reported as a mismatch at the altered byte; a pass that is not replayable is
// refused with its reason; GPU-owned textures created from captured identities hold the
// captured contents (mip levels, depth and stencil planes).
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

} // namespace

int main() {
    @autoreleasepool {
        char tmpl[] = "/tmp/gnm_replay_test.XXXXXX";
        const char* root = mkdtemp(tmpl);
        if (!root) return 1;
        TestDispatchReplay(root);
        TestTextureSeeding();
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
