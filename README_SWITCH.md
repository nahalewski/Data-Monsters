# Nintendo Switch PPSSPP 1.20.4 Port

## Project status

This repository does not currently contain a PPSSPP source tree, PPSSPP tags, Nintendo Switch platform files, or upstream PPSSPP remotes. The requested PPSSPP 1.17.1-to-1.20.4 port is therefore blocked until the correct PPSSPP Switch port repository, or the PPSSPP upstream source tree plus the existing Switch port history, is provided.

No Nintendo Switch runtime functionality has been claimed or validated from this repository.

## Intended PPSSPP base version

Target upstream release: PPSSPP 1.20.4.

## Supported Nintendo Switch environments

To be confirmed after the correct source tree is available. The intended target is Nintendo Switch homebrew using current devkitPro, devkitA64, and libnx.

## Prerequisites

Install devkitPro and the Nintendo Switch toolchain. Typical required packages are expected to include:

```sh
sudo dkp-pacman -S switch-dev switch-tools switch-glad switch-mesa switch-sdl2 switch-zlib switch-libpng switch-freetype
```

The exact package list must be verified against the actual PPSSPP Switch build system.

## Environment

```sh
export DEVKITPRO=/opt/devkitpro
export DEVKITARM="$DEVKITPRO/devkitARM"
export DEVKITA64="$DEVKITPRO/devkitA64"
```

## Submodules

After the correct PPSSPP repository is available, initialize submodules with:

```sh
git submodule update --init --recursive
```

## Build commands

A reproducible build script is included at `scripts/build-switch.sh`. It currently performs environment and repository validation and intentionally stops if PPSSPP source files are not present.

```sh
scripts/build-switch.sh
```

## Output folder

Expected final output after the real port is completed:

```text
build-switch/PPSSPP.nro
```

## SD card installation layout

Expected layout:

```text
/switch/PPSSPP/PPSSPP.nro
/switch/PPSSPP/assets/
/switch/PPSSPP/icon.jpg
```

## Title override/full-memory recommendation

PPSSPP should be launched using title override/full-memory mode when running games that need more memory than applet mode provides.

## Known issues

- This checkout is not a PPSSPP source tree.
- No upstream PPSSPP 1.17.1 or 1.20.4 tags are present locally.
- No Nintendo Switch PPSSPP platform implementation is present locally.
- No NRO can be generated from this repository in its current state.

## Runtime testing status

Not tested on hardware. Runtime validation must be performed after the actual PPSSPP Switch source tree is available and builds successfully.
