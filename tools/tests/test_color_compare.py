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

    def test_neutral_regions_skip_hue(self):
        # both regions near-neutral (C below NEUTRAL_C): their hues are arbitrary, so no h violation
        lim = color_compare.LIMITS["detail"]
        self.assertEqual(color_compare.compare_stats(self.stats(30, C=1.0, h=40),
                                                     self.stats(30, C=1.0, h=5), lim), [])
        # one side saturated: the hue is meaningful again and the check applies
        self.assertTrue(color_compare.compare_stats(self.stats(30, C=20.0, h=40),
                                                    self.stats(30, C=1.0, h=5), lim))


def png_chunk(t, body):
    return struct.pack(">I", len(body)) + t + body + struct.pack(">I", zlib.crc32(t + body) & 0xFFFFFFFF)


def run_pairs_file(d, cfg=None, raw=None, extra=()):
    p = os.path.join(d, "pairs.json")
    with open(p, "w") as f:
        f.write(raw if raw is not None else json.dumps(cfg))
    return subprocess.run([sys.executable, TOOL, p] + list(extra), capture_output=True, text=True)


def frame_pair(ours, limits="frame"):
    return {"pairs": [{"name": "p", "ours": ours, "ref": "ref.png",
                       "regions": {"frame": {"limits": limits, "ours": [0, 0, 1, 1], "ref": [0, 0, 1, 1]}}}]}


class CliTest(unittest.TestCase):
    def test_bad_input_exits_2(self):
        with tempfile.TemporaryDirectory() as d:
            write_rgb_png(os.path.join(d, "ref.png"), 16, 16, lambda x, y: (120, 100, 80))
            # a PNG whose IHDR is valid but whose IDAT is not zlib data (zlib.error)
            ihdr = png_chunk(b"IHDR", struct.pack(">IIBBBBB", 1, 1, 8, 2, 0, 0, 0))
            with open(os.path.join(d, "badidat.png"), "wb") as f:
                f.write(b"\x89PNG\r\n\x1a\n" + ihdr + png_chunk(b"IDAT", b"garbage") + png_chunk(b"IEND", b""))
            # a PNG whose IHDR is too short to unpack (struct.error)
            with open(os.path.join(d, "shortihdr.png"), "wb") as f:
                f.write(b"\x89PNG\r\n\x1a\n" + png_chunk(b"IHDR", b"\x00") + png_chunk(b"IEND", b""))
            # valid signature followed by garbage (no IHDR)
            with open(os.path.join(d, "garbage.png"), "wb") as f:
                f.write(b"\x89PNG\r\n\x1a\n" + b"not a chunk at all")
            cases = {
                "missing image": run_pairs_file(d, frame_pair("nope.png")),
                "invalid JSON": run_pairs_file(d, raw="{bad"),
                "unknown limits name": run_pairs_file(d, frame_pair("ref.png", limits="bogus")),
                "corrupt PNG (bad IDAT)": run_pairs_file(d, frame_pair("badidat.png")),
                "corrupt PNG (short IHDR)": run_pairs_file(d, frame_pair("shortihdr.png")),
                "corrupt PNG (garbage)": run_pairs_file(d, frame_pair("garbage.png")),
                "malformed pairs": run_pairs_file(d, {"pairs": "x"}),
            }
            for name, r in cases.items():
                with self.subTest(case=name):
                    self.assertEqual(r.returncode, 2, r.stderr)
                    self.assertNotIn("Traceback", r.stderr)
                    self.assertEqual(len(r.stderr.strip().splitlines()), 1, r.stderr)

    def test_ours_dir_replaces_directory(self):
        with tempfile.TemporaryDirectory() as d:
            ref_dir = os.path.join(d, "ref")
            sub = os.path.join(d, "sub")
            cand = os.path.join(d, "cand")
            for p in (ref_dir, sub, cand):
                os.makedirs(p)
            write_rgb_png(os.path.join(ref_dir, "ref.png"), 16, 16, lambda x, y: (120, 100, 80))
            write_rgb_png(os.path.join(sub, "a.png"), 16, 16, lambda x, y: (120, 100, 80))   # matches ref
            write_rgb_png(os.path.join(cand, "a.png"), 16, 16, lambda x, y: (200, 180, 160))  # does not
            cfg = frame_pair("sub/a.png")
            cfg["pairs"][0]["ref"] = "ref/ref.png"
            p_default = run_pairs_file(d, cfg)
            p_override = run_pairs_file(d, cfg, extra=["--ours-dir", cand])
            self.assertEqual(p_default.returncode, 0, p_default.stdout)
            self.assertEqual(p_override.returncode, 1, p_override.stdout)
            self.assertIn("p/frame", p_override.stdout)

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
