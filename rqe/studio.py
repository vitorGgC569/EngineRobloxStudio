from __future__ import annotations

import json
import os
import shutil
import subprocess
from pathlib import Path
from typing import Any

from .project import Project


RUNTIME_MANIFEST = "reports/studio-runtime/manifest.json"
REQUIRED_RUNTIME_SNAPSHOTS = (
    "spawn-runtime.png",
    "route-runtime.png",
)


def _candidate_paths() -> list[Path]:
    candidates: list[Path] = []
    local_app_data = os.environ.get("LOCALAPPDATA")
    program_files = os.environ.get("ProgramFiles")
    program_files_x86 = os.environ.get("ProgramFiles(x86)")
    for root in (local_app_data, program_files, program_files_x86):
        if root:
            root_path = Path(root)
            candidates.extend([
                root_path / "Roblox" / "Versions" / "RobloxStudioBeta.exe",
                root_path / "Roblox" / "RobloxStudioBeta.exe",
            ])
            versions_root = root_path / "Roblox" / "Versions"
            if versions_root.exists():
                candidates.extend(versions_root.glob("version-*\\RobloxStudioBeta.exe"))
    for command in ("RobloxStudioBeta.exe", "RobloxStudioBeta"):
        resolved = shutil.which(command)
        if resolved:
            candidates.append(Path(resolved))
    return candidates


def _running_process() -> bool:
    if os.name != "nt":
        return False
    try:
        result = subprocess.run(
            ["tasklist", "/FI", "IMAGENAME eq RobloxStudioBeta.exe", "/FO", "CSV", "/NH"],
            capture_output=True,
            text=True,
            timeout=3,
            check=False,
        )
    except (OSError, subprocess.SubprocessError):
        return False
    return "RobloxStudioBeta.exe" in result.stdout


def _runtime_manifest(project: Project) -> tuple[bool, dict[str, Any]]:
    manifest_path = project.root / RUNTIME_MANIFEST
    if not manifest_path.exists():
        return False, {"manifestPath": RUNTIME_MANIFEST, "liveStudioCapture": False, "snapshots": [], "issues": ["runtime manifest ausente"]}
    try:
        payload = json.loads(manifest_path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        return False, {"manifestPath": RUNTIME_MANIFEST, "liveStudioCapture": False, "snapshots": [], "issues": [f"runtime manifest inválido: {exc}"]}
    snapshots = payload.get("snapshots", []) if isinstance(payload, dict) else []
    by_file = {item.get("file"): item for item in snapshots if isinstance(item, dict)}
    missing = [filename for filename in REQUIRED_RUNTIME_SNAPSHOTS if filename not in by_file]
    issues = list(payload.get("issues", [])) if isinstance(payload, dict) else ["runtime manifest deve ser um objeto"]
    issues.extend(f"runtime snapshot ausente: {filename}" for filename in missing)
    live = bool(isinstance(payload, dict) and payload.get("liveStudioCapture") is True and not issues)
    return live, {
        "manifestPath": RUNTIME_MANIFEST,
        "liveStudioCapture": bool(isinstance(payload, dict) and payload.get("liveStudioCapture")),
        "captureType": payload.get("captureType") if isinstance(payload, dict) else None,
        "snapshots": snapshots,
        "issues": issues,
    }


def detect_studio(project: Project) -> dict[str, Any]:
    executable = next((path for path in _candidate_paths() if path.exists()), None)
    process_running = _running_process()
    live_capture, runtime_details = _runtime_manifest(project)
    studio_detected = bool(executable or process_running)
    ready = live_capture and studio_detected
    issues: list[str] = []
    if not studio_detected:
        issues.append("Roblox Studio não foi detectado no ambiente atual")
    if studio_detected and not live_capture:
        issues.append("Studio/ponte detectado, mas não há pacote de capturas runtime válido")
    if not studio_detected and not live_capture:
        issues.append("captura runtime bloqueada; somente evidência headless/source-preview está disponível")
    return {
        "status": "PASS" if ready else "WARN",
        "studioDetected": studio_detected,
        "processRunning": process_running,
        "executablePath": str(executable) if executable else None,
        "captureAdapter": "runtime-manifest" if live_capture else "not-connected",
        "liveStudioCapture": live_capture,
        "runtime": runtime_details,
        "issues": issues,
    }
