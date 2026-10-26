# TLOU colour fidelity Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make The Last of Us Remastered match a PS4 reference video in brightness, contrast and character colours on the "Beyond the Wall" route, at the game's default brightness, with no frame-rate loss.

**Architecture:** Measure first, with a statistics tool and system window captures that go through the same macOS display path as the reference. Then fix the output layer: the inverted `sceVideoOutAdjustColor` gamma, and the missing colour space on the window's CAMetalLayer. Then localise the hair/skin bug with a frame capture and pass replay, and finally re-measure the remaining grade.

**Tech Stack:** Objective-C/Metal runtime (`pkg/runtime/modules/libSceVideoOut`, `libSceGnmDriver`), the GCN shader recompiler (`3rdparty/gcn-recompiler`), Python 3 standard library tools (`tools/`), host C tests (`tests/host/run_host_tests.sh`), the macOS tools `screencapture`, `sips` and `ffmpeg`.

**Spec:** `docs/superpowers/specs/2026-10-25-tlou-colors-design.md`

## Global Constraints

- Every game run sets `PS4RECOMP_DATA_DIR=$HOME/ps4recomp-work/data_color` (a copy of the live saves) and `PS4_SAVEDATA_DIALOG_PICK=SAVEDATA06`. The live saves in `~/Library/Application Support/PS4Recomp` are never written.
- One game at a time. Every run is time-bounded (perl `alarm`) and windowed runs watch WindowServer. Kill the game if WindowServer RSS climbs past 2 GB. Run `~/ps4recomp-work/tools/memwatch.sh` during runs.
- `~/ps4recomp-work` is an APFS image: check `mount | grep ps4recomp-work` before building.
- Use absolute paths; every `cd` is `cd <dir> || exit 1`. Never `rm -rf` after a `cd` that was not checked. Never `git stash` in a worktree with symlinked `3rdparty`.
- Perf A/B: alternate builds, log `uptime` load average, discard runs with load > 15, and trust encoder/CP ms over fps.
- Repository files, comments and commit messages are in English. Reports to the owner are in Russian.
- No temporary hacks, no colour "grading to taste" at present time, and no stubs (AGENTS.md).
- Local commits on branch `tlou-colors` only. No push, and no merge into `metal4-backend` or main without the owner. Install into `eboot.app` only when the owner asks, and then atomically (temporary file, then `mv`).
- Colour tolerances (spec, section 1): whole frame |ΔL\* p50| ≤ 5, |ΔL\* p5| and |ΔL\* p95| ≤ 8, relative ΔC\* ≤ 15%; hair region |Δh| ≤ 20° and |ΔL\* p50| ≤ 10.
- Commit messages end with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.

## File Structure

| File | Responsibility |
|---|---|
| `tools/color_compare.py` (new) | CIE L\*C\*h statistics per region, and comparison of frame pairs against the tolerances; also a minimal PNG writer for other tools |
| `tools/tests/test_color_compare.py` (new) | tests for it |
| `tools/gamma_candidates.py` (new) | applies candidate output-gamma formulas to render-stage screenshots (calibration, Task 4) |
| `tools/tests/test_gamma_candidates.py` (new) | tests for it |
| `tools/tlou_color_run.sh` (new) | one windowed, time-bounded TLOU run from the colour build, with pad control and system window captures |
| `tools/color_ref/tlou_beyond_wall.json` (new) | the reference pairs: file names, regions, limits |
| `tools/color_ref/*.padctl` (new) | pad command files that bring the camera to each pair's view |
| `pkg/runtime/modules/libSceVideoOut/ps4_output_gamma.h` (new) | the output-gamma formula as plain C, shared by the presenter and the host test |
| `tests/host/output_gamma_test.c` (new) | host test of the formula |
| `tests/host/run_host_tests.sh` | runs the new test |
| `pkg/runtime/modules/libSceVideoOut/ps4_metal_screen.m` | window id log line, `PS4_SCREENSHOT_STAGE`, gamma exponent from the header, layer colour space |
| `docs/color-measurement.md` (new) | how to measure colours against a reference |
| Task 7 files | found by the capture; the candidates are in `ps4_gnm_resources.mm`, `resource_patching_pass.cpp` and `export.cpp` |

The ledger is `.superpowers/sdd/2026-10-25-tlou-colors/progress.md`, which is git-ignored like earlier SDD workspaces. Each task appends its numbers and decisions to it.

Reference video frames, window captures and GNM captures live outside the repository, in `~/ps4recomp-work/color_ref/` and `~/ps4recomp-work/cap_colors/`.

---

### Task 0: Worktree build setup

The worktree `~/ps4recomp-work/PS4Recomp-colors` (branch `tlou-colors` at dd4437b plus the spec commit) exists, but its `3rdparty` submodules are empty and nothing is built.

**Files:** none in git. This task creates local links and builds only.

- [ ] **Step 1: Link the submodules like the metal4 worktree does**

```bash
cd ~/ps4recomp-work/PS4Recomp-colors/3rdparty || exit 1
for d in libatrac9 minimp3 spirv-cross; do
  [ -d "$d" ] && [ -z "$(ls -A "$d")" ] && rmdir "$d"
  [ -e "$d" ] || ln -s "../../PS4Recomp/3rdparty/$d" "$d"
done
ls -la ~/ps4recomp-work/PS4Recomp-colors/3rdparty
```

Expected: three symlinks to `../../PS4Recomp/3rdparty/...`. `gcn-recompiler` stays a directory, because it is tracked in this branch.

- [ ] **Step 2: Build the shader recompiler**

```bash
cmake -S ~/ps4recomp-work/PS4Recomp-colors/3rdparty/gcn-recompiler \
      -B ~/ps4recomp-work/gcn-build-colors -G Ninja -DCMAKE_BUILD_TYPE=Release
ninja -C ~/ps4recomp-work/gcn-build-colors
cp ~/ps4recomp-work/gcn-build-colors/libgcn_recompiler.a \
   ~/ps4recomp-work/PS4Recomp-colors/3rdparty/gcn-recompiler/
```

Compare the CMake flags with `~/ps4recomp-work/gcn-build-metal4/CMakeCache.txt` (`grep CMAKE_BUILD_TYPE`) and use the same build type. If `libgcn_recompiler.a` is written to a subdirectory, take it from there (`find ~/ps4recomp-work/gcn-build-colors -name libgcn_recompiler.a`).

- [ ] **Step 3: Build the recompiler CLI and the game**

```bash
cd ~/ps4recomp-work/PS4Recomp-colors || exit 1
go build -o ps4-recomp ./cmd/ps4-recomp
G="<your-TLOU-dump>/CUSA00557"
./ps4-recomp "$G/eboot.bin" --app-dir "$G" -o ~/ps4recomp-work/tlou_build_colors -c \
  > ~/ps4recomp-work/build_colors.log 2>&1; echo "rc=$?"; tail -3 ~/ps4recomp-work/build_colors.log
```

Expected: `rc=0` and `~/ps4recomp-work/tlou_build_colors/ps4_app` exists. If the code generation step is slow, it is still the supported path. Do not copy objects from `tlou_build`.

- [ ] **Step 4: Run the existing tests once, as the baseline**

```bash
~/ps4recomp-work/PS4Recomp-colors/tests/host/run_host_tests.sh > ~/ps4recomp-work/hosttests_colors_base.log 2>&1; echo "rc=$?"
cd ~/ps4recomp-work/PS4Recomp-colors/tools || exit 1
for t in tests/test_*.py; do python3 "$t" > /dev/null 2>&1 || echo "FAIL $t"; done
```

Expected: `rc=0` and no `FAIL` lines. Write any pre-existing failure into the ledger as the baseline, and do not fix it in this plan.

---

### Task 1: `color_compare.py` — L\*C\*h statistics and pair comparison

**Files:**
- Create: `tools/color_compare.py`
- Test: `tools/tests/test_color_compare.py`

**Interfaces:**
- Consumes: `refcompare.read_png(path) -> (w, h, rows)`, where rows are `bytes` with 3 bytes of RGB per pixel.
- Produces:
  - `srgb_to_lab(r, g, b) -> (L, a, b)` for 8-bit sRGB values, D65;
  - `region_stats(img, rect, step=2) -> dict`, where `rect` is `(fx, fy, fw, fh)` as fractions of the image; the dict has keys `L5`, `L50`, `L95`, `C`, `h`, `n`;
  - `compare_stats(ours, ref, limits) -> list[str]`, which returns the violations, empty when within limits;
  - `LIMITS = {"frame": {...}, "detail": {...}}`;
  - `write_png(path, w, h, rows)`, which writes an 8-bit RGB PNG;
  - CLI `color_compare.py <pairs.json> [--root DIR] [--ours-dir DIR] [--json OUT]`, exit 0 within limits, 1 over a limit, 2 on bad input.

