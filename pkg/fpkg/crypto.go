// SPDX-License-Identifier: GPL-2.0-or-later

package fpkg

import (
	"crypto/aes"
	"crypto/cipher"
	"crypto/hmac"
	"crypto/rsa"
	"crypto/sha256"
	"encoding/binary"
	"errors"
	"fmt"
	"io"
	"math/big"
	"os"
	"sync"
)

// ErrRetail reports a package whose PFS keys cannot be unwrapped with the public fake
// keyset, i.e. a retail (console-key) PKG.
var ErrRetail = errors.New("this PKG is encrypted with console keys; use a dump of your own console or an fpkg")

const (
	pfsSectorSize   = 0x1000  // XTS data unit of the PFS image (crypto.cpp:193)
	pfsPlainSize    = 0x10000 // the outer PFS header block; XTS starts at sector 16
	pfsSeedOffset   = 0x370   // seed inside the outer PFS header (pkg.cpp:254)
	pfscMagic       = 0x43534650
	pfscSearchStart = 0x20000 // GetPFSCOffset, pkg.cpp:32-41
	pfscSearchStep  = 0x10000
)

var (
	fakeKey = sync.OnceValues(func() (*rsa.PrivateKey, error) { return loadKeyset(&fakeKeyset) })
	dk3Key  = sync.OnceValues(func() (*rsa.PrivateKey, error) { return loadKeyset(&pkgDerivedKey3Keyset) })
)

// loadKeyset builds an RSA private key from keys.h components (crypto.cpp:8-46) and
// checks the redundant CRT values against the ones keys.h stores, so a damaged copy of the
// key bytes fails loudly instead of silently decrypting garbage.
func loadKeyset(k *rsaKeyset) (*rsa.PrivateKey, error) {
	num := func(b []byte) *big.Int { return new(big.Int).SetBytes(b) }
	e := num(k.PublicExponent)
	if !e.IsInt64() {
		return nil, errors.New("fpkg: bad embedded RSA public exponent")
	}
	priv := &rsa.PrivateKey{
		PublicKey: rsa.PublicKey{N: num(k.Modulus), E: int(e.Int64())},
		D:         num(k.PrivateExponent),
		Primes:    []*big.Int{num(k.Prime1), num(k.Prime2)},
	}
	if err := priv.Validate(); err != nil {
		return nil, fmt.Errorf("fpkg: embedded RSA key: %w", err)
	}
	priv.Precompute()
	p, q, one := priv.Primes[0], priv.Primes[1], big.NewInt(1)
	dp := new(big.Int).Mod(priv.D, new(big.Int).Sub(p, one))
	dq := new(big.Int).Mod(priv.D, new(big.Int).Sub(q, one))
	qinv := new(big.Int).ModInverse(q, p)
	if dp.Cmp(num(k.Exponent1)) != 0 || dq.Cmp(num(k.Exponent2)) != 0 || qinv == nil || qinv.Cmp(num(k.Coefficient)) != 0 {
		return nil, errors.New("fpkg: embedded RSA key: CRT values do not match")
	}
	return priv, nil
}

// rsaDecrypt32 is RSA2048Decrypt (crypto.cpp:72-93): RSAES-PKCS1-v1_5 decryption keeping
// the first 32 bytes. Unlike the original it reports a padding failure or a short
// plaintext instead of returning uninitialised memory.
func rsaDecrypt32(priv *rsa.PrivateKey, ct []byte) ([32]byte, bool) {
	var out [32]byte
	pt, err := priv.Decrypt(nil, ct, nil) // nil options = PKCS #1 v1.5
	if err != nil || len(pt) < len(out) {
		return out, false
	}
	copy(out[:], pt)
	return out, true
}

// entryIVKey is ivKeyHASH256 over the in-memory PKGEntry of e followed by DK3
// (pkg.cpp:197-201, crypto.cpp:95-103): the first 24 bytes of the table row in big-endian
// order, then 8 zero bytes (the padding is skipped on read, never copied), then DK3.
func entryIVKey(e Entry, dk3 [32]byte) [32]byte {
	var in [64]byte
	be := binary.BigEndian
	be.PutUint32(in[0x00:], e.ID)
	be.PutUint32(in[0x04:], e.nameOffset)
	be.PutUint32(in[0x08:], e.flags1)
	be.PutUint32(in[0x0C:], e.flags2)
	be.PutUint32(in[0x10:], e.Offset)
	be.PutUint32(in[0x14:], e.Size)
	copy(in[32:], dk3[:])
	return sha256.Sum256(in[:])
}

