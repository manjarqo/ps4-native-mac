// Cube T#s through the real renderer (ps4draw::Dispatch: translation, texture cache, upload,
// binding, dispatch on Metal), run with Metal API validation. The translator declares every cube
// image as a 2D array of its faces (shadPS4: a GCN cube sample addresses a face by its index, the
// coordinates the shader computed with v_cubeid / v_cubesc / v_cubetc), so the renderer binds a 2D
// array view of the cube texture. Before, it bound the cube texture itself where the shader declares
// a texture2d_array, which Metal's validation rejects ("incorrect type of texture
// (MTLTextureTypeCube) ... expect MTLTextureType2DArray"; inFAMOUS Second Son's lighting passes).
// Hand-assembled compute shader (user data: s[0:7] the T#, s[8:11] the output V#, s[12:15] a point
// S#): image_sample_lz (DA) at (0.5, 0.5, face) for a few faces, each result stored with
// buffer_store_dwordx4.
//   (a) a 4x4 RGBA8 cube, each face its own colour: faces 1 and 4 read their colours;
//   (b) the same with POW2PAD (a guest layout of 8 slices; the texture holds the 6 faces): face 5;
//   (c) a cube array of 2 cubes whose T# view starts at its second cube (BASE_ARRAY 6, LAST_ARRAY
//       11): faces 1 and 4 of the view are faces 7 and 10 of the texture.
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>

#include <algorithm>
#include <array>
#include <string>
#include <vector>

#include "gcn_recompiler.h"
#include "ps4_gnm_draw.h"
#include "ps4_gnm_resources.h"

