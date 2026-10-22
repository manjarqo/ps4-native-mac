// Shaders dumped from Uncharted 4's chapter 1 (the boat) that the shader translator
// (3rdparty/gcn-recompiler) rejected, so their dispatches were skipped:
//  - u4_cs_execlo.*  (0x1300124f00): "s_mov_b32 exec_lo, -1" / "exec_hi, -1" (32-bit writes of
//    one EXEC half) failed with "SetDst: Unknown field 126".
//  - u4_cs_spill.*   (0x130015c400, async compute, skipped ~5 times per frame): V#s and a
//    pointer spilled to VGPR lanes (v_writelane / v_readlane) through a VGPR also written as a
//    relative-indexed register array in a loop; "Sharp dword 0 produced by ReadLane", then
//    "ReadConst base low not from constant memory". Its wave64 ballots then read workgroup
//    memory through a u64 view next to the u32 one, which the MSL backend dropped (undeclared
//    shared_mem_u32): Metal rejected the shader.
//  - u4_vs_fullscreen.* (0x1300000300): a vertex shader. The library declares the position
//    invariant itself (passes with depth func EQUAL after a prepass rely on equal positions).
//    The renderer already rewrote the MSL to [[position, invariant]], so this is not the cause
//    of the characters missing in U4's chapter 1; the check keeps the library's output right.
// Each must translate (with zeroed guest memory: the sharps' contents do not matter here) and
// the MSL must be accepted by Metal.
//
// The fixtures are game data and are not distributed: each developer dumps them from their own
// copy of the game (tests/host/README.md). A case whose fixture is absent prints a SKIP line and
// does not count as passed; a fixture that is present but unreadable fails.
//
// usage: gcn_u4_cs_test <local fixture dir>
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <fstream>
#include <sys/stat.h>
#include <sstream>
#include <string>
#include <vector>

#include "gcn_recompiler.h"
#include "msl_barrier_check.h"

