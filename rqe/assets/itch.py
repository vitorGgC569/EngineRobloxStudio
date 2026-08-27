"""Discover free 3D asset packs on itch.io, and read what each one permits.

Three stages, kept apart on purpose
-----------------------------------

**Discover** reads public listings. Nothing is downloaded and nothing is
decided; it produces a list of pack pages with prices and authors.

**Inspect** fetches each pack's own page and pulls out what it says about
licensing. This is where the useful truth lives and where it is messy: itch.io
has no structured licence field, so creators write it in prose, in a tag, or in
a README inside the zip and nowhere else.

**Fetch** downloads. Separate because it is the first stage that costs
somebody bandwidth and puts files on disk.

Why licence is a first-class field even during evaluation
---------------------------------------------------------

"Free" on itch.io means free to download. It does not mean free to
redistribute, and uploading a mesh to Roblox's Creator Store is redistribution:
the asset lands on Roblox's CDN under an uploader's account and becomes usable
by others. Plenty of free packs permit exactly that (CC0 especially). Plenty
forbid it. A few permit it only with attribution that a bare mesh upload cannot
carry.

None of that stops evaluation -- downloading a free pack to see whether it is
any good is what the download button is for. It stops *publishing*, which is a
different button, and keeping the field attached from the first stage is what
lets that decision be made later rather than reconstructed.
"""

from __future__ import annotations

import json
import re
import time
import urllib.error
import urllib.parse
import urllib.request
from html import unescape
from pathlib import Path
from typing import Any

CATALOGUE = Path("forge/kits/itch-assets.json")

#: itch.io's own paginator, which its infinite scroll calls. The HTML page has
#: no API and no feed; this is the same data its front end reads.
BROWSE = "https://itch.io/game-assets/free/{tag}?page={page}&format=json"

#: What this module was written against, and still the default.
TAG_3D = ("tag-3d",)

#[[
#   What a UI hunt walks instead.
#
#   Icons are not one tag. itch.io lets the creator choose, and the same pack
#   of sixty button glyphs is filed under `tag-user-interface` by one author
#   and `tag-icons` by the next -- so hunting a single tag finds a fraction of
#   what is there. These are walked in turn and de-duplicated by pack URL,
#   which is why `discover` takes a sequence rather than a string.
#
#   `tag-2d` is deliberately absent. It is mostly character sprites and
#   tilesets, which are a different job from a button glyph, and it is large
#   enough to drown the result.
#
#   Every tag below was probed before being listed. `tag-ui` is not one of
#   them: it returns HTML rather than JSON, because itch has no such tag and
#   serves a search page instead. That failure is silent in the paginator --
#   the JSON parse raises, the walker logs and moves on -- so an unchecked tag
#   here reads as "that subject has no free packs" rather than as a typo.
#]]
TAGS_UI = (
    "tag-user-interface",
    "tag-icons",
    "tag-gui",
    "tag-buttons",
    "tag-hud",
    "tag-interface",
    "tag-menu",
    "tag-inventory",
)

#: Honest about what this is. A scraper that pretends to be a browser is a
#: scraper whose operator does not want to be asked about it.
AGENT = {"User-Agent": "RQE-asset-evaluation/1.0 (+roblox asset sourcing; contact via itch)"}

#: One request a second. itch.io is a small company hosting other people's work
#: for free; the listing is 36 items a page and there is no hurry.
DELAY = 1.0

