"""Measure a live place through the Studio Bridge and emit runtime evidence.

Everything this module produces is sourced from a command a real Studio plugin
executed. Nothing here reads ``game-state.json``: that fixture is an assertion
about the game, while this is a measurement of it. Evidence is stamped
``source="studio-bridge"`` and carries the Studio context it came from, so a
reader can always tell a measured fact from a declared one.
"""

from __future__ import annotations

import json
import platform
import subprocess
from dataclasses import dataclass, field
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

from .hub.client import StudioBridge
from .hub.protocol import PROTOCOL_VERSION, BridgeError
from .models import Evidence
from .project import Project

ENGINE_VERSION = "0.2.0"

#: Validation levels, in ascending order of strength. Named explicitly so a
#: report can never imply more proof than it collected.
NOT_VALIDATED = "NOT_VALIDATED"
STATICALLY_VALIDATED = "STATICALLY_VALIDATED"
RUNTIME_VALIDATED = "RUNTIME_VALIDATED"
VISUALLY_VALIDATED = "VISUALLY_VALIDATED"
E2E_VALIDATED = "E2E_VALIDATED"

DEFAULT_OBSERVE_CONFIG: dict[str, Any] = {
    # Regions that must not intersect. Tag-driven first (engine-generic), with a
    # name pattern fallback so a place that predates tagging still gets checked.
    "regionTag": "QARegion",
    "regionNamePattern": "^Plot",
    "regionRoot": "game.Workspace",
    "groundSupportSamples": 9,
    "groundSupportMaxGap": 1.5,
    "budgets": {
        "minFps": 30.0,
        "maxFrameMs": 33.34,
        "maxWorkspaceInstances": 25000,
        "maxMemoryMb": 4000.0,
        "maxUnanchoredParts": 200,
    },
}


def _now() -> str:
    return datetime.now(timezone.utc).isoformat()


def _finding(severity: str, category: str, location: str, finding: str, suggested_action: str, evidence: dict[str, Any] | None = None) -> dict[str, Any]:
    """An actionable problem, in the shape a repair agent can consume."""
    return {
        "severity": severity,
        "category": category,
        "location": location,
        "finding": finding,
        "suggestedAction": suggested_action,
        "evidence": evidence or {},
    }


@dataclass
class Observation:
    """One measurement pass over a live place."""

    run_id: str
    started_at: str
    context: str
    place: dict[str, Any]
    measurements: dict[str, Any] = field(default_factory=dict)
    evidence: list[Evidence] = field(default_factory=list)
    findings: list[dict[str, Any]] = field(default_factory=list)
    errors: list[dict[str, Any]] = field(default_factory=list)
    validation_level: str = NOT_VALIDATED
    reproducibility: dict[str, Any] = field(default_factory=dict)
    contexts_seen: set[str] = field(default_factory=set)

    #: Ordered weakest to strongest. A pass that touched a running game is
    #: described as a run pass even if it ended back in edit mode.
    CONTEXT_STRENGTH = ("unknown", "edit", "client", "server", "run")

    def strongest_context(self) -> str:
        best = self.context
        for candidate in self.contexts_seen:
            if self.CONTEXT_STRENGTH.index(candidate) > self.CONTEXT_STRENGTH.index(best if best in self.CONTEXT_STRENGTH else "unknown"):
                best = candidate
        return best

    @property
    def ok(self) -> bool:
        return (
            not self.errors
            and not any(item.status == "FAIL" for item in self.evidence)
            and not any(not item.conclusive or item.truncated for item in self.evidence)
        )

    def counts(self) -> dict[str, int]:
        counts = {"PASS": 0, "WARN": 0, "FAIL": 0}
        for item in self.evidence:
            counts[item.status] += 1
        return counts

    def to_dict(self) -> dict[str, Any]:
        return {
            "runId": self.run_id,
            "startedAt": self.started_at,
            "completedAt": _now(),
            "validationLevel": self.validation_level,
            "studioContext": self.context,
            "contextsObserved": sorted(self.contexts_seen),
            "place": self.place,
            "status": "PASS" if self.ok else "FAIL",
            "counts": self.counts(),
            "measurements": self.measurements,
            "findings": self.findings,
            "evidence": [item.to_dict() for item in self.evidence],
            "commandErrors": self.errors,
            "reproducibility": self.reproducibility,
        }

    def terminal_summary(self) -> str:
        counts = self.counts()
        lines = [
            f"RUN {self.run_id}  [{self.validation_level}]",
            f"place: {self.place.get('placeName', '?')}  context: {self.context}",
            f"evidence: {counts['PASS']} PASS  {counts['WARN']} WARN  {counts['FAIL']} FAIL",
        ]
        if self.findings:
            lines.append(f"findings: {len(self.findings)}")
            for item in self.findings[:10]:
                lines.append(f"  [{item['severity']}] {item['location']}: {item['finding']}")
            if len(self.findings) > 10:
                lines.append(f"  ... {len(self.findings) - 10} more")
        if self.errors:
            lines.append(f"commands that failed: {len(self.errors)}")
        return "\n".join(lines)


