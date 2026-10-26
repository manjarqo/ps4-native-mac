#!/bin/bash
# One windowed, time-bounded TLOU run of the colour build with system window captures.
# usage: tlou_color_run.sh <outdir> <seconds> <padctl file|-> [ENV=VAL...]
# Window captures go through the macOS display path (gamma pass, CAMetalLayer colour space,
# compositor) like the reference video; they are converted to sRGB and scaled to 960 px wide.
# CAP_EVERY (default 5) seconds between captures, CAP_FROM (default 60) seconds before the first.
set -u
OUT=$1; SECS=$2; PAD=$3; shift 3
OUT=$(mkdir -p "$OUT" && cd "$OUT" && pwd) || exit 1   # absolute: the script changes directory
[ "$PAD" = "-" ] || PAD=$(cd "$(dirname "$PAD")" && pwd)/$(basename "$PAD") || exit 1
BUILD=${BUILD:-$HOME/ps4recomp-work/tlou_build_colors}
SRGB="/System/Library/ColorSync/Profiles/sRGB Profile.icc"
mkdir -p "$OUT/shots" || exit 1
# Every extra argument is an environment assignment for the game (env would run anything else as
# the command), and none may set the data dir: env applies them after the check below.
for a in "$@"; do
  case "$a" in
    PS4RECOMP_DATA_DIR=*) echo "set PS4RECOMP_DATA_DIR in the environment, not as an argument" >&2; exit 2;;
    [A-Za-z_]*=*) ;;
    *) echo "not an ENV=VAL argument: $a" >&2; exit 2;;
  esac
done
export PS4RECOMP_DATA_DIR=${PS4RECOMP_DATA_DIR:-$HOME/ps4recomp-work/data_color}
# The live saves are under ~/Library/Application Support: check the path with symlinks resolved
# (the dir itself, or its parent if it does not exist yet), ignoring case (APFS is case-insensitive).
if [ -d "$PS4RECOMP_DATA_DIR" ]; then
  DATA_REAL=$(cd "$PS4RECOMP_DATA_DIR" && pwd -P) || exit 2
else
  DATA_REAL=$(cd "$(dirname "$PS4RECOMP_DATA_DIR")" && pwd -P) || { echo "no parent for $PS4RECOMP_DATA_DIR" >&2; exit 2; }
  DATA_REAL=$DATA_REAL/$(basename "$PS4RECOMP_DATA_DIR")
fi
case "$(printf '%s' "$DATA_REAL" | tr '[:upper:]' '[:lower:]')" in
  *"application support"*) echo "refusing the live data dir ($DATA_REAL)" >&2; exit 2;;
esac
export PS4RECOMP_DATA_DIR=$DATA_REAL
CTL=""
if [ "$PAD" != "-" ]; then CTL="$OUT/pad.ctl"; : > "$CTL"; fi
cd "$BUILD" || exit 1
env PS4_LANG=${PS4_LANG:-ru} PS4_SAVEDATA_DIALOG_PICK=${PICK:-SAVEDATA06} PS4_PAD_AUTOPRESS=4000 \
    PS4_PAD_AUTOPRESS_UNTIL=${AUTOPRESS_UNTIL:-60000} ${CTL:+PS4_PAD_CTL=$CTL} \
    PS4_SCREENSHOT_DIR="$OUT/shots" PS4_SCREENSHOT_EVERY=${EVERY:-600} "$@" \
    perl -e "alarm $SECS; exec @ARGV" ./ps4_app > "$OUT/run.log" 2>&1 &
GAME=$!
# Always stop and reap the game, also when this script is interrupted.
trap 'kill $GAME 2>/dev/null; wait $GAME 2>/dev/null' EXIT
trap 'exit 130' INT TERM
# alive: the child exists and is not a zombie (kill -0 succeeds on a zombie until it is reaped).
alive() { local st; st=$(ps -o stat= -p "$1" 2>/dev/null); [ -n "$st" ] && [ "${st#Z}" = "$st" ]; }
# Stops the game when WindowServer exceeds 2 GB (checked every second while waiting, too).
ws_guard() {
  local ws
  ws=$(ps -axo rss=,comm= | awk '/WindowServer$/ {print int($1/1024)}' | head -1)
  if [ "${ws:-0}" -gt 2048 ]; then echo "WindowServer at ${ws} MB: stopping the game" >&2; kill $GAME 2>/dev/null; fi
}
WID=""
for _ in $(seq 1 60); do
  WID=$(grep -m1 -oE 'window id=[0-9]+' "$OUT/run.log" 2>/dev/null | cut -d= -f2)
  [ -n "$WID" ] && break
  ws_guard
  alive $GAME || break
  sleep 1
done
[ -n "$WID" ] || { echo "no window id in run.log" >&2; kill $GAME 2>/dev/null; exit 1; }
for _ in $(seq 1 "${CAP_FROM:-60}"); do
  alive $GAME || break
  ws_guard
  sleep 1
done
[ -n "$CTL" ] && cat "$PAD" >> "$CTL"
while alive $GAME; do
  T=$(date +%s)
  if screencapture -x -o -l"$WID" "$OUT/raw_$T.png" 2>/dev/null; then
    sips --matchTo "$SRGB" -Z 960 -s format png "$OUT/raw_$T.png" --out "$OUT/win_$T.png" > /dev/null && rm -f "$OUT/raw_$T.png"
  fi
  ws_guard
  sleep "${CAP_EVERY:-5}"
done
wait $GAME; echo "exit=$?"