#: Anchored on the id, which opens each cell. An earlier version split the
#: fragment on `class="game_cell "` -- but `data-game_id` sits *before* that
#: attribute, so every chunk ended with the next cell's id and began with none
#: of its own. It matched on one page by coincidence and returned zero on the
#: rest, which is the most expensive way for a parser to be wrong.
_CELL_START = re.compile(r'data-game_id="(\d+)"')
#: Anchored on the containing div, with the fields pulled out separately.
#:
#: Attribute order is not stable across pages: one emits
#: `<a href=... class="title">` and the next `<a data-action=... href=...>`.
#: A pattern assuming `href` came first parsed page 1 perfectly and returned
#: nothing for pages 2 and 3 -- which reads as "the listing ended" rather than
#: as a parser fault, and is why it survived a first look.
_TITLE_BLOCK = re.compile(r'class="game_title"[^>]*>(.*?)</div>', re.S)
_HREF = re.compile(r'href="(https://[^"]+)"')
_ANCHOR_TEXT = re.compile(r'>([^<]+)</a>')
_AUTHOR = re.compile(r'class="game_author"[^>]*>\s*<a[^>]*>([^<]+)</a>')
_PRICE = re.compile(r'class="price_value"[^>]*>([^<]+)<')

#: Licence names as creators actually write them, most permissive first. The
#: order matters: a page saying "CC0" and also "CC-BY" for a bonus file should
#: be read as the stricter of the two, so the scan records every hit and the
#: caller decides.
LICENCE_PATTERNS: tuple[tuple[str, str], ...] = (
    ("CC0", r"\bCC0\b|creative commons zero|public domain"),
    ("CC-BY", r"\bCC[\s\-]?BY\b(?![\s\-]*(?:NC|SA|ND))|attribution 4\.0"),
    ("CC-BY-SA", r"\bCC[\s\-]?BY[\s\-]?SA\b"),
    ("CC-BY-NC", r"\bCC[\s\-]?BY[\s\-]?NC\b|non[\s\-]?commercial"),
    ("CC-BY-ND", r"\bCC[\s\-]?BY[\s\-]?ND\b|no derivatives"),
    ("MIT", r"\bMIT licen[cs]e\b"),
    ("OGA-BY", r"\bOGA[\s\-]?BY\b"),
    ("custom", r"licen[cs]e"),
)

#: Phrases that say "not for redistribution" in the words creators use. Any hit
#: is decisive regardless of what licence name is also on the page: a pack that
#: says CC0 and "do not resell or redistribute" is a pack whose author has not
#: read CC0, and the safe reading is theirs.
FORBIDS_REDIST = (
    r"do not redistribut", r"don't redistribut", r"no redistribut",
    r"not for redistribut", r"do not resell", r"don't resell", r"no resell",
    r"personal use only", r"private use only", r"do not reupload",
    r"don't reupload", r"no reupload", r"credit is required",
)


def _get(url: str, timeout: float = 30.0, tries: int = 4) -> bytes:
    """Fetch, waiting out a rate limit rather than treating it as an answer.

    itch.io answers 429 under load, and the paginator's caller cannot tell that
    apart from "the listing ended" -- so one 429 on the first page of a tag
    used to discard the whole tag. It cost `tag-gui` entirely on a live sweep:
    zero packs reported, nothing wrong with the tag.

    Backs off 5, 10, 20 seconds. A 429 is the server asking for less, and the
    right response to being asked for less is to wait, not to retry harder.
    """
    request = urllib.request.Request(url, headers=AGENT)
    pause = 5.0
    for attempt in range(tries):
        try:
            with urllib.request.urlopen(request, timeout=timeout) as response:
                return response.read()
        except urllib.error.HTTPError as error:
            #: 429 and 5xx are worth waiting for. A 404 is an answer.
            if error.code != 429 and error.code < 500:
                raise
            if attempt == tries - 1:
                raise
            time.sleep(pause)
            pause *= 2
    raise urllib.error.URLError(f"gave up on {url} after {tries} tries")


def discover(pages: int = 10, progress: Any = print,
             tags: tuple[str, ...] = TAG_3D) -> list[dict[str, Any]]:
    """Walk the free listings for these tags and return one row per pack.

    Reading only. No pack page is fetched and nothing is downloaded.

    Several tags because a subject is rarely filed under one of them, and
    de-duplicated across all of them by pack URL: the overlap between
    `tag-icons` and `tag-user-interface` is large and a pack counted twice
    would be downloaded twice.

    Each row carries the tag it was found under, because "which listing did
    this come from" is the question asked when a hunt returns something
    unexpected, and it is unanswerable afterwards.
    """
    found: list[dict[str, Any]] = []
    seen: set[str] = set()

    for tag in tags:
        before = len(found)
        _walk(tag, pages, found, seen, progress)
        if len(tags) > 1:
            progress(f"  {tag}: {len(found) - before} new "
                     f"({len(found)} across {tags.index(tag) + 1} tags)")

    return found


