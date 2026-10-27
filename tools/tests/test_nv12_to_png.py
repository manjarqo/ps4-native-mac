#!/usr/bin/env python3
"""Tests for tools/nv12_to_png.py: synthetic NV12 dumps of known Y/Cb/Cr bars against RGB values
computed by hand from BT.709 limited range (Y 16..235, Cb/Cr 16..240)."""
import contextlib
import io
import os
import struct
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
import nv12_to_png  # noqa: E402
import refcompare  # noqa: E402

# (Y, Cb, Cr) -> RGB, by hand: R = 255/219 (Y-16) + 255/224 * 1.5748 (Cr-128),
# G = 255/219 (Y-16) - 255/224 (0.1873 (Cb-128) + 0.4681 (Cr-128)), B = 255/219 (Y-16) + 255/224 * 1.8556 (Cb-128),
# rounded and clamped.
BARS = [
    ((16, 128, 128), (0, 0, 0)),          # black
    ((235, 128, 128), (255, 255, 255)),   # white
    ((126, 128, 128), (128, 128, 128)),   # mid grey: 110 * 255/219 = 128.08
    # The primaries, encoded by hand (Y = 16 + 219 Kr/Kg/Kb, Cb/Cr = 128 + 224 * scaled difference,
    # rounded), decode to within 2 of pure red, green and blue: e.g. red (63, 102, 240) gives
    # R 54.7 + 200.8 -> 255, G 54.7 - 54.1 = 0.6 -> 1, B 54.7 - 54.9 -> 0.
    ((63, 102, 240), (255, 0, 0)),
    ((173, 42, 26), (0, 255, 0)),
    ((32, 240, 118), (0, 0, 255)),
]


def dump_bytes(w, h, pitch, pts, bars):
    """An NV12 dump as Videodec writes it: vertical bars of equal width, rows padded to pitch."""
    ah = (h + 15) & ~15
    y_plane = bytearray(pitch * ah)
    uv_plane = bytearray(pitch * ah // 2)
    bw = w // len(bars)
    for r in range(ah):
        for x in range(w):
            y_plane[r * pitch + x] = bars[min(x // bw, len(bars) - 1)][0][0]
    for r in range(ah // 2):
        for x in range(0, w, 2):
            (_, cb, cr) = bars[min(x // bw, len(bars) - 1)][0]
            uv_plane[r * pitch + x] = cb
            uv_plane[r * pitch + x + 1] = cr
    return struct.pack("<HHIq", w, h, pitch, pts) + bytes(y_plane) + bytes(uv_plane)


def expected(ycbcr):
    """The formula of the docstring, written out independently of the tool."""
    y, cb, cr = ycbcr
    ys = (y - 16) * 255.0 / 219.0
    cs = 255.0 / 224.0
    r = ys + cs * 1.5748 * (cr - 128)
    g = ys - cs * (0.1873 * (cb - 128) + 0.4681 * (cr - 128))
    b = ys + cs * 1.8556 * (cb - 128)
    return tuple(max(0, min(255, int(round(v)))) for v in (r, g, b))


class Nv12ToPngTest(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.mkdtemp()

    def tearDown(self):
        for n in os.listdir(self.dir):
            os.unlink(os.path.join(self.dir, n))
        os.rmdir(self.dir)

    def convert(self, w, h, pitch, bars):
        src = os.path.join(self.dir, "dec1_pic5.nv12")
        out = os.path.join(self.dir, "out.png")
        with open(src, "wb") as f:
            f.write(dump_bytes(w, h, pitch, 15015, bars))
        with contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(nv12_to_png.main([src, out]), 0)
        return refcompare.read_png(out)

    def test_hand_computed_bars(self):
        # The hand values in BARS agree with the formula (a check of the test itself).
        self.assertEqual([expected(b[0]) for b in BARS[:3]], [b[1] for b in BARS[:3]])
        w, h, pitch = 96, 20, 128  # pitch > width, height not a multiple of 16
        img_w, img_h, rows = self.convert(w, h, pitch, BARS)
        self.assertEqual((img_w, img_h), (w, h))
        bw = w // len(BARS)
        for i, (ycbcr, hand) in enumerate(BARS):
            x = i * bw + bw // 2
            for y in (0, h - 1):
                px = tuple(rows[y][3 * x:3 * x + 3])
                self.assertEqual(px, expected(ycbcr), "bar %d at row %d" % (i, y))
                for c in range(3):
                    self.assertLessEqual(abs(px[c] - hand[c]), 2, "bar %d channel %d: %s vs %s" % (i, c, px, hand))

    def test_header_and_size_checked(self):
        src = os.path.join(self.dir, "bad.nv12")
        with open(src, "wb") as f:
            f.write(dump_bytes(32, 16, 64, 0, BARS[:1])[:-1])  # one byte short
        with contextlib.redirect_stderr(io.StringIO()):
            self.assertEqual(nv12_to_png.main([src, os.path.join(self.dir, "x.png")]), 2)


if __name__ == "__main__":
    unittest.main()
