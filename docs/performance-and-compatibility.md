# Game compatibility and performance

[Back to the app quick start](../README.md#get-started) · [App guide](app-guide.md)

This reference preserves the measured conditions and limitations behind the short game list in
the README. The 0.5.0 release and newer source builds are distinguished where their features differ.

## Supported games on Mac

Test machine: **Apple M1 Pro, 16 GB unified memory**. The current development system is
**macOS 27.2 (26B123)**; historical TLOU route measurements used macOS 27.0.1 and the Sonic
benchmark used macOS 27.2. Bloodborne logs record M1 Pro, Metal 3, 1920x1080 and **Pro mode on**;
they do not stamp an OS version. All numbers below are local observations, not cross-hardware
results or full-game averages. The final 0.5.0 package has not received a new controlled gameplay
benchmark after its release-review safety fixes.

| Game | Stage | fps | Resolution | Notes |
| --- | --- | --- | --- | --- |
| The Last of Us Remastered (CUSA00557 v1.00) | Playable: boot, menus, movies, gameplay, saves | Latest operator-reported combat smoke: **84.5–85.6 fps**, menus **120 fps**. Historical 300 s courtyard route: **98.9 fps** Metal 3 / 85.5 fps Metal 4 | 1920x1080, base PS4 mode, MetalFX off; current smoke Metal 3 | M1 Pro / 16 GB. Latest reticle/crafting checks are operator-reported, not a new controlled 0.5.0 benchmark. Historical route details below; daylight lighting remains imperfect. |
| Bloodborne: Game of the Year Edition (CUSA03173 v1.09) | Playable offline 3D gameplay in the tested early areas | Local patched candidate: menus about **60 fps**; heavier late windows **49.4–58.8 fps**, including compilation. Selected windows without skipped draws: **52.6–58.8 fps** | 1920x1080, Metal 3, Pro mode on, MetalFX off | M1 Pro / 16 GB. Requires the separate local 60 FPS/timestep modification for these numbers; the published 0.5.0 compiler does not apply it; current `main` adds automatic application for a matching v1.09 image. Without that modification the game retains its 30 FPS cap. Candidate predates final release-review fixes. |
| Uncharted 4: A Thief's End (CUSA04529) | In progress: boots, menus, New Game, chapter 1 (boat cutscene and boat gameplay), saves, audio | Title screen about 21–22 fps, boat gameplay about 20–21 fps (`PS4_PRO=0`, 1080p, measured while other work ran on the machine). Pro mode: not re-measured (TBD) | 1920x1080 (`PS4_PRO=0`); 2560x1440 in Pro mode | Title screen: the scene is lit, but fog and light shafts are missing. Boat cutscene: Drake and Sully are lit and the motion-blur smear is fixed. Gameplay: water colour and foam differ from a PS4 and the sky is too dark. Base mode is recommended. |
| Sonic Origins Plus (CUSA30448, update 02.00) | Playable in verified Sonic 1 / Sonic CD scenarios; other parts unverified | Sonic 1 idle Green Hill: **54.7 fps** median (control **55.5 fps**). Sonic CD: about **55 fps** observed | 1920x1080, base PS4 mode, Metal 3, MetalFX off | M1 Pro / 16 GB, macOS 27.2. Sonic 1/CD gameplay and input verified. Sonic 2 selection only; Sonic 2/3 gameplay and campaign save/reload unverified. Metal 4 flickers. Historical benchmark, not a fresh 0.5.0 run. |

How the TLOU numbers were taken:

- Route: `tools/metal4_route.sh` plays a scripted pad route from a copy of a chapter 1 save, with
  `PS4_PRO=0`, separate data and cache directories and no screenshots. `tools/metal4_perf_ab.sh`
  alternated 5 runs of 300 s per backend on one build (commit 8bdffe7) and kept only pairs taken
  under the same machine load. Noise between runs was ±1.3 fps. The full numbers are in
  [docs/metal4-baseline.md](metal4-baseline.md).
- Batched compute commits (9 command buffers per frame instead of 49) raised this route from
  about 82 to 92 fps on Metal 3 in their own A/B
  ([docs/compute-batching.md](compute-batching.md)).
- Earlier measurements, at commit 8145002, with a different route script, so not directly
  comparable: walking (330 s) chapter 1 courtyard 89.7 fps and spore corridor 99.6 fps, no frame
  over 100 ms; standing courtyard 78.5–78.9 fps and Sarah's house 113.7–114.5 fps.
- The frame rate is uncapped. The bench window is in the background, so vsync does not limit it.
  The machine's background load moves these numbers by a few fps between runs.
- The route numbers were taken before the v0.3.0 colour fixes. The hair and foliage shadow work
  that now runs costs about 0.4 ms of GPU time per frame in scenes with much hair and foliage; the
  route was not re-measured.

### Current TLOU combat checks

The integration handoff reports **84.5–85.6 fps** in a 3D combat scene and **120 fps** in menus,
with the QuadStrip weapon reticle and gamepad touchpad crafting screen working. These short
operator checks are distinct from the older scripted courtyard route above; they are not a
controlled A/B or proof of zero regression across the game. Older gate logs include shader
compilation and are not comparable steady-state measurements.

### Bloodborne: Game of the Year Edition (CUSA03173)

Update **01.09** reaches title/menu, character creation, cutscenes and offline 3D gameplay in the
operator-identified Iosefka's Clinic / Central Yharnam areas. Base **01.00** is also registered in
the compatibility database; a separate 01.00 benchmark was not established by this release audit.

#### Local candidate performance (Metal 3, 1920x1080)

The available `bb_boot20`–`bb_boot28` logs identify Apple M1 Pro, **Pro mode on** and MetalFX off.
Each FPS sample below covers **300 renderer-reported presents**. These were successive bring-up
runs, not controlled alternating A/B measurements. Scene and camera attribution comes from the
operator, not automatic log classification.

| Candidate | Late observed FPS | Notes |
| --- | --- | --- |
| Initial bring-up (`bb_boot20` / `21`) | 19.0 / 19.1 | Menu cap 30 fps; about 50 GPU waits per frame |
| Reduced synchronization + GPU indirect GS + local 60 FPS modification (`22`) | 34.2–34.3 | Menus about 60 fps |
| Batched tessellation (`23`) | 37.8–37.9 | Successive-run observation |
| Private render targets + deferred copies (`25`) | 45.5–47.1 | Descriptor changes permit hardware compression; actual AFRC use was not measured |
| Additional candidate hoisting / compute-clear substitution (`28`) | 49.4–58.8 | Includes compilation windows; selected zero-skipped-draw windows 52.6–58.8 |

The handoff reports selected heavy-scene windows at **55.4–58.8 fps**, and **52.6–56.7 fps** while
rotating the camera. The wider range above includes all six late windows of the latest log,
including a 49.4 fps window with pending compilation. No sustained 60 fps or full-game average
is claimed. Sanitized samples and log hashes: [0.5.0 measurement provenance](performance-0.5.0.json).

**The measurements used a 60 FPS/timestep modification in local generated game assembly.
The published 0.5.0 engine kit does not include the automatic patch added later to `main`.** A clean rebuild with the published 0.5.0 engine does not install it and
normally retains Bloodborne's 30 FPS cap. Current `main` can apply it during a fresh build when
the supported v1.09 image passes all original-instruction checks; see [app guide](app-guide.md#features-in-current-main). No game assembly, executable, save or captured game data is
distributed with the release assets. The final release also removes an unproven shape-only compute-clear substitution,
restores CPU/GPU write ordering, and fixes private-texture upgrade ordering; the candidate FPS
numbers therefore do not benchmark the final 0.5.0 artifact.

#### Included engine work

- x86-64 integer/bit, double-shift, CMPXCHG16B, REP STOS and FMA lowering improvements; guest PRX
  initialization and pointer-return corrections. Backward string execution through `STD` remains
  explicitly unsupported rather than silently using the wrong direction across blocks.
- AvPlayer MP4 demux with VideoToolbox H.264 / AudioToolbox AAC playback, plus boot-path HLE, save,
  audio, thread and memory compatibility changes. This does not imply complete OS-library support.
- Tessellation (`LS -> HS -> VS(DS) -> PS`) and geometry (`ES -> GS -> VS(Copy) -> PS`) translation,
  GPU indirect geometry draws, batched tessellation and queued buffer-copy work.
- Large private render targets with lazy usage upgrades. The descriptor policy is compatible with
  Apple GPU compression; AFRC activation or compression ratios have not been independently measured.
- Hardware clear replacement is **not enabled merely from buffer sizes or dispatch shape**; the
  guest compute shader runs unless its semantics can be established safely.

Online multiplayer and networked Chalice Dungeon features are unavailable. Coverage of later
areas, long sessions and every save/reload scenario remains incomplete.

### Sonic Origins Plus

Status as of 2026-10-31: Sonic 1 and Sonic CD launch, render gameplay and accept input. Sonic 1
was also controlled by the user; Sonic CD was checked by starting a new game, pausing/resuming,
and issuing movement input. Attract-mode footage was excluded from control verification. The
base game, update 02.00 and four DLC packages are installed in the local bring-up project.

#### Measured performance

Both runs used an Apple M1 Pro with 16 GB RAM, macOS 27.2, AC power, Metal 3, 1920x1080,
`PS4_PRO=0`, MetalFX off and synchronous shader compilation with an existing cache. Automatic
confirmation stopped at 200 seconds; the measurement window was 280–320 seconds in idle
Green Hill, with physical input isolated. No compilation or GPU tests ran during that window.

| Run | Build | Median logged fps | Frame p50 | Frame p95 |
| --- | --- | --- | --- | --- |
| 34 | Control build with the preceding renderer fixes | 55.5 | 18.15 ms | 19.35 ms |
| 35 | Measured candidate: proven visible-texel write coverage and stronger save I/O error handling | **54.7** | **18.4 ms** | **19.7 ms** |

These are medians of renderer-reported telemetry windows, not independent hardware timing,
a full-game average or proof of statistical significance. The measured correctness changes did
**not** demonstrate an FPS improvement over the control run. Sustained 60 fps has not been
established. Sonic CD reached about 55 fps in a gameplay smoke run, but was not benchmarked
under this controlled scenario. No Sonic 2/3 gameplay FPS is claimed. These measurements predate the final 0.4.2 save-error and
dense-branch fixes and have not been repeated for 0.5.0.

**Use Metal 3 for Sonic.** The Metal 4 comparison was stopped after the user observed flickering;
early telemetry was also slower. Static host readback tests passing on Metal 4 do not establish
stable live rendering.

#### Implemented fixes and current limits

- Correct display interpretation of integer textures and refresh of CPU-backed sampled images,
  resolving the earlier black-screen/stale-framebuffer failures.
- GPU aliases must cover the requested image's byte range; 3D storage textures retain their depth.
- Pending GPU buffer writes initialize color/storage images on the GPU timeline; depth-decompress
  copy handling fixes menu rendering. Full refresh now requires coverage of all consumed visible
  texels rather than an arbitrary 8 KiB prefix.
- A fixed-size CPU detile path accelerates complete single-sample 32-bit microtiles.
- SaveDataMemory2 preserves repeated setup and persists writes without requiring explicit Sync.
  Write/flush/fsync/close failures propagate before replacing the prior save. Disk writes and
  subsequent reload are verified; campaign progress across restart is not yet verified.
- The local Sonic launcher offers Sonic 1, Sonic CD, Sonic 2 and Sonic 3 & Knuckles. It selects the
  game's carousel through observed UI state and real controller input; startup notices and the
  final mode/character confirmation remain manual. Sonic 2 selection was checked live; this is
  not a Sonic 2 gameplay claim.

Measurement data: [Sonic performance report](sonic-origins-performance.json).
The optional [startup chooser](../examples/sonic-origins/README.md) is published separately
from game content; no game files or memory captures are distributed.

### Colour fidelity (TLOU)

The colours were compared with a PS4 reference video on location-matched frames, as CIE L\*C\*h
statistics (`tools/color_compare.py`, [docs/color-measurement.md](color-measurement.md)):

| Frame | Before v0.3.0 | v0.3.0 | PS4 reference |
| --- | --- | --- | --- |
| Interior save point, median lightness (L\* p50) | 10.2 | 3.2 | 2.6 |
| Joel's hair, lightness (L\*) | 32 | 9 | 4 (hue within 20 degrees) |
| Plank courtyard in daylight, median lightness (L\* p50) | not measured | 11–19 (two captures) | 32 |

What was fixed in v0.3.0: the output gamma of `sceVideoOutAdjustColor` was applied inverted (the
image was brightened and washed out, and the in-game brightness slider went the wrong way); hair
and foliage were never shadowed (a shader buffer load mode, `addr64`, was not translated); two of
the three sun shadow cascades were always in shadow (an HTILE fast clear covered only the first
slice of the shadow depth array). Sunlit daylight surfaces are still darker than on a PS4 (see
[Known issues](#known-issues)).

**Upstream milestones (not verified in this fork):**

- Hollow Knight: Silksong: upstream reported a boot into the Unity runtime with a Metal display.
- Hogwarts Legacy: upstream reported a boot up to a virtual address space allocation failure.

---

## Known issues

- **Sonic Origins Plus:** Metal 4 flickers; use Metal 3. Sonic 2/3 gameplay and campaign
  save/reload remain unverified. These measurements have not been repeated for 0.5.0.

- **The Last of Us: daylight.** Sunlit daylight surfaces are darker than on a PS4 (plank courtyard
  L\* 11–19 against 32). The sun direction is the game's own data, so the remaining difference is in
  the evaluation of lighting or shadows; it is under investigation.
- **HTILE on Pro depth arrays.** A compute HTILE fast clear of a depth array in Pro (Neo) mode
  covers only its first slice (logged); in base mode each cleared slice is covered.
- **Window colour space.** The window layer is tagged sRGB, so macOS colour-matches the frame to a
  wide-gamut panel. The effect on screen is expected, not measured; `PS4_COLORSPACE=native`
  restores the untagged layer.
- **Uncharted 4.**
  - The title screen has no fog and no light shafts.
  - In gameplay the water colour and foam differ from a PS4, and the sky is too dark.
  - Red streaks seen in boat gameplay look like the game's own damage-direction indicator (a PS4
    video of the same scene shows them too); this is not confirmed.
  - Image descriptor (T#) tables that a shader indexes at run time are bound when a bound visible
    to the CPU gives at most 8 entries. Larger tables, and indices that only the GPU knows (for
    example in the reflection-probe culling shader), read a null image; each case is counted and
    logged once per shader.
  - Decals are not applied (CMASK is not emulated).
  - The shadow cube map is resolved from a 2D target ("texture type mismatch" in the log).
  - Frame rate is below a PS4's 30 fps: about 21–22 fps on the title screen and 20–21 fps in boat
    gameplay in base mode.
  - The faster guest-memory dispatch path (`PS4_GNM_GUEST_MEMORY_FAST=1`, about 3 fps more in boat gameplay) is
    opt-in: in long runs it showed rare anomalies (a stalled dispatch, a GPU memory blow-up, one
    crash) that the default path did not show, not yet explained.
- **Metal 4 is slower than Metal 3.** On the TLOU route it runs at 85.5 fps against 98.9. Each
  Metal 4 encoder starts with a barrier after all earlier work, so its command buffers never
  overlap on the GPU (11.4 against 9.3 ms of GPU time per frame). Metal 3 stays the default until
  Metal 4 at least matches it ([docs/metal4-backend.md](metal4-backend.md),
  [docs/gnm-ordering.md](gnm-ordering.md)).
- **Quit after a GPU hang.** If the command buffer watchdog gave up on the GPU, a normal quit waits
  10 s for the GPU and then stops with a FATAL message.
- **x87.** 80-bit values are kept as doubles, which loses 11 mantissa bits.
- **Misaligned atomics.** A LOCK operation on an operand that crosses a 16-byte boundary raises
  SIGBUS. TLOU has none.
- **NaN sign.** The sign of NaN results from invalid operations differs from x86 (ARM default NaN).
- **Unresolved imports.** Any import without an implementation is bound to a stub that stops the
  game with a log message naming the import. TLOU has 2, in `libSceGnmDriver`; it was never seen
  calling them.
- **Screenshot frames.** With screenshots on, the frames that capture one take ~130–150 ms.
- **Shader cache sharing.** Without a TITLE_ID in `param.sfo`, the cache key falls back to the game
  folder's name, so two such games in folders with the same name share a cache.
- **Bundle ID.** Bundles get the ID `org.ps4native.<TITLE_ID>`. Without a TITLE_ID in `param.sfo`
  they fall back to `org.ps4recomp.<executable name>`, so every such `eboot.app` has the same ID.
- **macOS metadata files.** On exFAT/FAT volumes, AppleDouble `._*` files next to the PRX modules
  produce harmless "Skipping module" messages.

---
