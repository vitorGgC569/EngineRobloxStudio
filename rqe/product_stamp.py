"""Build-time product identity stamp for generic Roblox projects.

The stamp is not product-truth evidence by itself.  It is a content-addressed
claim embedded in the exact Rojo build so the Studio bridge can measure which
contract/spec the candidate says it implements.  ``rqe.product_truth`` later
cross-checks that measured claim against immutable external provenance.
"""

from __future__ import annotations

import hashlib
import json
import re
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Mapping

from .project import Project
from .provenance import sha256_file
from .schema_validation import SchemaDefinitionError, validate_schema_instance


SHA256_RE = re.compile(r"^[0-9a-f]{64}$")
STAMP_NODE_NAME = "RQEProductIdentity"


class ProductStampError(ValueError):
    pass


@dataclass(frozen=True)
class ProductIdentityStamp:
    product_id: str
    intent_id: str
    contract_id: str
    visual_spec_id: str
    hashes: Mapping[str, str]

    @property
    def stamp_sha256(self) -> str:
        encoded = json.dumps(
            self.to_dict(include_stamp_hash=False),
            sort_keys=True,
            ensure_ascii=False,
            separators=(",", ":"),
        ).encode("utf-8")
        return hashlib.sha256(encoded).hexdigest()

    def to_dict(self, *, include_stamp_hash: bool = True) -> dict[str, Any]:
        payload: dict[str, Any] = {
            "schemaVersion": 1,
            "productId": self.product_id,
            "intentId": self.intent_id,
            "contractId": self.contract_id,
            "visualSpecId": self.visual_spec_id,
            "artifactHashes": dict(sorted(self.hashes.items())),
        }
        if include_stamp_hash:
            payload["stampSha256"] = self.stamp_sha256
        return payload

    def to_rojo_attributes(self) -> dict[str, Any]:
        return {
            "SchemaVersion": 1,
            "ProductId": self.product_id,
            "IntentId": self.intent_id,
            "ContractId": self.contract_id,
            "VisualSpecId": self.visual_spec_id,
            "ProductIntentSha256": self.hashes["productIntent"],
            "ContractSha256": self.hashes["contract"],
            "VisualQualitySpecSha256": self.hashes["visualQualitySpec"],
            "ReferenceBenchmarkSha256": self.hashes["referenceBenchmark"],
            "VisualCalibrationSha256": self.hashes["visualCalibration"],
            "StampSha256": self.stamp_sha256,
        }


