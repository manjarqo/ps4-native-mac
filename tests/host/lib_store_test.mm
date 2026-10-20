// Host test of the shader library store (ps4_gnm_library_store.mm) on the real Metal device.
//   unit                 key, file name, file format and configuration name (no Metal)
//   write  <dir> <nonce> compiles a vertex/fragment pair and a kernel (all entry points "main0", as
//                        SPIRV-Cross emits them), builds their pipelines and stores the libraries
//   read   <dir> <nonce> a new process: loads the three functions from the store (the API takes
//                        no source, so nothing is compiled), checks their types, draws and
//                        dispatches with them and compares the results with source-compiled ones
//   corrupt <dir> <nonce> one damaged entry is refused and deleted; the others still load
//   config <dir> <nonce> other compile options: the old configuration's entries are deleted
//   budget <dir> <nonce> over the budget at Open, the least recently used entries go first
#import <Metal/Metal.h>
#include "ps4_gnm_library_store.h"

#include <cmath>
#include <cstddef>
#include <cstdio>
#include <cstring>
#include <dirent.h>
#include <string>
#include <sys/stat.h>
#include <sys/time.h>
#include <unistd.h>
#include <vector>

namespace ls = ps4gnm_lib_store;

static int Fail(const char* what) {
    printf("lib_store_test: FAIL (%s)\n", what);
    return 1;
}
#define CHECK(c, what) \
    do {               \
        if (!(c)) return Fail(what); \
    } while (0)

static const char* kTag = "fastMath=0;preserveInvariance=1";

// Sources shaped like the renderer's: separate libraries, every entry point named main0. The
// nonce keeps caches of earlier runs from satisfying this one.
static std::string VertexSource(const std::string& nonce) {
    return "#include <metal_stdlib>\nusing namespace metal;\nconstant float kNonce = " + nonce + ".0;\n"
           "struct main0_out { float4 m_col [[user(locn0)]]; float4 gl_Position [[position]]; };\n"
           "vertex main0_out main0(uint vid [[vertex_id]]) {\n"
           "  main0_out o; float2 p = float2(float((vid << 1) & 2), float(vid & 2));\n"
           "  o.gl_Position = float4(p * 2.0 - 1.0, 0.0, 1.0);\n"
           "  o.m_col = float4(0.25, 0.5, fract(kNonce / 7.0), 1.0); return o; }\n";
}
static std::string FragmentSource(const std::string& nonce) {
    return "#include <metal_stdlib>\nusing namespace metal;\nconstant float kNonce = " + nonce + ".0;\n"
           "struct main0_out { float4 out_color [[color(0)]]; };\n"
           "struct main0_in { float4 m_col [[user(locn0)]]; };\n"
           "fragment main0_out main0(main0_in in [[stage_in]]) {\n"
           "  main0_out o; o.out_color = float4(in.m_col.xyz * 0.5, fract(kNonce / 3.0)); return o; }\n";
}
static std::string KernelSource(const std::string& nonce) {
    return "#include <metal_stdlib>\nusing namespace metal;\nconstant float kNonce = " + nonce + ".0;\n"
           "kernel void main0(device float* o [[buffer(0)]], uint i [[thread_position_in_grid]]) {\n"
           "  o[i] = float(i) * 3.0 + kNonce; }\n";
}
static ls::Key KeyOf(const std::string& src) {
    return ls::MakeKey(src.data(), src.size());
}

static MTLCompileOptions* Options() {
    MTLCompileOptions* o = [MTLCompileOptions new];
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    o.fastMathEnabled = NO;
#pragma clang diagnostic pop
    o.preserveInvariance = YES;
    return o;
}

static id<MTLFunction> Compile(id<MTLDevice> dev, const std::string& src) {
    NSError* e = nil;
    id<MTLLibrary> l = [dev newLibraryWithSource:@(src.c_str()) options:Options() error:&e];
    return [l newFunctionWithName:@"main0"];
}

static MTLRenderPipelineDescriptor* RenderDesc(id<MTLFunction> vs, id<MTLFunction> fs) {
    MTLRenderPipelineDescriptor* d = [MTLRenderPipelineDescriptor new];
    d.vertexFunction = vs;
    d.fragmentFunction = fs;
    d.colorAttachments[0].pixelFormat = MTLPixelFormatRGBA32Float;
    return d;
}

