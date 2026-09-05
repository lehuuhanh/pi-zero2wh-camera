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

# Historical variable name is kept for compatibility with existing installs.
# It now applies to BOTH video and image media below recordings/.
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

# IMPORTANT:
# Videos and images under recordings/ are temporary camera media. They are
# deleted when their last modification time is older than the retention window.
# .gitkeep placeholders and non-media files are not removed by this job.
MINUTES=$(( RETENTION_DAYS * 24 * 60 ))

echo "Media cleanup: root=$RECORDING_ROOT retention=${RETENTION_DAYS}d (video + image)"

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
    -iname '*.m4v' -o \
    -iname '*.jpg' -o \
    -iname '*.jpeg' -o \
    -iname '*.png' -o \
    -iname '*.webp' -o \
    -iname '*.bmp' -o \
    -iname '*.gif' -o \
    -iname '*.tif' -o \
    -iname '*.tiff' \
  \) \
  -mmin "+$MINUTES" \
  -print \
  -delete

# Remove empty recording subdirectories left behind by future date-based layouts.
find "$RECORDING_ROOT" -xdev -mindepth 1 -depth -type d -empty -delete 2>/dev/null || true

echo "Media cleanup complete."
