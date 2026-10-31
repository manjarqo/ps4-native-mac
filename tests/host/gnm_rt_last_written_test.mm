// Several GPU-owned surfaces at one address (ps4_gnm_resources.mm TextureCache): the same memory is
// used as surfaces of other sizes over a frame (a 1920x1080 target, then a 960x540 one at the same
// base for a half-resolution pass). Their memory holds what the last write left, so a lookup must
// take the last written surface. Before, every lookup took the first surface the hash map returned
// at the address: inFAMOUS Second Son's half-resolution motion blur sampled the corner of the
// full-resolution target instead of the half-resolution one written just before, and composited it
// over the frame as a ghost image at twice the size. A lookup takes the last written surface of
// those that cover the image (a smaller one written later holds only a part of it).
// Two RGBA8 targets at one address, A of 64x64 and B of 32x32, each filled with its own value, in
// both orders at two addresses (the map's order at an address is fixed, so one order failed):
//   (a) a 32x32 T# reads B when B was written last and the corner of A when A was;
//   (b) a 64x64 T# reads A in either order (only A covers it; B holds a part of it only);
//   (c) a 32x32 storage T# binds the last written of the surfaces that hold it;
//   (d) FindColorTarget(address) returns the last written surface;
//   (e) drawing to A again (a render-target bind) makes A the last written;
//   (f) a bind that only reads (a resolve source, a draw with write mask 0, a depth/stencil test
//       without writes) does not make a surface the last written;
//   (g) PS4 Pro checkerboard depth: a 1x depth surface and its 2x twin share the memory; with the
//       2x one bound last, the 1x lookup the storage-to-depth sync uses still finds the 1x one;
//   (h) a surface clone takes the last written of a depth and a color surface at the source;
//   (i) a color target reloaded from guest memory after a CPU write (InvalidateRange) is used then:
//       a clear of another surface over its bytes before that write no longer counts it as
//       superseded, and it is not evicted (it holds the newer guest bytes).
// Runs on the backend PS4_GNM_METAL names (test_backend.h).
#import <Metal/Metal.h>
#include <stdio.h>
#include <string.h>
#include <sys/mman.h>

#include "ps4_gnm_resources.h"
#include "test_backend.h"

// Runtime symbols ps4_gnm_resources.mm uses (the hitch counters and the Neo mode query).
extern "C" uint64_t ps4_hitch_now_ns(void) { return 0; }
extern "C" void ps4_hitch_add_ns(int, uint64_t) {}
extern "C" void ps4_gnm_hitch_note_upload(double) {}
extern "C" int32_t sceKernelIsNeoMode(void) { return 0; }

using namespace ps4gnm;

static int g_fail;

static void check(bool ok, const char* what) {
    printf("%s: %s\n", ok ? "ok" : "FAIL", what);
    if (!ok) g_fail = 1;
}

static const uint64_t kGuestSize = 1ull << 30;

static void Attach(TextureCache& tc, TestTextureResidency& res) {
    TextureCache::TextureHooks h;
    h.ctx = &res;
    h.created = TestTextureResidency::Created;
    h.released = TestTextureResidency::Released;
    tc.SetHooks(h);
}

// 2D RGBA8 unorm linear-aligned T# of n x n at addr (pitch n).
static ImageDesc Tsharp(uint64_t addr, uint32_t n) {
    uint32_t dw[8] = {};
    dw[0] = (uint32_t)(addr >> 8);
    dw[1] = (uint32_t)((addr >> 40) & 0xff) | (10u << 20); // 8_8_8_8 unorm
    dw[2] = (n - 1) | ((n - 1) << 14);
    dw[3] = 4u | (5u << 3) | (6u << 6) | (7u << 9) | (8u << 20) /* linear aligned */ | (9u << 28) /* 2D */;
    dw[4] = (n - 1) << 13;
    ImageDesc d;
    DecodeImage(dw, 8, &d);
    return d;
}

// RGBA8 linear-aligned render target of n x n at addr (pitch n).
static ColorTarget Rt(uint64_t addr, uint32_t n) {
    ColorTarget c;
    c.bound = true;
    c.address = addr;
    c.pitch = n;
    c.height = n;
    c.slice_bytes = n * n * 4;
    c.num_slices = 1;
    c.num_samples = 1;
    c.bpp = 32;
    c.dfmt = DataFormat::Format8_8_8_8;
    c.nfmt = NumberFormat::Unorm;
    c.mtl_format = MTLPixelFormatRGBA8Unorm;
    c.tile_mode = TileMode::DisplayLinearAligned;
    return c;
}

// n x n Depth32Float target at addr with `samples` samples.
static DepthTarget Db(uint64_t addr, uint32_t n, uint32_t samples) {
    DepthTarget d;
    d.bound = true;
    d.z_read_address = addr;
    d.pitch = n;
    d.height = n;
    d.slice_bytes = n * n * 4 * samples;
    d.num_slices = 1;
    d.num_samples = samples;
    d.bpp = 32;
    d.mtl_format = MTLPixelFormatDepth32Float;
    return d;
}

