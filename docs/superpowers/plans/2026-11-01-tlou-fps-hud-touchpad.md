# The Last of Us Remastered (`CUSA00557`) — FPS, Aiming Reticle (`QuadStrip`), and Gamepad Touchpad Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Restore and increase TLOU (`CUSA00557`) FPS beyond the `83.3 fps` baseline, render the missing aiming reticle (`QuadStrip` primitive emulation), and enable opening the crafting menu from a physical gamepad touchpad press (or Share/View fallback button) without regressing Bloodborne (`CUSA03173`) or Sonic Mania (`CUSA30448`).

**Architecture:**
1. **`libSceGnmDriver` Primitive Emulation (`ps4_gnm_draw.mm`):** Implement `BuildQuadStripIndices`, `BuildTriangleFanIndices`, and `BuildLineLoopIndices` alongside `BuildQuadListIndices` and wire them into `DrawEncode` so TLOU's `DRAW_INDEX_AUTO` `QuadStrip` calls (`n=66` reticle ring, `n=6` crosshair ticks) render as indexed triangle lists.
2. **`libScePad` Touchpad Input (`ps4_pad.m`):** Read `GCDualSenseGamepad` / `GCDualShockGamepad` `touchpadButton`, `touchpadPrimary`, and `touchpadSecondary` (plus `physicalInputProfile.buttons[@"Touchpad Button"]` and `gp.buttonOptions` / `gp.buttonHome` fallback), set `ORBIS_PAD_BUTTON_TOUCH_PAD` (`0x00100000`), and populate `OrbisPadTouchData` (`1920x950`).
3. **`libSceGnmDriver` Adaptive Texture Digest Polling (`ps4_gnm_resources.mm`):** Restore `n <= 4096` full-scan threshold in `ComputeGuestDigestLocked` and replace fixed `poll_interval` in `GetTextureImpl` with adaptive exponential backoff based on `cpu_unchanged_streak`.

**Tech Stack:** Objective-C++ (`libSceGnmDriver`), Objective-C (`libScePad`), Metal (`MTLRenderCommandEncoder`), GameController framework (`GCController`, `GCExtendedGamepad`, `GCDualSenseGamepad`, `GCDualShockGamepad`).

---

### Task 1: Emulate `QuadStrip` (and `TriangleFan`/`Polygon`/`LineLoop`) in `ps4_gnm_draw.mm`

**Files:**
- Modify: `pkg/runtime/modules/libSceGnmDriver/ps4_gnm_draw.mm:8132-8176`
- Modify: `pkg/runtime/modules/libSceGnmDriver/ps4_gnm_draw.mm:11591-11608`
- Modify: `tests/host/tex_evict_test.mm` (or dedicated host test)

- [ ] **Step 1: Implement `BuildQuadStripIndices`, `BuildTriangleFanIndices`, and `BuildLineLoopIndices` in `ps4_gnm_draw.mm`**
  Add index expansion helpers right after `BuildQuadListIndices` (`ps4_gnm_draw.mm:8175`):
  - `BuildQuadStripIndices`: for `vertex_count >= 4`, `quad_count = (vertex_count - 2) / 2`, emit `6 * quad_count` `uint32_t` indices `(v0, v1, v2, v2, v1, v3)` per quad `q` where `v0..v3` are at `2*q + 0..3`.
  - `BuildTriangleFanIndices`: for `vertex_count >= 3`, `tri_count = vertex_count - 2`, emit `3 * tri_count` `uint32_t` indices `(v(0), v(t+1), v(t+2))`.
  - `BuildLineLoopIndices`: for `vertex_count >= 2`, emit `2 * vertex_count` `uint32_t` indices `(v(i), v((i+1) % vertex_count))`.

- [ ] **Step 2: Wire emulated primitive types into `DrawEncode` (`ps4_gnm_draw.mm:11591-11608`)**
  Update the `if (rs.raster.needs_emulation)` branch in `DrawEncode` so `PrimitiveType::QuadList`, `PrimitiveType::QuadStrip`, `PrimitiveType::TriangleFan`, `PrimitiveType::Polygon`, and `PrimitiveType::LineLoop` build an emulated index buffer and dispatch `drawIndexedPrimitives:` with `MTLPrimitiveTypeTriangle` (or `MTLPrimitiveTypeLine` for `LineLoop`).

---

### Task 2: Support Physical Gamepad Touchpad Press & Touch Coordinates in `ps4_pad.m`

**Files:**
- Modify: `pkg/runtime/modules/libScePad/ps4_pad.h`
- Modify: `pkg/runtime/modules/libScePad/ps4_pad.m:933-1015`
- Modify: `tests/host/pad_test.m`

