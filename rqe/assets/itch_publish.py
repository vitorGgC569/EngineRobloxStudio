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

A single pack holds seventy meshes; the 360 downloaded hold 39,462. Most of
that is variants -- the same crate in four colours, the same tree at three
levels of detail -- and deduplicating by shape leaves about 12,400. At the
measured twelve seconds an upload takes, publishing all of it is 41 hours and
fills an account with near-duplicates nobody can search.

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

#: Open Cloud takes these directly as `Model`.
#:
#: `.gltf` was here and had to come out. It is JSON that *references* its
#: buffers and textures as separate files, so a single-file upload hands Roblox
#: a document pointing at things that are not there: 20 failures against 1
#: success, every one of them "Failed to parse the uploaded file". A `.glb` is
#: the same format with everything packed in, and works.
#:
#: `.obj` needs its `.mtl` beside it for the same reason, and `.blend` is not
#: an interchange format at all. The packs carry both and neither is offered.
UPLOADABLE = (".fbx", ".glb")

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

    **`.glb` first, and this is the whole difference between a coloured model
    and a grey one.** An FBX references its texture by relative path; Open
    Cloud receives one file and cannot resolve `../textures/atlas.png`, so
    every FBX upload arrives untextured. A `.glb` carries its images inside the
    file.

    Measured rather than assumed, by inserting both back into Studio: the GLB
    of a KayKit character came in with 8 parts and 7 textures; the FBX uploads
    came in with 0. This function used to sort `.fbx` first, which is why the
    first few dozen published assets are colourless.

    After format, smaller files win: a 12 MB prop and a 200 KB prop of the same
    thing are the same prop, and one of them costs forty times as much to load.
    """
    words = _topic_words()
    by_topic: dict[str, list[dict[str, Any]]] = {}
    seen_bases: dict[str, set[str]] = {}

    #: GLB first for colour, FBX second because it at least parses. An earlier
    #: version ranked `.gltf` above `.fbx` on the reasoning that it "names its
    #: buffers" -- exactly backwards, since naming a file Roblox never receives
    #: is worse than shipping no texture at all.
    rank = {".glb": 0, ".fbx": 1}
    ordered = sorted(meshes, key=lambda m: (rank.get(m["suffix"], 3), m["size"]))

    #[[
    #   FBX only where no coloured option exists for that topic at all.
    #
    #   Ranking alone still let a topic with two GLBs fill its remaining two
    #   slots with FBX, which publishes grey props beside coloured ones for the
    #   same thing -- the worst of both, because the grey ones are what a
    #   search surfaces half the time.
    #
    #   So a topic that has any textured mesh anywhere uses only those, even if
    #   that means fewer than `per_topic`. Falling back is for topics with no
    #   possibility of colour, which on the current inventory is six of them.
    #]]
    coloured_topics: set[str] = set()
    for mesh in ordered:
        if mesh["suffix"] == ".glb":
            topic = classify(mesh["stem"], words)
            if topic:
                coloured_topics.add(topic)
    for mesh in ordered:
        if mesh["size"] > MAX_BYTES:
            continue
        #: A zero-byte member is a packing accident, not a model. Roblox
        #: answers "Cannot import file with no mesh content", which is true and
        #: costs an upload and a poll to hear.
        if mesh["size"] == 0:
            continue
        topic = classify(mesh["stem"], words)
        if not topic:
            continue

        #: The rule: colour where colour is possible.
        if mesh["suffix"] == ".fbx" and topic in coloured_topics:
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
            #[[
            #   Roblox says why. Read it.
            #
            #   This recorded "operation did not resolve to an asset" for every
            #   failure, while the operation carried
            #   `error.message = "Failed to parse the uploaded file"` -- the one
            #   fact that identified the cause. Twenty-one failures looked like
            #   a timeout and were a format that cannot work.
            #]]
            detail = resolved.get("error") or {}
            records[marker] = {
                "error": (detail.get("message")
                          or ("upload did not finish within the poll window"
                              if not resolved.get("done")
                              else "operation resolved without an asset")),
                "code": detail.get("code"),
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


#: Refusals that will not change on a retry. Roblox is describing the file,
#: not the moment -- a throttle or a dropped connection is transient and worth
#: another go; a mesh with no geometry in it is not.
TERMINAL_ERRORS = (
    "no mesh content",
    "failed to parse",
    "unreadable",
    "too large",
)


def _terminal(error: Any) -> bool:
    """Is this failure about the file rather than the attempt?"""
    if not error:
        return False
    lowered = str(error).lower()
    return any(phrase in lowered for phrase in TERMINAL_ERRORS)


def follow(per_topic: int = 4, root: Path = ROOT, idle_rounds: int = 3,
           pause: float = 60.0, delay: float = DELAY,
           progress: Any = print) -> dict[str, Any]:
    """Publish as packs land, instead of waiting for the download to finish.

    Thirty gigabytes takes hours; the meshes inside the first pack are
    publishable the moment it lands. So this re-reads the inventory each round
    and uploads whatever the selection now reaches that has not gone up yet.

    `publish` already skips anything with an assetId in the manifest, so a
    round costs a re-scan and nothing else when there is nothing new. The
    manifest is the only coordination between the two jobs -- there is no
    shared state, no lock, and no assumption about which finishes first.

    Stops after `idle_rounds` consecutive rounds that publish nothing, which is
    what "the download finished and the selection is exhausted" looks like from
    here without needing to inspect the other job.
    """
    total_uploaded = 0
    idle = 0
    started = time.time()
    round_number = 0

    while idle < idle_rounds:
        round_number += 1
        book = inventory(root, progress=lambda _m: None)
        chosen = select(book["meshes"], per_topic=per_topic)

        #: What this round would add, before doing it -- so an idle round is
        #: recognised without paying for a publish pass to discover it.
        #[[
        #   Settled, not merely published.
        #
        #   This asked only whether an entry had an assetId, so a file Roblox
        #   permanently refuses stayed "pending" for ever: the loop never went
        #   idle, and it spent ninety rounds re-uploading the same four broken
        #   meshes -- two of them zero bytes -- once a minute.
        #
        #   A terminal refusal is an answer. Retrying it is not diligence, it is
        #   a loop that does not know how to stop.
        #]]
        settled: set[str] = set()
        if PUBLISHED.exists():
            try:
                for marker, record in (json.loads(
                        PUBLISHED.read_text(encoding="utf-8")).get("assets") or {}).items():
                    if record.get("assetId") or _terminal(record.get("error")):
                        settled.add(marker)
            except (OSError, json.JSONDecodeError):
                settled = set()
        pending = [m for m in chosen
                   if f"{Path(m['archive']).name}::{m['member']}" not in settled]

        progress(f"\nround {round_number}: {book['archives']} packs, "
                 f"{len(chosen)} selected, {len(pending)} new")

        if not pending:
            idle += 1
            progress(f"  nothing new ({idle}/{idle_rounds} idle rounds)")
            time.sleep(pause)
            continue

        idle = 0
        result = publish(pending, delay=delay, progress=progress)
        total_uploaded += result["uploaded"]
        progress(f"  round {round_number}: +{result['uploaded']} published, "
                 f"{result['failed']} failed, {total_uploaded} total")

    return {"rounds": round_number, "uploaded": total_uploaded,
            "seconds": round(time.time() - started)}


LUA_PATH = Path("forge/luau/Forge/Catalog/ItchAssets.lua")

_ITCH_HEADER = '''--!strict
--[[
	ItchAssets — CC0 models published to this account, grouped by topic.

	Generated by `rqe.assets.itch_publish`; rewritten on every export.

	These are published Roblox Models, not baked geometry, so they load through
	`InsertService:LoadAsset` at runtime rather than being rebuilt from parts.
	That works here for the reason it fails for store models generally: the
	signed-in account owns them, because it published them.

		local Itch = Forge.Catalog.ItchAssets
		local id = Itch.pick("tree", seed)
		local model = game:GetService("InsertService"):LoadAsset(id)

	`textured` is the field that matters when choosing, and it is measured
	rather than inferred: every asset here was loaded once in Studio and its
	descendants counted. The obvious inference -- a `.glb` embeds its images,
	an `.fbx` names them by relative path and so arrives grey -- is sound about
	file formats and was wrong about 144 of these 295 assets, because a GLB
	whose materials are plain untextured colours converts to a bare MeshPart
	and the colour does not survive the import.

	So do not restore the guess. If `textured` is false, nothing in the asset
	carries colour and the caller has to supply it.

	`meshes` is how many MeshParts came out. One means a single welded shape,
	which is what you get from a GLB that lost its materials; several means the
	pack modelled parts separately, and their names are often meaningful
	(`house5_door1`, `house5_windows`) in a way that a tint pass can use.

	Every entry keeps the pack and author it came from. CC0 asks for no credit
	-- the provenance is for the question "what is this and where did it come
	from", which is asked long after the answer stops being obvious.

	%(count)d models across %(topics)d topics, %(textured)d of them carrying
	colour of their own. Published %(when)s.
]]

local ItchAssets = {}

ItchAssets.count = %(count)d

export type Entry = {
	id: number, name: string, topic: string,
	textured: boolean, meshes: number, pack: string, author: string,
}

ItchAssets.models = ({
%(entries)s
} :: any) :: { Entry }
'''

_ITCH_FOOTER = '''
local byTopic: { [string]: { Entry } } = {}
for _, entry in ItchAssets.models do
	local list = byTopic[entry.topic]
	if not list then list = {} byTopic[entry.topic] = list end
	table.insert(list, entry)
end

--: Textured first inside every topic, so a caller that takes the first gets
--: the one with colour without having to ask.
for _, list in byTopic do
	table.sort(list, function(a, b)
		if a.textured ~= b.textured then
			return a.textured
		end
		return a.id < b.id
	end)
end

function ItchAssets.byTopic(topic: string): { Entry }
	return byTopic[topic] or {}
end

function ItchAssets.topics(): { string }
	local out = {}
	for topic in byTopic do
		table.insert(out, topic)
	end
	table.sort(out)
	return out
end

--[[
	One model's id from a topic, chosen by a seed.

	Seeded rather than random so a world generated twice is the same world --
	the thing that makes a layout something you can author against instead of
	something you re-roll until it looks right.

	`texturedOnly` skips the grey ones. Worth passing wherever a prop is the
	subject rather than the backdrop.
]]
function ItchAssets.pick(topic: string, seed: number, texturedOnly: boolean?): number?
	local list = byTopic[topic]
	if not list or #list == 0 then
		return nil
	end
	if texturedOnly then
		local coloured = {}
		for _, entry in list do
			if entry.textured then
				table.insert(coloured, entry)
			end
		end
		if #coloured == 0 then
			return nil
		end
		list = coloured
	end
	return list[(math.floor(math.abs(seed)) % #list) + 1].id
end

function ItchAssets.describe(): { [string]: any }
	local textured = 0
	for _, entry in ItchAssets.models do
		if entry.textured then textured += 1 end
	end
	return {
		models = ItchAssets.count,
		topics = #ItchAssets.topics(),
		textured = textured,
	}
end

return ItchAssets
'''


def _lua_str(value: Any) -> str:
    return '"' + str(value or "").replace("\\", "\\\\").replace('"', '\\"') + '"'


AUDIT = Path("artifacts/itch-texture-audit.json")


def _measured(audit: Path | None = None) -> dict[str, Any]:
    """What Studio found inside each published asset, keyed by asset id.

    Written by loading all of them once and counting what came out. Empty when
    the audit has not been run, which drops `textured` back to the guess below
    -- so `export_lua` says loudly when that happens.
    """
    path = Path(audit) if audit else AUDIT
    if not path.exists():
        return {}
    try:
        book = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return {}
    return {k: v for k, v in book.items()
            if isinstance(v, dict) and "error" not in v}


def export_lua(published: Path | None = None,
               audit: Path | None = None) -> tuple[Path, int]:
    """Write the published assets as a Luau module a game can read."""
    source = Path(published) if published else PUBLISHED
    book = json.loads(source.read_text(encoding="utf-8"))
    live = [v for v in (book.get("assets") or {}).values() if v.get("assetId")]
    measured = _measured(audit)

    rows = []
    textured = 0
    guessed = 0
    for entry in sorted(live, key=lambda e: (e.get("topic") or "", e["assetId"])):
        member = Path(entry.get("member") or "")

        #: Measured, not inferred.
        #:
        #: This read `member.suffix == ".glb"`, on the reasoning that a GLB
        #: packs its images into the asset and an FBX cannot. The reasoning is
        #: right; the conclusion was wrong 144 times in 295. A GLB whose
        #: materials are untextured colours converts to a bare MeshPart, and
        #: the colour does not survive the import. The flag claimed 221
        #: textured models; loading all 295 in Studio found 89.
        #:
        #: It was also confident about exactly the topics that fill a frame --
        #: house, tree, castle, rock, all claimed, all grey -- so the first
        #: world built on it came out white while the manifest said otherwise.
        found = measured.get(str(entry["assetId"]))
        if found:
            has_colour = bool(found.get("textures") or found.get("surfaces")
                              or found.get("tinted"))
            meshes = int(found.get("meshes") or 0)
        else:
            has_colour = member.suffix.lower() == ".glb"
            meshes = 0
            guessed += 1
        textured += 1 if has_colour else 0

        rows.append(
            f"\t{{ id = {entry['assetId']}, name = {_lua_str(entry.get('displayName'))}, "
            f"topic = {_lua_str(entry.get('topic'))}, "
            f"textured = {'true' if has_colour else 'false'}, "
            f"meshes = {meshes}, "
            f"pack = {_lua_str(entry.get('pack'))}, "
            f"author = {_lua_str(entry.get('author'))} }},")

    if guessed:
        print(f"  ! {guessed} of {len(live)} assets are not in the audit; their "
              f"`textured` is guessed from the file extension, which is wrong "
              f"about half the time. Re-run the Studio audit.")

    topics = {e.get("topic") for e in live if e.get("topic")}
    LUA_PATH.parent.mkdir(parents=True, exist_ok=True)
    LUA_PATH.write_text(
        _ITCH_HEADER % {"count": len(live), "topics": len(topics),
                        "textured": textured,
                        "when": time.strftime("%Y-%m-%d"),
                        "entries": "\n".join(rows)} + _ITCH_FOOTER,
        encoding="utf-8")
    return LUA_PATH, len(live)
