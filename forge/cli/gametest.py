"""Run gameplay scenarios inside the live game and report the result.

What this is for
----------------

Every other test in this project reads source. This one plays the game: it
spawns real rigs into the real world, drives them through the real combat
code, and asserts on real health. When it fails, the game is broken.

That distinction is the whole reason the module exists. Every genuine bug
found in this project so far — an animator that resolved no joints, an actor
loop that ran at a quarter of its configured rate, a property that does not
exist on this Roblox build — was found by running the game, and most were
found by a person watching a screen. This is the same detection without the
person.

    forge gametest                 run every scenario in the open place
    forge gametest --filter combat run the ones whose names match

How it runs
-----------

Scenarios live in the game's own source under `src/server/tests/` and register
with `Forge.Testing.scenario`. The *game* runs them, during its own bootstrap,
and publishes the report to a replicated StringValue; this file reads that and
formats it.

Running them from here was the obvious design and the wrong one: `bridge.exec`
only executes in Studio's edit context, and a suite that spawns Humanoids and
waits for damage needs a game that is actually running. Reading a published
report works from any context and has the useful side effect that re-reading a
finished run costs nothing.
"""

from __future__ import annotations

import json
import subprocess
import time
import sys
from pathlib import Path
from typing import Any

REPO = Path(__file__).resolve().parents[2]


class BridgeError(RuntimeError):
    pass



def live_place() -> str | None:
    """Which place the connected Studio session has open, if any.

    Used to refuse a suite run attributed to the wrong project: the report this
    module reads comes from whatever is running, and nothing inside it says
    which game produced it.

    Goes through the same subprocess transport as `_call` rather than opening
    its own HTTP connection -- one way in, so a change of hub address or auth
    does not leave a second path quietly broken.
    """
    proc = subprocess.run(
        [sys.executable, str(REPO / "rqe.py"), "studio", "call", "bridge.ping",
         "--params", "{}", "--timeout", "10"],
        capture_output=True, text=True, timeout=40, cwd=str(REPO),
    )
    try:
        envelope = json.loads(proc.stdout.strip() or proc.stderr.strip())
    except json.JSONDecodeError:
        return None
    #: `place` rides on the envelope beside the result, not inside it.
    return envelope.get("place")


def boot(game: str, wait_seconds: int = 240) -> None:
    """Open the built place and start it, so there is a report to read.

    `run` reads a report the *running* game published, and nothing was starting
    one. The suite therefore only worked when a play session happened to be
    left over from something else -- which made the fastest feedback in the
    engine, the one that needs no screenshots and finishes in a second, the one
    that could not be invoked on its own.

    This is deliberately the same lifecycle `playtest` uses. Two ways to start
    a game is two things to keep working.
    """
    sys.path.insert(0, str(REPO))
    from rqe.hub import lifecycle
    from rqe.hub.client import StudioBridge

    place = REPO / "games" / game / f"{game}.rbxlx"
    if not place.exists():
        raise BridgeError(f"no built place at {place}; run `forge build {game}`")

    bridge = StudioBridge("http://127.0.0.1:8790")
    lifecycle.restart_for_bridge(place, REPO / ".tmp" / "studio-recovery",
                                 bridge=bridge, wait_seconds=wait_seconds)
    bridge.unpin()
    started = lifecycle.start_play_solo(bridge=bridge, wait_seconds=120)
    if not started.get("started"):
        raise BridgeError("the game would not start")


def run(filter_text: str | None = None, timeout: int = 240) -> dict:
    """Read the report the running game published.

    Not `bridge.exec`: that only executes in edit mode, and a gameplay suite
    needs a game that is actually running. The server runs the suite during
    its own bootstrap and publishes the result to a replicated StringValue,
    which `dm.properties` can read from any context — the same channel
    `forge probe` has always used.

    `filter_text` is applied here rather than in the game, so re-reading a
    finished run is free and does not require re-running it.
    """
    #[[
    #   Wait for the report, do not glance for it.
    #
    #   The server publishes during its own bootstrap, which in a game that
    #   carves terrain is twelve seconds after the play session starts. A
    #   single read lands in that window every time and comes back "no instance
    #   at ReplicatedStorage.ForgeTests" -- which reads as "the suite is
    #   broken" and is really "you asked too early".
    #
    #   Polling costs nothing on a game that is already up: the first read
    #   answers and the loop exits.
    #]]
    deadline = time.monotonic() + timeout
    raw = None
    while True:
        try:
            result = _call("dm.properties", {
                "path": "ReplicatedStorage.ForgeTests.Report",
                "properties": ["Value"],
            }, 30) or {}
            raw = (result.get("properties") or {}).get("Value")
        except BridgeError as exc:
            #: The holder does not exist yet. Anything else is a real failure
            #: and should not be swallowed by a retry loop.
            if "E_NOT_FOUND" not in str(exc):
                raise
            raw = None
        if raw:
            break
        if time.monotonic() >= deadline:
            return {"error": "the game published no test report within "
                             f"{timeout}s; is `selfTest` on in its Config, and "
                             "did the place finish starting?"}
        time.sleep(1.5)
    try:
        report = json.loads(raw)
    except json.JSONDecodeError as exc:
        return {"error": f"the published report is not JSON: {exc}"}

    if filter_text and isinstance(report.get("results"), list):
        needle = filter_text.lower()
        report["results"] = [r for r in report["results"]
                             if needle in r.get("name", "").lower()]
    return report


def _call(method: str, params: dict, timeout: int = 120):
    proc = subprocess.run(
        [sys.executable, str(REPO / "rqe.py"), "studio", "call", method,
         "--params", json.dumps(params), "--timeout", str(timeout)],
        capture_output=True, text=True, timeout=timeout + 30, cwd=str(REPO),
    )
    raw = proc.stdout.strip() or proc.stderr.strip()
    try:
        envelope = json.loads(raw)
    except json.JSONDecodeError as exc:
        raise BridgeError(f"bridge did not return JSON: {exc} / {raw[:300]}")
    if not envelope.get("ok"):
        raise BridgeError(json.dumps(envelope.get("error"))[:400])
    return envelope.get("result")


def render(report: dict) -> str:
    if report.get("error"):
        return f"gametest: {report['error']}"

    lines = []
    for result in report.get("results", []):
        status = result["status"]
        mark = {"passed": "OK  ", "failed": "FAIL", "error": "ERR ",
                "timeout": "HANG", "skipped": "SKIP"}.get(status, "?   ")
        lines.append(f"  {mark} {result['name']}  ({result['checks']} checks, {result['seconds']}s)")
        #: A skip's reason is the whole content of the result. Printing the
        #: line without it says a scenario did not run and not why, which is
        #: the least useful half.
        if result.get("reason"):
            lines.append(f"         {result['reason']}")
        for failure in result.get("failures") or []:
            lines.append(f"         {failure}")
        if result.get("error"):
            lines.append(f"         {result['error']}")

    lines.append("")
    skipped = report.get("skipped", 0)
    summary = (f"  {report.get('passed', 0)} passed, {report.get('failed', 0)} failed, "
               f"{report.get('timedOut', 0)} hung")
    if skipped:
        #: Never folded into the pass count. A suite reading "12 passed" when
        #: four never ran is the report telling a comfortable lie.
        summary += f", {skipped} skipped"
    lines.append(summary + f", in {report.get('seconds', 0)}s")
    if skipped:
        lines.append(f"  {skipped} scenario(s) could not run; a skip is not a pass")
    return "\n".join(lines)
