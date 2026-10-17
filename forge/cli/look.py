"""Let the agent see what it built.

Why this is the most important file here
----------------------------------------

Every visual bug in this project was found by a person looking at a screen. A
character sliding with no animation. A foot folded into a crouch. Limbs
detached from a torso. Test bodies falling out of the sky. A bow held at the
wrong angle. Not one of them appeared in a test, and several passed every
static check, the doctor, and thirty-eight live scenarios on the way through.

An agent that cannot look at its own work is an agent whose visual quality is
capped by how much of a person's attention it can borrow.

How it captures now
-------------------

The old implementation photographed a Windows window and therefore had to
restore and focus Studio before every shot. The current path captures the
rendered viewport from inside Studio through `StudioCaptureService`. Camera
control and screenshot bytes share the same pinned bridge session, so the
command can run while Studio stays in the background and a frame of the IDE
cannot be mistaken for evidence about the game.

    forge look                        one shot of whatever is on screen
    forge look --at 0,40,0 --from 60  frame a point from a distance
    forge look --tour                 the standard set: spawn, arena, sky
"""

from __future__ import annotations

import json
import subprocess
import sys
import time
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

REPO = Path(__file__).resolve().parents[2]
SHOTS = REPO / "artifacts" / "forge-look"


class LookError(RuntimeError):
    pass


def _call(method: str, params: dict | None = None, timeout: int = 120) -> Any:
    args = [sys.executable, str(REPO / "rqe.py"), "studio", "call", method]
    if params:
        args += ["--params", json.dumps(params)]
    proc = subprocess.run(args, capture_output=True, text=True,
                          timeout=timeout + 30, cwd=str(REPO))
    raw = proc.stdout.strip() or proc.stderr.strip()
    try:
        envelope = json.loads(raw)
    except json.JSONDecodeError as exc:
        raise LookError(f"bridge did not return JSON: {exc} / {raw[:200]}")
    if not envelope.get("ok"):
        raise LookError(json.dumps(envelope.get("error"))[:300])
    return envelope.get("result")


def aim(at: tuple[float, float, float], distance: float = 60,
        height: float = 25) -> bool:
    """Point the edit-mode camera at a place in the world.

    A capture of an unaimed camera is a picture of wherever somebody left it,
    which for an automated look is almost always the sky. Framing first is
    what makes two captures of the same scene comparable.
    """
    x, y, z = at
    try:
        #: `lookAt`, not `target`. This said `target` for weeks; the schema
        #: rejected every call, the except below swallowed it, and `forge look`
        #: quietly photographed wherever the camera was last left -- twice
        #: returning byte-identical frames for two different subjects. An aim
        #: that fails now says so.
        _call("camera.set", {
            "position": [x + distance * 0.7, y + height, z + distance * 0.7],
            "lookAt": [x, y, z],
        })
        return True
    except LookError as error:
        print(f"  ! camera not aimed: {error}", file=sys.stderr)
        return False



def shoot(name: str = "look", settle: float = 0.35) -> Path:
    """Capture the rendered Studio viewport without touching desktop focus."""
    sys.path.insert(0, str(REPO))
    from rqe.capture import capture_native_viewpoint
    from rqe.hub.client import StudioBridge
    from rqe.workspace import hub_url

    SHOTS.mkdir(parents=True, exist_ok=True)
    stamp = datetime.now(timezone.utc).strftime("%H%M%S-%f")
    out = SHOTS / f"{name}-{stamp}.png"

    bridge = StudioBridge(hub_url())
    world_only = False
    try:
        session = bridge.pin_to_running(timeout=4)
    except Exception:
        try:
            session = bridge.pin_to_context("edit", timeout=8)
            world_only = True
        except Exception as exc:
            raise LookError(
                "no compatible Studio bridge session is available for native capture: "
                + str(exc)
            ) from exc

    try:
        with bridge.lease_scope(
            agent_id="forge-look-native-capture",
            session_id=session,
            context="any",
            ttl_seconds=60.0,
        ):
            shot = capture_native_viewpoint(
                bridge,
                target="",
                output=out,
                viewpoint=name,
                expected_session=session,
                world_only=world_only,
                include_ui=True,
                settle_seconds=max(0.0, settle),
            )
    except Exception as exc:
        raise LookError(f"native Studio viewport capture failed: {exc}") from exc

    if not shot.trustworthy:
        raise LookError(
            "native Studio viewport capture was not trustworthy: "
            + "; ".join(shot.integrity_issues)
        )
    if not out.exists() or out.stat().st_size < 1000:
        raise LookError("native Studio viewport capture returned no usable image bytes")
    return out


