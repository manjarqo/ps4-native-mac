// Structural check of a translated compute kernel's barriers, done on its MSL text without running
// it. A threadgroup_barrier that some invocations of the workgroup do not reach hangs the GPU (the
// simdgroups that reach it wait forever), so every barrier must be reached by all of them or by
// none:
//  - every `if` / `else` / `else if` / `switch` around a barrier branches on a workgroup-uniform
//    condition;
//  - every loop that holds a barrier is left (break, continue, its loop condition) only on
//    workgroup-uniform conditions;
//  - a kernel with barriers returns early only on workgroup-uniform conditions.
//
// Workgroup-uniform values are found by a forward analysis of the MSL, optimistic over loops (all
// variables start uniform and are marked divergent until nothing changes, so a loop-carried value
// is uniform only if every assignment of it is). A value is divergent if it depends on:
//  - an invocation id (gl_LocalInvocationID / Index, gl_GlobalInvocationID, gl_Subgroup*, any
//    gl_* but gl_WorkGroupID / gl_NumWorkGroups / gl_WorkGroupSize), a simdgroup or quad function
//    (simd_*, quad_*, spvSubgroup*, spvQuad*), an atomic;
//  - a read of workgroup memory at a divergent index (at a uniform index, e.g. a vote or exchange
//    slot, every invocation reads the same dword between the same two barriers; a write to it in
//    between by another invocation would be a race in the guest program itself);
//  - a read of a device buffer or texture that the kernel writes (another invocation may write it
//    in between), and, in a kernel that writes any device buffer, a read of every device buffer
//    but the flattened user data (srt_flatbuf, filled by the CPU): the written one may be the same
//    memory under another binding. Textures it only reads, and the buffers of a kernel that writes
//    none, are taken as constant during the dispatch;
//  - a divergent variable, or an assignment under a divergent branch or in a loop that is left on
//    a divergent condition.
// Anything the check does not recognize counts as divergent or is reported: a false alarm shows up
// as a test failure, a missed hazard as a GPU hang.
#pragma once

#include <map>
#include <regex>
#include <set>
#include <string>
#include <vector>

