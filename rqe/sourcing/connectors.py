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
import os
import shutil
import urllib.error
import urllib.request
import zipfile
from dataclasses import dataclass, field
from pathlib import Path, PurePosixPath
import re
from typing import Any

from .registry import LICENCES
from ..http_safety import error_body_limited


class ConnectorError(RuntimeError):
    """A source could not be reached, or answered with something unusable."""


#: Where fetched material lands before anything decides to use it.
CACHE = Path(".tmp/sourcing")

#: Kept small on purpose. A connector that will download anything is a supply
#: chain risk wearing a convenience feature.
MAX_DOWNLOAD_BYTES = 80 * 1024 * 1024
MAX_EXTRACTED_BYTES = 320 * 1024 * 1024
MAX_ARCHIVE_MEMBERS = 10_000
MAX_API_RESPONSE_BYTES = 2 * 1024 * 1024
MAX_ASSET_UPLOAD_BYTES = 50 * 1024 * 1024
SAFE_IDENTIFIER = re.compile(r"^[a-z0-9][a-z0-9._-]{0,79}$")

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
                   "490d233f68-1677590494/kenney_ui-audio.zip",
            "sha256": "946fc23a63d535d693eb31b2eabb80c8c28d6351e2186b344ceb71b2cb1d5eb6",
            "bytes": 411949,
            "licence": "CC0",
            "covers": ["confirm", "denied", "click", "error", "switch", "rollover"],
            "note": "50+ interface sounds: clicks, switches, rollovers",
        },
        "impact-sounds": {
            "url": "https://kenney.nl/media/pages/assets/impact-sounds/"
                   "87b4ddecda-1677589768/kenney_impact-sounds.zip",
            "sha256": "029d734af1582474edf3a694d1b0cebc97c1c152f2f39fa34d4c2bafc5de77f8",
            "bytes": 800850,
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
                   "37ac38a37b-1677698939/kenney_nature-kit.zip",
            "sha256": "fa7974a0d342bfe63c38664ba9f8ec1a4aab8ea25f099bdc56870e33588c4d9d",
            "bytes": 10537521,
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
                "fetchable": bool(entry.get("url")),
                "integrityPinned": bool(entry.get("sha256") and entry.get("bytes")),
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
    temporary = destination.with_name(destination.name + f".{os.getpid()}.part")
    temporary.unlink(missing_ok=True)
    request = urllib.request.Request(url, headers={"User-Agent": "rqe-sourcing/1"})
    try:
        with urllib.request.urlopen(request, timeout=120) as response:
            declared = int(response.headers.get("Content-Length") or 0)
            if declared > MAX_DOWNLOAD_BYTES:
                raise ConnectorError(
                    f"{url} declares {declared} bytes, above the "
                    f"{MAX_DOWNLOAD_BYTES} this connector will take")
            written = 0
            with temporary.open("xb") as handle:
                while True:
                    chunk = response.read(64 * 1024)
                    if not chunk:
                        break
                    written += len(chunk)
                    if written > MAX_DOWNLOAD_BYTES:
                        handle.close()
                        temporary.unlink(missing_ok=True)
                        raise ConnectorError(
                            f"{url} exceeded {MAX_DOWNLOAD_BYTES} bytes mid-stream")
                    handle.write(chunk)
            os.replace(temporary, destination)
            return written
    except urllib.error.HTTPError as error:
        raise ConnectorError(f"{url} returned HTTP {error.code}") from error
    except urllib.error.URLError as error:
        raise ConnectorError(f"{url} could not be reached: {error.reason}") from error
    finally:
        temporary.unlink(missing_ok=True)


def _sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        while True:
            chunk = handle.read(128 * 1024)
            if not chunk:
                break
            digest.update(chunk)
    return digest.hexdigest()


def _identifier(value: str, label: str) -> str:
    candidate = str(value or "").strip().lower()
    if SAFE_IDENTIFIER.fullmatch(candidate) is None or ".." in candidate:
        raise ConnectorError(f"{label} must be a safe 1-80 character identifier")
    return candidate


def _extract_archive(archive: Path, destination: Path, label: str) -> None:
    """Extract a bounded zip without trusting names, links or declared sizes."""

    try:
        with zipfile.ZipFile(archive) as bundle:
            members = bundle.infolist()
            if len(members) > MAX_ARCHIVE_MEMBERS:
                raise ConnectorError(
                    f"{label} contains {len(members)} entries; limit is {MAX_ARCHIVE_MEMBERS}"
                )
            declared_total = sum(max(0, item.file_size) for item in members)
            if declared_total > MAX_EXTRACTED_BYTES:
                raise ConnectorError(
                    f"{label} declares {declared_total} extracted bytes; limit is {MAX_EXTRACTED_BYTES}"
                )
            destination_root = destination.resolve()
            seen: set[Path] = set()
            written_total = 0
            for member in members:
                portable = PurePosixPath(member.filename.replace("\\", "/"))
                if portable.is_absolute() or not portable.parts or any(
                    part in {"", ".", ".."} or ":" in part for part in portable.parts
                ):
                    raise ConnectorError(f"{label} contains an unsafe path: {member.filename}")
                # Unix mode 0120000 denotes a symbolic link. Links are never
                # needed in an asset bundle and make containment time-dependent.
                if ((member.external_attr >> 16) & 0o170000) == 0o120000:
                    raise ConnectorError(f"{label} contains a symbolic link: {member.filename}")
                target = (destination_root / Path(*portable.parts)).resolve()
                try:
                    target.relative_to(destination_root)
                except ValueError as exc:
                    raise ConnectorError(
                        f"{label} contains a path that escapes extraction: {member.filename}"
                    ) from exc
                if target in seen:
                    raise ConnectorError(f"{label} contains a duplicate path: {member.filename}")
                seen.add(target)
                if member.is_dir():
                    target.mkdir(parents=True, exist_ok=True)
                    continue
                target.parent.mkdir(parents=True, exist_ok=True)
                with bundle.open(member) as source, target.open("xb") as output:
                    while chunk := source.read(64 * 1024):
                        written_total += len(chunk)
                        if written_total > MAX_EXTRACTED_BYTES:
                            raise ConnectorError(
                                f"{label} exceeded {MAX_EXTRACTED_BYTES} extracted bytes"
                            )
                        output.write(chunk)
    except (zipfile.BadZipFile, RuntimeError, OSError) as exc:
        if isinstance(exc, ConnectorError):
            raise
        raise ConnectorError(f"{label} is not a safe readable zip") from exc


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

    source = _identifier(source, "source")
    pack = _identifier(pack, "pack")
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
    expected_hash = str(entry.get("sha256") or "").lower()
    expected_bytes = entry.get("bytes")
    if not re.fullmatch(r"[0-9a-f]{64}", expected_hash) or not isinstance(expected_bytes, int):
        raise ConnectorError(
            f"{source}/{pack} has no pinned checksum and byte size; direct fetch is disabled"
        )

    target = Path(root) / CACHE / source / pack
    archive = target / (pack + ".zip")
    if not archive.is_file():
        _download(entry["url"], archive)
    actual_hash = _sha256(archive)
    actual_bytes = archive.stat().st_size
    if actual_hash != expected_hash or actual_bytes != expected_bytes:
        archive.unlink(missing_ok=True)
        raise ConnectorError(
            f"{source}/{pack} failed integrity verification "
            f"(sha256 {actual_hash}, bytes {actual_bytes})"
        )

    extracted = target / "files"
    if not extracted.is_dir():
        extracted.mkdir(parents=True, exist_ok=True)
        try:
            _extract_archive(archive, extracted, f"{source}/{pack}")
        except (ConnectorError, OSError) as error:
            shutil.rmtree(extracted, ignore_errors=True)
            if isinstance(error, ConnectorError):
                raise
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
        "archiveSha256": actual_hash,
        "archiveBytes": actual_bytes,
        "integrityVerified": True,
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

    source = _identifier(source, "source")
    pack = _identifier(pack, "pack")
    target = Path(root).resolve() / CACHE / source / pack
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

    source = _identifier(source, "source")
    pack = _identifier(pack, "pack")
    if kind not in USABLE_FORMATS:
        raise ConnectorError(f"unsupported asset kind: {kind}")
    if licence not in LICENCES:
        raise ConnectorError(
            "unknown licence " + repr(licence) + "; known: "
            + ", ".join(sorted(LICENCES)))
    terms = LICENCES[licence]
    if not terms.commercial:
        raise ConnectorError(
            licence + " may not ship in a generated game: " + terms.note)

    origin = Path(path).resolve()
    if not origin.is_dir():
        raise ConnectorError(str(path) + " is not a directory")

    wanted = USABLE_FORMATS.get(kind, set())
    files = sorted(
        item for item in origin.rglob("*")
        if item.is_file() and not item.is_symlink()
        and (not wanted or item.suffix.lower() in wanted)
    )
    if not files:
        raise ConnectorError(
            str(path) + " holds no " + kind + " files this connector can use")

    total_bytes = sum(item.stat().st_size for item in files)
    if len(files) > MAX_ARCHIVE_MEMBERS or total_bytes > MAX_EXTRACTED_BYTES:
        raise ConnectorError(
            f"adopted pack exceeds limits: {len(files)} files, {total_bytes} bytes"
        )
    home = Path(root).resolve() / CACHE / source / pack
    target_dir = home / "files"
    target_dir.mkdir(parents=True, exist_ok=True)
    for item in files:
        relative = item.resolve().relative_to(origin)
        destination = target_dir / relative
        destination.parent.mkdir(parents=True, exist_ok=True)
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


def publish(asset: Asset, *, api_key: str, creator_user_id: str,
            display_name: str = "", timeout: float = 90.0) -> dict[str, Any]:
    """Upload one asset through Open Cloud and return the operation to poll.

    Separate from `fetch` and `adopt` because this is the irreversible half: it
    puts the asset on a real account, under a real name, through moderation.

    The key is supplied by the internal credential loader and used only as a
    header. Agent-facing tools never accept a key or a key-file path.
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

    key = str(api_key or "").strip()
    if not key:
        raise ConnectorError("ROBLOX_OPEN_CLOUD_KEY is not configured")
    if asset.bytes > MAX_ASSET_UPLOAD_BYTES or asset.path.stat().st_size > MAX_ASSET_UPLOAD_BYTES:
        raise ConnectorError(f"asset exceeds the {MAX_ASSET_UPLOAD_BYTES}-byte upload limit")
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
            raw = response.read(MAX_API_RESPONSE_BYTES + 1)
            if len(raw) > MAX_API_RESPONSE_BYTES:
                raise ConnectorError("Open Cloud upload response exceeded the byte limit")
            body = json.loads(raw.decode("utf-8"))
    except urllib.error.HTTPError as error:
        raise ConnectorError(
            "Open Cloud refused the upload: HTTP " + str(error.code) + " "
            + error_body_limited(error, 200).decode("utf-8", "replace")) from error

    return {
        "operationId": body.get("operationId"),
        "sha256": asset.sha256,
        "source": asset.source,
        "licence": asset.licence,
        "attributionRequired": asset.attribution_required,
    }


def operation(operation_id: str, *, api_key: str,
              timeout: float = 45.0) -> dict[str, Any]:
    """Where an upload got to. Carries the asset id once moderation answers."""

    key = str(api_key or "").strip()
    if not key:
        raise ConnectorError("ROBLOX_OPEN_CLOUD_KEY is not configured")
    if re.fullmatch(r"[A-Za-z0-9_-]{1,200}", operation_id) is None:
        raise ConnectorError("operation id contains unsupported characters")
    http = urllib.request.Request(
        "https://apis.roblox.com/assets/v1/operations/" + operation_id,
        headers={"x-api-key": key})
    with urllib.request.urlopen(http, timeout=timeout) as response:
        raw = response.read(MAX_API_RESPONSE_BYTES + 1)
        if len(raw) > MAX_API_RESPONSE_BYTES:
            raise ConnectorError("Open Cloud operation response exceeded the byte limit")
        body = json.loads(raw.decode("utf-8"))
    if not body.get("done"):
        return {"done": False, "operationId": operation_id}
    result = body.get("response") or {}
    return {
        "done": True,
        "assetId": result.get("assetId"),
        "moderation": (result.get("moderationResult") or {}).get("moderationState"),
        "state": result.get("state"),
    }
