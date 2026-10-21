#!/usr/bin/env python3
"""Tests for tools/refcompare.py with PNGs written here (every filter type, colour types, crops)."""
import json
import os
import shutil
import struct
import sys
import tempfile
import unittest
import zlib

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
import refcompare  # noqa: E402


def png_bytes(w, h, pixel, ctype=2, filters=(0,), palette=None):
    """PNG of w x h; pixel(x, y) -> tuple of channel values for the colour type."""
    channels = {0: 1, 2: 3, 3: 1, 6: 4}[ctype]
    bpp = channels
    raw = bytearray()
    prev = bytearray(w * bpp)
    for y in range(h):
        line = bytearray()
        for x in range(w):
            line.extend(pixel(x, y))
        ft = filters[y % len(filters)]
        out = bytearray(line)
        for i in range(len(line)):
            a = line[i - bpp] if i >= bpp else 0
            b = prev[i]
            c = prev[i - bpp] if i >= bpp else 0
            if ft == 1:
                out[i] = (line[i] - a) & 255
            elif ft == 2:
                out[i] = (line[i] - b) & 255
            elif ft == 3:
                out[i] = (line[i] - ((a + b) >> 1)) & 255
            elif ft == 4:
                p = a + b - c
                pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
                out[i] = (line[i] - (a if pa <= pb and pa <= pc else b if pb <= pc else c)) & 255
        raw.append(ft)
        raw.extend(out)
        prev = line

    def chunk(t, d):
        return struct.pack(">I", len(d)) + t + d + struct.pack(">I", zlib.crc32(t + d) & 0xffffffff)
    data = b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, ctype, 0, 0, 0))
    if palette:
        data += chunk(b"PLTE", palette)
    return data + chunk(b"IDAT", zlib.compress(bytes(raw))) + chunk(b"IEND", b"")


class RefCompareTest(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.mkdtemp(prefix="refcompare_test")

    def tearDown(self):
        shutil.rmtree(self.dir)

    def write(self, name, data):
        p = os.path.join(self.dir, name)
        with open(p, "wb") as f:
            f.write(data)
        return p

    def test_decoder_all_filters_and_types(self):
        def grad(x, y):
            return ((x * 37 + y) & 255, (y * 11) & 255, (x ^ y) & 255)
        p = self.write("f.png", png_bytes(9, 10, grad, filters=(0, 1, 2, 3, 4)))
        w, h, rows = refcompare.read_png(p)
        self.assertEqual((w, h), (9, 10))
        for y in range(h):
            for x in range(w):
                self.assertEqual(tuple(rows[y][3 * x:3 * x + 3]), grad(x, y))
        g = refcompare.read_png(self.write("g.png", png_bytes(2, 1, lambda x, y: (100 + x,), ctype=0)))
        self.assertEqual(g[2][0], bytes([100, 100, 100, 101, 101, 101]))
        a = refcompare.read_png(self.write("a.png", png_bytes(1, 1, lambda x, y: (1, 2, 3, 9), ctype=6)))
        self.assertEqual(a[2][0], bytes([1, 2, 3]))
        pal = refcompare.read_png(self.write("p.png", png_bytes(2, 1, lambda x, y: (x,), ctype=3,
                                                                  palette=bytes([0, 0, 0, 10, 20, 30]))))
        self.assertEqual(pal[2][0], bytes([0, 0, 0, 10, 20, 30]))

    def test_same_image_is_within_limits(self):
        p = self.write("s.png", png_bytes(16, 8, lambda x, y: (x * 16, y * 32, 128)))
        out = os.path.join(self.dir, "r.json")
        self.assertEqual(refcompare.main([p, p, "--json", out]), 0)
        with open(out, encoding="utf-8") as f:
            r = json.load(f)
        self.assertEqual(r["max_abs_dY"], 0)
        self.assertEqual(r["hist_l1"], 0)
        self.assertTrue(r["within_limits"])

    def test_washed_out_frame_is_outside_limits(self):
        dark = self.write("d.png", png_bytes(16, 16, lambda x, y: (40, 40, 60)))
        bright = self.write("b.png", png_bytes(16, 16, lambda x, y: (200, 200, 200)))
        out = os.path.join(self.dir, "r.json")
        self.assertEqual(refcompare.main([bright, dark, "--json", out]), 1)
        with open(out, encoding="utf-8") as f:
            r = json.load(f)
        self.assertAlmostEqual(r["cells"][0]["dY"], 200 - (0.2126 * 40 + 0.7152 * 40 + 0.0722 * 60), places=1)
        self.assertEqual(r["hist_l1"], 2.0)

    def test_cells_are_fractions_and_crop(self):
        # left half black, right half white, at two sizes: same cells
        def half(w):
            return lambda x, y: (0, 0, 0) if x < w // 2 else (255, 255, 255)
        small = self.write("s.png", png_bytes(8, 4, half(8)))
        big = self.write("b.png", png_bytes(32, 12, half(32)))
        self.assertEqual(refcompare.main([small, big]), 0)
        # reference with a 4-pixel red border: within limits only once cropped away
        def bordered(x, y):
            if x < 4 or y < 4 or x >= 36 or y >= 16:
                return (255, 0, 0)
            return half(32)(x - 4, y - 4)
        ref = self.write("r.png", png_bytes(40, 20, bordered))
        self.assertEqual(refcompare.main([big, ref]), 1)
        self.assertEqual(refcompare.main([big, ref, "--crop-ref", "4,4,32,12"]), 0)
        self.assertEqual(refcompare.main([big, ref, "--crop-ref", "30,4,32,12"]), 2)

    def test_bad_input(self):
        self.assertEqual(refcompare.main([self.write("x.png", b"not a png"), self.write("y.png", b"")]), 2)


if __name__ == "__main__":
    unittest.main()
