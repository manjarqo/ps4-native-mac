// SPDX-License-Identifier: GPL-2.0-or-later

package cli

import (
	"errors"
	"flag"
	"fmt"
	"io"
	"io/fs"
	"os"
	"os/signal"
	"path/filepath"
	"runtime"
	"slices"
	"syscall"

	"ps4-recomp/pkg/compat"
	"ps4-recomp/pkg/events"
	"ps4-recomp/pkg/fpkg"
	"ps4-recomp/pkg/library"
	"ps4-recomp/pkg/sfo"
)

// iconEntryID is the PKG entry that holds sce_sys/icon0.png.
const iconEntryID = 0x1200

// engineCommands are the subcommands of the game-manager engine; Execute routes them before
// the build path.
var engineCommands = map[string]func(args []string) error{
	"inspect":      runInspect,
	"import":       runImport,
	"analyze-game": runAnalyzeGame,
	"version":      runVersion,
}

// engineFlags parses args for one engine subcommand. Flags may appear before or after the
// positional arguments. It returns the positionals and a writer that emits JSON lines with
// --json and plain text otherwise. A parse failure is reported as one bad_input error event.
func engineFlags(op string, args []string, setup func(fs *flag.FlagSet)) (pos []string, ev *events.Writer, asJSON bool, err error) {
	asJSON = slices.Contains(args, "-json") || slices.Contains(args, "--json")
	ev = events.New(stdout, op, asJSON)
	fset := flag.NewFlagSet(op, flag.ContinueOnError)
	fset.SetOutput(io.Discard)
	fset.BoolVar(&asJSON, "json", asJSON, "emit JSON events on stdout")
	if setup != nil {
		setup(fset)
	}
	rest := args
	for {
		if err = fset.Parse(rest); err != nil {
			return nil, ev, asJSON, ev.Error("bad_input", op+": "+err.Error())
		}
		if fset.NArg() == 0 {
			return pos, ev, asJSON, nil
		}
		pos = append(pos, fset.Arg(0))
		rest = fset.Args()[1:]
	}
}

// inspectResult is the done result of inspect.
type inspectResult struct {
	Kind         string `json:"kind"`
	Signing      string `json:"signing"`
	TitleID      string `json:"title_id"`
	ContentID    string `json:"content_id"`
	Title        string `json:"title"`
	AppVer       string `json:"app_ver"`
	Version      string `json:"version"`
	Category     string `json:"category"`
	IconPath     string `json:"icon_path"`
	PackedSize   int64  `json:"packed_size"`
	UnpackedSize int64  `json:"unpacked_size"`
}

func runInspect(args []string) error {
	pos, ev, asJSON, err := engineFlags("inspect", args, nil)
	if err != nil {
		return err
	}
	if len(pos) != 1 {
		return ev.Error("bad_input", "usage: ps4-recomp inspect <pkg|folder> [--json]")
	}
	st, err := os.Stat(pos[0])
	if err != nil {
		return ev.Error("bad_input", err.Error())
	}
	var res *inspectResult
	if st.IsDir() {
		res, err = inspectFolder(pos[0])
	} else {
		res, err = inspectPKG(pos[0], st.Size())
	}
	if err != nil {
		return ev.Error(errCode(err, "bad_pkg"), err.Error())
	}
	if !asJSON {
		fmt.Fprintf(stdout, "%s %s (%s) %q app_ver=%s signing=%s packed=%d unpacked=%d\n",
			res.Kind, res.TitleID, res.ContentID, res.Title, res.AppVer, res.Signing, res.PackedSize, res.UnpackedSize)
	}
	ev.Done(res)
	return nil
}

// versionResult is the done result of version.
type versionResult struct {
	Version string `json:"version"`
	Go      string `json:"go"`
}

