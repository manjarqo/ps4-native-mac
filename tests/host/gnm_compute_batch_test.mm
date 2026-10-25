// Batched compute commits (ps4draw::FlushCompute, docs/compute-batching.md), through the real
// renderer, on the backend PS4_GNM_METAL selects. The CP ends every compute submission with
// FlushCompute: while at least 2 seqs are in flight the commit is held, so that back-to-back
// submissions share a command buffer and a compute encoder; held work is committed by the next
// Flush, by the backlog dropping below 2, or after the bound (0.5 ms by default). The GPU is held
// by gates (DebugGpuWait), so "in flight" does not depend on timing.
//  - merge: two submissions of one dispatch each, with a guest wait between them (the barrier
//    the CP asks for at WAIT_REG_MEM): both dispatches are in one compute encoder, the wait is a
//    barrier in it, nothing is committed; without the wait, no barrier;
//  - a Flush (as at a graphics submission) commits held work at once;
//  - bound: held work is committed by the release thread within the bound (and not before it is
//    half over), while the GPU is still held; a fence action (AfterGpu: labels, interrupts)
//    after it runs once the gate opens;
//  - backlog: held work (with a long bound) is committed as soon as the gate opens and the
//    backlog drains, and its fence action runs;
//  - stream: submissions every 0.2 ms for 10 ms while the GPU is held: later submissions do not
//    move the bound, so the first commit comes within 5 ms of the first held submission, released
//    by the bound once;
//  - no backlog: FlushCompute commits at once;
//  - mode "off" (PS4_GNM_COMPUTE_BATCH=0, set before Init): with the GPU behind (two seqs gated),
//    each of 8 submissions is committed at its FlushCompute and none is held, as before batching.
// Not covered here: the CP's commit at once when a compute queue suspends on a wait
// (ps4_gnm_metal.mm, Flush(false) instead of FlushCompute): the replay harness has no CP
// compute queues (ps4_gnm_metal.mm is not in it), so that branch only runs in the game.
// usage: gnm_compute_batch_test [sync | async | off]
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>

#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>

#include <atomic>
#include <string>
#include <vector>

#include "ps4_gnm_backend.h"
#include "ps4_gnm_draw.h"

extern "C" void* ps4_gnm_debug_backend(void);

