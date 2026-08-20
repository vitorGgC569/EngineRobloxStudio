"""Reuse as tools a caller can reach for while building.

The registry decided and the connectors act; this is what puts both in front of
whoever is actually making the game. The shape matters: these are five small
questions asked in the order a builder asks them, not one `source_everything`
that decides on their behalf.

    sourcing_search     what exists for this need, and under what licence
    sourcing_adopt      take a pack that is on disk, recording where it came from
    sourcing_inspect    what is inside it, with hashes
    sourcing_publish    put one asset on Roblox -- the irreversible step, alone
    sourcing_decide     what the policy says: reuse, adapt or generate

`sourcing_publish` is deliberately its own tool rather than a flag on adopt.
It uploads to a real account under a real name and goes through moderation, and
an irreversible act should never be a parameter on a reversible one.
"""

from __future__ import annotations

from pathlib import Path
from typing import Any

from .server import Tool


def register_sourcing_tools(server: Any) -> Any:
    """Attach the sourcing tools to an MCP server."""

    root = server.root

    from ..sourcing import connectors, registry

    def search(arguments: dict[str, Any]) -> dict[str, Any]:
        need = str(arguments.get("need") or "")
        kind = str(arguments.get("kind") or "")
        hits = connectors.search(need, kind=kind) if need else connectors.catalogues(kind)
        return {
            "need": need,
            "kind": kind or "any",
            "results": hits,
            "note": (
                "licence is the first filter, not the last: a pack this project "
                "may not ship is never offered here"
            ),
        }

    def adopt(arguments: dict[str, Any]) -> dict[str, Any]:
        return connectors.adopt(
            Path(str(arguments["path"])),
            source=str(arguments["source"]),
            pack=str(arguments["pack"]),
            kind=str(arguments["kind"]),
            licence=str(arguments["licence"]),
            root=root,
            note=str(arguments.get("note") or ""),
        )

    def inspect(arguments: dict[str, Any]) -> dict[str, Any]:
        found = connectors.assets(
            str(arguments["source"]), str(arguments["pack"]),
            root=root, kind=str(arguments.get("kind") or ""),
            limit=int(arguments.get("limit") or 60),
        )
        return {
            "source": arguments["source"],
            "pack": arguments["pack"],
            "count": len(found),
            "assets": [item.to_dict() for item in found],
        }

    def publish(arguments: dict[str, Any]) -> dict[str, Any]:
        found = connectors.assets(
            str(arguments["source"]), str(arguments["pack"]), root=root)
        wanted = str(arguments["asset"])
        asset = next((item for item in found if item.id == wanted), None)
        if asset is None:
            return {
                "published": False,
                "reason": f"no asset {wanted!r} in {arguments['pack']}",
                "available": [item.id for item in found[:20]],
            }
        started = connectors.publish(
            asset,
            key_path=Path(str(arguments["keyPath"])),
            creator_user_id=str(arguments["creatorUserId"]),
            display_name=str(arguments.get("displayName") or ""),
        )
        started["published"] = True
        started["note"] = (
            "moderation is asynchronous; poll with sourcing_operation before "
            "treating the id as usable"
        )
        return started

    def operation(arguments: dict[str, Any]) -> dict[str, Any]:
        return connectors.operation(
            str(arguments["operationId"]),
            key_path=Path(str(arguments["keyPath"])),
        )

    def decide(arguments: dict[str, Any]) -> dict[str, Any]:
        verdict = registry.decide(
            str(arguments.get("need") or ""),
            role=str(arguments.get("role") or ""),
            kind=str(arguments.get("kind") or "geometry"),
            available=list(arguments.get("available") or ()),
        )
        return verdict.to_dict()

    server.register(Tool(
        name="sourcing_search",
        description=(
            "What external packs cover a need, and under what licence. "
            "Omit `need` to list everything known."
        ),
        input_schema={
            "type": "object",
            "properties": {
                "need": {"type": "string",
                         "description": "e.g. tree, denied, damage, rock"},
                "kind": {"type": "string",
                         "enum": ["audio", "geometry", "material", "icon"]},
            },
        },
        handler=search,
    ))

    server.register(Tool(
        name="sourcing_adopt",
        description=(
            "Record a pack already on disk under a stated licence, copying it "
            "into the cache with a provenance file. Refuses a licence a "
            "generated game may not ship."
        ),
        input_schema={
            "type": "object",
            "required": ["path", "source", "pack", "kind", "licence"],
            "properties": {
                "path": {"type": "string"},
                "source": {"type": "string"},
                "pack": {"type": "string"},
                "kind": {"type": "string",
                         "enum": ["audio", "geometry", "material", "icon"]},
                "licence": {"type": "string",
                            "description": "CC0, CC-BY-4.0, MIT, ..."},
                "note": {"type": "string"},
            },
        },
        handler=adopt,
    ))

    server.register(Tool(
        name="sourcing_inspect",
        description="The usable files in an adopted pack, each with its hash.",
        input_schema={
            "type": "object",
            "required": ["source", "pack"],
            "properties": {
                "source": {"type": "string"},
                "pack": {"type": "string"},
                "kind": {"type": "string"},
                "limit": {"type": "integer", "minimum": 1, "maximum": 400},
            },
        },
        handler=inspect,
    ))

    server.register(Tool(
        name="sourcing_publish",
        description=(
            "Upload one adopted asset to Roblox through Open Cloud. "
            "IRREVERSIBLE: it publishes under a real account and goes through "
            "moderation. Its own tool on purpose, never a flag on adopt."
        ),
        input_schema={
            "type": "object",
            "required": ["source", "pack", "asset", "keyPath", "creatorUserId"],
            "properties": {
                "source": {"type": "string"},
                "pack": {"type": "string"},
                "asset": {"type": "string"},
                "keyPath": {
                    "type": "string",
                    "description": "path to the Open Cloud key file; the key is "
                                   "read there and used only as a header",
                },
                "creatorUserId": {"type": "string"},
                "displayName": {"type": "string"},
            },
        },
        handler=publish,
    ))

    server.register(Tool(
        name="sourcing_operation",
        description="Poll an upload; carries the asset id once moderation answers.",
        input_schema={
            "type": "object",
            "required": ["operationId", "keyPath"],
            "properties": {
                "operationId": {"type": "string"},
                "keyPath": {"type": "string"},
            },
        },
        handler=operation,
    ))

    server.register(Tool(
        name="sourcing_decide",
        description=(
            "What the policy says for one need: reuse, adapt or generate, with "
            "the reason. Identity roles and modular roles are always generated."
        ),
        input_schema={
            "type": "object",
            "required": ["need", "role"],
            "properties": {
                "need": {"type": "string"},
                "role": {"type": "string",
                         "description": "vegetation, hero, structure, prop, ..."},
                "kind": {"type": "string"},
                "available": {"type": "array", "items": {"type": "string"}},
            },
        },
        handler=decide,
    ))

    return server
