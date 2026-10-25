# Metal 4 renderer backend, selectable at launch (TLOU first)

Date: 2026-10-22. Status: design approved by the owner, section by section. The written spec is pending the
owner's review.

## Goal

One `.app` contains two renderer backends, Metal 3 and Metal 4, and the backend is chosen at launch.
The Last of Us Remastered (CUSA00557) runs on the Metal 4 backend **at parity with Metal 3**:

- the same picture;
- no crashes and no GPU hangs;
- an fps no lower than on Metal 3.

A speed-up is measured and recorded, but it is not an acceptance condition. Both backends are maintained on
equal terms after the switch.

## Decisions (owner, 2026-10-22)

1. **Launch-time selection.** Both backends are built into every `.app`. `PS4_GNM_METAL=3|4` selects one.
2. **Success means parity**, as stated in the goal.
3. **Both backends are maintained equally.** The shared code is common and backend-agnostic, renderer fixes
   land once, and tests run on both backends. Metal 3 stays the fallback for older macOS and the reference
   for comparisons.
4. **Metal 4 has priority** over the queued Uncharted 4 graphics tasks. Those resume after this spec's Phase 6.
5. **Approach A:** an explicit backend interface on the Vulkan/Metal 4 model. Shared code decides barriers,
   residency and binding; each backend executes them.

## Background

Research for this spec was kept in the local SDD workspace (git-ignored, not in the repository). It covers:

- our Metal 3 usage map;
- the design of shadPS4's Vulkan renderer;
- the Vulkan → Metal 4 → our Metal 3 mapping;
- the probes.

Facts it established on the target machine, an Apple M1 Pro with macOS 27 and SDK 27.0:

- **Metal 4 support.** The GPU supports `MTLGPUFamilyMetal4`. The MTL4 APIs need macOS 26 or later
  (`MTL4CommandQueue.h:211`).
- **Shaders.** `MTL4Compiler` accepts our MSL 2.3 source unchanged. No header requires a newer language
  version for Metal 4 pipelines.
- **Pipelines.** Metal 3 pipeline states work on MTL4 render encoders (with a depth format) and on MTL4 compute
  encoders.
- **Events.** Shared events work between a Metal 3 queue and a Metal 4 queue.
- **Residency.** A no-copy buffer that is missing from every residency set has its GPU writes **silently
  dropped**. No error is reported.

shadPS4, a PS4 emulator with a Vulkan renderer, is a design reference only. Its code is not taken, because
PS4Recomp stays an AOT recompiler with no interpreter and no JIT (AGENTS.md). Two of its ideas are adopted:

- timeline "ticks", which map onto our commit `seq`;
- explicit barriers, which are a later spec.

## Architecture

### The seam

The seam sits at the encoder thread. A new `pkg/runtime/modules/libSceGnmDriver/ps4_gnm_backend.h` declares
`GnmBackend`. The bodies of `DrawEncode` and `DispatchEncode` stay shared and call it.

**Shared** (one copy, used by both backends):

- the GNM command processor and register decoding;
- V#/T#/S# decoding and `BindStage`;
- the texture cache, the buffer cache and the guest-memory windows;
- hazard logic and the guest-memory dispatch protocol (Tasks 2.7 and 3.1);
- shader translation and the shader cache;
- pipeline states, the binary archive and the pipeline archive;
- capture and replay.

**Implemented by each backend:**

- command-buffer lifecycle and the `seq` timeline: `BeginCmd`, `Commit`, `CompletedSeq`, `WaitSeq` and a
  completion callback;
- queue-level event signal and wait;
- render and compute passes, and barriers;
- pipeline and fixed-function state;
- binding: buffers, small byte blocks, textures and samplers;
- draws (direct, indexed, indirect and rect list) and dispatches (direct and indirect);
- buffer and texture copies and fills;
- residency: `MakeResident`, and `Evict` deferred to a `seq`;
- the present producer.

**The Metal 3 backend** is a move of today's code. Its behaviour does not change: barriers cover compute only,
as today, and residency calls do nothing.

**Amendment 2026-10-24.** The coordinator ruled this under the owner's delegation. The rule above
no longer holds in full. Three changes on the branch alter what Metal 3 does, each measured and
recorded in docs/metal4-backend.md, "Metal 3 changes beyond the move":
1. Batched compute commits, on both backends. A compute submission's commit is held for up to
   0.5 ms while 2 or more seqs are in flight.
   - TLOU on Metal 3: about 82 → 92 fps; the mean interrupt latency went from 6.7 to 5.3 ms.
   - `PS4_GNM_COMPUTE_BATCH=0` restores the earlier commit at the end of every submission.
   - Details are in docs/compute-batching.md.
