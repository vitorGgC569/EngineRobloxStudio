"""Screen templates: `ui.screen("inventory")` rather than forty positioned frames.

`Ui.lua` already has the primitives -- stacks, panels, buttons, grids, scrollers,
all reading the token set. What it does not have is the layer above: a *screen*,
which is a named arrangement of those primitives that has to survive a phone, a
notch, an empty state and a language nobody wrote it in.

Composing screens by hand is not slow so much as it is silently device-specific.
A shop laid out on a 1920-wide desktop looks correct, ships, and puts its buy
button under the status bar on a 390-wide phone -- and the only way anybody finds
out is a screenshot somebody happened to take.

So this layer computes the layout, per device, and checks it:

    template + device + tokens -> rects -> problems

Three things it will not do.

**It does not invent sizes.** Type steps, spacing steps and the touch minimum all
come from the token set, which is the same source `Ui.lua` reads. A screen laid
out against numbers chosen here would look right alone and wrong beside the game.

**It does not skip the empty state.** Every template declares one, because the
first session is the one where every list is empty, and a screen that was only
ever designed populated is a screen the new player sees broken.

**It does not build Instances.** The output is a layout an agent can check, diff
across devices, and only then hand to `Ui.lua` to construct. Keeping the decision
apart from the construction is what makes a bad layout arguable before it exists.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from typing import Any, Iterable, Sequence


class ScreenError(ValueError):
    """The screen could not be composed, and the message says why."""


@dataclass(frozen=True)
class Device:
    """A device class the UI has to survive."""

    id: str
    width: int
    height: int
    input_mode: str
    #: Pixels reserved at each edge for notches, home indicators and the Roblox
    #: top bar. Content inside these is drawn and unreachable.
    safe_top: int = 0
    safe_bottom: int = 0
    safe_left: int = 0
    safe_right: int = 0

    @property
    def portrait(self) -> bool:
        return self.height > self.width

    @property
    def touch(self) -> bool:
        return self.input_mode == "TOUCH"


#: The devices a Roblox experience actually ships to. The insets are not
#: guesses: Roblox reserves the top strip for its own chrome on every platform,
#: and a phone adds a notch above and a home indicator below.
DEVICES = {
    "desktop": Device("desktop", 1920, 1080, "KEYBOARD_MOUSE", safe_top=36),
    "tablet": Device("tablet", 1024, 768, "TOUCH", safe_top=36),
    "phone": Device("phone", 390, 844, "TOUCH",
                    safe_top=83, safe_bottom=34, safe_left=0, safe_right=0),
    "phone_landscape": Device("phone_landscape", 844, 390, "TOUCH",
                              safe_top=36, safe_bottom=21, safe_left=44, safe_right=44),
    "console": Device("console", 1920, 1080, "GAMEPAD", safe_top=36,
                      # Consoles overscan: the outer 5% may not be visible on a
                      # television at all.
                      safe_bottom=54, safe_left=96, safe_right=96),
}

#: The smallest a touch target may be. Below this a finger misses it, and the
#: player concludes the button is broken rather than that they missed.
TOUCH_TARGET_MINIMUM = 44

#: The smallest legible type on a handheld, in pixels.
MIN_TEXT_SIZE = 13

#: Screen states every template must declare. The first session is the one where
#: every list is empty, and a screen only ever designed populated is a screen the
#: new player sees broken.
REQUIRED_STATES = ("empty", "populated")
OPTIONAL_STATES = ("loading", "error", "locked")


@dataclass(frozen=True)
class Element:
    """One thing on a screen, before it has a position."""

    id: str
    kind: str
    #: Which band it belongs to: header, body or footer.
    band: str
    #: Type step from the token set, for text elements.
    text_step: str = ""
    #: Whether a finger has to hit it.
    interactive: bool = False
    #: How much of the band's free space it takes, against its siblings.
    weight: float = 1.0
    #: Fixed height in pixels; when set, weight is ignored.
    height: int = 0
    label: str = ""

    def to_dict(self) -> dict[str, Any]:
        return {
            "id": self.id, "kind": self.kind, "band": self.band,
            "textStep": self.text_step, "interactive": self.interactive,
            "weight": self.weight, "height": self.height, "label": self.label,
        }


@dataclass(frozen=True)
class ScreenTemplate:
    """A named screen: what it holds, and what it looks like when empty."""

    id: str
    title: str
    elements: tuple[Element, ...]
    states: tuple[str, ...] = REQUIRED_STATES
    #: What the screen says when it has nothing to show. Required, and written
    #: here rather than left to whoever builds it, because "no items" is a
    #: design decision and an unlabelled empty list reads as a loading failure.
    empty_message: str = ""
    #: Systems that must exist for this screen to have anything in it.
    requires_systems: tuple[str, ...] = ()

    def __post_init__(self) -> None:
        if not self.elements:
            raise ScreenError(f"screen {self.id!r} has no elements")
        for state in REQUIRED_STATES:
            if state not in self.states:
                raise ScreenError(
                    f"screen {self.id!r} does not declare its {state!r} state; the first "
                    "session is the one where every list is empty"
                )
        if not self.empty_message.strip():
            raise ScreenError(
                f"screen {self.id!r} has no empty message; an unlabelled empty list "
                "reads to a player as a loading failure"
            )
        bands = {element.band for element in self.elements}
        unknown = bands - {"header", "body", "footer"}
        if unknown:
            raise ScreenError(
                f"screen {self.id!r} uses unknown bands: {', '.join(sorted(unknown))}")


def _text(element_id: str, band: str, step: str, label: str, **kwargs: Any) -> Element:
    return Element(element_id, "text", band, text_step=step, label=label, **kwargs)


def _button(element_id: str, band: str, label: str, **kwargs: Any) -> Element:
    return Element(element_id, "button", band, text_step="label", label=label,
                   interactive=True, **kwargs)


#: The screens the document names, plus the two every game needs.
TEMPLATES: dict[str, ScreenTemplate] = {
    "inventory": ScreenTemplate(
        id="inventory", title="Inventory",
        elements=(
            _text("title", "header", "title", "Inventory", height=48),
            Element("capacity", "text", "header", text_step="caption",
                    label="0 / 0", height=20),
            Element("grid", "grid", "body", weight=1.0),
            _button("close", "footer", "Close", height=TOUCH_TARGET_MINIMUM),
        ),
        states=("empty", "populated", "loading"),
        empty_message="Nothing carried yet -- pick something up to fill this.",
        requires_systems=("inventory",),
    ),
    "shop": ScreenTemplate(
        id="shop", title="Shop",
        elements=(
            _text("title", "header", "title", "Shop", height=48),
            Element("balance", "value", "header", text_step="label", height=32),
            Element("catalogue", "scroller", "body", weight=1.0),
            _button("buy", "footer", "Buy", height=TOUCH_TARGET_MINIMUM),
            _button("close", "footer", "Close", height=TOUCH_TARGET_MINIMUM),
        ),
        states=("empty", "populated", "loading", "error"),
        empty_message="Nothing for sale right now -- come back after the next tier.",
        requires_systems=("shop", "economy"),
    ),
    "quest_log": ScreenTemplate(
        id="quest_log", title="Quests",
        elements=(
            _text("title", "header", "title", "Quests", height=48),
            Element("list", "scroller", "body", weight=1.0),
            Element("detail", "panel", "body", weight=0.8),
            _button("track", "footer", "Track", height=TOUCH_TARGET_MINIMUM),
            _button("close", "footer", "Close", height=TOUCH_TARGET_MINIMUM),
        ),
        states=("empty", "populated", "loading"),
        empty_message="No quests yet -- talk to someone to pick one up.",
        requires_systems=("quests",),
    ),
    "upgrade_tree": ScreenTemplate(
        id="upgrade_tree", title="Upgrades",
        elements=(
            _text("title", "header", "title", "Upgrades", height=48),
            Element("balance", "value", "header", text_step="label", height=32),
            Element("tree", "scroller", "body", weight=1.0),
            _button("purchase", "footer", "Purchase", height=TOUCH_TARGET_MINIMUM),
            _button("close", "footer", "Close", height=TOUCH_TARGET_MINIMUM),
        ),
        states=("empty", "populated", "locked"),
        empty_message="Everything here is bought -- the next tier unlocks more.",
        requires_systems=("progression", "economy"),
    ),
    "hud": ScreenTemplate(
        id="hud", title="HUD",
        elements=(
            Element("balance", "value", "header", text_step="label", height=32),
            Element("objective", "text", "header", text_step="caption", height=20),
            _button("menu", "footer", "Menu", height=TOUCH_TARGET_MINIMUM),
        ),
        states=("empty", "populated"),
        empty_message="Nothing to show yet.",
    ),
    "settings": ScreenTemplate(
        id="settings", title="Settings",
        elements=(
            _text("title", "header", "title", "Settings", height=48),
            Element("options", "scroller", "body", weight=1.0),
            _button("close", "footer", "Close", height=TOUCH_TARGET_MINIMUM),
        ),
        states=("empty", "populated"),
        empty_message="No settings available.",
    ),
}


@dataclass(frozen=True)
class Rect:
    x: int
    y: int
    width: int
    height: int

    def to_dict(self) -> dict[str, int]:
        return {"x": self.x, "y": self.y, "width": self.width, "height": self.height}


@dataclass
class Layout:
    """A screen, positioned for one device."""

    screen: str
    device: Device
    rects: dict[str, Rect] = field(default_factory=dict)
    text_sizes: dict[str, int] = field(default_factory=dict)

    def problems(self) -> list[str]:
        """Everything wrong with this screen on this device."""

        found: list[str] = []
        template = TEMPLATES[self.screen]
        by_id = {element.id: element for element in template.elements}

        safe_left = self.device.safe_left
        safe_top = self.device.safe_top
        safe_right = self.device.width - self.device.safe_right
        safe_bottom = self.device.height - self.device.safe_bottom

        for element_id, rect in self.rects.items():
            element = by_id[element_id]

            # Drawn and unreachable is the failure that only a phone shows.
            if rect.y < safe_top or rect.y + rect.height > safe_bottom \
                    or rect.x < safe_left or rect.x + rect.width > safe_right:
                found.append(
                    f"{element_id} falls outside the safe area on {self.device.id}; it "
                    "would be drawn under the notch, the home indicator or the "
                    "television's overscan, where a player can see it and not touch it"
                )

            if element.interactive and self.device.touch:
                if rect.height < TOUCH_TARGET_MINIMUM or rect.width < TOUCH_TARGET_MINIMUM:
                    found.append(
                        f"{element_id} is {rect.width}x{rect.height} on {self.device.id}, "
                        f"below the {TOUCH_TARGET_MINIMUM}px a finger reliably hits; the "
                        "player concludes the button is broken rather than that they missed"
                    )

            if rect.height <= 0 or rect.width <= 0:
                found.append(
                    f"{element_id} has no area on {self.device.id}; it exists in the tree "
                    "and not on the screen, which is the hardest kind of missing to find"
                )

        for element_id, size in self.text_sizes.items():
            if size < MIN_TEXT_SIZE:
                found.append(
                    f"{element_id} renders at {size}px on {self.device.id}, below the "
                    f"{MIN_TEXT_SIZE}px floor for legibility at arm's length"
                )

        return found

    @property
    def ok(self) -> bool:
        return not self.problems()

    def to_dict(self) -> dict[str, Any]:
        return {
            "screen": self.screen,
            "device": self.device.id,
            "viewport": {"width": self.device.width, "height": self.device.height},
            "safeArea": {
                "top": self.device.safe_top, "bottom": self.device.safe_bottom,
                "left": self.device.safe_left, "right": self.device.safe_right,
            },
            "ok": self.ok,
            "rects": {key: rect.to_dict() for key, rect in self.rects.items()},
            "textSizes": dict(self.text_sizes),
            "problems": self.problems(),
        }


def _type_scale(tokens: dict[str, Any], device: Device) -> dict[str, int]:
    """Type steps, scaled for the device.

    A 36px title on a 390-wide phone takes a third of the width; the same title
    on a desktop is unremarkable. Scaled by viewport width against the desktop
    reference, floored at legibility -- never below, because small-and-unreadable
    is worse than large-and-cramped.
    """

    steps = ((tokens.get("typography") or {}).get("steps") or {})
    if not steps:
        raise ScreenError(
            "the token set declares no typography steps; a screen laid out against "
            "sizes chosen here would look right alone and wrong beside the game"
        )
    factor = min(1.0, max(0.62, device.width / 1920.0 + 0.34))
    return {name: max(MIN_TEXT_SIZE, int(round(size * factor)))
            for name, size in steps.items()}


def compose(screen: str, *, device: Device | str, tokens: dict[str, Any]) -> Layout:
    """Position a screen for one device."""

    if screen not in TEMPLATES:
        raise ScreenError(
            f"unknown screen {screen!r}; templates: " + ", ".join(sorted(TEMPLATES)))
    if isinstance(device, str):
        if device not in DEVICES:
            raise ScreenError(
                f"unknown device {device!r}; known: " + ", ".join(sorted(DEVICES)))
        device = DEVICES[device]

    template = TEMPLATES[screen]
    scale = _type_scale(tokens, device)
    spacing = ((tokens.get("spacing") or {}).get("steps") or {})
    gap = int(spacing.get("base", 12))

    left = device.safe_left
    top = device.safe_top
    width = device.width - device.safe_left - device.safe_right
    height = device.height - device.safe_top - device.safe_bottom
    if width <= 0 or height <= 0:
        raise ScreenError(
            f"{device.id} has no usable area once its safe insets are applied")

    bands: dict[str, list[Element]] = {"header": [], "body": [], "footer": []}
    for element in template.elements:
        bands[element.band].append(element)

    rects: dict[str, Rect] = {}
    text_sizes: dict[str, int] = {}

    def place_fixed(elements: list[Element], y: int, downward: bool) -> int:
        cursor = y
        for element in elements:
            element_height = element.height or TOUCH_TARGET_MINIMUM
            if not downward:
                cursor -= element_height
            rects[element.id] = Rect(left, cursor, width, element_height)
            if element.text_step:
                text_sizes[element.id] = scale.get(element.text_step, MIN_TEXT_SIZE)
            cursor += element_height + gap if downward else -gap
        return cursor

    header_end = place_fixed(bands["header"], top, downward=True)
    footer_start = place_fixed(list(reversed(bands["footer"])),
                               top + height, downward=False)

    # Footer buttons sit side by side when there is room, and stack when there is
    # not. A row of three buttons on a 390-wide phone gives each 118px, which is
    # fine; five would give 70px, which is not, and stacking is the answer rather
    # than shrinking below the touch minimum.
    footer = bands["footer"]
    if footer:
        per_button = (width - gap * (len(footer) - 1)) // len(footer)
        if per_button >= TOUCH_TARGET_MINIMUM and not (device.touch and per_button < 96):
            row_y = min(rects[element.id].y for element in footer)
            row_height = max(rects[element.id].height for element in footer)
            for index, element in enumerate(footer):
                rects[element.id] = Rect(
                    left + index * (per_button + gap), row_y, per_button, row_height)
            footer_start = row_y - gap

    body_top = header_end
    body_height = max(footer_start - body_top, 0)
    body = bands["body"]
    if body:
        total_weight = sum(element.weight for element in body) or 1.0
        cursor = body_top
        for element in body:
            share = int(body_height * (element.weight / total_weight))
            rects[element.id] = Rect(left, cursor, width, max(share - gap, 0))
            if element.text_step:
                text_sizes[element.id] = scale.get(element.text_step, MIN_TEXT_SIZE)
            cursor += share

    return Layout(screen=screen, device=device, rects=rects, text_sizes=text_sizes)


def compose_matrix(screen: str, *, tokens: dict[str, Any],
                   devices: Sequence[str] = ()) -> dict[str, Any]:
    """One screen across every device it has to survive.

    The whole point of the layer. A screen checked only on the device it was
    authored for is a screen whose failure is waiting on somebody's phone.
    """

    names = list(devices) or list(DEVICES)
    layouts = {name: compose(screen, device=name, tokens=tokens) for name in names}
    problems = {name: layout.problems() for name, layout in layouts.items()}
    failing = {name: items for name, items in problems.items() if items}

    template = TEMPLATES[screen]
    return {
        "schemaVersion": 1,
        "screen": screen,
        "title": template.title,
        "ok": not failing,
        "devices": names,
        "states": list(template.states),
        "emptyMessage": template.empty_message,
        "requiresSystems": list(template.requires_systems),
        "layouts": {name: layout.to_dict() for name, layout in layouts.items()},
        "failingDevices": sorted(failing),
        "problems": failing,
        "note": (
            "layout only: no Instances were built. A screen checked on one device is a "
            "screen whose failure is waiting on somebody's phone"
        ),
    }


def screens_for(model: Any) -> list[str]:
    """Which screens a game model needs, from the systems it declares.

    A shop screen in a game with no shop is a button that opens an empty panel;
    a game with a shop and no shop screen is a system nobody can reach.
    """

    systems = set(getattr(model, "systems", ()))
    needed = ["hud", "settings"]
    for name, template in sorted(TEMPLATES.items()):
        if name in needed:
            continue
        if template.requires_systems and set(template.requires_systems) <= systems:
            needed.append(name)
    return needed


def catalogue() -> dict[str, Any]:
    """Every screen template, and what each needs behind it."""

    return {
        "schemaVersion": 1,
        "count": len(TEMPLATES),
        "devices": {
            name: {
                "width": device.width, "height": device.height,
                "inputMode": device.input_mode,
                "safeArea": {
                    "top": device.safe_top, "bottom": device.safe_bottom,
                    "left": device.safe_left, "right": device.safe_right,
                },
            }
            for name, device in sorted(DEVICES.items())
        },
        "screens": [
            {
                "id": template.id, "title": template.title,
                "states": list(template.states),
                "emptyMessage": template.empty_message,
                "requiresSystems": list(template.requires_systems),
                "elements": [element.to_dict() for element in template.elements],
            }
            for template in sorted(TEMPLATES.values(), key=lambda item: item.id)
        ],
        "touchTargetMinimum": TOUCH_TARGET_MINIMUM,
        "minTextSize": MIN_TEXT_SIZE,
    }