def _next_run_id(reports_dir: Path) -> str:
    artifacts = reports_dir.parent / "artifacts"
    existing = sorted(artifacts.glob("run-*")) if artifacts.exists() else []
    numbers = []
    for path in existing:
        suffix = path.name.split("-")[-1]
        if suffix.isdigit():
            numbers.append(int(suffix))
    return f"run-{(max(numbers) + 1 if numbers else 1):05d}"


def _git_commit(root: Path) -> str | None:
    try:
        result = subprocess.run(
            ["git", "rev-parse", "HEAD"],
            capture_output=True, text=True, timeout=5, check=False, cwd=str(root),
        )
    except (OSError, subprocess.SubprocessError):
        return None
    return result.stdout.strip() or None


class _Collector:
    """Runs bridge commands, recording failures instead of raising them.

    A single unsupported command must not abort the pass: a partial measurement
    with an explicit gap is more useful than no measurement at all.
    """

    def __init__(self, bridge: StudioBridge, observation: Observation) -> None:
        self.bridge = bridge
        self.observation = observation

    def call(self, method: str, params: dict[str, Any] | None = None, timeout: float = 20.0) -> Any:
        try:
            response = self.bridge.call_response(method, params, timeout=timeout)
        except BridgeError as exc:
            self.observation.errors.append({"method": method, "params": params or {}, "error": exc.to_dict()})
            return None
        if not response.ok:
            self.observation.errors.append({"method": method, "params": params or {}, "error": response.error})
            return None
        # The context can change between commands if a playtest starts mid-pass.
        # Record every context seen: the pass is described by the strongest one
        # it measured in, not by whatever Studio happened to be doing when the
        # last command (usually run.stop) returned.
        if response.context != "unknown":
            self.observation.contexts_seen.add(response.context)
            self.observation.context = self.observation.strongest_context()
        return response.result


#: A freshly opened place holds Terrain and Camera. Anything much above that
#: before a run means a previous run already generated a world here.
CLEAN_BASELINE_DESCENDANTS = 8


def _measurement_budgets(project: Project, config: dict[str, Any]) -> dict[str, Any]:
    """Resolve budgets with the release contract as the final authority.

    Observe configuration may add diagnostic budgets (memory and unanchored
    parts), but it must never weaken the FPS, frame-time or instance limits the
    product contract declares.
    """

    budgets = {
        **DEFAULT_OBSERVE_CONFIG["budgets"],
        **(config.get("budgets") or {}),
    }
    performance = project.contract.get("performance_budget") or {}
    client = performance.get("client") or {}
    instances = performance.get("instances") or {}
    if "target_fps" in client:
        budgets["minFps"] = float(client["target_fps"])
    if "max_frame_ms" in client:
        budgets["maxFrameMs"] = float(client["max_frame_ms"])
    if "max_workspace" in instances:
        budgets["maxWorkspaceInstances"] = int(instances["max_workspace"])
    return budgets


