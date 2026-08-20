"""The dimensions the goal names that nothing was measuring.

Line 81 of the goal lists seventeen things a scene critic has to look at. The
critic scored four axes covering seven of them, and the gap was not academic:
a single capture came back at 100/100 with no findings on a frame whose paving
was a grid of flat slabs, whose trees repeated one silhouette, and whose
objective was a smooth cylinder. The critic had not run out of defects. It had
run out of questions.

Seven were missing: visual hierarchy, architectural richness, gameplay
readability, landmark quality, primitive appearance, UI/world cohesion and
overall polish. They live here rather than in `critic.py` because each needs
enough explanation to be arguable, and a reader has to be able to disagree with
a metric to trust it.

Every one of them is measured against the same reference ladder the rest of the
critic uses -- the undressed green plate and the dressed blockout -- and any
that failed to order it would be reported unscored rather than kept. Pillow
only, like the rest.

What none of these do is judge. `primitiveAppearance` counts large uniform
axis-aligned rectangles, which is a proxy for "looks like an untextured test
block" and will happily accuse a deliberately minimal art style. That is a
tolerable error for a factory whose failure mode is shipping greybox, and it is
recorded here so nobody mistakes the number for taste.
"""

from __future__ import annotations

import math
from typing import Any


def _grey(image):
    return image.convert("L")


def visual_hierarchy(image) -> float:
    """Whether the frame has a subject, or is uniformly busy.

    A composed frame concentrates contrast somewhere; a filled one spreads it
    evenly. Measured as the share of total local contrast falling in the single
    busiest cell of a 6x6 grid, relative to the even share of 1/36.

    1.0 is perfectly even. Higher means concentration -- and measured on the
    ladder, high turns out to be the *bad* end, which is the opposite of what
    was expected when this was written. The undressed plate scores 15.96 because
    the whole frame is zero contrast except one strip, and the dressed blockout
    5.47 for the same reason in milder form. Every built frame sits between 1.5
    and 2.1.

    So it is scored as a ceiling, not a floor: what it actually detects is a
    frame with nothing in it *except* one thing. Genuine subject emphasis in a
    dense scene is a much smaller effect than emptiness, and this metric cannot
    separate the two -- it can only catch the degenerate case. Named honestly
    for what it does rather than for what it was reaching for.
    """

    from PIL import ImageFilter

    grey = _grey(image)
    edges = grey.filter(ImageFilter.FIND_EDGES)
    width, height = image.size
    cells: list[float] = []
    for row in range(6):
        for column in range(6):
            box = (
                column * width // 6, row * height // 6,
                (column + 1) * width // 6, (row + 1) * height // 6,
            )
            patch = edges.crop(box)
            histogram = patch.histogram()
            total = sum(histogram) or 1
            cells.append(sum(value * count for value, count in enumerate(histogram)) / total)
    overall = sum(cells) or 1e-9
    return (max(cells) / overall) * len(cells)


def architectural_richness(image) -> float:
    """How much of the frame is built rather than grown or empty.

    Buildings make long straight vertical edges; trees, ground and sky do not.
    Measured as the fraction of columns containing a vertical edge run of at
    least 4% of the frame height -- a wall, a post, a tower side.

    Deliberately not "count of parts": a scene can be made of ten thousand
    scattered rocks and still have no architecture in it, and that is exactly
    the state a scatter-driven world generator arrives at on its own.
    """

    from PIL import ImageChops, ImageFilter

    grey = _grey(image)
    width, height = image.size
    # Vertical edges only: a horizontal Sobel response, so ground seams and
    # horizon lines do not count as walls.
    shifted = ImageChops.offset(grey, 1, 0)
    vertical = ImageChops.difference(grey, shifted)
    exposure = grey.filter(ImageFilter.GaussianBlur(24))
    threshold = exposure.point(lambda v: max(3, min(255, round(14.0 * v / 128.0))))
    strong = ImageChops.subtract(vertical, threshold).point(
        lambda v: 255 if v > 0 else 0, mode="1").convert("L")

    pixels = strong.tobytes()
    minimum_run = max(4, int(height * 0.04))
    columns = 0
    for column in range(width):
        run = 0
        found = False
        for row in range(height):
            if pixels[row * width + column]:
                run += 1
                if run >= minimum_run:
                    found = True
                    break
            else:
                run = 0
        if found:
            columns += 1
    return columns / width if width else 0.0


