from __future__ import annotations

import httpx


class RemoteAssistantClient:
    def __init__(self, base_url: str) -> None:
        self.base_url = base_url.rstrip("/")

    async def trigger_briefing(self, user_name: str) -> dict:
        async with httpx.AsyncClient(timeout=60) as client:
            response = await client.post(f"{self.base_url}/remote/trigger-briefing", json={"user_name": user_name})
            response.raise_for_status()
            return response.json()