namespace {

int g_fail = 0;
#define CHECK(c, ...)                                                                     \
    do {                                                                                  \
        if (!(c)) {                                                                       \
            fprintf(stderr, "gnm_compute_batch_test: FAIL %s:%d: ", __FILE__, __LINE__); \
            fprintf(stderr, __VA_ARGS__);                                                 \
            fprintf(stderr, "\n");                                                        \
            g_fail++;                                                                     \
        }                                                                                 \
    } while (0)

constexpr uint64_t kMemSize = 256ull << 20;
constexpr uint64_t kCode = 0x01000000;
uint8_t* g_mem = nullptr;
GuestContext g_ctx;
std::vector<uint32_t> g_regs;

double NowMs() { return clock_gettime_nsec_np(CLOCK_UPTIME_RAW) / 1e6; }

// the register file of a 64x1x1 compute dispatch on every CU, with an empty program (s_endpgm)
// at kCode
void Load() {
    g_regs.assign(0x10000, 0);
    g_regs[0x2E07] = 64;          // COMPUTE_NUM_THREAD_X
    g_regs[0x2E08] = 1;           // COMPUTE_NUM_THREAD_Y
    g_regs[0x2E09] = 1;           // COMPUTE_NUM_THREAD_Z
    g_regs[0x2E16] = 0xFFFFFFFFu; // COMPUTE_STATIC_THREAD_MGMT_SE0
    g_regs[0x2E17] = 0xFFFFFFFFu; // COMPUTE_STATIC_THREAD_MGMT_SE1
    std::vector<uint32_t> code = {0xBEEB03FF, 0, 0xBF810000u, 0xBF800000u}; // header, s_endpgm, s_nop
    code[1] = uint32_t(code.size() / 2 - 1);
    uint8_t bi[32] = {'O', 'r', 'b', 'S', 'h', 'd', 'r', 7};
    const uint32_t w = (uint32_t(code.size() * 4) & 0xFFFFFF) << 8;
    const uint64_t hash = 0x5CA1AB1E0000BA7Cull;
    memcpy(bi + 8, &w, 4);
    memcpy(bi + 16, &hash, 8);
    const size_t at = code.size();
    code.resize(at + 8);
    memcpy(&code[at], bi, 32);
    memcpy(g_mem + kCode, code.data(), code.size() * 4);
    g_regs[0x2E0C] = uint32_t(kCode >> 8); // COMPUTE_PGM_LO
    g_regs[0x2E0D] = 0;
    g_regs[0x2E12] = 1 | (2 << 6); // 8 VGPRs, 24 SGPRs
    g_regs[0x2E13] = 0;            // no user SGPRs
}

void Submission() { // one compute submission: a dispatch, then the CP's end of submission
    ps4draw::Dispatch(&g_ctx, g_regs.data(), 1, 1, 1, 0, "asc", ps4draw::kQueueCompute);
    ps4draw::FlushCompute();
}

// two seqs committed behind the gate: the GPU is behind
void Backlog(id<MTLSharedEvent> gate) {
    for (int i = 0; i < 2; ++i) {
        ps4draw::DebugGpuWait((__bridge void*)gate, 1);
        ps4draw::Flush(false);
    }
}

// waits up to `ms` for the committed count to pass `committed`; the time waited, or -1
double WaitCommitted(uint64_t committed, double ms) {
    const double t0 = NowMs();
    while (NowMs() - t0 < ms) {
        if (ps4draw::GetEncodeCounts().committed > committed) return NowMs() - t0;
        usleep(50);
    }
    return -1;
}

void TestMerge(id<MTLDevice> dev) {
    ps4draw::DebugSetComputeHoldNs(2000000000ull); // only the Flush below releases it
    id<MTLSharedEvent> gate = [dev newSharedEvent];
    Backlog(gate);
    for (int wait = 1; wait >= 0; --wait) {
        const ps4draw::EncodeCounts c0 = ps4draw::GetEncodeCounts();
        Submission();
        if (wait) ps4draw::ComputeBarrier(ps4draw::kQueueCompute); // the next submission's WAIT_REG_MEM
        Submission();
        const ps4draw::EncodeCounts c1 = ps4draw::GetEncodeCounts();
        const char* what = wait ? "with a wait" : "without a wait";
        CHECK(c1.committed == c0.committed, "merge %s: %llu seqs committed while the GPU is behind", what,
              (unsigned long long)(c1.committed - c0.committed));
        CHECK(ps4draw::GetComputeHoldStats().holding, "merge %s: nothing held", what);
        CHECK(c1.compute_encoders - c0.compute_encoders == 1, "merge %s: %llu compute encoders for two submissions",
              what, (unsigned long long)(c1.compute_encoders - c0.compute_encoders));
        CHECK(c1.compute_barriers - c0.compute_barriers == (uint64_t)wait,
              "merge %s: %llu barriers between the submissions, want %d", what,
              (unsigned long long)(c1.compute_barriers - c0.compute_barriers), wait);
        // a graphics submission's Flush commits the held work at once
        ps4draw::Flush(false);
        const ps4draw::EncodeCounts c2 = ps4draw::GetEncodeCounts();
        CHECK(c2.committed == c1.committed + 1, "merge %s: the Flush committed %llu seqs", what,
              (unsigned long long)(c2.committed - c1.committed));
        CHECK(!ps4draw::GetComputeHoldStats().holding, "merge %s: still held after the Flush", what);
    }
    gate.signaledValue = 1;
    ps4draw::Flush(true);
}

void TestBound(id<MTLDevice> dev) {
    ps4draw::DebugSetComputeHoldNs(0); // the default, 0.5 ms
    for (int round = 0; round < 5; ++round) {
        id<MTLSharedEvent> gate = [dev newSharedEvent];
        Backlog(gate);
        const ps4draw::ComputeHoldStats h0 = ps4draw::GetComputeHoldStats();
        const uint64_t committed = ps4draw::GetEncodeCounts().committed;
        std::atomic<bool> ran{false};
        const double t0 = NowMs();
        Submission();
        ps4draw::AfterGpu([&ran] { ran.store(true); }); // a RELEASE_MEM label after the dispatch
        const double waited = WaitCommitted(committed, 200);
        const double since = NowMs() - t0;
        CHECK(waited >= 0, "bound, round %d: held work not committed within 200 ms", round);
        // the bound plus the release thread's wake-up and the encoder's queue: 5 ms on a busy machine
        CHECK(waited >= 0 && since < 5.0, "bound, round %d: committed %.2f ms after the submission", round, since);
        CHECK(since >= 0.4, "bound, round %d: committed %.2f ms after the submission, before the bound", round, since);
        CHECK(ps4draw::GetComputeHoldStats().by_time == h0.by_time + 1, "bound, round %d: not released by the bound",
              round);
        CHECK(!ran.load(), "bound, round %d: the fence action ran while the GPU is held", round);
        gate.signaledValue = 1;
        const double t1 = NowMs();
        while (!ran.load() && NowMs() - t1 < 2000) usleep(100);
        CHECK(ran.load(), "bound, round %d: the fence action did not run within 2 s of the gate", round);
        ps4draw::Flush(true);
        if (round == 0) printf("gnm_compute_batch_test: held work committed %.2f ms after its submission\n", since);
    }
}

void TestBacklogDrains(id<MTLDevice> dev) {
    ps4draw::DebugSetComputeHoldNs(2000000000ull);
    id<MTLSharedEvent> gate = [dev newSharedEvent];
    Backlog(gate);
    const ps4draw::ComputeHoldStats h0 = ps4draw::GetComputeHoldStats();
    const uint64_t committed = ps4draw::GetEncodeCounts().committed;
    std::atomic<bool> ran{false};
    Submission();
    ps4draw::AfterGpu([&ran] { ran.store(true); });
    usleep(20000);
    CHECK(ps4draw::GetEncodeCounts().committed == committed, "backlog: committed while the GPU is held");
    gate.signaledValue = 1;
    const double waited = WaitCommitted(committed, 1000);
    CHECK(waited >= 0, "backlog: held work not committed within 1 s of the backlog draining");
    CHECK(ps4draw::GetComputeHoldStats().by_backlog == h0.by_backlog + 1, "backlog: not released by the backlog");
    const double t1 = NowMs();
    while (!ran.load() && NowMs() - t1 < 2000) usleep(100);
    CHECK(ran.load(), "backlog: the fence action did not run");
    ps4draw::Flush(true);
    ps4draw::DebugSetComputeHoldNs(0);
}

void TestStream(id<MTLDevice> dev) {
    ps4draw::DebugSetComputeHoldNs(0);
    id<MTLSharedEvent> gate = [dev newSharedEvent];
    Backlog(gate);
    const ps4draw::ComputeHoldStats h0 = ps4draw::GetComputeHoldStats();
    const uint64_t committed = ps4draw::GetEncodeCounts().committed;
    const double t0 = NowMs();
    double first = -1;
    uint64_t by_time = 0;
    while (NowMs() - t0 < 10.0) {
        Submission();
        if (first < 0 && ps4draw::GetEncodeCounts().committed > committed) {
            first = NowMs() - t0;
            by_time = ps4draw::GetComputeHoldStats().by_time - h0.by_time;
        }
        usleep(200);
    }
    CHECK(first >= 0 && first <= 5.0, "stream: the first commit came %.2f ms after the first held submission "
                                      "(want within 5 ms: later submissions must not move the bound)", first);
    CHECK(by_time == 1, "stream: %llu releases by the bound at the first commit, want 1", (unsigned long long)by_time);
    gate.signaledValue = 1;
    ps4draw::Flush(true);
    printf("gnm_compute_batch_test: stream, first commit %.2f ms after the first held submission\n", first);
}

void TestNoBacklog() {
    ps4draw::Flush(true);
    const ps4draw::ComputeHoldStats h0 = ps4draw::GetComputeHoldStats();
    const uint64_t committed = ps4draw::GetEncodeCounts().committed;
    Submission();
    CHECK(ps4draw::GetEncodeCounts().committed == committed + 1, "no backlog: the submission was not committed");
    CHECK(ps4draw::GetComputeHoldStats().held == h0.held, "no backlog: the submission was held");
    ps4draw::Flush(true);
}

// PS4_GNM_COMPUTE_BATCH=0: no hold even with the GPU behind
void TestSwitchOff(id<MTLDevice> dev) {
    id<MTLSharedEvent> gate = [dev newSharedEvent];
    Backlog(gate);
    const ps4draw::ComputeHoldStats h0 = ps4draw::GetComputeHoldStats();
    uint64_t late = 0;
    for (int i = 0; i < 8; ++i) {
        const uint64_t committed = ps4draw::GetEncodeCounts().committed;
        Submission();
        late += WaitCommitted(committed, 0.05) < 0; // committed by the FlushCompute itself (an encoder job)
    }
    CHECK(!late, "PS4_GNM_COMPUTE_BATCH=0: %llu of 8 submissions were not committed at their end",
          (unsigned long long)late);
    CHECK(ps4draw::GetComputeHoldStats().held == h0.held, "PS4_GNM_COMPUTE_BATCH=0: %llu submissions held",
          (unsigned long long)(ps4draw::GetComputeHoldStats().held - h0.held));
    gate.signaledValue = 1;
    ps4draw::Flush(true);
}

void OnAlarm(int) {
    static const char msg[] = "gnm_compute_batch_test: FAIL a wait did not end (60 s)\n";
    (void)!write(2, msg, sizeof(msg) - 1);
    _exit(1);
}

} // namespace