def load_product_identity_stamp(project: Project) -> ProductIdentityStamp:
    relative = project.config.get("productIntent")
    if not isinstance(relative, str) or not relative.strip():
        raise ProductStampError("rqe.project.json does not configure productIntent")
    root = project.root.resolve()
    intent_path = _project_file(root, relative, "productIntent")
    intent = _read_object(intent_path, "productIntent")
    _validate_owned_document(
        root,
        intent_path,
        intent,
        "productIntent",
        "product-intent.v1.schema.json",
        "https://rqe.local/schemas/product-intent.v1.schema.json",
    )
    product_id = _text(intent.get("productId"), "productIntent.productId")
    intent_id = _text(intent.get("intentId"), "productIntent.intentId")
    bindings = intent.get("bindings")
    if not isinstance(bindings, Mapping):
        raise ProductStampError("productIntent.bindings must be an object")

    receipts: dict[str, tuple[dict[str, Any], Path, str]] = {}
    for name in (
        "contract",
        "visualQualitySpec",
        "referenceBenchmark",
        "visualCalibration",
    ):
        binding = bindings.get(name)
        if not isinstance(binding, Mapping):
            raise ProductStampError(f"productIntent.bindings.{name} must be an object")
        path = _project_file(
            root,
            _text(binding.get("path"), f"productIntent.bindings.{name}.path"),
            f"productIntent.bindings.{name}",
        )
        expected_hash = _hash(binding.get("sha256"), f"productIntent.bindings.{name}.sha256")
        actual_hash = sha256_file(path)
        if actual_hash != expected_hash:
            raise ProductStampError(
                f"productIntent.bindings.{name} hash mismatch: "
                f"expected {expected_hash}, observed {actual_hash}"
            )
        document = _read_object(path, name)
        bound_id = _text(binding.get("artifactId"), f"productIntent.bindings.{name}.artifactId")
        receipts[name] = (document, path, bound_id)

    contract, contract_path, contract_id = receipts["contract"]
    spec, spec_path, visual_spec_id = receipts["visualQualitySpec"]
    benchmark, _, benchmark_id = receipts["referenceBenchmark"]
    calibration, _, calibration_id = receipts["visualCalibration"]
    _validate_owned_document(
        root,
        receipts["referenceBenchmark"][1],
        benchmark,
        "referenceBenchmark",
        "reference-benchmark.v1.schema.json",
        "https://rqe.local/schemas/reference-benchmark.v1.schema.json",
    )
    _validate_owned_document(
        root,
        receipts["visualCalibration"][1],
        calibration,
        "visualCalibration",
        "visual-calibration-receipt.v1.schema.json",
        "https://rqe.local/schemas/visual-calibration-receipt.v1.schema.json",
    )
    observed_ids = {
        "contract": contract.get("contractId"),
        "visualQualitySpec": spec.get("specId"),
        "referenceBenchmark": benchmark.get("benchmarkId"),
        "visualCalibration": calibration.get("calibrationId"),
    }
    expected_ids = {
        "contract": contract_id,
        "visualQualitySpec": visual_spec_id,
        "referenceBenchmark": benchmark_id,
        "visualCalibration": calibration_id,
    }
    for name, expected in expected_ids.items():
        if observed_ids[name] != expected:
            raise ProductStampError(
                f"{name} id mismatch: expected {expected!r}, observed {observed_ids[name]!r}"
            )
    for name, document in (
        ("contract", contract),
        ("visualQualitySpec", spec),
        ("referenceBenchmark", benchmark),
        ("visualCalibration", calibration),
    ):
        if document.get("productId") != product_id:
            raise ProductStampError(
                f"{name}.productId does not match productIntent.productId"
            )

    configured_contract = project.contract_path.resolve()
    if contract_path != configured_contract:
        raise ProductStampError(
            "productIntent contract binding is not the active project contract"
        )
    configured_visual = (contract_path.parent / str(project.contract.get("visualQuality", {}).get("spec", ""))).resolve()
    if spec_path != configured_visual:
        raise ProductStampError(
            "productIntent visualQualitySpec binding is not the active visual spec"
        )

    return ProductIdentityStamp(
        product_id=product_id,
        intent_id=intent_id,
        contract_id=contract_id,
        visual_spec_id=visual_spec_id,
        hashes={
            "productIntent": sha256_file(intent_path),
            "contract": sha256_file(contract_path),
            "visualQualitySpec": sha256_file(spec_path),
            "referenceBenchmark": sha256_file(receipts["referenceBenchmark"][1]),
            "visualCalibration": sha256_file(receipts["visualCalibration"][1]),
        },
    )


def stamped_rojo_project(
    project_file: Path,
    stamp: ProductIdentityStamp,
) -> dict[str, Any]:
    """Return a build-only Rojo project with absolute source paths and stamp."""

    project_file = project_file.resolve()
    raw = _read_object(project_file, "rojoProject")
    tree = raw.get("tree")
    if not isinstance(tree, dict):
        raise ProductStampError("Rojo project tree must be an object")
    _absolutize_rojo_paths(raw, project_file.parent)
    replicated = tree.get("ReplicatedStorage")
    if replicated is None:
        replicated = {"$className": "ReplicatedStorage"}
        tree["ReplicatedStorage"] = replicated
    if not isinstance(replicated, dict):
        raise ProductStampError("Rojo ReplicatedStorage node must be an object")
    if STAMP_NODE_NAME in replicated:
        raise ProductStampError(
            f"Rojo project already defines reserved node {STAMP_NODE_NAME}"
        )
    replicated[STAMP_NODE_NAME] = {
        "$className": "Configuration",
        "$attributes": stamp.to_rojo_attributes(),
    }
    return raw


