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

# The source animation uses several character scales. These widths keep the
# new cap/body relationship readable without making the bell dominate the pet.
ROW_BELL_WIDTH = {
    0: 28,
    1: 25,
    2: 25,
    3: 32,
    4: 29,
    5: 29,
    6: 25,
    7: 24,
    8: 24,
    9: 28,
    10: 28,
}

ROW_EXPECTED_Y = {
    0: 166,
    1: 163,
    2: 159,
    3: 159,
    4: 169,
    5: 164,
    6: 149,
    7: 153,
    8: 153,
    9: 160,
    10: 156,
}

# The generated bell's round body center sits below the center of its full
# silhouette because of the shallow cap and top knob.
BELL_BODY_CENTER_Y = 0.63


def clear_transparent_rgb(image: Image.Image) -> Image.Image:
    array = np.array(image.convert("RGBA"))
    array[array[:, :, 3] == 0, :3] = 0
    return Image.fromarray(array, "RGBA")


def trim_to_alpha(image: Image.Image) -> Image.Image:
    rgba = clear_transparent_rgb(image)
    box = rgba.getchannel("A").getbbox()
    if box is None:
        raise ValueError("The bell asset is empty")
    return rgba.crop(box)


def cell(atlas: Image.Image, row: int, column: int) -> Image.Image:
    return atlas.crop(
        (
            column * CELL_W,
            row * CELL_H,
            (column + 1) * CELL_W,
            (row + 1) * CELL_H,
        )
    ).convert("RGBA")


def _components(mask: np.ndarray, minimum_pixels: int = 4) -> list[dict[str, object]]:
    seen = np.zeros_like(mask, dtype=bool)
    components: list[dict[str, object]] = []
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
        if len(points) < minimum_pixels:
            continue
        ys = [point[0] for point in points]
        xs = [point[1] for point in points]
        components.append(
            {
                "area": len(points),
                "bbox": (min(xs), min(ys), max(xs) + 1, max(ys) + 1),
            }
        )
    return components


def detect_bell_body(frame: Image.Image, row: int) -> tuple[float, float] | None:
    """Locate the warm-gold interior of the existing chest bell."""
    array = np.array(frame.convert("RGBA")).astype(np.int16)
    red, green, blue, alpha = (array[:, :, channel] for channel in range(4))
    yy, xx = np.mgrid[0:CELL_H, 0:CELL_W]
    search = (xx >= 45) & (xx <= 147) & (yy >= 125) & (yy <= 190)
    gold = (
        search
        & (alpha > 64)
        & (red > 145)
        & (green > 88)
        & (blue < 135)
        & (red > green * 1.03)
    )

    candidates: list[tuple[float, tuple[float, float]]] = []
    expected_y = ROW_EXPECTED_Y[row]
    for component in _components(gold):
        left, top, right, bottom = component["bbox"]
        width = right - left
        height = bottom - top
        area = int(component["area"])
        if not (4 <= width <= 26 and 4 <= height <= 26):
            continue
        center_x = (left + right) / 2
        center_y = (top + bottom) / 2
        if not (68 <= center_x <= 122 and 137 <= center_y <= 183):
            continue
        score = (
            area * 2
            + min(width, height) * 12
            - abs(width - height) * 7
            - abs(center_x - 96) * 1.4
            - abs(center_y - expected_y)
        )
        candidates.append((score, (center_x, center_y)))
    if not candidates:
        return None
    return max(candidates, key=lambda candidate: candidate[0])[1]


def resolve_row_anchors(atlas: Image.Image, row: int) -> list[tuple[float, float] | None]:
    frames = [cell(atlas, row, column) for column in range(COLS)]
    nonempty = [frame.getchannel("A").getbbox() is not None for frame in frames]
    anchors = [detect_bell_body(frame, row) if present else None for frame, present in zip(frames, nonempty)]

    known = [index for index, anchor in enumerate(anchors) if anchor is not None]
    for index, present in enumerate(nonempty):
        if not present or anchors[index] is not None:
            continue
        left = max((candidate for candidate in known if candidate < index), default=None)
        right = min((candidate for candidate in known if candidate > index), default=None)
        if left is not None and right is not None:
            amount = (index - left) / (right - left)
            lx, ly = anchors[left]
            rx, ry = anchors[right]
            anchors[index] = (lx + (rx - lx) * amount, ly + (ry - ly) * amount)
        elif left is not None:
            anchors[index] = anchors[left]
        elif right is not None:
            anchors[index] = anchors[right]
        else:
            anchors[index] = (96.0, float(ROW_EXPECTED_Y[row]))
    return anchors


def fit_bell(asset: Image.Image, width: int) -> Image.Image:
    source = trim_to_alpha(asset)
    height = max(1, round(source.height * width / source.width))
    return clear_transparent_rgb(source.resize((width, height), Image.Resampling.LANCZOS))


