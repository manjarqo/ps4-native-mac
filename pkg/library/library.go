// SPDX-License-Identifier: GPL-2.0-or-later

// Package library keeps the PS4 Native game library: library.json and one directory per
// game, games/<TITLE_ID>/{content,build,logs}, and imports fake-signed PKGs (games,
// patches, DLC) and dumped game folders into it. See docs/game-manager-engine.md.
//
// Every change to a game's files is staged next to the live tree and committed by
// renames: the live tree moves to a ".old" name, the staged tree takes its place,
// library.json is saved (or the renames are undone), and only then is the old tree
// removed. A crash between the two renames is repaired by the next import of that game.
package library

import (
	"bytes"
	"cmp"
	"crypto/sha256"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"maps"
	"os"
	"os/exec"
	"path/filepath"
	"reflect"
	"regexp"
	"slices"
	"strconv"
	"strings"
	"syscall"
	"time"

	"ps4-recomp/pkg/events"
	"ps4-recomp/pkg/fpkg"
	"ps4-recomp/pkg/sfo"
)

const (
	libraryFile    = "library.json"
	lockFile       = ".lock"
	libraryVersion = 1
	// spaceMargin is the free space an import keeps on top of the bytes it writes.
	spaceMargin = 1 << 30
	// progressStep is how many bytes pass between two progress events.
	progressStep = 32 << 20
	// cloneBatch caps the files passed to one cp invocation.
	cloneBatch = 256
	// lockPoll is how often an import retries a library lock held by another process.
	lockPoll = 100 * time.Millisecond
	// resumeMarker is the file in a resumable scratch directory that names the source it
	// holds. It contains '\\', which no PFS entry name can, and copyTree leaves a source
	// file of that name out, so it never collides with a game file.
	resumeMarker = "\\resume"
)

var (
	// titleIDPattern is a PS4 TITLE_ID: four letters and five digits (CUSA00557).
	titleIDPattern = regexp.MustCompile(`^[A-Z]{4}[0-9]{5}$`)
	// labelPattern is the entitlement label of a CONTENT_ID, its last 16 characters
	// (EP9000-CUSA00557_00-PROMOJOELSKIN001); real labels use [A-Z0-9_].
	labelPattern = regexp.MustCompile(`^[A-Za-z0-9_]{1,16}$`)
)

// Library is a game library rooted at Root.
type Library struct{ Root string }

// GameDir is the directory of one game.
func (l Library) GameDir(titleID string) string { return filepath.Join(l.Root, "games", titleID) }

// ContentDir holds the extracted game with its patches applied and, for a copied game, its DLC
// in addcont/. For a game imported by reference it is a symlink to the user's folder.
func (l Library) ContentDir(titleID string) string {
	return filepath.Join(l.GameDir(titleID), "content")
}

// AddcontDir is the directory that holds the game's DLC, one directory per entitlement label:
// content/addcont for a copied game, games/<TITLE_ID>/addcont for a game imported by reference,
// whose content is the user's folder and is never written to. The runtime scans content/addcont
// on its own; the launcher names games/<TITLE_ID>/addcont to it with PS4_ADDCONT_DIR.
func (l Library) AddcontDir(titleID string) string {
	if isSymlink(l.ContentDir(titleID)) {
		return l.refAddcontDir(titleID)
	}
	return filepath.Join(l.ContentDir(titleID), "addcont")
}

// refAddcontDir is the DLC directory of a game imported by reference, games/<TITLE_ID>/addcont.
func (l Library) refAddcontDir(titleID string) string {
	return filepath.Join(l.GameDir(titleID), "addcont")
}

// gameBytes is the size of a game's files: its content and, for a referenced game, the DLC
// kept next to it in games/<TITLE_ID>/addcont.
func (l Library) gameBytes(titleID string) (int64, error) {
	content := l.ContentDir(titleID)
	n, err := dirSize(content)
	if err != nil || !isSymlink(content) {
		return n, err
	}
	dlc, err := optionalDirSize(l.refAddcontDir(titleID))
	return n + dlc, err
}

// BuildDir holds the game's build directory and its .app.
func (l Library) BuildDir(titleID string) string { return filepath.Join(l.GameDir(titleID), "build") }

// LogsDir holds the game's build and run logs.
func (l Library) LogsDir(titleID string) string { return filepath.Join(l.GameDir(titleID), "logs") }

// pendingDir holds the files of a patch imported before its base game; pendingDir+".json"
// describes it.
func (l Library) pendingDir(titleID string) string { return filepath.Join(l.Root, "pending", titleID) }

// Game is one entry of library.json.
type Game struct {
	TitleID      string   `json:"title_id"`
	ContentID    string   `json:"content_id"`
	Title        string   `json:"title"`
	AppVer       string   `json:"app_ver"`
	Version      string   `json:"version"`
	Patches      []string `json:"patches"` // APP_VER of each applied patch
	DLC          []string `json:"dlc"`     // entitlement labels under AddcontDir
	ContentBytes int64    `json:"content_bytes"`
	Status       string   `json:"status"` // written by the app from the analyze-game verdict; "" until then
	BuiltWith    string   `json:"built_with"`
	LastPlayed   string   `json:"last_played"`
	PlaySeconds  int64    `json:"play_seconds"`

	// extra holds the fields of this game in library.json that the engine does not know
	// (written by a newer app), so that Save keeps them.
	extra map[string]json.RawMessage
}

// gameFields are the JSON names of Game's fields.
var gameFields = func() map[string]bool {
	m := map[string]bool{}
	t := reflect.TypeFor[Game]()
	for i := range t.NumField() {
		if name, _, _ := strings.Cut(t.Field(i).Tag.Get("json"), ","); name != "" {
			m[name] = true
		}
	}
	return m
}()

// gameJSON is Game without its methods, for the default encoding.
type gameJSON Game

// UnmarshalJSON decodes a game and keeps its unknown fields.
func (g *Game) UnmarshalJSON(b []byte) error {
	if err := json.Unmarshal(b, (*gameJSON)(g)); err != nil {
		return err
	}
	var all map[string]json.RawMessage
	if err := json.Unmarshal(b, &all); err != nil {
		return err
	}
	maps.DeleteFunc(all, func(k string, _ json.RawMessage) bool { return gameFields[k] })
	g.extra = nil
	if len(all) > 0 {
		g.extra = all
	}
	return nil
}

// MarshalJSON encodes a game with the unknown fields it was loaded with.
func (g Game) MarshalJSON() ([]byte, error) {
	b, err := json.Marshal(gameJSON(g))
	if err != nil || len(g.extra) == 0 {
		return b, err
	}
	all := maps.Clone(g.extra)
	if err := json.Unmarshal(b, &all); err != nil {
		return nil, err
	}
	return json.Marshal(all)
}

