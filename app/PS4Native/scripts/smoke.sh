#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Packages the app (package.sh, same arguments) and smoke-tests the package:
#   1. runs "PS4 Native.app" --smoke on the recorded engine fixtures, with the library and data
#      dir in scratch directories, under a time limit: FakeEngine replays the fixtures and
#      /bin/sleep 1 stands in for the game, so no engine command and no game runs;
#   2. checks it exits 0 and drew window.png (kept, with smoke.json, in $PS4NATIVE_DIST/smoke);
#   3. mounts the disk image read-only and verifies the signature of the app inside it.
#
# Usage: app/PS4Native/scripts/smoke.sh [--version X]
set -euo pipefail

die() { echo "smoke: $*" >&2; exit 1; }

APP_SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)" || exit 1
ROOT="$(cd "$APP_SRC/../.." && pwd -P)" || exit 1
FIXTURES="$APP_SRC/Tests/PS4NativeKitTests/Fixtures"
[ -f "$FIXTURES/import.jsonl" ] || die "no fixtures at $FIXTURES"

"$APP_SRC/scripts/package.sh" "$@"

DIST_IN="${PS4NATIVE_DIST:-$ROOT/../ps4native-dist}"
DIST="$(cd "$DIST_IN" && pwd -P)" || exit 1
APP="$DIST/PS4 Native.app"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
DMG="$DIST/PS4Native-$VERSION.dmg"
[ -f "$DMG" ] || die "no disk image at $DMG"

SCRATCH="$(mktemp -d "${TMPDIR:-/tmp}/ps4native-smoke.XXXXXX")" || exit 1
SCRATCH="$(cd "$SCRATCH" && pwd -P)" || exit 1
case "$SCRATCH" in */ps4native-smoke.*) ;; *) die "unexpected scratch dir $SCRATCH" ;; esac
MOUNT="$SCRATCH/mnt"
cleanup() {
  if [ -d "$MOUNT" ] && mount | grep -qF " on $MOUNT "; then hdiutil detach "$MOUNT" -quiet || true; fi
  rm -rf "$SCRATCH"
}
trap cleanup EXIT

OUT="$DIST/smoke"
rm -rf "$OUT"
mkdir -p "$OUT" "$SCRATCH/library" "$SCRATCH/data"

echo "== smoke run"
status=0
PS4NATIVE_LIBRARY="$SCRATCH/library" PS4RECOMP_DATA_DIR="$SCRATCH/data" \
  timeout -k 10 300 "$APP/Contents/MacOS/PS4Native" --smoke "$FIXTURES" --out "$OUT" || status=$?
[ "$status" -eq 0 ] || die "the smoke run exited with status $status (124: timed out); see $OUT/smoke.json"
[ -s "$OUT/window.png" ] || die "the smoke run drew no $OUT/window.png"
[ -s "$OUT/smoke.json" ] || die "the smoke run wrote no $OUT/smoke.json"
rm -rf "$OUT/src" "$OUT/Applications"

echo "== disk image"
mkdir -p "$MOUNT"
hdiutil attach -nobrowse -readonly -mountpoint "$MOUNT" "$DMG" >/dev/null
[ -L "$MOUNT/Applications" ] || die "the disk image has no Applications link"
codesign --verify --deep --strict "$MOUNT/PS4 Native.app" || die "the app in the disk image fails codesign --verify"
hdiutil detach "$MOUNT" -quiet

echo "smoke ok: $OUT/window.png, $OUT/smoke.json; $DMG verifies"
