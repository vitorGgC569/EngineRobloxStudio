"""Fail-closed product identity and visual-calibration trust boundary.

This module deliberately does not know any game name.  It verifies that a
candidate is being judged against the product intent, reference set and frozen
thresholds selected *before* candidate evaluation.  It does not measure the
candidate and it does not authorize release on its own.
"""

from __future__ import annotations

import hashlib
import json
import math
import re
from dataclasses import dataclass
from datetime import datetime
from pathlib import Path
from typing import Any, Iterable

from .schema_validation import SchemaDefinitionError, validate_schema_instance


SHA256_RE = re.compile(r"^[0-9a-f]{64}$")

_SCHEMAS = {
    "productIntent": (
        "product-intent.v1.schema.json",
        "https://rqe.local/schemas/product-intent.v1.schema.json",
    ),
    "referenceBenchmark": (
        "reference-benchmark.v1.schema.json",
        "https://rqe.local/schemas/reference-benchmark.v1.schema.json",
    ),
    "visualCalibration": (
        "visual-calibration-receipt.v1.schema.json",
        "https://rqe.local/schemas/visual-calibration-receipt.v1.schema.json",
    ),
    "runtimeIdentity": (
        "runtime-product-identity-receipt.v1.schema.json",
        "https://rqe.local/schemas/runtime-product-identity-receipt.v1.schema.json",
    ),
}


@dataclass(frozen=True)
class ProductTruthIssue:
    code: str
    path: str
    message: str

    def __str__(self) -> str:
        return f"{self.code} at {self.path}: {self.message}"


class ProductTruthError(ValueError):
    def __init__(self, issues: Iterable[ProductTruthIssue]):
        self.issues = tuple(issues)
        if not self.issues:
            raise ValueError("ProductTruthError requires at least one issue")
        super().__init__("product truth is blocked:\n- " + "\n- ".join(str(item) for item in self.issues))


@dataclass(frozen=True)
class ArtifactReceipt:
    path: Path
    sha256: str
    bytes: int

    def to_dict(self, root: Path) -> dict[str, Any]:
        return {
            "path": self.path.relative_to(root.resolve()).as_posix(),
            "sha256": self.sha256,
            "bytes": self.bytes,
        }


@dataclass(frozen=True)
class CalibrationTarget:
    artifact: str
    pointer: str
    value: int | float
    operator: str

    @property
    def key(self) -> tuple[str, str]:
        return (self.artifact, self.pointer)


@dataclass(frozen=True)
class ProductTruthBundle:
    root: Path
    product_id: str
    product_intent: dict[str, Any]
    contract: dict[str, Any]
    visual_quality_spec: dict[str, Any]
    reference_benchmark: dict[str, Any]
    visual_calibration: dict[str, Any]
    runtime_identity_receipt: dict[str, Any]
    artifacts: dict[str, ArtifactReceipt]
    reference_sources: tuple[ArtifactReceipt, ...]
    required_calibration_targets: tuple[CalibrationTarget, ...]

    def verify_unchanged(self) -> None:
        """Re-hash every trusted input before a consumer acts on this bundle."""

        issues: list[ProductTruthIssue] = []
        for name, receipt in self.artifacts.items():
            if not receipt.path.is_file():
                issues.append(ProductTruthIssue("ARTIFACT_DISAPPEARED", name, str(receipt.path)))
                continue
            actual = _sha256_file(receipt.path)
            if actual != receipt.sha256:
                issues.append(ProductTruthIssue(
                    "ARTIFACT_CHANGED", name,
                    f"expected {receipt.sha256}, observed {actual}",
                ))
        for index, receipt in enumerate(self.reference_sources):
            if not receipt.path.is_file():
                issues.append(ProductTruthIssue(
                    "REFERENCE_SOURCE_DISAPPEARED", f"referenceSources[{index}]", str(receipt.path)
                ))
                continue
            actual = _sha256_file(receipt.path)
            if actual != receipt.sha256:
                issues.append(ProductTruthIssue(
                    "REFERENCE_SOURCE_CHANGED", f"referenceSources[{index}]",
                    f"expected {receipt.sha256}, observed {actual}",
                ))
        if issues:
            raise ProductTruthError(issues)

    def to_receipt(self) -> dict[str, Any]:
        return {
            "schemaVersion": 1,
            "status": "READY",
            "productId": self.product_id,
            "artifacts": {
                name: receipt.to_dict(self.root)
                for name, receipt in sorted(self.artifacts.items())
            },
            "referenceSources": [item.to_dict(self.root) for item in self.reference_sources],
            "calibratedTargetCount": len(self.required_calibration_targets),
        }


@dataclass(frozen=True)
class ProductTruthAssessment:
    status: str
    bundle: ProductTruthBundle | None
    issues: tuple[ProductTruthIssue, ...]

    @property
    def ready(self) -> bool:
        return self.status == "READY" and self.bundle is not None and not self.issues

    def to_dict(self) -> dict[str, Any]:
        payload: dict[str, Any] = {
            "schemaVersion": 1,
            "status": self.status,
            "issues": [
                {"code": item.code, "path": item.path, "message": item.message}
                for item in self.issues
            ],
        }
        if self.bundle is not None:
            payload["receipt"] = self.bundle.to_receipt()
        return payload


def _issue(code: str, path: str, message: str) -> ProductTruthError:
    return ProductTruthError((ProductTruthIssue(code, path, message),))


def _sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def _validate_expected_hash(value: Any, label: str) -> str:
    if not isinstance(value, str) or SHA256_RE.fullmatch(value) is None:
        raise _issue("EXPECTED_HASH_MISSING", label, "a lowercase SHA-256 supplied by immutable provenance is required")
    return value


