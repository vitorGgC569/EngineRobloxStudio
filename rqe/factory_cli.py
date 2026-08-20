"""Machine-readable CLI surfaces for production planning and capability selection.

These commands inspect source-controlled definitions and compile deterministic
plans.  They do not execute production work and never authorize a release.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
from typing import Any, Mapping

from .models import VALIDATION_LEVELS
from .orchestrator.blueprint import (
    ProductionBlueprint,
    compile_production_blueprint,
    load_production_blueprint,
)
from .production_capabilities import (
    CATALOG_RELATIVE_PATH,
    ProductionCapabilityCatalog,
    write_structured_receipt,
)
from .schema_validation import SchemaDefinitionError, validate_schema_instance


INSPECTION_SCHEMA_URI = "rqe://schemas/production-blueprint-inspection.v1.schema.json"
INSPECTION_SCHEMA_PATH = Path("schemas/production-blueprint-inspection.v1.schema.json")


class FactoryCliError(ValueError):
    """A CLI request would produce an ambiguous or unsafe factory artifact."""


def add_factory_parsers(subparsers: argparse._SubParsersAction) -> None:
    capabilities = subparsers.add_parser(
        "capabilities",
        help="inspect or select the versioned industrial capability inventory",
    )
    capability_commands = capabilities.add_subparsers(
        dest="capabilities_command", required=True
    )

    report = capability_commands.add_parser(
        "report",
        help="report catalog integrity separately from production readiness",
    )
    _catalog_arguments(report)
    _output_argument(report)

    select = capability_commands.add_parser(
        "select",
        help="create a fail-closed receipt for a requested production slice",
    )
    _catalog_arguments(select)
    select.add_argument(
        "--phase",
        action="append",
        default=[],
        help="production phase to select; repeatable and unioned with --capability",
    )
    select.add_argument(
        "--capability",
        action="append",
        default=[],
        help="capability id to select; repeatable and unioned with --phase",
    )
    select.add_argument(
        "--minimum-validation-level",
        choices=VALIDATION_LEVELS,
        default="STATICALLY_VALIDATED",
        help="minimum declared evidence level required for every selected capability",
    )
    _output_argument(select)

    factory = subparsers.add_parser(
        "factory",
        help="validate and compile generic multi-game production blueprints",
    )
    factory_commands = factory.add_subparsers(dest="factory_command", required=True)

    inspect = factory_commands.add_parser(
        "inspect",
        help="validate a blueprint and emit a non-executing structural inspection",
    )
    inspect.add_argument("blueprint", help="production-blueprint.v1 JSON")
    _output_argument(inspect)

    compile_parser = factory_commands.add_parser(
        "compile",
        help="compile a validated blueprint into a deterministic production task DAG",
    )
    compile_parser.add_argument("blueprint", help="production-blueprint.v1 JSON")
    _output_argument(compile_parser)


def run_factory_command(args: argparse.Namespace) -> tuple[int, dict[str, Any]]:
    """Execute one read/compile-only command and return its structured payload."""

    if args.command == "capabilities":
        catalog = ProductionCapabilityCatalog.load(
            Path(args.path).resolve(),
            args.catalog,
        )
        if args.capabilities_command == "report":
            payload = catalog.coverage_report()
            _write_capability_output(args.output, payload)
            return (0 if payload["integrityStatus"] == "PASS" else 1), payload
        if args.capabilities_command == "select":
            payload = catalog.select(
                phases=args.phase,
                capability_ids=args.capability,
                minimum_validation_level=args.minimum_validation_level,
            )
            _write_capability_output(args.output, payload)
            return (0 if payload["selectionStatus"] == "PASS" else 1), payload
        raise FactoryCliError(
            f"unknown capabilities command: {args.capabilities_command}"
        )

    if args.command == "factory":
        blueprint_path = Path(args.blueprint).resolve()
        blueprint = load_production_blueprint(blueprint_path)
        if args.factory_command == "inspect":
            payload = inspect_blueprint(blueprint)
        elif args.factory_command == "compile":
            payload = compile_production_blueprint(blueprint).to_dict()
        else:
            raise FactoryCliError(f"unknown factory command: {args.factory_command}")
        _write_factory_output(args.output, payload)
        return 0, payload

    raise FactoryCliError(f"unsupported factory CLI command: {args.command}")


def inspect_blueprint(blueprint: ProductionBlueprint) -> dict[str, Any]:
    """Return a deterministic, static-only view of one validated blueprint."""

    project_rows: list[dict[str, Any]] = []
    for project in blueprint.projects:
        row: dict[str, Any] = {
            "projectId": project.project_id,
            "productId": project.product_id,
            "definitionSha256": project.sha256,
            "sourceRoot": project.source_root,
            "artifactRoot": project.artifact_root,
            "subsystemTotal": len(project.subsystems),
            "assetNeedTotal": len(project.asset_needs),
            "requiredAssetNeedTotal": sum(
                item.required_for_release for item in project.asset_needs
            ),
            "scenarioClassTotal": len(project.scenario_classes),
            "requiredScenarioClassTotal": sum(
                item.required_for_release for item in project.scenario_classes
            ),
            "captureCombinationTotal": len(
                project.device_viewpoint_matrix.combinations
            ),
            "qualityProfileTotal": len(project.quality_profiles),
            "requiredQualityProfileTotal": sum(
                item.required_for_release for item in project.quality_profiles
            ),
            "outputKinds": sorted(item.kind for item in project.output_artifact_refs),
        }
        if project.genre is not None:
            row["genre"] = project.genre
        if project.template_id is not None:
            row["templateId"] = project.template_id
        project_rows.append(row)

    summary = {
        "projectTotal": len(blueprint.projects),
        "subsystemTotal": sum(len(item.subsystems) for item in blueprint.projects),
        "assetNeedTotal": sum(len(item.asset_needs) for item in blueprint.projects),
        "scenarioClassTotal": sum(
            len(item.scenario_classes) for item in blueprint.projects
        ),
        "captureCombinationTotal": sum(
            len(item.device_viewpoint_matrix.combinations)
            for item in blueprint.projects
        ),
        "qualityProfileTotal": sum(
            len(item.quality_profiles) for item in blueprint.projects
        ),
    }
    identity = {
        "blueprintSha256": blueprint.sha256,
        "engine": blueprint.engine.to_dict(),
        "projects": project_rows,
        "summary": summary,
    }
    payload = {
        "$schema": INSPECTION_SCHEMA_URI,
        "schemaVersion": 1,
        "reportType": "rqe.production-blueprint-inspection",
        "inspectionId": _canonical_sha256(identity),
        "authorizesRelease": False,
        "validationLevel": "STATICALLY_VALIDATED",
        "blueprint": {
            "id": blueprint.blueprint_id,
            "revision": blueprint.revision,
            "sha256": blueprint.sha256,
        },
        "engine": blueprint.engine.to_dict(),
        "summary": summary,
        "projects": project_rows,
        "limitations": [
            "Declarative structure and product isolation were inspected; no task was executed and no release was authorized."
        ],
    }
    _validate_inspection(payload)
    return payload


def _catalog_arguments(parser: argparse.ArgumentParser) -> None:
    parser.add_argument(
        "path",
        nargs="?",
        default=".",
        help="repository root containing the catalog and its bound command manifest",
    )
    parser.add_argument(
        "--catalog",
        default=CATALOG_RELATIVE_PATH.as_posix(),
        help="catalog path relative to the repository root",
    )


def _output_argument(parser: argparse.ArgumentParser) -> None:
    parser.add_argument(
        "--output",
        help="explicit artifact path; omitted means JSON is printed only",
    )


def _validated_output_path(value: str) -> Path:
    destination = Path(value).resolve()
    if destination.stem.casefold() == "latest":
        raise FactoryCliError(
            "global latest artifacts are forbidden; choose a run-, plan-, or receipt-specific path"
        )
    return destination


def _write_capability_output(
    output: str | None,
    payload: Mapping[str, Any],
) -> None:
    if output is None:
        return
    write_structured_receipt(_validated_output_path(output), payload)


def _write_factory_output(output: str | None, payload: Mapping[str, Any]) -> None:
    if output is None:
        return
    if payload.get("schemaVersion") != 1:
        raise FactoryCliError("factory output must declare schemaVersion 1")
    if payload.get("authorizesRelease") is True:
        raise FactoryCliError("factory planning artifacts cannot authorize release")
    destination = _validated_output_path(output)
    destination.parent.mkdir(parents=True, exist_ok=True)
    temporary = destination.with_name(f".{destination.name}.{os.getpid()}.tmp")
    temporary.write_text(
        json.dumps(payload, indent=2, sort_keys=True, ensure_ascii=False) + "\n",
        encoding="utf-8",
    )
    os.replace(temporary, destination)


def _validate_inspection(payload: dict[str, Any]) -> None:
    root = Path(__file__).resolve().parents[1]
    try:
        schema = json.loads((root / INSPECTION_SCHEMA_PATH).read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise FactoryCliError(f"cannot read blueprint inspection schema: {exc}") from exc
    try:
        issues = validate_schema_instance(payload, schema)
    except SchemaDefinitionError as exc:
        raise FactoryCliError(f"invalid blueprint inspection schema: {exc}") from exc
    if issues:
        raise FactoryCliError(
            "generated blueprint inspection failed schema validation:\n- "
            + "\n- ".join(str(item) for item in issues)
        )


def _canonical_sha256(value: Mapping[str, Any]) -> str:
    encoded = json.dumps(
        value,
        sort_keys=True,
        separators=(",", ":"),
        ensure_ascii=False,
    ).encode("utf-8")
    return hashlib.sha256(encoded).hexdigest()


__all__ = [
    "FactoryCliError",
    "add_factory_parsers",
    "inspect_blueprint",
    "run_factory_command",
]
