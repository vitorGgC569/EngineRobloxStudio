"""Provider-neutral visual review over integrity-checked capture manifests.

The provider describes what is visible.  The engine owns provenance, validates
all citations and rubric coverage, and derives the score.  A model cannot make
an untrusted screenshot trustworthy or inject its own release score.
"""

from __future__ import annotations

import copy
import hashlib
import json
from dataclasses import dataclass, field
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Mapping, Protocol


VISUAL_REVIEW_SCHEMA_VERSION = 1
PROMPT_VERSION = "rqe.visual-review/1"
DEFAULT_PROMPT = """You are reviewing Roblox game screenshots against explicit visual rubrics.
Report only what is visible in the supplied images. Do not infer source code,
collision state, ownership, or hidden geometry. A geometry concern should be
worded as an appearance (for example, 'appears to float in this view'). Ignore
Roblox Studio chrome and judge the rendered game viewport only.

Return exactly two fields: assessments and findings. Assess every requested
criterion for every viewpoint with an integer grade from 1 (unacceptable) to 5
(production quality), a concrete rationale, and citations to supplied shot ids.
Every finding must be actionable and cite at least one supplied shot id. Do not
return an overall score; the quality engine derives it deterministically.
"""

SEVERITIES = {"critical", "major", "minor", "info"}
CATEGORIES = {
    "floating",
    "buried",
    "clipping",
    "gap",
    "alignment",
    "lighting",
    "density",
    "legibility",
    "scale",
    "composition",
    "finish",
    "consistency",
}
# Model findings are advisory observations, not calibrated defect classifiers.
# They therefore neither subtract from the rubric score nor veto a release on
# their own. Deterministic/runtime rules remain the blocking authority and can
# corroborate the same condition independently.
FINDING_PENALTY = {"critical": 0.0, "major": 0.0, "minor": 0.0, "info": 0.0}
PROVIDER_RESPONSE_SCHEMA: dict[str, Any] = {
    "type": "object",
    "additionalProperties": False,
    "required": ["assessments", "findings"],
    "properties": {
        "assessments": {
            "type": "array",
            "items": {
                "type": "object",
                "additionalProperties": False,
                "required": ["viewpoint", "rubric"],
                "properties": {
                    "viewpoint": {"type": "string"},
                    "rubric": {
                        "type": "array",
                        "items": {
                            "type": "object",
                            "additionalProperties": False,
                            "required": ["criterion", "grade", "rationale", "evidence"],
                            "properties": {
                                "criterion": {"type": "string"},
                                "grade": {"type": "integer", "minimum": 1, "maximum": 5},
                                "rationale": {"type": "string"},
                                "evidence": {
                                    "type": "object",
                                    "additionalProperties": False,
                                    "required": ["shotIds"],
                                    "properties": {"shotIds": {"type": "array", "minItems": 1, "items": {"type": "string"}}},
                                },
                            },
                        },
                    },
                },
            },
        },
        "findings": {
            "type": "array",
            "items": {
                "type": "object",
                "additionalProperties": False,
                "required": ["severity", "category", "location", "finding", "suggestedAction", "evidence"],
                "properties": {
                    "severity": {"type": "string", "enum": sorted(SEVERITIES)},
                    "category": {"type": "string", "enum": sorted(CATEGORIES)},
                    "location": {"type": "string"},
                    "finding": {"type": "string"},
                    "suggestedAction": {"type": "string"},
                    "evidence": {
                        "type": "object",
                        "additionalProperties": False,
                        "required": ["shotIds"],
                        "properties": {"shotIds": {"type": "array", "minItems": 1, "items": {"type": "string"}}},
                    },
                },
            },
        },
    },
}


class VisualReviewError(ValueError):
    """The review could not produce admissible visual evidence."""


@dataclass(frozen=True)
class ReviewImage:
    id: str
    mime_type: str
    data: bytes = field(repr=False)
    sha256: str = ""
    metadata: dict[str, Any] = field(default_factory=dict)

    def to_dict(self) -> dict[str, Any]:
        return {
            "id": self.id,
            "mimeType": self.mime_type,
            "sha256": self.sha256,
            "bytes": len(self.data),
            "metadata": self.metadata,
        }


