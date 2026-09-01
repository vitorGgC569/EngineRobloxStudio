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

  * upload the sheet as one `Image`,
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

`Image` is the assetType, and the distinction is not cosmetic: Open Cloud also
accepts `Decal`, reports it Approved and Active, and hands back an id that
**does not render**. 367 assets went up that way before a part with one of each
side by side showed the difference. Roblox re-encodes on upload; PNG with alpha
survives, which is the whole point for an icon.

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


# ------------------------------------------------------------------ nine-slice

#[[
#   Where a frame stops being a corner and starts being a repeat.
#
#   A panel, a button face or a window border is useless at one size. Roblox
#   stretches them correctly with `ScaleType = Slice` and a `SliceCenter` rect,
#   which needs four inset numbers -- and those are a property of the artwork,
#   not something a caller can be asked for.
#
#   So they are measured, by finding the tileable middle and taking the
#   distance from it to each edge. The middle is the run of columns around the
#   centre that are all identical to the centre column -- that is what "this
#   part may be stretched" means, and it is exactly what the eye reads as the
#   flat side of a frame.
#
#   The obvious version of this test does not work, and it is worth recording
#   why: scanning in from the left for the first column that equals its
#   neighbour returns **1** for almost every real asset, because packs ship art
#   with a transparent one-pixel margin and two transparent columns are equal.
#   Measured on a real button set, that version reported an inset of 1 on all
#   fourteen files it was tried against.
#
#   Returns nothing when there is no such run. That is the honest answer for a
#   circle, an illustration or an icon -- none of which are nine-slices -- and
#   it is far better than a plausible number: a wrong inset stretches the
#   corner of every panel in a game and reads as a rendering bug.
#]]

def _columns_equal(pixels: Any, width: int, height: int, a: int, b: int) -> bool:
    for y in range(height):
        if pixels[a, y] != pixels[b, y]:
            return False
    return True


def _rows_equal(pixels: Any, width: int, height: int, a: int, b: int) -> bool:
    for x in range(width):
        if pixels[x, a] != pixels[x, b]:
            return False
    return True


def slice_insets(data: bytes) -> dict[str, int] | None:
    """The four nine-slice insets of a frame image, measured, or None.

    Opens the image, which is why this is not run over the whole inventory:
    52,000 decodes is an afternoon. It runs on the few hundred that were
    selected as frames.
    """
    try:
        from PIL import Image
    except ImportError:
        return None

    import io
    try:
        with Image.open(io.BytesIO(data)) as image:
            image = image.convert("RGBA")
            width, height = image.size
            #: A frame smaller than this has no middle to tile.
            if width < 12 or height < 12:
                return None
            pixels = image.load()

            centre_x, centre_y = width // 2, height // 2

            left = centre_x
            while left > 0 and _columns_equal(pixels, width, height,
                                              left - 1, centre_x):
                left -= 1
            right = centre_x
            while right < width - 1 and _columns_equal(pixels, width, height,
                                                       right + 1, centre_x):
                right += 1

            top = centre_y
            while top > 0 and _rows_equal(pixels, width, height,
                                          top - 1, centre_y):
                top -= 1
            bottom = centre_y
            while bottom < height - 1 and _rows_equal(pixels, width, height,
                                                      bottom + 1, centre_y):
                bottom += 1
    except Exception:  # noqa: BLE001 - a pack ships broken files; skip them
        return None

    #: A run that reaches both edges means the image is uniform in that axis --
    #: a gradient strip, a solid fill, an icon. Nothing to slice.
    if left == 0 and right == width - 1:
        return None
    if top == 0 and bottom == height - 1:
        return None
    #: And a middle thinner than two pixels is not a middle; stretching it
    #: magnifies a single row of pixels across the whole panel.
    if right - left < 2 or bottom - top < 2:
        return None

    #[[
    #   Whether the middle is solid, which decides how the frame may be used.
    #
    #   Half the panel art in these packs is drawn with a *transparent* centre:
    #   it is an overlay border meant to sit on top of whatever is behind it.
    #   The other half is a filled plate. They are not interchangeable, and
    #   nothing in the filename says which one you have.
    #
    #   Measured because guessing produced an invisible HUD. The top bar was
    #   skinned with a transparent-centre frame and its own fill was cleared,
    #   which left the readouts floating over the world with no surface at all.
    #]]
    red, green, blue, centre_alpha = pixels[centre_x, centre_y]
    #: Rec. 709 luma, so a caller can pick text that reads against the face.
    #: A button drawn white-outside-black-inside took black label text chosen
    #: for the flat accent fill it replaced, and the label vanished.
    luma = (0.2126 * red + 0.7152 * green + 0.0722 * blue) / 255.0

    return {"left": int(left), "top": int(top),
            "right": int(right + 1), "bottom": int(bottom + 1),
            "opaque": bool(centre_alpha > 200),
            "dark": bool(luma < 0.5)}


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
    #: No `arrow`. In a UI pack it means a direction glyph essentially always,
    #: and because `arrow` is longer than `down` the longest-term rule handed
    #: `Arrow_Down` to archery -- 574 navigation chevrons filed as weapons.
    "combat.bow": ("bow", "archery", "quiver"),
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


