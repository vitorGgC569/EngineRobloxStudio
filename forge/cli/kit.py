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

Two speeds of content, and both are taken
-----------------------------------------

`.rbxm` files are Roblox instances: rojo mounts them straight into a place and
they work the moment the game starts. No upload, no moderation, no network.

Images, audio and meshes cannot be used that way — a game references them by
asset id, and an id only exists after `forge upload` has pushed the file and
moderation has passed it. That is a pipeline rather than a copy, and it is slow.

Both are taken anyway, into separate folders, because the alternative is
leaving six hundred icons in somebody else's repository and rediscovering them
in a year. A file that is copied and catalogued can be uploaded on the day it
is wanted; a file nobody recorded is a file nobody uploads.

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
import subprocess
import shutil
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

REPO = Path(__file__).resolve().parents[2]
KITS = REPO / "forge" / "kits"

#: Roblox instance containers: mountable by rojo, usable the instant the game
#: starts, no upload and no moderation.
INSTANCE_SUFFIXES = (".rbxm", ".rbxmx")

#: Whole places. Not mountable as-is, but an XML one can be read and the models
#: inside it lifted out — which is how an authored world becomes a set of props.
PLACE_SUFFIXES = (".rbxl", ".rbxlx")

#: Everything that has to travel through Roblox's asset pipeline before a game
#: can reference it. Copied and catalogued rather than ignored: `forge upload`
#: is the other half, and a file nobody recorded is a file nobody uploads.
UPLOADABLE = {
    ".png": "image",
    ".jpg": "image",
    ".jpeg": "image",
    ".tga": "image",
    ".mp3": "audio",
    ".ogg": "audio",
    ".wav": "audio",
    ".fbx": "mesh",
    ".obj": "mesh",
    ".glb": "mesh",
    ".gltf": "mesh",
}

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


#: Classes that exist once per place and cannot be re-parented.
#:
#: A kit is content mounted into `ReplicatedStorage`, so every piece has to be
#: something Roblox will let you put anywhere. `Terrain` is not: a file
#: carrying one makes Studio refuse to open the whole place with "Unable to
#: change Terrain's parent. Workspace already has Terrain" — which is not a
#: warning, it is a place that will not load.
#:
#: Found the only way these things are found: by building a game with a kit in
#: it and watching Studio refuse the file.
SINGLETON_CLASSES = (
    "Terrain", "Workspace", "Players", "Lighting", "StarterGui", "StarterPack",
    "StarterPlayer", "SoundService", "ReplicatedStorage", "ServerScriptService",
    "ServerStorage", "Teams", "Chat", "TestService",
)


def carries_singleton(path: Path) -> str | None:
    """Whether a file holds an instance that cannot be parented into a kit.

    Reads the raw bytes rather than parsing. Class names appear as plain text
    in both the XML and the binary formats, so one scan covers both — and a
    false positive costs one excluded prop while a false negative costs a place
    that will not open.
    """
    try:
        blob = path.read_bytes()
    except OSError:
        return None
    for name in SINGLETON_CLASSES:
        if f'class="{name}"'.encode() in blob:
            return name
    return None


def survey(source: Path) -> list[dict[str, Any]]:
    """Every piece of content a project holds, and what could be done with it.

    Read-only. Run it before `add`: several of these are large, and a kit is a
    thing you commit.

    Four kinds, and the distinction is what you can do with each:

      instance    `.rbxm`, mountable today, no upload
      place       a whole world; an XML one can have its models lifted out
      uploadable  images, audio, meshes — needs `forge upload` and moderation
      (skipped)   everything else: source, docs, build tooling
    """
    if not source.exists():
        raise KitError(f"no project at {source}")

    found: list[dict[str, Any]] = []
    for path in sorted(source.rglob("*")):
        if ".git" in path.parts or not path.is_file():
            continue
        suffix = path.suffix.lower()
        relative = path.relative_to(source)

        if suffix in INSTANCE_SUFFIXES:
            kind, category = "instance", categorise(relative)
        elif suffix in PLACE_SUFFIXES:
            kind, category = "place", "place"
        elif suffix in UPLOADABLE:
            kind, category = "uploadable", UPLOADABLE[suffix]
        else:
            continue

        found.append({
            "path": str(relative).replace("\\", "/"),
            "name": path.stem,
            "bytes": path.stat().st_size,
            "kind": kind,
            "category": category,
            # An XML file can be read and searched later; a binary one can only
            # be mounted. It decides what tooling can do with it afterwards.
            "format": "xml" if suffix in (".rbxmx", ".rbxlx") else "binary",
        })
    return found


