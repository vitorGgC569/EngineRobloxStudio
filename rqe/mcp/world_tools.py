"""Planning and building worlds, and the tools federated from Studio's own MCP.

Two groups that live together because `build_server` wires them together:

    world_*    plan a layout headlessly, build it, dress it, optimise it
    federated  what Roblox's own MCP server can do and this bridge cannot

**Planning happens before anything is built.** `world_plan` validates a
described layout with no Studio and nothing placed -- unreachable regions,
overlapping footprints, sightlines that do not exist. `world_blockout` plans
first and refuses to build a layout that fails, because a world built from a
broken plan is a world somebody has to look at to discover the break.

**Federated results are wrapped, never trusted.** Anything from Roblox's server
arrives as untyped text, is re-typed, stamped with its source, and marked
inconclusive when it cannot be parsed. It must never be indistinguishable from a
measurement this engine made itself.
"""

from __future__ import annotations

import json
from pathlib import Path
from typing import Any

from .server import Tool, ToolError


def register_world_tools(server: Any) -> Any:
    """Attach layout planning, building, dressing and optimisation."""

    from ..world import (
        WorldSpecError,
        align,
        composition,
        load_spec,
        merge,
        optimize,
        place,
        plan,
        replace,
        scatter,
    )
    from ..world.authoring import plan_program

    def _spec(arguments: dict[str, Any]):
        document = arguments.get("spec")
        if not isinstance(document, dict):
            raise ToolError("a world spec is required: regions, circulation, landmarks")
        try:
            return load_spec(document)
        except WorldSpecError as error:
            raise ToolError(f"the spec is not usable: {error}") from error

    def world_plan(arguments: dict[str, Any]) -> dict[str, Any]:
        """Validate a layout without building any of it."""

        spec = _spec(arguments)
        result = plan(
            server.root, spec,
            tokens=str(arguments.get("tokens") or "tokens/brickfarm.json"),
            timeout=float(arguments.get("timeout") or 60.0),
        )
        return {
            "id": spec.id,
            "problems": list(result.problems),
            "unreachable": list(result.unreachable),
            "walkableArea": result.walkable_area,
            "footprintArea": result.footprint_area,
            "buildable": not result.problems and not result.unreachable,
            "note": (
                "nothing was built. A layout that fails here fails in the place "
                "too, and finding out from a screenshot costs a build"
            ),
        }

    def world_grammar(arguments: dict[str, Any]) -> dict[str, Any]:
        """The Luau program a spec compiles to, before it runs."""

        spec = _spec(arguments)
        program = plan_program(spec, str(arguments.get("tokens") or "tokens/brickfarm.json"))
        return {
            "id": spec.id,
            "lines": program.count("\n") + 1,
            "program": program,
            "note": "read it, change it, or run it yourself with sdk_run",
        }

    def world_blockout(arguments: dict[str, Any]) -> dict[str, Any]:
        """Plan, then build -- and refuse to build a plan that failed."""

        spec = _spec(arguments)
        result = plan(
            server.root, spec,
            tokens=str(arguments.get("tokens") or "tokens/brickfarm.json"),
            timeout=float(arguments.get("timeout") or 60.0),
        )
        if result.problems or result.unreachable:
            if arguments.get("force") is not True:
                return {
                    "built": False,
                    "problems": list(result.problems),
                    "unreachable": list(result.unreachable),
                    "note": (
                        "planning failed, so nothing was built. Pass force:true "
                        "to build it anyway -- this is advice, not a gate"
                    ),
                }

        from ..hub.client import StudioBridge

        program = plan_program(spec, str(arguments.get("tokens") or "tokens/brickfarm.json"))
        # plan_program is engine-generated after schema validation; callers do
        # not supply a raw Luau chunk through this surface.
        bridge = StudioBridge(allow_arbitrary=True)
        try:
            timeout = float(arguments.get("timeout") or 180.0)
            with bridge.lease_scope(
                agent_id="mcp-world-blockout",
                context="edit",
                ttl_seconds=max(30.0, min(timeout + 30.0, 300.0)),
            ):
                answer = bridge.call(
                    "bridge.exec",
                    {"source": program, "chunkName": "rqe.blockout"},
                    timeout=timeout,
                )
        except Exception as error:  # noqa: BLE001
            return {"built": False, "error": str(error),
                    "remedy": "blockout builds into the open place and needs edit context"}

        return {
            "built": True,
            "id": spec.id,
            "problems": list(result.problems),
            "walkableArea": result.walkable_area,
            "result": answer.get("returned") if isinstance(answer, dict) else answer,
        }

    def world_dress(arguments: dict[str, Any]) -> dict[str, Any]:
        """Scatter dressing across a footprint, deterministically."""

        plans = []
        for entry in arguments.get("scatters") or []:
            plans.append(scatter(
                str(entry.get("kit") or "brickfarm"),
                str(entry["module"]),
                centre=list(entry.get("centre") or [0, 0, 0]),
                size=list(entry.get("size") or [64, 0, 64]),
                density=float(entry.get("density") or 0.01),
                region=str(entry.get("region") or ""),
                jitter=float(entry.get("jitter") or 0.35),
                rotate=entry.get("rotate") is not False,
            ))
        if not plans:
            return {"dressed": False, "error": "give at least one scatter"}

        combined = merge(*plans) if len(plans) > 1 else plans[0]
        if arguments.get("snap") is not None:
            combined = align(combined, grid=float(arguments["snap"]))

        return {
            "dressed": True,
            "kit": combined.kit_id,
            "placements": len(combined.placements),
            "seed": combined.seed,
            "operations": list(combined.operations),
            "note": "same seed, same dressing -- so it can be judged and repeated",
        }

    def world_optimize(arguments: dict[str, Any]) -> dict[str, Any]:
        """What could be instanced, reported rather than applied."""

        placements = arguments.get("placements")
        if not isinstance(placements, list):
            return {"error": "give the placements to look at"}

        built = composition.Plan(
            kit_id=str(arguments.get("kit") or "brickfarm"),
            placements=[
                composition.Placement(
                    module_id=str(entry["module"]),
                    at=tuple(entry.get("at") or (0, 0, 0)),
                    rotation_y=float(entry.get("rotationY") or 0.0),
                    scale=float(entry.get("scale") or 1.0),
                    region=str(entry.get("region") or ""),
                )
                for entry in placements
            ],
            seed=int(arguments.get("seed") or 0),
            operations=(),
        )
        report = optimize(built, instance_threshold=int(arguments.get("threshold") or 4))
        report["note"] = (
            "reported, not applied: removing a placement changes what the world "
            "looks like, and that is a decision rather than a cleanup"
        )
        return report

    def world_from_zones(arguments: dict[str, Any]) -> dict[str, Any]:
        """Turn a list of named zones into a spec that can be planned."""

        zones = arguments.get("zones")
        if not isinstance(zones, list) or not zones:
            return {"error": "give at least one zone"}

        regions = []
        for zone in zones:
            regions.append({
                "id": str(zone["id"]),
                "kind": str(zone.get("kind") or "plot"),
                "centre": list(zone.get("centre") or [0, 0, 0]),
                "size": list(zone.get("size") or [48, 0, 48]),
            })

        document = {
            "id": str(arguments.get("id") or "world"),
            "regions": regions,
            "circulation": arguments.get("circulation") or [],
            "landmarks": arguments.get("landmarks") or [],
            "sightlines": arguments.get("sightlines") or [],
        }
        try:
            spec = load_spec(document)
        except WorldSpecError as error:
            return {"error": str(error), "spec": document}
        return {
            "spec": document,
            "regions": len(spec.regions),
            "note": "pass this to world_plan, or edit it first",
        }

    server.register(Tool(
        name="world_plan",
        description=(
            "Validate a described layout headlessly -- no Studio, nothing built. "
            "Reports unreachable regions, overlapping footprints and broken "
            "sightlines before a build is spent on them."
        ),
        input_schema={
            "type": "object",
            "required": ["spec"],
            "properties": {
                "spec": {"type": "object"},
                "tokens": {"type": "string"},
                "timeout": {"type": "number"},
            },
        },
        handler=world_plan,
    ))

    server.register(Tool(
        name="world_grammar",
        description=(
            "The Luau program a spec compiles to. Read it, change it, or run it "
            "yourself -- the layout is not locked inside the tool."
        ),
        input_schema={
            "type": "object",
            "required": ["spec"],
            "properties": {"spec": {"type": "object"}, "tokens": {"type": "string"}},
        },
        handler=world_grammar,
    ))

    server.register(Tool(
        name="world_blockout",
        description=(
            "Plan a layout and build it into the open place. Planning failures "
            "stop the build by default and `force` overrides them -- advice, not "
            "a gate."
        ),
        input_schema={
            "type": "object",
            "required": ["spec"],
            "properties": {
                "spec": {"type": "object"},
                "tokens": {"type": "string"},
                "timeout": {"type": "number"},
                "force": {"type": "boolean"},
            },
        },
        handler=world_blockout,
    ))

    server.register(Tool(
        name="world_dress",
        description=(
            "Scatter dressing across footprints, deterministically. Same seed, "
            "same dressing, so a change can be judged against the run before it."
        ),
        input_schema={
            "type": "object",
            "required": ["scatters"],
            "properties": {
                "scatters": {"type": "array", "items": {"type": "object"}},
                "snap": {"type": "number"},
            },
        },
        handler=world_dress,
    ))

    server.register(Tool(
        name="world_optimize",
        description=(
            "What in a set of placements could be instanced. Reported, not "
            "applied: removing a placement changes what the world looks like."
        ),
        input_schema={
            "type": "object",
            "required": ["placements"],
            "properties": {
                "placements": {"type": "array", "items": {"type": "object"}},
                "kit": {"type": "string"},
                "seed": {"type": "integer"},
                "threshold": {"type": "integer", "minimum": 2},
            },
        },
        handler=world_optimize,
    ))

    server.register(Tool(
        name="world_from_zones",
        description=(
            "Turn named zones into a spec that can be planned. The quickest way "
            "from 'a hub, three plots and a road' to something checkable."
        ),
        input_schema={
            "type": "object",
            "required": ["zones"],
            "properties": {
                "id": {"type": "string"},
                "zones": {"type": "array", "items": {"type": "object"}},
                "circulation": {"type": "array"},
                "landmarks": {"type": "array"},
                "sightlines": {"type": "array"},
            },
        },
        handler=world_from_zones,
    ))

    return server