func (g *Game) clone() *Game {
	c := *g
	c.Patches, c.DLC = slices.Clone(g.Patches), slices.Clone(g.DLC)
	c.extra = maps.Clone(g.extra)
	return &c
}

// libraryJSON is the known part of library.json; Save keeps the other top-level fields.
type libraryJSON struct {
	Version int     `json:"version"`
	Games   []*Game `json:"games"`
}

// read reads and checks library.json: it returns the raw file (nil when there is none)
// and its decoded form. A file written by a newer engine (a higher version) is refused,
// so that it is neither misread nor overwritten.
func (l Library) read() ([]byte, *libraryJSON, error) {
	path := filepath.Join(l.Root, libraryFile)
	b, err := os.ReadFile(path)
	if errors.Is(err, fs.ErrNotExist) {
		return nil, &libraryJSON{}, nil
	}
	if err != nil {
		return nil, nil, err
	}
	var f libraryJSON
	if err := json.Unmarshal(b, &f); err != nil {
		return nil, nil, &fs.PathError{Op: "parse", Path: path, Err: err}
	}
	if f.Version > libraryVersion {
		return nil, nil, &fs.PathError{Op: "read", Path: path, Err: fmt.Errorf(
			"library version %d is newer than this engine supports (%d); update ps4-recomp", f.Version, libraryVersion)}
	}
	return b, &f, nil
}

// Load reads library.json. A library without one is empty. Fields the engine does not
// know are kept in the games and written back by Save. A library.json whose version is
// newer than the engine's is an error.
func (l Library) Load() (map[string]*Game, error) {
	_, f, err := l.read()
	if err != nil {
		return nil, err
	}
	games := map[string]*Game{}
	for _, g := range f.Games {
		if g != nil && g.TitleID != "" {
			games[g.TitleID] = g
		}
	}
	return games, nil
}

// Save writes library.json atomically: a temp file in the same directory, then a rename.
// Games are written sorted by TITLE_ID, with the unknown fields they were loaded with; the
// top-level fields other than version and games are taken from the file being replaced.
// A library.json whose version is newer than the engine's is not overwritten. Save does
// not lock the library; a read-modify-write of library.json goes through Update.
func (l Library) Save(games map[string]*Game) error {
	old, _, err := l.read()
	if err != nil {
		return err
	}
	top := map[string]json.RawMessage{}
	if old != nil {
		if err := json.Unmarshal(old, &top); err != nil {
			return err
		}
	}
	list := make([]*Game, 0, len(games))
	for _, id := range slices.Sorted(maps.Keys(games)) {
		list = append(list, games[id])
	}
	if top["version"], err = json.Marshal(libraryVersion); err != nil {
		return err
	}
	if top["games"], err = json.Marshal(list); err != nil {
		return err
	}
	b, err := json.MarshalIndent(top, "", "  ")
	if err != nil {
		return err
	}
	return writeAtomic(filepath.Join(l.Root, libraryFile), append(b, '\n'))
}

// Update changes library.json under the library lock: it loads the games, calls fn and
// saves the result when fn succeeds. Every writer of library.json in this process must
// use it (the protocol for other processes is in docs/game-manager-engine.md). Update
// blocks until the lock is free, and an Import, in this process or another, holds the
// lock for its whole run, which can take many minutes: do not call Update from a thread
// that must stay responsive.
func (l Library) Update(fn func(games map[string]*Game) error) error {
	unlock, err := l.lock(nil, nil)
	if err != nil {
		return err
	}
	defer unlock()
	return l.update(fn)
}

// update is Update for a caller that already holds the lock.
func (l Library) update(fn func(games map[string]*Game) error) error {
	games, err := l.Load()
	if err != nil {
		return err
	}
	if err := fn(games); err != nil {
		return err
	}
	return l.Save(games)
}

// lock takes an exclusive flock(2) on Root/.lock, creating Root, and returns its release.
// With cancel and waiting nil it blocks until the lock is free. Otherwise it polls with
// LOCK_NB every lockPoll, calls waiting once if the lock is held elsewhere, and gives up
// with a cancelled failure when cancel is closed.
func (l Library) lock(cancel <-chan struct{}, waiting func()) (func(), error) {
	if err := os.MkdirAll(l.Root, 0o755); err != nil {
		return nil, err
	}
	f, err := os.OpenFile(filepath.Join(l.Root, lockFile), os.O_RDWR|os.O_CREATE, 0o644)
	if err != nil {
		return nil, err
	}
	how := syscall.LOCK_EX
	if cancel != nil || waiting != nil {
		how |= syscall.LOCK_NB
	}
	for {
		err := syscall.Flock(int(f.Fd()), how)
		switch {
		case err == nil:
			return func() { f.Close() }, nil
		case errors.Is(err, syscall.EINTR):
			continue
		case how&syscall.LOCK_NB != 0 && errors.Is(err, syscall.EWOULDBLOCK):
			if waiting != nil {
				waiting()
				waiting = nil
			}
			select {
			case <-cancel:
				f.Close()
				return nil, fail("cancelled", "cancelled while waiting for the library lock %s", f.Name())
			case <-time.After(lockPoll):
			}
		default:
			f.Close()
			return nil, &fs.PathError{Op: "flock", Path: f.Name(), Err: err}
		}
	}
}

func writeAtomic(path string, b []byte) error {
	dir := filepath.Dir(path)
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return err
	}
	tmp, err := os.CreateTemp(dir, "."+filepath.Base(path)+"-*.tmp")
	if err != nil {
		return err
	}
	_, err = tmp.Write(b)
	if err == nil {
		err = tmp.Sync()
	}
	if cerr := tmp.Close(); err == nil {
		err = cerr
	}
	if err == nil {
		err = os.Chmod(tmp.Name(), 0o644)
	}
	if err == nil {
		err = os.Rename(tmp.Name(), path)
	}
	if err != nil {
		os.Remove(tmp.Name())
	}
	return err
}

// ImportResult is the outcome of Import. Pending is true for a patch whose base game is
// not in the library yet; it is applied when the base is imported.
type ImportResult struct {
	TitleID string `json:"title_id"`
	Kind    string `json:"kind"` // game, patch or dlc
	Game    *Game  `json:"game,omitempty"`
	Pending bool   `json:"pending"`
}

