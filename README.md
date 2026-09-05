# ⚠️ READ BEFORE INSTALLING — VIDEOS AND IMAGES IN `recordings/` ARE KEPT FOR ONLY 7 DAYS

> **IMPORTANT WARNING:** This project is designed as a low-storage camera appliance for Raspberry Pi Zero 2 W/WH. By default, **videos and images stored under `/home/pi/pi-zero2wh-camera/recordings/` are permanently deleted once they are older than 7 days**. If you need longer retention, back up important media to NAS/SMB/WebDAV/USB or change `VIDEO_RETENTION_DAYS` before long-term use.
>
> Before installation, verify that you are using the Raspberry Pi AI Camera (Sony IMX500), the correct 15-to-22-pin CSI cable for Raspberry Pi Zero 2 W/WH, a stable power supply, sufficient storage capacity, and that the camera is detected by `rpicam-hello --list-cameras`. Do not treat the `recordings/` directory as permanent storage.

# Pi Zero 2 WH AI Camera

Low-memory Raspberry Pi Zero 2 W/WH camera project for the Raspberry Pi AI Camera (Sony IMX500), Raspberry Pi OS 64-bit, and headless/OS Lite systems.

This project keeps the Flask + HTTPS + ZIP-sync workflow and selected ideas from `LukeDitria/mini_ai_camera`:

- IMX500 YOLO object detection
- class filtering
- EMA/hysteresis event triggering
- circular H.264 pre-event buffer
- automatic AI event video + snapshot
- bounding boxes in the browser stream
- low-memory tuning for 512 MB Pi Zero 2 W/WH
- automatic media retention cleanup

See `THIRD_PARTY_NOTICES.md` for attribution and license details.

## Zero 2 WH defaults

```text
Camera             1280x720 @ 15 fps
Browser MJPEG      6 fps
JPEG quality       68
Picamera2 buffers  4
AI parse rate      5 IPS
AI model           YOLOv8n IMX500 .rpk
Valid classes      person,car,bird,cat,dog
Pre-event video    3 seconds
Post-event video   4 seconds
H.264 bitrate      4 Mbit/s
Media retention    7 days (video + image)
Worker             127.0.0.1:8091
Web backend        127.0.0.1:8080
HTTPS              443
```

The AI inference runs on IMX500. The Zero 2 CPU is mainly used for web, JPEG generation, event control and file handling.

## Fast OS-Python install / update

Unlike `camera-app`, this Zero 2 project intentionally uses Raspberry Pi OS Python directly:

```text
/usr/bin/python3
```

There is no project venv and the installer does not run pip. Both worker and web services use OS-managed Python packages such as:

```text
python3-picamera2
python3-libcamera
python3-pil
python3-numpy
python3-flask
python3-requests
python3-waitress
```

This avoids rebuilding or duplicating Python environments on the 512 MB Pi Zero 2 W/WH and keeps Picamera2/libcamera on the Raspberry Pi OS package ABI.

`install.sh` checks actual installed packages instead of blindly reinstalling everything:

```text
package missing                    -> install only that package
installed version < apt candidate -> upgrade only that old package
already current                   -> skip install/upgrade
```

APT metadata is cached with:

```text
/var/lib/zero2-camera/apt-update.stamp
```

and is refreshed at most once every 24 hours by default when all required packages are already present. Override for one invocation if needed:

```bash
sudo APT_REFRESH_HOURS=6 /home/pi/pi-zero2wh-camera/install.sh
```

Repeated install/update also skips work that is already current:

```text
AI model already present          -> skip download
IMX500 boot config already right  -> skip rewrite/backup
systemd units unchanged           -> skip copy + daemon-reload
TLS certificate already present   -> skip regeneration
Nginx config unchanged            -> skip copy/reload
source/settings unchanged         -> skip worker/web restart
```

Installation state is stored at:

```text
/var/lib/zero2-camera/install-state.env
```

`requirements.txt` is documentation only for this project; it is not passed to pip.

## First install from ZIP

On Windows download:

```text
https://github.com/lehuuhanh/pi-zero2wh-camera/archive/refs/heads/main.zip
```

Copy it to the Pi:

```powershell
scp "C:\Users\user\Downloads\pi-zero2wh-camera-main.zip" pi@PI_IP:/home/pi/
```

On Raspberry Pi OS Lite:

```bash
mkdir -p /home/pi/zero2-install
unzip -q /home/pi/pi-zero2wh-camera-main.zip -d /home/pi/zero2-install

cd /home/pi/zero2-install/pi-zero2wh-camera-main
chmod +x sync-from-zip.sh
sudo ./sync-from-zip.sh
```

If `unzip` or `rsync` is missing, the ZIP updater installs only the missing tool.

Edit the local configuration:

```bash
nano /home/pi/pi-zero2wh-camera/config/settings.env
```

Change at least:

```text
NGINX_BASIC_PASSWORD=your-password
```

Then rerun the same optimized installer:

```bash
sudo /home/pi/pi-zero2wh-camera/install.sh
```

If the installer changes the IMX500 overlay:

```bash
sudo reboot
```

After reboot:

```bash
rpicam-hello --list-cameras
/home/pi/pi-zero2wh-camera/scripts/healthcheck.sh
```

Open:

```text
https://PI_IP/
```

## Future ZIP update

Copy a fresh GitHub ZIP from Windows to `/home/pi/`, then run:

```bash
sudo /home/pi/pi-zero2wh-camera/sync-from-zip.sh \
  /home/pi/pi-zero2wh-camera-main.zip
```

