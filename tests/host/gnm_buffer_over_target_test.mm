// Buffer stores over a GPU-owned color surface (TextureCache::NoteBufferWrite / TakeGuestNewer,
// ps4_gnm_draw.mm RefreshGuestNewer), replayed through the real renderer (tools/gnm_replay) with
// passes written by ps4gnm_capture::Writer. The passes of one case run in order in one process:
// renderer state (the texture cache, the target's texture) persists between ReplayPass calls,
// guest memory is reloaded for each pass. Every case has its own surface (its own address).
//
// The target: a GPU-owned RGBA8 unorm 64x8 surface (linear aligned), adopted with contents
// A = (10, 20, 30, 40) in every texel. Its identity is the one the renderer builds for it: from
// the T# (DecodeImage, ComputeSurfaceLayout, PackSurface: GetStorageTexture), or for case D from
// the color target registers (DecodeColorTarget: GetColorTarget).
//   W: a compute shader stores out[i] = i through a V# at the surface covering `size` bytes
//      (full: the surface's 2048 bytes; partial: 256);
//   S: a compute shader stores (1.0, 0.5, 0.5, 0.5) to row 0 of the surface (image_store);
//   D: a draw into the surface as color target 0 writes (1, 0, 0, 1) to its left half;
//   L: a compute shader loads row 0 of the surface (image_load) and stores the red channels as
//      floats; guest memory at the surface holds B (texel x = (x, 2x, 3x, 255)) for this pass.
// Cases, red channel of texel x in L's output:
//   A (W full, L): x / 255, the GPU copy brought guest memory into the texture (the old code: A);
//   B (W partial, L): 10 / 255, partial cover never replaces GPU-only contents;
//   C (W full, S, L): 1.0, the refresh runs before the storage write, which survives (a refresh
//      only at sample time would give x / 255);
//   D (W full, D, L): 1.0 left, x / 255 right, the refresh runs before the render pass, so the
//      draw composes on guest memory and survives;
//   E (W full in a dispatch whose binding fails, L): 10 / 255, work that never ran marks nothing
//      (the dispatch asks for 64 KiB of LDS per workgroup, more than Metal's 32 KiB, so it is spilled
//      to a buffer, and 8193 workgroups need more of it than the renderer gives: it is skipped
//      after its written V# was bound);
//   F (a CP DMA done on the CPU over the whole surface, L): x / 255, as for a buffer store;
//   G (W as a guest memory dispatch, L): x / 255. GW also loads through a V# it reads from a
//      table at run time, so it runs on the guest memory path (probe, gate, pass): its bound
//      store marks the surface once the pass ran, as W's does;
//   H (GW, S, GW again on the fast path, L): x / 255. The second GW has a prediction (the first
//      GW, and G's, ran the same shader) and PS4_GNM_GUEST_MEMORY_FAST=1 is set, so it is encoded
//      without a CPU wait: its store marks the surface once its result is known, before L samples
//      it (S's write in between consumed the first GW's mark: without the second mark L reads 1.0).
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>

#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>

#include <functional>
#include <string>
#include <vector>

#include "gcn_recompiler.h"
#include "gnm_replay.h"
#include "ps4_gnm_capture.h"
#include "ps4_gnm_draw.h"
#include "ps4_gnm_resources.h"

using namespace ps4gnm_capture;

