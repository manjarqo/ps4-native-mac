// SPDX-License-Identifier: GPL-2.0-or-later

package cli

import (
	"bytes"
	"encoding/json"
	"io"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"testing"

	"ps4-recomp/pkg/fpkg/fpkgtest"
	"ps4-recomp/pkg/sfo"
)

func runJSON(t *testing.T, args ...string) (lines []map[string]any, err error) {
	var buf bytes.Buffer
	old := stdout
	stdout = &buf
	defer func() { stdout = old }()
	err = Execute(args)
	for _, l := range strings.Split(strings.TrimSpace(buf.String()), "\n") {
		var m map[string]any
		if json.Unmarshal([]byte(l), &m) != nil {
			t.Fatalf("not JSON: %q", l)
		}
		lines = append(lines, m)
	}
	return lines, err
}

func TestInspectAndImportJSON(t *testing.T) {
	p, err := fpkgtest.BuildTestPKG(t.TempDir(), []sfo.Entry{{Key: "TITLE_ID", Str: "CUSA00557"}, {Key: "CATEGORY", Str: "gd"},
		{Key: "APP_VER", Str: "01.00"}, {Key: "TITLE", Str: "T"}, {Key: "CONTENT_ID", Str: "UP9000-CUSA00557_00-T"}},
		map[string][]byte{"eboot.bin": []byte("ELF")}, fpkgtest.Opts{})
	if err != nil {
		t.Fatal(err)
	}
	ls, err := runJSON(t, "inspect", p, "--json")
	if err != nil {
		t.Fatal(err)
	}
	last := ls[len(ls)-1]
	r := last["result"].(map[string]any)
	if last["event"] != "done" || r["kind"] != "game" || r["signing"] != "fake" || r["title_id"] != "CUSA00557" {
		t.Errorf("inspect = %v", last)
	}
	lib := t.TempDir()
	ls, err = runJSON(t, "import", p, "--library", lib, "--json")
	if err != nil || ls[len(ls)-1]["event"] != "done" {
		t.Fatalf("import: %v %v", err, ls)
	}
	sawProgress := false
	for _, l := range ls {
		sawProgress = sawProgress || l["event"] == "progress"
	}
	if !sawProgress {
		t.Error("no progress events")
	}
}

func TestInspectRetailIsError(t *testing.T) {
	p, _ := fpkgtest.BuildTestPKG(t.TempDir(), []sfo.Entry{{Key: "TITLE_ID", Str: "CUSA00557"}, {Key: "CATEGORY", Str: "gd"}, {Key: "CONTENT_ID", Str: "UP9000-CUSA00557_00-T"}},
		map[string][]byte{"eboot.bin": {1}}, fpkgtest.Opts{Retail: true})
	ls, _ := runJSON(t, "inspect", p, "--json")
	last := ls[len(ls)-1]
	if last["event"] != "done" || last["result"].(map[string]any)["signing"] != "retail" {
		t.Errorf("inspect retail = %v", last)
	}
	ls, err := runJSON(t, "import", p, "--library", t.TempDir(), "--json")
	if err == nil || ls[len(ls)-1]["code"] != "retail_pkg" {
		t.Errorf("import retail = %v %v", err, ls)
	}
	if n := countEvents(ls, "error"); n != 1 {
		t.Errorf("%d error events, want 1", n)
	}
}

func countEvents(ls []map[string]any, kind string) int {
	n := 0
	for _, l := range ls {
		if l["event"] == kind {
			n++
		}
	}
	return n
}

func writeFile(path string, b []byte) error {
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return err
	}
	return os.WriteFile(path, b, 0o644)
}

func TestEngineErrorsEmitOneEvent(t *testing.T) {
	notPKG := filepath.Join(t.TempDir(), "x.pkg")
	if err := writeFile(notPKG, []byte("not a pkg at all, just bytes")); err != nil {
		t.Fatal(err)
	}
	cases := []struct {
		args []string
		code string
	}{
		{[]string{"inspect", "--json"}, "bad_input"},
		{[]string{"inspect", filepath.Join(t.TempDir(), "missing"), "--json"}, "bad_input"},
		{[]string{"inspect", notPKG, "--json"}, "bad_pkg"},
		{[]string{"import", notPKG, "--json"}, "bad_input"},
		{[]string{"import", notPKG, "--library", t.TempDir(), "--bogus", "--json"}, "bad_input"},
		{[]string{"analyze-game", t.TempDir(), "--json"}, "bad_input"},
		{[]string{"analyze-game", filepath.Join(t.TempDir(), "missing"), "--json"}, "bad_input"},
	}
	for _, c := range cases {
		ls, err := runJSON(t, c.args...)
		last := ls[len(ls)-1]
		if err == nil || last["code"] != c.code || countEvents(ls, "error") != 1 {
			t.Errorf("%v: err=%v events=%v, want one %s error", c.args, err, ls, c.code)
		}
	}
}

