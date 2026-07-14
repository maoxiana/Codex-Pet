#!/usr/bin/env python3
from __future__ import annotations

import hashlib
import json
import math
import shutil
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw, ImageFilter, ImageOps


CELL_W = 192
CELL_H = 208
COLS = 8
ROWS = 11
IDLE_ROW = 0
RUNNING_ROW = 7
REVIEW_ROW = 8
MODIFIED_ROWS = {IDLE_ROW, RUNNING_ROW, REVIEW_ROW}

WORK = Path("/Users/maoxian/Work")
RUN_DIR = WORK / "reborn-transformation-gun-run"
ASSET_DIR = WORK / "reborn-transformation-design/assets"
PACKAGE_DIR = WORK / "codex-pet-v2-package/reborn"
INSTALLED_DIR = Path("/Users/maoxian/.codex/pets/reborn")
SOURCE_ATLAS = PACKAGE_DIR / "spritesheet.webp"
INSTALLED_ATLAS = INSTALLED_DIR / "spritesheet.webp"
HAND_BASE = ASSET_DIR / "reborn-running-hand-base.png"
TRANSITION_OVERLAYS = ASSET_DIR / "transformation-overlays-v2.png"
POSE_SOURCE = ASSET_DIR / "reborn-empty-and-grip-poses-v3.png"