@dataclass(frozen=True)
class ReviewRequest:
    run_id: str
    build_hash: str
    place_hash: str
    spec_hash: str
    capture_manifest_sha256: str
    prompt: str
    prompt_hash: str
    rubric_by_viewpoint: dict[str, tuple[str, ...]]
    images: tuple[ReviewImage, ...]
    response_schema: dict[str, Any] = field(default_factory=lambda: copy.deepcopy(PROVIDER_RESPONSE_SCHEMA))

    def to_dict(self) -> dict[str, Any]:
        return {
            "schemaVersion": VISUAL_REVIEW_SCHEMA_VERSION,
            "runId": self.run_id,
            "buildHash": self.build_hash,
            "placeHash": self.place_hash,
            "specHash": self.spec_hash,
            "captureManifestSha256": self.capture_manifest_sha256,
            "promptVersion": PROMPT_VERSION,
            "prompt": self.prompt,
            "promptHash": self.prompt_hash,
            "rubricByViewpoint": {key: list(value) for key, value in self.rubric_by_viewpoint.items()},
            "responseSchema": self.response_schema,
            "images": [image.to_dict() for image in self.images],
        }


class VisionProvider(Protocol):
    """Provider adapter boundary; vendor SDK details stay outside the engine."""

    name: str
    model: str

    def review(self, request: ReviewRequest) -> Mapping[str, Any]: ...


@dataclass(frozen=True)
class VisualReview:
    run_id: str
    build_hash: str
    place_hash: str
    spec_hash: str
    capture_manifest_sha256: str
    provider: str
    model: str
    model_hash: str
    prompt_hash: str
    assessments: tuple[dict[str, Any], ...]
    findings: tuple[dict[str, Any], ...]
    score: float
    rubric_average: float
    finding_penalty: float
    created_at: str

    def to_dict(self) -> dict[str, Any]:
        return {
            "schemaVersion": VISUAL_REVIEW_SCHEMA_VERSION,
            "status": "COMPLETE",
            "validationLevel": "VISUALLY_VALIDATED",
            "runId": self.run_id,
            "buildHash": self.build_hash,
            "placeHash": self.place_hash,
            "specHash": self.spec_hash,
            "captureManifestSha256": self.capture_manifest_sha256,
            "provider": self.provider,
            "model": self.model,
            "modelHash": self.model_hash,
            "promptVersion": PROMPT_VERSION,
            "promptHash": self.prompt_hash,
            "reviewedViewpoints": [item["viewpoint"] for item in self.assessments],
            "assessments": list(self.assessments),
            "findings": list(self.findings),
            "score": self.score,
            "scoring": {
                "rubricAverage": self.rubric_average,
                "findingPenalty": self.finding_penalty,
                "gradeMapping": {"1": 0, "2": 25, "3": 50, "4": 75, "5": 100},
                "findingPenaltyBySeverity": FINDING_PENALTY,
                "formula": "rubricAverage (findings are advisory until independently corroborated)",
            },
            "createdAt": self.created_at,
        }


def _now() -> str:
    return datetime.now(timezone.utc).isoformat()


