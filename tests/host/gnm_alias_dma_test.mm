// Guest windows that alias, through the renderer (docs/gnm-ordering.md, "Aliasing guest windows"; the GPU
// side of the ordering is gnm_backend_alias_test). GPU DMAs (ps4draw::GpuDma) bind guest memory
// through GuestBuffer's windows: a fill of a range crossing the first 64 MiB boundary goes through
// a two-window buffer, a copy inside the second window through the one-window buffer of that
// window, so they alias. In one seq (nothing committed in between):
//  - a fill of [W - 64 KiB, W + 64 KiB) through the two-window buffer (W: the window size);
//  - a copy within the second window from bytes the fill did not write: no wait (writes through
//    another window are ordered only where the bytes overlap);
//  - a copy within the second window from bytes the fill wrote: on Metal 3 the copy's encoder
//    waits for the fill's (one alias wait); on Metal 4 the renderer orders nothing itself (every
//    encoder starts after all earlier ones, the barrier at each encoder start) and no wait is
//    counted;
//  - a copy of the same bytes again in the next seq, after the first seq completed: no wait;
//  - write after read: a copy of those bytes into the first window, then a fill of them through
//    the two-window buffer
//    in the same seq: the fill waits for the copy (one alias wait on Metal 3) and the copy holds
//    the bytes before the fill;
//  - a job with two encoders (DebugTwoEncoderCopy: a helper copy encoder, then the copy) after a
//    fill through the two-window buffer: each encoder orders the job's window uses (two waits);
//  - write after a read the window's own later write replaced: a copy reads those bytes through
//    the one-window buffer, a fill writes other bytes through it, then a fill of the copied bytes
//    through the two-window buffer waits (for the second fill, which ends after the copy) and the
//    copy holds the bytes before it;
//  - the write hull grows over several writes in flight: fills of the copied bytes and of other
//    bytes through the one-window buffer, then a copy of the first fill's bytes through the
//    two-window buffer waits once (for the last fill, whose hull covers both).
// After the flushes every copy holds what it read.
// "async-compute" (PS4_GNM_ASYNC_COMPUTE=1) adds the windows across the two queues: with the
// compute queue held, a compute-ring fill through the two-window buffer, then the graphics wait for
// its label (JoinQueues) and a graphics copy of those bytes through the one-window buffer. The
// copy's alias wait on the other queue's fill is left out (counted on Metal 3; a fence orders one
// queue only) and the join orders it: the copy holds the fill's bytes.
#include <stdio.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>

#include <thread>

#import <Metal/Metal.h>

#include "ps4_gnm_backend.h"
#include "ps4_gnm_draw.h"
#include "ps4_gnm_guest_window.h"

extern "C" void* ps4_gnm_debug_backend(void);

static int g_fail = 0;
#define CHECK(c, ...)                                         \
    do {                                                      \
        if (!(c)) {                                           \
            fprintf(stderr, "gnm_alias_dma_test: FAIL: ");    \
            fprintf(stderr, __VA_ARGS__);                     \
            fprintf(stderr, "\n");                            \
            g_fail = 1;                                       \
        }                                                     \
    } while (0)

static uint64_t AliasWaits() {
    ps4gnm::GnmBackend* be = (ps4gnm::GnmBackend*)ps4_gnm_debug_backend();
    return be ? be->Stats().alias_waits : 0;
}

