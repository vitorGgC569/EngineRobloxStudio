"""One immutable, fail-closed release attempt.

The legacy commands remain diagnostic.  This module is the only place allowed
to decide whether a build may ship, and it never reads the hand-written game
fixture.
"""

from __future__ import annotations

import json
import os
import time
import subprocess
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

from .contract import validate_contract
from .hub.client import StudioBridge
from .hub.lifecycle import restart_for_bridge, start_play_solo
from .measurement_plan import MeasurementPlan, compile_measurement_plan
from .models import Evidence
from .observe import Observation, measure_place
from .project import Project
from .product_stamp import (
    ProductIdentityStamp,
    ProductStampError,
    load_product_identity_stamp,
    stamped_rojo_project,
)
from .product_truth import (
    ProductTruthAssessment,
    ProductTruthIssue,
    assess_product_truth,
)
from .provenance import (
    collect_build_provenance,
    collect_input_provenance,
    sha256_file,
)
from .release_gate import ReleaseGateResult, evaluate_release
from .release_artifacts import (
    ReleaseArtifactAssembler,
    RuntimeProducerOutput,
    execute_declared_scenarios,
    execute_post_scenario_logs,
    execute_quality_snapshot,
    execute_visual_capture,
)
from .run_artifacts import RunArtifacts
from .scanner import scan_structure
from .pixel_vision import PixelMetricsProvider
from .visual_cli import VisualCliError, _rubric_from_spec
from .visual_review import VisualReviewError, review_captures
from .visual_spec import VisualQualitySpec, load_visual_spec


@dataclass
class ReleaseOutcome:
    run_id: str
    directory: Path
    gate: ReleaseGateResult
    provenance: dict[str, Any]
    command_errors: list[dict[str, Any]]


def _now() -> str:
    return datetime.now(timezone.utc).isoformat()


def _visual_provider() -> Any:
    """The reviewer for this run: the best one whose configuration exists.

    A model name always comes from configuration (``RQE_VISION_MODEL``), never
    from a default, so the OpenAI provider only runs when both a model and an
    ``OPENAI_API_KEY`` are present. The pixel provider is the always-available
    floor: it grades what pixels can prove and reports "not assessed" for the
    rest, so a keyless run stays honest rather than green by accident.
    """
    model = os.environ.get("RQE_VISION_MODEL", "").strip()
    if model:
        from .openai_vision import OpenAIResponsesVisionProvider

        provider = OpenAIResponsesVisionProvider(model=model)
        if provider.configured:
            return provider
    return PixelMetricsProvider()


def _build_place(
    project: Project,
    run: RunArtifacts,
    product_stamp: ProductIdentityStamp | None,
) -> Path:
    configured_project = project.config.get("rojoProject")
    if not isinstance(configured_project, str) or not configured_project.strip():
        raise RuntimeError(
            "release requires an explicit rqe.project.json rojoProject; "
            "refusing to fall back to a different game"
        )
    relative_project = Path(configured_project.strip())
    if relative_project.is_absolute():
        raise RuntimeError("release rojoProject must be relative to the selected project root")
    project_file = (project.root / relative_project).resolve()
    try:
        project_file.relative_to(project.root.resolve())
    except ValueError as exc:
        raise RuntimeError("release rojoProject escapes the selected project root") from exc
    if not project_file.is_file():
        raise RuntimeError(f"release rojoProject does not exist: {relative_project.as_posix()}")
    build_project_file = project_file
    if product_stamp is not None:
        build_project_file = run.write_json(
            "build/stamped.project.json",
            stamped_rojo_project(project_file, product_stamp),
            producer_task_id="build.product-stamp",
        )
    output = run.directory / "build" / f"{run.run_id}.rbxlx"
    output.parent.mkdir(parents=True, exist_ok=True)
    completed = subprocess.run(
        ["rojo", "build", str(build_project_file), "--output", str(output)],
        cwd=project.root,
        capture_output=True,
        text=True,
        timeout=120,
        check=False,
    )
    run.write_json("build/rojo.json", {
        "command": ["rojo", "build", str(build_project_file), "--output", str(output)],
        "sourceProject": str(project_file),
        "productIdentityStamped": product_stamp is not None,
        "exitCode": completed.returncode,
        "stdout": completed.stdout,
        "stderr": completed.stderr,
    })
    if completed.returncode != 0 or not output.is_file():
        raise RuntimeError(f"rojo build failed with exit code {completed.returncode}: {completed.stderr.strip()}")
    run.register_existing(output.relative_to(run.directory))
    return output


def _stamp_evidence(
    evidence: list[Evidence],
    *,
    run_id: str,
    build_hash: str,
    observed_at: str,
) -> None:
    for item in evidence:
        item.run_id = run_id
        item.build_hash = build_hash
        item.observed_at = observed_at
        if item.coverage is None:
            item.coverage = 0.0 if (item.truncated or not item.conclusive) else 1.0


