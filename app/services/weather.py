from __future__ import annotations

import httpx

from app.models import DailyWeather


class OpenWeatherMapService:
    def __init__(self, api_key: str, lat: float, lon: float, units: str = "imperial") -> None:
        self.api_key = api_key
        self.lat = lat
        self.lon = lon
        self.units = units

    async def get_today_weather(self) -> DailyWeather:
        if not self.api_key:
            raise RuntimeError("WEATHER_API_KEY is required for live weather.")
        params = {
            "lat": self.lat,
            "lon": self.lon,
            "appid": self.api_key,
            "units": self.units,
            "exclude": "minutely,hourly,alerts",
        }
        async with httpx.AsyncClient(timeout=20) as client:
            response = await client.get("https://api.openweathermap.org/data/3.0/onecall", params=params)
            response.raise_for_status()
            payload = response.json()
        today = payload["daily"][0]
        return DailyWeather(
            summary=today["weather"][0]["description"],
            high=float(today["temp"]["max"]),
            low=float(today["temp"]["min"]),
        )
