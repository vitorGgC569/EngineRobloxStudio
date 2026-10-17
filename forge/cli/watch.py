"""Rebuild and reload a game whenever its source changes.

The gap this closes
-------------------

Every real check on this platform cost four commands and about three and a half
minutes: build, restart Studio, play solo, read the report. Eleven of those in
one session is forty minutes of waiting, and getting the order wrong was the
single largest source of mistakes -- testing a build that was never made,
reading a report from the run before.

Studio on its own has "save the file, see the change". The platform sits
outside it and paid a full restart to see anything. That is not an
inconvenience; it decides how many ideas can be tried in an hour, and therefore
how good the result is.

What this does and does not do
------------------------------

It watches source, rebuilds the on-disk place, and uses Rojo's sourcemap to
decide whether the already-open Studio DataModel can be updated safely.

Existing Lua/Luau scripts that map to a concrete Script, LocalScript or
ModuleScript are synchronized through the bridge's native `code.write` /
`code.reload` path. The whole changed batch is compiled before the first
mutation, and an active Play Solo is stopped and restarted through
StudioTestService -- never by foreground focus or F5.

Structural changes stay fail-closed. Deleted files, project manifests, TOML/JSON
changes or anything Rojo cannot map to a script return `coldReloadRequired`.
The watcher does not restart Studio unless the caller explicitly opted into
`--allow-cold-reload`. A session that merely *looks* updated is worse than a
named cold-reload requirement.
"""

from __future__ import annotations

import time
from pathlib import Path
from typing import Any, Callable

#: Anything that can change what the built place contains.
WATCHED_SUFFIXES = (".lua", ".luau", ".json", ".toml")

#: Directories whose churn is not source. `.rbxlx` output lives in the project
#: root, and rebuilding because the last rebuild wrote a file is a loop.
SKIP_DIRS = {".git", "node_modules", "__pycache__", ".tmp", "out", "dist"}


def _snapshot(roots: list[Path]) -> dict[str, float]:
    """Modification times for everything worth rebuilding over."""
    stamps: dict[str, float] = {}
    for root in roots:
        if not root.exists():
            continue
        for path in root.rglob("*"):
            if path.suffix.lower() not in WATCHED_SUFFIXES:
                continue
            if any(part in SKIP_DIRS for part in path.parts):
                continue
            try:
                stamps[str(path)] = path.stat().st_mtime
            except OSError:
                continue
    return stamps


def _changes(before: dict[str, float], after: dict[str, float]) -> list[str]:
    changed = [p for p, t in after.items() if before.get(p) != t]
    changed += [p for p in before if p not in after]
    return sorted(changed)


def run(project: Path, engine: Path, rebuild: Callable[[], bool],
        reload_studio: Callable[[list[str]], dict[str, Any]],
        settle: float = 0.6, poll: float = 1.0,
        progress: Any = print) -> None:
    """Watch, rebuild, reload. Runs until interrupted.

    `settle` is the pause after the first change before acting. An editor
    writing four files takes a moment to write all four, and rebuilding on the
    first of them produces a place missing the other three -- which then looks
    like a bug in the code rather than in the watcher.
    """
    roots = [project, engine]
    progress(f"watching {project.name} and the engine. Ctrl+C to stop.")
    stamps = _snapshot(roots)

    while True:
        time.sleep(poll)
        current = _snapshot(roots)
        changed = _changes(stamps, current)
        if not changed:
            continue

        #: Let the rest of the save land before reading anything.
        time.sleep(settle)
        current = _snapshot(roots)
        changed = _changes(stamps, current)
        stamps = current

        head = ", ".join(Path(p).name for p in changed[:3])
        if len(changed) > 3:
            head += f" and {len(changed) - 3} more"
        progress(f"\n{time.strftime('%H:%M:%S')}  {head}")

        started = time.time()
        if not rebuild():
            #: A build that fails leaves the previous place in Studio. Say so:
            #: the alternative is testing yesterday's build believing it is
            #: today's, which is the exact failure this tool exists to remove.
            progress("  build failed -- Studio still has the previous place")
            continue

        outcome = reload_studio(changed)

        if outcome.get("hotReloaded"):
            count = int(outcome.get("hotReloaded") or 0)
            restarted = outcome.get("playRestarted") is True
            progress(
                f"  hot-reloaded {count} script{'' if count == 1 else 's'} "
                f"in {time.time() - started:.0f}s"
                + ("; Play Solo restarted natively" if restarted else "")
            )
            continue

        if outcome.get("coldReloadRequired"):
            paths = outcome.get("coldChanges") or []
            head = ", ".join(Path(p).name for p in paths[:3])
            if len(paths) > 3:
                head += f" and {len(paths) - 3} more"
            progress(
                "  build is ready, but this change needs a cold Studio reload"
                + (f": {head}" if head else "")
            )
            continue

        if outcome.get("skipped"):
            progress(
                f"  built in {time.time() - started:.0f}s; Studio not reloaded "
                f"({outcome.get('reason') or 'cold reload disabled'})"
            )
            continue

        sessions = len((outcome.get("handshake") or {}).get("sessions") or [])
        progress(f"  reloaded in {time.time() - started:.0f}s "
                 f"({sessions} session{'' if sessions == 1 else 's'} connected)")
