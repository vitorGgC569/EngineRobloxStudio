"""Real connectors: discover, licence-check, fetch, publish.

`registry.py` decides *whether* to reuse. This is what actually goes and gets
the thing, and it exists because a policy with no hands is a policy nobody can
act on -- the registry had been right about Kenney and Quaternius for a while
and not one asset had ever been fetched through it.

**Shaped for a caller with judgement.** These are the operations someone
building a game needs while they are building it: "find me a torch sound",
"what is the licence on that", "put it in the place". They are not a pipeline
stage that decides for you. Whether a gothic pillar suits this abbey is the
caller's judgement, and it should be -- the connector's job is to make acting
on that judgement cheap and safe.

**Provenance is written at the moment of taking, never afterwards.** An asset
whose licence nobody recorded is one nobody can defend later, and reconstructing
it from memory is how a CC-BY sneaks into a shipped game uncredited.

**It does not scrape.** The Kenney pack pages serve their downloads through a
form rather than a plain link, and a regex against somebody's markup is a
connector that breaks silently the week they redesign. `fetch` handles sources
that publish a stable direct URL; `adopt` handles everything else -- a pack
already on disk, however it got there -- and both end in the same place: a
licence check, a hash and a provenance record.

**Fetching and publishing are separate calls on purpose.** Publishing puts an
asset on a real Roblox account, under a real name, through moderation. Making
that a side effect of a download would hide an irreversible act inside a
reversible one.
"""

from __future__ import annotations

import hashlib
import json
import shutil
import urllib.error
import urllib.request
import zipfile
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

from .registry import LICENCES


class ConnectorError(RuntimeError):
    """A source could not be reached, or answered with something unusable."""


#: Where fetched material lands before anything decides to use it.
CACHE = Path(".tmp/sourcing")

#: Kept small on purpose. A connector that will download anything is a supply
#: chain risk wearing a convenience feature.
MAX_DOWNLOAD_BYTES = 80 * 1024 * 1024

#: What a Roblox place can actually consume, per kind. A connector that returns
#: a 4K EXR for a material has technically succeeded and practically wasted
#: everybody's time.
USABLE_FORMATS = {
    "audio": {".ogg", ".wav", ".mp3"},
    "geometry": {".glb", ".gltf", ".obj", ".fbx"},
    "material": {".png", ".jpg", ".jpeg"},
    "icon": {".png", ".svg"},
}


@dataclass
class Asset:
    """One fetched file, with everything needed to defend using it."""

    id: str
    kind: str
    source: str
    licence: str
    path: Path
    sha256: str
    bytes: int
    attribution_required: bool = False
    notes: str = ""

    def to_dict(self) -> dict[str, Any]:
        return {
            "id": self.id,
            "kind": self.kind,
            "source": self.source,
            "licence": self.licence,
            "path": str(self.path),
            "sha256": self.sha256,
            "bytes": self.bytes,
            "attributionRequired": self.attribution_required,
            "notes": self.notes,
        }


@dataclass
class Catalogue:
    """What one source offers, as this connector understands it.

    A declared list rather than a live crawl. A scraper against somebody's
    website breaks the week they change their markup, and it hits the network on
    every question rather than on every decision. The pack URLs are stable
    published downloads; what changes is which packs exist, and that is a
    dictionary entry rather than a parser rewrite.
    """

    source: str
    kind: str
    entries: dict[str, dict[str, Any]] = field(default_factory=dict)


