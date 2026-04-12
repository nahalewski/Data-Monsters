# SD Card Preparation and Runtime Policy

## Required folder structure
```text
/core/assets/images
/core/assets/audio
/core/assets/animations
/core/data/memory
/core/data/settings
/core/data/cache
/core/data/logs
/core/manifests
/core/update
/core/offline
```

A template is included in `core_esp32_frontend/sdcard_template/`.

## First boot behavior
1. Mount SD card.
2. Run integrity check.
3. Auto-create missing folders.
4. Create `/core/manifests/assets_manifest.json` if absent.
5. If any critical step fails, switch to minimal-asset mode and warn in UI.

## What lives on SD
- Images, audio clips, music, animations.
- Memory snapshots and logs.
- Downloaded asset bundles and optional offline mirrors.

## What stays internal (NVS / flash)
- Wi-Fi credentials.
- Pairing metadata.
- Minimal safe boot config.
- SD health and last-known-safe settings.

## Cache strategy
- Prefer streaming large assets from SD.
- Cache indexes in small internal metadata.
- Evict least-recently-used or stale entries when thresholds are exceeded.
