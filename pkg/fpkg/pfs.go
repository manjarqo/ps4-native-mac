// SPDX-License-Identifier: GPL-2.0-or-later

package fpkg

import (
	"bytes"
	"compress/zlib"
	"encoding/binary"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"
)

var (
	// ErrCancelled is returned by Extract when its cancel channel is closed.
	ErrCancelled = errors.New("extraction cancelled")
	// ErrBadPKG reports a damaged or hostile package: a PFS structure that is out of
	// bounds or inconsistent.
	ErrBadPKG = errors.New("malformed PKG")
	// ErrUnsupported reports a valid-looking PFS layout the extractor cannot follow, such
	// as a file whose blocks are not stored contiguously.
	ErrUnsupported = errors.New("unsupported PFS layout")
)

// ProgressFunc receives extraction progress: the bytes of file data done so far, the
// total, and the file being written.
type ProgressFunc func(doneBytes, totalBytes int64, file string)

// FileInfo is one file or directory of the PFS image. Path is relative to the image root
// and '/'-separated.
type FileInfo struct {
	Path string
	Size int64
	Dir  bool
}

// Inner PFS layout (pfs.h, read at pkg.cpp:299-407 and 411-473; little-endian).
const (
	pfsInodeSize      = 0xA8                        // inode stride, pkg.cpp:321
	pfsInodesPerBlock = pfsBlockSize / pfsInodeSize // 390; records do not straddle blocks
	pfsDirectBlocks   = 12                          // db[] after Blocks: loc = db[0]
	pfsUnsetBlock     = 0xFFFFFFFF                  // an unused db[k] in real images
	inodeModeDir      = 0x4000                      // pfs.h:54-66
	inodeModeFile     = 0x8000
	direntFile        = 2 // pfs.h:11-14
	direntDir         = 3
	direntDot         = 4
	direntDotDot      = 5
	direntHeaderSize  = 0x10 // ino, type, namelen, entsize (pfs.h:117-123)
	maxNameLen        = 255
	extractChunk      = 16 * pfsBlockSize // 1 MiB: the write and cancel granularity
	sbDinodeCount     = 0x30              // superblock fields (pfs.h:24-41)
	sbDinodeBlocks    = 0x40
	sbSuperrootIno    = 0x48
	inodeOffMode      = 0x00 // inode fields (pfs.h:89-109)
	inodeOffSize      = 0x08
	inodeOffBlocks    = 0x60
	inodeOffDB        = 0x64                         // db[0] is shadPS4's loc
	pfscOffBlockSize  = 0x10                         // block_sz2, PFSC header (pfs.h:43-52)
	pfscOffTable      = 0x18                         // block_offsets
	pfscOffDataLength = 0x28                         // data_length
	pfsSuperrootName  = "uroot"                      // the image root, inside the superroot
	pfsMaxStoredBlock = pfsBlockSize + pfsSectorSize // stored block plus sector skew
)

// pfsInode holds the inode fields the extractor uses.
type pfsInode struct {
	mode   uint16
	size   int64
	blocks uint64
	db     [pfsDirectBlocks]uint64
}

// pfsEntry is a file or directory Extract writes: one found by walk, or a PKG entry
// written to sce_sys (sys).
type pfsEntry struct {
	path string
	dir  bool
	sys  bool // a PKG entry: loc is its offset in the PKG file
	size int64
	loc  uint64 // first PFSC block of a file's data, or the PKG offset of a sys entry
}

// sysEntryMin is the first entry id written to sce_sys. The ids below it (digests,
// entry_keys, image_key, general_digests, metas, entry_names) hold the package's own keys
// and digests, not files of the game.
const sysEntryMin = 0x400