# ------------------------------------------------------------------ sourcing

CATALOGUE = Path("forge/kits/itch-ui.json")


def redistributable(catalogue: Path | None = None,
                    limit: int | None = None) -> list[dict[str, Any]]:
    """The packs whose own page says they may be republished.

    `cc0` only. Not "free", which on itch means free to download and says
    nothing about redistribution -- and uploading art to Roblox's Creator Store
    *is* redistribution: it lands on Roblox's CDN under this account and
    becomes usable by others.

    `needs-reading` and `terms-present-unread` are excluded on purpose. They
    are the packs where a person has to look, and a pipeline that treats "I
    could not tell" as "yes" is a pipeline that republishes somebody's work
    against their terms at scale.
    """
    source = Path(catalogue) if catalogue else CATALOGUE
    book = json.loads(source.read_text(encoding="utf-8"))
    packs = [p for p in book.get("packs") or []
             if (p.get("licence") or {}).get("verdict") == "cc0"]
    return packs[:limit] if limit else packs


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


# ------------------------------------------------------------------ furniture

#: What a HUD is made of besides glyphs. Keyed by role, because a caller wants
#: "the panel background" and "the button face", not a filename.
FRAME_ROLES: dict[str, tuple[str, ...]] = {
    "panel": ("panel", "window", "frame", "board", "dialog", "popup", "menu"),
    "button": ("button", "btn"),
    "bar": ("bar", "gauge", "meter", "progress", "slider"),
    "tab": ("tab", "ribbon", "banner", "header", "title"),
    "slot": ("slot", "cell", "inventory", "socket"),
    "tooltip": ("tooltip", "speech", "balloon", "callout"),
}

#: Words that mark a variant of a face rather than a different face. A pack
#: ships `Button_Normal`, `Button_Hover`, `Button_Pressed`; all three are
#: wanted, and they are wanted *together* so a button can have states.
STATE_WORDS = {
    "normal": "normal", "default": "normal", "idle": "normal", "up": "normal",
    "hover": "hover", "highlight": "hover", "focus": "hover", "over": "hover",
    "pressed": "pressed", "press": "pressed", "active": "pressed",
    "click": "pressed", "down": "pressed",
    "disabled": "disabled", "inactive": "disabled", "locked": "disabled",
}


def frame_role(stem: str) -> tuple[str, str] | None:
    """The role and state a frame filename names, or None.

    Longest word wins, same rule as `classify`, for the same reason: `panel`
    and `button` both appear in `panel_button_frame` and the longer one is
    almost always the subject.
    """
    words = set(_words(stem))
    if not words:
        return None
    best: tuple[int, str] | None = None
    for role, terms in FRAME_ROLES.items():
        for term in terms:
            if term in words and (best is None or len(term) > best[0]):
                best = (len(term), role)
    if not best:
        return None
    state = "normal"
    for word in words:
        if word in STATE_WORDS:
            state = STATE_WORDS[word]
            break
    return best[1], state


