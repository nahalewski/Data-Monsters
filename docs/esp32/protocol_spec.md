# Core Companion Protocol Spec (Backend ↔ ESP32)

## Transport
- **State stream:** HTTP poll (`GET /esp32/state`) every 250-500ms (MVP).
- **Realtime option:** WebSocket (`/esp32/ws`) for future push events.
- **User intents:** HTTP POST (`/esp32/intent`).
- **Asset manifest:** HTTP GET (`/esp32/assets/manifest`).

## 1. GET /esp32/state
### Response
```json
{
  "timestamp": "2026-04-12T00:00:00Z",
  "screen": "home",
  "status_text": "Ready: Core",
  "face_state": "happy",
  "theme": "prism",
  "app_order": ["core", "learning", "ink", "gallery", "music", "settings", "magic8", "clock", "routines", "calculator"],
  "storage_hints": {
    "prefer_manifest": "/core/manifests/assets_manifest.json",
    "safe_mode": false
  }
}
```

## 2. POST /esp32/intent
### Request
```json
{
  "intent": "chat",
  "payload": {
    "text": "Can we do math practice?"
  }
}
```

### Canonical intents
- `ptt_start`
- `ptt_stop`
- `chat`
- `open_app`
- `settings_patch`
- `sync_request`

### Response
```json
{ "status": "ok", "intent": "chat" }
```

## 3. GET /esp32/assets/manifest
### Response
```json
{
  "version": 1,
  "generated_at": "2026-04-12T00:00:00Z",
  "assets": [
    { "id": "core_icon", "path": "/images/core_app_icon.png", "sha256": "..." }
  ]
}
```

## Error Handling
- If backend unavailable: ESP32 enters offline-safe mode, displays last-known snapshot and local safe settings.
- If SD absent/corrupt: fallback to built-in assets + warning banner.
- If manifest missing: create default manifest and queue sync request.
