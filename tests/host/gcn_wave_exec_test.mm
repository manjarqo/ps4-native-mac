// Wave-level GCN instructions on Metal, whose simdgroups are 32 wide (a wave64 compute shader
// runs as two simdgroups), checked by running small compute shaders and reading their output.
// Uncharted 4's chapter 1 compute shaders (tests/host/data/u4_cs_*, gcn_u4_cs_test) use them:
//  A. s_mov_b32 exec_hi after v_cmpx: lanes 32-63 must take the written half, not the low half
//     (they ran with exec_lo's bits: 16 lanes of 32 in the upper half here).
//  B. V# dwords spilled to VGPR lanes (v_writelane / v_readlane) and used for a store.
//  C. A wave64 compare whose 64-bit result (vcc) is read from both halves.
//  D-G. Cross-lane instructions of a wave64 (v_readfirstlane, v_readlane, scalar
//     instructions on EXEC and 64-bit masks, v_mbcnt, ADD_TID buffers): lanes 32-63 run in the
//     second simdgroup and must see the whole wave.
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>

#include <algorithm>
#include <cstdio>
#include <cstring>
#include <string>
#include <vector>

#include "gcn_recompiler.h"

namespace {

int g_fail = 0;
#define CHECK(c, ...)                                                                         \
    do {                                                                                      \
        if (!(c)) {                                                                           \
            std::fprintf(stderr, "gcn_wave_exec_test: FAIL %s:%d: ", __FILE__, __LINE__); \
            std::fprintf(stderr, __VA_ARGS__);                                                \
            std::fprintf(stderr, "\n");                                                       \
            g_fail++;                                                                         \
        }                                                                                     \
    } while (0)

constexpr uint64_t kGuestBase = 0x10000000;
constexpr uint64_t kGuestSize = 1u << 20;

struct Guest {
    id<MTLBuffer> buf;
    uint8_t* p(uint64_t a) { return static_cast<uint8_t*>(buf.contents) + (a - kGuestBase); }
    static bool Read(void* ctx, uint64_t addr, void* dst, uint64_t size) {
        auto* g = static_cast<Guest*>(ctx);
        if (addr < kGuestBase || addr + size > kGuestBase + kGuestSize) return false;
        std::memcpy(dst, g->p(addr), size);
        return true;
    }
};

std::vector<uint32_t> WithFooter(const std::vector<uint32_t>& body, uint64_t hash) {
    std::vector<uint32_t> code = {0xBEEB03FF, 0};
    code.insert(code.end(), body.begin(), body.end());
    while (code.size() % 2) code.push_back(0xBF800000); // s_nop
    code[1] = uint32_t(code.size() / 2 - 1);
    uint8_t bi[32] = {'O', 'r', 'b', 'S', 'h', 'd', 'r', 7};
    const uint32_t w = (uint32_t(code.size() * 4) & 0xFFFFFF) << 8;
    std::memcpy(bi + 8, &w, 4);
    std::memcpy(bi + 16, &hash, 8);
    const size_t at = code.size();
    code.resize(at + 8);
    std::memcpy(&code[at], bi, 32);
    return code;
}

// V#: base, num_records, stride, data/number format (dfmt 4 = 32 / nfmt 4 = uint by default).
void VSharp(uint32_t* v, uint64_t base, uint32_t records, uint32_t stride, uint32_t dfmt = 4, uint32_t nfmt = 4) {
    v[0] = uint32_t(base);
    v[1] = (uint32_t(base >> 32) & 0xFFF) | (stride << 16);
    v[2] = records;
    v[3] = 4 | (5 << 3) | (6 << 6) | (7 << 9) | (nfmt << 12) | (dfmt << 15);
}

gcn_shader* Compile(Guest& g, uint64_t code, const uint32_t ud[16], uint32_t threads) {
    gcn_profile prof;
    gcn_profile_default_metal(&prof);
    gcn_runtime_info rt{};
    rt.hw_stage = GCN_HW_CS;
    rt.sw_stage = GCN_SW_COMPUTE;
    rt.num_allocated_vgprs = 8;
    rt.num_user_data = 12;
    rt.cs.workgroup_size[0] = threads;
    rt.cs.workgroup_size[1] = rt.cs.workgroup_size[2] = 1;
    gcn_compile_desc d{};
    d.hw_stage = GCN_HW_CS;
    d.sw_stage = GCN_SW_COMPUTE;
    d.code_addr = code;
    std::memcpy(d.user_data, ud, 64);
    d.runtime = &rt;
    d.profile = &prof;
    d.read_guest = Guest::Read;
    d.read_ctx = &g;
    d.flags = GCN_COMPILE_EMIT_MSL;
    gcn_shader* sh = nullptr;
    char err[512] = {};
    const gcn_status st = gcn_compile(&d, &sh, err, sizeof(err));
    CHECK(st == GCN_OK && sh, "test CS does not translate: %s", err);
    return st == GCN_OK ? sh : nullptr;
}

// Binds like the renderer's BindStage: a guest buffer at the dword below its base, with
// buf_sizes = size + (base & 3) rounded up to dwords.
bool Run(id<MTLDevice> dev, Guest& g, const gcn_shader* sh, const uint32_t ud[16], uint32_t threads) {
    gcn_shader_info info;
    gcn_shader_get_info(sh, &info);
    NSError* e = nil;
    MTLCompileOptions* o = [MTLCompileOptions new];
    o.languageVersion = MTLLanguageVersion2_3;
    id<MTLLibrary> lib = [dev newLibraryWithSource:[NSString stringWithUTF8String:gcn_shader_msl(sh)] options:o error:&e];
    if (!lib) {
        std::fprintf(stderr, "MSL: %s\n", e.localizedDescription.UTF8String);
        return false;
    }
    id<MTLComputePipelineState> pso = [dev newComputePipelineStateWithFunction:[lib newFunctionWithName:@"main0"] error:&e];
    if (!pso) return false;
    std::vector<uint32_t> flat(std::max<uint32_t>(info.flatbuf_size_dw, 16));
    gcn_shader_build_flatbuf(sh, ud, Guest::Read, &g, flat.data(), flat.size());
    alignas(16) uint8_t push[(sizeof(gcn_push_data) + 15) & ~size_t(15)] = {};
    auto* pd = reinterpret_cast<gcn_push_data*>(push);
    id<MTLCommandQueue> q = [dev newCommandQueue];
    id<MTLCommandBuffer> cb = [q commandBuffer];
    id<MTLComputeCommandEncoder> enc = [cb computeCommandEncoder];
    [enc setComputePipelineState:pso];
    for (uint32_t i = 0; i < info.num_buffers; i++) {
        gcn_buffer_binding b;
        gcn_shader_get_buffer(sh, i, &b);
        for (uint32_t k = 0; k < b.num_msl_buffers; k++) {
            if (b.type == GCN_BUFFER_FLATBUF) {
                [enc setBytes:flat.data() length:flat.size() * 4 atIndex:b.msl_buffers[k]];
                continue;
            }
            if (b.type != GCN_BUFFER_GUEST) return false;
            uint32_t v[4];
            gcn_buffer_desc d{};
            if (!gcn_shader_fetch_buffer_sharp(sh, i, flat.data(), info.code_addr, v)) return false;
            gcn_decode_buffer(v, &d);
            const uint64_t base = d.base_address & ~3ull;
            [enc setBuffer:g.buf offset:base - kGuestBase atIndex:b.msl_buffers[k]];
            if (b.buffer_slot < GCN_MAX_BUFFERS)
                pd->buf_sizes[b.buffer_slot] =
                    base == d.base_address ? d.size_bytes : (d.size_bytes + uint32_t(d.base_address - base) + 3) & ~3u;
        }
    }
    if (info.msl_push_constant_buffer >= 0) [enc setBytes:push length:sizeof(push) atIndex:(NSUInteger)info.msl_push_constant_buffer];
    if (info.shared_memory_size)
        [enc setThreadgroupMemoryLength:(info.shared_memory_size + 15) & ~15u atIndex:0];
    [enc dispatchThreadgroups:MTLSizeMake(1, 1, 1) threadsPerThreadgroup:MTLSizeMake(threads, 1, 1)];
    [enc endEncoding];
    [cb commit];
    [cb waitUntilCompleted];
    return cb.status == MTLCommandBufferStatusCompleted;
}

constexpr uint32_t kEnd = 0xBF810000;

uint32_t* Out(Guest& g) { return reinterpret_cast<uint32_t*>(g.p(kGuestBase + 0x1000)); }

bool Setup(id<MTLDevice> dev, Guest& g, const std::vector<uint32_t>& body, uint64_t hash, uint32_t ud[16],
           uint32_t out_bytes = 256) {
    g.buf = [dev newBufferWithLength:kGuestSize options:MTLResourceStorageModeShared];
    std::memset(g.buf.contents, 0, kGuestSize);
    const auto prog = WithFooter(body, hash);
    std::memcpy(g.p(kGuestBase), prog.data(), prog.size() * 4);
    std::memset(ud, 0, 64);
    VSharp(&ud[4], kGuestBase + 0x1000, out_bytes, 0);
    return true;
}

void TestExecHalf(id<MTLDevice> dev) {
    Guest g;
    uint32_t ud[16];
    // v2 = v0 << 2; v1 = 1; exec = (16 > v0); exec_hi = -1; out[v0] = v1
    Setup(dev, g, {0x34040082, 0x7E020281, 0x7DA80090, 0xBEFF03C1, 0xE0701000, 0x80010102, kEnd},
          0x5CA1AB1E00000001ULL, ud);
    gcn_shader* sh = Compile(g, kGuestBase, ud, 64);
    if (!sh) return;
    CHECK(Run(dev, g, sh, ud, 64), "exec_hi: did not run");
    int lo = 0, hi = 0;
    for (int i = 0; i < 64; i++) (i < 32 ? lo : hi) += Out(g)[i] == 1;
    CHECK(Out(g)[0] == 1 && Out(g)[15] == 1 && Out(g)[16] == 0, "exec_hi: low half changed");
    CHECK(lo == 16 && hi == 32, "exec_hi: %d/%d lanes stored in the low/high half, expected 16/32", lo, hi);
    gcn_shader_destroy(sh);
}

void TestSpilledSharp(id<MTLDevice> dev) {
    Guest g;
    uint32_t ud[16];
    std::vector<uint32_t> b;
    for (uint32_t k = 0; k < 4; k++) { // v_writelane_b32 v3, s[4+k], k
        b.push_back(0xD2000000 | (0x102 << 17) | 3);
        b.push_back((4 + k) | ((0x80 + k) << 9));
    }
    for (uint32_t k = 0; k < 4; k++) { // v_readlane_b32 s[12+k], v3, k
        b.push_back(0xD2000000 | (0x101 << 17) | (12 + k));
        b.push_back(0x103 | ((0x80 + k) << 9));
    }
    // v1 = 7; v2 = 8; buffer_store_dword v1, v2, s[12:15] offen
    for (uint32_t w : {0x7E020287u, 0x7E040288u, 0xE0701000u, 0x80030102u, kEnd}) b.push_back(w);
    Setup(dev, g, b, 0x5CA1AB1E00000002ULL, ud);
    gcn_shader* sh = Compile(g, kGuestBase, ud, 1);
    if (!sh) return;
    CHECK(Run(dev, g, sh, ud, 1), "spilled V#: did not run");
    CHECK(Out(g)[2] == 7 && Out(g)[0] == 0, "spilled V#: out[2] = %u, out[0] = %u; expected 7 and 0", Out(g)[2], Out(g)[0]);
    gcn_shader_destroy(sh);
}

void TestWave64Compare(id<MTLDevice> dev) {
    Guest g;
    uint32_t ud[16];
    // vcc = (40 > v0); v1 = vcc_lo; v4 = vcc_hi; v2 = 0; out[0] = v1; out[1] = v4
    Setup(dev, g, {0x7D8800A8, 0x7E02026A, 0x7E08026B, 0x7E040280, 0xE0701000, 0x80010102, 0xE0701004, 0x80010402, kEnd},
          0x5CA1AB1E00000003ULL, ud);
    gcn_shader* sh = Compile(g, kGuestBase, ud, 64);
    if (!sh) return;
    CHECK(Run(dev, g, sh, ud, 64), "wave64 compare: did not run");
    CHECK(Out(g)[0] == 0xFFFFFFFFu && Out(g)[1] == 0xFFu, "wave64 compare: vcc = %08x:%08x, expected 000000ff:ffffffff",
          Out(g)[1], Out(g)[0]);
    gcn_shader_destroy(sh);
}


// Instruction words of the wave64 cases below (64-thread workgroup, v0 = thread id).
constexpr uint32_t kAddV1 = 0x4A0200FF;  // v_add_i32 v1, vcc, 100, v0 (literal follows)
constexpr uint32_t kShlV2 = 0x34040082;  // v_lshlrev_b32 v2, 2, v0
constexpr uint32_t kRflS10 = 0x7E140501; // v_readfirstlane_b32 s10, v1
constexpr uint32_t kMovV3S10 = 0x7E06020A; // v_mov_b32 v3, s10
constexpr uint32_t kStoreV3 = 0xE0701000, kStoreV3b = 0x80010302; // buffer_store_dword v3, v2, s[4:7] offen
constexpr uint32_t kExecLoLit = 0xBEFE03FF;  // s_mov_b32 exec_lo, literal
constexpr uint32_t kExecHiLit = 0xBEFF03FF;  // s_mov_b32 exec_hi, literal
// v_mov_b32 v6, s2 (user data 2 = 0); v_cmpx_le_u32 exec, 0, v6: every lane stays active, and the
// EXEC scope it opens does not depend on the lane id (the EXEC half writes after it apply in it)
#define OPEN_SCOPE 0x7E0C0202, 0x7DA60C80

// Runs a 64-thread program whose lanes 0-31 and 32-63 hold different values (v1 = 100 + lane)
// and returns the output dwords.
std::vector<uint32_t> RunWave64(id<MTLDevice> dev, const char* name, uint64_t hash, const std::vector<uint32_t>& body,
                                uint32_t out_dwords = 64, const std::vector<std::pair<int, uint32_t>>& ud_set = {},
                                uint32_t threads = 64, std::string* msl = nullptr,
                                gcn_shader_info* info = nullptr) {
    Guest g;
    uint32_t ud[16];
    std::vector<uint32_t> b = {kAddV1, 100, kShlV2};
    b.insert(b.end(), body.begin(), body.end());
    b.push_back(kEnd);
    Setup(dev, g, b, hash, ud, out_dwords * 4);
    for (const auto& [i, v] : ud_set) ud[i] = v;
    gcn_shader* sh = Compile(g, kGuestBase, ud, threads);
    if (!sh) return {};
    if (msl) *msl = gcn_shader_msl(sh);
    if (info) gcn_shader_get_info(sh, info);
    const bool ran = Run(dev, g, sh, ud, threads);
    CHECK(ran, "%s: did not run", name);
    gcn_shader_destroy(sh);
    if (!ran) return {};
    return std::vector<uint32_t>(Out(g), Out(g) + out_dwords);
}

// Checks out[l] == want(l) for every lane, printing the first few mismatches.
template <typename F>
void ExpectLanes(const char* name, const std::vector<uint32_t>& out, F want, uint32_t lanes = 64) {
    if (out.size() < lanes) return;
    int bad = 0;
    for (uint32_t l = 0; l < lanes; l++) {
        if (out[l] == want(l)) continue;
        if (bad++ < 4) std::fprintf(stderr, "  %s: lane %u = %u, expected %u\n", name, l, out[l], want(l));
    }
    CHECK(bad == 0, "%s: %d of %u lanes wrong", name, bad, lanes);
}

//  D. v_readfirstlane in a wave64: the first lane active in EXEC across both halves, not each
//     simdgroup's own first lane (lanes 32-63 read lane 32's value before).
void TestReadFirstLane(id<MTLDevice> dev) {
    // every lane active: lane 0's value everywhere
    auto out = RunWave64(dev, "readfirstlane all", 0x5CA1AB1E00000004ULL, {kRflS10, kMovV3S10, kStoreV3, kStoreV3b});
    ExpectLanes("readfirstlane all", out, [](uint32_t) { return 100u; });
    // lanes 0-4 inactive, read right after the EXEC write (outside the EXEC scope): lane 5
    out = RunWave64(dev, "readfirstlane from lane 5", 0x5CA1AB1E00000005ULL,
                    {OPEN_SCOPE, kExecLoLit, 0xFFFFFFE0, kRflS10, kMovV3S10, kStoreV3, kStoreV3b});
    ExpectLanes("readfirstlane from lane 5", out, [](uint32_t l) { return l < 5 ? 0u : 105u; });
    // the same, read inside the EXEC scope (v_mov v4, 0 first). LIMITATION: an EXEC scope is
    // divergent control flow, where the halves cannot exchange (a subgroup may skip the scope), so
    // each subgroup reads its own first EXEC lane: lanes 32-63 get lane 32's value, as at a18ab52.
    // GCN gives 105 everywhere; that needs predicated execution of EXEC scopes (not done yet).
    out = RunWave64(dev, "readfirstlane in scope", 0x5CA1AB1E00000006ULL,
                    {OPEN_SCOPE, kExecLoLit, 0xFFFFFFE0, 0x7E080280, kRflS10, kMovV3S10, kStoreV3, kStoreV3b});
    ExpectLanes("readfirstlane in scope", out, [](uint32_t l) { return l < 5 ? 0u : l < 32 ? 105u : 132u; });
    // only lanes 40-47 active: lane 40
    out = RunWave64(dev, "readfirstlane upper half", 0x5CA1AB1E00000007ULL,
                    {OPEN_SCOPE, 0xBEFE0380, kExecHiLit, 0xFF00, kRflS10, kMovV3S10, kStoreV3, kStoreV3b});
    ExpectLanes("readfirstlane upper half", out, [](uint32_t l) { return l >= 40 && l < 48 ? 140u : 0u; });
    // EXEC with only one half (s_bfm_b64 exec, 32, 32 / s_and_b64 exec, exec, user-data mask
    // 0:0xffffffff) and
    // v_readfirstlane inside its scope: one subgroup does not run the scope, so nothing in it may be
    // exchanged through workgroup memory (a barrier there is reached by one subgroup only). The
    // subgroup that runs it has the wave's first EXEC lane: lane 32 / lane 0.
    std::string scope_msl;
    out = RunWave64(dev, "readfirstlane upper-half scope", 0x5CA1AB1E00000012ULL,
                    {OPEN_SCOPE, 0x92FEA0A0, 0x7E080280, kRflS10, kMovV3S10, kStoreV3, kStoreV3b}, 64, {}, 64,
                    &scope_msl);
    ExpectLanes("readfirstlane upper-half scope", out, [](uint32_t l) { return l >= 32 ? 132u : 0u; });
    CHECK(!out.empty() && scope_msl.find("threadgroup_barrier") == std::string::npos,
          "readfirstlane upper-half scope: a barrier in a scope one subgroup skips");
    out = RunWave64(dev, "readfirstlane lower-half scope", 0x5CA1AB1E00000013ULL,
                    {OPEN_SCOPE, 0x87FE027E, 0x7E080280, kRflS10, kMovV3S10, kStoreV3, kStoreV3b}, 64,
                    {{2, 0xFFFFFFFFu}, {3, 0}}, 64, &scope_msl);
    ExpectLanes("readfirstlane lower-half scope", out, [](uint32_t l) { return l < 32 ? 100u : 0u; });
    CHECK(!out.empty() && scope_msl.find("threadgroup_barrier") == std::string::npos,
          "readfirstlane lower-half scope: a barrier in a scope one subgroup skips");
    // Cost: a value that is the same in every lane (v7 = user data s2) needs no exchange through
    // workgroup memory, and a 32-thread workgroup (one subgroup) keeps the subgroup broadcast.
    std::string msl;
    out = RunWave64(dev, "readfirstlane uniform", 0x5CA1AB1E0000000EULL,
                    {0x7E0E0202, 0x7E140507, kMovV3S10, kStoreV3, kStoreV3b}, 64, {{2, 55}}, 64, &msl);
    ExpectLanes("readfirstlane uniform", out, [](uint32_t) { return 55u; });
    CHECK(!out.empty() && msl.find("threadgroup_barrier") == std::string::npos,
          "readfirstlane uniform: a wave-uniform value is exchanged through workgroup memory");
    out = RunWave64(dev, "readfirstlane wave32", 0x5CA1AB1E0000000FULL, {kRflS10, kMovV3S10, kStoreV3, kStoreV3b},
                    64, {}, 32, &msl);
    ExpectLanes("readfirstlane wave32", out, [](uint32_t l) { return l < 32 ? 100u : 0u; });
    CHECK(!out.empty() && msl.find("threadgroup_barrier") == std::string::npos &&
              msl.find("simd_broadcast_first") != std::string::npos,
          "readfirstlane wave32: not a plain subgroup broadcast");
}

//  E. v_readlane with an SGPR lane in the other half. v_writelane is a known gap (emitted as 0,
//     see EmitWriteLane): its case is an expected failure, reported as XFAIL, and the shader must
//     count the zeroed result in gcn_shader_info.zeroed_write_lanes.
void TestReadLaneAndWriteLaneGap(id<MTLDevice> dev) {
    // s10 = v_readlane(v1, s2); out[l] = s10; s10 = v_readlane(v1, s3); out[64 + l] = s10, with
    // user data s2 = 40 and s3 = 7 (not constants the translator could fold)
    auto out = RunWave64(dev, "readlane sgpr", 0x5CA1AB1E00000008ULL,
                         {0xD202000A, 0x00000501, kMovV3S10, kStoreV3, kStoreV3b, 0xD202000A, 0x00000701, kMovV3S10,
                          0x4A0804FF, 256, kStoreV3, 0x80010304},
                         128, {{2, 40}, {3, 7}});
    ExpectLanes("readlane sgpr lane 40", out, [](uint32_t) { return 140u; });
    if (out.size() == 128)
        ExpectLanes("readlane sgpr lane 7", std::vector<uint32_t>(out.begin() + 64, out.end()),
                    [](uint32_t) { return 107u; });
    // s12 = 7; v_writelane v1, s12, 3; v_writelane v1, s12, 40; out[l] = v1
    gcn_shader_info info{};
    out = RunWave64(dev, "writelane", 0x5CA1AB1E00000009ULL,
                    {0xBE8C0387, 0xD2040001, 0x0001060C, 0xD2040001, 0x0001500C, kStoreV3, 0x80010102}, 64, {}, 64,
                    nullptr, &info);
    CHECK(info.zeroed_write_lanes > 0, "writelane: the zeroed v_writelane is not counted (%u)", info.zeroed_write_lanes);
    int wrong = 0;
    for (uint32_t l = 0; l < out.size() && l < 64; l++) wrong += out[l] != (l == 3 || l == 40 ? 7u : 100u + l);
    if (out.size() == 64 && wrong == 0)
        CHECK(false, "writelane: XPASS, the known v_writelane gap is closed: make this case a normal check");
    else
        std::printf("gcn_wave_exec_test: XFAIL writelane: %d of 64 lanes wrong (known gap: v_writelane emitted "
                    "as 0, %u counted)\n", wrong, info.zeroed_write_lanes);
}

//  F. Scalar instructions on EXEC and on 64-bit masks with only upper-half bits, and a mask
//     with bits in both halves used as a per-lane condition.
void TestWave64Masks(id<MTLDevice> dev) {
    // exec = lanes 24-31 and 40-47; s10 = s_ff1(exec); s11 = s_bcnt1(exec); s[12:13] = exec & -1;
    // s14 = s_ff1(0x100:0); out[8l + k] = s[10 + k]. Then the same EXEC with scc = bit 41 of exec,
    // s10 = scc ? 1 : 2.
    const std::vector<uint32_t> scalar = {0xBE8A147E, 0xBE8B107E, 0x878CC17E, 0xBE900380, 0xBE9103FF, 0x100, 0xBE8E1410};
    const std::vector<uint32_t> bitcmp = {0xBF0FA97E, 0x850A8281};
    const uint32_t want[2][5] = {{24, 16, 0xFF000000, 0xFF00, 40}, {1}};
    const char* what[2][5] = {{"s_ff1 exec", "s_bcnt1 exec", "s_and_b64 exec lo", "s_and_b64 exec hi",
                               "s_ff1 upper-half mask"},
                              {"s_bitcmp1 exec"}};
    for (int c = 0; c < 2; c++) {
        const uint32_t n = c == 0 ? 5 : 1;
        std::vector<uint32_t> b = {OPEN_SCOPE, kExecLoLit, 0xFF000000, kExecHiLit, 0xFF00};
        b.insert(b.end(), c == 0 ? scalar.begin() : bitcmp.begin(), c == 0 ? scalar.end() : bitcmp.end());
        b.push_back(0x340A0085); // v_lshlrev_b32 v5, 5, v0
        for (uint32_t k = 0; k < n; k++) {
            b.push_back(0x7E060200 | (10 + k)); // v_mov_b32 v3, s[10 + k]
            b.push_back(0xE0701000 | (4 * k));  // buffer_store_dword v3, v5, s[4:7] offen offset:4k
            b.push_back(0x80010305);
        }
        auto out = RunWave64(dev, what[c][0], 0x5CA1AB1E0000000AULL + (uint64_t(c) << 32), b, 512);
        if (out.size() != 512) continue;
        for (uint32_t k = 0; k < n; k++) {
            int bad = 0;
            for (uint32_t l = 24; l < 48; l++) bad += (l < 32 || l >= 40) && out[8 * l + k] != want[c][k];
            CHECK(bad == 0, "%s: lanes 24 / 40 have %u / %u, expected %u (%d of 16 lanes wrong)", what[c][k],
                  out[8 * 24 + k], out[8 * 40 + k], want[c][k], bad);
        }
    }
    // s[12:13] = 0x0F000000:0x0000000F; v3 = v_cndmask(0, 1, s[12:13]): lanes 0-3 and 56-59
    std::vector<uint32_t> out = RunWave64(dev, "mask condition", 0x5CA1AB1E0000000BULL,
                    {0xBE8C038F, 0xBE8D03FF, 0x0F000000, 0xD2000003, 0x00310280, kStoreV3, kStoreV3b});
    ExpectLanes("mask condition", out, [](uint32_t l) { return l < 4 || (l >= 56 && l < 60) ? 1u : 0u; });
    // A loop on a mask computed from vcc (shifted by user data s2 = 0): the ballot stays in the
    // loop, in each subgroup's own layout, and lanes 32-63 must keep testing their bit there
    // (they read 0 in the wave layout, so a loop waiting for its bit never ended).
    // v1 = 0; do { v1 += 1; vcc = (5 > v1) << s2; } while (vccnz); out[l] = v1
    out = RunWave64(dev, "vcc loop", 0x5CA1AB1E00000010ULL,
                    {0x7E020280, 0x4A020281, 0x7D880285, 0x8FEA026A, 0xBF87FFFC, kStoreV3, 0x80010102});
    ExpectLanes("vcc loop", out, [](uint32_t) { return 5u; });
    // exec = lanes 5-63; v3 = v_mbcnt_hi(exec_hi, v_mbcnt_lo(exec_lo, 0)): active lanes below.
    // LIMITATION (as "readfirstlane in scope"): inside the EXEC scope the ballot of EXEC stays per
    // subgroup, so lanes 32-63 count only the active lanes of their own half (GCN: l - 5).
    out = RunWave64(dev, "mbcnt", 0x5CA1AB1E0000000CULL,
                    {OPEN_SCOPE, kExecLoLit, 0xFFFFFFE0, 0xD2460003, 0x0001007E, 0xD2480003, 0x0002067F, kStoreV3, kStoreV3b});
    ExpectLanes("mbcnt", out, [](uint32_t l) { return l < 5 ? 0u : l < 32 ? l - 5 : l - 32; });
    // every lane active (no scope): mbcnt of EXEC is the lane id in both halves
    out = RunWave64(dev, "mbcnt all lanes", 0x5CA1AB1E00000015ULL,
                    {0xD2460003, 0x0001007E, 0xD2480003, 0x0002067F, kStoreV3, kStoreV3b});
    ExpectLanes("mbcnt all lanes", out, [](uint32_t l) { return l; });
}

//  G. A V# with ADD_TID_ENABLE: the record index is the lane (0-63), not the simdgroup lane.
//  H. Partial workgroups: 48 threads (a wave whose upper half has 16 lanes) and 96 threads (a
//     second wave of 32 lanes with no upper half). v_readfirstlane and s_bcnt1 of EXEC per wave.
void TestPartialGroups(id<MTLDevice> dev) {
    for (const uint32_t threads : {48u, 96u}) {
        char name[64];
        std::snprintf(name, sizeof(name), "readfirstlane %u threads", threads);
        auto out = RunWave64(dev, name, 0x5CA1AB1E00000014ULL + threads, {kRflS10, kMovV3S10, kStoreV3, kStoreV3b},
                             threads, {}, threads);
        ExpectLanes(name, out, [](uint32_t l) { return l < 64 ? 100u : 164u; }, threads);
        // s11 = s_bcnt1(exec); out[l] = s11: the lanes the wave has
        std::snprintf(name, sizeof(name), "s_bcnt1 exec %u threads", threads);
        out = RunWave64(dev, name, 0x5CA1AB1E00000114ULL + threads, {0xBE8B107E, 0x7E06020B, kStoreV3, kStoreV3b},
                        threads, {}, threads);
        ExpectLanes(name, out, [threads](uint32_t l) { return l < 64 ? std::min(threads, 64u) : threads - 64; },
                    threads);
    }
}

void TestAddTid(id<MTLDevice> dev) {
    uint32_t v[4];
    VSharp(v, kGuestBase + 0x1000, 64, 4);
    v[3] |= 1u << 23;
    // buffer_store_dword v1, off, s[8:11]
    auto out = RunWave64(dev, "add_tid", 0x5CA1AB1E0000000DULL, {0xE0700000, 0x80020100}, 64,
                         {{8, v[0]}, {9, v[1]}, {10, v[2]}, {11, v[3]}});
    ExpectLanes("add_tid", out, [](uint32_t l) { return 100u + l; });
}

} // namespace

int main() {
    @autoreleasepool {
        id<MTLDevice> dev = MTLCreateSystemDefaultDevice();
        if (!dev) {
            std::fprintf(stderr, "gcn_wave_exec_test: no Metal device\n");
            return 1;
        }
        TestExecHalf(dev);
        TestSpilledSharp(dev);
        TestWave64Compare(dev);
        TestReadFirstLane(dev);
        TestReadLaneAndWriteLaneGap(dev);
        TestWave64Masks(dev);
        TestAddTid(dev);
        TestPartialGroups(dev);
        if (g_fail) {
            std::fprintf(stderr, "gcn_wave_exec_test: %d failure(s)\n", g_fail);
            return 1;
        }
        std::printf("gcn_wave_exec_test: PASS\n");
        return 0;
    }
}
