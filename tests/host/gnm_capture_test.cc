// Capture writer and loader (pkg/runtime/modules/libSceGnmDriver/ps4_gnm_capture.cc) on a
// synthetic dispatch: snapshots are deduplicated by (address, size, content), the register file
// and the manifest round-trip exactly, raw texture sizes follow RawLayout, and the PNG views
// carry the documented per-format mapping (NaN magenta, float x/(1+x), depth min..max).
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>

#include <cmath>
#include <string>
#include <vector>

#include "ps4_gnm_capture.h"

using namespace ps4gnm_capture;

static int g_fail = 0;
#define CHECK(c, ...)                                                       \
    do {                                                                    \
        if (!(c)) {                                                         \
            fprintf(stderr, "gnm_capture_test: FAIL %s:%d: ", __FILE__, __LINE__); \
            fprintf(stderr, __VA_ARGS__);                                   \
            fprintf(stderr, "\n");                                          \
            g_fail++;                                                       \
        }                                                                   \
    } while (0)

static void TestCoalesce() {
    auto r = CoalescePages({{0x10000, 4}, {0x13ffc, 8}, {0x40000, 1}, {0x3c000, 0x4000}}, 1ull << 30);
    CHECK(r.size() == 2, "%zu ranges", r.size());
    if (r.size() == 2) {
        CHECK(r[0].first == 0x10000 && r[0].second == 0x8000, "first 0x%llx+0x%llx", (unsigned long long)r[0].first,
              (unsigned long long)r[0].second);
        CHECK(r[1].first == 0x3c000 && r[1].second == 0x8000, "second 0x%llx+0x%llx", (unsigned long long)r[1].first,
              (unsigned long long)r[1].second);
    }
    CHECK(CoalescePages({{0x7ffff000, 0x2000}}, 0x80000000)[0].second == 0x4000, "clamped to mem_size");
}

static void TestRawSize() {
    GpuTextureId t;
    t.mtl_format = kRGBA16Float;
    t.mtl_type = 2; // MTLTextureType2D
    t.mtl_width = 16;
    t.mtl_height = 8;
    t.mtl_levels = 2;
    CHECK(RawSize(t) == (16 * 8 + 8 * 4) * 8, "2D mips: %llu", (unsigned long long)RawSize(t));
    t.mtl_format = kDepth32Float_Stencil8;
    t.mtl_levels = 1;
    CHECK(RawSize(t) == 16 * 8 * 5, "depth+stencil planes: %llu", (unsigned long long)RawSize(t));
    t.mtl_format = kR32Float;
    t.mtl_type = 5; // cube
    CHECK(RawSize(t) == 16 * 8 * 4 * 6, "cube: %llu", (unsigned long long)RawSize(t));
}

static void TestViews() {
    GpuTextureId t;
    t.mtl_type = 2;
    t.mtl_width = 4;
    t.mtl_height = 1;
    std::vector<uint8_t> rgb;
    std::string mode;
    // RGBA16F: 1.0 -> 128 (x/(1+x)), NaN -> magenta, 0 -> 0, +Inf -> 255
    t.mtl_format = kRGBA16Float;
    const uint16_t h[16] = {0x3C00, 0x3C00, 0x3C00, 0x3C00, 0x7E00, 0, 0, 0, 0, 0, 0, 0, 0x7C00, 0x7C00, 0x7C00, 0};
    CHECK(ToViewRgb8(t, (const uint8_t*)h, sizeof(h), &rgb, &mode), "rgba16f view");
    CHECK(rgb[0] == 128 && rgb[3] == 255 && rgb[4] == 0 && rgb[5] == 255 && rgb[6] == 0 && rgb[9] == 255,
          "rgba16f: %u | %u %u %u | %u (%s)", rgb[0], rgb[3], rgb[4], rgb[5], rgb[9], mode.c_str());
    CHECK(mode == "float x/(1+x)", "mode %s", mode.c_str());
    // BGRA8: channels swapped back to RGB
    t.mtl_format = kBGRA8Unorm;
    const uint8_t b[16] = {1, 2, 3, 255, 10, 20, 30, 255, 0, 0, 0, 0, 0, 0, 0, 0};
    CHECK(ToViewRgb8(t, b, sizeof(b), &rgb, &mode) && rgb[0] == 3 && rgb[1] == 2 && rgb[2] == 1 && rgb[3] == 30,
          "bgra8 view %u %u %u %u", rgb[0], rgb[1], rgb[2], rgb[3]);
    // Depth32Float: min..max over the image
    t.mtl_format = kDepth32Float;
    const float d[4] = {0.25f, 0.5f, 0.75f, 0.5f};
    CHECK(ToViewRgb8(t, (const uint8_t*)d, sizeof(d), &rgb, &mode) && rgb[0] == 0 && rgb[6] == 255 && rgb[3] == 128,
          "depth view %u %u %u", rgb[0], rgb[3], rgb[6]);
    // too small a buffer and multisampled textures are refused
    t.mtl_format = kRGBA8Unorm;
    CHECK(!ToViewRgb8(t, b, 8, &rgb, &mode), "short raw accepted");
    t.mtl_samples = 4;
    CHECK(!ToViewRgb8(t, b, sizeof(b), &rgb, &mode) && mode == "unsupported: multisampled", "msaa: %s", mode.c_str());
}

