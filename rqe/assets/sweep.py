"""Search, fetch, open and judge Creator Store assets across every game topic.

The three stages, and why all three are needed
----------------------------------------------

`toolbox.shortlist` filters on what Roblox *reports*: triangle counts, a script
flag, votes. That is cheap and it is a claim by the uploader.

`inspection.screen` fetches the thing and reads it: what its scripts actually
say, how many of its parts are unanchored, how big it really is. That is the
truth and it costs a second per asset.

This runs the first over a topic list, the second over the survivors, and keeps
what comes through both. Roughly nine in ten candidates never reach stage two,
which is the point -- the expensive check only runs on things that might pass.

Why the topics look like this
-----------------------------

Grouped by the kind of game they serve, because that is how somebody shops:
nobody wants "a good model", they want a conveyor for a tycoon or a tombstone
for a horror map. `shared` is the set every kind draws on, and it is the largest
group because trees and crates outnumber anything genre-specific in any world
ever built.

Each topic carries the role its results should be judged as, which sets the
triangle budget. That is the single most important field here: the same rock is
a fine hero prop and a frame-rate problem as scatter, and no amount of looking
at a search result tells you which one you are buying.
"""

from __future__ import annotations

import json
import time
from pathlib import Path
from typing import Any

from . import inspection, toolbox
from ..workspace import hub_url

CATALOGUE = Path("forge/kits/store-catalogue.json")

#: topic -> role. Role sets the triangle budget it is judged against.
TOPICS: dict[str, dict[str, str]] = {
    "shared": {
        "tree": "scatter", "rock": "scatter", "bush": "scatter",
        "flower": "scatter", "grass patch": "scatter", "log": "scatter",
        "crate": "prop", "barrel": "prop", "fence": "prop", "door": "prop",
        "window": "prop", "wooden sign": "prop", "street lamp": "prop",
        "bench": "prop", "ladder": "prop", "bridge": "structure",
        "house": "structure", "wall": "prop", "road": "prop",
    },
    "furniture": {
        "chair": "prop", "table": "prop", "bed": "prop", "sofa": "prop",
        "bookshelf": "prop", "desk lamp": "prop", "rug": "prop",
        "kitchen counter": "prop", "refrigerator": "prop",
    },
    "tycoon": {
        "conveyor": "prop", "dropper": "prop", "furnace": "prop",
        "generator": "prop", "factory machine": "prop", "mine cart": "prop",
        "ore": "scatter", "pickaxe": "prop", "storage tank": "prop",
        "pipe": "prop",
    },
    "simulator": {
        "pet": "character", "egg": "prop", "treasure chest": "prop",
        "coin": "scatter", "gem": "scatter", "backpack": "prop",
        "podium": "prop", "shop stand": "prop",
    },
    "shooter": {
        "rifle": "prop", "pistol": "prop", "ammo box": "prop",
        "sandbag": "prop", "barricade": "prop", "shooting target": "prop",
        "military crate": "prop", "watchtower": "structure",
    },
    "rpg": {
        "sword": "prop", "shield": "prop", "potion": "prop", "armor": "prop",
        "magic staff": "prop", "altar": "prop", "treasure": "prop",
        "castle": "structure", "anvil": "prop",
    },
    "obby": {
        "platform": "prop", "checkpoint": "prop", "spinner": "prop",
        "trampoline": "prop", "conveyor platform": "prop", "spike trap": "prop",
    },
    "horror": {
        "abandoned hospital": "structure", "horror house": "structure",
        "monster": "character", "coffin": "prop", "tombstone": "prop",
        "candle": "prop", "old chair": "prop", "hospital bed": "prop",
        "rusty door": "prop",
    },
    "vfx": {
        "explosion": "prop", "campfire": "prop", "smoke": "prop",
        "portal": "prop", "torch": "prop",
    },
}


