"""Pixel comparison between two captures of the same viewpoint.

The missing half of visual regression. Without a diff, two screenshots across
two builds cannot be told apart, and "did this change break the look" has no
mechanical answer.

Deliberately not a similarity score: a single number cannot separate "the camera
moved two pixels" from "one button disappeared", and those are opposite
findings.
"""

from __future__ import annotations

import tempfile
import unittest
from pathlib import Path

from rqe.visual_compare import CompareError, NOISE_FLOOR, compare_images


def _image(path: Path, size=(64, 64), colour=(20, 30, 40), patch=None) -> Path:
    from PIL import Image

    image = Image.new("RGB", size, colour)
    if patch is not None:
        box, patch_colour = patch
        for y in range(box[1], box[3]):
            for x in range(box[0], box[2]):
                image.putpixel((x, y), patch_colour)
    image.save(path, "PNG")
    return path


class VisualCompareTests(unittest.TestCase):
    def setUp(self) -> None:
        self._temporary = tempfile.TemporaryDirectory()
        self.root = Path(self._temporary.name)

    def tearDown(self) -> None:
        self._temporary.cleanup()

    def test_identical_frames_report_no_change(self):
        first = _image(self.root / "a.png")
        second = _image(self.root / "b.png")
        result = compare_images(first, second)
        self.assertTrue(result["identical"])
        self.assertEqual(result["changedPixels"], 0)
        self.assertEqual(result["classification"], "identical")

    def test_a_localised_change_reports_where_it_is(self):
        """The bounding box is the point: 'something changed' is not actionable,
        'the top-left 16 pixels changed' is."""

        first = _image(self.root / "a.png")
        second = _image(self.root / "b.png", patch=((4, 6, 12, 14), (240, 20, 20)))
        result = compare_images(first, second)
        self.assertFalse(result["identical"])
        self.assertEqual(result["boundingBox"], [4, 6, 11, 13])
        self.assertEqual(result["changedPixels"], 8 * 8)

    def test_noise_below_the_floor_is_not_a_change(self):
        """Two frames differing only in encoding noise are identical to a
        viewer; reporting them as changed makes every comparison fail."""

        first = _image(self.root / "a.png", colour=(100, 100, 100))
        nudge = NOISE_FLOOR - 1
        second = _image(self.root / "b.png", colour=(100 + nudge, 100, 100))
        result = compare_images(first, second)
        self.assertTrue(result["identical"])

    def test_a_change_above_the_floor_is_counted(self):
        first = _image(self.root / "a.png", colour=(100, 100, 100))
        second = _image(self.root / "b.png", colour=(100 + NOISE_FLOOR + 5, 100, 100))
        result = compare_images(first, second)
        self.assertFalse(result["identical"])
        self.assertEqual(result["changedPixels"], result["totalPixels"])

    def test_a_whole_frame_change_is_classified_as_recomposed(self):
        first = _image(self.root / "a.png", colour=(10, 10, 10))
        second = _image(self.root / "b.png", colour=(240, 240, 240))
        self.assertEqual(compare_images(first, second)["classification"], "recomposed")

    def test_a_small_change_within_the_threshold_is_noise(self):
        first = _image(self.root / "a.png")
        second = _image(self.root / "b.png", patch=((0, 0, 4, 4), (250, 10, 10)))
        result = compare_images(first, second, threshold=0.05)
        self.assertTrue(result["withinThreshold"])
        self.assertEqual(result["classification"], "noise")

    def test_a_change_above_the_threshold_is_reported_as_changed(self):
        first = _image(self.root / "a.png")
        second = _image(self.root / "b.png", patch=((0, 0, 20, 20), (250, 10, 10)))
        result = compare_images(first, second, threshold=0.01)
        self.assertFalse(result["withinThreshold"])
        self.assertEqual(result["classification"], "changed")

    def test_different_sizes_are_incomparable_rather_than_resized(self):
        """Comparing a resized frame against a native one measures the
        resampler, not the change."""

        first = _image(self.root / "a.png", size=(64, 64))
        second = _image(self.root / "b.png", size=(48, 48))
        result = compare_images(first, second)
        self.assertFalse(result["dimensionsMatch"])
        self.assertEqual(result["classification"], "incomparable")

    def test_an_invalid_threshold_is_refused(self):
        first = _image(self.root / "a.png")
        second = _image(self.root / "b.png")
        with self.assertRaises(CompareError):
            compare_images(first, second, threshold=5)

    def test_the_summary_is_readable(self):
        first = _image(self.root / "a.png")
        second = _image(self.root / "b.png", patch=((4, 4, 10, 10), (250, 10, 10)))
        summary = compare_images(first, second)["summary"]
        self.assertIn("%", summary)
        self.assertIn("confined to", summary)


if __name__ == "__main__":
    unittest.main()
