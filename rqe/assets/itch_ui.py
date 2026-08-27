"""Turn downloaded UI packs into published Roblox images, with provenance intact.

Why this is not the mesh publisher with a different suffix
----------------------------------------------------------

A mesh pack ships one file per object. A UI pack ships a **sprite sheet**: one
1024x1024 PNG with ninety icons laid out on a grid, and often nothing else. The
individual icons exist only as regions of that image.

Roblox can use a sheet directly -- `ImageLabel.ImageRectOffset` and
`ImageRectSize` crop one cell out of one uploaded image -- and that is the
better outcome anyway: ninety icons as one asset is one HTTP fetch and one
texture, against ninety of each. So the job here is not "find the loose PNGs",
it is:

  * upload the sheet as one `Decal`,
  * work out the grid,
  * and record the offset and size of every cell, so a caller asks for
    `ui.close` and gets an image plus a rectangle.

Working out the grid is the hard part and this does not guess it. A sheet whose
cell size is unknown produces a catalogue entry with the sheet and no cells,
which is honest and still useful -- a person can read the number off the pack
page in ten seconds. Guessing produces a UI where every icon is a quarter of
the next one, which is worse than nothing because it looks deliberate.

What gets uploaded
------------------

`Decal` is the assetType. Roblox re-encodes on upload; PNG with alpha survives,
which is the whole point for an icon.

Loose icons are still preferred where a pack ships them, because a cell of a
sheet can only be as good as the grid detection and a loose file needs none.
"""

from __future__ import annotations

import json
import os
import struct
import time
import urllib.error
import urllib.request
import zipfile
from pathlib import Path
from typing import Any

from . import local_credentials
from .itch_publish import (ASSETS_URL, OPERATION_URL, _await_operation,
                           _multipart, _post)

ROOT = Path("assets/itch-ui")
INVENTORY = Path("forge/kits/itch-ui-inventory.json")
PUBLISHED = Path("forge/kits/itch-ui-published.json")
LUA_PATH = Path("forge/luau/Forge/UI/ItchIcons.lua")

#: Open Cloud takes these as `Decal`. No `.svg`: Roblox does not accept vector
#: art, and no `.psd` or `.aseprite`, which are source formats a pack ships
#: beside its exports.
UPLOADABLE = (".png", ".jpg", ".jpeg")

DELAY = 2.0

#: Roblox rejects images above this. Recorded rather than attempted.
MAX_BYTES = 20 * 1024 * 1024

#: Roblox downsamples anything larger, and a downsampled sheet has cells that
#: no longer land on integer boundaries -- which turns a crisp 16px glyph into
#: a blurred one with a slice of its neighbour along the edge.
MAX_EDGE = 1024

#: Below this an image is a fragment, a divider or a one-pixel spacer.
MIN_EDGE = 16


# ------------------------------------------------------------------ measuring

def _png_size(head: bytes) -> tuple[int, int] | None:
    """Width and height from a PNG header, without decoding the image.

    The IHDR chunk is fixed at bytes 16..24 of every PNG, so eight bytes read
    from the front of the file answers this. Pillow would too, and would also
    decode a 4096x4096 sheet into sixty megabytes of pixels to tell us its
    shape -- across thousands of files inside zips that is the difference
    between a minute and an afternoon.
    """
    if len(head) < 24 or head[:8] != b"\x89PNG\r\n\x1a\n":
        return None
    if head[12:16] != b"IHDR":
        return None
    width, height = struct.unpack(">II", head[16:24])
    return int(width), int(height)


def _jpeg_size(data: bytes) -> tuple[int, int] | None:
    """Width and height from a JPEG's first frame header."""
    if data[:2] != b"\xff\xd8":
        return None
    index = 2
    while index + 9 < len(data):
        if data[index] != 0xFF:
            index += 1
            continue
        marker = data[index + 1]
        #: SOF0..SOF15, skipping the four that are not frame headers.
        if 0xC0 <= marker <= 0xCF and marker not in (0xC4, 0xC8, 0xCC):
            height, width = struct.unpack(">HH", data[index + 5:index + 9])
            return int(width), int(height)
        if index + 4 > len(data):
            break
        index += 2 + struct.unpack(">H", data[index + 2:index + 4])[0]
    return None


