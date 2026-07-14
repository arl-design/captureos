"""CaptureOS image pipeline.

Implements the pipeline stages that belong to the camera side:

    Capture -> Validate -> Crop -> Resize -> Thumbnail -> Save Full Image

The database record and gallery notification stages are owned by the
backend service, which calls this service over HTTP.
"""

from __future__ import annotations

import io
import os
import uuid
from dataclasses import dataclass
from datetime import datetime, timezone

from PIL import Image, ImageOps

# Guard against decompression bombs but allow full 8 MP frames.
Image.MAX_IMAGE_PIXELS = 64_000_000

MIN_WIDTH = 320
MIN_HEIGHT = 240


class PipelineError(Exception):
    """Raised when a captured image fails validation or processing."""


@dataclass
class PipelineResult:
    photo_id: str
    filename: str
    thumb_filename: str
    width: int
    height: int
    size_bytes: int
    captured_at: str


def validate(image: Image.Image) -> None:
    if image.width < MIN_WIDTH or image.height < MIN_HEIGHT:
        raise PipelineError(
            f"image too small: {image.width}x{image.height}, "
            f"minimum {MIN_WIDTH}x{MIN_HEIGHT}"
        )


def crop_to_aspect(image: Image.Image, aspect_w: int, aspect_h: int) -> Image.Image:
    """Center-crop to the target aspect ratio without upscaling."""
    target = aspect_w / aspect_h
    current = image.width / image.height
    if abs(current - target) < 1e-3:
        return image
    if current > target:
        new_w = round(image.height * target)
        left = (image.width - new_w) // 2
        return image.crop((left, 0, left + new_w, image.height))
    new_h = round(image.width / target)
    top = (image.height - new_h) // 2
    return image.crop((0, top, image.width, top + new_h))


def process(
    raw_bytes: bytes,
    photos_dir: str,
    thumbs_dir: str,
    *,
    max_width: int = 2028,
    thumb_width: int = 480,
    quality: int = 92,
    aspect: tuple[int, int] = (4, 3),
) -> PipelineResult:
    """Run the full pipeline on a captured JPEG and write outputs to disk."""
    try:
        image = Image.open(io.BytesIO(raw_bytes))
        image.load()
    except Exception as exc:  # Pillow raises many types here
        raise PipelineError(f"unreadable image: {exc}") from exc

    image = ImageOps.exif_transpose(image).convert("RGB")
    validate(image)
    image = crop_to_aspect(image, *aspect)

    if image.width > max_width:
        new_h = round(image.height * max_width / image.width)
        image = image.resize((max_width, new_h), Image.LANCZOS)

    captured_at = datetime.now(timezone.utc)
    photo_id = uuid.uuid4().hex[:12]
    stamp = captured_at.strftime("%Y%m%d_%H%M%S")
    filename = f"capture_{stamp}_{photo_id}.jpg"
    thumb_filename = f"thumb_{stamp}_{photo_id}.jpg"

    os.makedirs(photos_dir, exist_ok=True)
    os.makedirs(thumbs_dir, exist_ok=True)

    full_path = os.path.join(photos_dir, filename)
    image.save(full_path, "JPEG", quality=quality, optimize=True)

    thumb = image.copy()
    thumb_h = round(thumb.height * thumb_width / thumb.width)
    thumb = thumb.resize((thumb_width, thumb_h), Image.LANCZOS)
    thumb.save(os.path.join(thumbs_dir, thumb_filename), "JPEG", quality=85)

    return PipelineResult(
        photo_id=photo_id,
        filename=filename,
        thumb_filename=thumb_filename,
        width=image.width,
        height=image.height,
        size_bytes=os.path.getsize(full_path),
        captured_at=captured_at.isoformat(),
    )
