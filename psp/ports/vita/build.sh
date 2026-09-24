#!/usr/bin/env bash
# PS Vita / Vita TV package.  Needs vitasdk on PATH (arm-vita-eabi-gcc) and
# ../../build/game.pak from build.sh --host-only (build_all.sh does both).
#
# Output: dist/vita/gen1recomp.vpk  (install with VitaShell; runs on a
# Vita/Vita TV on HENkaku/h-encore or in Vita3K).  ROMs go in
# ux0:data/gen1recomp/ (or roms/ under it); saves in ux0:data/gen1recomp/save/.
set -euo pipefail
export MODS_MAX_KB="${MODS_MAX_KB:-999999}"  # all fetched mods: these consoles have the memory
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$HERE/../.."
export VITASDK="${VITASDK:-/usr/local/vitasdk}"
export PATH="$VITASDK/bin:$PATH"
[ -f "$ROOT/build/game.pak" ] || bash "$ROOT/build.sh" --host-only
make -C "$HERE" -j"$(nproc)"
mkdir -p "$ROOT/dist/vita"
cp "$ROOT/runtime/build/vita/gen1recomp.vpk" "$ROOT/dist/vita/"
cp "$ROOT/README.md" "$ROOT/dist/vita/README.md"
cat > "$ROOT/dist/vita/INSTALL-VITA.txt" <<'EOF'
gen1recomp for PS Vita / Vita TV
1. Install gen1recomp.vpk with VitaShell (HENkaku / h-encore / Vita3K).
2. Create ux0:data/gen1recomp/ and copy your canonical US ROM dumps there
   (any file name; Red, Blue, Yellow, Gold, Silver, Crystal).
3. Start the app. Cross = A, Circle = B, Select + R / L cycles screen modes.
Saves and imported data: ux0:data/gen1recomp/save/pokemon-love2d/
Vita3K: enable "Show game data folder" in Vita3K and put the ROMs in
ux0:data/gen1recomp/ under its pref path.
EOF
echo "built $ROOT/dist/vita/gen1recomp.vpk"