// withSysEntries appends to ents, the entries of the PFS image, the PKG entries that
// shadPS4 writes to <out>/sce_sys/<name> before it extracts the PFS image (pkg.cpp:153-157,
// 211-221): every entry with a name, such as param.sfo, icon0.png, pic0.png, pic1.png and
// changeinfo/changeinfo.xml, with its parent directories. In real packages these files
// are in the entry table only, not in the PFS image. Left out are:
//   - the key and digest entries below sysEntryMin;
//   - entries shadPS4 does not name (it writes them as sce_sys/<decimal id>,
//     pkg.cpp:159-176);
//   - encrypted entries. shadPS4 writes them as ciphertext, and decrypts and rewrites
//     only the NP entries 0x400-0x403 (license.dat, license.info, nptitle.dat,
//     npbind.dat, pkg.cpp:223-248); none of them is read by the runtime, the analyser or
//     the build.
//
// A PFS file with the same path wins, as in shadPS4, where the PFS extraction overwrites
// the entry written before it.
func (p *Package) withSysEntries(ents []pfsEntry) []pfsEntry {
	have := make(map[string]bool, len(ents))
	for _, e := range ents {
		have[e.path] = true
	}
	for _, en := range p.Entries {
		if en.Name == "" || en.Encrypted || en.ID < sysEntryMin {
			continue
		}
		path := "sce_sys/" + en.Name
		if have[path] {
			continue
		}
		for i := range len(path) {
			if path[i] == '/' && !have[path[:i]] {
				have[path[:i]] = true
				ents = append(ents, pfsEntry{path: path[:i], dir: true})
			}
		}
		have[path] = true
		ents = append(ents, pfsEntry{path: path, sys: true, size: int64(en.Size), loc: uint64(en.Offset)})
	}
	return ents
}

type dirent struct {
	ino  uint64
	typ  int32
	name string
}

// pfsReader reads the inner PFS image stored in the PFSC container of an XTS-encrypted
// PFS image. It reads through r on demand and keeps only a few fixed-size buffers, so
// nothing grows with the image or file size.
type pfsReader struct {
	r          io.ReaderAt
	name       string // for errors
	base, size uint64 // file offset and size of the PFS image
	c          *xtsCipher
	pfsc       uint64 // PFSC header offset inside the image
	table      uint64 // block offset table offset inside the image
	nBlocks    uint64
	ndinode    uint64
	superroot  uint64

	sec     []byte // one decrypted sector, for small reads
	secNo   uint64
	secOK   bool
	raw     []byte // the sectors holding one stored block
	meta    []byte // one decoded block holding inodes or dirents
	metaNo  uint64
	metaOK  bool
	zr      io.ReadCloser
	zin     bytes.Reader
	scratch [16]byte
}

func (r *pfsReader) bad(format string, a ...any) error {
	return fmt.Errorf("%s: %w: %s", r.name, ErrBadPKG, fmt.Sprintf(format, a...))
}

// newPFSReader parses the PFSC header (pfs.h:43-52, pkg.cpp:280-288) at pfscOff inside
// the image and the inner superblock (decoded block 0, pkg.cpp:312-314).
func newPFSReader(rd io.ReaderAt, name string, base, size uint64, c *xtsCipher, pfscOff uint64) (*pfsReader, error) {
	r := &pfsReader{
		r: rd, name: name, base: base, size: size, c: c, pfsc: pfscOff,
		sec: make([]byte, pfsSectorSize), raw: make([]byte, pfsMaxStoredBlock), meta: make([]byte, pfsBlockSize),
	}
	var h [pfscHeaderSize]byte
	if err := r.readSmall(pfscOff, h[:]); err != nil {
		return nil, err
	}
	le := binary.LittleEndian
	if le.Uint32(h[0:]) != pfscMagic {
		return nil, r.bad("no PFSC header at %#x", pfscOff)
	}
	// shadPS4 hard-codes 0x10000 blocks (pkg.cpp:297, 307, 429, 455) and divides by
	// block_sz2 (pkg.cpp:283); require that they agree.
	if bs := le.Uint64(h[pfscOffBlockSize:]); bs != pfsBlockSize {
		return nil, r.bad("PFSC block size %#x, want %#x", bs, pfsBlockSize)
	}
	dataLen := le.Uint64(h[pfscOffDataLength:])
	// num_blocks = data_length / block_sz2 (pkg.cpp:283): a trailing partial block is
	// dropped, as in the source.
	r.nBlocks = dataLen / pfsBlockSize
	if r.nBlocks == 0 {
		return nil, r.bad("PFSC data length %#x holds no whole block", dataLen)
	}
	tableRel := le.Uint64(h[pfscOffTable:])
	if !within(pfscOff, tableRel, size) || !within(pfscOff+tableRel, 8*(r.nBlocks+1), size) {
		return nil, r.bad("PFSC block table (%d blocks at %#x) lies outside the image", r.nBlocks, tableRel)
	}
	r.table = pfscOff + tableRel

	sb, err := r.metaBlock(0)
	if err != nil {
		return nil, err
	}
	// shadPS4 reads only the low 32 bits (pkg.cpp:314); the field is 64-bit (pfs.h:37).
	r.ndinode = le.Uint64(sb[sbDinodeCount:])
	r.superroot = le.Uint64(sb[sbSuperrootIno:])
	if r.ndinode == 0 || (r.ndinode-1)/pfsInodesPerBlock+1 >= r.nBlocks {
		return nil, r.bad("inode count %d does not fit in %d blocks", r.ndinode, r.nBlocks)
	}
	if r.superroot >= r.ndinode {
		// shadPS4 never reads superroot_ino: it recognises the superroot block by the
		// "flat_path_table" name at offset 0x10 (pkg.cpp:331-337), the dirent block of
		// inode 0 in the images it reads. Fall back to inode 0 likewise.
		r.superroot = 0
	}
	return r, nil
}

