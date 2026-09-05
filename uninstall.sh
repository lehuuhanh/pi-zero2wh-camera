#!/usr/bin/env bash
set -Eeuo pipefail

if [[ $EUID -ne 0 ]]; then
  exec sudo bash "$0" "$@"
fi

systemctl disable --now \
  zero2-camera-worker \
  zero2-camera-web \
  zero2-camera-cleanup.timer \
  2>/dev/null || true

systemctl stop zero2-camera-cleanup.service 2>/dev/null || true

rm -f \
  /etc/systemd/system/zero2-camera-worker.service \
  /etc/systemd/system/zero2-camera-web.service \
  /etc/systemd/system/zero2-camera-cleanup.service \
  /etc/systemd/system/zero2-camera-cleanup.timer

rm -f \
  /etc/nginx/sites-enabled/zero2-camera.conf \
  /etc/nginx/sites-available/zero2-camera.conf \
  /etc/nginx/.zero2-camera.htpasswd

systemctl daemon-reload
systemctl reset-failed 2>/dev/null || true
nginx -t 2>/dev/null && systemctl reload nginx || true

echo "Services and cleanup timer removed."
echo "Project data and recordings under /home/pi/pi-zero2wh-camera were preserved."
