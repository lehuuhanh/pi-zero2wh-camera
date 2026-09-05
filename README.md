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

## Install

Clone/copy the project to the Pi, create the local settings file, then edit it:

```bash
cp config/settings.env.example config/settings.env
chmod 600 config/settings.env
nano config/settings.env
```

`config/settings.env` is intentionally ignored by Git so credentials are not committed. If it is missing, `install.sh` creates it from the example and asks you to rerun the installer.

Change at least:

```text
NGINX_BASIC_PASSWORD=your-password
```

Then:

```bash
chmod +x install.sh
sudo ./install.sh
```

The installer forces the IMX500 overlay by default and therefore may require a reboot.

```bash
sudo reboot
```

After reboot:

```bash
rpicam-hello --list-cameras
sudo systemctl restart zero2-camera-worker zero2-camera-web nginx
./scripts/healthcheck.sh
```

Open:

```text
https://PI_IP/
```

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

then no service restart is required; the next cleanup reads the updated value.

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
