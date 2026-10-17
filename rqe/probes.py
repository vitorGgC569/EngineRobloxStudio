from __future__ import annotations

from typing import Any, Callable

from .models import Evidence
from .project import Project


PROBE_CATALOG: list[tuple[str, str, str]] = [
    ("ground_support", "geometry", "major"),
    ("spawn_clearance", "gameplay", "critical"),
    ("spawn_support", "geometry", "critical"),
    ("path_exists", "navigation", "critical"),
    ("objective_reachable", "navigation", "critical"),
    ("collision_overlap", "geometry", "major"),
    ("floating_objects", "geometry", "major"),
    ("buried_objects", "geometry", "minor"),
    ("door_clearance", "gameplay", "major"),
    ("stairs_validity", "gameplay", "major"),
    ("interaction_distance", "gameplay", "major"),
    ("floor_progression", "gameplay", "major"),
    ("camera_obstruction", "visual", "minor"),
    ("ui_visibility", "ui", "major"),
    ("ui_overflow", "ui", "major"),
    ("card_gallery", "ui", "major"),
    ("button_interaction", "ui", "critical"),
    ("remote_security", "security", "critical"),
    ("runtime_error", "runtime", "critical"),
    ("memory_growth", "performance", "major"),
    ("instance_growth", "performance", "major"),
    ("duplicate_connections", "performance", "major"),
    ("persistence", "persistence", "critical"),
    ("multiplayer_isolation", "multiplayer", "critical"),
    ("performance_budget", "performance", "major"),
    ("asset_security", "security", "critical"),
    ("visual_quality", "visual", "minor"),
    ("visual_asset_quality", "visual", "major"),
    ("visual_snapshot_bundle", "visual", "major"),
    ("studio_runtime_capture", "visual", "major"),
]


def _evidence(
    name: str,
    category: str,
    severity: str,
    passed: bool | None,
    message: str,
    details: dict[str, Any],
    *,
    conclusive: bool = True,
) -> Evidence:
    status = "PASS" if passed is True else "WARN" if passed is None else "FAIL"
    return Evidence(
        id=f"probe.{name}",
        probe=name,
        category=category,
        status=status,
        severity=severity,
        message=message,
        source="headless-runtime",
        validation_level="NOT_VALIDATED",
        details=details,
        conclusive=conclusive,
    )


def _unmeasured(name: str, category: str, severity: str, defect: bool, defect_message: str, details: dict[str, Any]) -> Evidence:
    """A fixture can record a defect. It cannot record a Studio pass.

    ``frameMs: 12.4`` and an empty floating list used to come back PASS, and
    the diagnostic scorer then reported 100. The release gate already refuses
    ``headless-runtime``, but the probe itself was still satisfied.
    """

    if defect:
        return _evidence(name, category, severity, False, defect_message, details, conclusive=False)
    return _evidence(
        name,
        category,
        severity,
        None,
        "not measured in Studio; a fixture or headless literal cannot pass this probe",
        details,
        conclusive=False,
    )


def _nonzero(value: Any) -> bool:
    return isinstance(value, (int, float)) and not isinstance(value, bool) and value != 0


def _explicit_false(items: Any, key: str) -> bool:
    if not isinstance(items, list):
        return False
    return any(isinstance(item, dict) and item.get(key) is False for item in items)


def _door_too_narrow(doors: Any) -> bool:
    """A listed door whose clearance is below its requirement is a recorded defect.

    An empty list, a missing list, or a door that omits clearance is not a measurement.
    """

    if not isinstance(doors, list):
        return False
    for item in doors:
        if not isinstance(item, dict) or item.get("clearance") is None:
            continue
        required = item.get("required", 3)
        if float(item["clearance"]) < float(required):
            return True
    return False


def _security_rejected(runtime: dict[str, Any], network: dict[str, Any], static_scan: dict[str, Any]) -> bool:
    return (
        runtime.get("invalidPayloadRejected") is False
        or network.get("rateLimits") is False
        or static_scan.get("serverPurchaseDistanceGuard") is False
    )


def _asset_insecure(performance: dict[str, Any], static_scan: dict[str, Any]) -> bool:
    count = performance.get("assetPartCount")
    return (
        bool(static_scan.get("suspiciousScripts"))
        or bool(static_scan.get("assetManifestIssues"))
        or (count is not None and int(count) > 500)
    )


