// Resumable compute queue walk (ps4gnm_ib::Walk in ps4_gnm_ib.h, used by ProcessComputePackets
// in ps4_gnm_metal.mm). A compute queue whose WAIT_REG_MEM is not satisfied yet must stop at
// that packet and later continue exactly there, inside whatever IBs it had entered, instead of
// running on. Uncharted 4's async compute waits for the graphics depth prepass and then copies
// the depth buffer; the walker ran through the wait, copied stale depth, and later passes drew
// the water over Drake. The read pointer must not pass the waiting packet.
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
constexpr uint32_t kOpWait = 0x3C;
constexpr uint32_t kOpIb = 0x3F;

static uint32_t Type3(uint32_t op, uint32_t payload_dw) { return (3u << 30) | ((payload_dw - 1) << 16) | (op << 8); }

// The buffers live in one arena; IB packets carry arena indices instead of guest addresses.
struct Arena {
    std::vector<uint32_t> w;
    uint32_t Mark(uint32_t id) {
        w.push_back(Type3(kOpNop, 1));
        w.push_back(id);
        return id;
    }
    // waits until flags[flag] == value
    void Wait(uint32_t flag, uint32_t value) {
        w.push_back(Type3(kOpWait, 2));
        w.push_back(flag);
        w.push_back(value);
    }
    void Ib(uint32_t target, uint32_t size_dw, bool chain) {
        w.push_back(Type3(kOpIb, 3));
        w.push_back(target);
        w.push_back(0);
        w.push_back(size_dw | (chain ? 1u << 20 : 0));
    }
};

struct Queue {
    const Arena *a;
    std::vector<ps4gnm_ib::Frame> frames;
    std::vector<uint32_t> log;
    uint32_t read_ptr = 0;
    const uint32_t *flags;
    bool Run() {
        auto exec = [&](const ps4gnm_ib::Frame &f, int, ps4gnm_ib::Packet &pk) {
            const uint32_t h = f.words[f.pc];
            const uint32_t op = (h >> 8) & 0xFF, n = ((h >> 16) & 0x3FFF) + 1;
            if (f.pc + 1 + n > f.dw) return;
            const uint32_t *p = &f.words[f.pc + 1];
            pk.step = 1 + n;
            if (op == kOpNop) log.push_back(p[0]);
            if (op == kOpWait && flags[p[0]] != p[1]) pk.suspend = true;
            if (op == kOpIb) {
                pk.ib = &a->w[p[0]];
                pk.ib_dw = p[2] & 0xFFFFF;
                pk.chain = ps4gnm_ib::IsChained(p, n);
            }
        };
        return ps4gnm_ib::Walk(frames, true, exec, [&](uint32_t pc) { read_ptr = pc; });
    }
};

int main() {
    // ring: 1, IB call -> [2, chain -> [3, WAIT f0==1, 4]], 5, WAIT f1==7, 6
    Arena a; // the IBs first, so their indices are known
    const uint32_t ib_b = 0;
    a.Mark(3);
    a.Wait(0, 1);
    a.Mark(4);
    const uint32_t ib_b_dw = (uint32_t)a.w.size() - ib_b;
    const uint32_t ib_a = (uint32_t)a.w.size();
    a.Mark(2);
    a.Ib(ib_b, ib_b_dw, true);
    a.Mark(99); // after a chain: never runs
    const uint32_t ib_a_dw = (uint32_t)a.w.size() - ib_a;
    const uint32_t ring = (uint32_t)a.w.size();
    a.Mark(1);
    a.Ib(ib_a, ib_a_dw, false);
    const uint32_t after_ib = (uint32_t)a.w.size() - ring;
    a.Mark(5);
    const uint32_t wait2 = (uint32_t)a.w.size() - ring;
    a.Wait(1, 7);
    a.Mark(6);
    const uint32_t ring_dw = (uint32_t)a.w.size() - ring;

    uint32_t flags[2] = {0, 0};
    Queue q{&a, {{&a.w[ring], ring_dw, 0}}, {}, 0, flags};

    check(!q.Run(), "the queue stops at an unsatisfied wait inside a chained IB");
    check(q.log == std::vector<uint32_t>({1, 2, 3}), "packets before the wait ran, none after it");
    check(q.read_ptr == after_ib, "the read pointer stops after the ring's IB packet");
    check(q.frames.size() == 2 && q.frames.back().words == &a.w[ib_b], "the suspended walk is inside the chained IB");

    check(!q.Run(), "a second walk with the wait still unsatisfied stops again");
    check(q.log.size() == 3, "and runs nothing");

    flags[0] = 1;
    check(!q.Run(), "after the value arrives the walk continues to the next wait");
    check(q.log == std::vector<uint32_t>({1, 2, 3, 4, 5}), "continues at the wait, returns to the ring, skips the chained-from tail");
    check(q.read_ptr == wait2, "the read pointer stops at the ring-level wait");

    flags[1] = 7;
    check(q.Run(), "the walk finishes once the second value arrives");
    check(q.log == std::vector<uint32_t>({1, 2, 3, 4, 5, 6}), "every packet ran once, in order");
    check(q.read_ptr == ring_dw && q.frames.empty(), "the ring is consumed");

    // a truncated packet drops the rest of its buffer
    Arena t;
    t.Mark(1);
    t.w.push_back(Type3(kOpNop, 8)); // claims 8 payload dwords, only 1 follows
    t.w.push_back(0);
    Queue tq{&t, {{t.w.data(), (uint32_t)t.w.size(), 0}}, {}, 0, flags};
    check(tq.Run() && tq.log == std::vector<uint32_t>({1}), "a truncated packet ends the buffer");

    return g_fail;
}
