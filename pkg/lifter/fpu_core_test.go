package lifter

import (
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"

	"ps4-recomp/pkg/disasm"

	"golang.org/x/arch/x86/x86asm"
)

// liftX87Bytes decodes a straight-line x86-64 byte sequence and lifts every
// instruction, returning the C statements.
func liftX87Bytes(t *testing.T, code []byte) []string {
	t.Helper()
	l := NewLifter(nil)
	fn := &disasm.Function{EntryAddr: 0x1000, Blocks: map[uint64]*disasm.BasicBlock{}}
	var out []string
	pc := uint64(0x1000)
	for len(code) > 0 {
		inst, err := x86asm.Decode(code, 64)
		if err != nil {
			t.Fatalf("decode at 0x%x: %v", pc, err)
		}
		lines, err := l.LiftInstruction(disasm.Instruction{Address: pc, Inst: inst}, pc+uint64(inst.Len), fn)
		if err != nil {
			t.Fatalf("lift %v at 0x%x: %v", inst, pc, err)
		}
		out = append(out, lines...)
		pc += uint64(inst.Len)
		code = code[inst.Len:]
	}
	return out
}

func TestX87M80LoadStoreUsesExtendedFormat(t *testing.T) {
	// fld tword [rax] ; fstp tword [rbx]
	lines := strings.Join(liftX87Bytes(t, []byte{0xdb, 0x28, 0xdb, 0x3b}), "\n")
	if !strings.Contains(lines, "FPU_LOAD_M80(ctx->rax)") {
		t.Fatalf("fld m80 must use FPU_LOAD_M80, got:\n%s", lines)
	}
	if !strings.Contains(lines, "FPU_STORE_M80(ctx->rbx, FPU_ST(0))") {
		t.Fatalf("fstp m80 must use FPU_STORE_M80, got:\n%s", lines)
	}
	if strings.Contains(lines, "MEM_U32") {
		t.Fatalf("m80 operands must not be treated as m32, got:\n%s", lines)
	}
}

func TestX87FstpRegisterIsNotUnsequenced(t *testing.T) {
	// fstp st1
	lines := strings.Join(liftX87Bytes(t, []byte{0xdd, 0xd9}), "\n")
	if strings.Contains(lines, "= fpu_pop(ctx)") {
		t.Fatalf("FSTP ST(i) must not compute the destination and pop in one expression:\n%s", lines)
	}
	if !strings.Contains(lines, "double t_ = FPU_ST(0); FPU_ST(1) = t_;") {
		t.Fatalf("unexpected FSTP ST(1) lowering:\n%s", lines)
	}
}

func TestX87FstDoesNotPop(t *testing.T) {
	// fst qword [rcx]
	lines := strings.Join(liftX87Bytes(t, []byte{0xdd, 0x11}), "\n")
	if strings.Contains(lines, "fpu_pop") {
		t.Fatalf("FST must not pop:\n%s", lines)
	}
}

func TestX87RegisterArithOperandOrder(t *testing.T) {
	cases := []struct {
		name string
		code []byte
		want string
	}{
		{"fadd st0,st3", []byte{0xd8, 0xc3}, "double a_ = FPU_ST(0); double b_ = FPU_ST(3); FPU_ST(0) = a_ + b_;"},
		{"fmul st0,st2", []byte{0xd8, 0xca}, "double a_ = FPU_ST(0); double b_ = FPU_ST(2); FPU_ST(0) = a_ * b_;"},
		{"fdiv st0,st1", []byte{0xd8, 0xf1}, "double a_ = FPU_ST(0); double b_ = FPU_ST(1); FPU_ST(0) = a_ / b_;"},
		{"fdivr st0,st1", []byte{0xd8, 0xf9}, "double a_ = FPU_ST(0); double b_ = FPU_ST(1); FPU_ST(0) = b_ / a_;"},
		{"fdiv st2,st0", []byte{0xdc, 0xfa}, "double a_ = FPU_ST(2); double b_ = FPU_ST(0); FPU_ST(2) = a_ / b_;"},
		{"fsubrp st2,st0", []byte{0xde, 0xe2}, "double a_ = FPU_ST(2); double b_ = FPU_ST(0); FPU_ST(2) = b_ - a_;"},
		{"fdivp st3,st0", []byte{0xde, 0xfb}, "double a_ = FPU_ST(3); double b_ = FPU_ST(0); FPU_ST(3) = a_ / b_;"},
	}
	for _, tc := range cases {
		lines := strings.Join(liftX87Bytes(t, tc.code), "\n")
		if !strings.Contains(lines, tc.want) {
			t.Errorf("%s: want %q in:\n%s", tc.name, tc.want, lines)
		}
	}
}

