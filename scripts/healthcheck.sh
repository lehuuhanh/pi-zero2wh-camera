#!/usr/bin/env bash
set -u

APP="${APP_DIR:-/home/pi/pi-zero2wh-camera}"
BOOTCFG=/boot/firmware/config.txt
[[ -f "$BOOTCFG" ]] || BOOTCFG=/boot/config.txt

echo '=== board ==='
tr -d '\0' </proc/device-tree/model 2>/dev/null || true
echo

echo '=== architecture ==='
echo "kernel: $(uname -m)"
echo "debian: $(dpkg --print-architecture 2>/dev/null || true)"

if [[ -f "$APP/config/settings.env" ]]; then
  set -a
  # shellcheck disable=SC1090
  source "$APP/config/settings.env"
  set +a
fi

echo '=== configured camera / AI ==='
echo "sensor: ${CAMERA_SENSOR:-imx500}"
echo "boot auto-detect: ${CAMERA_BOOT_AUTO_DETECT:-0}"
echo "boot overlay: ${CAMERA_BOOT_OVERLAY:-imx500}"
echo "AI enabled: ${AI_ENABLED:-1}"
echo "AI model: ${AI_MODEL_PATH:-$APP/models/yolov8n.rpk}"
echo "AI confidence: ${AI_CONFIDENCE:-0.50}"
echo "AI IPS: ${AI_IPS:-5}"
echo "AI classes: ${AI_VALID_CLASSES:-person,car,bird,cat,dog}"
echo "video: ${CAMERA_WIDTH:-1280}x${CAMERA_HEIGHT:-720}@${CAMERA_FPS:-15}"
echo "stream fps: ${STREAM_FPS:-6}; buffer_count: ${BUFFER_COUNT:-4}"
echo "event buffer: ${AI_PREBUFFER_SECONDS:-3}s before + ${AI_POSTBUFFER_SECONDS:-4}s after"

echo '=== boot config ==='
if [[ -f "$BOOTCFG" ]]; then
  grep -nE 'camera_auto_detect|dtoverlay=imx500|start_x|gpu_mem' "$BOOTCFG" || true
else
  echo 'config.txt not found'
fi

echo '=== camera ==='
CAMERA_LIST="$(rpicam-hello --list-cameras 2>&1 || true)"
printf '%s\n' "$CAMERA_LIST"
if printf '%s\n' "$CAMERA_LIST" | grep -qi "${CAMERA_SENSOR:-imx500}"; then
  echo "camera probe: PASS (${CAMERA_SENSOR:-imx500})"
else
  echo "camera probe: FAIL (expected ${CAMERA_SENSOR:-imx500})"
fi

echo '=== IMX500 / RP2040 ==='
dmesg | grep -Ei 'imx500|rp2040|0040|001a|clk-aicam|unicam|csi@' | tail -80 || true

echo '=== AI assets ==='
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
