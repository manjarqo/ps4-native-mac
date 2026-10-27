#!/bin/bash
# Assemble the self-contained engine kit that the PS4 Native app ships in its bundle:
# ps4-recomp, the runtime sources, the built 3rdparty static libraries, and a bundled
# ninja and FreeType so a game build needs nothing from Homebrew. The layout mirrors the
# release archive (see INSTALL.txt there). Nothing is downloaded; missing inputs fail.
#
# Usage: tools/make_engine_kit.sh <out dir>
set -euo pipefail

if [ $# -ne 1 ] || [ -z "$1" ]; then
  echo "usage: $0 <out dir>" >&2
  exit 2
fi

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)" || exit 1
mkdir -p "$1" || exit 1
OUT="$(cd "$1" && pwd -P)" || exit 1
ROOT="$(cd "$ROOT" && pwd -P)" || exit 1
BREW=/opt/homebrew/opt

die() { echo "make_engine_kit: $*" >&2; exit 1; }

need() { # need <path> <hint>
  [ -e "$1" ] || die "missing input: $1 ($2)"
}

BREW_HINT="install it with: brew install freetype libpng ninja"
GCN="$ROOT/3rdparty/gcn-recompiler"
SPV="$ROOT/3rdparty/spirv-cross"
AT9="$ROOT/3rdparty/libatrac9"
MP3="$ROOT/3rdparty/minimp3"
FT="$BREW/freetype"
PNG="$BREW/libpng"
NINJA="$BREW/ninja"

BUILD_HINT="build the 3rdparty libraries first"
for f in "$GCN/libgcn_recompiler.a" "$GCN/include/gcn_recompiler.h" "$GCN/LICENSE" \
         "$SPV/libspirv-cross.a" "$SPV/LICENSE" \
         "$AT9/libatrac9.a" "$AT9/C/src/libatrac9.h" "$AT9/LICENSE" \
         "$MP3/minimp3.h" "$MP3/minimp3_ex.h" "$MP3/LICENSE"; do
  need "$f" "$BUILD_HINT"
done
for f in "$FT/include/freetype2/ft2build.h" "$FT/lib/libfreetype.a" "$FT/LICENSE.TXT" \
         "$PNG/lib/libpng16.a" "$PNG/LICENSE" \
         "$NINJA/bin/ninja" "$NINJA/COPYING"; do
  need "$f" "$BREW_HINT"
