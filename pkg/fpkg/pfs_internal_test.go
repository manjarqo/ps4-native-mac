// SPDX-License-Identifier: GPL-2.0-or-later

package fpkg

import (
	"bytes"
	"compress/zlib"
	"encoding/binary"
	"errors"
	"os"
	"path/filepath"
	"testing"
)

var le = binary.LittleEndian

// testImage builds an encrypted outer PFS image of inner, lets edit change the plaintext
// image (the PFSC container starts at pfscOffset) and opens a reader on it.
func testImage(t *testing.T, inner []byte, compress bool, edit func(img []byte)) (*pfsReader, error) {
	t.Helper()
	img, err := wrapPFSImage([16]byte{1, 2, 3}, inner, compress)
	if err != nil {
		t.Fatal(err)
	}
	if edit != nil {
		edit(img)
	}
	c := newXTS([16]byte{4, 5, 6}, [16]byte{7, 8, 9})
	encryptPFSImage(img, c)
	return newPFSReader(bytes.NewReader(img), "test", 0, uint64(len(img)), c, pfscOffset)
}

func testInner(t *testing.T, files map[string][]byte) []byte {
	t.Helper()
	inner, err := buildInnerPFS(files)
	if err != nil {
		t.Fatal(err)
	}
	return inner
}

// inodeRec returns the inode record of ino inside an inner image.
func inodeRec(inner []byte, ino uint64) []byte {
	return inner[(1+ino/pfsInodesPerBlock)*pfsBlockSize+(ino%pfsInodesPerBlock)*pfsInodeSize:][:pfsInodeSize]
}

// tableEntry returns the bytes of PFSC block table entry i inside a plain outer image.
func tableEntry(img []byte, i int) []byte { return img[pfscOffset+pfscTableOffset+8*i:][:8] }

// TestPFSCStoredAndCompressedBlocks pins the meaning of Opts.PFSC: the image is always
// PFSC-wrapped (shadPS4 finds it only that way, pkg.cpp:277); without compression every
// block is stored raw (stored size 0x10000, pkg.cpp:307), with it compressible blocks are
// zlib streams.
func TestPFSCStoredAndCompressedBlocks(t *testing.T) {
	inner := testInner(t, map[string][]byte{"a.bin": bytes.Repeat([]byte("x"), 3*pfsBlockSize)})
	for _, compress := range []bool{false, true} {
		pfsc, err := buildPFSC(inner, compress)
		if err != nil {
			t.Fatal(err)
		}
		raw := 0
		n := len(inner) / pfsBlockSize
		for i := range n {
			if le.Uint64(pfsc[pfscTableOffset+8*(i+1):])-le.Uint64(pfsc[pfscTableOffset+8*i:]) == pfsBlockSize {
				raw++
			}
		}
		if want := map[bool]int{false: n, true: 0}[compress]; raw != want {
			t.Errorf("compress=%v: %d of %d blocks stored raw, want %d", compress, raw, n, want)
		}
		r, err := testImage(t, inner, compress, nil)
		if err != nil {
			t.Fatal(err)
		}
		ents, err := r.walk()
		if err != nil || len(ents) != 1 || ents[0].size != 3*pfsBlockSize {
			t.Errorf("compress=%v: walk %+v %v", compress, ents, err)
		}
	}
}

func TestPFSRejectsFragmentedFile(t *testing.T) {
	inner := testInner(t, map[string][]byte{"a.bin": make([]byte, 3*pfsBlockSize)})
	rec := inodeRec(inner, 3) // 0 superroot, 1 flat_path_table, 2 uroot, 3 a.bin
	loc := le.Uint32(rec[inodeOffDB:])
	le.PutUint32(rec[inodeOffDB+4:], loc+2) // block 1 of the file is not loc+1
	r, err := testImage(t, inner, false, nil)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := r.walk(); !errors.Is(err, ErrUnsupported) {
		t.Errorf("walk: %v, want ErrUnsupported", err)
	}
}

func TestPFSRejectsZeroSizeBlock(t *testing.T) {
	inner := testInner(t, map[string][]byte{"a.bin": make([]byte, 2*pfsBlockSize)})
	last := len(inner)/pfsBlockSize - 1
	r, err := testImage(t, inner, false, func(img []byte) {
		copy(tableEntry(img, last), tableEntry(img, last+1)) // the last block stores 0 bytes
	})
	if err != nil {
		t.Fatal(err)
	}
	if _, err := r.walk(); err != nil {
		t.Fatal(err) // the metadata blocks are intact
	}
	buf := make([]byte, pfsBlockSize)
	if err := r.decodeBlock(uint64(last), buf); !errors.Is(err, ErrBadPKG) {
		t.Errorf("decodeBlock of a zero-size block: %v, want ErrBadPKG", err)
	}
}

