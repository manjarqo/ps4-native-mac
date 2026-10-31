#!/bin/bash
set -euo pipefail
LAUNCHER_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="${SONIC_PROJECT_DIR:-$LAUNCHER_DIR}"
export PS4RECOMP_DATA_DIR="$ROOT/data"
export PS4_PRO=0
export PS4_GNM_METAL="${PS4_GNM_METAL:-3}"
export PS4_GNM_SYNC_COMPILE="${PS4_GNM_SYNC_COMPILE:-1}"

# Existing scripted runs remain noninteractive, including launch.command --no-menu.
menu="${SONIC_MENU:-1}"
if [[ "${1:-}" == --no-menu ]]; then
    shift
    menu=0
fi
if [[ -n "${PS4_PAD_SCRIPT:-}${PS4_PAD_CTL:-}${PS4_PAD_AUTOPRESS:-}${PS4_GNM_QUIT_AFTER_S:-}${PS4_RECOMP_HEADLESS:-}${PS4_SCREENSHOT_DIR:-}" ]]; then
    menu=0
fi
if [[ "$menu" == 0 ]]; then
    cd "$ROOT/build"
    exec ./ps4_app "$@"
fi

cache="$ROOT/.launcher"
mkdir -p "$cache"
bundle="$cache/Sonic Origins Menu.app"
mkdir -p "$bundle/Contents/MacOS"
cp "$LAUNCHER_DIR/launcher-menu.plist" "$bundle/Contents/Info.plist"
helper="$bundle/Contents/MacOS/launcher-menu"
if [[ ! -x "$helper" || "$LAUNCHER_DIR/launcher-menu.m" -nt "$helper" ]]; then
    candidate="$(mktemp "$cache/launcher-menu.XXXXXX")"
    if ! /usr/bin/clang -fobjc-arc -Wall -Wextra -Werror -O2 -framework AppKit \
        "$LAUNCHER_DIR/launcher-menu.m" -o "$candidate"; then
        rm -f "$candidate"
        echo "Could not build Sonic menu. Use --no-menu for normal startup." >&2
        exit 1
    fi
    mv -f "$candidate" "$helper"
fi
choice="$("$helper" --choose)"
case "$choice" in
    "") exit 0 ;; # Cancel / window close does not start the game.
    normal)
        cd "$ROOT/build"
        exec ./ps4_app "$@"
        ;;
    [0-3]) ;;
    *) echo "Invalid menu result: $choice" >&2; exit 1 ;;
esac

session="$(mktemp -d "$cache/session.XXXXXX")"
control="$session/pad.ctl"
touch "$control"
export PS4_PAD_CTL="$control"
export PS4_SCREENSHOT_DIR="$session"
export PS4_SCREENSHOT_EVERY=2000000000
unset PS4_SCREENSHOT_EVERY_SEC
cd "$ROOT/build"
./ps4_app "$@" &
game_pid=$!
"$helper" --assist "$choice" "$control" "$game_pid" "$session" &
guide_pid=$!
cleanup() {
    kill "$guide_pid" 2>/dev/null || true
    rm -rf "$session"
}
trap cleanup EXIT
trap 'kill "$game_pid" 2>/dev/null || true' INT TERM HUP
status=0
wait "$game_pid" || status=$?
exit "$status"
