from __future__ import annotations

from datetime import datetime

from app.models import CalendarEvent, DailyBriefing, DailyWeather


def _format_first_event(events: list[CalendarEvent]) -> str:
    if not events:
        return "You have no events today."
    first = events[0]
    try:
        dt = datetime.fromisoformat(first.start_iso.replace("Z", "+00:00"))
        ts = dt.strftime("%-I:%M %p")
        return f"Your first event is at {ts}."
    except Exception:
        return f"Your first event is {first.title}."


class BriefingService:
    def compose(self, user_name: str, weather: DailyWeather, events: list[CalendarEvent]) -> DailyBriefing:
        event_count = len(events)
        event_segment = f"You have {event_count} event{'s' if event_count != 1 else ''} today."
        first_event_segment = _format_first_event(events)
        text = (
            f"Good morning {user_name}. "
            f"Today's high is {round(weather.high)} and the low is {round(weather.low)}. "
            f"{event_segment} {first_event_segment}"
        )
        return DailyBriefing(user_name=user_name, weather=weather, events=events, text=text)
