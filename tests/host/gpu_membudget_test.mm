// GPU memory accounting and budget decisions (ps4_gnm_membudget.h), checked against the real
// system: the hole check against mappings with unmapped, read-only and remapped pages and against
// what newBufferWithBytesNoCopy accepts; the accounting assumptions (currentAllocatedSize counts
// every no-copy length, GPU use wires the whole range) against Metal itself.
#import <Metal/Metal.h>
#include <mach/mach.h>
#include <mach/mach_vm.h>
#include <stdio.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>

#include "ps4_gnm_membudget.h"

static int g_fail;

static void check(int ok, const char *what) {
    printf("%s: %s\n", ok ? "ok" : "FAIL", what);
    if (!ok) g_fail = 1;
}

static const uint64_t MiB = 1ull << 20, GiB = 1ull << 30;

static void test_policy(void) {
    ps4_gpumem_policy p;
    ps4_gpumem_policy_init(&p, 16 * GiB, NULL, NULL, NULL);
    check(p.budget == 16 * GiB / 100 * 40, "default budget is 40% of RAM");
    check(p.nocopy_max == GiB, "no-copy ranges up to 1 GiB");
    check(p.idle_ns == 30000000000ull, "idle windows released after 30 s");
    ps4_gpumem_policy_init(&p, 16 * GiB, "25", NULL, NULL);
    check(p.budget == 16 * GiB / 100 * 25, "PS4_GNM_GPU_BUDGET_PCT=25");
    ps4_gpumem_policy_init(&p, 16 * GiB, "1", NULL, NULL);
    check(p.budget == 16 * GiB / 100 * 5, "percentage clamped to 5");
    ps4_gpumem_policy_init(&p, 16 * GiB, "99", NULL, NULL);
    check(p.budget == 16 * GiB / 100 * 90, "percentage clamped to 90");
    ps4_gpumem_policy_init(&p, 16 * GiB, "25", "3000", NULL);
    check(p.budget == 3000 * MiB, "PS4_GNM_GPU_BUDGET_MB wins over the percentage");
    ps4_gpumem_policy_init(&p, 16 * GiB, "x", "12x", NULL);
    check(p.budget == 16 * GiB / 100 * 40, "junk MB and junk percentage keep the 40% default");
    ps4_gpumem_policy_init(&p, 0, NULL, NULL, NULL);
    check(p.budget == UINT64_MAX, "unknown RAM size: no budget");
    ps4_gpumem_policy_init(&p, 0, NULL, "2048", NULL);
    check(p.budget == 2048 * MiB, "unknown RAM size: the MB value still applies");
    ps4_gpumem_policy_init(&p, 16 * GiB, NULL, NULL, "0");
    check(p.idle_ns == 0, "PS4_GNM_GPU_WINDOW_IDLE_S=0 disables idle release");
    ps4_gpumem_policy_init(&p, 16 * GiB, NULL, NULL, "5");
    check(p.idle_ns == 5000000000ull, "idle 5 s");
    ps4_gpumem_policy_init(&p, 16 * GiB, NULL, NULL, "abc");
    check(p.idle_ns == 30000000000ull, "junk idle keeps the default");
}