#: How big a file of each kind may be before it is indexed instead of copied.
#:
#: An instance is small and immediately usable, so the bar is generous. Source
#: art is not: HaloAndHorns alone holds 1.1GB of images, most of it 4K contact
#: sheets and skyboxes, and copying that into a git repository would be a worse
#: decision than not extracting it at all.
#:
#: Anything over the bar is still *recorded* — path, size, category, source
#: project — which is the part that makes it findable in a year. The index is
#: the reusable artefact for content too big to carry.
COPY_LIMITS = {
    "instance": 12_000_000,
    "place": 12_000_000,
    "uploadable": 400_000,
}


def add(source: Path, name: str, limit_bytes: int | None = None,
        categories: list[str] | None = None, kinds: list[str] | None = None) -> dict[str, Any]:
    """Copy a project's content into `forge/kits/<name>`.

    Laid out by what can be done with a file rather than by where it sat:

        mount/<category>/    instances rojo puts in the place
        upload/<category>/   images, audio, meshes awaiting `forge upload`
        places/              whole worlds, for `extract` to mine

    Flattened rather than mirroring the source tree, because that tree is
    however the project happened to organise itself and a kit is meant to be
    browsed by somebody who has never seen it.

    Anything past its kind's size limit is **indexed rather than copied**: the
    manifest records where it is and what it is, and the bytes stay in the
    source project. That is deliberate. "Extract everything" cannot sensibly
    mean "copy 1.3GB of 4K textures into version control", and a catalogue
    entry is what makes a file findable when somebody actually wants it.
    """
    pieces = survey(source)
    if categories:
        pieces = [p for p in pieces if p["category"] in categories]
    if kinds:
        pieces = [p for p in pieces if p["kind"] in kinds]
    if not pieces:
        raise KitError(f"{source} holds no content this understands")

    destination = KITS / name
    destination.mkdir(parents=True, exist_ok=True)

    roots = {"instance": "mount", "uploadable": "upload", "place": "places"}

    copied, indexed = [], []
    for piece in pieces:
        cap = limit_bytes or COPY_LIMITS.get(piece["kind"], 400_000)
        if piece["bytes"] > cap:
            indexed.append({
                **piece,
                "reason": f"over {cap // 1000}KB for a {piece['kind']}",
                # Where it actually is, so the index is usable rather than a
                # list of names nobody can act on.
                "sourcePath": str(source / piece["path"]),
            })
            continue

        root = roots.get(piece["kind"], "mount")
        folder = destination / root
        if piece["kind"] != "place":
            folder = folder / piece["category"]
        folder.mkdir(parents=True, exist_ok=True)

        # Names become Roblox instance names once mounted, so anything a path
        # allows and an instance does not has to go.
        safe = re.sub(r"[^A-Za-z0-9_-]", "_", piece["name"])[:60] or "piece"
        suffix = Path(piece["path"]).suffix
        target = folder / f"{safe}{suffix}"

        # Two files with the same stem in different source folders would
        # otherwise silently overwrite each other.
        counter = 2
        while target.exists():
            target = folder / f"{safe}_{counter}{suffix}"
            counter += 1

        origin = source / piece["path"]
        if piece["kind"] == "instance":
            singleton = carries_singleton(origin)
            if singleton:
                indexed.append({
                    **piece,
                    "reason": f"holds a {singleton}, which cannot be parented into a kit",
                    "sourcePath": str(origin),
                })
                continue

        shutil.copy2(origin, target)
        copied.append({
            **piece,
            "kitPath": str(target.relative_to(destination)).replace("\\", "/"),
        })

    manifest = {
        "kit": name,
        "source": str(source),
        "harvestedAt": datetime.now(timezone.utc).isoformat(),
        # The claim that makes this legitimate, written where it can be checked
        # rather than remembered.
        "licence": "held by the repository owner; see the source project",
        "pieces": copied,
        # Too large to carry, recorded so it can be found and uploaded later.
        "indexed": indexed,
        "byCategory": _counts(copied),
        "byKind": _counts(copied, "kind"),
        "indexedBytes": sum(p["bytes"] for p in indexed),
    }
    (destination / "kit.json").write_text(
        json.dumps(manifest, indent=2, ensure_ascii=False), encoding="utf-8")
    return manifest


