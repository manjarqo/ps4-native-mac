#!/bin/bash
# Alternating A/B of the TLOU route (docs/metal4-backend.md, "Measurements"). A and B are
# <build dir>:<3|4>; runs pairs A, B, A, B, ... under HEAVY_EXCLUSIVE=1 heavy_lock, each with the
# same warm cache directory per side, after one warm-up run per side (not counted).
#
# A pair is kept only if both runs are: a run is dropped when its load field is empty or above 15
# (checked first), or when its monitor shows other processes above 350 % CPU in more than two
# samples (a compile or another game: 300 % and more for its whole length). A kept pair's two
# runs must also have seen the same background: the medians of their monitors' other_cpu (the
# CPU of every other process, WindowServer and the agents' apps included; 45-55 on an idle
# machine, 90-240 while other agents work, which costs TLOU about 3 fps and 0.5 ms of encoder)
# differ by at most PAIR_MARGIN (default 40); otherwise the pair is repeated, as alternation
# cancels a background only when both runs of a pair share it. At most 2*N pairs are tried, and
# trying stops once N kept pairs can no longer be reached.
#
# Runs take no screenshots (EVERY=0, which also ignores EVERY_SEC) unless EVERY= is given: their
# absolute fps is not comparable with runs that took screenshots (every 600 flips by default),
# the A/B verdict is (both sides alike). Prints every run (stderr: the report line, the other_cpu
# median and spikes), the kept and dropped runs with their logs, the other_cpu medians of the
# kept runs, and the verdict of tools/metal4_route_report.py --verdict over the kept logs
# (medians of fps, encoder ms and CP ms per side, the B-vs-A line). Exit status: that of
# --verdict (0: B >= A), 1 when fewer than N pairs were kept. After every run it sleeps PAUSE s
# (default 60) outside the lock, so that other agents' jobs waiting for a slot get a window.
# NEVER run this script under heavy_lock.sh: it takes the lock for every run itself, and an outer
# exclusive lock blocks the inner one for ever (a deadlock that also stalls every other agent).
# A= and B= split a trailing ":3" or ":4" off as the Metal backend (PS4_GNM_METAL); anything else
# is the plain build directory.
# Each side's cache directory is $OUT/cache_<TAG>_A or _B (scratch, outside ~/Library/Caches): shared
# by that side's warm-up run and counted runs within this one invocation, and deleted when the
# script ends, whatever the exit path.
# usage: N=5 A=<build>:<3|4> B=<build>:<3|4> TAG=<name> [SECS=300] [PAIR_MARGIN=40] tools/metal4_perf_ab.sh [VAR=value...]
#        (trailing arguments go to every route run after its own settings, so
#        PS4_UPSCALE=metalfx overrides the route's PS4_UPSCALE=0 on both sides)
#        SUMMARY_ONLY=1 KEPT_A="<tag>..." KEPT_B="<tag>..." TAG=<name> N=<n> tools/metal4_perf_ab.sh
#        (no runs: the same summary over the logs of runs already made)
# REPORT_ARGS="<options>" go to every metal4_route_report.py call, the verdict included
# (REPORT_ARGS=--after-marker for routes whose boot has a varying number of perf lines: inFAMOUS).
# --after-marker and --skip in REPORT_ARGS are refused (exit status 2, before any run) together with
# ROUTE_KIND, FROM or TO, which select the perf windows by present index.
# Tests (tools/tests/test_metal4_perf_ab.py): ROUTE=<program> replaces the heavy_lock'ed
# metal4_route.sh (it gets BUILD, TAG, METAL, SECS, CACHE, EVERY, OUT and ROUTE_KIND in the
# environment and writes $OUT/$TAG.log and $OUT/$TAG.mon); OUT= is the runs directory.
#
# Uncharted 4: tools/u4_route.sh is a ROUTE program (it needs PS4_U4_APP_DIR=<game folder>):
#   N=3 A=<build> B=<build> TAG=<name> ROUTE=tools/u4_route.sh ROUTE_KIND=title|boat \
#     [FROM=<present>] [TO=<present>] tools/metal4_perf_ab.sh
# A and B may be plain build directories ("<build>" without ":<3|4>": no PS4_GNM_METAL is set).
# ROUTE_KIND is passed on to the route and makes a ROUTE run like the built-in one: under
# HEAVY_EXCLUSIVE=1 heavy_lock (HEAVY_LOCK= names another lock program, for tests). ROUTE_KIND, FROM
# or TO also switch the report lines and the verdict to the perf windows selected by present index
# (tools/metal4_route_report.py --from/--to; FROM defaults to 0, TO to the end of the log) instead
# of skipping the first 13 windows, and the verdict ends with the
# "VERDICT: B faster|slower|within noise" line.
set -u
: "${TAG:?}"
[ -n "${SUMMARY_ONLY:-}" ] || : "${A:?} ${B:?}"
EXTRA=("$@")
read -ra RARGS <<< "${REPORT_ARGS:-}"
N=${N:-5}; SECS=${SECS:-300}; PAUSE=${PAUSE:-60}; PAIR_MARGIN=${PAIR_MARGIN:-40}
R=$(cd "$(dirname "$0")/.." && pwd)
W=$HOME/ps4recomp-work
OUT=${OUT:-$W/metal4_research/runs}
export OUT
# the scratch caches of the sides (see the header); also removed on interrupt
CACHE_A=$OUT/cache_${TAG}_A; CACHE_B=$OUT/cache_${TAG}_B
cleanup_caches() { rm -rf "${CACHE_A:?}" "${CACHE_B:?}"; }
if [ -z "${SUMMARY_ONLY:-}" ]; then trap cleanup_caches EXIT; trap 'exit 1' INT TERM HUP; fi
HEAVY_LOCK=${HEAVY_LOCK:-$W/tools/heavy_lock.sh}
RANGE=()
if [ -n "${ROUTE_KIND:-}${FROM:-}${TO:-}" ]; then
  RANGE=(--from "${FROM:-0}" --to "${TO:-99999999}")
  # the report refuses to select perf lines both by position and by present index: every run's report
  # would fail, so refuse before the first run
  for o in ${RARGS[@]+"${RARGS[@]}"}; do
    case $o in --after-marker | --skip | --skip=*)
      echo "metal4_perf_ab: REPORT_ARGS $o selects perf lines by position; ROUTE_KIND, FROM and TO select them by present index: use one" >&2
      exit 2 ;;
    esac
  done
