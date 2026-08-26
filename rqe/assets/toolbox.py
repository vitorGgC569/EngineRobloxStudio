"""Search the Roblox library, and verify what the search returned.

Why this lives in `rqe.assets` and not in `forge`
-------------------------------------------------

`forge` is the game framework: it builds places and harvests kits. `rqe` is the
quality and asset engine: it discovers assets, checks them, and decides whether
they may be used. Finding a model on Roblox and verifying its moderation state
is squarely the second.

It also has to be here for a duller reason that turns out to be the right one:
the production capability catalogue only accepts adapter symbols under the
`rqe.` namespace, so anything a declared capability depends on has to live in
this package. That rule stops the catalogue from quietly acquiring dependencies
on whatever module happened to be convenient.

What works and what does not
----------------------------

Search answers **without a credential**. `rqe assets search` goes through Open
Cloud and reports `roblox_authorization_blocked` without an API key; these
endpoints -- the ones Studio's own toolbox window talks to -- do not.

Verification needs the key and gives back name, creator, type and moderation
state for any public asset. It does not give back the bytes: every download
route answers 401 to an API key, because model content is gated on a browser
session. Fetching is therefore Studio's job, through `assets.insert`.
"""

from __future__ import annotations

import json
import urllib.error
import urllib.parse
import urllib.request
from typing import Any

#: The endpoints Studio's toolbox window uses. Public, unauthenticated.
SEARCH_URL = "https://apis.roblox.com/toolbox-service/v1/marketplace/{category}"
DETAILS_URL = "https://apis.roblox.com/toolbox-service/v1/items/details"

#: Open Cloud, for the half that needs the operator's key.
ASSET_URL = "https://apis.roblox.com/assets/v1/assets/{asset_id}"

#: Toolbox marketplace categories. Models and Audio are the two worth naming;
#: the rest answer 400 and are not worth guessing at.
CATEGORY_MODEL = 10
CATEGORY_AUDIO = 3

#: Sent because these endpoints answer 403 to a bare urllib agent string.
_AGENT = {"User-Agent": "Mozilla/5.0"}


def _get(url: str, headers: dict[str, str] | None = None, timeout: float = 30.0) -> dict[str, Any]:
    request = urllib.request.Request(url, headers={**_AGENT, **(headers or {})})
    with urllib.request.urlopen(request, timeout=timeout) as response:
        return json.loads(response.read().decode("utf-8", "replace"))


def search(query: str, limit: int = 12, category: int = CATEGORY_MODEL) -> list[dict[str, Any]]:
    """Find assets by keyword, with enough detail to choose between them.

    Two calls, because the search endpoint returns bare ids and nothing else --
    no name, no creator, no part count. Choosing from an id alone is choosing at
    random, and toolbox results are largely keyword spam, so the second call is
    not optional.
    """
    found = _get(
        SEARCH_URL.format(category=int(category))
        + f"?limit={int(limit)}&keyword={urllib.parse.quote(query)}")
    ids = [str(item["id"]) for item in (found.get("data") or []) if item.get("id")]
    if not ids:
        return []

    detailed = _get(f"{DETAILS_URL}?assetIds={','.join(ids)}")
    out: list[dict[str, Any]] = []
    for item in detailed.get("data") or []:
        asset = item.get("asset") or {}
        creator = item.get("creator") or {}
        counts = asset.get("instanceCounts") or {}
        out.append({
            "id": asset.get("id"),
            "name": asset.get("name") or "",
            "creator": creator.get("name") or "",
            "creatorId": creator.get("id"),
            "verified": bool(creator.get("hasVerifiedBadge")),
            "duration": asset.get("duration"),
            "category": asset.get("categoryPath") or "",
            # A model full of scripts is somebody's whole system, and it arrives
            # sandboxed and disabled anyway. Worth seeing before choosing.
            "scripts": int(counts.get("script") or 0),
            "meshes": int(counts.get("meshPart") or 0),
        })
    return out


def official_only(candidates: list[dict[str, Any]]) -> list[dict[str, Any]]:
    """Keep only Roblox's own library clips.

    Roblox names every asset in its first-party sound library `... (SFX)`. They
    are free to use, moderated, and consistent in level and length -- which the
    open toolbox is not: an unfiltered search for a conveyor loop returned a rip
    of a commercial game's audio and a file called "test".
    """
    return [c for c in candidates if str(c.get("name", "")).strip().endswith("(SFX)")]


def verify(asset_id: int | str, api_key: str) -> dict[str, Any]:
    """What Roblox says about one asset: type, creator, moderation state.

    This is the check that stops an invented id reaching a game. An id written
    from memory does not fail loudly -- a bad sound is silence, a bad texture is
    a grey square -- so the rule is that nothing is written into a game table
    until this has answered for it.

    It is not the whole story: an approved id can still fail to load for an
    account that does not own it, which only running the game reveals. This
    catches the ids that were never real.
    """
    try:
        asset = _get(ASSET_URL.format(asset_id=int(asset_id)), {"x-api-key": api_key})
    except urllib.error.HTTPError as error:
        return {"id": str(asset_id), "ok": False, "status": error.code,
                "error": error.reason or "request refused"}

    moderation = (asset.get("moderationResult") or {}).get("moderationState")
    return {
        "id": str(asset_id),
        "ok": moderation == "Approved",
        "name": asset.get("displayName") or "",
        "type": asset.get("assetType"),
        "moderation": moderation,
        "creatorId": ((asset.get("creationContext") or {}).get("creator") or {}).get("userId"),
        "description": asset.get("description") or "",
    }