// Import adds src, a fake-signed PKG or a dumped game folder, to the library. mode is
// "copy" or, for folders only, "reference" (content becomes a symlink to the folder).
// Imports into one library are serialised by its lock. Progress goes to ev with stage
// "extract" (PKG) or "copy" (folder) in bytes. Every failure is reported with ev.Error
// and returned as its *events.CodeError; the live content and library.json are then
// unchanged. Closing cancel stops the import with code "cancelled", also while it waits
// for the library lock (reported once as progress stage "lock"). After a cancel the
// resumable scratch directories are kept, so that the next import of the same source
// resumes them; after any other failure the import's scratch directories are removed. The
// game directory, if this import created it, is removed unless it holds a kept scratch
// directory.
func (l Library) Import(src string, mode string, ev *events.Writer, cancel <-chan struct{}) (*ImportResult, error) {
	im := &importer{lib: l, ev: ev, cancel: cancel}
	defer im.release()
	r, err := im.run(src, mode)
	if err != nil {
		var f *failure
		if !errors.As(err, &f) {
			f = &failure{code: classify(err, "io"), err: err}
		}
		im.cleanup(f.code == "cancelled")
		return nil, ev.Error(f.code, f.err.Error())
	}
	return r, nil
}

// failure is an error with its events code.
type failure struct {
	code string
	err  error
}

func (f *failure) Error() string { return f.err.Error() }
func (f *failure) Unwrap() error { return f.err }

func fail(code, format string, a ...any) error {
	return &failure{code: code, err: fmt.Errorf(format, a...)}
}

// classify maps an error to its events code; def is used for errors that are neither a
// known fpkg sentinel nor a filesystem error.
func classify(err error, def string) string {
	var pe *fs.PathError
	var le *os.LinkError
	switch {
	case errors.Is(err, fpkg.ErrRetail):
		return "retail_pkg"
	case errors.Is(err, fpkg.ErrCancelled):
		return "cancelled"
	case errors.Is(err, fpkg.ErrBadPKG), errors.Is(err, fpkg.ErrUnsupported):
		return "bad_pkg"
	case errors.Is(err, syscall.ENOSPC):
		return "no_space"
	case errors.As(err, &pe), errors.As(err, &le):
		return "io"
	}
	return def
}

// asPKG marks an error from reading a package: format errors become bad_pkg.
func asPKG(err error) error { return &failure{code: classify(err, "bad_pkg"), err: err} }

// overlayHook, when set by a test, runs before each file overlay moves and can fail it.
var overlayHook func(rel string) error

type importer struct {
	lib     Library
	ev      *events.Writer
	cancel  <-chan struct{}
	scratch []scratchPath // removed on failure
	unlock  func()
	// marker identifies the source in the resume marker of each resumable scratch
	// directory: its CONTENT_ID and the PKG's size and mtime, or the folder's path.
	marker string
}

// scratchPath is a path cleanup removes when the import fails.
type scratchPath struct {
	path      string
	resumable bool // a scratch directory a later import can resume: kept after a cancel
	gameDir   bool // the game directory this import created: kept if not empty after a cancel
}

// track registers a path for removal if the import fails.
func (im *importer) track(path string, resumable bool) {
	im.scratch = append(im.scratch, scratchPath{path: path, resumable: resumable})
}

// cleanup removes the scratch paths of a failed import. After a cancel it keeps the
// resumable scratch directories, and removes the game directory it created only if that
// is empty.
func (im *importer) cleanup(cancelled bool) {
	for _, s := range slices.Backward(im.scratch) {
		switch {
		case cancelled && s.resumable:
		case cancelled && s.gameDir:
			os.Remove(s.path)
		default:
			os.RemoveAll(s.path)
		}
	}
}

func (im *importer) release() {
	if im.unlock != nil {
		im.unlock()
	}
}

// lock takes the library lock for the rest of the import. While another process holds it,
// one progress event (stage "lock") says so, and a cancel ends the wait.
func (im *importer) lock() error {
	unlock, err := im.lib.lock(im.cancel, func() {
		im.ev.Progress("lock", 0, 1, "stages", "waiting for library lock")
	})
	if err != nil {
		return err
	}
	im.unlock = unlock
	return nil
}

func (im *importer) cancelled() bool {
	select {
	case <-im.cancel:
		return true
	default:
		return false
	}
}

func (im *importer) warn(format string, a ...any) { im.ev.Warning(fmt.Sprintf(format, a...)) }

func (im *importer) run(src, mode string) (*ImportResult, error) {
	if mode != "copy" && mode != "reference" {
		return nil, fail("bad_input", "unknown import mode %q (want copy or reference)", mode)
	}
	st, err := os.Stat(src)
	if errors.Is(err, fs.ErrNotExist) {
		return nil, fail("bad_input", "%s does not exist", src)
	}
	if err != nil {
		return nil, err
	}
	if st.IsDir() {
		return im.importFolder(src, mode)
	}
	if mode == "reference" {
		return nil, fail("bad_input", "%s: reference mode is for folders; a PKG is always extracted", src)
	}
	return im.importPKG(src)
}

func (im *importer) importPKG(src string) (*ImportResult, error) {
	p, err := fpkg.Open(src)
	if err != nil {
		return nil, asPKG(err)
	}
	// Retail packages are rejected before anything is written.
	signing, err := p.Signing()
	if err != nil {
		return nil, asPKG(err)
	}
	if signing != "fake" {
		return nil, &failure{code: "retail_pkg", err: fpkg.ErrRetail}
	}
	s, err := p.SFO()
	if err != nil {
		return nil, asPKG(err)
	}
	kind, err := p.Kind()
	if err != nil {
		return nil, asPKG(err)
	}
	id, _ := s.String("TITLE_ID")
	if !titleIDPattern.MatchString(id) {
		return nil, fail("bad_pkg", "%s: param.sfo TITLE_ID %q is not a PS4 title id", src, id)
	}
	size, err := p.UnpackedSize()
	if err != nil {
		return nil, asPKG(err)
	}
	st, err := os.Stat(src)
	if err != nil {
		return nil, err
	}
	cid, ok := s.String("CONTENT_ID")
	if !ok {
		cid = p.ContentID
	}
	im.marker = pkgMarker(cid, st)
	if err := im.lock(); err != nil {
		return nil, err
	}
	if err := im.recoverGame(id); err != nil {
		return nil, err
	}
	games, err := im.lib.Load()
	if err != nil {
		return nil, err
	}
	switch kind {
	case fpkg.KindGame:
		return im.installGame(p, s, id, size, games)
	case fpkg.KindPatch:
		return im.installPatch(p, s, id, size, games)
	default:
		return im.installDLC(p, s, id, size, games)
	}
}

