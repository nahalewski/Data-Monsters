# Getting gen1recomp running on a PSP

## Supported models

| Model | RAM | Status |
| --- | --- | --- |
| PSP-2000 (Slim), **PSP-3000** (incl. 3001), PSP Go (N1000), PSP-E1000 (Street) | 64 MB | **Supported.** Red / Blue / Yellow fit with room to spare (≈8–11 MB of Lua heap in play). Gold runs (verified in PPSSPP on the 64 MB model: 58–60 fps, ≈21 MB heap); Silver should match it; Crystal (≈26 MB) is untested and borderline. |
| PSP-1000 (Phat) | 32 MB | Gen 1 only, and untested: the import and the game need ≈11 MB of Lua heap plus the runtime; Gen 2/3 cannot fit. |
| Any model, official firmware | — | Not possible: homebrew needs custom firmware. |
| FireRed / LeafGreen on any PSP | — | Not possible: the engine needs ≈81 MB for them. |

The build requests the full 64 MB on 2000-series and later hardware
automatically; nothing to configure.

Frame rates measured in PPSSPP with the PSP CPU model at 333 MHz: overworld
~50–60 fps standing, ~30 fps while walking, intro movie 18–25 fps, with
music on. The engine synthesizes music and sound effects sample by sample
in Lua, which the PSP cannot do in real time; this port renders the same
waveforms in C inside the runtime (about 1.3 µs per sample at 22 kHz, a
few percent of the CPU), so **music is on by default**. It can be switched
off on the options page.

The first launch of a freshly imported game converts its data files to Lua
bytecode (a second or two, once) so later boots load faster; a game boots
in about 2 seconds in the emulator. ROM hashes are remembered in
`save/pokemon-love2d/rom_index.lua`, so the launcher only re-hashes files
that changed.

## What you need

1. A PSP on **custom firmware** (6.61 PRO-C / ME / ARK-4 / Infinity 2). If
   the XMB shows a "PRO", "ME" or "ARK" version string under *System
   Settings → System Information*, you are set. Otherwise follow an ARK-4 or
   PRO guide for your model first; on a 3000 that is a two-minute install
   from the Memory Stick.
2. A Memory Stick (or a microSD adapter on a PSP-3000) with about 60 MB free
   per Gen 1 game, 100 MB for a Gen 2 game.
3. Your own canonical US cartridge dump of the game. The launcher verifies
   the SHA-1 and accepts only these:
   - Red `ea9bcae617fdf159b045185467ae58b2e4a48b9a`
   - Blue `d7037c83e1ae5b39bde3c30787637ba1d4c48ce2`
   - Yellow `cc7d03262ebfaf2f06772c1a480c7d9d5f4a38e1`
   - Gold `d8b8a3600a465308c9953dfa04f0081c05bdcb94`
   - Silver `49b163f7e57702bc939d642a18f591de55d92dae`
   - Crystal `f4cd194bdee0d04ca4eac29e09b8e4e9d818c133` (1.0) or
     `f2f52230b536214ef7c9924f483392993e226cfb` (1.1)

   Patched, trimmed, "[b]" or non-US dumps are listed as *Not supported*.

## Install

1. Connect the PSP over USB (*Settings → USB Connection*) or put the Memory
   Stick in a card reader.
2. Copy the `gen1recomp` folder from the zip to `PSP/GAME/` so you have
   `PSP/GAME/gen1recomp/EBOOT.PBP`.
3. Drop your ROM file(s) either **next to `EBOOT.PBP`** or into
   `PSP/GAME/gen1recomp/roms/`. Any file name is fine.
4. Disconnect, go to *Game → Memory Stick* on the XMB and start
   **gen1recomp for PSP**.

## First run

1. The launcher shows a card per game. Cards with a matching ROM say
   **IMPORT**; select one (D-pad or nub) and press **X**.
2. The import decodes your ROM into the engine's private data
   (`save/pokemon-love2d/<game>/`). It takes about **3 minutes for a Gen 1
   game** on the PSP; keep the console awake. It happens once per game.
