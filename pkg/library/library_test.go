// SPDX-License-Identifier: GPL-2.0-or-later

package library

import (
	"bytes"
	"encoding/json"
	"errors"
	"maps"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"sync"
	"testing"
	"time"

	"ps4-recomp/pkg/events"
	"ps4-recomp/pkg/fpkg"
	"ps4-recomp/pkg/fpkg/fpkgtest"
	"ps4-recomp/pkg/sfo"
)

func sfoFor(cat, ver, contentID string) []sfo.Entry {
	return []sfo.Entry{{Key: "TITLE_ID", Str: "CUSA04529"}, {Key: "CATEGORY", Str: cat},
		{Key: "APP_VER", Str: ver}, {Key: "TITLE", Str: "Test"}, {Key: "CONTENT_ID", Str: contentID}}
}

func pkgFile(t *testing.T, cat, ver, cid string, files map[string][]byte) string {
	p, err := fpkgtest.BuildTestPKG(t.TempDir(), sfoFor(cat, ver, cid), files, fpkgtest.Opts{})
	if err != nil {
		t.Fatal(err)
	}
	return p
}

func asCode(err error, t **events.CodeError) bool { return errors.As(err, t) }

func ev() *events.Writer { return events.New(&bytes.Buffer{}, "import", true) }

func TestGameThenPatchThenDLC(t *testing.T) {
	l := Library{Root: t.TempDir()}
	base := pkgFile(t, "gd", "01.00", "UP9000-CUSA04529_00-BASE", map[string][]byte{"eboot.bin": []byte("v100"), "a.dat": []byte("A")})
	if _, err := l.Import(base, "copy", ev(), nil); err != nil {
		t.Fatal(err)
	}
	patch := pkgFile(t, "gp", "01.32", "UP9000-CUSA04529_00-PATCH", map[string][]byte{"eboot.bin": []byte("v132")})
	if _, err := l.Import(patch, "copy", ev(), nil); err != nil {
		t.Fatal(err)
	}
	dlc := pkgFile(t, "ac", "01.00", "UP9000-CUSA04529_00-EXTRAPACK", map[string][]byte{"dlc.dat": []byte("D")})
	if _, err := l.Import(dlc, "copy", ev(), nil); err != nil {
		t.Fatal(err)
	}
	c := l.ContentDir("CUSA04529")
	if b, _ := os.ReadFile(filepath.Join(c, "eboot.bin")); string(b) != "v132" {
		t.Errorf("patched eboot = %q", b)
	}
	if b, _ := os.ReadFile(filepath.Join(c, "a.dat")); string(b) != "A" {
		t.Errorf("base file lost: %q", b)
	}
	if b, _ := os.ReadFile(filepath.Join(c, "addcont", "EXTRAPACK", "dlc.dat")); string(b) != "D" {
		t.Errorf("dlc = %q", b)
	}
	games, _ := l.Load()
	g := games["CUSA04529"]
	if g == nil || g.AppVer != "01.32" || len(g.Patches) != 1 || len(g.DLC) != 1 {
		t.Errorf("library = %+v", g)
	}
	if _, err := os.Stat(c + ".partial"); !os.IsNotExist(err) {
		t.Error("partial dir left")
	}
}

func TestPatchBeforeBase(t *testing.T) {
	l := Library{Root: t.TempDir()}
	r, err := l.Import(pkgFile(t, "gp", "01.32", "UP9000-CUSA04529_00-PATCH", map[string][]byte{"eboot.bin": []byte("v132")}), "copy", ev(), nil)
	if err != nil || !r.Pending {
		t.Fatalf("pending: %+v %v", r, err)
	}
	if _, err := l.Import(pkgFile(t, "gd", "01.00", "UP9000-CUSA04529_00-BASE", map[string][]byte{"eboot.bin": []byte("v100")}), "copy", ev(), nil); err != nil {
		t.Fatal(err)
	}
	if b, _ := os.ReadFile(filepath.Join(l.ContentDir("CUSA04529"), "eboot.bin")); string(b) != "v132" {
		t.Errorf("pending patch not applied: %q", b)
	}
}

func TestRetailRejectedAndCleaned(t *testing.T) {
	l := Library{Root: t.TempDir()}
	p, _ := fpkgtest.BuildTestPKG(t.TempDir(), sfoFor("gd", "01.00", "UP9000-CUSA04529_00-BASE"), map[string][]byte{"eboot.bin": {1}}, fpkgtest.Opts{Retail: true})
	_, err := l.Import(p, "copy", ev(), nil)
	var ce *events.CodeError
	if !asCode(err, &ce) || ce.Code != "retail_pkg" {
		t.Fatalf("err = %v", err)
	}
	if _, err := os.Stat(l.GameDir("CUSA04529")); !os.IsNotExist(err) {
		t.Error("game dir created for a retail PKG")
	}
}

func TestFolderReferenceAndCopy(t *testing.T) {
	src := t.TempDir()
	os.MkdirAll(filepath.Join(src, "sce_sys"), 0o755)
	os.WriteFile(filepath.Join(src, "eboot.bin"), []byte("ELF"), 0o644)
	os.WriteFile(filepath.Join(src, "sce_sys", "param.sfo"), sfo.Build(sfoFor("gd", "01.00", "UP9000-CUSA04529_00-BASE")), 0o644)
	for _, mode := range []string{"copy", "reference"} {
		l := Library{Root: t.TempDir()}
		if _, err := l.Import(src, mode, ev(), nil); err != nil {
			t.Fatalf("%s: %v", mode, err)
		}
		if b, _ := os.ReadFile(filepath.Join(l.ContentDir("CUSA04529"), "eboot.bin")); string(b) != "ELF" {
			t.Errorf("%s: eboot = %q", mode, b)
		}
		fi, _ := os.Lstat(l.ContentDir("CUSA04529"))
		if (mode == "reference") != (fi.Mode()&os.ModeSymlink != 0) {
			t.Errorf("%s: mode %v", mode, fi.Mode())
		}
	}
}

