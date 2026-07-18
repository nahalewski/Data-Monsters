#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

fail() {
  echo "error: $*" >&2
  exit 1
}

if [[ -z "${DEVKITPRO:-}" ]]; then
  fail "DEVKITPRO is not set. Install devkitPro and export DEVKITPRO, for example /opt/devkitpro."
fi

if [[ ! -d "$DEVKITPRO/devkitA64" ]]; then
  fail "devkitA64 was not found at $DEVKITPRO/devkitA64. Install the Nintendo Switch devkitA64 toolchain."
fi

if [[ ! -d "$DEVKITPRO/libnx" && ! -d "$DEVKITPRO/portlibs/switch" ]]; then
  fail "libnx or Switch portlibs were not found under DEVKITPRO. Install switch-dev/libnx packages."
fi

if [[ ! -d Core || ! -d Common || ! -d GPU ]]; then
  fail "this checkout does not look like a PPSSPP source tree; expected Core/, Common/, and GPU/ directories."
fi

git submodule update --init --recursive

build_dir="$repo_root/build-switch"
rm -rf "$build_dir"
cmake -S "$repo_root" -B "$build_dir" \
  -DCMAKE_TOOLCHAIN_FILE="$DEVKITPRO/cmake/Switch.cmake" \
  -DUSING_QT_UI=OFF \
  -DUSING_X11_VULKAN=OFF \
  -DUSING_EGL=ON \
  -DARM64=ON \
  -DNINTENDO_SWITCH=ON

cmake --build "$build_dir" --parallel "$(getconf _NPROCESSORS_ONLN)"

if [[ -f "$build_dir/PPSSPP.nro" ]]; then
  echo "Nintendo Switch NRO: $build_dir/PPSSPP.nro"
else
  fail "build completed but PPSSPP.nro was not found in $build_dir"
fi
