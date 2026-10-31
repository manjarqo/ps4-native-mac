// Occlusion queries through the real renderer (ps4draw::ZpassDone and ps4draw::Draw: translation,
// render pass, Metal visibility results, the fence action that writes the guest counters), on the
// backend PS4_GNM_METAL selects. A query is a ZPASS_DONE event at its begin address, draws, and one
// at the begin address + 8; per render backend (8 here) the DB writes a u64 with bit 63 (valid)
// 16 bytes apart, and the query's count is the end minus the begin, summed over the backends
// (Gnm::OcclusionQueryResults; shadPS4 liverpool.cpp EventWrite). Before, every event wrote a fake,
// growing counter (the same value into every backend, 0x2FFFFFF more per event): a query always
// read "visible", whatever it drew.
// Hand-assembled VS (a full-screen triangle at a constant depth) and PS (a constant colour) into a
// 64x64 RGBA8 target with a 64x64 32-bit float depth target. First, outside any query, a draw at
// z = 0.25 with the depth test ALWAYS and depth writes fills the depth target.
//   (1) a query around a draw at z = 0.75 with LESS: every sample fails, the count is 0;
//   (2) a query around a draw at z = 0.1 with LESS, in a 16x16 window scissor: 256 samples pass;
//   (3) a query around a draw at z = 0.75 with the depth test off: all 64x64 samples count;
//   (4) a query with no draw inside (a draw before its begin): 0;
//   (5) a query over two render passes (the second draw into another colour target): both count;
//   (6) a query around a 16x16 draw into 4x MSAA targets (DB_COUNT_CONTROL PERFECT_ZPASS_COUNTS,
//       SAMPLE_RATE 2, as radeonsi programs it): every sample counts, 16 * 16 * 4;
//   (7) a query around a draw with DB_COUNT_CONTROL.ZPASS_INCREMENT_DISABLE: 0;
//   (8) a query whose begin and end are PM4 EVENT_WRITE packets (decoded by ZpassDoneAddress, as
//       the CP does; ADDRESS_LO's low 3 bits set, which are not address bits): 16 * 16;
//   (9) a query that begins between two draws of one render pass: the pass is not split (one
//       render pass begun, no occlusion split), and only the second draw counts;
// and in every query each backend's begin and end have bit 63 set, and backends 1..7 count 0.
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>

#include <atomic>
#include <string>
#include <vector>

#include "gcn_recompiler.h"
#include "ps4_gnm_draw.h"

