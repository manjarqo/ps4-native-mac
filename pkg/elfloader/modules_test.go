package elfloader

import (
	"encoding/binary"
	"os"
	"path/filepath"
	"testing"
)

func TestMapGuestPath(t *testing.T) {
	app := filepath.Join(t.TempDir(), "game")
	if got := MapGuestPath("/app0/sce_module/libExample.prx", app); got != filepath.Join(app, "sce_module", "libExample.prx") {
		t.Fatalf("got %q", got)
	}
	if got := MapGuestPath("/app0", app); got != app {
		t.Fatalf("got %q", got)
	}
	if got := MapGuestPath("/data/save", app); got != "" {
		t.Fatalf("non-app0 absolute path must not map onto appDir, got %q", got)
	}
	if got := MapGuestPath("sce_module/libExample.prx", app); got != filepath.Join(app, "sce_module", "libExample.prx") {
		t.Fatalf("got %q", got)
	}
	if got := MapGuestPath("%s/Modules/Il2CppUserAssemblies.prx", app); got != filepath.Join(app, "Modules", "Il2CppUserAssemblies.prx") {
		t.Fatalf("got %q", got)
	}
	if got := MapGuestPath("/app0/%s/Modules/PS4Util.prx", app); got != filepath.Join(app, "Modules", "PS4Util.prx") {
		t.Fatalf("got %q", got)
	}
}

func TestDiscoverModulesDirectory(t *testing.T) {
	dir := t.TempDir()
	modDir := filepath.Join(dir, "Modules")
	if err := os.Mkdir(modDir, 0o755); err != nil {
		t.Fatal(err)
	}
	prxPath := filepath.Join(modDir, "Il2CppUserAssemblies.prx")
	if err := os.WriteFile(prxPath, []byte("fake-elf-data"), 0o644); err != nil {
		t.Fatal(err)
	}

	img := append([]byte{0, 0, 0, 0}, []byte("%s/Modules/Il2CppUserAssemblies.prx\x00")...)
	// Discover with empty appDir, but elfPath pointing to eboot.bin in dir
	refs := DiscoverCompanionModules(filepath.Join(dir, "eboot.bin"), "", img)
	if len(refs) != 1 {
		t.Fatalf("expected 1 module, got %+v", refs)
	}
	if filepath.Base(refs[0].Path) != "Il2CppUserAssemblies.prx" {
		t.Fatalf("unexpected path: %s", refs[0].Path)
	}
}

func TestReferencedModuleNames(t *testing.T) {
	img := make([]byte, 64)
	copy(img[8:], []byte("/app0/sce_module/libExample.prx\x00"))
	copy(img[40:], []byte("libc.prx\x00"))
	names := ReferencedModuleNames(img)
	if len(names) != 1 || names[0] != "/app0/sce_module/libExample.prx" {
		t.Fatalf("names=%v", names)
	}
}

func TestDiscoverResolvesApp0(t *testing.T) {
	dir := t.TempDir()
	modDir := filepath.Join(dir, "sce_module")
	if err := os.Mkdir(modDir, 0o755); err != nil {
		t.Fatal(err)
	}
	prx := filepath.Join(modDir, "libExample.prx")
	if err := os.WriteFile(prx, []byte("not-an-elf"), 0o644); err != nil {
		t.Fatal(err)
	}
	img := append([]byte{0, 0, 0, 0}, []byte("/app0/sce_module/libExample.prx\x00")...)
	refs := DiscoverCompanionModules("", dir, img)
	if len(refs) != 1 {
		t.Fatalf("expected 1 module, got %+v", refs)
	}
	if filepath.Base(refs[0].Path) != "libExample.prx" {
		t.Fatalf("path=%s", refs[0].Path)
	}
}

