// Backend selection (ps4gnm::ChooseBackend, ps4_gnm_backend.h): the default, explicit choices,
// and every way an explicit "4" is refused with a reason instead of falling back.
#include <signal.h>
#include <stdio.h>
#include <string.h>
#include <sys/wait.h>
#include <unistd.h>

#include "ps4_gnm_backend.h"

using namespace ps4gnm;

static int g_fail = 0;
#define CHECK(c, ...)                                                                   \
    do {                                                                                \
        if (!(c)) {                                                                     \
            fprintf(stderr, "gnm_backend_select_test: FAIL %s:%d: ", __FILE__, __LINE__); \
            fprintf(stderr, __VA_ARGS__);                                               \
            fprintf(stderr, "\n");                                                      \
            g_fail++;                                                                   \
        }                                                                               \
    } while (0)

// A bind op left unset by a backend aborts naming the op, instead of a call through a null pointer.
// The op runs in a child process whose SIGABRT handler exits with kAbortExit, so the run leaves no
// crash report; any other end of the child (a crash, a return) fails the check.
constexpr int kAbortExit = 86;
static void OnAbort(int) { _exit(kAbortExit); }

template <typename F>
static bool AbortsNaming(const char* op, F call) {
    int fd[2];
    if (pipe(fd)) return false;
    fflush(stdout);
    fflush(stderr);
    const pid_t pid = fork();
    if (pid < 0) return false;
    if (pid == 0) {
        dup2(fd[1], 2);
        close(fd[0]);
        signal(SIGABRT, OnAbort);
        call();
        _exit(0);
    }
    close(fd[1]);
    char msg[512];
    size_t n = 0;
    for (ssize_t r; n < sizeof msg - 1 && (r = read(fd[0], msg + n, sizeof msg - 1 - n)) > 0;) n += (size_t)r;
    msg[n] = 0;
    close(fd[0]);
    int st = 0;
    waitpid(pid, &st, 0);
    char want[64];
    snprintf(want, sizeof want, "bind op '%s'", op);
    const bool ok = WIFEXITED(st) && WEXITSTATUS(st) == kAbortExit && strstr(msg, want);
    if (!ok)
        fprintf(stderr, "gnm_backend_select_test: op %s: status 0x%x, stderr \"%s\"\n", op, st, msg);
    return ok;
}

