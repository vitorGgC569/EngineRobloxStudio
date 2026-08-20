"""The system composer, exposed to an agent.

    system_catalogue  every system the engine knows, and which ones exist
    system_compose    the systems a model needs, ordered, configured and loaded

The Game IR already knew *which* systems a game needs. What it could not do was
hand back anything runnable. `system_compose` names the module behind each one,
the order they start in, and the configuration derived from the model -- then
requires and calls every implemented module through the headless harness, so
"composed" means "loaded" rather than "referenced".

A system with no module is reported as `PLANNED` with its reason rather than
omitted. Ten of the fifteen have none yet, and a listing that showed only the
five would make a model asking for `gacha` look complete.
"""

from __future__ import annotations

from typing import Any

from .ir_tools import GAME_MODEL_SCHEMA
from .server import EngineMcpServer, Tool, ToolError


def register_system_tools(server: EngineMcpServer) -> EngineMcpServer:
    root = server.root

    def system_catalogue(_: dict[str, Any]) -> dict[str, Any]:
        from ..systems import catalogue

        return catalogue()

    server.register(Tool(
        name="system_catalogue",
        description=(
            "Every system the composer knows, which have a module behind them and which "
            "are planned, with the reason for each gap. Read this before declaring a "
            "model's systems."
        ),
        input_schema={"type": "object", "additionalProperties": False, "properties": {}},
        handler=system_catalogue,
    ))

    def system_compose(arguments: dict[str, Any]) -> dict[str, Any]:
        from ..ir import GameModelError, load_model
        from ..systems import CompositionError, compose, verify

        try:
            model = load_model(arguments["model"])
        except GameModelError as exc:
            raise ToolError(str(exc)) from exc

        try:
            composition = compose(model)
            if arguments.get("verify", True):
                composition = verify(root, composition)
        except CompositionError as exc:
            raise ToolError(str(exc)) from exc

        payload = composition.to_dict()
        payload["summary"] = composition.summary()
        return payload

    server.register(Tool(
        name="system_compose",
        description=(
            "Assemble the systems a game model needs: which SDK module implements each, "
            "the order they start in, and the configuration derived from the model. "
            "Loads and calls every implemented module through the headless harness, so a "
            "composition that reports success is one that ran. Reports a module that only "
            "works inside a live game as a finding rather than a failure."
        ),
        input_schema={
            "type": "object",
            "required": ["model"],
            "additionalProperties": False,
            "properties": {
                "model": GAME_MODEL_SCHEMA,
                "verify": {"type": "boolean"},
            },
        },
        handler=system_compose,
    ))

    return server