namespace msl_check {

inline std::string Trim(const std::string& s) {
    const size_t a = s.find_first_not_of(" \t");
    if (a == std::string::npos) return "";
    const size_t b = s.find_last_not_of(" \t\r");
    return s.substr(a, b - a + 1);
}

// Index just past the bracket that closes the one at `s[open]` ('(' or '['), or npos.
inline size_t Close(const std::string& s, size_t open) {
    const char o = s[open], c = o == '(' ? ')' : ']';
    int depth = 0;
    for (size_t i = open; i < s.size(); i++) {
        if (s[i] == o) depth++;
        if (s[i] == c && --depth == 0) return i + 1;
    }
    return std::string::npos;
}

// The text inside the parentheses that open at `s[open]`, or "" when they do not close.
inline std::string Parenthesized(const std::string& s, size_t open) {
    const size_t end = Close(s, open);
    return end == std::string::npos ? "" : s.substr(open + 1, end - open - 2);
}

inline bool IsIdChar(char c) { return std::isalnum(static_cast<unsigned char>(c)) || c == '_'; }

struct Kernel {
    std::vector<std::string> lines;     // main0, trimmed
    std::set<std::string> written;      // device buffers and textures the kernel writes
    bool writes_buffer = false;         // it writes a device buffer
    std::map<std::string, bool> divergent; // assigned variables
};

// Whether expression `e` is workgroup-uniform under the variable states of `k`.
inline bool Uniform(const Kernel& k, std::string e) {
    // workgroup memory reads: uniform at a literal index only
    for (size_t p = e.find("shared_mem_"); p != std::string::npos; p = e.find("shared_mem_", p + 1)) {
        size_t b = p;
        while (b < e.size() && IsIdChar(e[b])) b++;
        if (b >= e.size() || e[b] != '[') return false; // the array passed whole, e.g. to a function
        const size_t end = Close(e, b);
        if (end == std::string::npos) return false;
        if (!Uniform(k, e.substr(b + 1, end - b - 2))) return false;
        e.replace(p, end - p, std::string(end - p, ' '));
    }
    // reads of written buffers and textures
    static const std::regex access(R"((\w+)\)?\.(data\[|read\(|sample\(|gather\())");
    for (auto it = std::sregex_iterator(e.begin(), e.end(), access); it != std::sregex_iterator(); ++it) {
        const std::string name = (*it)[1].str();
        if (k.written.count(name)) return false;
        if (k.writes_buffer && (*it)[2].str() == "data[" && name != "srt_flatbuf") return false;
    }
    for (size_t i = 0; i < e.size();) {
        if (!(std::isalpha(static_cast<unsigned char>(e[i])) || e[i] == '_') || (i > 0 && IsIdChar(e[i - 1]))) {
            i++;
            continue;
        }
        size_t j = i;
        while (j < e.size() && IsIdChar(e[j])) j++;
        const std::string id = e.substr(i, j - i);
        const bool member = i > 0 && (e[i - 1] == '.' || (i > 1 && e[i - 1] == '>' && e[i - 2] == '-'));
        i = j;
        if (member) continue;
        if (id.rfind("gl_", 0) == 0) {
            if (id != "gl_WorkGroupID" && id != "gl_NumWorkGroups" && id != "gl_WorkGroupSize") return false;
            continue;
        }
        if (id.rfind("simd_", 0) == 0 || id.rfind("quad_", 0) == 0 || id.rfind("spvSubgroup", 0) == 0 ||
            id.rfind("spvQuad", 0) == 0 || id.rfind("atomic_", 0) == 0)
            return false;
        const auto v = k.divergent.find(id);
        if (v != k.divergent.end() && v->second) return false;
    }
    return true;
}

// An assignment statement: its variable and the expressions it depends on (the right-hand side,
// lvalue indices, and the old value for a compound or partial assignment). False for other
// statements and for stores to device memory, textures and workgroup memory.
inline bool ParseAssignment(const std::string& l, std::string* var, std::string* deps) {
    if (l.empty() || l.back() != ';') return false;
    size_t eq = std::string::npos;
    int depth = 0;
    for (size_t i = 0; i < l.size(); i++) {
        const char c = l[i];
        if (c == '(' || c == '[') depth++;
        if (c == ')' || c == ']') depth--;
        if (c != '=' || depth != 0) continue;
        const char prev = i ? l[i - 1] : ' ', next = i + 1 < l.size() ? l[i + 1] : ' ';
        if (next == '=' || ((prev == '!' || prev == '<' || prev == '>' || prev == '=') &&
                            !(i >= 2 && (l[i - 2] == '<' || l[i - 2] == '>') && l[i - 2] == prev)))
            return false; // a comparison before any assignment: not an assignment statement
        eq = i;
        break;
    }
    if (eq == std::string::npos) return false;
    std::string lhs = Trim(l.substr(0, eq));
    const std::string rhs = l.substr(eq + 1, l.size() - eq - 2);
    bool compound = false;
    while (!lhs.empty() && std::string("+-*/%&|^<>").find(lhs.back()) != std::string::npos) {
        lhs.pop_back();
        compound = true;
    }
    lhs = Trim(lhs);
    if (lhs.find(".data[") != std::string::npos || lhs.rfind("shared_mem_", 0) == 0) return false;
    // the lvalue: an identifier with .field / [index] suffixes, at the end of lhs
    size_t i = lhs.size();
    std::string indices;
    bool partial = false;
    for (;;) {
        if (i > 0 && lhs[i - 1] == ']') {
            int d = 0;
            size_t j = i;
            while (j > 0) {
                j--;
                if (lhs[j] == ']') d++;
                if (lhs[j] == '[' && --d == 0) break;
            }
            indices += " " + lhs.substr(j, i - j);
            i = j;
            partial = true;
            continue;
        }
        size_t j = i;
        while (j > 0 && IsIdChar(lhs[j - 1])) j--;
        if (j == i) return false;
        if (j > 0 && lhs[j - 1] == '.') {
            i = j - 1;
            partial = true;
            continue;
        }
        *var = lhs.substr(j, i - j);
        break;
    }
    if (var->rfind("shared_mem_", 0) == 0) return false;
    *deps = rhs + indices + (compound || partial ? " " + *var : "");
    return true;
}

enum class Kind { kBlock, kBranch, kLoop, kSwitch };
struct Frame {
    Kind kind = Kind::kBlock;
    bool uniform = true;       // kBranch / kSwitch: taken by all invocations or by none
    bool has_barrier = false;  // kLoop: a barrier in the body (at any depth)
    bool divergent_exit = false; // kLoop: left on a divergent condition
    std::string exit_cond;     // kLoop: the loop condition ("" for for (;;))
    int line = 0;
};

// One walk over main0 under the current variable states. Marks variables divergent (returns
// whether any changed) and, when `errors` is set, reports the barrier hazards.
inline bool Walk(Kernel& k, std::map<int, bool>& loop_exit_divergent, std::vector<std::string>* errors) {
    bool changed = false;
    std::vector<Frame> open;
    bool pending = false;
    Frame next;
    bool last_if_uniform = true; // of the `if` (chain) that closed last, for its `else`
    bool barriers = false, divergent_return = false;
    auto error = [&](int n, const std::string& what) {
        if (errors) errors->push_back((n ? "line " + std::to_string(n) + ": " : std::string()) + what);
    };
    auto control_uniform = [&](size_t from) { // branches above open[from - 1] and all loops
        for (size_t i = open.size(); i-- > from;) {
            if ((open[i].kind == Kind::kBranch || open[i].kind == Kind::kSwitch) && !open[i].uniform) return false;
            if (open[i].kind == Kind::kLoop && open[i].divergent_exit) return false;
        }
        return true;
    };
    auto branches_uniform = [&](size_t from) {
        for (size_t i = open.size(); i-- > from;)
            if ((open[i].kind == Kind::kBranch || open[i].kind == Kind::kSwitch) && !open[i].uniform) return false;
        return true;
    };
    auto close = [&](Frame f, const std::string& l) {
        if (f.kind == Kind::kLoop) {
            if (l.rfind("} while (", 0) == 0) f.exit_cond = Parenthesized(l, 8);
            const bool cond_divergent = !f.exit_cond.empty() && !Uniform(k, f.exit_cond);
            if ((f.divergent_exit || cond_divergent) && !loop_exit_divergent[f.line]) {
                loop_exit_divergent[f.line] = true;
                changed = true;
            }
            if (f.has_barrier && (f.divergent_exit || cond_divergent))
                error(f.line, "a loop with a barrier is left on a divergent condition");
        }
        if (f.kind == Kind::kBranch) last_if_uniform = f.uniform;
    };
    auto statement = [&](const std::string& l, int n) {
        std::string var, deps;
        if (l.find("threadgroup_barrier(") != std::string::npos) {
            barriers = true;
            for (size_t i = open.size(); i-- > 0;)
                if ((open[i].kind == Kind::kBranch || open[i].kind == Kind::kSwitch) && !open[i].uniform) {
                    error(n, "a barrier under the divergent branch at line " + std::to_string(open[i].line) + ": " +
                                 k.lines[size_t(open[i].line) - 1]);
                    break;
                }
            for (auto& f : open)
                if (f.kind == Kind::kLoop) f.has_barrier = true;
        } else if (l == "break;" || l == "continue;") {
            size_t i = open.size();
            while (i > 0 && open[i - 1].kind != Kind::kLoop && !(l == "break;" && open[i - 1].kind == Kind::kSwitch)) i--;
            if (i == 0) error(n, l + " outside a loop");
            else if (open[i - 1].kind == Kind::kLoop && !branches_uniform(i)) open[i - 1].divergent_exit = true;
        } else if (l.rfind("return", 0) == 0) {
            if (!branches_uniform(0)) divergent_return = true;
        } else if (l.rfind("goto ", 0) == 0) {
            error(n, "goto");
        } else if (ParseAssignment(l, &var, &deps)) {
            if (!k.divergent[var] && (!control_uniform(0) || !Uniform(k, deps))) {
                k.divergent[var] = true;
                changed = true;
            }
        }
    };
    for (size_t idx = 0; idx < k.lines.size(); idx++) {
        const std::string& l = k.lines[idx];
        const int n = int(idx) + 1;
        if (l.empty()) continue;
        if (pending && l != "{") { // a construct with a single unbraced statement
            open.push_back(next);
            pending = false;
            if (l.rfind("if (", 0) == 0 || l.rfind("for (", 0) == 0 || l.rfind("while (", 0) == 0 || l == "else" ||
                l == "do" || l.rfind("switch (", 0) == 0 || l.rfind("else if (", 0) == 0)
                error(n, "a nested construct without braces");
            else
                statement(l, n);
            const Frame f = open.back();
            open.pop_back();
            close(f, "");
            continue;
        }
        auto loop_frame = [&](const std::string& cond) {
            Frame f{Kind::kLoop, true, false, loop_exit_divergent[n], cond, n};
            return f;
        };
        if (l.rfind("if (", 0) == 0) {
            next = Frame{Kind::kBranch, Uniform(k, Parenthesized(l, 3)), false, false, "", n};
            pending = true;
        } else if (l.rfind("else if (", 0) == 0) {
            next = Frame{Kind::kBranch, last_if_uniform && Uniform(k, Parenthesized(l, 8)), false, false, "", n};
            pending = true;
        } else if (l == "else") {
            next = Frame{Kind::kBranch, last_if_uniform, false, false, "", n};
            pending = true;
        } else if (l.rfind("switch (", 0) == 0) {
            next = Frame{Kind::kSwitch, Uniform(k, Parenthesized(l, 7)), false, false, "", n};
            pending = true;
        } else if (l.rfind("for (", 0) == 0) {
            const std::string h = Parenthesized(l, 4);
            const size_t a = h.find(';'), b = a == std::string::npos ? a : h.find(';', a + 1);
            if (b == std::string::npos || !Trim(h.substr(0, a)).empty() || !Trim(h.substr(b + 1)).empty())
                error(n, "a for loop with an initializer or increment");
            next = loop_frame(b == std::string::npos ? "?" : Trim(h.substr(a + 1, b - a - 1)));
            pending = true;
        } else if (l.rfind("while (", 0) == 0) {
            next = loop_frame(Parenthesized(l, 6));
            pending = true;
        } else if (l == "do") {
            next = loop_frame("");
            pending = true;
        } else if (l == "{") {
            open.push_back(pending ? next : Frame{Kind::kBlock, true, false, false, "", n});
            pending = false;
        } else if (l[0] == '}') {
            if (open.empty()) break;
            const Frame f = open.back();
            open.pop_back();
            close(f, l);
            if (open.empty()) break; // the end of main0
        } else if (l.rfind("case ", 0) == 0 || l.rfind("default:", 0) == 0) {
            // labels of the enclosing switch
        } else {
            statement(l, n);
        }
    }
    if (barriers && divergent_return) error(0, "a kernel with barriers returns on a divergent condition");
    return changed;
}

// The barrier hazards in `msl` (empty when every barrier is reached by the whole workgroup or by
// none of it). The text must be in SPIRV-Cross's layout: one statement or brace per line.
inline std::vector<std::string> BarrierErrors(const std::string& msl) {
    const size_t start = msl.find("kernel void main0");
    if (start == std::string::npos) return {"no kernel main0"};
    if (msl.substr(0, start).find("threadgroup_barrier(") != std::string::npos)
        return {"a barrier in a function other than main0"};
    Kernel k;
    for (size_t pos = start; pos < msl.size();) {
        size_t eol = msl.find('\n', pos);
        if (eol == std::string::npos) eol = msl.size();
        k.lines.push_back(Trim(msl.substr(pos, eol - pos)));
        pos = eol + 1;
    }
    static const std::regex store(R"((\w+)\)?\.(data\[[^=]*\]\s*[+\-*/%&|^]?=[^=]|write\())");
    static const std::regex buffer(R"((\w+)\)?\.data\[)");
    for (const auto& l : k.lines) {
        const bool atomic = l.find("atomic_") != std::string::npos;
        for (auto it = std::sregex_iterator(l.begin(), l.end(), atomic ? buffer : store); it != std::sregex_iterator(); ++it) {
            k.written.insert((*it)[1].str());
            if (atomic || (*it)[2].str().rfind("data[", 0) == 0) k.writes_buffer = true;
        }
    }
    std::map<int, bool> loop_exit_divergent;
    for (int round = 0; Walk(k, loop_exit_divergent, nullptr); round++)
        if (round > 10000) return {"the uniformity analysis does not converge"};
    std::vector<std::string> errors;
    Walk(k, loop_exit_divergent, &errors);
    return errors;
}

} // namespace msl_check
