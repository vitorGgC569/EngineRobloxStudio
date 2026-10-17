"""Run the engine's own examples, in a real Studio, and report.

Why executable
--------------

A documented example is a claim about an API that nobody checks. It is written
once, the API moves, and the next reader copies a call that no longer exists.
This project has produced that failure repeatedly today in comment form, and a
comment nobody can run is exactly as trustworthy as a memory of a sound asset
id.

So each module's example is a function that runs. `forge example --all`
executes every one inside Studio and prints what each returned. When the
surface drifts, an example fails here rather than in an agent's hands.

    forge example              run every module's example
    forge example Combat       run one

Edit mode is enough: examples build rigs, solve maths and compute paths, none
of which needs a play session. That makes this the fastest check in the
project — seconds, with no build and no terrain.
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


def _exec(source: str, timeout: int = 240) -> Any:
    proc = subprocess.run(
        [sys.executable, str(REPO / "rqe.py"), "studio", "call", "bridge.exec",
         "--allow-arbitrary", "--params", json.dumps({"source": source}), "--timeout", str(timeout)],
        capture_output=True, text=True, timeout=timeout + 30, cwd=str(REPO),
    )
    raw = proc.stdout.strip() or proc.stderr.strip()
    try:
        envelope = json.loads(raw)
    except json.JSONDecodeError as exc:
        raise BridgeError(f"bridge did not return JSON: {exc} / {raw[:300]}")
    if not envelope.get("ok"):
        raise BridgeError(json.dumps(envelope.get("error"))[:300])
    return envelope.get("result", {}).get("returned")


_LUAU = """
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local folder = ReplicatedStorage:FindFirstChild("Forge")
if not folder then
	return { error = "no Forge in ReplicatedStorage; open a built place" }
end
local Examples = require(folder).Examples
%(call)s
"""


def run(module: str | None = None) -> dict:
    call = (f'return Examples.run({json.dumps(module)})' if module
            else "return Examples.runAll()")
    return _exec(_LUAU % {"call": call}) or {}


def render(report: dict) -> str:
    if report.get("error"):
        return f"example: {report['error']}"

    # A single module returns one record; --all returns a summary.
    records = report.get("results") or [report]
    lines = []
    for record in records:
        mark = "OK  " if record.get("ok") else "FAIL"
        lines.append(f"  {mark} {record.get('module', '?'):<14} {record.get('seconds', 0)}s")
        if record.get("ok"):
            result = record.get("result")
            if isinstance(result, dict):
                for key, value in sorted(result.items()):
                    lines.append(f"         {key} = {value}")
        else:
            lines.append(f"         {record.get('error')}")

    if "passed" in report:
        lines.append("")
        lines.append(f"  {report['passed']} ran, {report['failed']} failed")
    return "\n".join(lines)