static void test_decisions(void) {
    ps4_gpumem_policy p;
    ps4_gpumem_policy_init(&p, 16 * GiB, NULL, NULL, NULL);
    check(ps4_gpumem_admit_nocopy(&p, 64 * MiB, 0) == PS4_GPUMEM_ADMIT, "64 MiB plain range admitted");
    check(ps4_gpumem_admit_nocopy(&p, GiB, 0) == PS4_GPUMEM_ADMIT, "exactly 1 GiB admitted");
    check(ps4_gpumem_admit_nocopy(&p, GiB + 16384, 0) == PS4_GPUMEM_REFUSE_TOO_LARGE, "over 1 GiB refused");
    check(ps4_gpumem_admit_nocopy(&p, 64 * MiB, 1) == PS4_GPUMEM_REFUSE_HOLES, "range with holes refused");
    check(ps4_gpumem_admit_nocopy(&p, 2 * GiB, 1) == PS4_GPUMEM_REFUSE_TOO_LARGE, "size checked first");

    const uint64_t s = 1000000000ull;
    check(!ps4_gpumem_should_release(&p, 100 * s, 80 * s, 0), "20 s idle kept under budget");
    check(ps4_gpumem_should_release(&p, 100 * s, 70 * s, 0), "30 s idle released");
    check(!ps4_gpumem_should_release(&p, 100 * s, 100 * s - 100000000ull, 1), "used 100 ms ago kept over budget");
    check(ps4_gpumem_should_release(&p, 100 * s, 99 * s, 1), "1 s idle released over budget");
    check(!ps4_gpumem_should_release(&p, 100 * s, 101 * s, 1), "use stamped after now is kept");
    ps4_gpumem_policy_init(&p, 16 * GiB, NULL, NULL, "0");
    check(!ps4_gpumem_should_release(&p, 1000 * s, 0, 0), "idle release off: kept under budget");
    check(ps4_gpumem_should_release(&p, 1000 * s, 0, 1), "idle release off: still released over budget");

    ps4_gpumem_policy_init(&p, 10 * GiB, "40", NULL, NULL); // budget 4 GiB
    ps4_gpumem_budget_state st = {0, 0};
    check(ps4_gpumem_budget_update(&st, &p, 3 * GiB) == 0 && !st.over, "under budget");
    check(ps4_gpumem_budget_update(&st, &p, 5 * GiB) == 1 && st.over && st.times_over == 1, "goes over");
    check(ps4_gpumem_budget_update(&st, &p, 6 * GiB) == 0, "stays over without a new transition");
    check(ps4_gpumem_budget_update(&st, &p, p.budget - MiB) == 0 && st.over, "just under the budget: still over");
    check(ps4_gpumem_budget_update(&st, &p, p.budget / 10 * 9 - MiB) == -1 && !st.over, "under 90%: recovered");
    check(ps4_gpumem_budget_update(&st, &p, p.budget + 1) == 1 && st.times_over == 2, "second transition counted");

    ps4_gpumem_sample a;
    memset(&a, 0, sizeof(a));
    a.device = 3000 * MiB;
    a.nocopy_sum = 2000 * MiB;
    a.nocopy_distinct = 1200 * MiB;
    check(ps4_gpumem_charged(&a) == 2200 * MiB, "charged = own allocations + distinct no-copy coverage");
    a.device = 100 * MiB; // sampled while a buffer was being added
    check(ps4_gpumem_charged(&a) == 1200 * MiB, "no underflow when no-copy sum exceeds the device total");
}

static void test_log_rate(void) {
    ps4_gpumem_log_state st;
    memset(&st, 0, sizeof(st));
    ps4_gpumem_sample s;
    memset(&s, 0, sizeof(s));
    const uint64_t sec = 1000000000ull, step = 256 * MiB;
    s.t_ns = 5 * sec;
    s.wired = 2 * GiB;
    check(ps4_gpumem_log_due(&st, &s, 10 * sec, step), "first sample logs");
    s.t_ns = 6 * sec;
    check(!ps4_gpumem_log_due(&st, &s, 10 * sec, step), "1 s later, unchanged: quiet");
    s.wired += 255 * MiB;
    check(!ps4_gpumem_log_due(&st, &s, 10 * sec, step), "growth below the step: quiet");
    s.wired += MiB;
    check(ps4_gpumem_log_due(&st, &s, 10 * sec, step), "wired grew by the step: logs");
    s.t_ns = 7 * sec;
    s.wired -= GiB;
    check(!ps4_gpumem_log_due(&st, &s, 10 * sec, step), "shrinking does not log");
    s.nocopy_distinct = 300 * MiB;
    check(ps4_gpumem_log_due(&st, &s, 10 * sec, step), "no-copy coverage grew: logs");
    s.t_ns = 17 * sec;
    check(ps4_gpumem_log_due(&st, &s, 10 * sec, step), "period elapsed: logs");
    s.t_ns = 18 * sec;
    s.device = 300 * MiB;
    check(ps4_gpumem_log_due(&st, &s, 10 * sec, step), "device grew: logs");
    s.footprint = 300 * MiB;
    check(ps4_gpumem_log_due(&st, &s, 10 * sec, step), "footprint grew: logs");
}

