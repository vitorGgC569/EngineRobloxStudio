"""Declarative, multi-project production blueprints for the RQE engine.

This module is deliberately a planner, not a game generator.  It validates the
boundary between engine-owned code and product-owned inputs/outputs, then emits
a deterministic task DAG.  No task is executed and no game source is written
while compiling a blueprint.
"""

from __future__ import annotations

import hashlib
import json
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Iterable, Mapping

from rqe.schema_validation import SchemaDefinitionError, validate_schema_instance

from .dag import TaskGraph, TaskGraphError
from .models import CampaignStage, TaskSpec
from .ownership import OwnershipConflict, OwnershipRegistry, canonical_write_path


STATIC_VALIDATION_LEVEL = "STATICALLY_VALIDATED"
GAME_PROJECT_SCHEMA = "game-project-definition.v1.schema.json"
PRODUCTION_BLUEPRINT_SCHEMA = "production-blueprint.v1.schema.json"
PRODUCTION_PLAN_SCHEMA = "production-plan.v1.schema.json"

OUTPUT_KINDS = frozenset(
    {
        "PRODUCTION_PLAN",
        "SOURCE_BUNDLE",
        "ASSET_MANIFEST",
        "BUILD_PLACE",
        "INTEGRATION_MANIFEST",
        "MEASUREMENT_RUN",
        "SCENARIO_RESULTS",
        "CAPTURE_BUNDLE",
        "QUALITY_REVIEW",
        "REPAIR_PLAN",
        "REGRESSION_RUN",
        "RELEASE_CANDIDATE",
    }
)


class BlueprintError(ValueError):
    """A blueprint cannot safely be compiled into production work."""


def _repository_root() -> Path:
    return Path(__file__).resolve().parents[2]


def _canonical_json(value: Any) -> bytes:
    return json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode("utf-8")


def _sha256_json(value: Any) -> str:
    return hashlib.sha256(_canonical_json(value)).hexdigest()


def _read_json(path: Path, label: str) -> dict[str, Any]:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise BlueprintError(f"cannot read {label} {path}: {exc}") from exc
    if not isinstance(value, dict):
        raise BlueprintError(f"{label} root must be an object")
    return value


def _validate_shape(raw: Mapping[str, Any], schema_path: Path, label: str) -> None:
    schema = _read_json(schema_path, f"{label} schema")
    try:
        issues = validate_schema_instance(dict(raw), schema)
    except SchemaDefinitionError as exc:
        raise BlueprintError(f"invalid {label} schema: {exc}") from exc
    if issues:
        rendered = "; ".join(str(issue) for issue in issues)
        raise BlueprintError(f"invalid {label}: {rendered}")


def _unique(items: Iterable[str], label: str) -> None:
    values = tuple(items)
    duplicates = sorted({value for value in values if values.count(value) > 1})
    if duplicates:
        raise BlueprintError(f"duplicate {label}: {', '.join(duplicates)}")


def _path_parts(value: str) -> tuple[str, ...]:
    return tuple(canonical_write_path(value).split("/"))


def _paths_overlap(left: str, right: str) -> bool:
    left_parts = _path_parts(left)
    right_parts = _path_parts(right)
    length = min(len(left_parts), len(right_parts))
    return left_parts[:length] == right_parts[:length]


def _is_within(path: str, root: str) -> bool:
    path_parts = _path_parts(path)
    root_parts = _path_parts(root)
    return len(path_parts) >= len(root_parts) and path_parts[: len(root_parts)] == root_parts


def _join(root: str, *parts: str) -> str:
    suffix = "/".join(part.strip("/\\") for part in parts if part.strip("/\\"))
    return canonical_write_path(f"{root}/{suffix}" if suffix else root)


@dataclass(frozen=True)
class InputArtifactRef:
    product_id: str
    artifact_id: str
    kind: str
    path: str
    sha256: str

    @classmethod
    def from_raw(cls, raw: Mapping[str, Any]) -> "InputArtifactRef":
        return cls(
            product_id=str(raw["productId"]),
            artifact_id=str(raw["artifactId"]),
            kind=str(raw["kind"]),
            path=canonical_write_path(str(raw["path"])),
            sha256=str(raw["sha256"]),
        )

    def to_dict(self) -> dict[str, Any]:
        return {
            "productId": self.product_id,
            "artifactId": self.artifact_id,
            "kind": self.kind,
            "path": self.path,
            "sha256": self.sha256,
        }


@dataclass(frozen=True)
class OutputArtifactRef:
    product_id: str
    artifact_id: str
    kind: str
    path: str

    @classmethod
    def from_raw(cls, raw: Mapping[str, Any]) -> "OutputArtifactRef":
        return cls(
            product_id=str(raw["productId"]),
            artifact_id=str(raw["artifactId"]),
            kind=str(raw["kind"]),
            path=canonical_write_path(str(raw["path"])),
        )

    def to_dict(self) -> dict[str, Any]:
        return {
            "productId": self.product_id,
            "artifactId": self.artifact_id,
            "kind": self.kind,
            "path": self.path,
        }


@dataclass(frozen=True)
class SubsystemDefinition:
    id: str
    capability: str
    dependencies: tuple[str, ...]

    def to_dict(self) -> dict[str, Any]:
        return {"id": self.id, "capability": self.capability, "dependencies": list(self.dependencies)}