def select_frames(images: list[dict[str, Any]], per_role: int = 16,
                  per_pack: int = 2,
                  progress: Any = print) -> list[dict[str, Any]]:
    """Panels, button faces and bars that measure as real nine-slices.

    Each candidate is opened and measured; anything without a tileable middle
    is dropped rather than published with a guessed inset. That is most of
    them -- circles, glossy renders and illustrations are not nine-slices --
    and the ones that survive are the ones a HUD can be built from at any size.

    Two rules here were wrong on the first pass and both came from treating an
    upload as expensive:

    **Smallest first.** The reasoning was that a nine-slice never scales its
    corners, so a 32px border is as crisp as a 512px one for less memory. True,
    and it ignored that a 32px *button face* has a one-pixel border and a
    two-pixel middle: stretched across a 450-pixel bar it draws a thin outline
    and nothing else. The Claim button came out as an empty white rectangle.

    **Six per role, no cap per pack.** One generous pack filled every
    `button.normal` slot with six near-identical 32px faces, so there was no
    larger alternative to fall back to. A cap per pack forces the variety that
    makes the preference in `ItchIcons` mean anything.
    """
    candidates = []
    for image in images:
        if image["suffix"] != ".png":
            continue
        if not (24 <= image["width"] <= 512 and 12 <= image["height"] <= 512):
            continue
        role = frame_role(image["stem"])
        if not role:
            continue
        candidates.append({**image, "role": role[0], "state": role[1]})

    #: Largest first, so the fallback ladder in `ItchIcons` starts from art
    #: with a border big enough to survive being stretched.
    candidates.sort(key=lambda i: (i["role"], i["state"],
                                   -(i["width"] * i["height"])))

    chosen: list[dict[str, Any]] = []
    taken: dict[tuple[str, str], int] = {}
    from_pack: dict[tuple[str, str, str], int] = {}
    #: Packs republish each other constantly, so the same `Slider_Blue_Grabber`
    #: turns up in three of them. Keyed on name and size rather than on bytes:
    #: a re-export differs byte for byte and is still the same picture.
    seen: set[tuple[str, int, int]] = set()
    measured = refused = 0

    for image in candidates:
        slot = (image["role"], image["state"])
        if taken.get(slot, 0) >= per_role:
            continue
        pack_slot = (image["role"], image["state"], str(image.get("pack")))
        if from_pack.get(pack_slot, 0) >= per_pack:
            continue
        fingerprint = (image["stem"].lower(), image["width"], image["height"])
        if fingerprint in seen:
            continue
        seen.add(fingerprint)
        try:
            with zipfile.ZipFile(image["archive"]) as bundle:
                data = bundle.read(image["member"])
        except (zipfile.BadZipFile, OSError, KeyError):
            continue
        insets = slice_insets(data)
        if not insets:
            refused += 1
            continue
        measured += 1
        taken[slot] = taken.get(slot, 0) + 1
        from_pack[pack_slot] = from_pack.get(pack_slot, 0) + 1
        chosen.append({**image, "shape": "frame", "slice": insets,
                       "topic": f"{image['role']}.{image['state']}"})

    progress(f"  {len(chosen)} frames from {len(candidates)} candidates "
             f"({refused} refused: no tileable middle)")
    for slot, count in sorted(taken.items()):
        progress(f"    {slot[0]}.{slot[1]}: {count}")
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
            #[[
            #   `Image`, not `Decal`, and the difference is total.
            #
            #   Open Cloud accepts both and reports both Approved and Active.
            #   A Decal id does not render: put one on a part beside the same
            #   artwork uploaded as an Image and the Decal shows the part's own
            #   colour through while the Image shows the picture. 367 assets
            #   went up as Decals, every one of them approved, none of them
            #   usable, and the UI built on them was invisible.
            #
            #   `forge/cli/upload.py` has said `Image` since it was written --
            #   "what Open Cloud accepts, and what it calls each one". Reading
            #   it would have cost a minute.
            #]]
            "assetType": "Image",
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
        #: Measured before the upload and carried through, because it cannot be
        #: recovered afterwards: the published asset is pixels, and which of
        #: them are the border is not in them.
        "slice": image.get("slice"),
        "role": image.get("role"),
        "state": image.get("state"),
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
	sliceLeft: number?, sliceTop: number?,
	sliceRight: number?, sliceBottom: number?,
	opaque: boolean?, dark: boolean?,
	pack: string, author: string,
}

