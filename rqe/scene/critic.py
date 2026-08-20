"""The scene critic: does this look like a game, or like a test map?

The asset critic in `rqe/geometry/critic.py` answers a narrower question -- is
this *one mesh* worth looking at -- and answers it well, because a render it
scores has an alpha channel, a known subject and a fixed camera. None of that is
true here. This reads a screenshot of a running place: no mask, a whole world in
frame, and whatever the camera happened to be pointing at.

So the metrics are different, and the one that matters most is the one nobody
usually measures: **how much of the frame is large, flat, untextured colour**.
That is the greybox signature. A test map and a finished game differ far less in
their palettes than in how much of the screen is a single uninterrupted plane,
and a scene can pass every other check while two thirds of it is empty ground
under empty sky.

What this is not:

**Not a taste engine.** It measures composition defects, so a high score means
"nothing measurably wrong", never "attractive". Art direction is not in scope
and is not claimed.

**Not a substitute for looking.** The goal it serves says a person should be
able to see a screenshot and believe it is a commercial game. No number decides
that. What these numbers do is stop *me* from claiming progress because I
changed some code, and catch the cases that are objectively still greybox before
anyone is asked to judge the rest.

**Not calibrated the way the asset critic is.** That one has a four-rung ladder
built on purpose. This one has real captures of one game before and after
dressing, which is two points, and the thresholds say so rather than implying a
precision nothing here established.

Pillow only, like the asset critic: a critic that runs on a workstation and
fails in the container is not part of the pipeline.
"""

from __future__ import annotations

import math
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Iterable

from . import dimensions


# --------------------------------------------------------------- thresholds

#: Fraction of the frame that may be one flat, unbroken colour plane.
#:
#: The greybox signature, and the single most diagnostic number here. Measured:
#: the undressed place is 0.982 -- sky and ground and nothing else -- and after
#: lighting, a path, a plaza, a landmark and 48 plants it is 0.896.
#:
#: The bar is far below both, and is **aspirational rather than interpolated**.
#: Nothing measured here is a finished game, so no value between these two
#: references could describe one; this says where a dense scene lands, and both
#: references fail it because both deserve to.
FLAT_AREA_CEILING = 0.34

#: Interior edge density across the frame: how much of what is on screen has
#: detail on it. Measured 0.0101 undressed and 0.0199 dressed -- dressing roughly
#: doubled it and it is still an order below a scene of real geometry.
DETAIL_DENSITY_FLOOR = 0.045

#: Distinct hues holding at least 2% of the frame. A scene built from three
#: palette roles reads as a diagram of a scene.
HUE_VARIETY_FLOOR = 4

#: Luminance spread across the frame. Flat lighting on flat geometry gives a
#: narrow histogram, and that reads as unlit rather than as stylised.
LUMINANCE_SPREAD_FLOOR = 38.0

#: Detail above the horizon over detail across the whole frame.
#:
#: **Does not discriminate, and is scored at zero weight because of it.** Both
#: references measure above 1.0 -- the upper half is denser than the average
#: simply because the lower half is empty ground, which is the opposite of what
#: this was meant to detect. Kept measured and reported, because the intent is
#: right and a better formulation belongs here; scored, it would reward the
#: emptiness it was written to catch.
VERTICALITY_FLOOR = 0.12

#: Fraction of the frame allowed to sit at or near full white.
#:
#: Blown highlights destroy exactly what the rest of this file measures: a
#: clipped region has no detail, no hue and no material, so a scene can be made
#: to look "brighter" while scoring worse on every axis. It was found the way
#: these things are found -- a player-view screenshot where the plaza and the
#: beacon were solid white and the keep behind them had vanished.
#:
#: The cause was the world's own lights, not the mood: a 24-stud Neon ball with
#: a 120-stud floodlight on it, plus a lane of lamps overlapping into one wash.
CLIPPED_HIGHLIGHT_CEILING = 0.06

#: How similar the frame's left and right halves may be, after normalisation.
#: Above this, whatever fills the scene is being repeated rather than composed.
REPETITION_CEILING = 0.86

#: Overall score at or above which a scene carries no measured greybox defect.
#: Passing it is necessary and nowhere near sufficient: it means nothing is
#: measurably wrong, which is where judging by eye starts rather than ends.
PRODUCTION_SCORE = 78.0

#: Detail in the upper third of the frame. The skyline is where a world's
#: silhouette lives, and a flat one is the greybox signature that no amount of
#: ground-level detail removes.
#:
#: **Only meaningful from a viewpoint that can see a horizon.** Seven outlying
#: watchtowers at varied heights were added to break the skyline, the world grew
#: from 1130 to 1527 parts, and this measured 0.0159 before and 0.0159 after --
#: because the capture was aerial, and from above the upper third of the frame
#: is sky whatever stands on the ground.
#:
#: The metric is right and the viewpoint was wrong. A critique that scores this
#: from a top-down frame is measuring the camera, so `critique_scene` now says
#: so rather than reporting a silhouette failure the scene may not have.
SKYLINE_BREAK_FLOOR = 0.035

