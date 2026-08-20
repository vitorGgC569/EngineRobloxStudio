"""Engine tools exposed over MCP.

This module holds the half that works **without Studio running** -- tokens,
compilation, headless SDK execution, pacing simulation, plan compilation. That
is what makes the server useful the moment an agent connects, rather than only
once a desktop session happens to be alive, and it is the same set that runs in
CI and in an Open Cloud task.

The live-Studio surface lives in `bridge_tools` and is added by `build_server`,
so a connecting agent gets the whole engine. It is kept separate because the two
halves have different failure modes: everything here either works or raises,
while a bridge call can be refused by a lease, a context or a disconnected
session, and those refusals have to survive the boundary with their codes
intact.
"""

from __future__ import annotations

import json
from pathlib import Path
from typing import Any

from .server import EngineMcpServer, Tool, ToolError


def _relative_path_schema(description: str) -> dict[str, Any]:
    return {"type": "string", "minLength": 1, "description": description}


def register_engine_tools(server: EngineMcpServer) -> EngineMcpServer:
    root = server.root

    # ---------------------------------------------------------- capabilities

    def capabilities(_: dict[str, Any]) -> dict[str, Any]:
        from ..luau_check import compiler_path, discover
        from ..luau_harness import runtime_path

        return {
            "root": str(root),
            "luauCompiler": compiler_path(root).is_file(),
            "luauRuntime": runtime_path(root).is_file(),
            "luauSources": len(discover(root)),
            "tokenSets": sorted(path.name for path in (root / "tokens").glob("*.json")),
            "sdkLibraries": sorted(
                path.name for path in (root / "roblox" / "lib").iterdir() if path.is_dir()
            ) if (root / "roblox" / "lib").is_dir() else [],
        }

    server.register(Tool(
        name="engine_capabilities",
        description="What this engine can do right now, and which parts of the toolchain are installed.",
        input_schema={"type": "object", "additionalProperties": False, "properties": {}},
        handler=capabilities,
    ))

    # ----------------------------------------------------------------- tokens

    def tokens_inspect(arguments: dict[str, Any]) -> dict[str, Any]:
        from ..tokens import TokenError, derive_visual_thresholds, load_token_set

        relative = arguments.get("tokenSet", "tokens/brickfarm.json")
        try:
            tokens = load_token_set(root, relative)
        except TokenError as exc:
            raise ToolError(str(exc)) from exc
        thresholds = derive_visual_thresholds(tokens)
        return {
            "tokenSetId": tokens.id,
            "revision": tokens.revision,
            "sha256": tokens.sha256,
            "provenance": tokens.provenance,
            "roles": {role_id: role.to_dict() for role_id, role in sorted(tokens.roles.items())},
            "moods": list(tokens.mood_ids()),
            "cameras": list(tokens.camera_ids()),
            "derivedThresholds": thresholds.to_dict(),
        }

    server.register(Tool(
        name="tokens_inspect",
        description=(
            "Load a design token set, validate it, and return the visual thresholds it "
            "projects. Every art-direction number the SDK may use comes from here."
        ),
        input_schema={
            "type": "object",
            "additionalProperties": False,
            "properties": {"tokenSet": _relative_path_schema("path to a token set JSON file")},
        },
        handler=tokens_inspect,
    ))

    def tokens_conformance(arguments: dict[str, Any]) -> dict[str, Any]:
        from ..token_conformance import check
        from ..tokens import TokenError, load_token_set

        try:
            tokens = load_token_set(root, arguments.get("tokenSet", "tokens/brickfarm.json"))
        except TokenError as exc:
            raise ToolError(str(exc)) from exc
        spec_path = root / arguments["visualSpec"]
        if not spec_path.is_file():
            raise ToolError(f"visual spec not found: {spec_path}")
        spec = json.loads(spec_path.read_text(encoding="utf-8"))
        return check(spec, tokens).to_dict()

    server.register(Tool(
        name="tokens_conformance",
        description=(
            "Check whether a visual spec's thresholds were projected from a token set. "
            "A spec whose numbers were typed while looking at the candidate passes by "
            "construction, and this is what detects it."
        ),
        input_schema={
            "type": "object",
            "additionalProperties": False,
            "required": ["visualSpec"],
            "properties": {
                "tokenSet": _relative_path_schema("path to a token set JSON file"),
                "visualSpec": _relative_path_schema("path to a visual quality spec"),
            },
        },
        handler=tokens_conformance,
    ))

    # -------------------------------------------------------------- luau/SDK

    def luau_compile(_: dict[str, Any]) -> dict[str, Any]:
        from ..luau_check import ToolchainUnavailable, check_all, discover

        try:
            failures = check_all(root, allow_download=False)
        except ToolchainUnavailable as exc:
            raise ToolError(str(exc)) from exc
        return {
            "sources": len(discover(root)),
            "failures": [{"path": str(item.path), "message": item.message} for item in failures],
            "clean": not failures,
        }

    server.register(Tool(
        name="luau_compile",
        description=(
            "Compile every Luau source in the repository. Rojo packages files without "
            "parsing them, so a place can build cleanly from Luau that never runs."
        ),
        input_schema={"type": "object", "additionalProperties": False, "properties": {}},
        handler=luau_compile,
    ))

    def sdk_run(arguments: dict[str, Any]) -> dict[str, Any]:
        from ..luau_harness import HarnessError, run

        libraries = arguments.get("libraries") or ["roblox/lib/WorldKit"]
        try:
            result = run(
                root,
                libraries=libraries,
                body=arguments["body"],
                data=arguments.get("data") or {},
                timeout=float(arguments.get("timeoutSeconds", 60)),
            )
        except HarnessError as exc:
            raise ToolError(str(exc)) from exc
        return {
            "exitCode": result.exit_code,
            "ok": result.ok,
            "stdout": result.stdout,
            "stderr": result.stderr,
            "json": result.json_lines(),
        }

    server.register(Tool(
        name="sdk_run",
        description=(
            "Execute Luau against the SDK headlessly, with no Studio. A module that "
            "reaches for an engine feature the harness does not shim fails loudly, which "
            "means it is not portable."
        ),
        input_schema={
            "type": "object",
            "additionalProperties": False,
            "required": ["body"],
            "properties": {
                "body": {"type": "string", "minLength": 1, "description": "Luau to execute"},
                "libraries": {
                    "type": "array",
                    "items": {"type": "string", "minLength": 1},
                    "description": "SDK library directories to load",
                },
                "data": {"type": "object", "description": "values exposed as Lua globals"},
                "timeoutSeconds": {"type": "number", "exclusiveMinimum": 0, "maximum": 300},
            },
        },
        handler=sdk_run,
    ))

    # ------------------------------------------------------------- pacing

    def pacing_simulate(arguments: dict[str, Any]) -> dict[str, Any]:
        """Time-to-tier for a cost ladder, with no game running.

        Runs the shipped `Progression` module rather than a Python
        reimplementation of it, so the numbers an agent reasons about come from
        the same code the game executes.
        """

        from ..luau_harness import HarnessError, run

        costs = arguments["tierCosts"]
        body = """
        local Progression = Require("Progression")
        local tiers = {}
        for index, cost in ipairs(COSTS) do
            table.insert(tiers, {
                id = "t" .. index, index = index, displayName = "T" .. index,
                cost = cost, currency = "cash", incomeMultiplier = MULTIPLIER,
            })
        end
        local ladder = Progression.define(tiers)
        local report = Progression.pacing(ladder, INCOME)
        local steps = {}
        for _, step in ipairs(report.steps) do
            table.insert(steps, string.format(
                '{"tier":"%s","cost":%s,"seconds":%.2f,"cumulative":%.2f}',
                step.tierId, tostring(step.cost), step.secondsFromPrevious, step.secondsFromStart))
        end
        local problems = {}
        for _, problem in ipairs(Progression.pacingProblems(report, POLICY)) do
            table.insert(problems, string.format("%q", problem))
        end
        print(string.format('{"totalSeconds":%.2f,"worstRatio":%.4f,"worstAtTier":"%s","steps":[%s],"problems":[%s]}',
            report.totalSeconds, report.worstRatio, tostring(report.worstAtTier),
            table.concat(steps, ","), table.concat(problems, ",")))
        """
        try:
            result = run(
                root,
                libraries=["roblox/lib/GameKit"],
                body=body,
                data={
                    "COSTS": costs,
                    "INCOME": float(arguments["baseIncomePerSecond"]),
                    "MULTIPLIER": float(arguments.get("incomeMultiplier", 1.0)),
                    "POLICY": arguments.get("policy") or {},
                },
            )
        except HarnessError as exc:
            raise ToolError(str(exc)) from exc
        if not result.ok:
            raise ToolError(result.stderr.strip() or "pacing simulation failed")
        decoded = result.json_lines()
        if not decoded:
            raise ToolError("pacing simulation produced no report")
        return decoded[-1]

    server.register(Tool(
        name="pacing_simulate",
        description=(
            "Compute time-to-tier for a progression ladder without running the game. "
            "Answers whether a tier is priced wrong before anyone plays."
        ),
        input_schema={
            "type": "object",
            "additionalProperties": False,
            "required": ["tierCosts", "baseIncomePerSecond"],
            "properties": {
                "tierCosts": {
                    "type": "array",
                    "minItems": 1,
                    "items": {"type": "number", "minimum": 0},
                },
                "baseIncomePerSecond": {"type": "number", "exclusiveMinimum": 0},
                "incomeMultiplier": {"type": "number", "exclusiveMinimum": 0},
                "policy": {"type": "object"},
            },
        },
        handler=pacing_simulate,
    ))

    # -------------------------------------------------------------- release

    def plan_compile(_: dict[str, Any]) -> dict[str, Any]:
        from ..measurement_plan import MeasurementPlanError, compile_measurement_plan
        from ..project import Project

        try:
            plan = compile_measurement_plan(Project.load(root))
        except (MeasurementPlanError, Exception) as exc:  # noqa: BLE001
            raise ToolError(f"{type(exc).__name__}: {exc}") from exc
        return {
            "requirements": len(plan.requirements),
            "requiredCategories": list(plan.required_categories),
            "minimumVisualScore": plan.minimum_visual_score,
            "tokenConformance": plan.metadata.get("tokenConformance"),
            "probeRegistry": plan.metadata.get("probeRegistry"),
        }

    server.register(Tool(
        name="plan_compile",
        description=(
            "Compile the contract into the fail-closed measurement plan and report what "
            "must be proven, including which requirements have no producer."
        ),
        input_schema={"type": "object", "additionalProperties": False, "properties": {}},
        handler=plan_compile,
    ))

    # ----------------------------------------------------------- cloud backend

    def cloud_capabilities(arguments: dict[str, Any]) -> dict[str, Any]:
        import os

        from ..cloud import CloudConfig, LuauExecutionClient

        universe = arguments.get("universeId") or os.environ.get("ROBLOX_UNIVERSE_ID", "")
        place = arguments.get("placeId") or os.environ.get("ROBLOX_PLACE_ID", "")
        if not universe or not place:
            raise ToolError(
                "universeId and placeId are required, directly or via "
                "ROBLOX_UNIVERSE_ID / ROBLOX_PLACE_ID"
            )
        # The key is read from the environment and never accepted as an argument,
        # so a credential cannot be written into a transcript by an agent.
        client = LuauExecutionClient(CloudConfig(
            universe_id=universe,
            place_id=place,
            api_key=os.environ.get("ROBLOX_OPEN_CLOUD_KEY"),
        ))
        return client.capabilities()

    server.register(Tool(
        name="cloud_capabilities",
        description=(
            "Report whether the Open Cloud Luau execution backend is usable, and name "
            "what blocks it if not. The API key is read from the environment only."
        ),
        input_schema={
            "type": "object",
            "additionalProperties": False,
            "properties": {
                "universeId": {"type": "string"},
                "placeId": {"type": "string"},
            },
        },
        handler=cloud_capabilities,
    ))

    return server


