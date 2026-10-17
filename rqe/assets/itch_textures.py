"""Surface textures from the CC0 itch packs, published and catalogued.

The third asset pipeline, and the one that was missing. `itch_publish` handles
models and `itch_ui` handles interface art; neither can help a game that needs
a *surface* -- a ground, a wall, a plank floor. Every game in this repository
has therefore been built out of flat-coloured parts, which is most of why they
read as blockouts rather than as places.

Why these packs and not the photoreal ones
------------------------------------------

The harvest holds 6,849 texture-looking images across 168 packs, and most of
them are 1K and 2K PBR sets for a renderer this is not. `Classic64` is 813
images at a kilobyte each: low-resolution, hand-drawn, and tiling. On a Roblox
part at a couple of studs per tile that reads as a stylised surface rather than
as a blurry photograph, which is the look these games actually want.

What a texture becomes
----------------------

An `Image` asset, then a `MaterialVariant` through `Forge.Material`. The
variant is the part that matters: a decal stretched over a part is a decal, but
a material variant tiles by studs, takes the engine's lighting, and can be
swapped per zone by name. `Forge.Material.define` already does all of that and
has never had anything to define.
"""

from __future__ import annotations

import json
import os
import re
import time
import urllib.error
import urllib.request
import uuid
import zipfile
from pathlib import Path
from typing import Any

from . import local_credentials
from ..http_safety import HttpBoundaryError, error_body_limited, json_object_limited

ROOT = Path("assets/itch")
PUBLISHED = Path("forge/kits/itch-textures.json")
CATALOGUE = Path("forge/luau/Forge/Catalog/Textures.lua")
DELAY = 1.1
MAX_API_RESPONSE_BYTES = 4 * 1024 * 1024

#[[
#   The surfaces a game actually asks for.
#
#   Deliberately short. A catalogue of eight hundred textures is a catalogue
#   nobody chooses from, and the failure mode of the model catalogue -- 538
#   published, eleven used -- is already documented. Each role here is a thing
#   a game says out loud: "this zone's ground", "this building's walls".
#]]
ROLES: dict[str, tuple[str, ...]] = {
    "ground.grass": ("grass_",),
    "ground.dirt": ("dirt_", "ground_dirt", "soil"),
    "ground.sand": ("sand_",),
    "ground.snow": ("snow_",),
    "ground.ice": ("ice_",),
    "ground.stone": ("rock_", "stone_", "cobble"),
    "ground.ash": ("ash_", "gravel", "concrete_0"),
    "wall.brick": ("brick_",),
    "wall.plaster": ("wall_", "plaster"),
    "floor.plank": ("wood_plank", "planks_", "siding_wood"),
    "floor.tile": ("tile_",),
    "wood.bare": ("wood_bare", "wood_light", "wood_dark"),
    "metal.plate": ("metal_plate", "metal_panel", "metal_rust"),
}

#: Maps and masks a Roblox `SurfaceAppearance` can use beside the colour map.
#: Everything else in a PBR set is noise here.
_SUFFIX = {
    "normal": re.compile(r"(_norm(al)?|_nrm)\.", re.I),
    "roughness": re.compile(r"(_rough(ness)?|_rgh)\.", re.I),
    "metalness": re.compile(r"(_metal(lic|ness)?|_mtl)\.", re.I),
}
_SKIP = re.compile(r"(_ao|ambient|_height|_disp|_spec|_emissive|_alpha|_mask)\.", re.I)


def _licence(archive: Path) -> dict[str, Any]:
    """Whatever the harvest recorded about where this came from."""
    for candidate in (archive.parent / "source.json", archive.parent.parent / "source.json"):
        if candidate.is_file():
            try:
                return json.loads(candidate.read_text(encoding="utf-8"))
            except (OSError, json.JSONDecodeError):
                pass
    return {}


