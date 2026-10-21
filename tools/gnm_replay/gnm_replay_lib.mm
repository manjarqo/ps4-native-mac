// SPDX-License-Identifier: GPL-2.0-or-later
// PS4Recomp - replay of one captured pass (see gnm_replay.h); the gnm_replay tool is gnm_replay.mm.
#import <Foundation/Foundation.h>

#include "gnm_replay.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/stat.h>

#include <algorithm>

#include "gcn_recompiler.h"
#include "gcn_stores.h"
#include "ps4_gnm_capture.h"
#include "ps4_gnm_draw.h"

extern "C" int32_t g_replay_neo; // replay_links.c: sceKernelIsNeoMode() of the replay

namespace ps4replay {
using namespace ps4gnm_capture;

namespace {

uint8_t* g_mem = nullptr;
uint64_t g_mem_size = 0;
bool g_neo = false;
GuestContext g_ctx;
std::vector<std::pair<uint64_t, uint64_t>> g_loaded; // ranges the last call wrote

bool PrepareProcess(const FrameRec& f, Result* r) {
    if (g_mem) {
        if (f.mem_size != g_mem_size || f.neo != g_neo) {
            r->error = "frames of one process must share mem_size and neo mode";
            return false;
        }
        return true;
    }
    // what the game's renderer runs with, minus everything that would read or write state
    // outside this process (shader caches, pipeline archive, library store)
    setenv("PS4_GNM_SYNC_ENCODE", "1", 1);
    setenv("PS4_GNM_SYNC_COMPILE", "1", 1);
    setenv("PS4_GNM_NO_SHADER_CACHE", "1", 1);
    setenv("PS4_GNM_NO_PSO_ARCHIVE", "1", 1);
    setenv("PS4_GNM_NO_LIB_STORE", "1", 1);
    setenv("PS4_GNM_MEM_LOG", "0", 1);
    unsetenv("PS4_GNM_CAPTURE_FRAME");
    void* m = mmap(nullptr, f.mem_size, PROT_READ | PROT_WRITE, MAP_ANON | MAP_PRIVATE | MAP_NORESERVE, -1, 0);
    if (m == MAP_FAILED) {
        r->error = "cannot reserve guest memory of the capture's size";
        return false;
    }
    g_mem = (uint8_t*)m;
    g_mem_size = f.mem_size;
    g_neo = f.neo;
    g_replay_neo = f.neo ? 1 : 0;
    memset(&g_ctx, 0, sizeof(g_ctx));
    g_ctx.mem_base = g_mem;
    g_ctx.mem_size = g_mem_size;
    if (!ps4draw::Init(&g_ctx)) {
        r->error = "the renderer did not start (no Metal device, or PS4_GNM_METAL_DRAW=0)";
        return false;
    }
    return true;
}

bool LoadBlob(const std::string& dir, const BlobRef& b, Result* r) {
    if (b.file.empty()) {
        char m[96];
        snprintf(m, sizeof(m), "guest range 0x%llx+0x%llx was not stored (over the snapshot limit)",
                 (unsigned long long)b.addr, (unsigned long long)b.size);
        r->error = m;
        return false;
    }
    std::vector<uint8_t> d;
    if (!ReadFile(dir + "/" + b.file, &d) || d.size() != b.size || b.addr + b.size > g_mem_size) {
        r->error = "cannot load " + b.file;
        return false;
    }
    memcpy(g_mem + b.addr, d.data(), d.size());
    // a CPU write of guest memory, as the game reports one: cached sampled textures re-upload
    ps4draw::NotifyGuestWrite(b.addr, b.size, false, 0);
    g_loaded.push_back({b.addr, b.size});
    return true;
}

// The replayed bytes of an output, compared with the capture's when it holds them.
void AddOutput(const Options& opt, OutputResult o, const uint8_t* got, size_t got_n, const std::vector<uint8_t>* want,
               Result* r) {
    if (want) {
        o.compared = true;
        o.size = want->size();
        const size_t n = std::min(got_n, want->size());
        for (size_t i = 0; i < n; ++i)
            if (got[i] != (*want)[i]) {
                if (!o.diff_bytes) o.first_diff = i;
                o.diff_bytes++;
            }
        if (got_n != want->size()) {
            if (!o.diff_bytes) o.first_diff = n;
            o.diff_bytes += (uint64_t)std::max(got_n, want->size()) - n;
        }
        o.match = o.diff_bytes == 0;
    }
    if (!opt.out_dir.empty()) {
        mkdir(opt.out_dir.c_str(), 0755);
        std::string name = o.is_texture ? o.what : "buf_" + o.what.substr(7); // "buffer 0x.." -> "buf_0x.."
        WriteFile(opt.out_dir + "/" + name + (o.is_texture ? ".raw" : ".bin"), got, got_n);
        std::vector<uint8_t> rgb;
        std::string mode;
        if (o.is_texture && ToViewRgb8(o.tex, got, got_n, &rgb, &mode))
            WritePngRgb8(opt.out_dir + "/" + name + ".png", o.tex.mtl_width, o.tex.mtl_height, rgb);
    }
    if (opt.keep_outputs) o.bytes.assign(got, got + got_n);
    r->outputs.push_back(std::move(o));
}

} // namespace

Result ReplayPass(const Options& o) {
    Result r;
    FrameRec f;
    std::string err;
    if (!LoadFrame(o.frame_dir, &f, &err)) return r.error = err, r;
    if (o.pass >= f.passes.size() || f.passes[o.pass].index != o.pass) {
        r.error = "no pass " + std::to_string(o.pass) + " in " + o.frame_dir;
        return r;
    }
    const PassRec& p = f.passes[o.pass];
    if (!p.skipped.empty()) return r.error = "the renderer encoded nothing for this pass: " + p.skipped, r;
    if (!p.replayable) return r.error = "pass not stored replayable (PS4_GNM_CAPTURE_REPLAY)", r;
    for (const TextureRec& t : p.textures)
        if (!t.readback.empty()) return r.error = "contents of " + t.role + " were not captured: " + t.readback, r;
    if (f.gcn_cache_id != gcn_shader_cache_id())
        r.notes.push_back("captured with another gcn-recompiler build: translation differences show as mismatches");
    if (!PrepareProcess(f, &r)) return r;

    // guest memory: zero what the previous call loaded, then this pass's snapshots
    for (auto& [a, n] : g_loaded) {
        memset(g_mem + a, 0, n);
        ps4draw::NotifyGuestWrite(a, n, false, 0);
    }
    g_loaded.clear();
    for (const BlobRef& b : p.inputs)
        if (!LoadBlob(o.frame_dir, b, &r)) return r;
    // GPU-owned textures as they were before the pass
    for (const TextureRec& t : p.textures) {
        if (t.pre_file.empty()) continue; // created by the pass itself (from guest memory)
        std::vector<uint8_t> raw;
        if (!ReadFile(o.frame_dir + "/" + t.pre_file, &raw) || raw.size() != RawSize(t.id))
            return r.error = "cannot load " + t.pre_file, r;
        if (!ps4draw::ReplayAdoptTexture(t.id, &raw)) return r.error = "cannot create the texture of " + t.role, r;
    }
    for (uint64_t a : p.meta_cleared) ps4draw::ReplaySetMetaCleared(a);
    std::vector<uint32_t> regs;
    if (!LoadRegs(o.frame_dir, p.regs_file, &regs, &err)) return r.error = err, r;

    const uint64_t skipped0 = ps4draw::SkippedCount();
    ps4draw::SetExtentHints(p.cb_extent, p.db_extent);
    if (p.type == "draw") {
        ps4draw::DrawArgs a;
        a.indexed = p.indexed;
        a.index_base = p.index_base;
        a.index_type = p.index_type;
        a.index_offset = p.index_offset;
        a.count = p.count;
        a.max_index = p.max_index;
        a.num_instances = p.num_instances;
        a.name = p.name.c_str();
        a.indirect_addr = p.indirect_addr;
        a.base_vertex_ud = p.base_vertex_ud;
        a.start_instance_ud = p.start_instance_ud;
        if (!ps4draw::Draw(&g_ctx, regs.data(), a))
            return r.error = "Draw refused the indirect draw (the CPU fallback is a different pass)", r;
    } else if (p.type == "dispatch") {
        ps4draw::Dispatch(&g_ctx, regs.data(), p.dim[0], p.dim[1], p.dim[2], p.indirect_addr, p.queue.c_str());
    } else {
        return r.error = "unknown pass type " + p.type, r;
    }
    ps4draw::Flush(true);
    if (ps4draw::SkippedCount() != skipped0) return r.error = "the renderer skipped the pass (see the [gnm-draw] log)", r;
    r.ran = true;

    for (const TextureRec& t : p.textures) {
        if (!t.written) continue;
        OutputResult out;
        out.what = t.role;
        out.is_texture = true;
        out.tex = t.id;
        std::vector<uint8_t> want, got;
        const bool have = !t.post_file.empty() && ReadFile(o.frame_dir + "/" + t.post_file, &want);
        if (!ps4draw::ReplayReadTexture(t.id, &got)) {
            out.what += " (the renderer made no texture with the captured identity)";
            out.compared = have;
            out.size = out.diff_bytes = want.size();
            r.outputs.push_back(std::move(out));
            continue;
        }
        AddOutput(o, std::move(out), got.data(), got.size(), have ? &want : nullptr, &r);
    }
    for (const BufferRec& b : p.buffers) {
        if (!b.written) continue;
        OutputResult out;
        char what[64];
        snprintf(what, sizeof(what), "buffer 0x%llx", (unsigned long long)b.addr);
        out.what = what;
        out.addr = b.addr;
        std::vector<uint8_t> want;
        bool have = false;
        for (const BlobRef& ob : p.outputs)
            if (ob.addr == b.addr && ob.size == b.size && !ob.file.empty())
                have = ReadFile(o.frame_dir + "/" + ob.file, &want);
        AddOutput(o, std::move(out), g_mem + b.addr, b.size, have ? &want : nullptr, &r);
        g_loaded.push_back({b.addr, b.size});
    }
    if (r.outputs.empty()) {
        // nothing recorded as written: say what the shaders' code can write (memory the renderer
        // does not track, or stores the translation dropped, would not show up as an output)
        for (const StageRec& s : p.stages) {
            if (!s.code_size || s.code_addr + s.code_size > g_mem_size) continue;
            const GcnStores st = ScanGcnStores((const uint32_t*)(g_mem + s.code_addr), s.code_size / 4);
            char m[256];
            snprintf(m, sizeof(m), "%s 0x%llx: no output recorded; its GCN code has %s%s", s.stage.c_str(),
                     (unsigned long long)s.code_addr, st.Describe().c_str(),
                     st.complete ? "" : " (scan stopped at an unknown encoding)");
            r.notes.push_back(m);
        }
    }
    return r;
}

} // namespace ps4replay
