// Resumable compute queue walk (ps4gnm_ib::Walk in ps4_gnm_ib.h, used by ProcessComputePackets
// in ps4_gnm_metal.mm). A compute queue whose WAIT_REG_MEM is not satisfied yet must stop at
// that packet and later continue exactly there, inside whatever IBs it had entered, instead of
// running on. Uncharted 4's async compute waits for the graphics depth prepass and then copies
// the depth buffer; the walker ran through the wait, copied stale depth, and later passes drew
// the water over Drake. The read pointer must not pass the waiting packet.
// The queue (ps4gnm_wq::WaitQueue): submissions run in order, a later one waits behind a
// suspended one, a timed-out wait is skipped, and every wait gets its own time limit (a
// submission's second wait inherited the first one's start time and was skipped ~1 ms later).
#include <stdint.h>
#include <stdio.h>
#include <vector>
#include "ps4_gnm_ib.h"
#include "ps4_gnm_wait_queue.h"

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

// A submission: a list of waits (flag index, value); progress = waits passed.
struct Sub {
    std::vector<std::pair<int, uint32_t>> waits;
    size_t at = 0;
    int id;
};

static void TestWaitQueue() {
    uint32_t flags[3] = {0, 0, 0};
    std::vector<int> done;
    auto process = [&](Sub &s, bool skip) {
        for (; s.at < s.waits.size(); ++s.at) {
            const auto [f, v] = s.waits[s.at];
            if (flags[f] == v) continue;
            if (skip) {
                skip = false;
                continue;
            }
            return false;
        }
        done.push_back(s.id);
        return true;
    };
    ps4gnm_wq::WaitQueue<Sub> q;
    q.pending.push_back({{{0, 1}, {1, 1}}, 0, 1});
    q.pending.push_back({{}, 0, 2});
    const uint64_t ms = 1000000;
    check(q.Run(false, 100 * ms, process) && q.Suspended(), "the queue stops at the first wait");
    check(done.empty(), "the submission behind it does not run");
    check(!q.TimedOut(120 * ms, 50 * ms) && q.TimedOut(151 * ms, 50 * ms), "the wait times out after its limit");
    check(q.Run(true, 151 * ms, process), "after the timeout it stops again at the second wait");
    check(q.timeouts == 1 && q.suspends == 2, "one timeout, two suspensions counted");
    check(!q.TimedOut(152 * ms, 50 * ms), "the second wait gets its own time limit");
    check(q.TimedOut(202 * ms, 50 * ms), "and times out 50 ms after it started");
    flags[1] = 1;
    q.suspended_at = 0; // the value arrived (ResumeComputeQueues)
    check(!q.Run(false, 160 * ms, process) && !q.Suspended(), "the value arrives: both submissions finish");
    check(done == std::vector<int>({1, 2}), "in order");
    q.pending.push_back({{{2, 5}}, 0, 3});
    check(q.Run(false, 170 * ms, process), "a new submission waits");
    q.Reset();
    check(q.pending.empty() && !q.Suspended(), "a remapped queue drops its waiting submissions");
}

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

    TestWaitQueue();
    return g_fail;
}
