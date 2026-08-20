"""The visual critic.

These tests are mostly about the properties that make a score worth trusting
rather than about the arithmetic. A critic that scores an asset it could not
read, or that grades the renderer's framing and calls it the asset, or that
approves the thing it was calibrated on because it was calibrated on it, is
worse than no critic: it produces confident numbers that survive review.

The synthetic frames here are built from primitives with known properties -- a
flat square has no interior detail by construction, a striped one has a lot --
so each assertion has a reason that does not depend on Blender being installed.
"""

from __future__ import annotations

import unittest
from pathlib import Path
from tempfile import TemporaryDirectory

from PIL import Image, ImageDraw

from rqe.geometry.critic import (
    APPROVAL_SCORE,
    CALIBRATION,
    EDGE_DENSITY_BAND,
    LUMINANCE_SPREAD_BAND,
    SILHOUETTE_SHAPE_BAND,
    CriticError,
    Critique,
    critique,
)


SIZE = 256


def _frame(draw_asset, *, path: Path) -> Path:
    """An RGBA render: transparent background, opaque asset."""

    image = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
    draw_asset(ImageDraw.Draw(image))
    image.save(path)
    return path


def _flat_square(colour=(150, 150, 150)):
    def draw(pen):
        pen.rectangle([70, 70, 186, 186], fill=colour + (255,))
    return draw


def _striped_square(colour=(150, 150, 150), stripe=(40, 40, 40)):
    """Same silhouette, same mean value, heavy interior detail."""

    def draw(pen):
        pen.rectangle([70, 70, 186, 186], fill=colour + (255,))
        for x in range(76, 186, 10):
            pen.rectangle([x, 76, x + 4, 180], fill=stripe + (255,))
    return draw


def _two_tone_square():
    """Same silhouette, no interior geometry, strong value separation."""

    def draw(pen):
        pen.rectangle([70, 70, 186, 128], fill=(28, 28, 30, 255))
        pen.rectangle([70, 128, 186, 186], fill=(232, 230, 226, 255))
    return draw


def _views(directory: Path, draw, names=("front", "back", "left", "right", "perspective")):
    return [_frame(draw, path=directory / f"{name}.png") for name in names]


class TestFailsClosed(unittest.TestCase):
    def test_no_renders_is_refused_rather_than_scored_zero(self):
        """Absence of evidence must not be expressible as a score.

        A zero is a verdict about the asset. "Nobody rendered it" is a verdict
        about the process, and collapsing the two lets an asset be approved by
        deleting the thing that would have judged it."""

        with self.assertRaises(CriticError) as caught:
            critique([])
        self.assertIn("absence of evidence is not a pass", str(caught.exception))

    def test_a_missing_file_is_not_silently_skipped_into_emptiness(self):
        with self.assertRaises(CriticError):
            critique([Path("does-not-exist-front.png")])

    def test_an_empty_frame_is_refused(self):
        """Scoring a frame with no asset in it would produce numbers about
        nothing, and they would look exactly like numbers about something."""

        with TemporaryDirectory() as directory:
            root = Path(directory)
            _frame(lambda pen: None, path=root / "front.png")
            with self.assertRaises(CriticError) as caught:
                critique([root / "front.png"])
            self.assertIn("outside", str(caught.exception))


class TestMeasuresTheAssetNotTheHarness(unittest.TestCase):
    def test_interior_detail_separates_two_identical_silhouettes(self):
        """The whole point of the detail axis: same outline, different work."""

        with TemporaryDirectory() as directory:
            root = Path(directory)
            flat = root / "flat"
            striped = root / "striped"
            flat.mkdir()
            striped.mkdir()
            plain = critique(_views(flat, _flat_square()))
            detailed = critique(_views(striped, _striped_square()))

        self.assertGreater(
            detailed.scores["detail_distribution"],
            plain.scores["detail_distribution"],
        )

    def test_a_dark_asset_is_not_penalised_for_being_dark(self):
        """A fixed edge threshold measures how light the materials are rather
        than how much was modelled, which fails every asset with a dark
        palette."""

        with TemporaryDirectory() as directory:
            root = Path(directory)
            light_dir = root / "light"
            dark_dir = root / "dark"
            light_dir.mkdir()
            dark_dir.mkdir()
            light = critique(_views(light_dir, _striped_square((200, 200, 200), (120, 120, 120))))
            dark = critique(_views(dark_dir, _striped_square((60, 60, 60), (30, 30, 30))))

        # Same geometry, palette shifted. Within a wide tolerance rather than
        # exact: local contrast is not perfectly scale-free, and claiming it is
        # would be a stricter promise than the implementation keeps.
        self.assertAlmostEqual(
            light.scores["detail_distribution"],
            dark.scores["detail_distribution"],
            delta=25.0,
        )

    def test_value_separation_is_detected_without_any_geometry(self):
        with TemporaryDirectory() as directory:
            root = Path(directory)
            flat = root / "flat"
            two = root / "two"
            flat.mkdir()
            two.mkdir()
            plain = critique(_views(flat, _flat_square()))
            separated = critique(_views(two, _two_tone_square()))

        self.assertGreater(
            separated.scores["material_separation"],
            plain.scores["material_separation"],
        )