#: Below this fraction of ground in the lower half, the camera is looking down
#: at the world rather than across it, and any skyline reading is about the
#: angle rather than about the architecture.
HORIZON_VISIBLE_FLOOR = 0.12

#: Fine detail against coarse detail. Retired as a scored threshold -- see
#: UNSCORED below for the measurements that retired it -- and kept only so the
#: reported number has something to be read against.
SCALE_COHERENCE_FLOOR = 0.35

#: Detail away from dead centre. A generated scene defaults to the origin,
#: because that is where the origin is.
THIRDS_INTEREST_FLOOR = 0.55

#: Fraction of columns carrying a tall vertical edge -- a wall, post or tower.
#:
#: Measured: the undressed plate 0.0091 and the dressed blockout 0.0082, against
#: 0.0236 to 0.0390 for every frame of the built world. A threefold separation
#: with nothing in between, so the bar sits above both greybox rungs and below
#: every built one. What it catches is the state a scatter-driven generator
#: reaches on its own: ten thousand rocks and no architecture.
ARCHITECTURAL_RICHNESS_FLOOR = 0.018

#: Fraction of the frame that is a large flat axis-aligned rectangle.
#:
#: The development-primitive signature the goal asks to eliminate in line 17.
#: Measured: 0.856 undressed, 0.402 dressed, and 0.000 to 0.232 across the built
#: viewpoints. The ceiling is tight against the worst built frame on purpose --
#: that frame is the aerial one, and it is genuinely mostly slabs.
PRIMITIVE_APPEARANCE_CEILING = 0.25

#: Contrast concentrated in the busiest cell of a 6x6 grid, as a multiple of an
#: even share.
#:
#: Measured: 15.96 undressed, 5.47 dressed, 1.5 to 2.1 built. High is the bad
#: end -- see the docstring in `dimensions.py`, which says plainly that this
#: detects emptiness rather than emphasis and is named for what it does.
VISUAL_HIERARCHY_CEILING = 3.2

#: Fraction of the frame allowed to be clipped white or crushed black.
#:
#: **The axis that was missing.** This critic once returned 98-100 for a frame
#: whose character was blown to a flat white silhouette, and it was right by its
#: own lights: not one of its six dimensions measured exposure, so an image with
#: a sheet of 255 across it satisfied hierarchy, richness, landmark, primitive
#: appearance, readability and cohesion exactly as well as a correct one.
#:
#: Calibrated by construction rather than by interpolation, on frames whose
#: order was known before anything was measured: a correctly exposed frame
#: measures 0.000, and a frame deliberately blown measures 0.667. The bar sits
#: far below the broken end and above where specular hits legitimately land -- a
#: real frame has pixels at 255, but not *areas* of them.
#:
#: **Highlights only.** Crushed blacks were scored here for exactly one round,
#: until the corpus was pointed at `last-vigil`: a night game with 58% of its
#: viewport at 0-4 by design. `crushedFraction` is still measured and reported;
#: it is not a bar, because nothing here can tell a stylised night from an
#: underexposed one.
EXPOSURE_CLIPPING_CEILING = 0.04


AXIS_WEIGHTS = {
    "environment_density": 0.22,
    "composition": 0.16,
    "material_richness": 0.18,
    # Named separately because the goal names them separately, and because a
    # scene can be dense, lit and varied while still having a flat skyline --
    # which is exactly what the fort is.
    "silhouette": 0.14,
    # The two the goal names in line 17 and line 81 that nothing was measuring.
    # A scene can be dense, lit, varied and composed while being built entirely
    # from untextured slabs, and every axis above it will say so approvingly.
    "architectural_richness": 0.12,
    "primitive_appearance": 0.12,
    # Taken from `environment_density` (0.26 -> 0.22) and `material_richness`
    # (0.20 -> 0.18), the two largest, rather than diluting every axis: a blown
    # frame is a failure of the image, and the axes it is drawn from are the two
    # most able to be satisfied by a ruined one.
    "exposure": 0.06,
}

