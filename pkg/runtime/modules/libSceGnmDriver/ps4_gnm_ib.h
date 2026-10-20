// PM4 INDIRECT_BUFFER nesting for the command processor walkers in ps4_gnm_metal.mm.
#pragma once
#include <stdint.h>
#include <vector>

namespace ps4gnm_ib {

// A command buffer being walked: its words, size in dwords and the next packet.
struct Frame {
    const uint32_t *words;
    uint32_t dw;
    uint32_t pc;
};

// Limit for IB packets that call a sub-buffer and return (IB1 -> IB2 on GCN). It only guards
// against cycles: frames on the stack, the top-level buffer included, are at most
// kMaxDepth + 1.
constexpr int kMaxDepth = 4;

// The CHAIN bit of an INDIRECT_BUFFER packet (dw2 bit 20; field layout as in shadPS4
// src/video_core/amdgpu/pm4_cmds.h PM4CmdIndirectBuffer). A chained IB does not nest: the CP
// continues in the new buffer and never returns to the one holding the packet. Gnm builds
// large command buffers from chunks chained this way (Uncharted 4 chains dozens per frame).
inline bool IsChained(const uint32_t *payload, uint32_t payload_dw) {
    return payload_dw >= 3 && ((payload[2] >> 20) & 1u) != 0;
}

// Enters the IB [ib, ib + ib_dw) after the top frame has consumed the packet: a chained IB
// replaces the top frame, a call pushes a new frame unless the nesting limit is reached.
// Returns false when the call is skipped.
inline bool Enter(std::vector<Frame> &frames, const uint32_t *ib, uint32_t ib_dw, bool chain) {
    if (chain && !frames.empty()) {
        frames.back() = {ib, ib_dw, 0};
        return true;
    }
    if (frames.size() >= (size_t)kMaxDepth + 1) return false;
    frames.push_back({ib, ib_dw, 0});
    return true;
}

} // namespace ps4gnm_ib
