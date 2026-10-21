// Scalar memory reads in libgcn_recompiler (3rdparty/gcn-recompiler), run on Metal:
//
//  1. s_load_dword through an SRT pointer at an offset only the shader knows (a loop counter):
//     shadPS4 reads those through direct memory access; with the Metal profile the read used to
//     be left at flattened user data dword 0 ("Failed to compute offset for SRT walker").
//     It must read the guest table.
//  2. s_buffer_load_dword past the V#'s num_records must read 0, as on GCN. Uncharted 4's tiled
//     lighting takes its per-tile light count this way; reading past the end ran a loop for
//     seconds and the GPU watchdog killed the command buffer.
//  3. A pointer read at such an offset cannot be followed without direct memory access: the
//     reads through it are not flattened. That must be logged as an error, not dropped silently.
//  4. A compute shader dumped from Uncharted 4 (u4_cs_blur.*: a blur whose weights are read
//     at s[0:1] + 72 + 4 * i) translates without SRT walker errors, and its weights come from a
//     guest buffer based at the pointer it reads through.
//
// Case 4 needs a local fixture: game data, not distributed; each developer dumps it from their own
// copy of the game (tests/host/README.md). Without it the case prints a SKIP line and does not
// count as passed; a fixture that is present but unreadable fails.
//
// usage: gcn_scalar_reads_test <local fixture dir with u4_cs_blur.bin/.txt>
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <fstream>
#include <sstream>
#include <sys/stat.h>
#include <string>
#include <vector>

#include "gcn_recompiler.h"

namespace {

int g_fail = 0;
#define CHECK(c, ...)                                                    \
    do {                                                                 \
        if (!(c)) {                                                      \
            std::fprintf(stderr, "gcn_scalar_reads_test: FAIL %s:%d: ", __FILE__, __LINE__); \
            std::fprintf(stderr, __VA_ARGS__);                           \
            std::fprintf(stderr, "\n");                                  \
            g_fail++;                                                    \
        }                                                                \
    } while (0)

std::string g_log; // recompiler messages of the current compile
void LogSink(void*, int level, const char* msg) {
    if (level >= 3) g_log += std::string(msg) + "\n";
}

// Guest memory: one shared MTLBuffer standing for guest addresses [kGuestBase, +kGuestSize).
constexpr uint64_t kGuestBase = 0x10000000;
constexpr uint64_t kGuestSize = 4u << 20;

struct Guest {
    id<MTLBuffer> buf;
    uint8_t* p(uint64_t a) { return static_cast<uint8_t*>(buf.contents) + (a - kGuestBase); }
    void Put32(uint64_t a, std::initializer_list<uint32_t> w) { std::memcpy(p(a), w.begin(), w.size() * 4); }
    static bool Read(void* ctx, uint64_t addr, void* dst, uint64_t size) {
        auto* g = static_cast<Guest*>(ctx);
        if (addr < kGuestBase || addr + size > kGuestBase + kGuestSize) return false;
        std::memcpy(dst, g->p(addr), size);
        return true;
    }
};

// Guest memory for compile-only tests (no Metal buffer).
struct FakeGuest {
    std::vector<std::pair<uint64_t, std::vector<uint8_t>>> regions;
    void Add(uint64_t base, const void* p, size_t n) {
        regions.push_back({base, std::vector<uint8_t>((const uint8_t*)p, (const uint8_t*)p + n)});
    }
    static bool Read(void* ctx, uint64_t addr, void* dst, uint64_t size) {
        for (const auto& [base, data] : static_cast<FakeGuest*>(ctx)->regions) {
            if (addr >= base && addr + size <= base + data.size()) {
                std::memcpy(dst, data.data() + (addr - base), size);
                return true;
            }
        }
        std::memset(dst, 0, size); // the table itself: pointers read as 0
        return true;
    }
};

// Shader code with the "s_mov_b32 vcc_hi, <footer offset>" header and the OrbShdr footer.
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

// Raw V# (stride 0, num_records in bytes, 32-bit uint elements).
void VSharp(uint32_t* v, uint64_t base, uint32_t bytes) {
    v[0] = uint32_t(base);
    v[1] = uint32_t(base >> 32) & 0xFFF;
    v[2] = bytes;
    v[3] = 4 | (5 << 3) | (6 << 6) | (7 << 9) | (4 << 12) | (4 << 15);
}

// Runs a single-thread compute shader: binds its guest buffers (V# base -> offset in the guest
// MTLBuffer, size -> push_data.buf_sizes), the flattened user data and the push constants.
bool RunCompute(id<MTLDevice> dev, Guest& g, const gcn_shader* sh, const uint32_t ud[16]) {
    gcn_shader_info info;
    gcn_shader_get_info(sh, &info);
    const char* msl = gcn_shader_msl(sh);
    if (!msl) return false;
    NSError* e = nil;
    MTLCompileOptions* o = [MTLCompileOptions new];
    o.languageVersion = MTLLanguageVersion2_3;
    id<MTLLibrary> lib = [dev newLibraryWithSource:[NSString stringWithUTF8String:msl] options:o error:&e];
    if (!lib) {
        std::fprintf(stderr, "MSL: %s\n%s\n", e.localizedDescription.UTF8String, msl);
        return false;
    }
    id<MTLComputePipelineState> pso =
        [dev newComputePipelineStateWithFunction:[lib newFunctionWithName:@"main0"] error:&e];
    if (!pso) return false;
    std::vector<uint32_t> flat(info.flatbuf_size_dw);
    if (!gcn_shader_build_flatbuf(sh, ud, Guest::Read, &g, flat.data(), flat.size())) return false;
    gcn_push_data pd{};
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
            if (d.base_address < kGuestBase || d.base_address >= kGuestBase + kGuestSize) return false;
            [enc setBuffer:g.buf offset:d.base_address - kGuestBase atIndex:b.msl_buffers[k]];
            if (b.buffer_slot < GCN_MAX_BUFFERS) pd.buf_sizes[b.buffer_slot] = d.size_bytes;
        }
    }
    if (info.msl_push_constant_buffer >= 0)
        [enc setBytes:&pd length:sizeof(pd) atIndex:(NSUInteger)info.msl_push_constant_buffer];
    [enc dispatchThreadgroups:MTLSizeMake(1, 1, 1) threadsPerThreadgroup:MTLSizeMake(1, 1, 1)];
    [enc endEncoding];
    [cb commit];
    [cb waitUntilCompleted];
    return cb.status == MTLCommandBufferStatusCompleted;
}

