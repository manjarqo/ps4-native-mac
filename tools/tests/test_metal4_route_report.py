# Tests tools/metal4_route_report.py on fixed logs and monitor files.
import os
import subprocess
import sys
import tempfile
import unittest

TOOL = os.path.join(os.path.dirname(__file__), "..", "metal4_route_report.py")

LOG = """[gnm-draw] perf: 10.0 fps over last 300 presents; per frame: 9.0 commits, 1.0 waits, 2.0 ms waiting, 3.0 ms GPU busy, 30.0 ms CP (CPU), 20.0 ms encoder, 0.1 ms screen
[gnm-draw] perf: 60.0 fps over last 300 presents; per frame: 3.0 commits, 0.0 waits, 0.0 ms waiting, 9.0 ms GPU busy, 5.0 ms CP (CPU), 4.0 ms encoder, 0.3 ms screen
[gnm-draw] backend metal4: split commits per frame 0.5; allocators 6 (384 KiB); resident 120 (900 MiB)
[gnm-draw] perf: 50.0 fps over last 300 presents; per frame: 4.0 commits, 0.0 waits, 0.0 ms waiting, 9.0 ms GPU busy, 7.0 ms CP (CPU), 6.0 ms encoder, 0.3 ms screen
[gnm-draw] backend metal4: split commits per frame 1.5; allocators 6 (384 KiB); resident 121 (901 MiB)
[gnm-draw] present #601 from GPU target 0x1000 (1920x1080 fmt 80); totals: draws 100 dispatches 7 skipped 3 shaders 5 pipelines 6 submit 9
[gnm-draw] GPU watchdog: command buffer gnm-5 did not complete in 4000 ms; disabling GPU rendering (fences keep being signaled)
[gnm-residency] ASSERT buffer 0x1234 bound for VS slot 3 is in no residency set
FATAL something
"""
MON = """r start 10:00:00 load { 3.0 2.0 1.0 } WindowServer rss 1 KB
t=5 ws_rss=1 ws_cpu=1 load=4.0 game_rss=1 gpu_err=0 game_cpu=1 other_cpu=10
r stop 10:05:00 (time limit) load { 12.5 11.0 9.0 } WindowServer rss 2 KB
"""


def mem_lines(charged, footprint, peak):
    # The exact shapes printed by the sampler thread (ps4_gpumem_format and the caller's suffix).
    return (
        "[gnm-mem] charged 100/6400 MiB (device 900 MiB incl. no-copy 800 MiB; no-copy buffers 5 covering 700 MiB); "
        "wired 1000 MiB (+10 since start); footprint 300 MiB; peak charged 150 MiB, peak wired 1100 MiB; released 0 windows "
        "(0 MiB), purges 0, large 0, refused 0 too large / 0 with holes / 0 written, copies 0 (0 MiB)\n"
        "[gnm-mem] charged %d/6400 MiB (device 4000 MiB incl. no-copy 1000 MiB; no-copy buffers 9 covering 800 MiB); "
        "wired 3000 MiB (+20 since start); footprint %d MiB; peak charged %d MiB, peak wired 3100 MiB; released 2 windows "
        "(64 MiB), purges 1, large 0, refused 0 too large / 0 with holes / 0 written, copies 3 (12 MiB)\n"
        "[gnm-mem] texture cache at 120 s: sampled 40 (1500 MiB, peak 1600 MiB, budget 4096 MiB), GPU-owned 8 (200 MiB); "
        "evicted 1 (2 MiB), superseded GPU-owned 0 (0 MiB)\n" % (charged, footprint, peak))


def perf(fps, enc, cp, n=1):
    return ("[gnm-draw] perf: %.1f fps over last 300 presents; per frame: 3.0 commits, 0.0 waits, 0.0 ms waiting, "
            "9.0 ms GPU busy, %.1f ms CP (CPU), %.1f ms encoder, 0.3 ms screen\n" % (fps, cp, enc)) * n


def run(*args):
    p = subprocess.run([sys.executable, "-I", TOOL, *args], capture_output=True, text=True)
    return p.returncode, p.stdout.strip(), p.stderr


