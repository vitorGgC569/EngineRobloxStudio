from __future__ import annotations

import json
import re
from pathlib import Path
from typing import Any

from .models import Evidence
from .project import Project
from .studio import detect_studio
from .visual import validate_generated_visuals, validate_visual_snapshot_bundle


SUSPICIOUS_PATTERNS = {
    "numeric_require": re.compile(r"\brequire\s*\(\s*\d+\s*\)"),
    "http_request": re.compile(r"\bHttpService\s*:\s*(HttpGet|GetAsync|PostAsync|RequestAsync)\b"),
    "dynamic_code": re.compile(r"\b(loadstring|LoadString)\b"),
}


ALLOWED_ASSET_SOURCES = {"native-procedural", "local-approved", "generated-raster"}


def _validate_asset_manifest(project: Project) -> tuple[list[str], dict[str, Any]]:
    manifest_path = project.root / "assets/asset-manifest.json"
    if not manifest_path.exists():
        return ["assets/asset-manifest.json ausente"], {"assetCount": 0, "policy": {}, "manifestPath": str(manifest_path)}

    try:
        manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        return [f"manifesto de assets inválido: {exc}"], {"assetCount": 0, "policy": {}, "manifestPath": str(manifest_path)}

    issues: list[str] = []
    if not isinstance(manifest, dict):
        return ["manifesto de assets deve ser um objeto JSON"], {"assetCount": 0, "policy": {}, "manifestPath": str(manifest_path)}

    policy = manifest.get("policy", {})
    if not isinstance(policy, dict):
        issues.append("policy deve ser um objeto")
        policy = {}

    assets = manifest.get("assets", [])
    if not isinstance(assets, list) or not assets:
        issues.append("assets deve ser uma lista não vazia")
        assets = []

    seen_keys: set[str] = set()
    for index, asset in enumerate(assets):
        prefix = f"assets[{index}]"
        if not isinstance(asset, dict):
            issues.append(f"{prefix} deve ser um objeto")
            continue

        key = asset.get("key")
        if not isinstance(key, str) or not key:
            issues.append(f"{prefix}.key deve ser uma string não vazia")
        elif key in seen_keys:
            issues.append(f"chave de asset duplicada: {key}")
        else:
            seen_keys.add(key)

        if asset.get("source") not in ALLOWED_ASSET_SOURCES:
            issues.append(f"{prefix}.source não é aprovado")
        if asset.get("status") != "approved":
            issues.append(f"{prefix}.status precisa ser approved")
        if policy.get("requireScriptScan", True) and asset.get("scriptScan") != "clean":
            issues.append(f"{prefix}.scriptScan precisa ser clean")

        allocated_to = asset.get("allocatedTo")
        if policy.get("requireAllocation", True) and (
            not isinstance(allocated_to, list)
            or not allocated_to
            or any(not isinstance(target, str) or not target for target in allocated_to)
        ):
            issues.append(f"{prefix}.allocatedTo precisa apontar para pelo menos um destino")

        max_instances = asset.get("maxInstances")
        if isinstance(max_instances, bool) or not isinstance(max_instances, int) or max_instances <= 0:
            issues.append(f"{prefix}.maxInstances precisa ser um inteiro positivo")
        if not isinstance(asset.get("functionalProbe"), str) or not asset.get("functionalProbe"):
            issues.append(f"{prefix}.functionalProbe precisa ser preenchido")
        local_file = asset.get("localFile")
        if local_file and not (project.root / local_file).exists():
            issues.append(f"{prefix}.localFile não existe: {local_file}")

    details = {
        "manifestPath": str(manifest_path.relative_to(project.root)).replace("\\", "/"),
        "assetCount": len(assets),
        "policy": policy,
    }
    return issues, details