void TestHandWritten(id<MTLDevice> dev) {
    Guest g{[dev newBufferWithLength:kGuestSize options:MTLResourceStorageModeShared]};
    std::memset(g.buf.contents, 0, kGuestSize);
    const uint64_t code = kGuestBase, table = kGuestBase + 0x1000, small = kGuestBase + 0x2000,
                   out = kGuestBase + 0x3000;
    // user data: s[0:1] table pointer, s[4:7] V# of out, s[8:11] V# of an 8-byte buffer
    //   s_movk_i32 s12, 0                  ; byte offset
    //   s_movk_i32 s13, 0                  ; sum
    // loop:
    //   s_load_dword s14, s[0:1], s12      ; offset known only to the shader
    //   s_waitcnt lgkmcnt(0)
    //   s_add_u32 s13, s13, s14
    //   s_add_u32 s12, s12, 4
    //   s_cmp_lt_u32 s12, 16
    //   s_cbranch_scc1 loop
    //   s_buffer_load_dword s15, s[8:11], 4 ; dword 4 = byte 16, past num_records (8)
    //   s_waitcnt lgkmcnt(0)
    //   v_mov_b32 v1, s13
    //   v_mov_b32 v2, s15
    //   v_mov_b32 v0, 0
    //   buffer_store_dword v1, v0, s[4:7], 0
    //   buffer_store_dword v2, v0, s[4:7], 0 offset:4
    //   s_movk_i32 s20, 0
    //   s_buffer_load_dwordx4 s[16:19], s[8:11], s20 ; SGPR byte offset; dwords 2-3 past the end
    //   s_waitcnt lgkmcnt(0)
    //   v_mov_b32 v3..v6, s16..s19
    //   buffer_store_dword v3..v6, v0, s[4:7], 0 offset:8..20
    //   s_endpgm
    const auto prog = WithFooter({0xB00C0000, 0xB00D0000, 0xC007000C, 0xBF8C007F, 0x800D0E0D, 0x800C840C,
                                  0xBF0A900C, 0xBF85FFFA, 0xC2078904, 0xBF8C007F, 0x7E02020D, 0x7E04020F,
                                  0x7E000280, 0xE0700000, 0x80010100, 0xE0700004, 0x80010200, 0xB0140000,
                                  0xC2880814, 0xBF8C007F, 0x7E060210, 0x7E080211, 0x7E0A0212, 0x7E0C0213,
                                  0xE0700008, 0x80010300, 0xE070000C, 0x80010400, 0xE0700010, 0x80010500,
                                  0xE0700014, 0x80010600, 0xBF810000},
                                 0x5CA1A2EAD5000001ULL);
    std::memcpy(g.p(code), prog.data(), prog.size() * 4);
    g.Put32(table, {1000, 200, 30, 4, 0x55555555}); // the loop sums the first four
    g.Put32(small, {7, 8, 0xDEADBEEF, 0xDEADBEEF, 0xDEADBEEF}); // num_records 8: dwords 2.. are past it
    g.Put32(out, {0xFFFFFFFF, 0xFFFFFFFF, 0xFFFFFFFF, 0xFFFFFFFF, 0xFFFFFFFF, 0xFFFFFFFF});

    gcn_profile prof;
    gcn_profile_default_metal(&prof);
    gcn_runtime_info rt{};
    rt.hw_stage = GCN_HW_CS;
    rt.sw_stage = GCN_SW_COMPUTE;
    rt.num_allocated_vgprs = 8;
    rt.num_user_data = 12;
    rt.cs.workgroup_size[0] = rt.cs.workgroup_size[1] = rt.cs.workgroup_size[2] = 1;
    gcn_compile_desc d{};
    d.hw_stage = GCN_HW_CS;
    d.sw_stage = GCN_SW_COMPUTE;
    d.code_addr = code;
    d.user_data[0] = uint32_t(table);
    d.user_data[1] = uint32_t(table >> 32);
    VSharp(&d.user_data[4], out, 64);
    VSharp(&d.user_data[8], small, 8);
    d.runtime = &rt;
    d.profile = &prof;
    d.read_guest = Guest::Read;
    d.read_ctx = &g;
    d.flags = GCN_COMPILE_EMIT_MSL;
    g_log.clear();
    gcn_shader* sh = nullptr;
    char err[512] = {};
    const gcn_status st = gcn_compile(&d, &sh, err, sizeof(err));
    CHECK(st == GCN_OK && sh, "hand-written CS does not compile: %s", err);
    if (!sh) return;
    CHECK(g_log.find("Failed to compute offset") == std::string::npos, "SRT walker error:\n%s", g_log.c_str());
    CHECK(RunCompute(dev, g, sh, d.user_data), "hand-written CS did not run");
    uint32_t r[6];
    std::memcpy(r, g.p(out), sizeof(r));
    CHECK(r[0] == 1234, "s_load_dword with a loop-counter offset: sum %u, expected 1234", r[0]);
    CHECK(r[1] == 0, "s_buffer_load_dword past num_records read 0x%08x, expected 0", r[1]);
    CHECK(r[2] == 7 && r[3] == 8 && r[4] == 0 && r[5] == 0,
          "s_buffer_load_dwordx4 (SGPR offset) straddling num_records read %08x %08x %08x %08x, expected 7 8 0 0",
          r[2], r[3], r[4], r[5]);
    gcn_shader_destroy(sh);
}

