"""Where the game is, inside the picture of Studio.

The defect this exists for
--------------------------

Every screenshot in this repository is `GetWindowRect` on the Studio window and
`ImageGrab` over that rectangle. Menu, ribbon, Explorer, Properties panel and
the output pane are all in the frame, and **nothing cropped them out**. On a
1296x930 capture the game is 936x675 -- 52% of the image. Forty-eight per cent
of every visual measurement this project has ever taken was of the IDE.

That is not a rounding error, because the chrome is the highest-contrast thing
on screen. Measured on a real `brambleway` capture, with the game's own viewport
painted solid black:

    whole window, as measured    tones=16  contrast=1.000   PASS
    viewport only                tones=16  contrast=0.949   PASS
    BLACK viewport + chrome      tones=16  contrast=1.000   PASS

A game drawing literally nothing scores full marks on both of `playtest`'s frame
checks, because white text on dark chrome supplies the whole dynamic range. The
check whose docstring asks "is this a picture of a game, or of nothing" cannot
tell the difference.

How the viewport is found
-------------------------

Studio is Qt-drawn: the 3D viewport is not a child window, so there is no handle
to ask and no layout to query. The bridge knows the viewport's *size* and not
its *position*.

So it is found by what it does rather than by what it is: **the viewport is the
part of the window that changes.** Two frames a fraction of a second apart, and
the bounding box of the differing pixels is the game -- because Studio's chrome
is static and a running game never is. The measured size is then checked against
the size the client itself reports, so a blinking cursor in the output pane
cannot be mistaken for a game.

Three things make this the right method rather than a clever one:

  * it needs no knowledge of Studio's layout, which changes between versions and
    between users who moved a panel;
  * it self-calibrates at any window size, DPI scale or docking arrangement;
  * it is checkable, because the answer must agree with an independent
    measurement the running client already publishes.

When it cannot decide
---------------------

It returns `None`, and the caller must treat that as a **blocked measurement**,
never as a pass. A frame whose game region is unknown is not evidence about a
game. This is the same rule the rest of the engine follows and the reason the
bug above survived: the failure mode of a visual gate is silent approval.
"""

from __future__ import annotations

import time
from dataclasses import dataclass
from typing import Any, Callable, Protocol


#: Luma difference, 0-255, above which a pixel counts as "changed".
#:
#: Low enough to catch a slow pan over flat terrain, high enough to ignore PNG
#: quantisation and the one-bit dithering Studio does on its own panels. Twelve
#: was measured, not chosen: below eight the Explorer's alternating row tint
#: registers as motion, above twenty a distant skybox does not.
CHANGE_THRESHOLD = 12

#: How far the detected box may differ from the size the client reports, as a
#: fraction of the reported dimension.
#:
#: Not zero. The client reports the viewport in its own pixels and Windows
#: reports the window in desktop pixels; at 125% or 150% display scaling the two
#: differ by a real amount that is nobody's bug. Six per cent covers every scale
#: factor Windows offers and still rejects a match against a panel.
SIZE_TOLERANCE = 0.06

#: A detected region smaller than this fraction of the window is not a viewport.
#:
#: Guards the case where the game is nearly static and the only motion in the
#: frame is a spinner or a caret. A Studio viewport is never a tenth of its
#: window; a progress indicator always is.
MIN_WINDOW_FRACTION = 0.10


class ViewportError(RuntimeError):
    """The game region could not be established, and the message says why."""


@dataclass(frozen=True)
class Rect:
    """A region of a captured frame, in image pixels, right/bottom exclusive."""

    left: int
    top: int
    right: int
    bottom: int

    def __post_init__(self) -> None:
        if self.right <= self.left or self.bottom <= self.top:
            raise ViewportError(f"empty rectangle: {self.as_tuple()}")

    @property
    def width(self) -> int:
        return self.right - self.left

    @property
    def height(self) -> int:
        return self.bottom - self.top

    @property
    def area(self) -> int:
        return self.width * self.height

    def as_tuple(self) -> tuple[int, int, int, int]:
        return (self.left, self.top, self.right, self.bottom)

    def to_dict(self) -> dict[str, int]:
        return {
            "left": self.left, "top": self.top,
            "right": self.right, "bottom": self.bottom,
            "width": self.width, "height": self.height,
        }

    @classmethod
    def from_dict(cls, payload: dict[str, Any]) -> "Rect":
        return cls(int(payload["left"]), int(payload["top"]),
                   int(payload["right"]), int(payload["bottom"]))


