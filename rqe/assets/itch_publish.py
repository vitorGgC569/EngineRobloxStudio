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
from ..http_safety import HttpBoundaryError, error_body_limited, json_object_limited

ROOT = Path("assets/itch")
INVENTORY = Path("forge/kits/itch-inventory.json")
PUBLISHED = Path("forge/kits/itch-published.json")
MAX_API_RESPONSE_BYTES = 4 * 1024 * 1024

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


#[[
#   The other names a topic goes by in a filename.
#
#   A topic was only ever identified by the words in its own name, so `tree`
#   matched a file called `tree` and nothing else. The inventory holds 26,191
#   meshes, of which 222 are trees -- `pine01`, `birch-tree-2`, `spruce_1`,
#   `oak_large` -- and three reached the catalogue. A game whose entire
#   progression is unlocking rarer trees was built on three tree models
#   because artists do not name files after taxonomies.
#
#   Only names that genuinely *are* the topic go here. `stump` and `trunk`
#   are filed as logs rather than as trees on purpose: they are cut wood, and
#   a stump placed at tree scale is a stump the size of a tree.
#]]
SYNONYMS: dict[str, tuple[str, ...]] = {
    "tree": ("pine", "spruce", "birch", "oak", "maple", "willow", "fir",
             "cedar", "conifer", "palm", "sapling", "poplar", "aspen"),
    "log": ("stump", "trunk", "timber", "firewood", "logs", "lumber"),
    "rock": ("stone", "boulder", "rubble"),
    "bush": ("shrub", "hedge", "fern"),
    "flower": ("tulip", "rose", "daisy", "sunflower", "poppy"),
    "fence": ("railing", "picket", "palisade"),
    "grass patch": ("grasspatch", "turf", "meadow"),
    #: The swung tool. There are sixty axes in the inventory and no `axe`
    #: topic; filing them here is what makes a woodcutting game able to hand
    #: the player the thing it is named after.
    "pickaxe": ("axe", "hatchet", "chopper"),
    #: A closed container. Seeds arrive in these.
    "crate": ("sack", "pouch", "burlap"),
}


def _topic_words() -> dict[str, tuple[str, ...]]:
    """Every topic, with the words that identify it in a filename."""
    out: dict[str, tuple[str, ...]] = {}
    for topics in TOPICS.values():
        for topic in topics:
            #: "storage tank" matches a file called `tank` or `storage`; the
            #: multi-word topics almost never appear whole in a filename.
            terms = tuple(w for w in topic.split() if len(w) > 2)
            out[topic] = terms + SYNONYMS.get(topic, ())
    return out


#[[
#   Compounds whose meaning flips at the very edge a structural rule reads.
#
#   `watchtower` really is a tower and `minecart` really is a cart, so the
#   prefix/suffix rule below is right about them. These are the ones it is
#   wrong about, and nothing in the spelling distinguishes the two groups --
#   so they are written down rather than derived.
#
#   Written as the *word* the splitter produces, not the filename: `brickSmoker`
#   arrives here as `brick` and `smoker`, so the trap is `smoker`.
#
#   Each earns its line by having been observed in the published set.
#]]
COMPOUND_TRAPS = {
    "sandcastle",   #: a beach prop, not a 105-stud landmark
    "workbench",    #: a table
    "clamp",        #: ends in `lamp`
    "cauliflower",  #: ends in `flower`
    "smoker",       #: a barbecue, not smoke (from `brickSmoker`)
    "holder",       #: ends in `older`, starts nothing
    "micropipet",   #: not a pipe
}


def _stem_words(stem: str) -> list[str]:
    """A filename's words, in order, split on punctuation and on caseChanges.

    Without the case split `sandCastle` is one unknown word; with it, `sand`
    and `castle` both land and the *last* one can be recognised as the noun.
    """
    out = []
    for index, char in enumerate(stem):
        if char.isupper() and index > 0 and stem[index - 1].islower():
            out.append(" ")
        out.append(char.lower() if char.isalnum() else " ")
    return [w for w in "".join(out).split() if w]


