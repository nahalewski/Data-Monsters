from __future__ import annotations

import json
from datetime import datetime
from pathlib import Path


class TriggerStore:
    def __init__(self, path: Path) -> None:
        self.path = path
        self.path.parent.mkdir(parents=True, exist_ok=True)

    def get_last_trigger_iso(self) -> str | None:
        if not self.path.exists():
            return None
        data = json.loads(self.path.read_text())
        return data.get("last_trigger_iso")

    def set_last_trigger_now(self) -> None:
        payload = {"last_trigger_iso": datetime.utcnow().isoformat()}
        self.path.write_text(json.dumps(payload, indent=2))


class EnrollmentStore:
    def __init__(self, path: Path) -> None:
        self.path = path
        self.path.parent.mkdir(parents=True, exist_ok=True)

    def load(self) -> dict:
        if not self.path.exists():
            return {"users": []}
        return json.loads(self.path.read_text())

    def save(self, data: dict) -> None:
        self.path.write_text(json.dumps(data, indent=2))
