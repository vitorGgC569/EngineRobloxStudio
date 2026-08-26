"""Map every asset a salvaged game actually uses, and to which kind of game.

Why the referenced ids beat the harvested files
-----------------------------------------------

Two earlier passes built asset libraries the slow way: 257 pieces lifted out of
place files, and 162 icons resampled from source art and republished. Both are
real and both are second-best, because a shipped game already points at the
assets it uses -- a thousand of them -- and every one is uploaded, approved, and
proven in production.

`rbxassetid://8123...` in `EggService.lua` is a pet model somebody modelled,
moderated and shipped. Nothing needs harvesting, converting, resampling or
republishing; a game just refers to it.

How relevance is decided
------------------------

By where the id is written, which is the strongest signal available and costs
nothing to read. An id inside `PetFollowService.lua` is pet content; one in
`EggService.lua` is gacha content; one in `WeaponVisuals.luau` is combat. The
system inventory already knows which file implements which system, so the
mapping falls out of joining the two.

Game kinds are then declared as the systems they are built from -- a simulator
is gacha plus pets plus daily rewards -- so asking "what does a simulator have
available" is answered by the union of those systems' assets.

What this does not know
-----------------------

Whether the asset is any good, and whether it fits a particular art direction.
It narrows a thousand ids to the forty a person should look at, which is the
difference between browsing and choosing.
"""

from __future__ import annotations

import json
import re
from pathlib import Path
from typing import Any

KITS = Path("forge/kits")
ASSET_MAP = KITS / "asset-map.json"

#: Every numeric asset reference. `rbxasset://` paths are engine-shipped and
#: need no mapping -- they are available to every game already.
ASSET_ID = re.compile(r"rbxassetid://(\d+)")

#: The property that carries an id says what the id is, when it is written
#: inline. Roughly half are passed through variables and stay unknown, which is
#: honest: the type is confirmed against Open Cloud, not guessed here.
PROPERTY_KIND = {
    "SoundId": "audio", "MeshId": "mesh", "TextureId": "texture", "TextureID": "texture",
    "Image": "image", "Texture": "texture", "AnimationId": "animation", "Decal": "decal",
    "ColorMap": "texture", "NormalMap": "texture", "RoughnessMap": "texture",
    "MetalnessMap": "texture",
}
PROPERTY_NEAR = re.compile(
    r"(" + "|".join(PROPERTY_KIND) + r")\s*=\s*[\"']rbxassetid://(\d+)")

#: What a kind of game is made of. Declared as systems rather than as assets,
#: because the systems are what a designer picks and the assets follow.
GAME_KINDS: dict[str, tuple[str, ...]] = {
    "simulator":   ("gacha / hatch", "pet / companion", "daily reward", "timed reward",
                    "inventory", "monetization", "leaderboard", "trade"),
    "tycoon":      ("tycoon economy", "plot allocation", "rebirth / prestige", "daily reward",
                    "save / persistence", "monetization", "tutorial"),
    "shooter":     ("weapon / firing", "holding / equip", "character animation",
                    "party / group", "leaderboard", "world / map loading"),
    "rpg":         ("quest / mission", "inventory", "character animation", "weapon / firing",
                    "party / group", "save / persistence", "world / map loading"),
    "obby":        ("character animation", "leaderboard", "daily reward", "monetization",
                    "world / map loading"),
}


def _systems_by_file() -> dict[tuple[str, str], list[str]]:
    """Which systems each salvaged file implements, from the systems inventory."""
    inventory_path = KITS / "systems.json"
    if not inventory_path.exists():
        return {}
    try:
        inventory = json.loads(inventory_path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return {}

    out: dict[tuple[str, str], list[str]] = {}
    for system, hits in (inventory.get("systems") or {}).items():
        for hit in hits:
            out.setdefault((hit["kit"], hit["path"]), []).append(system)
    return out


def build() -> dict[str, Any]:
    """Scan the salvage for asset references and attribute each to its systems."""
    owners = _systems_by_file()
    assets: dict[str, dict[str, Any]] = {}

    for salvage in sorted(KITS.glob("*/salvage")):
        kit = salvage.parts[2]
        for path in sorted(salvage.rglob("*")):
            if path.suffix.lower() not in (".lua", ".luau", ".json"):
                continue
            try:
                text = path.read_text(encoding="utf-8", errors="replace")
            except OSError:
                continue

            relative = str(path.relative_to(salvage)).replace("\\", "/")
            systems = owners.get((kit, relative), [])

            inline_kind: dict[str, str] = {}
            for prop, asset_id in PROPERTY_NEAR.findall(text):
                inline_kind[asset_id] = PROPERTY_KIND[prop]

            for asset_id in set(ASSET_ID.findall(text)):
                entry = assets.setdefault(asset_id, {
                    "id": asset_id, "kits": [], "files": [], "systems": [], "kind": None,
                })
                if kit not in entry["kits"]:
                    entry["kits"].append(kit)
                if len(entry["files"]) < 4:
                    entry["files"].append(f"{kit}/{relative}")
                for system in systems:
                    if system not in entry["systems"]:
                        entry["systems"].append(system)
                entry["kind"] = entry["kind"] or inline_kind.get(asset_id)

    by_kind: dict[str, list[str]] = {}
    for kind, systems in GAME_KINDS.items():
        wanted = set(systems)
        by_kind[kind] = sorted(
            asset_id for asset_id, entry in assets.items()
            if wanted & set(entry["systems"]))

    unattributed = sorted(a for a, e in assets.items() if not e["systems"])

    mapping = {
        "$comment": (
            "Asset ids referenced by salvaged production code, attributed to the systems "
            "whose files reference them, and grouped by the kind of game those systems "
            "make. These are live approved uploads -- a game refers to them, nothing needs "
            "harvesting or republishing. It says which forty to look at, not which are good."),
        "assets": assets,
        "byGameKind": by_kind,
        "gameKinds": {k: list(v) for k, v in GAME_KINDS.items()},
        "total": len(assets),
        "attributed": len(assets) - len(unattributed),
        "unattributed": len(unattributed),
    }
    ASSET_MAP.write_text(json.dumps(mapping, indent=1, ensure_ascii=False) + "\n",
                         encoding="utf-8")
    return mapping
