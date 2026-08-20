"""The Game IR, exposed to an agent.

    game_vocabulary  the genres, topologies, systems and loop verbs available
    game_validate    is this game internally coherent, before anything is built
    game_compile     model -> production plan, through the real compiler

The point of the family is `game_validate`. A game can parse, compile, build and
not work: a loop verb with no system behind it, a currency nothing earns, a zone
gated above the last tier, progression with no save. Every one of those is
decidable from the model alone in milliseconds, and every one otherwise surfaces
as a play session that goes wrong in a way nobody can attribute.

`game_vocabulary` is here so an agent does not have to guess. A genre the engine
has no production path for, or a system with no implementation, would be caught
by validation -- but being told the real list up front is the difference between
one call and four.
"""

from __future__ import annotations

import json
from typing import Any

from .server import EngineMcpServer, Tool, ToolError


GAME_MODEL_SCHEMA = {
    "type": "object",
    "required": ["id", "genre", "theme", "pitch", "coreLoop", "world", "progression"],
    "properties": {
        "id": {"type": "string", "minLength": 1},
        "genre": {"type": "string"},
        "theme": {"type": "string"},
        "pitch": {"type": "string", "minLength": 1},
        "coreLoop": {"type": "array", "minItems": 1, "items": {"type": "string"}},
        "world": {
            "type": "object",
            "required": ["topology"],
            "properties": {
                "topology": {"type": "string"},
                "zones": {
                    "type": "array",
                    "items": {
                        "type": "object",
                        "required": ["id"],
                        "properties": {
                            "id": {"type": "string"},
                            "theme": {"type": "string"},
                            "difficulty": {"type": "integer", "minimum": 1},
                            "unlockedAtTier": {"type": "integer", "minimum": 0},
                        },
                    },
                },
            },
        },
        "progression": {
            "type": "object",
            "required": ["kind"],
            "properties": {
                "kind": {"type": "string"},
                "tiers": {"type": "integer", "minimum": 0},
                "firstTierSeconds": {"type": "number", "minimum": 0},
                "sessionMinutes": {"type": "number", "minimum": 0},
            },
        },
        "economy": {
            "type": "object",
            "properties": {
                "currencies": {
                    "type": "array",
                    "items": {
                        "type": "object",
                        "required": ["id"],
                        "properties": {
                            "id": {"type": "string"},
                            "displayName": {"type": "string"},
                            "earnedBy": {"type": "array", "items": {"type": "string"}},
                            "spentOn": {"type": "array", "items": {"type": "string"}},
                            "premium": {"type": "boolean"},
                        },
                    },
                },
            },
        },
        "systems": {"type": "array", "items": {"type": "string"}},
        "monetization": {"type": "array", "items": {"type": "string"}},
        "tokenSet": {"type": "string"},
        "concurrentPlayers": {"type": "integer", "minimum": 1},
        "privateSpace": {"type": "boolean"},
    },
}


