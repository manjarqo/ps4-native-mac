// SPDX-License-Identifier: GPL-2.0-or-later

// Package fpkg reads PS4 PKG files: the header, the entry table, the unencrypted sce_sys
// entries (param.sfo, icon0.png) and, for fake-signed packages, the PFS image keys.
// It is a Go port of shadPS4's PKG code (src/core/file_format/pkg.cpp, pkg.h, pfs.h,
// pkg_type.cpp and src/core/crypto at tag v.0.7.0, GPL-2.0-or-later). Citations such as
// pkg.cpp:54 refer to that tree.
package fpkg

import (
	"encoding/binary"
	"errors"
	"fmt"
	"io"
	"os"
	"strings"

	"ps4-recomp/pkg/sfo"
)

// PKG header layout (pkg.h:16-74; big-endian, 0x1000 bytes, read at pkg.cpp:54 and 114).
const (
	pkgMagic       = 0x7F434E54 // "\x7FCNT", pkg.cpp:55
	pkgHeaderSize  = 0x1000
	pkgEntrySize   = 32 // pkg.h:89-99
	maxEntryCount  = 1 << 16
	contentIDSize  = 0x24
	entryEncrypted = 1 << 31 // flags1 bit 31

	hdrMagic           = 0x000
	hdrType            = 0x004
	hdrFileCount       = 0x00C
	hdrEntryCount      = 0x010 // pkg_table_entry_count, pkg.cpp:71
	hdrSCEntryCount    = 0x014 // u16
	hdrEntryCount2     = 0x016 // u16
	hdrEntryOffset     = 0x018 // pkg_table_entry_offset, pkg.cpp:70
	hdrEntryDataSize   = 0x01C
	hdrBodyOffset      = 0x020
	hdrBodySize        = 0x028
	hdrContentOffset   = 0x030 // checked at pkg.cpp:123
	hdrContentSize     = 0x038
	hdrContentID       = 0x040
	hdrDRMType         = 0x070
	hdrContentType     = 0x074
	hdrPFSImageCount   = 0x404
	hdrPFSImageOffset  = 0x410 // pkg.cpp:254, 269, 440
	hdrPFSImageSize    = 0x418
	hdrPkgSize         = 0x430 // pkg.cpp:119
	hdrPFSCacheSize    = 0x43C // u32, sizes the PFSC search window, pkg.cpp:262
	entryIDEntryKeys   = 0x0010
	entryIDImageKey    = 0x0020
	entryIDParamSFO    = 0x1000
	entryIDIcon0       = 0x1200
	entryKeysMinSize   = 0x800 // seed digest, 7 digests, 7 RSA blocks (pkg.cpp:181-190)
	imageKeySize       = 0x100 // pkg.cpp:195
	rsaBlockSize       = 0x100
	entryKeysDK3Offset = 0x100 + 3*rsaBlockSize // key1[3], pkg.cpp:192
)

// Package is an opened PKG: its header fields and entry table. It does not hold the
// file open; each method that needs data opens it again.
type Package struct {
	ContentID            string
	DRMType, ContentType uint32
	PFSOffset, PFSSize   uint64
	Entries              []Entry

	path         string
	pfsCacheSize uint32
}

// Entry is one row of the PKG entry table (pkg.h:89-99).
type Entry struct {
	ID           uint32
	Name         string // from the id (pkg_type.cpp); "" for ids shadPS4 does not name
	Offset, Size uint32 // file offset and size of the entry data
	Encrypted    bool   // flags1 bit 31

	nameOffset, flags1, flags2 uint32
}

// Kind is the kind of content a PKG installs, from param.sfo CATEGORY.
type Kind string

const (
	KindGame  Kind = "game"  // CATEGORY gd
	KindPatch Kind = "patch" // CATEGORY gp
	KindDLC   Kind = "dlc"   // CATEGORY ac
)