def _absolutize_rojo_paths(node: Any, base: Path) -> None:
    if isinstance(node, dict):
        path = node.get("$path")
        if isinstance(path, str) and path:
            candidate = Path(path)
            if not candidate.is_absolute():
                candidate = (base / candidate).resolve()
            node["$path"] = candidate.as_posix()
        for value in node.values():
            _absolutize_rojo_paths(value, base)
    elif isinstance(node, list):
        for value in node:
            _absolutize_rojo_paths(value, base)


def _project_file(root: Path, relative: str | Path, label: str) -> Path:
    requested = Path(relative)
    if requested.is_absolute() or any(part in {".", ".."} for part in requested.parts):
        raise ProductStampError(f"{label} must be a normalized project-relative path")
    current = root
    for part in requested.parts:
        current = current / part
        if current.is_symlink():
            raise ProductStampError(f"{label} contains a symlink")
    path = (root / requested).resolve()
    try:
        path.relative_to(root)
    except ValueError as exc:
        raise ProductStampError(f"{label} escapes the project root") from exc
    if not path.is_file():
        raise ProductStampError(f"{label} does not exist: {path}")
    return path


def _read_object(path: Path, label: str) -> dict[str, Any]:
    def reject_duplicates(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
        result: dict[str, Any] = {}
        for key, value in pairs:
            if key in result:
                raise ProductStampError(f"{label} contains duplicate key {key!r}")
            result[key] = value
        return result

    try:
        value = json.loads(
            path.read_text(encoding="utf-8"),
            object_pairs_hook=reject_duplicates,
            parse_constant=lambda value: (_ for _ in ()).throw(
                ProductStampError(f"{label} contains non-finite number {value}")
            ),
        )
    except (OSError, UnicodeError, json.JSONDecodeError) as exc:
        raise ProductStampError(f"{label} is not valid JSON: {exc}") from exc
    if not isinstance(value, dict):
        raise ProductStampError(f"{label} root must be an object")
    return value


def _validate_owned_document(
    root: Path,
    document_path: Path,
    document: dict[str, Any],
    label: str,
    schema_filename: str,
    expected_schema_id: str,
) -> None:
    """Reject a stamp whose trust documents are only shape-like placeholders.

    Product identity is embedded at build time.  Waiting until the running
    place is evaluated to discover that its approval or independent references
    never existed stamps an invalid trust chain into an otherwise valid build.
    The owned schema is therefore a pre-build boundary as well as a runtime
    product-truth boundary.
    """

    declared = document.get("$schema")
    if not isinstance(declared, str) or not declared:
        raise ProductStampError(f"{label} does not declare its owned schema")
    requested = Path(declared)
    if requested.is_absolute():
        raise ProductStampError(f"{label}.$schema must be relative")
    actual = (document_path.parent / requested).resolve()
    expected = (root / "schemas" / schema_filename).resolve()
    if actual != expected:
        raise ProductStampError(
            f"{label}.$schema must resolve to engine-owned {schema_filename}"
        )
    schema = _read_object(expected, f"{label}.ownedSchema")
    if schema.get("$id") != expected_schema_id:
        raise ProductStampError(
            f"{label}.ownedSchema has unexpected $id {schema.get('$id')!r}"
        )
    try:
        issues = validate_schema_instance(document, schema)
    except SchemaDefinitionError as exc:
        raise ProductStampError(f"{label} owned schema is invalid: {exc}") from exc
    if issues:
        raise ProductStampError(
            f"{label} is not approved release input:\n- "
            + "\n- ".join(str(issue) for issue in issues)
        )


def _text(value: object, label: str) -> str:
    if not isinstance(value, str) or not value.strip():
        raise ProductStampError(f"{label} must be a non-empty string")
    return value.strip()


def _hash(value: object, label: str) -> str:
    text = _text(value, label)
    if SHA256_RE.fullmatch(text) is None:
        raise ProductStampError(f"{label} must be a lowercase SHA-256")
    return text


__all__ = [
    "ProductIdentityStamp",
    "ProductStampError",
    "STAMP_NODE_NAME",
    "load_product_identity_stamp",
    "stamped_rojo_project",
]
