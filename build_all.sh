#!/usr/bin/env bash
# Build every console target this port has a toolchain for and zip them up.
#
#   ./build_all.sh [--upstream DIR]
#
# Targets are skipped, not failed, when their toolchain is not installed:
#   PSP        psp-gcc (pspdev)            -> dist/gen1recomp/EBOOT.PBP
#   PS Vita    arm-vita-eabi-gcc (vitasdk) -> dist/vita/gen1recomp.vpk
#   PS3        ppu-gcc (ps3dev/PSL1GHT)    -> dist/ps3/ (folder + .pkg)
# Output: dist/gen1recomp-ports.zip
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ARGS=("$@")
export PSPDEV="${PSPDEV:-/usr/local/pspdev}"
export VITASDK="${VITASDK:-/usr/local/vitasdk}"
export PS3DEV="${PS3DEV:-/usr/local/ps3dev}"
export PSL1GHT="${PSL1GHT:-$PS3DEV}"
export PATH="$PSPDEV/bin:$VITASDK/bin:$PS3DEV/bin:$PS3DEV/ppu/bin:$PATH"

python3 "$HERE/runtime/tools/mkicons.py" "$HERE/psp-assets" >/dev/null
built=()

if command -v psp-gcc >/dev/null 2>&1; then
  echo "== PSP"
  bash "$HERE/build.sh" "${ARGS[@]}"
  built+=("dist/gen1recomp")
else
  echo "== PSP: psp-gcc not found, skipped (see README: pspdev)"
  # still produce the game archive so other targets can share it
  bash "$HERE/build.sh" --host-only "${ARGS[@]}"
fi

if [ -x "$HERE/ports/vita/build.sh" ] && command -v arm-vita-eabi-gcc >/dev/null 2>&1; then
  echo "== PS Vita"
  bash "$HERE/ports/vita/build.sh" && built+=("dist/vita")
else
  echo "== PS Vita: vitasdk not found, skipped"
fi

if [ -x "$HERE/ports/ps3/build.sh" ] && command -v ppu-gcc >/dev/null 2>&1; then
  echo "== PS3"
  bash "$HERE/ports/ps3/build.sh" && built+=("dist/ps3")
else
  echo "== PS3: ps3dev not found, skipped"
fi

cd "$HERE"
rm -f dist/gen1recomp-ports.zip
if [ ${#built[@]} -gt 0 ]; then
  cp README.md dist/README-ports.md
  (cd dist && zip -qr gen1recomp-ports.zip README-ports.md "${built[@]#dist/}")
  echo "wrote dist/gen1recomp-ports.zip: ${built[*]}"
else
  echo "nothing built"
  exit 1
fi
