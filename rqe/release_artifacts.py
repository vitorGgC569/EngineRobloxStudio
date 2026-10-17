"""Identity-bound producer artifacts for the one immutable release run.

The release gate accepts evidence, capture and review payloads, but producers
historically wrote their own folders (or mutable ``latest`` pointers).  This
module is the join boundary: an artifact is registered under the active
``RunArtifacts`` instance, bound to its exact build/place/spec, and only then
made available to the gate.

The assembler does not make quality policy.  It preserves raw producer output,
records integration defects, and refuses to turn an incomplete artifact into
positive evidence.
"""

from __future__ import annotations

import json
import re
from dataclasses import dataclass, field
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Callable, Iterable

from .capture import CaptureBackend, capture_set
from .hub.client import StudioBridge
from .hub.protocol import BridgeError
from .models import Evidence, SEVERITIES, VALIDATION_LEVELS
from .observe import Observation
from .project import Project
from .provenance import sha256_file, sha256_json
from .run_artifacts import RunArtifacts
from .scenario import (
    SCENARIO_ID_PATTERN,
    ScenarioResult,
    ScenarioRunner,
    load_scenario,
    scenario_document_issues,
)
from .visual_spec import VisualQualitySpec


_SHA256 = re.compile(r"^[0-9a-f]{64}$")
_PRODUCER_ID = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,95}$")


class ReleaseArtifactError(ValueError):
    pass


def _now() -> str:
    return datetime.now(timezone.utc).isoformat()


def _require_sha256(value: str, label: str) -> None:
    if not _SHA256.fullmatch(value):
        raise ReleaseArtifactError(f"{label} must be a lowercase SHA-256")


def _safe_inside(root: Path, path: Path, label: str) -> Path:
    root = root.resolve()
    resolved = path.resolve()
    try:
        resolved.relative_to(root)
    except ValueError as exc:
        raise ReleaseArtifactError(f"{label} escapes {root}") from exc
    if resolved.is_symlink():
        raise ReleaseArtifactError(f"{label} must not be a symlink")
    return resolved


def _binding_issues(scenario: dict[str, Any]) -> list[str]:
    issues: list[str] = []
    for index, binding in enumerate(scenario.get("releaseEvidence", [])):
        if not isinstance(binding, dict):
            continue
        if binding.get("severity") not in SEVERITIES:
            issues.append(
                f"releaseEvidence[{index}].severity must be one of {sorted(SEVERITIES)}"
            )
        minimum = binding.get("minimumValidationLevel", "E2E_VALIDATED")
        if minimum not in VALIDATION_LEVELS or minimum == "NOT_VALIDATED":
            issues.append(
                f"releaseEvidence[{index}].minimumValidationLevel must be positive"
            )
    return issues


@dataclass
class ProducerRecord:
    producer_id: str
    status: str
    validation_level: str
    artifact_paths: tuple[str, ...]
    evidence_ids: tuple[str, ...] = ()
    issues: tuple[str, ...] = ()

    def __post_init__(self) -> None:
        if not _PRODUCER_ID.fullmatch(self.producer_id):
            raise ReleaseArtifactError(f"unsafe producer id: {self.producer_id!r}")
        if self.status not in {"COMPLETE", "BLOCKED"}:
            raise ReleaseArtifactError(f"invalid producer status: {self.status!r}")
        if self.validation_level not in VALIDATION_LEVELS:
            raise ReleaseArtifactError(
                f"invalid producer validation level: {self.validation_level!r}"
            )
        if len(self.artifact_paths) != len(set(self.artifact_paths)):
            raise ReleaseArtifactError(f"producer {self.producer_id} repeats an artifact path")
        if len(self.evidence_ids) != len(set(self.evidence_ids)):
            raise ReleaseArtifactError(f"producer {self.producer_id} repeats an evidence id")

    def to_dict(self) -> dict[str, Any]:
        return {
            "producerId": self.producer_id,
            "status": self.status,
            "validationLevel": self.validation_level,
            "artifacts": list(self.artifact_paths),
            "evidenceIds": list(self.evidence_ids),
            "issues": list(self.issues),
        }


@dataclass
class RuntimeProducerOutput:
    """Provider-neutral hook result, including the future quality snapshot."""

    producer_id: str
    payload: dict[str, Any]
    evidence: list[Evidence] = field(default_factory=list)
    command_errors: list[dict[str, Any]] = field(default_factory=list)
    validation_level: str = "NOT_VALIDATED"
    status: str = "COMPLETE"


RuntimeProducerHook = Callable[[StudioBridge], RuntimeProducerOutput]


