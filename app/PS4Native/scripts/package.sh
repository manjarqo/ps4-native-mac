#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Packages the PS4 Native app: the engine kit, a release build of the app, "PS4 Native.app"
# (ad-hoc signed, not notarized) and a disk image holding the app and an /Applications link.
#
# Usage: app/PS4Native/scripts/package.sh [--version X]
#   --version X   the app's CFBundleShortVersionString; the engine's version by default.
# The outputs go to $PS4NATIVE_DIST, by default ps4native-dist next to the repository (the
# engine kit refuses an out dir inside the repository):
#   engine/                 the engine kit (tools/make_engine_kit.sh)
#   PS4 Native.app          the app, with the kit in Contents/Resources/engine
#   PS4Native-<version>.dmg the disk image
set -euo pipefail

die() { echo "package: $*" >&2; exit 1; }

VERSION=""
while [ $# -gt 0 ]; do
  case "$1" in
    --version) [ $# -ge 2 ] && [ -n "$2" ] || die "--version needs a value"; VERSION=$2; shift 2 ;;
    *) echo "usage: $0 [--version X]" >&2; exit 2 ;;
  esac
done

APP_SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)" || exit 1
ROOT="$(cd "$APP_SRC/../.." && pwd -P)" || exit 1
[ -f "$ROOT/tools/make_engine_kit.sh" ] || die "$ROOT is not the repository root"
DIST_IN="${PS4NATIVE_DIST:-$ROOT/../ps4native-dist}"
mkdir -p "$DIST_IN" || exit 1
DIST="$(cd "$DIST_IN" && pwd -P)" || exit 1
case "$DIST/" in
  "$ROOT/"*) die "refusing dist dir $DIST: it lies inside the repository $ROOT" ;;
esac

KIT="$DIST/engine"
APP="$DIST/PS4 Native.app"
STAGING="$DIST/dmg-staging"

echo "== engine kit"
"$ROOT/tools/make_engine_kit.sh" "$KIT"
[ -x "$KIT/ps4-recomp" ] || die "no engine in the kit at $KIT"

if [ -z "$VERSION" ]; then
  VERSION="$("$KIT/ps4-recomp" version --json | sed -n 's/.*"event":"done".*"version":"\([^"]*\)".*/\1/p')"
  [ -n "$VERSION" ] || die "cannot read the engine version"
fi
case "$VERSION" in
  *[!0-9A-Za-z.-]*) die "version $VERSION has characters other than letters, digits, dots and dashes" ;;
esac

echo "== app (release)"
swift build -c release --package-path "$APP_SRC"
BIN="$(swift build -c release --package-path "$APP_SRC" --show-bin-path)/PS4Native"
[ -x "$BIN" ] || die "no app binary at $BIN"

echo "== icon"
ICONSET="$DIST/AppIcon.iconset"
rm -rf "$ICONSET"
swift "$APP_SRC/scripts/make-icon.swift" "$ICONSET"

echo "== $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/PS4Native"
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
rm -rf "$ICONSET"
ditto "$KIT" "$APP/Contents/Resources/engine"
rm -f "$APP/Contents/Resources/engine/.engine-kit"
# Files copied from Homebrew are read-only; the bundle's own files must be writable to sign it.
chmod -R u+w "$APP"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleDevelopmentRegion</key>
	<string>en</string>
	<key>CFBundleDisplayName</key>
	<string>PS4 Native</string>
	<key>CFBundleExecutable</key>
	<string>PS4Native</string>
	<key>CFBundleIconFile</key>
	<string>AppIcon</string>
	<key>CFBundleIdentifier</key>
	<string>org.ps4native.manager</string>
	<key>CFBundleInfoDictionaryVersion</key>
	<string>6.0</string>
	<key>CFBundleName</key>
	<string>PS4 Native</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>CFBundleShortVersionString</key>
	<string>$VERSION</string>
	<key>CFBundleVersion</key>
	<string>$VERSION</string>
	<key>LSApplicationCategoryType</key>
	<string>public.app-category.games</string>
	<key>LSMinimumSystemVersion</key>
	<string>26.0</string>
	<key>NSHighResolutionCapable</key>
	<true/>
</dict>
</plist>
PLIST
plutil -lint "$APP/Contents/Info.plist" >/dev/null

echo "== signing (ad hoc)"
xattr -cr "$APP"
codesign --force --deep --sign - "$APP"
codesign --verify --deep --strict "$APP"

echo "== disk image"
DMG="$DIST/PS4Native-$VERSION.dmg"
rm -rf "$STAGING"
mkdir -p "$STAGING"
ditto "$APP" "$STAGING/PS4 Native.app"
ln -s /Applications "$STAGING/Applications"
hdiutil create -volname "PS4 Native" -srcfolder "$STAGING" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$STAGING"

echo "== done"
echo "app:    $APP ($(du -sh "$APP" | cut -f1))"
echo "engine: $(du -sh "$APP/Contents/Resources/engine" | cut -f1) of it is the engine kit"
echo "dmg:    $DMG ($(stat -f %z "$DMG") bytes, $(du -h "$DMG" | cut -f1))"
echo "sha256: $(shasum -a 256 "$DMG" | cut -d' ' -f1)"
