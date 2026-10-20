// Host test of sceRtcSetTime_t and sceRtcFormatRFC3339LocalTime (ps4_rtc_extras.c):
// known dates, the calendar edges (leap day, year 9999), both SDK behaviours of time_t,
// a round trip over the whole range against the C library's timegm, and the local-time
// formatting under several host time zones (including a half-hour zone and DST), checked by
// parsing the text back to the original instant.
#include "ps4_rtc.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

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

#define INVALID_POINTER ((int32_t)0x80B50002)
#define INVALID_VALUE ((int32_t)0x80B50003)
#define SDK_NEW 0x04008061u
#define SDK_OLD 0x02000000u

static int same(const OrbisDateTime *d, int y, int mo, int day, int h, int mi, int s) {
  return d->year == y && d->month == mo && d->day == day && d->hour == h && d->minute == mi && d->second == s &&
         d->microsecond == 0;
}

static void test_set_time_t(void) {
  OrbisDateTime d;
  memset(&d, 0xAA, sizeof(d));
  CHECK(sceRtcSetTime_t(&d, 0, SDK_NEW) == 0 && same(&d, 1970, 1, 1, 0, 0, 0), "epoch");
  CHECK(sceRtcSetTime_t(&d, 951782400, SDK_NEW) == 0 && same(&d, 2000, 2, 29, 0, 0, 0), "leap day 2000");
  CHECK(sceRtcSetTime_t(&d, 1000000000, SDK_NEW) == 0 && same(&d, 2001, 9, 9, 1, 46, 40), "1e9");
  CHECK(sceRtcSetTime_t(&d, 1792413296, SDK_NEW) == 0 && same(&d, 2026, 10, 19, 12, 34, 56), "2026-10-19");
  CHECK(sceRtcSetTime_t(&d, 2147483648LL, SDK_NEW) == 0 && same(&d, 2038, 1, 19, 3, 14, 8), "past 2038");
  CHECK(sceRtcSetTime_t(&d, 253402300799LL, SDK_NEW) == 0 && same(&d, 9999, 12, 31, 23, 59, 59), "last second of 9999");
  CHECK(sceRtcSetTime_t(&d, 253402300800LL, SDK_NEW) == INVALID_VALUE, "year 10000");
  CHECK(sceRtcSetTime_t(&d, -1, SDK_NEW) == INVALID_VALUE, "negative time, new SDK");
  CHECK(sceRtcSetTime_t(NULL, 0, SDK_NEW) == INVALID_POINTER, "NULL output");
  CHECK(sceRtcSetTime_t(NULL, -1, SDK_OLD) == INVALID_POINTER, "NULL output, old SDK");
  // Old SDKs take the low 32 bits: -1 is 0xffffffff = 2106-02-07 06:28:15.
  CHECK(sceRtcSetTime_t(&d, -1, SDK_OLD) == 0 && same(&d, 2106, 2, 7, 6, 28, 15), "negative time, old SDK");
  CHECK(sceRtcSetTime_t(&d, 0x100000000LL + 5, SDK_OLD) == 0 && same(&d, 1970, 1, 1, 0, 0, 5), "high bits dropped, old SDK");

  // Round trip against timegm over the whole range; the stride is odd so hours, minutes and
  // days of the week all vary.
  long bad = 0, n = 0;
  for (int64_t t = 0; t <= 253402300799LL; t += 7919117) {
    OrbisDateTime x;
    if (sceRtcSetTime_t(&x, t, SDK_NEW) != 0) { bad++; continue; }
    struct tm tm;
    memset(&tm, 0, sizeof(tm));
    tm.tm_year = x.year - 1900;
    tm.tm_mon = x.month - 1;
    tm.tm_mday = x.day;
    tm.tm_hour = x.hour;
    tm.tm_min = x.minute;
    tm.tm_sec = x.second;
    if ((int64_t)timegm(&tm) != t) bad++;
    n++;
  }
  CHECK(bad == 0 && n > 30000, "round trip: %ld mismatches in %ld samples", bad, n);
}

// Parses "YYYY-MM-DDTHH:MM:SS.ff(Z|+HH:MM|-HH:MM)" to a UTC instant in microseconds; -1 on error.
static int64_t parse_rfc3339(const char *s, int *tz_out) {
  int y, mo, d, h, mi, sec, frac;
  char zone[16] = {0};
  if (sscanf(s, "%d-%d-%dT%d:%d:%d.%2d%15s", &y, &mo, &d, &h, &mi, &sec, &frac, zone) != 8) return -1;
  int tz = 0;
  if (zone[0] != 'Z') {
    int th, tm_;
    if (sscanf(zone + 1, "%d:%d", &th, &tm_) != 2) return -1;
    tz = (th * 60 + tm_) * (zone[0] == '-' ? -1 : 1);
  } else if (zone[1] != 0) {
    return -1;
  }
  struct tm tm;
  memset(&tm, 0, sizeof(tm));
  tm.tm_year = y - 1900;
  tm.tm_mon = mo - 1;
  tm.tm_mday = d;
  tm.tm_hour = h;
  tm.tm_min = mi;
  tm.tm_sec = sec;
  *tz_out = tz;
  return ((int64_t)timegm(&tm) - (int64_t)tz * 60) * 1000000LL + (int64_t)frac * 10000;
}

