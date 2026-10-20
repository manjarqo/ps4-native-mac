// Guest buffers whose V# base address is not dword aligned, run on Metal (libgcn_recompiler in
// 3rdparty/gcn-recompiler, bound as the renderer binds them in BindStage).
//
// Metal binds buffers at dword-aligned offsets, so the renderer binds such a buffer at the dword
// below its base. Uncharted 4 has vertex buffers at base + 2 (16_16 attributes; ~5 per frame in
// the chapter 1 boat scene, "buffer N not dword aligned"): every load read 2 bytes early. The
// shader must be specialized on base & 3 and read the guest's bytes:
//  1. buffer_load_dwordx2 (raw dwords spanning two bound dwords each),
//  2. buffer_load_format_xy of a 16_16 float attribute (lowered to a raw dword load),
//  3. buffer_load_ubyte,
// each at base + 1, + 2 and + 3, and the aligned case unchanged. A permutation translated for one
// alignment is not compatible with a draw at another.
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>

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
            std::fprintf(stderr, "gcn_buffer_align_test: FAIL %s:%d: ", __FILE__, __LINE__); \
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

// user data: s[4:7] V# of out, s[8:11] V# of src.
//   v_mov_b32 v0, 0
//   <load> v1.., v0, s[8:11]
//   s_waitcnt 0
//   buffer_store_dword v1, v0, s[4:7], 0 (offset 0), v2 at offset 4
//   s_endpgm
std::vector<uint32_t> Program(uint32_t load_op_dword0, uint64_t hash) {
    return WithFooter({0x7E000280, load_op_dword0, 0x80020100, 0xBF8C0000, 0xE0700000, 0x80010100, 0xE0700004,
                       0x80010200, 0xBF810000},
                      hash);
}
constexpr uint32_t kLoadDwordx2 = 0xE0340000;   // buffer_load_dwordx2, offset 0
constexpr uint32_t kLoadFormatXy = 0xE0042000;  // buffer_load_format_xy, idxen
constexpr uint32_t kLoadUbyte = 0xE0200000;     // buffer_load_ubyte

struct Case {
    const char* name;
    uint32_t op;
    uint32_t dfmt, nfmt, stride;
};

gcn_shader* Compile(Guest& g, uint64_t code, const uint32_t ud[16]) {
    gcn_profile prof;
    gcn_profile_default_metal(&prof);
    gcn_runtime_info rt{};
    rt.hw_stage = GCN_HW_CS;
    rt.sw_stage = GCN_SW_COMPUTE;
    rt.num_allocated_vgprs = 4;
    rt.num_user_data = 12;
    rt.cs.workgroup_size[0] = rt.cs.workgroup_size[1] = rt.cs.workgroup_size[2] = 1;
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
    CHECK(st == GCN_OK && sh, "test CS does not compile: %s", err);
    return st == GCN_OK ? sh : nullptr;
}

// Binds like the renderer's BindStage: a guest buffer at the dword below its base, with
// buf_sizes = size + (base & 3).
bool Run(id<MTLDevice> dev, Guest& g, const gcn_shader* sh, const uint32_t ud[16]) {
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
            if (b.buffer_slot < GCN_MAX_BUFFERS) pd->buf_sizes[b.buffer_slot] = d.size_bytes + uint32_t(d.base_address - base);
        }
    }
    if (info.msl_push_constant_buffer >= 0) [enc setBytes:push length:sizeof(push) atIndex:(NSUInteger)info.msl_push_constant_buffer];
    [enc dispatchThreadgroups:MTLSizeMake(1, 1, 1) threadsPerThreadgroup:MTLSizeMake(1, 1, 1)];
    [enc endEncoding];
    [cb commit];
    [cb waitUntilCompleted];
    return cb.status == MTLCommandBufferStatusCompleted;
}

uint32_t Le32(const uint8_t* b) { return b[0] | b[1] << 8 | b[2] << 16 | uint32_t(b[3]) << 24; }

