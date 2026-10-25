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

The on-screen performance overlay (`MTL_HUD_ENABLED`, on by default) ends its first line with the
backend that started, `Metal 3` or `Metal 4` (`ps4_metal_screen_set_backend_label`, set by `Init`).

An explicit `4` needs every capability (`kGnmCapAll`), or render passes (`kGnmCapClears`) with
`PS4_GNM_MTL4_ONLY_CLEARS=1`. `PS4_GNM_MTL4_ONLY_CLEARS` set on a Metal 3 choice has no effect,
and the logged reason ends with `PS4_GNM_MTL4_ONLY_CLEARS ignored on Metal 3`.

The Metal 4 backend has every capability since Task 4.3 (`kMetal4BackendCaps = kGnmCapAll`,
ps4_gnm_backend_metal4.mm), so `PS4_GNM_METAL=4` alone runs it with draws. A build whose Metal 4
backend lacked a capability would stop at startup with "this build's Metal 4 backend lacks <caps>;
set PS4_GNM_MTL4_ONLY_CLEARS=1 to run it with draws skipped (debug)". Any value other than 3 or 4
is a startup error too.

**The default is Metal 3** (`DefaultPrefersMetal4()` returns false, ps4_gnm_backend.mm), also on
a GPU with `MTLGPUFamilyMetal4`. `PS4_GNM_METAL=4` runs Metal 4.

The Phase 6 A/B (docs/metal4-baseline.md, "Phase 6: performance, Metal 4 against Metal 3") decided
this. It ran TLOU, one build on both backends, 5 + 5 runs of 300 s:
- Metal 4 was slower beyond noise: 85.5 against 98.9 fps (−13.4, noise ±1.3).
- Its encoder and CP time were equal or lower (7.8 against 8.1 ms, 7.0 against 7.1 ms).
- The loss is GPU time: 11.4 against 9.3 ms of GPU busy per frame.

The rule is that the default changes only when Metal 4 at least equals Metal 3.

What would have to change is the serialisation by the encoder-start barriers (docs/gnm-ordering.md,
"Metal 4: barriers at encoder starts"):
- Every Metal 4 encoder waits for all earlier work, so its seqs never overlap on the GPU. Metal 3's
  hazard tracking lets a command buffer run alongside the next one.
- A replacement hazard design must cost less encoder time than it saves GPU time. The per-encoder
  fence model that was measured saved about 1 ms of GPU time per TLOU frame but cost 2–3 ms of
  encoder CPU.
- Once a design gets Metal 4's GPU busy time to Metal 3's without raising the encoder time, rerun
  the A/B. If Metal 4 then at least equals Metal 3, `DefaultPrefersMetal4()` returns true and
  gnm_backend_select_test checks the Metal 4 default.

A capability is advertised only once the renderer keeps everything that kind of work touches
resident (Metal 4 has no implicit residency: a write to a buffer outside every residency set is
lost without an error). Clears: render targets, the presenter's textures and the renderer's
built-in buffers (Task 2.4). Compute and copies: also the guest memory windows, the upload arena,
the page table and the guest memory dispatch buffers (Task 3.3). Draws: also the renderer's own
textures (Tasks 4.2, 4.3).

### PS4_GNM_MTL4_ONLY_CLEARS=1 (debug)

The renderer runs on the Metal 4 backend with its draws skipped (and, in a build whose Metal 4
backend lacks compute or copies, that work skipped or done on the CPU):

- A draw's render pass begins, so its clears and loads happen; the draw itself is skipped, and so
  is the preparation of the textures it samples (texture hazards, depth companions). The shared
  bookkeeping that preparation also does (guest memory invalidations, refreshes of surfaces
  written by buffer stores) happens at the next site that calls it, such as the render-target
  refresh before the pass. Counted in the `backend` log line, not as a skipped draw.
