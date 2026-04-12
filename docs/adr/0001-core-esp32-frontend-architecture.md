# ADR-0001: Core ESP32 Frontend as Thin UI + Device Services Client

- **Status:** Accepted
- **Date:** 2026-04-12

## Context
The upstream `nahalewski/Core` project centers around a Python/FastAPI + web UI stack with local MLX inference and desktop/mobile surfaces. The target hardware (Waveshare ESP32-S3 Touch AMOLED 1.75, 466x466 round panel) cannot host MLX/Python backend workloads.

## Decision
1. Build a new additive target `core_esp32_frontend/` in ESP-IDF + LVGL.
2. Preserve original behavior by introducing a companion protocol to existing backend routes and adding minimal backward-compatible API extensions under `/esp32/*`.
3. Use microSD for large/non-critical assets and logs; keep Wi-Fi/pairing/minimal safe settings in NVS.
4. Keep UI architecture componentized (runtime, protocol, storage, event bus) to mirror original modularity.
5. Support SD fault tolerance (manifest bootstrap, folder repair, minimal asset fallback, read-only safe mode).

## Rationale
- Keeps desktop/mobile and existing Python workflows intact.
- Avoids impossible on-device compute while preserving end-user experience.
- Enables gradual parity improvements without invasive rewrites.

## Consequences
- ESP32 frontend requires active companion backend for full conversational parity.
- Some visual and animation fidelity is approximated due to memory and GPU constraints.
- Additional maintenance path: protocol contract between Python backend and embedded client.