def register_federated_input(server: Any) -> Any:
    """Attach what Roblox's own MCP server can do and this bridge cannot.

    `VirtualInputManager` is refused both in a LocalScript and in a plugin
    (`lacking capability RobloxScript`), which left every GUI-driven requirement
    permanently unmeasurable. Roblox's own server does it, because it runs at a
    privilege level a third-party plugin does not get.
    """

    from .client import ADOPTED_TOOLS, FEDERATED_SOURCE, StudioMcpClient, studio_mcp_command

    def federated_catalogue(_arguments: dict[str, Any]) -> dict[str, Any]:
        return {
            "source": FEDERATED_SOURCE,
            "adopted": dict(ADOPTED_TOOLS),
            "note": (
                "these run in Roblox's own MCP server, not this bridge. Results "
                "are re-typed and stamped with their source -- a federated "
                "measurement must never look like one we made ourselves"
            ),
        }

    def federated_call(arguments: dict[str, Any]) -> dict[str, Any]:
        name = str(arguments["tool"])
        if name not in ADOPTED_TOOLS:
            return {
                "ok": False,
                "error": f"{name} is not an adopted tool",
                "adopted": sorted(ADOPTED_TOOLS),
                "why": (
                    "the adopted set is declared rather than discovered, so a "
                    "tool appearing upstream does not silently become part of "
                    "the measurement surface"
                ),
            }
        client = None
        try:
            client = StudioMcpClient.spawn(studio_mcp_command())
            client.initialize()
            descriptors = {tool.name: tool for tool in client.tools()}
            if name not in descriptors:
                return {"ok": False, "error": f"upstream tool {name} is unavailable", "source": FEDERATED_SOURCE}
            params = arguments.get("arguments") or {}
            missing = [key for key in descriptors[name].input_schema.get("required", []) if key not in params]
            if name != "list_roblox_studios" and not params.get("studio_id"):
                missing.append("studio_id")
            if missing:
                return {"ok": False, "error": "missing upstream arguments: " + ", ".join(sorted(set(missing))),
                        "source": FEDERATED_SOURCE, "inputSchema": dict(descriptors[name].input_schema)}
            result = client.call_tool(name, params)
        except Exception as error:  # noqa: BLE001
            return {"ok": False, "error": str(error), "source": FEDERATED_SOURCE}
        finally:
            try:
                if client is not None:
                    client.close()
            except Exception:  # noqa: BLE001
                pass

        payload = result.to_evidence_detail()
        payload.update({"text": result.text, "structured": result.structured})
        return payload

    server.register(Tool(
        name="federated_catalogue",
        description=(
            "What Roblox's own MCP server offers that this bridge cannot: "
            "synthesised keyboard and mouse input, mesh and material "
            "generation, asset search."
        ),
        input_schema={"type": "object", "properties": {}},
        handler=federated_catalogue,
    ))

    server.register(Tool(
        name="federated_call",
        description=(
            "Run one adopted tool on Roblox's MCP server. Results are wrapped "
            "and stamped with their source, never presented as our own."
        ),
        input_schema={
            "type": "object",
            "required": ["tool"],
            "properties": {
                "tool": {"type": "string"},
                "arguments": {"type": "object"},
            },
        },
        handler=federated_call,
    ))

    return server