// recoverGame repairs an interrupted commit of game id: a ".old" tree whose live tree is
// missing (a crash between the two renames) is moved back; one whose live tree exists
// (a crash after the commit) is removed. A stale content.next is removed too, and so is a
// games/<id>/addcont next to copied content: it is the DLC of a referenced game left by a
// switch to a copy (or a switch to reference that did not commit), whose files the copy
// already holds as hard links.
func (im *importer) recoverGame(id string) error {
	dir := im.lib.GameDir(id)
	content := im.lib.ContentDir(id)
	if err := im.recoverPair(content, content+".old"); err != nil {
		return err
	}
	if err := os.RemoveAll(content + ".next"); err != nil {
		return err
	}
	if isRealDir(content) {
		if err := os.RemoveAll(im.lib.refAddcontDir(id)); err != nil {
			return err
		}
	}
	olds, err := filepath.Glob(filepath.Join(dir, "dlc-*.old"))
	if err != nil {
		return err
	}
	for _, old := range olds {
		label := strings.TrimSuffix(strings.TrimPrefix(filepath.Base(old), "dlc-"), ".old")
		if labelPattern.MatchString(label) {
			if err := im.recoverPair(filepath.Join(im.lib.AddcontDir(id), label), old); err != nil {
				return err
			}
		}
	}
	return nil
}

func (im *importer) recoverPair(live, old string) error {
	if !exists(old) {
		return nil
	}
	if exists(live) {
		return os.RemoveAll(old)
	}
	im.warn("restoring %s after an interrupted import", live)
	return os.Rename(old, live)
}

// completeFile is the resume rule for PKG extraction: Extract writes each file under a
// scratch name and renames it to its final name only when it is complete, so a file
// found under its final name in the scratch directory is whole, and it is the same file
// when its size matches (the resume marker ties the scratch directory to one package:
// same CONTENT_ID, size and mtime). Such a file is skipped; anything else is written
// again.
func completeFile(dir string) func(rel string, size int64) bool {
	return func(rel string, size int64) bool {
		fi, err := os.Lstat(filepath.Join(dir, filepath.FromSlash(rel)))
		return err == nil && fi.Mode().IsRegular() && fi.Size() == size
	}
}

// scratchDir registers path as a scratch directory of this import. A symlink or other
// non-directory there is removed (never followed). A resumable directory is kept only
// when its resume marker equals im.marker, that is when an earlier run of the same
// source left it; otherwise it is removed, recreated and given the marker. A directory
// that is not resumable is always removed.
func (im *importer) scratchDir(path string, resumable bool) error {
	im.track(path, resumable)
	fi, err := os.Lstat(path)
	switch {
	case errors.Is(err, fs.ErrNotExist):
	case err != nil:
		return err
	case resumable && fi.IsDir() && readMarker(path) == im.marker:
		return nil
	default:
		if err := os.RemoveAll(path); err != nil {
			return err
		}
	}
	if !resumable {
		return nil
	}
	if err := os.MkdirAll(path, 0o755); err != nil {
		return err
	}
	return writeAtomic(filepath.Join(path, resumeMarker), []byte(im.marker))
}

// pkgMarker is the resume marker of a scratch directory filled from the package with
// CONTENT_ID contentID and file info st.
func pkgMarker(contentID string, st fs.FileInfo) string {
	return fmt.Sprintf("pkg %s size=%d mtime=%d\n", contentID, st.Size(), st.ModTime().UnixNano())
}

// readMarker returns the resume marker of the scratch directory dir, or "" without one.
func readMarker(dir string) string {
	b, err := os.ReadFile(filepath.Join(dir, resumeMarker))
	if err != nil {
		return ""
	}
	return string(b)
}

// dropMarker removes the resume marker of dir before dir is committed.
func dropMarker(dir string) error {
	if err := os.Remove(filepath.Join(dir, resumeMarker)); err != nil && !errors.Is(err, fs.ErrNotExist) {
		return err
	}
	return nil
}

// extract unpacks p into the scratch directory dst, resuming a previous run of the same
// package.
func (im *importer) extract(p *fpkg.Package, dst string) error {
	if err := im.scratchDir(dst, true); err != nil {
		return err
	}
	if err := p.Extract(dst, completeFile(dst), im.progress("extract"), im.cancel); err != nil {
		return &failure{code: classify(err, "io"), err: err}
	}
	return pruneExtra(p, dst)
}

// pruneExtra removes the files and directories in dst that p does not contain, such as
// the scratch files of an interrupted run or DLC linked in before a crash; the resume
// marker stays.
func pruneExtra(p *fpkg.Package, dst string) error {
	files, err := p.Files()
	if err != nil {
		return asPKG(err)
	}
	keep := make(map[string]bool, len(files)+1)
	for _, f := range files {
		keep[filepath.FromSlash(f.Path)] = true
	}
	keep[resumeMarker] = true
	return prune(dst, keep)
}

// progress returns a progress callback that emits at most one event per progressStep.
func (im *importer) progress(stage string) fpkg.ProgressFunc {
	last := int64(-1)
	return func(done, total int64, file string) {
		if done == last || (last >= 0 && done != total && done-last < progressStep) {
			return
		}
		last = done
		im.ev.Progress(stage, done, total, "bytes", file)
	}
}

// prepareGameDir creates games/<id>; a directory this import creates is removed on failure.
func (im *importer) prepareGameDir(id string) error {
	dir := im.lib.GameDir(id)
	if !exists(dir) {
		im.scratch = append(im.scratch, scratchPath{path: dir, gameDir: true})
	}
	return os.MkdirAll(dir, 0o755)
}

// checkSpace fails with no_space when the library volume has less than need bytes free.
func (im *importer) checkSpace(need int64) error {
	if err := os.MkdirAll(im.lib.Root, 0o755); err != nil {
		return err
	}
	var st syscall.Statfs_t
	if err := syscall.Statfs(im.lib.Root, &st); err != nil {
		return &fs.PathError{Op: "statfs", Path: im.lib.Root, Err: err}
	}
	if free := int64(st.Bavail) * int64(st.Bsize); free < need {
		return fail("no_space", "%s needs %d bytes free, %d available", im.lib.Root, need, free)
	}
	return nil
}

func exists(path string) bool {
	_, err := os.Lstat(path)
	return err == nil
}

func isSymlink(path string) bool {
	fi, err := os.Lstat(path)
	return err == nil && fi.Mode()&fs.ModeSymlink != 0
}

func isRealDir(path string) bool {
	fi, err := os.Lstat(path)
	return err == nil && fi.IsDir()
}

// commit replaces the live tree with the staged tree next and records g in library.json:
// live moves to old, next takes its place, and the library is saved. When saving fails,
// both renames are undone. old is removed only after the save.
func (im *importer) commit(live, next, old string, g *Game) error {
	if err := os.RemoveAll(old); err != nil {
		return err
	}
	hadLive := exists(live)
	if hadLive {
		if err := os.Rename(live, old); err != nil {
			return err
		}
	}
	if err := os.Rename(next, live); err != nil {
		if hadLive {
			os.Rename(old, live)
		}
		return err
	}
	err := im.lib.update(func(games map[string]*Game) error {
		games[g.TitleID] = g
		return nil
	})
	if err != nil {
		if rerr := os.Rename(live, next); rerr == nil && hadLive {
			os.Rename(old, live)
		}
		return err
	}
	// os.RemoveAll removes a symlink itself, never what it points to.
	if err := os.RemoveAll(old); err != nil {
		im.warn("could not remove the replaced %s: %v", old, err)
	}
	return nil
}

