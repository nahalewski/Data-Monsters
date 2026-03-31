from __future__ import annotations

import asyncio
from datetime import datetime

from app.models import FaceState


class FaceStateManager:
    def __init__(self) -> None:
        self._state = FaceState(expression="idle")
        self._lock = asyncio.Lock()

    async def set_expression(self, expression: str) -> FaceState:
        async with self._lock:
            self._state = FaceState(expression=expression, updated_at=datetime.utcnow())
            return self._state

    async def get_state(self) -> FaceState:
        async with self._lock:
            return self._state
