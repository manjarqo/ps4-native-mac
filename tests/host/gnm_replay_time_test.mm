// gnm_replay --time (ps4replay::TimePasses) through the real renderer on a synthetic capture: a
// compute kernel that loops a fixed number of VALU steps per thread is dispatched with 1 group and
// with 256 groups (and a third pass the renderer skipped). Each replayable pass gets one entry with
// the requested run count and 0 < min <= median; the pass with 256 groups takes longer than the
// one with 1, so the number follows the work the replay does and is not a constant.
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>

#include <string>
#include <vector>

#include "gcn_recompiler.h"
#include "gnm_replay.h"
#include "ps4_gnm_capture.h"

using namespace ps4gnm_capture;

namespace {

int g_fail = 0;
#define CHECK(c, ...)                                                                \
    do {                                                                             \
        if (!(c)) {                                                                  \
            fprintf(stderr, "gnm_replay_time_test: FAIL %s:%d: ", __FILE__, __LINE__); \
            fprintf(stderr, __VA_ARGS__);                                            \
            fprintf(stderr, "\n");                                                   \
            g_fail++;                                                                \
        }                                                                            \
    } while (0)

constexpr uint64_t kMemSize = 1ull << 32;
constexpr uint64_t kCode = 0x100000, kOut = 0x200000;
constexpr uint32_t kEnd = 0xBF810000;
constexpr uint32_t kSteps = 20000; // loop iterations per thread

// GCN program with the OrbShdr footer the translator looks for (as in gnm_replay_test).
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

// Writes <root>/frame_1: pass 0 and 1 run the same kernel with 1 and 256 groups of 1024 threads,
// pass 2 is one the renderer skipped.
//   s_movk_i32 s12, 0; v3 = v0 + 1
// loop (xorshift on v3: the compiler cannot fold it into a closed form):
//   v3 ^= v3 << 13; v3 ^= v3 >> 17; v3 ^= v3 << 5; s_add_u32 s12, s12, 1; s_cmp_lt_u32 s12, kSteps;
//   s_cbranch_scc1 loop
//   v_lshlrev_b32 v2, 2, v0; buffer_store_dword v3, v2, s[4:7] offen; s_endpgm
std::string WriteCapture(const std::string& root) {
    uint8_t* mem = (uint8_t*)mmap(nullptr, kMemSize, PROT_READ | PROT_WRITE, MAP_ANON | MAP_PRIVATE, -1, 0);
    const auto prog = WithFooter({0xB00C0000, 0x4A060081,             // s12 = 0; v3 = v0 + 1
                                  0x3408068D, 0x3A060704,             // loop: v4 = v3 << 13; v3 ^= v4
                                  0x2C080691, 0x3A060704,             //       v4 = v3 >> 17; v3 ^= v4
                                  0x34080685, 0x3A060704,             //       v4 = v3 << 5; v3 ^= v4
                                  0x800C810C,                         //       s12 += 1
                                  0xBF0AFF0C, kSteps, 0xBF85FFF6,     //       s_cmp_lt_u32 s12, kSteps; to loop
                                  0x34040082,                         // v2 = v0 << 2
                                  0xE0701000, 0x80010302, kEnd},      // buffer_store_dword v3, v2, s[4:7] offen
                                 0x5CA1AB1E000000B1ull);
    memcpy(mem + kCode, prog.data(), prog.size() * 4);
    memset(mem + kOut, 0, kPage);
    std::vector<uint32_t> regs(kNumRegs, 0);
    regs[0x2E07] = 1024; // COMPUTE_NUM_THREAD_X: 256 groups are more threads than the GPU runs at once
    regs[0x2E08] = regs[0x2E09] = 1;
    regs[0x2E0C] = uint32_t(kCode >> 8); // COMPUTE_PGM_LO
    regs[0x2E12] = 1;                    // RSRC1: 8 VGPRs
    regs[0x2E13] = 8 << 1;               // RSRC2: 8 user SGPRs
    uint32_t* ud = &regs[0x2E40];        // COMPUTE_USER_DATA_0..
    ud[4] = uint32_t(kOut);              // V#: base, stride 0, 4096 bytes, 32-bit uint
    ud[5] = 0;
    ud[6] = 4096;
    ud[7] = 4 | (5 << 3) | (6 << 6) | (7 << 9) | (4 << 12) | (4 << 15);
    const std::string dir = root + "/frame_1";
    Writer w(dir, 1, kMemSize, false, gcn_shader_cache_id());
    std::string err;
    CHECK(w.Begin(&err), "%s", err.c_str());
    for (uint32_t i = 0; i < 2; ++i) {
        PassRec p;
        p.index = i;
        p.replayable = true;
        p.type = "dispatch";
        p.queue = p.name = "gfx";
        p.regs_file = w.SaveRegs(regs.data(), &p.regs_hash);
        p.dim[0] = i ? 256 : 1;
        p.dim[1] = p.dim[2] = 1;
        StageRec st;
        st.stage = "cs";
        st.code_addr = kCode;
        p.stages.push_back(st);
        BufferRec b;
        b.stage = "cs";
        b.addr = kOut;
        b.size = 4096;
        b.written = true;
        memcpy(b.vsharp, &ud[4], 16);
        p.buffers.push_back(b);
        p.inputs.push_back(w.Snapshot(mem, kCode, kPage));
        p.inputs.push_back(w.Snapshot(mem, kOut, kPage));
        p.outputs.push_back(w.Snapshot(mem, kOut, kPage));
        w.AddPass(std::move(p));
    }
    PassRec skipped;
    skipped.index = 2;
    skipped.type = "dispatch";
    skipped.skipped = "meta clear";
    w.AddPass(std::move(skipped));
    CHECK(w.Finish(&err), "%s", err.c_str());
    munmap(mem, kMemSize);
    return dir;
}

void TestTimePasses(const std::string& root) {
    ps4replay::Options o;
    o.frame_dir = WriteCapture(root);
    std::vector<std::string> notes;
    const std::vector<ps4replay::PassTime> t = ps4replay::TimePasses(o, 0, UINT32_MAX, 5, &notes);
    CHECK(t.size() == 2, "%zu entries, want one per replayable pass (2)", t.size());
    CHECK(notes.size() == 1 && notes[0].find("pass 2") != std::string::npos && notes[0].find("meta clear") != std::string::npos,
          "the skipped pass is explained: %zu notes", notes.size());
    if (t.size() != 2) return;
    for (size_t i = 0; i < 2; ++i) {
        CHECK(t[i].pass == i, "entry %zu is pass %u", i, t[i].pass);
        CHECK(t[i].runs == 5, "pass %u: %d runs", t[i].pass, t[i].runs);
        CHECK(t[i].min_ms > 0 && t[i].min_ms <= t[i].median_ms, "pass %u: min %.4f median %.4f", t[i].pass, t[i].min_ms,
              t[i].median_ms);
    }
    printf("1 group: median %.3f ms min %.3f; 256 groups: median %.3f ms min %.3f\n", t[0].median_ms, t[0].min_ms,
           t[1].median_ms, t[1].min_ms);
    CHECK(t[1].median_ms > t[0].median_ms, "256 groups (%.3f ms) not slower than 1 group (%.3f ms)", t[1].median_ms,
          t[0].median_ms);
    // a range asks for its passes only, and a pass past the frame is reported
    notes.clear();
    const std::vector<ps4replay::PassTime> one = ps4replay::TimePasses(o, 1, 1, 3, &notes);
    CHECK(one.size() == 1 && one[0].pass == 1 && one[0].runs == 3 && notes.empty(), "single pass: %zu entries", one.size());
    notes.clear();
    CHECK(ps4replay::TimePasses(o, 7, 7, 3, &notes).empty() && notes.size() == 1, "pass past the frame end");
}

} // namespace

int main(int argc, char** argv) {
    @autoreleasepool {
        // write-capture <dir>: only writes the frame (<dir>/frame_1), for run_host_tests.sh to run
        // tools/gnm_replay --time on it.
        if (argc == 3 && !strcmp(argv[1], "write-capture")) {
            WriteCapture(argv[2]);
            return g_fail ? 1 : 0;
        }
        char tmpl[] = "/tmp/gnm_replay_time_test.XXXXXX";
        const char* root = mkdtemp(tmpl);
        if (!root) return 1;
        TestTimePasses(root);
        const std::string cmd = std::string("rm -rf '") + root + "'";
        if (system(cmd.c_str()) != 0) g_fail++;
        printf("gnm_replay_time_test: %s\n", g_fail ? "FAIL" : "PASS");
        return g_fail ? 1 : 0;
    }
}