func TestSaveIsAtomic(t *testing.T) {
	l := Library{Root: t.TempDir()}
	g := map[string]*Game{"CUSA00557": {TitleID: "CUSA00557", Title: "T"}}
	if err := l.Save(g); err != nil {
		t.Fatal(err)
	}
	entries, _ := os.ReadDir(l.Root)
	for _, e := range entries {
		if filepath.Ext(e.Name()) == ".tmp" {
			t.Errorf("temp file left: %s", e.Name())
		}
	}
	back, err := l.Load()
	if err != nil || back["CUSA00557"].Title != "T" {
		t.Errorf("load = %v %v", back, err)
	}
}

// The tests below go beyond the plan's list: resume, cancellation, error codes, the
// APP_VER fallback and the folder CATEGORY warning.

func TestResumeSkipsCompleteFiles(t *testing.T) {
	l := Library{Root: t.TempDir()}
	base := pkgFile(t, "gd", "01.00", "UP9000-CUSA04529_00-BASE", map[string][]byte{"eboot.bin": []byte("v100"), "a.dat": []byte("AAAA")})
	partial := l.ContentDir("CUSA04529") + ".partial"
	os.MkdirAll(partial, 0o755)
	writeMarker(t, partial, base, "UP9000-CUSA04529_00-BASE")
	// A complete file from an earlier run (same size, final name) is kept; a file
	// still under its in-progress name is not trusted and is written again.
	os.WriteFile(filepath.Join(partial, "eboot.bin"), []byte("KEEP"), 0o644)
	os.WriteFile(filepath.Join(partial, fpkg.PartName("a.dat")), []byte("AA"), 0o644)
	var out bytes.Buffer
	if _, err := l.Import(base, "copy", events.New(&out, "import", true), nil); err != nil {
		t.Fatal(err)
	}
	c := l.ContentDir("CUSA04529")
	if b, _ := os.ReadFile(filepath.Join(c, "eboot.bin")); string(b) != "KEEP" {
		t.Errorf("complete file re-extracted: %q", b)
	}
	if b, _ := os.ReadFile(filepath.Join(c, "a.dat")); string(b) != "AAAA" {
		t.Errorf("a.dat = %q", b)
	}
	if _, err := os.Stat(filepath.Join(c, fpkg.PartName("a.dat"))); !os.IsNotExist(err) {
		t.Error("stale scratch file kept in content")
	}
	if !bytes.Contains(out.Bytes(), []byte(`"stage":"extract"`)) || !bytes.Contains(out.Bytes(), []byte(`"unit":"bytes"`)) {
		t.Errorf("no extract progress: %s", out.Bytes())
	}
}

func TestFolderCopyResumeAndSkips(t *testing.T) {
	src := t.TempDir()
	os.MkdirAll(filepath.Join(src, "sce_sys"), 0o755)
	os.WriteFile(filepath.Join(src, "eboot.bin"), []byte("ELF"), 0o644)
	os.WriteFile(filepath.Join(src, "data.bin"), []byte("1234"), 0o644)
	os.WriteFile(filepath.Join(src, "._eboot.bin"), []byte("appledouble"), 0o644)
	os.WriteFile(filepath.Join(src, ".DS_Store"), []byte("finder"), 0o644)
	os.WriteFile(filepath.Join(src, "sce_sys", "param.sfo"), sfo.Build(sfoFor("gd", "01.00", "UP9000-CUSA04529_00-BASE")), 0o644)
	l := Library{Root: t.TempDir()}
	partial := l.ContentDir("CUSA04529") + ".partial"
	os.MkdirAll(filepath.Join(partial, "gone"), 0o755)
	resolved, _ := filepath.EvalSymlinks(src)
	os.WriteFile(filepath.Join(partial, resumeMarker), []byte("folder UP9000-CUSA04529_00-BASE "+resolved+"\n"), 0o644)
	// Same size, different bytes: SHA-256 differs, so it must be copied again.
	os.WriteFile(filepath.Join(partial, "data.bin"), []byte("XXXX"), 0o644)
	// Files and directories the source does not have are pruned.
	os.WriteFile(filepath.Join(partial, "stale.bin"), []byte("S"), 0o644)
	os.WriteFile(filepath.Join(partial, "gone", "x"), []byte("S"), 0o644)
	if _, err := l.Import(src, "copy", ev(), nil); err != nil {
		t.Fatal(err)
	}
	c := l.ContentDir("CUSA04529")
	if b, _ := os.ReadFile(filepath.Join(c, "data.bin")); string(b) != "1234" {
		t.Errorf("data.bin = %q", b)
	}
	for _, n := range []string{"stale.bin", "gone", resumeMarker} {
		if exists(filepath.Join(c, n)) {
			t.Errorf("%s is in content", n)
		}
	}
	for _, n := range []string{"._eboot.bin", ".DS_Store"} {
		if _, err := os.Lstat(filepath.Join(c, n)); !os.IsNotExist(err) {
			t.Errorf("%s copied", n)
		}
	}
	if _, err := os.Stat(partial); !os.IsNotExist(err) {
		t.Error("partial dir left")
	}
}

