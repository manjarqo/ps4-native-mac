// A crash after renderer work, with the GPU stalled: the runtime's crash handler ends the process
// with exit(1) (so the logs flush), which runs the exit handlers and static destruction. The
// renderer's exit handler (ReleaseBackend) must then do nothing: committing and waiting for a
// stalled GPU from a crashed process would hold the exit for the GPU watchdog (PS4_GNM_GPU_TIMEOUT)
// and the backend's destructor. ps4_host_crashing, set by the crash handler, makes it return at
// once, and the backend is not destroyed.
//
// run_host_tests.sh runs it with PS4_GNM_METAL=4 PS4_GNM_RESIDENCY_CHECK=1 and on Metal 3. It
// prints "gnm_crash_exit_test: crashing at <unix time>" right before the fault; the script requires
// the crash report, exit status 1, and an exit within 2 s of that time.
#include <stdio.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/time.h>

#import <Metal/Metal.h>

#include "ps4_gnm_draw.h"

int main() {
    @autoreleasepool {
        recomp_install_crash_handler();
        setenv("PS4_GNM_SYNC_COMPILE", "1", 1);
        setenv("PS4_GNM_NO_SHADER_CACHE", "1", 1);
        setenv("PS4_GNM_NO_PSO_ARCHIVE", "1", 1);
        setenv("PS4_GNM_NO_LIB_STORE", "1", 1);
        setenv("PS4_GNM_MEM_LOG", "0", 1);
        const uint64_t mem_size = 64ull << 20;
        void* m = mmap(nullptr, mem_size, PROT_READ | PROT_WRITE, MAP_ANON | MAP_PRIVATE | MAP_NORESERVE, -1, 0);
        if (m == MAP_FAILED) {
            fprintf(stderr, "gnm_crash_exit_test: FAIL: no guest memory\n");
            return 2;
        }
        static GuestContext ctx;
        memset(&ctx, 0, sizeof(ctx));
        ctx.mem_base = (uint8_t*)m;
        ctx.mem_size = mem_size;
        ctx.process_ctx = &ctx;
        pthread_mutex_init(&ctx.vm_mutex, nullptr);
        if (!ps4draw::Init(&ctx)) {
            fprintf(stderr, "gnm_crash_exit_test: FAIL: the renderer did not start\n");
            return 2;
        }
        ps4draw::DebugStallGpu();      // the GPU waits for an event nothing signals
        ps4draw::AfterGpu([] {});      // commits the stalled command buffer
        if (!ps4draw::HasPendingWork()) {
            fprintf(stderr, "gnm_crash_exit_test: FAIL: no work in flight before the crash\n");
            return 2;
        }
        struct timeval tv;
        gettimeofday(&tv, nullptr);
        printf("gnm_crash_exit_test: crashing at %.3f\n", tv.tv_sec + tv.tv_usec / 1e6);
        fflush(stdout);
        *(volatile int*)(uintptr_t)8 = 1; // SIGSEGV: the crash handler reports it and calls exit(1)
    }
    return 0;
}
