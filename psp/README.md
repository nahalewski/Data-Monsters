# gen1recomp for PSP

An unofficial port of the Gen 1 engine from
[bryanthaboi/gen1recomp](https://github.com/bryanthaboi/gen1recomp) to the
Sony PSP, delivered as a single homebrew `EBOOT.PBP`.

Based on the Pokemon Gen 1 Recompilation Project by BOIS CLUB GAMES, LLC
(https://github.com/bryanthaboi/gen1recomp).

gen1recomp is a LÖVE2D (Lua) game. The PSP cannot run LÖVE, LuaJIT or GLSL,
so this port ships **lovepsp**: a small LÖVE 11-compatible runtime written in
C for the PSP, running Lua 5.4 with a CPU rasterizer that reproduces the
engine's palette shaders. The engine's Lua code runs unmodified; it is fetched
from upstream at build time, compiled to bytecode and packed into the
EBOOT's `DATA.PSAR`.

## Installing

1. Copy the `gen1recomp/` folder from a release (or `psp/dist/gen1recomp`
   after building) to `ms0:/PSP/GAME/` on a PSP with custom firmware.
2. Put your own canonical US cartridge dump next to the `EBOOT.PBP` (or in
   `roms/` under it); any file name works, games are recognised by SHA-1.
   Only the dumps upstream accepts are recognised — Red, Blue, Yellow, Gold,
   Silver, Crystal, FireRed and LeafGreen (US) — and no game data ships with
   the port. Anything else (Emerald, Ruby, Sapphire, Green, ROM hacks,
   other regions) is listed as "Not supported" on the launcher: the engine
   has no support for those games.
3. Launch **gen1recomp for PSP** from the XMB. The launcher shows one
   cartridge card per game: move between them with the D-pad or nub and
   press **X** to import (once per game — it decodes the ROM into the
   engine's private cache under `save/pokemon-love2d/<version>/`; about
   three minutes for a Gen 1 game on the PSP), then **X** again to play.
   After an import the card shows the game's own logo and mascot, decoded
   from your ROM. **Triangle** opens the options page (screen mode,
   smoothing, confirm button, music on/off, music sample rate, delete
   imported data); **Square** rescans for ROMs.

Saves live in `PSP/GAME/gen1recomp/save/pokemon-love2d/`, in the same layout
as the desktop build.

### Controls

| Game Boy | PSP |
| --- | --- |
| D-pad | D-pad / analog nub |
| A | Cross |
| B | Circle |
| Start | Start |
| Select | Select |
| screen mode | Select + R (next) / Select + L (previous), anywhere; also on the options page |

The options page persists to `save/pokemon-love2d/psp_options.lua`.
`save/pokemon-love2d/env.txt` (KEY=VALUE lines) overrides the engine's
`POKEPORT_*` settings and the port's own:

- `LOVEPSP_GAMES=red,blue,yellow,firered` — which cards to offer. Only Gen 1
  fits the PSP: FireRed imports and boots under this runtime on a desktop,
  but its Lua heap is ~81 MB after loading (Blue: 8.7 MB) on top of a
  141 MB cache, more than the console's 32/64 MB of RAM.
- `LOVEPSP_AUTOIMPORT=blue` — start that import at boot (for emulator runs
  without input injection). `autoboot.txt` containing a version name boots
  it directly.

Screen modes: **NATIVE** (160x144 at 1x), **FULLSCREEN** (default: fills the
height, 3:2 aspect with side bars) and **WIDESCREEN** (stretched to the
full 16:9 panel).

## What works / what does not

- Red, Blue and Yellow: import, intro, title, new game, overworld, battles
  and saving run through the upstream Gen 1 engine.
- Gold/Silver/Crystal/FireRed/LeafGreen are not offered: their caches and
  engines do not fit the PSP's memory.
- Music and sound effects are synthesized by the engine's Lua chip
  synthesizer at 22 kHz. There is no worker thread on the PSP, so a song
  change costs a few frames.
- No online play, mods panel, save editor, updater or touch controls.
- Shaders: only the engine's own palette shaders run (as native kernels);
  `SHADERFX`/CRT-style post-processing is unavailable.

Performance on real hardware has not been measured by the build machine.
The engine is drawn at 160x144 on the CPU and scaled by the display driver,
which is what makes the CPU rasterizer feasible on a 333 MHz MIPS core.
`lovepsp.log` next to the EBOOT records errors and load timings.

## Building

Requirements: bash, python3, gcc + SDL2 dev headers (host tools), and the
[pspdev](https://github.com/pspdev/pspdev) toolchain (`psp-gcc`,
`mksfoex`, `pack-pbp` on `PATH`, or the `pspdev/pspdev` Docker image).

```sh
python3 psp/runtime/tools/mkicons.py psp/psp-assets   # XMB icon + background
bash psp/build.sh                                      # -> psp/dist/gen1recomp/EBOOT.PBP
bash psp/build.sh --host-only                          # just game.pak, for the desktop runtime
```

`build.sh` clones upstream `main` (override with `--ref` or
`--upstream DIR`). The upstream launcher files listed in its LICENSE term 2
are proprietary ("may not be copied, modified, redistributed, or used in any
fork"), so they are excluded and cannot be added back; `shell/main.lua` is
this port's own controller-driven front end and carries the credit the
licence requires.

### Testing without a PSP

`runtime/Makefile.host` builds the same runtime against SDL2:

```sh
make -C psp/runtime -f Makefile.host
mkdir -p /tmp/pspgame/roms && cp your-blue.gb /tmp/pspgame/roms/
LOVEPSP_BASE=/tmp/pspgame LOVEPSP_ARCHIVE=psp/build/game.pak psp/runtime/build/host/lovepsp
```

Headless scripted runs (used by CI): `LOVEPSP_HEADLESS=1`, `LOVEPSP_FRAMES=N`,
`LOVEPSP_SHOT=frame:out.png`, `LOVEPSP_INPUT=frame:button:frames,...`.
`runtime/test/smoke/` is a self-check of the runtime's API surface.

## Layout

```
psp/
  build.sh            fetch upstream, assemble, compile, pack, EBOOT
  shell/              this port's launcher (conf.lua, main.lua, lovepsp/env.lua)
  runtime/            lovepsp: src/*.c (C runtime), lua/boot.lua (Lua side),
                      Makefile (PSP), Makefile.host (SDL2), tools/, test/
  third_party/        Lua 5.4.6 (MIT), stb (public domain), font8x8 (public domain)
  psp-assets/         generated ICON0.PNG / PIC1.PNG
```

## Licence

The runtime and shell in this directory are released under the GPLv3, the
same licence as the gen1recomp engine they are built to run. See the upstream
`LICENSE.MD` (bundled as `LICENSE-gen1recomp.md` inside the archive). This
project contains no ROM data and no extracted game content.