static void test_windows(void) {
    ps4_gpumem_windows w;
    check(ps4_gpumem_windows_init(&w, 512 * GiB, 64 * MiB) && w.nwin == 8192, "8192 windows over 512 GiB");
    ps4_gpumem_sample s;
    ps4_gpumem_windows_add(&w, 3, 1, 64 * MiB);
    ps4_gpumem_windows_add(&w, 3, 2, 128 * MiB); // overlaps window 3
    ps4_gpumem_windows_add(&w, 10, 1, 64 * MiB);
    ps4_gpumem_windows_read(&w, &s);
    check(s.nocopy_count == 3 && s.nocopy_sum == 256 * MiB && s.nocopy_distinct == 192 * MiB,
          "3 buffers, 256 MiB sum, 3 distinct windows");
    ps4_gpumem_windows_remove(&w, 3, 1, 64 * MiB);
    ps4_gpumem_windows_read(&w, &s);
    check(s.nocopy_count == 2 && s.nocopy_sum == 192 * MiB && s.nocopy_distinct == 192 * MiB,
          "window 3 still covered by the spanning buffer");
    ps4_gpumem_windows_remove(&w, 3, 2, 128 * MiB);
    ps4_gpumem_windows_read(&w, &s);
    check(s.nocopy_count == 1 && s.nocopy_sum == 64 * MiB && s.nocopy_distinct == 64 * MiB, "only window 10 left");
    ps4_gpumem_windows_add(&w, 8191, 4, 64 * MiB); // clipped at the end of guest memory
    ps4_gpumem_windows_read(&w, &s);
    check(s.nocopy_distinct == 128 * MiB, "span past the last window is clipped");
    ps4_gpumem_windows_remove(&w, 8191, 4, 64 * MiB);
    ps4_gpumem_windows_remove(&w, 10, 1, 64 * MiB);
    ps4_gpumem_windows_remove(&w, 10, 1, 64 * MiB); // unbalanced remove must not wrap
    ps4_gpumem_windows_read(&w, &s);
    check(s.nocopy_count == 0 && s.nocopy_sum == 0 && s.nocopy_distinct == 0, "empty, no wrap-around");
    ps4_gpumem_windows_free(&w);
}

struct Pieces {
    uint64_t off[8], n[8];
    int count;
};
static void note_piece(void *ctx, uint64_t off, uint64_t n) {
    Pieces *p = (Pieces *)ctx;
    if (p->count < 8) {
        p->off[p->count] = off;
        p->n[p->count] = n;
    }
    p->count++;
}

