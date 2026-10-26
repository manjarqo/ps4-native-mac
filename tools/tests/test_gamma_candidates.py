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
