# Core ESP32 Frontend (Waveshare ESP32-S3 Touch AMOLED 1.75)

ESP-IDF + LVGL front-end runtime that preserves Core's circular launcher/app flow while delegating heavy AI logic to the existing Python backend.

## Goals
- Keep original Core UX metaphors (round launcher, Core face states, app tiles, status ring).
- Keep backend intelligence off-device (MLX/Python/voice synthesis remain companion-side).
- Treat ESP32 as a resilient local UI + device-services client.

## Build Quickstart
```bash
cd core_esp32_frontend
idf.py set-target esp32s3
idf.py build
idf.py -p /dev/ttyUSB0 flash monitor
```

See `../docs/esp32/build_and_flash.md` and `../docs/esp32/sd_card_layout.md` for full instructions.