static void test_holes(id<MTLDevice> dev) {
    const uint64_t pg = 16384, len = 64 * pg;
    uint8_t *m = (uint8_t *)mmap(NULL, len, PROT_READ | PROT_WRITE, MAP_ANON | MAP_PRIVATE, -1, 0);
    check(m != MAP_FAILED, "mmap");
    check(!ps4_gpumem_range_has_holes(m, len), "plain anonymous mapping has no holes");
    // another mapping remapped into the middle (like direct memory): separate VM regions, no hole
    uint8_t *phys = (uint8_t *)mmap(NULL, 4 * pg, PROT_READ | PROT_WRITE, MAP_ANON | MAP_SHARED, -1, 0);
    mach_vm_address_t target = (mach_vm_address_t)(uintptr_t)(m + 8 * pg);
    vm_prot_t cur, max;
    check(mach_vm_remap(mach_task_self(), &target, 4 * pg, 0, VM_FLAGS_FIXED | VM_FLAGS_OVERWRITE, mach_task_self(),
                        (mach_vm_address_t)(uintptr_t)phys, FALSE, &cur, &max, VM_INHERIT_SHARE) == KERN_SUCCESS,
          "mach_vm_remap into the range");
    check(!ps4_gpumem_range_has_holes(m, len), "remapped pages are not a hole");
    id<MTLBuffer> ok = [dev newBufferWithBytesNoCopy:m length:len options:MTLResourceStorageModeShared deallocator:nil];
    check(ok != nil, "Metal agrees: no-copy buffer over the remapped range is created");
    ok = nil;

    check(mprotect(m + 20 * pg, pg, PROT_READ) == 0, "mprotect one page read-only");
    check(ps4_gpumem_range_has_holes(m, len), "read-only page is a hole");
    check(!ps4_gpumem_range_has_holes(m, 20 * pg), "range ending before it has none");
    check(!ps4_gpumem_range_has_holes(m + 21 * pg, len - 21 * pg), "range starting after it has none");
    mprotect(m + 20 * pg, pg, PROT_READ | PROT_WRITE);

    check(munmap(m + 40 * pg, 2 * pg) == 0, "unmap two pages");
    check(ps4_gpumem_range_has_holes(m, len), "unmapped pages are a hole");
    id<MTLBuffer> bad = [dev newBufferWithBytesNoCopy:m length:len options:MTLResourceStorageModeShared deallocator:nil];
    check(bad == nil, "Metal agrees: no-copy buffer over the hole fails");
    check(munmap(m + 60 * pg, 4 * pg) == 0, "unmap the tail");
    check(ps4_gpumem_range_has_holes(m + 50 * pg, 14 * pg), "range running into unmapped tail has a hole");

    Pieces pc;
    memset(&pc, 0, sizeof(pc));
    check(mprotect(m + 30 * pg, pg, PROT_NONE) == 0, "PROT_NONE page");
    const uint64_t readable = ps4_gpumem_for_each_readable(m, len, note_piece, &pc);
    check(readable == len - pg - 2 * pg - 4 * pg, "readable bytes exclude PROT_NONE and unmapped pages");
    // pieces may be split by region boundaries (the remap); join adjacent ones and compare
    uint64_t joined_off[8], joined_n[8];
    int nj = 0;
    for (int i = 0; i < pc.count && i < 8; ++i) {
        if (nj && joined_off[nj - 1] + joined_n[nj - 1] == pc.off[i]) joined_n[nj - 1] += pc.n[i];
        else {
            joined_off[nj] = pc.off[i];
            joined_n[nj++] = pc.n[i];
        }
    }
    check(nj == 3 && joined_off[0] == 0 && joined_n[0] == 30 * pg && joined_off[1] == 31 * pg &&
              joined_n[1] == 9 * pg && joined_off[2] == 42 * pg && joined_n[2] == 18 * pg,
          "readable pieces: [0,30) [31,40) [42,60) pages");
    munmap(m, len);
    munmap(phys, 4 * pg);
}

