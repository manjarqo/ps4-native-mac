# Tests tools/u4_route.sh with a fake ps4_app: the environment the game gets, the pad script, the
# screenshot selection, the clean-up and the guards. The fake game only writes what the script
# makes it write; no real game or GPU is involved.
import os
import stat
import subprocess
import tempfile
import textwrap
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
TOOL = os.path.join(HERE, "..", "u4_route.sh")
PAD = os.path.join(HERE, "..", "u4_route_pad.txt")

# FAKE_MODE: "shots" writes frame_<n>.png for every 300th flip and exits; "hang" sleeps; "gpuerr" prints
# the renderer's failure line twice, then sleeps. It records its environment, its data directory and
# its PID in $FAKE_OUT.
FAKE = textwrap.dedent('''\
    #!/bin/bash
    echo "PAD=${PS4_PAD_SCRIPT-unset} CLOCK=${PS4_PAD_CLOCK-unset} AUTO=${PS4_PAD_AUTOPRESS-unset} APP=${PS4_APP_DIR-unset} METAL=${PS4_GNM_METAL-unset} EVERY=${PS4_SCREENSHOT_EVERY-unset} EXTRA=${EXTRA-unset} UPSCALE=$PS4_UPSCALE" > "$FAKE_OUT/env.txt"
    echo "$PS4RECOMP_DATA_DIR" > "$FAKE_OUT/data.txt"
    echo "$PS4RECOMP_CACHE_DIR" > "$FAKE_OUT/cache.txt"
    echo $$ > "$FAKE_OUT/pid.txt"
    [ -d "$PS4RECOMP_DATA_DIR" ] && touch "$PS4RECOMP_DATA_DIR/save.bin"
    case ${FAKE_MODE:-shots} in
      shots) [ -n "${PS4_SCREENSHOT_DIR-}" ] && for n in $(seq 0 300 6000); do : > "$PS4_SCREENSHOT_DIR/$(printf 'frame_%06d.png' $n)"; done
             echo "[gnm-draw] perf: 30.0 fps over last 300 presents; per frame: 3.0 commits, 1.0 waits, 2.0 ms waiting, 9.0 ms GPU busy, 7.0 ms CP (CPU), 13.0 ms encoder, 0.3 ms screen" ;;
      gpuerr) echo "[gnm-draw] command buffer gnm-1 failed after 2.5 ms on the GPU: x"
              echo "[gnm-draw] command buffer gnm-2 failed after 2.5 ms on the GPU: x"; exec sleep 120 ;;
      hang) exec sleep 120 ;;
    esac
    ''')


