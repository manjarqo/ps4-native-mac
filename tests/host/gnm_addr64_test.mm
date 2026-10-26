// MUBUF ADDR64 loads (CI: address = V#.base + VGPR[vaddr:vaddr+1] + soffset + inst_offset), run
// through the real renderer (translation, guest memory page table, Metal).
// The load sequence is The Last of Us Remastered's hair pixel shader 0xfff8f347 (and 17 other
// hair and foliage shaders), which reads the rows of its shadow cascade matrix this way:
//   s_mov_b32 s12, 0 ; s_mov_b32 s13, 0x40000 ; s_mov_b32 s14, -1 ; s_mov_b32 s15, 0x20024004
//   v_add_i32 v9, s52, v6 ; v_mov_b32 v6, s53 ; v_addc_u32 v10, 0, v6   (s[52:53]: SRT pointer)
//   buffer_load_dwordx4 v[22:25], v[9:10], s[12:15], 0 addr64
// (capture frame_9000 of the colour plan's Task 7, PS @0x10961f3800 offsets 0x8..0x168). The V#
// has base 0, stride 4 and num_records 0xFFFFFFFF; the translator used to ignore addr64 and read
// offset 0 of that V# (0 for every row), so those surfaces were never in shadow.
//  - compute: per lane a row at pointer + 0x3A4 + 48 * (lane & 3), the pointer just below 4 GiB so
//    the 64-bit add carries; a second load with soffset 16 and inst_offset 16 (+32 bytes). Every
//    lane must store exactly the dwords at those addresses.
//  - compute: lane * 16 from a pointer 256 bytes below 4 GiB, so the pointer's high dword is 0
//    in lanes 0..15 and 1 in the others; the same load with offen set as well (ADDR64 ignores
//    offen: the VGPR pair is the address, not an offset to add).
//  - draw: the same loads in a pixel shader (the cascade from user data), which stores them with
//    buffer_store_dwordx4 through a bound V#. The renderer binds draw stages with guest memory to
//    the page table and its draw fault slot (pass mode): the first draw meets the rows' 64 MiB page
//    unmapped (reads 0), the renderer maps it, and the next draws read the rows.
//
// usage: gnm_addr64_test
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>

#include <string>
#include <vector>

#include "gcn_recompiler.h"
#include "ps4_gnm_draw.h"

