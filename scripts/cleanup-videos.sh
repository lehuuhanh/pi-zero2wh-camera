#!/usr/bin/env bash
set -Eeuo pipefail

APP="/home/pi/pi-zero2wh-camera"
ENV_FILE="$APP/config/settings.env"

if [[ -f "$ENV_FILE" ]]; then
  set -a
  # shellcheck disable=SC1090
  source "$ENV_FILE"
  set +a
fi

RETENTION_DAYS="${VIDEO_RETENTION_DAYS:-7}"
RECORDING_ROOT="${RECORDING_ROOT:-$APP/recordings}"

if ! [[ "$RETENTION_DAYS" =~ ^[0-9]+$ ]] || (( RETENTION_DAYS < 1 )); then
  echo "ERROR: VIDEO_RETENTION_DAYS must be an integer >= 1; got: $RETENTION_DAYS" >&2
  exit 2
fi

if [[ ! -d "$RECORDING_ROOT" ]]; then
  echo "Recording directory does not exist: $RECORDING_ROOT"
  exit 0
fi

# Delete video files whose last modification is older than the retention window.
# Snapshots/images are intentionally preserved.
MINUTES=$(( RETENTION_DAYS * 24 * 60 ))

echo "Video cleanup: root=$RECORDING_ROOT retention=${RETENTION_DAYS}d"

find "$RECORDING_ROOT" -xdev -type f \
  \( \
    -iname '*.h264' -o \
    -iname '*.264' -o \
    -iname '*.mp4' -o \
    -iname '*.mkv' -o \
    -iname '*.mov' -o \
    -iname '*.avi' -o \
    -iname '*.webm' -o \
    -iname '*.ts' -o \
    -iname '*.m4v' \
  \) \
  -mmin "+$MINUTES" \
  -print \
  -delete

# Remove empty recording subdirectories left behind by future date-based layouts.
find "$RECORDING_ROOT" -xdev -mindepth 1 -depth -type d -empty -delete 2>/dev/null || true

echo "Video cleanup complete."
