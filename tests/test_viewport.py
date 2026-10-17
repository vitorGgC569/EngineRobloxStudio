"""The game region, and the measurement that could not fail without it.

The last test here is the regression: a frame whose game area is a flat colour
inside real Studio chrome scored full marks on both of `playtest`'s checks. It
is written as arithmetic over a synthetic frame rather than over a capture,
because a capture lives in `.tmp/` and a regression test that depends on a
gitignored file is a test that passes by being skipped.
"""

from __future__ import annotations

import unittest

from rqe.viewport import (
    CHANGE_THRESHOLD,
    Cache,
    Located,
    Rect,
    ViewportError,
    agrees_with_client,
    changed_region,
    crop,
    locate,
    plausible,
)

try:
    from PIL import Image, ImageDraw
    PILLOW = True
except ImportError:  # pragma: no cover - environment dependency
    PILLOW = False


WINDOW = (1296, 930)
#: Where the viewport sits in a real 1296x930 Studio window, measured off a
#: `brambleway` capture. Used as the truth a synthetic frame is built around.
GAME = Rect(172, 170, 1108, 845)


def _chrome_frame(game_fill=(0, 0, 0)):
    """A Studio-shaped frame: high-contrast chrome around a flat game area."""

    image = Image.new("RGB", WINDOW, (32, 34, 38))
    draw = ImageDraw.Draw(image)
    # The ribbon and the panels: white text on dark chrome is where the whole
    # dynamic range of a real capture comes from.
    draw.rectangle([0, 0, WINDOW[0], 150], fill=(246, 246, 248))
    draw.rectangle([1110, 150, WINDOW[0], WINDOW[1]], fill=(240, 240, 244))
    draw.rectangle([0, 860, WINDOW[0], WINDOW[1]], fill=(18, 18, 20))
    draw.text((20, 880), "com Ctrl ou use Ctrl+Para cima", fill=(255, 255, 255))
    # PIL's rectangle is inclusive of its far edge; Rect is exclusive. Drawing
    # one pixel short is what makes the drawn region exactly `GAME`.
    draw.rectangle([GAME.left, GAME.top, GAME.right - 1, GAME.bottom - 1],
                   fill=game_fill)
    return image


def _luma(pixel):
    red, green, blue = pixel[:3]
    return (0.2126 * red + 0.7152 * green + 0.0722 * blue) / 255.0