// newGame builds the record of a freshly installed base game, keeping the play history
// of an earlier install.
func newGame(s *sfo.File, id string, prev *Game) *Game {
	g := &Game{TitleID: id, Patches: []string{}, DLC: []string{}}
	g.ContentID, _ = s.String("CONTENT_ID")
	g.Title, _ = s.String("TITLE")
	g.Version, _ = s.String("VERSION")
	g.AppVer = appVer(s)
	if prev != nil {
		g.BuiltWith, g.LastPlayed, g.PlaySeconds = prev.BuiltWith, prev.LastPlayed, prev.PlaySeconds
		g.extra = maps.Clone(prev.extra)
	}
	return g
}

// compareVersions compares two app versions such as "01.09" and "01.32" field by field
// as numbers. ok is false when either is not dot-separated decimal fields.
func compareVersions(a, b string) (c int, ok bool) {
	fa, fb := strings.Split(a, "."), strings.Split(b, ".")
	for i := range max(len(fa), len(fb)) {
		x, y := 0, 0
		var err error
		if i < len(fa) {
			if x, err = strconv.Atoi(fa[i]); err != nil || x < 0 {
				return 0, false
			}
		}
		if i < len(fb) {
			if y, err = strconv.Atoi(fb[i]); err != nil || y < 0 {
				return 0, false
			}
		}
		if x != y {
			return cmp.Compare(x, y), true
		}
	}
	return 0, true
}

// older reports whether app version v is older than w. Versions that do not parse are
// never older.
func older(v, w string) bool {
	c, ok := compareVersions(v, w)
	return ok && c < 0
}

// appVer is APP_VER, or VERSION when param.sfo has no APP_VER or an empty one (as in many
// dumps).
func appVer(s *sfo.File) string {
	if v, ok := s.String("APP_VER"); ok && v != "" {
		return v
	}
	v, _ := s.String("VERSION")
	return v
}

func addUnique(list []string, v string) []string {
	if slices.Contains(list, v) {
		return list
	}
	return append(list, v)
}

func (im *importer) installGame(p *fpkg.Package, s *sfo.File, id string, size int64, games map[string]*Game) (*ImportResult, error) {
	if err := im.checkSpace(size + spaceMargin); err != nil {
		return nil, err
	}
	if err := im.prepareGameDir(id); err != nil {
		return nil, err
	}
	partial := im.lib.ContentDir(id) + ".partial"
	if err := im.extract(p, partial); err != nil {
		return nil, err
	}
	return im.finishCopy(s, id, partial, games)
}

// finishCopy completes a staged copy of a base game: it carries the installed DLC over,
// applies a pending patch, and commits the staged tree as content. The DLC and the
// pending patch are hard-linked into the staged tree, so they stay intact until the
// commit. The DLC carried over is decided by the live game and its record alone: a
// resumed staged tree (from which the extraction pruned earlier links) is relinked. The DLC
// of a game that was referenced comes from games/<id>/addcont, which is removed after the
// commit (or by the next recoverGame).
func (im *importer) finishCopy(s *sfo.File, id, partial string, games map[string]*Game) (*ImportResult, error) {
	if err := dropMarker(partial); err != nil {
		return nil, err
	}
	prev := games[id]
	g := newGame(s, id, prev)
	content := im.lib.ContentDir(id)
	addcont := im.lib.AddcontDir(id)
	wasRef := isSymlink(content)
	if prev != nil && isRealDir(addcont) {
		if err := linkTree(addcont, filepath.Join(partial, "addcont")); err != nil {
			return nil, err
		}
		g.DLC = slices.Clone(prev.DLC)
	}
	applied, err := im.stagePending(id, partial, g)
	if err != nil {
		return nil, err
	}
	if g.ContentBytes, err = dirSize(partial); err != nil {
		return nil, err
	}
	if err := im.commit(content, partial, content+".old", g); err != nil {
		return nil, err
	}
	if wasRef {
		if err := os.RemoveAll(addcont); err != nil {
			im.warn("could not remove the DLC directory %s of the referenced game: %v", addcont, err)
		}
	}
	if applied {
		im.dropPending(id)
	}
	return &ImportResult{TitleID: id, Kind: "game", Game: g}, nil
}

// linkTree hard-links every file of src to the same path under dst, replacing what is
// there, and copies the bytes when a link cannot be made.
func linkTree(src, dst string) error {
	return filepath.WalkDir(src, func(path string, d fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		rel, err := filepath.Rel(src, path)
		if err != nil {
			return err
		}
		target := filepath.Join(dst, rel)
		switch {
		case d.IsDir():
			return os.MkdirAll(target, 0o755)
		case !d.Type().IsRegular():
			return fmt.Errorf("%s: not a regular file", path)
		}
		if err := os.Remove(target); err != nil && !errors.Is(err, fs.ErrNotExist) {
			return err
		}
		if os.Link(path, target) == nil {
			return nil
		}
		return copyPlain(path, target)
	})
}

func copyPlain(from, to string) error {
	in, err := os.Open(from)
	if err != nil {
		return err
	}
	defer in.Close()
	fi, err := in.Stat()
	if err != nil {
		return err
	}
	out, err := os.OpenFile(to, os.O_WRONLY|os.O_CREATE|os.O_TRUNC, fi.Mode().Perm())
	if err != nil {
		return err
	}
	defer out.Close()
	if _, err := io.Copy(out, in); err != nil {
		return err
	}
	return out.Close()
}

// pendingPatch describes a patch stored under pending/ until its base game arrives.
type pendingPatch struct {
	AppVer string `json:"app_ver"`
}

// readPending returns the pending patch of id, if there is a complete one.
func (im *importer) readPending(id string) (*pendingPatch, error) {
	dir := im.lib.pendingDir(id)
	b, err := os.ReadFile(dir + ".json")
	if errors.Is(err, fs.ErrNotExist) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	var pp pendingPatch
	if err := json.Unmarshal(b, &pp); err != nil || !isRealDir(dir) {
		im.warn("ignoring the damaged pending patch of %s", id)
		return nil, nil
	}
	return &pp, nil
}

// stagePending links the pending patch of id over the staged tree dst and records it in
// g. It reports whether there was one.
func (im *importer) stagePending(id, dst string, g *Game) (bool, error) {
	pp, err := im.readPending(id)
	if err != nil || pp == nil {
		return false, err
	}
	if older(pp.AppVer, g.AppVer) {
		im.warn("the pending patch %s of %s is older than the game (%s); it is kept and not applied", pp.AppVer, id, g.AppVer)
		return false, nil
	}
	if err := linkTree(im.lib.pendingDir(id), dst); err != nil {
		return false, err
	}
	g.Patches = addUnique(g.Patches, pp.AppVer)
	g.AppVer = pp.AppVer
	return true, nil
}