// readSectors reads and decrypts whole sectors at off (a multiple of the sector size)
// inside the image into buf.
func (r *pfsReader) readSectors(off uint64, buf []byte) error {
	if !within(off, uint64(len(buf)), r.size) {
		return r.bad("read of %d bytes at %#x lies outside the PFS image", len(buf), off)
	}
	if off < pfsPlainSize {
		return r.bad("read at %#x inside the plain PFS header", off)
	}
	if _, err := r.r.ReadAt(buf, int64(r.base+off)); err != nil {
		return fmt.Errorf("%s: reading the PFS image: %w", r.name, err)
	}
	for i := 0; i < len(buf); i += pfsSectorSize {
		r.c.decryptSector((off+uint64(i))/pfsSectorSize, buf[i:i+pfsSectorSize])
	}
	return nil
}

// readSmall reads len(dst) decrypted bytes at pos inside the image, across sector
// boundaries, through a one-sector cache.
func (r *pfsReader) readSmall(pos uint64, dst []byte) error {
	if !within(pos, uint64(len(dst)), r.size) {
		return r.bad("read of %d bytes at %#x lies outside the PFS image", len(dst), pos)
	}
	for len(dst) > 0 {
		s := pos / pfsSectorSize
		if !r.secOK || r.secNo != s {
			r.secOK = false
			if err := r.readSectors(s*pfsSectorSize, r.sec); err != nil {
				return err
			}
			r.secNo, r.secOK = s, true
		}
		n := copy(dst, r.sec[pos%pfsSectorSize:])
		dst, pos = dst[n:], pos+uint64(n)
	}
	return nil
}

// decodeBlock decodes PFSC block i into out (pfsBlockSize bytes). As pkg.cpp:436-458, its
// stored bytes are [off[i], off[i+1]) of the block table, relative to the PFSC header; a
// stored size of 0x10000 is raw data and a smaller one a zlib stream. Unlike shadPS4 the
// offsets are 64-bit, the range is checked against the image, and a zero-size block (for
// which the source has no case and reuses a stale buffer) is an error.
func (r *pfsReader) decodeBlock(i uint64, out []byte) error {
	if i >= r.nBlocks {
		return r.bad("PFSC block %d out of range (%d blocks)", i, r.nBlocks)
	}
	if err := r.readSmall(r.table+8*i, r.scratch[:16]); err != nil {
		return err
	}
	le := binary.LittleEndian
	start, end := le.Uint64(r.scratch[0:]), le.Uint64(r.scratch[8:])
	n := end - start
	switch {
	case end < start || n > pfsBlockSize:
		return r.bad("PFSC block %d has a bad stored range [%#x, %#x)", i, start, end)
	case n == 0:
		return r.bad("PFSC block %d has a stored size of 0", i)
	case !within(r.pfsc, end, r.size):
		return r.bad("PFSC block %d lies outside the image", i)
	}
	abs := r.pfsc + start
	lo := abs &^ (pfsSectorSize - 1)
	hi := alignUp(abs+n, pfsSectorSize)
	buf := r.raw[:hi-lo]
	if err := r.readSectors(lo, buf); err != nil {
		return err
	}
	stored := buf[abs-lo : abs-lo+n]
	if n == pfsBlockSize {
		copy(out, stored)
		return nil
	}
	if err := r.inflate(stored, out); err != nil {
		return r.bad("PFSC block %d: %v", i, err)
	}
	return nil
}

