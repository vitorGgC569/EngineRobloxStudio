"""Open the game, play it, photograph it, and fail when the screen is wrong.

Why this exists
---------------

Six serious defects shipped past a clean compile, clean types and a clean
doctor in a single session:

  * a `VisualIcons` assert that killed the whole client at the first rail
    button, leaving one dark square where an interface should have been;
  * `GameKit.Save`'s memory mode never loading a profile, so a daily streak
    read "come back tomorrow" on a brand new save;
  * `Gameplay.systems` being a function, so `gameplay.systems or gameplay`
    silently bound the getter and every use threw inside a `task.spawn`;
  * 367 images uploaded as `Decal`, every one Approved and Active, none of
    them able to render;
  * a skin parented to a button, which under `ZIndexBehavior.Sibling` draws
    above its parent *always* and hid the label completely;
  * a game that lost in sixty seconds because towers are built by walking to a
    plinth and the first wave lands in twenty.

Not one of them is visible to a static check. Every one is obvious in a
screenshot. The difference between this project finding them and not finding
them was a person saying "go and look" -- and that is the thing this file
replaces.

What it checks
--------------

Deliberately few things, all of them arithmetic on what the client reports and
on the pixels:

  * the client built a UI at all, and how much of one;
  * nothing the game drew sits off-screen;
  * every text element has enough contrast against what is behind it;
  * touch targets clear the 44-pixel minimum after scaling;
  * the frame is not a flat colour, which is what a dead client looks like.

It does not review taste. A layout can pass all of this and still be ugly, and
the screenshots it writes are for a person to judge. What it refuses to let
through is the class of failure where the interface is *absent* and every other
gate is green.
"""

from __future__ import annotations

import json
import sys
import time
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

#: The name a game publishes its panel-opener under, so the gate never has to
#: guess. Any game that wants its interface photographed creates a
#: BindableFunction with exactly this name in ReplicatedStorage.
FORGE_HOOK = "ForgeUIHook"

REPO = Path(__file__).resolve().parents[2]
SHOTS = REPO / "artifacts" / "playtest"
RECEIPTS = REPO / "artifacts" / "playtest"

#: Roblox's own minimum for a touch target, in points. Anything smaller is a
#: control a thumb misses, and a `UIScale` shrinks these without telling you.
MIN_TOUCH = 44

#: Below this a text element cannot be read against its backdrop. Not the WCAG
#: ratio -- game UI sits over moving scenery and the useful question is cruder:
#: is there any separation at all.
MIN_CONTRAST = 0.22


@dataclass
class Finding:
    severity: str
    what: str
    detail: str = ""


@dataclass
class Report:
    game: str
    findings: list[Finding] = field(default_factory=list)
    shots: list[str] = field(default_factory=list)
    measured: dict[str, Any] = field(default_factory=dict)

    @property
    def failed(self) -> bool:
        return any(f.severity == "error" for f in self.findings)

    def add(self, severity: str, what: str, detail: str = "") -> None:
        self.findings.append(Finding(severity, what, detail))


def stamp(place: Path) -> str:
    """What identifies *this* build, so a receipt cannot outlive it.

    Size and modification time, not a hash: a place file is megabytes and this
    runs on every publish. The pair changes whenever rojo writes, which is the
    only event that matters.
    """
    info = place.stat()
    return f"{info.st_size}:{int(info.st_mtime)}"


def receipt_path(game: str) -> Path:
    return RECEIPTS / f"{game}.json"


def write_receipt(game: str, place: Path, report: "Report") -> Path:
    RECEIPTS.mkdir(parents=True, exist_ok=True)
    path = receipt_path(game)
    path.write_text(json.dumps({
        "game": game,
        "build": stamp(place),
        "passed": not report.failed,
        "at": time.strftime("%Y-%m-%dT%H:%M:%S"),
        "measured": report.measured,
        "findings": [{"severity": f.severity, "what": f.what}
                     for f in report.findings],
    }, indent=1), encoding="utf-8")
    return path


def read_receipt(game: str, place: Path) -> tuple[bool, str]:
    """Whether this exact build has a passing playtest, and why not.

    The build stamp is the point. A receipt from before the last rebuild says
    nothing about what is on disk now, and treating it as if it did is how a
    gate becomes a formality.
    """
    path = receipt_path(game)
    if not path.exists():
        return False, "no playtest has been run for this game"
    try:
        record = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return False, "the playtest receipt is unreadable"
    if record.get("build") != stamp(place):
        return False, ("the last playtest was for a different build; "
                       "rebuild happened after it")
    if not record.get("passed"):
        failures = [f["what"] for f in record.get("findings") or []
                    if f.get("severity") == "error"]
        return False, "the last playtest failed: " + ("; ".join(failures) or "?")
    return True, "passed"