func runVersion(args []string) error {
	pos, ev, asJSON, err := engineFlags("version", args, nil)
	if err != nil {
		return err
	}
	if len(pos) != 0 {
		return ev.Error("bad_input", "usage: ps4-recomp version [--json]")
	}
	if !asJSON {
		fmt.Fprintf(stdout, "ps4-recomp %s\n", Version)
		return nil
	}
	ev.Done(versionResult{Version: Version, Go: runtime.Version()})
	return nil
}

// codedError carries an events code through a plain error return.
type codedError struct {
	code string
	err  error
}

func (e *codedError) Error() string { return e.err.Error() }
func (e *codedError) Unwrap() error { return e.err }

func errCode(err error, def string) string {
	var c *codedError
	if errors.As(err, &c) {
		return c.code
	}
	return def
}

func sfoIdentity(res *inspectResult, s *sfo.File) {
	res.TitleID, _ = s.String("TITLE_ID")
	res.ContentID, _ = s.String("CONTENT_ID")
	res.Title, _ = s.String("TITLE")
	res.Category, _ = s.String("CATEGORY")
	res.Version, _ = s.String("VERSION")
	if res.AppVer, _ = s.String("APP_VER"); res.AppVer == "" {
		res.AppVer = res.Version
	}
}

func inspectPKG(path string, size int64) (*inspectResult, error) {
	p, err := fpkg.Open(path)
	if err != nil {
		return nil, err
	}
	kind, err := p.Kind()
	if err != nil {
		return nil, err
	}
	s, err := p.SFO()
	if err != nil {
		return nil, err
	}
	signing, err := p.Signing()
	if err != nil {
		return nil, err
	}
	res := &inspectResult{Kind: string(kind), Signing: signing, PackedSize: size}
	sfoIdentity(res, s)
	if res.ContentID == "" {
		res.ContentID = p.ContentID
	}
	// A retail PFS cannot be decrypted, so its unpacked size is unknown.
	if signing == "fake" {
		if res.UnpackedSize, err = p.UnpackedSize(); err != nil {
			return nil, err
		}
	}
	if icon, err := p.ReadEntry(iconEntryID); err == nil {
		res.IconPath = writeIcon(res, icon)
	}
	return res, nil
}

func inspectFolder(dir string) (*inspectResult, error) {
	s, err := sfo.Load(filepath.Join(dir, "sce_sys", "param.sfo"))
	if err != nil {
		code := "bad_pkg"
		if errors.Is(err, fs.ErrNotExist) {
			code = "bad_input"
		}
		return nil, &codedError{code, err}
	}
	res := &inspectResult{Kind: "folder", Signing: "none"}
	sfoIdentity(res, s)
	err = filepath.WalkDir(dir, func(_ string, d fs.DirEntry, err error) error {
		if err != nil || !d.Type().IsRegular() {
			return err
		}
		info, err := d.Info()
		if err == nil {
			res.PackedSize += info.Size()
		}
		return err
	})
	if err != nil {
		return nil, &codedError{"io", err}
	}
	res.UnpackedSize = res.PackedSize
	if icon, err := os.ReadFile(filepath.Join(dir, "sce_sys", "icon0.png")); err == nil {
		res.IconPath = writeIcon(res, icon)
	}
	return res, nil
}

// writeIcon stores the icon in the temp directory and returns its path, or "" on failure
// (a missing icon is not an inspect error).
func writeIcon(res *inspectResult, data []byte) string {
	id := res.ContentID
	if id == "" {
		id = res.TitleID
	}
	name := []byte(id)
	for i, c := range name {
		if !(c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' || c >= '0' && c <= '9' || c == '-' || c == '_') {
			name[i] = '_'
		}
	}
	if len(name) == 0 {
		name = []byte("unknown")
	}
	path := filepath.Join(os.TempDir(), "ps4native-icon-"+string(name)+".png")
	tmp, err := os.CreateTemp(os.TempDir(), "ps4native-icon-*.tmp")
	if err != nil {
		return ""
	}
	_, werr := tmp.Write(data)
	cerr := tmp.Close()
	if werr != nil || cerr != nil || os.Rename(tmp.Name(), path) != nil {
		os.Remove(tmp.Name())
		return ""
	}
	return path
}

