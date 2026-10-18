// SPDX-License-Identifier: GPL-2.0-or-later
/*
 * PS4Recomp - persistent cache of GCN shader translations (see ps4_gnm_shader_cache.mm).
 *
 * Translating a GCN program (gcn_compile: GCN -> SPIR-V -> MSL) costs 1-20 ms and used to run
 * the first time every shader permutation appeared in each session. Translated shaders are
 * stored as gcn_shader_serialize() blobs under
 *   ~/Library/Caches/PS4Recomp/<title>/gcn/<config hash>/<key>_<content>.gsc
 * and recreated with gcn_shader_deserialize() instead of translating again.
 *
 * Environment:
 *   PS4_GNM_NO_SHADER_CACHE   disable every on-disk shader cache (MSL and GCN)
 *   PS4_GNM_NO_GCN_CACHE      disable only this cache
 *   PS4_GNM_GCN_CACHE_VERIFY  translate every cache hit again and compare (debug)
 */
#pragma once

#include <stdint.h>
#include <string>

#include "gcn_recompiler.h"

namespace ps4gnm_shader_cache {

// Identifies the inputs of one translation that are known before translating: stage, program
// bytes and register-derived runtime info. The rest (bound resource properties) is checked per
// cached permutation with gcn_shader_is_compatible().
struct Key {
    uint64_t bucket = 0;     // hash of everything below; first part of the file name
    uint32_t hw = 0, sw = 0;
    uint32_t code_size = 0;
    uint64_t code_hash[2] = {0, 0}; // two independent 64-bit hashes of the program bytes
    gcn_runtime_info rt{};
};

// Opens (and creates) the cache of this title and configuration and starts reading its entries
// on a background thread.
void Start(const gcn_profile& profile, const gcn_msl_options& msl);
bool Enabled();
bool VerifyMode();

// Builds the key of the program at code_addr (reads its code through `read`). False when the
// program has no OrbShdr footer or is not readable (such shaders are not cached).
bool MakeKey(gcn_hw_stage hw, gcn_sw_stage sw, const gcn_runtime_info& rt, uint64_t code_addr,
             gcn_read_guest_fn read, void* ctx, Key* out);

// A new shader for code_addr from a cached permutation compatible with this draw, or nullptr.
// Entries of the key that the background loader has not reached yet are loaded here.
gcn_shader* Lookup(const Key& key, uint64_t code_addr, const uint32_t ud[16],
                   gcn_read_guest_fn read, void* ctx);

// Stores a freshly translated shader (any thread). The file is written asynchronously.
void Store(const Key& key, const gcn_shader* sh);

// Debug: true if two shaders give identical results through the whole query API.
bool SameTranslation(const gcn_shader* a, const gcn_shader* b, std::string* why);

// One-line statistics ("[gnm-cache] ...") since the previous call.
void PrintStats();

// Size limit of each on-disk shader cache (GCN translations, MSL sources): when a directory
// exceeds it at startup, the least recently used files (by modification time; MarkUsed()
// refreshes it) are removed down to 3/4 of it. PS4_GNM_SHADER_CACHE_MB overrides the default.
uint64_t BudgetBytes(uint64_t default_mb);
void PruneDir(const std::string& dir, const char* suffix, uint64_t budget_bytes, const char* what);
// Records that a cache file was used in this session (asynchronously; at most once per file).
void MarkUsed(const std::string& path);

} // namespace ps4gnm_shader_cache
