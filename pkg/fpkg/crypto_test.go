// SPDX-License-Identifier: GPL-2.0-or-later

package fpkg

import (
	"bytes"
	"encoding/hex"
	"testing"
)

func mustHex(s string) []byte {
	b, err := hex.DecodeString(s)
	if err != nil {
		panic(err)
	}
	return b
}

// TestXTSKnownAnswer checks the AES-XTS primitive against IEEE 1619 vector 1 (all-zero keys,
// sector 0, 32 zero bytes -> 917cf69ebd68b2ec9b9fe9a3eadda692cd43d2f59598ed858c02c2652fbf922e).
func TestXTSKnownAnswer(t *testing.T) {
	var k1, k2 [16]byte
	got := make([]byte, 32)
	xtsEncryptSector(k1, k2, 0, got)
	want := mustHex("917cf69ebd68b2ec9b9fe9a3eadda692cd43d2f59598ed858c02c2652fbf922e")
	if !bytes.Equal(got, want) {
		t.Fatalf("xts = %x", got)
	}
	xtsDecryptSector(k1, k2, 0, got)
	if !bytes.Equal(got, make([]byte, 32)) {
		t.Fatalf("xts round trip = %x", got)
	}
}

// TestEntryNames spot-checks the generated id -> name table against pkg_type.cpp:15-629.
func TestEntryNames(t *testing.T) {
	for id, want := range map[uint32]string{
		0x0001: "digests", 0x0409: "psreserved.dat", 0x100E: "shareprivacyguardimage.png",
		0x1201: "icon0_00.png", 0x121F: "icon0_30.png", 0x1241: "pic1_00.png",
		0x1261: "changeinfo/changeinfo_00.xml", 0x127F: "changeinfo/changeinfo_30.xml",
		0x1281: "icon0_00.dds", 0x12C1: "pic1_00.dds", 0x12DF: "pic1_30.dds",
		0x1400: "trophy/trophy00.trp", 0x1463: "trophy/trophy99.trp",
		0x1600: "keymap_rp/001.png", 0x1609: "keymap_rp/010.png",
		0x1610: "keymap_rp/00/001.png", 0x1619: "keymap_rp/00/010.png", 0x17F9: "keymap_rp/30/010.png",
		0x0002: "", 0x1464: "", 0x161A: "", 0x17FA: "",
	} {
		if got := entryName(id); got != want {
			t.Errorf("entryName(%#x) = %q, want %q", id, got, want)
		}
	}
}
