#!/usr/bin/env bash
# PS3 package.  Needs ps3dev (ppu-gcc, PSL1GHT) with SDL2 from ps3libraries.
#
# Output: dist/ps3/gen1recomp.pkg          CFW: install from the XMB (Package Manager)
#         dist/ps3/GEN1RECMP/              CFW "jailbreak folder": copy to
#                                          /dev_hdd0/game/GEN1RECMP/ (also RPCS3's
#                                          dev_hdd0/game/); RPCS3 installs the .pkg too
#         ROMs: /dev_hdd0/game/GEN1RECMP/USRDIR/ (or roms/ under it)
set -euo pipefail
export MODS_MAX_KB="${MODS_MAX_KB:-999999}"  # all fetched mods: these consoles have the memory
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$HERE/../.."
export PS3DEV="${PS3DEV:-/usr/local/ps3dev}"
export PSL1GHT="${PSL1GHT:-$PS3DEV}"
export PATH="$PS3DEV/bin:$PS3DEV/ppu/bin:$PATH"
export LC_ALL=C.UTF-8
# big-endian target: Lua source, not bytecode
BUILD_DIR="$ROOT/build_ps3" bash "$ROOT/build.sh" --host-only --no-bytecode "$@"
make -C "$HERE" -j"$(nproc)"
mkdir -p "$ROOT/dist/ps3"
cp "$HERE/lovepsp.pkg" "$ROOT/dist/ps3/gen1recomp.pkg"
# retail-installable (CFW / HEN) package; RPCS3 accepts either
package_finalize "$ROOT/dist/ps3/gen1recomp.pkg" || true
rm -rf "$ROOT/dist/ps3/GEN1RECMP"
cp -r "$HERE/build/pkg" "$ROOT/dist/ps3/GEN1RECMP"
cp "$ROOT/README.md" "$ROOT/dist/ps3/README.md"
cat > "$ROOT/dist/ps3/INSTALL-PS3.txt" <<'EOF'
gen1recomp for PS3 (CFW / HEN and RPCS3)
Package: install gen1recomp.pkg from the XMB (Install Package Files) or in
         RPCS3 via File > Install Packages.
Folder:  copy GEN1RECMP/ to /dev_hdd0/game/ (FTP or a USB file manager);
         RPCS3: <rpcs3>/dev_hdd0/game/GEN1RECMP/.
ROMs:    /dev_hdd0/game/GEN1RECMP/USRDIR/ (or roms/ under it), canonical US
         dumps of Red, Blue, Yellow, Gold, Silver, Crystal.
Saves:   /dev_hdd0/game/GEN1RECMP/USRDIR/save/pokemon-love2d/
Controls: Cross = A, Circle = B, Select + R / L cycle screen modes.
EOF
echo "built $ROOT/dist/ps3/gen1recomp.pkg"