// Draws one triangle over a 4x4 RGBA32F target and returns pixel (1,1).
static bool Draw(id<MTLDevice> dev, id<MTLFunction> vs, id<MTLFunction> fs, float out[4]) {
    NSError* e = nil;
    id<MTLRenderPipelineState> p = [dev newRenderPipelineStateWithDescriptor:RenderDesc(vs, fs) error:&e];
    if (!p) return false;
    MTLTextureDescriptor* td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA32Float
                                                                                  width:4 height:4 mipmapped:NO];
    td.usage = MTLTextureUsageRenderTarget;
    td.storageMode = MTLStorageModeShared;
    id<MTLTexture> t = [dev newTextureWithDescriptor:td];
    id<MTLCommandQueue> q = [dev newCommandQueue];
    id<MTLCommandBuffer> cb = [q commandBuffer];
    MTLRenderPassDescriptor* rp = [MTLRenderPassDescriptor renderPassDescriptor];
    rp.colorAttachments[0].texture = t;
    rp.colorAttachments[0].loadAction = MTLLoadActionClear;
    rp.colorAttachments[0].storeAction = MTLStoreActionStore;
    rp.colorAttachments[0].clearColor = MTLClearColorMake(9, 9, 9, 9);
    id<MTLRenderCommandEncoder> re = [cb renderCommandEncoderWithDescriptor:rp];
    [re setRenderPipelineState:p];
    [re drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
    [re endEncoding];
    [cb commit];
    [cb waitUntilCompleted];
    [t getBytes:out bytesPerRow:4 * 16 fromRegion:MTLRegionMake2D(1, 1, 1, 1) mipmapLevel:0];
    return cb.status == MTLCommandBufferStatusCompleted;
}

static bool Dispatch(id<MTLDevice> dev, id<MTLFunction> cs, std::vector<float>* out) {
    NSError* e = nil;
    id<MTLComputePipelineState> p = [dev newComputePipelineStateWithFunction:cs error:&e];
    if (!p) return false;
    id<MTLBuffer> b = [dev newBufferWithLength:64 * 4 options:MTLResourceStorageModeShared];
    id<MTLCommandQueue> q = [dev newCommandQueue];
    id<MTLCommandBuffer> cb = [q commandBuffer];
    id<MTLComputeCommandEncoder> ce = [cb computeCommandEncoder];
    [ce setComputePipelineState:p];
    [ce setBuffer:b offset:0 atIndex:0];
    [ce dispatchThreads:MTLSizeMake(64, 1, 1) threadsPerThreadgroup:MTLSizeMake(64, 1, 1)];
    [ce endEncoding];
    [cb commit];
    [cb waitUntilCompleted];
    out->assign((float*)b.contents, (float*)b.contents + 64);
    return cb.status == MTLCommandBufferStatusCompleted;
}

static int CountEntries(const std::string& dir) {
    int n = 0;
    if (DIR* d = opendir(dir.c_str())) {
        while (dirent* de = readdir(d)) {
            ls::Key k;
            if (ls::ParseFileName(de->d_name, &k)) ++n;
        }
        closedir(d);
    }
    return n;
}

