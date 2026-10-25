#!/usr/bin/env python3
"""Compares two gnm_replay --sha hash lists (docs/metal4-backend.md, "Replay parity").

usage: metal4_replay_cmp.py <base.txt> <new.txt> [--type draw|dispatch]
                            [--nondet PASSES --base2 <base2.txt>] [--fail-new-unstable]

Every pass the base list replayed (P ... RAN) must be replayed in the new list with the same
outputs (names, sizes and SHA-256). Passes the base list did not replay are not part of the pass
set and are ignored.

--nondet takes the passes documented as non-deterministic (comma separated numbers, or @file with
one number per line and '#' comments). --base2 is a second replay of the base build. A listed
pass is accepted when the set of outputs that differ between base and new equals the set that
differs between base and base2 (its Metal 3 run-to-run behaviour). A listed pass that does not
differ between base and base2 is reported as BADLIST: the list may only name passes that really
differ between two base runs.

The non-deterministic comparison is strict: a listed pass whose new run happens to equal base
(no differing output) is a DIFF too, because the set of differing outputs must be the same.

An output without a real hash (gnm_replay prints MISSING for a texture the renderer did not make,
"-" for a hash not asked for) is never the same output, even when both lists have it: it is a DIFF
on whichever side carries it, so two builds failing alike cannot pass as parity.

--fail-new-unstable: the lists come from gnm_replay --settle, whose U lines name the outputs whose
two replays of a pass differed (UNSTABLE-FIRST). Every U line of new whose pass and output have no
U line in base (or base2) is reported as UNSTABLE and counts as a difference. Without the option U
lines are ignored. --settle is a diagnostic (docs/gnm-capture.md): it classifies a DIFF a plain
sweep found, it is not the gate for ordering changes.

Exit status 0: no difference; 1: a difference, a missing pass or a bad list; 2: unreadable or
unparsable input, nothing to compare, or a usage error.
"""
import argparse
import sys


class InputError(Exception):
    pass


def load(path):
    passes = {}
    with open(path) as f:
        for no, line in enumerate(f, 1):
            w = line.split()
            if len(w) >= 4 and w[0] in ("P", "O"):
                try:
                    n = int(w[1])
                except ValueError:
                    raise InputError("%s line %d: bad pass number %r" % (path, no, w[1]))
                if w[0] == "P":
                    passes[n] = {"type": w[2], "state": w[3], "outs": {}}
                elif len(w) == 5 and n in passes:
                    passes[n]["outs"][w[2]] = (w[3], w[4])
                elif len(w) == 5:
                    raise InputError("%s line %d: output line for pass %d before its P line" % (path, no, n))
    return passes


def load_unstable(path):
    """(pass, output) of every U line: U <pass> UNSTABLE-FIRST <what> <first> <settled>."""
    out = set()
    with open(path) as f:
        for no, line in enumerate(f, 1):
            w = line.split()
            if w and w[0] == "U":
                if len(w) != 6 or w[2] != "UNSTABLE-FIRST":
                    raise InputError("%s line %d: bad U line" % (path, no))
                try:
                    out.add((int(w[1]), w[3]))
                except ValueError:
                    raise InputError("%s line %d: bad pass number %r" % (path, no, w[1]))
    return out


def parse_passes(spec):
    text = open(spec[1:]).read() if spec.startswith("@") else spec.replace(",", "\n")
    out = set()
    for line in text.splitlines():
        line = line.split("#", 1)[0].strip()
        if line:
            out.add(int(line))
    return out


def unhashed(h):
    """True for the placeholders gnm_replay prints instead of a SHA-256."""
    return h in ("MISSING", "-")


def differing(a, b):
    """Names of the outputs of pass dict a that b lacks or hashes differently, plus extras in b."""
    names = {w for w, h in a["outs"].items() if b["outs"].get(w) != h}
    return names | (set(b["outs"]) - set(a["outs"]))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("base")
    ap.add_argument("new")
    ap.add_argument("--type", choices=["draw", "dispatch"])
    ap.add_argument("--nondet", default="")
    ap.add_argument("--base2")
    ap.add_argument("--fail-new-unstable", action="store_true")
    a = ap.parse_args()
    if a.nondet and not a.base2:
        print("metal4_replay_cmp: --nondet needs --base2 (a second replay of the base build)", file=sys.stderr)
        return 2
    try:
        base, new = load(a.base), load(a.new)
        base2 = load(a.base2) if a.base2 else {}
        nondet = parse_passes(a.nondet) if a.nondet else set()
        if a.fail_new_unstable:
            known = load_unstable(a.base) | (load_unstable(a.base2) if a.base2 else set())
            new_unstable = sorted(load_unstable(a.new) - known)
        else:
            new_unstable = []
    except (OSError, ValueError, InputError) as e:
        print("metal4_replay_cmp: %s" % e)
        return 2
    same_p = same_o = diff = missing = nd_ok = 0
    for n in sorted(base):
        b = base[n]
        if b["state"] != "RAN" or (a.type and b["type"] != a.type):
            continue
        m = new.get(n)
        if not m or m["state"] != "RAN":
            print("MISSING pass %d (RAN -> %s)" % (n, m["state"] if m else "absent"))
            missing += 1
            continue
        bad = sorted(w for p in (b, m) for w, (_, h) in p["outs"].items() if unhashed(h))
        if bad:
            for what in sorted(set(bad)):
                print("DIFF pass %d %s (no hash: output missing or not hashed)" % (n, what))
                diff += 1
            continue
        if n in nondet:
            r = base2.get(n)
            if not r or r["state"] != "RAN":
                print("BADLIST pass %d (not replayed in the second base run)" % n)
                diff += 1
                continue
            ref = differing(b, r)
            if not ref:
                print("BADLIST pass %d (listed non-deterministic, but identical in two base runs)" % n)
                diff += 1
                continue
            got = differing(b, m)
            if got != ref:
                for what in sorted(got ^ ref):
                    print("DIFF pass %d %s (non-deterministic pass: %s)" %
                          (n, what, "differs only in new" if what in got else "differs only between base runs"))
                    diff += 1
            else:
                nd_ok += 1
            continue
        ok = True
        for what, h in sorted(b["outs"].items()):
            if m["outs"].get(what) != h:
                print("DIFF pass %d %s" % (n, what))
                diff += 1
                ok = False
            else:
                same_o += 1
        for what in sorted(set(m["outs"]) - set(b["outs"])):
            print("DIFF pass %d %s (only in new)" % (n, what))
            diff += 1
            ok = False
        same_p += ok
    for n, what in new_unstable:
        if a.type and base.get(n, {}).get("type") != a.type:
            continue
        print("UNSTABLE pass %d %s (UNSTABLE-FIRST in new, not in the base lists)" % (n, what))
        diff += 1
    if same_p + nd_ok + missing + diff == 0:
        print("metal4_replay_cmp: no passes to compare (empty or unparsable base list, or --type matches none)")
        return 2
    tail = "; non-deterministic as in base: %d" % nd_ok if nondet else ""
    print("same: %d passes, %d outputs; different: %d; missing: %d%s" % (same_p, same_o, diff, missing, tail))
    return 0 if diff == 0 and missing == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
