// T# tables a compute shader indexes at run time, run through the real renderer
// (ps4draw::Dispatch: translation, SRT walker, texture cache, binding, dispatch on Metal).
// Hand-assembled compute shaders; each workgroup w:
//   s_buffer_load_dword L from index buffer A at dword w (A: 0 1 1 0 2 7)
//   T# = 8 dwords at byte 0x40 + 48 * L of a table, read
//     (records) with s_buffer_load_dwordx8 through the table's V# (bytes 0..0xD0: 3 records),
//     (srt)     with s_load_dwordx8 through an SRT pointer (no bound but the index buffer's),
//   image_sample_lz at the centre with a static S# (or image_load_mip of texel (0, 0) level 0),
//   buffer_store_dwordx4 of the result at byte 16 * w of an output buffer.
// The table's record 0 is an 8x8 red texture, record 1 a blue one, record 2 holds no T# (it
// decodes as a non-square cube: no Metal texture can be made of it), and in the SRT pointer
// table record 7 is a green texture. GCN semantics: L = 7 reads past the V#'s num_records, an
// all-zero T# (the null image, 0); through an SRT pointer s_load has no bound, so it reads
// record 7. Before T# tables the translator bound the null image to every such read (all 0).
// The translation is also checked directly (libgcn_recompiler): one table, its kind, its entries
// as images of the table, the copied T#s, and no null image reads.
// Loop: a shader sums image_sample_lz over the SRT pointer table's records k = 0 .. N - 1 (a
// do-while, N in user data): with N = 3 the entries bound are records 0..3 (bucket 4), record 3 is
// not reached and stays empty although it holds a T#; with N = 5 the dispatch needs 8 entries,
// another permutation (the bucket is part of the specialization), and record 3 (green) is summed.
// Hazard: a compute shader writes a new T# into a table record and the next dispatch, in the same
// submission, reads the table: its SRT copy was made before the GPU wrote the record, so the
// encoder drains the GPU and copies again (the sample sees the new texture).
// The same with the writer on the asynchronous compute queue ("async-compute"): the graphics wait
// for its label joins the queues, and the reader still copies the table after the write.
// Address check: a table record holding a well-formed T# of an address inside a free VM extent
// is unbound (0 is read, not the texture in the host memory behind it) and counts as unmapped; one
// in memory without an extent (module images) or in a PROT_NONE extent is bound; mapping the free
// address makes the next dispatch bind it.
// Hazards are judged by what was pending when the CP copied the tables, not when the pass is
// encoded: a CP DMA pending at the copy, also in a captured frame (whose passes start encoding
// with the GPU drained); a draw whose VS and PS read the same written table (one check for the
// draw re-reads both stages); with the encoder thread, a second reader encoded after the first
// one's drain.
//
// usage: gnm_tsharp_table_test [capture|async]
//   (none): every test except those of the two modes, with PS4_GNM_SYNC_ENCODE
//   capture: the CP DMA hazard in captured frame 0 (PS4_GNM_CAPTURE_FRAME, temporary directory)
//   async: the second-reader hazard with the encoder thread
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <pthread.h>
#include <sys/mman.h>
#include <unistd.h>

#include <array>
#include <filesystem>
#include <atomic>
#include <chrono>
#include <string>
#include <vector>

#include "gcn_recompiler.h"
#include "ps4_gnm_draw.h"
#include "ps4_gnm_resources.h"