static int Unit() {
    // h1 must equal the renderer's MSL hash (ps4_gnm_draw.mm Fnv: FNV-1a steps from the seed
    // 1469598103934665603), which names the MSL cache files and keys its pipelines
    CHECK(ls::MakeKey("", 0).h1 == 1469598103934665603ull, "h1 of the empty string");
    CHECK(ls::MakeKey("a", 1).h1 == (1469598103934665603ull ^ 0x61) * 1099511628211ull, "h1 of \"a\"");
    const std::string a = VertexSource("1"), b = VertexSource("2");
    const ls::Key ka = KeyOf(a), kb = KeyOf(b);
    CHECK(ka == KeyOf(a), "key not deterministic");
    CHECK(ka.h1 != kb.h1 && ka.h2 != kb.h2, "different MSL, same hashes");
    CHECK(ka.len == a.size(), "key length");
    CHECK(ka.h1 != ka.h2, "h2 not independent of h1");
    // file names
    const std::string fn = ls::FileName(ka);
    ls::Key parsed;
    CHECK(fn.size() == 38 && ls::ParseFileName(fn.c_str(), &parsed) && parsed.h1 == ka.h1 && parsed.h2 == ka.h2,
          "file name round trip");
    CHECK(!ls::ParseFileName((fn + ".tmp123").c_str(), &parsed), "temporary file taken for an entry");
    CHECK(!ls::ParseFileName("0123456789abcdef_0123456789abcdeg.mlib", &parsed), "non-hex name accepted");
    CHECK(!ls::ParseFileName("0123456789abcdef-0123456789abcdef.mlib", &parsed), "name without '_' accepted");
    CHECK(!ls::ParseFileName("0123456789abcdef_0123456789abcdef.metal", &parsed), "other suffix accepted");
    // format: round trip and every refusal
    std::vector<uint8_t> payload(1000);
    for (size_t i = 0; i < payload.size(); ++i) payload[i] = (uint8_t)(i * 7 + 3);
    std::vector<uint8_t> file;
    ls::Encode(ka, ls::kFragment, payload.data(), payload.size(), &file);
    CHECK(file.size() == sizeof(ls::Header) + payload.size(), "encoded size");
    const uint8_t* p = nullptr;
    size_t pn = 0;
    CHECK(ls::Decode(file.data(), file.size(), ka, ls::kFragment, &p, &pn) == ls::Status::kOk && pn == payload.size() &&
              memcmp(p, payload.data(), pn) == 0,
          "decode round trip");
    CHECK(ls::Decode(file.data(), 10, ka, ls::kFragment, &p, &pn) == ls::Status::kTooSmall, "short file");
    CHECK(ls::Decode(file.data(), file.size() - 1, ka, ls::kFragment, &p, &pn) == ls::Status::kBadSize, "truncated");
    std::vector<uint8_t> longer = file;
    longer.push_back(0);
    CHECK(ls::Decode(longer.data(), longer.size(), ka, ls::kFragment, &p, &pn) == ls::Status::kBadSize, "extended");
    CHECK(ls::Decode(file.data(), file.size(), kb, ls::kFragment, &p, &pn) == ls::Status::kWrongKey, "other MSL");
    ls::Key klen = ka;
    klen.len++;
    CHECK(ls::Decode(file.data(), file.size(), klen, ls::kFragment, &p, &pn) == ls::Status::kWrongKey, "other length");
    ls::Key kh2 = ka;
    kh2.h2 ^= 1;
    CHECK(ls::Decode(file.data(), file.size(), kh2, ls::kFragment, &p, &pn) == ls::Status::kWrongKey, "other h2");
    CHECK(ls::Decode(file.data(), file.size(), ka, ls::kVertex, &p, &pn) == ls::Status::kWrongStage, "other stage");
    std::vector<uint8_t> bad = file;
    bad[0] ^= 1;
    CHECK(ls::Decode(bad.data(), bad.size(), ka, ls::kFragment, &p, &pn) == ls::Status::kBadMagic, "magic");
    bad = file;
    bad[offsetof(ls::Header, version)] ^= 1;
    CHECK(ls::Decode(bad.data(), bad.size(), ka, ls::kFragment, &p, &pn) == ls::Status::kBadVersion, "version");
    for (size_t at : {sizeof(ls::Header), sizeof(ls::Header) + 500, file.size() - 1}) {
        bad = file;
        bad[at] ^= 0x10;
        CHECK(ls::Decode(bad.data(), bad.size(), ka, ls::kFragment, &p, &pn) == ls::Status::kBadHash, "damaged payload");
    }
    bad = file;
    bad[offsetof(ls::Header, payload_hash)] ^= 1;
    CHECK(ls::Decode(bad.data(), bad.size(), ka, ls::kFragment, &p, &pn) == ls::Status::kBadHash, "damaged hash field");
    // configurations: options and OS build select the directory
    const std::string c0 = ls::ConfigName(kTag, "25A100");
    CHECK(c0.size() == 16 && c0 == ls::ConfigName(kTag, "25A100"), "configuration name not deterministic");
    CHECK(c0 != ls::ConfigName("fastMath=1;preserveInvariance=1", "25A100"), "options do not change the configuration");
    CHECK(c0 != ls::ConfigName(kTag, "25A101"), "OS build does not change the configuration");
    printf("lib_store_test unit: PASS\n");
    return 0;
}