ItchIcons.entries = ({
%(entries)s
} :: any) :: { Entry }
'''

_FOOTER = '''
--[[
	Icons win the token; sheets only hold it if nothing else does.

	Both kinds carry a token -- a crosshair sheet classifies as `action.close`
	as readily as a loose cross does -- and the first entry used to win, which
	made the answer depend on asset id ordering. When a sheet won, `get`
	returned it with a zero rect, and a caller asking for a close glyph got a
	256-pixel grid of ninety crosshairs stretched across its button.

	Sheets are still reachable by `cell`, which is the only way they were ever
	meant to be drawn.
]]
--[[
	Icons win the token, and the squarest icon wins among icons.

	Both kinds carry a token -- a crosshair sheet classifies as `action.close`
	as readily as a loose cross does -- and the first entry used to win, which
	made the answer depend on asset id ordering. When a sheet won, `get`
	returned it with a zero rect and a caller asking for a close glyph got a
	256-pixel grid of ninety crosshairs stretched across its button.

	Among icons, aspect decides. A glyph is drawn on a square canvas: a cross,
	a gear, a coin. An entry at 160x150 is a small illustration with a caption
	or a margin, and it reads as the wrong picture at button size -- the close
	button showed what looked like a broken-image icon for a whole session
	because the least square candidate happened to sort first.
]]
local function squareness(entry: Entry): number
	local long = math.max(entry.width, entry.height)
	local short = math.min(entry.width, entry.height)
	return if long > 0 then short / long else 0
end

local byToken: { [string]: Entry } = {}
for _, entry in ItchIcons.entries do
	if entry.token and entry.kind == "icon" then
		local held = byToken[entry.token]
		if not held or squareness(entry) > squareness(held) then
			byToken[entry.token] = entry
		end
	end
end
for _, entry in ItchIcons.entries do
	if entry.token and entry.kind ~= "frame" and not byToken[entry.token] then
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

--[[
	The furniture: panels, button faces, bars, slots, tabs.

	Kept apart from icons because they are used differently. An icon is drawn
	at its own size; a frame is *stretched* to whatever the layout needs, and
	stretching it correctly needs the nine-slice rect measured off the artwork.

	Roles are `panel`, `button`, `bar`, `slot`, `tab`, `tooltip`; states are
	`normal`, `hover`, `pressed`, `disabled`. A missing state falls back to
	`normal`, so a caller can ask for `button.hover` in a pack that never drew
	one and get the normal face rather than an empty rectangle.
]]
--[[
	Solid-centred frames first.

	Half the panel art in these packs is drawn with a transparent middle: it is
	an overlay border, meant to sit on top of something else. The other half is
	a filled plate. Nothing in the filename distinguishes them, so the centre
	pixel's alpha is measured at publish time and recorded here.

	Taking whichever came first produced an invisible HUD: the top bar was
	skinned with an overlay border and cleared its own fill, leaving the
	readouts floating over the world with no surface behind them.
]]
local byFrame: { [string]: Entry } = {}

--[[
	And every candidate behind the winner.

	`ItchIcons.frame` ranks art against the box it has to fill, and that cannot
	be done from a single pre-chosen entry: the frame that is best in general
	is routinely wrong for a 48-pixel cell. Keeping only the winner is what
	this did, and `frame` read a `byRole` that no line ever wrote -- a nil
	global, indexed on the first panel any game drew, which killed the whole
	client script before it created one element.
]]
local byRole: { [string]: { Entry } } = {}

