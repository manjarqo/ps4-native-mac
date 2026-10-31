package emitter

import (
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
)

// The first branch is initially within imm19 range. Relaxing the dense run of
// branches after it moves its target beyond that range.
func denseBranchFunction() string {
	return ".text\n.globl _dense_probe\n_dense_probe:\ncmp w0, #0\nb.eq L_dense_mid\nmov w0, #1\nret\n" +
		strings.Repeat("b.ne L_dense_end\n", 100000) + strings.Repeat("nop\n", 90000) +
		"L_dense_mid:\nmov w0, #2\nret\n" + strings.Repeat("nop\n", 210000) + "L_dense_end:\nret\n"
}

func TestRelaxExpansionKeepsBranchInRange(t *testing.T) {
	out := string(relaxFarBranches([]byte(denseBranchFunction()), 0x3000))
	// Measure the final displacement independently of the relaxer's positions.
	pc, branch, target := 0, -1, -1
	for _, line := range strings.Split(out, "\n") {
		line = strings.TrimSpace(line)
		if line == "L_dense_mid:" {
			target = pc
		}
		if line == "b.eq L_dense_mid" {
			branch = pc
		}
		if line != "" && line[0] != '.' && !strings.HasSuffix(line, ":") {
			pc++
		}
	}
	if target < 0 {
		t.Fatal("missing branch target")
	}
	if branch >= 0 && target-branch > 262143 {
		t.Fatalf("short conditional branch displaced %d instructions after relaxation (maximum 262143)", target-branch)
	}
}

func TestRelaxExpansionAssemblesAndExecutes(t *testing.T) {
	if runtime.GOOS != "darwin" || runtime.GOARCH != "arm64" {
		t.Skip("requires arm64 macOS")
	}
	dir := t.TempDir()
	s, c, exe := filepath.Join(dir, "dense.s"), filepath.Join(dir, "main.c"), filepath.Join(dir, "dense")
	if err := os.WriteFile(s, relaxFarBranches([]byte(denseBranchFunction()), 0x3000), 0600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(c, []byte("#include <assert.h>\nextern int dense_probe(int);\nint main(void) { assert(dense_probe(0) == 2); assert(dense_probe(1) == 1); }\n"), 0600); err != nil {
		t.Fatal(err)
	}
	for _, cmd := range []*exec.Cmd{exec.Command("clang", s, c, "-o", exe), exec.Command(exe)} {
		if out, err := cmd.CombinedOutput(); err != nil {
			t.Fatalf("%s: %v\n%s", cmd.Args[0], err, out)
		}
	}
}

// bigFunction is a function with conditional branches across more than a megabyte of code,
// the shape of a big switch function's jump table compare chain.
func bigFunction(pad int) string {
	var b strings.Builder
	b.WriteString(".globl _fn_0x1000\n_fn_0x1000:\n    str x30, [sp, #-16]!\n")
	b.WriteString("\nL_fn_0x1000_loc_0x1000:\n")
	b.WriteString("    b.ne L_fn_0x1000_loc_0x2000 // far forward\n")
	b.WriteString("    cbz x16, L_fn_0x1000_loc_0x2000\n")
	b.WriteString("    tbnz x17, #3, L_fn_0x1000_loc_0x2000\n")
	b.WriteString("    cbz x16, 1f\n    nop\n1:\n")
	b.WriteString("    b.eq L_fn_0x1000_near\n    nop\nL_fn_0x1000_near:\n")
	for range pad {
		b.WriteString("    nop\n")
	}
	b.WriteString("\nL_fn_0x1000_loc_0x2000:\n")
	b.WriteString("    cbnz w0, L_fn_0x1000_loc_0x1000\n")
	b.WriteString("    b.hs L_fn_0x1000_loc_0x1000\n")
	b.WriteString("    ldr x30, [sp], #16\n    ret\n\n")
	return b.String()
}

func TestRelaxFarBranchesRewrite(t *testing.T) {
	out := string(relaxFarBranches([]byte(bigFunction(300000)), 0x1000))
	for _, want := range []string{
		"    b.eq L_fn_0x1000_rlx_0\n    b L_fn_0x1000_loc_0x2000\nL_fn_0x1000_rlx_0:",
		"    cbnz x16, L_fn_0x1000_rlx_1\n    b L_fn_0x1000_loc_0x2000\nL_fn_0x1000_rlx_1:",
		"    tbz x17, #3, L_fn_0x1000_rlx_2\n    b L_fn_0x1000_loc_0x2000\nL_fn_0x1000_rlx_2:",
		"    cbz x16, 1f\n",
		"    b.eq L_fn_0x1000_near\n",
		"    cbz w0, L_fn_0x1000_rlx_3\n    b L_fn_0x1000_loc_0x1000\n",
		"    b.lo L_fn_0x1000_rlx_4\n    b L_fn_0x1000_loc_0x1000\n",
	} {
		if !strings.Contains(out, want) {
			t.Errorf("missing %q", want)
		}
	}

	small := bigFunction(100)
	if got := string(relaxFarBranches([]byte(small), 0x1000)); got != small {
		t.Errorf("small function changed")
	}
}

// TestRelaxFarBranchesAssembles assembles a relaxed function too big for the unrelaxed one
// to assemble.
func TestRelaxFarBranchesAssembles(t *testing.T) {
	if runtime.GOARCH != "arm64" {
		t.Skip("needs an arm64 assembler")
	}
	clang, err := exec.LookPath("clang")
	if err != nil {
		t.Skip("no clang")
	}
	dir := t.TempDir()
	src := bigFunction(300000)
	asm := func(name, text string) error {
		p := filepath.Join(dir, name+".s")
		if err := os.WriteFile(p, []byte(text), 0o644); err != nil {
			t.Fatal(err)
		}
		return exec.Command(clang, "-c", "-arch", "arm64", p, "-o", filepath.Join(dir, name+".o")).Run()
	}
	if asm("plain", src) == nil {
		t.Fatal("unrelaxed function assembled: the test function is not big enough")
	}
	if err := asm("relaxed", string(relaxFarBranches([]byte(src), 0x1000))); err != nil {
		t.Fatalf("relaxed function: %v", err)
	}
}
