// Buffer accesses through V#s a compute shader loads at run time, run through the real renderer
// (ps4draw::Dispatch: translation, the guest memory probe, the page table, the dispatch).
// The shader is Uncharted 4's 152-byte GPU copy shader (u4_cs_copy.*, capture r13c pass 21):
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
// The fast path (a shader whose written pages are known: probe, gate and pass encoded without a
// CPU wait):
//  - the copy again: no wait while it is encoded, the same result as the sync path;
//  - the copy with a source in a page not mapped yet: the gate refuses, the dispatch is re-run,
//    the same result;
//  - a shader that increments a buffer, its second dispatch with a source in a new page: the
//    refused pass has no effect (the buffer is incremented once);
//  - the copy writing the resource table of a later plain shader: after a barrier the CP waits
//    for the copy before it reads the table; without one it does not wait; the same on the
//    compute queue (its own barriers order it, the graphics ring's do not);
//  - a shader never dispatched before, after such a copy writes its table: its first
//    translation reads the table the copy wrote;
//  - the same with the table in a page the copy's prediction does not have (its probe finds it,
//    the dispatch is re-run): the CP still waits and reads what the copy wrote;
//  - a pass writing outside what its probe could know, after its gate passed (it stores the V#
//    it then loads): a later plain shader's table, a cached texture a later shader samples; both
//    see what the pass wrote; its result becomes final while another thread holds the
//    texture cache's lock;
//  - two fast dispatches back to back (a chain), the first missing: both re-run in order;
//  - a shader sampling an image, re-run with the texture it bound;
//  - a miss re-run with no further work from the CP.
// Separate runs, as the renderer gives up on the GPU in them (a result withheld for the test):
//  - hang-cp: the CP's wait for it ends after the GPU timeout;
//  - hang-throttle: so does the encoder's wait for room for command buffers behind it;
//  - hang-fast-throttle: the same wait met by a fast dispatch about to be encoded.
//
// The fast path is opt-in (PS4_GNM_GUEST_MEMORY_FAST=1, set here); "default" runs without it:
// every guest memory dispatch is waited for, with the same results.
//
// The copy shader is a local fixture: game data, not distributed; each developer dumps it from
// their own copy of the game (tests/host/README.md). Without it the cases that dispatch it (the
// copy cases, most fast path cases, "default" and the hang-* runs) print SKIP lines and do not
// count as passed; a fixture that is present but not the expected shader fails. The
// hand-assembled cases build their own register file and need no fixture.
//
// usage: gnm_guest_memory_test <local fixture dir> [default | hang-cp | hang-throttle | hang-fast-throttle]
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <signal.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>

#include <array>
#include <atomic>
#include <chrono>
#include <fstream>
#include <sstream>
#include <string>
#include <thread>
#include <vector>

#include "gcn_recompiler.h"
#include "ps4_gnm_backend_metal4.h"
#include "ps4_gnm_draw.h"

extern "C" void ps4_gnm_guest_remapped(uint64_t addr, uint64_t size);
extern "C" void* ps4_gnm_debug_backend(void);
extern "C" uint32_t ps4_gnm_debug_window_count(void);
extern "C" uint32_t ps4_gnm_debug_arena_chunks(void);
extern "C" uint64_t ps4_gnm_debug_sweep_released(void);

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

// The register file of a 64x1x1 compute dispatch on every CU; the program, its resources and
// user data are set by each case.
std::vector<uint32_t> BaseComputeRegs() {
    std::vector<uint32_t> regs(0x10000, 0);
    regs[0x2E07] = 64; // COMPUTE_NUM_THREAD_X
    regs[0x2E08] = 1;  // COMPUTE_NUM_THREAD_Y
    regs[0x2E09] = 1;  // COMPUTE_NUM_THREAD_Z
    regs[0x2E16] = 0xFFFFFFFFu; // COMPUTE_STATIC_THREAD_MGMT_SE0
    regs[0x2E17] = 0xFFFFFFFFu; // COMPUTE_STATIC_THREAD_MGMT_SE1
    return regs;
}

bool Exists(const std::string& path) {
    struct stat st;
    return stat(path.c_str(), &st) == 0;
}

// The first absent fixture file of the copy shader, or "" when both are present.
std::string MissingFixture(const std::string& dir) {
    for (const char* f : {"/u4_cs_copy.bin", "/u4_cs_copy.txt"})
        if (!Exists(dir + f)) return dir + f;
    return "";
}

void PrintSkip(const char* name, const std::string& missing) {
    printf("SKIP: gnm_guest_memory_test/%s: needs local fixture %s (game data, not distributed)\n", name, missing.c_str());
}

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
        const uint32_t r = std::strtoul(a.c_str(), nullptr, 16);
        if (r < g_regs.size()) g_regs[r] = std::strtoul(b.c_str(), nullptr, 16);
    }
    g_regs[0x2E0C] = uint32_t(kCode >> 8); // COMPUTE_PGM_LO
    g_regs[0x2E0D] = 0;
    g_regs[0x2E40] = uint32_t(kTable); // COMPUTE_USER_DATA_0/1: the copy table
    g_regs[0x2E41] = 0;
    return g_regs[0x2E13] == 0x84 && g_regs[0x2E07] == 64;
}

// Writes the code, the table and (fill) the buffers: sources hold 0xA5000000 | (entry << 16) |
// dword, destinations kSentinel.
void PrepareCopy(const std::vector<Entry>& entries, bool remove_dst_compare, bool fill = true, uint64_t table = kTable) {
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
    memset(g_mem + table, 0, 512);
    At(table)[72] = uint32_t(entries.size());
    for (size_t i = 0; i < entries.size(); ++i) {
        const Entry& e = entries[i];
        PutVsharp(At(table + 16 * i), e.src, 4, e.src_records, 0x20024004u);
        if (e.null_dst) memset(At(table + 128 + 16 * i), 0, 16);
        else PutVsharp(At(table + 128 + 16 * i), e.dst, 4, e.dst_records, e.dst_dword3);
        At(table + 256)[i] = e.count;
        for (uint32_t k = 0; fill && k < 64; ++k) {
            At(e.src)[k] = 0xA5000000u | uint32_t(i << 16) | k;
            if (!e.null_dst) At(e.dst)[k] = kSentinel;
        }
    }
    // the CPU wrote guest memory the renderer may have cached
    g_regs[0x2E40] = uint32_t(table); // COMPUTE_USER_DATA_0: the copy table
    ps4draw::NotifyGuestWrite(table, 4096, false, 0);
}

// PrepareCopy, then one dispatch of 64 threads, waited for. after_dispatch: the renderer's
// guest memory counters right after the dispatch was encoded (before the wait).
void Run(const std::vector<Entry>& entries, bool remove_dst_compare, ps4draw::GuestMemoryStats* after_dispatch = nullptr) {
    PrepareCopy(entries, remove_dst_compare);
    ps4draw::Dispatch(&g_ctx, g_regs.data(), 1, 1, 1, 0, "gfx", ps4draw::kQueueGfx);
    if (after_dispatch) *after_dispatch = ps4draw::GetGuestMemoryStats();
    ps4draw::Flush(true);
}

