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


#: Roblox's own creator account. Assets under it are the only third-party ones
#: `InsertService:LoadAsset` will fetch -- see `ROBLOX_CREATOR` below.
ROBLOX_USER_ID = 1

#: Why this constant earns a name.
#:
#: `InsertService:LoadAsset` refuses anything the signed-in user does not own:
#: "User is not authorized to access Asset", for free public models included.
#: Measured, not inferred -- an asset this account uploaded loads, and a free
#: model by somebody else does not.
#:
#: The exception is assets created by Roblox, which load for everybody. That
#: makes the official library the only source this pipeline can pull from
#: without a person first adding each model to their inventory by hand, and it
#: happens to be the best one: the showcase packs (Duvall Drive, Beyond the
#: Dark) are PBR-textured and consistent in scale.
ROBLOX_CREATOR = {"creatorTargetId": str(ROBLOX_USER_ID), "creatorType": "User"}


def search(query: str, limit: int = 12, category: int = CATEGORY_MODEL,
           official: bool = False) -> list[dict[str, Any]]:
    """Find assets by keyword, with enough detail to choose between them.

    Two calls, because the search endpoint returns bare ids and nothing else --
    no name, no creator, no part count. Choosing from an id alone is choosing at
    random, and toolbox results are largely keyword spam, so the second call is
    not optional.

    What the details call actually carries
    --------------------------------------

    Rather more than an earlier version of this function read. Every field below
    comes back on the same response, and each one answers a question somebody
    would otherwise answer by inserting the model and looking:

      * `hasScripts` -- the security question, before anything is inserted.
      * `triangles` / `vertices` -- the performance question. A 90k-triangle
        prop and a 900-triangle prop look identical in a search result.
      * `instanceCounts` -- what the model is *made of*, which separates a mesh
        prop from somebody's entire gun system.
      * `voting` -- the only crowd signal available, and the only defence
        against keyword spam that does not require looking at every result.
      * `objectTypes` -- Roblox's own semantic tags. Far better than
        `categoryPath`, which classifies a mining drill as `3d__weapons`.
      * `isEndorsed`, `isFree`, `createdUtc`.

    One correction worth recording: the verified-creator flag is
    `creator.isVerifiedCreator`. This function used to read
    `creator.hasVerifiedBadge`, which is not a key on this response, so every
    result reported `verified: false` -- including creators who are verified.
    """
    query_parts = {"limit": str(int(limit)), "keyword": query}
    if official:
        query_parts.update(ROBLOX_CREATOR)
    found = _get(
        SEARCH_URL.format(category=int(category))
        + "?" + urllib.parse.urlencode(query_parts))
    ids = [str(item["id"]) for item in (found.get("data") or []) if item.get("id")]
    if not ids:
        return []

    detailed = _get(f"{DETAILS_URL}?assetIds={','.join(ids)}")
    out: list[dict[str, Any]] = []
    for item in detailed.get("data") or []:
        asset = item.get("asset") or {}
        creator = item.get("creator") or {}
        voting = item.get("voting") or {}
        product = item.get("fiatProduct") or {}

        technical = asset.get("modelTechnicalDetails") or {}
        mesh = technical.get("objectMeshSummary") or {}
        # Present in two places depending on the endpoint's mood; the nested one
        # is the populated one for models.
        counts = technical.get("instanceCounts") or asset.get("instanceCounts") or {}

        out.append({
            "id": asset.get("id"),
            "name": asset.get("name") or "",
            "description": asset.get("description") or "",
            "creator": creator.get("name") or "",
            "creatorId": creator.get("id"),
            "verified": bool(creator.get("isVerifiedCreator")),
            "endorsed": bool(asset.get("isEndorsed")),
            "free": bool(product.get("isFree", True)),
            "created": asset.get("createdUtc"),
            "updated": asset.get("updatedUtc"),
            "duration": asset.get("duration"),
            "category": asset.get("categoryPath") or "",
            #: Roblox's semantic tags for what the thing is. The keyword that
            #: found it says what somebody typed; this says what it is.
            "objectTypes": asset.get("objectTypes") or [],
            #: The security question, answered before insertion.
            "hasScripts": bool(asset.get("hasScripts")),
            "sandboxed": bool((asset.get("capabilities") or {}).get("shouldSandbox")),
            "triangles": int(mesh.get("triangles") or 0),
            "vertices": int(mesh.get("vertices") or 0),
            "scripts": int(counts.get("script") or 0),
            "meshes": int(counts.get("meshPart") or 0),
            "animations": int(counts.get("animation") or 0),
            "decals": int(counts.get("decal") or 0),
            "audio": int(counts.get("audio") or 0),
            "tools": int(counts.get("tool") or 0),
            "upVotes": int(voting.get("upVotes") or 0),
            "downVotes": int(voting.get("downVotes") or 0),
            #: Roblox reports 0 for an unvoted asset, which is not the same as
            #: 0% approval. `assess` treats no votes as no signal.
            "approval": float(voting.get("upVotePercent") or 0),
        })
    return out


#: Triangle budgets by what a model is for, as a first cut.
#:
#: Not physically derived -- they are the point past which a thing is more
#: detailed than its job needs on a device most Roblox players are holding. A
#: hero prop the player walks up to earns its budget; forty pieces of scatter
#: vegetation at the same density is a frame-rate problem wearing a costume.
TRIANGLE_BUDGET = {
    "scatter": 1_500,    # placed by the hundred: rocks, grass, debris
    "prop": 6_000,       # furniture, crates, machines
    "hero": 25_000,      # the one thing in the room the player looks at
    "character": 15_000,
    "structure": 40_000, # a whole building
}


