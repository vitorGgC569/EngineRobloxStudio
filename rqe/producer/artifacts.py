"""Immutable artifact trail for deterministic producer runs.

This module deliberately records *production*, not release authorization.  A
``ProductionRun`` can prove that a brief was compiled, which stages returned,
and which source tree Rojo packaged without proving that the resulting game ran
in Studio.  Consequently every manifest written here carries
``releaseAllowed = false`` and an explicit ``NOT_EVALUATED`` authorization.

The directory is owned by :class:`rqe.run_artifacts.RunArtifacts`: creation is
exclusive, files are create-only, and ``run.json`` is written once after every
registered artifact has been re-hashed.  No ``latest`` pointer is created or
accepted as a run identity.
"""

from __future__ import annotations

import hashlib
import json
import os
import re
import secrets
import shutil
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path, PurePosixPath
from typing import Any, Iterable

from ..orchestrator.metrics import MetricsError, VerifiedRun, verify_finalized_run
from ..provenance import sha256_file, sha256_json, tree_sha256
from ..run_artifacts import RUN_ID_PATTERN, RunArtifacts
from .pipeline import (
    FAILED,
    NOT_APPLICABLE,
    OK,
    SKIPPED,
    ProductionRun,
    StageResult,
    _stages,
)


ARTIFACT_KIND = "PRODUCTION_RUN"
PRODUCTION_COMPLETE = "PRODUCTION_COMPLETE"
PRODUCTION_FAILED = "PRODUCTION_FAILED"
PRODUCTION_BLOCKED = "PRODUCTION_BLOCKED"
PRODUCTION_STATUSES = {
    PRODUCTION_COMPLETE,
    PRODUCTION_FAILED,
    PRODUCTION_BLOCKED,
}
SHA256_PATTERN = re.compile(r"^[0-9a-f]{64}$")
_PRODUCER_TASK_ID = "producer-run-snapshot"


class ProductionArtifactError(ValueError):
    """A finalized production trail is malformed or cannot be trusted."""


@dataclass(frozen=True)
class ProductionArtifactReceipt:
    run_id: str
    directory: Path
    manifest_path: Path
    manifest_sha256: str
    status: str
    validation_level: str
    blockers: tuple[dict[str, str], ...]
    build_id: str | None
    source_sha256: str | None
    place_sha256: str | None

    def to_dict(self) -> dict[str, Any]:
        return {
            "runId": self.run_id,
            "directory": str(self.directory),
            "manifest": str(self.manifest_path),
            "manifestSha256": self.manifest_sha256,
            "status": self.status,
            "validationLevel": self.validation_level,
            "blockers": [dict(item) for item in self.blockers],
            "buildId": self.build_id,
            "sourceSha256": self.source_sha256,
            "placeSha256": self.place_sha256,
            "releaseAllowed": False,
        }


@dataclass(frozen=True)
class VerifiedProductionArtifacts:
    run: VerifiedRun
    brief: dict[str, Any]
    stages: tuple[dict[str, Any], ...]
    source: dict[str, Any]
    build: dict[str, Any]
    summary: dict[str, Any]

    @property
    def run_id(self) -> str:
        return self.run.run_id

    @property
    def manifest(self) -> dict[str, Any]:
        return self.run.manifest


def new_production_run_id() -> str:
    stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    return f"production-{stamp}-{secrets.token_hex(6)}"


def _issue(code: str, message: str) -> dict[str, str]:
    return {"code": code, "message": message}


def _json_clone(payload: Any, label: str) -> Any:
    """Reject lossy/non-finite stage data before creating an artifact run."""

    try:
        encoded = json.dumps(
            payload,
            ensure_ascii=False,
            sort_keys=True,
            separators=(",", ":"),
            allow_nan=False,
        )
        return json.loads(encoded)
    except (TypeError, ValueError) as exc:
        raise ProductionArtifactError(f"{label} is not deterministic JSON: {exc}") from exc


def _brief_payload(production: ProductionRun) -> dict[str, Any]:
    encoded = production.brief.encode("utf-8")
    return {
        "schemaVersion": 1,
        "gameId": production.game_id,
        "encoding": "utf-8",
        "text": production.brief,
        "sha256": hashlib.sha256(encoded).hexdigest(),
        "bytes": len(encoded),
    }


def _stage_payloads(production: ProductionRun) -> list[dict[str, Any]]:
    payloads: list[dict[str, Any]] = []
    for ordinal, result in enumerate(production.results):
        payloads.append(_json_clone({
            "schemaVersion": 1,
            "gameId": production.game_id,
            "ordinal": ordinal,
            "result": result.to_dict(),
        }, f"stage {result.stage!r}"))
    return payloads


