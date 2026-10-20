// Shader permutation lookup and push constants of translated shaders (libgcn_recompiler in
// 3rdparty/gcn-recompiler, renderer header ps4_gnm_push_data.h).
//
//  1. gcn_shader_find_compatible_flat builds the draw's specialization from list[0]'s Info and
//     the flattened user data of list[0]'s SRT program. A permutation with another SRT program
//     but the same resource counts used to be compared against that specialization: one that
//     fits the draw never matched, so every draw asked for a new permutation (Uncharted 4 hit the
//     renderer's cap of 48 and then skipped the draws). It must be found.
//  2. gcn_shader_same_srt tells whether the flattened user data built for one permutation can be
//     bound for another (the renderer's StageFlat reuse).
//  3. gcn_shader_explain_mismatch names why a permutation does not fit a draw (debug log).
//  4. The push constants: the MSL struct the translated shaders declare must be exactly
//     ps4gnm_push::kBindBytes long, with gcn_push_data's member offsets (Metal reflection).
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>

#include <cstddef>
#include <cstdio>
#include <cstring>
#include <string>
#include <vector>

#include "gcn_recompiler.h"
#include "ps4_gnm_push_data.h"

namespace {

int g_fail = 0;
#define CHECK(c, ...)                                                                        \
    do {                                                                                     \
        if (!(c)) {                                                                          \
            std::fprintf(stderr, "gnm_shader_perm_test: FAIL %s:%d: ", __FILE__, __LINE__); \
            std::fprintf(stderr, __VA_ARGS__);                                               \
            std::fprintf(stderr, "\n");                                                      \
            g_fail++;                                                                        \
        }                                                                                    \
    } while (0)

constexpr uint64_t kGuestBase = 0x10000000;
constexpr uint64_t kGuestSize = 1u << 20;

struct Guest {
    std::vector<uint8_t> mem = std::vector<uint8_t>(kGuestSize, 0);
    uint8_t* p(uint64_t a) { return mem.data() + (a - kGuestBase); }
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

// Raw V# with a stride (32-bit uint elements, num_records in bytes).
void VSharp(uint8_t* dst, uint64_t base, uint32_t bytes, uint32_t stride) {
    uint32_t v[4];
    v[0] = uint32_t(base);
    v[1] = (uint32_t(base >> 32) & 0xFFF) | (stride << 16);
    v[2] = bytes;
    v[3] = 4 | (5 << 3) | (6 << 6) | (7 << 9) | (4 << 12) | (4 << 15);
    std::memcpy(dst, v, 16);
}

// A compute shader that stores to the buffer whose V# it loads from the table at s[0:1] + 4 * dw:
//   s_load_dwordx4 s[4:7], s[0:1], dw
//   s_waitcnt lgkmcnt(0)
//   v_mov_b32 v0, 0
//   buffer_store_dword v0, v0, s[4:7], 0
//   s_endpgm
std::vector<uint32_t> StoreThroughTable(uint32_t dw, uint64_t hash) {
    return WithFooter({0xC0820100u | dw, 0xBF8C007F, 0x7E000280, 0xE0700000, 0x80010000, 0xBF810000}, hash);
}

gcn_runtime_info ComputeRuntime() {
    gcn_runtime_info rt{};
    rt.hw_stage = GCN_HW_CS;
    rt.sw_stage = GCN_SW_COMPUTE;
    rt.num_allocated_vgprs = 4;
    rt.num_user_data = 2;
    rt.cs.workgroup_size[0] = rt.cs.workgroup_size[1] = rt.cs.workgroup_size[2] = 1;
    return rt;
}

gcn_shader* Compile(Guest& g, uint64_t code, const uint32_t ud[16], const gcn_runtime_info& rt,
                    const gcn_profile& prof) {
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
    CHECK(st == GCN_OK && sh, "test shader does not compile: %s", err);
    return st == GCN_OK ? sh : nullptr;
}

void TestPermutationsWithAnotherSrtProgram() {
    Guest g;
    const uint64_t code_a = kGuestBase, code_b = kGuestBase + 0x400, table = kGuestBase + 0x1000,
                   out = kGuestBase + 0x2000;
    const auto a = StoreThroughTable(0, 0x5CA1A2EAD5100001ULL); // V# at table + 0
    const auto b = StoreThroughTable(4, 0x5CA1A2EAD5100002ULL); // V# at table + 16
    std::memcpy(g.p(code_a), a.data(), a.size() * 4);
    std::memcpy(g.p(code_b), b.data(), b.size() * 4);
    uint32_t ud[16] = {uint32_t(table), uint32_t(table >> 32)};
    gcn_profile prof;
    gcn_profile_default_metal(&prof);
    const gcn_runtime_info rt = ComputeRuntime();

    // A is translated while its V# has stride 32 (like a permutation translated from memory
    // that has changed since); B from the current memory, stride 32 at table + 16.
    VSharp(g.p(table), out, 64, 32);
    gcn_shader* sa = Compile(g, code_a, ud, rt, prof);
    VSharp(g.p(table), out, 64, 12);
    VSharp(g.p(table + 16), out, 64, 32);
    gcn_shader* sb = Compile(g, code_b, ud, rt, prof);
    if (!sa || !sb) return;

    gcn_shader_info ia, ib;
    gcn_shader_get_info(sa, &ia);
    gcn_shader_get_info(sb, &ib);
    CHECK(ia.num_buffers == ib.num_buffers && ia.flatbuf_size_dw == ib.flatbuf_size_dw,
          "the two programs must have the same resource layout (buffers %u/%u, flat %u/%u dw)", ia.num_buffers,
          ib.num_buffers, ia.flatbuf_size_dw, ib.flatbuf_size_dw);
    CHECK(!gcn_shader_is_compatible(sa, ud, &rt, Guest::Read, &g), "A must not fit the current memory (stride 12)");
    CHECK(gcn_shader_is_compatible(sb, ud, &rt, Guest::Read, &g), "B must fit the current memory");
    // the renderer's diagnostic for programs with many permutations names the differing part
    char why[256];
    CHECK(gcn_shader_explain_mismatch(sa, ud, &rt, Guest::Read, &g, why, sizeof(why)) &&
              std::string(why).find("stride 32/12") != std::string::npos,
          "explain_mismatch for A: \"%s\", expected the stride 32/12 difference", why);
    CHECK(!gcn_shader_explain_mismatch(sb, ud, &rt, Guest::Read, &g, why, sizeof(why)) && why[0] == 0,
          "explain_mismatch for the fitting B: \"%s\"", why);

    CHECK(gcn_shader_same_srt(sa, sa), "a shader has its own SRT program");
    CHECK(!gcn_shader_same_srt(sa, sb), "programs reading the table at different offsets have different SRT programs");

    // The renderer's lookup: the draw's flattened user data built for list[0].
    const gcn_shader* list[2] = {sa, sb};
    std::vector<uint32_t> flat(std::max<uint32_t>(ia.flatbuf_size_dw, 16));
    gcn_shader_build_flatbuf(sa, ud, Guest::Read, &g, flat.data(), flat.size());
    const int hit = gcn_shader_find_compatible_flat(list, 2, ud, flat.data(), flat.size(), &rt, Guest::Read, &g);
    CHECK(hit == 1, "find_compatible_flat returned %d, expected 1 (B fits the draw)", hit);
    const int hit2 = gcn_shader_find_compatible(list, 2, ud, &rt, Guest::Read, &g);
    CHECK(hit2 == 1, "find_compatible returned %d, expected 1", hit2);

    // Same program, translated twice: the flattened data of one serves the other.
    gcn_shader* sb2 = Compile(g, code_b, ud, rt, prof);
    if (sb2) {
        CHECK(gcn_shader_same_srt(sb, sb2), "two translations of one program have the same SRT program");
        const gcn_shader* list2[2] = {sb2, sa};
        std::vector<uint32_t> f2(flat.size());
        gcn_shader_build_flatbuf(sb2, ud, Guest::Read, &g, f2.data(), f2.size());
        const int h = gcn_shader_find_compatible_flat(list2, 2, ud, f2.data(), f2.size(), &rt, Guest::Read, &g);
        CHECK(h == 0, "find_compatible_flat with the same program returned %d, expected 0", h);
        gcn_shader_destroy(sb2);
    }
    gcn_shader_destroy(sa);
    gcn_shader_destroy(sb);
}

void TestPushDataSize(id<MTLDevice> dev) {
    Guest g;
    const uint64_t code = kGuestBase, table = kGuestBase + 0x1000, out = kGuestBase + 0x2000;
    const auto prog = StoreThroughTable(0, 0x5CA1A2EAD5100003ULL);
    std::memcpy(g.p(code), prog.data(), prog.size() * 4);
    VSharp(g.p(table), out, 64, 0);
    uint32_t ud[16] = {uint32_t(table), uint32_t(table >> 32)};
    gcn_profile prof;
    gcn_profile_default_metal(&prof);
    gcn_shader* sh = Compile(g, code, ud, ComputeRuntime(), prof);
    if (!sh) return;
    gcn_shader_info info;
    gcn_shader_get_info(sh, &info);
    CHECK(info.msl_push_constant_buffer >= 0, "the shader has no push constants (bounds checks expected)");
    NSError* e = nil;
    MTLCompileOptions* o = [MTLCompileOptions new];
    o.languageVersion = MTLLanguageVersion2_3;
    id<MTLLibrary> lib = [dev newLibraryWithSource:[NSString stringWithUTF8String:gcn_shader_msl(sh)] options:o error:&e];
    CHECK(lib, "MSL: %s", e.localizedDescription.UTF8String);
    if (!lib || info.msl_push_constant_buffer < 0) return;
    MTLComputePipelineDescriptor* pd = [MTLComputePipelineDescriptor new];
    pd.computeFunction = [lib newFunctionWithName:@"main0"];
    MTLComputePipelineReflection* refl = nil;
    id<MTLComputePipelineState> pso = [dev newComputePipelineStateWithDescriptor:pd
                                                                         options:MTLPipelineOptionBindingInfo
                                                                      reflection:&refl
                                                                           error:&e];
    CHECK(pso, "pipeline: %s", e.localizedDescription.UTF8String);
    bool found = false;
    for (id<MTLBinding> b in refl.bindings) {
        if (b.type != MTLBindingTypeBuffer || b.index != (NSUInteger)info.msl_push_constant_buffer) continue;
        id<MTLBufferBinding> bb = (id<MTLBufferBinding>)b;
        found = true;
        CHECK(bb.bufferDataSize == ps4gnm_push::kBindBytes,
              "MSL push constant struct is %lu bytes, the renderer binds %zu (gcn_push_data is %zu)",
              (unsigned long)bb.bufferDataSize, ps4gnm_push::kBindBytes, sizeof(gcn_push_data));
        // xoffset, yoffset, xscale, yscale, buf_offsets as uint4/uint4/uint2, buf_sizes[56]
        MTLStructType* st = bb.bufferStructType;
        MTLStructMember* last = st ? st.members.lastObject : nil;
        CHECK(last && [last.name isEqualToString:@"buf_sizes"] && last.offset == offsetof(gcn_push_data, buf_sizes),
              "MSL buf_sizes at offset %lu, gcn_push_data has it at %zu", (unsigned long)(last ? last.offset : 0),
              offsetof(gcn_push_data, buf_sizes));
        MTLStructMember* yscale = st ? [st memberByName:@"yscale"] : nil;
        CHECK(yscale && yscale.offset == offsetof(gcn_push_data, yscale), "MSL yscale offset differs");
    }
    CHECK(found, "no reflection for push constant buffer %d", info.msl_push_constant_buffer);
    gcn_shader_destroy(sh);
}

} // namespace

int main() {
    @autoreleasepool {
        id<MTLDevice> dev = MTLCreateSystemDefaultDevice();
        if (!dev) {
            std::fprintf(stderr, "gnm_shader_perm_test: no Metal device\n");
            return 1;
        }
        TestPermutationsWithAnotherSrtProgram();
        TestPushDataSize(dev);
        if (g_fail) {
            std::fprintf(stderr, "gnm_shader_perm_test: %d failure(s)\n", g_fail);
            return 1;
        }
        std::printf("gnm_shader_perm_test: PASS\n");
        return 0;
    }
}