func TestInspectFolder(t *testing.T) {
	dir := t.TempDir()
	param := sfo.Build([]sfo.Entry{{Key: "TITLE_ID", Str: "CUSA00001"}, {Key: "CATEGORY", Str: "gd"},
		{Key: "VERSION", Str: "01.05"}, {Key: "TITLE", Str: "F"}})
	if err := writeFile(filepath.Join(dir, "sce_sys", "param.sfo"), param); err != nil {
		t.Fatal(err)
	}
	if err := writeFile(filepath.Join(dir, "sce_sys", "icon0.png"), []byte("PNG")); err != nil {
		t.Fatal(err)
	}
	ls, err := runJSON(t, "inspect", dir, "--json")
	if err != nil {
		t.Fatal(err)
	}
	r := ls[len(ls)-1]["result"].(map[string]any)
	if r["kind"] != "folder" || r["signing"] != "none" || r["app_ver"] != "01.05" || r["version"] != "01.05" ||
		r["unpacked_size"] != r["packed_size"] || r["icon_path"] == "" {
		t.Errorf("folder inspect = %v", r)
	}
}

// analyze-game --json must keep stdout to JSON lines, including whatever AnalyzeBinary prints.
func TestAnalyzeGameStdoutIsJSON(t *testing.T) {
	elf, err := os.ReadFile("../../hello_world.elf")
	if err != nil {
		t.Skip("sample ELF not found")
	}
	dir := t.TempDir()
	param := sfo.Build([]sfo.Entry{{Key: "TITLE_ID", Str: "CUSA00001"}, {Key: "CATEGORY", Str: "gd"},
		{Key: "VERSION", Str: "01.05"}, {Key: "TITLE", Str: "F"}})
	if err := writeFile(filepath.Join(dir, "sce_sys", "param.sfo"), param); err != nil {
		t.Fatal(err)
	}
	if err := writeFile(filepath.Join(dir, "eboot.bin"), elf); err != nil {
		t.Fatal(err)
	}
	r, w, err := os.Pipe()
	if err != nil {
		t.Fatal(err)
	}
	oldOut := os.Stdout
	os.Stdout = w
	var buf bytes.Buffer
	oldW := stdout
	stdout = &buf
	runErr := Execute([]string{"analyze-game", dir, "--json"})
	stdout, os.Stdout = oldW, oldOut
	w.Close()
	raw, _ := io.ReadAll(r)
	if runErr != nil {
		t.Fatal(runErr)
	}
	if len(raw) != 0 {
		t.Errorf("process stdout got non-event output: %q", raw)
	}
	lines := strings.Split(strings.TrimSpace(buf.String()), "\n")
	for _, l := range lines {
		if !json.Valid([]byte(l)) {
			t.Errorf("not JSON: %q", l)
		}
	}
	if !strings.Contains(lines[len(lines)-1], `"event":"done"`) {
		t.Errorf("last line = %q", lines[len(lines)-1])
	}
}

func TestInspectEmptyAppVerFallsBackToVersion(t *testing.T) {
	dir := t.TempDir()
	param := sfo.Build([]sfo.Entry{{Key: "TITLE_ID", Str: "CUSA00001"}, {Key: "CATEGORY", Str: "gd"},
		{Key: "APP_VER", Str: ""}, {Key: "VERSION", Str: "01.05"}})
	if err := writeFile(filepath.Join(dir, "sce_sys", "param.sfo"), param); err != nil {
		t.Fatal(err)
	}
	ls, err := runJSON(t, "inspect", dir, "--json")
	if err != nil {
		t.Fatal(err)
	}
	if r := ls[len(ls)-1]["result"].(map[string]any); r["app_ver"] != "01.05" {
		t.Errorf("app_ver = %v, want 01.05", r["app_ver"])
	}
}

func TestVersionJSON(t *testing.T) {
	ls, err := runJSON(t, "version", "--json")
	if err != nil {
		t.Fatal(err)
	}
	if len(ls) != 1 || ls[0]["event"] != "done" || ls[0]["op"] != "version" {
		t.Fatalf("lines: %v", ls)
	}
	res := ls[0]["result"].(map[string]any)
	if res["version"] != Version || res["go"] != runtime.Version() {
		t.Fatalf("result: %v", res)
	}
}