def measure_place(
    bridge: StudioBridge,
    project: Project,
    run_id: str | None = None,
    start_run: bool = False,
    stop_after: bool = True,
) -> Observation:
    """Measure the place currently open in Studio.

    With ``start_run`` the pass owns the whole cycle: bring the world to life,
    measure it, put Studio back in edit mode. That is the reproducible shape,
    because Studio's Run mode does not undo what game scripts build -- measuring
    a place that was already run once counts a doubled world.
    """
    config = {**DEFAULT_OBSERVE_CONFIG, **(project.config.get("observe") or {})}
    budgets = _measurement_budgets(project, config)

    observation = Observation(
        run_id=run_id or _next_run_id(project.reports_dir),
        started_at=_now(),
        context="unknown",
        place={},
    )
    collector = _Collector(bridge, observation)

    info = collector.call("studio.info", timeout=15)
    if info is None:
        observation.evidence.append(Evidence(
            id="studio.bridge.connected",
            probe="studio_bridge_connected",
            category="observability",
            status="FAIL",
            severity="critical",
            message="Studio Bridge did not answer studio.info; nothing could be measured",
            details={"hub": bridge.base_url, "errors": observation.errors},
            source="studio-bridge",
            validation_level=observation.validation_level,
        ))
        observation.validation_level = NOT_VALIDATED
        return observation

    observation.place = {
        "placeName": info.get("placeName"),
        "placeId": info.get("placeId"),
        "gameId": info.get("gameId"),
        "studioVersion": info.get("studioVersion"),
    }
    observation.context = str(info.get("context") or "unknown")
    observation.measurements["studio"] = info
    # A live edit-mode place is measured from the real engine, but the game is
    # not running: that is a stronger claim than reading source and a weaker one
    # than observing a running game. Never label it RUNTIME_VALIDATED.
    observation.validation_level = STATICALLY_VALIDATED if observation.context == "edit" else RUNTIME_VALIDATED

    observation.evidence.append(Evidence(
        id="studio.bridge.connected",
        probe="studio_bridge_connected",
        category="observability",
        status="PASS",
        severity="info",
        message=f"Live Studio answered through the bridge ({observation.context} context)",
        details={"place": observation.place, "context": observation.context, "protocol": PROTOCOL_VERSION},
        source="studio-bridge",
        validation_level=observation.validation_level,
    ))

    observation.reproducibility = {
        "engineVersion": ENGINE_VERSION,
        "protocolVersion": PROTOCOL_VERSION,
        "studioVersion": info.get("studioVersion"),
        "placeId": info.get("placeId"),
        "placeName": info.get("placeName"),
        "commit": _git_commit(project.root),
        "host": platform.node(),
        "python": platform.python_version(),
        "observeConfig": config,
    }

    if start_run and not _start_run(collector, observation):
        return observation

    # Everything after this reads the world. Pin to one DataModel so refs stay
    # valid and two sessions cannot be measured as if they were one.
    try:
        observation.measurements["pinnedSession"] = bridge.pin_to_running(timeout=25)
    except BridgeError as exc:
        observation.errors.append({"method": "pin_to_running", "params": {}, "error": exc.to_dict()})
        observation.evidence.append(Evidence(
            id="studio.session_pinned",
            probe="session_pinned",
            category="observability",
            status="FAIL",
            severity="critical",
            message="measurement could not pin all reads to one running DataModel",
            source="studio-bridge",
            validation_level=observation.validation_level,
            details={"error": exc.to_dict()},
            conclusive=False,
        ))
        if start_run and stop_after:
            collector.call("run.stop", timeout=30)
        return observation

    _measure_world(collector, observation, config, budgets)
    _measure_runtime(collector, observation, budgets)
    _measure_regions(collector, observation, config)
    _measure_navigation(collector, observation)
    _measure_logs(collector, observation)

    if start_run and stop_after:
        collector.call("run.stop", timeout=30)

    # Settle the final level against everything the pass actually observed.
    observation.context = observation.strongest_context()
    if observation.context != "edit" and observation.validation_level == STATICALLY_VALIDATED:
        observation.validation_level = RUNTIME_VALIDATED

    return observation


def _start_run(collector: _Collector, observation: Observation) -> bool:
    """Bring the world to life, refusing to measure an already-generated place."""
    started = collector.call(
        "run.start",
        {"settleSeconds": 6, "requireBaselineBelow": CLEAN_BASELINE_DESCENDANTS},
        timeout=45,
    )
    if started is None:
        # The guard fires as a command error; surface it as evidence rather than
        # measuring a doubled world and reporting confident wrong numbers.
        last = observation.errors[-1]["error"] if observation.errors else {}
        observation.evidence.append(Evidence(
            id="run.clean_baseline",
            probe="clean_baseline",
            category="observability",
            status="FAIL",
            severity="critical",
            message=f"could not start a clean run: {last.get('message', 'unknown reason')}",
            details=last,
            source="studio-bridge",
            validation_level=observation.validation_level,
        ))
        observation.findings.append(_finding(
            "critical", "measurement_integrity", "studio",
            "the place was not in a clean state, so the run was refused",
            "reopen the place in Studio before measuring; Run mode does not undo what game scripts build",
            last,
        ))
        return False

    # Starting the run flips the Studio context, which makes the plugin tear
    # down its session and re-register. Commands issued during that window land
    # on a session that is on its way out, so wait for a listener first.
    try:
        collector.bridge.wait_until_ready(timeout=30)
    except BridgeError as exc:
        observation.errors.append({"method": "wait_until_ready", "params": {}, "error": exc.to_dict()})
        observation.evidence.append(Evidence(
            id="run.clean_baseline",
            probe="clean_baseline",
            category="observability",
            status="FAIL",
            severity="critical",
            message="run changed Studio context but the replacement bridge session never became ready",
            details={"started": started, "error": exc.to_dict()},
            source="studio-bridge",
            validation_level=observation.validation_level,
            conclusive=False,
        ))
        observation.findings.append(_finding(
            "critical", "measurement_integrity", "studio",
            "the run could not be correlated to a ready replacement Studio session",
            "recover the exact Studio worker and rerun; do not reuse measurements from the uncertain context transition",
            {"error": exc.to_dict()},
        ))
        return False

    observation.measurements["runStart"] = started
    observation.context = str(started.get("context") or observation.context)
    observation.validation_level = RUNTIME_VALIDATED if observation.context != "edit" else observation.validation_level
    observation.evidence.append(Evidence(
        id="run.clean_baseline",
        probe="clean_baseline",
        category="observability",
        status="PASS",
        severity="critical",
        message=(
            f"run started from a clean baseline of {started.get('baselineDescendants')} descendants; "
            f"game scripts generated {started.get('generatedDescendants')}"
        ),
        details=started,
        source="studio-bridge",
        validation_level=observation.validation_level,
    ))
    return True