def scan_structure(project: Project) -> tuple[list[Evidence], dict[str, Any]]:
    evidence: list[Evidence] = []
    missing_paths = [path for path in project.expected_paths() if not (project.root / path).exists()]
    evidence.append(
        Evidence(
            id="structure.required_paths",
            probe="structural_integrity",
            category="structural",
            status="FAIL" if missing_paths else "PASS",
            severity="critical" if missing_paths else "info",
            message=("Arquivos estruturais obrigatórios estão presentes" if not missing_paths else "Arquivos estruturais ausentes"),
            details={"expected": project.expected_paths(), "missing": missing_paths},
            source="filesystem",
            validation_level="STATICALLY_VALIDATED",
        )
    )

    scripts: list[str] = []
    suspicious: list[dict[str, Any]] = []
    scan_roots = [project.root / relative for relative in project.config.get("scanPaths", [project.config.get("scripts", "roblox/mvp/src")])]
    for scan_root in scan_roots:
        if scan_root.exists():
            for path in sorted(scan_root.rglob("*.lua")):
                relative = str(path.relative_to(project.root)).replace("\\", "/")
                scripts.append(relative)
                text = path.read_text(encoding="utf-8")
                for label, pattern in SUSPICIOUS_PATTERNS.items():
                    for match in pattern.finditer(text):
                        line = text.count("\n", 0, match.start()) + 1
                        suspicious.append({"file": relative, "pattern": label, "line": line})

    evidence.append(
        Evidence(
            id="security.asset_scripts",
            probe="asset_security",
            category="security",
            status="FAIL" if suspicious else "PASS",
            severity="critical" if suspicious else "info",
            message=("Nenhum padrão de script suspeito foi encontrado" if not suspicious else "Padrões de script suspeitos encontrados"),
            details={"scriptsScanned": len(scripts), "findings": suspicious},
            source="static-luau-scan",
            validation_level="STATICALLY_VALIDATED",
        )
    )

    asset_manifest_issues, asset_manifest_details = _validate_asset_manifest(project)
    evidence.append(
        Evidence(
            id="security.asset_manifest",
            probe="asset_manifest",
            category="security",
            status="FAIL" if asset_manifest_issues else "PASS",
            severity="critical" if asset_manifest_issues else "info",
            message=("Manifesto de assets alocado, aprovado e validado" if not asset_manifest_issues else "Manifesto de assets inválido ou incompleto"),
            details={**asset_manifest_details, "issues": asset_manifest_issues},
            source="asset-manifest-validator",
            validation_level="STATICALLY_VALIDATED",
        )
    )

    visual_asset_issues, visual_asset_details = validate_generated_visuals(project)
    evidence.append(
        Evidence(
            id="visual.asset_quality",
            probe="visual_asset_quality",
            category="visual",
            status="FAIL" if visual_asset_issues else "PASS",
            severity="major" if visual_asset_issues else "info",
            message=("Artes raster geradas têm resolução e proporção válidas" if not visual_asset_issues else "Artes raster geradas precisam de correção"),
            details={**visual_asset_details, "issues": visual_asset_issues},
            source="visual-asset-validator",
            validation_level="STATICALLY_VALIDATED",
        )
    )

    snapshot_issues, snapshot_details = validate_visual_snapshot_bundle(project)
    evidence.append(
        Evidence(
            id="visual.snapshot_bundle",
            probe="visual_snapshot_bundle",
            category="visual",
            status="FAIL" if snapshot_issues else "PASS",
            severity="major" if snapshot_issues else "info",
            message=("Pacote de prints visuais presente e decodificável" if not snapshot_issues else "Pacote de prints visuais incompleto ou inválido"),
            details={**snapshot_details, "issues": snapshot_issues},
            source="visual-snapshot-validator",
            validation_level="STATICALLY_VALIDATED",
        )
    )

    studio_details = detect_studio(project)
    evidence.append(
        Evidence(
            id="studio.runtime_capture",
            probe="studio_runtime_capture",
            category="visual",
            status=studio_details["status"],
            severity="major",
            message=("Capturas runtime do Studio presentes e identificadas" if studio_details["status"] == "PASS" else "Capturas runtime do Studio ainda não estão disponíveis"),
            details=studio_details,
            source="studio-detector",
            validation_level="STATICALLY_VALIDATED",
        )
    )

    static = {
        "scriptsScanned": len(scripts),
        "scripts": scripts,
        "suspiciousScripts": suspicious,
        "assetManifestIssues": asset_manifest_issues,
        "assetManifest": asset_manifest_details,
        "visualAssetIssues": visual_asset_issues,
        "visualAssets": visual_asset_details,
        "visualSnapshotIssues": snapshot_issues,
        "visualSnapshots": snapshot_details,
        "studioRuntime": studio_details,
        "missingPaths": missing_paths,
        "serverPurchaseDistanceGuard": any(
            path.endswith("ServerMain.server.lua") and "OnServerEvent" in (project.root / path).read_text(encoding="utf-8") and "MaxActivationDistance" in (project.root / path).read_text(encoding="utf-8")
            for path in scripts
        ),
    }
    return evidence, static
