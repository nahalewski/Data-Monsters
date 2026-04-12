from __future__ import annotations

from datetime import datetime, timedelta
from zoneinfo import ZoneInfo

from google.auth.transport.requests import Request
from google.oauth2.credentials import Credentials
from google_auth_oauthlib.flow import InstalledAppFlow
from googleapiclient.discovery import build

from app.models import CalendarEvent

SCOPES = ["https://www.googleapis.com/auth/calendar.readonly"]


class GoogleCalendarService:
    def __init__(self, client_secret_file: str, token_file: str, calendar_ids: list[str], timezone: str) -> None:
        self.client_secret_file = client_secret_file
        self.token_file = token_file
        self.calendar_ids = calendar_ids
        self.timezone = timezone

    def _get_credentials(self) -> Credentials:
        creds = None
        try:
            creds = Credentials.from_authorized_user_file(self.token_file, SCOPES)
        except Exception:
            creds = None

        if not creds or not creds.valid:
            if creds and creds.expired and creds.refresh_token:
                creds.refresh(Request())
            else:
                flow = InstalledAppFlow.from_client_secrets_file(self.client_secret_file, SCOPES)
                creds = flow.run_local_server(port=0)
            with open(self.token_file, "w", encoding="utf-8") as token:
                token.write(creds.to_json())
        return creds

    def get_today_events(self) -> list[CalendarEvent]:
        creds = self._get_credentials()
        service = build("calendar", "v3", credentials=creds, cache_discovery=False)

        tz = ZoneInfo(self.timezone)
        now = datetime.now(tz)
        start = datetime(now.year, now.month, now.day, tzinfo=tz)
        end = start + timedelta(days=1)

        all_events: list[CalendarEvent] = []
        for cal_id in self.calendar_ids:
            result = (
                service.events()
                .list(
                    calendarId=cal_id,
                    timeMin=start.isoformat(),
                    timeMax=end.isoformat(),
                    singleEvents=True,
                    orderBy="startTime",
                )
                .execute()
            )
            for event in result.get("items", []):
                start_iso = event.get("start", {}).get("dateTime") or event.get("start", {}).get("date")
                all_events.append(CalendarEvent(title=event.get("summary", "Untitled event"), start_iso=start_iso))
        all_events.sort(key=lambda e: e.start_iso)
        return all_events