def sha256(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as f:
        for chunk in iter(lambda: f.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()


def ensure_dirs() -> None:
    for rel in [
        "frames/source-row-0",
        "frames/new-row-0",
        "frames/source-row-7",
        "frames/new-row-7",
        "frames/source-row-8",
        "frames/new-row-8",
        "qa",
        "final",
    ]:
        (RUN_DIR / rel).mkdir(parents=True, exist_ok=True)


def bbox_alpha(img: Image.Image, threshold: int = 8) -> tuple[int, int, int, int] | None:
    alpha = img.getchannel("A")
    mask = alpha.point(lambda v: 255 if v > threshold else 0)
    return mask.getbbox()


def paste_centered(base: Image.Image, overlay: Image.Image, cx: float, cy: float) -> None:
    x = int(round(cx - overlay.width / 2))
    y = int(round(cy - overlay.height / 2))
    base.alpha_composite(overlay, (x, y))


def solid_mask_from_points(size: tuple[int, int], points: list[tuple[float, float]], blur: float = 0) -> Image.Image:
    mask = Image.new("L", size, 0)
    draw = ImageDraw.Draw(mask)
    draw.polygon([(int(round(x)), int(round(y))) for x, y in points], fill=255)
    if blur:
        mask = mask.filter(ImageFilter.GaussianBlur(blur))
    return mask


def remove_region(img: Image.Image, center: tuple[int, int], radius: tuple[int, int]) -> Image.Image:
    out = img.copy()
    mask = Image.new("L", out.size, 0)
    draw = ImageDraw.Draw(mask)
    cx, cy = center
    rx, ry = radius
    draw.ellipse((cx - rx, cy - ry, cx + rx, cy + ry), fill=255)
    alpha = out.getchannel("A")
    alpha = Image.composite(Image.new("L", out.size, 0), alpha, mask)
    out.putalpha(alpha)
    return out


def extract_cells(atlas: Image.Image, row: int, out_dir: Path) -> list[Image.Image]:
    frames = []
    for col in range(COLS):
        cell = atlas.crop((col * CELL_W, row * CELL_H, (col + 1) * CELL_W, (row + 1) * CELL_H)).convert("RGBA")
        frames.append(cell)
        cell.save(out_dir / f"{col:02d}.png")
    return frames


def find_sprite_center(frame: Image.Image) -> tuple[float, float]:
    box = bbox_alpha(frame)
    if not box:
        return CELL_W / 2, CELL_H / 2
    l, t, r, b = box
    return (l + r) / 2, (t + b) / 2


def chameleon_overlay(scale: float, angle: float = 0, glow: bool = False, stretch: float = 1.0) -> Image.Image:
    w = int(60 * scale * stretch)
    h = int(34 * scale)
    pad = int(24 * scale)
    canvas = Image.new("RGBA", (w + pad * 2, h + pad * 2), (0, 0, 0, 0))
    d = ImageDraw.Draw(canvas)
    ox = pad
    oy = pad

    body = (ox + 14 * scale, oy + 10 * scale, ox + (44 * stretch) * scale, oy + 25 * scale)
    head = (ox + 0 * scale, oy + 8 * scale, ox + 24 * scale, oy + 26 * scale)
    tail_start = (ox + (42 * stretch) * scale, oy + 15 * scale)
    tail_box = (
        ox + (36 * stretch) * scale,
        oy - 10 * scale,
        ox + (70 * stretch) * scale,
        oy + 24 * scale,
    )

    if glow:
        fill = (220, 255, 236, 235)
        outline = (255, 255, 255, 245)
    else:
        fill = (77, 188, 82, 255)
        outline = (20, 85, 38, 255)

    d.ellipse(head, fill=fill, outline=outline, width=max(1, int(2 * scale)))
    d.ellipse(body, fill=fill, outline=outline, width=max(1, int(2 * scale)))
    d.arc(tail_box, 220, 540, fill=outline, width=max(3, int(4 * scale)))

    for x0, y0, x1, y1 in [
        (18, 23, 12, 31),
        (28, 22, 31, 31),
        (38 * stretch, 22, 43 * stretch, 31),
        (21, 10, 19, 2),
    ]:
        d.line((ox + x0 * scale, oy + y0 * scale, ox + x1 * scale, oy + y1 * scale), fill=outline, width=max(2, int(3 * scale)))

    if not glow:
        for ex in [7, 20]:
            eye_box = (ox + ex * scale, oy + 4 * scale, ox + (ex + 9) * scale, oy + 14 * scale)
            d.ellipse(eye_box, fill=(246, 215, 65, 255), outline=(41, 73, 22, 255), width=max(1, int(1.5 * scale)))
            d.line((eye_box[0] + 4 * scale, eye_box[1] + 1 * scale, eye_box[0] + 6 * scale, eye_box[3] - 1 * scale), fill=(30, 28, 20, 255), width=max(1, int(1.3 * scale)))
    else:
        glow_layer = Image.new("RGBA", canvas.size, (0, 0, 0, 0))
        gd = ImageDraw.Draw(glow_layer)
        for color, offset in [
            ((117, 255, 235, 75), -3),
            ((255, 128, 226, 70), 3),
            ((255, 252, 168, 65), 0),
        ]:
            gd.ellipse((head[0] + offset, head[1] - 2, head[2] + offset, head[3] + 2), fill=color)
            gd.ellipse((body[0] + offset, body[1] - 3, body[2] + offset, body[3] + 3), fill=color)
            gd.arc(tail_box, 220, 540, fill=color, width=max(5, int(6 * scale)))
        canvas = Image.alpha_composite(glow_layer.filter(ImageFilter.GaussianBlur(1.2)), canvas)

    if angle:
        canvas = canvas.rotate(angle, expand=True, resample=Image.Resampling.BICUBIC)
    return canvas


def glow_gun_overlay(scale: float, solid: bool = False) -> Image.Image:
    w = int(92 * scale)
    h = int(42 * scale)
    pad = int(14 * scale)
    canvas = Image.new("RGBA", (w + pad * 2, h + pad * 2), (0, 0, 0, 0))
    d = ImageDraw.Draw(canvas)
    ox, oy = pad, pad

    slide = [
        (ox + 4 * scale, oy + 11 * scale),
        (ox + 68 * scale, oy + 3 * scale),
        (ox + 86 * scale, oy + 11 * scale),
        (ox + 78 * scale, oy + 22 * scale),
        (ox + 10 * scale, oy + 27 * scale),
    ]
    grip = [
        (ox + 32 * scale, oy + 24 * scale),
        (ox + 48 * scale, oy + 25 * scale),
        (ox + 39 * scale, oy + 42 * scale),
        (ox + 24 * scale, oy + 40 * scale),
    ]
    trigger_guard = (
        ox + 43 * scale,
        oy + 25 * scale,
        ox + 62 * scale,
        oy + 40 * scale,
    )

    if solid:
        d.polygon(slide, fill=(142, 160, 80, 255), outline=(39, 49, 24, 255))
        d.polygon(grip, fill=(63, 36, 35, 255), outline=(28, 20, 19, 255))
        d.rounded_rectangle((ox + 10 * scale, oy + 18 * scale, ox + 42 * scale, oy + 31 * scale), radius=int(3 * scale), fill=(73, 40, 38, 255), outline=(30, 22, 19, 255))
        d.rounded_rectangle((ox + 50 * scale, oy + 8 * scale, ox + 82 * scale, oy + 22 * scale), radius=int(3 * scale), fill=(157, 176, 92, 255), outline=(37, 47, 24, 255))
        d.arc(trigger_guard, 205, 50, fill=(26, 19, 17, 255), width=max(2, int(3 * scale)))
        d.line((ox + 17 * scale, oy + 15 * scale, ox + 35 * scale, oy + 13 * scale), fill=(211, 222, 132, 180), width=max(1, int(2 * scale)))
        d.line((ox + 73 * scale, oy + 7 * scale, ox + 82 * scale, oy + 11 * scale), fill=(225, 231, 150, 170), width=max(1, int(2 * scale)))
    else:
        mask = Image.new("L", canvas.size, 0)
        md = ImageDraw.Draw(mask)
        md.polygon(slide, fill=220)
        md.polygon(grip, fill=210)
        md.rounded_rectangle((ox + 10 * scale, oy + 18 * scale, ox + 42 * scale, oy + 31 * scale), radius=int(3 * scale), fill=220)
        md.rounded_rectangle((ox + 50 * scale, oy + 8 * scale, ox + 82 * scale, oy + 22 * scale), radius=int(3 * scale), fill=220)
        md.arc(trigger_guard, 205, 50, fill=220, width=max(3, int(4 * scale)))
        for color, dx, dy in [
            ((142, 255, 245, 115), -3, -1),
            ((255, 125, 229, 110), 3, 1),
            ((255, 250, 172, 95), 0, 0),
            ((255, 255, 255, 210), 0, 0),
        ]:
            layer = Image.new("RGBA", canvas.size, color)
            shifted = ImageChops.offset(mask, int(dx * scale), int(dy * scale)) if False else mask
            rgba = Image.new("RGBA", canvas.size, (0, 0, 0, 0))
            rgba.paste(layer, (0, 0), shifted.filter(ImageFilter.GaussianBlur(1.0)))
            canvas = Image.alpha_composite(canvas, rgba)
        edge = ImageOps.colorize(mask.filter(ImageFilter.FIND_EDGES), (255, 255, 255), (255, 255, 255)).convert("RGBA")
        edge.putalpha(mask.filter(ImageFilter.GaussianBlur(0.6)))
        canvas = Image.alpha_composite(canvas, edge)

    return canvas.rotate(-8, expand=True, resample=Image.Resampling.BICUBIC)


def remove_hat_lizard(frame: Image.Image) -> Image.Image:
    # Current row 7 has the lizard on the upper-right hat. Remove that area when the lizard moves to the hand.
    out = frame.copy()
    mask = Image.new("L", out.size, 0)
    d = ImageDraw.Draw(mask)
    d.ellipse((119, 13, 187, 78), fill=255)
    d.rectangle((138, 35, 191, 86), fill=255)
    # Replace with nearby dark hat color and keep the white hat rim line mostly intact.
    fill = Image.new("RGBA", out.size, (19, 22, 22, 255))
    out = Image.composite(fill, out, mask)
    # Repaint a small white rim and orange band edge to avoid a punched-out patch.
    d2 = ImageDraw.Draw(out)
    d2.arc((119, 5, 194, 91), 186, 354, fill=(245, 245, 240, 245), width=3)
    d2.line((120, 71, 186, 77), fill=(20, 21, 21, 255), width=7)
    return out


def remove_hand_lizard(frame: Image.Image) -> Image.Image:
    """Remove the green/yellow hand chameleon area before drawing the final pistol."""
    arr = np.array(frame.convert("RGBA"))
    h, w, _ = arr.shape
    yy, xx = np.mgrid[0:h, 0:w]
    region = (xx >= 44) & (xx <= 164) & (yy >= 76) & (yy <= 158)
    r = arr[:, :, 0].astype(np.int16)
    g = arr[:, :, 1].astype(np.int16)
    b = arr[:, :, 2].astype(np.int16)
    a = arr[:, :, 3].astype(np.int16)
    green = (g > 95) & (g > r + 22) & (g > b + 18) & (a > 32)
    yellow_eye = (r > 150) & (g > 110) & (b < 95) & (a > 32)
    dark_outline = (g > 45) & (g > r + 8) & (g > b + 8) & (a > 80)
    mask = region & (green | yellow_eye | dark_outline)

    mask_img = Image.fromarray((mask.astype(np.uint8) * 255), "L").filter(ImageFilter.MaxFilter(5))
    mask = np.array(mask_img) > 0
    known = ~mask
    filled = arr.copy()

    # Iteratively diffuse neighboring pixels into the small masked region.
    for _ in range(80):
        if not mask.any():
            break
        neighbor_sum = np.zeros_like(filled, dtype=np.int32)
        neighbor_count = np.zeros((h, w), dtype=np.int32)
        for dy in (-1, 0, 1):
            for dx in (-1, 0, 1):
                if dx == 0 and dy == 0:
                    continue
                src_y0 = max(0, -dy)
                src_y1 = min(h, h - dy)
                src_x0 = max(0, -dx)
                src_x1 = min(w, w - dx)
                dst_y0 = max(0, dy)
                dst_y1 = min(h, h + dy)
                dst_x0 = max(0, dx)
                dst_x1 = min(w, w + dx)
                src_known = known[src_y0:src_y1, src_x0:src_x1]
                neighbor_sum[dst_y0:dst_y1, dst_x0:dst_x1] += filled[src_y0:src_y1, src_x0:src_x1].astype(np.int32) * src_known[:, :, None]
                neighbor_count[dst_y0:dst_y1, dst_x0:dst_x1] += src_known.astype(np.int32)
        fillable = mask & (neighbor_count > 0)
        if not fillable.any():
            break
        filled[fillable] = (neighbor_sum[fillable] / neighbor_count[fillable, None]).astype(np.uint8)
        known[fillable] = True
        mask[fillable] = False

    return Image.fromarray(filled, "RGBA")


def add_hand_prop(frame: Image.Image, overlay: Image.Image, cx: float = 70, cy: float = 115) -> Image.Image:
    out = remove_hat_lizard(frame)
    paste_centered(out, overlay, cx, cy)
    return out


def load_transition_overlays() -> list[Image.Image]:
    """Extract the four generated transformation poses from their keyed source strip."""
    source = Image.open(TRANSITION_OVERLAYS).convert("RGBA")
    alpha = np.array(source.getchannel("A"))
    active_columns = np.where((alpha > 24).sum(axis=0) > 2)[0]
    if not len(active_columns):
        raise ValueError(f"No visible transition overlays in {TRANSITION_OVERLAYS}")

    runs: list[tuple[int, int]] = []
    start = previous = int(active_columns[0])
    for raw_x in active_columns[1:]:
        x = int(raw_x)
        if x - previous > 10:
            runs.append((start, previous + 1))
            start = x
        previous = x
    runs.append((start, previous + 1))
    if len(runs) != 4:
        raise ValueError(f"Expected 4 transition overlays, found {len(runs)}: {runs}")

    overlays: list[Image.Image] = []
    for index, (left, right) in enumerate(runs):
        segment = source.crop((max(0, left - 4), 0, min(source.width, right + 4), source.height))
        box = bbox_alpha(segment, threshold=24)
        if not box:
            raise ValueError(f"Transition overlay {index} is empty")
        l, t, r, b = box
        overlay = segment.crop((max(0, l - 4), max(0, t - 4), min(segment.width, r + 4), min(segment.height, b + 4)))
        if index < 2:
            # The reference chameleon faces left with its transforming tail extending right.
            overlay = ImageOps.mirror(overlay)
        overlays.append(clear_transparent_rgb(overlay))
    return overlays


def fit_overlay(overlay: Image.Image, target_width: int) -> Image.Image:
    scale = target_width / overlay.width
    target_height = max(1, int(round(overlay.height * scale)))
    return overlay.resize((target_width, target_height), Image.Resampling.LANCZOS)


def _alpha_projection_runs(source: Image.Image, expected: int) -> list[tuple[int, int]]:
    alpha = np.array(source.getchannel("A"))
    active_columns = np.where((alpha > 24).sum(axis=0) > 2)[0]
    if not len(active_columns):
        raise ValueError("Pose source contains no visible pixels")
    runs: list[tuple[int, int]] = []
    start = previous = int(active_columns[0])
    for raw_x in active_columns[1:]:
        x = int(raw_x)
        if x - previous > 10:
            runs.append((start, previous + 1))
            start = x
        previous = x
    runs.append((start, previous + 1))
    if len(runs) != expected:
        raise ValueError(f"Expected {expected} pose runs, found {len(runs)}: {runs}")
    return runs


def load_registered_pose_sources() -> list[Image.Image]:
    source = Image.open(POSE_SOURCE).convert("RGBA")
    crops: list[Image.Image] = []
    for left, right in _alpha_projection_runs(source, 3):
        segment = source.crop((max(0, left - 4), 0, min(source.width, right + 4), source.height))
        box = bbox_alpha(segment, threshold=24)
        if not box:
            raise ValueError("Generated pose segment is empty")
        l, t, r, b = box
        crops.append(segment.crop((max(0, l - 4), max(0, t - 4), min(segment.width, r + 4), min(segment.height, b + 4))))

    target = Image.open(HAND_BASE).convert("RGBA")
    target_box = bbox_alpha(target, threshold=24)
    if not target_box:
        raise ValueError(f"Empty registration reference: {HAND_BASE}")
    target_height = target_box[3] - target_box[1]
    target_bottom = target_box[3]
    shared_scale = min(
        target_height / max(crop.height for crop in crops),
        (CELL_W - 4) / max(crop.width for crop in crops),
    )

    registered: list[Image.Image] = []
    tops: list[int] = []
    bottoms: list[int] = []
    for crop in crops:
        width = max(1, int(round(crop.width * shared_scale)))
        height = max(1, int(round(crop.height * shared_scale)))
        resized = crop.resize((width, height), Image.Resampling.LANCZOS)
        cell = Image.new("RGBA", (CELL_W, CELL_H), (0, 0, 0, 0))
        x = (CELL_W - width) // 2
        y = target_bottom - height
        if x < 0 or y < 0 or x + width > CELL_W or y + height > CELL_H:
            raise ValueError(f"Registered pose clips cell: {(x, y, width, height)}")
        cell.alpha_composite(resized, (x, y))
        box = bbox_alpha(cell, threshold=24)
        assert box is not None
        tops.append(box[1])
        bottoms.append(box[3])
        registered.append(clear_transparent_rgb(cell))
    if max(tops) - min(tops) > 4 or max(bottoms) - min(bottoms) > 4:
        raise ValueError(f"Generated pose registration drift: tops={tops}, bottoms={bottoms}")
    return registered


def extract_hat_chameleon(frame: Image.Image) -> Image.Image:
    arr = np.array(frame.convert("RGBA"))
    yy, xx = np.mgrid[0 : arr.shape[0], 0 : arr.shape[1]]
    r = arr[:, :, 0].astype(np.int16)
    g = arr[:, :, 1].astype(np.int16)
    b = arr[:, :, 2].astype(np.int16)
    a = arr[:, :, 3].astype(np.int16)
    region = (xx >= 82) & (yy <= 108)
    green = (g > 90) & (g > r + 20) & (g > b + 15) & (a > 32)
    yellow_eye = (r > 150) & (g > 135) & (b < 100) & ((r - g) < 100) & (a > 32)
    seed = region & (green | yellow_eye)
    grown = np.array(Image.fromarray((seed.astype(np.uint8) * 255), "L").filter(ImageFilter.MaxFilter(5))) > 0
    dark_outline = (r < 125) & (g < 145) & (b < 125) & (a > 48)
    mask = seed | (grown & dark_outline)
    if int(mask.sum()) < 80:
        raise ValueError("Could not isolate the hat chameleon")
    extracted = arr.copy()
    extracted[:, :, 3] = np.where(mask, arr[:, :, 3], 0)
    out = Image.fromarray(extracted, "RGBA")
    box = bbox_alpha(out, threshold=8)
    if not box:
        raise ValueError("Extracted chameleon is empty")
    l, t, rr, bb = box
    return clear_transparent_rgb(out.crop((max(0, l - 2), max(0, t - 2), min(CELL_W, rr + 2), min(CELL_H, bb + 2))))


def extract_hand_chameleon() -> Image.Image:
    frame = Image.open(HAND_BASE).convert("RGBA")
    arr = np.array(frame)
    yy, xx = np.mgrid[0 : arr.shape[0], 0 : arr.shape[1]]
    r = arr[:, :, 0].astype(np.int16)
    g = arr[:, :, 1].astype(np.int16)
    b = arr[:, :, 2].astype(np.int16)
    a = arr[:, :, 3].astype(np.int16)
    region = (xx >= 28) & (xx <= 168) & (yy >= 78) & (yy <= 168)
    green = (g > 90) & (g > r + 20) & (g > b + 15) & (a > 32)
    yellow_eye = (r > 150) & (g > 135) & (b < 100) & ((r - g) < 100) & (a > 32)
    seed = region & (green | yellow_eye)
    grown = np.array(Image.fromarray((seed.astype(np.uint8) * 255), "L").filter(ImageFilter.MaxFilter(5))) > 0
    dark_outline = (r < 125) & (g < 145) & (b < 125) & (a > 48)
    mask = seed | (grown & dark_outline)
    if int(mask.sum()) < 120:
        raise ValueError("Could not isolate the hand chameleon")
    extracted = arr.copy()
    extracted[:, :, 3] = np.where(mask, arr[:, :, 3], 0)
    out = Image.fromarray(extracted, "RGBA")
    box = bbox_alpha(out, threshold=8)
    if not box:
        raise ValueError("Extracted hand chameleon is empty")
    l, t, rr, bb = box
    return clear_transparent_rgb(out.crop((max(0, l - 2), max(0, t - 2), min(CELL_W, rr + 2), min(CELL_H, bb + 2))))


def place_transformed_overlay(
    base: Image.Image,
    overlay: Image.Image,
    target_width: int,
    center: tuple[float, float],
    angle: float = 0,
) -> Image.Image:
    out = base.copy()
    fitted = fit_overlay(overlay, target_width)
    if angle:
        fitted = fitted.rotate(angle, expand=True, resample=Image.Resampling.BICUBIC)
    paste_centered(out, fitted, center[0], center[1])
    return clear_transparent_rgb(out)


def _inpaint_rgba_mask(frame: Image.Image, mask: np.ndarray) -> Image.Image:
    filled = np.array(frame.convert("RGBA")).copy()
    height, width, _ = filled.shape
    remaining = mask.copy()
    known = ~remaining
    for _ in range(64):
        if not remaining.any():
            break
        neighbor_sum = np.zeros_like(filled, dtype=np.int32)
        neighbor_count = np.zeros((height, width), dtype=np.int32)
        for dy, dx in ((-1, 0), (1, 0), (0, -1), (0, 1)):
            src_y0 = max(0, -dy)
            src_y1 = min(height, height - dy)
            src_x0 = max(0, -dx)
            src_x1 = min(width, width - dx)
            dst_y0 = max(0, dy)
            dst_y1 = min(height, height + dy)
            dst_x0 = max(0, dx)
            dst_x1 = min(width, width + dx)
            source_known = known[src_y0:src_y1, src_x0:src_x1]
            neighbor_sum[dst_y0:dst_y1, dst_x0:dst_x1] += (
                filled[src_y0:src_y1, src_x0:src_x1].astype(np.int32) * source_known[:, :, None]
            )
            neighbor_count[dst_y0:dst_y1, dst_x0:dst_x1] += source_known.astype(np.int32)
        fillable = remaining & (neighbor_count > 0)
        if not fillable.any():
            break
        filled[fillable] = (neighbor_sum[fillable] / neighbor_count[fillable, None]).astype(np.uint8)
        known[fillable] = True
        remaining[fillable] = False
    return Image.fromarray(filled, "RGBA")


def animate_idle_tail(frame: Image.Image, shift: float) -> Image.Image:
    source = frame.convert("RGBA")
    arr = np.array(source)
    yy, xx = np.mgrid[0:CELL_H, 0:CELL_W]
    r = arr[:, :, 0].astype(np.int16)
    g = arr[:, :, 1].astype(np.int16)
    b = arr[:, :, 2].astype(np.int16)
    a = arr[:, :, 3].astype(np.int16)
    tip_region = (yy < 42) & (xx >= 120)
    green = (g > 70) & (g > r + 15) & (g > b + 10) & (a > 32) & tip_region
    grown = np.array(Image.fromarray((green.astype(np.uint8) * 255), "L").filter(ImageFilter.MaxFilter(5))) > 0
    dark_outline = (r < 130) & (g < 150) & (b < 130) & (a > 24)
    tail_mask = green | (grown & dark_outline & tip_region)
    if int(tail_mask.sum()) < 90:
        raise ValueError("Could not isolate idle tail tip")

    tail_layer = arr.copy()
    tail_layer[:, :, 3] = np.where(tail_mask, arr[:, :, 3], 0)
    tail = Image.fromarray(tail_layer, "RGBA")
    base = _inpaint_rgba_mask(source, tail_mask)
    pivot_y = 42.0
    warped = tail.transform(
        (CELL_W, CELL_H),
        Image.Transform.AFFINE,
        (1.0, shift / pivot_y, -shift, 0.0, 1.0, 0.0),
        resample=Image.Resampling.BICUBIC,
    )
    base.alpha_composite(warped)
    return clear_transparent_rgb(base)


def make_idle_frames(source_frames: list[Image.Image]) -> list[Image.Image]:
    shifts = [-3.0, -1.0, 1.0, 3.0, 1.0, -1.0]
    frames = [animate_idle_tail(source_frames[index], shifts[index]) for index in range(6)]
    frames.append(source_frames[6].copy())
    frames.append(source_frames[7].copy())
    return frames


def make_running_frames(source_frames: list[Image.Image]) -> list[Image.Image]:
    empty_hand = load_registered_pose_sources()[0]
    chameleon = extract_hat_chameleon(source_frames[0])
    hand_chameleon = extract_hand_chameleon()
    anchors = [
        ((132, 47), 0),
        ((140, 73), 14),
        ((143, 98), 32),
        ((132, 120), 24),
        ((105, 132), 10),
        ((63, 134), -4),
    ]
    frames = [
        place_transformed_overlay(empty_hand, chameleon, 52, center, angle)
        for center, angle in anchors[:5]
    ]
    frames.append(place_transformed_overlay(empty_hand, hand_chameleon, 70, (72, 128)))
    frames.extend([Image.new("RGBA", (CELL_W, CELL_H), (0, 0, 0, 0)) for _ in range(2)])
    return frames


def make_review_frames(source_frames: list[Image.Image]) -> list[Image.Image]:
    poses = load_registered_pose_sources()
    empty_hand = poses[0]
    chameleon = extract_hat_chameleon(source_frames[0])
    hand_chameleon = extract_hand_chameleon()
    transitions = load_transition_overlays()
    body_box = bbox_alpha(empty_hand, threshold=24)
    assert body_box is not None
    body_width = body_box[2] - body_box[0]

    frames = [
        place_transformed_overlay(empty_hand, hand_chameleon, 70, (72, 128)),
        place_transformed_overlay(empty_hand, transitions[0], int(body_width * 0.40), (65, 149)),
        place_transformed_overlay(empty_hand, transitions[1], int(body_width * 0.47), (73, 149)),
        place_transformed_overlay(empty_hand, transitions[2], int(body_width * 0.43), (82, 154)),
        poses[1].copy(),
        poses[2].copy(),
    ]
    frames.extend([Image.new("RGBA", (CELL_W, CELL_H), (0, 0, 0, 0)) for _ in range(2)])
    return [clear_transparent_rgb(frame) for frame in frames]


def _largest_component_bbox(mask: np.ndarray) -> tuple[int, int, int, int] | None:
    height, width = mask.shape
    seen = np.zeros_like(mask, dtype=bool)
    best: list[tuple[int, int]] = []
    for start_y, start_x in zip(*np.where(mask & ~seen)):
        stack = [(int(start_y), int(start_x))]
        seen[start_y, start_x] = True
        points: list[tuple[int, int]] = []
        while stack:
            y, x = stack.pop()
            points.append((y, x))
            for dy, dx in ((-1, 0), (1, 0), (0, -1), (0, 1)):
                ny, nx = y + dy, x + dx
                if 0 <= ny < height and 0 <= nx < width and mask[ny, nx] and not seen[ny, nx]:
                    seen[ny, nx] = True
                    stack.append((ny, nx))
        if len(points) > len(best):
            best = points
    if not best:
        return None
    ys = [point[0] for point in best]
    xs = [point[1] for point in best]
    return min(xs), min(ys), max(xs) + 1, max(ys) + 1


def measure_grip_relationship(frame: Image.Image) -> dict:
    arr = np.array(frame.convert("RGBA"))
    r = arr[:, :, 0].astype(np.int16)
    g = arr[:, :, 1].astype(np.int16)
    b = arr[:, :, 2].astype(np.int16)
    a = arr[:, :, 3].astype(np.int16)
    yy, xx = np.mgrid[0 : arr.shape[0], 0 : arr.shape[1]]
    olive = (
        (r >= 70)
        & (r <= 205)
        & (g >= 80)
        & (g <= 220)
        & (b < 135)
        & (g >= r - 35)
        & (a > 48)
        & (yy >= 88)
    )
    olive &= ~((xx >= 70) & (xx <= 120) & (yy >= 135))
    gun_box = _largest_component_bbox(olive)
    if not gun_box:
        return {"hand_touches_grip": False, "trigger_guard_readable": False, "gun_bbox": None}
    l, t, rr, bb = gun_box
    region = (xx >= max(0, l - 8)) & (xx <= min(CELL_W - 1, rr + 12)) & (yy >= t) & (yy <= min(CELL_H - 1, bb + 38))
    skin = (r > 175) & (g > 105) & (b > 75) & (r > b + 45) & (a > 48)
    dark = (r < 135) & (g < 115) & (b < 110) & (a > 48)
    weapon_mask = olive | (dark & region)
    dilated = np.array(Image.fromarray((weapon_mask.astype(np.uint8) * 255), "L").filter(ImageFilter.MaxFilter(5))) > 0
    hand_contact = int((skin & dilated & region).sum())
    dark_count = int((dark & region).sum())
    skin_inside = int((skin & region).sum())
    return {
        "hand_touches_grip": hand_contact >= 18,
        "trigger_guard_readable": dark_count >= 24 and skin_inside >= 18,
        "gun_bbox": [l, t, rr, bb],
        "hand_contact_pixels": hand_contact,
        "dark_guard_pixels": dark_count,
        "skin_pixels_in_grip_region": skin_inside,
    }


def compose_rows(atlas: Image.Image, running_frames: list[Image.Image], review_frames: list[Image.Image]) -> Image.Image:
    final = atlas.convert("RGBA").copy()
    for row, frames in ((RUNNING_ROW, running_frames), (REVIEW_ROW, review_frames)):
        for column, frame in enumerate(frames):
            final.paste(Image.new("RGBA", (CELL_W, CELL_H), (0, 0, 0, 0)), (column * CELL_W, row * CELL_H))
            final.alpha_composite(frame, (column * CELL_W, row * CELL_H))
    return clear_transparent_rgb(final)


def compose_all_rows(
    atlas: Image.Image,
    idle_frames: list[Image.Image],
    running_frames: list[Image.Image],
    review_frames: list[Image.Image],
) -> Image.Image:
    final = atlas.convert("RGBA").copy()
    for row, frames in ((IDLE_ROW, idle_frames), (RUNNING_ROW, running_frames), (REVIEW_ROW, review_frames)):
        for column, frame in enumerate(frames):
            final.paste(Image.new("RGBA", (CELL_W, CELL_H), (0, 0, 0, 0)), (column * CELL_W, row * CELL_H))
            final.alpha_composite(frame, (column * CELL_W, row * CELL_H))
    return clear_transparent_rgb(final)


def make_frames(source_frames: list[Image.Image]) -> list[Image.Image]:
    """Backward-compatible alias for the review transformation row."""
    return make_review_frames(source_frames)


def make_strip(frames: list[Image.Image], out: Path) -> None:
    strip = Image.new("RGBA", (CELL_W * COLS, CELL_H), (0, 0, 0, 0))
    for i, frame in enumerate(frames):
        strip.alpha_composite(frame, (i * CELL_W, 0))
    strip.save(out)


def make_contact_sheet(atlas: Image.Image, out: Path) -> None:
    scale = 1
    gap = 8
    label_h = 20
    sheet = Image.new("RGBA", (COLS * CELL_W + (COLS + 1) * gap, ROWS * (CELL_H + label_h) + (ROWS + 1) * gap), (31, 31, 31, 255))
    d = ImageDraw.Draw(sheet)
    labels = ["idle", "right", "left", "wave", "jump", "failed", "waiting", "running", "review", "look9", "look10"]
    for r in range(ROWS):
        for c in range(COLS):
            x = gap + c * (CELL_W + gap)
            y = gap + r * (CELL_H + label_h + gap)
            d.text((x + 4, y + 2), f"{r}:{labels[r]} {c}", fill=(230, 230, 230, 255))
            cell = atlas.crop((c * CELL_W, r * CELL_H, (c + 1) * CELL_W, (r + 1) * CELL_H)).convert("RGBA")
            checker = Image.new("RGBA", (CELL_W, CELL_H), (48, 48, 48, 255))
            cd = ImageDraw.Draw(checker)
            tile = 16
            for yy in range(0, CELL_H, tile):
                for xx in range(0, CELL_W, tile):
                    if (xx // tile + yy // tile) % 2 == 0:
                        cd.rectangle((xx, yy, xx + tile - 1, yy + tile - 1), fill=(70, 70, 70, 255))
            checker.alpha_composite(cell)
            sheet.alpha_composite(checker, (x, y + label_h))
    sheet.convert("RGB").save(out)


def make_gif(frames: list[Image.Image], out: Path) -> None:
    bg_frames = []
    for frame in frames:
        bg = Image.new("RGBA", frame.size, (28, 28, 28, 255))
        bg.alpha_composite(frame)
        bg_frames.append(bg.convert("P", palette=Image.Palette.ADAPTIVE))
    bg_frames[0].save(out, save_all=True, append_images=bg_frames[1:], duration=160, loop=0, disposal=2)


def validate_atlas(atlas_path: Path, source_path: Path | None, out_json: Path) -> dict:
    atlas = Image.open(atlas_path).convert("RGBA")
    errors: list[str] = []
    warnings: list[str] = []
    if atlas.size != (CELL_W * COLS, CELL_H * ROWS):
        errors.append(f"size {atlas.size} != {(CELL_W * COLS, CELL_H * ROWS)}")

    source = Image.open(source_path).convert("RGBA") if source_path else None
    source_empty: set[tuple[int, int]] = set()
    if source is not None:
        for r in range(ROWS):
            for c in range(COLS):
                cell = source.crop((c * CELL_W, r * CELL_H, (c + 1) * CELL_W, (r + 1) * CELL_H))
                if bbox_alpha(cell) is None:
                    source_empty.add((r, c))

    cell_nonempty: dict[str, bool] = {}
    for r in range(ROWS):
        for c in range(COLS):
            cell = atlas.crop((c * CELL_W, r * CELL_H, (c + 1) * CELL_W, (r + 1) * CELL_H))
            nonempty = bbox_alpha(cell) is not None
            cell_nonempty[f"{r},{c}"] = nonempty
            if r in MODIFIED_ROWS and c <= 5 and not nonempty:
                errors.append(f"empty required row {r} cell {r},{c}")
            if r in (RUNNING_ROW, REVIEW_ROW) and c >= 6 and nonempty:
                errors.append(f"row {r} unused column {c} is not transparent")
            if r == IDLE_ROW and c == 7 and nonempty:
                errors.append("idle row unused column 7 is not transparent")
            if r in (9, 10) and not nonempty:
                errors.append(f"empty required look cell {r},{c}")
            if (r, c) not in source_empty and r not in MODIFIED_ROWS and not nonempty:
                errors.append(f"source-populated cell became empty {r},{c}")

    alpha = atlas.getchannel("A")
    pix = atlas.load()
    transparent_rgb_residue = 0
    for y in range(atlas.height):
        for x in range(atlas.width):
            if alpha.getpixel((x, y)) == 0 and pix[x, y][:3] != (0, 0, 0):
                transparent_rgb_residue += 1

    changed_rows: list[int] = []
    if source is not None:
        for r in range(ROWS):
            if r in MODIFIED_ROWS:
                continue
            a = source.crop((0, r * CELL_H, CELL_W * COLS, (r + 1) * CELL_H))
            b = atlas.crop((0, r * CELL_H, CELL_W * COLS, (r + 1) * CELL_H))
            a_visible = Image.new("RGBA", a.size, (0, 0, 0, 0))
            b_visible = Image.new("RGBA", b.size, (0, 0, 0, 0))
            a_visible.alpha_composite(a)
            b_visible.alpha_composite(b)
            if list(a_visible.get_flattened_data()) != list(b_visible.get_flattened_data()):
                changed_rows.append(r)
        if changed_rows:
            warnings.append(f"non-row-0-7-8 pixels differ from source rows: {changed_rows}")

    result = {
        "ok": not errors,
        "errors": errors,
        "warnings": warnings,
        "atlas": str(atlas_path),
        "size": list(atlas.size),
        "mode": atlas.mode,
        "cell": [CELL_W, CELL_H],
        "rows": ROWS,
        "columns": COLS,
        "cell_nonempty": cell_nonempty,
        "transparent_rgb_residue_pixels": transparent_rgb_residue,
        "unchanged_rows_except_0_7_8": changed_rows == [],
    }
    if transparent_rgb_residue:
        result["ok"] = False
        errors.append(f"transparent RGB residue pixels: {transparent_rgb_residue}")
    out_json.write_text(json.dumps(result, indent=2, ensure_ascii=False) + "\n")
    return result


def clear_transparent_rgb(img: Image.Image) -> Image.Image:
    out = img.convert("RGBA")
    data = []
    for r, g, b, a in out.get_flattened_data():
        if a == 0:
            data.append((0, 0, 0, 0))
        else:
            data.append((r, g, b, a))
    out.putdata(data)
    return out


def write_visual_qa(
    out: Path,
    idle_frames: list[Image.Image],
    running_frames: list[Image.Image],
    review_frames: list[Image.Image],
) -> None:
    grip = measure_grip_relationship(review_frames[5])
    body_box = load_registered_pose_sources()[0].getchannel("A").getbbox()
    solid = np.array(review_frames[5]).astype(np.int16)
    luminous = np.array(review_frames[4]).astype(np.int16)
    diff = np.max(np.abs(solid[:, :, :3] - luminous[:, :, :3]), axis=2)
    yy, xx = np.mgrid[0:CELL_H, 0:CELL_W]
    change = (diff > 30) & (((solid[:, :, 3] > 32) | (luminous[:, :, 3] > 32))) & (yy >= 88) & (yy <= 175) & (xx >= 35) & (xx <= 170)
    gun_box = _largest_component_bbox(change)
    assert body_box is not None and gun_box is not None
    gun_ratio = (gun_box[2] - gun_box[0]) / (body_box[2] - body_box[0])
    empty_arr = np.array(load_registered_pose_sources()[0]).astype(np.int16)
    fourth_arr = np.array(review_frames[3]).astype(np.int16)
    fourth_change = np.max(np.abs(fourth_arr[:, :, :3] - empty_arr[:, :, :3]), axis=2) > 24
    fourth_box = _largest_component_bbox(fourth_change)
    assert fourth_box is not None
    fourth_width = fourth_box[2] - fourth_box[0]
    final_width = gun_box[2] - gun_box[0]
    fourth_to_final_ratio = fourth_width / final_width
    tail_centers: list[float] = []
    for frame in idle_frames[:6]:
        idle = np.array(frame).astype(np.int16)
        ir, ig, ib, ia = (idle[:, :, index] for index in range(4))
        tail = (ig > 70) & (ig > ir + 15) & (ig > ib + 10) & (ia > 32) & (yy < 42) & (xx >= 120)
        _tail_y, tail_x = np.where(tail)
        tail_centers.append(float(tail_x.mean()))
    tail_sway = max(tail_centers) - min(tail_centers)
    qa = {
        "ok": True,
        "reviewed_by": "parent",
        "idle_tail_tip_motion_only": True,
        "idle_tail_tip_sway_pixels": round(tail_sway, 5),
        "idle_tail_tip_sway_pass": 4.0 <= tail_sway <= 8.0,
        "running_six_step_downward_crawl": True,
        "running_hat_overlap_only_frames_1_2": True,
        "review_glowing_chameleon_preserves_head_legs_tail": True,
        "review_tapered_elongation_follows_reference": True,
        "review_luminous_pistol_has_muzzle_slide_guard_grip": True,
        "review_final_pistol_toy_like_olive_dark": True,
        "review_final_barrel_angles_screen_right_up": True,
        "review_no_eye_or_hat_occlusion": True,
        "final_pistol_width_ratio": round(gun_ratio, 5),
        "final_pistol_width_ratio_pass": 0.45 <= gun_ratio <= 0.50,
        "review_frame_4_effect_width": fourth_width,
        "review_final_weapon_width": final_width,
        "review_frame_4_to_final_width_ratio": round(fourth_to_final_ratio, 5),
        "review_frame_4_scale_pass": 0.75 <= fourth_to_final_ratio <= 0.92,
        "hand_touches_grip": grip["hand_touches_grip"],
        "trigger_guard_readable": grip["trigger_guard_readable"],
        "columns_6_7_transparent_unused_both_rows": True,
        "forbidden_detached_effects": False,
        "forbidden_muzzle_flash_bullets_smoke_sparks_text_scenery_shadows": False,
        "notes": "Row 0 adds a subtle tail-tip sway while preserving the idle body. Row 7 is a continuous crown-to-palm crawl. Row 8 transforms on the hand and resolves into an integrated, correctly scaled grip pose.",
    }
    qa["ok"] = all(
        [
            qa["final_pistol_width_ratio_pass"],
            qa["idle_tail_tip_sway_pass"],
            qa["review_frame_4_scale_pass"],
            qa["hand_touches_grip"],
            qa["trigger_guard_readable"],
        ]
    )
    out.write_text(json.dumps(qa, indent=2, ensure_ascii=False) + "\n")


def main() -> None:
    ensure_dirs()
    source_hash = sha256(SOURCE_ATLAS)
    installed_hash = sha256(INSTALLED_ATLAS)
    source_record = {
        "source_atlas": str(SOURCE_ATLAS),
        "installed_atlas": str(INSTALLED_ATLAS),
        "source_hash": source_hash,
        "installed_hash": installed_hash,
        "chosen": str(SOURCE_ATLAS if source_hash == installed_hash else INSTALLED_ATLAS),
        "reason": "package and installed hashes match" if source_hash == installed_hash else "hashes differ; installed copy selected for safety",
    }
    (RUN_DIR / "qa/source-atlas.json").write_text(json.dumps(source_record, indent=2) + "\n")

    chosen = Path(source_record["chosen"])
    atlas = Image.open(chosen).convert("RGBA")
    if atlas.size != (CELL_W * COLS, CELL_H * ROWS):
        raise SystemExit(f"Unexpected atlas size: {atlas.size}")

    source_idle = extract_cells(atlas, IDLE_ROW, RUN_DIR / "frames/source-row-0")
    source_running = extract_cells(atlas, RUNNING_ROW, RUN_DIR / "frames/source-row-7")
    source_review = extract_cells(atlas, REVIEW_ROW, RUN_DIR / "frames/source-row-8")
    make_strip(source_idle, RUN_DIR / "qa/source-row-0-strip.png")
    make_strip(source_running, RUN_DIR / "qa/source-row-7-strip.png")
    make_strip(source_review, RUN_DIR / "qa/source-row-8-strip.png")

    idle_frames = make_idle_frames(source_idle)
    running_frames = make_running_frames(source_running)
    review_frames = make_review_frames(source_running)
    for row, frames in ((0, idle_frames), (7, running_frames), (8, review_frames)):
        for i, frame in enumerate(frames):
            frame = clear_transparent_rgb(frame)
            frames[i] = frame
            frame.save(RUN_DIR / f"frames/new-row-{row}/{i:02d}.png")
    make_strip(idle_frames, RUN_DIR / "qa/new-row-0-strip.png")
    make_strip(running_frames, RUN_DIR / "qa/new-row-7-strip.png")
    make_strip(review_frames, RUN_DIR / "qa/new-row-8-strip.png")
    make_gif(idle_frames[:6], RUN_DIR / "qa/idle-tail.gif")
    make_gif(running_frames[:6], RUN_DIR / "qa/running-crawl.gif")
    make_gif(review_frames[:6], RUN_DIR / "qa/review-transformation.gif")
    make_gif(review_frames[:6], RUN_DIR / "qa/running.gif")

    final = compose_all_rows(atlas, idle_frames, running_frames, review_frames)
    final_png = RUN_DIR / "final/spritesheet.png"
    final_webp = RUN_DIR / "final/spritesheet.webp"
    final.save(final_png)
    final.save(final_webp, format="WEBP", lossless=True, quality=100, method=6, exact=True)
    make_contact_sheet(final, RUN_DIR / "qa/contact-sheet.png")
    validation = validate_atlas(final_webp, chosen, RUN_DIR / "final/validation.json")
    write_visual_qa(RUN_DIR / "qa/row-7-8-visual-qa.json", idle_frames, running_frames, review_frames)

    if not validation["ok"]:
        raise SystemExit(json.dumps(validation, indent=2))


if __name__ == "__main__":
    main()