def _counts(pieces: list[dict[str, Any]], field: str = "category") -> dict[str, int]:
    counts: dict[str, int] = {}
    for piece in pieces:
        key = str(piece.get(field, "?"))
        counts[key] = counts.get(key, 0) + 1
    return counts


def extract_models(place: Path, destination: Path, limit: int = 400,
                   min_parts: int = 4, max_parts: int = 400) -> list[dict[str, Any]]:
    """Lift the models out of an authored place and write each as its own file.

    An authored world is the most valuable thing in a licensed project and the
    least reusable: a 100MB place is somebody's whole game, and no other game
    wants it. What every other game wants is the *pieces* — the shed, the
    crane, the rock formation somebody actually modelled.

    So this streams the XML and writes each top-level `Model` out as a standalone
    `.rbxmx` that rojo can mount like any other. Streaming rather than parsing
    whole: these files run to a hundred megabytes and `ElementTree.parse` would
    hold all of it, plus the tree, in memory at once.

    Two bounds, and both matter for different reasons.

    `min_parts` skips the debris: a place is full of one-part "models" that are
    a single brick somebody grouped by accident, and four thousand of those
    bury the twelve worth having.

    `max_parts` skips the level. A 1300-part "MainIsland" is not a prop, it is
    somebody's whole world in one instance — the exact thing that is not
    reusable. Without this bound the first extraction produced 86MB, most of it
    three islands.

    Names are deduplicated too. A place holds eight copies of the same bridge
    at different positions; they are not identical files, and they are the same
    prop.

    Binary `.rbxl` cannot be read here. Roblox's binary format is not something
    to reimplement for this — open it in Studio and save the models out, which
    is a person's job once rather than a parser to maintain for ever.
    """
    import xml.etree.ElementTree as ET

    if place.suffix.lower() not in (".rbxlx", ".rbxmx"):
        raise KitError(f"{place.name} is binary; open it in Studio and save the models out")

    destination.mkdir(parents=True, exist_ok=True)
    written: list[dict[str, Any]] = []
    seen: dict[str, int] = {}

    depth = 0
    capturing: ET.Element | None = None
    stack: list[ET.Element] = []

    for event, element in ET.iterparse(str(place), events=("start", "end")):
        if event == "start":
            if element.tag == "Item":
                depth += 1
                if capturing is None and element.get("class") == "Model":
                    capturing = element
                    stack = [element]
                elif capturing is not None:
                    stack.append(element)
            continue

        # end
        if element.tag != "Item":
            continue
        depth -= 1
        if capturing is None:
            element.clear()
            continue

        stack.pop()
        if stack:
            continue

        # The captured subtree is complete.
        parts = sum(1 for item in capturing.iter("Item")
                    if (item.get("class") or "").endswith("Part"))
        name = None
        for prop in capturing.iter("string"):
            if prop.get("name") == "Name":
                name = (prop.text or "").strip()
                break

        if min_parts <= parts <= max_parts and name and name not in seen:
            seen[name] = 1
            safe = re.sub(r"[^A-Za-z0-9_-]", "_", name)[:48] or "model"
            if any(item.get("class") in SINGLETON_CLASSES
                   for item in capturing.iter("Item")):
                capturing.clear()
                capturing = None
                continue

            target = destination / f"{safe}.rbxmx"
            root = ET.Element("roblox", {"version": "4"})
            root.append(capturing)
            ET.ElementTree(root).write(target, encoding="utf-8", xml_declaration=True)
            written.append({
                "name": name,
                "file": target.name,
                "parts": parts,
                "bytes": target.stat().st_size,
            })

        capturing.clear()
        capturing = None
        if len(written) >= limit:
            break

    return written