// inflate decodes the zlib stream stored into out, which it must fill (pkg.cpp:10-30
// inflates into a 0x10000 buffer). shadPS4 ignores inflate's result, so once the block is
// full a missing or wrong Adler-32 trailer is tolerated; a stream that yields more than
// one block is refused.
func (r *pfsReader) inflate(stored, out []byte) error {
	r.zin.Reset(stored)
	var err error
	if r.zr == nil {
		r.zr, err = zlib.NewReader(&r.zin)
	} else {
		err = r.zr.(zlib.Resetter).Reset(&r.zin, nil)
	}
	if err != nil {
		return err
	}
	if _, err := io.ReadFull(r.zr, out[:pfsBlockSize]); err != nil {
		return fmt.Errorf("inflates to less than one block: %w", err)
	}
	switch _, err := io.ReadFull(r.zr, r.scratch[:1]); {
	case err == nil:
		return errors.New("inflates to more than one block")
	case err == io.EOF, err == io.ErrUnexpectedEOF, errors.Is(err, zlib.ErrChecksum):
		return nil
	default:
		return err
	}
}

// metaBlock returns decoded block i through a one-block cache; the result is valid until
// the next metaBlock call.
func (r *pfsReader) metaBlock(i uint64) ([]byte, error) {
	if r.metaOK && r.metaNo == i {
		return r.meta, nil
	}
	r.metaOK = false
	if err := r.decodeBlock(i, r.meta); err != nil {
		return nil, err
	}
	r.metaNo, r.metaOK = i, true
	return r.meta, nil
}

// inode returns inode ino. The table starts at block 1 (pkg.cpp:319) with 0xA8-byte
// records; shadPS4 packs 0x10000/0xA8 = 390.1 of them per block, reading the 391st past
// the block end and stopping at the first free slot (pkg.cpp:320-328). Here a block holds
// 390 records and inodes are indexed by number, so a free slot shifts nothing.
func (r *pfsReader) inode(ino uint64) (pfsInode, error) {
	var in pfsInode
	if ino >= r.ndinode {
		return in, r.bad("inode %d out of range (%d inodes)", ino, r.ndinode)
	}
	b, err := r.metaBlock(1 + ino/pfsInodesPerBlock)
	if err != nil {
		return in, err
	}
	rec := b[(ino%pfsInodesPerBlock)*pfsInodeSize:][:pfsInodeSize]
	le := binary.LittleEndian
	in.mode = le.Uint16(rec[inodeOffMode:])
	in.size = int64(le.Uint64(rec[inodeOffSize:]))
	in.blocks = uint64(le.Uint32(rec[inodeOffBlocks:]))
	for k := range in.db {
		in.db[k] = uint64(le.Uint32(rec[inodeOffDB+4*k:]))
	}
	return in, nil
}

// checkBlockMap checks that in's blocks are loc .. loc+blocks-1 of the PFSC table, the
// contiguous layout shadPS4 assumes (pkg.cpp:417-418, 436-439). The direct block pointers
// db[1..] must be unset or continue the run; a file whose map goes elsewhere is
// fragmented and gives ErrUnsupported instead of wrong data. Real images mark unused
// pointers 0xFFFFFFFF (inFAMOUS Second Son: db[1..min(Blocks,12)-1] of every inode, the
// rest 0); 0 is unset as well. shadPS4 never reads db[1..]. Indirect pointers are not
// followed (shadPS4 does not either).
func (r *pfsReader) checkBlockMap(in pfsInode, what string) error {
	if in.blocks == 0 {
		return nil
	}
	loc := in.db[0]
	if loc == 0 || loc+in.blocks > r.nBlocks {
		return r.bad("%s: blocks [%d, +%d) lie outside the image (%d blocks)", what, loc, in.blocks, r.nBlocks)
	}
	for k := uint64(1); k < min(in.blocks, pfsDirectBlocks); k++ {
		if b := in.db[k]; b != 0 && b != pfsUnsetBlock && b != loc+k {
			return fmt.Errorf("%s: %w: %s is fragmented (block %d is at %d, not %d)", r.name, ErrUnsupported, what, k, b, loc+k)
		}
	}
	return nil
}

