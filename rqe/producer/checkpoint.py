"""What a production run got through, so an interrupted one can carry on.

The gap
-------

`rqe/orchestrator/journal.py` is a crash-safe append-only journal on SQLite in
WAL mode, with per-task checkpoints and atomic state transitions. The producer
-- the thing that actually runs twelve stages and takes minutes -- had none of
it. A run interrupted at stage nine had nine stages of work on disk and no way
to say so: `skip_stages` existed, and it is a *manual* list somebody has to
retype from a report they still have open.

An interrupted run is not the unusual case. Studio hangs, a machine sleeps, an
agent is stopped, a network fetch times out. Redoing eleven minutes of work
because minute twelve failed is the cost that makes people stop using a tool.

What is recorded, and what deliberately is not
----------------------------------------------

**The verdicts, not the artifacts.** A checkpoint says `design` succeeded and
what it decided; the world it planned is already on disk where the stage put
it. Storing outputs here would make this a second copy that can disagree with
the first.

**Only `OK` and `NOT_APPLICABLE` are resumable.** A failed stage is retried,
because the reason to resume is usually that something was fixed. Resuming past
a failure would make the run report a success it never had.

**The brief is part of the identity.** Resuming a run whose brief has changed
would replay decisions made about a different game, so the checkpoint records a
hash of the inputs and refuses a resume that does not match. That refusal is
the whole value: silently resuming across a changed brief produces a game half
designed from each.
"""

from __future__ import annotations

import hashlib
import json
import secrets
from dataclasses import dataclass, field
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Iterable

#: One file per run, beside the artifacts the run produces.
CHECKPOINTS = Path("artifacts") / "producer"

#: Stage outcomes a later run may take on trust. `FAILED` and `SKIPPED` are
#: absent on purpose -- see the module docstring.
RESUMABLE = ("OK", "NOT_APPLICABLE")

#: The stages worth resuming, and the only ones it is safe to.
#:
#: The producer passes work between stages through an in-memory `context`:
#: `design` puts a model object in it, `art` a token set, `world` a spec. None
#: of that survives a process, so skipping one of those on a resume leaves
#: every later stage deciding against a context with holes in it -- worse than
#: starting over, and silently so.
#:
#: These four are the exception because their output is **files**, not objects,
#: and they are where the minutes are. Everything else re-runs in milliseconds
#: and rebuilds the context exactly as the first run had it.
RESUMABLE_STAGES = frozenset({"scaffold", "geometry", "implement", "build"})


def identity(brief: str, game_id: str, genre: str, theme: str,
             token_set: str, *, inputs: dict[str, Any] | None = None) -> str:
    """What makes two runs the same run.

    Everything the stages read out of the context before doing any work. A
    change to any of it means the decisions already recorded were made about a
    different game.
    """

    payload = json.dumps({
        "brief": brief.strip(), "gameId": game_id,
        "genre": genre, "theme": theme, "tokenSet": token_set,
        "inputs": inputs or {},
    }, sort_keys=True)
    return hashlib.sha256(payload.encode("utf-8")).hexdigest()


