"""Read the running game's DataModel, from whichever side actually has it.

Why this exists
---------------

The bridge grew `client.tree` and `client.properties` -- the client-side mirrors
of `dm.tree` and `dm.properties` -- and they were added to the plugin dispatcher,
to the command manifest, to the client source and to `CLAUDE.md`, which now
tells every agent to use them.

Nothing called them. Not one line of Python in the repository, not one CLI
command. `grep client.tree --include=*.py` returned zero results the day after
the commit that introduced them. Reaching the capability meant hand-writing an
HTTP POST, which is precisely the state the CLI exists to end.

That gap is not an oversight in one commit; it is the shape of the whole
problem. The capability was built, documented, and left with no front door.

Why both sides, in one command
------------------------------

`dm.*` answers from the server. Everything built on the client -- a viewmodel in
a ViewportFrame, a part hidden by `LocalTransparencyModifier`, an effect that
exists on one machine -- is simply *absent* there, and the absence looks
identical to the thing being broken.

The measured proof, run against `holdout`:

    dm.tree     Players.<p>.PlayerGui.ForgeViewmodel  ->  E_NOT_FOUND
    client.tree Players.<p>.PlayerGui.ForgeViewmodel  ->  ForgeViewmodel [ScreenGui]
                                                            View [ViewportFrame]
                                                              WorldModel
                                                                Gun_m9 [Model]

Before this, a first-person weapon was debugged by writing state into a TextLabel
and reading it back through `client.gui_tree`, because the GUI tree was the only
channel out of a running client. That worked, and it is the shape of a missing
capability rather than a clever trick.

So the two sides are one command with one flag, because the only real difference
at a call site is *which side you are asking*, and making that a flag is what
stops somebody debugging the server's account of a client-only object.

    forge inspect Workspace                        the server's tree
    forge inspect --client Players.me.PlayerGui     the client's tree
    forge inspect --client <path> --props Value,Text
"""

from __future__ import annotations

import json
import subprocess
import sys
from pathlib import Path
from typing import Any
from rqe.workspace import hub_url

REPO = Path(__file__).resolve().parents[2]

DEFAULT_HUB = hub_url()


class InspectError(RuntimeError):
    """The bridge could not answer, and the message says why."""


def _call(method: str, params: dict[str, Any], timeout: int = 60) -> Any:
    """One bridge command, through the hub the rest of `forge` already uses."""

    #: Counted here as well as inside `StudioBridge`, because this path spawns
    #: a *subprocess* to reach the bridge -- the in-process counter lives in the
    #: child and its ledger run does not exist. Without this the two chattiest
    #: commands in the repository would report zero round trips, which is the
    #: shape of under-reporting this ledger exists to prevent.
    from rqe.ledger import record_bridge_call
    import time as _time

    _started = _time.perf_counter()
    proc = subprocess.run(
        [sys.executable, str(REPO / "rqe.py"), "studio", "call", method,
         "--params", json.dumps(params), "--timeout", str(timeout)],
        capture_output=True, text=True, timeout=timeout + 30, cwd=str(REPO),
    )
    record_bridge_call(method, _time.perf_counter() - _started,
                       ok=proc.returncode == 0)
    raw = proc.stdout.strip() or proc.stderr.strip()
    if not raw:
        raise InspectError(
            "the bridge returned nothing. Start the hub with: "
            "python rqe.py studio serve")
    try:
        envelope = json.loads(raw)
    except json.JSONDecodeError as exc:
        raise InspectError(f"the bridge did not return JSON: {exc} / {raw[:300]}")
    if not envelope.get("ok"):
        raise InspectError(json.dumps(envelope.get("error"))[:400])
    return envelope.get("result")


def tree(path: str, *, client: bool = False, depth: int = 3,
         timeout: int = 60) -> Any:
    """The children under `path`, from the server or from a running client."""

    return _call("client.tree" if client else "dm.tree",
                 {"path": path, "depth": depth}, timeout)


def properties(path: str, names: list[str], *, client: bool = False,
               timeout: int = 60) -> Any:
    """Named properties of one instance, from the server or from a client."""

    return _call("client.properties" if client else "dm.properties",
                 {"path": path, "properties": names}, timeout)


def _render_tree(node: Any, indent: int = 0) -> list[str]:
    """The tree as a person reads it, rather than as JSON.

    A raw dump of the DataModel is unreadable at the depth anybody actually
    wants -- and reading it is the whole reason to have asked.
    """

    if not isinstance(node, dict):
        return [("  " * indent) + str(node)]

    name = node.get("name") or node.get("Name") or "?"
    class_name = node.get("className") or node.get("ClassName") or ""
    line = ("  " * indent) + (f"{name} [{class_name}]" if class_name else str(name))
    out = [line]
    children = node.get("children") or node.get("Children") or []
    if isinstance(children, list):
        for child in children:
            out.extend(_render_tree(child, indent + 1))
    return out


def render(result: Any, *, client: bool) -> str:
    side = "client" if client else "server"
    if result in (None, {}, []):
        return (f"forge inspect: nothing at that path on the {side}.\n\n"
                + ("  The server has no client-only objects in it. A viewmodel, a\n"
                   "  LocalTransparencyModifier or any effect built in a LocalScript\n"
                   "  exists only on the client -- ask that side with --client."
                   if not client else
                   "  No client answered, or the path does not exist there. A client\n"
                   "  only exists while the game is running: start it with\n"
                   "  `python rqe.py studio play_solo`."))

    payload = result
    if isinstance(payload, dict) and "tree" in payload:
        payload = payload["tree"]
    if isinstance(payload, dict) and ("children" in payload or "className" in payload):
        return f"forge inspect ({side})\n\n  " + "\n  ".join(_render_tree(payload))
    return f"forge inspect ({side})\n\n" + json.dumps(payload, indent=2)