namespace {

int g_fail = 0;
#define CHECK(c, ...)                                                                        \
    do {                                                                                     \
        if (!(c)) {                                                                          \
            fprintf(stderr, "gnm_buffer_over_target_test: FAIL %s:%d: ", __FILE__, __LINE__); \
            fprintf(stderr, __VA_ARGS__);                                                    \
            fprintf(stderr, "\n");                                                           \
            g_fail++;                                                                        \
        }                                                                                    \
    } while (0)

constexpr uint64_t kMemSize = 1ull << 32;
constexpr uint64_t kCodeW = 0x100000, kCodeS = 0x110000, kCodeL = 0x120000, kCodeE = 0x130000;
constexpr uint64_t kVs = 0x140000, kPs = 0x150000, kVb = 0x160000, kOut = 0x200000;
constexpr uint64_t kCodeGW = 0x170000, kTableGW = 0x180000, kSrcGW = 0x190000;
constexpr uint32_t kW = 64, kH = 8, kTexBytes = kW * kH * 4;
constexpr uint32_t kEnd = 0xBF810000;

// T# of a surface at `addr`: FMT_8_8_8_8 unorm, 64 x 8, dst_sel xyzw, tiling index 8 (linear
// aligned), 2D, pitch 64
std::vector<uint32_t> Tsharp(uint64_t addr) {
    return {uint32_t(addr >> 8), (10u << 20), 63 | (7u << 14),
            4 | (5 << 3) | (6 << 6) | (7 << 9) | (8u << 20) | (9u << 28), (63u << 13), 0, 0, 0};
}

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

// v2 = v0 << 2; v1 = v0; buffer_store_dword v1, v2, s[4:7] offen
const std::vector<uint32_t> kProgW = WithFooter({0x34040082, 0x7E020300, 0xE0701000, 0x80010102, kEnd},
                                                0x5CA1AB1E000003A1ull);
// v4 = v0; v5 = 0; v6 = 1.0; v7..v9 = 0.5; image_store v[6:9], v[4:5], s[8:15] dmask:0xf unorm
const std::vector<uint32_t> kProgS = WithFooter({0x7E080300, 0x7E0A0280, 0x7E0C02F2, 0x7E0E02F0, 0x7E1002F0,
                                                 0x7E1202F0, 0xF0201F00, 0x00020604, kEnd},
                                                0x5CA1AB1E000003A2ull);
// v2 = v0 << 2; v4 = v0; v5 = 0; image_load v[6:9], v[4:5], s[8:15] dmask:0xf unorm;
// buffer_store_dword v6, v2, s[4:7] offen (the texel goes to v[6:9]: loading it into v[0:3]
// would overwrite the store offset in v2)
const std::vector<uint32_t> kProgL = WithFooter({0x34040082, 0x7E080300, 0x7E0A0280, 0xF0001F00, 0x00020604,
                                                 0xE0701000, 0x80010602, kEnd},
                                                0x5CA1AB1E000003A3ull);
// W with LDS: v2 = v0 << 2; v1 = v0; ds_write_b32 v2, v1; buffer_store_dword v1, v2, s[4:7] offen
const std::vector<uint32_t> kProgE = WithFooter({0x34040082, 0x7E020300, 0xD8340000, 0x00000102, 0xE0701000,
                                                 0x80010102, kEnd},
                                                0x5CA1AB1E000003A4ull);
// GW: s20 = s16 + 0 (workgroup id x: 0); s_load_dwordx4 s[24:27], s[0:1], s20 (a V# from the
// table at s[0:1], at an offset the shader computes, so it is not resolved when the resource
// table is flattened: a guest memory dispatch); v2 = v0 << 2; buffer_load_dword v3, v2, s[24:27]
// offen; buffer_store_dword v3, v2, s[4:7] offen
const std::vector<uint32_t> kProgGW = WithFooter({0x80148010, 0xC08C0014, 0xBF8C0000, 0x34040082, 0xE0301000,
                                                  0x80060302, 0xBF8C0000, 0xE0701000, 0x80010302, kEnd},
                                                 0x5CA1AB1E000003A7ull);
// VS: buffer_load_format_xyzw v[1:4], v0, s[0:3] idxen; exp param0, pos0 done (gnm_replay_test)
const std::vector<uint32_t> kProgVs = WithFooter({0xE00C2000, 0x80000100, 0xBF8C0F70, 0xF800020F, 0x04030201,
                                                  0xF80008CF, 0x04030201, kEnd},
                                                 0x5CA1AB1E000003A5ull);
// PS: v0 = 1.0; v1 = v2 = 0; v3 = 1.0; exp mrt0 v0, v1, v2, v3 done vm
const std::vector<uint32_t> kProgPs = WithFooter({0x7E0002F2, 0x7E020280, 0x7E040280, 0x7E0602F2, 0xF800180F,
                                                  0x03020100, kEnd},
                                                 0x5CA1AB1E000003A6ull);

// The identity GetStorageTexture gives the surface of Tsharp(addr).
GpuTextureId StorageId(uint64_t addr) {
    ps4gnm::ImageDesc img;
    const std::vector<uint32_t> t = Tsharp(addr);
    ps4gnm::DecodeImage(t.data(), 8, &img);
    GpuTextureId g;
    g.kind = 1;
    g.address = img.address;
    g.mtl_format = g.entry_format = img.pixel.mtl_format;
    g.tex_type = g.mtl_type = (uint32_t)MTLTextureType2D;
    g.width = g.mtl_width = img.width;
    g.height = g.mtl_height = img.height;
    g.dfmt = (uint32_t)img.dfmt;
    g.nfmt = (uint32_t)img.nfmt;
    g.usage = (uint32_t)(MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite |
                         MTLTextureUsagePixelFormatView);
    g.storage_mode = (uint32_t)MTLStorageModeShared;
    ps4gnm::SurfaceDesc sd = img.ToSurfaceDesc();
    sd.levels = 1;
    ps4gnm::SurfaceLayout l;
    ps4gnm::ComputeSurfaceLayout(sd, &l);
    g.size = l.total_size;
    ps4gnm::PackSurface(sd, l, &g.surface);
    return g;
}

// Registers of D: the surface at `addr` as color target 0 (8_8_8_8 unorm, linear aligned), a
// triangle with vertices (0, -3), (0, 3), (-4, 0) covering the left half, the constant PS.
std::vector<uint32_t> DrawRegs(uint64_t addr) {
    std::vector<uint32_t> regs(kNumRegs, 0);
    ps4draw::SetRegDefaults(regs.data());
    regs[0x2C48] = uint32_t(kVs >> 8); // SPI_SHADER_PGM_LO_VS
    regs[0x2C4A] = 1 | (1 << 6);       // RSRC1_VS: 8 VGPRs, 16 SGPRs
    regs[0x2C4B] = 4 << 1;             // RSRC2_VS: 4 user SGPRs
    uint32_t* vud = &regs[0x2C4C];     // V# of the vertices: float4, stride 16, 3 records
    vud[0] = uint32_t(kVb);
    vud[1] = 16u << 16;
    vud[2] = 3;
    vud[3] = 4 | (5 << 3) | (6 << 6) | (7 << 9) | (7 << 12) | (14 << 15);
    regs[0x2C08] = uint32_t(kPs >> 8); // SPI_SHADER_PGM_LO_PS
    regs[0x2C0A] = 1 | (1 << 6);
    regs[0x2C0B] = 0;
    regs[0xA1B3] = regs[0xA1B4] = 2; // SPI_PS_INPUT_ENA / ADDR: PERSP_CENTER
    regs[0xA1B6] = 0;
    regs[0xA1B1] = 0;
    regs[0xA1C3] = 4; // SPI_SHADER_POS_FORMAT: POS0 4 components
    regs[0xA1C5] = 9; // SPI_SHADER_COL_FORMAT: MRT0 32_ABGR
    regs[0xA08E] = regs[0xA08F] = 0xF;
    regs[0xA202] = (1 << 4) | (0xCC << 16); // CB_COLOR_CONTROL: normal, copy
    regs[0xA206] = 0x43F;                  // PA_CL_VTE_CNTL
    const float vp[6] = {kW / 2.0f, kW / 2.0f, kH / 2.0f, kH / 2.0f, 0.5f, 0.5f};
    memcpy(&regs[0xA10F], vp, sizeof(vp));
    regs[0xA205] = 0; // no culling
    regs[0xC242] = 4; // triangle list
    uint32_t* cb = &regs[0xA318]; // CB_COLOR0_*
    cb[0] = uint32_t(addr >> 8);
    cb[1] = kW / 8 - 1;          // PITCH: 64
    cb[2] = kW * kH / 64 - 1;    // SLICE: 64 x 8
    cb[4] = (10u << 2);          // INFO: 8_8_8_8, unorm
    cb[5] = 8;                   // ATTRIB: linear aligned
    return regs;
}

// The identity GetColorTarget gives color target 0 of DrawRegs(addr).
GpuTextureId ColorId(uint64_t addr) {
    const std::vector<uint32_t> regs = DrawRegs(addr);
    ps4gnm::ColorTarget ct;
    ps4gnm::DecodeColorTarget(regs.data(), 0, &ct);
    GpuTextureId g;
    g.kind = 1;
    g.address = ct.address;
    g.mtl_format = g.entry_format = ct.mtl_format;
    g.tex_type = g.mtl_type = (uint32_t)MTLTextureType2D;
    g.width = g.mtl_width = kW;
    g.height = g.mtl_height = kH;
    g.dfmt = (uint32_t)ct.dfmt;
    g.nfmt = (uint32_t)ct.nfmt;
    for (uint32_t k = 0; k < 4; ++k) g.cb_swizzle[k] = (uint8_t)ct.swizzle[k];
    g.usage = (uint32_t)(MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite |
                         MTLTextureUsagePixelFormatView);
    g.storage_mode = (uint32_t)MTLStorageModeShared;
    ps4gnm::SurfaceDesc sd = ct.ToSurfaceDesc();
    sd.width = kW;
    sd.height = kH;
    ps4gnm::SurfaceLayout l;
    ct.GetLayout(&l);
    g.size = l.total_size;
    ps4gnm::PackSurface(sd, l, &g.surface);
    return g;
}

std::vector<uint32_t> DispatchRegs(uint64_t code, uint64_t vsharp_base, uint32_t vsharp_bytes, uint64_t tex) {
    std::vector<uint32_t> regs(kNumRegs, 0);
    regs[0x2E07] = kW; // COMPUTE_NUM_THREAD_X: one thread per texel of row 0
    regs[0x2E08] = regs[0x2E09] = 1;
    regs[0x2E0C] = uint32_t(code >> 8); // COMPUTE_PGM_LO
    regs[0x2E12] = 2;                   // RSRC1: 12 VGPRs
    regs[0x2E13] = 16 << 1;             // RSRC2: 16 user SGPRs
    uint32_t* ud = &regs[0x2E40];       // COMPUTE_USER_DATA_0..
    ud[4] = uint32_t(vsharp_base);      // V#: base, stride 0, vsharp_bytes, 32-bit uint
    ud[5] = uint32_t(vsharp_base >> 32);
    ud[6] = vsharp_bytes;
    ud[7] = 4 | (5 << 3) | (6 << 6) | (7 << 9) | (4 << 12) | (4 << 15);
    const std::vector<uint32_t> t = Tsharp(tex);
    memcpy(&ud[8], t.data(), 32);
    return regs;
}

struct Frame {
    uint8_t* mem = nullptr;
    Writer* w = nullptr;
    uint32_t next = 0;
};

PassRec NewPass(Frame& f, const std::vector<uint32_t>& regs, uint64_t code, const std::vector<uint32_t>& prog) {
    memcpy(f.mem + code, prog.data(), prog.size() * 4);
    PassRec p;
    p.index = f.next++;
    p.replayable = true;
    p.type = "dispatch";
    p.queue = p.name = "gfx";
    p.regs_file = f.w->SaveRegs(regs.data(), &p.regs_hash);
    p.dim[0] = p.dim[1] = p.dim[2] = 1;
    p.inputs.push_back(f.w->Snapshot(f.mem, code, kPage));
    return p;
}

enum class Mode { Sample, Storage, Draw, BindFails, CpuDma, GuestMem, GuestMemFast };

// GW over the surface at `tex` storing `bytes`: its table (user data 0-1) holds a V# of 2048
// bytes at kSrcGW.
PassRec GuestMemoryPass(Frame& f, uint64_t tex, uint32_t bytes) {
    std::vector<uint32_t> regs = DispatchRegs(kCodeGW, tex, bytes, tex);
    regs[0x2E12] = 2 | (3 << 6);       // 12 VGPRs, 32 SGPRs
    regs[0x2E13] = 16 << 1 | 1 << 7;   // 16 user SGPRs, s16 = workgroup id x
    uint32_t* ud = &regs[0x2E40];
    ud[0] = uint32_t(kTableGW);
    ud[1] = uint32_t(kTableGW >> 32);
    const uint32_t vsharp[4] = {uint32_t(kSrcGW), 0, kTexBytes, ud[7]};
    memcpy(f.mem + kTableGW, vsharp, sizeof(vsharp));
    PassRec p = NewPass(f, regs, kCodeGW, kProgGW);
    p.inputs.push_back(f.w->Snapshot(f.mem, kTableGW, kPage));
    p.inputs.push_back(f.w->Snapshot(f.mem, kSrcGW, kPage));
    BufferRec b;
    b.stage = "cs";
    b.addr = tex;
    b.size = bytes;
    b.written = true;
    p.buffers.push_back(b);
    p.inputs.push_back(f.w->Snapshot(f.mem, tex, kPage));
    return p;
}

// Writes <root>/frame_1 for the surface at `tex`: the first pass (W, its LDS variant for
// BindFails, W with a 0-byte V# for CpuDma, or GW for GuestMem and GuestMemFast) adopts the
// surface with contents A; then S or D (S and GW again for GuestMemFast); then L.
std::string WriteCase(const std::string& root, uint64_t tex, uint32_t w_bytes, Mode mode) {
    Frame f;
    f.mem = (uint8_t*)mmap(nullptr, kMemSize, PROT_READ | PROT_WRITE, MAP_ANON | MAP_PRIVATE, -1, 0);
    const std::string dir = root + "/frame_1";
    Writer w(dir, 1, kMemSize, false, gcn_shader_cache_id());
    f.w = &w;
    std::string err;
    CHECK(w.Begin(&err), "%s", err.c_str());
    const GpuTextureId tid = mode == Mode::Draw ? ColorId(tex) : StorageId(tex);
    const bool gm = mode == Mode::GuestMem || mode == Mode::GuestMemFast;
    {
        const bool lds = mode == Mode::BindFails;
        const uint32_t bytes = mode == Mode::CpuDma ? 0 : w_bytes;
        std::vector<uint32_t> regs = DispatchRegs(lds ? kCodeE : kCodeW, tex, bytes, tex);
        // E: COMPUTE_PGM_RSRC2.LDS_SIZE 128 (x 128 dwords = 64 KiB per workgroup): LDS spilled to a
        // buffer of 64 KiB x 8193 workgroups, over the renderer's 256 MiB: the bind fails
        if (lds) regs[0x2E13] |= 128u << 15;
        PassRec p = gm ? GuestMemoryPass(f, tex, bytes) : NewPass(f, regs, lds ? kCodeE : kCodeW, lds ? kProgE : kProgW);
        if (lds) p.dim[0] = 8193;
        BufferRec b;
        b.stage = "cs";
        b.addr = tex;
        b.size = bytes;
        b.written = true;
        if (bytes && !gm) p.buffers.push_back(b);
        std::vector<uint8_t> a(RawSize(tid));
        for (size_t i = 0; i + 3 < a.size(); i += 4) {
            a[i] = 10;
            a[i + 1] = 20;
            a[i + 2] = 30;
            a[i + 3] = 40;
        }
        TextureRec t;
        t.role = mode == Mode::Draw ? "t0_color0" : "t0_storage";
        t.written = false;
        t.id = tid;
        t.pre_file = w.SaveTexture(p.index, t.role, "pre", a, &t.pre_hash);
        p.textures.push_back(t);
        p.inputs.push_back(w.Snapshot(f.mem, tex, kPage));
        w.AddPass(std::move(p));
    }
    if (mode == Mode::Storage || mode == Mode::GuestMemFast) {
        PassRec p = NewPass(f, DispatchRegs(kCodeS, kOut, 256, tex), kCodeS, kProgS);
        w.AddPass(std::move(p));
    }
    if (mode == Mode::GuestMemFast) w.AddPass(GuestMemoryPass(f, tex, w_bytes));
    // guest memory at the surface from here on holds B (what the full-cover store left there)
    for (uint32_t y = 0; y < kH; ++y)
        for (uint32_t x = 0; x < kW; ++x) {
            uint8_t* px = f.mem + tex + (y * kW + x) * 4;
            px[0] = (uint8_t)x;
            px[1] = (uint8_t)(2 * x);
            px[2] = (uint8_t)(3 * x);
            px[3] = 255;
        }
    if (mode == Mode::Draw) {
        memcpy(f.mem + kVs, kProgVs.data(), kProgVs.size() * 4);
        memcpy(f.mem + kPs, kProgPs.data(), kProgPs.size() * 4);
        const float verts[12] = {0, -3, 0.5f, 1, 0, 3, 0.5f, 1, -4, 0, 0.5f, 1};
        memcpy(f.mem + kVb, verts, sizeof(verts));
        const std::vector<uint32_t> regs = DrawRegs(tex);
        PassRec p;
        p.index = f.next++;
        p.replayable = true;
        p.type = "draw";
        p.queue = "gfx";
        p.name = "DRAW_INDEX_AUTO";
        p.count = 3;
        p.cb_extent[0] = kW | kH << 16;
        p.regs_file = w.SaveRegs(regs.data(), &p.regs_hash);
        p.inputs.push_back(w.Snapshot(f.mem, kVs, kPage));
        p.inputs.push_back(w.Snapshot(f.mem, kPs, kPage));
        p.inputs.push_back(w.Snapshot(f.mem, kVb, kPage));
        p.inputs.push_back(w.Snapshot(f.mem, tex, kPage));
        w.AddPass(std::move(p));
    }
    // L
    {
        PassRec p = NewPass(f, DispatchRegs(kCodeL, kOut, kW * 4, tex), kCodeL, kProgL);
        BufferRec b;
        b.stage = "cs";
        b.addr = kOut;
        b.size = kW * 4;
        b.written = true;
        p.buffers.push_back(b);
        p.inputs.push_back(w.Snapshot(f.mem, tex, kPage));
        p.inputs.push_back(w.Snapshot(f.mem, kOut, kPage));
        w.AddPass(std::move(p));
    }
    CHECK(w.Finish(&err), "%s", err.c_str());
    munmap(f.mem, kMemSize);
    return dir;
}

// Runs the passes of a case in order (pass `skipped`, if any, must be skipped by the renderer;
// `between` runs after the first pass); the red channel of texel x of row 0 as L read it.
bool RunCase(const std::string& dir, uint32_t passes, std::vector<float>* red, int skipped = -1,
             const std::function<void()>& between = nullptr) {
    ps4replay::Options o;
    o.frame_dir = dir;
    o.keep_outputs = true;
    for (uint32_t i = 0; i < passes; ++i) {
        o.pass = i;
        const ps4replay::Result r = ps4replay::ReplayPass(o);
        if ((int)i == skipped) {
            if (r.ran || r.error.find("skipped") == std::string::npos) {
                fprintf(stderr, "  pass %u was not skipped by the renderer (%s)\n", i, r.error.c_str());
                return false;
            }
        } else if (!r.ran) {
            fprintf(stderr, "  pass %u not replayed: %s\n", i, r.error.c_str());
            return false;
        }
        if (i == 0 && between) between();
        if (i + 1 == passes) {
            for (const ps4replay::OutputResult& out : r.outputs)
                if (!out.is_texture && out.addr == kOut && out.bytes.size() == kW * 4) {
                    red->resize(kW);
                    memcpy(red->data(), out.bytes.data(), kW * 4);
                    return true;
                }
            fprintf(stderr, "  L's output was not returned\n");
            return false;
        }
    }
    return false;
}

void CheckRed(const char* name, const std::vector<float>& red, const std::function<float(uint32_t)>& want) {
    uint32_t bad = 0, first = 0;
    for (uint32_t x = 0; x < kW; ++x)
        if (fabsf(red[x] - want(x)) > 0.5f / 255.0f) {
            if (!bad) first = x;
            bad++;
        }
    CHECK(!bad, "case %s: %u of %u texels wrong; texel %u red %f (= %.1f / 255, bits 0x%08x), want %f", name, bad, kW,
          first, red[first], red[first] * 255.0f, ((const uint32_t*)red.data())[first], want(first));
}

} // namespace

