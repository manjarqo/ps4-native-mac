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
#include <utility>
#include <vector>

#include "ps4_gnm_capture.h"

namespace ps4replay {

struct Options {
    std::string frame_dir; // <PS4_GNM_CAPTURE_DIR>/frame_<n>
    uint32_t pass = 0;     // PassRec::index
    std::string out_dir;   // "" or a directory for the replayed outputs (.raw, .png, .bin)
    bool keep_outputs = false; // fill OutputResult::bytes (tests asserting output properties)
    bool sha256 = false;       // fill OutputResult::sha256 (range replays compare hashes, not files)
    // Called right before the pass's ps4draw::Draw / Dispatch (begin) and right after its
    // ps4draw::Flush(true) (end): what a caller measures around the renderer only (--allocs).
    void (*around_render)(void* ctx, bool begin) = nullptr;
    void* around_ctx = nullptr;
    // Settled replay (gnm_replay --settle), a diagnostic: every pass is replayed twice in a row,
    // its inputs (guest memory, seeded textures, fast clears) restored before each replay, and the
    // second replay is the one judged and reported (MATCH / DIFF, hashes, --out files,
    // around_render). An output whose two replays differ is marked unstable_first, with both
    // hashes. It classifies a difference a plain replay found (a first-execution effect, as in
    // docs/gnm-capture.md, "A first-execution effect", or not); it is NOT a gate for ordering
    // changes: the second replay runs on the renderer state the first one left (cache entries,
    // uploads already done, residency), and with every Metal 4 barrier removed settled sweeps came
    // out clean where plain ones did not (docs/gnm-capture.md). A pass writing a texture it creates
    // is not settled (Result::not_settled). Hashes are computed for both replays whatever sha256
    // says.
    bool settle = false;
    // Test-only (host tests; the command line never sets it): with settle, called for every output
    // of the first replay before it is hashed and compared, with its name and a copy of its bytes,
    // both of which the hook may change. It is how a test makes the first replay differ
    // deterministically.
    void (*test_settle_first)(void* ctx, std::string* what, std::vector<uint8_t>* bytes) = nullptr;
    void* test_settle_ctx = nullptr;
};

struct OutputResult {
    std::string what;        // texture role ("t2_color0") or "buffer 0x<addr>"
    bool compared = false;   // the capture holds this output after the pass
    uint64_t size = 0;       // bytes compared
    uint64_t replayed_size = 0; // bytes the replay produced
    uint64_t diff_bytes = 0; // bytes that differ from the capture
    uint64_t first_diff = 0; // offset of the first differing byte (when diff_bytes > 0)
    bool match = false;
    bool is_texture = false;
    ps4gnm_capture::GpuTextureId tex; // is_texture: the texture (bytes in the RawSize layout)
    uint64_t addr = 0;                // buffer: guest address
    std::vector<uint8_t> bytes;       // the replayed output (Options::keep_outputs)
    std::string sha256;               // SHA-256 of the replayed bytes, lowercase hex (Options::sha256)
    // Options::settle: the first replay's SHA-256 of this output ("ABSENT": the first replay did
    // not write it), and whether it differs from the second (sha256)
    std::string first_sha256;
    bool unstable_first = false;
};

struct Result {
    bool ran = false;      // the pass was replayed (outputs below are valid)
    std::string error;     // why it could not be replayed
    std::vector<std::string> notes;
    std::vector<OutputResult> outputs;
    // Options::settle: the outputs are the second replay's; unstable_first is set when any output
    // differs between the two replays, or the first wrote an output the second did not
    // (first_only: its name and first hash)
    bool settled = false;
    bool unstable_first = false;
    std::vector<std::pair<std::string, std::string>> first_only;
    // Options::settle on a pass that writes a texture it creates: replayed once, why it was not
    // settled ("" otherwise)
    std::string not_settled;
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

// The settle comparison (ReplayPass with Options::settle), exposed for tests: marks settled's
// outputs against first's by name and SHA-256 (first_sha256, unstable_first; "ABSENT" when first
// lacks the output), lists first's outputs settled lacks in first_only, and sets settled->settled.
void MarkUnstableFirst(const Result& first, Result* settled);

struct PassResult {
    uint32_t pass = 0;
    std::string type; // "draw", "dispatch" ("" for a pass the frame does not have)
    Result r;
};

// Replays passes first..last of one frame in order, in this process, each as ReplayPass does
// (its inputs reloaded; the renderer's caches carry over from pass to pass, the same way in every
// run). last = UINT32_MAX: to the frame's last pass. The first pass past the frame's end is
// reported as not replayed and ends the range. base.pass is ignored. The frame's manifest is
// parsed once. With base.out_dir set, pass <n>
// writes its outputs to <out_dir>/pass_<n>/ (the names inside are per output, not per pass).
std::vector<PassResult> ReplayPasses(const Options& base, uint32_t first, uint32_t last);

// Parses the pass argument of the command line: "<n>" (*range false), "<a>-<b>" with a <= b or
// "all" (*range true, "all" = 0..UINT32_MAX). Anything else (empty parts, junk, a > b) is refused.
bool ParsePassSpec(const std::string& s, uint32_t* first, uint32_t* last, bool* range);

// The lines gnm_replay prints for one pass of a range replay, each ending in '\n':
//   P <pass> <type|-> RAN <0|1 all outputs match the capture> <outputs>
//   O <pass> <what, spaces as '_'> <replayed bytes> <sha256|MISSING|->
//   P <pass> <type|-> NOT <reason>
// With Options::settle, an unstable pass (Result::unstable_first) has, after its O lines, one line
// per output whose two replays differ (the O line carries the settled hash):
//   U <pass> UNSTABLE-FIRST <what> <first sha256|ABSENT> <settled sha256|ABSENT>
// and a pass replayed once instead (Result::not_settled) ends with
//   S <pass> NOT-SETTLED <reason>
// An output the renderer made no texture for has hash MISSING (never a hash another run could
// share by also failing); "-" is a hash not asked for (Options::sha256 unset).
std::string FormatPassResult(const PassResult& p);

} // namespace ps4replay