func runImport(args []string) error {
	var libDir, mode string
	pos, ev, asJSON, err := engineFlags("import", args, func(f *flag.FlagSet) {
		f.StringVar(&libDir, "library", "", "library directory")
		f.StringVar(&mode, "mode", "copy", "copy or reference")
	})
	if err != nil {
		return err
	}
	if len(pos) != 1 || libDir == "" {
		return ev.Error("bad_input", "usage: ps4-recomp import <pkg|folder> --library <dir> [--mode copy|reference] [--json]")
	}

	cancel := make(chan struct{})
	sigs := make(chan os.Signal, 1)
	signal.Notify(sigs, os.Interrupt, syscall.SIGTERM)
	stopped := make(chan struct{})
	go func() {
		select {
		case <-sigs:
			close(cancel)
		case <-stopped:
		}
	}()
	defer func() {
		signal.Stop(sigs)
		close(stopped)
	}()

	// Import reports its own failures on ev.
	r, err := library.Library{Root: libDir}.Import(pos[0], mode, ev, cancel)
	if err != nil {
		return err
	}
	if !asJSON {
		fmt.Fprintf(stdout, "imported %s %s (pending=%v)\n", r.Kind, r.TitleID, r.Pending)
	}
	ev.Done(r)
	return nil
}

type verdictJSON struct {
	Status         string         `json:"status"`
	Name           string         `json:"name"`
	TestedVersions []string       `json:"tested_versions"`
	Recommended    map[string]int `json:"recommended"`
	KnownIssues    []string       `json:"known_issues"`
}

type analysisJSON struct {
	TitleID    string      `json:"title_id"`
	Title      string      `json:"title"`
	AppVer     string      `json:"app_ver"`
	Category   string      `json:"category"`
	Verdict    verdictJSON `json:"verdict"`
	Coverage   float64     `json:"coverage"`
	Unresolved int         `json:"unresolved"`
	MissingOps int         `json:"missing_ops"`
	Modules    []string    `json:"modules"`
}

func runAnalyzeGame(args []string) error {
	pos, ev, asJSON, err := engineFlags("analyze-game", args, nil)
	if err != nil {
		return err
	}
	if len(pos) != 1 {
		return ev.Error("bad_input", "usage: ps4-recomp analyze-game <content dir> [--json]")
	}
	if st, err := os.Stat(pos[0]); err != nil || !st.IsDir() {
		return ev.Error("bad_input", pos[0]+" is not a directory")
	}
	ev.Progress("analyze", 0, 1, "stages", "analysing eboot.bin")
	a, err := compat.AnalyzeGame(pos[0])
	if err != nil {
		code := "io"
		if errors.Is(err, fs.ErrNotExist) {
			code = "bad_input"
		}
		return ev.Error(code, err.Error())
	}
	res := analysisJSON{
		TitleID: a.TitleID, Title: a.Title, AppVer: a.AppVer, Category: a.Category,
		Verdict: verdictJSON{
			Status: a.Verdict.Status, Name: a.Verdict.Name, TestedVersions: a.Verdict.TestedVersions,
			Recommended: a.Verdict.Recommended, KnownIssues: a.Verdict.KnownIssues,
		},
		Coverage: a.Coverage, Unresolved: a.Unresolved, MissingOps: a.MissingOps, Modules: a.Modules,
	}
	if !asJSON {
		fmt.Fprintf(stdout, "%s %q app_ver=%s status=%s coverage=%.1f%% unresolved=%d missing_ops=%d\n",
			res.TitleID, res.Title, res.AppVer, res.Verdict.Status, res.Coverage, res.Unresolved, res.MissingOps)
	}
	ev.Done(res)
	return nil
}