// dirents lists the dirents of directory inode ino (pfs.h:117-123): entries packed by
// entsize in each of its blocks, a list ending at ino 0 or at the block end (pkg.cpp:372-
// 402). With wantDot, the first entry must be "." naming ino itself, which every directory
// block of shadPS4's walk starts with (pkg.cpp:365-369).
func (r *pfsReader) dirents(ino uint64, in pfsInode, what string, wantDot bool, out []dirent) ([]dirent, error) {
	if in.blocks == 0 {
		return nil, r.bad("directory %s has no blocks", what)
	}
	if err := r.checkBlockMap(in, "directory "+what); err != nil {
		return nil, err
	}
	le := binary.LittleEndian
	out = out[:0]
	for k := range in.blocks {
		b, err := r.metaBlock(in.db[0] + k)
		if err != nil {
			return nil, err
		}
		for j := 0; j+direntHeaderSize <= len(b); {
			dino := int32(le.Uint32(b[j:]))
			if dino == 0 {
				if wantDot && k == 0 && j == 0 {
					return nil, r.bad("directory %s (inode %d) is empty, without \".\"", what, ino)
				}
				break
			}
			typ := int32(le.Uint32(b[j+4:]))
			namelen := int32(le.Uint32(b[j+8:]))
			entsize := int32(le.Uint32(b[j+12:]))
			if namelen < 0 || namelen > maxNameLen || entsize < direntHeaderSize+namelen || entsize > int32(len(b)-j) {
				return nil, r.bad("directory %s: bad dirent at block %d+%#x", what, in.db[0]+k, j)
			}
			if dino < 0 || uint64(dino) >= r.ndinode {
				return nil, r.bad("directory %s: dirent names inode %d of %d", what, dino, r.ndinode)
			}
			d := dirent{ino: uint64(dino), typ: typ, name: string(b[j+direntHeaderSize : j+direntHeaderSize+int(namelen)])}
			if wantDot && k == 0 && j == 0 && (d.typ != direntDot || d.ino != ino) {
				return nil, r.bad("directory %s (inode %d): its block does not start with \".\"", what, ino)
			}
			out = append(out, d)
			j += int(entsize)
		}
	}
	return out, nil
}

// validName reports whether a dirent name is safe as one path component.
func validName(s string) bool {
	return s != "" && s != "." && s != ".." && !strings.ContainsAny(s, "/\\\x00")
}