@dataclass(frozen=True)
class Located:
    """A viewport rectangle and the account of how it was established."""

    rect: Rect
    method: str
    #: The size the running client reported, when one answered.
    reported: tuple[int, int] | None = None
    #: How far the detected box is from the reported size, as a fraction.
    drift: float = 0.0

    def to_dict(self) -> dict[str, Any]:
        return {
            "rect": self.rect.to_dict(),
            "method": self.method,
            "reportedViewport": list(self.reported) if self.reported else None,
            "drift": round(self.drift, 4),
        }


class _Image(Protocol):  # pragma: no cover - structural typing for PIL
    size: tuple[int, int]

    def convert(self, mode: str) -> Any: ...
    def crop(self, box: tuple[int, int, int, int]) -> Any: ...


# --------------------------------------------------------------------------
# The pure half: given two frames, where did the picture move?


def changed_region(before: Any, after: Any,
                   threshold: int = CHANGE_THRESHOLD) -> Rect | None:
    """The bounding box of pixels that differ between two frames.

    Uses Pillow's own difference and bounding-box primitives rather than a
    Python loop: a 1296x930 frame is 1.2 million pixels, and doing this in
    Python costs about a second per detection on a warm machine. The same work
    in Pillow is a few milliseconds, which is what makes it affordable to
    re-detect rather than trust a cached answer.
    """

    from PIL import Image, ImageChops

    if before.size != after.size:
        raise ViewportError(
            f"frames differ in size ({before.size} vs {after.size}); "
            "the window was resized between captures")

    left = before.convert("L")
    right = after.convert("L")
    delta = ImageChops.difference(left, right)
    #: Threshold to pure black/white first. `getbbox` treats any non-zero pixel
    #: as content, so without this every pixel that moved by one level of
    #: compression noise widens the box to the whole window -- which is exactly
    #: the answer this module exists to stop returning.
    mask = delta.point(lambda value: 255 if value > threshold else 0, mode="1")
    box = mask.getbbox()
    if box is None:
        return None
    try:
        return Rect(*box)
    except ViewportError:
        return None


def agrees_with_client(rect: Rect, reported: tuple[int, int] | None,
                       tolerance: float = SIZE_TOLERANCE) -> tuple[bool, float]:
    """Whether a detected box is the size the running client says it is.

    Returns the verdict and the drift, because a caller recording evidence
    wants the number and not only the boolean. A caller with no reported size
    gets `(True, 0.0)`: an unavailable cross-check is not a failed one, and the
    caller decides separately whether to accept an unchecked answer.
    """

    if not reported:
        return True, 0.0
    want_width, want_height = reported
    if want_width <= 0 or want_height <= 0:
        return True, 0.0
    drift = max(
        abs(rect.width - want_width) / want_width,
        abs(rect.height - want_height) / want_height,
    )
    return drift <= tolerance, drift


def plausible(rect: Rect, window: tuple[int, int],
              minimum: float = MIN_WINDOW_FRACTION) -> bool:
    """Whether a region is big enough to be a viewport at all.

    A spinner, a caret and a repainting progress bar are all "the part of the
    window that changed" in a game that happens to be standing still. None of
    them is ever a tenth of the window, and a Studio viewport always is.
    """

    width, height = window
    if width <= 0 or height <= 0:
        return False
    return rect.area >= minimum * width * height


def crop(image: Any, rect: Rect | None) -> Any:
    """The game region of a frame, or the whole frame when it is unknown.

    Deliberately permissive, because the *decision* about an unknown region
    belongs to the measurement, not to the cropper: a caller that wants to
    refuse must check for `None` itself. Silently measuring the whole window is
    the defect; silently refusing to crop is only a missing crop.
    """

    if rect is None:
        return image
    return image.crop(rect.as_tuple())