def _static_evidence(
    project: Project,
    visual_spec: VisualQualitySpec,
) -> tuple[list[Evidence], dict[str, Any]]:
    evidence, static_scan = scan_structure(project)
    issues = validate_contract(project.contract)
    evidence.append(Evidence(
        id="release.contract_schema",
        probe="contract_schema",
        category="structural",
        status="FAIL" if issues else "PASS",
        severity="critical",
        message="release contract is structurally valid" if not issues else "release contract is invalid",
        source="contract-validator",
        validation_level="STATICALLY_VALIDATED",
        details={"issues": issues},
    ))
    evidence.append(Evidence(
        id="release.fixture_excluded",
        probe="fixture_excluded",
        category="structural",
        status="PASS",
        severity="critical",
        message="release project was loaded without the hand-written game-state fixture",
        source="release-orchestrator",
        validation_level="STATICALLY_VALIDATED",
        details={"fixtureLoaded": project.fixture is not None},
    ))
    evidence.append(Evidence(
        id="release.visual_spec_schema",
        probe="visual_spec_schema",
        category="structural",
        status="PASS",
        severity="critical",
        message="visual quality specification is schema-valid and semantically complete",
        source="visual-spec-validator",
        validation_level="STATICALLY_VALIDATED",
        details={
            "specId": visual_spec.spec_id,
            "revision": visual_spec.revision,
            "ruleCount": len(visual_spec.rules),
            "path": visual_spec.path.relative_to(project.root).as_posix(),
        },
    ))
    security_issues = [
        *list(static_scan.get("suspiciousScripts", [])),
        *list(static_scan.get("assetManifestIssues", [])),
    ]
    evidence.append(Evidence(
        id="release.asset_security",
        probe="asset_security",
        category="security",
        status="FAIL" if security_issues else "PASS",
        severity="critical",
        message="source and asset manifest passed static security checks" if not security_issues else "static asset security checks failed",
        source="release-static-validator",
        validation_level="STATICALLY_VALIDATED",
        details={"issues": security_issues},
    ))
    return evidence, static_scan


def _blocked_product_truth(code: str, path: str, message: str) -> ProductTruthAssessment:
    return ProductTruthAssessment(
        "BLOCKED",
        None,
        (ProductTruthIssue(code, path, message),),
    )


def _runtime_identity_document(
    response: Any,
    *,
    run_id: str,
    build_id: str,
    place_sha256: str,
) -> dict[str, Any]:
    result = response.result
    if not isinstance(result, dict) or result.get("available") is not True:
        raise ValueError("Studio did not return an available product identity stamp")
    if response.context not in {"run", "server", "client"}:
        raise ValueError(
            f"product identity came from {response.context!r}, not a running DataModel"
        )
    measured = result.get("measuredIdentity")
    hashes = result.get("artifactHashes")
    if not isinstance(measured, dict) or not isinstance(hashes, dict):
        raise ValueError("Studio product identity result is incomplete")
    return {
        "$schema": "../../../schemas/runtime-product-identity-receipt.v1.schema.json",
        "schemaVersion": 1,
        "receiptId": f"runtime.product-identity.{response.id}",
        "runId": run_id,
        "buildId": build_id,
        "sessionId": response.session,
        "commandId": response.id,
        "source": "studio-bridge",
        "validationLevel": "RUNTIME_VALIDATED",
        "observedAt": datetime.now(timezone.utc).isoformat().replace("+00:00", "Z"),
        "coverage": 1,
        "conclusive": result.get("conclusive") is True,
        "truncated": False,
        "measuredIdentity": {
            "productId": measured.get("productId"),
            "contractId": measured.get("contractId"),
            "visualSpecId": measured.get("visualSpecId"),
        },
        "artifactHashes": {
            "productIntent": hashes.get("productIntent"),
            "contract": hashes.get("contract"),
            "visualQualitySpec": hashes.get("visualQualitySpec"),
            "referenceBenchmark": hashes.get("referenceBenchmark"),
            "visualCalibration": hashes.get("visualCalibration"),
            "place": place_sha256,
        },
    }