--[[
	Solid centre first, then the largest.

	Size is not a cost question here, which is what the publisher assumed when
	it kept the smallest of each role. A nine-slice never scales its corners,
	so a 32x32 pixel-art button face stretched across a 450-pixel bar draws its
	one-pixel border and nothing else -- the Claim button came out as an empty
	white outline with the label lost inside it. A 192x64 face carries to any
	width because its border has somewhere to be.
]]
--[[
	Then dark, because the engine's theme is dark.

	Skinning a *container* changes the colour context of everything inside it,
	and that is not something the container can fix per child: a light panel
	arrived and the title went white-on-white, the day labels vanished into the
	plate, and every one of those labels was correctly using `UI.theme` -- for
	the dark surface it was written against.

	Two ways out. Propagate "this surface is light" so every label picks its
	own contrast, or pick art that matches the theme already. The second costs
	one comparison and no changes anywhere else, and a project with a light
	theme flips this line rather than rewriting its labels.
]]
local PREFER_DARK = true

--: The roles that are surfaces rather than pictures. A game sets
--: `ItchIcons.surfaceTint` to its panel colour and these stop arguing with it.
local CONTAINER_ROLES: { [string]: boolean } = {
	panel = true, bar = true, slot = true, tab = true, tooltip = true,
	window = true, card = true,
}
ItchIcons.surfaceTint = nil :: Color3?

local function better(candidate: Entry, held: Entry?): boolean
	if not held then
		return true
	end
	if (candidate.opaque == true) ~= (held.opaque == true) then
		return candidate.opaque == true
	end
	if (candidate.dark == true) ~= (held.dark == true) then
		return (candidate.dark == true) == PREFER_DARK
	end
	return candidate.width * candidate.height > held.width * held.height
end

for _, entry in ItchIcons.entries do
	if entry.kind == "frame" and entry.token then
		local pool = byRole[entry.token]
		if not pool then
			pool = {}
			byRole[entry.token] = pool
		end
		table.insert(pool, entry)
		if better(entry, byFrame[entry.token]) then
			byFrame[entry.token] = entry
		end
	end
end

--: Best-first, so a caller that cannot say how big its box is still gets the
--: pick `better` would have made, and one that can starts from a sorted pool.
for _, pool in byRole do
	table.sort(pool, better)
end

--[[
	The best frame for a role, optionally sized against the box it must fill.

	Size is not "bigger is better", which is what this did after "smaller is
	cheaper" turned out to be wrong. A nine-slice draws its corners at their
	own size, so a 414x309 slot frame in a 48x88 cell has corners larger than
	the cell and renders as nothing at all -- the day cells lost their cards
	that way, and the fix for the button (prefer the largest) is what broke
	them.

	Given a target, the frames are ranked by how close their border is to the
	box: a border more than a third of the smaller edge cannot draw a middle,
	and one under a pixel or two disappears. Without a target the old rule
	stands, because a caller that does not know its size cannot be helped.
]]
function ItchIcons.frame(role: string, state: string?, target: Vector2?): Entry?
	local key = role .. "." .. (state or "normal")
	local pool = byRole[key] or byRole[role .. ".normal"]
	if not pool or #pool == 0 then
		return nil
	end
	if not target then
		return pool[1]
	end

	local shortest = math.min(target.X, target.Y)
	local best, bestScore = nil, -math.huge
	for _, entry in pool do
		local border = math.max(
			entry.sliceLeft or 0, entry.sliceTop or 0,
			entry.width - (entry.sliceRight or entry.width),
			entry.height - (entry.sliceBottom or entry.height))
		--: A border wants to be a small fraction of the box. 0.18 is the
		--: proportion a drawn frame reads as a frame rather than as a blob.
		local wanted = math.max(shortest * 0.18, 2)
		local score = -math.abs(border - wanted)
		if border * 2 >= shortest then
			--: Cannot fit two corners across the box; it will draw as a smear.
			score -= 1000
		end
		--[[
			Fit is the tie-breaker, not the whole question.

			This ranked by border alone the moment a caller offered a target
			size, which threw away the two properties `better` had already
			established matter more: whether the art has a middle at all, and
			whether it belongs to the same theme as the text that will sit on
			it. A seed panel came out pale green with grey labels on it --
			perfectly sized, unreadable -- because a light overlay frame
			happened to have the best-proportioned border in the pool.

			So opacity and theme are weighted above fit, and fit decides
			between the candidates that pass both.
		]]
		if entry.opaque ~= true then
			score -= 400
		end
		if (entry.dark == true) ~= PREFER_DARK then
			score -= 200
		end
		if score > bestScore then
			best, bestScore = entry, score
		end
	end
	return best or pool[1]
