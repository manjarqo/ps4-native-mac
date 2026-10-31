# Guards, monitor and clean-up shared by the fixed-route scripts (tools/metal4_route.sh,
# tools/u4_route.sh); sourced, not run. The script sets before calling these functions:
#   OUT TAG MON LOG SECS, and after starting the game: GP (its PID).
# Optional: TICK=5 (monitor period, s), LOAD_WAIT=48 (x 5 s), MAXGPUERR=2, LOAD_KILL=20,
#   CTL_SRC and CTL_DST (a camera program, see route_monitor).
# Only the game's own PID (and the children of the script's own watchdog) are ever signalled.

# set by the sourcing script only (never taken from the environment)
CTL_SRC=; CTL_DST=

load1() { sysctl -n vm.loadavg | awk '{print $2}'; }

# Waits up to LOAD_WAIT x 5 s for a 1-minute load below 10. Sets LATE to " (load stayed above 10)"
# when it never settled (the run then goes on; metal4_perf_ab.sh drops runs that end with load > 15).
route_wait_load() {
  local w
  LATE=" (load stayed above 10)"
  for ((w = 0; w <= ${LOAD_WAIT:-48}; w++)); do
    awk "BEGIN{exit !($(load1) < 10)}" && { LATE=; break; }
    [ "$w" -lt "${LOAD_WAIT:-48}" ] && sleep 5
  done
}

# WS = WindowServer's PID, WS0 = its RSS in KB now (0 when there is no WindowServer: no RSS guard)
route_ws_init() {
  WS=$(pgrep -x WindowServer | head -1)
  WS0=0
  [ -n "$WS" ] && WS0=$(ps -o rss= -p "$WS" | tr -d ' ')
  WS0=${WS0:-0}
}

# the system's GPU event reports (gpuEvent-*.ips, written when Metal blames this process for a GPU
# fault or hang) made during the run are copied next to the log: cleaners may delete the originals
route_stamp() { STAMP=$(mktemp "${TMPDIR:-/tmp}/route.XXXXXX"); }

# hard kill of the game's PID at SECS+30 s whatever the script does; sets WD
route_watchdog() {
  ( sleep $((SECS + 30)) & local sp=$!
    trap 'kill $sp 2>/dev/null; exit 0' TERM
    wait $sp 2>/dev/null
    kill -9 "$GP" 2>/dev/null ) 2>/dev/null &
  WD=$!
}

# Samples every TICK s until SECS: appends to $MON, sets WHY ("time limit", "exited" or the guard's
# reason, as in GUARD) and GUARD (the reason when a guard fired, else empty).
# With CTL_SRC set (a program of PS4_PAD_CTL commands) it is appended to the control file CTL_DST
# once the log shows "[pad] script started": while it is pending, each period sleeps in 1 s parts
# and checks the log; the monitor file notes when it was appended, or that it never was.
route_monitor() {
  local t s rss cpu l1 g grss ocpu cam=${CTL_SRC:+pending}
  WHY="time limit"; GUARD=
  for ((t = 0; t < SECS; t += ${TICK:-5})); do
    if [ -n "$cam" ]; then
      for ((s = 1; s <= ${TICK:-5}; s++)); do
        sleep 1
        if [ -n "$cam" ] && grep -q '^\[pad\] script started' "$LOG"; then
          cat "$CTL_SRC" >> "$CTL_DST"; cam=
          echo "camera program appended at t=$((t + s))" >> "$MON"
        fi
      done
    else
      sleep "${TICK:-5}"
    fi
    kill -0 "$GP" 2>/dev/null || { WHY="exited"; break; }
    rss=0; cpu=0
    [ -n "$WS" ] && read -r rss cpu < <(ps -o rss=,%cpu= -p "$WS")
    l1=$(load1)
    g=$(grep -cE "command buffer .*failed|GPU hang report|GPU watchdog" "$LOG")
    grss=$(ps -o rss= -p "$GP" | tr -d ' ')
    ocpu=$(ps -Ao pid=,pcpu= | awk -v g="$GP" '$1 != g {o += $2} END {printf "%.0f", o}')
    echo "t=$t ws_rss=$rss ws_cpu=$cpu load=$l1 game_rss=$grss gpu_err=$g other_cpu=$ocpu" >> "$MON"
    if [ -n "$WS" ] && [ $((rss - WS0)) -gt 307200 ]; then GUARD="WindowServer RSS +$(((rss - WS0) / 1024)) MB"; break; fi
    if awk "BEGIN{exit !($l1 > ${LOAD_KILL:-20})}"; then GUARD="load $l1"; break; fi
    if [ "$g" -ge "${MAXGPUERR:-2}" ]; then GUARD="GPU errors $g"; break; fi
  done
  [ -n "$cam" ] && echo "camera program never appended (no [pad] script started)" >> "$MON"
  [ -z "$GUARD" ] || WHY=$GUARD
}

# kills the game (TERM, then KILL) and the watchdog, copies the GPU event reports, removes the stamp
route_cleanup() {
  kill -TERM "$GP" 2>/dev/null; sleep 2; kill -9 "$GP" 2>/dev/null; wait "$GP" 2>/dev/null
  kill "$WD" 2>/dev/null; { wait "$WD"; } 2>/dev/null
  kill -0 "$GP" 2>/dev/null && echo "WARNING: game $GP still alive" | tee -a "$MON"
  local r
  while IFS= read -r r; do
    cp "$r" "$OUT/${TAG}_$(basename "$r")" && echo "GPU event report: $OUT/${TAG}_$(basename "$r")" | tee -a "$MON"
  done < <(find /Library/Logs/DiagnosticReports "$HOME/Library/Logs/DiagnosticReports" -maxdepth 1 \
             -name 'gpuEvent-ps4_app*' -newer "$STAMP" 2>/dev/null)
  rm -f "${STAMP:?}"
}

# the stop line of the monitor file
route_stop_line() {
  echo "$TAG stop $(date +%T) ($WHY) load $(sysctl -n vm.loadavg) WindowServer rss $( [ -n "$WS" ] && ps -o rss= -p "$WS" | tr -d ' ' ) KB" | tee -a "$MON"
}
