// A program that returns from main while renderer work is still on the GPU (gnm_replay and the
// host tests do; the game ends with _exit). The backend must be destroyed while everything its
// completion handlers use is alive: Init registers an exit handler (ps4draw ReleaseBackend) that
// completes the work and destroys the backend before the static objects of ps4_gnm_draw.mm are
// destroyed. Without it, static destruction destroys State's other members and the globals
// declared after it first, and the Metal 4 backend's destructor, which waits for the feedback of
// every commit, runs the remaining completion handlers against them.
//
// run_host_tests.sh runs it with PS4_GNM_METAL=4 PS4_GNM_RESIDENCY_CHECK=1 and on Metal 3, with the
// encoder thread (the exit handler hands its work to it) and with PS4_GNM_SYNC_ENCODE=1.
// The renderer's command buffer waits for an event that a thread signals 300 ms after main
// returned; a fence action behind it sets a flag. This program's own exit handler, registered
// before Init and so run after the renderer's, requires that the fence action ran by then.
#include <stdio.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>

#include <atomic>
#include <thread>

#import <Metal/Metal.h>

#include "ps4_gnm_draw.h"

namespace {
std::atomic<bool> g_fence_ran{false};

void CheckAtExit() {
    if (!g_fence_ran.load()) {
        fprintf(stderr, "gnm_exit_test: FAIL: the renderer's work was still in flight when the program's exit "
                        "handlers ran (no exit handler of the renderer completed it)\n");
        _exit(1);
    }
    printf("gnm_exit_test: PASS (the fence action ran before the exit handlers finished)\n");
    fflush(stdout);
}
} // namespace

int main() {
    @autoreleasepool {
        id<MTLDevice> dev = MTLCreateSystemDefaultDevice();
        if (!dev) {
            fprintf(stderr, "gnm_exit_test: FAIL: no Metal device\n");
            return 1;
        }
        atexit(CheckAtExit);
        // as gnm_replay: nothing outside this process (shader caches, pipeline archive, library store)
        setenv("PS4_GNM_SYNC_COMPILE", "1", 1);
        setenv("PS4_GNM_NO_SHADER_CACHE", "1", 1);
        setenv("PS4_GNM_NO_PSO_ARCHIVE", "1", 1);
        setenv("PS4_GNM_NO_LIB_STORE", "1", 1);
        setenv("PS4_GNM_MEM_LOG", "0", 1);
        const uint64_t mem_size = 64ull << 20;
        void* m = mmap(nullptr, mem_size, PROT_READ | PROT_WRITE, MAP_ANON | MAP_PRIVATE | MAP_NORESERVE, -1, 0);
        if (m == MAP_FAILED) {
            fprintf(stderr, "gnm_exit_test: FAIL: no guest memory\n");
            return 1;
        }
        static GuestContext ctx;
        memset(&ctx, 0, sizeof(ctx));
        ctx.mem_base = (uint8_t*)m;
        ctx.mem_size = mem_size;
        ctx.process_ctx = &ctx;
        pthread_mutex_init(&ctx.vm_mutex, nullptr);
        if (!ps4draw::Init(&ctx)) {
            fprintf(stderr, "gnm_exit_test: FAIL: the renderer did not start\n");
            return 1;
        }
        id<MTLSharedEvent> gate = [dev newSharedEvent];
        ps4draw::DebugGpuWait((__bridge void*)gate, 1);
        ps4draw::AfterGpu([] { g_fence_ran.store(true); }); // commits the command buffer
        if (g_fence_ran.load()) {
            fprintf(stderr, "gnm_exit_test: FAIL: the fence action ran before the gate opened\n");
            return 1;
        }
        std::thread([gate] {
            usleep(300000);
            gate.signaledValue = 1;
        }).detach();
    }
    return 0; // the work is in flight: exit handlers, then static destruction
}
