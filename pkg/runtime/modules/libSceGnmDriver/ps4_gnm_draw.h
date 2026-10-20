// SPDX-License-Identifier: GPL-2.0-or-later
/*
 * PS4Recomp - native Metal rendering backend for the GNM command processor.
 *
 * ps4_gnm_metal.mm walks the PM4 streams (register file, fences, DMA, ...) and calls into this
 * module for every draw / dispatch. Here the GCN shaders are recompiled to MSL (gcn_recompiler),
 * pipelines are built from the Liverpool register file (ps4_gnm_resources), resources are bound
 * straight out of guest memory (UMA, no-copy MTLBuffers) and the work is encoded into Metal
 * command buffers.
 *
 * The draw/dispatch flow is a port of shadPS4's Vulkan rasterizer
 * (src/video_core/renderer_vulkan/vk_rasterizer.cpp, vk_pipeline_cache.cpp,
 *  vk_graphics_pipeline.cpp, vk_compute_pipeline.cpp, vk_pipeline_common.cpp).
 * SPDX-FileCopyrightText: Copyright 2024-2026 shadPS4 Emulator Project
 * SPDX-License-Identifier: GPL-2.0-or-later
 *
 * All functions must be called with the GNM processing lock held (ps4_gnm_metal.mm's
 * g_state.mutex), except where noted.
 */
#ifndef PS4_GNM_DRAW_H
#define PS4_GNM_DRAW_H

#include <stddef.h>
#include <stdint.h>

#include <functional>

#include "recomp_runtime.h"

namespace ps4draw {

struct DrawArgs {
    bool indexed = false;
    uint64_t index_base = 0;   // guest address of the index buffer (INDEX_BASE / DRAW_INDEX_2)
    uint32_t index_type = 0;   // VGT_INDEX_TYPE: 0 = 16 bit, 1 = 32 bit
    uint32_t index_offset = 0; // first index (DRAW_INDEX_OFFSET_2)
    uint32_t count = 0;        // index / vertex count
    uint32_t max_index = 0;    // max_size of the index buffer (indices), 0 = unknown
    uint32_t num_instances = 1;
    const char* name = "draw";
    // DRAW_INDIRECT / DRAW_INDEX_INDIRECT executed on the GPU: guest address of the argument
    // record (layout identical to MTLDraw[Indexed]PrimitivesIndirectArguments), and the user
    // data slots (0..15) the CP would write baseVertex / startInstance into (-1: none).
    uint64_t indirect_addr = 0;
    int base_vertex_ud = -1;
    int start_instance_ud = -1;
};

// Initializes Metal state on first use. Returns false if the backend is disabled
// (PS4_GNM_METAL_DRAW=0) or Metal is unavailable.
bool Init(GuestContext* ctx);
bool Enabled();

// CLEAR_STATE: reset the register file to the hardware defaults (shadPS4 Regs::SetDefaults).
void SetRegDefaults(uint32_t* regs);

// Returns false only for an indirect draw that cannot take its arguments from GPU memory
// (nothing was encoded; the caller reads the arguments on the CPU and draws directly).
bool Draw(GuestContext* ctx, const uint32_t* regs, const DrawArgs& args);
// Compute dispatch with the COMPUTE_* registers in `regs`. indirect_addr != 0: read the group
// counts from guest memory at that address (GPU side).
void Dispatch(GuestContext* ctx, const uint32_t* regs, uint32_t dim_x, uint32_t dim_y,
              uint32_t dim_z, uint64_t indirect_addr, const char* queue);

// Run `fn` once all GPU work encoded so far has completed (fences/labels/interrupts: EOP,
// RELEASE_MEM, EOS). Commits the open command buffer. Actions run in submission order, on the
// calling thread when nothing is in flight, otherwise on Metal's completion thread.
void AfterGpu(std::function<void()> fn);

// Surface extents from the NOP hints after CB/DB register setup (0 = unknown); raw = w | h << 16.
void SetExtentHints(const uint32_t cb[8], uint32_t db);

// Called once per sceGnmSubmit* (trace windows, stats).
void OnSubmit();

// End of a command stream run (CP thread): waits for compute kernels that its dispatches still
// compile in the background (ps4_gnm_kernel_compile.h), so the CP does not run further ahead.
void WaitKernelCompiles();

// True if GPU work was encoded since the last Flush(true).
bool HasPendingWork();
// Guest dispatches run concurrently (as consecutive dispatches do on GCN); the command
// processor calls this where the guest synchronizes (cache flushes, partial flushes, fences,
// waits, CP writes), so later dispatches see the memory written by earlier ones.
void ComputeBarrier();
// Commit the open command buffer; wait for all submitted work to finish when `wait`.
void Flush(bool wait);

// CP DMA fill / CPU-side writes of guest memory (fast-clear metadata tracking, texture
// invalidation).
void NotifyGuestWrite(uint64_t addr, uint64_t size, bool is_fill, uint32_t fill_value);

// 64 KiB GDS backing store, shared between CP DMA (CPU) and shaders (GPU).
uint8_t* Gds();
// Encodes a CP DMA_DATA copy (or a 32-bit fill when src_fill) between guest memory and GDS on
// the GPU timeline, behind the work encoded so far, so the CPU does not wait for the GPU.
// Returns false if it cannot (unaligned range, unmapped memory); the caller then drains and
// copies on the CPU.
bool GpuDma(bool src_gds, bool src_fill, uint64_t src, uint32_t fill_value, bool dst_gds, uint64_t dst, uint32_t n);

// Presentation: if the display buffer at `addr` is (or was produced from) a GPU render target,
// render it into a BGRA8 texture and hand it to the Metal screen behind the frame's GPU work,
// without waiting for the GPU. Returns true on success; `on_done` (if any) then runs once the
// GPU has executed the presentation (like AfterGpu). On false, all GPU work has completed and
// `on_done` is not called.
bool Present(GuestContext* ctx, uint64_t addr, uint32_t width, uint32_t height, uint32_t pitch,
             uint32_t tiling_mode, uint32_t pixel_format, std::function<void()> on_done);

void Shutdown();

} // namespace ps4draw

#endif // PS4_GNM_DRAW_H
