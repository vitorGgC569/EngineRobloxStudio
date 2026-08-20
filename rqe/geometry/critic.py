"""The visual critic: what the renders say about the asset.

Topology validation answers "will Roblox accept this mesh". It cannot answer
"is this worth looking at", and those are different questions -- a watertight,
under-budget, correctly-unwrapped box passes every check in `validation.py` and
is still a box. This module closes that gap by reading the preview renders back
and measuring the three properties that separate a modelled asset from a
blocked-out one.

**Silhouette.** Read at distance and against a busy world, an asset is its
outline. The measures are how much shape that outline has, how its mass sits
vertically, and whether it reads differently from the front than from the side.
A form that is identical from every angle is a box with details painted on.

**Material separation.** Value range across the surface. An asset modelled with
care and then rendered as one flat tone has thrown away most of the work; the
measures are luminance spread and whether anything reads as a focal point.

**Detail distribution.** Where the modelling effort actually landed. Measured as
interior edge density -- the silhouette edge is deliberately excluded, because
against the background it is the strongest edge in the frame and would drown the
surface detail it is supposed to be measured against. The cross-view spread is
what catches the classic failure: a detailed front and a bare back.

Every threshold here is a module constant with a stated rationale, calibrated
against the reference ladder documented in `CALIBRATION` and never against the
asset being judged -- a bar fitted to its own candidate is not a bar. Metrics
that failed to order that ladder are measured and reported but not scored, and
which ones those are is recorded rather than quietly dropped.

The scores are not taste. This measures composition defects, so 90 means
"nothing measurably wrong", never "good". Style, appeal, and whether it reads as
steampunk are not in scope and are not claimed.

Pillow only. numpy is not a declared dependency of this project, and a critic
that runs on a workstation and fails in the container is not part of the
pipeline.
"""

from __future__ import annotations

import math
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Iterable


# --------------------------------------------------------------- thresholds

#: Per-channel distance from the background before a pixel counts as the asset.
#: The preview world is a flat colour, so the true background is uniform; this
#: only has to survive render sampling noise.
BACKGROUND_TOLERANCE = 12

#: A mask outside this band is not an asset in frame -- it is a framing failure,
#: and scoring it would produce confident numbers about nothing.
MASK_MIN_COVERAGE = 0.005
MASK_MAX_COVERAGE = 0.98

#: Where the numbers below come from.
#:
#: A ladder of four assets built by this same pipeline, ordered worst to best
#: *by construction* before anything was measured: a bare cube, the same form
#: articulated into three stacked volumes, that form again with three
#: contrasting materials, and a fully detailed machine with ribs, vents, a rear
#: panel and pipes. A bare cube is definitionally an unmodelled asset; if a
#: metric cannot separate it from the machine, the metric is wrong.
#:
#: This matters more than the numbers. A threshold fitted to the asset being
#: judged is not a threshold, so none of these is derived from a candidate --
#: they are the midpoints of separations measured on references whose quality
#: was known in advance. Three of the metrics originally proposed for this
#: module (frame coverage, distinct tone count, empty-cell count) failed to
#: order the ladder at all and are measured and reported but deliberately not
#: scored; inventing a bar for a metric that does not discriminate would have
#: produced confident numbers about nothing.
CALIBRATION = {
    "ladder": ("bare cube", "articulated stack", "stack + 3 materials", "detailed machine"),
    "silhouetteShape": (1.36, 2.05, 2.05, 2.65),
    "massBalance": (0.92, 2.12, 2.12, 2.15),
    "luminanceSpread": (28.6, 28.8, 71.0, 72.0),
    "focalContrast": (40.8, 31.8, 71.2, 97.0),
    "edgeDensity": (0.0064, 0.0288, 0.0295, 0.0478),
    "crossViewIou": (1.000, 1.000, 1.000, 0.874),
    "viewBalance": (0.06, 0.64, 0.88, 0.79),
    "unscored": ("coverage", "tones", "emptyCells"),
}

#: Isoperimetric quotient, perimeter^2 / (4*pi*area). A circle is 1.0 and a
#: square about 1.27; the measured cube sits at 1.36 and the articulated forms
#: at 2.05 and above, so the floor goes between them.
#:
#: The ceiling is honestly uncalibrated: the ladder contains no asset that is
#: too noisy, so it is set wide enough to catch only genuine fragmentation
#: rather than pretending to a precision nothing here established.
SILHOUETTE_SHAPE_BAND = (1.60, 8.0)

