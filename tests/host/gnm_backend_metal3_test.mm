// Metal3Backend (ps4_gnm_backend_metal3.h): the seq timeline (Commit, CompletedSeq, the
// completion callback), the upload command buffer committed before the main one, and queue-level
// event waits. The asynchronous compute queue (CommitAsync): a seq of it completes while an earlier
// main seq is held, CompletedSeq stays at the completed prefix of both queues, and an access fence
// is reported on the other queue from Main and from AsyncCompute, and is not reused while its own
// seq is in flight. The per-target encoder state (OpenEncoder, EncoderSerial) is checked on both
// backends by gnm_backend_cmd_test (backend_harness.h, CheckEncoderTracking).
#include <stdio.h>
#include <string.h>

#include <chrono>
#include <condition_variable>
#include <mutex>
#include <thread>
#include <vector>

#include "ps4_gnm_backend_metal3.h"

using namespace ps4gnm;

static int g_fail = 0;
#define CHECK(c, ...)                                                                    \
    do {                                                                                 \
        if (!(c)) {                                                                      \
            fprintf(stderr, "gnm_backend_metal3_test: FAIL %s:%d: ", __FILE__, __LINE__); \
            fprintf(stderr, __VA_ARGS__);                                                \
            fprintf(stderr, "\n");                                                       \
            g_fail++;                                                                    \
        }                                                                                \
    } while (0)

// What the completion callbacks reported, in call order.
struct Done {
    std::mutex mu;
    std::condition_variable cv;
    std::vector<GnmCompletion> calls;

    static void Fn(void* ctx, const GnmCompletion& c) {
        Done* d = static_cast<Done*>(ctx);
        std::lock_guard<std::mutex> lk(d->mu);
        GnmCompletion r = c;
        r.error = nil; // valid during the call only
        d->calls.push_back(r);
        d->cv.notify_all();
    }
    bool WaitFor(size_t n) {
        std::unique_lock<std::mutex> lk(mu);
        return cv.wait_for(lk, std::chrono::seconds(10), [&] { return calls.size() >= n; });
    }
    size_t Count() {
        std::lock_guard<std::mutex> lk(mu);
        return calls.size();
    }
};

static bool AllBytes(id<MTLBuffer> b, uint8_t v) {
    const uint8_t* p = (const uint8_t*)b.contents;
    for (NSUInteger i = 0; i < b.length; ++i)
        if (p[i] != v) return false;
    return true;
}