def _stage_issues(production: ProductionRun, root: Path) -> list[dict[str, str]]:
    issues: list[dict[str, str]] = []
    results = production.results
    canonical = tuple(
        stage.id for stage in _stages(root, scaffold=production.scaffold_requested)
    )
    declared = tuple(production.planned_stages)
    observed = tuple(result.stage for result in results)
    if declared != canonical:
        issues.append(_issue(
            "E_STAGE_PLAN_NONCANONICAL",
            "producer stage plan differs from the canonical pipeline: expected "
            + ", ".join(canonical)
            + "; declared "
            + (", ".join(declared) or "<missing>"),
        ))
    if observed != canonical:
        issues.append(_issue(
            "E_STAGE_GRAPH_INCOMPLETE",
            "stage artifacts do not cover the canonical pipeline in order: expected "
            + ", ".join(canonical)
            + "; observed "
            + (", ".join(observed) or "<missing>"),
        ))
    seen: set[str] = set()
    count = 0
    for result in results:
        count += 1
        if result.stage in seen:
            issues.append(_issue(
                "E_STAGE_DUPLICATE",
                f"stage {result.stage!r} appears more than once",
            ))
        seen.add(result.stage)
        if result.status not in {OK, FAILED, SKIPPED, NOT_APPLICABLE}:
            issues.append(_issue(
                "E_STAGE_STATUS",
                f"stage {result.stage!r} has unsupported status {result.status!r}",
            ))
        if result.status == FAILED:
            reason = result.error or "stage failed without a reason"
            issues.append(_issue("E_STAGE_FAILED", f"{result.stage}: {reason}"))
        elif result.status == SKIPPED:
            reason = result.blocked_by or "upstream dependency was not named"
            issues.append(_issue("E_STAGE_SKIPPED", f"{result.stage}: blocked by {reason}"))

        # Defense in depth for old/synthetic producer implementations.  A
        # normally-returned refusal must not become successful evidence.
        detail = result.detail if isinstance(result.detail, dict) else {}
        if "blocked" in detail:
            reason = detail.get("blocked") or "stage reported blocked without a reason"
            issues.append(_issue(
                "E_STAGE_DECLARED_REFUSAL",
                f"{result.stage}: {reason}",
            ))
        elif detail.get("ok") is False:
            reason = detail.get("error") or "stage reported ok=false"
            issues.append(_issue(
                "E_STAGE_DECLARED_REFUSAL",
                f"{result.stage}: {reason}",
            ))
    if count == 0:
        issues.append(_issue("E_STAGES_MISSING", "production run contains no stage results"))
    return issues


def _safe_relative_path(value: Any) -> PurePosixPath | None:
    if not isinstance(value, str) or not value or "\\" in value:
        return None
    logical = PurePosixPath(value)
    if logical.is_absolute() or any(
        part in {"", ".", ".."} or ":" in part for part in logical.parts
    ):
        return None
    return logical


def _safe_project_file(root: Path, value: Any) -> tuple[Path | None, str | None]:
    logical = _safe_relative_path(value)
    if logical is None:
        return None, f"build place path is unsafe: {value!r}"
    cursor = root
    for part in logical.parts:
        cursor = cursor / part
        if cursor.is_symlink():
            return None, f"build place path contains a symlink: {value!r}"
    target = cursor.resolve()
    try:
        target.relative_to(root)
    except ValueError:
        return None, f"build place path escapes the project root: {value!r}"
    if not target.is_file():
        return None, f"build place does not exist: {value!r}"
    return target, None


def _validate_source_paths(root: Path, values: Any) -> tuple[list[str], list[str]]:
    if not isinstance(values, list) or not values:
        return [], ["source receipt does not name any source roots"]
    paths: list[str] = []
    issues: list[str] = []
    for value in values:
        logical = _safe_relative_path(value)
        if logical is None:
            issues.append(f"source path is unsafe: {value!r}")
            continue
        cursor = root
        unsafe = False
        for part in logical.parts:
            cursor = cursor / part
            if cursor.is_symlink():
                issues.append(f"source path contains a symlink: {value!r}")
                unsafe = True
                break
        if unsafe:
            continue
        target = cursor.resolve()
        try:
            target.relative_to(root)
        except ValueError:
            issues.append(f"source path escapes the project root: {value!r}")
            continue
        if not target.exists():
            issues.append(f"source path is missing: {value!r}")
            continue
        paths.append(logical.as_posix())
    if len(paths) != len(set(paths)):
        issues.append("source receipt contains duplicate roots")
    return list(dict.fromkeys(paths)), issues


