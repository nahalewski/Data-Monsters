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

Player guide with supported models and troubleshooting: [GUIDE-PSP.md](GUIDE-PSP.md).

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
- Music and sound effects: the engine's chip synthesizer renders sample by
  sample in Lua, far too slow for the PSP, so the runtime carries a C port
  of its waveform stage (`runtime/src/apu.c`, hooked in by
  `shell/lovepsp/chipnative.lua`). The song interpreter stays in Lua; the C
  side renders each channel up to its next event and writes the channel
  state back, so output matches the Lua synth (verified against every song
  and effect of Blue, Yellow and Gold). 22 kHz by default; there is no
  worker thread on the PSP, so a song change costs a few frames.
- Loading: after an import the data files of the cache are converted to
  Lua bytecode on first boot (`lovepsp-bytecode` marker in the version
  folder) and ROM hashes are cached in `rom_index.lua`; copying a cache to a
  desktop install afterwards is not supported.
- No online play, save editor or updater; mods have their own page (below).
- Shaders: only the engine's own palette shaders run (as native kernels);
  `SHADERFX`/CRT-style post-processing is unavailable.

Performance on real hardware has not been measured by the build machine.
The engine is drawn at 160x144 on the CPU and scaled by the display driver,
which is what makes the CPU rasterizer feasible on a 333 MHz MIPS core.
`lovepsp.log` next to the EBOOT records errors and load timings.

## Mods

Upstream's example mods ship in the archive, all off by default; toggle
them on the launcher's Mods page (Triangle > Mods, X toggles). A toggle sets
the shared flag and clears the per-game overrides the desktop launcher
writes, so the card's state is what the game loads; `lovepsp.log` lists the
loaded mods and any loader error after each boot (`mods:` line).

Community mods come from their authors' GitHub repositories, as listed by
the project's official mod index, never from gen1recomp.com (upstream's
README calls that site unaffiliated and untrustworthy):

```sh
python3 psp/tools/fetch_mods.py psp/mods_extra      # 160 of 197 index entries
bash psp/build.sh                                    # PSP: mods up to 1 MB each
bash psp/ports/vita/build.sh                         # Vita/PS3: all fetched mods
```

`mods_extra/` is gitignored (each mod carries its own licence) and
`FETCH-REPORT.txt` lists what was skipped: mods that need the network, a
voxel renderer, or more than 8 MB of assets. Of the 171 mods in a full
build, 148 initialise cleanly on Yellow; the rest are Gen 2 only, depend on
a mod that is not there, need the desktop launcher's asset packs, or use
GLSL shaders. The Dramatic Shape voxel mod and the ShaderFX presets cannot
run here: both are GPU shader renderers and this runtime rasterises on the
CPU with the engine's palette shaders built in (ShaderFX also downloads its
presets at runtime; the consoles have no network access in this port).

### Updating mods from GitHub (Vita, Android)

The MODS panel in a game has an **UPDATE FROM GITHUB** button. It fetches
the official mod index feed, compares each installed mod's version with
the latest release listed there, downloads the release zip from the
author's GitHub repository, unpacks it into `save/pokemon-love2d/mods/`
(which shadows the copy inside the archive) and offers APPLY to restart
into the game with the new versions. Nothing is ever fetched from
gen1recomp.com. Downloads use the console's own TLS stack (sceHttp on the
Vita); the PSP and PS3 have no network support in this port.

A GitHub token is optional and only needed for repositories that require
one. Put it next to your ROMs as `github_token.json`
(`{"token": "ghp_..."}`) or `github_token.txt`; it is read at update time,
sent as the `Authorization` header, and never copied anywhere else. Keep
that file off anything you share.

### Controller navigation (Vita, Razer Kishi, any pad)

The panels are driven from the pad as well as by touch; the INSTRUCTIONS
row at the bottom of the MODS panel shows this in the app:

