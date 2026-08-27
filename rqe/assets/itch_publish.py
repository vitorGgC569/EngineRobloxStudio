"""Turn downloaded packs into published Roblox Models, with provenance intact.

The chain, all of it measured
-----------------------------

A pack arrives as a zip of `.fbx`, `.obj`, `.gltf` and textures. Roblox's Open
Cloud takes an `.fbx` directly as a `Model` asset -- no Blender step, no
conversion -- and returns an operation that resolves to an asset id. Proven end
to end before this file existed: a KayKit crossbow arrow went up as asset
72662153380213, moderation Approved.

So the work here is not conversion. It is choosing, pacing, and remembering.

Choosing
--------

A single pack holds seventy meshes; three hundred and sixty hold something like
twenty-five thousand. Most of that is variants -- the same crate in four
colours, the same tree at three levels of detail. Publishing all of it costs
fourteen hours and fills an account with near-duplicates nobody can search.

`select` takes the best few per topic, using the same topic vocabulary the
store sweep uses, and skips things that look like variants of something already
chosen.

Pacing
------

Open Cloud rate-limits uploads and answers 429 when pushed. A publisher that
does not pace gets throttled into a long tail of retries; one that paces
finishes sooner. The delay is deliberate and the backoff is exponential.

Remembering
-----------

Every published asset records which pack it came from, which author made it,
what licence that pack carried, and the path inside the zip. CC0 requires no
attribution -- and "where did this mesh come from" is a question somebody asks
a month later regardless, when the answer is no longer reconstructable.
"""

from __future__ import annotations

import json
import os
import time
import urllib.error
import urllib.request
import uuid
import zipfile
from pathlib import Path
from typing import Any

from . import local_credentials
from .sweep import TOPICS

ROOT = Path("assets/itch")
INVENTORY = Path("forge/kits/itch-inventory.json")
PUBLISHED = Path("forge/kits/itch-published.json")

ASSETS_URL = "https://apis.roblox.com/assets/v1/assets"
OPERATION_URL = "https://apis.roblox.com/assets/v1/operations/{op}"

#: Open Cloud takes these directly as `Model`. `.obj` needs a material file
#: beside it and `.blend` is not an interchange format, so neither is offered
#: here even though the packs carry both.
UPLOADABLE = (".fbx", ".glb", ".gltf")

#: Seconds between uploads. Open Cloud answers 429 under load, and a publisher
#: that races into throttling finishes later than one that waits.
DELAY = 2.0

#: Above this Roblox rejects the upload outright. Recorded rather than
#: attempted, so the manifest says why instead of the log saying nothing.
MAX_BYTES = 20 * 1024 * 1024

#: Names that mark a file as one of several near-identical siblings. Matched on
#: the stem's tail, so `crate_red` is a variant of `crate` and `crate_open` --
#: a genuinely different shape -- is not.
VARIANT_TAILS = (
    "_1", "_2", "_3", "_4", "_5", "_6", "_7", "_8", "_9",
    "_a", "_b", "_c", "_red", "_blue", "_green", "_yellow", "_white",
    "_black", "_purple", "_orange", "_pink", "_brown", "_grey", "_gray",
    "_lod0", "_lod1", "_lod2", "_lod3", "_alt", "_variant", "_var",
)


def _topic_words() -> dict[str, tuple[str, ...]]:
    """Every topic, with the words that identify it in a filename."""
    out: dict[str, tuple[str, ...]] = {}
    for topics in TOPICS.values():
        for topic in topics:
            #: "storage tank" matches a file called `tank` or `storage`; the
            #: multi-word topics almost never appear whole in a filename.
            out[topic] = tuple(w for w in topic.split() if len(w) > 2)
    return out


def classify(stem: str, words: dict[str, tuple[str, ...]] | None = None) -> str | None:
    """Which topic a mesh filename belongs to, or None."""
    table = words or _topic_words()
    lowered = stem.lower().replace("-", "_")
    best: tuple[int, str] | None = None
    for topic, terms in table.items():
        for term in terms:
            if term in lowered:
                #: Longest matching term wins, so `bookshelf` files under
                #: `bookshelf` rather than under `book`.
                score = len(term)
                if best is None or score > best[0]:
                    best = (score, topic)
    return best[1] if best else None


def _is_variant(stem: str) -> bool:
    lowered = stem.lower()
    return any(lowered.endswith(tail) for tail in VARIANT_TAILS)


def _base(stem: str) -> str:
    """The stem with a variant tail removed, for grouping siblings."""
    lowered = stem.lower()
    for tail in VARIANT_TAILS:
        if lowered.endswith(tail):
            return lowered[: -len(tail)]
    return lowered


