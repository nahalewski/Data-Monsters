from __future__ import annotations

from pathlib import Path
from pydantic import Field
from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    model_config = SettingsConfigDict(env_file=".env", env_file_encoding="utf-8", extra="ignore")

    assistant_mode: str = Field(default="local", alias="ASSISTANT_MODE")
    remote_assistant_url: str = Field(default="http://127.0.0.1:8080", alias="REMOTE_ASSISTANT_URL")

    assistant_user_name: str = Field(default="Ben", alias="ASSISTANT_USER_NAME")
    timezone: str = Field(default="UTC", alias="TIMEZONE")

    camera_index: int = Field(default=0, alias="CAMERA_INDEX")
    frame_width: int = Field(default=640, alias="FRAME_WIDTH")
    frame_height: int = Field(default=480, alias="FRAME_HEIGHT")
    face_stable_frames: int = Field(default=5, alias="FACE_STABLE_FRAMES")
    face_match_tolerance: float = Field(default=0.5, alias="FACE_MATCH_TOLERANCE")

    morning_start: str = Field(default="05:00", alias="MORNING_START")
    morning_end: str = Field(default="11:30", alias="MORNING_END")
    greeting_cooldown_minutes: int = Field(default=120, alias="GREETING_COOLDOWN_MINUTES")
    trigger_state_file: Path = Field(default=Path("data/trigger_state.json"), alias="TRIGGER_STATE_FILE")
    enrollments_file: Path = Field(default=Path("data/enrollments.json"), alias="ENROLLMENTS_FILE")

    weather_provider: str = Field(default="openweathermap", alias="WEATHER_PROVIDER")
    weather_api_key: str = Field(default="", alias="WEATHER_API_KEY")
    weather_lat: float = Field(default=0.0, alias="WEATHER_LAT")
    weather_lon: float = Field(default=0.0, alias="WEATHER_LON")
    weather_units: str = Field(default="imperial", alias="WEATHER_UNITS")

    calendar_provider: str = Field(default="google", alias="CALENDAR_PROVIDER")
    google_client_secret_file: Path = Field(default=Path("data/google_client_secret.json"), alias="GOOGLE_CLIENT_SECRET_FILE")
    google_token_file: Path = Field(default=Path("data/google_token.json"), alias="GOOGLE_TOKEN_FILE")
    google_calendar_ids: str = Field(default="primary", alias="GOOGLE_CALENDAR_IDS")

    piper_bin: Path = Field(default=Path("/usr/local/bin/piper"), alias="PIPER_BIN")
    piper_model: Path = Field(default=Path("/opt/piper/en_US-lessac-medium.onnx"), alias="PIPER_MODEL")
    piper_config: Path = Field(default=Path("/opt/piper/en_US-lessac-medium.onnx.json"), alias="PIPER_CONFIG")
    audio_player_bin: str = Field(default="aplay", alias="AUDIO_PLAYER_BIN")
    audio_device: str = Field(default="default", alias="AUDIO_DEVICE")

    ui_host: str = Field(default="0.0.0.0", alias="UI_HOST")
    ui_port: int = Field(default=8080, alias="UI_PORT")
    ui_poll_ms: int = Field(default=250, alias="UI_POLL_MS")

    log_level: str = Field(default="INFO", alias="LOG_LEVEL")


settings = Settings()