# ============================== the acervo ==================================
#: What a captured subtree is *for*, which is not the same as its class.
#:
#: A `Model` in an authored place is a shed, a boss, or somebody's whole level,
#: and the three want completely different handling. Classifying on the way out
#: is what turns 10,000 extracted Models — which is a second copy of the source
#: game, and useless — into a library you can find a monster in.
HARVEST_CLASSES = ("Model", "ScreenGui", "KeyframeSequence", "Animation", "Tool")

#: The largest a thing can be and still be somebody rather than somewhere.
CHARACTER_MAX_PARTS = 150

#: Property names whose value is an asset id, and what that id actually is.
#:
#: Recorded even for content that cannot be copied. A mesh belongs to whoever
#: uploaded it and lives on Roblox's CDN, so the file is not ours to take — but
#: the *id*, and the knowledge that it is the boss's head, is a catalogue entry,
#: and a catalogue is the difference between an archive and a pile.
ASSET_PROPERTIES = {
    "MeshId": "mesh", "TextureID": "texture", "TextureId": "texture",
    "SoundId": "sound", "AnimationId": "animation", "Image": "image",
    "Texture": "texture", "ColorMap": "texture", "NormalMap": "texture",
    "RoughnessMap": "texture", "MetalnessMap": "texture",
    "SkyboxBk": "skybox", "SkyboxDn": "skybox", "SkyboxFt": "skybox",
    "SkyboxLf": "skybox", "SkyboxRt": "skybox", "SkyboxUp": "skybox",
    "HeadColor3": None, "Graphic": "image",
}

_ASSET_PATTERN = re.compile(
    rb'name="([A-Za-z0-9_]+)"[^>]*>\s*(?:<url>)?\s*(rbxassetid://\d+|rbxasset://[^<\s"]+)')
_BARE_ASSET = re.compile(rb"rbxassetid://(\d+)")


def asset_ids(path: Path) -> dict[str, Any]:
    """Every asset the file refers to, by kind where the format says so.

    Reads bytes rather than parsing, for the same reason `carries_singleton`
    does: the binary format and the XML one both carry these as plain text, and
    one scan covering both beats a parser that covers half.

    XML gives the property name, so a mesh can be told from a sound. Binary does
    not, so those land under `unknown` — which is honest, and still useful,
    because an id with no kind is an id you can still look up.
    """
    try:
        blob = path.read_bytes()
    except OSError:
        return {"byKind": {}, "total": 0}

    by_kind: dict[str, set[str]] = {}
    claimed: set[bytes] = set()
    for prop, value in _ASSET_PATTERN.findall(blob):
        kind = ASSET_PROPERTIES.get(prop.decode("ascii", "replace"))
        if kind is None:
            continue
        by_kind.setdefault(kind, set()).add(value.decode("ascii", "replace"))
        claimed.add(value)

    for number in _BARE_ASSET.findall(blob):
        value = b"rbxassetid://" + number
        if value not in claimed:
            by_kind.setdefault("unknown", set()).add(value.decode("ascii"))

    return {
        "byKind": {k: sorted(v) for k, v in sorted(by_kind.items())},
        "total": sum(len(v) for v in by_kind.values()),
    }


def _subtree_name(element: Any) -> str | None:
    for prop in element.iter("string"):
        if prop.get("name") == "Name":
            return (prop.text or "").strip() or None
    return None


