// Background compute-kernel compiles (pkg/runtime/modules/libSceGnmDriver/ps4_gnm_kernel_compile.mm)
// on the real Metal device.
//
// usage: kernel_compile_test <nonce>
//   The nonce goes into every kernel's source, so the system Metal cache of earlier runs cannot
//   satisfy the compiles and they really run in the background.
//
// Checks: Start returns before the compile finished (a compile on the calling thread fails this);
// several kernels compile at the same time and in less wall time than one after another; an
// encoder-like thread that waits for each job in order gets kernels whose dispatch results are
// right; the same MSL shares one job (one compile); a failed compile reports Metal's error, stays
// failed and is not compiled again; several threads waiting for one job all get its kernel; a
// wait on a finished job does not block; no more than the limit compile at once and queued jobs
// start in the order they were asked for; the destructor waits for queued and running compiles.
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>

#include "ps4_gnm_kernel_compile.h"

#include <cstdio>
#include <cstdlib>
#include <string>
#include <thread>
#include <unistd.h>
#include <atomic>
#include <mutex>
#include <vector>

namespace {

int g_fail = 0;
#define CHECK(c)                                                                                                      \
    do {                                                                                                              \
        if (!(c)) {                                                                                                   \
            fprintf(stderr, "kernel_compile_test: FAIL %s:%d: %s\n", __FILE__, __LINE__, #c);                         \
            g_fail++;                                                                                                 \
        }                                                                                                             \
    } while (0)

MTLCompileOptions* Options() {
    MTLCompileOptions* o = [MTLCompileOptions new];
    o.preserveInvariance = YES;
    return o;
}

// out[i] = f_k(i): a loop and a few helpers, so the compile takes real time.
std::string KernelSource(unsigned k, unsigned long nonce) {
    char head[256];
    snprintf(head, sizeof(head), "// kernel_compile_test nonce %lu kernel %u\n#include <metal_stdlib>\nusing namespace metal;\n",
             nonce, k);
    std::string s = head;
    for (int h = 0; h < 24; ++h) {
        char fn[256];
        snprintf(fn, sizeof(fn), "static uint h%d(uint x) { for (uint j = 0; j < %d; ++j) x = x * 1664525u + %uu; return x; }\n",
                 h, 3 + h % 5, 1013904223u + (unsigned)h + k * 31u);
        s += fn;
    }
    char body[512];
    snprintf(body, sizeof(body),
             "kernel void main0(device uint* out [[buffer(0)]], uint i [[thread_position_in_grid]]) {\n"
             "    uint x = i * %uu + %luu;\n"
             "    out[i] = x + (h0(x) & 0u) + (h23(x) & 0u);\n"
             "}\n",
             k + 3, nonce % 100000);
    return s + body;
}

uint32_t Expected(unsigned k, unsigned long nonce, uint32_t i) {
    return i * (k + 3) + (uint32_t)(nonce % 100000);
}

uint64_t HashOf(const std::string& s) {
    uint64_t h = 1469598103934665603ull;
    for (unsigned char c : s) h = (h ^ c) * 1099511628211ull;
    return h;
}

// Runs the kernel over n threads and checks every output word.
bool RunAndCheck(id<MTLDevice> dev, id<MTLCommandQueue> q, id<MTLFunction> fn, unsigned k, unsigned long nonce) {
    NSError* e = nil;
    id<MTLComputePipelineState> pso = [dev newComputePipelineStateWithFunction:fn error:&e];
    if (!pso) {
        fprintf(stderr, "kernel_compile_test: pipeline of kernel %u failed: %s\n", k, e.localizedDescription.UTF8String);
        return false;
    }
    const uint32_t n = 256;
    id<MTLBuffer> out = [dev newBufferWithLength:n * 4 options:MTLResourceStorageModeShared];
    memset(out.contents, 0xAB, n * 4);
    id<MTLCommandBuffer> cb = [q commandBuffer];
    id<MTLComputeCommandEncoder> ce = [cb computeCommandEncoder];
    [ce setComputePipelineState:pso];
    [ce setBuffer:out offset:0 atIndex:0];
    [ce dispatchThreads:MTLSizeMake(n, 1, 1) threadsPerThreadgroup:MTLSizeMake(64, 1, 1)];
    [ce endEncoding];
    [cb commit];
    [cb waitUntilCompleted];
    const uint32_t* v = (const uint32_t*)out.contents;
    for (uint32_t i = 0; i < n; ++i)
        if (v[i] != Expected(k, nonce, i)) {
            fprintf(stderr, "kernel_compile_test: kernel %u out[%u] = %u, expected %u\n", k, i, v[i], Expected(k, nonce, i));
            return false;
        }
    return true;
}

} // namespace

int main(int argc, char** argv) {
    if (argc < 2) {
        fprintf(stderr, "usage: kernel_compile_test <nonce>\n");
        return 2;
    }
    const unsigned long nonce = strtoul(argv[1], nullptr, 10);
    @autoreleasepool {
        id<MTLDevice> dev = MTLCreateSystemDefaultDevice();
        if (!dev) {
            fprintf(stderr, "kernel_compile_test: no Metal device\n");
            return 1;
        }
        id<MTLCommandQueue> q = [dev newCommandQueue];
        const unsigned kParallel = 3;
        ps4gnm_kernels::Compiler comp(dev, Options, kParallel);

        // ---- several kernels: Start does not compile, the compiles overlap ----
        const unsigned kN = 6;
        std::vector<std::string> src(kN);
        std::vector<std::shared_ptr<ps4gnm_kernels::Job>> jobs(kN);
        unsigned done_at_start = 0;
        const double t0 = CFAbsoluteTimeGetCurrent();
        for (unsigned k = 0; k < kN; ++k) {
            src[k] = KernelSource(k, nonce);
            bool started = false;
            jobs[k] = comp.Start(HashOf(src[k]), src[k], &started);
            CHECK(started);
            CHECK(jobs[k] && jobs[k]->Hash() == HashOf(src[k]));
            if (jobs[k]->Done()) done_at_start++;
        }
        const double start_ms = (CFAbsoluteTimeGetCurrent() - t0) * 1000.0;
        CHECK(done_at_start == 0); // compiled by Start itself: not in the background
        CHECK(comp.Started() == kN);

        // when the last compile finished (compiles only; the dispatch checks below take time too)
        double ready_ms = 0;
        std::thread all([&] {
            for (auto& j : jobs) j->Wait();
            ready_ms = (CFAbsoluteTimeGetCurrent() - t0) * 1000.0;
        });
        // the encoder: waits for each kernel in stream order and runs its dispatch
        bool results_ok = true;
        double first_wait = 0;
        std::thread enc([&] {
            for (unsigned k = 0; k < kN; ++k) {
                double w = 0;
                id<MTLFunction> fn = jobs[k]->Wait(&w);
                if (k == 0) first_wait = w;
                if (!fn || !RunAndCheck(dev, q, fn, k, nonce)) results_ok = false;
            }
        });
        enc.join();
        all.join();
        const double wall_ms = (CFAbsoluteTimeGetCurrent() - t0) * 1000.0;
        CHECK(results_ok);
        CHECK(first_wait > 0); // the first kernel was still compiling when the encoder needed it
        double sum_ms = 0, max_ms = 0;
        for (auto& j : jobs) {
            CHECK(j->Done());
            CHECK(j->Error().empty());
            sum_ms += j->CompileMs();
            max_ms = std::max(max_ms, j->CompileMs());
        }
        CHECK(comp.PeakRunning() >= 2);
        CHECK(comp.PeakRunning() <= kParallel); // the limit holds
        CHECK(comp.Unfinished() == 0);
        // in parallel: the wall time of all compiles is well below their sum
        CHECK(ready_ms < 0.8 * sum_ms);
        fprintf(stderr, "kernel_compile_test: %u kernels started in %.2f ms; compiles %.0f ms in total (max %.0f ms), "
                        "all compiled after %.0f ms, checked after %.0f ms; %llu at once at most; first wait %.0f ms\n",
                kN, start_ms, sum_ms, max_ms, ready_ms, wall_ms, (unsigned long long)comp.PeakRunning(), first_wait);

        // ---- the same MSL shares the job; a wait on a finished job does not block ----
        {
            bool started = true;
            auto again = comp.Start(HashOf(src[0]), src[0], &started);
            CHECK(!started);
            CHECK(again == jobs[0]);
            CHECK(comp.Find(HashOf(src[0])) == jobs[0]);
            CHECK(comp.Find(HashOf(src[0]) ^ 1) == nullptr);
            CHECK(comp.Started() == kN);
            double w = -1;
            CHECK(again->Wait(&w) != nil);
            CHECK(w == 0);
        }

        // ---- a compile Metal rejects ----
        {
            char bad[200];
            snprintf(bad, sizeof(bad), "// nonce %lu\n#include <metal_stdlib>\nkernel void main0(device uint* o [[buffer(0)]]) { o[0] = undefined_name; }\n",
                     nonce);
            bool started = false;
            auto j = comp.Start(HashOf(bad), bad, &started);
            CHECK(started);
            CHECK(j->Wait() == nil);
            CHECK(j->Done());
            CHECK(j->Error().find("undefined_name") != std::string::npos);
            CHECK(comp.Failed() == 1);
            auto j2 = comp.Start(HashOf(bad), bad, &started);
            CHECK(!started && j2 == j); // not compiled again
            CHECK(comp.Started() == kN + 1);
        }

        // ---- several threads wait for one job ----
        {
            const std::string s = KernelSource(100, nonce);
            auto j = comp.Start(HashOf(s), s);
            CHECK(!j->Done());
            std::vector<std::thread> th;
            std::vector<id<MTLFunction>> got(4);
            for (int t = 0; t < 4; ++t) th.emplace_back([&, t] { got[t] = j->Wait(); });
            for (auto& t : th) t.join();
            for (int t = 0; t < 4; ++t) CHECK(got[t] != nil && got[t] == got[0]);
            CHECK(RunAndCheck(dev, q, got[0], 100, nonce));
        }

        // ---- one compile at a time: queued jobs wait and finish in the order they were asked for ----
        {
            ps4gnm_kernels::Compiler one(dev, Options, 1);
            const unsigned n = 4;
            std::vector<std::shared_ptr<ps4gnm_kernels::Job>> js;
            for (unsigned k = 0; k < n; ++k) {
                const std::string s = KernelSource(200 + k, nonce);
                js.push_back(one.Start(HashOf(s), s));
            }
            CHECK(one.Unfinished() == n);
            // first in, first compiled: when job 0 is done the last two have not even started
            js[0]->Wait();
            CHECK(!js[2]->Done() && !js[3]->Done());
            js[2]->Wait();
            CHECK(js[1]->Done());
            CHECK(!js[3]->Done());
            js[3]->Wait();
            CHECK(one.PeakRunning() == 1);
            CHECK(one.Unfinished() == 0);
            for (unsigned k = 0; k < n; ++k) CHECK(js[k]->Done() && js[k]->Error().empty());
            CHECK(js[n - 1]->CompileMs() > 0);
            for (unsigned k = 0; k < n; ++k) CHECK(RunAndCheck(dev, q, js[k]->Wait(), 200 + k, nonce));
        }
        // ---- priorities: kernels start before queued draw shaders; a dispatch request moves a
        //      queued draw-shader job ahead; the completion callback runs once with the library ----
        {
            ps4gnm_kernels::Compiler one(dev, Options, 1);
            using C = ps4gnm_kernels::Compiler;
            std::atomic<int> calls{0};
            std::atomic<bool> lib_ok{true};
            auto cb = [&](const ps4gnm_kernels::Job& j) {
                calls++;
                if (!j.Library() || !j.Done() || !j.Error().empty()) lib_ok = false;
            };
            std::vector<std::shared_ptr<ps4gnm_kernels::Job>> d;
            for (unsigned k = 0; k < 4; ++k) { // draw shaders: the first runs, three queue
                const std::string s = KernelSource(400 + k, nonce);
                d.push_back(one.Start(HashOf(s), s, nullptr, C::kDraw, cb));
            }
            const std::string ks = KernelSource(500, nonce);
            auto kern = one.Start(HashOf(ks), ks, nullptr, C::kDispatch, cb); // queued after d[3]
            const std::string ps = KernelSource(403, nonce);
            bool started = true;
            auto promoted = one.Start(HashOf(ps), ps, &started, C::kDispatch); // d[3], asked by a dispatch
            CHECK(!started && promoted == d[3]);
            kern->Wait();
            // the kernel ran right after the job that was running: draw shaders 1 and 2 still wait
            CHECK(!d[1]->Done() && !d[2]->Done());
            d[3]->Wait();
            // then the promoted draw shader, still ahead of 1 and 2
            CHECK(!d[1]->Done() && !d[2]->Done());
            for (auto& j : d) j->Wait();
            for (unsigned k = 0; k < 4; ++k) CHECK(RunAndCheck(dev, q, d[k]->Wait(), 400 + k, nonce));
            for (int t = 0; t < 100 && calls.load() < 5; ++t) usleep(10000);
            CHECK(calls.load() == 5); // once per started job (the promotion call passed none)
            CHECK(lib_ok.load());
        }
        // ---- the destructor waits for compiles still queued or running ----
        {
            std::shared_ptr<ps4gnm_kernels::Job> last;
            {
                ps4gnm_kernels::Compiler c2(dev, Options, 1);
                for (unsigned k = 0; k < 3; ++k) {
                    const std::string s = KernelSource(300 + k, nonce);
                    last = c2.Start(HashOf(s), s);
                }
                CHECK(!last->Done());
            }
            CHECK(last->Done());
        }
    }
    if (g_fail) {
        fprintf(stderr, "kernel_compile_test: %d checks FAILED\n", g_fail);
        return 1;
    }
    fprintf(stderr, "kernel_compile_test: PASS\n");
    return 0;
}
