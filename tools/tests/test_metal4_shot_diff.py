# Tests tools/metal4_shot_diff.py on generated PNGs.
import os
import struct
import subprocess
import sys
import tempfile
import unittest
import zlib

TOOL = os.path.join(os.path.dirname(__file__), "..", "metal4_shot_diff.py")


def chunk(t, d):
    return struct.pack(">I", len(d)) + t + d + struct.pack(">I", zlib.crc32(t + d) & 0xFFFFFFFF)


def write_png(path, w, h, pixel):
    raw = b"".join(b"\x00" + b"".join(bytes(pixel(x, y)) for x in range(w)) for y in range(h))
    with open(path, "wb") as f:
        f.write(b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0)) +
                chunk(b"IDAT", zlib.compress(raw)) + chunk(b"IEND", b""))


def write_raw(path, w, h, depth, ctype, rows, interlace=0, extra=()):
    """rows: list of raw scanline bytes (no filter byte)."""
    raw = b"".join(b"\x00" + r for r in rows)
    with open(path, "wb") as f:
        f.write(b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, depth, ctype, 0, 0, interlace)) +
                b"".join(chunk(t, d) for t, d in extra) + chunk(b"IDAT", zlib.compress(raw)) + chunk(b"IEND", b""))


def run(a, b, *args):
    p = subprocess.run([sys.executable, "-I", TOOL, a, b, *args], capture_output=True, text=True)
    return p.returncode, p.stdout.strip()