def _classify(element: Any, klass: str, parts: int,
              min_parts: int, max_parts: int) -> str | None:
    """Which shelf this belongs on, or None to leave it in the place."""
    # Not geometry, so no size bound applies: a HUD is one ScreenGui however
    # much is in it, and an animation has no parts at all.
    if klass == "ScreenGui":
        return "gui"
    #[[
    #   Keyframes and animation ids are not the same shelf.
    #
    #   A `KeyframeSequence` carries the poses: it is data, it is self
    #   contained, and it plays. An `Animation` carries only
    #   `rbxassetid://...` pointing at an upload on the account that authored
    #   the source game -- which fails for us exactly the way the harvested
    #   Sounds did, and for exactly the same reason.
    #
    #   Shelved together they read as one library of eighty-nine animations,
    #   half of which silently do nothing. Apart, the counts tell the truth.
    #]]
    if klass == "KeyframeSequence":
        return "animation"
    if klass == "Animation":
        return "animation-id"
    if klass == "Tool":
        return "tool"

    #[[
    #   Everything past here is geometry, and the size bound comes first.
    #
    #   It used to come last, after asking what the subtree contained, and that
    #   ordering is wrong in a way that took two attempts to see. A tycoon's
    #   entire level contains a shopkeeper, so it shelved as a `character`;
    #   bounding characters alone moved the same 127MB file to `vehicle`,
    #   because the level also contains a chair. Whatever a level contains, it
    #   is a level -- so the bound belongs above the question, not inside one
    #   answer to it.
    #]]
    if parts < min_parts or parts > max_parts:
        return None

    classes = {item.get("class") for item in element.iter("Item")}
    # A Humanoid is what makes a pile of parts something that walks, and a rig
    # is tens of parts: the tighter ceiling separates a monster from a room
    # with a monster in it.
    if "Humanoid" in classes and parts <= CHARACTER_MAX_PARTS:
        return "character"
    if "Seat" in classes or "VehicleSeat" in classes:
        return "vehicle"
    return "prop"


def harvest(place: Path, destination: Path, *, limit: int = 4000,
            min_parts: int = 4, max_parts: int = 400,
            per_kind: int = 600) -> dict[str, Any]:
    """One streaming pass over an authored place, shelved by what things are.

    This replaces counting parts as the only question asked of a subtree. Part
    count tells you a shed from a level and nothing else; it cannot tell you
    that the 18-part model is the boss, and the boss is the thing another game
    actually wants.

    `per_kind` is a separate ceiling from `limit` on purpose. A horror map holds
    two hundred copies of the same chair and three monsters, and a single global
    limit spends itself on chairs long before it reaches a monster.
    """
    import xml.etree.ElementTree as ET

    if place.suffix.lower() not in (".rbxlx", ".rbxmx"):
        raise KitError(f"{place.name} is binary; open it in Studio and save the models out")

    written: list[dict[str, Any]] = []
    counts: dict[str, int] = {}
    seen: set[str] = set()
    capturing: Any = None
    stack: list[Any] = []

    for event, element in ET.iterparse(str(place), events=("start", "end")):
        if event == "start":
            if element.tag != "Item":
                continue
            if capturing is None:
                if (element.get("class") or "") in HARVEST_CLASSES:
                    capturing = element
                    stack = [element]
            else:
                stack.append(element)
            continue

        if element.tag != "Item":
            continue
        if capturing is None:
            element.clear()
            continue
        stack.pop()
        if stack:
            continue

        klass = capturing.get("class") or ""
        parts = sum(1 for item in capturing.iter("Item")
                    if (item.get("class") or "").endswith("Part"))
        name = _subtree_name(capturing)
        kind = _classify(capturing, klass, parts, min_parts, max_parts)

        # A subtree carrying a singleton cannot be mounted anywhere, and one
        # such file makes the whole place refuse to open. Cheaper to drop.
        if any(item.get("class") in SINGLETON_CLASSES for item in capturing.iter("Item")):
            kind = None

        #[[
        #   Strip the package links rather than dropping the piece.
        #
        #   A `PackageLink` points at an asset on the account that authored the
        #   source game, so it always resolves to "Sem acesso" for us -- and
        #   Studio answers that with a modal dialog on open, which owns the
        #   window and stops Play Solo from ever starting. The model itself is
        #   perfectly good; only the link back to somebody else's asset is not.
        #]]
        if kind:
            for parent in capturing.iter():
                for child in list(parent):
                    if child.tag == "Item" and child.get("class") == "PackageLink":
                        parent.remove(child)

        key = f"{kind}/{name}"
        if kind and name and key not in seen and counts.get(kind, 0) < per_kind:
            seen.add(key)
            counts[kind] = counts.get(kind, 0) + 1
            folder = destination / kind
            folder.mkdir(parents=True, exist_ok=True)
            safe = re.sub(r"[^A-Za-z0-9_-]", "_", name)[:48] or kind
            target = folder / f"{safe}.rbxmx"
            root = ET.Element("roblox", {"version": "4"})
            root.append(capturing)
            ET.ElementTree(root).write(target, encoding="utf-8", xml_declaration=True)
            written.append({
                "name": name, "kind": kind, "class": klass,
                "file": f"{kind}/{target.name}", "parts": parts,
                "bytes": target.stat().st_size,
            })

        # ------------------------------------------------------------------
        #[[
        #   Animations shelved separately, as well as shipped with their rig.
        #
        #   A `KeyframeSequence` lives inside the model it animates, so the
        #   capture above swallows it whole and the animation shelf comes out
        #   empty while the place holds two hundred of them. That is the
        #   difference between having a monster and having a walk cycle: the
        #   rig is one prop, the animations are a library, and a fighting game
        #   wants the library.
        #]]
        if kind and name:
            for item in capturing.iter("Item"):
                itemClass = item.get("class") or ""
                if itemClass not in ("KeyframeSequence", "Animation"):
                    continue
                shelfName = "animation" if itemClass == "KeyframeSequence" else "animation-id"
                if counts.get(shelfName, 0) >= per_kind:
                    continue
                clip = _subtree_name(item) or name
                clipkey = f"{shelfName}/{clip}"
                if clipkey in seen:
                    continue
                seen.add(clipkey)
                counts[shelfName] = counts.get(shelfName, 0) + 1
                folder = destination / shelfName
                folder.mkdir(parents=True, exist_ok=True)
                safe = re.sub(r"[^A-Za-z0-9_-]", "_", clip)[:48] or "clip"
                target = folder / f"{safe}.rbxmx"
                root = ET.Element("roblox", {"version": "4"})
                root.append(item)
                ET.ElementTree(root).write(target, encoding="utf-8", xml_declaration=True)
                written.append({
                    "name": clip, "kind": shelfName,
                    "class": itemClass, "from": name,
                    "file": f"{shelfName}/{target.name}",
                    "bytes": target.stat().st_size,
                })

        capturing.clear()
        capturing = None
        if len(written) >= limit:
            break

    return {"written": written, "byKind": counts}


