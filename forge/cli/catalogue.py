"""Classify harvested content, and say what a game still needs.

The gap this closes
-------------------

257 pieces were lifted from licensed projects and shelved by *what they are* --
character, prop, tool, animation. That is enough to browse and not enough to
build with, and the proof is that quarryline shipped four machines made of
coloured boxes while `minershaven/Fire_Mine`, `Ice_Mine`, `Lightning_Mine` and
a 69-part, 41-mesh `Generator` sat unused on a shelf.

Nothing connected "this game needs a machine that produces ore" to "that file
is a mining machine". `Catalog.fromKit("drill")` searched by name, the piece is
called `Fire_Mine`, and the search failed silently into a grey box.

So this adds the missing middle: every piece gets a **style** and a **role**,
every game style declares the **roles it needs**, and the two are matched. What
matches is usable today; what does not is a gap with a name, which is the only
form of gap you can go and fill.

Why keyword classification, and where it stops
----------------------------------------------

A name is weak evidence and it is the evidence there is. `Fire_Mine` says mine,
`Halloween_streetlight` says lamp and says horror, `baobab_tree` says
vegetation. Structure corroborates: mesh count separates an authored model from
a pile of bricks, and part count separates a prop from somebody's whole level.

What it cannot do is judge whether a thing is *good*. That still needs eyes, and
the honest response is to record what is measurable -- meshes, textures, parts,
size -- so a person looks at ten candidates instead of two hundred.
"""

from __future__ import annotations

import json
import re
from pathlib import Path
from typing import Any

KITS = Path("forge/kits")
CATALOGUE = KITS / "catalogue.json"

#: Roles are what a game asks for. They are deliberately about *function in a
#: scene*, not about shape: a tycoon needs something that reads as "the machine
#: that produces", and whether that is a drill or a furnace is art direction.
ROLE_KEYWORDS: dict[str, tuple[str, ...]] = {
    "machine.source":   ("mine", "drill", "quarry", "extractor", "pump", "dropper"),
    "machine.process":  ("generator", "smelter", "furnace", "refinery", "forge", "reactor", "engine"),
    "machine.transport": ("conveyor", "belt", "rail", "cart", "pipe", "elevator", "lift"),
    "machine.store":    ("crate", "container", "silo", "tank", "chest", "vault", "depot", "storage"),
    "currency":         ("coin", "cash", "gem", "ruby", "treasure", "gold", "ingot"),
    "vegetation":       ("tree", "fern", "grass", "bush", "flower", "plant", "baobab", "palm"),
    "rock":             ("rock", "stone", "boulder", "ore", "crystal", "cliff"),
    "light":            ("lamp", "light", "torch", "lantern", "streetlight", "candle"),
    "structure":        ("house", "building", "wall", "gate", "fence", "door", "tower", "shed", "hut"),
    "path":             ("path", "road", "bridge", "stair", "ladder", "walkway"),
    "furniture":        ("table", "chair", "bench", "desk", "shelf", "sign", "board"),
    "hazard":           ("spike", "trap", "fire", "lava", "acid", "saw"),
    "effect":           ("particle", "beam", "aura", "explosion", "smoke", "spark"),
    "weapon":           ("sword", "gun", "pistol", "revolver", "axe", "bow", "blade", "hammer"),
    "grave":            ("grave", "tomb", "skull", "cemetery", "cemetary", "coffin", "pentagram", "cross"),
}

#: Style is the world a piece belongs to. A graveyard fence and an ore drill are
#: both `structure`-adjacent props and putting them in the same scene is how a
#: generated game looks assembled from a bargain bin.
STYLE_KEYWORDS: dict[str, tuple[str, ...]] = {
    "horror":     ("grave", "skull", "cemetery", "cemetary", "coffin", "pentagram", "nightmare",
                   "scary", "slendrina", "granny", "spider", "zombie", "chica", "torch", "halloween"),
    "industrial": ("mine", "drill", "generator", "smelter", "furnace", "conveyor", "belt",
                   "pipe", "engine", "reactor", "factory", "quarry", "silo"),
    "nature":     ("tree", "fern", "grass", "rock", "stone", "flower", "baobab", "plant", "leaf"),
    "fantasy":    ("halo", "portal", "cathedral", "rainbow", "golden", "magic", "rune", "crystal"),
    "combat":     ("sword", "gun", "pistol", "revolver", "axe", "blade", "armor", "shield"),
}

#: What each kind of game asks for. A style that cannot name its needs cannot be
#: told what it is missing, which is the whole point of this file.
STYLE_NEEDS: dict[str, tuple[str, ...]] = {
    "tycoon": ("machine.source", "machine.process", "machine.transport", "machine.store",
               "currency", "structure", "path", "light", "rock", "vegetation"),
    "horror": ("structure", "light", "grave", "path", "effect", "hazard"),
    "obby":   ("path", "hazard", "structure", "effect", "currency"),
    "combat": ("weapon", "structure", "effect", "hazard", "path"),
}