func TestPFSRejectsHostileStructures(t *testing.T) {
	files := map[string][]byte{"d/a.bin": make([]byte, pfsBlockSize+1)}
	// 0 superroot, 1 flat_path_table, 2 uroot, 3 d, 4 d/a.bin
	cases := map[string]struct {
		inner func(inner []byte)
		img   func(img []byte)
	}{
		"blocks do not match the size":  {inner: func(b []byte) { le.PutUint64(inodeRec(b, 4)[inodeOffSize:], 5) }},
		"file blocks outside the image": {inner: func(b []byte) { le.PutUint32(inodeRec(b, 4)[inodeOffDB:], 1<<30) }},
		"negative file size":            {inner: func(b []byte) { le.PutUint64(inodeRec(b, 4)[inodeOffSize:], 1<<63) }},
		"dirent inode out of range": {inner: func(b []byte) {
			d := b[le.Uint32(inodeRec(b, 3)[inodeOffDB:])*pfsBlockSize:]
			le.PutUint32(d[0x30:], 1000) // the third dirent of d: a.bin
		}},
		"directory reached twice": {inner: func(b []byte) {
			d := b[le.Uint32(inodeRec(b, 3)[inodeOffDB:])*pfsBlockSize:]
			le.PutUint32(d[0x30:], 3) // a.bin -> d itself, as a directory
			le.PutUint32(d[0x34:], direntDir)
			le.PutUint16(inodeRec(b, 3)[inodeOffMode:], inodeModeDir)
		}},
		"dirent runs past the block": {inner: func(b []byte) {
			d := b[le.Uint32(inodeRec(b, 3)[inodeOffDB:])*pfsBlockSize:]
			le.PutUint32(d[0x3C:], pfsBlockSize) // entsize of a.bin
		}},
		"unknown dirent type": {inner: func(b []byte) {
			d := b[le.Uint32(inodeRec(b, 3)[inodeOffDB:])*pfsBlockSize:]
			le.PutUint32(d[0x34:], 7)
		}},
		"inode count too large": {inner: func(b []byte) { le.PutUint64(b[sbDinodeCount:], 1<<40) }},
		"block table beyond the image": {img: func(img []byte) {
			le.PutUint64(img[pfscOffset+pfscOffTable:], 1<<40)
		}},
		"block stored ranges out of order": {img: func(img []byte) {
			le.PutUint64(tableEntry(img, 1), le.Uint64(tableEntry(img, 3))) // block 1 > block 2 start
		}},
	}
	for name, c := range cases {
		inner := testInner(t, files)
		if c.inner != nil {
			c.inner(inner)
		}
		r, err := testImage(t, inner, false, c.img)
		if err == nil {
			_, err = r.walk()
		}
		if err == nil {
			t.Errorf("%s: no error", name)
		} else if !errors.Is(err, ErrBadPKG) && !errors.Is(err, ErrUnsupported) {
			t.Errorf("%s: %v is neither ErrBadPKG nor ErrUnsupported", name, err)
		}
	}
}

// extractAll walks r and extracts its files into a temporary directory through the
// same path Extract uses, returning each file's content.
func extractAll(t *testing.T, r *pfsReader) map[string][]byte {
	t.Helper()
	ents, err := r.walk()
	if err != nil {
		t.Fatal(err)
	}
	dst := t.TempDir()
	root, err := os.OpenRoot(dst)
	if err != nil {
		t.Fatal(err)
	}
	defer root.Close()
	got := map[string][]byte{}
	buf := make([]byte, extractChunk)
	for _, e := range ents {
		if e.dir {
			if err := root.MkdirAll(filepath.FromSlash(e.path), 0o755); err != nil {
				t.Fatal(err)
			}
			continue
		}
		if err := r.extractFile(root, e, buf, nil, func(int64) {}); err != nil {
			t.Fatal(err)
		}
		b, err := os.ReadFile(filepath.Join(dst, e.path))
		if err != nil {
			t.Fatal(err)
		}
		got[e.path] = b
	}
	return got
}