// dropPending removes an applied pending patch; failures only warn, as the patch is
// already committed.
func (im *importer) dropPending(id string) {
	dir := im.lib.pendingDir(id)
	if err := os.Remove(dir + ".json"); err != nil && !errors.Is(err, fs.ErrNotExist) {
		im.warn("could not remove the applied pending patch of %s: %v", id, err)
	}
	if err := os.RemoveAll(dir); err != nil {
		im.warn("could not remove the applied pending patch of %s: %v", id, err)
	}
}

// installPatch stages the patched game as a clone of content with the patch files moved
// over it, then commits it; content is untouched until the commit.
func (im *importer) installPatch(p *fpkg.Package, s *sfo.File, id string, size int64, games map[string]*Game) (*ImportResult, error) {
	g := games[id]
	content := im.lib.ContentDir(id)
	if g == nil || !exists(content) {
		return im.storePending(p, s, id, size)
	}
	if isSymlink(content) {
		return nil, fail("bad_input", "%s is used in place (imported by reference) and its folder is never modified, so an update cannot be applied to it; import the folder again as a copy to apply updates", id)
	}
	v := appVer(s)
	if older(v, g.AppVer) {
		return nil, fail("bad_input", "%s: patch %s is older than the installed version %s; patches are cumulative, so apply the newest one", id, v, g.AppVer)
	}
	dir := im.lib.GameDir(id)
	contentBytes, err := dirSize(content)
	if err != nil {
		return nil, err
	}
	clone := canClone(content, dir)
	need := size + spaceMargin
	if !clone {
		need += contentBytes
	}
	if err := im.checkSpace(need); err != nil {
		return nil, err
	}
	patch := filepath.Join(dir, "patch.partial")
	if err := im.extract(p, patch); err != nil {
		return nil, err
	}
	next := content + ".next"
	if err := im.scratchDir(next, false); err != nil {
		return nil, err
	}
	if err := im.copyTree(content, next, contentBytes, clone); err != nil {
		return nil, err
	}
	if err := dropMarker(patch); err != nil {
		return nil, err
	}
	if err := overlay(patch, next); err != nil {
		return nil, err
	}
	ng := g.clone()
	ng.Patches = addUnique(ng.Patches, v)
	ng.AppVer, ng.Status = v, ""
	if ng.ContentBytes, err = dirSize(next); err != nil {
		return nil, err
	}
	if err := im.commit(content, next, content+".old", ng); err != nil {
		return nil, err
	}
	if err := os.RemoveAll(patch); err != nil {
		im.warn("could not remove %s: %v", patch, err)
	}
	return &ImportResult{TitleID: id, Kind: "patch", Game: ng}, nil
}

// storePending extracts a patch whose base game is missing into pending/<id>, replacing
// an earlier pending patch that is not newer (PS4 patches are cumulative).
func (im *importer) storePending(p *fpkg.Package, s *sfo.File, id string, size int64) (*ImportResult, error) {
	v := appVer(s)
	if pp, err := im.readPending(id); err != nil {
		return nil, err
	} else if pp != nil && older(v, pp.AppVer) {
		return nil, fail("bad_input", "%s: patch %s is older than the pending patch %s; patches are cumulative, so the newer one is kept", id, v, pp.AppVer)
	}
	if err := im.checkSpace(size + spaceMargin); err != nil {
		return nil, err
	}
	dir := im.lib.pendingDir(id)
	partial := dir + ".partial"
	if err := im.extract(p, partial); err != nil {
		return nil, err
	}
	if err := dropMarker(partial); err != nil {
		return nil, err
	}
	// pending/<id> without its description is incomplete and ignored, so the
	// description goes first and comes back last.
	if err := os.Remove(dir + ".json"); err != nil && !errors.Is(err, fs.ErrNotExist) {
		return nil, err
	}
	if err := os.RemoveAll(dir); err != nil {
		return nil, err
	}
	if err := os.Rename(partial, dir); err != nil {
		return nil, err
	}
	b, err := json.Marshal(pendingPatch{AppVer: v})
	if err != nil {
		return nil, err
	}
	if err := writeAtomic(dir+".json", b); err != nil {
		return nil, err
	}
	im.warn("%s is not in the library; the patch is kept and applied when the game is imported", id)
	return &ImportResult{TitleID: id, Kind: "patch", Pending: true}, nil
}

// overlay moves every file of src over the same path under dst, replacing what is there.
func overlay(src, dst string) error {
	return filepath.WalkDir(src, func(path string, d fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		rel, err := filepath.Rel(src, path)
		if err != nil {
			return err
		}
		target := filepath.Join(dst, rel)
		if d.IsDir() {
			return os.MkdirAll(target, 0o755)
		}
		if overlayHook != nil {
			if err := overlayHook(rel); err != nil {
				return err
			}
		}
		return os.Rename(path, target)
	})
}

// entitlement is the last '-' field of a CONTENT_ID: UP9000-CUSA00557_00-LABEL → LABEL.
func entitlement(contentID string) string {
	return contentID[strings.LastIndexByte(contentID, '-')+1:]
}

// installDLC stages the DLC in games/<id>/dlc-<label>.partial and commits it as
// <AddcontDir>/<label>: content/addcont/<label> for a copied game, games/<id>/addcont/<label>
// for a referenced one (whose folder is never written to).
func (im *importer) installDLC(p *fpkg.Package, s *sfo.File, id string, size int64, games map[string]*Game) (*ImportResult, error) {
	cid, ok := s.String("CONTENT_ID")
	if !ok {
		cid = p.ContentID
	}
	label := entitlement(cid)
	if !labelPattern.MatchString(label) {
		return nil, fail("bad_pkg", "DLC CONTENT_ID %q has no valid entitlement label", cid)
	}
	g := games[id]
	content := im.lib.ContentDir(id)
	if g == nil || !exists(content) {
		return nil, fail("bad_input", "%s is not in the library; import the game before its DLC", id)
	}
	if err := im.checkSpace(size + spaceMargin); err != nil {
		return nil, err
	}
	dir := im.lib.GameDir(id)
	partial := filepath.Join(dir, "dlc-"+label+".partial")
	if err := im.extract(p, partial); err != nil {
		return nil, err
	}
	if err := dropMarker(partial); err != nil {
		return nil, err
	}
	live := filepath.Join(im.lib.AddcontDir(id), label)
	ng := g.clone()
	ng.DLC = addUnique(ng.DLC, label)
	total, err := im.lib.gameBytes(id)
	if err != nil {
		return nil, err
	}
	var replaced int64
	if exists(live) {
		if replaced, err = dirSize(live); err != nil {
			return nil, err
		}
	}
	added, err := dirSize(partial)
	if err != nil {
		return nil, err
	}
	ng.ContentBytes = total - replaced + added
	if err := os.MkdirAll(filepath.Dir(live), 0o755); err != nil {
		return nil, err
	}
	if err := im.commit(live, partial, filepath.Join(dir, "dlc-"+label+".old"), ng); err != nil {
		return nil, err
	}
	return &ImportResult{TitleID: id, Kind: "dlc", Game: ng}, nil
}

