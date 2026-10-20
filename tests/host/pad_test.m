// Host test of libScePad on the real ps4_pad.m:
//  - scePadGetControllerInformation through the guest ABI, as Uncharted 4 calls it: it fills
//    exactly the 28-byte ScePadControllerInformation (one connected local pad, connectedCount
//    equal to the pad data's), writes nothing past it, and rejects unknown handles.
//  - PS4_PAD_CTL: actions such as "shot" run in file order, after the waits and holds before them.
#import <Foundation/Foundation.h>

#include "ps4_pad.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

// What ps4_pad.m takes from the renderer and the window.
volatile int g_ps4_screenshot_request;
volatile int g_ps4_gnm_dump_request;
volatile uint64_t g_ps4_videoout_flip_count;
static int g_close_requests;
void ps4_metal_screen_request_close(void) { g_close_requests++; }
void ps4_metal_screen_request_terminate(void) {}

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
static GuestContext g_ctx;
static uint8_t g_mem[MEM_SIZE];

static int32_t call(void (*shim)(GuestContext *), uint64_t a1, uint64_t a2, uint64_t a3) {
  g_ctx.rsp = 0x1000;
  g_ctx.rdi = a1;
  g_ctx.rsi = a2;
  g_ctx.rdx = a3;
  shim(&g_ctx);
  CHECK(g_ctx.rsp == 0x1008, "shim did not pop its return address");
  return (int32_t)g_ctx.rax;
}

static double now_ms(void) {
  struct timespec t;
  clock_gettime(CLOCK_MONOTONIC, &t);
  return t.tv_sec * 1000.0 + t.tv_nsec / 1e6;
}

static void test_controller_information(int32_t handle) {
  const uint64_t info = 0x2000;
  memset(g_mem + info, 0xAB, 64);
  int32_t rc = call(shim_scePadGetControllerInformation, (uint64_t)handle, info, 0);
  CHECK(rc == 0, "rc=0x%x", rc);
  OrbisPadControllerInformation ci;
  memcpy(&ci, g_mem + info, sizeof(ci));
  CHECK(ci.connected == 1, "connected=%u", ci.connected);
  CHECK(ci.connectedCount == 1, "connectedCount=%u", ci.connectedCount);
  CHECK(ci.connectionType == ORBIS_PAD_CONNECTION_TYPE_LOCAL, "connectionType=%u (1 = remote play)",
        ci.connectionType);
  CHECK(ci.deviceClass == ORBIS_PAD_DEVICE_CLASS_STANDARD, "deviceClass=%d", ci.deviceClass);
  CHECK(ci.touchPadResolutionX == 1920 && ci.touchPadResolutionY == 950, "touch pad %ux%u",
        ci.touchPadResolutionX, ci.touchPadResolutionY);
  CHECK(ci.touchPadPixelDensity == 1.0f, "pixel density %f", ci.touchPadPixelDensity);
  // Byte offsets the game reads (connectionType at 10, connected at 12).
  CHECK(g_mem[info + 10] == 0 && g_mem[info + 11] == 1 && g_mem[info + 12] == 1, "layout %u %u %u",
        g_mem[info + 10], g_mem[info + 11], g_mem[info + 12]);
  int clobbered = 0;
  for (int i = 28; i < 64; i++) clobbered += g_mem[info + i] != 0xAB;
  CHECK(clobbered == 0, "%d bytes written past the 28-byte struct", clobbered);

  // Its connectedCount is the one in the pad data (the game compares the two).
  OrbisPadData d;
  CHECK(scePadReadState(handle, &d) == 0, "ReadState");
  CHECK(d.count == ci.connectedCount && d.connected == 1, "pad data count=%u connected=%u", d.count, d.connected);

  rc = call(shim_scePadGetControllerInformation, (uint64_t)(handle + 7), info, 0);
  CHECK(rc == ORBIS_PAD_ERROR_INVALID_HANDLE, "unknown handle rc=0x%x", rc);
  rc = call(shim_scePadGetControllerInformation, (uint64_t)handle, 0, 0);
  CHECK(rc == ORBIS_PAD_ERROR_INVALID_ARG, "NULL info rc=0x%x", rc);
}

// Polls the pad like the game until `ms` has passed. Returns the buttons seen and records when
// the first screenshot request appeared (the test clears it, as the renderer does).
static uint32_t poll_for(int32_t handle, double ms, double t0, double *shot_at, int *shots) {
  uint32_t seen = 0;
  double end = now_ms() + ms;
  while (now_ms() < end) {
    OrbisPadData d;
    scePadReadState(handle, &d);
    seen |= d.buttons;
    if (g_ps4_screenshot_request) {
      g_ps4_screenshot_request = 0;
      if (*shots == 0) *shot_at = now_ms() - t0;
      (*shots)++;
    }
    usleep(1000);
  }
  return seen;
}

static void test_control_file(int32_t handle, const char *path) {
  OrbisPadData d;
  scePadReadState(handle, &d); // opens the control file at its end
  FILE *f = fopen(path, "a");
  fprintf(f, "w 150\nshot\np 4000 100\nclose\n");
  fclose(f);
  const double t0 = now_ms();
  double shot_at = -1;
  int shots = 0;
  uint32_t early = poll_for(handle, 100, t0, &shot_at, &shots);
  CHECK(shots == 0, "\"shot\" ran %.0f ms after it was read, before the 150 ms wait ended", shot_at);
  CHECK(early == 0, "buttons 0x%x during the wait", early);
  uint32_t later = poll_for(handle, 250, t0, &shot_at, &shots);
  CHECK(shots == 1, "%d screenshot requests", shots);
  CHECK(shot_at >= 140, "screenshot requested at %.0f ms", shot_at);
  CHECK(later & ORBIS_PAD_BUTTON_CROSS, "Cross was not held after the wait");
  CHECK(g_close_requests == 1, "close ran %d times after the hold", g_close_requests);
  scePadReadState(handle, &d);
  CHECK(d.buttons == 0, "buttons 0x%x after the script", d.buttons);
}

int main(void) {
  char path[] = "/tmp/pad_test_ctl.XXXXXX";
  int fd = mkstemp(path);
  if (fd < 0) return 1;
  close(fd);
  setenv("PS4_PAD_CTL", path, 1);
  setenv("PS4_BACKGROUND_WINDOW", "1", 1); // no host gamepad input during the test
  g_ctx.mem_base = g_mem;
  g_ctx.mem_size = MEM_SIZE;

  CHECK(scePadInit() == 0, "init");
  int32_t handle = scePadOpen(0x10000000, 0, 0, NULL);
  CHECK(handle > 0, "open %d", handle);
  test_controller_information(handle);
  test_control_file(handle, path);
  unlink(path);
  if (g_failures) {
    printf("pad_test: %d FAILED\n", g_failures);
    return 1;
  }
  printf("pad_test: PASS\n");
  return 0;
}
