#!/usr/bin/env python3
"""Compare a rendered frame with a reference frame by simple image statistics.

usage: refcompare.py <frame.png> <reference.png> [--crop-ref x,y,w,h] [--crop x,y,w,h]
                     [--json <out.json>] [--max-mean-dy N] [--max-cell-dy N] [--max-hist-l1 F]

Both images are split into a 4x4 grid. For every cell the mean R, G, B and luminance
(Y = 0.2126 R + 0.7152 G + 0.0722 B on the stored 8-bit values) are computed, and for the whole
image a 16-bin luminance histogram (fractions). Printed: per-cell mean luminance and colour of
both images and their difference, the mean and largest |dY| over the cells, and the histogram
L1 distance (0 = identical distributions, 2 = disjoint). The images need not have the same size:
cells are fractions of each image. A pixel-exact match is not expected (camera, compression and
timing differ); the statistics catch exposure, tint and grey-sky errors.

Exit status: 0 within the limits, 1 when a limit is exceeded, 2 on bad input.
Only the Python standard library is used (PNG: 8/16-bit, grey/RGB/palette/alpha, not interlaced).
"""
import argparse
import json
import struct
import sys
import zlib

GRID = 4
BINS = 16


def read_png(path):
    """Returns (width, height, rows) with rows a list of bytes objects, 3 bytes (RGB) per pixel."""
    with open(path, "rb") as f:
        data = f.read()
    if data[:8] != b"\x89PNG\r\n\x1a\n":
        raise ValueError("%s: not a PNG file" % path)
    pos, idat, palette, hdr = 8, [], None, None
    while pos + 8 <= len(data):
        n, typ = struct.unpack(">I4s", data[pos:pos + 8])
        body = data[pos + 8:pos + 8 + n]
        pos += 12 + n
        if typ == b"IHDR":
            hdr = struct.unpack(">IIBBBBB", body)
        elif typ == b"PLTE":
            palette = body
        elif typ == b"IDAT":
            idat.append(body)
        elif typ == b"IEND":
            break
    if hdr is None:
        raise ValueError("%s: no IHDR" % path)
    w, h, depth, ctype, _, _, interlace = hdr
    if interlace or depth not in (8, 16) or ctype not in (0, 2, 3, 4, 6) or (ctype == 3 and depth != 8):
        raise ValueError("%s: unsupported PNG (depth %d, colour type %d, interlace %d)" % (path, depth, ctype, interlace))
    channels = {0: 1, 2: 3, 3: 1, 4: 2, 6: 4}[ctype]
    bpp = channels * depth // 8
    stride = w * bpp
    raw = zlib.decompress(b"".join(idat))
    rows, prev = [], bytearray(stride)
    for y in range(h):
        ft = raw[y * (stride + 1)]
        line = bytearray(raw[y * (stride + 1) + 1:(y + 1) * (stride + 1)])
        if ft == 1:
            for i in range(bpp, stride):
                line[i] = (line[i] + line[i - bpp]) & 255
        elif ft == 2:
            for i in range(stride):
                line[i] = (line[i] + prev[i]) & 255
        elif ft == 3:
            for i in range(stride):
                left = line[i - bpp] if i >= bpp else 0
                line[i] = (line[i] + ((left + prev[i]) >> 1)) & 255
        elif ft == 4:
            for i in range(stride):
                a = line[i - bpp] if i >= bpp else 0
                b = prev[i]
                c = prev[i - bpp] if i >= bpp else 0
                p = a + b - c
                pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
                line[i] = (line[i] + (a if pa <= pb and pa <= pc else b if pb <= pc else c)) & 255
        elif ft != 0:
            raise ValueError("%s: bad filter type %d" % (path, ft))
        prev = line
        step = depth // 8
        if step == 2:  # keep the high byte of 16-bit samples
            line = line[0::2]
        if ctype == 2:
            rgb = bytes(line)
        elif ctype == 6:
            rgb = bytes(b for i, b in enumerate(line) if i % 4 != 3)
        elif ctype == 0:
            rgb = bytes(v for v in line for _ in range(3))
        elif ctype == 4:
            rgb = bytes(v for v in line[0::2] for _ in range(3))
        else:
            rgb = b"".join(palette[3 * v:3 * v + 3] for v in line)
        rows.append(rgb)
    return w, h, rows