class ReleaseArtifactAssembler:
    """Adopt every producer into one hash-bound, concurrency-safe run."""

    def __init__(
        self,
        run: RunArtifacts,
        *,
        project_root: Path,
        build_hash: str,
        place_hash: str,
        spec_hash: str,
    ) -> None:
        _require_sha256(build_hash, "build_hash")
        _require_sha256(place_hash, "place_hash")
        _require_sha256(spec_hash, "spec_hash")
        self.run = run
        self.project_root = project_root.resolve()
        self.build_hash = build_hash
        self.place_hash = place_hash
        self.spec_hash = spec_hash
        self.evidence: list[Evidence] = []
        self.command_errors: list[dict[str, Any]] = []
        self.records: list[ProducerRecord] = []
        self.capture_manifest: dict[str, Any] | None = None
        self.visual_review: dict[str, Any] | None = None
        self._capture_recorded = False
        self._index_written = False

    def _stamp(self, evidence: Iterable[Evidence], observed_at: str | None = None) -> list[Evidence]:
        stamped: list[Evidence] = []
        timestamp = observed_at or _now()
        existing_ids = {item.id for item in self.evidence}
        for item in evidence:
            if item.id in existing_ids:
                raise ReleaseArtifactError(f"duplicate release evidence id: {item.id}")
            if item.run_id not in (None, self.run.run_id):
                raise ReleaseArtifactError(
                    f"evidence {item.id!r} belongs to another run: {item.run_id!r}"
                )
            if item.build_hash not in (None, self.build_hash):
                raise ReleaseArtifactError(
                    f"evidence {item.id!r} belongs to another build"
                )
            item.run_id = self.run.run_id
            item.build_hash = self.build_hash
            item.observed_at = item.observed_at or timestamp
            if item.coverage is None:
                item.coverage = 0.0 if item.truncated or not item.conclusive else 1.0
            stamped.append(item)
            existing_ids.add(item.id)
        self.evidence.extend(stamped)
        return stamped

    def record_observation(self, observation: Observation) -> list[Evidence]:
        if observation.run_id != self.run.run_id:
            raise ReleaseArtifactError(
                f"observation belongs to {observation.run_id!r}, expected {self.run.run_id!r}"
            )
        payload = observation.to_dict()
        state_path = self.run.write_json(
            "runtime-state/observation.json",
            payload,
            producer_task_id="measure.observation",
        )
        server_path = self.run.write_json(
            "logs/studio-output.json",
            observation.measurements.get("logs", {}),
            producer_task_id="measure.server-logs",
        )
        client_path = self.run.write_json(
            "logs/client-output.json",
            observation.measurements.get("clientLogs", {}),
            producer_task_id="measure.client-logs",
        )
        metrics_path = self.run.write_json(
            "metrics/runtime.json",
            observation.measurements.get("runtime", {}),
            producer_task_id="measure.runtime",
        )
        # The observation's early server/client log facets stay in the raw
        # artifact for diagnosis.  Release evidence is emitted only by the
        # post-scenario collector, where both channels are combined so one
        # clean server stream cannot mask an unavailable client stream.
        stamped = self._stamp(
            item for item in observation.evidence if item.probe != "runtime_error"
        )
        self.command_errors.extend(observation.errors)
        issues = tuple(
            f"{item.get('method', 'unknown')}: {item.get('error')}"
            for item in observation.errors
        )
        self.records.append(ProducerRecord(
            producer_id="runtime.observation",
            status="BLOCKED" if issues else "COMPLETE",
            validation_level=observation.validation_level,
            artifact_paths=tuple(
                path.relative_to(self.run.directory).as_posix()
                for path in (state_path, server_path, client_path, metrics_path)
            ),
            evidence_ids=tuple(item.id for item in stamped),
            issues=issues,
        ))
        return stamped

    def record_external_producer(self, output: RuntimeProducerOutput) -> list[Evidence]:
        """Generic same-session hook used by quality and future producers."""

        if not _PRODUCER_ID.fullmatch(output.producer_id):
            raise ReleaseArtifactError(f"unsafe producer id: {output.producer_id!r}")
        if output.validation_level not in VALIDATION_LEVELS:
            raise ReleaseArtifactError(
                f"invalid producer validation level: {output.validation_level!r}"
            )
        path = self.run.write_json(
            f"producers/{output.producer_id}.json",
            {
                "schemaVersion": 1,
                "producerId": output.producer_id,
                "runId": self.run.run_id,
                "buildHash": self.build_hash,
                "placeHash": self.place_hash,
                "specHash": self.spec_hash,
                "observedAt": _now(),
                "status": output.status,
                "validationLevel": output.validation_level,
                "payload": output.payload,
                "commandErrors": output.command_errors,
            },
            producer_task_id=output.producer_id,
        )
        stamped = self._stamp(output.evidence)
        self.command_errors.extend(output.command_errors)
        issues = tuple(
            f"{item.get('code') or item.get('method') or 'producer-error'}: "
            f"{item.get('message') or item.get('error')}"
            for item in output.command_errors
        )
        self.records.append(ProducerRecord(
            output.producer_id,
            "BLOCKED" if issues or output.status != "COMPLETE" else "COMPLETE",
            output.validation_level,
            (path.relative_to(self.run.directory).as_posix(),),
            tuple(item.id for item in stamped),
            issues,
        ))
        return stamped

    def record_quality_snapshot(self, measurement: Any) -> list[Evidence]:
        """Persist the quality adapter's raw measurement and separate receipt."""

        if measurement.run_id != self.run.run_id:
            raise ReleaseArtifactError("quality snapshot belongs to another run")
        if measurement.build_hash != self.build_hash:
            raise ReleaseArtifactError("quality snapshot belongs to another build")
        if not isinstance(measurement.session_id, str) or not measurement.session_id:
            raise ReleaseArtifactError("quality snapshot has no pinned session")
        if sha256_json(measurement.snapshot) != measurement.snapshot_sha256:
            raise ReleaseArtifactError("quality snapshot hash receipt is invalid")
        snapshot_path = self.run.write_json(
            "runtime-state/quality-snapshot.json",
            measurement.snapshot,
            producer_task_id="quality.snapshot",
        )
        receipt = measurement.receipt()
        receipt["snapshotArtifact"] = snapshot_path.relative_to(self.run.directory).as_posix()
        receipt["placeHash"] = self.place_hash
        receipt["specHash"] = self.spec_hash
        receipt_path = self.run.write_json(
            "runtime-state/quality-snapshot-receipt.json",
            receipt,
            producer_task_id="quality.snapshot",
        )
        stamped = self._stamp(measurement.evidence, str(measurement.snapshot.get("capturedAt") or _now()))
        issues: list[str] = []
        if receipt.get("status") != "COMPLETE" or receipt.get("conclusive") is not True:
            issues.append("quality snapshot is inconclusive or truncated")
            self.command_errors.append({
                "code": "E_QUALITY_SNAPSHOT_INCONCLUSIVE",
                "message": issues[-1],
                "receipt": receipt_path.relative_to(self.run.directory).as_posix(),
            })
        self.records.append(ProducerRecord(
            "quality.snapshot",
            "BLOCKED" if issues else "COMPLETE",
            "RUNTIME_VALIDATED",
            (
                snapshot_path.relative_to(self.run.directory).as_posix(),
                receipt_path.relative_to(self.run.directory).as_posix(),
            ),
            tuple(item.id for item in stamped),
            tuple(issues),
        ))
        return stamped

    def execute_runtime_hooks(
        self,
        bridge: StudioBridge,
        hooks: Iterable[RuntimeProducerHook],
    ) -> None:
        """Execute registered producers while the exact session is still pinned."""

        for hook in hooks:
            try:
                output = hook(bridge)
                if not isinstance(output, RuntimeProducerOutput):
                    raise TypeError("runtime producer hook returned the wrong type")
                self.record_external_producer(output)
            except Exception as exc:
                producer_id = getattr(hook, "producer_id", None) or getattr(hook, "__name__", "runtime-hook")
                producer_id = str(producer_id)
                if not _PRODUCER_ID.fullmatch(producer_id):
                    producer_id = "runtime-hook"
                error = {
                    "code": "E_RUNTIME_PRODUCER",
                    "producerId": producer_id,
                    "type": type(exc).__name__,
                    "message": str(exc),
                }
                self.record_external_producer(RuntimeProducerOutput(
                    producer_id=producer_id,
                    payload={},
                    command_errors=[error],
                    status="BLOCKED",
                ))

    def record_scenario(
        self,
        scenario_path: Path,
        *,
        result: ScenarioResult | None,
        session_id: str,
        place_name: str,
        blocked_reason: str | None = None,
        state_id: str | None = None,
    ) -> list[Evidence]:
        path = _safe_inside(self.project_root, scenario_path, "scenario path")
        if not path.is_file():
            raise ReleaseArtifactError(f"scenario does not exist: {path}")
        scenario = load_scenario(path)
        issues = scenario_document_issues(scenario) + _binding_issues(scenario)
        identifier = str(scenario.get("id") or scenario.get("scenario") or "invalid")
        if not SCENARIO_ID_PATTERN.fullmatch(identifier):
            identifier = "invalid-scenario"
        if state_id is not None and not SCENARIO_ID_PATTERN.fullmatch(state_id):
            raise ReleaseArtifactError(f"unsafe evaluation state id: {state_id!r}")
        receipt_name = f"{state_id}--{identifier}" if state_id else identifier
        if len(receipt_name) > 80:
            receipt_name = f"scenario-{sha256_json({'state': state_id, 'scenario': identifier})[:24]}"
        producer_id = (
            f"scenario.{state_id}.{identifier}" if state_id else f"scenario.{identifier}"
        )
        if not _PRODUCER_ID.fullmatch(producer_id):
            producer_id = f"scenario.{sha256_json({'state': state_id, 'scenario': identifier})[:24]}"
        if blocked_reason:
            issues.append(blocked_reason)
        if result is not None and result.scenario != identifier:
            issues.append(
                f"runner returned scenario {result.scenario!r}, expected {identifier!r}"
            )
        declared_steps = len(scenario.get("steps", [])) if isinstance(scenario.get("steps"), list) else 0
        executed_steps = (
            sum(1 for item in result.steps if item.index > 0)
            if result is not None
            else 0
        )
        coverage = executed_steps / declared_steps if declared_steps else 0.0
        validation_level = result.validation_level if result is not None else "NOT_VALIDATED"
        command_errors = list(result.command_errors) if result is not None else []
        self.command_errors.extend(command_errors)
        if command_errors:
            issues.extend(
                f"bridge command failed at scenario step {item.get('step')}: {item.get('error')}"
                for item in command_errors
            )
        if result is None or validation_level == "NOT_VALIDATED":
            self.command_errors.append({
                "code": "E_SCENARIO_NOT_EXECUTED",
                "scenarioId": identifier,
                "stateId": state_id,
                "message": blocked_reason or "scenario produced no positive validation level",
            })
        conclusive = bool(
            result is not None
            and not issues
            and session_id
            and validation_level != "NOT_VALIDATED"
        )
        receipt = {
            "$schema": "https://rqe.local/schemas/scenario-result-receipt.v1.schema.json",
            "schemaVersion": 1,
            "producerId": "scenario.runner",
            "scenarioId": identifier,
            "stateId": state_id,
            "runId": self.run.run_id,
            "buildHash": self.build_hash,
            "placeHash": self.place_hash,
            "place": place_name,
            "sessionId": session_id,
            "source": "studio-scenario",
            "observedAt": _now(),
            "validationLevel": validation_level,
            "coverage": round(coverage, 6),
            "conclusive": conclusive,
            "status": (
                "BLOCKED" if result is None or issues else "COMPLETE"
            ),
            "outcome": result.status if result is not None else "NOT_RUN",
            "scenarioSpec": {
                "path": path.relative_to(self.project_root).as_posix(),
                "sha256": sha256_file(path),
            },
            "declaredSteps": declared_steps,
            "executedSteps": executed_steps,
            "issues": issues,
            "result": result.to_dict() if result is not None else None,
        }
        receipt_path = self.run.write_json(
            f"scenarios/{receipt_name}.json",
            receipt,
            producer_task_id="scenario.runner",
        )

        produced: list[Evidence] = []
        if result is not None:
            for binding in scenario.get("releaseEvidence", []):
                if not isinstance(binding, dict):
                    continue
                try:
                    item = Evidence(
                        id=str(binding["id"]),
                        probe=str(binding["probe"]),
                        category=str(binding["category"]),
                        status=result.status,
                        severity=str(binding["severity"]),
                        message=(
                            f"scenario {identifier} completed with {result.status}"
                        ),
                        source="studio-scenario",
                        validation_level=validation_level,
                        details={
                            "scenarioId": identifier,
                            "receipt": receipt_path.relative_to(self.run.directory).as_posix(),
                            "scenarioSpecSha256": receipt["scenarioSpec"]["sha256"],
                            "declaredSteps": declared_steps,
                            "executedSteps": executed_steps,
                            "issues": issues,
                        },
                        coverage=coverage,
                        conclusive=conclusive,
                    )
                except (KeyError, ValueError) as exc:
                    issues.append(f"invalid release evidence binding: {exc}")
                    continue
                produced.append(item)
        stamped = self._stamp(produced, receipt["observedAt"])
        self.records.append(ProducerRecord(
            producer_id=producer_id,
            status=str(receipt["status"]),
            validation_level=validation_level,
            artifact_paths=(receipt_path.relative_to(self.run.directory).as_posix(),),
            evidence_ids=tuple(item.id for item in stamped),
            issues=tuple(issues),
        ))
        return stamped

    def record_capture(
        self,
        relative_directory: str | Path,
        manifest: dict[str, Any],
        *,
        state_outcomes: dict[str, str] | None = None,
        viewpoint_states: dict[str, str] | None = None,
    ) -> list[Evidence]:
        if self._capture_recorded:
            raise ReleaseArtifactError("a release run can contain only one canonical capture set")
        self._capture_recorded = True
        directory = _safe_inside(
            self.run.directory,
            self.run.directory / relative_directory,
            "capture directory",
        )
        issues: list[str] = []
        try:
            registered = self.run.register_tree(
                directory.relative_to(self.run.directory),
                producer_task_id="capture.studio",
            )
        except (FileNotFoundError, ValueError) as exc:
            registered = []
            issues.append(str(exc))

        manifest_path = directory / "manifest.json"
        if not manifest_path.is_file():
            issues.append("capture manifest.json is missing")
        else:
            try:
                persisted = json.loads(manifest_path.read_text(encoding="utf-8"))
                if persisted != manifest:
                    issues.append("capture manifest argument differs from the persisted artifact")
            except (OSError, json.JSONDecodeError) as exc:
                issues.append(f"capture manifest cannot be decoded: {exc}")
        for field, expected in (
            ("runId", self.run.run_id),
            ("buildHash", self.build_hash),
            ("placeHash", self.place_hash),
            ("specHash", self.spec_hash),
        ):
            if manifest.get(field) != expected:
                issues.append(f"capture {field} does not match the active release")
        if manifest.get("trustworthy") is not True:
            issues.append("capture producer did not mark the set trustworthy")
        if manifest.get("failures") not in ([], None):
            issues.append("capture producer reported failures")
        if manifest.get("coverage") not in (1, 1.0):
            issues.append("capture coverage is incomplete")
        session_id = manifest.get("sessionId")
        if not isinstance(session_id, str) or not session_id:
            issues.append("capture sessionId is missing")
        captured_at = manifest.get("capturedAt")
        if not isinstance(captured_at, str) or not captured_at:
            issues.append("capture capturedAt is missing")
        required_viewpoints = manifest.get("requiredViewpoints")
        captured_viewpoints = manifest.get("capturedRequiredViewpoints")
        if (
            not isinstance(required_viewpoints, list)
            or not required_viewpoints
            or not isinstance(captured_viewpoints, list)
            or set(required_viewpoints) != set(captured_viewpoints)
        ):
            issues.append("capture required viewpoint coverage is not exact")

        shots = manifest.get("shots")
        if not isinstance(shots, list) or not shots:
            issues.append("capture set contains no shots")
            shots = []
        for shot in shots:
            if not isinstance(shot, dict):
                issues.append("capture shot has invalid shape")
                continue
            name = str(shot.get("file") or "")
            shot_path = directory / name
            try:
                shot_path = _safe_inside(directory, shot_path, "capture shot")
            except ReleaseArtifactError as exc:
                issues.append(str(exc))
                continue
            if not shot_path.is_file():
                issues.append(f"capture file is missing: {name}")
                continue
            if shot.get("sha256") != sha256_file(shot_path):
                issues.append(f"capture file hash differs from manifest: {name}")
            if shot.get("bytes") != shot_path.stat().st_size:
                issues.append(f"capture file size differs from manifest: {name}")
            if shot_path.suffix.lower() != ".png":
                issues.append(f"capture file is not a PNG artifact: {name}")
            if shot.get("trustworthy") is not True or shot.get("integrityIssues"):
                issues.append(f"capture shot is untrustworthy: {shot.get('id')}")
            for field, expected in (
                ("runId", self.run.run_id),
                ("buildHash", self.build_hash),
                ("placeHash", self.place_hash),
                ("specHash", self.spec_hash),
                ("sessionId", session_id),
            ):
                if shot.get(field) != expected:
                    issues.append(f"capture shot {shot.get('id')} has mismatched {field}")
            camera = shot.get("camera") if isinstance(shot.get("camera"), dict) else {}
            if not isinstance(camera.get("before"), dict) or not isinstance(camera.get("after"), dict):
                issues.append(f"capture shot has incomplete camera receipt: {shot.get('id')}")
            device = shot.get("device") if isinstance(shot.get("device"), dict) else {}
            if device.get("requested") is not None and device.get("verified") is not True:
                issues.append(f"capture device is unverified: {shot.get('id')}")
            resolution = shot.get("resolution") if isinstance(shot.get("resolution"), dict) else {}
            requested = resolution.get("requested")
            if requested is not None and resolution.get("measuredViewport") != requested:
                issues.append(f"capture viewport is unverified: {shot.get('id')}")

        if state_outcomes is not None and viewpoint_states is not None:
            for viewpoint in manifest.get("requiredViewpoints", []):
                state = viewpoint_states.get(str(viewpoint))
                if state is None or state_outcomes.get(state) != "PASS":
                    issues.append(
                        f"capture viewpoint {viewpoint!r} is not linked to a PASS state scenario"
                    )

        integration_path = self.run.write_json(
            "producers/capture.integration.json",
            {
                "schemaVersion": 1,
                "producerId": "capture.studio",
                "runId": self.run.run_id,
                "buildHash": self.build_hash,
                "placeHash": self.place_hash,
                "specHash": self.spec_hash,
                "manifestSha256": sha256_file(manifest_path) if manifest_path.is_file() else None,
                "registeredArtifacts": [
                    path.relative_to(self.run.directory).as_posix() for path in registered
                ],
                "status": "BLOCKED" if issues else "COMPLETE",
                "issues": list(dict.fromkeys(issues)),
            },
            producer_task_id="capture.integration",
        )
        issues = list(dict.fromkeys(issues))
        produced: list[Evidence] = []
        if not issues:
            self.capture_manifest = manifest
            observed_at = str(manifest.get("capturedAt") or _now())
            for shot in shots:
                viewpoint = str(shot["id"])
                produced.append(Evidence(
                    id=f"release.capture.{viewpoint}",
                    probe=f"visual.viewpoint.{viewpoint}.capture",
                    category="visual",
                    status="PASS",
                    severity="critical",
                    message=f"viewpoint {viewpoint} was captured with verified provenance",
                    source="studio-capture",
                    validation_level="VISUALLY_VALIDATED",
                    details={
                        "manifest": manifest_path.relative_to(self.run.directory).as_posix(),
                        "integration": integration_path.relative_to(self.run.directory).as_posix(),
                        "shot": shot,
                    },
                    observed_at=observed_at,
                    coverage=1.0,
                ))
        else:
            self.command_errors.append({
                "code": "E_CAPTURE_INTEGRITY",
                "message": "capture artifacts were preserved but rejected from the release gate",
                "issues": issues,
            })
        stamped = self._stamp(produced)
        self.records.append(ProducerRecord(
            producer_id="capture.studio",
            status="BLOCKED" if issues else "COMPLETE",
            validation_level="VISUALLY_VALIDATED" if not issues else "NOT_VALIDATED",
            artifact_paths=tuple(
                [path.relative_to(self.run.directory).as_posix() for path in registered]
                + [integration_path.relative_to(self.run.directory).as_posix()]
            ),
            evidence_ids=tuple(item.id for item in stamped),
            issues=tuple(issues),
        ))
        return stamped

    def record_visual_review(self, payload: dict[str, Any]) -> None:
        """Persist a provider result; the release gate performs rubric checks."""

        path = self.run.write_json(
            "visual-review/review.json",
            payload,
            producer_task_id="visual-review",
        )
        issues: list[str] = []
        for field, expected in (
            ("runId", self.run.run_id),
            ("buildHash", self.build_hash),
            ("placeHash", self.place_hash),
            ("specHash", self.spec_hash),
        ):
            if payload.get(field) != expected:
                issues.append(f"visual review {field} does not match the active release")
        if self.capture_manifest is None:
            issues.append("visual review has no accepted capture set")
        elif payload.get("captureManifestSha256") != sha256_json(self.capture_manifest):
            # visual_review historically hashes canonical JSON while the gate
            # hashes the persisted indented artifact.  Preserve that mismatch
            # as a blocker; callers cannot relabel an unbound review.
            encoded = json.dumps(self.capture_manifest, indent=2, ensure_ascii=False) + "\n"
            import hashlib

            actual = hashlib.sha256(encoded.encode("utf-8")).hexdigest()
            if payload.get("captureManifestSha256") != actual:
                issues.append("visual review is not hash-bound to the capture manifest")
        if not issues:
            self.visual_review = payload
        self.records.append(ProducerRecord(
            "visual-review",
            "BLOCKED" if issues else "COMPLETE",
            str(payload.get("validationLevel") or "NOT_VALIDATED"),
            (path.relative_to(self.run.directory).as_posix(),),
            (),
            tuple(issues),
        ))

    def write_index(self) -> Path:
        if self._index_written:
            raise ReleaseArtifactError("producer index was already written")
        self._index_written = True
        return self.run.write_json(
            "producers/index.json",
            {
                "$schema": "https://rqe.local/schemas/release-producer-index.v1.schema.json",
                "schemaVersion": 1,
                "runId": self.run.run_id,
                "buildHash": self.build_hash,
                "placeHash": self.place_hash,
                "specHash": self.spec_hash,
                "generatedAt": _now(),
                "producers": [item.to_dict() for item in self.records],
                "evidenceIds": [item.id for item in self.evidence],
                "commandErrorCount": len(self.command_errors),
            },
            producer_task_id="release.assembler",
        )


