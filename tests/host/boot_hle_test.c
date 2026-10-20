// Host test of the Uncharted 4 boot-path HLE set that is plain state or formatting:
// NpParty states, NpSignaling context options, NpProfileDialog close, Https certificate
// loading, NetCtl result, Net ether formatting, Coredump. Everything is called through the
// guest ABI where the function has a shim (registers in, rax out), exactly as the recompiled
// game calls it.
#include "ps4_http.h"
#include "ps4_net.h"
#include "ps4_netctl.h"
#include "ps4_np.h"
#include "ps4_np_profile_dialog.h"

#include <stdio.h>
#include <string.h>

void shim_sceCoredumpAttachMemoryRegionAsUserFile(GuestContext *ctx);
void shim_sceCoredumpGetStopInfoGpu(GuestContext *ctx);
void shim_sceNpSignalingDeleteContext(GuestContext *ctx);

static int g_failures;
#define CHECK(cond, ...)                                                       \
  do {                                                                         \
    if (!(cond)) {                                                             \
      printf("FAIL line %d: %s  ", __LINE__, #cond);                           \
      printf(__VA_ARGS__);                                                     \
      printf("\n");                                                            \
      g_failures++;                                                            \
    }                                                                          \
  } while (0)

#define MEM_SIZE 0x100000
static GuestContext g_ctx;
static uint8_t g_mem[MEM_SIZE];

// Calls a shim with System V arguments. Returns eax as the guest sees it.
static int32_t call(void (*shim)(GuestContext *), uint64_t a1, uint64_t a2, uint64_t a3) {
  g_ctx.rsp = 0x1000;
  g_ctx.rdi = a1;
  g_ctx.rsi = a2;
  g_ctx.rdx = a3;
  shim(&g_ctx);
  if (g_ctx.rsp != 0x1008) {
    printf("FAIL: shim did not pop its return address (rsp=0x%llx)\n", (unsigned long long)g_ctx.rsp);
    g_failures++;
  }
  return (int32_t)g_ctx.rax;
}

#define NP_PARTY_ALREADY_INITIALIZED ((int32_t)0x80552502)
#define NP_PARTY_NOT_INITIALIZED ((int32_t)0x80552503)
#define NP_PARTY_INVALID_ARGUMENT ((int32_t)0x80552504)
#define NP_PARTY_NOT_IN_PARTY ((int32_t)0x80552506)

static void test_np_party(void) {
  // Before Initialize everything but Initialize reports NOT_INITIALIZED.
  CHECK(call(shim_sceNpPartyCheckCallback, 0, 0, 0) == NP_PARTY_NOT_INITIALIZED, "check before init");
  CHECK(call(shim_sceNpPartyRegisterHandler, 0x2000, 0, 0) == NP_PARTY_NOT_INITIALIZED, "register before init");
  CHECK(call(shim_sceNpPartyTerminate, 0, 0, 0) == NP_PARTY_NOT_INITIALIZED, "terminate before init");
  CHECK(call(shim_sceNpPartyGetVoiceChatPriority, 0x2000, 0, 0) == NP_PARTY_NOT_INITIALIZED, "priority before init");

  CHECK(call(shim_sceNpPartyInitialize, 0x3000, 0, 0) == 0, "initialize");
  CHECK(call(shim_sceNpPartyInitialize, 0x3000, 0, 0) == NP_PARTY_ALREADY_INITIALIZED, "second initialize");

  // Registration stores the block's address and never calls it.
  CHECK(call(shim_sceNpPartyRegisterHandler, 0, 0, 0) == NP_PARTY_INVALID_ARGUMENT, "NULL handler");
  CHECK(call(shim_sceNpPartyRegisterHandler, 0x2000, 0, 0) == 0, "register handler");
  CHECK(call(shim_sceNpPartyRegisterPrivateHandler, 0x2400, 0, 0) == 0, "register private handler");
  CHECK(ps4_np_party_handler(false) == 0x2000 && ps4_np_party_handler(true) == 0x2400, "recorded handlers");
  CHECK(call(shim_sceNpPartyUnregisterPrivateHandler, 0, 0, 0) == 0, "unregister private");
  CHECK(ps4_np_party_handler(true) == 0 && ps4_np_party_handler(false) == 0x2000, "private handler cleared only");
  CHECK(call(shim_sceNpPartyCheckCallback, 0, 0, 0) == 0, "nothing to dispatch");

  // Never in a party while offline: the voice chat priority has no party to belong to.
  CHECK(call(shim_sceNpPartyGetVoiceChatPriority, 0x2800, 0, 0) == NP_PARTY_NOT_IN_PARTY, "get priority");
  CHECK(call(shim_sceNpPartySetVoiceChatPriority, 0x2800, 0, 0) == NP_PARTY_NOT_IN_PARTY, "set priority");
  CHECK(call(shim_sceNpPartyGetVoiceChatPriority, 0, 0, 0) == NP_PARTY_INVALID_ARGUMENT, "priority NULL out");

  // Terminate drops the registrations; a new Initialize starts clean.
  CHECK(call(shim_sceNpPartyTerminate, 0, 0, 0) == 0, "terminate");
  CHECK(ps4_np_party_handler(false) == 0, "handler dropped by terminate");
  CHECK(call(shim_sceNpPartyTerminate, 0, 0, 0) == NP_PARTY_NOT_INITIALIZED, "second terminate");
  CHECK(call(shim_sceNpPartyInitialize, 0x3000, 0, 0) == 0 && ps4_np_party_handler(false) == 0, "re-initialize is clean");
  CHECK(call(shim_sceNpPartyTerminate, 0, 0, 0) == 0, "final terminate");
}

static void test_np_signaling(void) {
  const int32_t NOT_INITIALIZED = (int32_t)0x80552701, CTX_NOT_FOUND = (int32_t)0x80552705, INVALID_ARGUMENT = (int32_t)0x80552715;
  uint32_t id = 0;
  // Context ids are handed out before Initialize too (no state check in Create), but options need Initialize.
  CHECK(sceNpSignalingCreateContext(NULL, NULL, NULL, &id) == 0 && id != 0, "create");
  CHECK(call(shim_sceNpSignalingSetContextOption, id, 1, 1) == NOT_INITIALIZED, "set option before init");
  CHECK(sceNpSignalingInitialize(0, 0, 0, 0) == 0, "init");
  CHECK(sceNpSignalingCreateContext(NULL, NULL, NULL, &id) == 0, "create after init");
  CHECK(call(shim_sceNpSignalingSetContextOption, id + 100, 1, 1) == CTX_NOT_FOUND, "unknown context");
  CHECK(call(shim_sceNpSignalingSetContextOption, 0, 1, 1) == CTX_NOT_FOUND, "context 0");
  CHECK(call(shim_sceNpSignalingSetContextOption, id, 2, 1) == INVALID_ARGUMENT, "unknown option id");
  CHECK(call(shim_sceNpSignalingSetContextOption, id, 1, 2) == INVALID_ARGUMENT, "option value 2");
  CHECK(ps4_np_signaling_ctx_flags(id) == 0, "flags untouched by failures");
  CHECK(call(shim_sceNpSignalingSetContextOption, id, 1, 1) == 0 && ps4_np_signaling_ctx_flags(id) == 0x2, "set flag");
  CHECK(call(shim_sceNpSignalingSetContextOption, id, 1, 0) == 0 && ps4_np_signaling_ctx_flags(id) == 0, "clear flag");
  CHECK(call(shim_sceNpSignalingSetContextOption, id, 1, 1) == 0, "set again");
  // Deleting the context makes it unknown; so does terminating the library.
  CHECK(call(shim_sceNpSignalingDeleteContext, id, 0, 0) == 0, "delete");
  CHECK(call(shim_sceNpSignalingSetContextOption, id, 1, 1) == CTX_NOT_FOUND, "deleted context");
  CHECK(sceNpSignalingCreateContextA(1, NULL, NULL, &id) == 0, "createA");
  CHECK(sceNpSignalingTerminate() == 0, "terminate");
  CHECK(call(shim_sceNpSignalingSetContextOption, id, 1, 1) == NOT_INITIALIZED, "after terminate");
}

static void test_profile_dialog(void) {
  const int32_t NOT_INITIALIZED = (int32_t)0x80b80003, NOT_RUNNING = (int32_t)0x80b8000b;
  CHECK(call(shim_sceNpProfileDialogClose, 0, 0, 0) == NOT_INITIALIZED, "close before init");
  CHECK(sceNpProfileDialogInitialize() == 0, "init");
  CHECK(call(shim_sceNpProfileDialogClose, 0, 0, 0) == NOT_RUNNING, "close when not running");
  OrbisNpProfileDialogParamA p;
  memset(&p, 0, sizeof(p));
  p.userData = (void *)0x1234;
  CHECK(sceNpProfileDialogOpenA(&p) == 0 && sceNpProfileDialogGetStatus() == ORBIS_COMMON_DIALOG_STATUS_RUNNING, "open");
  CHECK(call(shim_sceNpProfileDialogClose, 0, 0, 0) == 0, "close running dialog");
  CHECK(sceNpProfileDialogGetStatus() == ORBIS_COMMON_DIALOG_STATUS_FINISHED, "finished after close");
  OrbisNpProfileDialogResult r;
  CHECK(sceNpProfileDialogGetResult(&r) == 0 && r.userAction == ORBIS_COMMON_DIALOG_RESULT_OK && r.userData == (void *)0x1234,
        "result after close");
  CHECK(call(shim_sceNpProfileDialogClose, 0, 0, 0) == NOT_RUNNING, "close when finished");
  CHECK(sceNpProfileDialogTerminate() == 0, "terminate");
}

static void test_https_load_cert(void) {
  const int32_t BEFORE_INIT = (int32_t)0x80431001, INVALID_ID = (int32_t)0x80431100;
  // shim_sceHttpsLoadCert(ctxId, caNum, caList, cert, privKey)
  g_ctx.rcx = g_ctx.r8 = 0;
  CHECK(call(shim_sceHttpsLoadCert, 1, 0, 0) == BEFORE_INIT, "no library");
  int32_t http = sceHttpInit(1, 1, 0x10000);
  CHECK(http > 0, "http init");
  CHECK(call(shim_sceHttpsLoadCert, (uint64_t)http + 50, 0, 0) == INVALID_ID, "unknown id");
  int32_t tmpl = sceHttpCreateTemplate(http, "ua", 1, 0);
  CHECK(call(shim_sceHttpsLoadCert, (uint64_t)tmpl, 0, 0) == INVALID_ID, "a template id is not a library context");
  CHECK(!ps4_http_ctx_has_custom_ca(http), "no custom CA yet");
  CHECK(call(shim_sceHttpsLoadCert, (uint64_t)http, 0, 0) == 0, "load cert");
  CHECK(ps4_http_ctx_has_custom_ca(http), "custom CA recorded");
  int32_t http2 = sceHttpInit(1, 1, 0x10000);
  CHECK(!ps4_http_ctx_has_custom_ca(http2), "other context unaffected");
  CHECK(sceHttpTerm(http) == 0, "term");
  CHECK(call(shim_sceHttpsLoadCert, (uint64_t)http, 0, 0) == INVALID_ID, "terminated context");
  CHECK(sceHttpTerm(http2) == 0, "term 2");
  CHECK(call(shim_sceHttpsLoadCert, (uint64_t)http2, 0, 0) == BEFORE_INIT, "no library again");
}

static void test_netctl_net(void) {
  // sceNetCtlGetResult(eventType, int *err)
  *(int32_t *)(g_mem + 0x2000) = 77;
  CHECK(call(shim_sceNetCtlGetResult, 4, 0x2000, 0) == 0 && *(int32_t *)(g_mem + 0x2000) == 0, "get result");
  CHECK(call(shim_sceNetCtlGetResult, 4, 0, 0) == (int32_t)0x80412107, "NULL error pointer");

  // sceNetEtherNtostr(addr, buf, len)
  const uint8_t mac[6] = {0x00, 0xD9, 0xD1, 0x0a, 0xbc, 0xFF};
  memcpy(g_mem + 0x2100, mac, 6);
  memset(g_mem + 0x2200, 'x', 40);
  g_ctx.fs_base = 0x400; // errno slot at fs_base + 0x100
  CHECK(call(shim_sceNetEtherNtostr, 0x2100, 0x2200, 18) == 0, "ntostr");
  CHECK(strcmp((char *)g_mem + 0x2200, "00:d9:d1:0a:bc:ff") == 0, "ntostr text '%s'", (char *)g_mem + 0x2200);
  CHECK(g_mem[0x2200 + 18] == 'x', "no write past the terminator");
  CHECK(call(shim_sceNetEtherNtostr, 0x2100, 0x2200, 17) == -1 && *(int *)(g_mem + 0x500) == 28, "short buffer: ENOSPC, errno=%d",
        *(int *)(g_mem + 0x500));
  CHECK(call(shim_sceNetEtherNtostr, 0, 0x2200, 18) == -1 && *(int *)(g_mem + 0x500) == 14, "NULL address: EFAULT");
  CHECK(call(shim_sceNetEtherNtostr, 0x2100, 0, 18) == -1 && *(int *)(g_mem + 0x500) == 14, "NULL buffer: EFAULT");
  g_ctx.fs_base = 0;
}

static void test_coredump(void) {
  CHECK(call(shim_sceCoredumpAttachMemoryRegionAsUserFile, 0x2000, 0x1000, 0) == 0, "attach is a no-op");
  CHECK(call(shim_sceCoredumpGetStopInfoGpu, 0x2000, 0, 0) == (int32_t)0x81180003, "stop info outside a handler");
}

int main(void) {
  g_ctx.mem_base = g_mem;
  g_ctx.mem_size = MEM_SIZE;
  test_np_party();
  test_np_signaling();
  test_profile_dialog();
  test_https_load_cert();
  test_netctl_net();
  test_coredump();
  fflush(stdout);
  if (g_failures) {
    printf("boot_hle_test: %d FAILED\n", g_failures);
    return 1;
  }
  printf("boot_hle_test: PASS\n");
  return 0;
}
