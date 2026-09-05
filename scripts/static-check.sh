#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"

echo "Static check: $ROOT"

python3 -m py_compile \
  "$ROOT/ai_worker/worker.py" \
  "$ROOT/web/main.py"

bash -n \
  "$ROOT/install.sh" \
  "$ROOT/uninstall.sh" \
  "$ROOT/sync-from-zip.sh"

for script in "$ROOT"/scripts/*.sh; do
  bash -n "$script"
done

python3 - <<PY
from pathlib import Path
root = Path(r"$ROOT")
required = [
    "ai_worker/worker.py",
    "web/main.py",
    "web/templates/index.html",
    "config/settings.env.example",
    "systemd/zero2-camera-worker.service",
    "systemd/zero2-camera-web.service",
    "systemd/zero2-camera-cleanup.service",
    "systemd/zero2-camera-cleanup.timer",
]
missing = [item for item in required if not (root / item).is_file()]
if missing:
    raise SystemExit("Missing required files: " + ", ".join(missing))
print("Required file check: OK")
PY

echo "Static check: PASS"