def _selector_results(
    bridge: StudioBridge,
    selector: dict[str, Any],
    *,
    expected_session: str,
) -> tuple[list[dict[str, Any]], list[dict[str, Any]]]:
    params: dict[str, Any] = {"root": "game.Workspace", "limit": 256}
    for key in ("tag", "namePattern"):
        if key in selector:
            params[key] = selector[key]
    if "tag" not in params and "namePattern" not in params:
        return [], [{"code": "E_SELECTOR", "message": "selector has no executable tag or namePattern"}]
    errors: list[dict[str, Any]] = []
    try:
        response = bridge.call_response("dm.find", params, timeout=30)
        result = response.unwrap()
    except BridgeError as exc:
        return [], [{"code": exc.code, "message": exc.message, "details": exc.details}]
    if response.session != expected_session:
        return [], [{"code": "E_SESSION_MISMATCH", "message": "selector resolved on another session"}]
    if not isinstance(result, dict):
        return [], [{"code": "E_SELECTOR", "message": "dm.find returned no structured result"}]
    if result.get("truncated") is True:
        errors.append({"code": "E_TRUNCATED", "message": "landmark selector result was truncated"})
    candidates = [item for item in result.get("results", []) if isinstance(item, dict)]
    expected_attributes = selector.get("attributeEquals")
    if isinstance(expected_attributes, dict) and expected_attributes:
        filtered: list[dict[str, Any]] = []
        for candidate in candidates:
            ref = candidate.get("ref")
            target = f"ref:{ref}" if ref else candidate.get("path")
            try:
                props_response = bridge.call_response(
                    "dm.properties", {"path": target, "properties": []}, timeout=20
                )
                props = props_response.unwrap()
            except BridgeError as exc:
                errors.append({
                    "code": exc.code,
                    "message": exc.message,
                    "candidate": candidate.get("path"),
                })
                continue
            if props_response.session != expected_session or not isinstance(props, dict):
                errors.append({
                    "code": "E_SESSION_MISMATCH",
                    "message": "landmark attributes came from another session",
                    "candidate": candidate.get("path"),
                })
                continue
            attributes = props.get("attributes") or {}
            if all(attributes.get(key) == value for key, value in expected_attributes.items()):
                filtered.append(candidate)
        candidates = filtered
    return candidates, errors


