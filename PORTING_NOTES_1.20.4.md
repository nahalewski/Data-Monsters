# PPSSPP Nintendo Switch Porting Notes: 1.17.1 to 1.20.4

## Source and target commit hashes

- Current repository HEAD inspected: `6bc6d5c306572c4ccc980fe3aa53a7edfc286368`.
- Requested Switch-port base: PPSSPP 1.17.1 Nintendo Switch port.
- Requested target: official PPSSPP 1.20.4.

The PPSSPP commit hashes could not be identified in this checkout because it does not contain PPSSPP history, PPSSPP tags, or Nintendo Switch PPSSPP source files.

## Repository inspection result

The checkout contains a web/ESP32-oriented project with files such as `server.js`, `package.json`, `label-app/index.html`, and `core_esp32_frontend/`. It does not contain recognizable PPSSPP directories such as `Core/`, `GPU/`, `UI/`, `Common/`, `SDL/`, or Nintendo Switch packaging files.

## Update strategy used

No source transplant or rebase was performed because there is no PPSSPP source tree in this repository. The safe action was to create documentation and a guard-railed build script that records the blocker and prevents misleading build claims.

## Switch-specific commits retained

None found in this repository.

## Diff summary requested before code changes

Unable to produce a diff between PPSSPP 1.17.1 and the Switch port because neither the upstream PPSSPP 1.17.1 tag nor the Switch port branch exists in this checkout.

## Categorized Switch-specific files

None found in this repository.

Expected categories once the correct repository is available:

- Build system: CMake toolchain files, Switch Makefiles, NRO packaging scripts.
- Platform layer: Horizon/libnx initialization, applet lifecycle, filesystem mounting.
- Input: Joy-Con, Pro Controller, handheld controls, touchscreen.
- Audio: libnx audio output integration.
- Graphics: EGL/OpenGL ES or deko3d context handling.
- JIT and memory: ARM64 executable-memory allocation, cache maintenance, virtual memory APIs.
- Packaging/assets: icon, nacp metadata, romfs/assets layout.

## Switch-specific changes inside shared upstream files

None found in this repository.

## Commits that appear to contain Nintendo Switch-specific work

None found in this repository history. The visible history contains application and ESP32/frontend work, not PPSSPP Switch work.

## Likely conflict areas between PPSSPP 1.17.1 and 1.20.4

These areas must be audited in the actual PPSSPP repository:

- NativeApp lifecycle and platform entry-point APIs.
- GraphicsContext and DrawContext interface changes.
- ARM64 JIT cache allocation and executable memory APIs.
- Cache flush functions after JIT code generation.
- Filesystem/user path abstraction changes.
- Controller device IDs, axis handling, and touch input mapping.
- Audio callback and buffer interface changes.
- SDL2/SDL3 related source list and dependency changes.
- Vulkan exclusion for Nintendo Switch builds.
- Third-party submodule version and source layout changes.

## Proposed porting sequence

1. Check out the actual PPSSPP Switch 1.17.1 branch and record its commit hash.
2. Add/fetch the official PPSSPP upstream remote and verify the 1.20.4 tag.
3. Generate a full Switch-specific diff against upstream 1.17.1.
4. Create `switch-1.20.4-port` from upstream 1.20.4.
5. Transplant Switch build files and assets first.
6. Port platform, input, audio, filesystem, graphics, and lifecycle code in separate commits.
7. Port ARM64 JIT and executable-memory handling in a separate commit.
8. Build, fix compile errors by mapping old APIs to current 1.20.4 APIs, and document each fix.
9. Package NRO and run device testing checklist.

## Unresolved problems

- Correct PPSSPP source repository is not present.
- PPSSPP upstream tags are not present.
- Switch-specific port commits are not present.
- No compile attempt can produce `PPSSPP.nro` from this checkout.

## Files intentionally modified

- `README_SWITCH.md`
- `PORTING_NOTES_1.20.4.md`
- `SWITCH_TEST_CHECKLIST.md`
- `SWITCH_PORT_PROGRESS.md`
- `scripts/build-switch.sh`