@dataclass(frozen=True)
class OwnershipRule:
    subsystem_id: str
    owner_role: str
    write_roots: tuple[str, ...]

    def to_dict(self) -> dict[str, Any]:
        return {
            "subsystemId": self.subsystem_id,
            "ownerRole": self.owner_role,
            "writeRoots": list(self.write_roots),
        }


@dataclass(frozen=True)
class DeviceDefinition:
    id: str
    viewport_width: int
    viewport_height: int
    input_modes: tuple[str, ...]

    def to_dict(self) -> dict[str, Any]:
        return {
            "id": self.id,
            "viewportWidth": self.viewport_width,
            "viewportHeight": self.viewport_height,
            "inputModes": list(self.input_modes),
        }


@dataclass(frozen=True)
class ViewpointDefinition:
    id: str
    purpose: str
    camera_mode: str

    def to_dict(self) -> dict[str, Any]:
        return {"id": self.id, "purpose": self.purpose, "cameraMode": self.camera_mode}


@dataclass(frozen=True, order=True)
class CaptureCombination:
    device_id: str
    viewpoint_id: str

    def to_dict(self) -> dict[str, Any]:
        return {"deviceId": self.device_id, "viewpointId": self.viewpoint_id}


@dataclass(frozen=True)
class DeviceViewpointMatrix:
    devices: tuple[DeviceDefinition, ...]
    viewpoints: tuple[ViewpointDefinition, ...]
    combinations: tuple[CaptureCombination, ...]

    def to_dict(self) -> dict[str, Any]:
        return {
            "devices": [item.to_dict() for item in self.devices],
            "viewpoints": [item.to_dict() for item in self.viewpoints],
            "combinations": [item.to_dict() for item in self.combinations],
        }


@dataclass(frozen=True)
class ScenarioClassDefinition:
    id: str
    scenario_class: str
    required_for_release: bool
    actor_profile: str

    def to_dict(self) -> dict[str, Any]:
        return {
            "id": self.id,
            "class": self.scenario_class,
            "requiredForRelease": self.required_for_release,
            "actorProfile": self.actor_profile,
        }


@dataclass(frozen=True)
class AssetNeedDefinition:
    id: str
    asset_type: str
    strategy: str
    required_for_release: bool
    consumers: tuple[str, ...]
    acceptance_profile_id: str | None = None

    def to_dict(self) -> dict[str, Any]:
        payload: dict[str, Any] = {
            "id": self.id,
            "type": self.asset_type,
            "strategy": self.strategy,
            "requiredForRelease": self.required_for_release,
            "consumers": list(self.consumers),
        }
        if self.acceptance_profile_id is not None:
            payload["acceptanceProfileId"] = self.acceptance_profile_id
        return payload


@dataclass(frozen=True)
class QualityProfileDefinition:
    id: str
    required_for_release: bool
    applies_to: tuple[str, ...]
    input_ref: InputArtifactRef

    def to_dict(self) -> dict[str, Any]:
        return {
            "id": self.id,
            "requiredForRelease": self.required_for_release,
            "appliesTo": list(self.applies_to),
            "inputRef": self.input_ref.to_dict(),
        }


