import importlib.util
import unittest
from pathlib import Path

import numpy as np
from PIL import Image


ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts/repair_bell_style.py"
spec = importlib.util.spec_from_file_location("repair_bell_style", SCRIPT)
module = importlib.util.module_from_spec(spec)
assert spec.loader is not None
spec.loader.exec_module(module)


class BellStyleRepairTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.atlas = Image.open(ROOT / "final/spritesheet.webp").convert("RGBA")
        cls.bell = Image.open(ROOT / "assets/reborn-bell-reference-style.png").convert("RGBA")
        cls.empty_hand = Image.open(ROOT / "assets/reborn-empty-hand-pose.png").convert("RGBA")

    def test_bell_asset_is_transparent_and_has_deep_gold_center(self):
        alpha = np.array(self.bell.getchannel("A"))
        self.assertEqual(0, int(alpha[0, 0]))
        self.assertGreater(int((alpha > 240).sum()), 100_000)

        cropped = module.trim_to_alpha(self.bell)
        center = np.array(cropped)[round(cropped.height * 0.68), round(cropped.width * 0.50), :3]
        self.assertGreater(int(center[0]), 190)
        self.assertGreater(int(center[1]), 120)
        self.assertLess(int(center[2]), 95)

    def test_all_nonempty_cells_receive_a_bell(self):
        repaired, records, _ = module.repair_atlas(self.atlas, self.bell, self.empty_hand)
        nonempty = sum(
            module.cell(self.atlas, row, column).getchannel("A").getbbox() is not None
            for row in range(module.ROWS)
            for column in range(module.COLS)
        )
        self.assertEqual(nonempty, len(records))
        self.assertEqual(self.atlas.size, repaired.size)

    def test_blank_cells_remain_exactly_blank(self):
        repaired, _, _ = module.repair_atlas(self.atlas, self.bell, self.empty_hand)
        for row in range(module.ROWS):
            for column in range(module.COLS):
                before = module.cell(self.atlas, row, column)
                if before.getchannel("A").getbbox() is not None:
                    continue
                after = module.cell(repaired, row, column)
                self.assertTrue(np.array_equal(np.array(before), np.array(after)), (row, column))

    def test_hand_chameleon_foreground_is_preserved(self):
        repaired, _, _ = module.repair_atlas(self.atlas, self.bell, self.empty_hand)
        for row, column in ((7, 5), (8, 0)):
            before = np.array(module.cell(self.atlas, row, column)).astype(np.int16)
            after = np.array(module.cell(repaired, row, column)).astype(np.int16)
            red, green, blue, alpha = (before[:, :, channel] for channel in range(4))
            lizard = (alpha > 40) & (green > 70) & (green > red + 12) & (green > blue + 8)
            self.assertGreater(int(lizard.sum()), 300)
            self.assertTrue(np.array_equal(before[lizard], after[lizard]))

    def test_old_bell_slit_does_not_remain_below_replacement(self):
        repaired, records, _ = module.repair_atlas(self.atlas, self.bell, self.empty_hand)
        record = next(record for record in records if record["row"] == 0 and record["column"] == 0)
        center_x, center_y = (round(value) for value in record["anchor"])
        frame = np.array(module.cell(repaired, 0, 0))
        # The old bell extended below the smaller replacement. That area should
        # now be restored to the dark outfit instead of retaining its black slit
        # and gold rim fragments.
        below = frame[center_y + 11 : center_y + 16, center_x - 4 : center_x + 5, :3]
        dark = (below[:, :, 0] < 80) & (below[:, :, 1] < 80) & (below[:, :, 2] < 80)
        self.assertGreater(int(dark.sum()), 10)

        smooth_center = frame[center_y - 9 : center_y + 8, center_x - 2 : center_x + 3, :3]
        internal_dark = (
            (smooth_center[:, :, 0] < 80)
            & (smooth_center[:, :, 1] < 80)
            & (smooth_center[:, :, 2] < 80)
        )
        self.assertEqual(0, int(internal_dark.sum()))

    def test_seated_hands_remain_in_front_of_smooth_bell(self):
        repaired, records, _ = module.repair_atlas(self.atlas, self.bell, self.empty_hand)
        before = np.array(module.cell(self.atlas, 5, 3)).astype(np.int16)
        after = np.array(module.cell(repaired, 5, 3)).astype(np.int16)
        record = next(record for record in records if record["row"] == 5 and record["column"] == 3)
        red, green, blue, alpha = (before[:, :, channel] for channel in range(4))
        skin = (
            (alpha > 40)
            & (red > 155)
            & (green > 78)
            & (blue > 90)
            & (red > green + 5)
            & (green > blue + 4)
            & (blue > green * 0.75)
        )
        left, top, right, bottom = record["placement"]
        envelope = np.zeros((module.CELL_H, module.CELL_W), dtype=bool)
        envelope[max(0, top - 2) : min(module.CELL_H, bottom + 3), max(0, left - 2) : min(module.CELL_W, right + 3)] = True
        visible_hands = skin & envelope
        self.assertGreater(int(visible_hands.sum()), 12)
        self.assertTrue(np.array_equal(before[visible_hands], after[visible_hands]))

    def test_transformation_and_pistol_remain_in_front(self):
        repaired, records, _ = module.repair_atlas(self.atlas, self.bell, self.empty_hand)
        for column in range(1, 6):
            before_image = module.cell(self.atlas, 8, column)
            before = np.array(before_image).astype(np.int16)
            after = np.array(module.cell(repaired, 8, column)).astype(np.int16)
            record = next(
                record for record in records if record["row"] == 8 and record["column"] == column
            )
            foreground = np.array(
                module.foreground_mask(
                    before_image,
                    8,
                    column,
                    tuple(record["placement"]),
                    self.empty_hand,
                )
            ) > 0
            self.assertGreater(int(foreground.sum()), 200)
            self.assertTrue(np.array_equal(before[foreground], after[foreground]), column)


if __name__ == "__main__":
    unittest.main()