Pairs file schema, used by Tasks 2, 4, 5, 6 and 7:

```json
{
  "pairs": [
    {
      "name": "courtyard",
      "ours": "ours/courtyard.png",
      "ref": "video/courtyard.png",
      "regions": {
        "frame": {"limits": "frame",  "ours": [0, 0, 1, 0.86], "ref": [0, 0, 1, 0.86]},
        "hair":  {"limits": "detail", "ours": [0.40, 0.38, 0.08, 0.10], "ref": [0.39, 0.42, 0.07, 0.09]}
      }
    }
  ]
}
```

Paths are relative to `--root`, which defaults to the directory of the JSON file. `--ours-dir` replaces the directory of every `ours` path, keeping its basename; Task 4 uses it to compare candidate outputs.

- [ ] **Step 1: Write the failing tests**

```python
#!/usr/bin/env python3
"""Tests for tools/color_compare.py with PNGs written here."""
import json
import os
import struct
import subprocess
import sys
import tempfile
import unittest
import zlib

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, ".."))
import color_compare  # noqa: E402

TOOL = os.path.join(HERE, "..", "color_compare.py")


def write_rgb_png(path, w, h, pixel):
    raw = bytearray()
    for y in range(h):
        raw.append(0)
        for x in range(w):
            raw.extend(pixel(x, y))
    def chunk(t, body):
        return struct.pack(">I", len(body)) + t + body + struct.pack(">I", zlib.crc32(t + body) & 0xFFFFFFFF)
    with open(path, "wb") as f:
        f.write(b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0))
                + chunk(b"IDAT", zlib.compress(bytes(raw))) + chunk(b"IEND", b""))


class LabTest(unittest.TestCase):
    def test_reference_points(self):
        L, a, b = color_compare.srgb_to_lab(255, 255, 255)
        self.assertAlmostEqual(L, 100.0, delta=0.05)
        self.assertAlmostEqual(a, 0.0, delta=0.05)
        self.assertAlmostEqual(b, 0.0, delta=0.05)
        self.assertAlmostEqual(color_compare.srgb_to_lab(0, 0, 0)[0], 0.0, delta=0.01)
        self.assertAlmostEqual(color_compare.srgb_to_lab(128, 128, 128)[0], 53.59, delta=0.1)
        L, a, b = color_compare.srgb_to_lab(255, 0, 0)  # sRGB red: L 53.24, a 80.09, b 67.20
        self.assertAlmostEqual(L, 53.24, delta=0.1)
        self.assertAlmostEqual(a, 80.09, delta=0.2)
        self.assertAlmostEqual(b, 67.20, delta=0.2)


class StatsTest(unittest.TestCase):
    def test_grey_and_region(self):
        # left half black, right half grey 128
        img = (8, 4, [bytes([0, 0, 0] * 4 + [128, 128, 128] * 4)] * 4)
        s = color_compare.region_stats(img, (0.5, 0, 0.5, 1), step=1)
        self.assertEqual(s["n"], 16)
        self.assertAlmostEqual(s["L50"], 53.59, delta=0.1)
        self.assertAlmostEqual(s["C"], 0.0, delta=0.01)
        whole = color_compare.region_stats(img, (0, 0, 1, 1), step=1)
        self.assertAlmostEqual(whole["L5"], 0.0, delta=0.01)
        self.assertAlmostEqual(whole["L95"], 53.59, delta=0.1)

    def test_hue_of_red_and_blue(self):
        red = (2, 2, [bytes([200, 40, 40] * 2)] * 2)
        blue = (2, 2, [bytes([40, 40, 200] * 2)] * 2)
        hr = color_compare.region_stats(red, (0, 0, 1, 1), step=1)["h"]
        hb = color_compare.region_stats(blue, (0, 0, 1, 1), step=1)["h"]
        self.assertTrue(hr < 60 or hr > 330, hr)
        self.assertTrue(250 < hb < 320, hb)


class CompareTest(unittest.TestCase):
    def stats(self, L50, C=20.0, h=60.0, L5=None, L95=None):
        return {"L5": L5 if L5 is not None else L50 - 20, "L50": L50, "L95": L95 if L95 is not None else L50 + 20,
                "C": C, "h": h, "n": 100}

    def test_within_and_over(self):
        lim = color_compare.LIMITS
        self.assertEqual(color_compare.compare_stats(self.stats(50), self.stats(53), lim["frame"]), [])
        self.assertTrue(color_compare.compare_stats(self.stats(50), self.stats(56), lim["frame"]))
        self.assertTrue(color_compare.compare_stats(self.stats(50, C=30), self.stats(50, C=20), lim["frame"]))
        # hue wraps around 0/360
        self.assertEqual(color_compare.compare_stats(self.stats(30, h=355), self.stats(30, h=5), lim["detail"]), [])
        self.assertTrue(color_compare.compare_stats(self.stats(30, h=40), self.stats(30, h=5), lim["detail"]))


class CliTest(unittest.TestCase):
    def test_pairs_exit_codes(self):
        with tempfile.TemporaryDirectory() as d:
            write_rgb_png(os.path.join(d, "ref.png"), 16, 16, lambda x, y: (120, 100, 80))
            write_rgb_png(os.path.join(d, "same.png"), 16, 16, lambda x, y: (121, 100, 80))
            write_rgb_png(os.path.join(d, "bright.png"), 16, 16, lambda x, y: (200, 180, 160))
            def run(ours):
                cfg = {"pairs": [{"name": "p", "ours": ours, "ref": "ref.png",
                                  "regions": {"frame": {"limits": "frame", "ours": [0, 0, 1, 1], "ref": [0, 0, 1, 1]}}}]}
                p = os.path.join(d, "pairs.json")
                with open(p, "w") as f:
                    json.dump(cfg, f)
                return subprocess.run([sys.executable, TOOL, p, "--json", os.path.join(d, "out.json")],
                                      capture_output=True, text=True)
            self.assertEqual(run("same.png").returncode, 0)
            r = run("bright.png")
            self.assertEqual(r.returncode, 1)
            self.assertIn("p/frame", r.stdout)
            with open(os.path.join(d, "out.json")) as f:
                self.assertFalse(json.load(f)["ok"])

    def test_png_roundtrip(self):
        with tempfile.TemporaryDirectory() as d:
            p = os.path.join(d, "w.png")
            rows = [bytes([0, y * 10, 7]) for y in range(3)]
            color_compare.write_png(p, 1, 3, rows)
            w, h, back = color_compare.read_png(p)
            self.assertEqual((w, h), (1, 3))
            self.assertEqual([bytes(r) for r in back], rows)


if __name__ == "__main__":
    unittest.main()
```

- [ ] **Step 2: Run them and see them fail**

Run: `cd ~/ps4recomp-work/PS4Recomp-colors/tools || exit 1; python3 tests/test_color_compare.py`
Expected: `ModuleNotFoundError: No module named 'color_compare'`.

- [ ] **Step 3: Write the tool**

