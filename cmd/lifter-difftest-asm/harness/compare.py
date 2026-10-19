#!/usr/bin/env python3
"""Compare native.bin (x86-64 under Rosetta 2) and asm.bin (lifted arm64) from lifter-difftest-asm.

Usage: compare.py native.bin asm.bin tests.txt [--low] [--strict-nan] [--summary FILE]

tests.txt columns: index, guest address, signature, instruction text, flag rule, vector regs.
Flag rule: letters of the flags compared (C Z S O P), "-" for none, or shift:OP:SIZE:COUNT,
resolved per trial from the masked shift count (the input CL is stored in DtState.pad).
Vector registers are compared over all 256 bits; differences in a register the instruction
does not name are reported as "clobber" (scratch-register aliasing) rather than as a
semantic difference of the instruction itself.
"""
import struct, sys
from collections import OrderedDict

TRIALS = 8
STATE = 16 * 8 + 8 + 4 + 4 + 16 * 32
REC = 8 + STATE + 128
GPR = ["rax", "rcx", "rdx", "rbx", "rsp", "rbp", "rsi", "rdi", "r8", "r9", "r10", "r11", "r12", "r13", "r14", "r15"]
FLAGBIT = {"C": 0, "P": 2, "Z": 6, "S": 7, "O": 11}
CCNAMES = ["O", "NO", "B", "AE", "E", "NE", "BE", "A", "S", "NS", "P", "NP", "L", "GE", "LE", "G"]
# Per pair of condition codes: (name, flags it depends on, value of the even code).
_PAIRS = [("O", "O", lambda f: f["O"]), ("B", "C", lambda f: f["C"]), ("E", "Z", lambda f: f["Z"]),
          ("BE", "CZ", lambda f: f["C"] | f["Z"]), ("S", "S", lambda f: f["S"]), ("P", "P", lambda f: f["P"]),
          ("L", "SO", lambda f: f["S"] ^ f["O"]), ("LE", "ZSO", lambda f: f["Z"] | (f["S"] ^ f["O"]))]
CONDS = [p for p in _PAIRS for _ in (0, 1)]


def parse(buf, off):
    status, = struct.unpack_from("<I", buf, off)
    gpr = struct.unpack_from("<16Q", buf, off + 8)
    flags, mxcsr, cl = struct.unpack_from("<QII", buf, off + 8 + 128)
    ymm = [buf[off + 8 + 144 + 32 * i: off + 8 + 144 + 32 * (i + 1)] for i in range(16)]
    mem = buf[off + 8 + STATE: off + 8 + STATE + 128]
    return status, gpr, flags, mxcsr, cl, ymm, mem


def flags_for(rule, cl):
    """Return (flags to compare, whether register/memory results are defined) for one trial."""
    if not rule.startswith("shift:"):
        return ("" if rule == "-" else rule), True
    _, op, size, count = rule.split(":")
    size = int(size)
    c = cl if count == "cl" else int(count)
    c &= 0x3F if size == 64 else 0x1F
    if c == 0:
        return "CZSO", True  # flags unchanged
    one = "O" if c == 1 else ""  # OF is defined only for 1-bit shifts
    if op in ("SHL", "SHR", "SAR"):
        return ("C" if c < size else "") + "ZS" + one, True
    if op in ("ROL", "ROR", "RCL", "RCR"):
        return "CZS" + one, True  # ZF/SF unchanged
    if op in ("SHLD", "SHRD"):
        if c > size:
            return "", False  # result and flags undefined
        return "CZS" + one, True
    return "CZSO", True


def nan32(u):
    return (u & 0x7f800000) == 0x7f800000 and (u & 0x7fffff) != 0


def nan64(lo, hi):
    u = lo | (hi << 32)
    return (u & 0x7ff0000000000000) == 0x7ff0000000000000 and (u & 0xfffffffffffff) != 0