def build_server(root: Path | str, *, include_bridge: bool = True) -> EngineMcpServer:
    """The full engine surface.

    The bridge family is included by default because MCP is the interface to the
    engine, not to the half of it that runs without Studio. It can be excluded
    for a server that must never reach a live DataModel.
    """

    server = register_engine_tools(EngineMcpServer(root=Path(root).resolve()))

    from .campaign_tools import register_campaign_tools
    from .cloud_tools import register_cloud_tools
    from .factory_tools import register_factory_tools
    from .geometry_tools import register_geometry_tools
    from .lifecycle_tools import register_lifecycle_tools
    from .media_tools import register_media_tools
    from .content_tools import register_content_tools
    from .design_tools import register_design_tools
    from .director_tools import register_director_tools
    from .economy_tools import register_economy_tools
    from .ir_tools import register_ir_tools
    from .knowledge_tools import register_knowledge_tools
    from .producer_tools import register_producer_tools
    from .quality_tools import register_quality_tools
    from .recipe_tools import register_recipe_tools
    from .ui_tools import register_ui_tools
    from .system_tools import register_system_tools
    from .gameplay_tools import register_gameplay_tools
    from .sourcing_tools import register_sourcing_tools
    from .staging_tools import register_staging_tools
    from .authoring_tools import register_authoring_tools
    from .place_tools import register_place_tools
    from .guide_tools import register_guide_tools
    from .world_craft_tools import register_world_craft_tools
    from .interact_tools import register_interact_tools
    from .engine_tools import register_programming_tools
    from .instance_tools import register_instance_tools
    from .reuse_tools import register_reuse_tools
    from .scene_tools import register_scene_tools
    from .world_tools import register_federated_input, register_world_tools

    register_geometry_tools(server)
    register_factory_tools(server)
    register_cloud_tools(server)
    register_lifecycle_tools(server)
    register_media_tools(server)
    register_quality_tools(server)
    register_campaign_tools(server)
    register_world_tools(server)
    register_scene_tools(server)
    register_instance_tools(server)
    register_reuse_tools(server)
    register_ir_tools(server)
    register_economy_tools(server)
    register_system_tools(server)
    register_content_tools(server)
    register_director_tools(server)
    register_recipe_tools(server)
    register_ui_tools(server)
    register_design_tools(server)
    register_producer_tools(server)
    register_knowledge_tools(server)
    register_sourcing_tools(server)
    register_gameplay_tools(server)
    register_staging_tools(server)
    register_authoring_tools(server)
    register_place_tools(server)
    register_world_craft_tools(server)
    register_interact_tools(server)
    register_programming_tools(server)
    register_guide_tools(server)
    register_federated_input(server)

    if include_bridge:
        from .bridge_tools import register_bridge_tools

        register_bridge_tools(server)
    return server


def main(argv: list[str] | None = None) -> int:  # pragma: no cover - CLI
    import argparse

    parser = argparse.ArgumentParser(description="Run the RQE engine as an MCP server.")
    parser.add_argument("--root", default=".", help="repository root")
    arguments = parser.parse_args(argv)
    return build_server(arguments.root).serve()


if __name__ == "__main__":  # pragma: no cover
    raise SystemExit(main())