def _copy_build(run: RunArtifacts, source: Path, relative: str) -> Path:
    """Stream a place into the run and register only the completed copy."""

    target = run.directory / relative
    target.parent.mkdir(parents=True, exist_ok=True)
    temporary = target.parent / f".{target.name}.{secrets.token_hex(8)}.tmp"
    if target.exists():
        raise FileExistsError(target)
    try:
        with source.open("rb") as input_handle, temporary.open("xb") as output_handle:
            shutil.copyfileobj(input_handle, output_handle, length=1024 * 1024)
            output_handle.flush()
            os.fsync(output_handle.fileno())
        os.replace(temporary, target)
        run.register_existing(relative, producer_task_id=_PRODUCER_TASK_ID)
    finally:
        if temporary.exists():
            temporary.unlink()
    return target


def _source_digest(entries: Iterable[dict[str, Any]]) -> str:
    digest = hashlib.sha256()
    for entry in entries:
        digest.update(str(entry["path"]).encode("utf-8"))
        digest.update(b"\0")
        digest.update(str(entry["sha256"]).encode("ascii"))
        digest.update(b"\n")
    return digest.hexdigest()


def _measure_identity(
    production: ProductionRun,
    project_root: Path,
    artifacts: RunArtifacts,
) -> tuple[dict[str, Any], dict[str, Any], list[dict[str, str]], dict[str, str | None]]:
    issues: list[dict[str, str]] = []
    build_result = production.result("build")
    detail = build_result.detail if build_result is not None and isinstance(build_result.detail, dict) else {}
    source_declared = detail.get("source") if isinstance(detail.get("source"), dict) else {}

    declared_source_hash = source_declared.get("sha256")
    declared_source_count = source_declared.get("fileCount")
    declared_place_hash = detail.get("placeSha256")
    declared_build_id = detail.get("buildId")
    declared_place_bytes = detail.get("bytes")
    source_paths, path_issues = _validate_source_paths(project_root, source_declared.get("paths"))
    source_issues = list(path_issues)

    before_hash: str | None = None
    before_files: list[dict[str, Any]] = []
    after_hash: str | None = None
    after_count: int | None = None
    if source_paths and not path_issues:
        before_hash, before_files = tree_sha256(project_root, source_paths)
        if not before_files:
            source_issues.append("source roots contain no hashable files")
        if not isinstance(declared_source_hash, str) or not SHA256_PATTERN.fullmatch(declared_source_hash):
            source_issues.append("declared source sha256 is missing or invalid")
        elif before_hash != declared_source_hash:
            source_issues.append("measured source sha256 differs from the build receipt")
        if (
            isinstance(declared_source_count, bool)
            or not isinstance(declared_source_count, int)
            or declared_source_count < 1
        ):
            source_issues.append("declared source fileCount is missing or invalid")
        elif declared_source_count != len(before_files):
            source_issues.append("measured source file count differs from the build receipt")

    build_issues: list[str] = []
    copied_relative: str | None = None
    copied_hash: str | None = None
    copied_bytes: int | None = None
    if build_result is None:
        build_issues.append("build stage is absent")
    elif build_result.status != OK:
        build_issues.append(f"build stage status is {build_result.status!r}, not OK")
    if detail.get("ok") is not True:
        build_issues.append("build stage did not return ok=true")
    if detail.get("compiles") is not True:
        build_issues.append("build stage did not prove Luau compilation")

    place, place_error = _safe_project_file(project_root, detail.get("place"))
    if place_error:
        build_issues.append(place_error)
    elif place is not None:
        copied_relative = "build/place.rbxlx"
        copied = _copy_build(artifacts, place, copied_relative)
        copied_hash = sha256_file(copied)
        copied_bytes = copied.stat().st_size
        if not isinstance(declared_place_hash, str) or not SHA256_PATTERN.fullmatch(declared_place_hash):
            build_issues.append("declared place sha256 is missing or invalid")
        elif copied_hash != declared_place_hash:
            build_issues.append("copied place sha256 differs from the build receipt")
        if (
            isinstance(declared_place_bytes, bool)
            or not isinstance(declared_place_bytes, int)
            or declared_place_bytes < 1
        ):
            build_issues.append("declared place byte size is missing or invalid")
        elif copied_bytes != declared_place_bytes:
            build_issues.append("copied place byte size differs from the build receipt")

    # A second source pass brackets the potentially long place copy.  This
    # proves the source snapshot did not move while it was being admitted.
    if source_paths and not path_issues:
        after_hash, after_files = tree_sha256(project_root, source_paths)
        after_count = len(after_files)
        if before_hash != after_hash or before_files != after_files:
            source_issues.append("source tree changed while the production snapshot was captured")

    expected_build_id: str | None = None
    if (
        isinstance(declared_source_hash, str)
        and SHA256_PATTERN.fullmatch(declared_source_hash)
        and isinstance(declared_place_hash, str)
        and SHA256_PATTERN.fullmatch(declared_place_hash)
    ):
        expected_build_id = sha256_json({
            "sourceSha256": declared_source_hash,
            "placeSha256": declared_place_hash,
            "gameId": production.game_id,
        })
    if not isinstance(declared_build_id, str) or not SHA256_PATTERN.fullmatch(declared_build_id):
        build_issues.append("declared buildId is missing or invalid")
    elif expected_build_id != declared_build_id:
        build_issues.append("buildId is not derived from gameId, source sha256 and place sha256")

    reevaluate = production.result("reevaluate")
    if reevaluate is not None:
        reevaluate_source = (
            reevaluate.detail.get("source")
            if isinstance(reevaluate.detail, dict) and isinstance(reevaluate.detail.get("source"), dict)
            else {}
        )
        if reevaluate_source.get("sha256") != declared_source_hash:
            build_issues.append("reevaluate source sha256 differs from the packaged source")

    candidate = production.result("release_candidate")
    if candidate is not None and isinstance(candidate.detail, dict):
        for field, expected in (
            ("buildId", declared_build_id),
            ("placeSha256", declared_place_hash),
            ("sourceSha256", declared_source_hash),
        ):
            claimed = candidate.detail.get(field)
            if claimed is not None and claimed != expected:
                build_issues.append(f"release_candidate {field} differs from the build receipt")

    source_verified = not source_issues and bool(before_files)
    build_verified = not build_issues and copied_relative is not None
    identity_verified = source_verified and build_verified
    source_receipt = {
        "schemaVersion": 1,
        "status": "VERIFIED" if source_verified else "NOT_VERIFIED",
        "declared": {
            "sha256": declared_source_hash,
            "fileCount": declared_source_count,
            "paths": source_declared.get("paths"),
        },
        "measured": {
            "sha256": before_hash,
            "fileCount": len(before_files),
            "files": before_files,
        },
        "afterSnapshot": {
            "sha256": after_hash,
            "fileCount": after_count,
        },
        "stableDuringSnapshot": (
            before_hash is not None
            and before_hash == after_hash
            and len(before_files) == after_count
        ),
        "issues": source_issues,
    }
    build_receipt = {
        "schemaVersion": 1,
        "status": "VERIFIED" if build_verified else "NOT_VERIFIED",
        "declared": {
            "buildId": declared_build_id,
            "place": detail.get("place"),
            "placeSha256": declared_place_hash,
            "bytes": declared_place_bytes,
            "compiles": detail.get("compiles"),
            "ok": detail.get("ok"),
        },
        "measured": {
            "artifact": copied_relative,
            "placeSha256": copied_hash,
            "bytes": copied_bytes,
        },
        "identity": {
            "expectedBuildId": expected_build_id,
            "verified": identity_verified,
        },
        "issues": build_issues,
    }
    for message in source_issues:
        issues.append(_issue("E_SOURCE_IDENTITY", message))
    for message in build_issues:
        issues.append(_issue("E_BUILD_IDENTITY", message))
    identity = {
        "buildId": declared_build_id if identity_verified else None,
        "sourceSha256": declared_source_hash if identity_verified else None,
        "placeSha256": declared_place_hash if identity_verified else None,
    }
    return source_receipt, build_receipt, issues, identity


