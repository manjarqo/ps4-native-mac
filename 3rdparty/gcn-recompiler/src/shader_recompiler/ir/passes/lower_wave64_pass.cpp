// SPDX-FileCopyrightText: Copyright 2026 shadPS4 Emulator Project
// SPDX-License-Identifier: GPL-2.0-or-later

#include <unordered_map>
#include <unordered_set>
#include "common/logging/classes.h"
#include "shader_recompiler/info.h"
#include "shader_recompiler/ir/basic_block.h"
#include "shader_recompiler/ir/breadth_first_search.h"
#include "shader_recompiler/ir/ir_emitter.h"
#include "shader_recompiler/ir/passes/ir_passes.h"
#include "shader_recompiler/ir/program.h"
#include "shader_recompiler/profile.h"

namespace Shader::Optimization {

static bool IsDivergentCondition(const IR::U1& condition) {
    if (condition.IsImmediate()) {
        return false;
    }
    const IR::Inst* const condition_inst = condition.Inst();
    return IR::BreadthFirstSearch(condition_inst,
                                  [](const IR::Inst* inst) -> std::optional<bool> {
                                      switch (inst->GetOpcode()) {
                                      case IR::Opcode::LaneId:
                                          return true;
                                      case IR::Opcode::GetAttributeU32:
                                          if (inst->Arg(0).Attribute() ==
                                              IR::Attribute::LocalInvocationId) {
                                              return true;
                                          }
                                          break;
                                      default:
                                          break;
                                      }
                                      return std::nullopt;
                                  })
        .value_or(false);
}

static std::vector<IR::Block*> FindUniformBlocks(const IR::Program& program) {
    using Type = IR::AbstractSyntaxNode::Type;

    struct ConditionalScope {
        const IR::Block* merge;
        bool divergent;
    };

    std::vector<IR::Block*> blocks;
    std::vector<ConditionalScope> conditionals;
    std::vector<const IR::Block*> loops;
    u32 divergence_depth{};
    for (const IR::AbstractSyntaxNode& node : program.syntax_list) {
        switch (node.type) {
        case Type::If: {
            const bool divergent = IsDivergentCondition(node.data.if_node.cond);
            conditionals.push_back({node.data.if_node.merge, divergent});
            divergence_depth += static_cast<u32>(divergent);
            break;
        }
        case Type::EndIf:
            ASSERT(!conditionals.empty() && conditionals.back().merge == node.data.end_if.merge);
            divergence_depth -= static_cast<u32>(conditionals.back().divergent);
            conditionals.pop_back();
            break;
        case Type::Loop:
            loops.push_back(node.data.loop.merge);
            break;
        case Type::Repeat:
            if (loops.empty() || loops.back() != node.data.repeat.merge) {
                return {};
            }
            loops.pop_back();
            break;
        case Type::Block:
            if (divergence_depth == 0 && loops.empty()) {
                blocks.push_back(node.data.block);
            }
            break;
        default:
            break;
        }
    }
    if (!conditionals.empty() || !loops.empty()) {
        return {};
    }
    return blocks;
}

static IR::Inst* FindBallotForMaskedBitCount(const IR::Inst& mbcnt) {
    IR::Value value = mbcnt.Arg(0);
    if (value.IsImmediate()) {
        return nullptr;
    }
    IR::Inst* inst = value.Inst();
    if (inst->GetOpcode() != IR::Opcode::CompositeExtractU32x2 || inst->Arg(0).IsImmediate()) {
        return nullptr;
    }
    inst = inst->Arg(0).Inst();
    if (inst->GetOpcode() != IR::Opcode::UnpackUint2x32 || inst->Arg(0).IsImmediate()) {
        return nullptr;
    }
    inst = inst->Arg(0).Inst();
    return inst->GetOpcode() == IR::Opcode::Ballot ? inst : nullptr;
}

// PS4Recomp: whether every lane of a wave holds the same value. Conservative: a value is uniform
// only when nothing it is computed from can differ between lanes (lane and invocation ids,
// per-lane attributes, phis, cross-lane operations, workgroup memory, atomics).
class WaveUniformity {
public:
    bool IsUniform(const IR::Value& value) {
        if (value.IsImmediate()) {
            return true;
        }
        IR::Inst* const root = value.Inst();
        if (const auto it = known.find(root); it != known.end()) {
            return it->second;
        }
        // Post-order walk: an instruction is decided once its arguments are, or by itself.
        stack.clear();
        stack.push_back({root, 0});
        while (!stack.empty()) {
            Frame& top = stack.back();
            IR::Inst* const inst = top.inst;
            if (top.next_arg == 0) {
                if (const std::optional<bool> own = OwnUniformity(*inst)) {
                    known[inst] = *own;
                    stack.pop_back();
                    continue;
                }
            }
            std::optional<bool> decided;
            while (top.next_arg < inst->NumArgs()) {
                const IR::Value arg = inst->Arg(top.next_arg);
                if (!arg.IsImmediate()) {
                    const auto it = known.find(arg.Inst());
                    if (it == known.end()) {
                        break; // decide the argument first
                    }
                    if (!it->second) {
                        decided = false;
                        break;
                    }
                }
                ++top.next_arg;
            }
            if (!decided && top.next_arg < inst->NumArgs()) {
                IR::Inst* const arg_inst = inst->Arg(top.next_arg).Inst();
                stack.push_back({arg_inst, 0}); // invalidates `top`
                continue;
            }
            known[inst] = decided.value_or(true);
            stack.pop_back();
        }
        return known.at(root);
    }

private:
    struct Frame {
        IR::Inst* inst;
        size_t next_arg;
    };

