# Build and Flash Instructions

## Prerequisites
- ESP-IDF v5.x installed.
- USB serial access to ESP32-S3 board.
- LVGL + display/touch drivers configured in your ESP-IDF environment.

## Build
```bash
cd core_esp32_frontend
idf.py set-target esp32s3
idf.py build
```

## Flash
```bash
cd core_esp32_frontend
idf.py -p /dev/ttyUSB0 flash monitor
```

## Notes for Waveshare ESP32-S3 Touch AMOLED 1.75
- Resolution: 466x466 round display.
- Verify panel/touch wiring in BSP or board support component.
- Enable PSRAM and validate LVGL buffer allocation at boot.