static void TestThumbnail(const std::string& dir) {
    // 10x3 RGBA8, max width 4 -> every 3rd texel: 4x1, texels 0, 3, 6, 9 of row 0
    Writer w(dir, 1, 1 << 20, false, "");
    std::string err, mode;
    CHECK(w.Begin(&err), "Begin: %s", err.c_str());
    GpuTextureId t;
    t.mtl_format = kRGBA8Unorm;
    t.mtl_type = 2;
    t.mtl_width = 10;
    t.mtl_height = 3;
    std::vector<uint8_t> raw(10 * 3 * 4);
    for (size_t i = 0; i < 30; ++i) raw[i * 4] = (uint8_t)(i * 8);
    const std::string f = w.SavePng(3, "t0_color0", t, raw, 4, &mode);
    CHECK(f == "png/p00003_t0_color0.png" && mode == "unorm, 1/3 scale", "thumbnail %s (%s)", f.c_str(), mode.c_str());
    std::vector<uint8_t> png;
    CHECK(ReadFile(dir + "/" + f, &png) && png.size() > 24, "thumbnail file");
    if (png.size() > 24) {
        const uint32_t pw = (png[16] << 24) | (png[17] << 16) | (png[18] << 8) | png[19];
        const uint32_t ph = (png[20] << 24) | (png[21] << 16) | (png[22] << 8) | png[23];
        CHECK(pw == 4 && ph == 1, "thumbnail size %ux%u", pw, ph);
    }
}

// A file the writer cannot write is reported (Failures), and not remembered as written or as
// "not stored": once the directory is writable again the same content is stored.
static void TestWriteFailures(const std::string& dir) {
    Writer w(dir, 9, 1 << 20, false, "");
    std::string err, mode;
    CHECK(w.Begin(&err), "Begin: %s", err.c_str());
    std::vector<uint8_t> mem(1 << 20, 0x5A);
    std::vector<uint32_t> regs(kNumRegs, 0);
    regs[0x2E07] = 7;
    GpuTextureId t;
    t.mtl_format = kRGBA8Unorm;
    t.mtl_type = 2;
    t.mtl_width = 4;
    t.mtl_height = 1;
    const std::vector<uint8_t> raw(16, 0x80);
    for (const char* sub : {"/regs", "/blobs", "/png", "/tex"}) chmod((dir + sub).c_str(), 0555);
    uint64_t h = 0;
    CHECK(w.SaveRegs(regs.data(), &h).empty(), "register file written into a read-only directory");
    CHECK(w.Snapshot(mem.data(), 0x4000, kPage).file.empty(), "blob written into a read-only directory");
    CHECK(w.SavePng(0, "t0_color0", t, raw, 0, &mode).empty(), "png written into a read-only directory");
    CHECK(w.SaveTexture(0, "t0_color0", "post", raw, &h).empty(), "raw written into a read-only directory");
    CHECK(w.Failures() == 4, "write failures counted: %llu", (unsigned long long)w.Failures());
    for (const char* sub : {"/regs", "/blobs", "/png", "/tex"}) chmod((dir + sub).c_str(), 0755);
    const std::string rf = w.SaveRegs(regs.data(), &h);
    CHECK(!rf.empty(), "a failed register file is not cached");
    const BlobRef b = w.Snapshot(mem.data(), 0x4000, kPage);
    std::vector<uint8_t> back;
    CHECK(!b.file.empty() && ReadFile(dir + "/" + b.file, &back) && back.size() == kPage, "a failed blob is not cached");
    CHECK(w.Failures() == 4, "no new failures: %llu", (unsigned long long)w.Failures());
}

