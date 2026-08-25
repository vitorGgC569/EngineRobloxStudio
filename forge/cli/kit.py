"""Bring authored content out of a licensed project and into a kit.

What this is for
----------------

Everything mined so far has been *code* — the maths of an economy, the shape of
a combat pipeline, the rule a chain runs at its narrowest link. None of it is
what a player sees. A game assembled entirely from the library still looks like
six grey slabs, because grey slabs are what the code says to build when nobody
supplies a model.

The licensed projects are full of the other half: models, enemies, structures,
props, icon sets. A kit is that content, copied into this repository with its
provenance recorded, mounted by rojo, and reachable through `Forge.Catalog`.

    forge kit list projetos/HaloAndHorns     what is in there
    forge kit add projetos/HaloAndHorns --name halo

Why `.rbxm` and not FBX
-----------------------

The projects hold both. `.rbxm` files are Roblox instances — rojo mounts them
straight into a place and they work the moment the game starts. The `.fbx` and
`.png` exports are raw 3D source: using them means importing, uploading and
waiting for moderation on every mesh, which is a pipeline rather than a copy.

So this takes the `.rbxm` and leaves the rest, and says so, rather than
pretending a folder of FBX is usable content today.

Why local content matters beyond looks
--------------------------------------

`InsertService:LoadAsset` needs a published place. On an unpublished build it
does not error — it hangs, and this project lost an afternoon to a server that
booted and never finished because of exactly that. Content that ships inside
the place file cannot hang, cannot be moderated away overnight, and works in a
headless build. The kit is the answer to a reliability problem as much as to a
visual one.

Provenance
----------

Every kit records where each file came from and when. These are projects the
user holds a licence to; the manifest is what makes that checkable later rather
than a thing somebody remembers.
"""

from __future__ import annotations

import json
import re
import shutil
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

REPO = Path(__file__).resolve().parents[2]
KITS = REPO / "forge" / "kits"

#: Roblox instance containers. Everything else in a project is source art,
#: build tooling or documentation, and none of it can be mounted.
INSTANCE_SUFFIXES = (".rbxm", ".rbxmx")

#: What a folder name usually means, so a kit arrives sorted rather than as one
#: heap. Guessed from the path and always overridable — a wrong guess costs a
#: rename, and no guess costs a hundred.
CATEGORY_HINTS = {
    "guardian": "enemy",
    "enemy": "enemy",
    "mob": "enemy",
    "npc": "enemy",
    "breakable": "destructible",
    "landmark": "structure",
    "lair": "structure",
    "building": "structure",
    "prop": "prop",
    "drop": "pickup",
    "gem": "pickup",
    "gift": "pickup",
    "crate": "pickup",
    "ui": "interface",
    "icon": "interface",
}


class KitError(RuntimeError):
    pass


def categorise(path: Path) -> str:
    """Guess what a file is from the folders above it."""
    lowered = [part.lower() for part in path.parts]
    for part in reversed(lowered):
        for hint, category in CATEGORY_HINTS.items():
            if hint in part:
                return category
    return "prop"


def survey(source: Path) -> list[dict[str, Any]]:
    """Every mountable instance file in a project, with what we can tell about it.

    Read-only. Run it before `add` to see what a project would contribute —
    several of these are large, and a kit is a thing you commit.
    """
    if not source.exists():
        raise KitError(f"no project at {source}")

    found: list[dict[str, Any]] = []
    for path in sorted(source.rglob("*")):
        if path.suffix.lower() not in INSTANCE_SUFFIXES or ".git" in path.parts:
            continue
        found.append({
            "path": str(path.relative_to(source)).replace("\\", "/"),
            "name": path.stem,
            "bytes": path.stat().st_size,
            "category": categorise(path.relative_to(source)),
            # An XML file can be read and searched later; a binary one can only
            # be mounted. Worth recording, because it decides what tooling can
            # do with it afterwards.
            "format": "xml" if path.suffix.lower() == ".rbxmx" else "binary",
        })
    return found


