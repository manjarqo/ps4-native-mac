// SPDX-License-Identifier: GPL-2.0-or-later

package fpkg

import (
	"bytes"
	"cmp"
	"compress/zlib"
	"crypto/cipher"
	"crypto/rand"
	"crypto/rsa"
	"encoding/binary"
	"errors"
	"fmt"
	"io"
	"slices"
	"strings"

	"ps4-recomp/pkg/sfo"
)

// PackSpec describes a PKG for Write. Write is the inverse of the reader, used to build
// test packages; it keeps the whole package in memory.
type PackSpec struct {
	SFO   []byte            // param.sfo bytes; CONTENT_ID and CATEGORY are required
	Icon  []byte            // icon0.png bytes
	Files map[string][]byte // files of the PFS image, by path
	// Extra holds more entries for the entry table, such as pic0.png (0x1220) or
	// changeinfo/changeinfo.xml (0x1260). Like param.sfo and icon0.png, which are always
	// entries, they are not in the PFS image unless Files has them too.
	Extra []ExtraEntry
	PFSC  bool // zlib-compress the PFSC blocks where that makes them smaller
	// EKPFSKey wraps the EKPFS (entry 0x20). nil means the public fake keyset, which the
	// reader unwraps; any other 2048-bit key makes a package that reads as retail.
	EKPFSKey *rsa.PublicKey
}

// ExtraEntry is an entry Write adds to the entry table. Data is stored as it is; Encrypted
// only sets the flag.
type ExtraEntry struct {
	ID        uint32
	Data      []byte
	Encrypted bool
}

// Layout constants of the PFS images Write builds (pfs.h:24-52; little-endian).
const (
	pfsVersion       = 1
	pfsMagic         = 20130315 // known PFS superblock magic; not checked by shadPS4
	pfsModeIs64Bit   = 0x2      // pfs.h:16-22
	pfsModeEncrypted = 0x4
	pfsModeAlways    = 0x8
	pfsBlockSize     = 0x10000
	pfscOffset       = pfscSearchStart // where Write puts the PFSC header in the outer image
	pfscHeaderSize   = 0x30
	pfscTableOffset  = 0x400 // block table offset inside the PFSC (relative to its start)
	entryKeyIndexDK3 = 3 << 12
	contentTypeGD    = 0x1A // game data, also used for patches
	contentTypeAC    = 0x1B // additional content
	drmTypePS4       = 0xF
)

