// Texture cache eviction (docs/gpu-memory-budget.md): the policy (ps4_texcache_select and the
// defaults in ps4_gnm_membudget.c) and the real TextureCache (ps4_gnm_resources.mm) on a real
// Metal device over a host buffer standing in for guest memory: which entries go, that a texture
// referenced by a command buffer in flight is never evicted and stays alive until that command
// buffer is done, that its memory is then freed, that an evicted texture comes back with the
// current guest memory, how GPU-write invalidation behaves around eviction, that GPU-owned surfaces
// are evicted only when exactly known writes covered all of their memory after their last use, and
// that the GPU-owned range index notices entries added after an eviction.
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
    check(p.budget == gp.budget / 12, "default cache budget: a twelfth of the GPU budget");
    check(p.low_water == p.budget / 10 * 9, "evicts down to 90% of the cache budget");
    check(p.keep_ns == 2000 * MS, "textures used within 2 s are kept");
    check(p.press_ns == gp.press_ns, "GPU budget pressure keeps the windows' 250 ms");
    ps4_texcache_policy_init(&p, &gp, "512", "500");
    check(p.budget == 512 * MiB && p.keep_ns == 500 * MS, "PS4_GNM_TEX_CACHE_MB=512, PS4_GNM_TEX_KEEP_MS=500");
    ps4_texcache_policy_init(&p, &gp, "0", "5");
    check(p.budget == UINT64_MAX, "PS4_GNM_TEX_CACHE_MB=0: no cache budget");
    check(p.keep_ns == 100 * MS, "keep time clamped to 100 ms");
    ps4_texcache_policy_init(&p, &gp, "x1", "junk");
    check(p.budget == gp.budget / 12 && p.keep_ns == 2000 * MS, "junk values keep the defaults");
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
    // last_ns, last_seq, bytes, id
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

static ColorTarget Rt(uint64_t addr, uint32_t height = 64, uint32_t mtl_format = MTLPixelFormatRGBA8Unorm,
                      uint32_t num_slices = 1, uint32_t base_slice = 0) {
    ColorTarget c;
    c.bound = true;
    c.address = addr;
    c.pitch = 64;
    c.height = height;
    c.slice_bytes = 64 * height * 4;
    c.num_slices = num_slices;
    c.base_slice = base_slice;
    c.num_samples = 1;
    c.bpp = 32;
    c.dfmt = DataFormat::Format8_8_8_8;
    c.nfmt = NumberFormat::Unorm;
    c.mtl_format = mtl_format;
    c.tile_mode = TileMode::DisplayLinearAligned;
    return c;
}

static DepthTarget Db(uint64_t addr, uint32_t slices) {
    DepthTarget d;
    d.bound = true;
    d.z_read_address = addr;
    d.pitch = 64;
    d.height = 64;
    d.slice_bytes = 64 * 64 * 4;
    d.num_slices = slices;
    d.num_samples = 1;
    d.bpp = 32;
    d.mtl_format = MTLPixelFormatDepth32Float;
    return d;
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

    // the range index sees GPU-owned surfaces added after an eviction
    const uint64_t C1 = 0x100000, C2 = 0x200000;
    @autoreleasepool { // returned textures may be autoreleased: the freed check below runs after the pool
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
    }
    munmap(g.base, g.size);
}