#: Where the binary reader lives once it has been built.
CONVERTER = Path(__file__).resolve().parents[2] / "tools" / "rbx-convert" / "target" / "release" / "rbx-convert.exe"


def convert(source: Path, destination: Path) -> Path:
    """Turn a binary `.rbxl`/`.rbxm` into the XML the harvester can read.

    Half the licensed projects ship binary, and this module used to answer that
    with a comment telling a human to open each one in Studio and save the
    models out by hand. Nobody was ever going to do that twenty-three times, so
    in practice it meant those projects contributed nothing -- and they were the
    ones holding the fighting game's fifty-nine animations, the tycoon's
    twenty-eight tools and every HUD in the collection.

    `rbx-dom` reads both formats and rojo already depends on it, so the whole
    problem is thirty lines of Rust in `tools/rbx-convert`, built once.
    """
    if not CONVERTER.is_file():
        raise KitError(
            "the binary reader is not built yet: "
            "cd tools/rbx-convert && cargo build --release")
    destination.parent.mkdir(parents=True, exist_ok=True)
    finished = subprocess.run(
        [str(CONVERTER), str(source), str(destination)],
        capture_output=True, text=True)
    if finished.returncode != 0:
        raise KitError((finished.stderr or "conversion failed").strip())
    return destination


# ============================== the toolbox =================================
#: Roblox's own model search, the one the Studio toolbox window talks to.
#:
#: `rqe assets search` goes through Open Cloud, which reports itself AVAILABLE
#: and then answers `roblox_authorization_blocked` without an API key. These
#: endpoints answer unauthenticated, which is what makes a machine model
#: reachable at all: no licensed project in the collection had a drill, a
#: conveyor or a smelter, and no amount of harvesting was going to produce one.
TOOLBOX_SEARCH = "https://apis.roblox.com/toolbox-service/v1/marketplace/10"
TOOLBOX_DETAILS = "https://apis.roblox.com/toolbox-service/v1/items/details"
ASSET_DELIVERY = "https://assetdelivery.roblox.com/v1/asset/"