def _visual_below_bar(ui: dict[str, Any], static_scan: dict[str, Any]) -> bool:
    score = ui.get("visualScore")
    return (score is not None and float(score) < 0.85) or bool(static_scan.get("visualAssetIssues"))


def run_probes(project: Project, runtime: dict[str, Any], static_scan: dict[str, Any]) -> list[Evidence]:
    # A missing fixture means nobody measured the place. Describe that without
    # crashing, and without turning an empty list, a missing key, or a
    # headless literal into a pass. A recorded defect can still fail the
    # diagnostic. A recorded success stays unmeasured.
    fixture = project.fixture if isinstance(project.fixture, dict) else {}
    v = fixture.get("validation", {})
    geometry = fixture.get("geometry", {})
    spawn = fixture.get("spawn", {})
    ui = fixture.get("ui", {})
    performance = fixture.get("performance", {})
    network = fixture.get("network", {})
    probes: list[Evidence] = []

    samples = geometry.get("groundSupport", {}).get("samples", [])
    max_gap = float(geometry.get("groundSupport", {}).get("maxGap", 1.5))
    unsupported = [sample for sample in samples if not sample.get("supported", False) or float(sample.get("gap", 0)) > max_gap]
    coverage = (len(samples) - len(unsupported)) / len(samples) if samples else 0
    probes.append(_unmeasured(
        "ground_support",
        "geometry",
        "major",
        bool(unsupported),
        "Há pontos sem suporte",
        {"sampledPoints": len(samples), "supportCoverage": round(coverage, 3), "unsupportedPoints": unsupported, "maxGap": max_gap},
    ))

    probes.extend([
        _unmeasured("spawn_clearance", "gameplay", "critical", spawn.get("clearance") is False, "spawn is obstructed", {"clearance": spawn.get("clearance")}),
        _unmeasured("spawn_support", "geometry", "critical", spawn.get("supported") is False, "spawn has nothing under it", {"supportPart": spawn.get("supportPart")}),
        _unmeasured("path_exists", "navigation", "critical", v.get("pathExists") is False, "Caminho Spawn → PlayerPlot ausente", {"path": v.get("path", [])}),
        _unmeasured("objective_reachable", "navigation", "critical", v.get("objectiveReachable") is False, "the objective cannot be reached", {"objectives": v.get("objectives", [])}),
        _unmeasured("collision_overlap", "geometry", "major", bool(geometry.get("overlaps")), "parts overlap", {"overlaps": geometry.get("overlaps", [])}),
        _unmeasured("floating_objects", "geometry", "major", bool(geometry.get("floating")), "Objetos flutuando detectados", {"objects": geometry.get("floating", [])}),
        _unmeasured("buried_objects", "geometry", "minor", bool(geometry.get("buried")), "Objetos enterrados detectados", {"objects": geometry.get("buried", [])}),
        _unmeasured("door_clearance", "gameplay", "major", _door_too_narrow(geometry.get("doors")), "doorways do not have enough clearance", {"doors": geometry.get("doors", [])}),
        _unmeasured("stairs_validity", "gameplay", "major", _explicit_false(geometry.get("stairs"), "valid"), "Escadas inutilizáveis", {"stairs": geometry.get("stairs", [])}),
        _unmeasured("interaction_distance", "gameplay", "major", _explicit_false(v.get("interactions"), "reachable"), "an interaction is out of reach", {"interactions": v.get("interactions", [])}),
        _unmeasured("floor_progression", "gameplay", "major", v.get("floorPurchasePromptResponsive") is False, "the next floor cannot be bought at the lift", {"prompt": "PurchaseFloorPrompt", "responsive": v.get("floorPurchasePromptResponsive")}),
        _unmeasured("camera_obstruction", "visual", "minor", bool(v.get("cameraObstructions")), "test cameras are obstructed", {"obstructions": v.get("cameraObstructions", [])}),
        _unmeasured("ui_visibility", "ui", "major", any(not item.get("visible") for item in ui.get("elements", [])), "UI elements are not all visible", {"elements": ui.get("elements", [])}),
        _unmeasured("ui_overflow", "ui", "major", any(not item.get("withinViewport") for item in ui.get("mobile", {}).get("elements", [])), "UI mobile fora do viewport", {"devices": ui.get("mobile", {})}),
        _unmeasured("card_gallery", "ui", "major", v.get("cardGalleryResponsive") is False or any(item.get("name") == "CardCollectionPanel" and not item.get("visible") for item in ui.get("elements", [])), "card gallery is not visible or responsive", {"responsive": v.get("cardGalleryResponsive"), "elements": ui.get("elements", [])}),
        _unmeasured("button_interaction", "ui", "critical", v.get("purchaseButtonResponsive") is False, "the purchase button does not respond", {"input": "activate PurchasePrompt", "response": v.get("purchaseButtonResponsive")}),
        _unmeasured("remote_security", "security", "critical", _security_rejected(runtime, network, static_scan), "invalid payloads, rate limits, or the distance guard were not enforced", {"invalidPayloadRejected": runtime.get("invalidPayloadRejected"), "rateLimits": network.get("rateLimits"), "serverPurchaseDistanceGuard": static_scan.get("serverPurchaseDistanceGuard")}),
        _unmeasured("runtime_error", "runtime", "critical", _nonzero(runtime.get("consoleErrors")), "Erros de console no fluxo", {"consoleErrors": runtime.get("consoleErrors")}),
        _unmeasured("memory_growth", "performance", "major", performance.get("memoryGrowthMb") is not None and float(performance["memoryGrowthMb"]) > float(performance.get("maxMemoryGrowthMb", 5)), "memory growth is outside budget", {"memoryGrowthMb": performance.get("memoryGrowthMb"), "budgetMb": performance.get("maxMemoryGrowthMb")}),
        _unmeasured("instance_growth", "performance", "major", _nonzero(runtime.get("instanceGrowth")), "instance count grew during the run", {"instanceGrowth": runtime.get("instanceGrowth")}),
        _unmeasured("duplicate_connections", "performance", "major", _nonzero(runtime.get("duplicateConnections")), "duplicate connections were reported", {"duplicateConnections": runtime.get("duplicateConnections")}),
        _unmeasured("persistence", "persistence", "critical", runtime.get("persistencePass") is False, "state was lost across a reconnect", {"beforeReconnect": runtime.get("beforeReconnect"), "afterReconnect": runtime.get("afterReconnect")}),
        _unmeasured("multiplayer_isolation", "multiplayer", "critical", runtime.get("multiplayerIsolation") is False, "Vazamento de estado entre jogadores", {"multiplayerIsolation": runtime.get("multiplayerIsolation")}),
        _unmeasured("performance_budget", "performance", "major", (performance.get("frameMs") is not None and float(performance["frameMs"]) > 16.67) or (performance.get("workspaceInstances") is not None and int(performance["workspaceInstances"]) > 25000), "performance is outside budget", {"frameMs": performance.get("frameMs"), "workspaceInstances": performance.get("workspaceInstances"), "targetFrameMs": 16.67, "maxWorkspaceInstances": 25000}),
        _unmeasured("asset_security", "security", "critical", _asset_insecure(performance, static_scan), "Assets ou scripts falharam no scanner", {"suspiciousScripts": static_scan.get("suspiciousScripts", []), "assetManifestIssues": static_scan.get("assetManifestIssues", []), "assetPartCount": performance.get("assetPartCount")}),
        _unmeasured("visual_quality", "visual", "minor", _visual_below_bar(ui, static_scan), "Snapshots visuais ou artes abaixo do limiar", {"visualScore": ui.get("visualScore"), "snapshots": ui.get("snapshots", []), "visualAssetIssues": static_scan.get("visualAssetIssues", [])}),
        _unmeasured("visual_snapshot_bundle", "visual", "major", bool(static_scan.get("visualSnapshotIssues")), "Pacote de prints visuais inválido", {"captureType": static_scan.get("visualSnapshots", {}).get("captureType"), "liveStudioCapture": static_scan.get("visualSnapshots", {}).get("liveStudioCapture"), "snapshotCount": static_scan.get("visualSnapshots", {}).get("snapshotCount"), "issues": static_scan.get("visualSnapshotIssues", [])}),
        _evidence("studio_runtime_capture", "visual", "major", True if static_scan.get("studioRuntime", {}).get("status") == "PASS" else None, "Capturas runtime do Studio validadas" if static_scan.get("studioRuntime", {}).get("status") == "PASS" else "Studio runtime captures are pending; headless is not live evidence", static_scan.get("studioRuntime", {})),
    ])
    return probes