@dataclass(frozen=True)
class GameProjectDefinition:
    """All product-owned inputs required to plan one isolated game."""

    project_id: str
    product_id: str
    revision: str
    seed: int
    source_root: str
    artifact_root: str
    product_intent_ref: InputArtifactRef
    reference_bundle_ref: InputArtifactRef
    subsystems: tuple[SubsystemDefinition, ...]
    ownership: tuple[OwnershipRule, ...]
    device_viewpoint_matrix: DeviceViewpointMatrix
    scenario_classes: tuple[ScenarioClassDefinition, ...]
    asset_needs: tuple[AssetNeedDefinition, ...]
    quality_profiles: tuple[QualityProfileDefinition, ...]
    output_artifact_refs: tuple[OutputArtifactRef, ...]
    genre: str | None = None
    template_id: str | None = None
    schema_version: int = field(default=1, init=False)

    @classmethod
    def from_dict(
        cls,
        raw: Mapping[str, Any],
        *,
        schema_path: Path | None = None,
    ) -> "GameProjectDefinition":
        path = schema_path or _repository_root() / "schemas" / GAME_PROJECT_SCHEMA
        _validate_shape(raw, path, "game project definition")

        subsystems = tuple(
            sorted(
                (
                    SubsystemDefinition(
                        id=str(item["id"]),
                        capability=str(item["capability"]),
                        dependencies=tuple(sorted(str(value) for value in item["dependencies"])),
                    )
                    for item in raw["subsystems"]
                ),
                key=lambda item: item.id,
            )
        )
        ownership = tuple(
            sorted(
                (
                    OwnershipRule(
                        subsystem_id=str(item["subsystemId"]),
                        owner_role=str(item["ownerRole"]),
                        write_roots=tuple(sorted(canonical_write_path(str(value)) for value in item["writeRoots"])),
                    )
                    for item in raw["ownership"]
                ),
                key=lambda item: item.subsystem_id,
            )
        )
        matrix_raw = raw["deviceViewpointMatrix"]
        matrix = DeviceViewpointMatrix(
            devices=tuple(
                sorted(
                    (
                        DeviceDefinition(
                            id=str(item["id"]),
                            viewport_width=int(item["viewportWidth"]),
                            viewport_height=int(item["viewportHeight"]),
                            input_modes=tuple(sorted(str(value) for value in item["inputModes"])),
                        )
                        for item in matrix_raw["devices"]
                    ),
                    key=lambda item: item.id,
                )
            ),
            viewpoints=tuple(
                sorted(
                    (
                        ViewpointDefinition(
                            id=str(item["id"]),
                            purpose=str(item["purpose"]),
                            camera_mode=str(item["cameraMode"]),
                        )
                        for item in matrix_raw["viewpoints"]
                    ),
                    key=lambda item: item.id,
                )
            ),
            combinations=tuple(
                sorted(
                    CaptureCombination(
                        device_id=str(item["deviceId"]),
                        viewpoint_id=str(item["viewpointId"]),
                    )
                    for item in matrix_raw["combinations"]
                )
            ),
        )
        scenarios = tuple(
            sorted(
                (
                    ScenarioClassDefinition(
                        id=str(item["id"]),
                        scenario_class=str(item["class"]),
                        required_for_release=bool(item["requiredForRelease"]),
                        actor_profile=str(item["actorProfile"]),
                    )
                    for item in raw["scenarioClasses"]
                ),
                key=lambda item: item.id,
            )
        )
        assets = tuple(
            sorted(
                (
                    AssetNeedDefinition(
                        id=str(item["id"]),
                        asset_type=str(item["type"]),
                        strategy=str(item["strategy"]),
                        required_for_release=bool(item["requiredForRelease"]),
                        consumers=tuple(sorted(str(value) for value in item["consumers"])),
                        acceptance_profile_id=(
                            str(item["acceptanceProfileId"]) if "acceptanceProfileId" in item else None
                        ),
                    )
                    for item in raw["assetNeeds"]
                ),
                key=lambda item: item.id,
            )
        )
        profiles = tuple(
            sorted(
                (
                    QualityProfileDefinition(
                        id=str(item["id"]),
                        required_for_release=bool(item["requiredForRelease"]),
                        applies_to=tuple(sorted(str(value) for value in item["appliesTo"])),
                        input_ref=InputArtifactRef.from_raw(item["inputRef"]),
                    )
                    for item in raw["qualityProfiles"]
                ),
                key=lambda item: item.id,
            )
        )
        outputs = tuple(
            sorted(
                (OutputArtifactRef.from_raw(item) for item in raw["outputArtifactRefs"]),
                key=lambda item: (item.kind, item.artifact_id),
            )
        )
        project = cls(
            project_id=str(raw["projectId"]),
            product_id=str(raw["productId"]),
            revision=str(raw["revision"]),
            seed=int(raw["seed"]),
            genre=str(raw["genre"]) if "genre" in raw else None,
            template_id=str(raw["templateId"]) if "templateId" in raw else None,
            source_root=canonical_write_path(str(raw["sourceRoot"])),
            artifact_root=canonical_write_path(str(raw["artifactRoot"])),
            product_intent_ref=InputArtifactRef.from_raw(raw["productIntentRef"]),
            reference_bundle_ref=InputArtifactRef.from_raw(raw["referenceBundleRef"]),
            subsystems=subsystems,
            ownership=ownership,
            device_viewpoint_matrix=matrix,
            scenario_classes=scenarios,
            asset_needs=assets,
            quality_profiles=profiles,
            output_artifact_refs=outputs,
        )
        project._validate_semantics()
        return project

    def _validate_semantics(self) -> None:
        if _paths_overlap(self.source_root, self.artifact_root):
            raise BlueprintError("project sourceRoot and artifactRoot must not overlap")

        subsystem_ids = tuple(item.id for item in self.subsystems)
        ownership_ids = tuple(item.subsystem_id for item in self.ownership)
        profile_ids = tuple(item.id for item in self.quality_profiles)
        _unique(subsystem_ids, "subsystem id")
        _unique(ownership_ids, "ownership subsystemId")
        _unique((item.id for item in self.scenario_classes), "scenario id")
        _unique((item.id for item in self.asset_needs), "asset need id")
        _unique(profile_ids, "quality profile id")
        _unique((item.id for item in self.device_viewpoint_matrix.devices), "device id")
        _unique((item.id for item in self.device_viewpoint_matrix.viewpoints), "viewpoint id")

        if set(ownership_ids) != set(subsystem_ids):
            missing = sorted(set(subsystem_ids) - set(ownership_ids))
            extras = sorted(set(ownership_ids) - set(subsystem_ids))
            raise BlueprintError(f"ownership must cover every subsystem exactly once; missing={missing}, extras={extras}")

        dependency_graph: dict[str, tuple[str, ...]] = {}
        known_subsystems = set(subsystem_ids)
        for subsystem in self.subsystems:
            unknown = sorted(set(subsystem.dependencies) - known_subsystems)
            if unknown:
                raise BlueprintError(f"subsystem {subsystem.id!r} has unknown dependencies: {', '.join(unknown)}")
            if subsystem.id in subsystem.dependencies:
                raise BlueprintError(f"subsystem {subsystem.id!r} cannot depend on itself")
            dependency_graph[subsystem.id] = subsystem.dependencies
        self._assert_subsystem_graph_acyclic(dependency_graph)

        registry = OwnershipRegistry()
        for rule in self.ownership:
            for root in rule.write_roots:
                if not _is_within(root, self.source_root):
                    raise BlueprintError(
                        f"ownership root {root!r} for {rule.subsystem_id!r} escapes project sourceRoot"
                    )
            for index, left in enumerate(rule.write_roots):
                for right in rule.write_roots[index + 1 :]:
                    if _paths_overlap(left, right):
                        raise BlueprintError(
                            f"ownership roots {left!r} and {right!r} overlap within {rule.subsystem_id!r}"
                        )
            try:
                registry.acquire(f"{self.product_id}.{rule.subsystem_id}", rule.write_roots)
            except OwnershipConflict as exc:
                raise BlueprintError(str(exc)) from exc

        self._validate_input_ref(self.product_intent_ref, "PRODUCT_INTENT", "productIntentRef")
        self._validate_input_ref(self.reference_bundle_ref, "REFERENCE_BUNDLE", "referenceBundleRef")
        for profile in self.quality_profiles:
            self._validate_input_ref(profile.input_ref, "QUALITY_PROFILE", f"quality profile {profile.id!r}")
        if not any(profile.required_for_release for profile in self.quality_profiles):
            raise BlueprintError("at least one quality profile must be required for release")

        output_ids = tuple(item.artifact_id for item in self.output_artifact_refs)
        output_kinds = tuple(item.kind for item in self.output_artifact_refs)
        _unique(output_ids, "output artifact id")
        _unique(output_kinds, "output artifact kind")
        missing_outputs = sorted(OUTPUT_KINDS - set(output_kinds))
        extra_outputs = sorted(set(output_kinds) - OUTPUT_KINDS)
        if missing_outputs or extra_outputs:
            raise BlueprintError(
                f"outputArtifactRefs must bind every production output exactly once; "
                f"missing={missing_outputs}, extras={extra_outputs}"
            )
        for output in self.output_artifact_refs:
            if output.product_id != self.product_id:
                raise BlueprintError(
                    f"output artifact {output.artifact_id!r} belongs to productId "
                    f"{output.product_id!r}, expected {self.product_id!r}"
                )
            if not _is_within(output.path, self.artifact_root):
                raise BlueprintError(f"output artifact {output.artifact_id!r} escapes project artifactRoot")
        output_paths = tuple(item.path for item in self.output_artifact_refs)
        for index, left in enumerate(output_paths):
            for right in output_paths[index + 1 :]:
                if _paths_overlap(left, right):
                    raise BlueprintError(f"output artifact roots must be isolated: {left!r} overlaps {right!r}")

        known_profiles = set(profile_ids)
        for asset in self.asset_needs:
            unknown_consumers = sorted(set(asset.consumers) - known_subsystems)
            if unknown_consumers:
                raise BlueprintError(
                    f"asset need {asset.id!r} has unknown consumers: {', '.join(unknown_consumers)}"
                )
            if asset.acceptance_profile_id is not None and asset.acceptance_profile_id not in known_profiles:
                raise BlueprintError(
                    f"asset need {asset.id!r} has unknown acceptanceProfileId "
                    f"{asset.acceptance_profile_id!r}"
                )

        matrix = self.device_viewpoint_matrix
        device_ids = {item.id for item in matrix.devices}
        viewpoint_ids = {item.id for item in matrix.viewpoints}
        pairs = {(item.device_id, item.viewpoint_id) for item in matrix.combinations}
        if len(pairs) != len(matrix.combinations):
            raise BlueprintError("device/viewpoint matrix has duplicate combinations")
        for combination in matrix.combinations:
            if combination.device_id not in device_ids:
                raise BlueprintError(f"capture combination has unknown deviceId {combination.device_id!r}")
            if combination.viewpoint_id not in viewpoint_ids:
                raise BlueprintError(f"capture combination has unknown viewpointId {combination.viewpoint_id!r}")
        uncovered_devices = sorted(device_ids - {item.device_id for item in matrix.combinations})
        uncovered_viewpoints = sorted(viewpoint_ids - {item.viewpoint_id for item in matrix.combinations})
        if uncovered_devices or uncovered_viewpoints:
            raise BlueprintError(
                f"device/viewpoint matrix leaves entries uncovered; "
                f"devices={uncovered_devices}, viewpoints={uncovered_viewpoints}"
            )
        if not any(item.required_for_release for item in self.scenario_classes):
            raise BlueprintError("at least one scenario class must be required for release")

    def _validate_input_ref(self, ref: InputArtifactRef, kind: str, label: str) -> None:
        if ref.product_id != self.product_id:
            raise BlueprintError(
                f"{label} belongs to productId {ref.product_id!r}, expected {self.product_id!r}"
            )
        if ref.kind != kind:
            raise BlueprintError(f"{label} kind must be {kind}, got {ref.kind}")
        if not (_is_within(ref.path, self.source_root) or _is_within(ref.path, self.artifact_root)):
            raise BlueprintError(f"{label} path escapes this project's sourceRoot/artifactRoot")

    @staticmethod
    def _assert_subsystem_graph_acyclic(graph: Mapping[str, tuple[str, ...]]) -> None:
        visiting: set[str] = set()
        visited: set[str] = set()

        def visit(node: str, trail: tuple[str, ...]) -> None:
            if node in visited:
                return
            if node in visiting:
                raise BlueprintError(f"subsystem dependency cycle: {' -> '.join((*trail, node))}")
            visiting.add(node)
            for dependency in graph[node]:
                visit(dependency, (*trail, node))
            visiting.remove(node)
            visited.add(node)

        for node in sorted(graph):
            visit(node, ())

    @property
    def output_by_kind(self) -> dict[str, OutputArtifactRef]:
        return {item.kind: item for item in self.output_artifact_refs}

    def to_dict(self) -> dict[str, Any]:
        payload: dict[str, Any] = {
            "schemaVersion": self.schema_version,
            "projectId": self.project_id,
            "productId": self.product_id,
            "revision": self.revision,
            "seed": self.seed,
            "sourceRoot": self.source_root,
            "artifactRoot": self.artifact_root,
            "productIntentRef": self.product_intent_ref.to_dict(),
            "referenceBundleRef": self.reference_bundle_ref.to_dict(),
            "subsystems": [item.to_dict() for item in self.subsystems],
            "ownership": [item.to_dict() for item in self.ownership],
            "deviceViewpointMatrix": self.device_viewpoint_matrix.to_dict(),
            "scenarioClasses": [item.to_dict() for item in self.scenario_classes],
            "assetNeeds": [item.to_dict() for item in self.asset_needs],
            "qualityProfiles": [item.to_dict() for item in self.quality_profiles],
            "outputArtifactRefs": [item.to_dict() for item in self.output_artifact_refs],
        }
        if self.genre is not None:
            payload["genre"] = self.genre
        if self.template_id is not None:
            payload["templateId"] = self.template_id
        return payload

    @property
    def sha256(self) -> str:
        return _sha256_json(self.to_dict())