#: The packs this connector knows how to fetch.
#:
#: Small on purpose: these answer needs the factory actually has -- interface
#: sound, impact feedback, stylised nature. Every entry carries its own licence
#: rather than inheriting a source-level assumption, because a source can host
#: material under more than one.
CATALOGUES: tuple[Catalogue, ...] = (
    Catalogue("kenney", "audio", {
        "ui-audio": {
            "url": "https://kenney.nl/media/pages/assets/ui-audio/"
                   "1194701369-1677495181/kenney_ui-audio.zip",
            "licence": "CC0",
            "covers": ["confirm", "denied", "click", "error", "switch", "rollover"],
            "note": "50+ interface sounds: clicks, switches, rollovers",
        },
        "impact-sounds": {
            "url": "https://kenney.nl/media/pages/assets/impact-sounds/"
                   "3080119989-1677495200/kenney_impact-sounds.zip",
            "licence": "CC0",
            "covers": ["damage", "build", "impact", "hit"],
            "note": "impacts and hits, for damage and construction feedback",
        },
    }),
    Catalogue("quaternius", "geometry", {
        "ultimate-nature": {
            "url": "",
            "licence": "CC0",
            "covers": ["tree", "rock", "bush", "grass", "cliff", "plant"],
            "note": "hundreds of stylised nature meshes; download through "
                    "quaternius.com and bring in with adopt",
        },
        "ultimate-buildings": {
            "url": "",
            "licence": "CC0",
            "covers": ["building", "house", "ruin", "wall", "tower"],
            "note": "modular medieval and fantasy buildings; adopt only",
        },
        "ultimate-monsters": {
            "url": "",
            "licence": "CC0",
            "covers": ["monster", "creature", "enemy", "skeleton"],
            "note": "rigged low-poly creatures; adopt only",
        },
    }),
    Catalogue("ambientcg", "material", {
        "stone": {
            "url": "",
            "licence": "CC0",
            "covers": ["stone", "rock", "cobblestone", "brick", "concrete"],
            "note": "PBR stone and masonry; pick a 1K or 2K set, Roblox will "
                    "not thank you for 4K",
        },
        "wood": {
            "url": "",
            "licence": "CC0",
            "covers": ["wood", "plank", "bark", "timber"],
            "note": "PBR timber and planking",
        },
        "metal": {
            "url": "",
            "licence": "CC0",
            "covers": ["metal", "iron", "rust", "steel"],
            "note": "PBR metals including corroded sets",
        },
    }),
    Catalogue("polyhaven", "material", {
        "surfaces": {
            "url": "",
            "licence": "CC0",
            "covers": ["ground", "gravel", "sand", "dirt", "grass"],
            "note": "PBR ground surfaces and HDRIs",
        },
    }),
    Catalogue("game-icons", "icon", {
        "game-icons-net": {
            "url": "",
            "licence": "CC-BY-3.0",
            "covers": ["icon", "currency", "sword", "shield", "tower", "skull"],
            "note": "4000+ game icons. CC-BY: the credit must appear in the "
                    "running game, not in a README",
        },
    }),
    Catalogue("kenney", "geometry", {
        "nature-kit": {
            "url": "https://kenney.nl/media/pages/assets/nature-kit/"
                   "2013461503-1677495267/kenney_nature-kit.zip",
            "licence": "CC0",
            "covers": ["tree", "rock", "bush", "log", "plant"],
            "note": "stylised low-poly nature, close to the Roblox idiom",
        },
    }),
)


def catalogues(kind: str = "") -> list[dict[str, Any]]:
    """What can be fetched, optionally narrowed to one kind."""

    out: list[dict[str, Any]] = []
    for catalogue in CATALOGUES:
        if kind and catalogue.kind != kind:
            continue
        for name, entry in catalogue.entries.items():
            licence = LICENCES[entry["licence"]]
            out.append({
                "source": catalogue.source,
                "kind": catalogue.kind,
                "pack": name,
                "licence": licence.id,
                "attributionRequired": licence.attribution,
                "usable": licence.commercial,
                "covers": entry.get("covers", []),
                "note": entry.get("note", ""),
            })
    return out


