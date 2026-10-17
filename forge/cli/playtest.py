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
import hashlib
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
    """Content identity for the exact place build a receipt authorizes.

    Size + mtime collided in practice: a rebuilt place can have the same byte
    count and callers can preserve timestamps. Release evidence must identify
    bytes, not filesystem metadata, so this gate pays the cost of SHA-256.
    """
    digest = hashlib.sha256()
    with place.open("rb") as handle:
        while chunk := handle.read(1024 * 1024):
            digest.update(chunk)
    return digest.hexdigest()


def receipt_path(game: str) -> Path:
    return RECEIPTS / f"{game}.json"


def write_receipt(game: str, place: Path, report: "Report") -> Path:
    RECEIPTS.mkdir(parents=True, exist_ok=True)
    path = receipt_path(game)
    evidence_present = bool(report.measured)
    path.write_text(json.dumps({
        "game": game,
        "build": stamp(place),
        "passed": evidence_present and not report.failed,
        "evidencePresent": evidence_present,
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
    status = bridge.status()
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


def inspect_frame(path: Path, report: Report, region: Any = None) -> None:
    """Measure only the game region; unknown framing is blocked evidence."""
    try:
        from PIL import Image
    except ImportError:
        report.add("warning", "Pillow missing; the frame was not measured")
        return

    from rqe.viewport import crop

    if region is None:
        report.add(
            "error",
            "the game's region of the frame is unknown",
            "measuring the whole Studio window would score the ribbon and "
            "Explorer instead of the game",
        )
        return

    with Image.open(path) as image:
        frame = crop(image.convert("RGB"), region)
        pixels = list(frame.getdata())

    report.measured["frameRegion"] = region.to_dict()

    tones = {(_luma(p) * 16) // 1 for p in pixels}
    report.measured["tones"] = len(tones)
    if len(tones) < 5:
        report.add(
            "error",
            "the frame is nearly a flat colour",
            f"{len(tones)} distinct tones. A dead client looks exactly like this.",
        )

    brightest = max(pixels, key=_luma)
    darkest = min(pixels, key=_luma)
    spread = _luma(brightest) - _luma(darkest)
    report.measured["contrast"] = round(spread, 3)
    if spread < MIN_CONTRAST:
        report.add(
            "error",
            "the frame has almost no contrast",
            f"luminance spread {spread:.2f}",
        )


def _native_viewport_shot(
    bridge: Any,
    session: str,
    name: str,
    *,
    include_ui: bool = True,
) -> tuple[Path, Any]:
    """Capture only Studio's rendered viewport, never the desktop window."""
    from rqe.capture import capture_native_viewpoint
    from rqe.viewport import Rect

    SHOTS.mkdir(parents=True, exist_ok=True)
    output = SHOTS / f"{name}-{int(time.time() * 1000)}.png"
    shot = capture_native_viewpoint(
        bridge,
        target="",
        output=output,
        viewpoint=name,
        expected_session=session,
        world_only=False,
        include_ui=include_ui,
    )
    if not shot.trustworthy:
        raise RuntimeError(
            "native Studio viewport capture was not trustworthy: "
            + "; ".join(shot.integrity_issues)
        )
    if shot.width <= 0 or shot.height <= 0:
        raise RuntimeError("native Studio viewport capture returned an empty frame")
    return output, Rect(0, 0, shot.width, shot.height)


def run(game: str, wait: float = 9.0, panels: tuple[str, ...] = (),
        progress: Any = print) -> Report:
    """Build nothing, assume nothing: open what is built and look at it.

    The caller is expected to have built the place already. This opens it,
    plays it, waits for the world to settle, photographs it, and measures.
    """
    sys.path.insert(0, str(REPO))
    from rqe.hub import lifecycle

    report = Report(game=game)
    place = REPO / "games" / game / f"{game}.rbxlx"
    if not place.exists():
        report.add("error", "no built place", str(place))
        return report

    bridge = _bridge()
    ensured = lifecycle.ensure_studio_session(
        place,
        REPO / ".tmp" / "studio-recovery",
        bridge,
        wait_seconds=45,
        background=True,
        allow_cold_launch=False,
    )
    if not ensured.get("ready"):
        report.add(
            "error",
            "background Studio session is unavailable",
            str(ensured.get("reason") or "open the built place once explicitly in Studio"),
        )
        return report

    bridge.unpin()
    started = lifecycle.start_play_solo(
        bridge=bridge,
        wait_seconds=120,
        allow_foreground_fallback=False,
    )
    if not started.get("started"):
        report.add(
            "error",
            "the game would not start through StudioTestService",
            str(started.get("reason") or started.get("nativeAttempt") or ""),
        )
        return report

    #[[
    #   Wait for the interface, not for the clock.
    #
    #   This slept a flat nine seconds on every run, which is both too long on
    #   a warm machine and not long enough on a cold one -- the failure mode of
    #   the second being a photograph of a game that had not finished building
    #   its HUD, reported as "the game drew almost no interface".
    #
    #   Polling for what the wait was actually for costs a second or two on a
    #   normal run and still gives a slow machine its nine.
    #]]
    #[[
    #   Wait for the interface to *settle*, not merely to appear.
    #
    #   The first version broke out as soon as three elements existed, which is
    #   a HUD that has started drawing. A game whose server spends eleven
    #   seconds carving terrain answers that test at second two -- so the gate
    #   photographed a half-built game, reported an empty readout and no
    #   weapon, and every one of those absences was read as a bug that did not
    #   exist.
    #
    #   Two consecutive identical counts is enough: it costs a second on a warm
    #   run and it is the difference between measuring a game and measuring a
    #   loading screen.
    #]]
    session = None
    #[[
    #   Ask the game, and only guess when it does not answer.
    #
    #   `Debug.ready` is one line at the end of a bootstrap and it replaces
    #   every heuristic below with a fact. The heuristics stay for games
    #   written before it existed -- and because a game whose bootstrap throws
    #   never declares anything, so waiting forever for the signal would turn a
    #   broken game into a hang instead of a report.
    #]]
    #[[
    #   The readiness wait gets its own budget, not the whole one.
    #
    #   This shared a deadline with the settle loop below, so a game that never
    #   declares readiness -- every game written before `Debug.ready` existed --
    #   spent the entire budget waiting for a signal that was never coming, and
    #   the settle loop then ran zero times. The report was "no running session
    #   answered after starting one" for a game that had booted fine and was
    #   sitting there answering.
    #]]
    budget = max(wait, 3.0) * 3
    declared = False
    ready_deadline = time.time() + budget * 0.6
    while time.time() < ready_deadline:
        try:
            value = bridge.call("dm.properties", {
                "path": "ReplicatedStorage.ForgeReady",
                "properties": ["Value"],
            })
            if (value.get("properties") or {}).get("Value"):
                declared = True
                break
        except Exception:  # noqa: BLE001 - not there yet, or never will be
            pass
        time.sleep(0.75)

    settled, last = 0, (-1, -1)
    #: Whatever the readiness wait did not use, plus a floor, so the settle
    #: loop always gets a real chance to run.
    deadline = time.time() + (budget if not declared else budget * 0.5)
    while time.time() < deadline:
        session = _server_session(bridge)
        if session:
            bridge.pinned_session = session
            try:
                count = len(_gui_nodes(bridge))
            except Exception:  # noqa: BLE001 - not up yet is not an error
                count = -1
            #: Stable *and* saying something. A count that stops changing is a
            #: HUD that has finished being built, not one that has finished
            #: being filled -- and a readout still reading "Locating" is
            #: exactly what a game whose server is mid-boot looks like.
            try:
                filled = sum(1 for n in _gui_nodes(bridge)
                             if n.get("className") in ("TextLabel", "TextButton")
                             and (n.get("text") or "").strip()
                             and "RQEClient" not in n.get("path", ""))
            except Exception:  # noqa: BLE001
                filled = 0
            #: Count what is *filled*, not what exists. A HUD builds its labels
            #: in one frame and fills them as the answers arrive, so counting
            #: elements settles while the readout still says "Locating" and the
            #: weapon panel is blank -- which is exactly the half-booted
            #: photograph this poll was added to prevent, one layer down.
            if declared or (count >= 3 and filled >= 1):
                settled = settled + 1 if (count, filled) == last else 0
                last = (count, filled)
                if settled >= 2:
                    break
            else:
                last = (count, filled)
        time.sleep(0.5)
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
    with bridge.lease_scope(
        agent_id="forge-playtest-native-capture",
        session_id=session,
        context="running",
        ttl_seconds=120.0,
    ):
        shot, region = _native_viewport_shot(
            bridge,
            session,
            f"{game}-hud",
            include_ui=True,
        )
    report.shots.append(str(shot))
    report.measured["viewport"] = region.to_dict()
    report.measured["captureBackend"] = "StudioCaptureService"
    inspect_frame(shot, report, region)

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
                with bridge.lease_scope(
                    agent_id="forge-playtest-panel",
                    session_id=session,
                    context="running",
                    ttl_seconds=120.0,
                ):
                    bridge.call(
                        "client.invoke_bindable",
                        {"path": path, "argument": f"open:{panel}"},
                        timeout=45,
                    )
                    time.sleep(0.8)
                    panel_shot, _panel_region = _native_viewport_shot(
                        bridge,
                        session,
                        f"{game}-{panel}",
                        include_ui=True,
                    )
                report.shots.append(str(panel_shot))
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
