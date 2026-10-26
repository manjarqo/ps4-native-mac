# The Last of Us: colour fidelity against a PS4 reference

Date: 2026-10-25. Status: approved by the owner (design sections 1–5).

## Goal

The Last of Us Remastered (CUSA00557) runs at good frame rates on the Metal GNM renderer, but its colours differ
from a real PS4. The owner reports two problems while playing:

- **Characters.** Joel's hair is light blond, nearly yellow; on PS4 it is dark brown. Skin is also off.
- **Brightness.** The image is too bright and washed out.

The goal is a picture that matches the PS4 within the tolerances of section 1 on the "Beyond the Wall" ("За стеной")
route, at the game's default brightness, with no frame-rate loss.

Out of scope: Uncharted 4 colour work, HDR/EDR output, the 10-bit scanout path (it stays 8-bit), and any colour
"grading to taste" at present time.

## Reference and route

- **Reference.** `<ps4-reference.mov>` is a macOS screen recording of a YouTube video of the
  original game on PS4: 20.3 s, 3020×1702, 120 fps, h264 yuv420p, bt709, with the YouTube player overlay. It went
  through YouTube compression, the browser and the macOS display pipeline. It is good for image statistics, not for
  pixel comparison.
- **Route.** The owner's live save SAVEDATA06 ("За стеной", newest, 51 min). Test runs use a copy in
  `~/ps4recomp-work/data_color` (`PS4RECOMP_DATA_DIR=~/ps4recomp-work/data_color`,
  `PS4_SAVEDATA_DIALOG_PICK=SAVEDATA06`); the live saves are never touched.
- **Game setting.** The owner never changed the in-game brightness. At that default the game calls
  `sceVideoOutAdjustColor` with gamma 0.800 on all three channels (seen in the run log).

## Starting point

The build the owner plays (`~/ps4recomp-work/tlou_build`) is made from branch `metal4-backend`
(worktree `PS4Recomp-metal4`), which contains main and the frame capture/replay tools. This work lives on branch
`tlou-colors` (worktree `~/ps4recomp-work/PS4Recomp-colors`), cut from `metal4-backend` at dd4437b.

A first comparison (our internal screenshot at the save point against video frames of the same area) shows:

1. Joel's hair is blond in our frame and dark brown in the reference. This is one material, not the whole frame.
2. Our frame is more saturated and warmer; foliage is a neon yellow-green, while the reference is muted and greyish.
   The owner did not list this, so it is a secondary item (section 5).
3. The internal screenshot is taken **before** the output gamma pass, so it does not show what the owner sees.

What the code shows:

- **Output gamma is inverted.** `gamma_fs` in `pkg/runtime/modules/libSceVideoOut/ps4_metal_screen.m` decodes the
  sRGB frame to linear and re-encodes it with `k = 1 / (3.4 - gamma)`. Its comment says "gamma > 1 brightens", but
  the formula does the opposite: gamma 0.8 gives k = 1/2.6, which brightens (linear 0.2 → 0.54 instead of 0.48 at
  sRGB). So the game's default brightness produces a washed-out image, which matches the owner's report.
- **The window has no colour space.** `g_metalLayer` is `BGRA8Unorm` and its `colorspace` is never set, so macOS does
  not colour-match the frame. sRGB values go to the P3 panel unmapped, which oversaturates on screen. The internal
  screenshot cannot show this (it is written as DeviceRGB).
- **Format paths to audit for the hair/skin bug** (`pkg/runtime/modules/libSceGnmDriver/ps4_gnm_resources.mm`):
  2_10_10_10 SNORM/SINT mapped to UNORM/UINT with `exact=false`; BC4/BC5/BC6 sRGB remapped to UNORM; the T#
  DST_SEL swizzle path (`RemapSwizzle`, `ComposeViewSwizzle`); the sRGB/UNORM view chosen when a render target is
  sampled; FORCE_DEGAMMA in `resource_patching_pass.cpp`; the export conversion in
  `3rdparty/gcn-recompiler/src/shader_recompiler/frontend/translate/export.cpp`. These are candidates, not findings.

## Design

The work goes layer by layer, from the output inwards. The output errors are global and cheap, and they hide
everything else, so they go first. Every step is checked against the reference with the same measurement.

### 1. Measurement: see what the player sees

- **Primary measurement.** Our game runs **windowed** (≤720p window, time-bounded, WindowServer watched), and the
  window is captured with the system tool (`screencapture -x -l <windowID>`). The capture then passes through the same
  path as the reference: gamma pass → CAMetalLayer → colour space → macOS compositor. Output gamma and colour-space
  errors show up in it.