- Without compute: dispatches are skipped (counted as skipped; a replay reports "the renderer
  skipped the pass").
- Without copies, or without compute: GPU DMA is done by the CP on the CPU; texture uploads from
  guest memory are done on the CPU at bind time (the hazard path, which would drain the GPU, is
  not reached in this mode: draws skip their texture preparation and dispatches are skipped); a
  guest display buffer is presented by the CPU path; mip chains of render targets, the
  resolve by copy and the copy of a grown depth array's slices are skipped. Each skip is logged
  (`[gnm-draw] <what>: the metal4 backend lacks it (PS4_GNM_MTL4_ONLY_CLEARS); not done on the
  GPU`, rate limited with a count).
- The present's copy into the presenter's slot runs on every backend: both textures are resident.

Nothing in this mode aborts on a missing capability.

Builds set no deployment target, so their minimum macOS is the build host's. The few existing
`@available` checks guard pre-Metal 4 APIs, and none guards MTL4. A GPU without
`MTLGPUFamilyMetal4` is the only case where Metal 3 is chosen by necessity.

## Measurements

- The TLOU fixed route is `tools/metal4_route.sh` (time-bounded, scratch data and cache
  directories, a WindowServer / load / GPU-error monitor). `tools/metal4_perf_ab.sh` runs
  alternating A/B pairs and keeps a pair only if both runs ended with a 1-minute load of at most
  15, neither saw other processes above 350 % CPU in more than two monitor samples, and the
  medians of their monitors' other_cpu differ by at most 40 (idle is 45-55; while other agents
  work it is 90-240, which costs TLOU about 3 fps and 0.5 ms of encoder, so both runs of a pair
  must share it for the alternation to cancel it). The numbers of every phase gate are in
  docs/metal4-baseline.md.
- A/B runs take no screenshots (`EVERY=0`, which also ignores `EVERY_SEC`). Their absolute fps is
  therefore not comparable with runs that took screenshots (every 600 flips by default, as the
  routes of Phases 0-4 did); within one A/B both sides are alike.
- Replay parity: `gnm_replay <frame> all --sha` writes one SHA-256 per output, and
  `tools/metal4_replay_cmp.py` compares two such lists.
- The allocation count of `gnm_replay --allocs` (tools/gnm_replay/alloc_count) is process-wide
  inside the armed window, which runs from the renderer's Draw/Dispatch to its Flush(true). Worker
  threads and completion handlers count too, and the minimum of N replays absorbs unrelated
  threads. Allocations after Flush(true) are not counted.

## Debug variables

| variable | backend | effect |
|---|---|---|
| `PS4_GNM_ENCODER_STATUS=1` | Metal 3 only | per-encoder fault attribution of failed command buffers |
| `PS4_GNM_COMMIT_EACH=1` | both | one command buffer per draw or dispatch (bisecting a fault or hang; the Metal 4 tool for what ENCODER_STATUS does on Metal 3) |
| `PS4_GNM_MTL4_ONLY_CLEARS=1` | Metal 4 | draws are skipped after their render pass begins, so clears happen; dispatches, GPU DMA and GPU texture uploads are skipped or done on the CPU while the backend lacks compute and copies (see Selection); counted in the `backend` log line, not as skipped draws |
| `PS4_GNM_MTL4_FULL_BARRIERS=1` | Metal 4 | a barrier after every draw, dispatch and copy, for ordering A/B checks |
| `PS4_GNM_MTL4_NO_BARRIERS=1` | Metal 4, tests only | no encoder-start barriers; shows that a test depends on them |
| `PS4_GNM_RESIDENCY_CHECK=1` | Metal 4 | every buffer and texture bound, used through an argument buffer, drawn from (index, indirect), dispatched from (indirect), copied or attached is looked up in the residency sets, for the whole of the seq being recorded (a resource evicted after an earlier seq that has not completed counts as not resident: it leaves its set when that seq completes, maybe while this one runs); one `[gnm-residency] ASSERT <what> <resource> not resident` line per resource, every occurrence counted (`res_assert=` in the `backend` log line). Costs encoder time (TLOU with draws: 17.4 against 14.4 ms per frame, 57 against 70 fps). Off: no lookup. A non-resident resource is not reliably visible otherwise (writes lost, reads wrong or a command buffer timeout only when cold, no validation-layer message) |