// writeMarker gives the scratch directory dir the resume marker of the package pkg.
func writeMarker(t *testing.T, dir, pkg, contentID string) {
	t.Helper()
	st, err := os.Stat(pkg)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, resumeMarker), []byte(pkgMarker(contentID, st)), 0o644); err != nil {
		t.Fatal(err)
	}
}

// cancelOn is an event sink that closes cancel at the first event containing match.
type cancelOn struct {
	mu     sync.Mutex
	buf    bytes.Buffer
	match  string
	cancel chan struct{}
}

func (c *cancelOn) Write(b []byte) (int, error) {
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.cancel != nil && bytes.Contains(b, []byte(c.match)) {
		close(c.cancel)
		c.cancel = nil
	}
	return c.buf.Write(b)
}

func (c *cancelOn) String() string {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.buf.String()
}

// A cancelled import keeps its resumable scratch directory, and the next import of the
// same package resumes it: files completed before the cancel are not written again.
func TestCancelKeepsScratchForResume(t *testing.T) {
	l := Library{Root: t.TempDir()}
	big := bytes.Repeat([]byte("0123456789abcdef"), 1<<17) // 2 MiB, two chunks
	base := pkgFile(t, "gd", "01.00", "UP9000-CUSA04529_00-BASE", map[string][]byte{"a.dat": []byte("A"), "z/big.bin": big})
	// The first progress event follows a.dat, the first file extracted.
	sink := &cancelOn{match: `"stage":"extract"`, cancel: make(chan struct{})}
	_, err := l.Import(base, "copy", events.New(sink, "import", true), sink.cancel)
	if codeOf(err) != "cancelled" {
		t.Fatalf("err = %v", err)
	}
	if !strings.Contains(sink.String(), `"code":"cancelled"`) {
		t.Errorf("no cancelled error event: %s", sink.String())
	}
	partial := l.ContentDir("CUSA04529") + ".partial"
	done, err := os.Stat(filepath.Join(partial, "a.dat"))
	if err != nil {
		t.Fatalf("the scratch of a cancelled import was removed: %v", err)
	}
	if readMarker(partial) == "" {
		t.Error("no resume marker")
	}
	if games, _ := l.Load(); len(games) != 0 {
		t.Errorf("library after a cancel = %v", games)
	}
	mustImport(t, l, base, "copy")
	c := l.ContentDir("CUSA04529")
	again, err := os.Stat(filepath.Join(c, "a.dat"))
	if err != nil || !os.SameFile(done, again) {
		t.Errorf("a file completed before the cancel was written again: %v", err)
	}
	if b, _ := os.ReadFile(filepath.Join(c, "z", "big.bin")); !bytes.Equal(b, big) {
		t.Errorf("big.bin: %d bytes", len(b))
	}
	if exists(partial) || exists(filepath.Join(c, resumeMarker)) {
		t.Error("scratch or resume marker left after the commit")
	}
}

// A cancelled first folder copy keeps only its resumable scratch in the game directory.
func TestCancelledFolderCopyKeepsOnlyScratch(t *testing.T) {
	l := Library{Root: t.TempDir()}
	src := gameFolder(t, sfoFor("gd", "01.00", "UP9000-CUSA04529_00-BASE"))
	c := make(chan struct{})
	close(c)
	if _, err := l.Import(src, "copy", ev(), c); codeOf(err) != "cancelled" {
		t.Fatalf("err = %v", err)
	}
	// The folder copy was cancelled in its first batch: only its scratch is kept.
	entries, _ := os.ReadDir(l.GameDir("CUSA04529"))
	if len(entries) != 1 || entries[0].Name() != "content.partial" {
		t.Errorf("game dir after a cancel = %v", entries)
	}
	if games, _ := l.Load(); len(games) != 0 {
		t.Errorf("library after a cancel = %v", games)
	}
}

// A scratch directory left by another source (another version of the same TITLE_ID) is
// discarded instead of resumed.
func TestResumeMarkerMismatchDiscardsScratch(t *testing.T) {
	l := Library{Root: t.TempDir()}
	base := pkgFile(t, "gd", "01.00", "UP9000-CUSA04529_00-BASE", map[string][]byte{"eboot.bin": []byte("v100")})
	other := pkgFile(t, "gd", "01.00", "UP9000-CUSA04529_00-OTHER", map[string][]byte{"eboot.bin": []byte("vXXX")})
	partial := l.ContentDir("CUSA04529") + ".partial"
	os.MkdirAll(partial, 0o755)
	writeMarker(t, partial, other, "UP9000-CUSA04529_00-OTHER")
	os.WriteFile(filepath.Join(partial, "eboot.bin"), []byte("vXXX"), 0o644) // same size, other bytes
	mustImport(t, l, base, "copy")
	if b, _ := os.ReadFile(filepath.Join(l.ContentDir("CUSA04529"), "eboot.bin")); string(b) != "v100" {
		t.Errorf("eboot.bin = %q: a scratch of another package was resumed", b)
	}
}