def _row(candidate: dict[str, Any], verdict: dict[str, Any],
         opened: dict[str, Any] | None, topic: str, kind: str,
         role: str) -> dict[str, Any]:
    row = {
        "id": candidate["id"],
        "name": candidate["name"],
        "creator": candidate["creator"],
        "kind": kind,
        "topic": topic,
        "role": role,
        "triangles": candidate["triangles"],
        "upVotes": candidate["upVotes"],
        "downVotes": candidate["downVotes"],
        "endorsed": candidate["endorsed"],
        "verified": candidate["verified"],
        "objectTypes": candidate.get("objectTypes") or [],
        "score": verdict["score"],
    }
    if opened:
        row.update({
            "opened": True,
            "verdict": opened["verdict"],
            "parts": opened["parts"],
            "scripts": opened["scripts"],
            "meshes": opened["meshes"],
            "textures": opened["textures"],
            "unanchored": (opened.get("report") or {}).get("unanchored", 0),
            "size": opened.get("size") or {},
            "blocked": [f["name"] for f in opened.get("blocked", [])],
            "suspicious": [f["name"] for f in opened.get("suspicious", [])],
            "notes": opened.get("notes", []),
        })
    else:
        row.update({"opened": False, "verdict": "filtered",
                    "reasons": verdict.get("reasons", [])})
    return row


#: Studio dropping its bridge session mid-sweep looks exactly like this. It is
#: not a fetch failure and must not be recorded as one -- the asset is fine, the
#: session is gone.
_LOST_SESSION = "no connected session"


def _revive(progress: Any) -> bool:
    """Reuse the sweep's Studio session without ever cold-launching it.

    A dropped bridge is infrastructure failure, not an asset failure. The old
    recovery restarted Studio automatically, which could raise a visible window
    over the user's desktop. Recovery now only accepts an already-open,
    compatible persistent session. If none is available the checkpoint remains
    on disk and the sweep stops cleanly.
    """
    from pathlib import Path as _Path

    try:
        from rqe.hub import lifecycle
        from rqe.hub.client import StudioBridge
    except Exception:  # noqa: BLE001 - no hub package means no recovery
        return False

    place = _Path("games/quarryline/quarryline.rbxlx").resolve()
    if not place.exists():
        return False
    archive = _Path(".tmp/studio-recovery").resolve()
    archive.mkdir(parents=True, exist_ok=True)

    progress("  ... bridge session lost; attempting background-safe reuse")
    try:
        ensured = lifecycle.ensure_studio_session(
            place,
            archive,
            StudioBridge(hub_url()),
            wait_seconds=30,
            background=True,
            allow_cold_launch=False,
        )
    except Exception as error:  # noqa: BLE001
        progress(f"  ... background-safe recovery failed: {error}")
        return False

    revived = bool(ensured.get("ready"))
    progress(
        "  ... "
        + (
            "reused persistent Studio session"
            if revived
            else "no compatible session; refusing to cold-launch Studio"
        )
    )
    return revived


def _write(results: list[dict[str, Any]], stats: dict[str, int],
           chosen: list[str], started: float) -> dict[str, Any]:
    """Write the catalogue as it stands.

    Called on every checkpoint, not only at the end. The first full run wrote
    once, at the end, and lost 112 assets of work when the session dropped
    before it got there.

    Three buckets, not two. `assets` is what a game may use unread. `review` is
    what the scanner opened and could not clear on its own -- a script it wants
    a person to read. Those must not be filed with the approved, and burying
    them among the rejected would hide the most interesting results the sweep
    produces: a working conveyor whose script turns out to be four lines of
    velocity.
    """
    keepers = [r for r in results if r.get("verdict") in ("ok", "caveats")]
    review = [r for r in results if r.get("verdict") in ("read-it", "blocked")]
    catalogue = {
        "$comment": (
            "Creator Store assets that passed a metadata filter and were then "
            "fetched and read. `verdict` ok means nothing to report; caveats "
            "means usable with the notes attended to, usually unanchored parts. "
            "Everything here was opened -- the counts are measured, not claimed."),
        "sweptAt": time.strftime("%Y-%m-%d"),
        "stats": stats | {"kept": len(keepers), "review": len(review), "seconds": round(time.time() - started)},
        "topics": {k: list(v) for k, v in TOPICS.items() if k in chosen},
        "assets": sorted(keepers, key=lambda r: (r["kind"], r["topic"], -r["score"])),
        "review": sorted(review, key=lambda r: (r["kind"], r["topic"], -r["score"])),
        "rejected": [r for r in results
                     if r.get("verdict") not in ("ok", "caveats", "read-it", "blocked")],
    }
    CATALOGUE.parent.mkdir(parents=True, exist_ok=True)
    CATALOGUE.write_text(json.dumps(catalogue, indent=1, ensure_ascii=False) + "\n",
                         encoding="utf-8")
    return catalogue


