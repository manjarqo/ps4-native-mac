// Asynchronous compute (PS4_GNM_ASYNC_COMPUTE=1, Task 10.2.1): compute-ring work that is eligible
// runs on its own command queue, beside graphics as the ASC queues run beside the graphics ring on
// GCN; work that is not, and work after a wait on the other queue, joins the main queue.
// Through the real renderer (ps4draw::Dispatch, AfterGpu, GpuDma, JoinQueues), on the backend
// PS4_GNM_METAL selects. The GPU queues are held by gates (DebugGpuWait, DebugGpuWaitQueue), so
// every case is decided by order, not by timing:
//  - concurrency: with the main queue held, a compute-ring copy and its label (a compute fence
//    action) complete; off, the label waits for the gate;
//  - order: four compute submissions' labels run in submission order, graphics actions after the
//    gate;
//  - graphics waits on compute (the CP's WAIT_REG_MEM met by a compute label still pending): with
//    the compute queue held and its command buffer still open, a graphics copy of the compute
//    copy's output sees its values once the gate opens (JoinQueues(kQueueGfx));
//  - compute waits on graphics (met by a pending graphics label): with the main queue held, the
//    compute copy of a graphics copy's output sees its values, and its label waits for the gate
//    (JoinQueues(kQueueCompute) puts the rest of the submission behind graphics); the same with
//    the producer unknown (the CP's "earlier work" fallback, a timed-out wait that is skipped);
//  - DMA on the compute ring (GpuDma of kQueueCompute) after a compute copy into the same bytes:
//    the fill lands last, with the main queue held;
//  - CPU reads after both queues: Flush(true) returns with the guest memory written by both final;
//  - a sampled texture over memory a compute copy writes: graphics reads texel 3 (cached), the
//    compute queue (held) copies new texels over it, graphics joins at the compute label and reads
//    again: the new texel, as after everything completed (also with "gpu-upload": bind-time GPU
//    uploads from every size, PS4_GNM_GPU_UPLOAD_MIN_KB=0);
//  - a compute-ring job that binds an image joins Main: with the main queue held, its label waits;
//  - a compute ring whose label a graphics wait met runs on Main afterwards (gfx-consumed): its
//    label waits for the held main queue, while another ring's job (before it) runs beside it;
//  - counters: eligible jobs, joins by reason, cross waits (GetAsyncComputeCounts; a join with
//    nothing pending on the other queue encodes no wait and counts none).
// Mode "off" (the switch unset): the same programs, every queue on the main one: the concurrency
// case's label waits for the gate, the rest gives the same memory.
// Both backends have the second queue (kGnmCapAsyncCompute); one without it would run the "on"
// modes as "off" and fail the check that the switch took effect.
// usage: gnm_async_compute_test [sync | async | off] [gpu-upload]
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>

#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>

#include <atomic>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

#include "ps4_gnm_backend.h"
#include "ps4_gnm_draw.h"

extern "C" void* ps4_gnm_debug_backend(void);

