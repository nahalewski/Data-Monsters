#!/usr/bin/env bash
# Build gen1recomp for PSP.
#
#   ./build.sh [--host-only] [--upstream DIR] [--ref REF]
#
# Steps:
#   1. fetch bryanthaboi/gen1recomp (or use --upstream DIR)
#   2. assemble the game tree: this port's shell + the GPL engine (the
#      upstream launcher files listed in its LICENSE term 2 are excluded)
#   3. compile every .lua to Lua 5.4 bytecode and pack the tree into game.pak
#   4. build the lovepsp runtime for the PSP and wrap it in EBOOT.PBP with
#      game.pak as DATA.PSAR  (skipped with --host-only)
#
# Output: dist/gen1recomp/EBOOT.PBP  (copy the folder to PSP/GAME/)
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
UPSTREAM_URL="https://github.com/bryanthaboi/gen1recomp"
UPSTREAM_REF="${UPSTREAM_REF:-main}"
UPSTREAM_DIR=""
HOST_ONLY=0
BYTECODE=1
while [ $# -gt 0 ]; do
  case "$1" in
    --host-only) HOST_ONLY=1 ;;
    --no-bytecode) BYTECODE=0 ;;  # Lua source in the archive (big-endian targets)
    --upstream) UPSTREAM_DIR="$2"; shift ;;
    --ref) UPSTREAM_REF="$2"; shift ;;
    *) echo "unknown option $1" >&2; exit 2 ;;
  esac
  shift
done

BUILD="${BUILD_DIR:-$HERE/build}"
GAME="$BUILD/game"
DIST="$HERE/dist/gen1recomp"
mkdir -p "$BUILD" "$DIST"

# ------------------------------------------------------------ 1. upstream
if [ -z "$UPSTREAM_DIR" ]; then
  UPSTREAM_DIR="$BUILD/upstream"
  if [ ! -d "$UPSTREAM_DIR/.git" ]; then
    git clone --depth 1 --branch "$UPSTREAM_REF" "$UPSTREAM_URL" "$UPSTREAM_DIR"
  else
    git -C "$UPSTREAM_DIR" fetch --depth 1 origin "$UPSTREAM_REF"
    git -C "$UPSTREAM_DIR" checkout -q FETCH_HEAD
  fi
fi
UPSTREAM_COMMIT="$(git -C "$UPSTREAM_DIR" rev-parse --short HEAD 2>/dev/null || echo unknown)"
echo "upstream: $UPSTREAM_DIR @ $UPSTREAM_COMMIT"

# ------------------------------------------------------------ 2. host tools
make -C "$HERE/runtime" -f Makefile.host -j"$(nproc)" >/dev/null
# LUAC may point at a compiler built with a different number configuration
# (see LUA_NUMBER_CFLAGS in runtime/Makefile); the bytecode must match it
LUAC="${LUAC:-$HERE/runtime/build/host/lpluac}"

# ------------------------------------------------------------ 3. game tree
rm -rf "$GAME"
mkdir -p "$GAME"
cp -r "$HERE/shell/." "$GAME/"

# The engine.  LICENSE.MD term 2 lists the launcher files that are not under
# the GPL; they are left out and this port ships its own front end.
EXCLUDE=(
  src/import/LauncherView.lua
  src/import/LauncherSettings.lua
  src/import/OnlinePanel.lua
  src/import/CartLabelArt.lua
  src/import/CartShape.lua
  src/import/RomImporter.lua
  src/mods/LauncherMods.lua
  src/import/online
  assets/launcher
  assets/labels
)
cp -r "$UPSTREAM_DIR/src" "$GAME/src"
find "$GAME/src" -name '*.md' -delete
cp -r "$UPSTREAM_DIR/data" "$GAME/data"
mkdir -p "$GAME/tools" "$GAME/assets"
# Gen 1 manifests (~1 MiB each) plus the tiny Gen 3 stubs, so a FireRed /
# LeafGreen import can be tried with LOVEPSP_GAMES (see shell/main.lua)
for v in "" _blue _yellow _gold _silver _crystal _firered _leafgreen; do
  cp "$UPSTREAM_DIR/tools/rom_manifest$v.json" "$GAME/tools/"
