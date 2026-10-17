"""Honest MCP-facing execution of immutable production DAGs.

This module intentionally exposes much less than the production plan asks for.
The durable executor may only invoke deterministic handlers registered by its
caller, and the factory currently has real adapters for two read-only checks:

* a blueprint specification can verify its hash-bound inputs and product
  identity; and
* a blueprint design can replay the compiler's schema/graph/coverage checks and
  verify the quality-profile inputs it names.

Everything else is left unregistered.  The executor consequently records the
first unsupported production tasks and blocks their dependants instead of
pretending that an intent string is an implementation.  A serialized plan is
also executed with an empty registry: it contains the DAG, but not the source
definition needed to re-prove the specification/design completion checks.

The SQLite journal is control-plane resumability state.  Neither it nor a fully
successful handler result is release evidence, and every response remains
``NOT_VALIDATED`` / ``authorizesRelease=False``.
"""

from __future__ import annotations

import hashlib
import json
import os
import tempfile
from collections import Counter
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Mapping

from rqe.schema_validation import SchemaDefinitionError, validate_schema_instance
from rqe.safe_io import SafeIoError, read_bytes_limited, read_text_limited
from rqe.security import SecurityBoundaryError, resolve_inside

from ..orchestrator import (
    CampaignStage,
    DurableDagExecutor,
    HandlerRegistry,
    HandlerResult,
    ProductionBlueprint,
    SQLiteJournal,
    TaskGraph,
    TaskSpec,
    compile_production_blueprint,
)


class FactoryExecutionError(ValueError):
    """The requested durable execution cannot be made safe or reproducible."""


_SPECIFICATION_CHECKS = frozenset(
    {
        "input hashes match",
        "product identity remains consistent",
        "required fields are explicit",
    }
)
_DESIGN_CHECKS = frozenset(
    {
        "subsystem DAG is acyclic",
        "ownership is complete",
        "coverage matrices are closed",
    }
)


@dataclass(frozen=True)
class LoadedExecutionSource:
    tasks: tuple[TaskSpec, ...]
    plan_sha256: str
    source_kind: str
    source_validation_level: str
    handlers: HandlerRegistry
    registered_scope: str


def _canonical_sha256(value: Any) -> str:
    encoded = json.dumps(
        value,
        sort_keys=True,
        separators=(",", ":"),
        ensure_ascii=False,
    ).encode("utf-8")
    return hashlib.sha256(encoded).hexdigest()


def _read_object(path: Path, label: str) -> dict[str, Any]:
    try:
        payload = json.loads(read_text_limited(path, 16 * 1024 * 1024, label=label))
    except (SafeIoError, json.JSONDecodeError) as exc:
        raise FactoryExecutionError(f"cannot read {label} {path}: {exc}") from exc
    if not isinstance(payload, dict):
        raise FactoryExecutionError(f"{label} root must be an object")
    return payload


def _validate_plan_shape(root: Path, payload: Mapping[str, Any]) -> None:
    schema_path = root / "schemas" / "production-plan.v1.schema.json"
    schema = _read_object(schema_path, "compiled plan schema")
    try:
        issues = validate_schema_instance(dict(payload), schema)
    except SchemaDefinitionError as exc:
        raise FactoryExecutionError(f"invalid compiled plan schema: {exc}") from exc
    if issues:
        raise FactoryExecutionError(
            "invalid compiled production plan: " + "; ".join(str(issue) for issue in issues)
        )


def _tasks_from_serialized_plan(root: Path, payload: dict[str, Any]) -> tuple[TaskSpec, ...]:
    _validate_plan_shape(root, payload)
    declared_hash = str(payload["planSha256"])
    unsigned = dict(payload)
    unsigned.pop("planSha256", None)
    observed_hash = _canonical_sha256(unsigned)
    if observed_hash != declared_hash:
        raise FactoryExecutionError(
            "compiled plan hash mismatch: "
            f"declared {declared_hash}, observed {observed_hash}; refusing altered work"
        )

    tasks: list[TaskSpec] = []
    for project in payload["projects"]:
        for raw in project["tasks"]:
            tasks.append(
                TaskSpec(
                    id=str(raw["taskId"]),
                    stage=CampaignStage(str(raw["stage"])),
                    role=str(raw["role"]),
                    intent=str(raw["intent"]),
                    blocked_by=tuple(str(item) for item in raw["dependsOn"]),
                    read_set=tuple(str(item) for item in raw["readSet"]),
                    write_set=tuple(str(item) for item in raw["writeSet"]),
                    resource_claims=tuple(str(item) for item in raw["resourceClaims"]),
                    completion_checks=tuple(str(item) for item in raw["completionChecks"]),
                    guard_required=bool(raw["guardRequired"]),
                    metadata=dict(raw["metadata"]),
                )
            )

    # Re-validates global ids, dependencies and acyclicity instead of trusting
    # the fact that the JSON happened to match its structural schema.
    return TaskGraph(tasks).tasks


