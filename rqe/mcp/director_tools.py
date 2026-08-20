"""The art director, exposed to an agent.

    asset_plan  which assets a world needs, how many, unique or reused, at what cost

`mesh_brief` decides how to build *one* asset. This decides what a world needs
before any of them exist, and refuses a plan that does not fit.

The failure it prevents does not announce itself. A world authored
asset-by-asset accumulates forty unique meshes, each approved individually by a
validator that was only ever shown one at a time. Nothing rejects it, the phone
build stutters, and the cause is spread across forty defensible decisions.

Nothing here searches or generates. The plan says what to look for, what to
build, and what each may cost, so it can be argued with before an hour of
Blender time is spent on it.
"""

from __future__ import annotations

import json
from typing import Any

from .ir_tools import GAME_MODEL_SCHEMA
from .server import EngineMcpServer, Tool, ToolError


def register_director_tools(server: EngineMcpServer) -> EngineMcpServer:
    root = server.root

    def asset_plan(arguments: dict[str, Any]) -> dict[str, Any]:
        from ..assets.director import Budget, DirectorError, plan, plan_for_model
        from ..ir import GameModelError, load_model
        from ..world.grammar import GrammarError, build_world

        try:
            budget = Budget(
                triangles=int(arguments.get("triangleBudget", 120_000)),
                max_distinct=int(arguments.get("maxDistinct", 24)),
                hero_share_ceiling=float(arguments.get("heroShareCeiling", 0.45)),
            )
        except DirectorError as exc:
            raise ToolError(str(exc)) from exc

        world_spec = None
        model = None
        if "model" in arguments:
            try:
                model = load_model(arguments["model"])
            except GameModelError as exc:
                raise ToolError(str(exc)) from exc

            if model.zones and arguments.get("expandWorld", True):
                from ..tokens import TokenError, load_token_set

                relative = arguments.get("tokens") or model.token_set or "tokens/brickfarm.json"
                if not (root / relative).is_file():
                    raise ToolError(f"no token set at {relative}")
                try:
                    tokens = load_token_set(root, relative).data
                    world_spec = build_world(
                        f"{model.id}-world", tokens=tokens,
                        zones=[{"id": z.id, "theme": z.theme, "difficulty": z.difficulty}
                               for z in model.zones],
                        topology=model.topology,
                    )
                except (TokenError, GrammarError) as exc:
                    raise ToolError(str(exc)) from exc

        extra = [
            (str(item["id"]), str(item["role"]), int(item.get("instances", 1)))
            for item in arguments.get("extra", [])
        ]
        existing = [str(item) for item in arguments.get("existing", [])]
        source_offers = {
            str(item["id"]): tuple(str(source) for source in item.get("sources", []))
            for item in arguments.get("sourceOffers", [])
        }

        try:
            if model is not None:
                result = plan_for_model(model, world_spec=world_spec,
                                        budget=budget, existing=existing,
                                        source_offers=source_offers)
                for asset_id, role, instances in extra:
                    result.entries.extend(
                        plan(model.id, budget=budget,
                             extra=[(asset_id, role, instances)],
                             existing=existing,
                             source_offers=source_offers).entries
                    )
            else:
                result = plan(str(arguments.get("id", "scene")), budget=budget,
                              extra=extra, existing=existing,
                              source_offers=source_offers)
        except DirectorError as exc:
            raise ToolError(str(exc)) from exc

        payload = result.to_dict()
        payload["summary"] = result.summary()
        if world_spec is not None:
            payload["worldRegions"] = len(world_spec.regions)
        return payload

    server.register(Tool(
        name="asset_plan",
        description=(
            "Decide what a world's assets should be: which are needed, how many "
            "placements each serves, which must be unique and which are reused as a "
            "kit, what backend produces each, and how much of one triangle budget each "
            "may spend. Refuses a plan that does not fit, which is the check no "
            "per-asset validator can perform. Searches and generates nothing."
        ),
        input_schema={
            "type": "object",
            "additionalProperties": False,
            "properties": {
                "model": GAME_MODEL_SCHEMA,
                "id": {"type": "string", "minLength": 1},
                "triangleBudget": {"type": "integer", "minimum": 300},
                "maxDistinct": {"type": "integer", "minimum": 1},
                "heroShareCeiling": {"type": "number", "exclusiveMinimum": 0, "maximum": 1},
                "expandWorld": {"type": "boolean"},
                "tokens": {"type": "string"},
                "extra": {
                    "type": "array",
                    "items": {
                        "type": "object",
                        "required": ["id", "role"],
                        "additionalProperties": False,
                        "properties": {
                            "id": {"type": "string", "minLength": 1},
                            "role": {"type": "string"},
                            "instances": {"type": "integer", "minimum": 1},
                        },
                    },
                },
                "existing": {
                    "type": "array", "items": {"type": "string"},
                    "description": "assets already available; routed to DISCOVER",
                },
                "sourceOffers": {
                    "type": "array",
                    "description": (
                        "connector-proven offers for a semantic asset need; merely naming "
                        "a source here routes the plan but does not claim publication"
                    ),
                    "items": {
                        "type": "object",
                        "required": ["id", "sources"],
                        "additionalProperties": False,
                        "properties": {
                            "id": {"type": "string", "minLength": 1},
                            "sources": {
                                "type": "array",
                                "minItems": 1,
                                "uniqueItems": True,
                                "items": {"type": "string", "minLength": 1},
                            },
                        },
                    },
                },
            },
        },
        handler=asset_plan,
    ))

    return server
