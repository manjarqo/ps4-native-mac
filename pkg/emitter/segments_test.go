package emitter

import (
	"testing"

	"ps4-recomp/pkg/elfloader"
)

// A merged companion module's segments must not appear in the main image's segment list.
func TestOwnSegmentsExcludesMergedModules(t *testing.T) {
	main := &elfloader.LoadedELF{
		OrigMinVAddr: 0,
		OrigMaxVAddr: 0x2400000,
		MaxVAddr:     0x2400000,
		Segments: []*elfloader.Segment{
			{Vaddr: 0x0, Memsz: 0x1e00000, Flags: 5},
			{Vaddr: 0x2000000, Memsz: 0x70000, Flags: 4},
			{Vaddr: 0x2200000, Memsz: 0x1e0000, Flags: 6},
		},
	}
	fios := &elfloader.LoadedELF{
		MinVAddr: 0x2800000,
		MaxVAddr: 0x2900000,
		Segments: []*elfloader.Segment{{Vaddr: 0x2800000, Memsz: 0x80000, Flags: 5}},
	}
	if err := elfloader.MergeImages(main, fios); err != nil {
		t.Fatal(err)
	}
	if len(main.Segments) != 4 {
		t.Fatalf("merge should append the module segment: got %d segments", len(main.Segments))
	}
	got := ownSegments(main)
	if len(got) != 3 {
		t.Fatalf("ownSegments: got %d segments, want 3", len(got))
	}
	for _, s := range got {
		if s.Vaddr >= 0x2400000 {
			t.Fatalf("ownSegments kept merged module segment at 0x%x", s.Vaddr)
		}
	}
}
