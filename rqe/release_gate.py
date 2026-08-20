"""Fail-closed release evaluation.

This gate never interprets an omitted check as success.  It evaluates evidence
against a precompiled measurement plan, requires provenance from the same run
and build, and records why every missing or inadmissible claim was rejected.
"""

from __future__ import annotations

import hashlib
import json
from dataclasses import dataclass, field
from datetime import datetime, timezone
from typing import Any, Iterable

from .measurement_plan import MeasurementPlan, MeasurementRequirement
from .models import Evidence, validation_level_at_least
from .provenance import sha256_json
from .visual_review import FINDING_PENALTY, SEVERITIES, VisualReview


STATUS_SCORE = {"PASS": 100.0, "WARN": 70.0, "FAIL": 0.0}


@dataclass
class RequirementDecision:
    requirement_id: str
    probe: str
    category: str
    status: str
    score: float
    reasons: list[str] = field(default_factory=list)
    evidence_ids: list[str] = field(default_factory=list)

    def to_dict(self) -> dict[str, Any]:
        return {
            "requirementId": self.requirement_id,
            "probe": self.probe,
            "category": self.category,
            "status": self.status,
            "score": self.score,
            "reasons": self.reasons,
            "evidenceIds": self.evidence_ids,
        }


@dataclass
class ReleaseGateResult:
    release_allowed: bool
    run_id: str
    build_hash: str
    scores: dict[str, float]
    coverage: dict[str, float]
    decisions: list[RequirementDecision]
    blockers: list[str]
    visual_score: float | None

    def to_dict(self) -> dict[str, Any]:
        return {
            "releaseAllowed": self.release_allowed,
            "runId": self.run_id,
            "buildHash": self.build_hash,
            "scores": self.scores,
            "coverage": self.coverage,
            "visualScore": self.visual_score,
            "blockers": self.blockers,
            "requirements": [item.to_dict() for item in self.decisions],
        }


def _payload(item: Evidence | dict[str, Any]) -> dict[str, Any]:
    return item.to_dict() if isinstance(item, Evidence) else dict(item)


def _parse_time(value: Any) -> datetime | None:
    if not isinstance(value, str) or not value:
        return None
    try:
        parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError:
        return None
    if parsed.tzinfo is None:
        parsed = parsed.replace(tzinfo=timezone.utc)
    return parsed.astimezone(timezone.utc)


def _metadata_reasons(
    evidence: dict[str, Any],
    requirement: MeasurementRequirement,
    plan: MeasurementPlan,
    run_id: str,
    build_hash: str,
    now: datetime,
) -> list[str]:
    reasons: list[str] = []
    source = evidence.get("source")
    if source in plan.forbidden_sources:
        reasons.append(f"forbidden source {source!r}")
    if requirement.allowed_sources and source not in requirement.allowed_sources:
        reasons.append(f"source {source!r} is not allowed")

    actual_level = str(evidence.get("validationLevel") or "NOT_VALIDATED")
    try:
        if not validation_level_at_least(actual_level, requirement.minimum_validation_level):
            reasons.append(
                f"validation level {actual_level} is below {requirement.minimum_validation_level}"
            )
    except ValueError:
        reasons.append(f"invalid validation level {actual_level!r}")

    if evidence.get("runId") != run_id:
        reasons.append(f"evidence belongs to run {evidence.get('runId')!r}, expected {run_id!r}")
    if evidence.get("buildHash") != build_hash:
        reasons.append("evidence build hash does not match the release build")

    observed = _parse_time(evidence.get("observedAt"))
    if observed is None:
        reasons.append("observedAt is missing or invalid")
    else:
        age = (now - observed).total_seconds()
        if age < -60:
            reasons.append("evidence timestamp is in the future")
        elif age > requirement.maximum_age_seconds:
            reasons.append(
                f"evidence is stale ({age:.1f}s > {requirement.maximum_age_seconds:.1f}s)"
            )

    coverage = evidence.get("coverage")
    if isinstance(coverage, bool) or not isinstance(coverage, (int, float)):
        reasons.append("coverage is missing")
    elif not 0 <= float(coverage) <= 1:
        reasons.append(f"coverage {coverage!r} is outside 0..1")
    elif float(coverage) < requirement.minimum_coverage:
        reasons.append(
            f"coverage {float(coverage):.3f} is below {requirement.minimum_coverage:.3f}"
        )

    details = evidence.get("details") if isinstance(evidence.get("details"), dict) else {}
    if evidence.get("truncated") is True or details.get("truncated") is True:
        reasons.append("measurement was truncated")
    if evidence.get("conclusive") is False or details.get("conclusive") is False:
        reasons.append("measurement was inconclusive")
    return reasons