// The accounting rests on two facts of Metal on Apple silicon; if either changes, the charged
// formula is wrong, so they are checked here.
static void test_metal_accounting(id<MTLDevice> dev) {
    const uint64_t len = 512 * MiB;
    uint8_t *m = (uint8_t *)mmap(NULL, 2 * len, PROT_READ | PROT_WRITE, MAP_ANON | MAP_PRIVATE, -1, 0);
    const uint64_t dev0 = dev.currentAllocatedSize;
    id<MTLBuffer> a = [dev newBufferWithBytesNoCopy:m length:len options:MTLResourceStorageModeShared deallocator:nil];
    id<MTLBuffer> b = [dev newBufferWithBytesNoCopy:m length:2 * len options:MTLResourceStorageModeShared deallocator:nil];
    const uint64_t dev1 = dev.currentAllocatedSize;
    check(dev1 - dev0 >= 3 * len && dev1 - dev0 < 3 * len + 64 * MiB,
          "currentAllocatedSize counts every no-copy length, overlapping ones again");
    check(b.length == 2 * len, "spanning buffer length");
    b = nil;

    // first GPU use wires the whole range, although the guest never touched it
    id<MTLCommandQueue> q = [dev newCommandQueue];
    NSError *err = nil;
    id<MTLLibrary> lib = [dev newLibraryWithSource:@"kernel void k(device uint *b [[buffer(0)]], uint i "
                                                    "[[thread_position_in_grid]]) { b[i * 4096] += 1; }"
                                           options:nil
                                             error:&err];
    id<MTLComputePipelineState> pso = [dev newComputePipelineStateWithFunction:[lib newFunctionWithName:@"k"] error:&err];
    // The driver wires and unwires asynchronously (sometimes only after the command buffer has
    // completed), and other processes move the system-wide count too: poll for up to 3 s and
    // demand most of the range, in up to 3 rounds.
    auto poll = [](uint64_t from, bool up, uint64_t want) {
        uint64_t best = 0;
        for (int i = 0; i < 60; ++i) {
            const uint64_t w = ps4_gpumem_wired_bytes();
            const uint64_t d = up ? (w > from ? w - from : 0) : (from > w ? from - w : 0);
            best = d > best ? d : best;
            if (best >= want) break;
            usleep(50000);
        }
        return best;
    };
    int wired_seen = 0, unwired_seen = 0;
    for (int round = 0; round < 3 && !(wired_seen && unwired_seen); ++round) {
        if (!a) a = [dev newBufferWithBytesNoCopy:m length:len options:MTLResourceStorageModeShared deallocator:nil];
        usleep(200000);
        const uint64_t w0 = ps4_gpumem_wired_bytes();
        id<MTLCommandBuffer> cb = [q commandBuffer];
        id<MTLComputeCommandEncoder> ce = [cb computeCommandEncoder];
        [ce setComputePipelineState:pso];
        [ce setBuffer:a offset:0 atIndex:0];
        [ce dispatchThreads:MTLSizeMake(4, 1, 1) threadsPerThreadgroup:MTLSizeMake(4, 1, 1)];
        [ce endEncoding];
        [cb commit];
        [cb waitUntilCompleted];
        cb = nil;
        const uint64_t up = poll(w0, true, len * 6 / 10);
        const uint64_t w1 = ps4_gpumem_wired_bytes();
        a = nil;
        const uint64_t down = poll(w1, false, len * 6 / 10);
        printf("  round %d: wired +%llu MiB after the GPU used a 512 MiB untouched no-copy buffer, "
               "-%llu MiB after its release\n", round, (unsigned long long)(up / MiB), (unsigned long long)(down / MiB));
        wired_seen |= up >= len * 6 / 10;
        unwired_seen |= up >= len * 6 / 10 && down >= len * 6 / 10;
    }
    check(wired_seen, "GPU use wires the whole no-copy range");
    check(unwired_seen, "releasing the buffer unwires it");
    munmap(m, 2 * len);
}

int main(void) {
    @autoreleasepool {
        id<MTLDevice> dev = MTLCreateSystemDefaultDevice();
        if (!dev) {
            printf("FAIL: no Metal device\n");
            return 1;
        }
        test_policy();
        test_decisions();
        test_log_rate();
        test_windows();
        test_holes(dev);
        test_metal_accounting(dev);
        check(ps4_gpumem_mem_total() >= 4 * GiB, "hw.memsize read");
        check(ps4_gpumem_footprint_bytes() > 0, "phys_footprint read");
    }
    printf("gpu_membudget_test: %s\n", g_fail ? "FAIL" : "PASS");
    return g_fail;
}
