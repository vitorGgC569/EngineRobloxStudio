"""Pull the catalogued packs to disk, resumably.

Thirty gigabytes over five hundred files is a job that will be interrupted --
by a dropped connection, a full disk, or somebody closing the terminal. So the
only design decisions that matter here are about what happens when it stops.

  * **The manifest is written as it goes.** A run that records only at the end
    loses everything it did. That already happened once in this repository, to
    a sweep that got 112 assets in before the session dropped.

  * **A file already on disk at the right size is skipped.** Resuming is the
    normal case, not the exception, and re-downloading 20 GB to get the last
    2 GB is how a job becomes one nobody dares restart.

  * **A failure is recorded against the pack and the run continues.** One
    withdrawn upload must not end a batch of five hundred.

Layout is `author/pack-slug/filename`, because provenance is the thing that
matters later: when the question is "what is this mesh and may I publish it",
the answer has to be recoverable from the path.
"""

from __future__ import annotations

import hashlib
import json
import re
import time
import urllib.error
from pathlib import Path
from typing import Any

from .itch import DELAY, _key, fetch_upload
from ..security import SecurityBoundaryError, validate_filename

ROOT = Path("assets/itch")
MANIFEST = ROOT / "manifest.json"


def _slug(text: str) -> str:
    """A filesystem-safe name that a person can still read."""
    cleaned = re.sub(r"[^\w\s.-]", "", text, flags=re.UNICODE).strip()
    cleaned = re.sub(r"[\s_]+", "-", cleaned)
    return (cleaned[:60] or "unnamed").strip("-.")


def _md5(path: Path) -> str:
    digest = hashlib.md5()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


def run(packs: list[dict[str, Any]], root: Path = ROOT,
        verify: bool = True, progress: Any = print) -> dict[str, Any]:
    """Download every upload of every pack. Returns the manifest."""
    key = _key()
    root.mkdir(parents=True, exist_ok=True)

    #: Resume from whatever a previous run recorded, so its work counts.
    records: dict[str, Any] = {}
    if MANIFEST.exists():
        try:
            records = json.loads(MANIFEST.read_text(encoding="utf-8")).get("files") or {}
        except (OSError, json.JSONDecodeError):
            records = {}

    got = skipped = failed = 0
    downloaded_bytes = 0
    started = time.time()
    since_write = 0

    for index, pack in enumerate(packs, start=1):
        folder = root / _slug(pack.get("author") or "unknown") / _slug(pack["title"])

        for upload in pack.get("uploads") or []:
            try:
                name = validate_filename(
                    upload.get("filename") or f"{upload['id']}.bin",
                    label="itch upload filename",
                )
            except SecurityBoundaryError as error:
                failed += 1
                records[str(upload.get("id") or "invalid")] = {
                    "pack": pack["title"],
                    "author": pack.get("author"),
                    "url": pack.get("url"),
                    "error": str(error)[:160],
                }
                continue
            destination = folder / name
            marker = str(upload["id"])
            expected = int(upload.get("size") or 0)

            if destination.is_file() and destination.stat().st_size == expected:
                skipped += 1
                records.setdefault(marker, {
                    "path": str(destination), "size": expected,
                    "pack": pack["title"], "author": pack.get("author"),
                    "url": pack.get("url"), "licence": "cc0", "resumed": True,
                })
                continue

            try:
                written = fetch_upload(
                    upload["id"],
                    destination,
                    key,
                    expected_size=expected or None,
                    expected_md5=upload.get("md5") if verify else None,
                )
            except (urllib.error.HTTPError, urllib.error.URLError,
                    OSError, RuntimeError) as error:
                failed += 1
                records[marker] = {
                    "pack": pack["title"], "author": pack.get("author"),
                    "url": pack.get("url"), "error": str(error)[:160],
                }
                progress(f"  ! {pack['title'][:34]}/{name[:24]}: {str(error)[:60]}")
                time.sleep(DELAY)
                continue

            #: The listing hands over an md5. Checking it is cheap next to the
            #: download and turns "the file is there" into "the file is right".
            digest = _md5(destination) if verify else None
            if verify and upload.get("md5") and digest != upload["md5"]:
                failed += 1
                records[marker] = {
                    "pack": pack["title"], "author": pack.get("author"),
                    "error": f"md5 mismatch: got {digest}, expected {upload['md5']}",
                }
                progress(f"  ! {pack['title'][:34]}/{name[:24]}: md5 mismatch")
                destination.unlink(missing_ok=True)
                time.sleep(DELAY)
                continue

            got += 1
            downloaded_bytes += written
            records[marker] = {
                "path": str(destination), "size": written, "md5": digest,
                "pack": pack["title"], "author": pack.get("author"),
                "url": pack.get("url"), "licence": "cc0",
            }
            since_write += 1
            if since_write >= 5:
                _write(records, got, skipped, failed, downloaded_bytes, started)
                since_write = 0
            time.sleep(DELAY)

        if index % 20 == 0:
            progress(f"  {index}/{len(packs)} packs  "
                     f"{downloaded_bytes / 1e9:.2f} GB  "
                     f"({got} new, {skipped} already there, {failed} failed)")

    return _write(records, got, skipped, failed, downloaded_bytes, started)


def _write(records: dict[str, Any], got: int, skipped: int, failed: int,
           size: int, started: float) -> dict[str, Any]:
    manifest = {
        "$comment": (
            "Files pulled from itch.io. Every pack here was catalogued as CC0 -- "
            "public domain, no attribution required and republishing permitted. "
            "The classification is a scan of each pack's page prose, and the "
            "quotes behind it are in itch-assets.json; spot-check before "
            "publishing anything under your own account."),
        "files": records,
        "downloaded": got,
        "alreadyPresent": skipped,
        "failed": failed,
        "bytes": size,
        "gigabytes": round(size / 1e9, 2),
        "seconds": round(time.time() - started),
    }
    MANIFEST.parent.mkdir(parents=True, exist_ok=True)
    MANIFEST.write_text(json.dumps(manifest, indent=1, ensure_ascii=False) + "\n",
                        encoding="utf-8")
    return manifest
