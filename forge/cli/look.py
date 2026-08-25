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

Why it appeared broken
----------------------

The capture pipeline was never broken. `rqe/capture.py` refuses a frame with
fewer than eight distinct tones, on the grounds that such a picture is of a
minimised or uncomposited window rather than of a game — and it was right every
time. `rqe studio restart` launches Studio **minimised** by default, precisely
so it stays out of the way, and a minimised window has no composited surface to
photograph.

So this brings Studio forward, points the camera, waits for the frame, and
takes the picture. The refusal that looked like a bug is kept exactly as it is:
a capture pipeline that returns a black rectangle rather than failing is one
that teaches an agent the game is black.

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


def foreground() -> bool:
    """Bring Studio forward, because a minimised window cannot be photographed.

    Done here rather than left to the caller: forgetting it produces a capture
    that fails validation for a reason that looks like a rendering bug, and
    that misdiagnosis cost this project an afternoon.
    """
    script = (
        "$p = Get-Process | Where-Object { $_.ProcessName -like '*RobloxStudio*' } "
        "| Select-Object -First 1; "
        "if ($p) { "
        "  Add-Type -Name W -Namespace N -MemberDefinition '"
        "[DllImport(\"user32.dll\")] public static extern bool ShowWindow(IntPtr h, int c);"
        "[DllImport(\"user32.dll\")] public static extern bool SetForegroundWindow(IntPtr h);'; "
        "  [N.W]::ShowWindow($p.MainWindowHandle, 9) | Out-Null; "
        "  [N.W]::SetForegroundWindow($p.MainWindowHandle) | Out-Null; 'ok' "
        "} else { 'no studio' }"
    )
    proc = subprocess.run(["powershell", "-NoProfile", "-Command", script],
                          capture_output=True, text=True, timeout=60)
    return "ok" in (proc.stdout or "")


def aim(at: tuple[float, float, float], distance: float = 60,
        height: float = 25) -> bool:
    """Point the edit-mode camera at a place in the world.

    A capture of an unaimed camera is a picture of wherever somebody left it,
    which for an automated look is almost always the sky. Framing first is
    what makes two captures of the same scene comparable.
    """
    x, y, z = at
    try:
        _call("camera.set", {
            "position": [x + distance * 0.7, y + height, z + distance * 0.7],
            "target": [x, y, z],
        })
        return True
    except LookError:
        # Not fatal: an unaimed shot of the right window still beats no shot.
        return False


def shoot(name: str = "look", settle: float = 1.2) -> Path:
    """Take one validated picture of the Studio window."""
    sys.path.insert(0, str(REPO))
    from rqe.capture import capture  # imported late: Windows-only ctypes

    SHOTS.mkdir(parents=True, exist_ok=True)
    stamp = datetime.now(timezone.utc).strftime("%H%M%S")
    out = SHOTS / f"{name}-{stamp}.png"

    foreground()
    # Let the window actually paint. Capturing the frame after raising it is
    # how you photograph a half-drawn viewport and conclude the game is grey.
    time.sleep(settle)

    shot = capture(out, viewpoint=name, required=True)
    if not out.exists() or out.stat().st_size < 20000:
        raise LookError(
            f"the capture came back at {out.stat().st_size if out.exists() else 0} bytes. "
            "That is an uncomposited window: Studio is minimised or behind something.")
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
                "target": list(centre),
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