2. Per-encoder access fences that order aliasing guest windows (docs/gnm-ordering.md).
3. The texture cache's alias copy is encoded into the renderer's upload command buffer.

**The Metal 4 backend** adds these pieces:

- the queue and a command-allocator ring; an allocator is reset only after its `seq` completes;
- a timeline `MTLSharedEvent` and commit feedback, which replace completion handlers and `status`;
- a barrier at the start of each encoder;
- one argument table per stage;
- a bytes arena that replaces `setBytes`;
- copies and fills encoded on the compute encoder;
- the residency manager.

**Helper passes** are rewritten once on top of `BeginRender` and `Draw`, so that both backends share them.
They are depth sync, EQAA, depth companions, stencil copies and present conversion. This removes about 600
duplicated lines.

**Performance.** The backend is selected once, and calls go through a function table or a template rather than
a virtual call per bind. Binder dedupe stays in the shared code.

**Selection.** `ps4draw::Init` reads `PS4_GNM_METAL` once.

- The default is 4 when `supportsFamily:MTLGPUFamilyMetal4` holds. Otherwise it is 3.
- The chosen backend is logged at startup.
- An explicit request for 4 on hardware without Metal 4 is a startup error that says why. It never falls back
  silently.

The default switches to 4 only in Phase 6, and only if that phase's acceptance holds. Until then the default
is 3.

**Staying on Metal 3 in this spec:** the presenter (`ps4_metal_screen.m`) and the guest-memory re-run queue
(`queue2`). Events order work across the two queues, as they do today.

### Synchronisation

**Barriers (first version).** A conservative barrier at each MTL4 encoder start. It reproduces what Metal 3
orders between encoders today: render, compute, copy and CPU upload. Copies and dispatches inside one compute
encoder are also separated by barriers. `PS4_GNM_MTL4_FULL_BARRIERS=1` is a debug mode that puts a barrier
after every command, for ordering A/B checks. Precise barrier tracking is out of scope.

**Events inside a command buffer.** Metal 4 has no event operations in the middle of a command buffer. Every
mid-buffer signal or wait in the guest-memory chain protocol, and in the committed-ticket wait, becomes this
sequence:

1. end the command buffer;
2. commit it;
3. perform the queue-level event operation;
4. start a new command buffer.

The number of extra commits per frame is reported in the renderer stats.

**Watchdog.** A hang appears as a timeline value that stops advancing, since Metal 4 has no `cb.status`. The GPU
watchdog therefore keys on `CompletedSeq()`. A test checks it by waiting on a never-signalled event.

### Residency

Residency is the main risk, because a missing entry gives wrong results with no fault. `GnmResidency` is
backend-owned and holds 2–3 residency sets:

- guest-memory windows and the arena;
- textures;
- built-in buffers.

Its rules:

- An allocation is added when it is created: windows, spanning buffers, textures, arena chunks, the page table
  and built-ins.
- The sets are committed before each queue commit.
- An allocation is removed only after the last `seq` that used it completes. That is the same deferral as
  `GpuMem::Pending`.
- The window sweep, remaps, over-budget purges and texture-cache retire and evict all go through it.
- `PS4_GNM_RESIDENCY_CHECK=1` is a debug mode that asserts `containsAllocation:` on every bind.

### Pipelines and caches

Through Phase 6 both backends use Metal 3 pipeline states and the existing binary and pipeline archives, so
switching backends never causes a cold start. The GCN→MSL cache key and the MSL are backend-independent and
shared.

If the translator options ever diverge between backends, `msl_version` joins the shader-cache key and the
library-store tag. It is never left as an implicit default.

`MTL4Compiler` and `MTL4Archive` are out of scope.

### Capture, replay and tests

- **Replay.** `gnm_replay` follows `PS4_GNM_METAL`. Replay of the TLOU capture set is the main parity
  instrument: per pass, `diff_bytes == 0` between the backends.
- **Capture readbacks** keep their Metal 3 queue after `Flush(true)`, where the objects are shared. Textures
  adopted by replay are made resident.
- **Host suite.** `run_host_tests.sh` runs the renderer-level tests twice, with `PS4_GNM_METAL=3` and `=4`.
  On Metal 4-family hardware a test never passes by skipping: a missing feature fails it.
