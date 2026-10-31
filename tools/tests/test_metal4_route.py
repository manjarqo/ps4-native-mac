# Tests tools/metal4_route.sh with a stub game (BUILD= a directory whose ps4_app is a shell
# script): the camera program of CTL= is appended to the PS4_PAD_CTL file after the pad script's
# start marker, and PS4_PAD_CTL is unset without CTL=.
import os
import stat
import subprocess
import tempfile
import textwrap
import unittest

TOOL = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "metal4_route.sh")

# The stub game: records whether PS4_PAD_CTL is set and the control file's size when it prints the
# marker, then waits up to 5 s for the control file to fill and copies it to $STUB_OUT/ctl_copy.
# With STUB_NO_MARKER set it never prints the marker and outlives the route's 10 s.
STUB = textwrap.dedent('''\
    #!/bin/bash
    if [ -z "${PS4_PAD_CTL+x}" ]; then echo unset > "$STUB_OUT/ctl_state"; exit 0; fi
    echo "size_at_marker $(wc -c < "$PS4_PAD_CTL" | tr -d ' ')" > "$STUB_OUT/ctl_state"
    [ -n "${STUB_NO_MARKER:-}" ] && { sleep 15; exit 0; }
    echo "[pad] script started at 25000 ms"
    for i in $(seq 50); do [ -s "$PS4_PAD_CTL" ] && break; sleep 0.1; done
    sleep 0.5
    cp "$PS4_PAD_CTL" "$STUB_OUT/ctl_copy"
    ''')

PROGRAM = "w 128000\np 0 4000 128 128 255 128\nw 500\n"


def owner_game_runs():
    return subprocess.run(["pgrep", "-x", "eboot"], capture_output=True).returncode == 0


@unittest.skipIf(owner_game_runs(), "the owner's game runs: metal4_route.sh refuses to start")
class RouteTest(unittest.TestCase):
    def setUp(self):
        self._d = tempfile.TemporaryDirectory()
        self.addCleanup(self._d.cleanup)
        self.d = self._d.name
        self.build = os.path.join(self.d, "build")
        os.mkdir(self.build)
        app = os.path.join(self.build, "ps4_app")
        with open(app, "w") as f:
            f.write(STUB)
        os.chmod(app, stat.S_IRWXU)
        self.data = os.path.join(self.d, "data")
        os.makedirs(os.path.join(self.data, "saves"))
        self.prog = os.path.join(self.d, "cam.txt")
        with open(self.prog, "w") as f:
            f.write(PROGRAM)

    def route(self, ctl, **extra):
        env = dict(os.environ, BUILD=self.build, TAG="route_test_%d" % os.getpid(), SECS="10", EVERY="0",
                   OUT=os.path.join(self.d, "runs"), CACHE=os.path.join(self.d, "cache"), DATASRC=self.data,
                   SCRIPT=self.prog, STUB_OUT=self.d, LOAD_WAIT_S="0", **extra)
        env.pop("CTL", None)
        if ctl:
            env["CTL"] = ctl
        # output to a file, not a pipe: the route's watchdog sleep (SECS + 30 s) outlives the route
        # and would hold a pipe open
        with open(os.path.join(self.d, "route.out"), "w+") as out:
            p = subprocess.run(["/bin/bash", TOOL], env=env, stdout=out, stderr=subprocess.STDOUT, timeout=60)
            out.seek(0)
            p.stdout, p.stderr = out.read(), ""
        mon_path = os.path.join(self.d, "runs", env["TAG"] + ".mon")
        mon = open(mon_path).read() if os.path.exists(mon_path) else ""
        return p, mon

    def read(self, name):
        with open(os.path.join(self.d, name)) as f:
            return f.read()

    def test_ctl_program_appended_after_the_marker(self):
        p, mon = self.route(self.prog)
        self.assertEqual(p.returncode, 0, p.stdout + p.stderr)
        self.assertEqual(self.read("ctl_state").strip(), "size_at_marker 0")
        self.assertEqual(self.read("ctl_copy"), PROGRAM)
        self.assertIn("camera program appended at t=", mon)

    def test_ctl_without_marker_is_reported(self):
        p, mon = self.route(self.prog, STUB_NO_MARKER="1")
        self.assertEqual(p.returncode, 0, p.stdout + p.stderr)
        self.assertEqual(self.read("ctl_state").strip(), "size_at_marker 0")
        self.assertNotIn("camera program appended", mon)
        self.assertIn("camera program never appended", mon)

    def test_without_ctl_the_variable_is_unset(self):
        p, mon = self.route(None)
        self.assertEqual(p.returncode, 0, p.stdout + p.stderr)
        self.assertEqual(self.read("ctl_state").strip(), "unset")
        self.assertNotIn("camera program", mon)

    def test_missing_ctl_file_is_refused(self):
        p, _ = self.route(os.path.join(self.d, "absent.txt"))
        self.assertEqual(p.returncode, 2)
        self.assertIn("CTL", p.stdout + p.stderr)
        self.assertFalse(os.path.exists(os.path.join(self.d, "ctl_state")))


if __name__ == "__main__":
    unittest.main()