// Open parses the PKG header and entry table of path. It reads no PFS data.
func Open(path string) (*Package, error) {
	f, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer f.Close()
	st, err := f.Stat()
	if err != nil {
		return nil, err
	}
	fileSize := uint64(st.Size())

	var h [pkgHeaderSize]byte
	if _, err := io.ReadFull(f, h[:]); err != nil {
		if errors.Is(err, io.ErrUnexpectedEOF) || errors.Is(err, io.EOF) {
			return nil, fmt.Errorf("%s: not a PKG (file too small)", path)
		}
		return nil, err
	}
	be := binary.BigEndian
	if be.Uint32(h[hdrMagic:]) != pkgMagic {
		return nil, fmt.Errorf("%s: not a PKG (bad magic)", path)
	}
	// Validation as in Extract (pkg.cpp:119-126), with overflow-safe sums.
	pkgSize := be.Uint64(h[hdrPkgSize:])
	if pkgSize > fileSize {
		return nil, fmt.Errorf("%s: PKG is truncated (header says %d bytes, file has %d)", path, pkgSize, fileSize)
	}
	if !within(be.Uint64(h[hdrContentOffset:]), be.Uint64(h[hdrContentSize:]), pkgSize) {
		return nil, fmt.Errorf("%s: content size is bigger than the PKG size", path)
	}

	p := &Package{
		ContentID:    strings.TrimRight(string(h[hdrContentID:hdrContentID+contentIDSize]), "\x00"),
		DRMType:      be.Uint32(h[hdrDRMType:]),
		ContentType:  be.Uint32(h[hdrContentType:]),
		PFSOffset:    be.Uint64(h[hdrPFSImageOffset:]),
		PFSSize:      be.Uint64(h[hdrPFSImageSize:]),
		path:         path,
		pfsCacheSize: be.Uint32(h[hdrPFSCacheSize:]),
	}
	if !within(p.PFSOffset, p.PFSSize, fileSize) {
		return nil, fmt.Errorf("%s: PFS image lies outside the file", path)
	}

	n := be.Uint32(h[hdrEntryCount:])
	tableOff := uint64(be.Uint32(h[hdrEntryOffset:]))
	if n > maxEntryCount || !within(tableOff, uint64(n)*pkgEntrySize, fileSize) {
		return nil, fmt.Errorf("%s: bad entry table (%d entries at %#x)", path, n, tableOff)
	}
	table := make([]byte, int(n)*pkgEntrySize)
	if _, err := f.ReadAt(table, int64(tableOff)); err != nil {
		return nil, fmt.Errorf("%s: reading the entry table: %w", path, err)
	}
	p.Entries = make([]Entry, n)
	for i := range p.Entries {
		// The 8 trailing padding bytes of each row are skipped (pkg.cpp:86, 150).
		r := table[i*pkgEntrySize:]
		e := Entry{
			ID:         be.Uint32(r[0x00:]),
			nameOffset: be.Uint32(r[0x04:]),
			flags1:     be.Uint32(r[0x08:]),
			flags2:     be.Uint32(r[0x0C:]),
			Offset:     be.Uint32(r[0x10:]),
			Size:       be.Uint32(r[0x14:]),
		}
		e.Name = entryName(e.ID)
		e.Encrypted = e.flags1&entryEncrypted != 0
		if !within(uint64(e.Offset), uint64(e.Size), fileSize) {
			return nil, fmt.Errorf("%s: entry %#x lies outside the file", path, e.ID)
		}
		p.Entries[i] = e
	}
	return p, nil
}

// within reports whether [off, off+size) fits in [0, limit) without overflow.
func within(off, size, limit uint64) bool {
	return off <= limit && size <= limit-off
}

func (p *Package) entry(id uint32) (Entry, bool) {
	for _, e := range p.Entries {
		if e.ID == id {
			return e, true
		}
	}
	return Entry{}, false
}

// ReadEntry returns the data of the unencrypted entry id, for example 0x1000 (param.sfo)
// or 0x1200 (icon0.png).
func (p *Package) ReadEntry(id uint32) ([]byte, error) {
	e, ok := p.entry(id)
	if !ok {
		return nil, fmt.Errorf("%s: no entry %#x", p.path, id)
	}
	if e.Encrypted {
		return nil, fmt.Errorf("%s: entry %#x (%s) is encrypted", p.path, id, e.Name)
	}
	f, err := os.Open(p.path)
	if err != nil {
		return nil, err
	}
	defer f.Close()
	b := make([]byte, e.Size)
	if _, err := f.ReadAt(b, int64(e.Offset)); err != nil {
		return nil, fmt.Errorf("%s: reading entry %#x: %w", p.path, id, err)
	}
	return b, nil
}

