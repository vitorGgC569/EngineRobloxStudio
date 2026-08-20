"""Verified dashboard projection over immutable release-run manifests.

The dashboard is deliberately downstream of release truth.  This module reads
only finalized ``run.json`` schema v2 manifests, verifies the manifest digest
and every registered artifact, and then derives display metrics.  Neither the
index nor its optional latest pointer can authorize a release.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import secrets
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path, PurePosixPath
from typing import Any, Iterable

from ..provenance import sha256_file, sha256_json


SHA256_PATTERN = re.compile(r"^[0-9a-f]{64}$")
CHECK_STATUSES = {"PASS", "WARN", "FAIL", "ERROR", "SKIP", "BLOCKED"}


class MetricsError(ValueError):
    pass


@dataclass(frozen=True)
class VerifiedRun:
    directory: Path
    manifest: dict[str, Any]
    artifacts: dict[str, dict[str, Any]]
    created_at: datetime
    completed_at: datetime

    @property
    def run_id(self) -> str:
        return str(self.manifest["runId"])

    @property
    def manifest_sha256(self) -> str:
        return str(self.manifest["manifestSha256"])

    def read_json_artifact(self, reference: Any) -> Any:
        if not isinstance(reference, str) or reference not in self.artifacts:
            raise MetricsError(f"run {self.run_id}: artifact reference is not hash-bound: {reference!r}")
        target = self.directory / reference
        try:
            return json.loads(target.read_text(encoding="utf-8"))
        except (OSError, UnicodeDecodeError, json.JSONDecodeError) as exc:
            raise MetricsError(f"run {self.run_id}: artifact {reference!r} is not valid JSON: {exc}") from exc


def _utc_timestamp() -> str:
    return datetime.now(timezone.utc).isoformat()


def _parse_timestamp(value: Any, label: str) -> datetime:
    if not isinstance(value, str) or not value:
        raise MetricsError(f"{label} must be an ISO-8601 timestamp")
    try:
        parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError as exc:
        raise MetricsError(f"{label} must be an ISO-8601 timestamp") from exc
    if parsed.tzinfo is None:
        raise MetricsError(f"{label} must include a timezone")
    return parsed.astimezone(timezone.utc)


def _safe_artifact_path(run_directory: Path, relative: Any) -> Path:
    if not isinstance(relative, str) or not relative or "\\" in relative:
        raise MetricsError(f"artifact path must be a non-empty POSIX relative path: {relative!r}")
    logical = PurePosixPath(relative)
    if logical.is_absolute() or any(part in {"", ".", ".."} for part in logical.parts):
        raise MetricsError(f"artifact path is unsafe: {relative!r}")

    cursor = run_directory
    for part in logical.parts:
        cursor = cursor / part
        if cursor.is_symlink():
            raise MetricsError(f"artifact path contains a symlink: {relative!r}")
    resolved_root = run_directory.resolve()
    resolved = cursor.resolve()
    try:
        resolved.relative_to(resolved_root)
    except ValueError as exc:
        raise MetricsError(f"artifact path escapes its run: {relative!r}") from exc
    return resolved


def verify_finalized_run(run_directory: str | Path) -> VerifiedRun:
    """Verify one immutable manifest and all of its registered artifacts."""

    directory = Path(run_directory).resolve()
    manifest_path = directory / "run.json"
    if not manifest_path.is_file() or manifest_path.is_symlink():
        raise MetricsError(f"{directory.name}: finalized run.json is missing or unsafe")
    try:
        manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    except (OSError, UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise MetricsError(f"{directory.name}: run.json is not valid JSON: {exc}") from exc
    if not isinstance(manifest, dict) or manifest.get("schemaVersion") != 2:
        raise MetricsError(f"{directory.name}: finalized run schemaVersion 2 is required")
    if manifest.get("runId") != directory.name:
        raise MetricsError(f"{directory.name}: manifest runId does not match its directory")

    claimed_manifest_hash = manifest.get("manifestSha256")
    if not isinstance(claimed_manifest_hash, str) or not SHA256_PATTERN.fullmatch(claimed_manifest_hash):
        raise MetricsError(f"{directory.name}: manifestSha256 is missing or invalid")
    hash_input = dict(manifest)
    hash_input.pop("manifestSha256", None)
    actual_manifest_hash = sha256_json(hash_input)
    if actual_manifest_hash != claimed_manifest_hash:
        raise MetricsError(f"{directory.name}: manifestSha256 does not match run.json")

    created_at = _parse_timestamp(manifest.get("createdAt"), f"{directory.name}.createdAt")
    completed_at = _parse_timestamp(manifest.get("completedAt"), f"{directory.name}.completedAt")
    if completed_at < created_at:
        raise MetricsError(f"{directory.name}: completedAt precedes createdAt")
    if not isinstance(manifest.get("status"), str) or not manifest["status"]:
        raise MetricsError(f"{directory.name}: final status is missing")
    if not isinstance(manifest.get("releaseAllowed"), bool):
        raise MetricsError(f"{directory.name}: releaseAllowed must be boolean")

    raw_artifacts = manifest.get("artifacts")
    if not isinstance(raw_artifacts, list):
        raise MetricsError(f"{directory.name}: artifacts must be an array")
    artifacts: dict[str, dict[str, Any]] = {}
    for index, entry in enumerate(raw_artifacts):
        if not isinstance(entry, dict):
            raise MetricsError(f"{directory.name}: artifacts[{index}] must be an object")
        relative = entry.get("path")
        expected_hash = entry.get("sha256")
        expected_bytes = entry.get("bytes")
        if not isinstance(relative, str) or relative in artifacts:
            raise MetricsError(f"{directory.name}: artifact path is missing or duplicated: {relative!r}")
        if not isinstance(expected_hash, str) or not SHA256_PATTERN.fullmatch(expected_hash):
            raise MetricsError(f"{directory.name}: artifact {relative!r} has an invalid sha256")
        if isinstance(expected_bytes, bool) or not isinstance(expected_bytes, int) or expected_bytes < 0:
            raise MetricsError(f"{directory.name}: artifact {relative!r} has invalid byte size")
        target = _safe_artifact_path(directory, relative)
        if not target.is_file():
            raise MetricsError(f"{directory.name}: registered artifact is missing: {relative}")
        if target.stat().st_size != expected_bytes:
            raise MetricsError(f"{directory.name}: artifact byte size changed: {relative}")
        if sha256_file(target) != expected_hash:
            raise MetricsError(f"{directory.name}: artifact hash changed: {relative}")
        artifacts[relative] = dict(entry)

    return VerifiedRun(directory, manifest, artifacts, created_at, completed_at)


def _gap(code: str, message: str) -> dict[str, str]:
    return {"code": code, "message": message}


def _number(value: Any, minimum: float, maximum: float | None = None) -> float | None:
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        return None
    number = float(value)
    if number < minimum or (maximum is not None and number > maximum):
        return None
    return number


def _numeric_mapping(value: Any, minimum: float, maximum: float) -> dict[str, float] | None:
    if not isinstance(value, dict) or not value:
        return None
    output: dict[str, float] = {}
    for key, raw in value.items():
        number = _number(raw, minimum, maximum)
        if not isinstance(key, str) or not key or number is None:
            return None
        output[key] = number
    return dict(sorted(output.items()))


def _summary(values: dict[str, float]) -> dict[str, Any]:
    ordered = list(values.values())
    return {
        "byCategory": values,
        "minimum": round(min(ordered), 6),
        "average": round(sum(ordered) / len(ordered), 6),
    }


def _reported_metrics(manifest: dict[str, Any], gaps: list[dict[str, str]]) -> tuple[float | None, Any, list[dict[str, str]]]:
    raw = manifest.get("metrics")
    if raw is None:
        gaps.append(_gap("DURATION_UNREPORTED", "durationMs was not reported by the run"))
        gaps.append(_gap("COST_UNREPORTED", "cost was not reported by the run"))
        return None, None, []
    if not isinstance(raw, dict):
        gaps.append(_gap("METRICS_INVALID", "run metrics must be an object"))
        return None, None, []

    duration: float | None = None
    if "durationMs" not in raw or raw.get("durationMs") is None:
        gaps.append(_gap("DURATION_UNREPORTED", "durationMs was not reported by the run"))
    else:
        duration = _number(raw.get("durationMs"), 0)
        if duration is None:
            gaps.append(_gap("DURATION_INVALID", "durationMs is not a non-negative number"))

    cost: Any = None
    if "cost" not in raw or raw.get("cost") is None:
        gaps.append(_gap("COST_UNREPORTED", "cost was not reported by the run"))
    else:
        candidate = raw.get("cost")
        amount = _number(candidate.get("amount"), 0) if isinstance(candidate, dict) else None
        currency = candidate.get("currency") if isinstance(candidate, dict) else None
        if amount is None or not isinstance(currency, str) or not currency:
            gaps.append(_gap("COST_INVALID", "cost must contain non-negative amount and currency"))
        else:
            cost = dict(candidate)
            cost["amount"] = amount

    checks: list[dict[str, str]] = []
    raw_checks = raw.get("checks", [])
    if not isinstance(raw_checks, list):
        gaps.append(_gap("CHECK_RESULTS_INVALID", "metrics.checks must be an array"))
        return duration, cost, checks
    seen: set[tuple[str, str]] = set()
    for index, item in enumerate(raw_checks):
        if not isinstance(item, dict):
            gaps.append(_gap("CHECK_RESULT_INVALID", f"metrics.checks[{index}] is not an object"))
            continue
        check_id = item.get("checkId")
        fingerprint = item.get("fingerprint")
        status = str(item.get("status") or "").upper()
        if (
            not isinstance(check_id, str)
            or not check_id
            or not isinstance(fingerprint, str)
            or not SHA256_PATTERN.fullmatch(fingerprint)
            or status not in CHECK_STATUSES
        ):
            gaps.append(_gap("CHECK_RESULT_INVALID", f"metrics.checks[{index}] lacks a valid id, fingerprint or status"))
            continue
        identity = (check_id, fingerprint)
        if identity in seen:
            gaps.append(_gap("CHECK_RESULT_DUPLICATED", f"check {check_id!r} repeats the same fingerprint in one run"))
            continue
        seen.add(identity)
        checks.append({"checkId": check_id, "fingerprint": fingerprint, "status": status})
    return duration, cost, checks


def _compatibility_fingerprint(run: VerifiedRun, gaps: list[dict[str, str]]) -> str | None:
    reference = run.manifest.get("provenance")
    if reference is None:
        gaps.append(_gap("COMPATIBILITY_UNAVAILABLE", "run has no hash-bound provenance receipt"))
        return None
    try:
        provenance = run.read_json_artifact(reference)
    except MetricsError as exc:
        gaps.append(_gap("COMPATIBILITY_UNAVAILABLE", str(exc)))
        return None
    hashes = provenance.get("hashes") if isinstance(provenance, dict) else None
    if not isinstance(hashes, dict):
        gaps.append(_gap("COMPATIBILITY_UNAVAILABLE", "provenance.hashes is unavailable"))
        return None
    dimensions = {
        key: hashes.get(key)
        for key in ("contract", "config", "rojoProject", "plugin", "visualSpec", "seed")
    }
    if any(value is None for value in dimensions.values()):
        gaps.append(_gap("COMPATIBILITY_UNAVAILABLE", "provenance lacks one or more compatibility dimensions"))
        return None
    return sha256_json(dimensions)


def _derive_run(run: VerifiedRun) -> dict[str, Any]:
    gaps: list[dict[str, str]] = []
    gate: dict[str, Any] | None = None
    gate_consistent = False
    try:
        candidate = run.read_json_artifact(run.manifest.get("gate"))
        if isinstance(candidate, dict):
            gate = candidate
        else:
            gaps.append(_gap("GATE_INVALID", "gate artifact is not an object"))
    except MetricsError as exc:
        gaps.append(_gap("GATE_UNAVAILABLE", str(exc)))

    coverage: dict[str, Any] | None = None
    quality: dict[str, Any] | None = None
    blockers: list[str] = []
    if gate is not None:
        build_matches = gate.get("buildHash") == run.manifest.get("buildId")
        gate_allowed = gate.get("releaseAllowed")
        gate_consistent = (
            gate.get("runId") == run.run_id
            and build_matches
            and isinstance(gate_allowed, bool)
            and gate_allowed == run.manifest.get("releaseAllowed")
        )
        if not gate_consistent:
            gaps.append(_gap("GATE_BINDING_MISMATCH", "gate does not bind to the manifest run, build and release result"))

        coverage_values = _numeric_mapping(gate.get("coverage"), 0, 1)
        if coverage_values is None:
            gaps.append(_gap("COVERAGE_UNAVAILABLE", "gate coverage is missing, empty or invalid"))
        else:
            coverage = _summary(coverage_values)

        quality_values = _numeric_mapping(gate.get("scores"), 0, 100)
        if quality_values is None:
            gaps.append(_gap("QUALITY_UNAVAILABLE", "gate scores are missing, empty or invalid"))
        else:
            quality = _summary(quality_values)
            visual_score = _number(gate.get("visualScore"), 0, 100)
            quality["visualScore"] = visual_score

        raw_blockers = gate.get("blockers")
        if isinstance(raw_blockers, list):
            blockers = [item for item in raw_blockers if isinstance(item, str)]

    duration_ms, cost, checks = _reported_metrics(run.manifest, gaps)
    wall_clock_ms = round((run.completed_at - run.created_at).total_seconds() * 1000, 3)
    compatibility = _compatibility_fingerprint(run, gaps)
    return {
        "runId": run.run_id,
        "manifestSha256": run.manifest_sha256,
        "createdAt": run.manifest["createdAt"],
        "completedAt": run.manifest["completedAt"],
        "status": run.manifest["status"],
        "reportedReleaseAllowed": run.manifest["releaseAllowed"],
        "gateConsistent": gate_consistent,
        "buildId": run.manifest.get("buildId"),
        "compatibilityFingerprint": compatibility,
        "metrics": {
            "coverage": coverage,
            "quality": quality,
            "durationMs": duration_ms,
            "wallClockDurationMs": wall_clock_ms,
            "cost": cost,
            "checks": checks,
        },
        "blockers": blockers,
        "regression": None,
        "dataQualityGaps": gaps,
    }


def _derive_flakiness(runs: Iterable[dict[str, Any]]) -> dict[str, Any]:
    groups: dict[tuple[str, str], list[dict[str, str]]] = {}
    for run in runs:
        for check in run["metrics"]["checks"]:
            key = (check["checkId"], check["fingerprint"])
            groups.setdefault(key, []).append({"runId": run["runId"], "status": check["status"]})

    comparable: list[dict[str, Any]] = []
    total_transitions = 0
    total_flips = 0
    for (check_id, fingerprint), samples in sorted(groups.items()):
        if len(samples) < 2:
            continue
        flips = sum(
            1
            for before, after in zip(samples, samples[1:])
            if before["status"] != after["status"]
        )
        transitions = len(samples) - 1
        total_transitions += transitions
        total_flips += flips
        comparable.append({
            "checkId": check_id,
            "fingerprint": fingerprint,
            "sampleCount": len(samples),
            "transitions": transitions,
            "flips": flips,
            "flipRate": round(flips / transitions, 6),
            "samples": samples,
        })

    if total_transitions == 0:
        return {
            "status": "UNKNOWN",
            "comparableGroups": 0,
            "transitions": 0,
            "flips": 0,
            "flipRate": None,
            "checks": [],
            "reason": "no check has two runs with an identical fingerprint",
        }
    return {
        "status": "MEASURED",
        "comparableGroups": len(comparable),
        "transitions": total_transitions,
        "flips": total_flips,
        "flipRate": round(total_flips / total_transitions, 6),
        "checks": comparable,
        "reason": None,
    }


def _mapping_delta(current: Any, baseline: Any) -> dict[str, float]:
    if not isinstance(current, dict) or not isinstance(baseline, dict):
        return {}
    shared = sorted(set(current) & set(baseline))
    return {
        key: round(float(current[key]) - float(baseline[key]), 6)
        for key in shared
        if isinstance(current[key], (int, float))
        and not isinstance(current[key], bool)
        and isinstance(baseline[key], (int, float))
        and not isinstance(baseline[key], bool)
    }


def _attach_regressions(runs: list[dict[str, Any]]) -> None:
    for index, current in enumerate(runs):
        fingerprint = current.get("compatibilityFingerprint")
        if not fingerprint:
            current["regression"] = {
                "status": "UNKNOWN",
                "baselineRunId": None,
                "reason": "current run has no compatibility fingerprint",
            }
            continue
        baseline = next(
            (
                candidate
                for candidate in reversed(runs[:index])
                if candidate.get("status") == "RELEASED"
                and candidate.get("reportedReleaseAllowed") is True
                and candidate.get("gateConsistent") is True
                and candidate.get("compatibilityFingerprint") == fingerprint
            ),
            None,
        )
        if baseline is None:
            current["regression"] = {
                "status": "UNKNOWN",
                "baselineRunId": None,
                "reason": "no earlier compatible RELEASED baseline exists",
            }
            continue

        current_coverage = (current["metrics"].get("coverage") or {}).get("byCategory")
        baseline_coverage = (baseline["metrics"].get("coverage") or {}).get("byCategory")
        current_quality = (current["metrics"].get("quality") or {}).get("byCategory")
        baseline_quality = (baseline["metrics"].get("quality") or {}).get("byCategory")
        current_blockers = set(current.get("blockers") or [])
        baseline_blockers = set(baseline.get("blockers") or [])
        current["regression"] = {
            "status": "AVAILABLE",
            "baselineRunId": baseline["runId"],
            "baselineManifestSha256": baseline["manifestSha256"],
            "compatibilityFingerprint": fingerprint,
            "coverageDelta": _mapping_delta(current_coverage, baseline_coverage),
            "qualityDelta": _mapping_delta(current_quality, baseline_quality),
            "newBlockers": sorted(current_blockers - baseline_blockers),
            "resolvedBlockers": sorted(baseline_blockers - current_blockers),
            "reason": None,
        }


def build_dashboard_index(artifacts_root: str | Path) -> dict[str, Any]:
    """Build a non-authoritative display index from verified immutable runs."""

    root = Path(artifacts_root).resolve()
    verified: list[VerifiedRun] = []
    rejected: list[dict[str, str]] = []
    if root.exists():
        for directory in sorted((item for item in root.iterdir() if item.is_dir()), key=lambda item: item.name):
            if not (directory / "run.json").is_file():
                continue
            try:
                verified.append(verify_finalized_run(directory))
            except MetricsError as exc:
                rejected.append({"runId": directory.name, "code": "RUN_REJECTED", "message": str(exc)})

    verified.sort(key=lambda item: (item.completed_at, item.run_id))
    runs = [_derive_run(item) for item in verified]
    _attach_regressions(runs)
    flakiness = _derive_flakiness(runs)
    gaps: list[dict[str, Any]] = list(rejected)
    for run in runs:
        gaps.extend({"runId": run["runId"], **gap} for gap in run["dataQualityGaps"])
    if flakiness["status"] == "UNKNOWN":
        gaps.append({"runId": None, "code": "FLAKINESS_UNKNOWN", "message": flakiness["reason"]})

    newest = runs[-1] if runs else None
    latest = (
        {"runId": newest["runId"], "manifestSha256": newest["manifestSha256"]}
        if newest is not None
        else None
    )
    return {
        "schemaVersion": 1,
        "generatedAt": _utc_timestamp(),
        "source": "verified-finalized-run-manifests-v2",
        "latest": latest,
        "runs": list(reversed(runs)),
        "flakiness": flakiness,
        "dataQuality": {
            "verifiedRuns": len(runs),
            "rejectedRuns": len(rejected),
            "gaps": gaps,
        },
    }


def verify_latest_pointer(pointer: Any, index: dict[str, Any]) -> dict[str, str]:
    if not isinstance(pointer, dict) or set(pointer) != {"runId", "manifestSha256"}:
        raise MetricsError("latest pointer must contain exactly runId and manifestSha256")
    run_id = pointer.get("runId")
    manifest_hash = pointer.get("manifestSha256")
    if not isinstance(run_id, str) or not isinstance(manifest_hash, str) or not SHA256_PATTERN.fullmatch(manifest_hash):
        raise MetricsError("latest pointer has an invalid runId or manifestSha256")
    match = next(
        (
            run
            for run in index.get("runs", [])
            if run.get("runId") == run_id and run.get("manifestSha256") == manifest_hash
        ),
        None,
    )
    if match is None:
        raise MetricsError("latest pointer does not bind to a verified run manifest")
    return {"runId": run_id, "manifestSha256": manifest_hash}


def _atomic_write_json(path: Path, payload: Any) -> Path:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.parent / f".{path.name}.{secrets.token_hex(8)}.tmp"
    encoded = (json.dumps(payload, indent=2, ensure_ascii=False) + "\n").encode("utf-8")
    try:
        with temporary.open("xb") as handle:
            handle.write(encoded)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary, path)
    finally:
        if temporary.exists():
            temporary.unlink()
    return path


def write_latest_pointer(path: str | Path, index: dict[str, Any]) -> Path:
    latest = verify_latest_pointer(index.get("latest"), index)
    return _atomic_write_json(Path(path), latest)


def load_latest_pointer(path: str | Path, index: dict[str, Any]) -> dict[str, str]:
    source = Path(path)
    try:
        pointer = json.loads(source.read_text(encoding="utf-8"))
    except (OSError, UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise MetricsError(f"cannot read latest pointer: {exc}") from exc
    return verify_latest_pointer(pointer, index)


def write_dashboard_index(
    path: str | Path,
    index: dict[str, Any],
    *,
    latest_pointer_path: str | Path | None = None,
) -> Path:
    if index.get("schemaVersion") != 1 or index.get("source") != "verified-finalized-run-manifests-v2":
        raise MetricsError("dashboard index was not produced from verified run manifests")
    target = _atomic_write_json(Path(path), index)
    if latest_pointer_path is not None and index.get("latest") is not None:
        write_latest_pointer(latest_pointer_path, index)
    return target


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        prog="python -m rqe.orchestrator.metrics",
        description="derive a display-only dashboard index from verified finalized run manifests",
    )
    parser.add_argument("artifacts_root", nargs="?", default="artifacts")
    parser.add_argument("output", nargs="?", default="apps/dashboard/data/index.json")
    parser.add_argument("--latest-pointer", help="optional atomic {runId, manifestSha256} pointer")
    args = parser.parse_args(argv)
    index = build_dashboard_index(args.artifacts_root)
    write_dashboard_index(args.output, index, latest_pointer_path=args.latest_pointer)
    print(json.dumps({
        "index": str(Path(args.output).resolve()),
        "verifiedRuns": index["dataQuality"]["verifiedRuns"],
        "rejectedRuns": index["dataQuality"]["rejectedRuns"],
        "latest": index["latest"],
    }, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
