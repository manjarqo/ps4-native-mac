// SPDX-License-Identifier: GPL-2.0-or-later
/*
 * PS4 GNM Metal Graphics Backend for PS4Recomp.
 * Translates AMD GCN Liverpool PM4 command streams directly to Apple Metal API.
 */

#ifndef PS4_GNM_METAL_H
#define PS4_GNM_METAL_H

#include "recomp_runtime.h"
#include <stdint.h>
#include <stdbool.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

// Initialize the Metal Command Processor subsystem
int ps4_gnm_metal_init(GuestContext *ctx);

// Process a batch of PM4 Draw Command Buffers (DCB) and Constant Command Buffers (CCB)
int32_t ps4_gnm_metal_process_command_buffers(GuestContext *ctx, uint32_t count,
                                             const uint64_t *dcb_gpu_addrs, const uint32_t *dcb_sizes_in_bytes,
                                             const uint64_t *ccb_gpu_addrs, const uint32_t *ccb_sizes_in_bytes);

// Walk a span of compute (MEC/ASC) ring packets: RELEASE_MEM / EVENT_WRITE_EOS / WRITE_DATA /
// INDIRECT_BUFFER are honored (labels + compute interrupts with irq id == pipe_id); other
// packets are skipped. If read_ptr is non-NULL it is advanced per packet as
// (read_base_dw + consumed) % ring_size_dw.
// queue_slot: index of the compute queue (selects its COMPUTE_* register state).
int32_t ps4_gnm_metal_process_compute_packets(GuestContext *ctx, const uint32_t *words, uint32_t size_dw,
                                              uint32_t pipe_id, uint32_t queue_slot, uint32_t *read_ptr,
                                              uint32_t ring_size_dw, uint32_t read_base_dw);

// The compute queue in `queue_slot` was mapped again or unmapped: drop its submissions that
// still wait (they point into the old ring).
void ps4_gnm_metal_reset_compute_queue(uint32_t queue_slot);

// Presentation hook for libSceVideoOut: if the display buffer at `addr` was rendered by the GPU,
// present it from the Metal texture (returns 1); returns 0 if the caller must present from guest
// memory instead (all GPU work has then completed). tiling_mode/pixel_format as given to
// sceVideoOutSetBufferAttribute. The presentation is queued behind the frame's GPU work without
// waiting; on 1, on_done(arg) (if non-NULL) runs once the GPU has executed it (possibly on another
// thread, possibly before this function returns), in order with the GPU fences.
int ps4_gnm_metal_present(GuestContext *ctx, uint64_t addr, uint32_t width, uint32_t height, uint32_t pitch,
                          uint32_t tiling_mode, uint32_t pixel_format, void (*on_done)(void *), void *arg);

// Synchronize / wait for GPU to become idle
void ps4_gnm_metal_wait_gpu_idle(void);

// Shut down Metal Command Processor
void ps4_gnm_metal_destroy(void);

#ifdef __cplusplus
}
#endif

#endif // PS4_GNM_METAL_H