def image_size(data: bytes) -> tuple[int, int] | None:
    return _png_size(data) or _jpeg_size(data)


# ------------------------------------------------------------------ inventory

def inventory(root: Path = ROOT, progress: Any = print) -> dict[str, Any]:
    """Every uploadable image inside every downloaded UI pack, measured.

    Reads each zip's directory and then the first 32 bytes of each image, which
    is enough for its dimensions. Nothing is extracted: these packs are small
    individually and there are hundreds of them.
    """
    manifest_path = root / "manifest.json"
    provenance: dict[str, Any] = {}
    if manifest_path.exists():
        try:
            for record in (json.loads(manifest_path.read_text(encoding="utf-8"))
                           .get("files") or {}).values():
                if record.get("path"):
                    provenance[str(Path(record["path"]))] = record
        except (OSError, json.JSONDecodeError):
            pass

    images: list[dict[str, Any]] = []
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
                    if info.file_size == 0 or info.file_size > MAX_BYTES:
                        continue
                    #: A pack's own store art, not its contents.
                    lowered = info.filename.lower()
                    if any(word in lowered for word in
                           ("preview", "screenshot", "banner", "cover",
                            "thumbnail", "promo", "__macosx")):
                        continue

                    try:
                        with bundle.open(info) as handle:
                            head = handle.read(4096)
                    except (zipfile.BadZipFile, OSError, RuntimeError):
                        continue
                    size = image_size(head)
                    if not size:
                        continue

                    images.append({
                        "archive": str(archive),
                        "member": info.filename,
                        "stem": member.stem,
                        "suffix": member.suffix.lower(),
                        "bytes": info.file_size,
                        "width": size[0],
                        "height": size[1],
                        "pack": source.get("pack") or archive.parent.name,
                        "author": source.get("author") or archive.parent.parent.name,
                        "url": source.get("url"),
                        "licence": source.get("licence") or "unread",
                    })
        except (zipfile.BadZipFile, OSError) as error:
            progress(f"  ! {archive.name}: {error}")
            continue
        if index % 25 == 0:
            progress(f"  {index}/{len(archives)} packs, {len(images)} images")

    book = {
        "$comment": (
            "Uploadable images inside the downloaded UI packs, measured from "
            "each file's header without decoding it. Store art (previews, "
            "banners, covers) is excluded: it is the pack's advertising, not "
            "its contents, and republishing it is not what the licence "
            "covers."),
        "images": images,
        "count": len(images),
        "archives": len(archives),
    }
    INVENTORY.parent.mkdir(parents=True, exist_ok=True)
    INVENTORY.write_text(json.dumps(book, indent=1, ensure_ascii=False) + "\n",
                         encoding="utf-8")
    return book


# ------------------------------------------------------------------ shape

def shape(image: dict[str, Any]) -> str:
    """What kind of image this is, by its dimensions and its path.

    Three answers, and they are handled differently downstream:

      * `icon` -- small and roughly square. Upload as is, use whole.
      * `sheet` -- large, and usually a multiple of a small cell. Upload once
        and crop cells out of it.
      * `panel` -- a nine-slice frame, a bar, a long banner. Useful, but its
        rectangle is meaningful and it cannot be treated as either of the
        other two.
    """
    width, height = image["width"], image["height"]
    if width < MIN_EDGE or height < MIN_EDGE:
        return "fragment"

    longest, shortest = max(width, height), min(width, height)
    ratio = longest / max(shortest, 1)

    if longest <= 128 and ratio <= 1.35:
        return "icon"
    if longest >= 256 and ratio <= 2.2:
        return "sheet"
    if ratio > 2.2:
        return "panel"
    return "icon" if longest <= 192 else "sheet"