#: Bottom-third mask area over top-third mask area. The document's own example
#: complaint -- "base visually too heavy" -- is this number being large. The
#: ladder's deliberately tapering forms measure 2.12 to 2.15 and that is sound
#: design, so the ceiling sits above them and catches only genuine bottom
#: loading.
MASS_BALANCE_BAND = (0.5, 2.8)

#: Intersection-over-union between the front and side silhouettes, each
#: normalised to its own bounding box. The cube and both square-in-plan stacks
#: measure exactly 1.000; the asymmetric machine measures 0.874.
#:
#: Reported as a hint rather than a defect, and weighted lightly. A barrel or a
#: column is legitimately identical from front and side, and this measurement
#: cannot tell that apart from a box with details painted on.
CROSS_VIEW_IOU_CEILING = 0.93

#: Luminance standard deviation across the asset's surface, 0-255. The two
#: single-material rungs measure 28.6 and 28.8; the two multi-material rungs
#: measure 71.0 and 72.0. A clean separation, so the floor goes in the middle.
LUMINANCE_SPREAD_BAND = (45.0, 140.0)

#: Distinct tones: 16-bin luminance histogram, counting bins holding at least
#: 4% of the surface. Measured and reported, *not* scored: the ladder spans only
#: 5.0 to 6.4 across it, so it mostly registers shading rather than materials.
TONE_COUNT_FLOOR = 4

#: 95th percentile minus median luminance. The document's "central reactor lacks
#: focal contrast" is this number being small: nothing on the asset pulls the
#: eye. Rungs without an emissive focal point measure 31.8 and 40.8; rungs with
#: one measure 71.2 and 97.0.
FOCAL_CONTRAST_FLOOR = 50.0

#: Luminance step that counts as a modelled edge, quoted at mid grey and scaled
#: to the surface's own brightness at measurement time. Below this is shading
#: across a curve rather than a break in the form.
EDGE_CONTRAST = 26.0

#: Radius, in pixels, over which "local" brightness is taken for that scaling.
#: Wide enough to span a material patch, narrow enough that a rib and its
#: shadow do not average each other away.
EDGE_LOCALITY = 8.0

#: Fraction of interior pixels carrying a significant gradient. The bare cube
#: measures 0.0064 and the modelled rungs 0.0288 to 0.0478, so the floor goes
#: between them. The ceiling is uncalibrated -- no rung is over-detailed -- and
#: is set only to catch surfaces so busy they shimmer at draw distance.
EDGE_DENSITY_BAND = (0.015, 0.25)

#: Weakest view's edge density over the mean across views. The classic failure
#: this catches is a detailed front and an untouched back: the bare cube scores
#: 0.06 here, where the modelled rungs score 0.64 to 0.88.
VIEW_BALANCE_FLOOR = 0.42

#: Of nine cells over the asset's bounding box, how many may be effectively
#: bare. Measured and reported, *not* scored: on the ladder the most detailed
#: asset had more bare cells than the least, so this does not discriminate.
MAX_EMPTY_CELLS = 3

#: Overall score at or above which an asset carries no measured composition
#: defect. The document's worked example approves at 91 and revises at 78/61/83.
APPROVAL_SCORE = 85.0

#: Axis weights. Silhouette leads because it is the only property that survives
#: distance, and Roblox assets are mostly seen at distance.
AXIS_WEIGHTS = {
    "silhouette": 0.42,
    "material_separation": 0.28,
    "detail_distribution": 0.30,
}


class CriticError(RuntimeError):
    """The renders could not be read, so nothing can be said about them."""


# ------------------------------------------------------------------ results


@dataclass(frozen=True)
class Problem:
    """One measured defect, and the change that would answer it."""

    axis: str
    view: str
    finding: str
    measured: float
    expected: str
    revision: str
    blocking: bool = False

    def to_dict(self) -> dict[str, Any]:
        return {
            "axis": self.axis,
            "view": self.view,
            "finding": self.finding,
            "measured": round(self.measured, 4),
            "expected": self.expected,
            "revision": self.revision,
            "blocking": self.blocking,
        }


