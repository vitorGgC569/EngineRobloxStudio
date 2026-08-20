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
import sys
from pathlib import Path
from typing import Any

REPO = Path(__file__).resolve().parents[2]


class BridgeError(RuntimeError):
    pass



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
    result = _call("dm.properties", {
        "path": "ReplicatedStorage.ForgeTests.Report",
        "properties": ["Value"],
    }, timeout) or {}
    raw = (result.get("properties") or {}).get("Value")
    if not raw:
        return {"error": "the game published no test report; is `selfTest` on "
                         "in its Config, and has the place finished starting?"}
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
        mark = {"passed": "OK  ", "failed": "FAIL", "error": "ERR ", "timeout": "HANG"}.get(status, "?   ")
        lines.append(f"  {mark} {result['name']}  ({result['checks']} checks, {result['seconds']}s)")
        for failure in result.get("failures") or []:
            lines.append(f"         {failure}")
        if result.get("error"):
            lines.append(f"         {result['error']}")

    lines.append("")
    lines.append(
        f"  {report.get('passed', 0)} passed, {report.get('failed', 0)} failed, "
        f"{report.get('timedOut', 0)} hung, in {report.get('seconds', 0)}s"
    )
    return "\n".join(lines)