def _measure_world(collector: _Collector, observation: Observation, config: dict[str, Any], budgets: dict[str, Any]) -> None:
    summary = collector.call("world.summary", timeout=30)
    if summary is None:
        return
    observation.measurements["world"] = summary

    workspace_instances = int(summary.get("workspaceDescendants", 0))
    max_instances = int(budgets["maxWorkspaceInstances"])
    observation.evidence.append(Evidence(
        id="world.instance_budget",
        probe="instance_budget",
        category="performance",
        status="PASS" if workspace_instances <= max_instances else "FAIL",
        severity="major",
        message=f"Workspace holds {workspace_instances} instances (budget {max_instances})",
        details={"measured": workspace_instances, "budget": max_instances, "classCounts": summary.get("classCounts", {})},
        source="studio-bridge",
        validation_level=observation.validation_level,
    ))
    if workspace_instances > max_instances:
        observation.findings.append(_finding(
            "high", "performance", "game.Workspace",
            f"Workspace instance count {workspace_instances} exceeds the {max_instances} budget",
            "reduce part count, merge static geometry or move unused assets out of Workspace",
            {"measured": workspace_instances, "budget": max_instances},
        ))

    below = summary.get("partsBelowY", {})
    below_count = int(below.get("count", 0))
    observation.evidence.append(Evidence(
        id="world.parts_below_floor",
        probe="parts_below_floor",
        category="geometry",
        status="PASS" if below_count == 0 else "FAIL",
        severity="major",
        message=f"{below_count} part(s) below y={below.get('threshold')}",
        details=below,
        source="studio-bridge",
        validation_level=observation.validation_level,
    ))
    if below_count:
        observation.findings.append(_finding(
            "high", "world_geometry", "game.Workspace",
            f"{below_count} part(s) sit below y={below.get('threshold')} and are unreachable",
            "raise or delete the parts that fell out of the playable volume",
            below,
        ))

    unanchored = int(summary.get("unanchoredParts", 0))
    max_unanchored = int(budgets["maxUnanchoredParts"])
    observation.evidence.append(Evidence(
        id="world.unanchored_parts",
        probe="unanchored_parts",
        category="geometry",
        status="PASS" if unanchored <= max_unanchored else "WARN",
        severity="minor",
        message=f"{unanchored} unanchored part(s) (budget {max_unanchored})",
        details={"measured": unanchored, "budget": max_unanchored},
        source="studio-bridge",
        validation_level=observation.validation_level,
    ))

    spawns = collector.call("dm.find", {"className": "SpawnLocation", "root": "game.Workspace", "limit": 50})
    if spawns is not None:
        results = spawns.get("results", [])
        observation.measurements["spawns"] = results
        observation.evidence.append(Evidence(
            id="world.spawn_exists",
            probe="spawn_exists",
            category="gameplay",
            status="PASS" if results else "FAIL",
            severity="critical",
            message=f"{len(results)} SpawnLocation(s) found in Workspace",
            details={"spawns": results},
            source="studio-bridge",
            validation_level=observation.validation_level,
            coverage=0.0,
            conclusive=False,
        ))
        if not results:
            observation.findings.append(_finding(
                "critical", "world_geometry", "game.Workspace",
                "the place has no SpawnLocation; players cannot enter",
                "add a SpawnLocation on solid ground in the starting area",
            ))

        # Every spawn must actually stand on something, measured by raycast.
        for spawn in results[:8]:
            support = collector.call("world.ground_support", {
                "path": spawn["path"],
                "samples": int(config["groundSupportSamples"]),
                "maxGap": float(config["groundSupportMaxGap"]),
            }, timeout=25)
            if support is None:
                continue
            observation.measurements.setdefault("groundSupport", []).append(support)
            supported = bool(support.get("supported"))
            observation.evidence.append(Evidence(
                id=f"world.ground_support::{spawn['path']}",
                probe="ground_support",
                category="geometry",
                status="PASS" if supported else "FAIL",
                severity="critical",
                message=(
                    f"{spawn['path']} rests on a surface "
                    f"({support.get('sampledPoints')} raycasts, coverage {support.get('supportCoverage')})"
                    if supported else
                    f"{spawn['path']} is unsupported at {len(support.get('unsupportedPoints', []))} sampled point(s)"
                ),
                details=support,
                source="studio-bridge",
                validation_level=observation.validation_level,
            ))
            if not supported:
                observation.findings.append(_finding(
                    "critical", "world_geometry", spawn["path"],
                    f"spawn is not supported by ground within {config['groundSupportMaxGap']} studs",
                    "lower the spawn onto the floor or add a support surface beneath it",
                    {"unsupportedPoints": support.get("unsupportedPoints", [])},
                ))


