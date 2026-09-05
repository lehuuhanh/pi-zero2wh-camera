#!/usr/bin/env bash
set -Eeuo pipefail

APP="${APP_DIR:-/home/pi/pi-zero2wh-camera}"
EXAMPLE="${1:-$APP/config/settings.env.example}"
TARGET="${2:-$APP/config/settings.env}"

[[ -f "$EXAMPLE" ]] || {
  echo "ERROR: settings example not found: $EXAMPLE" >&2
  exit 1
}

if [[ ! -f "$TARGET" ]]; then
  cp "$EXAMPLE" "$TARGET"
  chmod 600 "$TARGET"
  echo "Created: $TARGET"
  exit 0
fi

declare -a missing=()

while IFS= read -r line || [[ -n "$line" ]]; do
  if [[ "$line" =~ ^([A-Z][A-Z0-9_]*)=(.*)$ ]]; then
    key="${BASH_REMATCH[1]}"
    if ! grep -qE "^${key}=" "$TARGET"; then
      missing+=("$line")
    fi
  fi
done < "$EXAMPLE"

if ((${#missing[@]} == 0)); then
  echo "Settings already contain all current keys."
  exit 0
fi

{
  echo
  echo "# =========================================================="
  echo "# Added automatically from newer settings.env.example"
  echo "# $(date -Is)"
  echo "# =========================================================="
  printf '%s\n' "${missing[@]}"
} >> "$TARGET"

chmod 600 "$TARGET"
echo "Added ${#missing[@]} missing setting(s) to: $TARGET"