def inventory(root: Path = ROOT, progress: Any = print) -> dict[str, Any]:
    """Every uploadable mesh inside every downloaded pack.

    Reads the zip directory rather than extracting. A pack is 40 MB and holds
    266 files; unpacking 360 of them to list their contents would cost more
    disk than the downloads did.
    """
    manifest_path = root / "manifest.json"
    provenance: dict[str, Any] = {}
    if manifest_path.exists():
        for record in (json.loads(manifest_path.read_text(encoding="utf-8"))
                       .get("files") or {}).values():
            if record.get("path"):
                provenance[str(Path(record["path"]))] = record

    meshes: list[dict[str, Any]] = []
    archives = sorted(root.rglob("*.zip"))
    for index, archive in enumerate(archives, start=1):
        source = provenance.get(str(archive), {})
        try:
            with zipfile.ZipFile(archive) as bundle:
                for info in bundle.infolist():
                    if info.is_dir():
                        continue
                    member = Path(info.filename)
                    if member.suffix.lower() not in UPLOADABLE:
                        continue
                    #: Animation rigs are not props and upload as broken
                    #: Models; a pack keeps them in their own folder.
                    if "animation" in info.filename.lower():
                        continue
                    meshes.append({
                        "archive": str(archive),
                        "member": info.filename,
                        "stem": member.stem,
                        "suffix": member.suffix.lower(),
                        "size": info.file_size,
                        "pack": source.get("pack") or archive.parent.name,
                        "author": source.get("author") or archive.parent.parent.name,
                        "url": source.get("url"),
                        "licence": source.get("licence") or "cc0",
                    })
        except (zipfile.BadZipFile, OSError) as error:
            progress(f"  ! {archive.name}: {error}")
            continue
        if index % 25 == 0:
            progress(f"  {index}/{len(archives)} packs, {len(meshes)} meshes")

    book = {
        "$comment": (
            "Uploadable meshes inside the downloaded CC0 packs. Read from each "
            "zip's directory without extracting. Animation rigs are excluded: "
            "they are not props and upload as broken Models."),
        "meshes": meshes,
        "count": len(meshes),
        "archives": len(archives),
    }
    INVENTORY.parent.mkdir(parents=True, exist_ok=True)
    INVENTORY.write_text(json.dumps(book, indent=1, ensure_ascii=False) + "\n",
                         encoding="utf-8")
    return book


def select(meshes: list[dict[str, Any]], per_topic: int = 4,
           skip_variants: bool = True) -> list[dict[str, Any]]:
    """The best few per topic. Strategy three: enough to build a game with.

    Preference order inside a topic: `.fbx` first because it is what Roblox
    ingests most reliably, then smaller files, because a 12 MB prop and a
    200 KB prop of the same thing are the same prop and one of them costs
    forty times as much to load.
    """
    words = _topic_words()
    by_topic: dict[str, list[dict[str, Any]]] = {}
    seen_bases: dict[str, set[str]] = {}

    ordered = sorted(meshes, key=lambda m: (m["suffix"] != ".fbx", m["size"]))
    for mesh in ordered:
        if mesh["size"] > MAX_BYTES:
            continue
        topic = classify(mesh["stem"], words)
        if not topic:
            continue

        bucket = by_topic.setdefault(topic, [])
        if len(bucket) >= per_topic:
            continue

        if skip_variants:
            base = _base(mesh["stem"])
            bases = seen_bases.setdefault(topic, set())
            #: One of each shape. A variant is only skipped when its base is
            #: already represented -- a pack that ships only `crate_red` still
            #: contributes a crate.
            if base in bases:
                continue
            bases.add(base)

        bucket.append({**mesh, "topic": topic})

    chosen: list[dict[str, Any]] = []
    for topic in sorted(by_topic):
        chosen.extend(by_topic[topic])
    return chosen


# ------------------------------------------------------------------ publish

def _multipart(payload: dict[str, Any], filename: str, content: bytes,
               content_type: str) -> tuple[bytes, str]:
    boundary = "rqe" + uuid.uuid4().hex
    parts = [
        f"--{boundary}\r\nContent-Disposition: form-data; name=\"request\"\r\n"
        f"Content-Type: application/json\r\n\r\n{json.dumps(payload)}\r\n".encode(),
        f"--{boundary}\r\nContent-Disposition: form-data; name=\"fileContent\"; "
        f"filename=\"{filename}\"\r\nContent-Type: {content_type}\r\n\r\n".encode(),
        content,
        f"\r\n--{boundary}--\r\n".encode(),
    ]
    return b"".join(parts), boundary


def _post(body: bytes, boundary: str, key: str, timeout: float = 120.0) -> dict[str, Any]:
    request = urllib.request.Request(
        ASSETS_URL, data=body, method="POST",
        headers={"x-api-key": key,
                 "Content-Type": f"multipart/form-data; boundary={boundary}"})
    with urllib.request.urlopen(request, timeout=timeout) as response:
        return json.load(response)


def _await_operation(operation: str, key: str, tries: int = 12,
                     pause: float = 3.0) -> dict[str, Any]:
    """Poll until the upload resolves. Returns the asset, or the last state.

    Uploads are asynchronous and moderation happens inside this window, so the
    operation is where a rejection surfaces. Not polling would record every
    upload as a success including the refused ones.
    """
    for _ in range(tries):
        request = urllib.request.Request(
            OPERATION_URL.format(op=operation), headers={"x-api-key": key})
        try:
            with urllib.request.urlopen(request, timeout=30) as response:
                state = json.load(response)
        except (urllib.error.HTTPError, urllib.error.URLError, OSError):
            time.sleep(pause)
            continue
        if state.get("done"):
            return state
        time.sleep(pause)
    return {"done": False, "operationId": operation}


