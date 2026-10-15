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
			name:     "movzx ecx, word ptr [rdi]",
			bytes:    []byte{0x0f, 0xb7, 0x0f}, // movzx ecx, word ptr [rdi]
			pc:       0x1000,
			expected: []string{"ldrh w21, [x28, x16]"},
		},
		{
			name:     "movzx ecx, byte ptr [rdi]",
			bytes:    []byte{0x0f, 0xb6, 0x0f}, // movzx ecx, byte ptr [rdi]
			pc:       0x1000,
			expected: []string{"ldrb w21, [x28, x16]"},
		},
		{
			name:     "mov byte ptr [r13 + 0x411d], 0 (large disp store without clobbering w17)",
			bytes:    []byte{0x41, 0xc6, 0x85, 0x1d, 0x41, 0x00, 0x00, 0x00}, // mov byte ptr [r13+0x411d], 0
			pc:       0x1000,
			expected: []string{"mov w17, #0x0", "mov x16, x13", "movz x7, #0x411d", "add x16, x16, x7", "strb w17, [x28, x16]"},
		},
		{
			name:     "movsx rcx, word ptr [rdi]",
			bytes:    []byte{0x48, 0x0f, 0xbf, 0x0f}, // movsx rcx, word ptr [rdi]
			pc:       0x1000,
			expected: []string{"ldrsh x21, [x28, x16]"},
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
			name:     "adc r14, 0",
			bytes:    []byte{0x49, 0x83, 0xd6, 0x00}, // adc r14, 0
			pc:       0x1000,
			expected: []string{"cset x16, cc", "adds x14, x14, x16"},
		},
		{
			name:     "adc eax, 0",
			bytes:    []byte{0x83, 0xd0, 0x00}, // adc eax, 0
			pc:       0x1000,
			expected: []string{"cset w16, cc", "adds w19, w19, w16"},
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
		{
			name:     "vmovddup xmm1, xmm2",
			bytes:    []byte{0xc5, 0xfb, 0x12, 0xca}, // vmovddup xmm1, xmm2
			pc:       0x1000,
			expected: []string{"dup v1.2d, v2.d[0]", "movi v17.16b, #0"},
		},
		{
			name:     "vmovq rbx, xmm0",
			bytes:    []byte{0xc4, 0xe1, 0xf9, 0x7e, 0xc3}, // vmovq rbx, xmm0
			pc:       0x1000,
			expected: []string{"fmov x20, d0"},
		},
		{
			name:     "vpshufd xmm0, xmm4, 0xee",
			bytes:    []byte{0xc5, 0xf9, 0x70, 0xc4, 0xee}, // vpshufd xmm0, xmm4, 0xee
			pc:       0x1000,
			expected: []string{"tbl v0.16b, {v4.16b}, v29.16b", "movi v16.16b, #0"},
		},
		{
			name:     "vpcmpeqd x7, x7, x7",
			bytes:    []byte{0xc5, 0xc1, 0x76, 0xff}, // vpcmpeqd x7, x7, x7
			pc:       0x1000,
			expected: []string{"cmeq v7.4s, v7.4s, v7.4s", "movi v23.16b, #0"},
		},
		{
			name:     "vpaddq x3, x3, x7",
			bytes:    []byte{0xc5, 0xe1, 0xd4, 0xdf}, // vpaddq x3, x3, x7
			pc:       0x1000,
			expected: []string{"add v3.2d, v3.2d, v7.2d", "movi v19.16b, #0"},
		},
		{
			name:     "bextr ecx, ecx, r8d",
			bytes:    []byte{0xc4, 0xe2, 0x38, 0xf7, 0xc9}, // bextr ecx, ecx, r8d
			pc:       0x1000,
			expected: []string{"ubfx w16, w8, #0, #8", "ubfx w17, w8, #8, #8", "lsr w18, w18, w16", "cmp w21, #0"},
		},
		{
			name:     "vcvttsd2si rax, xmm0",
			bytes:    []byte{0xc4, 0xe1, 0xfb, 0x2c, 0xc0}, // vcvttsd2si rax, xmm0
			pc:       0x1000,
			expected: []string{"fcvtzs x19, d0"},
		},
		{
			name:     "vbroadcastf128 ymm0, [rip + 0x10]",
			bytes:    []byte{0xc4, 0xe2, 0x7d, 0x1a, 0x05, 0x10, 0x00, 0x00, 0x00},
			pc:       0x1000,
			expected: []string{"ldr q0, [x28, x16]", "mov v16.16b, v0.16b"},
		},
		{
			name:     "vbroadcastsd ymm1, [rip + 0x10]",
			bytes:    []byte{0xc4, 0xe2, 0x7d, 0x19, 0x0d, 0x10, 0x00, 0x00, 0x00},
			pc:       0x1000,
			expected: []string{"ldr d1, [x28, x16]", "dup v1.2d, v1.d[0]", "mov v17.16b, v1.16b"},
		},
		{
			name:     "vextractf128 xmm0, ymm1, 1",
			bytes:    []byte{0xc4, 0xe3, 0x7d, 0x19, 0xc8, 0x01},
			pc:       0x1000,
			expected: []string{"mov v0.16b, v17.16b", "movi v16.16b, #0"},
		},
		{
			name:     "vinsertf128 ymm0, ymm1, xmm2, 1",
			bytes:    []byte{0xc4, 0xe3, 0x75, 0x18, 0xc2, 0x01},
			pc:       0x1000,
			expected: []string{"mov v16.16b, v2.16b", "mov v0.16b, v1.16b", "mov v16.16b, v16.16b"},
		},
		{
			name:     "vextractps eax, xmm0, 1",
			bytes:    []byte{0xc4, 0xe3, 0x79, 0x17, 0xc0, 0x01},
			pc:       0x1000,
			expected: []string{"umov w16, v0.s[1]", "mov w19, w16"},
		},
		{
			name:     "vinsertps xmm0, xmm1, xmm2, 0x10",
			bytes:    []byte{0xc4, 0xe3, 0x71, 0x21, 0xc2, 0x10},
			pc:       0x1000,
			expected: []string{"mov v16.s[0], v2.s[0]", "mov v0.16b, v1.16b", "mov v0.s[1], v16.s[0]", "movi v16.16b, #0"},
		},
		{
			name:     "vperm2f128 ymm0, ymm1, ymm2, 0x20",
			bytes:    []byte{0xc4, 0xe3, 0x75, 0x06, 0xc2, 0x20},
			pc:       0x1000,
			expected: []string{"mov v18.16b, v1.16b", "mov v19.16b, v2.16b", "mov v0.16b, v18.16b", "mov v16.16b, v19.16b"},
		},
		{
			name:     "vpermilps ymm0, ymm1, 0x1b",
			bytes:    []byte{0xc4, 0xe3, 0x7d, 0x04, 0xc1, 0x1b},
			pc:       0x1000,
			expected: []string{"mov v18.s[0], v1.s[3]", "mov v18.s[1], v1.s[2]", "mov v18.s[2], v1.s[1]", "mov v18.s[3], v1.s[0]", "mov v0.16b, v18.16b"},
		},
		{
			name:     "vpermilpd ymm0, ymm1, 0x01",
			bytes:    []byte{0xc4, 0xe3, 0x7d, 0x05, 0xc1, 0x01},
			pc:       0x1000,
			expected: []string{"mov v18.d[0], v1.d[1]", "mov v18.d[1], v1.d[0]", "mov v0.16b, v18.16b"},
		},
		{
			name:     "cpuid",
			bytes:    []byte{0x0f, 0xa2}, // cpuid
			pc:       0x1000,
			expected: []string{"// cpuid", "cbz w16", "cmp w16, #1"},
		},
		{
			name:     "xgetbv",
			bytes:    []byte{0x0f, 0x01, 0xd0}, // xgetbv
			pc:       0x1000,
			expected: []string{"// xgetbv", "mov x19, #7", "mov x22, #0"},
		},
		{
			name:     "vpinsrb x0, x0, r9l, 0x1",
			bytes:    []byte{0xc4, 0xc3, 0x79, 0x20, 0xc1, 0x01},
			pc:       0x1000,
			expected: []string{"mov w16, w9", "mov v0.b[1], w16", "movi v16.16b, #0"},
		},
		{
			name:     "vpmovmskb edx, x1",
			bytes:    []byte{0xc5, 0xf9, 0xd7, 0xd1},
			pc:       0x1000,
			expected: []string{"sshr v16.16b, v1.16b, #7", "and v16.16b, v16.16b, v17.16b", "addp v16.16b", "umov w16, v16.h[0]", "mov w22, w16"},
		},
		{
			name:     "vdpps x3, x3, x2, 0x7f",
			bytes:    []byte{0xc4, 0xe3, 0x61, 0x40, 0xda, 0x7f},
			pc:       0x1000,
			expected: []string{"fmul v16.4s, v3.4s, v2.4s", "faddp v17.4s, v16.4s, v16.4s", "faddp s17, v17.2s", "mov v3.s[0], v17.s[0]", "movi v19.16b, #0"},
		},
		{
			name:     "vucomiss x3, [rax]",
			bytes:    []byte{0xc5, 0xf8, 0x2e, 0x18},
			pc:       0x1000,
			expected: []string{"ldr s16, [x28, x16]", "fcmp s3, s16"},
		},
		{
			name:     "vucomisd x2, [rax+0x10]",
			bytes:    []byte{0xc5, 0xf9, 0x2e, 0x50, 0x10},
			pc:       0x1000,
			expected: []string{"ldr d16, [x28, x16]", "fcmp d2, d16"},
		},
		{
			name:     "vunpcklps x2, x0, x4",
			bytes:    []byte{0xc5, 0xf8, 0x14, 0xd4},
			pc:       0x1000,
			expected: []string{"zip1 v2.4s, v0.4s, v4.4s", "movi v18.16b, #0"},
		},
		{
			name:     "vunpcklps y2, y0, y4",
			bytes:    []byte{0xc5, 0xfc, 0x14, 0xd4},
			pc:       0x1000,
			expected: []string{"zip1 v2.4s, v0.4s, v4.4s", "zip1 v18.4s, v16.4s, v20.4s"},
		},
		{
			name:     "unpcklps x2, x4",
			bytes:    []byte{0x0f, 0x14, 0xd4},
			pc:       0x1000,
			expected: []string{"zip1 v2.4s, v2.4s, v4.4s"},
		},
		{
			name:     "vblendps x0, x1, x0, 0x3",
			bytes:    []byte{0xc4, 0xe3, 0x71, 0x0c, 0xc0, 0x03},
			pc:       0x1000,
			expected: []string{"bsl v28.16b, v0.16b, v1.16b", "mov v0.16b, v28.16b", "movi v16.16b, #0"},
		},
		{
			name:     "vmovshdup x1, x11",
			bytes:    []byte{0xc4, 0xc1, 0x7a, 0x16, 0xcb},
			pc:       0x1000,
			expected: []string{"trn2 v1.4s, v11.4s, v11.4s", "movi v17.16b, #0"},
		},
		{
			name:     "vmovsldup x1, x11",
			bytes:    []byte{0xc4, 0xc1, 0x7a, 0x12, 0xcb},
			pc:       0x1000,
			expected: []string{"trn1 v1.4s, v11.4s, v11.4s", "movi v17.16b, #0"},
		},
		{
			name:     "andn eax, ebx, ecx",
			bytes:    []byte{0xc4, 0xe2, 0x60, 0xf2, 0xc1},
			pc:       0x1000,
			expected: []string{"bics w18, w17, w16", "mov w19, w18"},
		},
		{
			name:     "vandnps x0, x1, x2",
			bytes:    []byte{0xc5, 0xf0, 0x55, 0xc2},
			pc:       0x1000,
			expected: []string{"bic v0.16b, v2.16b, v1.16b", "movi v16.16b, #0"},
		},
		{
			name:     "vpshufb x0, x1, x2",
			bytes:    []byte{0xc4, 0xe2, 0x71, 0x00, 0xc2},
			pc:       0x1000,
			expected: []string{"tbl v0.16b, {v1.16b}, v29.16b", "movi v16.16b, #0"},
		},
		{
			name:     "vcmpps x0, x1, x2, 0",
			bytes:    []byte{0xc5, 0xf0, 0xc2, 0xc2, 0x00},
			pc:       0x1000,
			expected: []string{"fcmeq v0.4s, v1.4s, v2.4s", "movi v16.16b, #0"},
		},
		{
			name:     "vcvtdq2ps x0, x1",
			bytes:    []byte{0xc5, 0xf8, 0x5b, 0xc1},
			pc:       0x1000,
			expected: []string{"scvtf v0.4s, v1.4s", "movi v16.16b, #0"},
		},
		{
			name:     "vpslld x1, x1, 4",
			bytes:    []byte{0xc5, 0xf1, 0x72, 0xf1, 0x04},
			pc:       0x1000,
			expected: []string{"shl v1.4s, v1.4s, #4", "movi v17.16b, #0"},
		},
		{
			name:     "push qword [rax]",
			bytes:    []byte{0xff, 0x30}, // push [rax]
			pc:       0x1000,
			expected: []string{"ldr x16, [x28, x16]", "sub x26, x26, #8", "str x16, [x28, x26]"},
		},
		{
			name:     "pop qword [rax]",
			bytes:    []byte{0x8f, 0x00}, // pop [rax]
			pc:       0x1000,
			expected: []string{"ldr x16, [x28, x26]", "add x26, x26, #8", "str x16, [x28, x16]"},
		},
		{
			name:     "div dword [rcx]",
			bytes:    []byte{0xf7, 0x31}, // div dword [rcx]
			pc:       0x1000,
			expected: []string{"ldr w17, [x28, x16]", "udiv w16, w19, w17", "msub w22, w16, w17, w19"},
		},
		{
			name:     "mul qword [rcx]",
			bytes:    []byte{0x48, 0xf7, 0x21}, // mul qword [rcx]
			pc:       0x1000,
			expected: []string{"ldr x17, [x28, x16]", "umulh x22, x19, x17", "mul x19, x19, x17"},
		},
		{
			name:     "not qword [rdx]",
			bytes:    []byte{0x48, 0xf7, 0x12}, // not qword [rdx]
			pc:       0x1000,
			expected: []string{"ldr x16, [x28, x16]", "mvn x16, x16", "str x16, [x28, x16]"},
		},
		{
			name:     "bts rax, 5",
			bytes:    []byte{0x48, 0x0f, 0xba, 0xe8, 0x05}, // bts rax, 5
			pc:       0x1000,
			expected: []string{"ubfx x16, x19, #5, #1", "cmp xzr, x16", "orr x19, x19, x18"},
		},
		{
			name:     "btr rax, 5",
			bytes:    []byte{0x48, 0x0f, 0xba, 0xf0, 0x05}, // btr rax, 5
			pc:       0x1000,
			expected: []string{"ubfx x16, x19, #5, #1", "cmp xzr, x16", "bic x19, x19, x18"},
		},
		{
			name:     "blsi eax, ebx",
			bytes:    []byte{0xc4, 0xe2, 0x78, 0xf3, 0xdb}, // blsi eax, ebx
			pc:       0x1000,
			expected: []string{"neg w17, w16", "and w19, w16, w17", "msr nzcv"},
		},
		{
			name:     "shlx eax, ebx, ecx",
			bytes:    []byte{0xc4, 0xe2, 0x69, 0xf7, 0xc3}, // shlx eax, ebx, ecx
			pc:       0x1000,
			expected: []string{"lsl w19, w16, w17"},
		},
		{
			name:     "rorx rax, rbx, 4",
			bytes:    []byte{0xc4, 0xe3, 0xfb, 0xf0, 0xc3, 0x04}, // rorx rax, rbx, 4
			pc:       0x1000,
			expected: []string{"ror x19, x16, #4"},
		},
		{
			name:     "vptest ymm0, ymm1",
			bytes:    []byte{0xc4, 0xe2, 0x7d, 0x17, 0xc1}, // vptest ymm0, ymm1
			pc:       0x1000,
			expected: []string{"and v16.16b, v1.16b, v0.16b", "bic v17.16b, v1.16b, v0.16b", "msr nzcv"},
		},
		{
			name:     "vpmulld xmm0, xmm1, xmm2",
			bytes:    []byte{0xc4, 0xe2, 0x71, 0x40, 0xc2}, // vpmulld xmm0, xmm1, xmm2
			pc:       0x1000,
			expected: []string{"mul v0.4s, v1.4s, v2.4s", "movi v16.16b, #0"},
		},
		{
			name:     "vpmaxud xmm0, xmm1, xmm2",
			bytes:    []byte{0xc4, 0xe2, 0x71, 0x3f, 0xc2}, // vpmaxud xmm0, xmm1, xmm2
			pc:       0x1000,
			expected: []string{"umax v0.4s, v1.4s, v2.4s", "movi v16.16b, #0"},
		},
		{
			name:     "vpmovzxbd ymm0, xmm1",
			bytes:    []byte{0xc4, 0xe2, 0x7d, 0x31, 0xc1}, // vpmovzxbd ymm0, xmm1
			pc:       0x1000,
			expected: []string{"uxtl v31.8h, v1.8b", "uxtl v0.4s, v31.4h", "uxtl2 v16.4s, v31.8h"},
		},
		{
			name:     "vroundps ymm0, ymm1, 1",
			bytes:    []byte{0xc4, 0xe3, 0x7d, 0x08, 0xc1, 0x01}, // vroundps ymm0, ymm1, 1 (floor)
			pc:       0x1000,
			expected: []string{"frintm v0.4s, v1.4s", "frintm v16.4s, v17.4s"},
		},
		{
			name:     "vhsubps xmm0, xmm1, xmm2",
			bytes:    []byte{0xc5, 0xf3, 0x7d, 0xc2}, // vhsubps xmm0, xmm1, xmm2
			pc:       0x1000,
			expected: []string{"uzp1 v28.4s, v1.4s, v2.4s", "uzp2 v29.4s, v1.4s, v2.4s", "fsub v0.4s, v28.4s, v29.4s"},
		},
		{
			name:     "vphaddd xmm0, xmm1, xmm2",
			bytes:    []byte{0xc4, 0xe2, 0x71, 0x02, 0xc2}, // vphaddd xmm0, xmm1, xmm2
			pc:       0x1000,
			expected: []string{"addp v0.4s, v1.4s, v2.4s", "movi v16.16b, #0"},
		},
		{
			name:     "vrcpps ymm0, ymm1",
			bytes:    []byte{0xc4, 0xe1, 0x7c, 0x53, 0xc1}, // vrcpps ymm0, ymm1
			pc:       0x1000,
			expected: []string{"frecpe v0.4s, v1.4s", "frecpe v16.4s, v17.4s"},
		},
		{
			name:     "vmovlpd [rax], xmm0",
			bytes:    []byte{0xc5, 0xf9, 0x13, 0x00}, // vmovlpd [rax], xmm0
			pc:       0x1000,
			expected: []string{"str d0, [x28, x16]"},
		},
		{
			name:     "vpslldq xmm1, xmm1, 4",
			bytes:    []byte{0xc5, 0xf1, 0x73, 0xf9, 0x04}, // vpslldq xmm1, xmm1, 4
			pc:       0x1000,
			expected: []string{"movi v31.16b, #0", "ext v1.16b, v31.16b, v1.16b, #12", "movi v17.16b, #0"},
		},
		{
			name:     "vpalignr xmm0, xmm1, xmm2, 4",
			bytes:    []byte{0xc4, 0xe3, 0x71, 0x0f, 0xc2, 0x04}, // vpalignr xmm0, xmm1, xmm2, 4
			pc:       0x1000,
			expected: []string{"ext v0.16b, v2.16b, v1.16b, #4", "movi v16.16b, #0"},
		},
		{
			name:     "vmovntps [rax], ymm0",
			bytes:    []byte{0xc5, 0xfc, 0x2b, 0x00}, // vmovntps [rax], ymm0
			pc:       0x1000,
			expected: []string{"str q0, [x28, x16]", "str q16, [x28, x16]"},
		},
		{
			name:     "vaddsubps xmm0, xmm1, xmm2",
			bytes:    []byte{0xc5, 0xf3, 0xd0, 0xc2}, // vaddsubps xmm0, xmm1, xmm2
			pc:       0x1000,
			expected: []string{"fsub v28.4s, v1.4s, v2.4s", "fadd v29.4s, v1.4s, v2.4s", "mov v0.s[1], v29.s[1]", "mov v0.s[3], v29.s[3]"},
		},
		{
			name:     "vcvtps2pd ymm0, xmm1",
			bytes:    []byte{0xc5, 0xfd, 0x5a, 0xc1}, // vcvtpd2ps xmm0, ymm1
			pc:       0x1000,
			expected: []string{"fcvtn v0.2s, v1.2d", "fcvtn2 v0.4s, v17.2d"},
		},
		{
			name:     "vcvttpd2dq xmm0, ymm1",
			bytes:    []byte{0xc5, 0xfd, 0xe6, 0xc1}, // vcvttpd2dq xmm0, ymm1
			pc:       0x1000,
			expected: []string{"fcvtzs v28.2d, v1.2d", "fcvtn v0.2s, v28.2d", "fcvtzs v29.2d, v17.2d", "fcvtn2 v0.4s, v29.2d"},
		},
		{
			name:     "cmpxchg16b [rax]",
			bytes:    []byte{0x48, 0x0f, 0xc7, 0x08}, // cmpxchg16b [rax]
			pc:       0x1000,
			expected: []string{"ldaxp x0, x1, [x16]", "stlxp w2, x20, x21, [x16]"},
		},
		{
			name:     "clc",
			bytes:    []byte{0xf8}, // clc
			pc:       0x1000,
			expected: []string{"mrs x16, nzcv", "orr x16, x16, #(1 << 29)", "msr nzcv, x16"},
		},
		{
			name:     "stc",
			bytes:    []byte{0xf9}, // stc
			pc:       0x1000,
			expected: []string{"mrs x16, nzcv", "bic x16, x16, #(1 << 29)", "msr nzcv, x16"},
		},
		{
			name:     "leave",
			bytes:    []byte{0xc9}, // leave
			pc:       0x1000,
			expected: []string{"mov x26, x25", "ldr x25, [x28, x26]", "add x26, x26, #8"},
		},
		{
			name:     "shld eax, ebx, 4",
			bytes:    []byte{0x0f, 0xa4, 0xd8, 0x04}, // shld eax, ebx, 4
			pc:       0x1000,
			expected: []string{"extr w16, w16, w17, #28"},
		},
		{
			name:     "vpslld xmm0, xmm1, xmm2",
			bytes:    []byte{0xc5, 0xf1, 0xf2, 0xc2}, // vpslld xmm0, xmm1, xmm2
			pc:       0x1000,
			expected: []string{"fmov x16, d2", "ushl v0.4s, v1.4s, v31.4s", "movi v16.16b, #0"},
		},
		{
			name:     "vpavgw xmm0, xmm1, xmm2",
			bytes:    []byte{0xc5, 0xf1, 0xe3, 0xc2}, // vpavgw xmm0, xmm1, xmm2
			pc:       0x1000,
			expected: []string{"urhadd v0.8h, v1.8h, v2.8h", "movi v16.16b, #0"},
		},
		{
			name:     "vpabsd xmm0, xmm1",
			bytes:    []byte{0xc4, 0xe2, 0x79, 0x1e, 0xc1}, // vpabsd xmm0, xmm1
			pc:       0x1000,
			expected: []string{"abs v0.4s, v1.4s", "movi v16.16b, #0"},
		},
		{
			name:     "vpsadbw xmm0, xmm1, xmm2",
			bytes:    []byte{0xc5, 0xf1, 0xf6, 0xc2}, // vpsadbw xmm0, xmm1, xmm2
			pc:       0x1000,
			expected: []string{"uabd v28.16b, v1.16b, v2.16b", "uaddlp v29.8h, v28.16b", "uaddlp v28.4s, v29.8h", "uaddlp v29.2d, v28.4s"},
		},
		{
			name:     "vpmaddwd xmm0, xmm1, xmm2",
			bytes:    []byte{0xc5, 0xf1, 0xf5, 0xc2}, // vpmaddwd xmm0, xmm1, xmm2
			pc:       0x1000,
			expected: []string{"smull v28.4s, v1.4h, v2.4h", "smull2 v29.4s, v1.8h, v2.8h", "addp v28.4s, v28.4s, v28.4s"},
		},
		{
			name:     "fldz",
			bytes:    []byte{0xd9, 0xee}, // fldz
			pc:       0x1000,
			expected: []string{"fmov d0, xzr", "add  x16, x27, #0x70", "str  w17, [x16, #0x2e0]"},
		},
		{
			name:     "fld1",
			bytes:    []byte{0xd9, 0xe8}, // fld1
			pc:       0x1000,
			expected: []string{"fmov d0, #1.0", "add  x16, x27, #0x70"},
		},
		{
			name:     "fstp st(0)",
			bytes:    []byte{0xdd, 0xd8}, // fstp st(0)
			pc:       0x1000,
			expected: []string{"add  w17, w17, #1", "str  w17, [x16, #0x2e0]"},
		},
		{
			name:     "fxch st(1)",
			bytes:    []byte{0xd9, 0xc9}, // fxch st(1)
			pc:       0x1000,
			expected: []string{"ldr  w17, [x16, #0x2e0]", "add  w17, w17, #1"},
		},
		{
			name:     "faddp st(1), st(0)",
			bytes:    []byte{0xde, 0xc1}, // faddp st(1), st(0)
			pc:       0x1000,
			expected: []string{"fadd d0, d0, d1", "add  w17, w17, #1"},
		},
		{
			name:     "fchs",
			bytes:    []byte{0xd9, 0xe0}, // fchs
			pc:       0x1000,
			expected: []string{"fneg d0, d0"},
		},
		{
			name:     "pxor mm0, mm0",
			bytes:    []byte{0x0f, 0xef, 0xc0},
			pc:       0x1000,
			expected: []string{"str xzr, [x18, #752]"},
		},
		{
			name:     "movq mm1, [rsi]",
			bytes:    []byte{0x0f, 0x6f, 0x0e},
			pc:       0x1000,
			expected: []string{"ldr x17, [x28, x16]", "str x17, [x18, #760]"},
		},
		{
			name:     "pmullw mm1, mm2",
			bytes:    []byte{0x0f, 0xd5, 0xca},
			pc:       0x1000,
			expected: []string{"ldr d16, [x18, #760]", "ldr d17, [x18, #768]", "mul v16.4h, v16.4h, v17.4h"},
		},
		{
			name:     "movsd string",
			bytes:    []byte{0xa5},
			pc:       0x1000,
			expected: []string{"ldr w16, [x28, x23]", "str w16, [x28, x24]"},
		},
		{
			name:     "cmpsd string",
			bytes:    []byte{0xa7},
			pc:       0x1000,
			expected: []string{"ldr w16, [x28, x23]", "ldr w17, [x28, x24]", "cmp w16, w17"},
		},
		{
			name:     "rep movsb",
			bytes:    []byte{0xf3, 0xa4},
			pc:       0x1000,
			expected: []string{"cbz x21", "ldrb w16, [x28, x23]", "strb w16, [x28, x24]"},
		},
		{
			name:     "rep stosd",
			bytes:    []byte{0xf3, 0xab},
			pc:       0x1000,
			expected: []string{"cbz x21", "str w19, [x28, x24]"},
		},
		{
			name:     "int 3",
			bytes:    []byte{0xcc},
			pc:       0x1000,
			expected: []string{"brk #0"},
		},
		{
			name:     "int 0x80",
			bytes:    []byte{0xcd, 0x80},
			pc:       0x1000,
			expected: []string{"brk #0"},
		},
		{
			name:     "emms",
			bytes:    []byte{0x0f, 0x77},
			pc:       0x1000,
			expected: []string{"// emms"},
		},
		{
			name:     "xorps xmm0, [rcx]",
			bytes:    []byte{0x0f, 0x57, 0x01},
			pc:       0x1000,
			expected: []string{"ldr q16, [x28, x16]", "eor v0.16b, v0.16b, v16.16b"},
		},
		{
			name:     "vpermilps ymm0, ymm1, ymm2",
			bytes:    []byte{0xc4, 0xe2, 0x75, 0x0c, 0xc2},
			pc:       0x1000,
			expected: []string{"tbl v0.16b, {v1.16b}, v23.16b", "tbl v16.16b, {v17.16b}, v23.16b"},
		},
		{
			name:     "ldmxcsr [rcx]",
			bytes:    []byte{0x0f, 0xae, 0x11},
			pc:       0x1000,
			expected: []string{"ldr w18, [x28, x16]", "str w18, [x17, #0x2ec]"},
		},
		{
			name:     "stmxcsr [rdx]",
			bytes:    []byte{0x0f, 0xae, 0x1a},
			pc:       0x1000,
			expected: []string{"ldr w18, [x17, #0x2ec]", "str w18, [x28, x16]"},
		},
		{
			name:     "pmaddubsw x0, x5",
			bytes:    []byte{0x66, 0x0f, 0x38, 0x04, 0xc5},
			pc:       0x1000,
			expected: []string{"uxtl v20.8h, v0.8b", "sxtl v21.8h, v5.8b", "sqadd v25.4h"},
		},
		{
			name:     "pmuldq x0, x3",
			bytes:    []byte{0x66, 0x0f, 0x38, 0x28, 0xc3},
			pc:       0x1000,
			expected: []string{"smull v0.2d, v20.2s, v21.2s"},
		},
		{
			name:     "pmulhw x1, x4",
			bytes:    []byte{0x66, 0x0f, 0xe5, 0xcc},
			pc:       0x1000,
			expected: []string{"smull  v20.4s, v1.4h, v4.4h", "uzp2   v1.8h, v20.8h, v21.8h"},
		},
		{
			name:     "pushfq",
			bytes:    []byte{0x9c},
			pc:       0x1000,
			expected: []string{"mrs  x16, nzcv", "sub  x26, x26, #8", "str  x17, [x28, x26]"},
		},
		{
			name:     "popfq",
			bytes:    []byte{0x9d},
			pc:       0x1000,
			expected: []string{"ldr  x17, [x28, x26]", "add  x26, x26, #8", "msr  nzcv, x16"},
		},
		{
			name:     "xlatb",
			bytes:    []byte{0xd7},
			pc:       0x1000,
			expected: []string{"uxtb w16, w19", "add  x16, x20, x16", "ldrb w16, [x28, x16]"},
		},
		{
			name:     "lret",
			bytes:    []byte{0xcb},
			pc:       0x1000,
			expected: []string{"ldr x30, [sp], #16", "ret"},
		},
		{
			name:     "fscale",
			bytes:    []byte{0xd9, 0xfd},
			pc:       0x1000,
			expected: []string{"frintz d1, d1", "fmul  d0, d0, d2"},
		},
		{
			name:     "fprem1",
			bytes:    []byte{0xd9, 0xf5},
			pc:       0x1000,
			expected: []string{"fdiv   d2, d0, d1", "fnmsub d0, d2, d1, d0"},
		},
		{
			name:     "vaesenc x0, x0, x1",
			bytes:    []byte{0xc4, 0xe2, 0x79, 0xdc, 0xc1},
			pc:       0x1000,
			expected: []string{"aese  v21.16b, v20.16b", "aesmc v21.16b, v21.16b", "eor   v0.16b, v21.16b, v1.16b"},
		},
		{
			name:     "vaesenclast x0, x0, x1",
			bytes:    []byte{0xc4, 0xe2, 0x79, 0xdd, 0xc1},
			pc:       0x1000,
			expected: []string{"aese  v21.16b, v20.16b", "eor   v0.16b, v21.16b, v1.16b"},
		},
		{
			name:     "cwd",
			bytes:    []byte{0x66, 0x99},
			pc:       0x1000,
			expected: []string{"sxth w16, w19", "asr  w16, w16, #16", "bfi  x22, x16, #0, #16"},
		},
		{
			name:     "enter 0, 0",
			bytes:    []byte{0xc8, 0x00, 0x00, 0x00},
			pc:       0x1000,
			expected: []string{"sub  x26, x26, #8", "str  x25, [x28, x26]", "mov  x25, x26"},
		},
		{
			name:     "crc32 rax, rbx",
			bytes:    []byte{0xf2, 0x48, 0x0f, 0x38, 0xf1, 0xc3},
			pc:       0x1000,
			expected: []string{"crc32cx w19, w17, x16"},
		},
		{
			name:     "rcl rdi, 1",
			bytes:    []byte{0x48, 0xd1, 0xd7},
			pc:       0x1000,
			expected: []string{"mrs  x18, nzcv", "ubfx w19, w18, #29, #1", "lsr  x20, x16, #63", "bfi  x18, x19, #29, #1", "msr  nzcv, x18"},
		},
		{
			name:     "fcos",
			bytes:    []byte{0xd9, 0xff},
			pc:       0x1000,
			expected: []string{"bl   _cos"},
		},
		{
			name:     "frndint",
			bytes:    []byte{0xd9, 0xfc},
			pc:       0x1000,
			expected: []string{"frinti d0, d0"},
		},
		{
			name:     "vpclmulqdq x0, x1, x2, 0",
			bytes:    []byte{0xc4, 0xe3, 0x71, 0x44, 0xc2, 0x00},
			pc:       0x1000,
		},
		{
			name:     "sar al, 7",
			bytes:    []byte{0xc0, 0xf8, 0x07}, // sar al, 7
			pc:       0x1000,
			expected: []string{"sxtb w16, w16", "asr w16, w16, #7"},
		},
		{
			name:     "vpcmpistri x1, x0, 0",
			bytes:    []byte{0xc4, 0xe3, 0x79, 0x63, 0xc8, 0x00},
			pc:       0x1000,
			expected: []string{
				"stp  x8,  x9,  [sp, #32]",
				"stp  x10, x11, [sp, #48]",
				"stp  x12, x13, [sp, #64]",
				"stp  x14, x15, [sp, #80]",
				"bl   _recomp_vpcmpistri",
				"ldp  x8,  x9,  [sp, #32]",
				"ldp  x10, x11, [sp, #48]",
				"ldp  x12, x13, [sp, #64]",
				"ldp  x14, x15, [sp, #80]",
			},
		},
	}

	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			lifter.lastFlagOp = 0
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