def classify(stem: str, words: dict[str, tuple[str, ...]] | None = None) -> str | None:
    """Which topic a mesh filename belongs to, or None.

    Whole words first, substrings only as a fallback. This matched substrings
    anywhere in the name, which files a mesh under a word buried inside another
    word -- silently, and the wrong answer looks exactly like a right one.
    Measured against the 295 already published: 38 were classified that way and
    about half changed meaning outright.

        carpet        -> pet
        sandcastle_A  -> castle       (and would then be built 105 studs tall)
        mailbox       -> ammo box
        hex_forest    -> ore
        table_lamp    -> table        (longest term wins, and `table` is longer)

    That last one is why the fallback is not enough on its own: both `table`
    and `lamp` are whole words in `table_lamp`, and length picks the adjective.
    English compounds put the noun last, so ties are broken by position -- the
    later word wins, which reads `table lamp` as a lamp and `lamp table` as a
    table, both correctly.

    The same bug has now been fixed three times in this repository, in three
    classifiers written months apart. It is worth suspecting on sight.
    """
    table = words or _topic_words()
    present = _stem_words(stem)
    if not present:
        return None
    index_of = {word: position for position, word in enumerate(present)}

    #: (position, length) so a later word beats an earlier one, and among words
    #: at the same position the longer term wins.
    best: tuple[int, int, str] | None = None
    for topic, terms in table.items():
        for term in terms:
            position = index_of.get(term)
            if position is None:
                continue
            score = (position, len(term), topic)
            if best is None or score[:2] > best[:2]:
                best = score
    if best:
        return best[2]

    #[[
    #   Compounds, and only at their edges.
    #
    #   Names arrive welded -- `minecart`, `watchtower`, `bookshelf`,
    #   `trapdoor` -- and all four of those are genuinely the thing their tail
    #   names. So the fallback matches a term that *starts or ends* a word,
    #   never one buried in the middle: `micropipet` stops being a pipe and
    #   `hex_forest` stops being ore.
    #
    #   That still leaves compounds whose meaning flips at the same edge --
    #   a sandcastle is not a castle at castle scale, a workbench is a table --
    #   and no structural rule separates those from `watchtower`. They are
    #   listed below as knowledge, which is what they are.
    #]]
    joined_words = [w for w in present if w not in COMPOUND_TRAPS]
    fallback: tuple[int, str] | None = None
    for topic, terms in table.items():
        for term in terms:
            if len(term) <= 3:
                #: Three letters is not evidence inside a longer word. `ore`,
                #: `pet` and `box` are exactly the ones that caused this.
                continue
            for word in joined_words:
                if word == term:
                    continue
                if word.startswith(term) or word.endswith(term):
                    if fallback is None or len(term) > fallback[0]:
                        fallback = (len(term), topic)
                    break
    return fallback[1] if fallback else None


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
        return json_object_limited(
            response,
            MAX_API_RESPONSE_BYTES,
            label="Roblox asset upload response",
        )


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
                state = json_object_limited(
                    response,
                    MAX_API_RESPONSE_BYTES,
                    label="Roblox asset operation response",
                )
        except (urllib.error.HTTPError, urllib.error.URLError, OSError, HttpBoundaryError):
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
    stopped = False
    started = time.time()
    since_write = 0

    for index, mesh in enumerate(chosen, start=1):
        if stopped:
            break
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
                body = error_body_limited(error, 200).decode("utf-8", "replace")
                records[marker] = {
                    "error": f"HTTP {error.code}: {body[:120]}",
                    **_source(mesh)}
                #: An account-level stop, not a failure of this file. Walking
                #: the rest of the batch collects the same answer several
                #: hundred times and deepens whatever triggered it: 487 of
                #: these came from one run that kept going.
                if MODERATED in body.lower():
                    progress("  ! the account is moderated for uploads; "
                             "stopping the batch")
                    stopped = True
                break
            except (urllib.error.URLError, OSError, HttpBoundaryError) as error:
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
#: Not a per-file failure at all: the account has been stopped. Retrying is
#: what produced 487 of these in one run, and the publisher should give up the
#: whole batch rather than walk the rest of it collecting the same answer.
MODERATED = "user is moderated"

