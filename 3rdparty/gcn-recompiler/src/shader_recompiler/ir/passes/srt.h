// SPDX-FileCopyrightText: Copyright 2024 shadPS4 Emulator Project
// SPDX-License-Identifier: GPL-2.0-or-later
//
// Modified for PS4Recomp's standalone gcn-recompiler: the x86-64 JIT walker function pointer is
// replaced by a portable bytecode program interpreted by RunSrtProgram().

#pragma once

#include <boost/container/set.hpp>
#include <boost/container/small_vector.hpp>
#include <span>
#include <vector>
#include "common/types.h"

namespace Serialization {
struct Archive;
}

namespace Shader {

// Portable SRT walker bytecode. Operands follow the opcode word.
// Pointer ops read a 64-bit guest pointer (masked to 48 bits) and push the previous one.
// Value ops work on a 32-bit value stack (dynamic offsets, in dwords).
enum class SrtOp : u32 {
    End = 0,
    PushPtrUd,  // sgpr: cur = user_data[sgpr] | user_data[sgpr+1] << 32
    PushPtrImm, // off_dw: cur = *(u64*)(cur + off_dw*4)
    PushPtrDyn, // (pop off_dw): cur = *(u64*)(cur + off_dw*4)
    PopPtr,
    CopyImm, // src_off_dw, dst: flat[dst] = *(u32*)(cur + src_off_dw*4)
    CopyDyn, // dst, (pop src_off_dw): flat[dst] = *(u32*)(cur + src_off_dw*4)
    LoadFlat, // idx: push flat[idx]
    Imm,      // value: push value
    Add, Sub, Mul, Shl, Shr, And, Or, Xor, Not, UMin, UMax,
    BfeU, // pop count, offset, base: push (base >> offset) & ((1 << count) - 1)
    // PS4Recomp: dst: flat[dst] = low dword of cur, flat[dst + 1] = bits 32..43 (V# dwords
    // 0-1 with stride 0). The pointer becomes the base of a guest buffer for reads whose
    // offset only the shader knows.
    StorePtr,
};

// Guest memory reader: copy `size` bytes at guest address `addr` into `dst`.
// Return false if the address is not mapped (the destination is then treated as zero).
using SrtReadFn = bool (*)(void* ctx, u64 addr, void* dst, u64 size);

// Guest memory the host maps as one host range (gcn_set_direct_guest_memory): reads through
// that reader are done here instead of calling it for every dword.
struct SrtDirectMemory {
    SrtReadFn read{};
    void* ctx{};
    const u8* base{};
    u64 size{};
};
extern SrtDirectMemory g_srt_direct;

// Same contract as calling read(ctx, ...): false for address 0 or an unmapped range.
inline bool SrtRead(SrtReadFn read, void* ctx, u64 addr, void* dst, u64 size) {
    const SrtDirectMemory& d = g_srt_direct;
    if (read && read == d.read && ctx == d.ctx) {
        if (addr == 0 || addr >= d.size || size > d.size - addr) return false;
        __builtin_memcpy(dst, d.base + addr, size);
        return true;
    }
    return read && read(ctx, addr, dst, size);
}

// Runs the walker. flat_dst must hold flattened_bufsize_dw dwords with the user data
// already copied to the first NUM_USER_DATA_REGS dwords. Returns false if any read failed.
bool RunSrtProgram(std::span<const u32> program, const u32* user_data, u32* flat_dst,
                   SrtReadFn read, void* read_ctx);

struct PersistentSrtInfo {
    // Special case when fetch shader uses step rates.
    struct SrtSharpReservation {
        u32 sgpr_base;
        u32 dword_offset;
        u32 num_dwords;
    };

    std::vector<u32> program{}; // empty when the shader has no extended user data
    u32 flattened_bufsize_dw = 16; // NumUserDataRegs

    void Serialize(Serialization::Archive& ar) const;
    bool Deserialize(Serialization::Archive& ar);
};

} // namespace Shader
