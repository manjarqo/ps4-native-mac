// SPDX-License-Identifier: GPL-2.0-or-later
// PS4Recomp - memory-writing instructions in a GCN (Sea Islands) program, for replay diagnostics:
// a pass whose capture records no output may still write memory the renderer does not track
// (gnm_replay prints what this finds). Walks the instruction stream by encoding (sizes and
// literal constants as in the Sea Islands ISA) to the end of the code: a program can have several
// s_endpgm (early exits), so the first one does not end the scan.
//
// The scan runs only for passes with no recorded output (gnm_replay_lib.mm ReplayPass): it is a
// diagnostic for "why is there nothing to compare", not part of the comparison.
#pragma once

#include <stddef.h>
#include <stdint.h>

#include <string>

namespace ps4replay {

struct GcnStores {
    uint32_t buffer = 0, tbuffer = 0, image = 0, flat = 0; // stores and atomics
    bool complete = false; // reached the end of the code without an unknown encoding
    uint32_t Total() const { return buffer + tbuffer + image + flat; }
    std::string Describe() const {
        std::string s;
        auto add = [&](uint32_t n, const char* what) {
            if (!n) return;
            if (!s.empty()) s += ", ";
            s += std::to_string(n) + " " + what;
        };
        add(buffer, "buffer_store/atomic");
        add(tbuffer, "tbuffer_store");
        add(image, "image_store/atomic");
        add(flat, "flat_store/atomic");
        return s.empty() ? "none" : s;
    }
};

// `dwords` dwords of code. Counts instructions that can write guest memory (DS, which writes LDS
// or GDS, is not counted).
inline GcnStores ScanGcnStores(const uint32_t* code, size_t dwords) {
    GcnStores r;
    size_t i = 0;
    while (i < dwords) {
        const uint32_t w = code[i];
        size_t len = 1;
        bool literal = false;
        if ((w >> 23) == 0x17F) { // SOPP
            // s_endpgm and the other SOPP are one dword: no literal, nothing to count
        } else if ((w >> 23) == 0x17E) { // SOPC
            literal = (w & 0xFF) == 255 || ((w >> 8) & 0xFF) == 255;
        } else if ((w >> 23) == 0x17D) { // SOP1
            literal = (w & 0xFF) == 255;
        } else if ((w >> 28) == 0xB) { // SOPK
            literal = ((w >> 23) & 0x1F) == 21; // s_setreg_imm32_b32
        } else if ((w >> 30) == 0x2) { // SOP2
            literal = (w & 0xFF) == 255 || ((w >> 8) & 0xFF) == 255;
        } else if ((w >> 27) == 0x18) { // SMRD
            literal = !((w >> 8) & 1) && (w & 0xFF) == 255;
        } else if ((w >> 25) == 0x3F || (w >> 25) == 0x3E) { // VOP1, VOPC
            literal = (w & 0x1FF) == 255;
        } else if ((w >> 31) == 0) { // VOP2
            const uint32_t op = (w >> 25) & 0x3F;
            literal = (w & 0x1FF) == 255 || op == 32 || op == 33; // v_madmk / v_madak
        } else {
            const uint32_t enc = w >> 26;
            len = 2;
            switch (enc) {
            case 0x34: break; // VOP3
            case 0x32: len = 1; break; // VINTRP
            case 0x36: break; // DS (LDS / GDS: not memory a pass outputs)
            case 0x38: { // MUBUF: stores 4-7, 24-31; atomics 48-96 (FMAX_X2)
                const uint32_t op = (w >> 18) & 0x7F;
                if ((op >= 4 && op <= 7) || (op >= 24 && op <= 31) || (op >= 48 && op <= 96)) r.buffer++;
                break;
            }
            case 0x3A: { // MTBUF: tbuffer_store_format 4-7
                const uint32_t op = (w >> 16) & 7;
                if (op >= 4) r.tbuffer++;
                break;
            }
            case 0x3C: { // MIMG: image_store 8-11, atomics 15-31
                const uint32_t op = (w >> 18) & 0x7F;
                if ((op >= 8 && op <= 11) || (op >= 15 && op <= 31)) r.image++;
                break;
            }
            case 0x37: { // FLAT: stores 24-31, atomics 48-96 (FMAX_X2)
                const uint32_t op = (w >> 18) & 0x7F;
                if ((op >= 24 && op <= 31) || (op >= 48 && op <= 96)) r.flat++;
                break;
            }
            case 0x3E: break; // EXP
            default: return r; // unknown encoding: stop (complete stays false)
            }
        }
        i += len + (literal ? 1 : 0);
    }
    r.complete = true;
    return r;
}

} // namespace ps4replay