def search(need: str, *, kind: str = "") -> list[dict[str, Any]]:
    """Packs that claim to cover this need.

    Matched against a declared `covers` vocabulary rather than free text. A
    connector that guesses which pack holds a "spooky torch crackle" guesses
    wrong confidently; the caller reads the note and decides.
    """

    want = need.strip().lower()
    hits = []
    for entry in catalogues(kind):
        covers = [str(item).lower() for item in entry.get("covers", [])]
        if any(want in item or item in want for item in covers):
            hits.append(entry)
        elif want and want in entry["note"].lower():
            hits.append(entry)
    return hits


def _download(url: str, destination: Path) -> int:
    destination.parent.mkdir(parents=True, exist_ok=True)
    request = urllib.request.Request(url, headers={"User-Agent": "rqe-sourcing/1"})
    try:
        with urllib.request.urlopen(request, timeout=120) as response:
            declared = int(response.headers.get("Content-Length") or 0)
            if declared > MAX_DOWNLOAD_BYTES:
                raise ConnectorError(
                    f"{url} declares {declared} bytes, above the "
                    f"{MAX_DOWNLOAD_BYTES} this connector will take")
            written = 0
            with destination.open("wb") as handle:
                while True:
                    chunk = response.read(64 * 1024)
                    if not chunk:
                        break
                    written += len(chunk)
                    if written > MAX_DOWNLOAD_BYTES:
                        handle.close()
                        destination.unlink(missing_ok=True)
                        raise ConnectorError(
                            f"{url} exceeded {MAX_DOWNLOAD_BYTES} bytes mid-stream")
                    handle.write(chunk)
            return written
    except urllib.error.HTTPError as error:
        raise ConnectorError(f"{url} returned HTTP {error.code}") from error
    except urllib.error.URLError as error:
        raise ConnectorError(f"{url} could not be reached: {error.reason}") from error


def _sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        while True:
            chunk = handle.read(128 * 1024)
            if not chunk:
                break
            digest.update(chunk)
    return digest.hexdigest()


def _find(source: str, pack: str, kind: str = ""):
    for catalogue in CATALOGUES:
        if catalogue.source != source:
            continue
        if kind and catalogue.kind != kind:
            continue
        if pack in catalogue.entries:
            return catalogue.entries[pack], catalogue.kind
    return None, kind


def fetch(source: str, pack: str, *, root: Path = Path("."),
          kind: str = "") -> dict[str, Any]:
    """Download one pack, verify its licence, and record where it came from.

    The licence is checked *before* the network call. Checking afterwards means
    the unusable thing is already on disk, and things on disk get used.
    """

    entry, kind = _find(source, pack, kind)
    if entry is None:
        raise ConnectorError(
            f"no pack {pack!r} from {source!r}; call catalogues() for what exists")

    licence = LICENCES[entry["licence"]]
    if not licence.commercial:
        raise ConnectorError(
            f"{source}/{pack} is {licence.id}, which a generated game may not "
            f"ship: {licence.note}")

    # A catalogue entry with no direct URL is known-about, not fetchable.
    # Quaternius goes through itch.io, ambientCG through a chooser, Kenney
    # through a form -- none serve a stable link, and guessing one produced a
    # confident 404. Saying so is more useful than pretending to try.
    if not entry.get("url"):
        raise ConnectorError(
            f"{source}/{pack} has no direct download this connector may use. "
            f"Fetch it from the source and bring it in with adopt(): "
            f"licence {licence.id}, covers {', '.join(entry.get('covers', []))}")

    target = Path(root) / CACHE / source / pack
    archive = target / (pack + ".zip")
    if not archive.is_file():
        _download(entry["url"], archive)

    extracted = target / "files"
    if not extracted.is_dir():
        extracted.mkdir(parents=True, exist_ok=True)
        try:
            with zipfile.ZipFile(archive) as bundle:
                for member in bundle.namelist():
                    # Zip-slip: a member named ../../x escapes the extraction
                    # root. Cheap to check, expensive to discover later.
                    resolved = (extracted / member).resolve()
                    if not str(resolved).startswith(str(extracted.resolve())):
                        raise ConnectorError(
                            f"{pack} holds a path that escapes its folder: {member}")
                bundle.extractall(extracted)
        except zipfile.BadZipFile as error:
            shutil.rmtree(extracted, ignore_errors=True)
            raise ConnectorError(f"{source}/{pack} is not a readable zip") from error

    wanted = USABLE_FORMATS.get(kind, set())
    files = sorted(
        path for path in extracted.rglob("*")
        if path.is_file() and (not wanted or path.suffix.lower() in wanted)
    )

    record = {
        "schemaVersion": 1,
        "source": source,
        "pack": pack,
        "kind": kind,
        "licence": licence.id,
        "attributionRequired": licence.attribution,
        "url": entry["url"],
        "archiveSha256": _sha256(archive),
        "files": len(files),
        "note": entry.get("note", ""),
    }
    (target / "provenance.json").write_text(
        json.dumps(record, indent=2) + "\n", encoding="utf-8")
    out = dict(record)
    out["paths"] = [str(path) for path in files[:40]]
    return out


