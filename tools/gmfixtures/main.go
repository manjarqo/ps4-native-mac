// SPDX-License-Identifier: GPL-2.0-or-later

// Command gmfixtures writes the synthetic inputs the PS4 Native app's engine fixtures are
// recorded from: a dumped content folder and fake-signed game, patch, DLC and retail PKGs.
//
// usage: gmfixtures <output dir> [hello_world.elf]
//
// The output dir receives content/ (eboot.bin and sce_sys/param.sfo), game.pkg, patch.pkg,
// dlc.pkg and retail.pkg. The ELF defaults to hello_world.elf in the current directory.
package main

import (
	"fmt"
	"os"
	"path/filepath"

	"ps4-recomp/pkg/fpkg/fpkgtest"
	"ps4-recomp/pkg/sfo"
)

const titleID = "CUSA00557"

func params(category, appVer, contentID string) []sfo.Entry {
	return []sfo.Entry{
		{Key: "APP_VER", Str: appVer},
		{Key: "CATEGORY", Str: category},
		{Key: "CONTENT_ID", Str: contentID},
		{Key: "TITLE", Str: "Test Game"},
		{Key: "TITLE_ID", Str: titleID},
		{Key: "VERSION", Str: appVer},
	}
}

// writePKG builds a PKG in a scratch directory under out and moves it to out/name.
func writePKG(out, name string, entries []sfo.Entry, files map[string][]byte, opts fpkgtest.Opts) error {
	tmp, err := os.MkdirTemp(out, ".pkg-")
	if err != nil {
		return err
	}
	defer os.RemoveAll(tmp)
	p, err := fpkgtest.BuildTestPKG(tmp, entries, files, opts)
	if err != nil {
		return fmt.Errorf("%s: %w", name, err)
	}
	return os.Rename(p, filepath.Join(out, name))
}

func run(out, elfPath string) error {
	elf, err := os.ReadFile(elfPath)
	if err != nil {
		return err
	}
	if err := os.MkdirAll(filepath.Join(out, "content", "sce_sys"), 0o755); err != nil {
		return err
	}
	game := params("gd", "01.00", "UP9000-"+titleID+"_00-TESTGAME00000000")
	if err := os.WriteFile(filepath.Join(out, "content", "eboot.bin"), elf, 0o755); err != nil {
		return err
	}
	if err := os.WriteFile(filepath.Join(out, "content", "sce_sys", "param.sfo"), sfo.Build(game), 0o644); err != nil {
		return err
	}
	gameFiles := map[string][]byte{"eboot.bin": elf}
	if err := writePKG(out, "game.pkg", game, gameFiles, fpkgtest.Opts{}); err != nil {
		return err
	}
	patch := params("gp", "01.05", "UP9000-"+titleID+"_00-TESTGAME00000000")
	if err := writePKG(out, "patch.pkg", patch, gameFiles, fpkgtest.Opts{}); err != nil {
		return err
	}
	dlc := params("ac", "01.00", "UP9000-"+titleID+"_00-TESTDLC000000000")
	if err := writePKG(out, "dlc.pkg", dlc, map[string][]byte{"dlc.dat": []byte("test DLC data\n")}, fpkgtest.Opts{}); err != nil {
		return err
	}
	return writePKG(out, "retail.pkg", game, gameFiles, fpkgtest.Opts{Retail: true})
}

func main() {
	if len(os.Args) < 2 || len(os.Args) > 3 {
		fmt.Fprintln(os.Stderr, "usage: gmfixtures <output dir> [hello_world.elf]")
		os.Exit(2)
	}
	elf := "hello_world.elf"
	if len(os.Args) == 3 {
		elf = os.Args[2]
	}
	if err := run(os.Args[1], elf); err != nil {
		fmt.Fprintln(os.Stderr, "gmfixtures:", err)
		os.Exit(1)
	}
}