func TestErrorCodes(t *testing.T) {
	l := Library{Root: t.TempDir()}
	notPKG := filepath.Join(t.TempDir(), "x.pkg")
	os.WriteFile(notPKG, []byte("this is not a package at all"), 0o644)
	noEboot := t.TempDir()
	os.MkdirAll(filepath.Join(noEboot, "sce_sys"), 0o755)
	os.WriteFile(filepath.Join(noEboot, "sce_sys", "param.sfo"), sfo.Build(sfoFor("gd", "01.00", "X")), 0o644)
	cases := []struct{ src, mode, code string }{
		{filepath.Join(t.TempDir(), "missing.pkg"), "copy", "bad_input"},
		{notPKG, "copy", "bad_pkg"},
		{noEboot, "copy", "bad_input"},
		{pkgFile(t, "gd", "01.00", "UP9000-CUSA04529_00-BASE", map[string][]byte{"eboot.bin": {1}}), "reference", "bad_input"},
		{pkgFile(t, "ac", "01.00", "UP9000-CUSA04529_00-EXTRAPACK", map[string][]byte{"d": {1}}), "copy", "bad_input"},
	}
	for _, c := range cases {
		var out bytes.Buffer
		_, err := l.Import(c.src, c.mode, events.New(&out, "import", true), nil)
		var ce *events.CodeError
		if !asCode(err, &ce) || ce.Code != c.code {
			t.Errorf("%s (%s): err = %v, want code %s", c.src, c.mode, err, c.code)
		}
		if !bytes.Contains(out.Bytes(), []byte(`"event":"error"`)) {
			t.Errorf("%s: no error event: %s", c.src, out.Bytes())
		}
	}
}

func TestFolderAppVerFallbackAndCategoryWarning(t *testing.T) {
	src := t.TempDir()
	os.MkdirAll(filepath.Join(src, "sce_sys"), 0o755)
	os.WriteFile(filepath.Join(src, "eboot.bin"), []byte("ELF"), 0o644)
	os.WriteFile(filepath.Join(src, "sce_sys", "param.sfo"), sfo.Build([]sfo.Entry{
		{Key: "TITLE_ID", Str: "CUSA00557"}, {Key: "CATEGORY", Str: "ac"},
		{Key: "VERSION", Str: "01.00"}, {Key: "TITLE", Str: "T"}}), 0o644)
	l := Library{Root: t.TempDir()}
	var out bytes.Buffer
	r, err := l.Import(src, "reference", events.New(&out, "import", true), nil)
	if err != nil {
		t.Fatal(err)
	}
	if r.Kind != "game" || r.Game.AppVer != "01.00" || r.Game.Version != "01.00" {
		t.Errorf("result = %+v %+v", r, r.Game)
	}
	if !bytes.Contains(out.Bytes(), []byte(`"event":"warning"`)) {
		t.Errorf("no CATEGORY warning: %s", out.Bytes())
	}
	if _, err := os.Stat(filepath.Join(src, "addcont")); !os.IsNotExist(err) {
		t.Error("import wrote into the referenced folder")
	}
}

// The byte copy used when the volume cannot clone.
func TestCopyTreeWithoutClone(t *testing.T) {
	src, dst := t.TempDir(), filepath.Join(t.TempDir(), "out")
	os.MkdirAll(filepath.Join(src, "d"), 0o755)
	big := bytes.Repeat([]byte("x"), 3<<20+5)
	os.WriteFile(filepath.Join(src, "d", "big.bin"), big, 0o644)
	os.WriteFile(filepath.Join(src, "eboot.bin"), []byte("ELF"), 0o755)
	im := &importer{ev: ev()}
	if err := im.copyTree(src, dst, int64(len(big))+3, false); err != nil {
		t.Fatal(err)
	}
	if b, _ := os.ReadFile(filepath.Join(dst, "d", "big.bin")); !bytes.Equal(b, big) {
		t.Errorf("big.bin: %d bytes", len(b))
	}
	if fi, err := os.Stat(filepath.Join(dst, "eboot.bin")); err != nil || fi.Mode().Perm() != 0o755 {
		t.Errorf("eboot.bin: %v %v", fi, err)
	}
}

func mustImport(t *testing.T, l Library, src, mode string) *ImportResult {
	t.Helper()
	r, err := l.Import(src, mode, ev(), nil)
	if err != nil {
		t.Fatalf("import %s: %v", src, err)
	}
	return r
}

func codeOf(err error) string {
	var ce *events.CodeError
	if asCode(err, &ce) {
		return ce.Code
	}
	return ""
}

func gameFolder(t *testing.T, entries []sfo.Entry) string {
	src := t.TempDir()
	os.MkdirAll(filepath.Join(src, "sce_sys"), 0o755)
	os.WriteFile(filepath.Join(src, "eboot.bin"), []byte("ELF"), 0o644)
	os.WriteFile(filepath.Join(src, "sce_sys", "param.sfo"), sfo.Build(entries), 0o644)
	return src
}

// snapshot maps every file under dir to its contents.
func snapshot(t *testing.T, dir string) map[string]string {
	m := map[string]string{}
	filepath.WalkDir(dir, func(path string, d os.DirEntry, err error) error {
		if err == nil && !d.IsDir() {
			b, _ := os.ReadFile(path)
			rel, _ := filepath.Rel(dir, path)
			m[rel] = string(b)
		}
		return nil
	})
	return m
}

// withoutSceSys drops the sce_sys files a PKG import writes from a snapshot.
func withoutSceSys(m map[string]string) map[string]string {
	maps.DeleteFunc(m, func(k, _ string) bool {
		return slices.Contains(strings.Split(k, string(filepath.Separator)), "sce_sys")
	})
	return m
}

// treeBytes sums the file sizes under dir.
func treeBytes(t *testing.T, dir string) int64 {
	t.Helper()
	n, err := dirSize(dir)
	if err != nil {
		t.Fatal(err)
	}
	return n
}