def _evaluate_product_truth(
    project: Project,
    run: RunArtifacts,
    *,
    stamp: ProductIdentityStamp | None,
    stamp_error: str | None,
    identity_response: Any | None,
    build_id: str,
    place_sha256: str,
) -> tuple[Evidence, ProductTruthAssessment]:
    """Make product alignment mandatory and preserve its exact assessment."""

    validation_level = "NOT_VALIDATED"
    conclusive = False
    coverage = 0.0
    runtime_receipt_path: Path | None = None

    if stamp_error is not None:
        assessment = _blocked_product_truth(
            "PRODUCT_IDENTITY_STAMP_BLOCKED",
            "productIdentityStamp",
            stamp_error,
        )
    elif stamp is None:
        assessment = _blocked_product_truth(
            "PRODUCT_INTENT_NOT_CONFIGURED",
            "rqe.project.json.productIntent",
            "a release project must bind an approved ProductIntent",
        )
    elif identity_response is None:
        assessment = _blocked_product_truth(
            "RUNTIME_PRODUCT_IDENTITY_MISSING",
            "runtimeIdentity",
            "the exact running build did not produce a product identity receipt",
        )
    else:
        runtime_result = (
            identity_response.result
            if isinstance(identity_response.result, dict)
            else {}
        )
        if (
            identity_response.context in {"run", "server", "client"}
            and runtime_result.get("conclusive") is True
        ):
            validation_level = "RUNTIME_VALIDATED"
            conclusive = True
            coverage = 1.0
        if runtime_result.get("available") is not True:
            assessment = _blocked_product_truth(
                "RUNTIME_PRODUCT_IDENTITY_UNAVAILABLE",
                "runtimeIdentity",
                str(runtime_result.get("reason") or "build identity stamp is unavailable"),
            )
        else:
            try:
                document = _runtime_identity_document(
                    identity_response,
                    run_id=run.run_id,
                    build_id=build_id,
                    place_sha256=place_sha256,
                )
                runtime_receipt_path = run.write_json(
                    "product-truth/runtime-identity.json",
                    document,
                    producer_task_id="measure.product-identity",
                )
                intent_path = project.config.get("productIntent")
                if not isinstance(intent_path, str) or not intent_path:
                    raise ValueError("rqe.project.json productIntent is missing")
                relative_runtime = runtime_receipt_path.relative_to(project.root)
                assessment = assess_product_truth(
                    project.root,
                    intent_path,
                    relative_runtime,
                    expected_product_intent_sha256=stamp.hashes["productIntent"],
                    expected_runtime_identity_sha256=sha256_file(runtime_receipt_path),
                    expected_run_id=run.run_id,
                    expected_build_id=build_id,
                    expected_place_sha256=place_sha256,
                )
                if assessment.bundle is not None:
                    assessment.bundle.verify_unchanged()
            except Exception as exc:
                assessment = _blocked_product_truth(
                    "PRODUCT_TRUTH_INTEGRATION_ERROR",
                    "productTruth",
                    f"{type(exc).__name__}: {exc}",
                )

    assessment_payload = assessment.to_dict()
    assessment_payload["runtimeReceipt"] = (
        runtime_receipt_path.relative_to(run.directory).as_posix()
        if runtime_receipt_path is not None
        else None
    )
    run.write_json(
        "product-truth/assessment.json",
        assessment_payload,
        producer_task_id="evaluate.product-truth",
    )
    issue_codes = [item.code for item in assessment.issues]
    evidence = Evidence(
        id="release.product_truth_alignment",
        probe="product_truth_alignment",
        category="structural",
        status="PASS" if assessment.ready else "FAIL",
        severity="critical",
        message=(
            f"runtime build matches frozen product intent {stamp.product_id}"
            if assessment.ready and stamp is not None
            else "E_PRODUCT_CONTRACT_MISMATCH: product truth is blocked"
        ),
        source="product-truth-validator",
        validation_level=validation_level,
        details={
            "status": assessment.status,
            "issueCodes": issue_codes,
            "issues": assessment_payload["issues"],
            "assessment": "product-truth/assessment.json",
            "runtimeReceipt": assessment_payload["runtimeReceipt"],
        },
        coverage=coverage,
        conclusive=conclusive,
        truncated=False,
    )
    return evidence, assessment


def _bind_observation(observation: Observation, *, run_id: str, build_hash: str) -> list[Evidence]:
    observed_at = _now()
    _stamp_evidence(
        observation.evidence,
        run_id=run_id,
        build_hash=build_hash,
        observed_at=observed_at,
    )
    return observation.evidence


def _live_place_name(bridge: StudioBridge, session_id: str, *, timeout: float = 15.0) -> str | None:
    """The DataModel name a session reports right now, not at handshake.

    A session records the place name when the plugin says hello, and a
    cold-launched Studio says hello before the file finishes opening: the name
    at that instant is the placeholder ("Game"), and the session record keeps
    it for its whole life. Measured, not theorised -- a cold-launched session
    reported "Game" in every hub status for ten minutes while a live probe to
    the same session answered with the exact run-named file. Matching on the
    record alone can therefore never see an RQE-launched build, which is the
    one case the cold-launch path exists for.
    """
    try:
        response = bridge.call_response(
            "dm.properties",
            {"path": "game", "_session": session_id},
            timeout=timeout,
        )
    except Exception:  # noqa: BLE001 - a probing miss is a "not yet", not an error
        return None
    if str(response.session) != session_id:
        return None
    if response.place:
        return response.place
    result = response.result if isinstance(response.result, dict) else None
    if isinstance(result, dict):
        properties = result.get("properties")
        if isinstance(properties, dict) and properties.get("Name"):
            return str(properties["Name"])
    return None


def _matching_live_session(bridge: StudioBridge, expected_place: str) -> dict[str, Any] | None:
    """The one edit session demonstrably open on the release build.

    The anchor is the edit session, exactly as `_play_session` documents: a
    running (play) session reports the DataModel's name -- "Game" for an
    unpublished build -- so name matching cannot see it, and a play session
    can also mask the transient name a just-launched Studio carries while the
    file is still loading. The name a session *records* is its handshake-time
    name, so a cold-launched Studio needs a live probe (see `_live_place_name`)
    before it can ever match. One edit session on the expected file is an
    unambiguous match; two still fail closed.
    """
    matched: list[dict[str, Any]] = []
    for item in bridge.status().get("sessions", []):
        if str(item.get("context")) != "edit":
            continue
        session_id = str(item.get("session") or "")
        if not session_id:
            continue
        recorded = str((item.get("place") or {}).get("name") or "")
        name = recorded
        if recorded != expected_place:
            name = _live_place_name(bridge, session_id) or recorded
        if name == expected_place:
            matched.append(item)
    if len(matched) != 1:
        return None
    return matched[0]


def _await_matching_live_session(
    bridge: StudioBridge,
    expected_place: str,
    *,
    timeout: float = 480.0,
) -> dict[str, Any] | None:
    """Wait for a freshly launched Studio to finish opening the release file.

    The plugin handshakes before the DataModel finishes loading, and while it
    loads ``game.Name`` is the placeholder default ("Game"), not the file
    name. A single look at that instant fails closed on a Studio that is
    demonstrably opening the right file. The match itself is unchanged: only
    the exact expected name matches -- read live while the load settles -- and
    one check after the wait still fails closed if the file never lands.
    """
    deadline = time.monotonic() + timeout
    while True:
        session = _matching_live_session(bridge, expected_place)
        if session is not None:
            return session
        if time.monotonic() >= deadline:
            return None
        time.sleep(2.0)


