import importlib.util
import unittest
from collections import deque
from pathlib import Path

import numpy as np
from PIL import Image, ImageChops


SCRIPT = Path(__file__).resolve().parents[1] / "scripts/build_reborn_transformation.py"
spec = importlib.util.spec_from_file_location("build_reborn_transformation", SCRIPT)
module = importlib.util.module_from_spec(spec)
assert spec.loader is not None
spec.loader.exec_module(module)


def row_frames(atlas: Image.Image, row: int) -> list[Image.Image]:
    return [
        atlas.crop(
            (
                col * module.CELL_W,
                row * module.CELL_H,
                (col + 1) * module.CELL_W,
                (row + 1) * module.CELL_H,
            )
        ).convert("RGBA")
        for col in range(module.COLS)
    ]


def largest_component_bbox(mask: np.ndarray):
    height, width = mask.shape
    seen = np.zeros_like(mask, dtype=bool)
    best = []
    for y, x in zip(*np.where(mask & ~seen)):
        queue = deque([(int(y), int(x))])
        seen[y, x] = True
        points = []
        while queue:
            cy, cx = queue.popleft()
            points.append((cy, cx))
            for dy, dx in ((-1, 0), (1, 0), (0, -1), (0, 1)):
                ny, nx = cy + dy, cx + dx
                if 0 <= ny < height and 0 <= nx < width and mask[ny, nx] and not seen[ny, nx]:
                    seen[ny, nx] = True
                    queue.append((ny, nx))
        if len(points) > len(best):
            best = points
    if not best:
        return None
    ys = [p[0] for p in best]
    xs = [p[1] for p in best]
    return min(xs), min(ys), max(xs) + 1, max(ys) + 1


def green_bbox(frame: Image.Image):
    arr = np.array(frame.convert("RGBA"))
    r, g, b, a = (arr[:, :, i].astype(np.int16) for i in range(4))
    green = (g > 90) & (g > r + 20) & (g > b + 15) & (a > 32)
    return largest_component_bbox(green)


def pistol_bbox(solid_frame: Image.Image, luminous_frame: Image.Image):
    solid = np.array(solid_frame.convert("RGBA")).astype(np.int16)
    luminous = np.array(luminous_frame.convert("RGBA")).astype(np.int16)
    difference = np.max(np.abs(solid[:, :, :3] - luminous[:, :, :3]), axis=2)
    visible = (solid[:, :, 3] > 32) | (luminous[:, :, 3] > 32)
    yy, xx = np.mgrid[0 : solid.shape[0], 0 : solid.shape[1]]
    weapon_change = (
        (difference > 30)
        & visible
        & (yy >= 88)
        & (yy <= 175)
        & (xx >= 35)
        & (xx <= 170)
    )
    return largest_component_bbox(weapon_change)


LEGACY_ASSETS_AVAILABLE = all(
    path.is_file()
    for path in (module.HAND_BASE, module.TRANSITION_OVERLAYS, module.POSE_SOURCE)
)


