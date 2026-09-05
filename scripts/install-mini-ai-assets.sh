#!/usr/bin/env bash
set -Eeuo pipefail

APP="${APP_DIR:-/home/pi/pi-zero2wh-camera}"
ENV_FILE="$APP/config/settings.env"
FORCE=0
[[ "${1:-}" == "--force" ]] && FORCE=1

if [[ -r "$ENV_FILE" ]]; then
  set -a
  # shellcheck disable=SC1090
  source "$ENV_FILE"
  set +a
fi

MODEL="${AI_MODEL_PATH:-$APP/models/yolov8n.rpk}"
LABELS="${AI_LABELS_PATH:-$APP/models/coco_labels.txt}"
MODEL_URL="${AI_MODEL_DOWNLOAD_URL:-https://raw.githubusercontent.com/LukeDitria/mini_ai_camera/main/models/yolov8n.rpk}"
LABELS_URL="${AI_LABELS_DOWNLOAD_URL:-https://raw.githubusercontent.com/LukeDitria/mini_ai_camera/main/models/coco_labels.txt}"

command -v curl >/dev/null 2>&1 || {
  echo "ERROR: curl is required" >&2
  exit 1
}

mkdir -p "$(dirname "$MODEL")" "$(dirname "$LABELS")"

download() {
  local url="$1"
  local dest="$2"
  local tmp="${dest}.download.$$"

  echo "Downloading: $url"
  curl -fL --retry 3 --retry-delay 2 --connect-timeout 15 \
    --max-time 300 \
    -o "$tmp" "$url"

  [[ -s "$tmp" ]] || {
    rm -f "$tmp"
    echo "ERROR: downloaded file is empty: $url" >&2
    return 1
  }

  mv -f "$tmp" "$dest"
  chmod 0644 "$dest"
  echo "Installed: $dest ($(stat -c '%s' "$dest") bytes)"
}

if (( FORCE )) || [[ ! -s "$MODEL" ]]; then
  download "$MODEL_URL" "$MODEL"
else
  echo "Model already present: $MODEL"
fi

if (( FORCE )) || [[ ! -s "$LABELS" ]]; then
  download "$LABELS_URL" "$LABELS"
else
  echo "Labels already present: $LABELS"
fi

echo "mini_ai_camera-compatible AI assets are ready."
