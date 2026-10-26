// A metadata (HTILE) clear done by a compute shader covers every slice of a depth array whose
// HTILE it writes, not only the slice drawn first afterwards.
// The Last of Us Remastered draws its sun shadow cascades into a 3072x1792 D16 array of 3 slices
// (DB_DEPTH_VIEW slice 0, 1 and 2) after one compute clear of its HTILE (2304 groups, V# stride 8,
// num_records 0x24000: 1179648 bytes = 3 slices of 384x256 HTILE dwords). The renderer took that
// clear on the first draw (slice 0) only, so slices 1 and 2 were never cleared to 1.0: they kept
// the zeros written outside the camera frustum by earlier frames and every pixel of cascades 1
// and 2 read as in shadow (capture frame_10500 of the colour plan's Task 8).
// The registers and descriptors here are that capture's (DB_Z_INFO 0xa0000001, DB_DEPTH_SIZE
// 0x6f97f, DB_DEPTH_SLICE 0x14fff, DB_DEPTH_VIEW 0x2001 / 0x4002, the clear's V#), only the
// addresses are moved into the test's guest memory.
//  - full clear: after the clear, a draw into a 64x64 corner of each slice leaves 1.0 (the clear
//    value) everywhere else in that slice;
//  - one-slice clear (num_records for 393216 bytes): slice 0 is cleared, slices 1 and 2 keep their
//    contents;
//  - clear before the array has grown: a new depth surface drawn only in slice 0 (a 1-slice Metal
//    texture), then the clear, then slices 0, 1, 2: the slice-0 draw must leave the clear pending
//    for the slices the texture does not have yet;
//  - HTILE slice sizes (AMD addrlib ComputeHtileInfo): 8 pipes (base PS4 depth tile modes), 16
//    pipes (Neo), 2 pipes, linear HTILE; a Neo depth target is not sized (0: one-slice clears).
//
// usage: gnm_htile_slices_test
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>

#include <vector>

#include "gcn_recompiler.h"
#include "ps4_gnm_capture.h"
#include "ps4_gnm_draw.h"
#include "ps4_gnm_resources.h"