namespace {

int g_fail = 0;
#define CHECK(c, ...)                                                                \
    do {                                                                             \
        if (!(c)) {                                                                  \
            fprintf(stderr, "gnm_cube_view_test: FAIL %s:%d: ", __FILE__, __LINE__); \
            fprintf(stderr, __VA_ARGS__);                                            \
            fprintf(stderr, "\n");                                                   \
            g_fail++;                                                                \
        }                                                                            \
    } while (0)

constexpr uint64_t kMemSize = 1ull << 32;
constexpr uint64_t kCodeA = 0x01000000, kCodeB = 0x01010000, kCodeC = 0x01020000;
constexpr uint64_t kOutA = 0x02000000, kOutB = 0x02010000, kOutC = 0x02020000;
constexpr uint64_t kTexA = 0x03000000, kTexB = 0x03100000, kTexC = 0x03200000;
constexpr uint32_t kSentinel = 0xCDCDCDCDu;
constexpr uint32_t kLinearAligned = 8;

uint8_t* g_mem = nullptr;
GuestContext g_ctx;

uint32_t* At(uint64_t addr) { return reinterpret_cast<uint32_t*>(g_mem + addr); }

uint32_t F(float f) {
    uint32_t u;
    memcpy(&u, &f, 4);
    return u;
}

std::vector<uint32_t> WithFooter(std::vector<uint32_t> body, uint64_t hash) {
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

// v0 = 0.5, v1 = 0.5, v2 = face; image_sample_lz v[4:7], v[0:2], s[0:7], s[12:15] dmask xyzw da;
// buffer_store_dwordx4 v[4:7] at 16 * k, one per face.
std::vector<uint32_t> Program(const std::vector<uint32_t>& faces, uint64_t hash) {
    std::vector<uint32_t> c;
    for (size_t k = 0; k < faces.size(); ++k) {
        c.push_back(0x7E0002F0);                // v_mov_b32 v0, 0.5
        c.push_back(0x7E0202F0);                // v_mov_b32 v1, 0.5
        c.push_back(0x7E0402FF);                // v_mov_b32 v2, literal
        c.push_back(F(float(faces[k])));
        c.push_back(0xF0000000u | 39u << 18 | 1u << 14 | 0xFu << 8); // image_sample_lz, DA
        c.push_back(0 | 4u << 8 | (0u / 4) << 16 | (12u / 4) << 21);
        c.push_back(0xBF8C0000u);               // s_waitcnt 0
        c.push_back(0xE0000000u | 30u << 18 | uint32_t(16 * k)); // buffer_store_dwordx4
        c.push_back(0x80u << 24 | (8u / 4) << 16 | 4u << 8);
        c.push_back(0xBF8C0000u);
    }
    c.push_back(0xBF810000u); // s_endpgm
    return WithFooter(c, hash);
}

// 4x4 RGBA8 unorm linear-aligned cube T# (pitch 64), one level, `cubes` cubes, viewing faces
// base_array..last_array.
void PutCubeTsharp(uint32_t* t, uint64_t addr, bool pow2pad, uint32_t cubes = 1, uint32_t base_array = 0,
                   uint32_t last_array = 5) {
    memset(t, 0, 32);
    t[0] = uint32_t(addr >> 8);
    t[1] = 10u << 20; // 8_8_8_8 unorm
    t[2] = 3 | (3u << 14);
    t[3] = 4 | (5 << 3) | (6 << 6) | (7 << 9) | (kLinearAligned << 20) | (uint32_t(pow2pad) << 25) | (11u << 28);
    t[4] = (cubes - 1) | (63u << 13); // depth: cubes - 1, pitch 64
    t[5] = base_array | (last_array << 13);
}

std::vector<uint32_t> Regs(uint64_t code_addr, const uint32_t* tsharp, uint64_t out, uint32_t out_bytes) {
    std::vector<uint32_t> regs(0x10000, 0);
    regs[0x2E07] = 64;
    regs[0x2E08] = regs[0x2E09] = 1;
    regs[0x2E0C] = uint32_t(code_addr >> 8);
    regs[0x2E12] = 1 | (3 << 6); // 8 VGPRs, 32 SGPRs
    regs[0x2E13] = 16 << 1;      // 16 user SGPRs
    uint32_t* ud = &regs[0x2E40];
    memcpy(ud, tsharp, 32);
    ud[8] = uint32_t(out); // V#: stride 0, out_bytes, 32-bit uint
    ud[9] = uint32_t(out >> 32) & 0xFFF;
    ud[10] = out_bytes;
    ud[11] = 4 | (5 << 3) | (6 << 6) | (7 << 9) | (4 << 12) | (4 << 15);
    ud[12] = 0;            // S#: wrap, point filters
    ud[13] = 0xF00u << 12; // max_lod 15
    ud[14] = 0;
    ud[15] = 0;
    return regs;
}

uint32_t FaceColor(uint32_t f) { return 0xFF000000u | (f * 20u) << 16 | (255u - f * 20u) << 8 | (f * 17u); }

std::array<uint32_t, 4> Unorm(uint32_t abgr) {
    std::array<uint32_t, 4> r;
    for (int c = 0; c < 4; ++c) r[c] = F(float((abgr >> (8 * c)) & 0xFF) / 255.0f);
    return r;
}

// faces: the face coordinates sampled; first_face: the texture face the view's face 0 is.
void Run(const char* name, uint64_t code_addr, uint64_t tex, bool pow2pad, uint64_t out,
         const std::vector<uint32_t>& faces, uint64_t hash, uint32_t cubes = 1, uint32_t first_face = 0) {
    uint32_t t[8];
    PutCubeTsharp(t, tex, pow2pad, cubes, first_face, first_face + 5);
    // every texel of face f FaceColor(f), at the faces' offsets in the guest layout
    ps4gnm::ImageDesc d;
    ps4gnm::SurfaceLayout l;
    CHECK(ps4gnm::DecodeImage(t, 8, &d) && ps4gnm::ComputeSurfaceLayout(d.ToSurfaceDesc(false), &l),
          "%s: the T# does not decode", name);
    const uint32_t slice_bytes = l.mips[0].size / std::max(1u, l.mips[0].slices);
    for (uint32_t f = 0; f < l.mips[0].slices; ++f)
        for (uint32_t i = 0; i < slice_bytes / 4; ++i) At(tex + uint64_t(slice_bytes) * f)[i] = FaceColor(f);
    ps4draw::NotifyGuestWrite(tex, l.total_size, false, 0);
    const std::vector<uint32_t> code = Program(faces, hash);
    memcpy(g_mem + code_addr, code.data(), code.size() * 4);
    const uint32_t out_bytes = uint32_t(faces.size() * 16);
    for (uint32_t k = 0; k < out_bytes / 4; ++k) At(out)[k] = kSentinel;
    ps4draw::NotifyGuestWrite(code_addr, 0x10000, false, 0);
    ps4draw::NotifyGuestWrite(out, 0x1000, false, 0);
    const std::vector<uint32_t> regs = Regs(code_addr, t, out, out_bytes);
    const uint64_t skipped0 = ps4draw::SkippedCount();
    ps4draw::Dispatch(&g_ctx, regs.data(), 1, 1, 1, 0, "gfx", ps4draw::kQueueGfx);
    ps4draw::Flush(true);
    CHECK(ps4draw::SkippedCount() == skipped0, "%s: the dispatch was skipped", name);
    for (size_t k = 0; k < faces.size(); ++k) {
        const uint32_t* got = At(out + 16 * k);
        const std::array<uint32_t, 4> want = Unorm(FaceColor(first_face + faces[k]));
        CHECK(memcmp(got, want.data(), 16) == 0, "%s: face %u read %08x %08x %08x %08x, want %08x %08x %08x %08x",
              name, faces[k], got[0], got[1], got[2], got[3], want[0], want[1], want[2], want[3]);
    }
}

} // namespace

int main(int argc, char** argv) {
    @autoreleasepool {
        if (argc > 1) {
            fprintf(stderr, "usage: gnm_cube_view_test\n");
            return 2;
        }
        setenv("PS4_GNM_SYNC_ENCODE", "1", 1);
        setenv("PS4_GNM_SYNC_COMPILE", "1", 1);
        setenv("PS4_GNM_NO_SHADER_CACHE", "1", 1);
        setenv("PS4_GNM_NO_PSO_ARCHIVE", "1", 1);
        setenv("PS4_GNM_NO_LIB_STORE", "1", 1);
        setenv("PS4_GNM_MEM_LOG", "0", 1);
        void* m = mmap(nullptr, kMemSize, PROT_READ | PROT_WRITE, MAP_ANON | MAP_PRIVATE | MAP_NORESERVE, -1, 0);
        if (m == MAP_FAILED) {
            fprintf(stderr, "gnm_cube_view_test: FAIL no guest memory\n");
            return 1;
        }
        g_mem = (uint8_t*)m;
        memset(&g_ctx, 0, sizeof(g_ctx));
        g_ctx.mem_base = g_mem;
        g_ctx.mem_size = kMemSize;
        if (!ps4draw::Init(&g_ctx)) {
            fprintf(stderr, "gnm_cube_view_test: FAIL the renderer did not start\n");
            return 1;
        }
        Run("cube", kCodeA, kTexA, false, kOutA, {1, 4}, 0xC0BE000000000001ull);
        Run("pow2pad cube", kCodeB, kTexB, true, kOutB, {5}, 0xC0BE000000000002ull);
        Run("second cube of a cube array", kCodeC, kTexC, false, kOutC, {1, 4}, 0xC0BE000000000003ull, 2, 6);
        if (g_fail) {
            fprintf(stderr, "gnm_cube_view_test: %d failure(s)\n", g_fail);
            return 1;
        }
        printf("gnm_cube_view_test: PASS\n");
        return 0;
    }
}
