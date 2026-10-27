#!/usr/bin/env python3
"""Summaries of TLOU route runs (tools/metal4_route.sh; docs/metal4-backend.md).

usage: metal4_route_report.py <run.log> [--skip N]
       metal4_route_report.py <run.log> --mem
       metal4_route_report.py --mem-cmp <m3.log> <m4.log> [--mem-tolerance 0.10]
       metal4_route_report.py --verdict --a <A.log>... --b <B.log>... [--skip N]

Default: one line. fps, encoder ms, CP ms and commits are means over the [gnm-draw] perf lines
after the first N (default 13: boot and loading); split commits are the mean of the [gnm-draw]
backend lines (0 without any); skipped, pending and flips come from the last "present #" line (pending
is the part of skipped that waited for a background shader or pipeline compile, a cold-cache effect;
skipped minus pending is the work really lost; 0 in logs that predate the split); load is the
1-minute load in the stop line of <run>.mon next to the log (-1 without one); asserts counts
[gnm-residency] ASSERT lines; reasons are the three largest counts of the last "[gnm-draw] skipped by
reason:" line as name:count ("none" when it says none, "-" in logs that predate it). Exit status 1
when the log has no perf line after the skipped ones.

--mem: one line with the numbers of the last "[gnm-mem] charged ..." line (the memory total the
Phase 5 footprint gate reads) and of the last "texture cache" line (-1 when the log has none).
--mem-cmp: charged totals of two runs; exit 0 iff |m4 - m3| / m3 <= the tolerance.
--verdict: per side the medians over the runs (each run is the mean over its perf lines after the
skipped ones) of fps, encoder ms and CP ms with their range, then the A/B line the Phase 6 gate
reads. Noise is max(1.0, max_A - min_A) fps and max(0.1, max_A - min_A) ms over the A runs.
Metal 4 (B) is "at least" Metal 3 (A) when its median fps is >= A's and its encoder and CP ms
are not above A's by more than the noise, and no run has FATAL, GPU error or watchdog lines. A
run without perf lines is reported as dropped; fewer than --min-runs (default 5) usable runs on a
side fails. Exit status 0 iff B is at least A. Unreadable input: exit status 2.
"""
import argparse
import os
import re
import sys

PERF = re.compile(r"\[gnm-draw\] perf: ([\d.]+) fps .*?per frame: ([\d.]+) commits.*?([\d.]+) ms CP \(CPU\), ([\d.]+) ms encoder")
BACKEND = re.compile(r"\[gnm-draw\] backend \w+: split commits per frame ([\d.]+)")
PRESENT = re.compile(r"\[gnm-draw\] present #(\d+) .*totals: .* skipped (\d+)(?: \(pending compile (\d+)\))?")
REASONS = re.compile(r"\[gnm-draw\] skipped by reason: (.*)$")
REASON = re.compile(r"\s*([\w-]+) (\d+)\s*$")
STOP = re.compile(r" stop .* load \{ ([\d.]+)")
MEM = re.compile(r"\[gnm-mem\] charged (\d+)/(\d+) MiB \(device (\d+) MiB incl\. no-copy (\d+) MiB; no-copy buffers (\d+) "
                 r"covering (\d+) MiB\); wired (\d+) MiB \([+-]?\d+ since start\); footprint (\d+) MiB; "
                 r"peak charged (\d+) MiB, peak wired (\d+) MiB")
TEXCACHE = re.compile(r"\[gnm-mem\] texture cache at \d+ s: sampled (\d+) \((\d+) MiB, peak (\d+) MiB")
GPU_ERR = re.compile(r"^\[gnm-draw\] (command buffer \S+ failed|GPU hang report)")


def mean(v):
    return sum(v) / len(v) if v else 0.0