class ShotDiffTest(unittest.TestCase):
    def setUp(self):
        self._t = tempfile.TemporaryDirectory()
        self.addCleanup(self._t.cleanup)
        d = self._t.name
        self.d = d
        self.a, self.b, self.c, self.e = (os.path.join(d, n) for n in ("a.png", "b.png", "c.png", "e.png"))
        write_png(self.a, 8, 4, lambda x, y: (x * 10, y * 20, 50))
        write_png(self.b, 8, 4, lambda x, y: (x * 10, y * 20, 50))
        write_png(self.c, 8, 4, lambda x, y: (x * 10 + (3 if (x, y) == (2, 1) else 0), y * 20,
                                              50 + (9 if (x, y) == (5, 3) else 0)))
        write_png(self.e, 4, 4, lambda x, y: (0, 0, 0))

    def test_cases(self):
        a, b, c, e = self.a, self.b, self.c, self.e
        self.assertEqual(run(a, b), (0, "identical"))
        self.assertEqual(run(a, c, "--threshold", "4"), (1, "differ: 2 pixels (6.25%), max channel diff 9, 1 pixels above 4, bbox x 2..5 y 1..3"))
        self.assertEqual(run(a, c, "--threshold", "9"), (0, "differ: 2 pixels (6.25%), max channel diff 9, 0 pixels above 9, bbox x 2..5 y 1..3"))
        self.assertEqual(run(a, c), (1, "differ: 2 pixels (6.25%), max channel diff 9, 2 pixels above 0, bbox x 2..5 y 1..3"))
        code, out = run(a, e)
        self.assertEqual(code, 1)
        self.assertTrue(out.startswith("size differs"))

    def test_bad_inputs_fail(self):
        d = self.d
        garbage, empty, trunc, zero = (os.path.join(d, n) for n in ("g.png", "z.png", "t.png", "w0.png"))
        with open(garbage, "wb") as f:
            f.write(b"this is not a png at all")
        open(empty, "wb").close()
        with open(self.a, "rb") as f:
            data = f.read()
        with open(trunc, "wb") as f:
            f.write(data[:len(data) // 2])
        with open(zero, "wb") as f:  # a valid PNG with zero width: nothing to compare
            f.write(b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", 0, 0, 8, 2, 0, 0, 0)) +
                    chunk(b"IDAT", zlib.compress(b"")) + chunk(b"IEND", b""))
        for bad in (garbage, empty, trunc, zero, os.path.join(d, "missing.png")):
            self.assertEqual(run(bad, bad)[0], 2, bad)       # same bad file twice must not read as "identical"
            self.assertEqual(run(self.a, bad)[0], 2, bad)
            self.assertEqual(run(bad, self.a)[0], 2, bad)
        self.assertEqual(run(self.a, self.b, "--threshold", "-1")[0], 2)

    def test_rgba_inputs(self):
        # alpha is ignored, a colour difference inside an RGBA image is still found
        p, q = os.path.join(self.d, "p.png"), os.path.join(self.d, "q.png")
        for path, r in ((p, 10), (q, 14)):
            raw = b"".join(b"\x00" + bytes([r, 20, 30, 255 - x]) * 1 for y in range(2) for x in range(1))
            with open(path, "wb") as f:
                f.write(b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", 1, 2, 8, 6, 0, 0, 0)) +
                        chunk(b"IDAT", zlib.compress(raw)) + chunk(b"IEND", b""))
        self.assertEqual(run(p, q), (1, "differ: 2 pixels (100.00%), max channel diff 4, 2 pixels above 0, bbox x 0..0 y 0..1"))

    def png(self, name, *args, **kw):
        p = os.path.join(self.d, name)
        write_raw(p, *args, **kw)
        return p

    def test_gray_and_palette(self):
        g1 = self.png("g1.png", 2, 1, 8, 0, [bytes([10, 20])])
        g2 = self.png("g2.png", 2, 1, 8, 0, [bytes([10, 27])])
        self.assertEqual(run(g1, g1), (0, "identical"))
        self.assertEqual(run(g1, g2), (1, "differ: 1 pixels (50.00%), max channel diff 7, 1 pixels above 0, bbox x 1..1 y 0..0"))
        pal = (b"PLTE", bytes([0, 0, 0, 100, 0, 0, 0, 100, 0]))
        p1 = self.png("p1.png", 2, 1, 8, 3, [bytes([0, 1])], extra=[pal])
        p2 = self.png("p2.png", 2, 1, 8, 3, [bytes([0, 2])], extra=[pal])
        self.assertEqual(run(p1, p1), (0, "identical"))
        self.assertEqual(run(p1, p2), (1, "differ: 1 pixels (50.00%), max channel diff 100, 1 pixels above 0, bbox x 1..1 y 0..0"))

    def test_refusals(self):
        s16 = struct.pack(">HHH", 0x1000, 0, 0)
        a16 = self.png("a16.png", 1, 1, 16, 2, [s16])
        b16 = self.png("b16.png", 1, 1, 16, 2, [struct.pack(">HHH", 0x10C8, 0, 0)])  # low byte differs only
        for x, y in ((a16, b16), (a16, a16)):
            code, out = run(x, y)
            self.assertEqual((code, out), (2, ""))
        il = self.png("il.png", 1, 1, 8, 2, [b"\0\0\0"], interlace=1)
        g4 = self.png("g4.png", 2, 1, 4, 0, [b"\x12"])
        for bad in (il, g4):
            self.assertEqual(run(bad, self.a)[0], 2)
        for t in ("256", "-1", "1000"):
            self.assertEqual(run(self.a, self.b, "--threshold", t)[0], 2, t)
        self.assertEqual(run(self.a, self.b, "--threshold", "255")[0], 0)

    def test_error_message_names_path_once(self):
        g4 = self.png("once4.png", 2, 1, 4, 0, [b"\x12"])
        p = subprocess.run([sys.executable, "-I", TOOL, g4, self.a], capture_output=True, text=True)
        self.assertEqual(p.stderr.count("once4.png"), 1, p.stderr)

    def test_alpha_only_difference_is_reported(self):
        x = self.png("x.png", 1, 1, 8, 6, [bytes([1, 2, 3, 255])])
        y = self.png("y.png", 1, 1, 8, 6, [bytes([1, 2, 3, 0])])
        self.assertEqual(run(x, y), (0, "identical (alpha not compared)"))

    def test_baseline(self):
        a, b, c = self.a, self.b, self.c
        # Metal 3 pair a/c differs by 9 at most: that becomes T, so a vs c passes
        code, out = run(a, c, "--baseline", a, c)
        self.assertEqual(code, 0)
        self.assertIn("baseline: 2 pixels differ, max channel diff 9", out)
        self.assertTrue(out.endswith("0 pixels above 9, bbox x 2..5 y 1..3"), out)
        # identical Metal 3 pair: T = 0, so a vs c fails
        code, out = run(a, c, "--baseline", a, b)
        self.assertEqual(code, 1)
        self.assertIn("baseline: 0 pixels differ, max channel diff 0", out)
        # explicit --threshold wins over the baseline
        self.assertEqual(run(a, c, "--baseline", a, c, "--threshold", "4")[0], 1)
        # a bad or differently sized baseline never passes
        self.assertEqual(run(a, c, "--baseline", a, self.e)[0], 2)
        self.assertEqual(run(a, c, "--baseline", a, os.path.join(self.d, "none.png"))[0], 2)
        self.assertEqual(run(a, c, "--baseline", self.e, self.e)[0], 2)


def run_dirs(a, b, *args):
    p = subprocess.run([sys.executable, "-I", TOOL, "--dirs", a, b, *args], capture_output=True, text=True)
    return p.returncode, p.stdout.strip().splitlines()


class ShotDirsTest(unittest.TestCase):
    """--dirs: the sec_<s>.png shots of two runs paired by their time index."""

    def setUp(self):
        self._t = tempfile.TemporaryDirectory()
        self.addCleanup(self._t.cleanup)
        self.root = self._t.name

    def run_dir(self, name, shots):
        """shots: {file name: blue value of the one pixel that varies}."""
        d = os.path.join(self.root, name)
        os.mkdir(d)
        for f, v in shots.items():
            write_png(os.path.join(d, f), 4, 2, lambda x, y, v=v: (x * 30, y * 40, v if (x, y) == (1, 1) else 0))
        return d

    def test_pairs_by_time_index(self):
        # Runs at different frame rates: the same second is a different flip, so frame_*.png
        # would pair the wrong images; sec_<s>.png pairs by time. frame_* and *_req.png are ignored,
        # an index in one run only is listed and does not fail.
        a = self.run_dir("a", {"sec_000000.png": 0, "sec_000005.png": 50, "sec_000010.png": 100,
                               "frame_000600.png": 200, "sec_000007_req.png": 9, "sec_000020.png": 1})
        b = self.run_dir("b", {"sec_000000.png": 0, "sec_000005.png": 50, "sec_000010.png": 103,
                               "sec_000015.png": 7, "frame_000600.png": 0, "sec_000020.png": 1})
        code, out = run_dirs(a, b, "--threshold", "4")
        self.assertEqual(code, 0)
        self.assertEqual(out, ["t=15s: only in " + b, "t=0s: identical", "t=5s: identical",
                               "t=10s: differ: 1 pixels (12.50%), max channel diff 3, 0 pixels above 4, bbox x 1..1 y 1..1",
                               "t=20s: identical", "paired 4 of 5 seconds"])
        code, out = run_dirs(a, b, "--threshold", "2")
        self.assertEqual(code, 1)  # a later identical index does not hide the failure
        self.assertEqual(out[-3], "t=10s: differ: 1 pixels (12.50%), max channel diff 3, 1 pixels above 2, bbox x 1..1 y 1..1")

    def test_baseline_per_index(self):
        a = self.run_dir("a", {"sec_000000.png": 10, "sec_000005.png": 50})
        b = self.run_dir("b", {"sec_000000.png": 12, "sec_000005.png": 56})
        m3a = self.run_dir("m3a", {"sec_000000.png": 0, "sec_000005.png": 0})
        m3b = self.run_dir("m3b", {"sec_000000.png": 2, "sec_000005.png": 5})
        code, out = run_dirs(a, b, "--baseline", m3a, m3b)
        # t=0: Metal 3 noise 2 covers the difference 2; t=5: noise 5 does not cover 6
        self.assertEqual(code, 1)
        self.assertEqual(out, ["t=0s: baseline: 1 pixels differ, max channel diff 2; "
                               "differ: 1 pixels (12.50%), max channel diff 2, 0 pixels above 2, bbox x 1..1 y 1..1",
                               "t=5s: baseline: 1 pixels differ, max channel diff 5; "
                               "differ: 1 pixels (12.50%), max channel diff 6, 1 pixels above 5, bbox x 1..1 y 1..1",
                               "paired 2 of 2 seconds"])
        # an index without a Metal 3 pair fails even when the Metal 4 pair is identical
        m3c = self.run_dir("m3c", {"sec_000000.png": 2})
        b2 = self.run_dir("b2", {"sec_000000.png": 12, "sec_000005.png": 50})
        code, out = run_dirs(a, b2, "--baseline", m3a, m3c)
        self.assertEqual(code, 1)
        self.assertEqual(out, ["t=0s: baseline: 1 pixels differ, max channel diff 2; "
                               "differ: 1 pixels (12.50%), max channel diff 2, 0 pixels above 2, bbox x 1..1 y 1..1",
                               "t=5s: no Metal 3 baseline pair", "paired 2 of 2 seconds"])

    def test_require_all(self):
        # a run that stopped early: its seconds pair and pass, the missing ones only with --require-all fail
        full = self.run_dir("full", {"sec_000000.png": 0, "sec_000005.png": 0, "sec_000010.png": 0})
        short = self.run_dir("short", {"sec_000000.png": 0, "sec_000005.png": 0})
        self.assertEqual(run_dirs(full, short), (0, ["t=10s: only in " + full, "t=0s: identical", "t=5s: identical",
                                                     "paired 2 of 3 seconds"]))
        self.assertEqual(run_dirs(full, short, "--require-all"),
                         (1, ["t=10s: only in " + full, "t=0s: identical", "t=5s: identical",
                              "paired 2 of 3 seconds (--require-all: some missing)"]))
        self.assertEqual(run_dirs(short, short, "--require-all")[0], 0)

    def test_nothing_paired_fails(self):
        a = self.run_dir("a", {"sec_000000.png": 0})
        b = self.run_dir("b", {"sec_000005.png": 0})
        e = self.run_dir("e", {"frame_000000.png": 0})
        self.assertEqual(run_dirs(a, b)[0], 2)
        self.assertEqual(run_dirs(e, e)[0], 2)
        self.assertEqual(run_dirs(a, os.path.join(self.root, "missing"))[0], 2)
        bad = self.run_dir("bad", {})
        with open(os.path.join(bad, "sec_000000.png"), "wb") as f:
            f.write(b"not a png")
        self.assertEqual(run_dirs(a, bad)[0], 2)


if __name__ == "__main__":
    unittest.main()
