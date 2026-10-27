// SPDX-License-Identifier: GPL-2.0-or-later

// Package fpkgtest builds small PKG files for tests through fpkg.Write.
package fpkgtest

import (
	"bytes"
	"crypto/rand"
	"crypto/rsa"
	"image"
	"image/png"
	"os"
	"path/filepath"

	"ps4-recomp/pkg/fpkg"
	"ps4-recomp/pkg/sfo"
)

// Opts selects the kind of test package.
type Opts struct {
	Retail bool              // wrap the EKPFS with a fresh RSA key, so the fake keyset cannot unwrap it
	PFSC   bool              // zlib-compress the PFSC blocks
	Extra  []fpkg.ExtraEntry // more sce_sys entries, such as pic0.png or changeinfo
}

// BuildTestPKG writes <dir>/test.pkg with a param.sfo built from entries, a 1x1 PNG
// icon0, opts.Extra and files in its PFS image, and returns its path. As in real
// packages, param.sfo, icon0 and the extra entries are PKG entries only: they are in the
// PFS image only if files has them too.
func BuildTestPKG(dir string, entries []sfo.Entry, files map[string][]byte, opts Opts) (string, error) {
	var icon bytes.Buffer
	if err := png.Encode(&icon, image.NewRGBA(image.Rect(0, 0, 1, 1))); err != nil {
		return "", err
	}
	spec := fpkg.PackSpec{SFO: sfo.Build(entries), Icon: icon.Bytes(), Files: files, Extra: opts.Extra, PFSC: opts.PFSC}
	if opts.Retail {
		k, err := rsa.GenerateKey(rand.Reader, 2048)
		if err != nil {
			return "", err
		}
		spec.EKPFSKey = &k.PublicKey
	}
	var out bytes.Buffer
	if err := fpkg.Write(&out, spec); err != nil {
		return "", err
	}
	path := filepath.Join(dir, "test.pkg")
	if err := os.WriteFile(path, out.Bytes(), 0o644); err != nil {
		return "", err
	}
	return path, nil
}