def compile_visual_capture_viewpoints(
    bridge: StudioBridge,
    visual_spec: VisualQualitySpec,
    *,
    expected_session: str,
) -> tuple[list[dict[str, Any]], list[dict[str, Any]]]:
    """Resolve semantic landmark selectors to session-scoped refs."""

    compiled: list[dict[str, Any]] = []
    errors: list[dict[str, Any]] = []
    required = {
        str(name)
        for state in visual_spec.data.get("evaluationStates", {}).values()
        for name in state.get("requiredViewpoints", [])
    }
    for name, viewpoint in visual_spec.data.get("viewpoints", {}).items():
        landmark_id = viewpoint.get("landmark")
        landmark = visual_spec.data.get("landmarks", {}).get(landmark_id, {})
        candidates, selector_errors = _selector_results(
            bridge,
            landmark.get("selector") or {},
            expected_session=expected_session,
        )
        errors.extend({**item, "viewpoint": name, "landmark": landmark_id} for item in selector_errors)
        if len(candidates) != 1:
            errors.append({
                "code": "E_LANDMARK_AMBIGUOUS",
                "message": f"viewpoint requires exactly one landmark, measured {len(candidates)}",
                "viewpoint": name,
                "landmark": landmark_id,
            })
            continue
        candidate = candidates[0]
        target = f"ref:{candidate['ref']}" if candidate.get("ref") else candidate.get("path")
        compiled.append({
            "name": name,
            "target": target,
            "required": name in required,
            "state": viewpoint.get("state"),
            "device": viewpoint.get("device"),
            "resolution": viewpoint.get("resolution"),
            "camera": viewpoint.get("camera"),
            "settleSeconds": 0.8,
        })
    return compiled, errors


