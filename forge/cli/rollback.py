"""Undo a publish, by re-publishing the last thing that was known good.

Why this is not `list_versions`
-------------------------------

`rqe/cloud/open_cloud.py` grew `list_versions` and documented it as *"the other
half of a rollback: publishing without being able to see what came before is a
one-way door"*. It was the honest half. The first half did not exist: a bad
publish could be seen and not undone.

And it could not be written the obvious way, because **Roblox Open Cloud has no
restore endpoint.** `POST .../versions` uploads a place file and that is the
entire surface. Listing versions tells you a v11 exists; nothing lets you ask
for it back.

So the rollback is built out of what does exist
-----------------------------------------------

Every publish keeps a copy of exactly the bytes it sent, under
`artifacts/published/<game>/`, named by version and content hash. Rolling back
re-publishes one of those, which produces a *new* version whose content is the
old one -- the only shape of rollback the platform permits, and the shape a
player experiences as identical.

Three consequences worth stating rather than discovering:

  * **A rollback is a publish.** It takes the publish lease, it is recorded in
    the ledger, and it appears in Roblox's version history as a new version.
    Nothing pretends the history was rewritten.

  * **It can only reach versions this repository published.** A version
    uploaded from Studio by hand is in Roblox's list and not in ours, and
    `--list` marks which are which rather than letting somebody select one that
    cannot be restored.

  * **The bytes are verified before they are sent.** The kept file is hashed
    against what the receipt recorded, so a truncated or edited artifact is a
    refusal rather than a silent publish of something nobody reviewed.
"""

from __future__ import annotations

import hashlib
import json
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

REPO = Path(__file__).resolve().parents[2]

#: Where the published bytes are kept. Under `artifacts/` because that is what
#: the directory is for, and per game because a rollback is always per game.
KEEP = Path("artifacts") / "published"


def _directory(game: str, root: Path = REPO) -> Path:
    return root / KEEP / game


def _receipts_path(game: str, root: Path = REPO) -> Path:
    return _directory(game, root) / "receipts.jsonl"


@dataclass
class Receipt:
    """One publish: what went up, when, and where the bytes are kept."""

    game: str
    universe_id: str
    place_id: str
    version_type: str
    version_number: Any
    sha256: str
    bytes: int
    kept: str
    published_at: str
    rolled_back_from: Any = None

    def to_dict(self) -> dict[str, Any]:
        return {
            "game": self.game,
            "universeId": self.universe_id,
            "placeId": self.place_id,
            "versionType": self.version_type,
            "versionNumber": self.version_number,
            "sha256": self.sha256,
            "bytes": self.bytes,
            "kept": self.kept,
            "publishedAt": self.published_at,
            "rolledBackFrom": self.rolled_back_from,
        }

    @classmethod
    def from_dict(cls, payload: dict[str, Any]) -> "Receipt":
        return cls(
            game=str(payload.get("game", "")),
            universe_id=str(payload.get("universeId", "")),
            place_id=str(payload.get("placeId", "")),
            version_type=str(payload.get("versionType", "")),
            version_number=payload.get("versionNumber"),
            sha256=str(payload.get("sha256", "")),
            bytes=int(payload.get("bytes") or 0),
            kept=str(payload.get("kept", "")),
            published_at=str(payload.get("publishedAt", "")),
            rolled_back_from=payload.get("rolledBackFrom"),
        )

    def kept_path(self, root: Path = REPO) -> Path:
        return _directory(self.game, root) / self.kept


def sha256_of(payload: bytes) -> str:
    return hashlib.sha256(payload).hexdigest()


