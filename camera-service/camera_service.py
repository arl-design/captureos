#!/usr/bin/env python3
"""CaptureOS camera service.

A small stdlib HTTP service that owns the camera hardware. On a Raspberry Pi
it shells out to rpicam-still / libcamera-still (the most reliable capture
path on Pi OS); anywhere else it falls back to a dev-mode synthetic camera so
the full CaptureOS stack can be developed and tested without hardware.

Endpoints:
    GET  /health   -> {"ok": true, "camera": "libcamera" | "dev"}
    GET  /frame    -> single JPEG preview frame
    GET  /preview  -> multipart/x-mixed-replace MJPEG stream
    POST /capture  -> capture full-res photo, run pipeline, return metadata

Configuration via environment:
    CAMERA_PORT        listen port (default 5000)
    CAPTUREOS_DATA     data root (default ../data relative to this file)
    CAMERA_FORCE_DEV   set to 1 to force the synthetic camera
"""

from __future__ import annotations

import io
import json
import logging
import logging.handlers
import math
import os
import shutil
import subprocess
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

from PIL import Image, ImageDraw

from pipeline import PipelineError, process

SERVICE_DIR = os.path.dirname(os.path.abspath(__file__))
DATA_ROOT = os.environ.get(
    "CAPTUREOS_DATA", os.path.join(os.path.dirname(SERVICE_DIR), "data")
)
PHOTOS_DIR = os.path.join(DATA_ROOT, "photos")
THUMBS_DIR = os.path.join(DATA_ROOT, "thumbnails")
PORT = int(os.environ.get("CAMERA_PORT", "5000"))

PREVIEW_SIZE = (640, 480)
PREVIEW_FPS = 12
CAPTURE_TIMEOUT_S = 10


def find_capture_binary() -> str | None:
    if os.environ.get("CAMERA_FORCE_DEV") == "1":
        return None
    for name in ("rpicam-still", "libcamera-still"):
        path = shutil.which(name)
        if path:
            return path
    return None


CAPTURE_BIN = find_capture_binary()
CAMERA_MODE = "libcamera" if CAPTURE_BIN else "dev"

# Rotating file log (reliability requirement: "Rotate logs automatically").
LOG_DIR = os.path.join(DATA_ROOT, "logs")
os.makedirs(LOG_DIR, exist_ok=True)
logger = logging.getLogger("captureos.camera")
logger.setLevel(logging.INFO)
_handler = logging.handlers.RotatingFileHandler(
    os.path.join(LOG_DIR, "camera.log"), maxBytes=1024 * 1024, backupCount=2
)
_handler.setFormatter(
    logging.Formatter("%(asctime)s %(levelname)s %(message)s")
)
logger.addHandler(_handler)

# Serialize hardware access: libcamera only allows one client at a time.
camera_lock = threading.Lock()


