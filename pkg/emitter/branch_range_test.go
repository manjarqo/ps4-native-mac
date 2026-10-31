package emitter

import (
	"bytes"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
)

// Block targets can be more than 1 MiB away after x86-to-ARM64 expansion.
// Assemble and execute both outcomes, in both directions, rather than comparing text.
func TestDistantBlockBranches(t *testing.T) {
	if runtime.GOOS != "darwin" || runtime.GOARCH != "arm64" {
		t.Skip("requires arm64 macOS")
	}
	var asm bytes.Buffer
	asm.WriteString(".text\n.p2align 2\n")
	cases := []struct {
		op    string
		taken int
	}{{"b.eq", 0}, {"b.ne", 1}, {"cbz x0,", 0}, {"cbnz x0,", 1}, {"tbz x0, #0,", 0}, {"tbnz x0, #0,", 1}}
	var driver bytes.Buffer
	driver.WriteString("#include <assert.h>\n")
	for i, c := range cases {
		for d := 0; d < 2; d++ {
			id := i*2 + d
			var fn bytes.Buffer
			target := fmt.Sprintf("L_fn_far_%d", id)
			fmt.Fprintf(&driver, "extern int probe%d(int);\n", id)
			if d == 1 {
				fmt.Fprintf(&fn, "%s:\nmov w0, #2\nret\n%s", target, strings.Repeat("    nop\n", 262150))
			}
			fmt.Fprintf(&fn, ".globl _probe%d\n_probe%d:\ncmp w0, #0\n", id, id)
			fmt.Fprintf(&fn, "    %s %s\n", c.op, target)
			fn.WriteString("mov w0, #1\nret\n")
			if d == 0 {
				fmt.Fprintf(&fn, "%s%s:\nmov w0, #2\nret\n", strings.Repeat("    nop\n", 262150), target)
			}
			asm.Write(relaxFarBranches(fn.Bytes(), uint64(id)))
		}
	}
	driver.WriteString("int main(void) {\n")
	for i, c := range cases {
		for d := 0; d < 2; d++ {
			fmt.Fprintf(&driver, "assert(probe%d(%d)==2); assert(probe%d(%d)==1);\n", i*2+d, c.taken, i*2+d, 1-c.taken)
		}
	}
	driver.WriteString("return 0; }\n")
	dir := t.TempDir()
	s := filepath.Join(dir, "branch.s")
	c := filepath.Join(dir, "main.c")
	out := filepath.Join(dir, "probe")
	if err := os.WriteFile(s, asm.Bytes(), 0600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(c, driver.Bytes(), 0600); err != nil {
		t.Fatal(err)
	}
	if b, err := exec.Command("clang", s, c, "-o", out).CombinedOutput(); err != nil {
		t.Fatalf("assemble distant branches: %v\n%s", err, b)
	}
	if b, err := exec.Command(out).CombinedOutput(); err != nil {
		t.Fatalf("branch outcomes: %v\n%s", err, b)
	}
}
