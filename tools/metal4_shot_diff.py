#!/usr/bin/env python3
"""Per-pixel comparison of two screenshots (docs/metal4-backend.md, "Screenshot parity").

usage: metal4_shot_diff.py <a.png> <b.png> [--threshold T | --baseline <m3_a.png> <m3_b.png>]
       metal4_shot_diff.py --dirs <dir_a> <dir_b> [--threshold T | --baseline <m3_dir_a> <m3_dir_b>] [--require-all]

Compares the 8-bit RGB of each pixel. Prints "identical", or how many pixels differ (and what
share of the image), the largest channel difference, how many pixels differ by more than T in
some channel, and the bounding box of the differing pixels. Without --threshold T is 0.

--baseline derives T from two Metal 3 screenshots of the same checkpoint: the largest per-pixel
channel difference between them (the Metal 3 run-to-run noise). An explicit --threshold wins.

--dirs pairs the time-cadence screenshots of two runs (PS4_SCREENSHOT_EVERY_SEC: sec_<s>.png, the
first flip at or after s seconds of wall time from the first flip) by their time index s; other
files (frame_*.png, debug requests sec_*_req.png) are ignored. With --baseline the two Metal 3
directories give T per index; an index without a Metal 3 pair is reported and fails. One line
per index found in both directories, then "paired N of M seconds" (M: found in either). An index
found in only one is listed and does not fail, unless --require-all (a run that stopped early).

Exit status 0: identical or no pixel above T (--dirs: for every paired index); 1: some pixel
above T, or the sizes differ; 2: no index in both directories (--dirs), an input is missing, is not a usable PNG, has no pixels, is 16 bits per channel (the low byte
would be dropped silently), or T is outside 0..255. An empty comparison never passes. Alpha is
not compared; when an input has alpha, the "identical" line says so.

Parity rule (screenshot parity; replay parity is a separate, byte-exact rule):
a Metal 3 vs Metal 4 difference is allowed only up to the Metal 3 run-to-run difference, and
each such effect is named. This tool does NOT enforce the naming: it cannot tell which effect
causes a difference. It also cannot tell a T taken from a real Metal 3 pair from one chosen to
make a Metal 4 comparison pass, unless --baseline is used; the reviewer must name the effects.
"""
import argparse
import os
import re
import struct
import sys
import zlib

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from refcompare import read_png  # noqa: E402


def header(path):
    with open(path, "rb") as f:
        h = f.read(26)
    return h[24], h[25]  # bit depth, colour type (read_png has already validated the file)


def load(path):
    try:
        w, h, rows = read_png(path)
        depth, ctype = header(path)
    except (OSError, ValueError, zlib.error, struct.error, KeyError) as e:
        sys.stderr.write("metal4_shot_diff: %s\n" % (e if isinstance(e, ValueError) else "%s: %s" % (path, e)))
        return None
    if w <= 0 or h <= 0 or len(rows) != h or any(len(r) != 3 * w for r in rows):
        sys.stderr.write("metal4_shot_diff: %s: empty or malformed image (%dx%d)\n" % (path, w, h))
        return None
    if depth == 16:
        sys.stderr.write("metal4_shot_diff: %s: 16 bits per channel is not supported (the low byte would not be compared)\n" % path)
        return None
    return w, h, rows, ctype in (4, 6)


def diff(ra, rb, w, thr):
    """Returns (differing pixels, max channel diff, pixels above thr, bounding box or None)."""
    n = above = mx = 0
    x0 = y0 = 1 << 30
    x1 = y1 = -1
    for y, (la, lb) in enumerate(zip(ra, rb)):
        if la == lb:
            continue
        for x in range(w):
            d = max(abs(la[3 * x + k] - lb[3 * x + k]) for k in range(3))
            if d:
                n += 1
                mx = max(mx, d)
                above += d > thr
                x0, x1, y0, y1 = min(x0, x), max(x1, x), min(y0, y), y
    return n, mx, above, (x0, y0, x1, y1) if n else None


SHOT = re.compile(r"^sec_(\d+)\.png$")


