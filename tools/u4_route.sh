#!/bin/bash
# Uncharted 4 fixed route for the performance work (U4 gate runs, A/B): a build's ps4_app run
# with a scratch data directory and a scratch cache directory, a frame-clocked pad script, time
# bounded, with a monitor (WindowServer RSS, load, GPU errors, other processes' CPU) and a kill by
# PID on every exit path. Built like tools/metal4_route.sh; run it under heavy_lock (HEAVY_EXCLUSIVE=1
# for fps), or as the ROUTE= program of tools/metal4_perf_ab.sh (which takes the lock itself).
#
# usage: PS4_U4_APP_DIR=<game folder> BUILD=<u4 build dir> ROUTE_KIND=title|boat TAG=<run name>
#        [SECS=300] [SHOTS="1500 2400 4500 5400"] [EVERY=<flips>] [CACHE=<dir>] [OUT=<runs dir>]
#        [METAL=3|4] [DATASRC=<save fixture to copy>] tools/u4_route.sh [ENV=VAL...]
#   ROUTE_KIND (or ROUTE=title|boat): title presses nothing; boat plays tools/u4_route_pad.txt.
#   PS4_U4_APP_DIR: the game folder, handed to the game as PS4_APP_DIR (never written into the repo).
#   SHOTS: the screenshots to keep, as flip numbers, saved as $OUT/shots_$TAG/frame_<n>.png (the run
#     saves every gcd(SHOTS)-th flip and the others are deleted afterwards). EVERY=0: no screenshots
#     (perf runs); EVERY=<n>: every n-th flip, all kept.
#   The ENV=VAL arguments are added to the game's environment last, so they win.
# Output: $OUT/$TAG.log (the game's output), $OUT/$TAG.mon (the monitor), $OUT/$TAG.guard (only when
# a guard stopped the run: the reason), the system's GPU event reports as $OUT/${TAG}_gpuEvent-*.ips.
# Exit status: 0 the run ended by itself or at the time limit, 1 bad usage or setup, 2 a guard killed
# the run, 3 the owner's game is running (not started).
# Guards: a 1-minute load below 10 before the start (waits up to LOAD_WAIT=48 x 5 s, then runs anyway
# and the monitor line says so; metal4_perf_ab.sh drops runs that end with load > 15), kill when
# WindowServer's RSS grows by more than 300 MB, when the load is above 20, or after MAXGPUERR=2 GPU
# error lines, a hard kill of the game's PID at SECS+30 s, SECS <= 300. Only the game's own PID is
# ever signalled. TICK=5 is the monitor period in seconds.
set -u
W=$HOME/ps4recomp-work
HERE=$(cd "$(dirname "$0")" && pwd)
. "$HERE/route_guard.sh"
: "${BUILD:?BUILD= required}" "${TAG:?TAG= required}"
# under metal4_perf_ab.sh ROUTE is the program path: only title|boat are kinds
KIND=${ROUTE_KIND:-}
if [ -z "$KIND" ]; then case ${ROUTE:-} in title | boat) KIND=$ROUTE ;; esac; fi
case $KIND in title | boat) ;; *) echo "u4_route: ROUTE_KIND=title|boat required (got '${KIND}')" >&2; exit 1 ;; esac
if [ -z "${PS4_U4_APP_DIR:-}" ]; then
  echo "u4_route: PS4_U4_APP_DIR is not set: export it as the Uncharted 4 game folder (the one that holds eboot.bin)" >&2
  exit 1
fi
[ -d "$PS4_U4_APP_DIR" ] || { echo "u4_route: PS4_U4_APP_DIR is not a directory" >&2; exit 1; }
SECS=${SECS:-300}
[ "$SECS" -le 300 ] || { echo "u4_route: SECS must be <= 300" >&2; exit 1; }
[ -x "$BUILD/ps4_app" ] || { echo "u4_route: $BUILD/ps4_app not found" >&2; exit 1; }
if P=$(pgrep -x eboot); then echo "u4_route: the owner's game runs (pid $P); not starting" >&2; exit 3; fi
OUT=${OUT:-$W/u4perf_runs}
mkdir -p "$OUT" || exit 1
CACHE_SCRATCH=
if [ -z "${CACHE:-}" ]; then CACHE=$OUT/cache_$TAG; CACHE_SCRATCH=1; fi
mkdir -p "$CACHE" || exit 1