// entryCBC returns the AES-128-CBC parameters of aesCbcCfb128Decrypt (crypto.cpp:105-121):
// key = ivKey[16:32], iv = ivKey[0:16].
func entryCBC(ivKey [32]byte) (cipher.Block, []byte) {
	b, err := aes.NewCipher(ivKey[16:32])
	if err != nil {
		panic(err) // a 16-byte key is always valid
	}
	return b, ivKey[0:16]
}

// pfsGenCryptoKey is PfsGenCryptoKey (crypto.cpp:164-187): HMAC-SHA256 keyed by EKPFS
// over u32le(1) || seed; the first half is the tweak key, the second the data key.
func pfsGenCryptoKey(ekpfs [32]byte, seed [16]byte) (data, tweak [16]byte) {
	var d [20]byte
	binary.LittleEndian.PutUint32(d[:], 1)
	copy(d[4:], seed[:])
	m := hmac.New(sha256.New, ekpfs[:])
	m.Write(d[:])
	sum := m.Sum(nil)
	copy(tweak[:], sum[:16])
	copy(data[:], sum[16:32])
	return data, tweak
}

// xtsCipher is AES-128-XTS (IEEE 1619) with independent data and tweak keys, as
// decryptPFS (crypto.cpp:189-215): the tweak of a data unit is its number as a 128-bit
// little-endian value encrypted with the tweak key, multiplied by alpha per 16-byte block.
type xtsCipher struct{ data, tweak cipher.Block }

func newXTS(data, tweak [16]byte) *xtsCipher {
	d, err := aes.NewCipher(data[:])
	if err != nil {
		panic(err)
	}
	t, err := aes.NewCipher(tweak[:])
	if err != nil {
		panic(err)
	}
	return &xtsCipher{data: d, tweak: t}
}

// crypt encrypts or decrypts buf in place as the data unit numbered sector. len(buf) must
// be a multiple of 16; a PFS caller passes whole 0x1000-byte sectors, or a prefix of one.
func (c *xtsCipher) crypt(sector uint64, buf []byte, decrypt bool) {
	if len(buf)%aes.BlockSize != 0 {
		panic("fpkg: XTS data unit is not a whole number of AES blocks")
	}
	var t [16]byte
	binary.LittleEndian.PutUint64(t[:], sector)
	c.tweak.Encrypt(t[:], t[:])
	for off := 0; off < len(buf); off += aes.BlockSize {
		b := buf[off : off+aes.BlockSize]
		subtle16(b, t[:])
		if decrypt {
			c.data.Decrypt(b, b)
		} else {
			c.data.Encrypt(b, b)
		}
		subtle16(b, t[:])
		xtsMulAlpha(&t)
	}
}

func (c *xtsCipher) encryptSector(sector uint64, buf []byte) { c.crypt(sector, buf, false) }
func (c *xtsCipher) decryptSector(sector uint64, buf []byte) { c.crypt(sector, buf, true) }

func subtle16(dst, x []byte) {
	for i := range 16 {
		dst[i] ^= x[i]
	}
}

// xtsMulAlpha is xtsMult (crypto.h:52-62): multiply the little-endian 128-bit tweak by x
// in GF(2^128) with the reduction polynomial x^128 + x^7 + x^2 + x + 1.
func xtsMulAlpha(t *[16]byte) {
	var carry byte
	for k := range t {
		next := t[k] >> 7
		t[k] = t[k]<<1 | carry
		carry = next
	}
	if carry != 0 {
		t[0] ^= 0x87
	}
}

// xtsEncryptSector and xtsDecryptSector run XTS with data key k1 and tweak key k2 over one
// data unit in place.
func xtsEncryptSector(k1, k2 [16]byte, sector uint64, buf []byte) {
	newXTS(k1, k2).encryptSector(sector, buf)
}

func xtsDecryptSector(k1, k2 [16]byte, sector uint64, buf []byte) {
	newXTS(k1, k2).decryptSector(sector, buf)
}