def _decide_requirement(
    requirement: MeasurementRequirement,
    evidence: list[dict[str, Any]],
    plan: MeasurementPlan,
    run_id: str,
    build_hash: str,
    now: datetime,
) -> RequirementDecision:
    if requirement.producer_status != "AVAILABLE":
        reasons = list(requirement.producer_reasons) or [
            "no release-integrated producer can generate admissible evidence"
        ]
        return RequirementDecision(
            requirement.id,
            requirement.probe,
            requirement.category,
            "UNPRODUCIBLE",
            0.0,
            reasons,
            list(requirement.producer_ids),
        )
    matches = [item for item in evidence if item.get("probe") == requirement.probe]
    if not matches:
        return RequirementDecision(
            requirement.id,
            requirement.probe,
            requirement.category,
            "MISSING",
            0.0,
            ["required probe produced no evidence"],
        )

    admissible: list[dict[str, Any]] = []
    rejected: list[str] = []
    for item in matches:
        reasons = _metadata_reasons(item, requirement, plan, run_id, build_hash, now)
        if reasons:
            rejected.append(f"{item.get('id', requirement.probe)}: " + "; ".join(reasons))
        else:
            admissible.append(item)

    if not admissible:
        return RequirementDecision(
            requirement.id,
            requirement.probe,
            requirement.category,
            "INVALID",
            0.0,
            rejected,
            [str(item.get("id") or requirement.probe) for item in matches],
        )

    non_pass = [item for item in admissible if str(item.get("status", "")).upper() != "PASS"]
    if non_pass:
        statuses = sorted({str(item.get("status", "UNKNOWN")).upper() for item in non_pass})
        return RequirementDecision(
            requirement.id,
            requirement.probe,
            requirement.category,
            "FAIL",
            min(STATUS_SCORE.get(status, 0.0) for status in statuses),
            [f"admissible evidence is not positive: {', '.join(statuses)}"],
            [str(item.get("id") or requirement.probe) for item in admissible],
        )

    return RequirementDecision(
        requirement.id,
        requirement.probe,
        requirement.category,
        "PASS",
        100.0,
        [],
        [str(item.get("id") or requirement.probe) for item in admissible],
    )


def _sha256_text(payload: str) -> str:
    return hashlib.sha256(payload.encode("utf-8")).hexdigest()


def _capture_artifact_hash(manifest: dict[str, Any]) -> str:
    encoded = json.dumps(manifest, indent=2, ensure_ascii=False) + "\n"
    return _sha256_text(encoded)


def _valid_sha256(value: Any) -> bool:
    return (
        isinstance(value, str)
        and len(value) == 64
        and all(character in "0123456789abcdef" for character in value)
    )


