// SPDX-FileCopyrightText: Copyright 2024 shadPS4 Emulator Project
// SPDX-License-Identifier: GPL-2.0-or-later

#include "shader_recompiler/backend/spirv/emit_spirv_instructions.h"
#include "shader_recompiler/backend/spirv/spirv_emit_context.h"

namespace Shader::Backend::SPIRV {

Id SubgroupScope(EmitContext& ctx) {
    return ctx.ConstU32(static_cast<u32>(spv::Scope::Subgroup));
}

Id EmitWarpId(EmitContext& ctx) {
    UNREACHABLE();
}

Id EmitLaneId(EmitContext& ctx) {
    return ctx.OpLoad(ctx.U32[1], ctx.subgroup_local_invocation_id);
}

Id EmitQuadBroadcast(EmitContext& ctx, Id value, Id index) {
    return ctx.OpGroupNonUniformQuadBroadcast(ctx.U32[1], SubgroupScope(ctx), value, index);
}

// PS4Recomp: the value of the first invocation in EXEC (of invocation 0 when EXEC has none, as
// GCN reads lane 0 then). Plain broadcast of the first executing invocation when every executing
// invocation is in EXEC.
Id EmitReadFirstLane(EmitContext& ctx, Id value, const IR::Value& exec) {
    if (exec.IsImmediate() && exec.U1()) {
        return ctx.OpGroupNonUniformBroadcastFirst(ctx.U32[1], SubgroupScope(ctx), value);
    }
    const Id ballot{ctx.OpGroupNonUniformBallot(ctx.U32[4], SubgroupScope(ctx), ctx.Def(exec))};
    const Id first{ctx.OpGroupNonUniformBallotFindLSB(ctx.U32[1], SubgroupScope(ctx), ballot)};
    const Id none{ctx.OpIEqual(ctx.U1[1], first, ctx.ConstU32(~0u))};
    const Id lane{ctx.OpSelect(ctx.U32[1], none, ctx.u32_zero_value, first)};
    return ctx.OpGroupNonUniformBroadcast(ctx.U32[1], SubgroupScope(ctx), value, lane);
}

Id EmitShuffle(EmitContext& ctx, Id value, Id index) {
    return ctx.OpGroupNonUniformShuffle(ctx.U32[1], SubgroupScope(ctx), value, index);
}

Id EmitShuffleXor(EmitContext& ctx, Id value, Id mask) {
    return ctx.OpGroupNonUniformShuffleXor(ctx.U32[1], SubgroupScope(ctx), value, mask);
}

Id EmitReadLane(EmitContext& ctx, Id value, Id lane) {
    return ctx.OpGroupNonUniformBroadcast(ctx.U32[1], SubgroupScope(ctx), value, lane);
}

// PS4Recomp: KNOWN GAP. v_writelane should give `write_value` in lane `lane` and `value` in the
// others; this emits 0 for the whole register (shadPS4's behaviour). The correct per-lane select
// (PS4Recomp commit 180a0fe) made Uncharted 4's boat-level async compute CS with spilled V#s and
// pointers run past the GPU watchdog, and rendering stopped (black screen); reverted in 157e7c7.
// The cause needs that dispatch's real inputs (a boat-frame capture); see the Task 2.5 report of
// the U4 graphics plan (2026-10-21). Uses that reach this emitter are
// counted in Info::zeroed_write_lanes, logged by the translator and by the renderer per shader.
Id EmitWriteLane(EmitContext& ctx, Id value, Id write_value, u32 lane) {
    return ctx.u32_zero_value;
}

Id EmitBallot(EmitContext& ctx, Id bit) {
    const Id ballot{ctx.OpGroupNonUniformBallot(ctx.U32[4], SubgroupScope(ctx), bit)};
    return ctx.OpBitcast(ctx.U64, ctx.OpVectorShuffle(ctx.U32[2], ballot, ballot, 0, 1));
}

Id EmitBallotFindLsb(EmitContext& ctx, Id mask) {
    const Id value{ctx.OpCompositeConstruct(ctx.U32[4], ctx.OpBitcast(ctx.U32[2], mask),
                                            ctx.u32_zero_value, ctx.u32_zero_value)};
    return ctx.OpGroupNonUniformBallotFindLSB(ctx.U32[1], SubgroupScope(ctx), value);
}

Id EmitInverseBallot(EmitContext& ctx, Id mask) {
    const Id value{ctx.OpCompositeConstruct(ctx.U32[4], ctx.OpBitcast(ctx.U32[2], mask),
                                            ctx.u32_zero_value, ctx.u32_zero_value)};
    return ctx.OpGroupNonUniformInverseBallot(ctx.U1[1], SubgroupScope(ctx), value);
}

Id EmitGroupAny(EmitContext& ctx, Id bit) {
    return ctx.OpGroupNonUniformAny(ctx.U1[1], SubgroupScope(ctx), bit);
}

} // namespace Shader::Backend::SPIRV