// Superseded GPU-owned surfaces: only when exactly known writes (clears, compute copies) of other
// surfaces covered all of their memory after their last use. Draws and storage stores never count:
// which bytes they write is unknown. Each case uses its own addresses; command buffer n is open at n s.
static void test_superseded(id<MTLDevice> dev) {
    id<MTLCommandQueue> q = [dev newCommandQueue];
    const uint64_t size = 64 * MiB;
    uint8_t* base = (uint8_t*)mmap(nullptr, size, PROT_READ | PROT_WRITE, MAP_ANON | MAP_PRIVATE, -1, 0);
    TextureCache tc(dev, q, base, size);
    auto at = [&](uint64_t seq) { tc.SetUse(seq, seq * 1000 * MS); };
    const uint32_t BGRA = MTLPixelFormatBGRA8Unorm;
    const uint64_t K16 = 64 * 64 * 4; // one 64x64 RGBA8 slice
    // a clear of slice `slice` of a color target, as draw.mm's NoteClearedColor credits it
    auto clear_slice = [&](const ColorTarget& c, id<MTLTexture> t, uint32_t slice) {
        const uint64_t lo = c.address + (uint64_t)slice * c.slice_bytes;
        return tc.NoteExactWrite(c.address, t, lo, lo + c.slice_bytes);
    };
    auto evict_all_idle = [&](uint64_t now_s, uint64_t completed) {
        return tc.EvictSuperseded(1000 * MS, now_s * 1000 * MS, completed);
    };
    std::vector<id<MTLTexture>> retired;
    __weak id<MTLTexture> weak_a1 = nil;
    @autoreleasepool {
        // 1: the same memory used as another surface. Drawing to it proves nothing; a clear does.
        const uint64_t X1 = 0x100000;
        at(1);
        id<MTLTexture> a1 = tc.GetColorTarget(Rt(X1), false);
        at(2);
        id<MTLTexture> b1 = tc.GetColorTarget(Rt(X1, 64, BGRA), false);
        check(evict_all_idle(5, 4).count == 0 && tc.FindColorTarget(X1, 64, 64) != nil,
              "case 1: a newer surface only drawn to does not supersede");
        at(6);
        check(clear_slice(Rt(X1, 64, BGRA), b1, 0), "case 1: clear of the newer surface noted");
        check(tc.GetGpuOwnedStats(1000 * MS).superseded_count == 1, "case 1: the older one counts as superseded");
        check(evict_all_idle(8, 0).count == 0, "case 1: its own last command buffer in flight: kept");
        check(tc.EvictSuperseded(20000 * MS, 8000 * MS, 6).count == 0, "case 1: used within the idle time: kept");
        weak_a1 = a1;
        a1 = nil;
        check(evict_all_idle(8, 2).count == 1, "case 1: cleared over after its last use: evicted");
        tc.TakeRetired(&retired);
        check(retired.size() == 1 && retired[0] == weak_a1, "case 1: evicted texture handed to the renderer");
        check(tc.OverlapsGpuTexture(X1, 16), "case 1: the newer surface stays in the range index");
        retired.clear();
    }
    check(weak_a1 == nil, "case 1: freed once the renderer dropped it");

    @autoreleasepool {
        // 2: the older surface is used again after the newer one was cleared (review I1)
        const uint64_t X2 = 0x200000;
        at(10);
        id<MTLTexture> a2 = tc.GetColorTarget(Rt(X2), false);
        at(11);
        clear_slice(Rt(X2, 64, BGRA), tc.GetColorTarget(Rt(X2, 64, BGRA), false), 0);
        at(12);
        check(tc.GetColorTarget(Rt(X2), false) == a2, "case 2: older surface rendered again");
        // 3: partial cover keeps the older surface (its first 4 KiB were not overwritten)
        const uint64_t X3 = 0x300000;
        at(13);
        id<MTLTexture> a3 = tc.GetColorTarget(Rt(X3), false);
        at(14);
        clear_slice(Rt(X3 + 0x1000), tc.GetColorTarget(Rt(X3 + 0x1000), false), 0);
        // 4: a newer surface starting before the older one and covering it (backward overlap)
        const uint64_t X4 = 0x400000, X5 = 0x500000;
        at(15);
        id<MTLTexture> a4 = tc.GetColorTarget(Rt(X4), false);
        id<MTLTexture> a5 = tc.GetColorTarget(Rt(X5), false);
        at(16);
        clear_slice(Rt(X4 - 0x1000, 128), tc.GetColorTarget(Rt(X4 - 0x1000, 128), false), 0);
        clear_slice(Rt(X5 - 0x1000, 128), tc.GetColorTarget(Rt(X5 - 0x1000, 128), false), 0);
        at(17);
        check(tc.FindColorTarget(X5) == a5, "case 4: X5 read again after the cover was cleared");
        // 5: both used by the same command buffer: order unknown, kept
        const uint64_t X6 = 0x600000;
        at(18);
        id<MTLTexture> a6 = tc.GetColorTarget(Rt(X6), false);
        clear_slice(Rt(X6, 64, BGRA), tc.GetColorTarget(Rt(X6, 64, BGRA), false), 0);
        // 6: a depth array over a render target, never cleared, grows
        const uint64_t Y = 0x700000;
        at(19);
        id<MTLTexture> ay = tc.GetColorTarget(Rt(Y), false);
        at(20);
        id<MTLTexture> dy = tc.GetDepthTarget(Db(Y, 1));
        at(21);
        id<MTLTexture> grown_from = nil;
        id<MTLTexture> dy2 = tc.GetDepthTarget(Db(Y, 2), &grown_from);
        check(dy && dy2 && dy2 != dy && grown_from == dy, "case 6: depth array grew");
        tc.TakeRetired(&retired);
        check(retired.size() == 1 && retired[0] == dy, "case 6: the replaced depth texture is handed to the renderer");
        retired.clear();
        // 7: compute copies into older surfaces' memory: read after (Z2), only half (Z3), whole (Z4)
        const uint64_t Z1 = 0x800000, Z2 = 0x900000, Z3 = 0xA00000, Z4 = 0xB00000;
        at(22);
        tc.GetColorTarget(Rt(Z1), false);
        id<MTLTexture> az2 = tc.GetColorTarget(Rt(Z2, 64, BGRA), false);
        id<MTLTexture> az3 = tc.GetColorTarget(Rt(Z3, 64, BGRA), false);
        id<MTLTexture> az4 = tc.GetColorTarget(Rt(Z4, 64, BGRA), false);
        at(23);
        id<MTLTexture> cs = nil, cd = nil;
        int kind = 0;
        check(tc.CloneGpuTexture(Z1, Z2, K16, &cs, &cd, &kind) && cd && cd != az2, "case 7: whole surface copied to Z2");
        check(tc.CloneGpuTexture(Z1, Z3, K16 / 2, &cs, &cd, &kind), "case 7: half a surface copied to Z3");
        check(tc.CloneGpuTexture(Z1, Z4, K16, &cs, &cd, &kind), "case 7: whole surface copied to Z4");
        at(24);
        check(tc.GetColorTarget(Rt(Z2, 64, BGRA), false) == az2, "case 7: Z2's older surface read after the copy");
        // 8: a slice view: clearing slice 1 of an array leaves slice 0's older surface alone (review I1-R)
        const uint64_t X7 = 0xC00000;
        at(25);
        id<MTLTexture> a7 = tc.GetColorTarget(Rt(X7), false);
        at(26);
        const ColorTarget arr = Rt(X7, 64, BGRA, 2, 1);
        check(clear_slice(arr, tc.GetColorTarget(arr, false), 1), "case 8: slice 1 of the array cleared");
        // 9: depth array: a clear of slice 1 keeps the color surface aliasing slice 0
        const uint64_t Y2 = 0xD00000;
        at(27);
        id<MTLTexture> ay2 = tc.GetColorTarget(Rt(Y2), false);
        at(28);
        id<MTLTexture> dz = tc.GetDepthTarget(Db(Y2, 2));
        check(tc.NoteExactWrite(Y2, dz, Y2 + K16, Y2 + 2 * K16), "case 9: depth slice 1 cleared");
        // 10: a storage image bound to a larger existing surface: stores are not exact writes. The
        // older surface is a depth target, so the storage bind can only match the larger color one.
        const uint64_t W1 = 0xE00000;
        at(29);
        id<MTLTexture> aw = tc.GetDepthTarget(Db(W1, 1));
        at(30);
        tc.GetColorTarget(Rt(W1, 128, BGRA), false);
        at(31);
        ImageDesc st = Tsharp(W1, 64, 64);
        id<MTLTexture> stex = tc.GetStorageTexture(st);
        check(stex != nil && stex != aw, "case 10: storage image bound to the larger color surface over W1");
        // 11: unions of covers: two halves (evicted), the same half twice (kept), a 256-byte gap (kept)
        const uint64_t U1 = 0xF00000, U2 = 0x1000000, U3 = 0x1100000, H = K16 / 2;
        at(32);
        tc.GetColorTarget(Rt(U1), false);
        id<MTLTexture> au2 = tc.GetColorTarget(Rt(U2), false);
        id<MTLTexture> au3 = tc.GetColorTarget(Rt(U3), false);
        at(33);
        auto half = [&](uint64_t addr) { clear_slice(Rt(addr, 32, BGRA), tc.GetColorTarget(Rt(addr, 32, BGRA), false), 0); };
        half(U1);
        half(U1 + H);
        half(U2);
        clear_slice(Rt(U2, 32, MTLPixelFormatRGBA8Unorm_sRGB), tc.GetColorTarget(Rt(U2, 32, MTLPixelFormatRGBA8Unorm_sRGB), false), 0);
        half(U3);
        half(U3 + H + 256);

        // one pass: everything idle for 1 s, all command buffers complete
        const uint64_t before = tc.GetMemStats().gpu_count;
        TextureCache::EvictResult r = evict_all_idle(60, 40);
        check(tc.GetColorTarget(Rt(X2), false) == a2, "case 2: surface used after the newer one was cleared is kept");
        check(tc.FindColorTarget(X3) == a3, "case 3: partially covered surface kept");
        check(tc.FindColorTarget(X4) == nil && a4 != nil, "case 4: surface covered by a newer one starting before it is evicted");
        check(tc.FindColorTarget(X5) == a5, "case 4: covered surface read after the cover was cleared is kept");
        check(tc.FindColorTarget(X6, 64, 64) != nil && a6 != nil && tc.GetColorTarget(Rt(X6), false) == a6,
              "case 5: same command buffer: kept");
        check(tc.FindColorTarget(Y) == ay && tc.FindDepthTarget(Y) == dy2,
              "case 6: render target under a depth array that grew (never cleared) is kept");
        check(tc.GetColorTarget(Rt(Z2, 64, BGRA), false) == az2, "case 7: Z2: read after the copy: kept");
        check(tc.GetColorTarget(Rt(Z3, 64, BGRA), false) == az3, "case 7: Z3: only half overwritten: kept");
        check(az4 != nil, "case 7: Z4 had a surface");
        check(tc.GetColorTarget(Rt(X7), false) == a7, "case 8: slice-0 surface under a slice-1 clear kept");
        check(tc.GetColorTarget(Rt(Y2), false) == ay2, "case 9: color alias of depth slice 0 kept under a slice-1 clear");
        check(tc.FindDepthTarget(W1) == aw, "case 10: surface under a storage image bind kept");
        check(tc.GetColorTarget(Rt(U2), false) == au2, "case 11: the same half covered twice: kept");
        check(tc.GetColorTarget(Rt(U3), false) == au3, "case 11: two halves with a gap: kept");
        // evicted: case 4's X4, case 7's Z4 surface, case 11's U1 surface
        check(r.count == 3 && tc.GetMemStats().gpu_count == before - 3, "exactly three surfaces evicted (X4, Z4, U1)");
        tc.TakeRetired(&retired);
        check(retired.size() == 3, "all three handed to the renderer");
        retired.clear();
        // case 9, second step: slice 0 cleared too, after the color alias's last use (61)
        at(62);
        check(tc.NoteExactWrite(Y2, dz, Y2, Y2 + K16), "case 9: depth slice 0 cleared");
        r = evict_all_idle(70, 62);
        check(r.count == 1 && tc.FindDepthTarget(Y2) == dz, "case 9: color alias of slice 0 evicted once slice 0 is cleared");
        tc.TakeRetired(&retired);
        retired.clear();
    }
    munmap(base, size);
}

