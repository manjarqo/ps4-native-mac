// The shader translator's output does not depend on the caller's floating-point environment
// (libgcn_recompiler in 3rdparty/gcn-recompiler, run on Metal as the renderer binds it).
//
// Guest threads run host code (the HLE shims, the renderer's command processor, the shader
// translation it starts) with the guest's MXCSR.FZ mapped to FPCR.FZ. On AArch64, FZ flushes
// denormal inputs as well as results, float -> double conversions included. The translator
// carries GCN integer constants through float-typed IR values (a VGPR is untyped; a format
// store takes F32), so an integer below 0x00800000 is a denormal float: under FZ its MSL literal
// came out as 0.0 (SPIRV-Cross prints a float literal through a double). inFAMOUS Second Son's
// tiled light culling compute shader ends each tile's light list with buffer_store_format_x of
// 0xFFFF (a 16-bit uint format); that store wrote 0, the pixel shader looping over the list
// until 0xFFFF never left its loop, and the GPU hung (kIOGPUCommandBufferCallbackErrorHang).
//
// Checked with FPCR.FZ set by the caller, as a guest thread with FTZ has it:
//  1. buffer_store_format_x of 0xFFFF into a 16-bit uint buffer stores 0xFFFF;
//  2. buffer_store_format_x of 1 into a 32-bit uint buffer stores 1;
//  3. the MSL is byte for byte the MSL translated with FZ clear;
//  4. the caller's FPCR is the same after gcn_compile.
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>

#include <cstdint>
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
            std::fprintf(stderr, "gcn_caller_fpenv_test: FAIL %s:%d: ", __FILE__, __LINE__); \
            std::fprintf(stderr, __VA_ARGS__);                                                \
            std::fprintf(stderr, "\n");                                                       \
            g_fail++;                                                                         \
        }                                                                                     \
    } while (0)

constexpr uint64_t kFpcrFz = 1ull << 24;

uint64_t GetFpcr() {
    uint64_t v;
    asm volatile("mrs %0, fpcr" : "=r"(v));
    return v;
}

void SetFpcr(uint64_t v) {
    asm volatile("msr fpcr, %0" : : "r"(v));
}

constexpr uint64_t kGuestBase = 0x10000000;
constexpr uint64_t kGuestSize = 1u << 20;
constexpr uint64_t kOut16 = kGuestBase + 0x1000;
constexpr uint64_t kOut32 = kGuestBase + 0x2000;

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

// V#: base, num_records, stride, data/number format.
void VSharp(uint32_t* v, uint64_t base, uint32_t records, uint32_t stride, uint32_t dfmt, uint32_t nfmt) {
    v[0] = uint32_t(base);
    v[1] = (uint32_t(base >> 32) & 0xFFF) | (stride << 16);
    v[2] = records;
    v[3] = 4 | (5 << 3) | (6 << 6) | (7 << 9) | (nfmt << 12) | (dfmt << 15);
}

// user data: s[4:7] V# of a 16-bit uint buffer, s[8:11] V# of a 32-bit uint buffer.
//   v_mov_b32 v0, 0
//   v_mov_b32 v1, 0x0000ffff
//   buffer_store_format_x v1, v0, s[4:7], 0 idxen
//   v_mov_b32 v2, 1
//   buffer_store_format_x v2, v0, s[8:11], 0 idxen
//   s_endpgm
std::vector<uint32_t> Program() {
    return WithFooter({0x7E000280, 0x7E0202FF, 0x0000FFFF, 0xE0102000, 0x80010100, 0x7E040281, 0xE0102000,
                       0x80020200, 0xBF810000},
                      0x5CA1AF9E00000001ULL);
}

gcn_shader* Compile(Guest& g, const uint32_t ud[16]) {
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
    d.code_addr = kGuestBase;
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

// Binds like the renderer's BindStage (the bases here are dword aligned).
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
            [enc setBuffer:g.buf offset:d.base_address - kGuestBase atIndex:b.msl_buffers[k]];
            if (b.buffer_slot < GCN_MAX_BUFFERS) pd->buf_sizes[b.buffer_slot] = d.size_bytes;
        }
    }
    if (info.msl_push_constant_buffer >= 0) [enc setBytes:push length:sizeof(push) atIndex:(NSUInteger)info.msl_push_constant_buffer];
    [enc dispatchThreadgroups:MTLSizeMake(1, 1, 1) threadsPerThreadgroup:MTLSizeMake(1, 1, 1)];
    [enc endEncoding];
    [cb commit];
    [cb waitUntilCompleted];
    return cb.status == MTLCommandBufferStatusCompleted;
}

void TestFlushToZeroCaller(id<MTLDevice> dev) {
    Guest g{[dev newBufferWithLength:kGuestSize options:MTLResourceStorageModeShared]};
    std::memset(g.buf.contents, 0, kGuestSize);
    const auto prog = Program();
    std::memcpy(g.p(kGuestBase), prog.data(), prog.size() * 4);
    uint32_t ud[16] = {};
    VSharp(&ud[4], kOut16, 8, 2, 2, 4); // BUF_DATA_FORMAT_16, BUF_NUM_FORMAT_UINT, stride 2
    VSharp(&ud[8], kOut32, 8, 4, 4, 4); // BUF_DATA_FORMAT_32, BUF_NUM_FORMAT_UINT, stride 4

    const uint64_t host = GetFpcr();
    SetFpcr(host & ~kFpcrFz);
    gcn_shader* plain = Compile(g, ud);
    SetFpcr(host | kFpcrFz);
    gcn_shader* ftz = Compile(g, ud);
    const uint64_t after = GetFpcr();
    SetFpcr(host);
    CHECK(after == (host | kFpcrFz), "gcn_compile changed the caller's FPCR: 0x%llx before, 0x%llx after",
          (unsigned long long)(host | kFpcrFz), (unsigned long long)after);
    if (!plain || !ftz) return;

    CHECK(std::strcmp(gcn_shader_msl(plain), gcn_shader_msl(ftz)) == 0,
          "the MSL translated with FPCR.FZ set differs from the MSL translated with it clear");
    std::memset(g.p(kOut16), 0xEE, 16);
    std::memset(g.p(kOut32), 0xEE, 16);
    CHECK(Run(dev, g, ftz, ud), "the CS translated with FPCR.FZ set did not run");
    uint16_t v16;
    uint32_t v32;
    std::memcpy(&v16, g.p(kOut16), 2);
    std::memcpy(&v32, g.p(kOut32), 4);
    CHECK(v16 == 0xFFFF, "buffer_store_format_x of 0xffff (16-bit uint) stored 0x%04x", v16);
    CHECK(v32 == 1, "buffer_store_format_x of 1 (32-bit uint) stored 0x%08x", v32);
    gcn_shader_destroy(plain);
    gcn_shader_destroy(ftz);
}

} // namespace

int main() {
    @autoreleasepool {
        id<MTLDevice> dev = MTLCreateSystemDefaultDevice();
        if (!dev) {
            std::fprintf(stderr, "gcn_caller_fpenv_test: no Metal device\n");
            return 1;
        }
        TestFlushToZeroCaller(dev);
        if (g_fail) {
            std::fprintf(stderr, "gcn_caller_fpenv_test: %d failure(s)\n", g_fail);
            return 1;
        }
        std::printf("gcn_caller_fpenv_test: PASS\n");
        return 0;
    }
}
