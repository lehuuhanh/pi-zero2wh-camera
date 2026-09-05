#!/usr/bin/env bash
set -u

APP="${APP_DIR:-/home/pi/pi-zero2wh-camera}"
BOOTCFG=/boot/firmware/config.txt
[[ -f "$BOOTCFG" ]] || BOOTCFG=/boot/config.txt

echo '=== board ==='
tr -d '\0' </proc/device-tree/model 2>/dev/null || true
echo

echo '=== boot config ==='
if [[ -f "$BOOTCFG" ]]; then
  grep -nE 'camera_auto_detect|dtoverlay=imx500|start_x|gpu_mem' "$BOOTCFG" || true
else
  echo 'config.txt not found'
fi

echo
echo '=== camera list ==='
rpicam-hello --list-cameras 2>&1 || true

echo
echo '=== IMX500 / RP2040 probe ==='
dmesg | grep -Ei 'imx500|rp2040|0040|001a|clk-aicam|unicam|csi@|camera' | tail -160 || true

echo
echo '=== I2C devices ==='
ls -l /dev/i2c* 2>/dev/null || true
for dev in 10-0040 10-001a 11-0040 11-001a; do
  path="/sys/bus/i2c/devices/$dev"
  if [[ -e "$path" ]]; then
    printf '%s: present' "$dev"
    if [[ -L "$path/driver" ]]; then
      printf ' driver=%s' "$(basename "$(readlink -f "$path/driver")")"
    else
      printf ' driver=UNBOUND'
    fi
    echo
  fi
done

echo
echo '=== kernel modules ==='
lsmod | grep -Ei 'imx500|rp2040|unicam|bcm2835' || true

echo
echo '=== packages ==='
dpkg -l 2>/dev/null | grep -E 'imx500|rpicam|libcamera|picamera2' || true

echo
echo '=== worker ==='
systemctl --no-pager --full status zero2-camera-worker.service 2>&1 | tail -50 || true

echo
echo '=== interpretation ==='
if rpicam-hello --list-cameras 2>&1 | grep -qi 'imx500'; then
  echo 'PASS: IMX500 is registered with libcamera.'
elif dmesg | grep -qi 'rp2040-gpio-bridge.*found dev ID'; then
  echo 'PARTIAL: RP2040 bridge is alive, but IMX500 did not register.'
  echo 'Inspect IMX500/clock/power probe lines above.'
else
  echo 'FAIL: RP2040 bridge did not report a device ID and IMX500 is unavailable.'
  echo 'With dtoverlay=imx500 loaded, first reseat/check the Zero 22-pin camera cable at both ends.'
  echo 'If another known-good cable/Pi gives the same result, investigate the AI Camera board/RP2040 firmware.'
fi

echo
echo "Project: $APP"
