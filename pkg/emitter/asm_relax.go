package emitter

import (
	"bytes"
	"fmt"
	"strings"
)

// The reach of the ARM64 conditional branches, in instructions: b.cond, cbz and cbnz take a
// 19-bit word offset (±1 MiB), tbz and tbnz a 14-bit one (±32 KiB). Use conservative
// limits; positions below already include every possible relaxation's extra instruction.
const (
	relaxImm19Limit = 1<<18 - 1<<16
	relaxImm14Limit = 1<<13 - 1<<11
)

// relaxFarBranches rewrites the conditional branches of one function's assembly whose label
// target may be out of reach (a function of more than a megabyte: big switch functions, whose
// every indirect jump compares the target against every block):
//
//	b.ne L          ->  b.eq L_rlx; b L; L_rlx:
//	cbz x16, L      ->  cbnz x16, L_rlx; b L; L_rlx:
//	tbz x17, #3, L  ->  tbnz x17, #3, L_rlx; b L; L_rlx:
//
// b reaches ±128 MiB. A function too small for any branch to be out of reach comes back as is.
func relaxFarBranches(src []byte, fnAddr uint64) []byte {
	if bytes.Count(src, []byte{'\n'}) < relaxImm14Limit {
		return src
	}
	lines := strings.Split(string(src), "\n")

	// Upper-bound instruction index of every line and label: reserve an extra
	// instruction for every conditional branch, even one that will remain short.
	// Every interval in the final output is therefore no longer than the interval
	// measured here. A single pass suffices even when many intervening branches grow.
	pos := make([]int, len(lines))
	labels := make(map[string]int)
	n := 0
	for i, ln := range lines {
		pos[i] = n
		t := strings.TrimSpace(ln)
		switch {
		case t == "" || t[0] == '.' || strings.HasPrefix(t, "//"):
		case strings.HasSuffix(t, ":"):
			labels[t[:len(t)-1]] = n
		default:
			n++
			if sp := strings.IndexAny(t, " \t"); sp >= 0 {
				mn := t[:sp]
				if mn == "cbz" || mn == "cbnz" || mn == "tbz" || mn == "tbnz" ||
					(strings.HasPrefix(mn, "b.") && invertCond(mn[2:]) != "") {
					n++
				}
			}
		}
	}
	if n < relaxImm14Limit {
		return src
	}

	var out bytes.Buffer
	out.Grow(len(src) + len(src)/8)
	relaxed := 0
	for i, ln := range lines {
		if i > 0 {
			out.WriteByte('\n')
		}
		inv, target, ok := relaxBranch(ln, labels, pos[i])
		if !ok {
			out.WriteString(ln)
			continue
		}
		skip := fmt.Sprintf("L_fn_0x%x_rlx_%d", fnAddr, relaxed)
		relaxed++
		fmt.Fprintf(&out, "    %s%s\n    b %s\n%s:", inv, skip, target, skip)
	}
	return out.Bytes()
}

// relaxBranch reports, for a conditional branch line whose label target lies beyond the
// branch's reach, the inverted branch up to its target operand, and the target.
func relaxBranch(ln string, labels map[string]int, at int) (inv, target string, ok bool) {
	t := strings.TrimSpace(ln)
	if c := strings.Index(t, "//"); c >= 0 {
		t = strings.TrimSpace(t[:c])
	}
	sp := strings.IndexAny(t, " \t")
	if sp < 0 {
		return "", "", false
	}
	mn, rest := t[:sp], strings.TrimSpace(t[sp:])
	ops := strings.Split(rest, ",")
	for k := range ops {
		ops[k] = strings.TrimSpace(ops[k])
	}
	target = ops[len(ops)-1]
	to, known := labels[target]
	if !known {
		return "", "", false
	}
	dist := to - at
	if dist < 0 {
		dist = -dist
	}
	head := strings.Join(ops[:len(ops)-1], ", ")
	switch {
	case strings.HasPrefix(mn, "b.") && len(ops) == 1:
		ic := invertCond(mn[2:])
		if ic == "" || dist < relaxImm19Limit {
			return "", "", false
		}
		return "b." + ic + " ", target, true
	case (mn == "cbz" || mn == "cbnz") && len(ops) == 2:
		if dist < relaxImm19Limit {
			return "", "", false
		}
		return map[string]string{"cbz": "cbnz", "cbnz": "cbz"}[mn] + " " + head + ", ", target, true
	case (mn == "tbz" || mn == "tbnz") && len(ops) == 3:
		if dist < relaxImm14Limit {
			return "", "", false
		}
		return map[string]string{"tbz": "tbnz", "tbnz": "tbz"}[mn] + " " + head + ", ", target, true
	}
	return "", "", false
}

func invertCond(c string) string {
	pairs := map[string]string{
		"eq": "ne", "ne": "eq", "cs": "cc", "cc": "cs", "hs": "lo", "lo": "hs",
		"mi": "pl", "pl": "mi", "vs": "vc", "vc": "vs", "hi": "ls", "ls": "hi",
		"ge": "lt", "lt": "ge", "gt": "le", "le": "gt",
	}
	return pairs[c]
}
