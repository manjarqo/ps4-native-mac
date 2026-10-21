// SPDX-License-Identifier: GPL-2.0-or-later
// PS4Recomp - replay of one captured pass (PS4_GNM_CAPTURE_FRAME, ps4_gnm_capture.h) through the
// renderer itself: ps4draw::Init / Draw / Dispatch / Flush of ps4_gnm_draw.mm, the same
// gcn-recompiler translation, BindStage binding and DrawEncode / DispatchEncode encoding as the
// game, on a guest memory filled from the pass's snapshots and GPU-owned textures created with
// the captured identities and contents. Only the seeding (ps4draw::Replay* in ps4_gnm_draw.h) is
// replay-specific.
#pragma once

#include <stdint.h>

#include <string>
#include <vector>

#include "ps4_gnm_capture.h"

namespace ps4replay {

struct Options {
    std::string frame_dir; // <PS4_GNM_CAPTURE_DIR>/frame_<n>
    uint32_t pass = 0;     // PassRec::index
    std::string out_dir;   // "" or a directory for the replayed outputs (.raw, .png, .bin)
    bool keep_outputs = false; // fill OutputResult::bytes (tests asserting output properties)
};

struct OutputResult {
    std::string what;        // texture role ("t2_color0") or "buffer 0x<addr>"
    bool compared = false;   // the capture holds this output after the pass
    uint64_t size = 0;       // bytes compared
    uint64_t diff_bytes = 0; // bytes that differ from the capture
    uint64_t first_diff = 0; // offset of the first differing byte (when diff_bytes > 0)
    bool match = false;
    bool is_texture = false;
    ps4gnm_capture::GpuTextureId tex; // is_texture: the texture (bytes in the RawSize layout)
    uint64_t addr = 0;                // buffer: guest address
    std::vector<uint8_t> bytes;       // the replayed output (Options::keep_outputs)
};

struct Result {
    bool ran = false;      // the pass was replayed (outputs below are valid)
    std::string error;     // why it could not be replayed
    std::vector<std::string> notes;
    std::vector<OutputResult> outputs;
    bool AllMatch() const {
        if (!ran || outputs.empty()) return false;
        for (const OutputResult& o : outputs)
            if (!o.compared || !o.match) return false;
        return true;
    }
};

// Replays one pass and compares every output it wrote with the capture, byte for byte. The
// renderer starts cold: no shader, pipeline or texture-cache state from the game, only what the
// pass's capture seeds (guest memory, the GPU-owned textures it uses, pending fast clears). A
// game bug that depends on stale cached state (a texture not re-uploaded, a translation reused
// for changed code) is therefore not reproduced by a replay. May be called several times in one
// process: each call reloads its pass's inputs (reported to the renderer as CPU writes), while
// the renderer's caches keep what earlier calls built. All calls must use frames with the same
// mem_size and neo mode.
Result ReplayPass(const Options& o);

} // namespace ps4replay
