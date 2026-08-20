"""Compile a game contract into an explicit, fail-closed measurement plan.

The legacy audit asks whichever probes happen to be registered and scores what
comes back.  That makes absence of evidence invisible.  A release does the
opposite: it first records every fact that must be proven, then matches evidence
to that plan.  Missing work therefore remains visible and scores zero.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

from .models import VALIDATION_LEVELS
from .project import Project, read_json
from .probe_registry import ProbeRegistry, load_probe_registry
from .provenance import sha256_file
from .visual_spec import load_visual_spec


class MeasurementPlanError(ValueError):
    pass


DEFAULT_LEVEL_BY_TYPE = {
    "structural": "STATICALLY_VALIDATED",
    "security": "STATICALLY_VALIDATED",
    "geometry": "RUNTIME_VALIDATED",
    "navigation": "RUNTIME_VALIDATED",
    "runtime": "RUNTIME_VALIDATED",
    "performance": "RUNTIME_VALIDATED",
    "visual": "VISUALLY_VALIDATED",
    "ui": "VISUALLY_VALIDATED",
    "scenario": "E2E_VALIDATED",
    "gameplay": "E2E_VALIDATED",
    "persistence": "E2E_VALIDATED",
    "multiplayer": "E2E_VALIDATED",
}

CATEGORY_BY_TYPE = {"scenario": "gameplay"}


@dataclass(frozen=True)
class MeasurementRequirement:
    id: str
    probe: str
    category: str
    severity: str
    minimum_validation_level: str
    minimum_coverage: float = 1.0
    allowed_sources: tuple[str, ...] = ()
    maximum_age_seconds: float = 3600.0
    producer_status: str = "AVAILABLE"
    producer_ids: tuple[str, ...] = ()
    producer_reasons: tuple[str, ...] = ()

    def to_dict(self) -> dict[str, Any]:
        return {
            "id": self.id,
            "probe": self.probe,
            "category": self.category,
            "severity": self.severity,
            "minimumValidationLevel": self.minimum_validation_level,
            "minimumCoverage": self.minimum_coverage,
            "allowedSources": list(self.allowed_sources),
            "maximumAgeSeconds": self.maximum_age_seconds,
            "producerStatus": self.producer_status,
            "producerIds": list(self.producer_ids),
            "producerReasons": list(self.producer_reasons),
        }


@dataclass(frozen=True)
class MeasurementPlan:
    schema_version: int
    contract_path: str
    requirements: tuple[MeasurementRequirement, ...]
    required_categories: tuple[str, ...]
    target_scores: dict[str, float]
    minimum_category_coverage: dict[str, float]
    forbidden_sources: tuple[str, ...]
    minimum_visual_score: float
    maximum_age_seconds_by_level: dict[str, float]
    require_trustworthy_captures: bool = True
    metadata: dict[str, Any] = field(default_factory=dict)

    def to_dict(self) -> dict[str, Any]:
        return {
            "schemaVersion": self.schema_version,
            "contractPath": self.contract_path,
            "requirements": [item.to_dict() for item in self.requirements],
            "requiredCategories": list(self.required_categories),
            "targetScores": self.target_scores,
            "minimumCategoryCoverage": self.minimum_category_coverage,
            "forbiddenSources": list(self.forbidden_sources),
            "minimumVisualScore": self.minimum_visual_score,
            "maximumAgeSecondsByLevel": self.maximum_age_seconds_by_level,
            "requireTrustworthyCaptures": self.require_trustworthy_captures,
            "metadata": self.metadata,
        }


def _number(value: Any, label: str, minimum: float = 0.0, maximum: float | None = None) -> float:
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        raise MeasurementPlanError(f"{label} must be a number")
    result = float(value)
    if result < minimum or (maximum is not None and result > maximum):
        upper = f" and <= {maximum}" if maximum is not None else ""
        raise MeasurementPlanError(f"{label} must be >= {minimum}{upper}")
    return result


def _quality_focus(project: Project) -> tuple[Path, dict[str, Any]]:
    relative = project.config.get("qualityFocus")
    if not isinstance(relative, str) or not relative:
        raise MeasurementPlanError("rqe.project.json must name qualityFocus")
    path = project.root / relative
    return path, read_json(path)


def compile_measurement_plan(project: Project) -> MeasurementPlan:
    """Turn the contract and quality policy into the complete release checklist."""

    focus_path, focus = _quality_focus(project)
    policy = project.contract.get("release_gate", {})
    if not isinstance(policy, dict):
        raise MeasurementPlanError("contract.release_gate must be an object")

    level_by_type = dict(DEFAULT_LEVEL_BY_TYPE)
    configured_levels = policy.get("minimum_validation_by_type", {})
    if not isinstance(configured_levels, dict):
        raise MeasurementPlanError("release_gate.minimum_validation_by_type must be an object")
    level_by_type.update({str(key): str(value) for key, value in configured_levels.items()})

    default_coverage = _number(
        policy.get("minimum_requirement_coverage", 1.0),
        "release_gate.minimum_requirement_coverage",
        0,
        1,
    )
    raw_age_by_level = policy.get("maximum_evidence_age_seconds_by_level")
    if not isinstance(raw_age_by_level, dict):
        raise MeasurementPlanError(
            "release_gate.maximum_evidence_age_seconds_by_level must be an object"
        )
    positive_levels = tuple(VALIDATION_LEVELS[1:])
    if set(raw_age_by_level) != set(positive_levels):
        raise MeasurementPlanError(
            "release_gate.maximum_evidence_age_seconds_by_level must define exactly "
            + ", ".join(positive_levels)
        )
    age_by_level = {
        level: _number(
            raw_age_by_level[level],
            f"release_gate.maximum_evidence_age_seconds_by_level.{level}",
            1,
        )
        for level in positive_levels
    }

    registry: ProbeRegistry = load_probe_registry(project)
    requirements: list[MeasurementRequirement] = []
    for index, raw in enumerate(project.contract.get("requirements", [])):
        if not isinstance(raw, dict):
            raise MeasurementPlanError(f"requirements[{index}] must be an object")
        kind = str(raw.get("type") or "")
        validation = raw.get("validation", {})
        if not isinstance(validation, dict):
            raise MeasurementPlanError(f"requirements[{index}].validation must be an object")
        minimum_level = str(validation.get("minimum_level") or level_by_type.get(kind, ""))
        if minimum_level not in VALIDATION_LEVELS or minimum_level == "NOT_VALIDATED":
            raise MeasurementPlanError(
                f"requirements[{index}] has no valid positive validation level for type {kind!r}"
            )
        allowed = validation.get("allowed_sources", [])
        if not isinstance(allowed, list) or any(not isinstance(item, str) or not item for item in allowed):
            raise MeasurementPlanError(f"requirements[{index}].validation.allowed_sources must be strings")
        probe = str(raw.get("probe") or "")
        allowed_sources = tuple(allowed)
        producer = registry.resolve(
            probe,
            minimum_validation_level=minimum_level,
            allowed_sources=allowed_sources,
        )
        requirements.append(MeasurementRequirement(
            id=str(raw.get("id") or ""),
            probe=probe,
            category=str(raw.get("category") or CATEGORY_BY_TYPE.get(kind, kind)),
            severity=str(raw.get("severity") or "major"),
            minimum_validation_level=minimum_level,
            minimum_coverage=_number(
                validation.get("minimum_coverage", default_coverage),
                f"requirements[{index}].validation.minimum_coverage",
                0,
                1,
            ),
            allowed_sources=allowed_sources,
            maximum_age_seconds=_number(
                validation.get("maximum_age_seconds", age_by_level[minimum_level]),
                f"requirements[{index}].validation.maximum_age_seconds",
                1,
            ),
            producer_status=producer.status,
            producer_ids=producer.producer_ids,
            producer_reasons=producer.reasons,
        ))

    visual_spec = load_visual_spec(project)
    visual_release = project.contract.get("visualQuality", {}).get("release", {})
    visual_rule_coverage = _number(
        visual_release.get("minimumRuleCoverage", 1.0),
        "visualQuality.release.minimumRuleCoverage",
        0,
        1,
    )
    for rule in visual_spec.rules:
        producer = registry.resolve(
            rule.probe,
            minimum_validation_level=rule.minimum_validation_level,
            allowed_sources=rule.allowed_sources,
        )
        requirements.append(MeasurementRequirement(
            id=rule.id,
            probe=rule.probe,
            category="visual",
            severity=rule.severity,
            minimum_validation_level=rule.minimum_validation_level,
            minimum_coverage=visual_rule_coverage,
            allowed_sources=rule.allowed_sources,
            maximum_age_seconds=age_by_level[rule.minimum_validation_level],
            producer_status=producer.status,
            producer_ids=producer.producer_ids,
            producer_reasons=producer.reasons,
        ))

    requirement_ids = [item.id for item in requirements]
    if len(requirement_ids) != len(set(requirement_ids)):
        raise MeasurementPlanError("contract and visual spec produced duplicate requirement ids")

    domains = focus.get("domains", {})
    if not isinstance(domains, dict) or not domains:
        raise MeasurementPlanError(f"{focus_path} must define non-empty domains")
    target_scores: dict[str, float] = {}
    category_coverage: dict[str, float] = {}
    configured_category_coverage = policy.get("minimum_category_coverage", {})
    if not isinstance(configured_category_coverage, dict):
        raise MeasurementPlanError("release_gate.minimum_category_coverage must be an object")
    for category, raw in domains.items():
        if not isinstance(raw, dict):
            raise MeasurementPlanError(f"quality domain {category!r} must be an object")
        target_scores[str(category)] = _number(raw.get("targetScore"), f"domains.{category}.targetScore", 0, 100)
        category_coverage[str(category)] = _number(
            configured_category_coverage.get(category, 1.0),
            f"release_gate.minimum_category_coverage.{category}",
            0,
            1,
        )

    requested_categories = policy.get("required_categories", list(domains))
    if not isinstance(requested_categories, list) or any(not isinstance(item, str) for item in requested_categories):
        raise MeasurementPlanError("release_gate.required_categories must be an array of strings")
    unknown_categories = sorted(set(requested_categories) - set(domains))
    if unknown_categories:
        raise MeasurementPlanError(f"required categories have no quality target: {', '.join(unknown_categories)}")
    planned_categories = {item.category for item in requirements}
    unplanned_categories = sorted(set(requested_categories) - planned_categories)
    if unplanned_categories:
        raise MeasurementPlanError(
            "required categories have no enumerated requirements: "
            + ", ".join(unplanned_categories)
        )

    forbidden = policy.get("forbidden_sources", ["headless-runtime"])
    if not isinstance(forbidden, list) or any(not isinstance(item, str) or not item for item in forbidden):
        raise MeasurementPlanError("release_gate.forbidden_sources must be an array of strings")

    visual_review = focus.get("visualReview", {})
    if not isinstance(visual_review, dict):
        raise MeasurementPlanError("qualityFocus.visualReview must be an object")
    minimum_visual = _number(
        policy.get("minimum_visual_score", visual_review.get("minimumRawVisualScore", 95)),
        "minimum visual score",
        0,
        100,
    )

    contract_relative = project.config.get("contract", "contracts/mining-tycoon.robloxqa.json")
    orphans = [
        {
            "requirementId": item.id,
            "probe": item.probe,
            "producerIds": list(item.producer_ids),
            "reasons": list(item.producer_reasons),
        }
        for item in requirements
        if item.producer_status != "AVAILABLE"
    ]
    return MeasurementPlan(
        schema_version=1,
        contract_path=str(contract_relative).replace("\\", "/"),
        requirements=tuple(requirements),
        required_categories=tuple(requested_categories),
        target_scores=target_scores,
        minimum_category_coverage=category_coverage,
        forbidden_sources=tuple(forbidden),
        minimum_visual_score=minimum_visual,
        maximum_age_seconds_by_level=age_by_level,
        require_trustworthy_captures=bool(policy.get("require_trustworthy_captures", True)),
        metadata={
            "qualityFocus": str(focus_path.relative_to(project.root)).replace("\\", "/"),
            "contractName": project.contract.get("game", {}).get("name"),
            "probeRegistry": {
                "path": registry.path.relative_to(project.root).as_posix(),
                "registryId": registry.registry_id,
                "sha256": sha256_file(registry.path),
                "requirements": len(requirements),
                "available": len(requirements) - len(orphans),
                "orphans": orphans,
            },
            "visualSpec": {
                **visual_spec.to_plan_metadata(project.root),
                "sha256": sha256_file(visual_spec.path),
            },
            "tokenConformance": _token_conformance(project, visual_spec),
        },
    )


def _token_conformance(project: Project, visual_spec: Any) -> dict[str, Any]:
    """Prove the visual spec's numbers were projected from a token set.

    The thresholds a spec asserts have to come from somewhere. When they are
    typed by hand while looking at the candidate, the spec describes the build it
    is grading and passes by construction -- which is precisely what
    ``building.minimumSize [8, 6, 8]`` was, next to a token grammar that derives
    ``[24, 18, 24]``.

    Reported rather than enforced here: the plan records what conforms and what
    does not, and the gate decides. A project that has not adopted tokens yet is
    ``NOT_DECLARED``, which is honest and visible -- not a silent pass.
    """

    relative = project.config.get("tokenSet")
    if not isinstance(relative, str) or not relative:
        return {
            "status": "NOT_DECLARED",
            "detail": "rqe.project.json does not name a tokenSet, so no visual threshold has a traceable author",
        }

    from .token_conformance import check
    from .tokens import TokenError, load_token_set

    try:
        tokens = load_token_set(project.root, relative)
    except TokenError as exc:
        return {"status": "INVALID", "detail": str(exc)}

    report = check(visual_spec.data, tokens)
    return {
        "status": "CONFORMS" if report.conforms else "DIVERGENT",
        "tokenSet": relative,
        **report.to_dict(),
    }
