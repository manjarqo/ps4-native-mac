# Tests tools/metal4_route.sh (the TLOU route) with a fake ps4_app: environment, data directory
# copy and removal, the guards and the stop line. It is the regression net for the guard code that
# tools/route_guard.sh shares with tools/u4_route.sh.
import os
import stat
import subprocess
import tempfile
import textwrap
import unittest

TOOL = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "metal4_route.sh")

FAKE = textwrap.dedent('''\
    #!/bin/bash
    echo "SCRIPT=${PS4_PAD_SCRIPT-unset} METAL=${PS4_GNM_METAL-unset} AUTO=${PS4_PAD_AUTOPRESS-unset} SHOTS=${PS4_SCREENSHOT_DIR-unset}:${PS4_SCREENSHOT_EVERY-unset} EXTRA=${EXTRA-unset}" > "$FAKE_OUT/env.txt"
    echo "$PS4RECOMP_DATA_DIR" > "$FAKE_OUT/data.txt"
    echo $$ > "$FAKE_OUT/pid.txt"
    cp "$PS4RECOMP_DATA_DIR/save.bin" "$FAKE_OUT/save_seen.txt"
    case ${FAKE_MODE:-exit} in
      gpuerr) echo "[gnm-draw] command buffer gnm-1 failed after 2.5 ms on the GPU: x"
              echo "[gnm-draw] command buffer gnm-2 failed after 2.5 ms on the GPU: x"; exec sleep 120 ;;
      hang) exec sleep 120 ;;
    esac
    ''')


class MetalRouteTest(unittest.TestCase):
    def setUp(self):
        self._d = tempfile.TemporaryDirectory()
        self.addCleanup(self._d.cleanup)
        self.d = self._d.name
        self.build = os.path.join(self.d, "build")
        self.out = os.path.join(self.d, "runs")
        self.src = os.path.join(self.d, "save")
        for p in (self.build, self.out, self.src):
            os.mkdir(p)
        with open(os.path.join(self.src, "save.bin"), "w") as f:
            f.write("save")
        with open(os.path.join(self.d, "walk.txt"), "w") as f:
            f.write("1000:4000:100\n")
        exe = os.path.join(self.build, "ps4_app")
        with open(exe, "w") as f:
            f.write(FAKE)
        os.chmod(exe, stat.S_IRWXU)

    def go(self, *args, **env):
        e = {k: v for k, v in os.environ.items() if k not in ("EVERY", "EVERY_SEC", "METAL", "CACHE")}
        e.update(BUILD=self.build, OUT=self.out, FAKE_OUT=self.out, TAG="m", SECS="3", TICK="1", LOAD_WAIT="0",
                 DATASRC=self.src, SCRIPT=os.path.join(self.d, "walk.txt"), EVERY="0", METAL="4")
        e.update(env)
        p = subprocess.run(["/bin/bash", TOOL, *args], env=e, capture_output=True, text=True, timeout=60)
        return p.returncode, p.stdout, p.stderr

    def read(self, name):
        with open(os.path.join(self.out, name)) as f:
            return f.read().strip()

    def test_environment_data_copy_and_cleanup(self):
        rc, out, err = self.go("EXTRA=1")
        self.assertEqual(rc, 0, out + err)
        self.assertEqual(self.read("env.txt"), "SCRIPT=1000:4000:100 METAL=4 AUTO=4000 SHOTS=unset:unset EXTRA=1")
        self.assertEqual(self.read("save_seen.txt"), "save")  # the fixture was copied
        self.assertFalse(os.path.exists(self.read("data.txt")))
        self.assertEqual(os.listdir(self.build), ["ps4_app"])
        mon = self.read("m.mon").splitlines()
        self.assertRegex(mon[0], r"^m start .* load \{ [\d.]+ .*metal 4$")
        self.assertRegex(mon[-1], r"^m stop \S+ \(exited\) load \{ [\d.]+ ")
        self.assertTrue(os.path.exists(os.path.join(self.src, "save.bin")))  # never the fixture itself

    def test_screenshots_directory(self):
        self.go(EVERY="600")
        self.assertIn(self.out + "/shots_m:600", self.read("env.txt"))
        self.assertTrue(os.path.isdir(os.path.join(self.out, "shots_m")))

    def test_time_limit_kills_the_game(self):
        rc, out, err = self.go(FAKE_MODE="hang", SECS="2")
        self.assertEqual(rc, 0, out + err)
        self.assertIn("(time limit)", self.read("m.mon").splitlines()[-1])
        self.assert_gone(self.read("pid.txt"))
        lines = self.read("m.mon")
        self.assertIn("other_cpu=", lines)

    def test_gpu_errors_stop_the_run_with_the_reason_in_the_stop_line(self):
        rc, out, err = self.go(FAKE_MODE="gpuerr", SECS="30")
        self.assertEqual(rc, 0)  # this route reports through the stop line only
        self.assertRegex(self.read("m.mon").splitlines()[-1], r"^m stop \S+ \(GPU errors 2\) ")
        self.assert_gone(self.read("pid.txt"))

    def test_load_guard(self):
        self.go(FAKE_MODE="hang", SECS="30", LOAD_KILL="0")
        self.assertRegex(self.read("m.mon").splitlines()[-1], r"^m stop \S+ \(load [\d.]+\) ")

    def test_secs_over_300_is_refused(self):
        rc, out, _ = self.go(SECS="301")
        self.assertEqual(rc, 2)
        self.assertIn("SECS must be <= 300", out)

    def assert_gone(self, pid):
        self.assertNotEqual(subprocess.run(["kill", "-0", pid], capture_output=True).returncode, 0)


if __name__ == "__main__":
    unittest.main()