#: `scale_coherence` used to be here at 0.10, and the 0.10 has been shared out
#: across the four axes above in proportion. It is still measured and still
#: reported; it is no longer scored, because it was measured on the reference
#: ladder and found to run backwards.
#:
#: In its ratio form -- `min(fine, coarse) / max(fine, coarse)` -- the undressed
#: green plate scores 0.474 and the dense gameplay frame scores 0.041. An empty
#: frame has almost no edges at either scale, so the ratio between two tiny
#: counts comes out near one, and the metric rewards having nothing in view. It
#: was ranking a greybox above a built scene by a factor of ten.
#:
#: A density form was tried instead -- adaptive edge density after a 4px blur,
#: which should read large-mass structure directly. Across the whole ladder it
#: measured 0.0053, 0.0048, 0.0049, 0.0049, 0.0048: flat to three decimals on
#: frames that range from a green plate to a fought-over battlefield. It does
#: not discriminate at all.
#:
#: And the ratio form is not even stable against exposure. After both edge
#: thresholds were made to scale with local brightness -- the change that fixed
#: `flatArea` -- one synthetic frame still measures 0.50 at gain 0.7 and 0.16 at
#: gain 1.4, because a ratio between two counts amplifies whatever residual each
#: of them carries rather than cancelling it.
#:
#: So the axis is retired rather than reweighted or re-tuned. The thing it was
#: reaching for is real -- a scene built from one size of object does read as a
#: diagram -- but nothing here measures it, and an axis that ranks the ladder
#: backwards is worse than no axis at all. This follows the asset critic, which
#: names `coverage`, `tones` and `emptyCells` as measured-but-unscored for the
#: same reason.
UNSCORED = ("verticality", "scaleCoherence")

#: What the numbers above were read from. Two captures of one game, named so the
#: thinness of the evidence is visible rather than implied.
CALIBRATION = {
    "references": ("siegehold undressed (green plate)", "siegehold dressed (lit, planted)"),
    "flatArea": (0.966, 0.876),
    "detailDensity": (0.0101, 0.0199),
    "hueVariety": (1, 6),
    "luminanceSpread": (11.8, 35.4),
    "overall": (43.7, 72.7),
    "unscored": UNSCORED,
    "dimensionsAdded": {
        "note": (
            "line 81 of the goal names seventeen dimensions. Six were built in "
            "rqe/scene/dimensions.py and measured against this ladder before any "
            "was scored; three ordered it and are scored, three did not and are "
            "reported only"
        ),
        "architecturalRichness": (0.0091, 0.0082),
        "primitiveAppearance": (0.8557, 0.4016),
        "visualHierarchy": (15.96, 5.47),
        "rejected": {
            "landmarkQuality": (
                "0.0 undressed after the empty-column fix, but 0.387 on the "
                "dressed blockout against 0.014-0.174 on built frames: it reads a "
                "bare horizon with one tower on it as better than a dense one, so "
                "it confounds having a landmark with having nothing else"
            ),
            "gameplayReadability": (
                "0.587 dressed and 0.956 on an old bright-palette aerial against "
                "0.019-0.187 built. It measures how saturated the palette is, not "
                "whether anything is called out"
            ),
            "uiWorldCohesion": (
                "0.996 on a frame with no UI in it at all. A scene the metric "
                "cannot fail is a scene it cannot assess"
            ),
        },
    },
    "flatAreaNote": (
        "flatArea was (0.982, 0.896) while its threshold was a fixed difference "
        "of 2 levels. That number read exposure as much as structure -- one "
        "frame put through a brightness knob measured 0.649 at gain 0.7 and "
        "0.457 at gain 1.8 without a pixel of structure changing -- so the "
        "threshold now scales with local brightness and the references were "
        "re-measured through it. Sky was then excluded from the ratio as well, "
        "for the reason given in `_flat_fraction`, and the references were "
        "re-measured a second time. The ladder still orders and the gap between "
        "the two rungs is wider than it was: 0.966 against 0.876"
    ),
    "caveat": (
        "two points from one game, not a purpose-built ladder like the asset "
        "critic's. The thresholds sit beyond both references because both are "
        "still greybox; they are a floor for 'obviously unfinished', not a "
        "definition of finished"
    ),
}


class SceneCriticError(RuntimeError):
    """The capture could not be read, so nothing can be said about it."""


@dataclass(frozen=True)
class Finding:
    axis: str
    view: str
    finding: str
    measured: float
    expected: str
    remedy: str

    def to_dict(self) -> dict[str, Any]:
        return {
            "axis": self.axis, "view": self.view, "finding": self.finding,
            "measured": round(self.measured, 4), "expected": self.expected,
            "remedy": self.remedy,
        }


