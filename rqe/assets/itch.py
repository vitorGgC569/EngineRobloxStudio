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
BROWSE = "https://itch.io/game-assets/free/tag-3d?page={page}&format=json"

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


def _get(url: str, timeout: float = 30.0) -> bytes:
    request = urllib.request.Request(url, headers=AGENT)
    with urllib.request.urlopen(request, timeout=timeout) as response:
        return response.read()


def discover(pages: int = 10, progress: Any = print) -> list[dict[str, Any]]:
    """Walk the free 3D listing and return one row per pack.

    Reading only. No pack page is fetched and nothing is downloaded.
    """
    found: list[dict[str, Any]] = []
    seen: set[str] = set()

    for page in range(1, pages + 1):
        try:
            payload = json.loads(_get(BROWSE.format(page=page)))
        except (urllib.error.URLError, OSError, json.JSONDecodeError) as error:
            progress(f"  page {page}: {error}")
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
            })
            added += 1

        progress(f"  page {page}: {added} packs ({len(found)} total)")
        if payload.get("num_items", 0) == 0:
            break
        time.sleep(DELAY)

    return found


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
              progress: Any = print) -> dict[str, Any]:
    """Discover free 3D packs and read what each one permits.

    Two passes because they cost differently: the listing is one request per 36
    packs, and reading terms is one request per pack. Both are paced.
    """
    packs = discover(pages=pages, progress=progress)
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
        "packs": rows,
        "count": len(rows),
        "byVerdict": by_verdict,
    }
    CATALOGUE.parent.mkdir(parents=True, exist_ok=True)
    CATALOGUE.write_text(json.dumps(book, indent=1, ensure_ascii=False) + "\n",
                         encoding="utf-8")
    return book