done
need "$ROOT/LICENSE" "repository root"
EXT="$GCN/externals"
for f in "$SPV"/LICENSES/*.txt "$EXT/boost/LICENSE_1_0.txt" "$EXT/fmt/LICENSE" \
         "$EXT/magic_enum/LICENSE" "$EXT/sirit/LICENSE.txt" \
         "$EXT/sirit/externals/SPIRV-Headers/LICENSE"; do
  need "$f" "$BUILD_HINT"
done
command -v go >/dev/null || die "go not found in PATH"

# The kit dir is cleaned below, so refuse any dir that is, contains or lies inside the repo,
# and any non-empty dir that this script did not create (marked with .engine-kit).
case "$OUT/" in
  "$ROOT/"*) die "refusing out dir $OUT: it is or lies inside the repository $ROOT" ;;
esac
case "$ROOT/" in
  "$OUT/"*) die "refusing out dir $OUT: it contains the repository $ROOT" ;;
esac
if [ ! -e "$OUT/.engine-kit" ] && [ -n "$(ls -A "$OUT")" ]; then
  die "refusing out dir $OUT: it is not empty and has no .engine-kit marker from an earlier run"
fi
touch "$OUT/.engine-kit"
for d in pkg 3rdparty bin licenses; do
  rm -rf "${OUT:?}/$d"
done
rm -f "$OUT/ps4-recomp" "$OUT/LICENSE"

echo "== building ps4-recomp"
(cd "$ROOT" && go build -buildvcs=false -trimpath -o "$OUT/ps4-recomp" ./cmd/ps4-recomp) || die "go build failed"

echo "== runtime sources"
(cd "$ROOT" && git ls-files -z pkg/runtime | while IFS= read -r -d '' f; do
  mkdir -p "$OUT/$(dirname "$f")"
  cp -L "$f" "$OUT/$f"
done)

echo "== 3rdparty"
mkdir -p "$OUT/3rdparty/gcn-recompiler/include" "$OUT/3rdparty/spirv-cross" \
         "$OUT/3rdparty/libatrac9/C/src" "$OUT/3rdparty/minimp3" \
         "$OUT/3rdparty/freetype/lib" "$OUT/bin" "$OUT/licenses"
cp -L "$GCN/libgcn_recompiler.a" "$GCN/LICENSE" "$OUT/3rdparty/gcn-recompiler/"
cp -L "$GCN/include/gcn_recompiler.h" "$OUT/3rdparty/gcn-recompiler/include/"
cp -L "$SPV/libspirv-cross.a" "$SPV/LICENSE" "$OUT/3rdparty/spirv-cross/"
cp -L "$AT9/libatrac9.a" "$AT9/LICENSE" "$OUT/3rdparty/libatrac9/"
cp -L "$AT9"/C/src/*.h "$OUT/3rdparty/libatrac9/C/src/"
cp -L "$MP3/minimp3.h" "$MP3/minimp3_ex.h" "$MP3/LICENSE" "$OUT/3rdparty/minimp3/"
cp -RL "$FT/include" "$OUT/3rdparty/freetype/include"
cp -L "$FT/lib/libfreetype.a" "$PNG/lib/libpng16.a" "$OUT/3rdparty/freetype/lib/"
cp -L "$FT/LICENSE.TXT" "$OUT/3rdparty/freetype/LICENSE.TXT"
cat > "$OUT/3rdparty/freetype/NOTICE" <<'NOTE'
FreeType 2 is used under the GNU GPL v2 option of its dual licence (see LICENSE.TXT); the GPLv2 text is the kit's LICENSE file.
NOTE
cp -L "$PNG/LICENSE" "$OUT/licenses/libpng-LICENSE"
cp -L "$NINJA/bin/ninja" "$OUT/bin/ninja"
cp -L "$NINJA/COPYING" "$OUT/licenses/ninja-COPYING"
cp -L "$ROOT/LICENSE" "$OUT/LICENSE"
chmod u+w "$OUT/bin/ninja"
chmod +x "$OUT/bin/ninja"

# Licenses of the components linked into the static libraries.
mkdir -p "$OUT/licenses/spirv-cross" "$OUT/licenses/gcn-recompiler"
cp -L "$SPV"/LICENSES/*.txt "$OUT/licenses/spirv-cross/"
cp -L "$EXT/boost/LICENSE_1_0.txt" "$OUT/licenses/gcn-recompiler/boost-LICENSE_1_0.txt"
cp -L "$EXT/fmt/LICENSE" "$OUT/licenses/gcn-recompiler/fmt-LICENSE"
cp -L "$EXT/magic_enum/LICENSE" "$OUT/licenses/gcn-recompiler/magic_enum-LICENSE"
cp -L "$EXT/sirit/LICENSE.txt" "$OUT/licenses/gcn-recompiler/sirit-LICENSE.txt"
cp -L "$EXT/sirit/externals/SPIRV-Headers/LICENSE" "$OUT/licenses/gcn-recompiler/SPIRV-Headers-LICENSE"

# No symlink may remain, and nothing may point into Homebrew.
if find "$OUT" -type l | grep -q .; then die "kit contains symlinks"; fi

echo "== self-check: build hello_world.elf with a copy of the kit under a path with a space (no Homebrew in PATH)"
ELF="$ROOT/hello_world.elf"
need "$ELF" "sample ELF used by the self-check"
# The app ships the kit in "PS4 Native.app/Contents/Resources/engine": the check runs a copy of
# the kit from a path with a space, so a path that the build hands to a shell unquoted fails here.
CHECK="$(mktemp -d "${TMPDIR:-/tmp}/engine kit check.XXXXXX")" || exit 1
case "$CHECK" in "/"*"/engine kit check."*) ;; *) die "unexpected scratch dir $CHECK" ;; esac
trap 'rm -rf "$CHECK"' EXIT
CHECK="$(cd "$CHECK" && pwd -P)" || exit 1
KIT="$CHECK/PS4 Native.app/Contents/Resources/engine"
mkdir -p "$KIT" || die "self-check: cannot create $KIT"
cp -R "$OUT/" "$KIT/" || die "self-check: cannot copy the kit to $KIT"
LOG="$CHECK/build.log"
PATH=/usr/bin:/bin "$KIT/ps4-recomp" "$ELF" -o "$CHECK/out dir/build" -c >"$LOG" 2>&1 || {
  tail -n 40 "$LOG" >&2
  die "self-check: ps4-recomp build failed"
}
grep -E "^ +(ninja|FreeType): " "$LOG" || true
if grep -qiE "no such file|compiling with clang directly" "$LOG"; then
  grep -iE "no such file|compiling with clang directly" "$LOG" | head -n 20 >&2
  die "self-check: the build did not run through the kit's ninja cleanly"
fi
grep -q "ninja: $KIT/bin/ninja" "$LOG" || die "self-check: the build did not pick the kit's ninja"
BIN="$CHECK/out dir/build/ps4_app"
[ -x "$BIN" ] || die "self-check: no built binary at $BIN"
if otool -L "$BIN" | grep -q /opt/homebrew; then
  otool -L "$BIN" | grep /opt/homebrew >&2
  die "self-check: built binary links against Homebrew"
fi
echo "self-check ok: built through the kit's ninja under a path with a space; no /opt/homebrew dependency"
echo "kit ready: $OUT ($(du -sh "$OUT" | cut -f1))"
