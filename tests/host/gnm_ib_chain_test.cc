// PM4 INDIRECT_BUFFER nesting (ps4_gnm_ib.h): a command buffer made of chained chunks runs to
// its end, however many chunks it has; called sub-buffers return to their caller; calls nested
// deeper than the limit are skipped. Uncharted 4 chains dozens of DCB chunks per frame; with
// chained IBs counted as nesting the walker dropped everything after the fourth chunk.
#include <stdint.h>
#include <stdio.h>
#include <vector>
#include "ps4_gnm_ib.h"

static int g_fail;

static void check(bool ok, const char *what) {
    printf("%s: %s\n", ok ? "ok" : "FAIL", what);
    if (!ok) g_fail = 1;
}

constexpr uint32_t kOpNop = 0x10;
constexpr uint32_t kOpIb = 0x3F;

static uint32_t Type3(uint32_t op, uint32_t payload_dw) { return (3u << 30) | ((payload_dw - 1) << 16) | (op << 8); }

static void Marker(std::vector<uint32_t> &b, uint32_t id) {
    b.push_back(Type3(kOpNop, 1));
    b.push_back(id);
}

// The buffers live in one arena; IB packets carry arena indices instead of guest addresses.
static void Ib(std::vector<uint32_t> &b, uint32_t target, uint32_t size_dw, bool chain) {
    b.push_back(Type3(kOpIb, 3));
    b.push_back(target);
    b.push_back(0);
    b.push_back(size_dw | (chain ? 1u << 20 : 0u));
}

// Walks the buffers like ProcessGfxPackets: returns the markers in execution order.
static std::vector<uint32_t> Walk(const std::vector<uint32_t> &arena, uint32_t start, uint32_t size_dw) {
    std::vector<uint32_t> seen;
    std::vector<ps4gnm_ib::Frame> frames{{arena.data() + start, size_dw, 0}};
    while (!frames.empty() && seen.size() < 1000) {
        ps4gnm_ib::Frame &f = frames.back();
        if (f.pc >= f.dw) {
            frames.pop_back();
            continue;
        }
        const uint32_t h = f.words[f.pc];
        const uint32_t op = (h >> 8) & 0xFF, n = ((h >> 16) & 0x3FFF) + 1;
        const uint32_t *p = f.words + f.pc + 1;
        f.pc += 1 + n;
        if (op == kOpNop) seen.push_back(p[0]);
        if (op == kOpIb) ps4gnm_ib::Enter(frames, arena.data() + p[0], p[2] & 0xFFFFF, ps4gnm_ib::IsChained(p, n));
    }
    return seen;
}

int main() {
    // 12 chunks, each: marker, then a chained IB to the next chunk (6 dwords per chunk).
    {
        std::vector<uint32_t> a;
        const uint32_t chunk_dw = 6, chunks = 12;
        for (uint32_t i = 0; i < chunks; ++i) {
            Marker(a, 100 + i);
            if (i + 1 < chunks)
                Ib(a, (i + 1) * chunk_dw, i + 2 < chunks ? chunk_dw : 4, true); // the last chunk has 4 dwords
            else
                Marker(a, 999);
        }
        const std::vector<uint32_t> seen = Walk(a, 0, chunk_dw);
        bool order = seen.size() == chunks + 1;
        for (uint32_t i = 0; order && i < chunks; ++i) order = seen[i] == 100 + i;
        check(order && seen.back() == 999, "12 chained chunks all run, in order, to the end");
    }
    // A call returns: main = M1, IB call -> sub (M2), M3.
    {
        std::vector<uint32_t> a;
        Marker(a, 1);
        Ib(a, 0, 0, false); // patched below
        Marker(a, 3);
        const uint32_t main_dw = (uint32_t)a.size(), sub = main_dw;
        Marker(a, 2);
        a[3] = sub;
        a[5] = 2;
        const std::vector<uint32_t> seen = Walk(a, 0, main_dw);
        check(seen == std::vector<uint32_t>({1, 2, 3}), "a called IB returns to the packet after the call");
    }
    // A chained IB inside a called IB returns to the caller of the chain, not into the chunk.
    {
        std::vector<uint32_t> a;
        Marker(a, 1);
        Ib(a, 0, 0, false); // -> s1, patched below
        Marker(a, 4);
        const uint32_t main_dw = (uint32_t)a.size();
        const uint32_t s1 = (uint32_t)a.size();
        Marker(a, 2);
        Ib(a, 0, 0, true); // -> s2, patched below
        Marker(a, 77); // after a chain: never runs
        const uint32_t s2 = (uint32_t)a.size();
        Marker(a, 3);
        a[3] = s1;
        a[5] = s2 - s1;
        a[s1 + 3] = s2;
        a[s1 + 5] = 2 | 1u << 20; // size 2, chained
        const std::vector<uint32_t> seen = Walk(a, 0, main_dw);
        check(seen == std::vector<uint32_t>({1, 2, 3, 4}), "chain inside a call: no return into the chunk, back to the caller");
    }
    // Calls nested deeper than the limit are skipped (cycle guard): a buffer that calls itself.
    {
        std::vector<uint32_t> a;
        Marker(a, 5);
        Ib(a, 0, 6, false);
        const std::vector<uint32_t> seen = Walk(a, 0, 6);
        check(seen.size() == (size_t)ps4gnm_ib::kMaxDepth + 1, "self-calling buffer stops at the nesting limit");
    }
    printf("gnm_ib_chain_test: %s\n", g_fail ? "FAIL" : "PASS");
    return g_fail;
}
