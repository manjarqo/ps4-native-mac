#!/usr/bin/env python3
"""Tests for tools/gnm_capture_view.py on a tiny synthetic capture."""
import json
import os
import shutil
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
import gnm_capture_view  # noqa: E402


def synthetic_frame():
    draw = {
        "index": 0, "type": "draw", "queue": "gfx", "name": "draw <b>&", "skipped": "",
        "indexed": True, "count": 36, "num_instances": 1, "indirect_addr": "0x0", "indirect_args": [0] * 5,
        "dim": [0, 0, 0],
        "stages": [{"stage": "vs", "code_addr": "0x10000", "pgm_hash": "0xaa"},
                   {"stage": "ps", "code_addr": "0x20000", "pgm_hash": "0xbb"}],
        "buffers": [{"stage": "vs", "index": 0, "addr": "0x30000", "size": 4096, "written": False}],
        "images": [{"stage": "ps", "index": 1, "addr": "0x13100b0000", "width": 1920, "height": 1080, "dfmt": 10,
                    "nfmt": 0, "storage": False, "textures": [0]}],
        "textures": [{"role": "color0", "written": True, "png_file": "png/p00000_color0.png",
                      "png_mode": "unorm", "readback": "",
                      "id": {"address": "0x13100b0000", "mtl_width": 1920, "mtl_height": 1080, "mtl_format": 80}},
                     {"role": "depth", "written": True, "png_file": "", "png_mode": "", "readback": "msaa",
                      "id": {"address": "0x1321918000", "mtl_width": 1920, "mtl_height": 1080, "mtl_format": 260}}],
        "inputs": [{"addr": "0x10000", "size": 16384}], "outputs": [],
        "state": {"blend_enable": [False, True] + [False] * 6, "depth_test": True, "depth_write": False,
                  "depth_compare": 3, "stencil_test": False, "viewport": [0, 0, 1920, 1080, 0, 1]},
    }
    disp = {
        "index": 1, "type": "dispatch", "queue": "compute0", "name": "compute0", "skipped": "meta clear",
        "dim": [8, 4, 1], "indirect_addr": "0x0", "stages": [{"stage": "cs", "code_addr": "0x40000",
                                                               "pgm_hash": "0xcc"}],
        "buffers": [], "images": [], "textures": [], "inputs": [], "outputs": [], "state": {},
    }
    return {"version": 1, "frame": 2460, "mem_size": "0x8000000000", "neo": False, "gcn_cache_id": "id",
            "passes": [draw, disp]}


class CaptureViewTest(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.mkdtemp(prefix="gnm_view_test")
        with open(os.path.join(self.dir, "manifest.json"), "w", encoding="utf-8") as f:
            json.dump(synthetic_frame(), f)

    def tearDown(self):
        shutil.rmtree(self.dir)

    def test_page_lists_passes_in_order_with_thumbnails(self):
        self.assertEqual(gnm_capture_view.main([self.dir]), 0)
        with open(os.path.join(self.dir, "index.html"), encoding="utf-8") as f:
            page = f.read()
        self.assertIn("2 passes: 1 draws, 1 dispatches, 1 skipped", page)
        self.assertLess(page.index('id="p0"'), page.index('id="p1"'))
        self.assertIn('<img src="png/p00000_color0.png"', page)
        self.assertIn("depth 0x1321918000 1920x1080 f260 (written)<br>msaa", page)
        self.assertIn("draw &lt;b&gt;&amp;", page)  # names are escaped
        self.assertIn('<tr id="p1" class="skipped">', page)
        self.assertIn("dispatch 8x4x1", page)
        self.assertIn("blend 1<br>depth test cmp 3", page)
        self.assertIn("ps img1 0x13100b0000 1920x1080 fmt 10/0 gpu", page)

    def test_output_path_option(self):
        out = os.path.join(self.dir, "other.html")
        self.assertEqual(gnm_capture_view.main([self.dir, "-o", out, "--thumb", "64"]), 0)
        with open(out, encoding="utf-8") as f:
            self.assertIn('width="64"', f.read())

    def test_missing_or_foreign_manifest(self):
        empty = tempfile.mkdtemp(prefix="gnm_view_empty")
        try:
            self.assertEqual(gnm_capture_view.main([empty]), 2)
            with open(os.path.join(empty, "manifest.json"), "w", encoding="utf-8") as f:
                json.dump({"version": 2}, f)
            self.assertEqual(gnm_capture_view.main([empty]), 2)
        finally:
            shutil.rmtree(empty)


if __name__ == "__main__":
    unittest.main()
