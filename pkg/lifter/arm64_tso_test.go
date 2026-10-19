package lifter

import (
	"regexp"
	"strings"
	"testing"

	"ps4-recomp/pkg/disasm"

	"golang.org/x/arch/x86/x86asm"
)

// liftOne lifts one instruction at 0x1000 with flags live and returns its lowering.
// (Upstream's disasm.Instruction has Address and Inst; the length comes from the decoded Inst.)
func liftOne(t *testing.T, l *Arm64Lifter, code []byte) string {
	t.Helper()
	inst, err := x86asm.Decode(code, 64)
	if err != nil {
		t.Fatalf("decode %x: %v", code, err)
	}
	di := disasm.Instruction{Address: 0x1000, Inst: inst}
	out, err := l.LiftInstructionToBuf(di, 0x1000+uint64(inst.Len), nil, nil)
	if err != nil {
		t.Fatalf("lift %x: %v", code, err)
	}
	return strings.Join(out, "\n")
}

var (
	// An LSE atomic with acquire and release semantics.
	lseAtomicRe = regexp.MustCompile(`(?m)^\s+(ldaddal|ldclral|ldeoral|ldsetal|swpal|casal|caspal)[bh]? `)
	// An exclusive loop: LDAXR ... STLXR, then DMB ISH.
	exclusiveFencedRe = regexp.MustCompile(`(?s)ldaxr[bhp]?\s.*stlxr[bhp]?\s.*\n\s+dmb ish`)
	// A plain (non-atomic) access to guest memory.
	plainGuestAccessRe = regexp.MustCompile(`(?m)^\s+(ldr|str)[bh]?\s+[wx]\d+, \[x28, x1[67]\]`)
	// An LSE atomic whose destination is the zero register: it has no acquire semantics.
	lseZeroDestRe = regexp.MustCompile(`(?m)^\s+(ld[a-z]+al|swpal)[bh]? [wx]\d+, [wx]zr,`)
)

// LOCK-prefixed read-modify-write instructions and XCHG with a memory operand (implicitly
// locked) are atomic and full barriers on x86. They were lowered as plain load/op/store
// (LOCK ADD/SUB/INC/DEC/OR/BTS: lost updates between guest threads; a reader count of TLOU's
// job system underflowed) or as exclusive loops without a barrier (XADD/CMPXCHG/XCHG).
func TestLockFullBarrier(t *testing.T) {
	cases := []struct {
		name string
		code []byte
	}{
		{"lock add [rdi],eax", []byte{0xf0, 0x01, 0x07}},
		{"lock xadd [rdi],eax", []byte{0xf0, 0x0f, 0xc1, 0x07}},
		{"lock cmpxchg [rdi],ecx", []byte{0xf0, 0x0f, 0xb1, 0x0f}},
		{"xchg [rdi],eax", []byte{0x87, 0x07}},
		{"lock inc dword [rdi]", []byte{0xf0, 0xff, 0x07}},
		{"lock or [rdi],eax", []byte{0xf0, 0x09, 0x07}},
		{"lock bts dword [rdi],eax", []byte{0xf0, 0x0f, 0xab, 0x07}},
		// the other LOCK forms
		{"lock sub [rdi],rax", []byte{0xf0, 0x48, 0x29, 0x07}},
		{"lock and byte [rdi],al", []byte{0xf0, 0x20, 0x07}},
		{"lock xor word [rdi],ax", []byte{0x66, 0xf0, 0x31, 0x07}},
		{"lock dec qword [rdi+8]", []byte{0xf0, 0x48, 0xff, 0x4f, 0x08}},
		{"lock add dword [rdi],0x10", []byte{0xf0, 0x83, 0x07, 0x10}},
		{"lock not dword [rdi]", []byte{0xf0, 0xf7, 0x17}},
		{"lock neg dword [rdi]", []byte{0xf0, 0xf7, 0x1f}},
		{"lock adc [rdi],eax", []byte{0xf0, 0x11, 0x07}},
		{"lock sbb byte [rdi],ah", []byte{0xf0, 0x18, 0x27}},
		{"lock btr qword [rdi],5", []byte{0xf0, 0x48, 0x0f, 0xba, 0x37, 0x05}},
		{"lock btc word [rdi],ax", []byte{0x66, 0xf0, 0x0f, 0xbb, 0x07}},
		{"lock xadd byte [rdi],ah", []byte{0xf0, 0x0f, 0xc0, 0x27}},
		{"lock cmpxchg byte [rdi],dl", []byte{0xf0, 0x0f, 0xb0, 0x17}},
		{"xchg qword [rdi],rsi", []byte{0x48, 0x87, 0x37}},
		{"lock cmpxchg16b [rdi]", []byte{0xf0, 0x48, 0x0f, 0xc7, 0x0f}},
		{"lock cmpxchg8b [rdi]", []byte{0xf0, 0x0f, 0xc7, 0x0f}},
	}
	l := NewArm64Lifter(map[uint64]bool{0x1000: true})
	for _, c := range cases {
		got := liftOne(t, l, c.code)
		if !lseAtomicRe.MatchString(got) && !exclusiveFencedRe.MatchString(got) {
			t.Errorf("%s: not an acquire+release LSE atomic or a fenced exclusive loop:\n%s", c.name, got)
		}
		if plainGuestAccessRe.MatchString(got) {
			t.Errorf("%s: plain guest memory access:\n%s", c.name, got)
		}
		if lseZeroDestRe.MatchString(got) {
			t.Errorf("%s: LSE atomic with a zero destination (no acquire):\n%s", c.name, got)
		}
		if strings.Contains(got, "cas") && !strings.Contains(got, "dmb ish") {
			t.Errorf("%s: a failed compare-and-swap must still be a full barrier:\n%s", c.name, got)
		}
	}
	// A VEX instruction whose second prefix byte x86asm records as LOCK is not locked.
	if got := liftOne(t, l, []byte{0xc5, 0xf0, 0x57, 0xc9}); lseAtomicRe.MatchString(got) || strings.Contains(got, "ldaxr") {
		t.Errorf("vxorps xmm1,xmm1,xmm1 lifted as an atomic:\n%s", got)
	}
}

// CMPXCHG8B/CMPXCHG16B change only ZF. CMPXCHG16B set the whole NZCV (CMP XZR, XZR) and so lost
// CF/SF/OF and the tracked carry sense; CMPXCHG8B was not lowered at all.
func TestCmpxchgWideOnlyZF(t *testing.T) {
	for _, c := range []struct{ name, hex string }{
		{"lock cmpxchg16b [rdi]", "f0480fc70f"},
		{"lock cmpxchg8b [rdi]", "f00fc70f"},
	} {
		// add rax, rbx first: CF is held in the carryAdd sense and must survive.
		l := liftBlock(t, "4801d8", c.hex)
		requireInOrder(t, c.name, l[1], "mrs x5, nzcv", "cset x6, eq", "bfi x5, x6, #30, #1", "msr nzcv, x5")
		forbid(t, c.name, l[1], "cmp xzr, xzr", "cmp x2, #0")
		if got := strings.Join(l[1], "\n"); strings.Contains(got, "UNSUPPORTED") {
			t.Errorf("%s: not lowered:\n%s", c.name, got)
		}
	}
	l := liftBlock(t, "4801d8", "f0480fc70f", "0f92c0") // ...; setb al reads CF of the ADD
	requireInOrder(t, "setb after cmpxchg16b", l[2], "cset w16, cs")
}
