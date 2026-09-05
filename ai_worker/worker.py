from __future__ import annotations

import io
import os
import signal
import threading
import time
from pathlib import Path

from flask import Flask, Response, jsonify, request
from picamera2 import Picamera2
from picamera2.encoders import H264Encoder
from picamera2.outputs import FileOutput
from PIL import Image

APP_DIR = Path(os.getenv("APP_DIR", "/home/pi/pi-zero2wh-camera"))
HOST = os.getenv("HOST", "127.0.0.1")
PORT = int(os.getenv("WORKER_PORT", "8091"))
WIDTH = int(os.getenv("CAMERA_WIDTH", "1280"))
HEIGHT = int(os.getenv("CAMERA_HEIGHT", "720"))
FPS = int(os.getenv("CAMERA_FPS", "15"))
STREAM_FPS = max(1, int(os.getenv("STREAM_FPS", "6")))
JPEG_QUALITY = max(30, min(95, int(os.getenv("JPEG_QUALITY", "68"))))
BUFFER_COUNT = max(3, min(8, int(os.getenv("BUFFER_COUNT", "4"))))
RECORD_WIDTH = int(os.getenv("RECORD_WIDTH", "1920"))
RECORD_HEIGHT = int(os.getenv("RECORD_HEIGHT", "1080"))
RECORD_FPS = int(os.getenv("RECORD_FPS", "15"))
RECORD_BITRATE = int(os.getenv("RECORD_BITRATE", "6000000"))

RECORD_ROOT = APP_DIR / "recordings"
MANUAL_DIR = RECORD_ROOT / "manual"
SNAPSHOT_DIR = RECORD_ROOT / "snapshots"
MANUAL_DIR.mkdir(parents=True, exist_ok=True)
SNAPSHOT_DIR.mkdir(parents=True, exist_ok=True)

app = Flask(__name__)


class CameraEngine:
    def __init__(self) -> None:
        self.lock = threading.RLock()
        self.cond = threading.Condition()
        self.stop_event = threading.Event()
        self.picam2 = Picamera2()
        self.started_at = time.time()
        self.last_frame_ts = 0.0
        self.frame_seq = 0
        self.jpeg = b""
        self.recording = False
        self.recording_file: str | None = None
        self.encoder: H264Encoder | None = None
        self._configure_preview()

    def _configure_preview(self) -> None:
        config = self.picam2.create_video_configuration(
            main={"size": (WIDTH, HEIGHT), "format": "RGB888"},
            controls={"FrameRate": FPS},
            buffer_count=BUFFER_COUNT,
        )
        self.picam2.configure(config)

    def start(self) -> None:
        self.picam2.start()
        threading.Thread(target=self._frame_loop, daemon=True, name="camera-frame-loop").start()

    def _frame_loop(self) -> None:
        interval = 1.0 / STREAM_FPS
        next_frame = 0.0
        while not self.stop_event.is_set():
            now = time.monotonic()
            if now < next_frame:
                time.sleep(min(0.02, next_frame - now))
                continue
            next_frame = now + interval
            try:
                array = self.picam2.capture_array("main")
                image = Image.fromarray(array)
                buf = io.BytesIO()
                image.save(buf, format="JPEG", quality=JPEG_QUALITY, optimize=False)
                jpeg = buf.getvalue()
                with self.cond:
                    self.jpeg = jpeg
                    self.frame_seq += 1
                    self.last_frame_ts = time.time()
                    self.cond.notify_all()
            except Exception as exc:
                print(f"frame loop error: {exc}", flush=True)
                time.sleep(0.5)

    def mjpeg(self):
        last = -1
        while not self.stop_event.is_set():
            with self.cond:
                self.cond.wait_for(lambda: self.frame_seq != last or self.stop_event.is_set(), timeout=5)
                if self.stop_event.is_set():
                    break
                last = self.frame_seq
                frame = self.jpeg
            if not frame:
                continue
            yield (
                b"--frame\r\n"
                b"Content-Type: image/jpeg\r\n"
                b"Content-Length: " + str(len(frame)).encode() + b"\r\n\r\n" + frame + b"\r\n"
            )

    def snapshot(self) -> str:
        with self.lock:
            stamp = time.strftime("%Y%m%d-%H%M%S")
            path = SNAPSHOT_DIR / f"snapshot-{stamp}.jpg"
            request_obj = self.picam2.capture_request()
            try:
                request_obj.save("main", str(path))
            finally:
                request_obj.release()
            return str(path.relative_to(RECORD_ROOT))

    def start_recording(self) -> str:
        with self.lock:
            if self.recording:
                raise RuntimeError("recording already active")
            stamp = time.strftime("%Y%m%d-%H%M%S")
            path = MANUAL_DIR / f"record-{stamp}.h264"
            # Keep the low-memory preview configuration; encode the same stream.
            self.encoder = H264Encoder(bitrate=RECORD_BITRATE)
            self.picam2.start_encoder(self.encoder, FileOutput(str(path)), name="main")
            self.recording = True
            self.recording_file = str(path.relative_to(RECORD_ROOT))
            return self.recording_file

    def stop_recording(self) -> str | None:
        with self.lock:
            if not self.recording:
                return self.recording_file
            self.picam2.stop_encoder(self.encoder)
            current = self.recording_file
            self.encoder = None
            self.recording = False
            return current

    def status(self) -> dict:
        props = self.picam2.camera_properties
        return {
            "ok": True,
            "camera": props.get("Model", "unknown"),
            "resolution": [WIDTH, HEIGHT],
            "camera_fps": FPS,
            "stream_fps": STREAM_FPS,
            "jpeg_quality": JPEG_QUALITY,
            "buffer_count": BUFFER_COUNT,
            "recording": self.recording,
            "recording_file": self.recording_file,
            "last_frame_age": None if not self.last_frame_ts else round(time.time() - self.last_frame_ts, 3),
            "uptime_seconds": int(time.time() - self.started_at),
        }

    def stop(self) -> None:
        self.stop_event.set()
        try:
            if self.recording:
                self.stop_recording()
        except Exception:
            pass
        try:
            self.picam2.stop()
            self.picam2.close()
        except Exception:
            pass


engine = CameraEngine()
engine.start()


@app.get("/health")
def health():
    return jsonify(engine.status())


@app.get("/stream.mjpg")
def stream():
    return Response(
        engine.mjpeg(),
        mimetype="multipart/x-mixed-replace; boundary=frame",
        headers={"Cache-Control": "no-store", "X-Accel-Buffering": "no"},
    )


@app.post("/snapshot")
def snapshot():
    try:
        return jsonify(ok=True, file=engine.snapshot())
    except Exception as exc:
        return jsonify(ok=False, error=str(exc)), 500


@app.post("/record/start")
def record_start():
    try:
        return jsonify(ok=True, file=engine.start_recording())
    except Exception as exc:
        return jsonify(ok=False, error=str(exc)), 409


@app.post("/record/stop")
def record_stop():
    try:
        return jsonify(ok=True, file=engine.stop_recording())
    except Exception as exc:
        return jsonify(ok=False, error=str(exc)), 500


def _shutdown(*_args):
    engine.stop()
    raise SystemExit(0)


signal.signal(signal.SIGTERM, _shutdown)
signal.signal(signal.SIGINT, _shutdown)

if __name__ == "__main__":
    app.run(host=HOST, port=PORT, threaded=True)