class TestVerdict(unittest.TestCase):
    def test_a_flat_square_is_not_approved(self):
        """The cheapest possible asset must fail. If it passes, the critic is
        measuring nothing and every later number is decoration."""

        with TemporaryDirectory() as directory:
            root = Path(directory)
            result = critique(_views(root, _flat_square()))
        self.assertEqual(result.verdict, "REVISE")
        self.assertLess(result.overall, APPROVAL_SCORE)

    def test_every_problem_carries_an_action(self):
        """A finding without a revision is a complaint. The loop needs the
        change, not the grievance."""

        with TemporaryDirectory() as directory:
            root = Path(directory)
            result = critique(_views(root, _flat_square()))
        self.assertTrue(result.problems)
        for problem in result.problems:
            self.assertTrue(problem.revision.strip(), problem.finding)
            self.assertTrue(problem.expected.strip(), problem.finding)

    def test_revisions_are_deduplicated(self):
        """The same defect on five views is one change, not five."""

        with TemporaryDirectory() as directory:
            root = Path(directory)
            result = critique(_views(root, _flat_square()))
        self.assertEqual(len(result.revisions), len(set(result.revisions)))

    def test_the_report_says_what_it_does_not_measure(self):
        with TemporaryDirectory() as directory:
            root = Path(directory)
            payload = critique(_views(root, _flat_square())).to_dict()
        self.assertIn("does not judge style", payload["scope"])
        self.assertIn("approvalScore", payload)


class TestThresholdProvenance(unittest.TestCase):
    def test_the_bands_are_not_derived_from_any_candidate(self):
        """The structural property. Every band is a module constant, so no
        measurement of the asset under review can move the bar it is judged
        against."""

        for band in (SILHOUETTE_SHAPE_BAND, LUMINANCE_SPREAD_BAND, EDGE_DENSITY_BAND):
            self.assertIsInstance(band, tuple)
            self.assertLess(band[0], band[1])

    def test_the_calibration_ladder_is_recorded(self):
        """A threshold whose derivation is not written down cannot be argued
        with, and an unarguable bar gets worked around instead of fixed."""

        self.assertIn("ladder", CALIBRATION)
        self.assertEqual(len(CALIBRATION["ladder"]), 4)
        for metric in ("silhouetteShape", "luminanceSpread", "edgeDensity"):
            self.assertEqual(len(CALIBRATION[metric]), len(CALIBRATION["ladder"]))

    def test_the_calibration_separates_the_worst_rung_from_the_best(self):
        """If the reference ladder does not order, the metric does not measure.
        Checked here so a future edit to the constants cannot quietly land a
        metric that no longer discriminates."""

        for metric in ("silhouetteShape", "luminanceSpread", "edgeDensity"):
            worst, *_, best = CALIBRATION[metric]
            self.assertLess(worst, best, metric)

    def test_metrics_that_failed_to_discriminate_are_named(self):
        """Dropping them silently would leave the docstring describing a critic
        that no longer exists."""

        self.assertIn("coverage", CALIBRATION["unscored"])
        self.assertIn("tones", CALIBRATION["unscored"])


class TestScoreShape(unittest.TestCase):
    def test_scores_stay_inside_zero_to_one_hundred(self):
        with TemporaryDirectory() as directory:
            root = Path(directory)
            result = critique(_views(root, _striped_square()))
        for axis, value in result.scores.items():
            self.assertGreaterEqual(value, 0.0, axis)
            self.assertLessEqual(value, 100.0, axis)
        self.assertGreaterEqual(result.overall, 0.0)
        self.assertLessEqual(result.overall, 100.0)

    def test_a_view_name_is_carried_on_every_finding(self):
        """"The back is undetailed" is actionable; "something is undetailed" is
        not."""

        with TemporaryDirectory() as directory:
            root = Path(directory)
            result = critique(_views(root, _flat_square()))
        for problem in result.problems:
            self.assertTrue(problem.view)

    def test_measurements_are_reported_per_view(self):
        with TemporaryDirectory() as directory:
            root = Path(directory)
            result = critique(_views(root, _flat_square()))
        for view in ("front", "back", "left", "right", "perspective"):
            self.assertIn(view, result.measurements)
            self.assertIn("edgeDensity", result.measurements[view])


if __name__ == "__main__":
    unittest.main()
