#!/usr/bin/env python3
"""Where a WAV file has sound: RMS, peak and clipping per window, sound checks, excerpts.

Usage: wav_activity.py <wav> [--window S] [--threshold-db D] [--require-sound A-B]
                       [--onset-after T] [--cut A-B <out.wav>]

Reads PCM16, PCM32 and float32 WAV (plain or WAVE_FORMAT_EXTENSIBLE), any channel count. The
runtime's PS4_AUDIO_DUMP file rewrites its header once per second and at a normal exit, so the
header of a run that was killed, or is still running, names fewer data bytes than the file holds:
then the file size is used, and a note says so.

Prints the duration, then one line per window of S seconds (default 1): its start, RMS in dBFS
over all channels, peak (full scale = 1) and the share of clipped samples (|x| >= 0.999).
  --threshold-db D      the level above which a window has sound (default -50 dBFS)
  --require-sound A-B   exit 1 unless at least 90 % of the S-second windows in [A, B) have sound
                        (time past the end of the file counts as silent)
  --onset-after T       print the start of the first 10 ms window at or after T s with sound
  --cut A-B OUT         write [A, B) to OUT in the input's format, for listening
Times are seconds from the first frame. Exit status: 0, 1 (a check failed), 2 (bad input).
"""
import argparse
import array
import collections
import math
import operator
import os
import struct
import sys

CLIP = 0.999
ONSET_WINDOW = 0.010

Wav = collections.namedtuple("Wav", "path fmt rate channels frames data scale note")
Window = collections.namedtuple("Window", "start rms_db peak clipped")

_TYPECODES = {"pcm16": "h", "pcm32": "i", "float32": "f"}
_SCALES = {"pcm16": 32768.0, "pcm32": 2147483648.0, "float32": 1.0}
_TAGS = {"pcm16": (1, 16), "pcm32": (1, 32), "float32": (3, 32)}


class WavError(Exception):
    pass


def _plausible_chunk(head, room):
    """Whether 8 bytes look like a chunk header (a printable tag and a size that fits in room)."""
    return (len(head) == 8 and all(32 <= b < 127 for b in head[:4]) and
            struct.unpack("<I", head[4:])[0] <= room - 8)