def _needs_play_session(project: Project, visual_spec: Any) -> bool:
    """Does any release scenario declare that it needs a real Player?

    Read from the scenarios themselves rather than assumed, so a project whose
    visual and additional release scenarios are all satisfiable headlessly never
    pays for a Play Solo it does not need.
    """
    relatives = [
        str((state or {}).get("scenario") or "")
        for state in visual_spec.data.get("evaluationStates", {}).values()
    ]
    configured = project.config.get("releaseScenarios") or []
    if isinstance(configured, list):
        relatives.extend(
            str(item) for item in configured
            if isinstance(item, str) and item.strip()
        )

    seen: set[str] = set()
    for relative in relatives:
        if not relative or relative in seen:
            continue
        seen.add(relative)
        path = project.root / relative
        try:
            scenario = json.loads(path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError):
            continue
        requires = scenario.get("requires")
        if isinstance(requires, dict) and requires.get("playSession") is True:
            return True
    return False


def _wait_for_a_player(bridge: StudioBridge, command_errors: list[dict[str, Any]],
                      timeout: float = 300.0) -> bool:
    """Wait until somebody is standing in the game before measuring it.

    A session exists the moment F5 lands; the game does not. A Forge place
    writes terrain, scatters a world and starts its systems before it lets
    anyone in, and measuring the instant the bridge connects photographs an
    empty Workspace — sixteen instances, no SpawnLocation, and a navigation
    probe that can say nothing because there is nowhere to start. Every one of
    those read as a failing game rather than as an early look.

    A player with a character is the readiness signal, and it is the same one
    the scenarios use, so the measurement and the scenarios describe the same
    moment instead of two different ones.
    """
    deadline = time.monotonic() + timeout
    last: str | None = None
    try:
        with bridge.lease_scope(
            agent_id="release-wait-for-player",
            session_id=bridge.pinned_session,
            context="running",
            ttl_seconds=300.0,
        ):
            while time.monotonic() < deadline:
                try:
                    bridge.renew_active_lease()
                    bridge.actor_attach(None)
                    return True
                except Exception as exc:  # noqa: BLE001
                    last = str(exc)
                    time.sleep(2.0)
    except Exception as exc:  # noqa: BLE001
        last = str(exc)

    command_errors.append({
        "code": "E_NO_PLAYER",
        "message": f"no player had a character within {timeout:.0f}s; "
                   "the measurement describes a world that is still being built",
        "lastError": (last or "")[:200],
    })
    return False


def _play_session(
    bridge: StudioBridge,
    expected_place: str,
    *,
    verified_session: str | None = None,
) -> dict[str, Any] | None:
    """The play-session half of a Studio that is running the release build.

    Play Solo adds a second connection in a `server` context alongside the
    edit one, and the scenarios need that one.

    A play session does not carry the file name.

    Its place is the DataModel's name — "Game" for an unpublished build —
    so matching it the way the edit session is matched finds nothing and
    silently leaves the scenarios in the headless context they cannot run
    in. That was invisible: no error, just a category at zero.

    So the anchor is the edit session, which does carry the file name --
    `verified_session` is the one this release already matched and pinned a
    moment ago; it counts if it is still live, so starting the play session
    does not have to re-prove the world under the load of bringing it up.
    Without it the live match runs again. Anything less certain -- no edit
    session on the expected place, or more than one running session --
    returns nothing and fails closed.
    """
    sessions = bridge.status().get("sessions", [])

    anchor: dict[str, Any] | None = None
    if verified_session:
        anchor = next(
            (item for item in sessions
             if str(item.get("session")) == verified_session
             and str(item.get("context")) == "edit"),
            None,
        )
    if anchor is None:
        anchor = _matching_live_session(bridge, expected_place)
    if anchor is None:
        return None

    running = [item for item in sessions
               if str(item.get("context")) in {"server", "client"}]
    if len(running) != 1:
        return None
    return running[0]


