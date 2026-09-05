#!/usr/bin/env bash
set -Eeuo pipefail

APP=/home/pi/pi-zero2wh-camera
SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="$SRC/config/settings.env"

if [[ $EUID -ne 0 ]]; then
  exec sudo bash "$0" "$@"
fi

if [[ ! -f "$ENV_FILE" ]]; then
  if [[ -f "$SRC/config/settings.env.example" ]]; then
    cp "$SRC/config/settings.env.example" "$ENV_FILE"
    chown pi:pi "$ENV_FILE" 2>/dev/null || true
    chmod 600 "$ENV_FILE"
    echo "Created $ENV_FILE from settings.env.example"
    echo "Edit NGINX_BASIC_PASSWORD, then rerun install.sh."
    exit 2
  fi

  echo "Missing $ENV_FILE and settings.env.example" >&2
  exit 1
fi

set -a
source "$ENV_FILE"
set +a

MODEL="$(tr -d '\0' </proc/device-tree/model 2>/dev/null || true)"
echo "Detected board: ${MODEL:-unknown}"
if [[ "$MODEL" != *"Raspberry Pi Zero 2"* ]]; then
  echo "WARNING: this project is tuned for Raspberry Pi Zero 2 W/WH."
fi

apt update
apt install -y \
  imx500-all rpicam-apps python3-picamera2 python3-libcamera \
  python3-pil python3-flask python3-requests python3-waitress \
  nginx openssl apache2-utils ffmpeg

install -d -o pi -g pi "$APP"
cp -a "$SRC"/. "$APP"/
chown -R pi:pi "$APP"
chmod +x \
  "$APP"/install.sh \
  "$APP"/uninstall.sh \
  "$APP"/scripts/healthcheck.sh \
  "$APP"/scripts/cleanup-videos.sh

BOOTCFG=""
[[ -f /boot/firmware/config.txt ]] && BOOTCFG=/boot/firmware/config.txt
[[ -z "$BOOTCFG" && -f /boot/config.txt ]] && BOOTCFG=/boot/config.txt
REBOOT_NEEDED=0

if [[ "${FORCE_IMX500_OVERLAY:-1}" == "1" && -n "$BOOTCFG" ]]; then
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
  echo "ERROR: edit $APP/config/settings.env and set NGINX_BASIC_PASSWORD before finishing nginx setup." >&2
  echo "Services will be installed but nginx auth is not configured." >&2
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
  echo "IMX500 overlay configured. Reboot required before starting camera services:"
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

echo
echo "Installed to $APP"
echo "Video retention: ${VIDEO_RETENTION_DAYS:-7} days; cleanup timer runs daily."
echo "Check timer: systemctl list-timers zero2-camera-cleanup.timer"
echo "Run cleanup now: sudo systemctl start zero2-camera-cleanup.service"
echo "After reboot test: rpicam-hello --list-cameras"
echo "Then: sudo systemctl restart zero2-camera-worker zero2-camera-web nginx"
