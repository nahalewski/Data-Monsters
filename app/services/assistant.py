from __future__ import annotations

import asyncio
import contextlib
import logging

from app.services.briefing import BriefingService
from app.services.calendar import GoogleCalendarService
from app.services.persistence import TriggerStore
from app.services.remote import RemoteAssistantClient
from app.services.speech import PiperSpeechService
from app.services.time_gate import MorningGate
from app.services.weather import OpenWeatherMapService
from app.state_manager import FaceStateManager

logger = logging.getLogger(__name__)


class MorningAssistant:
    def __init__(
        self,
        mode: str,
        state_manager: FaceStateManager,
        trigger_store: TriggerStore,
        morning_gate: MorningGate,
        briefing_service: BriefingService,
        weather_service: OpenWeatherMapService,
        calendar_service: GoogleCalendarService,
        speech_service: PiperSpeechService,
        remote_client: RemoteAssistantClient | None = None,
    ) -> None:
        self.mode = mode
        self.state_manager = state_manager
        self.trigger_store = trigger_store
        self.morning_gate = morning_gate
        self.briefing_service = briefing_service
        self.weather_service = weather_service
        self.calendar_service = calendar_service
        self.speech_service = speech_service
        self.remote_client = remote_client
        self._briefing_lock = asyncio.Lock()

    async def handle_recognized_user(self, user_name: str) -> None:
        async with self._briefing_lock:
            last_trigger = self.trigger_store.get_last_trigger_iso()
            if not self.morning_gate.can_trigger(last_trigger):
                logger.info("Greeting skipped: outside window or cooldown not elapsed.")
                return
            self.trigger_store.set_last_trigger_now()

            if self.mode == "remote" and self.remote_client:
                await self.state_manager.set_expression("thinking")
                await self.remote_client.trigger_briefing(user_name)
                await self.state_manager.set_expression("idle")
                return

            await self._run_local_briefing(user_name)

    async def _run_local_briefing(self, user_name: str) -> None:
        await self.state_manager.set_expression("smile")

        weather = await self.weather_service.get_today_weather()
        events = await asyncio.to_thread(self.calendar_service.get_today_events)
        briefing = self.briefing_service.compose(user_name=user_name, weather=weather, events=events)

        talk_task = asyncio.create_task(self._animate_talking())
        try:
            await self.speech_service.speak(briefing.text)
        finally:
            talk_task.cancel()
            with contextlib.suppress(asyncio.CancelledError):
                await talk_task
            await self.state_manager.set_expression("idle")

    async def remote_trigger(self, user_name: str) -> dict:
        await self._run_local_briefing(user_name)
        return {"status": "ok", "user_name": user_name}

    async def _animate_talking(self) -> None:
        states = ["talking_1", "talking_2"]
        idx = 0
        while True:
            await self.state_manager.set_expression(states[idx % 2])
            idx += 1
            await asyncio.sleep(0.2)
