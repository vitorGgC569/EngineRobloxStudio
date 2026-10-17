"""Content generation, exposed to an agent.

    content_generate    a whole family from a declaration, checked both ways
    content_from_model  the same, with tiers and theme taken from the game
    content_drop_table  a table for one tier, closed to exactly 1.0

The value is not the generating. It is that a catalogue produced by hand or by
prompt is quietly incoherent -- a tier weaker than the one below it, a rarity
nobody can roll, a variant strictly worse than its neighbour, a table summing to
0.97 -- and none of those crash. `consistency` asks whether the catalogue is
well-formed; `balance` asks whether it is fair, which is the question a
well-formed catalogue can still fail.
"""

from __future__ import annotations

import json
from typing import Any

from .ir_tools import GAME_MODEL_SCHEMA
from .server import EngineMcpServer, Tool, ToolError
from ..safe_io import SafeIoError, atomic_write_text
from ..security import SecurityBoundaryError, resolve_inside


SCHEMA_PROPERTIES = {
    "id": {"type": "string", "minLength": 1},
    "kind": {"type": "string"},
    "theme": {"type": "string", "minLength": 1},
    "tiers": {"type": "integer", "minimum": 1, "maximum": 40},
    "variantsPerTier": {"type": "integer", "minimum": 1, "maximum": 12},
    "roles": {"type": "array", "items": {"type": "string"}},
    "powerStep": {"type": "number"},
    "basePower": {"type": "number", "exclusiveMinimum": 0},
    "seed": {"type": "integer", "minimum": 0},
}


def _schema_from(arguments: dict[str, Any]):
    from ..content import ContentError, ContentSchema

    document = arguments["family"]
    try:
        return ContentSchema(
            id=str(document["id"]),
            kind=str(document.get("kind", "collectible")),
            theme=str(document.get("theme", "")),
            tiers=int(document.get("tiers", 1)),
            variants_per_tier=int(document.get("variantsPerTier", 1)),
            roles=tuple(str(role) for role in document.get("roles", ())),
            power_step=float(document.get("powerStep", 1.4)),
            base_power=float(document.get("basePower", 10.0)),
            seed=int(document.get("seed", 0)),
        )
    except (ContentError, KeyError, TypeError, ValueError) as exc:
        raise ToolError(str(exc)) from exc


def register_content_tools(server: EngineMcpServer) -> EngineMcpServer:
    root = server.root

    def content_generate(arguments: dict[str, Any]) -> dict[str, Any]:
        from ..content import build

        payload = build(_schema_from(arguments))
        if not arguments.get("includeEntries", True):
            payload["catalogue"].pop("entries", None)
        if arguments.get("write"):
            try:
                target = resolve_inside(
                    root,
                    arguments["write"],
                    label="write path",
                    suffixes=(".json",),
                )
                status = atomic_write_text(
                    target,
                json.dumps(payload["catalogue"], indent=2, ensure_ascii=False) + "\n",
                    overwrite=bool(arguments.get("overwrite")),
                )
            except (SecurityBoundaryError, SafeIoError) as exc:
                raise ToolError(str(exc)) from exc
            payload["written"] = str(target.relative_to(root))
            payload["writeStatus"] = status
        return payload

    server.register(Tool(
        name="content_generate",
        description=(
            "Generate a whole content family -- tiers, variants and roles -- "
            "deterministically from a declaration, then check it two ways: consistency "
            "for duplicate ids, empty tiers and missing roles, and balance for a tier "
            "that is not stronger than the last, a variant nobody would ever pick, and a "
            "rarity nobody can roll. A well-formed unfair catalogue passes every other "
            "check in the engine."
        ),
        input_schema={
            "type": "object",
            "required": ["family"],
            "additionalProperties": False,
            "properties": {
                "family": {
                    "type": "object",
                    "required": ["id", "theme", "tiers"],
                    "additionalProperties": False,
                    "properties": SCHEMA_PROPERTIES,
                },
                "includeEntries": {"type": "boolean"},
                "write": {"type": "string"},
                "overwrite": {"type": "boolean"},
            },
        },
        handler=content_generate,
    ))

    def content_from_model(arguments: dict[str, Any]) -> dict[str, Any]:
        from ..content import ContentError, build, from_model
        from ..ir import GameModelError, load_model

        try:
            model = load_model(arguments["model"])
            schema = from_model(
                model,
                kind=str(arguments.get("kind", "collectible")),
                variants_per_tier=int(arguments.get("variantsPerTier", 4)),
                roles=tuple(arguments.get("roles",
                                          ("melee", "ranged", "tank", "support"))),
            )
        except (GameModelError, ContentError) as exc:
            raise ToolError(str(exc)) from exc

        payload = build(schema)
        payload["gameId"] = model.id
        if not arguments.get("includeEntries", True):
            payload["catalogue"].pop("entries", None)
        return payload

    server.register(Tool(
        name="content_from_model",
        description=(
            "Generate a content family for a game, taking the tier count and theme from "
            "the model rather than the caller. Content generated for a different number "
            "of tiers than the game has is content unreachable behind a tier that does "
            "not exist."
        ),
        input_schema={
            "type": "object",
            "required": ["model"],
            "additionalProperties": False,
            "properties": {
                "model": GAME_MODEL_SCHEMA,
                "kind": {"type": "string"},
                "variantsPerTier": {"type": "integer", "minimum": 1, "maximum": 12},
                "roles": {"type": "array", "items": {"type": "string"}},
                "includeEntries": {"type": "boolean"},
            },
        },
        handler=content_from_model,
    ))

    def content_drop_table(arguments: dict[str, Any]) -> dict[str, Any]:
        from ..content import ContentError, drop_table, generate

        try:
            return drop_table(generate(_schema_from(arguments)),
                              tier=int(arguments["tier"]))
        except ContentError as exc:
            raise ToolError(str(exc)) from exc

    server.register(Tool(
        name="content_drop_table",
        description=(
            "A drop table for one tier, normalised from the rarities actually present "
            "and closed to exactly 1.0. A hand-written table sums to 0.97 and the "
            "missing three percent silently becomes whichever branch happens to be last."
        ),
        input_schema={
            "type": "object",
            "required": ["family", "tier"],
            "additionalProperties": False,
            "properties": {
                "family": {
                    "type": "object",
                    "required": ["id", "theme", "tiers"],
                    "additionalProperties": False,
                    "properties": SCHEMA_PROPERTIES,
                },
                "tier": {"type": "integer", "minimum": 1},
            },
        },
        handler=content_drop_table,
    ))

    return server
