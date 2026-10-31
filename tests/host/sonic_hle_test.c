// Host test of the HLE calls Sonic Origins (CUSA30448) brought in:
//  - libSceLoginDialog: the state machine the game polls (Initialize, Open, UpdateStatus until
//    FINISHED, GetResult writing result 0 and the host user's id into the game's 16-byte result,
//    nothing past its first 8 bytes), and the errors out of order;
//  - sceRtcCheckValid: every field's range and the error of the first field out of range,
//    February of leap and common years;
//  - sceKernelCheckReachability: an existing file and directory through the /app0 mount, a
//    missing path, a path over 255 bytes;
//  - sceUserServiceGetEvent: one login event of the host user, then
//    SCE_USER_SERVICE_ERROR_NO_EVENT (0x80960007), the code the game's event loop ends on (any
//    other error makes it poll forever);
//  - libSceNpWebApi2: library / user context / request ids, a user context per user, a request
//    that sends NOT_SIGNED_IN (no PSN sign-in) and then has no data or headers, headers after the
//    send, abort, delete, and the errors of unknown ids.
#include "ps4_rtc.h"
#include "ps4_syscalls.h"
#include "ps4_user_service.h"
#include "ps4_vfs.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

#define RUNTIME_STUBS_HAVE_VFS // ps4_vfs.c is linked for ps4_syscalls.c
#include "runtime_stubs.h"

// GPU hooks of the direct-memory code linked for ps4_syscalls.c (weak in the runtime).
void ps4_gnm_guest_remapped(uint64_t addr, uint64_t size) { (void)addr; (void)size; }
void ps4_gnm_notify_cpu_write(uint64_t addr, uint64_t size) { (void)addr; (void)size; }

void shim_sceLoginDialogInitialize(GuestContext *ctx);
void shim_sceLoginDialogOpen(GuestContext *ctx);
void shim_sceLoginDialogUpdateStatus(GuestContext *ctx);
void shim_sceLoginDialogGetResult(GuestContext *ctx);
void shim_sceLoginDialogTerminate(GuestContext *ctx);
void shim_sceRtcCheckValid(GuestContext *ctx);
void shim_sceNpWebApi2Initialize(GuestContext *ctx);
void shim_sceNpWebApi2Terminate(GuestContext *ctx);
void shim_sceNpWebApi2CreateUserContext(GuestContext *ctx);
void shim_sceNpWebApi2DeleteUserContext(GuestContext *ctx);
void shim_sceNpWebApi2CreateRequest(GuestContext *ctx);
void shim_sceNpWebApi2DeleteRequest(GuestContext *ctx);
void shim_sceNpWebApi2AbortRequest(GuestContext *ctx);
void shim_sceNpWebApi2AddHttpRequestHeader(GuestContext *ctx);
void shim_sceNpWebApi2SendRequest(GuestContext *ctx);
void shim_sceNpWebApi2ReadData(GuestContext *ctx);
void shim_sceNpWebApi2GetHttpResponseHeaderValueLength(GuestContext *ctx);

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

#define MEM_SIZE (1ULL << 20)
static GuestContext g;

static int32_t call6(void (*fn)(GuestContext *), uint64_t a, uint64_t b, uint64_t c, uint64_t d, uint64_t e,
                     uint64_t f) {
  g.rdx = c;
  g.rcx = d;
  g.r8 = e;
  g.r9 = f;
  g.rdi = a;
  g.rsi = b;
  g.rax = 0xdeadbeefdeadbeefULL;
  g.rsp = 0x8000;
  fn(&g);
  if (g.rsp != 0x8008) {
    printf("FAIL: shim did not return through SHIM_RETURN\n");
    exit(1);
  }
  return (int32_t)g.rax;
}
static int32_t call(void (*fn)(GuestContext *), uint64_t a, uint64_t b) { return call6(fn, a, b, 0, 0, 0, 0); }

static void test_login_dialog(void) {
  const uint64_t param = 0x1000, result = 0x2000;
  CHECK(call(shim_sceLoginDialogOpen, param, 0) == (int32_t)0x80B80003, "Open before Initialize");
  CHECK(call(shim_sceLoginDialogInitialize, 0, 0) == 0, "Initialize");
  CHECK(call(shim_sceLoginDialogInitialize, 0, 0) == (int32_t)0x80B80004, "Initialize twice");
  CHECK(call(shim_sceLoginDialogUpdateStatus, 0, 0) == 1, "status INITIALIZED");
  CHECK(call(shim_sceLoginDialogGetResult, result, 0) == (int32_t)0x80B80006, "GetResult before Open");
  CHECK(call(shim_sceLoginDialogOpen, 0, 0) == (int32_t)0x80B8000D, "Open(NULL)");
  // The game's parameter: size 0x40, mode, user ids -1.
  memset(g.mem_base + param, 0xff, 0x40);
  *(uint32_t *)(g.mem_base + param) = 0x40;
  CHECK(call(shim_sceLoginDialogOpen, param, 0) == 0, "Open");
  CHECK(call(shim_sceLoginDialogOpen, param, 0) == (int32_t)0x80B80006, "Open while running");
  CHECK(call(shim_sceLoginDialogUpdateStatus, 0, 0) == 3, "status FINISHED");
  memset(g.mem_base + result, 0, 16);
  memset(g.mem_base + result + 8, 0xa5, 8); // must stay as it is
  CHECK(call(shim_sceLoginDialogGetResult, result, 0) == 0, "GetResult");
  CHECK(*(int32_t *)(g.mem_base + result) == 0, "result OK");
  CHECK(*(int32_t *)(g.mem_base + result + 4) == ORBIS_USER_SERVICE_INITIAL_USER_ID, "user id 0x%x",
        *(int32_t *)(g.mem_base + result + 4));
  CHECK(*(uint64_t *)(g.mem_base + result + 8) == 0xa5a5a5a5a5a5a5a5ULL, "wrote past 8 bytes");
  CHECK(call(shim_sceLoginDialogOpen, param, 0) == 0, "Open again after FINISHED");
  CHECK(call(shim_sceLoginDialogTerminate, 0, 0) == 0, "Terminate");
  CHECK(call(shim_sceLoginDialogTerminate, 0, 0) == (int32_t)0x80B80003, "Terminate twice");
}