@dataclass
class SceneCritique:
    scores: dict[str, float]
    overall: float
    findings: list[Finding] = field(default_factory=list)
    measurements: dict[str, Any] = field(default_factory=dict)

    #: Findings that describe a scene as unfinished rather than as imperfect.
    #: A frame carrying one of these is greybox by the critic's own words, and
    #: the goal is explicit that a greybox must not reach release candidate.
    #: `primitive_appearance` joins the blocking set because "elimine a
    #: aparência de primitives de desenvolvimento" is not a matter of degree: a
    #: frame built from test blocks is greybox whatever else is true of it.
    #: `exposure` blocks because a clipped frame cannot be judged on anything
    #: else: the information the other axes would read has been destroyed.
    BLOCKING_AXES = ("environment_density", "primitive_appearance", "exposure")

    @property
    def production_ready(self) -> bool:
        """Above the bar *and* carrying no greybox finding.

        The average alone passed a frame at 78.6 while the critic was still
        reporting "62% of the frame is one unbroken plane -- the greybox
        signature". Strong scores on hue and material had outvoted the one axis
        that says the scene is unfinished, which is precisely the shape of
        optimising for a validator instead of for the thing it measures.
        """

        if self.overall < PRODUCTION_SCORE:
            return False
        return not any(f.axis in self.BLOCKING_AXES for f in self.findings)

    @property
    def verdict(self) -> str:
        return "VISUALLY_PRODUCTION_READY" if self.production_ready else "REVISE"

    @property
    def remedies(self) -> list[str]:
        seen: dict[str, None] = {}
        for finding in self.findings:
            seen.setdefault(finding.remedy, None)
        return list(seen)

    def to_dict(self) -> dict[str, Any]:
        return {
            "schemaVersion": 1,
            "verdict": self.verdict,
            "overall": round(self.overall, 2),
            "productionScore": PRODUCTION_SCORE,
            "scores": {k: round(v, 2) for k, v in self.scores.items()},
            "weights": dict(AXIS_WEIGHTS),
            "findings": [f.to_dict() for f in self.findings],
            "remedies": self.remedies,
            "measurements": self.measurements,
            "calibration": {k: list(v) if isinstance(v, tuple) else v
                            for k, v in CALIBRATION.items()},
            "scope": (
                "measures greybox defects in a real capture -- flat area, detail "
                "density, hue variety, verticality, repetition. Passing means "
                "nothing is measurably unfinished, which is where judging by eye "
                "begins rather than ends. Art direction is not scored"
            ),
        }

    def summary(self) -> str:
        lines = [f"{self.verdict}  {self.overall:.0f}/100 (production bar {PRODUCTION_SCORE:.0f})"]
        for axis, value in self.scores.items():
            lines.append(f"  {axis:<22s} {value:5.1f}")
        for finding in self.findings:
            lines.append(f"  [{finding.view}] {finding.finding}")
        return "\n".join(lines)


# ------------------------------------------------------------------ pixels


def _open(path: Path, viewport: tuple[float, float, float, float] | None):
    try:
        from PIL import Image
    except ImportError as exc:  # pragma: no cover - Pillow is declared
        raise SceneCriticError("Pillow is required to read captures") from exc
    try:
        with Image.open(path) as handle:
            image = handle.convert("RGB")
    except OSError as exc:
        raise SceneCriticError(f"could not read capture {path}: {exc}") from exc

    if viewport is None:
        return image
    width, height = image.size
    left, top, right, bottom = viewport
    box = (int(width * left), int(height * top), int(width * right), int(height * bottom))
    if box[2] - box[0] < 64 or box[3] - box[1] < 64:
        raise SceneCriticError(f"viewport crop of {path} leaves nothing to measure")
    return image.crop(box)


def _flat_fraction(image) -> float:
    """Fraction of the frame with no local variation, at any exposure.

    A blurred copy subtracted from the original leaves near-zero everywhere the
    image is a uniform plane. Sky and unbroken ground both land here, which is
    exactly the intent -- they are the two halves of a green plate.

    The threshold scales with local brightness, and that is not a refinement.
    The first version compared against a fixed `<= 2`, which made the number a
    reading of exposure: the same frame put through a brightness knob measured
    0.649 flat at gain 0.7 and 0.457 at gain 1.8 -- a 42% swing with not one
    pixel of structure changed. It cost this critic a real regression, scoring a
    darkened art pass as *less* detailed than the washed-out frame it replaced,
    because in an 8-bit image a fixed difference is a larger contrast ratio in
    the shadows than in the highlights.

    `26 * value / 128` is the same shape `_detail_density` has always used, and
    `_detail_density` is the control: across that same gain sweep it moved from
    0.0852 to 0.0790, which is the residual of the sweep itself rather than a
    verdict about the scene. Normalised at mid-grey, so a frame exposed like the
    calibration references measures what it always did.
    """

    from PIL import ImageChops, ImageFilter

    grey = image.convert("L")
    smooth = grey.filter(ImageFilter.GaussianBlur(3))
    variation = ImageChops.difference(grey, smooth)
    # A broad blur, not the 3px one: the threshold has to follow the exposure of
    # the region, and a 3px mean follows the detail it is meant to be judging.
    exposure = grey.filter(ImageFilter.GaussianBlur(24))
    threshold = exposure.point(lambda value: max(1, min(255, round(2.0 * value / 128.0))))
    flat = ImageChops.subtract(threshold, variation).point(
        lambda value: 255 if value > 0 else 0, mode="1"
    ).convert("L")

    # Sky is excluded from both sides of the ratio.
    #
    # A clear sky is smooth because skies are smooth, and counting it as
    # greybox means the ceiling doubles as a cap on how much sky a frame may
    # contain. At 0.34 that cap is about a third of the image, which no
    # ground-level shot of anything obeys. The measurement this number exists
    # to make -- "is the ground one unbroken plate, are the walls untextured"
    # -- is about what is under the horizon.
    #
    # Identified as the run of flat pixels reaching the top edge of each
    # column, so anything standing against the sky interrupts it and everything
    # below that silhouette counts as scene again. It cannot rescue an empty
    # world: the green plate's ground is flat too, and with its sky removed it
    # measures 0.97 rather than 0.98.
    width, height = image.size
    total = width * height
    if not total:
        return 0.0
    pixels = flat.tobytes()
    sky = 0
    sky_flat = 0
    for column in range(width):
        for row in range(height):
            if pixels[row * width + column] == 0:
                break
            sky += 1
            sky_flat += 1
    scene_total = total - sky
    if scene_total <= 0:
        # A frame that is nothing but sky. Flat by any reading of the word.
        return 1.0
    return (flat.histogram()[255] - sky_flat) / scene_total