def _capture_reasons(
    manifest: dict[str, Any] | None,
    *,
    plan: MeasurementPlan,
    run_id: str,
    build_hash: str,
    now: datetime,
) -> tuple[list[str], list[str]]:
    if not isinstance(manifest, dict):
        return ["capture manifest is missing"], []
    reasons: list[str] = []
    if manifest.get("schemaVersion") != 1:
        reasons.append("capture schemaVersion 1 is required")
    if manifest.get("trustworthy") is not True:
        reasons.append("capture set is missing, incomplete, failed or occluded")
    if manifest.get("runId") != run_id:
        reasons.append("capture runId does not match the release run")
    if manifest.get("buildHash") != build_hash:
        reasons.append("capture buildHash does not match the release build")
    expected_spec = (plan.metadata.get("visualSpec") or {}).get("sha256")
    if not _valid_sha256(expected_spec) or manifest.get("specHash") != expected_spec:
        reasons.append("capture specHash does not match the measurement plan")
    if not _valid_sha256(manifest.get("placeHash")):
        reasons.append("capture placeHash is missing or invalid")
    if not isinstance(manifest.get("sessionId"), str) or not manifest.get("sessionId"):
        reasons.append("capture sessionId is missing")
    if manifest.get("failures") not in ([], None):
        reasons.append("capture manifest contains failures")
    if manifest.get("occludedShots") not in (0, 0.0):
        reasons.append("capture manifest contains occluded shots")
    if manifest.get("coverage") not in (1, 1.0):
        reasons.append("capture coverage is incomplete")
    captured_at = _parse_time(manifest.get("capturedAt"))
    if captured_at is None:
        reasons.append("capture timestamp is missing or invalid")
    else:
        maximum_age = plan.maximum_age_seconds_by_level["VISUALLY_VALIDATED"]
        age = (now - captured_at).total_seconds()
        if age < -60 or age > maximum_age:
            reasons.append("capture manifest is stale or timestamped in the future")

    required = manifest.get("requiredViewpoints")
    captured = manifest.get("capturedRequiredViewpoints")
    if not isinstance(required, list) or not required or any(not isinstance(item, str) or not item for item in required):
        reasons.append("capture manifest must name required viewpoints")
        required_names: list[str] = []
    else:
        required_names = list(required)
        if len(required_names) != len(set(required_names)):
            reasons.append("capture required viewpoints are duplicated")
    if not isinstance(captured, list) or set(captured) != set(required_names):
        reasons.append("captured viewpoints do not exactly cover required viewpoints")
    if manifest.get("missingRequiredViewpoints") not in ([], None):
        reasons.append("capture manifest names missing required viewpoints")

    shots = manifest.get("shots")
    if not isinstance(shots, list) or not shots:
        reasons.append("capture manifest contains no shots")
    else:
        by_id: dict[str, dict[str, Any]] = {}
        for raw in shots:
            if not isinstance(raw, dict) or not isinstance(raw.get("id"), str):
                reasons.append("capture shot has an invalid shape")
                continue
            if raw["id"] in by_id:
                reasons.append(f"capture shot id is duplicated: {raw['id']}")
            by_id[raw["id"]] = raw
        for viewpoint in required_names:
            shot = by_id.get(viewpoint)
            if shot is None:
                reasons.append(f"required capture shot is absent: {viewpoint}")
                continue
            if shot.get("trustworthy") is not True or shot.get("integrityIssues"):
                reasons.append(f"required capture shot is untrustworthy: {viewpoint}")
            for field, expected in (
                ("runId", run_id),
                ("buildHash", build_hash),
                ("placeHash", manifest.get("placeHash")),
                ("specHash", expected_spec),
                ("sessionId", manifest.get("sessionId")),
            ):
                if shot.get(field) != expected:
                    reasons.append(f"capture shot {viewpoint} has mismatched {field}")
            if not _valid_sha256(shot.get("sha256")) or not isinstance(shot.get("bytes"), int) or shot.get("bytes", 0) <= 0:
                reasons.append(f"capture shot {viewpoint} has invalid PNG receipt")
            camera = shot.get("camera")
            if not isinstance(camera, dict) or not isinstance(camera.get("before"), dict) or not isinstance(camera.get("after"), dict):
                reasons.append(f"capture shot {viewpoint} has incomplete camera provenance")
    return list(dict.fromkeys(reasons)), required_names