def assess(candidate: dict[str, Any], role: str = "prop",
           allow_scripts: bool = False, **limits: Any) -> dict[str, Any]:
    """Decide whether a search result is worth inserting, and say why.

    Returns a verdict rather than a boolean, because "no" and "no, but" are
    different answers and a person reviewing a shortlist needs the reason more
    than the score.

    Scripts are a refusal, not a penalty
    ------------------------------------

    A free Roblox model that contains scripts is the oldest attack in the
    platform: the model works, and a `require(assetId)` buried in it pulls
    executable code from a server the model's author controls, after review, on
    every server that runs it. Roblox sandboxes inserted scripts and disables
    them, which reduces the risk and does not remove it -- the sandbox protects
    against accidental execution, not against a developer who enables the script
    to see what it does.

    So `hasScripts` refuses by default. `allow_scripts=True` exists because a
    whole working system *is* sometimes what you want, and when it is set the
    verdict says `review-scripts` rather than `ok`: the model still has to be
    inserted and read before anything uses it. Nothing here can read the source,
    because Roblox does not serve model bytes to an API key.

    Votes are a signal only where there are votes
    ---------------------------------------------

    Roblox reports `upVotePercent: 0` for an asset nobody has voted on, which is
    not the same as nobody approving of it. Treating those alike rejects every
    new asset and every niche one, so a candidate with no votes is judged on
    everything else instead.
    """
    reasons: list[str] = []
    warnings: list[str] = []

    budget = limits.get("triangles") or TRIANGLE_BUDGET.get(role, TRIANGLE_BUDGET["prop"])
    triangles = int(candidate.get("triangles") or 0)
    votes = int(candidate.get("upVotes") or 0) + int(candidate.get("downVotes") or 0)
    approval = float(candidate.get("approval") or 0)

    if candidate.get("hasScripts") or int(candidate.get("scripts") or 0) > 0:
        if not allow_scripts:
            reasons.append("contains scripts")
        else:
            warnings.append("contains scripts; read every one before enabling it")

    if not candidate.get("free", True):
        reasons.append("not free")

    if triangles > budget:
        reasons.append(f"{triangles} triangles over the {role} budget of {budget}")
    elif triangles == 0 and int(candidate.get("meshes") or 0) == 0:
        #: No mesh at all. Usually a part-built model, which is legitimate and
        #: is also what an empty or broken upload looks like.
        warnings.append("no mesh geometry; part-built or empty")

    minimum = limits.get("approval")
    if minimum is not None and votes > 0 and approval < minimum:
        reasons.append(f"{approval:.0f}% approval across {votes} votes")

    if int(candidate.get("tools") or 0) > 0:
        warnings.append("contains a Tool; carries its own behaviour")
    if int(candidate.get("audio") or 0) > 0:
        warnings.append("contains audio; check it is not a commercial rip")

    verdict = "ok"
    if reasons:
        verdict = "reject"
    elif warnings:
        verdict = "review-scripts" if candidate.get("hasScripts") else "review"

    return {
        "id": candidate.get("id"),
        "name": candidate.get("name"),
        "verdict": verdict,
        "reasons": reasons,
        "warnings": warnings,
        #: Ordering signal only. Deliberately not part of the verdict: a score
        #: that could overrule "contains scripts" would eventually do so.
        "score": _score(candidate, budget),
    }


def _score(candidate: dict[str, Any], budget: int) -> float:
    """Rank the survivors. Not a safety judgement -- `assess` owns that."""
    score = 0.0
    if candidate.get("endorsed"):
        score += 3.0
    if candidate.get("verified"):
        score += 1.5

    votes = int(candidate.get("upVotes") or 0) + int(candidate.get("downVotes") or 0)
    if votes > 0:
        #: Approval weighted by how many people voted, so 100% of three votes
        #: does not outrank 92% of four hundred.
        score += (float(candidate.get("approval") or 0) / 100.0) * min(votes / 50.0, 2.0)

    triangles = int(candidate.get("triangles") or 0)
    if 0 < triangles <= budget:
        #: Cheaper is better among things that all fit, but only mildly: this
        #: must never outweigh the crowd signal.
        score += 0.5 * (1.0 - triangles / budget)
    return round(score, 3)


def shortlist(query: str, role: str = "prop", limit: int = 24,
              allow_scripts: bool = False, official: bool = False,
              **limits: Any) -> dict[str, Any]:
    """Search, assess and rank in one call. The stage before a person looks.

    Returns the accepted and the rejected, because a shortlist with nothing in
    it is a question about the query, and the rejection reasons are the answer.
    """
    found = search(query, limit=limit, official=official)
    by_id = {c["id"]: c for c in found}

    accepted, rejected = [], []
    for candidate in found:
        verdict = assess(candidate, role=role, allow_scripts=allow_scripts, **limits)
        verdict["candidate"] = by_id[verdict["id"]]
        (rejected if verdict["verdict"] == "reject" else accepted).append(verdict)

    accepted.sort(key=lambda v: v["score"], reverse=True)
    return {"query": query, "role": role, "accepted": accepted, "rejected": rejected}


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