namespace {

int g_fail = 0;
#define CHECK(c, ...)                                                                     \
    do {                                                                                  \
        if (!(c)) {                                                                       \
            fprintf(stderr, "gnm_async_compute_test: FAIL %s:%d: ", __FILE__, __LINE__); \
            fprintf(stderr, __VA_ARGS__);                                                 \
            fprintf(stderr, "\n");                                                        \
            g_fail++;                                                                     \
        }                                                                                 \
    } while (0)

constexpr uint64_t kMemSize = 256ull << 20;
constexpr uint64_t kCode = 0x01000000;
constexpr uint64_t kData = 0x02000000; // the buffers, 0x1000 apart
constexpr uint32_t kWords = 5;         // what the program copies (the V#s' 20-byte bounds)
uint8_t* g_mem = nullptr;
GuestContext g_ctx;
bool g_on = false; // asynchronous compute active on this backend

double NowMs() { return clock_gettime_nsec_np(CLOCK_UPTIME_RAW) / 1e6; }

uint64_t Buf(int i) { return kData + 0x1000ull * i; }

void Put(uint64_t addr, const void* p, size_t n) {
    memcpy(g_mem + addr, p, n);
    ps4draw::NotifyGuestWrite(addr, n, false, 0);
}

void Fill(int buf, uint32_t base) {
    uint32_t v[kWords];
    for (uint32_t i = 0; i < kWords; ++i) v[i] = base + i;
    Put(Buf(buf), v, sizeof(v));
}

bool Holds(int buf, uint32_t base) {
    for (uint32_t i = 0; i < kWords; ++i) {
        uint32_t w;
        memcpy(&w, g_mem + Buf(buf) + 4 * i, 4);
        if (w != base + i) return false;
    }
    return true;
}

uint32_t First(int buf) {
    uint32_t w;
    memcpy(&w, g_mem + Buf(buf), 4);
    return w;
}

// The program at kCode (64 threads): v2 = v0 << 2; buffer_load_dword v3, v2, s[4:7] offen;
// s_waitcnt 0; buffer_store_dword v3, v2, s[8:11] offen: copies the 20 bytes of s[4:7]'s V# to
// s[8:11]'s (their 20-byte bounds drop the other lanes).
void Load() {
    std::vector<uint32_t> code = {0xBEEB03FF, 0, 0x34040082, 0xE0301000, 0x80010302, 0xBF8C0000,
                                  0xE0701000, 0x80020302, 0xBF810000};
    while (code.size() % 2) code.push_back(0xBF800000);
    code[1] = uint32_t(code.size() / 2 - 1);
    uint8_t bi[32] = {'O', 'r', 'b', 'S', 'h', 'd', 'r', 7};
    const uint32_t w = (uint32_t(code.size() * 4) & 0xFFFFFF) << 8;
    const uint64_t hash = 0x5CA1AB1E0000A5C0ull;
    memcpy(bi + 8, &w, 4);
    memcpy(bi + 16, &hash, 8);
    const size_t at = code.size();
    code.resize(at + 8);
    memcpy(&code[at], bi, 32);
    memcpy(g_mem + kCode, code.data(), code.size() * 4);
}

std::vector<uint32_t> CopyRegs(int src, int dst) {
    std::vector<uint32_t> regs(0x10000, 0);
    regs[0x2E07] = 64; // COMPUTE_NUM_THREAD_X
    regs[0x2E08] = regs[0x2E09] = 1;
    regs[0x2E0C] = uint32_t(kCode >> 8); // COMPUTE_PGM_LO
    regs[0x2E12] = 1;                    // RSRC1: 8 VGPRs
    regs[0x2E13] = 12 << 1;              // RSRC2: 12 user SGPRs
    uint32_t* ud = &regs[0x2E40];
    const uint32_t fmt = 4 | (5 << 3) | (6 << 6) | (7 << 9) | (4 << 12) | (4 << 15); // 32-bit uint
    ud[4] = uint32_t(Buf(src));
    ud[6] = kWords * 4;
    ud[7] = fmt;
    ud[8] = uint32_t(Buf(dst));
    ud[10] = kWords * 4;
    ud[11] = fmt;
    return regs;
}

void Copy(int queue, int src, int dst) {
    const std::vector<uint32_t> regs = CopyRegs(src, dst);
    ps4draw::Dispatch(&g_ctx, regs.data(), 1, 1, 1, 0, queue == ps4draw::kQueueCompute ? "asc" : "gfx", queue);
}

// The program at kCode + 0x10000: image_load_mip of texel 3, level 0 of the 1D T# in s[0:7] (S# in
// s[12:15]), stored as 16 bytes to the V# in s[8:11] (the encodings of gnm_tex1d_test).
constexpr uint64_t kCodeTex = kCode + 0x10000;
void LoadTexProgram() {
    std::vector<uint32_t> code = {0xBEEB03FF, 0,
                                  0x7E000283,                         // v_mov_b32 v0, 3
                                  0x7E020280,                         // v_mov_b32 v1, 0
                                  0xF0040F00, 0x00600400,             // image_load_mip v[4:7], v[0:1], s[0:7], s[12:15]
                                  0xBF8C0000,                         // s_waitcnt 0
                                  0xE0780000, 0x80020400,             // buffer_store_dwordx4 v[4:7], s[8:11]
                                  0xBF8C0000, 0xBF810000};
    while (code.size() % 2) code.push_back(0xBF800000);
    code[1] = uint32_t(code.size() / 2 - 1);
    uint8_t bi[32] = {'O', 'r', 'b', 'S', 'h', 'd', 'r', 7};
    const uint32_t w = (uint32_t(code.size() * 4) & 0xFFFFFF) << 8;
    const uint64_t hash = 0x5CA1AB1E0000A5C1ull;
    memcpy(bi + 8, &w, 4);
    memcpy(bi + 16, &hash, 8);
    const size_t at = code.size();
    code.resize(at + 8);
    memcpy(&code[at], bi, 32);
    memcpy(g_mem + kCodeTex, code.data(), code.size() * 4);
}

// A graphics-ring dispatch of that program: texel 3 of the RGBA8 Color1D texture at buffer `tex`
// (8 texels, linear aligned, pitch 64: texel x at byte 4x) into buffer `out`.
void ReadTexel(int tex, int out, int queue = ps4draw::kQueueGfx) {
    std::vector<uint32_t> regs(0x10000, 0);
    regs[0x2E07] = 64;
    regs[0x2E08] = regs[0x2E09] = 1;
    regs[0x2E0C] = uint32_t(kCodeTex >> 8);
    regs[0x2E12] = 1 | (3 << 6); // 8 VGPRs, 32 SGPRs
    regs[0x2E13] = 16 << 1;      // 16 user SGPRs
    uint32_t* ud = &regs[0x2E40];
    const uint64_t a = Buf(tex);
    ud[0] = uint32_t(a >> 8);
    ud[1] = 10u << 20;                                                       // 8_8_8_8, unorm
    ud[2] = 8 - 1;                                                           // width 8, height 1
    ud[3] = 4 | (5 << 3) | (6 << 6) | (7 << 9) | (8u << 20) | (8u << 28);    // xyzw, linear aligned, 1D
    ud[4] = (64 - 1) << 13;                                                  // pitch 64
    ud[8] = uint32_t(Buf(out));
    ud[10] = 16;
    ud[11] = 4 | (5 << 3) | (6 << 6) | (7 << 9) | (4 << 12) | (4 << 15);
    ud[13] = 0xF00u << 12; // max_lod 15
    ud[14] = 1u << 26;     // mip filter point
    ps4draw::Dispatch(&g_ctx, regs.data(), 1, 1, 1, 0, queue == ps4draw::kQueueCompute ? "asc" : "gfx", queue);
}

bool Same16(int a, int b) { return !memcmp(g_mem + Buf(a), g_mem + Buf(b), 16); }

bool WaitFor(const std::atomic<bool>& flag, double ms) {
    const double t0 = NowMs();
    while (!flag.load() && NowMs() - t0 < ms) usleep(100);
    return flag.load();
}

// Opens `gate` after `ms` from another thread (the caller may block on the GPU meanwhile).
std::thread OpenLater(id<MTLSharedEvent> gate, double ms) {
    return std::thread([gate, ms] {
        usleep((useconds_t)(ms * 1000));
        gate.signaledValue = 1;
    });
}

void TestConcurrency(id<MTLDevice> dev) {
    Fill(0, 0x1000);
    Fill(1, 0);
    id<MTLSharedEvent> gate = [dev newSharedEvent];
    ps4draw::DebugGpuWait((__bridge void*)gate, 1); // the main queue waits here
    ps4draw::Flush(false);
    const ps4draw::AsyncComputeCounts c0 = ps4draw::GetAsyncComputeCounts();
    std::atomic<bool> ran{false};
    Copy(ps4draw::kQueueCompute, 0, 1);
    ps4draw::AfterGpu([&ran] { ran.store(true); }, ps4draw::kQueueCompute); // its RELEASE_MEM label
    ps4draw::FlushCompute();
    if (g_on) {
        CHECK(WaitFor(ran, 2000), "concurrency: the compute label did not run within 2 s with the main queue held");
        CHECK(Holds(1, 0x1000), "concurrency: the compute copy did not land (0x%x) with the main queue held", First(1));
        const ps4draw::AsyncComputeCounts c1 = ps4draw::GetAsyncComputeCounts();
        CHECK(c1.eligible > c0.eligible, "concurrency: the copy was not counted as eligible");
    } else {
        CHECK(!WaitFor(ran, 200), "concurrency, off: the compute label ran with the main queue held");
    }
    gate.signaledValue = 1;
    ps4draw::Flush(true);
    CHECK(ran.load(), "concurrency: the compute label did not run after the gate");
    CHECK(Holds(1, 0x1000), "concurrency: the copy is missing after Flush(true) (0x%x)", First(1));
}

void TestOrder(id<MTLDevice> dev) {
    for (int i = 0; i < 4; ++i) Fill(10 + i, 0x2000 + 0x10 * i);
    id<MTLSharedEvent> gate = [dev newSharedEvent];
    ps4draw::DebugGpuWait((__bridge void*)gate, 1);
    std::mutex mu;
    std::vector<int> ran;
    std::atomic<int> n{0};
    ps4draw::AfterGpu([&] { std::lock_guard<std::mutex> lk(mu); ran.push_back(100); n++; }); // graphics, held
    ps4draw::Flush(false);
    for (int i = 0; i < 4; ++i) {
        Copy(ps4draw::kQueueCompute, 10 + i, 20 + i);
        ps4draw::AfterGpu([&, i] { std::lock_guard<std::mutex> lk(mu); ran.push_back(i); n++; }, ps4draw::kQueueCompute);
        ps4draw::FlushCompute();
    }
    if (g_on) {
        const double t0 = NowMs();
        while (n.load() < 4 && NowMs() - t0 < 2000) usleep(100);
        std::lock_guard<std::mutex> lk(mu);
        CHECK(ran == std::vector<int>({0, 1, 2, 3}), "order: %zu compute labels ran with the main queue held, want 0 1 2 3",
              ran.size());
    }
    gate.signaledValue = 1;
    ps4draw::Flush(true);
    std::lock_guard<std::mutex> lk(mu);
    const std::vector<int> want = g_on ? std::vector<int>({0, 1, 2, 3, 100}) : std::vector<int>({100, 0, 1, 2, 3});
    CHECK(ran == want, "order: actions ran as %s", [&] {
        static char b[128];
        b[0] = 0;
        for (int v : ran) snprintf(b + strlen(b), sizeof(b) - strlen(b), "%d ", v);
        return b;
    }());
    for (int i = 0; i < 4; ++i) CHECK(Holds(20 + i, 0x2000 + 0x10 * i), "order: copy %d missing", i);
}

// The CP finds a graphics WAIT_REG_MEM met only by a compute label still pending: the graphics work
// after it must see the compute work's results. The compute queue is held, and its command buffer
// is still open (no end of submission yet) when the graphics queue joins.
void TestGfxWaitsCompute(id<MTLDevice> dev) {
    Fill(30, 0x3000);
    Fill(31, 0);
    Fill(32, 0);
    id<MTLSharedEvent> gate = [dev newSharedEvent];
    ps4draw::DebugGpuWaitQueue((__bridge void*)gate, 1, ps4draw::kQueueCompute); // the compute queue waits here
    Copy(ps4draw::kQueueCompute, 30, 31);
    std::atomic<bool> label{false};
    ps4draw::AfterGpu([&label] { label.store(true); }, ps4draw::kQueueCompute);
    const ps4draw::AsyncComputeCounts c0 = ps4draw::GetAsyncComputeCounts();
    std::thread opener = OpenLater(gate, 100);
    // what the CP does at the graphics WAIT_REG_MEM: its barrier, then the join
    ps4draw::ComputeBarrier(ps4draw::kQueueGfx);
    ps4draw::JoinQueues(ps4draw::kQueueGfx);
    Copy(ps4draw::kQueueGfx, 31, 32);
    ps4draw::FlushCompute();
    ps4draw::Flush(true);
    opener.join();
    CHECK(label.load(), "graphics waits on compute: the compute label did not run");
    CHECK(Holds(31, 0x3000), "graphics waits on compute: the compute copy is missing (0x%x)", First(31));
    CHECK(Holds(32, 0x3000), "graphics waits on compute: the graphics copy read 0x%x, not the compute copy's output",
          First(32));
    if (g_on)
        CHECK(ps4draw::GetAsyncComputeCounts().cross_waits > c0.cross_waits,
              "graphics waits on compute: no cross wait counted");
    // nothing pending on the compute queue now: a join encodes no wait and counts none
    const uint64_t x = ps4draw::GetAsyncComputeCounts().cross_waits;
    ps4draw::JoinQueues(ps4draw::kQueueGfx);
    ps4draw::Flush(true);
    CHECK(ps4draw::GetAsyncComputeCounts().cross_waits == x, "graphics waits on compute: a join with nothing pending "
          "counted a cross wait");
}

// The CP finds a compute WAIT_REG_MEM met only by a graphics label still pending: the rest of the
// compute submission runs behind the graphics work. The main queue is held.
// unknown: the wait's producer is unknown (the CP's "earlier work" fallback, or a wait that timed
// out and is skipped): JoinQueues(compute, true), the same routing.
void TestComputeWaitsGfx(id<MTLDevice> dev, bool unknown) {
    const int b = unknown ? 90 : 40;
    const char* what = unknown ? "compute waits, producer unknown" : "compute waits on graphics";
    Fill(b + 0, 0x4000);
    Fill(b + 1, 0);
    Fill(b + 2, 0);
    id<MTLSharedEvent> gate = [dev newSharedEvent];
    ps4draw::DebugGpuWait((__bridge void*)gate, 1);
    Copy(ps4draw::kQueueGfx, b + 0, b + 1);
    ps4draw::Flush(false);
    const ps4draw::AsyncComputeCounts c0 = ps4draw::GetAsyncComputeCounts();
    // what the CP does at the compute WAIT_REG_MEM: its barrier, then the join
    ps4draw::ComputeBarrier(ps4draw::kQueueCompute);
    ps4draw::JoinQueues(ps4draw::kQueueCompute, unknown);
    Copy(ps4draw::kQueueCompute, b + 1, b + 2);
    std::atomic<bool> label{false};
    ps4draw::AfterGpu([&label] { label.store(true); }, ps4draw::kQueueCompute);
    ps4draw::FlushCompute();
    CHECK(!WaitFor(label, 200), "%s: the compute label ran with the graphics work held", what);
    gate.signaledValue = 1;
    ps4draw::Flush(true);
    CHECK(label.load(), "%s: the compute label did not run after the gate", what);
    CHECK(Holds(b + 2, 0x4000), "%s: the compute copy read 0x%x, not the graphics copy's output", what,
          First(b + 2));
    if (g_on) {
        const ps4draw::AsyncComputeCounts c1 = ps4draw::GetAsyncComputeCounts();
        CHECK(c1.joined > c0.joined, "%s: the compute job was not counted as joined", what);
    }
    // the next submission is eligible again
    Fill(b + 3, 0x4100);
    id<MTLSharedEvent> gate2 = [dev newSharedEvent];
    ps4draw::DebugGpuWait((__bridge void*)gate2, 1);
    ps4draw::Flush(false);
    std::atomic<bool> next{false};
    Copy(ps4draw::kQueueCompute, b + 3, b + 4);
    ps4draw::AfterGpu([&next] { next.store(true); }, ps4draw::kQueueCompute);
    ps4draw::FlushCompute();
    if (g_on) CHECK(WaitFor(next, 2000), "%s: the next submission did not run beside graphics", what);
    gate2.signaledValue = 1;
    ps4draw::Flush(true);
    CHECK(Holds(b + 4, 0x4100), "%s: the next submission's copy is missing", what);
}

// CP DMA of a compute ring on the GPU timeline (GpuDma of kQueueCompute) after a compute copy into
// the same bytes: the fill lands last; with the main queue held, both complete (on).
void TestDma(id<MTLDevice> dev) {
    Fill(50, 0x5000);
    Fill(51, 0);
    id<MTLSharedEvent> gate = [dev newSharedEvent];
    ps4draw::DebugGpuWait((__bridge void*)gate, 1);
    ps4draw::Flush(false);
    Copy(ps4draw::kQueueCompute, 50, 51);
    ps4draw::ComputeBarrier(ps4draw::kQueueCompute); // the CP's barrier at DMA_DATA
    CHECK(ps4draw::GpuDma(false, true, 0, 0x77777777u, false, Buf(51), kWords * 4, ps4draw::kQueueCompute),
          "dma: GpuDma refused");
    std::atomic<bool> label{false};
    ps4draw::AfterGpu([&label] { label.store(true); }, ps4draw::kQueueCompute);
    ps4draw::FlushCompute();
    if (g_on) {
        CHECK(WaitFor(label, 2000), "dma: the compute ring's label did not run with the main queue held");
        uint32_t w0;
        memcpy(&w0, g_mem + Buf(51), 4);
        CHECK(w0 == 0x77777777u, "dma: 0x%x at the destination when the compute ring's label ran, want the fill", w0);
    }
    gate.signaledValue = 1;
    ps4draw::Flush(true);
    uint32_t w[kWords];
    memcpy(w, g_mem + Buf(51), sizeof(w));
    bool fill = true;
    for (uint32_t v : w) fill = fill && v == 0x77777777u;
    CHECK(fill, "dma: 0x%x at the destination, want the fill after the copy", w[0]);
}

// A sampled texture over memory that a compute copy writes, read by graphics before and after
// graphics waits for the compute work (JoinQueues at a graphics WAIT_REG_MEM met by its label).
void TestSampledAfterCompute(id<MTLDevice> dev) {
    Fill(70, 0x01020304); // the texture: 8 RGBA8 texels (the first 5 words set, the rest zero)
    Fill(71, 0x80907000); // what the compute copy writes over the texture
    ReadTexel(70, 72);
    ps4draw::Flush(true);
    id<MTLSharedEvent> gate = [dev newSharedEvent];
    ps4draw::DebugGpuWaitQueue((__bridge void*)gate, 1, ps4draw::kQueueCompute);
    Copy(ps4draw::kQueueCompute, 71, 70);
    ps4draw::AfterGpu([] {}, ps4draw::kQueueCompute);
    ps4draw::FlushCompute();
    std::thread opener = OpenLater(gate, 100);
    ps4draw::ComputeBarrier(ps4draw::kQueueGfx);
    ps4draw::JoinQueues(ps4draw::kQueueGfx);
    ReadTexel(70, 73); // after the join: the copied texels
    ps4draw::Flush(true);
    opener.join();
    ReadTexel(70, 74); // with everything completed: the reference
    ps4draw::Flush(true);
    CHECK(!Same16(72, 74), "sampled texture: the copy changed nothing in texel 3 (the test does not test)");
    CHECK(Same16(73, 74), "sampled texture: after the join graphics read %08x, want %08x (the texel after the copy)",
          First(73), First(74));
}

// A compute-ring job that binds an image (U4's depth copy reads its depth through a T#) is not
// eligible: it runs on Main, so with the main queue held its label waits for the gate, and it
// reads the texel graphics wrote there before it.
void TestImagesJoin(id<MTLDevice> dev) {
    Fill(60, 0x0A0B0C0D);
    ReadTexel(60, 61); // caches the texture
    ps4draw::Flush(true);
    id<MTLSharedEvent> gate = [dev newSharedEvent];
    ps4draw::DebugGpuWait((__bridge void*)gate, 1);
    ps4draw::Flush(false);
    const ps4draw::AsyncComputeCounts c0 = ps4draw::GetAsyncComputeCounts();
    std::atomic<bool> label{false};
    ReadTexel(60, 62, ps4draw::kQueueCompute);
    ps4draw::AfterGpu([&label] { label.store(true); }, ps4draw::kQueueCompute);
    ps4draw::FlushCompute();
    CHECK(!WaitFor(label, 200), "image job: its label ran with the main queue held (it ran on the compute queue)");
    gate.signaledValue = 1;
    ps4draw::Flush(true);
    CHECK(label.load() && Same16(61, 62), "image job: label %d, read %08x, want %08x", label.load(), First(62), First(61));
    if (g_on)
        CHECK(ps4draw::GetAsyncComputeCounts().joined > c0.joined, "image job: not counted as joined");
}

// A ring whose label a graphics wait met runs on Main for a while: its next label waits for the held
// main queue, while another ring's job still runs beside it.
void TestGfxConsumedRing(id<MTLDevice> dev) {
    if (!g_on) return;
    Fill(80, 0x8000);
    Fill(81, 0x8100);
    ps4draw::SetCpComputeRing(5);
    Copy(ps4draw::kQueueCompute, 80, 82);
    ps4draw::AfterGpu([] {}, ps4draw::kQueueCompute);
    ps4draw::SetCpComputeRing(-1);
    ps4draw::ComputeBarrier(ps4draw::kQueueGfx);
    ps4draw::JoinQueues(ps4draw::kQueueGfx, false, 5); // a graphics wait met by ring 5's label
    ps4draw::FlushCompute();
    ps4draw::Flush(true);
    id<MTLSharedEvent> gate = [dev newSharedEvent];
    ps4draw::DebugGpuWait((__bridge void*)gate, 1);
    ps4draw::Flush(false);
    std::atomic<bool> ring5{false}, ring6{false};
    // Ring 6 first: the compute queue's labels run in order, so a ring 5 job ahead of it on Main
    // would hold ring 6's label too.
    ps4draw::SetCpComputeRing(6);
    Copy(ps4draw::kQueueCompute, 81, 84);
    ps4draw::AfterGpu([&ring6] { ring6.store(true); }, ps4draw::kQueueCompute);
    ps4draw::FlushCompute();
    ps4draw::SetCpComputeRing(5);
    Copy(ps4draw::kQueueCompute, 80, 83);
    ps4draw::AfterGpu([&ring5] { ring5.store(true); }, ps4draw::kQueueCompute);
    ps4draw::FlushCompute();
    ps4draw::SetCpComputeRing(-1);
    CHECK(WaitFor(ring6, 2000), "gfx-consumed: ring 6's label did not run beside the held main queue");
    CHECK(!WaitFor(ring5, 300), "gfx-consumed: ring 5's label ran with the main queue held (its work should be on Main)");
    gate.signaledValue = 1;
    ps4draw::Flush(true);
    CHECK(ring5.load() && Holds(83, 0x8000) && Holds(84, 0x8100), "gfx-consumed: the copies are missing");
}

// Work on both queues, then Flush(true): the memory written by both is final.
void TestCpuRead() {
    Fill(60, 0x6000);
    Fill(61, 0x6100);
    Copy(ps4draw::kQueueCompute, 60, 62);
    Copy(ps4draw::kQueueGfx, 61, 63);
    ps4draw::FlushCompute();
    ps4draw::Flush(true);
    CHECK(Holds(62, 0x6000) && Holds(63, 0x6100), "cpu read: 0x%x / 0x%x after Flush(true)", First(62), First(63));
}

void OnAlarm(int) {
    static const char msg[] = "gnm_async_compute_test: FAIL timed out (a queue never ran)\n";
    write(2, msg, sizeof(msg) - 1);
    _exit(1);
}

} // namespace