@dataclass(frozen=True)
class EngineDefinition:
    engine_id: str
    version: str
    source_roots: tuple[str, ...]

    def to_dict(self) -> dict[str, Any]:
        return {"engineId": self.engine_id, "version": self.version, "sourceRoots": list(self.source_roots)}


@dataclass(frozen=True)
class ProductionBlueprint:
    """One engine revision plus one or more mutually isolated products."""

    blueprint_id: str
    revision: str
    engine: EngineDefinition
    projects: tuple[GameProjectDefinition, ...]
    schema_version: int = field(default=1, init=False)

    @classmethod
    def from_dict(
        cls,
        raw: Mapping[str, Any],
        *,
        schema_dir: Path | None = None,
    ) -> "ProductionBlueprint":
        schemas = schema_dir or _repository_root() / "schemas"
        _validate_shape(raw, schemas / PRODUCTION_BLUEPRINT_SCHEMA, "production blueprint")
        projects = tuple(
            sorted(
                (
                    GameProjectDefinition.from_dict(item, schema_path=schemas / GAME_PROJECT_SCHEMA)
                    for item in raw["projects"]
                ),
                key=lambda item: (item.product_id, item.project_id),
            )
        )
        engine_raw = raw["engine"]
        engine = EngineDefinition(
            engine_id=str(engine_raw["engineId"]),
            version=str(engine_raw["version"]),
            source_roots=tuple(sorted(canonical_write_path(str(value)) for value in engine_raw["sourceRoots"])),
        )
        blueprint = cls(
            blueprint_id=str(raw["blueprintId"]),
            revision=str(raw["revision"]),
            engine=engine,
            projects=projects,
        )
        blueprint._validate_isolation()
        return blueprint

    def _validate_isolation(self) -> None:
        _unique((item.product_id for item in self.projects), "productId")
        _unique((item.project_id for item in self.projects), "projectId")
        _unique(self.engine.source_roots, "engine source root")

        for project in self.projects:
            for engine_root in self.engine.source_roots:
                if _paths_overlap(project.source_root, engine_root):
                    raise BlueprintError(
                        f"project {project.product_id!r} sourceRoot overlaps engine root {engine_root!r}"
                    )
                if _paths_overlap(project.artifact_root, engine_root):
                    raise BlueprintError(
                        f"project {project.product_id!r} artifactRoot overlaps engine root {engine_root!r}"
                    )

        for index, left in enumerate(self.projects):
            for right in self.projects[index + 1 :]:
                for left_label, left_root in (("sourceRoot", left.source_root), ("artifactRoot", left.artifact_root)):
                    for right_label, right_root in (
                        ("sourceRoot", right.source_root),
                        ("artifactRoot", right.artifact_root),
                    ):
                        if _paths_overlap(left_root, right_root):
                            raise BlueprintError(
                                f"projects {left.product_id!r} and {right.product_id!r} are not isolated: "
                                f"{left_label} {left_root!r} overlaps {right_label} {right_root!r}"
                            )

    def to_dict(self) -> dict[str, Any]:
        return {
            "schemaVersion": self.schema_version,
            "blueprintId": self.blueprint_id,
            "revision": self.revision,
            "engine": self.engine.to_dict(),
            "projects": [item.to_dict() for item in self.projects],
        }

    @property
    def sha256(self) -> str:
        return _sha256_json(self.to_dict())