The updater uses `rsync --itemize-changes`, preserves runtime state, then enters the same optimized `install.sh` path.

Preserved data:

```text
config/settings.env
recordings/
data/
models/*.rpk
.git/
```

No `git`, `gh auth login`, `git pull`, or GitHub authentication is required on the Pi for ZIP updates.

## IMX500 YOLO model

The binary `.rpk` model is intentionally not committed to this repository. During install or ZIP sync, when AI is enabled and the model is missing:

```bash
scripts/install-mini-ai-assets.sh
```

downloads the YOLOv8n IMX500 model from the upstream `LukeDitria/mini_ai_camera` repository.

If model and labels already exist, future installer runs skip the download.

Manual install/update:

```bash
cd /home/pi/pi-zero2wh-camera
./scripts/install-mini-ai-assets.sh
```

Force refresh:

```bash
./scripts/install-mini-ai-assets.sh --force
```

If the download is unavailable, the worker falls back to camera-only mode instead of making the whole camera service unusable.

## AI event logic

The detector keeps an exponential moving average for each configured class. This avoids starting/stopping events because of one noisy frame.

Defaults:

```text
AI_EMA_ALPHA=0.25
AI_EVENT_ACTIVATE=0.60
AI_EVENT_DEACTIVATE=0.35
```

The separate activation/deactivation thresholds provide hysteresis.

When an event starts, the continuously running H.264 circular buffer saves the previous few seconds too:

```text
AI_PREBUFFER_SECONDS=3
AI_POSTBUFFER_SECONDS=4
AI_EVENT_MAX_SECONDS=60
```

AI events are written under `recordings/events/`, manual recordings under `recordings/manual/`, and snapshots under `recordings/snapshots/`.

## AI settings

Main options in `config/settings.env`:

```text
AI_ENABLED=1
AI_MODEL_PATH=/home/pi/pi-zero2wh-camera/models/yolov8n.rpk
AI_LABELS_PATH=/home/pi/pi-zero2wh-camera/models/coco_labels.txt
AI_VALID_CLASSES=person,car,bird,cat,dog
AI_CONFIDENCE=0.50
AI_IOU_THRESHOLD=0.50
AI_IPS=5
AI_DRAW_BOXES=1
AI_EMA_ALPHA=0.25
AI_EVENT_ACTIVATE=0.60
AI_EVENT_DEACTIVATE=0.35
AI_EVENT_VIDEO_ENABLED=1
AI_EVENT_IMAGE_ENABLED=1
AI_PREBUFFER_SECONDS=3
AI_POSTBUFFER_SECONDS=4
AI_EVENT_MAX_SECONDS=60
AI_EVENT_COOLDOWN_SECONDS=3
```

To disable AI but keep streaming/manual recording:

```text
AI_ENABLED=0
```

Then restart:

```bash
sudo systemctl restart zero2-camera-worker
```

## Low-memory tuning

If the Zero 2 WH is short on RAM:

```text
CAMERA_WIDTH=960
CAMERA_HEIGHT=540
CAMERA_FPS=12
STREAM_FPS=4
JPEG_QUALITY=62
BUFFER_COUNT=3
AI_IPS=3
AI_DRAW_BOXES=0
AI_PREBUFFER_SECONDS=2
RECORD_BITRATE=2500000
```

For a headless appliance:

```bash
sudo systemctl set-default multi-user.target
sudo reboot
```

## ⚠️ AUTOMATIC MEDIA CLEANUP — VIDEOS AND IMAGES ARE KEPT FOR ONLY 7 DAYS

By default, retention cleanup applies to **both videos and images** under:

```text
/home/pi/pi-zero2wh-camera/recordings/
├── manual/
├── events/
└── snapshots/
```

Default setting:

```text
VIDEO_RETENTION_DAYS=7
```

The variable name is retained for backward compatibility with existing installations, but it now applies to both video and image media. Cleanup removes common formats such as H.264/MP4/MKV/MOV/AVI/WEBM and JPG/JPEG/PNG/WEBP/BMP/GIF/TIFF once a file is older than the configured retention period.

**Files removed by the cleanup job are permanently deleted.** Back up valuable videos or images to another device or host before the 7-day retention period expires. `.gitkeep` placeholders and non-media files are not removed by this job.

Check the timer:

```bash
systemctl list-timers zero2-camera-cleanup.timer
```

Run immediately:

```bash
sudo systemctl start zero2-camera-cleanup.service
```

Logs:

```bash
journalctl -u zero2-camera-cleanup.service -n 100 --no-pager
```

## Service status

```bash
systemctl status \
  zero2-camera-worker \
  zero2-camera-web \
  zero2-camera-cleanup.timer \
  nginx \
  --no-pager -l
```

Both worker and web use OS Python. The web service starts Waitress with:

```text
/usr/bin/python3 -m waitress
```

Worker log:

```bash
journalctl -u zero2-camera-worker -f
```

Health:

```bash
curl -s http://127.0.0.1:8091/health | python3 -m json.tool
```

## Build a portable ZIP locally

After the AI model has been downloaded, this command also packages the local model into the ZIP so another Pi can be installed without downloading it again:

```bash
sudo apt install -y zip rsync
cd /home/pi/pi-zero2wh-camera
./scripts/build-zip.sh
```

Output:

```text
/home/pi/pi-zero2wh-camera/pi-zero2wh-camera.zip
```

Local credentials, recordings and runtime data are excluded.

## Uninstall services

```bash
cd /home/pi/pi-zero2wh-camera
sudo ./uninstall.sh
```

Recordings and project data are preserved until the configured retention cleanup removes eligible media files.
