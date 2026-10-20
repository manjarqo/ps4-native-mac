// Texture cache eviction (docs/gpu-memory-budget.md): the policy (ps4_texcache_select and the
// defaults in ps4_gnm_membudget.c) and the real TextureCache (ps4_gnm_resources.mm) on a real
// Metal device over a host buffer standing in for guest memory: which entries go, that a texture
// referenced by a command buffer in flight is never evicted and stays alive until that command
// buffer is done, that its memory is then freed, that an evicted texture comes back with the
// current guest memory, how GPU-write invalidation behaves around eviction, that GPU-owned surfaces
// stay, and that the GPU-owned range index notices entries added after an eviction.
#import <Metal/Metal.h>
#include <stdio.h>
#include <string.h>
#include <sys/mman.h>

#include "ps4_gnm_membudget.h"
#include "ps4_gnm_resources.h"

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

static const uint64_t MiB = 1ull << 20, GiB = 1ull << 30, MS = 1000000ull;

// ---- policy ----

static void test_policy_init() {
    ps4_gpumem_policy gp;
    ps4_gpumem_policy_init(&gp, 16 * GiB, NULL, NULL, NULL);
    ps4_texcache_policy p;
    ps4_texcache_policy_init(&p, &gp, NULL, NULL);
    check(p.budget == gp.budget / 4, "default cache budget: a quarter of the GPU budget");
    check(p.low_water == p.budget / 10 * 9, "evicts down to 90% of the cache budget");
    check(p.keep_ns == 2000 * MS, "textures used within 2 s are kept");
    check(p.press_ns == gp.press_ns, "GPU budget pressure keeps the windows' 250 ms");
    ps4_texcache_policy_init(&p, &gp, "512", "500");
    check(p.budget == 512 * MiB && p.keep_ns == 500 * MS, "PS4_GNM_TEX_CACHE_MB=512, PS4_GNM_TEX_KEEP_MS=500");
    ps4_texcache_policy_init(&p, &gp, "0", "5");
    check(p.budget == UINT64_MAX, "PS4_GNM_TEX_CACHE_MB=0: no cache budget");
    check(p.keep_ns == 100 * MS, "keep time clamped to 100 ms");
    ps4_texcache_policy_init(&p, &gp, "x1", "junk");
    check(p.budget == gp.budget / 4 && p.keep_ns == 2000 * MS, "junk values keep the defaults");
    ps4_gpumem_policy_init(&gp, 0, NULL, NULL, NULL);
    ps4_texcache_policy_init(&p, &gp, NULL, NULL);
    check(p.budget == UINT64_MAX, "no GPU budget (unknown RAM): no cache budget");
    check(!ps4_texcache_evict_due(&p, 100 * GiB, 0) && ps4_texcache_evict_due(&p, 0, 1),
          "unlimited cache: only GPU budget pressure makes eviction due");
}

static ps4_texcache_policy small_policy(uint64_t budget) {
    ps4_texcache_policy p;
    memset(&p, 0, sizeof(p));
    p.budget = budget;
    p.low_water = budget / 10 * 9;
    p.keep_ns = 2000 * MS;
    p.press_ns = 250 * MS;
    return p;
}

