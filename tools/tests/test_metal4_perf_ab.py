# Tests tools/metal4_perf_ab.sh with a stub route (ROUTE=): the pair loop, its ends and the
# drop rules (load, other_cpu spikes, a pair's background mismatch).
import os
import stat
import subprocess
import tempfile
import textwrap
import unittest

TOOL = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "metal4_perf_ab.sh")

# The stub route: writes $OUT/$TAG.log (20 perf lines, so that some remain after the report's
# skip; with MARKED=1 an inFAMOUS-shaped log of 10 perf lines around a pad script marker) and $OUT/$TAG.mon (10 samples) from the plan line of its tag ("tag fps load cpu spikes";
# default 70 fps, load 9, other_cpu 50, no spikes), and appends its tag to $OUT/runs.txt.
STUB = textwrap.dedent('''\
    #!/bin/bash
    set -u
    read -r fps load cpu spikes < <(awk -v t="$TAG" '$1 == t {print $2, $3, $4, $5}' "$PLAN")
    fps=${fps:-70}; load=${load:-9}; cpu=${cpu:-50}; spikes=${spikes:-0}
    echo "$TAG" >> "$OUT/runs.txt"
    echo "$TAG $CACHE" >> "$OUT/caches.txt"
    mkdir -p "$CACHE" && touch "$CACHE/shader.bin"
    echo "$*" >> "$OUT/args.txt"
    line() { echo "[gnm-draw] perf: $1 fps over last 300 presents; per frame: 3.0 commits, 0.0 waits, 0.0 ms waiting, 9.0 ms GPU busy, 7.0 ms CP (CPU), 13.0 ms encoder, 0.3 ms screen"; }
    if [ -n "${MARKED:-}" ]; then
      { for i in $(seq 5); do line 120; done; echo "[pad] script started at 25001 ms"; line 18
        for i in $(seq 4); do line "$fps"; done; } > "$OUT/$TAG.log"
    else
      for i in $(seq 20); do line "$fps"; done > "$OUT/$TAG.log"
    fi
    {
      echo "$TAG start 10:00:00 load { 1.0 1.0 1.0 } WindowServer rss 1 KB metal $METAL"
      for i in $(seq 10); do
        c=$cpu; [ $i -le $spikes ] && c=400
        echo "t=$((i * 5)) ws_rss=1 ws_cpu=1 load=$load gpu_err=0 other_cpu=$c"
      done
      echo "$TAG stop 10:03:00 (time limit) load { $load 1.0 1.0 } WindowServer rss 1 KB"
    } > "$OUT/$TAG.mon"
    ''')


# The U4 stub route: like STUB, but the first 10 perf windows (presents 300..3000) run at 10 fps and
# the last 10 at the plan's fps; it records what the A/B script handed to it.
STUB_U4 = textwrap.dedent('''\
    #!/bin/bash
    set -u
    read -r fps < <(awk -v t="$TAG" '$1 == t {print $2}' "$PLAN")
    fps=${fps:-70}
    mkdir -p "$CACHE" && touch "$CACHE/shader.bin"
    echo "$TAG $CACHE" >> "$OUT/caches.txt"
    echo "$TAG BUILD=$BUILD METAL=${METAL-unset} ROUTE_KIND=${ROUTE_KIND-unset} SECS=$SECS" >> "$OUT/env.txt"
    for i in $(seq 20); do
      f=$fps; [ $i -le 10 ] && f=10
      echo "[gnm-draw] perf: $f fps over last 300 presents; per frame: 3.0 commits, 1.0 waits, 2.0 ms waiting, 9.0 ms GPU busy, 7.0 ms CP (CPU), 13.0 ms encoder, 0.3 ms screen"
      [ $((i % 2)) = 0 ] && echo "[gnm-draw] frame times over 600 frames: p50 30.0 p95 40.0 p99 45.0 max 90.0 ms; >33ms 1, >50ms 0, >100ms 0"
    done > "$OUT/$TAG.log"
    {
      echo "$TAG start 10:00:00 load { 1.0 1.0 1.0 } WindowServer rss 1 KB"
      for i in $(seq 10); do echo "t=$((i * 5)) ws_rss=1 ws_cpu=1 load=9 gpu_err=0 other_cpu=50"; done
      echo "$TAG stop 10:03:00 (time limit) load { 9.0 1.0 1.0 } WindowServer rss 1 KB"
    } > "$OUT/$TAG.mon"
    ''')