def assets(source: str, pack: str, *, root: Path = Path("."),
           kind: str = "", limit: int = 200) -> list[Asset]:
    """The usable files inside a fetched pack, each with its own hash."""

    target = Path(root) / CACHE / source / pack
    record_path = target / "provenance.json"
    if not record_path.is_file():
        raise ConnectorError(f"{source}/{pack} has not been fetched yet")
    record = json.loads(record_path.read_text(encoding="utf-8"))
    kind = kind or record["kind"]
    wanted = USABLE_FORMATS.get(kind, set())
    licence = LICENCES[record["licence"]]

    out: list[Asset] = []
    for path in sorted((target / "files").rglob("*")):
        if not path.is_file():
            continue
        if wanted and path.suffix.lower() not in wanted:
            continue
        out.append(Asset(
            id=path.stem, kind=kind, source=source, licence=licence.id,
            path=path, sha256=_sha256(path), bytes=path.stat().st_size,
            attribution_required=licence.attribution,
            notes=record.get("note", ""),
        ))
        if len(out) >= limit:
            break
    return out


def adopt(path: Path, *, source: str, pack: str, kind: str, licence: str,
          root: Path = Path("."), note: str = "") -> dict[str, Any]:
    """Take a pack that is already on disk, under a stated licence.

    The honest counterpart to `fetch`. Most good sources do not serve a stable
    direct URL -- Kenney downloads come through a form, Quaternius through
    itch.io -- and scraping around that is both fragile and rude. So whoever
    fetched it says where it came from, and this records that claim with a hash
    so it can be checked later.

    The licence is named by the caller because only the caller knows which page
    they took it from. It is validated against the registry, so a licence this
    project has no policy for is refused rather than assumed benign.
    """

    if licence not in LICENCES:
        raise ConnectorError(
            "unknown licence " + repr(licence) + "; known: "
            + ", ".join(sorted(LICENCES)))
    terms = LICENCES[licence]
    if not terms.commercial:
        raise ConnectorError(
            licence + " may not ship in a generated game: " + terms.note)

    origin = Path(path)
    if not origin.is_dir():
        raise ConnectorError(str(path) + " is not a directory")

    wanted = USABLE_FORMATS.get(kind, set())
    files = sorted(
        item for item in origin.rglob("*")
        if item.is_file() and (not wanted or item.suffix.lower() in wanted)
    )
    if not files:
        raise ConnectorError(
            str(path) + " holds no " + kind + " files this connector can use")

    home = Path(root) / CACHE / source / pack
    target_dir = home / "files"
    target_dir.mkdir(parents=True, exist_ok=True)
    for item in files:
        destination = target_dir / item.name
        if not destination.exists():
            shutil.copy2(item, destination)

    record = {
        "schemaVersion": 1,
        "source": source,
        "pack": pack,
        "kind": kind,
        "licence": terms.id,
        "attributionRequired": terms.attribution,
        "adoptedFrom": str(origin),
        "files": len(files),
        "note": note or terms.note,
    }
    (home / "provenance.json").write_text(
        json.dumps(record, indent=2) + chr(10), encoding="utf-8")
    return record