def _walk(tag: str, pages: int, found: list[dict[str, Any]],
          seen: set[str], progress: Any) -> None:
    for page in range(1, pages + 1):
        try:
            payload = json.loads(_get(BROWSE.format(tag=tag, page=page)))
        except (urllib.error.URLError, OSError, json.JSONDecodeError) as error:
            progress(f"  {tag} page {page}: {error}")
            break

        content = payload.get("content") or ""
        starts = [m for m in _CELL_START.finditer(content)]
        added = 0
        for index, start in enumerate(starts):
            end = starts[index + 1].start() if index + 1 < len(starts) else len(content)
            cell = content[start.start():end]

            block = _TITLE_BLOCK.search(cell)
            if not block:
                continue
            anchor = block.group(1)
            href = _HREF.search(anchor)
            text = _ANCHOR_TEXT.search(anchor)
            if not href or not text:
                continue

            url = href.group(1)
            if url in seen:
                continue
            seen.add(url)

            author = _AUTHOR.search(cell)
            price = _PRICE.search(cell)
            found.append({
                "id": start.group(1),
                "title": unescape(text.group(1)).strip(),
                "url": url,
                "author": unescape(author.group(1)).strip() if author else None,
                #: Absent means free outright; a value means "name your price",
                #: which is still downloadable at zero but is somebody asking.
                "suggestedPrice": unescape(price.group(1)).strip() if price else None,
                "tag": tag,
            })
            added += 1

        progress(f"  {tag} page {page}: {added} packs ({len(found)} total)")
        if payload.get("num_items", 0) == 0:
            break
        time.sleep(DELAY)


def read_licence(text: str) -> dict[str, Any]:
    """What a pack page says about licensing, and how sure that is.

    Returns every licence name matched rather than the first, because a page
    naming two is a page that needs a person, and collapsing it to one would
    hide exactly the case worth escalating.
    """
    lowered = text.lower()
    names = [name for name, pattern in LICENCE_PATTERNS
             if re.search(pattern, lowered, re.I)]
    forbids = [phrase for phrase in FORBIDS_REDIST
               if re.search(phrase, lowered, re.I)]

    #: "custom" only counts when nothing specific matched -- it is the word
    #: "license" appearing at all, which is a hint that terms exist and not a
    #: statement of what they are.
    specific = [n for n in names if n != "custom"]
    if specific:
        names = specific

    if forbids:
        verdict = "forbids-redistribution"
    elif names == ["CC0"]:
        verdict = "cc0"
    elif specific:
        verdict = "needs-reading"
    elif "custom" in names:
        verdict = "terms-present-unread"
    else:
        verdict = "unstated"

    return {
        "verdict": verdict,
        "names": names,
        "forbids": forbids,
        #: What a person should read, so the judgement can be checked rather
        #: than trusted.
        "quotes": _quotes(text, names, forbids),
    }


def _quotes(text: str, names: list[str], forbids: list[str]) -> list[str]:
    """The sentences the verdict was drawn from, trimmed."""
    out: list[str] = []
    sentences = re.split(r"(?<=[.!?])\s+|\n+", text)
    wanted = [p for _, p in LICENCE_PATTERNS if any(
        n for n in names)] + list(forbids)
    for sentence in sentences:
        stripped = sentence.strip()
        if not stripped or len(stripped) > 240:
            continue
        if any(re.search(pattern, stripped, re.I) for pattern in wanted):
            out.append(stripped)
        if len(out) >= 4:
            break
    return out


