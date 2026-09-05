#!/usr/bin/env bash
set -Eeuo pipefail
if [[ $EUID -ne 0 ]]; then exec sudo bash "$0" "$@"; fi
systemctl disable --now zero2-camera-worker zero2-camera-web 2>/dev/null || true
rm -f /etc/systemd/system/zero2-camera-worker.service /etc/systemd/system/zero2-camera-web.service
rm -f /etc/nginx/sites-enabled/zero2-camera.conf /etc/nginx/sites-available/zero2-camera.conf
rm -f /etc/nginx/.zero2-camera.htpasswd
systemctl daemon-reload
nginx -t 2>/dev/null && systemctl reload nginx || true
echo "Services removed. Project data under /home/pi/pi-zero2wh-camera was preserved."