class RouteReportTest(unittest.TestCase):
    def setUp(self):
        self._d = tempfile.TemporaryDirectory()
        self.d = self._d.name

    def tearDown(self):
        self._d.cleanup()

    def write(self, name, text):
        p = os.path.join(self.d, name)
        with open(p, "w") as f:
            f.write(text)
        return p

    def test_report(self):
        log = self.write("r.log", LOG)
        self.write("r.mon", MON)
        rc, out, err = run(log, "--skip", "1")
        self.assertEqual(rc, 0, err)
        self.assertEqual(out, "fps 55.0 enc_ms 5.0 cp_ms 6.0 commits 3.5 split 1.0 skipped 3 fatal 1 gpu_err 0 "
                              "watchdog 1 flips 601 load 12.5 asserts 1")

    def test_report_without_mon_and_with_gpu_error(self):
        log = self.write("r.log", perf(30, 2, 3) + "[gnm-draw] GPU hang report: x\n")
        rc, out, _ = run(log, "--skip", "0")
        self.assertEqual(rc, 0)
        self.assertIn("gpu_err 1", out)
        self.assertIn("load -1.0 asserts 0", out)
        self.assertIn("split 0.0", out)

    def test_gpu_error_lines_are_the_renderers_own(self):
        # the renderer's failure line (with the GPU time since cc5ca60) counts; a line of another
        # module, or one quoting the phrase, does not
        log = self.write("r.log", perf(30, 2, 3) +
                         "[gnm-draw] command buffer gnm-7 failed after 2.5 ms on the GPU: x\n"
                         "[metal-screen] present command buffer 3 failed: y\n"
                         "note: command buffer gnm-8 failed earlier\n")
        rc, out, _ = run(log, "--skip", "0")
        self.assertEqual(rc, 0)
        self.assertIn("gpu_err 1", out)

    def test_no_perf_lines(self):
        log = self.write("r.log", "nothing\n")
        rc, out, _ = run(log)
        self.assertEqual(rc, 1)
        self.assertIn("no perf lines", out)

    def test_default_skip_is_13(self):
        log = self.write("r.log", perf(10, 1, 1, 13) + perf(40, 2, 3))
        rc, out, _ = run(log)
        self.assertEqual(rc, 0)
        self.assertTrue(out.startswith("fps 40.0 enc_ms 2.0 cp_ms 3.0"), out)

    def test_mem_line_reads_last_total(self):
        log = self.write("r.log", mem_lines(2000, 2500, 2100))
        rc, out, err = run(log, "--mem")
        self.assertEqual(rc, 0, err)
        self.assertEqual(out, "mem charged 2000 budget 6400 device 4000 nocopy 1000 buffers 9 covering 800 wired 3000 "
                              "footprint 2500 peak_charged 2100 peak_wired 3100 tex_count 40 tex_mib 1500 tex_peak 1600")

    def test_mem_without_lines(self):
        rc, out, _ = run(self.write("r.log", "x\n"), "--mem")
        self.assertEqual(rc, 1)
        self.assertIn("no [gnm-mem] charged line", out)

    def test_mem_cmp_within_and_over(self):
        m3 = self.write("m3.log", mem_lines(2000, 1, 1))
        ok = self.write("ok.log", mem_lines(2150, 1, 1))
        bad = self.write("bad.log", mem_lines(2300, 1, 1))
        rc, out, _ = run("--mem-cmp", m3, ok)
        self.assertEqual((rc, out), (0, "mem charged m3 2000 m4 2150 delta +7.5% (limit 10%) ok"))
        rc, out, _ = run("--mem-cmp", m3, bad)
        self.assertEqual((rc, out), (1, "mem charged m3 2000 m4 2300 delta +15.0% (limit 10%) over"))

    def side(self, tag, fpses, enc, cp):
        return [self.write("%s%d.log" % (tag, i), perf(f, enc + i * 0.0, cp)) for i, f in enumerate(fpses)]

    def test_verdict_b_not_worse(self):
        a = self.side("a", [50, 52, 54], 6.0, 8.0)
        b = self.side("b", [55, 56, 57], 5.0, 7.0)
        rc, out, err = run("--verdict", "--skip", "0", "--min-runs", "3", "--a", *a, "--b", *b)
        self.assertEqual(rc, 0, err)
        self.assertIn("fps A median 52.0 range 50.0..54.0 runs 3 B median 56.0 range 55.0..57.0 runs 3", out)
        self.assertIn("B vs A: fps +4.0 (noise ±4.0), encoder ms -1.0 (noise ±0.1), CP ms -1.0 (noise ±0.1); "
                      "fps_ge yes enc_ok yes cp_ok yes; verdict B>=A", out)

    def test_verdict_equal_fps_medians_pass(self):
        a = self.side("a", [50, 52, 54], 6.0, 8.0)
        b = self.side("b", [51, 52, 53], 6.0, 8.0)
        rc, out, _ = run("--verdict", "--skip", "0", "--min-runs", "3", "--a", *a, "--b", *b)
        self.assertEqual(rc, 0, out)
        self.assertIn("fps_ge yes", out)

    def test_verdict_fps_below_is_worse_even_within_noise(self):
        a = self.side("a", [50, 52, 54], 6.0, 8.0)
        b = self.side("b", [50, 51, 52], 6.0, 8.0)
        rc, out, _ = run("--verdict", "--skip", "0", "--min-runs", "3", "--a", *a, "--b", *b)
        self.assertEqual(rc, 1)
        self.assertIn("fps_ge no", out)
        self.assertIn("verdict B<A", out)

    def test_verdict_encoder_above_noise_is_worse(self):
        a = self.side("a", [50, 51, 52], 6.0, 8.0)
        b = self.side("b", [60, 61, 62], 7.0, 8.0)
        rc, out, _ = run("--verdict", "--skip", "0", "--min-runs", "3", "--a", *a, "--b", *b)
        self.assertEqual(rc, 1)
        self.assertIn("enc_ok no cp_ok yes; verdict B<A", out)

    def test_missing_log_is_usage_error(self):
        rc, out, err = run(os.path.join(self.d, "absent.log"))
        self.assertEqual(rc, 2)
        self.assertIn("absent.log", out + err)
        rc, out, err = run("--mem-cmp", os.path.join(self.d, "a.log"), os.path.join(self.d, "b.log"))
        self.assertEqual(rc, 2)

    def test_verdict_reports_dropped_run_and_enforces_min_runs(self):
        a = self.side("a", [50, 52, 54], 6.0, 8.0)
        b = self.side("b", [55, 56], 5.0, 7.0) + [self.write("crashed.log", "boot\n")]
        rc, out, _ = run("--verdict", "--skip", "0", "--min-runs", "3", "--a", *a, "--b", *b)
        self.assertEqual(rc, 1)
        self.assertIn("dropped crashed.log", out)
        self.assertIn("runs kept A 3 B 2", out)
        self.assertIn("fewer than 3", out)

    def test_verdict_default_min_runs_is_5(self):
        a = self.side("a", [50, 52, 54], 6.0, 8.0)
        b = self.side("b", [55, 56, 57], 5.0, 7.0)
        rc, out, _ = run("--verdict", "--skip", "0", "--a", *a, "--b", *b)
        self.assertEqual(rc, 1)
        self.assertIn("fewer than 5", out)

    def test_verdict_fails_on_unclean_run(self):
        a = self.side("a", [50, 52, 54], 6.0, 8.0)
        b = self.side("b", [55, 56, 57], 5.0, 7.0)
        with open(b[1], "a") as f:
            f.write("FATAL boom\n[gnm-draw] GPU watchdog: x\n")
        rc, out, _ = run("--verdict", "--skip", "0", "--min-runs", "3", "--a", *a, "--b", *b)
        self.assertEqual(rc, 1)
        self.assertIn("B fatal 1 gpu_err 0 watchdog 1", out)
        self.assertIn("verdict B<A", out)

    def test_verdict_needs_both_sides(self):
        rc, _, err = run("--verdict", "--a", self.write("a.log", perf(1, 1, 1)))
        self.assertEqual(rc, 2)
        self.assertIn("--a and --b", err)


if __name__ == "__main__":
    unittest.main()
