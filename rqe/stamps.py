"""Derived numbers that live in checked-in files, and the one place they are cut.

Why this exists
---------------

`quality/production-capabilities.v1.json` records the sha256 of
`schemas/bridge-commands.v1.json`, so a bridge command cannot appear without the
capability catalogue that governs it being reviewed. That is a good rule and it
worked exactly as designed: somebody added `client.tree` and `client.properties`,
the hash stopped matching, and the gate refused.

It refused for **twenty-five commits**, on `main` as well as on the branch. Six
tests failed the whole time and the entire capability and release path was dead,
because the correct behaviour of a fail-closed gate -- refusing -- is
indistinguishable from a gate nobody is running.

The defect was never the hash. It was that the hash was a **number a human types
into a file**, with no command to cut it and no place that said it existed. The
most recent commit message even enumerates the work: *"adding a bridge command
means four places, and finding that out took four failed round trips"*. It is
five, and the fifth is not mentioned anywhere in the repository.

So every derived stamp is registered here, `verify` reports drift with the
command that fixes it, and `refresh` is that command. CI runs `verify`; a person
adding a bridge command runs `refresh` and reviews the diff, which is what the
rule wanted in the first place.

    python rqe.py stamp            # what has drifted
    python rqe.py stamp --write    # re-cut them, then read the diff
"""

from __future__ import annotations

import hashlib
import json
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Iterable, Sequence


class StampError(RuntimeError):
    """A stamp could not be read or cut, and the message says which."""


@dataclass(frozen=True)
class Stamp:
    """One derived value: a field in a document, cut from another file.

    `pointer` is the path to the field inside `document`, as a sequence of keys.
    Kept explicit rather than as a dotted string so a key containing a dot is
    not a silent bug in the thing that exists to prevent silent bugs.
    """

    name: str
    document: str
    pointer: tuple[str, ...]
    source: str
    why: str

    def read(self, root: Path) -> str:
        payload = _load(root / self.document)
        node: Any = payload
        for key in self.pointer:
            if not isinstance(node, dict) or key not in node:
                raise StampError(
                    f"{self.name}: {self.document} has no field "
                    f"{'.'.join(self.pointer)}")
            node = node[key]
        if not isinstance(node, str):
            raise StampError(
                f"{self.name}: {'.'.join(self.pointer)} is not a string")
        return node

    def measure(self, root: Path) -> str:
        path = root / self.source
        if not path.is_file():
            raise StampError(f"{self.name}: {self.source} does not exist")
        digest = hashlib.sha256()
        with path.open("rb") as handle:
            for chunk in iter(lambda: handle.read(1 << 20), b""):
                digest.update(chunk)
        return digest.hexdigest()

    def write(self, root: Path, value: str) -> None:
        path = root / self.document
        payload = _load(path)
        node: Any = payload
        for key in self.pointer[:-1]:
            node = node[key]
        node[self.pointer[-1]] = value
        #: Two spaces and a trailing newline, matching every other checked-in
        #: JSON document here. A refresh that reformats the file buries its own
        #: one-line change in a thousand-line diff, and a diff nobody can read
        #: is a review nobody does.
        path.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")


def _load(path: Path) -> dict[str, Any]:
    if not path.is_file():
        raise StampError(f"{path} does not exist")
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except json.JSONDecodeError as exc:
        raise StampError(f"{path} is not valid JSON: {exc}") from exc


#: Every derived stamp in the repository.
#:
#: One entry today, which is the point: it was unwritten anywhere and cost
#: twenty-five commits of dead gate. The next one is an append rather than a
#: rediscovery.
STAMPS: tuple[Stamp, ...] = (
    Stamp(
        name="bridge-command-manifest",
        document="quality/production-capabilities.v1.json",
        pointer=("commandManifest", "sha256"),
        source="schemas/bridge-commands.v1.json",
        why="a bridge command must not appear without the capability "
            "catalogue that governs it being reviewed",
    ),
)


@dataclass
class Result:
    """What one stamp says right now."""

    stamp: Stamp
    recorded: str
    measured: str
    error: str = ""

    @property
    def ok(self) -> bool:
        return not self.error and self.recorded == self.measured

    def render(self) -> str:
        if self.error:
            return f"  ERROR  {self.stamp.name}: {self.error}"
        if self.ok:
            return f"  ok     {self.stamp.name}"
        return (f"  DRIFT  {self.stamp.name}\n"
                f"           {self.stamp.document} -> {'.'.join(self.stamp.pointer)}\n"
                f"           recorded {self.recorded}\n"
                f"           measured {self.measured}  ({self.stamp.source})\n"
                f"           why it matters: {self.stamp.why}")

    def to_dict(self) -> dict[str, Any]:
        return {
            "name": self.stamp.name,
            "document": self.stamp.document,
            "field": ".".join(self.stamp.pointer),
            "source": self.stamp.source,
            "recorded": self.recorded,
            "measured": self.measured,
            "ok": self.ok,
            "error": self.error,
        }


def verify(root: Path, stamps: Sequence[Stamp] = STAMPS) -> list[Result]:
    """Every stamp, with what it records and what its source actually is."""

    results: list[Result] = []
    for stamp in stamps:
        try:
            results.append(Result(stamp, stamp.read(root), stamp.measure(root)))
        except StampError as exc:
            results.append(Result(stamp, "", "", error=str(exc)))
    return results


def refresh(root: Path, stamps: Sequence[Stamp] = STAMPS) -> list[Result]:
    """Re-cut every drifted stamp. Returns what changed, before the change."""

    changed: list[Result] = []
    for result in verify(root, stamps):
        if result.error:
            raise StampError(result.error)
        if not result.ok:
            result.stamp.write(root, result.measured)
            changed.append(result)
    return changed


def drifted(results: Iterable[Result]) -> list[Result]:
    return [item for item in results if not item.ok]