func TestReinstallKeepsDLC(t *testing.T) {
	l := Library{Root: t.TempDir()}
	mustImport(t, l, pkgFile(t, "gd", "01.00", "UP9000-CUSA04529_00-BASE", map[string][]byte{"eboot.bin": []byte("v100"), "old.dat": {1}}), "copy")
	mustImport(t, l, pkgFile(t, "ac", "01.00", "UP9000-CUSA04529_00-EXTRAPACK", map[string][]byte{"dlc.dat": []byte("D")}), "copy")
	mustImport(t, l, pkgFile(t, "gp", "01.32", "UP9000-CUSA04529_00-PATCH", map[string][]byte{"eboot.bin": []byte("v132")}), "copy")
	r := mustImport(t, l, pkgFile(t, "gd", "01.00", "UP9000-CUSA04529_00-BASE", map[string][]byte{"eboot.bin": []byte("v200")}), "copy")
	c := l.ContentDir("CUSA04529")
	want := map[string]string{"eboot.bin": "v200", filepath.Join("addcont", "EXTRAPACK", "dlc.dat"): "D"}
	if got := withoutSceSys(snapshot(t, c)); !maps.Equal(got, want) {
		t.Errorf("content = %v", got)
	}
	games, _ := l.Load()
	g := games["CUSA04529"]
	if !slices.Equal(g.DLC, []string{"EXTRAPACK"}) || len(g.Patches) != 0 || g.AppVer != "01.00" || g.ContentBytes != treeBytes(t, c) {
		t.Errorf("game = %+v", g)
	}
	if r.Game.ContentBytes != g.ContentBytes {
		t.Errorf("result = %+v", r.Game)
	}
	entries, _ := os.ReadDir(l.GameDir("CUSA04529"))
	if len(entries) != 1 {
		t.Errorf("scratch left in the game dir: %v", entries)
	}
}

func TestPatchRefusedForReferencedGame(t *testing.T) {
	src := gameFolder(t, sfoFor("gd", "01.00", "UP9000-CUSA04529_00-BASE"))
	before := snapshot(t, src)
	l := Library{Root: t.TempDir()}
	mustImport(t, l, src, "reference")
	_, err := l.Import(pkgFile(t, "gp", "01.32", "UP9000-CUSA04529_00-PATCH", map[string][]byte{"eboot.bin": []byte("v132")}), "copy", ev(), nil)
	if codeOf(err) != "bad_input" {
		t.Fatalf("err = %v", err)
	}
	if got := snapshot(t, src); !maps.Equal(got, before) {
		t.Errorf("referenced folder changed: %v", got)
	}
}

func TestFailedPatchLeavesGameUnchanged(t *testing.T) {
	l := Library{Root: t.TempDir()}
	mustImport(t, l, pkgFile(t, "gd", "01.00", "UP9000-CUSA04529_00-BASE", map[string][]byte{"eboot.bin": []byte("v100"), "a.dat": []byte("A"), "b.dat": []byte("B")}), "copy")
	c := l.ContentDir("CUSA04529")
	before := snapshot(t, c)
	lib, _ := os.ReadFile(filepath.Join(l.Root, "library.json"))
	n := 0
	overlayHook = func(string) error {
		if n++; n == 2 {
			return errors.New("injected failure")
		}
		return nil
	}
	defer func() { overlayHook = nil }()
	_, err := l.Import(pkgFile(t, "gp", "01.32", "UP9000-CUSA04529_00-PATCH", map[string][]byte{"eboot.bin": []byte("v132"), "a.dat": []byte("a2"), "b.dat": []byte("b2")}), "copy", ev(), nil)
	if err == nil {
		t.Fatal("patch with an injected failure succeeded")
	}
	if got := snapshot(t, c); !maps.Equal(got, before) {
		t.Errorf("content after a failed patch = %v", got)
	}
	if b, _ := os.ReadFile(filepath.Join(l.Root, "library.json")); !bytes.Equal(b, lib) {
		t.Errorf("library.json changed:\n%s", b)
	}
	for _, n := range []string{"content.next", "patch.partial", "content.old"} {
		if _, err := os.Lstat(filepath.Join(l.GameDir("CUSA04529"), n)); !os.IsNotExist(err) {
			t.Errorf("%s left", n)
		}
	}
}

func TestRecoverInterruptedCommit(t *testing.T) {
	l := Library{Root: t.TempDir()}
	mustImport(t, l, pkgFile(t, "gd", "01.00", "UP9000-CUSA04529_00-BASE", map[string][]byte{"eboot.bin": []byte("v100"), "a.dat": []byte("A")}), "copy")
	c := l.ContentDir("CUSA04529")
	// A crash after content moved to content.old, before the new tree took its place.
	if err := os.Rename(c, c+".old"); err != nil {
		t.Fatal(err)
	}
	mustImport(t, l, pkgFile(t, "gp", "01.32", "UP9000-CUSA04529_00-PATCH", map[string][]byte{"eboot.bin": []byte("v132")}), "copy")
	if got := withoutSceSys(snapshot(t, c)); !maps.Equal(got, map[string]string{"eboot.bin": "v132", "a.dat": "A"}) {
		t.Errorf("content = %v", got)
	}
	if _, err := os.Lstat(c + ".old"); !os.IsNotExist(err) {
		t.Error("content.old left")
	}
}