// ekpfs unwraps the EKPFS: DK3 from entry 0x10 with the PkgDerivedKey3 key (pkg.cpp:180-192),
// then entry 0x20 by AES-CBC with its ivKey and RSA with the fake key (pkg.cpp:193-205).
// A key that does not unwrap means a retail package (ErrRetail).
func (p *Package) ekpfs(r io.ReaderAt) ([32]byte, error) {
	var zero [32]byte
	// Find both entries first: unlike pkg.cpp:142, do not depend on the table order.
	keys, ok1 := p.entry(entryIDEntryKeys)
	img, ok2 := p.entry(entryIDImageKey)
	if !ok1 || !ok2 {
		return zero, fmt.Errorf("%s: no entry_keys/image_key entries", p.path)
	}
	if keys.Size < entryKeysMinSize || img.Size < imageKeySize {
		return zero, fmt.Errorf("%s: entry_keys/image_key entries are too small", p.path)
	}
	dk3Priv, err := dk3Key()
	if err != nil {
		return zero, err
	}
	fakePriv, err := fakeKey()
	if err != nil {
		return zero, err
	}

	var buf [rsaBlockSize]byte
	if _, err := r.ReadAt(buf[:], int64(keys.Offset)+entryKeysDK3Offset); err != nil {
		return zero, fmt.Errorf("%s: reading entry_keys: %w", p.path, err)
	}
	dk3, ok := rsaDecrypt32(dk3Priv, buf[:])
	if !ok {
		return zero, fmt.Errorf("%w (DK3 does not decrypt with the public PKG key)", ErrRetail)
	}

	if _, err := r.ReadAt(buf[:], int64(img.Offset)); err != nil {
		return zero, fmt.Errorf("%s: reading image_key: %w", p.path, err)
	}
	block, iv := entryCBC(entryIVKey(img, dk3))
	cipher.NewCBCDecrypter(block, iv).CryptBlocks(buf[:], buf[:])
	ek, ok := rsaDecrypt32(fakePriv, buf[:])
	if !ok {
		return zero, fmt.Errorf("%w (EKPFS does not decrypt with the fake key)", ErrRetail)
	}
	return ek, nil
}

// pfsKeys derives the XTS cipher of the PFS image read through f (pkg.cpp:252-261) and
// checks it by finding the PFSC magic in the decrypted image; it returns the cipher and
// the offset of the PFSC header inside the image. A package whose keys the fake keyset
// cannot unwrap gives ErrRetail; one with no PFSC search window gives ErrBadPKG.
func (p *Package) pfsKeys(f io.ReaderAt) (*xtsCipher, uint64, error) {
	ek, err := p.ekpfs(f)
	if err != nil {
		return nil, 0, err
	}
	if p.PFSSize < pfsPlainSize {
		return nil, 0, fmt.Errorf("%s: %w: PFS image is too small (%d bytes)", p.path, ErrBadPKG, p.PFSSize)
	}
	if p.pfsCacheSize == 0 {
		// The search window is 2*pfs_cache_size (pkg.cpp:262); shadPS4 then decrypts
		// nothing and extracts nothing. That is a damaged header, not a retail key.
		return nil, 0, fmt.Errorf("%s: %w: pfs_cache_size is 0, so there is no PFSC search window", p.path, ErrBadPKG)
	}
	var seed [16]byte
	if _, err := f.ReadAt(seed[:], int64(p.PFSOffset)+pfsSeedOffset); err != nil {
		return nil, 0, fmt.Errorf("%s: reading the PFS seed: %w", p.path, err)
	}
	c := newXTS(pfsGenCryptoKey(ek, seed))
	off, found, err := p.findPFSC(f, c)
	if err != nil {
		return nil, 0, err
	}
	if !found {
		return nil, 0, fmt.Errorf("%w (no PFSC image after decryption with the fake keys)", ErrRetail)
	}
	return c, off, nil
}

// findPFSC is GetPFSCOffset (pkg.cpp:32-41) without decrypting the whole window: it
// decrypts only the first AES block of each candidate sector. The window is
// 2*pfs_cache_size bytes (pkg.cpp:262), capped at the image size. It returns the offset of
// the PFSC header relative to the PFS image start.
func (p *Package) findPFSC(r io.ReaderAt, c *xtsCipher) (uint64, bool, error) {
	window := min(2*uint64(p.pfsCacheSize), p.PFSSize)
	var blk [aes.BlockSize]byte
	for off := uint64(pfscSearchStart); off+aes.BlockSize <= window; off += pfscSearchStep {
		if _, err := r.ReadAt(blk[:], int64(p.PFSOffset+off)); err != nil {
			return 0, false, fmt.Errorf("%s: reading the PFS image: %w", p.path, err)
		}
		c.decryptSector(off/pfsSectorSize, blk[:])
		if binary.LittleEndian.Uint32(blk[:]) == pfscMagic {
			return off, true, nil
		}
	}
	return 0, false, nil
}

// Signing reports "fake" when the PFS keys unwrap with the public fake keyset and decrypt
// a PFSC image, and "retail" otherwise. Other errors (I/O, a damaged layout) are returned.
func (p *Package) Signing() (string, error) {
	f, err := os.Open(p.path)
	if err != nil {
		return "", err
	}
	defer f.Close()
	_, _, err = p.pfsKeys(f)
	switch {
	case err == nil:
		return "fake", nil
	case errors.Is(err, ErrRetail):
		return "retail", nil
	}
	return "", err
}
