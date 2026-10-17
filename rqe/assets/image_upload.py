"""Take a PNG on disk and turn it into a `rbxassetid://` this account owns.

Why this exists
---------------

The licensed projects carry 365 icons and 119 other interface images, and none
of them were usable: a file on disk is not an asset, and a Roblox game can only
reference art that has been published. So the whole collection sat indexed and
unreachable while the HUD used no icons at all.

The publishing path runs through Studio rather than Open Cloud, because
`AssetService:CreateAssetAsync` is the only route that does not need a browser
session. That means an image goes out as a plain list of RGBA bytes over the
bridge, gets written into an `EditableImage` inside Studio, and is published
from there.

What this handles that a loop over the files would not
------------------------------------------------------

**Size.** Source art is 1200px square and a HUD draws it at 32. Sending the
original is a megabyte of JSON per icon for detail nobody can see, so
everything is resampled down before it leaves this process.

**The rate limit.** Roblox allows 30 uploads a minute and answers the 31st with
a refusal, so a batch of 365 must pace itself or lose most of the batch.

**The manifest.** An upload that succeeds and is not written down is an asset
nobody can find again: it exists, it costs a slot, and the id is gone. Every
success is recorded before the next one starts.
"""

from __future__ import annotations

import json
import time
from pathlib import Path
from typing import Any, Callable, Iterable

#: Roblox's documented ceiling. Kept a little under it: the limit is enforced
#: per minute on their side and our clock is not theirs.
UPLOADS_PER_MINUTE = 26

#: What a HUD icon is actually drawn at, times four. Beyond this the extra
#: pixels are paid for in upload time and JSON and never reach a screen.
DEFAULT_SIZE = 128

#: Where the name -> assetId mapping lives, so a game can reference an icon by
#: a name a person chose rather than by a number Roblox chose.
MANIFEST = Path("forge/catalog/images.json")


def prepare(path: Path, size: int = DEFAULT_SIZE) -> tuple[list[int], int, int]:
    """Resample one image and flatten it to the RGBA bytes the bridge wants.

    `LANCZOS` rather than the default: these are line-art icons going down by a
    factor of ten, and a cheaper filter turns thin strokes into gravel.
    """
    from PIL import Image

    with Image.open(path) as source:
        image = source.convert("RGBA")
        if image.width != size or image.height != size:
            image = image.resize((size, size), Image.LANCZOS)
        return list(image.tobytes()), image.width, image.height


def load_manifest() -> dict[str, Any]:
    if not MANIFEST.exists():
        return {}
    try:
        return json.loads(MANIFEST.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return {}


def record(name: str, entry: dict[str, Any]) -> None:
    """Write one result down immediately.

    Per upload rather than per batch, on purpose: a batch of three hundred that
    is interrupted at two hundred should leave two hundred usable ids behind,
    not an empty file and a rate limit spent.
    """
    manifest = load_manifest()
    manifest[name] = entry
    MANIFEST.parent.mkdir(parents=True, exist_ok=True)
    MANIFEST.write_text(json.dumps(manifest, indent=2, ensure_ascii=False) + "\n",
                        encoding="utf-8")


def upload(bridge: Any, path: Path, name: str, size: int = DEFAULT_SIZE,
           timeout: float = 240.0) -> dict[str, Any]:
    """Publish one image and return what Roblox said about it."""
    pixels, width, height = prepare(path, size)
    with bridge.lease_scope(
        agent_id="asset-image-upload",
        context="edit",
        ttl_seconds=max(30.0, min(timeout + 30.0, 300.0)),
    ):
        result = bridge.call("assets.create_image", {
            "name": name,
            "description": f"{path.name} via rqe.assets.image_upload",
            "width": width,
            "height": height,
            "pixels": pixels,
        }, timeout=timeout)

    entry = {
        "assetId": result.get("assetId"),
        "contentId": result.get("contentId"),
        "status": result.get("status"),
        "moderation": result.get("moderation"),
        "source": str(path),
        "size": size,
    }
    if result.get("status") == "PUBLISHED" and result.get("assetId"):
        record(name, entry)
    return entry


def upload_many(bridge: Any, items: Iterable[tuple[str, Path]],
                size: int = DEFAULT_SIZE,
                on_result: Callable[[str, dict[str, Any]], None] | None = None,
                skip_known: bool = True) -> dict[str, Any]:
    """Publish a batch, pacing to stay under the rate limit.

    Already-published names are skipped by default rather than re-uploaded.
    Roblox creates a *new* asset every time, so a re-run without this quietly
    doubles the collection and leaves the manifest pointing at the newer copy
    while the older one stays alive and unreferenced for ever.
    """
    known = load_manifest()
    gap = 60.0 / UPLOADS_PER_MINUTE
    done, skipped, failed = 0, 0, []
    last = 0.0

    for name, path in items:
        if skip_known and name in known and known[name].get("assetId"):
            skipped += 1
            continue

        wait = gap - (time.monotonic() - last)
        if wait > 0:
            time.sleep(wait)
        last = time.monotonic()

        try:
            entry = upload(bridge, path, name, size=size)
        except Exception as error:  # a refused upload must not end the batch
            entry = {"status": "ERROR", "reason": str(error)[:200], "source": str(path)}

        if entry.get("assetId"):
            done += 1
        else:
            failed.append((name, entry.get("status"), entry.get("reason")))
        if on_result:
            on_result(name, entry)

    return {"uploaded": done, "skipped": skipped,
            "failed": len(failed), "failures": failed[:20]}