TERMINAL_ERRORS = (
    "no mesh content", "failed to parse", "unreadable", "too large",
    #[[
    #   Roblox accepts the upload, starts an operation and never resolves it.
    #
    #   All 22 of these are `.gltf`, which the uploadable list has excluded
    #   since the format was measured -- glTF references its buffers as
    #   separate files, so a single-file upload hands Roblox a document
    #   pointing at things that are not there. They are residue from before
    #   that exclusion and none of them can succeed.
    #
    #   Without this line a follow loop retries all 22 every round, forever.
    #   That has already happened once in this repository, for four files.
    #]]
    "did not resolve",
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
	--[[
		A flat model is never picked, and unlike `texturedOnly` that is not a
		parameter.

		Some assets import as a single quad -- a billboard plane where a prop
		was expected -- and scattered through a world they stand in the grass as
		grey rectangles. There is no caller for whom that is the right answer.
		If every model for a topic is flat then the topic has nothing usable,
		and nil is the honest reply.
	]]
	local solid = {}
	for _, entry in list do
		if not entry.flat then
			table.insert(solid, entry)
		end
	end
	if #solid == 0 then
		return nil
	end
	list = solid

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

--[[
	A *named* model from a topic, for when any-of-them will not do.

	`pick` is the right call for scenery: a seed, a topic, and whichever tree
	comes back is a tree. It is the wrong call the moment a specific model has
	to mean something -- six tree species whose whole progression is "this one
	is rarer than that one" cannot be six seeds into the same list, because
	the player has no way to tell which they got.

	Matches on a word in the model's name, so a game asks for "birch" and gets
	the birch. Returns nil rather than a substitute: a caller that wanted a
	specific thing is better served by knowing it is absent than by silently
	receiving something else.
]]
function ItchAssets.named(topic: string, needle: string,
                         texturedOnly: boolean?): number?
	local list = byTopic[topic]
	if not list or needle == "" then
		return nil
	end
	local wanted = string.lower(needle)
	for _, entry in list do
		if not entry.flat
				and (not texturedOnly or entry.textured)
				and string.find(string.lower(entry.name), wanted, 1, true) then
			return entry.id
		end
	end
	return nil
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


#[[
#   The texture audit is a ledger, not an artifact.
#
#   It lived under `artifacts/`, which is gitignored, so a fresh clone
#   had no measurements and `export_lua` fell back to inferring
#   `textured` from the file extension -- the guess that claimed 221
#   coloured models where Studio found 89. What Studio measured is an
#   input to the catalogue and belongs beside the published ledger.
#]]
AUDIT = Path("forge/kits/itch-texture-audit.json")


def audit_textures(bridge: Any, ids: list[str] | None = None,
                   audit: Path | None = None, batch: int = 25,
                   progress: Any = print) -> dict[str, Any]:
    """Load each published asset in Studio and count what is actually inside.

    `textured` cannot be inferred from the upload. It was, once -- `.glb`
    carries its images, therefore a GLB upload is textured -- and that guess
    claimed 221 coloured models where Studio found 89. The file format only
    says what was *sent*; what survived the import is a different question and
    the only instrument that can answer it is Studio.

    This existed as a paragraph of Luau pasted through the bridge by hand, run
    once, which is why 56 newly published assets had no measurement at all and
    would have been ranked below the grey ones they replaced. Now it is a
    function, and it only visits ids it has not already measured.
    """
    path = Path(audit) if audit else AUDIT
    book: dict[str, Any] = {}
    if path.exists():
        try:
            book = json.loads(path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError):
            book = {}

    if ids is None:
        records = {}
        if PUBLISHED.exists():
            records = json.loads(PUBLISHED.read_text(encoding="utf-8")).get("assets") or {}
        ids = [str(v["assetId"]) for v in records.values() if v.get("assetId")]
    #: Anything measured before the shape fields existed is measured again.
    #: A partial audit that silently keeps old rows is an audit that never
    #: gains a column.
    todo = [i for i in ids
            if i not in book or "thinness" not in (book.get(i) or {})]
    if not todo:
        progress("every published asset is already measured")
        return book

    progress(f"measuring {len(todo)} assets in Studio")
    for start in range(0, len(todo), batch):
        chunk = todo[start:start + batch]
        source = """
local InsertService = game:GetService("InsertService")
local out = {}
for _, id in { %s } do
    local ok, model = pcall(function()
        return InsertService:LoadAsset(tonumber(id))
    end)
    if not ok or not model then
        out[id] = { error = "load failed" }
    else
        local textures, meshes, surfaces, tinted = 0, 0, 0, 0
        local name = model.Name
        for _, d in model:GetDescendants() do
            if d:IsA("MeshPart") then
                meshes += 1
                if d.TextureID ~= "" then textures += 1 end
            elseif d:IsA("SpecialMesh") then
                meshes += 1
                if d.TextureId ~= "" then textures += 1 end
            elseif d:IsA("Texture") or d:IsA("Decal") then
                surfaces += 1
            end
        end
        --[[
            The shape, not just the contents.

            Some published models import as a single flat quad -- a billboard
            plane where a prop was expected. Scattered through a world they
            read as grey rectangles standing in the grass, and nothing about
            the file, the topic or the texture count says so. The bounding box
            does, in one number.
        ]]
        local lo, hi
        for _, d in model:GetDescendants() do
            if d:IsA("BasePart") then
                local half = d.Size / 2
                local c = d.CFrame
                for _, corner in {
                    Vector3.new(half.X, half.Y, half.Z),
                    Vector3.new(-half.X, half.Y, half.Z),
                    Vector3.new(half.X, -half.Y, half.Z),
                    Vector3.new(half.X, half.Y, -half.Z),
                    Vector3.new(-half.X, -half.Y, half.Z),
                    Vector3.new(-half.X, half.Y, -half.Z),
                    Vector3.new(half.X, -half.Y, -half.Z),
                    Vector3.new(-half.X, -half.Y, -half.Z),
                } do
                    local w = c:PointToWorldSpace(corner)
                    lo = if lo then Vector3.new(math.min(lo.X, w.X), math.min(lo.Y, w.Y), math.min(lo.Z, w.Z)) else w
                    hi = if hi then Vector3.new(math.max(hi.X, w.X), math.max(hi.Y, w.Y), math.max(hi.Z, w.Z)) else w
                end
            end
        end
        local extent = if lo and hi then hi - lo else Vector3.zero
        local dims = { extent.X, extent.Y, extent.Z }
        table.sort(dims)

        local first = model:GetChildren()[1]
        out[id] = { textures = textures, meshes = meshes, surfaces = surfaces,
                    tinted = tinted, name = first and first.Name or name,
                    sizeX = extent.X, sizeY = extent.Y, sizeZ = extent.Z,
                    --: The thinnest edge against the longest. Under about a
                    --: fortieth and the thing has no depth at all.
                    thinness = if dims[3] > 0 then dims[1] / dims[3] else 0 }
        model:Destroy()
    end
end
return out
""" % ", ".join(f'"{i}"' for i in chunk)
        try:
            with bridge.lease_scope(
                agent_id="itch-texture-audit",
                context="edit",
                ttl_seconds=300.0,
            ):
                answer = bridge.exec_luau(source, timeout=240).get("returned") or {}
        except Exception as exc:  # noqa: BLE001
            progress(f"  ! batch failed: {exc}")
            continue
        book.update(answer)
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(json.dumps(book, indent=1) + chr(10), encoding="utf-8")
        progress(f"  {min(start + batch, len(todo))}/{len(todo)}")
    return book


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

        #[[
        #   Flat, and therefore not a prop.
        #
        #   Some published models import as a single quad -- a billboard plane
        #   where a tree or a rock was expected. Scattered through a world they
        #   stand in the grass as grey rectangles, and nothing in the filename,
        #   the topic or the texture count says so. The bounding box does: the
        #   thinnest edge against the longest, under a fortieth.
        #]]
        thinness = float(found.get("thinness") or 0) if found else 0.0
        flat = bool(found) and 0 < thinness < 0.025

        rows.append(
            f"\t{{ id = {entry['assetId']}, name = {_lua_str(entry.get('displayName'))}, "
            f"topic = {_lua_str(entry.get('topic'))}, "
            f"textured = {'true' if has_colour else 'false'}, "
            f"flat = {'true' if flat else 'false'}, "
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