void TestLostPointerLogged() {
    FakeGuest mem;
    const uint64_t code = kGuestBase, table = kGuestBase + 0x1000;
    //   v_readfirstlane_b32 s12, v0        ; offset only the shader knows
    //   s_load_dwordx2 s[16:17], s[0:1], s12
    //   s_waitcnt lgkmcnt(0)
    //   s_load_dword s18, s[16:17], 0      ; read through that pointer
    //   s_waitcnt lgkmcnt(0)
    //   v_mov_b32 v1, s18
    //   v_mov_b32 v0, 0
    //   buffer_store_dword v1, v0, s[4:7], 0
    //   s_endpgm
    const auto prog = WithFooter({0x7E180500, 0xC048000C, 0xBF8C007F, 0xC0091100, 0xBF8C007F, 0x7E020212,
                                  0x7E000280, 0xE0700000, 0x80010100, 0xBF810000},
                                 0x5CA1A2EAD5000002ULL);
    mem.Add(code, prog.data(), prog.size() * 4);
    gcn_profile prof;
    gcn_profile_default_metal(&prof);
    gcn_runtime_info rt{};
    rt.hw_stage = GCN_HW_CS;
    rt.sw_stage = GCN_SW_COMPUTE;
    rt.num_allocated_vgprs = 4;
    rt.num_user_data = 8;
    rt.cs.workgroup_size[0] = rt.cs.workgroup_size[1] = rt.cs.workgroup_size[2] = 1;
    gcn_compile_desc d{};
    d.hw_stage = GCN_HW_CS;
    d.sw_stage = GCN_SW_COMPUTE;
    d.code_addr = code;
    d.user_data[0] = uint32_t(table);
    d.user_data[1] = uint32_t(table >> 32);
    VSharp(&d.user_data[4], kGuestBase + 0x3000, 64);
    d.runtime = &rt;
    d.profile = &prof;
    d.read_guest = FakeGuest::Read;
    d.read_ctx = &mem;
    d.flags = GCN_COMPILE_EMIT_MSL;
    g_log.clear();
    gcn_shader* sh = nullptr;
    char err[512] = {};
    const gcn_status st = gcn_compile(&d, &sh, err, sizeof(err));
    CHECK(st == GCN_OK && sh, "lost-pointer CS does not compile: %s", err);
    CHECK(g_log.find("SRT pointer read at an offset only the shader knows") != std::string::npos,
          "a pointer read at a shader-only offset was not logged; log:\n%s", g_log.c_str());
    gcn_shader_destroy(sh);
}