def discover(root: Path = ROOT, packs: tuple[str, ...] = ("classic64",),
             progress: Any = print) -> list[dict[str, Any]]:
    """Every image in the named packs that looks like a tiling surface.

    Read out of the zips without extracting, the same way the model inventory
    works: 138 packs on disk is several gigabytes and none of it needs to be
    unpacked to be catalogued.
    """
    out: list[dict[str, Any]] = []
    archives = sorted(root.rglob("*.zip"))
    for archive in archives:
        if packs and not any(p in str(archive).lower() for p in packs):
            continue
        try:
            with zipfile.ZipFile(archive) as bundle:
                for info in bundle.infolist():
                    name = info.filename
                    if not name.lower().endswith((".png", ".jpg", ".jpeg")):
                        continue
                    base = Path(name).name
                    if _SKIP.search(base):
                        continue
                    if any(rx.search(base) for rx in _SUFFIX.values()):
                        continue
                    role = classify(base)
                    if not role:
                        continue
                    source = _licence(archive)
                    out.append({
                        "archive": str(archive),
                        "member": name,
                        "stem": Path(name).stem,
                        "role": role,
                        "size": info.file_size,
                        "pack": source.get("pack") or archive.parent.name,
                        "author": source.get("author") or archive.parent.parent.name,
                        "url": source.get("url"),
                        "licence": source.get("licence") or "cc0",
                    })
        except (zipfile.BadZipFile, OSError) as error:
            progress(f"  ! {archive.name}: {error}")
    return out


def classify(filename: str) -> str | None:
    """Which role a texture filename belongs to, or None.

    Prefix matching rather than substring, because a substring rule filed
    `sandcastle` as sand once already in this repository's model classifier and
    the lesson has been paid for three times.
    """
    base = Path(filename).name.lower()
    for role, prefixes in ROLES.items():
        for prefix in prefixes:
            if base.startswith(prefix):
                return role
    return None


def survey(data: bytes) -> dict[str, float] | None:
    """Measure an image, because its filename lies.

    `grass_1`, `grass_4` and `grass_5` in this pack are grass *blades on a
    black background* -- alpha-cut billboard sprites for foliage cards. Painted
    onto a ground plane they read as dark stripes, which is exactly what the
    first textured world in this project looked like. Every one of them is
    named like a surface, and the classifier believed it.

    A surface fills its frame. A cut-out does not. That is measurable in a
    tenth of a second and it is the difference between a ground that looks
    drawn and one that looks broken.

    Returns None when Pillow is unavailable, so the pipeline degrades to
    name-matching rather than refusing to run.
    """
    try:
        import io
        from PIL import Image
    except ImportError:
        return None
    try:
        image = Image.open(io.BytesIO(data)).convert("RGBA")
    except Exception:  # noqa: BLE001 - an unreadable image is not a surface
        return None
    pixels = list(image.getdata())
    count = max(1, len(pixels))
    transparent = sum(1 for p in pixels if p[3] < 40) / count
    black = sum(1 for p in pixels if p[0] + p[1] + p[2] < 42) / count
    luma = sum(0.2126 * p[0] + 0.7152 * p[1] + 0.0722 * p[2] for p in pixels) / count
    return {"transparent": transparent, "black": black, "luma": luma,
            "width": image.width, "height": image.height}


def isSurface(stats: dict[str, float] | None) -> bool:
    """Whether a measured image is a tiling surface rather than a cut-out.

    The thresholds are loose on purpose. A dark stone texture is legitimate; a
    quarter of the frame being pure black or transparent is not, because a
    surface has no holes in it.
    """
    if stats is None:
        return True
    return (stats["transparent"] < 0.20
            and stats["black"] < 0.25
            and stats["luma"] > 40)


def isFoliage(stats: dict[str, float] | None) -> bool:
    """Whether a measured image is a cut-out card rather than a surface.

    This existed as the negation of `isSurface` and the images that failed it
    were thrown away, which was the wrong conclusion drawn from a correct
    measurement. `grass_1` and its siblings are grass blades on a transparent
    or black field -- they are useless as ground and they are exactly what a
    foliage card is: a quad standing in the terrain with the sky showing
    through it.

    So the measurement routes rather than rejects. A filled image is a
    surface; a holed one is a card; both are wanted, for different jobs.
    """
    if stats is None:
        return False
    return (stats["transparent"] >= 0.20 or stats["black"] >= 0.25)         and stats["luma"] > 12