// Write writes a fake-signed (or, with spec.EKPFSKey, retail-looking) PKG: the header, an
// entry table with entry_keys (0x10), image_key (0x20), param.sfo (0x1000), icon0.png
// (0x1200) and spec.Extra, and an XTS-encrypted PFS image built by buildPFSImage.
func Write(w io.Writer, spec PackSpec) error {
	s, err := sfo.Parse(spec.SFO)
	if err != nil {
		return fmt.Errorf("fpkg: param.sfo: %w", err)
	}
	contentID, _ := s.String("CONTENT_ID")
	if contentID == "" || len(contentID) > contentIDSize {
		return fmt.Errorf("fpkg: param.sfo CONTENT_ID %q is missing or longer than %d bytes", contentID, contentIDSize)
	}
	contentType := uint32(contentTypeGD)
	if cat, _ := s.String("CATEGORY"); cat == "ac" {
		contentType = contentTypeAC
	}
	ekpfsKey := spec.EKPFSKey
	if ekpfsKey == nil {
		priv, err := fakeKey()
		if err != nil {
			return err
		}
		ekpfsKey = &priv.PublicKey
	}
	if ekpfsKey.Size() != rsaBlockSize {
		return errors.New("fpkg: the EKPFS key must be a 2048-bit RSA key")
	}
	dk3Priv, err := dk3Key()
	if err != nil {
		return err
	}

	var dk3, ek [32]byte
	var seed [16]byte
	for _, b := range [][]byte{dk3[:], ek[:], seed[:]} {
		if _, err := rand.Read(b); err != nil {
			return err
		}
	}

	// Entry table at 0x1000, sorted by id as shadPS4 expects; data follows, 16-aligned.
	entries := []Entry{
		{ID: entryIDEntryKeys, Size: entryKeysMinSize},
		{ID: entryIDImageKey, Size: imageKeySize, Encrypted: true, flags1: entryEncrypted, flags2: entryKeyIndexDK3},
		{ID: entryIDParamSFO, Size: uint32(len(spec.SFO))},
		{ID: entryIDIcon0, Size: uint32(len(spec.Icon))},
	}
	data := map[uint32][]byte{entryIDParamSFO: spec.SFO, entryIDIcon0: spec.Icon}
	for _, x := range spec.Extra {
		if _, dup := data[x.ID]; dup || x.ID == entryIDEntryKeys || x.ID == entryIDImageKey {
			return fmt.Errorf("fpkg: entry %#x given twice", x.ID)
		}
		e := Entry{ID: x.ID, Size: uint32(len(x.Data))}
		if x.Encrypted {
			e.Encrypted, e.flags1 = true, entryEncrypted
		}
		entries = append(entries, e)
		data[x.ID] = x.Data
	}
	slices.SortFunc(entries, func(a, b Entry) int { return cmp.Compare(a.ID, b.ID) })
	tableOff := uint64(pkgHeaderSize)
	off := alignUp(tableOff+uint64(len(entries))*pkgEntrySize, 16)
	for i := range entries {
		entries[i].Offset = uint32(off)
		off = alignUp(off+uint64(entries[i].Size), 16)
	}
	bodyEnd := off

	// entry_keys: seed digest, 7 digests, 7 RSA blocks; only key1[3] (DK3) is used
	// (pkg.cpp:180-192).
	entryKeys := make([]byte, entryKeysMinSize)
	ct, err := rsa.EncryptPKCS1v15(rand.Reader, &dk3Priv.PublicKey, dk3[:])
	if err != nil {
		return err
	}
	copy(entryKeys[entryKeysDK3Offset:], ct)

	// image_key: EKPFS wrapped by RSA, then AES-CBC with the entry's ivKey (pkg.cpp:193-205).
	imageKey, err := rsa.EncryptPKCS1v15(rand.Reader, ekpfsKey, ek[:])
	if err != nil {
		return err
	}
	ik := slices.IndexFunc(entries, func(e Entry) bool { return e.ID == entryIDImageKey })
	block, iv := entryCBC(entryIVKey(entries[ik], dk3))
	cipher.NewCBCEncrypter(block, iv).CryptBlocks(imageKey, imageKey)

	img, err := buildPFSImage(seed, spec.Files, spec.PFSC)
	if err != nil {
		return err
	}
	if uint64(len(img)) > 2*uint64(^uint32(0)) {
		return errors.New("fpkg: PFS image too large") // pfs_cache_size is a u32
	}
	encryptPFSImage(img, newXTS(pfsGenCryptoKey(ek, seed)))

	pfsOff := alignUp(bodyEnd, pfsBlockSize)
	pkgSize := pfsOff + uint64(len(img))

	var h [pkgHeaderSize]byte
	be := binary.BigEndian
	be.PutUint32(h[hdrMagic:], pkgMagic)
	be.PutUint32(h[hdrType:], 1)
	be.PutUint32(h[hdrFileCount:], uint32(len(entries)))
	be.PutUint32(h[hdrEntryCount:], uint32(len(entries)))
	be.PutUint16(h[hdrSCEntryCount:], uint16(len(entries)))
	be.PutUint16(h[hdrEntryCount2:], uint16(len(entries)))
	be.PutUint32(h[hdrEntryOffset:], uint32(tableOff))
	be.PutUint32(h[hdrEntryDataSize:], uint32(bodyEnd-tableOff))
	be.PutUint64(h[hdrBodyOffset:], tableOff)
	be.PutUint64(h[hdrBodySize:], bodyEnd-tableOff)
	be.PutUint64(h[hdrContentOffset:], pfsOff)
	be.PutUint64(h[hdrContentSize:], uint64(len(img)))
	copy(h[hdrContentID:], contentID)
	be.PutUint32(h[hdrDRMType:], drmTypePS4)
	be.PutUint32(h[hdrContentType:], contentType)
	be.PutUint32(h[hdrPFSImageCount:], 1)
	be.PutUint64(h[hdrPFSImageOffset:], pfsOff)
	be.PutUint64(h[hdrPFSImageSize:], uint64(len(img)))
	be.PutUint64(h[hdrPkgSize:], pkgSize)
	// The reader searches 2*pfs_cache_size bytes for the PFSC (pkg.cpp:262); cover the image.
	be.PutUint32(h[hdrPFSCacheSize:], uint32((len(img)+1)/2))

	out := make([]byte, pfsOff, pkgSize)
	copy(out, h[:])
	for i, e := range entries {
		r := out[tableOff+uint64(i)*pkgEntrySize:]
		be.PutUint32(r[0x00:], e.ID)
		be.PutUint32(r[0x04:], e.nameOffset)
		be.PutUint32(r[0x08:], e.flags1)
		be.PutUint32(r[0x0C:], e.flags2)
		be.PutUint32(r[0x10:], e.Offset)
		be.PutUint32(r[0x14:], e.Size)
	}
	data[entryIDEntryKeys], data[entryIDImageKey] = entryKeys, imageKey
	for _, e := range entries {
		copy(out[e.Offset:], data[e.ID])
	}
	out = append(out, img...)
	_, err = w.Write(out)
	return err
}