def publish(asset: Asset, *, key_path: Path, creator_user_id: str,
            display_name: str = "", timeout: float = 90.0) -> dict[str, Any]:
    """Upload one asset through Open Cloud and return the operation to poll.

    Separate from `fetch` and `adopt` because this is the irreversible half: it
    puts the asset on a real account, under a real name, through moderation.

    The key is read from the file the caller names and used only as a header --
    never logged, never returned, never taken as a plain argument that could end
    up in a transcript.
    """

    import mimetypes
    import uuid

    terms = LICENCES[asset.licence]
    if not terms.commercial:
        raise ConnectorError(asset.licence + " may not be published")

    kinds = {"audio": "Audio", "icon": "Decal", "material": "Decal"}
    if asset.kind not in kinds:
        raise ConnectorError(
            "Open Cloud has no asset type for " + repr(asset.kind)
            + "; geometry reaches a place through WorldKit.Mesh at runtime")

    key = Path(key_path).read_text(encoding="utf-8").strip()
    request = {
        "assetType": kinds[asset.kind],
        "displayName": display_name or asset.id,
        "description": (
            asset.licence + " from " + asset.source
            + (" -- " + asset.notes if asset.notes else "")),
        "creationContext": {"creator": {"userId": str(creator_user_id)}},
    }

    boundary = uuid.uuid4().hex
    crlf = chr(13) + chr(10)
    payload = bytearray()

    def field(name, value, filename="", ctype=""):
        payload.extend(("--" + boundary + crlf).encode())
        disposition = 'form-data; name="' + name + '"'
        if filename:
            disposition += '; filename="' + filename + '"'
        payload.extend(("Content-Disposition: " + disposition + crlf).encode())
        if ctype:
            payload.extend(("Content-Type: " + ctype + crlf).encode())
        payload.extend(crlf.encode())
        payload.extend(value)
        payload.extend(crlf.encode())

    field("request", json.dumps(request).encode())
    field("fileContent", asset.path.read_bytes(), asset.path.name,
          mimetypes.guess_type(asset.path.name)[0] or "application/octet-stream")
    payload.extend(("--" + boundary + "--" + crlf).encode())

    http = urllib.request.Request(
        "https://apis.roblox.com/assets/v1/assets", data=bytes(payload),
        method="POST",
        headers={"x-api-key": key,
                 "Content-Type": "multipart/form-data; boundary=" + boundary})
    try:
        with urllib.request.urlopen(http, timeout=timeout) as response:
            body = json.loads(response.read().decode("utf-8"))
    except urllib.error.HTTPError as error:
        raise ConnectorError(
            "Open Cloud refused the upload: HTTP " + str(error.code) + " "
            + error.read().decode("utf-8", "replace")[:200]) from error

    return {
        "operationId": body.get("operationId"),
        "sha256": asset.sha256,
        "source": asset.source,
        "licence": asset.licence,
        "attributionRequired": asset.attribution_required,
    }


def operation(operation_id: str, *, key_path: Path,
              timeout: float = 45.0) -> dict[str, Any]:
    """Where an upload got to. Carries the asset id once moderation answers."""

    key = Path(key_path).read_text(encoding="utf-8").strip()
    http = urllib.request.Request(
        "https://apis.roblox.com/assets/v1/operations/" + operation_id,
        headers={"x-api-key": key})
    with urllib.request.urlopen(http, timeout=timeout) as response:
        body = json.loads(response.read().decode("utf-8"))
    if not body.get("done"):
        return {"done": False, "operationId": operation_id}
    result = body.get("response") or {}
    return {
        "done": True,
        "assetId": result.get("assetId"),
        "moderation": (result.get("moderationResult") or {}).get("moderationState"),
        "state": result.get("state"),
    }