// The raw budget gates the raw files only: a written texture over the budget still gets its view
// PNG and says why it has no post file; replayable passes get full-size views, the others thumbnails.
static void TestBudget(const std::string& dir) {
    Writer w(dir, 2, 1 << 20, false, "");
    std::string err;
    CHECK(w.Begin(&err), "Begin: %s", err.c_str());
    GpuTextureId t;
    t.mtl_format = kRGBA8Unorm;
    t.mtl_type = 2;
    t.mtl_width = 8;
    t.mtl_height = 2;
    const std::vector<uint8_t> raw(RawSize(t), 0x40); // 64 bytes
    RawBudget b;
    b.limit = 100;
    TextureRec a;
    a.role = "t0_color0";
    a.id = t;
    CHECK(b.Fits(64), "64 bytes fit a 100-byte budget");
    w.SavePre(5, &a, raw, &b);
    CHECK(!a.pre_file.empty() && a.readback.empty() && b.used == 64, "pre stored within the budget (%llu used)",
          (unsigned long long)b.used);
    w.SavePost(5, true, &a, raw, &b, 4);
    CHECK(a.post_file.empty() && a.readback == kReadbackBudget, "post over the budget: no file, reason '%s'",
          a.readback.c_str());
    CHECK(b.used == 64, "a refused post does not use the budget (%llu)", (unsigned long long)b.used);
    CHECK(a.png_file == "png/p00005_t0_color0.png" && a.png_mode == "unorm", "view PNG despite the budget: %s (%s)",
          a.png_file.c_str(), a.png_mode.c_str());
    TextureRec c;
    c.role = "t1_color0";
    c.id = t;
    w.SavePre(6, &c, raw, &b);
    CHECK(c.pre_file.empty() && c.readback == kReadbackBudget, "pre over the budget: reason '%s'", c.readback.c_str());
    TextureRec n; // a pass that is not replayable: no raw file, a thumbnail at most 4 wide
    n.role = "t0_color0";
    n.id = t;
    w.SavePost(7, false, &n, raw, &b, 4);
    CHECK(n.post_file.empty() && n.readback.empty() && n.png_mode == "unorm, 1/2 scale",
          "not replayable: thumbnail only (%s, '%s')", n.png_mode.c_str(), n.readback.c_str());
    RawBudget big;
    TextureRec d;
    d.role = "t0_color0";
    d.id = t;
    w.SavePost(8, true, &d, raw, &big, 4);
    CHECK(!d.post_file.empty() && d.post_hash == Fnv64(raw.data(), raw.size()) && d.png_mode == "unorm",
          "replayable within the budget: post file and a full-size view");
}

static std::string TempDir() {
    char tmpl[] = "/tmp/gnm_capture_test.XXXXXX";
    const char* d = mkdtemp(tmpl);
    return d ? d : "";
}