def run(kinds: list[str] | None = None, per_topic: int = 20,
        open_top: int = 4, discard_every: int = 25, resume: bool = True,
        allow_scripts: bool = False, progress: Any = print) -> dict[str, Any]:
    """Sweep every topic, and return what survived both stages.

    `open_top` is the throttle that makes this affordable: a topic's results are
    ranked and only the best few are actually fetched. Fetching all twenty of
    everything would take an hour and tell us about nineteen models nobody would
    have picked anyway.

    Survives Studio. The catalogue is written at every checkpoint and `resume`
    skips ids already in it, so a dropped session costs the current asset rather
    than the whole run -- and the session is brought back rather than waited on.
    """
    chosen = kinds or list(TOPICS)
    results: list[dict[str, Any]] = []
    seen: set[int] = set()

    if resume and CATALOGUE.exists():
        try:
            previous = json.loads(CATALOGUE.read_text(encoding="utf-8"))
            results = ((previous.get("assets") or [])
                       + (previous.get("review") or [])
                       + (previous.get("rejected") or []))
            seen = {r["id"] for r in results if r.get("opened")}
            if seen:
                progress(f"  resuming; {len(seen)} already opened")
        except (OSError, json.JSONDecodeError, KeyError):
            results, seen = [], set()

    stats = {"searched": 0, "filtered": 0, "opened": 0, "failed": 0,
             "skipped": len(seen), "revivals": 0}
    started = time.time()
    since_discard = 0
    since_write = 0

    #: A sweep that starts against a dead session spends its whole run
    #: recording fetch failures. Check once, up front, rather than discovering
    #: it one asset at a time.
    try:
        inspection.discard()
    except Exception as error:  # noqa: BLE001
        if _LOST_SESSION not in str(error) or not _revive(progress):
            raise
        stats["revivals"] += 1

    for kind in chosen:
        for topic, role in TOPICS[kind].items():
            try:
                shortlisted = toolbox.shortlist(topic, role=role, limit=per_topic,
                                                allow_scripts=allow_scripts)
            except Exception as error:  # noqa: BLE001 - one topic must not end the sweep
                progress(f"  {kind}/{topic}: search failed ({error})")
                continue

            stats["searched"] += len(shortlisted["accepted"]) + len(shortlisted["rejected"])
            for verdict in shortlisted["rejected"]:
                if verdict["id"] in seen:
                    continue
                stats["filtered"] += 1
                results.append(_row(verdict["candidate"], verdict, None, topic, kind, role))

            for verdict in shortlisted["accepted"][:open_top]:
                candidate = verdict["candidate"]
                if candidate["id"] in seen:
                    continue

                opened = None
                for attempt in (1, 2):
                    try:
                        opened = inspection.screen(candidate["id"], role=role)
                        break
                    except Exception as error:  # noqa: BLE001
                        if _LOST_SESSION in str(error) and attempt == 1:
                            if _revive(progress):
                                stats["revivals"] += 1
                                since_discard = 0
                                continue
                        #: A real refusal from Roblox -- 403, a bad id -- is
                        #: information about the asset and is kept as such.
                        stats["failed"] += 1
                        results.append(
                            _row(candidate, verdict, None, topic, kind, role)
                            | {"verdict": "fetch-failed",
                               "reasons": [str(error)[:120]]})
                        break

                if opened is not None:
                    stats["opened"] += 1
                    results.append(_row(candidate, verdict, opened, topic, kind, role))

                seen.add(candidate["id"])
                since_discard += 1
                since_write += 1

                #: Periodic rather than per-asset: discarding costs a round trip,
                #: and holding twenty-five models is well inside what Studio
                #: carries comfortably.
                if since_discard >= discard_every:
                    try:
                        inspection.discard()
                    except Exception:  # noqa: BLE001 - a failed sweep-up is not fatal
                        pass
                    since_discard = 0

                if since_write >= 10:
                    _write(results, stats, chosen, started)
                    since_write = 0

            good = sum(1 for r in results
                       if r["topic"] == topic and r.get("verdict") in ("ok", "caveats"))
            progress(f"  {kind}/{topic}: {good} good "
                     f"({stats['opened']} opened, {time.time() - started:.0f}s)")

    try:
        inspection.discard()
    except Exception:  # noqa: BLE001
        pass

    catalogue = _write(results, stats, chosen, started)
    return catalogue


LUA_PATH = Path("forge/luau/Forge/Catalog/StoreAssets.lua")

