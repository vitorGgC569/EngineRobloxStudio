"""What a run cost: round trips, seconds, restarts, and what it produced.

Why this is the missing metric
------------------------------

This repository measures the *product* exhaustively -- probes, gates,
provenance, visual scores, a fail-closed release path. It measures the
*production* not at all. Nothing anywhere answers:

    how many round trips to Studio did that game take
    how long did it take
    how many of those trips failed, and on what
    how much of the wall clock was waiting on Studio rather than working

For a platform whose declared customer is an agent, that is the product metric.
An agent that needs four hundred bridge calls to build a tycoon and one that
needs forty are different products, and today they are indistinguishable --
including from each other across two versions of this repository, which is the
version that matters when deciding whether a change helped.

Three properties, each chosen against a way ledgers rot
-------------------------------------------------------

**It is automatic.** The counters live at the seam every bridge command already
passes through, and the run is opened by the CLI entry point. A ledger somebody
has to remember to write is a ledger with gaps exactly where the interesting
runs are.

**It cannot break what it measures.** Every hook is wrapped: a ledger that
raises while recording a successful build has turned a measurement into an
outage. Failures to record are counted and dropped, never propagated.

**It is append-only JSONL.** One line per run, written once at the end, so a
crashed run leaves the lines before it intact and a reader is a `for` loop. The
knowledge base next door chose the same shape and has one entry in it; the
difference here is that nothing has to decide to write.

What a line looks like
----------------------

    {"runId": "...", "command": "forge playtest", "game": "carvewood",
     "wallSeconds": 84.2, "bridge": {"calls": 61, "seconds": 39.4, "failed": 2,
     "byMethod": {"dm.properties": 22, ...}}, "studioRestarts": 1,
     "builds": 1, "exitCode": 0, "kind": "ok"}
"""

from __future__ import annotations

import json
import os
import platform
import time
import uuid
from collections import Counter
from contextlib import contextmanager
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Iterator

#: One line per run, beside the knowledge base.
LEDGER_PATH = Path(".rqe") / "ledger.jsonl"

#: How many distinct bridge methods a line records individually. A run that
#: calls two hundred distinct methods is not made clearer by listing them all,
#: and the total is kept regardless.
TOP_METHODS = 12


@dataclass
class Run:
    """One command, from the moment it started to what it cost."""

    command: str
    game: str = ""
    run_id: str = field(default_factory=lambda: uuid.uuid4().hex[:12])
    started_at: float = field(default_factory=time.time)
    started_clock: float = field(default_factory=time.perf_counter)

    #: Round trips to Studio: the number that answers "how expensive is this
    #: agent". Counted at the one seam they all pass through.
    bridge_calls: Counter = field(default_factory=Counter)
    bridge_failures: Counter = field(default_factory=Counter)
    bridge_seconds: float = 0.0

    #: The expensive discrete events. A Studio restart is tens of seconds and a
    #: build is seconds; counting them separately is what lets a reader tell a
    #: slow run from a chatty one.
    studio_restarts: int = 0
    builds: int = 0

    artifacts: list[str] = field(default_factory=list)
    notes: dict[str, Any] = field(default_factory=dict)

    exit_code: int | None = None
    #: Recording is best-effort; when it fails the run still succeeds and the
    #: line says how many observations were lost rather than pretending to be
    #: complete.
    dropped: int = 0

    @property
    def wall_seconds(self) -> float:
        return max(0.0, time.perf_counter() - self.started_clock)

    @property
    def total_calls(self) -> int:
        return sum(self.bridge_calls.values())

    @property
    def waiting_fraction(self) -> float:
        """How much of the run was spent waiting on Studio.

        The number that separates "this agent is inefficient" from "Studio is
        slow", which are different problems with different fixes.
        """

        wall = self.wall_seconds
        return round(self.bridge_seconds / wall, 3) if wall > 0 else 0.0

    def to_dict(self) -> dict[str, Any]:
        from .exits import name as exit_name

        return {
            "runId": self.run_id,
            "startedAt": self.started_at,
            "command": self.command,
            "game": self.game,
            "wallSeconds": round(self.wall_seconds, 2),
            "bridge": {
                "calls": self.total_calls,
                "seconds": round(self.bridge_seconds, 2),
                "failed": sum(self.bridge_failures.values()),
                "waitingFraction": self.waiting_fraction,
                "byMethod": dict(self.bridge_calls.most_common(TOP_METHODS)),
                "failuresByMethod": dict(self.bridge_failures.most_common(TOP_METHODS)),
            },
            "studioRestarts": self.studio_restarts,
            "builds": self.builds,
            "artifacts": list(self.artifacts),
            "exitCode": self.exit_code,
            "kind": exit_name(self.exit_code) if self.exit_code is not None else "",
            "dropped": self.dropped,
            "host": platform.node(),
            "pid": os.getpid(),
            "notes": dict(self.notes),
        }