def persist_production_run(
    production: ProductionRun,
    *,
    project_root: str | Path,
    artifacts_root: str | Path | None = None,
    run_id: str | None = None,
) -> ProductionArtifactReceipt:
    """Snapshot one completed ``ProductionRun`` into an immutable run folder.

    The function is safe for concurrent callers because it owns a fresh
    ``RunArtifacts`` directory and never re-opens an existing run.  Supplying
    the same explicit ``run_id`` concurrently makes exactly one caller win the
    exclusive directory creation; generated ids carry 48 random bits.

    This function never evaluates or grants release authorization.
    """

    root = Path(project_root).resolve()
    if not root.is_dir() or root.is_symlink():
        raise ProductionArtifactError(f"project root must be a real directory: {root}")
    identifier = run_id or new_production_run_id()
    if not RUN_ID_PATTERN.fullmatch(identifier):
        raise ProductionArtifactError(f"invalid production run id: {identifier!r}")
    if identifier.casefold() == "latest":
        raise ProductionArtifactError("'latest' is not a production run identity")

    # Preflight serialization so unsupported stage detail cannot leave a
    # plausible-looking, half-populated run folder.
    brief = _json_clone(_brief_payload(production), "brief")
    stages = _stage_payloads(production)
    producer_summary = _json_clone(production.to_dict(), "production summary")

    destination = Path(artifacts_root).resolve() if artifacts_root is not None else root / "artifacts"
    artifacts = RunArtifacts.create(destination, identifier)
    artifacts.write_json("production/brief.json", brief, producer_task_id=_PRODUCER_TASK_ID)
    stage_paths: list[str] = []
    for ordinal, payload in enumerate(stages):
        relative = f"production/stages/{ordinal:03d}.json"
        artifacts.write_json(relative, payload, producer_task_id=_PRODUCER_TASK_ID)
        stage_paths.append(relative)

    issues = _stage_issues(production, root)
    source, build, identity_issues, identity = _measure_identity(production, root, artifacts)
    issues.extend(identity_issues)
    # Preserve order while avoiding a cascade of identical consequences.
    issues = list({(item["code"], item["message"]): item for item in issues}.values())

    source_path = "production/source-receipt.json"
    build_path = "production/build-receipt.json"
    artifacts.write_json(source_path, source, producer_task_id=_PRODUCER_TASK_ID)
    artifacts.write_json(build_path, build, producer_task_id=_PRODUCER_TASK_ID)

    if production.failed:
        status = PRODUCTION_FAILED
    elif issues or production.skipped or not production.results:
        status = PRODUCTION_BLOCKED
    elif production.ok and build["identity"]["verified"] is True:
        status = PRODUCTION_COMPLETE
    else:
        status = PRODUCTION_BLOCKED
    validation_level = (
        "STATICALLY_VALIDATED" if build["identity"]["verified"] is True else "NOT_VALIDATED"
    )

    summary_path = "production/summary.json"
    summary = {
        "schemaVersion": 1,
        "gameId": production.game_id,
        "status": status,
        "validationLevel": validation_level,
        "producer": producer_summary,
        "briefArtifact": "production/brief.json",
        "stageArtifacts": stage_paths,
        "sourceReceiptArtifact": source_path,
        "buildReceiptArtifact": build_path,
        "identity": identity,
        "blockers": issues,
        "releaseAllowed": False,
    }
    artifacts.write_json(summary_path, summary, producer_task_id=_PRODUCER_TASK_ID)

    manifest_path = artifacts.finalize({
        "artifactKind": ARTIFACT_KIND,
        "status": status,
        "validationLevel": validation_level,
        "releaseAllowed": False,
        "releaseAuthorization": {
            "status": "NOT_EVALUATED",
            "authority": False,
            "reason": (
                "This manifest records deterministic production artifacts only; "
                "release requires the independent evidence-backed release gate."
            ),
        },
        "production": {
            "schemaVersion": 1,
            "gameId": production.game_id,
            "briefArtifact": "production/brief.json",
            "stageArtifacts": stage_paths,
            "sourceReceiptArtifact": source_path,
            "buildReceiptArtifact": build_path,
            "summaryArtifact": summary_path,
            "identity": identity,
            "scaffoldRequested": production.scaffold_requested,
            "plannedStages": [
                stage.id for stage in _stages(root, scaffold=production.scaffold_requested)
            ],
            "declaredPlannedStages": list(production.planned_stages),
        },
        "blockers": issues,
    })
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    return ProductionArtifactReceipt(
        run_id=identifier,
        directory=artifacts.directory,
        manifest_path=manifest_path,
        manifest_sha256=manifest["manifestSha256"],
        status=status,
        validation_level=validation_level,
        blockers=tuple(issues),
        build_id=identity["buildId"],
        source_sha256=identity["sourceSha256"],
        place_sha256=identity["placeSha256"],
    )


