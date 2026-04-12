from app.models import CalendarEvent, DailyWeather
from app.services.briefing import BriefingService


def test_briefing_text_contains_weather_and_event_count():
    service = BriefingService()
    weather = DailyWeather(summary="clear", high=74, low=58)
    events = [CalendarEvent(title="Standup", start_iso="2026-03-30T09:00:00-04:00")]
    briefing = service.compose("Ben", weather, events)
    assert "Good morning Ben" in briefing.text
    assert "high is 74" in briefing.text
    assert "You have 1 event today" in briefing.text