@dataclass
class Critique:
    scores: dict[str, float]
    overall: float
    problems: list[Problem] = field(default_factory=list)
    measurements: dict[str, Any] = field(default_factory=dict)
    views: tuple[str, ...] = ()

    @property
    def approved(self) -> bool:
        return self.overall >= APPROVAL_SCORE and not any(p.blocking for p in self.problems)

    @property
    def verdict(self) -> str:
        return "APPROVED" if self.approved else "REVISE"

    @property
    def revisions(self) -> list[str]:
        """Deduplicated, worst first. This is what goes back to the modeller."""

        seen: dict[str, float] = {}
        for problem in sorted(self.problems, key=lambda p: (not p.blocking, p.axis)):
            seen.setdefault(problem.revision, problem.measured)
        return list(seen)

    def to_dict(self) -> dict[str, Any]:
        return {
            "schemaVersion": 1,
            "verdict": self.verdict,
            "overall": round(self.overall, 2),
            "approvalScore": APPROVAL_SCORE,
            "scores": {key: round(value, 2) for key, value in self.scores.items()},
            "weights": dict(AXIS_WEIGHTS),
            "views": list(self.views),
            "problems": [problem.to_dict() for problem in self.problems],
            "revisions": self.revisions,
            "measurements": self.measurements,
            "scope": (
                "measures composition defects in the renders -- silhouette, value "
                "separation, detail placement. It does not judge style or appeal, "
                "so a high score means nothing measurably wrong, not good."
            ),
        }

    def summary(self) -> str:
        lines = [
            f"{self.verdict}  overall {self.overall:.0f}/100"
            f" (approves at {APPROVAL_SCORE:.0f})",
        ]
        for axis, value in self.scores.items():
            lines.append(f"  {axis:<22s} {value:5.1f}")
        if self.problems:
            lines.append("problems:")
            for problem in self.problems:
                mark = "!" if problem.blocking else "-"
                lines.append(f"  {mark} [{problem.view}] {problem.finding}")
            lines.append("revisions:")
            for revision in self.revisions:
                lines.append(f"  * {revision}")
        return "\n".join(lines)


# ------------------------------------------------------------ image helpers
#
# Everything below stays inside Pillow's C-level operations. A 768x768 render is
# 590k pixels and five of them is three million; a per-pixel Python loop turns a
# critic that should cost a second into one that costs a minute, and a critic
# nobody waits for does not get run.


def _open(path: Path):
    """Return (rgb, alpha-or-None). Alpha is the exact mask when it exists."""

    try:
        from PIL import Image
    except ImportError as exc:  # pragma: no cover - Pillow is a declared dep
        raise CriticError("Pillow is required to read renders") from exc
    try:
        with Image.open(path) as handle:
            loaded = handle.convert("RGBA")
    except OSError as exc:
        raise CriticError(f"could not read render {path}: {exc}") from exc

    alpha = loaded.getchannel("A")
    # A fully opaque alpha carries no information -- it is a screenshot, or a
    # render made before transparent film. Say so rather than masking the whole
    # frame as asset.
    low, high = alpha.getextrema()
    return loaded.convert("RGB"), (alpha if low < 250 else None)


