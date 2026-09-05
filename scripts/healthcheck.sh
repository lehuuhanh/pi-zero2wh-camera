#!/usr/bin/env bash
set -u

APP="${APP_DIR:-/home/pi/pi-zero2wh-camera}"

echo '=== board ==='
tr -d '\0' </proc/device-tree/model 2>/dev/null
echo

echo '=== architecture ==='
echo "kernel: $(uname -m)"
echo "debian: $(dpkg --print-architecture 2>/dev/null || true)"

echo '=== camera ==='
rpicam-hello --list-cameras 2>&1 || true

echo '=== AI assets ==='
if [[ -f "$APP/config/settings.env" ]]; then
  set -a
  # shellcheck disable=SC1090
  source "$APP/config/settings.env"
  set +a
fi
MODEL="${AI_MODEL_PATH:-$APP/models/yolov8n.rpk}"
LABELS="${AI_LABELS_PATH:-$APP/models/coco_labels.txt}"
ls -lh "$MODEL" "$LABELS" 2>&1 || true

echo '=== services ==='
systemctl --no-pager --full status \
  zero2-camera-worker \
  zero2-camera-web \
  zero2-camera-cleanup.timer \
  nginx 2>&1 | tail -120

echo '=== timers ==='
systemctl list-timers zero2-camera-cleanup.timer --no-pager 2>&1 || true

echo '=== ports ==='
ss -lntp 2>/dev/null | grep -E ':8091|:8080|:443|:80' || true

echo '=== worker health ==='
if command -v curl >/dev/null 2>&1; then
  curl -fsS http://127.0.0.1:8091/health 2>/dev/null | \
    python3 -m json.tool 2>/dev/null || true
fi

echo '=== memory ==='
free -h

echo '=== disk ==='
df -h "$APP" 2>/dev/null || true
