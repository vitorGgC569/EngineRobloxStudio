from __future__ import annotations

import json
from pathlib import Path
from typing import Any

from .project import Project


REQUIRED_SNAPSHOT_FILES = (
    "00-map-overview.png",
    "01-spawn-plaza.png",
    "02-ridge-exchange.png",
    "03-old-lantern-mine.png",
    "04-ridge-lift.png",
    "05-plots-grid.png",
    "06-plot-a-detail.png",
    "07-floor-progression.png",
    "08-card-gallery.png",
    "09-mobile-ui.png",
)


def validate_generated_visuals(project: Project) -> tuple[list[str], dict[str, Any]]:
    manifest_path = project.root / "assets/asset-manifest.json"
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    issues: list[str] = []
    inspected: list[dict[str, Any]] = []
    try:
        from PIL import Image, UnidentifiedImageError
    except ImportError:
        return ["Pillow não está disponível para validar imagens geradas"], {"inspected": inspected}

    for asset in manifest.get("assets", []):
        if asset.get("source") != "generated-raster":
            continue
        local_file = asset.get("localFile")
        if not local_file:
            issues.append(f"{asset.get('key', 'unknown')}: localFile ausente")
            continue
        path = project.root / local_file
        if not path.exists():
            issues.append(f"{asset.get('key', 'unknown')}: arquivo ausente")
            continue
        if path.stat().st_size > 8 * 1024 * 1024:
            issues.append(f"{asset['key']}: arquivo acima de 8 MB")
        try:
            with Image.open(path) as image:
                width, height = image.size
                ratio = width / height if height else 0
                if width < 512 or height < 512:
                    issues.append(f"{asset['key']}: resolução inferior a 512 px")
                if "/cards/" in local_file.replace("\\", "/") and not 0.9 <= ratio <= 1.1:
                    issues.append(f"{asset['key']}: carta precisa ser quase quadrada")
                if "/ui/" in local_file.replace("\\", "/") and not 1.2 <= ratio <= 2.2:
                    issues.append(f"{asset['key']}: painel UI precisa ser panorâmico")
                inspected.append({
                    "key": asset["key"],
                    "path": local_file,
                    "width": width,
                    "height": height,
                    "ratio": round(ratio, 3),
                    "mode": image.mode,
                    "bytes": path.stat().st_size,
                })
        except UnidentifiedImageError:
            issues.append(f"{asset['key']}: imagem não pôde ser decodificada")

    return issues, {"inspected": inspected, "assetCount": len(inspected)}


def validate_visual_snapshot_bundle(project: Project) -> tuple[list[str], dict[str, Any]]:
    manifest_path = project.root / "reports/visual-snapshots/manifest.json"
    issues: list[str] = []
    if not manifest_path.exists():
        return ["pacote de snapshots visuais ausente"], {"manifestPath": "reports/visual-snapshots/manifest.json", "snapshots": []}

    try:
        manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        return [f"manifesto de snapshots inválido: {exc}"], {"manifestPath": "reports/visual-snapshots/manifest.json", "snapshots": []}

    snapshots = manifest.get("snapshots", [])
    by_file = {item.get("file"): item for item in snapshots if isinstance(item, dict)}
    missing = [filename for filename in REQUIRED_SNAPSHOT_FILES if filename not in by_file]
    issues.extend(f"snapshot ausente no manifesto: {filename}" for filename in missing)
    inspected: list[dict[str, Any]] = []
    try:
        from PIL import Image, UnidentifiedImageError
    except ImportError:
        return ["Pillow não está disponível para validar snapshots"], {"manifestPath": "reports/visual-snapshots/manifest.json", "snapshots": snapshots}

    for filename in REQUIRED_SNAPSHOT_FILES:
        path = project.root / "reports/visual-snapshots" / filename
        if not path.exists():
            issues.append(f"arquivo de snapshot ausente: {filename}")
            continue
        try:
            with Image.open(path) as image:
                width, height = image.size
                if width < 800 or height < 500:
                    issues.append(f"snapshot {filename} tem resolução baixa")
                inspected.append({"file": filename, "width": width, "height": height, "bytes": path.stat().st_size})
        except (UnidentifiedImageError, OSError):
            issues.append(f"snapshot {filename} não pôde ser decodificado")

    return issues, {
        "manifestPath": "reports/visual-snapshots/manifest.json",
        "captureType": manifest.get("captureType"),
        "liveStudioCapture": bool(manifest.get("liveStudioCapture")),
        "inspected": inspected,
        "snapshotCount": len(inspected),
    }