done
for d in fonts skins touch logo; do
  [ -d "$UPSTREAM_DIR/assets/$d" ] && cp -r "$UPSTREAM_DIR/assets/$d" "$GAME/assets/$d"
done
for e in "${EXCLUDE[@]}"; do rm -rf "${GAME:?}/$e"; done
# upstream's example mods ride along (GPL); players add their own under
# save/pokemon-love2d/mods/ on the memory stick
cp -r "$UPSTREAM_DIR/mods" "$GAME/mods"
# the gallery is one level too deep for discovery (by upstream's design);
# lift it so each example is a card on the shell's Mods page, off by default
for m in "$GAME"/mods/examples/example_*; do [ -d "$m" ] && mv "$m" "$GAME/mods/"; done
rm -rf "$GAME/mods/examples"
# community mods fetched by tools/fetch_mods.py (gitignored; their own
# licences).  MODS_MAX_KB caps a mod's size: the PSP build takes the small
# ones (its 32/64 MB has to hold the game too); the Vita/PS3 builds take all.
MODS_MAX_KB="${MODS_MAX_KB:-1024}"
if [ -d "$HERE/mods_extra" ]; then
  n=0
  for m in "$HERE"/mods_extra/*/; do
    [ -f "$m/manifest.json" ] || continue
    kb=$(du -sk "$m" | cut -f1)
    if [ "$kb" -le "$MODS_MAX_KB" ]; then cp -r "$m" "$GAME/mods/$(basename "$m")"; n=$((n + 1)); fi
  done
  echo "community mods packed: $n (<= ${MODS_MAX_KB} KB each)"
fi
cp "$UPSTREAM_DIR/LICENSE.MD" "$GAME/LICENSE-gen1recomp.md"
cat > "$GAME/lovepsp/build_info.lua" <<EOF
return { upstream = "$UPSTREAM_COMMIT", built = "$(date -u +%Y-%m-%dT%H:%MZ)", port = "$(cat "$HERE/VERSION" 2>/dev/null | tr -d "[:space:]")" }
EOF

# Lua 5.4 bytecode: faster to load than source.  Debug info (line numbers,
# local names) is kept so error screens and bug reports stay useful; the
# chunk name keeps the archive-relative path for the same reason.
fail=0
while IFS= read -r -d '' f; do
  [ "$BYTECODE" = 1 ] || break
  rel="${f#$GAME/}"
  if ! "$LUAC" -g "$f" "$f.tmp" "$rel"; then fail=1; continue; fi
  mv "$f.tmp" "$f"
done < <(find "$GAME" -path "$GAME/mods" -prune -o -name '*.lua' -print0)
[ "$fail" = 0 ] || { echo "bytecode compilation failed" >&2; exit 1; }

python3 "$HERE/runtime/tools/mkpak.py" "$BUILD/game.pak" "$GAME"
cp "$BUILD/game.pak" "$DIST/game.pak"

# ------------------------------------------------------------ 4. EBOOT
if [ "$HOST_ONLY" = 1 ]; then
  echo "host-only build: $DIST/game.pak"
  exit 0
fi
export PSPDEV="${PSPDEV:-/usr/local/pspdev}"
export PATH="$PSPDEV/bin:$PATH"
make -C "$HERE/runtime" -j"$(nproc)" >/dev/null
# DATA.PSAR carries the game archive, so a single EBOOT.PBP is the whole port
pack-pbp "$DIST/EBOOT.PBP" "$HERE/runtime/build/psp/PARAM.SFO" "$HERE/psp-assets/ICON0.PNG" \
  NULL NULL "$HERE/psp-assets/PIC1.PNG" NULL "$HERE/runtime/build/psp/lovepsp.prx" "$BUILD/game.pak"
rm -f "$DIST/game.pak"
mkdir -p "$DIST/roms" "$DIST/save"
cp "$HERE/README.md" "$DIST/README.md"
cp "$HERE/GUIDE-PSP.md" "$DIST/GUIDE-PSP.md"
echo "built $DIST/EBOOT.PBP ($(du -h "$DIST/EBOOT.PBP" | cut -f1))"