def select(found: list[dict[str, Any]], per_role: int = 3) -> list[dict[str, Any]]:
    """A few per role, smallest first.

    Smallest is right here and wrong for models. A model's file size is detail
    a player sees; a tiling texture's size is resolution, and these are stylised
    surfaces meant to read as drawn. The 1 KB versions are the ones that look
    intentional at two studs per tile.
    """
    by_role: dict[str, list[dict[str, Any]]] = {}
    seen: set[str] = set()
    for item in sorted(found, key=lambda i: (i["role"], i["size"])):
        stem = item["stem"].lower()
        if stem in seen:
            continue
        bucket = by_role.setdefault(item["role"], [])
        if len(bucket) >= per_role:
            continue
        #: Opened and measured, not trusted. Smallest-first is the right order
        #: for a stylised surface and it is also exactly the order that put the
        #: three foliage sprites at the top of the grass list.
        try:
            with zipfile.ZipFile(item["archive"]) as bundle:
                stats = survey(bundle.read(item["member"]))
        except (zipfile.BadZipFile, KeyError, OSError):
            stats = None
        if isSurface(stats):
            item["kind"] = "surface"
        elif isFoliage(stats):
            #: A card, not a floor. Filed under `foliage.` so a world dresser
            #: asks for it deliberately and a ground never picks one up.
            item["kind"] = "foliage"
            item["role"] = "foliage." + item["role"].split(".")[-1]
        else:
            continue
        if stats:
            item["measured"] = stats
        seen.add(stem)
        bucket.append(item)
    out: list[dict[str, Any]] = []
    for role in ROLES:
        out.extend(by_role.get(role, []))
    return out


# ------------------------------------------------------------------ publish
def _multipart(payload: dict[str, Any], filename: str, content: bytes,
               mime: str) -> tuple[bytes, str]:
    boundary = uuid.uuid4().hex
    lines: list[bytes] = []
    lines.append(f"--{boundary}\r\n".encode())
    lines.append(b'Content-Disposition: form-data; name="request"\r\n')
    lines.append(b"Content-Type: application/json\r\n\r\n")
    lines.append(json.dumps(payload).encode() + b"\r\n")
    lines.append(f"--{boundary}\r\n".encode())
    lines.append(
        f'Content-Disposition: form-data; name="fileContent"; filename="{filename}"\r\n'.encode())
    lines.append(f"Content-Type: {mime}\r\n\r\n".encode())
    lines.append(content + b"\r\n")
    lines.append(f"--{boundary}--\r\n".encode())
    return b"".join(lines), boundary


def _post(body: bytes, boundary: str, key: str, timeout: float = 120.0) -> dict[str, Any]:
    request = urllib.request.Request(
        "https://apis.roblox.com/assets/v1/assets", data=body, method="POST",
        headers={"x-api-key": key,
                 "Content-Type": f"multipart/form-data; boundary={boundary}"})
    with urllib.request.urlopen(request, timeout=timeout) as response:
        return json_object_limited(
            response,
            MAX_API_RESPONSE_BYTES,
            label="Roblox texture upload response",
        )


def _await_operation(operation: str, key: str, tries: int = 14,
                     delay: float = 1.6) -> dict[str, Any]:
    if not operation:
        return {}
    url = f"https://apis.roblox.com/assets/v1/operations/{operation}"
    for _ in range(tries):
        try:
            request = urllib.request.Request(url, headers={"x-api-key": key})
            with urllib.request.urlopen(request, timeout=45) as response:
                body = json_object_limited(
                    response,
                    MAX_API_RESPONSE_BYTES,
                    label="Roblox texture operation response",
                )
            if body.get("done"):
                return body
        except (urllib.error.HTTPError, urllib.error.URLError, OSError, HttpBoundaryError):
            pass
        time.sleep(delay)
    return {}


def cutout(data: bytes) -> bytes | None:
    """Turn a black-backed sprite into one with an alpha channel.

    The foliage cards in these packs are grass blades painted on solid black,
    not on transparency -- which is how a sprite sheet from 2003 is drawn and
    how half of itch's CC0 vegetation still ships. Uploaded as-is and applied
    as a Roblox `Texture` they render exactly what they contain: dark
    rectangles standing in the grass.

    Roblox has no colour-key. The alpha has to exist in the file, so it is put
    there here, once, before upload. Luminance drives the alpha rather than an
    exact-black test, because these are compressed and the "black" around a
    blade is a gradient of near-black.

    Returns None when Pillow is unavailable or the image already has usable
    transparency, so nothing is converted twice.
    """
    try:
        import io
        from PIL import Image
    except ImportError:
        return None
    try:
        image = Image.open(io.BytesIO(data)).convert("RGBA")
    except Exception:  # noqa: BLE001
        return None

    pixels = list(image.getdata())
    if sum(1 for p in pixels if p[3] < 40) / max(1, len(pixels)) > 0.15:
        return None  # already cut out

    out = []
    for r, g, b, _ in pixels:
        luma = 0.2126 * r + 0.7152 * g + 0.0722 * b
        #: Fully transparent under 18, fully opaque over 58, and a ramp
        #: between -- which is what keeps a blade's edge from looking cut with
        #: scissors.
        if luma <= 18:
            alpha = 0
        elif luma >= 58:
            alpha = 255
        else:
            alpha = int((luma - 18) / 40 * 255)
        out.append((r, g, b, alpha))
    image.putdata(out)
    buffer = io.BytesIO()
    image.save(buffer, format="PNG")
    return buffer.getvalue()