#: Sent because the endpoints answer 403 to a bare urllib agent string.
_AGENT = {"User-Agent": "Mozilla/5.0"}


def _get_json(url: str, timeout: float = 25.0) -> dict[str, Any]:
    import urllib.request
    request = urllib.request.Request(url, headers=_AGENT)
    with urllib.request.urlopen(request, timeout=timeout) as response:
        return json.loads(response.read().decode("utf-8", "replace"))


def toolbox_search(query: str, limit: int = 12) -> list[dict[str, Any]]:
    """Find free models by keyword.

    Delegates to `rqe.assets.toolbox`, which owns asset discovery: `forge`
    builds games and harvests kits, `rqe` decides what an asset is and whether
    it may be used. Keeping one implementation also keeps the production
    capability catalogue honest -- it only accepts adapter symbols under `rqe.`,
    so a second copy here would be a dependency nothing could declare.
    """
    import sys
    sys.path.insert(0, str(Path(__file__).resolve().parents[2]))
    from rqe.assets import toolbox

    return toolbox.search(query, limit=limit)


def fetch_asset(asset_id: int, destination: Path, *, name: str | None = None,
                creator: str = "") -> dict[str, Any]:
    """Download one public model, convert it, and make it safe to mount.

    The delivery endpoint hands back the binary form, so this runs it through
    the same converter the licensed binaries go through, then applies every
    guard the harvest learned the hard way: no service singletons, no
    `PackageLink` (which greets the next Studio launch with a modal that owns
    the window), and no `SoundId` pointing at somebody else's upload.

    Attribution is written next to the file rather than assumed. A model taken
    from the toolbox has an author, and a library that cannot say whose work it
    is holding is a library nobody can safely publish from.
    """
    import urllib.request
    import xml.etree.ElementTree as ET

    destination.mkdir(parents=True, exist_ok=True)
    safe = re.sub(r"[^A-Za-z0-9_-]", "_", (name or str(asset_id)))[:48] or str(asset_id)

    request = urllib.request.Request(f"{ASSET_DELIVERY}?id={int(asset_id)}", headers=_AGENT)
    with urllib.request.urlopen(request, timeout=60) as response:
        payload = response.read()

    staged = destination / f".{safe}.rbxm"
    staged.write_bytes(payload)
    target = destination / f"{safe}.rbxmx"
    try:
        if payload[:8].lstrip().startswith(b"<roblox"):
            # Already XML: some older uploads are stored that way.
            target.write_bytes(payload)
        else:
            convert(staged, target)
    finally:
        staged.unlink(missing_ok=True)

    singleton = carries_singleton(target)
    if singleton:
        target.unlink(missing_ok=True)
        raise KitError(f"asset {asset_id} carries a {singleton} and cannot be mounted")

    tree = ET.parse(str(target))
    root = tree.getroot()
    stripped = {"PackageLink": 0, "SoundId": 0}
    for parent in root.iter():
        for child in list(parent):
            if child.tag == "Item" and child.get("class") == "PackageLink":
                parent.remove(child)
                stripped["PackageLink"] += 1
    for content in root.iter("Content"):
        if content.get("name") == "SoundId" and len(content):
            content.clear()
            content.set("name", "SoundId")
            ET.SubElement(content, "null")
            stripped["SoundId"] += 1
    tree.write(str(target), encoding="utf-8", xml_declaration=True)

    return {
        "id": int(asset_id),
        "name": name or str(asset_id),
        "creator": creator,
        "file": target.name,
        "bytes": target.stat().st_size,
        "stripped": stripped,
        "source": f"https://www.roblox.com/library/{int(asset_id)}",
    }


# =============================== code salvage ===============================
#: Directories that are somebody else's dependency tree rather than the
#: project's own thinking, and tests that only make sense beside the harness
#: they were written for.
SALVAGE_SKIP = ("packages", "_index", "node_modules", ".git", "roblox_packages",
                "devpackages", "dist", "build", "out")