static void test_select() {
    const ps4_texcache_policy p = small_policy(100);
    // id, last_ns, last_seq, bytes
    ps4_texcache_item it[6] = {
        {10000 * MS, 50, 30, 0}, // used at 10 s by command buffer 50 (in flight)
        {1000 * MS, 5, 30, 1},   // oldest
        {3000 * MS, 7, 30, 2},
        {2000 * MS, 6, 30, 3},
        {9500 * MS, 9, 30, 4},   // used 500 ms ago: recent
        {4000 * MS, 8, 30, 5},
    };
    const uint64_t total = 180, now = 10000 * MS, completed = 9;
    uint64_t freed = 0;
    ps4_texcache_item a[6];
    memcpy(a, it, sizeof(a));
    uint64_t n = ps4_texcache_select(a, 6, 50, &p, 0, now, completed, &freed);
    check(n == 0 && freed == 0, "under the cache budget nothing is evicted");
    memcpy(a, it, sizeof(a));
    n = ps4_texcache_select(a, 6, total, &p, 0, now, completed, &freed);
    // 180 -> at most 90: needs 90 bytes = three textures, least recently used first
    check(n == 3 && freed == 90, "over the cache budget: evicts down to the low water mark");
    check(n == 3 && a[0].id == 1 && a[1].id == 3 && a[2].id == 2, "least recently used go first");
    bool bad = false;
    for (uint64_t i = 0; i < n; ++i) bad |= a[i].id == 0 || a[i].id == 4;
    check(!bad, "neither the in-flight nor the recently used texture is chosen");
    // all candidates are needed and still not enough
    memcpy(a, it, sizeof(a));
    n = ps4_texcache_select(a, 6, 1000, &p, 0, now, completed, &freed);
    check(n == 4 && freed == 120, "working set over the budget: only the four candidates go");
    // GPU budget pressure: every candidate not used in the last 250 ms, also the 500 ms one
    memcpy(a, it, sizeof(a));
    n = ps4_texcache_select(a, 6, 50, &p, 1, now, completed, &freed);
    bad = false;
    for (uint64_t i = 0; i < n; ++i) bad |= a[i].id == 0;
    check(n == 5 && freed == 150 && !bad, "GPU budget pressure: all completed textures idle for 250 ms go");
    // the in-flight one becomes a candidate once its command buffer has completed
    memcpy(a, it, sizeof(a));
    n = ps4_texcache_select(a, 6, 50, &p, 1, now + 300 * MS, 50, &freed);
    check(n == 6, "after its command buffer completed (and 250 ms idle), the in-flight texture goes too");
    // a clock that went backwards never evicts
    ps4_texcache_item b[1] = {{now, 1, 1000, 7}};
    n = ps4_texcache_select(b, 1, 1000, &p, 1, now - 1, 5, &freed);
    check(n == 0, "a texture stamped later than now is kept");
}

// ---- TextureCache on Metal ----

struct Guest {
    uint8_t* base = nullptr;
    uint64_t size = 0;
};

// 2D RGBA8 unorm linear-aligned T# of w x h at addr (pitch = w).
static ImageDesc Tsharp(uint64_t addr, uint32_t w, uint32_t h) {
    uint32_t dw[8] = {};
    dw[0] = (uint32_t)(addr >> 8);
    dw[1] = (uint32_t)((addr >> 40) & 0xff) | (10u << 20) /* 8_8_8_8 */ | (0u << 26) /* unorm */;
    dw[2] = (w - 1) | ((h - 1) << 14);
    dw[3] = 4u | (5u << 3) | (6u << 6) | (7u << 9) | (8u << 20) /* linear aligned */ | (9u << 28) /* 2D */;
    dw[4] = (w - 1) << 13;
    ImageDesc d;
    DecodeImage(dw, 8, &d);
    return d;
}

static void Fill(Guest& g, uint64_t addr, uint64_t n, uint8_t v) { memset(g.base + addr, v, n); }

static uint8_t FirstByte(id<MTLTexture> t) {
    uint8_t px[4] = {};
    [t getBytes:px bytesPerRow:t.width * 4 fromRegion:MTLRegionMake2D(0, 0, 1, 1) mipmapLevel:0];
    return px[0];
}

static ColorTarget Rt(uint64_t addr) {
    ColorTarget c;
    c.bound = true;
    c.address = addr;
    c.pitch = 64;
    c.height = 64;
    c.slice_bytes = 64 * 64 * 4;
    c.num_slices = 1;
    c.num_samples = 1;
    c.bpp = 32;
    c.dfmt = DataFormat::Format8_8_8_8;
    c.nfmt = NumberFormat::Unorm;
    c.mtl_format = MTLPixelFormatRGBA8Unorm;
    c.tile_mode = TileMode::DisplayLinearAligned;
    return c;
}