// What a draw into the target leaves: every texel `v` (written through a blit on the cache's queue,
// so it lands before the cache's own copies and the test's readbacks).
static void Draw(id<MTLDevice> dev, id<MTLCommandQueue> q, id<MTLTexture> t, uint8_t v) {
    const NSUInteger n = t.width * t.height * 4;
    id<MTLBuffer> b = [dev newBufferWithLength:n options:MTLResourceStorageModeShared];
    memset(b.contents, v, n);
    id<MTLCommandBuffer> cb = [q commandBuffer];
    id<MTLBlitCommandEncoder> bl = [cb blitCommandEncoder];
    [bl copyFromBuffer:b
               sourceOffset:0
          sourceBytesPerRow:t.width * 4
        sourceBytesPerImage:n
                 sourceSize:MTLSizeMake(t.width, t.height, 1)
                  toTexture:t
           destinationSlice:0
           destinationLevel:0
          destinationOrigin:MTLOriginMake(0, 0, 0)];
    [bl endEncoding];
    [cb commit];
    [cb waitUntilCompleted];
}

// First byte of texel (0, 0) of tex (any storage mode).
static int Texel0(id<MTLDevice> dev, id<MTLCommandQueue> q, id<MTLTexture> tex) {
    if (!tex) return -1;
    id<MTLBuffer> b = [dev newBufferWithLength:256 options:MTLResourceStorageModeShared];
    id<MTLCommandBuffer> cb = [q commandBuffer];
    id<MTLBlitCommandEncoder> bl = [cb blitCommandEncoder];
    [bl copyFromTexture:tex
                     sourceSlice:0
                     sourceLevel:0
                    sourceOrigin:MTLOriginMake(0, 0, 0)
                      sourceSize:MTLSizeMake(1, 1, 1)
                        toBuffer:b
               destinationOffset:0
          destinationBytesPerRow:4
        destinationBytesPerImage:4];
    [bl endEncoding];
    [cb commit];
    [cb waitUntilCompleted];
    return ((const uint8_t*)b.contents)[0];
}

// A (64x64, 0xA0) and B (32x32, 0xB0) at addr, drawn in the order `a_first` says.
static void run(id<MTLDevice> dev, id<MTLCommandQueue> q, TextureCache& tc, uint64_t addr, bool a_first) {
    const char* order = a_first ? "A then B" : "B then A";
    printf("%s at 0x%llx\n", order, (unsigned long long)addr);
    @autoreleasepool {
        id<MTLTexture> a = nil, b = nil;
        if (a_first) {
            a = tc.GetColorTarget(Rt(addr, 64), false);
            Draw(dev, q, a, 0xA0);
            b = tc.GetColorTarget(Rt(addr, 32), false);
            Draw(dev, q, b, 0xB0);
        } else {
            b = tc.GetColorTarget(Rt(addr, 32), false);
            Draw(dev, q, b, 0xB0);
            a = tc.GetColorTarget(Rt(addr, 64), false);
            Draw(dev, q, a, 0xA0);
        }
        check(a && b && a != b, "two render targets at one address");
        const uint8_t last = a_first ? 0xB0 : 0xA0;
        const int small = Texel0(dev, q, tc.GetTexture(Tsharp(addr, 32)));
        printf("  32x32 T# reads %02x\n", small);
        check(small == last, "(a) a 32x32 T# reads the last written surface");
        const int big = Texel0(dev, q, tc.GetTexture(Tsharp(addr, 64)));
        printf("  64x64 T# reads %02x\n", big);
        check(big == 0xA0, "(b) a 64x64 T# reads A");
        check(tc.FindColorTarget(addr) == (a_first ? b : a), "(d) FindColorTarget returns the last written surface");
        id<MTLTexture> st = tc.GetStorageTexture(Tsharp(addr, 32));
        check(st == (a_first ? b : a), "(c) a 32x32 storage T# binds the last written surface that holds it");
        if (a_first) {
            check(tc.GetColorTarget(Rt(addr, 64), false) == a, "A bound again");
            Draw(dev, q, a, 0xA1);
            const int again = Texel0(dev, q, tc.GetTexture(Tsharp(addr, 32)));
            printf("  32x32 T# after A is drawn again reads %02x\n", again);
            check(again == 0xA1, "(e) after A is drawn again, a 32x32 T# reads A's corner");
            check(tc.FindColorTarget(addr) == a, "(e) FindColorTarget returns A");
        }
    }
}