    // Uniformity decided by the instruction itself, or nullopt when its arguments decide it.
    static std::optional<bool> OwnUniformity(const IR::Inst& inst) {
        if (inst.MayHaveSideEffects()) {
            return false;
        }
        switch (inst.GetOpcode()) {
        case IR::Opcode::Phi:
        case IR::Opcode::LaneId:
        case IR::Opcode::WarpId:
        case IR::Opcode::QuadBroadcast:
        case IR::Opcode::Shuffle:
        case IR::Opcode::ShuffleXor:
        case IR::Opcode::ReadFirstLane:
        case IR::Opcode::ReadLane:
        case IR::Opcode::WriteLane:
        case IR::Opcode::Ballot:
        case IR::Opcode::BallotFindLsb:
        case IR::Opcode::InverseBallot:
        case IR::Opcode::GroupAny:
        case IR::Opcode::MaskedBitCount32:
        case IR::Opcode::DataAppend:
        case IR::Opcode::DataConsume:
        case IR::Opcode::LoadSharedU16:
        case IR::Opcode::LoadSharedU32:
        case IR::Opcode::LoadSharedU64:
            return false;
        case IR::Opcode::GetAttribute:
        case IR::Opcode::GetAttributeU32: {
            const IR::Attribute attr = inst.Arg(0).Attribute();
            return attr == IR::Attribute::WorkgroupId || attr == IR::Attribute::WorkgroupIndex;
        }
        default:
            return std::nullopt;
        }
    }

