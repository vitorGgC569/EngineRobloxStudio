"""Explicit, immutable CLI surface for provider-backed visual reviews.

This command consumes a trustworthy capture manifest plus its exact visual
specification.  It can create visual-review evidence, but it never evaluates a
release gate and every emitted artifact states that it is not release authority.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import uuid
from collections.abc import Callable, Mapping
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

from .openai_vision import OpenAIResponsesError, OpenAIResponsesVisionProvider
from .schema_validation import SchemaDefinitionError, validate_schema_instance
from .visual_review import DEFAULT_PROMPT, VisionProvider, review_captures


class VisualCliError(ValueError):
    """The requested visual-review operation is ambiguous or unsafe."""


ProviderFactory = Callable[..., VisionProvider]


def add_visual_parser(subparsers: argparse._SubParsersAction) -> None:
    visual = subparsers.add_parser(
        "visual",
        help="perform provider-backed visual-quality operations",
    )
    commands = visual.add_subparsers(dest="visual_command", required=True)
    review = commands.add_parser(
        "review",
        help="review a trustworthy capture set; this does not authorize release",
    )
    review.add_argument(
        "capture_manifest",
        help="immutable capture manifest.json beside its referenced PNG files",
    )
    review.add_argument(
        "--spec",
        required=True,
        help="exact visual-quality spec whose file hash equals capture.specHash",
    )
    review.add_argument(
        "--rubric",
        help=(
            "optional rubricByViewpoint JSON; it must exactly match the rubric "
            "derived from --spec"
        ),
    )
    review.add_argument(
        "--model",
        required=True,
        help="explicit OpenAI model id with image input and Structured Outputs support",
    )
    review.add_argument(
        "--prompt-file",
        help="optional UTF-8 prompt; omitted uses the versioned engine prompt",
    )
    review.add_argument(
        "--image-detail",
        choices=("auto", "low", "high", "original"),
        default="high",
    )
    review.add_argument("--timeout-seconds", type=float, default=120.0)
    review.add_argument(
        "--output",
        required=True,
        help="new immutable JSON artifact path; existing/global latest paths are refused",
    )


def run_visual_command(
    args: argparse.Namespace,
    *,
    provider_factory: ProviderFactory = OpenAIResponsesVisionProvider,
) -> tuple[int, dict[str, Any]]:
    if args.command != "visual" or args.visual_command != "review":
        raise VisualCliError("unsupported visual CLI command")

    destination = _validate_new_output(Path(args.output))
    manifest_path = Path(args.capture_manifest).resolve()
    if manifest_path.name != "manifest.json":
        raise VisualCliError("capture manifest must be named manifest.json")
    manifest = _read_object(manifest_path, "capture manifest")
    spec_path = Path(args.spec).resolve()
    spec = _read_and_validate_spec(spec_path)
    if _sha256_file(spec_path) != manifest.get("specHash"):
        raise VisualCliError("visual spec file hash differs from capture.specHash")

    derived_rubric = _rubric_from_spec(spec, manifest)
    if args.rubric:
        submitted = _read_object(Path(args.rubric).resolve(), "visual rubric")
        raw_rubric = submitted.get("rubricByViewpoint", submitted)
        normalized = _normalize_rubric(raw_rubric, "visual rubric")
        if normalized != derived_rubric:
            raise VisualCliError(
                "explicit rubric differs from the rubric derived from the hash-bound visual spec"
            )

    prompt = DEFAULT_PROMPT
    if args.prompt_file:
        prompt_path = Path(args.prompt_file).resolve()
        if prompt_path.is_symlink() or not prompt_path.is_file():
            raise VisualCliError("prompt file must be an existing non-symlink file")
        prompt = prompt_path.read_text(encoding="utf-8")
        if not prompt.strip():
            raise VisualCliError("prompt file must not be empty")

    provider = provider_factory(
        model=args.model,
        timeout_seconds=args.timeout_seconds,
        image_detail=args.image_detail,
    )
    try:
        review = review_captures(
            manifest,
            manifest_path.parent,
            derived_rubric,
            provider,
            prompt=prompt,
        )
    except OpenAIResponsesError as exc:
        payload = {
            "$schema": "rqe://schemas/visual-review-attempt.v1.schema.json",
            "schemaVersion": 1,
            "operation": "rqe.visual.review",
            **exc.to_dict(),
            "runId": manifest.get("runId"),
            "buildHash": manifest.get("buildHash"),
            "placeHash": manifest.get("placeHash"),
            "specHash": manifest.get("specHash"),
            "captureManifestSha256": _sha256_file(manifest_path),
            "model": args.model,
            "createdAt": _now(),
        }
        _validate_attempt_receipt(payload)
        _write_immutable_json(destination, payload)
        return 1, payload

    payload = review.to_dict()
    payload["authorizesRelease"] = False
    _write_immutable_json(destination, payload)
    return 0, payload


def _read_object(path: Path, label: str) -> dict[str, Any]:
    if path.is_symlink() or not path.is_file():
        raise VisualCliError(f"{label} must be an existing non-symlink file")
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise VisualCliError(f"cannot read {label}: {type(exc).__name__}") from exc
    if not isinstance(value, dict):
        raise VisualCliError(f"{label} must be a JSON object")
    return value


def _read_and_validate_spec(path: Path) -> dict[str, Any]:
    spec = _read_object(path, "visual spec")
    schema_ref = spec.get("$schema")
    if not isinstance(schema_ref, str) or not schema_ref:
        raise VisualCliError("visual spec must declare a relative $schema")
    schema_relative = Path(schema_ref)
    if schema_relative.is_absolute():
        raise VisualCliError("visual spec $schema must be relative")
    schema_path = (path.parent / schema_relative).resolve()
    schema = _read_object(schema_path, "visual spec schema")
    if schema.get("$id") != "https://rqe.local/schemas/visual-quality-spec.v1.schema.json":
        raise VisualCliError("visual spec must use the RQE visual-quality-spec.v1 schema")
    owned_schema_path = (
        Path(__file__).resolve().parents[1]
        / "schemas"
        / "visual-quality-spec.v1.schema.json"
    )
    if _sha256_file(schema_path) != _sha256_file(owned_schema_path):
        raise VisualCliError("visual spec schema differs from the engine-owned RQE schema")
    try:
        issues = validate_schema_instance(spec, schema)
    except SchemaDefinitionError as exc:
        raise VisualCliError(
            f"visual spec schema is unsupported: {type(exc).__name__}"
        ) from exc
    if issues:
        raise VisualCliError(
            "visual spec failed schema validation: "
            + "; ".join(str(issue) for issue in issues[:8])
        )
    return spec


def _validate_attempt_receipt(payload: dict[str, Any]) -> None:
    schema_path = (
        Path(__file__).resolve().parents[1]
        / "schemas"
        / "visual-review-attempt.v1.schema.json"
    )
    schema = _read_object(schema_path, "visual review attempt schema")
    try:
        issues = validate_schema_instance(payload, schema)
    except SchemaDefinitionError as exc:
        raise VisualCliError(
            f"visual review attempt schema is unsupported: {type(exc).__name__}"
        ) from exc
    if issues:
        raise VisualCliError(
            "visual review attempt failed schema validation: "
            + "; ".join(str(issue) for issue in issues[:8])
        )


def _rubric_from_spec(
    spec: Mapping[str, Any],
    manifest: Mapping[str, Any],
) -> dict[str, list[str]]:
    required = manifest.get("requiredViewpoints")
    if not isinstance(required, list) or not required:
        raise VisualCliError("capture manifest must name requiredViewpoints")
    if any(not isinstance(item, str) or not item for item in required):
        raise VisualCliError("capture requiredViewpoints must contain non-empty strings")
    if len(required) != len(set(required)):
        raise VisualCliError("capture requiredViewpoints must be unique")
    viewpoints = spec.get("viewpoints")
    if not isinstance(viewpoints, Mapping):
        raise VisualCliError("visual spec viewpoints must be an object")
    rubric: dict[str, list[str]] = {}
    for viewpoint in required:
        definition = viewpoints.get(viewpoint)
        if not isinstance(definition, Mapping):
            raise VisualCliError(
                f"capture viewpoint {viewpoint!r} is absent from the visual spec"
            )
        weights = definition.get("rubric")
        if not isinstance(weights, Mapping) or not weights:
            raise VisualCliError(f"visual spec viewpoint {viewpoint!r} has no rubric")
        if any(
            not isinstance(name, str)
            or not name
            or isinstance(weight, bool)
            or not isinstance(weight, (int, float))
            or weight <= 0
            for name, weight in weights.items()
        ):
            raise VisualCliError(
                f"visual spec viewpoint {viewpoint!r} has an invalid rubric"
            )
        if abs(sum(float(value) for value in weights.values()) - 1.0) > 1e-9:
            raise VisualCliError(
                f"visual spec viewpoint {viewpoint!r} rubric weights must sum to 1"
            )
        rubric[viewpoint] = list(weights)
    return rubric


def _normalize_rubric(raw: Any, label: str) -> dict[str, list[str]]:
    if not isinstance(raw, Mapping) or not raw:
        raise VisualCliError(f"{label} must be a non-empty object")
    result: dict[str, list[str]] = {}
    for viewpoint, criteria in raw.items():
        if not isinstance(viewpoint, str) or not viewpoint:
            raise VisualCliError(f"{label} viewpoint ids must be non-empty strings")
        if not isinstance(criteria, list) or not criteria:
            raise VisualCliError(f"{label}.{viewpoint} must be a non-empty array")
        if any(not isinstance(item, str) or not item for item in criteria):
            raise VisualCliError(f"{label}.{viewpoint} criteria must be non-empty strings")
        if len(criteria) != len(set(criteria)):
            raise VisualCliError(f"{label}.{viewpoint} criteria must be unique")
        result[viewpoint] = list(criteria)
    return result


def _validate_new_output(path: Path) -> Path:
    destination = path.resolve()
    if destination.stem.casefold() == "latest" or any(
        part.casefold() == "latest" for part in destination.parts
    ):
        raise VisualCliError("global latest visual-review artifacts are forbidden")
    if destination.exists() or destination.is_symlink():
        raise VisualCliError(f"visual-review output already exists: {destination}")
    if destination.suffix.casefold() != ".json":
        raise VisualCliError("visual-review output must be a .json file")
    return destination


def _write_immutable_json(path: Path, payload: Mapping[str, Any]) -> None:
    encoded = (
        json.dumps(
            payload,
            indent=2,
            sort_keys=True,
            ensure_ascii=False,
            allow_nan=False,
        )
        + "\n"
    ).encode("utf-8")
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.parent / f".{path.name}.{os.getpid()}.{uuid.uuid4().hex}.tmp"
    try:
        with temporary.open("xb") as handle:
            handle.write(encoded)
            handle.flush()
            os.fsync(handle.fileno())
        try:
            os.link(temporary, path)
        except FileExistsError as exc:
            raise VisualCliError(f"visual-review output already exists: {path}") from exc
        except OSError as exc:
            # Some filesystems do not support hard links.  Exclusive creation
            # preserves the no-overwrite invariant even on that fallback path.
            try:
                with path.open("xb") as handle:
                    handle.write(encoded)
                    handle.flush()
                    os.fsync(handle.fileno())
            except FileExistsError as collision:
                raise VisualCliError(
                    f"visual-review output already exists: {path}"
                ) from collision
            except OSError:
                raise exc
    finally:
        try:
            temporary.unlink()
        except FileNotFoundError:
            pass


def _sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    try:
        with path.open("rb") as handle:
            for chunk in iter(lambda: handle.read(1024 * 1024), b""):
                digest.update(chunk)
    except OSError as exc:
        raise VisualCliError(f"cannot hash artifact {path.name}: {type(exc).__name__}") from exc
    return digest.hexdigest()


def _now() -> str:
    return datetime.now(timezone.utc).isoformat()


__all__ = [
    "VisualCliError",
    "add_visual_parser",
    "run_visual_command",
]
