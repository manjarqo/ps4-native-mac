#!/bin/bash
# TLOU fixed route for the Metal 4 backend work (docs/metal4-backend.md, "Measurements"): the
# walk script (after the autopress phase) from a copy of a save, time-bounded, with a scratch
# data directory and a scratch cache directory, a monitor (WindowServer RSS, load, GPU errors,
# other processes' CPU) and a kill by PID on every exit path. Run it under heavy_lock
# (HEAVY_EXCLUSIVE=1 for fps).
# usage: BUILD=<build dir> TAG=<run name> [METAL=3|4] [SECS=300] [DATASRC=<save to copy>]
#        [CACHE=<cache dir>] [OUT=<runs dir>] [EVERY=<screenshot period, flips; 0: no screenshots>]
#        [EVERY_SEC=<screenshot period, whole seconds of wall time from the first flip: sec_<s>.png>]
#        [SCRIPT=<PS4_PAD_SCRIPT file>] [CTL=<PS4_PAD_CTL program>] [LOAD_WAIT_S=<s, default 240>]
#        tools/metal4_route.sh [env...]
# CTL: a program of PS4_PAD_CTL commands (a camera turn on the right stick, which the pad script
# cannot hold) appended to the run's control file once the log shows "[pad] script started": the
# game reads that file from its end at the first pad read, so the program is timed from the pad
# script's first step. Without CTL, PS4_PAD_CTL is not set.
set -u
W=$HOME/ps4recomp-work
. "$(cd "$(dirname "$0")" && pwd)/route_guard.sh" # load wait, monitor, watchdog, clean-up
: "${BUILD:?BUILD= required}" "${TAG:?TAG= required}"
SECS=${SECS:-300}
[ "$SECS" -le 300 ] || { echo "metal4_route: SECS must be <= 300"; exit 2; }
if P=$(pgrep -x eboot); then echo "metal4_route: the owner's game runs (pid $P); not starting"; exit 3; fi
OUT=${OUT:-$W/metal4_research/runs}
DATASRC=${DATASRC:-$W/data_ch1}
if [ -n "${CTL:-}" ] && ! [ -r "$CTL" ]; then echo "metal4_route: CTL program $CTL not readable"; exit 2; fi
CACHE=${CACHE:-$W/metal4_research/cache_$TAG}
# EVERY=0: no screenshots (no shots directory; perf A/Bs, which need no images, use this)
SHOTENV=()
if [ "${EVERY:-600}" != 0 ]; then
  mkdir -p "$OUT/shots_$TAG" || exit 1
  rm -f "$OUT/shots_$TAG"/*.png
  SHOTENV=(PS4_SCREENSHOT_DIR="$OUT/shots_$TAG" PS4_SCREENSHOT_EVERY=${EVERY:-600} ${EVERY_SEC:+PS4_SCREENSHOT_EVERY_SEC=$EVERY_SEC})
fi
mkdir -p "$OUT" "$CACHE" || exit 1
D=$(mktemp -d "$W/metal4_research/data_$TAG.XXXXXX") || exit 1
cp -R "$DATASRC"/. "$D"/ || exit 1
LOG=$OUT/$TAG.log; MON=$OUT/$TAG.mon
CTLENV=()
if [ -n "${CTL:-}" ]; then
  : > "$D/pad.ctl" || exit 1
  CTLENV=(PS4_PAD_CTL="$D/pad.ctl")
  CTL_SRC=$CTL; CTL_DST=$D/pad.ctl # appended by route_monitor after the pad script's start marker
fi
route_stamp || exit 1
# waits up to LOAD_WAIT_S (4 minutes) for a 1-minute load below 10, then runs anyway:
# tools/metal4_perf_ab.sh drops a run that ended with load > 15
LOAD_WAIT=${LOAD_WAIT:-$((${LOAD_WAIT_S:-240} / 5))}
route_wait_load
route_ws_init
echo "$TAG start $(date +%T) load $(sysctl -n vm.loadavg) WindowServer rss ${WS0} KB metal ${METAL:-default}" | tee "$MON"
cd "$BUILD" || exit 1
EXE=ps4_app_route_$$
cp ps4_app "$EXE" || exit 1
env PS4RECOMP_DATA_DIR="$D" PS4RECOMP_CACHE_DIR="$CACHE" ${METAL:+PS4_GNM_METAL=$METAL} PS4_UPSCALE=0 PS4_PRO=0 \
  PS4_NO_DIALOGS=1 PS4_RECOMP_HEADLESS=1 PS4_BACKGROUND_WINDOW=1 PS4_LANG=ru PS4_PAD_AUTOPRESS=4000 \
  PS4_PAD_AUTOPRESS_UNTIL=90000 "PS4_PAD_SCRIPT=$(cat "${SCRIPT:-$W/walk_script.txt}")" \
  ${SHOTENV[@]+"${SHOTENV[@]}"} ${CTLENV[@]+"${CTLENV[@]}"} "$@" ./"$EXE" > "$LOG" 2>&1 &
GP=$!
cleanup() {
  route_cleanup
  rm -f "$BUILD/$EXE"
  case "$D" in "$W"/metal4_research/data_*) rm -rf "$D" ;; esac
}
route_watchdog
trap cleanup EXIT
trap 'exit 1' INT TERM HUP
route_monitor
cleanup
trap - EXIT
route_stop_line
