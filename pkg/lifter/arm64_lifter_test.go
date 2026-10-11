package lifter

import (
	"strings"
	"testing"

	"ps4-recomp/pkg/disasm"

	"golang.org/x/arch/x86/x86asm"
)

func TestArm64LifterBasic(t *testing.T) {
	lifter := NewArm64Lifter(map[uint64]bool{0x1000: true, 0x2000: true})

	tests := []struct {
		name     string
		bytes    []byte
		pc       uint64
		expected []string
	}{
		{
			name:     "mov eax, ebx (32-bit zero extend)",
			bytes:    []byte{0x89, 0xd8}, // mov eax, ebx
			pc:       0x1000,
			expected: []string{"mov w19, w20"},
		},
		{
			name:     "mov rax, rbx (64-bit)",
			bytes:    []byte{0x48, 0x89, 0xd8}, // mov rax, rbx
			pc:       0x1000,
			expected: []string{"mov x19, x20"},
		},
		{
			name:     "mov dh, 0xcb (high-8 register immediate)",
			bytes:    []byte{0xb6, 0xcb}, // mov dh, 0xcb
			pc:       0x1000,
			expected: []string{"mov w16, #0xcb", "bfi x22, x16, #8, #8"},
		},
		{
			name:     "movzx r9l, bl",
			bytes:    []byte{0x44, 0x0f, 0xb6, 0xcb}, // movzx r9l, bl
			pc:       0x1000,
			expected: []string{"uxtb w9, w20"},
		},
		{
			name:     "movsx rdx, ax",
			bytes:    []byte{0x48, 0x0f, 0xbf, 0xd0}, // movsx rdx, ax
			pc:       0x1000,
			expected: []string{"sxth x22, w19"},
		},
		{
			name:     "add rax, rcx",
			bytes:    []byte{0x48, 0x01, 0xc8}, // add rax, rcx
			pc:       0x1000,
			expected: []string{"adds x19, x19, x21"},
		},
		{
			name:     "sub rax, 42",
			bytes:    []byte{0x48, 0x83, 0xe8, 0x2a}, // sub rax, 42
			pc:       0x1000,
			expected: []string{"subs x19, x19, #42"},
		},
		{
			name:     "cmp rax, rbx",
			bytes:    []byte{0x48, 0x39, 0xd8}, // cmp rax, rbx
			pc:       0x1000,
			expected: []string{"cmp x19, x20"},
		},
		{
			name:     "sete al",
			bytes:    []byte{0x0f, 0x94, 0xc0}, // sete al
			pc:       0x1000,
			expected: []string{"cset w16, eq", "bfi x19, x16, #0, #8"},
		},
		{
			name:     "cmove rax, rbx",
			bytes:    []byte{0x48, 0x0f, 0x44, 0xc3}, // cmove rax, rbx
			pc:       0x1000,
			expected: []string{"csel x19, x20, x19, eq"},
		},
		{
			name:     "imul eax, ebx",
			bytes:    []byte{0x0f, 0xaf, 0xc3}, // imul eax, ebx
			pc:       0x1000,
			expected: []string{"mul w19, w19, w20"},
		},
		{
			name:     "bswap rax",
			bytes:    []byte{0x48, 0x0f, 0xc8}, // bswap rax
			pc:       0x1000,
			expected: []string{"rev x19, x19"},
		},
		{
			name:     "xorps xmm0, xmm1",
			bytes:    []byte{0x0f, 0x57, 0xc1}, // xorps xmm0, xmm1
			pc:       0x1000,
			expected: []string{"eor v0.16b, v0.16b, v1.16b"},
		},
		{
			name:     "ret",
			bytes:    []byte{0xc3}, // ret
			pc:       0x1000,
			expected: []string{"ldr x16, [x28, x26]", "add x26, x26, #8", "ret"},
		},
		{
			name:     "sbb eax, eax",
			bytes:    []byte{0x19, 0xc0}, // sbb eax, eax
			pc:       0x1000,
			expected: []string{"sbcs w19, w19, w19"},
		},
		{
			name:     "adc rax, rbx",
			bytes:    []byte{0x48, 0x11, 0xd8}, // adc rax, rbx
			pc:       0x1000,
			expected: []string{"adcs x19, x19, x20"},
		},
		{
			name:     "bt eax, 13",
			bytes:    []byte{0x0f, 0xba, 0xe0, 0x0d}, // bt eax, 13
			pc:       0x1000,
			expected: []string{"ubfx w16, w19, #13, #1", "cmp wzr, w16"},
		},
		{
			name:     "cvtss2sd xmm0, xmm1",
			bytes:    []byte{0xf3, 0x0f, 0x5a, 0xc1}, // cvtss2sd xmm0, xmm1
			pc:       0x1000,
			expected: []string{"fcvt d0, s1"},
		},
		{
			name:     "pandn xmm0, xmm1",
			bytes:    []byte{0x66, 0x0f, 0xdf, 0xc1}, // pandn xmm0, xmm1
			pc:       0x1000,
			expected: []string{"bic v0.16b, v1.16b, v0.16b"},
		},
		{
			name:     "pshufd xmm0, xmm1, 0",
			bytes:    []byte{0x66, 0x0f, 0x70, 0xc1, 0x00}, // pshufd xmm0, xmm1, 0
			pc:       0x1000,
			expected: []string{"dup v0.4s, v1.s[0]"},
		},
		{
			name:     "punpckldq xmm0, xmm1",
			bytes:    []byte{0x66, 0x0f, 0x62, 0xc1}, // punpckldq xmm0, xmm1
			pc:       0x1000,
			expected: []string{"zip1 v0.4s, v0.4s, v1.4s"},
		},
		{
			name:     "pcmpgtd xmm0, xmm1",
			bytes:    []byte{0x66, 0x0f, 0x66, 0xc1}, // pcmpgtd xmm0, xmm1
			pc:       0x1000,
			expected: []string{"cmgt v0.4s, v0.4s, v1.4s"},
		},
		{
			name:     "pmuludq xmm0, xmm1",
			bytes:    []byte{0x66, 0x0f, 0xf4, 0xc1}, // pmuludq xmm0, xmm1
			pc:       0x1000,
			expected: []string{"umull v0.2d, v0.2s, v1.2s"},
		},
	}

	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			inst, err := x86asm.Decode(tc.bytes, 64)
			if err != nil {
				t.Fatalf("failed to decode: %v", err)
			}
			dInst := disasm.Instruction{Address: tc.pc, Inst: inst}
			nextPC := tc.pc + uint64(inst.Len)
			lines, err := lifter.LiftInstructionToBuf(dInst, nextPC, nil, nil)
			if err != nil {
				t.Fatalf("LiftInstructionToBuf failed: %v", err)
			}
			joined := strings.Join(lines, "\n")
			for _, exp := range tc.expected {
				if !strings.Contains(joined, exp) {
					t.Errorf("expected %q in output, got:\n%s", exp, joined)
				}
			}
		})
	}
}