def execute_declared_scenarios(
    assembler: ReleaseArtifactAssembler,
    bridge: StudioBridge,
    visual_spec: VisualQualitySpec,
    *,
    session_id: str,
    context: str,
    place_name: str,
    reset_session: Any | None = None,
    additional_scenarios: list[str] | None = None,
) -> dict[str, str]:
    """Run each evaluation-state scenario or preserve why it could not run."""

    outcomes: dict[str, str] = {}
    targets: list[tuple[str | None, Path]] = [
        (str(state_id), assembler.project_root / str(state.get("scenario") or ""))
        for state_id, state in visual_spec.data.get("evaluationStates", {}).items()
    ]
    targets.extend(
        (None, assembler.project_root / str(relative))
        for relative in (additional_scenarios or [])
        if isinstance(relative, str) and relative.strip()
    )
    for state_id, scenario_path in targets:
        try:
            scenario = load_scenario(scenario_path)
            requires = scenario.get("requires") if isinstance(scenario, dict) else {}
            if isinstance(requires, dict) and requires.get("playSession") is True and context not in {"server", "client"}:
                assembler.record_scenario(
                    scenario_path,
                    result=None,
                    session_id=session_id,
                    place_name=place_name,
                    blocked_reason=(
                        f"scenario requires a Play Solo player; pinned Studio context is {context!r}"
                    ),
                    state_id=state_id,
                )
                outcome_key = state_id or f"scenario:{scenario_path.stem}"
                outcomes[outcome_key] = "BLOCKED"
                continue
            result = ScenarioRunner(bridge, reset_session=reset_session).run(scenario)
            recorded_session = str(getattr(bridge, "pinned_session", None) or session_id)
            assembler.record_scenario(
                scenario_path,
                result=result,
                session_id=recorded_session,
                place_name=place_name,
                state_id=state_id,
            )
            outcome_key = state_id or f"scenario:{result.scenario}"
            outcomes[outcome_key] = result.status
        except Exception as exc:
            try:
                assembler.record_scenario(
                    scenario_path,
                    result=None,
                    session_id=str(getattr(bridge, "pinned_session", None) or session_id),
                    place_name=place_name,
                    blocked_reason=f"{type(exc).__name__}: {exc}",
                    state_id=state_id,
                )
            except Exception as record_exc:
                assembler.command_errors.append({
                    "code": "E_SCENARIO_ARTIFACT",
                    "stateId": state_id,
                    "message": f"{type(record_exc).__name__}: {record_exc}",
                })
            outcome_key = state_id or f"scenario:{scenario_path.stem}"
            outcomes[outcome_key] = "BLOCKED"
    return outcomes


