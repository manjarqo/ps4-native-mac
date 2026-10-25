# Metal 4 Renderer Backend Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** One `.app` carries a Metal 3 and a Metal 4 renderer backend, chosen at launch with `PS4_GNM_METAL=3|4`, and The Last of Us Remastered (CUSA00557) runs on Metal 4 at parity with Metal 3 (same picture, no crash, no GPU hang, fps not lower).

**Architecture:** A `GnmBackend` interface (`ps4_gnm_backend.h`) sits at the encoder thread. The shared renderer (`ps4_gnm_draw.mm`: command processor side, caches, `BindStage`, hazard logic, the guest-memory protocol, the seq timeline, pipelines) decides what to encode; `Metal3Backend` (a move of today's code) or `Metal4Backend` (`MTL4CommandQueue`, allocator ring, timeline event, argument tables, bytes arena, encoder-start barriers, residency sets) executes it. Helper passes are rewritten once on `BeginRender`/`Draw` (`ps4_gnm_util_passes.mm`). Per-bind calls go through a function table, everything else is a virtual call made once per pass, copy or commit.

**Tech Stack:** Objective-C++ (C++17, ARC), Metal 3 and Metal 4 (macOS SDK 27.0, `MTL4*` APIs need macOS 26), CommonCrypto (SHA-256 of replay outputs), C (allocation counter, interposed with `DYLD_INSERT_LIBRARIES`), bash (host tests, run scripts), Python 3 standard library (report and compare tools), Go (generator, unchanged).

**Spec:** `docs/superpowers/specs/2026-10-22-metal4-backend-design.md` (the authority; read it with this plan). Research behind it: a note in the local SDD workspace (git-ignored, not in the repository: Metal 3 usage map, mapping table, interface sketch, risks); what the code relies on is in docs/metal4-backend.md and docs/gnm-ordering.md.

## Global Constraints

Copied verbatim from the spec's "Global constraints":

- AGENTS.md:
  - no cheating and no fake tests: each new test fails on the code before its change;
  - no stubs that return 0 and no temporary workarounds;
  - no interpreter and no JIT;
  - comments and docs in English;
  - Go analysis tools clean, with minimal allocations.
- TLOU does not regress on Metal 3 at any phase.
- gcn-recompiler is edited only through its in-repo copy.
- Local commits only. Pushing happens only on the owner's word.

From the spec's "Phases and acceptance" (they bind every run in this plan):

- time-bounded, at 300 s or less;
- scratch `PS4RECOMP_DATA_DIR` and cache dirs;
- through `heavy_lock`, exclusive for perf runs.
- On Metal 4-family hardware a test never passes by skipping: a missing feature fails it.

Project rules that apply to every task (owner's standing instructions):

- One game at a time; track your own game by PID and kill only your own process; the owner-game check is `pgrep -x eboot` (if it prints a PID, do not start a game run; wait or ask).
- Never touch `~/ps4recomp-work/tlou_build/eboot.app`, `~/ps4recomp-work/u4_build/eboot.app`, the owner's saves or shader caches. Builds go to the directories named below.
- `mount | grep ps4recomp-work` before builds and runs (the workdir is an APFS image on the SSD).
- Never `rm`/`ln` after a `cd` that could fail (`cd X || exit 1`, absolute paths).
- `git status` errors on the 3rdparty symlinks: use `git status --short -- pkg cmd tests tools docs .gitignore`.
- Builds use at most 6 jobs. Every game run and every full build goes through `~/ps4recomp-work/tools/heavy_lock.sh <cmd>`, one command per lock.
- Commit trailer on every commit: `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.

---

## Names used by every task

| what | value |
|---|---|
| worktree (branch `metal4-backend`) | `~/ps4recomp-work/PS4Recomp-metal4` |
| renderer sources | `pkg/runtime/modules/libSceGnmDriver/` (written `$G` in commands) |
| TLOU game directory | `TLOU_DIR="<your-TLOU-dump>"`: the directory that holds `eboot.bin` (the "TLOU eboot / app dir" row of `docs/superpowers/plans/2026-10-21-u4-graphics.md`). Set it once per shell: `export TLOU_DIR='<your-TLOU-dump>'`. Every build command below reads it. |
| U4 game directory (smoke runs only) | `U4_DIR="<your-U4-dump>"`: the "U4 eboot / app dir" row of the same plan; `export U4_DIR='<your-U4-dump>'` |
| research root (outside the repo) | `~/ps4recomp-work/metal4_research` (written `$M` in commands; `export M=$HOME/ps4recomp-work/metal4_research`) |
| game builds | `$M/tlou_build_<tag>` (`p0`, `p1`, … one per phase gate), `$M/u4_build_<tag>` |
| replay tool builds | `$M/replay_<tag>` |
| captures (the TLOU capture set) | `$M/captures/courtyard/frame_<n>`, `$M/captures/spores/frame_<n>` (Task 0.4) |
| replay hash lists | `$M/replay/<tag>_m<3|4>_<courtyard|spores>.txt` |
| runs and logs | `$M/runs/<tag>.{log,mon}`, screenshots `$M/runs/shots_<tag>/` |
| save fixtures (copied, never used directly) | `~/ps4recomp-work/data_ch1` (courtyard), `~/ps4recomp-work/data_user1441` (spores) |
| walk script | `~/ps4recomp-work/walk_script.txt` |

## Commands used by every task

**Host suite** (renderer-level tests run on each backend the phase supports; the loop is extended in Tasks 2.6, 3.4, 4.4 and 6.1):

```bash
mount | grep ps4recomp-work
cd ~/ps4recomp-work/PS4Recomp-metal4 || exit 1
mkdir -p $M
~/ps4recomp-work/tools/heavy_lock.sh tests/host/run_host_tests.sh > $M/host_<tag>.log 2>&1; echo host=$?
tail -5 $M/host_<tag>.log
```
Expected: `host=0`; the last lines are the capture-tools `PASS` line.

**Replay tool build:**

```bash
cd ~/ps4recomp-work/PS4Recomp-metal4 || exit 1
~/ps4recomp-work/tools/heavy_lock.sh tools/gnm_replay/build.sh $M/replay_<tag> tools/gnm_replay/gnm_replay.mm \
  > $M/replay_<tag>.build.log 2>&1; echo build=$?
```
Expected: `build=0`, `$M/replay_<tag>/gnm_replay` exists.

**Replay byte-identity check** (the parity instrument; "R-check <tag> <3|4>" in the tasks). It replays every pass of both captured frames in one process per frame and writes one SHA-256 per output (Task 0.1), then compares with the Phase 0 lists (Task 0.2):

```bash
cd ~/ps4recomp-work/PS4Recomp-metal4 || exit 1
mkdir -p $M/replay
for F in courtyard spores; do
  FR=$(ls -d $M/captures/$F/frame_* | head -1)
  ~/ps4recomp-work/tools/heavy_lock.sh env PS4_GNM_METAL=<3|4> $M/replay_<tag>/gnm_replay "$FR" all --sha \
    > $M/replay/<tag>_m<3|4>_$F.txt 2> $M/replay/<tag>_m<3|4>_$F.err; echo "$F replay=$?"
  python3 tools/metal4_replay_cmp.py $M/replay/p0_m3_$F.txt $M/replay/<tag>_m<3|4>_$F.txt; echo "$F cmp=$?"
done
```
Expected: `cmp=0` for both frames and the line `same: <N> passes, <K> outputs; different: 0; missing: 0`. Before Task 2.2 exists, `PS4_GNM_METAL=<3|4>` is always `3` (the Phase 0 tool ignores the variable). A pure-move task passes when the R-check with `3` gives `cmp=0` and the host suite is unchanged.

**TLOU game build** (a fresh directory per tag; the generator walks `pkg/runtime` and compiles every `.c/.m/.mm/.cpp`, so new renderer files need no build-file edit):

```bash
mount | grep ps4recomp-work
cd ~/ps4recomp-work/PS4Recomp-metal4 || exit 1
go build -o ps4-recomp ./cmd/ps4-recomp
~/ps4recomp-work/tools/heavy_lock.sh ./ps4-recomp "$TLOU_DIR/eboot.bin" --app-dir "$TLOU_DIR" -o $M/tlou_build_<tag> -c -j 6 \
  > $M/gen_tlou_<tag>.log 2>&1; echo gen=$?
tail -2 $M/gen_tlou_<tag>.log; ls -la $M/tlou_build_<tag>/ps4_app
```
Expected: `gen=0`, the log ends with "All tasks completed successfully", `ps4_app` exists.

**TLOU route run** (Task 0.4 writes `tools/metal4_route.sh`: courtyard walk from a copy of `data_ch1`, ≤ 300 s, scratch data and cache dirs, kill by PID on every exit path, WindowServer / load / GPU-error monitor):

```bash
cd ~/ps4recomp-work/PS4Recomp-metal4 || exit 1
~/ps4recomp-work/tools/heavy_lock.sh env BUILD=$M/tlou_build_<tag> TAG=<run> METAL=<3|4> SECS=300 tools/metal4_route.sh
python3 tools/metal4_route_report.py $M/runs/<run>.log
```
For an fps measurement prefix `HEAVY_EXCLUSIVE=1` to `heavy_lock.sh`. The report prints one line `fps <mean> enc_ms <x> cp_ms <y> commits <z> split <s> skipped <n> fatal <f> gpu_err <g> watchdog <w> flips <p> load <l>`.

**Perf A/B** (Task 0.4 writes `tools/metal4_perf_ab.sh`): alternating runs A, B, A, B, …, each under `HEAVY_EXCLUSIVE=1 heavy_lock`, a run whose 1-minute load at its end exceeds 15 (or whose monitor shows other processes above 150 % CPU in more than one sample) is discarded and repeated, until `N` runs per side are kept; prints the median fps, encoder ms and CP ms per side.

```bash
cd ~/ps4recomp-work/PS4Recomp-metal4 || exit 1
N=5 A=$M/tlou_build_<a>:3 B=$M/tlou_build_<b>:<3|4> TAG=<name> tools/metal4_perf_ab.sh | tee $M/ab_<name>.txt
```

"Within noise" (Phase 1): `|median_B - median_A| <= max(1.0, max_A - min_A)` fps over the kept A runs.

**Go analysis** (no Go file changes in this plan; run at every gate):

```bash
cd ~/ps4recomp-work/PS4Recomp-metal4 || exit 1
go vet ./... && test -z "$(gofmt -l cmd pkg)" && go test ./pkg/... 2>&1 | tail -3; echo go=$?
```
Expected: `go=0`.

---

## File structure

| file | responsibility | task |
|---|---|---|
| `$G/ps4_gnm_backend.h` | `GnmBackend` interface and every supporting type, `GnmComputeSink`, `ChooseBackend` | 1.1 |
| `$G/ps4_gnm_backend.mm` | `ChooseBackend`, `BackendName` (no Metal calls) | 1.1 |
| `$G/ps4_gnm_backend_metal3.h` / `.mm` | `Metal3Backend`: today's Metal 3 calls, moved | 1.2 |
| `$G/ps4_gnm_util_passes.h` / `.mm` | the utility MSL (present, depth copies, EQAA copies, detile) and `FullscreenPass` on `BeginRender`/`Draw` | 1.9 |
| `$G/ps4_gnm_residency.h` / `.mm` | `GnmResidency`: residency sets, deferred removal by seq, `Contains` for the bind-time check | 2.1, 5.2 |
| `$G/ps4_gnm_backend_metal4.h` / `.mm` | `Metal4Backend`, the bind-time residency check | 2.2–4.1, 5.1 |
| `$G/ps4_gnm_draw.mm` / `.h` | shared renderer; calls `S.be->…` | 1.2–1.9, 2.x–5.x |
| `$G/ps4_gnm_rectlist.h` | `ps4gnm_rect::Encode(GnmBackend&, …)` | 1.5 |
| `$G/ps4_gnm_resources.h` / `.mm` | `TextureCache::NewTextureLocked`, `DropEntryLocked`, residency hooks, GPU-copy hook | 2.4, 4.2 |
| `pkg/runtime/modules/libSceVideoOut/ps4_metal_screen.h` / `.m` | present producer split (`ps4_metal_screen_present_begin` / `_held_begin`), texture hooks | 1.8, 2.4 |
| `tools/gnm_replay/{gnm_replay.h,gnm_replay_lib.mm,gnm_replay.mm,build.sh,replay_links.c}` | range replay with SHA-256 per output, allocation counting hook, backend sources | 0.1, 0.3, 1.1+ |
| `tools/gnm_replay/alloc_count.c` | malloc-family interposer counting calls on one thread | 0.3 |
| `tools/metal4_replay_cmp.py`, `tools/metal4_route_report.py`, `tools/metal4_route.sh`, `tools/metal4_perf_ab.sh` | measurement tools | 0.2, 0.4 |
| `tools/tests/test_metal4_replay_cmp.py`, `tools/tests/test_metal4_route_report.py` | their unit tests | 0.2 |
| `tools/metal4_shot_diff.py`, `tools/tests/test_metal4_shot_diff.py` | per-pixel screenshot comparison and its test | 4.4 |
| `.gitignore` | un-ignore the new files under `tools/` | 0.2, 0.4 |
| `tests/host/backend_harness.h` | test helper: the backend `PS4_GNM_METAL` selects; `RequireMetal4` | 2.2 |
| `tests/host/gnm_backend_select_test.mm` | `ChooseBackend` | 1.1 |
| `tests/host/alloc_count_test.c` | the interposer counts and fails without it | 0.3 |
| `tests/host/gnm_residency_test.mm` | residency set logic (2.1), GPU positive and negative control (3.1), views (4.2), bind check (5.1) | 2.1+ |
| `tests/host/gnm_backend_cmd_test.mm` | allocator reuse after completion, command-buffer split for events | 2.2 |
| `tests/host/gnm_backend_present_test.mm` | clear → present conversion → slot copy → event, equal on both backends | 2.3 |
| `tests/host/gnm_backend_copy_test.mm` | every copy and fill op on both backends | 3.2 |
| `tests/host/gnm_backend_barrier_test.mm` | render pass sampling a compute-written texture equals Metal 3 | 4.1 |
| `tests/host/gnm_guest_memory_test.mm` (mode `remap`) | guest windows remapped and swept between dispatches, residency balance | 5.2 |
| `tests/host/run_host_tests.sh` | wiring; renderer-level tests on both backends | every task with a test |
| `docs/metal4-backend.md` | backends, selection, debug variables, residency rules, measurements | 1.1, then every phase |
| `docs/metal4-baseline.md` | Phase 0 numbers, then each gate's numbers | 0.4, gates |

---

## Phase 0: Baseline

Phase 0 builds the measurement instruments and records Metal 3 numbers on the code as it is (a053d62). No renderer change.

### Task 0.1: Range replay with SHA-256 per output

**Files:**
- Modify: `tools/gnm_replay/gnm_replay.h:19-24` (Options), `:26-40` (OutputResult), `:61` (new declarations)
- Modify: `tools/gnm_replay/gnm_replay_lib.mm:143-171` (AddOutput), `:175-308` (ReplayPass split into ReplayLoaded)
- Modify: `tools/gnm_replay/gnm_replay.mm:15-50` (argument parsing, range mode)
- Test: `tests/host/gnm_replay_test.mm` (new case `TestRange`)

**Interfaces:**
- Consumes: `ps4gnm_capture::LoadFrame`, `FrameRec`, `PassRec`, the existing `ReplayPass` body.
- Produces:
  - `struct Options { …; bool sha256 = false; void (*around_render)(void* ctx, bool begin) = nullptr; void* around_ctx = nullptr; };`
  - `OutputResult::sha256` (`std::string`, 64 lowercase hex digits; filled when `Options::sha256`).
  - `struct PassResult { uint32_t pass = 0; std::string type; Result r; };`
  - `std::vector<PassResult> ReplayPasses(const Options& base, uint32_t first, uint32_t last);` (`last` = `UINT32_MAX`: to the frame's last pass; `base.pass` is ignored)
  - `gnm_replay <frame_dir> <a>-<b>|all --sha` prints, per pass in order, `P <pass> <type> RAN <0|1 all outputs match the capture> <outputs>` followed by one `O <pass> <what> <size> <sha256>` line per output (`what` with spaces replaced by `_`), or `P <pass> <type> NOT <reason>`; exit 0.

- [ ] **Step 1: Write the failing test**

Append to `tests/host/gnm_replay_test.mm`, before `int main`, and call `TestRange(root)` from `main` after the existing cases (the test already has `WriteCapture(root, corrupt_at)` writing `<root>/frame_1` with one replayable dispatch whose output is 64 dwords `out[i] = i` at `kOut`):

```objc
// ReplayPasses: every pass of the frame in one call, with one SHA-256 per output; the hash is
// that of the replayed bytes (out[i] = i), and a range past the frame's end reports the pass.
void TestRange(const std::string& root) {
    const std::string frame = WriteCapture(root + "/range", -1);
    ps4replay::Options o;
    o.frame_dir = frame;
    o.sha256 = true;
    const std::vector<ps4replay::PassResult> all = ps4replay::ReplayPasses(o, 0, UINT32_MAX);
    CHECK(all.size() == 1, "range: %zu passes, want 1", all.size());
    if (all.size() != 1) return;
    CHECK(all[0].pass == 0 && all[0].type == "dispatch", "range: pass %u type %s", all[0].pass, all[0].type.c_str());
    CHECK(all[0].r.ran && all[0].r.outputs.size() == 1, "range: not replayed: %s", all[0].r.error.c_str());
    if (!all[0].r.ran || all[0].r.outputs.size() != 1) return;
    uint32_t want[64];
    for (uint32_t i = 0; i < 64; ++i) want[i] = i;
    unsigned char md[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(want, sizeof(want), md);
    char hex[2 * CC_SHA256_DIGEST_LENGTH + 1];
    for (int i = 0; i < CC_SHA256_DIGEST_LENGTH; ++i) snprintf(hex + 2 * i, 3, "%02x", md[i]);
    CHECK(all[0].r.outputs[0].sha256 == hex, "range: sha %s, want %s", all[0].r.outputs[0].sha256.c_str(), hex);
    const std::vector<ps4replay::PassResult> past = ps4replay::ReplayPasses(o, 0, 1);
    CHECK(past.size() == 2 && !past[1].r.ran && past[1].r.error.find("no pass 1") != std::string::npos,
          "range: pass 1 of a 1-pass frame not reported");
}
```

Add `#include <CommonCrypto/CommonDigest.h>` to its includes.

- [ ] **Step 2: Run it to verify it fails**

```bash
cd ~/ps4recomp-work/PS4Recomp-metal4 || exit 1
T=$(mktemp -d); tools/gnm_replay/build.sh $T tests/host/gnm_replay_test.mm 2>&1 | grep -m3 error
```
Expected: compile errors `no member named 'sha256' in 'ps4replay::Options'` and `no member named 'ReplayPasses'`.

- [ ] **Step 3: Implement**

`gnm_replay.h`: add to `Options` after `keep_outputs`:

```cpp
    bool sha256 = false;       // fill OutputResult::sha256 (range replays compare hashes, not files)
    // Called right before the pass's ps4draw::Draw / Dispatch (begin) and right after its
    // ps4draw::Flush(true) (end): what a caller measures around the renderer only (--allocs).
    void (*around_render)(void* ctx, bool begin) = nullptr;
    void* around_ctx = nullptr;
```

to `OutputResult` after `bytes`:

```cpp
    std::string sha256;               // SHA-256 of the replayed bytes, lowercase hex (Options::sha256)
```

and after `Result ReplayPass(const Options& o);`:

```cpp
struct PassResult {
    uint32_t pass = 0;
    std::string type; // "draw", "dispatch" ("" for a pass the frame does not have)
    Result r;
};

// Replays passes first..last of one frame in order, in this process, each as ReplayPass does
// (its inputs reloaded; the renderer's caches carry over from pass to pass, the same way in every
// run). last = UINT32_MAX: to the frame's last pass. A pass past the frame's end is reported as
// not replayed. base.pass is ignored. The frame's manifest is parsed once.
std::vector<PassResult> ReplayPasses(const Options& base, uint32_t first, uint32_t last);
```

`gnm_replay_lib.mm`: add `#include <CommonCrypto/CommonDigest.h>`. In `AddOutput`, before `if (opt.keep_outputs)`:

```cpp
    if (opt.sha256) {
        unsigned char md[CC_SHA256_DIGEST_LENGTH];
        CC_SHA256(got, (CC_LONG)got_n, md);
        char hex[2 * CC_SHA256_DIGEST_LENGTH + 1];
        for (int i = 0; i < CC_SHA256_DIGEST_LENGTH; ++i) snprintf(hex + 2 * i, 3, "%02x", md[i]);
        o.sha256 = hex;
    }
```

Split `ReplayPass` (`:175`): rename its body after `LoadFrame` to `Result ReplayLoaded(const Options& o, const FrameRec& f)` (inside the anonymous namespace, everything from `if (o.pass >= f.passes.size() …` to the end), and wrap the two renderer calls with the hook:

```cpp
    if (o.around_render) o.around_render(o.around_ctx, true);
    if (p.type == "draw") {
        …unchanged…
    }
    ps4draw::Flush(true);
    if (o.around_render) o.around_render(o.around_ctx, false);
```

(the early `return r.error = "Draw refused …"` inside the draw branch calls `o.around_render(o.around_ctx, false)` first when set). Then:

```cpp
Result ReplayPass(const Options& o) {
    Result r;
    FrameRec f;
    std::string err;
    if (!LoadFrame(o.frame_dir, &f, &err)) return r.error = err, r;
    return ReplayLoaded(o, f);
}

std::vector<PassResult> ReplayPasses(const Options& base, uint32_t first, uint32_t last) {
    std::vector<PassResult> out;
    FrameRec f;
    std::string err;
    if (!LoadFrame(base.frame_dir, &f, &err)) {
        PassResult p;
        p.pass = first;
        p.r.error = err;
        out.push_back(std::move(p));
        return out;
    }
    if (last == UINT32_MAX) last = f.passes.empty() ? 0 : (uint32_t)f.passes.size() - 1;
    for (uint32_t i = first; i <= last; ++i) {
        Options o = base;
        o.pass = i;
        PassResult p;
        p.pass = i;
        if (i < f.passes.size()) p.type = f.passes[i].type;
        p.r = ReplayLoaded(o, f);
        out.push_back(std::move(p));
    }
    return out;
}
```

`gnm_replay.mm`: after `o.frame_dir = argv[1];` parse the pass argument and the flags; keep the single-pass branch as it is, add the range branch:

```objc
        bool sha = false;
        for (int i = 3; i < argc; ++i) {
            if (!strcmp(argv[i], "--sha")) sha = true;
            else if (!strcmp(argv[i], "--out") && i + 1 < argc) o.out_dir = argv[++i];
        }
        uint32_t first = 0, last = 0;
        const bool range = !strcmp(argv[2], "all") || strchr(argv[2], '-');
        if (range) {
            if (strcmp(argv[2], "all")) {
                first = (uint32_t)strtoul(argv[2], nullptr, 10);
                last = (uint32_t)strtoul(strchr(argv[2], '-') + 1, nullptr, 10);
            } else {
                last = UINT32_MAX;
            }
            o.sha256 = sha;
            for (const ps4replay::PassResult& p : ps4replay::ReplayPasses(o, first, last)) {
                if (!p.r.ran) {
                    printf("P %u %s NOT %s\n", p.pass, p.type.empty() ? "-" : p.type.c_str(), p.r.error.c_str());
                    continue;
                }
                printf("P %u %s RAN %d %zu\n", p.pass, p.type.c_str(), p.r.AllMatch() ? 1 : 0, p.r.outputs.size());
                for (const ps4replay::OutputResult& out : p.r.outputs) {
                    std::string w = out.what;
                    for (char& c : w)
                        if (c == ' ') c = '_';
                    printf("O %u %s %zu %s\n", p.pass, w.c_str(), out.is_texture ? out.size : (size_t)out.size,
                           out.sha256.empty() ? "-" : out.sha256.c_str());
                }
            }
            return 0;
        }
        o.pass = (uint32_t)strtoul(argv[2], nullptr, 10);
```

The `O` line prints the size the replay produced, which exists also for outputs the capture does not hold: add `uint64_t replayed_size = 0; // bytes the replay produced` next to `size` in `OutputResult` (`gnm_replay.h`), set it in `AddOutput` (`o.replayed_size = got_n;`), and pass `(unsigned long long)out.replayed_size` with `%llu` as the `O` line's size argument. Update the usage text to `gnm_replay <frame_dir> <pass>|<a>-<b>|all [--out <dir>] [--sha]`.

- [ ] **Step 4: Run it to verify it passes**

```bash
cd ~/ps4recomp-work/PS4Recomp-metal4 || exit 1
T=$(mktemp -d); tools/gnm_replay/build.sh $T tests/host/gnm_replay_test.mm > $T/b.txt 2>&1 || cat $T/b.txt
$T/gnm_replay_test 2>&1 | grep -v "^\[gnm-\|^\[gcn \|^\[gpumem\]" | tail -3
```
Expected: `gnm_replay_test: PASS`.

- [ ] **Step 5: Host suite and commit**

Run the host suite (tag `t01`). Expected `host=0`.

```bash
git add tools/gnm_replay/gnm_replay.h tools/gnm_replay/gnm_replay_lib.mm tools/gnm_replay/gnm_replay.mm tests/host/gnm_replay_test.mm
git commit -m "gnm_replay: replay a pass range in one process with a SHA-256 per output

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

### Task 0.2: Replay-hash compare and route report tools

**Files:**
- Create: `tools/metal4_replay_cmp.py`, `tools/tests/test_metal4_replay_cmp.py`
- Create: `tools/metal4_route_report.py`, `tools/tests/test_metal4_route_report.py`
- Modify: `.gitignore:5` (after `!/tools/refcompare.py`)

**Interfaces:**
- Consumes: the `P`/`O` line format of Task 0.1; the renderer's log lines `[gnm-draw] perf: …`, `[gnm-draw] present #… totals: draws … skipped …`, `[gnm-draw] backend …` (from Task 2.6 on), `[gnm-mem] …`, `[gnm-residency] ASSERT` (Task 5.1), the `.mon` file of `metal4_route.sh` (Task 0.4).
- Produces:
  - `python3 tools/metal4_replay_cmp.py <base.txt> <new.txt> [--type draw|dispatch]`: prints `same: <N> passes, <K> outputs; different: <D>; missing: <M>` and one `DIFF pass <n> <what>` / `MISSING pass <n> (<state in base> -> <state in new>)` line per problem; exit 0 iff D = M = 0. Passes replayed in base must be replayed in new with the same output names and hashes; passes `NOT` in base are ignored (they are not part of the pass set).
  - `python3 tools/metal4_route_report.py <run.log> [--skip 13]`: one line `fps <mean> enc_ms <x> cp_ms <y> commits <z> split <s> skipped <n> fatal <f> gpu_err <g> watchdog <w> flips <p> load <l> asserts <a>`; values from the perf lines after the first `skip` (boot and loading), `skipped` and `flips` from the last `present #` line, `split` from the `backend` lines (0 when absent), `load` from `<run>.mon` next to the log (its `stop` line), `asserts` = count of `[gnm-residency] ASSERT`.

- [ ] **Step 1: Write the failing tests**

`tools/tests/test_metal4_replay_cmp.py`:

```python
# Tests tools/metal4_replay_cmp.py on small hash lists.
import os
import subprocess
import sys
import tempfile
import unittest

TOOL = os.path.join(os.path.dirname(__file__), "..", "metal4_replay_cmp.py")

BASE = """P 0 dispatch RAN 1 1
O 0 buffer_0x200000 256 aa
P 1 draw RAN 0 2
O 1 t0_color0 1024 bb
O 1 t1_depth 512 cc
P 2 draw NOT the renderer encoded nothing for this pass: x
"""


def run(base, new, *args):
    with tempfile.TemporaryDirectory() as d:
        a, b = os.path.join(d, "a.txt"), os.path.join(d, "b.txt")
        open(a, "w").write(base)
        open(b, "w").write(new)
        p = subprocess.run([sys.executable, TOOL, a, b, *args], capture_output=True, text=True)
        return p.returncode, p.stdout


class ReplayCmpTest(unittest.TestCase):
    def test_same(self):
        rc, out = run(BASE, BASE)
        self.assertEqual(rc, 0)
        self.assertIn("same: 2 passes, 3 outputs; different: 0; missing: 0", out)

    def test_hash_differs(self):
        rc, out = run(BASE, BASE.replace(" cc", " cd"))
        self.assertEqual(rc, 1)
        self.assertIn("DIFF pass 1 t1_depth", out)

    def test_pass_not_replayed_any_more(self):
        rc, out = run(BASE, BASE.replace("P 0 dispatch RAN 1 1\nO 0 buffer_0x200000 256 aa\n",
                                         "P 0 dispatch NOT the renderer skipped the pass\n"))
        self.assertEqual(rc, 1)
        self.assertIn("MISSING pass 0 (RAN -> NOT)", out)

    def test_type_filter(self):
        rc, out = run(BASE, BASE.replace(" cc", " cd"), "--type", "dispatch")
        self.assertEqual(rc, 0)
        self.assertIn("same: 1 passes, 1 outputs", out)

    def test_extra_pass_in_new_is_ignored(self):
        rc, _ = run(BASE, BASE.replace("P 2 draw NOT the renderer encoded nothing for this pass: x\n",
                                       "P 2 draw RAN 1 0\n"))
        self.assertEqual(rc, 0)


if __name__ == "__main__":
    unittest.main()
```

`tools/tests/test_metal4_route_report.py`:

```python
# Tests tools/metal4_route_report.py on a fixed log and monitor file.
import os
import subprocess
import sys
import tempfile
import unittest

TOOL = os.path.join(os.path.dirname(__file__), "..", "metal4_route_report.py")

LOG = """[gnm-draw] perf: 10.0 fps over last 300 presents; per frame: 9.0 commits, 1.0 waits, 2.0 ms waiting, 3.0 ms GPU busy, 30.0 ms CP (CPU), 20.0 ms encoder, 0.1 ms screen
[gnm-draw] perf: 60.0 fps over last 300 presents; per frame: 3.0 commits, 0.0 waits, 0.0 ms waiting, 9.0 ms GPU busy, 5.0 ms CP (CPU), 4.0 ms encoder, 0.3 ms screen
[gnm-draw] backend metal4: split commits per frame 0.5; allocators 6 (384 KiB); resident 120 (900 MiB)
[gnm-draw] perf: 50.0 fps over last 300 presents; per frame: 4.0 commits, 0.0 waits, 0.0 ms waiting, 9.0 ms GPU busy, 7.0 ms CP (CPU), 6.0 ms encoder, 0.3 ms screen
[gnm-draw] backend metal4: split commits per frame 1.5; allocators 6 (384 KiB); resident 121 (901 MiB)
[gnm-draw] present #601 from GPU target 0x1000 (1920x1080 fmt 80); totals: draws 100 dispatches 7 skipped 3 shaders 5 pipelines 6 submit 9
[gnm-draw] GPU watchdog: command buffer gnm-5 did not complete in 4000 ms; disabling GPU rendering (fences keep being signaled)
[gnm-residency] ASSERT buffer 0x1234 bound for VS slot 3 is in no residency set
FATAL something
"""
MON = """r start 10:00:00 load { 3.0 2.0 1.0 } WindowServer rss 1 KB
t=5 ws_rss=1 ws_cpu=1 load=4.0 game_rss=1 gpu_err=0 game_cpu=1 other_cpu=10
r stop 10:05:00 (time limit) load { 12.5 11.0 9.0 } WindowServer rss 2 KB
"""


class RouteReportTest(unittest.TestCase):
    def test_report(self):
        with tempfile.TemporaryDirectory() as d:
            log = os.path.join(d, "r.log")
            open(log, "w").write(LOG)
            open(os.path.join(d, "r.mon"), "w").write(MON)
            p = subprocess.run([sys.executable, TOOL, log, "--skip", "1"], capture_output=True, text=True)
            self.assertEqual(p.returncode, 0, p.stderr)
            self.assertEqual(p.stdout.strip(),
                             "fps 55.0 enc_ms 5.0 cp_ms 6.0 commits 3.5 split 1.0 skipped 3 fatal 1 gpu_err 0 "
                             "watchdog 1 flips 601 load 12.5 asserts 1")

    def test_no_perf_lines(self):
        with tempfile.TemporaryDirectory() as d:
            log = os.path.join(d, "r.log")
            open(log, "w").write("nothing\n")
            p = subprocess.run([sys.executable, TOOL, log], capture_output=True, text=True)
            self.assertEqual(p.returncode, 1)
            self.assertIn("no perf lines", p.stdout)


if __name__ == "__main__":
    unittest.main()
```

- [ ] **Step 2: Run them to verify they fail**

Run: `cd ~/ps4recomp-work/PS4Recomp-metal4 && python3 -m unittest discover -s tools/tests -p 'test_metal4_*.py' 2>&1 | tail -3`
Expected: FAIL (`can't open file '…/metal4_replay_cmp.py'`).

- [ ] **Step 3: Implement**

`tools/metal4_replay_cmp.py`:

```python
#!/usr/bin/env python3
"""Compares two gnm_replay --sha hash lists (docs/metal4-backend.md, "Replay parity").

usage: metal4_replay_cmp.py <base.txt> <new.txt> [--type draw|dispatch]

Every pass the base list replayed (P ... RAN) must be replayed in the new list with the same
outputs (names, sizes and SHA-256). Passes the base list did not replay are not part of the pass
set and are ignored. Exit status 0: no difference; 1: a difference or a missing pass.
"""
import argparse
import sys


def load(path):
    passes = {}
    with open(path) as f:
        for line in f:
            w = line.split()
            if len(w) >= 4 and w[0] == "P":
                passes[int(w[1])] = {"type": w[2], "state": w[3], "outs": {}}
            elif len(w) == 5 and w[0] == "O":
                passes[int(w[1])]["outs"][w[2]] = (w[3], w[4])
    return passes


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("base")
    ap.add_argument("new")
    ap.add_argument("--type", choices=["draw", "dispatch"])
    a = ap.parse_args()
    base, new = load(a.base), load(a.new)
    same_p = same_o = diff = missing = 0
    for n in sorted(base):
        b = base[n]
        if b["state"] != "RAN" or (a.type and b["type"] != a.type):
            continue
        m = new.get(n)
        if not m or m["state"] != "RAN":
            print("MISSING pass %d (RAN -> %s)" % (n, m["state"] if m else "absent"))
            missing += 1
            continue
        ok = True
        for what, h in sorted(b["outs"].items()):
            if m["outs"].get(what) != h:
                print("DIFF pass %d %s" % (n, what))
                diff += 1
                ok = False
            else:
                same_o += 1
        for what in sorted(set(m["outs"]) - set(b["outs"])):
            print("DIFF pass %d %s (only in new)" % (n, what))
            diff += 1
            ok = False
        same_p += ok
    print("same: %d passes, %d outputs; different: %d; missing: %d" % (same_p, same_o, diff, missing))
    return 0 if diff == 0 and missing == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
```

`tools/metal4_route_report.py`:

```python
#!/usr/bin/env python3
"""One-line summary of a TLOU route run (tools/metal4_route.sh; docs/metal4-backend.md).

usage: metal4_route_report.py <run.log> [--skip N]

fps, encoder ms, CP ms and commits are means over the [gnm-draw] perf lines after the first N
(default 13: boot and loading); split commits are the mean of the [gnm-draw] backend lines (0
without any); skipped and flips come from the last "present #" line; load is the 1-minute load
in the stop line of <run>.mon next to the log. Exit status 1 when the log has no perf line
after the skipped ones.
"""
import argparse
import os
import re
import sys

PERF = re.compile(r"\[gnm-draw\] perf: ([\d.]+) fps .*?per frame: ([\d.]+) commits.*?([\d.]+) ms CP \(CPU\), ([\d.]+) ms encoder")
BACKEND = re.compile(r"\[gnm-draw\] backend \w+: split commits per frame ([\d.]+)")
PRESENT = re.compile(r"\[gnm-draw\] present #(\d+) .*totals: .* skipped (\d+)")
STOP = re.compile(r" stop .* load \{ ([\d.]+)")


def mean(v):
    return sum(v) / len(v) if v else 0.0


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("log")
    ap.add_argument("--skip", type=int, default=13)
    a = ap.parse_args()
    perf, split = [], []
    skipped = flips = fatal = gpu_err = watchdog = asserts = 0
    with open(a.log, errors="replace") as f:
        for line in f:
            m = PERF.search(line)
            if m:
                perf.append(tuple(float(x) for x in m.groups()))
                continue
            m = BACKEND.search(line)
            if m:
                split.append(float(m.group(1)))
                continue
            m = PRESENT.search(line)
            if m:
                flips, skipped = int(m.group(1)), int(m.group(2))
            if "FATAL" in line:
                fatal += 1
            if re.search(r"command buffer .*failed|GPU hang report", line):
                gpu_err += 1
            if "GPU watchdog" in line:
                watchdog += 1
            if "[gnm-residency] ASSERT" in line:
                asserts += 1
    perf = perf[a.skip:]
    if not perf:
        print("metal4_route_report: no perf lines after the first %d" % a.skip)
        return 1
    load = -1.0
    mon = os.path.splitext(a.log)[0] + ".mon"
    if os.path.exists(mon):
        for line in open(mon):
            m = STOP.search(line)
            if m:
                load = float(m.group(1))
    print("fps %.1f enc_ms %.1f cp_ms %.1f commits %.1f split %.1f skipped %d fatal %d gpu_err %d watchdog %d "
          "flips %d load %.1f asserts %d" % (mean([p[0] for p in perf]), mean([p[3] for p in perf]),
                                             mean([p[2] for p in perf]), mean([p[1] for p in perf]), mean(split),
                                             skipped, fatal, gpu_err, watchdog, flips, load, asserts))
    return 0


if __name__ == "__main__":
    sys.exit(main())
```

(The fixture's perf lines after `--skip 1` are 60 and 50 fps → 55.0; encoder 4 and 6 → 5.0; CP 5 and 7 → 6.0; commits 3 and 4 → 3.5; split 0.5 and 1.5 → 1.0.)

`.gitignore`, after `!/tools/refcompare.py`:

```
!/tools/metal4_replay_cmp.py
!/tools/metal4_route_report.py
!/tools/metal4_route.sh
!/tools/metal4_perf_ab.sh
```

`chmod +x tools/metal4_replay_cmp.py tools/metal4_route_report.py`.

- [ ] **Step 4: Run them to verify they pass**

Run: `cd ~/ps4recomp-work/PS4Recomp-metal4 && python3 -m unittest discover -s tools/tests -p 'test_metal4_*.py' 2>&1 | tail -3`
Expected: `OK` (7 tests). The host suite runs them through its existing `python3 -m unittest discover -s "$R/tools/tests"` line; no wiring change.

- [ ] **Step 5: Commit**

```bash
git add .gitignore tools/metal4_replay_cmp.py tools/metal4_route_report.py tools/tests/test_metal4_replay_cmp.py tools/tests/test_metal4_route_report.py
git commit -m "tools: replay-hash compare and route report for the Metal 4 backend work

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

### Task 0.3: Allocations per replayed pass

**Files:**
- Create: `tools/gnm_replay/alloc_count.c`, `tests/host/alloc_count_test.c`
- Modify: `tools/gnm_replay/build.sh:31-34` (build the dylib), `tools/gnm_replay/gnm_replay.mm` (`--allocs <n>`)
- Modify: `tests/host/run_host_tests.sh` (after the `gnm_replay_test` run, `:197`)

**Interfaces:**
- Consumes: `Options::around_render` (Task 0.1).
- Produces:
  - `<replay out>/alloc_count.dylib` exporting `void alloc_count_begin(void)` and `uint64_t alloc_count_end(void)`: counts malloc, calloc, realloc, valloc, posix_memalign, aligned_alloc, malloc_zone_malloc, malloc_zone_calloc, malloc_zone_realloc and malloc_zone_memalign calls made on the calling thread between the two calls.
  - `DYLD_INSERT_LIBRARIES=<out>/alloc_count.dylib gnm_replay <frame> <pass> --allocs <n>`: replays the pass `n + 1` times, measures the renderer calls (Draw/Dispatch → Flush(true)) of the last `n`, prints `allocs per replay: <min> (min of <n>), max <max>`; exit 2 with `alloc_count.dylib is not loaded` when the interposer is absent.

- [ ] **Step 1: Write the failing test**

`tests/host/alloc_count_test.c`:

```c
// The allocation counter of gnm_replay --allocs (tools/gnm_replay/alloc_count.c): with the
// interposer loaded, exactly the 15 allocations made between begin and end on this thread are
// counted (none of another thread's); without it, the program says so and exits 3, so a run that
// forgot DYLD_INSERT_LIBRARIES cannot report a count of 0.
#include <dlfcn.h>
#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>

static void* other_thread(void* arg) {
    (void)arg;
    for (int i = 0; i < 100; i++) free(malloc(32));
    return NULL;
}

int main(void) {
    void (*begin)(void) = (void (*)(void))dlsym(RTLD_DEFAULT, "alloc_count_begin");
    uint64_t (*end)(void) = (uint64_t(*)(void))dlsym(RTLD_DEFAULT, "alloc_count_end");
    if (!begin || !end) {
        printf("alloc_count_test: alloc_count.dylib is not loaded\n");
        return 3;
    }
    void* p[15];
    begin();
    pthread_t th;
    pthread_create(&th, NULL, other_thread, NULL);
    for (int i = 0; i < 10; i++) p[i] = malloc(16 + i);
    for (int i = 10; i < 15; i++) p[i] = calloc(4, 8);
    pthread_join(th, NULL);
    const uint64_t n = end();
    for (int i = 0; i < 15; i++) free(p[i]);
    const int ok = n == 15;
    printf("alloc_count_test: %s (%llu allocations counted, want 15)\n", ok ? "PASS" : "FAIL", (unsigned long long)n);
    return ok ? 0 : 1;
}
```

(`pthread_create` itself may allocate on the calling thread; if the count comes out as 16 or 17, move the thread creation and join before `begin()` / after `end()` and start the other thread with a semaphore it waits on, so only the 15 calls are inside the window. The want value stays 15.)

- [ ] **Step 2: Run it to verify it fails**

```bash
T=$(mktemp -d); clang -std=gnu11 -Wall -Werror ~/ps4recomp-work/PS4Recomp-metal4/tests/host/alloc_count_test.c -o $T/a && $T/a; echo rc=$?
```
Expected: `alloc_count_test: alloc_count.dylib is not loaded`, `rc=3`.

- [ ] **Step 3: Implement**

`tools/gnm_replay/alloc_count.c`:

```c
// SPDX-License-Identifier: GPL-2.0-or-later
// Allocation counter for gnm_replay --allocs (docs/metal4-backend.md, "Allocations per pass").
// Loaded with DYLD_INSERT_LIBRARIES, it interposes the malloc family (dyld __interpose: every
// other image's calls come here, this image's own calls go to the real functions) and counts the
// calls a thread makes between alloc_count_begin() and alloc_count_end(). The per-thread state is
// in pthread keys: they need no allocation (a __thread variable could allocate on first use,
// inside malloc).
#include <malloc/malloc.h>
#include <pthread.h>
#include <stdint.h>
#include <stdlib.h>

static pthread_key_t k_on, k_n;

__attribute__((constructor)) static void init(void) {
    pthread_key_create(&k_on, NULL);
    pthread_key_create(&k_n, NULL);
}

static inline void note(void) {
    if (pthread_getspecific(k_on)) pthread_setspecific(k_n, (void*)((uintptr_t)pthread_getspecific(k_n) + 1));
}

void alloc_count_begin(void) {
    pthread_setspecific(k_n, (void*)0);
    pthread_setspecific(k_on, (void*)1);
}

uint64_t alloc_count_end(void) {
    pthread_setspecific(k_on, NULL);
    return (uint64_t)(uintptr_t)pthread_getspecific(k_n);
}

static void* c_malloc(size_t n) { note(); return malloc(n); }
static void* c_calloc(size_t c, size_t n) { note(); return calloc(c, n); }
static void* c_realloc(void* p, size_t n) { note(); return realloc(p, n); }
static void* c_valloc(size_t n) { note(); return valloc(n); }
static int c_posix_memalign(void** p, size_t a, size_t n) { note(); return posix_memalign(p, a, n); }
static void* c_aligned_alloc(size_t a, size_t n) { note(); return aligned_alloc(a, n); }
static void* c_zone_malloc(malloc_zone_t* z, size_t n) { note(); return malloc_zone_malloc(z, n); }
static void* c_zone_calloc(malloc_zone_t* z, size_t c, size_t n) { note(); return malloc_zone_calloc(z, c, n); }
static void* c_zone_realloc(malloc_zone_t* z, void* p, size_t n) { note(); return malloc_zone_realloc(z, p, n); }
static void* c_zone_memalign(malloc_zone_t* z, size_t a, size_t n) { note(); return malloc_zone_memalign(z, a, n); }

#define INTERPOSE(rep, orig)                                                                        \
    __attribute__((used)) static const struct { const void* r; const void* o; } interpose_##orig \
        __attribute__((section("__DATA,__interpose"))) = {(const void*)(rep), (const void*)(orig)}

INTERPOSE(c_malloc, malloc);
INTERPOSE(c_calloc, calloc);
INTERPOSE(c_realloc, realloc);
INTERPOSE(c_valloc, valloc);
INTERPOSE(c_posix_memalign, posix_memalign);
INTERPOSE(c_aligned_alloc, aligned_alloc);
INTERPOSE(c_zone_malloc, malloc_zone_malloc);
INTERPOSE(c_zone_calloc, malloc_zone_calloc);
INTERPOSE(c_zone_realloc, malloc_zone_realloc);
INTERPOSE(c_zone_memalign, malloc_zone_memalign);
```

`tools/gnm_replay/build.sh`: after the `replay_links.o` line add

```bash
clang -std=gnu11 -O1 -g -Wall -Werror -dynamiclib "$R/tools/gnm_replay/alloc_count.c" -o "$OUT/alloc_count.dylib"
```

`tools/gnm_replay/gnm_replay.mm`: add `#include <dlfcn.h>` and, in the flag loop of Task 0.1, `else if (!strcmp(argv[i], "--allocs") && i + 1 < argc) allocs = (int)strtol(argv[++i], nullptr, 10);` (declare `int allocs = 0;` before it). Before the single-pass `ReplayPass` call:

```objc
        if (allocs > 0) {
            struct Counter {
                void (*begin)(void);
                uint64_t (*end)(void);
                uint64_t last = 0;
            } c{(void (*)(void))dlsym(RTLD_DEFAULT, "alloc_count_begin"),
                (uint64_t(*)(void))dlsym(RTLD_DEFAULT, "alloc_count_end")};
            if (!c.begin || !c.end) {
                printf("alloc_count.dylib is not loaded (DYLD_INSERT_LIBRARIES=<replay out>/alloc_count.dylib)\n");
                return 2;
            }
            ps4replay::Result warm = ps4replay::ReplayPass(o); // caches, pipelines, textures
            if (!warm.ran) {
                printf("pass %u: NOT REPLAYED: %s\n", o.pass, warm.error.c_str());
                return 2;
            }
            o.around_render = [](void* p, bool begin) {
                Counter* k = static_cast<Counter*>(p);
                if (begin) k->begin();
                else k->last = k->end();
            };
            o.around_ctx = &c;
            uint64_t mn = UINT64_MAX, mx = 0;
            for (int k = 0; k < allocs; ++k) {
                ps4replay::ReplayPass(o);
                mn = std::min(mn, c.last);
                mx = std::max(mx, c.last);
            }
            printf("allocs per replay: %llu (min of %d), max %llu\n", (unsigned long long)mn, allocs, (unsigned long long)mx);
            return 0;
        }
```

(add `#include <algorithm>`).

`tests/host/run_host_tests.sh`, after the `gnm_replay_test` run line:

```bash
# The allocation counter of gnm_replay --allocs: counts this thread's calls only, and the
# program refuses to report without the interposer (exit 3).
clang -std=gnu11 -Wall -Werror "$R/tests/host/alloc_count_test.c" -o "$T/alloc_count_test"
DYLD_INSERT_LIBRARIES="$T/replay/alloc_count.dylib" "$T/alloc_count_test"
rc=0; "$T/alloc_count_test" > /dev/null || rc=$?
[ $rc -eq 3 ] || { echo "alloc_count_test: without the interposer it did not refuse (rc=$rc)"; exit 1; }
```

- [ ] **Step 4: Run it to verify it passes**

```bash
cd ~/ps4recomp-work/PS4Recomp-metal4 || exit 1
T=$(mktemp -d); tools/gnm_replay/build.sh $T tools/gnm_replay/gnm_replay.mm > $T/b.txt 2>&1 || cat $T/b.txt
clang -std=gnu11 -Wall -Werror tests/host/alloc_count_test.c -o $T/a && DYLD_INSERT_LIBRARIES=$T/alloc_count.dylib $T/a
```
Expected: `alloc_count_test: PASS (15 allocations counted, want 15)`.

- [ ] **Step 5: Host suite and commit**

Host suite (tag `t03`): `host=0`.

```bash
git add tools/gnm_replay/alloc_count.c tools/gnm_replay/build.sh tools/gnm_replay/gnm_replay.mm tests/host/alloc_count_test.c tests/host/run_host_tests.sh
git commit -m "gnm_replay: count the renderer's allocations per replayed pass

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

### Task 0.4: Route scripts, the TLOU capture set and the Metal 3 baseline

**Files:**
- Create: `tools/metal4_route.sh`, `tools/metal4_perf_ab.sh`, `docs/metal4-baseline.md`
- (outside the repo) `$M/captures/{courtyard,spores}/frame_<n>`, `$M/replay/p0_m3_{courtyard,spores}.txt`, `$M/tlou_build_p0`, `$M/replay_p0`

**Interfaces:**
- Consumes: Tasks 0.1–0.3; `~/ps4recomp-work/tools/heavy_lock.sh`; `~/ps4recomp-work/mutex_perf/extload.sh` is not needed (the monitor samples other processes' CPU itself).
- Produces: the route and A/B commands of "Commands used by every task"; the Phase 0 hash lists every R-check compares with; `docs/metal4-baseline.md` with the numbers every gate compares with.

- [ ] **Step 1: Write `tools/metal4_route.sh`**

```bash
#!/bin/bash
# TLOU fixed route for the Metal 4 backend work (docs/metal4-backend.md, "Measurements"): the
# walk script (after the autopress phase) from a copy of a save, time-bounded, with a scratch
# data directory and a scratch cache directory, a monitor (WindowServer RSS, load, GPU errors,
# other processes' CPU) and a kill by PID on every exit path. Run it under heavy_lock
# (HEAVY_EXCLUSIVE=1 for fps).
# usage: BUILD=<build dir> TAG=<run name> [METAL=3|4] [SECS=300] [DATASRC=<save to copy>]
#        [CACHE=<cache dir>] [OUT=<runs dir>] [EVERY=<screenshot period>] tools/metal4_route.sh [env...]
set -u
W=$HOME/ps4recomp-work
: "${BUILD:?BUILD= required}" "${TAG:?TAG= required}"
SECS=${SECS:-300}
[ "$SECS" -le 300 ] || { echo "metal4_route: SECS must be <= 300"; exit 2; }
if P=$(pgrep -x eboot); then echo "metal4_route: the owner's game runs (pid $P); not starting"; exit 3; fi
OUT=${OUT:-$W/metal4_research/runs}
DATASRC=${DATASRC:-$W/data_ch1}
CACHE=${CACHE:-$W/metal4_research/cache_$TAG}
mkdir -p "$OUT" "$CACHE" "$OUT/shots_$TAG" || exit 1
rm -f "$OUT/shots_$TAG"/*.png
D=$(mktemp -d "$W/metal4_research/data_$TAG.XXXXXX") || exit 1
cp -R "$DATASRC"/. "$D"/ || exit 1
LOG=$OUT/$TAG.log; MON=$OUT/$TAG.mon
for ((w = 0; w < 48; w++)); do awk "BEGIN{exit !($(sysctl -n vm.loadavg | awk '{print $2}') < 10)}" && break; sleep 5; done
WS=$(pgrep -x WindowServer | head -1)
WS0=$(ps -o rss= -p "$WS" | tr -d ' ')
echo "$TAG start $(date +%T) load $(sysctl -n vm.loadavg) WindowServer rss ${WS0} KB metal ${METAL:-default}" | tee "$MON"
cd "$BUILD" || exit 1
EXE=ps4_app_route_$$
cp ps4_app "$EXE" || exit 1
env PS4RECOMP_DATA_DIR="$D" PS4RECOMP_CACHE_DIR="$CACHE" ${METAL:+PS4_GNM_METAL=$METAL} PS4_UPSCALE=0 PS4_PRO=0 \
  PS4_NO_DIALOGS=1 PS4_RECOMP_HEADLESS=1 PS4_BACKGROUND_WINDOW=1 PS4_LANG=ru PS4_PAD_AUTOPRESS=4000 \
  PS4_PAD_AUTOPRESS_UNTIL=90000 "PS4_PAD_SCRIPT=$(cat "${SCRIPT:-$W/walk_script.txt}")" \
  PS4_SCREENSHOT_DIR="$OUT/shots_$TAG" PS4_SCREENSHOT_EVERY=${EVERY:-600} "$@" ./"$EXE" > "$LOG" 2>&1 &
GP=$!
cleanup() {
  kill -TERM $GP 2>/dev/null; sleep 2; kill -9 $GP 2>/dev/null; wait $GP 2>/dev/null
  kill "$WD" 2>/dev/null
  kill -0 $GP 2>/dev/null && echo "WARNING: game $GP still alive" | tee -a "$MON"
  rm -f "$BUILD/$EXE"
  case "$D" in "$W"/metal4_research/data_*) rm -rf "$D" ;; esac
}
( sleep $((SECS + 30)); kill -9 $GP 2>/dev/null ) &
WD=$!
trap cleanup EXIT
trap 'exit 1' INT TERM HUP
why="time limit"
for ((t = 0; t < SECS; t += 5)); do
  sleep 5
  kill -0 $GP 2>/dev/null || { why="exited"; break; }
  read -r rss cpu < <(ps -o rss=,%cpu= -p "$WS")
  l1=$(sysctl -n vm.loadavg | awk '{print $2}')
  g=$(grep -cE "command buffer .*failed|GPU hang report|GPU watchdog" "$LOG")
  ocpu=$(ps -Ao pid=,pcpu= | awk -v g=$GP '$1 != g {o += $2} END {printf "%.0f", o}')
  echo "t=$t ws_rss=$rss ws_cpu=$cpu load=$l1 gpu_err=$g other_cpu=$ocpu" >> "$MON"
  if [ $((rss - WS0)) -gt 307200 ]; then why="WindowServer RSS +$(((rss - WS0) / 1024)) MB"; break; fi
  if awk "BEGIN{exit !($l1 > 20)}"; then why="load $l1"; break; fi
  if [ "$g" -ge 2 ]; then why="GPU errors $g"; break; fi
done
cleanup
trap - EXIT
echo "$TAG stop $(date +%T) ($why) load $(sysctl -n vm.loadavg) WindowServer rss $(ps -o rss= -p "$WS" | tr -d ' ') KB" | tee -a "$MON"
```

`chmod +x tools/metal4_route.sh`. Check: `bash -n tools/metal4_route.sh && shellcheck tools/metal4_route.sh 2>/dev/null; echo ok` (shellcheck if installed).

- [ ] **Step 2: Write `tools/metal4_perf_ab.sh`**

```bash
#!/bin/bash
# Alternating A/B of the TLOU route (docs/metal4-backend.md, "Measurements"). A and B are
# <build dir>:<3|4>; runs A, B, A, B, ... under HEAVY_EXCLUSIVE=1 heavy_lock, each with the same
# warm cache directory per side; a run whose 1-minute load at its end exceeds 15, or whose monitor
# shows other processes above 150 % CPU in more than one sample, is discarded and repeated (at
# most 2*N attempts per side). Prints every run and the medians of the kept runs.
# usage: N=5 A=<build>:<3|4> B=<build>:<3|4> TAG=<name> [SECS=300] tools/metal4_perf_ab.sh
set -u
: "${A:?} ${B:?} ${TAG:?}"
N=${N:-5}; SECS=${SECS:-300}
R=$(cd "$(dirname "$0")/.." && pwd)
W=$HOME/ps4recomp-work
OUT=$W/metal4_research/runs
declare -a FA FB
run_side() { # side build metal index -> appends the fps of a kept run
  local side=$1 build=$2 metal=$3 i=$4 tag="${TAG}_$1$4"
  HEAVY_EXCLUSIVE=1 "$W/tools/heavy_lock.sh" env BUILD="$build" TAG="$tag" METAL="$metal" SECS="$SECS" \
    CACHE="$W/metal4_research/cache_${TAG}_$side" "$R/tools/metal4_route.sh" > /dev/null 2>&1
  local rep; rep=$(python3 "$R/tools/metal4_route_report.py" "$OUT/$tag.log") || { echo "$tag: no report"; return 1; }
  local load; load=$(awk '{for (i = 1; i < NF; i++) if ($i == "load") print $(i + 1)}' <<< "$rep")
  local busy; busy=$(awk -F'other_cpu=' 'NF > 1 && $2 + 0 > 150 {n++} END {print n + 0}' "$OUT/$tag.mon")
  echo "$tag: $rep other_cpu>150: $busy"
  if awk "BEGIN{exit !($load > 15 || $load < 0)}" || [ "$busy" -gt 1 ]; then echo "$tag: discarded"; return 1; fi
  awk '{print $2}' <<< "$rep"
}
median() { sort -n | awk '{v[NR] = $1} END {if (NR % 2) print v[(NR + 1) / 2]; else printf "%.1f\n", (v[NR / 2] + v[NR / 2 + 1]) / 2}'; }
# one warm-up run per side (caches), not counted
run_side A "${A%:*}" "${A##*:}" w > /dev/null; run_side B "${B%:*}" "${B##*:}" w > /dev/null
ia=0; ib=0
while [ ${#FA[@]} -lt "$N" ] || [ ${#FB[@]} -lt "$N" ]; do
  if [ ${#FA[@]} -lt "$N" ] && [ $ia -lt $((2 * N)) ]; then
    ia=$((ia + 1)); f=$(run_side A "${A%:*}" "${A##*:}" $ia | tail -1); [[ $f =~ ^[0-9.]+$ ]] && FA+=("$f")
  fi
  if [ ${#FB[@]} -lt "$N" ] && [ $ib -lt $((2 * N)) ]; then
    ib=$((ib + 1)); f=$(run_side B "${B%:*}" "${B##*:}" $ib | tail -1); [[ $f =~ ^[0-9.]+$ ]] && FB+=("$f")
  fi
  [ $ia -ge $((2 * N)) ] && [ $ib -ge $((2 * N)) ] && break
done
echo "A kept ${#FA[@]}: ${FA[*]}"
echo "B kept ${#FB[@]}: ${FB[*]}"
[ ${#FA[@]} -ge "$N" ] && [ ${#FB[@]} -ge "$N" ] || { echo "metal4_perf_ab: fewer than $N kept runs per side"; exit 1; }
echo "median fps A $(printf '%s\n' "${FA[@]}" | median) B $(printf '%s\n' "${FB[@]}" | median)"
echo "min/max A $(printf '%s\n' "${FA[@]}" | sort -n | head -1)/$(printf '%s\n' "${FA[@]}" | sort -n | tail -1)"
```

(The `run_side` lines also print the encoder and CP ms of every kept run; the medians of those are taken by hand from the printed reports into the baseline file.) `chmod +x tools/metal4_perf_ab.sh`; `bash -n tools/metal4_perf_ab.sh`.

- [ ] **Step 3: Build the Phase 0 binaries**

TLOU game build with tag `p0` and the replay tool build with tag `p0` (commands above).
Expected: `gen=0`, `build=0`.

- [ ] **Step 4: Capture the TLOU set (one frame per save)**

```bash
df -h ~/ps4recomp-work | tail -1     # at least 12 GiB available; otherwise stop and ask the owner
cd ~/ps4recomp-work/PS4Recomp-metal4 || exit 1
for F in courtyard spores; do
  case $F in courtyard) SRC=$HOME/ps4recomp-work/data_ch1 ;; spores) SRC=$HOME/ps4recomp-work/data_user1441 ;; esac
  mkdir -p $M/captures/$F
  ~/ps4recomp-work/tools/heavy_lock.sh env BUILD=$M/tlou_build_p0 TAG=p0_capture_$F DATASRC=$SRC SECS=300 \
    tools/metal4_route.sh PS4_GNM_SYNC_ENCODE=1 PS4_GNM_CAPTURE_FRAME=3600 PS4_GNM_CAPTURE_DIR=$M/captures/$F \
    PS4_GNM_CAPTURE_REPLAY=all PS4_GNM_CAPTURE_RAW_MB=4096
  ls $M/captures/$F/frame_3600/manifest.json && python3 tools/gnm_capture_view.py $M/captures/$F/frame_3600
done
du -sh $M/captures/*
```
Expected: both `manifest.json` exist. Open `$M/captures/<F>/frame_3600/index.html`'s last color-target thumbnails with the Read tool: the frame must be gameplay (not a loading screen or menu). If it is not, delete that frame directory and capture again with `PS4_GNM_CAPTURE_FRAME=4800`. Record the frame numbers in the baseline file.

- [ ] **Step 5: The Phase 0 pass set and allocation counts**

```bash
mkdir -p $M/replay
for F in courtyard spores; do
  FR=$(ls -d $M/captures/$F/frame_* | head -1)
  ~/ps4recomp-work/tools/heavy_lock.sh $M/replay_p0/gnm_replay "$FR" all --sha > $M/replay/p0_m3_$F.txt 2> $M/replay/p0_m3_$F.err
  echo "$F: $(grep -c '^P .* RAN ' $M/replay/p0_m3_$F.txt) ran ($(grep -c '^P .* RAN 1 ' $M/replay/p0_m3_$F.txt) byte-exact vs capture), $(grep -c '^P .* NOT ' $M/replay/p0_m3_$F.txt) not replayed"
  ~/ps4recomp-work/tools/heavy_lock.sh $M/replay_p0/gnm_replay "$FR" all --sha > $M/replay/p0b_m3_$F.txt 2>/dev/null
  python3 tools/metal4_replay_cmp.py $M/replay/p0_m3_$F.txt $M/replay/p0b_m3_$F.txt | tail -1
done
FR=$(ls -d $M/captures/courtyard/frame_* | head -1)
D=$(awk '$1 == "P" && $3 == "draw" && $4 == "RAN" {print $2; exit}' $M/replay/p0_m3_courtyard.txt)
C=$(awk '$1 == "P" && $3 == "dispatch" && $4 == "RAN" {print $2; exit}' $M/replay/p0_m3_courtyard.txt)
for k in 1 2 3; do for P in $D $C; do
  DYLD_INSERT_LIBRARIES=$M/replay_p0/alloc_count.dylib $M/replay_p0/gnm_replay "$FR" $P --allocs 5 | tail -1
done; done
```
Expected: the second run of each frame compares `different: 0; missing: 0` with the first (the replay is deterministic). If a pass differs between two runs of the same build, it is non-deterministic: list it in the baseline file under "non-deterministic passes". The comparison tool gets no exclusion option: it prints such a pass as DIFF in every later comparison, and each gate accepts a DIFF only for a pass on that list. Record `D`, `C` and the minimum `allocs per replay` of each over the three rounds.

- [ ] **Step 6: Route baseline (Metal 3)**

```bash
N=3 A=$M/tlou_build_p0:3 B=$M/tlou_build_p0:3 TAG=p0_route tools/metal4_perf_ab.sh | tee $M/ab_p0_route.txt
```
(`METAL=3` on a Phase 0 binary is ignored by the renderer; both sides are Metal 3.) Expected: `A kept 3`, `B kept 3`. These six runs are the Metal 3 baseline: fps, encoder ms, CP ms, commits per frame, skipped draws, from their report lines.

- [ ] **Step 7: Host suite on Phase 0**

Host suite (tag `p0`): `host=0`.

- [ ] **Step 8: Write `docs/metal4-baseline.md`**

```markdown
# Metal 4 backend: baseline numbers (Metal 3)

Recorded by Task 0.4 of docs/superpowers/plans/2026-10-22-metal4-backend.md on commit <hash>,
Apple M1 Pro, macOS <version>. Every phase gate appends its own section below.

## Phase 0 (Metal 3, before the seam)

- TLOU route: courtyard walk (tools/metal4_route.sh, data_ch1, 300 s, PS4_PRO=0, PS4_UPSCALE=0), six runs:

| run | fps | encoder ms/frame | CP ms/frame | commits/frame | skipped draws | load |
|---|---|---|---|---|---|---|
| <tag> | … | … | … | … | … | … |

  Median fps <x>, spread <min>–<max>.
- Replay pass set: courtyard frame <n>: <ran> passes replayed (<exact> byte-exact vs the capture),
  <not> not replayed; spores frame <n>: … Hash lists: $M/replay/p0_m3_{courtyard,spores}.txt.
  Non-deterministic passes (differ between two Metal 3 runs): <none | list>.
- Allocations per replayed pass (min of 3×5): draw pass <D>: <a>; dispatch pass <C>: <b>.
- Host suite: green (log $M/host_p0.log).
```

Fill every `<…>` from Steps 4–7 (no placeholder may stay).

- [ ] **Step 9: Commit**

```bash
git add tools/metal4_route.sh tools/metal4_perf_ab.sh docs/metal4-baseline.md
git commit -m "Metal 4 work: route and A/B scripts, Metal 3 baseline numbers

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

### Task 0.5: Phase 0 gate

**Files:** none (verification).

**Acceptance (spec table, Phase 0):** "A baseline numbers file; the host suite is green."

- [ ] **Step 1:** `grep -nE '<[A-Za-z |]+>|…' docs/metal4-baseline.md` prints nothing (every template field of the Phase 0 section filled); read the file once to confirm every number is present.
- [ ] **Step 2:** `tail -3 $M/host_p0.log` shows the capture-tools PASS line and the file was written by a run with `host=0`.
- [ ] **Step 3:** Go analysis: `go=0`.
- [ ] **Step 4:** Record "Phase 0 complete" with the commit hash in the SDD ledger (the local, git-ignored SDD workspace).

---

## Phase 1: The seam, Metal 3 behind it

Phase 1 moves today's Metal 3 code behind `GnmBackend` without changing behaviour. Task 1.1 declares the whole interface; Task 1.2 writes `Metal3Backend` completely (a transcription of the Metal calls listed per method) and moves the command-buffer lifecycle onto it; Tasks 1.3–1.9 each move one concern's call sites in `ps4_gnm_draw.mm` onto it and delete the raw code. Between 1.2 and 1.9 the not-yet-moved sites reach the Metal 3 objects through `Metal3Backend::LegacyCmd/LegacyRender/LegacyCompute` (declared in 1.2, deleted in 1.9; the Phase 1 gate checks they are gone). Line numbers are those of a053d62; each task also names the function, which is what counts once earlier tasks moved lines.

**Acceptance of every Phase 1 task:** R-check `<task tag>` with `PS4_GNM_METAL=3` gives `cmp=0` on both frames (pure move: byte-identical outputs), and the host suite passes unchanged. Each task's commit message names the moved functions.

### Task 1.1: The `GnmBackend` interface and backend selection

**Files:**
- Create: `$G/ps4_gnm_backend.h`, `$G/ps4_gnm_backend.mm`, `tests/host/gnm_backend_select_test.mm`, `docs/metal4-backend.md`
- Modify: `tools/gnm_replay/build.sh:20-21` (compile `ps4_gnm_backend.mm`)
- Modify: `tests/host/run_host_tests.sh` (after the `gnm_clear_color_test` run)

**Interfaces:**
- Consumes: nothing.
- Produces (every later task uses these names):

`$G/ps4_gnm_backend.h`:

```objc
// SPDX-License-Identifier: GPL-2.0-or-later
/*
 * PS4Recomp - the renderer backend seam (docs/metal4-backend.md).
 *
 * The GNM renderer (ps4_gnm_draw.mm) decides what is encoded: render passes and their clears,
 * bindings, barriers, residency and the seq timeline of committed work. A GnmBackend executes it
 * on one Metal API: Metal3Backend (ps4_gnm_backend_metal3.mm, MTLCommandQueue) or Metal4Backend
 * (ps4_gnm_backend_metal4.mm, MTL4CommandQueue). Both use the same device objects: buffers,
 * textures, samplers and Metal 3 pipeline states. ps4draw::Init chooses one from PS4_GNM_METAL
 * (ChooseBackend).
 *
 * Threading: everything runs on the encoder (under encq::state_mu), except CompletedSeq and Stats,
 * which any thread may call, and the residency calls, which are thread-safe.
 *
 * Objects passed in are not retained beyond the call unless stated: the renderer keeps them alive
 * (a Metal 3 command buffer retains what is encoded into it; Metal 4 keeps what GnmResidency holds).
 */
#ifndef PS4_GNM_BACKEND_H
#define PS4_GNM_BACKEND_H

#import <Foundation/Foundation.h>
#import <Metal/Metal.h>

#include <stddef.h>
#include <stdint.h>

#include <memory>
#include <string>

namespace ps4gnm {

class GnmBackend;

// Shader stage of a binding (the renderer's former ps4draw::Stage).
enum class GnmStage : uint8_t { Vertex = 0, Fragment = 1, Compute = 2 };

enum class GnmBackendKind : uint8_t { Metal3 = 3, Metal4 = 4 };

// What a backend implements. Metal3Backend: kGnmCapAll.
enum GnmCaps : uint32_t {
    kGnmCapClears = 1u << 0,  // render passes (load, clear, store, resolve), direct draws, CopyTexture: present
    kGnmCapCompute = 1u << 1, // compute encoders, compute bindings, Dispatch*
    kGnmCapCopies = 1u << 2,  // CopyBuffer, FillBuffer, CopyTextureRegion, CopyBufferToTexture
    kGnmCapDraws = 1u << 3,   // every GnmDraw kind, SetFixed, barriers inside a render pass
    kGnmCapAll = kGnmCapClears | kGnmCapCompute | kGnmCapCopies | kGnmCapDraws,
};

// A Metal 3 queue holds at most this many uncompleted command buffers; the Metal 4 backend applies
// the same limit to its seq timeline (WaitForRoom).
constexpr uint64_t kGnmMaxCommandBuffers = 64;

// The command buffers being recorded: the main one (one seq of the timeline) and the texture
// upload one, committed right before it (the renderer's former S.upload_cmd).
enum class GnmCmdTarget : uint8_t { Main = 0, Upload = 1 };

// The encoder open on the current target. At most one is open per target.
enum class GnmEncoder : uint8_t { None = 0, Render, Compute, Copy };

// Barrier stages, as MTLStages values (Metal 4 passes them on, Metal 3 maps them).
enum GnmStageBits : uint32_t {
    kGnmStageVertex = 1u << 0,
    kGnmStageFragment = 1u << 1,
    kGnmStageDispatch = 1u << 27,
    kGnmStageBlit = 1u << 28,
};
// The memory a barrier orders on Metal 3 (MTLBarrierScope values). Metal 4 barriers order all
// memory with device visibility.
enum GnmScopeBits : uint8_t { kGnmScopeBuffers = 1, kGnmScopeTextures = 2 };

// The residency set an allocation belongs to (Metal 4; Metal 3 makes bound resources resident by itself).
enum class GnmResidencyClass : uint8_t { Guest = 0, Texture = 1, Builtin = 2 };
constexpr int kGnmResidencyClasses = 3;

enum class GnmLoad : uint8_t { Load, Clear, DontCare };
enum class GnmStore : uint8_t { Store, MultisampleResolve };

struct GnmAttachment {
    __unsafe_unretained id<MTLTexture> tex = nil;
    __unsafe_unretained id<MTLTexture> resolve = nil; // GnmStore::MultisampleResolve
    uint32_t slice = 0;
    GnmLoad load = GnmLoad::Load;
    GnmStore store = GnmStore::Store;
};

// One render pass (MTLRenderPassDescriptor / MTL4RenderPassDescriptor).
struct GnmPassDesc {
    GnmAttachment color[8];
    MTLClearColor clear_color[8] = {}; // color[i].load == Clear
    GnmAttachment depth, stencil;
    double clear_depth = 0;            // depth.load == Clear (in [0, 1])
    uint32_t clear_stencil = 0;        // stencil.load == Clear
    uint32_t width = 0, height = 0;    // renderTargetWidth / renderTargetHeight; 0: not set
    uint32_t default_samples = 0;      // defaultRasterSampleCount; 0: not set
    uint32_t num_sample_positions = 0; // programmable sample positions; 0: the defaults
    MTLSamplePosition sample_positions[4] = {};
    __unsafe_unretained NSString* label = nil;
};

// Fixed-function state of a render encoder (the renderer's former EncoderState::Fixed). The
// renderer compares it with the state it set last and passes the changed fields (GnmFixedBits).
struct GnmFixedState {
    MTLViewport vp;
    MTLScissorRect sc;
    uint32_t stencil_ref[2]; // front, back
    uint32_t cull, winding, fill, clip; // MTLCullMode, MTLWinding, MTLTriangleFillMode, MTLDepthClipMode
    float bias[3];  // constant, slope, clamp
    float blend[4]; // blend color
};
enum GnmFixedBits : uint32_t {
    kGnmFixedStencilRef = 1u << 0,
    kGnmFixedViewport = 1u << 1,
    kGnmFixedScissor = 1u << 2,
    kGnmFixedCull = 1u << 3,
    kGnmFixedWinding = 1u << 4,
    kGnmFixedFill = 1u << 5,
    kGnmFixedClip = 1u << 6,
    kGnmFixedBias = 1u << 7,
    kGnmFixedBlend = 1u << 8,
};

enum class GnmDrawKind : uint8_t { Direct, Indexed, Indirect, IndexedIndirect };
struct GnmDraw {
    GnmDrawKind kind = GnmDrawKind::Direct;
    MTLPrimitiveType prim = MTLPrimitiveTypeTriangle;
    uint32_t vertex_start = 0;   // Direct
    uint32_t count = 0;          // vertices (Direct) or indices (Indexed)
    uint32_t instances = 1;      // Direct, Indexed
    uint32_t base_instance = 0;  // Direct, Indexed
    int32_t base_vertex = 0;     // Indexed
    MTLIndexType index_type = MTLIndexTypeUInt16;
    __unsafe_unretained id<MTLBuffer> index_buffer = nil; // Indexed, IndexedIndirect
    uint64_t index_offset = 0;
    uint64_t index_length = 0;   // bytes readable at index_offset (Metal 4 needs the length)
    __unsafe_unretained id<MTLBuffer> indirect_buffer = nil; // Indirect, IndexedIndirect
    uint64_t indirect_offset = 0;
};

// The end of one seq of the timeline: called once, on a Metal thread, after all its command
// buffers (upload and main, and Metal 4's split parts) completed or failed.
struct GnmCompletion {
    uint64_t seq = 0;
    bool failed = false;
    double gpu_start = 0, gpu_end = 0;        // seconds (MTLCommandBuffer GPUStartTime / GPUEndTime)
    __unsafe_unretained NSError* error = nil; // valid during the call
};
using GnmCompletionFn = void (*)(void* ctx, const GnmCompletion& c);

struct GnmBackendStats {
    uint64_t commits = 0;         // queue commits so far (all targets)
    uint64_t split_commits = 0;   // of those, made inside one seq for a queue-level event (Metal 4)
    uint64_t allocators = 0;      // command allocators created (Metal 4)
    uint64_t allocator_resets = 0;
    uint64_t allocator_bytes = 0; // their allocatedSize, summed
    uint64_t resident = 0;        // allocations in the residency sets (Metal 4)
    uint64_t resident_bytes = 0;  // the sets' allocatedSize, summed
};

// The per-bind operations, called through this table: one indirect call per bind, no virtual
// dispatch (the renderer's dedupe has already dropped unchanged binds).
struct GnmBindOps {
    void (*buffer)(GnmBackend*, GnmStage, uint32_t slot, __unsafe_unretained id<MTLBuffer> b, uint64_t off);
    void (*buffer_offset)(GnmBackend*, GnmStage, uint32_t slot, uint64_t off); // same buffer, new offset
    void (*bytes)(GnmBackend*, GnmStage, uint32_t slot, const void* p, size_t n);
    void (*texture)(GnmBackend*, GnmStage, uint32_t slot, __unsafe_unretained id<MTLTexture> t);
    void (*sampler)(GnmBackend*, GnmStage, uint32_t slot, __unsafe_unretained id<MTLSamplerState> s);
    // a buffer reached through an argument buffer (gpuAddress tables): Metal 3 useResource
    void (*use)(GnmBackend*, GnmStage, __unsafe_unretained id<MTLBuffer> b, bool written);
};

class GnmBackend {
public:
    virtual ~GnmBackend() = default;

    virtual GnmBackendKind Kind() const = 0;
    virtual uint32_t Caps() const = 0; // GnmCaps
    virtual bool Init(id<MTLDevice> dev, std::string* why) = 0;
    virtual id<MTLDevice> Device() const = 0;
    // A Metal 3 queue for work outside the timeline that the CPU waits for at once after a drain
    // (TextureCache readbacks and raw writes, capture). Metal 3: the timeline's queue itself.
    virtual id<MTLCommandQueue> SideQueue() const = 0;

    // ---- command buffers and the seq timeline
    // Opens target t's command buffer (it must not be open). encoder_status: Metal 3
    // MTLCommandBufferErrorOptionEncoderExecutionStatus (PS4_GNM_ENCODER_STATUS); Metal 4 has none.
    virtual void BeginCmd(GnmCmdTarget t, NSString* label, bool encoder_status) = 0;
    virtual bool CmdOpen(GnmCmdTarget t) const = 0;
    // The target that encoder, binding, work and event calls go to (Main unless switched).
    virtual void UseTarget(GnmCmdTarget t) = 0;
    virtual GnmCmdTarget Target() const = 0;
    // Commits the upload command buffer alone (no main one is open); it runs before the next seq.
    virtual void CommitUpload() = 0;
    // Commits the upload command buffer (if open), then the main one, as seq (the previous seq + 1).
    // done(ctx, …) runs once when everything of seq has completed. Encoders must be ended.
    virtual void Commit(uint64_t seq, GnmCompletionFn done, void* ctx) = 0;
    // The highest seq whose command buffers and every earlier one have completed (any thread).
    virtual uint64_t CompletedSeq() const = 0;
    // Before opening a main command buffer while `committed` seqs were committed: waits until fewer
    // than max_outstanding are uncompleted. False: none completed within timeout_ms (a GPU hang).
    virtual bool WaitForRoom(uint64_t committed, uint64_t max_outstanding, double timeout_ms) = 0;
    // Queue-level event operations in the current target's stream, after the work encoded so far
    // (signal) / before the work encoded from now on (wait). Metal 3 encodes them into the command
    // buffer; Metal 4 has them only between command buffers and splits the seq there.
    virtual void QueueSignal(id<MTLSharedEvent> ev, uint64_t value) = 0;
    virtual void QueueWait(id<MTLSharedEvent> ev, uint64_t value) = 0;

    // ---- encoders (on the current target)
    virtual GnmEncoder OpenEncoder() const = 0;
    // Changes whenever an encoder is opened on any target: the renderer's dedupe is valid only
    // while it holds.
    virtual uint64_t EncoderSerial() const = 0;
    virtual bool BeginRender(const GnmPassDesc& d) = 0;
    virtual void BeginCompute(bool serial) = 0; // serial: dispatches in order (PS4_GNM_SERIAL_COMPUTE, uploads)
    virtual void BeginCopies() = 0;
    virtual void EndEncoder() = 0;               // the open encoder, if any
    virtual void SetEncoderLabel(NSString* label) = 0;
    // Orders work inside the open encoder: `before` stages after `after` stages (GnmStageBits);
    // scope: GnmScopeBits (Metal 3). Nothing when no encoder is open (encoder boundaries are
    // ordered by the backend: Metal 3 tracking, Metal 4 a barrier at each encoder start).
    virtual void Barrier(uint32_t after, uint32_t before, uint8_t scope) = 0;

    // ---- pipeline and fixed-function state (on the open encoder)
    virtual void SetRenderPipeline(id<MTLRenderPipelineState> p) = 0;
    virtual void SetDepthStencil(id<MTLDepthStencilState> d) = 0;
    virtual void SetFixed(const GnmFixedState& f, uint32_t changed) = 0; // changed: GnmFixedBits
    virtual void SetComputePipeline(id<MTLComputePipelineState> p) = 0;

    // ---- binding (on the open encoder of the stage)
    void BindBuffer(GnmStage st, uint32_t slot, __unsafe_unretained id<MTLBuffer> b, uint64_t off) {
        ops_.buffer(this, st, slot, b, off);
    }
    void BindBufferOffset(GnmStage st, uint32_t slot, uint64_t off) { ops_.buffer_offset(this, st, slot, off); }
    void BindBytes(GnmStage st, uint32_t slot, const void* p, size_t n) { ops_.bytes(this, st, slot, p, n); }
    void BindTexture(GnmStage st, uint32_t slot, __unsafe_unretained id<MTLTexture> t) { ops_.texture(this, st, slot, t); }
    void BindSampler(GnmStage st, uint32_t slot, __unsafe_unretained id<MTLSamplerState> s) {
        ops_.sampler(this, st, slot, s);
    }
    void UseResource(GnmStage st, __unsafe_unretained id<MTLBuffer> b, bool written) { ops_.use(this, st, b, written); }

    // ---- work
    virtual void Draw(const GnmDraw& d) = 0;
    virtual void Dispatch(MTLSize groups, MTLSize threads_per_group) = 0;
    virtual void DispatchThreads(MTLSize threads, MTLSize threads_per_group) = 0;
    virtual void DispatchIndirect(id<MTLBuffer> args, uint64_t off, MTLSize threads_per_group) = 0;
    // copies and fills (inside BeginCopies … EndEncoder)
    virtual void CopyBuffer(id<MTLBuffer> src, uint64_t src_off, id<MTLBuffer> dst, uint64_t dst_off, uint64_t n) = 0;
    virtual void FillBuffer(id<MTLBuffer> dst, uint64_t off, uint64_t n, uint8_t value) = 0;
    virtual void CopyTexture(id<MTLTexture> src, id<MTLTexture> dst) = 0;
    virtual void CopyTextureRegion(id<MTLTexture> src, uint32_t src_slice, uint32_t src_level, MTLOrigin src_origin,
                                   MTLSize size, id<MTLTexture> dst, uint32_t dst_slice, uint32_t dst_level,
                                   MTLOrigin dst_origin) = 0;
    virtual void CopyBufferToTexture(id<MTLBuffer> src, uint64_t src_off, uint64_t row_bytes, uint64_t image_bytes,
                                     MTLSize size, id<MTLTexture> dst, uint32_t slice, uint32_t level,
                                     MTLOrigin origin) = 0;

    // ---- residency (thread-safe). Metal 3: bound resources are resident by themselves, these do
    // nothing and IsResident is true. Metal 4: GnmResidency.
    virtual void MakeResident(id<MTLAllocation> a, GnmResidencyClass c) = 0;
    // a leaves its set once every seq up to after_seq has completed (the renderer passes the seq
    // of the open command buffer: committed + 1)
    virtual void Evict(id<MTLAllocation> a, uint64_t after_seq) = 0;
    virtual bool IsResident(id<MTLAllocation> a) const = 0;

    virtual GnmBackendStats Stats() const = 0; // any thread

protected:
    GnmBindOps ops_{};
};

// Compute work of the guest memory protocol: the backend's open compute encoder (raw == nil), or
// a Metal 3 compute encoder of the guest memory re-run queue (queue2 stays on Metal 3).
struct GnmComputeSink {
    GnmBackend* be = nullptr;
    __unsafe_unretained id<MTLComputeCommandEncoder> raw = nil;

    void Pipeline(id<MTLComputePipelineState> p) const {
        if (raw) [raw setComputePipelineState:p];
        else be->SetComputePipeline(p);
    }
    void Buffer(uint32_t slot, id<MTLBuffer> b, uint64_t off) const {
        if (raw) [raw setBuffer:b offset:off atIndex:slot];
        else be->BindBuffer(GnmStage::Compute, slot, b, off);
    }
    void Bytes(uint32_t slot, const void* p, size_t n) const {
        if (raw) [raw setBytes:p length:n atIndex:slot];
        else be->BindBytes(GnmStage::Compute, slot, p, n);
    }
    void Dispatch(MTLSize groups, MTLSize tpt) const {
        if (raw) [raw dispatchThreadgroups:groups threadsPerThreadgroup:tpt];
        else be->Dispatch(groups, tpt);
    }
    void DispatchIndirect(id<MTLBuffer> args, uint64_t off, MTLSize tpt) const {
        if (raw) [raw dispatchThreadgroupsWithIndirectBuffer:args indirectBufferOffset:off threadsPerThreadgroup:tpt];
        else be->DispatchIndirect(args, off, tpt);
    }
    // the guest memory protocol's ordering between probe, gate, pass and harvest
    void Barrier() const {
        if (raw) [raw memoryBarrierWithScope:MTLBarrierScopeBuffers];
        else be->Barrier(kGnmStageDispatch, kGnmStageDispatch, kGnmScopeBuffers);
    }
};

// ---- selection (ps4draw::Init)
struct GnmBackendChoice {
    bool ok = false;
    GnmBackendKind kind = GnmBackendKind::Metal3;
    std::string why; // !ok: the startup error; ok: how the choice was made (logged)
};
// env: PS4_GNM_METAL (nullptr or "": the default). device_has_metal4: supportsFamily:
// MTLGPUFamilyMetal4. metal4_caps: what this build's Metal 4 backend implements (0: none).
// only_clears: PS4_GNM_MTL4_ONLY_CLEARS=1 (draws skipped; dispatches too without kGnmCapCompute).
// prefer_metal4: the default is 4 when the device and the backend allow it (false until Phase 6).
// An explicit "4" that cannot be honoured is an error, never a silent fallback.
GnmBackendChoice ChooseBackend(const char* env, bool device_has_metal4, uint32_t metal4_caps, bool only_clears,
                               bool prefer_metal4);
const char* BackendName(GnmBackendKind k); // "metal3" / "metal4"
// What this build's Metal 4 backend implements (ps4_gnm_backend.mm until Task 2.2, then
// ps4_gnm_backend_metal4.mm).
extern const uint32_t kMetal4BackendCaps;

std::unique_ptr<GnmBackend> MakeMetal3Backend(); // ps4_gnm_backend_metal3.mm (Task 1.2)

} // namespace ps4gnm

#endif // PS4_GNM_BACKEND_H
```

Task 2.2 adds one declaration: `std::unique_ptr<GnmBackend> MakeMetal4Backend();`.

- [ ] **Step 1: Write the failing test**

`tests/host/gnm_backend_select_test.mm`:

```objc
// Backend selection (ps4gnm::ChooseBackend, ps4_gnm_backend.h): the default, explicit choices,
// and every way an explicit "4" is refused with a reason instead of falling back.
#include <stdio.h>
#include <string.h>

#include "ps4_gnm_backend.h"

using namespace ps4gnm;

static int g_fail = 0;
#define CHECK(c, ...)                                                                   \
    do {                                                                                \
        if (!(c)) {                                                                     \
            fprintf(stderr, "gnm_backend_select_test: FAIL %s:%d: ", __FILE__, __LINE__); \
            fprintf(stderr, __VA_ARGS__);                                               \
            fprintf(stderr, "\n");                                                      \
            g_fail++;                                                                   \
        }                                                                               \
    } while (0)

int main() {
    // default: Metal 3 until prefer_metal4; Metal 4 only with a complete backend on a Metal 4 GPU
    GnmBackendChoice c = ChooseBackend(nullptr, true, kGnmCapAll, false, false);
    CHECK(c.ok && c.kind == GnmBackendKind::Metal3, "default without prefer_metal4: %s", c.why.c_str());
    c = ChooseBackend("", true, kGnmCapAll, false, true);
    CHECK(c.ok && c.kind == GnmBackendKind::Metal4, "default with prefer_metal4: %s", c.why.c_str());
    c = ChooseBackend(nullptr, false, kGnmCapAll, false, true);
    CHECK(c.ok && c.kind == GnmBackendKind::Metal3 && strstr(c.why.c_str(), "MTLGPUFamilyMetal4"),
          "default on a GPU without Metal 4: %s", c.why.c_str());
    c = ChooseBackend(nullptr, true, kGnmCapClears, false, true);
    CHECK(c.ok && c.kind == GnmBackendKind::Metal3, "default with an incomplete Metal 4 backend: %s", c.why.c_str());
    // explicit
    c = ChooseBackend("3", true, 0, false, true);
    CHECK(c.ok && c.kind == GnmBackendKind::Metal3, "explicit 3: %s", c.why.c_str());
    c = ChooseBackend("4", true, kGnmCapAll, false, false);
    CHECK(c.ok && c.kind == GnmBackendKind::Metal4, "explicit 4: %s", c.why.c_str());
    // refusals, each with its reason
    c = ChooseBackend("4", false, kGnmCapAll, false, false);
    CHECK(!c.ok && strstr(c.why.c_str(), "MTLGPUFamilyMetal4"), "4 without Metal 4 GPU: %s", c.why.c_str());
    c = ChooseBackend("4", true, 0, false, false);
    CHECK(!c.ok && strstr(c.why.c_str(), "not implemented"), "4 without a backend: %s", c.why.c_str());
    c = ChooseBackend("4", true, kGnmCapClears, false, false);
    CHECK(!c.ok && strstr(c.why.c_str(), "PS4_GNM_MTL4_ONLY_CLEARS=1"), "4 without draws: %s", c.why.c_str());
    c = ChooseBackend("4", true, kGnmCapClears, true, false);
    CHECK(c.ok && c.kind == GnmBackendKind::Metal4, "4 without draws, only clears: %s", c.why.c_str());
    c = ChooseBackend("5", true, kGnmCapAll, false, false);
    CHECK(!c.ok && strstr(c.why.c_str(), "must be 3 or 4"), "5: %s", c.why.c_str());
    c = ChooseBackend("metal4", true, kGnmCapAll, false, false);
    CHECK(!c.ok, "metal4 accepted");
    CHECK(!strcmp(BackendName(GnmBackendKind::Metal3), "metal3") && !strcmp(BackendName(GnmBackendKind::Metal4), "metal4"),
          "BackendName");
    printf("gnm_backend_select_test: %s\n", g_fail ? "FAIL" : "PASS");
    return g_fail ? 1 : 0;
}
```

- [ ] **Step 2: Run it to verify it fails**

```bash
cd ~/ps4recomp-work/PS4Recomp-metal4 || exit 1
G=pkg/runtime/modules/libSceGnmDriver; T=$(mktemp -d)
clang++ -std=c++17 -fobjc-arc -Wall -Werror -I $G tests/host/gnm_backend_select_test.mm -framework Metal -framework Foundation -o $T/s 2>&1 | head -3
```
Expected: `fatal error: 'ps4_gnm_backend.h' file not found`.

- [ ] **Step 3: Implement**

Create `$G/ps4_gnm_backend.h` with the content above. Create `$G/ps4_gnm_backend.mm`:

```objc
// SPDX-License-Identifier: GPL-2.0-or-later
// PS4Recomp - backend selection (ps4_gnm_backend.h, docs/metal4-backend.md "Selection").
#include "ps4_gnm_backend.h"

#include <string.h>

namespace ps4gnm {

// No Metal 4 backend in this build yet: Task 2.2 adds ps4_gnm_backend_metal4.mm, which defines
// this instead.
const uint32_t kMetal4BackendCaps = 0;

const char* BackendName(GnmBackendKind k) { return k == GnmBackendKind::Metal4 ? "metal4" : "metal3"; }

static std::string Missing(uint32_t caps) {
    std::string s;
    const auto add = [&](uint32_t bit, const char* what) {
        if (caps & bit) return;
        if (!s.empty()) s += ", ";
        s += what;
    };
    add(kGnmCapClears, "render passes");
    add(kGnmCapCompute, "compute");
    add(kGnmCapCopies, "copies");
    add(kGnmCapDraws, "draws");
    return s;
}

GnmBackendChoice ChooseBackend(const char* env, bool device_has_metal4, uint32_t metal4_caps, bool only_clears,
                               bool prefer_metal4) {
    GnmBackendChoice c;
    if (!env || !*env) {
        c.ok = true;
        if (!prefer_metal4) {
            c.why = "default (Metal 3)";
        } else if (!device_has_metal4) {
            c.why = "default: Metal 3, the GPU does not support MTLGPUFamilyMetal4";
        } else if (metal4_caps != kGnmCapAll) {
            c.why = "default: Metal 3, the Metal 4 backend lacks " + Missing(metal4_caps);
        } else {
            c.kind = GnmBackendKind::Metal4;
            c.why = "default: Metal 4 (the GPU supports MTLGPUFamilyMetal4)";
        }
        return c;
    }
    if (!strcmp(env, "3")) {
        c.ok = true;
        c.why = "PS4_GNM_METAL=3";
        return c;
    }
    if (strcmp(env, "4")) {
        c.why = std::string("PS4_GNM_METAL must be 3 or 4 (it is \"") + env + "\")";
        return c;
    }
    if (!device_has_metal4) {
        c.why = "PS4_GNM_METAL=4: this GPU does not support MTLGPUFamilyMetal4; use PS4_GNM_METAL=3";
        return c;
    }
    if (!metal4_caps) {
        c.why = "PS4_GNM_METAL=4: the Metal 4 backend is not implemented in this build; use PS4_GNM_METAL=3";
        return c;
    }
    if (!(metal4_caps & kGnmCapDraws) && !only_clears) {
        c.why = "PS4_GNM_METAL=4: this build's Metal 4 backend lacks " + Missing(metal4_caps) +
                "; set PS4_GNM_MTL4_ONLY_CLEARS=1 to run it with draws skipped (debug)";
        return c;
    }
    c.ok = true;
    c.kind = GnmBackendKind::Metal4;
    c.why = only_clears ? "PS4_GNM_METAL=4 with PS4_GNM_MTL4_ONLY_CLEARS=1 (draws skipped)" : "PS4_GNM_METAL=4";
    return c;
}

} // namespace ps4gnm
```

`tools/gnm_replay/build.sh:20`: add `"$G/ps4_gnm_backend.mm"` to the `for f in …` list (after `ps4_gnm_kernel_compile.mm`). (`tests/host/build_runtime_test.sh` and the game build walk `pkg/runtime` and pick it up.)

`tests/host/run_host_tests.sh`, after the `gnm_clear_color_test` run:

```bash
# Backend selection (ps4_gnm_backend.h): default, explicit choices, every refusal of "4" says why.
clang++ -std=c++17 -fobjc-arc -Wall -Werror -I "$G" "$R/tests/host/gnm_backend_select_test.mm" "$G/ps4_gnm_backend.mm" \
  -framework Metal -framework Foundation -o "$T/gnm_backend_select_test"
"$T/gnm_backend_select_test"
```

`docs/metal4-backend.md` (first version; later tasks add sections):

```markdown
# Renderer backends: Metal 3 and Metal 4

The GNM renderer (pkg/runtime/modules/libSceGnmDriver/ps4_gnm_draw.mm) encodes through a
`GnmBackend` (ps4_gnm_backend.h). Two backends are built into every `.app`:

- **Metal 3** (`ps4_gnm_backend_metal3.mm`): `MTLCommandQueue`, Metal's hazard tracking between
  encoders, `useResource` for buffers reached through argument buffers.
- **Metal 4** (`ps4_gnm_backend_metal4.mm`): `MTL4CommandQueue`, a command allocator ring reset
  only after its seq completed, a timeline `MTLSharedEvent` (= the renderer's commit seq),
  argument tables, a bytes arena instead of `setBytes`, a barrier at each encoder start, copies
  on compute encoders, residency sets (`GnmResidency`).

Shared by both: the command processor, register decoding, `BindStage`, the texture and buffer
caches, the guest memory windows, hazard logic, the guest memory dispatch protocol, shader
translation and caches, Metal 3 pipeline states and the pipeline / binary archives, capture and
replay. The presenter (`ps4_metal_screen.m`) and the guest memory re-run queue (`queue2`) stay on
Metal 3; shared events order work across the queues.

## Selection

`PS4_GNM_METAL=3|4`, read once by `ps4draw::Init` (`ChooseBackend`). The chosen backend is
logged: `[gnm-draw] backend metal3 (<reason>)`. Unset: Metal 3. An explicit `4` that cannot be
honoured (no `MTLGPUFamilyMetal4`, or a backend that does not implement what the run needs) is a
startup error naming the reason; it never falls back silently.

## Debug variables

| variable | backend | effect |
|---|---|---|
| `PS4_GNM_ENCODER_STATUS=1` | Metal 3 only | per-encoder fault attribution of failed command buffers |
| `PS4_GNM_COMMIT_EACH=1` | both | one command buffer per draw or dispatch (bisecting a fault or hang; the Metal 4 tool for what ENCODER_STATUS does on Metal 3) |
```

- [ ] **Step 4: Run it to verify it passes**

```bash
clang++ -std=c++17 -fobjc-arc -Wall -Werror -I $G tests/host/gnm_backend_select_test.mm $G/ps4_gnm_backend.mm \
  -framework Metal -framework Foundation -o $T/s && $T/s
```
Expected: `gnm_backend_select_test: PASS`.

- [ ] **Step 5: Host suite, R-check, commit**

Replay tool build tag `t11`, R-check `t11 3` (`cmp=0`; nothing in the renderer changed yet, this proves the tool build with the new file), host suite tag `t11` (`host=0`).

```bash
git add $G/ps4_gnm_backend.h $G/ps4_gnm_backend.mm tests/host/gnm_backend_select_test.mm tests/host/run_host_tests.sh tools/gnm_replay/build.sh docs/metal4-backend.md
git commit -m "gnm: GnmBackend interface and backend selection (PS4_GNM_METAL)

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

### Task 1.2: `Metal3Backend`; command-buffer lifecycle and the seq timeline behind it

**Files:**
- Create: `$G/ps4_gnm_backend_metal3.h`, `$G/ps4_gnm_backend_metal3.mm`
- Modify: `$G/ps4_gnm_draw.mm`: `State` (`:583-777`: fields `queue`, `cmd`, `upload_cmd`, `inflight`, `inflight_logs`), `EnsureCmd` (`:1765-1780`), `LogEncoderStatus` (`:1699-1707`), `ThrottleCommandBuffers` constant (`:1718`), `GmWaitForCommitted` (`:1760-1763`), `Commit` (`:1812-1919`), `WaitAll` (`:1925-1991`), `SampledTexture` (`:5425-5434`), `Init` (`:6351-6352`, `:6359`), `AfterGpuImpl` (`:6663-6670`), `CommitEachForDebug` (`:7050`), every remaining `S.cmd` / `S.upload_cmd` use (`:4808-4820`, `4866-4876`, `4915-4927`, `4993-4998`, `5064-5065`, `5124-5129`, `5279-5280`, `5598-5620`, `5663-5710`, `5743-5747`, `6049-6059`, `6575-6576`, `6709-6711`, `7128-7129`, `8130-8132`, `8530-8531`, `8848-8866`)
- Modify: `tools/gnm_replay/build.sh:20` (compile `ps4_gnm_backend_metal3.mm`)

**Interfaces:**
- Consumes: `ps4_gnm_backend.h` (Task 1.1).
- Produces:
  - `ps4gnm::Metal3Backend final : public GnmBackend` implementing every method (`Caps() == kGnmCapAll`), plus, for Tasks 1.3–1.8 only: `id<MTLCommandBuffer> LegacyCmd(GnmCmdTarget t) const;`, `id<MTLRenderCommandEncoder> LegacyRender() const;`, `id<MTLComputeCommandEncoder> LegacyCompute() const;` (the current target's), `void LegacyAdoptRender(id<MTLRenderCommandEncoder> e);`, `void LegacyAdoptCompute(id<MTLComputeCommandEncoder> e);` (an encoder the renderer created from `LegacyCmd` becomes the backend's open encoder, so `OpenEncoder()`/`EndEncoder()` see it; used by Task 1.2's untouched `BeginPass`/`ComputeEncoder` until Task 1.3).
  - In `ps4_gnm_draw.mm`: `State::be` (`std::unique_ptr<GnmBackend>`), `State::cmd_index` (`uint64_t`, the `gnm-<n>` label number of the open main command buffer), `struct InflightLog { uint64_t seq, cmd_index; std::shared_ptr<WorkLog> log; };` and `std::deque<InflightLog> State::inflight_logs`, `struct CommitDone` and `void CommitDoneFn(void* ctx, const GnmCompletion& c)`, `Metal3Backend& M3Legacy()` (Tasks 1.2–1.8).

`$G/ps4_gnm_backend_metal3.h`:

```objc
// SPDX-License-Identifier: GPL-2.0-or-later
// PS4Recomp - the Metal 3 renderer backend (ps4_gnm_backend.h): MTLCommandQueue, one
// MTLCommandBuffer per seq (plus the upload one), Metal's hazard tracking between encoders,
// setBytes, useResource. The renderer's Metal 3 calls, moved here unchanged.
#ifndef PS4_GNM_BACKEND_METAL3_H
#define PS4_GNM_BACKEND_METAL3_H

#include <deque>
#include <mutex>
#include <utility>

#include "ps4_gnm_backend.h"

namespace ps4gnm {

class Metal3Backend final : public GnmBackend {
public:
    Metal3Backend();
    GnmBackendKind Kind() const override { return GnmBackendKind::Metal3; }
    uint32_t Caps() const override { return kGnmCapAll; }
    bool Init(id<MTLDevice> dev, std::string* why) override;
    id<MTLDevice> Device() const override { return dev_; }
    id<MTLCommandQueue> SideQueue() const override { return queue_; }

    void BeginCmd(GnmCmdTarget t, NSString* label, bool encoder_status) override;
    bool CmdOpen(GnmCmdTarget t) const override { return t_[(int)t].cmd != nil; }
    void UseTarget(GnmCmdTarget t) override { cur_ = t; }
    GnmCmdTarget Target() const override { return cur_; }
    void CommitUpload() override;
    void Commit(uint64_t seq, GnmCompletionFn done, void* ctx) override;
    uint64_t CompletedSeq() const override;
    // The queue was made with kGnmMaxCommandBuffers: BeginCmd itself blocks while that many are
    // uncompleted (Metal's own limit), so there is nothing to wait for here.
    bool WaitForRoom(uint64_t, uint64_t, double) override { return true; }
    void QueueSignal(id<MTLSharedEvent> ev, uint64_t value) override;
    void QueueWait(id<MTLSharedEvent> ev, uint64_t value) override;

    GnmEncoder OpenEncoder() const override;
    uint64_t EncoderSerial() const override { return serial_; }
    bool BeginRender(const GnmPassDesc& d) override;
    void BeginCompute(bool serial) override;
    void BeginCopies() override;
    void EndEncoder() override;
    void SetEncoderLabel(NSString* label) override;
    void Barrier(uint32_t after, uint32_t before, uint8_t scope) override;

    void SetRenderPipeline(id<MTLRenderPipelineState> p) override { [Cur().renc setRenderPipelineState:p]; }
    void SetDepthStencil(id<MTLDepthStencilState> d) override { [Cur().renc setDepthStencilState:d]; }
    void SetFixed(const GnmFixedState& f, uint32_t changed) override;
    void SetComputePipeline(id<MTLComputePipelineState> p) override { [Cur().cenc setComputePipelineState:p]; }

    void Draw(const GnmDraw& d) override;
    void Dispatch(MTLSize groups, MTLSize tpt) override { [Cur().cenc dispatchThreadgroups:groups threadsPerThreadgroup:tpt]; }
    void DispatchThreads(MTLSize threads, MTLSize tpt) override { [Cur().cenc dispatchThreads:threads threadsPerThreadgroup:tpt]; }
    void DispatchIndirect(id<MTLBuffer> args, uint64_t off, MTLSize tpt) override {
        [Cur().cenc dispatchThreadgroupsWithIndirectBuffer:args indirectBufferOffset:off threadsPerThreadgroup:tpt];
    }
    void CopyBuffer(id<MTLBuffer> src, uint64_t src_off, id<MTLBuffer> dst, uint64_t dst_off, uint64_t n) override {
        [Cur().blit copyFromBuffer:src sourceOffset:src_off toBuffer:dst destinationOffset:dst_off size:n];
    }
    void FillBuffer(id<MTLBuffer> dst, uint64_t off, uint64_t n, uint8_t value) override {
        [Cur().blit fillBuffer:dst range:NSMakeRange(off, n) value:value];
    }
    void CopyTexture(id<MTLTexture> src, id<MTLTexture> dst) override { [Cur().blit copyFromTexture:src toTexture:dst]; }
    void CopyTextureRegion(id<MTLTexture> src, uint32_t src_slice, uint32_t src_level, MTLOrigin src_origin, MTLSize size,
                           id<MTLTexture> dst, uint32_t dst_slice, uint32_t dst_level, MTLOrigin dst_origin) override;
    void CopyBufferToTexture(id<MTLBuffer> src, uint64_t src_off, uint64_t row_bytes, uint64_t image_bytes, MTLSize size,
                             id<MTLTexture> dst, uint32_t slice, uint32_t level, MTLOrigin origin) override;

    void MakeResident(id<MTLAllocation>, GnmResidencyClass) override {} // bound resources are resident by themselves
    void Evict(id<MTLAllocation>, uint64_t) override {}
    bool IsResident(id<MTLAllocation>) const override { return true; }
    GnmBackendStats Stats() const override;

    // Tasks 1.2–1.8 only (deleted by Task 1.9): the renderer sites not moved yet.
    id<MTLCommandBuffer> LegacyCmd(GnmCmdTarget t) const { return t_[(int)t].cmd; }
    id<MTLRenderCommandEncoder> LegacyRender() const { return t_[(int)cur_].renc; }
    id<MTLComputeCommandEncoder> LegacyCompute() const { return t_[(int)cur_].cenc; }
    void LegacyAdoptRender(id<MTLRenderCommandEncoder> e) { Cur().renc = e; ++serial_; }
    void LegacyAdoptCompute(id<MTLComputeCommandEncoder> e) { Cur().cenc = e; ++serial_; }

private:
    struct Target {
        id<MTLCommandBuffer> cmd = nil;
        id<MTLRenderCommandEncoder> renc = nil;
        id<MTLComputeCommandEncoder> cenc = nil;
        id<MTLBlitCommandEncoder> blit = nil;
    };
    Target& Cur() { return t_[(int)cur_]; }
    const Target& Cur() const { return t_[(int)cur_]; }
    static void OpBuffer(GnmBackend* b, GnmStage st, uint32_t slot, __unsafe_unretained id<MTLBuffer> buf, uint64_t off);
    static void OpBufferOffset(GnmBackend* b, GnmStage st, uint32_t slot, uint64_t off);
    static void OpBytes(GnmBackend* b, GnmStage st, uint32_t slot, const void* p, size_t n);
    static void OpTexture(GnmBackend* b, GnmStage st, uint32_t slot, __unsafe_unretained id<MTLTexture> t);
    static void OpSampler(GnmBackend* b, GnmStage st, uint32_t slot, __unsafe_unretained id<MTLSamplerState> s);
    static void OpUse(GnmBackend* b, GnmStage st, __unsafe_unretained id<MTLBuffer> buf, bool written);

    id<MTLDevice> dev_ = nil;
    id<MTLCommandQueue> queue_ = nil;
    Target t_[2];
    GnmCmdTarget cur_ = GnmCmdTarget::Main;
    uint64_t serial_ = 0;
    mutable std::mutex inflight_mu_;
    mutable std::deque<std::pair<uint64_t, id<MTLCommandBuffer>>> inflight_; // committed, by seq
    mutable uint64_t completed_ = 0;
    std::atomic<uint64_t> commits_{0};
};

} // namespace ps4gnm

#endif // PS4_GNM_BACKEND_METAL3_H
```

(add `#include <atomic>` to the includes).

- [ ] **Step 1: Write `ps4_gnm_backend_metal3.mm` (every method; the Metal calls are those of the renderer sites named in the comments)**

```objc
// SPDX-License-Identifier: GPL-2.0-or-later
// PS4Recomp - the Metal 3 renderer backend (ps4_gnm_backend_metal3.h). Each method is the Metal 3
// code of the renderer site named in its comment (ps4_gnm_draw.mm before the backend seam).
#include "ps4_gnm_backend_metal3.h"

#include <stdio.h>

namespace ps4gnm {

Metal3Backend::Metal3Backend() {
    ops_.buffer = OpBuffer;
    ops_.buffer_offset = OpBufferOffset;
    ops_.bytes = OpBytes;
    ops_.texture = OpTexture;
    ops_.sampler = OpSampler;
    ops_.use = OpUse;
}

std::unique_ptr<GnmBackend> MakeMetal3Backend() { return std::make_unique<Metal3Backend>(); }

// Init: S.queue = [S.dev newCommandQueueWithMaxCommandBufferCount:kMaxCommandBuffers]; label "gnm"
bool Metal3Backend::Init(id<MTLDevice> dev, std::string* why) {
    dev_ = dev;
    queue_ = [dev newCommandQueueWithMaxCommandBufferCount:kGnmMaxCommandBuffers];
    if (!queue_) {
        if (why) *why = "newCommandQueueWithMaxCommandBufferCount failed";
        return false;
    }
    queue_.label = @"gnm";
    return true;
}

// EnsureCmd / SampledTexture (S.upload_cmd): commandBuffer or commandBufferWithDescriptor with
// MTLCommandBufferErrorOptionEncoderExecutionStatus; the upload command buffer logs its failure.
void Metal3Backend::BeginCmd(GnmCmdTarget t, NSString* label, bool encoder_status) {
    Target& x = t_[(int)t];
    if (encoder_status) {
        MTLCommandBufferDescriptor* d = [MTLCommandBufferDescriptor new];
        d.errorOptions = MTLCommandBufferErrorOptionEncoderExecutionStatus;
        x.cmd = [queue_ commandBufferWithDescriptor:d];
    } else {
        x.cmd = [queue_ commandBuffer];
    }
    x.cmd.label = label;
    if (t == GnmCmdTarget::Upload)
        [x.cmd addCompletedHandler:^(id<MTLCommandBuffer> done) {
            if (done.status == MTLCommandBufferStatusError)
                fprintf(stderr, "[gnm-draw] texture upload command buffer failed: %s\n",
                        done.error.localizedDescription.UTF8String);
        }];
}

// Commit: [S.upload_cmd commit] before S.cmd (same queue: the uploads run first)
void Metal3Backend::CommitUpload() {
    Target& u = t_[(int)GnmCmdTarget::Upload];
    if (!u.cmd) return;
    [u.cmd commit];
    u.cmd = nil;
    commits_.fetch_add(1, std::memory_order_relaxed);
}

// Commit: addCompletedHandler (GPU times, status) + commit; S.inflight
void Metal3Backend::Commit(uint64_t seq, GnmCompletionFn done, void* ctx) {
    CommitUpload();
    Target& m = t_[(int)GnmCmdTarget::Main];
    id<MTLCommandBuffer> cb = m.cmd;
    m.cmd = nil;
    [cb addCompletedHandler:^(id<MTLCommandBuffer> c) {
        GnmCompletion r;
        r.seq = seq;
        r.failed = c.status == MTLCommandBufferStatusError;
        r.gpu_start = c.GPUStartTime;
        r.gpu_end = c.GPUEndTime;
        r.error = c.error;
        done(ctx, r);
    }];
    [cb commit];
    commits_.fetch_add(1, std::memory_order_relaxed);
    std::lock_guard<std::mutex> lk(inflight_mu_);
    inflight_.emplace_back(seq, cb);
}

// WaitAll's status walk over S.inflight: the longest completed prefix of the committed seqs
uint64_t Metal3Backend::CompletedSeq() const {
    std::lock_guard<std::mutex> lk(inflight_mu_);
    while (!inflight_.empty() && inflight_.front().second.status >= MTLCommandBufferStatusCompleted) {
        completed_ = inflight_.front().first;
        inflight_.pop_front();
    }
    return completed_;
}

// GmCloseChain / DebugStallGpu / GmWaitForCommitted: encodeSignalEvent / encodeWaitForEvent
void Metal3Backend::QueueSignal(id<MTLSharedEvent> ev, uint64_t value) { [Cur().cmd encodeSignalEvent:ev value:value]; }
void Metal3Backend::QueueWait(id<MTLSharedEvent> ev, uint64_t value) { [Cur().cmd encodeWaitForEvent:ev value:value]; }

GnmEncoder Metal3Backend::OpenEncoder() const {
    const Target& x = Cur();
    return x.renc ? GnmEncoder::Render : x.cenc ? GnmEncoder::Compute : x.blit ? GnmEncoder::Copy : GnmEncoder::None;
}

static MTLLoadAction LoadOf(GnmLoad l) {
    return l == GnmLoad::Clear ? MTLLoadActionClear : l == GnmLoad::DontCare ? MTLLoadActionDontCare : MTLLoadActionLoad;
}
static MTLStoreAction StoreOf(GnmStore s) {
    return s == GnmStore::MultisampleResolve ? MTLStoreActionMultisampleResolve : MTLStoreActionStore;
}

// BeginPass (:5664-5710) and every helper pass's MTLRenderPassDescriptor
bool Metal3Backend::BeginRender(const GnmPassDesc& d) {
    Target& x = Cur();
    MTLRenderPassDescriptor* rp = [MTLRenderPassDescriptor renderPassDescriptor];
    for (int i = 0; i < 8; ++i) {
        const GnmAttachment& a = d.color[i];
        if (!a.tex) continue;
        MTLRenderPassColorAttachmentDescriptor* c = rp.colorAttachments[i];
        c.texture = a.tex;
        c.slice = a.slice;
        c.loadAction = LoadOf(a.load);
        if (a.load == GnmLoad::Clear) c.clearColor = d.clear_color[i];
        c.storeAction = StoreOf(a.store);
        if (a.store == GnmStore::MultisampleResolve) c.resolveTexture = a.resolve;
    }
    if (d.depth.tex) {
        rp.depthAttachment.texture = d.depth.tex;
        rp.depthAttachment.slice = d.depth.slice;
        rp.depthAttachment.loadAction = LoadOf(d.depth.load);
        if (d.depth.load == GnmLoad::Clear) rp.depthAttachment.clearDepth = d.clear_depth;
        rp.depthAttachment.storeAction = StoreOf(d.depth.store);
    }
    if (d.stencil.tex) {
        rp.stencilAttachment.texture = d.stencil.tex;
        rp.stencilAttachment.slice = d.stencil.slice;
        rp.stencilAttachment.loadAction = LoadOf(d.stencil.load);
        if (d.stencil.load == GnmLoad::Clear) rp.stencilAttachment.clearStencil = d.clear_stencil;
        rp.stencilAttachment.storeAction = StoreOf(d.stencil.store);
    }
    if (d.width) rp.renderTargetWidth = d.width;
    if (d.height) rp.renderTargetHeight = d.height;
    if (d.default_samples) rp.defaultRasterSampleCount = d.default_samples;
    if (d.num_sample_positions) [rp setSamplePositions:d.sample_positions count:d.num_sample_positions];
    x.renc = [x.cmd renderCommandEncoderWithDescriptor:rp];
    if (!x.renc) return false;
    if (d.label) x.renc.label = d.label;
    ++serial_;
    return true;
}

// ComputeEncoder (:5745-5747) and EncodeGpuUploadAt's side encoder (:5258)
void Metal3Backend::BeginCompute(bool serial) {
    Target& x = Cur();
    x.cenc = serial ? [x.cmd computeCommandEncoder] : [x.cmd computeCommandEncoderWithDispatchType:MTLDispatchTypeConcurrent];
    ++serial_;
}

void Metal3Backend::BeginCopies() {
    Target& x = Cur();
    x.blit = [x.cmd blitCommandEncoder];
    ++serial_;
}

// EndEncoders (:1671-1679) and every [e endEncoding] / [bl endEncoding]
void Metal3Backend::EndEncoder() {
    Target& x = Cur();
    if (x.renc) [x.renc endEncoding], x.renc = nil;
    if (x.cenc) [x.cenc endEncoding], x.cenc = nil;
    if (x.blit) [x.blit endEncoding], x.blit = nil;
}

void Metal3Backend::SetEncoderLabel(NSString* label) {
    Target& x = Cur();
    if (x.renc) x.renc.label = label;
    else if (x.cenc) x.cenc.label = label;
    else if (x.blit) x.blit.label = label;
}

static MTLRenderStages RenderStagesOf(uint32_t s) {
    MTLRenderStages r = 0;
    if (s & kGnmStageVertex) r |= MTLRenderStageVertex;
    if (s & kGnmStageFragment) r |= MTLRenderStageFragment;
    return r;
}

// ComputeBarrierImpl (:6538), the guest memory chain (:7861, :7993), the upload detile (:5261):
// memoryBarrierWithScope on the compute encoder; ps4gnm_rect::Encode: the render-stage form
void Metal3Backend::Barrier(uint32_t after, uint32_t before, uint8_t scope) {
    Target& x = Cur();
    if (x.cenc) [x.cenc memoryBarrierWithScope:(MTLBarrierScope)scope];
    else if (x.renc)
        [x.renc memoryBarrierWithScope:(MTLBarrierScope)scope afterStages:RenderStagesOf(after)
                          beforeStages:RenderStagesOf(before)];
}

// DrawEncode (:7473-7483)
void Metal3Backend::SetFixed(const GnmFixedState& f, uint32_t changed) {
    id<MTLRenderCommandEncoder> e = Cur().renc;
    if (changed & kGnmFixedStencilRef) [e setStencilFrontReferenceValue:f.stencil_ref[0] backReferenceValue:f.stencil_ref[1]];
    if (changed & kGnmFixedViewport) [e setViewport:f.vp];
    if (changed & kGnmFixedScissor) [e setScissorRect:f.sc];
    if (changed & kGnmFixedCull) [e setCullMode:(MTLCullMode)f.cull];
    if (changed & kGnmFixedWinding) [e setFrontFacingWinding:(MTLWinding)f.winding];
    if (changed & kGnmFixedFill) [e setTriangleFillMode:(MTLTriangleFillMode)f.fill];
    if (changed & kGnmFixedClip) [e setDepthClipMode:(MTLDepthClipMode)f.clip];
    if (changed & kGnmFixedBias) [e setDepthBias:f.bias[0] slopeScale:f.bias[1] clamp:f.bias[2]];
    if (changed & kGnmFixedBlend) [e setBlendColorRed:f.blend[0] green:f.blend[1] blue:f.blend[2] alpha:f.blend[3]];
}

// DrawEncode (:7522-7550), ps4gnm_rect::Encode, the helper passes' full-screen triangles
void Metal3Backend::Draw(const GnmDraw& d) {
    id<MTLRenderCommandEncoder> e = Cur().renc;
    switch (d.kind) {
    case GnmDrawKind::Direct:
        if (d.instances == 1 && d.base_instance == 0)
            [e drawPrimitives:d.prim vertexStart:d.vertex_start vertexCount:d.count];
        else
            [e drawPrimitives:d.prim vertexStart:d.vertex_start vertexCount:d.count instanceCount:d.instances
                 baseInstance:d.base_instance];
        break;
    case GnmDrawKind::Indexed:
        [e drawIndexedPrimitives:d.prim indexCount:d.count indexType:d.index_type indexBuffer:d.index_buffer
               indexBufferOffset:d.index_offset instanceCount:d.instances baseVertex:d.base_vertex
                    baseInstance:d.base_instance];
        break;
    case GnmDrawKind::Indirect:
        [e drawPrimitives:d.prim indirectBuffer:d.indirect_buffer indirectBufferOffset:d.indirect_offset];
        break;
    case GnmDrawKind::IndexedIndirect:
        [e drawIndexedPrimitives:d.prim indexType:d.index_type indexBuffer:d.index_buffer indexBufferOffset:d.index_offset
                  indirectBuffer:d.indirect_buffer indirectBufferOffset:d.indirect_offset];
        break;
    }
}

// MipChainFor (:5070), DrawEncode's grown depth array (:7131), ResolvePass (:6060)
void Metal3Backend::CopyTextureRegion(id<MTLTexture> src, uint32_t src_slice, uint32_t src_level, MTLOrigin src_origin,
                                      MTLSize size, id<MTLTexture> dst, uint32_t dst_slice, uint32_t dst_level,
                                      MTLOrigin dst_origin) {
    [Cur().blit copyFromTexture:src sourceSlice:src_slice sourceLevel:src_level sourceOrigin:src_origin sourceSize:size
                      toTexture:dst destinationSlice:dst_slice destinationLevel:dst_level destinationOrigin:dst_origin];
}

// EncodeGpuUploadAt (:5292)
void Metal3Backend::CopyBufferToTexture(id<MTLBuffer> src, uint64_t src_off, uint64_t row_bytes, uint64_t image_bytes,
                                        MTLSize size, id<MTLTexture> dst, uint32_t slice, uint32_t level, MTLOrigin origin) {
    [Cur().blit copyFromBuffer:src sourceOffset:src_off sourceBytesPerRow:row_bytes sourceBytesPerImage:image_bytes
                    sourceSize:size toTexture:dst destinationSlice:slice destinationLevel:level destinationOrigin:origin];
}

GnmBackendStats Metal3Backend::Stats() const {
    GnmBackendStats s;
    s.commits = commits_.load(std::memory_order_relaxed);
    return s;
}

// ---- Binder (:2903-2965): set*Buffer / set*BufferOffset / set*Bytes / set*Texture / set*SamplerState / useResource
void Metal3Backend::OpBuffer(GnmBackend* b, GnmStage st, uint32_t slot, __unsafe_unretained id<MTLBuffer> buf, uint64_t off) {
    Target& x = static_cast<Metal3Backend*>(b)->Cur();
    if (st == GnmStage::Vertex) [x.renc setVertexBuffer:buf offset:off atIndex:slot];
    else if (st == GnmStage::Fragment) [x.renc setFragmentBuffer:buf offset:off atIndex:slot];
    else [x.cenc setBuffer:buf offset:off atIndex:slot];
}
void Metal3Backend::OpBufferOffset(GnmBackend* b, GnmStage st, uint32_t slot, uint64_t off) {
    Target& x = static_cast<Metal3Backend*>(b)->Cur();
    if (st == GnmStage::Vertex) [x.renc setVertexBufferOffset:off atIndex:slot];
    else if (st == GnmStage::Fragment) [x.renc setFragmentBufferOffset:off atIndex:slot];
    else [x.cenc setBufferOffset:off atIndex:slot];
}
void Metal3Backend::OpBytes(GnmBackend* b, GnmStage st, uint32_t slot, const void* p, size_t n) {
    Target& x = static_cast<Metal3Backend*>(b)->Cur();
    if (st == GnmStage::Vertex) [x.renc setVertexBytes:p length:n atIndex:slot];
    else if (st == GnmStage::Fragment) [x.renc setFragmentBytes:p length:n atIndex:slot];
    else [x.cenc setBytes:p length:n atIndex:slot];
}
void Metal3Backend::OpTexture(GnmBackend* b, GnmStage st, uint32_t slot, __unsafe_unretained id<MTLTexture> t) {
    Target& x = static_cast<Metal3Backend*>(b)->Cur();
    if (st == GnmStage::Vertex) [x.renc setVertexTexture:t atIndex:slot];
    else if (st == GnmStage::Fragment) [x.renc setFragmentTexture:t atIndex:slot];
    else [x.cenc setTexture:t atIndex:slot];
}
void Metal3Backend::OpSampler(GnmBackend* b, GnmStage st, uint32_t slot, __unsafe_unretained id<MTLSamplerState> s) {
    Target& x = static_cast<Metal3Backend*>(b)->Cur();
    if (st == GnmStage::Vertex) [x.renc setVertexSamplerState:s atIndex:slot];
    else if (st == GnmStage::Fragment) [x.renc setFragmentSamplerState:s atIndex:slot];
    else [x.cenc setSamplerState:s atIndex:slot];
}
void Metal3Backend::OpUse(GnmBackend* b, GnmStage st, __unsafe_unretained id<MTLBuffer> buf, bool written) {
    Target& x = static_cast<Metal3Backend*>(b)->Cur();
    const MTLResourceUsage u = written ? (MTLResourceUsageRead | MTLResourceUsageWrite) : MTLResourceUsageRead;
    if (st == GnmStage::Compute) [x.cenc useResource:buf usage:u];
    else [x.renc useResource:buf usage:u stages:(st == GnmStage::Vertex ? MTLRenderStageVertex : MTLRenderStageFragment)];
}

} // namespace ps4gnm
```

Build check (no test can fail yet, the class is not used): `clang++ -std=c++17 -fobjc-arc -Wall -Werror -I $G -c $G/ps4_gnm_backend_metal3.mm -o $T/m3.o` → no output.

- [ ] **Step 2: Write the lifecycle part of the renderer change (draw.mm)**

Add `#include "ps4_gnm_backend.h"` and `#include "ps4_gnm_backend_metal3.h"` after `#include "ps4_gnm_kernel_compile.h"` (`:69`).

`State` (`:583`): delete `id<MTLCommandQueue> queue = nil;` (`:589`), `id<MTLCommandBuffer> cmd = nil;` (`:598`), `id<MTLCommandBuffer> upload_cmd = nil;` (`:599`), `std::vector<id<MTLCommandBuffer>> inflight;` (`:604`), and replace `std::unordered_map<void*, std::shared_ptr<WorkLog>> inflight_logs;` (`:758`) by `std::deque<InflightLog> inflight_logs; // committed, not known complete (pruned at commits, cleared by WaitAll)`. Add at the top of `State`:

```cpp
    std::unique_ptr<GnmBackend> be; // the backend chosen by Init (ps4_gnm_backend.h)
    uint64_t cmd_index = 0;         // label number of the open main command buffer ("gnm-<n>")
```

Before `struct State` add:

```cpp
struct InflightLog {
    uint64_t seq, cmd_index;
    std::shared_ptr<WorkLog> log;
};
```

After `State S;` add (removed by Task 1.9):

```cpp
// Tasks 1.2–1.8 of the backend seam (docs/superpowers/plans/2026-10-22-metal4-backend.md): the
// sites not moved behind GnmBackend yet reach the Metal 3 objects here. Only Metal3Backend exists
// while they do.
Metal3Backend& M3Legacy() { return *static_cast<Metal3Backend*>(S.be.get()); }
```

`kMaxCommandBuffers` (`:1718`): `constexpr uint64_t kMaxCommandBuffers = kGnmMaxCommandBuffers;`

`LogEncoderStatus` (`:1699`): take the error instead of the command buffer:

```cpp
void LogEncoderStatus(NSError* error) {
    NSArray* infos = error.userInfo[MTLCommandBufferEncoderInfoErrorKey];
    …unchanged loop…
}
```

`GmWaitForCommitted` (`:1760`) becomes target-based (Task 1.7 replaces the send by `QueueWait`):

```cpp
void GmWaitForCommitted(GnmCmdTarget t) {
    if (!g_gms.committed || GmResolved() >= g_gms.committed) return;
    [M3Legacy().LegacyCmd(t) encodeWaitForEvent:g_gms.ev value:2 * g_gms.committed];
}
```

`EnsureCmd` (`:1765-1780`):

```cpp
void EnsureCmd() {
    if (S.be->CmdOpen(GnmCmdTarget::Main)) return;
    ThrottleCommandBuffers();
    S.cmd_index = S.n_cmdbufs++;
    S.be->BeginCmd(GnmCmdTarget::Main, [NSString stringWithFormat:@"gnm-%llu", (unsigned long long)S.cmd_index],
                   EncoderStatusEnabled());
    g_cmd_open.store(true, std::memory_order_release);
    S.cmd_log = std::make_shared<WorkLog>();
    GmWaitForCommitted(GnmCmdTarget::Main);
}
```

Before `Commit` (`:1812`), the completion record that replaces the handler block's captures:

```cpp
// What the completion of one seq needs (the former addCompletedHandler block's captures).
struct CommitDone {
    uint64_t seq = 0, cmd_index = 0;
    std::shared_ptr<std::vector<GpuWrite>> written;
    TextureCache* tex_cache = nullptr;
    std::shared_ptr<WorkLog> log;
    std::shared_ptr<std::vector<std::shared_ptr<GmTicket>>> tickets;
    std::vector<id<MTLBuffer>> chunks; // upload arena chunks, recycled now
    UploadArena* arena = nullptr;
};

void CommitDoneFn(void* p, const GnmCompletion& c) {
    std::unique_ptr<CommitDone> d(static_cast<CommitDone*>(p));
    if (d->written && d->tex_cache) d->tex_cache->InvalidateWrites(*d->written);
    {
        // GPU busy time: union of the command buffers' execution intervals (they may overlap)
        std::lock_guard<std::mutex> lk(S.gpu_time_mu);
        const double from = std::max(c.gpu_start, S.gpu_last_end);
        if (c.gpu_end > from) S.gpu_ns.fetch_add((uint64_t)((c.gpu_end - from) * 1e9), std::memory_order_relaxed);
        S.gpu_last_end = std::max(S.gpu_last_end, c.gpu_end);
    }
    RunFences(d->seq);
    if (c.failed) {
        fprintf(stderr, "[gnm-draw] command buffer gnm-%llu failed: %s\n", (unsigned long long)d->cmd_index,
                c.error.localizedDescription.UTF8String);
        if (EncoderStatusEnabled()) LogEncoderStatus(c.error);
        if (d->log) d->log->Print("work", EncoderStatusEnabled() ? WorkLog::kAll : 12);
        // its guest memory dispatches may not have signaled: they count as skipped
        if (d->tickets) GmCommandBufferFailed(*d->tickets);
    }
    GmNotify();
    std::lock_guard<std::mutex> lk(d->arena->free_mu);
    for (auto& b : d->chunks)
        if (b.length == UploadArena::kChunk && d->arena->free_list.size() < 16) d->arena->free_list.push_back(b);
}
```

`Commit` (`:1812-1919`) becomes (unchanged lines kept as they are, shown with `…`):

```cpp
void Commit() {
    EndEncoders();
    …g_mem.tick, SweepGuestWindows, EvictTextures, sweep_ns: unchanged (:1814-1821)…
    if (!S.be->CmdOpen(GnmCmdTarget::Main)) {
        S.be->CommitUpload(); // texture copies for later work: they run before the next seq (same queue)
        if (S.tex) S.tex->SetUse(S.committed_seq + 1, g_mem.tick);
        return;
    }
    S.cmd_start_epoch = S.write_epoch + 1;
    g_cmd_open.store(false, std::memory_order_release);
    auto* done = new CommitDone;
    done->cmd_index = S.cmd_index;
    done->arena = &S.arena;
    done->chunks.reserve(S.arena.cur.size());
    for (auto& c : S.arena.cur) done->chunks.push_back(c.buf);
    S.arena.cur.clear();
    done->log = std::move(S.cmd_log);
    S.cmd_log.reset();
    uint64_t seq;
    {
        std::lock_guard<std::mutex> lk(S.fence_mu);
        seq = ++S.committed_seq;
    }
    done->seq = seq;
    if (S.tex) S.tex->SetUse(seq + 1, g_mem.tick);
    if (!S.gpu_written.empty()) {
        done->written = std::make_shared<std::vector<GpuWrite>>(S.gpu_written);
        S.inflight_written.push_back({seq, std::move(S.gpu_written)});
        S.gpu_written.clear();
        S.table_written.push_back({seq, done->written});
    }
    PruneTableWrites();
    done->tex_cache = S.tex;
    if (!g_gms.cmd_tickets.empty()) {
        done->tickets = std::make_shared<std::vector<std::shared_ptr<GmTicket>>>(std::move(g_gms.cmd_tickets));
        g_gms.cmd_tickets.clear();
    }
    std::shared_ptr<WorkLog> log = done->log;
    const uint64_t cmd_index = S.cmd_index;
    S.be->Commit(seq, CommitDoneFn, done); // done is deleted by CommitDoneFn
    g_gms.committed = g_gms.encoded;
    S.n_commits++;
    static const long hang_ms = getenv("PS4_GNM_HANG_REPORT_MS") ? atol(getenv("PS4_GNM_HANG_REPORT_MS")) : 0;
    if (hang_ms > 0) {
        GnmBackend* be = S.be.get();
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, hang_ms * NSEC_PER_MSEC),
                       dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            if (be->CompletedSeq() >= seq) return;
            fprintf(stderr, "[gnm-draw] GPU hang report: command buffer gnm-%llu not complete %ld ms after commit\n",
                    (unsigned long long)cmd_index, hang_ms);
            if (log) log->Print("pending work", WorkLog::kAll);
        });
    }
    // drop the logs of completed command buffers
    if (S.inflight_logs.size() >= 8) {
        const uint64_t c = S.be->CompletedSeq();
        while (!S.inflight_logs.empty() && S.inflight_logs.front().seq <= c) S.inflight_logs.pop_front();
    }
    S.inflight_logs.push_back({seq, cmd_index, log});
}
```

(the `arena` and `chunks` locals, the `addCompletedHandler` block, `[cb commit]`, and the `S.inflight` pruning loop are gone: their content is in `CommitDoneFn` and `Metal3Backend::Commit`/`CompletedSeq`.)

`WaitAll` (`:1925-1991`): the status walk becomes `CompletedSeq()`:

```cpp
void WaitAll() {
    const double t0 = CFAbsoluteTimeGetCurrent();
    if (!S.inflight_logs.empty()) S.n_waits++, S.n_waits_total++;
    const auto committed = [] {
        std::lock_guard<std::mutex> lk(S.fence_mu);
        return S.committed_seq;
    };
    while (!S.hung) {
        GmService();
        const uint64_t target = committed();
        const uint64_t done = S.be->CompletedSeq();
        const auto finished = [&] { return done >= target && GmResolved() >= g_gms.committed; };
        if (finished()) break;
        bool progressed;
        {
            encq::Unlocked free_state; // a re-run may be what it waits for
            std::unique_lock<std::mutex> lk(g_gms.mu);
            progressed = g_gms.cv.wait_for(lk, std::chrono::duration<double, std::milli>(S.gpu_timeout_ms), [&] {
                return g_gms.miss.load(std::memory_order_relaxed) || S.be->CompletedSeq() != done ||
                       (done >= target && GmResolved() >= g_gms.committed);
            });
        }
        if (progressed) continue;
        const InflightLog* stuck = nullptr;
        for (const InflightLog& l : S.inflight_logs)
            if (l.seq > done) {
                stuck = &l;
                break;
            }
        char label[32] = "(guest memory dispatch result)";
        if (done < target) snprintf(label, sizeof(label), "gnm-%llu", (unsigned long long)(stuck ? stuck->cmd_index : 0));
        fprintf(stderr,
                "[gnm-draw] GPU watchdog: command buffer %s did not complete in %.0f ms; "
                "disabling GPU rendering (fences keep being signaled)\n",
                label, S.gpu_timeout_ms);
        S.hung = true;
        ps4_metal_screen_release_held();
        GmLogState();
        if (stuck && stuck->log) stuck->log->Print("hung work", WorkLog::kAll);
        GmReleaseAll();
    }
    S.inflight_logs.clear();
    …the rest (:1971-1990) unchanged…
}
```

`SampledTexture` (`:5425-5434`):

```cpp
    if (!S.be->CmdOpen(GnmCmdTarget::Upload)) {
        S.be->BeginCmd(GnmCmdTarget::Upload, @"texture uploads", false);
        GmWaitForCommitted(GnmCmdTarget::Upload);
    }
    if (EncodeGpuUpload(img, up, M3Legacy().LegacyCmd(GnmCmdTarget::Upload))) {
```

`Init` (`:6351-6352`): replace the two queue lines by

```cpp
        {
            const bool only_clears = getenv("PS4_GNM_MTL4_ONLY_CLEARS") && !strcmp(getenv("PS4_GNM_MTL4_ONLY_CLEARS"), "1");
            const GnmBackendChoice ch = ChooseBackend(getenv("PS4_GNM_METAL"), [S.dev supportsFamily:MTLGPUFamilyMetal4],
                                                      kMetal4BackendCaps, only_clears, false);
            if (!ch.ok) {
                fprintf(stderr, "[gnm-draw] FATAL: %s\n", ch.why.c_str());
                ps4_host_quit(2);
            }
            S.be = MakeMetal3Backend();
            std::string why;
            if (!S.be->Init(S.dev, &why)) {
                fprintf(stderr, "[gnm-draw] FATAL: the %s backend did not start: %s\n", BackendName(ch.kind), why.c_str());
                ps4_host_quit(2);
            }
            fprintf(stderr, "[gnm-draw] backend %s (%s)\n", BackendName(S.be->Kind()), ch.why.c_str());
        }
```

and `S.tex = new TextureCache(S.dev, S.queue, …)` (`:6359`) → `S.tex = new TextureCache(S.dev, S.be->SideQueue(), proc->mem_base, proc->mem_size);`.

`AfterGpuImpl` (`:6663-6670`): `S.cmd` → `S.be->CmdOpen(GnmCmdTarget::Main)` (three places). `CommitEachForDebug` (`:7050`): `if (each && S.be->CmdOpen(GnmCmdTarget::Main)) Commit();`.

Every other `S.cmd` (the lists in **Files**) → `M3Legacy().LegacyCmd(GnmCmdTarget::Main)`; `S.upload_cmd` in `EncodeGpuUploadAt` callers → `M3Legacy().LegacyCmd(GnmCmdTarget::Upload)`. `BeginPass` (`:5710-5711`) adopts its encoder:

```cpp
    S.renc = [M3Legacy().LegacyCmd(GnmCmdTarget::Main) renderCommandEncoderWithDescriptor:rp];
    M3Legacy().LegacyAdoptRender(S.renc);
    g_rstate.Reset(S.renc);
```

and `ComputeEncoder` (`:5746-5749`) likewise `M3Legacy().LegacyAdoptCompute(S.cenc);` after creating it; `EndEncoders` (`:1671-1679`) ends them through the backend so its state stays right:

```cpp
    if (S.renc) {
        S.be->EndEncoder(); // [S.renc endEncoding]
        S.renc = nil;
        ResolveEqaaPass();
    }
    if (S.cenc) {
        S.be->EndEncoder();
        S.cenc = nil;
    }
```

(the same replacement at `BeginPass` `:5644`/`:5649` and `ComputeEncoder` `:5737`; `EncodeCs`'s label path `:7724` and `GmEncoder`'s main path stay on `S.cenc`, which is the adopted encoder).

`tools/gnm_replay/build.sh:20`: add `"$G/ps4_gnm_backend_metal3.mm"`.

- [ ] **Step 3: Build and run the R-check**

Replay tool build tag `t12` (`build=0`); R-check `t12 3`. Expected `cmp=0` on both frames (if a pass differs, the lifecycle move changed behaviour: compare with the `Commit`/`WaitAll` code above line by line; never adjust the compare).

- [ ] **Step 4: Host suite**

Host suite tag `t12`. Expected `host=0` (the `gnm_submit_flip_nonblocking_test` hang modes exercise the new `WaitAll` watchdog and `CompletedSeq`).

- [ ] **Step 5: Commit**

```bash
git add $G/ps4_gnm_backend_metal3.h $G/ps4_gnm_backend_metal3.mm $G/ps4_gnm_draw.mm tools/gnm_replay/build.sh
git commit -m "gnm: Metal3Backend; command buffers and the seq timeline behind it

Moves EnsureCmd, Commit (completion handler -> CommitDoneFn), WaitAll's status walk
(-> CompletedSeq), the queue creation of Init and the upload command buffer of SampledTexture
onto Metal3Backend. Behaviour unchanged (replay byte-identical, host suite green).

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

### Task 1.3: Passes and encoders

**Files:**
- Modify: `$G/ps4_gnm_draw.mm`: `EncoderState` (`:2846-2887`), `EndEncoders` (`:1666-1682`), `WorkLabel` (`:1694-1697`), `BeginPass` (`:5641-5732`), `ComputeEncoder` (`:5734-5753`), `State::renc`/`State::cenc` (`:600-601`), their users (`EliminateFastClear` `:6033`, `DrawEncode` `:7436-7438`/`:7515`, `EncodeCs` `:7723-7733`/`:7746-7748`, `GmEncoder` `:7839`, `GmEncodeDispatch` `:7880`/`:7888`, `GmRunSync` `:7992-7995`, `EncodeGpuUploadAt` `:5260`/`:5270`, `ComputeBarrierImpl` `:6538`)

**Interfaces:**
- Consumes: `GnmBackend::{BeginRender, BeginCompute, EndEncoder, OpenEncoder, EncoderSerial, SetEncoderLabel}`, `GnmPassDesc`, `GnmAttachment`.
- Produces: `bool BeginPass(const PassKey& key, const ClearReq& clr, id<MTLTexture> const* hold)` (was `id<MTLRenderCommandEncoder>`), `void ComputeEncoder()` (was `id<MTLComputeCommandEncoder>`; callers that sent raw calls use `M3Legacy().LegacyCompute()` until Task 1.5), `EncoderState::Reset(uint64_t serial)`, `EncoderState::Tracks(uint64_t serial) const`, `EncoderState::enc` is a `uint64_t` serial.

- [ ] **Step 1: EncoderState keyed by the backend's encoder serial**

```cpp
struct EncoderState {
    struct Slot { const void* p = nullptr; NSUInteger off = 0; uint32_t gen = 0; };
    uint64_t enc = 0;   // GnmBackend::EncoderSerial of the encoder described (0: none)
    uint32_t gen = 1;   // slots of other generations are unknown
    Slot buf[3][31], tex[3][128], samp[3][16];
    Slot pso, dss;
    using Fixed = GnmFixedState; // fixed-function state of a render encoder
    Fixed fixed;
    uint32_t fixed_gen = 0;
    bool fixed_stencil = false; // fixed.stencil_ref is set
    struct Used { const void* p; uint32_t how; } used[32];
    uint32_t n_used = 0;

    void Reset(uint64_t serial) {
        enc = serial;
        ++gen;
        n_used = 0;
    }
    bool Tracks(uint64_t serial) const { return serial && serial == enc; }
    bool Same(Slot& sl, const void* p) { …unchanged… }
};
```

`Binder::Tracked()` (`:2898-2902`):

```cpp
    EncoderState* Tracked() const {
        if (untracked) return nullptr;
        EncoderState& es = stage == Stage::Compute ? g_cstate : g_rstate;
        return es.Tracks(S.be->EncoderSerial()) ? &es : nullptr;
    }
```

- [ ] **Step 2: BeginPass, ComputeEncoder, EndEncoders on the backend**

`EndEncoders` (`:1666`):

```cpp
void EndEncoders() {
    if (g_gms.chain_open && !g_gms.chain_closing) {
        GmCloseChain(); // ends the encoders itself
        return;
    }
    const GnmEncoder open = S.be->OpenEncoder();
    if (open != GnmEncoder::None) S.be->EndEncoder();
    if (open == GnmEncoder::Render) ResolveEqaaPass();
    S.pass = PassKey{};
    for (auto& t : S.pass_hold) t = nil;
}
```

`BeginPass` (`:5641-5732`):

```cpp
bool BeginPass(const PassKey& key, const ClearReq& clr, id<MTLTexture> const* hold) {
    if (g_gms.chain_open) GmCloseChain();
    const GnmEncoder open = S.be->OpenEncoder();
    if (open == GnmEncoder::Compute) S.be->EndEncoder();
    if (open == GnmEncoder::Render && S.pass == key && !clr.any()) return true;
    if (open == GnmEncoder::Render) {
        S.be->EndEncoder();
        ResolveEqaaPass();
    }
    …EQAA stand-in loop (:5653-5662) unchanged…
    EnsureCmd();
    GnmPassDesc pd;
    bool any = false;
    for (int i = 0; i < 8; ++i) {
        if (!key.color[i]) continue;
        any = true;
        pd.color[i].tex = key.color[i];
        pd.color[i].load = clr.color[i] ? GnmLoad::Clear : GnmLoad::Load;
        if (clr.color[i]) pd.clear_color[i] = clr.color_value[i];
    }
    if (key.depth) {
        any = true;
        pd.depth.tex = key.depth;
        pd.depth.slice = key.depth_slice;
        pd.depth.load = clr.depth ? GnmLoad::Clear : GnmLoad::Load;
        pd.clear_depth = std::min(1.0, std::max(0.0, clr.depth_value));
        if (HasStencil(key.depth.pixelFormat)) {
            pd.stencil.tex = key.depth;
            pd.stencil.slice = key.depth_slice;
            pd.stencil.load = clr.stencil ? GnmLoad::Clear : GnmLoad::Load;
            pd.clear_stencil = clr.stencil_value;
        }
    }
    if (!any) {
        pd.width = std::max(1u, key.width);
        pd.height = std::max(1u, key.height);
        pd.default_samples = 1;
    }
    if (key.sample_locs && S.dev.programmableSamplePositionsSupported) {
        id<MTLTexture> t = key.depth;
        for (int i = 0; !t && i < 8; ++i) t = key.color[i];
        const NSUInteger n = t ? t.sampleCount : 1;
        if (n > 1 && n <= 4) {
            for (NSUInteger i = 0; i < n; ++i) {
                const uint32_t b = (key.sample_locs >> (8 * i)) & 0xFF;
                const int sx = (int)((b & 0xF) ^ 8) - 8, sy = (int)(((b >> 4) & 0xF) ^ 8) - 8;
                pd.sample_positions[i] = MTLSamplePositionMake(std::min(15, 8 + sx) / 16.0f, std::min(15, 8 + sy) / 16.0f);
            }
            pd.num_sample_positions = (uint32_t)n;
        }
    }
    static const bool labels = getenv("PS4_GNM_LABELS") != nullptr;
    if (labels) {
        id<MTLTexture> t0 = key.color[0] ? key.color[0] : key.depth;
        int ncol = 0;
        for (int i = 0; i < 8; ++i) ncol += key.color[i] != nil;
        pd.label = [NSString stringWithFormat:@"pass %llu: %d color%s %lux%lu fmt %lu depth %s%s", …the arguments of :5719-5725 unchanged…];
    } else if (EncoderStatusEnabled()) {
        pd.label = WorkLabel("render");
    }
    if (!S.be->BeginRender(pd)) return false;
    g_rstate.Reset(S.be->EncoderSerial());
    S.n_passes++;
    if (key.depth && !clr.depth) S.n_depth_loads++;
    S.pass = key;
    for (int i = 0; i < 9; ++i) S.pass_hold[i] = hold ? hold[i] : nil;
    return true;
}
```

(The label NSString is created under the backend call's autorelease pool as before; `pd.label` is `__unsafe_unretained`, so keep a strong local: `NSString* label = …; pd.label = label;`.)

`ComputeEncoder` (`:5734-5753`):

```cpp
void ComputeEncoder() {
    if (g_gms.chain_open && !g_gms.chain_member) GmCloseChain();
    if (S.be->OpenEncoder() == GnmEncoder::Render) {
        S.be->EndEncoder();
        ResolveEqaaPass(); // EQAA stand-ins write sample 0 back before compute reads the targets
        S.pass = PassKey{};
        for (auto& t : S.pass_hold) t = nil;
    }
    EnsureCmd();
    if (S.be->OpenEncoder() != GnmEncoder::Compute) {
        static const bool serial = getenv("PS4_GNM_SERIAL_COMPUTE") != nullptr;
        S.be->BeginCompute(serial);
        if (EncoderStatusEnabled()) S.be->SetEncoderLabel(WorkLabel("compute"));
        g_cstate.Reset(S.be->EncoderSerial());
        S.n_cencs++;
    }
}
```

Delete `State::renc` and `State::cenc`. Their users:
- `DrawEncode` `:7436-7438`: `if (!BeginPass(key, clr, hold)) return; id<MTLRenderCommandEncoder> enc = M3Legacy().LegacyRender(); const uint64_t enc_serial = S.be->EncoderSerial(); EncoderState* es = g_rstate.Tracks(enc_serial) ? &g_rstate : nullptr;` and `:7515` `if (S.be->EncoderSerial() != enc_serial) {` (the "encoder restarted after a hazard flush" check).
- `EncodeCs` `:7723-7726`: `if (!forced && labels && S.be->OpenEncoder() == GnmEncoder::Compute) S.be->EndEncoder();`; `:7727`: `id<MTLComputeCommandEncoder> enc = forced; if (!forced) { ComputeEncoder(); enc = M3Legacy().LegacyCompute(); }`; `:7728-7731` label → `S.be->SetEncoderLabel(…)` when `!forced`; `:7732`: `if (forced || !g_cstate.Tracks(S.be->EncoderSerial()) || …)`; `:7746`: record `const uint64_t serial = S.be->EncoderSerial();` right after the pipeline is set and test `if (!forced && S.be->EncoderSerial() != serial) { ComputeEncoder(); enc = M3Legacy().LegacyCompute(); if (!g_cstate.Tracks(S.be->EncoderSerial()) || …`.
- `GmEncoder` `:7839`: `if (!t.second) { ComputeEncoder(); return M3Legacy().LegacyCompute(); }`.
- `g_cstate.Reset(enc)` (`:5270`, `:7880`, `:7888`, `:7995`) → `g_cstate.Reset(S.be->EncoderSerial())`.
- `EncodeGpuUploadAt` `:5260`: `ComputeEncoder(); enc = M3Legacy().LegacyCompute();`.
- `ComputeBarrierImpl` `:6538`: `if (S.be->OpenEncoder() == GnmEncoder::Compute) [M3Legacy().LegacyCompute() memoryBarrierWithScope:MTLBarrierScopeBuffers | MTLBarrierScopeTextures], S.n_cbarriers++;`
- `EliminateFastClear` `:6033`: `BeginPass(k, clr, hold);` (result unused, as before).
- `Binder{Stage::Vertex, enc, nil}` / `Binder b{…, enc, …}` keep their encoder fields this task (Task 1.4 removes them).
- Delete `M3Legacy().LegacyAdoptRender`/`LegacyAdoptCompute` calls and the two methods from `Metal3Backend` (no user left).

- [ ] **Step 3: Build, R-check, host suite**

Replay tool build tag `t13`; R-check `t13 3`: `cmp=0`. Host suite tag `t13`: `host=0`. With `PS4_GNM_LABELS=1`, replay one draw pass of the courtyard frame and check that the label path runs (`$M/replay_t13/gnm_replay <frame> <D>`: exit 0 or 1 as in Phase 0, no crash).

- [ ] **Step 4: Commit**

```bash
git add $G/ps4_gnm_draw.mm $G/ps4_gnm_backend_metal3.h
git commit -m "gnm: render passes and compute encoders behind GnmBackend

Moves BeginPass's MTLRenderPassDescriptor, ComputeEncoder and EndEncoders onto
GnmBackend::BeginRender / BeginCompute / EndEncoder; encoder dedupe keyed by
GnmBackend::EncoderSerial. Behaviour unchanged.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

### Task 1.4: Binding and pipeline state

**Files:**
- Modify: `$G/ps4_gnm_draw.mm`: `enum class Stage` (`:2839`), `Binder` (`:2889-2966`), `BindStage` users of `b.Use` (`:4420`, `:4558`), `BindGuestPageTable` (`:4146`), `DrawEncode` pipeline / depth-stencil / fixed state (`:7439-7494`) and its `Binder`s (`:7499`, `:7507`), `EncodeCs` (`:7732-7733`, `:7736`, `:7748-7751`), `GmEncodeGate`/`GmEncodeHarvest` state (`:7814-7820`, `:7826-7827`), `EncodeGpuUploadAt` detile state (`:5263-5267`)

**Interfaces:**
- Consumes: `GnmBackend::{BindBuffer, BindBufferOffset, BindBytes, BindTexture, BindSampler, UseResource, SetRenderPipeline, SetDepthStencil, SetFixed, SetComputePipeline}`, `GnmFixedState`, `GnmFixedBits`, `GnmComputeSink`.
- Produces: `using Stage = GnmStage;`; `struct Binder { Stage stage; id<MTLComputeCommandEncoder> raw = nil; GmTextures* textures_out = nullptr; const GmTextures* textures_in = nullptr; … }` (raw: a queue2 encoder; nil: the backend); `GmEncodeGate(const GnmComputeSink& enc, …)`, `GmEncodeHarvest(const GnmComputeSink& enc, const GmSlot&)`.

- [ ] **Step 1: Stage and Binder**

`:2839`: `using Stage = GnmStage; // Vertex, Fragment, Compute (indexes the per-stage arrays)`

`Binder` (`:2889-2966`):

```cpp
struct Binder {
    Stage stage;
    // a Metal 3 compute encoder of the guest memory re-run queue (queue2), which g_cstate does not
    // describe (its object may even reuse the address of a tracked one); nil: the backend's open encoder
    id<MTLComputeCommandEncoder> raw = nil;
    GmTextures* textures_out = nullptr;      // records every texture bound
    const GmTextures* textures_in = nullptr; // BindStage binds these instead of looking images up
    EncoderState* Tracked() const {
        if (raw) return nullptr;
        EncoderState& es = stage == Stage::Compute ? g_cstate : g_rstate;
        return es.Tracks(S.be->EncoderSerial()) ? &es : nullptr;
    }
    void Buffer(id<MTLBuffer> b, NSUInteger off, uint32_t slot) {
        if (slot > 30) return;
        if (raw) {
            [raw setBuffer:b offset:off atIndex:slot];
            return;
        }
        if (EncoderState* es = Tracked()) {
            EncoderState::Slot& sl = es->buf[(int)stage][slot];
            if (sl.gen == es->gen && sl.p == (__bridge const void*)b) {
                if (sl.off == off || !b) return;
                sl.off = off;
                S.be->BindBufferOffset(stage, slot, off);
                return;
            }
            sl.p = (__bridge const void*)b;
            sl.off = off;
            sl.gen = es->gen;
        }
        S.be->BindBuffer(stage, slot, b, off);
    }
    // Residency (+ hazard tracking on Metal 3) of a buffer reached through an argument buffer.
    void Use(id<MTLBuffer> b, bool written) {
        if (raw) {
            [raw useResource:b usage:written ? (MTLResourceUsageRead | MTLResourceUsageWrite) : MTLResourceUsageRead];
            return;
        }
        if (EncoderState* es = Tracked()) {
            const uint32_t how = (written ? 3u : 1u) | ((uint32_t)stage << 8);
            for (uint32_t i = 0; i < es->n_used; ++i)
                if (es->used[i].p == (__bridge const void*)b && es->used[i].how == how) return;
            if (es->n_used < 32) es->used[es->n_used++] = {(__bridge const void*)b, how};
        }
        S.be->UseResource(stage, b, written);
    }
    void Bytes(const void* p, size_t n, uint32_t slot) {
        if (slot > 30) return;
        if (EncoderState* es = Tracked()) es->buf[(int)stage][slot].gen = 0; // replaced by the bytes
        if (n > 4096) {
            id<MTLBuffer> b;
            size_t off;
            void* ptr;
            if (!S.arena.Alloc(S.dev, n, 256, &b, &off, &ptr)) return;
            memcpy(ptr, p, n);
            Buffer(b, off, slot);
            return;
        }
        if (raw) [raw setBytes:p length:n atIndex:slot];
        else S.be->BindBytes(stage, slot, p, n);
    }
    void Texture(id<MTLTexture> t, uint32_t slot) {
        if (slot > 127) return;
        if (textures_out) textures_out->push_back({slot, t});
        if (raw) {
            [raw setTexture:t atIndex:slot];
            return;
        }
        if (EncoderState* es = Tracked(); es && es->Same(es->tex[(int)stage][slot], (__bridge const void*)t)) return;
        S.be->BindTexture(stage, slot, t);
    }
    void Sampler(id<MTLSamplerState> s, uint32_t slot) {
        if (slot > 15) return;
        if (raw) {
            [raw setSamplerState:s atIndex:slot];
            return;
        }
        if (EncoderState* es = Tracked(); es && es->Same(es->samp[(int)stage][slot], (__bridge const void*)s)) return;
        S.be->BindSampler(stage, slot, s);
    }
};
```

(`how` used `(uint32_t)MTLResourceUsage…` values 1 and 3; the literals are the same numbers. The raw `Use` path keeps the compute form only: queue2 encoders are compute encoders.)

- [ ] **Step 2: Pipeline and fixed state in DrawEncode and EncodeCs**

`DrawEncode` `:7439`: `if (!es || !es->Same(es->pso, (__bridge const void*)pso)) S.be->SetRenderPipeline(pso);`, `:7453`: `… S.be->SetDepthStencil(dss);`. The fixed-state block (`:7454-7494`):

```cpp
        {
            EncoderState::Fixed f;
            memset(&f, 0, sizeof(f)); // padding is compared
            …f.vp … f.blend: unchanged (:7457-7470)…
            const bool known = es && es->fixed_gen == es->gen;
            const EncoderState::Fixed* o = known ? &es->fixed : nullptr;
            uint32_t changed = 0;
            if (has_stencil && (!o || !es->fixed_stencil || memcmp(o->stencil_ref, f.stencil_ref, sizeof(f.stencil_ref))))
                changed |= kGnmFixedStencilRef;
            if (!o || memcmp(&o->vp, &f.vp, sizeof(f.vp))) changed |= kGnmFixedViewport;
            if (!o || memcmp(&o->sc, &f.sc, sizeof(f.sc))) changed |= kGnmFixedScissor;
            if (!o || o->cull != f.cull) changed |= kGnmFixedCull;
            if (!o || o->winding != f.winding) changed |= kGnmFixedWinding;
            if (!o || o->fill != f.fill) changed |= kGnmFixedFill;
            if (!o || o->clip != f.clip) changed |= kGnmFixedClip;
            if (!o || memcmp(o->bias, f.bias, sizeof(f.bias))) changed |= kGnmFixedBias;
            if (!o || memcmp(o->blend, f.blend, sizeof(f.blend))) changed |= kGnmFixedBlend;
            if (changed) S.be->SetFixed(f, changed);
            …the es-> bookkeeping (:7484-7493) unchanged…
        }
```

(`Metal3Backend::SetFixed` sends in the same order as the old block.) Binders: `Binder vb{Stage::Vertex};`, `Binder fb{Stage::Fragment};`.

`EncodeCs`: `:7732-7733` → `if (forced) [forced setComputePipelineState:pso]; else if (!g_cstate.Tracks(S.be->EncoderSerial()) || !g_cstate.Same(g_cstate.pso, (__bridge const void*)pso)) S.be->SetComputePipeline(pso);` (same at `:7748-7749` without the forced branch); `Binder b{Stage::Compute, forced, tex_out, tex_in};` and `Binder b2{Stage::Compute, nil, tex_out, tex_in};`.

- [ ] **Step 3: Guest memory gate and harvest through GnmComputeSink**

`GmEncodeGate(const GnmComputeSink& enc, const GmSlot& slot, …)` (`:7788`): replace its sends (`:7814-7821`) with `enc.Pipeline(g_gmem.gate_pso); enc.Buffer(0, slot.buf, 0); enc.Bytes(1, &p, sizeof(p)); …enc.Bytes(2, …) both branches…; enc.Buffer(3, ab, aoff); enc.Buffer(4, prev ? prev : slot.buf, 0); enc.Dispatch(MTLSizeMake(1, 1, 1), MTLSizeMake(GmThreads(g_gmem.gate_pso), 1, 1));` `GmEncodeHarvest(const GnmComputeSink& enc, const GmSlot& slot)` likewise. Their callers (`GmEncodeDispatch` `:7879`, `:7887`; `GmRunSync` `:7994`) pass `GnmComputeSink{S.be.get(), t.second ? enc : nil}` (`GmRunSync`'s capture path: `GnmComputeSink{S.be.get(), nil}`).

`EncodeGpuUploadAt` detile (`:5263-5267`), main path (`side == nil`): `S.be->SetComputePipeline(S.detile_pso); S.be->BindBuffer(GnmStage::Compute, 0, gbuf, goff); S.be->BindBuffer(GnmStage::Compute, 1, staging, 0); S.be->BindBuffer(GnmStage::Compute, 2, map, 0); S.be->BindBytes(GnmStage::Compute, 3, params, sizeof(params));` The side path (`side != nil`) keeps its raw sends until Task 1.6 moves the upload target.

- [ ] **Step 4: Build, R-check, host suite, commit**

Replay build `t14`, R-check `t14 3`: `cmp=0`; host suite `t14`: `host=0`; the `gnm_guest_memory_test` modes of the suite exercise the queue2 raw path.

```bash
git add $G/ps4_gnm_draw.mm
git commit -m "gnm: bindings and pipeline state behind GnmBackend

Binder's set* sends and useResource go through GnmBackend's bind table (dedupe stays in the
renderer); DrawEncode's pipeline, depth-stencil and fixed-function state through
SetRenderPipeline / SetDepthStencil / SetFixed; the guest memory gate and harvest through
GnmComputeSink (queue2 stays Metal 3). Behaviour unchanged.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

### Task 1.5: Draws and dispatches (and rect lists)

**Files:**
- Modify: `$G/ps4_gnm_draw.mm`: `DrawEncode` index data and draw calls (`:7316-7367`, `:7520`, `:7522-7550`), `EncodeCs` dispatch (`:7727`, `:7760-7774`), `GmEncoder`/`GmTarget`/`GmEncodeDispatch` (`:7832-7891`), `EncodeGpuUploadAt` detile dispatch (`:5268`)
- Modify: `$G/ps4_gnm_rectlist.h:57-90` (`Geometry` gets `index_length`; `Encode` takes the backend)
- Test: `tests/host/gnm_rectlist_test.mm:200-295` (encodes through `Metal3Backend`), `tests/host/run_host_tests.sh` (its build line gets the backend sources)

**Interfaces:**
- Consumes: `GnmBackend::{Draw, Dispatch, DispatchThreads, DispatchIndirect, Barrier, SetRenderPipeline, BindBuffer}`, `GnmDraw`, `MakeMetal3Backend`.
- Produces:
  - `ps4gnm_rect::Geometry::index_length` (`uint64_t`, bytes at `index_offset`);
  - `inline void ps4gnm_rect::Encode(ps4gnm::GnmBackend& be, id<MTLRenderPipelineState> capture, id<MTLRenderPipelineState> expand, const Geometry& g, const Buffers& b);`
  - `GnmComputeSink GmEncoder(GmTarget& t)` (was `id<MTLComputeCommandEncoder>`); `EncodeCs(DispatchRec&, id<MTLComputePipelineState>, MTLSize, id<MTLComputeCommandEncoder> forced, id<MTLBuffer> args, NSUInteger args_off, GmTextures* = nullptr, const GmTextures* = nullptr)` unchanged signature.

- [ ] **Step 1: Make the rect-list test encode through the backend (fails to compile first)**

In `tests/host/gnm_rectlist_test.mm`, add `#include "ps4_gnm_backend_metal3.h"`. The fixture gets a backend next to its queue: in the fixture struct add `std::unique_ptr<ps4gnm::GnmBackend> be;` and where `f.q` is created add `f.be = ps4gnm::MakeMetal3Backend(); std::string why; CHECK(f.be->Init(f.dev, &why), "backend: %s", why.c_str());`. Replace the encoding (`:213-289`, from `MTLRenderPassDescriptor* pd` to `[cb waitUntilCompleted];`) by:

```objc
    ps4gnm::GnmBackend& be = *f.be;
    be.BeginCmd(ps4gnm::GnmCmdTarget::Main, @"rectlist test", false);
    ps4gnm::GnmPassDesc pd;
    pd.color[0].tex = rt;
    pd.color[0].load = ps4gnm::GnmLoad::Clear;
    pd.clear_color[0] = MTLClearColorMake(0, 0, 0, 0);
    CHECK(be.BeginRender(pd), "%s: no render encoder", c.name);
    ps4gnm::GnmFixedState fx{};
    fx.vp = MTLViewport{0, 16384, 16384, -16384, 0, 1};
    fx.sc = MTLScissorRect{0, 0, kSize, kSize};
    fx.cull = c.cull_back ? (uint32_t)MTLCullModeBack : (uint32_t)MTLCullModeNone;
    fx.winding = (uint32_t)MTLWindingClockwise;
    fx.fill = (uint32_t)MTLTriangleFillModeFill;
    fx.clip = (uint32_t)MTLDepthClipModeClip;
    be.SetFixed(fx, ps4gnm::kGnmFixedViewport | ps4gnm::kGnmFixedScissor | ps4gnm::kGnmFixedCull | ps4gnm::kGnmFixedWinding);
    …the vertex-shader resource loop: [enc setVertexBytes:…] → be.BindBytes(ps4gnm::GnmStage::Vertex, …);
      [enc setVertexBuffer:b offset:o atIndex:i] → be.BindBuffer(ps4gnm::GnmStage::Vertex, i, b, o); same for the push constants…
    …slots / buffers / geo as before, plus geo.index_length = c.indexed ? idx.size() * 2 : 0;…
    ps4gnm_rect::Encode(be, f.capture, f.expand, geo, bufs);
    be.EndEncoder();
    struct Done { dispatch_semaphore_t sem; bool failed; } done{dispatch_semaphore_create(0), false};
    be.Commit(1 + f.n_commits++, [](void* p, const ps4gnm::GnmCompletion& r) {
        Done* d = static_cast<Done*>(p);
        d->failed = r.failed;
        dispatch_semaphore_signal(d->sem);
    }, &done);
    CHECK(dispatch_semaphore_wait(done.sem, dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_SEC)) == 0 && !done.failed,
          "%s: command buffer failed or hung", c.name);
```

(The viewport and cull state the test set with raw calls are now `SetFixed`; scissor `0,0,kSize,kSize` is Metal's default for a `kSize` target, so the rendered pixels are unchanged. Add `uint64_t n_commits = 0;` to the fixture.) Build line in `run_host_tests.sh`: add `"$G/ps4_gnm_backend.mm" "$G/ps4_gnm_backend_metal3.mm"` before `"$GR/libgcn_recompiler.a"` on the `gnm_rectlist_test` line.

Run: `cd ~/ps4recomp-work/PS4Recomp-metal4 && <the gnm_rectlist_test clang++ line from run_host_tests.sh with $R, $G, $GR, $T set>` → Expected: compile error `no matching function for call to 'Encode'` (the header still takes an encoder).

- [ ] **Step 2: Encode on the backend**

`ps4_gnm_rectlist.h`: `#include "ps4_gnm_backend.h"`; in `Geometry` after `index_offset`: `uint64_t index_length = 0; // bytes readable at index_offset (Metal 4 needs it)`; `Encode`:

```objc
inline void Encode(ps4gnm::GnmBackend& be, id<MTLRenderPipelineState> capture, id<MTLRenderPipelineState> expand,
                   const Geometry& g, const Buffers& b) {
    using namespace ps4gnm;
    be.SetRenderPipeline(capture);
    be.BindBuffer(GnmStage::Vertex, b.capture_slot, b.vertices, b.vertices_off);
    be.BindBuffer(GnmStage::Vertex, b.params_slot, b.params, b.params_off);
    GnmDraw d;
    d.prim = MTLPrimitiveTypePoint;
    d.count = g.count;
    d.instances = g.instances;
    d.base_instance = g.base_instance;
    if (g.index_buffer) {
        d.kind = GnmDrawKind::Indexed;
        d.index_type = g.index_type;
        d.index_buffer = g.index_buffer;
        d.index_offset = g.index_offset;
        d.index_length = g.index_length;
        d.base_vertex = g.base_vertex;
    } else {
        d.vertex_start = g.vertex_start;
    }
    be.Draw(d);
    // The expansion's vertex shader reads what the capture's vertex shader wrote.
    be.Barrier(kGnmStageVertex, kGnmStageVertex, kGnmScopeBuffers);
    be.SetRenderPipeline(expand);
    be.BindBuffer(GnmStage::Vertex, 0, b.vertices, b.vertices_off);
    be.BindBuffer(GnmStage::Vertex, 1, b.slots, b.slots_off);
    be.BindBuffer(GnmStage::Vertex, 2, b.params, b.params_off);
    GnmDraw e;
    e.count = g.count / 3 * 6;
    e.instances = g.instances;
    e.base_instance = g.base_instance;
    be.Draw(e);
}
```

(The old code always used the instanced forms; `Metal3Backend::Draw` uses the short form only for 1 instance at base 0, which Metal defines as the same draw. The update comment above `Encode` names the backend instead of the encoder.)

`DrawEncode`: track the readable index bytes. Declare `uint64_t ib_len = 0;` next to `ib_off` (`:7319`). Indirect indexed (`:7331`): `ib_len = (uint64_t)args.max_index * isz;`. QuadList (`:7337-7341`): `ib_len = (uint64_t)draw_count * 4;`. Indexed (`:7354-7366`): `ib_len = bytes;` (both the window and the arena copy hold `bytes` from the offset). Vertex buffers (`:7520`) unchanged (`vb.Buffer`). The draw (`:7522-7550`):

```cpp
        GnmDraw d;
        d.prim = prim;
        d.index_type = itype;
        d.index_buffer = ib;
        d.index_offset = ib_off;
        d.index_length = ib_len;
        if (indirect) {
            d.kind = indexed ? GnmDrawKind::IndexedIndirect : GnmDrawKind::Indirect;
            d.indirect_buffer = arg_buf;
            d.indirect_offset = arg_off;
            S.be->Draw(d);
        } else if (rect) {
            ps4gnm_rect::Geometry g;
            …g.count … g.index_type unchanged…
            g.index_length = ib_len;
            ps4gnm_rect::Encode(*S.be, rect_capture, pso, g, rect_bufs);
            if (es) …unchanged…
        } else if (indexed) {
            d.kind = GnmDrawKind::Indexed;
            d.count = draw_count;
            d.instances = inst;
            d.base_vertex = (int32_t)vertex_offset;
            d.base_instance = instance_offset;
            S.be->Draw(d);
        } else {
            d.vertex_start = vertex_offset;
            d.count = draw_count;
            d.instances = inst;
            d.base_instance = instance_offset;
            S.be->Draw(d);
        }
```

and delete `id<MTLRenderCommandEncoder> enc = M3Legacy().LegacyRender();` (no user left in DrawEncode).

`EncodeCs` dispatches (`:7760-7774`): `forced ? [forced dispatchThreadgroupsWithIndirectBuffer:…] : S.be->DispatchIndirect(args, args_off, tg)` for each of the three forms (`args`, the guest indirect buffer, direct `Dispatch(MTLSizeMake(r.dim_x, r.dim_y, r.dim_z), tg)`). The local `enc` stays only for the forced path: `id<MTLComputeCommandEncoder> enc = forced; if (!forced) ComputeEncoder();` and the hazard-flush branch calls `ComputeEncoder();` without fetching the encoder.

`GmEncoder` returns `GnmComputeSink`:

```cpp
GnmComputeSink GmEncoder(GmTarget& t) {
    if (!t.second) {
        ComputeEncoder();
        return GnmComputeSink{S.be.get(), nil};
    }
    if (!t.enc) { …queue2 creation unchanged (:7841-7847)… }
    return GnmComputeSink{S.be.get(), t.enc};
}
```

`GmEncodeDispatch`: `GnmComputeSink enc = GmEncoder(t);`, the barrier lambda becomes `const auto barrier = [&](const GnmComputeSink& e) { e.Barrier(); if (!t.second) S.n_cbarriers++; };` (Task 1.7 owns barriers; `GnmComputeSink::Barrier` already sends the same `memoryBarrierWithScope:MTLBarrierScopeBuffers` on both paths), `EncodeCs(r, pso, tg, t.second ? enc.raw : nil, …)`, gate and harvest get `enc`.

`EncodeGpuUploadAt` main path dispatch (`:5268`): `S.be->DispatchThreads(MTLSizeMake(count, 1, 1), MTLSizeMake(256, 1, 1));` (the side path keeps `[enc dispatchThreads:…]` until Task 1.6).

- [ ] **Step 3: Run the rect-list test, the R-check and the host suite**

The `gnm_rectlist_test` lines of `run_host_tests.sh` (with `MTL_DEBUG_LAYER=1`) → Expected: its PASS line (the corner colours are unchanged). Replay build `t15`, R-check `t15 3`: `cmp=0`. Host suite `t15`: `host=0`.

- [ ] **Step 4: Commit**

```bash
git add $G/ps4_gnm_draw.mm $G/ps4_gnm_rectlist.h tests/host/gnm_rectlist_test.mm tests/host/run_host_tests.sh
git commit -m "gnm: draws, dispatches and rect lists behind GnmBackend

DrawEncode's draw calls -> GnmBackend::Draw (with the index buffer length Metal 4 needs),
EncodeCs / the detile -> Dispatch*, ps4gnm_rect::Encode on the backend, the guest memory
encoder as GnmComputeSink. Behaviour unchanged.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

### Task 1.6: Copies and fills (and the upload target)

**Files:**
- Modify: `$G/ps4_gnm_draw.mm`: `MipChainFor` (`:5063-5074`), `EncodeGpuUpload`/`EncodeGpuUploadAt` (`:5162-5309`, the `side` parameter), `SampledTexture` (`:5425-5435`), `ResolvePass` blit (`:6058-6063`), `GpuDmaImpl` (`:6574-6581`), `DrawEncode` grown depth array (`:7127-7134`), `DispatchEncode` surface copy (`:8529-8533`), `GuestDisplayTexture` (`:8731`), `GpuUploadTexture` (`:5319`)

**Interfaces:**
- Consumes: `GnmBackend::{BeginCopies, CopyBuffer, FillBuffer, CopyTexture, CopyTextureRegion, CopyBufferToTexture, EndEncoder, UseTarget, Target, BeginCompute, CmdOpen, BeginCmd}`.
- Produces: `bool EncodeGpuUpload(const ImageDesc& img, const TextureCache::GpuUpload& up, bool upload_target);` and `bool EncodeGpuUploadAt(uint64_t address, const SurfaceDesc& sd, const TextureCache::GpuUpload& up, bool upload_target);` (`upload_target`: into the upload command buffer with its own encoders, the main encoders staying open; false: into the main one, ending its encoders). `struct UploadTargetScope` (RAII: switches the backend to the upload target and back).

- [ ] **Step 1: Copies on the backend**

`MipChainFor` (`:5063-5074`):

```cpp
    EndEncoders();
    EnsureCmd();
    S.be->BeginCopies();
    for (uint32_t m = 0; m < levels; ++m) {
        const uint32_t w = std::max(1u, img.width >> m), h = std::max(1u, img.height >> m);
        id<MTLTexture> src = srcs[m];
        if (!src || src.pixelFormat != base.pixelFormat || src.sampleCount > 1 || src.width < w || src.height < h) continue;
        S.be->CopyTextureRegion(src, 0, 0, MTLOriginMake(0, 0, 0), MTLSizeMake(w, h, 1), mc.tex, 0, m, MTLOriginMake(0, 0, 0));
    }
    S.be->EndEncoder();
```

`ResolvePass` blit branch (`:6059-6063`): `S.be->BeginCopies(); S.be->CopyTextureRegion(s, 0, 0, MTLOriginMake(0, 0, 0), MTLSizeMake(std::min(s.width, d.width), std::min(s.height, d.height), 1), d, 0, 0, MTLOriginMake(0, 0, 0)); S.be->EndEncoder();` (its render-resolve branch is Task 1.9's).

`GpuDmaImpl` (`:6574-6581`):

```cpp
    EndEncoders();
    EnsureCmd();
    S.be->BeginCopies();
    if (src_fill && !sb) S.be->FillBuffer(db, doff, n, (uint8_t)(fill_value & 0xFF));
    else S.be->CopyBuffer(sb, soff, db, doff, n);
    S.be->EndEncoder();
```

`DrawEncode` grown depth array (`:7127-7134`): `EndEncoders(); EnsureCmd(); S.be->BeginCopies(); for (…) S.be->CopyTextureRegion(grown_from, sl, 0, MTLOriginMake(0, 0, 0), MTLSizeMake(t.width, t.height, 1), t, sl, 0, MTLOriginMake(0, 0, 0)); S.be->EndEncoder();`.

`DispatchEncode` surface copy (`:8529-8533`): `EndEncoders(); EnsureCmd(); S.be->BeginCopies(); S.be->CopyTexture(src, dst); S.be->EndEncoder();`.

- [ ] **Step 2: The upload target**

Before `EncodeGpuUpload` add:

```cpp
// The texture-upload command buffer as the backend's current target for this scope (opened if
// needed; work there is committed right before the main command buffer, see Commit).
struct UploadTargetScope {
    GnmCmdTarget prev;
    UploadTargetScope() : prev(S.be->Target()) {
        if (!S.be->CmdOpen(GnmCmdTarget::Upload)) {
            S.be->BeginCmd(GnmCmdTarget::Upload, @"texture uploads", false);
            S.be->UseTarget(GnmCmdTarget::Upload);
            GmWaitForCommitted(GnmCmdTarget::Upload);
        }
        S.be->UseTarget(GnmCmdTarget::Upload);
    }
    ~UploadTargetScope() { S.be->UseTarget(prev); }
};
```

(`GmWaitForCommitted(GnmCmdTarget)` sends to `M3Legacy().LegacyCmd(t)` until Task 1.7, which makes it `QueueWait` on the current target.)

`EncodeGpuUploadAt(…, bool upload_target)`: the compute part (`:5256-5270`):

```cpp
        std::optional<UploadTargetScope> on_upload;
        if (upload_target) {
            on_upload.emplace();
            S.be->BeginCompute(true); // [side computeCommandEncoder]: serial dispatch type
        } else {
            ComputeEncoder();
            S.be->Barrier(kGnmStageDispatch, kGnmStageDispatch, kGnmScopeBuffers); // after the writing dispatches
        }
        S.be->SetComputePipeline(S.detile_pso);
        S.be->BindBuffer(GnmStage::Compute, 0, gbuf, goff);
        S.be->BindBuffer(GnmStage::Compute, 1, staging, 0);
        S.be->BindBuffer(GnmStage::Compute, 2, map, 0);
        S.be->BindBytes(GnmStage::Compute, 3, params, sizeof(params));
        S.be->DispatchThreads(MTLSizeMake(count, 1, 1), MTLSizeMake(256, 1, 1));
        if (upload_target) S.be->EndEncoder();
        else g_cstate.Reset(S.be->EncoderSerial()); // state set behind the dispatches' back
        on_upload.reset();
        src = staging;
        src_base = 0;
```

(`#include <optional>`.) The copy part (`:5274-5303`):

```cpp
    std::optional<UploadTargetScope> on_upload;
    if (upload_target) {
        on_upload.emplace();
    } else {
        EndEncoders();
        EnsureCmd();
    }
    S.be->BeginCopies();
    for (uint32_t m = 0; m < up.levels; ++m) {
        …w, h, row, image, rowbytes, rows, d, slices: unchanged…
        for (uint32_t sl = 0; sl < slices; ++sl)
            S.be->CopyBufferToTexture(src, src_base + ml.offset + (uint64_t)sl * image, row, is3d ? image : 0,
                                      MTLSizeMake(w, h, d), tex, sl, m, MTLOriginMake(0, 0, 0));
    }
    S.be->EndEncoder();
    on_upload.reset();
    if (!upload_target) { S.pending = true; LogWork("GPU texture upload"); }
    return true;
```

(The barrier on the main path was `[enc memoryBarrierWithScope:MTLBarrierScopeBuffers]` on the compute encoder: `Metal3Backend::Barrier` sends exactly that while a compute encoder is open.) Callers: `GpuUploadTexture` (`:5319`) `EncodeGpuUpload(img, up, false)`, `GuestDisplayTexture` (`:8731`) `EncodeGpuUpload(img, up, false)`, `SampledTexture` (`:5425-5435`) drops its own command-buffer creation and calls `EncodeGpuUpload(img, up, true)`; `RefreshGuestNewer`/other `EncodeGpuUploadAt(…, nil)` callers pass `false`.

- [ ] **Step 3: Build, R-check, host suite, commit**

Replay build `t16`, R-check `t16 3`: `cmp=0`; host suite `t16`: `host=0` (`gnm_buffer_over_target_test` exercises the refresh copies, `tex_evict_test` the uploads).

```bash
git add $G/ps4_gnm_draw.mm
git commit -m "gnm: copies, fills and the upload command buffer behind GnmBackend

Blit encoders of MipChainFor, EncodeGpuUploadAt, ResolvePass, GpuDmaImpl, DrawEncode's grown
depth array and the compute surface copy -> BeginCopies + Copy*/FillBuffer; the upload command
buffer as GnmCmdTarget::Upload. Behaviour unchanged.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

### Task 1.7: Barriers and queue-level events

**Files:**
- Modify: `$G/ps4_gnm_draw.mm`: `ComputeBarrierImpl` (`:6537-6539`), `GmWaitForCommitted` (Task 1.2 form), `GmCloseChain` (`:8130-8132`), `DebugStallGpu` (`:6705-6714`)

**Interfaces:**
- Consumes: `GnmBackend::{Barrier, QueueSignal, QueueWait, OpenEncoder, UseTarget}`.
- Produces: `void GmWaitForCommitted();` (the current target).

- [ ] **Step 1: Move**

```cpp
void ComputeBarrierImpl() {
    if (S.be->OpenEncoder() != GnmEncoder::Compute) return;
    S.be->Barrier(kGnmStageDispatch | kGnmStageBlit, kGnmStageDispatch | kGnmStageBlit, kGnmScopeBuffers | kGnmScopeTextures);
    S.n_cbarriers++;
}

// A new command buffer starts after the result of every guest memory dispatch committed so far is
// final (the current target's stream waits for 2 * committed).
void GmWaitForCommitted() {
    if (!g_gms.committed || GmResolved() >= g_gms.committed) return;
    S.be->QueueWait(g_gms.ev, 2 * g_gms.committed);
}
```

Callers: `EnsureCmd` → `GmWaitForCommitted();` (the main target is current there); `UploadTargetScope` → `GmWaitForCommitted();` after `UseTarget(Upload)`. `GmCloseChain` (`:8131-8132`): `S.be->QueueSignal(g_gms.ev, 2 * t - 1); S.be->QueueWait(g_gms.ev, 2 * t);`. `DebugStallGpu` (`:6709-6711`): `EndEncoders(); EnsureCmd(); static id<MTLSharedEvent> never = [S.dev newSharedEvent]; S.be->QueueWait(never, 1);`.

- [ ] **Step 2: Build, R-check, host suite, commit**

Replay build `t17`, R-check `t17 3`: `cmp=0`; host suite `t17`: `host=0` (`gnm_guest_memory_test` fast-path modes encode chains; `gnm_submit_flip_nonblocking_test` calls `DebugStallGpu`).

```bash
git add $G/ps4_gnm_draw.mm
git commit -m "gnm: compute barriers and queue-level events behind GnmBackend

ComputeBarrierImpl -> Barrier; GmCloseChain, GmWaitForCommitted and DebugStallGpu ->
QueueSignal / QueueWait. Behaviour unchanged.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

### Task 1.8: The present producer

**Files:**
- Modify: `pkg/runtime/modules/libSceVideoOut/ps4_metal_screen.h:36-40`, `ps4_metal_screen.m:1109-1160` (`ps4_metal_screen_encode_present`), `:1390-1425` (`ps4_metal_screen_queue_held`)
- Modify: `$G/ps4_gnm_draw.mm`: `PresentImpl` (`:8859-8870`), `CommitDone` / `CommitDoneFn` (Task 1.2), `Commit`, the `extern "C" int ps4_metal_screen_encode_present` declaration (`:73`)
- Modify: `tools/gnm_replay/replay_links.c:46-61`

**Interfaces:**
- Consumes: `GnmBackend::{BeginCopies, CopyTexture, EndEncoder, QueueSignal}`.
- Produces (C, `ps4_metal_screen.h`):

```c
// The producer side of a present, split from the command buffer so any renderer backend encodes
// it (docs/present-pacing.md): ps4_metal_screen_present_begin takes a slot for `texture` (the
// texture itself when it is an acquired slot) and fills `op`; the renderer then encodes, behind
// the frame's work, the copy of `texture` into op->copy_dst when that is not NULL and a signal of
// op->event with op->value; ps4_metal_screen_present_commit queues the slot for the presenter.
// If the command buffer fails, ps4_metal_screen_present_failed raises the event so the presenter
// never waits for it forever. Returns 0 with op filled, 1 when the frame is not shown (no free
// slot: nothing to encode, no commit call), -1 on error.
typedef struct ps4_metal_screen_present_op {
    void *event;    // id<MTLSharedEvent>
    uint64_t value;
    void *copy_dst; // id<MTLTexture> or NULL
    int slot;
} ps4_metal_screen_present_op;
int ps4_metal_screen_present_begin(void *texture, ps4_metal_screen_present_op *op);
void ps4_metal_screen_present_commit(const ps4_metal_screen_present_op *op);
void ps4_metal_screen_present_failed(const ps4_metal_screen_present_op *op);
// The same for a held frame: fills op (copy_dst is always NULL: the frame was rendered into the
// held texture) and queues it with done/arg; -1 if `texture` is not a held texture being rendered.
int ps4_metal_screen_held_begin(void *texture, ps4_metal_screen_held_done_fn done, void *arg,
                                ps4_metal_screen_present_op *op);
```

`ps4_metal_screen_encode_present` and `ps4_metal_screen_queue_held` stay (Metal 3 command-buffer conveniences, used by `gnm_submit_flip_nonblocking_test`), rewritten on top of these.

- [ ] **Step 1: Split the screen functions**

In `ps4_metal_screen.m`, `ps4_metal_screen_encode_present` (`:1109`) becomes three functions; the body is the old one divided at its GPU calls:

```objc
int ps4_metal_screen_present_begin(void *texture, ps4_metal_screen_present_op *op) {
    id<MTLTexture> src = (__bridge id<MTLTexture>)texture;
    if (!src || !op) return -1;
    if (!g_inited) {
        if (ps4_metal_screen_init((int)src.width, (int)src.height, "PS4Recomp - Native Metal Display") != 0) return -1;
    }
    presenter_start();
    int s = -1;
    pthread_mutex_lock(&g_pr.q.mu);
    for (int i = 0; i < PRESENT_SLOTS; i++)
        if (g_pr.q.state[i] == PS4_PQ_RENDERING && g_pr.slot[i].tex == src) s = i;
    pthread_mutex_unlock(&g_pr.q.mu);
    op->copy_dst = NULL;
    if (s < 0) {
        int superseded = 0;
        double waited = 0;
        s = ps4_pq_acquire(&g_pr.q, 0, &superseded, &waited);
        if (superseded) ps4_present_stats_on_superseded(pstats());
        if (s >= 0 && (src.pixelFormat != MTLPixelFormatBGRA8Unorm || !slot_texture(&g_pr.slot[s], src.width, src.height))) {
            ps4_pq_cancel(&g_pr.q, s);
            s = -1;
        }
        if (s < 0) {
            ps4_present_stats_on_superseded(pstats()); // this frame is not shown
            (void)screenshot_due();                    // but keeps the per-flip numbering
            ps4_metal_screen_pump_events();
            return 1;
        }
        op->copy_dst = (__bridge void *)g_pr.slot[s].tex;
    }
    op->event = (__bridge void *)g_pr.ready;
    op->value = atomic_fetch_add(&g_pr.ready_value, 1) + 1;
    op->slot = s;
    return 0;
}

void ps4_metal_screen_present_commit(const ps4_metal_screen_present_op *op) {
    g_pr.slot[op->slot].ready = op->value;
    g_pr.slot[op->slot].shot_idx = screenshot_due();
    ps4_pq_submit(&g_pr.q, op->slot, g_pr.slot[op->slot].shot_idx >= 0);
    ps4_metal_screen_pump_events();
}

// A failed command buffer may not have reached its signal; the presenter must not wait for it
// forever. Only while value is the newest handed out: a later command buffer's GPU signal could
// otherwise be lowered again by this CPU write.
void ps4_metal_screen_present_failed(const ps4_metal_screen_present_op *op) {
    id<MTLSharedEvent> ev = (__bridge id<MTLSharedEvent>)op->event;
    _Atomic uint64_t *newest = ev == g_held.ev ? &g_held.ev_value : &g_pr.ready_value;
    if (atomic_load(newest) == op->value && ev.signaledValue < op->value) ev.signaledValue = op->value;
}

int ps4_metal_screen_encode_present(void *command_buffer, void *texture) {
    id<MTLCommandBuffer> cb = (__bridge id<MTLCommandBuffer>)command_buffer;
    if (!cb) return -1;
    ps4_metal_screen_present_op op;
    const int r = ps4_metal_screen_present_begin(texture, &op);
    if (r != 0) return r < 0 ? -1 : 0;
    @autoreleasepool {
        if (op.copy_dst) {
            id<MTLBlitCommandEncoder> blit = [cb blitCommandEncoder];
            [blit copyFromTexture:(__bridge id<MTLTexture>)texture toTexture:(__bridge id<MTLTexture>)op.copy_dst];
            [blit endEncoding];
        }
        [cb encodeSignalEvent:(__bridge id<MTLSharedEvent>)op.event value:op.value];
        const ps4_metal_screen_present_op o = op;
        [cb addCompletedHandler:^(id<MTLCommandBuffer> done) {
            if (done.status == MTLCommandBufferStatusError) ps4_metal_screen_present_failed(&o);
        }];
        ps4_metal_screen_present_commit(&op);
    }
    return 0;
}
```

(`g_held` is defined after this point in the file: move the `HeldFrame`/`g_held` definitions (`:1176-1200`) above `ps4_metal_screen_present_begin`, or forward-declare `g_held` with its struct; the file's existing forward declarations at `:976-978` show the pattern. `g_held.ev_value` and `g_pr.ready_value` are both `_Atomic uint64_t` already.) `ps4_metal_screen_queue_held` (`:1390`) likewise: `ps4_metal_screen_held_begin` holds everything from the start to `pthread_mutex_unlock(&g_held.mu)` and the timer arm, minus the two `cb` calls, and fills `op` (`event = g_held.ev`, `value = v`, `copy_dst = NULL`, `slot = i`); `ps4_metal_screen_queue_held(cb, …)` = `held_begin` + `[cb encodeSignalEvent:…]` + the same failure handler. In `replay_links.c` add abort-on-call definitions for the four new functions, as for their neighbours:

```c
int ps4_metal_screen_present_begin(void *texture, void *op) {
    (void)texture; (void)op;
    NotInReplay("ps4_metal_screen_present_begin (Present)");
    return -1;
}
void ps4_metal_screen_present_commit(const void *op) { (void)op; NotInReplay("ps4_metal_screen_present_commit (Present)"); }
void ps4_metal_screen_present_failed(const void *op) { (void)op; NotInReplay("ps4_metal_screen_present_failed (Present)"); }
int ps4_metal_screen_held_begin(void *texture, void (*done)(void *, int), void *arg, void *op) {
    (void)texture; (void)done; (void)arg; (void)op;
    NotInReplay("ps4_metal_screen_held_begin (Present)");
    return -1;
}
```

- [ ] **Step 2: PresentImpl encodes the producer through the backend**

`CommitDone` gets `std::vector<ps4_metal_screen_present_op> present_fail; // raised if the command buffer fails` and `CommitDoneFn`'s `if (c.failed)` block calls `for (auto& op : d->present_fail) ps4_metal_screen_present_failed(&op);` first. `State` gets `std::vector<ps4_metal_screen_present_op> present_ops; // present signals in the open command buffer`; `Commit` moves them into `done->present_fail` (`done->present_fail.swap(S.present_ops);`).

`PresentImpl` (`:8859-8870`):

```cpp
            HeldFlip* held = hold ? new HeldFlip{seq, std::move(on_done)} : nullptr;
            ps4_metal_screen_present_op op{};
            if (held && ps4_metal_screen_held_begin((__bridge void*)dst, &HeldFlipDone, held, &op) != 0) {
                on_done = std::move(held->on_done); // not taken: shown like an unheld frame below
                delete held;
                held = nullptr;
            } else if (held) {
                S.be->QueueSignal((__bridge id<MTLSharedEvent>)op.event, op.value);
                S.present_ops.push_back(op);
            }
            if (!held) {
                const int r = ps4_metal_screen_present_begin((__bridge void*)dst, &op);
                if (r < 0) RLog("present-screen", "the Metal screen could not take the frame");
                if (r == 0) {
                    if (op.copy_dst) {
                        S.be->BeginCopies();
                        S.be->CopyTexture(dst, (__bridge id<MTLTexture>)op.copy_dst);
                        S.be->EndEncoder();
                    }
                    S.be->QueueSignal((__bridge id<MTLSharedEvent>)op.event, op.value);
                    S.present_ops.push_back(op);
                    ps4_metal_screen_present_commit(&op);
                }
                ps4_metal_screen_note_backpressure(0.0);
                AfterGpu([seq, f = std::move(on_done)]() mutable { CompleteFlip(seq, std::move(f)); });
            }
```

(The conversion pass right above still uses the legacy command buffer until Task 1.9; it ends its encoder before this code, so `BeginCopies` opens the blit on the same command buffer exactly where `ps4_metal_screen_encode_present` did.) Delete the `extern "C" int ps4_metal_screen_encode_present` line (`:73`).

- [ ] **Step 3: Run the present tests and the R-check**

Host suite tag `t18`: `host=0` (`gnm_submit_flip_nonblocking_test` in its three modes: flips complete in order, held frames, the 1 s and 3-frame drops; it calls `ps4_metal_screen_encode_present` on its own command buffer, now built on the split functions). Replay build `t18`, R-check `t18 3`: `cmp=0` (the replay links the stubs and never presents; the check proves nothing else moved).

- [ ] **Step 4: One TLOU run (present path in the game)**

TLOU game build tag `t18`; route run `TAG=t18_present METAL=3 SECS=120` (non-exclusive). Expected: `fatal 0 gpu_err 0 watchdog 0`, `flips` > 1000, screenshots in `$M/runs/shots_t18_present/` show gameplay (Read one).

- [ ] **Step 5: Commit**

```bash
git add pkg/runtime/modules/libSceVideoOut/ps4_metal_screen.h pkg/runtime/modules/libSceVideoOut/ps4_metal_screen.m $G/ps4_gnm_draw.mm tools/gnm_replay/replay_links.c
git commit -m "present: producer split from the command buffer; encoded through GnmBackend

ps4_metal_screen_present_begin / _commit / _failed and _held_begin; PresentImpl encodes the
slot copy and the ready signal with GnmBackend::CopyTexture / QueueSignal, and raises the
event on failure from the seq's completion. ps4_metal_screen_encode_present / queue_held stay
as Metal 3 conveniences on top. Behaviour unchanged.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

### Task 1.9: Helper passes on `BeginRender`/`Draw`

**Files:**
- Create: `$G/ps4_gnm_util_passes.h`, `$G/ps4_gnm_util_passes.mm`
- Modify: `$G/ps4_gnm_draw.mm`: `Init` (`:6412-6519`: the utility MSL and pipelines move out), `SyncDepthSibling` (`:4807-4829`), `SyncStorageToStencil` (`:4865-4884`), `SyncStorageToDepth` (`:4914-4935`), `DepthCompanion` (`:4992-5006`), `DepthFromMemory` (`:5123-5138`), `EqaaCopy` (`:5598-5627`), `ResolvePass` render branch (`:6050-6057`), `PresentImpl` conversion (`:8847-8858`), `M3Legacy` (delete)
- Modify: `$G/ps4_gnm_backend_metal3.h` (delete the `Legacy*` methods)
- Modify: `tools/gnm_replay/build.sh:20` (compile `ps4_gnm_util_passes.mm`)

**Interfaces:**
- Consumes: `GnmBackend`, `GnmPassDesc`, `GnmDraw`.
- Produces (`ps4_gnm_util_passes.h`):

```objc
// SPDX-License-Identifier: GPL-2.0-or-later
// PS4Recomp - the renderer's utility shaders (present conversion, depth and stencil copies,
// depth companions, EQAA copies, GPU texture detile) and the full-screen pass every helper pass
// is drawn with, on any GnmBackend.
#ifndef PS4_GNM_UTIL_PASSES_H
#define PS4_GNM_UTIL_PASSES_H

#include <string>

#include "ps4_gnm_backend.h"

namespace ps4gnm {

extern const char* const kGnmUtilMsl; // the MSL (the renderer's former kPresent)

struct GnmUtil {
    id<MTLLibrary> lib = nil;
    id<MTLRenderPipelineState> present = nil;     // present_vs + present_fs, BGRA8Unorm target
    id<MTLRenderPipelineState> depth2color = nil; // present_vs + depth2color_fs, R32Float target
    id<MTLComputePipelineState> detile = nil;     // detile_gather
};
// Compiles kGnmUtilMsl and builds the three pipelines. False (why set) only when the library does
// not compile; a pipeline that fails stays nil and why says which.
bool MakeGnmUtil(id<MTLDevice> dev, GnmUtil* out, std::string* why);

// A full-screen triangle (present_vs) into the pass `pd`, with `pso`, `dss` (nil: none set) and
// `src` at fragment texture 0. The caller opened the command buffer and ended the open encoder; the
// pass is ended on return. False: no render encoder (nothing encoded).
bool FullscreenPass(GnmBackend& be, const GnmPassDesc& pd, id<MTLRenderPipelineState> pso,
                    id<MTLDepthStencilState> dss, id<MTLTexture> src);

} // namespace ps4gnm

#endif // PS4_GNM_UTIL_PASSES_H
```

- [ ] **Step 1: Write `ps4_gnm_util_passes.mm`**

```objc
// SPDX-License-Identifier: GPL-2.0-or-later
// PS4Recomp - utility shaders and the full-screen helper pass (ps4_gnm_util_passes.h).
#include "ps4_gnm_util_passes.h"

namespace ps4gnm {

const char* const kGnmUtilMsl = R"(
…the MSL of ps4_gnm_draw.mm :6413-6498 (kPresent), unchanged…
)";

bool MakeGnmUtil(id<MTLDevice> dev, GnmUtil* out, std::string* why) {
    NSError* err = nil;
    out->lib = [dev newLibraryWithSource:[NSString stringWithUTF8String:kGnmUtilMsl] options:nil error:&err];
    if (!out->lib) {
        if (why) *why = err ? err.localizedDescription.UTF8String : "no library";
        return false;
    }
    MTLRenderPipelineDescriptor* pd = [MTLRenderPipelineDescriptor new];
    pd.vertexFunction = [out->lib newFunctionWithName:@"present_vs"];
    pd.fragmentFunction = [out->lib newFunctionWithName:@"present_fs"];
    pd.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
    out->present = [dev newRenderPipelineStateWithDescriptor:pd error:&err];
    if (!out->present && why) *why = err.localizedDescription.UTF8String;
    MTLRenderPipelineDescriptor* dd = [MTLRenderPipelineDescriptor new];
    dd.vertexFunction = pd.vertexFunction;
    dd.fragmentFunction = [out->lib newFunctionWithName:@"depth2color_fs"];
    dd.colorAttachments[0].pixelFormat = MTLPixelFormatR32Float;
    out->depth2color = [dev newRenderPipelineStateWithDescriptor:dd error:&err];
    if (id<MTLFunction> f = [out->lib newFunctionWithName:@"detile_gather"])
        out->detile = [dev newComputePipelineStateWithFunction:f error:&err];
    return true;
}

bool FullscreenPass(GnmBackend& be, const GnmPassDesc& pd, id<MTLRenderPipelineState> pso, id<MTLDepthStencilState> dss,
                    id<MTLTexture> src) {
    if (!be.BeginRender(pd)) return false;
    be.SetRenderPipeline(pso);
    if (dss) be.SetDepthStencil(dss);
    be.BindTexture(GnmStage::Fragment, 0, src);
    GnmDraw d;
    d.count = 3;
    be.Draw(d);
    be.EndEncoder();
    return true;
}

} // namespace ps4gnm
```

- [ ] **Step 2: Rewrite the helper passes**

`Init` (`:6412-6519`): replace the `kPresent` string and the pipeline block by

```cpp
        GnmUtil util;
        std::string uwhy;
        if (MakeGnmUtil(S.dev, &util, &uwhy)) {
            S.util_lib = util.lib;
            S.present_pso = util.present;
            S.depth2color_pso = util.depth2color;
            S.detile_pso = util.detile;
        }
        if (!S.present_pso) fprintf(stderr, "[gnm-draw] present pipeline failed: %s\n", uwhy.c_str());
```

Each helper keeps its pipeline lookup and replaces the descriptor and encoder block by a `GnmPassDesc` and `FullscreenPass`:

`SyncDepthSibling` (`:4807-4829`):

```cpp
    EndEncoders();
    EnsureCmd();
    GnmPassDesc pd;
    pd.depth = {t, nil, 0, GnmLoad::DontCare, GnmStore::Store};
    if (HasStencil(t.pixelFormat)) pd.stencil = {t, nil, 0, GnmLoad::Load, GnmStore::Store};
    pd.width = (uint32_t)t.width;
    pd.height = (uint32_t)t.height;
    FullscreenPass(*S.be, pd, pso, S.depth_copy_dss, sib);
    S.pending = true;
    tw = sw;
    S.depth_version[(__bridge void*)t]++;
    LogWork("depth sample-count copy");
```

`SyncStorageToStencil` (`:4865-4884`): `pd.depth = {dt, nil, 0, GnmLoad::Load, GnmStore::Store}; pd.stencil = {dt, nil, 0, GnmLoad::Load, GnmStore::Store}; pd.width = (uint32_t)std::min(dt.width, src.width); pd.height = (uint32_t)std::min(dt.height, src.height); FullscreenPass(*S.be, pd, pso, dss, src);` then its `S.pending`, `BumpDepthVersion`, `LogWork` lines.

`SyncStorageToDepth` (`:4914-4935`): `pd.depth = {dt, nil, 0, GnmLoad::Load, GnmStore::Store}; if (HasStencil(dt.pixelFormat)) pd.stencil = {dt, nil, 0, GnmLoad::Load, GnmStore::Store}; pd.width/height = min as before; FullscreenPass(*S.be, pd, pso, S.depth_copy_dss, src);`.

`DepthCompanion` (`:4992-5006`): `pd.color[0] = {c.tex, nil, 0, GnmLoad::DontCare, GnmStore::Store}; FullscreenPass(*S.be, pd, pso, nil, src);`.

`DepthFromMemory` (`:5123-5138`): `pd.depth = {ent.first, nil, 0, GnmLoad::DontCare, GnmStore::Store}; FullscreenPass(*S.be, pd, pso, S.depth_copy_dss, src);`.

`EqaaCopy` (`:5598-5627`): `EnsureCmd(); GnmPassDesc pd; if (IsDepthFormat(f)) { …depth_copy_dss creation unchanged…; pd.depth = {dst, nil, 0, GnmLoad::DontCare, GnmStore::Store}; if (HasStencil(f)) pd.stencil = {dst, nil, 0, GnmLoad::Load, GnmStore::Store}; } else { pd.color[0] = {dst, nil, 0, GnmLoad::DontCare, GnmStore::Store}; } FullscreenPass(*S.be, pd, pso, IsDepthFormat(f) ? S.depth_copy_dss : nil, src); S.pending = true;`

`ResolvePass` render branch (`:6050-6057`): `GnmPassDesc pd; pd.color[0] = {s, d, 0, GnmLoad::Load, GnmStore::MultisampleResolve}; if (S.be->BeginRender(pd)) S.be->EndEncoder();`

`PresentImpl` conversion (`:8847-8858`): `EndEncoders(); EnsureCmd(); GnmPassDesc pd; pd.color[0] = {dst, nil, 0, GnmLoad::DontCare, GnmStore::Store}; FullscreenPass(*S.be, pd, S.present_pso, nil, view); LogWork("present");`

Delete `M3Legacy()` and the `Legacy*` methods of `Metal3Backend`. `tools/gnm_replay/build.sh:20`: add `"$G/ps4_gnm_util_passes.mm"`.

- [ ] **Step 3: Check that no raw Metal 3 encoding is left in the renderer**

```bash
cd ~/ps4recomp-work/PS4Recomp-metal4 || exit 1
grep -nE "Legacy|renderCommandEncoderWithDescriptor|blitCommandEncoder|encodeSignalEvent|encodeWaitForEvent|commandBuffer\]|setVertex|setFragment|\[(enc|e|bl|S\.cenc|S\.renc) (set|draw|dispatch|copy|fill|memoryBarrier|endEncoding)" $G/ps4_gnm_draw.mm
```
Expected: only lines of the queue2 path (`GmEncoder`'s `[g_gmem.queue2 commandBuffer]` and `computeCommandEncoderWithDispatchType`, `GmSubmitWait`'s `[t.enc endEncoding]`, `EncodeCs`'s `forced` sends, `Binder`'s `raw` sends). Any other line is a site this phase missed: move it before committing.

- [ ] **Step 4: Build, R-check, host suite, TLOU run**

Replay build `t19`, R-check `t19 3`: `cmp=0`. Host suite `t19`: `host=0`. TLOU game build `t19`; route run `TAG=t19_helpers METAL=3 SECS=120`: `fatal 0 gpu_err 0 watchdog 0`, screenshots show gameplay.

- [ ] **Step 5: Commit**

```bash
git add $G/ps4_gnm_util_passes.h $G/ps4_gnm_util_passes.mm $G/ps4_gnm_draw.mm $G/ps4_gnm_backend_metal3.h tools/gnm_replay/build.sh
git commit -m "gnm: helper passes on BeginRender/Draw (FullscreenPass), utility MSL in its own file

SyncDepthSibling, SyncStorageToStencil, SyncStorageToDepth, DepthCompanion, DepthFromMemory,
EqaaCopy, ResolvePass and the present conversion are drawn with one FullscreenPass on the
backend; no raw Metal 3 encoding is left outside the guest memory re-run queue. Behaviour unchanged.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

### Task 1.10: Phase 1 gate

**Files:** `docs/metal4-baseline.md` (append "Phase 1"), `docs/metal4-backend.md` (Phase 1 state).

**Acceptance (spec table, Phase 1):** "Replay outputs byte-identical to Phase 0. Host suite green. TLOU route fps within noise (alternating builds, load ≤ 15). Allocations per draw not increased. Go analysis tools clean." Plus: `PS4_GNM_METAL=4` is a clear "not implemented" error.

- [ ] **Step 1: Replay byte identity on the full set**

Replay build `p1`; R-check `p1 3`. Expected: `cmp=0` on both frames.

- [ ] **Step 2: Host suite**

Host suite tag `p1`: `host=0`.

- [ ] **Step 3: `PS4_GNM_METAL=4` is a startup error**

```bash
FR=$(ls -d $M/captures/courtyard/frame_* | head -1)
PS4_GNM_METAL=4 $M/replay_p1/gnm_replay "$FR" 0 2>&1 | grep -m1 "FATAL"; echo rc=${PIPESTATUS[0]}
PS4_GNM_METAL=7 $M/replay_p1/gnm_replay "$FR" 0 2>&1 | grep -m1 "FATAL"
```
Expected: `[gnm-draw] FATAL: PS4_GNM_METAL=4: the Metal 4 backend is not implemented in this build; use PS4_GNM_METAL=3`, `rc=2`; `… PS4_GNM_METAL must be 3 or 4 (it is "7")`.

- [ ] **Step 4: Allocations per pass**

```bash
FR=$(ls -d $M/captures/courtyard/frame_* | head -1)
for k in 1 2 3; do for P in <D> <C>; do   # the passes recorded in docs/metal4-baseline.md
  DYLD_INSERT_LIBRARIES=$M/replay_p1/alloc_count.dylib $M/replay_p1/gnm_replay "$FR" $P --allocs 5 | tail -1
done; done
```
Expected: for each pass the minimum over the three rounds is ≤ the Phase 0 minimum. If it is higher, find the new allocation (run the pass under Instruments' Allocations template, or bisect the Phase 1 commits with the same command) and remove it before the gate passes.

- [ ] **Step 5: TLOU fps, alternating builds**

TLOU game build tag `p1`. Then:

```bash
N=3 A=$M/tlou_build_p0:3 B=$M/tlou_build_p1:3 TAG=p1_ab tools/metal4_perf_ab.sh | tee $M/ab_p1.txt
```
Expected: 3 kept runs per side, `|median B − median A| ≤ max(1.0, max_A − min_A)`; every kept run `fatal 0 gpu_err 0 watchdog 0`; skipped draws of B not above A's.

- [ ] **Step 6: Go analysis**

`go=0`.

- [ ] **Step 7: Record and commit**

Append to `docs/metal4-baseline.md`:

```markdown
## Phase 1 (seam, Metal 3 behind it), commit <hash>

- Replay: byte-identical to Phase 0 on both frames (<N> passes, <K> outputs each).
- Allocations per replayed pass: draw <D> <a1> (Phase 0 <a>), dispatch <C> <b1> (Phase 0 <b>).
- TLOU route A/B (Phase 0 build vs Phase 1 build, 3 alternating runs each): medians <x> / <y> fps,
  A spread <min>–<max>: within noise.
- Host suite green; go vet / gofmt / go test clean.
```

In `docs/metal4-backend.md` add under "Selection": "Until the Metal 4 backend exists (Phase 2), `PS4_GNM_METAL=4` stops at startup with "the Metal 4 backend is not implemented in this build"."

```bash
git add docs/metal4-baseline.md docs/metal4-backend.md
git commit -m "Metal 4 work: Phase 1 gate numbers (seam with Metal 3 behind it)

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

## Phase 2: Metal 4 queue, command buffers, clears, present

Phase 2 writes `Metal4Backend` up to what a clear-only frame and its present need. Methods of later phases abort with a message naming the task that implements them (`NotYet`); `kMetal4BackendCaps` excludes them, so `ChooseBackend` never lets a run reach them (a call would be a renderer bug, reported as such). Phase 4's gate checks that no `NotYet` is left.

### Task 2.1: `GnmResidency`

**Files:**
- Create: `$G/ps4_gnm_residency.h`, `$G/ps4_gnm_residency.mm`, `tests/host/gnm_residency_test.mm`
- Modify: `tests/host/run_host_tests.sh` (after `gnm_backend_select_test`), `tools/gnm_replay/build.sh:20`

**Interfaces:**
- Consumes: `GnmResidencyClass`, `kGnmResidencyClasses` (Task 1.1).
- Produces (`ps4_gnm_residency.h`):

```objc
// SPDX-License-Identifier: GPL-2.0-or-later
// PS4Recomp - residency sets of the Metal 4 backend (docs/metal4-backend.md, "Residency").
// Metal 4 makes nothing resident by itself: a no-copy buffer in no set has its GPU writes
// dropped without an error (the research's probe P4). Every allocation the GPU may touch is in
// one of kGnmResidencyClasses sets from its creation (Add) until every seq that may still use it
// has completed after its release (Remove(a, after_seq), then Retire(completed_seq)). The sets
// are added to the queue once; Commit() applies the changes and runs before every queue commit.
// GnmResidency holds a strong reference to every allocation it holds, so a release the renderer
// forgets shows as a leak (Count), never as a set entry of a freed object. Thread-safe.
#ifndef PS4_GNM_RESIDENCY_H
#define PS4_GNM_RESIDENCY_H

#include <deque>
#include <mutex>
#include <string>
#include <unordered_map>

#include "ps4_gnm_backend.h"

namespace ps4gnm {

class GnmResidency {
public:
    bool Init(id<MTLDevice> dev, std::string* why);
    id<MTLResidencySet> Set(GnmResidencyClass c) const { return sets_[(int)c]; }
    // Adds a to class c's set (again after a Remove whose seq has not completed: the removal is cancelled).
    void Add(id<MTLAllocation> a, GnmResidencyClass c);
    // a leaves its set at the first Retire with completed_seq >= after_seq. Unknown allocations: ignored.
    void Remove(id<MTLAllocation> a, uint64_t after_seq);
    void Retire(uint64_t completed_seq);
    void Commit(); // [set commit] for every changed set
    // In a set (held or waiting for its removal). A texture view counts as its parent texture,
    // a texture over a buffer as that buffer.
    bool Contains(id<MTLAllocation> a) const;
    size_t Count() const;        // allocations in the sets (held + waiting for removal)
    size_t PendingCount() const; // waiting for removal
    uint64_t AllocatedSize() const;

private:
    struct Entry {
        id<MTLAllocation> a;
        uint8_t cls;
        uint64_t remove_after; // 0: held; else the seq its removal waits for
    };
    mutable std::mutex mu_;
    id<MTLResidencySet> sets_[kGnmResidencyClasses] = {};
    bool dirty_[kGnmResidencyClasses] = {};
    std::unordered_map<const void*, Entry> entries_;
    std::deque<std::pair<const void*, uint64_t>> pending_; // (allocation, after_seq) in Remove order
};

} // namespace ps4gnm

#endif // PS4_GNM_RESIDENCY_H
```

- [ ] **Step 1: Write the failing test**

`tests/host/gnm_residency_test.mm` (this task's part; Tasks 3.1, 4.2 and 5.1 add cases):

```objc
// GnmResidency (ps4_gnm_residency.h): allocations stay in their set until the seq of their
// removal completed; a removal is cancelled by an Add before it completes; the set keeps a
// strong reference (an allocation released by its owner while in a set stays alive, and is freed
// once retired); texture views count as their parent. Later cases (GPU writes with and without
// the set, the bind-time check) are added by Tasks 3.1 and 5.1.
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>

#include <stdio.h>
#include <string.h>

#include "ps4_gnm_residency.h"

using namespace ps4gnm;

static int g_fail = 0;
#define CHECK(c, ...)                                                                 \
    do {                                                                              \
        if (!(c)) {                                                                   \
            fprintf(stderr, "gnm_residency_test: FAIL %s:%d: ", __FILE__, __LINE__);  \
            fprintf(stderr, __VA_ARGS__);                                             \
            fprintf(stderr, "\n");                                                    \
            g_fail++;                                                                 \
        }                                                                             \
    } while (0)

static void TestSetLogic(id<MTLDevice> dev) {
    GnmResidency r;
    std::string why;
    CHECK(r.Init(dev, &why), "Init: %s", why.c_str());
    id<MTLBuffer> a = [dev newBufferWithLength:65536 options:MTLResourceStorageModeShared];
    id<MTLBuffer> b = [dev newBufferWithLength:65536 options:MTLResourceStorageModeShared];
    MTLTextureDescriptor* td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm
                                                                                  width:64 height:64 mipmapped:NO];
    td.usage = MTLTextureUsageShaderRead | MTLTextureUsagePixelFormatView;
    id<MTLTexture> t = [dev newTextureWithDescriptor:td];
    r.Add(a, GnmResidencyClass::Guest);
    r.Add(b, GnmResidencyClass::Builtin);
    r.Add(t, GnmResidencyClass::Texture);
    r.Commit();
    CHECK(r.Count() == 3 && r.PendingCount() == 0, "count %zu pending %zu", r.Count(), r.PendingCount());
    CHECK(r.Contains(a) && r.Contains(b) && r.Contains(t), "added allocations not contained");
    CHECK([r.Set(GnmResidencyClass::Guest) containsAllocation:a] && ![r.Set(GnmResidencyClass::Guest) containsAllocation:b],
          "an allocation is in its class's set only");
    CHECK(r.AllocatedSize() > 0, "allocatedSize 0 after commit");
    id<MTLTexture> view = [t newTextureViewWithPixelFormat:MTLPixelFormatRGBA8Unorm_sRGB];
    CHECK(r.Contains(view), "a view of a resident texture counts as resident");
    // deferred removal
    r.Remove(a, 5);
    CHECK(r.Contains(a) && r.PendingCount() == 1, "removed before its seq completed");
    r.Retire(4);
    CHECK(r.Contains(a), "retired at seq 4 for a removal after seq 5");
    r.Retire(5);
    CHECK(!r.Contains(a) && r.Count() == 2, "not retired at seq 5 (count %zu)", r.Count());
    r.Commit();
    CHECK(![r.Set(GnmResidencyClass::Guest) containsAllocation:a], "still in the Metal set after retire + commit");
    // a removal cancelled by an Add before it completed
    r.Remove(b, 8);
    r.Add(b, GnmResidencyClass::Builtin);
    r.Retire(9);
    CHECK(r.Contains(b) && r.PendingCount() == 0, "re-added allocation removed by its old removal");
    r.Remove(id<MTLBuffer>([dev newBufferWithLength:16 options:0]), 1); // unknown: ignored
    CHECK(r.Count() == 2, "unknown removal changed the count");
}

// The strong reference: an allocation whose owner let it go stays alive while in a set and is
// freed when it is retired.
static void TestStrongReference(id<MTLDevice> dev) {
    GnmResidency r;
    std::string why;
    r.Init(dev, &why);
    __weak id<MTLBuffer> weak = nil;
    @autoreleasepool {
        id<MTLBuffer> x = [dev newBufferWithLength:4096 options:MTLResourceStorageModeShared];
        weak = x;
        r.Add(x, GnmResidencyClass::Guest);
        r.Remove(x, 1);
    }
    CHECK(weak != nil, "an allocation waiting for its removal was freed");
    @autoreleasepool {
        r.Retire(1);
    }
    CHECK(weak == nil, "a retired allocation is still alive (the set holds it)");
}

int main(int argc, char** argv) {
    (void)argc;
    (void)argv;
    @autoreleasepool {
        id<MTLDevice> dev = MTLCreateSystemDefaultDevice();
        if (!dev) {
            printf("gnm_residency_test: FAIL: no Metal device\n");
            return 1;
        }
        TestSetLogic(dev);
        TestStrongReference(dev);
    }
    printf("gnm_residency_test: %s\n", g_fail ? "FAIL" : "PASS");
    return g_fail ? 1 : 0;
}
```

(The `weak == nil` check after retire depends on the residency set itself not retaining the buffer after `removeAllocation:` + `commit`; `Retire` commits nothing, so call `r.Commit()` inside that second pool too, before the check.)

- [ ] **Step 2: Run it to verify it fails**

`clang++ -std=c++17 -fobjc-arc -Wall -Werror -I $G tests/host/gnm_residency_test.mm -framework Metal -framework Foundation -o $T/r` → Expected: `'ps4_gnm_residency.h' file not found`.

- [ ] **Step 3: Implement `ps4_gnm_residency.mm`**

```objc
// SPDX-License-Identifier: GPL-2.0-or-later
// PS4Recomp - residency sets of the Metal 4 backend (ps4_gnm_residency.h).
#include "ps4_gnm_residency.h"

namespace ps4gnm {

static const char* const kSetNames[kGnmResidencyClasses] = {"gnm guest memory", "gnm textures", "gnm built-ins"};

bool GnmResidency::Init(id<MTLDevice> dev, std::string* why) {
    for (int i = 0; i < kGnmResidencyClasses; ++i) {
        MTLResidencySetDescriptor* d = [MTLResidencySetDescriptor new];
        d.label = [NSString stringWithUTF8String:kSetNames[i]];
        d.initialCapacity = 256;
        NSError* err = nil;
        sets_[i] = [dev newResidencySetWithDescriptor:d error:&err];
        if (!sets_[i]) {
            if (why) *why = err ? err.localizedDescription.UTF8String : "newResidencySetWithDescriptor failed";
            return false;
        }
    }
    return true;
}

void GnmResidency::Add(id<MTLAllocation> a, GnmResidencyClass c) {
    if (!a) return;
    std::lock_guard<std::mutex> lk(mu_);
    const void* k = (__bridge const void*)a;
    auto it = entries_.find(k);
    if (it != entries_.end()) {
        it->second.remove_after = 0; // a pending removal is cancelled (its pending_ record is skipped)
        return;
    }
    entries_.emplace(k, Entry{a, (uint8_t)c, 0});
    [sets_[(int)c] addAllocation:a];
    dirty_[(int)c] = true;
}

void GnmResidency::Remove(id<MTLAllocation> a, uint64_t after_seq) {
    if (!a) return;
    std::lock_guard<std::mutex> lk(mu_);
    auto it = entries_.find((__bridge const void*)a);
    if (it == entries_.end()) return;
    it->second.remove_after = std::max<uint64_t>(after_seq, 1);
    pending_.emplace_back(it->first, it->second.remove_after);
}

void GnmResidency::Retire(uint64_t completed_seq) {
    std::lock_guard<std::mutex> lk(mu_);
    while (!pending_.empty() && pending_.front().second <= completed_seq) {
        auto it = entries_.find(pending_.front().first);
        // skipped: re-added (remove_after 0) or removed again later (another record follows)
        if (it != entries_.end() && it->second.remove_after == pending_.front().second) {
            [sets_[it->second.cls] removeAllocation:it->second.a];
            dirty_[it->second.cls] = true;
            entries_.erase(it);
        }
        pending_.pop_front();
    }
}

void GnmResidency::Commit() {
    std::lock_guard<std::mutex> lk(mu_);
    for (int i = 0; i < kGnmResidencyClasses; ++i)
        if (dirty_[i]) {
            [sets_[i] commit];
            dirty_[i] = false;
        }
}

bool GnmResidency::Contains(id<MTLAllocation> a) const {
    if (!a) return false;
    id<MTLAllocation> base = a;
    if ([(id)a conformsToProtocol:@protocol(MTLTexture)]) {
        id<MTLTexture> t = (id<MTLTexture>)a;
        if (t.parentTexture) base = t.parentTexture;
        else if (t.buffer) base = t.buffer;
    }
    std::lock_guard<std::mutex> lk(mu_);
    return entries_.count((__bridge const void*)base) != 0;
}

size_t GnmResidency::Count() const {
    std::lock_guard<std::mutex> lk(mu_);
    return entries_.size();
}

size_t GnmResidency::PendingCount() const {
    std::lock_guard<std::mutex> lk(mu_);
    size_t n = 0;
    for (auto& [k, e] : entries_) n += e.remove_after != 0;
    return n;
}

uint64_t GnmResidency::AllocatedSize() const {
    std::lock_guard<std::mutex> lk(mu_);
    uint64_t n = 0;
    for (int i = 0; i < kGnmResidencyClasses; ++i) n += sets_[i].allocatedSize;
    return n;
}

} // namespace ps4gnm
```

(`#include <algorithm>` for `std::max`. A view of a view: `parentTexture` is the original texture, Metal resolves the chain.)

`run_host_tests.sh`, after `gnm_backend_select_test`:

```bash
# Residency sets of the Metal 4 backend (ps4_gnm_residency.h): deferred removal, cancellation,
# strong references, views.
clang++ -std=c++17 -fobjc-arc -Wall -Werror -I "$G" "$R/tests/host/gnm_residency_test.mm" "$G/ps4_gnm_residency.mm" \
  -framework Metal -framework Foundation -o "$T/gnm_residency_test"
gpu "$T/gnm_residency_test"
```

`tools/gnm_replay/build.sh:20`: add `"$G/ps4_gnm_residency.mm"`.

- [ ] **Step 4: Run it to verify it passes**

Build and run as in Step 2 with `$G/ps4_gnm_residency.mm` added → Expected `gnm_residency_test: PASS`.

- [ ] **Step 5: Host suite, commit**

Host suite `t21`: `host=0`.

```bash
git add $G/ps4_gnm_residency.h $G/ps4_gnm_residency.mm tests/host/gnm_residency_test.mm tests/host/run_host_tests.sh tools/gnm_replay/build.sh
git commit -m "gnm: GnmResidency, residency sets with removal deferred to a seq

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

### Task 2.2: `Metal4Backend`: queue, allocator ring, timeline, feedback

**Files:**
- Create: `$G/ps4_gnm_backend_metal4.h`, `$G/ps4_gnm_backend_metal4.mm`, `tests/host/backend_harness.h`, `tests/host/gnm_backend_cmd_test.mm`
- Modify: `$G/ps4_gnm_backend.h` (declare `MakeMetal4Backend`), `$G/ps4_gnm_backend.mm` (delete the `kMetal4BackendCaps` definition), `tools/gnm_replay/build.sh:20`, `tests/host/run_host_tests.sh`

**Interfaces:**
- Consumes: `GnmBackend`, `GnmResidency`.
- Produces:
  - `std::unique_ptr<GnmBackend> MakeMetal4Backend();` (in `ps4_gnm_backend.h`);
  - `const uint32_t kMetal4BackendCaps = 0;` now in `ps4_gnm_backend_metal4.mm` (Task 2.3 sets `kGnmCapClears`);
  - `class Metal4Backend final : public GnmBackend` with, beyond the interface, `GnmResidency& Residency();` (tests);
  - `tests/host/backend_harness.h`: `std::unique_ptr<ps4gnm::GnmBackend> MakeTestBackend(id<MTLDevice> dev, std::string* why);` (the backend `PS4_GNM_METAL` names, `3` when unset) and `bool RequireMetal4(id<MTLDevice> dev, const char* test);` (true on a Metal 4-family GPU; on any other GPU prints `<test>: SKIP: no MTLGPUFamilyMetal4` and the caller exits 0 — the only allowed skip).

`$G/ps4_gnm_backend_metal4.h`:

```objc
// SPDX-License-Identifier: GPL-2.0-or-later
// PS4Recomp - the Metal 4 renderer backend (ps4_gnm_backend.h, docs/metal4-backend.md):
// MTL4CommandQueue; one or more MTL4CommandBuffers per seq (split at queue-level events), each
// with a command allocator that is reset only after its seq completed; a timeline MTLSharedEvent
// signalled with each seq after its last commit (CompletedSeq); commit feedback for errors and
// GPU times; argument tables per target and stage; a bytes arena for setBytes; a barrier at each
// encoder start; copies and fills on compute encoders; residency sets (GnmResidency).
#ifndef PS4_GNM_BACKEND_METAL4_H
#define PS4_GNM_BACKEND_METAL4_H

#include <atomic>
#include <deque>
#include <mutex>
#include <unordered_map>
#include <utility>
#include <vector>

#include "ps4_gnm_backend.h"
#include "ps4_gnm_residency.h"

namespace ps4gnm {

class Metal4Backend final : public GnmBackend {
public:
    Metal4Backend();
    GnmBackendKind Kind() const override { return GnmBackendKind::Metal4; }
    uint32_t Caps() const override { return kMetal4BackendCaps; }
    bool Init(id<MTLDevice> dev, std::string* why) override;
    id<MTLDevice> Device() const override { return dev_; }
    id<MTLCommandQueue> SideQueue() const override { return side_queue_; }

    void BeginCmd(GnmCmdTarget t, NSString* label, bool encoder_status) override;
    bool CmdOpen(GnmCmdTarget t) const override { return t_[(int)t].cb != nil; }
    void UseTarget(GnmCmdTarget t) override { cur_ = t; }
    GnmCmdTarget Target() const override { return cur_; }
    void CommitUpload() override;
    void Commit(uint64_t seq, GnmCompletionFn done, void* ctx) override;
    uint64_t CompletedSeq() const override { return timeline_.signaledValue; }
    bool WaitForRoom(uint64_t committed, uint64_t max_outstanding, double timeout_ms) override;
    void QueueSignal(id<MTLSharedEvent> ev, uint64_t value) override;
    void QueueWait(id<MTLSharedEvent> ev, uint64_t value) override;

    GnmEncoder OpenEncoder() const override { return t_[(int)cur_].open; }
    uint64_t EncoderSerial() const override { return serial_; }
    bool BeginRender(const GnmPassDesc& d) override;
    void BeginCompute(bool serial) override;
    void BeginCopies() override;
    void EndEncoder() override;
    void SetEncoderLabel(NSString* label) override;
    void Barrier(uint32_t after, uint32_t before, uint8_t scope) override;

    void SetRenderPipeline(id<MTLRenderPipelineState> p) override;
    void SetDepthStencil(id<MTLDepthStencilState> d) override;
    void SetFixed(const GnmFixedState& f, uint32_t changed) override;
    void SetComputePipeline(id<MTLComputePipelineState> p) override;

    void Draw(const GnmDraw& d) override;
    void Dispatch(MTLSize groups, MTLSize tpt) override;
    void DispatchThreads(MTLSize threads, MTLSize tpt) override;
    void DispatchIndirect(id<MTLBuffer> args, uint64_t off, MTLSize tpt) override;
    void CopyBuffer(id<MTLBuffer> src, uint64_t src_off, id<MTLBuffer> dst, uint64_t dst_off, uint64_t n) override;
    void FillBuffer(id<MTLBuffer> dst, uint64_t off, uint64_t n, uint8_t value) override;
    void CopyTexture(id<MTLTexture> src, id<MTLTexture> dst) override;
    void CopyTextureRegion(id<MTLTexture> src, uint32_t src_slice, uint32_t src_level, MTLOrigin src_origin, MTLSize size,
                           id<MTLTexture> dst, uint32_t dst_slice, uint32_t dst_level, MTLOrigin dst_origin) override;
    void CopyBufferToTexture(id<MTLBuffer> src, uint64_t src_off, uint64_t row_bytes, uint64_t image_bytes, MTLSize size,
                             id<MTLTexture> dst, uint32_t slice, uint32_t level, MTLOrigin origin) override;

    void MakeResident(id<MTLAllocation> a, GnmResidencyClass c) override { res_.Add(a, c); }
    void Evict(id<MTLAllocation> a, uint64_t after_seq) override { res_.Remove(a, after_seq); }
    bool IsResident(id<MTLAllocation> a) const override { return res_.Contains(a); }
    GnmBackendStats Stats() const override;

    GnmResidency& Residency() { return res_; }

private:
    struct Part { // a command buffer object and its allocator, reused together after their seq completed
        id<MTL4CommandBuffer> cb = nil;
        id<MTL4CommandAllocator> alloc = nil;
    };
    struct Target {
        id<MTL4CommandBuffer> cb = nil; // open (between beginCommandBuffer and the commit)
        Part part;
        id<MTL4RenderCommandEncoder> renc = nil;
        id<MTL4ComputeCommandEncoder> cenc = nil;
        GnmEncoder open = GnmEncoder::None;
        bool work = false; // an encoder was opened since the part began
        id<MTL4ArgumentTable> table[3] = {}; // GnmStage order
        uint64_t base[3][31] = {};           // gpuAddress bound at each buffer slot (BindBufferOffset)
        // QueueSignal after work not committed yet: issued right after this part's commit
        std::vector<std::pair<id<MTLSharedEvent>, uint64_t>> signals;
    };
    struct SeqRec { // the commits of one seq and their feedback
        uint32_t parts = 0, done = 0;
        bool final = false, failed = false;
        double start = 0, end = 0;
        NSError* error = nil;
        GnmCompletionFn fn = nullptr;
        void* ctx = nullptr;
    };
    Target& Cur() { return t_[(int)cur_]; }
    const Target& Cur() const { return t_[(int)cur_]; }
    void Recycle();                       // allocators, command buffers and bytes chunks of completed seqs
    Part AcquirePart();
    void BeginPart(GnmCmdTarget t, NSString* label);
    // Ends and commits the open command buffers (upload first; main only if with_main) as one more
    // part of the open seq; final: the seq's last part (then the timeline is signalled with it).
    void Submit(bool final, bool with_main, GnmCompletionFn fn, void* ctx);
    void Split();                         // Task 2.3: commit and reopen every open target inside the seq
    void OnFeedback(uint64_t seq, id<MTL4CommitFeedback> fb);
    void BeforeWork();                    // Task 2.3: a split for signals waiting on the current target
    static void OpBuffer(GnmBackend* b, GnmStage st, uint32_t slot, __unsafe_unretained id<MTLBuffer> buf, uint64_t off);
    static void OpBufferOffset(GnmBackend* b, GnmStage st, uint32_t slot, uint64_t off);
    static void OpBytes(GnmBackend* b, GnmStage st, uint32_t slot, const void* p, size_t n);
    static void OpTexture(GnmBackend* b, GnmStage st, uint32_t slot, __unsafe_unretained id<MTLTexture> t);
    static void OpSampler(GnmBackend* b, GnmStage st, uint32_t slot, __unsafe_unretained id<MTLSamplerState> s);
    static void OpUse(GnmBackend* b, GnmStage st, __unsafe_unretained id<MTLBuffer> buf, bool written);
    uint64_t BytesAddress(const void* p, size_t n); // Task 2.3: the bytes arena

    id<MTLDevice> dev_ = nil;
    id<MTL4CommandQueue> queue_ = nil;
    id<MTLCommandQueue> side_queue_ = nil;
    id<MTLSharedEvent> timeline_ = nil;
    dispatch_queue_t feedback_q_ = nullptr;
    GnmResidency res_;
    Target t_[2];
    GnmCmdTarget cur_ = GnmCmdTarget::Main;
    uint64_t serial_ = 0;
    uint64_t last_seq_ = 0; // the last seq committed (Commit); open_seq_ = last_seq_ + 1
    uint64_t open_seq() const { return last_seq_ + 1; }
    std::deque<std::pair<Part, uint64_t>> busy_; // parts of uncompleted seqs, in seq order
    std::vector<Part> free_;
    std::mutex seq_mu_;
    std::unordered_map<uint64_t, SeqRec> seqs_;
    // bytes arena (Task 2.3)
    struct Chunk {
        id<MTLBuffer> buf = nil;
        uint64_t last_seq = 0;
    };
    Chunk chunk_;
    size_t chunk_used_ = 0;
    std::deque<Chunk> chunks_busy_;
    std::vector<id<MTLBuffer>> chunks_free_;
    bool full_barriers_ = false, no_barriers_ = false;
    std::atomic<uint64_t> commits_{0}, split_commits_{0}, allocators_{0}, resets_{0};
};

} // namespace ps4gnm

#endif // PS4_GNM_BACKEND_METAL4_H
```

- [ ] **Step 1: Write the test harness and the failing test**

`tests/host/backend_harness.h`:

```objc
// Host tests that drive a renderer backend directly: the backend PS4_GNM_METAL names (3 when
// unset), and the one allowed skip (a Metal 4 test on a GPU without MTLGPUFamilyMetal4).
#pragma once
#import <Metal/Metal.h>

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <memory>
#include <string>

#include "ps4_gnm_backend.h"

inline bool RequireMetal4(id<MTLDevice> dev, const char* test) {
    if ([dev supportsFamily:MTLGPUFamilyMetal4]) return true;
    printf("%s: SKIP: no MTLGPUFamilyMetal4 on %s\n", test, dev.name.UTF8String);
    return false;
}

// nullptr (why set) if the named backend cannot run here; on a Metal 4-family GPU "4" always runs.
inline std::unique_ptr<ps4gnm::GnmBackend> MakeTestBackend(id<MTLDevice> dev, std::string* why) {
    const char* e = getenv("PS4_GNM_METAL");
    std::unique_ptr<ps4gnm::GnmBackend> be;
    if (e && !strcmp(e, "4")) {
        if (![dev supportsFamily:MTLGPUFamilyMetal4]) {
            *why = "PS4_GNM_METAL=4 on a GPU without MTLGPUFamilyMetal4";
            return nullptr;
        }
        be = ps4gnm::MakeMetal4Backend();
    } else {
        be = ps4gnm::MakeMetal3Backend();
    }
    if (!be->Init(dev, why)) return nullptr;
    return be;
}

// Commits seq and waits (5 s) for its completion; false on failure or timeout.
inline bool CommitAndWait(ps4gnm::GnmBackend& be, uint64_t seq) {
    struct Done {
        dispatch_semaphore_t sem = dispatch_semaphore_create(0);
        bool failed = false;
    };
    auto* d = new Done; // freed by the completion (a timed-out one leaks it; the test fails anyway)
    be.Commit(seq, [](void* p, const ps4gnm::GnmCompletion& c) {
        Done* x = static_cast<Done*>(p);
        x->failed = c.failed;
        dispatch_semaphore_signal(x->sem);
    }, d);
    if (dispatch_semaphore_wait(d->sem, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC)) != 0) return false;
    const bool ok = !d->failed;
    delete d;
    return ok;
}
```

(The completion lambda frees nothing; `CommitAndWait` deletes after the wait. `MakeMetal4Backend` is declared in `ps4_gnm_backend.h` by this task.)

`tests/host/gnm_backend_cmd_test.mm`:

```objc
// Command buffers and the seq timeline on the backend PS4_GNM_METAL selects (both run it):
//  - queue-level events in order: a signal before a wait happens before the wait is satisfied,
//    work after the wait waits for it, and the seq completes once (Metal 3 encodes the events
//    into the command buffer; Metal 4 issues them on the queue);
//  - Metal 4 only: a command allocator is reused only after its seq completed, the allocator
//    memory stays bounded over 1000 seqs, and WaitForRoom reports a GPU that makes no progress.
// Task 2.3 adds the split of a seq at an event between two render passes.
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>

#include "backend_harness.h"
#include "ps4_gnm_backend_metal4.h"

using namespace ps4gnm;

static int g_fail = 0;
#define CHECK(c, ...)                                                                    \
    do {                                                                                 \
        if (!(c)) {                                                                      \
            fprintf(stderr, "gnm_backend_cmd_test: FAIL %s:%d: ", __FILE__, __LINE__);   \
            fprintf(stderr, __VA_ARGS__);                                                \
            fprintf(stderr, "\n");                                                       \
            g_fail++;                                                                    \
        }                                                                                \
    } while (0)

static uint64_t g_seq = 0;

static void TestEventOrder(id<MTLDevice> dev, GnmBackend& be) {
    id<MTLSharedEvent> a = [dev newSharedEvent], gate = [dev newSharedEvent], c = [dev newSharedEvent];
    be.BeginCmd(GnmCmdTarget::Main, @"events", false);
    be.QueueSignal(a, 1);
    be.QueueWait(gate, 1);
    be.QueueSignal(c, 1);
    const uint64_t seq = ++g_seq;
    std::atomic<int> calls{0};
    be.Commit(seq, [](void* p, const GnmCompletion&) { static_cast<std::atomic<int>*>(p)->fetch_add(1); }, &calls);
    CHECK([a waitUntilSignaledValue:1 timeoutMS:2000], "the signal before the wait did not happen");
    usleep(200000);
    CHECK(c.signaledValue == 0, "work after a wait for an unsignalled event ran");
    CHECK(be.CompletedSeq() < seq, "seq %llu completed before its wait was satisfied", (unsigned long long)seq);
    gate.signaledValue = 1;
    CHECK([c waitUntilSignaledValue:1 timeoutMS:2000], "the signal after the wait did not happen");
    for (int i = 0; i < 200 && be.CompletedSeq() < seq; ++i) usleep(10000);
    CHECK(be.CompletedSeq() >= seq, "seq not complete after its wait was satisfied");
    for (int i = 0; i < 200 && calls.load() == 0; ++i) usleep(10000);
    CHECK(calls.load() == 1, "completion called %d times", calls.load());
}

// Metal 4: allocator reuse only after completion; bounded allocator memory.
static void TestAllocators(id<MTLDevice> dev, Metal4Backend& be) {
    id<MTLSharedEvent> gate = [dev newSharedEvent];
    const GnmBackendStats s0 = be.Stats();
    be.BeginCmd(GnmCmdTarget::Main, @"held", false);
    be.QueueWait(gate, 1); // everything committed from here on waits for the gate
    const uint64_t held = ++g_seq;
    be.Commit(held, [](void*, const GnmCompletion&) {}, nullptr);
    be.BeginCmd(GnmCmdTarget::Main, @"behind", false);
    const uint64_t behind = ++g_seq;
    be.Commit(behind, [](void*, const GnmCompletion&) {}, nullptr);
    be.BeginCmd(GnmCmdTarget::Main, @"third", false);
    const GnmBackendStats s1 = be.Stats();
    CHECK(s1.allocator_resets == s0.allocator_resets, "an allocator was reset while its seq had not completed");
    CHECK(s1.allocators >= s0.allocators + 2 || s0.allocators >= 3, "no new allocators while the earlier ones are in use");
    gate.signaledValue = 1;
    const uint64_t third = ++g_seq;
    CHECK(CommitAndWait(be, third), "seq %llu failed", (unsigned long long)third);
    be.BeginCmd(GnmCmdTarget::Main, @"reuse", false);
    const GnmBackendStats s2 = be.Stats();
    CHECK(s2.allocator_resets > s1.allocator_resets, "no allocator reused after its seq completed");
    CHECK(CommitAndWait(be, ++g_seq), "reuse seq failed");
    const uint64_t n0 = be.Stats().allocators;
    for (int i = 0; i < 1000; ++i) {
        be.BeginCmd(GnmCmdTarget::Main, nil, false);
        if (i % 100 == 99) CHECK(CommitAndWait(be, ++g_seq), "seq of loop %d failed", i);
        else be.Commit(++g_seq, [](void*, const GnmCompletion&) {}, nullptr);
    }
    const GnmBackendStats s3 = be.Stats();
    CHECK(s3.allocators - n0 <= kGnmMaxCommandBuffers, "%llu allocators created for 1000 seqs",
          (unsigned long long)(s3.allocators - n0));
}

// Metal 4: WaitForRoom gives up on a GPU that completes nothing.
static void TestWaitForRoom(id<MTLDevice> dev, Metal4Backend& be) {
    id<MTLSharedEvent> gate = [dev newSharedEvent];
    const uint64_t first = g_seq + 1;
    be.BeginCmd(GnmCmdTarget::Main, @"stalled", false);
    be.QueueWait(gate, 1);
    be.Commit(++g_seq, [](void*, const GnmCompletion&) {}, nullptr);
    for (uint64_t i = 1; i < 4; ++i) {
        be.BeginCmd(GnmCmdTarget::Main, nil, false);
        be.Commit(++g_seq, [](void*, const GnmCompletion&) {}, nullptr);
    }
    CHECK(!be.WaitForRoom(g_seq, 4, 300), "WaitForRoom returned with 4 of 4 seqs stalled");
    gate.signaledValue = 1;
    CHECK(be.WaitForRoom(g_seq, 4, 2000), "WaitForRoom timed out after the GPU went on");
    CHECK(be.CompletedSeq() >= first, "no progress");
}

int main() {
    @autoreleasepool {
        id<MTLDevice> dev = MTLCreateSystemDefaultDevice();
        std::string why;
        std::unique_ptr<GnmBackend> be = dev ? MakeTestBackend(dev, &why) : nullptr;
        if (!be) {
            printf("gnm_backend_cmd_test: FAIL: no backend: %s\n", why.c_str());
            return 1;
        }
        printf("gnm_backend_cmd_test: backend %s\n", BackendName(be->Kind()));
        TestEventOrder(dev, *be);
        if (be->Kind() == GnmBackendKind::Metal4) {
            TestAllocators(dev, static_cast<Metal4Backend&>(*be));
            TestWaitForRoom(dev, static_cast<Metal4Backend&>(*be));
        }
    }
    printf("gnm_backend_cmd_test: %s\n", g_fail ? "FAIL" : "PASS");
    return g_fail ? 1 : 0;
}
```

(`#include <atomic>` and `<unistd.h>`.)

- [ ] **Step 2: Run it to verify it fails**

```bash
BE="$G/ps4_gnm_backend.mm $G/ps4_gnm_backend_metal3.mm $G/ps4_gnm_backend_metal4.mm $G/ps4_gnm_residency.mm"
clang++ -std=c++17 -fobjc-arc -Wall -Werror -I $G -I tests/host tests/host/gnm_backend_cmd_test.mm $BE -framework Metal -framework Foundation -o $T/c 2>&1 | head -3
```
Expected: `'ps4_gnm_backend_metal4.h' file not found` (and the missing `.mm`).

- [ ] **Step 3: Implement `ps4_gnm_backend_metal4.mm` (this task's part)**

```objc
// SPDX-License-Identifier: GPL-2.0-or-later
// PS4Recomp - the Metal 4 renderer backend (ps4_gnm_backend_metal4.h).
#include "ps4_gnm_backend_metal4.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

namespace ps4gnm {

// What this backend implements so far (Tasks 2.3, 3.1, 3.2, 4.1 add to it).
const uint32_t kMetal4BackendCaps = 0;

std::unique_ptr<GnmBackend> MakeMetal4Backend() { return std::make_unique<Metal4Backend>(); }

// A method of a later task. kMetal4BackendCaps excludes it, so ChooseBackend never runs the renderer
// where it is called: reaching it is a renderer bug.
[[noreturn]] static void NotYet(const char* what, const char* task) {
    fprintf(stderr, "[gnm-draw] FATAL: Metal4Backend::%s is not implemented yet (%s of the Metal 4 plan); "
                    "kMetal4BackendCaps excludes it, so this call is a renderer bug\n", what, task);
    abort();
}

static bool EnvOn(const char* name) {
    const char* v = getenv(name);
    return v && !strcmp(v, "1");
}

Metal4Backend::Metal4Backend() {
    ops_.buffer = OpBuffer;
    ops_.buffer_offset = OpBufferOffset;
    ops_.bytes = OpBytes;
    ops_.texture = OpTexture;
    ops_.sampler = OpSampler;
    ops_.use = OpUse;
}

bool Metal4Backend::Init(id<MTLDevice> dev, std::string* why) {
    dev_ = dev;
    if (![dev supportsFamily:MTLGPUFamilyMetal4]) {
        if (why) *why = "the GPU does not support MTLGPUFamilyMetal4";
        return false;
    }
    feedback_q_ = dispatch_queue_create("gnm.mtl4.feedback",
                                        dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL, QOS_CLASS_USER_INTERACTIVE, 0));
    MTL4CommandQueueDescriptor* qd = [MTL4CommandQueueDescriptor new];
    qd.label = @"gnm";
    qd.feedbackQueue = feedback_q_;
    NSError* err = nil;
    queue_ = [dev newMTL4CommandQueueWithDescriptor:qd error:&err];
    if (!queue_) {
        if (why) *why = err ? err.localizedDescription.UTF8String : "newMTL4CommandQueueWithDescriptor failed";
        return false;
    }
    side_queue_ = [dev newCommandQueue];
    side_queue_.label = @"gnm side (Metal 3)";
    timeline_ = [dev newSharedEvent];
    timeline_.label = @"gnm timeline";
    if (!res_.Init(dev, why)) return false;
    for (int c = 0; c < kGnmResidencyClasses; ++c) [queue_ addResidencySet:res_.Set((GnmResidencyClass)c)];
    MTL4ArgumentTableDescriptor* ad = [MTL4ArgumentTableDescriptor new];
    ad.maxBufferBindCount = 31;
    ad.maxTextureBindCount = 128;
    ad.maxSamplerStateBindCount = 16;
    for (auto& t : t_)
        for (auto& tab : t.table) {
            tab = [dev newArgumentTableWithDescriptor:ad error:&err];
            if (!tab) {
                if (why) *why = err ? err.localizedDescription.UTF8String : "newArgumentTableWithDescriptor failed";
                return false;
            }
        }
    full_barriers_ = EnvOn("PS4_GNM_MTL4_FULL_BARRIERS");
    no_barriers_ = EnvOn("PS4_GNM_MTL4_NO_BARRIERS");
    return true;
}

void Metal4Backend::Recycle() {
    const uint64_t done = CompletedSeq();
    while (!busy_.empty() && busy_.front().second <= done) {
        [busy_.front().first.alloc reset];
        resets_.fetch_add(1, std::memory_order_relaxed);
        free_.push_back(busy_.front().first);
        busy_.pop_front();
    }
    while (!chunks_busy_.empty() && chunks_busy_.front().last_seq <= done) {
        chunks_free_.push_back(chunks_busy_.front().buf);
        chunks_busy_.pop_front();
    }
    res_.Retire(done);
}

Metal4Backend::Part Metal4Backend::AcquirePart() {
    Recycle();
    if (!free_.empty()) {
        Part p = free_.back();
        free_.pop_back();
        return p;
    }
    Part p;
    p.cb = [dev_ newCommandBuffer];
    p.alloc = [dev_ newCommandAllocator];
    allocators_.fetch_add(1, std::memory_order_relaxed);
    return p;
}

void Metal4Backend::BeginPart(GnmCmdTarget t, NSString* label) {
    Target& x = t_[(int)t];
    x.part = AcquirePart();
    x.cb = x.part.cb;
    [x.cb beginCommandBufferWithAllocator:x.part.alloc];
    x.cb.label = label;
    x.work = false;
}

// encoder_status: Metal 4 has no per-encoder status (MTL4CommandBufferOptions holds only a log
// state); the renderer warns once at startup that PS4_GNM_ENCODER_STATUS is Metal 3 only.
void Metal4Backend::BeginCmd(GnmCmdTarget t, NSString* label, bool) { BeginPart(t, label); }

void Metal4Backend::OnFeedback(uint64_t seq, id<MTL4CommitFeedback> fb) {
    GnmCompletionFn fn = nullptr;
    void* ctx = nullptr;
    NSError* err = nil; // strong: keeps the error alive for the call below
    GnmCompletion c;
    {
        std::lock_guard<std::mutex> lk(seq_mu_);
        SeqRec& r = seqs_[seq];
        r.done++;
        if (fb.error && !r.error) r.error = fb.error;
        r.failed |= fb.error != nil;
        if (fb.GPUStartTime > 0 && (r.start == 0 || fb.GPUStartTime < r.start)) r.start = fb.GPUStartTime;
        r.end = std::max(r.end, (double)fb.GPUEndTime);
        if (!r.final || r.done < r.parts) return;
        fn = r.fn;
        ctx = r.ctx;
        err = r.error;
        c.seq = seq;
        c.failed = r.failed;
        c.gpu_start = r.start;
        c.gpu_end = r.end;
        seqs_.erase(seq);
    }
    c.error = err;
    if (fn) fn(ctx, c); // outside seq_mu_: the callback may commit, wait or take the renderer's locks
}

// Ends and commits the open command buffers as one more part of the open seq, the upload one first
// (its copies run before the main command buffer's work: one commit array is executed in order);
// with_main = false leaves the main command buffer open (CommitUpload). The queue signals deferred
// by QueueSignal for the committed targets follow the commit. final: the seq's last part; the
// timeline is signalled with the seq after it and its completion runs when every part's feedback
// arrived. Encoders must have been ended by the caller (FATAL otherwise: ending one here would
// leave the renderer's encoder state stale).
void Metal4Backend::Submit(bool final, bool with_main, GnmCompletionFn fn, void* ctx) {
    const uint64_t seq = open_seq();
    id<MTL4CommandBuffer> list[2];
    NSUInteger n = 0;
    bool committed[2] = {false, false};
    for (GnmCmdTarget t : {GnmCmdTarget::Upload, GnmCmdTarget::Main}) {
        Target& x = t_[(int)t];
        if (!x.cb || (t == GnmCmdTarget::Main && !with_main)) continue;
        if (x.open != GnmEncoder::None) {
            fprintf(stderr, "[gnm-draw] FATAL: Metal4Backend: a commit of seq %llu with an open encoder (%s target)\n",
                    (unsigned long long)seq, t == GnmCmdTarget::Main ? "main" : "upload");
            abort();
        }
        [x.cb endCommandBuffer];
        list[n++] = x.cb;
        busy_.emplace_back(x.part, seq);
        x.cb = nil;
        x.part = Part{};
        committed[(int)t] = true;
    }
    {
        std::lock_guard<std::mutex> lk(seq_mu_);
        SeqRec& r = seqs_[seq];
        if (n) r.parts++;
        if (final) {
            r.final = true;
            r.fn = fn;
            r.ctx = ctx;
        }
    }
    res_.Commit(); // every allocation the parts use is in a set before the queue sees them
    if (n) {
        MTL4CommitOptions* opts = [MTL4CommitOptions new];
        [opts addFeedbackHandler:^(id<MTL4CommitFeedback> fb) { OnFeedback(seq, fb); }];
        [queue_ commit:list count:n options:opts];
        commits_.fetch_add(1, std::memory_order_relaxed);
        if (!final) split_commits_.fetch_add(1, std::memory_order_relaxed);
    }
    for (GnmCmdTarget t : {GnmCmdTarget::Upload, GnmCmdTarget::Main}) {
        if (!committed[(int)t]) continue;
        for (auto& [ev, v] : t_[(int)t].signals) [queue_ signalEvent:ev value:v];
        t_[(int)t].signals.clear();
    }
    if (final) {
        [queue_ signalEvent:timeline_ value:seq];
        last_seq_ = seq;
    }
}

// A split inside the open seq (Task 2.3: a signal that must follow recorded work, a wait that must
// not hold it back): commits every open command buffer and opens new ones on the same targets.
void Metal4Backend::Split() {
    NSString* labels[2] = {t_[0].cb.label, t_[1].cb.label};
    const bool open[2] = {t_[0].cb != nil, t_[1].cb != nil};
    Submit(false, true, nullptr, nullptr);
    for (int t = 0; t < 2; ++t)
        if (open[t]) BeginPart((GnmCmdTarget)t, labels[t]);
}

void Metal4Backend::CommitUpload() {
    if (t_[(int)GnmCmdTarget::Upload].cb) Submit(false, false, nullptr, nullptr);
}

void Metal4Backend::Commit(uint64_t seq, GnmCompletionFn done, void* ctx) {
    if (seq != open_seq()) {
        fprintf(stderr, "[gnm-draw] FATAL: Metal4Backend::Commit of seq %llu, expected %llu\n", (unsigned long long)seq,
                (unsigned long long)open_seq());
        abort();
    }
    // every seq ends with a committed command buffer: its feedback is the seq's completion
    if (!t_[(int)GnmCmdTarget::Main].cb) BeginPart(GnmCmdTarget::Main, nil);
    Submit(true, true, done, ctx);
}

bool Metal4Backend::WaitForRoom(uint64_t committed, uint64_t max_outstanding, double timeout_ms) {
    if (committed < max_outstanding) return true;
    const uint64_t need = committed - max_outstanding + 1;
    if (CompletedSeq() >= need) return true;
    return [timeline_ waitUntilSignaledValue:need timeoutMS:(uint64_t)timeout_ms];
}

// No work recorded since the current part began: the queue operation happens right here (every
// earlier part is committed). Task 2.3 adds the split when work is recorded.
void Metal4Backend::QueueSignal(id<MTLSharedEvent> ev, uint64_t value) {
    Target& x = Cur();
    if (!x.work) {
        [queue_ signalEvent:ev value:value];
        return;
    }
    NotYet("QueueSignal after work", "Task 2.3");
}

void Metal4Backend::QueueWait(id<MTLSharedEvent> ev, uint64_t value) {
    Target& x = Cur();
    if (!x.work && x.signals.empty()) {
        [queue_ waitForEvent:ev value:value];
        return;
    }
    NotYet("QueueWait after work", "Task 2.3");
}

GnmBackendStats Metal4Backend::Stats() const {
    GnmBackendStats s;
    s.commits = commits_.load(std::memory_order_relaxed);
    s.split_commits = split_commits_.load(std::memory_order_relaxed);
    s.allocators = allocators_.load(std::memory_order_relaxed);
    s.allocator_resets = resets_.load(std::memory_order_relaxed);
    s.resident = res_.Count();
    s.resident_bytes = res_.AllocatedSize();
    return s;
}

// ---- later tasks
bool Metal4Backend::BeginRender(const GnmPassDesc&) { NotYet("BeginRender", "Task 2.3"); }
void Metal4Backend::BeginCompute(bool) { NotYet("BeginCompute", "Task 3.1"); }
void Metal4Backend::BeginCopies() { NotYet("BeginCopies", "Task 2.3"); }
void Metal4Backend::EndEncoder() {
    Target& x = Cur();
    if (x.renc) [x.renc endEncoding];
    if (x.cenc) [x.cenc endEncoding];
    x.renc = nil;
    x.cenc = nil;
    x.open = GnmEncoder::None;
}
void Metal4Backend::SetEncoderLabel(NSString* label) {
    Target& x = Cur();
    if (x.renc) x.renc.label = label;
    else if (x.cenc) x.cenc.label = label;
}
void Metal4Backend::Barrier(uint32_t, uint32_t, uint8_t) { NotYet("Barrier", "Task 3.1"); }
void Metal4Backend::SetRenderPipeline(id<MTLRenderPipelineState>) { NotYet("SetRenderPipeline", "Task 2.3"); }
void Metal4Backend::SetDepthStencil(id<MTLDepthStencilState>) { NotYet("SetDepthStencil", "Task 2.3"); }
void Metal4Backend::SetFixed(const GnmFixedState&, uint32_t) { NotYet("SetFixed", "Task 4.1"); }
void Metal4Backend::SetComputePipeline(id<MTLComputePipelineState>) { NotYet("SetComputePipeline", "Task 3.1"); }
void Metal4Backend::Draw(const GnmDraw&) { NotYet("Draw", "Task 2.3"); }
void Metal4Backend::Dispatch(MTLSize, MTLSize) { NotYet("Dispatch", "Task 3.1"); }
void Metal4Backend::DispatchThreads(MTLSize, MTLSize) { NotYet("DispatchThreads", "Task 3.1"); }
void Metal4Backend::DispatchIndirect(id<MTLBuffer>, uint64_t, MTLSize) { NotYet("DispatchIndirect", "Task 3.1"); }
void Metal4Backend::CopyBuffer(id<MTLBuffer>, uint64_t, id<MTLBuffer>, uint64_t, uint64_t) { NotYet("CopyBuffer", "Task 3.2"); }
void Metal4Backend::FillBuffer(id<MTLBuffer>, uint64_t, uint64_t, uint8_t) { NotYet("FillBuffer", "Task 3.2"); }
void Metal4Backend::CopyTexture(id<MTLTexture>, id<MTLTexture>) { NotYet("CopyTexture", "Task 2.3"); }
void Metal4Backend::CopyTextureRegion(id<MTLTexture>, uint32_t, uint32_t, MTLOrigin, MTLSize, id<MTLTexture>, uint32_t,
                                      uint32_t, MTLOrigin) { NotYet("CopyTextureRegion", "Task 3.2"); }
void Metal4Backend::CopyBufferToTexture(id<MTLBuffer>, uint64_t, uint64_t, uint64_t, MTLSize, id<MTLTexture>, uint32_t,
                                        uint32_t, MTLOrigin) { NotYet("CopyBufferToTexture", "Task 3.2"); }
void Metal4Backend::BeforeWork() {}
uint64_t Metal4Backend::BytesAddress(const void*, size_t) { NotYet("BytesAddress", "Task 2.3"); }
void Metal4Backend::OpBuffer(GnmBackend*, GnmStage, uint32_t, __unsafe_unretained id<MTLBuffer>, uint64_t) { NotYet("BindBuffer", "Task 2.3"); }
void Metal4Backend::OpBufferOffset(GnmBackend*, GnmStage, uint32_t, uint64_t) { NotYet("BindBufferOffset", "Task 2.3"); }
void Metal4Backend::OpBytes(GnmBackend*, GnmStage, uint32_t, const void*, size_t) { NotYet("BindBytes", "Task 2.3"); }
void Metal4Backend::OpTexture(GnmBackend*, GnmStage, uint32_t, __unsafe_unretained id<MTLTexture>) { NotYet("BindTexture", "Task 2.3"); }
void Metal4Backend::OpSampler(GnmBackend*, GnmStage, uint32_t, __unsafe_unretained id<MTLSamplerState>) { NotYet("BindSampler", "Task 2.3"); }
void Metal4Backend::OpUse(GnmBackend*, GnmStage, __unsafe_unretained id<MTLBuffer>, bool) { NotYet("UseResource", "Task 3.1"); }

} // namespace ps4gnm
```

`ps4_gnm_backend.h`: after `MakeMetal3Backend` add `std::unique_ptr<GnmBackend> MakeMetal4Backend(); // ps4_gnm_backend_metal4.mm`; update the `kMetal4BackendCaps` comment ("ps4_gnm_backend_metal4.mm"). `ps4_gnm_backend.mm`: delete `const uint32_t kMetal4BackendCaps = 0;` and its comment. `tools/gnm_replay/build.sh:20`: add `"$G/ps4_gnm_backend_metal4.mm"`. Every host-test build line that compiles `ps4_gnm_backend.mm` now also compiles `ps4_gnm_backend_metal4.mm` and `ps4_gnm_residency.mm` (the select test and the rect-list test lines). `run_host_tests.sh`, after `gnm_residency_test`:

```bash
# Backend sources for tests that drive a backend directly (tests/host/backend_harness.h).
BE=("$G/ps4_gnm_backend.mm" "$G/ps4_gnm_backend_metal3.mm" "$G/ps4_gnm_backend_metal4.mm" "$G/ps4_gnm_residency.mm"
    "$G/ps4_gnm_util_passes.mm")
# Command buffers and the seq timeline on each backend: event order; Metal 4 allocator reuse
# after completion, bounded allocator memory, WaitForRoom on a stalled GPU.
clang++ -std=c++17 -fobjc-arc -Wall -Werror -I "$G" -I "$R/tests/host" "$R/tests/host/gnm_backend_cmd_test.mm" "${BE[@]}" \
  -framework Metal -framework Foundation -o "$T/gnm_backend_cmd_test"
for m in 3 4; do PS4_GNM_METAL=$m gpu "$T/gnm_backend_cmd_test"; done
```

- [ ] **Step 4: Run it to verify it passes**

Build as in Step 2, then `for m in 3 4; do PS4_GNM_METAL=$m $T/c; done`. Expected: two `gnm_backend_cmd_test: PASS` lines (`backend metal3`, `backend metal4`).

- [ ] **Step 5: R-check, host suite, commit**

Replay build `t22`, R-check `t22 3`: `cmp=0`; host suite `t22`: `host=0`.

```bash
git add $G/ps4_gnm_backend_metal4.h $G/ps4_gnm_backend_metal4.mm $G/ps4_gnm_backend.h $G/ps4_gnm_backend.mm tests/host/backend_harness.h tests/host/gnm_backend_cmd_test.mm tests/host/run_host_tests.sh tools/gnm_replay/build.sh
git commit -m "gnm: Metal4Backend queue, allocator ring, timeline event and commit feedback

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

### Task 2.3: Metal 4 render passes, clears, render bindings, present copy, the seq split

**Files:**
- Modify: `$G/ps4_gnm_backend_metal4.mm` (`BeginRender`, `BeginCopies`, `CopyTexture`, `SetRenderPipeline`, `SetDepthStencil`, `Draw` (direct), the render-stage bind ops, the bytes arena, `QueueSignal`/`QueueWait` with work, `BeforeWork`, `kMetal4BackendCaps = kGnmCapClears`)
- Create: `tests/host/gnm_backend_present_test.mm`
- Modify: `tests/host/gnm_backend_cmd_test.mm` (case `TestSplit`), `tests/host/run_host_tests.sh`

**Interfaces:**
- Consumes: Task 2.2; `FullscreenPass`, `MakeGnmUtil` (Task 1.9).
- Produces: `kMetal4BackendCaps == kGnmCapClears`; `Metal4Backend` render passes (all `GnmPassDesc` fields), `Draw` of `GnmDrawKind::Direct`, vertex/fragment `BindBuffer/BindBufferOffset/BindBytes/BindTexture/BindSampler`, `BeginCopies` + `CopyTexture`, and the seq split: a `QueueSignal` after recorded work is issued after that work's commit; a `QueueWait` after recorded work commits it first (`Stats().split_commits` counts these commits).

- [ ] **Step 1: Write the failing tests**

Append to `tests/host/gnm_backend_cmd_test.mm`:

```objc
// A queue-level signal between two render passes of one seq: the first pass's result is visible
// when the signal is (Metal 4 commits the first part there: split_commits + 1), the second pass
// waits for the event the wait names, and the seq completes after both.
static id<MTLTexture> SharedRgba(id<MTLDevice> dev, GnmBackend& be, uint32_t rgba) {
    MTLTextureDescriptor* td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm
                                                                                  width:8 height:8 mipmapped:NO];
    td.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
    td.storageMode = MTLStorageModeShared;
    id<MTLTexture> t = [dev newTextureWithDescriptor:td];
    uint32_t px[64];
    for (uint32_t& p : px) p = rgba;
    [t replaceRegion:MTLRegionMake2D(0, 0, 8, 8) mipmapLevel:0 withBytes:px bytesPerRow:32];
    be.MakeResident(t, GnmResidencyClass::Texture);
    return t;
}

static uint32_t Pixel(id<MTLTexture> t) {
    uint32_t p = 0;
    [t getBytes:&p bytesPerRow:32 fromRegion:MTLRegionMake2D(3, 3, 1, 1) mipmapLevel:0];
    return p;
}

static void ClearPass(GnmBackend& be, id<MTLTexture> t, MTLClearColor c) {
    GnmPassDesc pd;
    pd.color[0].tex = t;
    pd.color[0].load = GnmLoad::Clear;
    pd.clear_color[0] = c;
    CHECK(be.BeginRender(pd), "no render encoder");
    be.EndEncoder();
}

static void TestSplit(id<MTLDevice> dev, GnmBackend& be) {
    id<MTLTexture> a = SharedRgba(dev, be, 0xFF0000FFu), b = SharedRgba(dev, be, 0xFFFF0000u); // red, blue (ABGR in memory)
    id<MTLSharedEvent> after_a = [dev newSharedEvent], gate = [dev newSharedEvent];
    const uint64_t split0 = be.Stats().split_commits;
    be.BeginCmd(GnmCmdTarget::Main, @"split", false);
    ClearPass(be, a, MTLClearColorMake(0, 1, 0, 1)); // a: green
    be.QueueSignal(after_a, 1);
    be.QueueWait(gate, 1);
    ClearPass(be, b, MTLClearColorMake(1, 1, 1, 1)); // b: white
    const uint64_t seq = ++g_seq;
    be.Commit(seq, [](void*, const GnmCompletion&) {}, nullptr);
    CHECK([after_a waitUntilSignaledValue:1 timeoutMS:2000], "the signal after the first pass did not happen");
    CHECK(Pixel(a) == 0xFF00FF00u, "the first pass's clear is not visible at its signal: %08x", Pixel(a));
    usleep(100000);
    CHECK(Pixel(b) == 0xFFFF0000u, "the second pass ran before its wait was satisfied: %08x", Pixel(b));
    gate.signaledValue = 1;
    for (int i = 0; i < 200 && be.CompletedSeq() < seq; ++i) usleep(10000);
    CHECK(be.CompletedSeq() >= seq && Pixel(b) == 0xFFFFFFFFu, "the second pass did not run: %08x", Pixel(b));
    if (be.Kind() == GnmBackendKind::Metal4)
        CHECK(be.Stats().split_commits == split0 + 1, "split commits %llu, want %llu",
              (unsigned long long)be.Stats().split_commits, (unsigned long long)(split0 + 1));
}
```

and call `TestSplit(dev, *be);` in `main` after `TestEventOrder`.

`tests/host/gnm_backend_present_test.mm`:

```objc
// A clear presented and read back on the backend PS4_GNM_METAL selects (both run it), as the
// renderer presents: a clear of a game target, the present conversion (FullscreenPass with the
// utility present pipeline) into a slot texture, the copy into a second slot (the presenter's
// copy when the frame is not an acquired slot), and the ready signal after the work. The bytes
// are the clear colour on both backends, the signal comes after the copy's result is visible.
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>

#include "backend_harness.h"
#include "ps4_gnm_util_passes.h"

using namespace ps4gnm;

static int g_fail = 0;
#define CHECK(c, ...)                                                                        \
    do {                                                                                     \
        if (!(c)) {                                                                          \
            fprintf(stderr, "gnm_backend_present_test: FAIL %s:%d: ", __FILE__, __LINE__);   \
            fprintf(stderr, __VA_ARGS__);                                                    \
            fprintf(stderr, "\n");                                                           \
            g_fail++;                                                                        \
        }                                                                                    \
    } while (0)

static id<MTLTexture> Tex(id<MTLDevice> dev, GnmBackend& be, MTLPixelFormat f, MTLStorageMode m) {
    MTLTextureDescriptor* td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:f width:64 height:32 mipmapped:NO];
    td.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
    td.storageMode = m;
    id<MTLTexture> t = [dev newTextureWithDescriptor:td];
    be.MakeResident(t, GnmResidencyClass::Texture);
    return t;
}

int main() {
    @autoreleasepool {
        id<MTLDevice> dev = MTLCreateSystemDefaultDevice();
        std::string why;
        std::unique_ptr<GnmBackend> be = dev ? MakeTestBackend(dev, &why) : nullptr;
        GnmUtil util;
        if (!be || !MakeGnmUtil(dev, &util, &why) || !util.present) {
            printf("gnm_backend_present_test: FAIL: %s\n", why.c_str());
            return 1;
        }
        id<MTLTexture> game = Tex(dev, *be, MTLPixelFormatBGRA8Unorm, MTLStorageModePrivate);
        id<MTLTexture> slot = Tex(dev, *be, MTLPixelFormatBGRA8Unorm, MTLStorageModeShared);
        id<MTLTexture> slot2 = Tex(dev, *be, MTLPixelFormatBGRA8Unorm, MTLStorageModeShared);
        id<MTLSharedEvent> ready = [dev newSharedEvent];
        be->BeginCmd(GnmCmdTarget::Main, @"present test", false);
        GnmPassDesc clear;
        clear.color[0].tex = game;
        clear.color[0].load = GnmLoad::Clear;
        clear.clear_color[0] = MTLClearColorMake(64.0 / 255, 128.0 / 255, 192.0 / 255, 1); // r, g, b, a
        CHECK(be->BeginRender(clear), "clear pass");
        be->EndEncoder();
        GnmPassDesc conv;
        conv.color[0].tex = slot;
        conv.color[0].load = GnmLoad::DontCare;
        CHECK(FullscreenPass(*be, conv, util.present, nil, game), "present conversion");
        be->BeginCopies();
        be->CopyTexture(slot, slot2);
        be->EndEncoder();
        be->QueueSignal(ready, 1);
        CHECK(CommitAndWait(*be, 1), "the seq failed or hung");
        CHECK(ready.signaledValue == 1, "ready not signalled");
        const uint8_t want[4] = {192, 128, 64, 255}; // BGRA in memory
        for (id<MTLTexture> t : {slot, slot2}) {
            std::vector<uint8_t> px(64 * 32 * 4);
            [t getBytes:px.data() bytesPerRow:64 * 4 fromRegion:MTLRegionMake2D(0, 0, 64, 32) mipmapLevel:0];
            size_t bad = 0;
            for (size_t i = 0; i < px.size(); i += 4) bad += memcmp(&px[i], want, 4) != 0;
            CHECK(bad == 0, "%s: %zu of 2048 pixels are not the clear colour (first %u %u %u %u)",
                  t == slot ? "slot" : "slot copy", bad, px[0], px[1], px[2], px[3]);
        }
        printf("gnm_backend_present_test: backend %s\n", BackendName(be->Kind()));
    }
    printf("gnm_backend_present_test: %s\n", g_fail ? "FAIL" : "PASS");
    return g_fail ? 1 : 0;
}
```

(`#include <vector>`.) `run_host_tests.sh`, after the `gnm_backend_cmd_test` lines:

```bash
# A clear presented and read back (clear, present conversion, slot copy, ready signal), equal on both backends.
clang++ -std=c++17 -fobjc-arc -Wall -Werror -I "$G" -I "$R/tests/host" "$R/tests/host/gnm_backend_present_test.mm" "${BE[@]}" \
  -framework Metal -framework Foundation -o "$T/gnm_backend_present_test"
for m in 3 4; do PS4_GNM_METAL=$m gpu "$T/gnm_backend_present_test"; done
```

- [ ] **Step 2: Run them to verify they fail**

Build both tests; `PS4_GNM_METAL=4` runs → Expected: `[gnm-draw] FATAL: Metal4Backend::BeginRender is not implemented yet (Task 2.3 …)` and an abort (exit 134). The `PS4_GNM_METAL=3` runs pass (the Metal 3 path exists).

- [ ] **Step 3: Implement**

In `ps4_gnm_backend_metal4.mm`: `const uint32_t kMetal4BackendCaps = kGnmCapClears;` and replace the corresponding `NotYet` bodies:

```objc
static MTLLoadAction LoadOf(GnmLoad l) {
    return l == GnmLoad::Clear ? MTLLoadActionClear : l == GnmLoad::DontCare ? MTLLoadActionDontCare : MTLLoadActionLoad;
}
static MTLStoreAction StoreOf(GnmStore s) {
    return s == GnmStore::MultisampleResolve ? MTLStoreActionMultisampleResolve : MTLStoreActionStore;
}
constexpr MTLStages kAllStages = MTLStageVertex | MTLStageFragment | MTLStageDispatch | MTLStageBlit;

// Signals waiting for the work recorded so far are issued after that work's commit: if work is
// about to start again on this target, that commit happens now (a split of the seq).
void Metal4Backend::BeforeWork() {
    Target& x = Cur();
    if (!x.signals.empty()) Split();
    Cur().work = true;
}

void Metal4Backend::QueueSignal(id<MTLSharedEvent> ev, uint64_t value) {
    Target& x = Cur();
    if (!x.work) [queue_ signalEvent:ev value:value]; // every earlier part is committed
    else x.signals.emplace_back(ev, value);            // after this part's commit (Submit)
}

void Metal4Backend::QueueWait(id<MTLSharedEvent> ev, uint64_t value) {
    Target& x = Cur();
    if (x.work || !x.signals.empty()) Split(); // the work so far must not wait: commit it first
    [queue_ waitForEvent:ev value:value];
}

bool Metal4Backend::BeginRender(const GnmPassDesc& d) {
    BeforeWork();
    Target& x = Cur();
    MTL4RenderPassDescriptor* rp = [MTL4RenderPassDescriptor new];
    for (int i = 0; i < 8; ++i) {
        const GnmAttachment& a = d.color[i];
        if (!a.tex) continue;
        MTLRenderPassColorAttachmentDescriptor* c = rp.colorAttachments[i];
        c.texture = a.tex;
        c.slice = a.slice;
        c.loadAction = LoadOf(a.load);
        if (a.load == GnmLoad::Clear) c.clearColor = d.clear_color[i];
        c.storeAction = StoreOf(a.store);
        if (a.store == GnmStore::MultisampleResolve) c.resolveTexture = a.resolve;
    }
    if (d.depth.tex) {
        rp.depthAttachment.texture = d.depth.tex;
        rp.depthAttachment.slice = d.depth.slice;
        rp.depthAttachment.loadAction = LoadOf(d.depth.load);
        if (d.depth.load == GnmLoad::Clear) rp.depthAttachment.clearDepth = d.clear_depth;
        rp.depthAttachment.storeAction = StoreOf(d.depth.store);
    }
    if (d.stencil.tex) {
        rp.stencilAttachment.texture = d.stencil.tex;
        rp.stencilAttachment.slice = d.stencil.slice;
        rp.stencilAttachment.loadAction = LoadOf(d.stencil.load);
        if (d.stencil.load == GnmLoad::Clear) rp.stencilAttachment.clearStencil = d.clear_stencil;
        rp.stencilAttachment.storeAction = StoreOf(d.stencil.store);
    }
    if (d.width) rp.renderTargetWidth = d.width;
    if (d.height) rp.renderTargetHeight = d.height;
    if (d.default_samples) rp.defaultRasterSampleCount = d.default_samples;
    if (d.num_sample_positions) [rp setSamplePositions:d.sample_positions count:d.num_sample_positions];
    x.renc = [x.cb renderCommandEncoderWithDescriptor:rp];
    if (!x.renc) return false;
    if (d.label) x.renc.label = d.label;
    [x.renc setArgumentTable:x.table[(int)GnmStage::Vertex] atStages:MTLRenderStageVertex];
    [x.renc setArgumentTable:x.table[(int)GnmStage::Fragment] atStages:MTLRenderStageFragment];
    // what Metal 3 orders between encoders by itself: everything before (render, compute, copies) first
    if (!no_barriers_)
        [x.renc barrierAfterQueueStages:kAllStages beforeStages:MTLStageVertex | MTLStageFragment
                      visibilityOptions:MTL4VisibilityOptionDevice];
    x.open = GnmEncoder::Render;
    ++serial_;
    return true;
}

// Copies are on a compute encoder (Metal 4 has no blit encoder).
void Metal4Backend::BeginCopies() {
    BeforeWork();
    Target& x = Cur();
    x.cenc = [x.cb computeCommandEncoder];
    [x.cenc setArgumentTable:x.table[(int)GnmStage::Compute]];
    if (!no_barriers_)
        [x.cenc barrierAfterQueueStages:kAllStages beforeStages:MTLStageDispatch | MTLStageBlit
                      visibilityOptions:MTL4VisibilityOptionDevice];
    x.open = GnmEncoder::Copy;
    ++serial_;
}

void Metal4Backend::CopyTexture(id<MTLTexture> src, id<MTLTexture> dst) {
    [Cur().cenc copyFromTexture:src toTexture:dst];
    if (full_barriers_)
        [Cur().cenc barrierAfterEncoderStages:MTLStageBlit | MTLStageDispatch beforeEncoderStages:MTLStageBlit | MTLStageDispatch
                            visibilityOptions:MTL4VisibilityOptionDevice];
}

void Metal4Backend::SetRenderPipeline(id<MTLRenderPipelineState> p) { [Cur().renc setRenderPipelineState:p]; }
void Metal4Backend::SetDepthStencil(id<MTLDepthStencilState> d) { [Cur().renc setDepthStencilState:d]; }

void Metal4Backend::Draw(const GnmDraw& d) {
    if (d.kind != GnmDrawKind::Direct) NotYet("Draw (indexed / indirect)", "Task 4.1");
    [Cur().renc drawPrimitives:d.prim vertexStart:d.vertex_start vertexCount:d.count instanceCount:d.instances
                  baseInstance:d.base_instance];
    if (full_barriers_)
        [Cur().renc barrierAfterEncoderStages:MTLStageVertex | MTLStageFragment
                          beforeEncoderStages:MTLStageVertex | MTLStageFragment
                            visibilityOptions:MTL4VisibilityOptionDevice];
}

// setBytes: the bytes go into a 256 KiB shared chunk (resident, Builtin) and the table gets their
// address. A chunk is reused once the last seq that used it completed (Recycle).
constexpr size_t kBytesChunk = 256u << 10;
uint64_t Metal4Backend::BytesAddress(const void* p, size_t n) {
    const size_t off = (chunk_used_ + 255) & ~size_t(255); // constant buffer alignment
    if (!chunk_.buf || off + n > kBytesChunk) {
        if (chunk_.buf) chunks_busy_.push_back(chunk_);
        id<MTLBuffer> b = nil;
        if (!chunks_free_.empty()) {
            b = chunks_free_.back();
            chunks_free_.pop_back();
        } else {
            b = [dev_ newBufferWithLength:kBytesChunk options:MTLResourceStorageModeShared];
            res_.Add(b, GnmResidencyClass::Builtin);
        }
        chunk_ = Chunk{b, 0};
        chunk_used_ = 0;
        return BytesAddress(p, n);
    }
    memcpy((uint8_t*)chunk_.buf.contents + off, p, n);
    chunk_used_ = off + n;
    chunk_.last_seq = open_seq();
    return chunk_.buf.gpuAddress + off;
}

static inline bool RenderStage(GnmStage st) { return st != GnmStage::Compute; }

void Metal4Backend::OpBuffer(GnmBackend* b, GnmStage st, uint32_t slot, __unsafe_unretained id<MTLBuffer> buf, uint64_t off) {
    Metal4Backend* m = static_cast<Metal4Backend*>(b);
    if (!RenderStage(st)) NotYet("compute bindings", "Task 3.1");
    Target& x = m->Cur();
    const uint64_t base = buf ? buf.gpuAddress : 0;
    x.base[(int)st][slot] = base;
    [x.table[(int)st] setAddress:base ? base + off : 0 atIndex:slot];
}
void Metal4Backend::OpBufferOffset(GnmBackend* b, GnmStage st, uint32_t slot, uint64_t off) {
    Metal4Backend* m = static_cast<Metal4Backend*>(b);
    if (!RenderStage(st)) NotYet("compute bindings", "Task 3.1");
    Target& x = m->Cur();
    [x.table[(int)st] setAddress:x.base[(int)st][slot] + off atIndex:slot];
}
void Metal4Backend::OpBytes(GnmBackend* b, GnmStage st, uint32_t slot, const void* p, size_t n) {
    Metal4Backend* m = static_cast<Metal4Backend*>(b);
    if (!RenderStage(st)) NotYet("compute bindings", "Task 3.1");
    Target& x = m->Cur();
    x.base[(int)st][slot] = 0;
    [x.table[(int)st] setAddress:m->BytesAddress(p, n) atIndex:slot];
}
void Metal4Backend::OpTexture(GnmBackend* b, GnmStage st, uint32_t slot, __unsafe_unretained id<MTLTexture> t) {
    Metal4Backend* m = static_cast<Metal4Backend*>(b);
    if (!RenderStage(st)) NotYet("compute bindings", "Task 3.1");
    const MTLResourceID none = {};
    [m->Cur().table[(int)st] setTexture:t ? t.gpuResourceID : none atIndex:slot];
}
void Metal4Backend::OpSampler(GnmBackend* b, GnmStage st, uint32_t slot, __unsafe_unretained id<MTLSamplerState> s) {
    Metal4Backend* m = static_cast<Metal4Backend*>(b);
    if (!RenderStage(st)) NotYet("compute bindings", "Task 3.1");
    const MTLResourceID none = {};
    [m->Cur().table[(int)st] setSamplerState:s ? s.gpuResourceID : none atIndex:slot];
}
```

`Submit` must also give the current bytes chunk its seq: nothing to do (`last_seq` is set at each allocation to the seq being recorded, and a chunk is only recycled once that seq completed). `Recycle` is called by `AcquirePart` (each part); that is where completed chunks return to `chunks_free_`.

`EndEncoder` stays as in Task 2.2. Delete the `NotYet` bodies replaced here.

- [ ] **Step 4: Run them to verify they pass**

```bash
for m in 3 4; do PS4_GNM_METAL=$m $T/c; PS4_GNM_METAL=$m $T/p; done
```
Expected: four PASS lines (`gnm_backend_cmd_test` with `TestSplit`, `gnm_backend_present_test`) per backend. With `MTL_DEBUG_LAYER=1` set, the Metal 4 runs print no validation error.

- [ ] **Step 5: R-check, host suite, commit**

Replay build `t23`, R-check `t23 3`: `cmp=0`; host suite `t23`: `host=0`.

```bash
git add $G/ps4_gnm_backend_metal4.mm tests/host/gnm_backend_cmd_test.mm tests/host/gnm_backend_present_test.mm tests/host/run_host_tests.sh
git commit -m "gnm: Metal 4 render passes, clears, render bindings, present copy, seq split at events

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

### Task 2.4: Residency of render targets, present slots and built-ins

**Files:**
- Modify: `$G/ps4_gnm_resources.h:745-1013` (`TextureCache`: `TextureHooks`, `SetHooks`, `NewTextureLocked`, `DropEntryLocked`, `ReleaseTextureLocked`), `$G/ps4_gnm_resources.mm` (every `[device_ newTextureWithDescriptor:td]` at `:3275`, `:3385`, `:3448`, `:3490`, `:3525`, `:3675`, `:3847`, `:4122`; every `delete e` / `delete d` / `delete it->second` at `:2968`, `:3053`, `:3366`, `:3387`, `:3450`, `:3527`, `:3677`, `:3833`, `:3849`, `:4108`, `:4124`; `RetireLocked` at `:3493`; the alias copy replacement at `:3289`; the destructor `:2984`)
- Modify: `pkg/runtime/modules/libSceVideoOut/ps4_metal_screen.h`, `ps4_metal_screen.m` (`slot_texture` `:963-973`, `ps4_metal_screen_hold_texture` `:1378`; new `ps4_metal_screen_set_texture_hooks`)
- Modify: `$G/ps4_gnm_draw.mm` `Init` (`:6359-6367`: hooks, dummy, GDS) and `PresentImpl` (`:8835-8844`: `present_tex`)
- Modify: `tools/gnm_replay/replay_links.c` (the screen hook setter: the replay never presents, its hooks are never called; a real definition that stores nothing is not allowed: make it `NotInReplay` and do not call it under replay: `Init` calls it only when `ps4_metal_screen_get_device()` returned a device)
- Test: `tests/host/tex_evict_test.mm` (case `test_texture_hooks`)

**Interfaces:**
- Consumes: `GnmBackend::{MakeResident, Evict}`.
- Produces:
  - `struct TextureCache::TextureHooks { void* ctx = nullptr; void (*created)(void* ctx, id<MTLTexture> t) = nullptr; void (*released)(void* ctx, id<MTLTexture> t) = nullptr; };` and `void TextureCache::SetHooks(const TextureHooks& h);` (called once, before the first lookup): `created` for every texture the cache creates, `released` when it drops its last reference to one (entry deleted, texture replaced, alias copy replaced, cache destroyed).
  - `void ps4_metal_screen_set_texture_hooks(void (*created)(void* ctx, void* tex), void (*released)(void* ctx, void* tex), void* ctx);` (present slots and held textures).
  - In `ps4_gnm_draw.mm`: `void ResidentTexture(void*, id<MTLTexture> t)` / `void ReleasedTexture(void*, id<MTLTexture> t)` (→ `S.be->MakeResident(t, GnmResidencyClass::Texture)` / `S.be->Evict(t, S.committed_seq + 1)`).

- [ ] **Step 1: Write the failing test**

In `tests/host/tex_evict_test.mm` add (and call it from `main` after the existing cases):

```objc
// The texture hooks the Metal 4 backend's residency rests on: every texture the cache creates is
// reported once, and reported released when the cache drops it (eviction, replacement, the cache's
// destruction), so created - released is always the number of live cache textures.
struct HookCount {
    std::unordered_set<const void*> live;
    int created = 0, released = 0, released_unknown = 0;
};
static void test_texture_hooks(id<MTLDevice> dev) {
    id<MTLCommandQueue> q = [dev newCommandQueue];
    Guest g;
    g.size = 16 * MiB;
    g.base = (uint8_t*)mmap(nullptr, g.size, PROT_READ | PROT_WRITE, MAP_ANON | MAP_PRIVATE, -1, 0);
    check(g.base != MAP_FAILED, "hooks: guest memory mapped");
    HookCount hc;
    @autoreleasepool {
        TextureCache tc(dev, q, g.base, g.size);
        TextureCache::TextureHooks h;
        h.ctx = &hc;
        h.created = [](void* c, id<MTLTexture> t) {
            HookCount* x = static_cast<HookCount*>(c);
            x->created++;
            x->live.insert((__bridge const void*)t);
        };
        h.released = [](void* c, id<MTLTexture> t) {
            HookCount* x = static_cast<HookCount*>(c);
            x->released++;
            if (!x->live.erase((__bridge const void*)t)) x->released_unknown++;
        };
        tc.SetHooks(h);
        tc.SetUse(1, 1000 * MS);
        for (uint64_t i = 0; i < 8; ++i) {
            Fill(g, 0x10000 * (i + 1), 64 * 64 * 4, (uint8_t)(0x10 + i));
            check(tc.GetTexture(Tsharp(0x10000 * (i + 1), 64, 64)) != nil, "hooks: sampled texture");
        }
        check(tc.GetColorTarget(Rt(0x200000), false) != nil, "hooks: color target");
        id<MTLTexture> d1 = tc.GetDepthTarget(Db(0x300000, 1));
        id<MTLTexture> grown_from = nil;
        id<MTLTexture> d4 = tc.GetDepthTarget(Db(0x300000, 4), &grown_from);
        check(d1 && d4 && d4 != d1, "hooks: the depth target grew into a new texture");
        tc.SetUse(2, 60000 * MS);
        TextureCache::EvictResult r = tc.EvictSampled(small_policy(1), false, 60000 * MS, 1);
        check(r.count == 8, "hooks: the 8 idle sampled textures of a completed command buffer evicted");
        check(hc.created == 11, "hooks: 8 sampled + 1 color + 2 depth creations reported");
        check(hc.released == 9, "hooks: 8 evicted + the replaced depth texture reported released");
        check(hc.released_unknown == 0, "hooks: no release of a texture never reported created");
    }
    check(hc.live.empty(), "hooks: the cache's destruction reports every texture it still held");
    munmap(g.base, g.size);
}
```

(`#include <unordered_set>`; `main` calls `test_texture_hooks(dev);` after `test_guest_newer(dev);`. If `hc.created` or `hc.released` differ by the textures a path creates internally (an alias view is a view, not a creation: views are not reported), read the counted path in `ps4_gnm_resources.mm` and correct the expected number in the test with a comment naming that path; the `released_unknown == 0` and `live.empty()` checks never change.)

Run the `tex_evict_test` build line of `run_host_tests.sh` → Expected: compile error `no type named 'TextureHooks' in 'ps4gnm::TextureCache'`.

- [ ] **Step 2: Implement the TextureCache hooks**

`ps4_gnm_resources.h`, public part of `TextureCache`:

```objc
    // Every texture the cache creates (created) and every one it lets go (released: entry deleted,
    // texture replaced, alias copy replaced, the cache destroyed), for the Metal 4 backend's
    // residency sets. Set once, before the first lookup. Called with the cache's lock held.
    struct TextureHooks {
        void* ctx = nullptr;
        void (*created)(void* ctx, id<MTLTexture> t) = nullptr;
        void (*released)(void* ctx, id<MTLTexture> t) = nullptr;
    };
    void SetHooks(const TextureHooks& h) { hooks_ = h; }
```

private part:

```objc
    TextureHooks hooks_;
    id<MTLTexture> NewTextureLocked(MTLTextureDescriptor* td);
    void ReleaseTextureLocked(id<MTLTexture> t);
    // deletes e after reporting its texture and its alias copy released
    void DropEntryLocked(Entry* e);
```

`ps4_gnm_resources.mm`:

```objc
id<MTLTexture> TextureCache::NewTextureLocked(MTLTextureDescriptor* td) {
    id<MTLTexture> t = [device_ newTextureWithDescriptor:td];
    if (t && hooks_.created) hooks_.created(hooks_.ctx, t);
    return t;
}

void TextureCache::ReleaseTextureLocked(id<MTLTexture> t) {
    if (t && hooks_.released) hooks_.released(hooks_.ctx, t);
}

// An alias that is a view of a copy (GetTextureImpl: different dimensions) holds that copy as its parent.
void TextureCache::DropEntryLocked(Entry* e) {
    ReleaseTextureLocked(e->tex);
    if (e->alias && e->alias.parentTexture && e->alias.parentTexture != e->tex) ReleaseTextureLocked(e->alias.parentTexture);
    delete e;
}
```

Replace every `[device_ newTextureWithDescriptor:td]` listed in **Files** by `NewTextureLocked(td)` (all run with `mutex_` held); every `delete e` / `delete d` / `delete it->second` by `DropEntryLocked(…)` (the failed-creation deletes at `:3387`, `:3450`, `:3527`, `:3849`, `:4124` have `e->tex == nil`: `DropEntryLocked` reports nothing for them); at `:3493` add `ReleaseTextureLocked(e->tex);` before `RetireLocked(e->tex);`; at `:3289`, before the new alias is assigned, `if (e->alias && e->alias.parentTexture && e->alias.parentTexture != e->tex) ReleaseTextureLocked(e->alias.parentTexture);`; the destructor (`:2984`) drops every entry with `DropEntryLocked`.

- [ ] **Step 3: Presenter textures and the renderer's built-ins**

`ps4_metal_screen.h`:

```c
// The presenter's slot and held textures, for the renderer's Metal 4 residency sets: created for
// each one made, released for each one replaced. Set once, before the first present.
void ps4_metal_screen_set_texture_hooks(void (*created)(void *ctx, void *tex), void (*released)(void *ctx, void *tex),
                                        void *ctx);
```

`ps4_metal_screen.m`:

```objc
static struct {
    void (*created)(void *, void *);
    void (*released)(void *, void *);
    void *ctx;
} g_tex_hooks;

void ps4_metal_screen_set_texture_hooks(void (*created)(void *, void *), void (*released)(void *, void *), void *ctx) {
    g_tex_hooks.created = created;
    g_tex_hooks.released = released;
    g_tex_hooks.ctx = ctx;
}

static id<MTLTexture> hooked_texture(MTLTextureDescriptor *td, id<MTLTexture> old) {
    id<MTLTexture> t = [g_device newTextureWithDescriptor:td];
    if (old && g_tex_hooks.released) g_tex_hooks.released(g_tex_hooks.ctx, (__bridge void *)old);
    if (t && g_tex_hooks.created) g_tex_hooks.created(g_tex_hooks.ctx, (__bridge void *)t);
    return t;
}
```

`slot_texture` (`:971`): `ps->tex = hooked_texture(td, ps->tex);`; `ps4_metal_screen_hold_texture` (`:1378`): `h->tex = hooked_texture(td, h->tex);`.

`ps4_gnm_draw.mm`, before `Init`:

```cpp
void ResidentTexture(void*, id<MTLTexture> t) { S.be->MakeResident(t, GnmResidencyClass::Texture); }
void ReleasedTexture(void*, id<MTLTexture> t) { S.be->Evict(t, S.committed_seq + 1); }
```

(`committed_seq + 1` is the open command buffer's seq: the last one that can still use a texture dropped now. `committed_seq` is read without `fence_mu` here: the hooks run on the encoder thread, the only writer.) In `Init` after `S.tex = new TextureCache(…)`:

```cpp
        S.tex->SetHooks(TextureCache::TextureHooks{nullptr, ResidentTexture, ReleasedTexture});
        if (ps4_metal_screen_get_device())
            ps4_metal_screen_set_texture_hooks([](void*, void* t) { ResidentTexture(nullptr, (__bridge id<MTLTexture>)t); },
                                               [](void*, void* t) { ReleasedTexture(nullptr, (__bridge id<MTLTexture>)t); },
                                               nullptr);
```

and after `S.dummy` / `S.gds_buf` are created: `S.be->MakeResident(S.dummy, GnmResidencyClass::Builtin); if (S.gds_buf != S.dummy) S.be->MakeResident(S.gds_buf, GnmResidencyClass::Builtin);`. `PresentImpl` (`:8842`): after `S.present_tex = [S.dev newTextureWithDescriptor:td];` add `if (old) S.be->Evict(old, S.committed_seq + 1); S.be->MakeResident(S.present_tex, GnmResidencyClass::Texture);` with `id<MTLTexture> old = S.present_tex;` taken before the assignment. The guest display texture (`:8717`) the same way.

Metal 3 does nothing for these calls (its `MakeResident`/`Evict` are empty by design), so the R-check must stay identical.

- [ ] **Step 4: Run the test, R-check, host suite**

`tex_evict_test` build and run line → Expected: its PASS line. Replay build `t24`, R-check `t24 3`: `cmp=0`. Host suite `t24`: `host=0`.

- [ ] **Step 5: Commit**

```bash
git add $G/ps4_gnm_resources.h $G/ps4_gnm_resources.mm pkg/runtime/modules/libSceVideoOut/ps4_metal_screen.h pkg/runtime/modules/libSceVideoOut/ps4_metal_screen.m $G/ps4_gnm_draw.mm tools/gnm_replay/replay_links.c tests/host/tex_evict_test.mm
git commit -m "gnm: texture cache and presenter texture hooks; render targets, slots and built-ins resident on Metal 4

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

### Task 2.5: Run the renderer on Metal 4 with draws skipped (`PS4_GNM_MTL4_ONLY_CLEARS=1`)

**Files:**
- Modify: `$G/ps4_gnm_draw.mm`: `Init` (backend creation: Metal 4; the encoder-status warning), `EnsureCmd` (`WaitForRoom` + watchdog), `WaitAll` (watchdog text shared with `EnsureCmd`: new `GiveUpGpu`), `DrawEncode` (`:7436-7551`: skip after `BeginPass`), `DispatchEncode` (`:8405`: skip without `kGnmCapCompute`), `GpuDma` (`:6593`: refuse without `kGnmCapCopies`), `GpuUploadTexture`/`SampledTexture`/`GuestDisplayTexture` (no GPU upload without `kGnmCapCompute | kGnmCapCopies`), `PresentImpl` perf block (`:8937-8945`: the backend line)
- Modify: `docs/metal4-backend.md`, `tests/host/run_host_tests.sh`

**Interfaces:**
- Consumes: `ChooseBackend`, `MakeMetal4Backend`, `GnmBackend::{Caps, Stats, WaitForRoom}`.
- Produces: `bool g_only_clears` (renderer), `uint64_t State::n_clear_only` (draws skipped by the debug mode; not counted in `n_skipped`), `void GiveUpGpu(const char* what)`, the per-300-presents log line `[gnm-draw] backend <name>: split commits per frame <x>; allocators <n> (<KiB> KiB); resident <n> (<MiB> MiB)`.

- [ ] **Step 1: Write the failing check**

Add to `run_host_tests.sh`, after the `gnm_replay_test` run (the synthetic capture of `gnm_replay_test` is a dispatch pass; it writes `<dir>/frame_1`, so write one for the check):

```bash
# PS4_GNM_METAL=4 through the whole renderer: refused at startup without the debug mode while the
# Metal 4 backend lacks draws; with PS4_GNM_MTL4_ONLY_CLEARS=1 the renderer starts and skips what
# the backend lacks (here a dispatch, before Phase 3), never reaching a missing method.
"$T/replay/gnm_replay_test" write-capture "$T/m4cap" > /dev/null 2>&1
rc=0; PS4_GNM_METAL=4 "$T/replay/gnm_replay" "$T/m4cap/frame_1" 0 > "$T/m4a.txt" 2>&1 || rc=$?
grep -q "FATAL: PS4_GNM_METAL=4: this build's Metal 4 backend lacks" "$T/m4a.txt" && [ $rc -eq 2 ] ||
  { echo "Metal 4 without the debug mode was not refused (rc=$rc)"; cat "$T/m4a.txt"; exit 1; }
rc=0; PS4_GNM_METAL=4 PS4_GNM_MTL4_ONLY_CLEARS=1 "$T/replay/gnm_replay" "$T/m4cap/frame_1" 0 > "$T/m4b.txt" 2>&1 || rc=$?
grep -q "backend metal4" "$T/m4b.txt" && grep -q "NOT REPLAYED: the renderer skipped the pass" "$T/m4b.txt" && [ $rc -eq 2 ] ||
  { echo "Metal 4 only-clears run did not start and skip the dispatch (rc=$rc)"; cat "$T/m4b.txt"; exit 1; }
```

`gnm_replay_test.mm`: in `main`, `if (argc == 3 && !strcmp(argv[1], "write-capture")) { WriteCapture(argv[2], -1); return 0; }` before the tests; and the `gnm_replay` tool must be built in `$T/replay` too: add `"$R/tools/gnm_replay/gnm_replay.mm"` to the `build.sh` call that builds the replay tests.

Run the suite (or those lines by hand) → Expected: FAIL at the second check (`ChooseBackend` accepts the run, but `Init` still creates `Metal3Backend`, so "backend metal4" is missing).

- [ ] **Step 2: Implement**

`Init` backend creation:

```cpp
            S.be = ch.kind == GnmBackendKind::Metal4 ? MakeMetal4Backend() : MakeMetal3Backend();
            …Init and the log line as before…
            g_only_clears = only_clears && S.be->Kind() == GnmBackendKind::Metal4;
            if (S.be->Kind() == GnmBackendKind::Metal4 && EncoderStatusEnabled())
                fprintf(stderr, "[gnm-draw] PS4_GNM_ENCODER_STATUS is Metal 3 only (Metal 4 has no per-encoder "
                                "status); ignored. Bisect with PS4_GNM_COMMIT_EACH=1 instead\n");
```

(`bool g_only_clears = false;` in the anonymous namespace next to `State S`; `EncoderStatusEnabled()` returns false on Metal 4: `static const bool on = getenv("PS4_GNM_ENCODER_STATUS") && (!S.be || S.be->Kind() == GnmBackendKind::Metal3);` — it is first called after `Init`, so initialise it there: make it a plain `bool g_encoder_status` set in `Init` and read by `EncoderStatusEnabled()`.)

`GiveUpGpu` (the watchdog of `WaitAll`, shared with `EnsureCmd`):

```cpp
// The GPU made no progress within S.gpu_timeout_ms: rendering stops (fences keep being signalled).
void GiveUpGpu(const char* what) {
    fprintf(stderr, "[gnm-draw] GPU watchdog: %s did not complete in %.0f ms; disabling GPU rendering (fences keep "
                    "being signaled)\n", what, S.gpu_timeout_ms);
    S.hung = true;
    ps4_metal_screen_release_held();
    GmLogState();
    GmReleaseAll();
}
```

`WaitAll`'s block calls it with `label` (and prints the stuck log before `GmReleaseAll` as now: keep the print right after `GiveUpGpu`'s first line by passing the log: `GiveUpGpu(label)` then `if (stuck && stuck->log) stuck->log->Print(…)`; the order of the log lines changes, the messages do not). `EnsureCmd`, before `BeginCmd`:

```cpp
    uint64_t committed;
    {
        std::lock_guard<std::mutex> lk(S.fence_mu);
        committed = S.committed_seq;
    }
    if (!S.be->WaitForRoom(committed, kMaxCommandBuffers, S.gpu_timeout_ms)) {
        char what[96];
        snprintf(what, sizeof(what), "the oldest of %llu outstanding command buffers", (unsigned long long)kMaxCommandBuffers);
        GiveUpGpu(what);
    }
```

`DrawEncode`, right after `if (!BeginPass(key, clr, hold)) return;`:

```cpp
        if (g_only_clears) { // debug (Metal 4 without draws): the pass's clears happen, the draw does not
            S.n_clear_only++;
            return;
        }
```

`DispatchEncode` at its start (after `if (S.hung) return;`): `if (!(S.be->Caps() & kGnmCapCompute)) { cap::SetSkipped("backend without compute (PS4_GNM_MTL4_ONLY_CLEARS)"); S.n_skipped++; return; }`. `GpuDma` (CP side): `if (!(S.be->Caps() & kGnmCapCopies)) return false;` first (the CP then copies on the CPU, its existing fallback). `SampledTexture`, `GpuUploadTexture` and `GuestDisplayTexture`: `if ((S.be->Caps() & (kGnmCapCompute | kGnmCapCopies)) != (kGnmCapCompute | kGnmCapCopies))` → the CPU upload path (`S.tex->GetTexture(img)`) / `return false` / `return nil` (the existing fallbacks). The fast-clear and resolve paths (`EliminateFastClear`, `ResolvePass` with a multisample resolve) need only passes; `ResolvePass`'s copy branch and `MipChainFor` need `kGnmCapCopies`: skip them the same way (`RLog` once).

`PresentImpl`, in the 300-present block after the `per frame: … passes` line:

```cpp
            {
                static GnmBackendStats last{};
                const GnmBackendStats b = S.be->Stats();
                fprintf(stderr, "[gnm-draw] backend %s: split commits per frame %.1f; allocators %llu (%llu KiB); "
                                "resident %llu (%llu MiB); draws skipped by PS4_GNM_MTL4_ONLY_CLEARS %llu\n",
                        BackendName(S.be->Kind()), (b.split_commits - last.split_commits) / 300.0,
                        (unsigned long long)b.allocators, (unsigned long long)(b.allocator_bytes >> 10),
                        (unsigned long long)b.resident, (unsigned long long)(b.resident_bytes >> 20),
                        (unsigned long long)S.n_clear_only);
                last = b;
            }
```

`Metal4Backend::Stats()` fills `allocator_bytes` with the sum of `allocatedSize` over the allocators of `busy_` and `free_` (encoder thread; `Stats` is called from `PresentImpl` on the encoder thread, and its other fields are atomics).

`docs/metal4-backend.md`, debug variables table: add `PS4_GNM_MTL4_ONLY_CLEARS=1` (Metal 4: draws are skipped after their render pass begins, so clears happen; dispatches, GPU DMA and GPU texture uploads are skipped or done on the CPU while the backend lacks compute and copies; counted in the `backend` log line, not as skipped draws), `PS4_GNM_MTL4_FULL_BARRIERS=1` (Metal 4: a barrier after every draw, dispatch and copy, for ordering A/B checks), `PS4_GNM_MTL4_NO_BARRIERS=1` (Metal 4, tests only: no encoder-start barriers; shows that a test depends on them). Add a "Log lines" section describing the `backend` line.

- [ ] **Step 3: Run the check, R-check, host suite**

Host suite `t25`: `host=0` (the new lines pass). Replay build `t25`, R-check `t25 3`: `cmp=0`.

- [ ] **Step 4: Commit**

```bash
git add $G/ps4_gnm_draw.mm tests/host/gnm_replay_test.mm tests/host/run_host_tests.sh docs/metal4-backend.md
git commit -m "gnm: Metal 4 backend selectable; PS4_GNM_MTL4_ONLY_CLEARS debug mode; backend stats line

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

### Task 2.6: Phase 2 gate

**Files:** `docs/metal4-baseline.md` (append "Phase 2").

**Acceptance (spec table, Phase 2):** "A clear presented and read back equals Metal 3. TLOU boots to frames on Metal 4 with draws disabled (debug `PS4_GNM_MTL4_ONLY_CLEARS=1`): flips complete, no watchdog, `allocatedSize` does not grow over 10,000 frames."

- [ ] **Step 1: Host suite**

Host suite `p2`: `host=0`; `grep -E "gnm_backend_present_test: (backend|PASS)" $M/host_p2.log` shows both backends and two PASS lines.

- [ ] **Step 2: TLOU on Metal 4, clears only**

TLOU game build tag `p2`. Then:

```bash
~/ps4recomp-work/tools/heavy_lock.sh env BUILD=$M/tlou_build_p2 TAG=p2_m4_clears METAL=4 SECS=300 tools/metal4_route.sh PS4_GNM_MTL4_ONLY_CLEARS=1
python3 tools/metal4_route_report.py $M/runs/p2_m4_clears.log --skip 0
grep "backend metal4" $M/runs/p2_m4_clears.log | awk '{print $(NF-11), $(NF-10), $(NF-8), $(NF-7)}' | sed -n '5,$p'
```
Expected: `fatal 0 gpu_err 0 watchdog 0`, `flips` ≥ 10000; the `backend metal4` lines after the fifth (frame 1500, boot done) show the same allocator KiB and resident MiB to the end (no growth; a single step up when a new render-target size appears is allowed if it is followed by no further growth, and each such step is listed in the baseline file). If fewer than 10,000 frames were presented in 300 s, the gate is not met: find what limits the clear-only frame rate (the `perf` lines' CP and encoder ms) before going on.

- [ ] **Step 3: Metal 3 does not regress**

```bash
N=3 A=$M/tlou_build_p0:3 B=$M/tlou_build_p2:3 TAG=p2_ab tools/metal4_perf_ab.sh | tee $M/ab_p2.txt
```
Expected: within noise (as in Task 1.10), `fatal 0 gpu_err 0 watchdog 0`.

- [ ] **Step 4: Uncharted 4 smoke (recorded, not an acceptance condition)**

```bash
cd ~/ps4recomp-work/PS4Recomp-metal4 || exit 1
~/ps4recomp-work/tools/heavy_lock.sh ./ps4-recomp "$U4_DIR/eboot.bin" --app-dir "$U4_DIR" -o $M/u4_build_p2 -c -j 6 > $M/gen_u4_p2.log 2>&1; echo gen=$?
~/ps4recomp-work/tools/heavy_lock.sh env BUILD=$M/u4_build_p2 TAG=p2_u4_m4 METAL=4 SECS=120 DATASRC=$(mktemp -d) \
  SCRIPT=/dev/null tools/metal4_route.sh PS4_GNM_MTL4_ONLY_CLEARS=1
python3 tools/metal4_route_report.py $M/runs/p2_u4_m4.log --skip 0
```
(`metal4_route.sh` copies an empty data dir; U4 boots to its title with autopress; 720p because `PS4_PRO=0 PS4_UPSCALE=0`.) Record the report line in the baseline file. A crash or hang here is recorded with its log excerpt, not fixed in this phase unless it also happens in TLOU.

- [ ] **Step 5: Go analysis, record, commit**

`go=0`. Append:

```markdown
## Phase 2 (Metal 4 queue, command buffers, clears, present), commit <hash>

- Host suite green; gnm_backend_present_test equal on metal3 and metal4.
- TLOU, PS4_GNM_METAL=4 PS4_GNM_MTL4_ONLY_CLEARS=1, 300 s: <flips> flips, fatal 0, watchdog 0;
  allocator memory <KiB> KiB and resident <MiB> MiB from frame 1500 to the end (steps: <none | list>).
- Metal 3 A/B vs Phase 0: medians <x> / <y> fps, within noise.
- U4 smoke on Metal 4 (clears only): <report line>.
```

```bash
git add docs/metal4-baseline.md
git commit -m "Metal 4 work: Phase 2 gate numbers (queue, clears, present)

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

## Phase 3: Compute

### Task 3.1: Metal 4 compute encoders, compute bindings, dispatches, barriers; the residency controls

**Files:**
- Modify: `$G/ps4_gnm_backend_metal4.h` (`Target::serial`), `$G/ps4_gnm_backend_metal4.mm` (`BeginCompute`, `SetComputePipeline`, `Dispatch`, `DispatchThreads`, `DispatchIndirect`, `Barrier`, `OpUse`, the compute stage of the bind ops; `kMetal4BackendCaps = kGnmCapClears | kGnmCapCompute`)
- Test: `tests/host/gnm_residency_test.mm` (cases `TestGpuWrites`), `tests/host/run_host_tests.sh` (the residency test now links the backend sources)

**Interfaces:**
- Consumes: Tasks 2.2–2.3.
- Produces: `kMetal4BackendCaps == (kGnmCapClears | kGnmCapCompute)`; compute work on Metal 4: a compute encoder starts with a barrier after all queue stages; `Barrier(after, before, scope)` inside a compute encoder is `barrierAfterEncoderStages:beforeEncoderStages:visibilityOptions:Device` (scope ignored: device visibility orders all memory); `BeginCompute(true)` puts a barrier after every dispatch; indirect dispatches by `gpuAddress`.

- [ ] **Step 1: Write the failing test (residency positive and negative control)**

Append to `tests/host/gnm_residency_test.mm` (and add `#include "backend_harness.h"`, `#include "ps4_gnm_backend_metal4.h"`, `#include <sys/mman.h>`):

```objc
// GPU writes into a no-copy buffer over host memory (as a guest memory window) by a Metal 4
// dispatch: they land when the buffer is in a residency set (positive), and are lost without an
// error when it is in none (the negative control: the reason every window, arena chunk and
// built-in buffer must be added; if Metal ever reports this or makes the buffer resident by
// itself, this check fails and the residency rules must be revisited). Bytes come from the arena.
static const char* kWriteMsl = R"(
#include <metal_stdlib>
using namespace metal;
kernel void fill(device uint* out [[buffer(0)]], constant uint& k [[buffer(1)]], uint i [[thread_position_in_grid]]) {
    out[i] = i * 3u + k;
}
)";

static bool RunFill(Metal4Backend& be, id<MTLComputePipelineState> pso, id<MTLBuffer> buf, uint64_t seq) {
    const uint32_t k = 7;
    be.BeginCmd(GnmCmdTarget::Main, @"residency", false);
    be.BeginCompute(false);
    be.SetComputePipeline(pso);
    be.BindBuffer(GnmStage::Compute, 0, buf, 0);
    be.BindBytes(GnmStage::Compute, 1, &k, sizeof(k));
    be.Dispatch(MTLSizeMake(64, 1, 1), MTLSizeMake(64, 1, 1));
    be.EndEncoder();
    return CommitAndWait(be, seq);
}

static void TestGpuWrites(id<MTLDevice> dev) {
    if (!RequireMetal4(dev, "gnm_residency_test (GPU writes)")) return;
    Metal4Backend be;
    std::string why;
    CHECK(be.Init(dev, &why), "Metal 4 backend: %s", why.c_str());
    NSError* err = nil;
    id<MTLLibrary> lib = [dev newLibraryWithSource:[NSString stringWithUTF8String:kWriteMsl] options:nil error:&err];
    id<MTLComputePipelineState> pso = [dev newComputePipelineStateWithFunction:[lib newFunctionWithName:@"fill"] error:&err];
    CHECK(pso, "pipeline: %s", err.localizedDescription.UTF8String);
    if (!pso) return;
    const size_t n = 1u << 20;
    for (int resident = 1; resident >= 0; --resident) {
        uint32_t* mem = (uint32_t*)mmap(nullptr, n, PROT_READ | PROT_WRITE, MAP_ANON | MAP_PRIVATE, -1, 0);
        id<MTLBuffer> buf = [dev newBufferWithBytesNoCopy:mem length:n options:MTLResourceStorageModeShared deallocator:nil];
        if (resident) be.MakeResident(buf, GnmResidencyClass::Guest);
        const bool ok = RunFill(be, pso, buf, resident ? 1 : 2);
        CHECK(ok, "the dispatch's seq failed or hung (resident %d)", resident);
        uint32_t right = 0;
        for (uint32_t i = 0; i < 4096; ++i) right += mem[i] == i * 3u + 7u;
        if (resident) CHECK(right == 4096, "resident window: %u of 4096 dwords written", right);
        else CHECK(right == 0, "negative control: %u of 4096 dwords written into a window in no residency set; "
                               "the control shows nothing (Metal made it resident?)", right);
        if (resident) be.Evict(buf, 1);
        munmap(mem, n);
    }
}
```

Call `TestGpuWrites(dev);` from `main`. The residency test's build line in `run_host_tests.sh` becomes `… -I "$R/tests/host" "$R/tests/host/gnm_residency_test.mm" "${BE[@]}" …` (move it after the `BE=` definition), run as `PS4_GNM_METAL=4 gpu "$T/gnm_residency_test"` (the Metal 4 cases ignore the variable; the set-logic cases run anyway).

Run it → Expected: `FATAL: Metal4Backend::BeginCompute is not implemented yet (Task 3.1 …)`, abort.

- [ ] **Step 2: Implement**

`ps4_gnm_backend_metal4.h`: in `Target` add `bool serial = false; // BeginCompute(true): a barrier after every dispatch`.

`ps4_gnm_backend_metal4.mm`:

```objc
const uint32_t kMetal4BackendCaps = kGnmCapClears | kGnmCapCompute;

void Metal4Backend::BeginCompute(bool serial) {
    BeforeWork();
    Target& x = Cur();
    x.cenc = [x.cb computeCommandEncoder];
    [x.cenc setArgumentTable:x.table[(int)GnmStage::Compute]];
    if (!no_barriers_)
        [x.cenc barrierAfterQueueStages:kAllStages beforeStages:MTLStageDispatch | MTLStageBlit
                      visibilityOptions:MTL4VisibilityOptionDevice];
    x.open = GnmEncoder::Compute;
    x.serial = serial || EnvOn("PS4_GNM_SERIAL_COMPUTE");
    ++serial_;
}

void Metal4Backend::SetComputePipeline(id<MTLComputePipelineState> p) { [Cur().cenc setComputePipelineState:p]; }

// After a dispatch: the debug mode's barrier, or a serial encoder's.
static inline void AfterDispatch(id<MTL4ComputeCommandEncoder> e, bool barrier) {
    if (barrier)
        [e barrierAfterEncoderStages:MTLStageDispatch | MTLStageBlit beforeEncoderStages:MTLStageDispatch | MTLStageBlit
                   visibilityOptions:MTL4VisibilityOptionDevice];
}

void Metal4Backend::Dispatch(MTLSize groups, MTLSize tpt) {
    [Cur().cenc dispatchThreadgroups:groups threadsPerThreadgroup:tpt];
    AfterDispatch(Cur().cenc, full_barriers_ || Cur().serial);
}
void Metal4Backend::DispatchThreads(MTLSize threads, MTLSize tpt) {
    [Cur().cenc dispatchThreads:threads threadsPerThreadgroup:tpt];
    AfterDispatch(Cur().cenc, full_barriers_ || Cur().serial);
}
// The arguments (3 uint32) at gpuAddress + off; Metal 4 needs 4-byte alignment, which every caller
// already checks (DrawEncode / EncodeCs refuse unaligned guest arguments).
void Metal4Backend::DispatchIndirect(id<MTLBuffer> args, uint64_t off, MTLSize tpt) {
    [Cur().cenc dispatchThreadgroupsWithIndirectBuffer:args.gpuAddress + off threadsPerThreadgroup:tpt];
    AfterDispatch(Cur().cenc, full_barriers_ || Cur().serial);
}

void Metal4Backend::Barrier(uint32_t after, uint32_t before, uint8_t) {
    Target& x = Cur();
    if (x.cenc) {
        const MTLStages s = MTLStageDispatch | MTLStageBlit;
        [x.cenc barrierAfterEncoderStages:(MTLStages)after & s ?: s beforeEncoderStages:(MTLStages)before & s ?: s
                        visibilityOptions:MTL4VisibilityOptionDevice];
    } else if (x.renc) {
        NotYet("Barrier inside a render pass", "Task 4.1");
    }
}

// A buffer reached through an argument buffer (gpuAddress tables): Metal 4 has no useResource;
// the buffer is resident because every window, arena chunk and built-in is in a residency set from
// its creation (GnmResidency). Task 5.1 checks that here under PS4_GNM_RESIDENCY_CHECK=1.
void Metal4Backend::OpUse(GnmBackend*, GnmStage, __unsafe_unretained id<MTLBuffer>, bool) {}
```

In `OpBuffer`, `OpBufferOffset`, `OpBytes`, `OpTexture`, `OpSampler` delete the `if (!RenderStage(st)) NotYet(…)` lines and the `RenderStage` helper: the compute table is `x.table[(int)GnmStage::Compute]`, already bound by `BeginCompute`/`BeginCopies`.

- [ ] **Step 3: Run it to verify it passes**

```bash
clang++ -std=c++17 -fobjc-arc -Wall -Werror -I $G -I tests/host tests/host/gnm_residency_test.mm $BE $G/ps4_gnm_util_passes.mm -framework Metal -framework Foundation -o $T/r && PS4_GNM_METAL=4 $T/r
```
Expected: `gnm_residency_test: PASS` (both the positive and the negative control held). If the negative control fails (`… dwords written into a window in no residency set`), stop: Metal's behaviour differs from probe P4 on this machine; record it and ask the owner before changing the residency design.

- [ ] **Step 4: Other backend tests, R-check, host suite, commit**

`for m in 3 4; do PS4_GNM_METAL=$m $T/c; PS4_GNM_METAL=$m $T/p; done` still pass. Replay build `t31`, R-check `t31 3`: `cmp=0`. Host suite `t31`: `host=0`.

```bash
git add $G/ps4_gnm_backend_metal4.h $G/ps4_gnm_backend_metal4.mm tests/host/gnm_residency_test.mm tests/host/run_host_tests.sh
git commit -m "gnm: Metal 4 compute encoders, bindings, dispatches and barriers; residency positive and negative control

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

### Task 3.2: Metal 4 copies and fills on the compute encoder

**Files:**
- Modify: `$G/ps4_gnm_backend_metal4.mm` (`CopyBuffer`, `FillBuffer`, `CopyTextureRegion`, `CopyBufferToTexture`; `kMetal4BackendCaps |= kGnmCapCopies`)
- Create: `tests/host/gnm_backend_copy_test.mm`
- Modify: `tests/host/run_host_tests.sh`

**Interfaces:**
- Consumes: Task 3.1.
- Produces: `kMetal4BackendCaps == (kGnmCapClears | kGnmCapCompute | kGnmCapCopies)`; every copy op on both backends, on either target.

- [ ] **Step 1: Write the failing test**

`tests/host/gnm_backend_copy_test.mm`:

```objc
// Every copy and fill of GnmBackend on the backend PS4_GNM_METAL selects (both run it), with the
// results read back on the CPU: buffer copy at offsets, a byte fill, a buffer into two levels and
// two slices of a texture array (row and image pitches), a texture region between levels and
// slices, a whole-texture copy; and the upload target: a copy recorded there runs before the main
// command buffer's copy that reads its result, in the same seq.
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>

#include <vector>

#include "backend_harness.h"

using namespace ps4gnm;

static int g_fail = 0;
#define CHECK(c, ...)                                                                     \
    do {                                                                                  \
        if (!(c)) {                                                                       \
            fprintf(stderr, "gnm_backend_copy_test: FAIL %s:%d: ", __FILE__, __LINE__);   \
            fprintf(stderr, __VA_ARGS__);                                                 \
            fprintf(stderr, "\n");                                                        \
            g_fail++;                                                                     \
        }                                                                                 \
    } while (0)

int main() {
    @autoreleasepool {
        id<MTLDevice> dev = MTLCreateSystemDefaultDevice();
        std::string why;
        std::unique_ptr<GnmBackend> be = dev ? MakeTestBackend(dev, &why) : nullptr;
        if (!be) {
            printf("gnm_backend_copy_test: FAIL: %s\n", why.c_str());
            return 1;
        }
        const auto buffer = [&](size_t n, uint8_t fill) {
            id<MTLBuffer> b = [dev newBufferWithLength:n options:MTLResourceStorageModeShared];
            memset(b.contents, fill, n);
            be->MakeResident(b, GnmResidencyClass::Builtin);
            return b;
        };
        const auto texture = [&](MTLTextureType type, uint32_t w, uint32_t h, uint32_t levels, uint32_t slices) {
            MTLTextureDescriptor* td = [MTLTextureDescriptor new];
            td.textureType = type;
            td.pixelFormat = MTLPixelFormatR32Uint;
            td.width = w;
            td.height = h;
            td.mipmapLevelCount = levels;
            td.arrayLength = slices;
            td.storageMode = MTLStorageModeShared;
            td.usage = MTLTextureUsageShaderRead;
            id<MTLTexture> t = [dev newTextureWithDescriptor:td];
            be->MakeResident(t, GnmResidencyClass::Texture);
            return t;
        };
        id<MTLBuffer> src = buffer(1 << 16, 0), dst = buffer(1 << 16, 0xEE), fill = buffer(4096, 0);
        for (uint32_t i = 0; i < (1u << 14); ++i) ((uint32_t*)src.contents)[i] = 0x01000000u + i;
        id<MTLTexture> arr = texture(MTLTextureType2DArray, 16, 8, 2, 2);
        id<MTLTexture> region = texture(MTLTextureType2DArray, 16, 8, 2, 2);
        id<MTLTexture> whole = texture(MTLTextureType2DArray, 16, 8, 2, 2);
        id<MTLTexture> up = texture(MTLTextureType2D, 16, 8, 1, 1), up_copy = texture(MTLTextureType2D, 16, 8, 1, 1);
        be->BeginCmd(GnmCmdTarget::Main, @"copies", false);
        be->BeginCopies();
        be->CopyBuffer(src, 256, dst, 1024, 4096);
        be->FillBuffer(fill, 512, 1024, 0x5A);
        // level 0: 16x8, row 64 bytes; level 1: 8x4, row 32; two slices each, image = row * height
        be->CopyBufferToTexture(src, 0, 64, 0, MTLSizeMake(16, 8, 1), arr, 0, 0, MTLOriginMake(0, 0, 0));
        be->CopyBufferToTexture(src, 512, 64, 0, MTLSizeMake(16, 8, 1), arr, 1, 0, MTLOriginMake(0, 0, 0));
        be->CopyBufferToTexture(src, 1024, 32, 0, MTLSizeMake(8, 4, 1), arr, 0, 1, MTLOriginMake(0, 0, 0));
        be->CopyBufferToTexture(src, 1152, 32, 0, MTLSizeMake(8, 4, 1), arr, 1, 1, MTLOriginMake(0, 0, 0));
        be->EndEncoder();
        be->BeginCopies(); // reads what the previous encoder wrote
        be->CopyTextureRegion(arr, 1, 0, MTLOriginMake(4, 2, 0), MTLSizeMake(8, 4, 1), region, 0, 1, MTLOriginMake(0, 0, 0));
        be->CopyTexture(arr, whole);
        be->EndEncoder();
        // the upload target: committed before the main command buffer, in this seq
        be->BeginCmd(GnmCmdTarget::Upload, @"uploads", false);
        be->UseTarget(GnmCmdTarget::Upload);
        be->BeginCopies();
        be->CopyBufferToTexture(src, 4096, 64, 0, MTLSizeMake(16, 8, 1), up, 0, 0, MTLOriginMake(0, 0, 0));
        be->EndEncoder();
        be->UseTarget(GnmCmdTarget::Main);
        be->BeginCopies();
        be->CopyTexture(up, up_copy);
        be->EndEncoder();
        CHECK(CommitAndWait(*be, 1), "the seq failed or hung");
        const uint32_t* s = (const uint32_t*)src.contents;
        CHECK(!memcmp((uint8_t*)dst.contents + 1024, (uint8_t*)src.contents + 256, 4096), "CopyBuffer");
        CHECK(((uint8_t*)dst.contents)[1023] == 0xEE && ((uint8_t*)dst.contents)[1024 + 4096] == 0xEE, "CopyBuffer outside its range");
        bool fill_ok = true;
        for (int i = 0; i < 4096; ++i) fill_ok &= ((uint8_t*)fill.contents)[i] == (i >= 512 && i < 1536 ? 0x5A : 0);
        CHECK(fill_ok, "FillBuffer");
        const auto texel = [](id<MTLTexture> t, uint32_t x, uint32_t y, uint32_t level, uint32_t slice) {
            uint32_t v = 0;
            [t getBytes:&v bytesPerRow:64 bytesPerImage:0 fromRegion:MTLRegionMake2D(x, y, 1, 1) mipmapLevel:level slice:slice];
            return v;
        };
        CHECK(texel(arr, 5, 3, 0, 0) == s[3 * 16 + 5], "buffer -> texture level 0 slice 0");
        CHECK(texel(arr, 5, 3, 0, 1) == s[128 + 3 * 16 + 5], "buffer -> texture level 0 slice 1");
        CHECK(texel(arr, 2, 1, 1, 0) == s[256 + 1 * 8 + 2], "buffer -> texture level 1 slice 0");
        CHECK(texel(arr, 7, 3, 1, 1) == s[288 + 3 * 8 + 7], "buffer -> texture level 1 slice 1");
        CHECK(texel(region, 3, 2, 1, 0) == texel(arr, 7, 4, 0, 1), "texture region (slice 1 level 0 -> slice 0 level 1)");
        CHECK(texel(whole, 7, 3, 1, 1) == texel(arr, 7, 3, 1, 1) && texel(whole, 0, 0, 0, 0) == s[0], "whole-texture copy");
        CHECK(texel(up_copy, 9, 6, 0, 0) == s[1024 + 6 * 16 + 9], "upload target before the main command buffer");
        printf("gnm_backend_copy_test: backend %s\n", BackendName(be->Kind()));
    }
    printf("gnm_backend_copy_test: %s\n", g_fail ? "FAIL" : "PASS");
    return g_fail ? 1 : 0;
}
```

`run_host_tests.sh`, after the present test:

```bash
# Every copy and fill on each backend, the upload command buffer ordered before the main one.
clang++ -std=c++17 -fobjc-arc -Wall -Werror -I "$G" -I "$R/tests/host" "$R/tests/host/gnm_backend_copy_test.mm" "${BE[@]}" \
  -framework Metal -framework Foundation -o "$T/gnm_backend_copy_test"
for m in 3 4; do PS4_GNM_METAL=$m gpu "$T/gnm_backend_copy_test"; done
```

Run → Expected: Metal 3 PASS; Metal 4 `FATAL: Metal4Backend::CopyBuffer is not implemented yet (Task 3.2 …)`.

- [ ] **Step 2: Implement**

```objc
const uint32_t kMetal4BackendCaps = kGnmCapClears | kGnmCapCompute | kGnmCapCopies;

static inline void AfterCopy(id<MTL4ComputeCommandEncoder> e, bool barrier) { AfterDispatch(e, barrier); }

void Metal4Backend::CopyBuffer(id<MTLBuffer> src, uint64_t src_off, id<MTLBuffer> dst, uint64_t dst_off, uint64_t n) {
    [Cur().cenc copyFromBuffer:src sourceOffset:src_off toBuffer:dst destinationOffset:dst_off size:n];
    AfterCopy(Cur().cenc, full_barriers_);
}
void Metal4Backend::FillBuffer(id<MTLBuffer> dst, uint64_t off, uint64_t n, uint8_t value) {
    [Cur().cenc fillBuffer:dst range:NSMakeRange(off, n) value:value];
    AfterCopy(Cur().cenc, full_barriers_);
}
void Metal4Backend::CopyTextureRegion(id<MTLTexture> src, uint32_t src_slice, uint32_t src_level, MTLOrigin src_origin,
                                      MTLSize size, id<MTLTexture> dst, uint32_t dst_slice, uint32_t dst_level,
                                      MTLOrigin dst_origin) {
    [Cur().cenc copyFromTexture:src sourceSlice:src_slice sourceLevel:src_level sourceOrigin:src_origin sourceSize:size
                      toTexture:dst destinationSlice:dst_slice destinationLevel:dst_level destinationOrigin:dst_origin];
    AfterCopy(Cur().cenc, full_barriers_);
}
void Metal4Backend::CopyBufferToTexture(id<MTLBuffer> src, uint64_t src_off, uint64_t row_bytes, uint64_t image_bytes,
                                        MTLSize size, id<MTLTexture> dst, uint32_t slice, uint32_t level, MTLOrigin origin) {
    [Cur().cenc copyFromBuffer:src sourceOffset:src_off sourceBytesPerRow:row_bytes sourceBytesPerImage:image_bytes
                    sourceSize:size toTexture:dst destinationSlice:slice destinationLevel:level destinationOrigin:origin];
    AfterCopy(Cur().cenc, full_barriers_);
}
```

(Copies inside one `BeginCopies … EndEncoder` group write distinct destinations and read sources no copy of the group writes, as every renderer caller does; the next encoder's start barrier orders whatever follows. That is the spec's "copies and dispatches inside one compute encoder are separated by barriers": the renderer never mixes them in one encoder, `EndEncoders()` comes first on every copy path.)

- [ ] **Step 3: Run it, R-check, host suite, commit**

`for m in 3 4; do PS4_GNM_METAL=$m $T/copy; done` → two PASS lines. Replay build `t32`, R-check `t32 3`: `cmp=0`. Host suite `t32`: `host=0`.

```bash
git add $G/ps4_gnm_backend_metal4.mm tests/host/gnm_backend_copy_test.mm tests/host/run_host_tests.sh
git commit -m "gnm: Metal 4 copies and fills on compute encoders

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

### Task 3.3: Residency of guest windows, arena, page table and the guest memory buffers; compute tests on Metal 4

**Files:**
- Modify: `$G/ps4_gnm_draw.mm`: `UploadArena` (`:437-477`: `on_new`, `on_drop`), `ReleaseWindow` (`:1240-1243`), `GuestBuffer` (`:1485-1496`), `SweepGuestWindows` purge (`:1317-1324`), `CommitDoneFn` (the chunks that are not kept), `EnsureGuestMemoryState` (`:3973`), `GmAcquireSlot` (`:3987`), `BindGuestPageTable` (`:4105-4110`, `:4136-4142`), `EncodeGpuUploadAt` (`:5234-5237`, `:5250-5252`), `GpuDmaImpl` (`:6564`), `Init` (arena hooks)
- Modify: `tests/host/gcn_wave_exec_test.mm:248-320` (`Run` dispatches through the backend), `tests/host/run_host_tests.sh` (wave test, guest memory test and replay test on both backends)

**Interfaces:**
- Consumes: `GnmBackend::{MakeResident, Evict}`, `MakeTestBackend`.
- Produces: `UploadArena::on_new` / `on_drop` (`void (*)(id<MTLBuffer>)`), every GPU-visible buffer of the guest memory paths resident on Metal 4 from creation to release + seq.

- [ ] **Step 1: The wave test through the backend (fails on Metal 4 first)**

`gcn_wave_exec_test.mm` `Run(…)` (`:248`): replace the queue / command buffer / encoder block (`:281-311`) by the backend, created once in `main` (`static std::unique_ptr<ps4gnm::GnmBackend> g_be; static uint64_t g_seq;`; `g_be = MakeTestBackend(dev, &why)`, a `nullptr` is a FAIL), and make the guest buffer resident once when it is created (`g_be->MakeResident(g.buf, ps4gnm::GnmResidencyClass::Guest)` in `Guest`'s setup):

```objc
    ps4gnm::GnmBackend& be = *g_be;
    be.BeginCmd(ps4gnm::GnmCmdTarget::Main, nil, false);
    be.BeginCompute(false);
    be.SetComputePipeline(pso);
    for (uint32_t i = 0; i < info.num_buffers; i++) {
        …unchanged loop, with [enc setBytes:… atIndex:k] → be.BindBytes(ps4gnm::GnmStage::Compute, k, …) and
          [enc setBuffer:g.buf offset:o atIndex:k] → be.BindBuffer(ps4gnm::GnmStage::Compute, k, g.buf, o)…
    }
    if (info.msl_push_constant_buffer >= 0)
        be.BindBytes(ps4gnm::GnmStage::Compute, (uint32_t)info.msl_push_constant_buffer, push, sizeof(push));
    if (info.shared_memory_size) …see below…
    be.Dispatch(MTLSizeMake(1, 1, 1), MTLSizeMake(threads, 1, 1));
    be.EndEncoder();
    struct W { dispatch_semaphore_t done = dispatch_semaphore_create(0); } w;
    be.Commit(++g_seq, [](void* p, const ps4gnm::GnmCompletion&) { dispatch_semaphore_signal(static_cast<W*>(p)->done); }, &w);
    if (dispatch_semaphore_wait(w.done, dispatch_time(DISPATCH_TIME_NOW, int64_t(kKernelTimeoutSec) * NSEC_PER_SEC)) != 0) {
        …the existing timeout message and std::_Exit(124)…
    }
```

`setThreadgroupMemoryLength` is the one call the backend interface lacks: the translated kernels declare their LDS statically (the renderer never sets it), so check `info.shared_memory_size` handling first: grep the translator output (`GCN_WAVE_TEST_MSL_DIR`) for `threadgroup` parameters. If a kernel takes `[[threadgroup(0)]]` as a parameter, add `virtual void SetThreadgroupMemory(uint32_t index, uint32_t bytes) = 0;` to `GnmBackend` (Metal 3: `setThreadgroupMemoryLength:atIndex:`, Metal 4: the same method on `MTL4ComputeCommandEncoder`, `MTL4ComputeCommandEncoder.h:59`) in this step, with both implementations; otherwise delete the `if (info.shared_memory_size)` line and say so in the commit message. Build line: add `"${BE[@]}"` and `-I "$G" -I "$R/tests/host"` to the `gcn_wave_exec_test` line (move it after `BE=`), run `for m in 3 4; do PS4_GNM_METAL=$m gpu "$T/gcn_wave_exec_test" …; done`. On a Phase 3.2 build the Metal 4 run passes already if every buffer the test binds is resident; it is the renderer's guest memory paths below that need the hooks. Run it now: Expected: PASS on both (the test binds only `g.buf` and bytes).

The renderer's compute tests on Metal 4, `run_host_tests.sh`: `gnm_replay_test`, `gnm_guest_memory_test` (every mode) run a second time with `PS4_GNM_METAL=4 PS4_GNM_MTL4_ONLY_CLEARS=1` (draws are not on Metal 4 before Phase 4; these tests are compute-only):

```bash
for env in "PS4_GNM_METAL=3" "PS4_GNM_METAL=4 PS4_GNM_MTL4_ONLY_CLEARS=1"; do
  env $env gpu "$T/replay/gnm_replay_test" 2>&1 | { grep -v "^\[gnm-\|^\[gcn \|^\[gpumem\]" || true; }
  for mode in "" default hang-cp hang-throttle hang-fast-throttle; do
    env $env gpu "$T/replay/gnm_guest_memory_test" "$R/tests/host/data" $mode 2>&1 | { grep -v "^\[gnm-\|^\[gcn \|^\[gpumem\]" || true; }
  done
done
```

(replacing the existing single runs of these two tests). Run → Expected: on Metal 4 `gnm_guest_memory_test` FAILs (guest windows and slots are in no residency set: the probe's results stay zero, the CP waits time out or the destinations keep their old dwords).

- [ ] **Step 2: Residency hooks in the renderer**

`UploadArena`: add members `void (*on_new)(id<MTLBuffer>) = nullptr; void (*on_drop)(id<MTLBuffer>) = nullptr;` and after `if (!b) b = [dev newBufferWithLength:…]` → `if (b && on_new && !reused) on_new(b);` (`bool reused = b != nil` taken right after the free-list pop). `Init`, after the backend is created:

```cpp
        S.arena.on_new = [](id<MTLBuffer> b) { S.be->MakeResident(b, GnmResidencyClass::Guest); };
        S.arena.on_drop = [](id<MTLBuffer> b) { S.be->Evict(b, S.committed_seq + 1); };
```

`CommitDoneFn`: a chunk that is not put back on the free list is dropped: `else if (d->arena->on_drop) d->arena->on_drop(b);` — `CommitDoneFn` runs on a Metal thread and `S.committed_seq` is guarded there: pass the completed seq instead (`S.be->Evict(b, d->seq)`: the seq that used it has completed, the next `Retire` removes it). Write it as a second hook `void (*on_retired)(id<MTLBuffer>, uint64_t seq)` set to `[](id<MTLBuffer> b, uint64_t seq) { S.be->Evict(b, seq); }` and call `d->arena->on_retired(b, d->seq)`. `SweepGuestWindows` purge (`:1321-1322`): before `S.arena.free_list.clear()`, `for (id<MTLBuffer> b : S.arena.free_list) S.arena.on_drop(b);` (free chunks are unused: any seq is fine).

`GuestBuffer` (`:1495`): after `it = S.guest_bufs.emplace(…)`: `S.be->MakeResident(b, GnmResidencyClass::Guest);`. `ReleaseWindow` (`:1240`): `S.be->Evict(it->second.buf, S.committed_seq + 1);` before `erase` (covers `DropRemappedWindows` and `SweepGuestWindows`).

`EnsureGuestMemoryState` (`:3973`): `S.be->MakeResident(g_gmem.table, GnmResidencyClass::Builtin);`. `BindGuestPageTable`: the replacement table (`:4136`) `S.be->MakeResident(t, GnmResidencyClass::Builtin);`; the prune loop (`:4107-4109`) evicts the tables it drops: `else S.be->Evict(t.second, t.first);`. `GmAcquireSlot` (`:3987`): `S.be->MakeResident(s.buf, GnmResidencyClass::Builtin);` (slots are pooled for the process lifetime).

`EncodeGpuUploadAt`: the detile map (`:5235`) and staging (`:5250`) buffers → `S.be->MakeResident(…, GnmResidencyClass::Builtin)`; the map cache clear (`:5234`, `if (S.detile_maps.size() >= 64)`) and the purge (`:1319-1320`) evict what they drop (`for (auto& [k, b] : S.detile_maps) S.be->Evict(b, S.committed_seq + 1);` before each `clear()`, the same for `detile_staging`). `GpuDmaImpl` (`:6564`): `S.be->MakeResident(sb, GnmResidencyClass::Builtin);` after creating the pattern buffer and `S.be->Evict(sb, S.committed_seq + 1);` after the copy is encoded.

- [ ] **Step 3: Run the compute tests on both backends**

Host suite `t33`: `host=0`; the log shows `gnm_guest_memory_test` PASS lines for both environments and `gcn_wave_exec_test` PASS twice.

- [ ] **Step 4: R-check (Metal 3 unchanged), commit**

Replay build `t33`, R-check `t33 3`: `cmp=0`.

```bash
git add $G/ps4_gnm_draw.mm tests/host/gcn_wave_exec_test.mm tests/host/run_host_tests.sh
git commit -m "gnm: guest windows, arena, page table and guest memory buffers resident on Metal 4; compute tests on both backends

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

### Task 3.4: Phase 3 gate

**Files:** `docs/metal4-baseline.md` (append "Phase 3").

**Acceptance (spec table, Phase 3):** "Every compute pass of the TLOU capture set is byte-identical to Metal 3 in `gnm_replay`. `gcn_wave_exec_test` and `gnm_guest_memory_test` pass on Metal 4. The residency negative control fails without the set."

- [ ] **Step 1: Compute passes, Metal 4 vs Metal 3**

```bash
cd ~/ps4recomp-work/PS4Recomp-metal4 || exit 1
# replay build p3 (commands above), then:
for F in courtyard spores; do
  FR=$(ls -d $M/captures/$F/frame_* | head -1)
  ~/ps4recomp-work/tools/heavy_lock.sh env PS4_GNM_METAL=3 $M/replay_p3/gnm_replay "$FR" all --sha > $M/replay/p3_m3_$F.txt 2>/dev/null
  ~/ps4recomp-work/tools/heavy_lock.sh env PS4_GNM_METAL=4 PS4_GNM_MTL4_ONLY_CLEARS=1 $M/replay_p3/gnm_replay "$FR" all --sha \
    > $M/replay/p3_m4_$F.txt 2> $M/replay/p3_m4_$F.err
  python3 tools/metal4_replay_cmp.py $M/replay/p0_m3_$F.txt $M/replay/p3_m3_$F.txt | tail -1            # Metal 3 unchanged
  python3 tools/metal4_replay_cmp.py $M/replay/p3_m3_$F.txt $M/replay/p3_m4_$F.txt --type dispatch      # Metal 4 = Metal 3
done
```
Expected: both comparisons print `different: 0; missing: 0` for each frame (the second only over dispatch passes). A difference is investigated with `gnm_replay <frame> <pass> --out <dir>` on both backends and `PS4_GNM_MTL4_FULL_BARRIERS=1` (a difference that disappears with full barriers is a missing barrier); it is fixed, not listed, in this phase.

- [ ] **Step 2: Tests on Metal 4**

`grep -E "^(gcn_wave_exec_test|gnm_guest_memory_test|gnm_residency_test)" $M/host_p3.log` after the host suite `p3` (`host=0`): PASS for every run; the residency test's negative control is part of its PASS.

- [ ] **Step 3: TLOU on Metal 4, clears only, and Metal 3 regression**

TLOU game build `p3`. Route `TAG=p3_m4 METAL=4 SECS=300` with `PS4_GNM_MTL4_ONLY_CLEARS=1` (dispatches, DMA and GPU uploads now run on Metal 4): `fatal 0 gpu_err 0 watchdog 0`, flips paced as in Phase 2. `N=3 A=$M/tlou_build_p0:3 B=$M/tlou_build_p3:3 TAG=p3_ab tools/metal4_perf_ab.sh`: within noise.

- [ ] **Step 4: U4 smoke on Metal 4 (recorded)**

As in Task 2.6 Step 4 with tag `p3`.

- [ ] **Step 5: Go analysis, record, commit**

`go=0`. Append the Phase 3 section (replay comparison counts per frame, test results, route reports, U4 line) to `docs/metal4-baseline.md` and commit:

```bash
git add docs/metal4-baseline.md
git commit -m "Metal 4 work: Phase 3 gate numbers (compute)

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

## Phase 4: Graphics

### Task 4.1: Metal 4 draws, fixed-function state, barriers inside a pass; barrier coverage

**Files:**
- Modify: `$G/ps4_gnm_backend_metal4.mm` (`SetFixed`, `Draw` (every kind), `Barrier` in a render pass; `kMetal4BackendCaps = kGnmCapAll`; delete `NotYet` and every remaining use)
- Create: `tests/host/gnm_backend_barrier_test.mm`
- Modify: `tests/host/gnm_rectlist_test.mm` (the backend from `MakeTestBackend`), `tests/host/run_host_tests.sh`

**Interfaces:**
- Consumes: Tasks 2.3, 3.1.
- Produces: `kMetal4BackendCaps == kGnmCapAll`; `ChooseBackend("4", …)` now accepts runs without the debug mode.

- [ ] **Step 1: Write the failing tests**

`gnm_rectlist_test.mm`: the fixture's `f.be = ps4gnm::MakeMetal3Backend()` (Task 1.5) becomes `f.be = MakeTestBackend(f.dev, &why)` (`#include "backend_harness.h"`), and every texture and buffer the test creates is made resident (`f.be->MakeResident(x, …)` after each `newTextureWithDescriptor` / `newBuffer…`); its `run_host_tests.sh` line runs it for `m in 3 4` with `MTL_DEBUG_LAYER=1`.

`tests/host/gnm_backend_barrier_test.mm`:

```objc
// Barrier coverage (docs/metal4-backend.md, "Synchronisation"): a render pass that samples a
// texture a compute pass just wrote, in one seq, sees every texel the compute pass wrote, on the
// backend PS4_GNM_METAL selects (Metal 3 orders the two encoders by its hazard tracking, Metal 4
// by the barrier at the render encoder's start). The compute pass is slow on purpose (a long
// dependent loop per texel), so an unordered render pass would read texels not written yet. The
// teeth: on Metal 4 with PS4_GNM_MTL4_NO_BARRIERS=1 at least one of 8 tries must read wrong texels.
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>

#include <vector>

#include "backend_harness.h"
#include "ps4_gnm_util_passes.h"

using namespace ps4gnm;

static int g_fail = 0;
#define CHECK(c, ...)                                                                        \
    do {                                                                                     \
        if (!(c)) {                                                                          \
            fprintf(stderr, "gnm_backend_barrier_test: FAIL %s:%d: ", __FILE__, __LINE__);   \
            fprintf(stderr, __VA_ARGS__);                                                    \
            fprintf(stderr, "\n");                                                           \
            g_fail++;                                                                        \
        }                                                                                    \
    } while (0)

static const char* kMsl = R"(
#include <metal_stdlib>
using namespace metal;
kernel void slow_write(texture2d<uint, access::write> out [[texture(0)]], constant uint& n [[buffer(0)]],
                       uint2 p [[thread_position_in_grid]]) {
    uint v = p.x * 131u + p.y;
    for (uint i = 0; i < n; ++i) v = v * 1664525u + 1013904223u;
    out.write(uint4(v, 0, 0, 0), p);
}
struct VOut { float4 pos [[position]]; };
vertex VOut tri_vs(uint vid [[vertex_id]]) {
    VOut o;
    float2 uv = float2((vid << 1) & 2, vid & 2);
    o.pos = float4(uv * 2.0 - 1.0, 0.0, 1.0);
    return o;
}
fragment uint4 sample_fs(VOut in [[stage_in]], texture2d<uint> src [[texture(0)]]) {
    return uint4(src.read(uint2(in.pos.xy)).r, 0, 0, 1);
}
)";

constexpr uint32_t kW = 128, kH = 128, kLoop = 200000;

static uint32_t Expected(uint32_t x, uint32_t y) {
    uint32_t v = x * 131u + y;
    for (uint32_t i = 0; i < kLoop; ++i) v = v * 1664525u + 1013904223u;
    return v;
}

// One seq: compute writes `tex`, the render pass copies it into `rt`; returns the wrong texels of rt.
static uint32_t RunOnce(GnmBackend& be, id<MTLComputePipelineState> cs, id<MTLRenderPipelineState> rs, id<MTLTexture> tex,
                        id<MTLTexture> rt, const std::vector<uint32_t>& want, uint64_t seq) {
    std::vector<uint32_t> zero(kW * kH, 0);
    [tex replaceRegion:MTLRegionMake2D(0, 0, kW, kH) mipmapLevel:0 withBytes:zero.data() bytesPerRow:kW * 4];
    [rt replaceRegion:MTLRegionMake2D(0, 0, kW, kH) mipmapLevel:0 withBytes:zero.data() bytesPerRow:kW * 4];
    const uint32_t n = kLoop;
    be.BeginCmd(GnmCmdTarget::Main, @"barrier", false);
    be.BeginCompute(false);
    be.SetComputePipeline(cs);
    be.BindTexture(GnmStage::Compute, 0, tex);
    be.BindBytes(GnmStage::Compute, 0, &n, sizeof(n));
    be.Dispatch(MTLSizeMake(kW / 8, kH / 8, 1), MTLSizeMake(8, 8, 1));
    be.EndEncoder();
    GnmPassDesc pd;
    pd.color[0].tex = rt;
    pd.color[0].load = GnmLoad::DontCare;
    if (!FullscreenPass(be, pd, rs, nil, tex)) return kW * kH;
    if (!CommitAndWait(be, seq)) return kW * kH;
    std::vector<uint32_t> got(kW * kH);
    [rt getBytes:got.data() bytesPerRow:kW * 4 fromRegion:MTLRegionMake2D(0, 0, kW, kH) mipmapLevel:0];
    uint32_t bad = 0;
    for (size_t i = 0; i < got.size(); ++i) bad += got[i] != want[i];
    return bad;
}

static bool Build(id<MTLDevice> dev, id<MTLComputePipelineState>* cs, id<MTLRenderPipelineState>* rs) {
    NSError* e = nil;
    id<MTLLibrary> lib = [dev newLibraryWithSource:[NSString stringWithUTF8String:kMsl] options:nil error:&e];
    if (!lib) return false;
    *cs = [dev newComputePipelineStateWithFunction:[lib newFunctionWithName:@"slow_write"] error:&e];
    MTLRenderPipelineDescriptor* d = [MTLRenderPipelineDescriptor new];
    d.vertexFunction = [lib newFunctionWithName:@"tri_vs"];
    d.fragmentFunction = [lib newFunctionWithName:@"sample_fs"];
    d.colorAttachments[0].pixelFormat = MTLPixelFormatR32Uint;
    *rs = [dev newRenderPipelineStateWithDescriptor:d error:&e];
    return *cs && *rs;
}

static id<MTLTexture> Tex(id<MTLDevice> dev, GnmBackend& be, MTLTextureUsage u) {
    MTLTextureDescriptor* td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatR32Uint width:kW
                                                                                 height:kH mipmapped:NO];
    td.usage = u;
    td.storageMode = MTLStorageModeShared;
    id<MTLTexture> t = [dev newTextureWithDescriptor:td];
    be.MakeResident(t, GnmResidencyClass::Texture);
    return t;
}

int main() {
    @autoreleasepool {
        id<MTLDevice> dev = MTLCreateSystemDefaultDevice();
        std::string why;
        std::unique_ptr<GnmBackend> be = dev ? MakeTestBackend(dev, &why) : nullptr;
        id<MTLComputePipelineState> cs = nil;
        id<MTLRenderPipelineState> rs = nil;
        if (!be || !Build(dev, &cs, &rs)) {
            printf("gnm_backend_barrier_test: FAIL: %s\n", be ? "pipelines" : why.c_str());
            return 1;
        }
        std::vector<uint32_t> want(kW * kH);
        for (uint32_t y = 0; y < kH; ++y)
            for (uint32_t x = 0; x < kW; ++x) want[y * kW + x] = Expected(x, y);
        id<MTLTexture> tex = Tex(dev, *be, MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite);
        id<MTLTexture> rt = Tex(dev, *be, MTLTextureUsageRenderTarget);
        uint64_t seq = 0;
        for (int i = 0; i < 4; ++i) {
            const uint32_t bad = RunOnce(*be, cs, rs, tex, rt, want, ++seq);
            CHECK(bad == 0, "try %d: %u of %u texels wrong: the render pass ran before the compute pass's writes", i, bad, kW * kH);
        }
        if (be->Kind() == GnmBackendKind::Metal4) {
            setenv("PS4_GNM_MTL4_NO_BARRIERS", "1", 1);
            std::unique_ptr<GnmBackend> nb = MakeTestBackend(dev, &why);
            unsetenv("PS4_GNM_MTL4_NO_BARRIERS");
            id<MTLTexture> tex2 = Tex(dev, *nb, MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite);
            id<MTLTexture> rt2 = Tex(dev, *nb, MTLTextureUsageRenderTarget);
            uint32_t worst = 0;
            uint64_t s2 = 0;
            for (int i = 0; i < 8 && worst == 0; ++i) worst = std::max(worst, RunOnce(*nb, cs, rs, tex2, rt2, want, ++s2));
            CHECK(worst > 0, "without encoder barriers every try was right: the test cannot see a missing barrier "
                             "(make the compute pass slower: kLoop)");
        }
        printf("gnm_backend_barrier_test: backend %s\n", BackendName(be->Kind()));
    }
    printf("gnm_backend_barrier_test: %s\n", g_fail ? "FAIL" : "PASS");
    return g_fail ? 1 : 0;
}
```

(`#include <algorithm>`.) `run_host_tests.sh` after the copy test:

```bash
# Barrier coverage: a render pass sampling a texture a compute pass just wrote sees every texel,
# on each backend; on Metal 4 without encoder barriers the test sees the race (its teeth).
clang++ -std=c++17 -fobjc-arc -Wall -Werror -I "$G" -I "$R/tests/host" "$R/tests/host/gnm_backend_barrier_test.mm" "${BE[@]}" \
  -framework Metal -framework Foundation -o "$T/gnm_backend_barrier_test"
for m in 3 4; do PS4_GNM_METAL=$m gpu "$T/gnm_backend_barrier_test"; done
```

Run the rect-list and barrier tests → Expected: Metal 3 PASS; Metal 4 rect-list `FATAL: … SetFixed is not implemented yet (Task 4.1 …)`. The barrier test passes on Metal 4 already (compute, `FullscreenPass` and the start barriers exist since Tasks 2.3/3.1): its teeth check is what this task adds to the suite; record that its no-barrier run did read wrong texels.

- [ ] **Step 2: Implement**

```objc
const uint32_t kMetal4BackendCaps = kGnmCapAll;

void Metal4Backend::SetFixed(const GnmFixedState& f, uint32_t changed) {
    id<MTL4RenderCommandEncoder> e = Cur().renc;
    if (changed & kGnmFixedStencilRef) [e setStencilFrontReferenceValue:f.stencil_ref[0] backReferenceValue:f.stencil_ref[1]];
    if (changed & kGnmFixedViewport) [e setViewport:f.vp];
    if (changed & kGnmFixedScissor) [e setScissorRect:f.sc];
    if (changed & kGnmFixedCull) [e setCullMode:(MTLCullMode)f.cull];
    if (changed & kGnmFixedWinding) [e setFrontFacingWinding:(MTLWinding)f.winding];
    if (changed & kGnmFixedFill) [e setTriangleFillMode:(MTLTriangleFillMode)f.fill];
    if (changed & kGnmFixedClip) [e setDepthClipMode:(MTLDepthClipMode)f.clip];
    if (changed & kGnmFixedBias) [e setDepthBias:f.bias[0] slopeScale:f.bias[1] clamp:f.bias[2]];
    if (changed & kGnmFixedBlend) [e setBlendColorRed:f.blend[0] green:f.blend[1] blue:f.blend[2] alpha:f.blend[3]];
}

void Metal4Backend::Draw(const GnmDraw& d) {
    id<MTL4RenderCommandEncoder> e = Cur().renc;
    switch (d.kind) {
    case GnmDrawKind::Direct:
        [e drawPrimitives:d.prim vertexStart:d.vertex_start vertexCount:d.count instanceCount:d.instances
             baseInstance:d.base_instance];
        break;
    case GnmDrawKind::Indexed:
        [e drawIndexedPrimitives:d.prim indexCount:d.count indexType:d.index_type
                     indexBuffer:d.index_buffer.gpuAddress + d.index_offset indexBufferLength:d.index_length
                   instanceCount:d.instances baseVertex:d.base_vertex baseInstance:d.base_instance];
        break;
    case GnmDrawKind::Indirect:
        [e drawPrimitives:d.prim indirectBuffer:d.indirect_buffer.gpuAddress + d.indirect_offset];
        break;
    case GnmDrawKind::IndexedIndirect:
        [e drawIndexedPrimitives:d.prim indexType:d.index_type indexBuffer:d.index_buffer.gpuAddress + d.index_offset
               indexBufferLength:d.index_length indirectBuffer:d.indirect_buffer.gpuAddress + d.indirect_offset];
        break;
    }
    if (full_barriers_)
        [e barrierAfterEncoderStages:MTLStageVertex | MTLStageFragment beforeEncoderStages:MTLStageVertex | MTLStageFragment
                   visibilityOptions:MTL4VisibilityOptionDevice];
}
```

`Barrier`, render branch: `[x.renc barrierAfterEncoderStages:(MTLStages)after & (MTLStageVertex | MTLStageFragment) ?: MTLStageVertex beforeEncoderStages:(MTLStages)before & (MTLStageVertex | MTLStageFragment) ?: MTLStageVertex visibilityOptions:MTL4VisibilityOptionDevice];` (the rect list's vertex → vertex barrier). Delete `NotYet` and its every use: `QueueSignal`/`QueueWait` have their full form since Task 2.3; `grep -n NotYet $G/ps4_gnm_backend_metal4.mm` prints nothing.

- [ ] **Step 3: Run the tests**

`gnm_rectlist_test` and `gnm_backend_barrier_test` for `m in 3 4` → four PASS lines (rect-list corner colours equal on both backends). The select test still passes (`kMetal4BackendCaps` is not part of it).

- [ ] **Step 4: Replay on Metal 4 without the debug mode; R-check; host suite**

Replay build `t41`; R-check `t41 3`: `cmp=0`; then `PS4_GNM_METAL=4 $M/replay_t41/gnm_replay <courtyard frame> all --sha > $M/replay/t41_m4_courtyard.txt` and `python3 tools/metal4_replay_cmp.py $M/replay/t41_m3_courtyard.txt $M/replay/t41_m4_courtyard.txt`: record the result (Task 4.5 requires 0 differences; differences here are investigated now: draw passes only, the dispatch ones were equal in Phase 3). Host suite `t41`: `host=0`.

- [ ] **Step 5: Commit**

```bash
git add $G/ps4_gnm_backend_metal4.mm tests/host/gnm_backend_barrier_test.mm tests/host/gnm_rectlist_test.mm tests/host/run_host_tests.sh
git commit -m "gnm: Metal 4 draws (all kinds, explicit index lengths), fixed state, barriers in a pass; barrier coverage test

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

### Task 4.2: Residency of the renderer's own textures; texture cache copies on the timeline

**Files:**
- Modify: `$G/ps4_gnm_draw.mm`: `ForgetTexture` (`:1339-1348`), `DepthCompanion` (`:4985`), `MipChainFor` (`:5052-5061`), `DepthFromMemory` (`:5098-5104`), `EqaaTwin` (`:5554-5568`), `Init` (the GPU copy hook)
- Modify: `$G/ps4_gnm_resources.h` / `.mm` (`TextureCache::GpuCopyHook`, `SetGpuCopyHook`; the alias copy of `GetTextureImpl` `:3274-3287`)
- Test: `tests/host/gnm_residency_test.mm` (case `TestViews`), `tests/host/tex_evict_test.mm` (case `test_gpu_copy_hook`)

**Interfaces:**
- Consumes: `UploadTargetScope` (Task 1.6), `GnmBackend::{BeginCopies, CopyTextureRegion, EndEncoder, MakeResident, Evict}`.
- Produces: `struct TextureCache::GpuCopyHook { void* ctx = nullptr; void (*copy)(void* ctx, id<MTLTexture> src, id<MTLTexture> dst, MTLSize size) = nullptr; };`, `void TextureCache::SetGpuCopyHook(const GpuCopyHook& h);` (set: the alias copy is encoded by the renderer on its timeline, in the upload command buffer, ordered after every committed seq and before the open one; unset: the cache's own command buffer on its queue, as before, for tests that use the cache alone).

- [ ] **Step 1: Write the failing tests**

`tests/host/gnm_residency_test.mm`, Metal 4 case:

```objc
// A view of a resident texture, sampled in a Metal 4 render pass, reads the parent's texels: the
// renderer makes only the textures it creates resident, never their views (AdaptTexture, aliases).
static void TestViews(id<MTLDevice> dev) {
    if (!RequireMetal4(dev, "gnm_residency_test (views)")) return;
    Metal4Backend be;
    std::string why;
    GnmUtil util;
    CHECK(be.Init(dev, &why) && MakeGnmUtil(dev, &util, &why), "%s", why.c_str());
    MTLTextureDescriptor* td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm
                                                                                  width:32 height:32 mipmapped:NO];
    td.usage = MTLTextureUsageShaderRead | MTLTextureUsagePixelFormatView;
    td.storageMode = MTLStorageModeShared;
    id<MTLTexture> parent = [dev newTextureWithDescriptor:td];
    std::vector<uint32_t> px(32 * 32, 0xFF4080C0u); // ABGR in memory: r = 0xC0, g = 0x80, b = 0x40
    [parent replaceRegion:MTLRegionMake2D(0, 0, 32, 32) mipmapLevel:0 withBytes:px.data() bytesPerRow:128];
    id<MTLTexture> view = [parent newTextureViewWithPixelFormat:MTLPixelFormatRGBA8Unorm];
    td.pixelFormat = MTLPixelFormatBGRA8Unorm;
    td.usage = MTLTextureUsageRenderTarget;
    id<MTLTexture> rt = [dev newTextureWithDescriptor:td];
    be.MakeResident(parent, GnmResidencyClass::Texture);
    be.MakeResident(rt, GnmResidencyClass::Texture);
    be.BeginCmd(GnmCmdTarget::Main, @"view", false);
    GnmPassDesc pd;
    pd.color[0].tex = rt;
    pd.color[0].load = GnmLoad::DontCare;
    CHECK(FullscreenPass(be, pd, util.present, nil, view), "pass");
    CHECK(CommitAndWait(be, 1), "seq failed");
    uint32_t got = 0;
    [rt getBytes:&got bytesPerRow:128 fromRegion:MTLRegionMake2D(7, 9, 1, 1) mipmapLevel:0];
    CHECK(got == 0xFFC08040u, "view of a resident texture read %08x, want ffc08040 (BGRA of the parent's texel)", got);
}
```

(`#include "ps4_gnm_util_passes.h"`; call from `main`.) If this check fails, views are not covered by their parent on this machine: then `AdaptTextureUncached` and `TextureCache`'s alias views also call `MakeResident(view, Texture)` at creation and `Evict` when they are dropped (`g_view_cache_gen` reset, entry drop) — add that to Step 2 and keep the test.

`tests/host/tex_evict_test.mm`:

```objc
// The texture cache's alias copy (a GPU target sampled with other dimensions) goes through the GPU
// copy hook when one is set: once per new alias, with the target as the source and the alias's
// parent as the destination, and none through the cache's own queue.
static void test_gpu_copy_hook(id<MTLDevice> dev) {
    id<MTLCommandQueue> q = [dev newCommandQueue];
    Guest g;
    g.size = 16 * MiB;
    g.base = (uint8_t*)mmap(nullptr, g.size, PROT_READ | PROT_WRITE, MAP_ANON | MAP_PRIVATE, -1, 0);
    struct Hook {
        int calls = 0;
        __unsafe_unretained id<MTLTexture> src = nil, dst = nil;
        MTLSize size{};
    } hk;
    @autoreleasepool {
        TextureCache tc(dev, q, g.base, g.size);
        TextureCache::GpuCopyHook h;
        h.ctx = &hk;
        h.copy = [](void* c, id<MTLTexture> s, id<MTLTexture> d, MTLSize n) {
            Hook* x = static_cast<Hook*>(c);
            x->calls++;
            x->src = s;
            x->dst = d;
            x->size = n;
        };
        tc.SetGpuCopyHook(h);
        tc.SetUse(1, 1000 * MS);
        id<MTLTexture> rt = tc.GetColorTarget(Rt(0x100000), false); // 64x64 RGBA8
        id<MTLTexture> a = tc.GetTexture(Tsharp(0x100000, 32, 32));  // the same memory sampled as 32x32
        check(rt && a, "copy hook: target and its alias");
        check(hk.calls == 1, "copy hook: the alias copy went through the hook, once");
        check(hk.src == rt && hk.dst && hk.dst.width == 32 && hk.dst.height == 32 && hk.size.width == 32 &&
                  hk.size.height == 32,
              "copy hook: target -> 32x32 copy, 32x32 region");
        check(tc.GetTexture(Tsharp(0x100000, 32, 32)) == a && hk.calls == 1, "copy hook: the alias is reused, no second copy");
    }
    munmap(g.base, g.size);
}
```

(`main` calls `test_gpu_copy_hook(dev);`.)

Run both builds → Expected: compile error `no type named 'GpuCopyHook'` (tex_evict_test); the residency test's view case runs (record its result).

- [ ] **Step 2: Implement**

`ps4_gnm_resources.h`, public:

```objc
    // The GPU copy of a target into the sampled copy an alias views (different dimensions). Set: the
    // renderer encodes it on its own timeline (its upload command buffer). Unset: a command buffer of
    // the cache's queue, committed at once (tests that use the cache alone).
    struct GpuCopyHook {
        void* ctx = nullptr;
        void (*copy)(void* ctx, id<MTLTexture> src, id<MTLTexture> dst, MTLSize size) = nullptr;
    };
    void SetGpuCopyHook(const GpuCopyHook& h) { copy_hook_ = h; }
```

private: `GpuCopyHook copy_hook_;`. `GetTextureImpl` (`:3276-3287`):

```objc
            const MTLSize sz = MTLSizeMake(std::min(width, e->width), std::min(height, e->height), 1);
            if (copy_hook_.copy) {
                copy_hook_.copy(copy_hook_.ctx, e->tex, copy, sz);
            } else {
                id<MTLCommandBuffer> cb = [queue_ commandBuffer];
                id<MTLBlitCommandEncoder> bl = [cb blitCommandEncoder];
                [bl copyFromTexture:e->tex sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0, 0, 0) sourceSize:sz
                          toTexture:copy destinationSlice:0 destinationLevel:0 destinationOrigin:MTLOriginMake(0, 0, 0)];
                [bl endEncoding];
                [cb commit];
            }
```

`ps4_gnm_draw.mm`, before `Init`:

```cpp
// TextureCache alias copies (GpuCopyHook): in the upload command buffer, which runs after every
// committed seq and before the open one, as the cache's own command buffer did on Metal 3's queue.
void AliasCopy(void*, id<MTLTexture> src, id<MTLTexture> dst, MTLSize size) {
    UploadTargetScope on_upload;
    S.be->BeginCopies();
    S.be->CopyTextureRegion(src, 0, 0, MTLOriginMake(0, 0, 0), size, dst, 0, 0, MTLOriginMake(0, 0, 0));
    S.be->EndEncoder();
}
```

and in `Init`: `S.tex->SetGpuCopyHook(TextureCache::GpuCopyHook{nullptr, AliasCopy});`. (On Metal 3 this moves the copy from a command buffer committed at once to the upload command buffer committed right before the open one: both run after the committed seqs and before the open seq; the R-check confirms nothing changed.) The copy texture the alias views is created by `NewTextureLocked` (resident since Task 2.4); `UploadTargetScope` must not be entered while the cache's lock is held by the same thread if `BeginCmd` could re-enter the cache: it does not (it touches only the backend and `g_gms`).

Renderer-owned textures: `DepthCompanion` after `c.tex = [S.dev newTextureWithDescriptor:td];` → `S.be->MakeResident(c.tex, GnmResidencyClass::Texture);`. `MipChainFor` before `mc.tex = [S.dev newTextureWithDescriptor:td];` → `if (mc.tex) S.be->Evict(mc.tex, S.committed_seq + 1);` and after it `S.be->MakeResident(mc.tex, GnmResidencyClass::Texture);`. `DepthFromMemory` around `ent.first = …` the same. `EqaaTwin`: `S.be->MakeResident(twin, GnmResidencyClass::Texture);` and, when it replaces one (`it != S.eqaa_twin.end()`), `S.be->Evict(it->second, S.committed_seq + 1);`. `ForgetTexture` evicts what it erases: `if (auto c = S.depth_comp.find(key); c != S.depth_comp.end() && c->second.tex) S.be->Evict(c->second.tex, S.committed_seq + 1);` before the erase, and `S.be->Evict(tw->second, S.committed_seq + 1);` for the twin.

- [ ] **Step 3: Run the tests, R-check both backends, host suite**

`tex_evict_test`: PASS. `PS4_GNM_METAL=4 gnm_residency_test`: PASS. Replay build `t42`; R-check `t42 3`: `cmp=0`; Metal 4 replay of the courtyard frame vs `t42_m3`: record (no new difference compared with Task 4.1). Host suite `t42`: `host=0`.

- [ ] **Step 4: Commit**

```bash
git add $G/ps4_gnm_draw.mm $G/ps4_gnm_resources.h $G/ps4_gnm_resources.mm tests/host/gnm_residency_test.mm tests/host/tex_evict_test.mm
git commit -m "gnm: renderer-owned textures resident on Metal 4; texture cache alias copies on the renderer's timeline

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

### Task 4.3: Every renderer-level test on both backends

**Files:**
- Modify: `tests/host/run_host_tests.sh` (`gnm_submit_flip_nonblocking_test`, `gnm_replay_test`, `gnm_buffer_over_target_test`, `gnm_guest_memory_test`, `gnm_tsharp_table_test`, `gnm_capture_tex_test` and `tex_evict_test` loops over `PS4_GNM_METAL=3 4`, the Metal 4 runs without `PS4_GNM_MTL4_ONLY_CLEARS`)
- Modify: `tests/host/gnm_capture_tex_test.mm`, `tests/host/tex_evict_test.mm` (their queue: the selected backend's `SideQueue()`, their textures' hooks into the backend's residency under Metal 4)

**Interfaces:**
- Consumes: Tasks 4.1–4.2, `MakeTestBackend`.
- Produces: the suite runs every renderer-level test on both backends (the spec's host-suite rule).

- [ ] **Step 1: Wire the loops**

Each run line of the seven tests becomes a loop, for example:

```bash
for m in 3 4; do
  for mode in sync async nohooks; do
    PS4_GNM_METAL=$m "$T/rt_test/gnm_submit_flip_nonblocking_test" $mode > "$T/flip_nonblocking.txt" 2>&1 ||
      { echo "PS4_GNM_METAL=$m $mode:"; cat "$T/flip_nonblocking.txt"; exit 1; }
    grep "^gnm_submit_flip_nonblocking_test" "$T/flip_nonblocking.txt"
  done
done
```

The Task 3.3 `env $env` loop drops `PS4_GNM_MTL4_ONLY_CLEARS=1`. `gnm_capture_tex_test` and `tex_evict_test` build with `"${BE[@]}"` and `-I "$R/tests/host"`, create `MakeTestBackend` in `main`, pass `be->SideQueue()` where they made `[dev newCommandQueue]` for the `TextureCache`, and, under Metal 4, install `TextureHooks` that forward to `be->MakeResident`/`be->Evict` and assert at the end that `static_cast<Metal4Backend&>(*be).Residency().Count()` equals the number of textures the cache still holds (0 after the cache is destroyed and the backend retires: call `Residency().Retire(UINT64_MAX)` first).

- [ ] **Step 2: Run the suite**

Host suite `t43`. Expected `host=0`; every listed test prints its PASS line twice. A Metal 4 failure here is a real bug of Phases 2–4: fix it in this task (with a test that fails before the fix), never by dropping the Metal 4 run.

- [ ] **Step 3: Commit**

```bash
git add tests/host/run_host_tests.sh tests/host/gnm_capture_tex_test.mm tests/host/tex_evict_test.mm
git commit -m "tests: every renderer-level host test on both backends

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

### Task 4.4: Screenshot comparison tool

**Files:**
- Create: `tools/metal4_shot_diff.py`, `tools/tests/test_metal4_shot_diff.py`
- Modify: `.gitignore` (`!/tools/metal4_shot_diff.py`)

**Interfaces:**
- Consumes: `tools/refcompare.py:read_png`.
- Produces: `python3 tools/metal4_shot_diff.py <a.png> <b.png> [--threshold T]`: prints `identical` (exit 0), or `differ: <n> pixels, max channel diff <d>, <k> pixels above <T>` (exit 0 if k == 0, else 1); different sizes: `size differs` (exit 1).

- [ ] **Step 1: Write the failing test**

```python
# Tests tools/metal4_shot_diff.py on generated PNGs.
import os
import struct
import subprocess
import sys
import tempfile
import unittest
import zlib

TOOL = os.path.join(os.path.dirname(__file__), "..", "metal4_shot_diff.py")


def write_png(path, w, h, pixel):
    raw = b"".join(b"\x00" + b"".join(bytes(pixel(x, y)) for x in range(w)) for y in range(h))
    def chunk(t, d):
        return struct.pack(">I", len(d)) + t + d + struct.pack(">I", zlib.crc32(t + d) & 0xFFFFFFFF)
    with open(path, "wb") as f:
        f.write(b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0)) +
                chunk(b"IDAT", zlib.compress(raw)) + chunk(b"IEND", b""))


def run(a, b, *args):
    p = subprocess.run([sys.executable, TOOL, a, b, *args], capture_output=True, text=True)
    return p.returncode, p.stdout.strip()


class ShotDiffTest(unittest.TestCase):
    def test_cases(self):
        with tempfile.TemporaryDirectory() as d:
            a, b, c, e = (os.path.join(d, n) for n in ("a.png", "b.png", "c.png", "e.png"))
            write_png(a, 8, 4, lambda x, y: (x * 10, y * 20, 50))
            write_png(b, 8, 4, lambda x, y: (x * 10, y * 20, 50))
            write_png(c, 8, 4, lambda x, y: (x * 10 + (3 if (x, y) == (2, 1) else 0), y * 20, 50 + (9 if (x, y) == (5, 3) else 0)))
            write_png(e, 4, 4, lambda x, y: (0, 0, 0))
            self.assertEqual(run(a, b), (0, "identical"))
            self.assertEqual(run(a, c, "--threshold", "4"), (1, "differ: 2 pixels, max channel diff 9, 1 pixels above 4"))
            self.assertEqual(run(a, c, "--threshold", "9"), (0, "differ: 2 pixels, max channel diff 9, 0 pixels above 9"))
            self.assertEqual(run(a, e)[0], 1)


if __name__ == "__main__":
    unittest.main()
```

Run `python3 -m unittest tools/tests/test_metal4_shot_diff.py` → Expected: FAIL (no tool).

- [ ] **Step 2: Implement**

```python
#!/usr/bin/env python3
"""Per-pixel comparison of two screenshots (docs/metal4-backend.md, "Screenshot parity").

usage: metal4_shot_diff.py <a.png> <b.png> [--threshold T]

Prints "identical", or how many pixels differ, the largest channel difference and how many
pixels differ by more than T in some channel (default 0). Exit status 0: identical or no pixel
above T; 1: otherwise, or the sizes differ.
"""
import argparse
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from refcompare import read_png  # noqa: E402


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("a")
    ap.add_argument("b")
    ap.add_argument("--threshold", type=int, default=0)
    o = ap.parse_args()
    wa, ha, ra = read_png(o.a)
    wb, hb, rb = read_png(o.b)
    if (wa, ha) != (wb, hb):
        print("size differs: %dx%d vs %dx%d" % (wa, ha, wb, hb))
        return 1
    n = above = mx = 0
    for la, lb in zip(ra, rb):
        if la == lb:
            continue
        for x in range(wa):
            d = max(abs(la[3 * x + k] - lb[3 * x + k]) for k in range(3))
            if d:
                n += 1
                mx = max(mx, d)
                above += d > o.threshold
    if not n:
        print("identical")
        return 0
    print("differ: %d pixels, max channel diff %d, %d pixels above %d" % (n, mx, above, o.threshold))
    return 0 if above == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
```

`.gitignore`: `!/tools/metal4_shot_diff.py`.

- [ ] **Step 3: Run the test, commit**

`python3 -m unittest discover -s tools/tests -p 'test_metal4_*.py'` → `OK`.

```bash
git add .gitignore tools/metal4_shot_diff.py tools/tests/test_metal4_shot_diff.py
git commit -m "tools: per-pixel screenshot comparison for the Metal 4 parity checks

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

### Task 4.5: Phase 4 gate

**Files:** `docs/metal4-baseline.md` (append "Phase 4"), `docs/metal4-backend.md` ("Known differences" if any).

**Acceptance (spec table, Phase 4):** "All TLOU replay passes byte-identical to Metal 3; any difference is explained and listed. TLOU route screenshots at three checkpoints match Metal 3: exact, or below a per-pixel threshold on effects shown to be non-deterministic, each listed. No new skipped draws."

- [ ] **Step 1: Every replay pass, Metal 4 vs Metal 3**

Replay build `p4`; for both frames: `PS4_GNM_METAL=3 … > p4_m3_<F>.txt`, `PS4_GNM_METAL=4 … > p4_m4_<F>.txt`; `python3 tools/metal4_replay_cmp.py p0_m3_<F>.txt p4_m3_<F>.txt` (Metal 3 unchanged since Phase 0) and `python3 tools/metal4_replay_cmp.py p4_m3_<F>.txt p4_m4_<F>.txt` (all passes). Expected: `different: 0; missing: 0` everywhere. Each remaining difference gets: the pass, its outputs, the cause (found with `--out` dumps of both backends, `PS4_GNM_MTL4_FULL_BARRIERS=1`, and the pass's shaders in `tools/gnm_capture_view.py`), and why it is not a bug, in `docs/metal4-backend.md` "Known differences"; a difference that is a bug is fixed first (with a replay-based test where the pass can be extracted with `tools/gnm_capture_extract.py`).

- [ ] **Step 2: Screenshots at three checkpoints**

TLOU game build `p4`. Two Metal 3 runs and two Metal 4 runs of the route with screenshots every 600 frames:

```bash
for r in a b; do for m in 3 4; do
  ~/ps4recomp-work/tools/heavy_lock.sh env BUILD=$M/tlou_build_p4 TAG=p4_shots_m${m}$r METAL=$m SECS=300 EVERY=600 tools/metal4_route.sh
  python3 tools/metal4_route_report.py $M/runs/p4_shots_m${m}$r.log
done; done
for f in frame_002400.png frame_004800.png frame_007200.png; do
  echo "$f m3a/m3b: $(python3 tools/metal4_shot_diff.py $M/runs/shots_p4_shots_m3a/$f $M/runs/shots_p4_shots_m3b/$f)"
  echo "$f m3a/m4a: $(python3 tools/metal4_shot_diff.py $M/runs/shots_p4_shots_m3a/$f $M/runs/shots_p4_shots_m4a/$f)"
  echo "$f m4a/m4b: $(python3 tools/metal4_shot_diff.py $M/runs/shots_p4_shots_m4a/$f $M/runs/shots_p4_shots_m4b/$f)"
done
```

(If the route presents fewer than 7,200 frames in 300 s, take the last three multiples of 600 present in all four runs as the checkpoints.) Expected per checkpoint: `m3a/m4a` identical; or, where `m3a/m3b` also differs (the effect is non-deterministic run to run on Metal 3: animated water, particles, time-based effects), `m3a/m4a` differs by no more than `m3a/m3b` does: rerun `metal4_shot_diff.py` with `--threshold` set to the `m3a/m3b` max channel diff, which must print `0 pixels above`. Open each differing pair with the Read tool and name the effect. List every checkpoint, its result and the named effects in the baseline file.

- [ ] **Step 3: No new skipped draws**

From the four reports: `skipped` of the Metal 4 runs ≤ that of the Metal 3 runs of the same build, and the Metal 3 runs' `skipped` ≤ the Phase 0 runs' (`docs/metal4-baseline.md`).

- [ ] **Step 4: Host suite, Metal 3 regression, U4 smoke, Go analysis**

Host suite `p4`: `host=0`. `N=3 A=$M/tlou_build_p0:3 B=$M/tlou_build_p4:3 TAG=p4_ab tools/metal4_perf_ab.sh`: within noise. U4 smoke on Metal 4 (now without `PS4_GNM_MTL4_ONLY_CLEARS`), recorded. `go=0`.

- [ ] **Step 5: Record and commit**

```bash
git add docs/metal4-baseline.md docs/metal4-backend.md
git commit -m "Metal 4 work: Phase 4 gate numbers (graphics parity)

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

## Phase 5: Residency hardening

### Task 5.1: Bind-time residency check

**Files:**
- Modify: `$G/ps4_gnm_backend_metal4.h` / `.mm` (`check_residency_`, `CheckResident`, the bind ops `OpBuffer`, `OpBufferOffset`, `OpTexture`, `OpUse`, `Draw` index/indirect buffers, `DispatchIndirect`, the copy ops)
- Test: `tests/host/gnm_residency_test.mm` (case `TestBindCheck`)

**Interfaces:**
- Consumes: `GnmResidency::Contains` (Task 2.1).
- Produces: under `PS4_GNM_RESIDENCY_CHECK=1` (read once in `Init`) every resource bound, used, drawn from or copied on Metal 4 that is in no residency set prints one line `[gnm-residency] ASSERT <what> <label or address> not resident` per distinct resource (a set of already reported pointers), and `GnmBackendStats::residency_asserts` counts every occurrence. Off: no lookup at all (the bind path is unchanged).

- [ ] **Step 1: Write the failing test**

```objc
// The bind-time residency check (PS4_GNM_RESIDENCY_CHECK=1) reports a buffer bound while in no
// residency set, once per buffer, and nothing for a resident one or after the check is off.
static void TestBindCheck(id<MTLDevice> dev) {
    if (!RequireMetal4(dev, "gnm_residency_test (bind check)")) return;
    for (int on = 1; on >= 0; --on) {
        if (on) setenv("PS4_GNM_RESIDENCY_CHECK", "1", 1);
        Metal4Backend be;
        std::string why;
        CHECK(be.Init(dev, &why), "%s", why.c_str());
        unsetenv("PS4_GNM_RESIDENCY_CHECK");
        id<MTLBuffer> in = [dev newBufferWithLength:4096 options:MTLResourceStorageModeShared];
        id<MTLBuffer> out = [dev newBufferWithLength:4096 options:MTLResourceStorageModeShared];
        be.MakeResident(in, GnmResidencyClass::Builtin);
        be.BeginCmd(GnmCmdTarget::Main, @"check", false);
        be.BeginCopies();
        be.BindBuffer(GnmStage::Compute, 0, in, 0);
        be.BindBuffer(GnmStage::Compute, 1, out, 0);
        be.BindBuffer(GnmStage::Compute, 2, out, 256);
        be.EndEncoder();
        CHECK(CommitAndWait(be, 1), "seq failed");
        const uint64_t n = be.Stats().residency_asserts;
        if (on) CHECK(n == 2, "check on: %llu asserts, want 2 (the non-resident buffer, twice)", (unsigned long long)n);
        else CHECK(n == 0, "check off: %llu asserts", (unsigned long long)n);
    }
}
```

(`GnmBackendStats` gains `uint64_t residency_asserts = 0;` in `ps4_gnm_backend.h`; Metal 3 leaves it 0.) Call it from `main`. Run → Expected: compile error (`residency_asserts`).

- [ ] **Step 2: Implement**

`ps4_gnm_backend.h`: `uint64_t residency_asserts = 0; // Metal 4, PS4_GNM_RESIDENCY_CHECK=1: non-resident resources used` in `GnmBackendStats`, and the stats log line (Task 2.5) prints it as `res_assert=<n>`.

`ps4_gnm_backend_metal4.h`, private: `bool check_residency_ = false; std::unordered_set<const void*> reported_; uint64_t residency_asserts_ = 0; void CheckResident(id<MTLResource> r, const char* what);` (`#include <unordered_set>`).

```objc
// PS4_GNM_RESIDENCY_CHECK=1: a resource the GPU will touch that is in no residency set. On Metal 4
// its reads return zeros and its writes are lost without an error (probe P4), so this is a bug of
// the caller that made it (a creation path without MakeResident, or an Evict too early).
void Metal4Backend::CheckResident(id<MTLResource> r, const char* what) {
    if (!r || res_.Contains(r)) return;
    ++residency_asserts_;
    if (!reported_.insert((__bridge const void*)r).second) return;
    const char* label = r.label.length ? r.label.UTF8String : nullptr;
    if (label) fprintf(stderr, "[gnm-residency] ASSERT %s %s not resident\n", what, label);
    else if ([r conformsToProtocol:@protocol(MTLBuffer)])
        fprintf(stderr, "[gnm-residency] ASSERT %s buffer 0x%llx (%llu bytes) not resident\n", what,
                (unsigned long long)((id<MTLBuffer>)r).gpuAddress, (unsigned long long)((id<MTLBuffer>)r).length);
    else
        fprintf(stderr, "[gnm-residency] ASSERT %s texture %p not resident\n", what, (__bridge const void*)r);
}
```

Each op starts with `if (check_residency_) CheckResident(x, "<op>");` for every resource argument: `OpBuffer`/`OpBufferOffset` (`"bind buffer"`), `OpTexture` (`"bind texture"`), `OpUse` (`"use"`; this makes the argument-buffer path checked too), `Draw` (`"index buffer"`, `"indirect buffer"`), `DispatchIndirect` (`"indirect buffer"`), `CopyBuffer`/`FillBuffer`/`CopyTexture`/`CopyTextureRegion`/`CopyBufferToTexture` (`"copy source"`, `"copy destination"`), `BeginRender` (each attachment, `"attachment"`). `Init`: `check_residency_ = EnvOn("PS4_GNM_RESIDENCY_CHECK");`. `Stats()` fills `residency_asserts`. Bytes arena chunks are resident by construction (Task 2.3); the check does not look at them.

- [ ] **Step 3: Run, R-check, host suite, commit**

`PS4_GNM_METAL=4 gnm_residency_test`: PASS. Replay build `t51`; `PS4_GNM_METAL=4 PS4_GNM_RESIDENCY_CHECK=1 gnm_replay <courtyard frame> all --sha 2> $M/replay/t51_check.err`: `grep -c 'gnm-residency\] ASSERT' $M/replay/t51_check.err` → `0` (a non-zero count is a missing `MakeResident` in the replay or the renderer: fix it in this task). R-check `t51 3`: `cmp=0`. Host suite `t51`: `host=0`.

```bash
git add $G/ps4_gnm_backend.h $G/ps4_gnm_backend_metal4.h $G/ps4_gnm_backend_metal4.mm tests/host/gnm_residency_test.mm
git commit -m "gnm: Metal 4 bind-time residency check (PS4_GNM_RESIDENCY_CHECK=1)

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

### Task 5.2: Window sweep and remap stress on both backends

**Files:**
- Modify: `tests/host/gnm_guest_memory_test.mm` (mode `remap`: `TestRemapSweepStress`; `main`)
- Modify: `$G/ps4_gnm_draw.mm` (test accessors `ps4_gnm_debug_backend`, `ps4_gnm_debug_window_count`, `ps4_gnm_debug_arena_chunks`, next to `ps4_gnm_guest_remapped` `:9036`)
- Modify: `$G/ps4_gnm_residency.h` / `.mm` (`Count(GnmResidencyClass)`), `tests/host/gnm_residency_test.mm` (its set-logic case)
- Modify: `tests/host/run_host_tests.sh` (the `remap` mode for `m in 3 4`, the Metal 4 run with `PS4_GNM_RESIDENCY_CHECK=1` and no `[gnm-residency] ASSERT` allowed)

**Interfaces:**
- Consumes: Tasks 3.3, 5.1; `ps4_gnm_guest_remapped(addr, size)` (`ps4_gnm_draw.mm:9036`, what the kernel calls when guest memory is remapped: `DropRemappedWindows` releases the windows over it at the next `GuestBuffer`); the sweep (`SweepGuestWindows` `:1285`, once a second, releases windows idle for `PS4_GNM_GPU_WINDOW_IDLE_S`).
- Produces: `extern "C" void* ps4_gnm_debug_backend(void);` (`S.be.get()`), `extern "C" uint32_t ps4_gnm_debug_window_count(void);` (`S.guest_bufs.size()`, read on the encoder thread's side under `S.mu`), `extern "C" uint32_t ps4_gnm_debug_arena_chunks(void);` (arena chunks in use plus its free list, under `S.mu`); `size_t GnmResidency::Count(GnmResidencyClass c) const;`.

- [ ] **Step 1: Write the stress mode (fails on Metal 4 without the eviction)**

`gnm_residency_test.mm` set-logic part: one buffer added to each class → `CHECK(rs.Count(GnmResidencyClass::Guest) == 1 && rs.Count() == 3, …)`. `GnmResidency::Count(GnmResidencyClass c)`: the entries of class `c` under `mu_`.

`gnm_guest_memory_test.mm`, before `main`:

```objc
extern "C" void ps4_gnm_guest_remapped(uint64_t addr, uint64_t size);
extern "C" void* ps4_gnm_debug_backend(void);
extern "C" uint32_t ps4_gnm_debug_window_count(void);
extern "C" uint32_t ps4_gnm_debug_arena_chunks(void);

// Windows dropped and re-created many times while dispatches use them: by remaps of their guest
// memory (every iteration, the source's and the destination's 64 MiB windows) and by the idle
// sweep (PS4_GNM_GPU_WINDOW_IDLE_S=1, with pauses longer than a second). Every copy is right
// (a re-created window is a new no-copy buffer: on Metal 4 it must be in a residency set before
// its dispatch, or the copy is lost), and on Metal 4 the guest residency set holds no more than
// the live windows and arena chunks once the GPU is idle (dropped windows left their set).
void TestRemapSweepStress() {
    const Entry e{kSrc, kDst, 24, 24, 24};
    for (int i = 0; i < 200; ++i) {
        Run({e}, false);
        CheckCopy(e, 0, "remap stress");
        if (g_fail) return;
        ps4_gnm_guest_remapped(kSrc & ~((64ull << 20) - 1), 64ull << 20);
        ps4_gnm_guest_remapped(kDst & ~((64ull << 20) - 1), 64ull << 20);
        if (i % 40 == 39) usleep(1200 * 1000); // the next commit's sweep releases every idle window
    }
    ps4draw::Flush(true);
    auto* be = static_cast<ps4gnm::GnmBackend*>(ps4_gnm_debug_backend());
    CHECK(be != nullptr, "no backend");
    if (be && be->Kind() == ps4gnm::GnmBackendKind::Metal4) {
        auto& m4 = static_cast<ps4gnm::Metal4Backend&>(*be);
        m4.Residency().Retire(m4.CompletedSeq());
        const uint32_t windows = ps4_gnm_debug_window_count(), chunks = ps4_gnm_debug_arena_chunks();
        const size_t guest = m4.Residency().Count(ps4gnm::GnmResidencyClass::Guest);
        CHECK(guest <= windows + chunks, "guest residency %zu > live windows %u + arena chunks %u: dropped windows stayed resident",
              guest, windows, chunks);
    }
    printf("gnm_guest_memory_test remap: %u windows live at the end\n", ps4_gnm_debug_window_count());
}
```

(`#include "ps4_gnm_backend_metal4.h"`; the test already links the renderer and, since Task 3.3, the backend sources.) `main`: accept the mode `remap`: before `ps4draw::Init`, `setenv("PS4_GNM_GPU_WINDOW_IDLE_S", "1", 1)`; after it, `TestRemapSweepStress()`, then the PASS/FAIL line `gnm_guest_memory_test remap: …` and `_exit` as the hang modes do. `run_host_tests.sh`:

```bash
# Windows dropped by remaps and the idle sweep and re-created under dispatches, on each backend;
# on Metal 4 every bound resource must be resident (the bind-time check) and dropped windows leave.
for m in 3 4; do
  extra=""; [ $m = 4 ] && extra="PS4_GNM_RESIDENCY_CHECK=1"
  env PS4_GNM_METAL=$m $extra gpu "$T/replay/gnm_guest_memory_test" "$R/tests/host/data" remap > "$T/remap_$m.txt" 2>&1 ||
    { cat "$T/remap_$m.txt"; exit 1; }
  grep "^gnm_guest_memory_test remap" "$T/remap_$m.txt"
  if grep -q "gnm-residency\] ASSERT" "$T/remap_$m.txt"; then grep "gnm-residency" "$T/remap_$m.txt"; exit 1; fi
done
```

Run it on the Task 5.1 build with the accessors added → Expected: PASS on both. Teeth (each change temporary, restored before the commit; `git diff $G/ps4_gnm_draw.mm` afterwards shows only the accessors): delete the `S.be->Evict(…)` line of `ReleaseWindow` (Task 3.3) → the count check FAILs on Metal 4; delete the `MakeResident` of `GuestBuffer` → `[gnm-residency] ASSERT bind buffer …` lines and `remap stress: entry 0 dst[0] = …` failures on Metal 4. Record both in the commit message.

- [ ] **Step 2: Run the suite, commit**

Host suite `t52`: `host=0`, the remap mode's line twice.

```bash
git add $G/ps4_gnm_draw.mm $G/ps4_gnm_residency.h $G/ps4_gnm_residency.mm tests/host/gnm_residency_test.mm tests/host/gnm_guest_memory_test.mm tests/host/run_host_tests.sh
git commit -m "tests: window remap and sweep stress on both backends, residency of dropped windows checked on Metal 4

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

### Task 5.3: Phase 5 gate

**Files:** `docs/metal4-baseline.md` (append "Phase 5"), `docs/metal4-backend.md` ("Residency": the `CAMetalLayer.residencySet` note).

**Acceptance (spec table, Phase 5):** "TLOU route and a 30-minute run with `PS4_GNM_RESIDENCY_CHECK=1`: zero asserts. Window sweep/remap stress passes. Memory footprint (`[gnm-mem]`) within 10% of Metal 3." The 30-minute run is six 300 s runs (the run rule caps one run at 300 s), alternating the two saves, three of them with window release made aggressive (`PS4_GNM_GPU_WINDOW_IDLE_S=1 PS4_GNM_GPU_BUDGET_MB=2048`, the policy knobs `StartGpuMemSampler` passes to `ps4_gpumem_policy_init`, `ps4_gnm_draw.mm:1157-1158`) so windows are released and remapped many times.

- [ ] **Step 1: Six runs with the check**

TLOU game build `p5`.

```bash
cd ~/ps4recomp-work/PS4Recomp-metal4 || exit 1
i=0
for save in data_ch1 data_user1441 data_ch1 data_user1441 data_ch1 data_user1441; do
  i=$((i+1)); knobs=()
  [ $i -gt 3 ] && knobs=(PS4_GNM_GPU_WINDOW_IDLE_S=1 PS4_GNM_GPU_BUDGET_MB=2048)
  ~/ps4recomp-work/tools/heavy_lock.sh env BUILD=$M/tlou_build_p5 TAG=p5_check$i METAL=4 SECS=300 \
    DATASRC=$HOME/ps4recomp-work/$save tools/metal4_route.sh PS4_GNM_RESIDENCY_CHECK=1 "${knobs[@]}"
  python3 tools/metal4_route_report.py $M/runs/p5_check$i.log
  grep -c "gnm-residency\] ASSERT" $M/runs/p5_check$i.log
done
```

Expected per run: report `fatal 0 gpu_err 0 watchdog 0`, assert count `0`, `res_assert=0` on the last stats line. Runs 4–6 release windows: `grep "released .* guest window buffers" $M/runs/p5_check$i.log | tail -1` shows the line (it is rate-limited by `RLog`; its `(xN)` suffix gives the count) — none means the knobs did not bite: lower `PS4_GNM_GPU_BUDGET_MB` and rerun. An assert is a missing `MakeResident`/early `Evict`: fix it (with a host test where the path can be reached from one) and rerun all six.

- [ ] **Step 2: Memory footprint vs Metal 3**

Two route runs `BUILD=$M/tlou_build_p5 TAG=p5_mem_m3 METAL=3 SECS=300` and `BUILD=$M/tlou_build_p5 TAG=p5_mem_m4 METAL=4 SECS=300` (default save), each under `heavy_lock`. `python3 tools/metal4_route_report.py` prints the last `[gnm-mem]` total of each: Expected `|m4 − m3| / m3 ≤ 0.10`. Over 10 %: the report's per-class numbers (`[gnm-mem]` lists textures, windows, arena, built-ins) plus the residency sets' `AllocatedSize()` (stats line) show where; residency sets and the bytes arena are the Metal 4-only memory — the bytes arena's chunk count is bounded by the seqs in flight × 256 KiB.

- [ ] **Step 3: Host suite, regression, U4, Go analysis, notes**

Host suite `p5`: `host=0`. `N=3 A=$M/tlou_build_p0:3 B=$M/tlou_build_p5:3 TAG=p5_ab tools/metal4_perf_ab.sh`: within noise. U4 smoke (Metal 4, `PS4_GNM_RESIDENCY_CHECK=1`), recorded with its assert count. `go=0`.

In `docs/metal4-backend.md` "Residency" add: the presenter (`ps4_metal_screen`) stays on Metal 3 (`CAMetalLayer` drawables, the Metal 3 present queue), so `CAMetalLayer.residencySet` does not apply: the drawable is never used by a Metal 4 command buffer; the textures the renderer hands to the presenter are in the renderer's sets (Task 2.4), and the presenter's queue is ordered after the renderer's timeline by the present event (Task 1.8).

- [ ] **Step 4: Record and commit**

```bash
git add docs/metal4-baseline.md docs/metal4-backend.md
git commit -m "Metal 4 work: Phase 5 gate numbers (residency hardening)

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

## Phase 6: Performance and default

### Task 6.1: Full host suite on both backends; nothing left Metal 3-only

**Files:**
- Modify: `tests/host/run_host_tests.sh` (if Step 1 finds a renderer-level test not looped yet)

**Interfaces:** none new.

- [ ] **Step 1: List the tests that run on one backend only**

```bash
cd ~/ps4recomp-work/PS4Recomp-metal4 || exit 1
grep -n 'gpu "\$T' tests/host/run_host_tests.sh | grep -v 'PS4_GNM_METAL=\$m'
```

Each line printed is a test run once. For each: it links `$G/ps4_gnm_draw.mm` or `"${BE[@]}"` (renderer-level) → it must run in a `for m in 3 4` loop (wire it as in Task 4.3); it does not (translator, CPU-only, `TextureCache` alone with its own queue) → leave it and list it in the commit message with the reason.

- [ ] **Step 2: Run the suite under each default**

Host suite `t61` (both backends inside), then once more with `PS4_GNM_METAL` unset in the environment of the whole script and `PS4_GNM_METAL=4` exported for the whole script (`env PS4_GNM_METAL=4 ~/ps4recomp-work/tools/heavy_lock.sh bash tests/host/run_host_tests.sh` — the loops set their own value; the remaining single runs then use Metal 4): Expected `host=0` both times.

- [ ] **Step 3: Commit (if Step 1 changed the script)**

```bash
git add tests/host/run_host_tests.sh
git commit -m "tests: every renderer-level host test runs on both backends

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

### Task 6.2: Performance A/B, Metal 4 vs Metal 3

**Files:** `docs/metal4-baseline.md` (append "Phase 6: performance").

**Interfaces:** `tools/metal4_perf_ab.sh` (Task 0.4) with one build and two backends.

- [ ] **Step 1: The A/B**

TLOU game build `p6`. Machine quiet (the owner's other work stopped; `sysctl -n vm.loadavg` before the start < 8).

```bash
cd ~/ps4recomp-work/PS4Recomp-metal4 || exit 1
N=5 A=$M/tlou_build_p6:3 B=$M/tlou_build_p6:4 TAG=p6_ab tools/metal4_perf_ab.sh
```

The script alternates A, B, A, B … (10 runs, 300 s each, `heavy_lock` exclusive), logs `loadavg` at start and end of each, discards a run whose load exceeded 15 and replaces it (up to 5 replacements per side; more → stop and report the machine as too busy). Expected output: per side the median and range of fps, encoder ms/frame, CP ms/frame and `vm_stat`-derived footprint, and the verdict line `B vs A: fps +x.x (noise ±y.y), encoder ms −…, CP ms …`.

- [ ] **Step 2: Which side is better**

Decision rule (spec, Phase 6): Metal 4 "≥ Metal 3" means its median encoder ms and CP ms are lower or within noise, and its median fps is higher or within noise (noise as defined in Commands). Record the table and the verdict in the baseline file. If Metal 4 is worse beyond noise on a measure, record which, and the `[gnm-draw] perf:` breakdown (commits, waits, ms waiting, ms GPU busy, CP ms, encoder ms per frame, `ps4_gnm_draw.mm:8939`) medians of both sides, which shows whether the loss is in encoding, in waiting, or on the GPU.

- [ ] **Step 3: Commit**

```bash
git add docs/metal4-baseline.md
git commit -m "Metal 4 work: performance A/B against Metal 3

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

### Task 6.3: Default backend

**Files:**
- Modify: `$G/ps4_gnm_backend.mm` (`ChooseBackend`'s `prefer_metal4` at its call in `$G/ps4_gnm_draw.mm` `Init`), `tests/host/gnm_backend_select_test.mm`, `docs/metal4-backend.md` ("Selection")

**Interfaces:**
- Consumes: Task 6.2's verdict.
- Produces: with `PS4_GNM_METAL` unset, Metal 4 on a Metal 4-family device when Metal 4 was ≥ Metal 3; Metal 3 otherwise (then nothing changes in code, and the reason is recorded).

- [ ] **Step 1 (Metal 4 ≥ Metal 3): the failing test**

In `gnm_backend_select_test.mm` add:

```objc
    // The default (no PS4_GNM_METAL) after Phase 6: Metal 4 where the device has it.
    CHECK(DefaultPrefersMetal4(), "the renderer's default does not prefer Metal 4");
    CHECK(ChooseBackend(nullptr, true, kGnmCapAll, false, DefaultPrefersMetal4()).kind == GnmBackendKind::Metal4, "default, Metal 4 device");
    CHECK(ChooseBackend(nullptr, false, kGnmCapAll, false, DefaultPrefersMetal4()).kind == GnmBackendKind::Metal3, "default, Metal 3 device");
```

with `bool DefaultPrefersMetal4();` declared in `ps4_gnm_backend.h` next to `ChooseBackend`. Run → compile error.

- [ ] **Step 2 (Metal 4 ≥ Metal 3): implement**

`ps4_gnm_backend.mm`:

```cpp
// The backend used when PS4_GNM_METAL is not set. Metal 4 since its Phase 6 A/B
// (docs/metal4-baseline.md, "Phase 6: performance"): not slower than Metal 3 beyond noise.
bool DefaultPrefersMetal4() { return true; }
```

`Init` passes `DefaultPrefersMetal4()` instead of `false`. `docs/metal4-backend.md` "Selection": the default and the A/B it rests on; `PS4_GNM_METAL=3` keeps Metal 3.

- [ ] **Step 1–2 (Metal 4 worse): no code change**

`DefaultPrefersMetal4()` is added returning `false`, with its comment naming the measure that was worse and the baseline section; the test checks `!DefaultPrefersMetal4()` and the Metal 3 result for both devices. `docs/metal4-backend.md` "Selection" says why Metal 3 stays the default and what would have to change (the passes from Task 6.2 Step 2).

- [ ] **Step 3: Run, host suite, short route, commit**

Select test PASS. Host suite `t63`: `host=0`. Route `BUILD=$M/tlou_build_t63 TAG=p6_default SECS=300` with `METAL` not set (TLOU game build `t63` first): the backend line in the log names the expected backend; report `fatal 0 gpu_err 0 watchdog 0`.

```bash
git add $G/ps4_gnm_backend.h $G/ps4_gnm_backend.mm $G/ps4_gnm_draw.mm tests/host/gnm_backend_select_test.mm docs/metal4-backend.md
git commit -m "gnm: default backend after the Metal 4 A/B

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

### Task 6.4: Phase 6 gate (final)

**Files:** `docs/metal4-baseline.md` (append "Phase 6: gate").

**Acceptance (spec table, Phase 6):** "Perf A/B (≥5 alternating runs per backend, load > 15 discarded): Metal 4 ≥ Metal 3 on encoder ms and fps, or the reason it is not is recorded. Default switches to Metal 4 only then. Full host suite green on both backends."

- [ ] **Step 1: Checks**

```bash
cd ~/ps4recomp-work/PS4Recomp-metal4 || exit 1
grep -n "NotYet\|not implemented yet" $G/ps4_gnm_backend_metal4.mm      # nothing
grep -n "M3Legacy\|Legacy" $G/*.mm $G/*.h                                # nothing
git log --oneline main..metal4-backend | wc -l                            # the work's commits
```

Host suite `final` (`host=0`), Go analysis (`go=0`), U4 smoke on the default backend (recorded), the Phase 0 replay comparison once more on the final build for both frames and both backends (`different: 0` against `p4_m3_*`, or only the listed known differences).

- [ ] **Step 2: Record and commit**

The baseline file's "Phase 6: gate" lists: the A/B table and verdict, the default, the suite result, the known differences list (from `docs/metal4-backend.md`), the commits. Commit:

```bash
git add docs/metal4-baseline.md
git commit -m "Metal 4 work: Phase 6 gate (performance, default, final checks)

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

The branch stays local (no push); merging into `main` is the owner's decision after reading the gate records.

---

## Spec coverage

| Spec section / requirement | Tasks |
|---|---|
| Goal: Metal 4 renderer backend, same output as Metal 3 | 1.1–1.9 (seam), 2.2–2.3, 3.1–3.3, 4.1–4.2; parity gates 3.4, 4.5 |
| `GnmBackend` interface, one renderer, two backends | 1.1 (declarations), 1.2–1.9 (moves), 1.9 (no Legacy left) |
| Selection (`PS4_GNM_METAL`, capabilities, FATAL when unavailable) | 1.1, 1.2, 2.5, 6.3 |
| Command buffers, allocators reused after their seq | 2.2 (`TestAllocators`, `TestWaitForRoom`) |
| Timeline event, seq completion, fences, watchdog on the timeline | 1.2, 1.7, 2.2 (`TestEventOrder`) |
| Queue-level signal/wait, command-buffer split for events | 1.7, 2.3 (`TestSplit`) |
| Argument tables, no setBytes (bytes arena) | 2.2, 2.3, 3.1 |
| Barriers: start of encoder after queue stages; inside encoders; coverage test | 2.3, 3.1, 4.1 (`gnm_backend_barrier_test` with teeth) |
| Copies on compute encoders | 3.2 (`gnm_backend_copy_test`) |
| Residency sets: classes, add at creation, evict after seq | 2.1, 2.4, 3.3, 4.2 |
| Residency negative control | 3.1 (`TestGpuWrites`) |
| Present path (presenter on Metal 3, event hand-off) | 1.8, 2.3 (`gnm_backend_present_test`), 5.3 note |
| Helper passes through the backend | 1.9 |
| Debug modes (`ONLY_CLEARS`, `FULL_BARRIERS`, `NO_BARRIERS`, `SERIAL_COMPUTE`, `RESIDENCY_CHECK`) | 2.5, 3.1, 4.1, 5.1 |
| Replay byte-identity after each Phase 1 step | 0.1–0.2 (tools), R-check in 1.2–1.9, gate 1.10 |
| Allocation counts on the hot path | 0.3, 1.10, 2.6 |
| Phase gates (spec acceptance table) | 0.5, 1.10, 2.6, 3.4, 4.5, 5.3, 6.4 |
| Host suite on both backends | 2.5, 3.3, 4.3, 5.2, 6.1 |
| Perf A/B and default switch | 0.4 (script), 6.2, 6.3 |
| Documentation (`docs/metal4-backend.md`, `docs/metal4-baseline.md`) | 0.4, 1.1, every gate, 5.3, 6.3 |