func alignUp(v, a uint64) uint64 { return (v + a - 1) &^ (a - 1) }

// buildPFSImage returns the plaintext outer PFS image of files:
//
//	[0, 0x10000)            outer superblock (pfs.h:24-41) with the key seed at 0x370;
//	                        stored unencrypted (the seed must be readable before the
//	                        keys exist, pkg.cpp:252-261)
//	[0x10000, pfscOffset)   reserved for the outer inode and dirent blocks
//	[pfscOffset, ...)       the PFSC container (buildPFSC) holding buildInnerPFS(files)
//
// The result is a whole number of 0x10000-byte blocks.
func buildPFSImage(seed [16]byte, files map[string][]byte, compress bool) ([]byte, error) {
	inner, err := buildInnerPFS(files)
	if err != nil {
		return nil, err
	}
	return wrapPFSImage(seed, inner, compress)
}

// wrapPFSImage puts the inner image in a PFSC container inside an outer PFS image.
func wrapPFSImage(seed [16]byte, inner []byte, compress bool) ([]byte, error) {
	pfsc, err := buildPFSC(inner, compress)
	if err != nil {
		return nil, err
	}
	img := make([]byte, pfscOffset, alignUp(pfscOffset+uint64(len(pfsc)), pfsBlockSize))
	img = append(img, pfsc...)
	img = img[:cap(img)]
	putSuperblock(img, pfsModeIs64Bit|pfsModeEncrypted|pfsModeAlways, uint64(len(img))/pfsBlockSize)
	copy(img[pfsSeedOffset:], seed[:])
	return img, nil
}

// pfsNode is a file or directory of the inner image Write builds.
type pfsNode struct {
	name     string
	dir      bool
	data     []byte
	children []*pfsNode
	ino      uint64
	parent   uint64
	loc      uint64 // first block
	blocks   uint64
	dirents  [][]byte // a directory's dirent blocks
}

