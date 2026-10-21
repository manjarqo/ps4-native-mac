// Buffer accesses through V#s a compute shader loads at run time, run through the real renderer
// (ps4draw::Dispatch: translation, the guest memory probe, the page table, the dispatch).
// The shader is Uncharted 4's 152-byte GPU copy shader (data/u4_cs_copy.*, capture r13c pass 21):
// for each entry of a copy table it loads a source and a destination V# with s_load_dwordx4 at an
// offset computed in its loop, then buffer_load_format_x / buffer_store_format_x through them.
// The translator used to drop both (an empty if {} in the MSL), so the destinations were never
// written (the title screen's per-draw normal matrices stayed zero).
//  - two table entries, in other 64 MiB guest pages than the table: each destination receives
//    exactly its source's dwords; a source shorter than the count reads 0 past its num_records
//    (GCN range check); the dwords after the copy keep their contents;
//  - the same shader with the destination's "thread < num_records" compare removed (so the
//    threads past it do store): those stores are discarded by the range check;
//  - a destination V# with an 8_8_8_8 unorm format (not implemented): the dispatch is skipped and
//    nothing is written;
//  - a zeroed destination V# in the table: a no-op for that entry, the other entries still copy.
// Hand-assembled shaders (V#s read from a table at an offset the shader computes):
//  - buffer_load_dword / buffer_store_dword offen through stride-0 V#s (byte num_records), the
//    source in guest page 0 with bits 40..47 of its V# base set (ignored);
//  - buffer_load_format_xyzw with dst_sel W Z 1 X, stored with buffer_store_dwordx4;
//  - a chained probe: a V# loaded through a run-time V# from a page not mapped yet.
//
// usage: gnm_guest_memory_test <dir with the fixtures>
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>

#include <array>
#include <fstream>
#include <sstream>
#include <string>
#include <vector>

#include "gcn_recompiler.h"
#include "ps4_gnm_draw.h"