def time_shots(d):
    """{time index: path} of the sec_<s>.png files in directory d (None if d is not a directory)."""
    if not os.path.isdir(d):
        return None
    out = {}
    for name in os.listdir(d):
        m = SHOT.match(name)
        if m:
            out[int(m.group(1))] = os.path.join(d, name)
    return out


def compare_pair(pa, pb, thr, baseline, say):
    """Compares the images at pa and pb; say(line) reports. Returns the exit status of one pair."""
    a, b = load(pa), load(pb)
    if a is None or b is None:
        return 2
    if baseline:
        ba, bb = load(baseline[0]), load(baseline[1])
        if ba is None or bb is None:
            return 2
        if ba[:2] != bb[:2] or ba[:2] != a[:2]:
            sys.stderr.write("metal4_shot_diff: baseline images and compared images must have the same size\n")
            return 2
        bn, bmx, _, _ = diff(ba[2], bb[2], ba[0], 0)
        say("baseline: %d pixels differ, max channel diff %d" % (bn, bmx))
        if thr is None:
            thr = bmx
    if thr is None:
        thr = 0
    (wa, ha, ra, aa), (wb, hb, rb, ab) = a, b
    if (wa, ha) != (wb, hb):
        say("size differs: %dx%d vs %dx%d" % (wa, ha, wb, hb))
        return 1
    n, mx, above, box = diff(ra, rb, wa, thr)
    if not n:
        say("identical" + (" (alpha not compared)" if aa or ab else ""))
        return 0
    say("differ: %d pixels (%.2f%%), max channel diff %d, %d pixels above %d, bbox x %d..%d y %d..%d" %
        (n, 100.0 * n / (wa * ha), mx, above, thr, box[0], box[2], box[1], box[3]))
    return 0 if above == 0 else 1


def compare_dirs(o, thr):
    a, b = time_shots(o.a), time_shots(o.b)
    if a is None or b is None:
        sys.stderr.write("metal4_shot_diff: --dirs takes two directories\n")
        return 2
    base = None
    if o.baseline:
        base = (time_shots(o.baseline[0]), time_shots(o.baseline[1]))
        if base[0] is None or base[1] is None:
            sys.stderr.write("metal4_shot_diff: --baseline with --dirs takes two directories\n")
            return 2
    for k in sorted(set(a) ^ set(b)):
        print("t=%ds: only in %s" % (k, o.a if k in a else o.b))
    both = sorted(set(a) & set(b))
    if not both:
        sys.stderr.write("metal4_shot_diff: no time index in both directories\n")
        return 2
    worst = 0
    if o.require_all and len(both) != len(set(a) | set(b)):
        worst = 1
    for k in both:
        pair_base = None
        if base is not None:
            if k not in base[0] or k not in base[1]:
                print("t=%ds: no Metal 3 baseline pair" % k)
                worst = max(worst, 1)
                continue
            pair_base = (base[0][k], base[1][k])
        lines = []
        rc = compare_pair(a[k], b[k], thr, pair_base, lines.append)
        print("t=%ds: %s" % (k, "; ".join(lines) if lines else "unreadable"))
        worst = max(worst, rc)
    print("paired %d of %d seconds%s" % (len(both), len(set(a) | set(b)),
                                         " (--require-all: some missing)" if o.require_all and len(both) != len(set(a) | set(b)) else ""))
    return worst


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("a")
    ap.add_argument("b")
    ap.add_argument("--threshold", type=int)
    ap.add_argument("--baseline", nargs=2, metavar=("M3_A", "M3_B"))
    ap.add_argument("--dirs", action="store_true")
    ap.add_argument("--require-all", action="store_true", help="--dirs: fail when a second is in one run only")
    o = ap.parse_args()
    thr = o.threshold
    if thr is not None and not 0 <= thr <= 255:
        sys.stderr.write("metal4_shot_diff: --threshold must be in 0..255\n")
        return 2
    if o.dirs:
        return compare_dirs(o, thr)
    return compare_pair(o.a, o.b, thr, o.baseline, print)


if __name__ == "__main__":
    sys.exit(main())