static void check_zone(const char *tzname, int64_t unix_us, const char *want) {
  setenv("TZ", tzname, 1);
  tzset();
  OrbisRtcTick tick = {(uint64_t)unix_us};
  char buf[64];
  memset(buf, 'x', sizeof(buf));
  CHECK(sceRtcFormatRFC3339LocalTime(buf, &tick) == 0, "%s: result", tzname);
  CHECK(strcmp(buf, want) == 0, "%s: got '%s' want '%s'", tzname, buf, want);
  CHECK(buf[strlen(buf) + 1] == 'x', "%s: wrote only the text and its terminator", tzname);
  int tz;
  CHECK(parse_rfc3339(buf, &tz) == unix_us / 10000 * 10000, "%s: text parses back to the instant", tzname);
  // A tick in the PS4 epoch (microseconds since year 1) is the same instant.
  OrbisRtcTick ps4 = {(uint64_t)unix_us + 62135596800000000ULL};
  char buf2[64];
  CHECK(sceRtcFormatRFC3339LocalTime(buf2, &ps4) == 0 && strcmp(buf2, want) == 0, "%s: PS4-epoch tick '%s'", tzname, buf2);
}

static void test_format_local(void) {
  const int64_t t = 1792413296LL * 1000000 + 789012; // 2026-10-19 12:34:56.789012 UTC
  check_zone("UTC", t, "2026-10-19T12:34:56.78Z");
  check_zone("Europe/Moscow", t, "2026-10-19T15:34:56.78+03:00");
  check_zone("Asia/Kolkata", t, "2026-10-19T18:04:56.78+05:30");
  check_zone("America/St_Johns", t, "2026-10-19T10:04:56.78-02:30"); // DST in October
  // Winter and summer in the same zone (DST shift): 2026-01-15 12:00:00 UTC and 2026-07-15 12:00:00 UTC.
  check_zone("America/St_Johns", 1768478400LL * 1000000, "2026-01-15T08:30:00.00-03:30");
  check_zone("America/St_Johns", 1784116800LL * 1000000, "2026-07-15T09:30:00.00-02:30");
  // A day boundary crossed by the zone offset.
  check_zone("Pacific/Auckland", 1798756200LL * 1000000, "2027-01-01T11:30:00.00+13:00"); // 2026-12-31 22:30 UTC

  setenv("TZ", "Europe/Moscow", 1);
  tzset();
  OrbisRtcTick tick = {1792413296ULL * 1000000};
  CHECK(sceRtcFormatRFC3339LocalTime(NULL, &tick) == INVALID_POINTER, "NULL buffer");
  // NULL tick = now: the text parses to an instant within a few seconds of the clock.
  char buf[64];
  CHECK(sceRtcFormatRFC3339LocalTime(buf, NULL) == 0, "now");
  int tz;
  int64_t got = parse_rfc3339(buf, &tz);
  int64_t now = (int64_t)time(NULL) * 1000000;
  CHECK(got > 0 && got > now - 5000000 && got < now + 5000000 && tz == 180, "now parses to %lld (clock %lld), tz %d",
        (long long)got, (long long)now, tz);
  // The shim reads the buffer and the tick from guest memory.
  static uint8_t mem[0x10000];
  GuestContext ctx;
  memset(&ctx, 0, sizeof(ctx));
  ctx.mem_base = mem;
  ctx.mem_size = sizeof(mem);
  *(uint64_t *)(mem + 0x200) = 1792413296ULL * 1000000;
  ctx.rsp = 0x1000;
  ctx.rdi = 0x100;
  ctx.rsi = 0x200;
  shim_sceRtcFormatRFC3339LocalTime(&ctx);
  CHECK(ctx.rax == 0 && strcmp((char *)mem + 0x100, "2026-10-19T15:34:56.00+03:00") == 0 && ctx.rsp == 0x1008, "shim: '%s'",
        (char *)mem + 0x100);
}

static void test_set_time_t_shim(void) {
  static uint8_t mem[0x10000];
  GuestContext ctx;
  memset(&ctx, 0, sizeof(ctx));
  ctx.mem_base = mem;
  ctx.mem_size = sizeof(mem);
  ctx.process_ctx = &ctx;
  ctx.proc_param_addr = 0x4000;
  memcpy(mem + 0x4008, "ORBI", 4);
  *(uint32_t *)(mem + 0x4010) = SDK_NEW;
  OrbisDateTime *out = (OrbisDateTime *)(mem + 0x100);
  ctx.rsp = 0x1000;
  ctx.rdi = 0x100;
  ctx.rsi = (uint64_t)-1;
  shim_sceRtcSetTime_t(&ctx);
  CHECK((int32_t)ctx.rax == INVALID_VALUE && ctx.rsp == 0x1008, "shim, SDK from the process param (new): rax=0x%llx", (unsigned long long)ctx.rax);
  *(uint32_t *)(mem + 0x4010) = SDK_OLD;
  ctx.rsp = 0x1000;
  ctx.rsi = (uint64_t)-1;
  shim_sceRtcSetTime_t(&ctx);
  CHECK(ctx.rax == 0 && same(out, 2106, 2, 7, 6, 28, 15), "shim, old SDK takes 32 bits");
  ctx.rsp = 0x1000;
  ctx.rdi = 0;
  shim_sceRtcSetTime_t(&ctx);
  CHECK((int32_t)ctx.rax == INVALID_POINTER, "shim NULL output");
  // No process param: the current behaviour.
  ctx.proc_param_addr = 0;
  ctx.rsp = 0x1000;
  ctx.rdi = 0x100;
  ctx.rsi = (uint64_t)-1;
  shim_sceRtcSetTime_t(&ctx);
  CHECK((int32_t)ctx.rax == INVALID_VALUE, "shim without process param");
}

int main(void) {
  test_set_time_t();
  test_format_local();
  test_set_time_t_shim();
  fflush(stdout);
  if (g_failures) {
    printf("rtc_test: %d FAILED\n", g_failures);
    return 1;
  }
  printf("rtc_test: PASS\n");
  return 0;
}