namespace {

int g_fail = 0;
#define CHECK(c, ...)                                                                    \
    do {                                                                                 \
        if (!(c)) {                                                                      \
            fprintf(stderr, "gnm_guest_memory_test: FAIL %s:%d: ", __FILE__, __LINE__); \
            fprintf(stderr, __VA_ARGS__);                                                \
            fprintf(stderr, "\n");                                                       \
            g_fail++;                                                                    \
        }                                                                                \
    } while (0)

constexpr uint64_t kMemSize = 1ull << 32;
constexpr uint64_t kCode = 0x01000000;  // guest page 0 (64 MiB pages)
constexpr uint64_t kTable = 0x02000000; // page 0
constexpr uint64_t kSrc = 0x08000000;   // page 2
constexpr uint64_t kDst = 0x14000000;   // page 5
constexpr uint32_t kSentinel = 0xCDCDCDCDu;

uint8_t* g_mem = nullptr;
GuestContext g_ctx;
std::vector<uint8_t> g_code;
std::vector<uint32_t> g_regs;

uint32_t* At(uint64_t addr) { return reinterpret_cast<uint32_t*>(g_mem + addr); }

// V# of a 32-bit uint buffer, dst_sel X000 (dword 3 as the game's: 0x20024004 / 0x18024004)
void PutVsharp(uint32_t* v, uint64_t base, uint32_t stride, uint32_t num_records, uint32_t dword3) {
    v[0] = uint32_t(base);
    v[1] = uint32_t(base >> 32) | (stride << 16);
    v[2] = num_records;
    v[3] = dword3;
}

struct Entry {
    uint64_t src, dst;
    uint32_t src_records, dst_records, count;
    uint32_t dst_dword3 = 0x18024004u;
    bool null_dst = false; // the destination V# is all zero (num_records 0)
};

bool Load(const std::string& dir) {
    std::ifstream bin(dir + "/u4_cs_copy.bin", std::ios::binary);
    g_code.assign(std::istreambuf_iterator<char>(bin), std::istreambuf_iterator<char>());
    if (g_code.size() != 248) return false;
    g_regs.assign(0x10000, 0);
    std::ifstream txt(dir + "/u4_cs_copy.txt");
    std::string line;
    while (std::getline(txt, line)) {
        if (line.empty() || line[0] == '#') continue;
        std::istringstream ss(line);
        std::string a, b;
        ss >> a >> b;
        g_regs[std::strtoul(a.c_str(), nullptr, 16)] = std::strtoul(b.c_str(), nullptr, 16);
    }
    g_regs[0x2E0C] = uint32_t(kCode >> 8); // COMPUTE_PGM_LO
    g_regs[0x2E0D] = 0;
    g_regs[0x2E40] = uint32_t(kTable); // COMPUTE_USER_DATA_0/1: the copy table
    g_regs[0x2E41] = 0;
    return g_regs[0x2E13] == 0x84 && g_regs[0x2E07] == 64;
}

// Writes the table and the buffers, runs one dispatch of 64 threads. Sources hold
// 0xA5000000 | (entry << 16) | dword; destinations hold kSentinel.
void Run(const std::vector<Entry>& entries, bool remove_dst_compare) {
    std::vector<uint8_t> code = g_code;
    if (remove_dst_compare) {
        // v_cmpx_gt_u32 s[2:3], s14, v0 (dst num_records > thread) at byte 0x74 -> two s_nop
        uint32_t w[2];
        memcpy(w, &code[0x74], 8);
        CHECK(w[0] == 0xD1A80002u && w[1] == 0x0002000Eu, "fixture changed: %08x %08x", w[0], w[1]);
        w[0] = w[1] = 0xBF800000u;
        memcpy(&code[0x74], w, 8);
        // another program: another shader hash in its OrbShdr footer (byte 216; hash at +16), or
        // the renderer would reuse the translation of the unpatched one
        CHECK(memcmp(&code[216], "OrbShdr", 7) == 0, "fixture footer moved");
        code[216 + 16] ^= 0x5A;
    }
    memcpy(g_mem + kCode, code.data(), code.size());
    memset(g_mem + kTable, 0, 512);
    At(kTable)[72] = uint32_t(entries.size());
    for (size_t i = 0; i < entries.size(); ++i) {
        const Entry& e = entries[i];
        PutVsharp(At(kTable + 16 * i), e.src, 4, e.src_records, 0x20024004u);
        if (e.null_dst) memset(At(kTable + 128 + 16 * i), 0, 16);
        else PutVsharp(At(kTable + 128 + 16 * i), e.dst, 4, e.dst_records, e.dst_dword3);
        At(kTable + 256)[i] = e.count;
        for (uint32_t k = 0; k < 64; ++k) {
            At(e.src)[k] = 0xA5000000u | uint32_t(i << 16) | k;
            if (!e.null_dst) At(e.dst)[k] = kSentinel;
        }
    }
    // the CPU wrote guest memory the renderer may have cached
    ps4draw::NotifyGuestWrite(kTable, 4096, false, 0);
    ps4draw::Dispatch(&g_ctx, g_regs.data(), 1, 1, 1, 0, "gfx");
    ps4draw::Flush(true);
}

void TestCopy() {
    const Entry e0{kSrc, kDst, 24, 24, 24};
    // the source is shorter than the count: dwords 12..15 read 0
    const Entry e1{kSrc + 0x100000, kDst + 0x100000, 12, 16, 16};
    const uint64_t skipped0 = ps4draw::SkippedCount();
    Run({e0, e1}, false);
    CHECK(ps4draw::SkippedCount() == skipped0, "the dispatch was skipped");
    for (uint32_t k = 0; k < 64; ++k) {
        const uint32_t want = k < 24 ? (0xA5000000u | k) : kSentinel;
        CHECK(At(e0.dst)[k] == want, "entry 0 dst[%u] = %08x, want %08x", k, At(e0.dst)[k], want);
    }
    for (uint32_t k = 0; k < 64; ++k) {
        const uint32_t want = k < 12 ? (0xA5010000u | k) : k < 16 ? 0u : kSentinel;
        CHECK(At(e1.dst)[k] == want, "entry 1 dst[%u] = %08x, want %08x", k, At(e1.dst)[k], want);
    }
}

void TestStoreRangeCheck() {
    // 32 threads store; the destination has 20 records
    const Entry e{kSrc + 0x200000, kDst + 0x200000, 64, 20, 32};
    const uint64_t skipped0 = ps4draw::SkippedCount();
    Run({e}, true);
    CHECK(ps4draw::SkippedCount() == skipped0, "the dispatch was skipped");
    for (uint32_t k = 0; k < 64; ++k) {
        const uint32_t want = k < 20 ? (0xA5000000u | k) : kSentinel;
        CHECK(At(e.dst)[k] == want, "dst[%u] = %08x, want %08x", k, At(e.dst)[k], want);
    }
}

void TestUnsupportedFormat() {
    // destination 8_8_8_8 unorm (data format 10, number format 0), dst_sel XYZW
    Entry e{kSrc + 0x300000, kDst + 0x300000, 24, 24, 24};
    e.dst_dword3 = 4 | (5 << 3) | (6 << 6) | (7 << 9) | (0 << 12) | (10 << 15);
    const uint64_t skipped0 = ps4draw::SkippedCount();
    Run({e}, false);
    CHECK(ps4draw::SkippedCount() == skipped0 + 1, "the dispatch was not skipped");
    for (uint32_t k = 0; k < 64; ++k) CHECK(At(e.dst)[k] == kSentinel, "dst[%u] = %08x written", k, At(e.dst)[k]);
}

void TestNullDestination() {
    // a table entry with a zeroed destination V# between two good ones: that entry stores
    // nothing (num_records 0: a no-op on GCN), the others still copy. Without the shader's own
    // "thread < dst num_records" compare, so the stores through the zeroed V# are issued.
    const Entry e0{kSrc + 0x400000, kDst + 0x400000, 24, 24, 24};
    Entry e1{kSrc + 0x500000, 0, 24, 0, 24};
    e1.null_dst = true;
    const Entry e2{kSrc + 0x600000, kDst + 0x600000, 24, 24, 24};
    const uint64_t skipped0 = ps4draw::SkippedCount();
    Run({e0, e1, e2}, true);
    CHECK(ps4draw::SkippedCount() == skipped0, "the dispatch was skipped");
    for (uint32_t k = 0; k < 64; ++k) {
        CHECK(At(e0.dst)[k] == (k < 24 ? (0xA5000000u | k) : kSentinel), "entry 0 dst[%u] = %08x", k, At(e0.dst)[k]);
        CHECK(At(e2.dst)[k] == (k < 24 ? (0xA5020000u | k) : kSentinel), "entry 2 dst[%u] = %08x", k, At(e2.dst)[k]);
    }
}

// ---- Hand-assembled compute shaders (64 threads, s[0:1] = a table of V#s read at an offset the
// shader computes from the workgroup id s2, which the SRT walker does not know) ----
namespace gcn {
uint32_t Smrd(uint32_t op, uint32_t sdst, uint32_t sbase, uint32_t soff) { // offset in an SGPR
    return 0xC0000000u | op << 22 | sdst << 15 | (sbase / 2) << 9 | soff;
}
uint32_t SAddU32(uint32_t sdst, uint32_t ssrc0, uint32_t ssrc1) { return 0x80000000u | sdst << 16 | ssrc1 << 8 | ssrc0; }
uint32_t Vop1(uint32_t op, uint32_t vdst, uint32_t src0) { return 0x7E000000u | vdst << 17 | op << 9 | src0; }
uint32_t VLshlrev(uint32_t vdst, uint32_t src0, uint32_t vsrc1) { return 26u << 25 | vdst << 17 | vsrc1 << 9 | src0; }
void Mubuf(std::vector<uint32_t>& c, uint32_t op, bool idxen, bool offen, uint32_t vaddr, uint32_t vdata, uint32_t srsrc) {
    c.push_back(0xE0000000u | op << 18 | uint32_t(idxen) << 13 | uint32_t(offen) << 12);
    c.push_back(0x80u << 24 | (srsrc / 4) << 16 | vdata << 8 | vaddr); // soffset 0
}
constexpr uint32_t V(uint32_t n) { return 0x100 + n; }
constexpr uint32_t kWait = 0xBF8C0000u, kEnd = 0xBF810000u;
constexpr uint32_t kMov = 1, kReadFirstLane = 2;
constexpr uint32_t kLoadFmtX = 0, kLoadFmtXyzw = 3, kStoreFmtX = 4, kLoadDword = 12, kLoadDwordx4 = 14,
                   kStoreDword = 28, kStoreDwordx4 = 30;
// s8 = s2 + 0 (workgroup 0); s[4:7] = V# at table + 0, s[12:15] = V# at table + 16
void LoadTwoVsharps(std::vector<uint32_t>& c) {
    c.push_back(SAddU32(8, 2, 0x80));
    c.push_back(Smrd(2, 4, 0, 8));
    c.push_back(SAddU32(9, 8, 0x90)); // + 16
    c.push_back(Smrd(2, 12, 0, 9));
    c.push_back(kWait);
}
// the program with the header and OrbShdr footer the translator looks for
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

constexpr uint64_t kCode2 = 0x01100000, kTable2 = 0x02100000;

// Runs a hand-assembled program over table kTable2 (V#s at bytes 0, 16, ...).
void RunProgram(const std::vector<uint32_t>& body, uint64_t hash, const std::vector<std::array<uint32_t, 4>>& vsharps) {
    const std::vector<uint32_t> code = gcn::WithFooter(body, hash);
    memcpy(g_mem + kCode2, code.data(), code.size() * 4);
    memset(g_mem + kTable2, 0, 256);
    for (size_t i = 0; i < vsharps.size(); ++i) memcpy(At(kTable2 + 16 * i), vsharps[i].data(), 16);
    std::vector<uint32_t> regs = g_regs;
    regs[0x2E0C] = uint32_t(kCode2 >> 8);
    regs[0x2E12] = 1 | (2 << 6); // 8 VGPRs, 24 SGPRs
    regs[0x2E13] = 2 << 1 | 1 << 7; // 2 user SGPRs, s2 = workgroup id x
    regs[0x2E40] = uint32_t(kTable2);
    ps4draw::NotifyGuestWrite(kTable2, 4096, false, 0);
    ps4draw::Dispatch(&g_ctx, regs.data(), 1, 1, 1, 0, "gfx");
    ps4draw::Flush(true);
}

std::array<uint32_t, 4> Vsharp(uint64_t base, uint32_t stride, uint32_t num_records, uint32_t dword3) {
    std::array<uint32_t, 4> v;
    PutVsharp(v.data(), base, stride, num_records, dword3);
    return v;
}

void TestDwordOffenStride0() {
    // buffer_load_dword / buffer_store_dword offen (byte offset thread * 4) through stride-0 V#s
    // (num_records in bytes): 40 source bytes, 120 destination bytes. The source is in guest page 0.
    using namespace gcn;
    std::vector<uint32_t> c;
    LoadTwoVsharps(c);
    c.push_back(VLshlrev(2, 0x82, 0)); // v2 = v0 << 2
    Mubuf(c, kLoadDword, false, true, 2, 1, 4);
    c.push_back(kWait);
    Mubuf(c, kStoreDword, false, true, 2, 1, 12);
    c.push_back(kEnd);
    const uint64_t src = 0x03000000, dst = kDst + 0x700000;
    for (uint32_t k = 0; k < 64; ++k) {
        At(src)[k] = 0xC0000000u | k;
        At(dst)[k] = kSentinel;
    }
    const uint64_t skipped0 = ps4draw::SkippedCount();
    // bits 40..47 of the source V# base hold a value the GPU ignores (Uncharted 4's async compute
    // V#s do)
    std::array<uint32_t, 4> src_vsharp = Vsharp(src, 0, 40, 0x20024004u);
    src_vsharp[1] |= 0xAB00u;
    RunProgram(c, 0x5CA1AB1E0000D001ull, {src_vsharp, Vsharp(dst, 0, 120, 0x18024004u)});
    CHECK(ps4draw::SkippedCount() == skipped0, "the dispatch was skipped");
    for (uint32_t k = 0; k < 64; ++k) {
        const uint32_t want = k < 10 ? (0xC0000000u | k) : k < 30 ? 0u : kSentinel;
        CHECK(At(dst)[k] == want, "dword dst[%u] = %08x, want %08x", k, At(dst)[k], want);
    }
}

void TestDstSel() {
    // buffer_load_format_xyzw (idxen) through a 32_32_32_32 uint V# with dst_sel W Z 1 X, stored
    // with buffer_store_dwordx4 offen (thread * 16) through a stride-0 V#: 8 records
    using namespace gcn;
    std::vector<uint32_t> c;
    LoadTwoVsharps(c);
    Mubuf(c, kLoadFmtXyzw, true, false, 0, 4, 4);
    c.push_back(VLshlrev(2, 0x84, 0)); // v2 = v0 << 4
    c.push_back(kWait);
    Mubuf(c, kStoreDwordx4, false, true, 2, 4, 12);
    c.push_back(kEnd);
    const uint64_t src = kSrc + 0x800000, dst = kDst + 0x800000;
    for (uint32_t k = 0; k < 256; ++k) {
        At(src)[k] = 0xB0000000u | (k / 4) << 4 | (k % 4);
        At(dst)[k] = kSentinel;
    }
    const uint32_t sel = 7 | (6 << 3) | (1 << 6) | (4 << 9);
    const uint32_t dw3 = sel | (4u << 12) | (14u << 15); // uint, 32_32_32_32
    const uint64_t skipped0 = ps4draw::SkippedCount();
    RunProgram(c, 0x5CA1AB1E0000D002ull, {Vsharp(src, 16, 8, dw3), Vsharp(dst, 0, 8 * 16, 0x18024004u)});
    CHECK(ps4draw::SkippedCount() == skipped0, "the dispatch was skipped");
    for (uint32_t t = 0; t < 16; ++t) {
        const uint32_t r = 0xB0000000u | t << 4;
        const uint32_t want[4] = {r | 3, r | 2, 1u, r | 0};
        for (uint32_t c4 = 0; c4 < 4; ++c4) {
            const uint32_t w = t < 8 ? want[c4] : kSentinel;
            CHECK(At(dst)[t * 4 + c4] == w, "dst_sel dst[%u].%u = %08x, want %08x", t, c4, At(dst)[t * 4 + c4], w);
        }
    }
}

void TestChainedProbe() {
    // V# A (table) -> buffer_load_dwordx4 of V# B from guest page 7 -> buffer_load_format_x
    // through B from page 9 -> buffer_store_format_x through V# C (table) to page 11. The
    // first probe reads B as 0 (page 7 unmapped): it must map page 7 and probe again (finding
    // page 9), not judge B's format from that 0.
    using namespace gcn;
    std::vector<uint32_t> c;
    LoadTwoVsharps(c);
    c.push_back(Vop1(kMov, 1, 0x80)); // v1 = 0
    Mubuf(c, kLoadDwordx4, false, true, 1, 4, 4);
    c.push_back(kWait);
    for (uint32_t k = 0; k < 4; ++k) c.push_back(Vop1(kReadFirstLane, 16 + k, V(4 + k)));
    Mubuf(c, kLoadFmtX, true, false, 0, 2, 16);
    c.push_back(kWait);
    Mubuf(c, kStoreFmtX, true, false, 0, 2, 12);
    c.push_back(kEnd);
    const uint64_t a = 0x1C000000, b = 0x24000000, dst = 0x2C000000;
    PutVsharp(At(a), b, 4, 64, 0x20024004u); // V# B, stored where V# A points
    for (uint32_t k = 0; k < 64; ++k) {
        At(b)[k] = 0xD0000000u | k;
        At(dst)[k] = kSentinel;
    }
    const uint64_t skipped0 = ps4draw::SkippedCount();
    RunProgram(c, 0x5CA1AB1E0000D003ull, {Vsharp(a, 0, 16, 0x20024004u), Vsharp(dst, 4, 48, 0x18024004u)});
    CHECK(ps4draw::SkippedCount() == skipped0, "the dispatch was skipped");
    for (uint32_t k = 0; k < 64; ++k) {
        const uint32_t want = k < 48 ? (0xD0000000u | k) : kSentinel;
        CHECK(At(dst)[k] == want, "chained dst[%u] = %08x, want %08x", k, At(dst)[k], want);
    }
}

} // namespace

int main(int argc, char** argv) {
    @autoreleasepool {
        if (argc < 2) {
            fprintf(stderr, "usage: gnm_guest_memory_test <fixture dir>\n");
            return 2;
        }
        if (!Load(argv[1])) {
            fprintf(stderr, "gnm_guest_memory_test: FAIL cannot read %s/u4_cs_copy.*\n", argv[1]);
            return 1;
        }
        setenv("PS4_GNM_SYNC_ENCODE", "1", 1);
        setenv("PS4_GNM_SYNC_COMPILE", "1", 1);
        setenv("PS4_GNM_NO_SHADER_CACHE", "1", 1);
        setenv("PS4_GNM_NO_PSO_ARCHIVE", "1", 1);
        setenv("PS4_GNM_NO_LIB_STORE", "1", 1);
        setenv("PS4_GNM_MEM_LOG", "0", 1);
        void* m = mmap(nullptr, kMemSize, PROT_READ | PROT_WRITE, MAP_ANON | MAP_PRIVATE | MAP_NORESERVE, -1, 0);
        if (m == MAP_FAILED) {
            fprintf(stderr, "gnm_guest_memory_test: FAIL no guest memory\n");
            return 1;
        }
        g_mem = (uint8_t*)m;
        memset(&g_ctx, 0, sizeof(g_ctx));
        g_ctx.mem_base = g_mem;
        g_ctx.mem_size = kMemSize;
        if (!ps4draw::Init(&g_ctx)) {
            fprintf(stderr, "gnm_guest_memory_test: FAIL the renderer did not start\n");
            return 1;
        }
        TestCopy();
        TestStoreRangeCheck();
        TestUnsupportedFormat();
        TestNullDestination();
        TestDwordOffenStride0();
        TestDstSel();
        TestChainedProbe();
        if (g_fail) {
            fprintf(stderr, "gnm_guest_memory_test: %d failure(s)\n", g_fail);
            return 1;
        }
        printf("gnm_guest_memory_test: PASS\n");
        return 0;
    }
}
