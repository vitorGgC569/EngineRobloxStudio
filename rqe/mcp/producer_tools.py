"""The producer, exposed to an agent.

    producer_stages  the production graph, readable before anything runs
    producer_run     one brief, every layer, in dependency order

Ten layers exist and each answers to a different call. Driving them by hand
means knowing that the economy needs the model, the asset plan needs the world,
and the world needs the zones the design inferred -- and getting the order wrong
produces a plan for a game the design already said would not work.

A failed stage stops what depends on it and nothing else. Most of the work is
independent, and a run that gave up on the first refusal would throw away
nine-tenths of what it had already done.

Nothing here is an LLM. Each stage is one deterministic call into a layer that
already tests itself; the sequencing is the contribution.
"""

from __future__ import annotations

from typing import Any

from .server import EngineMcpServer, Tool, ToolError


def register_producer_tools(server: EngineMcpServer) -> EngineMcpServer:
    root = server.root

    def producer_stages(_: dict[str, Any]) -> dict[str, Any]:
        from ..producer import stages

        return {
            "schemaVersion": 1,
            "stages": stages(),
            "note": (
                "ordered by what each stage genuinely needs: the economy does not wait "
                "on the world, and the asset plan does"
            ),
        }

    server.register(Tool(
        name="producer_stages",
        description=(
            "The production graph the producer walks: every stage, what it waits on, and "
            "what it contributes. Readable before committing to a run."
        ),
        input_schema={"type": "object", "additionalProperties": False, "properties": {}},
        handler=producer_stages,
    ))

    def producer_run(arguments: dict[str, Any]) -> dict[str, Any]:
        from ..producer import (
            ProducerError,
            ProductionArtifactError,
            persist_production_run,
            produce,
        )

        profile = str(arguments.get("profile", "full"))
        skipped = ("geometry",) if profile == "static-no-geometry" else ()
        source_offers = {
            str(item["id"]): tuple(str(source) for source in item.get("sources", []))
            for item in arguments.get("sourceOffers", [])
        }
        try:
            run = produce(
                root,
                str(arguments["brief"]),
                game_id=str(arguments["id"]),
                genre=str(arguments.get("genre", "")),
                theme=str(arguments.get("theme", "")),
                token_set=str(arguments.get("tokenSet", "tokens/brickfarm.json")),
                triangle_budget=int(arguments.get("triangleBudget", 200_000)),
                scaffold=bool(arguments.get("scaffold", False)),
                skip_stages=skipped,
                source_offers=source_offers,
            )
            receipt = persist_production_run(
                run,
                project_root=root,
                run_id=arguments.get("runId"),
            )
        except (ProducerError, ProductionArtifactError, FileExistsError) as exc:
            raise ToolError(str(exc)) from exc

        payload = run.to_dict()
        payload["summary"] = run.summary()
        payload["artifactRun"] = receipt.to_dict()
        return payload

    server.register(Tool(
        name="producer_run",
        description=(
            "Drive every layer from one brief: design, systems, economy, content, world, "
            "interface, assets and the production plan, each in dependency order and "
            "each reporting what it decided. A stage that fails stops what depends on it "
            "and nothing else. Produces a built package, not a release-ready game: "
            "Studio runtime is still required. The static-no-geometry profile names Blender as "
            "omitted and can never satisfy the release stage. Every invocation finalizes an "
            "immutable, non-authorizing artifacts/<runId>/run.json trail."
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
                "tokenSet": {"type": "string"},
                "triangleBudget": {"type": "integer", "minimum": 300},
                "scaffold": {
                    "type": "boolean",
                    "description": "also create the project on disk, which the plan "
                                   "stage needs to hash its definitions",
                },
                "profile": {
                    "type": "string",
                    "enum": ["full", "static-no-geometry"],
                    "description": (
                        "full builds authored geometry; static-no-geometry emits the "
                        "explicit fallback for cheap static regression and blocks release"
                    ),
                },
                "runId": {
                    "type": "string",
                    "pattern": "^[A-Za-z0-9][A-Za-z0-9._-]{0,95}$",
                    "description": (
                        "optional immutable artifact run id; omitted generates a unique id"
                    ),
                },
                "sourceOffers": {
                    "type": "array",
                    "description": (
                        "connector-proven source availability for semantic asset needs; "
                        "this routes the AssetPlan but does not claim upload or integration"
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
        handler=producer_run,
    ))

    return server
