#!/usr/bin/env python3
"""Summaries of TLOU route runs (tools/metal4_route.sh; docs/metal4-backend.md).

usage: metal4_route_report.py <run.log> [--skip N | --after-marker]
       metal4_route_report.py <run.log> --mem
       metal4_route_report.py --mem-cmp <m3.log> <m4.log> [--mem-tolerance 0.10]
       metal4_route_report.py --verdict --a <A.log>... --b <B.log>... [--skip N | --after-marker]
       metal4_route_report.py <run.log> --from N --to N [--json]
       metal4_route_report.py --verdict --from N --to N --a <A.log>... --b <B.log>...

Default: one line. fps, encoder ms, CP ms and commits are means over the [gnm-draw] perf lines
after the first N (default 13: boot and loading); split commits are the mean of the [gnm-draw]
backend lines (0 without any); skipped, pending and flips come from the last "present #" line (pending
is the part of skipped that waited for a background shader or pipeline compile, a cold-cache effect;
skipped minus pending is the work really lost; 0 in logs that predate the split); load is the
1-minute load in the stop line of <run>.mon next to the log (-1 without one); asserts counts
[gnm-residency] ASSERT lines; reasons are the three largest counts of the last "[gnm-draw] skipped by
reason:" line as name:count ("none" when it says none, "-" in logs that predate it). Exit status 1
when the log has no perf line after the skipped ones.

--after-marker (in place of --skip): the means are over the perf lines after the first one that
follows the first "[pad] script started" line (the pad script's first step, at the start of
gameplay; that first line still holds frames from before it). For routes whose boot has a varying
number of perf lines (inFAMOUS: 4-6 at 120 fps, then one per 37 s at 8 fps). A log without the
marker or without perf lines after it is a run without perf lines (exit status 1; dropped by
--verdict). It selects perf lines in its own way and is refused together with --from/--to.

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

Present range (--from N and/or --to N, replacing --skip, which is refused together with them): the perf lines are selected by present
index instead of by position. The k-th perf line of a log ends at present 300*k (PresentStats prints
one per 300 presents from the start of the process); a window is selected when from <= index <= to.
A "frame times over 600 frames" line belongs to the perf window printed before it. The one-line mode
then prints fps_mean fps_min fps_max gpu_ms cp_ms enc_ms wait_ms waits p50 p99 fatal gpu_err
watchdog (per-frame means over the selected windows; p50 and p99 are the means of the frame-times
lines of the selected windows, -1 without one), the number of windows, the load and the skip reasons
of the selected windows: the three largest counts as name:count ("none" without a skip, "-" in logs
that predate the "skipped by reason" line). The runtime prints that line with cumulative counts after
each "present #300k+1" line, i.e. after perf window k; the counts of windows k1..k2 are those of the
last line printed before perf line k2+1 minus those of the last line printed before perf line k1 (zero
when there is none). --json prints the same with every window, the reasons as a name: count map of
every non-zero count (null in logs without the line). --verdict adds, after its usual lines, a
"VERDICT: B faster|slower|within noise (fps, gpu, p99 differences of the medians)" line: B is faster
(slower) when its median fps is above (below) A's by more than the noise band, the larger of the
spread of the A runs and 3 % of A's median; the GPU-busy and p99 differences are reported with their bands. In this mode the exit status
follows the VERDICT word: 0 unless B is slower or a run has FATAL, GPU error or watchdog lines. Exit status of the range mode:
3 when no perf window is selected (verdict: no run has one), 4 when the log has a perf or frame-times
line this tool cannot parse (a layout change must not pass unnoticed).
"""
import argparse
import json
import os
import re
import sys

PERF = re.compile(r"\[gnm-draw\] perf: ([\d.]+) fps .*?per frame: ([\d.]+) commits.*?([\d.]+) ms CP \(CPU\), ([\d.]+) ms encoder")
# all fields of the perf line (PresentStats in ps4_gnm_draw.mm); the layout after "ms screen" (the
# encoder CPU and throttle times, added later) is not read
PERF_FULL = re.compile(r"\[gnm-draw\] perf: ([\d.]+) fps over last 300 presents; per frame: ([\d.]+) commits, ([\d.]+) waits, "
                       r"([\d.]+) ms waiting, ([\d.]+) ms GPU busy, ([\d.]+) ms CP \(CPU\), ([\d.]+) ms encoder, "
                       r"([\d.]+) ms screen")
