#!/usr/bin/env bash
set -u
echo '=== board ==='
tr -d '\0' </proc/device-tree/model 2>/dev/null; echo
echo '=== camera ==='
rpicam-hello --list-cameras 2>&1 || true
echo '=== services ==='
systemctl --no-pager --full status zero2-camera-worker zero2-camera-web nginx 2>&1 | tail -80
echo '=== ports ==='
ss -lntp 2>/dev/null | grep -E ':8091|:8080|:443|:80' || true
echo '=== worker health ==='
curl -fsS http://127.0.0.1:8091/health 2>/dev/null || true; echo
echo '=== memory ==='
free -h
