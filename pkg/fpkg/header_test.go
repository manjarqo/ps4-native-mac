// SPDX-License-Identifier: GPL-2.0-or-later

package fpkg_test

import (
	"bytes"
	"encoding/binary"
	"errors"
	"os"
	"testing"

	. "ps4-recomp/pkg/fpkg"
	"ps4-recomp/pkg/fpkg/fpkgtest"
	"ps4-recomp/pkg/sfo"
)

func buildTestPKG(t *testing.T, e []sfo.Entry, files map[string][]byte, o fpkgtest.Opts) string {
	t.Helper()
	p, err := fpkgtest.BuildTestPKG(t.TempDir(), e, files, o)
	if err != nil {
		t.Fatal(err)
	}
	return p
}

var testSFO = []sfo.Entry{
	{Key: "TITLE_ID", Str: "CUSA00557"}, {Key: "CATEGORY", Str: "gd"},
	{Key: "APP_VER", Str: "01.00"}, {Key: "TITLE", Str: "Test Game"},
	{Key: "CONTENT_ID", Str: "UP9000-CUSA00557_00-TESTGAME00000000"},
}

func TestOpenHeaderAndSFO(t *testing.T) {
	path := buildTestPKG(t, testSFO, map[string][]byte{"eboot.bin": []byte("ELF")}, fpkgtest.Opts{})
	p, err := Open(path)
	if err != nil {
		t.Fatal(err)
	}
	if p.ContentID != "UP9000-CUSA00557_00-TESTGAME00000000" {
		t.Errorf("content id %q", p.ContentID)
	}
	s, err := p.SFO()
	if err != nil {
		t.Fatal(err)
	}
	if id, _ := s.String("TITLE_ID"); id != "CUSA00557" {
		t.Errorf("TITLE_ID %q", id)
	}
	if k, _ := p.Kind(); k != KindGame {
		t.Errorf("kind %q", k)
	}
	icon, err := p.ReadEntry(0x1200)
	if err != nil || !bytes.HasPrefix(icon, []byte("\x89PNG")) {
		t.Errorf("icon0: %v %q", err, icon[:min(8, len(icon))])
	}
}

func TestEntryTable(t *testing.T) {
	p, err := Open(buildTestPKG(t, testSFO, nil, fpkgtest.Opts{}))
	if err != nil {
		t.Fatal(err)
	}
	names := map[uint32]string{}
	for _, e := range p.Entries {
		names[e.ID] = e.Name
		if e.ID == 0x20 && !e.Encrypted {
			t.Error("image_key entry not marked encrypted")
		}
	}
	for id, want := range map[uint32]string{0x10: "entry_keys", 0x20: "image_key", 0x1000: "param.sfo", 0x1200: "icon0.png"} {
		if names[id] != want {
			t.Errorf("entry %#x named %q, want %q", id, names[id], want)
		}
	}
	if _, err := p.ReadEntry(0x20); err == nil {
		t.Error("ReadEntry of the encrypted image_key entry succeeded")
	}
	if _, err := p.ReadEntry(0x1006); err == nil {
		t.Error("ReadEntry of a missing entry succeeded")
	}
}

func TestKinds(t *testing.T) {
	for cat, want := range map[string]Kind{"gd": KindGame, "gp": KindPatch, "ac": KindDLC} {
		e := append([]sfo.Entry(nil), testSFO...)
		e[1] = sfo.Entry{Key: "CATEGORY", Str: cat}
		p, err := Open(buildTestPKG(t, e, nil, fpkgtest.Opts{}))
		if err != nil {
			t.Fatal(err)
		}
		if k, err := p.Kind(); err != nil || k != want {
			t.Errorf("%s: %q %v", cat, k, err)
		}
	}
}

func TestFakeAndRetail(t *testing.T) {
	fake, _ := Open(buildTestPKG(t, testSFO, map[string][]byte{"a": {1}}, fpkgtest.Opts{}))
	if s, err := fake.Signing(); err != nil || s != "fake" {
		t.Errorf("fake: %q %v", s, err)
	}
	retail, _ := Open(buildTestPKG(t, testSFO, map[string][]byte{"a": {1}}, fpkgtest.Opts{Retail: true}))
	if s, err := retail.Signing(); s != "retail" || err != nil {
		t.Errorf("retail: %q %v", s, err)
	}
	if err := retail.Extract(t.TempDir(), nil, nil, nil); !errors.Is(err, ErrRetail) {
		t.Errorf("retail Extract: %v, want ErrRetail", err)
	}
}

// TestZeroPFSCacheSizeIsMalformed: pfs_cache_size sizes the PFSC search window
// (pkg.cpp:262); zero leaves no window, which is a damaged package, not a retail one.
func TestZeroPFSCacheSizeIsMalformed(t *testing.T) {
	path := buildTestPKG(t, testSFO, nil, fpkgtest.Opts{})
	b, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	binary.BigEndian.PutUint32(b[0x43C:], 0)
	if err := os.WriteFile(path, b, 0o644); err != nil {
		t.Fatal(err)
	}
	p, err := Open(path)
	if err != nil {
		t.Fatal(err)
	}
	s, err := p.Signing()
	if s != "" || errors.Is(err, ErrRetail) || !errors.Is(err, ErrBadPKG) {
		t.Errorf("Signing = %q, %v; want ErrBadPKG", s, err)
	}
	if err := p.Extract(t.TempDir(), nil, nil, nil); errors.Is(err, ErrRetail) || !errors.Is(err, ErrBadPKG) {
		t.Errorf("Extract: %v, want ErrBadPKG", err)
	}
}

// TestSigningNeedsPFSCMagic damages the encrypted PFS image of a fake PKG: the EKPFS still
// unwraps with the fake key, but the PFSC magic no longer decrypts, so it is not "fake".
func TestSigningNeedsPFSCMagic(t *testing.T) {
	path := buildTestPKG(t, testSFO, nil, fpkgtest.Opts{PFSC: true})
	p, err := Open(path)
	if err != nil {
		t.Fatal(err)
	}
	if s, err := p.Signing(); err != nil || s != "fake" {
		t.Fatalf("intact: %q %v", s, err)
	}
	b, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	for off := p.PFSOffset + 0x10000; off < p.PFSOffset+p.PFSSize; off += 0x10000 {
		b[off] ^= 0xFF // the first byte of every block that could hold the PFSC header
	}
	if err := os.WriteFile(path, b, 0o644); err != nil {
		t.Fatal(err)
	}
	if s, err := p.Signing(); err != nil || s != "retail" {
		t.Errorf("damaged: %q %v", s, err)
	}
}

func TestRejectsNonPKG(t *testing.T) {
	path := t.TempDir() + "/x.pkg"
	if err := os.WriteFile(path, []byte("not a pkg at all, just text....................................."), 0o644); err != nil {
		t.Fatal(err)
	}
	if _, err := Open(path); err == nil {
		t.Error("no error for a non-PKG")
	}
}

func TestRejectsTruncatedPKG(t *testing.T) {
	path := buildTestPKG(t, testSFO, nil, fpkgtest.Opts{})
	b, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, b[:len(b)-1], 0o644); err != nil {
		t.Fatal(err)
	}
	if _, err := Open(path); err == nil {
		t.Error("no error for a truncated PKG")
	}
}
