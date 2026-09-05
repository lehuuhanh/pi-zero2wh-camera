#!/usr/bin/env bash
set -Eeuo pipefail

APP=/home/pi/pi-zero2wh-camera
SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATE_DIR=/var/lib/zero2-camera
STATE_FILE="$STATE_DIR/install-state.env"
APT_STAMP="$STATE_DIR/apt-update.stamp"
APT_REFRESH_HOURS="${APT_REFRESH_HOURS:-24}"

log() { printf '[zero2-install] %s\n' "$*"; }
die() { printf '[zero2-install] ERROR: %s\n' "$*" >&2; exit 1; }

if [[ $EUID -ne 0 ]]; then
  exec sudo -E bash "$0" "$@"
fi

state_get() {
  local key="$1"
  [[ -r "$STATE_FILE" ]] || return 0
  awk -F= -v key="$key" '$1 == key {sub(/^[^=]*=/, ""); print; exit}' "$STATE_FILE"
}

file_sha256() {
  sha256sum "$1" | awk '{print $1}'
}

source_hash() {
  local file rel
  {
    while IFS= read -r -d '' file; do
      rel="${file#"$APP"/}"
      printf '%s  %s\n' "$(file_sha256 "$file")" "$rel"
    done < <(
      find "$APP" -type f \
        \( -name '*.sh' -o -name '*.py' -o -name '*.txt' \
           -o -name '*.json' -o -name '*.html' -o -name '*.css' \
           -o -name '*.js' -o -name '*.conf' -o -name '*.service' \
           -o -name '*.timer' -o -name 'settings.env.example' \) \
        -not -path "$APP/.git/*" \
        -not -path "$APP/recordings/*" \
        -not -path "$APP/data/*" \
        -not -path "$APP/models/*" \
        -print0
    )
  } | LC_ALL=C sort | sha256sum | awk '{print $1}'
}

write_state() {
  local source="$1" settings="$2"
  install -d -m 0755 "$STATE_DIR"
  cat >"$STATE_FILE.tmp" <<EOF_STATE
SOURCE_HASH=$source
SETTINGS_HASH=$settings
UPDATED_AT=$(date +%s)
EOF_STATE
  chmod 0644 "$STATE_FILE.tmp"
  mv -f "$STATE_FILE.tmp" "$STATE_FILE"
}

APT_PACKAGES=(
  imx500-all
  rpicam-apps
  python3-picamera2
  python3-libcamera
  python3-pil
  python3-numpy
  python3-flask
  python3-requests
  python3-waitress
  nginx
  openssl
  apache2-utils
  ffmpeg
  curl
  unzip
  rsync
)

APT_CHANGED=0
apt_stamp_fresh() {
  [[ -e "$APT_STAMP" ]] || return 1
  [[ "$APT_REFRESH_HOURS" =~ ^[0-9]+$ ]] || return 1
  local now stamp max_age
  now="$(date +%s)"
  stamp="$(stat -c %Y "$APT_STAMP" 2>/dev/null || echo 0)"
  max_age=$((APT_REFRESH_HOURS * 3600))
  (( now - stamp < max_age ))
}