func TestX87FistpHonorsRoundingControl(t *testing.T) {
	// fistp qword [rcx]
	lines := strings.Join(liftX87Bytes(t, []byte{0xdf, 0x39}), "\n")
	if !strings.Contains(lines, "fpu_round_cw(ctx->fpu_cw, FPU_ST(0))") {
		t.Fatalf("FISTP must round per the control word:\n%s", lines)
	}
}

// TestX87ExecutesCorrectly compiles the lifted code against the real runtime
// header and checks the results numerically.
func TestX87ExecutesCorrectly(t *testing.T) {
	cc, err := exec.LookPath("cc")
	if err != nil {
		t.Skip("no C compiler available")
	}
	hdr, err := filepath.Abs("../runtime/core")
	if err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(filepath.Join(hdr, "recomp_context.h")); err != nil {
		t.Skip("runtime header not found")
	}

	seq := func(parts ...[]byte) []byte {
		var b []byte
		for _, p := range parts {
			b = append(b, p...)
		}
		return b
	}
	var (
		fldQRax   = []byte{0xdd, 0x00} // fld qword [rax]
		fstpTRbx  = []byte{0xdb, 0x3b} // fstp tword [rbx]
		fldTRbx   = []byte{0xdb, 0x2b} // fld tword [rbx]
		fstpQRcx  = []byte{0xdd, 0x19} // fstp qword [rcx]
		fstQRcx   = []byte{0xdd, 0x11} // fst qword [rcx]
		fld1      = []byte{0xd9, 0xe8}
		fldz      = []byte{0xd9, 0xee}
		fstpSt0   = []byte{0xdd, 0xd8}
		fstpSt1   = []byte{0xdd, 0xd9}
		faddSt0_2 = []byte{0xd8, 0xc2}
		fdivSt0_1 = []byte{0xd8, 0xf1}
		fdivrS0_1 = []byte{0xd8, 0xf9}
		fsubrpS2  = []byte{0xde, 0xe2}
		fistpQRcx = []byte{0xdf, 0x39}
		fldcwRdx  = []byte{0xd9, 0x2a}
	)

	type step struct {
		name string
		code []byte
	}
	steps := []step{
		// 1874.0 -> m80 -> check raw bytes in C, then back to double.
		{"m80", seq(fldQRax, fstpTRbx, fldTRbx, fstpQRcx)},
		// fld1; fldz; fstp st0 -> ST0 must still be 1.0
		{"fstp_st0", seq(fld1, fldz, fstpSt0, fstpQRcx)},
		// fld1; fldz; fstp st1 -> ST0 = 0.0 (old ST0 moved into ST1 then popped)
		{"fstp_st1", seq(fld1, fldz, fstpSt1, fstpQRcx)},
		// fst does not pop: fld1; fldz; fst [rcx]; fstp st0; fstp [rcx+8] => 0, 1
		{"fst", seq(fld1, fldz, fstQRcx, fstpSt0, []byte{0xdd, 0x59, 0x08})},
		// [rax]=1874: fld1, fldz, fld [rax] => ST0=1874 ST1=0 ST2=1; fadd st0,st2 => 1875
		{"fadd", seq(fld1, fldz, fldQRax, faddSt0_2, fstpQRcx)},
		// fld1; fld [rax]; fdiv st0,st1 => 1874/1 ; fdivr st0,st1 => 1/1874
		{"fdiv", seq(fld1, fldQRax, fdivSt0_1, fdivrS0_1, fstpQRcx)},
		// fld [rax]; fld1; fld1 => ST0=1 ST1=1 ST2=1874; fsubrp st2 => ST1 = 1 - 1874 after pop
		{"fsubrp", seq(fldQRax, fld1, fld1, fsubrpS2, fstpSt0, fstpQRcx)},
		// [rax+8]=2.5 ; default RC nearest-even => 2 ; truncate RC => [rdx+2]=0x0f7f
		{"fistp_rne", seq([]byte{0xdd, 0x40, 0x08}, fistpQRcx)},
		{"fistp_trunc", seq([]byte{0xd9, 0x6a, 0x02}, []byte{0xdd, 0x40, 0x10}, fistpQRcx, fldcwRdx)},
		// fld [rax]=1874 ; fxtract => ST0 = 1.830078125, ST1 = 10
		{"fxtract", seq(fldQRax, []byte{0xd9, 0xf4}, fstpQRcx, []byte{0xdd, 0x59, 0x08})},
	}

	var src strings.Builder
	src.WriteString("#include \"recomp_context.h\"\n_Thread_local GuestContext *g_current_ctx;\n")
	for i, s := range steps {
		src.WriteString("static void step_" + string(rune('a'+i)) + "(GuestContext *ctx) {\n")
		for _, line := range liftX87Bytes(t, s.code) {
			src.WriteString(line + "\n")
		}
		src.WriteString("}\n")
	}
	src.WriteString(`
static double rd(GuestContext *ctx, uint64_t a) { double d; memcpy(&d, ctx->mem_base + a, 8); return d; }
static void wr(GuestContext *ctx, uint64_t a, double d) { memcpy(ctx->mem_base + a, &d, 8); }
static void reset(GuestContext *ctx) {
  memset(ctx->mem_base, 0, 4096);
  ctx->fpu_top = 0; ctx->fpu_cw = 0x037f; ctx->fpu_sw = 0;
  ctx->rax = 0x100; ctx->rbx = 0x200; ctx->rcx = 0x300; ctx->rdx = 0x400;
  wr(ctx, 0x100, 1874.0); wr(ctx, 0x108, 2.5); wr(ctx, 0x110, 2.7);
  *(uint16_t *)(ctx->mem_base + 0x400) = 0x037f;
  *(uint16_t *)(ctx->mem_base + 0x402) = 0x0f7f;
}
int main(void) {
  static uint8_t mem[4096];
  static GuestContext c; GuestContext *ctx = &c; ctx->mem_base = mem;
  int bad = 0;
#define CHECK(cond) do { if (!(cond)) { printf("FAIL %s line %d\n", #cond, __LINE__); bad = 1; } } while (0)
  reset(ctx); step_a(ctx);
  { static const uint8_t want[10] = {0,0,0,0,0,0,0x40,0xea,0x09,0x40};
    CHECK(memcmp(mem + 0x200, want, 10) == 0); }
  CHECK(rd(ctx, 0x300) == 1874.0); CHECK(ctx->fpu_top == 0);
  reset(ctx); step_b(ctx); CHECK(rd(ctx, 0x300) == 1.0); CHECK(ctx->fpu_top == 0);
  reset(ctx); step_c(ctx); CHECK(rd(ctx, 0x300) == 0.0); CHECK(ctx->fpu_top == 0);
  reset(ctx); step_d(ctx); CHECK(rd(ctx, 0x300) == 0.0); CHECK(rd(ctx, 0x308) == 1.0); CHECK(ctx->fpu_top == 0);
  reset(ctx); step_e(ctx); CHECK(rd(ctx, 0x300) == 1875.0); CHECK(ctx->fpu_top == 6);
  reset(ctx); step_f(ctx); CHECK(rd(ctx, 0x300) == 1.0 / 1874.0); CHECK(ctx->fpu_top == 7);
  reset(ctx); step_g(ctx); CHECK(rd(ctx, 0x300) == 1.0 - 1874.0); CHECK(ctx->fpu_top == 0);
  reset(ctx); step_h(ctx); CHECK(*(int64_t *)(mem + 0x300) == 2);
  reset(ctx); step_i(ctx); CHECK(*(int64_t *)(mem + 0x300) == 2);
  reset(ctx); step_j(ctx); CHECK(rd(ctx, 0x300) == 1.830078125); CHECK(rd(ctx, 0x308) == 10.0); CHECK(ctx->fpu_top == 0);
  return bad;
}
`)
	dir := t.TempDir()
	cfile := filepath.Join(dir, "x87.c")
	if err := os.WriteFile(cfile, []byte(src.String()), 0o644); err != nil {
		t.Fatal(err)
	}
	bin := filepath.Join(dir, "x87")
	if out, err := exec.Command(cc, "-std=gnu11", "-O1", "-I", hdr, cfile, "-o", bin, "-lm").CombinedOutput(); err != nil {
		t.Fatalf("compile failed: %v\n%s\n--- source ---\n%s", err, out, src.String())
	}
	if out, err := exec.Command(bin).CombinedOutput(); err != nil {
		t.Fatalf("x87 execution checks failed: %v\n%s\n--- source ---\n%s", err, out, src.String())
	}
}