| Button | Does |
| --- | --- |
| START | open / close the MENU panel (replaces the game's START menu) |
| SELECT | open / close the MODS panel |
| Right stick, R1, R2 | move in the MENU panel, select, back |
| Left stick, L1, L2 | move in the MODS panel, toggle / select, back |
| D-pad, X, O | keep playing the game while a panel is open |
| Select + R / Select + L | screen mode |

**THEME**, a row at the bottom of the MODS panel, recolours both panels in
a Game Boy text-box style (double-line border, square rows, the pixel
font) to match a game: Game Boy green, Red, Green, Blue, Yellow, Gold,
Silver, Crystal, FireRed or LeafGreen; AUTO (the default) follows the game
being played. The choice is saved with the port's options.

On the Vita the drawn on-screen D-pad/A/B is off (the console has real
buttons); taps on panel rows still work. Text that does not fit a side
panel row scrolls sideways (marquee) on the highlighted row. The "On-screen pad" option turns
it on, and Android has it on by default.

### Screen layouts

`Screen layout` on the options page: **SINGLE** (the game with the touch
pad beside it) or **DS** (a double-height screen: the game in the top
half, the touch pad and the MODS / MENU buttons in the bottom half; an open
panel takes the whole bottom half). The Android app also has a **dual**
mode in which the main display shows only the game and a second display
shows the bottom half.

On Android foldables only (the DS layout the hinge sensor selects) a
**3DS skin** (`shell/assets/skin3ds`, art supplied by the port's author)
turns the phone into a 3DS. Both shells fill the width of the screen and
meet at the hinge (the logical screen becomes 480x680: top shell 480x320,
bottom shell 480x360). The game sits in the top screen; START opens the
MENU and SELECT the MODS panel in the bottom screen, each closing the
other; the button sprites drawn into the bottom shell's sockets (D-pad,
circle pad, A/B/X/Y, START, SELECT, HOME opening the MENU) are the touch
controls, a pressed one drawn darker and nudged. There are no floating
buttons in this mode. When the app starts on a foldable that is not yet
open, the closed lid ("Unfold to Play") fills the screen until the phone
is unfolded, or any button or tap, and then the launcher appears. The
Vita and the PS3 never show the skin.
"DS skin" on the options page picks the top frame: **G1R sticker with the
Game Boy Color border** (default), the plain sticker frame, a plain frame,
a small-screen frame, or OFF for the bare layout.

## Other consoles

The same runtime builds for the **PS Vita / Vita TV** (`ports/vita`, SDL2
on vitasdk, `.vpk`) and the **PS3** (`ports/ps3`, SDL2 on PSL1GHT, `.pkg` for
CFW/HEN and RPCS3 plus a `GEN1RECMP/` folder for `/dev_hdd0/game/`).

The Vita build is a native Vita application (ARM, vitasdk), not the PSP
EBOOT under the Vita's PSP emulator; Vita3K runs it as such. It has touch
controls: an on-screen D-pad, A/B and START/SELECT beside the game
(`runtime/src/touch.c`), taps on the launcher's cards and rows, and, in a
game, two floating buttons that appear when the screen is touched. The
left one slides in a MODS panel (toggle mods, APPLY restarts the game with
them), the right one a menu that replaces the game's START menu: POKeMON,
ITEM, the trainer card, SAVE, GAME OPTION (the engine's options), OPTIONS
(this port's settings), MODS and QUIT (back to the launcher). The game
shrinks between open panels and keeps running under the physical
controls; START toggles the menu. Gen 1 rows are the engine's own START
menu items, so rows mods add appear too; Gen 2 keeps its START menu, opened
from the panel. `shell/lovepsp/vitaui.lua` draws the panels into a canvas
the runtime composites over the presented frame (`lovepsp.setOverlay`).
If sound stops after Vita3K goes to the background and back, the runtime
reopens its audio device when the app regains focus.

### Android

On a foldable held open, the launcher itself is the 3DS: the selected
game's cartridge on the top screen (`shell/assets/carts`, art supplied by
the port's author; left / right or the stick changes the game, tapping the
cart or X plays or imports it) and a tabbed panel on the bottom screen
(`shell/lovepsp/foldui.lua`): **GAMES** (status, save, update check,
rescan), **MODS** (toggle the installed mods), **FIND** (browse the
official mod index and install or update mods from their authors'
releases), **ONLINE** (not part of this port) and **IMPORT** (where ROMs
go, import the selected game). L / R switch tabs, X activates, O returns
to GAMES. The update check reads the latest release of
https://github.com/nahalewski/gen1recomp-Fold (the port's own repository;
`VERSION` is the installed version) and, when a newer tag exists, opens
that release page in the browser.  The panel follows the G1R Deluxe
launcher's look: the logo and the swap-game / settings / quit icons on
top, icon tabs (the GAMES tab shows the selected game's letter), outlined
cards, and a footer with the BOIS CLUB credit, the update button and the
release notes.  The gear (or START) opens the settings modal with the
launcher's option rows as steppers and an Instructions page.

The app is its own package, `com.nahalewski.g1rports` ("G1R Ports"), so
installing it never touches or updates the official gen1recomp app.
`ports/android/build.sh` builds `dist/android/gen1recomp.apk` with the
Android SDK's own tools (aapt2, d8, apksigner; no Gradle) from the same
runtime under SDL2 (`SDL_DIR` points at an SDL 2.30 checkout, `ANDROID_SDK`
and `ANDROID_NDK` at the SDK and NDK r26). ROMs go in
`/sdcard/Android/data/com.nahalewski.g1rports/files/` (or `roms/` under
it); saves and the mod folder live under it too. The activity
(`ports/android/java`) decides the layout: a second display (dual-screen
phones, an external screen) gets the bottom half through a Presentation
while the main display shows the game; a foldable held half-open in
landscape (hinge angle sensor, Android 11+) switches to the DS layout;
otherwise the single-screen touch layout. The launcher's Screen layout
option overrides that. The APK has not been run on a device from this
machine: an emulator cannot run in this environment, so the first run on
hardware may need fixes.
`build_all.sh` (or `build_all.bat` on Windows) builds every target whose
toolchain is installed and zips them into `dist/gen1recomp-ports.zip`. The
PS3 build packs Lua source instead of bytecode (big-endian PPU). Neither
console build has been run on hardware or an emulator from this machine;
the PSP build has (PPSSPP).

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