def grid(image: dict[str, Any], cells: tuple[int, ...] = (16, 24, 32, 48, 64)
         ) -> dict[str, Any] | None:
    """The cell size of a sprite sheet, when it can be established.

    Only when both edges divide exactly by the same candidate and the result is
    a plausible number of cells. That is a weak test and it is meant to be: it
    answers for the common case -- a 512x512 sheet of 32px icons -- and returns
    nothing for anything irregular rather than inventing a grid.

    A wrong grid is worse than no grid. No grid leaves an unusable sheet that
    somebody notices; a wrong one produces a UI where every icon shows a
    quarter of itself and a sliver of its neighbour, and *looks* deliberate.
    """
    #: Only for images big enough to hold a grid. Without this a 32x32 icon
    #: divides by 16 and comes back as "four cells of 16px", which is true
    #: arithmetic about a single icon and would slice it into quarters.
    if shape(image) in ("icon", "fragment"):
        return None

    width, height = image["width"], image["height"]
    best: dict[str, Any] | None = None
    for cell in cells:
        if width % cell or height % cell:
            continue
        across, down = width // cell, height // cell
        if across < 2 and down < 2:
            continue
        if across * down > 1024:
            continue
        #: Larger cells first: a 512px sheet divides by 16 and by 64, and the
        #: 64 reading is right far more often than the 8x8=64-cell alternative.
        best = {"cell": cell, "across": across, "down": down,
                "cells": across * down}
    return best


# ------------------------------------------------------------------ meaning

#[[
#   What a UI needs, as tokens, with the words a filename uses for each.
#
#   Keyed the way `Forge.UI.VisualIcons` already keys its registry --
#   `group.name` -- because that registry exists, has nine tokens, and every
#   one of them points at `rbxassetid://0`. Filling it is the point of this
#   file, and inventing a second vocabulary beside it would leave two.
#
#   Grouped by what a player does, not by what the picture shows. `action.buy`
#   and `economy.coin` are both money and they are not interchangeable: one
#   goes on a button and one goes next to a number.
#]]
TOKENS: dict[str, tuple[str, ...]] = {
    # getting around
    "nav.home": ("home", "house"),
    "nav.shop": ("shop", "store", "market", "cart", "basket"),
    "nav.settings": ("settings", "setting", "gear", "cog", "options", "config"),
    "nav.inventory": ("inventory", "backpack", "bag", "satchel", "pouch"),
    "nav.map": ("map", "compass", "globe", "world"),
    "nav.quest": ("quest", "mission", "scroll", "objective", "journal"),
    "nav.leaderboard": ("leaderboard", "ranking", "podium", "chart"),
    "nav.back": ("back", "return", "exit"),
    "nav.menu": ("menu", "hamburger", "burger", "list"),

    # doing something
    "action.close": ("close", "cross", "x", "cancel", "dismiss"),
    "action.confirm": ("confirm", "check", "checkmark", "tick", "accept", "ok",
                       "yes", "done"),
    "action.play": ("play", "start", "begin", "resume"),
    "action.pause": ("pause",),
    "action.stop": ("stop", "square"),
    "action.next": ("next", "forward", "right", "arrowright", "skip"),
    "action.previous": ("previous", "prev", "left", "arrowleft"),
    "action.up": ("up", "arrowup", "top"),
    "action.down": ("down", "arrowdown", "bottom"),
    "action.add": ("add", "plus", "new", "create"),
    "action.remove": ("remove", "minus", "subtract"),
    "action.delete": ("delete", "trash", "bin", "garbage"),
    "action.edit": ("edit", "pencil", "pen", "write"),
    "action.search": ("search", "magnifier", "magnify", "find", "zoom"),
    "action.refresh": ("refresh", "reload", "reset", "restart", "sync"),
    "action.save": ("save", "disk", "floppy", "download"),
    "action.share": ("share", "invite", "link"),
    "action.upgrade": ("upgrade", "levelup", "enhance", "boost", "arrowsup"),
    "action.buy": ("buy", "purchase", "shopping"),
    "action.equip": ("equip", "wear", "slot"),

    # money and rewards
    "economy.coin": ("coin", "coins", "gold", "money", "currency"),
    "economy.gem": ("gem", "gems", "diamond", "crystal", "jewel"),
    "economy.cash": ("cash", "bill", "banknote", "dollar", "wallet"),
    "economy.ticket": ("ticket", "token", "voucher", "pass"),
    "economy.chest": ("chest", "crate", "lootbox", "loot"),
    "economy.gift": ("gift", "present", "reward", "box"),
    "economy.key": ("key", "keys"),

    # how things are going
    "status.error": ("error", "fail", "danger", "alert", "exclamation"),
    "status.success": ("success", "complete", "completed", "finished"),
    "status.warning": ("warning", "caution", "attention"),
    "status.info": ("info", "information", "question", "help", "hint"),
    "status.lock": ("lock", "locked", "padlock"),
    "status.unlock": ("unlock", "unlocked", "open"),
    "status.health": ("health", "heart", "hp", "life", "lives"),
    "status.energy": ("energy", "stamina", "lightning", "bolt", "battery"),
    "status.mana": ("mana", "magic", "mp"),
    "status.star": ("star", "stars", "favourite", "favorite"),
    "status.trophy": ("trophy", "cup", "award"),
    "status.medal": ("medal", "badge", "ribbon"),
    "status.timer": ("timer", "clock", "time", "hourglass", "stopwatch"),
    "status.xp": ("xp", "exp", "experience"),

    # fighting
    "combat.sword": ("sword", "blade", "attack"),
    "combat.shield": ("shield", "defence", "defense", "block", "guard"),
    "combat.bow": ("bow", "arrow", "archery"),
    "combat.potion": ("potion", "flask", "elixir", "vial"),
    "combat.armor": ("armor", "armour", "helmet", "helm"),
    "combat.speed": ("speed", "boots", "haste", "run"),
    "combat.skull": ("skull", "death", "dead", "poison"),

    # people
    "social.chat": ("chat", "message", "speech", "bubble", "talk"),
    "social.mail": ("mail", "envelope", "inbox", "letter"),
    "social.notification": ("notification", "bell", "alarm"),
    "social.profile": ("profile", "player", "avatar", "person", "user"),
    "social.group": ("group", "party", "team", "guild", "clan", "friends"),

    # the machine
    "media.soundOn": ("soundon", "volumeon", "unmute", "speaker", "audio"),
    "media.soundOff": ("soundoff", "volumeoff", "mute", "muted"),
    "media.music": ("music", "note", "melody"),
    "media.fullscreen": ("fullscreen", "expand", "maximize", "maximise"),
    "media.camera": ("camera", "photo", "screenshot", "picture"),
}


