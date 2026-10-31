// Host test of libScePad on the real ps4_pad.m:
//  - scePadGetControllerInformation through the guest ABI, as Uncharted 4 calls it: it fills
//    exactly the 28-byte ScePadControllerInformation (one connected local pad, connectedCount
//    equal to the pad data's), writes nothing past it, and rejects unknown handles.
//  - PS4_PAD_CTL: actions such as "shot" run in file order, after the waits and holds before them.
//  - PS4_PAD_CTL "t": touch points in the pad data (ScePadTouchData at 0x34), a finger sliding in a
//    straight line, two fingers with buttons, ids kept while a finger stays down and new after a
//    release, a malformed touch line ignored, no touch after the commands.
//  - Motion sensors: the four motion state calls keep per-handle state; the sensor is on after
//    scePadOpen; a pad with no motion device reads as a DualShock 4 at rest (unit quaternion, +1 g on y); a scripted
//    PS4_PAD_SCRIPT tilt turns the virtual pad (orientation, gravity and angular velocity follow);
//    the deadband zeroes slow rates; tilt correction pulls the orientation to gravity;
//    ResetOrientation makes the current pose the identity; a sensor that is off reads as off.
#import <Foundation/Foundation.h>

#include "ps4_pad.h"

#include <math.h>
#include <stddef.h>
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

static void test_touch(int32_t handle, const char *path) {
  CHECK(offsetof(OrbisPadData, touch) == 0x34, "touch data at 0x%zx", offsetof(OrbisPadData, touch));
  OrbisPadData d;
  scePadReadState(handle, &d);
  CHECK(d.touch.fingers == 0, "%u fingers before any touch command", d.touch.fingers);
  FILE *f = fopen(path, "a");
  // One finger slides from (100, 200) to (300, 400) over 200 ms; then it stays at (10, 20) with a
  // second finger at (1900, 900) and R2 held; a malformed line; a wait; a new touch.
  fprintf(f, "t 0 200 100 200 300 400\nt 200 150 10 20 10 20 1900 900 1900 900\nt 0 100 5 5\nw 50\nt 0 100 7 8 7 8\n");
  fclose(f);
  const double t0 = now_ms();
  int slide_reads = 0, mono = 1, two = 0, r2_with_two = 1;
  int last_x = -1;
  uint8_t id_slide = 0xff, id_a = 0xff, id_b = 0xff, id_new = 0xff;
  int bad_point = 0, gap_touch = 0, late_new = 0;
  while (now_ms() - t0 < 600) {
    scePadReadState(handle, &d);
    const double t = now_ms() - t0;
    if (d.touch.fingers == 1 && t < 190) {
      const int x = d.touch.touch[0].x, y = d.touch.touch[0].y;
      if (x < 100 || x > 300 || y - x != 100) bad_point++;
      if (x < last_x) mono = 0;
      last_x = x;
      slide_reads++;
      id_slide = d.touch.touch[0].finger;
    } else if (d.touch.fingers == 2) {
      two++;
      id_a = d.touch.touch[0].finger;
      id_b = d.touch.touch[1].finger;
      if (d.touch.touch[0].x != 10 || d.touch.touch[0].y != 20 || d.touch.touch[1].x != 1900 ||
          d.touch.touch[1].y != 900)
        bad_point++;
      if (!(d.buttons & ORBIS_PAD_BUTTON_R2) || d.analogButtons.r2 != 255) r2_with_two = 0;
    } else if (d.touch.fingers == 0 && two && id_new == 0xff) {
      gap_touch++;
    } else if (d.touch.fingers == 1 && two) {
      if (d.touch.touch[0].x != 7 || d.touch.touch[0].y != 8) bad_point++;
      id_new = d.touch.touch[0].finger;
      if (t > 560) late_new++;
    }
    usleep(1000);
  }
  CHECK(slide_reads > 20, "%d reads of the sliding finger", slide_reads);
  CHECK(mono && last_x >= 250, "the finger did not slide right (last x %d)", last_x);
  CHECK(bad_point == 0, "%d reads with a point off its line", bad_point);
  CHECK(two > 20, "%d reads with two fingers", two);
  CHECK(r2_with_two, "R2 not held with the two fingers");
  CHECK(id_a == id_slide, "the finger that stayed down changed its id (%u -> %u)", id_slide, id_a);
  CHECK(id_b != id_a, "both fingers have id %u", id_a);
  CHECK(gap_touch > 10, "no release during the wait (%d reads)", gap_touch);
  CHECK(id_new != 0xff && id_new != id_a && id_new != id_b, "the new touch has id %u (old %u, %u)", id_new, id_a, id_b);
  CHECK(late_new == 0, "the last touch lasted past its 100 ms");
  scePadReadState(handle, &d);
  CHECK(d.touch.fingers == 0, "%u fingers after the commands", d.touch.fingers);
}

