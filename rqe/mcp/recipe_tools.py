"""Gameplay recipes, exposed to an agent.

    recipe_catalogue  every genre the engine builds, and what each requires
    recipe_apply      a configuration becomes a whole, coherent game model
    recipe_check      does a model deliver the genre it claims

The point is scale. CardTycoon and MiningTycoon are not two projects; they are
one recipe and two configurations, and treating them as two projects is how the
second takes as long as the first.

`recipe_apply` supplies what the genre implies and refuses to invent what
distinguishes one game from another -- the theme, the pitch, the currency names.
A recipe that supplied those would be generating games rather than genres.
"""

from __future__ import annotations

from typing import Any

from .ir_tools import GAME_MODEL_SCHEMA
from .server import EngineMcpServer, Tool, ToolError


def register_recipe_tools(server: EngineMcpServer) -> EngineMcpServer:

    def recipe_catalogue(_: dict[str, Any]) -> dict[str, Any]:
        from ..recipes import catalogue

        return catalogue()

    server.register(Tool(
        name="recipe_catalogue",
        description=(
            "Every genre the engine has a production path for, and what each requires: "
            "the loop it must contain, the systems it cannot work without, the world "
            "shape and the pacing it usually has. Read this before writing a game model "
            "from scratch."
        ),
        input_schema={"type": "object", "additionalProperties": False, "properties": {}},
        handler=recipe_catalogue,
    ))

    def recipe_apply(arguments: dict[str, Any]) -> dict[str, Any]:
        from ..recipes import RecipeError, apply, check

        try:
            model = apply(
                str(arguments["genre"]),
                id=str(arguments["id"]),
                theme=str(arguments["theme"]),
                pitch=str(arguments["pitch"]),
                currencies=arguments.get("currencies", ()),
                zones=arguments.get("zones", ()),
                extra_verbs=arguments.get("extraVerbs", ()),
                extra_systems=arguments.get("extraSystems", ()),
                tiers=arguments.get("tiers"),
                first_tier_seconds=arguments.get("firstTierSeconds"),
                session_minutes=arguments.get("sessionMinutes"),
                token_set=str(arguments.get("tokenSet", "tokens/brickfarm.json")),
                monetization=arguments.get("monetization", ()),
                concurrent_players=int(arguments.get("concurrentPlayers", 1)),
                private_space=bool(arguments.get("privateSpace", False)),
            )
        except RecipeError as exc:
            raise ToolError(str(exc)) from exc

        return {
            "model": model.to_dict(),
            "sha256": model.sha256,
            "coherent": model.coherent,
            "conformance": check(model),
            "summary": model.summary(),
            "note": (
                "everything the genre implied was supplied; the theme, the pitch and "
                "the currencies are what make this game not another of its genre"
            ),
        }

    server.register(Tool(
        name="recipe_apply",
        description=(
            "Turn a small configuration -- a genre, a theme, a pitch -- into a whole "
            "coherent game model, with the loop, systems, world shape and pacing the "
            "genre implies. Refuses a configuration that would produce an incoherent "
            "model rather than handing back a starting point somebody then fixes."
        ),
        input_schema={
            "type": "object",
            "required": ["genre", "id", "theme", "pitch"],
            "additionalProperties": False,
            "properties": {
                "genre": {"type": "string"},
                "id": {"type": "string", "minLength": 1},
                "theme": {"type": "string", "minLength": 1},
                "pitch": {"type": "string", "minLength": 1},
                "currencies": {"type": "array", "items": {"type": "object"}},
                "zones": {"type": "array", "items": {"type": "object"}},
                "extraVerbs": {"type": "array", "items": {"type": "string"}},
                "extraSystems": {"type": "array", "items": {"type": "string"}},
                "tiers": {"type": "integer", "minimum": 0},
                "firstTierSeconds": {"type": "number", "minimum": 0},
                "sessionMinutes": {"type": "number", "minimum": 0},
                "tokenSet": {"type": "string"},
                "monetization": {"type": "array", "items": {"type": "string"}},
                "concurrentPlayers": {"type": "integer", "minimum": 1},
                "privateSpace": {"type": "boolean"},
            },
        },
        handler=recipe_apply,
    ))

    def recipe_check(arguments: dict[str, Any]) -> dict[str, Any]:
        from ..ir import GameModelError, load_model
        from ..recipes import check, conforms

        try:
            model = load_model(arguments["model"])
        except GameModelError as exc:
            raise ToolError(str(exc)) from exc

        findings = check(model)
        return {
            "id": model.id,
            "genre": model.genre,
            "conforms": conforms(model),
            "problems": [item for item in findings if not item.startswith("note:")],
            "notes": [item for item in findings if item.startswith("note:")],
            "note": (
                "genre is the word every downstream decision keys off -- the template, "
                "the scenario classes, the asset roles -- so a game mislabelled at the "
                "top is measured against the wrong bar all the way down"
            ),
        }

    server.register(Tool(
        name="recipe_check",
        description=(
            "Does a model deliver the genre it claims: a tycoon with no economy, a "
            "tower defense whose loop never defends. Separates defects from notes, "
            "because an unusual world shape is unusual rather than wrong."
        ),
        input_schema={
            "type": "object",
            "required": ["model"],
            "additionalProperties": False,
            "properties": {"model": GAME_MODEL_SCHEMA},
        },
        handler=recipe_check,
    ))

    return server