# --------------------------------------------------------------------------
# The live half: drive two frames out of a running Studio and diff them.


def reported_viewport(bridge: Any, timeout: int = 20) -> tuple[int, int] | None:
    """The viewport size the running client publishes, if a client answers.

    Two commands report it under two different names -- `client.viewport`
    answers `viewport`, `camera.get` answers `viewportSize` -- and this asks
    both rather than picking one, because which of them is available depends on
    whether a client is running and that is not this module's business.
    """

    for method, key in (("client.viewport", "viewport"),
                        ("camera.get", "viewportSize")):
        try:
            answer = bridge.call(method, {}, timeout=timeout)
        except Exception:  # noqa: BLE001 - an absent client is not an error here
            continue
        if not isinstance(answer, dict):
            continue
        size = answer.get(key)
        if isinstance(size, (list, tuple)) and len(size) == 2:
            try:
                width, height = int(size[0]), int(size[1])
            except (TypeError, ValueError):
                continue
            #: A (1, 1) viewport is what an edit-mode Studio reports when no
            #: client exists. `capture.py` already learned this the expensive
            #: way -- it once produced a whole evidence set at one pixel -- so
            #: it is rejected here rather than propagated as a target.
            if width > 1 and height > 1:
                return width, height
    return None


def locate(grab: Callable[[], Any], *, window_size: tuple[int, int],
           reported: tuple[int, int] | None = None,
           settle: float = 0.45, attempts: int = 3,
           nudge: Callable[[], None] | None = None) -> Located | None:
    """Find the game region by taking two frames and diffing them.

    `grab` returns a PIL image of the whole Studio window. `nudge`, when given,
    is called before the final attempt to make something move -- a small camera
    change -- for the case of a genuinely static scene.

    Returns `None` rather than a guess. Every caller of this function is about
    to measure a game, and a measurement over the wrong rectangle is worse than
    no measurement: it is a number that looks like evidence.
    """

    before = grab()
    for attempt in range(max(1, attempts)):
        #: Two frames far enough apart that a running world has moved and close
        #: enough that nothing has been clicked. Under half a second: a Studio
        #: autosave toast appears on a much longer cadence than this, and one
        #: that did appear would fail the size cross-check below anyway.
        time.sleep(settle)
        if nudge is not None and attempt == attempts - 1:
            try:
                nudge()
            except Exception:  # noqa: BLE001 - a refused nudge is not fatal
                pass
            time.sleep(settle)
        after = grab()

        region = changed_region(before, after)
        before = after
        if region is None:
            continue
        if not plausible(region, window_size):
            continue
        ok, drift = agrees_with_client(region, reported)
        if not ok:
            continue
        method = "motion" if nudge is None or attempt < attempts - 1 else "camera-nudge"
        return Located(rect=region, method=method, reported=reported, drift=drift)
    return None


class Cache:
    """One detection per window geometry, because it does not move.

    Studio's layout is stable while the window is: the viewport only changes
    position when the window is resized or a panel is docked, and both change
    the window rectangle. Keying on that gives a cache that cannot go stale in
    the way a time-based one would.
    """

    def __init__(self) -> None:
        self._entries: dict[tuple[Any, ...], Located] = {}

    @staticmethod
    def key(window_signature: Any, window_size: tuple[int, int]) -> tuple[Any, ...]:
        return (window_signature, int(window_size[0]), int(window_size[1]))

    def get(self, window_signature: Any,
            window_size: tuple[int, int]) -> Located | None:
        return self._entries.get(self.key(window_signature, window_size))

    def put(self, window_signature: Any, window_size: tuple[int, int],
            located: Located) -> Located:
        self._entries[self.key(window_signature, window_size)] = located
        return located

    def clear(self) -> None:
        self._entries.clear()


#: Process-wide, because a session photographs the same window many times and
#: the detection costs two captures. Cleared by tests rather than by a timer.
CACHE = Cache()