def _measure_runtime(collector: _Collector, observation: Observation, budgets: dict[str, Any]) -> None:
    state = collector.call("run.state", {"sampleSeconds": 0.6}, timeout=25)
    if state is None:
        return
    observation.measurements["runtime"] = state
    runtime = state.get("runtime", {})
    fps = runtime.get("fps")
    is_running = bool(state.get("isRunning"))

    if fps is None:
        observation.evidence.append(Evidence(
            id="runtime.frame_rate",
            probe="frame_rate",
            category="performance",
            status="WARN",
            severity="major",
            message="frame rate could not be sampled in this context",
            details={"unavailable": state.get("unavailable", []), "context": state.get("context")},
            source="studio-bridge",
            validation_level=observation.validation_level,
        ))
    else:
        minimum = float(budgets["minFps"])
        maximum_frame_ms = float(budgets["maxFrameMs"])
        worst_frame_ms = runtime.get("worstFrameMs")
        frame_time_ok = worst_frame_ms is not None and float(worst_frame_ms) <= maximum_frame_ms
        frame_rate_ok = float(fps) >= minimum
        observation.evidence.append(Evidence(
            id="runtime.frame_rate",
            probe="frame_rate",
            category="performance",
            # Edit mode idles at a low frame rate by design, so an edit-context
            # sample is informational rather than a budget failure.
            status="PASS" if frame_rate_ok and frame_time_ok else ("WARN" if not is_running else "FAIL"),
            severity="major",
            message=(
                f"sampled {fps} FPS / {worst_frame_ms} ms worst frame over {runtime.get('sampleSeconds')}s "
                f"in {state.get('context')} context (budgets {minimum} FPS / {maximum_frame_ms} ms)"
            ),
            details={
                "fps": fps,
                "worstFrameMs": worst_frame_ms,
                "minimumFps": minimum,
                "maximumFrameMs": maximum_frame_ms,
                "context": state.get("context"),
                "isRunning": is_running,
            },
            source="studio-bridge",
            validation_level=observation.validation_level,
            conclusive=worst_frame_ms is not None and is_running,
        ))
        if (not frame_rate_ok or not frame_time_ok) and is_running:
            observation.findings.append(_finding(
                "high", "performance", "runtime",
                f"runtime missed its {minimum} FPS / {maximum_frame_ms} ms frame budget",
                "profile scripts and physics; check for per-frame loops and unanchored part counts",
                {"fps": fps, "worstFrameMs": worst_frame_ms},
            ))

    memory = runtime.get("memoryMb")
    if memory is not None:
        budget = float(budgets["maxMemoryMb"])
        observation.evidence.append(Evidence(
            id="runtime.memory",
            probe="memory_budget",
            category="performance",
            status="PASS" if memory <= budget else "FAIL",
            severity="major",
            message=f"{memory} MB in use (budget {budget} MB)",
            details={"memoryMb": memory, "budgetMb": budget},
            source="studio-bridge",
            validation_level=observation.validation_level,
        ))

    workspace_instances = runtime.get("workspaceInstances")
    maximum_instances = int(budgets["maxWorkspaceInstances"])
    maximum_frame_ms = float(budgets["maxFrameMs"])
    complete = fps is not None and runtime.get("worstFrameMs") is not None and workspace_instances is not None
    within_budget = bool(
        complete
        and is_running
        and float(fps) >= float(budgets["minFps"])
        and float(runtime["worstFrameMs"]) <= maximum_frame_ms
        and int(workspace_instances) <= maximum_instances
    )
    observation.evidence.append(Evidence(
        id="runtime.performance_budget",
        probe="performance_budget",
        category="performance",
        status="PASS" if within_budget else ("FAIL" if complete and is_running else "WARN"),
        severity="major",
        message=(
            "runtime met the contracted FPS, frame-time and Workspace instance budgets"
            if within_budget else
            "contracted runtime performance budget was not conclusively met"
        ),
        details={
            "measured": {
                "fps": fps,
                "worstFrameMs": runtime.get("worstFrameMs"),
                "workspaceInstances": workspace_instances,
            },
            "budget": {
                "minimumFps": float(budgets["minFps"]),
                "maximumFrameMs": maximum_frame_ms,
                "maximumWorkspaceInstances": maximum_instances,
            },
            "context": state.get("context"),
            "isRunning": is_running,
            "unavailable": state.get("unavailable", []),
        },
        source="studio-bridge",
        validation_level=observation.validation_level,
        coverage=1.0 if complete and is_running else 0.0,
        conclusive=complete and is_running,
    ))