// entry i of a copy of `count` dwords from a source of `src_records` records (Run's contents)
void CheckCopy(const Entry& e, uint32_t i, const char* what) {
    for (uint32_t k = 0; k < 64; ++k) {
        const uint32_t want = k < std::min(e.count, e.src_records) ? (0xA5000000u | (i << 16) | k)
                              : k < std::min(e.count, e.dst_records) ? 0u
                                                                     : kSentinel;
        CHECK(At(e.dst)[k] == want, "%s: entry %u dst[%u] = %08x, want %08x", what, i, k, At(e.dst)[k], want);
    }
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

// The same copy again: the shader's written pages are known from TestCopy, so the dispatch
// takes the fast path (probe, gate and pass in the open command buffer): nothing waits for the
// GPU when it is encoded, and the result is the same as on the sync path.
void TestSteadyState() {
    const Entry e0{kSrc, kDst, 24, 24, 24};
    const Entry e1{kSrc + 0x100000, kDst + 0x100000, 12, 16, 16};
    const ps4draw::GuestMemoryStats before = ps4draw::GetGuestMemoryStats();
    ps4draw::GuestMemoryStats encoded;
    Run({e0, e1}, false, &encoded);
    const ps4draw::GuestMemoryStats after = ps4draw::GetGuestMemoryStats();
    CHECK(encoded.fast == before.fast + 1 && encoded.sync == before.sync, "not on the fast path (fast %llu -> %llu, sync %llu -> %llu)",
          (unsigned long long)before.fast, (unsigned long long)encoded.fast, (unsigned long long)before.sync,
          (unsigned long long)encoded.sync);
    CHECK(encoded.waits == before.waits, "encoding the dispatch waited for the GPU %llu time(s)",
          (unsigned long long)(encoded.waits - before.waits));
    CHECK(after.reruns == before.reruns, "the dispatch was re-run");
    CheckCopy(e0, 0, "steady state");
    CheckCopy(e1, 1, "steady state");
}

// The copy with its source moved into a 64 MiB page no dispatch has used: the fast path's probe
// finds the page unmapped, its gate refuses the pass, and the dispatch runs again (pages
// mapped) before anything after it. Same result as the sync path.
void TestMissRerun() {
    const Entry e0{0x40000000, kDst, 24, 24, 24};
    const Entry e1{kSrc + 0x100000, kDst + 0x100000, 12, 16, 16};
    const ps4draw::GuestMemoryStats before = ps4draw::GetGuestMemoryStats();
    ps4draw::GuestMemoryStats encoded;
    Run({e0, e1}, false, &encoded);
    const ps4draw::GuestMemoryStats after = ps4draw::GetGuestMemoryStats();
    CHECK(encoded.fast == before.fast + 1 && encoded.waits == before.waits, "not encoded on the fast path");
    CHECK(after.reruns == before.reruns + 1, "the dispatch was not re-run (%llu)",
          (unsigned long long)(after.reruns - before.reruns));
    CheckCopy(e0, 0, "miss");
    CheckCopy(e1, 1, "miss");
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
// Dispatches a hand-assembled program at `code_at` over the table at `table` (not waited for).
void DispatchProgram(uint64_t code_at, uint64_t table, const std::vector<uint32_t>& body, uint64_t hash,
                     const std::vector<std::array<uint32_t, 4>>& vsharps) {
    const std::vector<uint32_t> code = gcn::WithFooter(body, hash);
    memcpy(g_mem + code_at, code.data(), code.size() * 4);
    memset(g_mem + table, 0, 256);
    for (size_t i = 0; i < vsharps.size(); ++i) memcpy(At(table + 16 * i), vsharps[i].data(), 16);
    std::vector<uint32_t> regs = BaseComputeRegs();
    regs[0x2E0C] = uint32_t(code_at >> 8);
    regs[0x2E12] = 1 | (2 << 6); // 8 VGPRs, 24 SGPRs
    regs[0x2E13] = 2 << 1 | 1 << 7; // 2 user SGPRs, s2 = workgroup id x
    regs[0x2E40] = uint32_t(table);
    ps4draw::NotifyGuestWrite(table, 4096, false, 0);
    ps4draw::Dispatch(&g_ctx, regs.data(), 1, 1, 1, 0, "gfx", ps4draw::kQueueGfx);
}

void RunProgram(const std::vector<uint32_t>& body, uint64_t hash, const std::vector<std::array<uint32_t, 4>>& vsharps) {
    DispatchProgram(kCode2, kTable2, body, hash, vsharps);
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

// A shader with an effect that a second run would repeat: every thread adds 1 to its dword of
// buffer A and copies its dword of B into C (V#s A, B, C from the table). Its first dispatch
// (sync path) learns its written pages; in the second B is in a page not mapped yet, so the
// fast path's gate refuses the pass and the dispatch runs again. Had the refused pass run (an
// early-out without effect), A would be incremented twice.
void TestEarlyOutHasNoEffect() {
    using namespace gcn;
    std::vector<uint32_t> c;
    LoadTwoVsharps(c);                  // s[4:7] = A, s[12:15] = B
    c.push_back(SAddU32(10, 8, 0xA0));  // + 32
    c.push_back(Smrd(2, 16, 0, 10));    // s[16:19] = C
    c.push_back(kWait);
    Mubuf(c, kLoadDword, true, false, 0, 1, 12); // v1 = B[tid]
    Mubuf(c, kLoadDword, true, false, 0, 2, 4);  // v2 = A[tid]
    c.push_back(kWait);
    c.push_back(37u << 25 | 2u << 17 | 2u << 9 | 0x81u); // v_add_i32 v2, vcc, 1, v2
    Mubuf(c, kStoreDword, true, false, 0, 2, 4);  // A[tid] = v2
    Mubuf(c, kStoreDword, true, false, 0, 1, 16); // C[tid] = v1
    c.push_back(kEnd);
    const uint64_t a = kDst + 0x900000, cdst = kDst + 0xA00000;
    const auto run = [&](uint64_t b, uint32_t base) {
        for (uint32_t k = 0; k < 64; ++k) {
            At(a)[k] = base + k;
            At(b)[k] = 0xE0000000u | base | k;
            At(cdst)[k] = kSentinel;
        }
        RunProgram(c, 0x5CA1AB1E0000D004ull,
                   {Vsharp(a, 4, 64, 0x20024004u), Vsharp(b, 4, 64, 0x20024004u), Vsharp(cdst, 4, 64, 0x20024004u)});
        for (uint32_t k = 0; k < 64; ++k) {
            CHECK(At(a)[k] == base + k + 1, "A[%u] = %u, want %u (base %u)", k, At(a)[k], base + k + 1, base);
            CHECK(At(cdst)[k] == (0xE0000000u | base | k), "C[%u] = %08x, want %08x", k, At(cdst)[k], 0xE0000000u | base | k);
        }
    };
    const uint64_t skipped0 = ps4draw::SkippedCount();
    const ps4draw::GuestMemoryStats s0 = ps4draw::GetGuestMemoryStats();
    run(kSrc + 0x900000, 100);
    const ps4draw::GuestMemoryStats s1 = ps4draw::GetGuestMemoryStats();
    CHECK(s1.sync == s0.sync + 1, "the first dispatch did not take the sync path");
    run(0x48000000, 200); // a page no dispatch has used
    const ps4draw::GuestMemoryStats s2 = ps4draw::GetGuestMemoryStats();
    CHECK(s2.fast == s1.fast + 1 && s2.reruns == s1.reruns + 1, "fast %llu re-runs %llu, want 1 and 1",
          (unsigned long long)(s2.fast - s1.fast), (unsigned long long)(s2.reruns - s1.reruns));
    CHECK(ps4draw::SkippedCount() == skipped0, "a dispatch was skipped");
}

// A plain shader (no guest memory: its two V#s are read by the CP, s_load_dwordx4 at fixed
// offsets from its user data, the SRT walk) that copies 64 dwords from the first V# into the
// second, over the table at `table`; and the copy shader writing that table (8 dwords: one
// entry from vsrc). The CP reads the table when it prepares the plain shader's dispatch.
struct CopyThenPlain {
    uint64_t table, vsrc;
    std::vector<uint32_t> regs;
    CopyThenPlain(uint64_t table_, uint64_t vsrc_, uint64_t code_at, uint64_t hash) : table(table_), vsrc(vsrc_) {
        using namespace gcn;
        std::vector<uint32_t> c;
        c.push_back(0xC0000000u | 2u << 22 | 4u << 15 | 0u << 9 | 1u << 8 | 0u);  // s_load_dwordx4 s[4:7], s[0:1], 0
        c.push_back(0xC0000000u | 2u << 22 | 12u << 15 | 0u << 9 | 1u << 8 | 4u); // s_load_dwordx4 s[12:15], s[0:1], 4
        c.push_back(kWait);
        Mubuf(c, kLoadDword, true, false, 0, 1, 4);
        c.push_back(kWait);
        Mubuf(c, kStoreDword, true, false, 0, 1, 12);
        c.push_back(kEnd);
        const std::vector<uint32_t> code = WithFooter(c, hash);
        memcpy(g_mem + code_at, code.data(), code.size() * 4);
        regs = BaseComputeRegs();
        regs[0x2E0C] = uint32_t(code_at >> 8);
        regs[0x2E12] = 1 | (2 << 6);
        regs[0x2E13] = 2 << 1 | 1 << 7;
        regs[0x2E40] = uint32_t(table);
    }
    static void PutTable(uint32_t* at, uint64_t src, uint64_t dst) {
        PutVsharp(at, src, 4, 64, 0x20024004u);
        PutVsharp(at + 4, dst, 4, 64, 0x20024004u);
    }
    static void Fill(uint64_t src, uint64_t dst, uint32_t tag) {
        for (uint32_t k = 0; k < 64; ++k) {
            At(src)[k] = tag | k;
            At(dst)[k] = kSentinel;
        }
    }
    // the table holds (src, dst) now (CPU write)
    void SetTable(uint64_t src, uint64_t dst) const {
        PutTable(At(table), src, dst);
        ps4draw::NotifyGuestWrite(table, 32, false, 0);
    }
    // the copy writes (src, dst) into the table when it runs
    void Copy(uint64_t src, uint64_t dst, bool wait, const char* name = "gfx", int queue = ps4draw::kQueueGfx) const {
        PutTable(At(vsrc), src, dst);
        PrepareCopy({Entry{vsrc, table, 8, 8, 8}}, false, false);
        ps4draw::NotifyGuestWrite(vsrc, 64, false, 0);
        ps4draw::Dispatch(&g_ctx, g_regs.data(), 1, 1, 1, 0, name, queue);
        if (wait) ps4draw::Flush(true);
    }
    void Plain(bool wait = true, const char* name = "gfx", int queue = ps4draw::kQueueGfx) const {
        ps4draw::Dispatch(&g_ctx, regs.data(), 1, 1, 1, 0, name, queue);
        if (wait) ps4draw::Flush(true);
    }
};

void CheckFilled(uint64_t dst, uint32_t tag, const char* what) {
    for (uint32_t k = 0; k < 64; ++k)
        CHECK(At(dst)[k] == (tag | k), "%s: dst[%u] = %08x, want %08x", what, k, At(dst)[k], tag | k);
}
void CheckUntouched(uint64_t dst, const char* what) {
    for (uint32_t k = 0; k < 64; ++k) CHECK(At(dst)[k] == kSentinel, "%s: dst[%u] = %08x written", what, k, At(dst)[k]);
}

// The CP reads resource tables of later dispatches from guest memory (the SRT walk); a fast
// guest memory dispatch may have written them. The copy shader writes the two V#s of a plain
// shader's table. After a CS partial flush between them (ComputeBarrier), as the guest orders such
// a pair on GCN, the plain shader must bind the V#s the copy wrote, not the ones the table held
// before. Without it the two are not ordered (on GCN they may run at the same time) and the CP
// does not wait.
void TestCpWaitsForFastDispatch() {
    const uint64_t right_src = kSrc + 0xC00000, right_dst = kDst + 0xC00000;
    const uint64_t decoy_src = kSrc + 0xD00000, decoy_dst = kDst + 0xD00000;
    const CopyThenPlain cp(kDst + 0xB00000, kSrc + 0xB00000, 0x01200000, 0x5CA1AB1E0000D005ull);
    const auto barrier = [] { ps4draw::ComputeBarrier(ps4draw::kQueueGfx); };
    // warm-up: the copy learns its written page, the plain shader is translated
    CopyThenPlain::Fill(right_src, right_dst, 0xF1000000u);
    cp.Copy(right_src, right_dst, true);
    barrier();
    cp.Plain();
    CheckFilled(right_dst, 0xF1000000u, "warm-up");
    // not ordered: the CP does not wait
    cp.SetTable(decoy_src, decoy_dst);
    const ps4draw::GuestMemoryStats unordered = ps4draw::GetGuestMemoryStats();
    cp.Copy(right_src, right_dst, false);
    cp.Plain();
    CHECK(ps4draw::GetGuestMemoryStats().cp_waits == unordered.cp_waits, "the CP waited without a barrier");
    // ordered: the table holds the decoy V#s until the copy (fast path, not waited for) replaces them
    CopyThenPlain::Fill(right_src, right_dst, 0xF2000000u);
    CopyThenPlain::Fill(decoy_src, decoy_dst, 0xF3000000u);
    cp.SetTable(decoy_src, decoy_dst);
    const ps4draw::GuestMemoryStats before = ps4draw::GetGuestMemoryStats();
    cp.Copy(right_src, right_dst, false);
    barrier();
    cp.Plain();
    const ps4draw::GuestMemoryStats after = ps4draw::GetGuestMemoryStats();
    CHECK(after.fast == before.fast + 1, "the copy did not take the fast path");
    CHECK(after.cp_waits == before.cp_waits + 1, "the CP waited %llu times for the copy, want 1",
          (unsigned long long)(after.cp_waits - before.cp_waits));
    CheckFilled(right_dst, 0xF2000000u, "ordered");
    CheckUntouched(decoy_dst, "ordered: decoy");
}

// A compute shader never dispatched before, after a barrier behind a fast copy that writes its
// resource table: its first translation specializes on the sharps it reads through the table
// (the source's stride here), so it must read them after the copy ran. The table holds a decoy
// (stride 4) until the copy writes the right V#s (stride 8): every dst dword k is source dword 2k.
void TestNewShaderAfterFastCopy() {
    const uint64_t right_src = kSrc + 0x2800000, right_dst = kDst + 0x2800000;
    const uint64_t decoy_src = kSrc + 0x2900000, decoy_dst = kDst + 0x2900000;
    CopyThenPlain cp(kDst + 0x2700000, kSrc + 0x2700000, 0x01D00000, 0x5CA1AB1E0000D010ull);
    const auto put = [](uint32_t* at, uint64_t src, uint32_t stride, uint64_t dst) {
        PutVsharp(at, src, stride, 64, 0x20024004u);
        PutVsharp(at + 4, dst, 4, 64, 0x20024004u);
    };
    const auto copy = [&](bool wait) { // the copy writes the right V#s into cp.table
        put(At(cp.vsrc), right_src, 8, right_dst);
        PrepareCopy({Entry{cp.vsrc, cp.table, 8, 8, 8}}, false, false);
        ps4draw::NotifyGuestWrite(cp.vsrc, 64, false, 0);
        ps4draw::Dispatch(&g_ctx, g_regs.data(), 1, 1, 1, 0, "gfx", ps4draw::kQueueGfx);
        if (wait) ps4draw::Flush(true);
    };
    copy(true); // the copy learns cp.table's page; the plain shader is not dispatched
    for (uint32_t k = 0; k < 128; ++k) At(right_src)[k] = 0xA7000000u | k, At(decoy_src)[k] = 0xA8000000u | k;
    for (uint32_t k = 0; k < 64; ++k) At(right_dst)[k] = kSentinel, At(decoy_dst)[k] = kSentinel;
    ps4draw::NotifyGuestWrite(right_src, 512, false, 0);
    ps4draw::NotifyGuestWrite(decoy_src, 512, false, 0);
    put(At(cp.table), decoy_src, 4, decoy_dst);
    ps4draw::NotifyGuestWrite(cp.table, 32, false, 0);
    const ps4draw::GuestMemoryStats s0 = ps4draw::GetGuestMemoryStats();
    copy(false); // fast, not waited for
    ps4draw::ComputeBarrier(ps4draw::kQueueGfx);
    cp.Plain(); // its first dispatch
    const ps4draw::GuestMemoryStats s1 = ps4draw::GetGuestMemoryStats();
    CHECK(s1.fast == s0.fast + 1 && s1.cp_waits == s0.cp_waits + 1, "fast %llu CP waits %llu, want 1 1",
          (unsigned long long)(s1.fast - s0.fast), (unsigned long long)(s1.cp_waits - s0.cp_waits));
    for (uint32_t k = 0; k < 64; ++k)
        CHECK(At(right_dst)[k] == (0xA7000000u | (2 * k)), "new shader: dst[%u] = %08x, want %08x", k, At(right_dst)[k],
              0xA7000000u | (2 * k));
    CheckUntouched(decoy_dst, "new shader: decoy");
}

// The same pair on the compute queue (the asc rings: "asc", "asc-indirect"): the copy's result is
// visible to the compute queue's reads after the compute queue's synchronization, not after the
// graphics ring's.
void TestComputeQueueVisibility() {
    const uint64_t right_src = kSrc + 0x1A00000, right_dst = kDst + 0x1A00000;
    const uint64_t decoy_src = kSrc + 0x1B00000, decoy_dst = kDst + 0x1B00000;
    const CopyThenPlain cp(kDst + 0x1C00000, kSrc + 0x1C00000, 0x01700000, 0x5CA1AB1E0000D00Aull);
    const int q = ps4draw::kQueueCompute;
    CopyThenPlain::Fill(right_src, right_dst, 0xC1000000u);
    cp.Copy(right_src, right_dst, true, "asc", q);
    ps4draw::ComputeBarrier(q);
    cp.Plain(true, "asc-indirect", q);
    CheckFilled(right_dst, 0xC1000000u, "compute warm-up");
    // the graphics ring synchronizes: not an ordering point for the compute queue
    CopyThenPlain::Fill(right_src, right_dst, 0xC2000000u);
    CopyThenPlain::Fill(decoy_src, decoy_dst, 0xC3000000u);
    cp.SetTable(decoy_src, decoy_dst);
    ps4draw::GuestMemoryStats s0 = ps4draw::GetGuestMemoryStats();
    cp.Copy(right_src, right_dst, false, "asc", q);
    ps4draw::ComputeBarrier(ps4draw::kQueueGfx);
    cp.Plain(true, "asc-indirect", q);
    ps4draw::GuestMemoryStats s1 = ps4draw::GetGuestMemoryStats();
    CHECK(s1.fast == s0.fast + 1 && s1.cp_waits == s0.cp_waits, "gfx barrier: fast %llu CP waits %llu, want 1 0",
          (unsigned long long)(s1.fast - s0.fast), (unsigned long long)(s1.cp_waits - s0.cp_waits));
    // the compute queue synchronizes: its next dispatch ("asc-indirect" as well) waits
    CopyThenPlain::Fill(right_src, right_dst, 0xC4000000u);
    CopyThenPlain::Fill(decoy_src, decoy_dst, 0xC5000000u);
    cp.SetTable(decoy_src, decoy_dst);
    s0 = ps4draw::GetGuestMemoryStats();
    cp.Copy(right_src, right_dst, false, "asc", q);
    ps4draw::ComputeBarrier(q);
    cp.Plain(true, "asc-indirect", q);
    s1 = ps4draw::GetGuestMemoryStats();
    CHECK(s1.fast == s0.fast + 1 && s1.cp_waits == s0.cp_waits + 1, "compute barrier: fast %llu CP waits %llu, want 1 1",
          (unsigned long long)(s1.fast - s0.fast), (unsigned long long)(s1.cp_waits - s0.cp_waits));
    CheckFilled(right_dst, 0xC4000000u, "compute barrier");
    CheckUntouched(decoy_dst, "compute barrier: decoy");
}

// The copy writes the plain shader's table in a page its prediction does not have: its probe
// finds it, the gate refuses the pass and the dispatch runs again. The CP prepares the plain
// shader after a barrier: it waits for the copy's result (whatever pages were predicted) and binds
// the V#s the copy wrote.
void TestMispredictedWriteIsOrdered() {
    const uint64_t right_src = kSrc + 0x1300000, right_dst = kDst + 0x1300000;
    const CopyThenPlain warm(kDst + 0x1D00000, kSrc + 0x1D00000, 0x01600000, 0x5CA1AB1E0000D009ull);
    // the same plain shader over a table in a page the copy never wrote
    CopyThenPlain cp = warm;
    cp.table = kDst + 0x1200000;
    cp.vsrc = kSrc + 0x1200000;
    cp.regs[0x2E40] = uint32_t(cp.table);
    CopyThenPlain::Fill(right_src, right_dst, 0xF5000000u);
    warm.Copy(right_src, right_dst, true); // learns the page of warm.table
    ps4draw::ComputeBarrier(ps4draw::kQueueGfx);
    warm.Plain();
    CheckFilled(right_dst, 0xF5000000u, "mispredicted warm-up");
    CopyThenPlain::Fill(right_src, right_dst, 0xF4000000u);
    memset(At(cp.table), 0, 32); // null V#s: the plain shader does nothing unless the copy wrote them
    ps4draw::NotifyGuestWrite(cp.table, 32, false, 0);
    const ps4draw::GuestMemoryStats before = ps4draw::GetGuestMemoryStats();
    cp.Copy(right_src, right_dst, false); // fast: cp.table's page is not predicted
    ps4draw::ComputeBarrier(ps4draw::kQueueGfx);
    cp.Plain(); // the CP reads cp.table now
    const ps4draw::GuestMemoryStats after = ps4draw::GetGuestMemoryStats();
    CHECK(after.fast == before.fast + 1 && after.reruns == before.reruns + 1 && after.mispredicted == before.mispredicted + 1,
          "fast %llu re-runs %llu mispredicted %llu, want 1 1 1", (unsigned long long)(after.fast - before.fast),
          (unsigned long long)(after.reruns - before.reruns), (unsigned long long)(after.mispredicted - before.mispredicted));
    CHECK(after.cp_waits == before.cp_waits + 1, "the CP did not wait for the copy");
    CHECK(At(cp.table)[0] == uint32_t(right_src), "the copy's own result is wrong: %08x", At(cp.table)[0]);
    CheckFilled(right_dst, 0xF4000000u, "mispredicted");
}

// A shader whose pass writes where its probe could not know: it first stores a V# (from buffer
// N) into buffer B, then loads its destination V# back from B and copies 64 dwords from S through
// it. The probe stores nothing, so it reads B's old V# and reports the old destination's page
// (predicted): the gate passes. The pass writes the new destination, outside the prediction.
// V#s: B at table + 0, N at + 16, S at + 32.
std::vector<uint32_t> StoreThenLoadProgram() {
    using namespace gcn;
    std::vector<uint32_t> c;
    LoadTwoVsharps(c);                 // s[4:7] = B, s[12:15] = N
    c.push_back(SAddU32(10, 8, 0xA0)); // + 32
    c.push_back(Smrd(2, 16, 0, 10));   // s[16:19] = S
    c.push_back(kWait);
    c.push_back(Vop1(kMov, 1, 0x80)); // v1 = 0
    Mubuf(c, kLoadDwordx4, false, true, 1, 4, 12); // v[4:7] = N[0..3]
    c.push_back(kWait);
    Mubuf(c, kStoreDwordx4, false, true, 1, 4, 4); // B[0..3] = v[4:7]
    c.push_back(kWait);
    Mubuf(c, kLoadDwordx4, false, true, 1, 4, 4); // v[4:7] = B[0..3]
    c.push_back(kWait);
    for (uint32_t k = 0; k < 4; ++k) c.push_back(Vop1(kReadFirstLane, 20 + k, V(4 + k))); // s[20:23] = D
    Mubuf(c, kLoadDword, true, false, 0, 2, 16); // v2 = S[tid]
    c.push_back(kWait);
    Mubuf(c, kStoreDword, true, false, 0, 2, 20); // D[tid] = v2
    c.push_back(kEnd);
    return c;
}

struct StoreThenLoad {
    uint64_t code_at, table, b, n, src, hash;
    // one dispatch: B holds what it holds, N the V# of `dst` (num_records dwords), S the dwords
    void Dispatch(uint64_t dst, uint32_t num_records) const {
        PutVsharp(At(n), dst, 4, num_records, 0x20024004u);
        ps4draw::NotifyGuestWrite(n, 16, false, 0);
        DispatchProgram(code_at, table, StoreThenLoadProgram(), hash,
                        {Vsharp(b, 0, 16, 0x20024004u), Vsharp(n, 0, 16, 0x20024004u), Vsharp(src, 4, 64, 0x20024004u)});
    }
};

// The pass of a fast dispatch writes the table of a later plain shader outside its prediction,
// after its gate passed (nothing is re-run): the CP, preparing the plain shader after a barrier,
// still binds the V#s the pass wrote.
void TestPassWritesOutsideProbe() {
    const StoreThenLoad m{0x01800000, 0x02700000, kDst + 0x1600000, kSrc + 0x1600000, kSrc + 0x1700000, 0x5CA1AB1E0000D00Bull};
    const uint64_t first_dst = kDst + 0x1700000;
    const uint64_t right_src = kSrc + 0x1800000, right_dst = kDst + 0x1800000;
    CopyThenPlain plain(kDst + 0x1E00000, 0, 0x01900000, 0x5CA1AB1E0000D00Cull); // its table: outside m's prediction
    // learning run (sync path): B -> first_dst, written: B's and first_dst's pages
    PutVsharp(At(m.b), first_dst, 4, 64, 0x20024004u);
    for (uint32_t k = 0; k < 64; ++k) At(m.src)[k] = 0xE1000000u | k, At(first_dst)[k] = kSentinel;
    const ps4draw::GuestMemoryStats s0 = ps4draw::GetGuestMemoryStats();
    m.Dispatch(first_dst, 64);
    ps4draw::Flush(true);
    CheckFilled(first_dst, 0xE1000000u, "store-then-load learning run");
    CHECK(ps4draw::GetGuestMemoryStats().sync == s0.sync + 1, "the learning run did not take the sync path");
    // the plain shader once (translated), its table null
    memset(At(plain.table), 0, 32);
    ps4draw::NotifyGuestWrite(plain.table, 32, false, 0);
    plain.Plain();
    // the pass writes the plain shader's two V#s (S holds them) into its table; B still holds
    // first_dst's V#, so the probe reports first_dst's page
    CopyThenPlain::Fill(right_src, right_dst, 0xE2000000u);
    CopyThenPlain::PutTable(At(m.src), right_src, right_dst);
    ps4draw::NotifyGuestWrite(m.src, 64, false, 0);
    for (uint32_t k = 0; k < 64; ++k) At(first_dst)[k] = kSentinel;
    const ps4draw::GuestMemoryStats s1 = ps4draw::GetGuestMemoryStats();
    m.Dispatch(plain.table, 8);
    ps4draw::ComputeBarrier(ps4draw::kQueueGfx);
    plain.Plain();
    const ps4draw::GuestMemoryStats s2 = ps4draw::GetGuestMemoryStats();
    CHECK(s2.fast == s1.fast + 1 && s2.reruns == s1.reruns && s2.mispredicted == s1.mispredicted + 1,
          "fast %llu re-runs %llu mispredicted %llu, want 1 0 1", (unsigned long long)(s2.fast - s1.fast),
          (unsigned long long)(s2.reruns - s1.reruns), (unsigned long long)(s2.mispredicted - s1.mispredicted));
    CHECK(At(plain.table)[0] == uint32_t(right_src), "the pass did not write the table: %08x", At(plain.table)[0]);
    CheckUntouched(first_dst, "store-then-load: old destination");
    CheckFilled(right_dst, 0xE2000000u, "store-then-load: the plain shader after it");
}

// Two fast dispatches back to back form a chain (one point where the GPU waits for the CPU's
// verdict): X copies A into B, Y adds B to C. X's source moves into a page not mapped yet, so
// X's gate refuses it; Y's gate must then refuse Y too (it would add B before X wrote it), and
// both run again in order: C (0 before) receives A's dwords, added once.
void TestChainedMiss() {
    using namespace gcn;
    std::vector<uint32_t> c; // dst[tid] = src[tid] through the V#s at table + 0 (src) and + 16 (dst)
    LoadTwoVsharps(c);
    Mubuf(c, kLoadDword, true, false, 0, 1, 4);
    c.push_back(kWait);
    Mubuf(c, kStoreDword, true, false, 0, 1, 12);
    c.push_back(kEnd);
    std::vector<uint32_t> add; // dst[tid] += src[tid]
    LoadTwoVsharps(add);
    Mubuf(add, kLoadDword, true, false, 0, 1, 4);
    Mubuf(add, kLoadDword, true, false, 0, 2, 12);
    add.push_back(kWait);
    add.push_back(37u << 25 | 2u << 17 | 2u << 9 | 0x101u); // v_add_i32 v2, vcc, v1, v2
    Mubuf(add, kStoreDword, true, false, 0, 2, 12);
    add.push_back(kEnd);
    const uint64_t code_x = 0x01300000, code_y = 0x01400000, table_x = 0x02300000, table_y = 0x02400000;
    const uint64_t b = kDst + 0xE00000, cdst = kDst + 0xF00000;
    const auto run = [&](uint64_t a, uint32_t tag, bool flush_between) {
        for (uint32_t k = 0; k < 64; ++k) {
            At(a)[k] = tag | k;
            At(b)[k] = kSentinel;
            At(cdst)[k] = 0;
        }
        DispatchProgram(code_x, table_x, c, 0x5CA1AB1E0000D006ull, {Vsharp(a, 4, 64, 0x20024004u), Vsharp(b, 4, 64, 0x20024004u)});
        if (flush_between) ps4draw::Flush(true);
        DispatchProgram(code_y, table_y, add, 0x5CA1AB1E0000D007ull, {Vsharp(b, 4, 64, 0x20024004u), Vsharp(cdst, 4, 64, 0x20024004u)});
        ps4draw::Flush(true);
        for (uint32_t k = 0; k < 64; ++k) CHECK(At(cdst)[k] == (tag | k), "C[%u] = %08x, want %08x", k, At(cdst)[k], tag | k);
    };
    run(kSrc + 0xE00000, 0xB1000000u, true); // both shaders learn their pages (sync path)
    const ps4draw::GuestMemoryStats s0 = ps4draw::GetGuestMemoryStats();
    run(kSrc + 0xF00000, 0xB2000000u, false); // a chain of two that does not miss
    const ps4draw::GuestMemoryStats s1 = ps4draw::GetGuestMemoryStats();
    CHECK(s1.fast == s0.fast + 2 && s1.chains == s0.chains + 1 && s1.reruns == s0.reruns,
          "chain without a miss: fast %llu chains %llu re-runs %llu, want 2 1 0", (unsigned long long)(s1.fast - s0.fast),
          (unsigned long long)(s1.chains - s0.chains), (unsigned long long)(s1.reruns - s0.reruns));
    run(0x50000000, 0xB3000000u, false); // X's source in a page no dispatch has used
    const ps4draw::GuestMemoryStats s2 = ps4draw::GetGuestMemoryStats();
    CHECK(s2.fast == s1.fast + 2 && s2.chains == s1.chains + 1 && s2.reruns == s1.reruns + 2,
          "chain with a miss: fast %llu chains %llu re-runs %llu, want 2 1 2", (unsigned long long)(s2.fast - s1.fast),
          (unsigned long long)(s2.chains - s1.chains), (unsigned long long)(s2.reruns - s1.reruns));
}

// A guest memory shader that samples an image (T# and S# in its user data): the fast path takes
// it too. Its second dispatch meets a page not mapped yet and runs again; the re-run binds the
// texture the dispatch bound (as the dispatch without a miss would have used it), not one made
// from the guest memory the CPU changed after the dispatch was encoded.
void TestSampledImage() {
    using namespace gcn;
    constexpr uint64_t kTex = 0x02500000, code_at = 0x01500000, table = 0x02600000;
    std::vector<uint32_t> c;
    c.push_back(SAddU32(20, 16, 0x80));  // s20 = workgroup id + 0
    c.push_back(Smrd(2, 24, 0, 20));     // s[24:27] = V# at table + 0 (run time)
    c.push_back(kWait);
    c.push_back(0x7E0402FFu);            // v_mov_b32 v2, 0.3125
    c.push_back(0x3EA00000u);
    c.push_back(0x7E0602FFu);            // v_mov_b32 v3, 0.3125
    c.push_back(0x3EA00000u);
    c.push_back(0xF09C0F00u);            // image_sample_lz v[4:7], v[2:3], s[4:11], s[12:15] dmask 0xf
    c.push_back(2u | 4u << 8 | 1u << 16 | 3u << 21);
    c.push_back(kWait);
    Mubuf(c, kStoreDword, true, false, 0, 4, 24); // dst[tid] = red
    c.push_back(kEnd);
    const std::vector<uint32_t> code = WithFooter(c, 0x5CA1AB1E0000D008ull);
    memcpy(g_mem + code_at, code.data(), code.size() * 4);
    std::vector<uint32_t> regs = BaseComputeRegs();
    regs[0x2E0C] = uint32_t(code_at >> 8);
    regs[0x2E12] = 1 | (3 << 6);     // 8 VGPRs, 32 SGPRs
    regs[0x2E13] = 16 << 1 | 1 << 7; // 16 user SGPRs, s16 = workgroup id x
    uint32_t* ud = &regs[0x2E40];
    ud[0] = uint32_t(table);
    ud[1] = 0;
    ud[4] = uint32_t(kTex >> 8);                                            // T#: 8 x 8 16_16_16_16 float
    ud[5] = (12u << 20) | (7u << 26);
    ud[6] = 7 | (7u << 14);
    ud[7] = 4 | (5 << 3) | (6 << 6) | (7 << 9) | (8u << 20) | (9u << 28); // xyzw, linear aligned, 2D
    ud[8] = 7u << 13;                                                       // pitch 8
    ud[9] = ud[10] = ud[11] = 0;
    ud[12] = ud[13] = ud[14] = ud[15] = 0; // S#: wrap, point, LOD 0
    const auto fill_tex = [&](uint16_t red) {
        uint16_t* t = (uint16_t*)(g_mem + kTex);
        for (uint32_t i = 0; i < 64; ++i) {
            t[4 * i] = red;
            t[4 * i + 1] = t[4 * i + 2] = 0;
            t[4 * i + 3] = 0x3C00;
        }
        ps4draw::NotifyGuestWrite(kTex, 512, false, 0);
    };
    const auto run = [&](uint64_t dst, uint16_t red_before, uint16_t red_after, uint32_t want) {
        fill_tex(red_before);
        for (uint32_t k = 0; k < 64; ++k) At(dst)[k] = kSentinel;
        PutVsharp(At(table), dst, 4, 64, 0x18024004u);
        ps4draw::NotifyGuestWrite(table, 64, false, 0);
        ps4draw::Dispatch(&g_ctx, regs.data(), 1, 1, 1, 0, "gfx", ps4draw::kQueueGfx);
        fill_tex(red_after); // after the dispatch was encoded, before it ran
        ps4draw::Flush(true);
        for (uint32_t k = 0; k < 64; ++k) CHECK(At(dst)[k] == want, "image dst[%u] = %08x, want %08x", k, At(dst)[k], want);
    };
    const uint64_t skipped0 = ps4draw::SkippedCount();
    run(kDst + 0x1100000, 0x3800, 0x3800, 0x3F000000u); // 0.5: learns its pages
    const ps4draw::GuestMemoryStats s0 = ps4draw::GetGuestMemoryStats();
    run(kDst + 0x1100000, 0x3800, 0x3A00, 0x3F000000u); // fast path
    run(0x58000000, 0x3800, 0x3A00, 0x3F000000u);       // fast path, a miss and a re-run
    const ps4draw::GuestMemoryStats s1 = ps4draw::GetGuestMemoryStats();
    CHECK(s1.fast == s0.fast + 2 && s1.reruns == s0.reruns + 1, "image shader: fast %llu re-runs %llu, want 2 1",
          (unsigned long long)(s1.fast - s0.fast), (unsigned long long)(s1.reruns - s0.reruns));
    CHECK(ps4draw::SkippedCount() == skipped0, "a dispatch was skipped");
}

// A plain compute shader sampling an image (T# and S# in its user data, s[4:15]) into a buffer
// (V# in its user data, s[0:3]): its texture is uploaded from guest memory by the CPU.
struct SampleToBuffer {
    std::vector<uint32_t> regs;
    SampleToBuffer(uint64_t code_at, uint64_t tex, uint64_t out, uint64_t hash) {
        using namespace gcn;
        std::vector<uint32_t> c;
        c.push_back(0x7E0402FFu); // v_mov_b32 v2, 0.3125
        c.push_back(0x3EA00000u);
        c.push_back(0x7E0602FFu); // v_mov_b32 v3, 0.3125
        c.push_back(0x3EA00000u);
        c.push_back(0xF09C0F00u); // image_sample_lz v[4:7], v[2:3], s[4:11], s[12:15] dmask 0xf
        c.push_back(2u | 4u << 8 | 1u << 16 | 3u << 21);
        c.push_back(kWait);
        Mubuf(c, kStoreDword, true, false, 0, 4, 0); // out[tid] = red
        c.push_back(kEnd);
        const std::vector<uint32_t> code = WithFooter(c, hash);
        memcpy(g_mem + code_at, code.data(), code.size() * 4);
        regs = BaseComputeRegs();
        regs[0x2E0C] = uint32_t(code_at >> 8);
        regs[0x2E12] = 1 | (3 << 6);     // 8 VGPRs, 32 SGPRs
        regs[0x2E13] = 16 << 1 | 1 << 7; // 16 user SGPRs, s16 = workgroup id x
        uint32_t* ud = &regs[0x2E40];
        PutVsharp(ud, out, 4, 64, 0x18024004u);
        ud[4] = uint32_t(tex >> 8); // T#: 8 x 8 16_16_16_16 float
        ud[5] = (12u << 20) | (7u << 26);
        ud[6] = 7 | (7u << 14);
        ud[7] = 4 | (5 << 3) | (6 << 6) | (7 << 9) | (8u << 20) | (9u << 28); // xyzw, linear aligned, 2D
        ud[8] = 7u << 13;                                                       // pitch 8
        ud[9] = ud[10] = ud[11] = 0;
        ud[12] = ud[13] = ud[14] = ud[15] = 0; // S#: wrap, point, LOD 0
    }
    void Dispatch() const { ps4draw::Dispatch(&g_ctx, regs.data(), 1, 1, 1, 0, "gfx", ps4draw::kQueueGfx); }
};

// 8 x 8 texels of (red, 0, 0, 1) as halves, written into `at` as 128 dwords
void PutTexels(uint32_t* at, uint16_t red, uint32_t texels) {
    for (uint32_t i = 0; i < texels; ++i) {
        at[2 * i] = red;
        at[2 * i + 1] = 0x3C00u << 16;
    }
}

// The pass of a fast dispatch writes, outside its prediction (after its gate passed), the guest
// memory of a texture the renderer has cached; a plain shader samples it after a barrier: it must
// sample what the pass wrote (the cached texture is stale once the pass ran).
void TestPassWritesSampledTexture() {
    const StoreThenLoad m{0x01A00000, 0x02800000, kDst + 0x1F00000, kSrc + 0x1F00000, kSrc + 0x2000000, 0x5CA1AB1E0000D00Dull};
    const uint64_t first_dst = kDst + 0x2000000, tex = kDst + 0x2100000, out = kDst + 0x2200000;
    const SampleToBuffer q(0x01B00000, tex, out, 0x5CA1AB1E0000D00Eull);
    // learning run (sync path): B -> first_dst
    PutVsharp(At(m.b), first_dst, 4, 64, 0x20024004u);
    for (uint32_t k = 0; k < 64; ++k) At(m.src)[k] = 0xE3000000u | k;
    m.Dispatch(first_dst, 64);
    ps4draw::Flush(true);
    // the texture: red 0.5, sampled (and cached)
    PutTexels(At(tex), 0x3800, 64);
    ps4draw::NotifyGuestWrite(tex, 512, false, 0);
    const ps4draw::GuestMemoryStats s0 = ps4draw::GetGuestMemoryStats();
    for (uint32_t k = 0; k < 64; ++k) At(out)[k] = kSentinel;
    q.Dispatch();
    ps4draw::Flush(true);
    CHECK(ps4draw::GetGuestMemoryStats().fast + ps4draw::GetGuestMemoryStats().sync == s0.fast + s0.sync,
          "the sampling shader took the guest memory path");
    for (uint32_t k = 0; k < 64; ++k) CHECK(At(out)[k] == 0x3F000000u, "before: out[%u] = %08x, want 0.5", k, At(out)[k]);
    // the pass copies 32 texels of red 1.0 over the texture's first 4 rows (B still points at
    // first_dst: the probe reports first_dst's page)
    PutTexels(At(m.src), 0x3C00, 32);
    ps4draw::NotifyGuestWrite(m.src, 256, false, 0);
    const ps4draw::GuestMemoryStats s1 = ps4draw::GetGuestMemoryStats();
    m.Dispatch(tex, 64);
    ps4draw::ComputeBarrier(ps4draw::kQueueGfx);
    for (uint32_t k = 0; k < 64; ++k) At(out)[k] = kSentinel;
    q.Dispatch();
    ps4draw::Flush(true);
    const ps4draw::GuestMemoryStats s2 = ps4draw::GetGuestMemoryStats();
    CHECK(s2.fast == s1.fast + 1 && s2.reruns == s1.reruns && s2.mispredicted == s1.mispredicted + 1,
          "texture writer: fast %llu re-runs %llu mispredicted %llu, want 1 0 1", (unsigned long long)(s2.fast - s1.fast),
          (unsigned long long)(s2.reruns - s1.reruns), (unsigned long long)(s2.mispredicted - s1.mispredicted));
    CHECK(At(tex)[2 * 18] == 0x3C00u, "the pass did not write the texture: %08x", At(tex)[2 * 18]);
    for (uint32_t k = 0; k < 64; ++k) CHECK(At(out)[k] == 0x3F800000u, "after: out[%u] = %08x, want 1.0", k, At(out)[k]);
}

// The result of a fast dispatch whose pass wrote outside its prediction becomes final while
// another thread holds the texture cache's lock. The cache holds it while it waits for the GPU
// (readbacks); a ticket listener that needed it there would never let the GPU go on.
void TestResultFinalWhileTextureCacheLocked() {
    const StoreThenLoad m{0x01C00000, 0x02900000, kDst + 0x2400000, kSrc + 0x2400000, kSrc + 0x2500000, 0x5CA1AB1E0000D00Full};
    const uint64_t first_dst = kDst + 0x2500000, second_dst = kDst + 0x2600000;
    PutVsharp(At(m.b), first_dst, 4, 64, 0x20024004u);
    for (uint32_t k = 0; k < 64; ++k) At(m.src)[k] = 0xE5000000u | k, At(second_dst)[k] = kSentinel;
    m.Dispatch(first_dst, 64); // learning run (sync path)
    ps4draw::Flush(true);
    // what the next dispatch reads is in place (and the renderer told) before the lock is held
    PutVsharp(At(m.n), second_dst, 4, 64, 0x20024004u);
    ps4draw::NotifyGuestWrite(m.n, 16, false, 0);
    std::vector<uint32_t> regs = BaseComputeRegs();
    regs[0x2E0C] = uint32_t(m.code_at >> 8);
    regs[0x2E12] = 1 | (2 << 6);
    regs[0x2E13] = 2 << 1 | 1 << 7;
    regs[0x2E40] = uint32_t(m.table);
    const ps4draw::GuestMemoryStats s0 = ps4draw::GetGuestMemoryStats();
    std::atomic<int> phase{0}; // 1: the lock is held, 2: released
    std::thread holder([&] {
        ps4draw::TestHoldTextureCacheLock(true);
        phase = 1;
        std::this_thread::sleep_for(std::chrono::seconds(2));
        phase = 2;
        ps4draw::TestHoldTextureCacheLock(false);
    });
    while (phase.load() == 0) usleep(100);
    ps4draw::Dispatch(&g_ctx, regs.data(), 1, 1, 1, 0, "gfx", ps4draw::kQueueGfx); // fast; writes second_dst
    ps4draw::Flush(false);
    const auto t0 = std::chrono::steady_clock::now();
    int final_in = -1; // the phase in which the result became final
    while (std::chrono::steady_clock::now() - t0 < std::chrono::seconds(4)) {
        const int ph = phase.load();
        if (ps4draw::GetGuestMemoryStats().final_ticket > s0.final_ticket) {
            final_in = ph;
            break;
        }
        usleep(200);
    }
    holder.join();
    CHECK(final_in == 1, "the result became final %s", final_in < 0 ? "not at all" : "only after the texture cache's lock was released");
    ps4draw::Flush(true);
    const ps4draw::GuestMemoryStats s1 = ps4draw::GetGuestMemoryStats();
    CHECK(s1.fast == s0.fast + 1 && s1.mispredicted == s0.mispredicted + 1, "fast %llu mispredicted %llu, want 1 1",
          (unsigned long long)(s1.fast - s0.fast), (unsigned long long)(s1.mispredicted - s0.mispredicted));
    CheckFilled(second_dst, 0xE5000000u, "while the texture cache was locked");
}

// A missed fast dispatch is re-run without any further work from the CP (PS4_GNM_SYNC_ENCODE:
// no encoder thread; the CP thread may wait for the guest a long time): the GPU, held at the
// dispatch's 2t, goes on.
void TestRerunWithoutFurtherWork() {
    const Entry e0{0x60000000, kDst + 0x2300000, 24, 24, 24};
    PrepareCopy({e0}, false);
    const ps4draw::GuestMemoryStats before = ps4draw::GetGuestMemoryStats();
    ps4draw::Dispatch(&g_ctx, g_regs.data(), 1, 1, 1, 0, "gfx", ps4draw::kQueueGfx);
    ps4draw::Flush(false); // committed; nothing waits for it
    const auto t0 = std::chrono::steady_clock::now();
    uint64_t reruns = before.reruns;
    while (std::chrono::steady_clock::now() - t0 < std::chrono::seconds(3) && reruns == before.reruns) {
        usleep(1000);
        reruns = ps4draw::GetGuestMemoryStats().reruns;
    }
    CHECK(ps4draw::GetGuestMemoryStats().fast == before.fast + 1, "not on the fast path");
    CHECK(reruns == before.reruns + 1, "the missed dispatch was not re-run within 3 s (%llu)",
          (unsigned long long)(reruns - before.reruns));
    ps4draw::Flush(true);
    CheckCopy(e0, 0, "re-run without further work");
}

// ---- Separate runs (the renderer gives up on the GPU in them) ----
// The CP waits for a fast dispatch whose result never becomes final (TestWithholdNextTicket):
// after the GPU timeout it gives up on the GPU (Hung) and goes on, instead of waiting forever.
void TestCpWaitGivesUp() {
    const uint64_t right_src = kSrc + 0xC00000, right_dst = kDst + 0xC00000;
    const CopyThenPlain cp(kDst + 0xB00000, kSrc + 0xB00000, 0x01200000, 0x5CA1AB1E0000D005ull);
    CopyThenPlain::Fill(right_src, right_dst, 0xF1000000u);
    cp.Copy(right_src, right_dst, true);
    ps4draw::ComputeBarrier(ps4draw::kQueueGfx);
    cp.Plain();
    CHECK(!ps4draw::Hung(), "hung before the test");
    ps4draw::TestWithholdNextTicket();
    cp.Copy(right_src, right_dst, false);
    ps4draw::ComputeBarrier(ps4draw::kQueueGfx);
    const auto t0 = std::chrono::steady_clock::now();
    cp.Plain(false); // the CP waits for the withheld copy
    const double s = std::chrono::duration<double>(std::chrono::steady_clock::now() - t0).count();
    CHECK(ps4draw::Hung(), "the CP went on without giving up on the GPU (%.2f s)", s);
    CHECK(s < 10, "the CP waited %.2f s", s);
}

// Command buffers after a fast dispatch whose result never becomes final cannot complete: the
// throttle of outstanding command buffers gives up on the GPU after the GPU timeout instead of
// waiting forever.
void TestThrottleGivesUp() {
    const uint64_t right_src = kSrc + 0xC00000, right_dst = kDst + 0xC00000;
    const CopyThenPlain cp(kDst + 0xB00000, kSrc + 0xB00000, 0x01200000, 0x5CA1AB1E0000D005ull);
    CopyThenPlain::Fill(right_src, right_dst, 0xF1000000u);
    cp.Copy(right_src, right_dst, true);
    cp.Plain();
    ps4draw::TestWithholdNextTicket();
    cp.Copy(right_src, right_dst, false);
    const auto t0 = std::chrono::steady_clock::now();
    int n = 0;
    for (; n < 100 && !ps4draw::Hung(); ++n) {
        cp.Plain(false); // no barrier: the CP does not wait; each in its own command buffer
        ps4draw::Flush(false);
    }
    const double s = std::chrono::duration<double>(std::chrono::steady_clock::now() - t0).count();
    CHECK(ps4draw::Hung(), "100 command buffers behind the withheld dispatch, not hung (%.2f s)", s);
    CHECK(n > 20, "gave up after %d command buffers", n);
    CHECK(s < 10, "took %.2f s", s);
}

// The same with fast dispatches only: each command buffer starts with a fast copy, so the throttle
// is met while a fast dispatch is about to be encoded. It must wait (and give up) with the
// encoder's state free before the dispatch's encoding starts (a chain member being encoded while
// the state is free aborts: GmCheckUnlockable).
void TestFastThrottleGivesUp() {
    const uint64_t right_src = kSrc + 0xC00000, right_dst = kDst + 0xC00000;
    const CopyThenPlain cp(kDst + 0xB00000, kSrc + 0xB00000, 0x01200000, 0x5CA1AB1E0000D005ull);
    CopyThenPlain::Fill(right_src, right_dst, 0xF1000000u);
    cp.Copy(right_src, right_dst, true); // learns its page (sync path)
    ps4draw::TestWithholdNextTicket();
    const auto t0 = std::chrono::steady_clock::now();
    int n = 0;
    for (; n < 100 && !ps4draw::Hung(); ++n) {
        cp.Copy(right_src, right_dst, false); // fast, behind the withheld one
        ps4draw::Flush(false);
    }
    const double s = std::chrono::duration<double>(std::chrono::steady_clock::now() - t0).count();
    CHECK(ps4draw::Hung(), "100 fast dispatches behind the withheld one, not hung (%.2f s)", s);
    CHECK(n > 20, "gave up after %d command buffers", n);
    CHECK(s < 10, "took %.2f s", s);
}

// The default mode (no PS4_GNM_GUEST_MEMORY_FAST): every guest memory dispatch is waited for, also
// once its shader's pages are known; the results are the same.
void TestDefaultIsSync() {
    const Entry e0{kSrc, kDst, 24, 24, 24};
    const Entry e1{kSrc + 0x100000, kDst + 0x100000, 12, 16, 16};
    const ps4draw::GuestMemoryStats s0 = ps4draw::GetGuestMemoryStats();
    for (int i = 0; i < 3; ++i) {
        Run({e0, e1}, false);
        CheckCopy(e0, 0, "default mode");
        CheckCopy(e1, 1, "default mode");
    }
    const ps4draw::GuestMemoryStats s1 = ps4draw::GetGuestMemoryStats();
    CHECK(s1.sync == s0.sync + 3 && s1.fast == s0.fast, "default mode: sync %llu fast %llu, want 3 0",
          (unsigned long long)(s1.sync - s0.sync), (unsigned long long)(s1.fast - s0.fast));
}

// On Metal 4: the guest residency set holds no more than the live windows and arena chunks once
// the GPU is idle and a seq after the last drop completed (dropped windows left their set). A drop
// waits for the open seq: the copy run here commits it (and re-creates its windows).
void CheckGuestResidency(const Entry& e, const char* what) {
    Run({e}, false);
    CheckCopy(e, 0, what);
    auto* be = static_cast<ps4gnm::GnmBackend*>(ps4_gnm_debug_backend());
    CHECK(be != nullptr, "no backend");
    if (!be || be->Kind() != ps4gnm::GnmBackendKind::Metal4) return;
    auto& m4 = static_cast<ps4gnm::Metal4Backend&>(*be);
    m4.Residency().Retire(m4.CompletedSeq());
    const uint32_t windows = ps4_gnm_debug_window_count(), chunks = ps4_gnm_debug_arena_chunks();
    const size_t guest = m4.Residency().Count(ps4gnm::GnmResidencyClass::Guest);
    CHECK(guest <= windows + chunks, "%s: guest residency %zu > live windows %u + arena chunks %u: dropped windows stayed resident",
          what, guest, windows, chunks);
}

// Windows dropped and re-created many times while dispatches use them, on each backend:
// - remaps of their guest memory (the source's and the destination's 64 MiB windows, after every
//   copy but the one before a pause);
// - the idle sweep (PS4_GNM_GPU_WINDOW_IDLE_S=1): every 40 copies the windows sit idle for 1.2 s,
//   then a command buffer that binds no window (a GPU fill of an arena chunk) commits and its sweep
//   releases them (counted). A guest memory dispatch would not do: it reaches every window through
//   the guest page table, which counts as a use of each;
// - drops while a seq that used the window is in flight (TestInflightDrops).
// Every copy is right (a re-created window is a new no-copy buffer: on Metal 4 it must be in a
// residency set before its dispatch, and a dropped one must stay in it until the seqs that may use
// it completed, or their copies are lost), and every 40 copies the guest residency set is checked
// (CheckGuestResidency), whatever the copies gave.
void TestRemapSweepStress() {
    const Entry e{kSrc, kDst, 24, 24, 24};
    uint64_t swept = 0;
    for (int i = 0; i < 200; ++i) {
        Run({e}, false);
        CheckCopy(e, 0, "remap stress");
        if (i % 40 != 39) {
            ps4_gnm_guest_remapped(kSrc & ~((64ull << 20) - 1), 64ull << 20);
            ps4_gnm_guest_remapped(kDst & ~((64ull << 20) - 1), 64ull << 20);
            continue;
        }
        // the windows go idle; the sweep at the next commit (over a second later, binding none of
        // them) releases them
        usleep(1200 * 1000);
        const uint32_t live = ps4_gnm_debug_window_count();
        const uint64_t r0 = ps4_gnm_debug_sweep_released();
        std::vector<uint8_t> fill;
        CHECK(ps4draw::DebugArenaGpuFill(0x5A, 16, &fill) && fill.size() == 16 && fill[0] == 0x5A, "the GPU fill");
        const uint64_t r = ps4_gnm_debug_sweep_released() - r0;
        CHECK(live >= 3 && r == live, "iteration %d: the idle sweep released %llu of %u idle windows", i,
              (unsigned long long)r, live);
        swept += r;
        CheckGuestResidency(e, "remap stress, residency after a sweep");
    }
    printf("gnm_guest_memory_test remap: the idle sweep released %llu windows; %u windows live at the end\n",
           (unsigned long long)swept, ps4_gnm_debug_window_count());
}

// Windows dropped by a remap while a seq that used them has not run yet; the GPU is held by a
// gate (DebugGpuWait) until the drops are done, so "in flight" does not depend on timing.
// - committed: copy 1 is committed (Flush(false)) behind the gate, the windows are remapped, copy 2
//   (same windows: new buffers) drops the old ones while copy 1 waits;
// - open: copy 1 is encoded into the open command buffer, the windows are remapped, copy 2 drops
//   them within the same command buffer.
// Each copy has its own table and destination, so a lost copy shows. Then on Metal 4 the residency
// check as above.
void TestInflightDrops() {
    auto* be = static_cast<ps4gnm::GnmBackend*>(ps4_gnm_debug_backend());
    CHECK(be != nullptr, "no backend");
    if (!be) return;
    constexpr uint64_t kTable2 = kTable + 0x1000;
    for (int round = 0; round < 20; ++round) {
        const bool committed = round % 2 == 0;
        const Entry e1{kSrc + 0x300000, kDst + 0x300000, 24, 24, 24};
        const Entry e2{kSrc + 0x400000, kDst + 0x400000, 20, 20, 20};
        id<MTLSharedEvent> gate = [be->Device() newSharedEvent];
        ps4draw::DebugGpuWait((__bridge void*)gate, 1); // the GPU work encoded from now on waits
        PrepareCopy({e1}, false);
        ps4draw::Dispatch(&g_ctx, g_regs.data(), 1, 1, 1, 0, "gfx", ps4draw::kQueueGfx);
        if (committed) ps4draw::Flush(false);
        ps4_gnm_guest_remapped(kSrc & ~((64ull << 20) - 1), 64ull << 20);
        ps4_gnm_guest_remapped(kDst & ~((64ull << 20) - 1), 64ull << 20);
        PrepareCopy({e2}, false, true, kTable2); // its GuestBuffer drops the old windows
        ps4draw::Dispatch(&g_ctx, g_regs.data(), 1, 1, 1, 0, "gfx", ps4draw::kQueueGfx);
        ps4draw::Flush(false);
        gate.signaledValue = 1;
        ps4draw::Flush(true);
        g_regs[0x2E40] = uint32_t(kTable);
        const char* what = committed ? "drop under a committed seq" : "drop under the open seq";
        CheckCopy(e1, 0, what);
        CheckCopy(e2, 0, what);
    }
    CheckGuestResidency(Entry{kSrc, kDst, 24, 24, 24}, "residency after in-flight drops");
}

void OnAlarm(int) {
    static const char msg[] = "gnm_guest_memory_test: FAIL a wait did not end (60 s)\n";
    (void)!write(2, msg, sizeof(msg) - 1);
    _exit(1);
}

} // namespace

int main(int argc, char** argv) {
    @autoreleasepool {
        if (argc < 2) {
            fprintf(stderr, "usage: gnm_guest_memory_test <local fixture dir> [mode]\n");
            return 2;
        }
        const std::string missing = MissingFixture(argv[1]);
        const bool copy_shader = missing.empty();
        if (copy_shader && !Load(argv[1])) {
            fprintf(stderr, "gnm_guest_memory_test: FAIL %s/u4_cs_copy.* is not the expected copy shader\n", argv[1]);
            return 1;
        }
        setenv("PS4_GNM_SYNC_ENCODE", "1", 1);
        setenv("PS4_GNM_SYNC_COMPILE", "1", 1);
        setenv("PS4_GNM_NO_SHADER_CACHE", "1", 1);
        setenv("PS4_GNM_NO_PSO_ARCHIVE", "1", 1);
        setenv("PS4_GNM_NO_LIB_STORE", "1", 1);
        setenv("PS4_GNM_MEM_LOG", "0", 1);
        const std::string mode = argc > 2 ? argv[2] : "";
        // the fast path is opt-in (PS4_GNM_GUEST_MEMORY_FAST=1): every mode but "default" tests it
        if (mode != "default") setenv("PS4_GNM_GUEST_MEMORY_FAST", "1", 1);
        else unsetenv("PS4_GNM_GUEST_MEMORY_FAST");
        if (mode == "default") {
        } else if (mode == "remap") {
            setenv("PS4_GNM_GPU_WINDOW_IDLE_S", "1", 1); // the sweep releases windows idle for a second
            signal(SIGALRM, OnAlarm);
            alarm(60);
        } else if (!mode.empty()) {
            if (mode != "hang-cp" && mode != "hang-throttle" && mode != "hang-fast-throttle") {
                fprintf(stderr, "gnm_guest_memory_test: unknown mode %s\n", mode.c_str());
                return 2;
            }
            setenv("PS4_GNM_GPU_TIMEOUT", "300", 1);
            signal(SIGALRM, OnAlarm);
            alarm(60);
        }
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
        // default, remap and every hang-* run dispatch the copy shader; they skip after Init, so
        // the renderer's backend line is in their output
        if (!mode.empty() && !copy_shader) {
            PrintSkip(mode.c_str(), missing);
            printf("gnm_guest_memory_test %s: SKIP (needs a local fixture)\n", mode.c_str());
            return 0;
        }
        if (mode == "default") {
            TestDefaultIsSync();
            if (g_fail) {
                fprintf(stderr, "gnm_guest_memory_test default: %d failure(s)\n", g_fail);
                return 1;
            }
            printf("gnm_guest_memory_test default: PASS\n");
            return 0;
        }
        if (mode == "remap") {
            TestRemapSweepStress();
            TestInflightDrops();
            if (g_fail) fprintf(stderr, "gnm_guest_memory_test remap: %d failure(s)\n", g_fail);
            else printf("gnm_guest_memory_test remap: PASS\n");
            fflush(stdout);
            fflush(stderr);
            _exit(g_fail ? 1 : 0);
        }
        if (!mode.empty()) {
            // the GPU stays held behind the withheld result: leave without tearing Metal down
            if (mode == "hang-cp") TestCpWaitGivesUp();
            else if (mode == "hang-throttle") TestThrottleGivesUp();
            else TestFastThrottleGivesUp();
            if (g_fail) fprintf(stderr, "gnm_guest_memory_test %s: %d failure(s)\n", mode.c_str(), g_fail);
            else printf("gnm_guest_memory_test %s: PASS\n", mode.c_str());
            fflush(stdout);
            fflush(stderr);
            _exit(g_fail ? 1 : 0);
        }
        // a case that dispatches the copy shader (needs the fixture) or only hand-assembled ones
        struct Case {
            const char* name;
            void (*run)();
            bool copy;
        };
        static const Case kCases[] = {
            {"copy", TestCopy, true},
            {"steady_state", TestSteadyState, true},
            {"miss_rerun", TestMissRerun, true},
            {"store_range_check", TestStoreRangeCheck, true},
            {"unsupported_format", TestUnsupportedFormat, true},
            {"null_destination", TestNullDestination, true},
            {"dword_offen_stride0", TestDwordOffenStride0, false},
            {"dst_sel", TestDstSel, false},
            {"chained_probe", TestChainedProbe, false},
            {"early_out_has_no_effect", TestEarlyOutHasNoEffect, false},
            {"cp_waits_for_fast_dispatch", TestCpWaitsForFastDispatch, true},
            {"compute_queue_visibility", TestComputeQueueVisibility, true},
            {"new_shader_after_fast_copy", TestNewShaderAfterFastCopy, true},
            {"mispredicted_write_is_ordered", TestMispredictedWriteIsOrdered, true},
            {"pass_writes_outside_probe", TestPassWritesOutsideProbe, false},
            {"pass_writes_sampled_texture", TestPassWritesSampledTexture, false},
            {"result_final_while_texture_cache_locked", TestResultFinalWhileTextureCacheLocked, false},
            {"chained_miss", TestChainedMiss, false},
            {"sampled_image", TestSampledImage, false},
            {"rerun_without_further_work", TestRerunWithoutFurtherWork, true},
        };
        int run = 0, skipped = 0;
        for (const Case& c : kCases) {
            if (c.copy && !copy_shader) {
                PrintSkip(c.name, missing);
                skipped++;
                continue;
            }
            c.run();
            run++;
        }
        if (g_fail) {
            fprintf(stderr, "gnm_guest_memory_test: %d failure(s)\n", g_fail);
            return 1;
        }
        if (skipped) printf("gnm_guest_memory_test: PASS (%d cases run, %d skipped)\n", run, skipped);
        else printf("gnm_guest_memory_test: PASS\n");
        return 0;
    }
}
