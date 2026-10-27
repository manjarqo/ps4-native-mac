// GCN translation cache lookups with thousands of permutations of one program
// (pkg/runtime/modules/libSceGnmDriver/ps4_gnm_shader_cache.mm) on real translations.
//
// usage: gcn_cache_lookup_test session <dir> <n>
//          translates and stores n permutations of one compute program (they differ in the
//          buffer stride, which is part of the specialization), deletes the cache files once they
//          are written, then looks permutations up: every stored one must be found (from memory:
//          its file is gone), an unstored one must miss, and the lookup cost must not grow with
//          the number of permutations (the program's bucket holds all n).
//        gcn_cache_lookup_test write <dir> <n>   translates and stores n permutations, waits for
//          the files
//        gcn_cache_lookup_test odd <dir> <n>  a bucket with n permutations plus one entry of another
//          resource layout (a program without buffers, stored under the same key): a draw no
//          permutation fits finds that entry through the path that checks such entries one by
//          one, and gcn_shader_matches_draw_spec agrees with gcn_shader_is_compatible for it.
//        gcn_cache_lookup_test restart <dir> <n> a new process on that cache: lookups issued
//          while the startup loader runs return at once (hit or miss, never waiting for the
//          disk); once it finished, every permutation is found.
#import <Foundation/Foundation.h>

#include "gcn_recompiler.h"
#include "ps4_gnm_shader_cache.h"

#include <dirent.h>
#include <unistd.h>

#include <algorithm>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>

// The VFS of a game whose app root is /test/LOOKUPTEST and has no param.sfo: the shader caches
// are keyed by the root's name (ps4_current_game_key's fallback).
extern "C" const char* ps4_vfs_get_app_root(void) {
    return "/test/LOOKUPTEST";
}
extern "C" int ps4_vfs_resolve(const char*, char*, size_t) {
    return -1;
}

namespace sc = ps4gnm_shader_cache;

