// SPDX-License-Identifier: GPL-2.0-or-later
// PS4Recomp - replay of one captured pass (see gnm_replay.h); the gnm_replay tool is gnm_replay.mm.
#import <Foundation/Foundation.h>

#include "gnm_replay.h"

#include <pthread.h>
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

// The guest's VM extents as the replay knows them: the pass's guest memory snapshots and the
// images the captured draw bound are mapped, the rest of guest memory is free. The renderer treats
// a T# table entry at a provably unmapped address (a free extent) as unbound
// (gcn_set_image_address_check); in the game such entries were not bound and left no image
// record, so they stay unbound here too.
void SetMappedRanges(const PassRec& p) {
    std::vector<std::pair<uint64_t, uint64_t>> ranges; // [first page, end page) in bytes
    auto add = [&](uint64_t a, uint64_t n) {
        if (!n || a >= g_mem_size) return;
        const uint64_t end = std::min(g_mem_size, (a + n + 0xFFF) & ~0xFFFull);
        ranges.push_back({a & ~0xFFFull, end});
    };
    for (const BlobRef& b : p.inputs) add(b.addr, b.size);
    for (const ImageRec& im : p.images) add(im.addr, 1);
    std::sort(ranges.begin(), ranges.end());
    pthread_mutex_lock(&g_ctx.vm_mutex);
    for (GuestVMExtent* e = g_ctx.vm_extents; e;) {
        GuestVMExtent* next = e->next;
        free(e);
        e = next;
    }
    GuestVMExtent head{};
    GuestVMExtent* tail = &head;
    auto append = [&](uint64_t a, uint64_t end, bool is_free) {
        GuestVMExtent* e = (GuestVMExtent*)calloc(1, sizeof(GuestVMExtent));
        e->addr = a;
        e->size = end - a;
        e->is_free = is_free;
        e->prot = is_free ? 0 : PROT_READ | PROT_WRITE;
        e->prev = tail == &head ? nullptr : tail;
        tail->next = e;
        tail = e;
    };
    uint64_t at = 0;
    for (size_t i = 0; i < ranges.size();) {
        uint64_t a = ranges[i].first, end = ranges[i].second;
        for (++i; i < ranges.size() && ranges[i].first <= end; ++i) end = std::max(end, ranges[i].second);
        if (a > at) append(at, a, true);
        append(a, end, false);
        at = end;
    }
    if (at < g_mem_size) append(at, g_mem_size, true);
    g_ctx.vm_extents = head.next;
    recomp_vm_note_change();
    pthread_mutex_unlock(&g_ctx.vm_mutex);
}

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
    g_ctx.process_ctx = &g_ctx;
    pthread_mutex_init(&g_ctx.vm_mutex, nullptr);
    SetMappedRanges(PassRec{}); // a VM extent list from the start (SetMappedRanges per pass)
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
    // a texture without its contents before the pass cannot be seeded; one whose contents after the
    // pass went over the raw budget (its pre file stored) replays, and that output is reported as not
    // captured
    for (const TextureRec& t : p.textures)
        if (!t.readback.empty() && !(t.readback == kReadbackBudget && !t.pre_file.empty()))
            return r.error = "contents of " + t.role + " were not captured: " + t.readback, r;
    if (f.gcn_cache_id != gcn_shader_cache_id())
        r.notes.push_back("captured with another gcn-recompiler build: translation differences show as mismatches");
    for (const std::string& u : p.unstable)
        r.notes.push_back("capture: " + u + " changed while the pass ran; a mismatch may come from the capture");
    if (!PrepareProcess(f, &r)) return r;

    // guest memory: zero what the previous call loaded, then this pass's snapshots
    for (auto& [a, n] : g_loaded) {
        memset(g_mem + a, 0, n);
        ps4draw::NotifyGuestWrite(a, n, false, 0);
    }
    g_loaded.clear();
    for (const BlobRef& b : p.inputs)
        if (!LoadBlob(o.frame_dir, b, &r)) return r;
    SetMappedRanges(p);
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
        // the queue as the command processor named it ("gfx", "asc", "asc-indirect")
        const int queue = p.queue.compare(0, 3, "asc") == 0 ? ps4draw::kQueueCompute : ps4draw::kQueueGfx;
        ps4draw::Dispatch(&g_ctx, regs.data(), p.dim[0], p.dim[1], p.dim[2], p.indirect_addr, p.queue.c_str(), queue);
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
    // guest memory written through V#s the shader loads at run time (no bound buffer: the
    // capture records the written pages, ps4_gnm_draw.mm GmRunSync)
    for (const BlobRef& ob : p.outputs) {
        bool bound = false;
        for (const BufferRec& b : p.buffers)
            bound |= b.written && ob.addr == b.addr && ob.size == b.size;
        if (bound || ob.addr >= g_mem_size || ob.size > g_mem_size - ob.addr) continue;
        OutputResult out;
        char what[64];
        snprintf(what, sizeof(what), "buffer 0x%llx", (unsigned long long)ob.addr); // "guest pages"
        out.what = what;
        out.addr = ob.addr;
        std::vector<uint8_t> want;
        const bool have = !ob.file.empty() && ReadFile(o.frame_dir + "/" + ob.file, &want);
        AddOutput(o, std::move(out), g_mem + ob.addr, ob.size, have ? &want : nullptr, &r);
        g_loaded.push_back({ob.addr, ob.size});
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