def _background_colour(image) -> tuple[int, int, int]:
    """The preview world colour, taken from the corners.

    Sampled rather than assumed. The renderer's world colour is configuration
    that can change, and a hardcoded background silently masks the whole frame
    the day somebody edits it.
    """

    width, height = image.size
    inset = max(2, min(width, height) // 100)
    corners = [
        image.getpixel((inset, inset)),
        image.getpixel((width - 1 - inset, inset)),
        image.getpixel((inset, height - 1 - inset)),
        image.getpixel((width - 1 - inset, height - 1 - inset)),
    ]
    # Median per channel: an asset overlapping one corner cannot outvote three.
    return tuple(sorted(channel)[1] for channel in zip(*corners))  # type: ignore[return-value]


def _mask(image, background: tuple[int, int, int]):
    """Binary asset mask: 255 where the frame differs from the background."""

    from PIL import Image, ImageChops

    flat = Image.new("RGB", image.size, background)
    difference = ImageChops.difference(image, flat)
    red, green, blue = difference.split()
    # Max across channels, not luminance. `convert("L")` weights blue at 7%, so
    # a blue emissive panel against grey would read as background.
    strongest = ImageChops.lighter(ImageChops.lighter(red, green), blue)
    return strongest.point(lambda value: 255 if value > BACKGROUND_TOLERANCE else 0, mode="1").convert("L")


def _count(mask) -> int:
    return mask.histogram()[255]


def _bounding_box(mask) -> tuple[int, int, int, int] | None:
    return mask.getbbox()


def _erode(mask, radius: int = 3):
    from PIL import ImageFilter

    return mask.filter(ImageFilter.MinFilter(radius))


def _perimeter(mask) -> int:
    from PIL import ImageChops

    return _count(ImageChops.difference(mask, _erode(mask, 3)))


def _percentile(histogram: list[int], fraction: float) -> float:
    total = sum(histogram)
    if total == 0:
        return 0.0
    target = total * fraction
    running = 0
    for value, count in enumerate(histogram):
        running += count
        if running >= target:
            return float(value)
    return float(len(histogram) - 1)


def _band(value: float, low: float, high: float, *, slack: float | None = None) -> float:
    """100 inside the band, falling to 0 one slack-width outside it.

    Linear rather than a cliff. A hard pass/fail at the edge makes a score jump
    from 100 to 0 over a rounding error, and an asset that oscillates across
    that edge produces a revision loop that never converges.
    """

    if low <= value <= high:
        return 100.0
    width = slack if slack is not None else max(high - low, 1e-9)
    distance = (low - value) if value < low else (value - high)
    return max(0.0, 100.0 * (1.0 - distance / width))


def _floor_score(value: float, floor: float, *, slack: float | None = None) -> float:
    if value >= floor:
        return 100.0
    width = slack if slack is not None else floor
    return max(0.0, 100.0 * (1.0 - (floor - value) / width))


# ---------------------------------------------------------------- per-view


@dataclass
class _ViewMetrics:
    name: str
    coverage: float
    shape: float
    mass_balance: float
    luminance_spread: float
    tones: int
    focal_contrast: float
    edge_density: float
    empty_cells: int
    interior_pixels: int
    mask_source: str = "alpha"


def _measure_view(name: str, path: Path) -> tuple[_ViewMetrics, Any]:
    from PIL import ImageChops, ImageFilter

    image, alpha = _open(path)
    width, height = image.size
    frame = width * height
    if alpha is not None:
        # Exact. The renderer knows what is object and what is not; nothing here
        # has to be inferred from colour.
        mask = alpha.point(lambda value: 255 if value > 127 else 0, mode="1").convert("L")
        mask_source = "alpha"
    else:
        mask = _mask(image, _background_colour(image))
        mask_source = "background-key"

    covered = _count(mask)
    coverage = covered / frame if frame else 0.0
    if not MASK_MIN_COVERAGE <= coverage <= MASK_MAX_COVERAGE:
        raise CriticError(
            f"view {name!r} has {coverage:.1%} of the frame covered by the asset, "
            f"which is outside [{MASK_MIN_COVERAGE:.1%}, {MASK_MAX_COVERAGE:.1%}]. "
            "Either the render is empty or the background is not a flat colour; "
            "either way nothing measured from it would mean anything."
        )

    perimeter = _perimeter(mask)
    shape = (perimeter * perimeter) / (4.0 * math.pi * covered) if covered else 0.0

    box = _bounding_box(mask) or (0, 0, width, height)
    left, top, right, bottom = box
    box_height = max(bottom - top, 1)
    third = max(box_height // 3, 1)
    lower = _count(mask.crop((left, bottom - third, right, bottom)))
    upper = _count(mask.crop((left, top, right, top + third)))
    mass_balance = lower / upper if upper else float("inf")

    # Interior only. The outline against the background is the strongest edge in
    # the frame; leaving it in would let a featureless box score as detailed.
    interior = _erode(mask, 5)
    interior_pixels = _count(interior)
    if interior_pixels < 64:
        # Too thin to have an interior -- a wire or a plane seen edge-on.
        interior, interior_pixels = mask, covered

    grey = image.convert("L")
    histogram = grey.histogram(mask=interior)
    total = sum(histogram) or 1
    mean = sum(value * count for value, count in enumerate(histogram)) / total
    variance = sum(((value - mean) ** 2) * count for value, count in enumerate(histogram)) / total
    luminance_spread = math.sqrt(variance)

    bins = [sum(histogram[index * 16:(index + 1) * 16]) for index in range(16)]
    tones = sum(1 for count in bins if count >= total * 0.04)
    focal_contrast = _percentile(histogram, 0.95) - _percentile(histogram, 0.50)

    # Locally adaptive threshold, Weber-style. A dark material compresses every
    # gradient on it, so a fixed threshold measures how light the materials are
    # rather than how much was modelled -- two rungs of the calibration ladder
    # with identical geometry and different materials came back 2x apart. A
    # single whole-view mean does not fix it either: on an asset with a dark
    # base and a light body, the light body sets the mean and the base stays
    # under-measured. The threshold has to follow the surface.
    #
    # Scaling the threshold rather than stretching the image, because a stretch
    # amplifies whatever contrast exists -- a bare cube's three flat faces
    # became the most "detailed" surface in the ladder. A flat face has no
    # gradient to scale, so this leaves it at zero, where it belongs.
    local_mean = grey.filter(ImageFilter.GaussianBlur(EDGE_LOCALITY))
    local_threshold = local_mean.point(
        lambda value: max(8, min(255, int(EDGE_CONTRAST * value / 128.0)))
    )
    edges = grey.filter(ImageFilter.FIND_EDGES)
    strong = ImageChops.subtract(edges, local_threshold).point(
        lambda value: 255 if value > 0 else 0, mode="1"
    ).convert("L")
    strong = ImageChops.darker(strong, interior)
    edge_pixels = _count(strong)
    edge_density = edge_pixels / interior_pixels if interior_pixels else 0.0

    # Nine cells over the bounding box. A cell holding real asset but almost no
    # gradient is a face nobody modelled.
    cell_width = max((right - left) // 3, 1)
    cell_height = max((bottom - top) // 3, 1)
    densities: list[float] = []
    for row in range(3):
        for column in range(3):
            cell = (
                left + column * cell_width,
                top + row * cell_height,
                left + (column + 1) * cell_width if column < 2 else right,
                top + (row + 1) * cell_height if row < 2 else bottom,
            )
            occupancy = _count(interior.crop(cell))
            if occupancy < interior_pixels * 0.02:
                continue  # mostly background; not the modeller's omission
            densities.append(_count(strong.crop(cell)) / occupancy)
    reference = (sum(densities) / len(densities)) if densities else 0.0
    empty_cells = sum(1 for density in densities if density < reference * 0.25)

    metrics = _ViewMetrics(
        name=name,
        coverage=coverage,
        shape=shape,
        mass_balance=mass_balance,
        luminance_spread=luminance_spread,
        tones=tones,
        focal_contrast=focal_contrast,
        edge_density=edge_density,
        empty_cells=empty_cells,
        interior_pixels=interior_pixels,
        mask_source=mask_source,
    )
    return metrics, mask


def _normalised_silhouette(mask, size: int = 128):
    """The outline scaled to a common box, so shapes compare rather than sizes."""

    from PIL import Image

    box = mask.getbbox()
    if box is None:
        return Image.new("L", (size, size), 0)
    return mask.crop(box).resize((size, size), Image.NEAREST)


def _iou(first, second) -> float:
    from PIL import ImageChops

    intersection = _count(ImageChops.darker(first, second))
    union = _count(ImageChops.lighter(first, second))
    return intersection / union if union else 0.0


# ------------------------------------------------------------------- critic


#: Which views to read, and which pairs must differ from each other. Only front
#: against left is compared: front against back is often legitimately similar on
#: a symmetric asset, and flagging that would punish correct modelling.
CROSS_VIEW_PAIRS = (("front", "left"),)


def critique(previews: dict[str, Path] | Iterable[Path]) -> Critique:
    """Score an asset from its preview renders.

    `previews` is either a mapping of view name to path, or an iterable of paths
    whose stems name the views.
    """

    if not isinstance(previews, dict):
        previews = {Path(path).stem: Path(path) for path in previews}
    previews = {name: Path(path) for name, path in previews.items() if Path(path).is_file()}

    if not previews:
        # Fail closed. An asset with no renders has not been looked at, and
        # scoring it zero-by-default is the only reading that cannot be gamed
        # by deleting the evidence.
        raise CriticError(
            "no preview renders to read; an asset nobody rendered cannot be "
            "approved, and absence of evidence is not a pass"
        )

    metrics: dict[str, _ViewMetrics] = {}
    masks: dict[str, Any] = {}
    for name in sorted(previews):
        measured, mask = _measure_view(name, previews[name])
        metrics[name] = measured
        masks[name] = mask

    problems: list[Problem] = []
    views = tuple(metrics)

    # -- silhouette ------------------------------------------------------
    #
    # Coverage is measured but not scored. It is set by where the renderer puts
    # the camera, not by the asset: across the calibration ladder it varied from
    # 0.18 to 0.27 on assets whose quality differed enormously. Scoring it would
    # grade the harness and call it the asset.
    shape_scores: list[float] = []
    mass_scores: list[float] = []
    for name, view in metrics.items():
        shape_scores.append(_band(view.shape, *SILHOUETTE_SHAPE_BAND, slack=1.2))
        finite_mass = min(view.mass_balance, 99.0)
        mass_scores.append(_band(finite_mass, *MASS_BALANCE_BAND, slack=2.0))

        if view.shape < SILHOUETTE_SHAPE_BAND[0]:
            problems.append(Problem(
                "silhouette", name,
                "the outline is close to a plain rectangle, with no shape to read at distance",
                view.shape, f">= {SILHOUETTE_SHAPE_BAND[0]:.2f}",
                "break the outline: extrude secondary forms, or bevel and inset the "
                "primary volume so it stops reading as a box",
            ))
        elif view.shape > SILHOUETTE_SHAPE_BAND[1]:
            problems.append(Problem(
                "silhouette", name,
                "the outline is fragmented into noise rather than a readable form",
                view.shape, f"<= {SILHOUETTE_SHAPE_BAND[1]:.2f}",
                "consolidate protruding detail; join or remove small pieces that break "
                "the outline without adding to the form",
            ))
        if finite_mass > MASS_BALANCE_BAND[1]:
            problems.append(Problem(
                "silhouette", name,
                f"the base carries {finite_mass:.1f}x the visual mass of the top and reads as heavy",
                finite_mass, f"<= {MASS_BALANCE_BAND[1]:.1f}",
                "narrow the base, or raise and enlarge the upper form, to move mass upward",
            ))
        elif finite_mass < MASS_BALANCE_BAND[0]:
            problems.append(Problem(
                "silhouette", name,
                "the form is top-heavy and reads as unstable",
                finite_mass, f">= {MASS_BALANCE_BAND[0]:.2f}",
                "widen the base or add supports so the form reads as grounded",
            ))

    distinct_scores: list[float] = []
    for first, second in CROSS_VIEW_PAIRS:
        if first in masks and second in masks:
            overlap = _iou(_normalised_silhouette(masks[first]), _normalised_silhouette(masks[second]))
            distinct_scores.append(
                100.0 if overlap <= CROSS_VIEW_IOU_CEILING
                else max(0.0, 100.0 * (1.0 - (overlap - CROSS_VIEW_IOU_CEILING) / 0.14))
            )
            if overlap > CROSS_VIEW_IOU_CEILING:
                problems.append(Problem(
                    "silhouette", f"{first}|{second}",
                    f"the {first} and {second} outlines are {overlap:.0%} identical, "
                    "so the asset presents the same shape from every angle",
                    overlap, f"<= {CROSS_VIEW_IOU_CEILING:.0%}",
                    "differentiate the axes: the depth profile should not match the width "
                    "profile. Extrude or inset along one axis only",
                ))

    # Distinctness is folded in at a quarter weight: a radially symmetric asset
    # scores badly on it for a reason that is not a defect, so it may nudge a
    # score but must never decide one on its own.
    silhouette = _mean([_mean(shape_scores), _mean(mass_scores)])
    if distinct_scores:
        silhouette = silhouette * 0.75 + _mean(distinct_scores) * 0.25

    # -- material separation ---------------------------------------------
    spread_scores: list[float] = []
    focal_scores: list[float] = []
    for name, view in metrics.items():
        spread_scores.append(_band(view.luminance_spread, *LUMINANCE_SPREAD_BAND, slack=26.0))
        focal_scores.append(_floor_score(view.focal_contrast, FOCAL_CONTRAST_FLOOR, slack=42.0))

        if view.luminance_spread < LUMINANCE_SPREAD_BAND[0]:
            problems.append(Problem(
                "material_separation", name,
                "the surface reads as a single flat value, so assigned materials are not separating",
                view.luminance_spread, f">= {LUMINANCE_SPREAD_BAND[0]:.0f}",
                "assign materials with real value contrast between them -- a dark and a "
                "light are what make the parts readable, not two mid tones",
            ))
        if view.focal_contrast < FOCAL_CONTRAST_FLOOR:
            problems.append(Problem(
                "material_separation", name,
                "nothing on the asset pulls the eye; it has no focal point",
                view.focal_contrast, f">= {FOCAL_CONTRAST_FLOOR:.0f}",
                "give the functional centre an emissive or high-value material so the "
                "eye lands on what the asset is for",
            ))

    material_separation = _mean([_mean(spread_scores), _mean(focal_scores)])

    # -- detail distribution ---------------------------------------------
    density_scores: list[float] = []
    for name, view in metrics.items():
        density_scores.append(_band(view.edge_density, *EDGE_DENSITY_BAND, slack=0.12))
        if view.edge_density < EDGE_DENSITY_BAND[0]:
            problems.append(Problem(
                "detail_distribution", name,
                "the surface carries almost no modelled detail",
                view.edge_density, f">= {EDGE_DENSITY_BAND[0]:.3f}",
                f"add surface detail on the {name}: inset panels, extruded ribs or "
                "greebles sized to be legible at gameplay distance",
            ))
        elif view.edge_density > EDGE_DENSITY_BAND[1]:
            problems.append(Problem(
                "detail_distribution", name,
                "the surface is uniformly busy, which turns to shimmer at distance",
                view.edge_density, f"<= {EDGE_DENSITY_BAND[1]:.2f}",
                "remove high-frequency detail and keep contrast at the scale that "
                "survives distance",
            ))

    densities = {name: view.edge_density for name, view in metrics.items()}
    balance = 100.0
    if len(densities) > 1:
        average = _mean(list(densities.values()))
        weakest = min(densities, key=densities.get)  # type: ignore[arg-type]
        ratio = (densities[weakest] / average) if average else 0.0
        balance = _floor_score(ratio, VIEW_BALANCE_FLOOR, slack=VIEW_BALANCE_FLOOR)
        if ratio < VIEW_BALANCE_FLOOR:
            problems.append(Problem(
                "detail_distribution", weakest,
                f"the {weakest} carries {ratio:.0%} of the detail the other views do, "
                "so it reads as unfinished",
                ratio, f">= {VIEW_BALANCE_FLOOR:.0%}",
                f"model the {weakest}: it is currently a flat face behind a detailed "
                "front. A service panel, vents or structural ribs are enough",
            ))

    detail_distribution = _mean([_mean(density_scores), balance])

    scores = {
        "silhouette": silhouette,
        "material_separation": material_separation,
        "detail_distribution": detail_distribution,
    }
    overall = sum(scores[axis] * weight for axis, weight in AXIS_WEIGHTS.items())

    measurements = {
        name: {
            "coverage": round(view.coverage, 4),
            "silhouetteShape": round(view.shape, 3),
            "massBalance": round(min(view.mass_balance, 99.0), 3),
            "luminanceSpread": round(view.luminance_spread, 2),
            "tones": view.tones,
            "focalContrast": round(view.focal_contrast, 2),
            "edgeDensity": round(view.edge_density, 4),
            "emptyCells": view.empty_cells,
        }
        for name, view in metrics.items()
    }
    if len(densities) > 1:
        measurements["_crossView"] = {
            "weakestView": min(densities, key=densities.get),  # type: ignore[arg-type]
            "edgeDensityByView": {name: round(value, 4) for name, value in densities.items()},
        }

    return Critique(
        scores=scores,
        overall=overall,
        problems=problems,
        measurements=measurements,
        views=views,
    )


def _mean(values: list[float]) -> float:
    return sum(values) / len(values) if values else 0.0


def critique_package(package: Any) -> Critique:
    """Score an `AssetPackage` from the previews it already carries."""

    previews = {path.stem: path for path in package.previews()}
    return critique(previews)