end

--[[
	Dress an ImageLabel or ImageButton as a nine-slice frame.

	`ScaleType.Slice` with `SliceCenter` is what keeps a 96-pixel panel border
	crisp on a 600-pixel panel: the corners are drawn at their own size and
	only the middle stretches. Without it the same image scaled up is a blur
	with rounded corners the wrong radius.

	Returns false when the catalogue has no frame for that role, so a caller
	can keep its flat-colour panel instead of showing nothing.
]]
--: Returns whether it skinned *and* whether the art fills its own middle, so
--: a caller can decide whether to keep the background it was going to draw.
--: Returns whether it skinned, whether the art fills its own middle, and
--: whether that middle is dark -- which is what a caller needs to choose text
--: that can be read against it.
function ItchIcons.skin(label: any, role: string, state: string?,
                       target: Vector2?): (boolean, boolean, boolean)
	local entry = ItchIcons.frame(role, state, target)
	if not entry then
		return false, false, false
	end
	label.Image = "rbxassetid://" .. entry.id
	label.ScaleType = Enum.ScaleType.Slice
	label.SliceCenter = Rect.new(
		entry.sliceLeft or 0, entry.sliceTop or 0,
		entry.sliceRight or entry.width, entry.sliceBottom or entry.height)
	--[[
		A surface takes the theme's colour; an icon keeps its own.

		Tinting white leaves the art exactly as drawn, which is right for a
		glyph -- the drawing *is* the content. It is wrong for a panel or a
		bar, where the drawing is a texture and the colour is the theme's to
		decide: a seed panel came out pale green with the game's grey labels on
		it, every label correctly using `UI.theme`, for a surface that had
		quietly stopped being dark.

		`ItchIcons.surfaceTint` is what a caller sets to say "this is a
		container, not a picture". Nine-slice art is nearly always flat colour
		plus a border, so multiplying it lands on the tint and keeps the
		border, the bevel and the corner ornaments intact.
	]]
	local tint = ItchIcons.surfaceTint
	label.ImageColor3 = if tint and CONTAINER_ROLES[role] then tint
		else Color3.new(1, 1, 1)
	label.BackgroundTransparency = 1
	return true, entry.opaque == true, entry.dark == true
end

function ItchIcons.frames(): { string }
	local out = {}
	for token in byFrame do
		table.insert(out, token)
	end
	table.sort(out)
	return out
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
		frames = #ItchIcons.frames(),
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
        cut = entry.get("slice") or {}
        slicefields = ""
        if cut:
            slicefields = (f"sliceLeft = {int(cut['left'])}, "
                           f"sliceTop = {int(cut['top'])}, "
                           f"sliceRight = {int(cut['right'])}, "
                           f"sliceBottom = {int(cut['bottom'])}, "
                           f"opaque = {'true' if cut.get('opaque') else 'false'}, "
                           f"dark = {'true' if cut.get('dark') else 'false'}, ")
        rows.append(
            f"\t{{ {token}id = {entry['assetId']}, kind = {_lua_str(kind)}, "
            f"width = {int(entry.get('width') or 0)}, "
            f"height = {int(entry.get('height') or 0)}, "
            f"{gridfields}{slicefields}"
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