int main(int argc, char** argv) {
    const std::string mode = argc > 1 ? argv[1] : "sync";
    const std::string upload = argc > 2 ? argv[2] : "";
    @autoreleasepool {
        if (argc > 3 || (mode != "sync" && mode != "async" && mode != "off") || (!upload.empty() && upload != "gpu-upload")) {
            fprintf(stderr, "usage: gnm_async_compute_test [sync | async | off] [gpu-upload]\n");
            return 2;
        }
        if (upload == "gpu-upload") setenv("PS4_GNM_GPU_UPLOAD_MIN_KB", "0", 1);
        if (mode == "async") unsetenv("PS4_GNM_SYNC_ENCODE");
        else setenv("PS4_GNM_SYNC_ENCODE", "1", 1);
        if (mode == "off") unsetenv("PS4_GNM_ASYNC_COMPUTE");
        else setenv("PS4_GNM_ASYNC_COMPUTE", "1", 1);
        setenv("PS4_GNM_SYNC_COMPILE", "1", 1);
        setenv("PS4_GNM_NO_SHADER_CACHE", "1", 1);
        setenv("PS4_GNM_NO_PSO_ARCHIVE", "1", 1);
        setenv("PS4_GNM_NO_LIB_STORE", "1", 1);
        setenv("PS4_GNM_MEM_LOG", "0", 1);
        signal(SIGALRM, OnAlarm);
        alarm(60);
        g_mem = (uint8_t*)mmap(nullptr, kMemSize, PROT_READ | PROT_WRITE, MAP_ANON | MAP_PRIVATE | MAP_NORESERVE, -1, 0);
        if (g_mem == MAP_FAILED) {
            fprintf(stderr, "gnm_async_compute_test: FAIL no guest memory\n");
            return 1;
        }
        Load();
        LoadTexProgram();
        memset(&g_ctx, 0, sizeof(g_ctx));
        g_ctx.mem_base = g_mem;
        g_ctx.mem_size = kMemSize;
        g_ctx.process_ctx = &g_ctx;
        pthread_mutex_init(&g_ctx.vm_mutex, nullptr);
        if (!ps4draw::Init(&g_ctx)) {
            fprintf(stderr, "gnm_async_compute_test: FAIL the renderer did not start\n");
            return 1;
        }
        auto* be = static_cast<ps4gnm::GnmBackend*>(ps4_gnm_debug_backend());
        id<MTLDevice> dev = be->Device();
        g_on = ps4draw::GetAsyncComputeCounts().on;
        if (mode != "off")
            CHECK(g_on, "asynchronous compute is not active on %s with PS4_GNM_ASYNC_COMPUTE=1",
                  be->Kind() == ps4gnm::GnmBackendKind::Metal4 ? "Metal 4" : "Metal 3");
        CHECK(mode != "off" || !g_on, "asynchronous compute active without PS4_GNM_ASYNC_COMPUTE");
        Copy(ps4draw::kQueueCompute, 0, 1); // compiles the program
        ps4draw::FlushCompute();
        ps4draw::Flush(true);
        TestConcurrency(dev);
        TestOrder(dev);
        TestGfxWaitsCompute(dev);
        TestComputeWaitsGfx(dev, false);
        TestComputeWaitsGfx(dev, true);
        TestDma(dev);
        TestSampledAfterCompute(dev);
        TestImagesJoin(dev);
        TestGfxConsumedRing(dev);
        TestCpuRead();
        printf("gnm_async_compute_test %s%s%s: %s\n", mode.c_str(), upload.empty() ? "" : " ", upload.c_str(),
               g_fail ? "FAIL" : "PASS");
        fflush(stdout);
        _exit(g_fail ? 1 : 0);
    }
}