#: Suffixes worth taking. Code and the tables that configure it -- a system
#: without its config is a system nobody can see the shape of.
SALVAGE_SUFFIXES = (".lua", ".luau", ".json", ".toml")

#: Nothing above this is a module; it is generated or vendored.
SALVAGE_MAX_BYTES = 400_000


def salvage(source: Path, name: str, include_tests: bool = False) -> dict[str, Any]:
    """Copy a project's source wholesale, structure intact, provenance recorded.

    Why wholesale, and why unmodified
    ---------------------------------

    Every mining pass before this one took what it recognised: small libraries
    with obvious seams, and art out of places. It walked straight past the
    thing worth the most -- the system layer of a finished commercial game.
    HaloAndHorns holds 1,233 modules and 87,000 lines, of which the earlier
    pass took 278 files of audio, mesh and image and **not one line of logic**:
    no gacha, no daily streak, no retention ladder, no combat maths, no pet
    following.

    The reason is that recognising a system takes reading it, and reading 1,233
    modules to decide what to copy is the same work as copying them and reading
    afterwards -- except the second order keeps the option open.

    So this copies first and understands later. What lands here is unmodified
    third-party source under the licence the operator holds, kept whole so the
    relationships between modules survive: a `PetFollowService` without
    `PetFormation`, `PetMeander` and `configs/pet_follow.lua` beside it is a
    file, not a system.

    Generalising into `Forge` families is the separate, deliberate step that
    follows, and it is the step where copyright and design both get decided.
    """
    if not source.is_dir():
        raise KitError(f"{source} is not a directory")

    destination = KITS / name / "salvage"
    destination.mkdir(parents=True, exist_ok=True)

    taken: list[dict[str, Any]] = []
    skipped = 0

    for path in sorted(source.rglob("*")):
        if not path.is_file() or path.suffix.lower() not in SALVAGE_SUFFIXES:
            continue

        lowered = [part.lower() for part in path.relative_to(source).parts]
        if any(part in SALVAGE_SKIP for part in lowered):
            skipped += 1
            continue
        if not include_tests and any(
                part in ("test", "tests", "spec", "specs", "__tests__") for part in lowered):
            skipped += 1
            continue
        if path.stat().st_size > SALVAGE_MAX_BYTES:
            skipped += 1
            continue

        relative = path.relative_to(source)
        target = destination / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(path, target)
        taken.append({
            "path": str(relative).replace("\\", "/"),
            "bytes": path.stat().st_size,
            "lines": path.read_text(encoding="utf-8", errors="replace").count(chr(10)) + 1,
        })

    manifest = {
        "$comment": (
            "Unmodified source copied from a licensed project, kept whole so the "
            "relationships between modules survive. Generalising anything here into a "
            "Forge family is a separate step; nothing in this folder has been reviewed, "
            "adapted, or cleared for shipping as-is."),
        "kit": name,
        "source": str(source),
        "files": len(taken),
        "lines": sum(f["lines"] for f in taken),
        "skipped": skipped,
        "takenAt": datetime.now(timezone.utc).isoformat(timespec="seconds"),
        "manifest": taken,
    }
    (KITS / name / "salvage.json").write_text(
        json.dumps(manifest, indent=1, ensure_ascii=False) + chr(10), encoding="utf-8")
    return manifest


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
            name: {"$path": f"../../forge/kits/{name}/mount"},
        },
    }, indent=2)


def render(manifest: dict[str, Any]) -> str:
    lines = [f"  {manifest['kit']}  <-  {manifest['source']}"]
    for category, count in sorted(manifest["byCategory"].items()):
        lines.append(f"    {category:<14} {count}")
    if manifest.get("indexed"):
        size = manifest.get("indexedBytes", 0) / 1_000_000
        lines.append("")
        lines.append(f"    {len(manifest['indexed'])} files indexed but not copied "
                     f"({size:.0f}MB, still in the source project)")
    lines.append("")
    lines.append("  mount it by adding this to the game's default.project.json,")
    lines.append("  under ReplicatedStorage:")
    lines.append("")
    for line in mount_snippet(manifest["kit"]).splitlines():
        lines.append("    " + line)
    return "\n".join(lines)