@unittest.skipUnless(LEGACY_ASSETS_AVAILABLE, "legacy transformation source assets are not part of this repository")
class DualStateSequenceTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.atlas = Image.open(module.SOURCE_ATLAS).convert("RGBA")
        cls.idle_source = row_frames(cls.atlas, 0)
        cls.running_source = row_frames(cls.atlas, 7)
        cls.review_source = row_frames(cls.atlas, 8)

    def test_idle_tail_tip_has_subtle_loop_without_body_changes(self):
        idle_builder = getattr(module, "make_idle_frames", None)
        self.assertTrue(callable(idle_builder), "make_idle_frames is missing")
        frames = idle_builder(self.idle_source)
        self.assertEqual(8, len(frames))
        for frame in frames[:7]:
            self.assertIsNotNone(frame.getchannel("A").getbbox())
        self.assertIsNone(frames[7].getchannel("A").getbbox())

        yy, xx = np.mgrid[0 : module.CELL_H, 0 : module.CELL_W]
        tip_region = (yy < 42) & (xx >= 120)
        centers = []
        for index, frame in enumerate(frames[:6]):
            arr = np.array(frame).astype(np.int16)
            r, g, b, a = (arr[:, :, i] for i in range(4))
            tail = (g > 70) & (g > r + 15) & (g > b + 10) & (a > 32) & tip_region
            ys, xs = np.where(tail)
            self.assertGreater(len(xs), 80)
            centers.append((float(xs.mean()), float(ys.mean())))

            source = np.array(self.idle_source[index]).astype(np.int16)
            changed = np.max(np.abs(arr - source), axis=2) > 0
            self.assertEqual(0, int((changed & ~tip_region).sum()))

        x_values = [center[0] for center in centers]
        y_values = [center[1] for center in centers]
        self.assertGreaterEqual(max(x_values) - min(x_values), 4.0)
        self.assertLessEqual(max(x_values) - min(x_values), 8.0)
        self.assertLessEqual(max(y_values) - min(y_values), 3.0)
        for left, right in zip(x_values, x_values[1:]):
            self.assertLessEqual(abs(right - left), 4.0)

        self.assertIsNone(ImageChops.difference(frames[6], self.idle_source[6]).getbbox())
        self.assertIsNone(ImageChops.difference(frames[7], self.idle_source[7]).getbbox())

        composer = getattr(module, "compose_all_rows", None)
        self.assertTrue(callable(composer), "compose_all_rows is missing")
        final = composer(self.atlas, frames, self.running_source, self.review_source)
        for row in [1, 2, 3, 4, 5, 6, 9, 10]:
            source_row = np.array(
                self.atlas.crop((0, row * module.CELL_H, module.COLS * module.CELL_W, (row + 1) * module.CELL_H))
            )
            final_row = np.array(
                final.crop((0, row * module.CELL_H, module.COLS * module.CELL_W, (row + 1) * module.CELL_H))
            )
            self.assertTrue(np.array_equal(source_row, final_row), f"row {row} changed")
        for column in (6, 7):
            self.assertIsNone(ImageChops.difference(row_frames(final, 0)[column], self.idle_source[column]).getbbox())

    def builders(self):
        running_builder = getattr(module, "make_running_frames", None)
        review_builder = getattr(module, "make_review_frames", None)
        self.assertTrue(callable(running_builder), "make_running_frames is missing")
        self.assertTrue(callable(review_builder), "make_review_frames is missing")
        return running_builder, review_builder

    def test_running_has_six_step_downward_crawl(self):
        running_builder, _ = self.builders()
        frames = running_builder(self.running_source)
        self.assertEqual(8, len(frames))
        for frame in frames[:6]:
            self.assertIsNotNone(frame.getchannel("A").getbbox())
        for frame in frames[6:]:
            self.assertIsNone(frame.getchannel("A").getbbox())

        boxes = [green_bbox(frame) for frame in frames[:6]]
        self.assertTrue(all(boxes), boxes)
        centers = [((box[0] + box[2]) / 2, (box[1] + box[3]) / 2) for box in boxes]
        ys = [center[1] for center in centers]
        self.assertGreaterEqual(ys[-1] - ys[0], 45)
        for previous, current in zip(ys, ys[1:]):
            self.assertGreaterEqual(current, previous - 2)
            self.assertLessEqual(current - previous, 38)
        self.assertLessEqual(centers[-1][0], 85)
        self.assertGreaterEqual(centers[-1][1], 120)
        self.assertLessEqual(centers[-1][1], 145)
        final_width = boxes[-1][2] - boxes[-1][0]
        final_height = boxes[-1][3] - boxes[-1][1]
        self.assertGreaterEqual(final_width, final_height * 0.9)
        for left, right in zip(frames[:5], frames[1:6]):
            self.assertIsNotNone(ImageChops.difference(left, right).getbbox())

    def test_review_has_scaled_transformation_and_integrated_grip(self):
        _, review_builder = self.builders()
        frames = review_builder(self.review_source)
        self.assertEqual(8, len(frames))
        for frame in frames[:6]:
            self.assertIsNotNone(frame.getchannel("A").getbbox())
        for frame in frames[6:]:
            self.assertIsNone(frame.getchannel("A").getbbox())
        for left, right in zip(frames[:5], frames[1:6]):
            self.assertIsNotNone(ImageChops.difference(left, right).getbbox())

        hand_chameleon = green_bbox(frames[0])
        self.assertIsNotNone(hand_chameleon)
        self.assertGreaterEqual(
            hand_chameleon[2] - hand_chameleon[0],
            (hand_chameleon[3] - hand_chameleon[1]) * 0.9,
        )

        loader = getattr(module, "load_registered_pose_sources", None)
        self.assertTrue(callable(loader), "load_registered_pose_sources is missing")
        empty_hand = loader()[0]
        character_box = empty_hand.getchannel("A").getbbox()
        gun_box = pistol_bbox(frames[5], frames[4])
        self.assertIsNotNone(character_box)
        self.assertIsNotNone(gun_box)
        ratio = (gun_box[2] - gun_box[0]) / (character_box[2] - character_box[0])
        self.assertGreaterEqual(ratio, 0.45)
        self.assertLessEqual(ratio, 0.50)
        self.assertGreaterEqual(gun_box[1], 88)

        fourth_arr = np.array(frames[3]).astype(np.int16)
        empty_arr = np.array(empty_hand).astype(np.int16)
        fourth_changed = np.max(np.abs(fourth_arr[:, :, :3] - empty_arr[:, :, :3]), axis=2) > 24
        fourth_box = largest_component_bbox(fourth_changed)
        self.assertIsNotNone(fourth_box)
        fourth_width = fourth_box[2] - fourth_box[0]
        fourth_height = fourth_box[3] - fourth_box[1]
        final_width = gun_box[2] - gun_box[0]
        final_height = gun_box[3] - gun_box[1]
        self.assertGreaterEqual(fourth_width, final_width * 0.75)
        self.assertLessEqual(fourth_width, final_width * 0.92)
        self.assertLessEqual(fourth_height, final_height)

        grip = getattr(module, "measure_grip_relationship", None)
        self.assertTrue(callable(grip), "measure_grip_relationship is missing")
        metrics = grip(frames[5])
        self.assertTrue(metrics["hand_touches_grip"], metrics)
        self.assertTrue(metrics["trigger_guard_readable"], metrics)

        eye_mask = np.zeros((module.CELL_H, module.CELL_W), dtype=bool)
        eye_mask[88:126, 48:76] = True
        eye_mask[88:126, 106:134] = True
        for index in (1, 2, 3):
            frame_arr = np.array(frames[index]).astype(np.int16)
            changed = np.max(np.abs(frame_arr[:, :, :3] - empty_arr[:, :, :3]), axis=2) > 24
            self.assertEqual(0, int((changed & eye_mask).sum()), f"review frame {index} covers an eye")

    def test_composition_preserves_all_other_rows(self):
        running_builder, review_builder = self.builders()
        composer = getattr(module, "compose_rows", None)
        self.assertTrue(callable(composer), "compose_rows is missing")
        final = composer(
            self.atlas,
            running_builder(self.running_source),
            review_builder(self.review_source),
        )
        for row in [0, 1, 2, 3, 4, 5, 6, 9, 10]:
            source = np.array(
                self.atlas.crop((0, row * module.CELL_H, module.COLS * module.CELL_W, (row + 1) * module.CELL_H))
            )
            actual = np.array(
                final.crop((0, row * module.CELL_H, module.COLS * module.CELL_W, (row + 1) * module.CELL_H))
            )
            self.assertTrue(np.array_equal(source, actual), f"row {row} changed")


if __name__ == "__main__":
    unittest.main()