def erase_old_bell(source: Image.Image, anchor: tuple[float, float], row: int) -> Image.Image:
    """Restore the dark outfit beneath the old bell before compositing the new one."""
    array = np.array(source.convert("RGBA"))
    center_x, center_y = anchor
    left = max(0, round(center_x - 22))
    top = max(0, round(center_y - 22))
    right = min(CELL_W, round(center_x + 22))
    bottom = min(CELL_H, round(center_y + 22))
    sample = array[top:bottom, left:right]
    dark = (
        (sample[:, :, 3] > 200)
        & (sample[:, :, 0] < 70)
        & (sample[:, :, 1] < 70)
        & (sample[:, :, 2] < 70)
    )
    if np.any(dark):
        shirt_rgb = tuple(int(value) for value in np.median(sample[:, :, :3][dark], axis=0))
    else:
        shirt_rgb = (12, 14, 14)

    restored = source.copy().convert("RGBA")
    draw = ImageDraw.Draw(restored)
    radius_x = ROW_BELL_WIDTH[row] * 0.52
    radius_y = ROW_BELL_WIDTH[row] * 0.58
    draw.ellipse(
        (
            round(center_x - radius_x),
            round(center_y - radius_y),
            round(center_x + radius_x),
            round(center_y + radius_y),
        ),
        fill=shirt_rgb + (255,),
    )
    return restored


def foreground_mask(
    source: Image.Image,
    row: int,
    column: int,
    placement: tuple[int, int, int, int],
    empty_hand_pose: Image.Image,
) -> Image.Image:
    """Keep hands, the chameleon, transformation light and pistol above the bell."""
    array = np.array(source.convert("RGBA")).astype(np.int16)
    red, green, blue, alpha = (array[:, :, channel] for channel in range(4))

    green_subject = (alpha > 40) & (green > 70) & (green > red + 12) & (green > blue + 8)
    skin = (
        (alpha > 40)
        & (red > 155)
        & (green > 78)
        & (blue > 90)
        & (red > green + 5)
        & (green > blue + 4)
        # Peach skin retains substantially more blue than the old yellow bell.
        # A looser ratio caused the old bell's gold fill to be classified as
        # skin; dilation then pulled its black center slit back over the new,
        # otherwise seamless bell asset.
        & (blue > green * 0.75)
    )
    colorful_glow = (
        (alpha > 40)
        & (
            ((blue > 145) & (blue > red + 12))
            # Require a genuinely magenta/purple cast. The previous broad red
            # branch also matched the warm-gold bell and restored its old slit.
            | ((red > 165) & (blue > 115) & (red > green + 20) & (blue > green + 5))
        )
    )
    preserve = green_subject | skin | colorful_glow

    # Review cells 1-5 place a luminous transformation or the finished pistol
    # across the chest. Preserve the changed overlay relative to the clean hand
    # pose so the new bell stays behind it.
    if row == 8 and 1 <= column <= 5:
        base = np.array(empty_hand_pose.convert("RGBA")).astype(np.int16)
        color_difference = np.max(np.abs(array[:, :, :3] - base[:, :, :3]), axis=2)
        yy, xx = np.mgrid[0:CELL_H, 0:CELL_W]
        transform_region = (xx >= 24) & (xx <= 174) & (yy >= 94) & (yy <= 176)
        preserve |= (color_difference > 28) & transform_region & ((alpha > 24) | (base[:, :, 3] > 24))

    preserve_image = Image.fromarray((preserve.astype(np.uint8) * 255), "L").filter(ImageFilter.MaxFilter(5))

    left, top, right, bottom = placement
    envelope = Image.new("L", (CELL_W, CELL_H), 0)
    ImageDraw.Draw(envelope).rectangle((left - 2, top - 2, right + 2, bottom + 2), fill=255)
    return Image.fromarray(
        np.minimum(np.array(preserve_image), np.array(envelope)).astype(np.uint8),
        "L",
    )


def compose_frame(
    source: Image.Image,
    bell_asset: Image.Image,
    anchor: tuple[float, float],
    row: int,
    column: int,
    empty_hand_pose: Image.Image,
) -> tuple[Image.Image, dict[str, object]]:
    bell = fit_bell(bell_asset, ROW_BELL_WIDTH[row])
    center_x, center_y = anchor
    left = round(center_x - bell.width * 0.5)
    top = round(center_y - bell.height * BELL_BODY_CENTER_Y)
    placement = (left, top, left + bell.width, top + bell.height)

    result = erase_old_bell(source, anchor, row)
    result.alpha_composite(bell, (left, top))
    preserve = foreground_mask(source, row, column, placement, empty_hand_pose)
    result = Image.composite(source, result, preserve)
    result = clear_transparent_rgb(result)
    return result, {
        "row": row,
        "column": column,
        "anchor": [round(center_x, 2), round(center_y, 2)],
        "placement": list(placement),
        "preserved_foreground_pixels": int(np.count_nonzero(np.array(preserve))),
    }


