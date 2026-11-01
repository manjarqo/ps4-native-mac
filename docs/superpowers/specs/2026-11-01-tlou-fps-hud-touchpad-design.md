# The Last of Us Remastered (`CUSA00557`) — FPS Restoration & Optimization, Aiming Reticle (`QuadStrip`), and Gamepad Touchpad Design Spec

> 0.5.0 publication scope: this is the development design/plan, not independent proof that every acceptance criterion passed. See README, CHANGELOG and docs/performance-0.5.0.json for audited measurement scope. The local Bloodborne 60 FPS modification is not distributed; unsafe compute-clear substitution was removed, write/upgrade ordering corrected, and STD remains unsupported. No new controlled gameplay benchmark of those final safety changes is claimed.

- **Date:** 2026-11-01
- **Target Title:** The Last of Us Remastered (`CUSA00557`)
- **Cross-Game Non-Regression Gates:** Bloodborne GOTY (`CUSA03173` v1.09), Sonic Mania (`CUSA30448`)
- **Status:** Approved for Implementation

---

## 1. Problem Statement & Root-Cause Analysis

Three issues were identified in **The Last of Us Remastered (`CUSA00557`)**:

### 1.1 FPS Regression (`83.3 fps` -> `53.8–58.1 fps`) & Further Performance Headroom
- **Observation:** At baseline commit `28c6679` (`v0.4.3`), the automated `data_ch1` benchmark ran at **`83.3 fps`** (`9595` frames in `115.2s`). After the Sonic Mania (`022ca3f3`) and Bloodborne (`c63fda6`) integrations, the same benchmark dropped to **`53.8–58.1 fps`**.
- **Root Cause A (Full-Scan Digest Regression in `c63fda6`):**
  In `pkg/runtime/modules/libSceGnmDriver/ps4_gnm_resources.mm` (`ComputeGuestDigestLocked`, line 3298), commit `c63fda6` changed:
  ```cpp
  const bool full_scan = (n <= 4096) || (!e->surf.is_block && e->levels == 1 && n <= 8 * 1024 * 1024);
  ```
  Combined with `GetTextureImpl` (line 3663):
  ```cpp
  const bool is_static_asset = (e->surf.is_block || e->levels > 1) && e->cpu_unchanged_streak >= 4;
  const uint64_t poll_interval = is_static_asset ? 64 : 1;
  ```
  Because `OnSubmit()` advances `cpu_submit_epoch_` on every command buffer submission (`7.2–10.0` submissions per frame in TLOU), **every single-level uncompressed texture (`!e->surf.is_block && e->levels == 1`: LUTs, UI atlases, noise/wind tables, font pages) had `poll_interval = 1` forever** and was hashed byte-for-byte on the encoder thread ~120 times per frame (`~6,800` full memory scans per second).
- **Root Cause B (Excessive Digest Polling Even in `28c6679`):**
  Even in `28c6679`, `unchanged uploads skipped` reached `450,393` in 115 seconds (`~3,916` texture digest computations per second on the critical encoder thread) because:
  1. Single-level uncompressed textures (`!e->surf.is_block && e->levels == 1`) never transitioned out of `poll_interval = 1`, even when `cpu_unchanged_streak` reached thousands of consecutive unchanged checks.
  2. Block-compressed and mipmapped textures (`e->surf.is_block || e->levels > 1`) capped `poll_interval` at `64` submissions (`~6–8` frames in TLOU), forcing `~850` static textures (`415–545 MiB`) to be re-probed across guest memory every `6–8` frames.
- **Root Cause C (Stale Launcher Binary):**
  The standalone PS4Native launcher binary at `/Users/manjarqo/Library/Application Support/PS4Native/games/CUSA00557/build/ps4_app` had not been rebuilt with the latest runtime optimizations.

