// SPDX-License-Identifier: GPL-2.0-or-later

package fpkg_test

import (
	"bytes"
	"errors"
	"maps"
	"os"
	"path/filepath"
	"runtime"
	"slices"
	"testing"

	. "ps4-recomp/pkg/fpkg"
	"ps4-recomp/pkg/fpkg/fpkgtest"
	"ps4-recomp/pkg/sfo"
)

func testTree() map[string][]byte {
	big := bytes.Repeat([]byte("0123456789abcdef"), 300000) // 4.8 MB, several chunks
	return map[string][]byte{
		"eboot.bin":           []byte("\x7fELF fake eboot"),
		"sce_sys/param.sfo":   []byte("sfo"),
		"sce_module/libc.prx": []byte("prx"),
		"data/levels/big.bin": big,
		"data/empty.bin":      {},
	}
}

func TestExtractPlainAndPFSC(t *testing.T) {
	for _, pfsc := range []bool{false, true} {
		p, err := Open(buildTestPKG(t, testSFO, testTree(), fpkgtest.Opts{PFSC: pfsc}))
		if err != nil {
			t.Fatal(err)
		}
		dst := t.TempDir()
		var last int64
		if err := p.Extract(dst, nil, func(d, tot int64, _ string) { last = d }, nil); err != nil {
			t.Fatalf("pfsc=%v: %v", pfsc, err)
		}
		for rel, want := range testTree() {
			got, err := os.ReadFile(filepath.Join(dst, rel))
			if err != nil || !bytes.Equal(got, want) {
				t.Errorf("pfsc=%v %s: %v (len %d want %d)", pfsc, rel, err, len(got), len(want))
			}
		}
		total, _ := p.UnpackedSize()
		if last != total {
			t.Errorf("pfsc=%v: progress ended at %d of %d", pfsc, last, total)
		}
	}
}

func TestExtractSkipAndCancel(t *testing.T) {
	p, _ := Open(buildTestPKG(t, testSFO, testTree(), fpkgtest.Opts{}))
	dst := t.TempDir()
	os.MkdirAll(filepath.Join(dst, "sce_sys"), 0o755)
	os.WriteFile(filepath.Join(dst, "eboot.bin"), []byte("KEEP"), 0o644)
	skip := func(rel string, _ int64) bool { return rel == "eboot.bin" }
	if err := p.Extract(dst, skip, nil, nil); err != nil {
		t.Fatal(err)
	}
	if b, _ := os.ReadFile(filepath.Join(dst, "eboot.bin")); string(b) != "KEEP" {
		t.Errorf("skipped file rewritten: %q", b)
	}
	c := make(chan struct{})
	close(c)
	if err := p.Extract(t.TempDir(), nil, nil, c); !errors.Is(err, ErrCancelled) {
		t.Errorf("cancel: %v", err)
	}
}

// A file only gets its final name once it is complete, so a file found under its final
// name after an interrupted extraction is whole.
func TestExtractInterruptedFileKeepsPartName(t *testing.T) {
	p, _ := Open(buildTestPKG(t, testSFO, testTree(), fpkgtest.Opts{}))
	dst := t.TempDir()
	c := make(chan struct{})
	progress := func(_, _ int64, file string) {
		if file == "data/levels/big.bin" {
			select {
			case <-c:
			default:
				close(c)
			}
		}
	}
	if err := p.Extract(dst, nil, progress, c); !errors.Is(err, ErrCancelled) {
		t.Fatalf("err = %v", err)
	}
	if _, err := os.Stat(filepath.Join(dst, "data/levels/big.bin")); !os.IsNotExist(err) {
		t.Error("interrupted file has its final name")
	}
	if _, err := os.Stat(filepath.Join(dst, PartName("data/levels/big.bin"))); err != nil {
		t.Errorf("no scratch file: %v", err)
	}
}

