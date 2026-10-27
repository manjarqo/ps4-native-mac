package analyzer

import (
	"io"
	"os"
	"testing"
)

func TestAnalyzeBinary(t *testing.T) {
	elfPath := os.Getenv("PS4_TEST_ELF")
	if elfPath == "" {
		elfPath = "../../hello_world.elf"
	}
	if _, err := os.Stat(elfPath); err != nil {
		t.Skipf("Sample ELF %s not found", elfPath)
	}

	report, err := AnalyzeBinary(elfPath)
	if err != nil {
		t.Fatalf("AnalyzeBinary failed: %v", err)
	}

	if report.TotalInstructions == 0 {
		t.Errorf("Expected instructions to be found, got 0")
	}

	if report.CoveragePercent < 90.0 {
		t.Errorf("Expected high instruction coverage, got %.2f%%", report.CoveragePercent)
	}

	t.Logf("\n%s", report.SummaryString())
}

// AnalyzeBinary's progress goes to stderr: callers that print JSON on stdout rely on it.
func TestAnalyzeBinaryWritesNothingToStdout(t *testing.T) {
	if _, err := os.Stat("../../hello_world.elf"); err != nil {
		t.Skip("sample ELF not found")
	}
	r, w, err := os.Pipe()
	if err != nil {
		t.Fatal(err)
	}
	old := os.Stdout
	os.Stdout = w
	_, aerr := AnalyzeBinary("../../hello_world.elf")
	os.Stdout = old
	w.Close()
	out, _ := io.ReadAll(r)
	if aerr != nil {
		t.Fatal(aerr)
	}
	if len(out) != 0 {
		t.Errorf("AnalyzeBinary wrote to stdout: %q", out)
	}
}
