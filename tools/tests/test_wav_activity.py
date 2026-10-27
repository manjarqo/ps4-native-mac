# Tests tools/wav_activity.py on generated WAV files.
import array
import math
import os
import struct
import subprocess
import sys
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
TOOL = os.path.join(HERE, "..", "wav_activity.py")
sys.path.insert(0, os.path.join(HERE, ".."))
import wav_activity  # noqa: E402

RATE = 48000


def write_wav(path, samples, channels=2, fmt="float32", rate=RATE, data_size=None):
    """samples: interleaved floats in [-1, 1]. data_size overrides the header's data size."""
    if fmt == "float32":
        tag, bits, data = 3, 32, array.array("f", samples)
    elif fmt == "pcm16":
        tag, bits = 1, 16
        data = array.array("h", (max(-32768, min(32767, int(round(v * 32767)))) for v in samples))
    elif fmt == "pcm32":
        tag, bits = 1, 32
        data = array.array("i", (max(-2**31, min(2**31 - 1, int(round(v * (2**31 - 1))))) for v in samples))
    else:
        raise ValueError(fmt)
    if sys.byteorder == "big":
        data.byteswap()
    raw = data.tobytes()
    size = len(raw) if data_size is None else data_size
    block = channels * bits // 8
    with open(path, "wb") as f:
        f.write(b"RIFF" + struct.pack("<I", 36 + size) + b"WAVE")
        f.write(b"fmt " + struct.pack("<IHHIIHH", 16, tag, channels, rate, rate * block, block, bits))
        f.write(b"data" + struct.pack("<I", size) + raw)


def burst(seconds=4.0, start=2.0, end=3.0, amp=0.5, hz=440.0, channels=2):
    out = []
    for n in range(int(seconds * RATE)):
        t = n / RATE
        v = amp * math.sin(2 * math.pi * hz * (t - start)) if start <= t < end else 0.0
        out.extend([v] * channels)
    return out


class WavActivityTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.dir = tempfile.TemporaryDirectory()
        cls.samples = burst()
        cls.f32 = os.path.join(cls.dir.name, "burst_f32.wav")
        cls.s16 = os.path.join(cls.dir.name, "burst_s16.wav")
        cls.s32 = os.path.join(cls.dir.name, "burst_s32.wav")
        write_wav(cls.f32, cls.samples, fmt="float32")
        write_wav(cls.s16, cls.samples, fmt="pcm16")
        write_wav(cls.s32, cls.samples, fmt="pcm32")

    @classmethod
    def tearDownClass(cls):
        cls.dir.cleanup()

    def run_tool(self, *args):
        return subprocess.run([sys.executable, TOOL] + list(args), capture_output=True, text=True)

    def test_window_rms(self):
        want = 20 * math.log10(0.5 / math.sqrt(2))  # -9.03 dBFS
        for path in (self.f32, self.s16, self.s32):
            w = wav_activity.read_wav(path)
            self.assertEqual((w.rate, w.channels, w.frames), (RATE, 2, 4 * RATE), path)
            self.assertIsNone(w.note)
            rows = wav_activity.windows(w, 1.0)
            self.assertEqual([round(r.start, 3) for r in rows], [0.0, 1.0, 2.0, 3.0])
            for i in (0, 1, 3):
                self.assertEqual(rows[i].rms_db, -math.inf, (path, i))
                self.assertEqual(rows[i].peak, 0.0)
            self.assertAlmostEqual(rows[2].rms_db, want, delta=0.05, msg=path)
            self.assertAlmostEqual(rows[2].peak, 0.5, delta=0.001)
            self.assertEqual(rows[2].clipped, 0.0)

    def test_onset(self):
        for path in (self.f32, self.s16):
            w = wav_activity.read_wav(path)
            t = wav_activity.onset_after(w, 1.0, -50.0)
            self.assertIsNotNone(t)
            self.assertAlmostEqual(t, 2.00, delta=0.01, msg=path)
            self.assertIsNone(wav_activity.onset_after(w, 3.0, -50.0))
        r = self.run_tool(self.f32, "--onset-after", "1")
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertIn("onset after 1.000 s: 2.000 s", r.stdout)

    def test_require_sound(self):
        r = self.run_tool(self.f32, "--require-sound", "2-3")
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        r = self.run_tool(self.s16, "--require-sound", "0-2")
        self.assertEqual(r.returncode, 1, r.stdout + r.stderr)
        self.assertIn("0 of 2 windows", r.stdout)
        # A higher threshold than the burst's level makes it silent too.
        r = self.run_tool(self.f32, "--require-sound", "2-3", "--threshold-db", "-6")
        self.assertEqual(r.returncode, 1, r.stdout + r.stderr)

    def test_listing(self):
        r = self.run_tool(self.f32, "--window", "0.5")
        self.assertEqual(r.returncode, 0, r.stderr)
        lines = r.stdout.splitlines()
        self.assertIn("4.000 s", lines[0])
        rows = [l for l in lines if l.lstrip().startswith(("0.", "1.", "2.", "3."))]
        self.assertEqual(len(rows), 8)
        self.assertIn("-inf", rows[0])
        self.assertIn("-9.0", rows[4])

    def test_clipped_square(self):
        sq = []
        for n in range(RATE):
            sq.extend([1.0 if (n // 50) % 2 == 0 else -1.0] * 2)
        for fmt in ("float32", "pcm16"):
            path = os.path.join(self.dir.name, "square_%s.wav" % fmt)
            write_wav(path, sq, fmt=fmt)
            rows = wav_activity.windows(wav_activity.read_wav(path), 1.0)
            self.assertEqual(len(rows), 1)
            self.assertEqual(rows[0].clipped, 1.0, fmt)
            self.assertAlmostEqual(rows[0].rms_db, 0.0, delta=0.01)
        # half the samples at full scale
        half = [v if i % 4 < 2 else v * 0.5 for i, v in enumerate(sq)]
        path = os.path.join(self.dir.name, "half.wav")
        write_wav(path, half)
        self.assertAlmostEqual(wav_activity.windows(wav_activity.read_wav(path), 1.0)[0].clipped, 0.5)

    def test_stale_header(self):
        path = os.path.join(self.dir.name, "killed.wav")
        write_wav(path, self.samples, data_size=0)
        w = wav_activity.read_wav(path)
        self.assertEqual(w.frames, 4 * RATE)
        self.assertIn("file size", w.note)
        r = self.run_tool(path, "--require-sound", "2-3")
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertIn("file size", r.stdout)
        # a header one second behind the file (the dump rewrites it once per second)
        path = os.path.join(self.dir.name, "behind.wav")
        write_wav(path, self.samples, data_size=3 * RATE * 8)
        w = wav_activity.read_wav(path)
        self.assertEqual(w.frames, 4 * RATE)
        self.assertIsNotNone(w.note)

    def test_cut_round_trip(self):
        for path, fmt in ((self.f32, "float32"), (self.s16, "pcm16")):
            out = os.path.join(self.dir.name, "cut_%s.wav" % fmt)
            r = self.run_tool(path, "--cut", "2-3", out)
            self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
            src = wav_activity.read_wav(path)
            cut = wav_activity.read_wav(out)
            self.assertEqual((cut.fmt, cut.rate, cut.channels, cut.frames), (src.fmt, RATE, 2, RATE))
            self.assertIsNone(cut.note)
            self.assertEqual(cut.data.tolist(), src.data[2 * RATE * 2:3 * RATE * 2].tolist())

    def test_rejects_other_formats(self):
        path = os.path.join(self.dir.name, "u8.wav")
        with open(path, "wb") as f:
            f.write(b"RIFF" + struct.pack("<I", 40) + b"WAVE")
            f.write(b"fmt " + struct.pack("<IHHIIHH", 16, 1, 1, 8000, 8000, 1, 8))
            f.write(b"data" + struct.pack("<I", 4) + b"\x80\x80\x80\x80")
        r = self.run_tool(path)
        self.assertEqual(r.returncode, 2)
        self.assertIn("8-bit", r.stderr)


if __name__ == "__main__":
    unittest.main()