```python
#!/usr/bin/env python3
"""Compare rendered frames with reference frames by CIE L*C*h statistics per region.

usage: color_compare.py <pairs.json> [--root DIR] [--ours-dir DIR] [--json OUT]

For every pair and every named region of it, the 8-bit sRGB pixels are converted to CIE L*a*b*
(D65) and summarised: L* percentiles p5, p50 and p95, mean chroma C* and the chroma-weighted mean
hue angle h (degrees). Each region is compared against the limit set it names ("frame" or
"detail", see LIMITS). The reference is a compressed video, so the limits allow for that; a
pixel match is not expected.

Exit status: 0 within the limits, 1 when a limit is exceeded, 2 on bad input.
Only the Python standard library is used.
"""
import argparse
import json
import math
import os
import struct
import sys
import zlib

from refcompare import read_png

LIMITS = {
    # whole frame: exposure and contrast (L* percentiles) and saturation (relative chroma)
    "frame": {"L50": 5.0, "L5": 8.0, "L95": 8.0, "C_rel": 0.15},
    # a small region such as hair: tone and hue
    "detail": {"L50": 10.0, "h": 20.0},
}

_LIN = [(v / 255.0) / 12.92 if v <= 10 else (((v / 255.0) + 0.055) / 1.055) ** 2.4 for v in range(256)]
_XN, _ZN = 0.95047, 1.08883


def _f(t):
    return t ** (1.0 / 3.0) if t > 216.0 / 24389.0 else (24389.0 / 27.0 * t + 16.0) / 116.0


def srgb_to_lab(r, g, b):
    """CIE L*a*b* (D65) of an 8-bit sRGB colour."""
    R, G, B = _LIN[r], _LIN[g], _LIN[b]
    x = (0.4124564 * R + 0.3575761 * G + 0.1804375 * B) / _XN
    y = 0.2126729 * R + 0.7151522 * G + 0.0721750 * B
    z = (0.0193339 * R + 0.1191920 * G + 0.9503041 * B) / _ZN
    fx, fy, fz = _f(x), _f(y), _f(z)
    return 116.0 * fy - 16.0, 500.0 * (fx - fy), 200.0 * (fy - fz)


def _pct(sorted_vals, p):
    return sorted_vals[int(round(p * (len(sorted_vals) - 1)))]


def region_stats(img, rect, step=2):
    """L* p5/p50/p95, mean C*, mean hue h and pixel count of rect = (fx, fy, fw, fh) in fractions."""
    w, h, rows = img
    fx, fy, fw, fh = rect
    x0, y0 = int(fx * w), int(fy * h)
    x1, y1 = min(w, int(round((fx + fw) * w))), min(h, int(round((fy + fh) * h)))
    if x0 < 0 or y0 < 0 or x1 <= x0 or y1 <= y0:
        raise ValueError("region %r is empty in the %dx%d image" % (rect, w, h))
    cache = {}
    Ls, csum, asum, bsum = [], 0.0, 0.0, 0.0
    for y in range(y0, y1, step):
        row = rows[y]
        for x in range(x0, x1, step):
            key = bytes(row[3 * x:3 * x + 3])
            lab = cache.get(key)
            if lab is None:
                lab = cache[key] = srgb_to_lab(key[0], key[1], key[2])
            Ls.append(lab[0])
            csum += math.hypot(lab[1], lab[2])
            asum += lab[1]
            bsum += lab[2]
    n = len(Ls)
    Ls.sort()
    hue = math.degrees(math.atan2(bsum / n, asum / n)) % 360.0
    return {"L5": _pct(Ls, 0.05), "L50": _pct(Ls, 0.50), "L95": _pct(Ls, 0.95), "C": csum / n, "h": hue, "n": n}


def compare_stats(ours, ref, limits):
    """Violations of `limits` by ours against ref, as readable strings (empty: within limits)."""
    out = []
    for k in ("L5", "L50", "L95"):
        if k in limits and abs(ours[k] - ref[k]) > limits[k]:
            out.append("%s %.1f vs %.1f (limit %.1f)" % (k, ours[k], ref[k], limits[k]))
    if "C_rel" in limits:
        rel = (ours["C"] - ref["C"]) / max(ref["C"], 1.0)
        if abs(rel) > limits["C_rel"]:
            out.append("C %.1f vs %.1f (%+.0f%%, limit %.0f%%)" % (ours["C"], ref["C"], 100 * rel, 100 * limits["C_rel"]))
    if "h" in limits:
        dh = (ours["h"] - ref["h"] + 180.0) % 360.0 - 180.0
        if abs(dh) > limits["h"]:
            out.append("h %.0f vs %.0f (%+.0f deg, limit %.0f)" % (ours["h"], ref["h"], dh, limits["h"]))
    return out


def write_png(path, w, h, rows):
    """Writes an 8-bit RGB PNG; rows are bytes of 3*w values."""
    raw = b"".join(b"\x00" + bytes(r) for r in rows)

    def chunk(t, body):
        return struct.pack(">I", len(body)) + t + body + struct.pack(">I", zlib.crc32(t + body) & 0xFFFFFFFF)

    with open(path, "wb") as f:
        f.write(b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0))
                + chunk(b"IDAT", zlib.compress(raw, 6)) + chunk(b"IEND", b""))


def run_pairs(cfg, root, ours_dir=None):
    result = {"pairs": [], "ok": True}
    for pair in cfg["pairs"]:
        ours_path = pair["ours"]
        if ours_dir:
            ours_path = os.path.join(ours_dir, os.path.basename(ours_path))
        elif not os.path.isabs(ours_path):
            ours_path = os.path.join(root, ours_path)
        ref_path = pair["ref"] if os.path.isabs(pair["ref"]) else os.path.join(root, pair["ref"])
        ours_img, ref_img = read_png(ours_path), read_png(ref_path)
        for rname, reg in pair["regions"].items():
            so = region_stats(ours_img, tuple(reg["ours"]))
            sr = region_stats(ref_img, tuple(reg["ref"]))
            bad = compare_stats(so, sr, LIMITS[reg["limits"]])
            result["ok"] = result["ok"] and not bad
            result["pairs"].append({"pair": pair["name"], "region": rname, "ours": so, "ref": sr, "violations": bad})
    return result


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("pairs")
    ap.add_argument("--root", help="directory the pair paths are relative to (default: the JSON file's)")
    ap.add_argument("--ours-dir", help="take every 'ours' image from this directory (same basename)")
    ap.add_argument("--json", help="also write the result as JSON")
    a = ap.parse_args(argv)
    try:
        with open(a.pairs) as f:
            cfg = json.load(f)
        res = run_pairs(cfg, a.root or os.path.dirname(os.path.abspath(a.pairs)), a.ours_dir)
    except (OSError, ValueError, KeyError) as e:
        print("color_compare: %s" % e, file=sys.stderr)
        return 2
    print("%-24s %6s %6s %6s %6s %6s   (ours / ref)" % ("pair/region", "L5", "L50", "L95", "C", "h"))
    for r in res["pairs"]:
        o, f = r["ours"], r["ref"]
        print("%-24s %s" % ("%s/%s" % (r["pair"], r["region"]),
                            "  ".join("%5.1f/%-5.1f" % (o[k], f[k]) for k in ("L5", "L50", "L95", "C", "h"))))
        for v in r["violations"]:
            print("    OVER: %s" % v)
    print("OK" if res["ok"] else "OVER LIMITS")
    if a.json:
        with open(a.json, "w") as f:
            json.dump(res, f, indent=1)
    return 0 if res["ok"] else 1


if __name__ == "__main__":
    sys.exit(main())
```

- [ ] **Step 4: Run the tests and see them pass**

Run: `cd ~/ps4recomp-work/PS4Recomp-colors/tools || exit 1; python3 tests/test_color_compare.py -v`
Expected: all tests `ok`. If `test_reference_points` is off for red, check `_LIN`. The sRGB threshold 0.04045 × 255 = 10.3, so values ≤ 10 use the linear segment.

- [ ] **Step 5: Commit**

```bash
cd ~/ps4recomp-work/PS4Recomp-colors || exit 1
git add tools/color_compare.py tools/tests/test_color_compare.py
git commit -m "tools: color_compare.py, L*C*h statistics of frames against a reference

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 2: Measuring what the player sees — window id, window captures, reference pairs, baseline

**Files:**
- Modify: `pkg/runtime/modules/libSceVideoOut/ps4_metal_screen.m`, after `[g_window setDelegate:g_screenDelegate];` (about line 173)
- Create: `tools/tlou_color_run.sh`
- Create: `tools/color_ref/tlou_beyond_wall.json`, `tools/color_ref/<pair>.padctl`
- Create: `docs/color-measurement.md`

**Interfaces:**
- Consumes: `color_compare.py` (Task 1).
- Produces:
  - the stderr line `[metal-screen] window id=<n>`;
  - `tools/tlou_color_run.sh <outdir> <seconds> <padctl|-> [ENV=VAL...]`, which writes `<outdir>/run.log`, `<outdir>/win_<t>.png` (sRGB, 960 px wide) and internal screenshots in `<outdir>/shots/`;
  - the pairs file `tools/color_ref/tlou_beyond_wall.json`, whose `ours` entries are `ours/<pair>.png` and whose `ref` entries are `video/<pair>.png`, relative to `--root ~/ps4recomp-work/color_ref`.

- [ ] **Step 1: Log the window id**

In `ps4_metal_screen.m`, right after `[g_window setDelegate:g_screenDelegate];`:

```objc
        // tools/tlou_color_run.sh captures this window with `screencapture -l <id>`
        fprintf(stderr, "[metal-screen] window id=%ld\n", (long)[g_window windowNumber]);
