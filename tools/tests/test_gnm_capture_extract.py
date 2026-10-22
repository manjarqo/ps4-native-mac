#!/usr/bin/env python3
"""Tests for tools/gnm_capture_extract.py on a synthetic two-pass capture."""
import json
import os
import shutil
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
import gnm_capture_extract  # noqa: E402


class ExtractTest(unittest.TestCase):
    def setUp(self):
        self.root = tempfile.mkdtemp(prefix="gnm_extract_test")
        self.src = os.path.join(self.root, "frame_9")
        for d in ("blobs", "regs", "tex"):
            os.makedirs(os.path.join(self.src, d))
        files = {"regs/r0.bin": 8, "regs/r1.bin": 8, "blobs/code.bin": 16384, "blobs/big.bin": 5 << 20,
                 "blobs/out.bin": 256, "tex/p00001_t0_storage_pre.raw": 64, "tex/p00001_t0_storage_post.raw": 64,
                 "blobs/other.bin": 16384}
        for name, n in files.items():
            with open(os.path.join(self.src, name), "wb") as f:
                f.write(b"\x01" * n)
        tex = {"role": "t0_storage", "written": True, "pre_file": "tex/p00001_t0_storage_pre.raw",
               "post_file": "tex/p00001_t0_storage_post.raw", "png_file": "png/x.png", "id": {}}
        frame = {"version": 1, "frame": 9, "mem_size": "0x100000000", "neo": False, "gcn_cache_id": "x", "passes": [
            {"index": 0, "replayable": False, "type": "draw", "skipped": "", "regs_file": "regs/r0.bin",
             "inputs": [{"addr": "0x50000", "size": 16384, "file": "blobs/other.bin"}], "outputs": [], "textures": []},
            {"index": 1, "replayable": True, "type": "dispatch", "skipped": "", "regs_file": "regs/r1.bin",
             "dim": [64, 32, 1],
             "inputs": [{"addr": "0x10000", "size": 16384, "file": "blobs/code.bin"},
                        {"addr": "0x80000000", "size": 5 << 20, "file": "blobs/big.bin"}],
             "outputs": [{"addr": "0x20000", "size": 256, "file": "blobs/out.bin"}], "textures": [tex]}]}
        with open(os.path.join(self.src, "manifest.json"), "w", encoding="utf-8") as f:
            json.dump(frame, f)
        self.out = os.path.join(self.root, "fixture")

    def tearDown(self):
        shutil.rmtree(self.root)

    def load(self):
        with open(os.path.join(self.out, "manifest.json"), encoding="utf-8") as f:
            return json.load(f)

    def test_size_limit_and_drop_input(self):
        self.assertEqual(gnm_capture_extract.main([self.src, "1", self.out]), 1)  # 5 MiB input: over 4 MiB
        self.assertFalse(os.path.exists(self.out))
        self.assertEqual(gnm_capture_extract.main([self.src, "1", self.out, "--drop-input", "0x80000000"]), 0)
        m = self.load()
        self.assertEqual(len(m["passes"]), 1)
        p = m["passes"][0]
        self.assertEqual(p["index"], 0)
        self.assertEqual([b["addr"] for b in p["inputs"]], ["0x10000"])
        self.assertEqual(p["outputs"], [])  # property fixture: no captured outputs
        self.assertEqual(p["textures"][0]["post_file"], "")
        self.assertTrue(os.path.exists(os.path.join(self.out, "tex/p00001_t0_storage_pre.raw")))
        self.assertFalse(os.path.exists(os.path.join(self.out, "blobs/big.bin")))
        self.assertFalse(os.path.exists(os.path.join(self.out, "blobs/other.bin")))

    def test_keep_outputs_and_dim(self):
        args = [self.src, "1", self.out, "--drop-input", "0x80000000", "--keep-outputs"]
        self.assertEqual(gnm_capture_extract.main(args), 0)
        p = self.load()["passes"][0]
        self.assertEqual(p["outputs"][0]["file"], "blobs/out.bin")
        self.assertTrue(os.path.exists(os.path.join(self.out, "tex/p00001_t0_storage_post.raw")))
        shutil.rmtree(self.out)
        self.assertEqual(gnm_capture_extract.main(args + ["--dim", "2,1,1"]), 0)
        p = self.load()["passes"][0]
        self.assertEqual(p["dim"], [2, 1, 1])
        self.assertEqual(p["outputs"], [])  # shrunk: outputs are not comparable

    def test_refusals(self):
        self.assertEqual(gnm_capture_extract.main([self.src, "0", self.out]), 2)  # not replayable
        self.assertEqual(gnm_capture_extract.main([self.src, "7", self.out]), 2)  # no such pass
        self.assertEqual(gnm_capture_extract.main([self.src, "1", self.out, "--drop-input", "0x1234"]), 2)

    def referenced(self, m):
        p = m["passes"][0]
        files = [p["regs_file"]] + [b["file"] for b in p["inputs"] + p["outputs"]]
        files += [t[k] for t in p["textures"] for k in ("pre_file", "post_file", "png_file") if t[k]]
        return files

    def test_no_dangling_references(self):
        # --keep-outputs without --dim kept png_file, which names a file the fixture does not hold
        args = [self.src, "1", self.out, "--drop-input", "0x80000000", "--keep-outputs"]
        self.assertEqual(gnm_capture_extract.main(args), 0)
        for f in self.referenced(self.load()):
            self.assertTrue(os.path.exists(os.path.join(self.out, f)), f)

    def test_shared_blob_counted_once(self):
        # two inputs backed by one file (a deduplicated snapshot): its size counts once
        with open(os.path.join(self.src, "manifest.json"), encoding="utf-8") as f:
            m = json.load(f)
        p = m["passes"][1]
        p["inputs"] = [{"addr": "0x10000", "size": 3 << 20, "file": "blobs/big.bin"},
                       {"addr": "0x400000", "size": 3 << 20, "file": "blobs/big.bin"}]
        with open(os.path.join(self.src, "manifest.json"), "w", encoding="utf-8") as f:
            json.dump(m, f)
        self.assertEqual(gnm_capture_extract.main([self.src, "1", self.out, "--max-bytes", str(6 << 20)]), 0)
        self.assertEqual(gnm_capture_extract.main([self.src, "1", self.out + "2", "--max-bytes", str(5 << 20)]), 1)
        shutil.rmtree(self.out)

    def test_bad_input_exits_2(self):
        ok = [self.src, "1", self.out, "--drop-input", "0x80000000"]
        self.assertEqual(gnm_capture_extract.main(ok + ["--dim", "2,x,1"]), 2)
        self.assertEqual(gnm_capture_extract.main(ok + ["--dim", "2,1"]), 2)
        self.assertEqual(gnm_capture_extract.main(ok + ["--dim", "0,1,1"]), 2)
        self.assertEqual(gnm_capture_extract.main([self.src, "1", self.out, "--drop-input", "0xZZ"]), 2)
        self.assertEqual(gnm_capture_extract.main([os.path.join(self.root, "nothing"), "1", self.out]), 2)
        os.remove(os.path.join(self.src, "blobs/code.bin"))  # a file the manifest names is gone
        self.assertEqual(gnm_capture_extract.main(ok), 2)
        self.assertFalse(os.path.exists(self.out))
        os.makedirs(self.out)  # an existing output directory is refused before the size check
        self.assertEqual(gnm_capture_extract.main([self.src, "1", self.out]), 2)


if __name__ == "__main__":
    unittest.main()
