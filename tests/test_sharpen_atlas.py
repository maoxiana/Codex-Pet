import importlib.util
import unittest
from pathlib import Path

import numpy as np
from PIL import Image


ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts/sharpen_atlas.py"
spec = importlib.util.spec_from_file_location("sharpen_atlas", SCRIPT)
module = importlib.util.module_from_spec(spec)
assert spec.loader is not None
spec.loader.exec_module(module)


class SharpenAtlasTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.atlas = Image.open(ROOT / "final/spritesheet.webp").convert("RGBA")
        cls.repaired, cls.report = module.repair_atlas(cls.atlas)

    def test_geometry_is_preserved(self):
        self.assertEqual((1536, 2288), self.repaired.size)
        self.assertEqual(self.atlas.size, self.repaired.size)

    def test_blank_cells_remain_identical(self):
        for row in range(module.ROWS):
            for column in range(module.COLS):
                box = (
                    column * module.CELL_W,
                    row * module.CELL_H,
                    (column + 1) * module.CELL_W,
                    (row + 1) * module.CELL_H,
                )
                before = self.atlas.crop(box)
                if before.getchannel("A").getbbox() is not None:
                    continue
                after = self.repaired.crop(box)
                self.assertTrue(np.array_equal(np.asarray(before), np.asarray(after)), (row, column))

    def test_transparency_never_expands(self):
        before = np.asarray(self.atlas)[:, :, 3]
        after = np.asarray(self.repaired)[:, :, 3]
        self.assertEqual(0, int(((before == 0) & (after > 0)).sum()))
        self.assertEqual(0, int(((before == 255) & (after < 255)).sum()))

    def test_partial_alpha_is_reduced_but_sprite_remains(self):
        self.assertLess(self.report["partial_alpha_after"], self.report["partial_alpha_before"])
        self.assertEqual(self.report["visible_pixels_before"], self.report["visible_pixels_after"])
        self.assertGreater(self.report["changed_pixels"], 1000)

    def test_all_nonempty_cells_stay_nonempty(self):
        for row in range(module.ROWS):
            for column in range(module.COLS):
                box = (
                    column * module.CELL_W,
                    row * module.CELL_H,
                    (column + 1) * module.CELL_W,
                    (row + 1) * module.CELL_H,
                )
                before = self.atlas.crop(box).getchannel("A").getbbox()
                after = self.repaired.crop(box).getchannel("A").getbbox()
                self.assertEqual(before is None, after is None, (row, column))


if __name__ == "__main__":
    unittest.main()