@dataclass(frozen=True)
class CompiledProjectPlan:
    project_id: str
    product_id: str
    project_definition_sha256: str
    tasks: tuple[TaskSpec, ...]

    def to_dict(self) -> dict[str, Any]:
        return {
            "projectId": self.project_id,
            "productId": self.product_id,
            "projectDefinitionSha256": self.project_definition_sha256,
            "tasks": [_task_to_dict(task) for task in self.tasks],
        }


@dataclass(frozen=True)
class ProductionPlan:
    plan_id: str
    blueprint_id: str
    blueprint_sha256: str
    engine: EngineDefinition
    projects: tuple[CompiledProjectPlan, ...]
    schema_version: int = field(default=1, init=False)
    validation_level: str = field(default=STATIC_VALIDATION_LEVEL, init=False)

    def _unsigned_dict(self) -> dict[str, Any]:
        return {
            "schemaVersion": self.schema_version,
            "planId": self.plan_id,
            "blueprintId": self.blueprint_id,
            "blueprintSha256": self.blueprint_sha256,
            "validationLevel": self.validation_level,
            "engine": self.engine.to_dict(),
            "projects": [item.to_dict() for item in self.projects],
        }

    @property
    def sha256(self) -> str:
        return _sha256_json(self._unsigned_dict())

    def to_dict(self) -> dict[str, Any]:
        payload = self._unsigned_dict()
        payload["planSha256"] = self.sha256
        return payload


