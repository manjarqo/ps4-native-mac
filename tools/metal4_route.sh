#!/bin/bash
# TLOU fixed route for the Metal 4 backend work (docs/metal4-backend.md, "Measurements"): the
# walk script (after the autopress phase) from a copy of a save, time-bounded, with a scratch
# data directory and a scratch cache directory, a monitor (WindowServer RSS, load, GPU errors,
# other processes' CPU) and a kill by PID on every exit path. Run it under heavy_lock
# (HEAVY_EXCLUSIVE=1 for fps).
# usage: BUILD=<build dir> TAG=<run name> [METAL=3|4] [SECS=300] [DATASRC=<save to copy>]
#        [CACHE=<cache dir>] [OUT=<runs dir>] [EVERY=<screenshot period, flips; 0: no screenshots>]
#        [EVERY_SEC=<screenshot period, whole seconds of wall time from the first flip: sec_<s>.png>]
#        tools/metal4_route.sh [env...]
set -u
W=$HOME/ps4recomp-work
: "${BUILD:?BUILD= required}" "${TAG:?TAG= required}"
SECS=${SECS:-300}
[ "$SECS" -le 300 ] || { echo "metal4_route: SECS must be <= 300"; exit 2; }
if P=$(pgrep -x eboot); then echo "metal4_route: the owner's game runs (pid $P); not starting"; exit 3; fi
OUT=${OUT:-$W/metal4_research/runs}
DATASRC=${DATASRC:-$W/data_ch1}
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
# the system's GPU event reports (gpuEvent-*.ips, written when Metal blames this process for a GPU
# fault or hang) made during the run are copied next to the log: cleaners may delete the originals
STAMP=$(mktemp "${TMPDIR:-/tmp}/metal4_route.XXXXXX") || exit 1
# waits up to 4 minutes for a 1-minute load below 10, then runs anyway: tools/metal4_perf_ab.sh
# drops a run that ended with load > 15
for ((w = 0; w < 48; w++)); do awk "BEGIN{exit !($(sysctl -n vm.loadavg | awk '{print $2}') < 10)}" && break; sleep 5; done
WS=$(pgrep -x WindowServer | head -1)
WS0=$(ps -o rss= -p "$WS" | tr -d ' ')
echo "$TAG start $(date +%T) load $(sysctl -n vm.loadavg) WindowServer rss ${WS0} KB metal ${METAL:-default}" | tee "$MON"
cd "$BUILD" || exit 1
EXE=ps4_app_route_$$
cp ps4_app "$EXE" || exit 1
env PS4RECOMP_DATA_DIR="$D" PS4RECOMP_CACHE_DIR="$CACHE" ${METAL:+PS4_GNM_METAL=$METAL} PS4_UPSCALE=0 PS4_PRO=0 \
  PS4_NO_DIALOGS=1 PS4_RECOMP_HEADLESS=1 PS4_BACKGROUND_WINDOW=1 PS4_LANG=ru PS4_PAD_AUTOPRESS=4000 \
  PS4_PAD_AUTOPRESS_UNTIL=90000 "PS4_PAD_SCRIPT=$(cat "${SCRIPT:-$W/walk_script.txt}")" \
  ${SHOTENV[@]+"${SHOTENV[@]}"} "$@" ./"$EXE" > "$LOG" 2>&1 &
GP=$!
cleanup() {
  kill -TERM $GP 2>/dev/null; sleep 2; kill -9 $GP 2>/dev/null; wait $GP 2>/dev/null
  kill "$WD" 2>/dev/null
  kill -0 $GP 2>/dev/null && echo "WARNING: game $GP still alive" | tee -a "$MON"
  rm -f "$BUILD/$EXE"
  case "$D" in "$W"/metal4_research/data_*) rm -rf "$D" ;; esac
  local r
  while IFS= read -r r; do
    cp "$r" "$OUT/${TAG}_$(basename "$r")" && echo "GPU event report: $OUT/${TAG}_$(basename "$r")" | tee -a "$MON"
  done < <(find /Library/Logs/DiagnosticReports "$HOME/Library/Logs/DiagnosticReports" -maxdepth 1 \
             -name 'gpuEvent-ps4_app*' -newer "$STAMP" 2>/dev/null)
  rm -f "${STAMP:?}"
}
( sleep $((SECS + 30)); kill -9 $GP 2>/dev/null ) &
WD=$!
trap cleanup EXIT
trap 'exit 1' INT TERM HUP
why="time limit"
for ((t = 0; t < SECS; t += 5)); do
  sleep 5
  kill -0 $GP 2>/dev/null || { why="exited"; break; }
  read -r rss cpu < <(ps -o rss=,%cpu= -p "$WS")
  l1=$(sysctl -n vm.loadavg | awk '{print $2}')
  g=$(grep -cE "command buffer .*failed|GPU hang report|GPU watchdog" "$LOG")
  ocpu=$(ps -Ao pid=,pcpu= | awk -v g=$GP '$1 != g {o += $2} END {printf "%.0f", o}')
  echo "t=$t ws_rss=$rss ws_cpu=$cpu load=$l1 gpu_err=$g other_cpu=$ocpu" >> "$MON"
  if [ $((rss - WS0)) -gt 307200 ]; then why="WindowServer RSS +$(((rss - WS0) / 1024)) MB"; break; fi
  if awk "BEGIN{exit !($l1 > 20)}"; then why="load $l1"; break; fi
  if [ "$g" -ge 2 ]; then why="GPU errors $g"; break; fi
done
cleanup
trap - EXIT
echo "$TAG stop $(date +%T) ($why) load $(sysctl -n vm.loadavg) WindowServer rss $(ps -o rss= -p "$WS" | tr -d ' ') KB" | tee -a "$MON"