// buildInnerPFS returns the inner (PFSC-wrapped) image holding files, in the layout the
// reader (pfs.go) follows:
//
//	block 0                 superblock (pfs.h:24-41): dinode_count, superroot inode 0
//	blocks 1..k             inode table, 390 records of 0xA8 bytes per block (pfs.h:89-109)
//	then                    dirent blocks (pfs.h:117-123) of the superroot, uroot and
//	                        every directory, each starting with "." and ".."
//	then                    file data, each file in consecutive blocks
//
// Inodes are 0 superroot, 1 flat_path_table (an empty file), 2 uroot, then the entries
// breadth-first in name order, so dinode_count is 3 + entries, as pkg.cpp:398 counts
// them. Paths are split at '/'; their components are stored as they are (a test can
// build a hostile package), but they must be non-empty and at most 255 bytes.
func buildInnerPFS(files map[string][]byte) ([]byte, error) {
	uroot := &pfsNode{name: pfsSuperrootName, dir: true}
	for path, data := range files {
		n := uroot
		parts := strings.Split(path, "/")
		for i, part := range parts {
			if part == "" || len(part) > maxNameLen {
				return nil, fmt.Errorf("fpkg: bad PFS path %q", path)
			}
			last := i == len(parts)-1
			var c *pfsNode
			for _, x := range n.children {
				if x.name == part {
					c = x
				}
			}
			if c == nil {
				c = &pfsNode{name: part, dir: !last}
				if last {
					c.data = data
				}
				n.children = append(n.children, c)
			} else if c.dir == last {
				return nil, fmt.Errorf("fpkg: PFS path %q is both a file and a directory", path)
			}
			n = c
		}
	}

	superroot := &pfsNode{dir: true, ino: 0}
	fpt := &pfsNode{name: "flat_path_table", ino: 1}
	uroot.ino, uroot.parent = 2, 2 // uroot's ".." names itself: inode 0 would end the list
	superroot.children = []*pfsNode{fpt, uroot}
	nodes := []*pfsNode{superroot, fpt, uroot}
	for q := 2; q < len(nodes); q++ {
		d := nodes[q]
		if !d.dir {
			continue
		}
		slices.SortFunc(d.children, func(a, b *pfsNode) int { return strings.Compare(a.name, b.name) })
		for _, c := range d.children {
			c.ino, c.parent = uint64(len(nodes)), d.ino
			nodes = append(nodes, c)
		}
	}

	ndinode := uint64(len(nodes))
	inodeBlocks := (ndinode + pfsInodesPerBlock - 1) / pfsInodesPerBlock
	next := 1 + inodeBlocks
	for _, n := range nodes {
		if !n.dir {
			continue
		}
		var ents []dirent
		if n != superroot {
			ents = append(ents, dirent{n.ino, direntDot, "."}, dirent{n.parent, direntDotDot, ".."})
		}
		for _, c := range n.children {
			typ := int32(direntFile)
			if c.dir {
				typ = direntDir
			}
			ents = append(ents, dirent{c.ino, typ, c.name})
		}
		n.dirents = packDirents(ents)
		n.loc, n.blocks = next, uint64(len(n.dirents))
		next += n.blocks
	}
	for _, n := range nodes {
		if !n.dir && len(n.data) > 0 {
			n.loc, n.blocks = next, (uint64(len(n.data))+pfsBlockSize-1)/pfsBlockSize
			next += n.blocks
		}
	}
	if next > uint64(^uint32(0)) {
		return nil, errors.New("fpkg: PFS image too large")
	}

	inner := make([]byte, next*pfsBlockSize)
	putSuperblock(inner, pfsModeIs64Bit|pfsModeAlways, next)
	le := binary.LittleEndian
	le.PutUint64(inner[sbDinodeCount:], ndinode)
	le.PutUint64(inner[sbDinodeBlocks:], inodeBlocks)
	le.PutUint64(inner[sbSuperrootIno:], superroot.ino)
	for _, n := range nodes {
		rec := inner[(1+n.ino/pfsInodesPerBlock)*pfsBlockSize+(n.ino%pfsInodesPerBlock)*pfsInodeSize:][:pfsInodeSize]
		mode, size := uint16(inodeModeFile|0o444), uint64(len(n.data))
		if n.dir {
			mode, size = inodeModeDir|0o555, n.blocks*pfsBlockSize
		}
		le.PutUint16(rec[inodeOffMode:], mode)
		le.PutUint16(rec[0x02:], 1) // Nlink
		le.PutUint64(rec[inodeOffSize:], size)
		le.PutUint64(rec[0x10:], size) // SizeCompressed
		le.PutUint32(rec[inodeOffBlocks:], uint32(n.blocks))
		for k := range min(n.blocks, pfsDirectBlocks) {
			le.PutUint32(rec[inodeOffDB+4*k:], uint32(n.loc+k))
		}
		for k, b := range n.dirents {
			copy(inner[(n.loc+uint64(k))*pfsBlockSize:], b)
		}
		if !n.dir {
			copy(inner[n.loc*pfsBlockSize:], n.data)
		}
	}
	return inner, nil
}

