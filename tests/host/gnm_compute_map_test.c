// Mapping a compute queue (sceGnmMapComputeQueue / sceGnmUnmapComputeQueue in ps4_gnmdriver.c)
// drops the slot's waiting submissions (ps4_gnm_metal_reset_compute_queue) before the new
// mapping is published: the read pointer is zeroed only after the reset. Resetting after
// publishing left a window where the renderer's watchdog could resume an old submission, run
// packets from the old ring and write its old read pointer over the new mapping's zero.
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>

#include "ps4_equeue.h"
#include "ps4_gnmdriver.h"

static int g_fail;
static uint32_t *g_read_ptr;
static uint32_t g_seen = 0xffffffffu;
static int g_resets;

static void check(int ok, const char *what) {
    printf("%s: %s\n", ok ? "ok" : "FAIL", what);
    if (!ok) g_fail = 1;
}

// the renderer side
void ps4_gnm_metal_reset_compute_queue(uint32_t slot) {
    (void)slot;
    g_resets++;
    if (g_read_ptr) g_seen = *g_read_ptr;
}
int32_t ps4_gnm_metal_process_compute_packets(GuestContext *ctx, const uint32_t *w, uint32_t n, uint32_t p, uint32_t s,
                                              uint32_t *rp, uint32_t rs, uint32_t rb) {
    (void)ctx, (void)w, (void)n, (void)p, (void)s, (void)rp, (void)rs, (void)rb;
    return 0;
}
int32_t ps4_gnm_metal_process_command_buffers(GuestContext *ctx, uint32_t count, const uint64_t *a, const uint32_t *b,
                                              const uint64_t *c, const uint32_t *d) {
    (void)ctx, (void)count, (void)a, (void)b, (void)c, (void)d;
    return 0;
}
void ps4_gnm_metal_destroy(void) {}
int ps4_equeue_exists(OrbisKernelEqueue eq) { (void)eq; return 0; }
int ps4_equeue_trigger_event(OrbisKernelEqueue eq, uint64_t ident, int16_t filter, int64_t data, void *udata) {
    (void)eq, (void)ident, (void)filter, (void)data, (void)udata;
    return 0;
}
int ps4_equeue_remove_events(OrbisKernelEqueue eq, uint64_t ident, int16_t filter) {
    (void)eq, (void)ident, (void)filter;
    return 0;
}
uint64_t recomp_vm_alloc_named_aligned(GuestContext *ctx, size_t size, size_t alignment, int prot, int flags,
                                       const char *name) {
    (void)ctx, (void)size, (void)alignment, (void)prot, (void)flags, (void)name;
    return 0;
}
int32_t ps4_videoout_submit_flip(GuestContext *ctx, int32_t handle, int32_t idx, uint32_t mode, int64_t arg,
                                 int gpu_flip) {
    (void)ctx, (void)handle, (void)idx, (void)mode, (void)arg, (void)gpu_flip;
    return 0;
}
int32_t sceVideoOutGetBufferLabelAddress(GuestContext *ctx, int32_t handle, uint64_t *label_addr) {
    (void)ctx, (void)handle, (void)label_addr;
    return (int32_t)0x8029000Bu; // no VideoOut here: SCE_VIDEO_OUT_ERROR_INVALID_HANDLE
}