#: The run this process is inside, if any.
#:
#: Module-level rather than passed down: the instrumentation sits inside
#: `StudioBridge`, six frames below the CLI that opened the run, and threading
#: a ledger handle through six signatures to count one integer is how
#: instrumentation gets removed the first time somebody refactors.
_CURRENT: Run | None = None


def current() -> Run | None:
    return _CURRENT


def _safe(function):
    """Recording must never be the reason a run fails."""

    import functools

    @functools.wraps(function)
    def guarded(*args: Any, **kwargs: Any) -> None:
        run = _CURRENT
        if run is None:
            return
        try:
            function(run, *args, **kwargs)
        except Exception:  # noqa: BLE001 - counted, never raised
            run.dropped += 1

    return guarded


@_safe
def record_bridge_call(run: Run, method: str, seconds: float, ok: bool = True) -> None:
    """One round trip to Studio, timed."""

    run.bridge_calls[method] += 1
    run.bridge_seconds += max(0.0, float(seconds))
    if not ok:
        run.bridge_failures[method] += 1


@_safe
def record_studio_restart(run: Run) -> None:
    run.studio_restarts += 1


@_safe
def record_build(run: Run) -> None:
    run.builds += 1


@_safe
def record_artifact(run: Run, path: str) -> None:
    if path not in run.artifacts:
        run.artifacts.append(str(path))


@_safe
def note(run: Run, key: str, value: Any) -> None:
    run.notes[key] = value


def append(run: Run, root: Path | str = ".") -> Path | None:
    """Write one line. Returns where, or `None` if it could not be written."""

    path = Path(root) / LEDGER_PATH
    try:
        path.parent.mkdir(parents=True, exist_ok=True)
        with path.open("a", encoding="utf-8") as handle:
            handle.write(json.dumps(run.to_dict()) + "\n")
    except OSError:
        #: A read-only checkout or a full disk must not fail the command that
        #: just succeeded. The observation is lost and that is the correct
        #: trade; the alternative is a tool that breaks when its diary does.
        return None
    return path


@contextmanager
def run(command: str, *, game: str = "", root: Path | str = ".") -> Iterator[Run]:
    """Open a run, record everything inside it, write one line on the way out.

    Re-entrant by design: a command that calls another command's function does
    not open a second run, because the cost belongs to the outer one. The inner
    call gets the same object and its counters land in the same line.
    """

    global _CURRENT

    if _CURRENT is not None:
        yield _CURRENT
        return

    active = Run(command=command, game=game)
    _CURRENT = active
    try:
        yield active
    finally:
        _CURRENT = None
        append(active, root)


# --------------------------------------------------------------------------
# Reading it back.


def read(root: Path | str = ".", *, game: str = "", command: str = "",
         limit: int = 0) -> list[dict[str, Any]]:
    """Every recorded run, newest last, optionally filtered."""

    path = Path(root) / LEDGER_PATH
    if not path.is_file():
        return []
    rows: list[dict[str, Any]] = []
    for line in path.read_text(encoding="utf-8", errors="ignore").splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            row = json.loads(line)
        except json.JSONDecodeError:
            #: One torn line, from a process killed mid-write, must not hide
            #: every line after it.
            continue
        if game and row.get("game") != game:
            continue
        if command and not str(row.get("command", "")).startswith(command):
            continue
        rows.append(row)
    return rows[-limit:] if limit else rows