namespace {

int g_fail = 0;
#define CHECK(c, ...)                                                               \
    do {                                                                            \
        if (!(c)) {                                                                 \
            fprintf(stderr, "gnm_addr64_test: FAIL %s:%d: ", __FILE__, __LINE__);   \
            fprintf(stderr, __VA_ARGS__);                                           \
            fprintf(stderr, "\n");                                                  \
            g_fail++;                                                               \
        }                                                                           \
    } while (0)

constexpr uint64_t kMemSize = 1ull << 33;   // 8 GiB (reserved, not committed)
constexpr uint64_t kCode = 0x01000000;
constexpr uint64_t kSrt = 0x02000000;       // dwords 4..5: the pointer
constexpr uint64_t kPtr = 0xFFFFFE00ull;    // rows from kPtr + 0x3A4: past 4 GiB (the add carries)
constexpr uint64_t kPtr2 = 0xFFFFFF00ull;   // lane * 16 from it: lanes 16.. carry, 0..15 do not
constexpr uint64_t kOut = 0x03000000;
constexpr uint32_t kRow = 0x3A4, kCascadeBytes = 48;
constexpr uint32_t kSentinel = 0xCDCDCDCDu;

uint8_t* g_mem = nullptr;
GuestContext g_ctx;

uint32_t* At(uint64_t addr) { return reinterpret_cast<uint32_t*>(g_mem + addr); }

namespace gcn {
uint32_t Smrd(uint32_t op, uint32_t sdst, uint32_t sbase, uint32_t dwords) { // immediate dword offset
    return 0xC0000000u | op << 22 | sdst << 15 | (sbase / 2) << 9 | 1u << 8 | dwords;
}
uint32_t SMovB32(uint32_t sdst, uint32_t ssrc0) { return 0xBE800300u | sdst << 16 | ssrc0; }
uint32_t Vop1(uint32_t op, uint32_t vdst, uint32_t src0) { return 0x7E000000u | vdst << 17 | op << 9 | src0; }
uint32_t Vop2(uint32_t op, uint32_t vdst, uint32_t src0, uint32_t vsrc1) { return op << 25 | vdst << 17 | vsrc1 << 9 | src0; }
void Mubuf(std::vector<uint32_t>& c, uint32_t op, bool offen, bool addr64, uint32_t vaddr, uint32_t vdata,
           uint32_t srsrc, uint32_t soffset = 0x80, uint32_t offset = 0) {
    c.push_back(0xE0000000u | op << 18 | uint32_t(addr64) << 15 | uint32_t(offen) << 12 | offset);
    c.push_back(soffset << 24 | (srsrc / 4) << 16 | vdata << 8 | vaddr);
}
constexpr uint32_t kWait = 0xBF8C0000u, kEnd = 0xBF810000u, kLiteral = 0xFF;
constexpr uint32_t kSLoadX2 = 1, kVMov = 1, kVMulU32U24 = 11, kVLshlrev = 26, kVAnd = 27, kVAddI32 = 37,
                   kVAddcU32 = 40, kLoadDwordx4 = 14, kStoreDwordx4 = 30;
constexpr uint32_t Inline(uint32_t n) { return 0x80 + n; } // integer inline constant 0..64

// The program with the header and OrbShdr footer the translator looks for
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

// The hair shader's load sequence, from the SRT pointer at s[ptr_sgpr..] (loaded from s[0:1] + 16)
// and the cascade index in v1: v[4:7] = the dwords at pointer + 0x3A4 + 48 * c, v[10:13] those 32
// bytes further (soffset s16 = 16, inst_offset 16).
void HairLoads(std::vector<uint32_t>& c, uint32_t ptr_sgpr) {
    c.push_back(Smrd(kSLoadX2, ptr_sgpr, 0, 4)); // s[ptr:ptr+1] = SRT pointer (byte 0x10)
    c.push_back(SMovB32(12, Inline(0)));         // the hair shader's V#: base 0, stride 4,
    c.push_back(SMovB32(13, kLiteral));          // num_records 0xFFFFFFFF
    c.push_back(0x00040000u);
    c.push_back(SMovB32(14, 0xC1));              // -1
    c.push_back(SMovB32(15, kLiteral));
    c.push_back(0x20024004u);
    c.push_back(SMovB32(16, Inline(16)));
    c.push_back(kWait);
    c.push_back(Vop2(kVMulU32U24, 1, Inline(kCascadeBytes), 1)); // v1 = 48 * c
    c.push_back(Vop2(kVAddI32, 1, kLiteral, 1));                  // v1 += 0x3A4
    c.push_back(kRow);
    c.push_back(Vop2(kVAddI32, 2, ptr_sgpr, 1));                  // v2 = ptr.lo + v1 (carry to vcc)
    c.push_back(Vop1(kVMov, 3, ptr_sgpr + 1));                    // v3 = ptr.hi
    c.push_back(Vop2(kVAddcU32, 3, Inline(0), 3));                // v3 += vcc
    Mubuf(c, kLoadDwordx4, false, true, 2, 4, 12);
    Mubuf(c, kLoadDwordx4, false, true, 2, 10, 12, 16, 16);
    c.push_back(kWait);
}
} // namespace gcn

// A triangle covering the target from the vertex id, exported as position and parameter 0
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
    return WithFooter(c, 0x5CA1AB1E0000A650ull);
}