// TestPFSAcceptsWhatShadPS4Extracts covers layouts the source extracts correctly although
// they are unusual: the reader must not be stricter there.
func TestPFSAcceptsWhatShadPS4Extracts(t *testing.T) {
	big := bytes.Repeat([]byte("abc"), pfsBlockSize/3+7)
	files := map[string][]byte{"d/a.bin": big, "e.bin": {}}
	// 0 superroot, 1 flat_path_table, 2 uroot, 3 d, 4 e.bin, 5 d/a.bin
	cases := map[string]struct {
		inner func(inner []byte)
		img   func(img []byte)
	}{
		// pkg.cpp:460-468 writes 0x10000-(Blocks*0x10000-Size) = 0 bytes.
		"empty file with a block": {inner: func(b []byte) {
			le.PutUint32(inodeRec(b, 4)[inodeOffBlocks:], 1)
			le.PutUint32(inodeRec(b, 4)[inodeOffDB:], 0xFFFFFF) // any loc
		}},
		// pkg.cpp:385-396 and 416 go by the dirent type only.
		"no inode mode bits": {inner: func(b []byte) {
			le.PutUint16(inodeRec(b, 3)[inodeOffMode:], 0)
			le.PutUint16(inodeRec(b, 5)[inodeOffMode:], 0)
		}},
		// pkg.cpp:283 truncates data_length / block_sz2.
		"data length with a partial block": {img: func(img []byte) {
			off := pfscOffset + pfscOffDataLength
			le.PutUint64(img[off:], le.Uint64(img[off:])+0x1234)
		}},
		// Real images (inFAMOUS Second Son CUSA00004 v1.07) store 0xFFFFFFFF in the
		// direct pointers db[1..min(Blocks,12)-1] of files and directories; shadPS4
		// reads Blocks blocks from loc and never reads db[1..] (pkg.cpp:417-418).
		"unset direct pointers 0xFFFFFFFF": {inner: func(b []byte) {
			for _, ino := range []uint64{3, 5} { // d (1 block), d/a.bin (2 blocks)
				for k := 1; k < pfsDirectBlocks; k++ {
					le.PutUint32(inodeRec(b, ino)[inodeOffDB+4*k:], 0xFFFFFFFF)
				}
			}
		}},
		// shadPS4 never reads superroot_ino (pkg.cpp:331-337).
		"superroot inode out of range": {inner: func(b []byte) { le.PutUint64(b[sbSuperrootIno:], 1<<40) }},
	}
	for name, c := range cases {
		inner := testInner(t, files)
		if c.inner != nil {
			c.inner(inner)
		}
		r, err := testImage(t, inner, true, c.img)
		if err != nil {
			t.Errorf("%s: %v", name, err)
			continue
		}
		got := extractAll(t, r)
		if len(got) != 2 || !bytes.Equal(got["d/a.bin"], big) || got["e.bin"] == nil || len(got["e.bin"]) != 0 {
			t.Errorf("%s: extracted %d files, d/a.bin %d bytes, e.bin %q", name, len(got), len(got["d/a.bin"]), got["e.bin"])
		}
	}
}

// TestPFSInflateTrailer: a block must inflate to exactly 0x10000 bytes; its Adler-32
// trailer may be missing or wrong, as shadPS4 ignores inflate's result (pkg.cpp:10-30).
func TestPFSInflateTrailer(t *testing.T) {
	deflate := func(n int) []byte {
		var b bytes.Buffer
		w := zlib.NewWriter(&b)
		w.Write(bytes.Repeat([]byte("pfsc"), n/4+1)[:n])
		w.Close()
		return b.Bytes()
	}
	good := deflate(pfsBlockSize)
	badSum := bytes.Clone(good)
	badSum[len(badSum)-1] ^= 0xFF
	cases := []struct {
		name   string
		stream []byte
		ok     bool
	}{
		{"valid", good, true},
		{"wrong checksum", badSum, true},
		{"no checksum", good[:len(good)-4], true},
		{"short block", deflate(pfsBlockSize - 1), false},
		{"oversized block", deflate(pfsBlockSize + 1), false},
	}
	r := &pfsReader{}
	out := make([]byte, pfsBlockSize)
	for _, c := range cases {
		err := r.inflate(c.stream, out)
		if (err == nil) != c.ok {
			t.Errorf("%s: %v", c.name, err)
		}
		if err == nil && !bytes.Equal(out, bytes.Repeat([]byte("pfsc"), pfsBlockSize/4)) {
			t.Errorf("%s: wrong data", c.name)
		}
	}
}
