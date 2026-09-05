#!/usr/bin/env bash
set -Eeuo pipefail

APP=/home/pi/pi-zero2wh-camera
SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ $EUID -ne 0 ]]; then
  exec sudo bash "$0" "$@"
fi

apt update
apt install -y \
  imx500-all rpicam-apps python3-picamera2 python3-libcamera \
  python3-pil python3-numpy python3-flask python3-requests python3-waitress \
  nginx openssl apache2-utils ffmpeg curl unzip rsync

install -d -o pi -g pi "$APP"

if [[ "$(readlink -f "$SRC")" != "$(readlink -f "$APP")" ]]; then
  rsync -a \
    --exclude '/config/settings.env' \
    --exclude '/recordings/' \
    --exclude '/data/' \
    --exclude '/.git/' \
    "$SRC"/ "$APP"/
fi

if [[ ! -f "$APP/config/settings.env" ]]; then
  cp "$APP/config/settings.env.example" "$APP/config/settings.env"
  chown pi:pi "$APP/config/settings.env"
  chmod 600 "$APP/config/settings.env"
fi

chmod +x \
  "$APP"/install.sh \
  "$APP"/uninstall.sh \
  "$APP"/sync-from-zip.sh \
  "$APP"/scripts/*.sh

"$APP/scripts/merge-settings.sh" \
  "$APP/config/settings.env.example" \
  "$APP/config/settings.env"

set -a
# shellcheck disable=SC1090
source "$APP/config/settings.env"
set +a

MODEL="$(tr -d '\0' </proc/device-tree/model 2>/dev/null || true)"
echo "Detected board: ${MODEL:-unknown}"
if [[ "$MODEL" != *"Raspberry Pi Zero 2"* ]]; then
  echo "WARNING: this project is tuned for Raspberry Pi Zero 2 W/WH."
fi

install -d -o pi -g pi \
  "$APP/recordings/manual" \
  "$APP/recordings/events" \
  "$APP/recordings/snapshots" \
  "$APP/data" \
  "$APP/models"

if [[ "${AI_ENABLED:-1}" == "1" ]]; then
  if ! sudo -u pi APP_DIR="$APP" "$APP/scripts/install-mini-ai-assets.sh"; then
    echo "WARNING: AI model download failed; camera will start without AI."
  fi
fi

BOOTCFG=""
[[ -f /boot/firmware/config.txt ]] && BOOTCFG=/boot/firmware/config.txt
[[ -z "$BOOTCFG" && -f /boot/config.txt ]] && BOOTCFG=/boot/config.txt
REBOOT_NEEDED=0

if [[ "${FORCE_IMX500_OVERLAY:-1}" == "1" && -n "$BOOTCFG" ]]; then
  if ! grep -qE '^[[:space:]]*camera_auto_detect=0([[:space:]]|$)' "$BOOTCFG" ||
     ! grep -qE '^[[:space:]]*dtoverlay=imx500([[:space:]]|$)' "$BOOTCFG"; then
    cp -a "$BOOTCFG" "$BOOTCFG.zero2-camera.$(date +%Y%m%d-%H%M%S).bak"

    if grep -qE '^[[:space:]]*camera_auto_detect=' "$BOOTCFG"; then
      sed -i 's/^[[:space:]]*camera_auto_detect=.*/camera_auto_detect=0/' "$BOOTCFG"
    else
      printf '\ncamera_auto_detect=0\n' >> "$BOOTCFG"
    fi

    if ! grep -qE '^[[:space:]]*dtoverlay=imx500([[:space:]]|$)' "$BOOTCFG"; then
      printf 'dtoverlay=imx500\n' >> "$BOOTCFG"
    fi

    REBOOT_NEEDED=1
  fi
fi

install -m 0644 "$APP/systemd/zero2-camera-worker.service" /etc/systemd/system/
install -m 0644 "$APP/systemd/zero2-camera-web.service" /etc/systemd/system/
install -m 0644 "$APP/systemd/zero2-camera-cleanup.service" /etc/systemd/system/
install -m 0644 "$APP/systemd/zero2-camera-cleanup.timer" /etc/systemd/system/

mkdir -p /etc/nginx/certs
if [[ ! -f /etc/nginx/certs/zero2-camera.key ]]; then
  IP="${PI_IP:-$(hostname -I | awk '{print $1}')}"
  openssl req -x509 -nodes -newkey rsa:2048 -days 3650 \
    -subj "/CN=${IP:-raspberrypi.local}" \
    -keyout /etc/nginx/certs/zero2-camera.key \
    -out /etc/nginx/certs/zero2-camera.crt
fi

if [[ "${NGINX_BASIC_PASSWORD:-CHANGE_ME}" == "CHANGE_ME" || -z "${NGINX_BASIC_PASSWORD:-}" ]]; then
  echo
  echo "ACTION REQUIRED:"
  echo "  nano $APP/config/settings.env"
  echo "Set NGINX_BASIC_PASSWORD, then rerun:"
  echo "  sudo $APP/install.sh"
  echo
else
  htpasswd -bc /etc/nginx/.zero2-camera.htpasswd "${NGINX_BASIC_USER:-pi}" "$NGINX_BASIC_PASSWORD"
  chown root:www-data /etc/nginx/.zero2-camera.htpasswd
  chmod 640 /etc/nginx/.zero2-camera.htpasswd

  sed \
    -e "s/__HTTP_PORT__/${NGINX_HTTP_PORT:-80}/g" \
    -e "s/__HTTPS_PORT__/${NGINX_HTTPS_PORT:-443}/g" \
    "$APP/nginx/zero2-camera.conf" > /etc/nginx/sites-available/zero2-camera.conf

  ln -sfn /etc/nginx/sites-available/zero2-camera.conf /etc/nginx/sites-enabled/zero2-camera.conf
  rm -f /etc/nginx/sites-enabled/default
  nginx -t
fi

systemctl daemon-reload
systemctl enable zero2-camera-worker zero2-camera-web
systemctl enable --now zero2-camera-cleanup.timer

if (( REBOOT_NEEDED )); then
  echo
  echo "IMX500 overlay changed. Reboot required:"
  echo "  sudo reboot"
else
  systemctl restart zero2-camera-worker
  sleep 8
  systemctl restart zero2-camera-web

  if [[ -f /etc/nginx/sites-enabled/zero2-camera.conf ]]; then
    systemctl enable --now nginx
    systemctl restart nginx
  fi
fi

chown -R pi:pi "$APP/config" "$APP/models" "$APP/recordings" "$APP/data"

echo
echo "Installed: $APP"
echo "AI: ${AI_ENABLED:-1}; model=${AI_MODEL_PATH:-$APP/models/yolov8n.rpk}"
echo "AI prebuffer: ${AI_PREBUFFER_SECONDS:-3}s"
echo "Video retention: ${VIDEO_RETENTION_DAYS:-7} days"
echo "Health check: $APP/scripts/healthcheck.sh"
