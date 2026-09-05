from __future__ import annotations

import io
import os
import signal
import threading
import time
from pathlib import Path

from flask import Flask, Response, jsonify
from picamera2 import Picamera2
from picamera2.encoders import H264Encoder
from picamera2.outputs import CircularOutput
from PIL import Image, ImageDraw

try:
    from picamera2.devices import IMX500
    from picamera2.devices.imx500 import (
        NetworkIntrinsics,
        postprocess_nanodet_detection,
    )
except Exception:
    IMX500 = None
    NetworkIntrinsics = None
    postprocess_nanodet_detection = None


APP_DIR = Path(os.getenv("APP_DIR", "/home/pi/pi-zero2wh-camera"))
HOST = os.getenv("HOST", "127.0.0.1")
PORT = int(os.getenv("WORKER_PORT", "8091"))

WIDTH = int(os.getenv("CAMERA_WIDTH", "1280"))
HEIGHT = int(os.getenv("CAMERA_HEIGHT", "720"))
FPS = max(1, int(os.getenv("CAMERA_FPS", "15")))
STREAM_FPS = max(1, int(os.getenv("STREAM_FPS", "6")))
JPEG_QUALITY = max(30, min(95, int(os.getenv("JPEG_QUALITY", "68"))))
BUFFER_COUNT = max(3, min(8, int(os.getenv("BUFFER_COUNT", "4"))))
RECORD_BITRATE = max(250_000, int(os.getenv("RECORD_BITRATE", "4000000")))

AI_ENABLED = os.getenv("AI_ENABLED", "1") == "1"
AI_MODEL_PATH = Path(
    os.getenv("AI_MODEL_PATH", str(APP_DIR / "models" / "yolov8n.rpk"))
)
AI_LABELS_PATH = Path(
    os.getenv("AI_LABELS_PATH", str(APP_DIR / "models" / "coco_labels.txt"))
)
AI_VALID_CLASSES = {
    item.strip()
    for item in os.getenv(
        "AI_VALID_CLASSES",
        "person,car,bird,cat,dog",
    ).split(",")
    if item.strip()
}
AI_CONFIDENCE = max(0.01, min(1.0, float(os.getenv("AI_CONFIDENCE", "0.50"))))
AI_IOU = max(0.01, min(1.0, float(os.getenv("AI_IOU_THRESHOLD", "0.50"))))
AI_IPS = max(1, int(os.getenv("AI_IPS", "5")))
AI_DRAW_BOXES = os.getenv("AI_DRAW_BOXES", "1") == "1"

EMA_ALPHA = max(0.01, min(1.0, float(os.getenv("AI_EMA_ALPHA", "0.25"))))
EVENT_ACTIVATE = max(
    0.01,
    min(1.0, float(os.getenv("AI_EVENT_ACTIVATE", "0.60"))),
)
EVENT_DEACTIVATE = max(
    0.0,
    min(EVENT_ACTIVATE, float(os.getenv("AI_EVENT_DEACTIVATE", "0.35"))),
)
EVENT_VIDEO_ENABLED = os.getenv("AI_EVENT_VIDEO_ENABLED", "1") == "1"
EVENT_IMAGE_ENABLED = os.getenv("AI_EVENT_IMAGE_ENABLED", "1") == "1"
PREBUFFER_SECONDS = max(1, min(10, int(os.getenv("AI_PREBUFFER_SECONDS", "3"))))
POSTBUFFER_SECONDS = max(0, min(30, int(os.getenv("AI_POSTBUFFER_SECONDS", "4"))))
EVENT_MAX_SECONDS = max(5, int(os.getenv("AI_EVENT_MAX_SECONDS", "60")))
EVENT_COOLDOWN_SECONDS = max(0, int(os.getenv("AI_EVENT_COOLDOWN_SECONDS", "3")))