def _measure_regions(collector: _Collector, observation: Observation, config: dict[str, Any]) -> None:
    """Check that regions which must be exclusive do not intersect.

    Generic by design: plots, zones, arenas and rooms are all "regions that must
    not overlap". The engine finds them by tag first, then by name pattern.
    """
    tagged = collector.call("dm.find", {"tag": config["regionTag"], "limit": 128, "topLevelOnly": True})
    results = (tagged or {}).get("results", [])
    discovery = "tag"

    if not results and config.get("regionNamePattern"):
        by_name = collector.call("dm.find", {
            "namePattern": config["regionNamePattern"],
            "root": config["regionRoot"],
            "limit": 128,
            # "^Plot" matches PlotA and its PlotBorder children alike; only the
            # outermost matches are the exclusive regions being tested.
            "topLevelOnly": True,
        })
        results = (by_name or {}).get("results", [])
        discovery = "namePattern"

    observation.measurements["regions"] = {"discovery": discovery, "count": len(results), "results": results}

    if len(results) < 2:
        observation.evidence.append(Evidence(
            id="world.region_overlap",
            probe="spatial_overlap",
            category="geometry",
            status="WARN",
            severity="minor",
            message=f"only {len(results)} exclusive region(s) discovered; overlap check needs at least two",
            details={"discovery": discovery, "regionTag": config["regionTag"], "regionNamePattern": config.get("regionNamePattern")},
            source="studio-bridge",
            validation_level=observation.validation_level,
        ))
        return

    # Address regions by ref: same-named siblings share one GetFullName path.
    paths = [f"ref:{item['ref']}" if item.get("ref") else item["path"] for item in results]
    overlaps = collector.call("world.overlaps", {"paths": paths, "tolerance": 0.0}, timeout=30)
    if overlaps is None:
        return

    observation.measurements["regionOverlaps"] = overlaps
    clean = bool(overlaps.get("clean"))
    observation.evidence.append(Evidence(
        id="world.region_overlap",
        probe="spatial_overlap",
        category="geometry",
        status="PASS" if clean else "FAIL",
        severity="critical",
        message=(
            f"{overlaps.get('regions')} exclusive regions, none intersecting"
            if clean else
            f"{overlaps.get('overlapping')} intersecting region pair(s) out of {overlaps.get('regions')}"
        ),
        details=overlaps,
        source="studio-bridge",
        validation_level=observation.validation_level,
    ))

    for collision in overlaps.get("collisions", []):
        observation.findings.append(_finding(
            "high", "spatial_overlap", collision["a"],
            f"{collision['a']} intersects {collision['b']}",
            (
                f"move one region {collision['minimumSeparation']} studs along "
                f"{collision['separationAxis']} to separate them"
            ),
            collision,
        ))


