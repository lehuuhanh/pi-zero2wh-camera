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
```

## Uninstall services

```bash
sudo ./uninstall.sh
```

The uninstall script preserves recordings and the project directory.