# pad script: lines "t:mask:hold", comments with #, joined with commas
PAD=
if [ "$KIND" = boat ]; then
  PAD=$(grep -v -e '^[[:space:]]*#' -e '^[[:space:]]*$' "$HERE/u4_route_pad.txt" | tr -d ' \t' | paste -sd, -)
  [ -n "$PAD" ] || { echo "u4_route: $HERE/u4_route_pad.txt has no steps" >&2; exit 1; }
fi

# screenshots
SHOTENV=(); KEEP=(); SHOTDIR=$OUT/shots_$TAG
rm -f "$SHOTDIR"/*.png # the shots of an earlier run with this tag
gcd() { local a=$1 b=$2 t; while [ "$b" -ne 0 ]; do t=$((a % b)); a=$b; b=$t; done; echo "$a"; }
if [ "${EVERY:-}" != 0 ]; then
  STEP=${EVERY:-}
  if [ -z "$STEP" ]; then
    STEP=0
    for n in ${SHOTS-1500 2400 4500 5400}; do
      case $n in '' | *[!0-9]* | 0) echo "u4_route: SHOTS entries must be positive flip numbers (got '$n')" >&2; exit 1 ;; esac
      STEP=$(gcd "$STEP" "$n"); KEEP+=("$n")
    done
  fi
  if [ "$STEP" -gt 0 ]; then
    mkdir -p "$SHOTDIR" || exit 1
    SHOTENV=(PS4_SCREENSHOT_DIR="$SHOTDIR" PS4_SCREENSHOT_EVERY="$STEP")
  fi
fi

D=$(mktemp -d "$OUT/data_$TAG.XXXXXX") || exit 1
if [ -n "${DATASRC:-}" ]; then cp -R "$DATASRC"/. "$D"/ || { rm -rf "$D"; exit 1; }; fi
LOG=$OUT/$TAG.log; MON=$OUT/$TAG.mon; GUARD_FILE=$OUT/$TAG.guard
rm -f "$GUARD_FILE"
route_stamp || exit 1
route_wait_load
route_ws_init
echo "$TAG start $(date +%T) load $(sysctl -n vm.loadavg) WindowServer rss ${WS0} KB route $KIND metal ${METAL:-default}$LATE" | tee "$MON"
cd "$BUILD" || exit 1
EXE=ps4_app_route_$$
cp ps4_app "$EXE" || exit 1
env PS4RECOMP_DATA_DIR="$D" PS4RECOMP_CACHE_DIR="$CACHE" PS4_APP_DIR="$PS4_U4_APP_DIR" ${METAL:+PS4_GNM_METAL=$METAL} \
  PS4_UPSCALE=0 PS4_PRO=0 PS4_NO_DIALOGS=1 PS4_RECOMP_HEADLESS=1 PS4_BACKGROUND_WINDOW=1 PS4_PAD_AUTOPRESS=0 \
  ${PAD:+PS4_PAD_CLOCK=frames "PS4_PAD_SCRIPT=$PAD"} \
  ${SHOTENV[@]+"${SHOTENV[@]}"} "$@" ./"$EXE" > "$LOG" 2>&1 &
GP=$!
cleanup() {
  route_cleanup
  rm -f "$BUILD/$EXE"
  case "$D" in "$OUT"/data_*) rm -rf "$D" ;; esac
  [ -z "$CACHE_SCRATCH" ] || case "$CACHE" in "$OUT"/cache_*) rm -rf "$CACHE" ;; esac
  # keep only the wanted screenshots
  if [ ${#KEEP[@]} -gt 0 ]; then
    local f n k keep miss=
    for f in "$SHOTDIR"/frame_*.png; do
      [ -e "$f" ] || continue
      n=$((10#$(basename "$f" .png | sed 's/^frame_//'))); keep=
      for k in "${KEEP[@]}"; do [ "$k" -eq "$n" ] && keep=1; done
      [ -n "$keep" ] || rm -f "$f"
    done
    for k in "${KEEP[@]}"; do [ -e "$SHOTDIR/$(printf 'frame_%06d.png' "$k")" ] || miss="$miss $k"; done
    [ -z "$miss" ] || echo "screenshots missing for flips:$miss" | tee -a "$MON"
  fi
}
route_watchdog
trap cleanup EXIT
trap 'exit 1' INT TERM HUP
route_monitor
[ -z "$GUARD" ] || { echo "$GUARD" > "$GUARD_FILE"; WHY="guard: $GUARD"; }
cleanup
trap - EXIT
route_stop_line
[ -z "$GUARD" ] || exit 2
exit 0
