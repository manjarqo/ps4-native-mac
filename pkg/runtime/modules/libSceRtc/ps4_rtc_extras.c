// libSceRtc: sceRtcFormatRFC2822 and sceRtcTickAddSeconds.
//
// The rest of this module stores ticks as microseconds since the Unix epoch,
// while real PS4 ticks count microseconds since 0001-01-01. Formatting accepts
// both: values at or beyond the 1970 offset in PS4 ticks are converted.
#include "ps4_rtc.h"
#include <stdio.h>
#include <string.h>
#include <sys/time.h>
#include <time.h>

#define ORBIS_RTC_ERROR_INVALID_POINTER ((int32_t)0x80B50002)
#define ORBIS_RTC_ERROR_INVALID_VALUE   ((int32_t)0x80B50003)

#define RTC_UNIX_EPOCH_PS4_TICKS 62135596800000000ULL // 0001-01-01 -> 1970-01-01, in us

static int64_t rtc_tick_to_unix_us(uint64_t tick) {
    if (tick >= RTC_UNIX_EPOCH_PS4_TICKS) return (int64_t)(tick - RTC_UNIX_EPOCH_PS4_TICKS);
    return (int64_t)tick;
}

// int sceRtcFormatRFC2822(char *pszDateTime, const SceRtcTick *pTickUtc, int iTimeZoneMinutes)
// Output: "Fri, 16 Oct 2026 18:13:44 +0300" (null pTickUtc = current time).
int32_t sceRtcFormatRFC2822(char *out, const OrbisRtcTick *tick_utc, int tz_minutes) {
    if (!out) return ORBIS_RTC_ERROR_INVALID_POINTER;
    int64_t us;
    if (tick_utc) {
        us = rtc_tick_to_unix_us(tick_utc->tick);
    } else {
        struct timeval tv;
        gettimeofday(&tv, NULL);
        us = (int64_t)tv.tv_sec * 1000000LL + tv.tv_usec;
    }
    time_t secs = (time_t)(us / 1000000LL) + (time_t)tz_minutes * 60;
    struct tm tm;
    if (!gmtime_r(&secs, &tm)) return ORBIS_RTC_ERROR_INVALID_VALUE;
    static const char *const days[] = {"Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"};
    static const char *const months[] = {"Jan", "Feb", "Mar", "Apr", "May", "Jun",
                                         "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"};
    int tz = tz_minutes;
    char sign = '+';
    if (tz < 0) {
        sign = '-';
        tz = -tz;
    }
    snprintf(out, 32, "%s, %02d %s %04d %02d:%02d:%02d %c%02d%02d",
             days[tm.tm_wday % 7], tm.tm_mday, months[tm.tm_mon % 12], tm.tm_year + 1900,
             tm.tm_hour, tm.tm_min, tm.tm_sec, sign, (tz / 60) % 100, tz % 60);
    return 0;
}

// int sceRtcTickAddSeconds(SceRtcTick *pTick0, const SceRtcTick *pTick1, int64_t lAdd)
int32_t sceRtcTickAddSeconds(OrbisRtcTick *dst, const OrbisRtcTick *src, int64_t add) {
    if (!dst || !src) return ORBIS_RTC_ERROR_INVALID_POINTER;
    dst->tick = src->tick + (uint64_t)(add * 1000000LL);
    return 0;
}

void shim_sceRtcFormatRFC2822(GuestContext *ctx) {
    char *out = ctx->rdi ? (char *)(ctx->mem_base + ctx->rdi) : NULL;
    const OrbisRtcTick *tick = ctx->rsi ? (const OrbisRtcTick *)(ctx->mem_base + ctx->rsi) : NULL;
    ctx->rax = (uint64_t)(int64_t)sceRtcFormatRFC2822(out, tick, (int)(int32_t)ctx->rdx);
    SHIM_RETURN();
}

void shim_sceRtcTickAddSeconds(GuestContext *ctx) {
    OrbisRtcTick *dst = ctx->rdi ? (OrbisRtcTick *)(ctx->mem_base + ctx->rdi) : NULL;
    const OrbisRtcTick *src = ctx->rsi ? (const OrbisRtcTick *)(ctx->mem_base + ctx->rsi) : NULL;
    ctx->rax = (uint64_t)(int64_t)sceRtcTickAddSeconds(dst, src, (int64_t)ctx->rdx);
    SHIM_RETURN();
}