def register_ir_tools(server: EngineMcpServer) -> EngineMcpServer:
    root = server.root

    def game_vocabulary(_: dict[str, Any]) -> dict[str, Any]:
        from ..ir import (
            GENRES, LOOP_VERB_SYSTEMS, MONETIZATION_KINDS,
            PROGRESSION_KINDS, SYSTEM_REQUIREMENTS, TOPOLOGIES,
        )

        return {
            "genres": list(GENRES),
            "topologies": list(TOPOLOGIES),
            "progressionKinds": list(PROGRESSION_KINDS),
            "monetization": list(MONETIZATION_KINDS),
            "systems": {
                name: {"requires": list(requires)}
                for name, requires in sorted(SYSTEM_REQUIREMENTS.items())
            },
            "coreLoopVerbs": {
                verb: {"needsSystems": list(systems)}
                for verb, systems in sorted(LOOP_VERB_SYSTEMS.items())
            },
            "note": (
                "a loop verb with no system behind it builds fine and the player cannot "
                "do it, so the verbs list what each one needs"
            ),
        }

    server.register(Tool(
        name="game_vocabulary",
        description=(
            "The genres, world topologies, progression kinds, systems and core-loop verbs "
            "a game model may use, and what each verb needs behind it. Read this before "
            "writing a model."
        ),
        input_schema={"type": "object", "additionalProperties": False, "properties": {}},
        handler=game_vocabulary,
    ))

    def game_validate(arguments: dict[str, Any]) -> dict[str, Any]:
        from ..ir import GameModelError, load_model, required_systems

        try:
            model = load_model(arguments["model"])
        except GameModelError as exc:
            # Malformed, not incoherent. Reported as an error because there is
            # no model to reason about yet.
            raise ToolError(str(exc)) from exc

        problems = model.problems()
        return {
            "id": model.id,
            "coherent": not problems,
            "problems": problems,
            "requiredSystems": required_systems(model),
            "declaredSystems": list(model.systems),
            "missingSystems": sorted(set(required_systems(model)) - set(model.systems)),
            "sha256": model.sha256,
            "summary": model.summary(),
            "note": (
                "coherence is decided from the model alone -- no Studio, no build. Each "
                "problem here is a game that would compile, build, and not work"
            ),
        }

    server.register(Tool(
        name="game_validate",
        description=(
            "Check a game model for internal incoherence before anything is built: loop "
            "verbs with no system behind them, currencies nothing earns or nothing spends, "
            "zones gated above the last tier, progression with no save. Reports every "
            "problem at once, because fixing them one exception at a time is how a model "
            "takes six passes to become playable."
        ),
        input_schema={
            "type": "object",
            "required": ["model"],
            "additionalProperties": False,
            "properties": {"model": GAME_MODEL_SCHEMA},
        },
        handler=game_validate,
    ))

    def game_compile(arguments: dict[str, Any]) -> dict[str, Any]:
        from ..ir import GameModelError, load_model
        from ..ir.compiler import compile_model, to_product_intent

        try:
            model = load_model(arguments["model"])
            result = compile_model(model, root=root)
        except GameModelError as exc:
            raise ToolError(str(exc)) from exc

        plan = result["plan"]
        projects = plan.get("projects", [])
        tasks = projects[0].get("tasks", []) if projects else []

        payload: dict[str, Any] = {
            "id": model.id,
            "modelSha256": result["modelSha256"],
            "planId": plan.get("planId"),
            "tasks": len(tasks),
            "stages": sorted({task.get("stage") for task in tasks if task.get("stage")}),
            "systems": result["systems"],
            "productIntent": to_product_intent(model),
            "note": result["note"],
        }
        if arguments.get("includePlan"):
            payload["plan"] = plan
        if arguments.get("includeBlueprint"):
            payload["blueprint"] = result["blueprint"]

        if arguments.get("write"):
            output = (root / arguments["write"]).resolve()
            try:
                output.relative_to(root.resolve())
            except ValueError as exc:
                raise ToolError("write path must stay inside the project root") from exc
            output.parent.mkdir(parents=True, exist_ok=True)
            output.write_text(
                json.dumps(result["blueprint"], indent=2, ensure_ascii=False) + "\n",
                encoding="utf-8",
            )
            payload["written"] = str(output.relative_to(root))
        return payload

    server.register(Tool(
        name="game_compile",
        description=(
            "Compile a game model into the production plan, through the same compiler the "
            "factory uses. Refuses an incoherent model rather than producing a task graph "
            "that would spend every hour of execution on a known defect. Builds nothing."
        ),
        input_schema={
            "type": "object",
            "required": ["model"],
            "additionalProperties": False,
            "properties": {
                "model": GAME_MODEL_SCHEMA,
                "includePlan": {"type": "boolean"},
                "includeBlueprint": {"type": "boolean"},
                "write": {
                    "type": "string",
                    "description": "path to write the derived blueprint to",
                },
            },
        },
        handler=game_compile,
    ))

    def game_new(arguments: dict[str, Any]) -> dict[str, Any]:
        """Create the project, laid out, from the model.

        The complaint this answers is exact: an agent should not begin a game by
        deciding where files go. Two agents deciding independently produce two
        layouts, and every tool that walks a project then handles both.
        """

        from ..economy import EconomyError, Targets, solve
        from ..ir import GameModelError, load_model
        from ..ir.scaffold import ScaffoldError, scaffold_project

        try:
            model = load_model(arguments["model"])
        except GameModelError as exc:
            raise ToolError(str(exc)) from exc

        economy = None
        if arguments.get("solveEconomy", True) and model.progression.tiers >= 2                 and model.progression.first_tier_seconds > 0:
            total = float(arguments.get("totalMinutes")
                          or model.progression.session_minutes or 0)
            if total > 0:
                try:
                    economy = solve(root, Targets(
                        tiers=model.progression.tiers,
                        first_tier_seconds=model.progression.first_tier_seconds,
                        total_minutes=total,
                        income_multiplier=float(arguments.get("incomeMultiplier", 1.0)),
                    )).to_dict()
                except EconomyError as exc:
                    # Reported, not fatal. A project whose curve needs another
                    # pass is still a project worth having on disk.
                    economy = {"unsolved": str(exc)}

        try:
            scaffold = scaffold_project(
                model, root=root, force=bool(arguments.get("force", False)),
                economy=economy,
            )
        except ScaffoldError as exc:
            raise ToolError(str(exc)) from exc

        payload = scaffold.to_dict()
        payload["summary"] = scaffold.summary()
        payload["economySolved"] = bool(economy and "unsolved" not in economy)
        return payload

    server.register(Tool(
        name="game_new",
        description=(
            "Create a game project from a model: definitions, blueprint, source roots, "
            "catalogs, economy and scenarios, every file derived from the one model. "
            "Refuses an incoherent model rather than writing a tree somebody has to "
            "discover is wrong, and leaves existing files alone."
        ),
        input_schema={
            "type": "object",
            "required": ["model"],
            "additionalProperties": False,
            "properties": {
                "model": GAME_MODEL_SCHEMA,
                "solveEconomy": {"type": "boolean"},
                "totalMinutes": {"type": "number", "exclusiveMinimum": 0},
                "incomeMultiplier": {"type": "number", "exclusiveMinimum": 0},
                "force": {"type": "boolean"},
            },
        },
        handler=game_new,
    ))

    return server
