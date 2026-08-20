"""The knowledge base, exposed to an agent.

    knowledge_coverage  what the base knows, and what it cannot know yet
    knowledge_record    add a production run to it
    knowledge_advise    what previous games of a genre landed on
    knowledge_query     one category, measured or honestly unavailable

The document's ask is that game #20 benefit from games #1 to #19. Half of what
it lists comes out of engine-side work -- curves, layouts, budgets, system sets,
failure patterns -- and half needs shipped games with players.

Asking for the second half comes back `UNAVAILABLE` with what would unlock it,
never as a zero. An empty average for retention looks like an answer, and that
is worse than having no retention question at all.
"""

from __future__ import annotations

from typing import Any

from .server import EngineMcpServer, Tool, ToolError


def register_knowledge_tools(server: EngineMcpServer) -> EngineMcpServer:
    root = server.root

    def knowledge_coverage(arguments: dict[str, Any]) -> dict[str, Any]:
        from ..knowledge import coverage

        return coverage(root, store=arguments.get("store", ".rqe/knowledge.jsonl"))

    server.register(Tool(
        name="knowledge_coverage",
        description=(
            "What the engine has learned from the games it has made, and what it cannot "
            "learn without shipping one. Categories needing players are listed rather "
            "than omitted, because deleting them would make the base look complete and "
            "quietly stop anybody asking."
        ),
        input_schema={
            "type": "object",
            "additionalProperties": False,
            "properties": {"store": {"type": "string"}},
        },
        handler=knowledge_coverage,
    ))

    def knowledge_record(arguments: dict[str, Any]) -> dict[str, Any]:
        from ..knowledge import KnowledgeError, record
        from ..producer import ProducerError, produce

        try:
            run = produce(
                root,
                str(arguments["brief"]),
                game_id=str(arguments["id"]),
                genre=str(arguments.get("genre", "")),
                scaffold=bool(arguments.get("scaffold", False)),
            )
            entry = record(root, run, store=arguments.get("store", ".rqe/knowledge.jsonl"))
        except (ProducerError, KnowledgeError) as exc:
            raise ToolError(str(exc)) from exc

        return {
            "recorded": entry.to_dict(),
            "run": run.to_dict(),
            "note": (
                "append-only: a run is a fact about a moment, and rewriting history "
                "makes 'did the curve get steeper over time' unanswerable"
            ),
        }

    server.register(Tool(
        name="knowledge_record",
        description=(
            "Run a brief through the producer and remember what it decided: the curve "
            "that verified, the layout that validated, the systems it needed, the "
            "budget it fitted, and which stages refused. Appends; never rewrites."
        ),
        input_schema={
            "type": "object",
            "required": ["brief", "id"],
            "additionalProperties": False,
            "properties": {
                "brief": {"type": "string", "minLength": 1},
                "id": {"type": "string", "minLength": 1},
                "genre": {"type": "string"},
                "scaffold": {"type": "boolean"},
                "store": {"type": "string"},
            },
        },
        handler=knowledge_record,
    ))

    def knowledge_advise(arguments: dict[str, Any]) -> dict[str, Any]:
        from ..knowledge import advise

        return advise(root, str(arguments["genre"]),
                      store=arguments.get("store", ".rqe/knowledge.jsonl"))

    server.register(Tool(
        name="knowledge_advise",
        description=(
            "What previous games of a genre landed on: the step ratios their curves "
            "verified at, how many regions their zones expanded into, which systems "
            "they all needed and which they all wanted and lacked. A median is where "
            "the engine has been, not what is correct -- following it without thinking "
            "is how twenty games become one game twenty times."
        ),
        input_schema={
            "type": "object",
            "required": ["genre"],
            "additionalProperties": False,
            "properties": {
                "genre": {"type": "string", "minLength": 1},
                "store": {"type": "string"},
            },
        },
        handler=knowledge_advise,
    ))

    def knowledge_query(arguments: dict[str, Any]) -> dict[str, Any]:
        from ..knowledge import KnowledgeError, failures, query

        store = arguments.get("store", ".rqe/knowledge.jsonl")
        category = str(arguments["category"])
        try:
            if category == "failure_patterns":
                return failures(root, store=store)
            return query(root, category, genre=str(arguments.get("genre", "")),
                         store=store)
        except KnowledgeError as exc:
            raise ToolError(str(exc)) from exc

    server.register(Tool(
        name="knowledge_query",
        description=(
            "One category of what the engine has learned. Returns MEASURED with a "
            "spread, NO_DATA when nothing has been recorded yet, or UNAVAILABLE with "
            "what would unlock it when the category needs a shipped game -- never a "
            "zero, because an empty average looks like an answer."
        ),
        input_schema={
            "type": "object",
            "required": ["category"],
            "additionalProperties": False,
            "properties": {
                "category": {"type": "string", "minLength": 1},
                "genre": {"type": "string"},
                "store": {"type": "string"},
            },
        },
        handler=knowledge_query,
    ))

    return server