def classify(stem: str) -> str | None:
    """Which UI token a filename names, or None.

    Whole words first, substrings only as a fallback -- and that order is not
    a preference, it is a bug fixed twice already in this repository. Plain
    substring matching over filenames files `street lamp` under `tree`
    (s-TREE-t) and `carpet` under `pet`, silently, and the wrong answer looks
    exactly like a right one.

    A filename is words separated by punctuation and case changes, so
    `icon_arrowRight_02` is split into `icon arrow right 02` before matching.
    Without the case split, `arrowRight` is one unknown word and the icon is
    unclassifiable.
    """
    words = _words(stem)
    if not words:
        return None
    present = set(words)

    #: Longest term wins, not first in the table. `trophy_gold` matched both
    #: `gold` (economy.coin) and `trophy` (status.trophy) and took whichever
    #: dict order reached first -- a trophy filed as a coin. The longer term is
    #: the subject; the shorter one is usually a colour or a material.
    best: tuple[int, str] | None = None
    for token, terms in TOKENS.items():
        for term in terms:
            if term in present and (best is None or len(term) > best[0]):
                best = (len(term), token)
    if best:
        return best[1]

    #: Compound names arrive welded: `soundoff`, `arrowright`, `lootbox`.
    #: Joined in the filename's own order -- an earlier version joined a *set*,
    #: so whether `soundOff` matched `soundoff` depended on set iteration and
    #: changed between runs.
    joined = "".join(words)
    for token, terms in TOKENS.items():
        for term in terms:
            #: Three letters is not evidence: `x`, `ok`, `hp`, `up` appear
            #: inside half the words in English and are only trustworthy whole.
            if len(term) > 3 and term in joined:
                if best is None or len(term) > best[0]:
                    best = (len(term), token)
    return best[1] if best else None