// Motion sensors. The script clock is PS4_PAD_CLOCK=frames: flip count f is f*1000/30 ms, so the
// test sets the time exactly. The script (set in main) turns the pad to a 90-degree roll from 1000
// to 1500 ms, then slowly (0.5 degrees per second, below the deadband) to 90.5 degrees from 3000
// to 4000 ms, then at once to roll 90, yaw 30 at 5000 ms; L2 and R2 are pressed at 6000 ms; a shake runs from 7000 to 8000 ms.
static OrbisPadData read_at(int32_t handle, uint64_t frame) {
  g_ps4_videoout_flip_count = frame;
  const uint64_t buf = 0x3000;
  memset(g_mem + buf, 0xCD, sizeof(OrbisPadData));
  int32_t rc = call(shim_scePadReadState, (uint64_t)handle, buf, 0);
  CHECK(rc == 0, "ReadState rc=0x%x", rc);
  OrbisPadData d;
  memcpy(&d, g_mem + buf, sizeof(d));
  return d;
}

static int near(float a, float b, float eps) { return fabsf(a - b) <= eps; }

#define CHECK_QUAT(d, X, Y, Z, W, eps)                                                              \
  CHECK(near((d).quat.x, X, eps) && near((d).quat.y, Y, eps) && near((d).quat.z, Z, eps) &&         \
            near((d).quat.w, W, eps),                                                              \
        "quat (%f %f %f %f), want (%f %f %f %f)", (d).quat.x, (d).quat.y, (d).quat.z, (d).quat.w,   \
        (double)(X), (double)(Y), (double)(Z), (double)(W))
