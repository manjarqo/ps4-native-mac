// Wave-level GCN instructions on Metal, whose simdgroups are 32 wide (a wave64 compute shader
// runs as two simdgroups), checked by running small compute shaders and reading their output.
// Uncharted 4's chapter 1 compute shaders (tests/host/data/u4_cs_*, gcn_u4_cs_test) use them:
//  A. s_mov_b32 exec_hi after v_cmpx: lanes 32-63 must take the written half, not the low half
//     (they ran with exec_lo's bits: 16 lanes of 32 in the upper half here).
//  B. V# dwords spilled to VGPR lanes (v_writelane / v_readlane) and used for a store.
//  C. A wave64 compare whose 64-bit result (vcc) is read from both halves.
//  D-G. Cross-lane instructions of a wave64 (v_readfirstlane, v_readlane, scalar
//     instructions on EXEC and 64-bit masks, v_mbcnt, ADD_TID buffers): lanes 32-63 run in the
//     second simdgroup and must see the whole wave.
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>

#include <algorithm>
#include <cctype>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <ctime>
#include <string>
#include <vector>

#include "gcn_recompiler.h"
#include "backend_harness.h" // CHECK, g_fail, MakeTestBackend (PS4_GNM_METAL=3|4)
#include "msl_barrier_check.h"