def _measure(image):
    """`playtest.inspect_frame`'s arithmetic, so the regression is the real one."""

    pixels = list(image.convert("RGB").getdata())
    tones = {(_luma(p) * 16) // 1 for p in pixels}
    brightest = max(pixels, key=_luma)
    darkest = min(pixels, key=_luma)
    return len(tones), _luma(brightest) - _luma(darkest)


class RectTests(unittest.TestCase):
    def test_an_empty_rectangle_is_refused_rather_than_stored(self):
        with self.assertRaises(ViewportError):
            Rect(10, 10, 10, 40)
        with self.assertRaises(ViewportError):
            Rect(10, 10, 40, 10)

    def test_a_rectangle_survives_a_round_trip_through_its_dict(self):
        self.assertEqual(Rect.from_dict(GAME.to_dict()), GAME)

    def test_the_dict_carries_the_derived_size_a_reader_needs(self):
        payload = GAME.to_dict()
        self.assertEqual(payload["width"], 936)
        self.assertEqual(payload["height"], 675)


class AgreementTests(unittest.TestCase):
    def test_an_exact_match_agrees_with_no_drift(self):
        ok, drift = agrees_with_client(GAME, (936, 675))
        self.assertTrue(ok)
        self.assertEqual(drift, 0.0)

    def test_display_scaling_is_within_tolerance(self):
        # 936 desktop pixels reported as 928 client pixels is a scale factor,
        # not a mislocated viewport.
        ok, drift = agrees_with_client(GAME, (928, 669))
        self.assertTrue(ok)
        self.assertLess(drift, 0.06)

    def test_a_panel_sized_region_is_rejected(self):
        ok, drift = agrees_with_client(Rect(0, 0, 200, 120), (936, 675))
        self.assertFalse(ok)
        self.assertGreater(drift, 0.5)

    def test_no_reported_size_is_not_a_failed_check(self):
        ok, drift = agrees_with_client(GAME, None)
        self.assertTrue(ok)
        self.assertEqual(drift, 0.0)

    def test_a_one_pixel_report_is_treated_as_absent(self):
        # An edit-mode Studio answers (1, 1); accepting it as a target would
        # reject every real viewport.
        ok, _ = agrees_with_client(GAME, (0, 0))
        self.assertTrue(ok)


class PlausibilityTests(unittest.TestCase):
    def test_a_viewport_is_a_large_part_of_its_window(self):
        self.assertTrue(plausible(GAME, WINDOW))

    def test_a_spinner_is_not_a_viewport(self):
        self.assertFalse(plausible(Rect(600, 400, 640, 440), WINDOW))

    def test_a_degenerate_window_is_never_plausible(self):
        self.assertFalse(plausible(GAME, (0, 0)))


@unittest.skipUnless(PILLOW, "Pillow is required")
class DetectionTests(unittest.TestCase):
    def test_the_moving_region_is_the_game_region(self):
        before = _chrome_frame((40, 90, 60))
        after = _chrome_frame((60, 40, 90))
        found = changed_region(before, after)
        self.assertIsNotNone(found)
        self.assertEqual(found.as_tuple(), GAME.as_tuple())

    def test_two_identical_frames_report_nothing_rather_than_everything(self):
        frame = _chrome_frame((40, 90, 60))
        self.assertIsNone(changed_region(frame, frame.copy()))

    def test_compression_noise_does_not_widen_the_box_to_the_window(self):
        # Every pixel nudged by less than the threshold. Without the point()
        # threshold, getbbox() would return the whole window and the module
        # would confidently answer "the game is the entire screen".
        before = _chrome_frame((40, 90, 60))
        after = before.point(lambda value: min(255, value + CHANGE_THRESHOLD - 2))
        self.assertIsNone(changed_region(before, after))

    def test_frames_of_different_sizes_are_refused(self):
        with self.assertRaises(ViewportError):
            changed_region(_chrome_frame(), Image.new("RGB", (100, 100)))

    def test_locate_finds_the_viewport_and_says_how(self):
        frames = [_chrome_frame((40, 90, 60)), _chrome_frame((60, 40, 90))]
        found = locate(lambda: frames.pop(0), window_size=WINDOW,
                       reported=(936, 675), settle=0.0)
        self.assertIsInstance(found, Located)
        self.assertEqual(found.rect.as_tuple(), GAME.as_tuple())
        self.assertEqual(found.method, "motion")
        self.assertEqual(found.drift, 0.0)

    def test_locate_refuses_a_static_scene_rather_than_guessing(self):
        frame = _chrome_frame((40, 90, 60))
        self.assertIsNone(
            locate(lambda: frame.copy(), window_size=WINDOW,
                   reported=(936, 675), settle=0.0, attempts=2))

    def test_locate_refuses_a_region_that_contradicts_the_client(self):
        # Only a small panel repaints. The size cross-check is what stops that
        # being reported as the game.
        base = _chrome_frame((40, 90, 60))
        moved = base.copy()
        ImageDraw.Draw(moved).rectangle([20, 880, 300, 910], fill=(90, 90, 90))
        frames = [base, moved, base.copy(), moved.copy()]
        self.assertIsNone(
            locate(lambda: frames.pop(0), window_size=WINDOW,
                   reported=(936, 675), settle=0.0, attempts=2))

    def test_a_nudge_rescues_a_scene_that_was_standing_still(self):
        still = _chrome_frame((40, 90, 60))
        moved = _chrome_frame((60, 40, 90))
        state = {"nudged": False}

        def grab():
            return (moved if state["nudged"] else still).copy()

        def nudge():
            state["nudged"] = True

        found = locate(grab, window_size=WINDOW, reported=(936, 675),
                       settle=0.0, attempts=2, nudge=nudge)
        self.assertIsNotNone(found)
        self.assertEqual(found.method, "camera-nudge")


@unittest.skipUnless(PILLOW, "Pillow is required")
class CropTests(unittest.TestCase):
    def test_cropping_returns_the_game_at_its_own_size(self):
        cropped = crop(_chrome_frame(), GAME)
        self.assertEqual(cropped.size, (936, 675))

    def test_an_unknown_region_leaves_the_frame_alone(self):
        frame = _chrome_frame()
        self.assertEqual(crop(frame, None).size, frame.size)


@unittest.skipUnless(PILLOW, "Pillow is required")
class TheRegressionThisModuleExistsFor(unittest.TestCase):
    """A black game inside real chrome used to score full marks."""

    #: `playtest.inspect_frame`'s own thresholds, restated so this test fails
    #: if either is ever loosened without someone reading this file.
    MIN_TONES = 5
    MIN_CONTRAST = 0.22

    def test_the_whole_window_cannot_tell_a_black_game_from_a_lit_one(self):
        black_tones, black_contrast = _measure(_chrome_frame((0, 0, 0)))
        lit_tones, lit_contrast = _measure(_chrome_frame((40, 90, 60)))

        # The defect, stated as the gate itself: a game drawing nothing passes
        # both checks, because the chrome supplies the whole dynamic range.
        self.assertGreaterEqual(black_tones, self.MIN_TONES)
        self.assertGreaterEqual(black_contrast, self.MIN_CONTRAST)
        self.assertGreaterEqual(lit_tones, self.MIN_TONES)
        self.assertGreaterEqual(lit_contrast, self.MIN_CONTRAST)

        # And the ranking is backwards, which is the sharpest way to say it:
        # the frame with **no game in it** scores higher on both measures than
        # the frame with a game in it, because all the signal is chrome.
        self.assertGreaterEqual(black_tones, lit_tones)
        self.assertGreater(black_contrast, lit_contrast)

    def test_cropping_first_makes_both_of_them_fail(self):
        for fill in ((0, 0, 0), (40, 90, 60)):
            with self.subTest(fill=fill):
                tones, contrast = _measure(crop(_chrome_frame(fill), GAME))
                # One tone, no contrast: the measurement now describes the game
                # and reports it as featureless instead of borrowing the
                # ribbon's dynamic range to pass.
                self.assertEqual(tones, 1)
                self.assertEqual(contrast, 0.0)
                self.assertLess(tones, self.MIN_TONES)
                self.assertLess(contrast, self.MIN_CONTRAST)


class CacheTests(unittest.TestCase):
    def test_a_resized_window_is_a_different_key(self):
        cache = Cache()
        found = Located(rect=GAME, method="motion")
        cache.put("hwnd:1", WINDOW, found)
        self.assertIs(cache.get("hwnd:1", WINDOW), found)
        self.assertIsNone(cache.get("hwnd:1", (1000, 800)))
        self.assertIsNone(cache.get("hwnd:2", WINDOW))

    def test_clearing_empties_it(self):
        cache = Cache()
        cache.put("hwnd:1", WINDOW, Located(rect=GAME, method="motion"))
        cache.clear()
        self.assertIsNone(cache.get("hwnd:1", WINDOW))


@unittest.skipUnless(PILLOW, "Pillow is required")
class TheGateFailsClosedNow(unittest.TestCase):
    """`playtest` must block when it cannot say where the game is."""

    def _report(self):
        from forge.cli.playtest import Report

        return Report(game="viewport-probe")

    def _frame(self, tmp, fill):
        path = tmp / "frame.png"
        _chrome_frame(fill).save(path)
        return path

    def test_an_unknown_region_is_an_error_and_measures_nothing(self):
        import tempfile
        from pathlib import Path

        from forge.cli.playtest import inspect_frame

        with tempfile.TemporaryDirectory() as raw:
            report = self._report()
            inspect_frame(self._frame(Path(raw), (0, 0, 0)), report, None)

        self.assertTrue(report.failed)
        self.assertNotIn("tones", report.measured)
        self.assertNotIn("contrast", report.measured)
        self.assertTrue(any("region of the frame is unknown" in f.what
                            for f in report.findings))

    def test_a_black_game_inside_real_chrome_now_fails(self):
        import tempfile
        from pathlib import Path

        from forge.cli.playtest import inspect_frame

        with tempfile.TemporaryDirectory() as raw:
            report = self._report()
            inspect_frame(self._frame(Path(raw), (0, 0, 0)), report, GAME)

        # Before the crop this scored tones=16, contrast=1.00 and passed.
        self.assertEqual(report.measured["tones"], 1)
        self.assertEqual(report.measured["contrast"], 0.0)
        self.assertTrue(report.failed)

    def test_the_region_that_was_measured_is_recorded_in_the_evidence(self):
        import tempfile
        from pathlib import Path

        from forge.cli.playtest import inspect_frame

        with tempfile.TemporaryDirectory() as raw:
            report = self._report()
            inspect_frame(self._frame(Path(raw), (40, 90, 60)), report, GAME)

        self.assertEqual(report.measured["frameRegion"], GAME.to_dict())


if __name__ == "__main__":  # pragma: no cover
    unittest.main()