def _review_reasons(
    review: VisualReview | dict[str, Any] | None,
    capture_manifest: dict[str, Any] | None,
    required_viewpoints: list[str],
    *,
    plan: MeasurementPlan,
    run_id: str,
    build_hash: str,
    now: datetime,
) -> tuple[list[str], float | None]:
    if isinstance(review, VisualReview):
        payload = review.to_dict()
    elif isinstance(review, dict):
        payload = dict(review)
    else:
        return ["structured visual review is missing"], None
    reasons: list[str] = []
    if payload.get("schemaVersion") != 1 or payload.get("status") != "COMPLETE":
        reasons.append("visual review is incomplete or has an unsupported schema")
    if payload.get("validationLevel") != "VISUALLY_VALIDATED":
        reasons.append("visual review validation level is not VISUALLY_VALIDATED")
    if payload.get("runId") != run_id or payload.get("buildHash") != build_hash:
        reasons.append("visual review does not belong to the release run/build")
    expected_spec = (plan.metadata.get("visualSpec") or {}).get("sha256")
    if payload.get("specHash") != expected_spec:
        reasons.append("visual review specHash does not match the measurement plan")
    if not isinstance(capture_manifest, dict):
        reasons.append("visual review cannot be linked without a capture manifest")
    else:
        if payload.get("placeHash") != capture_manifest.get("placeHash"):
            reasons.append("visual review placeHash differs from the capture build")
        if payload.get("captureManifestSha256") != _capture_artifact_hash(capture_manifest):
            reasons.append("visual review is not hash-bound to the capture manifest artifact")
    for field in ("provider", "model"):
        if not isinstance(payload.get(field), str) or not payload.get(field):
            reasons.append(f"visual review {field} is missing")
    if not _valid_sha256(payload.get("modelHash")) or payload.get("modelHash") != sha256_json({"provider": payload.get("provider"), "model": payload.get("model")}):
        reasons.append("visual review modelHash is invalid")
    if not _valid_sha256(payload.get("promptHash")):
        reasons.append("visual review promptHash is invalid")
    created_at = _parse_time(payload.get("createdAt"))
    if created_at is None:
        reasons.append("visual review timestamp is missing or invalid")
    else:
        maximum_age = plan.maximum_age_seconds_by_level["VISUALLY_VALIDATED"]
        age = (now - created_at).total_seconds()
        if age < -60 or age > maximum_age:
            reasons.append("visual review is stale or timestamped in the future")

    reviewed = payload.get("reviewedViewpoints")
    if not isinstance(reviewed, list) or set(reviewed) != set(required_viewpoints):
        reasons.append("visual review viewpoint coverage is incomplete")
    assessments = payload.get("assessments")
    grades: list[int] = []
    assessed: set[str] = set()
    if not isinstance(assessments, list) or not assessments:
        reasons.append("visual review contains no assessments")
    else:
        for assessment in assessments:
            if not isinstance(assessment, dict) or not isinstance(assessment.get("viewpoint"), str):
                reasons.append("visual review assessment has an invalid shape")
                continue
            viewpoint = assessment["viewpoint"]
            if viewpoint in assessed or viewpoint not in required_viewpoints:
                reasons.append(f"visual review assessment viewpoint is duplicate or unknown: {viewpoint}")
            assessed.add(viewpoint)
            rubric = assessment.get("rubric")
            if not isinstance(rubric, list) or not rubric:
                reasons.append(f"visual review rubric is empty: {viewpoint}")
                continue
            for entry in rubric:
                grade = entry.get("grade") if isinstance(entry, dict) else None
                if isinstance(grade, bool) or not isinstance(grade, int) or not 1 <= grade <= 5:
                    reasons.append(f"visual review grade is invalid: {viewpoint}")
                    continue
                citations = (entry.get("evidence") or {}).get("shotIds")
                if not isinstance(citations, list) or viewpoint not in citations or any(item not in required_viewpoints for item in citations):
                    reasons.append(f"visual review rubric citation is invalid: {viewpoint}")
                grades.append(grade)
    if assessed != set(required_viewpoints):
        reasons.append("visual review assessments do not cover every required viewpoint")

    # A vision model is useful as a critic, but its severity labels are not a
    # calibrated blocking signal. Findings stay in the artifact and are routed
    # to repair; only independently measured rules can veto the release.
    penalty = 0.0
    findings = payload.get("findings")
    if not isinstance(findings, list):
        reasons.append("visual review findings must be an array")
    else:
        for finding in findings:
            severity = finding.get("severity") if isinstance(finding, dict) else None
            if severity not in SEVERITIES:
                reasons.append("visual review finding has an invalid severity")
                continue
            citations = (finding.get("evidence") or {}).get("shotIds")
            if not isinstance(citations, list) or not citations or any(item not in required_viewpoints for item in citations):
                reasons.append("visual review finding has invalid citations")
            penalty += FINDING_PENALTY[severity]

    if grades:
        average = round(sum((grade - 1) * 25 for grade in grades) / len(grades), 1)
        derived = round(max(0.0, average - round(penalty, 1)), 1)
    else:
        average = 0.0
        derived = 0.0
    score = payload.get("score")
    scoring = payload.get("scoring") if isinstance(payload.get("scoring"), dict) else {}
    if isinstance(score, bool) or not isinstance(score, (int, float)) or float(score) != derived:
        reasons.append("visual review score was not derived from the submitted rubric/findings")
    if scoring.get("rubricAverage") != average or scoring.get("findingPenalty") != round(penalty, 1):
        reasons.append("visual review scoring receipt does not match the deterministic recomputation")
    return list(dict.fromkeys(reasons)), derived if not reasons else None