### 1.2 Missing Aiming Reticle / Crosshair When Aiming (`L2`)
- **Observation:** Holding `L2` to aim a firearm/bow/throwable in TLOU shows no aiming reticle/crosshair on screen.
- **Root Cause:** Every TLOU gameplay log records thousands of skipped draw calls:
  ```text
  [gnm-draw] DRAW_INDEX_AUTO: primitive type QuadStrip not supported yet; skipped (VS 0x1026ba9300 PS 0x1026bdc300 n=66) (x2048)
  [gnm-draw] DRAW_INDEX_AUTO: primitive type QuadStrip not supported yet; skipped (VS 0x1026ba9300 PS 0x1026bdc300 n=6) (x1024)
  ```
  TLOU draws the circular aiming reticle ring (`n=66` = 32 quad segments around the circle = 33 inner/outer vertex pairs) and crosshair ticks (`n=6` = 2 quad segments = 3 vertex pairs) using `DRAW_INDEX_AUTO` with `PrimitiveType::QuadStrip` (`DI_PT_QUADSTRIP = 20`).
  In `pkg/runtime/modules/libSceGnmDriver/ps4_gnm_draw.mm` (`DrawEncode`, lines 11591–11608), `rs.raster.needs_emulation` only implemented `PrimitiveType::QuadList` (`BuildQuadListIndices`) and skipped `PrimitiveType::QuadStrip`, `PrimitiveType::TriangleFan`, `PrimitiveType::Polygon`, and `PrimitiveType::LineLoop` with `SkipReason::Primitive`.

### 1.3 Gamepad Touchpad Press Does Not Open Crafting / Backpack Screen
- **Observation:** Pressing the touchpad button on a physical DualSense/DualShock 4 controller (or the secondary center button on controllers without a touchpad) in TLOU does nothing, preventing the player from opening Joel's crafting/backpack menu.
- **Root Cause:** In `pkg/runtime/modules/libScePad/ps4_pad.m` (`scePadReadState`, lines 933–996):
  1. `ORBIS_PAD_BUTTON_TOUCH_PAD` (`0x00100000`) is never set from any physical `GCController` input (`GCDualSenseGamepad.touchpadButton`, `GCDualShockGamepad.touchpadButton`, or `physicalInputProfile.buttons[GCInputDualShockTouchpadButton]`).
  2. `OrbisPadTouchData` (`touch.fingers`, `touch.touch[0]`) is never populated from `GCDualSenseGamepad` / `GCDualShockGamepad` (`touchpadPrimary`, `touchpadSecondary`) or synthesized when `ORBIS_PAD_BUTTON_TOUCH_PAD` is pressed.
  3. Both `gp.buttonMenu` and `gp.buttonOptions` were mapped to `ORBIS_PAD_BUTTON_OPTIONS`, leaving no button mapped to `ORBIS_PAD_BUTTON_TOUCH_PAD` on non-PlayStation controllers or when pressing the Share/View/Back button.

---

## 2. Technical Design

### 2.1 Component 1: `QuadStrip`, `TriangleFan`, `Polygon`, and `LineLoop` Primitive Emulation (`ps4_gnm_draw.mm`)
- **AMD GCN `DI_PT_QUADSTRIP` (`PrimitiveType::QuadStrip`) Winding & Topology:**
  - Given `vertex_count >= 4`, the number of quads is `quad_count = (vertex_count - 2) / 2`.
  - For quad `q` in `[0, quad_count)`:
    - Base vertex offset `b = 2 * q`
    - Rail vertices: `v0 = src_vertex(b + 0)`, `v1 = src_vertex(b + 1)`, `v2 = src_vertex(b + 2)`, `v3 = src_vertex(b + 3)`
    - Note: unlike OpenGL `GL_QUAD_STRIP` pre-3.2, AMD GCN `DI_PT_QUADSTRIP` orders vertices along the two rails identically to a triangle strip where each pair `(2*q, 2*q+1)` forms a cross-rail edge, decomposing into two consistent-winding triangles:
      - Triangle 0: `(v0, v1, v2)`
      - Triangle 1: `(v2, v1, v3)`
    - Emit `6` `uint32_t` indices per quad (`6 * quad_count` total) and submit via `drawIndexedPrimitives:MTLPrimitiveTypeTriangle`.
