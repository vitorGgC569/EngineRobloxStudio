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

#: What names an asset, in three widening circles.
#:
#: A first pass looked only for Roblox property names (`SoundId`, `MeshId`) and
#: typed 7 ids out of 1058, because production code almost never assigns to
#: those directly -- it builds config tables and hands them to something else
#: later. The vocabulary that actually appears is `texture_asset` (452 times),
#: `mesh_asset` (448), `image_id` (198), and a long tail of `icon`, `walk`,
#: `normal_map`.
#:
#: So: match the assignment key first, and where that key is generic (`id`,
#: `asset_id`, `asset`) fall back to the key of the table enclosing it. That
#: second circle is what types
#:
#:     egg_hatch_pop = { id = "rbxassetid://114572398311789" }
#:
#: as audio -- the name of the thing being defined says what it is even when
#: the field does not.
KEY_KIND: tuple[tuple[str, str], ...] = (
    (r"anim|(^|_)(walk|run|idle|attack|jump|climb|swim|fall|dance|emote|pose)($|_)",
     "animation"),
    (r"sound|audio|music|sfx|track|(^|_)(pop|snare|click|chime|whoosh|thud|sting)($|_)",
     "audio"),
    (r"mesh", "mesh"),
    (r"texture|_map$|colou?r_?map|normal_?map|roughness|metalness|specular|albedo",
     "texture"),
    (r"decal", "decal"),
    (r"image|icon|thumb|logo|badge|banner|portrait|avatar", "image"),
    (r"model|prefab|rig", "model"),
)
KEY_PATTERNS = tuple((re.compile(p, re.I), kind) for p, kind in KEY_KIND)

#: Keys that carry an id without saying anything about it. Seeing one of these
#: sends the classifier out to the enclosing table.
GENERIC_KEYS = frozenset({"id", "asset", "asset_id", "assetid", "value", "default"})

#: `key = "rbxassetid://123"` in Lua, or `"key": "rbxassetid://123"` in JSON.
#: Both spellings matter -- several of these games keep their asset manifests as
#: JSON beside the code that reads them, and a Lua-only pattern silently types
#: none of them.
KEYED_ID = re.compile(
    r"[\"']?([A-Za-z_][A-Za-z_0-9]*)[\"']?\s*[=:]\s*[\"']rbxassetid://(\d+)")

#: `some_name = {` -- the table an id sits inside. Scanned backwards from the
#: id, so the nearest enclosing definition wins.
BLOCK_OPEN = re.compile(r"^\s*\[?[\"']?([A-Za-z_][A-Za-z_0-9]*)[\"']?\]?\s*=\s*\{")


def _kind_from_name(name: str) -> str | None:
    """The asset kind a key name implies, or None if it implies nothing."""
    for pattern, kind in KEY_PATTERNS:
        if pattern.search(name):
            return kind
    return None


def _classify(text: str, filename: str = "") -> dict[str, str]:
    """Map each inline id in `text` to a kind.

    Three widening circles: the key, then the table enclosing it, then the file.
    Each is weaker than the last, and the file is weakest of all -- but a file
    called `sounds.lua` really does hold sounds, and taking that signal types
    ninety ids that carry no other clue at all.
    """
    lines = text.splitlines()
    found: dict[str, str] = {}
    from_file = _kind_from_name(filename) if filename else None

    for number, line in enumerate(lines):
        for key, asset_id in KEYED_ID.findall(line):
            if asset_id in found:
                continue

            kind = None
            if key.lower() not in GENERIC_KEYS:
                kind = _kind_from_name(key)

            if kind is None:
                #: Walk back for the table this id is being defined inside.
                #: Bounded because an unbounded scan eventually reaches the
                #: file's outermost table, whose name describes everything in
                #: the file and therefore describes nothing.
                for previous in range(number - 1, max(-1, number - 25), -1):
                    match = BLOCK_OPEN.match(lines[previous])
                    if match:
                        kind = _kind_from_name(match.group(1))
                        break

            #: Weakest circle, and last: what the file is named. Only reached
            #: when neither the key nor its table said anything.
            if kind is None:
                kind = from_file

            if kind:
                found[asset_id] = kind
    return found

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


#: Fields that come from Roblox rather than from reading the source, and that a
#: rescan must therefore carry forward rather than recompute. Resolving them
#: costs a Studio session and four minutes; silently discarding them on a
#: rebuild is how a scan becomes something nobody dares to run.
VERIFIED_FIELDS = ("verified", "name", "creator", "assetType", "error", "guessedKind")


def _group_by_type(ids: list[str], assets: dict[str, dict[str, Any]]) -> dict[str, list[str]]:
    """Split one game kind's assets by what they actually are.

    The flat per-kind list answers "what may a shooter use"; this answers "what
    meshes may a shooter use", which is the question somebody building one
    actually has. Only verified entries are grouped -- an unverified guess in a
    list headed `mesh` is worse than an absence.
    """
    grouped: dict[str, list[str]] = {}
    for asset_id in ids:
        entry = assets.get(asset_id) or {}
        if entry.get("verified") and entry.get("kind"):
            grouped.setdefault(entry["kind"], []).append(asset_id)
    return {kind: sorted(found) for kind, found in sorted(grouped.items())}


def build() -> dict[str, Any]:
    """Scan the salvage for asset references and attribute each to its systems."""
    owners = _systems_by_file()
    assets: dict[str, dict[str, Any]] = {}

    previous: dict[str, dict[str, Any]] = {}
    verified_summary: dict[str, Any] | None = None
    if ASSET_MAP.exists():
        try:
            existing = json.loads(ASSET_MAP.read_text(encoding="utf-8"))
            previous = existing.get("assets") or {}
            verified_summary = existing.get("verified")
        except (OSError, json.JSONDecodeError):
            pass

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

            inline_kind = _classify(text, path.name)

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

    #: Roblox's answer outranks the filename heuristic wherever both exist. The
    #: heuristic's guess is preserved as `guessedKind` when they disagree, so the
    #: classifier can be judged against ground truth instead of being trusted.
    for asset_id, entry in assets.items():
        known = previous.get(asset_id)
        if not known:
            continue
        for field in VERIFIED_FIELDS:
            if field in known:
                entry[field] = known[field]
        if known.get("verified") and known.get("kind"):
            guess = entry.get("kind")
            if guess and guess != known["kind"]:
                entry["guessedKind"] = guess
            entry["kind"] = known["kind"]

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
            "make. Every one resolved against Roblox: they exist, and `kind`/`name` are "
            "the web API's own answer. Existing is not the same as loading -- delivery of "
            "non-public assets is authorised against the requesting universe, so an id "
            "here can still fail to render in a place that does not own it. It says which "
            "forty to look at, not which are good."),
        "assets": assets,
        "byGameKind": by_kind,
        "byGameKindAndType": {
            kind: _group_by_type(ids, assets) for kind, ids in by_kind.items()
        },
        "gameKinds": {k: list(v) for k, v in GAME_KINDS.items()},
        "total": len(assets),
        "attributed": len(assets) - len(unattributed),
        "unattributed": len(unattributed),
    }
    if verified_summary:
        mapping["verified"] = verified_summary
    ASSET_MAP.write_text(json.dumps(mapping, indent=1, ensure_ascii=False) + "\n",
                         encoding="utf-8")
    return mapping