func TestStaleScratchSymlinkIsNotFollowed(t *testing.T) {
	victim := t.TempDir()
	os.WriteFile(filepath.Join(victim, "keep.txt"), []byte("K"), 0o644)
	l := Library{Root: t.TempDir()}
	gd := l.GameDir("CUSA04529")
	os.MkdirAll(gd, 0o755)
	for _, n := range []string{"content.partial", "content.ref.partial", "patch.partial", "dlc-EXTRAPACK.partial", "content.next"} {
		os.Symlink(victim, filepath.Join(gd, n))
	}
	mustImport(t, l, pkgFile(t, "gd", "01.00", "UP9000-CUSA04529_00-BASE", map[string][]byte{"eboot.bin": []byte("v100")}), "copy")
	mustImport(t, l, pkgFile(t, "gp", "01.32", "UP9000-CUSA04529_00-PATCH", map[string][]byte{"eboot.bin": []byte("v132")}), "copy")
	mustImport(t, l, pkgFile(t, "ac", "01.00", "UP9000-CUSA04529_00-EXTRAPACK", map[string][]byte{"dlc.dat": []byte("D")}), "copy")
	if got := snapshot(t, victim); !maps.Equal(got, map[string]string{"keep.txt": "K"}) {
		t.Errorf("symlink target changed: %v", got)
	}
	if isSymlink(l.ContentDir("CUSA04529")) {
		t.Error("content is the stale symlink")
	}
}

func TestStrictNamesAndLibraryOverlap(t *testing.T) {
	l := Library{Root: t.TempDir()}
	bad := gameFolder(t, []sfo.Entry{{Key: "TITLE_ID", Str: "../CUSA0"}, {Key: "CATEGORY", Str: "gd"}})
	if _, err := l.Import(bad, "copy", ev(), nil); codeOf(err) != "bad_input" {
		t.Errorf("bad TITLE_ID: %v", err)
	}
	mustImport(t, l, pkgFile(t, "gd", "01.00", "UP9000-CUSA04529_00-BASE", map[string][]byte{"eboot.bin": {1}}), "copy")
	if _, err := l.Import(pkgFile(t, "ac", "01.00", "UP9000-CUSA04529_00-BAD.LABEL", map[string][]byte{"d": {1}}), "copy", ev(), nil); codeOf(err) != "bad_pkg" {
		t.Errorf("bad label: %v", err)
	}
	inside := filepath.Join(l.Root, "games", "CUSA04529", "content")
	os.MkdirAll(filepath.Join(inside, "sce_sys"), 0o755)
	os.WriteFile(filepath.Join(inside, "sce_sys", "param.sfo"), sfo.Build(sfoFor("gd", "01.00", "X")), 0o644)
	if _, err := l.Import(inside, "copy", ev(), nil); codeOf(err) != "bad_input" {
		t.Errorf("folder inside the library: %v", err)
	}
}

func TestUpdate(t *testing.T) {
	l := Library{Root: t.TempDir()}
	if err := l.Update(func(g map[string]*Game) error {
		g["CUSA00557"] = &Game{TitleID: "CUSA00557", PlaySeconds: 5}
		return nil
	}); err != nil {
		t.Fatal(err)
	}
	if err := l.Update(func(g map[string]*Game) error { g["CUSA00557"].PlaySeconds += 7; return nil }); err != nil {
		t.Fatal(err)
	}
	games, _ := l.Load()
	if games["CUSA00557"].PlaySeconds != 12 {
		t.Errorf("play seconds = %d", games["CUSA00557"].PlaySeconds)
	}
}

func TestAppVerEmptyFallsBackToVersion(t *testing.T) {
	for _, tc := range []struct {
		entries []sfo.Entry
		want    string
	}{
		{[]sfo.Entry{{Key: "APP_VER", Str: ""}, {Key: "VERSION", Str: "01.05"}}, "01.05"},
		{[]sfo.Entry{{Key: "VERSION", Str: "01.05"}}, "01.05"},
		{[]sfo.Entry{{Key: "APP_VER", Str: "01.09"}, {Key: "VERSION", Str: "01.05"}}, "01.09"},
	} {
		s, err := sfo.Parse(sfo.Build(tc.entries))
		if err != nil {
			t.Fatal(err)
		}
		if got := appVer(s); got != tc.want {
			t.Errorf("%v: appVer = %q, want %q", tc.entries, got, tc.want)
		}
	}
}

// loadParam reads content/sce_sys/param.sfo as analyze-game does (compat.readParam).
func loadParam(t *testing.T, dir string) *sfo.File {
	t.Helper()
	s, err := sfo.Load(filepath.Join(dir, "sce_sys", "param.sfo"))
	if err != nil {
		t.Fatalf("no param.sfo: %v", err)
	}
	return s
}

func sfoString(s *sfo.File, key string) string {
	v, _ := s.String(key)
	return v
}