def _execute_release_attempt(
    project: Project,
    run: RunArtifacts,
    *,
    hub_url: str,
    static_only: bool,
    allow_cold_studio_launch: bool,
) -> ReleaseOutcome:
    visual_spec = load_visual_spec(project)
    plan: MeasurementPlan = compile_measurement_plan(project)
    run.write_json("measurement-plan.json", plan.to_dict())

    product_stamp: ProductIdentityStamp | None = None
    product_stamp_error: str | None = None
    configured_intent = project.config.get("productIntent")
    if isinstance(configured_intent, str) and configured_intent.strip():
        try:
            product_stamp = load_product_identity_stamp(project)
        except ProductStampError as exc:
            product_stamp_error = str(exc)
    stamp_preflight = {
        "schemaVersion": 1,
        "status": "READY" if product_stamp is not None else "BLOCKED",
        "stamp": product_stamp.to_dict() if product_stamp is not None else None,
        "error": product_stamp_error,
    }
    run.write_json(
        "product-truth/stamp-preflight.json",
        stamp_preflight,
        producer_task_id="compile.product-identity",
    )

    stamp_payload = product_stamp.to_dict() if product_stamp is not None else None
    inputs_before = collect_input_provenance(
        project,
        visual_spec_path=visual_spec.path,
        product_identity_stamp=stamp_payload,
    )
    run.write_json("build/inputs-before.json", inputs_before)
    place = _build_place(project, run, product_stamp)
    inputs_after = collect_input_provenance(
        project,
        visual_spec_path=visual_spec.path,
        product_identity_stamp=stamp_payload,
    )
    run.write_json("build/inputs-after.json", inputs_after)
    if inputs_before["inputId"] != inputs_after["inputId"]:
        raise RuntimeError(
            "release inputs changed while Rojo was building; candidate provenance is inconclusive"
        )
    visual_seed = (project.config.get("release") or {}).get("seed")
    provenance = collect_build_provenance(
        project,
        place,
        visual_spec_path=visual_spec.path,
        seed=visual_seed,
        product_identity_stamp=stamp_payload,
    )
    build_hash = str(provenance["buildId"])
    run.write_json("build-manifest.json", provenance)

    artifact_assembler = ReleaseArtifactAssembler(
        run,
        project_root=project.root,
        build_hash=build_hash,
        place_hash=str(provenance["place"]["sha256"]),
        spec_hash=str(plan.metadata["visualSpec"]["sha256"]),
    )

    observed_at = _now()
    evidence, static_scan = _static_evidence(project, visual_spec)
    _stamp_evidence(evidence, run_id=run.run_id, build_hash=build_hash, observed_at=observed_at)
    # One list is shared by every producer so the gate sees capture, scenario,
    # client-log and snapshot failures from this exact run.  Producers never
    # write mutable latest pointers.
    command_errors = artifact_assembler.command_errors
    identity_response: Any | None = None

    if not static_only:
        bridge = StudioBridge(hub_url)
        try:
            #: Decided before Studio is launched, because it changes how.
            needs_play = _needs_play_session(project, visual_spec)

            session = _matching_live_session(bridge, place.name)
            if session is None and not allow_cold_studio_launch:
                command_errors.append({
                    "code": "E_STUDIO_COLD_LAUNCH_REQUIRED",
                    "message": (
                        "runtime release evidence requires the exact run-named build in Studio, "
                        "but cold Studio launch is disabled; explicitly allow it or open the build first"
                    ),
                    "expectedPlace": place.name,
                })

            if session is None and allow_cold_studio_launch:
                # Open the build this run just made.
                #
                # The place is named after the run id, and a run id is unique by
                # construction, so no Studio session can already be running it:
                # the match could only ever fail. Requiring an operator to have
                # opened a file whose name the run invents a moment later made
                # runtime evidence unreachable, and every release therefore
                # blocked with every category at zero coverage — which reads as
                # a failing game and means "nobody looked".
                #
                # Opening it here does not weaken the check. The session is
                # still matched by name afterwards, so a Studio that failed to
                # start, or started on something else, still fails closed.
                try:
                    restart_for_bridge(
                        place,
                        project.root / ".rqe" / "studio-archive",
                        bridge=bridge,
                        wait_seconds=240.0,
                        # Even an explicitly authorized cold launch stays
                        # background-first. Play/Run is controlled through
                        # StudioTestService and screenshots through
                        # StudioCaptureService; neither requires foreground.
                        background=True,
                    )
                except Exception as exc:  # noqa: BLE001
                    command_errors.append({
                        "code": "E_STUDIO_LAUNCH",
                        "message": f"could not open the release build in Studio: {exc}",
                        "expectedPlace": place.name,
                    })
                else:
                    session = _await_matching_live_session(bridge, place.name)

            if session is None:
                available = [
                    {
                        "name": (item.get("place") or {}).get("name"),
                        "context": item.get("context"),
                    }
                    for item in bridge.status().get("sessions", [])
                ]
                if allow_cold_studio_launch:
                    command_errors.append({
                        "code": "E_BUILD_MISMATCH",
                        "message": "no unique live Studio session is running the exact release build",
                        "expectedPlace": place.name,
                        "availablePlaces": available,
                    })
            else:
                bridge.pinned_session = str(session["session"])
                matched_edit_session = str(session["session"])
                observation: Observation | None = None

                # [[
                #     When a player is needed, play *first* and measure that.
                #
                #     `run.start` is `RunService:Run()`, which runs the game's
                #     scripts inside the **edit** DataModel. Stopping it does
                #     not undo them: every part the world generator made is
                #     still there. Starting Play Solo afterwards therefore
                #     began from a world that had already been built once, the
                #     game built it again, and the visual spec refused the
                #     result with "viewpoint requires exactly one landmark,
                #     measured 2". Two arenas, and nothing named the cause.
                #
                #     A play session brings the world to life just as well, so
                #     when the scenarios need a player there is no reason to
                #     run it twice. The measurement then describes the session
                #     the scenarios and the captures actually use, which it
                #     should have done all along.
                # ]]
                played_first = False
                if needs_play:
                    try:
                        report = start_play_solo(bridge, wait_seconds=180.0, restart=True)
                    except Exception as exc:  # noqa: BLE001
                        command_errors.append({
                            "code": "E_PLAY_SOLO",
                            "message": f"could not start Play Solo: {exc}",
                        })
                    else:
                        client_bridge = report.get("clientBridge")
                        if isinstance(client_bridge, dict) and not client_bridge.get("ok"):
                            command_errors.append({
                                "code": "E_CLIENT_BRIDGE",
                                "message": str(client_bridge.get("error")
                                               or "the client half was not installed"),
                            })
                        if not report.get("started"):
                            command_errors.append({
                                "code": "E_PLAY_SOLO",
                                "message": "Play Solo did not produce a session",
                                "report": report,
                            })
                        else:
                            play = _play_session(
                                bridge,
                                place.name,
                                verified_session=matched_edit_session,
                            )
                            if play is not None:
                                bridge.pinned_session = str(play["session"])
                                played_first = True
                                _wait_for_a_player(bridge, command_errors)

                try:
                    observation = measure_place(
                        bridge,
                        project,
                        run_id=run.run_id,
                        start_run=not played_first,
                        stop_after=False,
                    )
                    artifact_assembler.record_observation(observation)
                    if played_first or observation.measurements.get("runStart") is not None:
                        try:
                            with bridge.lease_scope(
                                agent_id="release-product-identity",
                                run_id=run.run_id,
                                build_id=build_hash,
                                session_id=bridge.pinned_session,
                                context="running",
                                ttl_seconds=60.0,
                            ):
                                response = bridge.call_response(
                                    "product.identity", {}, timeout=20
                                )
                            if response.ok:
                                identity_response = response
                            else:
                                command_errors.append({
                                    "code": "E_PRODUCT_IDENTITY_COMMAND",
                                    "message": "Studio rejected product.identity",
                                    "error": response.error,
                                    "session": response.session,
                                })
                        except Exception as exc:
                            command_errors.append({
                                "code": "E_PRODUCT_IDENTITY_COMMAND",
                                "message": str(exc),
                                "type": type(exc).__name__,
                            })

                        active_session = str(bridge.pinned_session or "")
                        scenario_context = observation.context
                        capture_place = place.name

                        # Give the scenarios the player they ask for.
                        #
                        # `measure_place` starts the world with `run.start`,
                        # which is real physics and real navigation and no
                        # Player at all. A scenario that declares
                        # `requires.playSession` is then refused with "pinned
                        # Studio context is 'run'", every viewpoint loses its
                        # PASS state, and the capture set is rejected — so a
                        # release blocks on visual evidence that was never
                        # allowed to be gathered.
                        #
                        # Play Solo is the only way to get a Player, and it is
                        # started only when a scenario actually asked for one:
                        # it takes the screen for a moment, and paying that
                        # cost when nothing needs it would be rude.
                        if played_first:
                            scenario_context = str(observation.context or "server")
                            capture_place = str(
                                (_play_session(
                                    bridge,
                                    place.name,
                                    verified_session=matched_edit_session,
                                ) or {})
                                .get("place", {}).get("name") or place.name)

                        if needs_play and not played_first and scenario_context == "run":
                            play_report: dict[str, Any] | None = None
                            try:
                                # `restart=True`, because `measure_place` has
                                # already put Studio into Run mode and a
                                # session that is already running swallows the
                                # F5. The run has to be stopped before Play
                                # Solo can start, which is the one part of
                                # this that cannot be scripted any other way.
                                play_report = start_play_solo(
                                    bridge, wait_seconds=180.0, restart=True)
                            except Exception as exc:  # noqa: BLE001
                                command_errors.append({
                                    "code": "E_PLAY_SOLO",
                                    "message": f"could not start Play Solo: {exc}",
                                })

                            # `start_play_solo` reports rather than raises.
                            #
                            # It returns `started: False` when the keystroke
                            # landed nowhere, and catching only exceptions made
                            # that indistinguishable from success — the run
                            # carried on in the headless context, the scenarios
                            # were refused, and the reason never reached the
                            # log. Its own account of the attempt is recorded
                            # here whatever happened, because the whole
                            # difference between a diagnosable failure and a
                            # mystery is whether the thing that failed said so.
                            # The client half is what every `client.*` command
                            # rides on — viewport, GUI, player state. When it
                            # is missing the failures surface as timeouts on
                            # whatever asked first, naming the symptom and
                            # never the cause, so its own verdict is recorded
                            # here even when Play Solo otherwise succeeded.
                            client_bridge = (play_report or {}).get("clientBridge")
                            if isinstance(client_bridge, dict) and not client_bridge.get("ok"):
                                command_errors.append({
                                    "code": "E_CLIENT_BRIDGE",
                                    "message": str(client_bridge.get("error")
                                                   or "the client half was not installed"),
                                    "detail": client_bridge.get("detail"),
                                })

                            if play_report is not None and not play_report.get("started"):
                                command_errors.append({
                                    "code": "E_PLAY_SOLO",
                                    "message": "Play Solo did not produce a session",
                                    "report": play_report,
                                })

                            if play_report is not None and play_report.get("started"):
                                play = _play_session(
                                    bridge,
                                    place.name,
                                    verified_session=matched_edit_session,
                                )
                                if play is not None:
                                    bridge.pinned_session = str(play["session"])
                                    active_session = str(play["session"])
                                    scenario_context = str(play.get("context") or "server")
                                    # [[
                                    #    A running session identifies itself by
                                    #    DataModel, not by file.
                                    #
                                    #    Its place is "Game" for an unpublished
                                    #    build, so the capture's identity check
                                    #    compared the release file name against
                                    #    it and refused every shot — a set with
                                    #    no shots, marked untrustworthy, and a
                                    #    visual score of zero.
                                    #
                                    #    Nothing is loosened by following it.
                                    #    `_play_session` only returns a session
                                    #    when this Studio also holds an edit
                                    #    session on the expected file, so the
                                    #    build is already established; this
                                    #    just names the same DataModel the way
                                    #    the running half names it.
                                    # ]]
                                    capture_place = str(
                                        (play.get("place") or {}).get("name") or place.name)

                        # Snapshot, scenario and capture intentionally use
                        # separate leases. A scenario reset destroys the DataModel
                        # named by its current fence; keeping one caller-owned lease
                        # across the whole phase makes a legitimate rejoin impossible.
                        with bridge.lease_scope(
                            agent_id="release-quality-snapshot",
                            run_id=run.run_id,
                            build_id=build_hash,
                            session_id=active_session,
                            context="running",
                            ttl_seconds=300.0,
                        ):
                            execute_quality_snapshot(
                                artifact_assembler,
                                bridge,
                                project,
                                visual_spec,
                                expected_session=active_session,
                            )

                        def reset_release_session() -> dict[str, Any]:
                            try:
                                report = start_play_solo(
                                    bridge,
                                    wait_seconds=180.0,
                                    restart=True,
                                    allow_foreground_fallback=False,
                                )
                            except Exception as exc:  # noqa: BLE001
                                return {
                                    "started": False,
                                    "reason": f"{type(exc).__name__}: {exc}",
                                }
                            if not report.get("started"):
                                return report
                            play = _play_session(
                                bridge,
                                place.name,
                                verified_session=matched_edit_session,
                            )
                            if play is None:
                                return {
                                    **report,
                                    "started": False,
                                    "reason": "fresh Play Solo session could not be uniquely identified",
                                }
                            bridge.pinned_session = str(play["session"])
                            readiness_errors: list[dict[str, Any]] = []
                            if not _wait_for_a_player(
                                bridge, readiness_errors, timeout=180.0
                            ):
                                return {
                                    **report,
                                    "started": False,
                                    "reason": "fresh Play Solo session never produced a ready player",
                                    "readinessErrors": readiness_errors,
                                }
                            return {
                                **report,
                                "started": True,
                                "sessionId": str(play["session"]),
                                "context": str(play.get("context") or "server"),
                            }

                        state_outcomes = execute_declared_scenarios(
                            artifact_assembler,
                            bridge,
                            visual_spec,
                            session_id=active_session,
                            context=scenario_context,
                            place_name=place.name,
                            reset_session=reset_release_session,
                            additional_scenarios=list(project.config.get("releaseScenarios") or []),
                        )

                        current_play = _play_session(
                            bridge,
                            place.name,
                            verified_session=matched_edit_session,
                        )
                        if current_play is not None:
                            bridge.pinned_session = str(current_play["session"])
                            active_session = str(current_play["session"])
                            scenario_context = str(current_play.get("context") or "server")
                            capture_place = str(
                                (current_play.get("place") or {}).get("name") or place.name
                            )
                            try:
                                with bridge.lease_scope(
                                    agent_id="release-capture-evidence",
                                    run_id=run.run_id,
                                    build_id=build_hash,
                                    session_id=active_session,
                                    context="running",
                                    ttl_seconds=300.0,
                                ):
                                    execute_visual_capture(
                                        artifact_assembler,
                                        bridge,
                                        visual_spec,
                                        build_path=place,
                                        expected_place=capture_place,
                                        session_id=active_session,
                                        state_outcomes=state_outcomes,
                                    )
                                    execute_post_scenario_logs(
                                        artifact_assembler,
                                        bridge,
                                        expected_session=active_session,
                                    )
                                    capture_manifest = artifact_assembler.capture_manifest
                                    if (
                                        isinstance(capture_manifest, dict)
                                        and capture_manifest.get("trustworthy") is True
                                    ):
                                        # The capture set exists and is bound to
                                        # this run; the review is what turns a
                                        # trustworthy screenshot into an
                                        # assessment the gate can score.  The
                                        # provider is chosen by what is
                                        # configured -- a vision model when a
                                        # key exists, the pixel floor otherwise.
                                        try:
                                            reviewed = review_captures(
                                                capture_manifest,
                                                run.directory / "screenshots",
                                                _rubric_from_spec(
                                                    visual_spec.data, capture_manifest
                                                ),
                                                _visual_provider(),
                                                output_directory=run.directory / "visual-review",
                                            )
                                            artifact_assembler.record_visual_review(
                                                reviewed.to_dict()
                                            )
                                        except (VisualCliError, VisualReviewError) as exc:
                                            artifact_assembler.record_external_producer(
                                                RuntimeProducerOutput(
                                                    producer_id="visual-review.execution-error",
                                                    payload={
                                                        "type": type(exc).__name__,
                                                        "message": str(exc),
                                                    },
                                                    command_errors=[{
                                                        "code": "E_VISUAL_REVIEW",
                                                        "type": type(exc).__name__,
                                                        "message": str(exc),
                                                    }],
                                                    status="BLOCKED",
                                                )
                                            )
                            except Exception as exc:
                                artifact_assembler.record_external_producer(
                                    RuntimeProducerOutput(
                                        producer_id="capture.execution-error",
                                        payload={
                                            "type": type(exc).__name__,
                                            "message": str(exc),
                                        },
                                        command_errors=[{
                                            "code": "E_CAPTURE_EXECUTION",
                                            "type": type(exc).__name__,
                                            "message": str(exc),
                                        }],
                                        status="BLOCKED",
                                    )
                                )
                        else:
                            artifact_assembler.record_external_producer(
                                RuntimeProducerOutput(
                                    producer_id="capture.execution-error",
                                    payload={
                                        "type": "SessionUnavailable",
                                        "message": "no unique live Play Solo session remained after scenario execution",
                                    },
                                    command_errors=[{
                                        "code": "E_CAPTURE_SESSION",
                                        "message": "no unique live Play Solo session remained after scenario execution",
                                    }],
                                    status="BLOCKED",
                                )
                            )
                finally:
                    if (
                        observation is not None
                        and observation.measurements.get("runStart") is not None
                    ):
                        try:
                            with bridge.lease_scope(
                                agent_id="release-stop-run",
                                run_id=run.run_id,
                                build_id=build_hash,
                                context="running",
                                ttl_seconds=60.0,
                                release_required=False,
                            ):
                                bridge.call("run.stop", timeout=30)
                        except Exception as exc:
                            command_errors.append({
                                "code": "E_RUN_STOP",
                                "message": str(exc),
                                "type": type(exc).__name__,
                            })
        except Exception as exc:
            command_errors.append({
                "code": "E_STUDIO_PHASE",
                "message": str(exc),
                "type": type(exc).__name__,
            })

    product_evidence, _product_assessment = _evaluate_product_truth(
        project,
        run,
        stamp=product_stamp,
        stamp_error=product_stamp_error,
        identity_response=identity_response,
        build_id=build_hash,
        place_sha256=str(provenance["place"]["sha256"]),
    )
    _stamp_evidence(
        [product_evidence],
        run_id=run.run_id,
        build_hash=build_hash,
        observed_at=_now(),
    )
    evidence.extend(artifact_assembler.evidence)
    evidence.append(product_evidence)

    run.write_json("evidence/static-scan.json", static_scan)
    run.write_json("evidence/evidence.json", [item.to_dict() for item in evidence])
    run.write_json("logs/command-errors.json", command_errors)
    producer_index = artifact_assembler.write_index()

    gate = evaluate_release(
        plan,
        evidence,
        run_id=run.run_id,
        build_hash=build_hash,
        command_errors=command_errors,
        capture_manifest=artifact_assembler.capture_manifest,
        visual_review=artifact_assembler.visual_review,
    )
    run.write_json("gate.json", gate.to_dict())
    run.finalize({
        "status": "RELEASED" if gate.release_allowed else "BLOCKED",
        "releaseAllowed": gate.release_allowed,
        "buildId": build_hash,
        "gate": "gate.json",
        "provenance": "build-manifest.json",
        "measurementPlan": "measurement-plan.json",
        "productTruth": "product-truth/assessment.json",
        "producerIndex": producer_index.relative_to(run.directory).as_posix(),
        "captureManifest": (
            "screenshots/manifest.json"
            if artifact_assembler.capture_manifest is not None
            else None
        ),
    })
    return ReleaseOutcome(run.run_id, run.directory, gate, provenance, command_errors)


