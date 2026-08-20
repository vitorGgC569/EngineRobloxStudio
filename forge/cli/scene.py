"""Move a scene between a live session and the repository.

The gap this closes
-------------------

The Editor could already do everything except keep its work. You could select
a rock, move it, rotate it, ground it, undo it — and the moment the session
ended, all of it was gone. `Editor.save()` serialises the scene and publishes
it to `Workspace.ForgeScenes.<name>` as a StringValue, with a comment saying
that is what lets `forge scene pull` collect it. That command did not exist.

So the engine had a tool that edits a world and no way to keep the edit. That
is the difference between an editor and an inspector, and it is why moving a
rock in the viewport was a demonstration rather than authoring.

    forge scene pull provingground          live session -> repo
    forge scene push provingground          repo -> live session
    forge scene list                        what the session is holding

Scenes land in `games/<name>/scenes/<scene>.json` and are loaded by the game
at startup, so a pulled edit survives a rebuild, a restart, and the next
person to open the project.
"""

from __future__ import annotations

import json
import subprocess
import sys
from pathlib import Path
from typing import Any

REPO = Path(__file__).resolve().parents[2]


class BridgeError(RuntimeError):
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
        raise BridgeError(f"bridge did not return JSON: {exc}\n{raw[:300]}")
    if not envelope.get("ok"):
        raise BridgeError(json.dumps(envelope.get("error"))[:300])
    return envelope.get("result")


def scenes_dir(game: str) -> Path:
    return REPO / "games" / game / "scenes"


def list_live() -> list[str]:
    """Scene names the running session has published."""
    try:
        result = _call("instance.children", {"path": "Workspace.ForgeScenes"}) or {}
    except BridgeError:
        return []
    children = result.get("children") or []
    return [c.get("name") for c in children if c.get("name")]


def pull(game: str, name: str | None = None) -> list[Path]:
    """Copy scenes out of the live session and into the repository.

    Reads the StringValue the Editor publishes. Nothing is interpreted here on
    purpose: the JSON the engine wrote is the JSON that lands on disk, so a
    round trip cannot quietly reformat someone's world.
    """
    names = [name] if name else list_live()
    if not names:
        raise BridgeError(
            "no scenes published; call Editor.save() in the session first")

    written: list[Path] = []
    target = scenes_dir(game)
    target.mkdir(parents=True, exist_ok=True)

    for scene in names:
        # Read through `bridge.exec`, not `dm.properties`: the latter returns
        # a generic property set and simply omits `StringValue.Value`, so the
        # first version pulled every scene as empty and reported success.
        # Asking Luau for the field is the only way to know it came back.
        source = (
            'local holder = workspace:FindFirstChild("ForgeScenes")\n'
            'local value = holder and holder:FindFirstChild(%s)\n'
            'return value and (value :: StringValue).Value or nil'
            % json.dumps(scene)
        )
        # `bridge.exec` wraps what the script returned inside `returned`;
        # reading the envelope itself gets a dict of timings, which the first
        # version then discarded as "not a string" and reported as an empty
        # scene.
        envelope = _call("bridge.exec", {"source": source}) or {}
        value = envelope.get("returned") if isinstance(envelope, dict) else None
        if not value:
            print(f"  {scene}: empty, skipped")
            continue
        # Parsed once purely to refuse writing something that is not JSON, then
        # re-indented so a diff of a moved rock is one readable line.
        try:
            parsed = json.loads(value)
        except json.JSONDecodeError as exc:
            print(f"  {scene}: not valid JSON ({exc}); skipped")
            continue
        path = target / f"{scene}.json"
        path.write_text(json.dumps(parsed, indent=2, ensure_ascii=False), encoding="utf-8")
        placements = len(parsed.get("placements") or parsed.get("items") or [])
        print(f"  {scene}: {placements} placements -> {path.relative_to(REPO)}")
        written.append(path)
    return written


_PUSH_LUAU = """
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Forge = require(ReplicatedStorage:WaitForChild("Forge"))
local Editor = Forge.Editor
Editor.loadJson(%(json)s)

-- Report what the editor is holding afterwards rather than what `loadJson`
-- handed back: `open` returns its own handle, so trusting that made a
-- successful push print "pushed None".
local scene = Editor.scene()
return {
	name = scene and scene.name or nil,
	placements = scene and #scene.placements or 0,
}
"""


def push(game: str, name: str) -> dict:
    """Send a scene from the repository into the open session."""
    path = scenes_dir(game) / f"{name}.json"
    if not path.exists():
        raise BridgeError(f"no scene at {path.relative_to(REPO)}")
    text = path.read_text(encoding="utf-8")
    source = _PUSH_LUAU % {"json": json.dumps(text)}
    envelope = _call("bridge.exec", {"source": source}) or {}
    # Same unwrapping as `pull`. Forgetting it here is what made a working
    # push report "pushed None".
    return envelope.get("returned") or {}