def _safe_reference_path(root: Path, relative: str) -> tuple[Path | None, str | None]:
    try:
        return resolve_inside(root, relative, label="reference path"), None
    except SecurityBoundaryError as exc:
        return None, str(exc)


def _verify_json_reference(
    root: Path,
    *,
    path: str,
    expected_sha256: str,
    label: str,
) -> tuple[dict[str, Any], dict[str, Any] | None, list[str]]:
    resolved, path_error = _safe_reference_path(root, path)
    receipt: dict[str, Any] = {
        "label": label,
        "path": path,
        "expectedSha256": expected_sha256,
    }
    blockers: list[str] = []
    if path_error is not None or resolved is None:
        blockers.append(path_error or f"cannot resolve {label}")
        receipt["verified"] = False
        return receipt, None, blockers
    if not resolved.is_file():
        blockers.append(f"{label} does not exist: {path}")
        receipt["verified"] = False
        return receipt, None, blockers

    try:
        raw = read_bytes_limited(resolved, 16 * 1024 * 1024, label=label)
    except SafeIoError as exc:
        blockers.append(str(exc))
        receipt["verified"] = False
        return receipt, None, blockers
    observed = hashlib.sha256(raw).hexdigest()
    receipt.update(
        {
            "observedSha256": observed,
            "bytes": len(raw),
            "verified": observed == expected_sha256,
        }
    )
    if observed != expected_sha256:
        blockers.append(
            f"{label} hash mismatch: expected {expected_sha256}, observed {observed}"
        )

    try:
        document = json.loads(raw.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        blockers.append(f"{label} is not a UTF-8 JSON document: {exc}")
        return receipt, None, blockers
    if not isinstance(document, dict):
        blockers.append(f"{label} root must be an object")
        return receipt, None, blockers
    return receipt, document, blockers


def _verify_nested_references(
    root: Path,
    bundle: Mapping[str, Any],
    *,
    label: str,
) -> tuple[list[dict[str, Any]], list[str]]:
    references = bundle.get("references")
    if not isinstance(references, list) or not references:
        return [], [f"{label} does not declare a non-empty references array"]

    receipts: list[dict[str, Any]] = []
    blockers: list[str] = []
    for index, item in enumerate(references):
        if not isinstance(item, dict):
            blockers.append(f"{label} reference {index} is not an object")
            continue
        relative = item.get("path")
        expected = item.get("sha256")
        if not isinstance(relative, str) or not relative.strip():
            blockers.append(f"{label} reference {index} has no path")
            continue
        if not isinstance(expected, str) or len(expected) != 64:
            blockers.append(f"{label} reference {index} has no valid sha256")
            continue
        resolved, path_error = _safe_reference_path(root, relative)
        receipt: dict[str, Any] = {
            "id": item.get("id"),
            "path": relative,
            "expectedSha256": expected,
        }
        if path_error is not None or resolved is None:
            blockers.append(path_error or f"cannot resolve {label} reference {index}")
            receipt["verified"] = False
        elif not resolved.is_file():
            blockers.append(f"{label} reference does not exist: {relative}")
            receipt["verified"] = False
        else:
            try:
                raw = read_bytes_limited(resolved, 16 * 1024 * 1024, label=f"{label} reference")
            except SafeIoError as exc:
                blockers.append(str(exc))
                receipt["verified"] = False
                receipts.append(receipt)
                continue
            observed = hashlib.sha256(raw).hexdigest()
            receipt["observedSha256"] = observed
            receipt["verified"] = observed == expected
            if observed != expected:
                blockers.append(
                    f"{label} reference hash mismatch for {relative}: "
                    f"expected {expected}, observed {observed}"
                )
        receipts.append(receipt)
    return receipts, blockers


def _materialize_verification_receipt(
    root: Path,
    context: Any,
    *,
    artifact_kind: str,
    detail: Mapping[str, Any],
) -> tuple[str | None, str | None]:
    """Atomically create the task's declared write or verify an identical one.

    A verifier that only returns success would leave the DAG's writeSet a lie.
    These two adapters therefore produce a deterministic, plan-bound receipt
    under their one declared output root.  Existing different content is never
    overwritten: it may belong to another plan or a human-owned process.
    """

    writes = tuple(context.task.write_set)
    if len(writes) != 1:
        return None, (
            f"verification task {context.task.id!r} must declare exactly one write root, "
            f"observed {len(writes)}"
        )
    directory, path_error = _safe_reference_path(root, writes[0])
    if path_error is not None or directory is None:
        return None, path_error or f"cannot resolve write root {writes[0]!r}"
    if directory.exists() and not directory.is_dir():
        return None, f"declared write root is not a directory: {writes[0]}"
    directory.mkdir(parents=True, exist_ok=True)
    target = directory / "verification.json"
    receipt = {
        "schemaVersion": 1,
        "artifactKind": artifact_kind,
        "planSha256": context.plan_sha256,
        "taskId": context.task.id,
        "handlerKey": context.handler_key,
        "idempotencyKey": context.idempotency_key,
        "completedChecks": list(context.task.completion_checks),
        "validationLevel": "STATICALLY_VALIDATED",
        "authorizesRelease": False,
        "studioUsed": False,
        "detail": dict(detail),
    }
    encoded = json.dumps(receipt, indent=2, sort_keys=True, ensure_ascii=False) + "\n"

    if target.exists():
        try:
            existing = json.loads(target.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError) as exc:
            return None, f"existing verification receipt is unreadable: {target}: {exc}"
        if existing != receipt:
            return None, (
                f"refusing to overwrite a different verification receipt at {writes[0]}/"
                "verification.json"
            )
        return target.relative_to(root).as_posix(), None

    temporary_name: str | None = None
    try:
        with tempfile.NamedTemporaryFile(
            mode="w",
            encoding="utf-8",
            newline="\n",
            prefix=".verification.",
            suffix=".tmp",
            dir=directory,
            delete=False,
        ) as temporary:
            temporary.write(encoded)
            temporary.flush()
            os.fsync(temporary.fileno())
            temporary_name = temporary.name
        try:
            # A hard-link publishes the already-flushed bytes without an
            # overwrite window.  If another worker published first, compare
            # below and accept only byte-equivalent semantic content.
            os.link(temporary_name, target)
        except FileExistsError:
            try:
                existing = json.loads(target.read_text(encoding="utf-8"))
            except (OSError, json.JSONDecodeError) as exc:
                return None, (
                    f"another worker published an unreadable verification receipt at "
                    f"{writes[0]}/verification.json: {exc}"
                )
            if existing != receipt:
                return None, (
                    f"another worker published a different verification receipt at "
                    f"{writes[0]}/verification.json"
                )
        except OSError as exc:
            return None, f"cannot atomically publish verification receipt {target}: {exc}"
    finally:
        if temporary_name is not None:
            try:
                Path(temporary_name).unlink()
            except FileNotFoundError:
                pass

    return target.relative_to(root).as_posix(), None


def _specification_handler(root: Path, project: Any):
    def verify(context: Any) -> HandlerResult:
        context.raise_if_cancelled()
        receipts: list[dict[str, Any]] = []
        blockers: list[str] = []

        intent_receipt, intent, intent_blockers = _verify_json_reference(
            root,
            path=project.product_intent_ref.path,
            expected_sha256=project.product_intent_ref.sha256,
            label=f"{project.product_id} product intent",
        )
        bundle_receipt, bundle, bundle_blockers = _verify_json_reference(
            root,
            path=project.reference_bundle_ref.path,
            expected_sha256=project.reference_bundle_ref.sha256,
            label=f"{project.product_id} reference bundle",
        )
        receipts.extend((intent_receipt, bundle_receipt))
        blockers.extend((*intent_blockers, *bundle_blockers))

        for label, document in (("product intent", intent), ("reference bundle", bundle)):
            if document is not None and document.get("productId") != project.product_id:
                blockers.append(
                    f"{project.product_id} {label} productId is "
                    f"{document.get('productId')!r}, expected {project.product_id!r}"
                )

        nested_receipts: list[dict[str, Any]] = []
        if bundle is not None:
            nested_receipts, nested_blockers = _verify_nested_references(
                root,
                bundle,
                label=f"{project.product_id} reference bundle",
            )
            blockers.extend(nested_blockers)

        identity_consistent = (
            context.task.metadata.get("productId") == project.product_id
            and context.task.metadata.get("projectId") == project.project_id
            and project.product_intent_ref.product_id == project.product_id
            and project.reference_bundle_ref.product_id == project.product_id
        )
        if not identity_consistent:
            blockers.append(f"task identity does not match product {project.product_id!r}")

        payload = {
            "verificationOnly": True,
            "projectId": project.project_id,
            "productId": project.product_id,
            "projectDefinitionSha256": project.sha256,
            "schemaValidated": [
                "production-blueprint.v1.schema.json",
                "game-project-definition.v1.schema.json",
            ],
            "inputReceipts": receipts,
            "referenceReceipts": nested_receipts,
            "productIdentityConsistent": identity_consistent,
        }
        if blockers:
            return HandlerResult.blocked(
                "SPECIFICATION_NOT_VERIFIED",
                "the blueprint specification checks could not all be proven",
                blockers=blockers,
                payload=payload,
            )
        artifact_path, write_blocker = _materialize_verification_receipt(
            root,
            context,
            artifact_kind="SPECIFICATION_VERIFICATION",
            detail=payload,
        )
        if write_blocker is not None:
            return HandlerResult.blocked(
                "SPECIFICATION_ARTIFACT_NOT_WRITTEN",
                "the verified specification could not be materialized",
                blockers=(write_blocker,),
                payload=payload,
            )
        payload["artifact"] = artifact_path
        return HandlerResult.succeeded(
            payload,
            completed_checks=context.task.completion_checks,
            validation_level="STATICALLY_VALIDATED",
        )

    return verify


def _design_handler(root: Path, project: Any):
    def verify(context: Any) -> HandlerResult:
        context.raise_if_cancelled()
        blockers: list[str] = []
        quality_receipts: list[dict[str, Any]] = []
        for profile in project.quality_profiles:
            receipt, document, reference_blockers = _verify_json_reference(
                root,
                path=profile.input_ref.path,
                expected_sha256=profile.input_ref.sha256,
                label=f"{project.product_id} quality profile {profile.id}",
            )
            quality_receipts.append(receipt)
            blockers.extend(reference_blockers)
            if document is not None:
                if document.get("profileId") != profile.id:
                    blockers.append(
                        f"quality profile {profile.id!r} document identifies "
                        f"{document.get('profileId')!r}"
                    )
                applies_to = document.get("appliesTo")
                if not isinstance(applies_to, list) or set(applies_to) != set(profile.applies_to):
                    blockers.append(
                        f"quality profile {profile.id!r} appliesTo does not match the blueprint"
                    )

        subsystem_ids = {item.id for item in project.subsystems}
        ownership_ids = [item.subsystem_id for item in project.ownership]
        ownership_complete = (
            len(ownership_ids) == len(set(ownership_ids))
            and set(ownership_ids) == subsystem_ids
        )
        if not ownership_complete:
            blockers.append("ownership does not cover each subsystem exactly once")

        device_ids = {item.id for item in project.device_viewpoint_matrix.devices}
        viewpoint_ids = {item.id for item in project.device_viewpoint_matrix.viewpoints}
        combinations = set(project.device_viewpoint_matrix.combinations)
        capture_closed = (
            bool(combinations)
            and {item.device_id for item in combinations} == device_ids
            and {item.viewpoint_id for item in combinations} == viewpoint_ids
            and all(
                item.device_id in device_ids and item.viewpoint_id in viewpoint_ids
                for item in combinations
            )
        )
        profile_ids = {item.id for item in project.quality_profiles}
        asset_links_closed = all(
            set(item.consumers) <= subsystem_ids
            and (item.acceptance_profile_id is None or item.acceptance_profile_id in profile_ids)
            for item in project.asset_needs
        )
        coverage_closed = (
            capture_closed
            and asset_links_closed
            and bool(project.scenario_classes)
            and any(item.required_for_release for item in project.scenario_classes)
            and bool(project.quality_profiles)
            and any(item.required_for_release for item in project.quality_profiles)
        )
        if not coverage_closed:
            blockers.append("one or more declared coverage matrices are open")

        # Construction of ``project`` already ran the compiler's explicit DFS
        # and rejected unknown dependencies or cycles.  Recheck the references
        # here so the receipt states what was actually established.
        dependency_links_closed = all(
            set(item.dependencies) <= subsystem_ids and item.id not in item.dependencies
            for item in project.subsystems
        )
        if not dependency_links_closed:
            blockers.append("subsystem dependency references are not closed")

        payload = {
            "verificationOnly": True,
            "projectId": project.project_id,
            "productId": project.product_id,
            "projectDefinitionSha256": project.sha256,
            "compilerChecks": {
                "subsystemDagAcyclic": dependency_links_closed,
                "subsystemCount": len(project.subsystems),
                "ownershipComplete": ownership_complete,
                "captureMatrixClosed": capture_closed,
                "assetLinksClosed": asset_links_closed,
                "requiredScenarioCoverage": any(
                    item.required_for_release for item in project.scenario_classes
                ),
                "requiredQualityCoverage": any(
                    item.required_for_release for item in project.quality_profiles
                ),
            },
            "compiledWork": {
                "seed": project.seed,
                "genre": project.genre,
                "templateId": project.template_id,
                "subsystems": [item.to_dict() for item in project.subsystems],
                "ownership": [item.to_dict() for item in project.ownership],
                "scenarioClasses": [item.to_dict() for item in project.scenario_classes],
                "deviceViewpointMatrix": project.device_viewpoint_matrix.to_dict(),
                "assetNeeds": [item.to_dict() for item in project.asset_needs],
                "qualityProfiles": [item.to_dict() for item in project.quality_profiles],
                "outputArtifacts": [item.to_dict() for item in project.output_artifact_refs],
            },
            "qualityProfileReceipts": quality_receipts,
        }
        if blockers:
            return HandlerResult.blocked(
                "DESIGN_NOT_VERIFIED",
                "the blueprint design checks could not all be proven",
                blockers=blockers,
                payload=payload,
            )
        artifact_path, write_blocker = _materialize_verification_receipt(
            root,
            context,
            artifact_kind="DESIGN_VERIFICATION",
            detail=payload,
        )
        if write_blocker is not None:
            return HandlerResult.blocked(
                "DESIGN_ARTIFACT_NOT_WRITTEN",
                "the verified design could not be materialized",
                blockers=(write_blocker,),
                payload=payload,
            )
        payload["artifact"] = artifact_path
        return HandlerResult.succeeded(
            payload,
            completed_checks=context.task.completion_checks,
            validation_level="STATICALLY_VALIDATED",
        )

    return verify


def _blueprint_handlers(root: Path, blueprint: ProductionBlueprint, plan: Any) -> HandlerRegistry:
    registry = HandlerRegistry()
    projects = {item.product_id: item for item in blueprint.projects}
    for compiled in plan.projects:
        project = projects[compiled.product_id]
        if compiled.project_definition_sha256 != project.sha256:
            # This should be impossible through the compiler.  An empty route
            # is safer than registering against an identity we cannot bind.
            continue
        tasks = {item.id: item for item in compiled.tasks}
        specify = tasks.get(f"{project.product_id}.specify")
        if (
            specify is not None
            and specify.stage is CampaignStage.SPECIFYING
            and specify.role == "product-architect"
            and frozenset(specify.completion_checks) == _SPECIFICATION_CHECKS
            and not specify.guard_required
        ):
            registry.register_task(
                specify.id,
                _specification_handler(root, project),
                version="blueprint-specification-verifier-v1",
                replay_safe=True,
                max_attempts=1,
            )

        design = tasks.get(f"{project.product_id}.design")
        if (
            design is not None
            and design.stage is CampaignStage.PLANNED
            and design.role == "systems-architect"
            and frozenset(design.completion_checks) == _DESIGN_CHECKS
            and not design.guard_required
        ):
            registry.register_task(
                design.id,
                _design_handler(root, project),
                version="blueprint-design-verifier-v1",
                replay_safe=True,
                max_attempts=1,
            )
    return registry


def load_execution_source(root: Path, path: Path) -> LoadedExecutionSource:
    payload = _read_object(path, "factory execution source")
    if "planSha256" in payload or "planId" in payload:
        tasks = _tasks_from_serialized_plan(root, payload)
        return LoadedExecutionSource(
            tasks=tasks,
            plan_sha256=str(payload["planSha256"]),
            source_kind="COMPILED_PLAN",
            source_validation_level="STATICALLY_VALIDATED",
            handlers=HandlerRegistry(),
            registered_scope="none; serialized plans do not carry source proof for their checks",
        )

    try:
        blueprint = ProductionBlueprint.from_dict(payload, schema_dir=root / "schemas")
        plan = compile_production_blueprint(blueprint, schema_dir=root / "schemas")
    except Exception as exc:  # noqa: BLE001 - normalized at this tool boundary
        raise FactoryExecutionError(f"cannot compile production blueprint: {exc}") from exc
    tasks = tuple(task for project in plan.projects for task in project.tasks)
    return LoadedExecutionSource(
        tasks=tasks,
        plan_sha256=plan.sha256,
        source_kind="BLUEPRINT",
        source_validation_level="STATICALLY_VALIDATED",
        handlers=_blueprint_handlers(root, blueprint, plan),
        registered_scope="read-only blueprint specification/design verification",
    )


def execute_factory_action(
    *,
    root: Path,
    source_path: Path,
    source_relative: str,
    journal_path: Path,
    journal_relative: str,
    campaign_id: str,
    action: str,
    worker_id: str,
    max_tasks: int | None = None,
    cancellation_reason: str | None = None,
) -> dict[str, Any]:
    loaded = load_execution_source(root, source_path)

    with SQLiteJournal(journal_path) as journal:
        already_bound = any(
            event.kind == "CAMPAIGN_BOUND" for event in journal.events(campaign_id)
        )
        if action == "run" and already_bound:
            raise FactoryExecutionError(
                f"campaign {campaign_id!r} already has durable state; use resume or inspect"
            )
        if action == "resume" and not already_bound:
            raise FactoryExecutionError(
                f"campaign {campaign_id!r} has no durable state to resume; use run"
            )
        if action not in {"run", "resume"} and max_tasks is not None:
            raise FactoryExecutionError("maxTasks is only valid for run or resume")

        executor = DurableDagExecutor(
            tasks=loaded.tasks,
            plan_sha256=loaded.plan_sha256,
            campaign_id=campaign_id,
            worker_id=worker_id,
            journal=journal,
            handlers=loaded.handlers,
        )
        if action == "inspect":
            report = executor.inspect()
        elif action in {"run", "resume"}:
            report = executor.run(max_tasks=max_tasks)
        elif action == "cancel":
            if not isinstance(cancellation_reason, str) or not cancellation_reason.strip():
                raise FactoryExecutionError("cancel requires a non-empty cancellationReason")
            executor.request_cancellation(cancellation_reason.strip())
            # Materialise cancellation for every pending task when this worker
            # can obtain the scheduler lease.  If another worker owns it, the
            # durable request is still visible in the returned report and that
            # worker will observe it at its next cancellation boundary.
            report = executor.run()
        else:  # protected by the MCP schema, kept defensive for direct callers
            raise FactoryExecutionError(f"unknown factory execution action: {action!r}")

        events = journal.events(campaign_id)

    report_payload = report.to_dict()
    status_counts = Counter(item.status.value for item in report.tasks)
    unsupported = [item.task_id for item in report.tasks if item.status.value == "UNSUPPORTED"]
    blocked = [item.task_id for item in report.tasks if item.status.value == "BLOCKED"]

    if loaded.source_kind == "COMPILED_PLAN":
        remaining_gap = (
            "The serialized plan omits the source definition needed to re-prove its "
            "specification/design checks, so its handler registry is empty. Root tasks "
            "become UNSUPPORTED and dependants become BLOCKED when run."
        )
    else:
        remaining_gap = (
            "Only read-only blueprint specification/design verification has deterministic "
            "adapters. Asset production, subsystem/source build, integration, Studio "
            "measurement, gameplay, capture, evaluation, repair, regression, and release-"
            "candidate assembly have no registered executor adapter and remain UNSUPPORTED "
            "or BLOCKED."
        )

    return {
        **report_payload,
        "action": action,
        "source": source_relative,
        "sourceKind": loaded.source_kind,
        "sourceValidationLevel": loaded.source_validation_level,
        "journal": journal_relative,
        "journalPersisted": journal_path.is_file(),
        "journalEventCount": len(events),
        "registeredHandlers": list(loaded.handlers.keys()),
        "registeredScope": loaded.registered_scope,
        "statusCounts": dict(sorted(status_counts.items())),
        "unsupportedTasks": unsupported,
        "blockedTasks": blocked,
        "studioUsed": False,
        "studioEvidence": "NOT_COLLECTED",
        # Reasserted here even though the executor owns the same invariant, so
        # future report changes cannot accidentally expand this MCP receipt.
        "validationLevel": "NOT_VALIDATED",
        "authorizesRelease": False,
        "remainingGap": remaining_gap,
        "note": (
            "This is durable control-plane execution only. Verification handlers persist "
            "journal checkpoints; they do not build a game, use Studio, or authorize release."
        ),
    }


__all__ = [
    "FactoryExecutionError",
    "LoadedExecutionSource",
    "execute_factory_action",
    "load_execution_source",
]