def publish(chosen: list[dict[str, Any]], creator_user_id: str = "5812220258",
            delay: float = DELAY, progress: Any = print) -> dict[str, Any]:
    """Upload each selected mesh as a Roblox Model. Resumable."""
    local_credentials.load()
    key = os.environ.get(local_credentials.ENV_VAR, "")
    if not key:
        raise RuntimeError("no Roblox Open Cloud credential")

    records: dict[str, Any] = {}
    if PUBLISHED.exists():
        try:
            records = json.loads(PUBLISHED.read_text(encoding="utf-8")).get("assets") or {}
        except (OSError, json.JSONDecodeError):
            records = {}

    uploaded = skipped = failed = 0
    started = time.time()
    since_write = 0

    for index, mesh in enumerate(chosen, start=1):
        marker = f"{Path(mesh['archive']).name}::{mesh['member']}"
        if marker in records and records[marker].get("assetId"):
            skipped += 1
            continue

        try:
            with zipfile.ZipFile(mesh["archive"]) as bundle:
                content = bundle.read(mesh["member"])
        except (zipfile.BadZipFile, KeyError, OSError) as error:
            failed += 1
            records[marker] = {"error": f"unreadable: {error}"[:160], **_source(mesh)}
            continue

        payload = {
            "assetType": "Model",
            "displayName": _display_name(mesh),
            #: Provenance in the description because it is the only field that
            #: travels with the asset. CC0 asks for no credit; a month from now
            #: somebody will still want to know where this came from.
            "description": (f"CC0 public domain. Source: {mesh['author']}, "
                            f"{mesh['pack']}. {mesh.get('url') or ''}").strip(),
            "creationContext": {"creator": {"userId": str(creator_user_id)}},
        }
        body, boundary = _multipart(
            payload, Path(mesh["member"]).name, content,
            "model/fbx" if mesh["suffix"] == ".fbx" else "model/gltf-binary")

        wait = delay
        state: dict[str, Any] | None = None
        for attempt in range(4):
            try:
                state = _post(body, boundary, key)
                break
            except urllib.error.HTTPError as error:
                if error.code == 429:
                    #: Throttled. Backing off is the only thing that helps, and
                    #: retrying immediately makes it worse for everybody.
                    wait *= 2
                    progress(f"  throttled; waiting {wait:.0f}s")
                    time.sleep(wait)
                    continue
                records[marker] = {
                    "error": f"HTTP {error.code}: "
                             f"{error.read()[:120].decode('utf-8', 'replace')}",
                    **_source(mesh)}
                break
            except (urllib.error.URLError, OSError) as error:
                records[marker] = {"error": str(error)[:160], **_source(mesh)}
                break

        if not state:
            failed += 1
            time.sleep(delay)
            continue

        resolved = _await_operation(state.get("operationId", ""), key)
        asset = (resolved.get("response") or {})
        asset_id = asset.get("assetId")
        if asset_id:
            uploaded += 1
            records[marker] = {
                "assetId": asset_id,
                "displayName": asset.get("displayName"),
                "moderation": (asset.get("moderationResult") or {}).get("moderationState"),
                **_source(mesh),
            }
        else:
            failed += 1
            records[marker] = {"error": "operation did not resolve to an asset",
                               "operation": state.get("operationId"), **_source(mesh)}

        since_write += 1
        if since_write >= 5:
            _write(records, uploaded, skipped, failed, started)
            since_write = 0
        if index % 20 == 0:
            progress(f"  {index}/{len(chosen)}  {uploaded} up, {failed} failed, "
                     f"{time.time() - started:.0f}s")
        time.sleep(delay)

    return _write(records, uploaded, skipped, failed, started)


def _source(mesh: dict[str, Any]) -> dict[str, Any]:
    return {"topic": mesh.get("topic"), "pack": mesh.get("pack"),
            "author": mesh.get("author"), "licence": mesh.get("licence"),
            "member": mesh.get("member")}


def _display_name(mesh: dict[str, Any]) -> str:
    """A name a person can find later. Roblox caps this at 50 characters."""
    stem = mesh["stem"].replace("_", " ").replace("-", " ").strip()
    return (stem[:44] or "Model").title()


def _write(records: dict[str, Any], uploaded: int, skipped: int, failed: int,
           started: float) -> dict[str, Any]:
    book = {
        "$comment": (
            "Models published to Roblox from CC0 itch.io packs. Each entry keeps "
            "the pack, author and licence it came from, and the moderation state "
            "Roblox returned. Uploads are asynchronous and moderation happens "
            "inside the operation, so an entry without an assetId was refused or "
            "never resolved -- not merely slow."),
        "assets": records,
        "uploaded": uploaded,
        "alreadyPublished": skipped,
        "failed": failed,
        "seconds": round(time.time() - started),
    }
    PUBLISHED.parent.mkdir(parents=True, exist_ok=True)
    PUBLISHED.write_text(json.dumps(book, indent=1, ensure_ascii=False) + "\n",
                         encoding="utf-8")
    return book