// The scratch name of a file cannot be the name of another file of the image: an
// interrupted write of "x" must not leave a truncated file named "x.part", which a resume
// would take for that entry.
func TestExtractScratchNameIsNotAnEntryName(t *testing.T) {
	files := map[string][]byte{"x": bytes.Repeat([]byte("x"), 3<<20), "x.part": []byte("entry x.part")}
	p, _ := Open(buildTestPKG(t, testSFO, files, fpkgtest.Opts{}))
	dst := t.TempDir()
	c := make(chan struct{})
	progress := func(_, _ int64, file string) {
		if file == "x" {
			select {
			case <-c:
			default:
				close(c)
			}
		}
	}
	if err := p.Extract(dst, nil, progress, c); !errors.Is(err, ErrCancelled) {
		t.Fatalf("err = %v", err)
	}
	if _, err := os.Lstat(filepath.Join(dst, "x.part")); !os.IsNotExist(err) {
		t.Error("an interrupted write left a file named like another entry")
	}
	if err := p.Extract(dst, nil, nil, nil); err != nil {
		t.Fatal(err)
	}
	for rel, want := range files {
		if got, err := os.ReadFile(filepath.Join(dst, rel)); err != nil || !bytes.Equal(got, want) {
			t.Errorf("%s: %d bytes, %v", rel, len(got), err)
		}
	}
}

func TestExtractRejectsEscapingPaths(t *testing.T) {
	p, _ := Open(buildTestPKG(t, testSFO, map[string][]byte{"../evil": {1}}, fpkgtest.Opts{}))
	if err := p.Extract(t.TempDir(), nil, nil, nil); err == nil {
		t.Error("an escaping path was extracted")
	}
}

func TestFilesAndUnpackedSize(t *testing.T) {
	tree := testTree()
	p, err := Open(buildTestPKG(t, testSFO, tree, fpkgtest.Opts{PFSC: true}))
	if err != nil {
		t.Fatal(err)
	}
	fs, err := p.Files()
	if err != nil {
		t.Fatal(err)
	}
	var got, wantPaths []string
	var want int64
	for rel, b := range tree {
		wantPaths = append(wantPaths, rel)
		want += int64(len(b))
	}
	for _, d := range []string{"data", "data/levels", "sce_module", "sce_sys"} {
		wantPaths = append(wantPaths, d+"/")
	}
	// icon0.png is a PKG entry only; param.sfo is in the PFS image too, which wins.
	icon, err := p.ReadEntry(0x1200)
	if err != nil {
		t.Fatal(err)
	}
	tree["sce_sys/icon0.png"] = icon
	wantPaths = append(wantPaths, "sce_sys/icon0.png")
	want += int64(len(icon))
	for _, f := range fs {
		name := f.Path
		if f.Dir {
			name += "/"
			if f.Size != 0 {
				t.Errorf("directory %s has size %d", f.Path, f.Size)
			}
		} else if int64(len(tree[f.Path])) != f.Size {
			t.Errorf("%s: size %d, want %d", f.Path, f.Size, len(tree[f.Path]))
		}
		got = append(got, name)
	}
	slices.Sort(got)
	slices.Sort(wantPaths)
	if !slices.Equal(got, wantPaths) {
		t.Errorf("Files() = %q, want %q", got, wantPaths)
	}
	if n, err := p.UnpackedSize(); err != nil || n != want {
		t.Errorf("UnpackedSize = %d, %v; want %d", n, err, want)
	}
}