```

If `windowNumber` is 0 at that point (it is valid only once the window exists on screen), move the line to right after the window is first ordered front (`makeKeyAndOrderFront`). Check by running the game in Step 3.

- [ ] **Step 2: Write `tools/tlou_color_run.sh`**

```bash
#!/bin/bash
# One windowed, time-bounded TLOU run of the colour build with system window captures.
# usage: tlou_color_run.sh <outdir> <seconds> <padctl file|-> [ENV=VAL...]
# Window captures go through the macOS display path (gamma pass, CAMetalLayer colour space,
# compositor) like the reference video; they are converted to sRGB and scaled to 960 px wide.
# CAP_EVERY (default 5) seconds between captures, CAP_FROM (default 60) seconds before the first.
set -u
OUT=$1; SECS=$2; PAD=$3; shift 3
BUILD=${BUILD:-$HOME/ps4recomp-work/tlou_build_colors}
SRGB="/System/Library/ColorSync/Profiles/sRGB Profile.icc"
mkdir -p "$OUT/shots" || exit 1
export PS4RECOMP_DATA_DIR=${PS4RECOMP_DATA_DIR:-$HOME/ps4recomp-work/data_color}
case "$PS4RECOMP_DATA_DIR" in *"Application Support"*) echo "refusing the live data dir" >&2; exit 2;; esac
CTL=""
if [ "$PAD" != "-" ]; then CTL="$OUT/pad.ctl"; : > "$CTL"; fi
cd "$BUILD" || exit 1
env PS4_LANG=${PS4_LANG:-ru} PS4_SAVEDATA_DIALOG_PICK=${PICK:-SAVEDATA06} PS4_PAD_AUTOPRESS=4000 \
    PS4_PAD_AUTOPRESS_UNTIL=${AUTOPRESS_UNTIL:-60000} ${CTL:+PS4_PAD_CTL=$CTL} \
    PS4_SCREENSHOT_DIR="$OUT/shots" PS4_SCREENSHOT_EVERY=${EVERY:-600} "$@" \
    perl -e "alarm $SECS; exec @ARGV" ./ps4_app > "$OUT/run.log" 2>&1 &
GAME=$!
WID=""
for _ in $(seq 1 60); do
  WID=$(grep -m1 -oE 'window id=[0-9]+' "$OUT/run.log" 2>/dev/null | cut -d= -f2)
  [ -n "$WID" ] && break
  sleep 1
done
[ -n "$WID" ] || { echo "no window id in run.log" >&2; kill $GAME; exit 1; }
sleep "${CAP_FROM:-60}"
[ -n "$CTL" ] && cat "$PAD" >> "$CTL"
while kill -0 $GAME 2>/dev/null; do
  T=$(date +%s)
  if screencapture -x -o -l"$WID" "$OUT/raw_$T.png" 2>/dev/null; then
    sips --matchTo "$SRGB" -Z 960 -s format png "$OUT/raw_$T.png" --out "$OUT/win_$T.png" > /dev/null && rm -f "$OUT/raw_$T.png"
  fi
  WS=$(ps -axo rss=,comm= | awk '/WindowServer$/ {print int($1/1024)}' | head -1)
  if [ "${WS:-0}" -gt 2048 ]; then echo "WindowServer at ${WS} MB: stopping the game" >&2; kill $GAME; fi
  sleep "${CAP_EVERY:-5}"
done
wait $GAME; echo "exit=$?"
```

Make it executable with `chmod +x`.

- [ ] **Step 3: Check the capture chain end to end**

1. Rebuild the game as in Task 0, Step 3.
2. Run: `~/ps4recomp-work/PS4Recomp-colors/tools/tlou_color_run.sh ~/ps4recomp-work/color_runs/smoke 120 -`
3. Expected: `exit=142` (alarm), several `win_*.png` that show the game, not the desktop or a black frame, and `window id=` in `run.log`.

If the captures show only the wallpaper, the process has no Screen Recording permission. Stop and ask the owner to grant it in System Settings → Privacy & Security → Screen Recording. Do not change security settings yourself.

- [ ] **Step 4: Check that the measurement path does not shift colours**

Open the reference video in QuickTime Player, paused on a frame:

```bash
open -a "QuickTime Player" <ps4-reference.mov>
```

Pause at 12.0 s and capture the window, by its id from `osascript -e 'tell app "QuickTime Player" to id of window 1'`, or interactively with `screencapture -x -o -w`. Convert with the same `sips --matchTo ... -Z 960` call. Extract the same frame with ffmpeg:

```bash
mkdir -p ~/ps4recomp-work/color_ref/video ~/ps4recomp-work/color_ref/check
ffmpeg -v error -ss 12.0 -i <ps4-reference.mov> -frames:v 1 \
  -vf "scale=960:-2:flags=bicubic:out_color_matrix=bt709:out_range=full,format=rgb24" \
  ~/ps4recomp-work/color_ref/check/ffmpeg_12s.png
```

Compare the two with a one-pair JSON in `color_ref/check/` (`frame` region `[0, 0, 1, 0.86]` on both sides).

Expected: whole-frame |ΔL\* p50| ≤ 2 and relative ΔC\* ≤ 5%. If it is larger, the ffmpeg conversion does not match what macOS shows, so fix the ffmpeg filter (try without `out_color_matrix`, or with `-colorspace bt709 -color_trc bt709` input flags) until it matches. Record the final filter in `docs/color-measurement.md`. Every later reference frame is extracted with that filter.

- [ ] **Step 5: Choose the reference pairs and their views**

1. Extract the video at 2 fps with the filter from Step 4 into `color_ref/video/all_%03d.png`.
2. Look at the frames and choose 3–4 views:
   - `courtyard`: planks and ivy in daylight;
   - `interior`: the dark room;
   - `joel_back`: Joel close from behind, hair visible;
   - optionally `climb`: the blue cloth and ivy.
3. Copy each chosen frame to `color_ref/video/<pair>.png`.
4. For each view, write a pad command file `tools/color_ref/<pair>.padctl` that brings Joel's camera from the save point to a similar view. It uses the `PS4_PAD_CTL` syntax from `pkg/runtime/modules/libScePad/ps4_pad.m:298`: `p <hexmask> <dur_ms> <lx> <ly> <rx> <ry>`, `w <ms>`, `shot`. For example, turning the camera right and walking forward for 1.5 s:

```
p 0 700 128 128 230 128
w 500
p 0 1500 128 0 128 128
w 1500
shot
```

5. Iterate with `tlou_color_run.sh ... <pair>.padctl` until the window capture looks like the reference view.
6. Copy the best `win_*.png` to `color_ref/ours/<pair>.png`.

The camera need not match exactly: the statistics compare regions, not pixels.

- [ ] **Step 6: Write the pairs file with regions**

Write `tools/color_ref/tlou_beyond_wall.json` in the Task 1 schema:

- one entry per pair;
- a `frame` region `[0, 0, 1, 0.86]` that leaves out the YouTube controls and subtitles on the reference side, and the same region on ours;
- for `joel_back`, a `hair` region (limits `detail`) drawn tightly around the back of Joel's head on each side;
- for `joel_back`, a `skin` region (limits `detail`) on the neck or arm, if one is visible on both sides.

Find the region fractions by opening the PNGs with `open -a Preview` and reading the pixel positions (Tools → Show Inspector), then dividing by the image size.

- [ ] **Step 7: Baseline measurement**

Run: `python3 ~/ps4recomp-work/PS4Recomp-colors/tools/color_compare.py ~/ps4recomp-work/PS4Recomp-colors/tools/color_ref/tlou_beyond_wall.json --root ~/ps4recomp-work/color_ref --json ~/ps4recomp-work/color_ref/baseline.json`

Expected: exit 1 (OVER LIMITS). From the spec's analysis, expect ours brighter in L\*, higher in C\* and off in hair hue. Copy the printed table into the ledger as the baseline.

If the baseline is **within** limits on L\* (the owner sees a washed-out image), the measurement is wrong. Stop and recheck Step 4.

- [ ] **Step 8: Document and commit**

Write `docs/color-measurement.md`, about one page:

- why the window capture is used instead of the internal screenshot;
- the ffmpeg filter from Step 4;
- the run command, the pairs file and how to add a pair;
- the limits;
- the Screen Recording permission note.

```bash
cd ~/ps4recomp-work/PS4Recomp-colors || exit 1
git add pkg/runtime/modules/libSceVideoOut/ps4_metal_screen.m tools/tlou_color_run.sh tools/color_ref docs/color-measurement.md
git commit -m "Colour measurement: window id log, windowed TLOU run with system captures, reference pairs

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 3: `PS4_SCREENSHOT_STAGE=output` — internal screenshot after the gamma pass