// walk lists every file and directory under uroot, parents before children. Instead of
// shadPS4's scan of all blocks for "flat_path_table" and "."/".." signatures, with uroot
// taken as the inode whose number equals the superroot entry count (pkg.cpp:331-363), it
// finds uroot by name in the superroot directory and follows each directory inode's
// blocks, which does not depend on block order (port notes 7.5).
func (r *pfsReader) walk() ([]pfsEntry, error) {
	sr, err := r.inode(r.superroot)
	if err != nil {
		return nil, err
	}
	var buf []dirent
	buf, err = r.dirents(r.superroot, sr, "superroot", false, buf)
	if err != nil {
		return nil, err
	}
	uroot := uint64(0)
	for _, d := range buf {
		if d.typ == direntDir && d.name == pfsSuperrootName {
			uroot = d.ino
			break
		}
	}
	if uroot == 0 {
		return nil, r.bad("no %q directory in the superroot", pfsSuperrootName)
	}

	type dir struct {
		ino  uint64
		path string
	}
	queue := []dir{{uroot, ""}}
	seen := map[uint64]bool{uroot: true}
	var out []pfsEntry
	for len(queue) > 0 {
		d := queue[0]
		queue = queue[1:]
		what := d.path
		if what == "" {
			what = "/"
		}
		in, err := r.inode(d.ino)
		if err != nil {
			return nil, err
		}
		if buf, err = r.dirents(d.ino, in, what, true, buf); err != nil {
			return nil, err
		}
		for _, e := range buf {
			if e.typ == direntDot || e.typ == direntDotDot {
				continue
			}
			if !validName(e.name) {
				return nil, r.bad("directory %s: unsafe entry name %q", what, e.name)
			}
			rel := e.name
			if d.path != "" {
				rel = d.path + "/" + e.name
			}
			// Every file and directory has its own inode, so there are fewer entries
			// than inodes (pkg.cpp:398 stops the walk at ndinode); this also bounds the
			// walk of a hostile image.
			if uint64(len(out)) >= r.ndinode {
				return nil, r.bad("more directory entries than inodes")
			}
			ci, err := r.inode(e.ino)
			if err != nil {
				return nil, err
			}
			switch e.typ {
			case direntDir:
				if seen[e.ino] {
					return nil, r.bad("%s: directory inode %d is reached twice", rel, e.ino)
				}
				seen[e.ino] = true
				queue = append(queue, dir{e.ino, rel})
				out = append(out, pfsEntry{path: rel, dir: true})
			case direntFile:
				// File or directory is decided by the dirent type alone, as in the
				// source (pkg.cpp:385-396, 416); the inode mode is not consulted.
				if ci.size < 0 {
					return nil, r.bad("%s: negative size %d", rel, ci.size)
				}
				if ci.size == 0 {
					// Written as an empty file whatever its Blocks (pkg.cpp:460-468).
					out = append(out, pfsEntry{path: rel})
					break
				}
				// The last block is trimmed to Size (pkg.cpp:460-468); any other
				// Blocks makes shadPS4's write size wrap, so it must be exactly the
				// blocks Size needs.
				if ci.blocks != (uint64(ci.size)+pfsBlockSize-1)/pfsBlockSize {
					return nil, r.bad("%s: size %d does not match its %d blocks", rel, ci.size, ci.blocks)
				}
				if err := r.checkBlockMap(ci, rel); err != nil {
					return nil, err
				}
				out = append(out, pfsEntry{path: rel, size: ci.size, loc: ci.db[0]})
			default:
				return nil, fmt.Errorf("%s: %w: %s has dirent type %d", r.name, ErrUnsupported, rel, e.typ)
			}
		}
	}
	return out, nil
}

// openPFS opens the package file and a reader of its inner PFS image. The caller closes
// the file.
func (p *Package) openPFS() (*pfsReader, *os.File, error) {
	f, err := os.Open(p.path)
	if err != nil {
		return nil, nil, err
	}
	c, pfscOff, err := p.pfsKeys(f)
	if err == nil {
		var r *pfsReader
		if r, err = newPFSReader(f, p.path, p.PFSOffset, p.PFSSize, c, pfscOff); err == nil {
			return r, f, nil
		}
	}
	f.Close()
	return nil, nil, err
}

// walk lists what Extract writes: the PFS image and the sce_sys entries.
func (p *Package) walk() ([]pfsEntry, error) {
	r, f, err := p.openPFS()
	if err != nil {
		return nil, err
	}
	defer f.Close()
	ents, err := r.walk()
	if err != nil {
		return nil, err
	}
	return p.withSysEntries(ents), nil
}

// Files lists the files and directories Extract writes, parents before children: those
// of the PFS image, then the sce_sys entries of the PKG (see withSysEntries).
func (p *Package) Files() ([]FileInfo, error) {
	ents, err := p.walk()
	if err != nil {
		return nil, err
	}
	out := make([]FileInfo, len(ents))
	for i, e := range ents {
		out[i] = FileInfo{Path: e.path, Size: e.size, Dir: e.dir}
	}
	return out, nil
}

// UnpackedSize returns the total size of the files Extract writes.
func (p *Package) UnpackedSize() (int64, error) {
	ents, err := p.walk()
	if err != nil {
		return 0, err
	}
	return totalSize(ents), nil
}

func totalSize(ents []pfsEntry) int64 {
	var n int64
	for _, e := range ents {
		n += e.size
	}
	return n
}

func cancelled(c <-chan struct{}) bool {
	select {
	case <-c:
		return true
	default:
		return false
	}
}