// A PKG import writes the package's sce_sys entries into the content, as shadPS4 does:
// param.sfo and icon0.png of the base game, the patch's param.sfo over them, and the DLC's
// own sce_sys in its addcont directory.
func TestPKGImportWritesSceSys(t *testing.T) {
	l := Library{Root: t.TempDir()}
	base, err := fpkgtest.BuildTestPKG(t.TempDir(), sfoFor("gd", "01.00", "UP9000-CUSA04529_00-BASE"),
		map[string][]byte{"eboot.bin": []byte("v100")}, fpkgtest.Opts{Extra: []fpkg.ExtraEntry{{ID: 0x1220, Data: []byte("PIC0")}}})
	if err != nil {
		t.Fatal(err)
	}
	mustImport(t, l, base, "copy")
	c := l.ContentDir("CUSA04529")
	if s := loadParam(t, c); sfoString(s, "TITLE_ID") != "CUSA04529" || sfoString(s, "APP_VER") != "01.00" || sfoString(s, "CATEGORY") != "gd" {
		t.Errorf("base param.sfo = %v", s)
	}
	if b, _ := os.ReadFile(filepath.Join(c, "sce_sys", "pic0.png")); string(b) != "PIC0" {
		t.Errorf("pic0.png = %q", b)
	}
	if _, err := os.Stat(filepath.Join(c, "sce_sys", "icon0.png")); err != nil {
		t.Errorf("icon0.png: %v", err)
	}
	mustImport(t, l, pkgFile(t, "gp", "01.32", "UP9000-CUSA04529_00-PATCH", map[string][]byte{"eboot.bin": []byte("v132")}), "copy")
	if s := loadParam(t, c); sfoString(s, "APP_VER") != "01.32" {
		t.Errorf("patched param.sfo APP_VER = %q", sfoString(s, "APP_VER"))
	}
	if b, _ := os.ReadFile(filepath.Join(c, "sce_sys", "pic0.png")); string(b) != "PIC0" {
		t.Errorf("a base sce_sys file the patch lacks was lost: %q", b)
	}
	mustImport(t, l, pkgFile(t, "ac", "01.00", "UP9000-CUSA04529_00-EXTRAPACK", map[string][]byte{"dlc.dat": []byte("D")}), "copy")
	if s := loadParam(t, filepath.Join(c, "addcont", "EXTRAPACK")); sfoString(s, "CATEGORY") != "ac" {
		t.Errorf("DLC param.sfo CATEGORY = %q", sfoString(s, "CATEGORY"))
	}
	if s := loadParam(t, c); sfoString(s, "APP_VER") != "01.32" || sfoString(s, "CATEGORY") != "gp" {
		t.Errorf("the DLC changed the game's param.sfo: %v", s)
	}
	games, _ := l.Load()
	if g := games["CUSA04529"]; g.ContentBytes != treeBytes(t, c) {
		t.Errorf("content_bytes %d, tree %d", g.ContentBytes, treeBytes(t, c))
	}
}

// A pending patch brings its param.sfo when it is applied to the base game.
func TestPendingPatchUpdatesParam(t *testing.T) {
	l := Library{Root: t.TempDir()}
	mustImport(t, l, pkgFile(t, "gp", "01.32", "UP9000-CUSA04529_00-PATCH", map[string][]byte{"eboot.bin": []byte("v132")}), "copy")
	mustImport(t, l, pkgFile(t, "gd", "01.00", "UP9000-CUSA04529_00-BASE", map[string][]byte{"eboot.bin": []byte("v100")}), "copy")
	if s := loadParam(t, l.ContentDir("CUSA04529")); sfoString(s, "APP_VER") != "01.32" {
		t.Errorf("param.sfo APP_VER = %q", sfoString(s, "APP_VER"))
	}
}

func TestPatchVersionOrder(t *testing.T) {
	l := Library{Root: t.TempDir()}
	patch := func(ver string) string {
		return pkgFile(t, "gp", ver, "UP9000-CUSA04529_00-PATCH", map[string][]byte{"eboot.bin": []byte("v" + ver)})
	}
	// Pending: an older patch does not replace a newer one; a newer one does.
	mustImport(t, l, patch("01.32"), "copy")
	if _, err := l.Import(patch("01.09"), "copy", ev(), nil); codeOf(err) != "bad_input" {
		t.Errorf("older pending patch: %v", err)
	}
	if pp, _ := (&importer{lib: l, ev: ev()}).readPending("CUSA04529"); pp == nil || pp.AppVer != "01.32" {
		t.Errorf("pending = %+v", pp)
	}
	mustImport(t, l, patch("01.50"), "copy")
	if pp, _ := (&importer{lib: l, ev: ev()}).readPending("CUSA04529"); pp == nil || pp.AppVer != "01.50" {
		t.Errorf("pending = %+v", pp)
	}
	mustImport(t, l, pkgFile(t, "gd", "01.00", "UP9000-CUSA04529_00-BASE", map[string][]byte{"eboot.bin": []byte("v100")}), "copy")
	c := l.ContentDir("CUSA04529")
	// Installed: an older patch is refused and changes nothing; the same one again is a
	// reinstall.
	before := snapshot(t, c)
	if _, err := l.Import(patch("01.09"), "copy", ev(), nil); codeOf(err) != "bad_input" {
		t.Errorf("older patch: %v", err)
	}
	if got := snapshot(t, c); !maps.Equal(got, before) {
		t.Errorf("an older patch changed the content")
	}
	r := mustImport(t, l, patch("01.50"), "copy")
	if r.Game.AppVer != "01.50" || !slices.Equal(r.Game.Patches, []string{"01.50"}) {
		t.Errorf("reinstalled patch: %+v", r.Game)
	}
	for _, tc := range []struct {
		a, b string
		c    int
		ok   bool
	}{{"01.09", "01.32", -1, true}, {"01.32", "01.09", 1, true}, {"01.10", "1.1", 1, true}, {"02.00", "02.00", 0, true}, {"1.0", "x", 0, false}} {
		if c, ok := compareVersions(tc.a, tc.b); c != tc.c || ok != tc.ok {
			t.Errorf("compareVersions(%q, %q) = %d, %v", tc.a, tc.b, c, ok)
		}
	}
}

