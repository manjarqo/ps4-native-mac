// CPU detiling compared byte for byte with the per-element address oracle. Includes partial
// tiles, slices, mips and truncated input; --bench reports timings without a timing assertion.
#include <algorithm>
#include <chrono>
#include <cstdio>
#include <cstring>
#include <vector>
#include "ps4_gnm_resources.h"

extern "C" uint64_t ps4_hitch_now_ns(void) { return 0; }
extern "C" void ps4_hitch_add_ns(int, uint64_t) {}
extern "C" void ps4_gnm_hitch_note_upload(double) {}
extern "C" int32_t sceKernelIsNeoMode(void) { return 0; }

using namespace ps4gnm;

static bool Run(uint32_t w, uint32_t h, uint32_t pitch, uint32_t depth, uint32_t layers,
                uint32_t levels, TileMode mode, uint32_t bpp, bool truncated, bool bench) {
    SurfaceDesc sd;
    sd.width = w; sd.height = h; sd.pitch = pitch; sd.depth = depth;
    sd.layers = layers; sd.levels = levels; sd.tile_mode = mode; sd.bpp = bpp;
    SurfaceLayout l;
    if (!ComputeSurfaceLayout(sd, &l)) return false;
    std::vector<uint8_t> tiled(l.total_size), expected(l.total_size), got(l.total_size);
    for (size_t i = 0; i < tiled.size(); ++i) tiled[i] = uint8_t((i * 37) ^ (i >> 5) ^ (i >> 13));
    const size_t available = truncated ? tiled.size() - 17 : tiled.size();
    const uint32_t bytes = bpp / 8;
    for (uint32_t m = 0; m < levels; ++m) {
        const auto& ml = l.mips[m];
        for (uint32_t s = 0; s < std::max(1u, depth >> m) * layers; ++s)
            for (uint32_t y = 0; y < std::max(1u, h >> m); ++y)
                for (uint32_t x = 0; x < std::max(1u, w >> m); ++x) {
                    const uint64_t ta = TiledElementOffset(sd, l, m, x, y, s);
                    const uint64_t to = ml.offset + ((uint64_t(s) * ml.height + y) * ml.pitch + x) * bytes;
                    if (ta + bytes <= available) memcpy(expected.data() + to, tiled.data() + ta, bytes);
                }
    }
    if (!DetileSurface(sd, l, tiled.data(), available, got.data(), got.size(), 0, levels, true) || got != expected) {
        fprintf(stderr, "FAIL: %ux%u pitch %u depth %u layers %u mips %u mode %u bpp %u truncated %d\n",
                w, h, pitch, depth, layers, levels, unsigned(mode), bpp, int(truncated));
        return false;
    }
    if (bench) {
        std::vector<double> times;
        for (int i = 0; i < 120; ++i) {
            const auto start = std::chrono::steady_clock::now();
            DetileSurface(sd, l, tiled.data(), available, got.data(), got.size(), 0, levels, true);
            const auto end = std::chrono::steady_clock::now();
            if (i >= 20) times.push_back(std::chrono::duration<double, std::milli>(end - start).count());
        }
        std::sort(times.begin(), times.end());
        printf("detile %ux%u pitch %u mode %u median_ms %.6f min_ms %.6f runs %zu\n",
               w, h, pitch, unsigned(mode), times[times.size() / 2], times.front(), times.size());
    }
    return true;
}

int main(int argc, char** argv) {
    bool ok = true;
    const bool bench = argc == 2 && !strcmp(argv[1], "--bench");
    for (bool truncated : {false, true}) {
        ok &= Run(64, 64, 64, 1, 1, 1, TileMode::Thin1DThin, 32, truncated, false);
        ok &= Run(37, 19, 64, 1, 1, 1, TileMode::Thin1DThin, 32, truncated, false);
        ok &= Run(36, 20, 64, 1, 2, 3, TileMode::Thin1DThin, 32, truncated, false);
        ok &= Run(16, 13, 16, 4, 1, 1, TileMode::Thick1DThick, 32, truncated, false);
        ok &= Run(37, 19, 64, 1, 1, 1, TileMode::Thin1DThin, 16, truncated, false);
        for (uint32_t bits : {64u, 128u}) {
            ok &= Run(37, 19, 64, 1, 1, 1, TileMode::Thin1DThin, bits, truncated, false);
            ok &= Run(36, 20, 64, 1, 2, 3, TileMode::Thin1DThin, bits, truncated, false);
            ok &= Run(16, 13, 16, 4, 1, 1, TileMode::Thick1DThick, bits, truncated, false);
        }
    }
    ok &= Run(424, 240, 424, 1, 1, 1, TileMode::Thin1DThin, 32, false, bench);
    printf("gnm_cpu_detile_test: %s\n", ok ? "PASS" : "FAIL");
    return ok ? 0 : 1;
}
