#!/usr/bin/env python3
"""Compare native.bin and lifted.bin produced by the lifter difftest runners."""
import struct, sys
from collections import defaultdict

TRIALS = 8
STATE = 16 * 8 + 8 + 4 + 4 + 16 * 32
REC = 8 + STATE + 128
GPR = ["rax", "rcx", "rdx", "rbx", "rsp", "rbp", "rsi", "rdi", "r8", "r9", "r10", "r11", "r12", "r13", "r14", "r15"]
FLAGS = [(0, "CF"), (2, "PF"), (4, "AF"), (6, "ZF"), (7, "SF"), (11, "OF")]

def parse(buf, off):
    status, = struct.unpack_from("<I", buf, off)
    gpr = struct.unpack_from("<16Q", buf, off + 8)
    flags, mxcsr = struct.unpack_from("<QI", buf, off + 8 + 128)
    ymm = [buf[off + 8 + 144 + 32 * i: off + 8 + 144 + 32 * (i + 1)] for i in range(16)]
    mem = buf[off + 8 + STATE: off + 8 + STATE + 128]
    return status, gpr, flags, mxcsr, ymm, mem

def main():
    nat = open(sys.argv[1], "rb").read()
    lif = open(sys.argv[2], "rb").read()
    tests = [l.rstrip("\n").split("\t") for l in open(sys.argv[3])]
    check_flags = "--flags" in sys.argv
    global low_only
    low_only = "--low" in sys.argv
    global ignore_nan
    ignore_nan = "--strict-nan" not in sys.argv
    n = len(nat) // REC // TRIALS
    bad = 0
    for t in range(n):
        diffs = []
        sig = []
        for k in range(TRIALS):
            o = (t * TRIALS + k) * REC
            s1, g1, f1, m1, y1, mem1 = parse(nat, o)
            s2, g2, f2, m2, y2, mem2 = parse(lif, o)
            if s1:
                sig.append("native-signal%d" % s1); break
            if s2:
                diffs.append("lifted crashed"); break
            for i in range(16):
                if g1[i] != g2[i]:
                    diffs.append("%s: native %016x lifted %016x" % (GPR[i], g1[i], g2[i]))
            for i in range(16):
                if y1[i] != y2[i]:
                    a = struct.unpack("<8I", y1[i]); b = struct.unpack("<8I", y2[i])
                    fa = struct.unpack("<8f", y1[i]); fb = struct.unpack("<8f", y2[i])
                    def nan32(u): return (u & 0x7f800000) == 0x7f800000 and (u & 0x7fffff) != 0
                    def nan64(lo, hi):
                        u = lo | (hi << 32)
                        return (u & 0x7ff0000000000000) == 0x7ff0000000000000 and (u & 0xfffffffffffff) != 0
                    same = [a[j] == b[j] or (ignore_nan and nan32(a[j]) and nan32(b[j])) for j in range(8)]
                    if ignore_nan:
                        for j in range(0, 8, 2):
                            if nan64(a[j], a[j+1]) and nan64(b[j], b[j+1]):
                                same[j] = same[j+1] = True
                    lanes = [j for j in range(8) if not same[j] and (j < 4 or not low_only)]
                    if not lanes:
                        continue
                    diffs.append("ymm%d lanes %s: native %s lifted %s (f: %s vs %s)" % (
                        i, lanes, " ".join("%08x" % a[j] for j in lanes), " ".join("%08x" % b[j] for j in lanes),
                        " ".join("%g" % fa[j] for j in lanes), " ".join("%g" % fb[j] for j in lanes)))
            if mem1 != mem2:
                idx = [j for j in range(128) if mem1[j] != mem2[j]]
                diffs.append("mem bytes %d..%d differ" % (idx[0] - 32, idx[-1] - 32))
            if check_flags:
                for bit, name in FLAGS:
                    if (f1 >> bit & 1) != (f2 >> bit & 1):
                        diffs.append("flag %s native %d lifted %d" % (name, f1 >> bit & 1, f2 >> bit & 1))
            if (m1 & ~0x3f) != (m2 & ~0x3f):
                diffs.append("mxcsr native %x lifted %x" % (m1, m2))
            if diffs:
                diffs.insert(0, "trial %d:" % k)
                break
        if diffs:
            bad += 1
            print("FAIL #%s %s  | %s  [%s]" % (tests[t][0], tests[t][2], tests[t][3], tests[t][1]))
            for d in diffs[:6]:
                print("     ", d)
    print("%d/%d tests differ" % (bad, n))

main()