    std::unordered_map<IR::Inst*, bool> known;
    std::vector<Frame> stack;
};

// PS4Recomp: v_readfirstlane carries EXEC (it ignores the EXEC scope, so it can run where some
// executing lanes are outside EXEC). Inside a scope whose condition is that same EXEC value, the
// executing lanes are the EXEC lanes: the operand becomes true and the plain subgroup broadcast
// of the first executing lane is emitted.
static void DropRedundantReadFirstLaneExec(IR::Program& program) {
    using Type = IR::AbstractSyntaxNode::Type;
    std::vector<IR::Value> conds;
    for (const IR::AbstractSyntaxNode& node : program.syntax_list) {
        switch (node.type) {
        case Type::If: {
            // the structurizer refers to the condition through ConditionRef
            IR::Value cond = node.data.if_node.cond;
            if (const IR::Inst* ref = cond.TryInst();
                ref && ref->GetOpcode() == IR::Opcode::ConditionRef) {
                cond = ref->Arg(0);
            }
            conds.push_back(cond);
            break;
        }
        case Type::EndIf:
            conds.pop_back();
            break;
        case Type::Block:
            for (IR::Inst& inst : node.data.block->Instructions()) {
                if (inst.GetOpcode() != IR::Opcode::ReadFirstLane) {
                    continue;
                }
                const IR::Value exec = inst.Arg(1);
                if (!exec.IsImmediate() && std::ranges::find(conds, exec) != conds.end()) {
                    inst.SetArg(1, IR::Value{true});
                }
            }
            break;
        default:
            break;
        }
    }
}

// PS4Recomp: whether `value` is computed (through any chain of instructions) from one of `insts`.
static bool ReachesAny(const IR::Value& value, const std::unordered_set<const IR::Inst*>& insts) {
    if (value.IsImmediate()) {
        return false;
    }
    std::unordered_set<const IR::Inst*> visited{value.Inst()};
    std::vector<const IR::Inst*> pending{value.Inst()};
    while (!pending.empty()) {
        const IR::Inst* const inst = pending.back();
        pending.pop_back();
        if (insts.contains(inst)) {
            return true;
        }
        for (size_t i = 0; i < inst->NumArgs(); ++i) {
            const IR::Value arg = inst->Arg(i);
            if (!arg.IsImmediate() && visited.insert(arg.Inst()).second) {
                pending.push_back(arg.Inst());
            }
        }
    }
    return false;
}

// PS4Recomp: v_readlane of a register built by v_writelane (SGPRs spilled to VGPR lanes) in a
// wave64 that runs as two 32-wide subgroups. A lane of the other half lives in the other
// subgroup, which non-uniform control flow cannot reach. Each subgroup keeps both halves of such
// a register instead: the register value (its own half) and a shadow with the other half, which
// v_writelane to a lane of the other half updates. v_readlane picks the half holding its lane and
// reads it in the subgroup, with no exchange, in any control flow. Values not built by
// v_writelane have no shadow: their other half reads as this subgroup's (as before).
static void LowerSpilledLaneReads(IR::Program& program,
                                  std::unordered_set<const IR::Inst*>& local_reads) {
    std::unordered_set<IR::Inst*> built; // v_writelane results and phis of them
    std::vector<IR::Inst*> phis;
    for (IR::Block* block : program.blocks) {
        for (IR::Inst& inst : block->Instructions()) {
            if (inst.GetOpcode() == IR::Opcode::WriteLane) {
                built.insert(&inst);
            }
        }
    }
    if (built.empty()) {
        return;
    }
    for (bool changed = true; changed;) {
        changed = false;
        for (IR::Block* block : program.blocks) {
            for (IR::Inst& inst : block->Instructions()) {
                if (inst.GetOpcode() != IR::Opcode::Phi || built.contains(&inst)) {
                    continue;
                }
                for (size_t i = 0; i < inst.NumArgs(); ++i) {
                    const IR::Value arg = inst.Arg(i);
                    if (!arg.IsImmediate() && built.contains(arg.Inst())) {
                        built.insert(&inst);
                        phis.push_back(&inst);
                        changed = true;
                        break;
                    }
                }
            }
        }
    }
    std::unordered_map<const IR::Inst*, IR::Value> other;
    const auto other_of = [&](const IR::Value& value) {
        if (!value.IsImmediate()) {
            if (const auto it = other.find(value.Inst()); it != other.end()) {
                return it->second;
            }
        }
        return value;
    };
    const auto own_half = [](IR::IREmitter& ir) {
        return ir.BitwiseAnd(
            ir.ShiftRightLogical(ir.GetAttributeU32(IR::Attribute::LocalInvocationIndex), ir.Imm32(5u)),
            ir.Imm32(1u));
    };
    for (IR::Inst* phi : phis) {
        IR::Block* const block = phi->GetParent();
        IR::Inst* const shadow =
            &*block->PrependNewInst(IR::Block::InstructionList::s_iterator_to(*phi), IR::Opcode::Phi);
        shadow->SetFlags(IR::Type::U32);
        other[phi] = IR::Value{shadow};
    }
    for (IR::Block* block : program.blocks) {
        for (IR::Inst& inst : block->Instructions()) {
            if (inst.GetOpcode() != IR::Opcode::WriteLane) {
                continue;
            }
            IR::IREmitter ir{*block, IR::Block::InstructionList::s_iterator_to(inst)};
            const IR::U32 lane = ir.BitwiseAnd(IR::U32{inst.Arg(2)}, ir.Imm32(63u));
            const IR::U32 index = ir.GetAttributeU32(IR::Attribute::LocalInvocationIndex);
            const IR::U1 is_lane = ir.LogicalAnd(
                ir.IEqual(ir.BitwiseAnd(index, ir.Imm32(31u)), ir.BitwiseAnd(lane, ir.Imm32(31u))),
                ir.INotEqual(ir.ShiftRightLogical(lane, ir.Imm32(5u)), own_half(ir)));
            other[&inst] = ir.Select(is_lane, inst.Arg(1), other_of(inst.Arg(0)));
        }
    }
    for (IR::Inst* phi : phis) {
        IR::Inst* const shadow = other.at(phi).Inst();
        for (size_t i = 0; i < phi->NumArgs(); ++i) {
            shadow->AddPhiOperand(phi->PhiBlock(i), other_of(phi->Arg(i)));
        }
    }
    for (IR::Block* block : program.blocks) {
        for (IR::Inst& inst : block->Instructions()) {
            if (inst.GetOpcode() != IR::Opcode::ReadLane || inst.Arg(0).IsImmediate() ||
                !built.contains(inst.Arg(0).Inst())) {
                continue;
            }
            IR::IREmitter ir{*block, IR::Block::InstructionList::s_iterator_to(inst)};
            const IR::U32 lane = ir.BitwiseAnd(IR::U32{inst.Arg(1)}, ir.Imm32(63u));
            const IR::U1 own = ir.IEqual(ir.ShiftRightLogical(lane, ir.Imm32(5u)), own_half(ir));
            const IR::U32 value{ir.Select(own, inst.Arg(0), other_of(inst.Arg(0)))};
            const IR::U32 read = ir.ReadLane(value, ir.BitwiseAnd(lane, ir.Imm32(31u)));
            local_reads.insert(read.Inst());
            inst.ReplaceUsesWithAndRemove(read);
        }
    }
}

// PS4Recomp: GCN lane of this invocation (0..63). A wave64 compute shader on a smaller subgroup
// runs each wave as several subgroups, and its GCN lane is the local invocation index modulo 64.
static IR::U32 GcnLane(IR::IREmitter& ir, bool split) {
    if (split) {
        return ir.BitwiseAnd(ir.GetAttributeU32(IR::Attribute::LocalInvocationIndex), ir.Imm32(63u));
    }
    return ir.LaneId();
}

// Cross-lane operations whose result depends on the GCN wave layout. All stages: v_writelane
// becomes a per-lane select and v_readfirstlane drops EXEC where it is implied. Wave64 compute
// shaders run as two 32-wide subgroups when the host subgroup is smaller: their operations that
// cross the halves (ballots, readlane, readfirstlane, mbcnt) exchange through workgroup memory in
// uniform control flow, and 64-bit masks applied per lane test the lane's own bit.
void LowerWaveOpsPass(IR::Program& program, const RuntimeInfo& runtime_info,
                      const Profile& profile) {
    const auto [size_x, size_y, size_z] = runtime_info.hw.cs.workgroup_size;
    const u32 num_threads = size_x * size_y * size_z;
    const bool split = program.info.hw_stage == HwStage::Compute && profile.subgroup_size < 64 &&
                       num_threads > 32;

    DropRedundantReadFirstLaneExec(program);
    if (split) {
        // A value that is the same in every lane needs no exchange: any lane reads it. Code that
        // only fed such reads (e.g. a ballot picking the lane) is dead afterwards.
        WaveUniformity uniformity;
        for (IR::Block* block : program.blocks) {
            for (IR::Inst& inst : block->Instructions()) {
                if ((inst.GetOpcode() == IR::Opcode::ReadLane ||
                     inst.GetOpcode() == IR::Opcode::ReadFirstLane) &&
                    uniformity.IsUniform(inst.Arg(0))) {
                    inst.ReplaceUsesWith(inst.Arg(0));
                }
            }
        }
        DeadCodeEliminationPass(program);
    }

    std::unordered_set<const IR::Inst*> local_reads;
    if (split) {
        LowerSpilledLaneReads(program, local_reads);
    }

    // A workgroup whose last wave has 32 lanes or fewer: that wave has no upper half.
    const bool last_wave_half = num_threads % 64 != 0 && num_threads % 64 <= 32;
    std::vector<IR::Inst*> write_lanes;
    std::vector<IR::Inst*> inverse_ballots;
    std::vector<IR::Inst*> worklist;
    // ballots left to each subgroup (non-uniform control flow): their bits are in the
    // subgroup's own layout, lanes 32-63 in the low word
    std::unordered_set<const IR::Inst*> subgroup_ballots;
    const auto uniform_blocks = split ? FindUniformBlocks(program) : std::vector<IR::Block*>{};
    for (IR::Block* block : program.blocks) {
        const bool is_uniform = std::ranges::contains(uniform_blocks, block);
        const auto push_worklist = [&](IR::Inst& inst) {
            if (is_uniform) {
                worklist.push_back(&inst);
            } else {
                LOG_WARNING(Render_Recompiler, "{} instruction in non uniform control flow",
                            inst.GetOpcode());
                if (inst.GetOpcode() == IR::Opcode::Ballot) {
                    subgroup_ballots.insert(&inst);
                }
            }
        };
        for (IR::Inst& inst : block->Instructions()) {
            const IR::Opcode op = inst.GetOpcode();
            if (op == IR::Opcode::WriteLane) {
                write_lanes.push_back(&inst);
                continue;
            }
            if (!split) {
                continue;
            }
            if (op == IR::Opcode::InverseBallot) {
                inverse_ballots.push_back(&inst);
            } else if (op == IR::Opcode::ReadLane || op == IR::Opcode::ReadFirstLane) {
                if (!local_reads.contains(&inst)) {
                    push_worklist(inst);
                }
            } else if (op == IR::Opcode::Ballot) {
                const IR::Value bit = inst.Arg(0);
                if (is_uniform && bit.IsImmediate() && bit.U1()) {
                    // every lane of the wave runs this: the mask of the lanes the wave has
                    IR::IREmitter ir{*block, IR::Block::InstructionList::s_iterator_to(inst)};
                    IR::U64 mask = ir.Imm64(~u64{0});
                    if (num_threads % 64 != 0) {
                        const IR::U32 wave = ir.ShiftRightLogical(
                            ir.GetAttributeU32(IR::Attribute::LocalInvocationIndex), ir.Imm32(6u));
                        mask = IR::U64{ir.Select(ir.IEqual(wave, ir.Imm32(num_threads / 64)),
                                                 ir.Imm64((u64{1} << (num_threads % 64)) - 1), mask)};
                    }
                    inst.ReplaceUsesWithAndRemove(mask);
                } else {
                    push_worklist(inst);
                }
            } else if (op == IR::Opcode::MaskedBitCount32) {
                IR::Inst* const ballot = FindBallotForMaskedBitCount(inst);
                if (ballot == nullptr ||
                    std::ranges::contains(uniform_blocks, ballot->GetParent())) {
                    worklist.push_back(&inst);
                }
            }
        }
    }

    for (IR::Inst* inst : write_lanes) {
        // v_writelane: the lane named by the scalar operand (low 6 bits) takes the new value
        IR::IREmitter ir{*inst->GetParent(), IR::Block::InstructionList::s_iterator_to(*inst)};
        const IR::U1 is_lane = ir.IEqual(GcnLane(ir, split),
                                         ir.BitwiseAnd(IR::U32{inst->Arg(2)}, ir.Imm32(63u)));
        inst->ReplaceUsesWithAndRemove(ir.Select(is_lane, inst->Arg(1), inst->Arg(0)));
    }
    for (IR::Inst* inst : inverse_ballots) {
        // A mask built from a ballot left to each subgroup keeps the subgroup's own bit (the
        // layout it was made in): testing the wave lane's bit there reads 0 in lanes 32-63, and
        // loops waiting for their bit never ended (Uncharted 4 async CS with spilled V#s).
        if (!subgroup_ballots.empty() && ReachesAny(inst->Arg(0), subgroup_ballots)) {
            continue;
        }
        // a 64-bit mask applied per lane: this lane's bit, from the half holding the lane
        IR::IREmitter ir{*inst->GetParent(), IR::Block::InstructionList::s_iterator_to(*inst)};
        const IR::U32 lane = GcnLane(ir, true);
        const IR::Value halves = ir.UnpackUint2x32(IR::U64{inst->Arg(0)});
        const IR::U32 word = IR::U32{ir.Select(ir.ILessThan(lane, ir.Imm32(32u), false),
                                               ir.CompositeExtract(halves, 0),
                                               ir.CompositeExtract(halves, 1))};
        const IR::U32 bit =
            ir.BitFieldExtract(word, ir.BitwiseAnd(lane, ir.Imm32(31u)), ir.Imm32(1u));
        inst->ReplaceUsesWithAndRemove(ir.INotEqual(bit, ir.Imm32(0u)));
    }
    // A lane index or mask computed from a ballot left to each subgroup is in the subgroup's own
    // layout: the subgroup operation that matches it stays.
    if (!subgroup_ballots.empty()) {
        std::erase_if(worklist, [&](const IR::Inst* inst) {
            return (inst->GetOpcode() == IR::Opcode::ReadLane &&
                    ReachesAny(inst->Arg(1), subgroup_ballots)) ||
                   (inst->GetOpcode() == IR::Opcode::MaskedBitCount32 &&
                    ReachesAny(inst->Arg(0), subgroup_ballots));
        });
    }
    if (worklist.empty()) {
        return;
    }

    // Workgroup memory after the shader's own: one dword per subgroup, and for readfirstlane a
    // second array with each subgroup's value.
    const bool needs_values = std::ranges::any_of(worklist, [](const IR::Inst* inst) {
        return inst->GetOpcode() == IR::Opcode::ReadFirstLane;
    });
    const u32 num_subgroups = Common::AlignUp(num_threads, 64) / profile.subgroup_size;
    const u32 scratch_base = Common::AlignUp(runtime_info.hw.cs.shared_memory_size, sizeof(u64));
    const u32 values_base = scratch_base + num_subgroups * u32(sizeof(u32));
    const u32 scratch_size = (needs_values ? 2 : 1) * num_subgroups * u32(sizeof(u32));
    program.info.shared_memory_scratch_size =
        scratch_base + scratch_size - runtime_info.hw.cs.shared_memory_size;

    for (IR::Inst* inst : worklist) {
        LOG_INFO(Render_Recompiler, "Lowering {} instruction for wave64", inst->GetOpcode());
        IR::IREmitter ir{*inst->GetParent(), IR::Block::InstructionList::s_iterator_to(*inst)};
        const IR::U32 invocation_index = ir.GetAttributeU32(IR::Attribute::LocalInvocationIndex);
        const IR::U32 subgroup_id = ir.ShiftRightLogical(invocation_index, ir.Imm32(5));
        // byte offset of this subgroup's dword in an array, and of its wave's lower subgroup's
        const IR::U32 slot = ir.ShiftLeftLogical(subgroup_id, ir.Imm32(2u));
        const IR::U32 pair = ir.BitwiseAnd(slot, ir.Imm32(~7u));
        const IR::U32 offset = ir.IAdd(ir.Imm32(scratch_base), slot);
        const auto load_lo = [&](u32 base) {
            return IR::U32{ir.LoadShared(32, false, ir.IAdd(ir.Imm32(base), pair))};
        };
        // the dword of the wave's upper subgroup, 0 when the wave has no upper half
        const auto load_hi = [&](u32 base) {
            const IR::U32 hi = IR::U32{ir.LoadShared(32, false, ir.IAdd(ir.Imm32(base + 4u), pair))};
            if (!last_wave_half) {
                return hi;
            }
            const IR::U32 hi_first = ir.IAdd(ir.ShiftLeftLogical(pair, ir.Imm32(3u)), ir.Imm32(32u));
            return IR::U32{ir.Select(ir.ILessThan(hi_first, ir.Imm32(num_threads), false), hi,
                                     ir.Imm32(0u))};
        };
        if (inst->GetOpcode() == IR::Opcode::Ballot) {
            const IR::U32 mask_low =
                IR::U32{ir.CompositeExtract(ir.UnpackUint2x32(ir.Ballot(IR::U1{inst->Arg(0)})), 0)};
            ir.WriteShared(32, mask_low, offset);
            ir.Barrier();
            // PS4Recomp: two 32-bit loads of the subgroup pair instead of one 64-bit load. A
            // u64 view of workgroup memory next to the u32 one needs explicit workgroup layouts
            // (aliased blocks), which the MSL backend drops: the variables went undeclared and
            // Metal rejected the shader (Uncharted 4 async CS 0x130015c400).
            const IR::U32 lo = load_lo(scratch_base);
            const IR::U32 hi = load_hi(scratch_base);
            const IR::U64 mask = ir.PackUint2x32(ir.CompositeConstruct(lo, hi));
            ir.Barrier();
            inst->ReplaceUsesWithAndRemove(mask);
        } else if (inst->GetOpcode() == IR::Opcode::ReadLane) {
            // v_readlane: the lane is the low 6 bits of a scalar operand (the same in every lane)
            const IR::U32 lane = ir.BitwiseAnd(IR::U32{inst->Arg(1)}, ir.Imm32(63u));
            const IR::U32 lane32 = ir.BitwiseAnd(lane, ir.Imm32(31u));
            const IR::U32 half = ir.ShiftRightLogical(lane, ir.Imm32(5u));
            ir.WriteShared(32, ir.ReadLane(IR::U32{inst->Arg(0)}, lane32), offset);
            ir.Barrier();
            const IR::U32 value = IR::U32{ir.LoadShared(
                32, false,
                ir.IAdd(ir.IAdd(ir.Imm32(scratch_base), pair), ir.ShiftLeftLogical(half, ir.Imm32(2u))))};
            ir.Barrier();
            inst->ReplaceUsesWithAndRemove(value);
        } else if (inst->GetOpcode() == IR::Opcode::ReadFirstLane) {
            // v_readfirstlane: the first lane in EXEC across both halves, lane 0 when EXEC is 0.
            // Each subgroup publishes the value of its first EXEC lane (of its lane 0 without
            // one) and its half of EXEC. When EXEC is the executing lanes (true here), a lower
            // subgroup running this has the wave's first EXEC lane, and its value is the result.
            const IR::U32 value{inst->Arg(0)};
            const IR::U1 exec{inst->Arg(1)};
            const bool exec_is_executing = exec.IsImmediate() && exec.U1();
            ir.WriteShared(32, ir.ReadFirstLane(value, exec), ir.IAdd(ir.Imm32(values_base), slot));
            if (!exec_is_executing) {
                const IR::U32 exec_half =
                    IR::U32{ir.CompositeExtract(ir.UnpackUint2x32(ir.Ballot(exec)), 0)};
                ir.WriteShared(32, exec_half, offset);
            }
            ir.Barrier();
            IR::U32 result = load_lo(values_base);
            if (!exec_is_executing) {
                // no EXEC lane in the lower half: the upper half's first, if it has one
                const IR::U1 take_hi =
                    ir.LogicalAnd(ir.IEqual(load_lo(scratch_base), ir.Imm32(0u)),
                                  ir.INotEqual(load_hi(scratch_base), ir.Imm32(0u)));
                result = IR::U32{ir.Select(take_hi, load_hi(values_base), result)};
            }
            ir.Barrier();
            inst->ReplaceUsesWithAndRemove(result);
        } else if (inst->GetOpcode() == IR::Opcode::MaskedBitCount32) {
            const IR::U32 subgroup_invocation_id = ir.BitwiseAnd(invocation_index, ir.Imm32(63));
            const IR::U64 mask = ir.ISub(
                ir.ShiftLeftLogical(ir.Imm64(u64{1}), subgroup_invocation_id), ir.Imm64(u64{1}));
            const IR::U32 thread_mask{
                ir.CompositeExtract(ir.UnpackUint2x32(mask), inst->Arg(2).U1() ? 1u : 0u)};
            const IR::U32 masked_value{
                ir.BitCount(ir.BitwiseAnd(IR::U32{inst->Arg(0)}, thread_mask))};
            inst->ReplaceUsesWithAndRemove(ir.IAdd(masked_value, IR::U32{inst->Arg(1)}));
        }
    }
}

} // namespace Shader::Optimization