// TestExtractWritesSysEntries checks the port of pkg.cpp:153-221: the named, unencrypted
// PKG entries from 0x400 on are written to sce_sys/<name> next to the PFS files, and a PFS
// file of the same path wins.
func TestExtractWritesSysEntries(t *testing.T) {
	extra := []ExtraEntry{
		{ID: 0x1220, Data: []byte("PIC0-ENTRY")},                  // pic0.png, also in the PFS image
		{ID: 0x1006, Data: []byte("PIC1")},                        // pic1.png
		{ID: 0x1260, Data: []byte("<changeinfo/>")},               // changeinfo/changeinfo.xml
		{ID: 0x0400, Data: []byte("ciphertext"), Encrypted: true}, // license.dat
		{ID: 0x0080, Data: []byte("digests")},                     // general_digests
		{ID: 0x0300, Data: []byte("unnamed")},                     // no name
	}
	files := map[string][]byte{"eboot.bin": []byte("ELF"), "sce_sys/pic0.png": []byte("PIC0-PFS")}
	p, err := Open(buildTestPKG(t, testSFO, files, fpkgtest.Opts{Extra: extra}))
	if err != nil {
		t.Fatal(err)
	}
	dst := t.TempDir()
	var last, total int64
	if err := p.Extract(dst, nil, func(d, tot int64, _ string) { last, total = d, tot }, nil); err != nil {
		t.Fatal(err)
	}
	icon, _ := p.ReadEntry(0x1200)
	want := map[string]string{
		"eboot.bin":                         "ELF",
		"sce_sys/param.sfo":                 string(sfo.Build(testSFO)),
		"sce_sys/icon0.png":                 string(icon),
		"sce_sys/pic0.png":                  "PIC0-PFS",
		"sce_sys/pic1.png":                  "PIC1",
		"sce_sys/changeinfo/changeinfo.xml": "<changeinfo/>",
	}
	got := map[string]string{}
	filepath.WalkDir(dst, func(path string, d os.DirEntry, err error) error {
		if err == nil && !d.IsDir() {
			b, _ := os.ReadFile(path)
			rel, _ := filepath.Rel(dst, path)
			got[filepath.ToSlash(rel)] = string(b)
		}
		return err
	})
	if !maps.Equal(got, want) {
		t.Errorf("extracted %q\nwant %q", got, want)
	}
	if size, _ := p.UnpackedSize(); last != total || total != size {
		t.Errorf("progress %d of %d, unpacked size %d", last, total, size)
	}
	// A sys entry follows the resume rule like a PFS file.
	os.WriteFile(filepath.Join(dst, "sce_sys", "pic1.png"), []byte("KEEP"), 0o644)
	if err := p.Extract(dst, func(rel string, size int64) bool { return rel == "sce_sys/pic1.png" && size == 4 }, nil, nil); err != nil {
		t.Fatal(err)
	}
	if b, _ := os.ReadFile(filepath.Join(dst, "sce_sys", "pic1.png")); string(b) != "KEEP" {
		t.Errorf("skipped sys entry rewritten: %q", b)
	}
}

// TestExtractRefusesSymlinkOutOfDst plants a symlink to a directory outside dst where the
// package has a directory; extraction must not write through it.
func TestExtractRefusesSymlinkOutOfDst(t *testing.T) {
	p, _ := Open(buildTestPKG(t, testSFO, map[string][]byte{"data/x.bin": {1, 2, 3}}, fpkgtest.Opts{}))
	dst, outside := t.TempDir(), t.TempDir()
	if err := os.Symlink(outside, filepath.Join(dst, "data")); err != nil {
		t.Fatal(err)
	}
	if err := p.Extract(dst, nil, nil, nil); err == nil {
		t.Error("extracted through a symlink that leaves dst")
	}
	if _, err := os.Stat(filepath.Join(outside, "x.bin")); err == nil {
		t.Error("a file was written outside dst")
	}
}

// TestExtractMemoryDoesNotGrowWithFileSize checks the streaming: extracting a 32 MiB file
// allocates about as much as extracting a 64 KiB one.
func TestExtractMemoryDoesNotGrowWithFileSize(t *testing.T) {
	alloc := func(size int) uint64 {
		data := bytes.Repeat([]byte{0xA5, 0x5A, 0x00, 0x11}, size/4)
		p, err := Open(buildTestPKG(t, testSFO, map[string][]byte{"f.bin": data}, fpkgtest.Opts{PFSC: true}))
		if err != nil {
			t.Fatal(err)
		}
		dst := t.TempDir()
		runtime.GC()
		var before, after runtime.MemStats
		runtime.ReadMemStats(&before)
		if err := p.Extract(dst, nil, nil, nil); err != nil {
			t.Fatal(err)
		}
		runtime.ReadMemStats(&after)
		return after.TotalAlloc - before.TotalAlloc
	}
	small, big := alloc(64<<10), alloc(32<<20)
	if big > small+(1<<20) {
		t.Errorf("extracting 32 MiB allocated %d bytes, 64 KiB allocated %d", big, small)
	}
}