def _task_to_dict(task: TaskSpec) -> dict[str, Any]:
    return {
        "taskId": task.id,
        "stage": task.stage.value,
        "role": task.role,
        "intent": task.intent,
        "dependsOn": list(task.blocked_by),
        "readSet": list(task.read_set),
        "writeSet": list(task.write_set),
        "resourceClaims": list(task.resource_claims),
        "completionChecks": list(task.completion_checks),
        "guardRequired": task.guard_required,
        "metadata": task.metadata,
    }


def _compile_project(project: GameProjectDefinition) -> CompiledProjectPlan:
    product = project.product_id
    outputs = project.output_by_kind
    ownership = {item.subsystem_id: item for item in project.ownership}
    tasks: list[TaskSpec] = []

    def task_id(suffix: str) -> str:
        return f"{product}.{suffix}"

    def add(
        suffix: str,
        stage: CampaignStage,
        role: str,
        intent: str,
        *,
        dependencies: Iterable[str] = (),
        reads: Iterable[str] = (),
        writes: Iterable[str] = (),
        resources: Iterable[str] = (),
        checks: Iterable[str] = (),
        guard: bool = False,
        metadata: Mapping[str, Any] | None = None,
    ) -> str:
        identifier = task_id(suffix)
        task_metadata = {
            "productId": product,
            "projectId": project.project_id,
            "seed": project.seed,
            **dict(metadata or {}),
        }
        tasks.append(
            TaskSpec(
                id=identifier,
                stage=stage,
                role=role,
                intent=intent,
                blocked_by=tuple(sorted(dependencies)),
                read_set=tuple(sorted({canonical_write_path(value) for value in reads})),
                write_set=tuple(sorted({canonical_write_path(value) for value in writes})),
                resource_claims=tuple(sorted(set(resources))),
                completion_checks=tuple(sorted(set(checks))),
                guard_required=guard,
                metadata=task_metadata,
            )
        )
        return identifier

    plan_root = outputs["PRODUCTION_PLAN"].path
    specify = add(
        "specify",
        CampaignStage.SPECIFYING,
        "product-architect",
        "validate product intent, reference provenance, and definition completeness",
        reads=(project.product_intent_ref.path, project.reference_bundle_ref.path),
        writes=(_join(plan_root, "specification"),),
        checks=("input hashes match", "product identity remains consistent", "required fields are explicit"),
        metadata={
            "inputArtifacts": [project.product_intent_ref.artifact_id, project.reference_bundle_ref.artifact_id],
            "templateId": project.template_id,
            "genre": project.genre,
        },
    )
    design = add(
        "design",
        CampaignStage.PLANNED,
        "systems-architect",
        "compile the declared product into subsystem, scenario, capture, asset, and quality work",
        dependencies=(specify,),
        reads=(
            _join(plan_root, "specification"),
            *(profile.input_ref.path for profile in project.quality_profiles),
        ),
        writes=(_join(plan_root, "design"),),
        checks=("subsystem DAG is acyclic", "ownership is complete", "coverage matrices are closed"),
    )

    asset_tasks: dict[str, str] = {}
    asset_root = outputs["ASSET_MANIFEST"].path
    for asset in project.asset_needs:
        asset_tasks[asset.id] = add(
            f"asset.{asset.id}",
            CampaignStage.BUILDING,
            "asset-producer",
            "discover or create, validate, publish, and prepare one declared asset need",
            dependencies=(design,),
            reads=(_join(plan_root, "design"),),
            writes=(_join(asset_root, "items", asset.id),),
            resources=(f"asset-publication:{product}",),
            checks=(
                "provenance and license receipt exists",
                "preview and technical validation exist",
                "published identity is approved or explicitly blocked",
            ),
            metadata={
                "assetNeedId": asset.id,
                "assetType": asset.asset_type,
                "strategy": asset.strategy,
                "requiredForRelease": asset.required_for_release,
                "consumers": list(asset.consumers),
            },
        )
    assets_final = add(
        "assets.finalize",
        CampaignStage.BUILDING,
        "asset-integrator",
        "finalize the product-scoped asset manifest without accepting placeholders",
        dependencies=tuple(asset_tasks.values()) or (design,),
        reads=tuple(_join(asset_root, "items", asset.id) for asset in project.asset_needs),
        writes=(_join(asset_root, "manifest"),),
        checks=("all release-required assets are approved and product-bound",),
        metadata={"outputArtifactId": outputs["ASSET_MANIFEST"].artifact_id},
    )

    build_tasks: dict[str, str] = {}
    for subsystem in project.subsystems:
        rule = ownership[subsystem.id]
        consumed_assets = tuple(
            asset_tasks[asset.id] for asset in project.asset_needs if subsystem.id in asset.consumers
        )
        dependency_tasks = tuple(task_id(f"build.{dependency}") for dependency in subsystem.dependencies)
        build_tasks[subsystem.id] = add(
            f"build.{subsystem.id}",
            CampaignStage.BUILDING,
            rule.owner_role,
            "implement one declared subsystem inside its exclusive product-owned write roots",
            dependencies=(design, *consumed_assets, *dependency_tasks),
            reads=(
                _join(plan_root, "design"),
                *(
                    root
                    for dependency in subsystem.dependencies
                    for root in ownership[dependency].write_roots
                ),
            ),
            writes=rule.write_roots,
            resources=(f"project-write:{product}",),
            checks=("subsystem contract is satisfied", "new failure modes have automated guards"),
            guard=True,
            metadata={"subsystemId": subsystem.id, "capability": subsystem.capability},
        )

    source_bundle = add(
        "source.finalize",
        CampaignStage.BUILDING,
        "build-integrator",
        "snapshot the complete product source after all subsystem ownership scopes finish",
        dependencies=tuple(build_tasks.values()),
        reads=(project.source_root,),
        writes=(outputs["SOURCE_BUNDLE"].path,),
        checks=("source bundle hash is recorded", "no engine-owned source is included"),
        metadata={"outputArtifactId": outputs["SOURCE_BUNDLE"].artifact_id},
    )
    integrate = add(
        "integrate",
        CampaignStage.INTEGRATING,
        "integration-agent",
        "integrate product source and approved assets into a reproducible Roblox place build",
        dependencies=(source_bundle, assets_final),
        reads=(outputs["SOURCE_BUNDLE"].path, _join(asset_root, "manifest")),
        writes=(outputs["BUILD_PLACE"].path, outputs["INTEGRATION_MANIFEST"].path),
        resources=(f"build:{product}",),
        checks=("build and integration hashes are recorded", "all asset ids resolve to this product"),
    )
    measure = add(
        "measure",
        CampaignStage.MEASURING,
        "measurement-agent",
        "measure the integrated build through typed engine probes in a pinned Studio session",
        dependencies=(integrate,),
        reads=(outputs["BUILD_PLACE"].path, outputs["INTEGRATION_MANIFEST"].path),
        writes=(outputs["MEASUREMENT_RUN"].path,),
        resources=(f"studio-session:{product}",),
        checks=("run identity matches the exact build", "required probes are conclusive and untruncated"),
    )

    scenario_tasks: list[str] = []
    for scenario in project.scenario_classes:
        scenario_tasks.append(
            add(
                f"play.{scenario.id}",
                CampaignStage.PLAYING,
                "gameplay-qa-agent",
                "play one declared scenario class through player-equivalent black-box actions",
                dependencies=(measure,),
                reads=(outputs["BUILD_PLACE"].path, outputs["MEASUREMENT_RUN"].path),
                writes=(_join(outputs["SCENARIO_RESULTS"].path, scenario.id),),
                resources=(f"studio-session:{product}",),
                checks=("scenario evidence is correlated to the run", "server and client logs are captured"),
                metadata={
                    "scenarioId": scenario.id,
                    "scenarioClass": scenario.scenario_class,
                    "actorProfile": scenario.actor_profile,
                    "requiredForRelease": scenario.required_for_release,
                },
            )
        )

    capture_tasks: list[str] = []
    for combination in project.device_viewpoint_matrix.combinations:
        capture_tasks.append(
            add(
                f"capture.{combination.device_id}.{combination.viewpoint_id}",
                CampaignStage.CAPTURING,
                "capture-agent",
                "capture one deterministic device and viewpoint combination from the measured build",
                dependencies=tuple(scenario_tasks),
                reads=(outputs["BUILD_PLACE"].path, outputs["SCENARIO_RESULTS"].path),
                writes=(
                    _join(
                        outputs["CAPTURE_BUNDLE"].path,
                        f"{combination.device_id}--{combination.viewpoint_id}",
                    ),
                ),
                resources=(f"studio-window:{product}",),
                checks=("foreground ownership is verified", "camera, device, build, and run identities are bound"),
                metadata={"deviceId": combination.device_id, "viewpointId": combination.viewpoint_id},
            )
        )

    evaluation_tasks: list[str] = []
    for profile in project.quality_profiles:
        evaluation_tasks.append(
            add(
                f"evaluate.{profile.id}",
                CampaignStage.EVALUATING,
                "quality-critic",
                "evaluate measured and captured evidence against one independently defined quality profile",
                dependencies=tuple(capture_tasks),
                reads=(
                    profile.input_ref.path,
                    outputs["MEASUREMENT_RUN"].path,
                    outputs["SCENARIO_RESULTS"].path,
                    outputs["CAPTURE_BUNDLE"].path,
                ),
                writes=(_join(outputs["QUALITY_REVIEW"].path, profile.id),),
                checks=("deterministic findings and advisory critique remain separate", "citations bind exact evidence"),
                metadata={
                    "qualityProfileId": profile.id,
                    "requiredForRelease": profile.required_for_release,
                    "appliesTo": list(profile.applies_to),
                },
            )
        )

    repair_plan = add(
        "repair.plan",
        CampaignStage.REPAIRING,
        "repair-orchestrator",
        "compile findings into ownership-scoped repair work, or attest that no repair is required",
        dependencies=tuple(evaluation_tasks),
        reads=(outputs["QUALITY_REVIEW"].path,),
        writes=(outputs["REPAIR_PLAN"].path,),
        checks=("every repair target has one subsystem owner", "each repaired failure receives a guard"),
        metadata={"dynamicFanout": "OWNERSHIP_SCOPED_REPAIR_TASKS"},
    )
    impacted = add(
        "regression.impacted",
        CampaignStage.REGRESSION_IMPACTED,
        "regression-agent",
        "run the minimum deterministic regression selected from verified change impact",
        dependencies=(repair_plan,),
        reads=(outputs["REPAIR_PLAN"].path, outputs["BUILD_PLACE"].path),
        writes=(_join(outputs["REGRESSION_RUN"].path, "impacted"),),
        checks=("unknown impact escalates to full scope", "impacted evidence never authorizes release"),
    )
    full = add(
        "regression.full",
        CampaignStage.REGRESSION_FULL,
        "release-qa-agent",
        "run the complete deterministic gate after impacted feedback",
        dependencies=(impacted,),
        reads=(
            outputs["BUILD_PLACE"].path,
            outputs["MEASUREMENT_RUN"].path,
            outputs["SCENARIO_RESULTS"].path,
            outputs["CAPTURE_BUNDLE"].path,
            outputs["QUALITY_REVIEW"].path,
        ),
        writes=(_join(outputs["REGRESSION_RUN"].path, "full"),),
        checks=("full gate is complete", "all evidence is fresh, measured, immutable, and hash-bound"),
    )
    add(
        "release.candidate",
        CampaignStage.EVALUATING,
        "release-agent",
        "assemble a release candidate only after the complete deterministic gate authorizes it",
        dependencies=(full,),
        reads=(
            outputs["SOURCE_BUNDLE"].path,
            outputs["BUILD_PLACE"].path,
            outputs["INTEGRATION_MANIFEST"].path,
            outputs["REGRESSION_RUN"].path,
        ),
        writes=(outputs["RELEASE_CANDIDATE"].path,),
        checks=("FULL deterministic gate authorizes candidate", "candidate identities match this product only"),
        metadata={"terminalArtifactKind": "RELEASE_CANDIDATE"},
    )

    try:
        graph = TaskGraph(tasks)
    except (TaskGraphError, ValueError) as exc:
        raise BlueprintError(f"compiled task graph is invalid for product {product!r}: {exc}") from exc
    return CompiledProjectPlan(
        project_id=project.project_id,
        product_id=product,
        project_definition_sha256=project.sha256,
        tasks=graph.tasks,
    )


