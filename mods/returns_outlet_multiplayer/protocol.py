"""Protocol primitives for the Returns Outlet Simulator multiplayer mod."""
from __future__ import annotations

from dataclasses import dataclass, field
import json
import time
from typing import Any, Dict, Iterable, List, Optional

MAX_PLAYERS = 8
DEFAULT_TICK_RATE_HZ = 20


class ProtocolError(ValueError):
    """Raised when a client sends an invalid protocol message."""


@dataclass
class Player:
    id: str
    name: str
    ready: bool = False
    x: float = 0.0
    y: float = 0.0
    rotation: float = 0.0
    last_seen: float = field(default_factory=time.time)

    def snapshot(self) -> Dict[str, Any]:
        return {
            "id": self.id,
            "name": self.name,
            "ready": self.ready,
            "x": self.x,
            "y": self.y,
            "rotation": self.rotation,
        }


@dataclass
class Pallet:
    id: str
    category: str
    estimated_value: int
    claimed_by: Optional[str] = None

    def snapshot(self) -> Dict[str, Any]:
        return {
            "id": self.id,
            "category": self.category,
            "estimated_value": self.estimated_value,
            "claimed_by": self.claimed_by,
        }


def encode_message(kind: str, **payload: Any) -> bytes:
    return (json.dumps({"type": kind, **payload}, separators=(",", ":")) + "\n").encode("utf-8")


def decode_message(raw: bytes | str) -> Dict[str, Any]:
    if isinstance(raw, bytes):
        raw = raw.decode("utf-8")
    try:
        message = json.loads(raw)
    except json.JSONDecodeError as exc:
        raise ProtocolError(f"invalid json: {exc.msg}") from exc
    if not isinstance(message, dict) or not isinstance(message.get("type"), str):
        raise ProtocolError("message must be an object with a string type")
    return message


def default_pallets() -> List[Pallet]:
    categories = ["electronics", "home", "apparel", "tools", "toys", "kitchen"]
    return [
        Pallet(id=f"PALLET-{index + 1:03d}", category=category, estimated_value=150 + index * 75)
        for index, category in enumerate(categories)
    ]


def lobby_snapshot(players: Iterable[Player], pallets: Iterable[Pallet]) -> Dict[str, Any]:
    return {
        "players": [player.snapshot() for player in players],
        "pallets": [pallet.snapshot() for pallet in pallets],
        "server_time": time.time(),
    }
