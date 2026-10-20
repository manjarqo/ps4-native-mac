// SPDX-FileCopyrightText: Copyright 2026 PS4Recomp contributors
// SPDX-License-Identifier: GPL-2.0-or-later

#pragma once

#include <cstdint>
#include <map>
#include <string>
#include <vector>
#include "gcn_recompiler.h"

namespace GcnMsl {

// SPIR-V (set 0) binding -> MSL slot(s) chosen by SPIRV-Cross automatic assignment.
struct Bindings {
    std::map<uint32_t, std::vector<uint32_t>> buffers; // aliases share one SPIR-V binding
    std::map<uint32_t, uint32_t> textures;             // first slot (arrays take consecutive)
    std::map<uint32_t, uint32_t> samplers;
    int32_t push_constant_buffer = -1;
    uint32_t first_free_buffer = 0;
    uint32_t num_textures = 0;
    uint32_t num_samplers = 0;
    // Storage buffers moved into the set 0 argument buffer (only when the discrete slots would
    // exceed gcn_msl_options.max_buffer_slots): SPIR-V binding -> [[id(n)]] entry index.
    std::map<uint32_t, uint32_t> arg_entries;
    int32_t argument_buffer = -1; // [[buffer(n)]] of the argument buffer, -1 if none
    uint32_t num_arg_entries = 0;
};

// arg_candidates: SPIR-V bindings of storage buffers that may be reached through an argument
// buffer (guest memory buffers). nullptr disables the argument buffer fallback.
bool Convert(const std::vector<uint32_t>& spirv, const gcn_msl_options& opt, std::string& out,
             std::string& err, Bindings* bindings,
             const std::vector<uint32_t>* arg_candidates = nullptr);

} // namespace GcnMsl
