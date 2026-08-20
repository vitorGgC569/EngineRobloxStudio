"""Load, validate and compile the executable visual-quality contract."""

from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path
from typing import Any

from .project import Project, read_json
from .schema_validation import SchemaDefinitionError, validate_schema_instance


class VisualSpecError(ValueError):
    pass


@dataclass(frozen=True)
class VisualRule:
    id: str
    probe: str
    minimum_validation_level: str
    allowed_sources: tuple[str, ...]
    severity: str = "major"

    def to_dict(self) -> dict[str, Any]:
        return {
            "id": self.id,
            "probe": self.probe,
            "minimumValidationLevel": self.minimum_validation_level,
            "allowedSources": list(self.allowed_sources),
            "severity": self.severity,
        }


@dataclass(frozen=True)
class VisualQualitySpec:
    path: Path
    schema_path: Path
    data: dict[str, Any]
    rules: tuple[VisualRule, ...]

    @property
    def spec_id(self) -> str:
        return str(self.data["specId"])

    @property
    def revision(self) -> int:
        return int(self.data["revision"])

    def to_plan_metadata(self, root: Path) -> dict[str, Any]:
        return {
            "path": self.path.relative_to(root).as_posix(),
            "schemaPath": self.schema_path.relative_to(root).as_posix(),
            "specId": self.spec_id,
            "revision": self.revision,
            "ruleCount": len(self.rules),
            "rules": [rule.to_dict() for rule in self.rules],
        }


def _resolve_inside(root: Path, base: Path, relative: Any, label: str) -> Path:
    if not isinstance(relative, str) or not relative:
        raise VisualSpecError(f"{label} must be a non-empty relative path")
    requested = Path(relative)
    if requested.is_absolute():
        raise VisualSpecError(f"{label} must be relative")
    root = root.resolve()
    path = (base / requested).resolve()
    try:
        path.relative_to(root)
    except ValueError as exc:
        raise VisualSpecError(f"{label} escapes the project root") from exc
    if path.is_symlink():
        raise VisualSpecError(f"{label} must not be a symlink")
    if not path.is_file():
        raise VisualSpecError(f"{label} does not exist: {path}")
    return path


def _semantic_issues(project: Project, data: dict[str, Any]) -> list[str]:
    issues: list[str] = []

    swatches = data.get("palette", {}).get("swatches", [])
    swatch_ids = [item.get("id") for item in swatches if isinstance(item, dict)]
    if len(swatch_ids) != len(set(swatch_ids)):
        issues.append("palette swatch ids must be unique")

    for type_id, definition in data.get("objectTypes", {}).items():
        minimum = definition.get("minimumInstances")
        maximum = definition.get("maximumInstances")
        if maximum is not None and minimum is not None and minimum > maximum:
            issues.append(f"objectTypes.{type_id} minimumInstances exceeds maximumInstances")
        scale = definition.get("scale", {})
        minimum_size = scale.get("minimumSize", [])
        maximum_size = scale.get("maximumSize", [])
        if len(minimum_size) == len(maximum_size) == 3:
            for axis, (low, high) in enumerate(zip(minimum_size, maximum_size)):
                if low > high:
                    issues.append(f"objectTypes.{type_id}.scale axis {axis} minimum exceeds maximum")

    profiles = data.get("regionProfiles", {})
    for profile_id, profile in profiles.items():
        density = profile.get("density", {})
        if density.get("minimumRootsPer1000SquareStuds", 0) > density.get("maximumRootsPer1000SquareStuds", 0):
            issues.append(f"regionProfiles.{profile_id}.density minimum exceeds maximum")
        heights = profile.get("heightVariation", {})
        if heights.get("minimumP90MinusP10", 0) > heights.get("maximumP90MinusP10", 0):
            issues.append(f"regionProfiles.{profile_id}.heightVariation minimum exceeds maximum")

    for set_id, region_set in data.get("regionSets", {}).items():
        profile = region_set.get("profile")
        if profile not in profiles:
            issues.append(f"regionSets.{set_id}.profile references unknown profile {profile!r}")
        if region_set.get("minimumRegions", 0) > region_set.get("maximumRegions", 0):
            issues.append(f"regionSets.{set_id} minimumRegions exceeds maximumRegions")

    landmarks = data.get("landmarks", {})
    states = data.get("evaluationStates", {})
    viewpoints = data.get("viewpoints", {})
    for viewpoint_id, viewpoint in viewpoints.items():
        landmark = viewpoint.get("landmark")
        state = viewpoint.get("state")
        if landmark not in landmarks:
            issues.append(f"viewpoints.{viewpoint_id}.landmark references unknown landmark {landmark!r}")
        if state not in states:
            issues.append(f"viewpoints.{viewpoint_id}.state references unknown state {state!r}")
        rubric = viewpoint.get("rubric", {})
        if rubric and abs(sum(rubric.values()) - 1.0) > 1e-9:
            issues.append(f"viewpoints.{viewpoint_id}.rubric weights must sum to 1")

    covered: set[str] = set()
    for state_id, state in states.items():
        for viewpoint_id in state.get("requiredViewpoints", []):
            if viewpoint_id not in viewpoints:
                issues.append(f"evaluationStates.{state_id} references unknown viewpoint {viewpoint_id!r}")
                continue
            covered.add(viewpoint_id)
            if viewpoints[viewpoint_id].get("state") != state_id:
                issues.append(
                    f"evaluationStates.{state_id} includes viewpoint {viewpoint_id!r} declared for "
                    f"state {viewpoints[viewpoint_id].get('state')!r}"
                )
        scenario = state.get("scenario")
        try:
            _resolve_inside(project.root, project.root, scenario, f"evaluationStates.{state_id}.scenario")
        except VisualSpecError as exc:
            issues.append(str(exc))
    missing_state_coverage = sorted(set(viewpoints) - covered)
    if missing_state_coverage:
        issues.append(f"viewpoints missing from evaluation states: {', '.join(missing_state_coverage)}")

    focus_path = _resolve_inside(
        project.root,
        project.root,
        project.config.get("qualityFocus"),
        "rqe.project.json qualityFocus",
    )
    focus = read_json(focus_path)
    required_snapshots = focus.get("visualReview", {}).get("requiredSnapshots", [])
    if not isinstance(required_snapshots, list):
        issues.append("qualityFocus.visualReview.requiredSnapshots must be an array")
    else:
        missing = sorted(set(required_snapshots) - set(viewpoints))
        if missing:
            issues.append(f"required visual snapshots have no deterministic viewpoint: {', '.join(missing)}")

    target_devices = set(project.contract.get("game", {}).get("target_devices", []))
    viewpoint_devices = {item.get("device") for item in viewpoints.values()}
    missing_devices = sorted(target_devices - viewpoint_devices)
    if missing_devices:
        issues.append(f"target devices have no visual viewpoint: {', '.join(missing_devices)}")
    return issues


