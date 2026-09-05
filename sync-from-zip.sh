#!/usr/bin/env bash
set -Eeuo pipefail

APP="${APP_DIR:-/home/pi/pi-zero2wh-camera}"
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SOURCE=""
TMP=""

cleanup() {
  [[ -n "$TMP" && -d "$TMP" ]] && rm -rf -- "$TMP"
}
trap cleanup EXIT

if [[ $EUID -ne 0 ]]; then
  exec sudo bash "$0" "$@"
fi

need_pkg=()
command -v unzip >/dev/null 2>&1 || need_pkg+=(unzip)
command -v rsync >/dev/null 2>&1 || need_pkg+=(rsync)
command -v curl >/dev/null 2>&1 || need_pkg+=(curl)
if ((${#need_pkg[@]})); then
  apt update
  apt install -y "${need_pkg[@]}"
fi

if [[ $# -ge 1 ]]; then
  ZIP="$1"
  [[ -f "$ZIP" ]] || {
    echo "ERROR: ZIP not found: $ZIP" >&2
    exit 1
  }

  TMP="$(mktemp -d /tmp/pi-zero2wh-camera-sync.XXXXXX)"
  unzip -q "$ZIP" -d "$TMP"

  if [[ -f "$TMP/install.sh" ]]; then
    SOURCE="$TMP"
  else
    SOURCE="$(find "$TMP" -mindepth 1 -maxdepth 2 -type f -name install.sh -printf '%h\n' | head -1)"
  fi

  [[ -n "$SOURCE" && -f "$SOURCE/install.sh" ]] || {
    echo "ERROR: install.sh not found inside ZIP" >&2
    exit 1
  }
else
  SOURCE="$SELF_DIR"
fi

if [[ "$(readlink -f "$SOURCE")" == "$(readlink -f "$APP" 2>/dev/null || true)" ]]; then
  echo "Source already is $APP; no file copy required."
else
  install -d -o pi -g pi "$APP"

  echo "Syncing: $SOURCE -> $APP"
  echo "Preserving: config/settings.env, recordings/, data/, models/*.rpk, .git/"

  rsync -a --delete \
    --exclude '/config/settings.env' \
    --exclude '/recordings/' \
    --exclude '/data/' \
    --exclude '/models/*.rpk' \
    --exclude '/.git/' \
    --exclude '__pycache__/' \
    --exclude '*.pyc' \
    "$SOURCE"/ "$APP"/
fi

install -d -o pi -g pi \
  "$APP/recordings/manual" \
  "$APP/recordings/events" \
  "$APP/recordings/snapshots" \
  "$APP/data" \
  "$APP/models"

if [[ ! -f "$APP/config/settings.env" ]]; then
  cp "$APP/config/settings.env.example" "$APP/config/settings.env"
  chown pi:pi "$APP/config/settings.env"
  chmod 600 "$APP/config/settings.env"
fi

chmod 0755 "$APP"/install.sh "$APP"/uninstall.sh "$APP"/sync-from-zip.sh "$APP"/scripts/*.sh

"$APP/scripts/merge-settings.sh" \
  "$APP/config/settings.env.example" \
  "$APP/config/settings.env"

set -a
# shellcheck disable=SC1090
source "$APP/config/settings.env"
set +a

if [[ "${AI_ENABLED:-1}" == "1" && ! -s "${AI_MODEL_PATH:-$APP/models/yolov8n.rpk}" ]]; then
  if ! sudo -u pi APP_DIR="$APP" "$APP/scripts/install-mini-ai-assets.sh"; then
    echo "WARNING: AI assets unavailable; camera-only mode remains usable."
  fi
fi

chown -R pi:pi "$APP/config" "$APP/models" "$APP/recordings" "$APP/data"

for unit in \
  zero2-camera-worker.service \
  zero2-camera-web.service \
  zero2-camera-cleanup.service \
  zero2-camera-cleanup.timer
do
  if [[ -f "$APP/systemd/$unit" ]]; then
    install -m 0644 "$APP/systemd/$unit" "/etc/systemd/system/$unit"
  fi
done

systemctl daemon-reload

if [[ -f /etc/systemd/system/zero2-camera-cleanup.timer ]]; then
  systemctl enable --now zero2-camera-cleanup.timer
fi

for service in zero2-camera-worker.service zero2-camera-web.service; do
  if systemctl cat "$service" >/dev/null 2>&1; then
    systemctl try-restart "$service" || true
  fi
done

if systemctl is-active --quiet nginx; then
  nginx -t && systemctl reload nginx || true
fi

echo
echo "ZIP sync complete: $APP"
echo "Preserved local config, recordings, data and downloaded AI model."
echo "New config keys were merged automatically."
echo
if systemctl cat zero2-camera-worker.service >/dev/null 2>&1; then
  echo "Existing installation updated."
  echo "Check: $APP/scripts/healthcheck.sh"
else
  echo "First install:"
  echo "  nano $APP/config/settings.env"
  echo "  sudo $APP/install.sh"
fi
