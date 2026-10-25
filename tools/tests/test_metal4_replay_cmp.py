# Tests tools/metal4_replay_cmp.py on small hash lists.
import os
import subprocess
import sys
import tempfile
import unittest

TOOL = os.path.join(os.path.dirname(__file__), "..", "metal4_replay_cmp.py")

BASE = """P 0 dispatch RAN 1 1
O 0 buffer_0x200000 256 aa
P 1 draw RAN 0 2
O 1 t0_color0 1024 bb
O 1 t1_depth 512 cc
P 2 draw NOT the renderer encoded nothing for this pass: x
"""


def write(path, text):
    with open(path, "w") as f:
        f.write(text)


def run(base, new, *args, extra=None):
    """Runs the tool; extra maps a file name to its text and is passed through {name} in args."""
    with tempfile.TemporaryDirectory() as d:
        a, b = os.path.join(d, "a.txt"), os.path.join(d, "b.txt")
        write(a, base)
        write(b, new)
        paths = {}
        for name, text in (extra or {}).items():
            paths[name] = os.path.join(d, name)
            write(paths[name], text)
        argv = [x.format(**paths) for x in args]
        p = subprocess.run([sys.executable, "-I", TOOL, a, b, *argv], capture_output=True, text=True)
        return p.returncode, p.stdout + p.stderr


class ReplayCmpTest(unittest.TestCase):
    def test_same(self):
        rc, out = run(BASE, BASE)
        self.assertEqual(rc, 0)
        self.assertIn("same: 2 passes, 3 outputs; different: 0; missing: 0", out)

    def test_hash_differs(self):
        rc, out = run(BASE, BASE.replace(" cc", " cd"))
        self.assertEqual(rc, 1)
        self.assertIn("DIFF pass 1 t1_depth", out)
        self.assertIn("different: 1", out)

    def test_pass_not_replayed_any_more(self):
        rc, out = run(BASE, BASE.replace("P 0 dispatch RAN 1 1\nO 0 buffer_0x200000 256 aa\n",
                                         "P 0 dispatch NOT the renderer skipped the pass\n"))
        self.assertEqual(rc, 1)
        self.assertIn("MISSING pass 0 (RAN -> NOT)", out)

    def test_pass_absent_in_new(self):
        rc, out = run(BASE, "P 1 draw RAN 0 2\nO 1 t0_color0 1024 bb\nO 1 t1_depth 512 cc\n")
        self.assertEqual(rc, 1)
        self.assertIn("MISSING pass 0 (RAN -> absent)", out)

    def test_type_filter(self):
        rc, out = run(BASE, BASE.replace(" cc", " cd"), "--type", "dispatch")
        self.assertEqual(rc, 0)
        self.assertIn("same: 1 passes, 1 outputs", out)

    def test_extra_pass_in_new_is_ignored(self):
        rc, _ = run(BASE, BASE.replace("P 2 draw NOT the renderer encoded nothing for this pass: x\n",
                                       "P 2 draw RAN 1 0\n"))
        self.assertEqual(rc, 0)

    def test_extra_output_in_new_differs(self):
        rc, out = run(BASE, BASE.replace("P 2 draw NOT", "O 1 t2_extra 8 ee\nP 2 draw NOT"))
        self.assertEqual(rc, 1)
        self.assertIn("DIFF pass 1 t2_extra (only in new)", out)

    def test_missing_output_on_both_sides_is_a_diff(self):
        # two builds that both fail to make a texture print identical lines: not parity
        bad = BASE.replace("O 1 t1_depth 512 cc", "O 1 t1_depth 0 MISSING")
        rc, out = run(bad, bad)
        self.assertEqual(rc, 1)
        self.assertIn("DIFF pass 1 t1_depth (no hash", out)

    def test_missing_output_on_one_side_is_a_diff(self):
        rc, out = run(BASE, BASE.replace("O 1 t1_depth 512 cc", "O 1 t1_depth 0 MISSING"))
        self.assertEqual(rc, 1)
        self.assertIn("DIFF pass 1 t1_depth", out)

    def test_unhashed_output_is_a_diff(self):
        rc, _ = run(BASE.replace(" aa", " -"), BASE.replace(" aa", " -"))
        self.assertEqual(rc, 1)


class InputErrorTest(unittest.TestCase):
    def test_empty_base_compares_nothing(self):
        rc, out = run("", BASE)
        self.assertEqual(rc, 2)
        self.assertIn("no passes to compare", out)

    def test_garbage_base_compares_nothing(self):
        rc, out = run("hello\nworld\n", BASE)
        self.assertEqual(rc, 2)
        self.assertIn("no passes to compare", out)

    def test_type_filter_matching_nothing(self):
        rc, out = run(BASE.replace("P 0 dispatch", "P 0 draw"), BASE, "--type", "dispatch")
        self.assertEqual(rc, 2)
        self.assertIn("no passes to compare", out)

    def test_output_line_before_any_pass(self):
        rc, out = run("O 0 x 1 aa\n" + BASE, BASE)
        self.assertEqual(rc, 2)
        self.assertIn("line 1", out)

    def test_non_numeric_pass_number(self):
        rc, out = run(BASE + "P x draw RAN 0 0\n", BASE)
        self.assertEqual(rc, 2)
        self.assertIn("bad pass number", out)

    def test_missing_file(self):
        rc, out = run(BASE, BASE, "--base2", "/nonexistent/zz")
        self.assertEqual(rc, 2)
        self.assertIn("/nonexistent/zz", out)