def inspect(pack: dict[str, Any], timeout: float = 30.0) -> dict[str, Any]:
    """Fetch one pack's page and read its terms. Still no download."""
    try:
        html = _get(pack["url"], timeout=timeout).decode("utf-8", "replace")
    except (urllib.error.URLError, OSError) as error:
        return {**pack, "licence": {"verdict": "unreachable",
                                    "names": [], "forbids": [],
                                    "quotes": [str(error)[:120]]}}

    #: Strip tags before reading prose. A licence stated inside a link's title
    #: attribute is still a statement, and matching raw HTML finds it twice.
    text = re.sub(r"<script.*?</script>|<style.*?</style>", " ", html, flags=re.S)
    text = re.sub(r"<[^>]+>", " ", text)
    text = re.sub(r"\s+", " ", text)

    #: What formats it ships, which decides whether it is usable at all.
    formats = sorted({fmt for fmt in
                      ("fbx", "obj", "gltf", "glb", "blend", "dae", "stl", "ply")
                      if re.search(rf"\.{fmt}\b", text, re.I)})

    return {**pack, "licence": read_licence(text), "formats": formats}


def catalogue(pages: int = 20, inspect_all: bool = True,
              progress: Any = print, tags: tuple[str, ...] = TAG_3D,
              out: Path | None = None) -> dict[str, Any]:
    """Discover free packs under these tags and read what each one permits.

    Two passes because they cost differently: the listing is one request per 36
    packs, and reading terms is one request per pack. Both are paced.

    `out` keeps hunts apart. A UI sweep written over `itch-assets.json` would
    destroy the 3D catalogue that 295 published models were selected from, and
    "the file the last run happened to write" is not a thing to build on.
    """
    packs = discover(pages=pages, progress=progress, tags=tags)
    progress(f"\n{len(packs)} packs found; reading terms")

    rows: list[dict[str, Any]] = []
    for index, pack in enumerate(packs, start=1):
        rows.append(inspect(pack) if inspect_all else pack)
        if index % 25 == 0:
            progress(f"  {index}/{len(packs)}")
        time.sleep(DELAY)

    by_verdict: dict[str, int] = {}
    for row in rows:
        verdict = (row.get("licence") or {}).get("verdict", "unread")
        by_verdict[verdict] = by_verdict.get(verdict, 0) + 1

    book = {
        "$comment": (
            "Free 3D asset packs on itch.io with what each page says about "
            "licensing. `verdict` cc0 means the page names CC0 and nothing "
            "contradicts it; forbids-redistribution means the page uses words "
            "that rule out republishing whatever licence it also names; "
            "needs-reading and terms-present-unread both mean a person must "
            "look. Free to download is not free to republish, and uploading a "
            "mesh to Roblox's Creator Store is republishing."),
        "collectedAt": time.strftime("%Y-%m-%d"),
        "tags": list(tags),
        "packs": rows,
        "count": len(rows),
        "byVerdict": by_verdict,
    }
    destination = Path(out) if out else CATALOGUE
    destination.parent.mkdir(parents=True, exist_ok=True)
    destination.write_text(json.dumps(book, indent=1, ensure_ascii=False) + "\n",
                           encoding="utf-8")
    return book


# ============================== fetching ====================================
#[[
#   The download path, and why it is not the documented one.
#
#   itch.io's published server-side API is scoped to the key owner: profile,
#   your own games, your own purchases. Read at face value it says bulk
#   downloading other people's packs is impossible, and that conclusion was
#   drawn here and was wrong.
#
#   The API the desktop client uses lives on the same host and answers the same
#   key. `/games/{id}/uploads` lists a pack's files with sizes and hashes, and
#   `/uploads/{id}/download` hands back a signed URL. Measured, not inferred:
#   13,024,345 bytes of real zip came back on the first try.
#
#   Two details make the difference between working and a confusing 403:
#
#     * **Do not follow the redirect with the key attached.** The target is a
#       signed R2 URL, and forwarding `Authorization: <itch key>` makes S3 try
#       to parse it as an AWS signature -- which fails as
#       "Missing x-amz-content-sha256", an error about the wrong thing entirely.
#
#     * **The signature is for GET and lasts 60 seconds.** A HEAD against it is
#       403, so a size probe has to come from the uploads listing rather than
#       from the file itself.
#]]