static void TestWriterRoundTrip() {
    const std::string root = TempDir();
    CHECK(!root.empty(), "mkdtemp");
    const std::string dir = root + "/frame_7";
    // a small guest memory: code at 0x10000, a buffer at 0x14000
    const uint64_t mem_size = 1ull << 20;
    std::vector<uint8_t> mem(mem_size, 0);
    for (int i = 0; i < 64; ++i) mem[0x10000 + i] = (uint8_t)i;
    Writer w(dir, 7, mem_size, false, "gcn-test-id");
    std::string err;
    CHECK(w.Begin(&err), "Begin: %s", err.c_str());
    const BlobRef a = w.Snapshot(mem.data(), 0x10000, kPage);
    const BlobRef b = w.Snapshot(mem.data(), 0x10000, kPage); // same content: one file
    CHECK(!a.file.empty() && a.file == b.file && a.hash == b.hash, "dedup: %s vs %s", a.file.c_str(), b.file.c_str());
    mem[0x10001] = 0xEE;
    const BlobRef c = w.Snapshot(mem.data(), 0x10000, kPage); // changed content: new file
    CHECK(c.file != a.file && c.hash != a.hash, "changed content shares %s", c.file.c_str());
    std::vector<uint8_t> back;
    CHECK(ReadFile(dir + "/" + c.file, &back) && back.size() == kPage && back[1] == 0xEE, "blob content");

    std::vector<uint32_t> regs(kNumRegs, 0);
    regs[0x2E07] = 64;
    regs[0x2E0C] = 0x100;
    regs[0xFFFF] = 0xdeadbeef;
    uint64_t rh = 0, rh2 = 0;
    const std::string rf = w.SaveRegs(regs.data(), &rh);
    CHECK(w.SaveRegs(regs.data(), &rh2) == rf && rh == rh2, "register file dedup");

    PassRec p;
    p.index = 0;
    p.replayable = true;
    p.type = "dispatch";
    p.queue = "gfx";
    p.name = "gfx";
    p.regs_file = rf;
    p.regs_hash = rh;
    p.dim[0] = 2;
    p.dim[1] = p.dim[2] = 1;
    StageRec s;
    s.stage = "cs";
    s.code_addr = 0x10000;
    s.code_size = 40;
    s.pgm_hash = 0x5CA1AB1E00000001ull;
    s.user_data[4] = 0x14000;
    p.stages.push_back(s);
    BufferRec br;
    br.stage = "cs";
    br.addr = 0x14000;
    br.size = 256;
    br.written = true;
    br.vsharp[0] = 0x14000;
    p.buffers.push_back(br);
    TextureRec tr;
    tr.role = "storage";
    tr.written = true;
    tr.id.kind = 1;
    tr.id.address = 0x123456789a00ull;
    tr.id.mtl_format = kRGBA16Float;
    tr.id.entry_format = kRGBA16Float + 1;
    tr.id.mtl_type = 2;
    tr.id.mtl_width = 4;
    tr.id.mtl_height = 1;
    tr.id.surface = {1, 2, 3, 0xFFFFFFFFu};
    tr.id.swizzle[0] = 3;
    std::vector<uint8_t> raw(RawSize(tr.id), 0);
    tr.post_file = w.SaveTexture(0, tr.role, "post", raw, &tr.post_hash);
    tr.png_file = w.SavePng(0, tr.role, tr.id, raw, 0, &tr.png_mode);
    CHECK(!tr.png_file.empty() && tr.png_mode == "float x/(1+x)", "png %s (%s)", tr.png_file.c_str(), tr.png_mode.c_str());
    p.textures.push_back(tr);
    ImageRec ir;
    ir.stage = "cs";
    ir.storage = true;
    ir.addr = tr.id.address;
    ir.textures = {0};
    p.images.push_back(ir);
    p.inputs.push_back(a);
    p.outputs.push_back(w.Snapshot(mem.data(), 0x14000, kPage));
    p.meta_cleared.push_back(0x9900);
    p.state.viewport[2] = 1920.5;
    p.state.blend_enable[3] = true;
    p.name = "name with \"quotes\"";
    w.AddPass(std::move(p));
    CHECK(w.Finish(&err), "Finish: %s", err.c_str());

    FrameRec f;
    CHECK(LoadFrame(dir, &f, &err), "LoadFrame: %s", err.c_str());
    CHECK(f.frame == 7 && f.mem_size == mem_size && f.gcn_cache_id == "gcn-test-id" && f.passes.size() == 1,
          "frame header");
    if (f.passes.size() == 1) {
        const PassRec& q = f.passes[0];
        CHECK(q.replayable && q.type == "dispatch" && q.dim[0] == 2 && q.name == "name with \"quotes\"", "pass header");
        CHECK(q.stages.size() == 1 && q.stages[0].pgm_hash == 0x5CA1AB1E00000001ull && q.stages[0].user_data[4] == 0x14000,
              "stage");
        CHECK(q.buffers.size() == 1 && q.buffers[0].written && q.buffers[0].size == 256, "buffer");
        CHECK(q.textures.size() == 1 && q.textures[0].id.address == 0x123456789a00ull &&
                  q.textures[0].id.surface.size() == 4 && q.textures[0].id.surface[3] == 0xFFFFFFFFu &&
                  q.textures[0].id.swizzle[0] == 3 && q.textures[0].id.entry_format == kRGBA16Float + 1 && q.textures[0].post_hash == tr.post_hash,
              "texture id");
        CHECK(q.images.size() == 1 && q.images[0].textures.size() == 1 && q.images[0].textures[0] == 0, "image -> texture");
        CHECK(q.inputs.size() == 1 && q.inputs[0].file == a.file && q.inputs[0].hash == a.hash, "inputs");
        CHECK(q.meta_cleared.size() == 1 && q.meta_cleared[0] == 0x9900, "meta");
        CHECK(q.state.viewport[2] == 1920.5 && q.state.blend_enable[3], "state");
        std::vector<uint32_t> r2;
        CHECK(LoadRegs(dir, q.regs_file, &r2, &err) && r2 == regs, "register file round trip: %s", err.c_str());
    }
    std::vector<uint8_t> png;
    CHECK(ReadFile(dir + "/png/p00000_storage.png", &png) && png.size() > 8 && png[1] == 'P', "png on disk");
    FrameRec bad;
    CHECK(!ParseManifest("{\"version\": 99}", &bad, &err), "foreign version accepted");
    CHECK(!ParseManifest("{\"version\": 1, \"passes\": [", &bad, &err), "truncated manifest accepted");
    TestThumbnail(root + "/frame_1");
    TestWriteFailures(root + "/frame_9");
    TestBudget(root + "/frame_2");
    const std::string cmd = "rm -rf '" + root + "'";
    CHECK(system(cmd.c_str()) == 0, "cleanup");
}

int main() {
    TestCoalesce();
    TestRawSize();
    TestViews();
    TestWriterRoundTrip();
    if (g_fail) {
        fprintf(stderr, "gnm_capture_test: %d failure(s)\n", g_fail);
        return 1;
    }
    printf("gnm_capture_test: PASS\n");
    return 0;
}
