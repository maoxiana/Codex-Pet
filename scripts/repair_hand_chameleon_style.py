#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
from collections import deque
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw, ImageFilter


CELL_W = 192
CELL_H = 208
COLS = 8
ROWS = 11
TARGET_CELLS = ((7, 5), (8, 0))
LIZARD_WIDTH = 78
LIZARD_CENTER = (72, 139)
EYE_ROI = (24, 122, 80, 149)


def clear_transparent_rgb(image: Image.Image) -> Image.Image:
    array = np.array(image.convert("RGBA"))
    array[array[:, :, 3] == 0, :3] = 0
    return Image.fromarray(array, "RGBA")


def trim_to_alpha(image: Image.Image) -> Image.Image:
    rgba = clear_transparent_rgb(image)
    box = rgba.getchannel("A").getbbox()
    if box is None:
        raise ValueError("The chameleon asset is empty")
    return rgba.crop(box)


def fit_width(image: Image.Image, width: int) -> Image.Image:
    source = trim_to_alpha(image)
    height = max(1, round(source.height * width / source.width))
    return clear_transparent_rgb(source.resize((width, height), Image.Resampling.LANCZOS))


def _components(mask: np.ndarray, minimum_pixels: int = 5) -> list[tuple[int, int, int, int]]:
    seen = np.zeros_like(mask, dtype=bool)
    components: list[tuple[int, int, int, int]] = []
    height, width = mask.shape
    for start_y, start_x in zip(*np.where(mask & ~seen)):
        queue = deque([(int(start_y), int(start_x))])
        seen[start_y, start_x] = True
        points: list[tuple[int, int]] = []
        while queue:
            y, x = queue.popleft()
            points.append((y, x))
            for dy, dx in ((-1, 0), (1, 0), (0, -1), (0, 1)):
                ny, nx = y + dy, x + dx
                if 0 <= ny < height and 0 <= nx < width and mask[ny, nx] and not seen[ny, nx]:
                    seen[ny, nx] = True
                    queue.append((ny, nx))
        if len(points) >= minimum_pixels:
            ys = [point[0] for point in points]
            xs = [point[1] for point in points]
            components.append((min(xs), min(ys), max(xs) + 1, max(ys) + 1))
    return sorted(components)


def eye_components(frame: Image.Image) -> list[tuple[int, int, int, int]]:
    array = np.array(frame.convert("RGBA")).astype(np.int16)
    left, top, right, bottom = EYE_ROI
    roi = array[top:bottom, left:right]
    red, green, blue, alpha = (roi[:, :, channel] for channel in range(4))
    orange_yellow = (red > 170) & (green > 75) & (blue < 125) & (alpha > 48)
    # The eyes contain highlights and a dark vertical pupil. Join those nearby
    # color islands before counting so each physical eye is one component.
    joined = Image.fromarray((orange_yellow.astype(np.uint8) * 255), "L").filter(ImageFilter.MaxFilter(3))
    orange_yellow = np.array(joined) > 0
    return [
        (x0 + left, y0 + top, x1 + left, y1 + top)
        for x0, y0, x1, y1 in _components(orange_yellow)
    ]


def compose_hand_pose(base_pose: Image.Image, chameleon: Image.Image) -> Image.Image:
    frame = clear_transparent_rgb(base_pose)
    if frame.size != (CELL_W, CELL_H):
        raise ValueError(f"Expected a 192x208 base pose, received {frame.size}")
    lizard = fit_width(chameleon, LIZARD_WIDTH)
    x = round(LIZARD_CENTER[0] - lizard.width / 2)
    y = round(LIZARD_CENTER[1] - lizard.height / 2)
    frame.alpha_composite(lizard, (x, y))
    frame = clear_transparent_rgb(frame)
    eyes = eye_components(frame)
    if len(eyes) != 2:
        raise ValueError(f"Expected exactly two readable chameleon eyes, found {eyes}")
    return frame


def cell(atlas: Image.Image, row: int, column: int) -> Image.Image:
    return atlas.crop(
        (
            column * CELL_W,
            row * CELL_H,
            (column + 1) * CELL_W,
            (row + 1) * CELL_H,
        )
    ).convert("RGBA")


