// Ordering of the guest detile dispatch (EncodeGpuUploadAt's DispatchThreads, ps4_gnm_draw.mm)
// through the real renderer (ps4draw::Dispatch: translation, hazards, texture cache, GPU upload,
// binding). An experimental Metal 4 barrier model (per-encoder fences instead of encoder-start
// barriers) that left this dispatch unordered could read the tiled source before the GPU wrote it
// (RAW on gbuf), and could write the shared staging buffer while an earlier copy from it still read
// it (WAR/WAW on detile_staging). Replays end every pass with Flush(true), so they cannot see it;
// this test keeps everything in one seq.
//
// Each iteration, in one seq (nothing committed in between):
//  - producer P (guest compute shader): copies 32 MiB of tiled texel data from a source buffer to
//    two adjacent 2048x2048 R32 uint surfaces T1 and T2 (1D thin tiling), last bytes first, each
//    element written kRepeat times, so the dispatch runs long; its compute encoder stays open;
//  - consumer C1 samples T1 (image_load_mip of every texel) and stores the values to OUT1: binding
//    it finds T1's memory written by pending GPU work, so the renderer copies T1 on the GPU behind P
//    (GpuUploadTexture): the detile dispatch into the staging buffer of the 16 MiB size class (in
//    P's encoder, after the renderer's barrier), then the blit into the texture;
//  - consumer C2 does the same for T2: a second detile into the same staging buffer, after the
//    first one's copy read it.
// Then Flush(true): OUT1 and OUT2 must hold every texel of this iteration's pattern, byte for byte.
// The pattern changes every iteration, so a detile that reads T1/T2 before P wrote them returns the
// previous iteration's texels; a failure reports how many wrong texels hold those. It also reports
// how many hold the other texture's texels (T2's in T1: the staging buffer overwritten under the
// first copy), but that count is a diagnostic only: no mutation tried made it non-trivial (it
// stayed at 0-1), so the staging WAR/WAW is covered only together with everything else, by
// PS4_GNM_MTL4_NO_BARRIERS=1 failing every texel, and on Metal 3 by untracked staging.
//
// Mutations that turned it red on both backends: the detile's Barrier(Dispatch -> Dispatch) after P
// removed or moved after the detile (only T1 fails, with the previous iteration's texels: the RAW
// on gbuf; T2's detile is in a new encoder, after the start barrier). Metal 3 only: the staging
// buffer made untracked (all texels of T1 and T2). Metal 4 only: PS4_GNM_MTL4_NO_BARRIERS=1 (no
// encoder-start barriers; all texels of T1 and T2).
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>

#include <vector>

#include "gcn_recompiler.h"
#include "ps4_gnm_draw.h"
#include "ps4_gnm_resources.h"

