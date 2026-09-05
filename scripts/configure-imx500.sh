#!/usr/bin/env bash
set -Eeuo pipefail

APP="${APP_DIR:-/home/pi/pi-zero2wh-camera}"
ENV_FILE="$APP/config/settings.env"

if [[ $EUID -ne 0 ]]; then
  exec sudo bash "$0" "$@"
fi

if [[ -f "$ENV_FILE" ]]; then
  set -a
  # shellcheck disable=SC1090
  source "$ENV_FILE"
  set +a
fi

AUTO="${CAMERA_BOOT_AUTO_DETECT:-0}"
OVERLAY="${CAMERA_BOOT_OVERLAY:-imx500}"
SENSOR="${CAMERA_SENSOR:-imx500}"

if [[ "$SENSOR" != "imx500" || "$OVERLAY" != "imx500" ]]; then
  echo "ERROR: this helper only configures Raspberry Pi AI Camera / IMX500." >&2
  echo "CAMERA_SENSOR=$SENSOR CAMERA_BOOT_OVERLAY=$OVERLAY" >&2
  exit 1
fi

BOOTCFG=""
[[ -f /boot/firmware/config.txt ]] && BOOTCFG=/boot/firmware/config.txt
[[ -z "$BOOTCFG" && -f /boot/config.txt ]] && BOOTCFG=/boot/config.txt
[[ -n "$BOOTCFG" ]] || { echo "ERROR: config.txt not found" >&2; exit 1; }

backup="$BOOTCFG.imx500.$(date +%Y%m%d-%H%M%S).bak"
cp -a "$BOOTCFG" "$backup"

# Set one camera_auto_detect value.
if grep -qE '^[[:space:]]*camera_auto_detect=' "$BOOTCFG"; then
  sed -i "s/^[[:space:]]*camera_auto_detect=.*/camera_auto_detect=${AUTO}/" "$BOOTCFG"
else
  printf '\ncamera_auto_detect=%s\n' "$AUTO" >> "$BOOTCFG"
fi

# Remove duplicate active IMX500 lines and append one canonical entry.
sed -i '/^[[:space:]]*dtoverlay=imx500[[:space:]]*$/d' "$BOOTCFG"
printf 'dtoverlay=imx500\n' >> "$BOOTCFG"

echo "Backup: $backup"
echo "Configured:"
grep -nE 'camera_auto_detect|dtoverlay=imx500|start_x|gpu_mem' "$BOOTCFG" || true

echo
if grep -qE '^[[:space:]]*(start_x|gpu_mem)=' "$BOOTCFG"; then
  echo "WARNING: legacy camera options start_x/gpu_mem are present."
  echo "They are not required for libcamera/IMX500."
fi

echo "Reboot required: sudo reboot"