@dataclass
class Checkpoint:
    """What one run got through."""

    game_id: str
    identity: str
    stages: dict[str, dict[str, Any]] = field(default_factory=dict)
    updated_at: str = ""
    output_roots: list[str] = field(default_factory=list)
    output_hashes: dict[str, str] = field(default_factory=dict)
    context: dict[str, Any] = field(default_factory=dict)

    @staticmethod
    def output_inventory(root: Path, paths: Iterable[str]) -> dict[str, str]:
        base = root.resolve()
        found: dict[str, str] = {}
        for name in paths:
            target = (base / name).resolve()
            target.relative_to(base)
            files = sorted(target.rglob("*")) if target.is_dir() else [target]
            for file in files:
                if file.is_file():
                    file.resolve().relative_to(base)
                    found[file.relative_to(base).as_posix()] = hashlib.sha256(file.read_bytes()).hexdigest()
        return found

    def bind_outputs(self, root: Path, paths: Iterable[str], context: dict[str, Any] | None = None) -> None:
        self.output_roots = list(paths)
        self.output_hashes = self.output_inventory(root, self.output_roots)
        self.context = context or {}

    def path(self, root: Path) -> Path:
        return Path(root) / CHECKPOINTS / f"{self.game_id}.checkpoint.json"

    @property
    def resumable(self) -> list[str]:
        return sorted(name for name, entry in self.stages.items()
                      if entry.get("status") in RESUMABLE)

    def record(self, stage: str, status: str, detail: dict[str, Any] | None,
               seconds: float) -> None:
        self.stages[stage] = {
            "status": status,
            "detail": detail or {},
            "seconds": round(seconds, 3),
        }
        self.updated_at = datetime.now(timezone.utc).isoformat(timespec="seconds")

    def to_dict(self) -> dict[str, Any]:
        return {
            "gameId": self.game_id,
            "identity": self.identity,
            "updatedAt": self.updated_at,
            "stages": self.stages,
            "outputRoots": self.output_roots,
            "outputHashes": self.output_hashes,
            "context": self.context,
        }

    def save(self, root: Path) -> Path | None:
        """Written after every stage, so a crash loses one stage at most.

        Best-effort: a checkpoint that cannot be written must not fail a run
        that is otherwise going fine. The next resume simply starts earlier.
        """

        path = self.path(root)
        try:
            path.parent.mkdir(parents=True, exist_ok=True)
            #: Written beside and moved into place, because a run killed
            #: mid-write would otherwise leave a truncated checkpoint -- and a
            #: half-written record of what succeeded is worse than none.
            temporary = path.with_suffix(f".{secrets.token_hex(6)}.part")
            temporary.write_text(json.dumps(self.to_dict(), indent=2),
                                 encoding="utf-8")
            temporary.replace(path)
        except OSError:
            return None
        return path

    @classmethod
    def load(cls, root: Path, game_id: str) -> "Checkpoint | None":
        path = Path(root) / CHECKPOINTS / f"{game_id}.checkpoint.json"
        if not path.is_file():
            return None
        try:
            payload = json.loads(path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError):
            return None
        return cls(
            game_id=str(payload.get("gameId", game_id)),
            identity=str(payload.get("identity", "")),
            stages=dict(payload.get("stages") or {}),
            updated_at=str(payload.get("updatedAt", "")),
            output_roots=list(payload.get("outputRoots") or []),
            output_hashes=dict(payload.get("outputHashes") or {}),
            context=dict(payload.get("context") or {}),
        )

    @classmethod
    def clear(cls, root: Path, game_id: str) -> bool:
        path = Path(root) / CHECKPOINTS / f"{game_id}.checkpoint.json"
        try:
            path.unlink()
        except OSError:
            return False
        return True


def resumable_stages(root: Path, game_id: str, want: str) -> tuple[
        Checkpoint | None, list[str], str]:
    """What may be taken on trust, and why not when the answer is nothing.

    Returns the checkpoint, the stages it licenses skipping, and a sentence for
    a caller to print when it licenses none. The sentence matters: "resuming
    from scratch" and "refusing to resume because the brief changed" look
    identical from outside and mean opposite things.
    """

    found = Checkpoint.load(root, game_id)
    if found is None:
        return None, [], "no checkpoint for this game; starting from the beginning"
    if found.identity != want:
        return found, [], (
            "the brief, genre, theme or token set has changed since that "
            "checkpoint; starting from the beginning rather than replaying "
            "decisions made about a different game")
    if not found.resumable:
        return found, [], "the checkpoint records no stage that finished; starting over"
    if not found.output_roots or not found.output_hashes:
        return found, [], "checkpoint has no hash-bound output inventory; starting over"
    try:
        current = found.output_inventory(root, found.output_roots)
    except (ValueError, OSError):
        return found, [], "checkpoint outputs are unavailable or outside the project; starting over"
    if current != found.output_hashes:
        return found, [], "checkpoint outputs changed, disappeared or gained unverified files; starting over"
    return found, found.resumable, ""


def unresumable(stages: Iterable[str]) -> list[str]:
    """Which of these would leave the context with holes if skipped."""

    return sorted(name for name in stages if name not in RESUMABLE_STAGES)
