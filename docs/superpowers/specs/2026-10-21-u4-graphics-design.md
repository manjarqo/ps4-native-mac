# Uncharted 4 graphics: pass-level capture, replay and reference-driven fixes

Date: 2026-10-21. Status: approved by the owner (sections 1–3).

## Goal

Make Uncharted 4 look **playable** on the Metal GNM renderer:

- The "Press Any Button" title screen is close to a real PS4 frame in colour, lighting and composition, with no artefacts.
- In chapter 1, Drake and the other characters are visible and lit, both in the boat cutscene and in boat gameplay.
- There are no gross artefacts: no red streaks, no black blocks or squares, no washed-out exposure.
- Smaller differences, such as decals or exact shadow detail, are acceptable.

## Starting point

Branch u4-render (worktree `~/ps4recomp-work/PS4Recomp-render`) is ahead of u4-bringup. It contains:

- the merged u4-pad and u4-rectlist branches;
- renderer fixes reviewed in two rounds (render1-review.md, render2-review.md);
- eef5783, which has not been reviewed yet: render targets written by buffer stores are refreshed before they are sampled.

The findings so far are in `.superpowers/sdd/2026-10-20-uncharted4-bringup/render-report.md`.

- **Drake.** He is present in the depth prepass and in the g-buffer: MRT2 at 0x130b520000 holds material IDs and MRT0 at 0x13100b0000 holds albedo. He is lost in tiled deferred lighting, which is 33 indirect compute dispatches writing 0x1323370000. The output is flat sky-grey, which looks like zero lighting plus fog. One of the lighting inputs, 0x1309858000 (11_11_10 float), is never written by any GPU work in three traced gameplay frames.
- **Other open issues:**
  - yellow and white blotches on Drake in the cutscene;
  - red smears from about frame 7800 on;
  - washed-out exposure and a grey sky;
  - faint squares;
  - the shadow cube aliased to a 2D depth target;
  - decals that are never applied, because CMASK is not emulated;
  - the LDS-spill buffer sized for only 1024 groups on indirect dispatches.
- **Title screen.** The owner reports wrong colours and artefacts.

## Approach: pass-level capture, replay, reference comparison

### 1. Frame capture

Set `PS4_GNM_CAPTURE_FRAME=<n>` and optionally `PS4_GNM_CAPTURE_DIR=<dir>`. On frame n the renderer records every pass, meaning every draw and every dispatch, in submission order:

- **Metadata** goes into `manifest.json`:
  - pass index, queue, and draw or dispatch type;
  - shader stage hashes and guest addresses;
  - indirect arguments;
  - every bound input (T#/V#/S#), with guest address, format, dimensions and size;
  - every output (colour and depth targets, storage images and buffers);
  - blend, depth, stencil and viewport state.
- **Each output after the pass has completed**, as a PNG for viewing (with a tonemap or normalisation documented per format) and as raw bytes.
- **Each input**, as a snapshot of the guest memory ranges the pass reads, so that the pass can be replayed. Inputs shared between passes are stored once and keyed by address and content hash.

The capture costs nothing when the variable is unset. Captures live outside the repository under `~/ps4recomp-work/u4_research/captures/`.

This builds on the existing debug dumps (`PS4_GNM_DUMP_MEM`, `PS4_GNM_DUMP_DRAWS_RT`, from 5162e69) rather than duplicating them.

### 2. Capture overview

A script turns a capture into a local HTML page. The page lists the passes in order with output thumbnails and metadata, so the first pass where the image goes wrong can be found by eye. The script lives in the repository's `tools/`; its output stays outside the repository.

### 3. Pass replay

A host tool loads one pass from a capture: shader bytecode, user data and SRT, and the snapshotted input memory. It runs the pass through the same gcn-recompiler translation and the same Metal binding and encode code as the game, then writes the outputs.

- **Fidelity check:** replaying a captured pass must reproduce its captured output byte for byte. A mismatch is itself a bug, either in replay or in determinism, and is reported.
- **Locking fixes:** every rendering fix is locked by a host test that replays a minimal extracted pass, containing only the shader and data the test needs, and asserts the corrected output property. The test must fail on the old code (AGENTS.md: no fake tests, no stubs). Only minimal extracted data goes into the repository, never whole game frames.

### 4. Reference frames

The sources are:

- frames from the PS4 playthrough video `https://www.youtube.com/watch?v=Lecdfcv-8IE`, covering the title screen, the main menu, the chapter 1 boat cutscene and boat gameplay;
- the owner's real-PS4 screenshot `u4_research/reference/press_any_button_ps4.png`.

Reference frames are copyrighted and stay outside the repository in `~/ps4recomp-work/u4_research/reference/`. Downloading the video, or installing yt-dlp/ffmpeg if they are missing, needs the owner's confirmation first, with the file name and size stated.

Frames are compared in two ways:

- by eye, with an agent viewing the frames side by side;
- with simple metrics: mean colour and luminance per region of a 4x4 grid, plus a luminance histogram, to catch exposure, tint and grey-sky errors.

A pixel-exact match is not expected, because camera, compression and timing differ.

### 5. Per-issue loop

1. Capture the frame.
2. Find the first bad pass.
3. Replay that pass.
4. Fix the root cause.
5. Lock the fix with a host test.
6. Recapture and compare against the reference.
7. Check TLOU for regressions.

## Phases and acceptance

**Phase 0: base.**
- Review eef5783.
- Merge u4-render into u4-bringup. The base must also contain gpu-membudget, shader-cache, present-pacing, async-compute, tex-evict, audio3dmix and the README.
- New work happens on one branch, `u4-graphics`, from the merged u4-bringup.

**Phase 1: tools.** Build capture, overview and replay.
- Acceptance: replaying a g-buffer draw, a lighting compute dispatch and the tonemap pass from a U4 capture reproduces their captured outputs byte for byte.

**Phase 2: the title screen to the reference.** Work in this order:
1. colour, tonemap and exposure;
2. light shafts and fog;
3. black blocks and squares;
4. foliage and alpha.

Acceptance:
- side by side with the reference, there is no noticeable difference in colour, light or composition;
- per-region mean colour and luminance are close to the reference;
- there are no artefacts.

**Phase 3: chapter 1.** Work in this order:
1. lighting, until Drake and the characters on the boat are visible and lit. This includes finding the producer of 0x1309858000.
2. red streaks;
3. the cutscene blotches on Drake;
4. any exposure or sky problems left after Phase 2.

Acceptance: frames from the boat cutscene and from boat gameplay, side by side with the video frames, show visible, lit characters, no gross artefacts, and plausible water, sky and boat.

**Phase 4: if time remains (not required for "playable").**
- the shadow cube aliasing (2D target vs cube): reject aliased targets of the wrong type or size and assemble the cube from guest memory;
- CMASK emulation for decals;
- the LDS-spill limit on indirect dispatches.

**Every phase must also meet these conditions:**
- **TLOU does not regress.** The courtyard walk from the data_ch1 test fixture runs with fatal 0, its screenshots match base, and fps on warm caches is within noise of base.
- **U4 stays healthy.** There are no GPU hangs, and chapter 1 fps does not drop below the current values: base mode 33–34, Pro 24–26.

## Execution

- **Method:** superpowers subagent-driven development. Each plan task goes to a fresh implementer, followed by a task review covering spec and quality, then fix rounds and a scoped re-review, with a final whole-branch review at the end. Progress is kept in the SDD ledger.
- **Parallelism:** only one implementer works on renderer and translator files at a time. Reviews run in parallel. Phase 1 tooling may overlap Phase 0.
- **Rules:** `parallel-rules.md` applies.
  - One game at a time, through heavy_lock.
  - Every run is time-bounded.
  - Every wait loop has a hard timeout and checks that the process it waits for is still alive.
  - Data and cache dirs are scratch dirs. Never touch the owner's saves, caches or installed eboots.
  - gcn-recompiler is edited only through its in-repo copy; the shared `3rdparty` is never touched.
  - Local commits only, no push.
- **Liveness:** the controller checks any agent that has gone 90 minutes without a commit or a report.

## Out of scope

- Pixel-exact matching with PS4 output.
- Performance work beyond holding today's fps.
- Multiplayer.