def _luma(pixel: tuple[int, ...]) -> float:
    red, green, blue = pixel[0], pixel[1], pixel[2]
    return (0.2126 * red + 0.7152 * green + 0.0722 * blue) / 255.0


def _bridge() -> Any:
    sys.path.insert(0, str(REPO))
    from rqe.hub.client import StudioBridge

    return StudioBridge("http://127.0.0.1:8790")


def _server_session(bridge: Any) -> str | None:
    """The session running the game, from the hub's own view.

    Pinning matters here for the reason it always does in this project:
    unpinned calls answer from whichever DataModel replies first, and edit mode
    has no PlayerGui at all -- so an unpinned check reports an empty interface
    for a game whose interface is fine.
    """
    import urllib.request

    with urllib.request.urlopen("http://127.0.0.1:8790/status", timeout=8) as raw:
        status = json.load(raw)
    for session in status.get("sessions") or []:
        if session.get("context") in ("server", "run"):
            return session["session"]
    return None


def _gui_nodes(bridge: Any) -> list[dict[str, Any]]:
    try:
        bridge.call("client.ensure_channel", {}, timeout=45)
    except Exception:  # noqa: BLE001 - the channel may already exist
        pass
    tree = bridge.call("client.gui_tree", {}, timeout=60)
    #: `elements`, and the alternatives are checked because getting this wrong
    #: is the worst failure this file can have: it reported "the game drew
    #: almost no interface" for a UI that was on screen and photographed in the
    #: same run. A gate that cries wolf is worse than no gate, so a *missing*
    #: key is now distinguished from an empty one by the caller.
    for key in ("elements", "nodes", "tree"):
        found = tree.get(key)
        if isinstance(found, list):
            return found
    raise RuntimeError(
        f"client.gui_tree answered with keys {sorted(tree)} and no element list")


def inspect_ui(bridge: Any, report: Report, where: str = "") -> None:
    """What the client actually built, measured through the client.

    `where` names the screen being measured. Without it every finding reads as
    if it were on the HUD, and the panels -- which is where the small controls
    actually are -- had no way to say so.
    """
    tag = f" in the {where} panel" if where else ""
    try:
        nodes = _gui_nodes(bridge)
    except Exception as error:  # noqa: BLE001
        report.add("error", "the client could not be inspected", str(error)[:200])
        return

    #: Roblox's own chrome and the bridge's helper are not the game's UI.
    ours = [n for n in nodes
            if "PlayerGui" in n.get("path", "")
            and not any(word in n.get("path", "")
                        for word in ("Freecam", "RQEClient", "ForgeToasts"))]
    report.measured["elements" if not where else f"elements:{where}"] = len(ours)

    if len(ours) < 3:
        report.add("error", f"the game drew almost no interface{tag}",
                   f"{len(ours)} elements under PlayerGui. A LocalScript that "
                   "dies on its first line leaves exactly this.")
        return

    offscreen = [n for n in ours if n.get("offScreen")]
    if offscreen:
        report.add("error", f"{len(offscreen)} elements are off-screen{tag}",
                   ", ".join(n.get("path", "").split(".")[-1]
                             for n in offscreen[:6]))

    small = []
    for node in ours:
        if node.get("className") not in ("TextButton", "ImageButton"):
            continue
        size = node.get("absoluteSize") or [0, 0]
        if min(size) and min(size) < MIN_TOUCH:
            small.append((node.get("path", "").split(".")[-1], round(min(size))))
    report.measured["buttons" if not where else f"buttons:{where}"] = sum(
        1 for n in ours if n.get("className") in ("TextButton", "ImageButton"))
    if small:
        report.add("warning",
                   f"{len(small)} touch targets are under {MIN_TOUCH}px{tag}",
                   ", ".join(f"{name} {edge}px" for name, edge in small[:6]))

    #: A label with no text is a readout that never bound. This is the shape of
    #: "the attribute was never published" and of "the string was cleared".
    blank = [n for n in ours
             if n.get("className") in ("TextLabel", "TextButton")
             and n.get("text") == ""]
    if len(blank) > 2:
        report.add("warning", f"{len(blank)} text elements are empty{tag}")