ensure_os_packages() {
  local pkg installed candidate
  local -a missing=() upgrades=()

  for pkg in "${APT_PACKAGES[@]}"; do
    if ! dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null |
         grep -q '^install ok installed$'; then
      missing+=("$pkg")
    fi
  done

  if ((${#missing[@]})) || ! apt_stamp_fresh; then
    if ((${#missing[@]})); then
      log "missing OS packages detected; refresh apt metadata"
    else
      log "apt metadata older than ${APT_REFRESH_HOURS}h; refresh once"
    fi
    apt update
    install -d -m 0755 "$STATE_DIR"
    touch "$APT_STAMP"
  else
    log "all required OS packages exist and apt metadata is fresh: skip apt update"
  fi

  missing=()
  for pkg in "${APT_PACKAGES[@]}"; do
    if ! dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null |
         grep -q '^install ok installed$'; then
      missing+=("$pkg")
      continue
    fi

    installed="$(dpkg-query -W -f='${Version}' "$pkg" 2>/dev/null || true)"
    candidate="$(apt-cache policy "$pkg" 2>/dev/null | awk '/Candidate:/ {print $2; exit}')"
    if [[ -n "$installed" && -n "$candidate" && "$candidate" != "(none)" ]] &&
       dpkg --compare-versions "$installed" lt "$candidate"; then
      upgrades+=("$pkg")
      log "OS package upgrade: $pkg $installed -> $candidate"
    fi
  done

  if ((${#missing[@]})); then
    log "install only missing OS packages: ${missing[*]}"
    apt install -y "${missing[@]}"
    APT_CHANGED=1
  fi

  if ((${#upgrades[@]})); then
    log "upgrade only old OS packages: ${upgrades[*]}"
    apt install -y --only-upgrade "${upgrades[@]}"
    APT_CHANGED=1
  fi

  if ((${#missing[@]} == 0 && ${#upgrades[@]} == 0)); then
    log "OS dependencies already current: no package install/upgrade"
  fi
}

verify_os_python() {
  log "verify /usr/bin/python3 dependencies; no venv and no pip install"
  /usr/bin/python3 - <<'PY'
import importlib
mods = {
    "flask": "python3-flask",
    "requests": "python3-requests",
    "waitress": "python3-waitress",
    "PIL": "python3-pil",
    "numpy": "python3-numpy",
    "picamera2": "python3-picamera2",
    "libcamera": "python3-libcamera",
}
failed = []
for module, package in mods.items():
    try:
        importlib.import_module(module)
    except Exception as exc:
        failed.append(f"{module} ({package}): {exc}")
if failed:
    raise SystemExit("OS Python dependency check failed:\n  " + "\n  ".join(failed))
print("OS Python dependencies: OK")
PY
}

ensure_os_packages
verify_os_python

install -d -o pi -g pi "$APP"
if [[ "$(readlink -f "$SRC")" != "$(readlink -f "$APP")" ]]; then
  log "sync source into $APP; copy only changed files"
  rsync -a --itemize-changes \
    --exclude '/config/settings.env' \
    --exclude '/recordings/' \
    --exclude '/data/' \
    --exclude '/models/*.rpk' \
    --exclude '/.git/' \
    "$SRC"/ "$APP"/
fi

if [[ ! -f "$APP/config/settings.env" ]]; then
  cp "$APP/config/settings.env.example" "$APP/config/settings.env"
  chown pi:pi "$APP/config/settings.env"
  chmod 600 "$APP/config/settings.env"
fi

chmod 0755 "$APP/install.sh" "$APP/uninstall.sh" "$APP/sync-from-zip.sh" "$APP"/scripts/*.sh
"$APP/scripts/merge-settings.sh" \
  "$APP/config/settings.env.example" \
  "$APP/config/settings.env"

set -a
# shellcheck disable=SC1090
source "$APP/config/settings.env"
set +a

MODEL="$(tr -d '\0' </proc/device-tree/model 2>/dev/null || true)"
log "detected board: ${MODEL:-unknown}"
if [[ "$MODEL" != *"Raspberry Pi Zero 2"* ]]; then
  echo "WARNING: this project is tuned for Raspberry Pi Zero 2 W/WH."
fi

EXPECTED_SENSOR="${CAMERA_SENSOR:-imx500}"
BOOT_AUTO_DETECT="${CAMERA_BOOT_AUTO_DETECT:-0}"
BOOT_OVERLAY="${CAMERA_BOOT_OVERLAY:-imx500}"

[[ "$EXPECTED_SENSOR" == "imx500" ]] ||
  echo "WARNING: CAMERA_SENSOR=$EXPECTED_SENSOR; this project is designed for IMX500."
[[ "$BOOT_OVERLAY" == "imx500" ]] ||
  echo "WARNING: CAMERA_BOOT_OVERLAY=$BOOT_OVERLAY; expected imx500."

install -d -o pi -g pi \
  "$APP/recordings/manual" \
  "$APP/recordings/events" \
  "$APP/recordings/snapshots" \
  "$APP/data" \
  "$APP/models"

if [[ "${AI_ENABLED:-1}" == "1" ]]; then
  if [[ -s "${AI_MODEL_PATH:-$APP/models/yolov8n.rpk}" &&
        -s "${AI_LABELS_PATH:-$APP/models/coco_labels.txt}" ]]; then
    log "AI model/labels already present: skip download"
  elif ! sudo -u pi APP_DIR="$APP" "$APP/scripts/install-mini-ai-assets.sh"; then
    echo "WARNING: AI model download failed; camera will start without AI."
  fi
fi

BOOTCFG=""
[[ -f /boot/firmware/config.txt ]] && BOOTCFG=/boot/firmware/config.txt
[[ -z "$BOOTCFG" && -f /boot/config.txt ]] && BOOTCFG=/boot/config.txt
REBOOT_NEEDED=0

if [[ "${FORCE_IMX500_OVERLAY:-1}" == "1" && -n "$BOOTCFG" ]]; then
  desired_auto="camera_auto_detect=${BOOT_AUTO_DETECT}"
  desired_overlay="dtoverlay=${BOOT_OVERLAY}"

  if ! grep -qE "^[[:space:]]*camera_auto_detect=${BOOT_AUTO_DETECT}([[:space:]]|$)" "$BOOTCFG" ||
     ! grep -qE "^[[:space:]]*dtoverlay=${BOOT_OVERLAY}([[:space:]]|$)" "$BOOTCFG"; then
    cp -a "$BOOTCFG" "$BOOTCFG.zero2-camera.$(date +%Y%m%d-%H%M%S).bak"
    if grep -qE '^[[:space:]]*camera_auto_detect=' "$BOOTCFG"; then
      sed -i "s/^[[:space:]]*camera_auto_detect=.*/${desired_auto}/" "$BOOTCFG"
    else
      printf '\n%s\n' "$desired_auto" >>"$BOOTCFG"
    fi
    sed -i "/^[[:space:]]*dtoverlay=${BOOT_OVERLAY}[[:space:]]*$/d" "$BOOTCFG"
    printf '%s\n' "$desired_overlay" >>"$BOOTCFG"
    REBOOT_NEEDED=1
  else
    log "IMX500 boot configuration already correct: skip"
  fi
fi

SYSTEMD_CHANGED=0
for unit in \
  zero2-camera-worker.service \
  zero2-camera-web.service \
  zero2-camera-cleanup.service \
  zero2-camera-cleanup.timer
do
  src_unit="$APP/systemd/$unit"
  dst_unit="/etc/systemd/system/$unit"
  if [[ ! -f "$dst_unit" ]] || ! cmp -s "$src_unit" "$dst_unit"; then
    install -m 0644 "$src_unit" "$dst_unit"
    SYSTEMD_CHANGED=1
    log "systemd update: $unit"
  fi
done
if ((SYSTEMD_CHANGED)); then
  systemctl daemon-reload
else
  log "systemd units unchanged: skip copy/reload"
fi

NGINX_CHANGED=0
mkdir -p /etc/nginx/certs /etc/nginx/sites-available /etc/nginx/sites-enabled
if [[ ! -f /etc/nginx/certs/zero2-camera.key || ! -f /etc/nginx/certs/zero2-camera.crt ]]; then
  IP="${PI_IP:-$(hostname -I | awk '{print $1}')}"
  openssl req -x509 -nodes -newkey rsa:2048 -days 3650 \
    -subj "/CN=${IP:-raspberrypi.local}" \
    -keyout /etc/nginx/certs/zero2-camera.key \
    -out /etc/nginx/certs/zero2-camera.crt
  NGINX_CHANGED=1
else
  log "TLS certificate already exists: skip generation"
fi

if [[ "${NGINX_BASIC_PASSWORD:-CHANGE_ME}" == "CHANGE_ME" || -z "${NGINX_BASIC_PASSWORD:-}" ]]; then
  echo
  echo "ACTION REQUIRED:"
  echo "  nano $APP/config/settings.env"
  echo "Set NGINX_BASIC_PASSWORD, then rerun:"
  echo "  sudo $APP/install.sh"
  echo
else
  if [[ ! -s /etc/nginx/.zero2-camera.htpasswd ]]; then
    htpasswd -bc /etc/nginx/.zero2-camera.htpasswd "${NGINX_BASIC_USER:-pi}" "$NGINX_BASIC_PASSWORD"
    chown root:www-data /etc/nginx/.zero2-camera.htpasswd
    chmod 640 /etc/nginx/.zero2-camera.htpasswd
    NGINX_CHANGED=1
  else
    log "Nginx Basic Auth already exists: preserve"
  fi

  rendered="$(mktemp)"
  sed \
    -e "s/__HTTP_PORT__/${NGINX_HTTP_PORT:-80}/g" \
    -e "s/__HTTPS_PORT__/${NGINX_HTTPS_PORT:-443}/g" \
    "$APP/nginx/zero2-camera.conf" >"$rendered"

  if [[ ! -f /etc/nginx/sites-available/zero2-camera.conf ]] ||
     ! cmp -s "$rendered" /etc/nginx/sites-available/zero2-camera.conf; then
    install -m 0644 "$rendered" /etc/nginx/sites-available/zero2-camera.conf
    NGINX_CHANGED=1
    log "Nginx configuration changed: update"
  else
    log "Nginx configuration unchanged: skip copy"
  fi
  rm -f "$rendered"

  ln -sfn /etc/nginx/sites-available/zero2-camera.conf /etc/nginx/sites-enabled/zero2-camera.conf
  rm -f /etc/nginx/sites-enabled/default
  nginx -t
fi

systemctl enable zero2-camera-worker zero2-camera-web >/dev/null
if ! systemctl is-enabled --quiet zero2-camera-cleanup.timer 2>/dev/null ||
   ! systemctl is-active --quiet zero2-camera-cleanup.timer; then
  systemctl enable --now zero2-camera-cleanup.timer
else
  log "cleanup timer already enabled/running: skip"
fi

CURRENT_SOURCE="$(source_hash)"
CURRENT_SETTINGS="$(file_sha256 "$APP/config/settings.env")"
OLD_SOURCE="$(state_get SOURCE_HASH)"
OLD_SETTINGS="$(state_get SETTINGS_HASH)"
RUNTIME_CHANGED=0
if [[ -z "$OLD_SOURCE" || "$CURRENT_SOURCE" != "$OLD_SOURCE" ||
      "$CURRENT_SETTINGS" != "$OLD_SETTINGS" || "$APT_CHANGED" == 1 ||
      "$SYSTEMD_CHANGED" == 1 ]]; then
  RUNTIME_CHANGED=1
fi

if ((REBOOT_NEEDED)); then
  echo
  echo "IMX500 boot configuration changed. Reboot required:"
  echo "  sudo reboot"
else
  if rpicam-hello --list-cameras 2>&1 | grep -qi "$EXPECTED_SENSOR"; then
    if ((RUNTIME_CHANGED)) || ! systemctl is-active --quiet zero2-camera-worker; then
      log "camera runtime changed/inactive: restart worker"
      systemctl restart zero2-camera-worker
      sleep 8
    else
      log "camera source/settings/packages unchanged and worker active: skip restart"
    fi
  else
    echo
    echo "WARNING: expected camera '$EXPECTED_SENSOR' is not enumerated by libcamera."
    echo "Worker was not restarted. Run:"
    echo "  $APP/scripts/diagnose-imx500.sh"
  fi

  if ((RUNTIME_CHANGED)) || ! systemctl is-active --quiet zero2-camera-web; then
    log "web runtime changed/inactive: restart web"
    systemctl restart zero2-camera-web
  else
    log "web source/settings/packages unchanged and service active: skip restart"
  fi

  if [[ -f /etc/nginx/sites-enabled/zero2-camera.conf ]]; then
    if ! systemctl is-active --quiet nginx; then
      systemctl enable --now nginx
    elif ((NGINX_CHANGED)); then
      systemctl reload nginx
    else
      log "Nginx unchanged and active: skip reload/restart"
    fi
  fi
fi

chown pi:pi "$APP/config/settings.env" 2>/dev/null || true
find "$APP/models" -maxdepth 1 -type f -exec chown pi:pi {} + 2>/dev/null || true
write_state "$CURRENT_SOURCE" "$CURRENT_SETTINGS"

echo
echo "Installed/updated: $APP"
echo "Python runtime: /usr/bin/python3 (Raspberry Pi OS packages; no project venv)"
echo "Camera sensor: ${EXPECTED_SENSOR}; overlay=${BOOT_OVERLAY}; auto-detect=${BOOT_AUTO_DETECT}"
echo "AI: ${AI_ENABLED:-1}; model=${AI_MODEL_PATH:-$APP/models/yolov8n.rpk}"
echo "AI prebuffer: ${AI_PREBUFFER_SECONDS:-3}s"
echo "Video retention: ${VIDEO_RETENTION_DAYS:-7} days"
echo "Health check: $APP/scripts/healthcheck.sh"