int main() {
    @autoreleasepool {
        id<MTLDevice> dev = MTLCreateSystemDefaultDevice();
        if (!dev) {
            fprintf(stderr, "gnm_backend_metal3_test: FAIL no Metal device\n");
            return 1;
        }
        std::unique_ptr<GnmBackend> owned = MakeMetal3Backend();
        CHECK(owned->Kind() == GnmBackendKind::Metal3, "kind %d", (int)owned->Kind());
        CHECK(owned->Caps() == (kGnmCapAll | kGnmCapAsyncCompute), "caps 0x%x", owned->Caps());
        std::string why;
        CHECK(owned->Init(dev, &why), "Init: %s", why.c_str());
        Metal3Backend& be = *static_cast<Metal3Backend*>(owned.get());
        CHECK(be.Device() == dev, "Device()");
        CHECK(be.SideQueue() != nil, "SideQueue()");
        CHECK(be.CompletedSeq() == 0, "nothing committed: CompletedSeq %llu", (unsigned long long)be.CompletedSeq());

        const NSUInteger n = 4096;
        id<MTLBuffer> a = [dev newBufferWithLength:n options:MTLResourceStorageModeShared];
        id<MTLBuffer> b = [dev newBufferWithLength:n options:MTLResourceStorageModeShared];
        memset(a.contents, 0, n);
        memset(b.contents, 0, n);
        Done done;

        // ---- seq 1: the upload command buffer fills a, the main one copies a to b. The upload one
        // is committed first on the same queue, so b gets the fill.
        CHECK(!be.CmdOpen(GnmCmdTarget::Main) && !be.CmdOpen(GnmCmdTarget::Upload), "nothing open at start");
        be.BeginCmd(GnmCmdTarget::Main, @"test main 1", false);
        CHECK(be.CmdOpen(GnmCmdTarget::Main) && !be.CmdOpen(GnmCmdTarget::Upload), "main open only");
        CHECK(be.Target() == GnmCmdTarget::Main, "Main is the default target");
        be.BeginCopies();

        be.UseTarget(GnmCmdTarget::Upload);
        be.BeginCmd(GnmCmdTarget::Upload, @"test uploads", false);
        be.BeginCopies();
        be.FillBuffer(a, 0, n, 0x5A);
        be.EndEncoder();
        be.BeginCompute(true);
        be.EndEncoder();
        be.UseTarget(GnmCmdTarget::Main);
        be.CopyBuffer(a, 0, b, 0, n);
        be.EndEncoder();
        be.Commit(1, Done::Fn, &done);
        CHECK(!be.CmdOpen(GnmCmdTarget::Main) && !be.CmdOpen(GnmCmdTarget::Upload), "Commit closes both");
        CHECK(done.WaitFor(1), "seq 1 did not complete");
        CHECK(AllBytes(b, 0x5A), "the upload command buffer did not run before the main one");
        {
            std::lock_guard<std::mutex> lk(done.mu);
            CHECK(done.calls.size() == 1 && done.calls[0].seq == 1 && !done.calls[0].failed, "seq 1 completion");
            CHECK(done.calls[0].gpu_end >= done.calls[0].gpu_start && done.calls[0].gpu_start > 0, "seq 1 GPU times");
        }
        CHECK(be.CompletedSeq() == 1, "CompletedSeq %llu after seq 1", (unsigned long long)be.CompletedSeq());
        CHECK(be.Stats().commits == 2, "commits %llu (upload + main)", (unsigned long long)be.Stats().commits);

        // ---- an upload command buffer alone (no main one open): it runs before the next seq
        be.UseTarget(GnmCmdTarget::Upload);
        be.BeginCmd(GnmCmdTarget::Upload, @"test uploads alone", false);
        be.BeginCopies();
        be.FillBuffer(a, 0, n, 0xC3);
        be.EndEncoder();
        be.UseTarget(GnmCmdTarget::Main);
        be.CommitUpload();
        CHECK(!be.CmdOpen(GnmCmdTarget::Upload), "CommitUpload closes the upload command buffer");
        CHECK(be.Stats().commits == 3, "commits %llu", (unsigned long long)be.Stats().commits);

        // ---- seq 2 waits on the GPU for an event the CPU signals later; seq 3 is queued behind it.
        // CompletedSeq stays at 1 while 2 is held, then reaches 3.
        id<MTLSharedEvent> ev = [dev newSharedEvent];
        be.BeginCmd(GnmCmdTarget::Main, @"test main 2", false);
        be.QueueWait(ev, 1);
        be.BeginCopies();
        be.CopyBuffer(a, 0, b, 0, n);
        be.EndEncoder();
        be.Commit(2, Done::Fn, &done);
        be.BeginCmd(GnmCmdTarget::Main, @"test main 3", false);
        be.QueueSignal(ev, 2);
        be.Commit(3, Done::Fn, &done);
        std::this_thread::sleep_for(std::chrono::milliseconds(200));
        CHECK(be.CompletedSeq() == 1, "seq 2 is held by its event wait: CompletedSeq %llu",
              (unsigned long long)be.CompletedSeq());
        CHECK(done.Count() == 1, "no completion while seq 2 is held (%zu)", done.Count());
        ev.signaledValue = 1;
        CHECK(done.WaitFor(3), "seqs 2 and 3 did not complete after the signal");
        CHECK(be.CompletedSeq() == 3, "CompletedSeq %llu after seq 3", (unsigned long long)be.CompletedSeq());
        CHECK(ev.signaledValue == 2, "seq 3's QueueSignal: event value %llu", (unsigned long long)ev.signaledValue);
        CHECK(AllBytes(b, 0xC3), "the lone upload command buffer did not run before seq 2");
        {
            std::lock_guard<std::mutex> lk(done.mu);
            CHECK(done.calls.size() == 3 && done.calls[1].seq == 2 && done.calls[2].seq == 3, "completion order");
        }
        CHECK(be.Stats().commits == 5, "commits %llu", (unsigned long long)be.Stats().commits);

        // ---- asynchronous compute: main seq 4 is held by an event; async seq 5 (a fill of a)
        // completes meanwhile. CompletedSeq stays at 3 (the prefix), then reaches 5.
        id<MTLSharedEvent> ev2 = [dev newSharedEvent];
        be.BeginCmd(GnmCmdTarget::Main, @"test main 4", false);
        be.QueueWait(ev2, 1);
        be.BeginCompute(true);
        const uint64_t main_fence = be.AccessFence();
        be.EndEncoder();
        be.Commit(4, Done::Fn, &done);
        be.UseTarget(GnmCmdTarget::AsyncCompute);
        be.BeginCmd(GnmCmdTarget::AsyncCompute, @"test async 5", false);
        CHECK(be.CmdOpen(GnmCmdTarget::AsyncCompute), "the async command buffer is open");
        be.BeginCopies();
        const uint64_t async_fence = be.AccessFence();
        CHECK(be.AccessFenceOtherQueue(main_fence), "a main fence is not reported as the other queue's from AsyncCompute");
        CHECK(!be.AccessFenceOtherQueue(async_fence), "the async encoder's own fence is reported as the other queue's");
        be.FillBuffer(a, 0, n, 0x7E);
        be.EndEncoder();
        be.CommitAsync(5, Done::Fn, &done);
        be.UseTarget(GnmCmdTarget::Main);
        CHECK(be.AccessFenceOtherQueue(async_fence), "an async fence is not reported as the other queue's from Main");
        CHECK(!be.AccessFenceOtherQueue(main_fence), "a main fence is reported as the other queue's from Main");
        CHECK(done.WaitFor(4), "async seq 5 did not complete while main seq 4 is held");
        CHECK(AllBytes(a, 0x7E), "the async fill did not run");
        CHECK(be.CompletedSeq() == 3, "main seq 4 is held: CompletedSeq %llu, want 3", (unsigned long long)be.CompletedSeq());
        {
            std::lock_guard<std::mutex> lk(done.mu);
            CHECK(done.calls.size() == 4 && done.calls[3].seq == 5, "the async seq's completion came first");
        }
        // a fence of seq 4 (held) is not retired by a later commit: still live
        be.BeginCmd(GnmCmdTarget::Main, @"test main 6", false);
        be.Commit(6, Done::Fn, &done);
        CHECK(be.AccessFenceOtherQueue(async_fence), "the async fence was retired before main seq 4 completed");
        ev2.signaledValue = 1;
        CHECK(done.WaitFor(6), "seqs 4 and 6 did not complete after the signal");
        CHECK(be.CompletedSeq() == 6, "CompletedSeq %llu after seq 6", (unsigned long long)be.CompletedSeq());
    }
    if (g_fail) return 1;
    printf("gnm_backend_metal3_test: PASS\n");
    return 0;
}