- [ ] **Step 1: Add testable touchpad extraction & fallback button mapping in `ps4_pad.m`**
  - In `ps4_pad.m`:
    - Query `gp` (`GCExtendedGamepad`) and `controller.physicalInputProfile` for `touchpadButton` (`isPressed`), `touchpadPrimary` (`xAxis.value`, `yAxis.value`), and `touchpadSecondary` (`xAxis.value`, `yAxis.value`).
    - Keep `gp.buttonMenu.isPressed` mapped to `ORBIS_PAD_BUTTON_OPTIONS`.
    - Map `gp.buttonOptions.isPressed` (Share/Create/View/Back) and `gp.buttonHome.isPressed` to `ORBIS_PAD_BUTTON_TOUCH_PAD` by default (unless `PS4_PAD_SHARE_AS_OPTIONS=1` is set).
    - When `ORBIS_PAD_BUTTON_TOUCH_PAD` is set in `buttons` and `touch.fingers == 0`, populate a default center finger (`touch.fingers = 1`, `x = 960`, `y = 475`, `id = 0`) via `ps4_pad_normalize_touch_for_buttons(&buttons, &touch)`.

- [ ] **Step 2: Add unit test coverage in `tests/host/pad_test.m`**
  - Verify `ps4_pad_normalize_touch_for_buttons` synthesizes a center touch point `(960, 475)` when `ORBIS_PAD_BUTTON_TOUCH_PAD` is pressed with `fingers == 0`, preserves explicit touch coordinates when `fingers > 0`, and converts normalized `[-1..1]` DualSense/DualShock touchpad axes into `1920x950` coordinates.

---

### Task 3: Restore `n <= 4096` Full-Scan Threshold & Add Adaptive Digest Polling Backoff in `ps4_gnm_resources.mm`

**Files:**
- Modify: `pkg/runtime/modules/libSceGnmDriver/ps4_gnm_resources.mm:3295-3305`
- Modify: `pkg/runtime/modules/libSceGnmDriver/ps4_gnm_resources.mm:3660-3670`
- Modify: `tests/host/tex_evict_test.mm`

- [ ] **Step 1: Restore `n <= 4096` full-scan threshold in `ComputeGuestDigestLocked`**
  - Change line 3298 back to `const bool full_scan = (n <= 4096);` so single-level uncompressed textures larger than `4 KiB` use `64` evenly-spaced cache-line (`64-byte`) probes (`4 KiB` total read) instead of scanning up to `8 MiB` per texture per submission.

- [ ] **Step 2: Implement adaptive exponential backoff in `GetTextureImpl`**
  - Add `ComputeTexturePollInterval(bool is_block_or_mip, uint32_t unchanged_streak)`:
    - `is_block_or_mip`: `<4 -> 1`, `<16 -> 64`, `<64 -> 256`, `>=64 -> 1024`.
    - single-level uncompressed: `<8 -> 1`, `<32 -> 16`, `<128 -> 64`, `>=128 -> 256`.

- [ ] **Step 3: Run host tests (`tex_evict_test`, `pad_test`, `go test ./...`)**
  - Verify all host tests and Go tests pass.

---

### Task 4: Rebuild TLOU Binaries & Verify FPS, Aiming Reticle, Touchpad Crafting, and Bloodborne Non-Regression

**Files:**
- Rebuild: `/Users/manjarqo/ps4recomp-work/bb_research/tlou_check/ps4_app`
- Rebuild: `/Users/manjarqo/Library/Application Support/PS4Native/games/CUSA00557/build/ps4_app`

- [ ] **Step 1: Rebuild TLOU runtime & binaries**
  - Run `build_runtime.sh` in `/Users/manjarqo/ps4recomp-work/bb_research/tlou_check` and `/Users/manjarqo/Library/Application Support/PS4Native/games/CUSA00557/build`.

- [ ] **Step 2: Run TLOU `data_ch1` benchmark in unattended desktop mode**
  - Measure average FPS over the 115s benchmark and confirm `>= 83.3 fps` and `0` `QuadStrip` skip messages.

- [ ] **Step 3: Run TLOU weapon aiming (`L2`) & touchpad crafting (`touch`) verification in unattended desktop mode**
  - Using an isolated copy of `SAVEDATA09`, launch TLOU on the desktop in unattended mode (`PS4_NO_DIALOGS=1 PS4_RECOMP_HEADLESS=1`), inject `l2` via `PS4_PAD_CTL` to verify the aiming reticle on screen, and inject `touch` via `PS4_PAD_CTL` to verify Joel's crafting/backpack screen opens.

- [ ] **Step 4: Verify Bloodborne (`CUSA03173`) non-regression**
  - Rebuild Bloodborne runtime and verify `40+ fps` in-game 3D rendering in unattended desktop mode.