static int32_t rtc_check(uint16_t y, uint16_t mo, uint16_t d, uint16_t h, uint16_t mi, uint16_t s, uint32_t us) {
  OrbisDateTime *t = (OrbisDateTime *)(g.mem_base + 0x3000);
  *t = (OrbisDateTime){y, mo, d, h, mi, s, us};
  return call(shim_sceRtcCheckValid, 0x3000, 0);
}

static void test_rtc_check_valid(void) {
  CHECK(rtc_check(2026, 10, 29, 23, 59, 59, 999999) == 0, "valid");
  CHECK(rtc_check(1, 1, 1, 0, 0, 0, 0) == 0, "year 1");
  CHECK(rtc_check(2024, 2, 29, 0, 0, 0, 0) == 0, "leap day");
  CHECK(rtc_check(2000, 2, 29, 0, 0, 0, 0) == 0, "leap day 2000");
  CHECK(rtc_check(1900, 2, 29, 0, 0, 0, 0) == (int32_t)0x80B5000A, "1900 not leap");
  CHECK(rtc_check(2026, 4, 31, 0, 0, 0, 0) == (int32_t)0x80B5000A, "April 31");
  CHECK(rtc_check(0, 1, 1, 0, 0, 0, 0) == (int32_t)0x80B50008, "year 0");
  CHECK(rtc_check(10000, 1, 1, 0, 0, 0, 0) == (int32_t)0x80B50008, "year 10000");
  CHECK(rtc_check(2026, 13, 1, 0, 0, 0, 0) == (int32_t)0x80B50009, "month 13");
  CHECK(rtc_check(2026, 1, 0, 0, 0, 0, 0) == (int32_t)0x80B5000A, "day 0");
  CHECK(rtc_check(2026, 1, 1, 24, 0, 0, 0) == (int32_t)0x80B5000B, "hour 24");
  CHECK(rtc_check(2026, 1, 1, 0, 60, 0, 0) == (int32_t)0x80B5000C, "minute 60");
  CHECK(rtc_check(2026, 1, 1, 0, 0, 60, 0) == (int32_t)0x80B5000D, "second 60");
  CHECK(rtc_check(2026, 1, 1, 0, 0, 0, 1000000) == (int32_t)0x80B5000E, "microsecond");
  CHECK(rtc_check(2026, 13, 0, 99, 0, 0, 0) == (int32_t)0x80B50009, "first bad field");
  CHECK(call(shim_sceRtcCheckValid, 0, 0) == (int32_t)0x80B50002, "NULL");
}

static int32_t reach(const char *path) {
  strcpy((char *)g.mem_base + 0x4000, path);
  return call(shim_sceKernelCheckReachability, 0x4000, 0);
}

static void test_check_reachability(void) {
  char root[] = "/tmp/sonic_hle_test.XXXXXX";
  CHECK(mkdtemp(root) != NULL, "mkdtemp");
  char path[256];
  snprintf(path, sizeof(path), "%s/movie", root);
  CHECK(mkdir(path, 0755) == 0, "mkdir");
  snprintf(path, sizeof(path), "%s/movie/logo.usm", root);
  FILE *f = fopen(path, "w");
  CHECK(f != NULL, "create");
  if (f) fclose(f);
  ps4_vfs_init(root);
  CHECK(reach("/app0/movie/logo.usm") == 0, "file");
  CHECK(reach("/app0/movie") == 0, "directory");
  CHECK(reach("/app0/movie/missing.usm") == (int32_t)0x80020002, "missing");
  char longp[300];
  memset(longp, 'a', sizeof(longp) - 1);
  longp[0] = '/';
  longp[sizeof(longp) - 1] = 0;
  CHECK(reach(longp) == (int32_t)0x8002003F, "too long");
  CHECK(call(shim_sceKernelCheckReachability, 0, 0) == (int32_t)0x80020016, "NULL");
  unlink(path);
  snprintf(path, sizeof(path), "%s/movie", root);
  rmdir(path);
  rmdir(root);
}