MODERATED = "user is moderated"


def publish(chosen: list[dict[str, Any]], creator_user_id: str = "5812220258",
            delay: float = DELAY, progress: Any = print) -> dict[str, Any]:
    """Upload each texture as an `Image`. Resumable, and it stops when told to.

    `Image` and not `Decal`, which is the mistake that cost this repository 367
    assets: Open Cloud accepts `Decal`, reports it Approved and Active, and it
    never renders. The ledger is written after every upload rather than at the
    end, because a run that records only on success loses everything it did.
    """
    local_credentials.load()
    key = os.environ.get(local_credentials.ENV_VAR, "")
    if not key:
        raise RuntimeError("no Roblox Open Cloud credential")

    book: dict[str, Any] = {"$comment":
        "CC0 surface textures published as Roblox Image assets. Read by "
        "Forge.Catalog.Textures and turned into MaterialVariants by "
        "Forge.Material.", "assets": {}}
    if PUBLISHED.exists():
        try:
            book = json.loads(PUBLISHED.read_text(encoding="utf-8"))
            book.setdefault("assets", {})
        except (OSError, json.JSONDecodeError):
            pass

    uploaded = failed = skipped = 0
    stopped = False

    def flush() -> None:
        PUBLISHED.parent.mkdir(parents=True, exist_ok=True)
        PUBLISHED.write_text(json.dumps(book, indent=1) + "\n", encoding="utf-8")

    for index, item in enumerate(chosen, start=1):
        if stopped:
            break
        marker = f"{Path(item['archive']).name}::{item['member']}"
        if (book["assets"].get(marker) or {}).get("assetId"):
            skipped += 1
            continue
        try:
            with zipfile.ZipFile(item["archive"]) as bundle:
                content = bundle.read(item["member"])
        except (zipfile.BadZipFile, KeyError, OSError) as error:
            failed += 1
            book["assets"][marker] = {"error": f"unreadable: {error}"[:150]}
            continue

        #: A card gets its alpha cut before it goes up. A surface never does:
        #: the same operation on a floor texture punches holes in the dark
        #: parts of it.
        suffix = Path(item["member"]).suffix.lower()
        if item.get("kind") == "foliage":
            converted = cutout(content)
            if converted:
                content = converted
                suffix = ".png"
        payload = {
            "assetType": "Image",
            "displayName": item["stem"][:48].replace("_", " ").title() or "Texture",
            "description": (f"CC0 public domain. Source: {item['author']}, "
                            f"{item['pack']}. {item.get('url') or ''}").strip()[:900],
            "creationContext": {"creator": {"userId": str(creator_user_id)}},
        }
        body, boundary = _multipart(
            payload, Path(item["member"]).name, content,
            "image/png" if suffix == ".png" else "image/jpeg")

        state: dict[str, Any] | None = None
        wait = delay
        for _ in range(4):
            try:
                state = _post(body, boundary, key)
                break
            except urllib.error.HTTPError as error:
                if error.code == 429:
                    wait *= 2
                    progress(f"  throttled; waiting {wait:.0f}s")
                    time.sleep(wait)
                    continue
                text = error_body_limited(error, 200).decode("utf-8", "replace")
                book["assets"][marker] = {"error": f"HTTP {error.code}: {text[:120]}"}
                #: An account-level stop, not a failure of this file. Walking
                #: the rest collects the same answer hundreds of times and
                #: deepens whatever triggered it.
                if MODERATED in text.lower():
                    progress("  ! the account is moderated for uploads; stopping")
                    stopped = True
                break
            except (urllib.error.URLError, OSError, HttpBoundaryError) as error:
                book["assets"][marker] = {"error": str(error)[:150]}
                break

        if not state:
            failed += 1
            flush()
            time.sleep(delay)
            continue

        resolved = _await_operation(state.get("operationId", ""), key)
        asset = resolved.get("response") or {}
        asset_id = asset.get("assetId")
        if asset_id:
            uploaded += 1
            book["assets"][marker] = {
                "assetId": asset_id, "role": item["role"], "stem": item["stem"],
                "kind": item.get("kind") or "surface",
                "displayName": asset.get("displayName"),
                "moderation": (asset.get("moderationResult") or {}).get("moderationState"),
                "pack": item["pack"], "author": item["author"],
                "licence": item["licence"],
            }
        else:
            failed += 1
            book["assets"][marker] = {"error": "never resolved", "role": item["role"]}
        flush()
        if index % 10 == 0:
            progress(f"  {index}/{len(chosen)}  {uploaded} up, {failed} failed")
        time.sleep(delay)

    flush()
    return {"uploaded": uploaded, "failed": failed, "skipped": skipped,
            "stopped": stopped}