3. Press **X** again on the (now **READY**) card to play. The card also shows
   your game's own logo once imported.

## Controls

| In game | PSP |
| --- | --- |
| D-pad | D-pad or analog nub |
| A | Cross (swap to Circle in options) |
| B | Circle |
| Start / Select | Start / Select |
| Screen mode | **Select + R** next, **Select + L** previous: NATIVE (160×144), FULLSCREEN (3:2, fills the height), WIDESCREEN (16:9 stretch) |
| Quit | HOME → Exit Game (the game saves as you play, like the original) |

Launcher: D-pad/nub to pick a card, **X** play/import, **Triangle** options,
**Square** rescan for ROMs, **Circle** back.

## Options (Triangle)

- Screen mode / smooth scaling
- Confirm button (Cross = A or Circle = A)
- Music ON/OFF and the music sample rate (22050 Hz default; 44100 Hz
  doubles the synthesizer's cost, 11025 Hz halves it)
- Mods: upstream's example mods and the community mods bundled by
  `tools/fetch_mods.py` (the PSP build takes those up to 1 MB) ship in the
  EBOOT, all **off** by default; toggle them here (X). The change applies
  the next time a game starts. After a boot, `lovepsp.log` has a `mods:`
  line naming each enabled mod's state and any error, so a mod that does
  nothing can be checked there. Enabling many mods costs memory: on a 32 MB
  PSP-1000 keep it to a few. Your own mods go in `save/pokemon-love2d/mods/<mod>/`
  (a folder with `manifest.json`, Lua source only) and appear in the same
  list. Mods that need an extra asset pack (Mystery Dungeon, Link to the
  Past) cannot be used: those packs come from the desktop launcher's
  importers, which are not part of this port. Only get mods from the
  project's official sources (the GitHub repo and its Discord) —
  gen1recomp.com is an impersonating site upstream warns about.
- Delete imported data for the selected game (saves are kept)

Settings persist in `save/pokemon-love2d/psp_options.lua`. Advanced settings
go in `save/pokemon-love2d/env.txt` as `KEY=VALUE` lines
(`LOVEPSP_GAMES=red,blue,yellow` to hide cards, any engine `POKEPORT_*`
variable).

## Saves

`PSP/GAME/gen1recomp/save/pokemon-love2d/` holds saves and imported data in
the same layout as the desktop version of gen1recomp, so a save folder can be
copied between the PSP and a PC. Back it up before deleting the game folder.

## Troubleshooting

- **Nothing happens / the icon is corrupted on the XMB:** the PSP is not on
  custom firmware, or the folder is not directly under `PSP/GAME/`.
- **A card says NO ROM although the file is there:** the dump is not the
  canonical US version (check the SHA-1 above), or the file is not next to
  the EBOOT or in `roms/`. Press Square to rescan after copying.
- **Red screen at start:** the runtime could not start; `lovepsp.log` next to
  the EBOOT says why. Press START to exit.
- **Purple error screen:** an engine error with a traceback, also written to
  `lovepsp.log`. Please attach that file when reporting.
- **Slow:** NATIVE screen mode is slightly cheaper to present than the
  scaled modes; a lower music sample rate in options costs less CPU, and
  Music OFF removes the synthesizer entirely. `lovepsp.log` records boot
  timings (`launcher: ready in`, `game: ... loaded`) and, with
  `LOVEPSP_PROFILE=1` in `save/pokemon-love2d/env.txt`, a per-frame profile.
- **No music, only sound effects:** open the options page (Triangle) and
  check Music is ON; builds before the native synthesizer stored it OFF.
- **Gold/Silver/Crystal fail to load or freeze:** out of memory; these are
  experimental and need a 64 MB model.

## Testing without a PSP

PPSSPP runs the EBOOT: put the `gen1recomp` folder in PPSSPP's memory stick
under `PSP/GAME/`, set *System → PSP model* to PSP-2000/3000 (64 MB), and
launch it from the Games list.