- **Additional Emulated Primitives (`TriangleFan` / `Polygon` and `LineLoop`):**
  - `BuildTriangleFanIndices`: for `vertex_count >= 3`, `tri_count = vertex_count - 2`, emit `(v(0), v(t+1), v(t+2))` for `t in [0, tri_count)`, rendered as `MTLPrimitiveTypeTriangle`.
  - `BuildLineLoopIndices`: for `vertex_count >= 2`, emit `2 * vertex_count` indices `(v(i), v((i+1) % vertex_count))` for `i in [0, vertex_count)`, rendered as `MTLPrimitiveTypeLine`.
- **Integration in `DrawEncode` (`ps4_gnm_draw.mm:11591–11608`):**
  - Route `PrimitiveType::QuadList`, `PrimitiveType::QuadStrip`, `PrimitiveType::TriangleFan`, `PrimitiveType::Polygon`, and `PrimitiveType::LineLoop` through index-buffer emulation for both `DRAW_INDEX_AUTO` (`index_buf == nullptr`) and indexed draws (`index_buf != nullptr`).

### 2.2 Component 2: Physical Gamepad Touchpad Button & Touch Coordinates (`ps4_pad.m`)
- **Controller Input Extraction Helper (`ps4_pad_extract_touchpad`):**
  - Inspect `GCController *controller` and `GCExtendedGamepad *gp`:
    1. **PlayStation Controllers (`GCDualSenseGamepad` / `GCDualShockGamepad` via `NSClassFromString` / `respondsToSelector:` and `physicalInputProfile`):**
       - Check `touchpadButton.isPressed` via property selector on `gp` or `controller.physicalInputProfile.buttons[@"Touchpad Button"]`.
       - Check `touchpadPrimary` (`GCControllerDirectionPad`) and `touchpadSecondary` (`GCControllerDirectionPad`) via property selectors on `gp` or `controller.physicalInputProfile.dpads[@"Touchpad Primary"]` / `@"Touchpad Secondary"`.
       - Convert normalized `[-1.0, +1.0]` axis values `(x, y)` (when `x != 0.0f || y != 0.0f`) to PS4 touchpad coordinates (`1920 x 950`):
         - `px = (uint16_t)clampf((x + 1.0f) * 0.5f * 1919.0f, 0.0f, 1919.0f)`
         - `py = (uint16_t)clampf((1.0f - y) * 0.5f * 949.0f, 0.0f, 949.0f)`
    2. **Fallback Button Mapping for All Controllers:**
       - `gp.buttonMenu` -> `ORBIS_PAD_BUTTON_OPTIONS` (right center button: Options / Start / Menu).
       - `gp.buttonOptions` (left center button: Share / Create / View / Back) and `gp.buttonHome` (PS / Guide button):
         - Map to `ORBIS_PAD_BUTTON_TOUCH_PAD` (unless disabled via `PS4_PAD_SHARE_AS_OPTIONS=1`, in which case `gp.buttonOptions` maps to `ORBIS_PAD_BUTTON_OPTIONS`). This ensures both DualShock/DualSense users (who may press either the physical touchpad click or Share/Create) and Xbox/generic controller users (who press View/Back) can open the TLOU crafting menu and Bloodborne gesture/personal effects menus effortlessly.
    3. **Default Touch Finger Synthesis on Touchpad Click:**
       - When `ORBIS_PAD_BUTTON_TOUCH_PAD` is pressed and no explicit finger coordinates were reported by `touchpadPrimary`/`touchpadSecondary` or `PS4_PAD_CTL`, synthesize a 1-finger touch at the center of the touchpad `(960, 475)` (`id = 0`), because games that check both `buttons & ORBIS_PAD_BUTTON_TOUCH_PAD` and `touchData.touchNum > 0` require valid touch coordinates during a click.

