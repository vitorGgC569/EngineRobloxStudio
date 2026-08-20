"""The asset package: what the geometry worker returns instead of a file.

A `.glb` on its own is not enough for an agent to work with. It cannot be looked
at, its topology cannot be checked, and the thing that produced it is gone. An
asset that cannot be inspected before publishing is an asset published on faith.

So a build returns a directory:

    asset-<id>/
      source/      the modelling program that produced this, as data
      project/     the .blend, so a human can open and continue it
      export/      .glb and .fbx, plus any textures
      previews/    front, back, left, right, perspective
      analysis/    topology, dimensions, materials, validation
      manifest.json

Two properties make it useful rather than decorative. Every file is hashed, so
a package can be proven unchanged and two revisions can be compared by content
rather than by timestamp. And the program is stored alongside the output, so the
mesh is reproducible: the same program run again produces the same geometry, and
a revision is a diff rather than a new mystery.
"""

from __future__ import annotations

import hashlib
import json
import shutil
from dataclasses import dataclass, field
from datetime import datetime, timezone
from pathlib import Path
from typing import Any


PACKAGE_SCHEMA_VERSION = 1

DIRECTORIES = ("source", "project", "export", "previews", "analysis")


class PackageError(ValueError):
    """The package is malformed."""


def _sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def _timestamp() -> str:
    return datetime.now(timezone.utc).isoformat()


@dataclass
class AssetPackage:
    """A directory holding one asset and everything known about it."""

    root: Path
    asset_id: str

    @classmethod
    def create(cls, parent: Path, asset_id: str) -> "AssetPackage":
        root = Path(parent) / f"asset-{asset_id}"
        for name in DIRECTORIES:
            (root / name).mkdir(parents=True, exist_ok=True)
        return cls(root=root, asset_id=asset_id)

    @classmethod
    def open(cls, root: Path) -> "AssetPackage":
        root = Path(root)
        manifest = root / "manifest.json"
        if not manifest.is_file():
            raise PackageError(f"no manifest at {manifest}")
        document = json.loads(manifest.read_text(encoding="utf-8"))
        return cls(root=root, asset_id=str(document.get("assetId", root.name)))

    # -- paths -----------------------------------------------------------

    @property
    def source_dir(self) -> Path:
        return self.root / "source"

    @property
    def project_dir(self) -> Path:
        return self.root / "project"

    @property
    def export_dir(self) -> Path:
        return self.root / "export"

    @property
    def previews_dir(self) -> Path:
        return self.root / "previews"

    @property
    def analysis_dir(self) -> Path:
        return self.root / "analysis"

    @property
    def manifest_path(self) -> Path:
        return self.root / "manifest.json"

    # -- writing ---------------------------------------------------------

    def write_program(self, program: dict[str, Any]) -> Path:
        """Store the program that produced this asset.

        The reason a package is reproducible. Without it, a revision is a new
        mystery rather than a diff.
        """

        path = self.source_dir / "program.json"
        path.write_text(json.dumps(program, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
        return path

    def write_analysis(self, name: str, payload: dict[str, Any]) -> Path:
        path = self.analysis_dir / f"{name}.json"
        path.write_text(json.dumps(payload, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
        return path

    def adopt(self, source: Path, category: str, name: str | None = None) -> Path:
        """Move a file Blender wrote into the package."""

        if category not in DIRECTORIES:
            raise PackageError(f"unknown package category {category!r}")
        source = Path(source)
        if not source.is_file():
            raise PackageError(f"cannot adopt a file that does not exist: {source}")
        target = self.root / category / (name or source.name)
        target.parent.mkdir(parents=True, exist_ok=True)
        if source.resolve() != target.resolve():
            shutil.move(str(source), str(target))
        return target

    # -- reading ---------------------------------------------------------

    def program(self) -> dict[str, Any]:
        path = self.source_dir / "program.json"
        if not path.is_file():
            raise PackageError(f"package {self.asset_id} has no program")
        return json.loads(path.read_text(encoding="utf-8"))

    def analysis(self, name: str) -> dict[str, Any]:
        path = self.analysis_dir / f"{name}.json"
        if not path.is_file():
            raise PackageError(f"package {self.asset_id} has no {name} analysis")
        return json.loads(path.read_text(encoding="utf-8"))

    def previews(self) -> list[Path]:
        return sorted(path for path in self.previews_dir.glob("*.png"))

    def mesh(self) -> Path | None:
        for extension in (".glb", ".gltf", ".fbx"):
            found = sorted(self.export_dir.glob(f"*{extension}"))
            if found:
                return found[0]
        return None

    # -- integrity -------------------------------------------------------

    def inventory(self) -> dict[str, dict[str, Any]]:
        """Every file in the package, hashed."""

        files: dict[str, dict[str, Any]] = {}
        for path in sorted(self.root.rglob("*")):
            if not path.is_file() or path.name == "manifest.json":
                continue
            relative = path.relative_to(self.root).as_posix()
            files[relative] = {"sha256": _sha256(path), "bytes": path.stat().st_size}
        return files

    def write_manifest(self, extra: dict[str, Any] | None = None) -> dict[str, Any]:
        files = self.inventory()
        # A hash over the file hashes. Two builds of the same program produce the
        # same content hash, which is what makes "did this revision change
        # anything" answerable without opening Blender.
        joined = "\n".join(f"{name}:{record['sha256']}" for name, record in sorted(files.items()))
        content_hash = hashlib.sha256(joined.encode("utf-8")).hexdigest()

        manifest: dict[str, Any] = {
            "schemaVersion": PACKAGE_SCHEMA_VERSION,
            "assetId": self.asset_id,
            "createdAt": _timestamp(),
            "contentHash": content_hash,
            "files": files,
            "fileCount": len(files),
        }
        if extra:
            manifest.update(extra)
        self.manifest_path.write_text(
            json.dumps(manifest, indent=2, ensure_ascii=False) + "\n", encoding="utf-8"
        )
        return manifest

    def manifest(self) -> dict[str, Any]:
        if not self.manifest_path.is_file():
            raise PackageError(f"package {self.asset_id} has no manifest")
        return json.loads(self.manifest_path.read_text(encoding="utf-8"))

    def verify(self) -> list[str]:
        """Confirm the package is intact, and say precisely what is not."""

        problems: list[str] = []
        try:
            manifest = self.manifest()
        except PackageError as exc:
            return [str(exc)]

        recorded = manifest.get("files") or {}
        present = self.inventory()

        for name, record in recorded.items():
            if name not in present:
                problems.append(f"missing: {name}")
            elif present[name]["sha256"] != record.get("sha256"):
                problems.append(f"modified since the manifest was written: {name}")
        for name in present:
            if name not in recorded:
                problems.append(f"present but not in the manifest: {name}")

        if self.mesh() is None:
            problems.append("no exported mesh")
        if not self.previews():
            problems.append("no preview renders, so nothing can review this asset")
        return sorted(problems)

    def to_dict(self) -> dict[str, Any]:
        return {
            "assetId": self.asset_id,
            "root": str(self.root),
            "mesh": str(self.mesh()) if self.mesh() else None,
            "previews": [str(path) for path in self.previews()],
            "fileCount": len(self.inventory()),
        }
