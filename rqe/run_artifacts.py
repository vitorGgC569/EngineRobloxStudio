"""Immutable, concurrency-safe artifact directories for release attempts."""

from __future__ import annotations

import json
import os
import re
import secrets
from dataclasses import dataclass, field
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

from .provenance import sha256_file, sha256_json


RUN_ID_PATTERN = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,95}$")


def new_run_id() -> str:
    stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    return f"release-{stamp}-{secrets.token_hex(4)}"


@dataclass
class ArtifactEntry:
    path: str
    sha256: str
    bytes: int
    producer_task_id: str | None = None

    def to_dict(self) -> dict[str, Any]:
        payload: dict[str, Any] = {
            "path": self.path,
            "sha256": self.sha256,
            "bytes": self.bytes,
        }
        if self.producer_task_id is not None:
            payload["producerTaskId"] = self.producer_task_id
        return payload


@dataclass
class RunArtifacts:
    root: Path
    run_id: str
    directory: Path
    created_at: str
    entries: list[ArtifactEntry] = field(default_factory=list)
    finalized: bool = False

    @classmethod
    def create(cls, artifacts_root: Path, run_id: str | None = None) -> "RunArtifacts":
        identifier = run_id or new_run_id()
        if not RUN_ID_PATTERN.fullmatch(identifier):
            raise ValueError(f"invalid run id: {identifier!r}")
        root = artifacts_root.resolve()
        root.mkdir(parents=True, exist_ok=True)
        directory = root / identifier
        directory.mkdir(exist_ok=False)
        return cls(
            root=root,
            run_id=identifier,
            directory=directory,
            created_at=datetime.now(timezone.utc).isoformat(),
        )

    def _target(self, relative: str | Path) -> Path:
        if self.finalized:
            raise RuntimeError("run is finalized and immutable")
        candidate = (self.directory / relative).resolve()
        try:
            candidate.relative_to(self.directory.resolve())
        except ValueError as exc:
            raise ValueError(f"artifact path escapes run directory: {relative}") from exc
        return candidate

    def _register(self, target: Path, producer_task_id: str | None = None) -> None:
        if producer_task_id is not None and not RUN_ID_PATTERN.fullmatch(producer_task_id):
            raise ValueError(f"invalid producer task id: {producer_task_id!r}")
        item = target.relative_to(self.directory).as_posix()
        if any(entry.path == item for entry in self.entries):
            raise FileExistsError(target)
        self.entries.append(ArtifactEntry(
            path=item,
            sha256=sha256_file(target),
            bytes=target.stat().st_size,
            producer_task_id=producer_task_id,
        ))

    def write_bytes(
        self,
        relative: str | Path,
        payload: bytes,
        *,
        producer_task_id: str | None = None,
    ) -> Path:
        target = self._target(relative)
        target.parent.mkdir(parents=True, exist_ok=True)
        with target.open("xb") as handle:
            handle.write(payload)
            handle.flush()
            os.fsync(handle.fileno())
        self._register(target, producer_task_id)
        return target

    def write_text(
        self,
        relative: str | Path,
        payload: str,
        *,
        producer_task_id: str | None = None,
    ) -> Path:
        return self.write_bytes(relative, payload.encode("utf-8"), producer_task_id=producer_task_id)

    def write_json(
        self,
        relative: str | Path,
        payload: Any,
        *,
        producer_task_id: str | None = None,
    ) -> Path:
        return self.write_text(
            relative,
            json.dumps(payload, indent=2, ensure_ascii=False) + "\n",
            producer_task_id=producer_task_id,
        )

    def register_existing(
        self,
        relative: str | Path,
        *,
        producer_task_id: str | None = None,
    ) -> Path:
        """Register a tool-produced artifact without copying or rewriting it."""

        target = self._target(relative)
        if not target.is_file():
            raise FileNotFoundError(target)
        if target.is_symlink():
            raise ValueError(f"artifact must not be a symlink: {relative}")
        self._register(target, producer_task_id)
        return target

    def register_tree(
        self,
        relative: str | Path,
        *,
        producer_task_id: str | None = None,
    ) -> list[Path]:
        """Hash-bind every regular file a tool produced below one run folder.

        Screenshot and external-review tools write several files atomically on
        their own.  This adopts those files into the immutable run without
        copying them or relying on a mutable ``latest`` pointer.  Symlinks and
        empty trees are refused, and every path still passes ``_target``'s
        escape/finalization guards.
        """

        directory = self._target(relative)
        if not directory.is_dir() or directory.is_symlink():
            raise ValueError(f"artifact tree must be a real directory: {relative}")
        paths = sorted(
            (path for path in directory.rglob("*") if path.is_file()),
            key=lambda path: path.relative_to(self.directory).as_posix(),
        )
        if not paths:
            raise ValueError(f"artifact tree contains no files: {relative}")
        for path in paths:
            if path.is_symlink():
                raise ValueError(
                    f"artifact must not be a symlink: {path.relative_to(self.directory)}"
                )
            self._register(path, producer_task_id)
        return paths

    def finalize(self, payload: dict[str, Any]) -> Path:
        if self.finalized:
            raise RuntimeError("run was already finalized")
        for entry in self.entries:
            path = self.directory / entry.path
            if not path.is_file() or path.is_symlink():
                raise RuntimeError(f"registered artifact is missing or unsafe: {entry.path}")
            actual_hash = sha256_file(path)
            actual_bytes = path.stat().st_size
            if actual_hash != entry.sha256 or actual_bytes != entry.bytes:
                raise RuntimeError(f"registered artifact changed before finalization: {entry.path}")

        manifest = {
            "schemaVersion": 2,
            "runId": self.run_id,
            "createdAt": self.created_at,
            "completedAt": datetime.now(timezone.utc).isoformat(),
            "artifacts": [entry.to_dict() for entry in sorted(self.entries, key=lambda item: item.path)],
            **payload,
        }
        manifest["manifestSha256"] = sha256_json(manifest)
        path = self._target("run.json")
        temporary = self.directory / f".run-{secrets.token_hex(8)}.tmp"
        encoded = (json.dumps(manifest, indent=2, ensure_ascii=False) + "\n").encode("utf-8")
        try:
            with temporary.open("xb") as handle:
                handle.write(encoded)
                handle.flush()
                os.fsync(handle.fileno())
            if path.exists():
                raise FileExistsError(path)
            os.replace(temporary, path)
        finally:
            if temporary.exists():
                temporary.unlink()
        self.finalized = True
        return path
