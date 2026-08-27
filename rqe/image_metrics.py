"""Measurements a screenshot can prove on its own, with no vision model.

Why this exists
---------------

The release gate wants a structured visual review, and the only provider that
could produce one needed an OpenAI key. Without one the review is missing, the
gate blocks, and every game in the repository fails on the same requirement --
so the visual half of validation has never run for anybody who does not have
that credential.

Meanwhile the defects that actually shipped were these:

  * a game about darkness whose ground was brighter than its lamps;
  * a player character blown out to a white blur by bloom plus overlapping
    lights;
  * a HUD hidden behind Roblox's own topbar.

Two of those three are arithmetic on pixels. Not judgement, not taste --
arithmetic. A histogram answers "is the floor brighter than the light sources"
and "how much of this frame is clipped to white" in milliseconds, and both
answers are the same every time anybody asks.

What this is not
----------------

It is not a substitute for someone looking. It cannot tell you the composition
is dull, the colours clash, or the silhouette reads badly. Those need a vision
model or a person, and the provider built on this says so per criterion rather
than quietly grading what it did not examine.
"""

from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path
from typing import Any

import numpy as np
from PIL import Image

#: Rec. 709 luma weights. Perceptual rather than a flat mean: green carries most
#: of the brightness a person sees, and averaging the channels equally reports a
#: saturated blue as far brighter than it looks.
_LUMA = np.array([0.2126, 0.7152, 0.0722], dtype=np.float32)

#: Above this a pixel is at or near the top of the display range and carries no
#: detail. Not 1.0: bloom and tonemapping land pixels a hair under white, and
#: they are just as blown out.
CLIPPED_ABOVE = 0.96

#: Below this a pixel is crushed to black, and detail there is gone too.
CRUSHED_BELOW = 0.02


@dataclass(frozen=True)
class ImageMetrics:
    """What one frame measures. Every field is reproducible from the file."""

    width: int
    height: int
    mean_luminance: float
    median_luminance: float
    contrast: float
    clipped_fraction: float
    crushed_fraction: float
    #: Mean luminance of the bottom third, which in a third-person game is
    #: almost always ground.
    lower_luminance: float
    #: Mean of the brightest 1% of pixels -- the light sources, if any.
    highlight_luminance: float
    #: Distinct hues holding at least 1% of the frame. A world built from three
    #: greys reports three.
    hue_variety: int
    #: Fraction of pixels on an edge. Low means flat or empty; very high means
    #: noise.
    edge_density: float

    def to_dict(self) -> dict[str, Any]:
        return {
            "width": self.width,
            "height": self.height,
            "meanLuminance": round(self.mean_luminance, 4),
            "medianLuminance": round(self.median_luminance, 4),
            "contrast": round(self.contrast, 4),
            "clippedFraction": round(self.clipped_fraction, 4),
            "crushedFraction": round(self.crushed_fraction, 4),
            "lowerLuminance": round(self.lower_luminance, 4),
            "highlightLuminance": round(self.highlight_luminance, 4),
            "hueVariety": self.hue_variety,
            "edgeDensity": round(self.edge_density, 4),
        }


def _luminance(rgb: np.ndarray) -> np.ndarray:
    return (rgb @ _LUMA).astype(np.float32)


def measure(path: Path | str) -> ImageMetrics:
    """Read one image and measure it. Raises if it cannot be opened."""
    with Image.open(path) as handle:
        frame = handle.convert("RGB")
        rgb = np.asarray(frame, dtype=np.float32) / 255.0
        hsv = np.asarray(frame.convert("HSV"), dtype=np.float32)

    height, width = rgb.shape[0], rgb.shape[1]
    luma = _luminance(rgb)
    flat = luma.reshape(-1)

    #: The brightest 1%, which is where lamps, the sun and specular hits live.
    #: A mean over the whole frame cannot distinguish a bright scene from a
    #: dark scene containing bright lights, and that distinction is the point.
    cutoff = max(1, int(flat.size * 0.01))
    highlights = np.partition(flat, -cutoff)[-cutoff:]

    lower_band = luma[int(height * 2 / 3):, :]

    #: Hue histogram over pixels with enough saturation and value to have a
    #: hue at all. Grey has a hue and it means nothing.
    hue, sat, val = hsv[..., 0], hsv[..., 1], hsv[..., 2]
    coloured = (sat > 40) & (val > 30)
    variety = 0
    if coloured.any():
        counts, _ = np.histogram(hue[coloured], bins=18, range=(0, 256))
        variety = int((counts > coloured.sum() * 0.01).sum())

    #: Sobel magnitude, thresholded. Detail, not aesthetics: an empty plain and
    #: a dense street differ here by an order of magnitude.
    gy, gx = np.gradient(luma)
    edges = np.hypot(gx, gy)

    return ImageMetrics(
        width=width,
        height=height,
        mean_luminance=float(flat.mean()),
        median_luminance=float(np.median(flat)),
        contrast=float(flat.std()),
        clipped_fraction=float((flat >= CLIPPED_ABOVE).mean()),
        crushed_fraction=float((flat <= CRUSHED_BELOW).mean()),
        lower_luminance=float(lower_band.mean()) if lower_band.size else 0.0,
        highlight_luminance=float(highlights.mean()),
        hue_variety=variety,
        edge_density=float((edges > 0.08).mean()),
    )