// User data: s[0:1] SRT pointer, s2 cascade, s[4:7] V# of the output
std::vector<uint32_t> HairPs() {
    using namespace gcn;
    std::vector<uint32_t> c;
    c.push_back(Vop1(kVMov, 1, 2)); // v1 = s2
    HairLoads(c, 20);
    Mubuf(c, kStoreDwordx4, false, false, 0, 4, 4);
    Mubuf(c, kStoreDwordx4, false, false, 0, 10, 4, 0x80, 16);
    c.push_back(0xF800180Fu); // exp mrt0 v4..v7 done vm
    c.push_back(4u | 5u << 8 | 6u << 16 | 7u << 24);
    c.push_back(kEnd);
    return WithFooter(c, 0x5CA1AB1E0000A660ull);
}

uint32_t Tag(uint64_t addr) { return 0xA0000000u | uint32_t(addr & 0x0FFFFFFF); }

void PutRows() {
    // every dword from kPtr to kPtr + 0x500 holds a tag of its address (covers kPtr2 + 64 * 16)
    for (uint64_t a = kPtr; a < kPtr + 0x500; a += 4) *At(a) = Tag(a);
    *At(kSrt + 0x10) = uint32_t(kPtr);
    *At(kSrt + 0x14) = uint32_t(kPtr >> 32);
    *At(kSrt + 0x18) = uint32_t(kPtr2);
    *At(kSrt + 0x1C) = uint32_t(kPtr2 >> 32);
    ps4draw::NotifyGuestWrite(kSrt, 0x1000, false, 0);
    ps4draw::NotifyGuestWrite(kPtr, 0x1000, false, 0);
}

void PutVsharp(uint32_t* v, uint64_t base, uint32_t bytes) {
    v[0] = uint32_t(base);
    v[1] = uint32_t(base >> 32) & 0xFF; // stride 0: num_records in bytes
    v[2] = bytes;
    v[3] = 4 | (5 << 3) | (6 << 6) | (7 << 9) | (4 << 12) | (4 << 15); // xyzw, uint, 32
}

void TestCompute() {
    using namespace gcn;
    std::vector<uint32_t> c;
    c.push_back(Vop2(kVAnd, 1, Inline(3), 0)); // v1 = c = thread & 3
    HairLoads(c, 20);
    c.push_back(Vop2(kVLshlrev, 8, Inline(4), 0)); // v8 = thread * 16
    Mubuf(c, kStoreDwordx4, true, false, 8, 4, 4);
    Mubuf(c, kStoreDwordx4, true, false, 8, 10, 4, 0x80, 1024);
    c.push_back(kEnd);
    const std::vector<uint32_t> code = WithFooter(c, 0x5CA1AB1E0000A640ull);
    memcpy(g_mem + kCode, code.data(), code.size() * 4);
    ps4draw::NotifyGuestWrite(kCode, 0x10000, false, 0);
    for (uint32_t k = 0; k < 2048 / 4; ++k) At(kOut)[k] = kSentinel;
    ps4draw::NotifyGuestWrite(kOut, 0x1000, false, 0);

    std::vector<uint32_t> regs(0x10000, 0);
    regs[0x2E07] = 64;
    regs[0x2E08] = regs[0x2E09] = 1;
    regs[0x2E0C] = uint32_t(kCode >> 8);
    regs[0x2E12] = 3 | (3 << 6); // 16 VGPRs, 32 SGPRs
    regs[0x2E13] = 8 << 1;       // 8 user SGPRs: s[0:1] SRT, s[4:7] output V#
    regs[0x2E40] = uint32_t(kSrt);
    regs[0x2E41] = uint32_t(kSrt >> 32);
    PutVsharp(&regs[0x2E44], kOut, 2048);
    const uint64_t skipped0 = ps4draw::SkippedCount();
    ps4draw::Dispatch(&g_ctx, regs.data(), 1, 1, 1, 0, "gfx", ps4draw::kQueueGfx);
    ps4draw::Flush(true);
    CHECK(ps4draw::SkippedCount() == skipped0, "compute: the dispatch was skipped");
    int bad = 0;
    for (uint32_t t = 0; t < 64 && bad < 4; ++t) {
        const uint64_t row = kPtr + kRow + kCascadeBytes * (t & 3);
        for (uint32_t k = 0; k < 4; ++k) {
            const uint32_t a = At(kOut + 16 * t)[k], b = At(kOut + 1024 + 16 * t)[k];
            if (a != Tag(row + 4 * k) || b != Tag(row + 32 + 4 * k)) {
                CHECK(false, "compute lane %u dword %u: %08x %08x, want %08x %08x (address 0x%llx)", t, k, a, b,
                      Tag(row + 4 * k), Tag(row + 32 + 4 * k), (unsigned long long)(row + 4 * k));
                ++bad;
                break;
            }
        }
    }
}

