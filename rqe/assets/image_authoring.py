"""Procedural image authoring, in the form `EditableImage` accepts.

This is the narrow end of the asset wedge and it was chosen deliberately. Images
are the cheapest asset type to generate, the fastest through moderation, need no
external tool, and unblock the three places the current game looks worst: card
art, icons and UI panels.

Every generator returns a flat RGBA byte array, row-major from the top left,
which is exactly what `assets.create_image` sends and what
`EditableImage:WritePixelsBuffer` consumes. No intermediate file format, no
encoder, nothing for the two sides to disagree about.

Colours come from a token set. A generator that took raw RGB would produce art
that could not be re-themed with the rest of the world, which is the whole
failure this SDK is arranged to prevent.
"""

from __future__ import annotations

import hashlib
import math
from dataclasses import dataclass
from typing import Callable, Sequence

from ..tokens import TokenSet


MAX_DIMENSION = 1024


class ImageAuthoringError(ValueError):
    """The image could not be authored."""


@dataclass(frozen=True)
class Image:
    """A raster plus the provenance needed to publish it honestly."""

    width: int
    height: int
    pixels: tuple[int, ...]
    generator: str
    token_set_id: str
    token_sha256: str
    seed: int

    def __post_init__(self) -> None:
        expected = self.width * self.height * 4
        if len(self.pixels) != expected:
            raise ImageAuthoringError(
                f"{self.width}x{self.height} RGBA needs {expected} bytes, got {len(self.pixels)}"
            )

    @property
    def sha256(self) -> str:
        """Content hash of the raster itself.

        The identity that survives publication: an asset id says which upload
        this was, and this says what was actually in it.
        """

        return hashlib.sha256(bytes(self.pixels)).hexdigest()

    def to_command_params(self, name: str, description: str = "") -> dict:
        return {
            "name": name,
            "description": description,
            "width": self.width,
            "height": self.height,
            "pixels": list(self.pixels),
        }

    def provenance(self) -> dict:
        return {
            "schemaVersion": 1,
            "generator": self.generator,
            "tokenSetId": self.token_set_id,
            "tokenSha256": self.token_sha256,
            "seed": self.seed,
            "width": self.width,
            "height": self.height,
            "sha256": self.sha256,
            # Generated content, never a placeholder. The asset pipeline refuses
            # placeholders, and saying so here is what lets it check.
            "placeholder": False,
        }


class Canvas:
    """A mutable RGBA buffer with the few operations these generators need."""

    def __init__(self, width: int, height: int) -> None:
        if not isinstance(width, int) or not isinstance(height, int):
            raise ImageAuthoringError("dimensions must be integers")
        if not 1 <= width <= MAX_DIMENSION or not 1 <= height <= MAX_DIMENSION:
            raise ImageAuthoringError(f"dimensions must be between 1 and {MAX_DIMENSION}")
        self.width = width
        self.height = height
        self.data = bytearray(width * height * 4)

    def _index(self, x: int, y: int) -> int:
        return (y * self.width + x) * 4

    def set(self, x: int, y: int, rgba: Sequence[int]) -> None:
        if not (0 <= x < self.width and 0 <= y < self.height):
            return
        offset = self._index(x, y)
        self.data[offset:offset + 4] = bytes(
            max(0, min(255, int(channel))) for channel in rgba
        )

    def blend(self, x: int, y: int, rgba: Sequence[int]) -> None:
        """Source-over alpha compositing.

        Written out rather than pulled from a library because the whole point of
        this module is that it has no dependency an Open Cloud task would lack.
        """

        if not (0 <= x < self.width and 0 <= y < self.height):
            return
        alpha = max(0, min(255, int(rgba[3]))) / 255.0
        if alpha <= 0:
            return
        offset = self._index(x, y)
        existing = self.data[offset:offset + 4]
        base_alpha = existing[3] / 255.0
        out_alpha = alpha + base_alpha * (1 - alpha)
        for channel in range(3):
            source = max(0, min(255, int(rgba[channel])))
            blended = (source * alpha + existing[channel] * base_alpha * (1 - alpha))
            self.data[offset + channel] = int(blended / out_alpha) if out_alpha else 0
        self.data[offset + 3] = int(round(out_alpha * 255))

    def fill(self, rgba: Sequence[int]) -> None:
        for y in range(self.height):
            for x in range(self.width):
                self.set(x, y, rgba)

    def rect(self, x0: int, y0: int, x1: int, y1: int, rgba: Sequence[int]) -> None:
        for y in range(max(0, y0), min(self.height, y1)):
            for x in range(max(0, x0), min(self.width, x1)):
                self.blend(x, y, rgba)

    def frame(self, thickness: int, rgba: Sequence[int]) -> None:
        for offset in range(thickness):
            for x in range(self.width):
                self.blend(x, offset, rgba)
                self.blend(x, self.height - 1 - offset, rgba)
            for y in range(self.height):
                self.blend(offset, y, rgba)
                self.blend(self.width - 1 - offset, y, rgba)

    def to_tuple(self) -> tuple[int, ...]:
        return tuple(self.data)