def execute_release(
    root: str | Path,
    *,
    hub_url: str = "",
    run_id: str | None = None,
    static_only: bool = False,
    allow_cold_studio_launch: bool = False,
) -> ReleaseOutcome:
    """Build and evaluate one release candidate without consulting the fixture.

    Every failure after the run directory is allocated is finalized as an
    immutable ``INFRA_FAILED`` run.  An interrupted build therefore cannot
    disappear or be mistaken for a release that was never evaluated.

    The current vertical slice can consume an already-open Studio only when it
    is running the exact run-named build produced here.  P1 lifecycle ownership
    will make opening that build automatic; until then a mismatch is an explicit
    blocker rather than an excuse to stamp another place with this build hash.
    """

    project = Project.load(root, include_fixture=False)
    run = RunArtifacts.create(project.root / "artifacts", run_id)
    try:
        return _execute_release_attempt(
            project,
            run,
            hub_url=hub_url,
            static_only=static_only,
            allow_cold_studio_launch=allow_cold_studio_launch,
        )
    except Exception as exc:
        error = {
            "code": "E_RELEASE_INFRASTRUCTURE",
            "type": type(exc).__name__,
            "message": str(exc),
            "observedAt": _now(),
        }
        provenance: dict[str, Any] = {"buildId": None}
        manifest_path = run.directory / "build-manifest.json"
        if manifest_path.is_file():
            try:
                provenance = json.loads(manifest_path.read_text(encoding="utf-8"))
            except (OSError, json.JSONDecodeError):
                pass
        build_hash = str(provenance.get("buildId") or "UNBUILT")
        gate = ReleaseGateResult(
            release_allowed=False,
            run_id=run.run_id,
            build_hash=build_hash,
            scores={},
            coverage={},
            decisions=[],
            blockers=[f"release infrastructure failed: {type(exc).__name__}: {exc}"],
            visual_score=None,
        )
        if not run.finalized:
            run.write_json("logs/release-infrastructure-error.json", error)
            if not (run.directory / "gate.json").exists():
                run.write_json("gate.json", gate.to_dict())
            run.finalize({
                "status": "INFRA_FAILED",
                "releaseAllowed": False,
                "buildId": provenance.get("buildId"),
                "gate": "gate.json",
                "infrastructureError": "logs/release-infrastructure-error.json",
            })
        return ReleaseOutcome(run.run_id, run.directory, gate, provenance, [error])


def release_terminal_summary(outcome: ReleaseOutcome) -> str:
    status = "ALLOWED" if outcome.gate.release_allowed else "BLOCKED"
    lines = [
        f"RELEASE {outcome.run_id}: {status}",
        f"build: {outcome.provenance['buildId']}",
        f"artifacts: {outcome.directory}",
    ]
    lines.extend(f"- {reason}" for reason in outcome.gate.blockers[:20])
    if len(outcome.gate.blockers) > 20:
        lines.append(f"- ... {len(outcome.gate.blockers) - 20} more blocker(s)")
    return "\n".join(lines)