# stands in for heavy_lock.sh: records the lock mode and runs the command
LOCK_STUB = textwrap.dedent('''\
    #!/bin/bash
    echo "lock HEAVY_EXCLUSIVE=${HEAVY_EXCLUSIVE-unset} $*" >> "$OUT/lock.txt"
    exec "$@"
    ''')


class PerfAbTest(unittest.TestCase):
    def setUp(self):
        self._d = tempfile.TemporaryDirectory()
        self.addCleanup(self._d.cleanup)
        self.d = self._d.name
        self.stub = os.path.join(self.d, "route_stub.sh")
        with open(self.stub, "w") as f:
            f.write(STUB)
        os.chmod(self.stub, stat.S_IRWXU)

    def ab(self, plan, n=3, extra=(), env=None):
        with open(os.path.join(self.d, "plan.txt"), "w") as f:
            f.write(plan)
        env_extra = env
        env = dict(os.environ, ROUTE=self.stub, PLAN=os.path.join(self.d, "plan.txt"), OUT=self.d, PAUSE="0",
                   N=str(n), A="/a:4", B="/b:4", TAG="t", SECS="10")
        env.pop("REPORT_ARGS", None)
        env.update(env_extra or {})
        p = subprocess.run(["/bin/bash", TOOL, *extra], env=env, capture_output=True, text=True, timeout=60)
        with open(os.path.join(self.d, "runs.txt")) as f:
            runs = f.read().split()
        return p.returncode, p.stdout, p.stderr, runs

    def test_all_kept(self):
        code, out, err, runs = self.ab("")
        self.assertEqual(runs, ["t_Aw", "t_Bw", "t_A1", "t_B1", "t_A2", "t_B2", "t_A3", "t_B3"])
        self.assertIn("A kept 3: t_A1 t_A2 t_A3", out)
        self.assertIn("other_cpu medians: A 50 50 50; B 50 50 50", out)
        self.assertEqual(code, 0, out + err)

    def test_trailing_arguments_reach_every_route_run(self):
        code, out, err, runs = self.ab("", n=1, extra=("PS4_UPSCALE=metalfx", "X=1"))
        with open(os.path.join(self.d, "args.txt")) as f:
            args = f.read().splitlines()
        self.assertEqual(len(args), len(runs))
        self.assertTrue(all(a == "PS4_UPSCALE=metalfx X=1" for a in args), args)
        self.assertEqual(code, 0, out + err)

    def test_report_args_reach_every_report_call(self):
        # an inFAMOUS-shaped log (MARKED=1): 5 boot lines at 120 fps, the pad script's marker, the
        # straddling line, then 4 lines at the plan's fps. 10 perf lines: the report's default skip
        # of 13 keeps none, so without REPORT_ARGS every run is dropped.
        code, out, err, runs = self.ab("t_B1 30 9 50 0\nt_B2 30 9 50 0\n", n=2,
                                       env={"MARKED": "1", "REPORT_ARGS": "--after-marker"})
        self.assertIn("t_A1: fps 70.0 ", err)
        self.assertIn("t_B1: fps 30.0 ", err)
        self.assertIn("fps A median 70.0 range 70.0..70.0 runs 2 B median 30.0", out)
        self.assertEqual(code, 1, out + err)  # B is slower: the verdict, not a dropped side
        self.assertNotIn("fewer than", out)
        code, out, err, runs = self.ab("", n=1, env={"MARKED": "1"})
        self.assertIn("t_A1: no report", err)
        self.assertEqual(code, 1)

    def test_one_side_always_dropped_ends(self):
        # B over the load limit every time: the old loop never ended once A had its N runs
        plan = "".join("t_B%d 70 20 50 0\n" % i for i in range(1, 7))
        code, out, err, runs = self.ab(plan)
        self.assertEqual(code, 1)
        self.assertIn("fewer than 3 kept runs per side", out)
        # pair 4 cannot leave 3 reachable (0 kept + 3 left after it = 3: still tried); after
        # pair 4 fails, 0 + 2 < 3: stop
        self.assertEqual(runs[-2:], ["t_A4", "t_B4"])
        self.assertIn("t_B1: discarded (load '20.0')", err)

    def test_background_mismatch_repeats_the_pair(self):
        # pair 1: A at the idle level, B with other agents busy (a +130 background): repeated
        code, out, err, runs = self.ab("t_B1 70 9 180 0\n")
        self.assertIn("t pair 1: discarded (other_cpu medians 50 and 180 differ by 130 > 40)", err)
        self.assertIn("A kept 3: t_A2 t_A3 t_A4", out)
        self.assertIn("dropped: t_A1 t_B1", out)
        self.assertEqual(code, 0, out + err)
        # within the margin both stay
        code, out, err, runs = self.ab("t_B1 70 9 90 0\n")
        self.assertIn("A kept 3: t_A1 t_A2 t_A3", out)

    def test_spikes_drop_the_pair(self):
        code, out, err, runs = self.ab("t_A2 70 9 50 3\n")
        self.assertIn("t_A2: discarded (other processes busy in 3 samples)", err)
        self.assertIn("dropped: t_A2 t_B2", out)
        self.assertIn("A kept 3: t_A1 t_A3 t_A4", out)
        # two samples are tolerated
        code, out, err, runs = self.ab("t_A2 70 9 50 2\n")
        self.assertIn("A kept 3: t_A1 t_A2 t_A3", out)

    def test_early_stop(self):
        # every pair fails: after pair 4 three kept pairs cannot be reached any more (6 tries)
        plan = "".join("t_A%d 70 20 50 0\n" % i for i in range(1, 7))
        code, out, err, runs = self.ab(plan)
        self.assertEqual(code, 1)
        self.assertEqual(runs, ["t_Aw", "t_Bw", "t_A1", "t_B1", "t_A2", "t_B2", "t_A3", "t_B3", "t_A4", "t_B4"])

    # ---- Uncharted 4 (ROUTE_KIND, plain build directories, present range) ----

    def ab_u4(self, plan, **extra):
        for name, text in (("route_u4.sh", STUB_U4), ("lock_stub.sh", LOCK_STUB)):
            with open(os.path.join(self.d, name), "w") as f:
                f.write(text)
            os.chmod(os.path.join(self.d, name), stat.S_IRWXU)
        with open(os.path.join(self.d, "plan.txt"), "w") as f:
            f.write(plan)
        env = dict(os.environ, ROUTE=os.path.join(self.d, "route_u4.sh"), PLAN=os.path.join(self.d, "plan.txt"),
                   OUT=self.d, PAUSE="0", N="3", A="/a", B="/b", TAG="u", SECS="10", ROUTE_KIND="boat",
                   HEAVY_LOCK=os.path.join(self.d, "lock_stub.sh"), **extra)
        p = subprocess.run(["/bin/bash", TOOL], env=env, capture_output=True, text=True, timeout=60)
        return p.returncode, p.stdout, p.stderr

    def read(self, name):
        with open(os.path.join(self.d, name)) as f:
            return f.read()

    def test_u4_plain_build_kind_and_lock(self):
        plan = "".join("u_B%s 90\n" % i for i in ("w", 1, 2, 3, 4, 5, 6))
        code, out, err = self.ab_u4(plan, FROM="3300")
        self.assertEqual(code, 0, out + err)
        env = self.read("env.txt").splitlines()
        # a plain build directory: the build is the whole value and no Metal version is set
        self.assertEqual(env[0], "u_Aw BUILD=/a METAL= ROUTE_KIND=boat SECS=10")
        self.assertEqual(env[1], "u_Bw BUILD=/b METAL= ROUTE_KIND=boat SECS=10")
        self.assertEqual(len(env), 8)
        # every run went through the lock, exclusively
        locks = self.read("lock.txt").splitlines()
        self.assertEqual(len(locks), 8)
        self.assertTrue(all(l.startswith("lock HEAVY_EXCLUSIVE=1 env ") for l in locks), locks)

    def test_u4_range_selects_the_windows_and_prints_the_verdict(self):
        plan = "".join("u_B%s 90\n" % i for i in ("w", 1, 2, 3, 4, 5, 6))
        code, out, err = self.ab_u4(plan, FROM="3300")
        self.assertIn("fps A median 70.0 range 70.0..70.0 runs 3 B median 90.0", out)
        self.assertIn("VERDICT: B faster (fps +20.0, gpu +0.0 ms, p99 +0.0 ms)", out)
        self.assertIn("fps_mean 70.0 ", err) # the per-run line is the range line
        # without FROM the 10 slow windows count: B's mean is 50, A's 40
        code, out, err = self.ab_u4(plan)
        self.assertIn("fps A median 40.0", out)
        self.assertIn("B median 50.0", out)

    def test_u4_range_past_the_log_drops_every_run(self):
        code, out, err = self.ab_u4("", FROM="99999")
        self.assertEqual(code, 1)
        self.assertIn("u_A1: no report", err)
        self.assertIn("fewer than 3 kept runs per side", out)

    def test_caches_are_scratch_under_the_runs_dir_per_side_and_deleted(self):
        code, out, err, runs = self.ab("")
        lines = self.read("caches.txt").splitlines()
        sides = {}
        for l in lines:
            tag, cache = l.split()
            sides.setdefault(tag[2], set()).add(cache)
        # one directory per side, shared by warm-up and counted runs, inside the runs dir
        self.assertEqual(sides, {"A": {os.path.join(self.d, "cache_t_A")}, "B": {os.path.join(self.d, "cache_t_B")}})
        self.assertEqual(len(lines), 8)
        self.assertFalse(os.path.exists(os.path.join(self.d, "cache_t_A")))
        self.assertFalse(os.path.exists(os.path.join(self.d, "cache_t_B")))
        # the U4 path too, also when the A/B ends early
        code, out, err = self.ab_u4("", FROM="99999")
        self.assertEqual(code, 1)
        self.assertFalse(os.path.exists(os.path.join(self.d, "cache_u_A")))

    def test_report_args_that_select_by_position_are_refused_with_a_range(self):
        # every per-run report would exit 2: refused before the first run
        for args, extra in (("--after-marker", {}), ("--skip 3", {"FROM": "3300"}), ("--skip=3", {"TO": "6000"}),
                            ("--after-marker", {"FROM": "3300"})):
            code, out, err = self.ab_u4("", REPORT_ARGS=args, **extra)
            self.assertEqual(code, 2, (args, extra, out, err))
            self.assertIn("REPORT_ARGS", err)
            self.assertFalse(os.path.exists(os.path.join(self.d, "env.txt")), (args, extra))
            self.assertFalse(os.path.exists(os.path.join(self.d, "lock.txt")), (args, extra))
        # without a range they still select the perf lines (inFAMOUS)
        code, out, err, runs = self.ab("", n=1, env={"MARKED": "1", "REPORT_ARGS": "--after-marker"})
        self.assertEqual(code, 0, out + err)
        self.assertEqual(len(runs), 4)

    def test_route_without_kind_is_not_locked_and_keeps_the_old_line(self):
        code, out, err, _ = self.ab("")
        self.assertFalse(os.path.exists(os.path.join(self.d, "lock.txt")))
        self.assertNotIn("VERDICT", out)
        self.assertIn("t_A1: fps 70.0 enc_ms 13.0", err)


if __name__ == "__main__":
    unittest.main()
