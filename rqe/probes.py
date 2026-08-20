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


def _evidence(name: str, category: str, severity: str, passed: bool | None, message: str, details: dict[str, Any]) -> Evidence:
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
    )


def run_probes(project: Project, runtime: dict[str, Any], static_scan: dict[str, Any]) -> list[Evidence]:
    v = project.fixture.get("validation", {})
    geometry = project.fixture.get("geometry", {})
    spawn = project.fixture.get("spawn", {})
    ui = project.fixture.get("ui", {})
    performance = project.fixture.get("performance", {})
    network = project.fixture.get("network", {})
    probes: list[Evidence] = []

    samples = geometry.get("groundSupport", {}).get("samples", [])
    max_gap = float(geometry.get("groundSupport", {}).get("maxGap", 1.5))
    unsupported = [sample for sample in samples if not sample.get("supported", False) or float(sample.get("gap", 0)) > max_gap]
    coverage = (len(samples) - len(unsupported)) / len(samples) if samples else 0
    probes.append(_evidence("ground_support", "geometry", "major", not unsupported, "A área alvo possui suporte dentro do gap permitido" if not unsupported else "Há pontos sem suporte", {"sampledPoints": len(samples), "supportCoverage": round(coverage, 3), "unsupportedPoints": unsupported, "maxGap": max_gap}))

    probes.extend([
        _evidence("spawn_clearance", "gameplay", "critical", bool(spawn.get("clearance")), "Spawn sem obstrução" if spawn.get("clearance") else "Spawn obstruído", {"clearance": spawn.get("clearance")}),
        _evidence("spawn_support", "geometry", "critical", bool(spawn.get("supported")), "Spawn apoiado em superfície válida" if spawn.get("supported") else "Spawn sem suporte", {"supportPart": spawn.get("supportPart")}),
        _evidence("path_exists", "navigation", "critical", bool(v.get("pathExists")), "Caminho Spawn → PlayerPlot encontrado" if v.get("pathExists") else "Caminho Spawn → PlayerPlot ausente", {"path": v.get("path", [])}),
        _evidence("objective_reachable", "navigation", "critical", bool(v.get("objectiveReachable")), "Objetivo básico alcançável" if v.get("objectiveReachable") else "Objetivo não alcançável", {"objectives": v.get("objectives", [])}),
        _evidence("collision_overlap", "geometry", "major", not geometry.get("overlaps"), "Nenhuma colisão estrutural detectada" if not geometry.get("overlaps") else "Peças sobrepostas", {"overlaps": geometry.get("overlaps", [])}),
        _evidence("floating_objects", "geometry", "major", not geometry.get("floating"), "Nenhum objeto flutuando" if not geometry.get("floating") else "Objetos flutuando detectados", {"objects": geometry.get("floating", [])}),
        _evidence("buried_objects", "geometry", "minor", not geometry.get("buried"), "Nenhum objeto enterrado" if not geometry.get("buried") else "Objetos enterrados detectados", {"objects": geometry.get("buried", [])}),
        _evidence("door_clearance", "gameplay", "major", all(item.get("clearance", 0) >= item.get("required", 3) for item in geometry.get("doors", [])), "Portas têm passagem suficiente", "doors" in geometry and {"doors": geometry.get("doors", [])} or {}),
        _evidence("stairs_validity", "gameplay", "major", all(item.get("valid") for item in geometry.get("stairs", [])), "Escadas utilizáveis", {"stairs": geometry.get("stairs", [])}),
        _evidence("interaction_distance", "gameplay", "major", all(item.get("reachable") for item in v.get("interactions", [])), "Interações dentro do alcance", {"interactions": v.get("interactions", [])}),
        _evidence("floor_progression", "gameplay", "major", bool(v.get("floorPurchasePromptResponsive")), "Compra do próximo andar disponível no elevador", {"prompt": "PurchaseFloorPrompt", "responsive": v.get("floorPurchasePromptResponsive")}),
        _evidence("camera_obstruction", "visual", "minor", not v.get("cameraObstructions"), "Câmeras de teste sem obstrução", {"obstructions": v.get("cameraObstructions", [])}),
        _evidence("ui_visibility", "ui", "major", all(item.get("visible") for item in ui.get("elements", [])), "Elementos de UI visíveis", {"elements": ui.get("elements", [])}),
        _evidence("ui_overflow", "ui", "major", all(item.get("withinViewport") for item in ui.get("mobile", {}).get("elements", [])), "UI mobile dentro do viewport", {"devices": ui.get("mobile", {})}),
        _evidence("card_gallery", "ui", "major", bool(v.get("cardGalleryResponsive")) and any(item.get("name") == "CardCollectionPanel" and item.get("visible") for item in ui.get("elements", [])), "Galeria de cartas visível e responsiva", {"responsive": v.get("cardGalleryResponsive"), "elements": ui.get("elements", [])}),
        _evidence("button_interaction", "ui", "critical", bool(v.get("purchaseButtonResponsive")), "Botão de compra responde ao input" if v.get("purchaseButtonResponsive") else "Botão de compra não responde", {"input": "activate PurchasePrompt", "response": v.get("purchaseButtonResponsive")}),
        _evidence("remote_security", "security", "critical", bool(runtime.get("invalidPayloadRejected")) and bool(network.get("rateLimits")) and bool(static_scan.get("serverPurchaseDistanceGuard")), "Payload inválido rejeitado, rate limit e distância server-side ativos", {"invalidPayloadRejected": runtime.get("invalidPayloadRejected"), "rateLimits": network.get("rateLimits"), "serverPurchaseDistanceGuard": static_scan.get("serverPurchaseDistanceGuard")}),
        _evidence("runtime_error", "runtime", "critical", runtime.get("consoleErrors", 1) == 0, "Fluxo sem erros de console" if runtime.get("consoleErrors", 1) == 0 else "Erros de console no fluxo", {"consoleErrors": runtime.get("consoleErrors")}),
        _evidence("memory_growth", "performance", "major", float(performance.get("memoryGrowthMb", 999)) <= float(performance.get("maxMemoryGrowthMb", 5)), "Crescimento de memória dentro do orçamento", {"memoryGrowthMb": performance.get("memoryGrowthMb"), "budgetMb": performance.get("maxMemoryGrowthMb")}),
        _evidence("instance_growth", "performance", "major", runtime.get("instanceGrowth", 1) == 0, "Nenhum vazamento de instâncias", {"instanceGrowth": runtime.get("instanceGrowth")}),
        _evidence("duplicate_connections", "performance", "major", runtime.get("duplicateConnections", 1) == 0, "Nenhuma conexão duplicada", {"duplicateConnections": runtime.get("duplicateConnections")}),
        _evidence("persistence", "persistence", "critical", bool(runtime.get("persistencePass")), "Estado preservado após reconnect" if runtime.get("persistencePass") else "Estado perdido após reconnect", {"beforeReconnect": runtime.get("beforeReconnect"), "afterReconnect": runtime.get("afterReconnect")}),
        _evidence("multiplayer_isolation", "multiplayer", "critical", bool(runtime.get("multiplayerIsolation")), "Estado e plots isolados entre jogadores" if runtime.get("multiplayerIsolation") else "Vazamento de estado entre jogadores", {"multiplayerIsolation": runtime.get("multiplayerIsolation")}),
        _evidence("performance_budget", "performance", "major", float(performance.get("frameMs", 999)) <= 16.67 and int(performance.get("workspaceInstances", 999999)) <= 25000, "Performance dentro do orçamento", {"frameMs": performance.get("frameMs"), "workspaceInstances": performance.get("workspaceInstances"), "targetFrameMs": 16.67, "maxWorkspaceInstances": 25000}),
        _evidence("asset_security", "security", "critical", not static_scan.get("suspiciousScripts") and not static_scan.get("assetManifestIssues") and int(performance.get("assetPartCount", 999999)) <= 500, "Assets e scripts passaram pelo sandbox scanner", {"suspiciousScripts": static_scan.get("suspiciousScripts", []), "assetManifestIssues": static_scan.get("assetManifestIssues", []), "assetPartCount": performance.get("assetPartCount")}),
        _evidence("visual_quality", "visual", "minor", float(ui.get("visualScore", 0)) >= 0.85 and not static_scan.get("visualAssetIssues"), "Snapshots visuais e artes acima do limiar", {"visualScore": ui.get("visualScore"), "snapshots": ui.get("snapshots", []), "visualAssetIssues": static_scan.get("visualAssetIssues", [])}),
        _evidence("visual_snapshot_bundle", "visual", "major", not static_scan.get("visualSnapshotIssues"), "Pacote de prints visuais validado" if not static_scan.get("visualSnapshotIssues") else "Pacote de prints visuais inválido", {"captureType": static_scan.get("visualSnapshots", {}).get("captureType"), "liveStudioCapture": static_scan.get("visualSnapshots", {}).get("liveStudioCapture"), "snapshotCount": static_scan.get("visualSnapshots", {}).get("snapshotCount"), "issues": static_scan.get("visualSnapshotIssues", [])}),
        _evidence("studio_runtime_capture", "visual", "major", True if static_scan.get("studioRuntime", {}).get("status") == "PASS" else None, "Capturas runtime do Studio validadas" if static_scan.get("studioRuntime", {}).get("status") == "PASS" else "Capturas runtime do Studio pendentes; headless não é evidência live", static_scan.get("studioRuntime", {})),
    ])
    return probes