RECORD_ROOT = APP_DIR / "recordings"
MANUAL_DIR = RECORD_ROOT / "manual"
EVENT_DIR = RECORD_ROOT / "events"
SNAPSHOT_DIR = RECORD_ROOT / "snapshots"
for directory in (MANUAL_DIR, EVENT_DIR, SNAPSHOT_DIR):
    directory.mkdir(parents=True, exist_ok=True)

app = Flask(__name__)


def _read_labels(path: Path) -> list[str]:
    try:
        return [
            line.strip()
            for line in path.read_text(encoding="utf-8").splitlines()
            if line.strip()
        ]
    except Exception:
        return []


class CameraEngine:
    def __init__(self) -> None:
        self.lock = threading.RLock()
        self.cond = threading.Condition()
        self.stop_event = threading.Event()

        self.started_at = time.time()
        self.last_frame_ts = 0.0
        self.frame_seq = 0
        self.jpeg = b""

        self.ai_error: str | None = None
        self.imx500 = None
        self.intrinsics = None
        self.labels = _read_labels(AI_LABELS_PATH)
        self.detections: list[dict] = []
        self.ema: dict[str, float] = {}
        self.last_inference_at = 0.0

        self.event_active = False
        self.event_classes: list[str] = []
        self.event_started_at = 0.0
        self.event_stop_deadline = 0.0
        self.last_event_end = 0.0
        self.last_event: dict | None = None

        self.recording = False
        self.recording_kind: str | None = None
        self.recording_path: Path | None = None

        self._init_ai()
        camera_num = self.imx500.camera_num if self.imx500 is not None else 0
        self.picam2 = Picamera2(camera_num)
        self._configure_camera()

        self.encoder = H264Encoder(
            bitrate=RECORD_BITRATE,
            repeat=True,
            iperiod=max(1, FPS),
        )
        self.circular = CircularOutput(
            buffersize=max(FPS, PREBUFFER_SECONDS * FPS)
        )

    def _init_ai(self) -> None:
        if not AI_ENABLED:
            self.ai_error = "disabled by AI_ENABLED=0"
            return
        if IMX500 is None:
            self.ai_error = "IMX500 Python support is unavailable"
            return
        if not AI_MODEL_PATH.is_file():
            self.ai_error = f"model missing: {AI_MODEL_PATH}"
            return

        try:
            self.imx500 = IMX500(str(AI_MODEL_PATH))
            intrinsics = self.imx500.network_intrinsics
            if intrinsics is None and NetworkIntrinsics is not None:
                intrinsics = NetworkIntrinsics()
                intrinsics.task = "object detection"
            if intrinsics is not None:
                intrinsics.threshold = AI_CONFIDENCE
                intrinsics.update_with_defaults()
            self.intrinsics = intrinsics
        except Exception as exc:
            self.imx500 = None
            self.intrinsics = None
            self.ai_error = f"AI init failed: {exc}"

    def _configure_camera(self) -> None:
        config = self.picam2.create_video_configuration(
            main={
                "size": (WIDTH, HEIGHT),
                "format": "RGB888",
            },
            controls={"FrameRate": FPS},
            buffer_count=BUFFER_COUNT,
        )
        self.picam2.configure(config)

    @property
    def ai_ready(self) -> bool:
        return self.imx500 is not None and self.intrinsics is not None

    def start(self) -> None:
        if self.ai_ready:
            try:
                self.imx500.show_network_fw_progress_bar()
                if self.intrinsics.preserve_aspect_ratio:
                    self.imx500.set_auto_aspect_ratio()
            except Exception as exc:
                self.ai_error = f"AI firmware setup warning: {exc}"

        self.picam2.start()
        self.picam2.start_encoder(
            self.encoder,
            self.circular,
            name="main",
        )
        threading.Thread(
            target=self._frame_loop,
            daemon=True,
            name="zero2-camera-loop",
        ).start()

    def _parse_detections(self, metadata) -> list[dict] | None:
        if not self.ai_ready:
            return None

        outputs = self.imx500.get_outputs(metadata, add_batch=True)
        if outputs is None:
            return None

        input_width, input_height = self.imx500.get_input_size()

        try:
            if (
                getattr(self.intrinsics, "postprocess", None) == "nanodet"
                and postprocess_nanodet_detection is not None
            ):
                boxes, scores, classes = postprocess_nanodet_detection(
                    outputs=outputs[0],
                    conf=AI_CONFIDENCE,
                    iou_thres=AI_IOU,
                    max_out_dets=10,
                )[0]
                from picamera2.devices.imx500.postprocess import scale_boxes

                boxes = scale_boxes(
                    boxes,
                    1,
                    1,
                    input_height,
                    input_width,
                    False,
                    False,
                )
            else:
                boxes = outputs[0][0]
                scores = outputs[1][0]
                classes = outputs[2][0]

                if getattr(self.intrinsics, "bbox_normalization", False):
                    boxes = boxes / input_height

                if getattr(self.intrinsics, "bbox_order", None) == "xy":
                    boxes = boxes[:, [1, 0, 3, 2]]

            result: list[dict] = []
            for box, score, category in zip(boxes, scores, classes):
                confidence = float(score)
                if confidence < AI_CONFIDENCE:
                    continue

                category_id = int(category)
                label = (
                    self.labels[category_id]
                    if 0 <= category_id < len(self.labels)
                    else str(category_id)
                )
                if AI_VALID_CLASSES and label not in AI_VALID_CLASSES:
                    continue

                converted = self.imx500.convert_inference_coords(
                    box,
                    metadata,
                    self.picam2,
                )
                x, y, width, height = [
                    max(0, int(value))
                    for value in converted
                ]

                result.append(
                    {
                        "label": label,
                        "confidence": round(confidence, 4),
                        "bbox": [x, y, width, height],
                    }
                )
            return result
        except Exception as exc:
            self.ai_error = f"inference parse failed: {exc}"
            return None

    def _update_ema(self, detections: list[dict]) -> None:
        current: dict[str, float] = {}
        for item in detections:
            label = item["label"]
            current[label] = max(
                current.get(label, 0.0),
                float(item["confidence"]),
            )

        all_labels = set(self.ema) | set(current) | AI_VALID_CLASSES
        for label in all_labels:
            previous = self.ema.get(label, 0.0)
            score = current.get(label, 0.0)
            value = EMA_ALPHA * score + (1.0 - EMA_ALPHA) * previous
            if value < 0.001:
                self.ema.pop(label, None)
            else:
                self.ema[label] = value

    def _active_classes(self) -> list[str]:
        return sorted(
            label
            for label, value in self.ema.items()
            if value >= EVENT_ACTIVATE
        )

    def _all_deactivated(self) -> bool:
        return all(
            value < EVENT_DEACTIVATE
            for value in self.ema.values()
        )

    def _start_output_recording(self, path: Path, kind: str) -> None:
        if self.recording:
            raise RuntimeError(
                f"recording already active ({self.recording_kind})"
            )

        path.parent.mkdir(parents=True, exist_ok=True)
        path.unlink(missing_ok=True)
        self.circular.fileoutput = str(path)
        self.circular.start()
        self.recording = True
        self.recording_kind = kind
        self.recording_path = path

    def _stop_output_recording(self) -> str | None:
        if not self.recording:
            return None

        path = self.recording_path
        self.circular.stop()
        self.circular.fileoutput = None
        self.recording = False
        self.recording_kind = None
        self.recording_path = None
        return str(path.relative_to(RECORD_ROOT)) if path else None

    def _event_start(self, classes: list[str], image: Image.Image) -> None:
        now = time.time()
        if now - self.last_event_end < EVENT_COOLDOWN_SECONDS:
            return

        stamp = time.strftime("%Y%m%d-%H%M%S")
        class_tag = "-".join(classes[:3]) or "ai"
        video_path = EVENT_DIR / f"event-{class_tag}-{stamp}.h264"
        image_path = EVENT_DIR / f"event-{class_tag}-{stamp}.jpg"

        if EVENT_IMAGE_ENABLED:
            image.save(
                image_path,
                format="JPEG",
                quality=JPEG_QUALITY,
                optimize=False,
            )

        video_started = False
        if EVENT_VIDEO_ENABLED and not self.recording:
            try:
                self._start_output_recording(video_path, "event")
                video_started = True
            except Exception as exc:
                self.ai_error = f"event recording start failed: {exc}"

        self.event_active = True
        self.event_classes = list(classes)
        self.event_started_at = now
        self.event_stop_deadline = 0.0
        self.last_event = {
            "started_at": int(now),
            "classes": list(classes),
            "image": (
                str(image_path.relative_to(RECORD_ROOT))
                if EVENT_IMAGE_ENABLED
                else None
            ),
            "video": (
                str(video_path.relative_to(RECORD_ROOT))
                if video_started
                else None
            ),
        }
        print(
            f"AI EVENT START classes={','.join(classes)} "
            f"prebuffer={PREBUFFER_SECONDS}s",
            flush=True,
        )

    def _event_stop(self) -> None:
        if not self.event_active:
            return

        video = None
        if self.recording and self.recording_kind == "event":
            try:
                video = self._stop_output_recording()
            except Exception as exc:
                self.ai_error = f"event recording stop failed: {exc}"

        now = time.time()
        if self.last_event is not None:
            self.last_event["ended_at"] = int(now)
            if video:
                self.last_event["video"] = video

        print(
            f"AI EVENT END classes={','.join(self.event_classes)}",
            flush=True,
        )
        self.event_active = False
        self.event_classes = []
        self.event_started_at = 0.0
        self.event_stop_deadline = 0.0
        self.last_event_end = now

    def _update_event_state(
        self,
        detections: list[dict],
        image: Image.Image,
    ) -> None:
        self._update_ema(detections)
        now = time.time()
        active = self._active_classes()

        if not self.event_active:
            if active:
                self._event_start(active, image)
            return

        self.event_classes = sorted(
            set(self.event_classes) | set(active)
        )

        if now - self.event_started_at >= EVENT_MAX_SECONDS:
            self._event_stop()
            return

        if self._all_deactivated():
            if self.event_stop_deadline <= 0:
                self.event_stop_deadline = now + POSTBUFFER_SECONDS
            elif now >= self.event_stop_deadline:
                self._event_stop()
        else:
            self.event_stop_deadline = 0.0

    def _draw_detections(self, image: Image.Image) -> None:
        if not AI_DRAW_BOXES or not self.detections:
            return

        draw = ImageDraw.Draw(image)
        for item in self.detections:
            x, y, width, height = item["bbox"]
            x2 = min(image.width - 1, x + width)
            y2 = min(image.height - 1, y + height)
            x = min(image.width - 1, x)
            y = min(image.height - 1, y)
            draw.rectangle(
                (x, y, x2, y2),
                outline="lime",
                width=2,
            )
            draw.text(
                (x + 3, max(0, y - 12)),
                f'{item["label"]} {item["confidence"]:.2f}',
                fill="lime",
            )

    def _frame_loop(self) -> None:
        interval = 1.0 / STREAM_FPS
        inference_interval = 1.0 / AI_IPS
        next_frame = 0.0

        while not self.stop_event.is_set():
            now_mono = time.monotonic()
            if now_mono < next_frame:
                time.sleep(min(0.02, next_frame - now_mono))
                continue
            next_frame = now_mono + interval

            try:
                request_obj = self.picam2.capture_request()
                try:
                    metadata = request_obj.get_metadata()
                    array = request_obj.make_array("main")
                finally:
                    request_obj.release()

                image = Image.fromarray(array)

                if (
                    self.ai_ready
                    and now_mono - self.last_inference_at
                    >= inference_interval
                ):
                    parsed = self._parse_detections(metadata)
                    if parsed is not None:
                        self.detections = parsed
                        self._update_event_state(parsed, image)
                    self.last_inference_at = now_mono

                self._draw_detections(image)

                buf = io.BytesIO()
                image.save(
                    buf,
                    format="JPEG",
                    quality=JPEG_QUALITY,
                    optimize=False,
                )
                jpeg = buf.getvalue()

                with self.cond:
                    self.jpeg = jpeg
                    self.frame_seq += 1
                    self.last_frame_ts = time.time()
                    self.cond.notify_all()
            except Exception as exc:
                print(f"camera loop error: {exc}", flush=True)
                time.sleep(0.25)

    def mjpeg(self):
        last = -1
        while not self.stop_event.is_set():
            with self.cond:
                self.cond.wait_for(
                    lambda: (
                        self.frame_seq != last
                        or self.stop_event.is_set()
                    ),
                    timeout=5,
                )
                if self.stop_event.is_set():
                    break
                last = self.frame_seq
                frame = self.jpeg

            if not frame:
                continue

            yield (
                b"--frame\r\n"
                b"Content-Type: image/jpeg\r\n"
                b"Content-Length: "
                + str(len(frame)).encode()
                + b"\r\n\r\n"
                + frame
                + b"\r\n"
            )

    def snapshot(self) -> str:
        with self.cond:
            if not self.jpeg:
                self.cond.wait(timeout=5)
            jpeg = self.jpeg

        if not jpeg:
            raise RuntimeError("no camera frame available")

        stamp = time.strftime("%Y%m%d-%H%M%S")
        path = SNAPSHOT_DIR / f"snapshot-{stamp}.jpg"
        path.write_bytes(jpeg)
        return str(path.relative_to(RECORD_ROOT))

    def start_recording(self) -> str:
        with self.lock:
            stamp = time.strftime("%Y%m%d-%H%M%S")
            path = MANUAL_DIR / f"record-{stamp}.h264"
            self._start_output_recording(path, "manual")
            return str(path.relative_to(RECORD_ROOT))

    def stop_recording(self) -> str | None:
        with self.lock:
            if self.recording_kind == "event":
                raise RuntimeError("AI event recording is active")
            return self._stop_output_recording()

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
            "recording_kind": self.recording_kind,
            "recording_file": (
                str(self.recording_path.relative_to(RECORD_ROOT))
                if self.recording_path
                else None
            ),
            "ai": {
                "enabled": AI_ENABLED,
                "ready": self.ai_ready,
                "error": self.ai_error,
                "model": str(AI_MODEL_PATH),
                "ips": AI_IPS,
                "confidence": AI_CONFIDENCE,
                "valid_classes": sorted(AI_VALID_CLASSES),
                "detections": self.detections,
                "ema": {
                    key: round(value, 3)
                    for key, value in sorted(self.ema.items())
                },
                "event_active": self.event_active,
                "event_classes": self.event_classes,
                "prebuffer_seconds": PREBUFFER_SECONDS,
                "postbuffer_seconds": POSTBUFFER_SECONDS,
                "last_event": self.last_event,
            },
            "last_frame_age": (
                None
                if not self.last_frame_ts
                else round(time.time() - self.last_frame_ts, 3)
            ),
            "uptime_seconds": int(time.time() - self.started_at),
        }

    def stop(self) -> None:
        self.stop_event.set()
        try:
            if self.event_active:
                self._event_stop()
            elif self.recording:
                self._stop_output_recording()
        except Exception:
            pass
        try:
            self.picam2.stop_encoder(self.encoder)
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
        headers={
            "Cache-Control": "no-store",
            "X-Accel-Buffering": "no",
        },
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
        return jsonify(ok=False, error=str(exc)), 409


def _shutdown(*_args):
    engine.stop()
    raise SystemExit(0)


signal.signal(signal.SIGTERM, _shutdown)
signal.signal(signal.SIGINT, _shutdown)

if __name__ == "__main__":
    app.run(host=HOST, port=PORT, threaded=True)
