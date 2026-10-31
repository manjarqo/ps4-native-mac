// Indirect quad-list draws (DRAW_INDIRECT / DRAW_INDEX_INDIRECT with VGT_PRIMITIVE_TYPE QuadList)
// through the real renderer (ps4draw::Draw): they are drawn on the GPU path, so the command
// processor never drains the GPU to read their arguments on the CPU (inFAMOUS Second Son drew 118
// such draws per frame, each a CPU-GPU round trip, Task 10.2 of its bring-up plan).
//
// The 8x8 RGBA16Float target is cut into 8 one-column quads: vertices 4q..4q+3 of the vertex
// buffer are the corners of column q, in quad-list order (two triangles 0 1 2 and 0 2 3). The VS
// calls a fetch shader (as in gnm_replay_test's draw kinds) that loads the position per vertex
// (v0 + s4) and an x offset per instance (v3 + s5, whole columns); the PS exports (1, 0.5, 0, 1).
// Cases, each into its own target:
//   - indexed, 32-bit indices, whose argument record a compute dispatch encoded just before the
//     draw writes (count 4, 3 instances from start instance 2, start index 4: the first 4 indices
//     are a decoy quad), the start instance written to the fetch shader's s5;
//   - non-indexed from start vertex 8 (2 quads), written to the fetch shader's s4;
//   - non-indexed with start vertex 8 and start instance 3 in a record whose CP writes them to no
//     SGPR: as on GCN (the index generator starts at 0, the instance id at 0) they change nothing;
//   - indexed, 16-bit, one quad whose indices are the last 4 of max_index;
//   - indexed with a count past max_index - start index: indices past INDEX_BUFFER_SIZE read as 0
//     (a quad of vertex 0 four times: nothing drawn), so only the quad inside is drawn.
//   - indexed with a partial last quad at max_index (its indices past it read as 0).
// Indexed quad lists reserve their worst case in the seq's pools, so a command buffer whose draws
// need more than one pool draws them all, one command buffer's pools are capped at 64 MiB (past it
// Draw refuses, counted quad-size), and the first pool's size follows demand and decays.
// Without the kernels (a test hook) Draw refuses quad lists, counted; a non-indexed quad list
// larger than the shared pattern draws nothing and is counted as skipped; indirect triangle lists
// apply the record's base vertex / start instance only where the CP writes them to SGPRs (patched
// on the GPU, or on the CPU without the kernel; a record pending GPU work writes is drawn as it is
// and counted).
// A triangle-fan indirect draw is still refused (the CPU converts fans) and counted under
// IndirectFallback::Emulation for its primitive type; the quad lists are counted under no reason.
// Each is compared with its expected columns, and the first three with the same draw issued
// direct (the CPU's quad-list conversion, BuildQuadListIndices). Draw must take every one (true),
// and the CPU must not wait for the GPU while they are drawn (GuestMemoryStats::waits).
//
// usage: gnm_indirect_quad_test [async]   (default: PS4_GNM_SYNC_ENCODE; async: the encoder thread)
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>

#include <string>
#include <vector>

#include "gcn_recompiler.h"
#include "ps4_gnm_capture.h"
#include "ps4_gnm_draw.h"
#include "ps4_gnm_resources.h"