namespace {

int g_fail = 0;
#define CHECK(c, ...)                                                                        \
    do {                                                                                     \
        if (!(c)) {                                                                          \
            fprintf(stderr, "gnm_occlusion_query_test: FAIL %s:%d: ", __FILE__, __LINE__); \
            fprintf(stderr, __VA_ARGS__);                                                    \
            fprintf(stderr, "\n");                                                           \
            g_fail++;                                                                        \
        }                                                                                    \
    } while (0)

constexpr uint64_t kMemSize = 256ull << 20;
constexpr uint64_t kCode = 0x01000000; // one VS per depth at kCode + 0x10000 * k, the PS after them
constexpr uint64_t kRt2 = 0x02300000, kRt = 0x02000000, kDepth = 0x02100000, kQuery = 0x02200000;
constexpr uint64_t kRtMsaa = 0x02400000, kDepthMsaa = 0x02500000; // 4x MSAA colour and depth
constexpr uint32_t kW = 64, kH = 64, kBackends = 8;
constexpr uint64_t kValid = 0x8000000000000000ull;

uint8_t* g_mem = nullptr;
GuestContext g_ctx;

uint32_t Fbits(float f) {
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

uint32_t Vop1(uint32_t op, uint32_t vdst, uint32_t src0) { return 0x7E000000u | vdst << 17 | op << 9 | src0; }
uint32_t Vop2(uint32_t op, uint32_t vdst, uint32_t src0, uint32_t vsrc1) { return op << 25 | vdst << 17 | vsrc1 << 9 | src0; }
constexpr uint32_t V(uint32_t n) { return 0x100 + n; }
constexpr uint32_t kEnd = 0xBF810000u, kLiteral = 0xFF, kVMov = 1;

// position (4 * (id & 1) - 1, 4 * (id >> 1) - 1, z, 1): a triangle over the whole target
std::vector<uint32_t> VsProgram(float z, uint64_t hash) {
    constexpr uint32_t kVAndB32 = 27, kVLshrrevB32 = 22, kVAddI32 = 37, kVCvtF32I32 = 5, kVLshlrevB32 = 26;
    std::vector<uint32_t> c;
    c.push_back(Vop2(kVAndB32, 10, 0x81, 0));
    c.push_back(Vop2(kVLshrrevB32, 11, 0x81, 0));
    for (uint32_t r = 10; r < 12; ++r) {
        c.push_back(Vop2(kVLshlrevB32, r, 0x82, r));
        c.push_back(Vop2(kVAddI32, r, 0xC1, r)); // + (-1)
        c.push_back(Vop1(kVCvtF32I32, r, V(r)));
    }
    c.push_back(Vop1(kVMov, 12, kLiteral));
    c.push_back(Fbits(z));
    c.push_back(Vop1(kVMov, 13, 0xF2)); // w = 1.0
    c.push_back(0xF800020Fu);           // exp param0 v10, v11, v12, v13
    c.push_back(10u | 11u << 8 | 12u << 16 | 13u << 24);
    c.push_back(0xF80008CFu); // exp pos0 v10, v11, v12, v13 done
    c.push_back(10u | 11u << 8 | 12u << 16 | 13u << 24);
    c.push_back(kEnd);
    return WithFooter(c, hash);
}

std::vector<uint32_t> PsProgram() {
    std::vector<uint32_t> c;
    for (uint32_t r = 2; r < 6; ++r) c.push_back(Vop1(kVMov, r, 0xF2)); // 1.0
    c.push_back(0xF800180Fu); // exp mrt0 v2, v3, v4, v5 done vm
    c.push_back(2u | 3u << 8 | 4u << 16 | 5u << 24);
    c.push_back(kEnd);
    return WithFooter(c, 0x0CC1DE0000000F00ull);
}

void Load(uint64_t at, const std::vector<uint32_t>& code) {
    memcpy(g_mem + at, code.data(), code.size() * 4);
    ps4draw::NotifyGuestWrite(at, 0x10000, false, 0);
}

struct DrawCfg {
    uint64_t vs = 0;
    uint64_t rt = kRt;
    bool depth_test = true, depth_write = false;
    uint32_t zfunc = 1;                 // DB_DEPTH_CONTROL ZFUNC: 1 LESS, 7 ALWAYS
    uint32_t scissor_w = kW, scissor_h = kH;
    bool msaa = false;          // 4x MSAA colour and depth targets (at kRtMsaa, kDepthMsaa)
    uint32_t count_control = 0; // DB_COUNT_CONTROL
};

std::vector<uint32_t> Regs(const DrawCfg& d) {
    std::vector<uint32_t> regs(0x10000, 0);
    ps4draw::SetRegDefaults(regs.data());
    const uint64_t ps = kCode + 0x100000;
    auto stage = [&](uint32_t pgm, uint64_t code) {
        regs[pgm] = uint32_t(code >> 8);
        regs[pgm + 1] = uint32_t(code >> 40);
        regs[pgm + 2] = 3 | (3 << 6); // RSRC1: 16 VGPRs, 32 SGPRs
        regs[pgm + 3] = 0;            // RSRC2: no user SGPRs
    };
    stage(0x2C48, d.vs); // SPI_SHADER_PGM_LO_VS
    stage(0x2C08, ps);   // SPI_SHADER_PGM_LO_PS
    regs[0xA1B1] = 0;    // SPI_VS_OUT_CONFIG
    regs[0xA1B3] = 2;    // SPI_PS_INPUT_ENA: PERSP_CENTER
    regs[0xA1B4] = 2;    // SPI_PS_INPUT_ADDR
    regs[0xA1B6] = 0;    // SPI_PS_IN_CONTROL: no interpolants
    regs[0xA1C3] = 4;    // SPI_SHADER_POS_FORMAT: 4 components
    regs[0xA1C4] = 0;    // SPI_SHADER_Z_FORMAT
    regs[0xA1C5] = 9;    // SPI_SHADER_COL_FORMAT: MRT0 32_ABGR
    regs[0xA2D5] = 0;    // VGT_SHADER_STAGES_EN: VS + PS
    const uint64_t rt = d.msaa ? kRtMsaa : d.rt, depth = d.msaa ? kDepthMsaa : kDepth;
    regs[0xA318] = uint32_t(rt >> 8);  // CB_COLOR0_BASE
    regs[0xA319] = kW / 8 - 1;         // CB_COLOR0_PITCH
    regs[0xA31A] = kW * kH / 64 - 1;   // CB_COLOR0_SLICE
    regs[0xA31B] = 0;                  // CB_COLOR0_VIEW
    regs[0xA31C] = 0xA << 2;           // CB_COLOR0_INFO: 8_8_8_8 unorm
    regs[0xA31D] = 8 | (d.msaa ? 2u << 12 | 2u << 15 : 0); // CB_COLOR0_ATTRIB: linear, NUM_SAMPLES, NUM_FRAGMENTS
    regs[0xA08E] = 0xF;                // CB_TARGET_MASK
    regs[0xA08F] = 0xF;                // CB_SHADER_MASK
    regs[0xA202] = 0x00CC0010;         // CB_COLOR_CONTROL: normal, ROP3 copy
    // depth target: 32-bit float, 64x64, at kDepth; no stencil
    regs[0xA010] = 3 | (d.msaa ? 2u << 2 : 0); // DB_Z_INFO: FORMAT Z_32_FLOAT, NUM_SAMPLES
    regs[0xA011] = 0;                        // DB_STENCIL_INFO: invalid
    regs[0xA012] = uint32_t(depth >> 8);     // DB_Z_READ_BASE
    regs[0xA014] = uint32_t(depth >> 8);     // DB_Z_WRITE_BASE
    regs[0xA016] = (kW / 8 - 1) | (kH / 8 - 1) << 11; // DB_DEPTH_SIZE
    regs[0xA017] = kW * kH / 64 - 1;         // DB_DEPTH_SLICE
    regs[0xA002] = 0;                        // DB_DEPTH_VIEW
    regs[0xA000] = 0;                        // DB_RENDER_CONTROL
    regs[0xA001] = d.count_control;          // DB_COUNT_CONTROL
    if (d.msaa) regs[0xA2F8] = 2;            // PA_SC_AA_CONFIG: MSAA_NUM_SAMPLES 4x
    regs[0xA200] = (d.depth_test ? 1u << 1 : 0) | (d.depth_write ? 1u << 2 : 0) | d.zfunc << 4; // DB_DEPTH_CONTROL
    regs[0xA00C] = 0;                         // PA_SC_SCREEN_SCISSOR_TL
    regs[0xA00D] = kW | (kH << 16);
    regs[0xA081] = 0x80000000;                // PA_SC_WINDOW_SCISSOR_TL
    regs[0xA082] = d.scissor_w | (d.scissor_h << 16);
    regs[0xA090] = 0x80000000;                // PA_SC_GENERIC_SCISSOR_TL
    regs[0xA091] = kW | (kH << 16);
    regs[0xA10F] = Fbits(kW / 2.f);           // PA_CL_VPORT_XSCALE / XOFFSET / YSCALE / YOFFSET / ZSCALE / ZOFFSET
    regs[0xA110] = Fbits(kW / 2.f);
    regs[0xA111] = Fbits(-(kH / 2.f));
    regs[0xA112] = Fbits(kH / 2.f);
    regs[0xA113] = Fbits(1.f);
    regs[0xA114] = Fbits(0.f);
    regs[0xA206] = 0x43F; // PA_CL_VTE_CNTL
    regs[0xA204] = 0;     // PA_CL_CLIP_CNTL
    regs[0xA205] = 0;     // PA_SU_SC_MODE_CNTL: no culling
    regs[0xC242] = 4;     // VGT_PRIMITIVE_TYPE: triangle list
    return regs;
}

void DrawOnce(const DrawCfg& c, const char* name) {
    const std::vector<uint32_t> regs = Regs(c);
    ps4draw::DrawArgs args;
    args.count = 3;
    args.name = name;
    const uint64_t skipped0 = ps4draw::SkippedCount();
    ps4draw::Draw(&g_ctx, regs.data(), args);
    CHECK(ps4draw::SkippedCount() == skipped0, "%s: the draw was skipped", name);
}

// The fence actions so far have run (the counters are written after the GPU).
void Drain() {
    ps4draw::Flush(true);
    std::atomic<bool> done{false};
    ps4draw::AfterGpu([&] { done = true; });
    ps4draw::Flush(true);
    for (int i = 0; i < 2000 && !done; ++i) usleep(1000);
    CHECK(done, "the fence action did not run");
}

// A ZPASS_DONE at q as the CP sees it: an EVENT_WRITE packet (type 3, opcode 0x46, 3 payload
// dwords) decoded by ps4draw::ZpassDoneAddress; ADDRESS_LO carries junk in its low 3 bits.
void ZpassDonePacket(uint64_t q) {
    const uint32_t pkt[4] = {3u << 30 | 2u << 16 | 0x46u << 8, 57u | 1u << 8, uint32_t(q) | 5u, uint32_t(q >> 32)};
    const uint32_t payload_dw = ((pkt[0] >> 16) & 0x3FFF) + 1;
    const uint64_t addr = ps4draw::ZpassDoneAddress(pkt + 1, payload_dw);
    CHECK(addr == q, "the EVENT_WRITE packet decodes to 0x%llx, want 0x%llx", (unsigned long long)addr,
          (unsigned long long)q);
    if (addr) ps4draw::ZpassDone(addr, kBackends);
}

uint64_t* Q(uint64_t q) { return reinterpret_cast<uint64_t*>(g_mem + q); }

// The query at q: every begin and end valid; backend 0's end - begin is `want`, the others 0.
void CheckQuery(uint64_t q, uint64_t want, const char* what) {
    const uint64_t* r = Q(q);
    bool valid = true;
    uint64_t others = 0;
    for (uint32_t b = 0; b < kBackends; ++b) {
        valid = valid && (r[2 * b] & kValid) && (r[2 * b + 1] & kValid);
        if (b) others += (r[2 * b + 1] & ~kValid) - (r[2 * b] & ~kValid);
    }
    const uint64_t got = (r[1] & ~kValid) - (r[0] & ~kValid);
    printf("%s: begin 0x%llx end 0x%llx count %llu (want %llu), other backends %llu\n", what,
           (unsigned long long)r[0], (unsigned long long)r[1], (unsigned long long)got, (unsigned long long)want,
           (unsigned long long)others);
    CHECK(valid, "%s: a begin or end lacks the valid bit", what);
    CHECK(got == want, "%s: count %llu, want %llu", what, (unsigned long long)got, (unsigned long long)want);
    CHECK(others == 0, "%s: backends 1..7 count %llu, want 0", what, (unsigned long long)others);
}

void Run() {
    Load(kCode, VsProgram(0.25f, 0x0CC1DE0000000A25ull));
    Load(kCode + 0x10000, VsProgram(0.75f, 0x0CC1DE0000000A75ull));
    Load(kCode + 0x20000, VsProgram(0.1f, 0x0CC1DE0000000A10ull));
    Load(kCode + 0x100000, PsProgram());
    ps4draw::NotifyGuestWrite(kRt, 0x10000, false, 0);
    ps4draw::NotifyGuestWrite(kRt2, 0x10000, false, 0);
    ps4draw::NotifyGuestWrite(kRtMsaa, 0x10000, false, 0);
    ps4draw::NotifyGuestWrite(kDepthMsaa, 0x10000, false, 0);
    memset(g_mem + kQuery, 0, 0x1000);
    ps4draw::NotifyGuestWrite(kQuery, 0x1000, false, 0);

    DrawCfg fill;
    fill.vs = kCode;
    fill.depth_write = true;
    fill.zfunc = 7;
    DrawOnce(fill, "fill depth 0.25");

    const uint64_t q1 = kQuery, q2 = kQuery + 0x100, q3 = kQuery + 0x200, q4 = kQuery + 0x300;
    DrawCfg behind;
    behind.vs = kCode + 0x10000;
    ps4draw::ZpassDone(q1, kBackends);
    DrawOnce(behind, "behind");
    ps4draw::ZpassDone(q1 + 8, kBackends);

    DrawCfg front;
    front.vs = kCode + 0x20000;
    front.scissor_w = front.scissor_h = 16;
    ps4draw::ZpassDone(q2, kBackends);
    DrawOnce(front, "front 16x16");
    ps4draw::ZpassDone(q2 + 8, kBackends);

    DrawCfg untested;
    untested.vs = kCode + 0x10000;
    untested.depth_test = false;
    ps4draw::ZpassDone(q3, kBackends);
    DrawOnce(untested, "depth test off");
    ps4draw::ZpassDone(q3 + 8, kBackends);

    DrawOnce(untested, "before the begin");
    ps4draw::ZpassDone(q4, kBackends);
    ps4draw::ZpassDone(q4 + 8, kBackends);

    const uint64_t q5 = kQuery + 0x400;
    DrawCfg other = untested;
    other.rt = kRt2;
    ps4draw::ZpassDone(q5, kBackends);
    DrawOnce(front, "front 16x16, pass 1");
    DrawOnce(other, "depth test off, another target");
    ps4draw::ZpassDone(q5 + 8, kBackends);

    const uint64_t q6 = kQuery + 0x500, q7 = kQuery + 0x600, q8 = kQuery + 0x700, q9 = kQuery + 0x800;
    DrawCfg msaa = front;
    msaa.depth_test = false;
    msaa.msaa = true;
    msaa.count_control = 1u << 1 | 2u << 4; // PERFECT_ZPASS_COUNTS, SAMPLE_RATE 2 (4 samples)
    ps4draw::ZpassDone(q6, kBackends);
    DrawOnce(msaa, "4x MSAA 16x16");
    ps4draw::ZpassDone(q6 + 8, kBackends);

    DrawCfg disabled = untested;
    disabled.count_control = 1; // ZPASS_INCREMENT_DISABLE
    ps4draw::ZpassDone(q7, kBackends);
    DrawOnce(disabled, "increment disabled");
    ps4draw::ZpassDone(q7 + 8, kBackends);

    DrawCfg front_untested = front;
    front_untested.depth_test = false;
    ZpassDonePacket(q8);
    DrawOnce(front_untested, "16x16, PM4 events");
    ZpassDonePacket(q8 + 8);
    const uint32_t not_zpass[3] = {57u, uint32_t(q8), 0}; // PIXEL_PIPE_STAT_DUMP with event index 0
    CHECK(ps4draw::ZpassDoneAddress(not_zpass, 3) == 0, "an event with index 0 decodes as ZPASS_DONE");

    DrawOnce(msaa, "another pass first"); // the next draw begins a pass
    const ps4draw::EncodeCounts c0 = ps4draw::GetEncodeCounts();
    DrawOnce(front_untested, "before the begin, same pass");
    ps4draw::ZpassDone(q9, kBackends);
    DrawOnce(untested, "after the begin, same pass");
    ps4draw::ZpassDone(q9 + 8, kBackends);
    const ps4draw::EncodeCounts c1 = ps4draw::GetEncodeCounts();
    printf("(9) render passes begun %llu, split by occlusion queries %llu\n",
           (unsigned long long)(c1.render_passes - c0.render_passes),
           (unsigned long long)(c1.occlusion_splits - c0.occlusion_splits));
    CHECK(c1.render_passes - c0.render_passes == 1, "(9) %llu render passes begun, want 1 (no split at the begin)",
          (unsigned long long)(c1.render_passes - c0.render_passes));
    CHECK(c1.occlusion_splits == c0.occlusion_splits, "(9) a render pass split by the query");

    Drain();
    CheckQuery(q6, 16 * 16 * 4, "(6) 4x MSAA");
    CheckQuery(q7, 0, "(7) increment disabled");
    CheckQuery(q8, 16 * 16, "(8) PM4 events");
    CheckQuery(q9, kW * kH, "(9) begun inside a pass");
    CheckQuery(q5, 16 * 16 + kW * kH, "(5) two passes");
    CheckQuery(q1, 0, "(1) behind the depth");
    CheckQuery(q2, 16 * 16, "(2) 16x16 in front");
    CheckQuery(q3, kW * kH, "(3) depth test off");
    CheckQuery(q4, 0, "(4) no draw inside");
}

} // namespace

int main(int argc, char** argv) {
    @autoreleasepool {
        if (argc > 1) {
            fprintf(stderr, "usage: gnm_occlusion_query_test\n");
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
            fprintf(stderr, "gnm_occlusion_query_test: FAIL no guest memory\n");
            return 1;
        }
        g_mem = (uint8_t*)m;
        memset(&g_ctx, 0, sizeof(g_ctx));
        g_ctx.mem_base = g_mem;
        g_ctx.mem_size = kMemSize;
        if (!ps4draw::Init(&g_ctx)) {
            fprintf(stderr, "gnm_occlusion_query_test: FAIL the renderer did not start\n");
            return 1;
        }
        Run();
        if (g_fail) {
            fprintf(stderr, "gnm_occlusion_query_test: %d failure(s)\n", g_fail);
            return 1;
        }
        printf("gnm_occlusion_query_test: PASS\n");
        return 0;
    }
}