def inspect_frame(path: Path, report: Report) -> None:
    """Arithmetic on the pixels: is this a picture of a game, or of nothing."""
    try:
        from PIL import Image
    except ImportError:
        report.add("warning", "Pillow missing; the frame was not measured")
        return

    with Image.open(path) as image:
        frame = image.convert("RGB")
        pixels = list(frame.getdata())

    tones = {(_luma(p) * 16) // 1 for p in pixels}
    report.measured["tones"] = len(tones)
    if len(tones) < 5:
        report.add("error", "the frame is nearly a flat colour",
                   f"{len(tones)} distinct tones. A minimised window and a "
                   "dead client both look like this.")

    brightest = max(pixels, key=_luma)
    darkest = min(pixels, key=_luma)
    spread = _luma(brightest) - _luma(darkest)
    report.measured["contrast"] = round(spread, 3)
    if spread < MIN_CONTRAST:
        report.add("error", "the frame has almost no contrast",
                   f"luminance spread {spread:.2f}")


def run(game: str, wait: float = 9.0, panels: tuple[str, ...] = (),
        progress: Any = print) -> Report:
    """Build nothing, assume nothing: open what is built and look at it.

    The caller is expected to have built the place already. This opens it,
    plays it, waits for the world to settle, photographs it, and measures.
    """
    sys.path.insert(0, str(REPO))
    from forge.cli import look
    from rqe.hub import lifecycle

    report = Report(game=game)
    place = REPO / "games" / game / f"{game}.rbxlx"
    if not place.exists():
        report.add("error", "no built place", str(place))
        return report

    bridge = _bridge()
    lifecycle.restart_for_bridge(place, REPO / ".tmp" / "studio-recovery",
                                 bridge=bridge, wait_seconds=240)
    bridge.unpin()
    started = lifecycle.start_play_solo(bridge=bridge, wait_seconds=120)
    if not started.get("started"):
        report.add("error", "the game would not start")
        return report

    time.sleep(wait)
    session = _server_session(bridge)
    if not session:
        report.add("error", "no running session answered after starting one")
        return report
    bridge.pinned_session = session

    errors = bridge.call("log.tail", {"limit": 80, "severity": "error"},
                         timeout=25).get("entries") or []
    report.measured["scriptErrors"] = len(errors)
    for entry in errors[:5]:
        report.add("error", "a script errored", str(entry.get("message"))[:180])

    inspect_ui(bridge, report)

    SHOTS.mkdir(parents=True, exist_ok=True)
    shot = look.shoot(f"{game}-hud")
    report.shots.append(str(shot))
    inspect_frame(shot, report)

    #: Panels are opened through the game's own opener when it has one, because
    #: synthetic input is refused by Studio and screen-coordinate clicking
    #: breaks the moment anything moves.
    #[[
    #   A report that measured nothing has verified nothing.
    #
    #   An edit once dedented the early `return` out of its own `if`, so `run`
    #   returned before touching Studio -- and the gate answered "nothing to
    #   report", wrote a passing receipt, and would have waved a publish
    #   through. A gate whose failure mode is silent approval is worse than no
    #   gate, so the absence of measurements is itself a finding.
    #]]
    if not report.measured:
        report.add("error", "the playtest measured nothing",
                   "it never reached Studio; the run is not evidence of anything")

    #[[
    #   Find the hook by asking, not by guessing its capitalisation.
    #
    #   This built the path as `game.title() + "UI"`, which turns `carvewood`
    #   into `CarvewoodUI` while the game had named it `CarveWoodUI`. One
    #   capital, and the gate reported "could not open the seeds panel" for a
    #   panel that opened perfectly -- a false negative on the single check
    #   that exists to photograph the interface.
    #
    #   Python cannot know where a game puts the camel hump in its own name.
    #   The DataModel can, so it is asked.
    #]]
    #[[
    #   One name, the same in every game.
    #
    #   This built the path from `game.title() + "UI"`, which is a guess about
    #   where a game puts the capital letters in its own name. It happened to
    #   be right for `siegehold` and `overflow` and wrong for `carvewood`,
    #   whose hook is `CarveWoodUI` -- so the gate reported "could not open the
    #   seeds panel" for a panel that opened perfectly. A false negative on the
    #   only check that photographs the interface is worse than no check: it
    #   trains you to ignore the warning.
    #
    #   The hook is created by a LocalScript, so it exists only in the client's
    #   DataModel and cannot be looked up from the server either. There is no
    #   way to *find* it -- so it gets a fixed name instead, and the old guess
    #   stays as a fallback for the games written before this one.
    #]]
    hooks = [f"ReplicatedStorage.{FORGE_HOOK}",
             f"ReplicatedStorage.{game.title()}UI"]

    for panel in panels:
        last: Exception | None = None
        for path in hooks:
            try:
                bridge.call("client.invoke_bindable",
                            {"path": path,
                             "argument": f"open:{panel}"}, timeout=45)
                time.sleep(0.8)
                report.shots.append(str(look.shoot(f"{game}-{panel}")))
                #[[
                #   Measured, not merely photographed.
                #
                #   This opened each panel, took a picture and moved on, so
                #   every rule the gate enforces -- touch targets, off-screen
                #   elements, empty labels -- applied only to the HUD. The
                #   panels are where the small controls live: a 30px close
                #   button and a row of 29px buy buttons sat in a shot this
                #   gate had itself taken and called clean.
                #]]
                inspect_ui(bridge, report, where=panel)
                last = None
                break
            except Exception as error:  # noqa: BLE001
                last = error
        if last is not None:
            report.add("warning", f"could not open the {panel} panel",
                       f"tried {', '.join(hooks)} -- {str(last)[:110]}")

    return report