- **New Metal 4 tests:**
  - residency, positive, and a negative control that must fail without the set;
  - the command-buffer split for events;
  - allocator reuse only after completion;
  - barrier coverage: a render pass sampling a compute-written texture matches Metal 3.
- **Wave64 barrier safety** (`tests/host/msl_barrier_check.h`, `gcn_wave_exec_test`) is checked under both
  backends. The MSL and the pipelines are the same.
- **Debug tooling.** `PS4_GNM_ENCODER_STATUS` is documented as Metal 3-only. On Metal 4, `PS4_GNM_COMMIT_EACH`
  is used to bisect.

## Phases and acceptance

Each phase is a separate task with its own review. Runs follow the project rules:

- time-bounded, at 300 s or less;
- scratch `PS4RECOMP_DATA_DIR` and cache dirs;
- through `heavy_lock`, exclusive for perf runs.

| Phase | Content | Acceptance |
| --- | --- | --- |
| 0. Baseline | Metal 3 numbers: the fixed TLOU route, fps, encoder and CP ms per frame, commits per frame, skipped draws, the replay pass set. | A baseline numbers file; the host suite is green. |
| 1. Seam, Metal 3 behind it | `GnmBackend` and `Metal3Backend` as a move of existing code; helper passes on `BeginRender`/`Draw`; `PS4_GNM_METAL=4` is a clear "not implemented" error. | Replay outputs byte-identical to Phase 0. Host suite green. TLOU route fps within noise (alternating builds, load ≤ 15). Allocations per draw not increased. Go analysis tools clean. |
| 2. Metal 4 queue, command buffers, clears, present | Queue, allocator ring, timeline event and feedback, clear-only render passes, the present producer, residency for targets and slots. | A clear presented and read back equals Metal 3. TLOU boots to frames on Metal 4 with draws disabled (debug `PS4_GNM_MTL4_ONLY_CLEARS=1`): flips complete, no watchdog, `allocatedSize` does not grow over 10,000 frames. |
| 3. Compute | Compute encoder, argument tables, arena, indirect dispatch through `gpuAddress`, copies and fills, barriers, residency for windows, arena and page table. | Every compute pass of the TLOU capture set is byte-identical to Metal 3 in `gnm_replay`. `gcn_wave_exec_test` and `gnm_guest_memory_test` pass on Metal 4. The residency negative control fails without the set. |
| 4. Graphics | Render pipelines and fixed state, vertex buffers through the table, direct, indexed and indirect draws with explicit index lengths, rect lists, helper passes, sample positions, EQAA. | All TLOU replay passes byte-identical to Metal 3; any difference is explained and listed. TLOU route screenshots at three checkpoints match Metal 3: exact, or below a per-pixel threshold on effects shown to be non-deterministic, each listed. No new skipped draws. |
| 5. Residency hardening | The full residency manager: texture-cache hooks, window sweep and remap, deferred removal, the layer's residency set, the bind-time check. | A 30-minute TLOU run with `PS4_GNM_RESIDENCY_CHECK=1` has 0 asserts. `[gnm-mem]` budget behaviour equals Metal 3 within ±10 %. `guest_window_test` and a new remap stress test pass on Metal 4. |
| 6. Default switch | Default 4 when Metal 4 is supported; both backends ship in one `.app`. | The full host suite passes on both backends. The TLOU route on both has no crash, no watchdog and paced flips. **Metal 4 fps ≥ Metal 3 fps**: medians of at least 5 alternating runs per backend, runs at load > 15 discarded. If Metal 4 is slower, the default stays 3 and the reason is recorded. |

From Phase 2 to Phase 6, a short Uncharted 4 smoke run on Metal 4, up to the title screen, is recorded to spot
regressions. It is not an acceptance condition.

## Global constraints

- AGENTS.md:
  - no cheating and no fake tests: each new test fails on the code before its change;
  - no stubs that return 0 and no temporary workarounds;
  - no interpreter and no JIT;
  - comments and docs in English;
  - Go analysis tools clean, with minimal allocations.
- TLOU does not regress on Metal 3 at any phase.
- gcn-recompiler is edited only through its in-repo copy.
- Local commits only. Pushing happens only on the owner's word.

## Out of scope

Each of these gets its own spec later:

- precise barrier tracking and argument-table tuning, where the speed-up is expected (shadPS4's
  `AccessBuffer`/`FlushBarriers` model);
- `MTL4Compiler` and `MTL4Archive`;
- moving `queue2` and the presenter to Metal 4;
- Uncharted 4 on Metal 4.
