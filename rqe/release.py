"""One immutable, fail-closed release attempt.

The legacy commands remain diagnostic.  This module is the only place allowed
to decide whether a build may ship, and it never reads the hand-written game
fixture.
"""

from __future__ import annotations

import json
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


def _build_place(
    project: Project,
    run: RunArtifacts,
    product_stamp: ProductIdentityStamp | None,
) -> Path:
    project_file = project.root / project.config.get("rojoProject", "roblox/mvp/default.project.json")
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


def _matching_live_session(bridge: StudioBridge, expected_place: str) -> dict[str, Any] | None:
    status = bridge.status()
    matches = [
        item for item in status.get("sessions", [])
        if str((item.get("place") or {}).get("name")) == expected_place
    ]
    if len(matches) != 1:
        return None
    return matches[0]


def _needs_play_session(project: Project, visual_spec: Any) -> bool:
    """Does any evaluation state declare that it needs a real Player?

    Read from the scenarios themselves rather than assumed, so a spec whose
    states are all satisfiable headlessly never pays for a Play Solo it does
    not need.
    """
    for state in visual_spec.data.get("evaluationStates", {}).values():
        relative = str((state or {}).get("scenario") or "")
        if not relative:
            continue
        path = project.root / relative
        try:
            scenario = json.loads(path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError):
            continue
        requires = scenario.get("requires")
        if isinstance(requires, dict) and requires.get("playSession") is True:
            return True
    return False


def _play_session(bridge: StudioBridge, expected_place: str) -> dict[str, Any] | None:
    """The play-session half of a Studio that is running the release build.

    Play Solo adds a second connection in a `server` context alongside the
    edit one, and the scenarios need that one. Matched on the place name as
    well as the context, so a Studio running something else can never be
    mistaken for this build.
    """
    sessions = bridge.status().get("sessions", [])

    #: A play session does not carry the file name.
    #:
    #: Its place is the DataModel's name — "Game" for an unpublished build —
    #: so matching it the way the edit session is matched finds nothing and
    #: silently leaves the scenarios in the headless context they cannot run
    #: in. That was invisible: no error, just a category at zero.
    #:
    #: So the anchor is the edit session, which does carry the file name. If
    #: this Studio is demonstrably open on the release build, the one running
    #: session beside it is that build running. Anything less certain — no
    #: edit session on the expected place, or more than one running session —
    #: returns nothing and fails closed.
    edit = [item for item in sessions
            if str((item.get("place") or {}).get("name")) == expected_place]
    if not edit:
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
            if session is None:
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
                        # Minimised by default, because Studio taking the
                        # screen during a release run is rude. But Play Solo
                        # cannot be started without focus — Studio ignores
                        # synthesised key messages — and a minimised window
                        # has no composited surface to photograph either. So a
                        # run that needs a player needs the screen, and the
                        # alternative is a silent zero in every visual
                        # category.
                        background=not needs_play,
                    )
                except Exception as exc:  # noqa: BLE001
                    command_errors.append({
                        "code": "E_STUDIO_LAUNCH",
                        "message": f"could not open the release build in Studio: {exc}",
                        "expectedPlace": place.name,
                    })
                else:
                    session = _matching_live_session(bridge, place.name)

            if session is None:
                available = [
                    (item.get("place") or {}).get("name")
                    for item in bridge.status().get("sessions", [])
                ]
                command_errors.append({
                    "code": "E_BUILD_MISMATCH",
                    "message": "no unique live Studio session is running the exact release build",
                    "expectedPlace": place.name,
                    "availablePlaces": available,
                })
            else:
                bridge.pinned_session = str(session["session"])
                observation: Observation | None = None
                try:
                    observation = measure_place(
                        bridge,
                        project,
                        run_id=run.run_id,
                        start_run=True,
                        stop_after=False,
                    )
                    artifact_assembler.record_observation(observation)
                    if observation.measurements.get("runStart") is not None:
                        try:
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
                        if needs_play and scenario_context == "run":
                            try:
                                # `restart=True`, because `measure_place` has
                                # already put Studio into Run mode and a
                                # session that is already running swallows the
                                # F5. The run has to be stopped before Play
                                # Solo can start, which is the one part of
                                # this that cannot be scripted any other way.
                                start_play_solo(bridge, wait_seconds=180.0, restart=True)
                            except Exception as exc:  # noqa: BLE001
                                command_errors.append({
                                    "code": "E_PLAY_SOLO",
                                    "message": f"could not start Play Solo: {exc}",
                                })
                            else:
                                play = _play_session(bridge, place.name)
                                if play is not None:
                                    bridge.pinned_session = str(play["session"])
                                    active_session = str(play["session"])
                                    scenario_context = str(play.get("context") or "server")

                        execute_quality_snapshot(
                            artifact_assembler,
                            bridge,
                            project,
                            visual_spec,
                            expected_session=active_session,
                        )
                        state_outcomes = execute_declared_scenarios(
                            artifact_assembler,
                            bridge,
                            visual_spec,
                            session_id=active_session,
                            context=scenario_context,
                            place_name=place.name,
                        )
                        try:
                            execute_visual_capture(
                                artifact_assembler,
                                bridge,
                                visual_spec,
                                build_path=place,
                                expected_place=place.name,
                                session_id=active_session,
                                state_outcomes=state_outcomes,
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
                        execute_post_scenario_logs(
                            artifact_assembler,
                            bridge,
                            expected_session=active_session,
                        )
                finally:
                    if (
                        observation is not None
                        and observation.measurements.get("runStart") is not None
                    ):
                        try:
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
    hub_url: str = "http://127.0.0.1:8790",
    run_id: str | None = None,
    static_only: bool = False,
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