void TestCase(id<MTLDevice> dev, const Case& c, uint32_t misalign) {
    Guest g{[dev newBufferWithLength:kGuestSize options:MTLResourceStorageModeShared]};
    std::memset(g.buf.contents, 0, kGuestSize);
    const uint64_t code = kGuestBase, out = kGuestBase + 0x1000, src = kGuestBase + 0x2000 + misalign;
    const auto prog = Program(c.op, 0x5CA1A2EAD5200000ULL + c.op + misalign);
    std::memcpy(g.p(code), prog.data(), prog.size() * 4);
    // bytes 0x10, 0x11, ... from the dword below the base on: the guest's data starts at src
    for (uint32_t i = 0; i < 64; i++) g.p(kGuestBase + 0x2000)[i] = uint8_t(0x10 + i);
    if (c.op == kLoadFormatXy) { // two halfs: 1.5, -2.0
        const uint16_t h[2] = {0x3E00, 0xC000};
        std::memcpy(g.p(src), h, 4);
    }
    uint32_t ud[16] = {};
    VSharp(&ud[4], out, 64, 0);
    VSharp(&ud[8], src, c.stride ? 4 : 16, c.stride, c.dfmt, c.nfmt);
    g.p(out)[0] = 0xEE;
    gcn_shader* sh = Compile(g, code, ud);
    if (!sh) return;
    CHECK(Run(dev, g, sh, ud), "%s +%u: did not run", c.name, misalign);
    uint32_t r[2];
    std::memcpy(r, g.p(out), 8);
    const uint8_t* s = g.p(src);
    if (c.op == kLoadDwordx2) {
        CHECK(r[0] == Le32(s) && r[1] == Le32(s + 4), "%s +%u: read %08x %08x, guest has %08x %08x", c.name, misalign,
              r[0], r[1], Le32(s), Le32(s + 4));
    } else if (c.op == kLoadFormatXy) {
        float f[2];
        std::memcpy(f, r, 8);
        CHECK(f[0] == 1.5f && f[1] == -2.0f, "%s +%u: read %g %g, expected 1.5 -2", c.name, misalign, f[0], f[1]);
    } else {
        CHECK(r[0] == s[0], "%s +%u: read 0x%x, guest has 0x%x", c.name, misalign, r[0], s[0]);
    }

    // A draw whose buffer has another alignment needs another permutation.
    uint32_t ud2[16];
    std::memcpy(ud2, ud, 64);
    VSharp(&ud2[8], (src & ~3ull) + ((misalign + 2) & 3), c.stride ? 4 : 16, c.stride, c.dfmt, c.nfmt);
    gcn_profile prof;
    gcn_profile_default_metal(&prof);
    gcn_runtime_info rt{};
    rt.hw_stage = GCN_HW_CS;
    rt.sw_stage = GCN_SW_COMPUTE;
    rt.num_allocated_vgprs = 4;
    rt.num_user_data = 12;
    rt.cs.workgroup_size[0] = rt.cs.workgroup_size[1] = rt.cs.workgroup_size[2] = 1;
    CHECK(gcn_shader_is_compatible(sh, ud, &rt, Guest::Read, &g), "%s +%u: not compatible with its own draw", c.name,
          misalign);
    CHECK(!gcn_shader_is_compatible(sh, ud2, &rt, Guest::Read, &g), "%s +%u: compatible with a base at +%u", c.name,
          misalign, (misalign + 2) & 3);
    gcn_shader_destroy(sh);
}

} // namespace

int main() {
    @autoreleasepool {
        id<MTLDevice> dev = MTLCreateSystemDefaultDevice();
        if (!dev) {
            std::fprintf(stderr, "gcn_buffer_align_test: no Metal device\n");
            return 1;
        }
        const Case cases[] = {
            {"buffer_load_dwordx2", kLoadDwordx2, 4, 4, 0},
            {"buffer_load_format_xy 16_16 float", kLoadFormatXy, 5, 7, 4},
            {"buffer_load_ubyte", kLoadUbyte, 4, 4, 0},
        };
        for (const Case& c : cases)
            for (uint32_t m = 0; m < 4; m++) TestCase(dev, c, m);
        if (g_fail) {
            std::fprintf(stderr, "gcn_buffer_align_test: %d failure(s)\n", g_fail);
            return 1;
        }
        std::printf("gcn_buffer_align_test: PASS\n");
        return 0;
    }
}