namespace {

// The kernels run through the renderer's backend (PS4_GNM_METAL), created once in main.
std::unique_ptr<ps4gnm::GnmBackend> g_be;
uint64_t g_seq = 0;

constexpr uint64_t kGuestBase = 0x10000000;
constexpr uint64_t kGuestSize = 1u << 20;

struct Guest {
    id<MTLBuffer> buf;
    // resident from Setup on; leaves its set once the last seq that used it completed
    ~Guest() {
        if (buf && g_be) g_be->Evict(buf, g_seq);
    }
    uint8_t* p(uint64_t a) { return static_cast<uint8_t*>(buf.contents) + (a - kGuestBase); }
    static bool Read(void* ctx, uint64_t addr, void* dst, uint64_t size) {
        auto* g = static_cast<Guest*>(ctx);
        if (addr < kGuestBase || addr + size > kGuestBase + kGuestSize) return false;
        std::memcpy(dst, g->p(addr), size);
        return true;
    }
};

std::vector<uint32_t> WithFooter(const std::vector<uint32_t>& body, uint64_t hash) {
    std::vector<uint32_t> code = {0xBEEB03FF, 0};
    code.insert(code.end(), body.begin(), body.end());
    while (code.size() % 2) code.push_back(0xBF800000); // s_nop
    code[1] = uint32_t(code.size() / 2 - 1);
    uint8_t bi[32] = {'O', 'r', 'b', 'S', 'h', 'd', 'r', 7};
    const uint32_t w = (uint32_t(code.size() * 4) & 0xFFFFFF) << 8;
    std::memcpy(bi + 8, &w, 4);
    std::memcpy(bi + 16, &hash, 8);
    const size_t at = code.size();
    code.resize(at + 8);
    std::memcpy(&code[at], bi, 32);
    return code;
}

// V#: base, num_records, stride, data/number format (dfmt 4 = 32 / nfmt 4 = uint by default).
void VSharp(uint32_t* v, uint64_t base, uint32_t records, uint32_t stride, uint32_t dfmt = 4, uint32_t nfmt = 4) {
    v[0] = uint32_t(base);
    v[1] = (uint32_t(base >> 32) & 0xFFF) | (stride << 16);
    v[2] = records;
    v[3] = 4 | (5 << 3) | (6 << 6) | (7 << 9) | (nfmt << 12) | (dfmt << 15);
}

// ---- Hang guards. A test kernel that never ends holds the GPU (2026-10-22: a test program whose
// loop exit was a branch back into the loop ran for 35 minutes), so before a kernel runs, its
// guest program is checked for a loop it cannot leave, and while it runs, the wait for it is
// bounded: a kernel that does not end fails the run and ends the process.

uint64_t g_case_hash = 0; // the shader hash of the test kernel being set up or run

// Dwords of the GCN instruction at `pc`, or 0 for an encoding these checks do not decode.
uint32_t InstDwords(const std::vector<uint32_t>& p, size_t pc) {
    const uint32_t w = p[pc];
    if ((w >> 30) == 2) {                                  // scalar ALU / program control
        if ((w >> 23) == 0x17F) return 1;                  // SOPP
        if ((w >> 23) == 0x17D) return (w & 0xFF) == 0xFF ? 2 : 1; // SOP1
        if ((w >> 23) == 0x17E || (w >> 28) != 0xB)        // SOPC, SOP2
            return ((w & 0xFF) == 0xFF || ((w >> 8) & 0xFF) == 0xFF) ? 2 : 1;
        return 1;                                          // SOPK
    }
    if ((w >> 31) == 0) {                                  // VOP2, VOP1, VOPC
        bool literal = (w & 0x1FF) == 0xFF;
        const uint32_t vop2 = (w >> 25) & 0x3F;
        if ((w >> 25) < 0x3E && (vop2 == 0x20 || vop2 == 0x21)) literal = true; // v_madmk / v_madak
        return literal ? 2 : 1;
    }
    switch (w >> 26) {
    case 0x30: case 0x31: case 0x32: return 1;             // SMRD, VINTRP
    case 0x34: case 0x36: case 0x38: case 0x3A: case 0x3C: case 0x3E: return 2; // VOP3, DS, MUBUF, MTBUF, MIMG, EXP
    default: return 0;
    }
}

// The next instruction of a wave whose EXEC is zero at `pc`, while EXEC provably stays zero: -1
// when the program may end, may set a non-zero EXEC, or may branch on state the zero EXEC does
// not decide (SCC, VCC). EXEC stays zero through v_cmpx (EXEC &= compare), a compare that writes
// EXEC (inactive lanes give 0 bits), s_and_saveexec_b64, and s_and_b64 / s_andn2_b64 of EXEC with
// EXEC as the ANDed source; every other write of exec_lo / exec_hi may set lanes.
long ZeroExecNext(const std::vector<uint32_t>& p, size_t pc) {
    const uint32_t w = p[pc];
    const uint32_t n = InstDwords(p, pc);
    if (n == 0 || pc + n > p.size()) return -1;
    auto is_exec = [](uint32_t r) { return r == 126 || r == 127; };
    if ((w >> 23) == 0x17F) {                              // SOPP
        const uint32_t op = (w >> 16) & 0x7F;
        const long target = long(pc) + 1 + int16_t(w & 0xFFFF);
        switch (op) {
        case 1: return -1;                                 // s_endpgm
        case 2: case 8: return target;                     // s_branch, s_cbranch_execz (taken)
        case 9: return long(pc) + 1;                       // s_cbranch_execnz (not taken)
        case 4: case 5: case 6: case 7: return -1;         // SCC / VCC branches
        default: return long(pc) + 1;
        }
    }
    if ((w >> 23) == 0x17D) {                              // SOP1
        const uint32_t op = (w >> 8) & 0xFF;
        if (op >= 0x24 && op <= 0x2B) return op == 0x24 ? long(pc + n) : -1; // *_saveexec_b64
        return is_exec((w >> 16) & 0x7F) ? -1 : long(pc + n);
    }
    if ((w >> 30) == 2 && (w >> 23) != 0x17E && (w >> 28) != 0xB) { // SOP2
        if (!is_exec((w >> 16) & 0x7F)) return long(pc + n);
        const uint32_t op = (w >> 23) & 0x7F, s0 = w & 0xFF, s1 = (w >> 8) & 0xFF;
        if (op == 0x0F && (s0 == 126 || s1 == 126)) return long(pc + n); // s_and_b64 exec, exec, x
        if (op == 0x15 && s0 == 126) return long(pc + n);  // s_andn2_b64 exec, exec, x
        return -1;
    }
    if ((w >> 30) == 2) return (w >> 28) == 0xB && (w >> 23) != 0x17E && is_exec((w >> 16) & 0x7F) ? -1 : long(pc + n);
    if ((w >> 31) == 0) {
        if ((w >> 25) == 0x3E) return long(pc + n);        // VOPC (v_cmpx keeps EXEC zero)
        return is_exec((w >> 17) & 0xFF) ? -1 : long(pc + n); // v_readfirstlane / v_readlane to EXEC
    }
    if ((w >> 26) == 0x34) {                               // VOP3
        const uint32_t op = (w >> 17) & 0x1FF;
        if (op < 0x100) return long(pc + n);               // compares: EXEC-writing ones keep it zero
        return is_exec(w & 0xFF) || is_exec((w >> 8) & 0x7F) ? -1 : long(pc + n);
    }
    if ((w >> 27) == 0x18) return is_exec((w >> 15) & 0x7F) ? -1 : long(pc + n); // SMRD
    return long(pc + n);
}

// Whether a write of EXEC at `pc` may leave EXEC zero (any write of it can).
bool WritesExec(const std::vector<uint32_t>& p, size_t pc) {
    const uint32_t w = p[pc];
    if ((w >> 23) == 0x17F) return false;
    if ((w >> 23) == 0x17D) {
        const uint32_t op = (w >> 8) & 0xFF;
        return (op >= 0x24 && op <= 0x2B) || ((w >> 16) & 0x7F) >= 126;
    }
    if ((w >> 30) == 2) return (w >> 23) != 0x17E && (((w >> 16) & 0x7F) == 126 || ((w >> 16) & 0x7F) == 127);
    if ((w >> 31) == 0) return (w >> 25) == 0x3E ? (((w >> 17) & 0xFF) & 0x10) != 0 : ((w >> 17) & 0xFF) >= 126 && ((w >> 17) & 0xFF) <= 127;
    if ((w >> 26) == 0x34) {
        const uint32_t op = (w >> 17) & 0x1FF;
        return (op < 0x100 && (op & 0x10)) || (w & 0xFF) == 126 || (w & 0xFF) == 127;
    }
    return false;
}

// A guest program that cannot end: after an instruction that may leave EXEC zero, a path of
// instructions that keep it zero returns to itself (such a wave loops forever on GCN too). Returns
// the dword offset of the write after which it happens, or -1. Instructions are decoded from the
// entry along both edges of every branch, so the data after s_endpgm is never read as code.
long ZeroExecCycle(const std::vector<uint32_t>& p) {
    std::vector<uint8_t> reached(p.size(), 0);
    std::vector<size_t> work = {0};
    while (!work.empty()) {
        const size_t pc = work.back();
        work.pop_back();
        if (pc >= p.size() || reached[pc]) continue;
        reached[pc] = 1;
        const uint32_t w = p[pc], n = InstDwords(p, pc);
        if (n == 0) continue;
        if ((w >> 23) == 0x17F) {
            const uint32_t op = (w >> 16) & 0x7F;
            if (op == 1) continue;
            if (op >= 2 && op <= 9) work.push_back(size_t(long(pc) + 1 + int16_t(w & 0xFFFF)));
            if (op == 2) continue;
        }
        work.push_back(pc + n);
    }
    for (size_t pc = 0; pc < p.size(); pc++) {
        if (!reached[pc] || !WritesExec(p, pc)) continue;
        std::vector<uint8_t> seen(p.size(), 0);
        long at = long(pc + InstDwords(p, pc));
        while (at >= 0 && size_t(at) < p.size() && !seen[size_t(at)]) {
            seen[size_t(at)] = 1;
            at = ZeroExecNext(p, size_t(at));
        }
        if (at >= 0 && size_t(at) < p.size()) return long(pc);
    }
    return -1;
}

uint32_t g_lds_bytes = 0; // workgroup memory of the next compiled CS

uint32_t g_compile_flags = 0; // extra GCN_COMPILE_* flags of the next compiled CS
std::string g_compile_error;  // with g_expect_compile_error: the error of the last compile
bool g_expect_compile_error = false;

gcn_shader* Compile(Guest& g, uint64_t code, const uint32_t ud[16], uint32_t threads) {
    gcn_profile prof;
    gcn_profile_default_metal(&prof);
    gcn_runtime_info rt{};
    rt.hw_stage = GCN_HW_CS;
    rt.sw_stage = GCN_SW_COMPUTE;
    rt.num_allocated_vgprs = 16;
    rt.cs.shared_memory_size = g_lds_bytes;
    rt.num_user_data = 12;
    rt.cs.workgroup_size[0] = threads;
    rt.cs.workgroup_size[1] = rt.cs.workgroup_size[2] = 1;
    gcn_compile_desc d{};
    d.hw_stage = GCN_HW_CS;
    d.sw_stage = GCN_SW_COMPUTE;
    d.code_addr = code;
    std::memcpy(d.user_data, ud, 64);
    d.runtime = &rt;
    d.profile = &prof;
    d.read_guest = Guest::Read;
    d.read_ctx = &g;
    d.flags = GCN_COMPILE_EMIT_MSL | g_compile_flags;
    gcn_shader* sh = nullptr;
    char err[512] = {};
    const gcn_status st = gcn_compile(&d, &sh, err, sizeof(err));
    g_compile_error = st == GCN_OK ? "" : err;
    if (g_expect_compile_error) {
        if (sh) gcn_shader_destroy(sh);
        return nullptr;
    }
    CHECK(st == GCN_OK && sh, "test CS does not translate: %s", err);
    return st == GCN_OK ? sh : nullptr;
}

// A local that the MSL declares without a value and reads before it writes it is undefined: the
// GPU leaves whatever its register held (in Uncharted 4, values that kept a loop running). Every
// case runs with every such declaration given all bits set (true, 0xFFFFFFFF, a NaN), so a kernel
// whose result depends on one gives that result every time. A translation must not depend on
// them: each case checks the guest program's result. GCN_WAVE_TEST_NO_POISON=1 runs the MSL as
// generated (for inspection).
const bool g_poison_locals = std::getenv("GCN_WAVE_TEST_NO_POISON") == nullptr;

void PoisonUninitializedLocals(std::string& msl) {
    std::string out;
    out.reserve(msl.size() + msl.size() / 8);
    size_t at = 0;
    while (at < msl.size()) {
        size_t end = msl.find('\n', at);
        if (end == std::string::npos) end = msl.size();
        std::string line = msl.substr(at, end - at);
        const size_t f = line.find_first_not_of(' ');
        static const char* const kInits[][2] = {
            {"bool _", " = true;"}, {"uint _", " = 0xFFFFFFFFu;"}, {"int _", " = int(0xFFFFFFFFu);"},
            {"float _", " = as_type<float>(0xFFFFFFFFu);"}};
        for (const auto& [type, init] : kInits) {
            const size_t n = std::strlen(type);
            if (f != std::string::npos && line.compare(f, n, type) == 0 && line.back() == ';' &&
                line.find_first_not_of("0123456789", f + n) == line.size() - 1) {
                line.pop_back();
                line += init;
                break;
            }
        }
        out += line;
        if (end < msl.size()) out += '\n';
        at = end + 1;
    }
    msl = std::move(out);
}

constexpr int kKernelTimeoutSec = 10; // a test kernel runs in microseconds

// Binds like the renderer's BindStage: a guest buffer at the dword below its base, with
// buf_sizes = size + (base & 3) rounded up to dwords.
bool Run(id<MTLDevice> dev, Guest& g, const gcn_shader* sh, const uint32_t ud[16], uint32_t threads) {
    gcn_shader_info info;
    gcn_shader_get_info(sh, &info);
    NSError* e = nil;
    MTLCompileOptions* o = [MTLCompileOptions new];
    o.languageVersion = MTLLanguageVersion2_3;
    if (const char* dir = std::getenv("GCN_WAVE_TEST_MSL_DIR")) { // the MSL of each kernel, for inspection
        char path[1024];
        std::snprintf(path, sizeof(path), "%s/%016llx.metal", dir, (unsigned long long)g_case_hash);
        if (FILE* f = std::fopen(path, "w")) {
            std::fputs(gcn_shader_msl(sh), f);
            std::fclose(f);
        }
    }
    // A barrier that part of the workgroup may not reach would hang the GPU: such a kernel is
    // reported and not run.
    const auto barrier_errors = msl_check::BarrierErrors(gcn_shader_msl(sh));
    for (size_t i = 0; i < barrier_errors.size() && i < 4; i++)
        std::fprintf(stderr, "  kernel %016llx: %s\n", (unsigned long long)g_case_hash, barrier_errors[i].c_str());
    CHECK(barrier_errors.empty(), "kernel %016llx: %zu barrier hazard(s) in the MSL; not run",
          (unsigned long long)g_case_hash, barrier_errors.size());
    if (!barrier_errors.empty()) return false;
    if (std::getenv("GCN_WAVE_TEST_NO_RUN")) return false; // translate and check only
    std::string source = gcn_shader_msl(sh);
    if (g_poison_locals) PoisonUninitializedLocals(source);
    id<MTLLibrary> lib = [dev newLibraryWithSource:[NSString stringWithUTF8String:source.c_str()] options:o error:&e];
    if (!lib) {
        std::fprintf(stderr, "MSL: %s\n", e.localizedDescription.UTF8String);
        return false;
    }
    id<MTLComputePipelineState> pso = [dev newComputePipelineStateWithFunction:[lib newFunctionWithName:@"main0"] error:&e];
    if (!pso) return false;
    std::vector<uint32_t> flat(std::max<uint32_t>(info.flatbuf_size_dw, 16));
    gcn_shader_build_flatbuf(sh, ud, Guest::Read, &g, flat.data(), flat.size());
    alignas(16) uint8_t push[(sizeof(gcn_push_data) + 15) & ~size_t(15)] = {};
    auto* pd = reinterpret_cast<gcn_push_data*>(push);
    ps4gnm::GnmBackend& be = *g_be;
    be.BeginCmd(ps4gnm::GnmCmdTarget::Main, nil, false);
    be.BeginCompute(false);
    be.SetComputePipeline(pso);
    for (uint32_t i = 0; i < info.num_buffers; i++) {
        gcn_buffer_binding b;
        gcn_shader_get_buffer(sh, i, &b);
        for (uint32_t k = 0; k < b.num_msl_buffers; k++) {
            if (b.type == GCN_BUFFER_FLATBUF) {
                be.BindBytes(ps4gnm::GnmStage::Compute, b.msl_buffers[k], flat.data(), flat.size() * 4);
                continue;
            }
            if (b.type != GCN_BUFFER_GUEST) {
                be.EndEncoder();
                be.Commit(++g_seq, [](void*, const ps4gnm::GnmCompletion&) {}, nullptr);
                return false;
            }
            uint32_t v[4];
            gcn_buffer_desc d{};
            if (!gcn_shader_fetch_buffer_sharp(sh, i, flat.data(), info.code_addr, v)) {
                be.EndEncoder();
                be.Commit(++g_seq, [](void*, const ps4gnm::GnmCompletion&) {}, nullptr);
                return false;
            }
            gcn_decode_buffer(v, &d);
            const uint64_t base = d.base_address & ~3ull;
            be.BindBuffer(ps4gnm::GnmStage::Compute, b.msl_buffers[k], g.buf, base - kGuestBase);
            if (b.buffer_slot < GCN_MAX_BUFFERS)
                pd->buf_sizes[b.buffer_slot] =
                    base == d.base_address ? d.size_bytes : (d.size_bytes + uint32_t(d.base_address - base) + 3) & ~3u;
        }
    }
    if (info.msl_push_constant_buffer >= 0)
        be.BindBytes(ps4gnm::GnmStage::Compute, (uint32_t)info.msl_push_constant_buffer, push, sizeof(push));
    // LDS: the translated kernels declare it statically (threadgroup arrays in main0), as the
    // renderer relies on; no threadgroup memory is set at dispatch
    be.Dispatch(MTLSizeMake(1, 1, 1), MTLSizeMake(threads, 1, 1));
    be.EndEncoder();
    struct W {
        dispatch_semaphore_t done = dispatch_semaphore_create(0);
        bool failed = false;
    } w;
    be.Commit(++g_seq, [](void* p, const ps4gnm::GnmCompletion& c) {
        auto* x = static_cast<W*>(p);
        x->failed = c.failed;
        dispatch_semaphore_signal(x->done);
    }, &w);
    if (dispatch_semaphore_wait(w.done, dispatch_time(DISPATCH_TIME_NOW, int64_t(kKernelTimeoutSec) * NSEC_PER_SEC)) != 0) {
        // The process ends: the GPU work of a hung kernel cannot be cancelled, and process exit
        // tears down its command queue.
        std::fprintf(stderr, "gcn_wave_exec_test: FAIL: kernel %016llx did not end in %d s (a GPU hang)\n",
                     (unsigned long long)g_case_hash, kKernelTimeoutSec);
        std::_Exit(124);
    }
    return !w.failed;
}

constexpr uint32_t kEnd = 0xBF810000;

uint32_t* Out(Guest& g) { return reinterpret_cast<uint32_t*>(g.p(kGuestBase + 0x1000)); }

bool Setup(id<MTLDevice> dev, Guest& g, const std::vector<uint32_t>& body, uint64_t hash, uint32_t ud[16],
           uint32_t out_bytes = 256) {
    if (g.buf) g_be->Evict(g.buf, g_seq);
    g.buf = [dev newBufferWithLength:kGuestSize options:MTLResourceStorageModeShared];
    g_be->MakeResident(g.buf, ps4gnm::GnmResidencyClass::Guest);
    std::memset(g.buf.contents, 0, kGuestSize);
    const auto prog = WithFooter(body, hash);
    g_case_hash = hash;
    const long stuck = ZeroExecCycle(prog);
    CHECK(stuck < 0, "kernel %016llx: after the EXEC write at dword %ld a wave with no lane loops forever",
          (unsigned long long)hash, stuck - 2);
    if (stuck >= 0) return false;
    std::memcpy(g.p(kGuestBase), prog.data(), prog.size() * 4);
    std::memset(ud, 0, 64);
    VSharp(&ud[4], kGuestBase + 0x1000, out_bytes, 0);
    return true;
}

void TestExecHalf(id<MTLDevice> dev) {
    Guest g;
    uint32_t ud[16];
    // v2 = v0 << 2; v1 = 1; exec = (16 > v0); exec_hi = -1; out[v0] = v1
    if (!Setup(dev, g, {0x34040082, 0x7E020281, 0x7DA80090, 0xBEFF03C1, 0xE0701000, 0x80010102, kEnd},
          0x5CA1AB1E00000001ULL, ud)) return;
    gcn_shader* sh = Compile(g, kGuestBase, ud, 64);
    if (!sh) return;
    CHECK(Run(dev, g, sh, ud, 64), "exec_hi: did not run");
    int lo = 0, hi = 0;
    for (int i = 0; i < 64; i++) (i < 32 ? lo : hi) += Out(g)[i] == 1;
    CHECK(Out(g)[0] == 1 && Out(g)[15] == 1 && Out(g)[16] == 0, "exec_hi: low half changed");
    CHECK(lo == 16 && hi == 32, "exec_hi: %d/%d lanes stored in the low/high half, expected 16/32", lo, hi);
    gcn_shader_destroy(sh);
}

void TestSpilledSharp(id<MTLDevice> dev) {
    Guest g;
    uint32_t ud[16];
    std::vector<uint32_t> b;
    for (uint32_t k = 0; k < 4; k++) { // v_writelane_b32 v3, s[4+k], k
        b.push_back(0xD2000000 | (0x102 << 17) | 3);
        b.push_back((4 + k) | ((0x80 + k) << 9));
    }
    for (uint32_t k = 0; k < 4; k++) { // v_readlane_b32 s[12+k], v3, k
        b.push_back(0xD2000000 | (0x101 << 17) | (12 + k));
        b.push_back(0x103 | ((0x80 + k) << 9));
    }
    // v1 = 7; v2 = 8; buffer_store_dword v1, v2, s[12:15] offen
    for (uint32_t w : {0x7E020287u, 0x7E040288u, 0xE0701000u, 0x80030102u, kEnd}) b.push_back(w);
    if (!Setup(dev, g, b, 0x5CA1AB1E00000002ULL, ud)) return;
    gcn_shader* sh = Compile(g, kGuestBase, ud, 1);
    if (!sh) return;
    CHECK(Run(dev, g, sh, ud, 1), "spilled V#: did not run");
    CHECK(Out(g)[2] == 7 && Out(g)[0] == 0, "spilled V#: out[2] = %u, out[0] = %u; expected 7 and 0", Out(g)[2], Out(g)[0]);
    gcn_shader_destroy(sh);
}

void TestWave64Compare(id<MTLDevice> dev) {
    Guest g;
    uint32_t ud[16];
    // vcc = (40 > v0); v1 = vcc_lo; v4 = vcc_hi; v2 = 0; out[0] = v1; out[1] = v4
    if (!Setup(dev, g, {0x7D8800A8, 0x7E02026A, 0x7E08026B, 0x7E040280, 0xE0701000, 0x80010102, 0xE0701004, 0x80010402, kEnd},
          0x5CA1AB1E00000003ULL, ud)) return;
    gcn_shader* sh = Compile(g, kGuestBase, ud, 64);
    if (!sh) return;
    CHECK(Run(dev, g, sh, ud, 64), "wave64 compare: did not run");
    CHECK(Out(g)[0] == 0xFFFFFFFFu && Out(g)[1] == 0xFFu, "wave64 compare: vcc = %08x:%08x, expected 000000ff:ffffffff",
          Out(g)[1], Out(g)[0]);
    gcn_shader_destroy(sh);
}


// Instruction words of the wave64 cases below (64-thread workgroup, v0 = thread id).
constexpr uint32_t kAddV1 = 0x4A0200FF;  // v_add_i32 v1, vcc, 100, v0 (literal follows)
constexpr uint32_t kShlV2 = 0x34040082;  // v_lshlrev_b32 v2, 2, v0
constexpr uint32_t kRflS10 = 0x7E140501; // v_readfirstlane_b32 s10, v1
constexpr uint32_t kMovV3S10 = 0x7E06020A; // v_mov_b32 v3, s10
constexpr uint32_t kStoreV3 = 0xE0701000, kStoreV3b = 0x80010302; // buffer_store_dword v3, v2, s[4:7] offen
constexpr uint32_t kExecLoLit = 0xBEFE03FF;  // s_mov_b32 exec_lo, literal
constexpr uint32_t kExecHiLit = 0xBEFF03FF;  // s_mov_b32 exec_hi, literal
// v_mov_b32 v6, s2 (user data 2 = 0); v_cmpx_le_u32 exec, 0, v6: every lane stays active, and the
// EXEC scope it opens does not depend on the lane id (the EXEC half writes after it apply in it)
#define OPEN_SCOPE 0x7E0C0202, 0x7DA60C80

// Runs a 64-thread program whose lanes 0-31 and 32-63 hold different values (v1 = 100 + lane)
// and returns the output dwords.
std::vector<uint32_t> RunWave64(id<MTLDevice> dev, const char* name, uint64_t hash, const std::vector<uint32_t>& body,
                                uint32_t out_dwords = 64, const std::vector<std::pair<int, uint32_t>>& ud_set = {},
                                uint32_t threads = 64, std::string* msl = nullptr,
                                gcn_shader_info* info = nullptr) {
    Guest g;
    uint32_t ud[16];
    std::vector<uint32_t> b = {kAddV1, 100, kShlV2};
    b.insert(b.end(), body.begin(), body.end());
    b.push_back(kEnd);
    if (!Setup(dev, g, b, hash, ud, out_dwords * 4)) return {};
    for (const auto& [i, v] : ud_set) ud[i] = v;
    gcn_shader* sh = Compile(g, kGuestBase, ud, threads);
    if (!sh) return {};
    if (msl) *msl = gcn_shader_msl(sh);
    if (info) gcn_shader_get_info(sh, info);
    const bool ran = Run(dev, g, sh, ud, threads);
    CHECK(ran, "%s: did not run", name);
    gcn_shader_destroy(sh);
    if (!ran) return {};
    return std::vector<uint32_t>(Out(g), Out(g) + out_dwords);
}

// Checks out[l] == want(l) for every lane, printing the first few mismatches.
template <typename F>
void ExpectLanes(const char* name, const std::vector<uint32_t>& out, F want, uint32_t lanes = 64) {
    if (out.size() < lanes) return;
    int bad = 0;
    for (uint32_t l = 0; l < lanes; l++) {
        if (out[l] == want(l)) continue;
        if (bad++ < 4) std::fprintf(stderr, "  %s: lane %u = %u, expected %u\n", name, l, out[l], want(l));
    }
    CHECK(bad == 0, "%s: %d of %u lanes wrong", name, bad, lanes);
}

//  D. v_readfirstlane in a wave64: the first lane active in EXEC across both halves, not each
//     simdgroup's own first lane (lanes 32-63 read lane 32's value before).
void TestReadFirstLane(id<MTLDevice> dev) {
    // every lane active: lane 0's value everywhere
    auto out = RunWave64(dev, "readfirstlane all", 0x5CA1AB1E00000004ULL, {kRflS10, kMovV3S10, kStoreV3, kStoreV3b});
    ExpectLanes("readfirstlane all", out, [](uint32_t) { return 100u; });
    // lanes 0-4 inactive, read right after the EXEC write (outside the EXEC scope): lane 5
    out = RunWave64(dev, "readfirstlane from lane 5", 0x5CA1AB1E00000005ULL,
                    {OPEN_SCOPE, kExecLoLit, 0xFFFFFFE0, kRflS10, kMovV3S10, kStoreV3, kStoreV3b});
    ExpectLanes("readfirstlane from lane 5", out, [](uint32_t l) { return l < 5 ? 0u : 105u; });
    // the same, read inside the EXEC scope (v_mov v4, 0 first): the scope runs predicated (every
    // invocation runs it), so the halves exchange there too and lanes 32-63 read lane 5's value
    out = RunWave64(dev, "readfirstlane in scope", 0x5CA1AB1E00000006ULL,
                    {OPEN_SCOPE, kExecLoLit, 0xFFFFFFE0, 0x7E080280, kRflS10, kMovV3S10, kStoreV3, kStoreV3b});
    ExpectLanes("readfirstlane in scope", out, [](uint32_t l) { return l < 5 ? 0u : 105u; });
    // only lanes 40-47 active: lane 40
    out = RunWave64(dev, "readfirstlane upper half", 0x5CA1AB1E00000007ULL,
                    {OPEN_SCOPE, 0xBEFE0380, kExecHiLit, 0xFF00, kRflS10, kMovV3S10, kStoreV3, kStoreV3b});
    ExpectLanes("readfirstlane upper half", out, [](uint32_t l) { return l >= 40 && l < 48 ? 140u : 0u; });
    // EXEC with only one half (s_bfm_b64 exec, 32, 32 / s_and_b64 exec, exec, user-data mask
    // 0:0xffffffff) and v_readfirstlane inside its scope: one subgroup has no lane in the scope.
    // The scope runs predicated, so that subgroup still reaches the exchange's barriers (at d502bd7
    // the scope was a real branch and kept no exchange). The result is the wave's first EXEC lane:
    // lane 32 / lane 0.
    std::string scope_msl;
    out = RunWave64(dev, "readfirstlane upper-half scope", 0x5CA1AB1E00000012ULL,
                    {OPEN_SCOPE, 0x92FEA0A0, 0x7E080280, kRflS10, kMovV3S10, kStoreV3, kStoreV3b}, 64, {}, 64,
                    &scope_msl);
    ExpectLanes("readfirstlane upper-half scope", out, [](uint32_t l) { return l >= 32 ? 132u : 0u; });
    out = RunWave64(dev, "readfirstlane lower-half scope", 0x5CA1AB1E00000013ULL,
                    {OPEN_SCOPE, 0x87FE027E, 0x7E080280, kRflS10, kMovV3S10, kStoreV3, kStoreV3b}, 64,
                    {{2, 0xFFFFFFFFu}, {3, 0}}, 64, &scope_msl);
    ExpectLanes("readfirstlane lower-half scope", out, [](uint32_t l) { return l < 32 ? 100u : 0u; });
    // s_endpgm inside an EXEC scope that lanes 0-31 enter, then v_readfirstlane after the scope.
    // s_endpgm ends the whole wave on GCN, whatever EXEC is: nothing is stored. (The translator
    // used to end lanes 0-31 only, and lanes 32-63 stored lane 32's value.) The program runs
    // predicated: the exchange after the scope is reached by every invocation (Run checks every
    // barrier of the MSL).
    // vcc = 32 > v0; s[12:13] = saveexec(vcc); if (exec) { v4 = 0; s_endpgm } exec = s[12:13]
    out = RunWave64(dev, "readfirstlane after a divergent return", 0x5CA1AB1E00000016ULL,
                    {0x7D8800A0, 0xBE8C246A, 0xBF880002, 0x7E080280, kEnd, 0xBEFE040C, kRflS10, kMovV3S10,
                     kStoreV3, kStoreV3b},
                    64, {}, 64, &scope_msl);
    ExpectLanes("readfirstlane after a divergent return", out, [](uint32_t) { return 0u; });
    // Cost: a value that is the same in every lane (v7 = user data s2) needs no exchange through
    // workgroup memory, and a 32-thread workgroup (one subgroup) keeps the subgroup broadcast.
    std::string msl;
    out = RunWave64(dev, "readfirstlane uniform", 0x5CA1AB1E0000000EULL,
                    {0x7E0E0202, 0x7E140507, kMovV3S10, kStoreV3, kStoreV3b}, 64, {{2, 55}}, 64, &msl);
    ExpectLanes("readfirstlane uniform", out, [](uint32_t) { return 55u; });
    CHECK(!out.empty() && msl.find("threadgroup_barrier") == std::string::npos,
          "readfirstlane uniform: a wave-uniform value is exchanged through workgroup memory");
    out = RunWave64(dev, "readfirstlane wave32", 0x5CA1AB1E0000000FULL, {kRflS10, kMovV3S10, kStoreV3, kStoreV3b},
                    64, {}, 32, &msl);
    ExpectLanes("readfirstlane wave32", out, [](uint32_t l) { return l < 32 ? 100u : 0u; });
    CHECK(!out.empty() && msl.find("threadgroup_barrier") == std::string::npos &&
              msl.find("simd_broadcast_first") != std::string::npos,
          "readfirstlane wave32: not a plain subgroup broadcast");
}

//  E. v_readlane with an SGPR lane in the other half; v_writelane to lanes 3 and 40 (a per-lane
//     select of the named lane, the other lanes keep their value).
void TestReadLaneAndWriteLaneGap(id<MTLDevice> dev) {
    // s10 = v_readlane(v1, s2); out[l] = s10; s10 = v_readlane(v1, s3); out[64 + l] = s10, with
    // user data s2 = 40 and s3 = 7 (not constants the translator could fold)
    auto out = RunWave64(dev, "readlane sgpr", 0x5CA1AB1E00000008ULL,
                         {0xD202000A, 0x00000501, kMovV3S10, kStoreV3, kStoreV3b, 0xD202000A, 0x00000701, kMovV3S10,
                          0x4A0804FF, 256, kStoreV3, 0x80010304},
                         128, {{2, 40}, {3, 7}});
    ExpectLanes("readlane sgpr lane 40", out, [](uint32_t) { return 140u; });
    if (out.size() == 128)
        ExpectLanes("readlane sgpr lane 7", std::vector<uint32_t>(out.begin() + 64, out.end()),
                    [](uint32_t) { return 107u; });
    // s12 = 7; v_writelane v1, s12, 3; v_writelane v1, s12, 40; out[l] = v1
    out = RunWave64(dev, "writelane", 0x5CA1AB1E00000009ULL,
                    {0xBE8C0387, 0xD2040001, 0x0001060C, 0xD2040001, 0x0001500C, kStoreV3, 0x80010102});
    ExpectLanes("writelane", out, [](uint32_t l) { return l == 3 || l == 40 ? 7u : 100u + l; });
}

//  F. Scalar instructions on EXEC and on 64-bit masks with only upper-half bits, and a mask
//     with bits in both halves used as a per-lane condition.
void TestWave64Masks(id<MTLDevice> dev) {
    // exec = lanes 24-31 and 40-47; s10 = s_ff1(exec); s11 = s_bcnt1(exec); s[12:13] = exec & -1;
    // s14 = s_ff1(0x100:0); out[8l + k] = s[10 + k]. Then the same EXEC with scc = bit 41 of exec,
    // s10 = scc ? 1 : 2.
    const std::vector<uint32_t> scalar = {0xBE8A147E, 0xBE8B107E, 0x878CC17E, 0xBE900380, 0xBE9103FF, 0x100, 0xBE8E1410};
    const std::vector<uint32_t> bitcmp = {0xBF0FA97E, 0x850A8281};
    const uint32_t want[2][5] = {{24, 16, 0xFF000000, 0xFF00, 40}, {1}};
    const char* what[2][5] = {{"s_ff1 exec", "s_bcnt1 exec", "s_and_b64 exec lo", "s_and_b64 exec hi",
                               "s_ff1 upper-half mask"},
                              {"s_bitcmp1 exec"}};
    for (int c = 0; c < 2; c++) {
        const uint32_t n = c == 0 ? 5 : 1;
        std::vector<uint32_t> b = {OPEN_SCOPE, kExecLoLit, 0xFF000000, kExecHiLit, 0xFF00};
        b.insert(b.end(), c == 0 ? scalar.begin() : bitcmp.begin(), c == 0 ? scalar.end() : bitcmp.end());
        b.push_back(0x340A0085); // v_lshlrev_b32 v5, 5, v0
        for (uint32_t k = 0; k < n; k++) {
            b.push_back(0x7E060200 | (10 + k)); // v_mov_b32 v3, s[10 + k]
            b.push_back(0xE0701000 | (4 * k));  // buffer_store_dword v3, v5, s[4:7] offen offset:4k
            b.push_back(0x80010305);
        }
        auto out = RunWave64(dev, what[c][0], 0x5CA1AB1E0000000AULL + (uint64_t(c) << 32), b, 512);
        if (out.size() != 512) continue;
        for (uint32_t k = 0; k < n; k++) {
            int bad = 0;
            for (uint32_t l = 24; l < 48; l++) bad += (l < 32 || l >= 40) && out[8 * l + k] != want[c][k];
            CHECK(bad == 0, "%s: lanes 24 / 40 have %u / %u, expected %u (%d of 16 lanes wrong)", what[c][k],
                  out[8 * 24 + k], out[8 * 40 + k], want[c][k], bad);
        }
    }
    // s[12:13] = 0x0F000000:0x0000000F; v3 = v_cndmask(0, 1, s[12:13]): lanes 0-3 and 56-59
    std::vector<uint32_t> out = RunWave64(dev, "mask condition", 0x5CA1AB1E0000000BULL,
                    {0xBE8C038F, 0xBE8D03FF, 0x0F000000, 0xD2000003, 0x00310280, kStoreV3, kStoreV3b});
    ExpectLanes("mask condition", out, [](uint32_t l) { return l < 4 || (l >= 56 && l < 60) ? 1u : 0u; });
    // A loop on a mask computed from vcc (shifted by user data s2 = 0): the ballot stays in the
    // loop, in each subgroup's own layout, and lanes 32-63 must keep testing their bit there
    // (they read 0 in the wave layout, so a loop waiting for its bit never ended).
    // v1 = 0; do { v1 += 1; vcc = (5 > v1) << s2; } while (vccnz); out[l] = v1
    out = RunWave64(dev, "vcc loop", 0x5CA1AB1E00000010ULL,
                    {0x7E020280, 0x4A020281, 0x7D880285, 0x8FEA026A, 0xBF87FFFC, kStoreV3, 0x80010102});
    ExpectLanes("vcc loop", out, [](uint32_t) { return 5u; });
    // exec = lanes 5-63; v3 = v_mbcnt_hi(exec_hi, v_mbcnt_lo(exec_lo, 0)): active lanes below.
    // Inside the EXEC scope (predicated) the ballot of EXEC is the wave's, so lanes 32-63 count
    // the active lanes of both halves.
    out = RunWave64(dev, "mbcnt", 0x5CA1AB1E0000000CULL,
                    {OPEN_SCOPE, kExecLoLit, 0xFFFFFFE0, 0xD2460003, 0x0001007E, 0xD2480003, 0x0002067F, kStoreV3, kStoreV3b});
    ExpectLanes("mbcnt", out, [](uint32_t l) { return l < 5 ? 0u : l - 5; });
    // every lane active (no scope): mbcnt of EXEC is the lane id in both halves
    out = RunWave64(dev, "mbcnt all lanes", 0x5CA1AB1E00000015ULL,
                    {0xD2460003, 0x0001007E, 0xD2480003, 0x0002067F, kStoreV3, kStoreV3b});
    ExpectLanes("mbcnt all lanes", out, [](uint32_t l) { return l; });
}

//  G. A V# with ADD_TID_ENABLE: the record index is the lane (0-63), not the simdgroup lane.
//  H. Partial workgroups: 48 threads (a wave whose upper half has 16 lanes) and 96 threads (a
//     second wave of 32 lanes with no upper half). v_readfirstlane and s_bcnt1 of EXEC per wave.
void TestPartialGroups(id<MTLDevice> dev) {
    for (const uint32_t threads : {48u, 96u}) {
        char name[64];
        std::snprintf(name, sizeof(name), "readfirstlane %u threads", threads);
        auto out = RunWave64(dev, name, 0x5CA1AB1E00000014ULL + threads, {kRflS10, kMovV3S10, kStoreV3, kStoreV3b},
                             threads, {}, threads);
        ExpectLanes(name, out, [](uint32_t l) { return l < 64 ? 100u : 164u; }, threads);
        // s11 = s_bcnt1(exec); out[l] = s11: the lanes the wave has
        std::snprintf(name, sizeof(name), "s_bcnt1 exec %u threads", threads);
        out = RunWave64(dev, name, 0x5CA1AB1E00000114ULL + threads, {0xBE8B107E, 0x7E06020B, kStoreV3, kStoreV3b},
                        threads, {}, threads);
        ExpectLanes(name, out, [threads](uint32_t l) { return l < 64 ? std::min(threads, 64u) : threads - 64; },
                    threads);
    }
}

//  I. The whole body inside an EXEC bounds check (v_cmpx_gt_u32 exec, s2, v0 + s_cbranch_execz),
//     as in Uncharted 4's motion-blur scatter CS: readlane 32, readlane 0 and readfirstlane, a loop
//     whose trip count differs per lane (2000 iterations in threads 0-31, none in the others), then a
//     write of each lane's value to workgroup memory and a read of lane (l + 32) & 63's. In a
//     wave every lane finishes the loop before the write and writes before the read.
//     out[8l .. 8l + 4] = readlane 32, readlane 0, readfirstlane, workgroup-memory read and the
//     loop's result (v12 = 3 v12 + 1 per iteration, so the loop cannot be folded away). The
//     written value carries a salt per run, so stale workgroup memory from earlier runs cannot match.
void TestDivergentBody(id<MTLDevice> dev) {
    const std::vector<uint32_t> body = {
        0x7DA80002, 0xBF880000, // v_cmpx_gt_u32 exec, s2, v0; s_cbranch_execz end (patched)
        0xD202000A, 0x00014101, // v_readlane_b32 s10, v1, 32
        0xD202000B, 0x00010101, // v_readlane_b32 s11, v1, 0
        0x7E180501,             // v_readfirstlane_b32 s12, v1
        0x7D8800A0,             // v_cmp_gt_u32 vcc, 32, v0
        0x7E120203,             // v_mov_b32 v9, s3 (2000)
        0x00101280,             // v_cndmask_b32 v8, 0, v9, vcc
        0x7E0E0280,             // v_mov_b32 v7, 0
        0x7E180280,             // v_mov_b32 v12, 0
        0xBE94047E,             // s_mov_b64 s[20:21], exec
        0x7DA21107,             // loop: v_cmpx_lt_u32 exec, v7, v8
        0xBF880005,             // s_cbranch_execz +5
        0x4A0E0E81,             // v_add_i32 v7, vcc, 1, v7
        0x341A1881,             // v_lshlrev_b32 v13, 1, v12
        0x4A18190D,             // v_add_i32 v12, vcc, v13, v12
        0x4A181881,             // v_add_i32 v12, vcc, 1, v12 (v12 = 3 v12 + 1)
        0xBF82FFF9,             // s_branch loop
        0xBEFE0414,             // s_mov_b64 exec, s[20:21]
        0x4A160208,             // v_add_i32 v11, vcc, s8, v1 (s8: a salt per run)
        0xD8340000, 0x00000B02, // ds_write_b32 v2, v11
        0x4A0C00A0,             // v_add_i32 v6, vcc, 32, v0
        0x360C0CBF,             // v_and_b32 v6, 63, v6
        0x340C0C82,             // v_lshlrev_b32 v6, 2, v6
        0xD8D80000, 0x05000006, // ds_read_b32 v5, v6
        0x34140085,             // v_lshlrev_b32 v10, 5, v0
        0x7E06020A, 0xE0701000, 0x8001030A, // v3 = s10; out[4l] = v3
        0x7E06020B, 0xE0701004, 0x8001030A, // v3 = s11; out[4l + 1]
        0x7E06020C, 0xE0701008, 0x8001030A, // v3 = s12; out[4l + 2]
        0xE070100C, 0x8001050A,             // out[4l + 3] = v5
        0xE0701010, 0x80010C0A,             // out[4l + 4] = v12 (the loop's result)
    };
    std::vector<uint32_t> b = body;
    b[1] = 0xBF880000 | uint32_t(b.size() - 2); // to the s_endpgm RunWave64 appends
    g_lds_bytes = 256;
    struct Case {
        const char* name;
        uint32_t threads, bound;
    };
    uint32_t salt = 1000u * (uint32_t(time(nullptr)) % 1000u + 1u);
    for (const Case c : {Case{"divergent body, full group", 64, 64}, Case{"divergent body, 48 of 64 lanes", 64, 48},
                         Case{"divergent body, 96 threads", 96, 96}}) {
        salt += 1000000u;
        const auto out = RunWave64(dev, c.name, 0x5CA1AB1E00000020ULL + c.bound + c.threads * 256, b, 8 * c.threads,
                                   {{2, c.bound}, {3, 2000}, {8, salt}}, c.threads);
        if (out.size() != 8 * c.threads) continue;
        uint32_t lcg = 0;
        for (int i = 0; i < 2000; i++) lcg = 3 * lcg + 1;
        int bad = 0;
        for (uint32_t l = 0; l < c.threads; l++) {
            const uint32_t wave = l & ~63u, lane = l & 63;
            const bool active = l < c.bound;
            const uint32_t lanes_in_wave = std::min(64u, c.threads - wave);
            uint32_t want[5] = {100 + wave + 32, 100 + wave, 100 + wave, salt + 100 + wave + ((lane + 32) & 63),
                                l < 32 ? lcg : 0u};
            bool check[5] = {lanes_in_wave > 32, true, true, true, true};
            // a partner lane outside EXEC (or a wave without it) never wrote its slot
            const uint32_t partner = (lane + 32) & 63;
            if (wave + partner >= c.bound || partner >= lanes_in_wave) check[3] = false;
            for (int k = 0; k < 5; k++) {
                const uint32_t got = out[8 * l + k];
                const bool ok = active ? (!check[k] || got == want[k]) : got == 0;
                if (!ok && bad++ < 6)
                    std::fprintf(stderr, "  %s: lane %u word %d = %u, expected %u\n", c.name, l, k, got,
                                 active ? want[k] : 0);
            }
        }
        CHECK(bad == 0, "%s: %d wrong words", c.name, bad);
    }
    g_lds_bytes = 0;
}

//  J. v_readlane of a lane outside EXEC inside an EXEC scope reads that lane's register as it
//     was before the scope (the lane did not run the write), not a value the lane computed.
//     Lanes 0-39 active; v1 += 1000 in the scope; s10 = readlane(v1, 50), s11 = readlane(v1, 7).
void TestReadLaneOutsideExec(id<MTLDevice> dev) {
    std::vector<uint32_t> b = {
        0x7DA80002, 0xBF880000, // v_cmpx_gt_u32 exec, s2, v0; s_cbranch_execz end (patched)
        0x4A0202FF, 1000,       // v_add_i32 v1, vcc, 1000, v1
        0xD202000A, 0x00016501, // v_readlane_b32 s10, v1, 50
        0xD202000B, 0x00010F01, // v_readlane_b32 s11, v1, 7
        0x34140083,             // v_lshlrev_b32 v10, 3, v0
        0x7E06020A, 0xE0701000, 0x8001030A, // v3 = s10; out[2l] = v3
        0x7E06020B, 0xE0701004, 0x8001030A, // v3 = s11; out[2l + 1] = v3
    };
    b[1] = 0xBF880000 | uint32_t(b.size() - 2);
    const auto out = RunWave64(dev, "readlane outside exec", 0x5CA1AB1E00000030ULL, b, 128, {{2, 40}});
    if (out.size() != 128) return;
    int bad = 0;
    for (uint32_t l = 0; l < 64; l++) {
        const uint32_t want[2] = {l < 40 ? 150u : 0u, l < 40 ? 1107u : 0u};
        for (int k = 0; k < 2; k++) {
            if (out[2 * l + k] == want[k]) continue;
            if (bad++ < 4)
                std::fprintf(stderr, "  readlane outside exec: lane %u word %d = %u, expected %u\n", l, k,
                             out[2 * l + k], want[k]);
        }
    }
    CHECK(bad == 0, "readlane outside exec: %d wrong words", bad);
}

// Patches the s_cbranch_execz at b[at] to jump to the end of b (the s_endpgm RunWave64 appends).
void PatchExecz(std::vector<uint32_t>& b, size_t at) {
    b[at] = 0xBF880000 | uint32_t(b.size() - at - 1);
}

// Checks out[words * l + k] == want(l, k) for every lane l < lanes and word k < words.
template <typename F>
void ExpectWords(const char* name, const std::vector<uint32_t>& out, uint32_t lanes, uint32_t words, F want) {
    if (out.size() < lanes * words) return;
    int bad = 0;
    for (uint32_t l = 0; l < lanes; l++) {
        for (uint32_t k = 0; k < words; k++) {
            const uint32_t got = out[words * l + k], w = want(l, k);
            if (got == w) continue;
            if (bad++ < 4) std::fprintf(stderr, "  %s: lane %u word %u = %u, expected %u\n", name, l, k, got, w);
        }
    }
    CHECK(bad == 0, "%s: %d wrong words", name, bad);
}

//  L. Lanes outside EXEC in a predicated scope keep their registers (lanes 0-39 in EXEC):
//     - v5 = 7 before the scope, v1 += 1000 and v5 = v1 in it, then v_readlane s10, v1, 50: lane 50
//       did not run the scope, so its v1 is still 150 (the readlane must read v1, not the
//       register that got the same value);
//     - s14 = 7 before the scope, `if (s2 == 40) s14 = 50` in it, then v_readlane s10, v1, s14:
//       scalar instructions run for the whole wave, so s14 = 50 in every lane (lanes 40-63 too)
//       and the readlane reads lane 50 (150);
//     - ds_swizzle (swap neighbours) of v1 in the scope with lanes 0-40 in EXEC: lane 40 reads
//       lane 41's v1, still 141.
void TestLanesOutsideExec(id<MTLDevice> dev) {
    for (int variant = 0; variant < 2; variant++) {
        std::vector<uint32_t> b = {0xBE8E0387, 0x7E0A0287}; // s_mov_b32 s14, 7; v_mov_b32 v5, 7
        b.push_back(0x7DA80002);                            // v_cmpx_gt_u32 exec, s2, v0
        const size_t scope = b.size();
        b.push_back(0xBF880000);                // s_cbranch_execz end (patched)
        b.push_back(0x4A0202FF); b.push_back(1000); // v_add_i32 v1, vcc, 1000, v1
        if (variant == 0) {
            b.push_back(0x7E0A0301);            // v_mov_b32 v5, v1
            b.push_back(0xBE8E03B2);            // s_mov_b32 s14, 50
        } else {
            b.push_back(0xBF06A802);            // s_cmp_eq_u32 s2, 40
            b.push_back(0xBF840001);            // s_cbranch_scc0 +1
            b.push_back(0xBE8E03B2);            // s_mov_b32 s14, 50
        }
        b.push_back(0xD202000A); b.push_back(0x00001D01); // v_readlane_b32 s10, v1, s14
        b.push_back(0x34140083);                          // v_lshlrev_b32 v10, 3, v0
        for (uint32_t w : {0x7E06020Au, 0xE0701000u, 0x8001030Au, 0x7E06020Eu, 0xE0701004u, 0x8001030Au})
            b.push_back(w); // out[2l] = s10, out[2l + 1] = s14
        PatchExecz(b, scope);
        const char* name = variant == 0 ? "readlane of a lane outside exec, value copied" :
                                          "readlane lane from an sgpr set in a scalar if";
        const auto out = RunWave64(dev, name, 0x5CA1AB1E00000040ULL + variant, b, 128, {{2, 40}});
        ExpectWords(name, out, 64, 2, [](uint32_t l, uint32_t k) { return l < 40 ? (k == 0 ? 150u : 50u) : 0u; });
    }
    std::vector<uint32_t> b = {0x7DA80002, 0xBF880000, // v_cmpx_gt_u32 exec, s2, v0; execz end
                               0x4A0202FF, 1000,       // v1 += 1000
                               0x7E140501,             // v_readfirstlane_b32 s10, v1
                               0xD8D4041F, 0x05000001, // ds_swizzle_b32 v5, v1 offset:swap(xor 1)
                               0x7E060305, kStoreV3, kStoreV3b}; // out[l] = v5
    PatchExecz(b, 1);
    const auto out = RunWave64(dev, "swizzle of a lane outside exec", 0x5CA1AB1E00000042ULL, b, 64, {{2, 41}});
    ExpectLanes("swizzle of a lane outside exec", out, [](uint32_t l) {
        const uint32_t p = l ^ 1;
        return l < 41 ? (p < 41 ? 1100u + p : 100u + p) : 0u;
    });
}

//  M. Scalarization loop inside a bounds check (lanes 0-39): s_ff1 of EXEC, v_readlane of that
//     lane, the lane leaves EXEC; every lane adds the value of each lane up to its own. The SGPRs
//     are carried through the loop for the whole wave.
void TestScalarizationLoop(id<MTLDevice> dev) {
    std::vector<uint32_t> b = {
        0x7DA80002, 0xBF880000, // v_cmpx_gt_u32 exec, s2, v0; execz end (patched)
        0xBE94047E,             // s_mov_b64 s[20:21], exec
        0x7E060280,             // v_mov_b32 v3, 0
        0xBE8C147E,             // loop: s_ff1_i32_b64 s12, exec
        0xD202000D, 0x00001901, // v_readlane_b32 s13, v1, s12
        0x4A06060D,             // v_add_i32 v3, vcc, s13, v3
        0x8F8E0C81,             // s_lshl_b64 s[14:15], 1, s12
        0x8AFE0E7E,             // s_andn2_b64 exec, exec, s[14:15]
        0xBF89FFF9,             // s_cbranch_execnz loop
        0xBEFE0414,             // s_mov_b64 exec, s[20:21]
        kStoreV3, kStoreV3b,    // out[l] = v3
    };
    PatchExecz(b, 1);
    const auto out = RunWave64(dev, "scalarization loop", 0x5CA1AB1E00000043ULL, b, 64, {{2, 40}});
    ExpectLanes("scalarization loop", out, [](uint32_t l) { return l < 40 ? 100 * (l + 1) + l * (l + 1) / 2 : 0u; });
}

//  N. A predicated scope nested in another (lanes 0-47, then 8-47): v_readfirstlane and
//     v_readlane 40 in the inner one.
void TestNestedScope(id<MTLDevice> dev) {
    std::vector<uint32_t> b = {
        0x7DA80002, 0xBF880000, // v_cmpx_gt_u32 exec, s2, v0; execz end
        0x7DA60003, 0xBF880000, // v_cmpx_le_u32 exec, s3, v0; execz end
        0x7E140501,             // v_readfirstlane_b32 s10, v1
        0xD202000B, 0x00015101, // v_readlane_b32 s11, v1, 40
        0x34140083,             // v_lshlrev_b32 v10, 3, v0
        0x7E06020A, 0xE0701000, 0x8001030A, 0x7E06020B, 0xE0701004, 0x8001030A,
    };
    PatchExecz(b, 1);
    PatchExecz(b, 3);
    const auto out = RunWave64(dev, "nested scope", 0x5CA1AB1E00000044ULL, b, 128, {{2, 48}, {3, 8}});
    ExpectWords("nested scope", out, 64, 2,
                [](uint32_t l, uint32_t k) { return l >= 8 && l < 48 ? (k == 0 ? 108u : 140u) : 0u; });
}

//  O. EXEC loops with lane-divergent trip counts (1-4, lane & 3), whose bodies need the whole
//     wave: s_bcnt1 of EXEC counts the lanes still in the loop (64, 48, 32, 16).
//     - a loop with its test at the top: v12 = sum of the counts of the lane's iterations;
//     - a do-while loop whose value v13 = 3 * iteration is computed before the test and used after
//       the loop: each lane keeps the value of its own last iteration.
void TestPredicatedLoops(id<MTLDevice> dev) {
    const uint32_t sums[4] = {64, 112, 144, 160};
    std::vector<uint32_t> b = {
        0x36100083, 0x4A101081, // v8 = (v0 & 3) + 1
        0x7E0E0280, 0x7E180280, // v7 = 0; v12 = 0
        0xBE94047E,             // s_mov_b64 s[20:21], exec
        0x7DA21107, 0xBF880004, // loop: v_cmpx_lt_u32 exec, v7, v8; s_cbranch_execz +4
        0xBE8B107E,             // s_bcnt1_i32_b64 s11, exec
        0x4A18180B,             // v_add_i32 v12, vcc, s11, v12
        0x4A0E0E81,             // v_add_i32 v7, vcc, 1, v7
        0xBF82FFFA,             // s_branch loop
        0xBEFE0414,             // s_mov_b64 exec, s[20:21]
        0x7E06030C, kStoreV3, kStoreV3b, // out[l] = v12
    };
    auto out = RunWave64(dev, "exchange in a loop", 0x5CA1AB1E00000045ULL, b);
    ExpectLanes("exchange in a loop", out, [&](uint32_t l) { return sums[l & 3]; });
    b = {
        0x36100083, 0x4A101081, 0x7E0E0280, 0x7E180280, 0xBE94047E,
        0xBE8B107E,             // loop: s_bcnt1_i32_b64 s11, exec
        0x4A18180B,             // v_add_i32 v12, vcc, s11, v12
        0x4A0E0E81,             // v_add_i32 v7, vcc, 1, v7
        0x341A0E81, 0x4A1A0F0D, // v13 = 3 * v7
        0x7DA21107,             // v_cmpx_lt_u32 exec, v7, v8
        0xBF89FFF9,             // s_cbranch_execnz loop
        0xBEFE0414,             // s_mov_b64 exec, s[20:21]
        0x34140083,             // v_lshlrev_b32 v10, 3, v0
        0x7E06030D, 0xE0701000, 0x8001030A, 0x7E06030C, 0xE0701004, 0x8001030A,
    };
    out = RunWave64(dev, "loop value used after the loop", 0x5CA1AB1E00000046ULL, b, 128);
    ExpectWords("loop value used after the loop", out, 64, 2,
                [&](uint32_t l, uint32_t k) { return k == 0 ? 3 * ((l & 3) + 1) : sums[l & 3]; });
}

//  P. LDS inside a bounds check of a one-wave workgroup, as in Uncharted 4's pass 904: every lane
//     zeroes slot l & 15, then ds_add_u32 1 to it in a loop of (l >> 4) + 1 iterations, then reads
//     it: 1 + 2 + 3 + 4 = 10. Then LDS atomics with a result: ds_add_rtn_u32 1 on one dword by
//     every lane runs as one wave step, lanes 0-31 first: they get 0-31, lanes 32-63 get 32-63.
void TestPredicatedLds(id<MTLDevice> dev) {
    g_lds_bytes = 64;
    std::vector<uint32_t> b = {
        0x7DA80002, 0xBF880000, // v_cmpx_gt_u32 exec, s2, v0; execz end
        0x3608008F, 0x34080882, // v4 = (v0 & 15) << 2
        0x7E0A0280, 0xD8340000, 0x00000504, // v5 = 0; ds_write_b32 v4, v5
        0x2C100084, 0x4A101081, // v8 = (v0 >> 4) + 1
        0x7E0E0280, 0x7E0C0281, // v7 = 0; v6 = 1
        0xBE94047E,             // s_mov_b64 s[20:21], exec
        0x7DA21107, 0xBF880004, // loop: v_cmpx_lt_u32 exec, v7, v8; s_cbranch_execz +4
        0xD8000000, 0x00000604, // ds_add_u32 v4, v6
        0x4A0E0E81,             // v7 += 1
        0xBF82FFFA,             // s_branch loop
        0xBEFE0414,             // s_mov_b64 exec, s[20:21]
        0xD8D80000, 0x09000004, // ds_read_b32 v9, v4
        0x7E060309, kStoreV3, kStoreV3b, // out[l] = v9
    };
    PatchExecz(b, 1);
    auto out = RunWave64(dev, "lds in a predicated loop", 0x5CA1AB1E00000047ULL, b, 64, {{2, 64}});
    ExpectLanes("lds in a predicated loop", out, [](uint32_t) { return 10u; });
    b = {
        0x7DA80002, 0xBF880000, // v_cmpx_gt_u32 exec, s2, v0; execz end
        0x7E080280, 0x7E0A0280, 0xD8340000, 0x00000504, // v4 = 0; v5 = 0; ds_write_b32 v4, v5
        0x7E0C0281, 0xD8800000, 0x07000604, // v6 = 1; ds_add_rtn_u32 v7, v4, v6
        0x7E060307, kStoreV3, kStoreV3b, // out[l] = v7
    };
    PatchExecz(b, 1);
    for (int run = 0; run < 3; run++) {
        out = RunWave64(dev, "lds atomics in halves", 0x5CA1AB1E00000048ULL, b, 64, {{2, 64}});
        if (out.size() != 64) break;
        uint64_t seen = 0;
        int bad = 0;
        for (uint32_t l = 0; l < 64; l++) {
            const bool ok = out[l] < 64 && (out[l] < 32) == (l < 32) && !(seen >> out[l] & 1);
            if (ok) seen |= 1ull << out[l];
            if (!ok && bad++ < 4) std::fprintf(stderr, "  lds atomics in halves: lane %u got %u\n", l, out[l]);
        }
        CHECK(bad == 0, "lds atomics in halves: %d lanes out of their half's order (run %d)", bad, run);
    }
    g_lds_bytes = 0;
}

//  Q. s_endpgm in an EXEC scope (lanes 0-31), then v_readfirstlane in a second scope, in a
//     workgroup of two waves (128 threads). Wave 0 ends (all its lanes: s_endpgm ends the wave);
//     wave 1 (no lane < 32) stores lane 64's value. The shader is predicated as a whole (it used
//     to fall back per subgroup, counted in unpredicated_wave_regions): nothing is counted.
void TestEndThenLaneRead(id<MTLDevice> dev) {
    std::vector<uint32_t> b = {0x7D8800A0, 0xBE8C246A, 0xBF880002, 0x7E080280, kEnd, 0xBEFE040C,
                               0x7DA80002, 0xBF880000, kRflS10, kMovV3S10, kStoreV3, kStoreV3b};
    PatchExecz(b, 7);
    gcn_shader_info info{};
    const auto out = RunWave64(dev, "end then lane read", 0x5CA1AB1E00000049ULL, b, 128, {{2, 128}}, 128, nullptr,
                               &info);
    ExpectLanes("end then lane read", out, [](uint32_t l) { return l < 64 ? 0u : 164u; }, 128);
    CHECK(info.unpredicated_wave_regions == 0 && info.per_subgroup_lane_ops == 0,
          "end then lane read: %u unpredicated regions and %u per-subgroup reads counted",
          info.unpredicated_wave_regions, info.per_subgroup_lane_ops);
}

// The `if` conditions around each threadgroup_barrier of an MSL kernel (brace nesting). An empty
// result means the MSL is not shaped as expected.
std::vector<std::vector<std::string>> BarrierScopes(const std::string& msl) {
    std::vector<std::vector<std::string>> scopes;
    std::vector<std::string> open; // the `if` condition (or "" for other braces) of each open brace
    std::string pending;           // condition of an `if` / `else` whose brace comes next
    bool have_pending = false;
    const size_t start = msl.find("kernel void main0");
    if (start == std::string::npos) return scopes;
    size_t pos = start;
    while (pos < msl.size()) {
        size_t eol = msl.find('\n', pos);
        if (eol == std::string::npos) eol = msl.size();
        std::string line = msl.substr(pos, eol - pos);
        pos = eol + 1;
        const size_t first = line.find_first_not_of(" \t");
        if (first == std::string::npos) continue;
        line = line.substr(first);
        if (line.rfind("if (", 0) == 0) {
            pending = line.substr(3);
            have_pending = true;
        } else if (line == "else") {
            pending = "else";
            have_pending = true;
        } else if (line == "{") {
            open.push_back(have_pending ? pending : "");
            have_pending = false;
        } else if (line.rfind("}", 0) == 0) {
            if (!open.empty()) open.pop_back();
        } else if (line.find("threadgroup_barrier(") != std::string::npos) {
            std::vector<std::string> conds;
            for (const auto& c : open)
                if (!c.empty()) conds.push_back(c);
            scopes.push_back(conds);
        } else {
            have_pending = false;
        }
    }
    return scopes;
}

// Whether `cond` is the MSL of a WorkgroupAny result: an OR of workgroup-memory slots != 0.
bool IsWorkgroupAnyCondition(const std::string& cond) {
    if (cond.size() < 8 || cond.compare(cond.size() - 6, 6, "!= 0u)") != 0) return false;
    for (size_t i = 1; i + 6 < cond.size(); i++) {
        const char c = cond[i];
        if (!(std::isdigit(static_cast<unsigned char>(c)) || c == '_' || c == ' ' || c == '|' || c == '(' || c == ')'))
            return false;
    }
    return true;
}

//  R. No barrier in a branch that one subgroup can skip (a GPU hang). s16 = 1 is written in a
//     top-level EXEC scope of lanes 0-31 only (the other subgroup keeps another value), then in a
//     predicated bounds check with LDS, `if (s16 == 1)` (a branch per wave on the scalar
//     condition, taken by one subgroup only here) holds a nested EXEC scope. Every barrier must be
//     reached by the whole workgroup: the only branches around one are predicated ifs, which
//     branch on a WorkgroupAny result. The MSL structure is checked; the kernel is not run.
void TestNoBarrierInBranches(id<MTLDevice> dev) {
    std::vector<uint32_t> b = {
        0x7D8800A0, 0xBE8C246A, 0xBF880001, // vcc = 32 > v0; s[12:13] = saveexec(vcc); execz +1
        0xBE900381,                         // s_mov_b32 s16, 1
        0xBEFE040C,                         // s_mov_b64 exec, s[12:13]
        0x7DA80002, 0xBF880000,             // v_cmpx_gt_u32 exec, s2, v0; execz end (patched)
        0xD8340000, 0x00000102,             // ds_write_b32 v2, v1
        0xBF068110,                         // s_cmp_eq_u32 s16, 1
        0xBF840003,                         // s_cbranch_scc0 skip
        0x7DA80003, 0xBF880001,             // v_cmpx_gt_u32 exec, s3, v0; execz skip
        0x7E060281,                         // v_mov_b32 v3, 1
        0xD8D80000, 0x05000002,             // skip: ds_read_b32 v5, v2
        0x7E060305, kStoreV3, kStoreV3b,    // out[l] = v5
    };
    PatchExecz(b, 6);
    Guest g;
    uint32_t ud[16];
    std::vector<uint32_t> prog = {kAddV1, 100, kShlV2};
    prog.insert(prog.end(), b.begin(), b.end());
    prog.push_back(kEnd);
    if (!Setup(dev, g, prog, 0x5CA1AB1E00000050ULL, ud)) return;
    g_lds_bytes = 256;
    gcn_shader* sh = Compile(g, kGuestBase, ud, 64);
    g_lds_bytes = 0;
    if (!sh) return;
    const auto scopes = BarrierScopes(gcn_shader_msl(sh));
    CHECK(!scopes.empty(), "no barrier in branches: no barrier found (the case no longer predicates)");
    int bad = 0;
    for (const auto& conds : scopes)
        for (const auto& c : conds)
            if (!IsWorkgroupAnyCondition(c) && bad++ < 4)
                std::fprintf(stderr, "  no barrier in branches: a barrier inside if %s\n", c.c_str());
    CHECK(bad == 0, "no barrier in branches: %d barrier(s) in a branch not taken by every invocation", bad);
    gcn_shader_destroy(sh);
}

//  R2. A load through a V# the shader only reads, from memory it writes through another V# (two
//      V#s over one buffer): an `if` on the loaded value holds an s_barrier. On GCN the wave-wide
//      load gives all 64 lanes one value; on Metal each 32-lane simdgroup loads at its own time,
//      and a store in between (here the shader's own store through the second V#, or another
//      workgroup's) gives the halves different values: a plain branch around the barrier would
//      hang. The value does not count as wave-uniform: every barrier is outside branches or under
//      a predicated if (a WorkgroupAny result). The kernel then runs: A[0] = 1, every lane takes
//      the if and stores 1.
void TestAliasedReadOnlyLoad(id<MTLDevice> dev) {
    Guest g;
    uint32_t ud[16];
    const std::vector<uint32_t> prog = {
        kAddV1, 100, kShlV2,
        0xE0300000, 0x80000300, // buffer_load_dword v3, s[0:3] (A) offset 0
        0xBF8C0000,             // s_waitcnt
        0x7D8A0680,             // v_cmp_ne_u32 vcc, 0, v3
        0xBE8C246A,             // s_and_saveexec_b64 s[12:13], vcc
        0xBF880001,             // s_cbranch_execz +1
        0xBF8A0000,             // s_barrier
        0xBEFE040C,             // s_mov_b64 exec, s[12:13]
        0xE0700000, 0x80020300, // buffer_store_dword v3, s[8:11] (B: A's memory) offset 0
        kStoreV3, kStoreV3b,    // out[l] = v3
        kEnd,
    };
    if (!Setup(dev, g, prog, 0x5CA1AB1E00000070ULL, ud)) return;
    constexpr uint64_t kShared = kGuestBase + 0x2000;
    VSharp(&ud[0], kShared, 16, 0);
    VSharp(&ud[8], kShared, 16, 0);
    reinterpret_cast<uint32_t*>(g.p(kShared))[0] = 1;
    gcn_shader* sh = Compile(g, kGuestBase, ud, 64);
    if (!sh) return;
    const auto scopes = BarrierScopes(gcn_shader_msl(sh));
    CHECK(!scopes.empty(), "aliased read-only load: no barrier found");
    int bad = 0;
    for (const auto& conds : scopes)
        for (const auto& c : conds)
            if (!IsWorkgroupAnyCondition(c) && bad++ < 4)
                std::fprintf(stderr, "  aliased read-only load: a barrier inside if %s\n", c.c_str());
    CHECK(bad == 0, "aliased read-only load: %d barrier(s) in a branch on a value loaded from memory the shader writes",
          bad);
    if (bad == 0 && Run(dev, g, sh, ud, 64)) {
        std::vector<uint32_t> out(Out(g), Out(g) + 64);
        ExpectLanes("aliased read-only load", out, [](uint32_t) { return 1u; });
    }
    gcn_shader_destroy(sh);
}

//  S. A wave with no lane in an EXEC scope skips its scalar code (s_cbranch_execz): 128 threads,
//     s14 = 7, then a scope of lanes 0-39 with a v_readlane (predicated) and s_mov_b32 s14, 5.
//     After the scope s14 is 5 in wave 0 and still 7 in wave 1.
void TestScopeScalarCodePerWave(id<MTLDevice> dev) {
    std::vector<uint32_t> b = {0xBE8E0387, 0xBE94047E, 0x7DA80002, 0xBF880000, // s14 = 7; save exec; scope
                               0xD202000A, 0x00014101, 0xBE8E0385,             // readlane s10, v1, 32; s14 = 5
                               0xBEFE0414, 0x34140082, 0x7E06020E, 0xE0701000, 0x8001030A}; // out[l] = s14
    b[3] = 0xBF880000 | 3u; // s_cbranch_execz to the exec restore
    const auto out = RunWave64(dev, "scope scalar code per wave", 0x5CA1AB1E00000051ULL, b, 128, {{2, 40}}, 128);
    ExpectLanes("scope scalar code per wave", out, [](uint32_t l) { return l < 64 ? 5u : 7u; }, 128);
}

//  T. A v_readfirstlane whose operands are computed before its EXEC scope (lanes 0-39) is
//     computed in the scope's header, where every invocation runs: the scope itself is not
//     predicated (it writes s10 only, which nothing reads after it) and stays a real branch. The
//     value is the wave's first EXEC lane (lane 0) in lanes 32-39 too. The MSL has the exchange's
//     barrier, outside every if.
//  U. The same with s_mov_b32 s14, 5 in a scope of lanes 0-15, s14 read after the scope: the
//     subgroup of lanes 32-63 has no lane in the scope, but GCN ran the scope's scalar code for the
//     whole wave, so s14 is 5 in all 64 lanes. That needs the scope predicated: its lane read is
//     not hoisted.
void TestHoistedLaneReads(id<MTLDevice> dev) {
    std::vector<uint32_t> b = {0xBE94047E, 0x7DA80002, 0xBF880004, // save exec; scope of lanes < s2
                               kRflS10, kMovV3S10, kStoreV3, kStoreV3b, // out[l] = readfirstlane(v1)
                               0xBEFE0414};                             // restore exec
    std::string msl;
    auto out = RunWave64(dev, "hoisted readfirstlane", 0x5CA1AB1E00000052ULL, b, 64, {{2, 40}}, 64, &msl);
    ExpectLanes("hoisted readfirstlane", out, [](uint32_t l) { return l < 40 ? 100u : 0u; });
    const auto scopes = BarrierScopes(msl);
    CHECK(!scopes.empty(), "hoisted readfirstlane: no exchange barrier");
    for (const auto& conds : scopes)
        CHECK(conds.empty(), "hoisted readfirstlane: a barrier inside if %s (the scope was predicated)",
              conds.empty() ? "" : conds.front().c_str());
    b = {0xBE8E0387, 0xBE94047E, 0x7DA80002, 0xBF880005, // s14 = 7; save exec; scope of lanes < s2
         kRflS10, 0xBE8E0385, kMovV3S10, kStoreV3, kStoreV3b, // s14 = 5; out[l] = readfirstlane(v1)
         0xBEFE0414, 0x7E06020E, 0xE0701100, 0x80010302};    // restore exec; out[64 + l] = s14
    out = RunWave64(dev, "scalar state after the scope", 0x5CA1AB1E00000053ULL, b, 128, {{2, 16}});
    ExpectLanes("scalar state after the scope", out,
                [](uint32_t l) { return l < 16 ? 100u : l < 64 ? 0u : 5u; }, 128);
}

//  V. A v_readlane whose source VGPR is written in the scope must not be hoisted into the if's
//     header: a lane outside EXEC keeps its register, not the value the scope writes. v7 = 500 +
//     lane before the scope; EXEC saved; scope of lanes < s2; in the scope v1 = v7, then
//     s10 = readlane(v1, 50). Lane 50 is outside EXEC when s2 <= 50, so its v1 is the pre-scope
//     150 (RunWave64 sets v1 = 100 + lane), and readlane broadcasts 150 to the lanes that run it.
//     If the readlane were hoisted (computed from v7 in the header), every lane would read 550.
//     v7 is lane-dependent so the readlane source does not fold to a constant. This is the same
//     scope shape as `hoisted readfirstlane`, which does hoist; only the in-scope write of the
//     source register stops it.
void TestReadLaneSourceWrittenInScope(id<MTLDevice> dev) {
    const uint32_t add_v7[] = {0x4A0E00FF, 500};         // v_add_i32 v7, vcc, 500, v0
    const uint32_t mov_v1_v7 = 0x7E020307;               // v_mov_b32 v1, v7
    const uint32_t readlane[] = {0xD202000A, 0x00016501}; // v_readlane_b32 s10, v1, 50
    // root region: EXEC saved, a scope of lanes < s2, restored after
    std::vector<uint32_t> b = {add_v7[0], add_v7[1], 0xBE94047E, 0x7DA80002, 0xBF880006,
                               mov_v1_v7, readlane[0], readlane[1], kMovV3S10, kStoreV3, kStoreV3b,
                               0xBEFE0414};
    auto out = RunWave64(dev, "readlane source written in scope (root)", 0x5CA1AB1E00000054ULL, b, 64, {{2, 40}});
    ExpectLanes("readlane source written in scope (root)", out, [](uint32_t l) { return l < 40 ? 150u : 0u; });
    // under a predicated parent: an outer scope of lanes 0-59 with an LDS write (predicated), the
    // readlane scope nested in it. MaskBlock would read v1 at the inner header, before v1 = v7.
    g_lds_bytes = 256;
    b = {add_v7[0], add_v7[1], 0x7DA80003, 0xBF88000B,       // outer scope lanes < s3 (patched)
         0x7E0A0280, 0xD8340000, 0x00000501,                 // v5 = 0; ds_write_b32 v2, v5
         0xBE94047E, 0x7DA80002, 0xBF880006,                 // save exec; inner scope lanes < s2
         mov_v1_v7, readlane[0], readlane[1], kMovV3S10, kStoreV3, kStoreV3b, // v1 = v7; out[l] = readlane
         0xBEFE0414};                                        // restore exec (inner)
    PatchExecz(b, 3);
    out = RunWave64(dev, "readlane source written in scope (predicated parent)", 0x5CA1AB1E00000055ULL, b, 64,
                    {{2, 40}, {3, 60}});
    ExpectLanes("readlane source written in scope (predicated parent)", out, [](uint32_t l) { return l < 40 ? 150u : 0u; });
    g_lds_bytes = 0;
    // 128 threads (two waves): the shader compiles with several subgroups; lanes outside EXEC keep
    // their old register (0 where they never ran)
    b = {add_v7[0], add_v7[1], 0xBE94047E, 0x7DA80002, 0xBF880006,
         mov_v1_v7, readlane[0], readlane[1], kMovV3S10, kStoreV3, kStoreV3b, 0xBEFE0414};
    out = RunWave64(dev, "readlane source written in scope (two waves)", 0x5CA1AB1E00000056ULL, b, 128, {{2, 40}}, 128);
    ExpectLanes("readlane source written in scope (two waves)", out, [](uint32_t l) { return l < 40 ? 150u : 0u; }, 128);
}

//  W. A break out of an EXEC scope in a loop that needs the whole wave: 128 threads; a loop of 2
//     or 3 iterations by lane (v7 < v8) whose body has an if of lanes 0-39 with s10 =
//     v_readfirstlane v1, s14 = s10 + 5 and a break; the other path writes s14 = 9. GCN branches
//     per wave: the break (an s_branch) takes all of wave 0 out of the loop with s14 = 105 (lane
//     0's v1 + 5), and wave 1 (no lane < 40) runs its iterations and ends with s14 = 9. The loop
//     and the if are predicated (PredicateBreak); a loop left by a break nested in an if used to
//     be left per subgroup (lanes 32-63 read lane 32: 137).
void TestBreakInScope(id<MTLDevice> dev) {
    const std::vector<uint32_t> b = {
        0x36100081, 0x4A101082,             // v8 = (v0 & 1) + 2
        0xBE8E0387, 0xBE94047E, 0x7E0E0280, // s14 = 7; s[20:21] = exec; v7 = 0
        0x7DA21107, 0xBF88000B,             // loop: v_cmpx_lt_u32 exec, v7, v8; execz -> after the loop
        0xBE96047E,                         // s[22:23] = exec (the loop's lanes)
        0x7DA80002, 0xBF880004,             // v_cmpx_gt_u32 exec, s2, v0; execz -> else (the if, lanes < 40)
        kRflS10, 0x800E850A,                // v_readfirstlane s10, v1; s_add_u32 s14, s10, 5
        0xBEFE0414, 0xBF820004,             // exec = s[20:21]; s_branch -> after the loop (break)
        0xBEFE0416, 0xBE8E0389,             // else: exec = s[22:23]; s14 = 9
        0x4A0E0E81, 0xBF82FFF3,             // v7 += 1; s_branch loop
        0xBEFE0414,                         // after the loop: exec = s[20:21]
        0x34140082, 0x7E06020E, 0xE0701000, 0x8001030A}; // out[l] = s14
    gcn_shader_info info{};
    const auto out = RunWave64(dev, "break in scope", 0x5CA1AB1E00000057ULL, b, 128, {{2, 40}}, 128, nullptr, &info);
    CHECK(info.unpredicated_wave_regions == 0, "break in scope: %u region(s) not predicated", info.unpredicated_wave_regions);
    ExpectLanes("break in scope", out, [](uint32_t l) { return l < 64 ? 105u : 9u; }, 128);
}

//  X. A register of a vector type written in a predicated region: buffer_load_dwordx3 into
//     v[4:6] before an EXEC scope of lanes < 40 and again in it (another offset), so the value
//     after the scope can be a phi of the two loads' U32x3 results, kept in a register of that
//     type. The scope also has v1 = v7; s10 = v_readlane(v1, 50), which needs the whole wave and
//     cannot be hoisted (its source is written in the scope): the scope is predicated, and the
//     vector register's write there is masked per component. Lanes < 40 get the dwords at offset
//     16 of the program, the others those at offset 0; s10 = 150 (lane 50 is outside EXEC and
//     keeps v1 = 100 + 50) in every lane. A predication that gave up on the vector register left
//     the scope per subgroup (counted in unpredicated_wave_regions) and read lane 50 from the
//     lane's own subgroup.
void TestVectorRegisterInPredicatedScope(id<MTLDevice> dev) {
    uint32_t v[4];
    VSharp(v, kGuestBase, 64, 0);
    std::vector<uint32_t> b = {
        0x4A0E00FF, 500,        // v7 = 500 + v0
        0xE03C0000, 0x80020400, // buffer_load_dwordx3 v[4:6], off, s[8:11] offset:0
        0xBE94047E,             // s[20:21] = exec
        0x7DA80002, 0,          // v_cmpx_gt_u32 exec, s2, v0; execz -> the restore (patched)
        0xE03C0010, 0x80020400, // buffer_load_dwordx3 v[4:6], off, s[8:11] offset:16
        0x7E020307,             // v1 = v7
        0xD202000A, 0x00016501, // v_readlane_b32 s10, v1, 50
    };
    PatchExecz(b, 6);
    for (uint32_t w : {0xBEFE0414u,              // exec = s[20:21]
                       0x34140084u,              // v10 = v0 << 4
                       0xE0701000u, 0x8001040Au, 0xE0701004u, 0x8001050Au, 0xE0701008u, 0x8001060Au,
                       kMovV3S10, 0xE070100Cu, 0x8001030Au}) // out[4l .. 4l + 3] = v4, v5, v6, s10
        b.push_back(w);
    gcn_shader_info info{};
    const auto out = RunWave64(dev, "vector register in a predicated scope", 0x5CA1AB1E00000058ULL, b, 256,
                               {{2, 40}, {8, v[0]}, {9, v[1]}, {10, v[2]}, {11, v[3]}}, 64, nullptr, &info);
    CHECK(info.unpredicated_wave_regions == 0, "vector register in a predicated scope: %u region(s) not predicated",
          info.unpredicated_wave_regions);
    // the program in guest memory: the WithFooter header (2 dwords), then RunWave64's prefix
    const std::vector<uint32_t> prog = WithFooter([&] {
        std::vector<uint32_t> p = {kAddV1, 100, kShlV2};
        p.insert(p.end(), b.begin(), b.end());
        p.push_back(kEnd);
        return p;
    }(), 0);
    ExpectWords("vector register in a predicated scope", out, 64, 4, [&](uint32_t l, uint32_t k) {
        return k == 3 ? 150u : prog[(l < 40 ? 4 : 0) + k];
    });
}

//  Y. A break of an outer loop from an if in an inner loop: 128 threads; an outer loop of 3
//     iterations on a scalar counter (s15 < 3), an inner loop of 2 or 3 iterations by lane, and in
//     it an if of lanes 0-39 with s14 = v_readfirstlane(v1) + 5 and an s_branch past both loops.
//     Wave 0 leaves both loops in its first inner iteration with s14 = 105; wave 1 runs all of them
//     and keeps s14 = 7. Every invocation runs the predicated loops until none is in them: the
//     inner loop, which the break leaves too, must end once every invocation left it this way.
void TestBreakOfOuterLoop(id<MTLDevice> dev) {
    const std::vector<uint32_t> b = {
        0x36100081, 0x4A101082,             // v8 = (v0 & 1) + 2
        0xBE8E0387, 0xBE94047E, 0xBE8F0380, // s14 = 7; s[20:21] = exec; s15 = 0
        0xBF0A830F, 0xBF840011,             // outer: s_cmp_lt_u32 s15, 3; s_cbranch_scc0 -> after
        0x7E0E0280, 0xBE96047E,             // v7 = 0; s[22:23] = exec
        0x7DA21107, 0xBF88000A,             // inner: v_cmpx_lt_u32 exec, v7, v8; execz -> inner end
        0xBE98047E, 0x7DA80002, 0xBF880004, // s[24:25] = exec; v_cmpx_gt_u32 exec, s2, v0; execz -> else
        kRflS10, 0x800E850A,                // v_readfirstlane s10, v1; s_add_u32 s14, s10, 5
        0xBEFE0414, 0xBF820006,             // exec = s[20:21]; s_branch -> after (out of both loops)
        0xBEFE0418, 0x4A0E0E81, 0xBF82FFF4, // else: exec = s[24:25]; v7 += 1; s_branch inner
        0xBEFE0416, 0x800F810F, 0xBF82FFED, // inner end: exec = s[22:23]; s15 += 1; s_branch outer
        0xBEFE0414,                         // after: exec = s[20:21]
        0x34140082, 0x7E06020E, 0xE0701000, 0x8001030A}; // out[l] = s14
    gcn_shader_info info{};
    const auto out = RunWave64(dev, "break of an outer loop", 0x5CA1AB1E00000059ULL, b, 128, {{2, 40}}, 128, nullptr, &info);
    CHECK(info.unpredicated_wave_regions == 0, "break of an outer loop: %u region(s) not predicated",
          info.unpredicated_wave_regions);
    ExpectLanes("break of an outer loop", out, [](uint32_t l) { return l < 64 ? 105u : 7u; }, 128);
}

//  Z. s_endpgm in an EXEC scope, then a barrier: 128 threads; a scope of lanes 0-39 ends the
//     program (s_endpgm ends the whole wave on GCN, every lane of it, whatever EXEC is). Wave 1
//     (no lane < 40) goes on: s_barrier, s10 = v_readfirstlane v1 (lane 64: 164), out[l] = s10.
//     Wave 0 stores nothing. The waves that ended must still not leave the barrier waiting: the
//     program is predicated, and the end only clears the wave's predicates.
void TestEndInScope(id<MTLDevice> dev) {
    const std::vector<uint32_t> b = {
        0xBE94047E,             // s[20:21] = exec
        0x7DA80002, 0xBF880001, // v_cmpx_gt_u32 exec, s2, v0; execz -> the restore
        0xBF810000,             // s_endpgm
        0xBEFE0414,             // exec = s[20:21]
        0xBF8A0000,             // s_barrier
        kRflS10, kMovV3S10, kStoreV3, kStoreV3b}; // out[l] = v_readfirstlane(v1)
    gcn_shader_info info{};
    const auto out = RunWave64(dev, "end in scope", 0x5CA1AB1E0000005AULL, b, 128, {{2, 40}}, 128, nullptr, &info);
    CHECK(info.unpredicated_wave_regions == 0, "end in scope: %u region(s) not predicated", info.unpredicated_wave_regions);
    ExpectLanes("end in scope", out, [](uint32_t l) { return l < 64 ? 0u : 164u; }, 128);
}

//  U. v_writelane in a predicated scope: 128 threads, v5 = v1 (100 + lane); a scope of lanes 0-39
//     (predicated: it holds v1 = v7; v_readlane s10, v1, 50, whose source it writes) with s12 = 9
//     and v_writelane v5, s12, 50. GCN writes lane 50 whatever EXEC is, but only in a wave that
//     runs the instruction: wave 0 does (lane 50 = 9), wave 1 skips the scope (s_cbranch_execz)
//     and keeps lane 114 = 214. Every invocation runs predicated code, so the write must be masked
//     with the wave predicate.
void TestWriteLaneInPredicatedScope(id<MTLDevice> dev) {
    std::vector<uint32_t> b = {
        0x7E0A0301,             // v5 = v1
        0x4A0E00FF, 500,        // v7 = 500 + v0
        0xBE94047E,             // s[20:21] = exec
        0x7DA80002, 0,          // v_cmpx_gt_u32 exec, s2, v0; execz -> the restore (patched)
        0x7E020307,             // v1 = v7
        0xD202000A, 0x00016501, // v_readlane_b32 s10, v1, 50
        0xBE8C0389,             // s12 = 9
        0xD2040005, 0x0001640C, // v_writelane_b32 v5, s12, 50
    };
    PatchExecz(b, 5);
    for (uint32_t w : {0xBEFE0414u, 0x7E060305u, kStoreV3, kStoreV3b}) b.push_back(w); // out[l] = v5
    const auto out = RunWave64(dev, "writelane in a predicated scope", 0x5CA1AB1E0000005BULL, b, 128, {{2, 40}}, 128);
    ExpectLanes("writelane in a predicated scope", out, [](uint32_t l) { return l == 50 ? 9u : 100u + l; }, 128);
}

//  F1-F4. The fallback path of the wave64 predication (forced with GCN_COMPILE_WAVE64_FALLBACK, as
//     no shader of the tests or the corpora reaches it any more): its regions stay per subgroup.
//     A guest barrier in per-subgroup code must fail the translation (the renderer skips the
//     dispatches) instead of hanging the GPU. These shaders are translated, never run.
//     F1: s_barrier in an EXEC scope of lanes 0-39.
//     F2: s_barrier in a uniform if (on user data s3) nested in that scope.
//     F3: s_endpgm in the scope, then s_barrier at the top level (the ended invocations never
//         reach it).
//     F4: v_readfirstlane in the scope and no barrier: it translates, the regions and the lane
//         read left per subgroup are counted, and the counts survive the shader cache.
std::string FallbackCompileError(id<MTLDevice> dev, const std::vector<uint32_t>& body, uint64_t hash) {
    Guest g;
    uint32_t ud[16];
    std::vector<uint32_t> prog = {kAddV1, 100, kShlV2};
    prog.insert(prog.end(), body.begin(), body.end());
    prog.push_back(kEnd);
    if (!Setup(dev, g, prog, hash, ud)) return "setup";
    ud[2] = 40;
    g_compile_flags = GCN_COMPILE_WAVE64_FALLBACK;
    g_expect_compile_error = true;
    Compile(g, kGuestBase, ud, 128);
    g_expect_compile_error = false;
    g_compile_flags = 0;
    return g_compile_error;
}

void TestFallbackRefusesBarriers(id<MTLDevice> dev) {
    const char* const refusal = "barrier in per-subgroup control flow";
    std::vector<uint32_t> f1 = {0xBE94047E, 0x7DA80002, 0, 0xBF8A0000}; // scope { s_barrier }
    PatchExecz(f1, 2);
    f1.push_back(0xBEFE0414);
    std::string e = FallbackCompileError(dev, f1, 0x5CA1AB1E00000060ULL);
    CHECK(e.find(refusal) != std::string::npos, "fallback F1: a barrier in an EXEC scope translates (%s)", e.c_str());
    // scope { s_cmp_eq_u32 s3, 0; s_cbranch_scc1 +1; s_barrier }
    std::vector<uint32_t> f2 = {0xBE94047E, 0x7DA80002, 0, 0xBF068003, 0xBF850001, 0xBF8A0000};
    PatchExecz(f2, 2);
    f2.push_back(0xBEFE0414);
    e = FallbackCompileError(dev, f2, 0x5CA1AB1E00000061ULL);
    CHECK(e.find(refusal) != std::string::npos, "fallback F2: a barrier in a uniform if in an EXEC scope translates (%s)",
          e.c_str());
    // scope { s_endpgm }; s_barrier
    const std::vector<uint32_t> f3 = {0xBE94047E, 0x7DA80002, 0xBF880001, 0xBF810000, 0xBEFE0414, 0xBF8A0000};
    e = FallbackCompileError(dev, f3, 0x5CA1AB1E00000062ULL);
    CHECK(e.find(refusal) != std::string::npos, "fallback F3: a barrier after an end in a scope translates (%s)",
          e.c_str());
    // F4: scope { v_readfirstlane s10, v1 }; out[l] = s10
    std::vector<uint32_t> f4 = {0xBE94047E, 0x7DA80002, 0, kRflS10};
    PatchExecz(f4, 2);
    for (uint32_t w : {0xBEFE0414u, kMovV3S10, kStoreV3, kStoreV3b}) f4.push_back(w);
    Guest g;
    uint32_t ud[16];
    std::vector<uint32_t> prog = {kAddV1, 100, kShlV2};
    prog.insert(prog.end(), f4.begin(), f4.end());
    prog.push_back(kEnd);
    if (!Setup(dev, g, prog, 0x5CA1AB1E00000063ULL, ud)) return;
    ud[2] = 40;
    g_compile_flags = GCN_COMPILE_WAVE64_FALLBACK;
    gcn_shader* sh = Compile(g, kGuestBase, ud, 128);
    g_compile_flags = 0;
    if (!sh) return;
    gcn_shader_info info{};
    gcn_shader_get_info(sh, &info);
    CHECK(info.unpredicated_wave_regions == 1 && info.per_subgroup_lane_ops == 1,
          "fallback F4: %u unpredicated regions and %u per-subgroup reads counted, expected 1 and 1",
          info.unpredicated_wave_regions, info.per_subgroup_lane_ops);
    void* blob = nullptr;
    size_t n = 0;
    gcn_shader* back = nullptr;
    char err[256] = {};
    CHECK(gcn_shader_serialize(sh, &blob, &n) == GCN_OK &&
              gcn_shader_deserialize(blob, n, kGuestBase, &back, err, sizeof(err)) == GCN_OK && back,
          "fallback F4: shader cache round trip failed: %s", err);
    if (back) {
        gcn_shader_info cached{};
        gcn_shader_get_info(back, &cached);
        CHECK(cached.unpredicated_wave_regions == info.unpredicated_wave_regions &&
                  cached.per_subgroup_lane_ops == info.per_subgroup_lane_ops,
              "fallback F4: the cache kept %u / %u", cached.unpredicated_wave_regions, cached.per_subgroup_lane_ops);
        gcn_shader_destroy(back);
    }
    gcn_free(blob);
    gcn_shader_destroy(sh);
}

//  Z2. s_endpgm in an EXEC scope with nothing after it that needs the whole wave (a store of v1):
//      the program is not predicated (no workgroup vote, no barrier: the end stays a return of
//      the lanes that reach it). Lanes 0-31 end and store nothing. GCN ends the whole wave; that
//      the translation lets lanes 32-63 store is a known gap, counted in per_lane_ends (1), which
//      the shader cache keeps.
void TestEndWithoutWaveNeeds(id<MTLDevice> dev) {
    const std::vector<uint32_t> body = {0x7D8800A0, 0xBE8C246A, 0xBF880002, 0x7E080280, kEnd, 0xBEFE040C,
                                        0x7E060301, kStoreV3, kStoreV3b};
    std::string msl;
    gcn_shader_info info{};
    const auto out = RunWave64(dev, "end without wave needs", 0x5CA1AB1E0000005CULL, body, 64, {}, 64, &msl, &info);
    ExpectLanes("end without wave needs", out, [](uint32_t) { return 0u; }, 32);
    CHECK(!out.empty() && msl.find("threadgroup_barrier") == std::string::npos,
          "end without wave needs: the program is predicated");
    CHECK(info.per_lane_ends == 1, "end without wave needs: %u per-lane end(s) counted, expected 1", info.per_lane_ends);
    Guest g;
    uint32_t ud[16];
    std::vector<uint32_t> prog = {kAddV1, 100, kShlV2};
    prog.insert(prog.end(), body.begin(), body.end());
    prog.push_back(kEnd);
    if (!Setup(dev, g, prog, 0x5CA1AB1E0000005CULL, ud)) return;
    gcn_shader* sh = Compile(g, kGuestBase, ud, 64);
    if (!sh) return;
    void* blob = nullptr;
    size_t n = 0;
    gcn_shader* back = nullptr;
    char err[256] = {};
    CHECK(gcn_shader_serialize(sh, &blob, &n) == GCN_OK &&
              gcn_shader_deserialize(blob, n, kGuestBase, &back, err, sizeof(err)) == GCN_OK && back,
          "end without wave needs: shader cache round trip failed: %s", err);
    if (back) {
        gcn_shader_info cached{};
        gcn_shader_get_info(back, &cached);
        CHECK(cached.per_lane_ends == 1, "end without wave needs: the cache kept %u per-lane end(s)", cached.per_lane_ends);
        gcn_shader_destroy(back);
    }
    gcn_free(blob);
    gcn_shader_destroy(sh);
}

// A scope of lanes 0-39 with an EXEC loop of 1 iteration (even lanes) or 2 (odd lanes). Each
// iteration computes s[26:27] with `mask` and runs a waterfall over it: s16 += 1,
// v_readfirstlane, v_cmpx_eq, s_andn2_b64 s[26:27] between VALU instructions (the branch then
// reads SCC in the next block), s_mov exec, s_cbranch_scc1, with a bail-out (s[26:27] = 0 once s16
// reaches 64). The value is the same in every lane, so when `mask` gives no bit outside EXEC each
// waterfall runs once: s16 = 2 after the scope, stored by every lane. A bit set in lanes 40-63
// (outside the scope) kept the waterfall going until the bail-out (s16 = 65 there).
std::vector<uint32_t> MaskWaterfall(const std::vector<uint32_t>& mask) {
    std::vector<uint32_t> b = {
        0xBE900380,             // s16 = 0
        0xBE94047E,             // s_mov_b64 s[20:21], exec
        0x7DA80002, 0,          // v_cmpx_gt_u32 exec, s2, v0; s_cbranch_execz -> end (the scope's end)
        0x36100081, 0x4A101081, // v8 = (v0 & 1) + 1
        0x7E0E0280,             // v7 = 0
        0xBE96047E,             // s_mov_b64 s[22:23], exec
    };
    const size_t loop = b.size();
    b.insert(b.end(), {0x7DA21107, 0}); // loop: v_cmpx_lt_u32 exec, v7, v8; s_cbranch_execz -> end
    b.push_back(0xBE98047E);            // s_mov_b64 s[24:25], exec
    b.insert(b.end(), mask.begin(), mask.end());
    b.insert(b.end(), {0x7E1E0500, 0x7E12020F}); // v_readfirstlane_b32 s15, v0; v9 = s15 (one value)
    const size_t waterfall = b.size();
    b.insert(b.end(), {
                          0x80108110,             // s_add_u32 s16, s16, 1
                          0xBF09C010, 0x859A1A80, // s_cmp_ge_u32 s16, 64; s_cselect_b64 s[26:27], 0, s[26:27]
                          0x7E1C0509,             // v_readfirstlane_b32 s14, v9
                          0xD1A4001C, 0x0002120E, // v_cmpx_eq_u32 s[28:29], s14, v9
                          0x7E280300,             // v_mov_b32 v20, v0
                          0x8A9A1C1A,             // s_andn2_b64 s[26:27], s[26:27], s[28:29]
                          0x7E2A0300,             // v_mov_b32 v21, v0
                          0xBEFE041A,             // s_mov_b64 exec, s[26:27]
                      });
    const auto branch = [&](uint32_t op, size_t to) {
        b.push_back(op | (uint32_t(int32_t(to) - int32_t(b.size()) - 1) & 0xFFFF));
    };
    branch(0xBF850000, waterfall); // s_cbranch_scc1
    b.insert(b.end(), {0xBEFE0418, 0x4A0E0E81}); // s_mov_b64 exec, s[24:25]; v7 += 1
    branch(0xBF820000, loop);                    // s_branch
    const size_t end = b.size();
    b[3] = 0xBF880000 | uint32_t(end - 4);
    b[loop + 1] = 0xBF880000 | uint32_t(end - loop - 2);
    b.insert(b.end(), {0xBEFE0414, 0x7E060210, kStoreV3, kStoreV3b}); // exec = s[20:21]; out[l] = s16
    return b;
}

void RunMaskWaterfall(id<MTLDevice> dev, const char* name, uint64_t hash, const std::vector<uint32_t>& mask) {
    gcn_shader_info info{};
    const auto out = RunWave64(dev, name, hash, MaskWaterfall(mask), 64, {{2, 40}}, 64, nullptr, &info);
    CHECK(info.unpredicated_wave_regions == 0, "%s: %u region(s) not predicated", name, info.unpredicated_wave_regions);
    ExpectLanes(name, out, [](uint32_t) { return 2u; });
}

//  AA. A copy of EXEC into an SGPR pair in a predicated loop, then a waterfall loop over the pair
//     (as in Uncharted 4's async 1x1x1 CS, pgm 0x4c7184e105f63818, whose waterfall never ended):
//     MaskWaterfall with s_mov_b64 s[26:27], exec. s_mov_b64 is a scalar instruction: it writes all
//     64 bits for the wave, 0 for the lanes outside EXEC (40-63 here). Written only for the lanes in
//     EXEC, those lanes' bits stayed undefined, and while one was set the waterfall went on for
//     those lanes; with the undefined locals set (g_poison_locals), it went on until the bail-out
//     (s16 = 65 in lanes 40-63).
//  AB, AC. The bit outside EXEC of masks combined by s_orn2_b64 (LogicalOr, LogicalNot) and
//     s_xnor_b64 (LogicalXor, LogicalNot) from a v_cmp result (0 outside EXEC) and an SGPR pair of
//     all ones (the lane's own bit): s_orn2_b64 s[26:27], cmp, ones and s_xnor_b64 s[26:27], ones,
//     cmp are 0 in every lane, the lanes outside EXEC included.
void TestExecCopyInPredicatedLoop(id<MTLDevice> dev) {
    RunMaskWaterfall(dev, "exec copy in a predicated loop", 0x5CA1AB1E0000005DULL, {0xBE9A047E});
    const std::vector<uint32_t> ones_and_cmp = {
        0xBE9E03C1, 0xBE9F03C1, // s30 = -1; s31 = -1
        0xD1880020, 0x00020080, // v_cmp_gt_u32 s[32:33], 0, v0 (false)
    };
    std::vector<uint32_t> orn2 = ones_and_cmp, xnor = ones_and_cmp;
    orn2.push_back(0x8B9A1E20); // s_orn2_b64 s[26:27], s[32:33], s[30:31]
    xnor.push_back(0x8E9A201E); // s_xnor_b64 s[26:27], s[30:31], s[32:33]
    RunMaskWaterfall(dev, "s_orn2_b64 mask in a predicated loop", 0x5CA1AB1E0000005EULL, orn2);
    RunMaskWaterfall(dev, "s_xnor_b64 mask in a predicated loop", 0x5CA1AB1E0000005FULL, xnor);
}

//  AD. A copy of EXEC made in a loop and used after it (a loop result, KeepLoopResults): a scope of
//     lanes 0-39 with an EXEC loop whose first block copies EXEC into s[26:27] and that is left by a
//     scalar exit after 2 iterations (s_cbranch_scc1) or by EXEC (s_cbranch_execz); after the
//     scalar exit, a waterfall over s[26:27] as in MaskWaterfall (one value in the wave: one
//     iteration, s16 = 1 in every lane). The register that carries the copy out of the loop holds
//     a 64-bit mask's bit, written for the whole wave (0 for lanes 40-63); written only for the
//     lanes in EXEC, those lanes kept an undefined bit.
void TestMaskLoopResult(id<MTLDevice> dev) {
    const std::vector<uint32_t> b = {
        0xBE900380, 0xBE94047E, // s16 = 0; s_mov_b64 s[20:21], exec
        0x7DA80002, 0xBF88001B, // v_cmpx_gt_u32 exec, s2, v0; s_cbranch_execz -> 31
        0xBE910380, 0x7E0E0280, // s17 = 0; v7 = 0
        0x36100081, 0x4A101081, // v8 = (v0 & 1) + 1
        0xBE9A047E,             // 8: loop: s_mov_b64 s[26:27], exec
        0x80118111, 0xBF098211, // s_add_u32 s17, s17, 1; s_cmp_ge_u32 s17, 2
        0xBF850004,             // s_cbranch_scc1 -> 16
        0x7DA21107, 0xBF880010, // v_cmpx_lt_u32 exec, v7, v8; s_cbranch_execz -> 30
        0x4A0E0E81, 0xBF82FFF8, // v7 += 1; s_branch -> 8
        0x7E1E0500, 0x7E12020F, // 16: v_readfirstlane_b32 s15, v0; v9 = s15
        0x80108110,             // 18: waterfall: s_add_u32 s16, s16, 1
        0xBF09C010, 0x859A1A80, // s_cmp_ge_u32 s16, 64; s_cselect_b64 s[26:27], 0, s[26:27] (bail out)
        0x7E1C0509,             // v_readfirstlane_b32 s14, v9
        0xD1A4001C, 0x0002120E, // v_cmpx_eq_u32 s[28:29], s14, v9
        0x7E280300, 0x8A9A1C1A, // v_mov_b32 v20, v0; s_andn2_b64 s[26:27], s[26:27], s[28:29]
        0x7E2A0300, 0xBEFE041A, // v_mov_b32 v21, v0; s_mov_b64 exec, s[26:27]
        0xBF85FFF5,             // 28: s_cbranch_scc1 -> 18
        0xBF820001,             // s_branch -> 31
        0xBF800000,             // 30: s_nop (the EXEC exit)
        0xBEFE0414,             // 31: s_mov_b64 exec, s[20:21]
        0x7E060210, kStoreV3, kStoreV3b, // out[l] = s16
    };
    gcn_shader_info info{};
    const auto out = RunWave64(dev, "exec copy as a loop result", 0x5CA1AB1E00000071ULL, b, 64, {{2, 40}}, 64,
                               nullptr, &info);
    CHECK(info.unpredicated_wave_regions == 0, "exec copy as a loop result: %u region(s) not predicated",
          info.unpredicated_wave_regions);
    ExpectLanes("exec copy as a loop result", out, [](uint32_t) { return 1u; });
}

//  AE. A v_cmp result of a predicated loop combined with EXEC after it into a mask: a scope of
//     lanes 0-39 with an EXEC loop (v_cmp_lt_u32 vcc, v7, v8; s_and_b64 exec, exec, vcc;
//     s_cbranch_execz), then s_and_b64 s[26:27], exec, vcc and a waterfall over s[26:27] as in
//     MaskWaterfall. VCC is 0 when the loop ends, so the waterfall runs once: s16 = 1 in every
//     lane. The loop's VCC reaches the mask only through LogicalAnd(EXEC, cmp), which has no
//     lane's-own-bit source: its loop-result register was not counted as a mask register and the
//     shader stopped translating (OutsideExecBit: an unhandled source).
void TestMaskOfLoopCompare(id<MTLDevice> dev) {
    const std::vector<uint32_t> b = {
        0xBE900380, 0xBE94047E, // s16 = 0; s_mov_b64 s[20:21], exec
        0x7DA80002, 0xBF880018, // v_cmpx_gt_u32 exec, s2, v0; s_cbranch_execz -> 28
        0x36100081, 0x4A101081, // v8 = (v0 & 1) + 1
        0x7E0E0280, 0xBE96047E, // v7 = 0; s_mov_b64 s[22:23], exec
        0x7D821107, 0x87FE6A7E, // 8: loop: v_cmp_lt_u32 vcc, v7, v8; s_and_b64 exec, exec, vcc
        0xBF880002,             // s_cbranch_execz -> 13
        0x4A0E0E81, 0xBF82FFFB, // v7 += 1; s_branch -> 8
        0xBEFE0416, 0x879A6A7E, // 13: s_mov_b64 exec, s[22:23]; s_and_b64 s[26:27], exec, vcc
        0x7E1E0500, 0x7E12020F, // v_readfirstlane_b32 s15, v0; v9 = s15
        0x80108110,             // 17: waterfall: s_add_u32 s16, s16, 1
        0xBF09C010, 0x859A1A80, // s_cmp_ge_u32 s16, 64; s_cselect_b64 s[26:27], 0, s[26:27] (bail out)
        0x7E1C0509,             // v_readfirstlane_b32 s14, v9
        0xD1A4001C, 0x0002120E, // v_cmpx_eq_u32 s[28:29], s14, v9
        0x7E280300, 0x8A9A1C1A, // v_mov_b32 v20, v0; s_andn2_b64 s[26:27], s[26:27], s[28:29]
        0x7E2A0300, 0xBEFE041A, // v_mov_b32 v21, v0; s_mov_b64 exec, s[26:27]
        0xBF85FFF5,             // 27: s_cbranch_scc1 -> 17
        0xBEFE0414,             // 28: s_mov_b64 exec, s[20:21]
        0x7E060210, kStoreV3, kStoreV3b, // out[l] = s16
    };
    gcn_shader_info info{};
    const auto out = RunWave64(dev, "loop v_cmp in a mask", 0x5CA1AB1E00000072ULL, b, 64, {{2, 40}}, 64, nullptr, &info);
    CHECK(info.unpredicated_wave_regions == 0, "loop v_cmp in a mask: %u region(s) not predicated",
          info.unpredicated_wave_regions);
    ExpectLanes("loop v_cmp in a mask", out, [](uint32_t) { return 1u; });
}

//  AF. A copy of EXEC made in a loop, used outside every region of a program whose lanes may end:
//     128 threads; lanes 0-31 end (s_endpgm in an EXEC scope: wave 0 ends). Then a do-while EXEC
//     loop (s_mov_b64 s[26:27], exec; v7 += 1; v_cmpx_lt_u32 v7, v8; s_cbranch_execnz) of 1
//     iteration (even lanes) or 2 (odd lanes): s[26:27] holds the odd lanes when it ends. Then
//     s_mov_b64 exec, s[26:27] and a waterfall over s[26:27] that stores s16 in the lanes of its
//     EXEC: odd lanes of wave 1 store 1, the others nothing. The loop-result register was written
//     only where P held, so even lanes kept their first iteration's bit (1) and stored too.
void TestMaskLoopResultWithEnds(id<MTLDevice> dev) {
    const std::vector<uint32_t> b = {
        0x7D8800A0, 0xBE8C246A, // v_cmp_gt_u32 vcc, 32, v0; s_and_saveexec_b64 s[12:13], vcc
        0xBF880001, kEnd,       // s_cbranch_execz -> 4; s_endpgm
        0xBEFE040C,             // 4: s_mov_b64 exec, s[12:13]
        0xBE900380, 0xBE94047E, // s16 = 0; s_mov_b64 s[20:21], exec
        0x7E0E0280, 0x36100081, 0x4A101081, // v7 = 0; v8 = (v0 & 1) + 1
        0xBE9A047E, 0x4A0E0E81, // 10: loop: s_mov_b64 s[26:27], exec; v7 += 1
        0x7DA21107, 0xBF89FFFC, // v_cmpx_lt_u32 exec, v7, v8; s_cbranch_execnz -> 10
        0xBEFE041A,             // s_mov_b64 exec, s[26:27]
        0x7E1E0500, 0x7E12020F, // v_readfirstlane_b32 s15, v0; v9 = s15
        0x80108110,             // 17: waterfall: s_add_u32 s16, s16, 1
        0xBF09C010, 0x859A1A80, // s_cmp_ge_u32 s16, 64; s_cselect_b64 s[26:27], 0, s[26:27] (bail out)
        0x7E1C0509,             // v_readfirstlane_b32 s14, v9
        0xD1A4001C, 0x0002120E, // v_cmpx_eq_u32 s[28:29], s14, v9
        0x7E060210, kStoreV3, kStoreV3b, // out[l] = s16
        0x8A9A1C1A, 0x7E2A0300, // s_andn2_b64 s[26:27], s[26:27], s[28:29]; v_mov_b32 v21, v0
        0xBEFE041A, 0xBF85FFF3, // s_mov_b64 exec, s[26:27]; 29: s_cbranch_scc1 -> 17
        0xBEFE0414,             // s_mov_b64 exec, s[20:21]
    };
    gcn_shader_info info{};
    const auto out = RunWave64(dev, "loop result with ends", 0x5CA1AB1E00000073ULL, b, 128, {}, 128, nullptr, &info);
    CHECK(info.unpredicated_wave_regions == 0, "loop result with ends: %u region(s) not predicated",
          info.unpredicated_wave_regions);
    ExpectLanes("loop result with ends", out, [](uint32_t l) { return l >= 64 && (l & 1) ? 1u : 0u; }, 128);
}

//  AG. Two predicated EXEC loops in a scope of lanes 0-39 whose results meet in masks (found by
//     review): loop 1 makes C1 (v_cmp_lt_u32 s[30:31], v7, 1) and VCC; after it s[26:27] = exec &
//     vcc and s[36:37] = vcc; loop 2 makes s[32:33] = s[36:37] & s[30:31] (L). After loop 2,
//     v10 = v_cndmask(0, 1, s[32:33]) and a waterfall over s[26:27] as in MaskWaterfall; every
//     lane stores s16 + v10 = 1. Whether a loop result is a mask register depends on the other
//     results: KeepLoopResults decided it result by result on the program it was changing, so a
//     mask write read a result's plain register and the shader stopped translating
//     (OutsideExecBit: an unhandled source). The marked set is now decided as a fixpoint before
//     Unsupported().
void TestTwoLoopMaskResults(id<MTLDevice> dev) {
    const std::vector<uint32_t> b = {
        0xBE900380, 0xBE94047E, // s16 = 0; s_mov_b64 s[20:21], exec
        0x7DA80002, 0xBF880027, // v_cmpx_gt_u32 exec, s2, v0; s_cbranch_execz -> 45
        0x36100081, 0x4A101081, // v8 = (v0 & 1) + 1
        0x7E0E0280, 0xBE96047E, // v7 = 0; s_mov_b64 s[22:23], exec
        0xD182001E, 0x00010307, // 8: loop 1: v_cmp_lt_u32 s[30:31], v7, 1 (C1)
        0x7D821107, 0x87FE6A7E, // v_cmp_lt_u32 vcc, v7, v8; s_and_b64 exec, exec, vcc
        0xBF880002,             // s_cbranch_execz -> 15
        0x4A0E0E81, 0xBF82FFF9, // v7 += 1; s_branch -> 8
        0xBEFE0416, 0x879A6A7E, // 15: s_mov_b64 exec, s[22:23]; s_and_b64 s[26:27], exec, vcc
        0xBEA4046A, 0x7E0E0280, // s_mov_b64 s[36:37], vcc; v7 = 0
        0xBE98047E,             // s_mov_b64 s[24:25], exec
        0x87A01E24,             // 20: loop 2: s_and_b64 s[32:33], s[36:37], s[30:31] (L)
        0xD1820022, 0x00021107, // v_cmp_lt_u32 s[34:35], v7, v8
        0x87FE227E, 0xBF880002, // s_and_b64 exec, exec, s[34:35]; s_cbranch_execz -> 27
        0x4A0E0E81, 0xBF82FFF9, // v7 += 1; s_branch -> 20
        0xBEFE0418,             // 27: s_mov_b64 exec, s[24:25]
        0xD200000A, 0x00810280, // v_cndmask_b32 v10, 0, 1, s[32:33]
        0x7E1E0500, 0x7E12020F, // v_readfirstlane_b32 s15, v0; v9 = s15
        0x80108110,             // 32: waterfall: s_add_u32 s16, s16, 1
        0xBF09C010, 0x859A1A80, // s_cmp_ge_u32 s16, 64; s_cselect_b64 s[26:27], 0, s[26:27] (bail out)
        0x7E1C0509,             // v_readfirstlane_b32 s14, v9
        0xD1A4001C, 0x0002120E, // v_cmpx_eq_u32 s[28:29], s14, v9
        0x7E280300, 0x8A9A1C1A, // v_mov_b32 v20, v0; s_andn2_b64 s[26:27], s[26:27], s[28:29]
        0x7E2A0300, 0xBEFE041A, // v_mov_b32 v21, v0; s_mov_b64 exec, s[26:27]
        0xBF85FFF5,             // s_cbranch_scc1 -> 32
        0xBEFE0414,             // 45: s_mov_b64 exec, s[20:21]
        0x7E060210, 0x4A06070A, // v3 = s16; v3 += v10
        kStoreV3, kStoreV3b,    // out[l] = v3
    };
    gcn_shader_info info{};
    const auto out = RunWave64(dev, "two loops' mask results", 0x5CA1AB1E00000074ULL, b, 64, {{2, 40}}, 64, nullptr,
                               &info);
    CHECK(info.unpredicated_wave_regions == 0, "two loops' mask results: %u region(s) not predicated",
          info.unpredicated_wave_regions);
    ExpectLanes("two loops' mask results", out, [](uint32_t) { return 1u; });
}

void TestAddTid(id<MTLDevice> dev) {
    uint32_t v[4];
    VSharp(v, kGuestBase + 0x1000, 64, 4);
    v[3] |= 1u << 23;
    // buffer_store_dword v1, off, s[8:11]
    auto out = RunWave64(dev, "add_tid", 0x5CA1AB1E0000000DULL, {0xE0700000, 0x80020100}, 64,
                         {{8, v[0]}, {9, v[1]}, {10, v[2]}, {11, v[3]}});
    ExpectLanes("add_tid", out, [](uint32_t l) { return 100u + l; });
}

// The hang guard on guest programs, checked without a GPU. The program that hung the GPU on
// 2026-10-22: a loop whose EXEC exit (s_cbranch_execz at 4) lands on the loop's back branch (12),
// so a wave whose lanes all left loops 3 -> 4 -> 12 -> 3 forever. With the exit on the
// instruction after the back branch (13) the program can end, and the guard must accept it.
void TestHangGuard() {
    std::vector<uint32_t> b = {
        0xBE8E0387, 0xBE94047E, 0x7E0E0280,             // s14 = 7; s[20:21] = exec; v7 = 0
        0x7DA21082, 0xBF880007,                         // 3: v_cmpx_lt_u32 2, v8; 4: execz -> 12
        0xBEFE0414, 0x7DA80002, 0xBF880003,             // exec = s[20:21]; v_cmpx_gt_u32 s2, v0; execz -> 11
        0xBE8E0385, 0xBEFE0414, 0xBF820002,             // s14 = 5; exec = s[20:21]; s_branch -> 13
        0x4A0E0E81, 0xBF82FFF6,                         // 11: v7 += 1; 12: s_branch -> 3
        0xBEFE0414, kEnd};                              // 13: exec = s[20:21]
    const auto hung = WithFooter(b, 0);
    CHECK(ZeroExecCycle(hung) == 2 + 3, "hang guard: the 2026-10-22 loop is not found (got %ld)", ZeroExecCycle(hung) - 2);
    b[4] = 0xBF880008; // execz -> 13
    CHECK(ZeroExecCycle(WithFooter(b, 0)) < 0, "hang guard: a loop with a reachable exit is rejected");
    // A waterfall loop (s_and_saveexec ... s_xor_b64 exec ... s_cbranch_execnz) is accepted.
    const std::vector<uint32_t> waterfall = {0xBE94047E, 0x7E140501, 0x7D84020A, 0xBE96246A,
                                             0x89FE167E, 0xBF89FFFB, 0xBEFE0414, kEnd};
    CHECK(ZeroExecCycle(WithFooter(waterfall, 0)) < 0, "hang guard: a waterfall loop is rejected");

    // The MSL barrier check: a vote branch and a vote-controlled loop around barriers pass; a
    // barrier under a per-invocation branch, a loop with a barrier left per invocation, a vote of
    // a slot read at a per-invocation index, and an early return per invocation are caught.
    const std::string head = "kernel void main0(uint gl_LocalInvocationIndex [[thread_index_in_threadgroup]])\n{\n"
                             "    threadgroup_barrier(mem_flags::mem_threadgroup);\n"
                             "    uint _10 = shared_mem_u32[64u >> 2u];\n    uint _11 = shared_mem_u32[68u >> 2u];\n"
                             "    uint _12 = shared_mem_u32[gl_LocalInvocationIndex];\n";
    const std::string bar = "threadgroup_barrier(mem_flags::mem_threadgroup);\n";
    auto errors = [&](const std::string& body) { return msl_check::BarrierErrors(head + body + "}\n").size(); };
    CHECK(errors("    if ((_10 | _11) != 0u)\n    {\n        " + bar + "    }\n    else\n    {\n        " + bar + "    }\n") == 0,
          "barrier check: a barrier in a vote branch and its else is rejected");
    CHECK(errors("    for (;;)\n    {\n        " + bar + "        if (!((_10 | _11) != 0u))\n        {\n            break;\n"
                 "        }\n        if (gl_LocalInvocationIndex < 3u)\n        {\n            _12 = 1u;\n        }\n    }\n") == 0,
          "barrier check: a vote-controlled loop with a barrier is rejected");
    CHECK(errors("    if (gl_LocalInvocationIndex < 32u)\n    {\n        " + bar + "    }\n") == 1,
          "barrier check: a barrier under a per-invocation branch is not found");
    CHECK(errors("    if (gl_LocalInvocationIndex < 32u)\n    {\n    }\n    else\n    {\n        " + bar + "    }\n") == 1,
          "barrier check: a barrier in the else of a per-invocation branch is not found");
    CHECK(errors("    for (;;)\n    {\n        " + bar + "        if (gl_LocalInvocationIndex < 3u)\n        {\n"
                 "            break;\n        }\n    }\n") == 1,
          "barrier check: a loop with a barrier left per invocation is not found");
    CHECK(errors("    if ((_10 | _12) != 0u)\n    {\n        " + bar + "    }\n") == 1,
          "barrier check: a vote of a per-invocation slot read counts as uniform");
    CHECK(errors("    if (gl_LocalInvocationIndex < 3u)\n    {\n        return;\n    }\n    " + bar) == 1,
          "barrier check: an early return per invocation is not found");
    // Uniform values other than votes: a constant-buffer read, a loop counter updated the same
    // way by every invocation. Divergent: a read of a buffer the kernel writes, a counter updated
    // under a per-invocation branch.
    CHECK(errors("    uint _20 = srt_flatbuf.data[3u];\n    if (_20 != 0u)\n    {\n        " + bar + "    }\n") == 0,
          "barrier check: a branch on a constant-buffer value is rejected");
    CHECK(errors("    uint _23 = 4u >> 2u;\n    if (shared_mem_u32[_23] != 0u)\n    {\n        " + bar + "    }\n") == 0,
          "barrier check: a branch on workgroup memory at a uniform index is rejected");
    CHECK(errors("    ssbo_1.data[gl_LocalInvocationIndex] = 1u;\n    if (ssbo_1.data[0u] != 0u)\n    {\n        " + bar +
                 "    }\n") == 1,
          "barrier check: a branch on a buffer the kernel writes counts as uniform");
    // Another binding may be the same memory: in a kernel that writes a buffer, a branch on any
    // other buffer is divergent; on the flattened user data (filled by the CPU) it is not, and
    // in a kernel that writes no buffer a read-only buffer is constant.
    CHECK(errors("    ssbo_2.data[gl_LocalInvocationIndex] = 1u;\n    if (ssbo_1.data[0u] != 0u)\n    {\n        " + bar +
                 "    }\n") == 1,
          "barrier check: a branch on a read-only buffer in a kernel that writes another counts as uniform");
    CHECK(errors("    ssbo_2.data[gl_LocalInvocationIndex] = 1u;\n    if (srt_flatbuf.data[0u] != 0u)\n    {\n        " + bar +
                 "    }\n") == 0,
          "barrier check: a branch on the flattened user data in a kernel that writes a buffer is rejected");
    CHECK(errors("    if (ssbo_1.data[0u] != 0u)\n    {\n        " + bar + "    }\n") == 0,
          "barrier check: a branch on a read-only buffer in a kernel that writes no buffer is rejected");
    const std::string loop = "    uint _21 = 0u;\n    for (;;)\n    {\n        " + bar + "        if (_21 > 4u)\n        {\n"
                             "            break;\n        }\n";
    CHECK(errors(loop + "        _21 = _21 + 1u;\n    }\n") == 0, "barrier check: a uniform loop counter is rejected");
    CHECK(errors(loop + "        if (gl_LocalInvocationIndex < 3u)\n        {\n            _21 = _21 + 1u;\n        }\n    }\n") == 1,
          "barrier check: a loop counter updated per invocation counts as uniform");
}

} // namespace

