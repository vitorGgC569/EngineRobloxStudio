"""Pixel comparison between two captures of the same viewpoint.

The missing piece for visual regression. Without a diff, two screenshots of the
same viewpoint across two builds cannot be told apart, and "did this change
break the look of the game" has no mechanical answer -- only a human squinting
at two images.

Deliberately not a similarity score. A single number cannot distinguish "the
whole frame shifted two pixels because the camera moved" from "one button
disappeared", and those are opposite findings. What this returns instead is
*where* the change is: how much of the frame moved, how concentrated it is, and
the bounding box that contains it.

Perceptual rather than raw RGB. Two frames differing only in encoding noise are
identical to a viewer, and a channel-wise comparison reports them as changed.
"""

from __future__ import annotations

import math
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any


#: Per-channel difference below which two pixels are the same to a viewer.
#: Renders and screenshots carry a little noise; treating it as change makes
#: every comparison fail and the tool useless.
NOISE_FLOOR = 6

#: A change touching less than this fraction of the frame is a detail; more is
#: a different composition. Used only to label, never to decide.
COMPOSITION_FRACTION = 0.25


class CompareError(RuntimeError):
    """The images could not be compared."""


@dataclass
class Comparison:
    width: int
    height: int
    changed_pixels: int
    total_pixels: int
    mean_delta: float
    max_delta: int
    bounding_box: tuple[int, int, int, int] | None
    threshold: float
    dimensions_match: bool = True
    detail: dict[str, Any] = field(default_factory=dict)

    @property
    def changed_fraction(self) -> float:
        return self.changed_pixels / self.total_pixels if self.total_pixels else 0.0

    @property
    def identical(self) -> bool:
        # Dimensions first. Two frames of different sizes compare zero changed
        # pixels because none were compared at all, and reporting that as
        # identical is the one answer that would let a visual regression pass in
        # silence.
        return self.dimensions_match and self.changed_pixels == 0

    @property
    def within_threshold(self) -> bool:
        return self.dimensions_match and self.changed_fraction <= self.threshold

    @property
    def classification(self) -> str:
        if not self.dimensions_match:
            return "incomparable"
        if self.identical:
            return "identical"
        if self.changed_fraction >= COMPOSITION_FRACTION:
            return "recomposed"
        if self.within_threshold:
            return "noise"
        return "changed"

    def to_dict(self) -> dict[str, Any]:
        return {
            "schemaVersion": 1,
            "width": self.width,
            "height": self.height,
            "totalPixels": self.total_pixels,
            "changedPixels": self.changed_pixels,
            "changedFraction": round(self.changed_fraction, 6),
            "meanDelta": round(self.mean_delta, 3),
            "maxDelta": self.max_delta,
            "boundingBox": list(self.bounding_box) if self.bounding_box else None,
            "threshold": self.threshold,
            "withinThreshold": self.within_threshold,
            "identical": self.identical,
            "dimensionsMatch": self.dimensions_match,
            "classification": self.classification,
            **self.detail,
        }

    def summary(self) -> str:
        if not self.dimensions_match:
            return "incomparable: the two frames are different sizes"
        if self.identical:
            return "identical: not one pixel changed"
        percent = self.changed_fraction * 100
        where = ""
        if self.bounding_box:
            left, top, right, bottom = self.bounding_box
            where = f", confined to ({left},{top})-({right},{bottom})"
        return f"{self.classification}: {percent:.2f}% of pixels changed{where}"


def compare_images(before: Path, after: Path, *, threshold: float = 0.02) -> dict[str, Any]:
    """Compare two PNGs and report what changed and where."""

    try:
        from PIL import Image
    except ImportError as exc:  # pragma: no cover - environment dependency
        raise CompareError("Pillow is required for image comparison: pip install pillow") from exc

    if not 0 <= threshold <= 1:
        raise CompareError("threshold must be between 0 and 1")

    with Image.open(before) as first, Image.open(after) as second:
        left = first.convert("RGB")
        right = second.convert("RGB")

        if left.size != right.size:
            # Not resized to match. A comparison between a resized frame and a
            # native one measures the resampler, not the change.
            return Comparison(
                width=left.size[0], height=left.size[1],
                changed_pixels=0, total_pixels=left.size[0] * left.size[1],
                mean_delta=0.0, max_delta=0, bounding_box=None,
                threshold=threshold, dimensions_match=False,
                detail={"beforeSize": list(left.size), "afterSize": list(right.size)},
            ).to_dict()

        width, height = left.size
        left_pixels = left.load()
        right_pixels = right.load()

        changed = 0
        total_delta = 0
        max_delta = 0
        min_x, min_y, max_x, max_y = width, height, -1, -1

        for y in range(height):
            for x in range(width):
                a = left_pixels[x, y]
                b = right_pixels[x, y]
                delta = max(abs(a[0] - b[0]), abs(a[1] - b[1]), abs(a[2] - b[2]))
                if delta > max_delta:
                    max_delta = delta
                if delta > NOISE_FLOOR:
                    changed += 1
                    total_delta += delta
                    if x < min_x:
                        min_x = x
                    if y < min_y:
                        min_y = y
                    if x > max_x:
                        max_x = x
                    if y > max_y:
                        max_y = y

    box = (min_x, min_y, max_x, max_y) if max_x >= 0 else None
    comparison = Comparison(
        width=width,
        height=height,
        changed_pixels=changed,
        total_pixels=width * height,
        mean_delta=(total_delta / changed) if changed else 0.0,
        max_delta=max_delta,
        bounding_box=box,
        threshold=threshold,
    )
    payload = comparison.to_dict()
    payload["summary"] = comparison.summary()
    payload["before"] = str(before)
    payload["after"] = str(after)
    return payload