static void test_user_service_events(void) {
  const uint64_t ev = 0x6000;
  CHECK(call(shim_sceUserServiceGetEvent, ev, 0) == 0, "first event");
  CHECK(*(int32_t *)(g.mem_base + ev) == ORBIS_USER_SERVICE_EVENT_TYPE_LOGIN, "login event");
  CHECK(*(int32_t *)(g.mem_base + ev + 4) == ORBIS_USER_SERVICE_INITIAL_USER_ID, "login user");
  CHECK(call(shim_sceUserServiceGetEvent, ev, 0) == (int32_t)0x80960007, "NO_EVENT 0x%x", (uint32_t)g.rax);
  CHECK(call(shim_sceUserServiceGetEvent, 0, 0) == (int32_t)0x80960005, "NULL");
}

static void test_np_webapi2(void) {
  const int32_t lib = call(shim_sceNpWebApi2Initialize, 1, 0x10000);
  CHECK(lib > 0 && lib < 0x8000, "lib ctx %d", lib);
  CHECK(call(shim_sceNpWebApi2CreateUserContext, 0x8000, ORBIS_USER_SERVICE_INITIAL_USER_ID) == (int32_t)0x80553403,
        "invalid lib id");
  const int32_t user = call(shim_sceNpWebApi2CreateUserContext, (uint64_t)lib, ORBIS_USER_SERVICE_INITIAL_USER_ID);
  CHECK(user > 0 && user >> 16 == lib, "user ctx %#x", user);
  CHECK(call(shim_sceNpWebApi2CreateUserContext, (uint64_t)lib, ORBIS_USER_SERVICE_INITIAL_USER_ID) == (int32_t)0x8055340a,
        "second context for the same user");
  strcpy((char *)g.mem_base + 0x7000, "userProfile");
  strcpy((char *)g.mem_base + 0x7100, "/v1/users/me/profile");
  strcpy((char *)g.mem_base + 0x7200, "GET");
  const uint64_t req_out = 0x7300;
  CHECK(call6(shim_sceNpWebApi2CreateRequest, (uint64_t)(uint32_t)user, 0x7000, 0x7100, 0x7200, 0, req_out) == 0,
        "create request");
  int64_t req;
  memcpy(&req, g.mem_base + req_out, 8);
  CHECK(req >> 32 == user && req >> 48 == lib, "request id %#llx", (unsigned long long)req);
  CHECK(call6(shim_sceNpWebApi2AddHttpRequestHeader, (uint64_t)req, 0x7200, 0x7200, 0, 0, 0) == 0, "header");
  CHECK(call6(shim_sceNpWebApi2SendRequest, (uint64_t)req, 0, 0, 0, 0, 0) == (int32_t)0x80553407, "not signed in");
  CHECK(call6(shim_sceNpWebApi2AddHttpRequestHeader, (uint64_t)req, 0x7200, 0x7200, 0, 0, 0) == (int32_t)0x8055341a,
        "header after send");
  CHECK(call6(shim_sceNpWebApi2ReadData, (uint64_t)req, 0x7400, 16, 0, 0, 0) == (int32_t)0x80431100, "no data");
  CHECK(call6(shim_sceNpWebApi2GetHttpResponseHeaderValueLength, (uint64_t)req, 0x7200, 0x7400, 0, 0, 0) ==
            (int32_t)0x80432025,
        "no headers");
  CHECK(call(shim_sceNpWebApi2AbortRequest, (uint64_t)req, 0) == 0, "abort");
  CHECK(call6(shim_sceNpWebApi2SendRequest, (uint64_t)req, 0, 0, 0, 0, 0) == (int32_t)0x80553409, "aborted");
  CHECK(call(shim_sceNpWebApi2DeleteRequest, (uint64_t)req, 0) == 0, "delete request");
  CHECK(call(shim_sceNpWebApi2DeleteRequest, (uint64_t)req, 0) == (int32_t)0x80553406, "deleted request");
  CHECK(call(shim_sceNpWebApi2DeleteUserContext, (uint64_t)(uint32_t)user, 0) == 0, "delete user");
  CHECK(call6(shim_sceNpWebApi2CreateRequest, (uint64_t)(uint32_t)user, 0x7000, 0x7100, 0x7200, 0, req_out) ==
            (int32_t)0x80553405,
        "request on a deleted user context");
  CHECK(call(shim_sceNpWebApi2Terminate, (uint64_t)lib, 0) == 0, "terminate");
  CHECK(call(shim_sceNpWebApi2Terminate, (uint64_t)lib, 0) == (int32_t)0x80553404, "terminated");
}

int main(void) {
  g.mem_base = (uint8_t *)calloc(1, MEM_SIZE);
  g.mem_size = MEM_SIZE;
  test_login_dialog();
  test_rtc_check_valid();
  test_check_reachability();
  test_user_service_events();
  test_np_webapi2();
  if (g_failures) {
    printf("sonic_hle_test: %d failure(s)\n", g_failures);
    return 1;
  }
  printf("sonic_hle_test: PASS\n");
  return 0;
}