int main() {
    @autoreleasepool {
        id<MTLDevice> dev = MTLCreateSystemDefaultDevice();
        if (!dev) {
            std::fprintf(stderr, "gcn_wave_exec_test: no Metal device\n");
            return 1;
        }
        std::string why;
        g_be = MakeTestBackend(dev, &why);
        if (!g_be) {
            std::fprintf(stderr, "gcn_wave_exec_test: FAIL: no backend: %s\n", why.c_str());
            return 1;
        }
        std::printf("gcn_wave_exec_test: backend %s\n", ps4gnm::BackendName(g_be->Kind()));
        TestHangGuard();
        TestExecHalf(dev);
        TestSpilledSharp(dev);
        TestWave64Compare(dev);
        TestReadFirstLane(dev);
        TestReadLaneAndWriteLaneGap(dev);
        TestWave64Masks(dev);
        TestAddTid(dev);
        TestPartialGroups(dev);
        TestDivergentBody(dev);
        TestReadLaneOutsideExec(dev);
        TestLanesOutsideExec(dev);
        TestScalarizationLoop(dev);
        TestNestedScope(dev);
        TestPredicatedLoops(dev);
        TestPredicatedLds(dev);
        TestEndThenLaneRead(dev);
        TestNoBarrierInBranches(dev);
        TestAliasedReadOnlyLoad(dev);
        TestScopeScalarCodePerWave(dev);
        TestHoistedLaneReads(dev);
        TestReadLaneSourceWrittenInScope(dev);
        TestBreakInScope(dev);
        TestBreakOfOuterLoop(dev);
        TestEndInScope(dev);
        TestEndWithoutWaveNeeds(dev);
        TestWriteLaneInPredicatedScope(dev);
        TestFallbackRefusesBarriers(dev);
        TestVectorRegisterInPredicatedScope(dev);
        TestExecCopyInPredicatedLoop(dev);
        TestMaskLoopResult(dev);
        TestMaskOfLoopCompare(dev);
        TestMaskLoopResultWithEnds(dev);
        TestTwoLoopMaskResults(dev);
        if (g_fail) {
            std::fprintf(stderr, "gcn_wave_exec_test: %d failure(s)\n", g_fail);
            return 1;
        }
        std::printf("gcn_wave_exec_test: PASS\n");
        return 0;
    }
}
