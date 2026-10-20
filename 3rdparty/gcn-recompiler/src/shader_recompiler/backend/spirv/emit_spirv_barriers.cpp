// SPDX-FileCopyrightText: Copyright 2021 yuzu Emulator Project
// SPDX-License-Identifier: GPL-2.0-or-later

#include "shader_recompiler/backend/spirv/emit_spirv_instructions.h"
#include "shader_recompiler/backend/spirv/spirv_emit_context.h"

namespace Shader::Backend::SPIRV {
namespace {
void MemoryBarrier(EmitContext& ctx, spv::Scope scope) {
    const auto semantics{
        spv::MemorySemanticsMask::AcquireRelease | spv::MemorySemanticsMask::UniformMemory |
        spv::MemorySemanticsMask::WorkgroupMemory | spv::MemorySemanticsMask::AtomicCounterMemory |
        spv::MemorySemanticsMask::ImageMemory};
    ctx.OpMemoryBarrier(ctx.ConstU32(static_cast<u32>(scope)),
                        ctx.ConstU32(static_cast<u32>(semantics)));
}
} // Anonymous namespace

void EmitBarrier(EmitContext& ctx) {
    const auto execution{spv::Scope::Workgroup};
    spv::Scope memory;
    spv::MemorySemanticsMask memory_semantics;
    if (ctx.sw_stage == Shader::SwStage::TessellationControl) {
        memory = spv::Scope::Invocation;
        memory_semantics = spv::MemorySemanticsMask::MaskNone;
    } else {
        memory = spv::Scope::Workgroup;
        memory_semantics =
            spv::MemorySemanticsMask::AcquireRelease | spv::MemorySemanticsMask::WorkgroupMemory;
        if (ctx.sw_stage == Shader::SwStage::Compute) {
            // PS4Recomp: GCN shaders issue s_waitcnt before s_barrier, so global memory writes
            // of the workgroup are visible to its other waves after the barrier (they share the
            // CU's write-through L1). Metal only guarantees that with mem_device/mem_texture
            // barrier flags, so include buffer and image memory for compute.
            memory_semantics = memory_semantics | spv::MemorySemanticsMask::UniformMemory |
                               spv::MemorySemanticsMask::ImageMemory;
        }
    }
    ctx.OpControlBarrier(ctx.ConstU32(static_cast<u32>(execution)),
                         ctx.ConstU32(static_cast<u32>(memory)),
                         ctx.ConstU32(static_cast<u32>(memory_semantics)));
}

void EmitSubgroupBarrier(EmitContext& ctx) {
    const auto semantics{static_cast<u32>(spv::MemorySemanticsMask::AcquireRelease |
                                          spv::MemorySemanticsMask::WorkgroupMemory)};
    // PS4Recomp: emitted as a subgroup-scope OpControlBarrier rather than OpMemoryBarrier.
    // SPIRV-Cross (MSL) drops an OpControlBarrier that directly follows an OpMemoryBarrier,
    // assuming the memory barrier already was a threadgroup barrier; after a subgroup memory
    // barrier that silently removed the next workgroup barrier (s_barrier), e.g. between the
    // steps of an LDS reduction, so other SIMD groups read stale shared memory. Both forms
    // become simdgroup_barrier(mem_flags::mem_threadgroup) in MSL.
    ctx.OpControlBarrier(ctx.ConstU32(static_cast<u32>(spv::Scope::Subgroup)),
                         ctx.ConstU32(static_cast<u32>(spv::Scope::Subgroup)),
                         ctx.ConstU32(semantics));
}

void EmitWorkgroupMemoryBarrier(EmitContext& ctx) {
    MemoryBarrier(ctx, spv::Scope::Workgroup);
}

void EmitDeviceMemoryBarrier(EmitContext& ctx) {
    MemoryBarrier(ctx, spv::Scope::Device);
}

} // namespace Shader::Backend::SPIRV
