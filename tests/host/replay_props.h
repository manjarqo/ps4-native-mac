// Properties of replayed pass outputs (tools/gnm_replay, Options::keep_outputs) for host tests
// that lock rendering fixes: texel decoding of level 0 / slice 0 of the common target formats
// and image statistics.
#pragma once

#include <math.h>
#include <string.h>

#include <algorithm>
#include <string>
#include <vector>

#include "gnm_replay.h"
#include "ps4_gnm_capture.h"

namespace replay_props {
using ps4gnm_capture::GpuTextureId;

inline float Half(uint16_t h) {
    const uint32_t s = h >> 15, e = (h >> 10) & 31, m = h & 1023;
    const float v = e == 0 ? ldexpf((float)m, -24) : e == 31 ? (m ? NAN : INFINITY) : ldexpf((float)(m | 1024), (int)e - 25);
    return s ? -v : v;
}
inline float Small(uint32_t v, int mbits) { // unsigned 11/10-bit float
    const uint32_t e = v >> mbits, m = v & ((1u << mbits) - 1);
    if (e == 0) return ldexpf((float)m, -14 - mbits);
    if (e == 31) return m ? NAN : INFINITY;
    return ldexpf((float)(m | (1u << mbits)), (int)e - 15 - mbits);
}

// RGBA of texel (x, y); false for formats not decoded here.
inline bool Texel(const ps4replay::OutputResult& o, uint32_t x, uint32_t y, float rgba[4]) {
    const GpuTextureId& t = o.tex;
    const uint32_t bpe = ps4gnm_capture::BytesPerTexel(t.mtl_format);
    if (!o.is_texture || !bpe || x >= t.mtl_width || y >= t.mtl_height || o.bytes.size() < (size_t)t.mtl_width * t.mtl_height * bpe)
        return false;
    const uint8_t* p = o.bytes.data() + ((size_t)y * t.mtl_width + x) * bpe;
    rgba[0] = rgba[1] = rgba[2] = 0;
    rgba[3] = 1;
    switch (t.mtl_format) {
    case ps4gnm_capture::kRGBA16Float:
    case ps4gnm_capture::kRG16Float:
    case ps4gnm_capture::kR16Float:
        for (uint32_t k = 0; k < bpe / 2; ++k) {
            uint16_t h;
            memcpy(&h, p + 2 * k, 2);
            rgba[k] = Half(h);
        }
        return true;
    case ps4gnm_capture::kRGBA32Float:
    case ps4gnm_capture::kRG32Float:
    case ps4gnm_capture::kR32Float:
        memcpy(rgba, p, bpe);
        return true;
    case ps4gnm_capture::kRG11B10Float: {
        uint32_t v;
        memcpy(&v, p, 4);
        rgba[0] = Small(v & 2047, 6);
        rgba[1] = Small((v >> 11) & 2047, 6);
        rgba[2] = Small(v >> 22, 5);
        return true;
    }
    case ps4gnm_capture::kRGBA8Unorm:
    case ps4gnm_capture::kRGBA8Unorm_sRGB:
    case ps4gnm_capture::kBGRA8Unorm:
    case ps4gnm_capture::kBGRA8Unorm_sRGB: {
        const bool bgr = t.mtl_format == ps4gnm_capture::kBGRA8Unorm || t.mtl_format == ps4gnm_capture::kBGRA8Unorm_sRGB;
        rgba[0] = p[bgr ? 2 : 0] / 255.0f;
        rgba[1] = p[1] / 255.0f;
        rgba[2] = p[bgr ? 0 : 2] / 255.0f;
        rgba[3] = p[3] / 255.0f;
        return true;
    }
    default:
        return false;
    }
}

struct Stats {
    uint64_t texels = 0, non_finite = 0;
    double mean[3] = {}, mean_luma = 0, luma_stddev = 0;
    float max_luma = 0;
};

// Over the texels of [x0, x0 + w) x [y0, y0 + h) (w = 0: the whole width, h = 0: the whole height).
inline Stats RegionStats(const ps4replay::OutputResult& o, uint32_t x0 = 0, uint32_t y0 = 0, uint32_t w = 0, uint32_t h = 0) {
    Stats s;
    const uint32_t x1 = w ? std::min(o.tex.mtl_width, x0 + w) : o.tex.mtl_width;
    const uint32_t y1 = h ? std::min(o.tex.mtl_height, y0 + h) : o.tex.mtl_height;
    double sum2 = 0;
    for (uint32_t y = y0; y < y1; ++y)
        for (uint32_t x = x0; x < x1; ++x) {
            float c[4];
            if (!Texel(o, x, y, c)) return s;
            s.texels++;
            if (!std::isfinite(c[0]) || !std::isfinite(c[1]) || !std::isfinite(c[2])) {
                s.non_finite++;
                continue;
            }
            const double l = 0.2126 * c[0] + 0.7152 * c[1] + 0.0722 * c[2];
            for (int k = 0; k < 3; ++k) s.mean[k] += c[k];
            s.mean_luma += l;
            sum2 += l * l;
            s.max_luma = std::max(s.max_luma, (float)l);
        }
    const double n = (double)(s.texels - s.non_finite);
    if (n > 0) {
        for (double& m : s.mean) m /= n;
        s.mean_luma /= n;
        s.luma_stddev = sqrt(std::max(0.0, sum2 / n - s.mean_luma * s.mean_luma));
    }
    return s;
}

// The output named `role_suffix` ("_color0", "_storage", "buffer 0x...") of a replay result.
inline const ps4replay::OutputResult* Find(const ps4replay::Result& r, const std::string& role_suffix) {
    for (const ps4replay::OutputResult& o : r.outputs)
        if (o.what.size() >= role_suffix.size() &&
            o.what.compare(o.what.size() - role_suffix.size(), role_suffix.size(), role_suffix) == 0)
            return &o;
    return nullptr;
}

} // namespace replay_props
