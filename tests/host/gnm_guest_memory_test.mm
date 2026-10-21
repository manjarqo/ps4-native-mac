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
//    nothing is written.
//
// usage: gnm_guest_memory_test <dir with the fixtures>
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>

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
    }
    memcpy(g_mem + kCode, code.data(), code.size());
    memset(g_mem + kTable, 0, 512);
    At(kTable)[72] = uint32_t(entries.size());
    for (size_t i = 0; i < entries.size(); ++i) {
        const Entry& e = entries[i];
        PutVsharp(At(kTable + 16 * i), e.src, 4, e.src_records, 0x20024004u);
        PutVsharp(At(kTable + 128 + 16 * i), e.dst, 4, e.dst_records, e.dst_dword3);
        At(kTable + 256)[i] = e.count;
        for (uint32_t k = 0; k < 64; ++k) {
            At(e.src)[k] = 0xA5000000u | uint32_t(i << 16) | k;
            At(e.dst)[k] = kSentinel;
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
        if (g_fail) {
            fprintf(stderr, "gnm_guest_memory_test: %d failure(s)\n", g_fail);
            return 1;
        }
        printf("gnm_guest_memory_test: PASS\n");
        return 0;
    }
}
