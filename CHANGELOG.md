# Changelog

## 0.5.0 — 2026-11-01

This release integrates the Bloodborne bring-up branch, TLOU input/reticle updates, and release-review correctness fixes on top of 0.4.3.

### Playable game coverage and documentation

- Three title families now have playable compatibility entries: **The Last of Us Remastered** (`CUSA00557` v1.00), **Sonic Origins Plus** (`CUSA30448` update 02.00; Sonic 1/CD gameplay verified), and **Bloodborne GOTY** (`CUSA03173`; bring-up and local performance work target v1.09). Bloodborne v1.00 is also registered, but a separate v1.00 benchmark was not established by this audit.
- Uncharted 4 remains in progress. These statuses describe verified scenarios, not complete campaigns or every game mode.
- README now identifies the **M1 Pro / 16 GB** test machine, current macOS 27.2 system, historical OS/scene differences, renderer/resolution/Pro-mode conditions, and the limitations of each FPS report.
- Added sanitized performance provenance with Bloodborne log hashes and individual 300-present telemetry windows. No game binaries, shaders, saves or captured memory are included.
- TLOU's latest combat smoke (84.5–85.6 FPS, menus about 120) is an operator-reported integration result, separate from the historical 98.9 FPS scripted route. Sonic's 54.7 FPS Green Hill median remains its earlier bounded idle-scene result. Bloodborne's latest local patched candidate logged 49.4–58.8 FPS in the six heavier late windows, including compilation; selected zero-skipped-draw windows logged 52.6–58.8 FPS. These are not a new controlled benchmark of the final release artifact.

### Bloodborne CPU and runtime bring-up

- Expanded integer/bit and double-shift instruction lowering, CMPXCHG16B, REP STOS, and FMA instruction families used during bring-up.
- Improved PRX discovery/initialization, ELF module initialization, symbol resolution and guest pointer-return handling.
- Added AvPlayer MP4 demux and media playback through VideoToolbox H.264 and AudioToolbox AAC, plus boot-path compatibility adjustments in audio, synchronization, direct memory, threads, saves, RTC, PlayGo and related APIs.
- API coverage remains partial; this is not a complete implementation of the PS4 operating system.

### Renderer and shader translation

- Added tessellation-stage translation and MSL generation (`LS -> HS -> VS(DS) -> PS`) and geometry-stage translation (`ES -> GS -> VS(Copy) -> PS`). Synthetic translator smoke checks compile the generated MSL using Metal.
- Added GPU-side preparation and indirect geometry draws, batched tessellation, in-pass tessellation pre-pass scheduling, and deferred multi-region buffer-copy work.
- Added large private render targets and lazy texture-usage upgrades. These descriptors permit Apple GPU compression; actual AFRC activation and compression ratios were not independently established.
- Expanded shader handling for relative register moves, lane/swizzle operations, float-class checks, and NaN/Inf handling used by the new workloads.

### The Last of Us Remastered and input

- Added QuadStrip index conversion used by the weapon aiming reticle.
- Added DualSense/DualShock 4 touchpad click and touch-coordinate input, with fallback input handling for supported controllers.
- Adjusted texture-digest polling backoff to reduce repeated work on unchanged sampled textures. Digest sampling remains heuristic and may miss ordinary CPU writes outside sampled bytes; explicit targeted invalidations force refreshes.

### Release-review correctness fixes

- Removed a new compute-to-clear substitution that inferred shader behavior only from resource sizes/dispatch shape. The original compute shader now executes rather than risking replacement of unrelated work by a constant clear.
- Fixed private render-target usage upgrades so preservation copies execute after preceding producers on the Main queue, instead of being committed early on Upload.
- Restored CPU/GPU ordering before WRITE_DATA and CE dump writes to guest memory that earlier GPU work may still read.
- Removed compiler-local STD direction tracking that was lost at basic-block boundaries. STD/backward string execution remains explicitly unsupported rather than silently corrupting memory; CLD and normal forward string paths remain supported.

### Packaging and important limits

- App and bundled engine version are **0.5.0**. Rebuild existing compiled games to pick up the new compiler/runtime; the release does not update already generated game assembly in place.
- **Bloodborne 60 FPS/timestep modification is not installed by this release.** The measured local candidate had edits in generated game assembly; a clean build normally retains the game's 30 FPS cap. The final release also contains the safety changes above, so candidate FPS must not be presented as final-release performance.
- Use **Metal 3** for the documented gameplay scenarios. Sonic Metal 4 flicker remains unresolved; Bloodborne Metal 4 gameplay has not been established.
- Bloodborne online multiplayer/networked Chalice features, full campaign coverage and all save/reload scenarios are not verified. Sonic 2/3 gameplay remains unverified.
- Packages are ad-hoc signed, not notarized. Requirements remain Apple Silicon, macOS 26+, and Apple command-line tools to build games from the user's own dump.

Fresh build/test results and the exact source commit are recorded in the downloadable release manifest. App fixture smoke tests validate the manager UI with recorded data; they do not run or validate real gameplay.
