from __future__ import annotations

import asyncio
import logging
from pathlib import Path

from fastapi import FastAPI, HTTPException
from fastapi.responses import FileResponse
from fastapi.staticfiles import StaticFiles
from pydantic import BaseModel

from app.services.assistant import MorningAssistant
from app.services.briefing import BriefingService
from app.services.calendar import GoogleCalendarService
from app.services.persistence import EnrollmentStore, TriggerStore
from app.services.remote import RemoteAssistantClient
from app.services.speech import PiperSpeechService
from app.services.time_gate import MorningGate
from app.services.vision import FaceRecognizer, VisionLoop
from app.services.weather import OpenWeatherMapService
from app.settings import settings
from app.state_manager import FaceStateManager

logging.basicConfig(level=getattr(logging, settings.log_level.upper(), logging.INFO))
logger = logging.getLogger(__name__)

app = FastAPI(title="Pi Morning Assistant", version="1.0.0")
app.mount("/static", StaticFiles(directory="app/static"), name="static")

state_manager = FaceStateManager()
trigger_store = TriggerStore(settings.trigger_state_file)
enrollment_store = EnrollmentStore(settings.enrollments_file)

weather_service = OpenWeatherMapService(
    api_key=settings.weather_api_key,
    lat=settings.weather_lat,
    lon=settings.weather_lon,
    units=settings.weather_units,
)
calendar_service = GoogleCalendarService(
    client_secret_file=str(settings.google_client_secret_file),
    token_file=str(settings.google_token_file),
    calendar_ids=[c.strip() for c in settings.google_calendar_ids.split(",") if c.strip()],
    timezone=settings.timezone,
)
speech_service = PiperSpeechService(
    piper_bin=settings.piper_bin,
    model=settings.piper_model,
    audio_player_bin=settings.audio_player_bin,
    audio_device=settings.audio_device,
)
briefing_service = BriefingService()
morning_gate = MorningGate(
    tz_name=settings.timezone,
    start_hhmm=settings.morning_start,
    end_hhmm=settings.morning_end,
    cooldown_minutes=settings.greeting_cooldown_minutes,
)
remote_client = RemoteAssistantClient(settings.remote_assistant_url) if settings.assistant_mode == "remote" else None
assistant = MorningAssistant(
    mode=settings.assistant_mode,
    state_manager=state_manager,
    trigger_store=trigger_store,
    morning_gate=morning_gate,
    briefing_service=briefing_service,
    weather_service=weather_service,
    calendar_service=calendar_service,
    speech_service=speech_service,
    remote_client=remote_client,
)

recognizer = FaceRecognizer(enrollment_store=enrollment_store, tolerance=settings.face_match_tolerance)
vision_loop = VisionLoop(
    camera_index=settings.camera_index,
    width=settings.frame_width,
    height=settings.frame_height,
    recognizer=recognizer,
    stable_frames=settings.face_stable_frames,
)
vision_task: asyncio.Task | None = None


class RemoteTriggerRequest(BaseModel):
    user_name: str


@app.get("/")
async def index() -> FileResponse:
    return FileResponse("app/static/index.html")


@app.get("/health")
async def health() -> dict:
    return {"status": "ok", "mode": settings.assistant_mode}


@app.get("/api/face-state")
async def get_face_state() -> dict:
    state = await state_manager.get_state()
    return state.model_dump(mode="json")


@app.post("/api/face-state/{expression}")
async def set_face_state(expression: str) -> dict:
    allowed = {"idle", "smile", "thinking", "talking_1", "talking_2", "mad"}
    if expression not in allowed:
        raise HTTPException(status_code=400, detail="Unknown expression")
    state = await state_manager.set_expression(expression)
    return state.model_dump(mode="json")


@app.post("/remote/trigger-briefing")
async def remote_trigger(req: RemoteTriggerRequest) -> dict:
    return await assistant.remote_trigger(req.user_name)


async def _on_stable_match(match) -> None:
    logger.info("Stable face match: %s (%.2f)", match.name, match.confidence)
    await assistant.handle_recognized_user(match.name)


@app.on_event("startup")
async def startup() -> None:
    global vision_task
    if settings.assistant_mode in {"local", "remote"}:
        vision_task = asyncio.create_task(vision_loop.run(on_stable_match=_on_stable_match))


@app.on_event("shutdown")
async def shutdown() -> None:
    vision_loop.stop()
    if vision_task:
        await asyncio.wait([vision_task], timeout=2)