def execute_quality_snapshot(
    assembler: ReleaseArtifactAssembler,
    bridge: StudioBridge,
    project: Project,
    visual_spec: VisualQualitySpec,
    *,
    expected_session: str,
) -> None:
    """Run the typed raw snapshot adapter before the owning run is stopped."""

    try:
        from .quality_snapshot import measure_quality_snapshot

        measurement = measure_quality_snapshot(
            bridge,
            project,
            visual_spec,
            run_id=assembler.run.run_id,
            build_hash=assembler.build_hash,
            expected_session=expected_session,
        )
        assembler.record_quality_snapshot(measurement)
    except Exception as exc:
        assembler.record_external_producer(RuntimeProducerOutput(
            producer_id="quality.snapshot-error",
            payload={
                "expectedSession": expected_session,
                "type": type(exc).__name__,
                "message": str(exc),
            },
            command_errors=[{
                "code": "E_QUALITY_SNAPSHOT",
                "type": type(exc).__name__,
                "message": str(exc),
            }],
            status="BLOCKED",
        ))


def execute_post_scenario_logs(
    assembler: ReleaseArtifactAssembler,
    bridge: StudioBridge,
    *,
    expected_session: str,
) -> None:
    """Read both Output histories after gameplay/capture side effects."""

    payload: dict[str, Any] = {}
    facets: list[Evidence] = []
    errors: list[dict[str, Any]] = []
    for method, key, evidence_id, label in (
        ("log.tail", "server", "runtime.console_errors.post_scenarios", "Studio/server"),
        ("client.logs", "client", "runtime.client_errors.post_scenarios", "active player client"),
    ):
        try:
            response = bridge.call_response(method, {"limit": 400}, timeout=30)
            result = response.unwrap()
            if response.session != expected_session:
                raise ReleaseArtifactError(
                    f"{method} answered from {response.session!r}, expected {expected_session!r}"
                )
            if response.context not in {"run", "server", "client"}:
                raise ReleaseArtifactError(f"{method} answered from non-running context {response.context!r}")
            if not isinstance(result, dict):
                raise ReleaseArtifactError(f"{method} returned no structured log history")
            payload[key] = result
            available = result.get("available") is True
            counts = result.get("counts") if isinstance(result.get("counts"), dict) else {}
            error_count = int(counts.get("error", 0)) if available else 0
            error_entries = [
                item for item in result.get("entries", [])
                if isinstance(item, dict) and item.get("severity") == "error"
            ]
            truncated = bool(available and error_count > len(error_entries))
            facets.append(Evidence(
                id=evidence_id,
                probe="runtime_error",
                category="runtime",
                status=(
                    "PASS" if available and error_count == 0
                    else "FAIL" if available
                    else "WARN"
                ),
                severity="critical",
                message=(
                    f"{error_count} error line(s) in the {label} output after scenarios"
                    if available
                    else f"{label} output is unavailable after scenarios"
                ),
                source="studio-bridge",
                validation_level="RUNTIME_VALIDATED",
                details={
                    "available": available,
                    "counts": counts,
                    "entries": error_entries[:25],
                    "reason": result.get("reason"),
                    "phase": "post-scenarios-and-capture",
                },
                coverage=1.0 if available and not truncated else 0.0,
                conclusive=available and not truncated,
                truncated=truncated,
            ))
        except Exception as exc:
            error = {
                "code": "E_POST_SCENARIO_LOGS",
                "method": method,
                "type": type(exc).__name__,
                "message": str(exc),
            }
            errors.append(error)
            payload[key] = {"available": False, "error": error}

    by_id = {item.id: item for item in facets}
    required_ids = {
        "runtime.console_errors.post_scenarios",
        "runtime.client_errors.post_scenarios",
    }
    complete = required_ids.issubset(by_id)
    any_failure = any(item.status == "FAIL" for item in facets)
    all_pass = complete and all(item.status == "PASS" for item in facets)
    combined = Evidence(
        id="runtime.errors.post_scenarios",
        probe="runtime_error",
        category="runtime",
        status="FAIL" if any_failure else "PASS" if all_pass else "WARN",
        severity="critical",
        message=(
            "server and client outputs are clean after all release actions"
            if all_pass
            else "server/client output did not conclusively remain clean after all release actions"
        ),
        source="studio-bridge",
        validation_level="RUNTIME_VALIDATED",
        details={
            "phase": "post-scenarios-and-capture",
            "facets": [item.to_dict() for item in facets],
            "missingFacets": sorted(required_ids - set(by_id)),
        },
        coverage=1.0 if all_pass or any_failure and complete else 0.0,
        conclusive=complete and all(item.conclusive for item in facets),
        truncated=any(item.truncated for item in facets),
    )
    assembler.record_external_producer(RuntimeProducerOutput(
        producer_id="logs.post-scenarios",
        payload=payload,
        evidence=[combined],
        command_errors=errors,
        validation_level="RUNTIME_VALIDATED" if facets else "NOT_VALIDATED",
        status="COMPLETE" if not errors else "BLOCKED",
    ))