def _assert_compiled_plan_isolation(
    blueprint: ProductionBlueprint,
    project_plans: tuple[CompiledProjectPlan, ...],
) -> None:
    definitions = {project.product_id: project for project in blueprint.projects}
    task_ids: set[str] = set()
    for plan in project_plans:
        project = definitions[plan.product_id]
        allowed_roots = (project.source_root, project.artifact_root)
        for task in plan.tasks:
            if task.id in task_ids:
                raise BlueprintError(f"compiled plans share task id {task.id!r}")
            task_ids.add(task.id)
            if task.metadata.get("productId") != project.product_id:
                raise BlueprintError(f"task {task.id!r} lost its product identity")
            for path in (*task.read_set, *task.write_set):
                if not any(_is_within(path, root) for root in allowed_roots):
                    raise BlueprintError(f"task {task.id!r} escaped its project roots through {path!r}")
                for other in blueprint.projects:
                    if other.product_id == project.product_id:
                        continue
                    if _is_within(path, other.source_root) or _is_within(path, other.artifact_root):
                        raise BlueprintError(
                            f"task {task.id!r} references artifact space owned by {other.product_id!r}"
                        )


def compile_production_blueprint(
    blueprint: ProductionBlueprint | Mapping[str, Any],
    *,
    schema_dir: Path | None = None,
) -> ProductionPlan:
    """Compile a validated blueprint into a stable, non-executing task plan."""

    definition = (
        blueprint
        if isinstance(blueprint, ProductionBlueprint)
        else ProductionBlueprint.from_dict(blueprint, schema_dir=schema_dir)
    )
    project_plans = tuple(_compile_project(project) for project in definition.projects)
    _assert_compiled_plan_isolation(definition, project_plans)
    plan = ProductionPlan(
        plan_id=f"{definition.blueprint_id}.{definition.revision}.{definition.sha256[:12]}",
        blueprint_id=definition.blueprint_id,
        blueprint_sha256=definition.sha256,
        engine=definition.engine,
        projects=project_plans,
    )
    schemas = schema_dir or _repository_root() / "schemas"
    _validate_shape(plan.to_dict(), schemas / PRODUCTION_PLAN_SCHEMA, "compiled production plan")
    return plan


def load_game_project_definition(
    path: Path,
    *,
    schema_path: Path | None = None,
) -> GameProjectDefinition:
    return GameProjectDefinition.from_dict(_read_json(path, "game project definition"), schema_path=schema_path)


def load_production_blueprint(
    path: Path,
    *,
    schema_dir: Path | None = None,
) -> ProductionBlueprint:
    return ProductionBlueprint.from_dict(_read_json(path, "production blueprint"), schema_dir=schema_dir)


__all__ = [
    "AssetNeedDefinition",
    "BlueprintError",
    "CaptureCombination",
    "CompiledProjectPlan",
    "DeviceDefinition",
    "DeviceViewpointMatrix",
    "EngineDefinition",
    "GameProjectDefinition",
    "InputArtifactRef",
    "OutputArtifactRef",
    "OwnershipRule",
    "ProductionBlueprint",
    "ProductionPlan",
    "QualityProfileDefinition",
    "ScenarioClassDefinition",
    "SubsystemDefinition",
    "ViewpointDefinition",
    "compile_production_blueprint",
    "load_game_project_definition",
    "load_production_blueprint",
]
