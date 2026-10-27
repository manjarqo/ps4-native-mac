// 1D textures, run through the real renderer (ps4draw::Dispatch: translation, texture cache,
// upload, binding, dispatch on Metal). GCN samples a 1D image along x; the same texels are a 2D
// image of height 1 (a 2D array for Color1DArray), which Metal can make with any format and mip
// count, and which the translator's SPIR-V declares for every 1D image. The renderer creates every
// Color1D / Color1DArray T# as such a texture and the translator reads it as one: a sample at u
// reads (u, 0.5), a load at x reads (x, 0), derivatives and offsets get a zero y, the slice moves
// to the third coordinate; image_get_resinfo still answers as for a 1D image. Before, the
// block-compressed and mipmapped ones were bound as null (every read 0), and the others were 1D
// Metal textures bound where the shader declares a 2D texture (wrong texels, or a Metal
// validation abort).
// Hand-assembled compute shaders (user data: s[0:7] the T#, s[8:11] the output V#, s[12:15] a
// point S# with point mip filtering); every result is stored with buffer_store_dwordx4.
//   (a) BC1 Color1D, 8x1, Thin1DThin: block 0 all red, block 1 all blue. image_load_mip of
//       texels 1 and 5 at level 0 gives red and blue; image_sample_lz at u = 0.75 gives blue, and
//       image_sample_lz_o at texel 2 with offset +4 too.
//       The translation binds it as Color2D (view type 9).
//   (b) RGBA8 Color1D, 4 texels, 3 levels (4, 2, 1), Thin1DThin, each level its own colour.
//       image_load_mip at level 2 and image_sample_l at lod 1 give those levels' colours,
//       image_load_mip of texel 3 at level 0 the level-0 colour; image_get_resinfo at lods 0 and 1
//       gives (4, 0, 0, 3) and (2, 0, 0, 3); image_sample_d with du/dx = 0.5, du/dy = 0 (lod 1)
//       the level-1 colour.
//   (c) A first-frame T# of inFAMOUS Second Son (1x1 BC1 Color1D) decodes as a valid 2D texture
//       of 1x1, not counted as one Metal cannot create.
//   (d) RGBA8 Color1D, 8 texels, one level, linear: texels 0-3 red, 4-7 blue. image_load_mip of
//       texels 1 and 5 and image_sample_lz at u = 0.75 give red, blue, blue; it decodes as a 2D
//       texture and translates as Color2D.
//   (e) BC1 Color1DArray, 8 texels, 2 levels, 2 layers, Thin1DThin, read as an array: the block
//       of slice 1 at level 1 green, block 1 of slice 1 at level 0 blue, the rest red.
//       image_load_mip and image_sample_l of slice 1 at level 1 give green; image_load_mip of
//       texel 5 gives blue in slice 1 and red in slice 0 at level 0; image_get_resinfo at lods 0
//       and 1 gives (8, 2, 0, 2) and (4, 2, 0, 2); it translates as Color2DArray (13).
//   (f) The specialization: the shader of (a) translated for its BC1 Color1D T# is not compatible
//       with a BC1 Color2D T# (both views are Color2D, but the address VGPRs differ), and is
//       compatible with its own.
//
// usage: gnm_tex1d_test [gpu-upload]
//   gpu-upload: textures are copied to Metal on the GPU (PS4_GNM_GPU_UPLOAD_MIN_KB=0: the detile
//   compute dispatch and blit) instead of on the CPU.
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>

#include <array>
#include <string>
#include <vector>

#include "gcn_recompiler.h"
#include "ps4_gnm_draw.h"
#include "ps4_gnm_resources.h"