def compile_visual_rules(data: dict[str, Any]) -> tuple[VisualRule, ...]:
    """Expand the visual contract so absence of any rule remains measurable."""

    rules: list[VisualRule] = [
        VisualRule("visual_classification_coverage", "visual.classification.coverage", "RUNTIME_VALIDATED", ("studio-quality-validator",), "critical"),
        VisualRule("visual_palette_conformance", "visual.palette.conformance", "RUNTIME_VALIDATED", ("studio-quality-validator",)),
    ]
    for type_id in sorted(data["objectTypes"]):
        rules.extend((
            VisualRule(f"visual_object_{type_id}_cardinality", f"visual.object.{type_id}.cardinality", "RUNTIME_VALIDATED", ("studio-quality-validator",)),
            VisualRule(f"visual_object_{type_id}_scale", f"visual.object.{type_id}.scale", "RUNTIME_VALIDATED", ("studio-quality-validator",)),
        ))
    for set_id in sorted(data["regionSets"]):
        rules.append(VisualRule(
            f"visual_region_{set_id}_cardinality",
            f"visual.region.{set_id}.cardinality",
            "RUNTIME_VALIDATED",
            ("studio-quality-validator",),
        ))
        for metric in ("density", "height-variation", "material-variety", "repetition"):
            rules.append(VisualRule(
                f"visual_region_{set_id}_{metric.replace('-', '_')}",
                f"visual.region.{set_id}.{metric}",
                "RUNTIME_VALIDATED",
                ("studio-quality-validator",),
            ))
    for landmark_id in sorted(data["landmarks"]):
        rules.append(VisualRule(
            f"visual_landmark_{landmark_id}_visibility",
            f"visual.landmark.{landmark_id}.visibility",
            "RUNTIME_VALIDATED",
            ("studio-quality-validator",),
        ))
    for viewpoint_id in sorted(data["viewpoints"]):
        rules.extend((
            VisualRule(
                f"visual_viewpoint_{viewpoint_id}_capture",
                f"visual.viewpoint.{viewpoint_id}.capture",
                "VISUALLY_VALIDATED",
                ("studio-capture",),
                "critical",
            ),
            VisualRule(
                f"visual_viewpoint_{viewpoint_id}_review",
                f"visual.viewpoint.{viewpoint_id}.review",
                "VISUALLY_VALIDATED",
                ("visual-review",),
                "critical",
            ),
        ))
    for state_id in sorted(data["evaluationStates"]):
        rules.append(VisualRule(
            f"visual_state_{state_id}_coverage",
            f"visual.state.{state_id}.coverage",
            "VISUALLY_VALIDATED",
            ("visual-review",),
            "critical",
        ))
    return tuple(rules)


def load_visual_spec(project: Project) -> VisualQualitySpec:
    visual = project.contract.get("visualQuality")
    if not isinstance(visual, dict):
        raise VisualSpecError("contract.visualQuality must be an object")
    path = _resolve_inside(project.root, project.contract_path.parent, visual.get("spec"), "visualQuality.spec")
    data = read_json(path)
    schema_path = _resolve_inside(project.root, path.parent, data.get("$schema"), "visual spec $schema")
    schema = read_json(schema_path)
    try:
        schema_issues = validate_schema_instance(data, schema)
    except SchemaDefinitionError as exc:
        raise VisualSpecError(f"invalid visual schema definition: {exc}") from exc
    issues = [str(issue) for issue in schema_issues]
    if data.get("specId") != visual.get("specId"):
        issues.append("visual spec specId does not match contract.visualQuality.specId")
    if data.get("schemaVersion") != visual.get("schemaMajor"):
        issues.append("visual spec schemaVersion does not match contract.visualQuality.schemaMajor")
    issues.extend(_semantic_issues(project, data))
    if issues:
        raise VisualSpecError("visual quality spec is invalid:\n- " + "\n- ".join(issues))
    return VisualQualitySpec(path=path, schema_path=schema_path, data=data, rules=compile_visual_rules(data))