int main() {
    // The default (no PS4_GNM_METAL) after Phase 6: Metal 3, also on a Metal 4 device (Metal 4 was
    // slower in the Phase 6 A/B, docs/metal4-baseline.md).
    CHECK(!DefaultPrefersMetal4(), "the renderer's default prefers Metal 4");
    CHECK(ChooseBackend(nullptr, true, kGnmCapAll, false, DefaultPrefersMetal4()).kind == GnmBackendKind::Metal3,
          "default, Metal 4 device");
    CHECK(ChooseBackend(nullptr, false, kGnmCapAll, false, DefaultPrefersMetal4()).kind == GnmBackendKind::Metal3,
          "default, Metal 3 device");
    // default: Metal 3 without prefer_metal4; Metal 4 only with a complete backend on a Metal 4 GPU
    GnmBackendChoice c = ChooseBackend(nullptr, true, kGnmCapAll, false, false);
    CHECK(c.ok && c.kind == GnmBackendKind::Metal3, "default without prefer_metal4: %s", c.why.c_str());
    c = ChooseBackend("", true, kGnmCapAll, false, true);
    CHECK(c.ok && c.kind == GnmBackendKind::Metal4, "default with prefer_metal4: %s", c.why.c_str());
    c = ChooseBackend(nullptr, false, kGnmCapAll, false, true);
    CHECK(c.ok && c.kind == GnmBackendKind::Metal3 && strstr(c.why.c_str(), "MTLGPUFamilyMetal4"),
          "default on a GPU without Metal 4: %s", c.why.c_str());
    c = ChooseBackend(nullptr, true, kGnmCapClears, false, true);
    CHECK(c.ok && c.kind == GnmBackendKind::Metal3, "default with an incomplete Metal 4 backend: %s", c.why.c_str());
    // explicit
    c = ChooseBackend("3", true, 0, false, true);
    CHECK(c.ok && c.kind == GnmBackendKind::Metal3, "explicit 3: %s", c.why.c_str());
    c = ChooseBackend("4", true, kGnmCapAll, false, false);
    CHECK(c.ok && c.kind == GnmBackendKind::Metal4, "explicit 4: %s", c.why.c_str());
    // refusals, each with its reason
    c = ChooseBackend("4", false, kGnmCapAll, false, false);
    CHECK(!c.ok && strstr(c.why.c_str(), "MTLGPUFamilyMetal4"), "4 without Metal 4 GPU: %s", c.why.c_str());
    c = ChooseBackend("4", true, 0, false, false);
    CHECK(!c.ok && strstr(c.why.c_str(), "not implemented"), "4 without a backend: %s", c.why.c_str());
    c = ChooseBackend("4", true, kGnmCapClears, false, false);
    CHECK(!c.ok && strstr(c.why.c_str(), "PS4_GNM_MTL4_ONLY_CLEARS=1"), "4 without draws: %s", c.why.c_str());
    c = ChooseBackend("4", true, kGnmCapClears, true, false);
    CHECK(c.ok && c.kind == GnmBackendKind::Metal4, "4 without draws, only clears: %s", c.why.c_str());
    c = ChooseBackend("5", true, kGnmCapAll, false, false);
    CHECK(!c.ok && strstr(c.why.c_str(), "must be 3 or 4"), "5: %s", c.why.c_str());
    c = ChooseBackend("metal4", true, kGnmCapAll, false, false);
    CHECK(!c.ok, "metal4 accepted");
    // an explicit 4 needs every capability of the requested mode
    c = ChooseBackend("4", true, kGnmCapClears | kGnmCapDraws, false, false);
    CHECK(!c.ok && strstr(c.why.c_str(), "compute, copies"), "4 without compute and copies: %s", c.why.c_str());
    c = ChooseBackend("4", true, kGnmCapAll & ~kGnmCapCopies, false, false);
    CHECK(!c.ok && strstr(c.why.c_str(), "copies"), "4 without copies: %s", c.why.c_str());
    c = ChooseBackend("4", true, kGnmCapCompute, true, false);
    CHECK(!c.ok && strstr(c.why.c_str(), "render passes"), "4 only clears without render passes: %s", c.why.c_str());
    // PS4_GNM_MTL4_ONLY_CLEARS on Metal 3 has no effect, and the reason says so
    c = ChooseBackend(nullptr, true, kGnmCapAll, true, false);
    CHECK(c.ok && c.kind == GnmBackendKind::Metal3 && strstr(c.why.c_str(), "PS4_GNM_MTL4_ONLY_CLEARS ignored"),
          "only clears on the default Metal 3: %s", c.why.c_str());
    c = ChooseBackend("3", true, kGnmCapClears, true, false);
    CHECK(c.ok && c.kind == GnmBackendKind::Metal3 && strstr(c.why.c_str(), "PS4_GNM_MTL4_ONLY_CLEARS ignored"),
          "only clears on explicit 3: %s", c.why.c_str());
    c = ChooseBackend("3", true, kGnmCapAll, false, false);
    CHECK(c.ok && !strstr(c.why.c_str(), "ONLY_CLEARS"), "explicit 3 without only clears: %s", c.why.c_str());
    // every entry of a default-constructed bind table aborts with the op's name
    const GnmBindOps ops{};
    CHECK(AbortsNaming("buffer", [&] { ops.buffer(nullptr, GnmStage::Vertex, 0, nil, 0); }), "unset buffer op");
    CHECK(AbortsNaming("buffer_offset", [&] { ops.buffer_offset(nullptr, GnmStage::Vertex, 0, 0); }),
          "unset buffer_offset op");
    CHECK(AbortsNaming("bytes", [&] { ops.bytes(nullptr, GnmStage::Fragment, 0, nullptr, 0); }), "unset bytes op");
    CHECK(AbortsNaming("texture", [&] { ops.texture(nullptr, GnmStage::Fragment, 0, nil); }), "unset texture op");
    CHECK(AbortsNaming("sampler", [&] { ops.sampler(nullptr, GnmStage::Compute, 0, nil); }), "unset sampler op");
    CHECK(AbortsNaming("use", [&] { ops.use(nullptr, GnmStage::Compute, nil, false); }), "unset use op");
    CHECK(!strcmp(BackendName(GnmBackendKind::Metal3), "metal3") && !strcmp(BackendName(GnmBackendKind::Metal4), "metal4"),
          "BackendName");
    printf("gnm_backend_select_test: %s\n", g_fail ? "FAIL" : "PASS");
    return g_fail ? 1 : 0;
}