int main(int argc, char** argv) {
    const std::string mode = argc > 1 ? argv[1] : "sync";
    @autoreleasepool {
        if (argc > 2 || (mode != "sync" && mode != "async" && mode != "off")) {
            fprintf(stderr, "usage: gnm_compute_batch_test [sync | async | off]\n");
            return 2;
        }
        if (mode == "sync" || mode == "off") setenv("PS4_GNM_SYNC_ENCODE", "1", 1);
        else unsetenv("PS4_GNM_SYNC_ENCODE");
        if (mode == "off") setenv("PS4_GNM_COMPUTE_BATCH", "0", 1);
        else unsetenv("PS4_GNM_COMPUTE_BATCH");
        setenv("PS4_GNM_SYNC_COMPILE", "1", 1);
        setenv("PS4_GNM_NO_SHADER_CACHE", "1", 1);
        setenv("PS4_GNM_NO_PSO_ARCHIVE", "1", 1);
        setenv("PS4_GNM_NO_LIB_STORE", "1", 1);
        setenv("PS4_GNM_MEM_LOG", "0", 1);
        signal(SIGALRM, OnAlarm);
        alarm(60);
        g_mem = (uint8_t*)mmap(nullptr, kMemSize, PROT_READ | PROT_WRITE, MAP_ANON | MAP_PRIVATE | MAP_NORESERVE, -1, 0);
        if (g_mem == MAP_FAILED) {
            fprintf(stderr, "gnm_compute_batch_test: FAIL no guest memory\n");
            return 1;
        }
        Load();
        memset(&g_ctx, 0, sizeof(g_ctx));
        g_ctx.mem_base = g_mem;
        g_ctx.mem_size = kMemSize;
        g_ctx.process_ctx = &g_ctx;
        pthread_mutex_init(&g_ctx.vm_mutex, nullptr);
        if (!ps4draw::Init(&g_ctx)) {
            fprintf(stderr, "gnm_compute_batch_test: FAIL the renderer did not start\n");
            return 1;
        }
        auto* be = static_cast<ps4gnm::GnmBackend*>(ps4_gnm_debug_backend());
        id<MTLDevice> dev = be->Device();
        Submission(); // compiles the program; nothing is in flight
        ps4draw::Flush(true);
        if (mode == "off") {
            TestSwitchOff(dev);
            printf("gnm_compute_batch_test off: %s\n", g_fail ? "FAIL" : "PASS");
            fflush(stdout);
            _exit(g_fail ? 1 : 0);
        }
        TestNoBacklog();
        TestMerge(dev);
        TestBound(dev);
        TestBacklogDrains(dev);
        TestStream(dev);
        const uint64_t skipped = ps4draw::SkippedCount();
        CHECK(skipped == 0, "%llu dispatches skipped", (unsigned long long)skipped);
    }
    printf("gnm_compute_batch_test %s: %s\n", mode.c_str(), g_fail ? "FAIL" : "PASS");
    fflush(stdout);
    _exit(g_fail ? 1 : 0);
}