func TestRetailModuleNotStub(t *testing.T) {
	dir := t.TempDir()
	libcStub := filepath.Join(dir, "libc.prx")
	if err := os.WriteFile(libcStub, make([]byte, 1024), 0o644); err != nil {
		t.Fatal(err)
	}
	if !IsSystemStubModule(libcStub) {
		t.Fatalf("expected %s (< 64KB) to be a system stub", libcStub)
	}

	libcPath := filepath.Join(dir, "retail", "libc.prx")
	if err := os.MkdirAll(filepath.Dir(libcPath), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(libcPath, make([]byte, 128*1024), 0o644); err != nil {
		t.Fatal(err)
	}
	if IsSystemStubModule(libcPath) {
		t.Fatalf("expected %s (> 64KB) to NOT be treated as a system stub", libcPath)
	}
}

func TestDiscoverPrxDir(t *testing.T) {
	dir := t.TempDir()
	prxDir := filepath.Join(dir, "prx")
	if err := os.Mkdir(prxDir, 0o755); err != nil {
		t.Fatal(err)
	}
	plugin := filepath.Join(prxDir, "akplugin.prx")
	if err := os.WriteFile(plugin, []byte("stub"), 0o644); err != nil {
		t.Fatal(err)
	}
	refs := DiscoverCompanionModules("", dir, nil)
	found := false
	for _, ref := range refs {
		if filepath.Base(ref.Path) == "akplugin.prx" {
			found = true
			break
		}
	}
	if !found {
		t.Fatalf("expected akplugin.prx from prx directory to be discovered, got %+v", refs)
	}
}

func TestApplyBiasCanary(t *testing.T) {
	img := make([]byte, 0x10000)
	const origCanaryAddr = 0x5000
	const gotOffset = 0x2000
	const canaryVal = uint64(0x595e9fbd94fda766)
	binary.LittleEndian.PutUint64(img[origCanaryAddr:origCanaryAddr+8], canaryVal)
	binary.LittleEndian.PutUint64(img[gotOffset:gotOffset+8], origCanaryAddr)

	loaded := &LoadedELF{
		MinVAddr:    0x1000,
		MaxVAddr:    0x6000,
		CanaryAddr:  origCanaryAddr,
		MemoryImage: img,
		Relocations: []Relocation{
			{Offset: gotOffset, Type: R_X86_64_GLOB_DAT, SymName: "f7uOxY9mM1U#D#D"},
		},
	}

	const delta = uint64(0x20000)
	if err := loaded.ApplyBias(delta); err != nil {
		t.Fatalf("ApplyBias failed: %v", err)
	}

	if loaded.CanaryAddr != origCanaryAddr+delta {
		t.Fatalf("expected CanaryAddr 0x%x, got 0x%x", origCanaryAddr+delta, loaded.CanaryAddr)
	}

	newGotOffset := gotOffset + delta
	gotPtr := binary.LittleEndian.Uint64(loaded.MemoryImage[newGotOffset : newGotOffset+8])
	if gotPtr != loaded.CanaryAddr {
		t.Fatalf("expected GOT entry to point to shifted canary 0x%x, got 0x%x", loaded.CanaryAddr, gotPtr)
	}
}

func TestMergeImagesCanary(t *testing.T) {
	const dstCanaryAddr = 0x8000
	const canaryVal = uint64(0x595e9fbd94fda766)

	dstImg := make([]byte, 0x9000)
	binary.LittleEndian.PutUint64(dstImg[dstCanaryAddr:dstCanaryAddr+8], canaryVal)
	dst := &LoadedELF{
		FileName:    "main",
		MinVAddr:    0x1000,
		MaxVAddr:    0x9000,
		CanaryAddr:  dstCanaryAddr,
		MemoryImage: dstImg,
	}

	const srcCanaryAddr = 0x15000
	const srcGotOffset = 0x12000
	srcImg := make([]byte, 0x16000)
	binary.LittleEndian.PutUint64(srcImg[srcCanaryAddr:srcCanaryAddr+8], canaryVal)
	binary.LittleEndian.PutUint64(srcImg[srcGotOffset:srcGotOffset+8], srcCanaryAddr)
	src := &LoadedELF{
		FileName:    "companion.prx",
		MinVAddr:    0x10000,
		MaxVAddr:    0x16000,
		CanaryAddr:  srcCanaryAddr,
		MemoryImage: srcImg,
		Relocations: []Relocation{
			{Offset: srcGotOffset, Type: R_X86_64_GLOB_DAT, SymName: "__stack_chk_guard"},
		},
	}

	if err := MergeImages(dst, src); err != nil {
		t.Fatalf("MergeImages failed: %v", err)
	}

	if dst.CanaryAddr != dstCanaryAddr {
		t.Fatalf("expected dst CanaryAddr 0x%x, got 0x%x", dstCanaryAddr, dst.CanaryAddr)
	}

	gotPtr := binary.LittleEndian.Uint64(dst.MemoryImage[srcGotOffset : srcGotOffset+8])
	if gotPtr != dstCanaryAddr {
		t.Fatalf("expected merged GOT entry to point to process canary 0x%x, got 0x%x", dstCanaryAddr, gotPtr)
	}
}

func TestDiscoverCompanionModulesFiltersSceModule(t *testing.T) {
	dir := t.TempDir()
	sceModDir := filepath.Join(dir, "sce_module")
	if err := os.MkdirAll(sceModDir, 0o755); err != nil {
		t.Fatal(err)
	}

	// Retail libc.prx and libSceFios2.prx (> 64 KB) must be kept.
	retailPayload := make([]byte, 128*1024)
	for _, name := range []string{"libc.prx", "libSceFios2.prx"} {
		if err := os.WriteFile(filepath.Join(sceModDir, name), retailPayload, 0o644); err != nil {
			t.Fatal(err)
		}
	}

	// Explicitly referenced PRX in sce_module/ must be kept.
	if err := os.WriteFile(filepath.Join(sceModDir, "libCustomEngine.prx"), []byte("referenced-prx"), 0o644); err != nil {
		t.Fatal(err)
	}

	// Unreferenced middleware PRXs with no matching exports must be skipped.
	for _, unused := range []string{
		"libSceFace.prx",
		"libSceHand.prx",
		"libSceHeadTracker.prx",
		"libSceS3DConversion.prx",
		"libSceSmart.prx",
	} {
		if err := os.WriteFile(filepath.Join(sceModDir, unused), retailPayload, 0o644); err != nil {
			t.Fatal(err)
		}
	}

	img := append([]byte{0, 0, 0, 0}, []byte("/app0/sce_module/libCustomEngine.prx\x00")...)
	refs := DiscoverCompanionModules(filepath.Join(dir, "eboot.bin"), dir, img)

	got := make(map[string]bool)
	for _, r := range refs {
		got[filepath.Base(r.Path)] = true
	}

	for _, want := range []string{"libc.prx", "libSceFios2.prx", "libCustomEngine.prx"} {
		if !got[want] {
			t.Errorf("expected %s to be kept, got refs=%+v", want, refs)
		}
	}
	for _, unwanted := range []string{
		"libSceFace.prx",
		"libSceHand.prx",
		"libSceHeadTracker.prx",
		"libSceS3DConversion.prx",
		"libSceSmart.prx",
	} {
		if got[unwanted] {
			t.Errorf("expected unreferenced %s to be filtered out, got refs=%+v", unwanted, refs)
		}
	}
}

func TestUnresolvedAndExportedSymbolsIntersection(t *testing.T) {
	mainELF := &LoadedELF{
		MemoryImage: make([]byte, 0x2000),
		Relocations: []Relocation{
			{Offset: 0x1000, Type: R_X86_64_JUMP_SLOT, SymName: "needed_nid#A#B"},
		},
	}
	unresolved := make(map[string]struct{})
	addUnresolvedSymbols(unresolved, mainELF)

	usedPRX := &LoadedELF{
		MemoryImage: make([]byte, 0x2000),
		DynSymbols: []Symbol{
			{Name: "needed_nid#C#D", Address: 0x120, Type: 2},
		},
	}
	unusedPRX := &LoadedELF{
		MemoryImage: make([]byte, 0x2000),
		DynSymbols: []Symbol{
			{Name: "other_nid#C#D", Address: 0x120, Type: 2},
		},
	}

	if !exportsIntersectUnresolved(usedPRX.ExportedSymbols(), unresolved) {
		t.Fatalf("expected usedPRX exports to intersect mainELF unresolved symbols")
	}
	if exportsIntersectUnresolved(unusedPRX.ExportedSymbols(), unresolved) {
		t.Fatalf("expected unusedPRX exports NOT to intersect mainELF unresolved symbols")
	}
}

func TestDiscoverCompanionModulesBloodborne(t *testing.T) {
	bbDir := "/Users/manjarqo/Library/Application Support/PS4Native/games/CUSA03173/content"
	ebootPath := filepath.Join(bbDir, "eboot.bin")
	if !fileExists(ebootPath) {
		t.Skip("Bloodborne CUSA03173 not present")
	}
	refs := DiscoverCompanionModules(ebootPath, bbDir, nil)
	got := make(map[string]bool)
	for _, r := range refs {
		got[filepath.Base(r.Path)] = true
	}
	if len(refs) != 2 || !got["libc.prx"] || !got["libSceFios2.prx"] {
		t.Fatalf("expected exactly libc.prx and libSceFios2.prx for Bloodborne, got %+v", refs)
	}
}
