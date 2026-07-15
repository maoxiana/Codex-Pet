#!/usr/bin/env python3
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path

import numpy as np
from PIL import Image, ImageFilter


CELL_W = 192
CELL_H = 208
COLS = 8
ROWS = 11


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def _blur_float(channel: np.ndarray, radius: float) -> np.ndarray:
    image = Image.fromarray(np.clip(np.rint(channel * 255.0), 0, 255).astype(np.uint8), "L")
    blurred = image.filter(ImageFilter.GaussianBlur(radius=radius))
    return np.asarray(blurred, dtype=np.float32) / 255.0


def sharpen_cell(
    source: Image.Image,
    *,
    radius: float,
    amount: float,
    edge_strength: float,
) -> Image.Image:
    """Sharpen straight-alpha art without pulling transparent black into edges."""
    array = np.asarray(source.convert("RGBA"), dtype=np.float32) / 255.0
    rgb = array[:, :, :3]
    alpha = array[:, :, 3]

    if not np.any(alpha > 0):
        return source.convert("RGBA").copy()

    premultiplied = rgb * alpha[:, :, None]
    blurred_alpha = _blur_float(alpha, radius)
    blurred_premultiplied = np.stack(
        [_blur_float(premultiplied[:, :, channel], radius) for channel in range(3)],
        axis=2,
    )
    local_color = np.divide(
        blurred_premultiplied,
        blurred_alpha[:, :, None],
        out=rgb.copy(),
        where=blurred_alpha[:, :, None] > (1.0 / 255.0),
    )

    sharpened_rgb = np.clip(rgb + amount * (rgb - local_color), 0.0, 1.0)

    # Increase the slope around 50% alpha. This removes only the faintest fringe
    # and makes near-opaque edge pixels more decisive without growing the sprite.
    tightened_alpha = np.clip(
        (alpha - 0.5) * (1.0 + edge_strength) + 0.5,
        0.0,
        1.0,
    )
    # Retain the original support exactly. Very faint antialiasing may become
    # fainter, but a light cleanup must not contract thin hair, tail, or hand
    # details by deleting their outermost source pixels.
    tightened_alpha[(alpha > 0.0) & (tightened_alpha < (1.0 / 255.0))] = 1.0 / 255.0
    tightened_alpha[alpha == 0.0] = 0.0
    tightened_alpha[alpha == 1.0] = 1.0

    result = np.empty_like(array)
    result[:, :, :3] = sharpened_rgb
    result[:, :, 3] = tightened_alpha
    result[tightened_alpha == 0.0, :3] = 0.0
    return Image.fromarray(np.clip(np.rint(result * 255.0), 0, 255).astype(np.uint8), "RGBA")


def repair_atlas(
    atlas: Image.Image,
    *,
    radius: float = 0.65,
    amount: float = 0.28,
    edge_strength: float = 0.08,
) -> tuple[Image.Image, dict[str, object]]:
    atlas = atlas.convert("RGBA")
    expected_size = (CELL_W * COLS, CELL_H * ROWS)
    if atlas.size != expected_size:
        raise ValueError(f"Expected v2 atlas size {expected_size}, got {atlas.size}")

    output = Image.new("RGBA", atlas.size, (0, 0, 0, 0))
    before = np.asarray(atlas)
    nonempty_cells = 0

    for row in range(ROWS):
        for column in range(COLS):
            box = (
                column * CELL_W,
                row * CELL_H,
                (column + 1) * CELL_W,
                (row + 1) * CELL_H,
            )
            source = atlas.crop(box)
            if source.getchannel("A").getbbox() is None:
                output.paste(source, box[:2])
                continue
            nonempty_cells += 1
            output.paste(
                sharpen_cell(
                    source,
                    radius=radius,
                    amount=amount,
                    edge_strength=edge_strength,
                ),
                box[:2],
            )

    after = np.asarray(output)
    before_alpha = before[:, :, 3]
    after_alpha = after[:, :, 3]
    report = {
        "ok": True,
        "size": list(output.size),
        "cell_size": [CELL_W, CELL_H],
        "grid": [COLS, ROWS],
        "nonempty_cells": nonempty_cells,
        "parameters": {
            "radius": radius,
            "amount": amount,
            "edge_strength": edge_strength,
        },
        "changed_pixels": int(np.any(before != after, axis=2).sum()),
        "partial_alpha_before": int(((before_alpha > 0) & (before_alpha < 255)).sum()),
        "partial_alpha_after": int(((after_alpha > 0) & (after_alpha < 255)).sum()),
        "visible_pixels_before": int((before_alpha > 0).sum()),
        "visible_pixels_after": int((after_alpha > 0).sum()),
        "new_visible_pixels": int(((before_alpha == 0) & (after_alpha > 0)).sum()),
        "lost_opaque_pixels": int(((before_alpha == 255) & (after_alpha < 255)).sum()),
    }
    return output, report


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Mildly sharpen and tighten a Codex v2 pet atlas")
    parser.add_argument("source", type=Path)
    parser.add_argument("--png-output", type=Path, required=True)
    parser.add_argument("--webp-output", type=Path, required=True)
    parser.add_argument("--json-out", type=Path, required=True)
    parser.add_argument("--radius", type=float, default=0.65)
    parser.add_argument("--amount", type=float, default=0.28)
    parser.add_argument("--edge-strength", type=float, default=0.08)
    return parser.parse_args()


def main() -> None:
    args = parse_args()
    source = Image.open(args.source).convert("RGBA")
    repaired, report = repair_atlas(
        source,
        radius=args.radius,
        amount=args.amount,
        edge_strength=args.edge_strength,
    )
    args.png_output.parent.mkdir(parents=True, exist_ok=True)
    args.webp_output.parent.mkdir(parents=True, exist_ok=True)
    args.json_out.parent.mkdir(parents=True, exist_ok=True)
    repaired.save(args.png_output, format="PNG", optimize=True)
    repaired.save(
        args.webp_output,
        format="WEBP",
        lossless=True,
        quality=100,
        method=6,
        exact=True,
    )
    report["source"] = str(args.source.resolve())
    report["png_output"] = str(args.png_output.resolve())
    report["webp_output"] = str(args.webp_output.resolve())
    report["png_sha256"] = sha256(args.png_output)
    report["webp_sha256"] = sha256(args.webp_output)
    args.json_out.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(report, indent=2))


if __name__ == "__main__":
    main()
