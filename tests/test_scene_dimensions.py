"""The dimensions from line 81 of the goal, and which of them earned a score.

Six were built. Three ordered the reference ladder and are scored; three did not
and are reported only. The evidence for each verdict lives here rather than in a
transcript, because "we measured it and it ran backwards" is a claim that has to
survive the next person who wants to switch it on.
"""

from __future__ import annotations

import random

import pytest

from rqe.scene.critic import (
    ARCHITECTURAL_RICHNESS_FLOOR,
    AXIS_WEIGHTS,
    CALIBRATION,
    PRIMITIVE_APPEARANCE_CEILING,
    VISUAL_HIERARCHY_CEILING,
)
from rqe.scene.dimensions import (
    architectural_richness,
    gameplay_readability,
    landmark_quality,
    measure,
    primitive_appearance,
    ui_world_cohesion,
    visual_hierarchy,
)


def _plate(size=(320, 240)):
    """The greybox rung: sky over one unbroken ground colour."""

    from PIL import Image

    frame = Image.new("RGB", size, (150, 175, 205))
    frame.paste(Image.new("RGB", (size[0], size[1] // 2), (110, 190, 90)), (0, size[1] // 2))
    return frame


def _built(size=(320, 240), seed=11):
    """The built rung: ground texture, and walls that make vertical edges."""

    from PIL import Image, ImageDraw

    rng = random.Random(seed)
    frame = Image.new("RGB", size, (150, 175, 205))
    draw = ImageDraw.Draw(frame)
    draw.rectangle([0, size[1] // 2, size[0], size[1]], fill=(48, 74, 40))
    for _ in range(400):
        x, y = rng.randrange(size[0]), rng.randrange(size[1] // 2, size[1])
        side = rng.randrange(2, 9)
        shade = tuple(max(0, min(255, c + rng.randrange(-28, 28))) for c in (48, 74, 40))
        draw.rectangle([x, y, x + side, y + side], fill=shade)
    # Towers: tall, narrow, and at different heights, which is what separates
    # architecture from scatter.
    for x, top in ((40, 40), (110, 70), (190, 30), (260, 85)):
        draw.rectangle([x, top, x + 18, size[1] // 2 + 20], fill=(120, 126, 134))
        draw.rectangle([x + 4, top + 6, x + 14, top + 20], fill=(70, 74, 82))
    return frame


# --------------------------------------------------------------- the scored


def test_architectural_richness_separates_built_from_bare():
    bare, built = architectural_richness(_plate()), architectural_richness(_built())
    assert bare < ARCHITECTURAL_RICHNESS_FLOOR <= built


def test_primitive_appearance_catches_the_flat_slab():
    bare, built = primitive_appearance(_plate()), primitive_appearance(_built())
    assert bare > PRIMITIVE_APPEARANCE_CEILING
    assert built < bare


def test_visual_hierarchy_reads_high_on_an_empty_frame():
    """High is the bad end, which is the opposite of the name's suggestion.

    Asserted against the recorded ladder rather than against a synthetic plate,
    because the synthetic one does not reproduce the effect: its horizon is a
    single hard line running the full width, so its contrast is spread evenly
    across all six columns and it scores *low*. The real undressed capture has
    one gradient strip and nothing else, which is what drives the metric to
    15.96. A test that used the synthetic frame here would be asserting a
    property this metric does not have.
    """

    undressed, dressed = CALIBRATION["dimensionsAdded"]["visualHierarchy"]
    assert undressed > dressed > VISUAL_HIERARCHY_CEILING
    assert visual_hierarchy(_built()) < VISUAL_HIERARCHY_CEILING


def test_visual_hierarchy_rises_when_the_frame_empties_out():
    """The direction, on frames built here: less scene, higher score."""

    from PIL import Image, ImageDraw

    sparse = Image.new("RGB", (320, 240), (60, 70, 80))
    ImageDraw.Draw(sparse).rectangle([150, 100, 180, 140], fill=(230, 230, 230))
    assert visual_hierarchy(sparse) > visual_hierarchy(_built())


@pytest.mark.parametrize("axis", ["architectural_richness", "primitive_appearance"])
def test_the_scored_dimensions_are_axes(axis):
    assert axis in AXIS_WEIGHTS


def test_primitive_appearance_blocks_release():
    """A frame built from test blocks is greybox whatever else is true of it."""

    from rqe.scene.critic import SceneCritique

    assert "primitive_appearance" in SceneCritique.BLOCKING_AXES


# ------------------------------------------------------------- the unscored


def test_landmark_quality_is_not_scored_and_the_reason_is_recorded():
    """It ranks a bare horizon with one tower above a dense one.

    Measured on the real ladder: 0.387 on the dressed blockout against 0.014 to
    0.174 on built frames. It confounds having a landmark with having nothing
    else, so it is reported and not scored.
    """

    assert "landmark_quality" not in AXIS_WEIGHTS
    rejected = CALIBRATION["dimensionsAdded"]["rejected"]
    assert "landmarkQuality" in rejected
    assert "confounds" in rejected["landmarkQuality"]


def test_landmark_quality_at_least_refuses_an_empty_frame():
    """The one thing it does get right, kept as a regression.

    Before the empty-column fix the plate scored a perfect 1.0 -- the same
    failure that retired `scale_coherence`.
    """

    assert landmark_quality(_plate()) == 0.0


def test_gameplay_readability_is_not_scored():
    assert "gameplay_readability" not in AXIS_WEIGHTS
    assert "gameplayReadability" in CALIBRATION["dimensionsAdded"]["rejected"]


def test_ui_world_cohesion_is_not_scored():
    """On the real ladder it returned 0.996 for a frame with no UI at all.

    A metric a scene cannot fail is a metric that cannot assess it. Note the
    synthetic plate scores 0.354 rather than ~1.0 -- its top band is pure sky
    against a half-green lower frame, so the two hue histograms genuinely
    disagree. That the synthetic and the real frame land so far apart is itself
    a reason not to trust the number yet.
    """

    assert "ui_world_cohesion" not in AXIS_WEIGHTS
    assert "uiWorldCohesion" in CALIBRATION["dimensionsAdded"]["rejected"]


def test_ui_world_cohesion_measures_shared_hue_when_there_is_any():
    """Sanity: a band drawn in the world's own hue beats an alien one."""

    from PIL import Image, ImageDraw

    def framed(colour):
        frame = _built()
        ImageDraw.Draw(frame).rectangle([0, 0, 320, 40], fill=colour)
        return frame

    belonging = ui_world_cohesion(framed((60, 96, 52)))
    alien = ui_world_cohesion(framed((235, 40, 210)))
    assert belonging > alien


def test_unscored_dimensions_are_still_reported():
    """Measured and shown is the point; only the scoring was withheld."""

    reported = measure(_built())
    for name in ("landmarkQuality", "gameplayReadability", "uiWorldCohesion"):
        assert name in reported


def test_gameplay_readability_measures_something_even_if_unscored():
    """Sanity: a frame with a saturated accent reads higher than one without."""

    from PIL import Image, ImageDraw

    plain = _built()
    marked = _built()
    draw = ImageDraw.Draw(marked)
    draw.rectangle([140, 150, 190, 200], fill=(245, 200, 70))
    assert gameplay_readability(marked) > gameplay_readability(plain)


# ------------------------------------------------------------- the record


def test_the_calibration_records_what_each_dimension_measured():
    added = CALIBRATION["dimensionsAdded"]
    for name in ("architecturalRichness", "primitiveAppearance", "visualHierarchy"):
        undressed, dressed = added[name]
        assert undressed != dressed, f"{name} did not separate the two rungs"
    assert len(added["rejected"]) == 3
