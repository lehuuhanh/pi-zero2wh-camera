#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="${1:-$ROOT/pi-zero2wh-camera.zip}"
TMP="$(mktemp -d /tmp/pi-zero2wh-camera-zip.XXXXXX)"
trap 'rm -rf -- "$TMP"' EXIT

command -v rsync >/dev/null 2>&1 || {
  echo "ERROR: rsync is required" >&2
  exit 1
}
command -v zip >/dev/null 2>&1 || {
  echo "ERROR: zip is required" >&2
  exit 1
}

DEST="$TMP/pi-zero2wh-camera"
mkdir -p "$DEST"

# A locally downloaded models/*.rpk file is intentionally included so the
# resulting ZIP can be copied to another Pi without downloading the model.
rsync -a \
  --exclude '/.git/' \
  --exclude '/config/settings.env' \
  --exclude '/recordings/*' \
  --exclude '/data/*' \
  --exclude '/pi-zero2wh-camera.zip' \
  --exclude '__pycache__/' \
  --exclude '*.pyc' \
  "$ROOT"/ "$DEST"/

mkdir -p \
  "$DEST/recordings/manual" \
  "$DEST/recordings/events" \
  "$DEST/recordings/snapshots" \
  "$DEST/data" \
  "$DEST/models"

rm -f -- "$OUT"
(
  cd "$TMP"
  zip -qr "$OUT" pi-zero2wh-camera
)

echo "Created: $OUT"
ls -lh "$OUT"
if [[ -s "$ROOT/models/yolov8n.rpk" ]]; then
  echo "AI model included in ZIP."
else
  echo "AI model not present locally; installer will download it on the target Pi."
fi