def execute_visual_capture(
    assembler: ReleaseArtifactAssembler,
    bridge: StudioBridge,
    visual_spec: VisualQualitySpec,
    *,
    build_path: Path,
    expected_place: str,
    session_id: str,
    state_outcomes: dict[str, str],
    backend: CaptureBackend | None = None,
    expected_hwnd: int | None = None,
    expected_pid: int | None = None,
) -> dict[str, Any]:
    """Capture the declarative matrix into the active run and adopt it."""

    viewpoints, resolution_errors = compile_visual_capture_viewpoints(
        bridge, visual_spec, expected_session=session_id
    )
    capture_directory = assembler.run.directory / "screenshots"
    required = sorted(
        {
            str(name)
            for state in visual_spec.data.get("evaluationStates", {}).values()
            for name in state.get("requiredViewpoints", [])
        }
    )
    manifest = capture_set(
        bridge,
        viewpoints,
        capture_directory,
        assembler.run.run_id,
        build_hash=assembler.build_hash,
        place_hash=assembler.place_hash,
        spec_hash=assembler.spec_hash,
        build_path=build_path,
        spec_path=visual_spec.path,
        required_viewpoints=required,
        expected_place=expected_place,
        expected_session=session_id,
        expected_hwnd=expected_hwnd,
        expected_pid=expected_pid,
        backend=backend,
    )
    if resolution_errors:
        manifest["failures"].extend(resolution_errors)
        manifest["trustworthy"] = False
        temporary = capture_directory / "manifest.json.tmp"
        temporary.write_text(
            json.dumps(manifest, indent=2, ensure_ascii=False) + "\n",
            encoding="utf-8",
        )
        temporary.replace(capture_directory / "manifest.json")
    viewpoint_states = {
        str(name): str(viewpoint.get("state"))
        for name, viewpoint in visual_spec.data.get("viewpoints", {}).items()
    }
    assembler.record_capture(
        "screenshots",
        manifest,
        state_outcomes=state_outcomes,
        viewpoint_states=viewpoint_states,
    )
    return manifest