def _atomic_json(path: Path, payload: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix(path.suffix + ".tmp")
    temporary.write_text(json.dumps(payload, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    temporary.replace(path)


def _sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def _canonical_hash(value: Any) -> str:
    return _sha256(json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode("utf-8"))


def _require_text(value: Any, label: str) -> str:
    if not isinstance(value, str) or not value.strip():
        raise VisualReviewError(f"{label} must be a non-empty string")
    return value.strip()


def _require_sha256(value: Any, label: str) -> str:
    text = _require_text(value, label)
    if len(text) != 64 or any(character not in "0123456789abcdef" for character in text):
        raise VisualReviewError(f"{label} must be a lowercase SHA-256")
    return text


def _capture_request(
    manifest: dict[str, Any],
    capture_directory: Path,
    rubric_by_viewpoint: Mapping[str, list[str] | tuple[str, ...]],
    prompt: str,
) -> ReviewRequest:
    if manifest.get("schemaVersion") != 1:
        raise VisualReviewError("capture manifest schemaVersion 1 is required")
    if manifest.get("trustworthy") is not True:
        raise VisualReviewError("untrustworthy captures cannot be sent to a vision provider")
    if manifest.get("failures") or manifest.get("occludedShots") not in (0, 0.0):
        raise VisualReviewError("capture manifest contains failures or occluded shots")
    if manifest.get("coverage") != 1 and manifest.get("coverage") != 1.0:
        raise VisualReviewError("capture coverage must be complete")

    run_id = _require_text(manifest.get("runId"), "capture.runId")
    build_hash = _require_sha256(manifest.get("buildHash"), "capture.buildHash")
    place_hash = _require_sha256(manifest.get("placeHash"), "capture.placeHash")
    spec_hash = _require_sha256(manifest.get("specHash"), "capture.specHash")
    _require_text(manifest.get("sessionId"), "capture.sessionId")

    manifest_path = capture_directory / "manifest.json"
    if not manifest_path.is_file():
        raise VisualReviewError("capture manifest artifact is missing")
    try:
        artifact_manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise VisualReviewError(f"capture manifest artifact is invalid: {exc}") from exc
    if artifact_manifest != manifest:
        raise VisualReviewError("capture manifest input differs from the persisted artifact")
    manifest_hash = _sha256(manifest_path.read_bytes())

    required_raw = manifest.get("requiredViewpoints")
    if not isinstance(required_raw, list) or not required_raw:
        raise VisualReviewError("capture manifest must name at least one required viewpoint")
    required = [_require_text(value, "required viewpoint") for value in required_raw]
    if len(required) != len(set(required)):
        raise VisualReviewError("required viewpoints must be unique")
    if manifest.get("missingRequiredViewpoints"):
        raise VisualReviewError("capture manifest is missing required viewpoints")
    captured = manifest.get("capturedRequiredViewpoints")
    if not isinstance(captured, list) or set(captured) != set(required):
        raise VisualReviewError("captured viewpoint coverage differs from required coverage")

    normalized_rubric: dict[str, tuple[str, ...]] = {}
    if set(rubric_by_viewpoint) != set(required):
        raise VisualReviewError("rubric viewpoints must exactly match required capture viewpoints")
    for viewpoint in required:
        raw_criteria = rubric_by_viewpoint[viewpoint]
        if not isinstance(raw_criteria, (list, tuple)) or not raw_criteria:
            raise VisualReviewError(f"rubric for {viewpoint} must contain at least one criterion")
        criteria = tuple(_require_text(value, f"rubric {viewpoint} criterion") for value in raw_criteria)
        if len(criteria) != len(set(criteria)):
            raise VisualReviewError(f"rubric for {viewpoint} contains duplicate criteria")
        normalized_rubric[viewpoint] = criteria

    shots = manifest.get("shots")
    if not isinstance(shots, list) or not shots:
        raise VisualReviewError("capture manifest contains no shots")
    by_id: dict[str, dict[str, Any]] = {}
    for raw in shots:
        if not isinstance(raw, dict):
            raise VisualReviewError("capture shot must be an object")
        shot_id = _require_text(raw.get("id"), "capture shot id")
        if shot_id in by_id:
            raise VisualReviewError(f"duplicate capture shot id: {shot_id}")
        by_id[shot_id] = raw

    images: list[ReviewImage] = []
    root = capture_directory.resolve()
    for viewpoint in required:
        raw = by_id.get(viewpoint)
        if raw is None:
            raise VisualReviewError(f"required capture shot is absent: {viewpoint}")
        if raw.get("trustworthy") is not True or raw.get("integrityIssues"):
            raise VisualReviewError(f"required capture shot is untrustworthy: {viewpoint}")
        if (
            raw.get("runId") != run_id
            or raw.get("buildHash") != build_hash
            or raw.get("placeHash") != place_hash
            or raw.get("specHash") != spec_hash
        ):
            raise VisualReviewError(f"capture shot provenance differs from manifest: {viewpoint}")
        filename = _require_text(raw.get("file"), f"capture shot {viewpoint} file")
        if Path(filename).name != filename or Path(filename).suffix.lower() != ".png":
            raise VisualReviewError(f"capture shot {viewpoint} has an unsafe PNG path")
        path = (root / filename).resolve()
        if path.parent != root or not path.is_file():
            raise VisualReviewError(f"capture shot file is missing or outside the artifact directory: {viewpoint}")
        expected_hash = _require_sha256(raw.get("sha256"), f"capture shot {viewpoint} sha256")
        data = path.read_bytes()
        actual_hash = _sha256(data)
        if actual_hash != expected_hash:
            raise VisualReviewError(f"capture shot hash differs from its manifest: {viewpoint}")
        if raw.get("bytes") != len(data):
            raise VisualReviewError(f"capture shot byte count differs from its manifest: {viewpoint}")
        images.append(ReviewImage(
            id=viewpoint,
            mime_type="image/png",
            data=data,
            sha256=actual_hash,
            metadata={
                "target": raw.get("target"),
                "camera": raw.get("camera"),
                "width": raw.get("width"),
                "height": raw.get("height"),
            },
        ))

    prompt_text = _require_text(prompt, "visual review prompt")
    prompt_hash = _canonical_hash({
        "promptVersion": PROMPT_VERSION,
        "prompt": prompt_text,
        "rubric": {key: list(value) for key, value in normalized_rubric.items()},
        "captureManifestSha256": manifest_hash,
    })
    return ReviewRequest(
        run_id=run_id,
        build_hash=build_hash,
        place_hash=place_hash,
        spec_hash=spec_hash,
        capture_manifest_sha256=manifest_hash,
        prompt=prompt_text,
        prompt_hash=prompt_hash,
        rubric_by_viewpoint=normalized_rubric,
        images=tuple(images),
    )


def _validate_citations(raw: Any, known_shots: set[str], label: str, *, must_include: str | None = None) -> list[str]:
    if not isinstance(raw, dict) or set(raw) != {"shotIds"}:
        raise VisualReviewError(f"{label}.evidence must contain only shotIds")
    shot_ids = raw.get("shotIds")
    if not isinstance(shot_ids, list) or not shot_ids:
        raise VisualReviewError(f"{label} must cite at least one shot")
    normalized = [_require_text(value, f"{label} shot id") for value in shot_ids]
    unknown = sorted(set(normalized) - known_shots)
    if unknown:
        raise VisualReviewError(f"{label} cites unknown shots: {unknown}")
    if must_include and must_include not in normalized:
        raise VisualReviewError(f"{label} must cite its own viewpoint {must_include}")
    return normalized


def _validate_provider_result(raw: Mapping[str, Any], request: ReviewRequest) -> tuple[tuple[dict[str, Any], ...], tuple[dict[str, Any], ...], float, float]:
    if not isinstance(raw, Mapping):
        raise VisualReviewError("vision provider response must be an object")
    if set(raw) != {"assessments", "findings"}:
        raise VisualReviewError("vision provider response must contain exactly assessments and findings; provider scores are forbidden")
    known_shots = {image.id for image in request.images}

    assessment_raw = raw.get("assessments")
    if not isinstance(assessment_raw, list):
        raise VisualReviewError("provider assessments must be an array")
    by_viewpoint: dict[str, dict[str, Any]] = {}
    numeric_grades: list[int] = []
    for index, item in enumerate(assessment_raw):
        if not isinstance(item, dict) or set(item) != {"viewpoint", "rubric"}:
            raise VisualReviewError(f"assessment[{index}] must contain exactly viewpoint and rubric")
        viewpoint = _require_text(item.get("viewpoint"), f"assessment[{index}].viewpoint")
        if viewpoint not in request.rubric_by_viewpoint:
            raise VisualReviewError(f"assessment cites unknown viewpoint: {viewpoint}")
        if viewpoint in by_viewpoint:
            raise VisualReviewError(f"duplicate assessment for viewpoint: {viewpoint}")
        rubric_raw = item.get("rubric")
        if not isinstance(rubric_raw, list):
            raise VisualReviewError(f"assessment rubric for {viewpoint} must be an array")
        normalized_rubric: list[dict[str, Any]] = []
        seen_criteria: set[str] = set()
        for rubric_index, entry in enumerate(rubric_raw):
            if not isinstance(entry, dict) or set(entry) != {"criterion", "grade", "rationale", "evidence"}:
                raise VisualReviewError(f"rubric {viewpoint}[{rubric_index}] has invalid fields")
            criterion = _require_text(entry.get("criterion"), f"rubric {viewpoint} criterion")
            if criterion in seen_criteria:
                raise VisualReviewError(f"duplicate rubric criterion {criterion!r} for {viewpoint}")
            seen_criteria.add(criterion)
            grade = entry.get("grade")
            if isinstance(grade, bool) or not isinstance(grade, int) or not 1 <= grade <= 5:
                raise VisualReviewError(f"rubric grade for {viewpoint}/{criterion} must be an integer 1..5")
            rationale = _require_text(entry.get("rationale"), f"rubric rationale for {viewpoint}/{criterion}")
            shot_ids = _validate_citations(entry.get("evidence"), known_shots, f"rubric {viewpoint}/{criterion}", must_include=viewpoint)
            numeric_grades.append(grade)
            normalized_rubric.append({
                "criterion": criterion,
                "grade": grade,
                "rationale": rationale,
                "evidence": {"shotIds": shot_ids},
            })
        expected = set(request.rubric_by_viewpoint[viewpoint])
        if seen_criteria != expected:
            raise VisualReviewError(
                f"rubric coverage for {viewpoint} differs from requested criteria; "
                f"missing={sorted(expected - seen_criteria)}, extra={sorted(seen_criteria - expected)}"
            )
        by_viewpoint[viewpoint] = {"viewpoint": viewpoint, "rubric": normalized_rubric}

    if set(by_viewpoint) != set(request.rubric_by_viewpoint):
        missing = sorted(set(request.rubric_by_viewpoint) - set(by_viewpoint))
        raise VisualReviewError(f"provider omitted required viewpoint assessments: {missing}")
    if not numeric_grades:
        raise VisualReviewError("provider returned no rubric grades")

    findings_raw = raw.get("findings")
    if not isinstance(findings_raw, list):
        raise VisualReviewError("provider findings must be an array")
    findings: list[dict[str, Any]] = []
    penalty = 0.0
    required_fields = {"severity", "category", "location", "finding", "suggestedAction", "evidence"}
    for index, item in enumerate(findings_raw):
        if not isinstance(item, dict) or set(item) != required_fields:
            raise VisualReviewError(f"finding[{index}] has invalid fields")
        severity = _require_text(item.get("severity"), f"finding[{index}].severity")
        category = _require_text(item.get("category"), f"finding[{index}].category")
        if severity not in SEVERITIES:
            raise VisualReviewError(f"finding[{index}] has invalid severity {severity!r}")
        if category not in CATEGORIES:
            raise VisualReviewError(f"finding[{index}] has invalid category {category!r}")
        shot_ids = _validate_citations(item.get("evidence"), known_shots, f"finding[{index}]")
        normalized = {
            "severity": severity,
            "category": category,
            "location": _require_text(item.get("location"), f"finding[{index}].location"),
            "finding": _require_text(item.get("finding"), f"finding[{index}].finding"),
            "suggestedAction": _require_text(item.get("suggestedAction"), f"finding[{index}].suggestedAction"),
            "evidence": {"shotIds": shot_ids},
        }
        findings.append(normalized)
        penalty += FINDING_PENALTY[severity]

    rubric_average = sum((grade - 1) * 25 for grade in numeric_grades) / len(numeric_grades)
    ordered_assessments = tuple(by_viewpoint[name] for name in request.rubric_by_viewpoint)
    return ordered_assessments, tuple(findings), round(rubric_average, 1), round(penalty, 1)


def review_captures(
    manifest: dict[str, Any],
    capture_directory: Path,
    rubric_by_viewpoint: Mapping[str, list[str] | tuple[str, ...]],
    provider: VisionProvider,
    *,
    prompt: str = DEFAULT_PROMPT,
    output_directory: Path | None = None,
) -> VisualReview:
    """Validate capture lineage, invoke a provider, then derive the score."""

    request = _capture_request(manifest, capture_directory, rubric_by_viewpoint, prompt)
    provider_name = _require_text(getattr(provider, "name", None), "provider.name")
    model = _require_text(getattr(provider, "model", None), "provider.model")
    try:
        # Adapters receive a deep copy: vendor glue cannot mutate the rubric or
        # response schema the engine later uses to validate and stamp evidence.
        raw = provider.review(copy.deepcopy(request))
    except VisualReviewError:
        raise
    except Exception as exc:
        raise VisualReviewError(f"vision provider failed: {type(exc).__name__}: {exc}") from exc
    assessments, findings, rubric_average, penalty = _validate_provider_result(raw, request)
    score = rubric_average
    review = VisualReview(
        run_id=request.run_id,
        build_hash=request.build_hash,
        place_hash=request.place_hash,
        spec_hash=request.spec_hash,
        capture_manifest_sha256=request.capture_manifest_sha256,
        provider=provider_name,
        model=model,
        model_hash=_canonical_hash({"provider": provider_name, "model": model}),
        prompt_hash=request.prompt_hash,
        assessments=assessments,
        findings=findings,
        score=score,
        rubric_average=rubric_average,
        finding_penalty=penalty,
        created_at=_now(),
    )
    if output_directory is not None:
        _atomic_json(output_directory / "request.json", request.to_dict())
        _atomic_json(output_directory / "review.json", review.to_dict())
    return review