def read_wav(path):
    """Reads a WAV file into a Wav (interleaved samples in an array of the file's sample type)."""
    file_size = os.path.getsize(path)
    with open(path, "rb") as f:
        riff = f.read(12)
        if len(riff) < 12 or riff[:4] != b"RIFF" or riff[8:12] != b"WAVE":
            raise WavError("%s: not a RIFF/WAVE file" % path)
        fmt = None
        while True:
            head = f.read(8)
            if len(head) < 8:
                raise WavError("%s: no data chunk" % path)
            tag, size = head[:4], struct.unpack("<I", head[4:])[0]
            if tag == b"fmt ":
                body = f.read(size)
                if len(body) < 16:
                    raise WavError("%s: short fmt chunk" % path)
                code, channels, rate, _, _, bits = struct.unpack("<HHIIHH", body[:16])
                if code == 0xFFFE and len(body) >= 26:
                    code = struct.unpack("<H", body[24:26])[0]  # the sub-format GUID's first word
                if code == 1 and bits == 16:
                    fmt = "pcm16"
                elif code == 1 and bits == 32:
                    fmt = "pcm32"
                elif code == 3 and bits == 32:
                    fmt = "float32"
                else:
                    raise WavError("%s: unsupported sample format (tag %d, %d-bit); PCM16, PCM32 and "
                                   "float32 are read" % (path, code, bits))
                if channels == 0 or rate == 0:
                    raise WavError("%s: %d channels at %d Hz" % (path, channels, rate))
                if size & 1:
                    f.read(1)
            elif tag == b"data":
                if fmt is None:
                    raise WavError("%s: data before fmt" % path)
                offset = f.tell()
                remain = file_size - offset
                n, note = size, None
                if size > remain or (size == 0 and remain > 0):
                    n = remain
                elif size < remain:
                    # More bytes than the header names: another chunk, or audio written after the
                    # header was last updated.
                    after = size + (size & 1)
                    f.seek(offset + after)
                    if not _plausible_chunk(f.read(8), remain - after):
                        n = remain
                if n != size:
                    note = ("note: the header says %d data bytes, the file holds %d; using the file "
                            "size (the writer did not finish the header: a run that was killed, or "
                            "one still running)" % (size, remain))
                block = channels * _TAGS[fmt][1] // 8
                n -= n % block
                f.seek(offset)
                data = array.array(_TYPECODES[fmt])
                data.frombytes(f.read(n))
                if sys.byteorder == "big":
                    data.byteswap()
                return Wav(path, fmt, rate, channels, n // block, data, _SCALES[fmt], note)
            else:
                f.seek(size + (size & 1), 1)


def _stats(w, a, b):
    """RMS dBFS, peak and clipped share of frames [a, b)."""
    s = w.data[a * w.channels:b * w.channels]
    if not s:
        return -math.inf, 0.0, 0.0
    sq = math.fsum(map(operator.mul, s, s)) if w.fmt == "float32" else sum(map(operator.mul, s, s))
    rms = math.sqrt(sq / len(s)) / w.scale
    mags = list(map(abs, s))
    peak = max(mags) / w.scale
    if w.fmt == "float32":
        clipped = sum(map(CLIP.__le__, mags))
    else:
        clipped = sum(map(int(math.ceil(CLIP * w.scale)).__le__, mags))
    return (20.0 * math.log10(rms) if rms > 0 else -math.inf), peak, clipped / len(s)


def windows(w, seconds, start=0.0, end=None):
    """Windows of `seconds` from `start` to `end` (default: the end of the file). Each window is
    cut at `end`; a window past the end of the file is silent."""
    if seconds <= 0:
        raise WavError("the window must be longer than 0 s")
    end = w.frames / w.rate if end is None else end
    out = []
    k = 0
    while True:
        t = start + k * seconds
        if t >= end - 1e-9:
            break
        a = int(round(t * w.rate))
        b = int(round(min(t + seconds, end) * w.rate))
        a, b = min(a, w.frames), min(b, w.frames)
        out.append(Window(t, *_stats(w, a, b)))
        k += 1
    return out


def onset_after(w, t, threshold_db):
    """Start of the first 10 ms window at or after t s whose RMS is above threshold_db, or None."""
    step = int(round(ONSET_WINDOW * w.rate))
    a = int(round(t * w.rate))
    while a < w.frames:
        if _stats(w, a, min(a + step, w.frames))[0] > threshold_db:
            return a / w.rate
        a += step
    return None


def write_wav(w, path, a, b):
    """Writes frames [a, b) of w to path in w's format."""
    s = w.data[a * w.channels:b * w.channels]
    if sys.byteorder == "big":
        s = array.array(s.typecode, s)
        s.byteswap()
    raw = s.tobytes()
    code, bits = _TAGS[w.fmt]
    block = w.channels * bits // 8
    with open(path, "wb") as f:
        f.write(b"RIFF" + struct.pack("<I", 36 + len(raw)) + b"WAVE")
        f.write(b"fmt " + struct.pack("<IHHIIHH", 16, code, w.channels, w.rate, w.rate * block, block, bits))
        f.write(b"data" + struct.pack("<I", len(raw)) + raw)


def _span(text):
    try:
        a, b = (float(x) for x in text.split("-", 1))
    except ValueError:
        raise argparse.ArgumentTypeError("expected A-B in seconds, got %r" % text)
    if b <= a or a < 0:
        raise argparse.ArgumentTypeError("empty or negative span %r" % text)
    return a, b


def _fmt_db(db):
    return "%8s" % "-inf" if db == -math.inf else "%8.2f" % db


def main(argv=None):
    p = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    p.add_argument("wav")
    p.add_argument("--window", type=float, default=1.0, metavar="S")
    p.add_argument("--threshold-db", type=float, default=-50.0, metavar="D")
    p.add_argument("--require-sound", type=_span, metavar="A-B")
    p.add_argument("--onset-after", type=float, metavar="T")
    p.add_argument("--cut", nargs=2, metavar=("A-B", "OUT"))
    args = p.parse_args(argv)
    try:
        w = read_wav(args.wav)
        rows = windows(w, args.window)
    except (OSError, WavError) as e:
        print("wav_activity: %s" % e, file=sys.stderr)
        return 2
    print("%s: %s, %d ch, %d Hz, %d frames, %.3f s" % (w.path, w.fmt, w.channels, w.rate, w.frames,
                                                      w.frames / w.rate))
    if w.note:
        print(w.note)
    print("  start_s  rms_dbfs    peak  clipped")
    for r in rows:
        print("%9.3f  %s  %6.4f  %6.3f%%" % (r.start, _fmt_db(r.rms_db), r.peak, 100.0 * r.clipped))
    status = 0
    if args.onset_after is not None:
        t = onset_after(w, args.onset_after, args.threshold_db)
        if t is None:
            print("onset after %.3f s: none above %.1f dBFS" % (args.onset_after, args.threshold_db))
            status = 1
        else:
            print("onset after %.3f s: %.3f s" % (args.onset_after, t))
    if args.require_sound:
        a, b = args.require_sound
        span = windows(w, args.window, a, b)
        above = sum(1 for r in span if r.rms_db > args.threshold_db)
        ok = bool(span) and above >= 0.9 * len(span)
        past = " (the file ends at %.3f s)" % (w.frames / w.rate) if b > w.frames / w.rate else ""
        print("require sound %g-%g s: %d of %d windows above %.1f dBFS%s: %s" %
              (a, b, above, len(span), args.threshold_db, past, "OK" if ok else "FAIL"))
        if not ok:
            status = 1
    if args.cut:
        try:
            a, b = _span(args.cut[0])
        except argparse.ArgumentTypeError as e:
            print("wav_activity: --cut: %s" % e, file=sys.stderr)
            return 2
        fa, fb = min(int(round(a * w.rate)), w.frames), min(int(round(b * w.rate)), w.frames)
        write_wav(w, args.cut[1], fa, fb)
        print("cut %.3f-%.3f s (%d frames) to %s" % (fa / w.rate, fb / w.rate, fb - fa, args.cut[1]))
    return status


if __name__ == "__main__":
    sys.exit(main())
