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
# skip) and $OUT/$TAG.mon (10 samples) from the plan line of its tag ("tag fps load cpu spikes";
# default 70 fps, load 9, other_cpu 50, no spikes), and appends its tag to $OUT/runs.txt.
STUB = textwrap.dedent('''\
    #!/bin/bash
    set -u
    read -r fps load cpu spikes < <(awk -v t="$TAG" '$1 == t {print $2, $3, $4, $5}' "$PLAN")
    fps=${fps:-70}; load=${load:-9}; cpu=${cpu:-50}; spikes=${spikes:-0}
    echo "$TAG" >> "$OUT/runs.txt"
    echo "$*" >> "$OUT/args.txt"
    for i in $(seq 20); do
      echo "[gnm-draw] perf: $fps fps over last 300 presents; per frame: 3.0 commits, 0.0 waits, 0.0 ms waiting, 9.0 ms GPU busy, 7.0 ms CP (CPU), 13.0 ms encoder, 0.3 ms screen"
    done > "$OUT/$TAG.log"
    {
      echo "$TAG start 10:00:00 load { 1.0 1.0 1.0 } WindowServer rss 1 KB metal $METAL"
      for i in $(seq 10); do
        c=$cpu; [ $i -le $spikes ] && c=400
        echo "t=$((i * 5)) ws_rss=1 ws_cpu=1 load=$load gpu_err=0 other_cpu=$c"
      done
      echo "$TAG stop 10:03:00 (time limit) load { $load 1.0 1.0 } WindowServer rss 1 KB"
    } > "$OUT/$TAG.mon"
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

    def ab(self, plan, n=3, extra=()):
        with open(os.path.join(self.d, "plan.txt"), "w") as f:
            f.write(plan)
        env = dict(os.environ, ROUTE=self.stub, PLAN=os.path.join(self.d, "plan.txt"), OUT=self.d, PAUSE="0",
                   N=str(n), A="/a:4", B="/b:4", TAG="t", SECS="10")
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


if __name__ == "__main__":
    unittest.main()