def _words(stem: str) -> list[str]:
    """A filename's words, in order, split on punctuation and on caseChanges.

    Without the case split `arrowRight` is one unknown word and the icon is
    unclassifiable; with it, `arrow` and `right` both land.
    """
    out = []
    for index, char in enumerate(stem):
        if char.isupper() and index > 0 and stem[index - 1].islower():
            out.append(" ")
        out.append(char.lower() if char.isalnum() else " ")
    return [w for w in "".join(out).split() if w]


# ------------------------------------------------------------------ selecting

def select(images: list[dict[str, Any]], per_token: int = 3,
           sheets_per_pack: int = 2, progress: Any = print) -> list[dict[str, Any]]:
    """What to upload, and in what order.

    Two kinds of value, and they are not comparable:

      * A **loose icon that classifies** is directly usable. A game asks for
        `action.close` and gets exactly that. These are taken first and capped
        per token, because the fourth close button adds nothing.

      * A **sheet** is dozens of icons for one upload and one texture fetch,
        which is the cheaper thing at runtime by a wide margin -- but only
        addressable by cell index until somebody labels it. Capped per pack so
        one generous author cannot fill the account.

    Panels and fragments are skipped. A nine-slice frame is genuinely useful
    and needs its slice insets recorded to be used at all; publishing it
    without them produces a stretched blur, so it waits for a pass that can
    measure them.
    """
    for image in images:
        image["shape"] = shape(image)
        image["topic"] = classify(image["stem"])
        if image["shape"] == "sheet":
            image["grid"] = grid(image)

    chosen: list[dict[str, Any]] = []
    by_token: dict[str, int] = {}
    by_pack: dict[str, int] = {}

    icons = [i for i in images
             if i["shape"] == "icon" and i["topic"]
             and i["width"] <= MAX_EDGE and i["height"] <= MAX_EDGE]
    #: PNG before JPEG: an icon needs transparency and a JPEG has none, so a
    #: JPEG icon arrives with a white box around it.
    icons.sort(key=lambda i: (i["topic"], i["suffix"] != ".png", -i["width"]))
    for image in icons:
        token = image["topic"]
        if by_token.get(token, 0) >= per_token:
            continue
        by_token[token] = by_token.get(token, 0) + 1
        chosen.append(image)

    sheets = [i for i in images
              if i["shape"] == "sheet" and i.get("grid")
              and i["suffix"] == ".png"
              and i["width"] <= MAX_EDGE and i["height"] <= MAX_EDGE]
    #: Most cells first: the sheet that carries ninety icons is worth more than
    #: the one carrying four, and they cost the same to upload.
    sheets.sort(key=lambda i: -(i["grid"] or {}).get("cells", 0))
    for image in sheets:
        pack = str(image.get("pack") or image["archive"])
        if by_pack.get(pack, 0) >= sheets_per_pack:
            continue
        by_pack[pack] = by_pack.get(pack, 0) + 1
        chosen.append(image)

    cells = sum((i.get("grid") or {}).get("cells", 0)
                for i in chosen if i["shape"] == "sheet")
    progress(f"  {len(chosen)} selected: "
             f"{sum(1 for i in chosen if i['shape'] == 'icon')} loose icons "
             f"across {len(by_token)} tokens, "
             f"{sum(1 for i in chosen if i['shape'] == 'sheet')} sheets "
             f"holding about {cells} cells")
    return chosen


# ------------------------------------------------------------------ publish