def landmark_quality(image) -> float:
    """How far the tallest thing rises above the skyline around it.

    A landmark is not "a tall object"; it is an object taller than its
    neighbours. Measured as the difference between the highest and the median
    occupied row across columns, as a fraction of frame height -- so a flat wall
    running the width of the frame scores zero however tall it is, and a single
    tower scores well even in a small frame.
    """

    from PIL import ImageChops, ImageFilter

    grey = _grey(image)
    width, height = image.size
    smooth = grey.filter(ImageFilter.GaussianBlur(2))
    exposure = grey.filter(ImageFilter.GaussianBlur(24))
    threshold = exposure.point(lambda v: max(2, min(255, round(6.0 * v / 128.0))))
    variation = ImageChops.difference(grey, smooth)
    occupied = ImageChops.subtract(variation, threshold).point(
        lambda v: 255 if v > 0 else 0, mode="1").convert("L")

    pixels = occupied.tobytes()
    tops: list[int] = []
    for column in range(width):
        for row in range(height):
            if pixels[row * width + column]:
                tops.append(row)
                break

    # Only columns that contain something count.
    #
    # The first version appended `height` for empty columns, which handed the
    # undressed green plate a perfect 1.0: almost none of its columns have
    # content, so the median sat at the bottom of the frame and the two or three
    # columns with an edge in them read as a spire. That is the same failure
    # that retired `scale_coherence` -- a metric an empty frame wins -- and it
    # is caught here rather than shipped because the ladder was measured before
    # the axis was scored.
    if len(tops) < width * 0.4:
        return 0.0
    ordered = sorted(tops)
    median = ordered[len(ordered) // 2]
    highest = ordered[0]
    return max(0.0, (median - highest) / height)


def primitive_appearance(image) -> float:
    """Fraction of the frame occupied by large flat axis-aligned rectangles.

    The development-primitive signature the goal asks to eliminate: an
    untextured Part fills a quadrilateral with one colour, and at typical camera
    angles a great many of them are close to axis-aligned on screen.

    Measured by scanning for runs of near-identical colour that are long in both
    directions -- at least 6% of the width and 6% of the height. Small uniform
    patches are ignored, because every scene has those; what this looks for is
    the 200-pixel-wide grey slab.

    Lower is better. This is the one dimension here whose failure mode is
    accusing a minimal style of being unfinished, and that trade is deliberate.
    """

    from PIL import Image

    width, height = image.size
    # Downsample first: this is a structural question, and at full resolution it
    # is a per-pixel loop over a million pixels in Python.
    scale = 160
    small = image.convert("RGB").resize(
        (scale, max(1, round(scale * height / width))), Image.BILINEAR)
    sw, sh = small.size
    data = small.tobytes()

    def at(x: int, y: int) -> tuple[int, int, int]:
        index = (y * sw + x) * 3
        return data[index], data[index + 1], data[index + 2]

    def alike(a: tuple[int, int, int], b: tuple[int, int, int]) -> bool:
        return (abs(a[0] - b[0]) + abs(a[1] - b[1]) + abs(a[2] - b[2])) <= 12

    min_w = max(3, round(sw * 0.06))
    min_h = max(3, round(sh * 0.06))
    covered = 0
    claimed = bytearray(sw * sh)
    for y in range(0, sh - min_h + 1, 2):
        for x in range(0, sw - min_w + 1, 2):
            if claimed[y * sw + x]:
                continue
            seed = at(x, y)
            # Grow right, then down, keeping the block rectangular.
            right = x
            while right + 1 < sw and alike(at(right + 1, y), seed):
                right += 1
            if right - x + 1 < min_w:
                continue
            bottom = y
            while bottom + 1 < sh and all(
                alike(at(column, bottom + 1), seed) for column in range(x, right + 1, 3)
            ):
                bottom += 1
            if bottom - y + 1 < min_h:
                continue
            for row in range(y, bottom + 1):
                base = row * sw
                for column in range(x, right + 1):
                    if not claimed[base + column]:
                        claimed[base + column] = 1
                        covered += 1
    total = sw * sh
    return covered / total if total else 0.0


def gameplay_readability(image, *, accent_budget: float = 0.10) -> float:
    """Whether anything in the frame is marked out as mattering.

    The goal wants a player to see, without text, where they can build and what
    they must defend. That is what an accent colour is for, and a palette
    declares an accent budget precisely so accents stay rare enough to mean
    something.

    Measured as the fraction of the frame carrying high-chroma, high-value
    pixels, scored as a band: zero means nothing is called out and the scene is
    uniform in importance; far above the budget means everything is called out,
    which is the same thing.
    """

    small = image.convert("RGB").resize((160, 120))
    data = small.tobytes()
    total = 160 * 120
    marked = 0
    for index in range(0, len(data), 3):
        red, green, blue = data[index], data[index + 1], data[index + 2]
        high, low = max(red, green, blue), min(red, green, blue)
        if high < 110:
            continue
        if (high - low) / max(high, 1) > 0.42:
            marked += 1
    return marked / total if total else 0.0


def ui_world_cohesion(image, *, ui_band: float = 0.22) -> float:
    """Whether the interface looks like it belongs to the world it sits on.

    Measured as the overlap between the hue histogram of the top band -- where
    a HUD lives -- and that of the rest of the frame. A HUD drawn from the
    world's palette shares its hues; one drawn from a default UI kit does not.

    1.0 is complete overlap. This cannot tell a well-designed HUD from a badly
    designed one; it can tell a HUD that came from the same design system from
    one that did not, which is the specific failure the goal names.
    """

    width, height = image.size
    cut = max(1, int(height * ui_band))
    top = image.crop((0, 0, width, cut)).convert("RGB").resize((96, 32))
    rest = image.crop((0, cut, width, height)).convert("RGB").resize((96, 96))

    def hues(sample) -> list[float]:
        buckets = [0.0] * 12
        data = sample.tobytes()
        for index in range(0, len(data), 3):
            red, green, blue = data[index], data[index + 1], data[index + 2]
            high, low = max(red, green, blue), min(red, green, blue)
            span = high - low
            if span < 20:
                # Near-greys belong to everything and would swamp the overlap.
                continue
            r, g, b = red / 255.0, green / 255.0, blue / 255.0
            top_channel = max(r, g, b)
            delta = span / 255.0
            if top_channel == r:
                hue = ((g - b) / delta) % 6
            elif top_channel == g:
                hue = (b - r) / delta + 2
            else:
                hue = (r - g) / delta + 4
            buckets[int((hue * 60.0) % 360.0 // 30)] += 1
        total = sum(buckets) or 1.0
        return [value / total for value in buckets]

    a, b = hues(top), hues(rest)
    if sum(a) == 0 or sum(b) == 0:
        # No chromatic UI, or no chromatic world. Nothing to disagree about.
        return 1.0
    return sum(min(x, y) for x, y in zip(a, b))


def exposure_health(image) -> float:
    """How much of the frame has been blown past what a display can show.

    **The dimension that was missing, and the reason the critic once scored a
    frame 99/100 with the character blown to white.** Nothing measured exposure
    at all: hierarchy, richness, landmark, primitive appearance, readability and
    cohesion can every one of them be satisfied by an image whose highlights are
    a flat sheet of 255. Clipping destroys information, and a metric suite that
    cannot see it will happily call a ruined frame finished.

    **Blown highlights only.** The first version counted crushed blacks too, on
    the reasoning that they are the same defect from the other side. They are
    not, and the counterexample is in this repository: `last-vigil` is a night
    game, and 58% of its game viewport sits at 0-4 by design. Scoring that as a
    defect would fire the axis on every dark scene -- which is most of the
    horror genre -- while a frame with *areas* at 250+ is wrong in every style
    there is.

    So the black end is measured and reported by `crushed_fraction` and
    deliberately not scored, the same discipline the asset critic applies to the
    three metrics that failed to order its ladder. A confident number about
    nothing is worse than no number.
    """

    grey = _grey(image)
    counts = grey.histogram()
    total = sum(counts)
    if total == 0:
        return 0.0
    # 250 rather than 255: a value of 252 is already unrecoverable on screen,
    # and a threshold at the absolute limit misses the shoulder where the
    # detail actually died.
    return sum(counts[250:]) / total


def crushed_fraction(image) -> float:
    """How much of the frame sits at pure black. Reported, never scored.

    A stylised night scene is legitimately full of this, and nothing here can
    tell that apart from an underexposed one. Useful to a person reading the
    numbers; not usable as a bar.
    """

    grey = _grey(image)
    counts = grey.histogram()
    total = sum(counts)
    if total == 0:
        return 0.0
    return sum(counts[:5]) / total


def measure(image) -> dict[str, Any]:
    """Every dimension in this module, for one frame."""

    return {
        "visualHierarchy": round(visual_hierarchy(image), 3),
        "architecturalRichness": round(architectural_richness(image), 4),
        "landmarkQuality": round(landmark_quality(image), 4),
        "primitiveAppearance": round(primitive_appearance(image), 4),
        "gameplayReadability": round(gameplay_readability(image), 4),
        "uiWorldCohesion": round(ui_world_cohesion(image), 3),
        "exposureHealth": round(exposure_health(image), 4),
        "crushedFraction": round(crushed_fraction(image), 4),
    }