// Buffer writes over GPU-owned surfaces (TextureCache::NoteBufferWrite): a surface is marked guest
// newer only when exactly known writes since its last GPU write cover all of it; a GPU write in
// between starts the cover again; a mark is taken once; an evicted or cleared marked surface does
// not leave the marked count behind (the renderer's fast path checks it before every lookup).
static void test_guest_newer(id<MTLDevice> dev) {
    id<MTLCommandQueue> q = [dev newCommandQueue];
    const uint64_t size = 256 * MiB; // several 64 MiB hint granules
    uint8_t* base = (uint8_t*)mmap(nullptr, size, PROT_READ | PROT_WRITE, MAP_ANON | MAP_PRIVATE, -1, 0);
    TextureCache tc(dev, q, base, size);
    auto at = [&](uint64_t seq) { tc.SetUse(seq, seq * 1000 * MS); };
    const uint64_t K16 = 64 * 64 * 4, H = K16 / 2;
    @autoreleasepool {
        const uint64_t A = 0x100000, B = 0x200000, C = 0x300000;
        at(1);
        id<MTLTexture> ta = tc.GetColorTarget(Rt(A), false);
        id<MTLTexture> tb = tc.GetColorTarget(Rt(B), false);
        tc.GetColorTarget(Rt(C), false);
        // A: two halves, the second starting before the first ends, cover it together
        tc.NoteBufferWrite(A, H + 16, 1);
        check(tc.GuestNewerCount() == 0 && tc.GetGuestNewerStats().partial == 1, "half of A: not marked, partial");
        tc.NoteBufferWrite(A + H, H, 2);
        check(tc.GuestNewerCount() == 1 && tc.GetGuestNewerStats().marked == 1, "both halves of A: marked");
        // B: a draw between the halves: the first half no longer describes its contents
        tc.NoteBufferWrite(B, H, 3);
        tc.GetColorTarget(Rt(B), false);
        tc.NoteBufferWrite(B + H, H, 4);
        check(tc.GuestNewerCount() == 1, "B drawn between its halves: not marked");
        // one write covering B and C marks both
        tc.NoteBufferWrite(B - 0x1000, C + K16 - B + 0x2000, 5);
        check(tc.GuestNewerCount() == 3, "one write over B and C: both marked");
        // the refresh is handed out with the surface's own layout; the mark goes only once the copy
        // was encoded, a copy that could not be encoded leaves it marked
        TextureCache::GpuUpload up;
        check(tc.TakeGuestNewer(A, ta, &up) && up.tex == ta && up.width == 64 && up.height == 64 &&
                  up.layout.total_size == K16,
              "A's refresh handed out");
        tc.FinishGuestNewer(A, ta, false, false);
        check(tc.GuestNewerCount() == 3 && tc.GetGuestNewerStats().failed == 1,
              "A's copy not encoded before a read-only use: still marked");
        check(tc.TakeGuestNewer(A, ta, &up) && up.tex == ta, "A's refresh handed out again");
        tc.FinishGuestNewer(A, ta, true, false);
        check(!tc.TakeGuestNewer(A, ta, &up) && up.tex == nil && tc.GuestNewerCount() == 2 &&
                  tc.GetGuestNewerStats().refreshed == 1,
              "A's mark gone once its copy was encoded");
        check(!tc.TakeGuestNewer(B, ta, &up), "B's mark not taken for another texture");
        check(tc.TakeGuestNewer(B, nil, &up) && up.tex == tb, "B's mark taken for any texture at B");
        // B's copy cannot be encoded before a GPU write of B (a render-target bind): the mark goes, so
        // no later refresh attempt copies the older guest bytes over what the GPU wrote
        tc.FinishGuestNewer(B, tb, false, true);
        check(tc.GuestNewerCount() == 1 && tc.GetGuestNewerStats().failed == 2 &&
                  tc.GetGuestNewerStats().refreshed == 1,
              "B's copy not encoded before a GPU write: unmarked, counted as failed");
        check(!tc.TakeGuestNewer(B, nil, &up) && up.tex == nil, "B: a later refresh attempt has nothing to copy");
        // a write nowhere near a GPU-owned surface (another 64 MiB granule) is dropped before the lock
        const uint64_t partial = tc.GetGuestNewerStats().partial;
        tc.NoteBufferWrite(0x8000000, K16, 7);
        check(tc.GetGuestNewerStats().partial == partial && tc.GuestNewerCount() == 1, "a write far from every surface");
        // a surface created in a granule no surface was in before: its creation sets the granule's
        // hint, so a write over it is not dropped before the lock
        const uint64_t D = 0xc100000;
        id<MTLTexture> td = tc.GetColorTarget(Rt(D), false);
        tc.NoteBufferWrite(D, K16, 8);
        check(td != nil && tc.GuestNewerCount() == 2 && tc.TakeGuestNewer(D, td, &up) && up.tex == td,
              "a surface in a fresh granule: marked");
        tc.FinishGuestNewer(D, td, true, false);
        // C stays marked and is superseded (a newer surface at C cleared after C's last use): evicting
        // it drops its mark
        at(2);
        id<MTLTexture> c2 = tc.GetColorTarget(Rt(C, 64, MTLPixelFormatBGRA8Unorm), false);
        at(3);
        check(tc.NoteExactWrite(C, c2, C, C + K16), "the newer surface at C cleared");
        check(tc.GuestNewerCount() == 1, "C still marked before the eviction");
        check(tc.EvictSuperseded(1000 * MS, 10000 * MS, 3).count == 1, "C evicted");
        check(tc.GuestNewerCount() == 0, "evicted marked surface: marked count back to 0");
        // Clear drops every mark
        tc.NoteBufferWrite(A, K16, 6);
        check(tc.GuestNewerCount() == 1, "A marked again");
        std::vector<id<MTLTexture>> retired;
        tc.TakeRetired(&retired);
        tc.Clear();
        check(tc.GuestNewerCount() == 0, "Clear: marked count 0");
    }
    munmap(base, size);
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
        test_superseded(dev);
        test_guest_newer(dev);
    }
    printf("tex_evict_test: %s\n", g_fail ? "FAIL" : "PASS");
    return g_fail;
}