**Files:**
- Modify: `pkg/runtime/modules/libSceVideoOut/ps4_metal_screen.m` (`present_encode`, about lines 870–985)
- Modify: `docs/color-measurement.md` (one paragraph)

**Interfaces:**
- Consumes: `gamma_pipeline()` and `current_gamma()` in `ps4_metal_screen.m`.
- Produces: `PS4_SCREENSHOT_STAGE=render|output` (default `render`). With `output`, the screenshot holds the frame after the output gamma, which Task 4 needs to check its CPU model of the shader. A local `gamma_prm_z` in `present_encode` holds what the gamma shader gets in `prm[2]`; Task 5 changes its value.

- [ ] **Step 1: Read the stage once**

Above `present_encode`:

```objc
// PS4_SCREENSHOT_STAGE=output saves screenshots after the output gamma pass (what the window
// shows, without the HUD and the layer's colour matching); the default "render" saves the frame
// as rendered, before it.
static bool screenshot_after_gamma(void) {
    static int v = -1;
    if (v < 0) {
        const char *s = getenv("PS4_SCREENSHOT_STAGE");
        v = s && strcmp(s, "output") == 0;
    }
    return v == 1;
}
```

- [ ] **Step 2: Render the gamma pass into the shot texture too**

In `present_encode`:

1. Hoist the shader parameter into a local next to `gamma`: `const float gamma_prm_z = gamma;`. Use it for `prm[2]` in the existing drawable pass.
2. Compute `const bool shot_gamma = shot_idx >= 0 && gamma_pso && screenshot_after_gamma();`. This needs `gamma_pso` to be computed before the `shot` texture is created, so move those two lines up.
3. When `shot_gamma` is true, the shot texture must also be a render target: set `td.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;` on its descriptor.
4. After the drawable's gamma encoder, and outside `if (drawable && gamma_pso)`, because a minimised window has no drawable but still takes shots, encode the pass into `shot`:

```objc
        if (shot_gamma) {
            MTLRenderPassDescriptor *sp = [MTLRenderPassDescriptor renderPassDescriptor];
            sp.colorAttachments[0].texture = shot;
            sp.colorAttachments[0].loadAction = MTLLoadActionDontCare;
            sp.colorAttachments[0].storeAction = MTLStoreActionStore;
            id<MTLRenderCommandEncoder> se = [cb renderCommandEncoderWithDescriptor:sp];
            [se setRenderPipelineState:gamma_pso];
            [se setViewport:(MTLViewport){0.0, 0.0, (double)iw, (double)ih, 0.0, 1.0}];
            const float sprm[4] = {0.0f, 0.0f, gamma_prm_z, is_srgb_format(img.pixelFormat) ? 1.0f : 0.0f};
            [se setFragmentBytes:sprm length:sizeof(sprm) atIndex:0];
            [se setFragmentTexture:img atIndex:0];
            [se drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
            [se endEncoding];
        }
```

5. Change the blit line to `if (shot && !shot_gamma) [blit copyFromTexture:img toTexture:shot];`.

- [ ] **Step 3: Verify**

1. Rebuild the game (Task 0, Step 3).
2. Run 120 s twice with `tlou_color_run.sh` and `-`: once with `PS4_SCREENSHOT_STAGE=output`, once without.
3. At the default gamma 0.8 the `output` shots must differ from the `render` shots of the same scene. With today's formula they are brighter: compare with `color_compare.py` on a one-pair JSON (ours = output shot, ref = render shot), where L\* p50 should be higher.

- [ ] **Step 4: Commit**

```bash
cd ~/ps4recomp-work/PS4Recomp-colors || exit 1
git add pkg/runtime/modules/libSceVideoOut/ps4_metal_screen.m docs/color-measurement.md
git commit -m "videoout: PS4_SCREENSHOT_STAGE=output saves screenshots after the output gamma

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 4: Calibrate the output-gamma formula against the reference

**Files:**
- Create: `tools/gamma_candidates.py`
- Test: `tools/tests/test_gamma_candidates.py`

**Interfaces:**
- Consumes: `color_compare.read_png`, `color_compare.write_png`, the pairs file (Task 2), `PS4_SCREENSHOT_STAGE` (Task 3).
- Produces:
  - `CANDIDATES: dict[str, callable(e: float, gamma: float) -> float]` on encoded values in [0, 1];
  - CLI `gamma_candidates.py --gamma 0.8 --out DIR in1.png [in2.png ...]`, which writes `DIR/<candidate>/<basename>`;
  - the decision, recorded in the ledger: the chosen candidate name and its numbers.

The candidates:
- `current`: today's shader. Decode sRGB, then `1.055·lin^k − 0.055` with k = 1/(3.4 − g), and the sRGB linear segment below 0.0031308.
- `inv`: the same structure with k = 1/(1.4 + g).
- `encoded_pow`: `e^(1/g)` applied to the encoded value.
- `identity`: no change. This tests the hypothesis that the PS4 at the default gamma shows the frame as rendered.

- [ ] **Step 1: Write the failing tests**

```python
#!/usr/bin/env python3
"""Tests for tools/gamma_candidates.py."""
import os
import sys
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
import gamma_candidates as gc  # noqa: E402


class CandidateTest(unittest.TestCase):
    def test_identity_at_one(self):
        for name in ("inv", "encoded_pow", "identity"):
            f = gc.CANDIDATES[name]
            for e in (0.0, 0.02, 0.2, 0.5, 0.9, 1.0):
                self.assertAlmostEqual(f(e, 1.0), e, delta=2e-3, msg=name)

    def test_current_matches_shader_and_brightens_at_08(self):
        # the shader of ps4_metal_screen.m: k = 1/(3.4-g); at g = 0.8 a mid grey gets brighter
        self.assertGreater(gc.CANDIDATES["current"](0.5, 0.8), 0.5)

    def test_corrected_direction(self):
        for name in ("inv", "encoded_pow"):
            f = gc.CANDIDATES[name]
            self.assertLess(f(0.5, 0.8), 0.5, name)      # gamma < 1 darkens
            self.assertGreater(f(0.5, 1.2), 0.5, name)   # gamma > 1 brightens
            prev = -1.0
            for i in range(11):                         # monotonic in the value
                v = f(i / 10.0, 0.8)
                self.assertGreaterEqual(v, prev, name)
                prev = v

    def test_apply_image(self):
        img = (2, 1, [bytes([128, 128, 128, 255, 0, 10])])
        w, h, rows = gc.apply_image(img, gc.CANDIDATES["identity"], 0.8)
        self.assertEqual(rows[0], img[2][0])


if __name__ == "__main__":
    unittest.main()
```

- [ ] **Step 2: Run and see it fail**

Run: `cd ~/ps4recomp-work/PS4Recomp-colors/tools || exit 1; python3 tests/test_gamma_candidates.py`
Expected: `ModuleNotFoundError: No module named 'gamma_candidates'`.

- [ ] **Step 3: Write the tool**

```python
#!/usr/bin/env python3
"""Apply candidate output-gamma formulas (sceVideoOutAdjustColor) to render-stage screenshots.

usage: gamma_candidates.py --gamma G --out DIR in1.png [in2.png ...]

Writes DIR/<candidate>/<basename of each input>. The inputs are screenshots taken before the
output gamma pass (PS4_SCREENSHOT_STAGE=render, the default); color_compare.py --ours-dir
DIR/<candidate> then tells which formula brings them closest to the reference video.
"""
import argparse
import os
import sys

from color_compare import read_png, write_png


def srgb_decode(e):
    return e / 12.92 if e <= 0.04045 else ((e + 0.055) / 1.055) ** 2.4


def encode_with(lin, k):
    return 12.92 * lin if lin <= 0.0031308 else 1.055 * lin ** k - 0.055


def _clamp(v):
    return 0.0 if v < 0.0 else 1.0 if v > 1.0 else v


CANDIDATES = {
    # today's gamma_fs: k = 1 / (3.4 - gamma)
    "current": lambda e, g: _clamp(encode_with(srgb_decode(e), 1.0 / (3.4 - g))),
    # direction fixed, identity at 1.0: k = 1 / (1.4 + gamma)
    "inv": lambda e, g: _clamp(encode_with(srgb_decode(e), 1.0 / (1.4 + g))),
    # a plain power on the encoded value
    "encoded_pow": lambda e, g: _clamp(e ** (1.0 / g)),
    # the frame as rendered
    "identity": lambda e, g: e,
}