def main():
    args = sys.argv[1:]
    nat = open(args[0], "rb").read()
    lif = open(args[1], "rb").read()
    tests = [l.rstrip("\n").split("\t") for l in open(args[2])]
    low_only = "--low" in args
    ignore_nan = "--strict-nan" not in args
    summary_path = args[args.index("--summary") + 1] if "--summary" in args else None
    n = len(nat) // REC // TRIALS
    if len(lif) // REC // TRIALS != n or len(tests) != n:
        print("record count mismatch: native %d asm %d tests %d" % (n, len(lif) // REC // TRIALS, len(tests)))
        sys.exit(2)
    bad = 0
    native_faults = 0
    by_op = OrderedDict()  # opcode -> {kind -> [count, example]}
    for t in range(n):
        idx, addr, sig, text, rule, vregs = tests[t]
        named = set() if vregs == "-" else {int(v) for v in vregs.split(",")}
        diffs = []
        kinds = set()
        native_fault = False
        for k in range(TRIALS):
            o = (t * TRIALS + k) * REC
            s1, g1, f1, m1, cl, y1, mem1 = parse(nat, o)
            s2, g2, f2, m2, _, y2, mem2 = parse(lif, o)
            if s1:
                native_fault = True
                break
            if s2:
                diffs.append("lifted code crashed")
                kinds.add("crash")
                break
            fl, defined = flags_for(rule, cl)
            if defined:
                for i in range(16):
                    if g1[i] != g2[i]:
                        diffs.append("%s: native %016x lifted %016x" % (GPR[i], g1[i], g2[i]))
                        kinds.add("gpr")
            for i in range(16):
                if y1[i] == y2[i]:
                    continue
                a = struct.unpack("<8I", y1[i]); b = struct.unpack("<8I", y2[i])
                same = [a[j] == b[j] or (ignore_nan and nan32(a[j]) and nan32(b[j])) for j in range(8)]
                if ignore_nan:
                    for j in range(0, 8, 2):
                        if nan64(a[j], a[j + 1]) and nan64(b[j], b[j + 1]):
                            same[j] = same[j + 1] = True
                lanes = [j for j in range(8) if not same[j] and (j < 4 or not low_only)]
                if not lanes:
                    continue
                if i not in named:
                    kinds.add("clobber")
                else:
                    kinds.add("vec" if lanes[0] < 4 else "vec-hi")
                fa = struct.unpack("<8f", y1[i]); fb = struct.unpack("<8f", y2[i])
                diffs.append("%symm%d lanes %s: native %s lifted %s (f: %s vs %s)" % (
                    "CLOBBER " if i not in named else "", i, lanes,
                    " ".join("%08x" % a[j] for j in lanes), " ".join("%08x" % b[j] for j in lanes),
                    " ".join("%g" % fa[j] for j in lanes), " ".join("%g" % fb[j] for j in lanes)))
            if defined and mem1 != mem2:
                ix = [j for j in range(128) if mem1[j] != mem2[j]]
                diffs.append("mem bytes %d..%d differ: native %s lifted %s" % (
                    ix[0] - 32, ix[-1] - 32, mem1[ix[0]:ix[-1] + 1].hex(), mem2[ix[0]:ix[-1] + 1].hex()))
                kinds.add("mem")
            for name in fl:
                bit = FLAGBIT[name]
                if (f1 >> bit & 1) != (f2 >> bit & 1):
                    diffs.append("flag %sF native %d lifted %d" % (name, f1 >> bit & 1, f2 >> bit & 1))
                    kinds.add("flag-" + name + "F")
            # Every condition code as the lifted Jcc/SETcc/CMOVcc would evaluate it (bits 32-47 of
            # the lifted flags word) against the native EFLAGS, when its input flags are defined.
            nf = {name: (f1 >> bit) & 1 for name, bit in FLAGBIT.items()}
            for cc, (cname, need, fn) in enumerate(CONDS):
                if not set(need) <= set(fl):
                    continue
                want = fn(nf) ^ (cc & 1)
                got = (f2 >> (32 + cc)) & 1
                if want != got:
                    diffs.append("cond %s native %d lifted %d" % (CCNAMES[cc], want, got))
                    kinds.add("cond-" + CCNAMES[cc])
            if (m1 & ~0x3f) != (m2 & ~0x3f):
                diffs.append("mxcsr native %x lifted %x" % (m1, m2))
                kinds.add("mxcsr")
            if diffs:
                diffs.insert(0, "trial %d (input CL %d):" % (k, cl))
                break
        if native_fault:
            native_faults += 1
            continue
        if diffs:
            bad += 1
            print("FAIL #%s %s  | %s  [%s] flags=%s" % (idx, sig, text, addr, rule))
            for d in diffs[:7]:
                print("     ", d)
            op = sig.split(" ")[0]
            ent = by_op.setdefault(op, {})
            for kd in sorted(kinds):
                if kd not in ent:
                    ent[kd] = [0, "%s  [%s]" % (text, addr)]
                ent[kd][0] += 1
    print("%d/%d tests differ (%d skipped: native fault)" % (bad, n, native_faults))
    if summary_path:
        lines = ["| opcode | kind | tests | example |", "|---|---|---|---|"]
        for op in sorted(by_op):
            for kd, (cnt, ex) in sorted(by_op[op].items()):
                lines.append("| %s | %s | %d | `%s` |" % (op, kd, cnt, ex))
        with open(summary_path, "w") as fh:
            fh.write("%d/%d tests differ (%d skipped: native fault)\n\n" % (bad, n, native_faults))
            fh.write("\n".join(lines) + "\n")


main()