// skipName reports macOS metadata files that are not part of a game: AppleDouble "._*"
// files and Finder's .DS_Store.
func skipName(name string) bool { return strings.HasPrefix(name, "._") || name == ".DS_Store" }

// dirSize sums the regular files under dir, without the files skipName drops.
func dirSize(dir string) (int64, error) {
	root, err := filepath.EvalSymlinks(dir)
	if err != nil {
		return 0, err
	}
	var n int64
	err = filepath.WalkDir(root, func(path string, d fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		if d.Type().IsRegular() && !skipName(d.Name()) {
			fi, err := d.Info()
			if err != nil {
				return err
			}
			n += fi.Size()
		}
		return nil
	})
	return n, err
}

// optionalDirSize is dirSize of a directory that may be missing (0 then).
func optionalDirSize(dir string) (int64, error) {
	if !exists(dir) {
		return 0, nil
	}
	return dirSize(dir)
}

// within reports whether path is dir or lies under it; both are resolved paths.
func within(path, dir string) bool {
	rel, err := filepath.Rel(dir, path)
	return err == nil && rel != ".." && !strings.HasPrefix(rel, ".."+string(filepath.Separator))
}

func (im *importer) importFolder(src, mode string) (*ImportResult, error) {
	dir, err := filepath.EvalSymlinks(src)
	if err != nil {
		return nil, err
	}
	if dir, err = filepath.Abs(dir); err != nil {
		return nil, err
	}
	for _, f := range []string{"eboot.bin", filepath.Join("sce_sys", "param.sfo")} {
		if fi, err := os.Stat(filepath.Join(dir, f)); err != nil || !fi.Mode().IsRegular() {
			return nil, fail("bad_input", "%s has no %s; a game folder needs eboot.bin and sce_sys/param.sfo", src, f)
		}
	}
	s, err := sfo.Load(filepath.Join(dir, "sce_sys", "param.sfo"))
	if err != nil {
		return nil, &failure{code: "bad_input", err: err}
	}
	id, _ := s.String("TITLE_ID")
	if !titleIDPattern.MatchString(id) {
		return nil, fail("bad_input", "%s: param.sfo TITLE_ID %q is not a PS4 title id", src, id)
	}
	if cat, ok := s.String("CATEGORY"); ok && cat != "gd" {
		im.warn("param.sfo CATEGORY is %q; importing as a game because eboot.bin is present", cat)
	}
	cid, _ := s.String("CONTENT_ID")
	im.marker = fmt.Sprintf("folder %s %s\n", cid, dir)
	if err := im.lock(); err != nil {
		return nil, err
	}
	root, err := filepath.EvalSymlinks(im.lib.Root)
	if err != nil {
		return nil, err
	}
	if root, err = filepath.Abs(root); err != nil {
		return nil, err
	}
	if within(dir, root) || within(root, dir) {
		return nil, fail("bad_input", "%s and the library %s must not contain each other", src, im.lib.Root)
	}
	if err := im.recoverGame(id); err != nil {
		return nil, err
	}
	games, err := im.lib.Load()
	if err != nil {
		return nil, err
	}
	if err := im.prepareGameDir(id); err != nil {
		return nil, err
	}
	if mode == "reference" {
		return im.reference(s, id, dir, games)
	}
	size, err := dirSize(dir)
	if err != nil {
		return nil, err
	}
	// An APFS clone takes almost no space, as in installPatch.
	clone := canClone(dir, im.lib.GameDir(id))
	need := int64(spaceMargin)
	if !clone {
		need += size
	}
	if err := im.checkSpace(need); err != nil {
		return nil, err
	}
	partial := im.lib.ContentDir(id) + ".partial"
	if err := im.scratchDir(partial, true); err != nil {
		return nil, err
	}
	if err := im.copyTree(dir, partial, size, clone); err != nil {
		return nil, err
	}
	return im.finishCopy(s, id, partial, games)
}

// reference commits content as a symlink to the folder dir. The folder is never written
// to: a pending patch is not applied, and DLC lives in games/<id>/addcont. The DLC of an
// earlier import is kept: a referenced game's stays where it is, and a copied game's is
// hard-linked from content/addcont into games/<id>/addcont before the commit (recoverGame
// removes it again if the commit does not happen).
func (im *importer) reference(s *sfo.File, id, dir string, games map[string]*Game) (*ImportResult, error) {
	content := im.lib.ContentDir(id)
	ref := content + ".ref.partial"
	if err := im.scratchDir(ref, false); err != nil {
		return nil, err
	}
	if err := os.Symlink(dir, ref); err != nil {
		return nil, err
	}
	prev := games[id]
	g := newGame(s, id, prev)
	refAddcont := im.lib.refAddcontDir(id)
	if prev != nil {
		if copied := filepath.Join(content, "addcont"); isRealDir(content) && isRealDir(copied) {
			if err := im.scratchDir(refAddcont, false); err != nil {
				return nil, err
			}
			if err := linkTree(copied, refAddcont); err != nil {
				return nil, err
			}
		}
		if isRealDir(refAddcont) {
			g.DLC = slices.Clone(prev.DLC)
		}
	}
	if pp, err := im.readPending(id); err != nil {
		return nil, err
	} else if pp != nil {
		im.warn("the pending patch for %s is kept: a referenced game is never modified", id)
	}
	size, err := dirSize(dir)
	if err != nil {
		return nil, err
	}
	dlc, err := optionalDirSize(refAddcont)
	if err != nil {
		return nil, err
	}
	g.ContentBytes = size + dlc
	if err := im.commit(content, ref, content+".old", g); err != nil {
		return nil, err
	}
	return &ImportResult{TitleID: id, Kind: "game", Game: g}, nil
}

// canClone reports whether files of src can be cloned into dstDir: both on one APFS
// volume. (cp -c falls back to a full copy silently, so this is decided up front.)
func canClone(src, dstDir string) bool {
	a, err1 := os.Stat(src)
	b, err2 := os.Stat(dstDir)
	if err1 != nil || err2 != nil {
		return false
	}
	sa, ok1 := a.Sys().(*syscall.Stat_t)
	sb, ok2 := b.Sys().(*syscall.Stat_t)
	if !ok1 || !ok2 || sa.Dev != sb.Dev {
		return false
	}
	var st syscall.Statfs_t
	if syscall.Statfs(dstDir, &st) != nil {
		return false
	}
	var name []byte
	for _, c := range st.Fstypename {
		if c == 0 {
			break
		}
		name = append(name, byte(c))
	}
	return string(name) == "apfs"
}

