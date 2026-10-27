package emitter

import (
	"os"
	"path/filepath"
	"strings"
	"testing"

	"ps4-recomp/pkg/elfloader"
)

func TestTLSInitSourceListsEveryModule(t *testing.T) {
	src := tlsInitSource([]elfloader.TLSModule{
		{ID: 1, Name: "eboot.bin", Vaddr: 0xda0060, Filesz: 4, Memsz: 0x30, Align: 8, Offset: 0x30},
		{ID: 2, Name: "libSceFios2.prx", Vaddr: 0x8010020, Memsz: 0x40, Align: 8, Offset: 0x70},
	})
	for _, want := range []string{
		"{1, 0xda0060ULL, 0x4ULL, 0x30ULL, 0x8ULL, 0x30ULL}, // eboot.bin",
		"{2, 0x8010020ULL, 0x0ULL, 0x40ULL, 0x8ULL, 0x70ULL}, // libSceFios2.prx",
		"recomp_init_tls_modules(ctx, tls_modules, 2);",
	} {
		if !strings.Contains(src, want) {
			t.Errorf("missing %q in\n%s", want, src)
		}
	}
	if got := tlsInitSource(nil); got != "    recomp_init_tls_modules(ctx, NULL, 0);" {
		t.Errorf("no TLS: %q", got)
	}
}

// The static TLS is set up before recomp_init_process_param, which runs guest code (the game's
// malloc replacement init), as rtld allocates the initial TLS before any init code.
func TestMainRunnerSetsUpTLSBeforeGuestCode(t *testing.T) {
	e := &AsmEmitter{elf: &elfloader.LoadedELF{
		EntryPoint:    0x61dfd0,
		ProcParamAddr: 0xda0000,
		TLSModules:    []elfloader.TLSModule{{ID: 1, Name: "eboot.bin", Vaddr: 0xda0060, Filesz: 4, Memsz: 0x30, Align: 8, Offset: 0x30}},
	}}
	path := filepath.Join(t.TempDir(), "main.c")
	if err := e.EmitMainRunner(path); err != nil {
		t.Fatal(err)
	}
	b, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	src := string(b)
	tls := strings.Index(src, "recomp_init_tls_modules(ctx, tls_modules, 1);")
	param := strings.Index(src, "recomp_init_process_param(ctx, 0xda0000ULL);")
	entry := strings.Index(src, "recomp_enter_guest(ctx")
	if tls < 0 || param < 0 || entry < 0 {
		t.Fatalf("main.c lacks a call (tls %d, process param %d, entry %d):\n%s", tls, param, entry, src)
	}
	if !(tls < param && param < entry) {
		t.Errorf("order: tls at %d, process param at %d, entry at %d", tls, param, entry)
	}
}