def keep(game: str, place_file: Path, result: dict[str, Any], *,
         universe_id: str, place_id: str, root: Path = REPO,
         rolled_back_from: Any = None, payload: bytes | None = None) -> Receipt:
    """Record a publish and keep the exact bytes that went up.

    Called by `publish` on success. The copy is what makes a rollback possible
    at all, and it is taken from the file that was *sent* rather than rebuilt
    from source: a rebuild can differ, and a rollback to something nobody
    published is not a rollback.
    """

    payload = place_file.read_bytes() if payload is None else payload
    digest = sha256_of(payload)
    version = result.get("versionNumber")
    name = f"v{version}-{digest[:12]}.rbxlx" if version else f"{digest[:12]}.rbxlx"

    directory = _directory(game, root)
    directory.mkdir(parents=True, exist_ok=True)
    destination = directory / name
    if not destination.exists():
        destination.write_bytes(payload)
    elif destination.read_bytes() != payload:
        raise OSError("retained publication artifact has conflicting bytes")

    receipt = Receipt(
        game=game, universe_id=str(universe_id), place_id=str(place_id),
        version_type=str(result.get("versionType", "")),
        version_number=version, sha256=digest, bytes=len(payload), kept=name,
        published_at=datetime.now(timezone.utc).isoformat(timespec="seconds"),
        rolled_back_from=rolled_back_from,
    )
    with _receipts_path(game, root).open("a", encoding="utf-8") as handle:
        handle.write(json.dumps(receipt.to_dict()) + "\n")
    return receipt


def history(game: str, root: Path = REPO) -> list[Receipt]:
    """Every publish this repository made for a game, oldest first."""

    path = _receipts_path(game, root)
    if not path.is_file():
        return []
    out: list[Receipt] = []
    for line in path.read_text(encoding="utf-8", errors="ignore").splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            out.append(Receipt.from_dict(json.loads(line)))
        except (json.JSONDecodeError, TypeError, ValueError):
            continue
    return out


def restorable(game: str, root: Path = REPO) -> list[Receipt]:
    """Publishes whose bytes are still on disk and still intact."""

    good: list[Receipt] = []
    for receipt in history(game, root):
        path = receipt.kept_path(root)
        if not path.is_file():
            continue
        if sha256_of(path.read_bytes()) != receipt.sha256:
            continue
        good.append(receipt)
    return good


def target(game: str, version: Any = None, root: Path = REPO) -> Receipt:
    """Which version to go back to.

    With no version named, the one before the most recent -- which is what
    "roll back" means when somebody has just published something bad and wants
    it to stop.
    """

    from rqe.exits import USAGE, Problem

    available = restorable(game, root)
    if not available:
        raise Problem(
            USAGE, f"no restorable publish is recorded for '{game}'",
            detail=("A rollback re-publishes bytes this repository kept when it "
                    "published them. Nothing was kept for this game -- either it "
                    "was never published from here, or it was published before "
                    "publishes were recorded."),
            remedy_override="build and publish once, then rollback becomes available",
        )

    if version is not None:
        wanted = str(version)
        for receipt in reversed(available):
            if str(receipt.version_number) == wanted:
                return receipt
        raise Problem(
            USAGE, f"version {wanted} is not restorable for '{game}'",
            detail="restorable: " + ", ".join(
                str(item.version_number) for item in available) or "(none)",
            remedy_override="`forge publish <game> --list` shows what can be restored",
        )

    if len(available) < 2:
        raise Problem(
            USAGE, f"only one publish is recorded for '{game}'",
            detail="There is nothing earlier to go back to.",
            remedy_override="name a version explicitly if you meant to re-publish it",
        )
    return available[-2]


def render(game: str, root: Path = REPO) -> str:
    """What can be rolled back to, and what cannot."""

    rows = history(game, root)
    if not rows:
        return (f"forge publish --list: nothing recorded for '{game}'.\n\n"
                "  Publishes are recorded from now on; earlier ones were not\n"
                "  kept, so they cannot be restored from here.")

    good = {id(item) for item in restorable(game, root)}
    out = [f"publishes of {game}", ""]
    for receipt in reversed(rows):
        mark = "restorable" if any(
            r.sha256 == receipt.sha256 and r.version_number == receipt.version_number
            for r in restorable(game, root)) else "bytes gone"
        version = f"v{receipt.version_number}" if receipt.version_number else "?"
        note = ""
        if receipt.rolled_back_from is not None:
            note = f"  (rollback of v{receipt.rolled_back_from})"
        out.append(f"  {version:<8} {receipt.version_type:<10} "
                   f"{receipt.published_at}  {receipt.bytes / 1024:7.0f} KB  "
                   f"{mark}{note}")
    out.append("")
    out.append("  Roblox has no restore endpoint: a rollback re-publishes kept")
    out.append("  bytes as a NEW version whose content is the old one.")
    return "\n".join(out)