UPLOADS = "https://api.itch.io/games/{game}/uploads"
DOWNLOAD = "https://api.itch.io/uploads/{upload}/download"


def _key(path: Path | None = None) -> str:
    source = Path(path) if path else Path(".secrets/itch-api.key")
    if not source.is_file():
        raise RuntimeError(
            f"no itch API key at {source}; generate one at itch.io/user/settings/api-keys")
    return source.read_text(encoding="utf-8").strip()


class _NoRedirect(urllib.request.HTTPRedirectHandler):
    """Surface the redirect instead of following it, so the key is not forwarded."""

    def redirect_request(self, req, fp, code, msg, headers, newurl):
        raise urllib.error.HTTPError(req.full_url, code, newurl, headers, fp)


def _authed(url: str, key: str, timeout: float = 30.0) -> Any:
    request = urllib.request.Request(
        url, headers={"Authorization": key, **AGENT})
    with urllib.request.urlopen(request, timeout=timeout) as response:
        return json.load(response)


def uploads(game_id: str | int, key: str, timeout: float = 30.0) -> list[dict[str, Any]]:
    """Every file a pack offers, with size and hash. No download."""
    try:
        payload = _authed(UPLOADS.format(game=game_id), key, timeout)
    except (urllib.error.HTTPError, urllib.error.URLError, OSError):
        return []
    return payload.get("uploads") or []


def measure(packs: list[dict[str, Any]], key: str | None = None,
            progress: Any = print) -> dict[str, Any]:
    """How much disk this would cost, without spending any of it.

    Worth its own pass. 360 packs is somewhere between a gigabyte and twenty
    depending on what is in them, and that is a number to see before it lands
    rather than after.
    """
    token = key or _key()
    rows: list[dict[str, Any]] = []
    total = 0

    for index, pack in enumerate(packs, start=1):
        files = uploads(pack["id"], token)
        #: Only what is actually free. A pack can carry a paid upload beside a
        #: demo, and `demo` marks the ones that are not the real thing.
        free = [f for f in files if not f.get("demo")]
        size = sum(int(f.get("size") or 0) for f in free)
        total += size
        rows.append({**pack, "uploads": [
            {"id": f["id"], "filename": f.get("filename"),
             "displayName": f.get("display_name"),
             "size": f.get("size"), "md5": f.get("md5_hash")}
            for f in free]})
        if index % 25 == 0:
            progress(f"  {index}/{len(packs)}  {total / 1e9:.2f} GB so far")
        time.sleep(DELAY)

    return {"packs": rows, "bytes": total, "gigabytes": round(total / 1e9, 2),
            "files": sum(len(r["uploads"]) for r in rows)}


def fetch_upload(upload_id: int | str, destination: Path, key: str,
                 timeout: float = 300.0) -> int:
    """Download one file. Returns bytes written."""
    opener = urllib.request.build_opener(_NoRedirect)
    request = urllib.request.Request(
        DOWNLOAD.format(upload=upload_id),
        headers={"Authorization": key, **AGENT})

    target: str | None = None
    try:
        opener.open(request, timeout=timeout)
    except urllib.error.HTTPError as error:
        if error.code in (301, 302, 303, 307, 308):
            target = str(error.reason)
        else:
            raise
    if not target:
        raise RuntimeError(f"upload {upload_id}: no download redirect")

    #: Clean request. The signed URL carries its own authorisation and the itch
    #: key would be misread as an AWS one.
    written = 0
    destination.parent.mkdir(parents=True, exist_ok=True)
    plain = urllib.request.Request(target, headers=AGENT)
    with urllib.request.urlopen(plain, timeout=timeout) as response:
        with destination.open("wb") as handle:
            while True:
                chunk = response.read(1 << 16)
                if not chunk:
                    break
                handle.write(chunk)
                written += len(chunk)
    return written