def _detail_density(image) -> float:
    from PIL import ImageChops, ImageFilter

    grey = image.convert("L")
    local = grey.filter(ImageFilter.GaussianBlur(8))
    threshold = local.point(lambda value: max(8, min(255, int(26 * value / 128.0))))
    edges = grey.filter(ImageFilter.FIND_EDGES)
    strong = ImageChops.subtract(edges, threshold).point(
        lambda value: 255 if value > 0 else 0, mode="1"
    ).convert("L")
    total = image.size[0] * image.size[1]
    return strong.histogram()[255] / total if total else 0.0


def _hue_variety(image) -> int:
    hsv = image.convert("HSV")
    hue, saturation, _ = hsv.split()
    # Only pixels with enough saturation to read as a colour; grey has a hue and
    # it means nothing, so counting it inflates variety on a bare scene.
    mask = saturation.point(lambda value: 255 if value > 40 else 0, mode="1").convert("L")
    histogram = hue.histogram(mask=mask)
    total = sum(histogram) or 1
    buckets = [sum(histogram[index * 16:(index + 1) * 16]) for index in range(16)]
    return sum(1 for count in buckets if count >= total * 0.02)


def _clipped(image) -> float:
    """Fraction of pixels at or near full white in every channel.

    Measured per channel rather than on luminance: a surface can clip in red
    and green while blue still holds detail, and averaging hides it.
    """

    from PIL import ImageChops

    red, green, blue = image.split()
    darkest = ImageChops.darker(ImageChops.darker(red, green), blue)
    blown = darkest.point(lambda value: 255 if value >= 250 else 0, mode="1").convert("L")
    total = image.size[0] * image.size[1]
    return blown.histogram()[255] / total if total else 0.0


def _thirds_interest(image) -> float:
    """How much of the frame's detail sits away from dead centre.

    Composition, measured the only way a still frame allows: content placed on
    the thirds rather than centred is what separates a photograph from a
    snapshot, and a generated scene defaults to dead centre because that is
    where the origin is.
    """

    width, height = image.size
    third_x, third_y = width // 3, height // 3
    middle = image.crop((third_x, third_y, third_x * 2, third_y * 2))
    centre_detail = _detail_density(middle)
    whole = _detail_density(image)
    if whole <= 0:
        return 0.0
    # Fraction of detail *outside* the centre ninth, normalised by area.
    centre_share = (centre_detail * (third_x * third_y)) / (whole * width * height)
    return max(0.0, 1.0 - centre_share)


def _scale_coherence(image) -> float:
    """Whether the frame holds detail at more than one size.

    A scene built from one size of thing reads as a diagram. Measured as the
    ratio of fine detail to coarse: an image with only coarse edges is blocky,
    one with only fine edges is noise, and a real scene has both.
    """

    from PIL import ImageChops, ImageFilter

    grey = image.convert("L")
    # Both thresholds scale with local exposure, for the reason spelled out in
    # `_flat_fraction`: with fixed cuts the fine count tracked brightness (40k
    # edges at gain 0.7, 64k at gain 1.8) while the coarse count did not, so the
    # ratio between them read the exposure knob and reported it as art.
    exposure = grey.filter(ImageFilter.GaussianBlur(24))
    fine_cut = exposure.point(lambda v: max(2, min(255, round(30.0 * v / 128.0))))
    coarse_cut = exposure.point(lambda v: max(1, min(255, round(12.0 * v / 128.0))))
    fine = ImageChops.subtract(grey.filter(ImageFilter.FIND_EDGES), fine_cut).point(
        lambda v: 255 if v > 0 else 0, mode="1").convert("L")
    coarse = ImageChops.subtract(
        grey.filter(ImageFilter.GaussianBlur(4)).filter(ImageFilter.FIND_EDGES),
        coarse_cut).point(lambda v: 255 if v > 0 else 0, mode="1").convert("L")
    fine_count = fine.histogram()[255]
    coarse_count = coarse.histogram()[255]
    if fine_count + coarse_count == 0:
        return 0.0
    # 1.0 when the two are balanced, falling to 0 when either dominates.
    ratio = min(fine_count, coarse_count) / max(fine_count, coarse_count, 1)
    return ratio


