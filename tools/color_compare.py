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
# hue is undefined for a neutral region: skip the h check when both regions have mean C* below this
NEUTRAL_C = 5.0

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
    if "h" in limits and not (ours["C"] < NEUTRAL_C and ref["C"] < NEUTRAL_C):
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
    except Exception as e:  # any load or structure failure is bad input (exit 2), never a traceback
        print("color_compare: %s: %s" % (type(e).__name__, e), file=sys.stderr)
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