def add(source: Path, name: str, limit_bytes: int = 12_000_000,
        categories: list[str] | None = None) -> dict[str, Any]:
    """Copy a project's instance files into `forge/kits/<name>`.

    Flattened into one folder per category rather than mirroring the source
    tree, because the source tree is however that project happened to organise
    itself and a kit is meant to be browsed by somebody who has never seen it.

    `limit_bytes` is a guard, not a preference. A 100MB place file copied into
    a git repository is a decision, and it should be made deliberately rather
    than by a wildcard.
    """
    pieces = survey(source)
    if categories:
        pieces = [p for p in pieces if p["category"] in categories]
    if not pieces:
        raise KitError(f"{source} holds no .rbxm or .rbxmx files")

    destination = KITS / name
    destination.mkdir(parents=True, exist_ok=True)

    copied, skipped = [], []
    for piece in pieces:
        if piece["bytes"] > limit_bytes:
            skipped.append({**piece, "reason": f"over {limit_bytes // 1_000_000}MB"})
            continue

        folder = destination / piece["category"]
        folder.mkdir(parents=True, exist_ok=True)
        # Names are used as Roblox instance names once mounted, so anything a
        # path allows and an instance does not has to go.
        safe = re.sub(r"[^A-Za-z0-9_-]", "_", piece["name"])[:60] or "piece"
        target = folder / f"{safe}{Path(piece['path']).suffix}"

        # Two files with the same stem in different source folders would
        # otherwise silently overwrite each other.
        counter = 2
        while target.exists():
            target = folder / f"{safe}_{counter}{Path(piece['path']).suffix}"
            counter += 1

        shutil.copy2(source / piece["path"], target)
        copied.append({
            **piece,
            "kitPath": str(target.relative_to(destination)).replace("\\", "/"),
        })

    manifest = {
        "kit": name,
        "source": str(source),
        "harvestedAt": datetime.now(timezone.utc).isoformat(),
        # The claim that makes this legitimate, written down where it can be
        # checked rather than remembered.
        "licence": "held by the repository owner; see the source project",
        "pieces": copied,
        "skipped": skipped,
        "byCategory": _counts(copied),
    }
    (destination / "kit.json").write_text(
        json.dumps(manifest, indent=2, ensure_ascii=False), encoding="utf-8")
    return manifest


def _counts(pieces: list[dict[str, Any]]) -> dict[str, int]:
    counts: dict[str, int] = {}
    for piece in pieces:
        counts[piece["category"]] = counts.get(piece["category"], 0) + 1
    return counts


def installed() -> list[dict[str, Any]]:
    """Every kit in the repository."""
    if not KITS.exists():
        return []
    out = []
    for folder in sorted(KITS.iterdir()):
        manifest = folder / "kit.json"
        if not manifest.is_file():
            continue
        try:
            data = json.loads(manifest.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError):
            continue
        out.append({
            "kit": data.get("kit", folder.name),
            "pieces": len(data.get("pieces") or []),
            "byCategory": data.get("byCategory") or {},
            "source": data.get("source"),
        })
    return out


def mount_snippet(name: str) -> str:
    """What to paste into a game's rojo project to get the kit into the place."""
    return json.dumps({
        "Kits": {
            "$className": "Folder",
            name: {"$path": f"../../forge/kits/{name}"},
        },
    }, indent=2)


def render(manifest: dict[str, Any]) -> str:
    lines = [f"  {manifest['kit']}  <-  {manifest['source']}"]
    for category, count in sorted(manifest["byCategory"].items()):
        lines.append(f"    {category:<14} {count}")
    if manifest.get("skipped"):
        lines.append("")
        for piece in manifest["skipped"][:6]:
            lines.append(f"    skipped {piece['name']} ({piece['reason']})")
    lines.append("")
    lines.append("  mount it by adding this to the game's default.project.json,")
    lines.append("  under ReplicatedStorage:")
    lines.append("")
    for line in mount_snippet(manifest["kit"]).splitlines():
        lines.append("    " + line)
    return "\n".join(lines)