// copyTree copies the folder src into dst, resuming a previous run: a file already in dst
// with the same size and SHA-256 is kept, and what dst holds that src does not (other
// than dst's resume marker) is removed. With clone, files are cloned with APFS
// clonefile (cp -c, one cp per batch of files of a directory); otherwise their bytes are
// copied. Files skipName drops and anything that is not a regular file or a directory
// are left out.
func (im *importer) copyTree(src, dst string, total int64, clone bool) error {
	var order []string            // directories with files to copy, in walk order
	todo := map[string][]string{} // directory rel → file names
	keep := map[string]bool{resumeMarker: true}
	var done int64
	progress := im.progress("copy")
	err := filepath.WalkDir(src, func(path string, d fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		if skipName(d.Name()) && path != src {
			if d.IsDir() {
				return fs.SkipDir
			}
			return nil
		}
		rel, err := filepath.Rel(src, path)
		if err != nil {
			return err
		}
		switch {
		case d.IsDir():
			keep[rel] = true
			return os.MkdirAll(filepath.Join(dst, rel), 0o755)
		case !d.Type().IsRegular():
			im.warn("skipping %s: not a regular file", rel)
			return nil
		case rel == resumeMarker:
			im.warn("skipping %s: the name is reserved for the import's resume marker", rel)
			return nil
		}
		keep[rel] = true
		same, size, err := sameFile(path, filepath.Join(dst, rel))
		if err != nil {
			return err
		}
		if same {
			done += size
			progress(done, total, rel)
			return nil
		}
		parent := filepath.Dir(rel)
		if _, ok := todo[parent]; !ok {
			order = append(order, parent)
		}
		todo[parent] = append(todo[parent], d.Name())
		return nil
	})
	if err != nil {
		return err
	}
	if err := prune(dst, keep); err != nil {
		return err
	}
	buf := make([]byte, 1<<20)
	for _, rel := range order {
		names := todo[rel]
		for len(names) > 0 {
			n := min(len(names), cloneBatch)
			from, to := filepath.Join(src, rel), filepath.Join(dst, rel)
			if clone {
				err = im.cloneBatch(from, to, names[:n], &done, total, progress)
			} else {
				err = im.copyBatch(from, to, names[:n], buf, &done, total, progress)
			}
			if err != nil {
				return err
			}
			names = names[n:]
		}
	}
	progress(total, total, "")
	return nil
}

// prune removes everything under dst whose path relative to dst is not in keep.
func prune(dst string, keep map[string]bool) error {
	return filepath.WalkDir(dst, func(path string, d fs.DirEntry, err error) error {
		if err != nil || path == dst {
			return err
		}
		rel, err := filepath.Rel(dst, path)
		if err != nil || keep[rel] {
			return err
		}
		if err := os.RemoveAll(path); err != nil {
			return err
		}
		if d.IsDir() {
			return fs.SkipDir
		}
		return nil
	})
}

// cloneBatch clones the files names from the directory from into the directory to.
func (im *importer) cloneBatch(from, to string, names []string, done *int64, total int64, progress fpkg.ProgressFunc) error {
	if im.cancelled() {
		return &failure{code: "cancelled", err: fpkg.ErrCancelled}
	}
	args := []string{"-c"}
	for _, n := range names {
		if err := os.Remove(filepath.Join(to, n)); err != nil && !errors.Is(err, fs.ErrNotExist) {
			return err
		}
		args = append(args, filepath.Join(from, n))
	}
	var stderr bytes.Buffer
	cmd := exec.Command("cp", append(args, to+string(filepath.Separator))...)
	cmd.Stderr = &stderr
	if err := cmd.Run(); err != nil {
		msg := strings.TrimSpace(stderr.String())
		code := "io"
		if strings.Contains(msg, "No space left") {
			code = "no_space"
		}
		return fail(code, "cp -c into %s: %v: %s", to, err, msg)
	}
	for _, n := range names {
		fi, err := os.Lstat(filepath.Join(to, n))
		if err != nil {
			return err
		}
		*done += fi.Size()
	}
	progress(*done, total, filepath.Join(to, names[len(names)-1]))
	return nil
}

// copyBatch copies the bytes of the files names from the directory from into to.
func (im *importer) copyBatch(from, to string, names []string, buf []byte, done *int64, total int64, progress fpkg.ProgressFunc) error {
	for _, n := range names {
		if err := im.copyFile(filepath.Join(from, n), filepath.Join(to, n), buf, done, total, progress); err != nil {
			return err
		}
	}
	return nil
}

func (im *importer) copyFile(from, to string, buf []byte, done *int64, total int64, progress fpkg.ProgressFunc) error {
	in, err := os.Open(from)
	if err != nil {
		return err
	}
	defer in.Close()
	fi, err := in.Stat()
	if err != nil {
		return err
	}
	if err := os.Remove(to); err != nil && !errors.Is(err, fs.ErrNotExist) {
		return err
	}
	out, err := os.OpenFile(to, os.O_WRONLY|os.O_CREATE|os.O_EXCL, fi.Mode().Perm())
	if err != nil {
		return err
	}
	defer out.Close()
	for {
		if im.cancelled() {
			return &failure{code: "cancelled", err: fpkg.ErrCancelled}
		}
		n, rerr := in.Read(buf)
		if n > 0 {
			if _, err := out.Write(buf[:n]); err != nil {
				return err
			}
			*done += int64(n)
			progress(*done, total, to)
		}
		if rerr == io.EOF {
			break
		}
		if rerr != nil {
			return rerr
		}
	}
	return out.Close()
}

// sameFile reports whether dst is a regular file with the size and SHA-256 of src, and
// returns src's size.
func sameFile(src, dst string) (bool, int64, error) {
	si, err := os.Stat(src)
	if err != nil {
		return false, 0, err
	}
	di, err := os.Lstat(dst)
	if err != nil || !di.Mode().IsRegular() || di.Size() != si.Size() {
		return false, si.Size(), nil
	}
	a, err := fileHash(src)
	if err != nil {
		return false, 0, err
	}
	b, err := fileHash(dst)
	if err != nil {
		return false, si.Size(), nil
	}
	return a == b, si.Size(), nil
}

func fileHash(path string) ([sha256.Size]byte, error) {
	var sum [sha256.Size]byte
	f, err := os.Open(path)
	if err != nil {
		return sum, err
	}
	defer f.Close()
	h := sha256.New()
	if _, err := io.Copy(h, f); err != nil {
		return sum, err
	}
	h.Sum(sum[:0])
	return sum, nil
}