def publish(chosen: list[dict[str, Any]], creator_user_id: str = "5812220258",
            delay: float = DELAY, progress: Any = print) -> dict[str, Any]:
    """Upload each selected image as a Roblox Decal. Resumable.

    The manifest is written after every upload, not at the end. A run that
    records only on success loses everything it did when the session drops, and
    that has already happened once in this repository to a sweep that got 112
    assets in.
    """
    local_credentials.load()
    key = os.environ.get(local_credentials.ENV_VAR, "")
    if not key:
        raise RuntimeError("no Roblox Open Cloud credential")

    book: dict[str, Any] = {"assets": {}}
    if PUBLISHED.exists():
        try:
            book = json.loads(PUBLISHED.read_text(encoding="utf-8"))
            book.setdefault("assets", {})
        except (OSError, json.JSONDecodeError):
            book = {"assets": {}}

    uploaded = failed = skipped = 0
    started = time.time()

    for index, image in enumerate(chosen, start=1):
        marker = f"{Path(image['archive']).name}::{image['member']}"
        recorded = book["assets"].get(marker) or {}
        if recorded.get("assetId"):
            skipped += 1
            continue
        if _terminal(recorded):
            skipped += 1
            continue

        try:
            with zipfile.ZipFile(image["archive"]) as bundle:
                content = bundle.read(image["member"])
        except (zipfile.BadZipFile, OSError, KeyError) as error:
            book["assets"][marker] = {"error": str(error)[:160], **_provenance(image)}
            failed += 1
            continue

        payload = {
            "assetType": "Decal",
            "displayName": _display_name(image),
            "description": _description(image),
            "creationContext": {
                "creator": {"userId": str(creator_user_id)},
                #: Roblox requires this on every asset; the packs selected here
                #: are CC0, so the honest answer is that no separate licence
                #: applies to the upload.
                "expectedPrice": 0,
            },
        }
        body, boundary = _multipart(
            payload, Path(image["member"]).name, content,
            "image/png" if image["suffix"] == ".png" else "image/jpeg")

        try:
            operation = _post(body, boundary, key)
        except urllib.error.HTTPError as error:
            detail = error.read().decode("utf-8", errors="replace")
            book["assets"][marker] = {
                "error": f"HTTP {error.code}: {detail[:200]}", **_provenance(image)}
            failed += 1
            progress(f"  ! {image['stem'][:30]}: HTTP {error.code}")
            _write(book, uploaded, failed, skipped, started)
            time.sleep(delay)
            continue
        except (urllib.error.URLError, OSError) as error:
            book["assets"][marker] = {"error": str(error)[:160], **_provenance(image)}
            failed += 1
            time.sleep(delay)
            continue

        state = _await_operation(operation.get("operationId") or "", key)
        asset = (state.get("response") or {})
        asset_id = asset.get("assetId")
        if asset_id:
            book["assets"][marker] = {
                "assetId": asset_id,
                "displayName": payload["displayName"],
                **_provenance(image),
            }
            uploaded += 1
        else:
            #: The reason Roblox gave, not a summary of it. An earlier version
            #: recorded "operation did not resolve" while the response carried
            #: "Failed to parse the uploaded file" -- it fetched the reason and
            #: threw it away.
            reason = ((state.get("error") or {}).get("message")
                      or state.get("error") or "operation did not resolve")
            book["assets"][marker] = {"error": str(reason)[:200], **_provenance(image)}
            failed += 1
            progress(f"  ! {image['stem'][:30]}: {str(reason)[:60]}")

        _write(book, uploaded, failed, skipped, started)
        if index % 20 == 0:
            progress(f"  {index}/{len(chosen)}  {uploaded} up, {failed} failed")
        time.sleep(delay)

    return _write(book, uploaded, failed, skipped, started)


TERMINAL_ERRORS = ("failed to parse", "unreadable", "too large",
                   "no image content", "moderat", "http 400")


def _terminal(record: dict[str, Any]) -> bool:
    """Whether a recorded failure is worth retrying.

    Without this, a follow loop retries the same four permanently-broken files
    every round forever. That happened: ninety rounds after the work finished.
    """
    reason = str(record.get("error") or "").lower()
    return any(word in reason for word in TERMINAL_ERRORS)