// SFO parses the package's param.sfo (entry 0x1000, pkg.cpp:90-98).
func (p *Package) SFO() (*sfo.File, error) {
	b, err := p.ReadEntry(entryIDParamSFO)
	if err != nil {
		return nil, err
	}
	s, err := sfo.Parse(b)
	if err != nil {
		return nil, fmt.Errorf("%s: param.sfo: %w", p.path, err)
	}
	return s, nil
}

// Kind maps param.sfo CATEGORY to the kind of content the package installs.
func (p *Package) Kind() (Kind, error) {
	s, err := p.SFO()
	if err != nil {
		return "", err
	}
	cat, _ := s.String("CATEGORY")
	switch cat {
	case "gd":
		return KindGame, nil
	case "gp":
		return KindPatch, nil
	case "ac":
		return KindDLC, nil
	}
	return "", fmt.Errorf("%s: unsupported param.sfo CATEGORY %q", p.path, cat)
}

// entryNames holds the ids pkg_type.cpp:17-60 names one by one; the regular ranges are
// generated in entryName.
var entryNames = map[uint32]string{
	0x0001: "digests", 0x0010: "entry_keys", 0x0020: "image_key", 0x0080: "general_digests",
	0x0100: "metas", 0x0200: "entry_names", 0x0400: "license.dat", 0x0401: "license.info",
	0x0402: "nptitle.dat", 0x0403: "npbind.dat", 0x0404: "selfinfo.dat", 0x0406: "imageinfo.dat",
	0x0407: "target-deltainfo.dat", 0x0408: "origin-deltainfo.dat", 0x0409: "psreserved.dat",
	0x1000: "param.sfo", 0x1001: "playgo-chunk.dat", 0x1002: "playgo-chunk.sha",
	0x1003: "playgo-manifest.xml", 0x1004: "pronunciation.xml", 0x1005: "pronunciation.sig",
	0x1006: "pic1.png", 0x1007: "pubtoolinfo.dat", 0x1008: "app/playgo-chunk.dat",
	0x1009: "app/playgo-chunk.sha", 0x100A: "app/playgo-manifest.xml", 0x100B: "shareparam.json",
	0x100C: "shareoverlayimage.png", 0x100D: "save_data.png", 0x100E: "shareprivacyguardimage.png",
	0x1200: "icon0.png", 0x1220: "pic0.png", 0x1240: "snd0.at9",
	0x1260: "changeinfo/changeinfo.xml", 0x1280: "icon0.dds", 0x12A0: "pic0.dds", 0x12C0: "pic1.dds",
}

// entryName returns the sce_sys file name of entry id, as shadPS4's GetEntryNameByType
// (pkg_type.cpp:631-638), or "" for an id it does not name. The 611-entry literal table of
// pkg_type.cpp:15-629 is generated from its regular ranges here, and matches it for all
// ids but one typo: the literal list names 0x1648 "keymap_rp/03/0010.png" and has no 0x1649,
// where the pattern of every other keymap_rp directory gives 0x1648 "keymap_rp/03/009.png"
// and 0x1649 "keymap_rp/03/010.png". The pattern is used.
func entryName(id uint32) string {
	if s, ok := entryNames[id]; ok {
		return s
	}
	switch {
	case id >= 0x1201 && id <= 0x121F:
		return fmt.Sprintf("icon0_%02d.png", id-0x1201)
	case id >= 0x1241 && id <= 0x125F:
		return fmt.Sprintf("pic1_%02d.png", id-0x1241)
	case id >= 0x1261 && id <= 0x127F:
		return fmt.Sprintf("changeinfo/changeinfo_%02d.xml", id-0x1261)
	case id >= 0x1281 && id <= 0x129F:
		return fmt.Sprintf("icon0_%02d.dds", id-0x1281)
	case id >= 0x12C1 && id <= 0x12DF:
		return fmt.Sprintf("pic1_%02d.dds", id-0x12C1)
	case id >= 0x1400 && id <= 0x1463:
		return fmt.Sprintf("trophy/trophy%02d.trp", id-0x1400)
	case id >= 0x1600 && id <= 0x1609:
		return fmt.Sprintf("keymap_rp/%03d.png", id-0x1600+1)
	case id >= 0x1610 && id <= 0x17F9:
		dir, n := (id-0x1610)/0x10, (id-0x1610)%0x10
		if n < 10 {
			return fmt.Sprintf("keymap_rp/%02d/%03d.png", dir, n+1)
		}
	}
	return ""
}