### 2.3 Component 3: Adaptive Texture Digest Polling & Full-Scan Threshold (`ps4_gnm_resources.mm`)
- **Restore `n <= 4096` Full-Scan Threshold in `ComputeGuestDigestLocked` (`ps4_gnm_resources.mm:3298`):**
  - Full byte-for-byte scan only for tiny buffers (`n <= 4096`).
  - For `n > 4096`:
    - Single-level uncompressed surfaces (`!e->surf.is_block && e->levels == 1`): `64` evenly-spaced cache-line (`64-byte`) probes (`4 KiB` total read), which still detects localized CPU updates (such as Sonic Mania's software framebuffer and Bloodborne's menu masks) while costing `< 150 ns`.
    - Block-compressed or mipmapped surfaces (`e->surf.is_block || e->levels > 1`): `16` evenly-spaced cache-line (`64-byte`) probes (`1 KiB` total read).
- **Adaptive Exponential Backoff in `GetTextureImpl` (`ps4_gnm_resources.mm:3663`):**
  - Replace the fixed binary `poll_interval = is_static_asset ? 64 : 1` with a helper `ComputeTexturePollInterval(bool is_block_or_mip, uint32_t unchanged_streak)`:
    - **If `is_block_or_mip` (`e->surf.is_block || e->levels > 1`):**
      - `unchanged_streak < 4` -> `1`
      - `unchanged_streak < 16` -> `64`
      - `unchanged_streak < 64` -> `256`
      - `unchanged_streak >= 64` -> `1024`
    - **If single-level uncompressed (`!e->surf.is_block && e->levels == 1`):**
      - `unchanged_streak < 8` -> `1` (any dynamic CPU framebuffer like Sonic Mania modifies guest memory every frame so its `unchanged_streak` stays `0..1` and is polled on every single submission; also preserves `tex_evict_test` behavior where `unchanged_streak` is `1..2`)
      - `unchanged_streak < 32` -> `16`
      - `unchanged_streak < 128` -> `64`
      - `unchanged_streak >= 128` -> `256`
  - **Impact on TLOU:**
    - Static block-compressed and mipmapped textures quickly reach `unchanged_streak >= 64` and are only re-probed once every `1024` submissions (`~100–140` frames instead of every `6` frames).
    - Static single-level uncompressed LUTs/UI textures reach `unchanged_streak >= 128` within `~2` seconds and back off to `256` submissions instead of polling on every submission.
    - Total texture digest computations in TLOU drop by **>90%**, eliminating the `c63fda6` regression and surpassing the `28c6679` baseline FPS (`83.3 fps`).

---

## 3. Verification & Non-Regression Criteria

1. **Unit & Host Tests:**
   - `go test ./...` passes 100%.
   - `tests/host/tex_evict_test` passes all existing assertions plus new adaptive backoff assertions.
   - `tests/host/pad_test` passes all existing assertions plus new touchpad button & touch coordinate tests.
   - New `QuadStrip` primitive emulation test verifies `BuildQuadStripIndices` for `n=6` (2 quads -> 12 indices) and `n=66` (32 quads -> 192 indices).
2. **TLOU (`CUSA00557`) Verification (Unattended Desktop Mode):**
   - Rebuild both `/Users/manjarqo/ps4recomp-work/bb_research/tlou_check/ps4_app` and `/Users/manjarqo/Library/Application Support/PS4Native/games/CUSA00557/build/ps4_app`.
   - Benchmark run (`data_ch1` + `walk_script.txt` for 115s): verify **average FPS >= 83.3 fps** (targeting `85–95+ fps`).
   - Gameplay weapon & crafting test (`SAVEDATA09` via `PS4_PAD_CTL` in unattended desktop mode):
     - Hold `L2`: confirm `0` occurrences of `primitive type QuadStrip not supported yet; skipped` in the log and confirm the aiming reticle is rendered on screen.
     - Press `touch`: confirm `ORBIS_PAD_BUTTON_TOUCH_PAD` + touch coordinates open Joel's crafting/backpack screen on screen.
3. **Bloodborne (`CUSA03173`) & Sonic Mania (`CUSA30448`) Non-Regression:**
   - Run Bloodborne in unattended desktop mode to verify `40+ fps` in-game 3D rendering and zero regressions.
   - Run `sonic_hle_test` and `tex_evict_test` to confirm dynamic CPU textures update every frame.