# ------------------------------------------------------------------ verdicts

@dataclass(frozen=True)
class Verdict:
    """One measurable judgement: a grade 1..5 and why."""

    grade: int
    rationale: str


def exposure(metrics: ImageMetrics) -> Verdict:
    """Is the frame blown out, crushed, or neither.

    The blown-out case is the one that shipped: bloom at 1.05 plus four
    overlapping lights turned a player into a white blur, and nothing in the
    toolchain noticed because nothing was looking.
    """
    clipped = metrics.clipped_fraction
    crushed = metrics.crushed_fraction
    if clipped > 0.12:
        return Verdict(1, f"{clipped:.0%} of the frame is clipped to white; "
                          "detail there is gone")
    if clipped > 0.05:
        return Verdict(2, f"{clipped:.0%} of the frame is clipped to white")
    if crushed > 0.45:
        return Verdict(2, f"{crushed:.0%} of the frame is crushed to black")
    if clipped > 0.02 or crushed > 0.25:
        return Verdict(3, f"{clipped:.0%} clipped, {crushed:.0%} crushed")
    return Verdict(4, f"exposure is inside range: {clipped:.1%} clipped, "
                      f"{crushed:.1%} crushed")


def contrast(metrics: ImageMetrics) -> Verdict:
    """Is there tonal range, or is it a flat wash."""
    value = metrics.contrast
    if value < 0.05:
        return Verdict(1, f"luminance spread is {value:.3f}; the frame is flat")
    if value < 0.10:
        return Verdict(2, f"luminance spread is {value:.3f}; very low contrast")
    if value < 0.15:
        return Verdict(3, f"luminance spread is {value:.3f}")
    return Verdict(4, f"luminance spread is {value:.3f}")


def lighting_direction(metrics: ImageMetrics) -> Verdict:
    """Do the light sources read as brighter than the ground.

    The exact defect that shipped: a game about darkness with pale sand ground,
    where the floor was brighter than the lamps meant to light it. Measurable
    without knowing anything about the game -- the brightest 1% of a lit scene
    should be well above its ground plane.
    """
    ground = metrics.lower_luminance
    highlight = metrics.highlight_luminance
    if ground <= 0.001:
        return Verdict(3, "no ground band to compare against")
    ratio = highlight / max(ground, 0.001)
    if ratio < 1.15:
        return Verdict(1, f"the brightest 1% ({highlight:.2f}) barely exceeds the "
                          f"ground ({ground:.2f}); light sources do not read as sources")
    if ratio < 1.6:
        return Verdict(2, f"light sources are only {ratio:.1f}x the ground")
    if ratio < 2.5:
        return Verdict(3, f"light sources are {ratio:.1f}x the ground")
    return Verdict(4, f"light sources are {ratio:.1f}x the ground")


def detail(metrics: ImageMetrics) -> Verdict:
    """Is there anything in frame, or is it an empty plane."""
    density = metrics.edge_density
    if density < 0.02:
        return Verdict(1, f"edge density {density:.3f}; the frame is nearly empty")
    if density < 0.05:
        return Verdict(2, f"edge density {density:.3f}; very little in frame")
    if density < 0.10:
        return Verdict(3, f"edge density {density:.3f}")
    return Verdict(4, f"edge density {density:.3f}")


def colour(metrics: ImageMetrics) -> Verdict:
    """Is there more than one colour in the world."""
    variety = metrics.hue_variety
    if variety <= 1:
        return Verdict(2, f"{variety} hue band holds more than 1% of the frame")
    if variety <= 3:
        return Verdict(3, f"{variety} hue bands hold more than 1% of the frame")
    return Verdict(4, f"{variety} hue bands hold more than 1% of the frame")


#: Criterion name fragments to the measurement that speaks to them.
#:
#: Matched on substrings because rubrics are written per project and nobody is
#: going to spell a criterion the way this file would. A criterion that matches
#: nothing is reported unassessed rather than graded, which is the whole reason
#: this mapping is explicit rather than a default.
MEASURABLE: tuple[tuple[tuple[str, ...], Any], ...] = (
    (("exposure", "brightness", "blown", "overexpos", "bloom"), exposure),
    (("contrast", "tonal", "range"), contrast),
    (("light", "lamp", "illuminat", "shadow"), lighting_direction),
    (("detail", "density", "empty", "sparse", "populat", "clutter"), detail),
    (("colour", "color", "palette", "hue", "saturation"), colour),
)


def assess(criterion: str, metrics: ImageMetrics) -> Verdict | None:
    """The measured verdict for a criterion, or None if pixels cannot say."""
    lowered = criterion.lower()
    for fragments, measurement in MEASURABLE:
        if any(fragment in lowered for fragment in fragments):
            return measurement(metrics)
    return None