namespace {

int g_fail = 0;
#define CHECK(c, ...)                                                                  \
    do {                                                                               \
        if (!(c)) {                                                                    \
            fprintf(stderr, "gnm_htile_slices_test: FAIL %s:%d: ", __FILE__, __LINE__); \
            fprintf(stderr, __VA_ARGS__);                                              \
            fprintf(stderr, "\n");                                                     \
            g_fail++;                                                                  \
        }                                                                              \
    } while (0)

constexpr uint64_t kMemSize = 1ull << 32;
constexpr uint64_t kCode = 0x01000000, kVs = kCode, kPs = kCode + 0x1000, kCs = kCode + 0x2000;
// the capture's 0x1033670000 / 0x10355f0000; the "before growth" case uses a second pair, so its
// first frame meets a texture that has never been an array
uint64_t kDepth = 0x10000000, kHtile = 0x13000000;
float g_clear = 1.0f; // DB_DEPTH_CLEAR
constexpr uint32_t kW = 3072, kH = 1792, kSlices = 3;
constexpr uint32_t kHtileSliceBytes = 384 * 256 * 4; // 393216

uint8_t* g_mem = nullptr;
GuestContext g_ctx;

uint32_t Fbits(float f) {
    uint32_t u;
    memcpy(&u, &f, 4);
    return u;
}

namespace gcn {
uint32_t Vop1(uint32_t op, uint32_t vdst, uint32_t src0) { return 0x7E000000u | vdst << 17 | op << 9 | src0; }
uint32_t Vop2(uint32_t op, uint32_t vdst, uint32_t src0, uint32_t vsrc1) { return op << 25 | vdst << 17 | vsrc1 << 9 | src0; }
constexpr uint32_t kEnd = 0xBF810000u, kVMov = 1, kVLshlrev = 26, kVAnd = 27, kVAddI32 = 37;
constexpr uint32_t Inline(uint32_t n) { return 0x80 + n; }

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
} // namespace gcn

// A triangle covering the target from the vertex id (z = 0: the depth is PA_CL_VPORT_ZOFFSET)
std::vector<uint32_t> CoverVs() {
    using namespace gcn;
    constexpr uint32_t kVLshrrevB32 = 22, kVCvtF32I32 = 5;
    std::vector<uint32_t> c;
    c.push_back(Vop2(kVAnd, 10, Inline(1), 0));
    c.push_back(Vop2(kVLshrrevB32, 11, Inline(1), 0));
    for (uint32_t r = 10; r < 12; ++r) {
        c.push_back(Vop2(kVLshlrev, r, Inline(2), r));
        c.push_back(Vop2(kVAddI32, r, 0xC1, r)); // + (-1)
        c.push_back(Vop1(kVCvtF32I32, r, 0x100 + r));
    }
    c.push_back(Vop1(kVMov, 12, Inline(0)));
    c.push_back(Vop1(kVMov, 13, 0xF2)); // 1.0
    c.push_back(0xF800020Fu);           // exp param0 v10..v13
    c.push_back(10u | 11u << 8 | 12u << 16 | 13u << 24);
    c.push_back(0xF80008CFu);           // exp pos0 v10..v13 done
    c.push_back(10u | 11u << 8 | 12u << 16 | 13u << 24);
    c.push_back(kEnd);
    return WithFooter(c, 0x5CA1AB1E0000B100ull);
}

// The shadow casters' pixel shader: no colour, exp null done vm
std::vector<uint32_t> NullPs() {
    return gcn::WithFooter({0xF8001890u, 0u, gcn::kEnd}, 0x5CA1AB1E0000B110ull);
}

// The clear: one dword store per lane through the HTILE V# at s[4:7]; the renderer tracks such a
// dispatch as a metadata clear and does not run it
std::vector<uint32_t> ClearCs() {
    using namespace gcn;
    std::vector<uint32_t> c;
    c.push_back(Vop2(kVLshlrev, 1, Inline(2), 0)); // v1 = lane * 4
    c.push_back(Vop1(kVMov, 2, Inline(0)));
    c.push_back(0xE0701000u);                      // buffer_store_dword v2, v1, s[4:7] offen
    c.push_back(0x80u << 24 | 1u << 16 | 2u << 8 | 1u);
    c.push_back(kEnd);
    return WithFooter(c, 0x5CA1AB1E0000B120ull);
}

void Clear(uint32_t bytes) {
    std::vector<uint32_t> regs(0x10000, 0);
    regs[0x2E07] = 64;
    regs[0x2E08] = regs[0x2E09] = 1;
    regs[0x2E0C] = uint32_t(kCs >> 8);
    regs[0x2E12] = 3 | (3 << 6);
    regs[0x2E13] = 12 << 1; // user SGPRs s0..s11
    // the capture's V#: dword1 0x8b010 (base_hi 0x10, stride 8), num_records 0x24000, dword3 0x1805c02c
    regs[0x2E44] = uint32_t(kHtile);
    regs[0x2E45] = 0x8b000u | uint32_t(kHtile >> 32);
    regs[0x2E46] = bytes / 8;
    regs[0x2E47] = 0x1805c02cu;
    regs[0x2E4A] = 0x6f97f; // the clear's own user data: DB_DEPTH_SIZE, DB_DEPTH_SLICE
    regs[0x2E4B] = 0x14fff;
    ps4draw::Dispatch(&g_ctx, regs.data(), 2304, 1, 1, 0, "gfx", ps4draw::kQueueGfx);
}

// A depth-only draw of depth `z` into slice `slice` (DB_DEPTH_VIEW), the whole slice or a 64x64 corner
void DrawDepth(uint32_t slice, float z, bool corner) {
    std::vector<uint32_t> regs(0x10000, 0);
    ps4draw::SetRegDefaults(regs.data());
    auto stage = [&](uint32_t pgm, uint64_t code) {
        regs[pgm] = uint32_t(code >> 8);
        regs[pgm + 1] = uint32_t(code >> 40);
        regs[pgm + 2] = 3 | (3 << 6);
        regs[pgm + 3] = 0;
    };
    stage(0x2C48, kVs);
    stage(0x2C08, kPs);
    regs[0xA1B1] = 0;          // SPI_VS_OUT_CONFIG
    regs[0xA1B3] = 2;          // SPI_PS_INPUT_ENA: PERSP_CENTER
    regs[0xA1B4] = 2;
    regs[0xA1B6] = 0;
    regs[0xA1C3] = 4;          // SPI_SHADER_POS_FORMAT
    regs[0xA1C4] = 0;          // SPI_SHADER_Z_FORMAT
    regs[0xA1C5] = 0;          // SPI_SHADER_COL_FORMAT: no colour
    regs[0xA2D5] = 0;
    regs[0xA08E] = 0;          // CB_TARGET_MASK
    regs[0xA08F] = 0;
    regs[0xA202] = 0x00CC0010;
    // depth target: the capture's registers
    regs[0xA000] = 0x60;                       // DB_RENDER_CONTROL
    regs[0xA002] = slice | slice << 13;        // DB_DEPTH_VIEW: 0, 0x2001, 0x4002
    regs[0xA005] = uint32_t(kHtile >> 8);      // DB_HTILE_DATA_BASE
    regs[0xA00B] = Fbits(g_clear);             // DB_DEPTH_CLEAR
    regs[0xA00F] = 0x1d0c41;                   // DB_DEPTH_INFO
    regs[0xA010] = 0xa0000001;                 // DB_Z_INFO: Z16, HTILE
    regs[0xA011] = 0x20000000;                 // DB_STENCIL_INFO
    regs[0xA012] = regs[0xA014] = uint32_t(kDepth >> 8);
    regs[0xA016] = 0x6f97f;                    // DB_DEPTH_SIZE: 3072x1792
    regs[0xA017] = 0x14fff;                    // DB_DEPTH_SLICE
    regs[0xA200] = 0x7007f6;                   // DB_DEPTH_CONTROL: z test (always) and write
    regs[0xA2AF] = 0x8;                        // DB_HTILE_SURFACE
    const uint32_t bw = corner ? 64 : kW, bh = corner ? 64 : kH;
    regs[0xA00D] = kW | (kH << 16);            // PA_SC_SCREEN_SCISSOR_BR
    regs[0xA081] = 0x80000000;
    regs[0xA082] = kW | (kH << 16);
    regs[0xA090] = 0x80000000;                 // PA_SC_GENERIC_SCISSOR
    regs[0xA091] = bw | (bh << 16);
    regs[0xA0B4] = 0;                          // PA_SC_VPORT_ZMIN_0 / ZMAX_0
    regs[0xA0B5] = Fbits(1.0f);
    regs[0xA10F] = Fbits(kW / 2.f);
    regs[0xA110] = Fbits(kW / 2.f);
    regs[0xA111] = Fbits(kH / 2.f);
    regs[0xA112] = Fbits(kH / 2.f);
    regs[0xA113] = Fbits(0.f);                 // PA_CL_VPORT_ZSCALE
    regs[0xA114] = Fbits(z);                   // PA_CL_VPORT_ZOFFSET
    regs[0xA206] = 0x43F;
    regs[0xC242] = 4;
    ps4draw::DrawArgs args;
    args.count = 3;
    args.name = "htile-slices";
    const uint64_t skipped0 = ps4draw::SkippedCount();
    ps4draw::Draw(&g_ctx, regs.data(), args);
    CHECK(ps4draw::SkippedCount() == skipped0, "the draw into slice %u was skipped", slice);
}

// The depth array's slices (D16), read from the renderer's texture
bool ReadSlices(std::vector<uint16_t>* out) {
    ps4gnm_capture::GpuTextureId gid;
    gid.kind = 2;
    gid.address = kDepth;
    gid.mtl_format = gid.entry_format = (uint32_t)MTLPixelFormatDepth16Unorm;
    gid.width = kW;
    gid.height = kH;
    gid.layers = kSlices;
    gid.mtl_type = (uint32_t)MTLTextureType2DArray;
    gid.mtl_levels = 1;
    std::vector<uint8_t> raw;
    if (!ps4draw::ReplayReadTexture(gid, &raw) || raw.size() != size_t(kW) * kH * kSlices * 2) return false;
    out->resize(raw.size() / 2);
    memcpy(out->data(), raw.data(), raw.size());
    return true;
}

uint16_t At(const std::vector<uint16_t>& d, uint32_t slice, uint32_t x, uint32_t y) {
    return d[(size_t(slice) * kH + y) * kW + x];
}

uint16_t D16(float z) { return uint16_t(z * 65535.f + 0.5f); }

// Fills every slice with `z` (no clear pending), clears `clear_bytes` of HTILE, draws `corner_z`
// into the corner of each slice and checks each slice outside the corner against want[slice]
void Run(const char* what, uint32_t clear_bytes, float corner_z, const float want[kSlices]) {
    for (uint32_t s = 0; s < kSlices; ++s) DrawDepth(s, 0.25f, false);
    Clear(clear_bytes);
    for (uint32_t s = 0; s < kSlices; ++s) DrawDepth(s, corner_z, true);
    ps4draw::Flush(true);
    std::vector<uint16_t> d;
    if (!ReadSlices(&d)) {
        CHECK(false, "%s: no 3-slice depth texture at 0x%llx", what, (unsigned long long)kDepth);
        return;
    }
    for (uint32_t s = 0; s < kSlices; ++s) {
        const uint16_t in = At(d, s, 10, 10), out = At(d, s, 2000, 1000);
        CHECK(abs(int(in) - int(D16(corner_z))) <= 1, "%s: slice %u corner %u, want %u", what, s, in, D16(corner_z));
        CHECK(abs(int(out) - int(D16(want[s]))) <= 1, "%s: slice %u outside the corner %u, want %u (%.2f)", what, s,
              out, D16(want[s]), want[s]);
    }
}

// A new surface: its first frame draws only slice 0 before the clear
void RunBeforeGrowth() {
    kDepth = 0x20000000;
    kHtile = 0x23000000;
    g_clear = 0.9f;
    DrawDepth(0, 0.25f, false); // registers the HTILE; the Metal texture has one slice
    Clear(kSlices * kHtileSliceBytes);
    for (uint32_t s = 0; s < kSlices; ++s) DrawDepth(s, 0.75f, true);
    ps4draw::Flush(true);
    std::vector<uint16_t> d;
    if (!ReadSlices(&d)) {
        CHECK(false, "before growth: no 3-slice depth texture at 0x%llx", (unsigned long long)kDepth);
        return;
    }
    // slices 1 and 2 are created by the draws into them (contents undefined until written), so
    // this case clears to 0.9 rather than 1.0
    for (uint32_t s = 0; s < kSlices; ++s)
        CHECK(abs(int(At(d, s, 2000, 1000)) - int(D16(g_clear))) <= 1,
              "before growth: slice %u outside the corner %u, want %u (cleared to %.1f)", s, At(d, s, 2000, 1000),
              D16(g_clear), g_clear);
}

void TestSizes() {
    using ps4gnm::HtileSliceBytes;
    CHECK(HtileSliceBytes(3072, 1792, 8, false) == 393216, "8 pipes 3072x1792: %llu",
          (unsigned long long)HtileSliceBytes(3072, 1792, 8, false)); // the capture: 0x24000 * 8 / 3
    CHECK(HtileSliceBytes(1536, 1792, 8, false) == 196608, "8 pipes 1536x1792: %llu",
          (unsigned long long)HtileSliceBytes(1536, 1792, 8, false)); // 512x512 macro tile
    CHECK(HtileSliceBytes(1536, 1792, 16, false) == 262144, "16 pipes 1536x1792: %llu",
          (unsigned long long)HtileSliceBytes(1536, 1792, 16, false)); // 1024x512 macro tile
    CHECK(HtileSliceBytes(64, 64, 16, false) == 32768, "16 pipes 64x64: %llu",
          (unsigned long long)HtileSliceBytes(64, 64, 16, false));
    CHECK(HtileSliceBytes(1536, 1792, 2, false) == 172032, "2 pipes 1536x1792: %llu",
          (unsigned long long)HtileSliceBytes(1536, 1792, 2, false)); // 256x256 macro tile
    CHECK(HtileSliceBytes(3072, 1792, 8, true) == 344064, "linear 8 pipes 3072x1792: %llu",
          (unsigned long long)HtileSliceBytes(3072, 1792, 8, true)); // 128x64
    CHECK(HtileSliceBytes(3072, 1792, 4, false) == 0, "4 pipes are not sized");
    ps4gnm::DepthTarget d;
    d.tile_mode = ps4gnm::TileMode::Depth2DThin64;
    d.pitch = 3072;
    d.height = 1792;
    CHECK(ps4gnm::DepthHtileSliceBytes(d, false) == 393216, "base PS4 depth target: %llu",
          (unsigned long long)ps4gnm::DepthHtileSliceBytes(d, false));
    CHECK(ps4gnm::DepthHtileSliceBytes(d, true) == 0, "Neo depth target: %llu, want 0 (not sized)",
          (unsigned long long)ps4gnm::DepthHtileSliceBytes(d, true));
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
            fprintf(stderr, "gnm_htile_slices_test: FAIL no guest memory\n");
            return 1;
        }
        g_mem = (uint8_t*)m;
        memset(&g_ctx, 0, sizeof(g_ctx));
        g_ctx.mem_base = g_mem;
        g_ctx.mem_size = kMemSize;
        if (!ps4draw::Init(&g_ctx)) {
            fprintf(stderr, "gnm_htile_slices_test: FAIL the renderer did not start\n");
            return 1;
        }
        const std::vector<uint32_t> vs = CoverVs(), ps = NullPs(), cs = ClearCs();
        memcpy(g_mem + kVs, vs.data(), vs.size() * 4);
        memcpy(g_mem + kPs, ps.data(), ps.size() * 4);
        memcpy(g_mem + kCs, cs.data(), cs.size() * 4);
        ps4draw::NotifyGuestWrite(kCode, 0x10000, false, 0);
        const float all[kSlices] = {1.0f, 1.0f, 1.0f}, first[kSlices] = {1.0f, 0.25f, 0.25f};
        Run("clear of 3 slices", kSlices * kHtileSliceBytes, 0.75f, all);
        Run("clear of slice 0", kHtileSliceBytes, 0.5f, first);
        RunBeforeGrowth();
        TestSizes();
        if (g_fail) {
            fprintf(stderr, "gnm_htile_slices_test: %d failure(s)\n", g_fail);
            return 1;
        }
        printf("gnm_htile_slices_test: PASS\n");
        return 0;
    }
}