// Extract writes the PFS image's files and the package's sce_sys entries (see
// withSysEntries) under dst: directories 0755, files 0644. A file
// for which skip returns true is left as it is (and counts as done). progress, if not nil,
// is called after each chunk of at most 1 MiB; cancel, if closed, stops the extraction
// between chunks with ErrCancelled. Every path stays inside dst: names with "/", "\" or
// NUL, ".." and "." are refused, and writes go through an os.Root, which refuses symlinks
// that leave dst. Each file is written under a scratch name (PartName) and renamed to its
// final name once complete, so after a cancelled or failed extraction every file under
// its final name is whole; truncated scratch files and directories may be left, so
// callers extract into a scratch directory.
func (p *Package) Extract(dst string, skip func(rel string, size int64) bool, progress ProgressFunc, cancel <-chan struct{}) error {
	r, f, err := p.openPFS()
	if err != nil {
		return err
	}
	defer f.Close()
	ents, err := r.walk()
	if err != nil {
		return err
	}
	ents = p.withSysEntries(ents)
	if err := os.MkdirAll(dst, 0o755); err != nil {
		return err
	}
	root, err := os.OpenRoot(dst)
	if err != nil {
		return err
	}
	defer root.Close()

	total, done := totalSize(ents), int64(0)
	buf := make([]byte, extractChunk)
	for _, e := range ents {
		if cancelled(cancel) {
			return ErrCancelled
		}
		if e.dir {
			if err := root.MkdirAll(filepath.FromSlash(e.path), 0o755); err != nil {
				return err
			}
			continue
		}
		if skip == nil || !skip(e.path, e.size) {
			err := r.extractFile(root, e, buf, cancel, func(n int64) {
				done += n
				if progress != nil {
					progress(done, total, e.path)
				}
			})
			if err != nil {
				return err
			}
			continue
		}
		done += e.size
		if progress != nil {
			progress(done, total, e.path)
		}
	}
	return nil
}

// partSuffix marks a file Extract is still writing. It contains '\\', which validName
// refuses in every entry name, so no file of an image can have a scratch name.
const partSuffix = "\\part"

// PartName is the name Extract writes the file name under until it is complete.
func PartName(name string) string { return name + partSuffix }

// extractFile writes file e (pkg.cpp:411-473): its blocks decoded in order, the last one
// trimmed to the file size, in chunks of buf's size; a sys entry is copied from the PKG
// file (pkg.cpp:211-221). It writes PartName(name) and renames
// it to name when the file is complete, so a file under its final name is never truncated.
func (r *pfsReader) extractFile(root *os.Root, e pfsEntry, buf []byte, cancel <-chan struct{}, onChunk func(int64)) error {
	name := filepath.FromSlash(e.path)
	part := PartName(name)
	if err := r.writeFile(root, part, e, buf, cancel, onChunk); err != nil {
		return err
	}
	return root.Rename(part, name)
}

func (r *pfsReader) writeFile(root *os.Root, name string, e pfsEntry, buf []byte, cancel <-chan struct{}, onChunk func(int64)) error {
	out, err := root.OpenFile(name, os.O_WRONLY|os.O_CREATE|os.O_TRUNC, 0o644)
	if err != nil {
		return err
	}
	defer out.Close()
	if err := out.Chmod(0o644); err != nil {
		return err
	}
	blk := e.loc
	for left := e.size; left > 0; {
		if cancelled(cancel) {
			return ErrCancelled
		}
		n := min(left, int64(len(buf)))
		if e.sys {
			if _, err := r.r.ReadAt(buf[:n], int64(blk)); err != nil {
				return fmt.Errorf("%s: reading the PKG entry: %w", e.path, err)
			}
			blk += uint64(n)
		}
		for off := int64(0); !e.sys && off < n; off += pfsBlockSize {
			if err := r.decodeBlock(blk, buf[off:off+pfsBlockSize]); err != nil {
				return fmt.Errorf("%s: %w", e.path, err)
			}
			blk++
		}
		if _, err := out.Write(buf[:n]); err != nil {
			return err
		}
		left -= n
		onChunk(n)
	}
	if e.size == 0 {
		onChunk(0)
	}
	return out.Close()
}
