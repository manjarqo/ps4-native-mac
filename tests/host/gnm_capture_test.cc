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
    auto z = CoalescePages({{0, 64}, {0x8000, 4}}, 1ull << 30);
    CHECK(z.size() == 1 && z[0].first == 0x8000, "a range at address 0 is dropped (%zu ranges)", z.size());
}

// Guest memory with a PROT_NONE page in the middle: the snapshot ranges skip it.
static void TestReadable() {
    const size_t pg = (size_t)getpagesize();
    uint8_t* m = (uint8_t*)mmap(nullptr, 4 * pg, PROT_READ | PROT_WRITE, MAP_ANON | MAP_PRIVATE, -1, 0);
    CHECK(m != MAP_FAILED, "mmap");
    if (m == MAP_FAILED) return;
    CHECK(mprotect(m + pg, pg, PROT_NONE) == 0, "mprotect");
    auto r = ClampReadable(m, {{0, 4 * pg}});
    CHECK(r.size() == 2 && r[0].first == 0 && r[0].second == pg && r[1].first == 2 * pg && r[1].second == 2 * pg,
          "PROT_NONE page cut out: %zu ranges", r.size());
    auto t = ClampReadable(m, {{pg + 8, 16}});
    CHECK(t.empty(), "a range inside the guard page is dropped (%zu)", t.size());
    uint64_t sum = 0;
    for (auto& [a, n] : r) sum += Fnv64(m + a, n) & 1; // reading every kept byte does not fault
    (void)sum;
    munmap(m, 4 * pg);
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
    RawBudget budget;
    TextureRec pre;
    pre.role = "t0_color0";
    pre.id = t;
    w.SavePre(0, &pre, raw, &budget);
    CHECK(pre.pre_file.empty() && budget.used == 0, "a failed pre write uses no budget (%llu)", (unsigned long long)budget.used);
    w.SavePost(0, true, &pre, raw, &budget, 0);
    CHECK(pre.post_file.empty() && budget.used == 0, "a failed post write uses no budget (%llu)", (unsigned long long)budget.used);
    CHECK(w.Failures() == 7, "write failures counted: %llu", (unsigned long long)w.Failures());
    for (const char* sub : {"/regs", "/blobs", "/png", "/tex"}) chmod((dir + sub).c_str(), 0755);
    const std::string rf = w.SaveRegs(regs.data(), &h);
    CHECK(!rf.empty(), "a failed register file is not cached");
    const BlobRef b = w.Snapshot(mem.data(), 0x4000, kPage);
    std::vector<uint8_t> back;
    CHECK(!b.file.empty() && ReadFile(dir + "/" + b.file, &back) && back.size() == kPage, "a failed blob is not cached");
    CHECK(w.Failures() == 7, "no new failures: %llu", (unsigned long long)w.Failures());
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

// A depth target cleared by the load action is written even with depth writes and stencil off.
static void TestDepthWritten() {
    CHECK(!DepthTargetWritten(false, false, false, false), "a depth test only reads");
    CHECK(DepthTargetWritten(true, false, false, false), "depth writes");
    CHECK(DepthTargetWritten(false, true, false, false), "stencil test");
    CHECK(DepthTargetWritten(false, false, true, false), "HTILE / register depth clear with writes off");
    CHECK(DepthTargetWritten(false, false, false, true), "stencil clear");
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
    CHECK(unlink((dir + "/" + a.file).c_str()) == 0, "remove the first blob");
    const BlobRef b = w.Snapshot(mem.data(), 0x10000, kPage); // same content: the stored file is reused
    std::vector<uint8_t> gone;
    CHECK(!ReadFile(dir + "/" + a.file, &gone), "an already stored blob is not written again");
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
    // a T# table entry (gcn_image_binding.table / table_entry)
    ImageRec te;
    te.stage = "cs";
    te.index = 5;
    te.table = 1;
    te.entry = 3;
    p.images.push_back(te);
    p.inputs.push_back(a);
    p.outputs.push_back(w.Snapshot(mem.data(), 0x14000, kPage));
    p.meta_cleared.push_back(0x9900);
    p.meta_cleared_slices.push_back(2);
    p.unstable = {"input 0x1000+0x4000", "texture t3_sampled"};
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
        CHECK(q.images.size() == 2 && q.images[0].textures.size() == 1 && q.images[0].textures[0] == 0, "image -> texture");
        CHECK(q.images.size() == 2 && q.images[0].table == -1 && q.images[0].entry == -1 && q.images[1].table == 1 &&
                  q.images[1].entry == 3 && q.images[1].index == 5,
              "T# table entry marks");
        CHECK(q.inputs.size() == 1 && q.inputs[0].file == a.file && q.inputs[0].hash == a.hash, "inputs");
        CHECK(q.meta_cleared.size() == 1 && q.meta_cleared[0] == 0x9900, "meta");
        CHECK(q.meta_cleared_slices.size() == 1 && q.meta_cleared_slices[0] == 2, "meta slice");
        CHECK(q.unstable.size() == 2 && q.unstable[0] == "input 0x1000+0x4000" && q.unstable[1] == "texture t3_sampled", "unstable");
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

// Shader-address selection (ShaderSelection): keys count occurrences per stage pair and frame; the
// producers of a selected pass are the latest earlier writers of each byte it reads, so a writer
// whose bytes a later pass overwrote entirely is not one, two writers of different halves both are,
// and passes after the reader, writers of bytes nobody selected reads, and readers of other
// shaders' outputs are not.
static void TestShaderSelection() {
    using R = ShaderSelection::Range;
    ShaderSelection sel;
    std::string err;
    CHECK(!sel.Parse("", &err) && sel.Empty(), "empty list accepted");
    CHECK(!sel.Parse("0x10,zz", &err) && sel.Empty() && err.find("zz") != std::string::npos, "bad entry: %s",
          err.c_str());
    CHECK(!sel.Parse("0x10,,0x20", &err), "empty entry accepted");
    CHECK(!sel.Parse("0", &err), "address 0 accepted");
    CHECK(!sel.Parse("-1", &err) && !sel.Parse(" 0x10", &err) && !sel.Parse("pgm:-5", &err) && sel.Empty(),
          "a negative or space-led entry accepted");
    CHECK(sel.Parse("0x200081af00,4096,0x1000", &err) && sel.Shaders().size() == 2 &&
              sel.Shaders()[0] == 0x1000 && sel.Shaders()[1] == 0x200081af00,
          "hex and decimal, duplicates merged");

    const uint64_t VS = 0x1300007500, PS = 0x200081af00, CS = 0x5000, VS2 = 0x6000, PS2 = 0x7000;
    // learning frame:
    //  0 cs        writes T [0x10000, +0x1000)            (overwritten by 1: not a producer)
    //  1 vs2/ps2   writes T [0x10000, +0x1000)            producer (T)
    //  2 cs        writes U [0x20000, +0x800)             producer (first half of U)
    //  3 cs        writes U [0x20800, +0x800)             producer (second half of U)
    //  4 vs2/ps2   writes V [0x30000, +0x100)             nobody selected reads V: not a producer
    //  5 vs/ps     reads T, U, its target W; writes W     the selected pass (W never written before)
    //  6 vs2/ps2   reads W, writes T                      after the reader: not a producer
    //  7 vs/ps     reads T                                second occurrence: its producer is 6
    sel.BeginFrame();
    SelectKey k[8];
    k[0] = sel.Next(CS, 0);
    k[1] = sel.Next(VS2, PS2);
    k[2] = sel.Next(CS, 0);
    k[3] = sel.Next(CS, 0);
    k[4] = sel.Next(VS2, PS2);
    k[5] = sel.Next(VS, PS);
    k[6] = sel.Next(VS2, PS2);
    k[7] = sel.Next(VS, PS);
    CHECK(k[3].occurrence == 2 && k[4].occurrence == 1 && k[7].occurrence == 1 && k[5].occurrence == 0,
          "occurrences %u %u %u", k[3].occurrence, k[4].occurrence, k[7].occurrence);
    CHECK(sel.UsesShader(k[5]) && sel.UsesShader(k[7]) && !sel.UsesShader(k[1]) && !sel.UsesShader(k[0]),
          "UsesShader");
    sel.Learn(k[0], {{0x40000, 0x10}}, {{0x10000, 0x1000}});
    sel.Learn(k[1], {}, {{0x10000, 0x800}, {0x10800, 0x800}});
    sel.Learn(k[2], {}, {{0x20000, 0x800}});
    sel.Learn(k[3], {}, {{0x20800, 0x800}});
    sel.Learn(k[4], {}, {{0x30000, 0x100}});
    sel.Learn(k[5], {{0x10100, 0x10}, {0x20000, 0x1000}, {0x50000, 0x100}}, {{0x50000, 0x100}});
    sel.Learn(k[6], {{0x50000, 0x100}}, {{0x10000, 0x1000}});
    sel.Learn(k[7], {{0x10000, 4}}, std::vector<R>{});
    sel.FinishLearning();
    CHECK(sel.NumReaders() == 2 && sel.NumProducers() == 4, "%zu readers, %zu producers", sel.NumReaders(),
          sel.NumProducers());
    // captured frame: the same passes match by key
    sel.BeginFrame();
    bool want[8] = {false, true, true, true, false, true, true, true};
    SelectKey n[8];
    n[0] = sel.Next(CS, 0);
    n[1] = sel.Next(VS2, PS2);
    n[2] = sel.Next(CS, 0);
    n[3] = sel.Next(CS, 0);
    n[4] = sel.Next(VS2, PS2);
    n[5] = sel.Next(VS, PS);
    n[6] = sel.Next(VS2, PS2);
    n[7] = sel.Next(VS, PS);
    for (int i = 0; i < 8; ++i) {
        CHECK(n[i] == k[i], "pass %d: key differs between frames", i);
        CHECK(sel.Selects(n[i]) == want[i], "pass %d: selected %d", i, (int)sel.Selects(n[i]));
    }
    CHECK(!sel.Selects(sel.Next(CS, 0)), "a pass the learning frame did not have");

    // program hashes: a shader the game loads at another address in another run is still found
    ShaderSelection byp;
    CHECK(!byp.Parse("pgm:", &err) && err.find("program hash") != std::string::npos, "empty pgm entry: %s",
          err.c_str());
    CHECK(!byp.Parse("pgm:0x4c71zz", &err) && byp.Empty(), "bad pgm entry accepted");
    CHECK(byp.Parse("pgm:0x4c7184e1f5d449ec,0x1000", &err) && byp.Programs().size() == 1 &&
              byp.Programs()[0] == 0x4c7184e1f5d449ecull && byp.Shaders().size() == 1 && byp.Shaders()[0] == 0x1000,
          "pgm and address entries");
    byp.BeginFrame();
    const SelectKey w = byp.Next(0x130010c200, 0, 0x4c7184e1a73a4797ull, 0);   // zeroes the field
    const SelectKey f = byp.Next(0x130010cf00, 0, 0x4c7184e1f5d449ecull, 0);   // the selected program
    const SelectKey d = byp.Next(0x2000300000, 0x2000400000, 0x11, 0x22);      // reads it
    CHECK(!byp.UsesShader(w) && byp.UsesShader(f) && !byp.UsesShader(d), "UsesShader by program hash");
    byp.Learn(w, {}, {{0x1900400000, 0x100}});
    byp.Learn(f, {{0x1900400000, 0x100}}, {{0x1900400000, 0x100}});
    byp.Learn(d, {{0x1900400000, 0x100}}, std::vector<R>{});
    byp.FinishLearning();
    byp.BeginFrame();
    const SelectKey w2 = byp.Next(0x130010c200, 0, 0x4c7184e1a73a4797ull, 0);
    const SelectKey f2 = byp.Next(0x130010cf00, 0, 0x4c7184e1f5d449ecull, 0);
    CHECK(byp.NumReaders() == 1 && byp.Selects(w2) && byp.Selects(f2), "program-hash reader and its producer");
    CHECK(byp.Known(f2) && !byp.Known(byp.Next(0x130010cf00, 0, 0x4c7184e1f5d449ecull, 0)),
          "a selected pass the learning frame did not have is not known");
}

// Writes declared by a texture or a bound V# range may cover only part of it (a draw covers some
// pixels, a compute shader stores some fields): such a writer is a producer of the bytes it may
// have written but hides no earlier writer. Only exact writes (the probed ranges of a guest
// memory dispatch) hide earlier writers, also when they cover just a part of an earlier write.
static void TestPartialWriters() {
    using R = ShaderSelection::Range;
    ShaderSelection sel;
    std::string err;
    CHECK(sel.Parse("0x9000", &err), "parse");
    const uint64_t VB = 0x1902b00000, N = 0x1000;
    sel.BeginFrame();
    // the ocean vertex buffer: a dispatch zeroes it, the foam dispatch stores fields 13-16 of each
    // vertex; both bind the whole buffer; the selected draw reads it
    const SelectKey zero = sel.Next(0x5000, 0), foam = sel.Next(0x6000, 0);
    // exact writes: a whole range, then its middle third, then a part outside the middle only
    const SelectKey all = sel.Next(0x7000, 0), mid = sel.Next(0x7100, 0), part = sel.Next(0x7200, 0);
    const SelectKey after = sel.Next(0x7300, 0); // exactly overwrites the first third
    const SelectKey draw = sel.Next(0x9000, 0);
    const uint64_t X = 0x40000000;
    sel.Learn(zero, {}, {}, {{VB, N}});
    sel.Learn(foam, {}, {}, {{VB, N}});
    sel.Learn(part, {}, {{X + 0x100, 0x100}});
    sel.Learn(all, {}, {{X, 0x3000}});
    sel.Learn(mid, {}, {{X + 0x1000, 0x1000}});
    sel.Learn(after, {}, {{X, 0x1000}});
    sel.Learn(draw, {{VB, N}, {X, 0x3000}}, std::vector<R>{});
    sel.FinishLearning();
    CHECK(sel.Selects(zero), "an earlier writer of the whole buffer hidden by a later partial writer");
    CHECK(sel.Selects(foam), "the later partial writer is not a producer");
    CHECK(sel.Selects(after) && sel.Selects(mid) && sel.Selects(all),
          "exact writers of the first third, the middle third and the last third: %d %d %d", sel.Selects(after),
          sel.Selects(mid), sel.Selects(all));
    CHECK(!sel.Selects(part), "a writer whose bytes later exact writes replaced entirely is a producer");
    CHECK(sel.NumProducers() == 5, "%zu producers", sel.NumProducers());
}

// ChangedInputs: guest memory rewritten after a snapshot is reported; a range the pass wrote
// itself and a range recorded without contents are not.
void TestChangedInputs() {
    std::vector<uint8_t> mem(0x40000, 0x11);
    std::string root = "/tmp/gnm_capture_changed.XXXXXX";
    CHECK(mkdtemp(&root[0]) != nullptr, "mkdtemp");
    Writer ww(root + "/f", 1, mem.size(), false, "id");
    std::string err;
    CHECK(ww.Begin(&err), "%s", err.c_str());
    std::vector<BlobRef> in = {ww.Snapshot(mem.data(), 0x0, kPage), ww.Snapshot(mem.data(), 0x4000, kPage),
                               ww.Snapshot(mem.data(), 0x8000, kPage)};
    BlobRef big;
    big.addr = 0xC000;
    big.size = kPage; // recorded, not stored (no file)
    in.push_back(big);
    std::vector<BlobRef> out = {BlobRef{0x8000, 16, 0, ""}};
    CHECK(ChangedInputs(mem.data(), in, out).empty(), "unchanged memory reported");
    mem[0x4010] = 0x22; // a guest thread rewrote a byte of the second range
    mem[0x8010] = 0x22; // the pass wrote the third range
    mem[0xC010] = 0x22; // the fourth has no contents to compare
    const std::vector<std::string> ch = ChangedInputs(mem.data(), in, out);
    CHECK(ch.size() == 1 && ch[0] == "input 0x4000+0x4000", "changed inputs: %zu (%s)", ch.size(),
          ch.empty() ? "" : ch[0].c_str());
    const std::string cmd = "rm -rf '" + root + "'";
    CHECK(system(cmd.c_str()) == 0, "cleanup");
}

int main() {
    TestCoalesce();
    TestReadable();
    TestRawSize();
    TestViews();
    TestDepthWritten();
    TestWriterRoundTrip();
    TestShaderSelection();
    TestPartialWriters();
    TestChangedInputs();
    if (g_fail) {
        fprintf(stderr, "gnm_capture_test: %d failure(s)\n", g_fail);
        return 1;
    }
    printf("gnm_capture_test: PASS\n");
    return 0;
}