def _token_conformance_blockers(plan: MeasurementPlan) -> list[str]:
    """Refuse a release whose visual thresholds have no traceable author.

    A spec whose numbers were typed while looking at the candidate describes the
    build it grades, and therefore passes by construction. The projection from a
    token set is what gives a threshold an author; this is where the absence of
    that projection stops being a documentation gap and starts being a blocker.
    """

    report = plan.metadata.get("tokenConformance")
    if not isinstance(report, dict):
        return ["visual thresholds have no token-conformance report"]

    status = report.get("status")
    if status == "CONFORMS":
        return []
    if status == "NOT_DECLARED":
        return [
            "no token set is declared, so no visual threshold can be traced to an author "
            "independent of the candidate"
        ]
    if status == "INVALID":
        return [f"the declared token set is invalid: {report.get('detail')}"]

    issues = report.get("issues") or []
    # Named individually up to a point, then counted. A blocker list nobody can
    # read is a blocker list nobody acts on, but hiding the count would
    # understate how far the spec has drifted.
    shown = [f"visual threshold is not derived from tokens: {issue}" for issue in issues[:5]]
    if len(issues) > 5:
        shown.append(
            f"visual thresholds diverge from the token set in {len(issues)} places "
            f"(coverage {report.get('coverage')}); the remainder are in the measurement plan"
        )
    return shown


def evaluate_release(
    plan: MeasurementPlan,
    evidence: Iterable[Evidence | dict[str, Any]],
    *,
    run_id: str,
    build_hash: str,
    command_errors: Iterable[dict[str, Any]] = (),
    capture_manifest: dict[str, Any] | None = None,
    visual_review: VisualReview | dict[str, Any] | None = None,
    now: datetime | None = None,
) -> ReleaseGateResult:
    """Evaluate one immutable run.  Every unknown is a blocker, never a pass."""

    evaluated_at = (now or datetime.now(timezone.utc)).astimezone(timezone.utc)
    payloads = [_payload(item) for item in evidence]
    decisions = [
        _decide_requirement(item, payloads, plan, run_id, build_hash, evaluated_at)
        for item in plan.requirements
    ]

    scores: dict[str, float] = {}
    coverage: dict[str, float] = {}
    blockers: list[str] = []
    for category in plan.required_categories:
        category_decisions = [item for item in decisions if item.category == category]
        if category_decisions:
            scores[category] = round(
                sum(item.score for item in category_decisions) / len(category_decisions), 1
            )
            coverage[category] = round(
                sum(1 for item in category_decisions if item.status == "PASS") / len(category_decisions),
                4,
            )
        else:
            # Measurement-plan compilation rejects this shape. Keep the runtime
            # guard as defense in depth for a manually constructed plan.
            scores[category] = 0.0
            coverage[category] = 0.0
            blockers.append(f"{category}: required category has no enumerated requirements")

        minimum_coverage = plan.minimum_category_coverage.get(category, 1.0)
        if coverage[category] < minimum_coverage:
            blockers.append(
                f"{category}: coverage {coverage[category]:.3f} below {minimum_coverage:.3f}"
            )
        target = plan.target_scores.get(category)
        if target is None:
            blockers.append(f"{category}: no target score is defined")
        elif scores[category] < target:
            blockers.append(f"{category}: score {scores[category]:.1f} below {target:.1f}")

    for decision in decisions:
        if decision.status != "PASS":
            blockers.append(
                f"{decision.requirement_id}: {decision.status.lower()} ({'; '.join(decision.reasons)})"
            )

    errors = list(command_errors)
    if errors:
        blockers.append(f"{len(errors)} bridge command error(s) were recorded")

    blockers.extend(_token_conformance_blockers(plan))

    visual_score: float | None = None
    if "visual" in plan.required_categories or "ui" in plan.required_categories:
        capture_reasons, required_viewpoints = _capture_reasons(
            capture_manifest,
            plan=plan,
            run_id=run_id,
            build_hash=build_hash,
            now=evaluated_at,
        )
        if plan.require_trustworthy_captures:
            blockers.extend(capture_reasons)
        review_reasons, visual_score = _review_reasons(
            visual_review,
            capture_manifest,
            required_viewpoints,
            plan=plan,
            run_id=run_id,
            build_hash=build_hash,
            now=evaluated_at,
        )
        blockers.extend(review_reasons)
        if visual_score is not None and visual_score < plan.minimum_visual_score:
            blockers.append(
                f"visual review score {visual_score:.1f} below {plan.minimum_visual_score:.1f}"
            )

    # Preserve insertion order while collapsing repeated consequences.
    blockers = list(dict.fromkeys(blockers))
    return ReleaseGateResult(
        release_allowed=not blockers,
        run_id=run_id,
        build_hash=build_hash,
        scores=scores,
        coverage=coverage,
        decisions=decisions,
        blockers=blockers,
        visual_score=visual_score,
    )
