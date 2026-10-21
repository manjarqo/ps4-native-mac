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
int32_t sceVideoOutSubmitFlip(GuestContext *ctx, int32_t handle, int32_t idx, uint32_t mode, int64_t arg) {
    (void)ctx, (void)handle, (void)idx, (void)mode, (void)arg;
    return 0;
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
    sceGnmUnmapComputeQueue(1, 0);
    check(g_resets == 2, "unmapping resets the slot");
    check(g_seen == 0x66, "unmapping resets it before the mapping is cleared");
    return g_fail;
}