def _project_file(root: Path, value: Any, label: str) -> Path:
    if not isinstance(value, (str, Path)) or not str(value):
        raise _issue("PATH_REQUIRED", label, "a non-empty project-relative path is required")
    requested = Path(value)
    if requested.is_absolute():
        raise _issue("PATH_ABSOLUTE", label, "absolute paths are forbidden")
    if any(part in {"..", "."} for part in requested.parts):
        raise _issue("PATH_NOT_NORMALIZED", label, "'.' and '..' path components are forbidden")
    root = root.resolve()
    current = root
    for part in requested.parts:
        current = current / part
        if current.is_symlink():
            raise _issue("PATH_SYMLINK", label, f"symlink component is forbidden: {current}")
    path = (root / requested).resolve()
    try:
        path.relative_to(root)
    except ValueError as exc:
        raise _issue("PATH_ESCAPE", label, "path escapes the project root") from exc
    if not path.is_file():
        raise _issue("FILE_MISSING", label, f"file does not exist: {path}")
    return path


def _schema_file(root: Path, document_path: Path, declared: Any, kind: str) -> Path:
    filename, expected_id = _SCHEMAS[kind]
    expected = _project_file(root, Path("schemas") / filename, f"{kind}.ownedSchema")
    if not isinstance(declared, str) or not declared:
        raise _issue("SCHEMA_DECLARATION_MISSING", f"{kind}.$schema", "owned schema path is required")
    requested = Path(declared)
    if requested.is_absolute():
        raise _issue("SCHEMA_PATH_ABSOLUTE", f"{kind}.$schema", "schema path must be relative")
    actual = (document_path.parent / requested).resolve()
    try:
        actual.relative_to(root.resolve())
    except ValueError as exc:
        raise _issue("SCHEMA_PATH_ESCAPE", f"{kind}.$schema", "schema path escapes the project root") from exc
    if actual != expected:
        raise _issue(
            "SCHEMA_SUBSTITUTION", f"{kind}.$schema",
            f"must resolve to the engine-owned schema {expected.relative_to(root.resolve()).as_posix()}",
        )
    schema = _read_json(expected, f"{kind}.ownedSchema")
    if schema.get("$id") != expected_id:
        raise _issue("SCHEMA_ID_MISMATCH", f"{kind}.ownedSchema.$id", f"expected {expected_id!r}")
    return expected


