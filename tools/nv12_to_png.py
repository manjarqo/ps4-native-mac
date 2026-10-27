#!/usr/bin/env python3
"""Convert a libSceVideodec picture dump (PS4_VIDEODEC_DUMP) to an RGB PNG.

usage: nv12_to_png.py <dec<n>_pic<i>.nv12> <out.png>

The dump is a 16-byte little-endian header (u16 width, u16 height, u32 pitch, i64 pts) and NV12
as the game received it: the luma plane, pitch bytes per row for align(height, 16) rows, then the
interleaved Cb/Cr plane, pitch bytes per row for half as many rows. Only the width x height
picture is converted, with BT.709 coefficients and limited range (Y 16..235, Cb/Cr 16..240): the
HD default when the SPS carries no colour description, as in the inFAMOUS movies (their VUI has
no video_signal_type). VideoToolbox returns the samples unconverted, so the dump holds the
stream's own Y'CbCr; how the game turns it into RGB is up to the game's shader.

    R = 255/219 (Y-16) + 255/224 * 1.5748 (Cr-128)
    G = 255/219 (Y-16) - 255/224 * (0.1873 (Cb-128) + 0.4681 (Cr-128))
    B = 255/219 (Y-16) + 255/224 * 1.8556 (Cb-128)

rounded and clamped to 0..255. Each chroma sample covers 2x2 luma samples (no interpolation).
Exit status: 0 on success, 2 on bad input. Only the Python standard library is used.
"""
import struct
import sys
import zlib

HEADER = struct.Struct("<HHIq")
KY = 255.0 / 219.0
KC = 255.0 / 224.0


def read_dump(path):
    """Returns (width, height, pitch, pts, luma, chroma) or raises ValueError."""
    with open(path, "rb") as f:
        data = f.read()
    if len(data) < HEADER.size:
        raise ValueError("%s: no header" % path)
    w, h, pitch, pts = HEADER.unpack_from(data)
    ah = (h + 15) & ~15
    luma_size = pitch * ah
    need = HEADER.size + luma_size + luma_size // 2
    if w == 0 or h == 0 or pitch < w or len(data) != need:
        raise ValueError("%s: %ux%u pitch %u needs %u bytes, has %u" % (path, w, h, pitch, need, len(data)))
    luma = memoryview(data)[HEADER.size:HEADER.size + luma_size]
    chroma = memoryview(data)[HEADER.size + luma_size:need]
    return w, h, pitch, pts, luma, chroma


def clamp(v):
    v = int(round(v))
    return 0 if v < 0 else 255 if v > 255 else v


def to_rgb_rows(w, h, pitch, luma, chroma):
    """RGB rows (bytes, 3 per pixel) of the picture."""
    # The colour terms depend only on (Cb, Cr): precomputed per chroma pair of a row.
    ytab = [(y - 16) * KY for y in range(256)]
    rows = []
    for r in range(h):
        lrow = luma[r * pitch:r * pitch + w]
        crow = chroma[(r >> 1) * pitch:(r >> 1) * pitch + w + (w & 1)]
        out = bytearray(3 * w)
        for cx in range(0, w, 2):
            cb = crow[cx] - 128
            cr = crow[cx + 1] - 128
            dr = KC * 1.5748 * cr
            dg = -KC * (0.1873 * cb + 0.4681 * cr)
            db = KC * 1.8556 * cb
            for x in (cx, cx + 1):
                if x >= w:
                    break
                ys = ytab[lrow[x]]
                o = 3 * x
                out[o] = clamp(ys + dr)
                out[o + 1] = clamp(ys + dg)
                out[o + 2] = clamp(ys + db)
        rows.append(bytes(out))
    return rows


def write_png(path, w, h, rows):
    def chunk(tag, body):
        return struct.pack(">I", len(body)) + tag + body + struct.pack(">I", zlib.crc32(tag + body) & 0xFFFFFFFF)

    raw = b"".join(b"\x00" + row for row in rows)
    png = b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0))
    png += chunk(b"IDAT", zlib.compress(raw, 6)) + chunk(b"IEND", b"")
    with open(path, "wb") as f:
        f.write(png)


def main(argv=None):
    argv = sys.argv[1:] if argv is None else argv
    if len(argv) != 2:
        print(__doc__.strip().splitlines()[2], file=sys.stderr)
        return 2
    try:
        w, h, pitch, pts, luma, chroma = read_dump(argv[0])
    except (OSError, ValueError) as e:
        print("nv12_to_png: %s" % e, file=sys.stderr)
        return 2
    write_png(argv[1], w, h, to_rgb_rows(w, h, pitch, luma, chroma))
    print("%s: %ux%u pitch %u pts %d -> %s" % (argv[0], w, h, pitch, pts, argv[1]))
    return 0


if __name__ == "__main__":
    sys.exit(main())
