# Pi Zero 2 WH Camera

Low-memory Raspberry Pi Zero 2 W/WH camera project, tuned for Raspberry Pi AI Camera (Sony IMX500) on Raspberry Pi OS 64-bit.

## Defaults

- Capture: 1280x720 @ 15 fps
- Browser MJPEG: 6 fps
- JPEG quality: 68
- Picamera2 buffers: 4
- Worker: Flask on 127.0.0.1:8091
- Web proxy: Waitress on 127.0.0.1:8080
- Nginx HTTPS: 443
- Recording: H.264 from the active low-memory stream
- Video retention: automatically delete video files older than 7 days

## Easiest install: ZIP, no Git required

This project can be installed and updated on Raspberry Pi OS Lite without GitHub CLI and without `git`.

On Windows, download the repository as ZIP or copy a prepared `pi-zero2wh-camera.zip` to the Pi, for example:

```powershell
scp "C:\Users\Hanh\Downloads\pi-zero2wh-camera.zip" pi@PI_IP:/home/pi/
```

First install on the Pi:

```bash
sudo apt update
sudo apt install -y unzip
cd /home/pi
rm -rf /home/pi/pi-zero2wh-camera-new
mkdir -p /home/pi/pi-zero2wh-camera-new
unzip -q /home/pi/pi-zero2wh-camera.zip -d /home/pi/pi-zero2wh-camera-new
cd /home/pi/pi-zero2wh-camera-new/pi-zero2wh-camera
chmod +x install.sh sync-from-zip.sh scripts/*.sh
sudo ./sync-from-zip.sh
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

If the IMX500 overlay was changed, reboot:

```bash
sudo reboot
```

After reboot:

```bash
rpicam-hello --list-cameras
sudo systemctl restart zero2-camera-worker zero2-camera-web nginx
/home/pi/pi-zero2wh-camera/scripts/healthcheck.sh
```

Open:

```text
https://PI_IP/
```

## Updating later with one ZIP

Copy the new ZIP from Windows to `/home/pi/pi-zero2wh-camera.zip`, then run only:

```bash
cd /home/pi/pi-zero2wh-camera
sudo ./sync-from-zip.sh /home/pi/pi-zero2wh-camera.zip
```

The ZIP sync updater automatically installs `unzip`/`rsync` if missing, replaces project source files, refreshes systemd units, enables the cleanup timer, and restarts installed camera services.

It deliberately preserves:

```text
config/settings.env
recordings/
data/
.git/
```

So your password, local settings, recordings, snapshots, and runtime database are not overwritten by an update ZIP.

Check after sync:

```bash
/home/pi/pi-zero2wh-camera/scripts/healthcheck.sh
systemctl status zero2-camera-worker zero2-camera-web --no-pager -l
```

## Build a clean ZIP

From a checked-out project directory:

```bash
sudo apt install -y zip rsync
chmod +x scripts/build-zip.sh
./scripts/build-zip.sh
```

This creates:

```text
pi-zero2wh-camera.zip
```

The ZIP excludes `.git`, local `config/settings.env`, recordings, runtime data, Python cache files, and old ZIP output.

## Git install/update is optional

If Git is available, the normal workflow still works:

```bash
git clone https://github.com/lehuuhanh/pi-zero2wh-camera.git
cd pi-zero2wh-camera
cp config/settings.env.example config/settings.env
chmod 600 config/settings.env
nano config/settings.env
sudo ./install.sh
```

Later:

```bash
cd /home/pi/pi-zero2wh-camera
git pull
```

`config/settings.env` is intentionally ignored by Git so credentials are not committed.

## Automatic video cleanup

By default, all video files under `recordings/` older than 7 days are deleted automatically. The cleanup recognizes `.h264`, `.264`, `.mp4`, `.mkv`, `.mov`, `.avi`, `.webm`, `.ts`, and `.m4v`. Snapshot images are preserved.

The retention period is configured in `config/settings.env`:

```text
VIDEO_RETENTION_DAYS=7
```

The installer enables `zero2-camera-cleanup.timer`, which runs once per day and is persistent across shutdowns.

Check the next cleanup run:

```bash
systemctl list-timers zero2-camera-cleanup.timer
```

Run cleanup immediately:

```bash
sudo systemctl start zero2-camera-cleanup.service
```

View cleanup logs:

```bash
journalctl -u zero2-camera-cleanup.service --no-pager
```

Test the cleanup script directly:

```bash
/home/pi/pi-zero2wh-camera/scripts/cleanup-videos.sh
```

To keep videos for 14 days instead, change:

```text
VIDEO_RETENTION_DAYS=14
```

No service restart is required; the next cleanup reads the updated value.

## Boot configuration

The installer backs up the active `config.txt`, then sets:

```ini
camera_auto_detect=0
dtoverlay=imx500
```

Set `FORCE_IMX500_OVERLAY=0` before install if you do not want this behavior.

## Memory tuning

If RAM is still tight, use:

```text
CAMERA_WIDTH=960
CAMERA_HEIGHT=540
CAMERA_FPS=12
STREAM_FPS=4
JPEG_QUALITY=62
BUFFER_COUNT=3
```

For a headless camera appliance:

```bash
sudo systemctl set-default multi-user.target
sudo reboot
```

## Logs

```bash
journalctl -u zero2-camera-worker -f
journalctl -u zero2-camera-web -f
journalctl -u zero2-camera-cleanup.service --no-pager
```

## Uninstall services

```bash
sudo ./uninstall.sh
```

The uninstall script removes the camera services and cleanup timer but preserves recordings and the project directory.