// packDirents lays dirents out in 0x10000-byte blocks; entsize is the header plus the
// name and a NUL, rounded up to 8 (so "." takes 0x18, as pkg.cpp:365-369 expects).
func packDirents(ents []dirent) [][]byte {
	var blocks [][]byte
	var b []byte
	j := 0
	le := binary.LittleEndian
	for _, e := range ents {
		size := int(alignUp(uint64(direntHeaderSize+len(e.name)+1), 8))
		if b == nil || j+size > len(b) {
			b, j = make([]byte, pfsBlockSize), 0
			blocks = append(blocks, b)
		}
		le.PutUint32(b[j:], uint32(e.ino))
		le.PutUint32(b[j+4:], uint32(e.typ))
		le.PutUint32(b[j+8:], uint32(len(e.name)))
		le.PutUint32(b[j+12:], uint32(size))
		copy(b[j+direntHeaderSize:], e.name)
		j += size
	}
	return blocks
}

// putSuperblock writes the PFS superblock fields Write sets (pfs.h:24-41).
func putSuperblock(b []byte, mode uint16, nBlocks uint64) {
	le := binary.LittleEndian
	le.PutUint64(b[0x00:], pfsVersion)
	le.PutUint64(b[0x08:], pfsMagic)
	le.PutUint16(b[0x1C:], mode)
	le.PutUint32(b[0x20:], pfsBlockSize)
	le.PutUint64(b[0x28:], nBlocks)
}

// buildPFSC wraps inner (a whole number of 0x10000-byte blocks) in a PFSC container
// (pfs.h:43-52, read at pkg.cpp:280-288): header, a u64 table of num_blocks+1 block
// offsets at 0x400, then the blocks from the first 0x10000 boundary after the table. A
// block is stored zlib-compressed when compress is set and that is smaller than 0x10000,
// otherwise raw (pkg.cpp:307-310 tells them apart by the stored size).
func buildPFSC(inner []byte, compress bool) ([]byte, error) {
	if len(inner)%pfsBlockSize != 0 {
		return nil, errors.New("fpkg: inner PFS image is not a whole number of blocks")
	}
	n := uint64(len(inner)) / pfsBlockSize
	dataStart := alignUp(pfscTableOffset+8*(n+1), pfsBlockSize)
	out := make([]byte, dataStart, dataStart+uint64(len(inner)))
	le := binary.LittleEndian
	le.PutUint32(out[0x00:], pfscMagic)
	le.PutUint32(out[0x0C:], pfsBlockSize)
	le.PutUint64(out[0x10:], pfsBlockSize)
	le.PutUint64(out[0x18:], pfscTableOffset)
	le.PutUint64(out[0x20:], dataStart)
	le.PutUint64(out[0x28:], uint64(len(inner)))
	var zbuf bytes.Buffer
	for i := range n {
		le.PutUint64(out[pfscTableOffset+8*i:], uint64(len(out)))
		blk := inner[i*pfsBlockSize : (i+1)*pfsBlockSize]
		if compress {
			zbuf.Reset()
			zw := zlib.NewWriter(&zbuf)
			if _, err := zw.Write(blk); err != nil {
				return nil, err
			}
			if err := zw.Close(); err != nil {
				return nil, err
			}
			if zbuf.Len() < pfsBlockSize {
				blk = zbuf.Bytes()
			}
		}
		out = append(out, blk...)
	}
	le.PutUint64(out[pfscTableOffset+8*n:], uint64(len(out)))
	return out, nil
}

// encryptPFSImage XTS-encrypts img in place from sector 16 (offset 0x10000) on; the outer
// header block stays plain. Sector numbers count from the image start (crypto.cpp:194).
func encryptPFSImage(img []byte, c *xtsCipher) {
	for off := pfsPlainSize; off+pfsSectorSize <= len(img); off += pfsSectorSize {
		c.encryptSector(uint64(off/pfsSectorSize), img[off:off+pfsSectorSize])
	}
}