def apply_image(img, f, gamma):
    w, h, rows = img
    lut = bytes(int(round(255.0 * f(v / 255.0, gamma))) for v in range(256))
    return w, h, [bytes(r).translate(lut) for r in rows]


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--gamma", type=float, required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("inputs", nargs="+")
    a = ap.parse_args(argv)
    for name, f in CANDIDATES.items():
        d = os.path.join(a.out, name)
        os.makedirs(d, exist_ok=True)
        for p in a.inputs:
            w, h, rows = apply_image(read_png(p), f, a.gamma)
            write_png(os.path.join(d, os.path.basename(p)), w, h, rows)
    return 0


if __name__ == "__main__":
    sys.exit(main())
```

- [ ] **Step 4: Run the tests and see them pass**

Run: `cd ~/ps4recomp-work/PS4Recomp-colors/tools || exit 1; python3 tests/test_gamma_candidates.py -v`
Expected: all `ok`.

- [ ] **Step 5: Check the CPU model against the shader**

The `current` candidate applied to a render-stage shot must reproduce the `output`-stage shot of the same frame from Task 3. Take a pair of shots with the same frame number from the two Task 3 runs; any static frame works, for example the save-point view before Joel moves. Then run:

```bash
cd ~/ps4recomp-work/PS4Recomp-colors/tools || exit 1
python3 gamma_candidates.py --gamma 0.8 --out ~/ps4recomp-work/color_ref/model <render-stage shot>.png
```

Compare `color_ref/model/current/<shot>.png` with the output-stage shot using a one-pair JSON. Expected: |ΔL\*| ≤ 0.5 and |ΔC\*| ≤ 0.5. Otherwise the model does not match the shader; fix the model before using it to choose.

- [ ] **Step 6: Calibrate**

1. For each reference pair, take a **render-stage** internal screenshot of the same view: `tlou_color_run.sh` with the pair's `.padctl`, whose final `shot` writes into `shots/`.
2. Scale it to 960 px wide with `sips -Z 960` and save it as `color_ref/render/<pair>.png`.
3. Run:

```bash
cd ~/ps4recomp-work/PS4Recomp-colors/tools || exit 1
python3 gamma_candidates.py --gamma 0.8 --out ~/ps4recomp-work/color_ref/cand ~/ps4recomp-work/color_ref/render/*.png
for c in current inv encoded_pow identity; do
  echo "== $c"
  python3 color_compare.py color_ref/tlou_beyond_wall.json --root ~/ps4recomp-work/color_ref \
    --ours-dir ~/ps4recomp-work/color_ref/cand/$c --json ~/ps4recomp-work/color_ref/cand_$c.json
done
```

4. Choose the candidate with the smallest sum of |ΔL\* p5| + |ΔL\* p50| + |ΔL\* p95| over the `frame` regions of all pairs. Hair and saturation are not decided here: they are Tasks 6–7.
5. Record the table and the choice in the ledger.

Decision rules:
- `inv` or `encoded_pow` best: Task 5 implements it.
- `identity` best, with the difference from the best corrected candidate larger than 2 L\* in total: this suggests that the PS4 does not re-encode at gamma 0.8. Do not guess. Write the numbers into the ledger and ask the owner (in Russian) before Task 5, because it changes what the brightness slider does.
- `current` best: the analysis was wrong. Stop and report to the owner with the numbers.

- [ ] **Step 7: Commit**

```bash
cd ~/ps4recomp-work/PS4Recomp-colors || exit 1
git add tools/gamma_candidates.py tools/tests/test_gamma_candidates.py
git commit -m "tools: gamma_candidates.py, output-gamma formulas for calibration against a reference

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 5: Fix the output gamma in the runtime

**Files:**
- Create: `pkg/runtime/modules/libSceVideoOut/ps4_output_gamma.h`
- Create: `tests/host/output_gamma_test.c`
- Modify: `tests/host/run_host_tests.sh` (after the `screenshot_cadence_test` block, about line 65)
- Modify: `pkg/runtime/modules/libSceVideoOut/ps4_metal_screen.m` (the comment above `g_gamma_bits`, `gamma_fs`, and `gamma_prm_z` in `present_encode`)
- Modify: `tools/gamma_candidates.py` (mark the chosen candidate in a comment)

**Interfaces:**
- Consumes: the Task 4 decision (`inv` or `encoded_pow`), and `gamma_prm_z` (Task 3).
- Produces:
  - `static inline float ps4_output_gamma_param(float gamma)`, the value the shader gets in `prm.z`;
  - `static inline float ps4_output_gamma_apply(float e, float gamma)`, the CPU form of the shader for one encoded channel value, used by the test.

The code below is for `inv`. For `encoded_pow`, use the alternative bodies marked "encoded_pow".

- [ ] **Step 1: Write the failing host test**

```c
// Host test for the output gamma of sceVideoOutAdjustColor (libSceVideoOut/ps4_output_gamma.h).
#include "ps4_output_gamma.h"
#include <math.h>
#include <stdio.h>

static int fails;

#define CHECK(cond, ...)                                                       \
    do {                                                                       \
        if (!(cond)) {                                                         \
            fprintf(stderr, "output_gamma_test:%d: ", __LINE__);               \
            fprintf(stderr, __VA_ARGS__);                                      \
            fprintf(stderr, "\n");                                             \
            fails++;                                                           \
        }                                                                      \
    } while (0)

int main(void) {
    // 1.0 is the identity
    for (int i = 0; i <= 255; i++) {
        const float e = i / 255.0f;
        const float o = ps4_output_gamma_apply(e, 1.0f);
        CHECK(fabsf(o - e) < 2e-3f, "gamma 1.0 changed %f to %f", e, o);
    }
    // below 1 darkens, above 1 brightens (the game's default 0.8 must not wash the image out)
    CHECK(ps4_output_gamma_apply(0.5f, 0.8f) < 0.5f, "gamma 0.8 does not darken mid grey");
    CHECK(ps4_output_gamma_apply(0.5f, 1.2f) > 0.5f, "gamma 1.2 does not brighten mid grey");
    // monotonic in the value and in gamma; black and white stay put
    for (int gi = 5; gi <= 15; gi++) {
        const float g = gi / 10.0f;
        float prev = -1.0f;
        for (int i = 0; i <= 255; i++) {
            const float o = ps4_output_gamma_apply(i / 255.0f, g);
            CHECK(o >= prev, "not monotonic at gamma %f, value %d", g, i);
            prev = o;
        }
        CHECK(ps4_output_gamma_apply(0.0f, g) == 0.0f, "black moved at gamma %f", g);
        CHECK(fabsf(ps4_output_gamma_apply(1.0f, g) - 1.0f) < 1e-4f, "white moved at gamma %f", g);
        CHECK(ps4_output_gamma_apply(0.5f, g) <= ps4_output_gamma_apply(0.5f, g + 0.1f),
              "not monotonic in gamma at %f", g);
    }
    if (fails) return 1;
    printf("output_gamma_test: ok\n");
    return 0;
}
```

Add to `tests/host/run_host_tests.sh`, after the screenshot cadence test:

```bash
# sceVideoOutAdjustColor output gamma: identity at 1.0, < 1 darkens, > 1 brightens, monotonic.
clang -std=gnu11 -Wall -Werror -I "$R/pkg/runtime/modules/libSceVideoOut" "$R/tests/host/output_gamma_test.c" \
  -lm -o "$T/output_gamma_test"
"$T/output_gamma_test"
```

- [ ] **Step 2: Run and see it fail**

Run: `~/ps4recomp-work/PS4Recomp-colors/tests/host/run_host_tests.sh 2>&1 | tail -3`
Expected: a compile error, `ps4_output_gamma.h: No such file`.

- [ ] **Step 3: Write the header**

```c
// Output gamma of sceVideoOutAdjustColor, shared by the presenter (ps4_metal_screen.m) and its
// host test. The game's brightness option sets it; The Last of Us passes 0.8 at its default.
// gamma 1.0 shows the frame as rendered, gamma < 1 darkens and gamma > 1 brightens. The form was
// chosen by calibration against a PS4 reference video (docs/color-measurement.md): the frame is
// decoded from sRGB to linear and encoded again with the exponent 1 / (1.4 + gamma), which is
// the sRGB exponent 1/2.4 at gamma 1.0.
#ifndef PS4_OUTPUT_GAMMA_H
#define PS4_OUTPUT_GAMMA_H
#include <math.h>

// What the presenter's gamma shader receives in prm.z: the encoding exponent.
static inline float ps4_output_gamma_param(float gamma) { return 1.0f / (1.4f + gamma); }

// CPU form of the shader for one encoded channel value in [0, 1].
static inline float ps4_output_gamma_apply(float e, float gamma) {
    const float lin = e <= 0.04045f ? e / 12.92f : powf((e + 0.055f) / 1.055f, 2.4f);
    const float k = ps4_output_gamma_param(gamma);
    const float o = lin <= 0.0031308f ? 12.92f * lin : 1.055f * powf(lin, k) - 0.055f;
    return o < 0.0f ? 0.0f : o > 1.0f ? 1.0f : o;
}
#endif
```

For `encoded_pow`, use `ps4_output_gamma_param(g) = 1.0f / g` and `ps4_output_gamma_apply(e, g) = powf(e, ps4_output_gamma_param(g))` (clamped to [0, 1]), and change the comment to say that the encoded value is raised to 1/gamma.

- [ ] **Step 4: Run the host test and see it pass**

Run: `~/ps4recomp-work/PS4Recomp-colors/tests/host/run_host_tests.sh 2>&1 | grep -E 'output_gamma|FAIL|error'`
Expected: `output_gamma_test: ok`, and the whole script exits 0.

- [ ] **Step 5: Use the header in the presenter**

In `ps4_metal_screen.m`:

1. Add `#include "ps4_output_gamma.h"` with the other local includes.
2. Replace the comment above `g_gamma_bits` with: `// Output gamma (sceVideoOutAdjustColor), see ps4_output_gamma.h. 1.0 presents the frame as is.`
3. In `gamma_fs`, change the parameter comment to `z = encoding exponent (ps4_output_gamma_param)`, and replace

```
"    float k = 1.0 / (3.4 - prm.z);\n"
"    float3 o = select(1.055 * pow(lin, k) - 0.055, 12.92 * lin, lin <= 0.0031308);\n"
```

with

```
"    float3 o = select(1.055 * pow(lin, prm.z) - 0.055, 12.92 * lin, lin <= 0.0031308);\n"
```

For `encoded_pow`, the shader body works on the encoded value. When the source view decodes sRGB (`prm.w > 0.5`), it re-encodes first:

```
"    float3 e = src.read(uint2(in.pos.xy - prm.xy)).rgb;\n"
"    float3 enc = prm.w > 0.5 ? select(1.055 * pow(e, 1.0 / 2.4) - 0.055, 12.92 * e, e <= 0.0031308) : e;\n"
"    float3 o = pow(enc, prm.z);\n"
"    return float4(saturate(o), 1.0);\n"
```

4. In `present_encode`, change the Task 3 local to `const float gamma_prm_z = ps4_output_gamma_param(gamma);`. Both the drawable pass and the screenshot pass already use it.

- [ ] **Step 6: Verify in the game**

1. Rebuild the game.
2. With `PS4_SCREENSHOT_STAGE=output`, take one view's shot. `gamma_candidates.py`'s chosen candidate applied to the render-stage shot of the same frame must match it within |ΔL\*| ≤ 0.5 (same procedure as Task 4, Step 5).
3. Retake the window captures for all pairs (Task 2, Step 5, the same `.padctl` files), run `color_compare.py`, and write the table to the ledger.

Expected: L\* p5/p50/p95 of the `frame` regions are within limits or clearly closer than the baseline. C\* may still be over: that is Task 6.

4. Check the in-game brightness slider: in a short windowed run, move the slider up. AdjustColor in the log shows gamma > 0.8, and the window gets brighter.

- [ ] **Step 7: Commit**

```bash
cd ~/ps4recomp-work/PS4Recomp-colors || exit 1
git add pkg/runtime/modules/libSceVideoOut/ps4_output_gamma.h pkg/runtime/modules/libSceVideoOut/ps4_metal_screen.m \
        tests/host/output_gamma_test.c tests/host/run_host_tests.sh tools/gamma_candidates.py
git commit -m "videoout: output gamma in the right direction, calibrated against a PS4 reference

sceVideoOutAdjustColor's gamma 0.8 (TLOU's default brightness) brightened the image: the
exponent 1/(3.4-gamma) grows away from sRGB as gamma falls. The formula now lives in
ps4_output_gamma.h with a host test.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 6: sRGB colour space on the window layer

**Files:**
- Modify: `pkg/runtime/modules/libSceVideoOut/ps4_metal_screen.m` (layer setup, about line 178)
- Modify: `docs/color-measurement.md` (the variable)

**Interfaces:**
- Produces: `PS4_COLORSPACE=srgb|native` (default `srgb`). With `native`, the layer gets no colour space, which is the old behaviour.

- [ ] **Step 1: Set the colour space**

After `g_metalLayer.framebufferOnly = NO;`:

```objc
        // The frame holds sRGB values. Tagging the layer lets macOS map them to the panel's gamut
        // (P3 on Mac displays); untagged, they are shown as panel values and look oversaturated.
        // PS4_COLORSPACE=native keeps the layer untagged, for comparison.
        const char *cs_env = getenv("PS4_COLORSPACE");
        if (!(cs_env && strcmp(cs_env, "native") == 0)) {
            CGColorSpaceRef srgb = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
            g_metalLayer.colorspace = srgb;
            CGColorSpaceRelease(srgb);
        }
```

- [ ] **Step 2: Measure the colour effect**

1. Rebuild.
2. Retake the window captures of all pairs, once with the default and once with `PS4_COLORSPACE=native`, and run `color_compare.py` on both.
3. Expected: with `srgb`, the whole-frame C\* is lower than with `native` and closer to the reference.
4. Write both tables to the ledger.

- [ ] **Step 3: Frame-rate A/B**

Use the existing A/B tool (`tools/metal4_perf_ab.sh`; read its usage header first) on the TLOU route:

- side A: a copy of the build directory made at Task 5's commit, before this task;
- side B: this build;
- alternate the sides, at least 3 runs each, logging `uptime`;
- discard runs with load > 15.

Expected: encoder ms and fps equal within noise. If B is measurably slower, record the numbers and ask the owner before keeping the change.

- [ ] **Step 4: Commit**

```bash
cd ~/ps4recomp-work/PS4Recomp-colors || exit 1
git add pkg/runtime/modules/libSceVideoOut/ps4_metal_screen.m docs/color-measurement.md
git commit -m "videoout: tag the window layer as sRGB so macOS colour-matches the frame

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 7: Hair and skin — localise with a frame capture, prove with a replay, fix

This task is an investigation. Its code change depends on what the capture shows. The steps give the exact procedure, the hypotheses to check in order, and the fix and test pattern for each.

**Files:**
- Read first: `docs/gnm-capture.md` (capturing, layout, manifest, replay), `tools/gnm_capture_view.py`, `tools/gnm_replay/build.sh`
- Modify, depending on the cause:
  - `pkg/runtime/modules/libSceGnmDriver/ps4_gnm_resources.mm` (`GetPixelFormat` ~286, `RemapNumberFormat` ~125, `RemapSwizzle` ~151, `ComposeViewSwizzle` ~434, the RT-as-texture view ~2982–3032);
  - `3rdparty/gcn-recompiler/src/shader_recompiler/ir/passes/resource_patching_pass.cpp` (FORCE_DEGAMMA ~826);
  - `3rdparty/gcn-recompiler/src/shader_recompiler/frontend/translate/export.cpp`.
- Test: a new host test next to the existing format tests in `tests/host/` (see `gnm_alias_dma_test.mm` and `gcn_runtime_sharp_test.mm` for the pattern), plus the replay comparison.

**Interfaces:**
- Consumes: the `joel_back` pair and its `hair` / `skin` regions (Task 2).
- Produces: a fix whose cause is recorded in the commit message and the ledger.

- [ ] **Step 1: Capture a frame with Joel's hair in view**

1. Find the present index of a frame in the `joel_back` view: run `tlou_color_run.sh` with `joel_back.padctl`, and read the `shot` frame number from `shots/`.
2. Capture that frame (add 10 to it, so the camera has settled):

```bash
~/ps4recomp-work/PS4Recomp-colors/tools/tlou_color_run.sh ~/ps4recomp-work/color_runs/cap 240 \
  ~/ps4recomp-work/PS4Recomp-colors/tools/color_ref/joel_back.padctl \
  PS4_GNM_SYNC_ENCODE=1 PS4_GNM_CAPTURE_FRAME=<n> PS4_GNM_CAPTURE_DIR=~/ps4recomp-work/cap_colors
python3 ~/ps4recomp-work/PS4Recomp-colors/tools/gnm_capture_view.py ~/ps4recomp-work/cap_colors/frame_<n>
open ~/ps4recomp-work/cap_colors/frame_<n>/index.html
```

Capture is slow (seconds to minutes for the frame), so use a long alarm. Check `gnm_capture_view.py`'s usage line first; if it takes other arguments, use them. If the pad timing drifts because of the slow frame, capture the frame at the save point instead: Joel's hair is visible from behind there too.

- [ ] **Step 2: Find the hair and skin draws**

In `index.html`, find the g-buffer passes whose `png/p<pass>_<role>.png` shows Joel's hair appearing, and whose albedo MRT shows a light or yellow colour there.

For each such pass, record in the ledger:
- `stages[].code_addr` and `pgm_hash` of the PS;
- every sampled T#: data format, number format, DST_SEL, the Metal view format the renderer chose, and whether it went through `RemapNumberFormat` or is `exact=false`;
- the CB format and number type, and `export_format`.

Do the same for a skin pass (face or arms).

Then decide whether the colour is already wrong in the g-buffer albedo. If yes, the cause is in the material pass (Steps 3–4). If the albedo is right and the lit result is wrong, follow the lighting and composite passes that read that MRT the same way.

- [ ] **Step 3: Check the hypotheses in this order**

For each, the check, and the fix if it is the cause:

1. **A sampled texture with a remapped or inexact format** (2_10_10_10 SNORM → UNORM, BC4/BC5/BC6 sRGB → UNORM, BC6 `SrgbToNorm`).
   - Check: the T# of a hair texture hits one of these paths.
   - Fix: give that format an exact Metal mapping or a shader-side conversion, following how SNORM is handled elsewhere in `GetPixelFormat`. Never leave a silent inexact mapping.
2. **The DST_SEL swizzle composed wrongly** with a format that has its own swizzle (`swap_rb` formats, BGRA views).
   - Check: the view's `MTLTextureSwizzleChannels` against DST_SEL composed with the format's component order. Compute by hand which channel ends up in `.r`.
   - Fix: correct `ComposeViewSwizzle` / `RemapSwizzle`.
3. **sRGB view or FORCE_DEGAMMA applied twice, or not at all.** Hair that is too light is what sRGB data read as UNORM would look like, or an albedo decoded and then decoded again shown darker.
   - Check: the T# number format (SRGB?), whether the sampler has FORCE_DEGAMMA, and whether the view is `_sRGB`.
   - Fix: in `resource_patching_pass.cpp` or in the view selection, so that exactly one linearisation happens.
4. **An RT sampled later through an sRGB/UNORM view that disagrees with how it was written** (`ps4_gnm_resources.mm` ~2982–3032).
   - Check: the hair albedo MRT's CB number type when written against the T# number type when read.
   - Fix: in the view selection.
5. **Export conversion** (`export.cpp`: FP16/UNORM16/SNORM16 compressed exports, the 8-bit rounding).
   - Check: the hair PS's `export_format` and the MRT format.
   - Fix: in `export.cpp`.

If none of these explains it, the input data is the question. Only then use REA, with one scoped question: "how does the game build the data that this PS reads at <code_addr> for texture/buffer X". Follow the owner's REA rule (one binary session, closed afterwards, results treated as data, and the answer recorded in the ledger).

- [ ] **Step 4: Prove the cause with a replay before changing the renderer**

1. Recapture with `PS4_GNM_CAPTURE_REPLAY_SHADER=pgm:<hair ps hash>`, so the hair pass and its producers are replayable.
2. Build the replay (`tools/gnm_replay/build.sh`, see `docs/gnm-capture.md`).
3. Replay the pass unchanged and check that it reproduces the captured output (`tools/metal4_replay_cmp.py`).
4. Apply the candidate fix and replay again. The hair region of the replayed MRT must now be dark brown. Check it with `color_compare.py`, using a pair of the replayed PNG against `video/joel_back.png` and only the `hair` region. Albedo is not the final colour, so the check here is the hue (`h`) and that the region is no longer light: L\* p50 drops clearly.

- [ ] **Step 5: Write the failing unit test for the cause, then fix**

Write a host test of the exact function you will change, with the hair's descriptor values from Step 2 as input and the expected Metal format, swizzle or flag as output. For example, for hypothesis 2:

```objc
// The hair albedo T# of TLOU (capture frame_<n>, pass <p>): <dfmt>/<nfmt>, DST_SEL <x,y,z,w>.
// The view must put the texture's <channel> into .r.
MTLTextureSwizzleChannels s = ComposeViewSwizzle(<args from the capture>);
CHECK(s.red == MTLTextureSwizzle<expected>);
```

The `<...>` fields are filled in from the capture's ledger entry of Step 2; they are data, not missing design. Run the test with `tests/host/run_host_tests.sh` and see it fail. Then implement the fix found in Steps 3–4 and see the test pass. The test must use the real descriptor values from the capture, not invented ones.

- [ ] **Step 6: Verify in the game**

1. Rebuild.
2. Retake the `joel_back` window capture and run `color_compare.py`. The `hair` region must be within the `detail` limits and the `skin` region must not be worse than before.
3. Look at Ellie and Tess in the same frames: on a 60 s walk with the `courtyard.padctl` view, the companion is in frame. No new colour error.
4. Run the whole pairs file and write the table to the ledger.

- [ ] **Step 7: Commit**

```bash
cd ~/ps4recomp-work/PS4Recomp-colors || exit 1
git add <changed files> tests/host/<new test> tests/host/run_host_tests.sh
git commit -m "gnm: <the cause in one line>

TLOU drew Joel's hair blond instead of dark brown: <mechanism, with the descriptor values
from the capture>. Proven by replaying the hair pass of a captured frame before and after.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 8: Remaining grade

**Files:** none unless the check fails, in which case the cause decides which files change, as in Task 7.

- [ ] **Step 1: Re-measure**

Run `color_compare.py` on all pairs with fresh window captures, and write the table to the ledger.

- [ ] **Step 2: Decide**

- If every `frame` region has relative ΔC\* ≤ 15% and |Δh| is unremarkable: this task closes with the numbers.
- If ΔC\* is still over 15%, find the tonemap / colour-grading pass in the Task 7 capture: the full-screen pass near the end of the frame that samples a small 3D texture (the grading LUT) or reads the HDR target and writes the 8-bit target. Check its LUT texture's format, number format and view (3D `_sRGB`? remapped?) and its export, using the Task 7 Step 3 hypotheses.
- Prove the cause with a replay (Task 7, Step 4), write a unit test with the real descriptor values (Task 7, Step 5), fix, re-measure and commit as in Task 7, Step 7.

---

### Task 9: Final verification and report

- [ ] **Step 1: All tests**

```bash
~/ps4recomp-work/PS4Recomp-colors/tests/host/run_host_tests.sh > ~/ps4recomp-work/hosttests_colors_final.log 2>&1; echo "rc=$?"
cd ~/ps4recomp-work/PS4Recomp-colors/tools || exit 1
for t in tests/test_*.py; do python3 "$t" > /dev/null 2>&1 || echo "FAIL $t"; done
cd ~/ps4recomp-work/PS4Recomp-colors || exit 1; go vet ./pkg/... ./cmd/...
```

Expected: `rc=0`, no `FAIL` beyond the Task 0 baseline, and `go vet` clean.

- [ ] **Step 2: Colour numbers**

Fresh window captures of all pairs, then `color_compare.py`. Expected: exit 0. Any region still over its limit is listed in the report with its numbers. It is not hidden, and the limits are not loosened.

- [ ] **Step 3: Frame rate**

A/B against `metal4-backend`'s `tlou_build` on the TLOU route, with the same rules as Task 6, Step 3. Expected: no loss within noise.

- [ ] **Step 4: Uncharted 4 control**

1. Rebuild U4 from this branch into a separate directory, `~/ps4recomp-work/u4_build_colors`, using the same `ps4-recomp` command with the U4 `eboot.bin` and `--app-dir`.
2. Take one window capture of the title screen with this build and one with the current U4 build, each in a ≤720p window, time-bounded, with `PS4RECOMP_DATA_DIR` set to the test copy and nothing else running.
3. Expected: no new artefact. Brightness may change through AdjustColor; record the gamma U4 passes, from its log, and both captures in the ledger.

- [ ] **Step 5: Whole-branch review**

Use superpowers:requesting-code-review on `metal4-backend..tlou-colors`. Fix the findings that hold, with a commit each.

- [ ] **Step 6: Report to the owner, in Russian**

The report covers:
- the baseline and the final colour table;
- what each fix was and why;
- the fps numbers;
- the U4 control;
- anything still over its limit.

Offer the next steps for the owner to decide: merge into `metal4-backend`, and install into `eboot.app` atomically. Do neither without their yes.
