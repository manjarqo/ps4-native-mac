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
    # CHOSEN (Task 4/5): the encoded value raised to 1/gamma; best fit to the PS4 reference
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