FTIMES = re.compile(r"\[gnm-draw\] frame times over (\d+) frames: p50 ([\d.]+) p95 ([\d.]+) p99 ([\d.]+) max ([\d.]+) ms")
WINDOW = 300 # presents per perf line
BACKEND = re.compile(r"\[gnm-draw\] backend \w+: split commits per frame ([\d.]+)")
PRESENT = re.compile(r"\[gnm-draw\] present #(\d+) .*totals: .* skipped (\d+)(?: \(pending compile (\d+)\))?")
REASONS = re.compile(r"\[gnm-draw\] skipped by reason: (.*)$")
REASON = re.compile(r"\s*([\w-]+) (\d+)\s*$")
STOP = re.compile(r" stop .* load \{ ([\d.]+)")
MEM = re.compile(r"\[gnm-mem\] charged (\d+)/(\d+) MiB \(device (\d+) MiB incl\. no-copy (\d+) MiB; no-copy buffers (\d+) "
                 r"covering (\d+) MiB\); wired (\d+) MiB \([+-]?\d+ since start\); footprint (\d+) MiB; "
                 r"peak charged (\d+) MiB, peak wired (\d+) MiB")
TEXCACHE = re.compile(r"\[gnm-mem\] texture cache at \d+ s: sampled (\d+) \((\d+) MiB, peak (\d+) MiB")
MARKER = re.compile(r"^\[pad\] script started")
GPU_ERR = re.compile(r"^\[gnm-draw\] (command buffer \S+ failed|GPU hang report)")


def mean(v):
    return sum(v) / len(v) if v else 0.0


