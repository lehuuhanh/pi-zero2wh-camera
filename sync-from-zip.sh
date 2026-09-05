#!/usr/bin/env bash
set -Eeuo pipefail

APP="${APP_DIR:-/home/pi/pi-zero2wh-camera}"
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SOURCE=""
TMP=""

cleanup() {
  [[ -n "$TMP" && -d "$TMP" ]] && rm -rf -- "$TMP"
}
trap cleanup EXIT

if [[ $EUID -ne 0 ]]; then
  exec sudo -E bash "$0" "$@"
fi

need_pkg=()
command -v unzip >/dev/null 2>&1 || need_pkg+=(unzip)
command -v rsync >/dev/null 2>&1 || need_pkg+=(rsync)
if ((${#need_pkg[@]})); then
  apt update
  apt install -y "${need_pkg[@]}"
fi

if [[ $# -ge 1 ]]; then
  ZIP="$1"
  [[ -f "$ZIP" ]] || {
    echo "ERROR: ZIP not found: $ZIP" >&2
    exit 1
  }

  TMP="$(mktemp -d /tmp/pi-zero2wh-camera-sync.XXXXXX)"
  unzip -q "$ZIP" -d "$TMP"

  if [[ -f "$TMP/install.sh" ]]; then
    SOURCE="$TMP"
  else
    SOURCE="$(find "$TMP" -mindepth 1 -maxdepth 2 -type f -name install.sh -printf '%h\n' | head -1)"
  fi

  [[ -n "$SOURCE" && -f "$SOURCE/install.sh" ]] || {
    echo "ERROR: install.sh not found inside ZIP" >&2
    exit 1
  }
else
  SOURCE="$SELF_DIR"
fi

if [[ -f "$SOURCE/scripts/static-check.sh" ]]; then
  bash "$SOURCE/scripts/static-check.sh" "$SOURCE"
fi

if [[ "$(readlink -f "$SOURCE")" == "$(readlink -f "$APP" 2>/dev/null || true)" ]]; then
  echo "Source already is $APP; no file copy required."
else
  install -d -o pi -g pi "$APP"
  echo "Syncing changed source: $SOURCE -> $APP"
  echo "Preserving: config/settings.env, recordings/, data/, models/*.rpk, .git/"

  rsync -a --delete --itemize-changes \
    --exclude '/config/settings.env' \
    --exclude '/recordings/' \
    --exclude '/data/' \
    --exclude '/models/*.rpk' \
    --exclude '/.git/' \
    --exclude '__pycache__/' \
    --exclude '*.pyc' \
    "$SOURCE"/ "$APP"/
fi

if [[ ! -f "$APP/config/settings.env" ]]; then
  cp "$APP/config/settings.env.example" "$APP/config/settings.env"
  chown pi:pi "$APP/config/settings.env"
  chmod 600 "$APP/config/settings.env"
fi

chmod 0755 "$APP/install.sh" "$APP/uninstall.sh" "$APP/sync-from-zip.sh" "$APP"/scripts/*.sh

# Use exactly the same smart installation path for first install and updates.
# install.sh reuses /usr/bin/python3 + Raspberry Pi OS packages, skips packages
# already installed at the current apt candidate version, upgrades only old
# versions, skips existing AI assets, unchanged systemd/Nginx files and avoids
# unnecessary service restarts.
cleanup
trap - EXIT
exec "$APP/install.sh"
