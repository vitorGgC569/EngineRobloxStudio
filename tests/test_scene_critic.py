"""The scene critic, on images built here rather than on captures.

Written after two of its metrics were found to be measuring the wrong thing --
`flatArea` swinging 42% under a brightness knob, `scaleCoherence` ranking an
empty plate above a built scene -- neither of which any test would have caught,
because there were no tests. Synthetic frames, so this runs without `.tmp`.
"""

from __future__ import annotations

import random
from pathlib import Path

import pytest

from rqe.scene.critic import (
    AXIS_WEIGHTS,
    CALIBRATION,
    FLAT_AREA_CEILING,
    PRODUCTION_SCORE,
    UNSCORED,
    SceneCriticError,
    _flat_fraction,
    _scale_coherence,
    critique_scene,
)


def _image(size=(320, 240)):
    from PIL import Image

    return Image.new("RGB", size, (60, 70, 80))


def _noisy(size=(320, 240), *, base=(60, 70, 80), amplitude=45, seed=7):
    """A frame with structure at several sizes, deterministically."""

    from PIL import Image, ImageDraw

    rng = random.Random(seed)
    image = Image.new("RGB", size, base)
    draw = ImageDraw.Draw(image)
    for _ in range(240):
        x, y = rng.randrange(size[0]), rng.randrange(size[1])
        side = rng.randrange(3, 40)
        shade = tuple(
            max(0, min(255, channel + rng.randrange(-amplitude, amplitude)))
            for channel in base
        )
        draw.rectangle([x, y, x + side, y + side], fill=shade)
    return image


def _gain(image, factor):
    from PIL import ImageEnhance

    return ImageEnhance.Brightness(image).enhance(factor)


# ------------------------------------------------------------------- exposure


def test_flat_fraction_does_not_read_the_brightness_knob():
    """The defect that started this: same pixels, different exposure.

    Before the threshold scaled with local brightness this measured 0.649 at
    gain 0.7 and 0.457 at gain 1.8 on a real capture -- enough to report an art
    pass as a regression. A little drift is expected and honest, because
    brightening an 8-bit image really does clip detail away.
    """

    frame = _noisy()
    measured = [_flat_fraction(_gain(frame, factor)) for factor in (0.7, 1.0, 1.4)]
    assert max(measured) - min(measured) < 0.12


def test_scale_coherence_still_reads_the_brightness_knob():
    """Kept as a warning, not as a standard.

    The adaptive thresholds fixed `flatArea` and did not fix this: the same
    synthetic frame measures roughly 0.50 at gain 0.7 and 0.16 at gain 1.4,
    because the ratio between two edge counts amplifies whatever residual each
    of them carries. That is the third independent reason the axis is unscored,
    and this test exists so that anyone tempted to put it back in AXIS_WEIGHTS
    has to delete an assertion that says why not.
    """

    frame = _noisy()
    measured = [_scale_coherence(_gain(frame, factor)) for factor in (0.7, 1.0, 1.4)]
    assert max(measured) - min(measured) > 0.2
    assert "scale_coherence" not in AXIS_WEIGHTS


# ------------------------------------------------------------------------ sky


def test_a_smooth_sky_is_not_counted_as_greybox():
    """Half sky over textured ground is a photograph, not an unbroken plane."""

    from PIL import Image

    ground = _noisy(size=(320, 120))
    frame = Image.new("RGB", (320, 240), (150, 175, 205))
    frame.paste(ground, (0, 120))
    assert _flat_fraction(frame) < 0.35


def test_removing_the_sky_does_not_rescue_an_empty_world():
    """The green plate is flat under the horizon too, and must still say so."""

    from PIL import Image

    frame = Image.new("RGB", (320, 240), (150, 175, 205))
    frame.paste(Image.new("RGB", (320, 120), (110, 190, 90)), (0, 120))
    assert _flat_fraction(frame) > 0.9


def test_a_frame_that_is_entirely_sky_is_flat():
    assert _flat_fraction(_image()) == pytest.approx(1.0)


# ------------------------------------------------------------- retired axis


def test_scale_coherence_is_measured_but_not_scored():
    assert "scale_coherence" not in AXIS_WEIGHTS
    assert "scaleCoherence" in UNSCORED
    assert "scaleCoherence" in CALIBRATION["unscored"]


def test_the_weights_still_sum_to_one():
    assert sum(AXIS_WEIGHTS.values()) == pytest.approx(1.0)


def test_no_finding_is_raised_from_an_unscored_metric(tmp_path):
    path = tmp_path / "frame.png"
    _noisy().save(path)
    report = critique_scene({"frame": path})
    assert all(finding.axis in AXIS_WEIGHTS for finding in report.findings)
    assert "scaleCoherence" in report.measurements["frame"]


# ------------------------------------------------------------------- verdicts


def test_a_scene_nobody_captured_fails_closed(tmp_path):
    with pytest.raises(SceneCriticError, match="absence of evidence"):
        critique_scene({})


def test_a_missing_file_is_not_silently_scored(tmp_path):
    with pytest.raises(SceneCriticError):
        critique_scene({"gone": tmp_path / "nothing.png"})


def test_a_flat_plate_is_refused(tmp_path):
    from PIL import Image

    path = tmp_path / "plate.png"
    frame = Image.new("RGB", (320, 240), (150, 175, 205))
    frame.paste(Image.new("RGB", (320, 120), (110, 190, 90)), (0, 120))
    frame.save(path)

    report = critique_scene({"plate": path})
    assert report.overall < PRODUCTION_SCORE
    assert not report.production_ready
    assert report.verdict == "REVISE"
    assert any(finding.axis == "environment_density" for finding in report.findings)


def test_a_greybox_finding_blocks_release_whatever_the_average(tmp_path):
    """Above the bar is not enough if the critic still calls the scene unfinished.

    An earlier version passed a frame at 78.6 while reporting "62% of the frame
    is one unbroken plane", because strong hue and material scores outvoted the
    one axis that says the scene is not built yet.
    """

    from dataclasses import dataclass

    from rqe.scene.critic import Finding, SceneCritique

    report = SceneCritique(
        scores={axis: 100.0 for axis in AXIS_WEIGHTS},
        overall=PRODUCTION_SCORE + 20,
        findings=[Finding(
            "environment_density", "frame", "62% of the frame is one unbroken plane",
            0.62, f"<= {FLAT_AREA_CEILING}", "build something",
        )],
    )
    assert not report.production_ready
    assert report.verdict == "REVISE"


def test_the_calibration_ladder_is_recorded_in_order():
    """Undressed must measure flatter and less detailed than dressed."""

    undressed, dressed = CALIBRATION["flatArea"]
    assert undressed > dressed
    undressed, dressed = CALIBRATION["detailDensity"]
    assert undressed < dressed