def dev_frame(size: tuple[int, int], full_quality: bool = False) -> bytes:
    """Synthetic camera frame: animated backdrop with a timestamp."""
    w, h = size
    t = time.time()
    image = Image.new("RGB", size)
    draw = ImageDraw.Draw(image)
    for y in range(h):
        phase = y / h * math.pi
        r = int(120 + 100 * math.sin(t * 0.7 + phase))
        g = int(90 + 80 * math.sin(t * 0.5 + phase + 2.1))
        b = int(140 + 90 * math.sin(t * 0.9 + phase + 4.2))
        draw.line([(0, y), (w, y)], fill=(r, g, b))
    cx = w / 2 + math.cos(t) * w / 5
    cy = h / 2 + math.sin(t * 1.3) * h / 5
    radius = min(w, h) / 6
    draw.ellipse(
        [cx - radius, cy - radius, cx + radius, cy + radius],
        fill=(255, 205, 0),
        outline=(20, 20, 20),
        width=max(2, w // 200),
    )
    stamp = time.strftime("%Y-%m-%d %H:%M:%S")
    draw.text((12, h - 28), f"CaptureOS dev camera  {stamp}", fill=(255, 255, 255))
    buf = io.BytesIO()
    image.save(buf, "JPEG", quality=92 if full_quality else 70)
    return buf.getvalue()


def capture_still() -> bytes:
    """Capture a full-resolution still as JPEG bytes."""
    if CAPTURE_BIN is None:
        return dev_frame((2028, 1520), full_quality=True)
    with camera_lock:
        result = subprocess.run(
            [
                CAPTURE_BIN,
                "-n",  # no preview window
                "-t", "300",
                "--width", "3280",
                "--height", "2464",
                "-q", "95",
                "-o", "-",
            ],
            capture_output=True,
            timeout=CAPTURE_TIMEOUT_S,
        )
    if result.returncode != 0 or not result.stdout:
        raise RuntimeError(
            f"{os.path.basename(CAPTURE_BIN)} failed: "
            f"{result.stderr.decode(errors='replace')[-300:]}"
        )
    return result.stdout


def preview_frame() -> bytes:
    """A single low-latency preview frame."""
    if CAPTURE_BIN is None:
        return dev_frame(PREVIEW_SIZE)
    with camera_lock:
        result = subprocess.run(
            [
                CAPTURE_BIN,
                "-n",
                "-t", "1",
                "--width", str(PREVIEW_SIZE[0]),
                "--height", str(PREVIEW_SIZE[1]),
                "-q", "70",
                "--immediate",
                "-o", "-",
            ],
            capture_output=True,
            timeout=CAPTURE_TIMEOUT_S,
        )
    if result.returncode != 0 or not result.stdout:
        raise RuntimeError("preview capture failed")
    return result.stdout


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    server_version = "CaptureOS-Camera/1.0"

    def log_message(self, fmt, *args):  # quiet the per-request noise
        if os.environ.get("CAMERA_VERBOSE") == "1":
            super().log_message(fmt, *args)

    def send_json(self, obj: dict, status: int = 200) -> None:
        body = json.dumps(obj).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self) -> None:
        if self.path == "/health":
            self.send_json({"ok": True, "camera": CAMERA_MODE})
        elif self.path == "/frame":
            try:
                frame = preview_frame()
            except Exception as exc:
                self.send_json({"ok": False, "error": str(exc)}, 503)
                return
            self.send_response(200)
            self.send_header("Content-Type", "image/jpeg")
            self.send_header("Content-Length", str(len(frame)))
            self.send_header("Cache-Control", "no-store")
            self.end_headers()
            self.wfile.write(frame)
        elif self.path == "/preview":
            self.stream_preview()
        else:
            self.send_json({"ok": False, "error": "not found"}, 404)

    def stream_preview(self) -> None:
        boundary = "captureosframe"
        self.send_response(200)
        self.send_header(
            "Content-Type", f"multipart/x-mixed-replace; boundary={boundary}"
        )
        self.send_header("Cache-Control", "no-store")
        # Streaming responses cannot carry Content-Length; close when done.
        self.send_header("Connection", "close")
        self.end_headers()
        interval = 1 / PREVIEW_FPS
        try:
            while True:
                start = time.time()
                frame = preview_frame()
                self.wfile.write(
                    f"--{boundary}\r\n"
                    f"Content-Type: image/jpeg\r\n"
                    f"Content-Length: {len(frame)}\r\n\r\n".encode()
                )
                self.wfile.write(frame)
                self.wfile.write(b"\r\n")
                elapsed = time.time() - start
                if elapsed < interval:
                    time.sleep(interval - elapsed)
        except (BrokenPipeError, ConnectionResetError):
            pass  # client went away — normal for preview streams

    def do_POST(self) -> None:
        if self.path != "/capture":
            self.send_json({"ok": False, "error": "not found"}, 404)
            return
        length = int(self.headers.get("Content-Length") or 0)
        options = {}
        if length:
            try:
                options = json.loads(self.rfile.read(length) or b"{}")
            except json.JSONDecodeError:
                self.send_json({"ok": False, "error": "invalid JSON body"}, 400)
                return
        try:
            raw = capture_still()
            logger.info("capture ok (%d bytes raw)", len(raw))
            result = process(
                raw,
                PHOTOS_DIR,
                THUMBS_DIR,
                max_width=int(options.get("max_width", 2028)),
                thumb_width=int(options.get("thumb_width", 480)),
                quality=int(options.get("quality", 92)),
            )
        except PipelineError as exc:
            logger.error("pipeline rejected capture: %s", exc)
            self.send_json({"ok": False, "error": f"pipeline: {exc}"}, 422)
            return
        except Exception as exc:
            logger.error("capture failed: %s", exc)
            self.send_json({"ok": False, "error": str(exc)}, 500)
            return
        self.send_json(
            {
                "ok": True,
                "photo_id": result.photo_id,
                "filename": result.filename,
                "thumb_filename": result.thumb_filename,
                "width": result.width,
                "height": result.height,
                "size_bytes": result.size_bytes,
                "captured_at": result.captured_at,
            }
        )


def main() -> None:
    os.makedirs(PHOTOS_DIR, exist_ok=True)
    os.makedirs(THUMBS_DIR, exist_ok=True)
    server = ThreadingHTTPServer(("0.0.0.0", PORT), Handler)
    print(f"CaptureOS camera service on :{PORT} (camera={CAMERA_MODE})")
    logger.info("camera service started (mode=%s, port=%d)", CAMERA_MODE, PORT)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
