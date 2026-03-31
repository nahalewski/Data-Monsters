from __future__ import annotations

from datetime import datetime, time, timedelta
from zoneinfo import ZoneInfo


def _parse_hhmm(value: str) -> time:
    hours, minutes = value.split(":")
    return time(hour=int(hours), minute=int(minutes))


class MorningGate:
    def __init__(self, tz_name: str, start_hhmm: str, end_hhmm: str, cooldown_minutes: int) -> None:
        self.tz = ZoneInfo(tz_name)
        self.start = _parse_hhmm(start_hhmm)
        self.end = _parse_hhmm(end_hhmm)
        self.cooldown = timedelta(minutes=cooldown_minutes)

    def now(self) -> datetime:
        return datetime.now(self.tz)

    def is_morning_window(self) -> bool:
        current = self.now().time()
        return self.start <= current <= self.end

    def can_trigger(self, last_trigger_iso: str | None) -> bool:
        if not self.is_morning_window():
            return False
        if not last_trigger_iso:
            return True
        last_dt = datetime.fromisoformat(last_trigger_iso)
        if last_dt.tzinfo is None:
            last_dt = last_dt.replace(tzinfo=ZoneInfo("UTC"))
        now_utc = datetime.now(ZoneInfo("UTC"))
        return now_utc - last_dt >= self.cooldown
