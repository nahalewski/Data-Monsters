"""Backward-compatible API extension for the upstream Core FastAPI bridge.

Drop-in usage:
    from core_backend_compat.esp32_api_extension import install_esp32_routes
    install_esp32_routes(core_bridge.api, core_bridge_instance)
"""

from __future__ import annotations

from datetime import datetime
from typing import Any

from fastapi import Body, FastAPI


def install_esp32_routes(api: FastAPI, bridge: Any) -> None:
    """Install ESP32-focused endpoints without removing existing desktop/mobile routes."""

    @api.get("/esp32/state")
    def esp32_state() -> dict[str, Any]:
        app = bridge.app
        settings = getattr(app, "settings", {}) or {}
        return {
            "timestamp": datetime.utcnow().isoformat(),
            "screen": settings.get("last_screen", "home"),
            "status_text": getattr(app, "status_text", "Ready"),
            "face_state": getattr(app, "current_state", "happy"),
            "theme": settings.get("current_theme", "prism"),
            "app_order": settings.get(
                "app_order",
                ["core", "learning", "ink", "gallery", "music", "settings", "magic8", "clock", "routines", "calculator"],
            ),
            "storage_hints": {
                "prefer_manifest": "/core/manifests/assets_manifest.json",
                "safe_mode": settings.get("esp32_safe_mode", False),
            },
        }

    @api.post("/esp32/intent")
    def esp32_intent(payload: dict[str, Any] = Body(...)) -> dict[str, Any]:
        intent = payload.get("intent", "none")
        data = payload.get("payload", {})

        if intent == "ptt_start":
            bridge.app.trigger_ptt_start()
        elif intent == "ptt_stop":
            bridge.app.trigger_ptt_stop()
        elif intent == "chat" and isinstance(data, dict):
            text = data.get("text", "")
            if text:
                bridge.app.handle_text_input(text)
        elif intent == "settings_patch" and isinstance(data, dict):
            bridge.app.settings.update(data)
            with open("settings.json", "w", encoding="utf-8") as f:
                import json

                json.dump(bridge.app.settings, f, indent=4)
            bridge.app.reload_settings()

        bridge.log_event(f"ESP32 intent: {intent}")
        return {"status": "ok", "intent": intent}

    @api.get("/esp32/assets/manifest")
    def esp32_assets_manifest() -> dict[str, Any]:
        return {
            "version": 1,
            "generated_at": datetime.utcnow().isoformat(),
            "assets": [
                {"id": "core_icon", "path": "/images/core_app_icon.png", "sha256": "runtime"},
                {"id": "face_happy", "path": "/images/face_happy.png", "sha256": "runtime"},
            ],
        }
