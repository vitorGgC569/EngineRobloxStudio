"""The measurements that stand in for looking at the screen.

Synthetic frames, so a threshold change fails a test rather than drifting
quietly. Each case is one of the defects that shipped past a clean doctor,
clean type checks and sixteen green scenarios.
"""

from __future__ import annotations

import tempfile
import unittest
from pathlib import Path

import numpy as np
from PIL import Image

from rqe.image_metrics import assess, measure
from rqe.pixel_vision import PixelMetricsProvider
from rqe.visual_review import ReviewImage, ReviewRequest, _validate_provider_result


def frame(pixels: np.ndarray, directory: Path, name: str) -> Path:
    path = directory / f"{name}.png"
    Image.fromarray(pixels.astype(np.uint8), "RGB").save(path)
    return path


def flat(value: int, size: int = 96) -> np.ndarray:
    return np.full((size, size, 3), value, dtype=np.uint8)


class MetricsCase(unittest.TestCase):
    def setUp(self) -> None:
        self._temp = tempfile.TemporaryDirectory()
        self.dir = Path(self._temp.name)

    def tearDown(self) -> None:
        self._temp.cleanup()

    # ------------------------------------------------------------- exposure
    def test_a_blown_out_frame_is_refused(self) -> None:
        """The player-as-white-blur defect: bloom plus overlapping lights."""
        pixels = flat(20)
        pixels[20:80, 20:80] = 255
        verdict = assess("exposure", measure(frame(pixels, self.dir, "blown")))
        self.assertLessEqual(verdict.grade, 2)
        self.assertIn("clipped", verdict.rationale)

    def test_an_all_black_frame_is_refused(self) -> None:
        """A blank capture. Two were sitting in this repo's capture directory."""
        verdict = assess("exposure", measure(frame(flat(0), self.dir, "black")))
        self.assertLessEqual(verdict.grade, 2)
        self.assertIn("crushed", verdict.rationale)

    def test_a_well_exposed_frame_passes(self) -> None:
        rng = np.random.default_rng(7)
        pixels = rng.integers(40, 210, (96, 96, 3), dtype=np.uint8)
        verdict = assess("exposure", measure(frame(pixels, self.dir, "ok")))
        self.assertGreaterEqual(verdict.grade, 4)

    # ------------------------------------------------------------- lighting
    def test_ground_brighter_than_the_lamps_is_refused(self) -> None:
        """The exact defect: a game about darkness with a pale sand floor.

        Bright ground fills the lower band; the only "lights" are barely
        brighter than it, so nothing reads as a source.
        """
        pixels = flat(30)
        pixels[64:, :] = 200          # ground, bottom third
        pixels[10:14, 10:14] = 210    # a "lamp" that barely out-shines it
        verdict = assess("lighting", measure(frame(pixels, self.dir, "pale")))
        self.assertLessEqual(verdict.grade, 2)

    def test_lights_well_above_the_ground_pass(self) -> None:
        pixels = flat(20)
        pixels[64:, :] = 40           # dark ground
        pixels[10:30, 10:30] = 250    # real light sources
        verdict = assess("lighting", measure(frame(pixels, self.dir, "lit")))
        self.assertGreaterEqual(verdict.grade, 4)

    # -------------------------------------------------------------- density
    def test_an_empty_plane_is_refused(self) -> None:
        verdict = assess("detail density", measure(frame(flat(120), self.dir, "empty")))
        self.assertEqual(verdict.grade, 1)

    def test_a_populated_frame_passes(self) -> None:
        rng = np.random.default_rng(11)
        pixels = rng.integers(0, 255, (96, 96, 3), dtype=np.uint8)
        verdict = assess("detail density", measure(frame(pixels, self.dir, "busy")))
        self.assertGreaterEqual(verdict.grade, 4)

    # --------------------------------------------------------------- colour
    def test_a_greyscale_world_reports_no_hues(self) -> None:
        rng = np.random.default_rng(3)
        grey = rng.integers(40, 200, (96, 96, 1), dtype=np.uint8).repeat(3, axis=2)
        verdict = assess("colour palette", measure(frame(grey, self.dir, "grey")))
        self.assertLessEqual(verdict.grade, 2)

    # -------------------------------------------------------- what it won't do
    def test_an_unmeasurable_criterion_is_not_graded(self) -> None:
        """The honesty rule. Composition is not arithmetic, so it is not graded."""
        self.assertIsNone(assess("composition", measure(frame(flat(120), self.dir, "x"))))


class ProviderCase(unittest.TestCase):
    """The provider must satisfy the gate's contract, or it is decoration."""

    def setUp(self) -> None:
        self._temp = tempfile.TemporaryDirectory()
        self.dir = Path(self._temp.name)
        rng = np.random.default_rng(5)
        self.shots = ["front", "aerial"]
        self.images = []
        for name in self.shots:
            pixels = rng.integers(30, 220, (96, 96, 3), dtype=np.uint8)
            path = frame(pixels, self.dir, name)
            self.images.append(ReviewImage(
                id=name, mime_type="image/png", data=path.read_bytes(),
                sha256="0" * 64, metadata={"path": path.name}))

    def tearDown(self) -> None:
        self._temp.cleanup()

    def request(self, rubric: dict) -> ReviewRequest:
        return ReviewRequest(
            run_id="r", build_hash="b", place_hash="p", spec_hash="s",
            capture_manifest_sha256="c", prompt="x", prompt_hash="h",
            rubric_by_viewpoint=rubric, images=tuple(self.images))

    def test_the_gate_accepts_what_the_provider_returns(self) -> None:
        req = self.request({
            "front": ("exposure", "lighting"),
            "aerial": ("contrast", "detail density"),
        })
        raw = PixelMetricsProvider(self.dir).review(req)
        assessments, findings, average, _ = _validate_provider_result(raw, req)
        self.assertEqual(len(assessments), 2)
        self.assertGreaterEqual(average, 0)

    def test_unmeasurable_criteria_are_declared_rather_than_graded(self) -> None:
        """A provider that quietly grades what it did not examine is worse
        than no provider: it manufactures confidence."""
        req = self.request({"front": ("composition",), "aerial": ("exposure",)})
        raw = PixelMetricsProvider(self.dir).review(req)
        _validate_provider_result(raw, req)

        composition = raw["assessments"][0]["rubric"][0]
        self.assertEqual(composition["grade"], 3)
        self.assertIn("not assessed", composition["rationale"])
        self.assertTrue(any("not visually assessed" in f["finding"]
                            for f in raw["findings"]))

    def test_a_missing_capture_is_an_error_not_a_pass(self) -> None:
        req = self.request({"front": ("exposure",), "nowhere": ("exposure",)})
        with self.assertRaises(Exception):
            PixelMetricsProvider(self.dir).review(req)

    def test_low_grades_raise_findings(self) -> None:
        black = frame(flat(0), self.dir, "front")
        self.images[0] = ReviewImage(id="front", mime_type="image/png",
                                     data=black.read_bytes(), sha256="0" * 64,
                                     metadata={"path": black.name})
        req = self.request({"front": ("exposure",), "aerial": ("exposure",)})
        raw = PixelMetricsProvider(self.dir).review(req)
        _validate_provider_result(raw, req)
        self.assertTrue(any(f["location"] == "front" and f["severity"] != "info"
                            for f in raw["findings"]))


if __name__ == "__main__":
    unittest.main()