def stats(img, crop=None):
    """Per-cell (mean R, G, B, Y) on a GRID x GRID grid and a BINS-bin luminance histogram."""
    w, h, rows = img
    x0, y0, cw, ch = crop if crop else (0, 0, w, h)
    if x0 < 0 or y0 < 0 or cw <= 0 or ch <= 0 or x0 + cw > w or y0 + ch > h:
        raise ValueError("crop %r outside the %dx%d image" % (crop, w, h))
    sums = [[0.0, 0.0, 0.0, 0.0, 0] for _ in range(GRID * GRID)]
    hist = [0] * BINS
    for y in range(y0, y0 + ch):
        row = rows[y]
        gy = (y - y0) * GRID // ch
        for x in range(x0, x0 + cw):
            r, g, b = row[3 * x], row[3 * x + 1], row[3 * x + 2]
            lum = 0.2126 * r + 0.7152 * g + 0.0722 * b
            c = sums[gy * GRID + (x - x0) * GRID // cw]
            c[0] += r
            c[1] += g
            c[2] += b
            c[3] += lum
            c[4] += 1
            hist[min(BINS - 1, int(lum * BINS / 256))] += 1
    cells = [[s[k] / s[4] for k in range(4)] for s in sums]
    total = float(cw * ch)
    return cells, [v / total for v in hist]


def compare(frame, ref):
    fc, fh = frame
    rc, rh = ref
    dy = [fc[i][3] - rc[i][3] for i in range(GRID * GRID)]
    return {
        "cells": [{"frame": [round(v, 2) for v in fc[i]], "reference": [round(v, 2) for v in rc[i]],
                   "dY": round(dy[i], 2)} for i in range(GRID * GRID)],
        "mean_abs_dY": round(sum(abs(d) for d in dy) / len(dy), 2),
        "max_abs_dY": round(max(abs(d) for d in dy), 2),
        "hist_l1": round(sum(abs(a - b) for a, b in zip(fh, rh)), 4),
        "hist_frame": [round(v, 4) for v in fh],
        "hist_reference": [round(v, 4) for v in rh],
    }


def parse_crop(s):
    if not s:
        return None
    v = [int(x) for x in s.split(",")]
    if len(v) != 4:
        raise ValueError("crop must be x,y,w,h")
    return tuple(v)


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("frame")
    ap.add_argument("reference")
    ap.add_argument("--crop", help="x,y,w,h of the frame to compare")
    ap.add_argument("--crop-ref", help="x,y,w,h of the reference to compare (e.g. without borders)")
    ap.add_argument("--json", help="also write the result as JSON")
    ap.add_argument("--max-mean-dy", type=float, default=12.0)
    ap.add_argument("--max-cell-dy", type=float, default=25.0)
    ap.add_argument("--max-hist-l1", type=float, default=0.30)
    a = ap.parse_args(argv)
    try:
        res = compare(stats(read_png(a.frame), parse_crop(a.crop)), stats(read_png(a.reference), parse_crop(a.crop_ref)))
    except (OSError, ValueError, zlib.error) as e:
        print("refcompare: %s" % e, file=sys.stderr)
        return 2
    print("cell  frame Y (R G B)            reference Y (R G B)        dY")
    for i, c in enumerate(res["cells"]):
        f, r = c["frame"], c["reference"]
        print("%d,%d   %6.1f (%5.1f %5.1f %5.1f)   %6.1f (%5.1f %5.1f %5.1f)   %+6.1f" %
              (i // GRID, i % GRID, f[3], f[0], f[1], f[2], r[3], r[0], r[1], r[2], c["dY"]))
    ok = (res["mean_abs_dY"] <= a.max_mean_dy and res["max_abs_dY"] <= a.max_cell_dy and
          res["hist_l1"] <= a.max_hist_l1)
    res["limits"] = {"max_mean_dy": a.max_mean_dy, "max_cell_dy": a.max_cell_dy, "max_hist_l1": a.max_hist_l1}
    res["within_limits"] = ok
    print("mean |dY| %.2f (limit %.1f), max |dY| %.2f (limit %.1f), histogram L1 %.4f (limit %.2f): %s" %
          (res["mean_abs_dY"], a.max_mean_dy, res["max_abs_dY"], a.max_cell_dy, res["hist_l1"], a.max_hist_l1,
           "WITHIN LIMITS" if ok else "OUTSIDE LIMITS"))
    if a.json:
        with open(a.json, "w", encoding="utf-8") as f:
            json.dump(res, f, indent=1)
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