int main(int argc, char** argv) {
    if (argc == 2 && strcmp(argv[1], "unit") == 0) return Unit();
    if (argc != 4) return Fail("usage: lib_store_test unit | <write|read|corrupt|config|budget> <dir> <nonce>");
    const std::string mode = argv[1], dir = argv[2], nonce = argv[3];
    @autoreleasepool {
        id<MTLDevice> dev = MTLCreateSystemDefaultDevice();
        CHECK(dev, "no Metal device");
        const std::string vsrc = VertexSource(nonce), fsrc = FragmentSource(nonce), csrc = KernelSource(nonce);
        const ls::Key kv = KeyOf(vsrc), kf = KeyOf(fsrc), kc = KeyOf(csrc);
        const char* tag = mode == "config" ? "fastMath=1;preserveInvariance=1" : kTag;
        if (mode == "budget") {
            // three entries of about the same size; the one used least recently goes
            std::string sd;
            {
                CHECK(ls::Open(dev, dir, kTag, 64ull << 20), "budget: open");
                sd = ls::Dir();
            }
            CHECK(CountEntries(sd) == 3, "budget: expected the 3 entries of write");
            struct timeval tv[2] = {{1000000000, 0}, {1000000000, 0}};
            utimes((sd + "/" + ls::FileName(kc)).c_str(), tv); // oldest
            tv[0].tv_sec = tv[1].tv_sec = 1100000000;
            utimes((sd + "/" + ls::FileName(kv)).c_str(), tv);
            struct stat st;
            uint64_t total = 0;
            for (const ls::Key& k : {kv, kf, kc}) {
                CHECK(stat((sd + "/" + ls::FileName(k)).c_str(), &st) == 0, "budget: stat");
                total += (uint64_t)st.st_size;
            }
            // reopen (a new session) with a budget just under the total: 3/4 of it keeps two files
            // only if the smallest goes; the kernel entry is the oldest, so it must be the one removed
            // as long as removing it brings the total under 3/4 of the budget
            const uint64_t budget = total - 1;
            CHECK(ls::Open(dev, dir, kTag, budget), "budget: reopen");
            const bool kept_v = stat((sd + "/" + ls::FileName(kv)).c_str(), &st) == 0;
            const bool kept_f = stat((sd + "/" + ls::FileName(kf)).c_str(), &st) == 0;
            const bool kept_c = stat((sd + "/" + ls::FileName(kc)).c_str(), &st) == 0;
            CHECK(!kept_c, "budget: least recently used entry kept");
            CHECK(kept_f, "budget: most recently used entry removed");
            CHECK(ls::Has(kv) == kept_v && ls::Has(kf) && !ls::Has(kc), "budget: index does not match the files");
            printf("lib_store_test budget: PASS\n");
            return 0;
        }
        CHECK(ls::Open(dev, dir, tag, 64ull << 20), "open");
        const std::string sd = ls::Dir();
        if (mode == "write") {
            CHECK(CountEntries(sd) == 0 && !ls::Has(kv) && !ls::Has(kf) && !ls::Has(kc), "write: store not empty");
            // a stale temporary of a dead process and one of this process (kept)
            const std::string stale = sd + "/" + ls::FileName(kv) + ".tmp999999";
            FILE* f = fopen(stale.c_str(), "w");
            fputs("x", f);
            fclose(f);
            id<MTLFunction> v = Compile(dev, vsrc), fr = Compile(dev, fsrc), c = Compile(dev, csrc);
            CHECK(v && fr && c, "write: compile");
            NSError* e = nil;
            MTLRenderPipelineDescriptor* rd = RenderDesc(v, fr);
            CHECK([dev newRenderPipelineStateWithDescriptor:rd error:&e], "write: render pipeline");
            MTLComputePipelineDescriptor* cd = [MTLComputePipelineDescriptor new];
            cd.computeFunction = c;
            CHECK([dev newComputePipelineStateWithDescriptor:cd options:MTLPipelineOptionNone reflection:nil error:&e],
                  "write: compute pipeline");
            ls::StoreRender(&kv, &kf, rd);
            ls::StoreCompute(kc, cd);
            CHECK(ls::Has(kv) && ls::Has(kf) && ls::Has(kc), "write: queued entries not known");
            ls::StoreRender(&kv, &kf, rd); // already queued: no second write
            CHECK(ls::Flush(60), "write: flush");
            CHECK(CountEntries(sd) == 3, "write: expected 3 entries");
            ls::Key full;
            uint32_t stage = 0;
            CHECK(ls::Peek(kv, &full, &stage) && full == kv && stage == ls::kVertex, "write: vertex entry header");
            CHECK(ls::Peek(kf, &full, &stage) && full == kf && stage == ls::kFragment, "write: fragment entry header");
            CHECK(ls::Peek(kc, &full, &stage) && full == kc && stage == ls::kKernel, "write: kernel entry header");
            printf("lib_store_test write: PASS\n");
            return 0;
        }
        if (mode == "read") {
            struct stat st;
            CHECK(stat((sd + "/" + ls::FileName(kv) + ".tmp999999").c_str(), &st) != 0, "read: stale temporary kept");
            CHECK(CountEntries(sd) == 3 && ls::Has(kv) && ls::Has(kf) && ls::Has(kc), "read: entries not indexed");
            std::string why;
            id<MTLFunction> v = ls::Load(kv, ls::kVertex, &why);
            CHECK(v && v.functionType == MTLFunctionTypeVertex, "read: vertex function");
            id<MTLFunction> fr = ls::Load(kf, ls::kFragment, &why);
            CHECK(fr && fr.functionType == MTLFunctionTypeFragment, "read: fragment function");
            id<MTLFunction> c = ls::Load(kc, ls::kKernel, &why);
            CHECK(c && c.functionType == MTLFunctionTypeKernel, "read: kernel function");
            // same results as source-compiled functions
            float a[4], b[4];
            CHECK(Draw(dev, v, fr, a), "read: draw with stored functions");
            CHECK(Draw(dev, Compile(dev, vsrc), Compile(dev, fsrc), b), "read: draw with compiled functions");
            CHECK(memcmp(a, b, sizeof(a)) == 0, "read: stored and compiled functions draw different pixels");
            const float n = (float)atof(nonce.c_str());
            CHECK(a[0] == 0.125f && a[1] == 0.25f && fabsf(a[3] - (n / 3.0f - floorf(n / 3.0f))) < 1e-4f,
                  "read: unexpected pixel");
            std::vector<float> x, y;
            CHECK(Dispatch(dev, c, &x) && Dispatch(dev, Compile(dev, csrc), &y) && x == y, "read: dispatch results differ");
            CHECK(x[5] == 15.0f + n, "read: unexpected dispatch result");
            // a request for the wrong stage is refused (and the entry dropped)
            CHECK(!ls::Load(kc, ls::kVertex, &why) && !ls::Has(kc) && stat((sd + "/" + ls::FileName(kc)).c_str(), &st) != 0,
                  "read: wrong stage accepted or entry kept");
            printf("lib_store_test read: PASS\n");
            return 0;
        }
        if (mode == "corrupt") {
            const std::string p = sd + "/" + ls::FileName(kf);
            FILE* f = fopen(p.c_str(), "r+b");
            CHECK(f, "corrupt: open entry");
            fseek(f, -100, SEEK_END);
            int ch = fgetc(f);
            fseek(f, -100, SEEK_END);
            fputc(ch ^ 0x40, f);
            fclose(f);
            std::string why;
            CHECK(!ls::Load(kf, ls::kFragment, &why) && why == ls::StatusName(ls::Status::kBadHash), "corrupt: damaged entry loaded");
            struct stat st;
            CHECK(stat(p.c_str(), &st) != 0 && !ls::Has(kf), "corrupt: damaged entry kept");
            CHECK(ls::Load(kv, ls::kVertex, &why), "corrupt: intact entry refused");
            printf("lib_store_test corrupt: PASS\n");
            return 0;
        }
        if (mode == "config") {
            // the entries of the other options are gone, the new directory is empty
            CHECK(CountEntries(sd) == 0 && !ls::Has(kv), "config: new configuration not empty");
            int dirs = 0;
            if (DIR* d = opendir((dir + "/mlib").c_str())) {
                while (dirent* de = readdir(d))
                    if (de->d_name[0] != '.') ++dirs;
                closedir(d);
            }
            CHECK(dirs == 1, "config: directory of the old configuration kept");
            printf("lib_store_test config: PASS\n");
            return 0;
        }
    }
    return Fail("unknown mode");
}
