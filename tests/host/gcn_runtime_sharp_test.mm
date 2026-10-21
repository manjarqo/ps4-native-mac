// T#s and S#s a shader does not read from its resource tables as they are (hand-assembled
// compute shaders, translated with zeroed guest memory):
//  - a T# and an S# loaded with s_buffer_load through a V# the shader loads at run time: the
//    shader translates, its image read reads the null image and is counted
//    (gcn_shader_info.null_image_reads, also after a shader cache round trip), and the S# cannot
//    be fetched (gcn_shader_fetch_sampler_sharp returns false: the renderer logs it);
//  - a T# dword computed in the shader (s_or_b32 of two of its dwords): the translation fails,
//    naming the instruction and the dword;
//  - an S# dword computed in the shader: the same.
//
// usage: gcn_runtime_sharp_test
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>

#include "gcn_recompiler.h"

namespace {

int g_fail = 0;
#define CHECK(c, ...)                                                                        \
    do {                                                                                     \
        if (!(c)) {                                                                          \
            std::fprintf(stderr, "gcn_runtime_sharp_test: FAIL %s:%d: ", __FILE__, __LINE__); \
            std::fprintf(stderr, __VA_ARGS__);                                               \
            std::fprintf(stderr, "\n");                                                      \
            g_fail++;                                                                        \
        }                                                                                    \
    } while (0)

bool ZeroRead(void*, uint64_t, void* dst, uint64_t size) {
    std::memset(dst, 0, size);
    return true;
}

uint32_t Smrd(uint32_t op, uint32_t sdst, uint32_t sbase, bool imm, uint32_t off) {
    return 0xC0000000u | op << 22 | sdst << 15 | (sbase / 2) << 9 | uint32_t(imm) << 8 | off;
}
uint32_t Sop2(uint32_t op, uint32_t sdst, uint32_t ssrc0, uint32_t ssrc1) {
    return 0x80000000u | op << 23 | sdst << 16 | ssrc1 << 8 | ssrc0;
}
void Mimg(std::vector<uint32_t>& c, uint32_t op, uint32_t vaddr, uint32_t vdata, uint32_t srsrc, uint32_t ssamp) {
    c.push_back(0xF0000000u | op << 18 | 0xFu << 8); // dmask xyzw
    c.push_back(vaddr | vdata << 8 | (srsrc / 4) << 16 | (ssamp / 4) << 21);
}
constexpr uint32_t kWait = 0xBF8C0000u, kEnd = 0xBF810000u;
constexpr uint32_t kSAddU32 = 0, kSOrB32 = 16;
constexpr uint32_t kSLoadX4 = 2, kSLoadX8 = 3, kSBufLoadX4 = 10, kSBufLoadX8 = 11;
constexpr uint32_t kImageLoad = 0, kImageSampleLz = 39;
constexpr uint64_t kCode = 0x100000;

// Translates a 64-thread compute shader with user data s[0:1] and the workgroup id in s2.
gcn_shader* Compile(const std::vector<uint32_t>& code, uint64_t hash, std::string* err) {
    std::vector<uint32_t> regs(0x10000, 0);
    regs[0x2E07] = 64;
    regs[0x2E08] = regs[0x2E09] = 1;
    regs[0x2E0C] = uint32_t(kCode >> 8);
    regs[0x2E12] = 1 | (3 << 6);    // 8 VGPRs, 32 SGPRs
    regs[0x2E13] = 2 << 1 | 1 << 7; // 2 user SGPRs, s2 = workgroup id x
    gcn_profile prof;
    gcn_profile_default_metal(&prof);
    gcn_runtime_info rt;
    gcn_runtime_info_from_regs(regs.data(), regs.size(), GCN_HW_CS, GCN_SW_COMPUTE, &prof, &rt);
    gcn_compile_desc d{};
    d.hw_stage = GCN_HW_CS;
    d.sw_stage = GCN_SW_COMPUTE;
    d.code_addr = kCode;
    d.code = code.data();
    d.code_size = uint32_t(code.size() * 4);
    d.hash = hash;
    d.runtime = &rt;
    d.profile = &prof;
    d.read_guest = ZeroRead;
    d.flags = GCN_COMPILE_EMIT_MSL;
    gcn_shader* sh = nullptr;
    char e[1024] = {};
    const gcn_status st = gcn_compile(&d, &sh, e, sizeof(e));
    *err = e;
    if (st != GCN_OK && sh) {
        gcn_shader_destroy(sh);
        return nullptr;
    }
    return st == GCN_OK ? sh : nullptr;
}

void TestBufferLoadedSharps() {
    std::vector<uint32_t> c;
    c.push_back(Sop2(kSAddU32, 8, 2, 0x80));         // s8 = workgroup id (0)
    c.push_back(Smrd(kSLoadX4, 4, 0, false, 8));     // V# s[4:7] at table + s8
    c.push_back(kWait);
    c.push_back(Smrd(kSBufLoadX8, 16, 4, true, 0));  // T# s[16:23] through it
    c.push_back(Smrd(kSBufLoadX4, 24, 4, true, 8));  // S# s[24:27] through it
    c.push_back(kWait);
    Mimg(c, kImageSampleLz, 0, 4, 16, 24);
    c.push_back(kWait);
    c.push_back(kEnd);
    std::string err;
    gcn_shader* sh = Compile(c, 0x5CA1AB1E0000E001ull, &err);
    CHECK(sh, "does not translate: %s", err.c_str());
    if (!sh) return;
    gcn_shader_info info{};
    gcn_shader_get_info(sh, &info);
    CHECK(info.null_image_reads == 1, "null_image_reads %u", info.null_image_reads);
    CHECK(info.num_samplers == 1, "%u samplers", info.num_samplers);
    std::vector<uint32_t> flat(std::max<uint32_t>(info.flatbuf_size_dw, 16), 0);
    uint32_t ss[4] = {1, 1, 1, 1};
    CHECK(!gcn_shader_fetch_sampler_sharp(sh, 0, flat.data(), ss), "the S# loaded at run time was fetched");
    CHECK(!ss[0] && !ss[1] && !ss[2] && !ss[3], "S# not zeroed");
    // the count survives the shader cache
    void* blob = nullptr;
    size_t n = 0;
    CHECK(gcn_shader_serialize(sh, &blob, &n) == GCN_OK, "serialize");
    gcn_shader* back = nullptr;
    char e[256] = {};
    CHECK(blob && gcn_shader_deserialize(blob, n, kCode, &back, e, sizeof(e)) == GCN_OK && back, "deserialize: %s", e);
    if (back) {
        gcn_shader_info bi{};
        gcn_shader_get_info(back, &bi);
        CHECK(bi.null_image_reads == 1, "null_image_reads %u after the cache", bi.null_image_reads);
        gcn_shader_destroy(back);
    }
    gcn_free(blob);
    gcn_shader_destroy(sh);
}

void TestComputedTsharp() {
    std::vector<uint32_t> c;
    c.push_back(Smrd(kSLoadX8, 16, 0, true, 0)); // T# s[16:23] from the table
    c.push_back(kWait);
    c.push_back(Sop2(kSOrB32, 16, 16, 17));      // s16 |= s17
    Mimg(c, kImageLoad, 0, 4, 16, 0);
    c.push_back(kWait);
    c.push_back(kEnd);
    std::string err;
    gcn_shader* sh = Compile(c, 0x5CA1AB1E0000E002ull, &err);
    CHECK(!sh, "a computed T# translated");
    if (sh) gcn_shader_destroy(sh);
    CHECK(err.find("T# dword 0") != std::string::npos && err.find("BitwiseOr32") != std::string::npos &&
              err.find("pc") != std::string::npos,
          "error: %s", err.c_str());
}

void TestComputedSsharp() {
    std::vector<uint32_t> c;
    c.push_back(Smrd(kSLoadX8, 16, 0, true, 0)); // T#
    c.push_back(Smrd(kSLoadX4, 24, 0, true, 8)); // S#
    c.push_back(kWait);
    c.push_back(Sop2(kSOrB32, 24, 24, 25));      // s24 |= s25
    Mimg(c, kImageSampleLz, 0, 4, 16, 24);
    c.push_back(kWait);
    c.push_back(kEnd);
    std::string err;
    gcn_shader* sh = Compile(c, 0x5CA1AB1E0000E003ull, &err);
    CHECK(!sh, "a computed S# translated");
    if (sh) gcn_shader_destroy(sh);
    CHECK(err.find("S# dword 0") != std::string::npos && err.find("BitwiseOr32") != std::string::npos,
          "error: %s", err.c_str());
}

} // namespace

int main() {
    TestBufferLoadedSharps();
    TestComputedTsharp();
    TestComputedSsharp();
    if (g_fail) {
        std::fprintf(stderr, "gcn_runtime_sharp_test: %d failure(s)\n", g_fail);
        return 1;
    }
    std::printf("gcn_runtime_sharp_test: PASS\n");
    return 0;
}
