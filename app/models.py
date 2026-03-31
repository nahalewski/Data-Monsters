from __future__ import annotations

from datetime import datetime
from pydantic import BaseModel, Field


class FaceState(BaseModel):
    expression: str = Field(default="idle")
    updated_at: datetime = Field(default_factory=datetime.utcnow)


class DailyWeather(BaseModel):
    summary: str
    high: float
    low: float


class CalendarEvent(BaseModel):
    title: str
    start_iso: str


class DailyBriefing(BaseModel):
    user_name: str
    weather: DailyWeather
    events: list[CalendarEvent]
    text: str