#: The standard set, for a Forge game.
#:
#: Named viewpoints rather than arbitrary angles, so two runs a week apart are
#: comparable and a regression is visible as a difference rather than as a
#: feeling.
TOUR = [
    {"name": "spawn", "at": (0, 38, 0), "distance": 40, "height": 14},
    {"name": "arena", "at": (0, 34, 0), "distance": 150, "height": 90},
    {"name": "ring", "at": (96, 34, 0), "distance": 60, "height": 22},
    {"name": "horizon", "at": (0, 34, 0), "distance": 300, "height": 40},
]

#: Angles relative to whatever is being looked at, rather than places.
#:
#: `TOUR` above is four points written for one arena, and it is worth exactly
#: as much on the next game as the coordinates happen to be. These are yaw and
#: pitch around a subject, with distance and height as fractions of its size,
#: so the same seven shots frame a boss, a lobby or a whole map without anybody
#: editing numbers.
#:
#: Adapted from a bridge that photographs a Studio scene from a fixed set of
#: angles for a vision model to inspect. The set is chosen, not arbitrary:
#: three orthogonal views to read shape, an isometric to read arrangement, a
#: low hero shot for how it presents, and two wides for context — which is
#: roughly what an artist takes when asked "show me the thing".
#:
#: yaw and pitch are degrees; distance and lift are multiples of the subject's
#: largest horizontal dimension.
ANGLES = [
    {"name": "front",      "yaw": 0,   "pitch": 0,   "distance": 1.6, "lift": 0.10},
    {"name": "side-right", "yaw": 85,  "pitch": -5,  "distance": 1.6, "lift": 0.10},
    {"name": "side-left",  "yaw": -85, "pitch": -5,  "distance": 1.6, "lift": 0.10},
    {"name": "isometric",  "yaw": 45,  "pitch": -25, "distance": 1.8, "lift": 0.35},
    {"name": "hero-low",   "yaw": 15,  "pitch": -8,  "distance": 1.2, "lift": 0.05},
    {"name": "wide",       "yaw": 0,   "pitch": -20, "distance": 3.0, "lift": 0.80},
    {"name": "high",       "yaw": 180, "pitch": -65, "distance": 2.4, "lift": 2.20},
]


def orbit(centre: tuple[float, float, float], size: float,
          angles: list[dict] | None = None) -> list[Path]:
    """Photograph one subject from every angle in `ANGLES`.

    `size` is the subject's largest horizontal dimension, which is what turns
    the fractions above into studs. Reading it from the world rather than
    guessing is what makes the same seven shots work on a helmet and on a
    mountain; `world.bounds` over the bridge already answers it.
    """
    import math

    shots: list[Path] = []
    for angle in angles or ANGLES:
        radians = math.radians(angle["yaw"])
        reach = size * angle["distance"]
        # Pitch becomes height, because the camera looks at the centre either
        # way — raising the eye and letting it look down is the same framing
        # with one fewer rotation to get wrong.
        height = size * angle["lift"] + reach * math.tan(math.radians(-angle["pitch"]))

        # `aim` puts the eye at a fixed 45 degrees, which is the one thing an
        # orbit cannot use, so this positions the camera itself.
        try:
            _call("camera.set", {
                "position": [centre[0] + math.sin(radians) * reach,
                             centre[1] + height,
                             centre[2] + math.cos(radians) * reach],
                "lookAt": list(centre),
            })
        except LookError:
            # An unaimed shot of the right window still beats no shot.
            pass

        time.sleep(0.4)
        try:
            shots.append(shoot(angle["name"]))
        except LookError as exc:
            print(f"  {angle['name']}: {exc}")
    return shots


def tour(points: list[dict] | None = None) -> list[Path]:
    """Photograph the standard viewpoints, in order."""
    shots = []
    for point in points or TOUR:
        aim(point["at"], point.get("distance", 60), point.get("height", 25))
        time.sleep(0.4)
        try:
            shots.append(shoot(point["name"]))
        except LookError as exc:
            print(f"  {point['name']}: {exc}")
    return shots