_LUA_HEADER = '''--!strict
--[[
	StoreAssets — Creator Store assets that were fetched, opened and read.

	Generated by `rqe.assets.sweep`; do not edit by hand, it is rewritten on
	every sweep. Every id here was searched for, filtered on its metadata, then
	actually pulled into Studio and inspected -- the part and triangle counts
	below are measured rather than claimed, and nothing carrying a script or an
	unreadable payload reached this file.

		local store = Forge.Catalog.StoreAssets
		for _, piece in store.byTopic("conveyor") do
			print(piece.id, piece.parts)
		end

	`verdict` is "ok" or "caveats". Caveats means usable with something to
	attend to, and in practice that is nearly always unanchored parts: they are
	physics bodies the server simulates for as long as they exist, which is fine
	for one and expensive for a hundred. `unanchored` says how many.

	Swept %(swept)s. %(count)d assets across %(topics)d topics.
]]

local StoreAssets = {}

StoreAssets.sweptAt = %(sweptQuoted)s

export type Piece = {
	id: number, name: string, kind: string, topic: string, role: string,
	parts: number, triangles: number, unanchored: number, verdict: string,
}

--: Annotated by cast, not by declaration: Luau takes a type on a `local` but
--: not on a table field, and `StoreAssets.pieces: { Piece } = {` is a parse
--: error rather than a type error -- it fails at load, not at check.
StoreAssets.pieces = ({
%(entries)s
} :: any) :: { Piece }
'''

_LUA_FOOTER = '''
local byTopic: { [string]: { Piece } } = {}
local byKind: { [string]: { Piece } } = {}
for _, piece in StoreAssets.pieces do
	local topic = byTopic[piece.topic]
	if not topic then topic = {} byTopic[piece.topic] = topic end
	table.insert(topic, piece)

	local kind = byKind[piece.kind]
	if not kind then kind = {} byKind[piece.kind] = kind end
	table.insert(kind, piece)
end

--: Everything filed under one topic, best first. Empty table rather than nil,
--: so a caller can iterate the result of any topic without checking.
function StoreAssets.byTopic(topic: string): { Piece }
	return byTopic[topic] or {}
end

function StoreAssets.byKind(kind: string): { Piece }
	return byKind[kind] or {}
end

--[[
	The best match for a topic, optionally refusing anything with caveats.

	`clean` is worth passing wherever the piece will be placed in bulk: a prop
	with unanchored parts is a fine centrepiece and a bad choice for scatter.
]]
function StoreAssets.pick(topic: string, clean: boolean?): Piece?
	for _, piece in StoreAssets.byTopic(topic) do
		if not clean or piece.verdict == "ok" then
			return piece
		end
	end
	return nil
end

function StoreAssets.topics(): { string }
	local out = {}
	for topic in byTopic do
		table.insert(out, topic)
	end
	table.sort(out)
	return out
end

return StoreAssets
'''


def _lua_string(value: str) -> str:
    return '"' + str(value).replace("\\", "\\\\").replace('"', '\\"') + '"'


def export_lua(catalogue: dict[str, Any] | None = None) -> tuple[Path, int]:
    """Write the kept assets as a Luau module a game can actually read."""
    data = catalogue or json.loads(CATALOGUE.read_text(encoding="utf-8"))
    assets = data.get("assets") or []

    entries = "\n".join(
        "\t{ id = %d, name = %s, kind = %s, topic = %s, role = %s, "
        "parts = %d, triangles = %d, unanchored = %d, verdict = %s }," % (
            piece["id"], _lua_string(piece["name"]), _lua_string(piece["kind"]),
            _lua_string(piece["topic"]), _lua_string(piece["role"]),
            piece.get("parts", 0), piece.get("triangles", 0),
            piece.get("unanchored", 0), _lua_string(piece["verdict"]))
        #: Ordered so `pick` returns the best of a topic without sorting at
        #: runtime, and clean before caveats at equal score.
        for piece in sorted(assets, key=lambda p: (
            p["kind"], p["topic"], p["verdict"] != "ok", -p["score"]))
    )

    topics = {piece["topic"] for piece in assets}
    LUA_PATH.parent.mkdir(parents=True, exist_ok=True)
    LUA_PATH.write_text(
        _LUA_HEADER % {
            "swept": data.get("sweptAt", "?"),
            "sweptQuoted": _lua_string(data.get("sweptAt", "?")),
            "count": len(assets),
            "topics": len(topics),
            "entries": entries,
        } + _LUA_FOOTER,
        encoding="utf-8")
    return LUA_PATH, len(assets)