// A reinstall resumed from a scratch tree into which DLC had been linked before a crash
// still carries the DLC over (the extraction prunes the old links).
func TestResumedReinstallKeepsDLC(t *testing.T) {
	l := Library{Root: t.TempDir()}
	mustImport(t, l, pkgFile(t, "gd", "01.00", "UP9000-CUSA04529_00-BASE", map[string][]byte{"eboot.bin": []byte("v100")}), "copy")
	mustImport(t, l, pkgFile(t, "ac", "01.00", "UP9000-CUSA04529_00-EXTRAPACK", map[string][]byte{"dlc.dat": []byte("D")}), "copy")
	base := pkgFile(t, "gd", "01.00", "UP9000-CUSA04529_00-BASE", map[string][]byte{"eboot.bin": []byte("v200")})
	partial := l.ContentDir("CUSA04529") + ".partial"
	os.MkdirAll(filepath.Join(partial, "addcont", "EXTRAPACK", "sce_sys"), 0o755)
	writeMarker(t, partial, base, "UP9000-CUSA04529_00-BASE")
	os.WriteFile(filepath.Join(partial, "eboot.bin"), []byte("v200"), 0o644)
	mustImport(t, l, base, "copy")
	c := l.ContentDir("CUSA04529")
	if b, _ := os.ReadFile(filepath.Join(c, "addcont", "EXTRAPACK", "dlc.dat")); string(b) != "D" {
		t.Errorf("DLC lost by a resumed reinstall: %q", b)
	}
	if games, _ := l.Load(); !slices.Equal(games["CUSA04529"].DLC, []string{"EXTRAPACK"}) {
		t.Errorf("dlc = %v", games["CUSA04529"].DLC)
	}
}

// library.json fields the engine does not know survive a load and save, at the top level
// and per game, and a reinstall keeps the game's.
func TestLibraryJSONKeepsUnknownFields(t *testing.T) {
	l := Library{Root: t.TempDir()}
	path := filepath.Join(l.Root, "library.json")
	os.WriteFile(path, []byte(`{"version":1,"app":{"sort":"title"},"games":[{"title_id":"CUSA04529","play_seconds":5,"keep_saves":true,"rebuild":{"offered":"0.3.0"}}]}`), 0o644)
	if err := l.Update(func(g map[string]*Game) error { g["CUSA04529"].PlaySeconds += 7; return nil }); err != nil {
		t.Fatal(err)
	}
	mustImport(t, l, pkgFile(t, "gd", "01.00", "UP9000-CUSA04529_00-BASE", map[string][]byte{"eboot.bin": []byte("v100")}), "copy")
	b, _ := os.ReadFile(path)
	var f struct {
		Version int             `json:"version"`
		App     json.RawMessage `json:"app"`
		Games   []map[string]json.RawMessage
	}
	if err := json.Unmarshal(b, &f); err != nil {
		t.Fatal(err)
	}
	compact := func(r json.RawMessage) string {
		var b bytes.Buffer
		json.Compact(&b, r)
		return b.String()
	}
	if f.Version != 1 || compact(f.App) != `{"sort":"title"}` || len(f.Games) != 1 {
		t.Fatalf("library.json = %s", b)
	}
	g := f.Games[0]
	if compact(g["keep_saves"]) != "true" || compact(g["rebuild"]) != `{"offered":"0.3.0"}` || compact(g["play_seconds"]) != "12" || compact(g["app_ver"]) != `"01.00"` {
		t.Errorf("game = %s", b)
	}
}

// A library.json from a newer engine is refused and left as it is.
func TestLibraryJSONNewerVersionRefused(t *testing.T) {
	l := Library{Root: t.TempDir()}
	path := filepath.Join(l.Root, "library.json")
	newer := []byte(`{"version":2,"games":[]}`)
	os.WriteFile(path, newer, 0o644)
	if _, err := l.Load(); err == nil || !strings.Contains(err.Error(), "newer") {
		t.Errorf("Load = %v", err)
	}
	if err := l.Save(map[string]*Game{}); err == nil {
		t.Error("Save overwrote a newer library.json")
	}
	_, err := l.Import(pkgFile(t, "gd", "01.00", "UP9000-CUSA04529_00-BASE", map[string][]byte{"eboot.bin": {1}}), "copy", ev(), nil)
	if codeOf(err) != "io" {
		t.Errorf("import into a newer library: %v", err)
	}
	if b, _ := os.ReadFile(path); !bytes.Equal(b, newer) {
		t.Errorf("library.json changed: %s", b)
	}
}

// An import that waits for the library lock says so once and can be cancelled.
func TestLockWaitIsCancellable(t *testing.T) {
	l := Library{Root: t.TempDir()}
	unlock, err := l.lock(nil, nil)
	if err != nil {
		t.Fatal(err)
	}
	defer unlock()
	sink := &cancelOn{match: "waiting for library lock", cancel: make(chan struct{})}
	errc := make(chan error, 1)
	go func() {
		_, err := l.Import(pkgFile(t, "gd", "01.00", "UP9000-CUSA04529_00-BASE", map[string][]byte{"eboot.bin": {1}}), "copy", events.New(sink, "import", true), sink.cancel)
		errc <- err
	}()
	select {
	case err := <-errc:
		if codeOf(err) != "cancelled" {
			t.Errorf("err = %v", err)
		}
	case <-time.After(10 * time.Second):
		t.Fatal("a cancel did not end the wait for the library lock")
	}
	out := sink.String()
	if strings.Count(out, `"stage":"lock"`) != 1 || !strings.Contains(out, `"code":"cancelled"`) {
		t.Errorf("events = %s", out)
	}
	if exists(l.GameDir("CUSA04529")) {
		t.Error("game dir created while waiting for the lock")
	}
}
