# Raspberry Pi 5 AI Morning Assistant

A production-oriented, runnable morning assistant designed for Raspberry Pi 5 with:
- Local USB webcam face recognition
- Morning-only greeting trigger with stability and cooldown logic
- Daily spoken briefing (weather + today's calendar)
- USB speaker/mic audio pipeline (TTS playback)
- Fullscreen pixel-art AI face UI with expressions
- Optional split-brain mode (Pi A vision/UI, Pi B assistant logic)

## Architecture

### Local mode (single Pi)
1. `VisionLoop` reads USB webcam frames with OpenCV.
2. `FaceRecognizer` matches faces against locally enrolled encodings.
3. Stable match (N frames) triggers `MorningAssistant`.
4. `MorningAssistant` checks morning window + cooldown persisted in `data/trigger_state.json`.
5. Assistant fetches weather + calendar data, composes briefing text.
6. Piper generates speech, audio plays via ALSA.
7. Face state transitions drive frontend: `smile -> talking_1/talking_2 -> idle`.

### Remote mode (two Pis)
- Pi A: vision + display, set `ASSISTANT_MODE=remote` and `REMOTE_ASSISTANT_URL=http://PI_B:8080`
- Pi B: runs same app in local capability mode (has weather/calendar/secrets and audio output)
- Pi A calls Pi B `/remote/trigger-briefing` over local HTTP.

## Expression states
Supported and implemented:
- `idle`
- `smile`
- `thinking`
- `talking_1`
- `talking_2`
- `mad`

Assets are in `app/static/assets/faces/*.svg` and can be swapped with your own pixel-art images.

## Repo structure

```text
app/
  main.py
  models.py
  settings.py
  state_manager.py
  services/
    assistant.py
    briefing.py
    calendar.py
    persistence.py
    remote.py
    speech.py
    time_gate.py
    vision.py
    weather.py
  static/
    index.html
    styles.css
    app.js
    assets/faces/
config/
  assistant.yaml
scripts/
  enroll_face.py
  run_backend.py
  install_pi.sh
systemd/
  pi-morning-assistant.service
data/
  (runtime files: enrollments, trigger state, Google OAuth token)
tests/
requirements.txt
.env.example
```

## Raspberry Pi 5 setup

### 1) Install
From repo root on Pi:

```bash
chmod +x scripts/install_pi.sh
./scripts/install_pi.sh
```

### 2) Configure environment

```bash
cp .env.example .env
nano .env
```

Required secrets/config:
- `WEATHER_API_KEY` (OpenWeatherMap)
- `WEATHER_LAT`, `WEATHER_LON`
- `GOOGLE_CLIENT_SECRET_FILE` path to OAuth client JSON
- `PIPER_BIN`, `PIPER_MODEL`
- `AUDIO_DEVICE` if non-default ALSA output

### 3) Google Calendar auth (one-time)
- Place OAuth client JSON at `data/google_client_secret.json` (or path in `.env`)
- First assistant run opens local auth browser; complete login once.
- Token is saved to `data/google_token.json`.

### 4) Enroll your face

```bash
.venv/bin/python scripts/enroll_face.py --name Ben --camera-index 0 --samples 5
```

### 5) Run

```bash
.venv/bin/python scripts/run_backend.py
```

Open browser on Pi display (kiosk/fullscreen recommended):
- `http://127.0.0.1:8080`

### 6) Start on boot (systemd)

```bash
sudo cp systemd/pi-morning-assistant.service /etc/systemd/system/
sudo sed -i "s|__APP_DIR__|/opt/pi-morning-assistant|g" /etc/systemd/system/pi-morning-assistant.service
sudo sed -i "s|__USER__|pi|g" /etc/systemd/system/pi-morning-assistant.service
sudo systemctl daemon-reload
sudo systemctl enable --now pi-morning-assistant.service
```

## API endpoints
- `GET /health`
- `GET /api/face-state`
- `POST /api/face-state/{expression}`
- `POST /remote/trigger-briefing`

## Practical notes
- Core vision is local and does not require cloud services.
- Weather/calendar require external APIs and secrets.
- For best reliability, use fixed USB device mapping and stable lighting for recognition.
- Use Chromium kiosk mode for fullscreen UI:

```bash
chromium-browser --kiosk http://127.0.0.1:8080
```

## Validation checklist on Pi

```bash
python -m compileall app scripts
python -m pytest -q
.venv/bin/python scripts/run_backend.py
curl http://127.0.0.1:8080/health
curl http://127.0.0.1:8080/api/face-state
```

## What still requires your secrets/hardware
- OpenWeatherMap API key
- Google OAuth client secret and first-run auth
- USB webcam connected and index configured
- USB speaker/mic configured and ALSA playback device verified
- Piper binary + model installed at configured paths