def repair_atlas(
    atlas: Image.Image,
    base_pose: Image.Image,
    chameleon: Image.Image,
) -> tuple[Image.Image, list[dict[str, object]], list[Image.Image]]:
    source = atlas.convert("RGBA")
    if source.size != (CELL_W * COLS, CELL_H * ROWS):
        raise ValueError(f"Expected a 1536x2288 v2 atlas, received {source.size}")

    replacement = compose_hand_pose(base_pose, chameleon)
    repaired = source.copy()
    records: list[dict[str, object]] = []
    qa_cells: list[Image.Image] = []
    for row, column in TARGET_CELLS:
        before = cell(source, row, column)
        repaired.paste(replacement, (column * CELL_W, row * CELL_H))
        qa_cells.extend((before, replacement))
        records.append(
            {
                "row": row,
                "column": column,
                "eye_components": eye_components(replacement),
                "replacement_alpha_bbox": replacement.getchannel("A").getbbox(),
            }
        )
    return clear_transparent_rgb(repaired), records, qa_cells


def make_qa_strip(cells: list[Image.Image], output: Path) -> None:
    scale = 2
    label_height = 24
    canvas = Image.new("RGBA", (len(cells) * CELL_W * scale, CELL_H * scale + label_height), (36, 36, 36, 255))
    draw = ImageDraw.Draw(canvas)
    labels = ("running before", "running after", "review before", "review after")
    for index, (frame, label) in enumerate(zip(cells, labels)):
        enlarged = frame.resize((CELL_W * scale, CELL_H * scale), Image.Resampling.NEAREST)
        canvas.alpha_composite(enlarged, (index * CELL_W * scale, label_height))
        draw.text((index * CELL_W * scale + 8, 6), label, fill=(255, 255, 255, 255))
    output.parent.mkdir(parents=True, exist_ok=True)
    canvas.save(output)


def parse_args() -> argparse.Namespace:
    root = Path(__file__).resolve().parents[1]
    parser = argparse.ArgumentParser(description="Replace Reborn's hand-held chameleon with the reference-style asset.")
    parser.add_argument("--source", type=Path, default=root / "final/spritesheet.webp")
    parser.add_argument("--base-pose", type=Path, default=root / "assets/reborn-empty-hand-pose.png")
    parser.add_argument("--chameleon", type=Path, default=root / "assets/hand-chameleon-reference-style.png")
    parser.add_argument("--png-output", type=Path, default=root / "final/spritesheet.png")
    parser.add_argument("--webp-output", type=Path, default=root / "final/spritesheet.webp")
    parser.add_argument("--qa-output", type=Path, default=root / "qa/hand-chameleon-style-repair.png")
    parser.add_argument("--report-output", type=Path, default=root / "qa/hand-chameleon-style-repair.json")
    return parser.parse_args()


def main() -> None:
    args = parse_args()
    source = Image.open(args.source).convert("RGBA")
    base_pose = Image.open(args.base_pose).convert("RGBA")
    chameleon = Image.open(args.chameleon).convert("RGBA")
    repaired, records, qa_cells = repair_atlas(source, base_pose, chameleon)

    args.png_output.parent.mkdir(parents=True, exist_ok=True)
    args.webp_output.parent.mkdir(parents=True, exist_ok=True)
    repaired.save(args.png_output)
    repaired.save(args.webp_output, format="WEBP", lossless=True, quality=100, method=6, exact=True)
    make_qa_strip(qa_cells, args.qa_output)

    reloaded = Image.open(args.webp_output).convert("RGBA")
    exact_round_trip = np.array_equal(np.array(repaired), np.array(reloaded))
    report = {
        "ok": exact_round_trip and all(len(record["eye_components"]) == 2 for record in records),
        "source": str(args.source),
        "base_pose": str(args.base_pose),
        "chameleon": str(args.chameleon),
        "png_output": str(args.png_output),
        "webp_output": str(args.webp_output),
        "size": list(repaired.size),
        "target_cells": records,
        "lizard_width": LIZARD_WIDTH,
        "lizard_center": list(LIZARD_CENTER),
        "lossless_round_trip_exact": exact_round_trip,
        "untouched_cells": ROWS * COLS - len(TARGET_CELLS),
    }
    args.report_output.parent.mkdir(parents=True, exist_ok=True)
    args.report_output.write_text(json.dumps(report, indent=2, ensure_ascii=False) + "\n")
    if not report["ok"]:
        raise SystemExit(json.dumps(report, indent=2, ensure_ascii=False))


if __name__ == "__main__":
    main()
