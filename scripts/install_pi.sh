#!/usr/bin/env bash
set -euo pipefail

APP_DIR="/opt/pi-morning-assistant"
VENV_DIR="$APP_DIR/.venv"
USER_NAME="${SUDO_USER:-$USER}"

sudo apt-get update
sudo apt-get install -y \
  python3.11 python3.11-venv python3-pip \
  build-essential cmake \
  libopenblas-dev liblapack-dev libx11-dev libgtk-3-dev \
  libatlas-base-dev libjpeg-dev \
  portaudio19-dev ffmpeg alsa-utils

sudo mkdir -p "$APP_DIR"
sudo rsync -a --delete ./ "$APP_DIR"/
sudo chown -R "$USER_NAME":"$USER_NAME" "$APP_DIR"

python3.11 -m venv "$VENV_DIR"
"$VENV_DIR/bin/pip" install --upgrade pip wheel
"$VENV_DIR/bin/pip" install -r "$APP_DIR/requirements.txt"

cp "$APP_DIR/.env.example" "$APP_DIR/.env"
echo "Edit $APP_DIR/.env with API keys, location, and audio paths."

echo "Installing systemd service..."
sudo cp "$APP_DIR/systemd/pi-morning-assistant.service" /etc/systemd/system/
sudo sed -i "s|__APP_DIR__|$APP_DIR|g" /etc/systemd/system/pi-morning-assistant.service
sudo sed -i "s|__USER__|$USER_NAME|g" /etc/systemd/system/pi-morning-assistant.service
sudo systemctl daemon-reload

cat <<MSG
Install complete.
Next steps:
1) Edit $APP_DIR/.env
2) Enroll your face:
   $VENV_DIR/bin/python $APP_DIR/scripts/enroll_face.py --name Ben
3) Start service:
   sudo systemctl enable --now pi-morning-assistant.service
MSG