def _measure_navigation(collector: _Collector, observation: Observation) -> None:
    """Can a character actually reach the things it is meant to interact with?

    Generic by construction: the objectives are whatever ProximityPrompts the
    place contains, and the origins are its SpawnLocations. No game-specific
    landmark names appear anywhere.
    """
    spawns = observation.measurements.get("spawns") or []
    if not spawns:
        observation.evidence.append(Evidence(
            id="navigation.objective_reachable",
            probe="objective_reachable",
            category="navigation",
            status="WARN",
            severity="critical",
            message="navigation coverage is unavailable because no measured spawn exists",
            source="studio-bridge",
            validation_level=observation.validation_level,
            details={"spawns": 0},
            coverage=0.0,
            conclusive=False,
        ))
        return

    prompts = collector.call("dm.find", {"className": "ProximityPrompt", "root": "game.Workspace", "limit": 40})
    if prompts is None:
        observation.evidence.append(Evidence(
            id="navigation.objective_reachable",
            probe="objective_reachable",
            category="navigation",
            status="WARN",
            severity="critical",
            message="navigation coverage is unavailable because objective discovery failed",
            source="studio-bridge",
            validation_level=observation.validation_level,
            details={"commandErrors": observation.errors[-1:]},
            coverage=0.0,
            conclusive=False,
        ))
        return
    objectives = (prompts or {}).get("results", [])
    observation.measurements["objectives"] = objectives
    if not objectives:
        observation.evidence.append(Evidence(
            id="navigation.objective_reachable",
            probe="objective_reachable",
            category="navigation",
            status="WARN",
            severity="critical",
            message="navigation coverage is zero because no objectives were discovered",
            source="studio-bridge",
            validation_level=observation.validation_level,
            details={"query": prompts.get("query"), "truncated": prompts.get("truncated")},
            coverage=0.0,
            conclusive=False,
            truncated=bool(prompts.get("truncated")),
        ))
        return

    origin = spawns[0]
    checks: list[dict[str, Any]] = []
    unreachable: list[dict[str, Any]] = []
    inconclusive = 0

    for objective in objectives[:12]:
        result = collector.call("world.path", {
            "fromPath": f"ref:{origin['ref']}" if origin.get("ref") else origin["path"],
            "toPath": f"ref:{objective['ref']}" if objective.get("ref") else objective["path"],
        }, timeout=35)
        if result is None:
            continue
        entry = {
            "from": origin["path"],
            "to": objective["path"],
            "reachable": result.get("reachable"),
            "status": result.get("status"),
            "conclusive": result.get("conclusive"),
            "controlStatus": result.get("controlStatus"),
            "straightLineDistance": result.get("straightLineDistance"),
            "waypointCount": result.get("waypointCount"),
        }
        checks.append(entry)
        if not result.get("conclusive"):
            inconclusive += 1
        elif not result.get("reachable"):
            unreachable.append(entry)

    if not checks:
        observation.evidence.append(Evidence(
            id="navigation.objective_reachable",
            probe="objective_reachable",
            category="navigation",
            status="WARN",
            severity="critical",
            message="navigation produced no conclusive objective checks",
            source="studio-bridge",
            validation_level=observation.validation_level,
            details={"objectives": len(objectives), "commandErrors": observation.errors[-len(objectives):]},
            coverage=0.0,
            conclusive=False,
            truncated=bool(prompts.get("truncated")),
        ))
        return

    observation.measurements["navigation"] = {"checks": checks, "unreachable": len(unreachable), "inconclusive": inconclusive}

    if inconclusive == len(checks):
        # The navmesh was unusable, so a NoPath verdict proves nothing. Say that
        # rather than blaming the level for the measurement's own blind spot.
        observation.evidence.append(Evidence(
            id="navigation.objective_reachable",
            probe="objective_reachable",
            category="navigation",
            status="WARN",
            severity="critical",
            message="navigation could not be measured: the navmesh control probe failed",
            details={"checks": checks},
            source="studio-bridge",
            validation_level=observation.validation_level,
            conclusive=False,
        ))
        return

    observation.evidence.append(Evidence(
        id="navigation.objective_reachable",
        probe="objective_reachable",
        category="navigation",
        status="PASS" if not unreachable else "FAIL",
        severity="critical",
        message=(
            f"all {len(checks) - inconclusive} objective(s) reachable on foot from {origin['path']}"
            if not unreachable else
            f"{len(unreachable)} of {len(checks)} objective(s) unreachable from {origin['path']}"
        ),
        details={"checks": checks, "spawn": origin["path"]},
        source="studio-bridge",
        validation_level=observation.validation_level,
        coverage=(len(checks) - inconclusive) / len(objectives) if objectives else 0.0,
        conclusive=inconclusive == 0,
        truncated=bool((prompts or {}).get("truncated")) or len(objectives) > len(checks),
    ))

    for entry in unreachable:
        observation.findings.append(_finding(
            "critical", "navigation", entry["to"],
            f"no path from {entry['from']} to {entry['to']} ({entry['status']})",
            "remove or fix the collision geometry blocking the route, then re-run the navigation check",
            entry,
        ))


def _measure_logs(collector: _Collector, observation: Observation) -> None:
    logs = collector.call("log.tail", {"limit": 200}, timeout=20)
    if logs is None:
        observation.evidence.append(Evidence(
            id="runtime.console_errors",
            probe="runtime_error",
            category="runtime",
            status="WARN",
            severity="critical",
            message="Studio/server output could not be measured",
            details={"commandErrors": observation.errors[-1:]},
            source="studio-bridge",
            validation_level=observation.validation_level,
            coverage=0.0,
            conclusive=False,
        ))
    else:
        observation.measurements["logs"] = logs
        counts = logs.get("counts", {})
        errors = int(counts.get("error", 0))
        server_error_entries = [
            entry for entry in logs.get("entries", [])
            if entry.get("severity") == "error"
        ]

        observation.evidence.append(Evidence(
            id="runtime.console_errors",
            probe="runtime_error",
            category="runtime",
            status="PASS" if errors == 0 else "FAIL",
            severity="critical",
            message=f"{errors} error line(s) in the Studio/server output",
            details={"counts": counts, "entries": server_error_entries[:25]},
            source="studio-bridge",
            validation_level=observation.validation_level,
            coverage=1.0,
            truncated=errors > len(server_error_entries),
        ))

        if errors:
            for entry in server_error_entries[:10]:
                observation.findings.append(_finding(
                    "critical", "runtime_error", "output",
                    entry.get("message", "")[:300],
                    "fix the script raising this error, then re-run the measurement",
                    {"timestamp": entry.get("timestamp")},
                ))

    client_logs = collector.call("client.logs", {"limit": 200}, timeout=25)
    if client_logs is None:
        observation.evidence.append(Evidence(
            id="runtime.client_errors",
            probe="runtime_error",
            category="runtime",
            status="WARN",
            severity="critical",
            message="the active player's client output could not be measured",
            details={"commandErrors": observation.errors[-1:]},
            source="studio-bridge",
            validation_level=observation.validation_level,
            coverage=0.0,
            conclusive=False,
        ))
        return

    observation.measurements["clientLogs"] = client_logs
    available = bool(client_logs.get("available"))
    client_counts = client_logs.get("counts") or {}
    client_errors = int(client_counts.get("error", 0)) if available else 0
    client_entries = [
        entry for entry in client_logs.get("entries", [])
        if entry.get("severity") == "error"
    ]
    observation.evidence.append(Evidence(
        id="runtime.client_errors",
        probe="runtime_error",
        category="runtime",
        status="PASS" if available and client_errors == 0 else ("FAIL" if available else "WARN"),
        severity="critical",
        message=(
            f"{client_errors} error line(s) in the active player's output"
            if available else
            "the active player's LogService history is unavailable"
        ),
        details={
            "available": available,
            "player": client_logs.get("player"),
            "counts": client_counts,
            "entries": client_entries[:25],
            "reason": client_logs.get("reason"),
        },
        source="studio-bridge",
        validation_level=observation.validation_level,
        coverage=1.0 if available else 0.0,
        conclusive=available,
        truncated=bool(available and client_errors > len(client_entries)),
    ))

    for entry in client_entries[:10]:
        observation.findings.append(_finding(
            "critical", "runtime_error", "client-output",
            entry.get("message", "")[:300],
            "fix the LocalScript error and repeat the player scenario",
            {"timestamp": entry.get("timestamp"), "player": client_logs.get("player")},
        ))


