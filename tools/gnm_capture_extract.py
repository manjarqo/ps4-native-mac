#!/usr/bin/env python3
"""Extract one replayable pass of a GNM frame capture as a minimal frame for a host test.

usage: gnm_capture_extract.py <frame_dir> <pass> <out_frame_dir> [--max-bytes N]
                              [--drop-input 0xADDR ...] [--dim X,Y,Z] [--keep-outputs]

The output is a frame directory (manifest.json, blobs/, regs/, tex/) holding only that pass,
renumbered 0, and the files it references; tools/gnm_replay and tests/host/gnm_replay_test.mm read
it like a full capture. By default the captured outputs after the pass are dropped: a fixture
locks a fix by asserting a property of the replayed output, not by comparing with the (wrong)
output of the old code. --keep-outputs keeps them (fidelity fixtures).
--drop-input removes guest snapshots the property does not depend on (each removal must be
justified in the test's comment); --dim shrinks a dispatch's group counts. The fixture must stay
under --max-bytes (default 4 MiB). A pass extracted from a game's capture holds that game's
shaders and data: it is a local fixture (tests/host/data/game/, git-ignored, or
PS4_HOST_GAME_FIXTURES) and is never committed (tests/host/README.md).
"""
import argparse
import json
import os
import shutil
import sys


def fail(msg):
    print("gnm_capture_extract: %s" % msg, file=sys.stderr)
    return 2


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("frame_dir")
    ap.add_argument("pass_index", type=int)
    ap.add_argument("out_dir")
    ap.add_argument("--max-bytes", type=int, default=4 << 20)
    ap.add_argument("--drop-input", action="append", default=[])
    ap.add_argument("--dim")
    ap.add_argument("--keep-outputs", action="store_true")
    a = ap.parse_args(argv)  # argparse itself exits 2 on malformed options
    try:
        with open(os.path.join(a.frame_dir, "manifest.json"), encoding="utf-8") as f:
            frame = json.load(f)
        passes = [p for p in frame.get("passes", []) if p.get("index") == a.pass_index]
        if not passes:
            return fail("no pass %d" % a.pass_index)
        p = passes[0]
        if not p.get("replayable") or p.get("skipped"):
            return fail("pass %d is not replayable (%s)" % (a.pass_index, p.get("skipped") or
                                                              "not in PS4_GNM_CAPTURE_REPLAY"))
        try:
            drop = {int(x, 0) for x in a.drop_input}
        except ValueError as e:
            return fail("bad --drop-input address: %s" % e)
        unknown = drop - {int(b["addr"], 16) for b in p["inputs"]}
        if unknown:
            return fail("no input at %s" % ", ".join(hex(x) for x in sorted(unknown)))
        p["inputs"] = [b for b in p["inputs"] if int(b["addr"], 16) not in drop]
        if a.dim:
            if p["type"] != "dispatch":
                return fail("--dim applies to dispatches")
            try:
                dim = [int(x) for x in a.dim.split(",")]
            except ValueError:
                dim = []
            if len(dim) != 3 or min(dim) < 1:
                return fail("--dim wants X,Y,Z, three positive integers, got %r" % a.dim)
            p["dim"] = dim
        if not a.keep_outputs or a.dim:
            p["outputs"] = []
            for t in p["textures"]:
                t["post_file"] = ""
                t["post_hash"] = "0x0"
        for t in p["textures"]:  # the view PNGs are not part of a fixture
            t["png_file"] = ""
            t["png_mode"] = ""
        p["index"] = 0
        files = [p["regs_file"]] + [b["file"] for b in p["inputs"] + p["outputs"] if b.get("file")]
        files += [t[k] for t in p["textures"] for k in ("pre_file", "post_file") if t.get(k)]
        files = sorted(set(files))  # blobs shared by several entries are stored and counted once
        missing = [f for f in files if not os.path.isfile(os.path.join(a.frame_dir, f))]
        if missing:
            return fail("capture files missing: %s" % ", ".join(missing[:5]))
        if os.path.exists(a.out_dir):
            return fail("%s exists" % a.out_dir)
        total = sum(os.path.getsize(os.path.join(a.frame_dir, f)) for f in files)
        if total > a.max_bytes:
            print("gnm_capture_extract: %d bytes, over the limit of %d: drop inputs the property does not need "
                  "(--drop-input), shrink the dispatch (--dim), or build a smaller synthetic pass" %
                  (total, a.max_bytes), file=sys.stderr)
            return 1
        for f in files:
            dst = os.path.join(a.out_dir, f)
            os.makedirs(os.path.dirname(dst), exist_ok=True)
            shutil.copyfile(os.path.join(a.frame_dir, f), dst)
        frame["passes"] = [p]
        with open(os.path.join(a.out_dir, "manifest.json"), "w", encoding="utf-8") as f:
            json.dump(frame, f, indent=0)
    except (OSError, ValueError, KeyError, TypeError) as e:  # unreadable or malformed capture
        return fail("%s: %s" % (type(e).__name__, e))
    print("gnm_capture_extract: pass %d -> %s (%d files, %d bytes)" % (a.pass_index, a.out_dir, len(files), total))
    return 0


if __name__ == "__main__":
    sys.exit(main())