namespace {

int g_fail = 0;
#define CHECK(c, ...)                                                               \
    do {                                                                            \
        if (!(c)) {                                                                 \
            fprintf(stderr, "gnm_tex1d_test: FAIL %s:%d: ", __FILE__, __LINE__);   \
            fprintf(stderr, __VA_ARGS__);                                           \
            fprintf(stderr, "\n");                                                  \
            g_fail++;                                                               \
        }                                                                           \
    } while (0)

constexpr uint64_t kMemSize = 1ull << 32;
constexpr uint64_t kCodeA = 0x01000000, kCodeB = 0x01010000, kCodeD = 0x01020000, kCodeE = 0x01030000,
                   kCodeF = 0x01040000;
constexpr uint64_t kOutA = 0x02000000, kOutB = 0x02010000, kOutD = 0x02020000, kOutE = 0x02030000,
                   kOutF = 0x02040000;
constexpr uint64_t kTexA = 0x03000000, kTexB = 0x03100000, kTexD = 0x03200000, kTexE = 0x03300000;
constexpr uint32_t kSentinel = 0xCDCDCDCDu;
constexpr uint32_t kThin1D = 13; // TileMode Thin1DThin (the inFAMOUS T#'s)
constexpr uint32_t kLinearAligned = 8;

uint8_t* g_mem = nullptr;
GuestContext g_ctx;
bool g_gpu_upload = false; // gpu-upload mode

uint32_t* At(uint64_t addr) { return reinterpret_cast<uint32_t*>(g_mem + addr); }

bool ReadGuest(void*, uint64_t addr, void* dst, uint64_t size) {
    if (addr == 0 || addr + size > kMemSize) return false;
    memcpy(dst, g_mem + addr, size);
    return true;
}

namespace gcn {
uint32_t Vop1(uint32_t op, uint32_t vdst, uint32_t src0) { return 0x7E000000u | vdst << 17 | op << 9 | src0; }
void Mimg(std::vector<uint32_t>& c, uint32_t op, uint32_t vaddr, uint32_t vdata, uint32_t srsrc, uint32_t ssamp,
          bool da = false) {
    c.push_back(0xF0000000u | op << 18 | uint32_t(da) << 14 | 0xFu << 8); // dmask xyzw
    c.push_back(vaddr | vdata << 8 | (srsrc / 4) << 16 | (ssamp / 4) << 21);
}
void Store(std::vector<uint32_t>& c, uint32_t vdata, uint32_t srsrc, uint32_t offset) { // buffer_store_dwordx4
    c.push_back(0xE0000000u | 30u << 18 | offset);
    c.push_back(0x80u << 24 | (srsrc / 4) << 16 | vdata << 8); // soffset 0, no vaddr
}
void MovImm(std::vector<uint32_t>& c, uint32_t vdst, uint32_t bits) {
    if (bits <= 64) {
        c.push_back(Vop1(1, vdst, 0x80 + bits)); // inline integer constant
    } else {
        c.push_back(Vop1(1, vdst, 0xFF));
        c.push_back(bits);
    }
}
uint32_t F(float f) {
    uint32_t u;
    memcpy(&u, &f, 4);
    return u;
}
constexpr uint32_t kWait = 0xBF8C0000u, kEnd = 0xBF810000u;
constexpr uint32_t kImageLoadMip = 1, kImageGetResinfo = 14, kImageSampleD = 34, kImageSampleL = 36,
                   kImageSampleLz = 39, kImageSampleLzO = 55;
std::vector<uint32_t> WithFooter(std::vector<uint32_t> body, uint64_t hash) {
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
} // namespace gcn

// One image instruction: its opcode, its address VGPRs (v0, v1, ...) and the 16-byte output
// slot it is stored to.
struct Read {
    uint32_t op;
    std::vector<uint32_t> addr; // bit patterns of v0, v1, ...
    bool da = false;            // array
};

std::vector<uint32_t> Program(const std::vector<Read>& reads, uint64_t hash) {
    using namespace gcn;
    std::vector<uint32_t> c;
    for (size_t k = 0; k < reads.size(); ++k) {
        for (size_t i = 0; i < reads[k].addr.size(); ++i) MovImm(c, uint32_t(i), reads[k].addr[i]);
        Mimg(c, reads[k].op, 0, 4, 0, 12, reads[k].da);
        c.push_back(kWait);
        Store(c, 4, 8, uint32_t(16 * k));
        c.push_back(kWait);
    }
    c.push_back(kEnd);
    return WithFooter(c, hash);
}

void PutVsharp(uint32_t* v, uint64_t base, uint32_t bytes) {
    v[0] = uint32_t(base);
    v[1] = uint32_t(base >> 32) & 0xFFF; // stride 0: num_records in bytes
    v[2] = bytes;
    v[3] = 4 | (5 << 3) | (6 << 6) | (7 << 9) | (4 << 12) | (4 << 15); // xyzw, uint, 32
}

// Color1D T# (Color1DArray of `layers` when layers > 0): width texels, last_level, dfmt (nfmt
// unorm), tile mode, pitch
void PutTsharp1D(uint32_t* t, uint64_t addr, uint32_t width, uint32_t last_level, uint32_t dfmt,
                 uint32_t tile = kThin1D, uint32_t pitch = 8, uint32_t layers = 0) {
    memset(t, 0, 32);
    t[0] = uint32_t(addr >> 8);
    t[1] = dfmt << 20;
    t[2] = width - 1; // height field 0
    const uint32_t type = layers ? 12u : 8u;
    t[3] = 4 | (5 << 3) | (6 << 6) | (7 << 9) | (last_level << 16) | (tile << 20) | (type << 28); // xyzw
    t[4] = (pitch - 1) << 13 | (layers ? layers - 1 : 0); // depth field: layers - 1
    t[5] = (layers ? layers - 1 : 0) << 13;               // last_array
}

// Point filters, wrap, point mip filter, lods 0..15
void PutSsharp(uint32_t* s) {
    s[0] = 0;
    s[1] = 0xF00u << 12; // max_lod 15.0
    s[2] = 1u << 26;     // mip_filter point
    s[3] = 0;
}

std::vector<uint32_t> Regs(uint64_t code_addr, const uint32_t* tsharp, uint64_t out, uint32_t out_bytes) {
    std::vector<uint32_t> regs(0x10000, 0);
    regs[0x2E07] = 64; // 64 threads
    regs[0x2E08] = regs[0x2E09] = 1;
    regs[0x2E0C] = uint32_t(code_addr >> 8);
    regs[0x2E12] = 1 | (3 << 6); // 8 VGPRs, 32 SGPRs
    regs[0x2E13] = 16 << 1;      // 16 user SGPRs
    uint32_t* ud = &regs[0x2E40];
    memcpy(ud, tsharp, 32);
    PutVsharp(ud + 8, out, out_bytes);
    PutSsharp(ud + 12);
    return regs;
}

gcn_profile g_prof;
gcn_runtime_info g_rt;

// Translates the program as the renderer does (nullptr on failure, reported).
gcn_shader* Compile(const std::vector<uint32_t>& regs, const std::vector<uint32_t>& code) {
    gcn_profile_default_metal(&g_prof);
    gcn_runtime_info_from_regs(regs.data(), regs.size(), GCN_HW_CS, GCN_SW_COMPUTE, &g_prof, &g_rt);
    gcn_compile_desc d{};
    d.hw_stage = GCN_HW_CS;
    d.sw_stage = GCN_SW_COMPUTE;
    uint64_t addr = 0;
    gcn_stage_from_regs(regs.data(), regs.size(), GCN_HW_CS, &addr, d.user_data);
    d.code_addr = addr;
    d.code = code.data();
    d.code_size = uint32_t(code.size() * 4);
    d.runtime = &g_rt;
    d.profile = &g_prof;
    d.read_guest = ReadGuest;
    d.flags = GCN_COMPILE_EMIT_MSL;
    gcn_shader* sh = nullptr;
    char err[512] = {};
    CHECK(gcn_compile(&d, &sh, err, sizeof(err)) == GCN_OK && sh, "does not translate: %s", err);
    return sh;
}

// Translates the program as the renderer does and returns the view type of its one image.
uint32_t TranslatedViewType(const std::vector<uint32_t>& regs, const std::vector<uint32_t>& code) {
    gcn_shader* sh = Compile(regs, code);
    if (!sh) return 0;
    gcn_shader_info info{};
    gcn_shader_get_info(sh, &info);
    CHECK(info.null_image_reads == 0, "%u image reads of the null image", info.null_image_reads);
    uint32_t view_type = 0;
    CHECK(info.num_images == 1, "%u images, want 1", info.num_images);
    if (info.num_images >= 1) {
        gcn_image_binding b{};
        gcn_shader_get_image(sh, 0, &b);
        view_type = b.view_type;
    }
    gcn_shader_destroy(sh);
    return view_type;
}

// Runs the program on the texture and compares the stored slots with want (raw bits).
void Run(const char* name, const std::vector<uint32_t>& code, uint64_t code_addr, const uint32_t* tsharp,
         uint64_t out, const std::vector<std::array<uint32_t, 4>>& want) {
    memcpy(g_mem + code_addr, code.data(), code.size() * 4);
    const uint32_t out_bytes = uint32_t(want.size() * 16);
    for (uint32_t k = 0; k < out_bytes / 4; ++k) At(out)[k] = kSentinel;
    ps4draw::NotifyGuestWrite(code_addr, 0x10000, false, 0);
    ps4draw::NotifyGuestWrite(out, 0x1000, false, 0);
    const std::vector<uint32_t> regs = Regs(code_addr, tsharp, out, out_bytes);
    const uint64_t skipped0 = ps4draw::SkippedCount(), uploads0 = ps4draw::BindUploadCount();
    ps4draw::Dispatch(&g_ctx, regs.data(), 1, 1, 1, 0, "gfx", ps4draw::kQueueGfx);
    ps4draw::Flush(true);
    CHECK(ps4draw::SkippedCount() == skipped0, "%s: the dispatch was skipped", name);
    // the texture is new: copied on the GPU while binding in gpu-upload mode, on the CPU otherwise
    const uint64_t uploads = ps4draw::BindUploadCount() - uploads0;
    CHECK(uploads == (g_gpu_upload ? 1u : 0u), "%s: %llu GPU uploads while binding, want %u", name,
          (unsigned long long)uploads, g_gpu_upload ? 1u : 0u);
    for (size_t k = 0; k < want.size(); ++k) {
        const uint32_t* got = At(out + 16 * k);
        CHECK(memcmp(got, want[k].data(), 16) == 0, "%s: read %zu stored %08x %08x %08x %08x, want %08x %08x %08x %08x",
              name, k, got[0], got[1], got[2], got[3], want[k][0], want[k][1], want[k][2], want[k][3]);
    }
}

std::array<uint32_t, 4> Unorm(uint32_t abgr) {
    std::array<uint32_t, 4> r;
    for (int c = 0; c < 4; ++c) r[c] = gcn::F(float((abgr >> (8 * c)) & 0xFF) / 255.0f);
    return r;
}

// (a) BC1 8x1: block 0 red (color0 0xF800), block 1 blue (0x001F), indices 0 (color0)
void TestBc1() {
    using namespace gcn;
    // Thin1DThin: one 8x8 micro tile of blocks; blocks (0, 0) and (1, 0) are its elements 0 and 1
    memset(At(kTexA), 0, 512);
    At(kTexA)[0] = 0xF800u;
    At(kTexA)[1] = 0;
    At(kTexA)[2] = 0x001Fu;
    At(kTexA)[3] = 0;
    ps4draw::NotifyGuestWrite(kTexA, 0x1000, false, 0);
    uint32_t t[8];
    PutTsharp1D(t, kTexA, 8, 0, 35);
    const std::vector<uint32_t> code = Program({{kImageLoadMip, {1, 0}},   // texel 1, level 0
                                                {kImageLoadMip, {5, 0}},   // texel 5, level 0
                                                {kImageSampleLz, {F(0.75f)}},
                                                {kImageSampleLzO, {4, F(0.3125f)}}}, // texel 2, offset +4
                                               0x7E1D000000000001ull);
    const std::array<uint32_t, 4> red = {F(1), F(0), F(0), F(1)}, blue = {F(0), F(0), F(1), F(1)};
    Run("bc1", code, kCodeA, t, kOutA, {red, blue, blue, blue});
    const uint32_t vt = TranslatedViewType(Regs(kCodeA, t, kOutA, 64), code);
    CHECK(vt == 9, "bc1: the translation binds view type %u, want Color2D (9)", vt);
}

// (b) RGBA8 4 texels, 3 levels: level m filled with kLevel[m]
const uint32_t kLevel[3] = {0xFF0000FFu, 0xFF00FF00u, 0xFFFF0000u}; // ABGR: red, green, blue
void TestMips() {
    using namespace gcn;
    // Thin1DThin, pitch 8: every level is one 8x8 micro tile of 256 bytes (offsets 0, 256, 512)
    for (uint32_t m = 0; m < 3; ++m)
        for (uint32_t k = 0; k < 64; ++k) At(kTexB + 256 * m)[k] = kLevel[m];
    ps4draw::NotifyGuestWrite(kTexB, 0x1000, false, 0);
    uint32_t t[8];
    PutTsharp1D(t, kTexB, 4, 2, 10); // 8_8_8_8
    const std::vector<uint32_t> code = Program({{kImageLoadMip, {0, 2}},           // texel 0, level 2
                                                {kImageSampleL, {F(0.5f), F(1)}},   // u 0.5, lod 1
                                                {kImageLoadMip, {3, 0}},           // texel 3, level 0
                                                {kImageGetResinfo, {0}},           // lod 0
                                                {kImageGetResinfo, {1}},           // lod 1
                                                // du/dx = 0.5 (2 texels of level 0), du/dy = 0: lod 1
                                                {kImageSampleD, {F(0.5f), F(0), F(0.5f)}}},
                                               0x7E1D000000000002ull);
    Run("mips", code, kCodeB, t, kOutB,
        {Unorm(kLevel[2]), Unorm(kLevel[1]), Unorm(kLevel[0]), {4, 0, 0, 3}, {2, 0, 0, 3}, Unorm(kLevel[1])});
    const uint32_t vt = TranslatedViewType(Regs(kCodeB, t, kOutB, 96), code);
    CHECK(vt == 9, "mips: the translation binds view type %u, want Color2D (9)", vt);
}

// (c) decode only
void TestDecode() {
    const uint32_t infamous[8] = {0x1091e093, 0x02300000, 0x00000000, 0x84d00fac, 0x0003e000, 0, 0, 0};
    const uint64_t n0 = ps4gnm::UncreatableImageCount();
    ps4gnm::ImageDesc d;
    const bool ok = ps4gnm::DecodeImage(infamous, 8, &d);
    CHECK(ok && d.valid, "the inFAMOUS 1x1 BC1 Color1D T# decodes as invalid");
    CHECK(d.mtl_texture_type == MTLTextureType2D, "the inFAMOUS T# is Metal texture type %u, want 2D (%u)",
          d.mtl_texture_type, (uint32_t)MTLTextureType2D);
    CHECK(d.width == 1 && d.height == 1, "the inFAMOUS T# is %ux%u, want 1x1", d.width, d.height);
    CHECK(ps4gnm::UncreatableImageCount() == n0, "the inFAMOUS T# counts as a texture Metal cannot create");
}

// (d) a plain 1D texture: RGBA8, 8 texels, one level, linear aligned (pitch 64; texel x at 4x)
void TestPlain() {
    using namespace gcn;
    for (uint32_t x = 0; x < 64; ++x) At(kTexD)[x] = x < 4 ? kLevel[0] : kLevel[2]; // red, blue
    ps4draw::NotifyGuestWrite(kTexD, 0x1000, false, 0);
    uint32_t t[8];
    PutTsharp1D(t, kTexD, 8, 0, 10, kLinearAligned, 64);
    ps4gnm::ImageDesc d;
    const bool ok = ps4gnm::DecodeImage(t, 8, &d);
    CHECK(ok && d.mtl_texture_type == MTLTextureType2D && d.height == 1,
          "a one-level RGBA8 Color1D T# is Metal texture type %u of height %u (valid %d), want 2D (%u) of height 1",
          d.mtl_texture_type, d.height, ok, (uint32_t)MTLTextureType2D);
    const std::vector<uint32_t> code = Program({{kImageLoadMip, {1, 0}},   // texel 1, level 0
                                                {kImageLoadMip, {5, 0}},   // texel 5, level 0
                                                {kImageSampleLz, {F(0.75f)}}},
                                               0x7E1D000000000004ull);
    Run("plain", code, kCodeD, t, kOutD, {Unorm(kLevel[0]), Unorm(kLevel[2]), Unorm(kLevel[2])});
    const uint32_t vt = TranslatedViewType(Regs(kCodeD, t, kOutD, 48), code);
    CHECK(vt == 9, "plain: the translation binds view type %u, want Color2D (9)", vt);
}

// (e) BC1 Color1DArray: 8 texels (2 blocks), 2 levels, 2 layers, Thin1DThin, pitch 8. Level 0:
// one 8x8 micro tile of blocks (512 bytes) per slice; level 1 at 1024, 512 bytes per slice.
void TestArray() {
    using namespace gcn;
    for (uint32_t b = 0; b < 0x800 / 8; ++b) { // every block red
        At(kTexE)[2 * b] = 0xF800u;
        At(kTexE)[2 * b + 1] = 0;
    }
    At(kTexE + 512 + 8)[0] = 0x001Fu;  // slice 1, level 0, block 1: blue
    At(kTexE + 1024 + 512)[0] = 0x07E0u; // slice 1, level 1, block 0: green
    ps4draw::NotifyGuestWrite(kTexE, 0x1000, false, 0);
    uint32_t t[8];
    PutTsharp1D(t, kTexE, 8, 1, 35, kThin1D, 8, 2);
    const std::vector<uint32_t> code = Program({{kImageLoadMip, {1, 1, 1}, true},         // texel 1, slice 1, level 1
                                                {kImageSampleL, {F(0.5f), F(1), F(1)}, true}, // u 0.5, slice 1, lod 1
                                                {kImageLoadMip, {5, 1, 0}, true},         // texel 5, slice 1, level 0
                                                {kImageLoadMip, {5, 0, 0}, true},         // texel 5, slice 0, level 0
                                                {kImageGetResinfo, {0}, true},            // lod 0
                                                {kImageGetResinfo, {1}, true}},           // lod 1
                                               0x7E1D000000000005ull);
    const std::array<uint32_t, 4> red = {F(1), F(0), F(0), F(1)}, green = {F(0), F(1), F(0), F(1)},
                                  blue = {F(0), F(0), F(1), F(1)};
    Run("array", code, kCodeE, t, kOutE, {green, green, blue, red, {8, 2, 0, 2}, {4, 2, 0, 2}});
    const uint32_t vt = TranslatedViewType(Regs(kCodeE, t, kOutE, 96), code);
    CHECK(vt == 13, "array: the translation binds view type %u, want Color2DArray (13)", vt);
}

// (f) the shader of (a) specialized for its BC1 Color1D T# does not serve a BC1 Color2D T#
void TestSpecialization() {
    using namespace gcn;
    uint32_t t1d[8], t2d[8];
    PutTsharp1D(t1d, kTexA, 8, 0, 35);
    memcpy(t2d, t1d, 32);
    t2d[2] = 7 | (3u << 14);                        // 8 x 4
    t2d[3] = (t2d[3] & 0x0FFFFFFFu) | (9u << 28);   // Color2D
    const std::vector<uint32_t> code = Program({{kImageLoadMip, {5, 0}}}, 0x7E1D000000000006ull);
    const std::vector<uint32_t> regs1 = Regs(kCodeF, t1d, kOutF, 16), regs2 = Regs(kCodeF, t2d, kOutF, 16);
    gcn_shader* sh = Compile(regs1, code);
    if (!sh) return;
    uint32_t ud1[16], ud2[16];
    uint64_t a = 0;
    gcn_stage_from_regs(regs1.data(), regs1.size(), GCN_HW_CS, &a, ud1);
    gcn_stage_from_regs(regs2.data(), regs2.size(), GCN_HW_CS, &a, ud2);
    CHECK(gcn_shader_is_compatible(sh, ud1, &g_rt, ReadGuest, nullptr),
          "specialization: the shader is not compatible with its own Color1D T#");
    CHECK(!gcn_shader_is_compatible(sh, ud2, &g_rt, ReadGuest, nullptr),
          "specialization: the shader translated for a BC1 Color1D T# is compatible with a BC1 Color2D T#");
    gcn_shader_destroy(sh);
}

} // namespace

int main(int argc, char** argv) {
    @autoreleasepool {
        const std::string mode = argc > 1 ? argv[1] : "";
        if (!mode.empty() && mode != "gpu-upload") {
            fprintf(stderr, "usage: gnm_tex1d_test [gpu-upload]\n");
            return 2;
        }
        g_gpu_upload = mode == "gpu-upload";
        if (g_gpu_upload) setenv("PS4_GNM_GPU_UPLOAD_MIN_KB", "0", 1);
        setenv("PS4_GNM_SYNC_ENCODE", "1", 1);
        setenv("PS4_GNM_SYNC_COMPILE", "1", 1);
        setenv("PS4_GNM_NO_SHADER_CACHE", "1", 1);
        setenv("PS4_GNM_NO_PSO_ARCHIVE", "1", 1);
        setenv("PS4_GNM_NO_LIB_STORE", "1", 1);
        setenv("PS4_GNM_MEM_LOG", "0", 1);
        void* m = mmap(nullptr, kMemSize, PROT_READ | PROT_WRITE, MAP_ANON | MAP_PRIVATE | MAP_NORESERVE, -1, 0);
        if (m == MAP_FAILED) {
            fprintf(stderr, "gnm_tex1d_test: FAIL no guest memory\n");
            return 1;
        }
        g_mem = (uint8_t*)m;
        memset(&g_ctx, 0, sizeof(g_ctx));
        g_ctx.mem_base = g_mem;
        g_ctx.mem_size = kMemSize;
        if (!ps4draw::Init(&g_ctx)) {
            fprintf(stderr, "gnm_tex1d_test: FAIL the renderer did not start\n");
            return 1;
        }
        TestBc1();
        TestMips();
        TestDecode();
        TestPlain();
        TestArray();
        TestSpecialization();
        const char* tag = mode.empty() ? "" : " gpu-upload";
        if (g_fail) {
            fprintf(stderr, "gnm_tex1d_test%s: %d failure(s)\n", tag, g_fail);
            return 1;
        }
        printf("gnm_tex1d_test%s: PASS\n", tag);
        return 0;
    }
}