def write_observation(observation: Observation, reports_dir: Path) -> dict[str, str]:
    """Persist the run into the artifact tree and update the latest pointer."""
    artifacts = reports_dir.parent / "artifacts" / observation.run_id
    for sub in ("runtime-state", "logs", "report", "screenshots", "metrics"):
        (artifacts / sub).mkdir(parents=True, exist_ok=True)

    payload = observation.to_dict()

    state_path = artifacts / "runtime-state" / "observation.json"
    state_path.write_text(json.dumps(payload, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")

    logs_path = artifacts / "logs" / "studio-output.json"
    logs_path.write_text(json.dumps(observation.measurements.get("logs", {}), indent=2, ensure_ascii=False) + "\n", encoding="utf-8")

    metrics_path = artifacts / "metrics" / "runtime.json"
    metrics_path.write_text(json.dumps(observation.measurements.get("runtime", {}), indent=2, ensure_ascii=False) + "\n", encoding="utf-8")

    run_path = artifacts / "run.json"
    run_path.write_text(json.dumps({
        "runId": observation.run_id,
        "startedAt": observation.started_at,
        "validationLevel": observation.validation_level,
        "status": payload["status"],
        "counts": payload["counts"],
        "findings": len(observation.findings),
        "reproducibility": observation.reproducibility,
    }, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")

    report_path = artifacts / "report" / "summary.md"
    report_path.write_text(_markdown_report(observation), encoding="utf-8")

    reports_dir.mkdir(parents=True, exist_ok=True)
    latest_path = reports_dir / "latest-observation.json"
    latest_path.write_text(json.dumps(payload, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")

    return {
        "observation": str(state_path),
        "run": str(run_path),
        "report": str(report_path),
        "latest": str(latest_path),
    }


def _markdown_report(observation: Observation) -> str:
    counts = observation.counts()
    lines = [
        f"# {observation.run_id}",
        "",
        f"- Validation level: **{observation.validation_level}**",
        f"- Studio context: **{observation.context}**",
        f"- Place: **{observation.place.get('placeName', '?')}**",
        f"- Status: **{'PASS' if observation.ok else 'FAIL'}** ({counts['PASS']} PASS / {counts['WARN']} WARN / {counts['FAIL']} FAIL)",
        "",
        "## Evidence",
        "",
        "| Status | Severity | Probe | Message |",
        "|---|---|---|---|",
    ]
    for item in observation.evidence:
        message = item.message.replace("|", "\\|")
        lines.append(f"| {item.status} | {item.severity} | `{item.probe}` | {message} |")

    if observation.findings:
        lines += ["", "## Findings", "", "| Severity | Category | Location | Finding | Suggested action |", "|---|---|---|---|---|"]
        for item in observation.findings:
            lines.append(
                f"| {item['severity']} | {item['category']} | `{item['location']}` | "
                f"{item['finding'].replace('|', chr(92) + '|')} | {item['suggestedAction']} |"
            )

    if observation.errors:
        lines += ["", "## Commands that failed", ""]
        for item in observation.errors:
            lines.append(f"- `{item['method']}`: {item['error'].get('code')} {item['error'].get('message')}")

    lines += ["", "## Reproducibility", "", "```json", json.dumps(observation.reproducibility, indent=2, ensure_ascii=False), "```", ""]
    return "\n".join(lines)
