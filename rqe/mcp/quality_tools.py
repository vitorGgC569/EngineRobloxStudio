"""The quality family, reachable through the protocol.

The split stays where it is: `quality.snapshot` measures inside Studio and takes
**no thresholds**, and every rule below is policy in Python. Sending a limit into
the DataModel is how a validator starts grading itself, so the tools here fetch a
snapshot and apply the rules on this side rather than pushing the rules across.

What changes is reachability. Before, the eight rule families existed as Python
an agent could not invoke, which meant the layer that decides whether a world is
any good could only be driven by shelling out. A capability that cannot be
called is a capability the platform does not really offer.

Every tool returns the evidence records the release gate would consume, so what
an agent sees while iterating is the same thing the gate will see later. A tool
that reported a friendlier summary than the gate uses would teach an agent to
trust the wrong number.
"""

from __future__ import annotations

import os
from pathlib import Path
from typing import Any

from .server import EngineMcpServer, Tool, ToolError


#: Which probe prefixes belong to which family, so a caller can ask one question
#: rather than filtering a hundred evidence records by hand.
FAMILIES = {
    "geometry": ("visual.object.", "visual.classification."),
    "density": ("visual.region.", "-density"),
    "scale": ("visual.object.", "-scale"),
    "visibility": ("visual.landmark.",),
    "ui": ("visual.viewpoint.",),
    "visual": ("visual.",),
}


def _bridge(arguments: dict[str, Any]):
    from ..hub.client import StudioBridge

    return StudioBridge(
        arguments.get("hub") or os.environ.get("RQE_HUB_URL", "http://127.0.0.1:8790"),
        token=os.environ.get("RQE_BRIDGE_TOKEN"),
    )


def _snapshot(root: Path, arguments: dict[str, Any]) -> tuple[dict[str, Any], Any, Any]:
    """Fetch a live snapshot and the spec that will grade it."""

    from ..project import Project
    from ..visual_spec import VisualSpecError, load_visual_spec

    project = Project.load(root)
    try:
        spec = load_visual_spec(project)
    except VisualSpecError as exc:
        raise ToolError(f"the visual quality spec is invalid: {exc}") from exc

    bridge = _bridge(arguments)
    if arguments.get("pinToRunning", True):
        try:
            bridge.pin_to_running()
        except Exception:  # noqa: BLE001 - edit mode is a legitimate context
            pass

    # The selector comes from the spec, never from the caller: a snapshot taken
    # against different selectors than the rules expect measures a different
    # world and grades it anyway.
    try:
        snapshot = bridge.call("quality.snapshot", _selector(spec), timeout=120)
    except Exception as exc:  # noqa: BLE001
        raise ToolError(
            f"could not take a quality snapshot: {type(exc).__name__}: {exc}. "
            "This needs a Studio session with the plugin attached."
        ) from exc
    return snapshot, project, spec


def _selector(spec: Any) -> dict[str, Any]:
    data = spec.data
    return {
        "roots": {
            "tag": "RQEVisualRoot",
            "typeAttribute": "VisualType",
            "variantAttribute": "VisualVariant",
        },
        "regions": {
            "tag": "RQEVisualRegion",
            "profileAttribute": "VisualRegionProfile",
            "idAttribute": "RegionId",
        },
        "landmarks": [
            {
                "id": landmark_id,
                "maximumDistance": definition.get("maximumDistance"),
                "samples": definition.get("samples"),
            }
            for landmark_id, definition in sorted(data.get("landmarks", {}).items())
        ],
    }


def _select_family(evidence: list[Any], family: str) -> list[dict[str, Any]]:
    records = [item.to_dict() if hasattr(item, "to_dict") else dict(item) for item in evidence]
    if family == "all":
        return records

    prefixes = FAMILIES.get(family)
    if prefixes is None:
        raise ToolError(f"unknown quality family {family!r}; available: {', '.join(sorted(FAMILIES))}")

    selected = []
    for record in records:
        probe = str(record.get("probe", ""))
        # A suffix entry (leading '-') narrows within a prefix, which is how
        # 'density' and 'scale' pick their slice of the same region rules.
        includes = [item for item in prefixes if not item.startswith("-")]
        narrows = [item[1:] for item in prefixes if item.startswith("-")]
        if includes and not any(probe.startswith(item) for item in includes):
            continue
        if narrows and not any(probe.endswith(item) for item in narrows):
            continue
        selected.append(record)
    return selected


