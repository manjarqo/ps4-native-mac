# Colour measurement for TLOU

Goal: compare what the player sees in the recompiled game with the original PS4 game, as numbers.

The images are not in the repository: the reference frames come from a recording of the PS4 game
and the game captures from your own dump, so both are game material. The pair files in
`tools/color_ref/` name them relative to a local directory of your choice (`<color_ref>` below),
which you fill yourself as described under "Pairs".

## Why window captures

The internal screenshots (`PS4_SCREENSHOT_DIR`) are taken before the output gamma pass, the
CAMetalLayer colour space and the compositor. `PS4_SCREENSHOT_STAGE=output` saves them after the
gamma pass instead (still without the HUD, the layer's colour matching and the compositor); the
default is `render`. The reference is a screen recording of a video, so it
went through the macOS display path. `tools/tlou_color_run.sh` therefore captures the game window
with `screencapture -x -o -l<windowid>`, which includes the gamma pass and the compositor, and
converts it to sRGB (`sips --matchTo`, 960 px wide). The window id comes from the runtime line
`[metal-screen] window id=<n>` on stderr. The capture includes the title bar (about 5 % at the
top) and the FPS overlay at the top left, so the regions of ours leave out the top 12 %.

## Reference frames: the ffmpeg filter

Reference used here: a macOS screen recording of a YouTube video of the PS4 game (h264
bt709 tv range). QuickTime shows bt709 video with a pure gamma of about 1.961, not with the sRGB
curve, so plain YUV to RGB conversion is about 5 L* too dark in the mid tones. The filter that
matches what macOS shows: scale to 960 px, bt709 full
range RGB, then per channel F = maxval * srgb_encode(pow(val/maxval, 1.961)). Literally (one line,
as passed to `-vf`):

```
scale=960:-2:flags=bicubic:out_color_matrix=bt709:out_range=full,format=rgb24,lutrgb=r='maxval*if(lt(pow(val/maxval\,1.961)\,0.0031308)\,12.92*pow(val/maxval\,1.961)\,1.055*pow(pow(val/maxval\,1.961)\,1/2.4)-0.055)':g='maxval*if(lt(pow(val/maxval\,1.961)\,0.0031308)\,12.92*pow(val/maxval\,1.961)\,1.055*pow(pow(val/maxval\,1.961)\,1/2.4)-0.055)':b='maxval*if(lt(pow(val/maxval\,1.961)\,0.0031308)\,12.92*pow(val/maxval\,1.961)\,1.055*pow(pow(val/maxval\,1.961)\,1/2.4)-0.055)'
```

Check (frame at 12 s and 4 s, QuickTime window captured and converted like the game captures vs
this filter, whole frame): without the lut |dL50| = 5.0; with it L50 32.9 vs 33.9 (1.0),
L5 1.4 vs 2.8, L95 73.0 vs 73.3, C 12.2 vs 12.1; at 4 s L50 0.1 vs 1.4, C 2.7 vs 2.8.
Extract frames with `ffmpeg -ss T -i VIDEO -frames:v 1 -vf "<filter>" out.png`
(`fps=2,<filter>` for a sequence).

## Running

    tools/tlou_color_run.sh <outdir> <seconds> <padctl|-> [ENV=VAL...]

`BUILD` names the build directory with `ps4_app` (default `~/ps4recomp-work/tlou_build_colors`).
Windowed, time-bounded (perl alarm, exit 142), data dir `$PS4RECOMP_DATA_DIR`, by default
`~/ps4recomp-work/data_color` (never the
live one: a `PS4RECOMP_DATA_DIR` whose resolved path contains "Application Support", in any case,
is refused, and it cannot be set through the `ENV=VAL` arguments; every extra argument must be one). Autopress Cross runs until `AUTOPRESS_UNTIL` (default 60000 ms), which loads the save
at "Beyond the Wall"; gameplay is on screen at 60 s. `CAP_FROM` (default 60) is the delay before the
first capture and the moment the pad file is appended, `CAP_EVERY` (default 5) the seconds between
captures (a capture takes about 1.8 s). The pad file is appended to the control file when the
captures begin, but the game applies it only some seconds later (about 20 s observed), so take the
LAST captures of a run of 75-80 s. The script stops the game when WindowServer exceeds 2 GB.
Values used here: CAP_FROM=60, AUTOPRESS_UNTIL=60000, CAP_EVERY=1, 78 s.

## Pairs

`tools/color_ref/tlou_beyond_wall.json` lists the pairs and is the authoritative set; paths are
relative to `--root <color_ref>` (`ours/<pair>.png`, `video/<pair>.png`).
`tools/color_ref/tlou_render_pairs.json` is the Task 4 calibration set (internal screenshots, ours
region `[0,0,1,1]`); it is kept as it was then (its interior pair still uses `video/interior.png`
and it has no `bluecloth` / `plank`) and is not updated with the pairs below.

| pair | ours (pad file) | reference frame |
| --- | --- | --- |
| interior | save view, no input (`interior.padctl`) | video 0.0 s (all_001, the save frame) |
| courtyard | camera turned right 250 ms (`courtyard.padctl`) | video 15 s (all_031) |
| joel_back | camera turned right 500 ms (`joel_back.padctl`) | video 11 s (all_023) |
| bluecloth | walk to the blue-cloth climb wall (`bluecloth.padctl`), capture about 31 s after the first | video 6.0 s (all_013) |
| plank | the bluecloth route, the climb, then the plank courtyard (`plank.padctl`), last capture of a 180 s run | video 11.5 s (all_024) |

`bluecloth` and `plank` show the same places as the video (the interior pair is the save point;
`courtyard` and `joel_back` are not location-matched). Their routes were driven with `CAP_EVERY=2`
and a 180 s run; the pad file is applied about 20 s after `CAP_FROM`, and the route is
deterministic enough to repeat (Joel's position varies by a step, Ellie's by more).

Regions: `frame` on ours `[0,0.12,1,0.76]` (without title bar and overlay), on the reference
`[0,0.02,1,0.84]` (without YouTube controls and subtitles); `hair` (limits `detail`) on `joel_back`:
ours `[0.406,0.452,0.078,0.133]`, reference `[0.328,0.443,0.042,0.083]`. No skin region: the neck
is not visible in our view.

Add a pair: write a `.padctl` (`p <hexmask> <dur_ms> <lx> <ly> <rx> <ry>`, `w <ms>`, `shot`),
run the script, copy the last `win_*.png` to `<color_ref>/ours/<pair>.png`, extract the reference
frame with the filter above to `<color_ref>/video/<pair>.png`, add an entry with regions read off
the images (fraction = pixel / image size).

Compare: `python3 tools/color_compare.py tools/color_ref/tlou_beyond_wall.json --root
<color_ref> [--ours-dir DIR] [--json OUT]` (exit 0 within limits, 1 over, 2 bad
input). Limits are in `color_compare.py` (`frame`: dL50 5, dL5 8, dL95 8, relative dC 15 %;
`detail`: dL50 10, dh 20 degrees).

## Permission

The capture needs Screen Recording permission for the terminal or app that runs the script. With
no permission the captures show only the wallpaper or are black; grant it in System Settings,
Privacy & Security, Screen Recording.

## PS4_COLORSPACE

The window layer is tagged as sRGB by default. The tag declares what the frame holds (sRGB
values), so macOS colour-matches it to the panel (P3 on Mac displays). `PS4_COLORSPACE=native`
leaves the layer untagged (the old behaviour: the values go to the panel without that matching).
The on-screen effect of the tag (less saturated colour on a wide-gamut panel when tagged) is
expected, not measured: window captures do not show it. `screencapture` of the window gave the
same pixels with both settings (Task 6), so these captures cannot compare the two; that needs a
measurement of the panel itself.
