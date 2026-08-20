"""The critic must notice when a frame has been destroyed by light.

This is the defect that prompted the axis: the scene critic once returned
98-100 for a frame whose character was blown to a flat white silhouette, and it
was right by its own lights -- not one of its six dimensions measured exposure,
so an image with a sheet of 255 across it satisfied hierarchy, richness,
landmark, primitive appearance, readability and cohesion exactly as well as a
correct one.

**Calibrated by construction.** The ladder below is ordered worst-to-best before
anything is measured: a frame, the same frame brightened, and the same frame
blown out. If the critic cannot separate them, the critic is wrong -- the same
argument the asset critic's four-rung ladder makes.
"""

from __future__ import annotations

import pytest

import inspect

from rqe.scene.dimensions import exposure_health

Image = pytest.importorskip("PIL.Image")
ImageEnhance = pytest.importorskip("PIL.ImageEnhance")


def frame(seed: int = 0):
    """A frame with real tonal range, built rather than captured.

    A synthetic frame keeps this test independent of whatever is in `.tmp`,
    which is where captures live and where they are deleted.
    """

    width = height = 96
    image = Image.new("RGB", (width, height))
    image.putdata([
        (40 + (x * 5 + seed) % 170, 55 + (y * 3) % 150, 70 + (x * y) % 120)
        for y in range(height) for x in range(width)
    ])
    return image


def test_a_correct_frame_clips_nothing():
    assert exposure_health(frame()) == pytest.approx(0.0, abs=0.01)


def test_blowing_a_frame_out_is_visible_to_the_critic():
    """The exact failure: brightness past the display range destroys detail."""

    base = frame()
    brightened = ImageEnhance.Brightness(base).enhance(1.8)
    blown = ImageEnhance.Brightness(base).enhance(3.0)

    assert exposure_health(base) < exposure_health(brightened) < exposure_health(blown)
    assert exposure_health(blown) > 0.30, "a frame blown to 3x must read as clipped"


def test_the_ladder_is_ordered_by_construction():
    """Monotonic across five rungs, not just at the ends.

    A metric that separates only the extremes passes the previous test while
    still being unable to tell a slightly hot frame from a correct one, which is
    the resolution that actually matters when adjusting a light.
    """

    base = frame()
    measured = [
        exposure_health(ImageEnhance.Brightness(base).enhance(gain))
        for gain in (1.0, 1.4, 1.8, 2.4, 3.0)
    ]
    assert measured == sorted(measured), f"not monotone: {measured}"


def test_a_night_scene_is_not_a_defect():
    """The counterexample that retired the black end of this metric.

    The first version scored crushed blacks alongside blown highlights, and the
    first real frame it met was `last-vigil` -- a night game with 58% of its
    viewport at 0-4 *by design*. Scoring that would fire the axis on most of the
    horror genre.

    The earlier version of this test dimmed a frame globally, where nothing
    reaches 0-4, so it passed while the metric was wrong. This builds the actual
    failure: a frame with real black in it.
    """

    from rqe.scene.dimensions import crushed_fraction

    width = height = 96
    night = Image.new("RGB", (width, height))
    night.putdata([
        # Two thirds genuinely black, a third with detail -- a night scene.
        (0, 0, 0) if y < height * 0.66 else (70 + (x * 2) % 90, 80, 95)
        for y in range(height) for x in range(width)
    ])

    assert crushed_fraction(night) > 0.5, "the frame really is mostly black"
    assert exposure_health(night) < 0.01, (
        "darkness must not read as clipping; that would fail every night scene")


def test_the_black_end_is_measured_but_never_scored():
    """Reported for a person to read, not used as a bar.

    Nothing here can tell a stylised night from an underexposed one, and the
    asset critic's own discipline says a metric that cannot discriminate is
    measured and reported rather than scored.
    """

    from rqe.scene.dimensions import measure

    keys = measure(frame())
    assert "crushedFraction" in keys
    assert "exposureHealth" in keys

    from rqe.scene import critic

    # The scored axis reads `exposureHealth`; the black end is only ever
    # reported. If the critic ever scores it, this fails.
    assert "crushedFraction" not in inspect.getsource(critic.critique_scene)



def test_exposure_is_scored_and_blocking():
    """Measuring it without scoring it would have changed nothing."""

    from rqe.scene.critic import AXIS_WEIGHTS, SceneCritique

    assert "exposure" in AXIS_WEIGHTS
    assert AXIS_WEIGHTS["exposure"] > 0
    assert sum(AXIS_WEIGHTS.values()) == pytest.approx(1.0)
    assert "exposure" in SceneCritique.BLOCKING_AXES