def _silhouette_against_sky(image) -> float:
    """How broken the skyline is.

    The upper third of a frame is where a world's silhouette lives. A flat
    horizon there is the greybox signature no ground-level detail removes, and
    it is what walls, towers and canopy exist to fix.
    """

    width, height = image.size
    sky = image.crop((0, 0, width, height // 3))
    return _detail_density(sky)


def _luminance_spread(image) -> float:
    histogram = image.convert("L").histogram()
    total = sum(histogram) or 1
    mean = sum(v * c for v, c in enumerate(histogram)) / total
    variance = sum(((v - mean) ** 2) * c for v, c in enumerate(histogram)) / total
    return math.sqrt(variance)


def _verticality(image) -> float:
    """Detail sitting in the upper half, relative to the whole.

    A world with nothing standing up in it puts all of its structure below the
    horizon, and reads as a floor plan drawn in perspective.
    """

    width, height = image.size
    upper = image.crop((0, 0, width, height // 2))
    upper_detail = _detail_density(upper)
    whole = _detail_density(image)
    return upper_detail / whole if whole > 0 else 0.0


def _repetition(image) -> float:
    """How alike the two halves of the frame are.

    Crude on purpose. A scene assembled by scattering one prop across a plane is
    close to self-similar under a horizontal flip, and that is the specific
    failure worth catching: filled rather than composed.
    """

    from PIL import Image, ImageChops

    width, height = image.size
    size = (128, 128)
    left = image.crop((0, 0, width // 2, height)).resize(size, Image.BILINEAR).convert("L")
    right = image.crop((width // 2, 0, width, height)).resize(size, Image.BILINEAR).convert("L")
    difference = ImageChops.difference(left, right)
    histogram = difference.histogram()
    total = sum(histogram) or 1
    mean = sum(v * c for v, c in enumerate(histogram)) / total
    # Near-identical halves give a mean difference near zero.
    return max(0.0, 1.0 - mean / 64.0)


def _band(value: float, low: float, high: float, slack: float) -> float:
    if low <= value <= high:
        return 100.0
    distance = (low - value) if value < low else (value - high)
    return max(0.0, 100.0 * (1.0 - distance / max(slack, 1e-9)))


def _floor(value: float, floor: float, slack: float) -> float:
    if value >= floor:
        return 100.0
    return max(0.0, 100.0 * (1.0 - (floor - value) / max(slack, 1e-9)))


def _ceiling(value: float, ceiling: float, slack: float) -> float:
    if value <= ceiling:
        return 100.0
    return max(0.0, 100.0 * (1.0 - (value - ceiling) / max(slack, 1e-9)))


def gates(
    *,
    functional: bool,
    critique: "SceneCritique | None",
) -> dict[str, Any]:
    """The two verdicts, kept apart.

    A game can be complete and look unfinished, and the failure mode this
    prevents is a release gate that averages the two into one number nobody can
    act on. `FUNCTIONALLY_COMPLETE` is about systems: they exist, they run, they
    are wired. `VISUALLY_PRODUCTION_READY` is about a capture of the running
    game, and it fails closed -- no capture is not a pass.

    A game may sit at FUNCTIONALLY_COMPLETE / REVISE indefinitely, and that is
    the correct place for one that plays and still reads as greybox.
    """

    visual = "NOT_ASSESSED"
    if critique is not None:
        visual = critique.verdict

    return {
        "schemaVersion": 1,
        "functional": "FUNCTIONALLY_COMPLETE" if functional else "INCOMPLETE",
        "visual": visual,
        # Both, or neither. A release that ships on the functional gate alone is
        # how a working prototype reaches players looking like one.
        "releaseCandidate": functional and visual == "VISUALLY_PRODUCTION_READY",
        "visualScore": round(critique.overall, 2) if critique else None,
        "blocking": (
            []
            if critique is not None and critique.production_ready
            else (critique.remedies if critique is not None
                  else ["no capture of the running game, so nothing was assessed"])
        ),
        "note": (
            "a functional game that still reads as greybox stays in REVISE. The two "
            "gates are separate because averaging them produces a number nobody can act on"
        ),
    }


def critique_scene(
    frames: dict[str, Path] | Iterable[Path],
    *,
    viewport: tuple[float, float, float, float] | None = None,
) -> SceneCritique:
    """Score one or more captures of a running place.

    `viewport` crops away editor chrome as fractions of the frame. Without it the
    ribbon and the property panel are measured as part of the scene, and a busy
    editor makes an empty world look detailed -- which would make this critic
    report the opposite of the truth.
    """

    if not isinstance(frames, dict):
        frames = {Path(path).stem: Path(path) for path in frames}
    frames = {name: Path(path) for name, path in frames.items() if Path(path).is_file()}
    if not frames:
        # Fail closed, like every other gate here. A scene nobody captured has
        # not been looked at, and scoring it zero would be a verdict about the
        # game rather than about the process.
        raise SceneCriticError(
            "no captures to read; a scene nobody photographed cannot be called "
            "production ready, and absence of evidence is not a pass"
        )

    measurements: dict[str, Any] = {}
    findings: list[Finding] = []
    flat_scores, detail_scores, hue_scores = [], [], []
    spread_scores, vertical_scores, repeat_scores = [], [], []
    clip_scores: list[float] = []
    skyline_scores: list[float] = []
    scale_scores: list[float] = []
    thirds_scores: list[float] = []
    arch_scores: list[float] = []
    primitive_scores: list[float] = []
    hierarchy_scores: list[float] = []
    exposure_scores: list[float] = []

    for name in sorted(frames):
        image = _open(frames[name], viewport)
        flat = _flat_fraction(image)
        detail = _detail_density(image)
        hues = _hue_variety(image)
        spread = _luminance_spread(image)
        clipped = _clipped(image)
        thirds = _thirds_interest(image)
        scale = _scale_coherence(image)
        skyline = _silhouette_against_sky(image)
        vertical = _verticality(image)
        repeat = _repetition(image)
        extra = dimensions.measure(image)

        measurements[name] = {
            "flatArea": round(flat, 4),
            "detailDensity": round(detail, 4),
            "hueVariety": hues,
            "luminanceSpread": round(spread, 2),
            "clippedHighlights": round(clipped, 4),
            "thirdsInterest": round(thirds, 3),
            "scaleCoherence": round(scale, 3),
            "skylineBreak": round(skyline, 4),
            "verticality": round(vertical, 3),
            "repetition": round(repeat, 3),
            "size": list(image.size),
            **extra,
        }

        flat_scores.append(_ceiling(flat, FLAT_AREA_CEILING, 0.35))
        detail_scores.append(_floor(detail, DETAIL_DENSITY_FLOOR, DETAIL_DENSITY_FLOOR))
        hue_scores.append(_floor(hues, HUE_VARIETY_FLOOR, HUE_VARIETY_FLOOR))
        spread_scores.append(_floor(spread, LUMINANCE_SPREAD_FLOOR, LUMINANCE_SPREAD_FLOOR))
        clip_scores.append(_ceiling(clipped, CLIPPED_HIGHLIGHT_CEILING, 0.12))
        skyline_scores.append(_floor(skyline, SKYLINE_BREAK_FLOOR, SKYLINE_BREAK_FLOOR))
        thirds_scores.append(_floor(thirds, THIRDS_INTEREST_FLOOR, THIRDS_INTEREST_FLOOR))

        architecture = extra["architecturalRichness"]
        primitives = extra["primitiveAppearance"]
        hierarchy = extra["visualHierarchy"]
        arch_scores.append(_floor(
            architecture, ARCHITECTURAL_RICHNESS_FLOOR, ARCHITECTURAL_RICHNESS_FLOOR))
        primitive_scores.append(_ceiling(primitives, PRIMITIVE_APPEARANCE_CEILING, 0.35))
        hierarchy_scores.append(_ceiling(hierarchy, VISUAL_HIERARCHY_CEILING, 6.0))

        exposure = extra["exposureHealth"]
        exposure_scores.append(_ceiling(exposure, EXPOSURE_CLIPPING_CEILING, 0.30))
        if exposure > EXPOSURE_CLIPPING_CEILING:
            findings.append(Finding(
                "exposure", name,
                f"{exposure * 100:.0f}% of the frame is clipped to pure white "
                "-- that detail is gone, not bright",
                exposure, f"<= {EXPOSURE_CLIPPING_CEILING:.2f}",
                "bring the exposure down or the lights in: brightness above the "
                "display range is not brightness, it is missing information. "
                "Darkness is not this defect and is not scored",
            ))

        if architecture < ARCHITECTURAL_RICHNESS_FLOOR:
            findings.append(Finding(
                "architectural_richness", name,
                "almost nothing in this frame is built; the vertical edges a wall, "
                "a post or a tower makes are missing",
                architecture, f">= {ARCHITECTURAL_RICHNESS_FLOOR:.3f}",
                "put architecture in the view -- scatter density is not the same "
                "thing, and no number of rocks supplies it",
            ))
        if primitives > PRIMITIVE_APPEARANCE_CEILING:
            findings.append(Finding(
                "primitive_appearance", name,
                f"{primitives * 100:.0f}% of the frame is large flat untextured "
                "rectangles -- the development-primitive look",
                primitives, f"<= {PRIMITIVE_APPEARANCE_CEILING:.2f}",
                "break the big slabs: panelling, trim, material change or a kit "
                "part instead of one Part scaled up",
            ))
        if hierarchy > VISUAL_HIERARCHY_CEILING:
            findings.append(Finding(
                "composition", name,
                "all the contrast in the frame is in one place and the rest is "
                "empty -- a subject with no scene around it",
                hierarchy, f"<= {VISUAL_HIERARCHY_CEILING:.1f}",
                "fill the frame: the problem is not the subject, it is that "
                "nothing else in view carries any detail at all",
            ))

        # A frame with no horizon in it cannot report on a skyline. Scoring it
        # anyway blames the architecture for the camera angle, which is how a
        # correct fix reads as no change at all.
        lower = image.crop((0, image.size[1] // 2, image.size[0], image.size[1]))
        horizon_visible = _detail_density(lower) > HORIZON_VISIBLE_FLOOR * detail
        if not horizon_visible:
            skyline_scores[-1] = 100.0
            measurements[name]["skylineAssessed"] = False
        elif skyline < SKYLINE_BREAK_FLOOR:
            findings.append(Finding(
                "silhouette", name,
                "the skyline is nearly unbroken; nothing in this frame stands against sky",
                skyline, f">= {SKYLINE_BREAK_FLOOR:.3f}",
                "raise architecture into the upper third of the frame, or bring the "
                "camera down so what is already tall reads against the horizon",
            ))
        # No finding is raised from `scale` any more. It is still measured and
        # still reported alongside the others, but a metric that ranks an empty
        # plate above a built scene must not be allowed to say a built scene is
        # unfinished -- see UNSCORED.
        if thirds < THIRDS_INTEREST_FLOOR:
            findings.append(Finding(
                "composition", name,
                "the frame's interest is bunched at dead centre",
                thirds, f">= {THIRDS_INTEREST_FLOOR:.2f}",
                "compose off-centre: put the landmark on a third and let the "
                "circulation lead the eye across the frame",
            ))
        vertical_scores.append(_floor(vertical, VERTICALITY_FLOOR, VERTICALITY_FLOOR))
        repeat_scores.append(_ceiling(repeat, REPETITION_CEILING, 0.14))

        if flat > FLAT_AREA_CEILING:
            findings.append(Finding(
                "environment_density", name,
                f"{flat:.0%} of the frame is one unbroken plane -- the greybox signature",
                flat, f"<= {FLAT_AREA_CEILING:.0%}",
                "break the ground and sky planes: terrain relief, structures that "
                "occlude the horizon, and props at varied distances rather than a "
                "single flat expanse",
            ))
        if detail < DETAIL_DENSITY_FLOOR:
            findings.append(Finding(
                "environment_density", name,
                "almost nothing on screen carries surface detail",
                detail, f">= {DETAIL_DENSITY_FLOOR:.3f}",
                "replace primitive slabs with kit modules or meshes; a scene of "
                "untextured boxes reads as a test map at any resolution",
            ))
        if hues < HUE_VARIETY_FLOOR:
            findings.append(Finding(
                "material_richness", name,
                f"only {hues} distinct hues hold any real area",
                float(hues), f">= {HUE_VARIETY_FLOOR}",
                "widen the palette in use: a scene built from three roles reads as "
                "a diagram of a scene",
            ))
        if spread < LUMINANCE_SPREAD_FLOOR:
            findings.append(Finding(
                "material_richness", name,
                "the frame has almost no light-to-dark range",
                spread, f">= {LUMINANCE_SPREAD_FLOOR:.0f}",
                "add shadow and contrast: directional light with real shadows, "
                "darker recesses, and materials that are not all mid-value",
            ))
        if clipped > CLIPPED_HIGHLIGHT_CEILING:
            findings.append(Finding(
                "material_richness", name,
                f"{clipped:.0%} of the frame is blown to white, which destroys the "
                "detail, hue and material everything else here measures",
                clipped, f"<= {CLIPPED_HIGHLIGHT_CEILING:.0%}",
                "bring the light budget down rather than the exposure: emissive "
                "sized to read instead of to dominate, and point lights whose "
                "ranges do not overlap into one wash",
            ))
        if repeat > REPETITION_CEILING:
            findings.append(Finding(
                "composition", name,
                f"the two halves of the frame are {repeat:.0%} alike -- filled rather than composed",
                repeat, f"<= {REPETITION_CEILING:.0%}",
                "compose asymmetrically: one dominant landmark, varied region "
                "identities, and scatter that follows the layout rather than the frame",
            ))

    def mean(values: list[float]) -> float:
        return sum(values) / len(values) if values else 0.0

    scores = {
        "environment_density": mean([mean(flat_scores), mean(detail_scores)]),
        "composition": mean([
            mean(repeat_scores), mean(thirds_scores), mean(hierarchy_scores)]),
        "architectural_richness": mean(arch_scores),
        "primitive_appearance": mean(primitive_scores),
        "silhouette": mean(skyline_scores),
        "exposure": mean(exposure_scores),
        "material_richness": mean([mean(hue_scores), mean(spread_scores), mean(clip_scores)]),
    }
    overall = sum(scores[axis] * weight for axis, weight in AXIS_WEIGHTS.items())

    return SceneCritique(
        scores=scores, overall=overall, findings=findings, measurements=measurements,
    )