void TestComputeLaneHighAndOffen() {
    using namespace gcn;
    std::vector<uint32_t> c;
    c.push_back(Smrd(kSLoadX2, 20, 0, 6)); // s[20:21] = kPtr2 (byte 0x18)
    c.push_back(SMovB32(12, Inline(0)));
    c.push_back(SMovB32(13, kLiteral));
    c.push_back(0x00040000u);
    c.push_back(SMovB32(14, 0xC1));
    c.push_back(SMovB32(15, kLiteral));
    c.push_back(0x20024004u);
    c.push_back(kWait);
    c.push_back(Vop2(kVLshlrev, 1, Inline(4), 0)); // v1 = lane * 16
    c.push_back(Vop2(kVAddI32, 2, 20, 1));         // v2 = ptr.lo + v1 (carry from lane 16 on)
    c.push_back(Vop1(kVMov, 3, 21));
    c.push_back(Vop2(kVAddcU32, 3, Inline(0), 3)); // v3 = ptr.hi + carry: 0 or 1 per lane
    Mubuf(c, kLoadDwordx4, false, true, 2, 4, 12);
    Mubuf(c, kLoadDwordx4, true, true, 2, 10, 12); // offen with addr64: ignored
    c.push_back(kWait);
    c.push_back(Vop2(kVLshlrev, 8, Inline(4), 0));
    Mubuf(c, kStoreDwordx4, true, false, 8, 4, 4);
    Mubuf(c, kStoreDwordx4, true, false, 8, 10, 4, 0x80, 1024);
    c.push_back(kEnd);
    const uint64_t code_at = kCode + 0x30000, out = kOut + 0x2000;
    const std::vector<uint32_t> code = WithFooter(c, 0x5CA1AB1E0000A670ull);
    memcpy(g_mem + code_at, code.data(), code.size() * 4);
    ps4draw::NotifyGuestWrite(code_at, 0x10000, false, 0);
    for (uint32_t k = 0; k < 2048 / 4; ++k) At(out)[k] = kSentinel;
    ps4draw::NotifyGuestWrite(out, 0x1000, false, 0);
    std::vector<uint32_t> regs(0x10000, 0);
    regs[0x2E07] = 64;
    regs[0x2E08] = regs[0x2E09] = 1;
    regs[0x2E0C] = uint32_t(code_at >> 8);
    regs[0x2E12] = 3 | (3 << 6);
    regs[0x2E13] = 8 << 1;
    regs[0x2E40] = uint32_t(kSrt);
    regs[0x2E41] = uint32_t(kSrt >> 32);
    PutVsharp(&regs[0x2E44], out, 2048);
    const uint64_t skipped0 = ps4draw::SkippedCount();
    ps4draw::Dispatch(&g_ctx, regs.data(), 1, 1, 1, 0, "gfx", ps4draw::kQueueGfx);
    ps4draw::Flush(true);
    CHECK(ps4draw::SkippedCount() == skipped0, "lane high dword: the dispatch was skipped");
    int bad = 0;
    for (uint32_t t = 0; t < 64 && bad < 4; ++t) {
        const uint64_t a0 = kPtr2 + 16 * t;
        for (uint32_t k = 0; k < 4; ++k) {
            const uint32_t a = At(out + 16 * t)[k], b = At(out + 1024 + 16 * t)[k];
            if (a != Tag(a0 + 4 * k) || b != Tag(a0 + 4 * k)) {
                CHECK(false, "lane %u (address 0x%llx) dword %u: %08x, with offen %08x, want %08x", t,
                      (unsigned long long)(a0 + 4 * k), k, a, b, Tag(a0 + 4 * k));
                ++bad;
                break;
            }
        }
    }
}