def _rgba(srgb: Sequence[int], alpha: int = 255) -> tuple[int, int, int, int]:
    return (int(srgb[0]), int(srgb[1]), int(srgb[2]), int(alpha))


def _mix(a: Sequence[int], b: Sequence[int], t: float) -> tuple[int, int, int]:
    t = max(0.0, min(1.0, t))
    return tuple(int(round(a[i] + (b[i] - a[i]) * t)) for i in range(3))  # type: ignore[return-value]


def _rng(seed: int):
    """A tiny deterministic generator.

    `random` would work, but seeding a module-global from several call sites is
    how two "deterministic" images stop matching between runs. A local state
    cannot be disturbed by anything else.
    """

    state = (seed or 1) & 0xFFFFFFFF

    def next_float() -> float:
        nonlocal state
        state = (1103515245 * state + 12345) & 0x7FFFFFFF
        return state / 0x7FFFFFFF

    return next_float


# ------------------------------------------------------------------ generators


def rarity_card(
    tokens: TokenSet,
    *,
    rarity_role: str,
    width: int = 256,
    height: int = 358,
    seed: int = 0,
) -> Image:
    """A card face: gradient ground, rarity frame, inner bevel, corner marks.

    The proportions are the standard 5:7 trading-card ratio rather than a
    rectangle chosen by eye, because a card that is not card-shaped reads as
    wrong before anyone looks at the art on it.
    """

    canvas = Canvas(width, height)
    rarity = tokens.role(rarity_role).srgb
    ground = tokens.role("ink").srgb
    light = tokens.role("neutralLight").srgb
    random = _rng(seed)

    # Vertical gradient from ink to a rarity-tinted ink, so every rarity shares
    # a family while staying distinguishable at a glance.
    top = _mix(ground, rarity, 0.35)
    for y in range(height):
        colour = _mix(top, ground, y / max(height - 1, 1))
        for x in range(width):
            canvas.set(x, y, _rgba(colour))

    # Subtle noise. Flat digital gradients band on cheap displays and read as
    # unfinished; a per-pixel jitter of a few levels removes it entirely.
    for y in range(height):
        for x in range(width):
            jitter = int((random() - 0.5) * 8)
            offset = (y * width + x) * 4
            for channel in range(3):
                value = canvas.data[offset + channel] + jitter
                canvas.data[offset + channel] = max(0, min(255, value))

    canvas.frame(6, _rgba(rarity))
    canvas.frame(2, _rgba(light, 90))

    inset = 16
    canvas.rect(inset, inset, width - inset, height - inset, _rgba(light, 18))

    # Corner pips, the cheapest possible rarity read at thumbnail size.
    pip = max(6, width // 22)
    for corner_x, corner_y in ((inset, inset), (width - inset - pip, inset),
                               (inset, height - inset - pip), (width - inset - pip, height - inset - pip)):
        canvas.rect(corner_x, corner_y, corner_x + pip, corner_y + pip, _rgba(rarity))

    return Image(
        width=width,
        height=height,
        pixels=canvas.to_tuple(),
        generator=f"rarity_card:{rarity_role}",
        token_set_id=tokens.id,
        token_sha256=tokens.sha256,
        seed=seed,
    )


def icon(
    tokens: TokenSet,
    *,
    role: str,
    glyph: str = "circle",
    size: int = 128,
    seed: int = 0,
) -> Image:
    """A flat UI icon on a rounded token-coloured field."""

    canvas = Canvas(size, size)
    fill = tokens.role(role).srgb
    ground = tokens.role("ink").srgb
    light = tokens.role("neutralLight").srgb

    radius = size * 0.22
    for y in range(size):
        for x in range(size):
            if _inside_rounded(x, y, size, size, radius):
                canvas.set(x, y, _rgba(_mix(fill, light, 0.08)))
            else:
                canvas.set(x, y, (0, 0, 0, 0))

    centre = size / 2
    span = size * 0.26
    for y in range(size):
        for x in range(size):
            dx, dy = x - centre, y - centre
            inside = False
            if glyph == "circle":
                inside = dx * dx + dy * dy <= span * span
            elif glyph == "square":
                inside = abs(dx) <= span * 0.85 and abs(dy) <= span * 0.85
            elif glyph == "diamond":
                inside = abs(dx) + abs(dy) <= span * 1.15
            elif glyph == "cross":
                inside = (abs(dx) <= span * 0.3 and abs(dy) <= span) or (
                    abs(dy) <= span * 0.3 and abs(dx) <= span
                )
            else:
                raise ImageAuthoringError(f"unknown glyph {glyph!r}")
            if inside:
                canvas.blend(x, y, _rgba(ground, 235))

    return Image(
        width=size,
        height=size,
        pixels=canvas.to_tuple(),
        generator=f"icon:{role}:{glyph}",
        token_set_id=tokens.id,
        token_sha256=tokens.sha256,
        seed=seed,
    )


def panel(
    tokens: TokenSet,
    *,
    width: int = 512,
    height: int = 288,
    seed: int = 0,
) -> Image:
    """A UI panel background: dark ground, bright hairline, soft top light."""

    canvas = Canvas(width, height)
    ground = tokens.role("ink").srgb
    light = tokens.role("neutralLight").srgb

    for y in range(height):
        # A gentle falloff from the top reads as a light source and stops a large
        # flat panel from looking like a hole in the screen.
        lift = 0.10 * (1 - y / max(height - 1, 1))
        colour = _mix(ground, light, lift)
        for x in range(width):
            canvas.set(x, y, _rgba(colour, 242))

    canvas.frame(2, _rgba(light, 70))
    return Image(
        width=width,
        height=height,
        pixels=canvas.to_tuple(),
        generator="panel",
        token_set_id=tokens.id,
        token_sha256=tokens.sha256,
        seed=seed,
    )


def _inside_rounded(x: int, y: int, width: int, height: int, radius: float) -> bool:
    if radius <= 0:
        return True
    for corner_x, corner_y in ((radius, radius), (width - radius, radius),
                               (radius, height - radius), (width - radius, height - radius)):
        if (x < radius and corner_x == radius) or (x >= width - radius and corner_x != radius):
            if (y < radius and corner_y == radius) or (y >= height - radius and corner_y != radius):
                return math.hypot(x - corner_x + 0.5, y - corner_y + 0.5) <= radius
    return True


GENERATORS: dict[str, Callable[..., Image]] = {
    "rarity_card": rarity_card,
    "icon": icon,
    "panel": panel,
}