namespace {

int g_fail = 0;
int g_run = 0, g_skipped = 0;
#define CHECK(c, ...)                                                                   \
    do {                                                                                \
        if (!(c)) {                                                                     \
            std::fprintf(stderr, "gcn_u4_cs_test: FAIL %s:%d: ", __FILE__, __LINE__);  \
            std::fprintf(stderr, __VA_ARGS__);                                          \
            std::fprintf(stderr, "\n");                                                 \
            g_fail++;                                                                   \
        }                                                                               \
    } while (0)

bool ZeroRead(void*, uint64_t, void* dst, uint64_t size) {
    std::memset(dst, 0, size);
    return true;
}

bool Exists(const std::string& path) {
    struct stat st;
    return stat(path.c_str(), &st) == 0;
}

// False (and a SKIP line) when one of the case's fixture files is absent.
bool HaveFixture(const std::string& dir, const std::string& name) {
    for (const char* ext : {".bin", ".txt"}) {
        const std::string path = dir + "/" + name + ext;
        if (!Exists(path)) {
            std::printf("SKIP: gcn_u4_cs_test/%s: needs local fixture %s (game data, not distributed)\n",
                        name.c_str(), path.c_str());
            g_skipped++;
            return false;
        }
    }
    g_run++;
    return true;
}

void Run(id<MTLDevice> dev, const std::string& dir, const std::string& name, uint32_t hw = GCN_HW_CS,
         uint32_t sw = GCN_SW_COMPUTE) {
    if (!HaveFixture(dir, name)) return;
    std::ifstream bin(dir + "/" + name + ".bin", std::ios::binary);
    std::vector<uint8_t> code((std::istreambuf_iterator<char>(bin)), std::istreambuf_iterator<char>());
    CHECK(code.size() >= 8, "cannot read %s/%s.bin", dir.c_str(), name.c_str());
    if (code.size() < 8) return;
    std::vector<uint32_t> regs(0x10000, 0);
    std::ifstream txt(dir + "/" + name + ".txt");
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
    CHECK(code_addr != 0, "%s: no program address", name.c_str());
    gcn_profile prof;
    gcn_profile_default_metal(&prof);
    gcn_runtime_info rt;
    gcn_runtime_info_from_regs(regs.data(), regs.size(), (gcn_hw_stage)hw, (gcn_sw_stage)sw, &prof, &rt);
    gcn_compile_desc d{};
    d.hw_stage = (gcn_hw_stage)hw;
    d.sw_stage = (gcn_sw_stage)sw;
    uint64_t reg_addr = 0;
    gcn_stage_from_regs(regs.data(), regs.size(), (gcn_hw_stage)hw, &reg_addr, d.user_data);
    d.code_addr = code_addr;
    d.code = reinterpret_cast<const uint32_t*>(code.data());
    d.code_size = uint32_t(code.size() & ~3u);
    d.runtime = &rt;
    d.profile = &prof;
    d.read_guest = ZeroRead;
    d.read_ctx = nullptr;
    d.flags = GCN_COMPILE_EMIT_MSL;
    gcn_shader* sh = nullptr;
    char err[1024] = {};
    const gcn_status st = gcn_compile(&d, &sh, err, sizeof(err));
    CHECK(st == GCN_OK && sh, "%s does not translate: %s", name.c_str(), err);
    if (!sh) return;
    const char* msl = gcn_shader_msl(sh);
    CHECK(msl, "%s: no MSL", name.c_str());
    if (const char* dir = std::getenv("GCN_U4_CS_TEST_MSL_DIR"); msl && dir) { // for inspection
        if (FILE* f = std::fopen((std::string(dir) + "/" + name + ".metal").c_str(), "w")) {
            std::fputs(msl, f);
            std::fclose(f);
        }
    }
    if (msl && hw == GCN_HW_CS) { // no barrier that part of the workgroup may not reach (a GPU hang)
        const auto errors = msl_check::BarrierErrors(msl);
        for (size_t i = 0; i < errors.size() && i < 4; i++) std::fprintf(stderr, "  %s: %s\n", name.c_str(), errors[i].c_str());
        CHECK(errors.empty(), "%s: %zu barrier(s) part of the workgroup may not reach", name.c_str(), errors.size());
        // every EXEC-divergent region predicated, no lane read left per subgroup: u4_cs_spill had
        // 58 regions and 145 lane reads per subgroup (registers of vector type in its regions),
        // and 56 barriers under per-subgroup conditions
        gcn_shader_info info;
        gcn_shader_get_info(sh, &info);
        CHECK(info.unpredicated_wave_regions == 0 && info.per_subgroup_lane_ops == 0,
              "%s: %u region(s) not predicated, %u lane read(s) per subgroup", name.c_str(),
              info.unpredicated_wave_regions, info.per_subgroup_lane_ops);
    }
    if (msl && hw == GCN_HW_VS)
        CHECK(std::strstr(msl, "[[position, invariant]]"), "%s: the position output is not invariant", name.c_str());
    if (msl) {
        NSError* e = nil;
        MTLCompileOptions* o = [MTLCompileOptions new];
        o.preserveInvariance = YES;
        o.languageVersion = MTLLanguageVersion2_3;
        id<MTLLibrary> lib = [dev newLibraryWithSource:[NSString stringWithUTF8String:msl] options:o error:&e];
        CHECK(lib && [lib newFunctionWithName:@"main0"], "%s: Metal rejects the MSL: %s", name.c_str(),
              e ? e.localizedDescription.UTF8String : "no main0");
    }
    gcn_shader_destroy(sh);
}

} // namespace

int main(int argc, char** argv) {
    @autoreleasepool {
        if (argc < 2) {
            std::fprintf(stderr, "usage: gcn_u4_cs_test <fixture dir>\n");
            return 2;
        }
        id<MTLDevice> dev = MTLCreateSystemDefaultDevice();
        if (!dev) {
            std::fprintf(stderr, "gcn_u4_cs_test: no Metal device\n");
            return 1;
        }
        Run(dev, argv[1], "u4_cs_execlo");
        Run(dev, argv[1], "u4_cs_spill");
        Run(dev, argv[1], "u4_vs_fullscreen", GCN_HW_VS, GCN_SW_VERTEX);
        if (g_fail) {
            std::fprintf(stderr, "gcn_u4_cs_test: %d failure(s)\n", g_fail);
            return 1;
        }
        if (g_run == 0) {
            std::printf("gcn_u4_cs_test: SKIP (all %d cases need local fixtures)\n", g_skipped);
            return 0;
        }
        if (g_skipped) std::printf("gcn_u4_cs_test: PASS (%d cases run, %d skipped)\n", g_run, g_skipped);
        else std::printf("gcn_u4_cs_test: PASS\n");
        return 0;
    }
}