- **Internal screenshot.** `PS4_SCREENSHOT_DIR` stays a diagnostic of the rendered values. A new
  `PS4_SCREENSHOT_STAGE=output` saves the frame after the gamma pass instead of before it (default stays `render`), so
  render errors and output errors can be told apart.
- **Reference frames.** 3–4 pairs with a similar view, chosen once and stored with their crops: a dark interior, the
  courtyard with ivy and planks, Joel close from behind (hair and skin). Video frames are extracted with ffmpeg and
  cropped to exclude the YouTube overlay and subtitles.
- **`tools/color_compare.py`** (standard library only, like `refcompare.py`, whose PNG reader it reuses). Per image
  and per named region (whole frame, a 4×4 grid, and hand-marked regions such as "hair") it computes CIE L\*
  percentiles (p5, p50, p95), mean chroma C\* and mean hue angle h. It prints our value, the reference value and the
  difference, and exits 1 when a limit is exceeded.
- **Tolerances**, with room for YouTube compression and a not-identical camera:
  - |ΔL\*| of p50 ≤ 5 and of p5/p95 ≤ 8 over the whole frame;
  - relative ΔC\* ≤ 15% over the whole frame;
  - in the hair region |Δh| ≤ 20° and |ΔL\*| ≤ 10.

### 2. Output gamma (`sceVideoOutAdjustColor`)

- Fix the direction of the exponent so that gamma < 1 darkens and gamma > 1 brightens, with gamma 1.0 the identity.
  The candidate is `k = 1 / (1.4 + gamma)` (gamma 1.0 → 1/2.4, the sRGB exponent).
- Calibrate the exact form against the reference: render the same captured frame through each candidate and take the
  one whose L\* percentiles are closest to the reference. Record the result and the reason in the code comment.
- Keep the identity fast path at gamma 1.0. The in-game brightness slider must move the image the right way.
- Tests: the shader formula, extracted as a pure function in a host test, is the identity at 1.0 and monotonic in
  gamma, and gamma 0.8 darkens.

### 3. Window colour space

- Set `g_metalLayer.colorspace` to sRGB (`kCGColorSpaceSRGB`), so macOS maps the frame to the panel's gamut.
- `PS4_COLORSPACE=native` restores the old behaviour, for comparison.
- Check the frame-rate cost with an A/B by encoder ms and fps under the noise rules (alternate builds, log load
  average, discard runs with load > 15). The expected cost is zero; any measurable loss is reported to the owner.

### 4. Hair and skin

- Capture a frame with Joel close up (`PS4_GNM_SYNC_ENCODE=1 PS4_GNM_CAPTURE_FRAME=<n>`), open it in
  `gnm_capture_view.py`, and find the draws that write Joel's hair and skin into the g-buffer.
- For those draws compare each T# (data format, number format, DST_SEL, sRGB), the view the renderer created, and the
  shader export with what the descriptors say. Start with the candidates listed above.
- Prove the cause with a replay of the single pass with the fix before changing the renderer.
- Use REA only if the capture cannot explain the input data, as agreed (no broad RE of the binary).
- Done when Joel's hair is dark brown and the hair region meets the section 1 limits, and skin shows no yellow or grey
  shift against the reference. Other characters (Ellie, Tess) are checked on the same frames.

### 5. Remaining grade

- After sections 2–4 measure saturation and hue again over the whole frame.
- If the relative ΔC\* is still above 15%, a separate task investigates the tonemap/colour-grading pass through the
  capture (the LUT texture's format and view, and the pass's export). Otherwise this section closes with the numbers.

## Verification

- All reference pairs are within the section 1 limits, measured with system window captures.
- Frame rate and encoder ms on the TLOU route are no worse than `metal4-backend` within noise.
- Uncharted 4 title screen: one control screenshot before and after, with no visible regression (U4 also calls
  AdjustColor, so the gamma fix affects it).
- Existing tests (`tools/tests`, the host tests, `gnm_metal_test`) pass.

## Constraints

- Test runs set `PS4RECOMP_DATA_DIR` to the test copy, never the live saves.
- One game at a time, ≤720p window, every run time-bounded, memory watched with `~/ps4recomp-work/tools/memwatch.sh`.
- Installing into `eboot.app` is atomic (temporary file, then `mv`), because the owner may be playing.
- Local commits only. No push, and no merge into `metal4-backend` or main without the owner.