static void test_cache(id<MTLDevice> dev) {
    id<MTLCommandQueue> q = [dev newCommandQueue];
    Guest g;
    g.size = 16 * MiB;
    g.base = (uint8_t*)mmap(nullptr, g.size, PROT_READ | PROT_WRITE, MAP_ANON | MAP_PRIVATE, -1, 0);
    check(g.base != MAP_FAILED, "guest memory mapped");
    TextureCache tc(dev, q, g.base, g.size);
    const ps4_texcache_policy p = small_policy(1); // any sampled texture is over the budget

    const uint64_t A = 0x10000, B = 0x40000;
    Fill(g, A, 64 * 64 * 4, 0x11);
    tc.SetUse(1, 1000 * MS); // open command buffer 1
    __weak id<MTLTexture> weak_a = nil;
    id<MTLCommandBuffer> cb = nil;
    id<MTLSharedEvent> gate = [dev newSharedEvent];
    @autoreleasepool {
        id<MTLTexture> ta = tc.GetTexture(Tsharp(A, 64, 64));
        check(ta != nil && FirstByte(ta) == 0x11, "sampled texture uploaded from guest memory");
        weak_a = ta;
        TextureCache::MemStats m = tc.GetMemStats();
        check(m.sampled_count == 1 && m.sampled_bytes >= 64 * 64 * 4, "MemStats counts the sampled texture");
        // command buffer 1 reads the texture (a blit into a buffer) and is committed, but held
        // back from completing by an event it waits on
        id<MTLBuffer> out = [dev newBufferWithLength:64 * 64 * 4 options:MTLResourceStorageModeShared];
        cb = [q commandBuffer];
        [cb encodeWaitForEvent:gate value:1];
        id<MTLBlitCommandEncoder> bl = [cb blitCommandEncoder];
        [bl copyFromTexture:ta sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0, 0, 0)
                 sourceSize:MTLSizeMake(64, 64, 1) toBuffer:out destinationOffset:0 destinationBytesPerRow:256
                destinationBytesPerImage:256 * 64];
        [bl endEncoding];
        [cb commit];
        tc.SetUse(2, 1000 * MS); // committed as 1, the next one is open

        // command buffer 1 not complete: the texture stays, however old and over budget
        TextureCache::EvictResult r = tc.EvictSampled(p, false, 60000 * MS, 0);
        check(r.count == 0 && tc.GetMemStats().sampled_count == 1, "in-flight texture not evicted (cache budget)");
        r = tc.EvictSampled(p, true, 60000 * MS, 0);
        check(r.count == 0, "in-flight texture not evicted (GPU budget pressure)");
        // completed, but used just now: kept
        r = tc.EvictSampled(p, false, 1500 * MS, 1);
        check(r.count == 0, "texture used 500 ms ago kept under the cache budget");
        // completed and idle: evicted
        r = tc.EvictSampled(p, false, 4000 * MS, 1);
        TextureCache::MemStats m2 = tc.GetMemStats();
        check(r.count == 1 && r.bytes == m.sampled_bytes && m2.sampled_count == 0 && m2.sampled_bytes == 0,
              "idle texture of a completed command buffer evicted, accounting removed");
        check(tc.EvictedCount() == 1 && tc.EvictedBytes() == m.sampled_bytes, "eviction totals");
    }
    // the cache and the test dropped the texture; only the waiting command buffer holds it
    for (int i = 0; i < 5; ++i) usleep(10000);
    check(weak_a != nil && cb.status < MTLCommandBufferStatusCompleted,
          "evicted texture kept alive by the command buffer in flight");
    gate.signaledValue = 1; // let the command buffer run: it reads the evicted texture
    // the evicted texture lived while the (real) command buffer referenced it
    [cb waitUntilCompleted];
    check(cb.status == MTLCommandBufferStatusCompleted, "command buffer using the evicted texture completed");
    cb = nil;
    for (int i = 0; i < 50 && weak_a; ++i) usleep(10000);
    check(weak_a == nil, "evicted texture freed once no command buffer holds it");

    // evicted texture comes back with the current guest memory (the game rewrote it meanwhile)
    Fill(g, A, 64 * 64 * 4, 0x22);
    tc.SetUse(3, 5000 * MS);
    id<MTLTexture> ta2 = tc.GetTexture(Tsharp(A, 64, 64));
    check(ta2 != nil && FirstByte(ta2) == 0x22, "re-created texture uploaded again from guest memory");

    // LRU among candidates, and GPU writes around eviction. B gets a GPU upload that marks it
    // current after write epoch 5, in command buffer 4 (A was last used in command buffer 3).
    const uint64_t tex_bytes = tc.GetMemStats().sampled_bytes;
    tc.SetUse(4, 9000 * MS);
    Fill(g, B, 64 * 64 * 4, 0x33);
    TextureCache::GpuUpload up;
    id<MTLTexture> tb = tc.GetTextureForGpuUpload(Tsharp(B, 64, 64), 5, 6, &up);
    check(tb != nil && up.tex == tb, "GPU upload handed out");
    std::vector<TextureCache::WriteRange> w{{B, 64, 5}};
    tc.InvalidateWrites(w);
    check(tc.GetTextureForGpuUpload(Tsharp(B, 64, 64), 5, 7, &up) == tb && up.tex == nil,
          "write epoch 5 retired: the GPU copy made after it stays current");
    // budget of 1.5 textures, low water 1.35: one of the two must go, the least recently used
    const ps4_texcache_policy p15 = small_policy(tex_bytes * 3 / 2);
    TextureCache::EvictResult r = tc.EvictSampled(p15, false, 20000 * MS, 4);
    check(r.count == 1 && tc.GetMemStats().sampled_count == 1, "over the cache budget: one texture evicted");
    check(tc.GetTextureForGpuUpload(Tsharp(B, 64, 64), 5, 7, &up) == tb, "the least recently used (A) went, B stayed");
    // Now B goes too and is re-created by the CPU. Retiring the epoch-5 write again (its
    // completion handler can run late) must make the new entry stale: it has no GPU copy made
    // after that write. That costs one extra upload, never stale contents.
    r = tc.EvictSampled(p, false, 20000 * MS, 4);
    check(r.count == 1 && tc.GetMemStats().sampled_count == 0, "B evicted");
    Fill(g, B, 64 * 64 * 4, 0x44);
    tc.SetUse(5, 21000 * MS);
    id<MTLTexture> tb2 = tc.GetTexture(Tsharp(B, 64, 64));
    check(tb2 != nil && tb2 != tb && FirstByte(tb2) == 0x44, "re-created after eviction: CPU upload of current memory");
    Fill(g, B, 64 * 64 * 4, 0x55);
    tc.InvalidateWrites(w);
    id<MTLTexture> tb3 = tc.GetTexture(Tsharp(B, 64, 64));
    check(tb3 == tb2 && FirstByte(tb3) == 0x55, "late GPU-write retirement re-uploads the re-created texture");

    // GPU-owned surfaces are never evicted, and the range index sees surfaces added after an eviction
    const uint64_t C1 = 0x100000, C2 = 0x200000;
    id<MTLTexture> rt1 = tc.GetColorTarget(Rt(C1), false);
    check(rt1 != nil && tc.GetMemStats().gpu_count == 1, "render target created");
    check(tc.OverlapsGpuTexture(C1, 16) && !tc.OverlapsGpuTexture(C2, 16), "range index: C1 only");
    // entries: sampled B + RT C1 = 2; evict B, then add C2: the count is 2 again
    tc.SetUse(6, 30000 * MS);
    r = tc.EvictSampled(p, true, 60000 * MS, 5);
    check(r.count == 1 && tc.GetMemStats().gpu_count == 1, "GPU budget pressure evicts the sampled texture, not the RT");
    id<MTLTexture> rt2 = tc.GetColorTarget(Rt(C2), false);
    check(rt2 != nil, "second render target created");
    check(tc.OverlapsGpuTexture(C2, 16), "range index rebuilt for a render target added after an eviction");
    check(tc.FindColorTarget(C1) == rt1, "render target kept");
    munmap(g.base, g.size);
}

int main() {
    test_policy_init();
    test_select();
    @autoreleasepool {
        id<MTLDevice> dev = MTLCreateSystemDefaultDevice();
        if (!dev) {
            printf("FAIL: no Metal device\n");
            return 1;
        }
        test_cache(dev);
    }
    printf("tex_evict_test: %s\n", g_fail ? "FAIL" : "PASS");
    return g_fail;
}