def repair_atlas(
    atlas: Image.Image,
    bell_asset: Image.Image,
    empty_hand_pose: Image.Image,
) -> tuple[Image.Image, list[dict[str, object]], list[tuple[Image.Image, Image.Image, str]]]:
    source = atlas.convert("RGBA")
    if source.size != (CELL_W * COLS, CELL_H * ROWS):
        raise ValueError(f"Expected a 1536x2288 v2 atlas, received {source.size}")
    if empty_hand_pose.size != (CELL_W, CELL_H):
        raise ValueError(f"Expected a 192x208 empty-hand pose, received {empty_hand_pose.size}")

    repaired = source.copy()
    records: list[dict[str, object]] = []
    qa_pairs: list[tuple[Image.Image, Image.Image, str]] = []
    qa_targets = {(0, 0), (1, 0), (3, 0), (5, 3), (7, 5), (8, 0), (8, 3), (8, 5), (9, 0), (10, 0)}

    for row in range(ROWS):
        anchors = resolve_row_anchors(source, row)
        for column, anchor in enumerate(anchors):
            if anchor is None:
                continue
            before = cell(source, row, column)
            after, record = compose_frame(before, bell_asset, anchor, row, column, empty_hand_pose)
            repaired.paste(after, (column * CELL_W, row * CELL_H))
            records.append(record)
            if (row, column) in qa_targets:
                qa_pairs.append((before, after, f"r{row}c{column}"))
    return clear_transparent_rgb(repaired), records, qa_pairs


def make_qa_sheet(pairs: list[tuple[Image.Image, Image.Image, str]], output: Path) -> None:
    scale = 2
    label_height = 24
    columns = 4
    tiles: list[tuple[Image.Image, str]] = []
    for before, after, label in pairs:
        tiles.extend(((before, f"{label} before"), (after, f"{label} after")))
    rows = (len(tiles) + columns - 1) // columns
    canvas = Image.new(
        "RGBA",
        (columns * CELL_W * scale, rows * (CELL_H * scale + label_height)),
        (36, 36, 36, 255),
    )
    draw = ImageDraw.Draw(canvas)
    for index, (frame, label) in enumerate(tiles):
        x = (index % columns) * CELL_W * scale
        y = (index // columns) * (CELL_H * scale + label_height)
        enlarged = frame.resize((CELL_W * scale, CELL_H * scale), Image.Resampling.NEAREST)
        canvas.alpha_composite(enlarged, (x, y + label_height))
        draw.text((x + 8, y + 6), label, fill=(255, 255, 255, 255))
    output.parent.mkdir(parents=True, exist_ok=True)
    canvas.save(output)


def parse_args() -> argparse.Namespace:
    root = Path(__file__).resolve().parents[1]
    parser = argparse.ArgumentParser(description="Replace Reborn's chest bell with the reference-style cap and orb.")
    parser.add_argument("--source", type=Path, default=root / "final/spritesheet.webp")
    parser.add_argument("--bell", type=Path, default=root / "assets/reborn-bell-reference-style.png")
    parser.add_argument("--empty-hand-pose", type=Path, default=root / "assets/reborn-empty-hand-pose.png")
    parser.add_argument("--png-output", type=Path, default=root / "final/spritesheet.png")
    parser.add_argument("--webp-output", type=Path, default=root / "final/spritesheet.webp")
    parser.add_argument("--qa-output", type=Path, default=root / "qa/bell-style-repair.png")
    parser.add_argument("--report-output", type=Path, default=root / "qa/bell-style-repair.json")
    return parser.parse_args()


def main() -> None:
    args = parse_args()
    source = Image.open(args.source).convert("RGBA")
    bell_asset = Image.open(args.bell).convert("RGBA")
    empty_hand_pose = Image.open(args.empty_hand_pose).convert("RGBA")
    repaired, records, qa_pairs = repair_atlas(source, bell_asset, empty_hand_pose)

    args.png_output.parent.mkdir(parents=True, exist_ok=True)
    args.webp_output.parent.mkdir(parents=True, exist_ok=True)
    repaired.save(args.png_output)
    repaired.save(args.webp_output, format="WEBP", lossless=True, quality=100, method=6, exact=True)
    make_qa_sheet(qa_pairs, args.qa_output)

    reloaded = Image.open(args.webp_output).convert("RGBA")
    exact_round_trip = np.array_equal(np.array(repaired), np.array(reloaded))
    report = {
        "ok": exact_round_trip and bool(records),
        "source": str(args.source),
        "bell": str(args.bell),
        "empty_hand_pose": str(args.empty_hand_pose),
        "png_output": str(args.png_output),
        "webp_output": str(args.webp_output),
        "size": list(repaired.size),
        "updated_cells": len(records),
        "placements": records,
        "lossless_round_trip_exact": exact_round_trip,
    }
    args.report_output.parent.mkdir(parents=True, exist_ok=True)
    args.report_output.write_text(json.dumps(report, indent=2, ensure_ascii=False) + "\n")
    if not report["ok"]:
        raise SystemExit(json.dumps(report, indent=2, ensure_ascii=False))


if __name__ == "__main__":
    main()