uint32_t Fbits(float f) {
    uint32_t u;
    memcpy(&u, &f, 4);
    return u;
}

constexpr uint64_t kVs = kCode + 0x10000, kPs = kCode + 0x20000, kRt = 0x04000000, kDrawOut = kOut + 0x1000;

// A triangle-list draw of 3 vertices into a 64x64 RGBA8 linear target at kRt
std::vector<uint32_t> DrawRegs(uint32_t cascade) {
    constexpr uint32_t kW = 64, kH = 64;
    std::vector<uint32_t> regs(0x10000, 0);
    ps4draw::SetRegDefaults(regs.data());
    auto stage = [&](uint32_t pgm, uint64_t code, uint32_t user) {
        regs[pgm] = uint32_t(code >> 8);
        regs[pgm + 1] = uint32_t(code >> 40);
        regs[pgm + 2] = 3 | (3 << 6); // RSRC1: 16 VGPRs, 32 SGPRs
        regs[pgm + 3] = 8 << 1;       // RSRC2: 8 user SGPRs
        regs[user] = uint32_t(kSrt);
        regs[user + 1] = uint32_t(kSrt >> 32);
        regs[user + 2] = cascade;
        PutVsharp(&regs[user + 4], kDrawOut, 32);
    };
    stage(0x2C48, kVs, 0x2C4C); // SPI_SHADER_PGM_LO_VS, SPI_SHADER_USER_DATA_VS_0
    stage(0x2C08, kPs, 0x2C0C); // SPI_SHADER_PGM_LO_PS, SPI_SHADER_USER_DATA_PS_0
    regs[0xA1B1] = 0;          // SPI_VS_OUT_CONFIG
    regs[0xA1B3] = 2;          // SPI_PS_INPUT_ENA: PERSP_CENTER
    regs[0xA1B4] = 2;          // SPI_PS_INPUT_ADDR
    regs[0xA1B6] = 0;          // SPI_PS_IN_CONTROL: no interpolants
    regs[0xA1C3] = 4;          // SPI_SHADER_POS_FORMAT: 4 components
    regs[0xA1C4] = 0;          // SPI_SHADER_Z_FORMAT
    regs[0xA1C5] = 9;          // SPI_SHADER_COL_FORMAT: MRT0 32_ABGR
    regs[0xA2D5] = 0;          // VGT_SHADER_STAGES_EN: VS + PS
    regs[0xA318] = uint32_t(kRt >> 8); // CB_COLOR0_BASE
    regs[0xA319] = kW / 8 - 1;         // CB_COLOR0_PITCH
    regs[0xA31A] = kW * kH / 64 - 1;   // CB_COLOR0_SLICE
    regs[0xA31C] = 0xA << 2;           // CB_COLOR0_INFO: 8_8_8_8 unorm
    regs[0xA31D] = 8;                  // CB_COLOR0_ATTRIB: linear aligned
    regs[0xA08E] = 0xF;                // CB_TARGET_MASK
    regs[0xA08F] = 0xF;                // CB_SHADER_MASK
    regs[0xA202] = 0x00CC0010;         // CB_COLOR_CONTROL: normal, ROP3 copy
    regs[0xA00D] = kW | (kH << 16);    // PA_SC_SCREEN_SCISSOR_BR
    regs[0xA081] = 0x80000000;         // PA_SC_WINDOW_SCISSOR_TL
    regs[0xA082] = kW | (kH << 16);
    regs[0xA090] = 0x80000000;         // PA_SC_GENERIC_SCISSOR_TL
    regs[0xA091] = kW | (kH << 16);
    regs[0xA10F] = Fbits(kW / 2.f);    // PA_CL_VPORT_*
    regs[0xA110] = Fbits(kW / 2.f);
    regs[0xA111] = Fbits(kH / 2.f);
    regs[0xA112] = Fbits(kH / 2.f);
    regs[0xA113] = Fbits(0.5f);
    regs[0xA114] = Fbits(0.5f);
    regs[0xA206] = 0x43F;              // PA_CL_VTE_CNTL
    regs[0xC242] = 4;                  // VGT_PRIMITIVE_TYPE: triangle list
    return regs;
}

