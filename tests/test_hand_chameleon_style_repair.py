import importlib.util
import unittest
from pathlib import Path

import numpy as np
from PIL import Image


ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts/repair_hand_chameleon_style.py"
spec = importlib.util.spec_from_file_location("repair_hand_chameleon_style", SCRIPT)
module = importlib.util.module_from_spec(spec)
assert spec.loader is not None
spec.loader.exec_module(module)


class HandChameleonStyleRepairTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.atlas = Image.open(ROOT / "final/spritesheet.webp").convert("RGBA")
        cls.base_pose = Image.open(ROOT / "assets/reborn-empty-hand-pose.png").convert("RGBA")
        cls.chameleon = Image.open(ROOT / "assets/hand-chameleon-reference-style.png").convert("RGBA")

    def test_reference_style_pose_has_two_readable_eyes(self):
        pose = module.compose_hand_pose(self.base_pose, self.chameleon)
        self.assertEqual(2, len(module.eye_components(pose)))
        self.assertIsNotNone(pose.getchannel("A").getbbox())

    def test_both_target_cells_receive_the_same_pose(self):
        repaired, records, _ = module.repair_atlas(self.atlas, self.base_pose, self.chameleon)
        self.assertEqual([(7, 5), (8, 0)], [(record["row"], record["column"]) for record in records])
        running = np.array(module.cell(repaired, 7, 5))
        review = np.array(module.cell(repaired, 8, 0))
        self.assertTrue(np.array_equal(running, review))

    def test_only_the_two_expected_cells_change(self):
        repaired, _, _ = module.repair_atlas(self.atlas, self.base_pose, self.chameleon)
        for row in range(module.ROWS):
            for column in range(module.COLS):
                if (row, column) in module.TARGET_CELLS:
                    continue
                before = np.array(module.cell(self.atlas, row, column))
                after = np.array(module.cell(repaired, row, column))
                self.assertTrue(np.array_equal(before, after), (row, column))


if __name__ == "__main__":
    unittest.main()