def _provenance(image: dict[str, Any]) -> dict[str, Any]:
    return {
        "member": image["member"],
        "pack": image.get("pack"),
        "author": image.get("author"),
        "url": image.get("url"),
        "licence": image.get("licence"),
        "width": image.get("width"),
        "height": image.get("height"),
        "shape": image.get("shape") or shape(image),
        "grid": image.get("grid"),
        "topic": image.get("topic"),
    }


def _display_name(image: dict[str, Any]) -> str:
    stem = "".join(c if c.isalnum() or c in " -_" else " "
                   for c in image["stem"]).replace("_", " ").strip()
    return (stem[:44] or "Icon").title()


def _description(image: dict[str, Any]) -> str:
    pack = image.get("pack") or "an itch.io pack"
    author = image.get("author") or "unknown"
    return (f"UI art from '{pack}' by {author} on itch.io, published under "
            f"CC0. {image.get('width')}x{image.get('height')}.")[:900]


_HEADER = '''--!strict
--[[
	ItchIcons — CC0 UI art published to this account, keyed by what it is for.

	Generated by `rqe.assets.itch_ui`; rewritten on every export. Do not edit.

	Two kinds of entry, and the difference matters at the call site.

	A **whole** entry is one image that is one icon. Point an `ImageLabel` at
	it and you are done.

	A **cell** entry is one rectangle of a sprite sheet -- most UI packs ship
	ninety icons as a single PNG, and Roblox crops one out with
	`ImageRectOffset` and `ImageRectSize`. That is the better shape anyway: one
	asset, one texture, one fetch, instead of ninety of each.

	`apply` handles both, which is why it exists and why UI code should call it
	rather than reading `.image` and assigning it. Reading the id alone works
	for a whole entry and silently shows the entire sheet for a cell one.

		local Icons = Forge.UI.ItchIcons
		Icons.apply(button.Icon, "action.close")

	Sheets whose grid could not be established are here with `cells = 0`. They
	are usable as a whole image and not as icons, and that is recorded rather
	than guessed: a wrong grid shows every icon as a quarter of itself plus a
	sliver of its neighbour, and looks deliberate.

	%(whole)d whole icons across %(tokens)d tokens, and %(sheets)d sheets
	holding %(cells)d cells. Published %(when)s.
]]

local ItchIcons = {}

export type Entry = {
	token: string?, id: number, kind: string,
	width: number, height: number,
	cell: number?, across: number?, down: number?,
	pack: string, author: string,
}

ItchIcons.entries = ({
%(entries)s
} :: any) :: { Entry }
'''

_FOOTER = '''
local byToken: { [string]: Entry } = {}
for _, entry in ItchIcons.entries do
	if entry.token and not byToken[entry.token] then
		byToken[entry.token] = entry
	end
end

--: What a caller needs to show one icon: the image, and the rectangle of it to
--: show. A zero `rectSize` means the whole image, which is what an
--: `ImageLabel` already means by it -- so the same three assignments work for
--: both kinds without the caller branching.
export type Drawn = {
	image: string,
	rectOffset: Vector2,
	rectSize: Vector2,
}

function ItchIcons.get(token: string): Drawn?
	local entry = byToken[token]
	if not entry then
		return nil
	end
	return {
		image = "rbxassetid://" .. entry.id,
		rectOffset = Vector2.zero,
		rectSize = Vector2.zero,
	}
end

--[[
	One cell of a sheet, by index, reading left to right and top to bottom.

	Index rather than name because a sheet arrives unlabelled: the pack knows
	its own order and the filename does not carry it. Labelling one is a
	person's ten seconds and turns 90 cells into 90 tokens.
]]
function ItchIcons.cell(assetId: number, index: number): Drawn?
	for _, entry in ItchIcons.entries do
		if entry.id ~= assetId then
			continue
		end
		local across, cell = entry.across, entry.cell
		if not across or not cell or across < 1 then
			return nil
		end
		local zero = index - 1
		return {
			image = "rbxassetid://" .. entry.id,
			rectOffset = Vector2.new((zero % across) * cell,
				math.floor(zero / across) * cell),
			rectSize = Vector2.new(cell, cell),
		}
	end
	return nil
end

--: Set an ImageLabel or ImageButton from a token. Returns whether it found
--: one, so a caller can fall back rather than display a blank square.
function ItchIcons.apply(label: any, token: string): boolean
	local drawn = ItchIcons.get(token)
	if not drawn then
		return false
	end
	label.Image = drawn.image
	label.ImageRectOffset = drawn.rectOffset
	label.ImageRectSize = drawn.rectSize
	return true
end

function ItchIcons.tokens(): { string }
	local out = {}
	for token in byToken do
		table.insert(out, token)
	end
	table.sort(out)
	return out
end

function ItchIcons.sheets(): { Entry }
	local out = {}
	for _, entry in ItchIcons.entries do
		if entry.kind == "sheet" then
			table.insert(out, entry)
		end
	end
	return out
end

function ItchIcons.describe(): { [string]: any }
	return {
		entries = #ItchIcons.entries,
		tokens = #ItchIcons.tokens(),
		sheets = #ItchIcons.sheets(),
	}
end

return ItchIcons
'''