// (f), (g), (h)
static void run_binds(id<MTLDevice> dev, id<MTLCommandQueue> q, TextureCache& tc) {
    @autoreleasepool {
        const uint64_t X = 0x30000000, D = 0x38000000, C = 0x3c000000;
        id<MTLTexture> a = tc.GetColorTarget(Rt(X, 64), false);
        Draw(dev, q, a, 0xA0);
        id<MTLTexture> b = tc.GetColorTarget(Rt(X, 32), false);
        Draw(dev, q, b, 0xB0);
        check(tc.GetColorTarget(Rt(X, 64), false, false) == a, "A bound without writes");
        check(tc.FindColorTarget(X) == b, "(f) a color bind without writes leaves B the last written");
        check(Texel0(dev, q, tc.GetTexture(Tsharp(X, 32))) == 0xB0, "(f) a 32x32 T# still reads B");
        id<MTLTexture> d1 = tc.GetDepthTarget(Db(D, 64, 1));
        id<MTLTexture> d2 = tc.GetDepthTarget(Db(D, 64, 2));
        check(d1 && d2 && d1.sampleCount == 1 && d2.sampleCount == 2, "a 1x depth surface and its 2x twin");
        check(tc.FindDepthTarget(D) == d2, "the 2x twin, bound last, is the last written");
        check(tc.FindDepthTarget(D, 1) == d1, "(g) the 1x lookup finds the 1x surface");
        check(tc.FindDepthTarget(D, 2) == d2, "(g) the 2x lookup finds the 2x twin");
        check(tc.GetDepthTarget(Db(D, 64, 1), nullptr, false) == d1, "the 1x surface bound for a test only");
        check(tc.FindDepthTarget(D) == d2, "(f) a depth test without writes leaves the 2x twin the last written");
        check(tc.GetDepthTarget(Db(D, 64, 1)) == d1 && tc.FindDepthTarget(D) == d1,
              "a depth write makes the 1x surface the last written");
        id<MTLTexture> cd = tc.GetDepthTarget(Db(C, 64, 1));
        id<MTLTexture> cc = tc.GetColorTarget(Rt(C, 64), false);
        id<MTLTexture> src = nil, dst = nil;
        int kind = 0;
        check(cd && cc && tc.CloneGpuTexture(C, C + 0x1000000, 64 * 64 * 4, &src, &dst, &kind),
              "a clone of the surfaces at C");
        check(src == cc && kind == 1, "(h) the clone takes the color surface written after the depth one");
    }
}

// (i), in a cache of its own (the eviction would see the other cases' surfaces)
static void run_reload(id<MTLDevice> dev, id<MTLCommandQueue> q, uint8_t* mem, TestTextureResidency& res) {
    const uint64_t MS = 1000000ull, X = 0x40000000, bytes = 64 * 64 * 4;
    TextureCache tc(dev, q, mem, kGuestSize);
    Attach(tc, res);
    @autoreleasepool {
        tc.SetUse(1, 1000 * MS);
        id<MTLTexture> a = tc.GetColorTarget(Rt(X, 64), false);
        tc.SetUse(2, 2000 * MS);
        id<MTLTexture> d = tc.GetDepthTarget(Db(X, 64, 1));
        check(a && d && tc.NoteExactWrite(X, d, X, X + bytes, 2), "a depth clear over the color target's bytes");
        check(tc.GetGpuOwnedStats(0).superseded_count == 1, "the clear supersedes the color target");
        tc.SetUse(3, 3000 * MS);
        tc.InvalidateRange(X, bytes, true, 0); // a CPU write over the bytes: the color target is reloaded
        const TextureCache::GpuOwnedStats g = tc.GetGpuOwnedStats(0);
        printf("  after the reload: %llu superseded\n", (unsigned long long)g.superseded_count);
        check(g.superseded_count == 0, "(i) the reloaded color target is not superseded");
        const TextureCache::EvictResult r = tc.EvictSuperseded(0, 10000 * MS, 100);
        check(r.count == 0 && tc.FindColorTarget(X) == a, "(i) the reloaded color target is not evicted");
        std::vector<id<MTLTexture>> retired;
        tc.TakeRetired(&retired);
    }
}

int main() {
    const char* backend = "none";
    @autoreleasepool {
        id<MTLDevice> dev = MTLCreateSystemDefaultDevice();
        if (!dev) {
            printf("FAIL: no Metal device\n");
            return 1;
        }
        const char* env = getenv("PS4_GNM_METAL");
        if (env && !strcmp(env, "4") && !RequireMetal4(dev, "gnm_rt_last_written_test")) return 0;
        std::string why;
        std::unique_ptr<GnmBackend> be = MakeTestBackend(dev, &why);
        if (!be) {
            printf("FAIL: no backend: %s\n", why.c_str());
            return 1;
        }
        backend = BackendName(be->Kind());
        TestTextureResidency res;
        res.be = be.get();
        uint8_t* mem = (uint8_t*)mmap(nullptr, kGuestSize, PROT_READ | PROT_WRITE, MAP_ANON | MAP_PRIVATE | MAP_NORESERVE,
                                      -1, 0);
        if (mem == MAP_FAILED) {
            printf("FAIL: guest memory not mapped\n");
            return 1;
        }
        id<MTLCommandQueue> q = be->SideQueue();
        {
            TextureCache tc(dev, q, mem, kGuestSize);
            Attach(tc, res);
            run(dev, q, tc, 0x10000000, true);
            run(dev, q, tc, 0x20000000, false);
            run_binds(dev, q, tc);
        }
        run_reload(dev, q, mem, res);
        res.Retire();
        munmap(mem, kGuestSize);
    }
    printf("gnm_rt_last_written_test: %s [%s]\n", g_fail ? "FAIL" : "PASS", backend);
    return g_fail;
}
