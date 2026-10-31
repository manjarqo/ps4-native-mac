# Tests tools/metal4_route_report.py on fixed logs and monitor files.
import json
import os
import subprocess
import sys
import tempfile
import unittest

TOOL = os.path.join(os.path.dirname(__file__), "..", "metal4_route_report.py")
# two consecutive perf blocks of a real U4 run (presents 300 and 600; the second is followed by the
# 600-frame percentile line)
TWO_WINDOWS = os.path.join(os.path.dirname(__file__), "data", "perf_two_windows.log")
# a synthetic third window (present 900) with the failure lines the summary counts
SYNTHETIC = ("[gnm-draw] perf: 20.0 fps over last 300 presents; per frame: 9.0 commits, 3.0 waits, 10.0 ms waiting, "
             "30.0 ms GPU busy, 12.0 ms CP (CPU), 14.0 ms encoder, 0.0 ms screen\n"
             "FATAL: something broke\n"
             "[gnm-draw] command buffer gnm-9 failed after 2.5 ms on the GPU: x\n")

LOG = """[gnm-draw] perf: 10.0 fps over last 300 presents; per frame: 9.0 commits, 1.0 waits, 2.0 ms waiting, 3.0 ms GPU busy, 30.0 ms CP (CPU), 20.0 ms encoder, 0.1 ms screen
[gnm-draw] perf: 60.0 fps over last 300 presents; per frame: 3.0 commits, 0.0 waits, 0.0 ms waiting, 9.0 ms GPU busy, 5.0 ms CP (CPU), 4.0 ms encoder, 0.3 ms screen
[gnm-draw] backend metal4: split commits per frame 0.5; allocators 6 (384 KiB); resident 120 (900 MiB)
[gnm-draw] perf: 50.0 fps over last 300 presents; per frame: 4.0 commits, 0.0 waits, 0.0 ms waiting, 9.0 ms GPU busy, 7.0 ms CP (CPU), 6.0 ms encoder, 0.3 ms screen
[gnm-draw] backend metal4: split commits per frame 1.5; allocators 6 (384 KiB); resident 121 (901 MiB)
[gnm-draw] present #301 from GPU target 0x1000 (1920x1080 fmt 80); totals: draws 50 dispatches 3 skipped 1 (pending compile 1) shaders 5 pipelines 6 submit 4
[gnm-draw] skipped by reason: pending-compile 1
[gnm-draw] present #601 from GPU target 0x1000 (1920x1080 fmt 80); totals: draws 100 dispatches 7 skipped 3 (pending compile 2) shaders 5 pipelines 6 submit 9
[gnm-draw] skipped by reason: pending-compile 2, vertex-align 1
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
        self.assertEqual(out, "fps 55.0 enc_ms 5.0 cp_ms 6.0 commits 3.5 split 1.0 skipped 3 pending 2 fatal 1 gpu_err 0 "
                              "watchdog 1 flips 601 load 12.5 asserts 1 reasons pending-compile:2,vertex-align:1")

    def test_reasons_top_three_of_the_last_line(self):
        # the last "skipped by reason" line, its three largest counts (ties in the line's order)
        log = self.write("r.log", perf(30, 2, 3) +
                         "[gnm-draw] skipped by reason: vertex-align 9\n"
                         "[gnm-draw] skipped by reason: pending-compile 137, empty-scissor 11099, cs-pipeline 2145, "
                         "arena 2145, gm-status 3\n")
        rc, out, _ = run(log, "--skip", "0")
        self.assertEqual(rc, 0)
        self.assertTrue(out.endswith(" reasons empty-scissor:11099,cs-pipeline:2145,arena:2145"), out)

    def test_reasons_none_and_absent(self):
        rc, out, _ = run(self.write("n.log", perf(30, 2, 3) + "[gnm-draw] skipped by reason: none\n"), "--skip", "0")
        self.assertEqual(rc, 0)
        self.assertTrue(out.endswith(" reasons none"), out)
        # logs that predate the line
        rc, out, _ = run(self.write("o.log", perf(30, 2, 3)), "--skip", "0")
        self.assertEqual(rc, 0)
        self.assertTrue(out.endswith(" reasons -"), out)

    def test_pending_absent_in_old_logs_is_zero(self):
        old = LOG.replace(" (pending compile 2)", "")
        rc, out, err = run(self.write("o.log", old), "--skip", "1")
        self.assertEqual(rc, 0, err)
        self.assertIn("skipped 3 pending 0 fatal 1", out)

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

    # an inFAMOUS-shaped run: boot lines at 120 fps, the pad script's start marker, then the line
    # that straddles the loading and the gameplay lines
    MARKER = "[pad] script started at 25001 ms\n"

    def marked(self, name, fpses, enc=20.0, cp=100.0):
        return self.write(name, perf(120, 0.2, 0.1, 5) + self.MARKER + perf(18, 30.0, 40.0) +
                          "".join(perf(f, enc, cp) for f in fpses))

    def test_after_marker_skips_the_straddling_line(self):
        log = self.marked("m.log", [8.0, 9.0, 10.0])
        rc, out, err = run(log, "--after-marker")
        self.assertEqual(rc, 0, err)
        self.assertTrue(out.startswith("fps 9.0 enc_ms 20.0 cp_ms 100.0"), out)

    def test_after_marker_replaces_the_skip(self):
        # 9 perf lines in all: the default skip of 13 would leave none
        rc, out, _ = run(self.marked("m.log", [8.0, 9.0, 10.0]), "--after-marker", "--skip", "13")
        self.assertEqual(rc, 0, out)
        self.assertTrue(out.startswith("fps 9.0 "), out)

    def test_after_marker_without_marker_fails(self):
        rc, out, _ = run(self.write("n.log", perf(120, 0.2, 0.1, 5) + perf(9, 20, 100, 4)), "--after-marker")
        self.assertEqual(rc, 1)
        self.assertIn("no [pad] script started line", out)

    def test_after_marker_with_only_the_straddling_line_fails(self):
        rc, out, _ = run(self.marked("s.log", []), "--after-marker")
        self.assertEqual(rc, 1)
        self.assertIn("no perf lines after the marker", out)

    def test_after_marker_only_the_first_marker_counts(self):
        log = self.write("t.log", perf(120, 0.2, 0.1, 2) + self.MARKER + perf(18, 1, 1) + perf(8, 20, 100) +
                         self.MARKER + perf(10, 20, 100))
        rc, out, _ = run(log, "--after-marker")
        self.assertEqual(rc, 0, out)
        self.assertTrue(out.startswith("fps 9.0 "), out)

    def test_verdict_after_marker(self):
        a = [self.marked("a%d.log" % i, [f, f]) for i, f in enumerate([8.0, 8.5, 9.0])]
        b = [self.marked("b%d.log" % i, [f, f]) for i, f in enumerate([12.0, 12.5, 13.0])]
        b.append(self.write("b_nomarker.log", perf(30, 20, 100, 20)))
        rc, out, _ = run("--verdict", "--after-marker", "--min-runs", "3", "--a", *a, "--b", *b)
        self.assertEqual(rc, 0, out)
        self.assertIn("fps A median 8.5 range 8.0..9.0 runs 3 B median 12.5 range 12.0..13.0 runs 3", out)
        self.assertIn("dropped b_nomarker.log: no [pad] script started line", out)

    def test_after_marker_with_a_present_range_is_refused(self):
        log = self.marked("m.log", [8.0, 9.0, 10.0])
        rc, _, err = run(log, "--after-marker", "--from", "0")
        self.assertEqual(rc, 2)
        self.assertIn("--after-marker", err)
        rc, _, err = run("--verdict", "--after-marker", "--to", "900", "--a", log, "--b", log)
        self.assertEqual(rc, 2)
        self.assertIn("--after-marker", err)

    def test_skip_with_a_present_range_is_refused(self):
        log = self.marked("s.log", [8.0, 9.0, 10.0])
        rc, _, err = run(log, "--skip", "0", "--from", "0")
        self.assertEqual(rc, 2)
        self.assertIn("--skip", err)
        rc, _, err = run("--verdict", "--skip", "2", "--to", "900", "--a", log, "--b", log)
        self.assertEqual(rc, 2)
        self.assertIn("--skip", err)
        # the default skip is not an explicit --skip
        rc, _, err = run(log, "--from", "0")
        self.assertEqual(rc, 0, err)

    def test_verdict_needs_both_sides(self):
        rc, _, err = run("--verdict", "--a", self.write("a.log", perf(1, 1, 1)))
        self.assertEqual(rc, 2)
        self.assertIn("--a and --b", err)

    # ---- present-range mode (U4 perf summary) ----

    def real_log(self, extra=""):
        with open(TWO_WINDOWS) as f:
            return self.write("real.log", f.read() + extra)

    def test_range_json_has_the_values_of_the_log(self):
        rc, out, err = run(self.real_log(), "--from", "0", "--to", "99999", "--json")
        self.assertEqual(rc, 0, err)
        j = json.loads(out)
        self.assertEqual([w["present"] for w in j["windows"]], [300, 600])
        self.assertEqual([(w["fps"], w["commits"], w["waits"], w["wait_ms"], w["gpu_ms"], w["cp_ms"], w["enc_ms"])
                          for w in j["windows"]],
                         [(35.6, 8.0, 1.0, 4.6, 22.2, 11.4, 8.8), (35.9, 8.0, 1.0, 4.5, 22.0, 7.6, 8.1)])
        # the percentile line follows the second window
        self.assertEqual([(w["p50"], w["p99"]) for w in j["windows"]], [(None, None), (27.8, 33.7)])
        self.assertEqual((j["fatal"], j["gpu_err"], j["watchdog"]), (0, 0, 0))
        self.assertAlmostEqual(j["fps_mean"], 35.75)
        self.assertEqual((j["fps_min"], j["fps_max"]), (35.6, 35.9))
        self.assertEqual((j["p50"], j["p99"]), (27.8, 33.7))

    def test_range_counts_fatal_and_gpu_errors_of_the_synthetic_block(self):
        rc, out, err = run(self.real_log(SYNTHETIC), "--from", "0", "--to", "99999", "--json")
        self.assertEqual(rc, 0, err)
        j = json.loads(out)
        self.assertEqual(len(j["windows"]), 3)
        self.assertEqual((j["fatal"], j["gpu_err"], j["watchdog"]), (1, 1, 0))
        self.assertEqual(j["windows"][2]["present"], 900)

    def test_range_one_line(self):
        rc, out, err = run(self.real_log(), "--from", "0", "--to", "99999")
        self.assertEqual(rc, 0, err)
        self.assertEqual(out, "fps_mean 35.8 fps_min 35.6 fps_max 35.9 gpu_ms 22.1 cp_ms 9.5 enc_ms 8.4 wait_ms 4.5 "
                              "waits 1.0 p50 27.8 p99 33.7 fatal 0 gpu_err 0 watchdog 0 windows 2 load -1.0 reasons -")

    def test_range_selects_by_present_index(self):
        log = self.real_log()
        rc, out, _ = run(log, "--from", "301", "--to", "600", "--json")
        self.assertEqual((rc, [w["present"] for w in json.loads(out)["windows"]]), (0, [600]))
        rc, out, _ = run(log, "--to", "300", "--json")
        self.assertEqual((rc, [w["present"] for w in json.loads(out)["windows"]]), (0, [300]))
        # the percentiles of a window that has no line after it are -1
        rc, out, _ = run(log, "--to", "300")
        self.assertIn("p50 -1.0 p99 -1.0", out)

    def test_range_past_every_window_is_exit_3(self):
        rc, out, _ = run(self.real_log(), "--from", "601", "--to", "99999")
        self.assertEqual(rc, 3)
        self.assertIn("no perf window", out)
        rc, _, _ = run(self.write("empty.log", "boot\n"), "--from", "0")
        self.assertEqual(rc, 3)

    def test_range_unparsable_perf_line_is_exit_4(self):
        bad = "[gnm-draw] perf: 35.6 fps over last 300 presents; per frame: 8.0 commits, 1.0 waits\n"
        rc, out, _ = run(self.real_log(bad), "--from", "0", "--to", "99999")
        self.assertEqual(rc, 4)
        self.assertIn("line 22", out)
        # also when the bad line is outside the range, and for a frame-times line
        rc, _, _ = run(self.real_log(bad), "--from", "0", "--to", "300")
        self.assertEqual(rc, 4)
        rc, _, _ = run(self.real_log("[gnm-draw] frame times over 600 frames: p50 oops\n"), "--from", "0")
        self.assertEqual(rc, 4)
        # the plain report keeps skipping such lines
        rc, _, _ = run(self.real_log(bad), "--skip", "0")
        self.assertEqual(rc, 0)

    def test_range_does_not_change_the_plain_report(self):
        rc, out, _ = run(self.real_log(), "--skip", "0")
        self.assertEqual(rc, 0)
        self.assertTrue(out.startswith("fps 35.8 enc_ms 8.4 cp_ms 9.5 commits 8.0"), out)

    def test_json_needs_a_range(self):
        rc, _, err = run(self.real_log(), "--json")
        self.assertEqual(rc, 2)
        self.assertIn("--json", err)

    def range_side(self, tag, fpses, gpu, p99):
        out = []
        for i, f in enumerate(fpses):
            text = ""
            for k in range(2): # presents 300 and 600; the percentile line after the second
                text += ("[gnm-draw] perf: %.1f fps over last 300 presents; per frame: 3.0 commits, 0.0 waits, 0.0 ms waiting, "
                         "%.1f ms GPU busy, 5.0 ms CP (CPU), 4.0 ms encoder, 0.3 ms screen\n" % (f, gpu))
            text += "[gnm-draw] frame times over 600 frames: p50 30.0 p95 40.0 p99 %.1f max 90.0 ms; >33ms 1, >50ms 0, >100ms 0\n" % p99
            out.append(self.write("%s%d.log" % (tag, i), text))
        return out

    def verdict(self, a, b, *extra):
        return run("--verdict", "--from", "0", "--to", "99999", "--min-runs", "3", *extra, "--a", *a, "--b", *b)

    def test_range_verdict_faster(self):
        a = self.range_side("a", [50, 51, 52], 20.0, 40.0)
        b = self.range_side("b", [58, 59, 60], 18.0, 35.0)
        rc, out, err = self.verdict(a, b)
        self.assertEqual(rc, 0, err)
        self.assertIn("noise band (larger of the A-vs-A spread and 3%): fps ±2.0, gpu ±0.6, p99 ±1.2", out)
        self.assertIn("VERDICT: B faster (fps +8.0, gpu -2.0 ms, p99 -5.0 ms)", out)
        self.assertIn("fps A median 51.0", out) # the usual lines are still there

    def test_range_verdict_slower_and_within_noise(self):
        a = self.range_side("a", [50, 51, 52], 20.0, 40.0)
        rc, out, _ = self.verdict(a, self.range_side("b", [40, 41, 42], 25.0, 50.0))
        self.assertEqual(rc, 1)
        self.assertIn("VERDICT: B slower (fps -10.0, gpu +5.0 ms, p99 +10.0 ms)", out)
        # +1.0 fps with a 2.0 spread is inside the band; the sign of the other fields does not matter
        rc, out, _ = self.verdict(a, self.range_side("c", [51, 52, 53], 20.0, 40.0))
        self.assertIn("VERDICT: B within noise (fps +1.0, gpu +0.0 ms, p99 +0.0 ms)", out)

    def test_range_verdict_exit_follows_the_word(self):
        a = self.range_side("a", [50, 51, 52], 20.0, 40.0)
        # fps equal but the old encoder rule would fail: the range exit status follows the VERDICT word
        rc, out, _ = self.verdict(a, self.range_side("w", [50, 51, 52], 20.0, 40.0))
        self.assertIn("VERDICT: B within noise", out)
        self.assertEqual(rc, 0)
        self.assertEqual(self.verdict(a, self.range_side("f", [60, 61, 62], 20.0, 40.0))[0], 0)
        self.assertEqual(self.verdict(a, self.range_side("s", [40, 41, 42], 20.0, 40.0))[0], 1)
        # a faster B with a FATAL line is not a pass
        b = self.range_side("u", [60, 61, 62], 20.0, 40.0)
        with open(b[0], "a") as f:
            f.write("FATAL boom\n")
        rc, out, _ = self.verdict(a, b)
        self.assertIn("VERDICT: B faster", out)
        self.assertEqual(rc, 1)
        self.assertIn("not clean", out)

    def test_range_verdict_noise_floor_is_3_percent(self):
        # identical A runs: the band is 3 % of the median (1.5 fps), not 0
        a = self.range_side("a", [50, 50, 50], 20.0, 40.0)
        rc, out, _ = self.verdict(a, self.range_side("b", [51, 51, 51], 20.0, 40.0))
        self.assertIn("fps ±1.5", out)
        self.assertIn("VERDICT: B within noise", out)
        rc, out, _ = self.verdict(a, self.range_side("c", [52, 52, 52], 20.0, 40.0))
        self.assertIn("VERDICT: B faster", out)

    def test_range_verdict_without_percentiles_says_n_a(self):
        a = self.range_side("a", [50, 51, 52], 20.0, 40.0)
        b = [self.write("nb%d.log" % i, perf(60, 4, 5, 2)) for i in range(3)]
        rc, out, _ = self.verdict(a, b)
        self.assertIn("(fps +9.0, gpu -11.0 ms, p99 n/a)", out)

    def test_range_verdict_empty_selection_and_unparsable(self):
        a = self.range_side("a", [50, 51, 52], 20.0, 40.0)
        b = self.range_side("b", [50, 51, 52], 20.0, 40.0)
        rc, out, _ = run("--verdict", "--from", "5000", "--min-runs", "3", "--a", *a, "--b", *b)
        self.assertEqual(rc, 3)
        self.assertIn("dropped a0.log: no perf window", out)
        with open(b[1], "a") as f:
            f.write("[gnm-draw] perf: broken\n")
        rc, out, _ = self.verdict(a, b)
        self.assertEqual(rc, 4)

    # ---- skip reasons of the selected windows (range mode) ----

    def reasons_log(self):
        # the runtime prints cumulative counts after each "present #300k+1" line, i.e. after perf window k
        def present(n, line):
            return ("[gnm-draw] present #%d from GPU target 0x1000 (1920x1080 fmt 80); totals: draws 1 dispatches 1 "
                    "skipped 0 (pending compile 0) shaders 1 pipelines 1 submit 1\n[gnm-draw] skipped by reason: %s\n" %
                    (n, line))
        return self.write("rs.log",
                          present(1, "pending-compile 40") +
                          perf(30, 2, 3) + present(301, "pending-compile 50, empty-scissor 10") +
                          perf(30, 2, 3) + present(601, "pending-compile 50, empty-scissor 110, arena 5") +
                          perf(30, 2, 3) + present(901, "pending-compile 52, empty-scissor 410, arena 5, cs-bind 7, "
                                                        "vertex-align 1"))

    def test_range_reasons_are_the_counts_of_the_selected_windows(self):
        log = self.reasons_log()
        # windows 600 and 900: the counts after window 900 minus those after window 300
        rc, out, err = run(log, "--from", "600", "--to", "900")
        self.assertEqual(rc, 0, err)
        self.assertTrue(out.endswith(" windows 2 load -1.0 reasons empty-scissor:400,cs-bind:7,arena:5"), out)
        # window 300 alone: minus the line printed before the first window (present #1)
        rc, out, _ = run(log, "--from", "300", "--to", "300")
        self.assertTrue(out.endswith(" reasons pending-compile:10,empty-scissor:10"), out)
        # every reason with a count in the JSON
        rc, out, _ = run(log, "--from", "600", "--to", "900", "--json")
        self.assertEqual(json.loads(out)["reasons"],
                         {"pending-compile": 2, "empty-scissor": 400, "arena": 5, "cs-bind": 7, "vertex-align": 1})

    def test_range_reasons_none_and_absent(self):
        log = self.reasons_log()
        with open(log, "a") as f:  # a fourth window without new skips
            f.write(perf(30, 2, 3) + "[gnm-draw] skipped by reason: pending-compile 52, empty-scissor 410, arena 5, "
                    "cs-bind 7, vertex-align 1\n")
        rc, out, _ = run(log, "--from", "1200", "--to", "1200")
        self.assertTrue(out.endswith(" reasons none"), out)
        # logs that predate the line
        rc, out, _ = run(self.real_log(), "--from", "0", "--to", "99999")
        self.assertTrue(out.endswith(" reasons -"), out)
        rc, out, _ = run(self.real_log(), "--from", "0", "--to", "99999", "--json")
        self.assertIsNone(json.loads(out)["reasons"])


if __name__ == "__main__":
    unittest.main()
