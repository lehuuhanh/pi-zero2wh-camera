# Pi Zero 2 WH AI Camera

Low-memory Raspberry Pi Zero 2 W/WH camera project for the Raspberry Pi AI Camera (Sony IMX500), Raspberry Pi OS 64-bit, and headless/OS Lite systems.

This project keeps the existing Flask + HTTPS + ZIP-sync workflow and now combines selected ideas from `LukeDitria/mini_ai_camera`:

- IMX500 YOLO object detection
- class filtering
- EMA/hysteresis event triggering
- circular H.264 pre-event buffer
- automatic AI event video + snapshot
- bounding boxes in the browser stream
- low-memory tuning for 512 MB Pi Zero 2 W/WH
- automatic video retention cleanup

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
Video retention    7 days
Worker             127.0.0.1:8091
Web backend        127.0.0.1:8080
HTTPS              443
```

The AI inference runs on IMX500. The Zero 2 CPU is mainly used for web, JPEG generation, event control and file handling.

## Easiest first install from ZIP

On Windows download:

```text
https://github.com/lehuuhanh/pi-zero2wh-camera/archive/refs/heads/main.zip
```

Copy it to the Pi:

```powershell
scp "C:\Users\Hanh\Downloads\pi-zero2wh-camera-main.zip" pi@PI_IP:/home/pi/
```

On Raspberry Pi OS Lite:

```bash
sudo apt update
sudo apt install -y unzip

mkdir -p /home/pi/zero2-install
unzip -q /home/pi/pi-zero2wh-camera-main.zip -d /home/pi/zero2-install

cd /home/pi/zero2-install/pi-zero2wh-camera-main
chmod +x sync-from-zip.sh
sudo ./sync-from-zip.sh
```

Edit the local configuration:

```bash
nano /home/pi/pi-zero2wh-camera/config/settings.env
```

Change at least:

```text
NGINX_BASIC_PASSWORD=your-password
```

Then install:

```bash
cd /home/pi/pi-zero2wh-camera
sudo ./install.sh
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

## Easiest future update

Copy a fresh GitHub ZIP from Windows to `/home/pi/`, then run only:

```bash
sudo /home/pi/pi-zero2wh-camera/sync-from-zip.sh \
  /home/pi/pi-zero2wh-camera-main.zip
```

The sync preserves:

```text
config/settings.env
recordings/
data/
models/*.rpk
.git/
```

It also merges newly introduced settings into the existing `config/settings.env` without overwriting existing values or passwords.

No `git`, `gh auth login`, `git pull`, or GitHub authentication is required on the Pi for ZIP updates.

## IMX500 YOLO model

The binary `.rpk` model is intentionally not committed to this repository. During install or ZIP sync, when AI is enabled and the model is missing:

```bash
scripts/install-mini-ai-assets.sh
```

downloads the YOLOv8n IMX500 model from the upstream `LukeDitria/mini_ai_camera` repository.

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

AI events are written under:

```text
recordings/events/
```

Manual recordings remain under:

```text
recordings/manual/
```

Snapshots remain under:

```text
recordings/snapshots/
```

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

To monitor only people and cars:

```text
AI_VALID_CLASSES=person,car
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

## Automatic video cleanup

Video files older than the configured retention period are removed once per day:

```text
VIDEO_RETENTION_DAYS=7
```

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

Snapshot/JPEG images are preserved by the video retention script.

## Service status

```bash
systemctl status \
  zero2-camera-worker \
  zero2-camera-web \
  zero2-camera-cleanup.timer \
  nginx \
  --no-pager -l
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

Recordings and project data are preserved.