@dataclass
class Summary:
    """What a set of runs cost, together."""

    runs: int = 0
    wall_seconds: float = 0.0
    bridge_calls: int = 0
    bridge_seconds: float = 0.0
    bridge_failures: int = 0
    studio_restarts: int = 0
    builds: int = 0
    by_kind: Counter = field(default_factory=Counter)
    by_method: Counter = field(default_factory=Counter)

    @property
    def calls_per_run(self) -> float:
        return round(self.bridge_calls / self.runs, 1) if self.runs else 0.0

    @property
    def seconds_per_run(self) -> float:
        return round(self.wall_seconds / self.runs, 1) if self.runs else 0.0

    @property
    def failure_rate(self) -> float:
        return (round(self.bridge_failures / self.bridge_calls, 4)
                if self.bridge_calls else 0.0)

    @property
    def waiting_fraction(self) -> float:
        return (round(self.bridge_seconds / self.wall_seconds, 3)
                if self.wall_seconds > 0 else 0.0)

    def to_dict(self) -> dict[str, Any]:
        return {
            "runs": self.runs,
            "wallSeconds": round(self.wall_seconds, 1),
            "secondsPerRun": self.seconds_per_run,
            "bridgeCalls": self.bridge_calls,
            "callsPerRun": self.calls_per_run,
            "bridgeSeconds": round(self.bridge_seconds, 1),
            "waitingFraction": self.waiting_fraction,
            "bridgeFailures": self.bridge_failures,
            "failureRate": self.failure_rate,
            "studioRestarts": self.studio_restarts,
            "builds": self.builds,
            "byKind": dict(self.by_kind.most_common()),
            "byMethod": dict(self.by_method.most_common(TOP_METHODS)),
        }


def summarise(rows: list[dict[str, Any]]) -> Summary:
    total = Summary()
    for row in rows:
        bridge = row.get("bridge") or {}
        total.runs += 1
        total.wall_seconds += float(row.get("wallSeconds") or 0)
        total.bridge_calls += int(bridge.get("calls") or 0)
        total.bridge_seconds += float(bridge.get("seconds") or 0)
        total.bridge_failures += int(bridge.get("failed") or 0)
        total.studio_restarts += int(row.get("studioRestarts") or 0)
        total.builds += int(row.get("builds") or 0)
        total.by_kind[str(row.get("kind") or "?")] += 1
        for method, count in (bridge.get("byMethod") or {}).items():
            total.by_method[method] += int(count)
    return total


def render(rows: list[dict[str, Any]], *, game: str = "") -> str:
    """The ledger as a person reads it."""

    if not rows:
        return ("forge cost: nothing recorded yet.\n\n"
                "  Every `forge` command writes one line when it finishes. Run\n"
                "  one -- `forge gametest <game>` is the cheapest -- and ask again.")

    total = summarise(rows)
    head = f"forge cost{f': {game}' if game else ''}"
    out = [head, ""]
    out.append(f"  {total.runs} run(s), {total.wall_seconds:.0f}s of wall clock")
    out.append(f"  {total.bridge_calls} round trips to Studio "
               f"({total.calls_per_run} per run), {total.bridge_seconds:.0f}s in them")
    if total.wall_seconds > 0:
        out.append(f"  {total.waiting_fraction:.0%} of the wall clock was waiting on Studio")
    if total.bridge_calls:
        out.append(f"  {total.bridge_failures} failed round trip(s) "
                   f"({total.failure_rate:.1%})")
    out.append(f"  {total.studio_restarts} Studio restart(s), {total.builds} build(s)")
    out.append("")

    out.append("  how each run ended")
    for kind, count in total.by_kind.most_common():
        out.append(f"    {count:4d}  {kind}")
    out.append("")

    out.append("  where the round trips went")
    for method, count in total.by_method.most_common(8):
        share = count / total.bridge_calls if total.bridge_calls else 0
        out.append(f"    {count:5d}  {share:5.1%}  {method}")
    out.append("")

    out.append("  most recent")
    for row in rows[-6:]:
        bridge = row.get("bridge") or {}
        out.append(f"    {row.get('command',''):<22} {row.get('game',''):<14} "
                   f"{float(row.get('wallSeconds') or 0):7.1f}s "
                   f"{int(bridge.get('calls') or 0):5d} calls  "
                   f"{row.get('kind','')}")
    return "\n".join(out)