class NondetTest(unittest.TestCase):
    # base2 is a second Metal 3 run: pass 1 differs in t0_color0 only.
    BASE2 = BASE.replace(" bb", " b2")

    def test_nondet_same_differing_set_is_accepted(self):
        new = BASE.replace(" bb", " b3")  # differs in t0_color0, as between the two base runs
        rc, out = run(BASE, new, "--nondet", "1", "--base2", "{b2}", extra={"b2": self.BASE2})
        self.assertEqual(rc, 0, out)
        self.assertIn("same: 1 passes, 1 outputs; different: 0; missing: 0; non-deterministic as in base: 1", out)

    def test_nondet_pass_that_did_not_change_is_rejected(self):
        rc, out = run(BASE, BASE, "--nondet", "1", "--base2", "{b2}", extra={"b2": self.BASE2})
        self.assertEqual(rc, 1)  # differing sets {} != {t0_color0}
        self.assertIn("DIFF pass 1 t0_color0", out)

    def test_nondet_other_output_differs(self):
        new = BASE.replace(" bb", " b3").replace(" cc", " cd")  # t1_depth differs too: not run-to-run noise
        rc, out = run(BASE, new, "--nondet", "1", "--base2", "{b2}", extra={"b2": self.BASE2})
        self.assertEqual(rc, 1)
        self.assertIn("DIFF pass 1 t1_depth", out)
        self.assertNotIn("DIFF pass 1 t0_color0", out)

    def test_listed_pass_stable_in_base_runs_is_a_bad_list(self):
        rc, out = run(BASE, BASE, "--nondet", "0", "--base2", "{b2}", extra={"b2": self.BASE2})
        self.assertEqual(rc, 1)
        self.assertIn("BADLIST pass 0", out)

    def test_unlisted_pass_still_exact(self):
        new = BASE.replace(" bb", " b3").replace(" aa", " ab")
        rc, out = run(BASE, new, "--nondet", "1", "--base2", "{b2}", extra={"b2": self.BASE2})
        self.assertEqual(rc, 1)
        self.assertIn("DIFF pass 0 buffer_0x200000", out)

    def test_nondet_file_with_comments(self):
        rc, out = run(BASE, BASE.replace(" bb", " b3"), "--nondet", "@{list}", "--base2", "{b2}",
                      extra={"b2": self.BASE2, "list": "# water\n1  # pass 1\n"})
        self.assertEqual(rc, 0, out)

    def test_nondet_needs_base2(self):
        rc, out = run(BASE, BASE, "--nondet", "1")
        self.assertEqual(rc, 2)
        self.assertIn("--base2", out)

    def test_nondet_pass_not_replayed_is_missing(self):
        new = BASE.replace("P 1 draw RAN 0 2\nO 1 t0_color0 1024 bb\nO 1 t1_depth 512 cc\n", "P 1 draw NOT skipped\n")
        rc, out = run(BASE, new, "--nondet", "1", "--base2", "{b2}", extra={"b2": self.BASE2})
        self.assertEqual(rc, 1)
        self.assertIn("MISSING pass 1 (RAN -> NOT)", out)



UNST = "U 1 UNSTABLE-FIRST t0_color0 ba bb\n"


class ReplayCmpUnstableTest(unittest.TestCase):
    def test_new_unstable_fails_with_the_option(self):
        rc, out = run(BASE, BASE + UNST, "--fail-new-unstable")
        self.assertEqual(rc, 1)
        self.assertIn("UNSTABLE pass 1 t0_color0 (UNSTABLE-FIRST in new, not in the base lists)", out)
        self.assertIn("different: 1", out)

    def test_new_unstable_ignored_without_the_option(self):
        rc, out = run(BASE, BASE + UNST)
        self.assertEqual(rc, 0)
        self.assertNotIn("UNSTABLE", out)

    def test_unstable_in_base_is_known(self):
        rc, out = run(BASE + UNST, BASE + UNST, "--fail-new-unstable")
        self.assertEqual(rc, 0, out)

    def test_unstable_in_base2_is_known(self):
        rc, out = run(BASE, BASE + UNST, "--fail-new-unstable", "--base2", "{b2}", extra={"b2": BASE + UNST})
        self.assertEqual(rc, 0, out)

    def test_unstable_other_output_of_a_known_pass_fails(self):
        rc, out = run(BASE + UNST, BASE + UNST + "U 1 UNSTABLE-FIRST t1_depth ca cc\n", "--fail-new-unstable")
        self.assertEqual(rc, 1)
        self.assertIn("UNSTABLE pass 1 t1_depth", out)

    def test_bad_u_line_is_an_input_error(self):
        rc, out = run(BASE, BASE + "U 1 t0_color0 ba bb\n", "--fail-new-unstable")
        self.assertEqual(rc, 2)
        self.assertIn("bad U line", out)


if __name__ == "__main__":
    unittest.main()