def median(v):
    s = sorted(v)
    n = len(s)
    return s[n // 2] if n % 2 else (s[n // 2 - 1] + s[n // 2]) / 2


def parse(path):
    r = {"perf": [], "split": [], "skipped": 0, "pending": 0, "flips": 0, "fatal": 0, "gpu_err": 0, "watchdog": 0,
         "asserts": 0, "mem": None, "tex": None, "reasons": None}
    with open(path, errors="replace") as f:
        for line in f:
            m = PERF.search(line)
            if m:
                r["perf"].append(tuple(float(x) for x in m.groups()))
                continue
            m = BACKEND.search(line)
            if m:
                r["split"].append(float(m.group(1)))
                continue
            m = PRESENT.search(line)
            if m:
                r["flips"], r["skipped"] = int(m.group(1)), int(m.group(2))
                r["pending"] = int(m.group(3) or 0)  # logs before the split have no pending count
                continue
            m = REASONS.search(line)
            if m:
                body = m.group(1).strip()
                r["reasons"] = []
                if body != "none":
                    for part in body.split(","):
                        p = REASON.match(part)
                        if p:
                            r["reasons"].append((p.group(1), int(p.group(2))))
                continue
            m = MEM.search(line)
            if m:
                r["mem"] = tuple(int(x) for x in m.groups())
                continue
            m = TEXCACHE.search(line)
            if m:
                r["tex"] = tuple(int(x) for x in m.groups())
                continue
            r["fatal"] += "FATAL" in line
            r["gpu_err"] += bool(GPU_ERR.search(line))
            r["watchdog"] += "GPU watchdog" in line
            r["asserts"] += "[gnm-residency] ASSERT" in line
    return r


def load_of(log):
    load = -1.0
    mon = os.path.splitext(log)[0] + ".mon"
    if os.path.exists(mon):
        for line in open(mon):
            m = STOP.search(line)
            if m:
                load = float(m.group(1))
    return load


def run_means(r, skip):
    """(fps, enc_ms, cp_ms, commits) means over the perf lines after the first skip, or None."""
    perf = r["perf"][skip:]
    if not perf:
        return None
    return mean([p[0] for p in perf]), mean([p[3] for p in perf]), mean([p[2] for p in perf]), mean([p[1] for p in perf])


def reasons_text(reasons, top=3):
    """The largest counts of a parsed "skipped by reason" line (stable order on ties)."""
    if reasons is None:
        return "-"
    if not reasons:
        return "none"
    best = sorted(reasons, key=lambda x: -x[1])[:top]
    return ",".join("%s:%d" % x for x in best)


def cmd_report(a):
    r = parse(a.log[0])
    m = run_means(r, a.skip)
    if not m:
        print("metal4_route_report: no perf lines after the first %d" % a.skip)
        return 1
    print("fps %.1f enc_ms %.1f cp_ms %.1f commits %.1f split %.1f skipped %d pending %d fatal %d gpu_err %d watchdog %d "
          "flips %d load %.1f asserts %d reasons %s" % (m[0], m[1], m[2], m[3], mean(r["split"]), r["skipped"], r["pending"],
                                                        r["fatal"], r["gpu_err"], r["watchdog"], r["flips"], load_of(a.log[0]),
                                                        r["asserts"], reasons_text(r["reasons"])))
    return 0


def cmd_mem(a):
    r = parse(a.log[0])
    if not r["mem"]:
        print("metal4_route_report: no [gnm-mem] charged line")
        return 1
    c, budget, dev, nocopy, nbuf, cover, wired, foot, pk_c, pk_w = r["mem"]
    tex = r["tex"] or (-1, -1, -1)
    print("mem charged %d budget %d device %d nocopy %d buffers %d covering %d wired %d footprint %d "
          "peak_charged %d peak_wired %d tex_count %d tex_mib %d tex_peak %d" %
          (c, budget, dev, nocopy, nbuf, cover, wired, foot, pk_c, pk_w, tex[0], tex[1], tex[2]))
    return 0


def cmd_mem_cmp(a):
    tot = []
    for p in a.mem_cmp:
        r = parse(p)
        if not r["mem"]:
            print("metal4_route_report: no [gnm-mem] charged line in %s" % p)
            return 1
        tot.append(r["mem"][0])
    m3, m4 = tot
    delta = (m4 - m3) / m3 if m3 else float("inf")
    ok = abs(delta) <= a.mem_tolerance
    print("mem charged m3 %d m4 %d delta %+.1f%% (limit %.0f%%) %s" %
          (m3, m4, delta * 100, a.mem_tolerance * 100, "ok" if ok else "over"))
    return 0 if ok else 1


def side(logs, skip):
    """(runs, bad) where bad = (fatal, gpu_err, watchdog) summed over all runs; runs without perf lines are reported."""
    runs, bad = [], [0, 0, 0]
    for p in logs:
        r = parse(p)
        bad[0] += r["fatal"]
        bad[1] += r["gpu_err"]
        bad[2] += r["watchdog"]
        m = run_means(r, skip)
        if m:
            runs.append(m)
        else:
            print("dropped %s: no perf lines after the first %d" % (os.path.basename(p), skip))
    return runs, bad


def cmd_verdict(a):
    if not a.a or not a.b:
        print("metal4_route_report: --verdict needs --a and --b", file=sys.stderr)
        return 2
    (A, bad_a), (B, bad_b) = side(a.a, a.skip), side(a.b, a.skip)
    print("runs kept A %d B %d" % (len(A), len(B)))
    if len(A) < a.min_runs or len(B) < a.min_runs:
        print("metal4_route_report: fewer than %d usable runs on a side" % a.min_runs)
        return 1
    print("A fatal %d gpu_err %d watchdog %d" % tuple(bad_a))
    print("B fatal %d gpu_err %d watchdog %d" % tuple(bad_b))
    res = {}
    for i, name, floor in ((0, "fps", 1.0), (1, "enc_ms", 0.1), (2, "cp_ms", 0.1)):
        va, vb = [r[i] for r in A], [r[i] for r in B]
        res[name] = (median(va), median(vb), max(floor, max(va) - min(va)), min(va), max(va), min(vb), max(vb))
        print("%s A median %.1f range %.1f..%.1f runs %d B median %.1f range %.1f..%.1f runs %d" %
              (name, res[name][0], res[name][3], res[name][4], len(va), res[name][1], res[name][5], res[name][6], len(vb)))
    fa, fb, nf = res["fps"][:3]
    ea, eb, ne = res["enc_ms"][:3]
    ca, cb, nc = res["cp_ms"][:3]
    fps_ok, enc_ok, cp_ok = fb >= fa, eb - ea <= ne, cb - ca <= nc
    clean = not any(bad_a) and not any(bad_b)
    print("B vs A: fps %+.1f (noise ±%.1f), encoder ms %+.1f (noise ±%.1f), CP ms %+.1f (noise ±%.1f); "
          "fps_ge %s enc_ok %s cp_ok %s; verdict %s" %
          (fb - fa, nf, eb - ea, ne, cb - ca, nc, "yes" if fps_ok else "no", "yes" if enc_ok else "no",
           "yes" if cp_ok else "no", "B>=A" if fps_ok and enc_ok and cp_ok and clean else "B<A"))
    return 0 if fps_ok and enc_ok and cp_ok and clean else 1


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("log", nargs="*")
    ap.add_argument("--skip", type=int, default=13)
    ap.add_argument("--mem", action="store_true")
    ap.add_argument("--mem-cmp", nargs=2, metavar=("M3_LOG", "M4_LOG"))
    ap.add_argument("--mem-tolerance", type=float, default=0.10)
    ap.add_argument("--verdict", action="store_true")
    ap.add_argument("--min-runs", type=int, default=5)
    ap.add_argument("--a", nargs="+")
    ap.add_argument("--b", nargs="+")
    a = ap.parse_args()
    try:
        if a.verdict:
            return cmd_verdict(a)
        if a.mem_cmp:
            return cmd_mem_cmp(a)
        if len(a.log) != 1:
            ap.error("exactly one run log is expected")
        return cmd_mem(a) if a.mem else cmd_report(a)
    except OSError as e:
        print("metal4_route_report: %s" % e)
        return 2


if __name__ == "__main__":
    sys.exit(main())