namespace {

int g_fail = 0;
#define CHECK(c, ...)                                                                     \
    do {                                                                                  \
        if (!(c)) {                                                                       \
            fprintf(stderr, "gnm_indirect_quad_test: FAIL %s:%d: ", __FILE__, __LINE__); \
            fprintf(stderr, __VA_ARGS__);                                                 \
            fprintf(stderr, "\n");                                                        \
            g_fail++;                                                                     \
        }                                                                                 \
    } while (0)

constexpr uint64_t kMemSize = 1ull << 32;
constexpr uint64_t kVs = 0x190000, kPs = 0x1A0000, kFetch = 0x1B0000, kVsharps = 0x1C0000, kOffs = 0x1D0000;
constexpr uint64_t kVb = 0x1E0000, kIb = 0x200000, kArgs = 0x210000, kArgsSrc = 0x220000, kCs = 0x230000;
constexpr uint64_t kTarget = 0x400000; // + 0x10000 per draw
constexpr uint32_t kEnd = 0xBF810000;
constexpr uint32_t kQuadList = 19; // VGT_PRIMITIVE_TYPE DI_PT_QUADLIST
constexpr float kColOffset[8] = {0, 6, 1, 3, 5, 2, 4, 0}; // instance i moves its quad this many columns

uint8_t* g_mem = nullptr;
GuestContext g_ctx;

std::vector<uint32_t> WithFooter(const std::vector<uint32_t>& body, uint64_t hash) {
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

void Put(uint64_t addr, const void* p, size_t n) {
    memcpy(g_mem + addr, p, n);
    ps4draw::NotifyGuestWrite(addr, n, false, 0);
}

// The programs, the vertices (column q: x in [q / 4 - 1, (q + 1) / 4 - 1]), the instance offsets
// and their V#s.
void Setup() {
    // fetch shader: s_load_dwordx4 s[8:11], s[2:3], 0; s_load_dwordx4 s[12:15], s[2:3], 4;
    // v_add_i32 v0, s4, v0; v_add_i32 v3, s5, v3; s_waitcnt lgkmcnt(0);
    // buffer_load_format_xyzw v[4:7], v0, s[8:11] idxen; buffer_load_format_x v8, v3, s[12:15] idxen;
    // s_waitcnt vmcnt(0); s_setpc_b64 s[16:17]
    const uint32_t fetch[] = {0xC0840300, 0xC0860304, 0x4A000004, 0x4A060605, 0xBF8C007F, 0xE00C2000,
                              0x80020400, 0xE0002000, 0x80030803, 0xBF8C0F70, 0xBE802010};
    // VS: s_swappc_b64 s[16:17], s[0:1]; v_add_f32 v4, v8, v4; v_mov_b32 v6, 0.5; v_mov_b32 v7, 1.0;
    // exp param0 v[4:7]; exp pos0 v[4:7] done
    const auto vs = WithFooter({0xBE902100, 0x06080908, 0x7E0C02F0, 0x7E0E02F2, 0xF800020F, 0x07060504, 0xF80008CF,
                                0x07060504, kEnd},
                               0x5CA1AB1E0000C0A5ull);
    // PS: v0 = 1.0; v1 = 0.5; v2 = 0; v3 = 1.0; exp mrt0 v[0:3] done vm
    const auto ps = WithFooter({0x7E0002F2, 0x7E0202F0, 0x7E040280, 0x7E0602F2, 0xF800180F, 0x03020100, kEnd},
                               0x5CA1AB1E0000C0A4ull);
    // CS (64 threads): v2 = v0 << 2; buffer_load_dword v3, v2, s[4:7] offen; s_waitcnt 0;
    // buffer_store_dword v3, v2, s[8:11] offen: copies the 20 bytes of s[4:7]'s V# to s[8:11]'s
    // (the V#s' 20-byte bounds drop the other lanes)
    const auto cs = WithFooter({0x34040082, 0xE0301000, 0x80010302, 0xBF8C0000, 0xE0701000, 0x80020302, kEnd},
                               0x5CA1AB1E0000C0A6ull);
    Put(kFetch, fetch, sizeof(fetch));
    Put(kVs, vs.data(), vs.size() * 4);
    Put(kPs, ps.data(), ps.size() * 4);
    Put(kCs, cs.data(), cs.size() * 4);
    float verts[8 * 4][4];
    for (uint32_t q = 0; q < 8; ++q) {
        const float x0 = q * 0.25f - 1, x1 = x0 + 0.25f;
        const float c[4][2] = {{x0, -1}, {x1, -1}, {x1, 1}, {x0, 1}};
        for (uint32_t k = 0; k < 4; ++k) {
            verts[4 * q + k][0] = c[k][0];
            verts[4 * q + k][1] = c[k][1];
            verts[4 * q + k][2] = 0.5f;
            verts[4 * q + k][3] = 1;
        }
    }
    Put(kVb, verts, sizeof(verts));
    float offs[8];
    for (uint32_t i = 0; i < 8; ++i) offs[i] = kColOffset[i] * 0.25f;
    Put(kOffs, offs, sizeof(offs));
    const uint32_t vsharp[8] = {uint32_t(kVb), 16u << 16, 32, 4 | (5 << 3) | (6 << 6) | (7 << 9) | (7 << 12) | (14 << 15),
                                uint32_t(kOffs), 4u << 16, 8, 4 | (5 << 3) | (6 << 6) | (7 << 9) | (7 << 12) | (4 << 15)};
    Put(kVsharps, vsharp, sizeof(vsharp));
}

uint32_t Fbits(float f) {
    uint32_t u;
    memcpy(&u, &f, 4);
    return u;
}

// A quad-list draw into the 8x8 RGBA16Float linear target at `target`; s4 / s5: base vertex and
// start instance in user data (direct draws; 0 for the indirect ones, whose come from the record).
std::vector<uint32_t> DrawRegs(uint64_t target, uint32_t s4, uint32_t s5) {
    std::vector<uint32_t> regs(ps4gnm_capture::kNumRegs, 0);
    ps4draw::SetRegDefaults(regs.data());
    regs[0x2C48] = uint32_t(kVs >> 8);         // SPI_SHADER_PGM_LO_VS
    regs[0x2C4A] = 2 | (2 << 6) | (3u << 24);  // RSRC1_VS: 12 VGPRs, 24 SGPRs, VGPR_COMP_CNT 3 (v3 = instance id)
    regs[0x2C4B] = 6 << 1;                     // RSRC2_VS: 6 user SGPRs
    uint32_t* vud = &regs[0x2C4C];
    vud[0] = uint32_t(kFetch);
    vud[1] = uint32_t(kFetch >> 32);
    vud[2] = uint32_t(kVsharps);
    vud[3] = uint32_t(kVsharps >> 32);
    vud[4] = s4;
    vud[5] = s5;
    regs[0x2C08] = uint32_t(kPs >> 8); // SPI_SHADER_PGM_LO_PS
    regs[0x2C0A] = 1 | (1 << 6);
    regs[0x2C0B] = 0;
    regs[0xA1B3] = regs[0xA1B4] = 2; // SPI_PS_INPUT_ENA / ADDR: PERSP_CENTER
    regs[0xA1B6] = 0;                // SPI_PS_IN_CONTROL: no interpolants
    regs[0xA1B1] = 0;                // SPI_VS_OUT_CONFIG: 1 parameter
    regs[0xA1C3] = 4;                // SPI_SHADER_POS_FORMAT: POS0 4 components
    regs[0xA1C5] = 9;                // SPI_SHADER_COL_FORMAT: MRT0 32_ABGR
    regs[0xA08E] = regs[0xA08F] = 0xF;      // CB_TARGET_MASK / CB_SHADER_MASK
    regs[0xA202] = (1 << 4) | (0xCC << 16); // CB_COLOR_CONTROL: normal, copy
    regs[0xA206] = 0x43F;                   // PA_CL_VTE_CNTL
    const float vp[6] = {4, 4, 4, 4, 0.5f, 0.5f};
    memcpy(&regs[0xA10F], vp, sizeof(vp));
    regs[0xA205] = 0;         // PA_SU_SC_MODE_CNTL: no culling
    regs[0xC242] = kQuadList; // VGT_PRIMITIVE_TYPE
    uint32_t* cb = &regs[0xA318]; // CB_COLOR0_*
    cb[0] = uint32_t(target >> 8);
    cb[1] = 0;                         // PITCH: 8
    cb[2] = 0;                         // SLICE: 8 x 8
    cb[4] = (12u << 2) | (7u << 8);    // INFO: 16_16_16_16, float
    cb[5] = 8;                         // ATTRIB: linear aligned
    return regs;
}

// The identity the texture cache gives the target (as gnm_replay_test's TargetId).
ps4gnm_capture::GpuTextureId TargetId(const std::vector<uint32_t>& regs) {
    ps4gnm::ColorTarget ct;
    ps4gnm::DecodeColorTarget(regs.data(), 0, &ct);
    ps4gnm_capture::GpuTextureId g;
    g.kind = 1;
    g.address = ct.address;
    g.mtl_format = g.entry_format = ct.mtl_format;
    g.tex_type = g.mtl_type = (uint32_t)MTLTextureType2D;
    g.width = g.mtl_width = 8;
    g.height = g.mtl_height = 8;
    g.dfmt = (uint32_t)ct.dfmt;
    g.nfmt = (uint32_t)ct.nfmt;
    for (uint32_t k = 0; k < 4; ++k) g.cb_swizzle[k] = (uint8_t)ct.swizzle[k];
    g.usage = (uint32_t)(MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite |
                         MTLTextureUsagePixelFormatView);
    g.storage_mode = (uint32_t)MTLStorageModeShared;
    ps4gnm::SurfaceDesc sd = ct.ToSurfaceDesc();
    sd.width = 8;
    sd.height = 8;
    ps4gnm::SurfaceLayout l;
    ct.GetLayout(&l);
    g.size = l.total_size;
    ps4gnm::PackSurface(sd, l, &g.surface);
    return g;
}

// The columns of the target that hold the PS colour (bit c = column c, every row of it), or -1
// when a pixel holds neither that colour nor the target's initial zeros, or the target is not
// found.
int Columns(const std::vector<uint32_t>& regs, std::vector<uint8_t>* raw) {
    if (!ps4draw::ReplayReadTexture(TargetId(regs), raw) || raw->size() < 8 * 8 * 8) return -1;
    const uint16_t color[4] = {0x3C00, 0x3800, 0x0000, 0x3C00}, zero[4] = {};
    int cols = 0;
    for (uint32_t x = 0; x < 8; ++x) {
        uint32_t drawn = 0;
        for (uint32_t y = 0; y < 8; ++y) {
            const uint8_t* p = raw->data() + (y * 8 + x) * 8;
            if (!memcmp(p, color, 8)) drawn++;
            else if (memcmp(p, zero, 8)) return -1;
        }
        if (drawn == 8) cols |= 1 << x;
        else if (drawn) return -1;
    }
    return cols;
}

ps4draw::DrawArgs Args(const char* name, bool indexed, uint32_t index_type, uint32_t count, uint32_t index_offset,
                       uint32_t max_index, uint32_t instances, uint64_t indirect, int bv_ud = -1, int si_ud = -1) {
    ps4draw::DrawArgs a;
    a.name = name;
    a.indexed = indexed;
    a.index_base = indexed ? kIb : 0;
    a.index_type = index_type;
    a.index_offset = index_offset;
    a.count = count;
    a.max_index = max_index;
    a.num_instances = instances;
    a.indirect_addr = indirect;
    a.base_vertex_ud = bv_ud;
    a.start_instance_ud = si_ud;
    return a;
}

std::vector<uint32_t> CsRegs() {
    std::vector<uint32_t> regs(ps4gnm_capture::kNumRegs, 0);
    regs[0x2E07] = 64; // COMPUTE_NUM_THREAD_X
    regs[0x2E08] = regs[0x2E09] = 1;
    regs[0x2E0C] = uint32_t(kCs >> 8); // COMPUTE_PGM_LO
    regs[0x2E12] = 1;                  // RSRC1: 8 VGPRs
    regs[0x2E13] = 12 << 1;            // RSRC2: 12 user SGPRs
    uint32_t* ud = &regs[0x2E40];
    const uint32_t fmt = 4 | (5 << 3) | (6 << 6) | (7 << 9) | (4 << 12) | (4 << 15); // 32-bit uint
    ud[4] = uint32_t(kArgsSrc);
    ud[6] = 20;
    ud[7] = fmt;
    ud[8] = uint32_t(kArgs);
    ud[10] = 20;
    ud[11] = fmt;
    return regs;
}

struct Case {
    const char* name;
    bool indexed;
    uint32_t index_type, max_index;
    std::vector<uint32_t> indices;
    std::vector<uint32_t> record; // the indirect argument record
    bool gpu_written;             // the record is written by a compute dispatch before the draw
    int bv_ud, si_ud;             // the user SGPRs the CP writes the record's base vertex / start instance to
    // the same draw issued direct: count, first index, instances, base vertex (s4), start instance
    // (s5); none if count 0
    uint32_t direct_count, direct_offset, direct_instances, direct_s4, direct_s5;
    int columns; // expected
};

void PutIndices(const Case& c) {
    std::vector<uint8_t> b(c.indices.size() * (c.index_type ? 4 : 2) + 64, 0); // zeros past them
    for (size_t i = 0; i < c.indices.size(); ++i) {
        if (c.index_type) memcpy(b.data() + 4 * i, &c.indices[i], 4);
        else {
            const uint16_t h = (uint16_t)c.indices[i];
            memcpy(b.data() + 2 * i, &h, 2);
        }
    }
    Put(kIb, b.data(), b.size());
}

void RunCase(const Case& c, uint32_t n) {
    const uint64_t t_ind = kTarget + 0x20000 * n, t_dir = t_ind + 0x10000;
    std::vector<uint8_t> zeros(8 * 8 * 8, 0);
    Put(t_ind, zeros.data(), zeros.size());
    Put(t_dir, zeros.data(), zeros.size());
    PutIndices(c);
    const std::vector<uint32_t> regs = DrawRegs(t_ind, 0, 0);
    std::vector<uint32_t> rec = c.record;
    rec.resize(5, 0);
    if (c.gpu_written) {
        // what the CPU sees until the dispatch ran: a record that draws nothing
        const uint32_t empty[5] = {0, 0, 0, 0, 0};
        Put(kArgs, empty, sizeof(empty));
        Put(kArgsSrc, rec.data(), 20);
    } else {
        Put(kArgs, rec.data(), 20);
    }
    const uint64_t waits0 = ps4draw::GetGuestMemoryStats().waits;
    const uint64_t skipped0 = ps4draw::SkippedCount();
    if (c.gpu_written) {
        const std::vector<uint32_t> cregs = CsRegs();
        ps4draw::Dispatch(&g_ctx, cregs.data(), 1, 1, 1, 0, "gfx", ps4draw::kQueueGfx);
        ps4draw::ComputeBarrier(ps4draw::kQueueGfx); // the guest's CS_PARTIAL_FLUSH before the draw
    }
    const bool taken = ps4draw::Draw(&g_ctx, regs.data(),
                                     Args(c.name, c.indexed, c.index_type, 0, 0, c.max_index, 1, kArgs, c.bv_ud, c.si_ud));
    ps4draw::Flush(false); // committed, not waited for
    const uint64_t waits = ps4draw::GetGuestMemoryStats().waits - waits0;
    CHECK(taken, "%s: Draw refused the indirect draw (the CP would drain the GPU and draw it direct)", c.name);
    CHECK(waits == 0, "%s: the CPU waited for the GPU %llu times while it was drawn", c.name,
          (unsigned long long)waits);
    ps4draw::Flush(true);
    CHECK(ps4draw::SkippedCount() == skipped0, "%s: %llu draws skipped", c.name,
          (unsigned long long)(ps4draw::SkippedCount() - skipped0));
    std::vector<uint8_t> got, ref;
    const int cols = Columns(regs, &got);
    CHECK(cols == c.columns, "%s: columns 0x%x drawn, want 0x%x (-1: other pixels or no target)", c.name, cols,
          c.columns);
    if (!c.direct_count) return;
    const std::vector<uint32_t> dregs = DrawRegs(t_dir, c.direct_s4, c.direct_s5);
    CHECK(ps4draw::Draw(&g_ctx, dregs.data(),
                        Args(c.name, c.indexed, c.index_type, c.direct_count, c.direct_offset, c.max_index,
                             c.direct_instances, 0)),
          "%s: the direct draw was refused", c.name);
    ps4draw::Flush(true);
    const int dcols = Columns(dregs, &ref);
    CHECK(dcols == c.columns, "%s: the direct draw drew columns 0x%x, want 0x%x", c.name, dcols, c.columns);
    CHECK(got == ref, "%s: the indirect draw's pixels differ from the direct draw's", c.name);
}

std::vector<uint32_t> Quad(uint32_t q) { return {4 * q, 4 * q + 1, 4 * q + 2, 4 * q + 3}; }
std::vector<uint32_t> Cat(std::initializer_list<std::vector<uint32_t>> parts) {
    std::vector<uint32_t> v;
    for (const auto& x : parts) v.insert(v.end(), x.begin(), x.end());
    return v;
}

constexpr uint64_t kBigIb = 0x1000000; // index buffers of the pool tests

// Each indexed draw reserves its worst case, QuadListIndexBytes(max_index), in the seq's quad
// index pool, so none can find it full: three draws of 600000 indices (150000 quads naming columns
// 0..7 in turn, 3.6 MB converted each, 10.8 MB together, past one 4 MiB pool) in one command buffer
// each get a pool of their own and all draw every column, with no skip.
constexpr uint32_t kBigMax = 600000;
void PutCycleQuads(uint32_t indices) {
    std::vector<uint32_t> ib(indices);
    for (uint32_t i = 0; i < indices; ++i) ib[i] = 4 * ((i / 4) % 8) + i % 4;
    Put(kBigIb, ib.data(), ib.size() * 4);
}
void TestPoolsWorstCase() {
    using ps4draw::SkipReason;
    PutCycleQuads(kBigMax);
    const uint32_t rec[5] = {kBigMax, 1, 0, 0, 0};
    Put(kArgs, rec, sizeof(rec));
    std::vector<uint8_t> zeros(8 * 8 * 8, 0);
    std::vector<std::vector<uint32_t>> regs;
    for (uint32_t k = 0; k < 3; ++k) {
        const uint64_t t = kTarget + 0x380000 + 0x10000 * k;
        Put(t, zeros.data(), zeros.size());
        regs.push_back(DrawRegs(t, 0, 0));
    }
    ps4draw::Flush(true);
    const uint64_t b0 = ps4draw::QuadIndexPoolBytes(), q0 = ps4draw::SkippedCount(SkipReason::QuadIndices);
    const uint64_t waits0 = ps4draw::GetGuestMemoryStats().waits;
    for (uint32_t k = 0; k < 3; ++k) {
        ps4draw::DrawArgs a = Args("worst case", true, 1, 0, 0, kBigMax, 1, kArgs);
        a.index_base = kBigIb;
        CHECK(ps4draw::Draw(&g_ctx, regs[k].data(), a), "worst case %u: refused", k);
    }
    CHECK(ps4draw::GetGuestMemoryStats().waits == waits0, "worst case: the CPU waited for the GPU");
    ps4draw::Flush(true);
    const uint64_t db = ps4draw::QuadIndexPoolBytes() - b0;
    CHECK(db == 3 * (4ull << 20), "worst case: %llu pool bytes, want three 4 MiB pools", (unsigned long long)db);
    CHECK(ps4draw::SkippedCount(SkipReason::QuadIndices) == q0, "worst case: %llu draws skipped",
          (unsigned long long)(ps4draw::SkippedCount(SkipReason::QuadIndices) - q0));
    std::vector<uint8_t> raw;
    for (uint32_t k = 0; k < 3; ++k)
        CHECK(Columns(regs[k], &raw) == 0xFF, "worst case %u: columns 0x%x drawn, want 0xff", k, Columns(regs[k], &raw));
}

// One command buffer's quad index pools are capped at 64 MiB of worst cases: 18 draws of 600000
// indices (3.6 MB each, 64.8 MB) are taken and draw, the 19th is refused (counted quad-size, so
// the CP drains and draws it direct), and after the flush the next one is taken again.
void TestSeqDemandCap() {
    using ps4draw::IndirectFallback;
    using ps4draw::SkipReason;
    PutCycleQuads(kBigMax);
    const uint32_t rec[5] = {kBigMax, 1, 0, 0, 0};
    Put(kArgs, rec, sizeof(rec));
    const uint64_t t = kTarget + 0x3D0000, t2 = kTarget + 0x3E0000;
    std::vector<uint8_t> zeros(8 * 8 * 8, 0);
    Put(t, zeros.data(), zeros.size());
    Put(t2, zeros.data(), zeros.size());
    const std::vector<uint32_t> regs = DrawRegs(t, 0, 0), regs2 = DrawRegs(t2, 0, 0);
    ps4draw::DrawArgs a = Args("seq cap", true, 1, 0, 0, kBigMax, 1, kArgs);
    a.index_base = kBigIb;
    ps4draw::Flush(true);
    const uint64_t f0 = ps4draw::IndirectFallbacks(IndirectFallback::QuadSize);
    const uint64_t s0 = ps4draw::SkippedCount();
    uint32_t taken = 0;
    for (uint32_t k = 0; k < 18; ++k) taken += ps4draw::Draw(&g_ctx, regs.data(), a) ? 1 : 0;
    const bool past = ps4draw::Draw(&g_ctx, regs.data(), a);
    CHECK(taken == 18 && !past, "seq cap: %u of the first 18 draws taken, the 19th %s", taken,
          past ? "taken (want refused)" : "refused");
    CHECK(ps4draw::IndirectFallbacks(IndirectFallback::QuadSize) - f0 == 1, "seq cap: %llu quad-size fallbacks, want 1",
          (unsigned long long)(ps4draw::IndirectFallbacks(IndirectFallback::QuadSize) - f0));
    ps4draw::Flush(true);
    CHECK(ps4draw::Draw(&g_ctx, regs2.data(), a), "seq cap: the draw after the flush was refused");
    ps4draw::Flush(true);
    CHECK(ps4draw::SkippedCount() == s0, "seq cap: %llu draws skipped", (unsigned long long)(ps4draw::SkippedCount() - s0));
    std::vector<uint8_t> raw;
    CHECK(Columns(regs, &raw) == 0xFF, "seq cap: columns 0x%x drawn, want 0xff", Columns(regs, &raw));
    CHECK(Columns(regs2, &raw) == 0xFF, "seq cap, after the flush: columns 0x%x drawn, want 0xff", Columns(regs2, &raw));
}

// The size of a seq's first pool follows the largest seq demand (TestPoolsWorstCase's: one 4 MiB
// chunk) and halves after kQuadHintDecaySeqs (256) seqs with quad draws that needed no more: a
// one-quad draw per seq gets a 4 MiB pool in seqs 0..255 after it, 2 MiB in seq 256.
void TestPoolHintDecays() {
    const uint32_t rec[5] = {4, 1, 0, 0, 0};
    Put(kArgs, rec, sizeof(rec));
    const uint64_t t = kTarget + 0x3B0000;
    std::vector<uint8_t> zeros(8 * 8 * 8, 0);
    Put(t, zeros.data(), zeros.size());
    const std::vector<uint32_t> regs = DrawRegs(t, 0, 0);
    uint64_t first = 0, before = 0, after = 0;
    for (uint32_t s = 0; s <= 256; ++s) {
        const uint64_t b0 = ps4draw::QuadIndexPoolBytes();
        ps4draw::DrawArgs a = Args("decay", true, 1, 0, 0, 8, 1, kArgs);
        a.index_base = kBigIb;
        CHECK(ps4draw::Draw(&g_ctx, regs.data(), a), "decay %u: refused", s);
        ps4draw::Flush(true);
        const uint64_t db = ps4draw::QuadIndexPoolBytes() - b0;
        if (s == 0) first = db;
        if (s == 255) before = db;
        if (s == 256) after = db;
    }
    CHECK(first == 4u << 20 && before == 4u << 20 && after == 2u << 20,
          "decay: first pools %llu, %llu (seq 255), %llu (seq 256) bytes, want 4 MiB, 4 MiB, 2 MiB",
          (unsigned long long)first, (unsigned long long)before, (unsigned long long)after);
    std::vector<uint8_t> raw;
    CHECK(Columns(regs, &raw) == 1, "decay: columns 0x%x drawn, want 0x1", Columns(regs, &raw));
}

// A draw larger than the seq's first pool (3000 quads: 72000 bytes of indices) draws whole the
// first time: its region is reserved before the pool is chosen, not found missing on the GPU.
void TestLargeFirstDraw() {
    using ps4draw::SkipReason;
    constexpr uint32_t kQuads = 3000;
    PutCycleQuads(kQuads * 4);
    const uint32_t rec[5] = {kQuads * 4, 1, 0, 0, 0};
    Put(kArgs, rec, sizeof(rec));
    const uint64_t t = kTarget + 0x3C0000;
    std::vector<uint8_t> zeros(8 * 8 * 8, 0);
    Put(t, zeros.data(), zeros.size());
    const std::vector<uint32_t> regs = DrawRegs(t, 0, 0);
    ps4draw::DrawArgs a = Args("large first draw", true, 1, 0, 0, kQuads * 4, 1, kArgs);
    a.index_base = kBigIb;
    const uint64_t q0 = ps4draw::SkippedCount(SkipReason::QuadIndices);
    CHECK(ps4draw::Draw(&g_ctx, regs.data(), a), "large first draw: refused");
    ps4draw::Flush(true);
    std::vector<uint8_t> raw;
    CHECK(Columns(regs, &raw) == 0xFF, "large first draw: columns 0x%x drawn, want 0xff", Columns(regs, &raw));
    CHECK(ps4draw::SkippedCount(SkipReason::QuadIndices) == q0, "large first draw: counted as skipped");
}

// Without the GPU path's kernel (the test hook), Draw refuses an indirect quad list, so the CP
// falls back instead of the encoder skipping it, and counts it under needs-emulation:QuadList.
void TestKernelUnavailable() {
    using ps4draw::IndirectFallback;
    const std::vector<uint32_t> regs = DrawRegs(kTarget + 0x300000, 0, 0);
    const uint32_t rec[4] = {4, 1, 0, 0};
    Put(kArgs, rec, sizeof(rec));
    const uint64_t f0 = ps4draw::IndirectFallbacks(IndirectFallback::Emulation, kQuadList);
    const uint64_t skipped0 = ps4draw::SkippedCount();
    ps4draw::TestSetIndirectKernels(false);
    const bool taken = ps4draw::Draw(&g_ctx, regs.data(), Args("no kernel", false, 0, 0, 0, 0, 1, kArgs));
    ps4draw::TestSetIndirectKernels(true);
    ps4draw::Flush(true);
    CHECK(!taken, "no kernel: Draw took the indirect quad list");
    CHECK(ps4draw::IndirectFallbacks(IndirectFallback::Emulation, kQuadList) - f0 == 1,
          "no kernel: counted %llu times under needs-emulation:QuadList, want 1",
          (unsigned long long)(ps4draw::IndirectFallbacks(IndirectFallback::Emulation, kQuadList) - f0));
    CHECK(ps4draw::SkippedCount() == skipped0, "no kernel: the draw was counted as skipped");
}

// A non-indexed indirect quad list larger than the shared pattern (64K quads at first) draws
// nothing, is counted as a skipped draw (quad-indices) once the encoder sees the kernel's record of
// it, and the next draw has a pattern grown to its count (here a 2-quad draw, columns 0 and 1).
void TestPatternOverflow() {
    using ps4draw::SkipReason;
    const uint64_t t1 = kTarget + 0x310000, t2 = kTarget + 0x320000;
    std::vector<uint8_t> zeros(8 * 8 * 8, 0);
    Put(t1, zeros.data(), zeros.size());
    Put(t2, zeros.data(), zeros.size());
    const uint32_t big[4] = {4 * 65537, 1, 0, 0}, small[4] = {8, 1, 0, 0};
    const uint64_t q0 = ps4draw::SkippedCount(SkipReason::QuadIndices);
    Put(kArgs, big, sizeof(big));
    const std::vector<uint32_t> r1 = DrawRegs(t1, 0, 0), r2 = DrawRegs(t2, 0, 0);
    CHECK(ps4draw::Draw(&g_ctx, r1.data(), Args("oversize", false, 0, 0, 0, 0, 1, kArgs)), "oversize: refused");
    ps4draw::Flush(true);
    std::vector<uint8_t> raw;
    CHECK(Columns(r1, &raw) == 0, "oversize: columns 0x%x drawn, want none (not a truncated draw)", Columns(r1, &raw));
    Put(kArgs, small, sizeof(small));
    CHECK(ps4draw::Draw(&g_ctx, r2.data(), Args("after oversize", false, 0, 0, 0, 0, 1, kArgs)), "after oversize: refused");
    ps4draw::Flush(true);
    CHECK(ps4draw::SkippedCount(SkipReason::QuadIndices) - q0 == 1, "oversize: %llu quad-indices skips counted, want 1",
          (unsigned long long)(ps4draw::SkippedCount(SkipReason::QuadIndices) - q0));
    CHECK(Columns(r2, &raw) == 3, "after oversize: columns 0x%x drawn, want 0x3", Columns(r2, &raw));
}

// Indirect triangle-list draws (the GPU path Metal draws from the record as it is): quad 0 as two
// triangles through 16-bit indices 0 1 2 0 2 3, the record's base vertex 8 and start instance 2.
// Written to no SGPR, GCN ignores them (column 0): the record is copied with those fields replaced
// on the GPU (args-patched), or on the CPU without the kernel (the test hook); written to s4 / s5
// they move the draw to quad 2 with instance offset 1 (column 3). A record pending GPU work writes
// is drawn as it is and counted: with values 0 column 0, with base vertex 8 and start instance 2
// column 3 (pinning the as-is rule).
void TestTriangleRecordOffsets() {
    constexpr uint32_t kTriList = 4;
    const uint16_t idx[12] = {0, 1, 2, 0, 2, 3, 4, 5, 6, 4, 6, 7};
    Put(kIb, idx, sizeof(idx));
    struct {
        const char* name;
        int bv_ud, si_ud;
        bool gpu_written;
        int columns;
        bool kernels; // the args patch kernel available
        uint32_t patched, copied; // records corrected on the GPU, on the CPU
        uint32_t count;           // indices: 6 quad 0, 12 quads 0 and 1
    } cases[] = {{"triangle list, record offsets written to no SGPR", -1, -1, false, 1 << 0, true, 1, 0, 6},
                 // two quads, so a copy left from the case before cannot pass for this one's
                 {"triangle list, record offsets written to no SGPR, no kernel", -1, -1, false, 3, false, 0, 1, 12},
                 {"triangle list, record offsets written to s4 / s5", 4, 5, false, 1 << 3, true, 0, 0, 6},
                 {"triangle list, record written by a dispatch", -1, -1, true, 1 << 0, true, 0, 0, 6},
                 // pinned as it is: a GPU-written record's offsets are applied unchecked (quad 2,
                 // instance offset 1), and counted
                 {"triangle list, record with offsets written by a dispatch", -1, -1, true, 1 << 3, true, 0, 0, 6}};
    uint32_t n = 0;
    for (const auto& c : cases) {
        const uint64_t t = kTarget + 0x330000 + 0x10000 * n++;
        std::vector<uint8_t> zeros(8 * 8 * 8, 0);
        Put(t, zeros.data(), zeros.size());
        std::vector<uint32_t> regs = DrawRegs(t, 0, 0);
        regs[0xC242] = kTriList;
        const uint32_t zero[5] = {};
        if (c.gpu_written) {
            const bool offsets = c.columns != 1 << 0;
            const uint32_t gpu_rec[5] = {c.count, 1, 0, offsets ? 8u : 0u, offsets ? 2u : 0u};
            Put(kArgs, zero, sizeof(zero));
            Put(kArgsSrc, gpu_rec, sizeof(gpu_rec));
        } else {
            const uint32_t rec[5] = {c.count, 1, 0, 8, 2};
            Put(kArgs, rec, sizeof(rec));
        }
        const uint64_t u0 = ps4draw::IndirectRecordOffsetsUnchecked();
        const uint64_t p0 = ps4draw::ArgsPatched(false), c0 = ps4draw::ArgsPatched(true);
        const uint64_t skipped0 = ps4draw::SkippedCount();
        ps4draw::TestSetIndirectKernels(c.kernels);
        if (c.gpu_written) {
            const std::vector<uint32_t> cregs = CsRegs();
            ps4draw::Dispatch(&g_ctx, cregs.data(), 1, 1, 1, 0, "gfx", ps4draw::kQueueGfx);
            ps4draw::ComputeBarrier(ps4draw::kQueueGfx);
        }
        CHECK(ps4draw::Draw(&g_ctx, regs.data(), Args(c.name, true, 0, 0, 0, 12, 1, kArgs, c.bv_ud, c.si_ud)),
              "%s: refused", c.name);
        ps4draw::Flush(true);
        ps4draw::TestSetIndirectKernels(true);
        CHECK(ps4draw::ArgsPatched(false) - p0 == c.patched && ps4draw::ArgsPatched(true) - c0 == c.copied,
              "%s: %llu records patched on the GPU, %llu on the CPU, want %u, %u", c.name,
              (unsigned long long)(ps4draw::ArgsPatched(false) - p0), (unsigned long long)(ps4draw::ArgsPatched(true) - c0),
              c.patched, c.copied);
        CHECK(ps4draw::SkippedCount() == skipped0, "%s: skipped", c.name);
        const uint64_t du = ps4draw::IndirectRecordOffsetsUnchecked() - u0;
        CHECK(du == (c.gpu_written ? 1u : 0u), "%s: %llu records counted unchecked", c.name, (unsigned long long)du);
        std::vector<uint8_t> raw;
        const int cols = Columns(regs, &raw);
        CHECK(cols == c.columns, "%s: columns 0x%x drawn, want 0x%x", c.name, cols, c.columns);
    }
}

} // namespace

int main(int argc, char** argv) {
    @autoreleasepool {
        const std::string mode = argc > 1 ? argv[1] : "";
        if (mode != "" && mode != "async") {
            fprintf(stderr, "usage: gnm_indirect_quad_test [async]\n");
            return 2;
        }
        if (mode == "async") unsetenv("PS4_GNM_SYNC_ENCODE");
        else setenv("PS4_GNM_SYNC_ENCODE", "1", 1);
        setenv("PS4_GNM_SYNC_COMPILE", "1", 1);
        setenv("PS4_GNM_NO_SHADER_CACHE", "1", 1);
        setenv("PS4_GNM_NO_PSO_ARCHIVE", "1", 1);
        setenv("PS4_GNM_NO_LIB_STORE", "1", 1);
        setenv("PS4_GNM_MEM_LOG", "0", 1);
        void* m = mmap(nullptr, kMemSize, PROT_READ | PROT_WRITE, MAP_ANON | MAP_PRIVATE | MAP_NORESERVE, -1, 0);
        if (m == MAP_FAILED) {
            fprintf(stderr, "gnm_indirect_quad_test: FAIL no guest memory\n");
            return 1;
        }
        g_mem = (uint8_t*)m;
        memset(&g_ctx, 0, sizeof(g_ctx));
        g_ctx.mem_base = g_mem;
        g_ctx.mem_size = kMemSize;
        if (!ps4draw::Init(&g_ctx)) {
            fprintf(stderr, "gnm_indirect_quad_test: FAIL the renderer did not start\n");
            return 1;
        }
        Setup();
        const Case cases[] = {
            // indices 0..3 a decoy (quad 7), 4..7 quad 0; 3 instances from 2: offsets 1, 3, 5
            {"indexed 32-bit, record written by a dispatch, 3 instances from instance 2 and index 4", true, 1, 8,
             Cat({Quad(7), Quad(0)}), {4, 3, 4, 0, 2}, true, -1, 5, 4, 4, 3, 0, 2, (1 << 1) | (1 << 3) | (1 << 5)},
            // vertices 8..15: quads 2 and 3
            {"non-indexed from vertex 8, 2 quads", false, 0, 0, {}, {8, 1, 8, 0}, false, 4, -1, 8, 0, 1, 8, 0,
             (1 << 2) | (1 << 3)},
            // the record's start vertex and start instance reach no SGPR: quad 0, offset 0
            {"non-indexed, start vertex and instance written to no SGPR", false, 0, 0, {}, {4, 1, 8, 3}, false, -1, -1,
             4, 0, 1, 0, 0, 1 << 0},
            // 16-bit, max_index 12: the last 4 indices name quad 5
            {"indexed 16-bit, the last quad of max_index", true, 0, 12, Cat({Quad(7), Quad(7), Quad(5)}),
             {4, 1, 8, 0, 0}, false, -1, -1, 4, 8, 1, 0, 0, 1 << 5},
            // 12 indices from index 4 with max_index 8: quad 3, then 8 indices past INDEX_BUFFER_SIZE
            // (read as 0: degenerate). The decoy quad 7 in memory past max_index is not drawn.
            // the direct draw (BuildQuadListIndices) reads past max_index as 0 as well
            {"indexed 32-bit, count past max_index", true, 1, 8, Cat({Quad(6), Quad(3), Quad(7), Quad(7)}),
             {12, 1, 4, 0, 0}, false, -1, -1, 12, 4, 1, 0, 0, 1 << 3},
            // max_index 10: quad 3, then a partial quad of indices 8, 9 (vertices 0, 1) and 10, 11 past
            // max_index (read as 0: degenerate); memory holds 2, 3 there, which would complete quad 0
            {"indexed 32-bit, a partial last quad at max_index", true, 1, 10, Cat({Quad(6), Quad(3), Quad(0)}),
             {8, 1, 4, 0, 0}, false, -1, -1, 8, 4, 1, 0, 0, 1 << 3},
        };
        using ps4draw::IndirectFallback;
        uint64_t fb0[(size_t)IndirectFallback::Count];
        for (size_t i = 0; i < (size_t)IndirectFallback::Count; ++i) fb0[i] = ps4draw::IndirectFallbacks((IndirectFallback)i, kQuadList);
        uint32_t n = 0;
        for (const Case& c : cases) RunCase(c, n++);
        for (size_t i = 0; i < (size_t)IndirectFallback::Count; ++i)
            CHECK(ps4draw::IndirectFallbacks((IndirectFallback)i, kQuadList) == fb0[i],
                  "the quad lists counted %llu fallbacks of reason %zu",
                  (unsigned long long)(ps4draw::IndirectFallbacks((IndirectFallback)i, kQuadList) - fb0[i]), i);
        {
            constexpr uint32_t kFan = 5; // DI_PT_TRIFAN
            std::vector<uint32_t> regs = DrawRegs(kTarget + 0x200000, 0, 0);
            regs[0xC242] = kFan;
            const uint32_t rec[4] = {4, 1, 0, 0};
            Put(kArgs, rec, sizeof(rec));
            const uint64_t f0 = ps4draw::IndirectFallbacks(IndirectFallback::Emulation, kFan);
            CHECK(!ps4draw::Draw(&g_ctx, regs.data(), Args("fan", false, 0, 0, 0, 0, 1, kArgs)),
                  "an indirect triangle fan was taken: the GPU path cannot convert fans");
            CHECK(ps4draw::IndirectFallbacks(IndirectFallback::Emulation, kFan) - f0 == 1,
                  "the refused fan was counted %llu times under needs-emulation, want 1",
                  (unsigned long long)(ps4draw::IndirectFallbacks(IndirectFallback::Emulation, kFan) - f0));
            ps4draw::Flush(true);
        }
        TestLargeFirstDraw();
        TestPoolsWorstCase();
        TestPoolHintDecays();
        TestSeqDemandCap();
        TestKernelUnavailable();
        TestPatternOverflow();
        TestTriangleRecordOffsets();
        if (g_fail) {
            fprintf(stderr, "gnm_indirect_quad_test%s%s: %d failure(s)\n", mode.empty() ? "" : " ", mode.c_str(), g_fail);
            return 1;
        }
        printf("gnm_indirect_quad_test%s%s: PASS (%u cases)\n", mode.empty() ? "" : " ", mode.c_str(), n);
        return 0;
    }
}