# ------------------------------------------------------------------- export
def _lua(value: Any) -> str:
    if isinstance(value, str):
        return '"' + value.replace("\\", "\\\\").replace('"', '\\"') + '"'
    if isinstance(value, bool):
        return "true" if value else "false"
    return str(value)


def export_lua(published: Path | None = None) -> tuple[Path, int]:
    """Write the published textures as a Luau module a game can read."""
    source = Path(published) if published else PUBLISHED
    book = json.loads(source.read_text(encoding="utf-8"))
    live = [v for v in (book.get("assets") or {}).values() if v.get("assetId")]
    live.sort(key=lambda e: (e.get("role") or "", str(e["assetId"])))

    rows = []
    for entry in live:
        rows.append("	{ id = %s, role = %s, kind = %s, name = %s, pack = %s, author = %s },"
                    % (_lua(int(entry["assetId"])), _lua(entry.get("role") or ""),
                       _lua(entry.get("kind") or "surface"),
                       _lua(entry.get("stem") or ""), _lua(entry.get("pack") or ""),
                       _lua(entry.get("author") or "")))

    body = '''--!strict
--[[
	Textures — CC0 surface art published to this account, keyed by what it is
	for.

	Generated by `rqe.assets.itch_textures`; rewritten on every export. Do not
	edit.

	These are `Image` assets, not Decals. The distinction is not cosmetic and
	cost this repository 367 assets once: Open Cloud accepts `Decal`, reports it
	Approved and Active, and it never renders anywhere.

	What to do with one
	-------------------

	Hand the id to `Forge.Material.define` and get a `MaterialVariant`, then set
	a part's `Material` and `MaterialVariant` name. That tiles by studs and
	takes the engine's lighting. Painting it on as a `Texture` instead stretches
	one image over a face and reads as a sticker the moment the part is not
	square.

		local Textures = Forge.Catalog.Textures
		local grass = Textures.pick("ground.grass", 7)
		Forge.Material.define("MeadowGrass", {
			base = Enum.Material.Grass, colorMap = grass.id, studsPerTile = 4,
		})
]]

local Textures = {}

export type Entry = {
	id: number, role: string, kind: string, name: string, pack: string,
	author: string,
}

Textures.entries = ({
%s
} :: any) :: { Entry }

local byRole: { [string]: { Entry } } = {}
for _, entry in Textures.entries do
	local bucket = byRole[entry.role]
	if not bucket then
		bucket = {}
		byRole[entry.role] = bucket
	end
	table.insert(bucket, entry)
end

function Textures.byRole(role: string): { Entry }
	return byRole[role] or {}
end

function Textures.roles(): { string }
	local out = {}
	for role in byRole do
		table.insert(out, role)
	end
	table.sort(out)
	return out
end

--[[
	One texture for a role, chosen by a seed.

	Seeded rather than random so a world generated twice is the same world --
	the thing that makes a layout something you can author against instead of
	something you re-roll until it looks right.
]]
function Textures.pick(role: string, seed: number): Entry?
	local bucket = byRole[role]
	if not bucket or #bucket == 0 then
		return nil
	end
	return bucket[(math.floor(math.abs(seed)) %% #bucket) + 1]
end

--: The first of a role, for a caller that wants the same surface every time.
function Textures.first(role: string): Entry?
	local bucket = byRole[role]
	return if bucket then bucket[1] else nil
end

function Textures.describe(): { [string]: any }
	local counts: { [string]: number } = {}
	for role, bucket in byRole do
		counts[role] = #bucket
	end
	return { total = #Textures.entries, roles = counts }
end

return Textures
''' % "\n".join(rows)

    CATALOGUE.parent.mkdir(parents=True, exist_ok=True)
    CATALOGUE.write_text(body, encoding="utf-8")
    return CATALOGUE, len(live)