def _require_reference(verified: VerifiedRun, value: Any, label: str) -> str:
    if not isinstance(value, str) or value not in verified.artifacts:
        raise ProductionArtifactError(f"{label} is not a hash-bound artifact reference")
    return value


def _validate_source_receipt(source: dict[str, Any]) -> None:
    if source.get("schemaVersion") != 1:
        raise ProductionArtifactError("source receipt schemaVersion 1 is required")
    if source.get("status") not in {"VERIFIED", "NOT_VERIFIED"}:
        raise ProductionArtifactError("source receipt status is invalid")
    issues = source.get("issues")
    if not isinstance(issues, list) or any(not isinstance(item, str) or not item for item in issues):
        raise ProductionArtifactError("source receipt issues must be an array of messages")
    measured = source.get("measured")
    if not isinstance(measured, dict):
        raise ProductionArtifactError("source receipt measured section is missing")
    files = measured.get("files")
    if not isinstance(files, list):
        raise ProductionArtifactError("source receipt files must be an array")
    previous = ""
    for entry in files:
        if not isinstance(entry, dict):
            raise ProductionArtifactError("source receipt file entry is invalid")
        logical = _safe_relative_path(entry.get("path"))
        if logical is None or logical.as_posix() <= previous:
            raise ProductionArtifactError("source receipt file paths are unsafe, duplicate or unsorted")
        previous = logical.as_posix()
        if not isinstance(entry.get("sha256"), str) or not SHA256_PATTERN.fullmatch(entry["sha256"]):
            raise ProductionArtifactError("source receipt file sha256 is invalid")
        size = entry.get("bytes")
        if isinstance(size, bool) or not isinstance(size, int) or size < 0:
            raise ProductionArtifactError("source receipt file byte size is invalid")
    measured_hash = measured.get("sha256")
    if files:
        if not isinstance(measured_hash, str) or measured_hash != _source_digest(files):
            raise ProductionArtifactError("source aggregate sha256 does not match its file receipts")
    elif measured_hash is not None:
        raise ProductionArtifactError("empty source receipt cannot claim an aggregate sha256")
    if measured.get("fileCount") != len(files):
        raise ProductionArtifactError("source fileCount does not match its file receipts")
    if source.get("status") == "VERIFIED":
        if issues or not files:
            raise ProductionArtifactError("verified source receipt contains issues or no files")
        declared = source.get("declared")
        after = source.get("afterSnapshot")
        if not isinstance(declared, dict) or not isinstance(after, dict):
            raise ProductionArtifactError("verified source receipt lacks declared/after identity")
        if declared.get("sha256") != measured_hash or declared.get("fileCount") != len(files):
            raise ProductionArtifactError("verified source receipt differs from its declaration")
        if after.get("sha256") != measured_hash or after.get("fileCount") != len(files):
            raise ProductionArtifactError("verified source receipt was not stable during snapshot")
        if source.get("stableDuringSnapshot") is not True:
            raise ProductionArtifactError("verified source receipt does not assert snapshot stability")
    elif not issues:
        raise ProductionArtifactError("unverified source receipt must explain why it is unverified")