namespace {

int g_fail = 0;
#define CHECK(c, ...)                                                                   \
    do {                                                                                \
        if (!(c)) {                                                                     \
            fprintf(stderr, "gnm_detile_order_test: FAIL %s:%d: ", __FILE__, __LINE__); \
            fprintf(stderr, __VA_ARGS__);                                               \
            fprintf(stderr, "\n");                                                      \
            g_fail++;                                                                   \
        }                                                                               \
    } while (0)

constexpr uint64_t kMemSize = 1ull << 32;
constexpr uint64_t kCodeP = 0x01000000, kCodeC = 0x01010000;
constexpr uint64_t kSrc = 0x10000000;                    // the tiled bytes of T1 then T2
constexpr uint64_t kTex1 = 0x20000000;                   // T1; T2 follows it
constexpr uint64_t kOut1 = 0x30000000, kOut2 = 0x32000000;
constexpr uint32_t kDim = 2048, kLog2Dim = 11;           // 2048 x 2048 texels, 4 bytes each: 16 MiB
constexpr uint32_t kTiled1D = 13;                        // tiling index Thin1DThin
constexpr uint32_t kRepeat = 32;                         // P writes every element this many times
constexpr int kIterations = 6;

uint8_t* g_mem = nullptr;
GuestContext g_ctx;

namespace gcn {
constexpr uint32_t V(uint32_t n) { return 0x100 + n; }
constexpr uint32_t kWait = 0xBF8C0000u, kEnd = 0xBF810000u, kLiteral = 0xFF;
constexpr uint32_t kVMov = 1;                                                // VOP1
constexpr uint32_t kVLshrrev = 22, kVLshlrev = 26, kVAnd = 27, kVAddI32 = 37, kVSubI32 = 38; // VOP2
constexpr uint32_t kLoadDwordx4 = 14, kStoreDword = 28, kStoreDwordx4 = 30;  // MUBUF
constexpr uint32_t kImageLoadMip = 1;                                        // MIMG
uint32_t Vop1(uint32_t op, uint32_t vdst, uint32_t src0) { return 0x7E000000u | vdst << 17 | op << 9 | src0; }
uint32_t Vop2(uint32_t op, uint32_t vdst, uint32_t src0, uint32_t vsrc1) { return op << 25 | vdst << 17 | vsrc1 << 9 | src0; }
void Mubuf(std::vector<uint32_t>& c, uint32_t op, uint32_t vaddr, uint32_t vdata, uint32_t srsrc) {
    c.push_back(0xE0000000u | op << 18 | 1u << 12); // offen
    c.push_back(0x80u << 24 | (srsrc / 4) << 16 | vdata << 8 | vaddr); // soffset 0
}
void Mimg(std::vector<uint32_t>& c, uint32_t op, uint32_t vaddr, uint32_t vdata, uint32_t srsrc) {
    c.push_back(0xF0000000u | op << 18 | 0xFu << 8); // dmask xyzw
    c.push_back(vaddr | vdata << 8 | (srsrc / 4) << 16);
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
// v1 = workgroup id (in s`wg`) * 64 + thread id x (v0)
void GlobalId(std::vector<uint32_t>& c, uint32_t wg) {
    c.push_back(Vop1(kVMov, 1, wg));
    c.push_back(Vop2(kVLshlrev, 1, 0x86, 1));
    c.push_back(Vop2(kVAddI32, 1, V(0), 1));
}
} // namespace gcn

// P: s[0:3] V# of the source, s[4:7] V# of T1 and T2's memory, s8 = workgroup id. Thread g copies
// the 16 bytes of chunk n - 1 - g (n chunks in all), kRepeat times: the workgroups launched last
// write the start of T1, which the detile reads first, so a detile not ordered after P overlaps
// P's last, long-running workgroups.
std::vector<uint32_t> ProducerProgram(uint32_t chunks) {
    using namespace gcn;
    std::vector<uint32_t> c;
    GlobalId(c, 8);
    c.push_back(Vop2(kVSubI32, 1, kLiteral, 1));
    c.push_back(chunks - 1);                  // v1 = n - 1 - g
    c.push_back(Vop2(kVLshlrev, 2, 0x84, 1)); // v2 = v1 * 16
    for (uint32_t k = 0; k < kRepeat; ++k) {
        Mubuf(c, kLoadDwordx4, 2, 3, 0);
        c.push_back(kWait);
        Mubuf(c, kStoreDwordx4, 2, 3, 4);
        c.push_back(kWait);
    }
    c.push_back(kEnd);
    return WithFooter(c, 0x5CA1AB1E00009001ull);
}

// C: s[0:7] T# of the texture, s[8:11] V# of the output, s12 = workgroup id. Thread g loads texel
// (g % 2048, g / 2048) and stores it at byte 4 g.
std::vector<uint32_t> ConsumerProgram() {
    using namespace gcn;
    std::vector<uint32_t> c;
    GlobalId(c, 12);
    c.push_back(Vop2(kVAnd, 2, kLiteral, 1));
    c.push_back(kDim - 1);                          // v2 = x
    c.push_back(Vop2(kVLshrrev, 3, 0x80 + kLog2Dim, 1)); // v3 = y
    c.push_back(Vop1(kVMov, 4, 0x80));              // v4 = level 0
    Mimg(c, kImageLoadMip, 2, 5, 0);                // v[5:8]
    c.push_back(kWait);
    c.push_back(Vop2(kVLshlrev, 9, 0x82, 1)); // v9 = g * 4
    Mubuf(c, kStoreDword, 9, 5, 8);
    c.push_back(kEnd);
    return WithFooter(c, 0x5CA1AB1E00009002ull);
}

void PutVsharp(uint32_t* v, uint64_t base, uint32_t bytes) {
    v[0] = uint32_t(base);
    v[1] = uint32_t(base >> 32) & 0xFFF; // stride 0: num_records in bytes
    v[2] = bytes;
    v[3] = 4 | (5 << 3) | (6 << 6) | (7 << 9) | (4 << 12) | (4 << 15); // xyzw, uint, 32
}

// 2048 x 2048, FMT_32 uint, dst_sel xyzw, tiling index kTiled1D, 2D, pitch 2048
void PutTsharp(uint32_t* t, uint64_t addr) {
    memset(t, 0, 32);
    t[0] = uint32_t(addr >> 8);
    t[1] = (4u << 20) | (4u << 26);
    t[2] = (kDim - 1) | ((kDim - 1) << 14);
    t[3] = 4 | (5 << 3) | (6 << 6) | (7 << 9) | (kTiled1D << 20) | (9u << 28);
    t[4] = (kDim - 1) << 13;
}

std::vector<uint32_t> Regs(uint64_t code, uint32_t user_sgprs) {
    std::vector<uint32_t> regs(0x10000, 0);
    regs[0x2E07] = 64; // 64 threads
    regs[0x2E08] = regs[0x2E09] = 1;
    regs[0x2E0C] = uint32_t(code >> 8);
    regs[0x2E12] = 3 | (3 << 6);              // 16 VGPRs, 32 SGPRs
    regs[0x2E13] = user_sgprs << 1 | 1 << 7; // user SGPRs, then the workgroup id x
    return regs;
}

uint32_t Texel(int iter, uint32_t tex, uint32_t x, uint32_t y) {
    uint32_t h = (uint32_t)iter * 0x9E3779B1u ^ tex * 0x85EBCA77u ^ x * 0xC2B2AE3Du ^ y * 0x27D4EB2Fu;
    h ^= h >> 15;
    h *= 0x2C1B3C6Du;
    return h ^ (h >> 12);
}

} // namespace

int main() {
    @autoreleasepool {
        setenv("PS4_GNM_SYNC_ENCODE", "1", 1);
        setenv("PS4_GNM_SYNC_COMPILE", "1", 1);
        setenv("PS4_GNM_NO_SHADER_CACHE", "1", 1);
        setenv("PS4_GNM_NO_PSO_ARCHIVE", "1", 1);
        setenv("PS4_GNM_NO_LIB_STORE", "1", 1);
        setenv("PS4_GNM_MEM_LOG", "0", 1);
        void* m = mmap(nullptr, kMemSize, PROT_READ | PROT_WRITE, MAP_ANON | MAP_PRIVATE | MAP_NORESERVE, -1, 0);
        if (m == MAP_FAILED) {
            fprintf(stderr, "gnm_detile_order_test: FAIL no guest memory\n");
            return 1;
        }
        g_mem = (uint8_t*)m;
        memset(&g_ctx, 0, sizeof(g_ctx));
        g_ctx.mem_base = g_mem;
        g_ctx.mem_size = kMemSize;
        if (!ps4draw::Init(&g_ctx)) {
            fprintf(stderr, "gnm_detile_order_test: FAIL the renderer did not start\n");
            return 1;
        }
        uint32_t ts[8];
        PutTsharp(ts, kTex1);
        ps4gnm::ImageDesc img;
        CHECK(ps4gnm::DecodeImage(ts, 8, &img) && img.valid, "the T# does not decode");
        const ps4gnm::SurfaceDesc sd = img.ToSurfaceDesc();
        ps4gnm::SurfaceLayout layout;
        CHECK(ps4gnm::ComputeSurfaceLayout(sd, &layout), "no layout");
        const uint64_t size = layout.total_size; // 16 MiB: one staging size class for both
        CHECK(size == (uint64_t)kDim * kDim * 4, "surface of %llu bytes, want %u", (unsigned long long)size, kDim * kDim * 4);
        if (g_fail) return 1;
        const uint64_t tex2 = kTex1 + size;
        std::vector<uint32_t> offset(kDim * kDim); // byte offset of texel (x, y) in the tiled surface
        for (uint32_t y = 0; y < kDim; ++y)
            for (uint32_t x = 0; x < kDim; ++x) offset[y * kDim + x] = (uint32_t)ps4gnm::TiledElementOffset(sd, layout, 0, x, y, 0);

        const std::vector<uint32_t> prog_p = ProducerProgram((uint32_t)(2 * size / 16)), prog_c = ConsumerProgram();
        memcpy(g_mem + kCodeP, prog_p.data(), prog_p.size() * 4);
        memcpy(g_mem + kCodeC, prog_c.data(), prog_c.size() * 4);
        ps4draw::NotifyGuestWrite(kCodeP, 0x20000, false, 0);
        std::vector<uint32_t> rp = Regs(kCodeP, 8);
        PutVsharp(&rp[0x2E40], kSrc, (uint32_t)(2 * size));
        PutVsharp(&rp[0x2E44], kTex1, (uint32_t)(2 * size));
        std::vector<uint32_t> rc[2] = {Regs(kCodeC, 12), Regs(kCodeC, 12)};
        const uint64_t tex_at[2] = {kTex1, tex2}, out_at[2] = {kOut1, kOut2};
        for (int t = 0; t < 2; ++t) {
            PutTsharp(&rc[t][0x2E40], tex_at[t]);
            PutVsharp(&rc[t][0x2E48], out_at[t], (uint32_t)size);
        }
        const uint32_t p_groups = (uint32_t)(2 * size / 16 / 64), c_groups = kDim * kDim / 64;

        for (int it = 0; it < kIterations; ++it) {
            // this iteration's texels in the source, at their tiled positions; the outputs cleared
            for (uint32_t t = 0; t < 2; ++t) {
                uint32_t* src = (uint32_t*)(g_mem + kSrc + t * size);
                for (uint32_t y = 0; y < kDim; ++y)
                    for (uint32_t x = 0; x < kDim; ++x) src[offset[y * kDim + x] / 4] = Texel(it, t, x, y);
                memset(g_mem + out_at[t], 0xCD, size);
            }
            ps4draw::NotifyGuestWrite(kSrc, 2 * size, false, 0);
            ps4draw::NotifyGuestWrite(kOut1, kOut2 + size - kOut1, false, 0);
            const uint64_t skipped0 = ps4draw::SkippedCount();
            ps4draw::Dispatch(&g_ctx, rp.data(), p_groups, 1, 1, 0, "gfx", ps4draw::kQueueGfx);
            ps4draw::Dispatch(&g_ctx, rc[0].data(), c_groups, 1, 1, 0, "gfx", ps4draw::kQueueGfx);
            ps4draw::Dispatch(&g_ctx, rc[1].data(), c_groups, 1, 1, 0, "gfx", ps4draw::kQueueGfx);
            ps4draw::Flush(true);
            CHECK(ps4draw::SkippedCount() == skipped0, "iteration %d: a dispatch was skipped", it);
            for (uint32_t t = 0; t < 2; ++t) {
                const uint32_t* out = (const uint32_t*)(g_mem + out_at[t]);
                uint32_t bad = 0, first = 0, prev = 0, other = 0;
                for (uint32_t y = 0; y < kDim; ++y)
                    for (uint32_t x = 0; x < kDim; ++x) {
                        const uint32_t i = y * kDim + x, got = out[i];
                        if (got == Texel(it, t, x, y)) continue;
                        if (!bad++) first = i;
                        if (it > 0 && got == Texel(it - 1, t, x, y)) prev++; // read before P wrote it
                        if (got == Texel(it, 1 - t, x, y)) other++;          // the other detile's texel
                    }
                CHECK(!bad, "iteration %d, T%u: %u of %u texels wrong (%u of the previous iteration, %u of the other "
                      "texture); first at (%u, %u): %08x, want %08x",
                      it, t + 1, bad, kDim * kDim, prev, other, first % kDim, first / kDim, out[first],
                      Texel(it, t, first % kDim, first / kDim));
            }
        }
        if (g_fail) {
            fprintf(stderr, "gnm_detile_order_test: %d failure(s)\n", g_fail);
            return 1;
        }
        printf("gnm_detile_order_test: PASS (%d iterations)\n", kIterations);
        return 0;
    }
}
