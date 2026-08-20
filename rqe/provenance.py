"""Content-addressed build provenance for immutable release runs."""

from __future__ import annotations

import hashlib
import json
import subprocess
from pathlib import Path
from typing import Any, Iterable, Mapping

from .project import Project


DEFAULT_SOURCE_ROOTS = (
    "rqe",
    "schemas",
    "contracts",
    "roblox/lib/WorldKit",
)

IGNORED_PARTS = {"__pycache__", ".git", ".tmp", "artifacts", "reports"}


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def sha256_json(payload: Any) -> str:
    encoded = json.dumps(payload, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode("utf-8")
    return hashlib.sha256(encoded).hexdigest()


def _safe_path(root: Path, relative: str | Path, *, required: bool = True) -> Path | None:
    root = root.resolve()
    candidate = (root / relative).resolve()
    try:
        candidate.relative_to(root)
    except ValueError as exc:
        raise ValueError(f"provenance path escapes project root: {relative}") from exc
    if candidate.is_symlink():
        raise ValueError(f"provenance path must not be a symlink: {relative}")
    if not candidate.exists():
        if required:
            raise FileNotFoundError(candidate)
        return None
    return candidate


def tree_sha256(root: Path, paths: Iterable[str | Path]) -> tuple[str, list[dict[str, Any]]]:
    """Hash files and their project-relative names in stable order."""

    root = root.resolve()
    files: dict[str, Path] = {}
    for requested in paths:
        target = _safe_path(root, requested, required=False)
        if target is None:
            continue
        candidates = [target] if target.is_file() else target.rglob("*")
        for candidate in candidates:
            if not candidate.is_file() or candidate.is_symlink():
                continue
            relative = candidate.relative_to(root)
            if any(part in IGNORED_PARTS for part in relative.parts):
                continue
            files[relative.as_posix()] = candidate

    digest = hashlib.sha256()
    entries: list[dict[str, Any]] = []
    for relative, path in sorted(files.items()):
        file_hash = sha256_file(path)
        digest.update(relative.encode("utf-8"))
        digest.update(b"\0")
        digest.update(file_hash.encode("ascii"))
        digest.update(b"\n")
        entries.append({"path": relative, "sha256": file_hash, "bytes": path.stat().st_size})
    return digest.hexdigest(), entries


def _file_receipt(root: Path, relative: str | Path, *, required: bool = True) -> dict[str, Any] | None:
    path = _safe_path(root, relative, required=required)
    if path is None:
        return None
    if not path.is_file():
        raise ValueError(f"expected a file for provenance: {relative}")
    return {
        "path": path.relative_to(root.resolve()).as_posix(),
        "sha256": sha256_file(path),
        "bytes": path.stat().st_size,
    }


def _git_commit(root: Path) -> str | None:
    try:
        result = subprocess.run(
            ["git", "rev-parse", "HEAD"],
            cwd=root,
            capture_output=True,
            text=True,
            timeout=5,
            check=False,
        )
    except (OSError, subprocess.SubprocessError):
        return None
    value = result.stdout.strip()
    return value if result.returncode == 0 and value else None


def collect_input_provenance(
    project: Project,
    *,
    visual_spec_path: Path | None = None,
    product_identity_stamp: Mapping[str, Any] | None = None,
) -> dict[str, Any]:
    """Fingerprint every input that can affect a Rojo release build."""

    root = project.root.resolve()
    configured_sources = list(DEFAULT_SOURCE_ROOTS)
    configured_sources.extend(str(item) for item in project.config.get("scanPaths", []))
    source_hash, source_files = tree_sha256(root, configured_sources)
    plugin_hash, plugin_files = tree_sha256(root, ["apps/studio-plugin/src"])
    worldkit_hash, worldkit_files = tree_sha256(root, ["roblox/lib/WorldKit"])
    asset_hash, asset_files = tree_sha256(root, ["assets"])
    contract = _file_receipt(root, project.config.get("contract", "contracts/mining-tycoon.robloxqa.json"))
    configuration = _file_receipt(root, "rqe.project.json")
    rojo = _file_receipt(root, project.config.get("rojoProject", "roblox/mvp/default.project.json"))
    asset_manifest = _file_receipt(root, project.config.get("assetManifest", "assets/asset-manifest.json"))
    visual: dict[str, Any] | None = None
    if visual_spec_path is not None:
        try:
            relative = visual_spec_path.resolve().relative_to(root)
        except ValueError as exc:
            raise ValueError("visual spec escapes project root") from exc
        visual = _file_receipt(root, relative)

    hashes = {
        "source": source_hash,
        "contract": contract["sha256"] if contract else None,
        "configuration": configuration["sha256"] if configuration else None,
        "rojoProject": rojo["sha256"] if rojo else None,
        "plugin": plugin_hash,
        "worldKit": worldkit_hash,
        "assets": asset_hash,
        "assetManifest": asset_manifest["sha256"] if asset_manifest else None,
        "visualSpec": visual["sha256"] if visual else None,
        "productTruth": (
            dict(product_identity_stamp.get("artifactHashes", {}))
            if product_identity_stamp is not None
            else None
        ),
        "productStamp": (
            product_identity_stamp.get("stampSha256")
            if product_identity_stamp is not None
            else None
        ),
    }
    return {
        "schemaVersion": 1,
        "inputId": sha256_json(hashes),
        "hashes": hashes,
        "files": {
            "source": len(source_files),
            "plugin": len(plugin_files),
            "worldKit": len(worldkit_files),
            "assets": len(asset_files),
        },
        "contract": contract,
        "configuration": configuration,
        "rojoProject": rojo,
        "assetManifest": asset_manifest,
        "visualSpec": visual,
        "productTruth": dict(product_identity_stamp) if product_identity_stamp is not None else None,
    }


def collect_build_provenance(
    project: Project,
    place_path: Path,
    *,
    visual_spec_path: Path | None = None,
    seed: Any = None,
    product_identity_stamp: Mapping[str, Any] | None = None,
) -> dict[str, Any]:
    """Create the receipt every evidence item must bind to."""

    root = project.root.resolve()
    place = place_path.resolve()
    if not place.is_file():
        raise FileNotFoundError(place)

    configured_sources = list(DEFAULT_SOURCE_ROOTS)
    configured_sources.extend(str(item) for item in project.config.get("scanPaths", []))
    source_hash, source_files = tree_sha256(root, configured_sources)
    plugin_hash, plugin_files = tree_sha256(root, ["apps/studio-plugin/src"])
    worldkit_hash, worldkit_files = tree_sha256(root, ["roblox/lib/WorldKit"])
    asset_hash, asset_files = tree_sha256(root, ["assets"])

    contract_receipt = _file_receipt(root, project.config.get("contract", "contracts/mining-tycoon.robloxqa.json"))
    config_receipt = _file_receipt(root, "rqe.project.json")
    rojo_relative = project.config.get("rojoProject", "roblox/mvp/default.project.json")
    rojo_receipt = _file_receipt(root, rojo_relative)
    asset_receipt = _file_receipt(root, project.config.get("assetManifest", "assets/asset-manifest.json"))

    visual_receipt: dict[str, Any] | None = None
    if visual_spec_path is not None:
        visual_resolved = visual_spec_path.resolve()
        try:
            visual_relative = visual_resolved.relative_to(root)
        except ValueError as exc:
            raise ValueError("visual spec escapes project root") from exc
        visual_receipt = _file_receipt(root, visual_relative)

    place_receipt = {
        "path": str(place),
        "sha256": sha256_file(place),
        "bytes": place.stat().st_size,
    }
    components = {
        "source": source_hash,
        "contract": contract_receipt["sha256"] if contract_receipt else None,
        "config": config_receipt["sha256"] if config_receipt else None,
        "rojoProject": rojo_receipt["sha256"] if rojo_receipt else None,
        "place": place_receipt["sha256"],
        "plugin": plugin_hash,
        "worldKit": worldkit_hash,
        "assets": asset_hash,
        "assetManifest": asset_receipt["sha256"] if asset_receipt else None,
        "visualSpec": visual_receipt["sha256"] if visual_receipt else None,
        "productTruth": (
            dict(product_identity_stamp.get("artifactHashes", {}))
            if product_identity_stamp is not None
            else None
        ),
        "productStamp": (
            product_identity_stamp.get("stampSha256")
            if product_identity_stamp is not None
            else None
        ),
        "seed": seed,
    }
    build_id = sha256_json(components)
    return {
        "schemaVersion": 1,
        "buildId": build_id,
        "gitCommit": _git_commit(root),
        "seed": seed,
        "hashes": components,
        "contract": contract_receipt,
        "configuration": config_receipt,
        "rojoProject": rojo_receipt,
        "place": place_receipt,
        "plugin": {"sha256": plugin_hash, "fileCount": len(plugin_files)},
        "worldKit": {"sha256": worldkit_hash, "fileCount": len(worldkit_files)},
        "assets": {
            "sha256": asset_hash,
            "fileCount": len(asset_files),
            "manifest": asset_receipt,
        },
        "visualSpec": visual_receipt,
        "productTruth": dict(product_identity_stamp) if product_identity_stamp is not None else None,
        "source": {"sha256": source_hash, "fileCount": len(source_files)},
    }