def _lua_str(value: Any) -> str:
    return '"' + str(value or "").replace("\\", "\\\\").replace('"', '\\"') + '"'


def export_lua(published: Path | None = None) -> tuple[Path, int]:
    """Write the published images as a Luau module the UI can read."""
    source = Path(published) if published else PUBLISHED
    book = json.loads(source.read_text(encoding="utf-8"))
    live = [v for v in (book.get("assets") or {}).values() if v.get("assetId")]

    rows, whole, sheets, cells = [], 0, 0, 0
    tokens: set[str] = set()
    for entry in sorted(live, key=lambda e: (e.get("topic") or "~", e["assetId"])):
        kind = entry.get("shape") or "icon"
        cell = entry.get("grid") or {}
        if kind == "sheet":
            sheets += 1
            cells += int(cell.get("cells") or 0)
        else:
            whole += 1
            if entry.get("topic"):
                tokens.add(entry["topic"])

        token = (f"token = {_lua_str(entry['topic'])}, "
                 if entry.get("topic") else "")
        gridfields = ""
        if cell:
            gridfields = (f"cell = {int(cell['cell'])}, "
                          f"across = {int(cell['across'])}, "
                          f"down = {int(cell['down'])}, ")
        rows.append(
            f"\t{{ {token}id = {entry['assetId']}, kind = {_lua_str(kind)}, "
            f"width = {int(entry.get('width') or 0)}, "
            f"height = {int(entry.get('height') or 0)}, "
            f"{gridfields}"
            f"pack = {_lua_str(entry.get('pack'))}, "
            f"author = {_lua_str(entry.get('author'))} }},")

    LUA_PATH.parent.mkdir(parents=True, exist_ok=True)
    LUA_PATH.write_text(
        _HEADER % {"whole": whole, "tokens": len(tokens), "sheets": sheets,
                   "cells": cells, "when": time.strftime("%Y-%m-%d"),
                   "entries": "\n".join(rows)} + _FOOTER,
        encoding="utf-8")
    return LUA_PATH, len(live)


def _write(book: dict[str, Any], uploaded: int, failed: int, skipped: int,
           started: float) -> dict[str, Any]:
    book["$comment"] = (
        "Images published to Roblox from CC0 itch.io UI packs. Each entry "
        "keeps the pack and author it came from, and its pixel size -- which "
        "a caller needs, because an ImageLabel showing a cell of a sheet is "
        "positioned in the sheet's own pixels.")
    book["uploaded"] = uploaded
    book["failed"] = failed
    book["skipped"] = skipped
    book["seconds"] = round(time.time() - started)
    PUBLISHED.parent.mkdir(parents=True, exist_ok=True)
    PUBLISHED.write_text(json.dumps(book, indent=1, ensure_ascii=False) + "\n",
                         encoding="utf-8")
    return book