def verify_production_run_artifacts(run_directory: str | Path) -> VerifiedProductionArtifacts:
    """Verify manifest integrity and the stricter production-run invariants."""

    directory = Path(run_directory).resolve()
    if directory.name.casefold() == "latest":
        raise ProductionArtifactError("a latest pointer cannot be production authority")
    try:
        verified = verify_finalized_run(directory)
    except MetricsError as exc:
        raise ProductionArtifactError(str(exc)) from exc
    manifest = verified.manifest
    if manifest.get("artifactKind") != ARTIFACT_KIND:
        raise ProductionArtifactError("manifest is not a production run artifact trail")
    if manifest.get("status") not in PRODUCTION_STATUSES:
        raise ProductionArtifactError("production manifest status is invalid")
    if manifest.get("releaseAllowed") is not False:
        raise ProductionArtifactError("production artifacts can never authorize release")
    authorization = manifest.get("releaseAuthorization")
    if not isinstance(authorization, dict) or authorization.get("status") != "NOT_EVALUATED" or authorization.get("authority") is not False:
        raise ProductionArtifactError("production manifest has an invalid release authorization boundary")
    production = manifest.get("production")
    if not isinstance(production, dict) or production.get("schemaVersion") != 1:
        raise ProductionArtifactError("production manifest section is missing or invalid")
    scaffold_requested = production.get("scaffoldRequested")
    planned_stages = production.get("plannedStages")
    declared_planned_stages = production.get("declaredPlannedStages")
    if (
        not isinstance(scaffold_requested, bool)
        or not isinstance(planned_stages, list)
        or not isinstance(declared_planned_stages, list)
    ):
        raise ProductionArtifactError("production manifest has no canonical stage-plan receipt")
    canonical_stages = [
        stage.id for stage in _stages(directory, scaffold=scaffold_requested)
    ]
    if planned_stages != canonical_stages:
        raise ProductionArtifactError("production manifest stage plan is not canonical")

    brief_ref = _require_reference(verified, production.get("briefArtifact"), "briefArtifact")
    source_ref = _require_reference(
        verified, production.get("sourceReceiptArtifact"), "sourceReceiptArtifact"
    )
    build_ref = _require_reference(
        verified, production.get("buildReceiptArtifact"), "buildReceiptArtifact"
    )
    summary_ref = _require_reference(
        verified, production.get("summaryArtifact"), "summaryArtifact"
    )
    stage_refs = production.get("stageArtifacts")
    if not isinstance(stage_refs, list) or not stage_refs:
        raise ProductionArtifactError("production manifest contains no stage artifacts")
    if len(stage_refs) != len(set(stage_refs)):
        raise ProductionArtifactError("production stage artifact references are duplicated")
    stage_paths = [
        _require_reference(verified, value, f"stageArtifacts[{index}]")
        for index, value in enumerate(stage_refs)
    ]

    brief = verified.read_json_artifact(brief_ref)
    source = verified.read_json_artifact(source_ref)
    build = verified.read_json_artifact(build_ref)
    summary = verified.read_json_artifact(summary_ref)
    stages = tuple(verified.read_json_artifact(path) for path in stage_paths)
    if not all(isinstance(item, dict) for item in (brief, source, build, summary, *stages)):
        raise ProductionArtifactError("production artifacts must contain JSON objects")
    if brief.get("schemaVersion") != 1 or brief.get("gameId") != production.get("gameId"):
        raise ProductionArtifactError("brief artifact identity is invalid")
    text = brief.get("text")
    if not isinstance(text, str):
        raise ProductionArtifactError("brief text is missing")
    encoded = text.encode("utf-8")
    if brief.get("sha256") != hashlib.sha256(encoded).hexdigest() or brief.get("bytes") != len(encoded):
        raise ProductionArtifactError("brief receipt does not match its exact text")
    stage_names: set[str] = set()
    stage_refusals: list[str] = []
    for ordinal, stage in enumerate(stages):
        if stage.get("schemaVersion") != 1 or stage.get("gameId") != production.get("gameId") or stage.get("ordinal") != ordinal:
            raise ProductionArtifactError(f"stage artifact {ordinal} has invalid identity/order")
        result = stage.get("result")
        if not isinstance(result, dict) or not isinstance(result.get("stage"), str):
            raise ProductionArtifactError(f"stage artifact {ordinal} has no result")
        stage_name = result["stage"]
        if stage_name in stage_names:
            raise ProductionArtifactError(f"stage artifact name is duplicated: {stage_name}")
        stage_names.add(stage_name)
        status = result.get("status")
        if status not in {OK, FAILED, SKIPPED, NOT_APPLICABLE}:
            raise ProductionArtifactError(f"stage artifact {ordinal} has invalid status")
        detail = result.get("detail") if isinstance(result.get("detail"), dict) else {}
        if status in {FAILED, SKIPPED} or "blocked" in detail or detail.get("ok") is False:
            stage_refusals.append(stage_name)
    stage_graph_complete = [
        stage["result"]["stage"] for stage in stages
    ] == canonical_stages

    _validate_source_receipt(source)
    if build.get("schemaVersion") != 1 or not isinstance(build.get("identity"), dict):
        raise ProductionArtifactError("build receipt is missing or invalid")
    if build.get("status") not in {"VERIFIED", "NOT_VERIFIED"}:
        raise ProductionArtifactError("build receipt status is invalid")
    build_issues = build.get("issues")
    if not isinstance(build_issues, list) or any(
        not isinstance(item, str) or not item for item in build_issues
    ):
        raise ProductionArtifactError("build receipt issues must be an array of messages")
    if build.get("status") == "VERIFIED" and build_issues:
        raise ProductionArtifactError("verified build receipt contains issues")
    if build.get("status") == "NOT_VERIFIED" and not build_issues:
        raise ProductionArtifactError("unverified build receipt must explain why it is unverified")
    identity = production.get("identity")
    if not isinstance(identity, dict):
        raise ProductionArtifactError("production identity is missing")
    blockers = manifest.get("blockers")
    if not isinstance(blockers, list):
        raise ProductionArtifactError("production blockers must be an array")
    if summary.get("status") != manifest.get("status") or summary.get("blockers") != blockers:
        raise ProductionArtifactError("production summary diverges from the final manifest")
    if summary.get("identity") != identity or summary.get("releaseAllowed") is not False:
        raise ProductionArtifactError("production summary identity/authorization diverges")
    if summary.get("briefArtifact") != brief_ref:
        raise ProductionArtifactError("production summary brief reference diverges")
    if summary.get("stageArtifacts") != stage_paths:
        raise ProductionArtifactError("production summary stage references diverge")
    if summary.get("sourceReceiptArtifact") != source_ref or summary.get("buildReceiptArtifact") != build_ref:
        raise ProductionArtifactError("production summary provenance references diverge")
    producer_summary = summary.get("producer")
    if not isinstance(producer_summary, dict):
        raise ProductionArtifactError("production summary producer payload is missing")
    if producer_summary.get("gameId") != production.get("gameId") or producer_summary.get("brief") != text:
        raise ProductionArtifactError("production summary producer/brief identity diverges")
    if producer_summary.get("scaffoldRequested") is not scaffold_requested:
        raise ProductionArtifactError("production summary scaffold profile diverges")
    if producer_summary.get("plannedStages") != declared_planned_stages:
        raise ProductionArtifactError("production summary declared stage plan diverges")
    if producer_summary.get("stages") != [stage["result"] for stage in stages]:
        raise ProductionArtifactError("production summary stage payloads diverge")
    if any(
        not isinstance(item, dict)
        or not isinstance(item.get("code"), str)
        or not item.get("code")
        or not isinstance(item.get("message"), str)
        or not item.get("message")
        for item in blockers
    ):
        raise ProductionArtifactError("production blockers have an invalid shape")
    blocker_codes = {item["code"] for item in blockers}
    if not stage_graph_complete and "E_STAGE_GRAPH_INCOMPLETE" not in blocker_codes:
        raise ProductionArtifactError("incomplete production graph has no explicit blocker")
    if declared_planned_stages != canonical_stages and "E_STAGE_PLAN_NONCANONICAL" not in blocker_codes:
        raise ProductionArtifactError("noncanonical declared stage plan has no explicit blocker")

    if build["identity"].get("verified") is True:
        declared = build.get("declared") if isinstance(build.get("declared"), dict) else {}
        measured = build.get("measured") if isinstance(build.get("measured"), dict) else {}
        place_ref = _require_reference(verified, measured.get("artifact"), "build place artifact")
        place_entry = verified.artifacts[place_ref]
        if measured.get("placeSha256") != place_entry["sha256"] or measured.get("bytes") != place_entry["bytes"]:
            raise ProductionArtifactError("build receipt does not match the copied place artifact")
        source_hash = source.get("measured", {}).get("sha256")
        if declared.get("placeSha256") != measured.get("placeSha256") or declared.get("bytes") != measured.get("bytes"):
            raise ProductionArtifactError("verified build receipt differs from its place declaration")
        if declared.get("ok") is not True or declared.get("compiles") is not True:
            raise ProductionArtifactError("verified build receipt lacks successful compilation")
        expected_build_id = sha256_json({
            "sourceSha256": source_hash,
            "placeSha256": measured.get("placeSha256"),
            "gameId": production.get("gameId"),
        })
        if build["identity"].get("expectedBuildId") != expected_build_id:
            raise ProductionArtifactError("verified build identity is not content-derived")
        expected_identity = {
            "buildId": expected_build_id,
            "sourceSha256": source_hash,
            "placeSha256": measured.get("placeSha256"),
        }
        if identity != expected_identity or declared.get("buildId") != expected_build_id:
            raise ProductionArtifactError("production identity differs from the verified build")
        if source.get("status") != "VERIFIED" or build.get("status") != "VERIFIED":
            raise ProductionArtifactError("verified identity relies on an unverified receipt")
    elif any(value is not None for value in identity.values()):
        raise ProductionArtifactError("unverified production identity must be fail-closed")

    if manifest.get("status") == PRODUCTION_COMPLETE:
        if blockers:
            raise ProductionArtifactError("complete production manifest contains blockers")
        if stage_refusals:
            raise ProductionArtifactError("complete production manifest contains refused stages")
        if build["identity"].get("verified") is not True:
            raise ProductionArtifactError("complete production manifest has no verified build identity")
        if summary.get("producer", {}).get("ok") is not True:
            raise ProductionArtifactError("complete production manifest records a failed producer")
        if manifest.get("validationLevel") != "STATICALLY_VALIDATED":
            raise ProductionArtifactError("complete production manifest has the wrong validation level")
        if not stage_graph_complete or declared_planned_stages != canonical_stages:
            raise ProductionArtifactError("complete production manifest has an incomplete stage graph")
    elif not blockers:
        raise ProductionArtifactError("non-complete production manifest must explain its blockers")

    return VerifiedProductionArtifacts(
        run=verified,
        brief=brief,
        stages=stages,
        source=source,
        build=build,
        summary=summary,
    )


__all__ = [
    "ARTIFACT_KIND",
    "PRODUCTION_BLOCKED",
    "PRODUCTION_COMPLETE",
    "PRODUCTION_FAILED",
    "ProductionArtifactError",
    "ProductionArtifactReceipt",
    "VerifiedProductionArtifacts",
    "new_production_run_id",
    "persist_production_run",
    "verify_production_run_artifacts",
]