int main(int argc, char** argv) {
    const bool async_compute = argc > 1 && !strcmp(argv[1], "async-compute");
    if (argc > 2 || (argc == 2 && !async_compute)) {
        fprintf(stderr, "usage: gnm_alias_dma_test [async-compute]\n");
        return 2;
    }
    if (async_compute) setenv("PS4_GNM_ASYNC_COMPUTE", "1", 1);
    @autoreleasepool {
        setenv("PS4_GNM_SYNC_ENCODE", "1", 1);
        setenv("PS4_GNM_SYNC_COMPILE", "1", 1);
        setenv("PS4_GNM_NO_SHADER_CACHE", "1", 1);
        setenv("PS4_GNM_NO_PSO_ARCHIVE", "1", 1);
        setenv("PS4_GNM_NO_LIB_STORE", "1", 1);
        setenv("PS4_GNM_MEM_LOG", "0", 1);
        const uint64_t W = PS4_GNM_WINDOW_SIZE, mem_size = 2 * W;
        uint8_t* mem = (uint8_t*)mmap(nullptr, mem_size, PROT_READ | PROT_WRITE, MAP_ANON | MAP_PRIVATE | MAP_NORESERVE, -1, 0);
        if (mem == MAP_FAILED) {
            fprintf(stderr, "gnm_alias_dma_test: FAIL: no guest memory\n");
            return 1;
        }
        static GuestContext ctx;
        memset(&ctx, 0, sizeof(ctx));
        ctx.mem_base = mem;
        ctx.mem_size = mem_size;
        ctx.process_ctx = &ctx;
        pthread_mutex_init(&ctx.vm_mutex, nullptr);
        if (!ps4draw::Init(&ctx)) {
            fprintf(stderr, "gnm_alias_dma_test: FAIL: the renderer did not start\n");
            return 1;
        }
        ps4gnm::GnmBackend* be = (ps4gnm::GnmBackend*)ps4_gnm_debug_backend();
        const bool metal3 = be && be->Kind() == ps4gnm::GnmBackendKind::Metal3;
        printf("gnm_alias_dma_test: backend %s\n", metal3 ? "metal3" : "metal4");
        const uint64_t fill_at = W - 0x10000, fill_n = 0x20000;
        const uint64_t apart = W + 0x200000, near = W + 0x100, n = 0x1000;
        const uint64_t out1 = W + 0x800000, out2 = W + 0x900000, out3 = W + 0xA00000;
        memset(mem + apart, 0x33, n);
        const uint64_t w0 = AliasWaits();
        CHECK(ps4draw::GpuDma(false, true, 0, 0x5A5A5A5A, false, fill_at, (uint32_t)fill_n), "the fill was not taken");
        CHECK(ps4draw::GpuDma(false, false, apart, 0, false, out1, (uint32_t)n), "the first copy was not taken");
        const uint64_t w1 = AliasWaits();
        CHECK(w1 == w0, "a copy from bytes the fill did not write waited (%llu alias waits)",
              (unsigned long long)(w1 - w0));
        CHECK(ps4draw::GpuDma(false, false, near, 0, false, out2, (uint32_t)n), "the second copy was not taken");
        const uint64_t w2 = AliasWaits();
        if (metal3)
            CHECK(w2 == w1 + 1, "Metal 3: the copy of bytes the fill wrote through another window waited %llu times, "
                                "not once", (unsigned long long)(w2 - w1));
        else
            CHECK(w2 == w1, "Metal 4 counted alias waits");
        ps4draw::Flush(true);
        CHECK(ps4draw::GpuDma(false, false, near, 0, false, out3, (uint32_t)n), "the third copy was not taken");
        CHECK(AliasWaits() == w2, "a copy after the fill's seq completed waited");
        ps4draw::Flush(true);
        // write after read
        // out4 in the first window: the copy only reads through the second window's buffer (a use
        // of one window that reads and writes is ordered as a write)
        const uint64_t out4 = 0x200000, out5 = W + 0xC00000;
        const uint64_t w3 = AliasWaits();
        CHECK(ps4draw::GpuDma(false, false, near, 0, false, out4, (uint32_t)n), "the fourth copy was not taken");
        CHECK(ps4draw::GpuDma(false, true, 0, 0x77777777, false, fill_at, (uint32_t)fill_n), "the second fill was not taken");
        const uint64_t w4 = AliasWaits();
        CHECK(w4 == w3 + (metal3 ? 1 : 0), "write after read: the fill waited %llu times, want %d",
              (unsigned long long)(w4 - w3), metal3 ? 1 : 0);
        ps4draw::Flush(true);
        // two encoders in one job
        CHECK(ps4draw::GpuDma(false, true, 0, 0x5A5A5A5A, false, fill_at, (uint32_t)fill_n), "the third fill was not taken");
        const uint64_t w5 = AliasWaits();
        CHECK(ps4draw::DebugTwoEncoderCopy(near, out5, (uint32_t)n), "the two-encoder copy was not encoded");
        const uint64_t w6 = AliasWaits();
        CHECK(w6 == w5 + (metal3 ? 2 : 0), "two encoders in one job: %llu waits, want %d (one per encoder)",
              (unsigned long long)(w6 - w5), metal3 ? 2 : 0);
        ps4draw::Flush(true);
        // a read through the one-window buffer, its write elsewhere, a write of the read bytes
        // through the two-window buffer (all in one seq)
        const uint64_t out6 = 0x300000, other = W + 0xD00000;
        const uint64_t w7 = AliasWaits();
        CHECK(ps4draw::GpuDma(false, false, near, 0, false, out6, (uint32_t)n), "the sixth copy was not taken");
        CHECK(ps4draw::GpuDma(false, true, 0, 0x11111111, false, other, (uint32_t)n), "the fill elsewhere was not taken");
        CHECK(ps4draw::GpuDma(false, true, 0, 0x66666666, false, fill_at, (uint32_t)fill_n), "the fourth fill was not taken");
        const uint64_t w8 = AliasWaits();
        CHECK(w8 == w7 + (metal3 ? 1 : 0), "write after a replaced read: the fill waited %llu times, want %d",
              (unsigned long long)(w8 - w7), metal3 ? 1 : 0);
        ps4draw::Flush(true);
        uint32_t bad6 = 0;
        for (uint64_t i = 0; i < n; ++i) bad6 += mem[out6 + i] != 0x5A; // read before the 0x66 fill
        CHECK(bad6 == 0, "write after a replaced read: %u of %llu copied bytes wrong", bad6, (unsigned long long)n);
        // two writes in flight through the one-window buffer, then a read of the first one's bytes
        // through the two-window buffer
        const uint64_t out7 = 0x500000, other2 = W + 0x600000;
        const uint64_t w9 = AliasWaits();
        CHECK(ps4draw::GpuDma(false, true, 0, 0x5A5A5A5A, false, near, (uint32_t)n), "the fill of near was not taken");
        CHECK(ps4draw::GpuDma(false, true, 0, 0x44444444, false, other2, (uint32_t)n), "the other fill was not taken");
        CHECK(ps4draw::GpuDma(false, false, fill_at, 0, false, out7, (uint32_t)fill_n), "the wide copy was not taken");
        const uint64_t w10 = AliasWaits();
        CHECK(w10 == w9 + (metal3 ? 1 : 0), "a growing write hull: the copy waited %llu times, want %d",
              (unsigned long long)(w10 - w9), metal3 ? 1 : 0);
        ps4draw::Flush(true);
        uint32_t bad7 = 0;
        for (uint64_t i = 0; i < n; ++i) bad7 += mem[out7 + (near - fill_at) + i] != 0x5A;
        CHECK(bad7 == 0, "a growing write hull: %u of %llu copied bytes wrong", bad7, (unsigned long long)n);
        uint32_t bad1 = 0, bad2 = 0, bad3 = 0, bad4 = 0, bad5 = 0;
        for (uint64_t i = 0; i < n; ++i) {
            bad1 += mem[out1 + i] != 0x33;
            bad2 += mem[out2 + i] != 0x5A;
            bad3 += mem[out3 + i] != 0x5A;
            bad4 += mem[out4 + i] != 0x5A; // read before the 0x77 fill
            bad5 += mem[out5 + i] != 0x5A;
        }
        CHECK(bad1 == 0 && bad2 == 0 && bad3 == 0 && bad4 == 0 && bad5 == 0,
              "copies: %u, %u, %u, %u and %u of %llu bytes wrong", bad1, bad2, bad3, bad4, bad5, (unsigned long long)n);
        if (async_compute) {
            const uint64_t out8 = W + 0xF00000;
            const ps4draw::AsyncComputeCounts c0 = ps4draw::GetAsyncComputeCounts();
            CHECK(c0.on, "asynchronous compute is not on");
            id<MTLSharedEvent> gate = [be->Device() newSharedEvent];
            ps4draw::DebugGpuWaitQueue((__bridge void*)gate, 1, ps4draw::kQueueCompute);
            CHECK(ps4draw::GpuDma(false, true, 0, 0x2B2B2B2B, false, fill_at, (uint32_t)fill_n, ps4draw::kQueueCompute),
                  "the compute fill was not taken");
            ps4draw::AfterGpu([] {}, ps4draw::kQueueCompute);
            ps4draw::FlushCompute();
            std::thread opener([gate] {
                usleep(100000);
                gate.signaledValue = 1;
            });
            ps4draw::ComputeBarrier(ps4draw::kQueueGfx);
            ps4draw::JoinQueues(ps4draw::kQueueGfx);
            CHECK(ps4draw::GpuDma(false, false, near, 0, false, out8, (uint32_t)n), "the graphics copy was not taken");
            ps4draw::Flush(true);
            opener.join();
            uint32_t bad8 = 0;
            for (uint64_t i = 0; i < n; ++i) bad8 += mem[out8 + i] != 0x2B;
            CHECK(bad8 == 0, "across queues: %u of %llu copied bytes are not the compute fill's", bad8,
                  (unsigned long long)n);
            const ps4draw::AsyncComputeCounts c1 = ps4draw::GetAsyncComputeCounts();
            CHECK(c1.eligible > c0.eligible, "the compute fill did not run on the compute queue");
            if (metal3)
                CHECK(c1.alias_skipped > c0.alias_skipped, "across queues: no alias wait was left out (counted)");
        }
        if (metal3) {
            const ps4gnm::GnmBackendStats st = be->Stats();
            printf("gnm_alias_dma_test: %llu access fences, %llu alias waits\n", (unsigned long long)st.access_fences,
                   (unsigned long long)st.alias_waits);
        }
    }
    printf("gnm_alias_dma_test: %s\n", g_fail ? "FAIL" : "PASS");
    return g_fail;
}