#define CHECK_VEC(v, X, Y, Z, eps)                                                                  \
  CHECK(near((v).x, X, eps) && near((v).y, Y, eps) && near((v).z, Z, eps),                          \
        #v " (%f %f %f), want (%f %f %f)", (v).x, (v).y, (v).z, (double)(X), (double)(Y), (double)(Z))

// Roll angle (about z) of an orientation that is a pure rotation about z, in degrees.
static double roll_deg(const OrbisPadData *d) {
  return 2.0 * atan2(d->quat.z, d->quat.w) * 180.0 / M_PI;
}

static void test_motion(void) {
  // ScePadData layout (SDK, shadPS4 pad.h): orientation, then acceleration, then angular velocity.
  CHECK(offsetof(OrbisPadData, quat) == 0x0C, "orientation at 0x%zx", offsetof(OrbisPadData, quat));
  CHECK(offsetof(OrbisPadData, acell) == 0x1C, "acceleration at 0x%zx", offsetof(OrbisPadData, acell));
  CHECK(offsetof(OrbisPadData, vel) == 0x28, "angular velocity at 0x%zx", offsetof(OrbisPadData, vel));
  // Unknown handles.
  void (*setters[3])(GuestContext *) = {shim_scePadSetMotionSensorState, shim_scePadSetTiltCorrectionState,
                                        shim_scePadSetAngularVelocityDeadbandState};
  for (int i = 0; i < 3; i++) {
    int32_t rc = call(setters[i], 0x7777, 1, 0);
    CHECK(rc == ORBIS_PAD_ERROR_INVALID_HANDLE, "setter %d on an unknown handle rc=0x%x", i, rc);
  }
  int32_t rc = call(shim_scePadResetOrientation, 0x7777, 0, 0);
  CHECK(rc == ORBIS_PAD_ERROR_INVALID_HANDLE, "ResetOrientation on an unknown handle rc=0x%x", rc);

  // h1: deadband on, no tilt correction. h2: deadband and tilt correction. h3: sensor only.
  int32_t h1 = scePadOpen(0x10000001, 0, 0, NULL);
  int32_t h2 = scePadOpen(0x10000002, 0, 0, NULL);
  int32_t h3 = scePadOpen(0x10000003, 0, 0, NULL);
  CHECK(h1 > 0 && h2 > 0 && h3 > 0, "open %d %d %d", h1, h2, h3);

  // The sensor is on after open (inFAMOUS Second Son reads motion without ever calling
  // scePadSetMotionSensorState): a pad at rest, before any other call.
  OrbisPadData d = read_at(h1, 0);
  CHECK_QUAT(d, 0, 0, 0, 1, 1e-6f);
  CHECK_VEC(d.acell, 0, 1, 0, 1e-6f);
  CHECK_VEC(d.vel, 0, 0, 0, 0);

  // Turning it on again changes nothing.
  CHECK(call(shim_scePadSetMotionSensorState, (uint64_t)h1, 1, 0) == 0, "motion on h1");
  CHECK(call(shim_scePadSetAngularVelocityDeadbandState, (uint64_t)h1, 1, 0) == 0, "deadband h1");
  CHECK(call(shim_scePadSetAngularVelocityDeadbandState, (uint64_t)h2, 1, 0) == 0, "deadband h2");
  CHECK(call(shim_scePadSetTiltCorrectionState, (uint64_t)h2, 1, 0) == 0, "tilt h2");

  // At rest (no motion device, script not started): a still pad lying flat.
  for (int h = 0; h < 3; h++) {
    d = read_at(h == 0 ? h1 : h == 1 ? h2 : h3, 3);
    CHECK_QUAT(d, 0, 0, 0, 1, 1e-6f);
    CHECK_VEC(d.acell, 0, 1, 0, 1e-6f);
    CHECK_VEC(d.vel, 0, 0, 0, 0);
  }

  // Mid-turn (1100 ms): the scripted rate of 90 degrees in 500 ms about z.
  const float rate = (float)(M_PI / 2 / 0.5);
  for (uint64_t f = 30; f <= 33; f++) {
    read_at(h1, f);
    read_at(h2, f);
    d = read_at(h3, f);
  }
  CHECK_VEC(d.vel, 0, 0, rate, 1e-4f);
  CHECK(fabs(roll_deg(&d) - 18.0) < 0.01, "roll %f at 1100 ms, want 18", roll_deg(&d));

  // After the turn (1600 ms): held sideways, gravity on x.
  const float s45 = (float)M_SQRT1_2;
  for (int h = 0; h < 3; h++) {
    d = read_at(h == 0 ? h1 : h == 1 ? h2 : h3, 48);
    CHECK_QUAT(d, 0, 0, s45, s45, 1e-4f);
    CHECK_VEC(d.acell, 1, 0, 0, 1e-4f);
    CHECK_VEC(d.vel, 0, 0, 0, 0);
  }

  // The slow turn to 90.5 degrees (3000..4000 ms), read every frame until 4600 ms.
  OrbisPadData d1 = d, d2 = d, d3 = d;
  for (uint64_t f = 49; f <= 138; f++) {
    d1 = read_at(h1, f);
    d2 = read_at(h2, f);
    d3 = read_at(h3, f);
    if (f == 105) { // 3500 ms, mid slow turn
      CHECK(d1.vel.z == 0 && d2.vel.z == 0, "deadband let %g / %g rad/s through", d1.vel.z, d2.vel.z);
      CHECK(near(d3.vel.z, (float)(0.5 * M_PI / 180), 1e-5f), "slow rate %g without deadband", d3.vel.z);
    }
  }
  // Gravity follows the pad on every handle.
  const float c905 = (float)cos(90.5 * M_PI / 180), s905 = (float)sin(90.5 * M_PI / 180);
  CHECK_VEC(d1.acell, s905, c905, 0, 1e-4f);
  CHECK_VEC(d2.acell, s905, c905, 0, 1e-4f);
  // Without deadband the gyro carries the slow turn; with it and no tilt correction the
  // orientation stays at 90; tilt correction pulls it to the measured gravity.
  CHECK(fabs(roll_deg(&d3) - 90.5) < 0.01, "h3 roll %f, want 90.5", roll_deg(&d3));
  CHECK(fabs(roll_deg(&d1) - 90.0) < 0.01, "h1 roll %f, want 90 (deadband, no tilt correction)", roll_deg(&d1));
  CHECK(fabs(roll_deg(&d2) - 90.5) < 0.1, "h2 roll %f, want 90.5 (tilt correction)", roll_deg(&d2));

  // ResetOrientation: the current pose becomes the identity; gravity still points along x.
  CHECK(call(shim_scePadResetOrientation, (uint64_t)h1, 0, 0) == 0, "reset h1");
  d = read_at(h1, 139);
  CHECK_QUAT(d, 0, 0, 0, 1, 1e-6f);
  CHECK_VEC(d.acell, s905, c905, 0, 1e-4f);
  d = read_at(h3, 139);
  CHECK(fabs(roll_deg(&d) - 90.5) < 0.01, "reset of h1 changed h3: roll %f", roll_deg(&d));

  // The sensor off again: the values of a sensor that is off.
  CHECK(call(shim_scePadSetMotionSensorState, (uint64_t)h1, 0, 0) == 0, "motion off h1");
  d = read_at(h1, 140);
  CHECK_QUAT(d, 0, 0, 0, 1, 0);
  CHECK_VEC(d.acell, 0, 0, 0, 0);
  CHECK_VEC(d.vel, 0, 0, 0, 0);

  // Yaw about the top face's normal, turned at once (turn 0) at 5000 ms: roll 90 then yaw 30.
  d = read_at(h3, 150);
  CHECK_VEC(d.acell, (float)cos(M_PI / 6), 0, 0.5f, 1e-4f);

  // The sideways key (H) turns the virtual pad to roll 90 over 300 ms, from wherever it is.
  ps4_pad_handle_key(4, 1);
  d = read_at(h3, 160);
  CHECK_VEC(d.acell, 1, 0, 0, 1e-4f);
  ps4_pad_handle_key(4, 0);
  d = read_at(h3, 170);
  CHECK_VEC(d.acell, 0, 1, 0, 1e-4f);

  // A scripted L2 + R2 press is a fully pulled trigger, as on a pad (6000..6100 ms).
  d = read_at(h3, 181);
  CHECK((d.buttons & (ORBIS_PAD_BUTTON_L2 | ORBIS_PAD_BUTTON_R2)) == (ORBIS_PAD_BUTTON_L2 | ORBIS_PAD_BUTTON_R2),
        "buttons 0x%x", d.buttons);
  CHECK(d.analogButtons.l2 == 255 && d.analogButtons.r2 == 255, "triggers %u %u", d.analogButtons.l2,
        d.analogButtons.r2);
  d = read_at(h3, 190);
  CHECK(d.analogButtons.l2 == 0 && d.analogButtons.r2 == 0, "triggers %u %u after the press",
        d.analogButtons.l2, d.analogButtons.r2);

  // A scripted shake (7000..8000 ms, 1 g at 5 Hz along the vertical) adds linear acceleration on
  // top of gravity; the pad lies flat again after the H key was released.
  d = read_at(h3, 211); // 7033 ms: sin(2 pi 5 0.0333) = 0.866
  CHECK_VEC(d.acell, 0, 1.866f, 0, 2e-3f);
  CHECK_VEC(d.vel, 0, 0, 0, 0);
  d = read_at(h3, 250); // after the shake
  CHECK_VEC(d.acell, 0, 1, 0, 1e-4f);
  // The N key shakes the pad while it is held.
  ps4_pad_handle_key(45, 1);
  int moved = 0;
  for (uint64_t f = 251; f < 260; f++) {
    d = read_at(h3, f);
    moved |= fabsf(d.acell.y - 1) > 0.1f;
  }
  CHECK(moved, "the N key did not shake the pad");
  ps4_pad_handle_key(45, 0);
  d = read_at(h3, 261);
  CHECK_VEC(d.acell, 0, 1, 0, 1e-4f);

  scePadClose(h1);
  scePadClose(h2);
  scePadClose(h3);
}

// "clock" mode (a process of its own, wall clock): PS4_PAD_SCRIPT times count from the first pad
// read, not from scePadOpen, so existing routes keep their timing.
static int clock_main(void) {
  setenv("PS4_BACKGROUND_WINDOW", "1", 1);
  setenv("PS4_PAD_SCRIPT", "250:4000:200", 1); // Cross from 250 to 450 ms
  CHECK(scePadInit() == 0, "init");
  int32_t h = scePadOpen(0x10000000, 0, 0, NULL);
  usleep(400 * 1000);
  OrbisPadData d;
  scePadReadState(h, &d);
  CHECK(!(d.buttons & ORBIS_PAD_BUTTON_CROSS), "Cross at the first read, 400 ms after open: the script clock started at open");
  const double t0 = now_ms();
  uint32_t seen = 0;
  while (now_ms() - t0 < 350) {
    scePadReadState(h, &d);
    seen |= d.buttons;
    usleep(1000);
  }
  CHECK(seen & ORBIS_PAD_BUTTON_CROSS, "no Cross within 350 ms of the first read");
  if (g_failures) {
    printf("pad_test clock: %d FAILED\n", g_failures);
    return 1;
  }
  printf("pad_test clock: PASS\n");
  return 0;
}

int main(int argc, char **argv) {
  if (argc > 1 && strcmp(argv[1], "clock") == 0) return clock_main();
  char path[] = "/tmp/pad_test_ctl.XXXXXX";
  int fd = mkstemp(path);
  if (fd < 0) return 1;
  close(fd);
  setenv("PS4_PAD_CTL", path, 1);
  setenv("PS4_BACKGROUND_WINDOW", "1", 1); // no host gamepad input during the test
  setenv("PS4_PAD_CLOCK", "frames", 1);
  setenv("PS4_PAD_SCRIPT", "1000:tilt:90:0:0:500,3000:tilt:90.5:0:0:1000,5000:tilt:90:0:30:0,6000:300:100,7000:shake:1:1000:5", 1);
  g_ctx.mem_base = g_mem;
  g_ctx.mem_size = MEM_SIZE;

  CHECK(scePadInit() == 0, "init");
  test_motion();
  int32_t handle = scePadOpen(0x10000000, 0, 0, NULL);
  CHECK(handle > 0, "open %d", handle);
  test_controller_information(handle);
  test_control_file(handle, path);
  test_touch(handle, path);
  unlink(path);
  if (g_failures) {
    printf("pad_test: %d FAILED\n", g_failures);
    return 1;
  }
  printf("pad_test: PASS\n");
  return 0;
}