// Draws once and returns whether the PS stored the rows of `cascade`
bool DrawOnce(uint32_t cascade, const char* what, bool report) {
    for (uint32_t k = 0; k < 8; ++k) At(kDrawOut)[k] = kSentinel;
    ps4draw::NotifyGuestWrite(kDrawOut, 0x1000, false, 0);
    ps4draw::NotifyGuestWrite(kRt, 0x10000, false, 0);
    const std::vector<uint32_t> regs = DrawRegs(cascade);
    ps4draw::DrawArgs args;
    args.count = 3;
    args.name = "addr64-draw";
    const uint64_t skipped0 = ps4draw::SkippedCount();
    ps4draw::Draw(&g_ctx, regs.data(), args);
    ps4draw::Flush(true);
    CHECK(ps4draw::SkippedCount() == skipped0, "%s: the draw was skipped", what);
    const uint64_t row = kPtr + kRow + kCascadeBytes * cascade;
    for (uint32_t k = 0; k < 4; ++k) {
        const uint32_t a = At(kDrawOut)[k], b = At(kDrawOut)[4 + k];
        if (a != Tag(row + 4 * k) || b != Tag(row + 32 + 4 * k)) {
            if (report)
                CHECK(false, "%s dword %u: %08x %08x, want %08x %08x", what, k, a, b, Tag(row + 4 * k),
                      Tag(row + 32 + 4 * k));
            return false;
        }
    }
    return true;
}

void TestDraw() {
    const std::vector<uint32_t> vs = CoverVs(), ps = HairPs();
    memcpy(g_mem + kVs, vs.data(), vs.size() * 4);
    memcpy(g_mem + kPs, ps.data(), ps.size() * 4);
    ps4draw::NotifyGuestWrite(kCode, 0x30000, false, 0);
    // the rows' 64 MiB page (at 4 GiB) is not mapped yet: the first draw reads 0 there and the
    // renderer maps the page when the next draw binds the slot
    const ps4draw::GuestMemoryStats s0 = ps4draw::GetGuestMemoryStats();
    const bool first = DrawOnce(1, "draw 1", false);
    CHECK(!first, "draw 1 read the rows of a page that was not mapped");
    CHECK(DrawOnce(2, "draw 2", true), "draw 2 did not read the rows");
    const ps4draw::GuestMemoryStats s2 = ps4draw::GetGuestMemoryStats();
    CHECK(s2.draw_mapped == s0.draw_mapped + 1, "%llu pages mapped for draws, want 1",
          (unsigned long long)(s2.draw_mapped - s0.draw_mapped));
    CHECK(DrawOnce(3, "draw 3", true), "draw 3 did not read the rows");
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
            fprintf(stderr, "gnm_addr64_test: FAIL no guest memory\n");
            return 1;
        }
        g_mem = (uint8_t*)m;
        memset(&g_ctx, 0, sizeof(g_ctx));
        g_ctx.mem_base = g_mem;
        g_ctx.mem_size = kMemSize;
        if (!ps4draw::Init(&g_ctx)) {
            fprintf(stderr, "gnm_addr64_test: FAIL the renderer did not start\n");
            return 1;
        }
        PutRows();
        TestDraw(); // first: the compute test's dispatch maps the rows' page
        TestCompute();
        TestComputeLaneHighAndOffen();
        if (g_fail) {
            fprintf(stderr, "gnm_addr64_test: %d failure(s)\n", g_fail);
            return 1;
        }
        printf("gnm_addr64_test: PASS\n");
        return 0;
    }
}
