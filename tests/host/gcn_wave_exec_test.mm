// Wave-level GCN instructions on Metal, whose simdgroups are 32 wide (a wave64 compute shader
// runs as two simdgroups), checked by running small compute shaders and reading their output.
// Uncharted 4's chapter 1 compute shaders (tests/host/data/u4_cs_*, gcn_u4_cs_test) use them:
//  A. s_mov_b32 exec_hi after v_cmpx: lanes 32-63 must take the written half, not the low half
//     (they ran with exec_lo's bits: 16 lanes of 32 in the upper half here).
//  B. V# dwords spilled to VGPR lanes (v_writelane / v_readlane) and used for a store.
//  C. A wave64 compare whose 64-bit result (vcc) is read from both halves.
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>

#include <algorithm>
#include <cstdio>
#include <cstring>
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

bool Setup(id<MTLDevice> dev, Guest& g, const std::vector<uint32_t>& body, uint64_t hash, uint32_t ud[16]) {
    g.buf = [dev newBufferWithLength:kGuestSize options:MTLResourceStorageModeShared];
    std::memset(g.buf.contents, 0, kGuestSize);
    const auto prog = WithFooter(body, hash);
    std::memcpy(g.p(kGuestBase), prog.data(), prog.size() * 4);
    std::memset(ud, 0, 64);
    VSharp(&ud[4], kGuestBase + 0x1000, 256, 0);
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
        if (g_fail) {
            std::fprintf(stderr, "gcn_wave_exec_test: %d failure(s)\n", g_fail);
            return 1;
        }
        std::printf("gcn_wave_exec_test: PASS\n");
        return 0;
    }
}