namespace {

int g_fail = 0;
#define CHECK(c, ...)                                                                    \
    do {                                                                                 \
        if (!(c)) {                                                                      \
            fprintf(stderr, "gnm_tsharp_table_test: FAIL %s:%d: ", __FILE__, __LINE__); \
            fprintf(stderr, __VA_ARGS__);                                                \
            fprintf(stderr, "\n");                                                       \
            g_fail++;                                                                    \
        }                                                                                \
    } while (0)

constexpr uint64_t kMemSize = 1ull << 32;
constexpr uint64_t kCode = 0x01000000;
constexpr uint64_t kIndex = 0x02000000;  // index buffer A
constexpr uint64_t kTable = 0x02100000;  // table behind a V# (3 records)
constexpr uint64_t kSrt = 0x02200000;    // table behind an SRT pointer (8 records)
constexpr uint64_t kOut = 0x02300000;
constexpr uint64_t kTex[3] = {0x03000000, 0x03100000, 0x03200000}; // red, blue, green
constexpr uint32_t kRecordBytes = 48, kTableFirst = 0x40;
constexpr uint32_t kIndices[6] = {0, 1, 1, 0, 2, 7};
constexpr uint32_t kSentinel = 0xCDCDCDCDu;

uint8_t* g_mem = nullptr;
GuestContext g_ctx;

uint32_t* At(uint64_t addr) { return reinterpret_cast<uint32_t*>(g_mem + addr); }

bool ReadGuest(void*, uint64_t addr, void* dst, uint64_t size) {
    if (addr == 0 || addr + size > kMemSize) return false;
    memcpy(dst, g_mem + addr, size);
    return true;
}

namespace gcn {
uint32_t Smrd(uint32_t op, uint32_t sdst, uint32_t sbase, uint32_t soff) { // byte offset in an SGPR
    return 0xC0000000u | op << 22 | sdst << 15 | (sbase / 2) << 9 | soff;
}
uint32_t Sop2(uint32_t op, uint32_t sdst, uint32_t ssrc0, uint32_t ssrc1) {
    return 0x80000000u | op << 23 | sdst << 16 | ssrc1 << 8 | ssrc0;
}
uint32_t Vop1(uint32_t op, uint32_t vdst, uint32_t src0) { return 0x7E000000u | vdst << 17 | op << 9 | src0; }
uint32_t VLshlrev(uint32_t vdst, uint32_t src0, uint32_t vsrc1) { return 26u << 25 | vdst << 17 | vsrc1 << 9 | src0; }
void Mimg(std::vector<uint32_t>& c, uint32_t op, uint32_t vaddr, uint32_t vdata, uint32_t srsrc, uint32_t ssamp) {
    c.push_back(0xF0000000u | op << 18 | 0xFu << 8); // dmask xyzw
    c.push_back(vaddr | vdata << 8 | (srsrc / 4) << 16 | (ssamp / 4) << 21);
}
void Mubuf(std::vector<uint32_t>& c, uint32_t op, bool offen, uint32_t vaddr, uint32_t vdata, uint32_t srsrc,
           uint32_t offset = 0) {
    c.push_back(0xE0000000u | op << 18 | uint32_t(offen) << 12 | offset);
    c.push_back(0x80u << 24 | (srsrc / 4) << 16 | vdata << 8 | vaddr); // soffset 0
}
constexpr uint32_t V(uint32_t n) { return 0x100 + n; }
constexpr uint32_t kWait = 0xBF8C0000u, kEnd = 0xBF810000u, kLiteral = 0xFF;
constexpr uint32_t kSAddU32 = 0, kSLshlB32 = 30, kSMulI32 = 38;
constexpr uint32_t kSLoadX8 = 3, kSBufLoad = 8, kSBufLoadX8 = 11;
constexpr uint32_t kVMov = 1, kImageLoadMip = 1, kImageSampleLz = 39, kLoadDwordx4 = 14, kStoreDwordx4 = 30;
constexpr uint32_t kVAddF32 = 3;
uint32_t Vop2(uint32_t op, uint32_t vdst, uint32_t src0, uint32_t vsrc1) { return op << 25 | vdst << 17 | vsrc1 << 9 | src0; }
uint32_t SMovB32(uint32_t sdst, uint32_t ssrc0) { return 0xBE800300u | sdst << 16 | ssrc0; }
uint32_t SCmpLtU32(uint32_t ssrc0, uint32_t ssrc1) { return 0xBF0A0000u | ssrc1 << 8 | ssrc0; }
uint32_t SCbranchScc1(int16_t dwords) { return 0xBF850000u | uint16_t(dwords); }
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

enum class Form { Records, Srt };
enum class Op { Sample, LoadMip };

// User data: s[0:3] V# of A, s[4:7] V# of the table (Records) or s[4:5] the SRT pointer,
// s[8:11] V# of the output, s[12:15] S# (all zero: wrap, point filters); s16 = workgroup id.
std::vector<uint32_t> Program(Form form, Op op) {
    using namespace gcn;
    std::vector<uint32_t> c;
    c.push_back(Sop2(kSLshlB32, 17, 16, 0x82));                          // s17 = w * 4
    c.push_back(Smrd(kSBufLoad, 18, 0, 17));                             // s18 = A[w] = L
    c.push_back(kWait);
    c.push_back(Sop2(kSMulI32, 19, 18, 0x80 + kRecordBytes));            // s19 = L * 48
    c.push_back(Sop2(kSAddU32, 19, 19, 0x80 + kTableFirst));             // s19 += 0x40
    c.push_back(form == Form::Records ? Smrd(kSBufLoadX8, 20, 4, 19)     // T# s[20:27]
                                      : Smrd(kSLoadX8, 20, 4, 19));
    c.push_back(kWait);
    if (op == Op::Sample) {
        c.push_back(Vop1(kVMov, 0, kLiteral));
        c.push_back(0x3F000000u); // v0 = 0.5
        c.push_back(Vop1(kVMov, 1, kLiteral));
        c.push_back(0x3F000000u); // v1 = 0.5
        Mimg(c, kImageSampleLz, 0, 2, 20, 12);
    } else {
        c.push_back(Vop1(kVMov, 6, 0x80)); // x, y, level 0
        c.push_back(Vop1(kVMov, 7, 0x80));
        c.push_back(Vop1(kVMov, 8, 0x80));
        Mimg(c, kImageLoadMip, 6, 2, 20, 0);
    }
    c.push_back(kWait);
    c.push_back(Vop1(kVMov, 9, 16));      // v9 = w
    c.push_back(VLshlrev(9, 0x84, 9));    // v9 = w * 16
    Mubuf(c, kStoreDwordx4, true, 9, 2, 8);
    c.push_back(kEnd);
    const uint64_t hash = 0x5CA1AB1E00007000ull | (form == Form::Srt ? 0x10 : 0) | (op == Op::LoadMip ? 1 : 0);
    return WithFooter(c, hash);
}

// Loop over the SRT pointer table: v[10:13] = sum of image_sample_lz of records k = 0 .. N - 1,
// N = s6 (user data), stored at byte 16 * w.
std::vector<uint32_t> LoopProgram() {
    using namespace gcn;
    std::vector<uint32_t> c;
    c.push_back(SMovB32(17, 0x80)); // k = 0
    for (uint32_t r = 10; r < 14; ++r) c.push_back(Vop1(kVMov, r, 0x80));
    c.push_back(Vop1(kVMov, 0, kLiteral));
    c.push_back(0x3F000000u); // v0 = 0.5
    c.push_back(Vop1(kVMov, 1, kLiteral));
    c.push_back(0x3F000000u); // v1 = 0.5
    const size_t loop = c.size();
    c.push_back(Sop2(kSMulI32, 19, 17, 0x80 + kRecordBytes)); // s19 = k * 48 + 0x40
    c.push_back(Sop2(kSAddU32, 19, 19, 0x80 + kTableFirst));
    c.push_back(Smrd(kSLoadX8, 20, 4, 19));                   // T# s[20:27] through the SRT pointer
    c.push_back(kWait);
    Mimg(c, kImageSampleLz, 0, 2, 20, 12);
    c.push_back(kWait);
    for (uint32_t r = 0; r < 4; ++r) c.push_back(Vop2(kVAddF32, 10 + r, V(2 + r), 10 + r));
    c.push_back(Sop2(kSAddU32, 17, 17, 0x81)); // ++k
    c.push_back(SCmpLtU32(17, 6));             // k < N
    c.push_back(SCbranchScc1(int16_t(int(loop) - int(c.size() + 1))));
    c.push_back(Vop1(kVMov, 9, 16));   // v9 = w
    c.push_back(VLshlrev(9, 0x84, 9)); // v9 = w * 16
    Mubuf(c, kStoreDwordx4, true, 9, 10, 8);
    c.push_back(kEnd);
    return WithFooter(c, 0x5CA1AB1E00007100ull);
}

// Copies 32 bytes from the buffer of V# s[0:3] to the buffer of V# s[4:7] (a T# into a table).
std::vector<uint32_t> CopyProgram() {
    using namespace gcn;
    std::vector<uint32_t> c;
    c.push_back(Vop1(kVMov, 1, 0x80));
    Mubuf(c, kLoadDwordx4, true, 1, 2, 0);
    Mubuf(c, kLoadDwordx4, true, 1, 6, 0, 16);
    c.push_back(kWait);
    Mubuf(c, kStoreDwordx4, true, 1, 2, 4);
    Mubuf(c, kStoreDwordx4, true, 1, 6, 4, 16);
    c.push_back(kEnd);
    return WithFooter(c, 0x5CA1AB1E00007200ull);
}

void PutVsharp(uint32_t* v, uint64_t base, uint32_t bytes) {
    v[0] = uint32_t(base);
    v[1] = uint32_t(base >> 32) & 0xFFF; // stride 0: num_records in bytes
    v[2] = bytes;
    v[3] = 4 | (5 << 3) | (6 << 6) | (7 << 9) | (4 << 12) | (4 << 15); // xyzw, uint, 32
}

// 8x8 RGBA8 unorm, linear aligned (pitch 64 texels, the alignment of that tile mode), 2D
constexpr uint32_t kPitch = 64;
void PutTsharp(uint32_t* t, uint64_t addr) {
    memset(t, 0, 32);
    t[0] = uint32_t(addr >> 8);
    t[1] = 10u << 20;                                                  // 8_8_8_8, unorm
    t[2] = 7 | (7u << 14);                                             // 8 x 8
    t[3] = 4 | (5 << 3) | (6 << 6) | (7 << 9) | (8u << 20) | (9u << 28); // xyzw, linear aligned, 2D
    t[4] = (kPitch - 1) << 13;
}

// No T#: a cube of 64 x 32 (Metal cubes are square). Uncharted 4's unused light records hold
// floats that decode to such T#s.
void PutJunkTsharp(uint32_t* t) {
    PutTsharp(t, kTex[0]);
    t[2] = 63 | (31u << 14);
    t[3] = (t[3] & 0x0FFFFFFFu) | (11u << 28);
}

const uint32_t kColor[3] = {0xFF0000FFu, 0xFFFF0000u, 0xFF00FF00u}; // ABGR: red, blue, green

void Setup() {
    for (int i = 0; i < 3; ++i)
        for (uint32_t k = 0; k < kPitch * 8; ++k) At(kTex[i])[k] = kColor[i];
    memcpy(At(kIndex), kIndices, sizeof(kIndices));
    // the table behind a V#: records 0..2
    memset(At(kTable), 0x5A, 0x200); // bytes past the V#'s num_records hold junk
    PutTsharp(At(kTable + kTableFirst), kTex[0]);
    PutTsharp(At(kTable + kTableFirst + kRecordBytes), kTex[1]);
    PutJunkTsharp(At(kTable + kTableFirst + 2 * kRecordBytes));
    // the table behind an SRT pointer: records 0..7, record 7 green
    memset(At(kSrt), 0, 0x400);
    PutTsharp(At(kSrt + kTableFirst), kTex[0]);
    PutTsharp(At(kSrt + kTableFirst + kRecordBytes), kTex[1]);
    PutJunkTsharp(At(kSrt + kTableFirst + 2 * kRecordBytes));
    PutTsharp(At(kSrt + kTableFirst + 3 * kRecordBytes), kTex[2]); // only the loop with N = 5 reaches it
    PutTsharp(At(kSrt + kTableFirst + 7 * kRecordBytes), kTex[2]);
    ps4draw::NotifyGuestWrite(kIndex, 0x400000, false, 0);
}

constexpr uint32_t kTableBytes = kTableFirst + 3 * kRecordBytes; // 0xD0

std::vector<uint32_t> Regs(Form form, uint64_t code_addr, uint64_t out) {
    std::vector<uint32_t> regs(0x10000, 0);
    regs[0x2E07] = 64; // 64 threads
    regs[0x2E08] = regs[0x2E09] = 1;
    regs[0x2E0C] = uint32_t(code_addr >> 8);
    regs[0x2E12] = 2 | (3 << 6);    // 12 VGPRs, 32 SGPRs
    regs[0x2E13] = 16 << 1 | 1 << 7; // 16 user SGPRs, s16 = workgroup id x
    uint32_t* ud = &regs[0x2E40];
    PutVsharp(ud, kIndex, sizeof(kIndices));
    if (form == Form::Records) {
        PutVsharp(ud + 4, kTable, kTableBytes);
    } else {
        ud[4] = uint32_t(kSrt);
        ud[5] = uint32_t(kSrt >> 32);
    }
    PutVsharp(ud + 8, out, 6 * 16);
    return regs;
}

// Translates the program as the renderer does for this dispatch and checks its T# table.
void CheckTranslation(Form form, Op op, const std::vector<uint32_t>& regs, const std::vector<uint32_t>& code) {
    gcn_profile prof;
    gcn_profile_default_metal(&prof);
    gcn_runtime_info rt;
    gcn_runtime_info_from_regs(regs.data(), regs.size(), GCN_HW_CS, GCN_SW_COMPUTE, &prof, &rt);
    gcn_compile_desc d{};
    d.hw_stage = GCN_HW_CS;
    d.sw_stage = GCN_SW_COMPUTE;
    uint64_t addr = 0;
    gcn_stage_from_regs(regs.data(), regs.size(), GCN_HW_CS, &addr, d.user_data);
    d.code_addr = addr;
    d.code = code.data();
    d.code_size = uint32_t(code.size() * 4);
    d.runtime = &rt;
    d.profile = &prof;
    d.read_guest = ReadGuest;
    d.flags = GCN_COMPILE_EMIT_MSL;
    gcn_shader* sh = nullptr;
    char err[512] = {};
    CHECK(gcn_compile(&d, &sh, err, sizeof(err)) == GCN_OK && sh, "does not translate: %s", err);
    if (!sh) return;
    gcn_shader_info info{};
    gcn_shader_get_info(sh, &info);
    CHECK(info.null_image_reads == 0, "%u image reads of the null image", info.null_image_reads);
    CHECK(info.num_image_tables == 1, "%u T# tables", info.num_image_tables);
    gcn_image_table t{};
    if (gcn_shader_get_image_table(sh, 0, &t)) {
        if (form == Form::Records) {
            // the V# bounds it: 3 records reached, 4 bound (bucket)
            CHECK(t.kind == GCN_IMAGE_TABLE_RECORDS && t.num_entries == 4 && t.reached == 3,
                  "table kind %u, %u entries, %u reached", t.kind, t.num_entries, t.reached);
        } else {
            // the index buffer bounds it: its records hold the distinct indices 1, 2, 7, and 0
            // (an index read past it): 4 entries
            CHECK(t.kind == GCN_IMAGE_TABLE_INDEXED && t.num_entries == 4 && t.reached == 4,
                  "table kind %u, %u entries, %u reached", t.kind, t.num_entries, t.reached);
        }
        CHECK(t.first_dw == kTableFirst / 4 && t.stride_dw == kRecordBytes / 4 && t.num_dwords == 8 && t.num_sites == 1,
              "table dword %u + %u * index, %u dwords, %u sites", t.first_dw, t.stride_dw, t.num_dwords, t.num_sites);
    }
    // the entries are images of the table; their T#s are the records the draw reaches
    std::vector<uint32_t> flat(info.flatbuf_size_dw);
    CHECK(gcn_shader_build_flatbuf(sh, d.user_data, ReadGuest, nullptr, flat.data(), flat.size()), "flatbuf");
    uint32_t entries = 0;
    for (uint32_t i = 0; i < info.num_images; ++i) {
        gcn_image_binding b{};
        gcn_shader_get_image(sh, i, &b);
        if (b.table == UINT32_MAX) continue;
        entries++;
        uint32_t tsharp[8] = {};
        const bool fetched = gcn_shader_fetch_image_sharp(sh, i, flat.data(), tsharp);
        // the record entry k holds (Records: k; Indexed: the distinct indices of A, 0 first)
        const uint32_t k = b.table_entry;
        constexpr uint32_t kDistinct[4] = {0, 1, 2, 7};
        const uint32_t record = form == Form::Records ? k : (k < 4 ? kDistinct[k] : ~0u);
        const uint64_t src = (form == Form::Records ? kTable : kSrt) + kTableFirst + record * kRecordBytes;
        const bool in_table = form == Form::Srt || kTableFirst + record * kRecordBytes < kTableBytes;
        if (record == 2) {
            CHECK(!fetched, "entry %u (no T#: a non-square cube) was fetched as a T#", k);
        } else if (!in_table) {
            CHECK(!fetched, "entry %u past the table was fetched", k);
        } else {
            CHECK(fetched && memcmp(tsharp, At(src), 32) == 0, "entry %u: T# not the one of record %u", k, record);
        }
    }
    CHECK(entries == t.num_entries, "%u images are table entries, the table has %u", entries, t.num_entries);
    (void)op;
    gcn_shader_destroy(sh);
}

void Run(Form form, Op op, uint64_t code_addr, uint64_t out) {
    const std::vector<uint32_t> code = Program(form, op);
    memcpy(g_mem + code_addr, code.data(), code.size() * 4);
    for (uint32_t k = 0; k < 6 * 4; ++k) At(out)[k] = kSentinel;
    ps4draw::NotifyGuestWrite(code_addr, 0x10000, false, 0);
    ps4draw::NotifyGuestWrite(out, 0x1000, false, 0);
    const std::vector<uint32_t> regs = Regs(form, code_addr, out);
    const uint64_t skipped0 = ps4draw::SkippedCount();
    ps4draw::Dispatch(&g_ctx, regs.data(), 6, 1, 1, 0, "gfx", ps4draw::kQueueGfx);
    ps4draw::Flush(true);
    const char* name = form == Form::Records ? (op == Op::Sample ? "records/sample" : "records/load_mip")
                                             : (op == Op::Sample ? "srt/sample" : "srt/load_mip");
    CHECK(ps4draw::SkippedCount() == skipped0, "%s: the dispatch was skipped", name);
    for (uint32_t w = 0; w < 6; ++w) {
        const uint32_t L = kIndices[w];
        // red / blue / (junk: 0) / past the V#: 0, through an SRT pointer: green
        uint32_t color = 0;
        bool zero = true;
        if (L < 2) color = kColor[L], zero = false;
        if (L == 7 && form == Form::Srt) color = kColor[2], zero = false;
        float want[4] = {0, 0, 0, 0};
        if (!zero)
            for (int c = 0; c < 4; ++c) want[c] = float((color >> (8 * c)) & 0xFF) / 255.0f;
        float got[4];
        memcpy(got, At(out + 16 * w), 16);
        CHECK(memcmp(got, want, 16) == 0, "%s: workgroup %u (L = %u) stored %g %g %g %g, want %g %g %g %g", name, w, L,
              got[0], got[1], got[2], got[3], want[0], want[1], want[2], want[3]);
    }
    CheckTranslation(form, op, regs, code);
}

std::vector<uint32_t> CsRegs(uint64_t code_addr, uint32_t user_sgprs) {
    std::vector<uint32_t> regs(0x10000, 0);
    regs[0x2E07] = 64;
    regs[0x2E08] = regs[0x2E09] = 1;
    regs[0x2E0C] = uint32_t(code_addr >> 8);
    regs[0x2E12] = 3 | (3 << 6); // 16 VGPRs, 32 SGPRs
    regs[0x2E13] = user_sgprs << 1 | 1 << 7;
    return regs;
}

void Store(float* f, uint32_t color, float scale) {
    for (int c = 0; c < 4; ++c) f[c] += scale * float((color >> (8 * c)) & 0xFF) / 255.0f;
}

void TestLoop() {
    const uint64_t code_addr = kCode + 0x40000, out = kOut + 0x4000;
    const std::vector<uint32_t> code = LoopProgram();
    memcpy(g_mem + code_addr, code.data(), code.size() * 4);
    ps4draw::NotifyGuestWrite(code_addr, 0x10000, false, 0);
    for (const uint32_t n : {3u, 5u}) {
        for (uint32_t k = 0; k < 4; ++k) At(out)[k] = kSentinel;
        ps4draw::NotifyGuestWrite(out, 0x1000, false, 0);
        std::vector<uint32_t> regs = CsRegs(code_addr, 16);
        uint32_t* ud = &regs[0x2E40];
        ud[4] = uint32_t(kSrt);
        ud[5] = uint32_t(kSrt >> 32);
        ud[6] = n;
        PutVsharp(ud + 8, out, 16);
        const ps4draw::ImageTableStats s0 = ps4draw::GetImageTableStats();
        const uint64_t skipped0 = ps4draw::SkippedCount();
        ps4draw::Dispatch(&g_ctx, regs.data(), 1, 1, 1, 0, "gfx", ps4draw::kQueueGfx);
        ps4draw::Flush(true);
        const ps4draw::ImageTableStats s1 = ps4draw::GetImageTableStats();
        CHECK(ps4draw::SkippedCount() == skipped0, "loop N = %u: the dispatch was skipped", n);
        // records 0 red, 1 blue, 2 no T# (0), 3 green, 4 zero
        float want[4] = {0, 0, 0, 0};
        Store(want, kColor[0], 1);
        Store(want, kColor[1], 1);
        if (n == 5) Store(want, kColor[2], 1);
        float got[4];
        memcpy(got, At(out), 16);
        CHECK(memcmp(got, want, 16) == 0, "loop N = %u stored %g %g %g %g, want %g %g %g %g", n, got[0], got[1], got[2],
              got[3], want[0], want[1], want[2], want[3]);
        if (n == 3) {
            // 4 entries: red, blue, the junk record, and record 3 not copied (k = 3 is not reached)
            CHECK(s1.bound - s0.bound == 2 && s1.rejected - s0.rejected == 1 && s1.empty - s0.empty == 1,
                  "loop N = 3 entries: %llu bound, %llu rejected, %llu empty", (unsigned long long)(s1.bound - s0.bound),
                  (unsigned long long)(s1.rejected - s0.rejected), (unsigned long long)(s1.empty - s0.empty));
        } else {
            // 8 entries: red, blue, junk, green, then zero records 4 and the 3 not reached
            CHECK(s1.bound - s0.bound == 3 && s1.rejected - s0.rejected == 1 && s1.empty - s0.empty == 4,
                  "loop N = 5 entries: %llu bound, %llu rejected, %llu empty", (unsigned long long)(s1.bound - s0.bound),
                  (unsigned long long)(s1.rejected - s0.rejected), (unsigned long long)(s1.empty - s0.empty));
        }
        // the translation: a loop table
        gcn_profile prof;
        gcn_profile_default_metal(&prof);
        gcn_runtime_info rt;
        gcn_runtime_info_from_regs(regs.data(), regs.size(), GCN_HW_CS, GCN_SW_COMPUTE, &prof, &rt);
        gcn_compile_desc d{};
        d.hw_stage = GCN_HW_CS;
        d.sw_stage = GCN_SW_COMPUTE;
        uint64_t addr = 0;
        gcn_stage_from_regs(regs.data(), regs.size(), GCN_HW_CS, &addr, d.user_data);
        d.code_addr = addr;
        d.code = code.data();
        d.code_size = uint32_t(code.size() * 4);
        d.runtime = &rt;
        d.profile = &prof;
        d.read_guest = ReadGuest;
        d.flags = GCN_COMPILE_EMIT_MSL;
        gcn_shader* sh = nullptr;
        char err[512] = {};
        CHECK(gcn_compile(&d, &sh, err, sizeof(err)) == GCN_OK && sh, "loop shader does not translate: %s", err);
        if (!sh) continue;
        gcn_image_table t{};
        CHECK(gcn_shader_get_image_table(sh, 0, &t) && t.kind == GCN_IMAGE_TABLE_LOOP &&
                  t.num_entries == (n == 3 ? 4u : 8u) && t.reached == n,
              "loop N = %u: table kind %u, %u entries, %u reached", n, t.kind, t.num_entries, t.reached);
        // a shader compiled for N = 3 does not serve a draw with N = 5
        if (n == 3) {
            std::vector<uint32_t> r5 = regs;
            r5[0x2E40 + 6] = 5;
            uint32_t ud5[16];
            uint64_t a5 = 0;
            gcn_stage_from_regs(r5.data(), r5.size(), GCN_HW_CS, &a5, ud5);
            CHECK(!gcn_shader_is_compatible(sh, ud5, &rt, ReadGuest, nullptr),
                  "the N = 3 permutation was found compatible with N = 5");
            CHECK(gcn_shader_is_compatible(sh, d.user_data, &rt, ReadGuest, nullptr),
                  "the N = 3 permutation is not compatible with its own draw");
        }
        gcn_shader_destroy(sh);
    }
}

void TestHazard() {
    // a fresh copy of the V# table, record 0 red; the copy shader writes the blue T# into record 0
    constexpr uint64_t kTable2 = 0x02400000, kNewTsharp = 0x02500000;
    const uint64_t copy_addr = kCode + 0x50000, read_addr = kCode + 0x60000, out = kOut + 0x5000;
    memcpy(At(kTable2), At(kTable), kTableBytes);
    PutTsharp(At(kNewTsharp), kTex[1]);
    const std::vector<uint32_t> copy = CopyProgram(), read = Program(Form::Records, Op::Sample);
    memcpy(g_mem + copy_addr, copy.data(), copy.size() * 4);
    memcpy(g_mem + read_addr, read.data(), read.size() * 4);
    for (uint32_t k = 0; k < 6 * 4; ++k) At(out)[k] = kSentinel;
    ps4draw::NotifyGuestWrite(kTable2, 0x200000, false, 0);
    ps4draw::NotifyGuestWrite(copy_addr, 0x20000, false, 0);
    ps4draw::NotifyGuestWrite(out, 0x1000, false, 0);
    std::vector<uint32_t> cregs = CsRegs(copy_addr, 8);
    PutVsharp(&cregs[0x2E40], kNewTsharp, 32);
    PutVsharp(&cregs[0x2E44], kTable2 + kTableFirst, 32);
    std::vector<uint32_t> rregs = Regs(Form::Records, read_addr, out);
    PutVsharp(&rregs[0x2E44], kTable2, kTableBytes);
    const ps4draw::ImageTableStats s0 = ps4draw::GetImageTableStats();
    ps4draw::Dispatch(&g_ctx, cregs.data(), 1, 1, 1, 0, "gfx", ps4draw::kQueueGfx);
    ps4draw::Dispatch(&g_ctx, rregs.data(), 6, 1, 1, 0, "gfx", ps4draw::kQueueGfx);
    ps4draw::Flush(true);
    const ps4draw::ImageTableStats s1 = ps4draw::GetImageTableStats();
    CHECK(s1.hazard_drains - s0.hazard_drains == 1, "%llu table hazard drains, want 1",
          (unsigned long long)(s1.hazard_drains - s0.hazard_drains));
    CHECK(memcmp(At(kTable2 + kTableFirst), At(kNewTsharp), 32) == 0, "the copy shader did not write the record");
    for (uint32_t w = 0; w < 6; ++w) {
        if (kIndices[w] != 0) continue;
        float want[4] = {0, 0, 0, 0}, got[4];
        Store(want, kColor[1], 1);
        memcpy(got, At(out + 16 * w), 16);
        CHECK(memcmp(got, want, 16) == 0, "hazard: workgroup %u (record 0, rewritten blue) stored %g %g %g %g", w,
              got[0], got[1], got[2], got[3]);
    }
}

// The hazard with asynchronous compute (mode "async-compute", PS4_GNM_ASYNC_COMPUTE=1): the copy
// shader runs on a compute ring (its own queue: eligible, it binds no image), the CP's graphics
// wait for its label joins the queues, and the reading dispatch on the graphics ring sees the
// rewritten record: the table copy is made after the compute work completed (a hazard drain).
void TestHazardCompute() {
    constexpr uint64_t kTable3 = 0x02600000, kNewTsharp = 0x02700000;
    const uint64_t copy_addr = kCode + 0x70000, read_addr = kCode + 0x80000, out = kOut + 0x6000;
    memcpy(At(kTable3), At(kTable), kTableBytes);
    PutTsharp(At(kNewTsharp), kTex[1]);
    const std::vector<uint32_t> copy = CopyProgram(), read = Program(Form::Records, Op::Sample);
    memcpy(g_mem + copy_addr, copy.data(), copy.size() * 4);
    memcpy(g_mem + read_addr, read.data(), read.size() * 4);
    for (uint32_t k = 0; k < 6 * 4; ++k) At(out)[k] = kSentinel;
    ps4draw::NotifyGuestWrite(kTable3, 0x200000, false, 0);
    ps4draw::NotifyGuestWrite(copy_addr, 0x20000, false, 0);
    ps4draw::NotifyGuestWrite(out, 0x1000, false, 0);
    std::vector<uint32_t> cregs = CsRegs(copy_addr, 8);
    PutVsharp(&cregs[0x2E40], kNewTsharp, 32);
    PutVsharp(&cregs[0x2E44], kTable3 + kTableFirst, 32);
    std::vector<uint32_t> rregs = Regs(Form::Records, read_addr, out);
    PutVsharp(&rregs[0x2E44], kTable3, kTableBytes);
    const ps4draw::AsyncComputeCounts c0 = ps4draw::GetAsyncComputeCounts();
    CHECK(c0.on, "asynchronous compute is not on");
    const ps4draw::ImageTableStats s0 = ps4draw::GetImageTableStats();
    ps4draw::Dispatch(&g_ctx, cregs.data(), 1, 1, 1, 0, "asc", ps4draw::kQueueCompute);
    ps4draw::AfterGpu([] {}, ps4draw::kQueueCompute); // the compute label
    ps4draw::FlushCompute();
    // the CP at the graphics WAIT_REG_MEM met by that pending label
    ps4draw::ComputeBarrier(ps4draw::kQueueGfx);
    ps4draw::JoinQueues(ps4draw::kQueueGfx);
    ps4draw::Dispatch(&g_ctx, rregs.data(), 6, 1, 1, 0, "gfx", ps4draw::kQueueGfx);
    ps4draw::Flush(true);
    const ps4draw::AsyncComputeCounts c1 = ps4draw::GetAsyncComputeCounts();
    CHECK(c1.eligible > c0.eligible, "the copy shader did not run on the compute queue");
    const ps4draw::ImageTableStats s1 = ps4draw::GetImageTableStats();
    CHECK(s1.hazard_drains - s0.hazard_drains == 1, "%llu table hazard drains, want 1",
          (unsigned long long)(s1.hazard_drains - s0.hazard_drains));
    CHECK(memcmp(At(kTable3 + kTableFirst), At(kNewTsharp), 32) == 0, "the copy shader did not write the record");
    for (uint32_t w = 0; w < 6; ++w) {
        if (kIndices[w] != 0) continue;
        float want[4] = {0, 0, 0, 0}, got[4];
        Store(want, kColor[1], 1);
        memcpy(got, At(out + 16 * w), 16);
        CHECK(memcmp(got, want, 16) == 0, "async compute hazard: workgroup %u (record 0, rewritten blue) stored %g %g "
              "%g %g", w, got[0], got[1], got[2], got[3]);
    }
}

// The harness's VM extents, laid out as the runtime's: guest memory below kHeap has no extent
// (the runtime's module images and the memory it places there), so everything the other tests
// use is mapped without one; from kHeap on, one free extent, in which kProt is then mapped and
// mprotect'ed to PROT_NONE as a whole (as sceKernelMprotect does for a guard page inside an
// extent), and kUnmapped stays free.
constexpr uint64_t kHeap = 0x40000000, kProt = 0x90000000, kUnmapped = 0x80000000;

// ---- Table hazards judged at the point the CP read the tables (not at encoding) ----
// Addresses of these tests (above everything else the harness uses).
constexpr uint64_t kHzCode = 0x04000000; // + 0x10000 per program
constexpr uint64_t kHzTable = 0x05000000, kHzNew = 0x05100000, kHzRt = 0x05200000, kHzOut = 0x05300000;
constexpr uint64_t kHzTableBytes = kTableFirst + kRecordBytes; // one record

// A fresh one-record V# table at `table` whose record 0 holds `first` (a T# of an 8x8 texture),
// and the blue T# at kHzNew for the pending GPU write to copy over it.
void PrepareHzTable(uint64_t table, uint64_t first) {
    memset(At(table), 0, 0x100);
    PutTsharp(At(table + kTableFirst), first);
    PutTsharp(At(kHzNew), kTex[1]);
    ps4draw::NotifyGuestWrite(table, 0x10000, false, 0);
    ps4draw::NotifyGuestWrite(kHzNew, 0x1000, false, 0);
}

void LoadHzProgram(uint64_t at, const std::vector<uint32_t>& code) {
    memcpy(g_mem + at, code.data(), code.size() * 4);
    ps4draw::NotifyGuestWrite(at, 0x10000, false, 0);
}

// The Records dispatch (Program) over the one-record table at `table`, writing to `out`; true if
// the workgroups that index record 0 sampled the blue texture (the T# the GPU wrote).
std::vector<uint32_t> HzReadRegs(uint64_t code_addr, uint64_t table, uint64_t out) {
    std::vector<uint32_t> regs = Regs(Form::Records, code_addr, out);
    PutVsharp(&regs[0x2E44], table, kHzTableBytes);
    for (uint32_t k = 0; k < 6 * 4; ++k) At(out)[k] = kSentinel;
    ps4draw::NotifyGuestWrite(out, 0x1000, false, 0);
    return regs;
}
bool SampledBlue(uint64_t out, const char* what) {
    bool ok = true;
    for (uint32_t w = 0; w < 6; ++w) {
        if (kIndices[w] != 0) continue;
        float want[4] = {0, 0, 0, 0}, got[4];
        Store(want, kColor[1], 1);
        memcpy(got, At(out + 16 * w), 16);
        if (memcmp(got, want, 16) != 0) {
            CHECK(false, "%s: workgroup %u (record 0, rewritten blue by the GPU) stored %g %g %g %g", what, w, got[0],
                  got[1], got[2], got[3]);
            ok = false;
        }
    }
    return ok;
}
// The copy shader (CopyProgram) writing the blue T# over record 0 of `table`.
std::vector<uint32_t> HzCopyRegs(uint64_t code_addr, uint64_t table) {
    std::vector<uint32_t> cregs = CsRegs(code_addr, 8);
    PutVsharp(&cregs[0x2E40], kHzNew, 32);
    PutVsharp(&cregs[0x2E44], table + kTableFirst, 32);
    return cregs;
}

// A CP DMA on the GPU (ps4draw::GpuDma, not a pass) writes the blue T# over record 0, then a
// dispatch reads the table. Its CP copy of the table is made while the DMA is pending. In a
// captured frame (mode "capture") the pass starts its encoding with the GPU drained, so when
// the hazard check runs the DMA has completed: judged at that point, nothing is pending and the
// stale red entry is bound (workgroups 0 and 3 sample red). Judged at the CP's read, the DMA was
// pending: the table is read again (blue). Without capture this was already caught; both modes
// run it.
void TestHazardDma(const char* mode) {
    const uint64_t table = kHzTable, read_addr = kHzCode, out = kHzOut;
    PrepareHzTable(table, kTex[0]);
    LoadHzProgram(read_addr, Program(Form::Records, Op::Sample));
    const std::vector<uint32_t> rregs = HzReadRegs(read_addr, table, out);
    const ps4draw::ImageTableStats s0 = ps4draw::GetImageTableStats();
    CHECK(ps4draw::GpuDma(false, false, kHzNew, 0, false, table + kTableFirst, 32), "%s DMA: GpuDma refused", mode);
    ps4draw::Dispatch(&g_ctx, rregs.data(), 6, 1, 1, 0, "gfx", ps4draw::kQueueGfx);
    ps4draw::Flush(true);
    const ps4draw::ImageTableStats s1 = ps4draw::GetImageTableStats();
    CHECK(memcmp(At(table + kTableFirst), At(kHzNew), 32) == 0, "%s DMA: the DMA did not write the record", mode);
    CHECK(s1.hazard_drains - s0.hazard_drains == 1, "%s DMA: %llu table hazard drains, want 1", mode,
          (unsigned long long)(s1.hazard_drains - s0.hazard_drains));
    SampledBlue(out, mode);
}

// Encoder thread (mode "async"): the CP runs ahead of the encoder. A copy shader writes the blue
// T# over record 0; two dispatches read the table, both copied by the CP before the copy shader
// was even encoded (the encoder is held in a fence action meanwhile). The first one's hazard
// check finds the copy pending and drains the GPU; when the second one is encoded the copy has
// completed. Judged at encoding, the second binds the stale red entry; judged at the CP's read,
// the copy was pending for both and both sample blue.
void TestHazardAsync() {
    const uint64_t table = kHzTable + 0x10000, copy_addr = kHzCode + 0x10000, read_addr = kHzCode + 0x20000;
    const uint64_t out_a = kHzOut + 0x1000, out_b = kHzOut + 0x2000;
    // warm up: both shaders translated and their pipelines made before the encoder is held
    PrepareHzTable(table, kTex[0]);
    LoadHzProgram(copy_addr, CopyProgram());
    LoadHzProgram(read_addr, Program(Form::Records, Op::Sample));
    {
        const std::vector<uint32_t> cregs = HzCopyRegs(copy_addr, table), rregs = HzReadRegs(read_addr, table, out_a);
        ps4draw::Dispatch(&g_ctx, cregs.data(), 1, 1, 1, 0, "gfx", ps4draw::kQueueGfx);
        ps4draw::Dispatch(&g_ctx, rregs.data(), 6, 1, 1, 0, "gfx", ps4draw::kQueueGfx);
        ps4draw::Flush(true);
        SampledBlue(out_a, "async warm-up");
    }
    PrepareHzTable(table, kTex[0]);
    const std::vector<uint32_t> cregs = HzCopyRegs(copy_addr, table), ra = HzReadRegs(read_addr, table, out_a),
                                rb = HzReadRegs(read_addr, table, out_b);
    ps4draw::Flush(true); // nothing in flight: the fence action below runs on the encoder thread
    std::atomic<int> held{0};
    std::atomic<bool> go{false};
    ps4draw::AfterGpu([&] {
        held = 1;
        const auto t0 = std::chrono::steady_clock::now();
        while (!go.load() && std::chrono::steady_clock::now() - t0 < std::chrono::seconds(5)) usleep(100);
        held = 2;
    });
    const auto t0 = std::chrono::steady_clock::now();
    while (held.load() == 0 && std::chrono::steady_clock::now() - t0 < std::chrono::seconds(2)) usleep(100);
    CHECK(held.load() == 1, "async: the encoder did not hold in the fence action (%d)", held.load());
    const ps4draw::ImageTableStats s0 = ps4draw::GetImageTableStats();
    ps4draw::Dispatch(&g_ctx, cregs.data(), 1, 1, 1, 0, "gfx", ps4draw::kQueueGfx);
    ps4draw::Dispatch(&g_ctx, ra.data(), 6, 1, 1, 0, "gfx", ps4draw::kQueueGfx);
    ps4draw::Dispatch(&g_ctx, rb.data(), 6, 1, 1, 0, "gfx", ps4draw::kQueueGfx);
    CHECK(held.load() == 1, "async: the CP waited for the encoder (the test no longer runs the CP ahead)");
    go = true;
    ps4draw::Flush(true);
    const ps4draw::ImageTableStats s1 = ps4draw::GetImageTableStats();
    CHECK(memcmp(At(table + kTableFirst), At(kHzNew), 32) == 0, "async: the copy shader did not write the record");
    CHECK(s1.hazard_drains - s0.hazard_drains == 2, "async: %llu table hazard drains, want 2 (both readers)",
          (unsigned long long)(s1.hazard_drains - s0.hazard_drains));
    SampledBlue(out_a, "async, first reader");
    SampledBlue(out_b, "async, second reader (encoded after the first one's drain)");
}

// A draw whose VS and PS both read one table (s_buffer_load_dwordx8 at 0x40 + 48 * L, L = A[i],
// i = the first lane's v0, so the index is only known at run time and the table is bounded by its
// V#: record 0; image_sample_lz at the centre). VS: a triangle covering the target (from the vertex
// id), the sample as parameter 0; PS: the sample to MRT0 and, with buffer_store_dwordx4, to the
// output buffer (every pixel stores the same 16 bytes). In the PS the first lane's v0 is a
// barycentric (any index): A has 6 dwords, a load past them reads 0, so L = 0 as well.
// User data: s[0:3] V# of A, s[4:7] V# of the table, s[8:11] S#, (PS) s[12:15] V# of the output.
std::vector<uint32_t> TableStageProgram(bool vertex) {
    using namespace gcn;
    constexpr uint32_t kVAndB32 = 27, kVLshrrevB32 = 22, kVAddI32 = 37, kVCvtF32I32 = 5;
    std::vector<uint32_t> c;
    if (vertex) {
        // position (x, y) = (4 * (id & 1) - 1, 4 * (id >> 1) - 1): (-1, -1), (3, -1), (-1, 3)
        c.push_back(Vop2(kVAndB32, 10, 0x81, 0));
        c.push_back(Vop2(kVLshrrevB32, 11, 0x81, 0));
        for (uint32_t r = 10; r < 12; ++r) {
            c.push_back(VLshlrev(r, 0x82, r));
            c.push_back(Vop2(kVAddI32, r, 0xC1, r)); // + (-1)
            c.push_back(Vop1(kVCvtF32I32, r, V(r)));
        }
    }
    c.push_back(0x7E000000u | 16u << 17 | 2u << 9 | V(0));   // v_readfirstlane_b32 s16, v0
    c.push_back(Sop2(kSLshlB32, 17, 16, 0x82));               // s17 = s16 * 4
    c.push_back(Smrd(kSBufLoad, 18, 0, 17));                  // s18 = A[s16] = L
    c.push_back(kWait);
    c.push_back(Sop2(kSMulI32, 19, 18, 0x80 + kRecordBytes)); // s19 = L * 48 + 0x40
    c.push_back(Sop2(kSAddU32, 19, 19, 0x80 + kTableFirst));
    c.push_back(Smrd(kSBufLoadX8, 20, 4, 19));                // T# s[20:27]
    c.push_back(kWait);
    c.push_back(Vop1(kVMov, 0, kLiteral));
    c.push_back(0x3F000000u);
    c.push_back(Vop1(kVMov, 1, kLiteral));
    c.push_back(0x3F000000u);
    Mimg(c, kImageSampleLz, 0, 2, 20, 8);                     // v[2:5]
    c.push_back(kWait);
    if (vertex) {
        c.push_back(Vop1(kVMov, 12, 0x80)); // z = 0
        c.push_back(Vop1(kVMov, 13, 0xF2)); // w = 1.0
        c.push_back(0xF800020Fu);           // exp param0 v2, v3, v4, v5
        c.push_back(2u | 3u << 8 | 4u << 16 | 5u << 24);
        c.push_back(0xF80008CFu);           // exp pos0 v10, v11, v12, v13 done
        c.push_back(10u | 11u << 8 | 12u << 16 | 13u << 24);
    } else {
        Mubuf(c, kStoreDwordx4, false, 0, 2, 12);
        c.push_back(0xF800180Fu); // exp mrt0 v2, v3, v4, v5 done vm
        c.push_back(2u | 3u << 8 | 4u << 16 | 5u << 24);
    }
    c.push_back(kEnd);
    return WithFooter(c, vertex ? 0x5CA1AB1E00007A00ull : 0x5CA1AB1E00007B00ull);
}

uint32_t Fbits(float f) {
    uint32_t u;
    memcpy(&u, &f, 4);
    return u;
}

// Registers of a triangle-list draw of 3 vertices with VS and PS at vs / ps, both with the user
// data of TableStageProgram over `table` and `out`, into a 64x64 RGBA8 linear colour target at
// kHzRt.
std::vector<uint32_t> DrawRegs(uint64_t vs, uint64_t ps, uint64_t table, uint64_t out) {
    constexpr uint32_t kW = 64, kH = 64;
    std::vector<uint32_t> regs(0x10000, 0);
    ps4draw::SetRegDefaults(regs.data());
    auto stage = [&](uint32_t pgm, uint64_t code, uint32_t user) {
        regs[pgm] = uint32_t(code >> 8);
        regs[pgm + 1] = uint32_t(code >> 40);
        regs[pgm + 2] = 3 | (3 << 6); // RSRC1: 16 VGPRs, 32 SGPRs
        regs[pgm + 3] = 16 << 1;      // RSRC2: 16 user SGPRs
        PutVsharp(&regs[user], kIndex, sizeof(kIndices));
        PutVsharp(&regs[user + 4], table, kHzTableBytes);
        for (uint32_t k = 8; k < 12; ++k) regs[user + k] = 0; // S#: wrap, point
        PutVsharp(&regs[user + 12], out, 16);
    };
    stage(0x2C48, vs, 0x2C4C); // SPI_SHADER_PGM_LO_VS, SPI_SHADER_USER_DATA_VS_0
    stage(0x2C08, ps, 0x2C0C); // SPI_SHADER_PGM_LO_PS, SPI_SHADER_USER_DATA_PS_0
    regs[0xA1B1] = 0;          // SPI_VS_OUT_CONFIG
    regs[0xA1B3] = 2;          // SPI_PS_INPUT_ENA: PERSP_CENTER
    regs[0xA1B4] = 2;          // SPI_PS_INPUT_ADDR
    regs[0xA1B6] = 0;          // SPI_PS_IN_CONTROL: no interpolants
    regs[0xA1C3] = 4;          // SPI_SHADER_POS_FORMAT: 4 components
    regs[0xA1C4] = 0;          // SPI_SHADER_Z_FORMAT
    regs[0xA1C5] = 9;          // SPI_SHADER_COL_FORMAT: MRT0 32_ABGR
    regs[0xA2D5] = 0;          // VGT_SHADER_STAGES_EN: VS + PS
    regs[0xA318] = uint32_t(kHzRt >> 8); // CB_COLOR0_BASE
    regs[0xA319] = kW / 8 - 1;           // CB_COLOR0_PITCH
    regs[0xA31A] = kW * kH / 64 - 1;     // CB_COLOR0_SLICE
    regs[0xA31B] = 0;                    // CB_COLOR0_VIEW
    regs[0xA31C] = 0xA << 2;             // CB_COLOR0_INFO: 8_8_8_8 unorm
    regs[0xA31D] = 8;                    // CB_COLOR0_ATTRIB: linear aligned
    regs[0xA08E] = 0xF;                  // CB_TARGET_MASK
    regs[0xA08F] = 0xF;                  // CB_SHADER_MASK
    regs[0xA202] = 0x00CC0010;           // CB_COLOR_CONTROL: normal, ROP3 copy
    regs[0xA00C] = 0;                    // PA_SC_SCREEN_SCISSOR_TL
    regs[0xA00D] = kW | (kH << 16);
    regs[0xA081] = 0x80000000;           // PA_SC_WINDOW_SCISSOR_TL
    regs[0xA082] = kW | (kH << 16);
    regs[0xA090] = 0x80000000;           // PA_SC_GENERIC_SCISSOR_TL
    regs[0xA091] = kW | (kH << 16);
    regs[0xA10F] = Fbits(kW / 2.f);      // PA_CL_VPORT_XSCALE / XOFFSET / YSCALE / YOFFSET / ZSCALE / ZOFFSET
    regs[0xA110] = Fbits(kW / 2.f);
    regs[0xA111] = Fbits(kH / 2.f);
    regs[0xA112] = Fbits(kH / 2.f);
    regs[0xA113] = Fbits(0.5f);
    regs[0xA114] = Fbits(0.5f);
    regs[0xA206] = 0x43F;                // PA_CL_VTE_CNTL
    regs[0xA204] = 0;                    // PA_CL_CLIP_CNTL
    regs[0xA205] = 0;                    // PA_SU_SC_MODE_CNTL: no culling
    regs[0xC242] = 4;                    // VGT_PRIMITIVE_TYPE: triangle list
    return regs;
}

// A copy shader writes the blue T# over record 0 (red before), which both stages of the next draw
// read. Checked stage by stage, the VS check drained the GPU and read the VS's tables again,
// after which nothing was pending for the PS check: the PS kept the stale red entry. One check for
// the draw re-reads both stages' tables: the PS samples blue.
void TestHazardDraw() {
    const uint64_t table = kHzTable + 0x20000, copy_addr = kHzCode + 0x30000, out = kHzOut + 0x3000;
    const uint64_t vs_addr = kHzCode + 0x40000, ps_addr = kHzCode + 0x50000;
    PrepareHzTable(table, kTex[0]);
    LoadHzProgram(copy_addr, CopyProgram());
    LoadHzProgram(vs_addr, TableStageProgram(true));
    LoadHzProgram(ps_addr, TableStageProgram(false));
    for (uint32_t k = 0; k < 4; ++k) At(out)[k] = kSentinel;
    ps4draw::NotifyGuestWrite(out, 0x1000, false, 0);
    ps4draw::NotifyGuestWrite(kHzRt, 0x10000, false, 0);
    const std::vector<uint32_t> cregs = HzCopyRegs(copy_addr, table), dregs = DrawRegs(vs_addr, ps_addr, table, out);
    ps4draw::DrawArgs args;
    args.count = 3;
    args.name = "table-hazard-draw";
    const ps4draw::ImageTableStats s0 = ps4draw::GetImageTableStats();
    const uint64_t skipped0 = ps4draw::SkippedCount();
    ps4draw::Dispatch(&g_ctx, cregs.data(), 1, 1, 1, 0, "gfx", ps4draw::kQueueGfx);
    ps4draw::Draw(&g_ctx, dregs.data(), args);
    ps4draw::Flush(true);
    const ps4draw::ImageTableStats s1 = ps4draw::GetImageTableStats();
    CHECK(ps4draw::SkippedCount() == skipped0, "draw: skipped");
    CHECK(memcmp(At(table + kTableFirst), At(kHzNew), 32) == 0, "draw: the copy shader did not write the record");
    CHECK(s1.hazard_drains - s0.hazard_drains == 1, "draw: %llu table hazard drains, want 1 (one per draw)",
          (unsigned long long)(s1.hazard_drains - s0.hazard_drains));
    CHECK(s1.bound - s0.bound == 2, "draw: %llu table entries bound, want 2 (VS and PS)",
          (unsigned long long)(s1.bound - s0.bound));
    float want[4] = {0, 0, 0, 0}, got[4];
    Store(want, kColor[1], 1);
    memcpy(got, At(out), 16);
    CHECK(memcmp(got, want, 16) == 0, "draw: the PS sampled %g %g %g %g, want the blue the GPU wrote (red: stale entry)",
          got[0], got[1], got[2], got[3]);
}

// Table entries and the address check (gcn_set_image_address_check): a well-formed T# at an
// address inside a free extent is unbound (0 is read, not the texture the host memory behind it
// holds) and counts as unmapped; a T# in memory without an extent (module images) or in an
// extent whose protection is PROT_NONE is bound; once the free address is mapped, the next
// dispatch binds it (the renderer's copy of the unmapped ranges follows the VM generation).
void TestAddressCheck() {
    constexpr uint64_t kTable3 = 0x02600000;
    const uint64_t code_addr = kCode + 0x70000, out = kOut + 0x6000;
    for (uint32_t k = 0; k < kPitch * 8; ++k) At(kUnmapped)[k] = kColor[2];
    for (uint32_t k = 0; k < kPitch * 8; ++k) At(kProt + 0x10000)[k] = kColor[1];
    memcpy(At(kTable3), At(kTable), 0x200);
    PutTsharp(At(kTable3 + kTableFirst + kRecordBytes), kUnmapped);         // record 1: green, unmapped
    PutTsharp(At(kTable3 + kTableFirst + 2 * kRecordBytes), kProt + 0x10000); // record 2: blue, PROT_NONE extent
    const std::vector<uint32_t> code = Program(Form::Records, Op::Sample);
    memcpy(g_mem + code_addr, code.data(), code.size() * 4);
    ps4draw::NotifyGuestWrite(kTable3, 0x1000, false, 0);
    ps4draw::NotifyGuestWrite(kUnmapped, 0x1000, false, 0);
    ps4draw::NotifyGuestWrite(kProt + 0x10000, 0x1000, false, 0);
    ps4draw::NotifyGuestWrite(code_addr, 0x10000, false, 0);
    std::vector<uint32_t> regs = Regs(Form::Records, code_addr, out);
    PutVsharp(&regs[0x2E44], kTable3, kTableBytes);
    for (const bool mapped : {false, true}) {
        if (mapped && recomp_vm_alloc_fixed(&g_ctx, kUnmapped, 0x200000, PROT_READ | PROT_WRITE, 0, "direct") != kUnmapped) {
            CHECK(false, "address check: could not map 0x%llx", (unsigned long long)kUnmapped);
            return;
        }
        for (uint32_t k = 0; k < 6 * 4; ++k) At(out)[k] = kSentinel;
        ps4draw::NotifyGuestWrite(out, 0x1000, false, 0);
        const ps4draw::ImageTableStats s0 = ps4draw::GetImageTableStats();
        const uint64_t skipped0 = ps4draw::SkippedCount();
        ps4draw::Dispatch(&g_ctx, regs.data(), 6, 1, 1, 0, "gfx", ps4draw::kQueueGfx);
        ps4draw::Flush(true);
        const ps4draw::ImageTableStats s1 = ps4draw::GetImageTableStats();
        const char* when = mapped ? "after mapping" : "before mapping";
        CHECK(ps4draw::SkippedCount() == skipped0, "address check %s: the dispatch was skipped", when);
        // red, blue (PROT_NONE extent), green once mapped, else unmapped; past the V#: empty
        const uint64_t want_bound = mapped ? 3 : 2, want_unmapped = mapped ? 0 : 1;
        CHECK(s1.bound - s0.bound == want_bound && s1.unmapped - s0.unmapped == want_unmapped &&
                  s1.rejected - s0.rejected == 0 && s1.empty - s0.empty == 1,
              "address check %s: %llu bound, %llu unmapped, %llu rejected, %llu empty", when,
              (unsigned long long)(s1.bound - s0.bound), (unsigned long long)(s1.unmapped - s0.unmapped),
              (unsigned long long)(s1.rejected - s0.rejected), (unsigned long long)(s1.empty - s0.empty));
        for (uint32_t w = 0; w < 6; ++w) {
            const uint32_t L = kIndices[w];
            float want[4] = {0, 0, 0, 0}, got[4];
            if (L == 0) Store(want, kColor[0], 1);
            if (L == 1 && mapped) Store(want, kColor[2], 1);
            if (L == 2) Store(want, kColor[1], 1);
            memcpy(got, At(out + 16 * w), 16);
            CHECK(memcmp(got, want, 16) == 0, "address check %s: workgroup %u (L = %u) stored %g %g %g %g, want %g %g %g %g",
                  when, w, L, got[0], got[1], got[2], got[3], want[0], want[1], want[2], want[3]);
        }
    }
}

// The statistics take an entry's address from T# bits 0-37 only: a T# that no texture can be made
// of (the non-square cube at kTex[0], mapped) with mtype_l2 and min_lod set in dword 1 counts as
// rejected, not as unmapped (bits 38-39 read as address bits put it past guest memory).
void TestStatsAddressBits() {
    constexpr uint64_t kTable5 = 0x02C00000;
    const uint64_t code_addr = kCode + 0xF0000, out = kOut + 0xB000;
    memcpy(At(kTable5), At(kTable), 0x200);
    At(kTable5 + kTableFirst + 2 * kRecordBytes)[1] |= 3u << 6 | 5u << 8; // mtype_l2 3, min_lod 5
    const std::vector<uint32_t> code = Program(Form::Records, Op::Sample);
    memcpy(g_mem + code_addr, code.data(), code.size() * 4);
    for (uint32_t k = 0; k < 6 * 4; ++k) At(out)[k] = kSentinel;
    ps4draw::NotifyGuestWrite(kTable5, 0x1000, false, 0);
    ps4draw::NotifyGuestWrite(code_addr, 0x10000, false, 0);
    ps4draw::NotifyGuestWrite(out, 0x1000, false, 0);
    std::vector<uint32_t> regs = Regs(Form::Records, code_addr, out);
    PutVsharp(&regs[0x2E44], kTable5, kTableBytes);
    const ps4draw::ImageTableStats s0 = ps4draw::GetImageTableStats();
    ps4draw::Dispatch(&g_ctx, regs.data(), 6, 1, 1, 0, "gfx", ps4draw::kQueueGfx);
    ps4draw::Flush(true);
    const ps4draw::ImageTableStats s1 = ps4draw::GetImageTableStats();
    CHECK(s1.bound - s0.bound == 2 && s1.rejected - s0.rejected == 1 && s1.unmapped - s0.unmapped == 0,
          "T# with mtype_l2 / min_lod: %llu bound, %llu rejected, %llu unmapped, want 2 / 1 / 0",
          (unsigned long long)(s1.bound - s0.bound), (unsigned long long)(s1.rejected - s0.rejected),
          (unsigned long long)(s1.unmapped - s0.unmapped));
}

// Translates a hand-assembled compute program for the given registers (as the renderer does).
gcn_shader* Translate(const std::vector<uint32_t>& regs, const std::vector<uint32_t>& code, gcn_runtime_info* rt,
                      uint32_t ud[16]) {
    gcn_profile prof;
    gcn_profile_default_metal(&prof);
    gcn_runtime_info_from_regs(regs.data(), regs.size(), GCN_HW_CS, GCN_SW_COMPUTE, &prof, rt);
    gcn_compile_desc d{};
    d.hw_stage = GCN_HW_CS;
    d.sw_stage = GCN_SW_COMPUTE;
    uint64_t addr = 0;
    gcn_stage_from_regs(regs.data(), regs.size(), GCN_HW_CS, &addr, d.user_data);
    memcpy(ud, d.user_data, 64);
    d.code_addr = addr;
    d.code = code.data();
    d.code_size = uint32_t(code.size() * 4);
    d.runtime = rt;
    d.profile = &prof;
    d.read_guest = ReadGuest;
    d.flags = GCN_COMPILE_EMIT_MSL;
    gcn_shader* sh = nullptr;
    char err[512] = {};
    CHECK(gcn_compile(&d, &sh, err, sizeof(err)) == GCN_OK && sh, "does not translate: %s", err);
    return sh;
}

// One or two do-while loops over the SRT pointer table (records of stride_bytes from byte 0x40),
// summing image_sample_lz of each record: loop 1 k = 0 .. s6 - 1 (counter s17), loop 2
// k = 0 .. s7 - 1 (counter s18).
std::vector<uint32_t> LoopsProgram(uint32_t stride_bytes, bool two, uint64_t hash) {
    using namespace gcn;
    std::vector<uint32_t> c;
    for (uint32_t r = 10; r < 14; ++r) c.push_back(Vop1(kVMov, r, 0x80));
    c.push_back(Vop1(kVMov, 0, kLiteral));
    c.push_back(0x3F000000u);
    c.push_back(Vop1(kVMov, 1, kLiteral));
    c.push_back(0x3F000000u);
    for (uint32_t l = 0; l < (two ? 2u : 1u); ++l) {
        const uint32_t k = 17 + l, n = 6 + l;
        c.push_back(SMovB32(k, 0x80));
        const size_t loop = c.size();
        c.push_back(Sop2(kSMulI32, 19, k, kLiteral)); // s19 = k * stride + 0x40
        c.push_back(stride_bytes);
        c.push_back(Sop2(kSAddU32, 19, 19, 0x80 + kTableFirst));
        c.push_back(Smrd(kSLoadX8, 20, 4, 19));
        c.push_back(kWait);
        Mimg(c, kImageSampleLz, 0, 2, 20, 12);
        c.push_back(kWait);
        for (uint32_t r = 0; r < 4; ++r) c.push_back(Vop2(kVAddF32, 10 + r, V(2 + r), 10 + r));
        c.push_back(Sop2(kSAddU32, k, k, 0x81));
        c.push_back(SCmpLtU32(k, n));
        c.push_back(SCbranchScc1(int16_t(int(loop) - int(c.size() + 1))));
    }
    c.push_back(Vop1(kVMov, 9, 16));
    c.push_back(VLshlrev(9, 0x84, 9));
    Mubuf(c, kStoreDwordx4, true, 9, 10, 8);
    c.push_back(kEnd);
    return WithFooter(c, hash);
}

std::vector<uint32_t> LoopRegs(uint64_t code_addr, uint32_t n1, uint32_t n2) {
    std::vector<uint32_t> regs = CsRegs(code_addr, 16);
    uint32_t* ud = &regs[0x2E40];
    ud[4] = uint32_t(kSrt);
    ud[5] = uint32_t(kSrt >> 32);
    ud[6] = n1;
    ud[7] = n2;
    PutVsharp(ud + 8, kOut + 0x7000, 16);
    return regs;
}

// A gap table (no bound fits) read by two sites keeps both sites' bounds, not only the first of
// each kind: two loops over one table, N1 = 20 and N2 = 30 (both over 8 entries); a draw with
// N2 = 3 is not served by that shader (its second loop fits now: another permutation).
void TestGapBounds() {
    const std::vector<uint32_t> code = LoopsProgram(kRecordBytes, true, 0x5CA1AB1E00007300ull);
    gcn_runtime_info rt;
    uint32_t ud[16];
    gcn_shader* sh = Translate(LoopRegs(kCode + 0x80000, 20, 30), code, &rt, ud);
    if (!sh) return;
    gcn_image_table t{};
    CHECK(gcn_shader_get_image_table(sh, 0, &t) && t.kind == GCN_IMAGE_TABLE_NONE && t.num_sites == 2,
          "two loops over one table, N = 20 / 30: kind %u, %u sites", t.kind, t.num_sites);
    uint32_t ud3[16];
    memcpy(ud3, ud, 64);
    ud3[7] = 3;
    CHECK(!gcn_shader_is_compatible(sh, ud3, &rt, ReadGuest, nullptr),
          "the gap shader of N = 20 / 30 was found compatible with N = 20 / 3");
    CHECK(gcn_shader_is_compatible(sh, ud, &rt, ReadGuest, nullptr), "the gap shader does not serve its own draw");
    gcn_shader_destroy(sh);
}

// No table form for offsets the table form cannot represent (counted null image reads instead):
// a record index that decreases (T# at 0x40 + 48 * (2 - L): multiplier -48), and a loop whose
// entries lie past 4 GiB (stride 0x40000000 bytes, N = 5: entry 7 at byte 7 * 2^30).
void TestUnrepresentable() {
    using namespace gcn;
    {
        std::vector<uint32_t> c;
        c.push_back(Sop2(kSLshlB32, 17, 16, 0x82));
        c.push_back(Smrd(kSBufLoad, 18, 0, 17)); // L
        c.push_back(kWait);
        c.push_back(Sop2(kSMulI32, 19, 18, kLiteral));
        c.push_back(uint32_t(-int32_t(kRecordBytes))); // s19 = -48 * L
        c.push_back(Sop2(kSAddU32, 19, 19, kLiteral));
        c.push_back(kTableFirst + 2 * kRecordBytes);  // + 0x40 + 96
        c.push_back(Smrd(kSBufLoadX8, 20, 4, 19));
        c.push_back(kWait);
        c.push_back(Vop1(kVMov, 0, kLiteral));
        c.push_back(0x3F000000u);
        c.push_back(Vop1(kVMov, 1, kLiteral));
        c.push_back(0x3F000000u);
        Mimg(c, kImageSampleLz, 0, 2, 20, 12);
        c.push_back(kWait);
        c.push_back(Vop1(kVMov, 9, 16));
        c.push_back(VLshlrev(9, 0x84, 9));
        Mubuf(c, kStoreDwordx4, true, 9, 2, 8);
        c.push_back(kEnd);
        const std::vector<uint32_t> code = WithFooter(c, 0x5CA1AB1E00007400ull);
        gcn_runtime_info rt;
        uint32_t ud[16];
        gcn_shader* sh = Translate(Regs(Form::Records, kCode + 0x90000, kOut + 0x8000), code, &rt, ud);
        if (sh) {
            gcn_shader_info info{};
            gcn_shader_get_info(sh, &info);
            // no table entries are bound: either no table form at all, or a gap table
            gcn_image_table t{};
            const bool gap = info.num_image_tables == 0 ||
                             (info.num_image_tables == 1 && gcn_shader_get_image_table(sh, 0, &t) && t.kind == GCN_IMAGE_TABLE_NONE);
            CHECK(gap && info.null_image_reads == 1,
                  "decreasing record index: %u T# tables (kind %u, %u entries, stride %u), %u null image reads",
                  info.num_image_tables, t.kind, t.num_entries, t.stride_dw, info.null_image_reads);
            gcn_shader_destroy(sh);
        }
    }
    {
        const std::vector<uint32_t> code = LoopsProgram(0x40000000u, false, 0x5CA1AB1E00007500ull);
        gcn_runtime_info rt;
        uint32_t ud[16];
        gcn_shader* sh = Translate(LoopRegs(kCode + 0xA0000, 5, 0), code, &rt, ud);
        if (sh) {
            gcn_shader_info info{};
            gcn_shader_get_info(sh, &info);
            gcn_image_table t{};
            CHECK(gcn_shader_get_image_table(sh, 0, &t) && t.kind == GCN_IMAGE_TABLE_NONE && info.null_image_reads == 1,
                  "loop table past 4 GiB: kind %u, %u null image reads", t.kind, info.null_image_reads);
            gcn_shader_destroy(sh);
        }
    }
}

// The hazard drain re-checks the permutation: a compute shader writes a valid T# into the table
// record that held no T# (entry 2: the null image in the permutation chosen before the write).
// After the drain the tables no longer fit that permutation: the dispatch is skipped and counted,
// not run with entry 2 unbound.
void TestHazardSkip() {
    constexpr uint64_t kTable4 = 0x02800000, kNewTsharp = 0x02900000;
    const uint64_t copy_addr = kCode + 0xB0000, read_addr = kCode + 0xC0000, out = kOut + 0x9000;
    memcpy(At(kTable4), At(kTable), 0x200);
    PutTsharp(At(kNewTsharp), kTex[1]);
    const std::vector<uint32_t> copy = CopyProgram(), read = Program(Form::Records, Op::Sample);
    memcpy(g_mem + copy_addr, copy.data(), copy.size() * 4);
    memcpy(g_mem + read_addr, read.data(), read.size() * 4);
    for (uint32_t k = 0; k < 6 * 4; ++k) At(out)[k] = kSentinel;
    ps4draw::NotifyGuestWrite(kTable4, 0x200000, false, 0);
    ps4draw::NotifyGuestWrite(copy_addr, 0x20000, false, 0);
    ps4draw::NotifyGuestWrite(out, 0x1000, false, 0);
    std::vector<uint32_t> cregs = CsRegs(copy_addr, 8);
    PutVsharp(&cregs[0x2E40], kNewTsharp, 32);
    PutVsharp(&cregs[0x2E44], kTable4 + kTableFirst + 2 * kRecordBytes, 32);
    std::vector<uint32_t> rregs = Regs(Form::Records, read_addr, out);
    PutVsharp(&rregs[0x2E44], kTable4, kTableBytes);
    const ps4draw::ImageTableStats s0 = ps4draw::GetImageTableStats();
    const uint64_t skipped0 = ps4draw::SkippedCount();
    ps4draw::Dispatch(&g_ctx, cregs.data(), 1, 1, 1, 0, "gfx", ps4draw::kQueueGfx);
    ps4draw::Dispatch(&g_ctx, rregs.data(), 6, 1, 1, 0, "gfx", ps4draw::kQueueGfx);
    ps4draw::Flush(true);
    const ps4draw::ImageTableStats s1 = ps4draw::GetImageTableStats();
    CHECK(s1.hazard_drains - s0.hazard_drains == 1 && s1.hazard_skips - s0.hazard_skips == 1,
          "hazard skip: %llu drains, %llu skips, want 1 / 1", (unsigned long long)(s1.hazard_drains - s0.hazard_drains),
          (unsigned long long)(s1.hazard_skips - s0.hazard_skips));
    CHECK(ps4draw::SkippedCount() == skipped0 + 1, "hazard skip: the dispatch was not counted as skipped");
    bool untouched = true;
    for (uint32_t k = 0; k < 6 * 4; ++k) untouched &= At(out)[k] == kSentinel;
    CHECK(untouched, "hazard skip: the skipped dispatch wrote its output");
}

// More table reads than a fixed list holds: 8 tables (one per site, T# at 0x40 + 0x200 * j +
// 48 * L through the SRT pointer, L = A2[w] = w) of 8 entries each, image_load_mip'd and summed,
// read with one index scan: 65 ranges. A compute shader writes the blue T# into table 7's record
// 7, the 65th range: the next dispatch drains and workgroup 7 sums 7 red texels and 1 blue.
std::vector<uint32_t> ManyTablesProgram() {
    using namespace gcn;
    std::vector<uint32_t> c;
    for (uint32_t r = 10; r < 14; ++r) c.push_back(Vop1(kVMov, r, 0x80));
    c.push_back(Vop1(kVMov, 6, 0x80));
    c.push_back(Vop1(kVMov, 7, 0x80));
    c.push_back(Vop1(kVMov, 8, 0x80));
    c.push_back(Sop2(kSLshlB32, 17, 16, 0x82));
    c.push_back(Smrd(kSBufLoad, 18, 0, 17)); // L = A2[w]
    c.push_back(kWait);
    for (uint32_t j = 0; j < 8; ++j) {
        c.push_back(Sop2(kSMulI32, 19, 18, 0x80 + kRecordBytes));
        c.push_back(Sop2(kSAddU32, 19, 19, kLiteral));
        c.push_back(kTableFirst + 0x200 * j);
        c.push_back(Smrd(kSLoadX8, 20, 4, 19));
        c.push_back(kWait);
        Mimg(c, kImageLoadMip, 6, 2, 20, 0);
        c.push_back(kWait);
        for (uint32_t r = 0; r < 4; ++r) c.push_back(Vop2(kVAddF32, 10 + r, V(2 + r), 10 + r));
    }
    c.push_back(Vop1(kVMov, 9, 16));
    c.push_back(VLshlrev(9, 0x84, 9));
    Mubuf(c, kStoreDwordx4, true, 9, 10, 8);
    c.push_back(kEnd);
    return WithFooter(c, 0x5CA1AB1E00007600ull);
}

void TestManyReads() {
    constexpr uint64_t kSrt2 = 0x02A00000, kIndex2 = 0x02B00000, kNewTsharp = 0x02B10000;
    const uint64_t copy_addr = kCode + 0xD0000, read_addr = kCode + 0xE0000, out = kOut + 0xA000;
    memset(At(kSrt2), 0, 0x1000);
    for (uint32_t j = 0; j < 8; ++j)
        for (uint32_t t = 0; t < 8; ++t) PutTsharp(At(kSrt2 + kTableFirst + 0x200 * j + kRecordBytes * t), kTex[0]);
    for (uint32_t w = 0; w < 8; ++w) At(kIndex2)[w] = w;
    PutTsharp(At(kNewTsharp), kTex[1]);
    const std::vector<uint32_t> copy = CopyProgram(), read = ManyTablesProgram();
    memcpy(g_mem + copy_addr, copy.data(), copy.size() * 4);
    memcpy(g_mem + read_addr, read.data(), read.size() * 4);
    for (uint32_t k = 0; k < 8 * 4; ++k) At(out)[k] = kSentinel;
    ps4draw::NotifyGuestWrite(kSrt2, 0x200000, false, 0);
    ps4draw::NotifyGuestWrite(copy_addr, 0x20000, false, 0);
    ps4draw::NotifyGuestWrite(out, 0x1000, false, 0);
    std::vector<uint32_t> cregs = CsRegs(copy_addr, 8);
    PutVsharp(&cregs[0x2E40], kNewTsharp, 32);
    PutVsharp(&cregs[0x2E44], kSrt2 + kTableFirst + 0x200 * 7 + kRecordBytes * 7, 32);
    std::vector<uint32_t> rregs = CsRegs(read_addr, 16);
    uint32_t* ud = &rregs[0x2E40];
    PutVsharp(ud, kIndex2, 32);
    ud[4] = uint32_t(kSrt2);
    ud[5] = uint32_t(kSrt2 >> 32);
    PutVsharp(ud + 8, out, 8 * 16);
    // the translation: 8 indexed tables of 8 entries, 65 table reads
    {
        gcn_runtime_info rt;
        uint32_t tud[16];
        gcn_shader* sh = Translate(rregs, read, &rt, tud);
        if (sh) {
            gcn_shader_info info{};
            gcn_shader_get_info(sh, &info);
            std::vector<uint32_t> flat(info.flatbuf_size_dw);
            gcn_shader_build_flatbuf(sh, tud, ReadGuest, nullptr, flat.data(), flat.size());
            const uint32_t reads = gcn_shader_image_table_reads(sh, flat.data(), nullptr, 0);
            gcn_image_table t{};
            CHECK(info.num_image_tables == 8 && gcn_shader_get_image_table(sh, 7, &t) && t.kind == GCN_IMAGE_TABLE_INDEXED &&
                      t.num_entries == 8 && reads == 65 && info.null_image_reads == 0,
                  "8 tables: %u tables, table 7 kind %u, %u entries, %u table reads, %u null image reads",
                  info.num_image_tables, t.kind, t.num_entries, reads, info.null_image_reads);
            gcn_shader_destroy(sh);
        }
    }
    const ps4draw::ImageTableStats s0 = ps4draw::GetImageTableStats();
    const uint64_t skipped0 = ps4draw::SkippedCount();
    ps4draw::Dispatch(&g_ctx, cregs.data(), 1, 1, 1, 0, "gfx", ps4draw::kQueueGfx);
    ps4draw::Dispatch(&g_ctx, rregs.data(), 8, 1, 1, 0, "gfx", ps4draw::kQueueGfx);
    ps4draw::Flush(true);
    const ps4draw::ImageTableStats s1 = ps4draw::GetImageTableStats();
    CHECK(ps4draw::SkippedCount() == skipped0, "8 tables: a dispatch was skipped");
    CHECK(s1.hazard_drains - s0.hazard_drains == 1, "8 tables: %llu hazard drains, want 1 (the 65th read)",
          (unsigned long long)(s1.hazard_drains - s0.hazard_drains));
    for (uint32_t w = 0; w < 8; ++w) {
        float want[4] = {0, 0, 0, 0}, got[4];
        Store(want, kColor[0], w == 7 ? 7.0f : 8.0f);
        if (w == 7) Store(want, kColor[1], 1);
        memcpy(got, At(out + 16 * w), 16);
        CHECK(memcmp(got, want, 16) == 0, "8 tables: workgroup %u stored %g %g %g %g, want %g %g %g %g", w, got[0], got[1],
              got[2], got[3], want[0], want[1], want[2], want[3]);
    }
}

// The renderer's own check: the junk T# decodes as invalid, counted.
void TestJunkDecode() {
    uint32_t t[8];
    PutJunkTsharp(t);
    const uint64_t n0 = ps4gnm::UncreatableImageCount();
    ps4gnm::ImageDesc d;
    CHECK(!ps4gnm::DecodeImage(t, 8, &d) && !d.valid, "a 64 x 32 cube decodes as valid");
    CHECK(ps4gnm::UncreatableImageCount() == n0 + 1, "the uncreatable T# was not counted");
}

} // namespace

int main(int argc, char** argv) {
    @autoreleasepool {
        // "": every test, with PS4_GNM_SYNC_ENCODE; "capture": the DMA hazard in a captured frame
        // (frame 0, into a temporary directory); "async": the hazard with the encoder thread;
        // "async-compute": the hazard with the writer on the asynchronous compute queue
        const std::string mode = argc > 1 ? argv[1] : "";
        if (mode != "" && mode != "capture" && mode != "async" && mode != "async-compute") {
            fprintf(stderr, "usage: gnm_tsharp_table_test [capture|async|async-compute]\n");
            return 2;
        }
        if (mode == "async-compute") setenv("PS4_GNM_ASYNC_COMPUTE", "1", 1);
        char cap_dir[] = "/tmp/gnm_tsharp_capture.XXXXXX";
        if (mode == "async") {
            unsetenv("PS4_GNM_SYNC_ENCODE");
        } else {
            setenv("PS4_GNM_SYNC_ENCODE", "1", 1);
        }
        if (mode == "capture") {
            if (!mkdtemp(cap_dir)) {
                fprintf(stderr, "gnm_tsharp_table_test: FAIL no capture directory\n");
                return 1;
            }
            setenv("PS4_GNM_CAPTURE_FRAME", "0", 1);
            setenv("PS4_GNM_CAPTURE_DIR", cap_dir, 1);
        }
        setenv("PS4_GNM_SYNC_COMPILE", "1", 1);
        setenv("PS4_GNM_NO_SHADER_CACHE", "1", 1);
        setenv("PS4_GNM_NO_PSO_ARCHIVE", "1", 1);
        setenv("PS4_GNM_NO_LIB_STORE", "1", 1);
        setenv("PS4_GNM_MEM_LOG", "0", 1);
        void* m = mmap(nullptr, kMemSize, PROT_READ | PROT_WRITE, MAP_ANON | MAP_PRIVATE | MAP_NORESERVE, -1, 0);
        if (m == MAP_FAILED) {
            fprintf(stderr, "gnm_tsharp_table_test: FAIL no guest memory\n");
            return 1;
        }
        g_mem = (uint8_t*)m;
        memset(&g_ctx, 0, sizeof(g_ctx));
        g_ctx.mem_base = g_mem;
        g_ctx.mem_size = kMemSize;
        // a VM extent list (the renderer then checks T# table entries against it): nothing below
        // kHeap, one free extent from it on; kProt mapped, then PROT_NONE as a whole
        g_ctx.process_ctx = &g_ctx;
        pthread_mutex_init(&g_ctx.vm_mutex, nullptr);
        GuestVMExtent* root = (GuestVMExtent*)calloc(1, sizeof(GuestVMExtent));
        root->addr = kHeap;
        root->size = kMemSize - kHeap;
        root->is_free = true;
        g_ctx.vm_extents = root;
        if (recomp_vm_alloc_fixed(&g_ctx, kProt, 0x200000, PROT_READ | PROT_WRITE, 0, "direct") != kProt) {
            fprintf(stderr, "gnm_tsharp_table_test: FAIL could not map 0x%llx\n", (unsigned long long)kProt);
            return 1;
        }
        pthread_mutex_lock(&g_ctx.vm_mutex);
        for (GuestVMExtent* e = g_ctx.vm_extents; e; e = e->next)
            if (e->addr == kProt) e->prot = 0;
        pthread_mutex_unlock(&g_ctx.vm_mutex);
        if (!ps4draw::Init(&g_ctx)) {
            fprintf(stderr, "gnm_tsharp_table_test: FAIL the renderer did not start\n");
            return 1;
        }
        Setup();
        if (mode == "capture" || mode == "async" || mode == "async-compute") {
            if (mode == "capture") {
                TestHazardDma("capture");
            } else if (mode == "async") {
                TestHazardAsync();
            } else {
                TestHazardCompute();
            }
            if (mode == "capture") {
                std::error_code ec;
                std::filesystem::remove_all(cap_dir, ec);
            }
            if (g_fail) {
                fprintf(stderr, "gnm_tsharp_table_test %s: %d failure(s)\n", mode.c_str(), g_fail);
                return 1;
            }
            printf("gnm_tsharp_table_test %s: PASS\n", mode.c_str());
            return 0;
        }
        const ps4draw::ImageTableStats s0 = ps4draw::GetImageTableStats();
        Run(Form::Records, Op::Sample, kCode, kOut);
        // red, blue, and two entries without a texture: the junk record and the one past the table
        const ps4draw::ImageTableStats s1 = ps4draw::GetImageTableStats();
        CHECK(s1.bound - s0.bound == 2 && s1.rejected - s0.rejected == 1 && s1.empty - s0.empty == 1,
              "records/sample entries: %llu bound, %llu rejected, %llu empty", (unsigned long long)(s1.bound - s0.bound),
              (unsigned long long)(s1.rejected - s0.rejected), (unsigned long long)(s1.empty - s0.empty));
        Run(Form::Srt, Op::Sample, kCode + 0x10000, kOut + 0x1000);
        Run(Form::Records, Op::LoadMip, kCode + 0x20000, kOut + 0x2000);
        Run(Form::Srt, Op::LoadMip, kCode + 0x30000, kOut + 0x3000);
        TestLoop();
        TestHazard();
        TestAddressCheck();
        TestHazardSkip();
        TestStatsAddressBits();
        TestManyReads();
        TestGapBounds();
        TestUnrepresentable();
        TestJunkDecode();
        TestHazardDma("sync");
        TestHazardDraw();
        if (g_fail) {
            fprintf(stderr, "gnm_tsharp_table_test: %d failure(s)\n", g_fail);
            return 1;
        }
        printf("gnm_tsharp_table_test: PASS\n");
        return 0;
    }
}
