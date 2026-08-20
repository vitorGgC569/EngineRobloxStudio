"""The design compiler, exposed to an agent.

    design_analyse  what the brief says, before anything is decided
    design_compile  a brief becomes a whole game design, showing its work

This is the only tool in the engine whose output has no verifiable right answer,
so it is the one that most needs to be arguable. Every field comes back with
STATED, INFERRED or DEFAULTED, and an inference names the words that produced
it. DEFAULTED is where disagreement belongs -- hiding it inside INFERRED is how a
generated design becomes something nobody feels able to change.

The result is held to one thing it *can* be held to: the model must be coherent
and must conform to its genre. A design that reads beautifully and compiles to
an incoherent game has failed.
"""

from __future__ import annotations

import json
from typing import Any

from .server import EngineMcpServer, Tool, ToolError


def register_design_tools(server: EngineMcpServer) -> EngineMcpServer:
    root = server.root

    def design_analyse(arguments: dict[str, Any]) -> dict[str, Any]:
        from ..design import DesignError, analyse

        try:
            return analyse(str(arguments["brief"])).to_dict()
        except DesignError as exc:
            raise ToolError(str(exc)) from exc

    server.register(Tool(
        name="design_analyse",
        description=(
            "Read a prose brief and report what it says -- genre candidates with the "
            "words that support each, mechanics, monetization, places, session length, "
            "and where it is ambiguous. Decides nothing: two genres with equal evidence "
            "is a question for a designer, and picking one silently is how a brief "
            "becomes a game nobody asked for."
        ),
        input_schema={
            "type": "object",
            "required": ["brief"],
            "additionalProperties": False,
            "properties": {"brief": {"type": "string", "minLength": 1}},
        },
        handler=design_analyse,
    ))

    def design_compile(arguments: dict[str, Any]) -> dict[str, Any]:
        from ..design import DesignError, compile_brief

        try:
            document = compile_brief(
                str(arguments["brief"]),
                id=str(arguments["id"]),
                genre=str(arguments.get("genre", "")),
                theme=str(arguments.get("theme", "")),
                pitch=str(arguments.get("pitch", "")),
                session_minutes=float(arguments.get("sessionMinutes", 0.0)),
                token_set=str(arguments.get("tokenSet", "tokens/brickfarm.json")),
            )
        except DesignError as exc:
            raise ToolError(str(exc)) from exc

        payload = document.to_dict()
        payload["summary"] = document.summary()

        if arguments.get("scaffold"):
            from ..ir.scaffold import ScaffoldError, scaffold_project

            try:
                scaffold = scaffold_project(document.model, root=root)
            except ScaffoldError as exc:
                raise ToolError(str(exc)) from exc
            payload["scaffold"] = scaffold.to_dict()
        return payload

    server.register(Tool(
        name="design_compile",
        description=(
            "Turn a prose brief into a whole game design: genre, core loop, currencies, "
            "progression, zones, systems and the screens they imply -- every field "
            "carrying whether the brief stated it, the compiler inferred it from named "
            "words, or nothing decided it and a default was taken. Refuses a design that "
            "compiles to an incoherent game, which is the one thing this layer can be "
            "held to."
        ),
        input_schema={
            "type": "object",
            "required": ["brief", "id"],
            "additionalProperties": False,
            "properties": {
                "brief": {"type": "string", "minLength": 1},
                "id": {"type": "string", "minLength": 1},
                "genre": {"type": "string"},
                "theme": {"type": "string"},
                "pitch": {"type": "string"},
                "sessionMinutes": {"type": "number", "minimum": 0},
                "tokenSet": {"type": "string"},
                "scaffold": {
                    "type": "boolean",
                    "description": "also create the project on disk",
                },
            },
        },
        handler=design_compile,
    ))

    return server
