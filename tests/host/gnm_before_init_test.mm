// The renderer's entry points the command processor reaches before the first draw or dispatch
// (ps4draw::Init runs at the first one): a game's first command buffers start with compute
// barriers, flushes and fence actions (The Last of Us: a CS partial flush before its first
// dispatch), and every other guarded entry point (guest writes, CP DMA, submits, extent hints,
// kernel compile waits, the GPU stall hook, shutdown). The renderer has no backend yet (ps4draw
// State::be), so each must do nothing (a fence action runs at once, a DMA is left to the CPU)
// instead of reaching for the backend.
#include <stdio.h>

#include "ps4_gnm_draw.h"

namespace {
int g_fail = 0;
#define CHECK(c, ...)                                                                   \
    do {                                                                                \
        if (!(c)) {                                                                     \
            fprintf(stderr, "gnm_before_init_test: FAIL %s:%d: ", __FILE__, __LINE__); \
            fprintf(stderr, __VA_ARGS__);                                               \
            fprintf(stderr, "\n");                                                      \
            g_fail++;                                                                   \
        }                                                                               \
    } while (0)
} // namespace

int main() {
    CHECK(!ps4draw::Enabled(), "the renderer runs before Init");
    ps4draw::ComputeBarrier(ps4draw::kQueueGfx);
    ps4draw::ComputeBarrier(ps4draw::kQueueCompute);
    ps4draw::Flush(false);
    ps4draw::Flush(true);
    bool ran = false;
    ps4draw::AfterGpu([&] { ran = true; });
    CHECK(ran, "a fence action before Init did not run at once");
    ps4draw::NotifyGuestWrite(0x100000, 4096, false, 0);
    ps4draw::NotifyGuestWrite(0x100000, 4096, true, 0xABCD, true);
    CHECK(!ps4draw::GpuDma(false, true, 0, 0x12345678, false, 0x100000, 64), "a CP DMA was encoded before Init");
    ps4draw::OnSubmit();
    const uint32_t cb[8] = {64 | 64u << 16};
    ps4draw::SetExtentHints(cb, 0);
    ps4draw::WaitKernelCompiles();
    ps4draw::DebugStallGpu();
    CHECK(!ps4draw::HasPendingWork(), "work pending before Init");
    CHECK(!ps4draw::Enabled(), "the renderer started without Init");
    ps4draw::Shutdown();
    if (g_fail) return 1;
    printf("gnm_before_init_test: PASS\n");
    return 0;
}
