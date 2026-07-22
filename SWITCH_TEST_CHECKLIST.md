# Nintendo Switch PPSSPP Runtime Test Checklist

Use this checklist on real Nintendo Switch hardware after the PPSSPP 1.20.4 Switch port compiles and packages an NRO.

## Launch and environment

- [ ] Launch from Homebrew Menu.
- [ ] Launch using title override/full-memory mode.
- [ ] Confirm applet mode behavior is documented if unsupported.
- [ ] Confirm clean exit returns to Homebrew Menu.

## UI and filesystem

- [ ] Main menu renders correctly.
- [ ] Game browser opens.
- [ ] SD card file access works.
- [ ] Configuration path is created and writable.
- [ ] Save-data path is created and writable.

## Game loading

- [ ] Launch an ISO.
- [ ] Launch a CSO.
- [ ] Create an in-game save.
- [ ] Load an in-game save.
- [ ] Create a save state.
- [ ] Load a save state.

## Input

- [ ] Built-in handheld controls work.
- [ ] Detached Joy-Con input works.
- [ ] Pro Controller input works.
- [ ] Touchscreen input works.
- [ ] Controller reconnect behavior works.

## Audio

- [ ] Audio initializes.
- [ ] Audio remains synchronized during gameplay.
- [ ] Audio recovers after suspend/resume.

## Display and graphics

- [ ] Handheld mode renders at expected resolution.
- [ ] Docked mode renders at expected resolution.
- [ ] VSync/frame pacing is acceptable.
- [ ] Graphics backend remains stable in menus.
- [ ] Graphics backend remains stable in gameplay.
- [ ] Shader compilation works.
- [ ] Texture upscaling works, if enabled.

## Lifecycle

- [ ] Suspend works from menu.
- [ ] Resume works from menu.
- [ ] Suspend works during gameplay.
- [ ] Resume works during gameplay.

## CPU/JIT

- [ ] Interpreter mode compiles and launches a game.
- [ ] ARM64 JIT mode compiles and launches a game.
- [ ] JIT cache invalidation does not crash after gameplay transitions.

## Networking

- [ ] Ad-hoc networking works, if supported by the Switch port.
- [ ] Unsupported networking features fail gracefully and are documented.

## Performance

- [ ] Compare performance against the known-good 1.17.1 Switch build.
- [ ] Record tested game, backend, mode, and approximate FPS.