int main(void) {
    static uint32_t read_ptr;
    g_read_ptr = &read_ptr;
    read_ptr = 0x55; // left by the previous user of the read pointer
    const int32_t vqid = sceGnmMapComputeQueue(1, 0, 0x100000, 256, &read_ptr);
    check(vqid > 0, "the queue maps");
    check(g_resets == 1, "mapping resets the slot");
    check(g_seen == 0x55, "the reset runs before the read pointer of the new mapping is published");
    check(read_ptr == 0, "the read pointer is zeroed");

    read_ptr = 0x66;
    g_seen = 0;
    sceGnmUnmapComputeQueue((uint32_t)vqid);
    check(g_resets == 2, "unmapping resets the slot");
    check(g_seen == 0x66, "unmapping resets it before the mapping is cleared");

    // sceGnmSetLsShader: 23 dwords (0x17), including SET_SH_REG(0x14b, ls_regs[3]) at dwords 20..22.
    uint32_t ls_dcb[23] = {0};
    uint32_t ls_regs[6] = {0x1111u, 0x0u, 0x3333u, 0x4444u, 0x5555u, 0x6666u};
    int32_t ls_ret = sceGnmSetLsShader(ls_dcb, 23, ls_regs, 0u);
    check(ls_ret == 0 && ls_dcb[20] == 0xC0017600u && ls_dcb[21] == 0x14Bu && ls_dcb[22] == 0x4444u,
          "sceGnmSetLsShader writes 23 dwords ending with SPI_SHADER_PGM_RSRC2_LS (0x14b)");

    // sceGnmComputeWaitOnAddress: 14 dwords (0x0e) and returns 0x0e.
    uint32_t wait_dcb[14] = {0};
    int32_t wait_ret = sceGnmComputeWaitOnAddress(wait_dcb, 14, 0x123456789ABCDEF0ULL, 0xFFFFFFFFu, 3u, 0x42u);
    check(wait_ret == 0x0e, "sceGnmComputeWaitOnAddress returns 14 dwords");
    check(wait_dcb[3] == 0xC0053C00u && wait_dcb[7] == 0x42u && wait_dcb[8] == 0xFFFFFFFFu,
          "sceGnmComputeWaitOnAddress emits WAIT_REG_MEM with ref and mask");

    // sceGnmSetPsShader(..., NULL): clears PS regs without overwriting CB_SHADER_MASK (0x008F).
    uint32_t ps_dcb[40] = {0};
    sceGnmSetPsShader(ps_dcb, 40, NULL);
    int wrote_cb_shader_mask = 0;
    for (int i = 0; i < 39; i++) {
        if (ps_dcb[i] == 0xC0016900u && ps_dcb[i + 1] == 0x008Fu) {
            wrote_cb_shader_mask = 1;
        }
    }
    check(!wrote_cb_shader_mask, "sceGnmSetPsShader(NULL) preserves CB_SHADER_MASK");

    // sceGnmPrepareFlip*: writes sentinel 0xabcdef10..0xabcdef13 into dcb[0].
    static uint8_t fake_mem[4096];
    GuestContext ctx = {0};
    ctx.mem_base = fake_mem;
    ctx.mem_size = sizeof(fake_mem);
    uint32_t *flip_dcb = (uint32_t *)(fake_mem + 256);
    ctx.rdi = 256;
    ctx.rsi = 0x14;
    shim_sceGnmPrepareFlip(&ctx);
    check((int32_t)ctx.rax == 0x0f && flip_dcb[0] == 0xabcdef10u, "sceGnmPrepareFlip writes 0xabcdef10");
    ctx.rdi = 256;
    ctx.rsi = 0x14;
    shim_sceGnmPrepareFlipWithEopInterrupt(&ctx);
    check((int32_t)ctx.rax == 0x14 && flip_dcb[0] == 0xabcdef12u, "sceGnmPrepareFlipWithEopInterrupt writes 0xabcdef12");
    ctx.rdi = 256;
    ctx.rsi = 0x14;
    shim_sceGnmPrepareFlipWithEopInterruptRequeued(&ctx);
    check((int32_t)ctx.rax == 0x14 && flip_dcb[0] == 0xabcdef13u, "sceGnmPrepareFlipWithEopInterruptRequeued writes 0xabcdef13");

    // sceGnmValidateCommandBuffers: returns 0x80D11001.
    check(sceGnmValidateCommandBuffers() == (int32_t)0x80D11001, "sceGnmValidateCommandBuffers returns 0x80D11001");
    return g_fail;
}
