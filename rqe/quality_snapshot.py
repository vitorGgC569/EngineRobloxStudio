"""Compile and consume the typed Studio visual-quality snapshot command.

The visual spec owns policy.  The plugin receives only selectors, measurement
parameters and hard safety budgets, then returns raw geometry/raycast facts.
This module binds that response to one run/build/session before the deterministic
rules in :mod:`rqe.quality` are allowed to turn it into release evidence.
"""

from __future__ import annotations

import copy
from dataclasses import dataclass
from typing import Any, Protocol

from .models import Evidence
from .project import Project
from .provenance import sha256_json
from .quality import evaluate_quality_snapshot
from .visual_spec import VisualQualitySpec


RUNNING_CONTEXTS = {"run", "server", "client"}


class QualitySnapshotError(ValueError):
    """The Studio snapshot cannot be admitted as runtime quality evidence."""


@dataclass(frozen=True)
class QualitySnapshotLimits:
    """Transport/performance guardrails, never visual acceptance thresholds."""

    max_candidates: int = 25_000
    max_roots: int = 5_000
    max_regions: int = 500
    max_visibility_samples: int = 20_000

    def to_dict(self) -> dict[str, int]:
        values = {
            "maxCandidates": self.max_candidates,
            "maxRoots": self.max_roots,
            "maxRegions": self.max_regions,
            "maxVisibilitySamples": self.max_visibility_samples,
        }
        for name, value in values.items():
            if isinstance(value, bool) or not isinstance(value, int) or value < 1:
                raise QualitySnapshotError(f"quality snapshot limit {name} must be a positive integer")
        return values


class QualitySnapshotBridge(Protocol):
    pinned_session: str | None

    def call_response(
        self,
        method: str,
        params: dict[str, Any] | None = None,
        timeout: float = 15.0,
        lease: dict[str, Any] | None = None,
    ) -> Any: ...


@dataclass(frozen=True)
class QualitySnapshotMeasurement:
    run_id: str
    build_hash: str
    session_id: str
    context: str
    command_id: str
    request_sha256: str
    snapshot_sha256: str
    snapshot: dict[str, Any]
    evidence: tuple[Evidence, ...]

    @property
    def conclusive(self) -> bool:
        return bool(self.evidence) and all(
            item.conclusive and not item.truncated and item.coverage == 1.0
            for item in self.evidence
        )

    def receipt(self) -> dict[str, Any]:
        return {
            "schemaVersion": 1,
            "status": "COMPLETE" if self.conclusive else "INCONCLUSIVE",
            "validationLevel": "RUNTIME_VALIDATED",
            "source": "studio-bridge",
            "runId": self.run_id,
            "buildHash": self.build_hash,
            "sessionId": self.session_id,
            "context": self.context,
            "commandId": self.command_id,
            "requestSha256": self.request_sha256,
            "snapshotSha256": self.snapshot_sha256,
            "capturedAt": self.snapshot.get("capturedAt"),
            "truncated": bool(self.snapshot.get("truncated")),
            "conclusive": self.conclusive,
            "evidenceCount": len(self.evidence),
            "failedRules": [item.probe for item in self.evidence if item.status != "PASS"],
            "authorizesRelease": False,
        }


def compile_quality_snapshot_params(
    spec: VisualQualitySpec,
    *,
    limits: QualitySnapshotLimits | None = None,
) -> dict[str, Any]:
    """Compile raw-measurement parameters without leaking acceptance policy.

    In particular, minimum coverage, density, palette, cardinality, visibility
    and score thresholds never cross the bridge.  That makes the Studio command
    reusable for any genre and prevents the measurer from grading itself.
    """

    classification = spec.data.get("classification")
    if not isinstance(classification, dict):
        raise QualitySnapshotError("visual spec classification must be an object")
    measurement_keys = (
        "candidateTag",
        "rootTag",
        "typeAttribute",
        "variantAttribute",
        "assetKeyAttribute",
        "regionTag",
        "regionProfileAttribute",
        "landmarkTag",
        "landmarkAnchorTag",
        "excludeTag",
    )
    compiled_classification: dict[str, str] = {}
    for key in measurement_keys:
        value = classification.get(key)
        if not isinstance(value, str) or not value.strip():
            raise QualitySnapshotError(f"visual spec classification.{key} must be a non-empty string")
        compiled_classification[key] = value

    landmarks: list[dict[str, Any]] = []
    for landmark_id in sorted(spec.data.get("landmarks", {})):
        policy = spec.data["landmarks"][landmark_id]
        landmarks.append({
            "id": landmark_id,
            "selector": copy.deepcopy(policy["selector"]),
            "anchorSelector": copy.deepcopy(policy["anchorSelector"]),
            "maximumDistance": policy["maximumDistance"],
            "sampleSpacing": policy["sampleSpacing"],
            "eyeHeight": policy["eyeHeight"],
            "raysPerAnchor": policy["raysPerAnchor"],
        })

    return {
        "classification": compiled_classification,
        "landmarks": landmarks,
        "limits": (limits or QualitySnapshotLimits()).to_dict(),
    }


def measure_quality_snapshot(
    bridge: QualitySnapshotBridge,
    project: Project,
    spec: VisualQualitySpec,
    *,
    run_id: str,
    build_hash: str,
    expected_session: str | None = None,
    lease: dict[str, Any] | None = None,
    timeout: float = 60.0,
    limits: QualitySnapshotLimits | None = None,
) -> QualitySnapshotMeasurement:
    """Measure one pinned running DataModel and derive deterministic evidence."""

    session_id = expected_session or bridge.pinned_session
    if not isinstance(session_id, str) or not session_id:
        raise QualitySnapshotError("quality.snapshot requires an explicitly pinned Studio session")
    if not isinstance(run_id, str) or not run_id:
        raise QualitySnapshotError("quality.snapshot run_id must be a non-empty string")
    if not isinstance(build_hash, str) or not build_hash:
        raise QualitySnapshotError("quality.snapshot build_hash must be a non-empty string")

    params = compile_quality_snapshot_params(spec, limits=limits)
    response = bridge.call_response("quality.snapshot", params, timeout=timeout, lease=lease)
    if response.session != session_id:
        raise QualitySnapshotError(
            f"quality.snapshot answered from session {response.session!r}, expected pinned session {session_id!r}"
        )
    if response.context not in RUNNING_CONTEXTS:
        raise QualitySnapshotError(
            f"quality.snapshot answered from {response.context!r}, not a running DataModel"
        )
    if not response.ok:
        error = response.error if isinstance(response.error, dict) else {"message": str(response.error)}
        raise QualitySnapshotError(f"Studio rejected quality.snapshot: {error}")
    if not isinstance(response.result, dict):
        raise QualitySnapshotError("quality.snapshot result must be an object")

    snapshot = copy.deepcopy(response.result)
    observed_at = snapshot.get("capturedAt")
    if not isinstance(observed_at, str) or not observed_at:
        raise QualitySnapshotError("quality.snapshot result has no capturedAt timestamp")
    evidence = tuple(evaluate_quality_snapshot(
        project,
        spec,
        snapshot,
        run_id=run_id,
        build_hash=build_hash,
        observed_at=observed_at,
    ))
    if not evidence:
        raise QualitySnapshotError("quality.snapshot produced no deterministic quality evidence")
    return QualitySnapshotMeasurement(
        run_id=run_id,
        build_hash=build_hash,
        session_id=session_id,
        context=response.context,
        command_id=response.id,
        request_sha256=sha256_json(params),
        snapshot_sha256=sha256_json(snapshot),
        snapshot=snapshot,
        evidence=evidence,
    )
