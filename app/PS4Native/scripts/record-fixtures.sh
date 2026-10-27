#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Records the engine streams the app's tests replay (Tests/PS4NativeKitTests/Fixtures/*.jsonl).
#
# Builds ps4-recomp and tools/gmfixtures, writes a synthetic content folder and fake PKGs into
# a scratch directory, runs each engine command with --json into a scratch library, and
# replaces the scratch paths with the placeholders FakeEngine substitutes:
#   $LIB  the scratch library      $SRC  the gmfixtures output dir      $TMP  the engine's temp dir
# The build step is a real recompilation of hello_world.elf and takes a few minutes.
set -euo pipefail

app=$(cd "$(dirname "$0")/.." && pwd)
repo=$(cd "$app/../.." && pwd)
out="$app/Tests/PS4NativeKitTests/Fixtures"
[ -f "$repo/hello_world.elf" ] || { echo "record-fixtures: $repo/hello_world.elf is missing" >&2; exit 1; }

scratch=$(mktemp -d "${TMPDIR:-/tmp}/gmfixtures.XXXXXX")
scratch=$(cd "$scratch" && pwd -P)
trap 'rm -rf "$scratch"' EXIT
src="$scratch/src"
lib="$scratch/lib"
tmp="$scratch/tmp"
mkdir -p "$src" "$lib" "$tmp" "$scratch/logs"

# The engine stays in the repo root: build finds pkg/runtime and 3rdparty next to it.
(cd "$repo" && go build -buildvcs=false -o ps4-recomp ./cmd/ps4-recomp \
  && go build -buildvcs=false -o "$scratch/gmfixtures" ./tools/gmfixtures)
engine="$repo/ps4-recomp"
"$scratch/gmfixtures" "$src" "$repo/hello_world.elf"

# record <name> <expect ok|fail> <engine args...>: stdout goes to <name>.jsonl, stderr to a log.
record() {
  local name=$1 expect=$2; shift 2
  local status=0
  (cd "$repo" && TMPDIR="$tmp" "$engine" "$@" --json) >"$scratch/$name.jsonl" 2>"$scratch/logs/$name.log" || status=$?
  local last; last=$(tail -n 1 "$scratch/$name.jsonl")
  case "$expect:$status:$last" in
    ok:0:'{"event":"done"'*|fail:1:'{"event":"error"'*) ;;
    *) echo "record-fixtures: $name ended with status $status: $last" >&2
       tail -n 20 "$scratch/logs/$name.log" >&2
       exit 1 ;;
  esac
}

game="$lib/games/CUSA00557"
record inspect ok inspect "$src/game.pkg"
record inspect-retail ok inspect "$src/retail.pkg"
record inspect-folder ok inspect "$src/content"
record import ok import "$src/game.pkg" --library "$lib"
record import-patch ok import "$src/patch.pkg" --library "$lib"
record import-dlc ok import "$src/dlc.pkg" --library "$lib"
record import-retail fail import "$src/retail.pkg" --library "$lib"
record analyze-game ok analyze-game "$game/content"
record build ok build "$game/content/eboot.bin" -o "$game/build"
record version ok version

# Longest paths first, so $LIB and $SRC win over $TMP and over the scratch root.
for f in "$scratch"/*.jsonl; do
  sed -e "s#$lib#\$LIB#g" -e "s#$src#\$SRC#g" -e "s#$tmp#\$TMP#g" "$f" >"$out/$(basename "$f")"
done
if grep -n -e '/Users/' -e '/Volumes/' -e '/private/' -e "$scratch" "$out"/*.jsonl; then
  echo "record-fixtures: a machine path is left in the fixtures above" >&2
  exit 1
fi
echo "record-fixtures: wrote $(ls "$out"/*.jsonl | wc -l | tr -d ' ') fixtures to $out"