def _read_json(path: Path, label: str) -> dict[str, Any]:
    def object_pairs(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
        result: dict[str, Any] = {}
        for key, value in pairs:
            if key in result:
                raise ValueError(f"duplicate key {key!r}")
            result[key] = value
        return result

    def invalid_constant(value: str) -> None:
        raise ValueError(f"non-finite number {value}")

    try:
        payload = json.loads(
            path.read_text(encoding="utf-8"),
            object_pairs_hook=object_pairs,
            parse_constant=invalid_constant,
        )
    except (OSError, UnicodeError, json.JSONDecodeError, ValueError) as exc:
        raise _issue("JSON_INVALID", label, str(exc)) from exc
    if not isinstance(payload, dict):
        raise _issue("JSON_ROOT_INVALID", label, "document root must be an object")
    return payload


def _receipt(path: Path) -> ArtifactReceipt:
    return ArtifactReceipt(path=path, sha256=_sha256_file(path), bytes=path.stat().st_size)


def _load_owned_document(
    root: Path,
    path: Path,
    kind: str,
    *,
    expected_hash: str | None = None,
) -> tuple[dict[str, Any], ArtifactReceipt]:
    receipt = _receipt(path)
    if expected_hash is not None and receipt.sha256 != expected_hash:
        raise _issue(
            "HASH_MISMATCH", kind,
            f"expected {expected_hash}, observed {receipt.sha256}",
        )
    payload = _read_json(path, kind)
    schema_path = _schema_file(root, path, payload.get("$schema"), kind)
    schema = _read_json(schema_path, f"{kind}.ownedSchema")
    try:
        schema_issues = validate_schema_instance(payload, schema)
    except SchemaDefinitionError as exc:
        raise _issue("SCHEMA_DEFINITION_INVALID", kind, str(exc)) from exc
    if schema_issues:
        raise ProductTruthError(
            ProductTruthIssue("SCHEMA_VALIDATION_FAILED", kind, str(item))
            for item in schema_issues
        )
    return payload, receipt


def _load_bound_json(
    root: Path,
    binding: dict[str, Any],
    label: str,
) -> tuple[dict[str, Any], ArtifactReceipt]:
    path = _project_file(root, binding.get("path"), f"bindings.{label}.path")
    expected = _validate_expected_hash(binding.get("sha256"), f"bindings.{label}.sha256")
    receipt = _receipt(path)
    if receipt.sha256 != expected:
        raise _issue("HASH_MISMATCH", f"bindings.{label}", f"expected {expected}, observed {receipt.sha256}")
    return _read_json(path, label), receipt


def _parse_time(value: Any, label: str) -> datetime:
    if not isinstance(value, str) or not value.endswith("Z"):
        raise _issue("TIMESTAMP_INVALID", label, "UTC RFC3339 timestamp ending in Z is required")
    try:
        return datetime.fromisoformat(value[:-1] + "+00:00")
    except ValueError as exc:
        raise _issue("TIMESTAMP_INVALID", label, str(exc)) from exc


def _expect_equal(issues: list[ProductTruthIssue], expected: Any, actual: Any, path: str, code: str) -> None:
    if actual != expected:
        issues.append(ProductTruthIssue(code, path, f"expected {expected!r}, observed {actual!r}"))


def _ids(items: Any, label: str, issues: list[ProductTruthIssue]) -> tuple[str, ...]:
    if not isinstance(items, list):
        issues.append(ProductTruthIssue("SEMANTIC_LIST_INVALID", label, "must be an array"))
        return ()
    values = tuple(item.get("id") for item in items if isinstance(item, dict) and isinstance(item.get("id"), str))
    if len(values) != len(items):
        issues.append(ProductTruthIssue("SEMANTIC_ID_MISSING", label, "every item must have an id"))
    if len(values) != len(set(values)):
        issues.append(ProductTruthIssue("SEMANTIC_ID_DUPLICATE", label, "ids must be unique"))
    return values


def _check_contract_semantics(
    intent: dict[str, Any], contract: dict[str, Any], issues: list[ProductTruthIssue]
) -> None:
    truth = contract.get("productTruth")
    if not isinstance(truth, dict):
        issues.append(ProductTruthIssue(
            "CONTRACT_PRODUCT_TRUTH_MISSING", "contract.productTruth",
            "contract must bind intent semantics to concrete requirement ids",
        ))
        return
    _expect_equal(issues, intent.get("intentId"), truth.get("intentId"), "contract.productTruth.intentId", "INTENT_ID_MISMATCH")
    bindings = truth.get("semanticBindings")
    if not isinstance(bindings, dict):
        issues.append(ProductTruthIssue("CONTRACT_SEMANTIC_BINDINGS_MISSING", "contract.productTruth.semanticBindings", "object is required"))
        return
    requirement_ids = {
        item.get("id") for item in contract.get("requirements", [])
        if isinstance(item, dict) and isinstance(item.get("id"), str)
    }
    for group in ("worldRoles", "uiSurfaces", "gameplayVerbs"):
        expected = set(_ids(intent.get("semantics", {}).get(group), f"intent.semantics.{group}", issues))
        actual = bindings.get(group)
        if not isinstance(actual, dict):
            issues.append(ProductTruthIssue("CONTRACT_SEMANTIC_GROUP_MISSING", f"contract.productTruth.semanticBindings.{group}", "object is required"))
            continue
        if set(actual) != expected:
            issues.append(ProductTruthIssue(
                "CONTRACT_SEMANTIC_COVERAGE_MISMATCH", f"contract.productTruth.semanticBindings.{group}",
                f"expected exactly {sorted(expected)!r}, observed {sorted(actual)!r}",
            ))
        for semantic_id, references in actual.items():
            if not isinstance(references, list) or not references:
                issues.append(ProductTruthIssue("CONTRACT_REQUIREMENT_BINDING_EMPTY", f"contract.productTruth.semanticBindings.{group}.{semantic_id}", "at least one requirement id is required"))
                continue
            unknown = sorted({item for item in references if item not in requirement_ids})
            if unknown:
                issues.append(ProductTruthIssue("CONTRACT_REQUIREMENT_UNKNOWN", f"contract.productTruth.semanticBindings.{group}.{semantic_id}", f"unknown requirement ids: {unknown!r}"))


def _check_visual_semantics(
    intent: dict[str, Any], spec: dict[str, Any], calibration_id: str, issues: list[ProductTruthIssue]
) -> None:
    truth = spec.get("productTruth")
    if not isinstance(truth, dict):
        issues.append(ProductTruthIssue(
            "VISUAL_PRODUCT_TRUTH_MISSING", "visualQualitySpec.productTruth",
            "visual spec must bind product roles to landmarks, regions and viewpoints",
        ))
        return
    _expect_equal(issues, intent.get("intentId"), truth.get("intentId"), "visualQualitySpec.productTruth.intentId", "INTENT_ID_MISMATCH")
    _expect_equal(issues, calibration_id, truth.get("calibrationId"), "visualQualitySpec.productTruth.calibrationId", "CALIBRATION_ID_MISMATCH")
    bindings = truth.get("semanticBindings")
    if not isinstance(bindings, dict):
        issues.append(ProductTruthIssue("VISUAL_SEMANTIC_BINDINGS_MISSING", "visualQualitySpec.productTruth.semanticBindings", "object is required"))
        return

    known = {
        "landmarkIds": set(spec.get("landmarks", {})),
        "regionSetIds": set(spec.get("regionSets", {})),
        "viewpointIds": set(spec.get("viewpoints", {})),
    }
    for group in ("worldRoles", "uiSurfaces"):
        expected = set(_ids(intent.get("semantics", {}).get(group), f"intent.semantics.{group}", issues))
        actual = bindings.get(group)
        if not isinstance(actual, dict):
            issues.append(ProductTruthIssue("VISUAL_SEMANTIC_GROUP_MISSING", f"visualQualitySpec.productTruth.semanticBindings.{group}", "object is required"))
            continue
        if set(actual) != expected:
            issues.append(ProductTruthIssue(
                "VISUAL_SEMANTIC_COVERAGE_MISMATCH", f"visualQualitySpec.productTruth.semanticBindings.{group}",
                f"expected exactly {sorted(expected)!r}, observed {sorted(actual)!r}",
            ))
        for semantic_id, references in actual.items():
            path = f"visualQualitySpec.productTruth.semanticBindings.{group}.{semantic_id}"
            if not isinstance(references, dict):
                issues.append(ProductTruthIssue("VISUAL_SEMANTIC_BINDING_INVALID", path, "object is required"))
                continue
            referenced = 0
            for key, allowed in known.items():
                values = references.get(key, [])
                if not isinstance(values, list):
                    issues.append(ProductTruthIssue("VISUAL_SEMANTIC_REFERENCE_INVALID", f"{path}.{key}", "array is required"))
                    continue
                referenced += len(values)
                unknown = sorted({item for item in values if item not in allowed})
                if unknown:
                    issues.append(ProductTruthIssue("VISUAL_SEMANTIC_REFERENCE_UNKNOWN", f"{path}.{key}", f"unknown ids: {unknown!r}"))
            if referenced == 0:
                issues.append(ProductTruthIssue("VISUAL_SEMANTIC_BINDING_EMPTY", path, "at least one landmark, region set or viewpoint is required"))


def _pointer_escape(value: str) -> str:
    return value.replace("~", "~0").replace("/", "~1")


def _number(value: Any) -> bool:
    return isinstance(value, (int, float)) and not isinstance(value, bool) and math.isfinite(value)


def required_calibration_targets(
    contract: dict[str, Any], visual_quality_spec: dict[str, Any]
) -> tuple[CalibrationTarget, ...]:
    """Enumerate every v1 value that can change visual acceptance or scoring.

    The registry is schema-versioned rather than game-specific.  An unknown
    visual schema version blocks instead of silently leaving new thresholds
    uncalibrated.
    """

    if visual_quality_spec.get("schemaVersion") != 1:
        raise _issue(
            "UNSUPPORTED_VISUAL_SPEC_SCHEMA", "visualQualitySpec.schemaVersion",
            "no calibration-target registry exists for this schema version",
        )
    targets: dict[tuple[str, str], CalibrationTarget] = {}

    def add(artifact: str, pointer: str, value: Any, operator: str) -> None:
        if _number(value):
            target = CalibrationTarget(artifact, pointer, value, operator)
            targets[target.key] = target

    def add_numeric_tree(artifact: str, pointer: str, value: Any, operator: str = "eq") -> None:
        if _number(value):
            add(artifact, pointer, value, operator)
        elif isinstance(value, list):
            for index, child in enumerate(value):
                add_numeric_tree(artifact, f"{pointer}/{index}", child, operator)
        elif isinstance(value, dict):
            for key, child in value.items():
                lowered = key.lower()
                child_operator = "gte" if lowered.startswith("minimum") else "lte" if lowered.startswith("maximum") else operator
                add_numeric_tree(artifact, f"{pointer}/{_pointer_escape(str(key))}", child, child_operator)

    contract_paths = (
        ("/visualQuality/release/minimumScore", contract.get("visualQuality", {}).get("release", {}).get("minimumScore"), "gte"),
        ("/visualQuality/release/minimumRuleCoverage", contract.get("visualQuality", {}).get("release", {}).get("minimumRuleCoverage"), "gte"),
        ("/release_gate/minimum_visual_score", contract.get("release_gate", {}).get("minimum_visual_score"), "gte"),
    )
    for pointer, value, operator in contract_paths:
        add("contract", pointer, value, operator)

    spec = visual_quality_spec
    add("visualQualitySpec", "/classification/minimumClassifiedFraction", spec.get("classification", {}).get("minimumClassifiedFraction"), "gte")
    palette = spec.get("palette", {})
    add("visualQualitySpec", "/palette/maximumDeltaE", palette.get("maximumDeltaE"), "lte")
    add("visualQualitySpec", "/palette/maximumOffPaletteFraction", palette.get("maximumOffPaletteFraction"), "lte")
    for index, swatch in enumerate(palette.get("swatches", [])):
        if isinstance(swatch, dict):
            add_numeric_tree("visualQualitySpec", f"/palette/swatches/{index}/rgb", swatch.get("rgb"), "eq")

    for object_id, definition in spec.get("objectTypes", {}).items():
        if not isinstance(definition, dict):
            continue
        base = f"/objectTypes/{_pointer_escape(str(object_id))}"
        add("visualQualitySpec", f"{base}/minimumInstances", definition.get("minimumInstances"), "gte")
        add("visualQualitySpec", f"{base}/maximumInstances", definition.get("maximumInstances"), "lte")
        scale = definition.get("scale", {})
        add_numeric_tree("visualQualitySpec", f"{base}/scale/minimumSize", scale.get("minimumSize"), "gte")
        add_numeric_tree("visualQualitySpec", f"{base}/scale/maximumSize", scale.get("maximumSize"), "lte")
        add("visualQualitySpec", f"{base}/scale/maximumRelativeMad", scale.get("maximumRelativeMad"), "lte")

    for profile_id, profile in spec.get("regionProfiles", {}).items():
        if isinstance(profile, dict):
            add_numeric_tree("visualQualitySpec", f"/regionProfiles/{_pointer_escape(str(profile_id))}", profile)
    for set_id, region_set in spec.get("regionSets", {}).items():
        if isinstance(region_set, dict):
            base = f"/regionSets/{_pointer_escape(str(set_id))}"
            for key in ("minimumRegions", "maximumRegions", "minimumProfileCoverage"):
                operator = "gte" if key.startswith("minimum") else "lte"
                add("visualQualitySpec", f"{base}/{key}", region_set.get(key), operator)
    for landmark_id, landmark in spec.get("landmarks", {}).items():
        if isinstance(landmark, dict):
            add_numeric_tree("visualQualitySpec", f"/landmarks/{_pointer_escape(str(landmark_id))}", landmark)
    for viewpoint_id, viewpoint in spec.get("viewpoints", {}).items():
        if not isinstance(viewpoint, dict):
            continue
        base = f"/viewpoints/{_pointer_escape(str(viewpoint_id))}"
        add_numeric_tree("visualQualitySpec", f"{base}/resolution", viewpoint.get("resolution"), "eq")
        add_numeric_tree("visualQualitySpec", f"{base}/camera", viewpoint.get("camera"), "eq")
        add_numeric_tree("visualQualitySpec", f"{base}/rubric", viewpoint.get("rubric"), "eq")
    for state_id, state in spec.get("evaluationStates", {}).items():
        if isinstance(state, dict):
            add("visualQualitySpec", f"/evaluationStates/{_pointer_escape(str(state_id))}/minimumRuleCoverage", state.get("minimumRuleCoverage"), "gte")

    if not targets:
        raise _issue("CALIBRATION_TARGETS_EMPTY", "visualQualitySpec", "no visual acceptance or scoring values were discoverable")
    return tuple(targets[key] for key in sorted(targets))


def _resolve_pointer(document: Any, pointer: str) -> Any:
    if not isinstance(pointer, str) or not pointer.startswith("/"):
        raise KeyError("JSON pointer must begin with '/'")
    node = document
    for encoded in pointer[1:].split("/"):
        token = encoded.replace("~1", "/").replace("~0", "~")
        if isinstance(node, dict):
            node = node[token]
        elif isinstance(node, list):
            if not token.isdigit():
                raise KeyError(token)
            node = node[int(token)]
        else:
            raise KeyError(token)
    return node


def _check_reference_benchmark(
    root: Path,
    product_id: str,
    benchmark: dict[str, Any],
    issues: list[ProductTruthIssue],
) -> tuple[tuple[ArtifactReceipt, ...], dict[str, dict[str, Any]]]:
    independence = benchmark.get("independenceReceipt", {})
    _expect_equal(issues, product_id, benchmark.get("productId"), "referenceBenchmark.productId", "PRODUCT_ID_MISMATCH")
    _expect_equal(issues, product_id, independence.get("excludedCandidateProductId"), "referenceBenchmark.independenceReceipt.excludedCandidateProductId", "CANDIDATE_EXCLUSION_MISMATCH")
    source_ids: set[str] = set()
    source_receipts: list[ArtifactReceipt] = []
    for index, source in enumerate(benchmark.get("sources", [])):
        source_id = source.get("sourceId")
        if source_id in source_ids:
            issues.append(ProductTruthIssue("REFERENCE_SOURCE_DUPLICATE", f"referenceBenchmark.sources[{index}].sourceId", str(source_id)))
        source_ids.add(source_id)
        if source.get("referenceProductId") == product_id:
            issues.append(ProductTruthIssue(
                "REFERENCE_IS_CANDIDATE", f"referenceBenchmark.sources[{index}].referenceProductId",
                "reference product must differ from the candidate product",
            ))
        try:
            snapshot = _project_file(root, source.get("snapshotPath"), f"referenceBenchmark.sources[{index}].snapshotPath")
            receipt = _receipt(snapshot)
            if receipt.sha256 != source.get("sha256"):
                issues.append(ProductTruthIssue(
                    "REFERENCE_SOURCE_HASH_MISMATCH", f"referenceBenchmark.sources[{index}].sha256",
                    f"expected {source.get('sha256')}, observed {receipt.sha256}",
                ))
            else:
                source_receipts.append(receipt)
        except ProductTruthError as exc:
            issues.extend(exc.issues)

    observations: dict[str, dict[str, Any]] = {}
    for index, observation in enumerate(benchmark.get("observations", [])):
        observation_id = observation.get("observationId")
        if observation_id in observations:
            issues.append(ProductTruthIssue("REFERENCE_OBSERVATION_DUPLICATE", f"referenceBenchmark.observations[{index}].observationId", str(observation_id)))
        elif isinstance(observation_id, str):
            observations[observation_id] = observation
        unknown = sorted(set(observation.get("sourceIds", [])) - source_ids)
        if unknown:
            issues.append(ProductTruthIssue("REFERENCE_OBSERVATION_SOURCE_UNKNOWN", f"referenceBenchmark.observations[{index}].sourceIds", f"unknown source ids: {unknown!r}"))

    created = _parse_time(benchmark.get("createdAt"), "referenceBenchmark.createdAt")
    frozen = _parse_time(benchmark.get("frozenAt"), "referenceBenchmark.frozenAt")
    if created > frozen:
        issues.append(ProductTruthIssue("REFERENCE_CHRONOLOGY_INVALID", "referenceBenchmark.frozenAt", "frozenAt precedes createdAt"))
    for index, source in enumerate(benchmark.get("sources", [])):
        if _parse_time(source.get("acquiredAt"), f"referenceBenchmark.sources[{index}].acquiredAt") > frozen:
            issues.append(ProductTruthIssue("REFERENCE_NOT_FROZEN", f"referenceBenchmark.sources[{index}].acquiredAt", "source was acquired after benchmark freeze"))
    for index, observation in enumerate(benchmark.get("observations", [])):
        if _parse_time(observation.get("observedAt"), f"referenceBenchmark.observations[{index}].observedAt") > frozen:
            issues.append(ProductTruthIssue("REFERENCE_NOT_FROZEN", f"referenceBenchmark.observations[{index}].observedAt", "observation was produced after benchmark freeze"))
    if _parse_time(independence.get("verifiedAt"), "referenceBenchmark.independenceReceipt.verifiedAt") > frozen:
        issues.append(ProductTruthIssue("REFERENCE_INDEPENDENCE_NOT_FROZEN", "referenceBenchmark.independenceReceipt.verifiedAt", "independence decision was produced after benchmark freeze"))
    return tuple(source_receipts), observations


def _check_calibration(
    contract: dict[str, Any],
    spec: dict[str, Any],
    benchmark: dict[str, Any],
    benchmark_hash: str,
    calibration: dict[str, Any],
    observations: dict[str, dict[str, Any]],
    issues: list[ProductTruthIssue],
) -> tuple[CalibrationTarget, ...]:
    _expect_equal(issues, benchmark.get("benchmarkId"), calibration.get("benchmark", {}).get("benchmarkId"), "visualCalibration.benchmark.benchmarkId", "BENCHMARK_ID_MISMATCH")
    _expect_equal(issues, benchmark_hash, calibration.get("benchmark", {}).get("sha256"), "visualCalibration.benchmark.sha256", "BENCHMARK_HASH_MISMATCH")
    required = required_calibration_targets(contract, spec)
    required_map = {item.key: item for item in required}
    actual: dict[tuple[str, str], dict[str, Any]] = {}
    threshold_ids: set[str] = set()
    frozen = _parse_time(benchmark.get("frozenAt"), "referenceBenchmark.frozenAt")
    calibrated = _parse_time(calibration.get("methodology", {}).get("calibratedAt"), "visualCalibration.methodology.calibratedAt")
    if calibrated < frozen:
        issues.append(ProductTruthIssue("CALIBRATION_CHRONOLOGY_INVALID", "visualCalibration.methodology.calibratedAt", "calibration precedes benchmark freeze"))

    documents = {"contract": contract, "visualQualitySpec": spec}
    for index, threshold in enumerate(calibration.get("thresholds", [])):
        path = f"visualCalibration.thresholds[{index}]"
        threshold_id = threshold.get("thresholdId")
        if threshold_id in threshold_ids:
            issues.append(ProductTruthIssue("CALIBRATION_THRESHOLD_DUPLICATE", f"{path}.thresholdId", str(threshold_id)))
        threshold_ids.add(threshold_id)
        key = (threshold.get("targetArtifact"), threshold.get("targetPointer"))
        if key in actual:
            issues.append(ProductTruthIssue("CALIBRATION_TARGET_DUPLICATE", path, f"duplicate target {key!r}"))
        actual[key] = threshold
        artifact = documents.get(key[0])
        if artifact is None:
            continue
        try:
            target_value = _resolve_pointer(artifact, key[1])
        except (KeyError, IndexError, TypeError) as exc:
            issues.append(ProductTruthIssue("CALIBRATION_TARGET_UNKNOWN", f"{path}.targetPointer", str(exc)))
            continue
        if not _number(target_value):
            issues.append(ProductTruthIssue("CALIBRATION_TARGET_NOT_NUMERIC", f"{path}.targetPointer", "target must resolve to a finite number"))
        elif not math.isclose(float(target_value), float(threshold.get("value")), rel_tol=0, abs_tol=1e-12):
            issues.append(ProductTruthIssue("CALIBRATION_VALUE_MISMATCH", f"{path}.value", f"target contains {target_value!r}, receipt contains {threshold.get('value')!r}"))

        provenance = threshold.get("provenance", {})
        _expect_equal(issues, benchmark.get("benchmarkId"), provenance.get("benchmarkId"), f"{path}.provenance.benchmarkId", "BENCHMARK_ID_MISMATCH")
        _expect_equal(issues, benchmark_hash, provenance.get("benchmarkSha256"), f"{path}.provenance.benchmarkSha256", "BENCHMARK_HASH_MISMATCH")
        source_observations = provenance.get("sourceObservationIds", [])
        unknown = sorted(set(source_observations) - set(observations))
        if unknown:
            issues.append(ProductTruthIssue("CALIBRATION_OBSERVATION_UNKNOWN", f"{path}.provenance.sourceObservationIds", f"unknown observation ids: {unknown!r}"))
        for observation_id in source_observations:
            observation = observations.get(observation_id)
            if observation is None:
                continue
            if observation.get("metricId") != threshold.get("metricId"):
                issues.append(ProductTruthIssue("CALIBRATION_METRIC_MISMATCH", f"{path}.metricId", f"observation {observation_id!r} measures {observation.get('metricId')!r}"))
            if observation.get("scope") != threshold.get("scope"):
                issues.append(ProductTruthIssue("CALIBRATION_SCOPE_MISMATCH", f"{path}.scope", f"observation {observation_id!r} has scope {observation.get('scope')!r}"))
            if observation.get("unit") != threshold.get("unit"):
                issues.append(ProductTruthIssue("CALIBRATION_UNIT_MISMATCH", f"{path}.unit", f"observation {observation_id!r} has unit {observation.get('unit')!r}"))
        known_observations = [observations[item] for item in source_observations if item in observations]
        if known_observations:
            try:
                derived_value = _derive_threshold_value(
                    [float(item["value"]) for item in known_observations],
                    provenance.get("derivationMethod"),
                    provenance.get("derivationParameters"),
                )
            except (KeyError, TypeError, ValueError) as exc:
                issues.append(ProductTruthIssue("CALIBRATION_DERIVATION_INVALID", f"{path}.provenance", str(exc)))
            else:
                if not math.isclose(derived_value, float(threshold.get("value")), rel_tol=0, abs_tol=1e-12):
                    issues.append(ProductTruthIssue(
                        "CALIBRATION_DERIVATION_MISMATCH", f"{path}.value",
                        f"declared derivation produces {derived_value!r}, receipt contains {threshold.get('value')!r}",
                    ))
        derived_at = _parse_time(provenance.get("derivedAt"), f"{path}.provenance.derivedAt")
        if derived_at < frozen:
            issues.append(ProductTruthIssue("CALIBRATION_DERIVED_BEFORE_FREEZE", f"{path}.provenance.derivedAt", "threshold derivation precedes benchmark freeze"))
        if derived_at > calibrated:
            issues.append(ProductTruthIssue("CALIBRATION_DERIVED_AFTER_RECEIPT", f"{path}.provenance.derivedAt", "threshold derivation follows receipt calibratedAt"))

    missing = sorted(set(required_map) - set(actual))
    for artifact, pointer in missing:
        issues.append(ProductTruthIssue(
            "CALIBRATION_COVERAGE_MISSING", f"{artifact}:{pointer}",
            "every visual acceptance, capture and scoring number requires reference-derived provenance",
        ))
    for key, threshold in actual.items():
        expected = required_map.get(key)
        if expected is not None and threshold.get("operator") != expected.operator:
            issues.append(ProductTruthIssue("CALIBRATION_OPERATOR_MISMATCH", f"{key[0]}:{key[1]}", f"expected {expected.operator!r}, observed {threshold.get('operator')!r}"))
    return required


def _derive_threshold_value(
    values: list[float], method: Any, parameters: Any
) -> float:
    """Recompute a declared calibration derivation from frozen observations."""

    if not values or any(not math.isfinite(item) for item in values):
        raise ValueError("at least one finite source observation is required")
    if not isinstance(parameters, dict):
        raise ValueError("derivationParameters must be an object")
    ordered = sorted(values)
    if method == "reference-minimum":
        if parameters:
            raise ValueError("reference-minimum accepts no parameters")
        return ordered[0]
    if method == "reference-maximum":
        if parameters:
            raise ValueError("reference-maximum accepts no parameters")
        return ordered[-1]
    if method == "reference-mean":
        allowed = {"sampleCount"}
        if set(parameters) - allowed:
            raise ValueError("reference-mean accepts only sampleCount")
        sample_count = parameters.get("sampleCount", len(values))
        if sample_count != len(values):
            raise ValueError(f"sampleCount declares {sample_count!r}, observed {len(values)}")
        return math.fsum(values) / len(values)
    if method == "reference-quantile":
        if set(parameters) != {"quantile"}:
            raise ValueError("reference-quantile requires only quantile")
        quantile = parameters["quantile"]
        if not _number(quantile) or not 0 <= quantile <= 1:
            raise ValueError("quantile must be a finite number in [0, 1]")
        position = (len(ordered) - 1) * float(quantile)
        lower = math.floor(position)
        upper = math.ceil(position)
        if lower == upper:
            return ordered[lower]
        weight = position - lower
        return ordered[lower] * (1 - weight) + ordered[upper] * weight
    if method == "reference-range":
        if set(parameters) != {"bound"} or parameters.get("bound") not in {"minimum", "maximum"}:
            raise ValueError("reference-range requires bound='minimum' or bound='maximum'")
        return ordered[0] if parameters["bound"] == "minimum" else ordered[-1]
    if method == "director-margin-over-reference":
        if set(parameters) != {"baseline", "margin"}:
            raise ValueError("director-margin-over-reference requires baseline and margin")
        baseline = parameters["baseline"]
        margin = parameters["margin"]
        if baseline not in {"minimum", "maximum", "mean"}:
            raise ValueError("baseline must be minimum, maximum or mean")
        if not _number(margin):
            raise ValueError("margin must be a finite number")
        base = (
            ordered[0] if baseline == "minimum"
            else ordered[-1] if baseline == "maximum"
            else math.fsum(values) / len(values)
        )
        return base + float(margin)
    raise ValueError(f"unsupported derivation method {method!r}")


def load_product_truth(
    root: Path,
    product_intent_path: str | Path,
    runtime_identity_receipt_path: str | Path,
    *,
    expected_product_intent_sha256: str | None,
    expected_runtime_identity_sha256: str | None,
    expected_run_id: str | None,
    expected_build_id: str | None,
    expected_place_sha256: str | None,
) -> ProductTruthBundle:
    """Load one fully cross-bound product-truth bundle or raise.

    Expected hashes and run/build identity must come from the immutable run
    manifest/build provenance.  Making them mandatory prevents a caller from
    treating the receipt's own declarations as corroboration.
    """

    root = root.resolve()
    if not root.is_dir():
        raise _issue("PROJECT_ROOT_MISSING", "root", f"directory does not exist: {root}")
    intent_expected = _validate_expected_hash(expected_product_intent_sha256, "expectedProductIntentSha256")
    runtime_expected = _validate_expected_hash(expected_runtime_identity_sha256, "expectedRuntimeIdentitySha256")
    place_expected = _validate_expected_hash(expected_place_sha256, "expectedPlaceSha256")
    if not isinstance(expected_run_id, str) or not expected_run_id:
        raise _issue("EXPECTED_RUN_ID_MISSING", "expectedRunId", "run id from the immutable manifest is required")
    if not isinstance(expected_build_id, str) or not expected_build_id:
        raise _issue("EXPECTED_BUILD_ID_MISSING", "expectedBuildId", "build id from build provenance is required")

    intent_path = _project_file(root, product_intent_path, "productIntent.path")
    intent, intent_receipt = _load_owned_document(
        root, intent_path, "productIntent", expected_hash=intent_expected
    )
    bindings = intent["bindings"]

    contract, contract_receipt = _load_bound_json(root, bindings["contract"], "contract")
    spec, spec_receipt = _load_bound_json(root, bindings["visualQualitySpec"], "visualQualitySpec")

    benchmark_path = _project_file(
        root, bindings["referenceBenchmark"]["path"], "bindings.referenceBenchmark.path"
    )
    benchmark_hash = _validate_expected_hash(
        bindings["referenceBenchmark"]["sha256"], "bindings.referenceBenchmark.sha256"
    )
    benchmark, benchmark_receipt = _load_owned_document(
        root, benchmark_path, "referenceBenchmark", expected_hash=benchmark_hash
    )
    calibration_path = _project_file(
        root, bindings["visualCalibration"]["path"], "bindings.visualCalibration.path"
    )
    calibration_hash = _validate_expected_hash(
        bindings["visualCalibration"]["sha256"], "bindings.visualCalibration.sha256"
    )
    calibration, calibration_receipt = _load_owned_document(
        root, calibration_path, "visualCalibration", expected_hash=calibration_hash
    )
    runtime_path = _project_file(root, runtime_identity_receipt_path, "runtimeIdentity.path")
    runtime, runtime_receipt = _load_owned_document(
        root, runtime_path, "runtimeIdentity", expected_hash=runtime_expected
    )

    issues: list[ProductTruthIssue] = []
    product_id = intent["productId"]
    artifact_id_pairs = (
        ("contract", bindings["contract"]["artifactId"], contract.get("contractId")),
        ("visualQualitySpec", bindings["visualQualitySpec"]["artifactId"], spec.get("specId")),
        ("referenceBenchmark", bindings["referenceBenchmark"]["artifactId"], benchmark.get("benchmarkId")),
        ("visualCalibration", bindings["visualCalibration"]["artifactId"], calibration.get("calibrationId")),
    )
    for label, bound_id, observed_id in artifact_id_pairs:
        _expect_equal(issues, bound_id, observed_id, f"{label}.id", "ARTIFACT_ID_MISMATCH")
    for label, document in (
        ("contract", contract),
        ("visualQualitySpec", spec),
        ("referenceBenchmark", benchmark),
        ("visualCalibration", calibration),
    ):
        _expect_equal(issues, product_id, document.get("productId"), f"{label}.productId", "PRODUCT_ID_MISMATCH")

    runtime_identity = runtime["measuredIdentity"]
    _expect_equal(issues, product_id, runtime_identity.get("productId"), "runtimeIdentity.measuredIdentity.productId", "RUNTIME_PRODUCT_ID_MISMATCH")
    _expect_equal(issues, contract.get("contractId"), runtime_identity.get("contractId"), "runtimeIdentity.measuredIdentity.contractId", "RUNTIME_CONTRACT_ID_MISMATCH")
    _expect_equal(issues, spec.get("specId"), runtime_identity.get("visualSpecId"), "runtimeIdentity.measuredIdentity.visualSpecId", "RUNTIME_VISUAL_SPEC_ID_MISMATCH")
    _expect_equal(issues, expected_run_id, runtime.get("runId"), "runtimeIdentity.runId", "RUNTIME_RUN_ID_MISMATCH")
    _expect_equal(issues, expected_build_id, runtime.get("buildId"), "runtimeIdentity.buildId", "RUNTIME_BUILD_ID_MISMATCH")

    actual_hashes = {
        "productIntent": intent_receipt.sha256,
        "contract": contract_receipt.sha256,
        "visualQualitySpec": spec_receipt.sha256,
        "referenceBenchmark": benchmark_receipt.sha256,
        "visualCalibration": calibration_receipt.sha256,
        "place": place_expected,
    }
    for name, expected in actual_hashes.items():
        _expect_equal(
            issues, expected, runtime["artifactHashes"].get(name),
            f"runtimeIdentity.artifactHashes.{name}", "RUNTIME_ARTIFACT_HASH_MISMATCH",
        )

    _check_contract_semantics(intent, contract, issues)
    _check_visual_semantics(intent, spec, calibration.get("calibrationId"), issues)
    source_receipts, observations = _check_reference_benchmark(root, product_id, benchmark, issues)
    required_targets = _check_calibration(
        contract, spec, benchmark, benchmark_receipt.sha256, calibration, observations, issues
    )
    _expect_equal(issues, product_id, calibration.get("productId"), "visualCalibration.productId", "PRODUCT_ID_MISMATCH")

    runtime_time = _parse_time(runtime.get("observedAt"), "runtimeIdentity.observedAt")
    for label, value in (
        ("productIntent.authorship.approvedAt", intent.get("authorship", {}).get("approvedAt")),
        ("referenceBenchmark.frozenAt", benchmark.get("frozenAt")),
        ("visualCalibration.methodology.calibratedAt", calibration.get("methodology", {}).get("calibratedAt")),
    ):
        if _parse_time(value, label) > runtime_time:
            issues.append(ProductTruthIssue(
                "PRODUCT_TRUTH_AFTER_RUNTIME", label,
                "product truth must be frozen before candidate runtime identity is observed",
            ))

    if issues:
        raise ProductTruthError(issues)

    bundle = ProductTruthBundle(
        root=root,
        product_id=product_id,
        product_intent=intent,
        contract=contract,
        visual_quality_spec=spec,
        reference_benchmark=benchmark,
        visual_calibration=calibration,
        runtime_identity_receipt=runtime,
        artifacts={
            "productIntent": intent_receipt,
            "contract": contract_receipt,
            "visualQualitySpec": spec_receipt,
            "referenceBenchmark": benchmark_receipt,
            "visualCalibration": calibration_receipt,
            "runtimeIdentity": runtime_receipt,
        },
        reference_sources=source_receipts,
        required_calibration_targets=required_targets,
    )
    bundle.verify_unchanged()
    return bundle


def assess_product_truth(
    root: Path,
    product_intent_path: str | Path,
    runtime_identity_receipt_path: str | Path,
    *,
    expected_product_intent_sha256: str | None = None,
    expected_runtime_identity_sha256: str | None = None,
    expected_run_id: str | None = None,
    expected_build_id: str | None = None,
    expected_place_sha256: str | None = None,
) -> ProductTruthAssessment:
    """Return an explicit READY/BLOCKED decision without a partial bundle."""

    try:
        bundle = load_product_truth(
            root,
            product_intent_path,
            runtime_identity_receipt_path,
            expected_product_intent_sha256=expected_product_intent_sha256,
            expected_runtime_identity_sha256=expected_runtime_identity_sha256,
            expected_run_id=expected_run_id,
            expected_build_id=expected_build_id,
            expected_place_sha256=expected_place_sha256,
        )
    except ProductTruthError as exc:
        return ProductTruthAssessment("BLOCKED", None, exc.issues)
    except Exception as exc:  # a validator defect must block release, never authorize it
        return ProductTruthAssessment(
            "BLOCKED",
            None,
            (ProductTruthIssue("PRODUCT_TRUTH_VALIDATOR_ERROR", "$", f"{type(exc).__name__}: {exc}"),),
        )
    return ProductTruthAssessment("READY", bundle, ())


__all__ = [
    "ArtifactReceipt",
    "CalibrationTarget",
    "ProductTruthAssessment",
    "ProductTruthBundle",
    "ProductTruthError",
    "ProductTruthIssue",
    "assess_product_truth",
    "load_product_truth",
    "required_calibration_targets",
]
