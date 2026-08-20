"""The economy designer, exposed to an agent.

    economy_design      session targets -> a verified cost ladder
    economy_from_model  the same, using the targets a game model already declares

`pacing_simulate` answers the forward question: given costs, how long does each
tier take. These answer the inverse, which is the half a designer was previously
doing by hand -- guess, simulate, read, adjust, repeat, and ship whichever
numbers they got tired at.

Every answer is measured against the `Progression` module the game runs, and the
drift between what was asked and what that module reports comes back in the
result. A solver that only agreed with itself would be a second implementation
of pacing, and the two would drift.
"""

from __future__ import annotations

from typing import Any

from .ir_tools import GAME_MODEL_SCHEMA
from .server import EngineMcpServer, Tool, ToolError


def register_economy_tools(server: EngineMcpServer) -> EngineMcpServer:
    root = server.root

    def economy_design(arguments: dict[str, Any]) -> dict[str, Any]:
        from ..economy import EconomyError, Targets, design, session_spread, solve

        try:
            targets = Targets(
                tiers=int(arguments["tiers"]),
                first_tier_seconds=float(arguments["firstTierSeconds"]),
                total_minutes=float(arguments["totalMinutes"]),
                income_multiplier=float(arguments.get("incomeMultiplier", 1.0)),
                base_income_per_second=float(arguments.get("baseIncomePerSecond", 1.0)),
            )
            result = (solve(root, targets, policy=arguments.get("policy"))
                      if arguments.get("verify", True) else design(targets))
        except EconomyError as exc:
            raise ToolError(str(exc)) from exc

        payload = result.to_dict()
        payload["summary"] = result.summary()
        if arguments.get("sessionMinutes"):
            payload["sessionSpread"] = session_spread(
                result, session_minutes=float(arguments["sessionMinutes"]))
        return payload

    server.register(Tool(
        name="economy_design",
        description=(
            "Solve a cost ladder from how the session should feel -- the first upgrade in "
            "45 seconds, the ladder finished in 90 minutes -- and verify it by running the "
            "shipped Progression module. Reports the drift between what was asked and what "
            "the game's own code measures."
        ),
        input_schema={
            "type": "object",
            "required": ["tiers", "firstTierSeconds", "totalMinutes"],
            "additionalProperties": False,
            "properties": {
                "tiers": {"type": "integer", "minimum": 2},
                "firstTierSeconds": {"type": "number", "exclusiveMinimum": 0},
                "totalMinutes": {"type": "number", "exclusiveMinimum": 0},
                "incomeMultiplier": {"type": "number", "exclusiveMinimum": 0},
                "baseIncomePerSecond": {"type": "number", "exclusiveMinimum": 0},
                "sessionMinutes": {
                    "type": "number", "exclusiveMinimum": 0,
                    "description": "also report where players land in one session",
                },
                "policy": {"type": "object"},
                "verify": {"type": "boolean"},
            },
        },
        handler=economy_design,
    ))

    def economy_from_model(arguments: dict[str, Any]) -> dict[str, Any]:
        """Solve the economy a game model already asked for.

        The model carries `firstTierSeconds` and `sessionMinutes` because they
        are design decisions; restating them here would be a second place for
        the same number to live and a second place for it to be wrong.
        """

        from ..economy import EconomyError, Targets, session_spread, solve
        from ..ir import GameModelError, load_model

        try:
            model = load_model(arguments["model"])
        except GameModelError as exc:
            raise ToolError(str(exc)) from exc

        if model.progression.tiers < 2:
            raise ToolError(
                f"{model.id} declares {model.progression.tiers} tiers; a curve needs two"
            )
        if model.progression.first_tier_seconds <= 0:
            raise ToolError(
                f"{model.id} does not say how long the first tier should take, so there is "
                "nothing to solve against. Set progression.firstTierSeconds"
            )

        total = float(arguments.get("totalMinutes") or model.progression.session_minutes)
        if total <= 0:
            raise ToolError(
                "neither the model nor the call says how long the ladder should take; set "
                "progression.sessionMinutes or pass totalMinutes"
            )

        try:
            result = solve(root, Targets(
                tiers=model.progression.tiers,
                first_tier_seconds=model.progression.first_tier_seconds,
                total_minutes=total,
                income_multiplier=float(arguments.get("incomeMultiplier", 1.0)),
                base_income_per_second=float(arguments.get("baseIncomePerSecond", 1.0)),
            ), policy=arguments.get("policy"))
        except EconomyError as exc:
            raise ToolError(str(exc)) from exc

        payload = result.to_dict()
        payload["gameId"] = model.id
        payload["currencies"] = [currency.id for currency in model.currencies]
        payload["summary"] = result.summary()
        if model.progression.session_minutes > 0:
            payload["sessionSpread"] = session_spread(
                result, session_minutes=model.progression.session_minutes)
        return payload

    server.register(Tool(
        name="economy_from_model",
        description=(
            "Solve and verify the cost ladder a game model already implies, from the "
            "session targets it declares. Keeps the pacing intent in one place instead of "
            "restating it beside the model."
        ),
        input_schema={
            "type": "object",
            "required": ["model"],
            "additionalProperties": False,
            "properties": {
                "model": GAME_MODEL_SCHEMA,
                "totalMinutes": {"type": "number", "exclusiveMinimum": 0},
                "incomeMultiplier": {"type": "number", "exclusiveMinimum": 0},
                "baseIncomePerSecond": {"type": "number", "exclusiveMinimum": 0},
                "policy": {"type": "object"},
            },
        },
        handler=economy_from_model,
    ))

    return server