`PS4_GNM_ENCODER_STATUS=1` with the Metal 4 backend is ignored with a warning (Metal 4 command
buffers have no per-encoder status).

## Log lines

Every 300 presents, after the `per frame` line:

```
[gnm-draw] backend <metal3|metal4>: split commits per frame <x>; allocators <n> (<KiB> KiB; created <c>, released <r> in 300 frames); resident <n> (<MiB> MiB, <t> textures); draws skipped by PS4_GNM_MTL4_ONLY_CLEARS <n>; res_assert=<n>
```

- split commits per frame: queue commits made inside one seq for a queue-level event (Metal 4
  signals and waits exist only between command buffers), averaged over the 300 presents.
- allocators: command allocators alive (created minus released), the sum of their `allocatedSize`
  now, and how many were created and released in the last 300 frames (the trim, below).
- resident: allocations in the residency sets, the sum of the sets' `allocatedSize`, and how many
  of them are in the Texture set (the texture cache's textures, the presenter's slot and held
  textures, the renderer's present textures): it stays bounded across resolution changes when
  replaced textures leave the set.
- draws skipped by PS4_GNM_MTL4_ONLY_CLEARS: since startup.

Metal 3 has no allocators, splits or residency sets: it prints zeros there.

The `perf` line ends with the split of `ms encoder` (the encoder thread's wall time running jobs):
`encoder <x> ms CPU` is that thread's CPU time over the same jobs, and `blocked <a> ms throttle,
<b> ms in-flight limit, <c> ms opening command buffers` the wall time of EnsureCmd's blocking calls
on it (ThrottleCommandBuffers; the backend's WaitForRoom; BeginCmd, where Metal 3's queue blocks at
its command buffer limit). The rest of the wall time is time off the CPU elsewhere: WaitAll (also
a blocking call on the encoder thread, counted in the line's `ms waiting`, not split out here),
locks, kernel compile waits, preemption. TLOU at 1c988e7, 150 s (runs `eb_m4` and `eb_m3`, their
last six perf lines: the route's last scene, after the earlier scenes' 14-15 ms): Metal 4
13.4-13.5 ms encoder, 12.8-12.9 ms CPU, 0.3 ms opening command buffers, nothing else blocked;
Metal 3 11.5-11.6 ms, 11.0-11.1 ms CPU, 0.3 ms opening.

These lines, the `perf` and `per frame` lines before them and the `present #<n> from <source>;
totals: …` line every 300th present are printed for every present: from a GPU target, and from
guest memory read by the CPU (the only path while PS4_GNM_MTL4_ONLY_CLEARS skips what writes the
display buffer).

The GPU watchdog (no progress within `PS4_GNM_GPU_TIMEOUT`, WaitAll or the backend's limit on
command buffers in flight) prints `[gnm-draw] GPU watchdog: <what> did not complete in <ms> ms;
disabling GPU rendering (fences keep being signaled)`, the guest memory ticket state and, for a
stuck command buffer, its work log.

## Command allocators (Metal 4)

Each command buffer part has its own `MTL4CommandAllocator`, reused once its seq has completed.
A reset keeps an allocator's memory: `allocatedSize` stays at the largest part it ever recorded
(measured before the trim: 6.9-8.5 MiB each, 330-440 MiB in all at about 49 parts in flight; every
command buffer has a fixed base of about 0.6 MiB, about 2.4 MiB more with its first render
encoder, and free allocators were reused by parts of any shape, so each grew to the largest part
it met). TLOU's parts are bimodal (a probe of 10000 gameplay parts on fresh
allocators: 87 % compute-only at about 0.6 MiB, 13 % with a render pass at 2-5.6 MiB, in runs of
about 6 per frame). The trim (Task 5.4, `Metal4Backend::Recycle` and `AcquirePart`):

- A Main part predicts a render pass when the previous frame (`GnmBackend::NoteFrameEnd`, called
  by the renderer's present) had one within 2 positions of it, or when the target's last part had
  one (on Upload only the latter). Predicted render: a large free allocator, else the smallest
  small one; predicted compute: the smallest small one. A compute part never takes a large one
  (it gets a new allocator instead), so it never keeps a large one large. The window absorbs the
  shift of a frame's render runs by a part or two, which an exact position missed about once a
  frame (a creation and a release per frame).
- After its reset an allocator over the threshold, max(1.5 MiB, 2 x the median size of the last
  256 compute-only parts that ran on a fresh allocator), goes to a large free list of at most 12;
  with the list full, the largest of the list and this one is released with its command buffer
  object (a pathological part's allocator does not stay while smaller ones go). One under the
  threshold goes to the small list.
- Free allocators beyond the most parts in flight over the last 8192 submits (this window and the
  previous one) plus 4 are released, the largest first.
- Only reset parts of completed seqs are released; the `backend` line counts the allocators alive
  and those created and released in the last 300 frames. TLOU on Metal 4 with draws, two 300 s
  routes: 53 allocators, 113-116 MiB. After the warm-up at the start of gameplay (about 40
  creations), single creations and releases until about 105-134 s (t54d2: 1/0, 1/0, 0/1; t54d3:
  1/0, 2/1), then none for the last 2.7 minutes of each run.

## Residency

The renderer's residency sets (`GnmResidency`: Guest, Builtin and Texture classes) are added to its
`MTL4CommandQueue` once, at backend creation, so every command buffer the renderer commits sees
them.

The presenter (`ps4_metal_screen.m`) stays on Metal 3. Its `CAMetalLayer` drawables are rendered by
command buffers of its own Metal 3 queues, so `CAMetalLayer.residencySet` does not apply: no Metal 4
command buffer ever uses a drawable.
- The textures the renderer hands to the presenter (its slot, held frames and present textures) are
  in the renderer's Texture set (Task 2.4), so the renderer's writes to them are resident.
- The presenter's queue is ordered after the renderer's timeline by the present event (Task 1.8):
  its command buffer waits for the event value the renderer signals once the frame is written
  (`encodeWaitForEvent`).

## Guest memory on Metal 4

Every buffer the guest memory paths hand to the GPU is in a residency set from its creation until
it is let go plus the seq that may still use it (Task 3.3):

- Guest class: the 64 MiB no-copy windows and the buffers spanning several windows (GuestBuffer;
  evicted by ReleaseWindow after the open seq, which covers the idle and remap sweeps), and the
  upload arena's chunks (`UploadArena::on_new`; a chunk dropped by the purge leaves after the open
  seq, a chunk CommitDoneFn does not recycle after the seq that used it).
- Builtin class: the guest page table (a replaced table leaves after the open seq, as passes
  encoded so far read it), the guest memory dispatch slots (pooled for the process lifetime), the
  detile maps and staging buffers (evicted when their caches are cleared or purged), and the DMA
  fill pattern buffers (after the open seq).

- Texture class, besides the texture cache's and the presenter's textures (Task 2.4): the
  renderer's own textures that compute work reaches too (a dispatch that samples a depth target
  binds its depth companion, PrepareDepthCompanions): depth companions, mip chains of render
  targets, depth textures made from memory and EQAA stand-ins, from creation until replaced or
  forgotten (ForgetTexture), plus the open seq.

The texture cache's alias copy (a GPU target sampled with other dimensions) is encoded by the
renderer in its upload command buffer (`TextureCache::GpuCopyHook`, Task 4.2), after every
committed seq and before the open one, as the cache's own command buffer on Metal 3's queue ran.
On Metal 4 the cache's queue is not the renderer's, so a copy there would not be ordered with the
renderer's work (gnm_backend_copy_test TestAliasCopyOrder: a copy on a queue of its own reads the
target before an earlier seq's clear on Metal 4). As before, a target rendered in the open seq and
sampled in the same seq with other dimensions gets a copy that misses that seq's writes (on Metal 4,
after a mid-seq split, it sees the part before the split). Views (aliases, adapted textures) are covered by their parent's residency
(gnm_residency_test TestViews).

With that, the Metal 4 backend advertises compute and copies (`kMetal4BackendCaps`).

A texture outside every residency set is not always visibly wrong on Metal 4: the TLOU courtyard
replay's pass 518 (a dispatch sampling a depth target through its companion) matched Metal 3 in
warm runs, but the first run after a few idle minutes (or a game run) failed its command buffer
with MTL4CommandQueueErrorTimeout (4 ms of GPU time), until the companion was made resident.

A window and a spanning buffer over the same pages give that memory two GPU virtual addresses. The
renderer's barriers on Metal 4 (encoder starts, its own barriers, the barriers between copies and
dispatches of one encoder) use `MTL4VisibilityOptionDevice | MTL4VisibilityOptionResourceAlias`:
the header defines ResourceAlias as the option that makes aliased virtual addresses consistent.
gnm_residency_test's TestAliasedViews (write through one view, read through the other in the next
encoder, both ways, 32 rounds) passes on the M1 Pro with Device alone and even with execution-only
barriers (without any barrier it reads stale data in 29 to 31 of 32 rounds), so on this GPU the
alias flush is not observable: Device-only cannot be justified by a test, and the header's option
is used.

## Metal 4 ordering differences

Where the Metal 4 backend orders or reads differently from Metal 3. None changes a result the
renderer depends on; each can make a replay output differ from Metal 3 (the replay gate lists such
passes as expected differences, next to the passes that differ between two Metal 3 replays).

- **A queue-level wait holds the whole queue.** Metal 3 encodes a wait into the main command
  buffer; the upload command buffer, committed before it, does not wait. Metal 4 has waits only
  between command buffers, on the queue: uploads recorded before the wait are committed first
  (UploadFirst), but uploads recorded after it wait too. The guest memory protocol's 2t wait is
  signalled by the CPU for work already committed, so this costs stalls, never a deadlock.
- **Uploads recorded after a mid-seq split run after the pre-split main work.** A signal or
  wait inside a seq splits it into parts (Upload, then Main, per part). An upload recorded after
  the split goes into the next part, so it runs after the main work before the split; on Metal 3
  the seq's single upload command buffer runs before all of its main work. Metal 4's order is
  program order, and the renderer's invalidation (`cmd_start_epoch`) is conservative in that
  direction; a capture with guest memory chains (Uncharted 4) can still differ in replay.
- **Indices past index_length.** Metal 4 indexed draws take the readable length of the index
  buffer (`indexBufferLength`): a read past it gives index 0 (vertex_id 0), while Metal 3 reads on
  into the buffer. An indexed-indirect draw whose GPU-written indices run past max_index can differ.
- **Indexed-indirect index length unobservable (M1 Pro, macOS 27).** The indexed-indirect draw
  ignores `indexBufferLength` there (even 0 draws the last indices, also under the validation
  layer); the direct indexed draw honours it. The renderer passes the same length to both forms,
  so a wrong length of an indexed-indirect draw cannot be detected on this GPU.

## Metal 3 changes beyond the move

The Metal 3 backend began as a move of the renderer's earlier Metal code. Three changes on this
branch alter what Metal 3 does. The spec's amendment of 2026-10-24 records them.

- **Batched compute commits** (docs/compute-batching.md).
  - While 2 or more seqs are in flight, the commit at the end of a compute submission is held for
    up to 0.5 ms, so that back-to-back submissions share a command buffer and an encoder. Labels
    and interrupts of held work come later by at most that bound, plus the release thread's
    wake-up.
  - Measured on TLOU Metal 3: about 82 → 92 fps, and the mean interrupt latency went down,
    6.7 → 5.3 ms.
  - `PS4_GNM_COMPUTE_BATCH=0` restores a commit at the end of every submission.
- **Per-encoder access fences for aliasing guest windows** (docs/gnm-ordering.md, "Aliasing guest
  windows").
  - Two buffers over the same guest memory are not ordered by Metal 3's tracking, which works per
    object. Metal3Backend now gives every encoder an `MTLFence`. The renderer makes a use wait for
    the overlapping in-flight accesses through other windows.
  - This costs about 0.2-0.3 ms of encoder CPU and about 0.1 ms of GPU per TLOU frame.
- **The texture cache's alias copy is in the renderer's upload command buffer**
  (`TextureCache::GpuCopyHook`).
  - It used to be committed at once as a command buffer of its own on the renderer's queue, ahead
    of the open seq.
  - It is now encoded through the backend into the open seq's upload command buffer, which also
    runs before that seq's main work. So its order against the draws that sample the copy is
    unchanged, and the same path works on Metal 4.
  - The copy is now committed with the seq rather than at once.

## Screenshot parity

`PS4_SCREENSHOT_DIR=<dir>` saves screenshots of presented flips. Two cadences:

- `PS4_SCREENSHOT_EVERY=<n>` (default 600): every n-th flip, `frame_<flip>.png`. Flips not shown
  (superseded or dropped) are counted, so the numbering is per flip.
- `PS4_SCREENSHOT_EVERY_SEC=<s>` (a whole number of seconds; it replaces the flip cadence): the
  first shown flip at or after each multiple of s seconds of wall time (CLOCK_MONOTONIC) since the
  first flip, `sec_<seconds>.png`, named by the last multiple the flip has passed. After a stall
  the shot is named by the moment it shows and the multiples it skipped are not saved. Each
  `[metal-screen] saved` line gives the time after the first flip, so a late shot is visible
  (normally name and time differ by under one flip interval), and `[metal-screen] time cadence:
  ... first flip at <t> s after start` gives the first flip's offset from process start, to
  compare between runs: a different offset shifts every pair by the same time. A debug request in
  this mode is `sec_<seconds>_req.png`. The intro of a game is paced by time, not by flips, so two
  runs at different frame rates show the same scene at the same second but not at the same flip;
  this is the cadence for comparing Metal 3 and Metal 4 runs.

`tools/metal4_route.sh` takes `EVERY=` and `EVERY_SEC=`. `tools/metal4_shot_diff.py --dirs <a> <b>
[--threshold T | --baseline <m3_a> <m3_b>] [--require-all]` pairs the `sec_*.png` of two runs by
the second and prints "paired N of M seconds"; `--baseline` takes T per second from two Metal 3
runs; `--require-all` fails when a second is in one run only (a run that stopped early). The parity rule and what the tool does not
check are in its header.

## Exit

The backend is destroyed while everything its completion handlers use is alive: ps4draw's
Shutdown completes the work (Flush, then WaitAll) and destroys it, and Init registers an exit
handler doing the same for programs that return from main without Shutdown (gnm_replay, host
tests; tests/host/gnm_exit_test.mm). The game's quit ends with `_exit`. A crash ends with the
crash handler's `exit(1)`, so the logs flush: the exit handler then does nothing (no commit, no
wait for the GPU) and the backend is not destroyed (`ps4_host_crashing`;
tests/host/gnm_crash_exit_test.mm).

On Metal 3, CompletedSeq counts a seq when its completion handler starts, so WaitAll can return
while the rest of the handler (the renderer's CommitDoneFn: fence actions due at that seq, the GPU
busy-time accounting, the texture cache's write invalidation, guest memory ticket notification and
the recycling of the upload arena's chunks) still runs; the Metal 3 backend's destructor waits for
every handler to return, as Metal 4's waits for every commit's feedback. On both backends a GPU
that still has not finished when the backend is destroyed on a normal exit is FATAL after 10 s
(a crash skips the destruction, above).