int main() {
    // case H: guest memory dispatches with a prediction take the fast path (opt-in)
    setenv("PS4_GNM_GUEST_MEMORY_FAST", "1", 1);
    @autoreleasepool {
        char tmpl[] = "/tmp/gnm_buffer_over_target_test.XXXXXX";
        const char* root = mkdtemp(tmpl);
        if (!root) return 1;
        const std::string r = root;
        const auto ramp = [](uint32_t x) { return x / 255.0f; };
        const auto old = [](uint32_t) { return 10 / 255.0f; };
        std::vector<float> red;
        if (RunCase(WriteCase(r + "/a", 0x300000, kTexBytes, Mode::Sample), 2, &red))
            CheckRed("A (full cover, then sample)", red, ramp);
        else
            CHECK(false, "case A did not run");
        if (RunCase(WriteCase(r + "/b", 0x340000, 256, Mode::Sample), 2, &red))
            CheckRed("B (partial cover, then sample)", red, old);
        else
            CHECK(false, "case B did not run");
        if (RunCase(WriteCase(r + "/c", 0x380000, kTexBytes, Mode::Storage), 3, &red))
            CheckRed("C (full cover, storage write, then sample)", red, [](uint32_t) { return 1.0f; });
        else
            CHECK(false, "case C did not run");
        if (RunCase(WriteCase(r + "/d", 0x3C0000, kTexBytes, Mode::Draw), 3, &red))
            CheckRed("D (full cover, draw into the left half, then sample)", red,
                     [](uint32_t x) { return x < kW / 2 ? 1.0f : x / 255.0f; });
        else
            CHECK(false, "case D did not run");
        if (RunCase(WriteCase(r + "/e", 0x400000, kTexBytes, Mode::BindFails), 2, &red, 0))
            CheckRed("E (full cover by a dispatch that is skipped, then sample)", red, old);
        else
            CHECK(false, "case E did not run");
        // F: between W (nothing stored) and L, a CP DMA on the CPU writes the whole surface
        if (RunCase(WriteCase(r + "/f", 0x440000, kTexBytes, Mode::CpuDma), 2, &red, -1,
                    [] { ps4draw::NotifyGuestWrite(0x440000, kTexBytes, false, 0, true); }))
            CheckRed("F (CP DMA on the CPU over the whole surface, then sample)", red, ramp);
        else
            CHECK(false, "case F did not run");
        // G: the first dispatch of GW's shader takes the guest memory path's sync path
        ps4draw::GuestMemoryStats g0 = ps4draw::GetGuestMemoryStats();
        if (RunCase(WriteCase(r + "/g", 0x480000, kTexBytes, Mode::GuestMem), 2, &red))
            CheckRed("G (full cover by a guest memory dispatch, then sample)", red, ramp);
        else
            CHECK(false, "case G did not run");
        ps4draw::GuestMemoryStats g1 = ps4draw::GetGuestMemoryStats();
        CHECK(g1.sync > g0.sync, "case G: GW did not run on the guest memory path");
        // H: GW has a prediction now, the second GW is encoded on the fast path
        if (RunCase(WriteCase(r + "/h", 0x4C0000, kTexBytes, Mode::GuestMemFast), 4, &red))
            CheckRed("H (full cover by a fast guest memory dispatch after a storage write, then sample)", red, ramp);
        else
            CHECK(false, "case H did not run");
        ps4draw::GuestMemoryStats g2 = ps4draw::GetGuestMemoryStats();
        CHECK(g2.fast > g1.fast, "case H: no GW took the fast path (fast %llu, sync %llu)",
              (unsigned long long)(g2.fast - g1.fast), (unsigned long long)(g2.sync - g1.sync));
        const std::string cmd = std::string("rm -rf '") + root + "'";
        if (system(cmd.c_str()) != 0) g_fail++;
        if (g_fail) {
            fprintf(stderr, "gnm_buffer_over_target_test: %d failure(s)\n", g_fail);
            return 1;
        }
        printf("gnm_buffer_over_target_test: PASS\n");
        return 0;
    }
}