namespace {

int g_fail = 0;
#define CHECK(c)                                                                                   \
    do {                                                                                           \
        if (!(c)) {                                                                                \
            fprintf(stderr, "gcn_cache_lookup_test: FAIL %s:%d: %s\n", __FILE__, __LINE__, #c);    \
            g_fail++;                                                                              \
        }                                                                                          \
    } while (0)

constexpr uint64_t kCode = 0x1000;
std::vector<uint8_t> g_mem(1 << 20);

bool Read(void*, uint64_t addr, void* dst, uint64_t size) {
    if (addr >= g_mem.size() || size > g_mem.size() - addr) return false;
    memcpy(dst, g_mem.data() + addr, size);
    return true;
}

// v1 = v0 << 2; buffer_store_dword v0, v1, s[0:3] offen; s_endpgm — then the OrbShdr footer.
void PutProgram() {
    const uint32_t cs[] = {0x34020082u, 0xE0701000u, 0x80000001u, 0xBF810000u};
    memcpy(g_mem.data() + kCode, cs, sizeof(cs));
    uint8_t bi[28] = {};
    memcpy(bi, "OrbShdr", 7);
    const uint32_t bits = (uint32_t)sizeof(cs) << 8; // length:24 after 8 flag bits
    memcpy(bi + 8, &bits, 4);
    const uint64_t hash = 0x5eed1234abcdull;
    memcpy(bi + 16, &hash, 8);
    memcpy(g_mem.data() + kCode + sizeof(cs), bi, sizeof(bi));
}

// A second program at kCode2: no resources (another resource layout).
constexpr uint64_t kCode2 = 0x3000;
void PutProgram2() {
    const uint32_t cs[] = {0xBF800000u, 0xBF800000u, 0xBF800000u, 0xBF810000u}; // s_nop x3, s_endpgm
    memcpy(g_mem.data() + kCode2, cs, sizeof(cs));
    uint8_t bi[28] = {};
    memcpy(bi, "OrbShdr", 7);
    const uint32_t bits = (uint32_t)sizeof(cs) << 8;
    memcpy(bi + 8, &bits, 4);
    const uint64_t hash = 0x0dd0dd0dd0ull;
    memcpy(bi + 16, &hash, 8);
    memcpy(g_mem.data() + kCode2 + sizeof(cs), bi, sizeof(bi));
}

gcn_runtime_info Runtime() {
    gcn_runtime_info rt;
    memset(&rt, 0, sizeof(rt));
    rt.hw_stage = GCN_HW_CS;
    rt.sw_stage = GCN_SW_COMPUTE;
    rt.num_allocated_vgprs = 4;
    rt.num_user_data = 4;
    rt.cs.workgroup_size[0] = 64;
    rt.cs.workgroup_size[1] = rt.cs.workgroup_size[2] = 1;
    return rt;
}

// User data of permutation i: a buffer V# whose stride is 4 + i.
void UserData(uint32_t i, uint32_t ud[16]) {
    memset(ud, 0, 64);
    ud[0] = 0x600000;
    ud[1] = (4u + i) << 16;
    ud[2] = 4096;
    ud[3] = 4 | (5 << 3) | (6 << 6) | (7 << 9) | (4 << 12) | (4 << 15);
}

gcn_profile g_profile;
gcn_msl_options g_msl;

void StartCache(const char* dir) {
    setenv("PS4RECOMP_CACHE_DIR", dir, 1);
    gcn_profile_default_metal(&g_profile);
    gcn_msl_options_default(&g_msl);
    sc::Start(g_profile, g_msl);
}

std::string GcnDir(const char* dir) {
    // <dir>/LOOKUPTEST/gcn/<config>
    std::string root = std::string(dir) + "/LOOKUPTEST/gcn";
    DIR* d = opendir(root.c_str());
    std::string out;
    if (!d) return out;
    while (dirent* e = readdir(d))
        if (e->d_name[0] != '.') out = root + "/" + e->d_name;
    closedir(d);
    return out;
}

size_t CountFiles(const std::string& dir, bool remove) {
    size_t n = 0;
    if (DIR* d = opendir(dir.c_str())) {
        while (dirent* e = readdir(d)) {
            const size_t l = strlen(e->d_name);
            if (l > 4 && strcmp(e->d_name + l - 4, ".gsc") == 0) {
                n++;
                if (remove) unlink((dir + "/" + e->d_name).c_str());
            }
        }
        closedir(d);
    }
    return n;
}

bool Translate(uint32_t i, sc::Key* key, gcn_shader** out, uint64_t code = kCode) {
    const gcn_runtime_info rt = Runtime();
    uint32_t ud[16];
    UserData(i, ud);
    gcn_compile_desc d{};
    d.hw_stage = GCN_HW_CS;
    d.sw_stage = GCN_SW_COMPUTE;
    d.code_addr = code;
    memcpy(d.user_data, ud, 64);
    d.runtime = &rt;
    d.profile = &g_profile;
    d.read_guest = Read;
    d.read_ctx = nullptr;
    d.flags = GCN_COMPILE_EMIT_MSL;
    d.msl = &g_msl;
    char err[256] = {0};
    if (gcn_compile(&d, out, err, sizeof(err)) != GCN_OK) {
        fprintf(stderr, "gcn_cache_lookup_test: translation %u failed: %s\n", i, err);
        return false;
    }
    return sc::MakeKey(GCN_HW_CS, GCN_SW_COMPUTE, rt, code, Read, nullptr, key);
}

// Stores n permutations; returns their key (all equal: one program, one runtime state).
sc::Key StoreAll(uint32_t n) {
    sc::Key key;
    for (uint32_t i = 0; i < n; ++i) {
        gcn_shader* sh = nullptr;
        if (!Translate(i, &key, &sh)) {
            g_fail++;
            break;
        }
        sc::Store(key, sh);
        gcn_shader_destroy(sh);
    }
    return key;
}

double Now() {
    return CFAbsoluteTimeGetCurrent() * 1000.0;
}

bool WaitFiles(const std::string& dir, size_t n) {
    for (int t = 0; t < 600 && CountFiles(dir, false) < n; ++t) usleep(50000);
    return CountFiles(dir, false) >= n;
}

// Looks up permutation i; true if found and compatible with its own user data.
bool Find(const sc::Key& key, uint32_t i, double* ms) {
    uint32_t ud[16];
    UserData(i, ud);
    const double t0 = Now();
    gcn_shader* hit = sc::Lookup(key, kCode, ud, Read, nullptr);
    *ms = Now() - t0;
    const gcn_runtime_info rt = Runtime();
    const bool ok = hit && gcn_shader_is_compatible(hit, ud, &rt, Read, nullptr);
    if (hit) gcn_shader_destroy(hit);
    return ok;
}

} // namespace

int main(int argc, char** argv) {
    if (argc < 4) {
        fprintf(stderr, "usage: gcn_cache_lookup_test session|write|restart <dir> <n>\n");
        return 2;
    }
    const std::string mode = argv[1];
    const char* dir = argv[2];
    const uint32_t n = (uint32_t)atoi(argv[3]);
    PutProgram();
    @autoreleasepool {
        if (mode == "session") {
            StartCache(dir);
            CHECK(sc::Enabled());
            // a small bucket first, as the reference cost
            const uint32_t small = 100;
            sc::Key key = StoreAll(small);
            double ms = 0, small_total = 0;
            for (uint32_t i = 0; i < small; ++i) {
                CHECK(Find(key, i, &ms));
                small_total += ms;
            }
            const double small_mean = small_total / small;
            // grow the same bucket to n permutations
            for (uint32_t i = small; i < n; ++i) {
                gcn_shader* sh = nullptr;
                if (!Translate(i, &key, &sh)) {
                    g_fail++;
                    break;
                }
                sc::Store(key, sh);
                gcn_shader_destroy(sh);
            }
            // the files are written in the background; then delete them: lookups must not need them
            const std::string gd = GcnDir(dir);
            CHECK(!gd.empty());
            CHECK(WaitFiles(gd, n));
            CHECK(CountFiles(gd, true) == n);
            CHECK(CountFiles(gd, false) == 0);
            double total = 0, worst = 0;
            uint32_t found = 0, probes = 0;
            for (uint32_t i = 0; i < n; i += std::max(1u, n / 400)) {
                if (Find(key, i, &ms)) found++;
                probes++;
                total += ms;
                worst = std::max(worst, ms);
            }
            CHECK(found == probes); // every stored permutation is found, from memory
            uint32_t ud[16];
            UserData(n + 7, ud); // a stride no permutation has
            const double t0 = Now();
            gcn_shader* miss = sc::Lookup(key, kCode, ud, Read, nullptr);
            const double miss_ms = Now() - t0;
            CHECK(miss == nullptr);
            // a draw without the buffer bound (null V#): the slot is not compared, so a permutation
            // is reused (the first one, as a scan would pick), through another slot mask
            {
                uint32_t nud[16] = {};
                const gcn_runtime_info rt = Runtime();
                const double t1 = Now();
                gcn_shader* any = sc::Lookup(key, kCode, nud, Read, nullptr);
                const double null_ms = Now() - t1;
                CHECK(any != nullptr);
                if (any) {
                    CHECK(gcn_shader_is_compatible(any, nud, &rt, Read, nullptr));
                    gcn_shader_destroy(any);
                }
                CHECK(null_ms < 10.0);
            }
            const double mean = total / probes;
            fprintf(stderr, "gcn_cache_lookup_test: %u permutations in one bucket; lookup mean %.3f ms (%u: %.3f ms), "
                            "max %.3f ms, miss %.3f ms; %u/%u found\n",
                    n, mean, small, small_mean, worst, miss_ms, found, probes);
            // bounded: independent of the bucket size (a scan over every permutation grows with it)
            CHECK(mean < 0.1);
            CHECK(worst < 10.0);
            CHECK(miss_ms < 10.0);
            CHECK(mean < 4.0 * small_mean + 0.05);
        } else if (mode == "odd") {
            PutProgram2();
            StartCache(dir);
            sc::Key key = StoreAll(n);
            sc::Key key2;
            gcn_shader* other = nullptr;
            CHECK(Translate(0, &key2, &other, kCode2));
            gcn_shader* base = nullptr;
            sc::Key k0;
            CHECK(Translate(0, &k0, &base));
            const gcn_runtime_info rt = Runtime();
            uint32_t ud[16];
            UserData(n + 50, ud); // no stored permutation of the program has this stride
            // the API: for an entry of another layout, the match is the full compatibility check
            CHECK(!gcn_shader_same_resource_layout(other, base));
            CHECK(gcn_shader_same_resource_layout(base, base));
            gcn_draw_spec* ds = gcn_draw_spec_create(base, ud, &rt, Read, nullptr);
            CHECK(ds != nullptr);
            CHECK(gcn_shader_matches_draw_spec(other, ds, ud, &rt, Read, nullptr) ==
                  gcn_shader_is_compatible(other, ud, &rt, Read, nullptr));
            CHECK(gcn_shader_matches_draw_spec(other, ds, ud, &rt, Read, nullptr)); // no resources: fits any draw
            CHECK(!gcn_shader_matches_draw_spec(base, ds, ud, &rt, Read, nullptr)); // other stride
            CHECK(gcn_shader_matches_draw_spec(base, ds, ud, &rt, Read, nullptr) ==
                  gcn_shader_is_compatible(base, ud, &rt, Read, nullptr));
            gcn_draw_spec_destroy(ds);
            // the cache: before the odd entry the draw misses; after it the draw finds it
            double t0 = Now();
            gcn_shader* miss = sc::Lookup(key, kCode, ud, Read, nullptr);
            CHECK(miss == nullptr);
            sc::Store(key, other); // under the first program's key: an entry of another layout
            gcn_shader* hit = sc::Lookup(key, kCode, ud, Read, nullptr);
            const double ms = Now() - t0;
            CHECK(hit != nullptr);
            if (hit) {
                gcn_shader_info info;
                gcn_shader_get_info(hit, &info);
                CHECK(info.num_buffers == 0); // the odd entry, not a permutation of the program
                gcn_shader_destroy(hit);
            }
            // a stored stride still finds its own permutation (first in insertion order)
            double ms2 = 0;
            CHECK(Find(key, n / 2, &ms2));
            fprintf(stderr, "gcn_cache_lookup_test: odd entry found by a draw no permutation fits (%.3f ms)\n", ms);
            gcn_shader_destroy(other);
            gcn_shader_destroy(base);
        } else if (mode == "write") {
            StartCache(dir);
            StoreAll(n);
            CHECK(WaitFiles(GcnDir(dir), n));
        } else if (mode == "restart") {
            StartCache(dir); // the startup loader begins reading n files in the background
            sc::Key key;
            gcn_shader* sh = nullptr;
            CHECK(Translate(0, &key, &sh));
            if (sh) gcn_shader_destroy(sh);
            // while it loads: every lookup returns at once
            double worst = 0, ms = 0;
            uint32_t early_hits = 0, early = 0;
            for (int k = 0; k < 50; ++k, ++early) {
                if (Find(key, (uint32_t)(k * 37) % n, &ms)) early_hits++;
                worst = std::max(worst, ms);
            }
            // once loaded: every permutation is found
            bool all = false;
            for (int t = 0; t < 200 && !all; ++t) {
                all = true;
                for (uint32_t i = 0; i < n && all; i += std::max(1u, n / 100)) all = Find(key, i, &ms);
                if (!all) usleep(50000);
            }
            CHECK(all);
            // loaded from disk: the cost does not grow with the number of permutations either
            double total = 0, after_worst = 0;
            uint32_t probes = 0, found = 0;
            for (uint32_t i = 0; i < n; i += std::max(1u, n / 200)) {
                if (Find(key, i, &ms)) found++;
                probes++;
                total += ms;
                after_worst = std::max(after_worst, ms);
            }
            CHECK(found == probes);
            fprintf(stderr, "gcn_cache_lookup_test: restart with %u entries: %u/%u lookups during loading hit, "
                            "slowest %.3f ms; after loading %u/%u found, mean %.3f ms, max %.3f ms\n",
                    n, early_hits, early, worst, found, probes, total / probes, after_worst);
            CHECK(worst < 10.0);
            CHECK(total / probes < 0.1);
            CHECK(after_worst < 10.0);
        } else {
            fprintf(stderr, "unknown mode %s\n", mode.c_str());
            return 2;
        }
    }
    if (g_fail) {
        fprintf(stderr, "gcn_cache_lookup_test %s: %d checks FAILED\n", mode.c_str(), g_fail);
        return 1;
    }
    fprintf(stderr, "gcn_cache_lookup_test %s: PASS\n", mode.c_str());
    return 0;
}