def register_quality_tools(server: EngineMcpServer) -> EngineMcpServer:
    root = server.root

    def quality_evaluate(arguments: dict[str, Any]) -> dict[str, Any]:
        from ..quality import evaluate_quality_snapshot

        snapshot, project, spec = _snapshot(root, arguments)
        evidence = evaluate_quality_snapshot(
            project, spec, snapshot,
            run_id=arguments.get("runId", "adhoc"),
            build_hash=arguments.get("buildHash", "adhoc"),
        )
        family = arguments.get("family", "all")
        records = _select_family(evidence, family)

        failing = [item for item in records if str(item.get("status", "")).upper() != "PASS"]
        inconclusive = [item for item in records if item.get("conclusive") is False]

        return {
            "family": family,
            "snapshotTruncated": bool(snapshot.get("truncated")),
            "rules": len(records),
            "failing": len(failing),
            # Separated from failing on purpose: a rule that could not be
            # measured has not passed and has not failed, and collapsing the two
            # is how a truncated snapshot reads as a clean world.
            "inconclusive": len(inconclusive),
            "clean": not failing and not inconclusive,
            "findings": [
                {
                    "probe": item.get("probe"),
                    "status": item.get("status"),
                    "severity": item.get("severity"),
                    "detail": item.get("details"),
                }
                for item in failing[:25]
            ],
            "evidence": records,
        }

    server.register(Tool(
        name="quality_evaluate",
        description=(
            "Take a live quality snapshot and apply the deterministic visual rules to it: "
            "geometry, density, scale, visibility, ui, or all. Measurement happens in "
            "Studio and carries no thresholds; the policy is applied here."
        ),
        input_schema={
            "type": "object",
            "additionalProperties": False,
            "properties": {
                "family": {"enum": ["all", "geometry", "density", "scale", "visibility", "ui", "visual"]},
                "hub": {"type": "string"},
                "pinToRunning": {"type": "boolean"},
                "runId": {"type": "string"},
                "buildHash": {"type": "string"},
            },
        },
        handler=quality_evaluate,
    ))

    def quality_navigation(arguments: dict[str, Any]) -> dict[str, Any]:
        """Whether the world can be walked, answered from the world itself.

        Kept out of `quality_evaluate` because it is not a rule over a snapshot:
        it asks the navmesh and the pathfinder directly, and a navmesh that is
        not responding is a different finding from a destination that cannot be
        reached.
        """

        bridge = _bridge(arguments)
        try:
            navigation = bridge.call("world.navigation", {}, timeout=60)
            spawns = bridge.call("world.spawn_points", {}, timeout=30)
        except Exception as exc:  # noqa: BLE001
            raise ToolError(f"{type(exc).__name__}: {exc}") from exc

        problems: list[str] = []
        if not navigation.get("navmeshResponsive"):
            problems.append(
                "the navmesh did not return a path across open ground; nothing about "
                "reachability can be concluded until that is fixed"
            )
        if spawns.get("count", 0) == 0:
            problems.append("no SpawnLocation exists, so players have nowhere to arrive")
        if spawns.get("ambiguousArrival"):
            problems.append(
                "several neutral spawns are enabled, so arrival is random and any "
                "scenario that depends on a starting position will be flaky"
            )

        return {
            "navmeshResponsive": bool(navigation.get("navmeshResponsive")),
            "spawnCount": spawns.get("count", 0),
            "problems": problems,
            "clean": not problems,
            "navigation": navigation,
            "spawns": spawns,
        }

    server.register(Tool(
        name="quality_navigation",
        description=(
            "Ask the navmesh and the spawn inventory directly: is pathfinding working "
            "here at all, and can a player arrive somewhere predictable."
        ),
        input_schema={
            "type": "object",
            "additionalProperties": False,
            "properties": {"hub": {"type": "string"}},
        },
        handler=quality_navigation,
    ))

    def quality_performance(arguments: dict[str, Any]) -> dict[str, Any]:
        """Frame, memory, physics and network against a declared budget.

        A budget nobody measures is a comment. The numbers come from a sampled
        window rather than an instantaneous counter, because a single read
        reports whatever happened during one frame.
        """

        bridge = _bridge(arguments)
        try:
            bridge.pin_to_running()
        except Exception as exc:  # noqa: BLE001
            raise ToolError(
                f"performance can only be measured against a running place: {exc}"
            ) from exc

        seconds = float(arguments.get("seconds", 3))
        try:
            metrics = bridge.call("runtime.metrics", {"seconds": seconds}, timeout=seconds + 60)
            memory = bridge.call("runtime.memory", {}, timeout=60)
            physics = bridge.call("runtime.physics", {"seconds": seconds}, timeout=seconds + 60)
            network = bridge.call("runtime.network", {}, timeout=60)
        except Exception as exc:  # noqa: BLE001
            raise ToolError(f"{type(exc).__name__}: {exc}") from exc

        budget = arguments.get("budget") or {}
        problems: list[str] = []

        if not metrics.get("conclusive"):
            problems.append(f"frame timing was not measurable: {metrics.get('reason')}")
        else:
            fps = metrics.get("fps") or {}
            floor = budget.get("minimumFps")
            # The tail, not the mean. A mean of 60 with a p99 of 12 is a game
            # that stutters, and the mean alone hides it completely.
            tail = fps.get("p99")
            if floor is not None and tail is not None and tail < float(floor):
                problems.append(
                    f"p99 frame rate {tail:.1f} is below the budget of {floor}; "
                    "the worst frames are what a player feels"
                )

        ceiling = budget.get("maximumMemoryMb")
        total = memory.get("totalMb")
        if ceiling is not None and total is not None and total > float(ceiling):
            problems.append(f"memory {total:.0f}MB is above the budget of {ceiling}MB")

        moving = (physics.get("parts") or {}).get("unanchoredMoving")
        awake_ceiling = budget.get("maximumMovingParts")
        if awake_ceiling is not None and moving is not None and moving > int(awake_ceiling):
            problems.append(
                f"{moving} unanchored parts are moving, above {awake_ceiling}; "
                "physics cost scales with this, not with part count"
            )

        return {
            "sampleSeconds": seconds,
            "problems": problems,
            "clean": not problems,
            "metrics": metrics,
            "memory": memory,
            "physics": physics,
            "network": network,
        }

    server.register(Tool(
        name="quality_performance",
        description=(
            "Sample frame timing, memory, physics and network against a declared budget "
            "and report what exceeds it. Judges the p99, not the mean."
        ),
        input_schema={
            "type": "object",
            "additionalProperties": False,
            "properties": {
                "seconds": {"type": "number", "exclusiveMinimum": 0, "maximum": 10},
                "hub": {"type": "string"},
                "budget": {
                    "type": "object",
                    "additionalProperties": False,
                    "properties": {
                        "minimumFps": {"type": "number"},
                        "maximumMemoryMb": {"type": "number"},
                        "maximumMovingParts": {"type": "integer"},
                    },
                },
            },
        },
        handler=quality_performance,
    ))

    return server
