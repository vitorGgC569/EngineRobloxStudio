"""Composing a scene: place, scatter, align, vary, replace, optimise.

Plans are data. Nothing here touches the open place -- a plan is built,
combined and inspected, and building it is a separate step. That separation is
why a scatter can be seeded, diffed, judged and repeated rather than only looked
at once.

`ui_click` lives here too, because pressing something in a running interface is
the other half of composing one: a screen nobody can press is a screen nobody
has tested.
"""

from __future__ import annotations

from typing import Any

from .server import Tool, ToolError


def register_scene_tools(server: Any) -> Any:
    """Attach scene composition and interface interaction."""

    from ..world import (
        CompositionError,
        align,
        optimize,
        place,
        replace,
        scatter,
        variant,
        variant_spread,
    )
    from ..world.composition import Placement, Plan

    def _plan_from(arguments: dict[str, Any]) -> Plan:
        """Rebuild a plan from what a previous call returned."""

        payload = arguments.get("plan")
        if not isinstance(payload, dict):
            raise ToolError("give the plan a previous call returned")
        return Plan(
            kit_id=str(payload.get("kitId") or payload.get("kit_id") or "brickfarm"),
            placements=tuple(
                Placement(
                    module_id=str(entry.get("moduleId") or entry.get("module_id")),
                    position=tuple(entry.get("position") or (0, 0, 0)),
                    rotation_y=float(entry.get("rotationY") or entry.get("rotation_y") or 0.0),
                    scale=float(entry.get("scale") or 1.0),
                    variant=str(entry.get("variant") or ""),
                    cell=tuple(entry.get("cell") or (0, 0, 0)),
                    region=str(entry.get("region") or ""),
                )
                for entry in payload.get("placements") or []
            ),
            seed=int(payload.get("seed") or 0),
            operations=tuple(payload.get("operations") or ()),
        )

    def _out(plan: Plan, **extra: Any) -> dict[str, Any]:
        report = dict(plan.to_dict())
        report.update(extra)
        report["count"] = len(plan.placements)
        return report

    def scene_place(arguments: dict[str, Any]) -> dict[str, Any]:
        try:
            plan = place(
                str(arguments.get("kit") or "brickfarm"),
                str(arguments["module"]),
                list(arguments.get("at") or [0, 0, 0]),
                rotation_y=float(arguments.get("rotationY") or 0.0),
                scale=float(arguments.get("scale") or 1.0),
                region=str(arguments.get("region") or ""),
            )
        except CompositionError as error:
            raise ToolError(str(error)) from error
        return _out(plan)

    def scene_scatter(arguments: dict[str, Any]) -> dict[str, Any]:
        try:
            plan = scatter(
                str(arguments.get("kit") or "brickfarm"),
                str(arguments["module"]),
                centre=list(arguments.get("centre") or [0, 0, 0]),
                size=list(arguments.get("size") or [64, 0, 64]),
                density=float(arguments.get("density") or 0.01),
                region=str(arguments.get("region") or ""),
                jitter=float(arguments.get("jitter") or 0.35),
                rotate=arguments.get("rotate") is not False,
                exclude=[list(point) for point in arguments.get("exclude") or []],
                exclusion_radius=float(arguments.get("exclusionRadius") or 0.0),
            )
        except CompositionError as error:
            raise ToolError(str(error)) from error
        return _out(plan, note="same seed, same scatter")

    def scene_align(arguments: dict[str, Any]) -> dict[str, Any]:
        return _out(align(
            _plan_from(arguments),
            axis=str(arguments.get("axis") or "y"),
            grid=float(arguments.get("grid") or 1.0),
        ))

    def scene_variant(arguments: dict[str, Any]) -> dict[str, Any]:
        variants = [str(name) for name in arguments.get("variants") or []]
        if not variants:
            raise ToolError("give at least one variant name")
        weights = arguments.get("weights")
        plan = variant(
            _plan_from(arguments),
            variants=variants,
            weights=[float(value) for value in weights] if weights else None,
        )
        return _out(plan, spread=variant_spread(plan))

    def scene_replace(arguments: dict[str, Any]) -> dict[str, Any]:
        return _out(replace(
            _plan_from(arguments),
            module_id=str(arguments["module"]),
            with_module=str(arguments["with"]),
            region=arguments.get("region"),
        ))

    def scene_optimize(arguments: dict[str, Any]) -> dict[str, Any]:
        report = dict(optimize(
            _plan_from(arguments),
            instance_threshold=int(arguments.get("threshold") or 4),
        ))
        report["note"] = (
            "reported, not applied: what to cut is a decision about how the "
            "world looks rather than a cleanup"
        )
        return report

    def ui_click(arguments: dict[str, Any]) -> dict[str, Any]:
        """Press something in the running interface, through the client relay."""

        from ..hub.client import StudioBridge

        bridge = StudioBridge()
        try:
            bridge.pin_to_running()
            return bridge.call("client.gui_click", {
                "path": str(arguments["path"]),
            }, timeout=float(arguments.get("timeout") or 30.0))
        except Exception as error:  # noqa: BLE001
            return {
                "clicked": False,
                "error": str(error),
                "remedy": "a GUI only exists while the game runs; start Play Solo",
            }

    server.register(Tool(
        name="scene_place",
        description="Put one kit module at a point. Returns a plan, not a build.",
        input_schema={
            "type": "object",
            "required": ["module"],
            "properties": {
                "kit": {"type": "string"},
                "module": {"type": "string"},
                "at": {"type": "array", "items": {"type": "number"},
                       "minItems": 3, "maxItems": 3},
                "rotationY": {"type": "number"},
                "scale": {"type": "number", "exclusiveMinimum": 0},
                "region": {"type": "string"},
            },
        },
        handler=scene_place,
    ))

    server.register(Tool(
        name="scene_scatter",
        description=(
            "Scatter a module across a footprint at a density, deterministically. "
            "Exclusions keep it off the roads and the plots."
        ),
        input_schema={
            "type": "object",
            "required": ["module"],
            "properties": {
                "kit": {"type": "string"},
                "module": {"type": "string"},
                "centre": {"type": "array", "items": {"type": "number"},
                           "minItems": 3, "maxItems": 3},
                "size": {"type": "array", "items": {"type": "number"},
                         "minItems": 3, "maxItems": 3},
                "density": {"type": "number", "exclusiveMinimum": 0},
                "region": {"type": "string"},
                "jitter": {"type": "number"},
                "rotate": {"type": "boolean"},
                "exclude": {"type": "array"},
                "exclusionRadius": {"type": "number"},
            },
        },
        handler=scene_scatter,
    ))

    server.register(Tool(
        name="scene_align",
        description="Snap every placement in a plan onto a grid.",
        input_schema={
            "type": "object",
            "required": ["plan"],
            "properties": {
                "plan": {"type": "object"},
                "axis": {"type": "string"},
                "grid": {"type": "number", "exclusiveMinimum": 0},
            },
        },
        handler=scene_align,
    ))

    server.register(Tool(
        name="scene_variant",
        description=(
            "Spread variants across a plan, weighted. Forty identical trees read "
            "as a copy-paste; the same forty across three silhouettes read as a wood."
        ),
        input_schema={
            "type": "object",
            "required": ["plan", "variants"],
            "properties": {
                "plan": {"type": "object"},
                "variants": {"type": "array", "items": {"type": "string"}},
                "weights": {"type": "array", "items": {"type": "number"}},
            },
        },
        handler=scene_variant,
    ))

    server.register(Tool(
        name="scene_replace",
        description="Swap one module for another across a plan, optionally by region.",
        input_schema={
            "type": "object",
            "required": ["plan", "module", "with"],
            "properties": {
                "plan": {"type": "object"},
                "module": {"type": "string"},
                "with": {"type": "string"},
                "region": {"type": "string"},
            },
        },
        handler=scene_replace,
    ))

    server.register(Tool(
        name="scene_optimize",
        description=(
            "What in a plan could be instanced, and what it would save. "
            "Reported, never applied."
        ),
        input_schema={
            "type": "object",
            "required": ["plan"],
            "properties": {
                "plan": {"type": "object"},
                "threshold": {"type": "integer", "minimum": 2},
            },
        },
        handler=scene_optimize,
    ))

    server.register(Tool(
        name="ui_click",
        description=(
            "Press something in the running game's interface. A screen nobody "
            "can press is a screen nobody has tested."
        ),
        input_schema={
            "type": "object",
            "required": ["path"],
            "properties": {
                "path": {"type": "string"},
                "timeout": {"type": "number"},
            },
        },
        handler=ui_click,
    ))

    return server