bool LoadFile(const std::string& path, std::vector<uint8_t>& out) {
    std::ifstream f(path, std::ios::binary);
    if (!f) return false;
    out.assign(std::istreambuf_iterator<char>(f), std::istreambuf_iterator<char>());
    return true;
}

// False (and a SKIP line) when one of the blur's fixture files is absent.
bool HaveBlurFixture(const std::string& dir) {
    for (const char* f : {"/u4_cs_blur.bin", "/u4_cs_blur.txt"}) {
        struct stat st;
        if (stat((dir + f).c_str(), &st) != 0) {
            std::printf("SKIP: gcn_scalar_reads_test/u4_cs_blur: needs local fixture %s%s (game data, not distributed)\n",
                        dir.c_str(), f);
            return false;
        }
    }
    return true;
}

void TestU4Blur(id<MTLDevice> dev, const std::string& dir) {
    std::vector<uint8_t> code;
    CHECK(LoadFile(dir + "/u4_cs_blur.bin", code) && code.size() >= 8, "cannot read %s/u4_cs_blur.bin", dir.c_str());
    if (code.size() < 8) return;
    std::vector<uint32_t> regs(0x10000, 0);
    std::ifstream txt(dir + "/u4_cs_blur.txt");
    std::string line;
    uint64_t code_addr = 0;
    while (std::getline(txt, line)) {
        if (line.empty()) continue;
        if (line[0] == '#') {
            const auto p = line.find("at 0x");
            if (p != std::string::npos) code_addr = std::strtoull(line.c_str() + p + 3, nullptr, 16);
            continue;
        }
        std::istringstream ss(line);
        std::string a, b;
        ss >> a >> b;
        const uint32_t r = std::strtoul(a.c_str(), nullptr, 16);
        if (r < regs.size()) regs[r] = std::strtoul(b.c_str(), nullptr, 16);
    }
    CHECK(code_addr != 0, "no program address in u4_cs_blur.txt");
    gcn_profile prof;
    gcn_profile_default_metal(&prof);
    gcn_runtime_info rt;
    gcn_runtime_info_from_regs(regs.data(), regs.size(), GCN_HW_CS, GCN_SW_COMPUTE, &prof, &rt);
    gcn_compile_desc d{};
    d.hw_stage = GCN_HW_CS;
    d.sw_stage = GCN_SW_COMPUTE;
    uint64_t reg_addr = 0;
    gcn_stage_from_regs(regs.data(), regs.size(), GCN_HW_CS, &reg_addr, d.user_data);
    d.code_addr = code_addr;
    d.code = reinterpret_cast<const uint32_t*>(code.data());
    d.code_size = uint32_t(code.size() & ~3u);

    // Guest memory: the shader, and its SRT at s[0:1] (moved into the test's guest range):
    // T# at dwords 0 and 8, clamps at 16/17, scale at 18, weights from byte 72 on.
    Guest g{[dev newBufferWithLength:kGuestSize options:MTLResourceStorageModeShared]};
    std::memset(g.buf.contents, 0, kGuestSize);
    const uint64_t srt = kGuestBase + 0x4000;
    d.user_data[0] = uint32_t(srt);
    d.user_data[1] = uint32_t(srt >> 32);
    const uint32_t tsharp[8] = {0x00001000, 0x00A00000, 0x003FC0FF, 0x90000FAC, 0x001FE000, 0, 0, 0};
    std::memcpy(g.p(srt), tsharp, 32);
    std::memcpy(g.p(srt + 32), tsharp, 32);
    d.runtime = &rt;
    d.profile = &prof;
    d.read_guest = Guest::Read;
    d.read_ctx = &g;
    d.flags = GCN_COMPILE_EMIT_MSL;
    g_log.clear();
    gcn_shader* sh = nullptr;
    char err[512] = {};
    const gcn_status st = gcn_compile(&d, &sh, err, sizeof(err));
    CHECK(st == GCN_OK && sh, "U4 blur does not compile: %s", err);
    if (!sh) return;
    CHECK(g_log.find("Failed to compute offset") == std::string::npos, "SRT walker error:\n%s", g_log.c_str());
    gcn_shader_info info;
    gcn_shader_get_info(sh, &info);
    std::vector<uint32_t> flat(info.flatbuf_size_dw);
    gcn_shader_build_flatbuf(sh, d.user_data, Guest::Read, &g, flat.data(), flat.size());
    bool weights = false;
    for (uint32_t i = 0; i < info.num_buffers; i++) {
        gcn_buffer_binding b;
        gcn_shader_get_buffer(sh, i, &b);
        uint32_t v[4];
        gcn_buffer_desc bd{};
        if (b.type != GCN_BUFFER_GUEST || !gcn_shader_fetch_buffer_sharp(sh, i, flat.data(), code_addr, v)) continue;
        gcn_decode_buffer(v, &bd);
        if (bd.base_address == srt && !b.is_written && b.num_msl_buffers > 0) weights = true;
    }
    CHECK(weights, "no guest buffer based at the SRT pointer for the blur weights");
    gcn_shader_destroy(sh);
}

} // namespace

int main(int argc, char** argv) {
    @autoreleasepool {
        id<MTLDevice> dev = MTLCreateSystemDefaultDevice();
        if (!dev) {
            std::fprintf(stderr, "gcn_scalar_reads_test: no Metal device\n");
            return 1;
        }
        gcn_set_log_callback(LogSink, nullptr);
        TestHandWritten(dev);
        TestLostPointerLogged();
        const std::string dir = argc > 1 ? argv[1] : ".";
        const bool blur = HaveBlurFixture(dir);
        if (blur) TestU4Blur(dev, dir);
        if (g_fail) return 1;
        if (blur) std::printf("gcn_scalar_reads_test: PASS\n");
        else std::printf("gcn_scalar_reads_test: PASS (3 cases run, 1 skipped)\n");
    }
    return 0;
}