fi
# "<build>:<3|4>", or a plain "<build>" (no Metal version)
build_of() { case $1 in *:[34]) echo "${1%:*}" ;; *) echo "$1" ;; esac; }
metal_of() { case $1 in *:[34]) echo "${1##*:}" ;; *) echo "" ;; esac; }
declare -a TA TB
dropped=()
MED=0 # other_cpu median of the last run_side (run_side runs in this shell)
# other_cpu median of a monitor file (0 without samples)
cpu_median() {
  awk -F'other_cpu=' 'NF > 1 {print $2 + 0}' "$1" | sort -n | awk '{a[NR] = $1} END {print NR ? a[int((NR + 1) / 2)] : 0}'
}
run_side() { # side build metal index: returns 0 for a kept run; the run line goes to stderr
  local side=$1 build=$2 metal=$3 i=$4 tag="${TAG}_$1$4"
  if [ -n "${ROUTE:-}" ]; then
    local lock=()
    [ -n "${ROUTE_KIND:-}" ] && lock=(env HEAVY_EXCLUSIVE=1 "$HEAVY_LOCK")
    ${lock[@]+"${lock[@]}"} env BUILD="$build" TAG="$tag" METAL="$metal" SECS="$SECS" EVERY="${EVERY:-0}" ROUTE_KIND="${ROUTE_KIND:-}" \
      CACHE="$OUT/cache_${TAG}_$side" "$ROUTE" ${EXTRA[@]+"${EXTRA[@]}"} > /dev/null 2>&1
  else
    HEAVY_EXCLUSIVE=1 "$W/tools/heavy_lock.sh" env BUILD="$build" TAG="$tag" METAL="$metal" SECS="$SECS" EVERY="${EVERY:-0}" \
      OUT="$OUT" CACHE="$OUT/cache_${TAG}_$side" "$R/tools/metal4_route.sh" ${EXTRA[@]+"${EXTRA[@]}"} > /dev/null 2>&1
  fi
  sleep "$PAUSE"
  MED=0
  local rep; rep=$(python3 "$R/tools/metal4_route_report.py" ${RARGS[@]+"${RARGS[@]}"} "$OUT/$tag.log" ${RANGE[@]+"${RANGE[@]}"}) || { echo "$tag: no report" >&2; return 1; }
  local load; load=$(awk '{for (i = 1; i < NF; i++) if ($i == "load") print $(i + 1)}' <<< "$rep")
  local busy; busy=$(awk -F'other_cpu=' 'NF > 1 && $2 + 0 > 350 {n++} END {print n + 0}' "$OUT/$tag.mon")
  MED=$(cpu_median "$OUT/$tag.mon")
  echo "$tag: $rep other_cpu median $MED, >350: $busy" >&2
  if [ -z "$load" ] || awk "BEGIN{exit !($load > 15 || $load < 0)}"; then
    echo "$tag: discarded (load '${load:-none}')" >&2; return 1
  fi
  if [ "$busy" -gt 2 ]; then echo "$tag: discarded (other processes busy in $busy samples)" >&2; return 1; fi
  return 0
}
summary() {
  echo "A kept ${#TA[@]}: ${TA[*]:-}"
  echo "B kept ${#TB[@]}: ${TB[*]:-}"
  echo "dropped: ${dropped[*]:-none}"
  local t ma=() mb=()
  for t in ${TA[@]+"${TA[@]}"}; do ma+=("$(cpu_median "$OUT/$t.mon")"); done
  for t in ${TB[@]+"${TB[@]}"}; do mb+=("$(cpu_median "$OUT/$t.mon")"); done
  echo "other_cpu medians: A ${ma[*]:-none}; B ${mb[*]:-none}"
  [ ${#TA[@]} -ge "$N" ] && [ ${#TB[@]} -ge "$N" ] || { echo "metal4_perf_ab: fewer than $N kept runs per side"; return 1; }
  local la=() lb=()
  for t in "${TA[@]}"; do la+=("$OUT/$t.log"); done
  for t in "${TB[@]}"; do lb+=("$OUT/$t.log"); done
  echo "A logs: ${la[*]}"
  echo "B logs: ${lb[*]}"
  python3 "$R/tools/metal4_route_report.py" ${RARGS[@]+"${RARGS[@]}"} --verdict ${RANGE[@]+"${RANGE[@]}"} --min-runs "$N" --a "${la[@]}" --b "${lb[@]}"
}
if [ -n "${SUMMARY_ONLY:-}" ]; then
  read -ra TA <<< "${KEPT_A:?}"; read -ra TB <<< "${KEPT_B:?}"
  summary; exit $?
fi
run_side A "$(build_of "$A")" "$(metal_of "$A")" w; run_side B "$(build_of "$B")" "$(metal_of "$B")" w
kept=0
for ((p = 1; p <= 2 * N && kept < N; p++)); do
  # the pairs left cannot make up N any more: stop
  [ $((kept + 2 * N - p + 1)) -ge "$N" ] || break
  run_side A "$(build_of "$A")" "$(metal_of "$A")" $p; ka=$?; mA=$MED
  run_side B "$(build_of "$B")" "$(metal_of "$B")" $p; kb=$?; mB=$MED
  d=$((mA > mB ? mA - mB : mB - mA))
  if [ $ka -eq 0 ] && [ $kb -eq 0 ] && [ $d -le "$PAIR_MARGIN" ]; then
    TA+=("${TAG}_A$p"); TB+=("${TAG}_B$p"); kept=$((kept + 1))
  else
    [ $ka -eq 0 ] && [ $kb -eq 0 ] && echo "${TAG} pair $p: discarded (other_cpu medians $mA and $mB differ by $d > $PAIR_MARGIN)" >&2
    dropped+=("${TAG}_A$p" "${TAG}_B$p")
  fi
done
summary
