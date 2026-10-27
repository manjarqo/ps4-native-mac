// Host test of sigfillset (FreeBSD sigset_t: four 32-bit words) and scePlayGoSetToDoList,
// called through the guest ABI.
#include "ps4_playgo.h"
#include "ps4_sigset.h"

#include <errno.h>
#include <stdio.h>
#include <string.h>

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

#define MEM_SIZE 0x10000
static uint8_t g_mem[MEM_SIZE];
static GuestContext g_ctx;

static int64_t call(void (*shim)(GuestContext *), uint64_t a1, uint64_t a2, uint64_t a3) {
  g_ctx.rsp = 0x1000;
  g_ctx.rdi = a1;
  g_ctx.rsi = a2;
  g_ctx.rdx = a3;
  shim(&g_ctx);
  if (g_ctx.rsp != 0x1008) {
    printf("FAIL: shim did not pop its return address\n");
    g_failures++;
  }
  return (int64_t)g_ctx.rax;
}

int main(void) {
  g_ctx.mem_base = g_mem;
  g_ctx.mem_size = MEM_SIZE;
  g_ctx.fs_base = 0x400;
  uint32_t *set = (uint32_t *)(g_mem + 0x2000);
  memset(set, 0, 16);
  set[4] = 0x12345678; // the word after the set must not change
  CHECK(call(shim_sigfillset, 0x2000, 0, 0) == 0, "sigfillset");
  CHECK(set[0] == 0xffffffffu && set[1] == 0xffffffffu && set[2] == 0xffffffffu && set[3] == 0xffffffffu,
        "all 128 bits set");
  CHECK(set[4] == 0x12345678u, "no write past the set");
  CHECK((int32_t)call(shim_sigfillset, 0, 0, 0) == -1, "NULL set");
  CHECK(*(int *)(g_mem + g_ctx.fs_base + 0x100) == 22, "errno EINVAL");

  uint32_t handle_var = 0;
  memcpy(g_mem + 0x3000, &handle_var, 4);
  CHECK(call(shim_scePlayGoOpen, 0x3000, 0, 0) == 0, "open");
  const uint32_t h = *(uint32_t *)(g_mem + 0x3000);
  OrbisPlayGoToDo *todo = (OrbisPlayGoToDo *)(g_mem + 0x3100);
  todo[0].chunkId = 3;
  todo[0].locus = ORBIS_PLAYGO_LOCUS_LOCAL_FAST;
  CHECK(call(shim_scePlayGoSetToDoList, h, 0x3100, 1) == 0, "set a to-do list");
  CHECK(call(shim_scePlayGoSetToDoList, h, 0, 0) == 0, "empty list");
  CHECK((int32_t)call(shim_scePlayGoSetToDoList, h, 0, 2) == -EINVAL, "NULL list with entries");
  uint32_t n = 99;
  memcpy(g_mem + 0x3200, &n, 4);
  g_ctx.rcx = 0x3200;
  CHECK(call(shim_scePlayGoGetToDoList, h, 0x3100, 4) == 0 && *(uint32_t *)(g_mem + 0x3200) == 0,
        "nothing left to install after a to-do list");
  if (g_failures) {
    printf("playgo_sigset_test: %d failure(s)\n", g_failures);
    return 1;
  }
  printf("playgo_sigset_test: PASS\n");
  return 0;
}