def median(v):
    s = sorted(v)
    n = len(s)
    return s[n // 2] if n % 2 else (s[n // 2 - 1] + s[n // 2]) / 2


def parse(path):
    r = {"perf": [], "split": [], "skipped": 0, "pending": 0, "flips": 0, "fatal": 0, "gpu_err": 0, "watchdog": 0,
         "asserts": 0, "mem": None, "tex": None, "reasons": None, "marker": None, "windows": [], "unparsed": [],
         "reason_lines": []}
    perf_lines = 0
    with open(path, errors="replace") as f:
        for n, line in enumerate(f, 1):
            if "[gnm-draw] perf:" in line:
                perf_lines += 1
                m = PERF_FULL.search(line)
                if m:
                    v = [float(x) for x in m.groups()]
                    r["windows"].append({"present": WINDOW * perf_lines, "fps": v[0], "commits": v[1], "waits": v[2],
                                         "wait_ms": v[3], "gpu_ms": v[4], "cp_ms": v[5], "enc_ms": v[6],
                                         "screen_ms": v[7], "p50": None, "p99": None})
                else:
                    r["unparsed"].append(n)
            elif "[gnm-draw] frame times over" in line:
                m = FTIMES.search(line)
                if not m:
                    r["unparsed"].append(n)
                elif r["windows"]:
                    r["windows"][-1]["p50"], r["windows"][-1]["p99"] = float(m.group(2)), float(m.group(4))
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
                # (perf lines printed before it, its cumulative counts) for the present-range mode
                r["reason_lines"].append((perf_lines, dict(r["reasons"])))
                continue
            if r["marker"] is None and MARKER.search(line):
                r["marker"] = len(r["perf"])  # perf lines before the marker
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


def select(r, rng):
    """The perf windows whose present index is in rng = (from, to)."""
    return [w for w in r["windows"] if rng[0] <= w["present"] <= rng[1]]


def window_reasons(r, sel):
    """The skip counts of the perf windows sel by reason (non-zero only), or None without a reason line."""
    if not r["reason_lines"]:
        return None
    k1, k2 = sel[0]["present"] // WINDOW, sel[-1]["present"] // WINDOW
    start, end = {}, {}
    for n, counts in r["reason_lines"]:
        if n < k1:
            start = counts
        if n <= k2:
            end = counts
    out = {}
    for name, c in end.items():
        d = c - start.get(name, 0)
        if d > 0:
            out[name] = d
    return out


def summarize(r, rng):
    """The fields of the range mode over the windows in rng, or None without a window."""
    sel = select(r, rng)
    if not sel:
        return None
    ft = [(w["p50"], w["p99"]) for w in sel if w["p99"] is not None]
    return {"windows": sel, "n": len(sel),
            "fps_mean": mean([w["fps"] for w in sel]), "fps_min": min(w["fps"] for w in sel),
            "fps_max": max(w["fps"] for w in sel), "gpu_ms": mean([w["gpu_ms"] for w in sel]),
            "cp_ms": mean([w["cp_ms"] for w in sel]), "enc_ms": mean([w["enc_ms"] for w in sel]),
            "wait_ms": mean([w["wait_ms"] for w in sel]), "waits": mean([w["waits"] for w in sel]),
            "p50": mean([f[0] for f in ft]) if ft else -1.0, "p99": mean([f[1] for f in ft]) if ft else -1.0,
            "fatal": r["fatal"], "gpu_err": r["gpu_err"], "watchdog": r["watchdog"], "reasons": window_reasons(r, sel)}


def selected(r, a):
    """The perf lines --skip / --after-marker keep, or a reason string when none are."""
    if a.after_marker:
        if r["marker"] is None:
            return "no [pad] script started line"
        perf = r["perf"][r["marker"] + 1:]
        return perf if perf else "no perf lines after the marker and the line that straddles it"
    perf = r["perf"][a.skip:]
    return perf if perf else "no perf lines after the first %d" % a.skip


def run_means(perf):
    """(fps, enc_ms, cp_ms, commits) means over the perf lines, or None."""
    if not perf:
        return None
    return mean([p[0] for p in perf]), mean([p[3] for p in perf]), mean([p[2] for p in perf]), mean([p[1] for p in perf])


def range_means(sel):
    """(fps, enc_ms, cp_ms, commits) means over the perf windows sel (select)."""
    return (mean([w["fps"] for w in sel]), mean([w["enc_ms"] for w in sel]), mean([w["cp_ms"] for w in sel]),
            mean([w["commits"] for w in sel]))


def reasons_text(reasons, top=3):
    """The largest counts of a parsed "skipped by reason" line (stable order on ties)."""
    if reasons is None:
        return "-"
    if not reasons:
        return "none"
    best = sorted(reasons, key=lambda x: -x[1])[:top]
    return ",".join("%s:%d" % x for x in best)


class Unparsed(Exception):
    """A perf or frame-times line in the layout this tool does not know (exit status 4)."""


def checked(path):
    r = parse(path)
    if r["unparsed"]:
        raise Unparsed("%s: line %d is a perf or frame-times line this tool cannot parse (layout of "
                       "PresentStats changed?)" % (path, r["unparsed"][0]))
    return r


def cmd_range_report(a):
    r = checked(a.log[0])
    sm = summarize(r, a.rng)
    if not sm:
        print("metal4_route_report: no perf window with a present index in %d..%d (%d windows in the log)" %
              (a.rng[0], a.rng[1], len(r["windows"])))
        return 3
    load = load_of(a.log[0])
    if a.json:
        out = {k: v for k, v in sm.items() if k != "n"}
        out["load"] = load
        print(json.dumps(out))
        return 0
    reasons = None if sm["reasons"] is None else list(sm["reasons"].items())
    print("fps_mean %.1f fps_min %.1f fps_max %.1f gpu_ms %.1f cp_ms %.1f enc_ms %.1f wait_ms %.1f waits %.1f "
          "p50 %.1f p99 %.1f fatal %d gpu_err %d watchdog %d windows %d load %.1f reasons %s" %
          (sm["fps_mean"], sm["fps_min"], sm["fps_max"], sm["gpu_ms"], sm["cp_ms"], sm["enc_ms"], sm["wait_ms"],
           sm["waits"], sm["p50"], sm["p99"], sm["fatal"], sm["gpu_err"], sm["watchdog"], sm["n"], load,
           reasons_text(reasons)))
    return 0


def cmd_report(a):
    if a.rng:
        return cmd_range_report(a)
    r = parse(a.log[0])
    perf = selected(r, a)
    if isinstance(perf, str):
        print("metal4_route_report: %s" % perf)
        return 1
    m = run_means(perf)
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


def side(logs, a):
    """(runs, bad, sums) where bad = (fatal, gpu_err, watchdog) summed over all runs and sums the range
    summaries of the kept runs (range mode only); runs without perf lines are reported."""
    runs, bad, sums = [], [0, 0, 0], []
    rng = a.rng
    for p in logs:
        r = checked(p) if rng else parse(p)
        bad[0] += r["fatal"]
        bad[1] += r["gpu_err"]
        bad[2] += r["watchdog"]
        if rng:
            sel = select(r, rng)
            if sel:
                runs.append(range_means(sel))
                sums.append(summarize(r, rng))
            else:
                print("dropped %s: no perf window with a present index in %d..%d" % (os.path.basename(p), rng[0], rng[1]))
            continue
        perf = selected(r, a)
        if isinstance(perf, str):
            print("dropped %s: %s" % (os.path.basename(p), perf))
        else:
            runs.append(run_means(perf))
    return runs, bad, sums


def range_verdict(sa, sb):
    """The VERDICT line of the range mode from the run summaries of both sides."""
    parts, bands = [], []
    res = {}
    for key, name, unit in (("fps_mean", "fps", ""), ("gpu_ms", "gpu", " ms"), ("p99", "p99", " ms")):
        va, vb = [x[key] for x in sa], [x[key] for x in sb]
        if min(va + vb) < 0: # a run without a frame-times line in the range
            parts.append("%s n/a" % name)
            continue
        band = max(max(va) - min(va), 0.03 * median(va))
        d = median(vb) - median(va)
        res[name] = (d, band)
        parts.append("%s %+.1f%s" % (name, d, unit))
        bands.append("%s ±%.1f" % (name, band))
    d, band = res["fps"]
    word = "faster" if d > band else "slower" if d < -band else "within noise"
    return word, "noise band (larger of the A-vs-A spread and 3%%): %s\nVERDICT: B %s (%s)" % (", ".join(bands), word, ", ".join(parts))


def cmd_verdict(a):
    if not a.a or not a.b:
        print("metal4_route_report: --verdict needs --a and --b", file=sys.stderr)
        return 2
    (A, bad_a, sum_a), (B, bad_b, sum_b) = side(a.a, a), side(a.b, a)
    print("runs kept A %d B %d" % (len(A), len(B)))
    if a.rng and not A and not B:
        print("metal4_route_report: no run has a perf window in the range")
        return 3
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
    if a.rng:
        word, text = range_verdict(sum_a, sum_b)
        print(text)
        # the exit status follows the VERDICT word: 0 unless B is slower or a run has FATAL, GPU error
        # or watchdog lines (the B>=A line above is the Metal 3 / Metal 4 gate and may differ)
        if not clean:
            print("runs are not clean (fatal/gpu_err/watchdog above): verdict fails")
        return 0 if word != "slower" and clean else 1
    return 0 if fps_ok and enc_ok and cp_ok and clean else 1


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("log", nargs="*")
    ap.add_argument("--skip", type=int) # 13 when not given
    ap.add_argument("--after-marker", action="store_true")
    ap.add_argument("--from", dest="rng_from", type=int)
    ap.add_argument("--to", dest="rng_to", type=int)
    ap.add_argument("--json", action="store_true")
    ap.add_argument("--mem", action="store_true")
    ap.add_argument("--mem-cmp", nargs=2, metavar=("M3_LOG", "M4_LOG"))
    ap.add_argument("--mem-tolerance", type=float, default=0.10)
    ap.add_argument("--verdict", action="store_true")
    ap.add_argument("--min-runs", type=int, default=5)
    ap.add_argument("--a", nargs="+")
    ap.add_argument("--b", nargs="+")
    a = ap.parse_args()
    a.rng = None
    if a.rng_from is not None or a.rng_to is not None:
        a.rng = (a.rng_from if a.rng_from is not None else 0, a.rng_to if a.rng_to is not None else sys.maxsize)
    if a.json and not a.rng:
        ap.error("--json needs --from or --to")
    if a.after_marker and a.rng:
        ap.error("--after-marker and --from/--to select perf lines in two different ways: use one")
    if a.skip is not None and a.rng:
        ap.error("--skip and --from/--to select perf lines in two different ways: use one")
    if a.skip is None:
        a.skip = 13
    try:
        if a.verdict:
            return cmd_verdict(a)
        if a.mem_cmp:
            return cmd_mem_cmp(a)
        if len(a.log) != 1:
            ap.error("exactly one run log is expected")
        return cmd_mem(a) if a.mem else cmd_report(a)
    except Unparsed as e:
        print("metal4_route_report: %s" % e)
        return 4
    except OSError as e:
        print("metal4_route_report: %s" % e)
        return 2


if __name__ == "__main__":
    sys.exit(main())