def _signals(path: Path) -> dict[str, int]:
    """Structural facts read from the file, without parsing it as a tree.

    Class names appear as plain text in both Roblox formats, so counting them is
    one read. Precision is not the point here -- separating a 69-part model with
    41 meshes from a four-brick prop is.
    """
    try:
        blob = path.read_bytes()
    except OSError:
        return {"parts": 0, "meshes": 0, "textures": 0, "bytes": 0}

    def count(*needles: bytes) -> int:
        return sum(blob.count(n) for n in needles)

    return {
        "parts": count(b'class="Part"', b'class="MeshPart"',
                       b'class="WedgePart"', b'class="UnionOperation"'),
        "meshes": count(b"MeshId", b'class="SpecialMesh"'),
        "textures": count(b'class="Texture"', b'class="Decal"', b'class="SurfaceAppearance"'),
        "bytes": len(blob),
    }


def _words(name: str) -> list[str]:
    return [w for w in re.split(r"[^a-z0-9]+", name.lower()) if w]


def _match(name: str, table: dict[str, tuple[str, ...]]) -> list[str]:
    """Every entry whose keywords appear in the name, best first.

    A piece can honestly be two things -- `Halloween_streetlight` is a light and
    it is horror -- so this returns all of them rather than forcing a choice
    that would lose the second fact.
    """
    lowered = name.lower()
    hits: list[tuple[int, str]] = []
    for key, keywords in table.items():
        score = sum(len(word) for word in keywords if word in lowered)
        if score:
            hits.append((score, key))
    hits.sort(reverse=True)
    return [key for _score, key in hits]


def classify_one(path: Path, kit: str, shelf: str) -> dict[str, Any]:
    name = path.stem
    signals = _signals(path)
    roles = _match(name, ROLE_KEYWORDS)
    styles = _match(name, STYLE_KEYWORDS)

    #[[
    #   The shelf is evidence too, and it outranks a silent name.
    #
    #   A piece on the `character` shelf is a character whatever it is called,
    #   and a `tool` is a tool. Only props are genuinely ambiguous, which is
    #   why they are the ones keywords have to work on.
    #]]
    if shelf in ("character", "tool", "vehicle", "gui", "animation", "animation-id"):
        roles = [shelf] + [r for r in roles if r != shelf]

    return {
        "name": name,
        "kit": kit,
        "shelf": shelf,
        "file": str(path).replace("\\", "/"),
        "roles": roles,
        "styles": styles,
        #: An authored model has meshes; a pile of bricks does not. This is the
        #: one signal that reliably separates "usable as-is" from "needs work".
        "authored": signals["meshes"] > 0 or signals["textures"] > 0,
        **signals,
    }


def build() -> dict[str, Any]:
    """Classify every harvested piece and write the catalogue."""
    pieces: list[dict[str, Any]] = []
    for shelf_dir in sorted(KITS.glob("*/mount/harvest/*")):
        if not shelf_dir.is_dir():
            continue
        kit = shelf_dir.parts[1]
        shelf = shelf_dir.name
        for piece in sorted(shelf_dir.glob("*.rbxmx")):
            pieces.append(classify_one(piece, kit, shelf))

    by_role: dict[str, int] = {}
    for piece in pieces:
        for role in piece["roles"]:
            by_role[role] = by_role.get(role, 0) + 1

    catalogue = {
        "$comment": (
            "Every harvested piece, tagged with the role it can fill and the style it "
            "belongs to. Written by `forge kit classify`. The point is matching: a game "
            "asks for roles, this says which files answer and which do not."),
        "pieces": pieces,
        "byRole": dict(sorted(by_role.items())),
        "unclassified": sum(1 for p in pieces if not p["roles"]),
        "total": len(pieces),
    }
    CATALOGUE.write_text(json.dumps(catalogue, indent=1, ensure_ascii=False) + "\n",
                         encoding="utf-8")
    return catalogue


def load() -> dict[str, Any]:
    if not CATALOGUE.exists():
        return {"pieces": [], "byRole": {}, "total": 0}
    try:
        return json.loads(CATALOGUE.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return {"pieces": [], "byRole": {}, "total": 0}


def match(style: str, prefer_authored: bool = True) -> dict[str, Any]:
    """What a style needs, what answers it, and what is missing.

    Candidates are ranked by whether they are authored and then by how much is
    in them, because the choice a person actually makes is "show me the ones
    with meshes first".
    """
    needs = STYLE_NEEDS.get(style)
    if not needs:
        raise KeyError(f"no needs declared for style '{style}'; "
                       f"known: {', '.join(sorted(STYLE_NEEDS))}")

    catalogue = load()
    filled: dict[str, list[dict[str, Any]]] = {}
    missing: list[str] = []

    for role in needs:
        candidates = [p for p in catalogue["pieces"] if role in p.get("roles", [])]
        #: Same-style pieces first: a graveyard fence answers `structure` and
        #: puts a headstone in a quarry.
        candidates.sort(key=lambda p: (
            style not in p.get("styles", []),
            not p.get("authored") if prefer_authored else False,
            -p.get("parts", 0),
        ))
        if candidates:
            filled[role] = candidates[:5]
        else:
            missing.append(role)

    return {
        "style": style,
        "needs": list(needs),
        "filled": filled,
        "missing": missing,
        "coverage": f"{len(filled)}/{len(needs)}",
    }
