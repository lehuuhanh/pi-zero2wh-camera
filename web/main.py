from __future__ import annotations

import os
from pathlib import Path

import requests
from flask import Flask, Response, jsonify, render_template, request, send_from_directory, stream_with_context

WORKER = f"http://{os.getenv('HOST', '127.0.0.1')}:{os.getenv('WORKER_PORT', '8091')}"
APP_DIR = Path(os.getenv("APP_DIR", "/home/pi/pi-zero2wh-camera"))
RECORD_ROOT = APP_DIR / "recordings"
WEB_PORT = int(os.getenv("WEB_PORT", "8080"))

app = Flask(__name__, template_folder="templates")


def worker(method: str, path: str, **kwargs):
    r = requests.request(method, WORKER + path, timeout=kwargs.pop("timeout", 20), **kwargs)
    r.raise_for_status()
    return r


@app.get("/")
def index():
    return render_template("index.html")


@app.get("/api/status")
def status():
    try:
        return jsonify(worker("GET", "/health", timeout=5).json())
    except Exception as exc:
        return jsonify(ok=False, error=str(exc)), 503


@app.post("/api/snapshot")
def snapshot():
    try:
        r = worker("POST", "/snapshot")
        return jsonify(r.json())
    except Exception as exc:
        return jsonify(ok=False, error=str(exc)), 500


@app.post("/api/record/start")
def record_start():
    try:
        return jsonify(worker("POST", "/record/start").json())
    except requests.HTTPError as exc:
        return jsonify(ok=False, error=exc.response.text), exc.response.status_code
    except Exception as exc:
        return jsonify(ok=False, error=str(exc)), 500


@app.post("/api/record/stop")
def record_stop():
    try:
        return jsonify(worker("POST", "/record/stop").json())
    except Exception as exc:
        return jsonify(ok=False, error=str(exc)), 500


@app.get("/stream.mjpg")
def stream():
    try:
        upstream = requests.get(WORKER + "/stream.mjpg", stream=True, timeout=(5, 86400))
        upstream.raise_for_status()
        return Response(
            stream_with_context(upstream.iter_content(chunk_size=128 * 1024)),
            content_type=upstream.headers.get("content-type", "multipart/x-mixed-replace; boundary=frame"),
            headers={"Cache-Control": "no-store", "X-Accel-Buffering": "no"},
        )
    except Exception as exc:
        return Response(str(exc), status=503, mimetype="text/plain")


@app.get("/media/<path:name>")
def media(name: str):
    return send_from_directory(RECORD_ROOT, name, as_attachment=False)


if __name__ == "__main__":
    app.run(host="127.0.0.1", port=WEB_PORT, threaded=True)