class U4RouteTest(unittest.TestCase):
    def setUp(self):
        self._d = tempfile.TemporaryDirectory()
        self.addCleanup(self._d.cleanup)
        self.d = self._d.name
        self.build = os.path.join(self.d, "build")
        self.out = os.path.join(self.d, "runs")
        self.app = os.path.join(self.d, "game")
        for p in (self.build, self.out, self.app):
            os.mkdir(p)
        exe = os.path.join(self.build, "ps4_app")
        with open(exe, "w") as f:
            f.write(FAKE)
        os.chmod(exe, stat.S_IRWXU)

    def go(self, *args, mode="shots", app=True, **env):
        e = {k: v for k, v in os.environ.items() if k not in ("ROUTE", "ROUTE_KIND", "SHOTS", "EVERY", "METAL", "CACHE")}
        e.update(BUILD=self.build, OUT=self.out, FAKE_OUT=self.out, FAKE_MODE=mode, TAG="t", SECS="3", TICK="1",
                 LOAD_WAIT="0", ROUTE_KIND="boat",
                 # the load guard reads the real machine's load; a huge limit makes the tests independent of it
                 # (test_load_guard sets its own limit)
                 LOAD_KILL="1000000")
        e.pop("PS4_U4_APP_DIR", None)
        if app:
            e["PS4_U4_APP_DIR"] = self.app
        e.update(env)
        p = subprocess.run(["/bin/bash", TOOL, *args], env=e, capture_output=True, text=True, timeout=60)
        return p.returncode, p.stdout, p.stderr

    def read(self, name):
        with open(os.path.join(self.out, name)) as f:
            return f.read().strip()

    def test_boat_environment_and_cleanup(self):
        rc, out, err = self.go("EXTRA=1")
        self.assertEqual(rc, 0, out + err)
        env = self.read("env.txt")
        pad = PAD_STEPS
        self.assertIn("PAD=%s CLOCK=frames AUTO=0 APP=%s METAL=unset " % (pad, self.app), env)
        self.assertIn("EXTRA=1 UPSCALE=0", env) # the ENV=VAL arguments reach the game
        # the scratch data directory was in the run directory, used, and is gone; so is the scratch cache
        data, cache = self.read("data.txt"), self.read("cache.txt")
        self.assertTrue(data.startswith(self.out + os.sep + "data_t."), data)
        self.assertFalse(os.path.exists(data))
        self.assertFalse(os.path.exists(cache))
        # the per-run copy of the game is gone and the log, monitor and exit line exist
        self.assertEqual(os.listdir(self.build), ["ps4_app"])
        self.assertIn("perf: 30.0 fps", self.read("t.log"))
        self.assertIn("(exited)", self.read("t.mon").splitlines()[-1])
        self.assertFalse(os.path.exists(os.path.join(self.out, "t.guard")))

    def test_title_presses_nothing(self):
        rc, out, err = self.go(ROUTE_KIND="title")
        self.assertEqual(rc, 0, out + err)
        self.assertIn("PAD=unset CLOCK=unset AUTO=0 ", self.read("env.txt"))

    def test_route_name_in_route_but_not_a_program_path(self):
        rc, _, _ = self.go(ROUTE_KIND="", ROUTE="title")
        self.assertEqual(rc, 0)
        self.assertIn("PAD=unset ", self.read("env.txt"))
        # as ROUTE= of metal4_perf_ab.sh, ROUTE is this program's path and the kind comes from ROUTE_KIND
        rc, _, _ = self.go(ROUTE_KIND="boat", ROUTE=TOOL)
        self.assertEqual(rc, 0)
        self.assertIn("CLOCK=frames", self.read("env.txt"))
        rc, _, err = self.go(ROUTE_KIND="", ROUTE=TOOL)
        self.assertEqual(rc, 1)
        self.assertIn("ROUTE_KIND=title|boat", err)

    def test_default_shots_are_kept_and_the_others_deleted(self):
        rc, out, err = self.go()
        self.assertEqual(rc, 0, out + err)
        self.assertIn("EVERY=300 ", self.read("env.txt"))
        shots = sorted(os.listdir(os.path.join(self.out, "shots_t")))
        self.assertEqual(shots, ["frame_001500.png", "frame_002400.png", "frame_004500.png", "frame_005400.png"])
        self.assertNotIn("missing", self.read("t.mon"))

    def test_shots_list_every_and_missing(self):
        rc, _, _ = self.go(SHOTS="600 900")
        self.assertEqual(sorted(os.listdir(os.path.join(self.out, "shots_t"))), ["frame_000600.png", "frame_000900.png"])
        self.assertIn("EVERY=300 ", self.read("env.txt"))
        # a shot the game never saved is named in the monitor
        rc, _, _ = self.go(SHOTS="300 6300")
        self.assertIn("screenshots missing for flips: 6300", self.read("t.mon"))
        # EVERY=0: no screenshots at all, EVERY=n: every n-th flip, all kept
        rc, _, _ = self.go(EVERY="0")
        self.assertEqual(os.listdir(os.path.join(self.out, "shots_t")), []) # earlier shots of the tag are cleared
        self.assertIn("EVERY=unset ", self.read("env.txt"))
        rc, _, _ = self.go(EVERY="1200")
        self.assertIn("EVERY=1200 ", self.read("env.txt"))
        self.assertEqual(len(os.listdir(os.path.join(self.out, "shots_t"))), 21)

    def test_bad_shots_entry(self):
        rc, _, err = self.go(SHOTS="1500 x")
        self.assertEqual(rc, 1)
        self.assertIn("SHOTS entries", err)

    def test_app_dir_is_required_and_checked(self):
        rc, _, err = self.go(app=False)
        self.assertEqual(rc, 1)
        self.assertIn("PS4_U4_APP_DIR is not set", err)
        rc, _, err = self.go(PS4_U4_APP_DIR=os.path.join(self.d, "absent"))
        self.assertEqual(rc, 1)
        self.assertIn("not a directory", err)
        self.assertFalse(os.path.exists(os.path.join(self.out, "env.txt"))) # the game never started

    def test_secs_limit_and_missing_build(self):
        rc, _, err = self.go(SECS="301")
        self.assertEqual(rc, 1)
        self.assertIn("SECS must be <= 300", err)
        rc, _, err = self.go(BUILD=os.path.join(self.d, "nothing"))
        self.assertEqual(rc, 1)
        self.assertIn("ps4_app not found", err)

    def test_time_limit_kills_the_game_by_its_pid(self):
        rc, out, err = self.go(mode="hang", SECS="2")
        self.assertEqual(rc, 0, out + err)
        self.assertIn("(time limit)", self.read("t.mon").splitlines()[-1])
        self.assert_gone(self.read("pid.txt"))
        self.assertFalse(os.path.exists(os.path.join(self.out, "t.guard")))
        self.assertEqual(err, "") # the stopped watchdog prints no job message

    def test_gpu_errors_are_a_guard_stop(self):
        rc, out, err = self.go(mode="gpuerr", SECS="30")
        self.assertEqual(rc, 2, out + err)
        self.assertEqual(self.read("t.guard"), "GPU errors 2")
        self.assertIn("(guard: GPU errors 2)", self.read("t.mon").splitlines()[-1])
        self.assert_gone(self.read("pid.txt"))
        self.assertFalse(os.path.exists(self.read("data.txt")))

    def test_gpu_error_limit_is_tunable(self):
        rc, _, _ = self.go(mode="gpuerr", SECS="3", MAXGPUERR="3")
        self.assertEqual(rc, 0)

    def test_load_guard(self):
        # a load limit of zero cannot be met: the monitor stops the run on its first sample
        rc, out, err = self.go(mode="hang", SECS="30", LOAD_KILL="0")
        self.assertEqual(rc, 2, out + err)
        self.assertRegex(self.read("t.guard"), r"^load [\d.]+$")

    def test_no_windowserver_is_not_an_arithmetic_error(self):
        # a pgrep that finds nothing: no WindowServer PID, so no RSS guard and no arithmetic on empty values
        fakebin = os.path.join(self.d, "fakebin")
        os.mkdir(fakebin)
        with open(os.path.join(fakebin, "pgrep"), "w") as f:
            f.write("#!/bin/bash\nexit 1\n")
        os.chmod(os.path.join(fakebin, "pgrep"), stat.S_IRWXU)
        rc, out, err = self.go(mode="hang", SECS="2", PATH=fakebin + os.pathsep + os.environ["PATH"])
        self.assertEqual(rc, 0, out + err)
        self.assertNotIn("syntax error", err + out)
        self.assertIn("(time limit)", self.read("t.mon").splitlines()[-1])
        self.assertIn("t=0 ws_rss=0 ", self.read("t.mon"))

    def assert_gone(self, pid):
        r = subprocess.run(["kill", "-0", pid], capture_output=True)
        self.assertNotEqual(r.returncode, 0, "game %s is still alive" % pid)


def _pad_steps():
    with open(PAD) as f:
        lines = [l.strip() for l in f if l.strip() and not l.strip().startswith("#")]
    return ",".join(lines)


PAD_STEPS = _pad_steps()


class PadFileTest(unittest.TestCase):
    def test_every_step_is_time_mask_hold_and_times_increase(self):
        last = -1
        for step in PAD_STEPS.split(","):
            t, mask, hold = step.split(":")
            self.assertGreater(int(t), last, step)
            last = int(t)
            int(mask, 16)
            self.assertGreater(int(hold), 0, step)
        self.assertLessEqual(len(PAD_STEPS.split(",")), 256) # the pad module reads at most 256 steps


if __name__ == "__main__":
    unittest.main()
