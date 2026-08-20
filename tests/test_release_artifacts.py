from __future__ import annotations

import hashlib
import json
import tempfile
import unittest
from dataclasses import dataclass
from pathlib import Path

from rqe.models import Evidence
from rqe.observe import Observation
from rqe.release_artifacts import ReleaseArtifactAssembler, ReleaseArtifactError
from rqe.release_artifacts import execute_post_scenario_logs
from rqe.hub.protocol import Response
from rqe.provenance import sha256_json
from rqe.run_artifacts import RunArtifacts
from rqe.scenario import ScenarioResult, StepResult
from rqe.schema_validation import validate_schema_instance


BUILD_HASH = "a" * 64
PLACE_HASH = "b" * 64
SPEC_HASH = "c" * 64


class ReleaseArtifactAssemblerTests(unittest.TestCase):
    def assembler(self, root: Path, run_id: str = "release-artifacts") -> ReleaseArtifactAssembler:
        run = RunArtifacts.create(root / "artifacts", run_id)
        return ReleaseArtifactAssembler(
            run,
            project_root=root,
            build_hash=BUILD_HASH,
            place_hash=PLACE_HASH,
            spec_hash=SPEC_HASH,
        )

    def test_observation_separates_client_logs_and_binds_every_artifact(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            assembler = self.assembler(root)
            observation = Observation(
                run_id=assembler.run.run_id,
                started_at="2026-08-11T00:00:00Z",
                context="run",
                place={"placeName": "candidate.rbxlx"},
                validation_level="RUNTIME_VALIDATED",
                measurements={
                    "logs": {"counts": {"error": 0}},
                    "clientLogs": {"available": True, "counts": {"error": 0}},
                    "runtime": {"fps": 60},
                },
                evidence=[Evidence(
                    id="runtime.clean",
                    probe="performance_budget",
                    category="performance",
                    status="PASS",
                    severity="critical",
                    message="clean",
                    source="studio-bridge",
                    validation_level="RUNTIME_VALIDATED",
                )],
            )
            produced = assembler.record_observation(observation)
            assembler.write_index()
            manifest_path = assembler.run.finalize({"status": "BLOCKED"})
            manifest = json.loads(manifest_path.read_text(encoding="utf-8"))

            self.assertEqual(assembler.run.run_id, produced[0].run_id)
            self.assertEqual(BUILD_HASH, produced[0].build_hash)
            paths = {item["path"] for item in manifest["artifacts"]}
            self.assertIn("logs/client-output.json", paths)
            self.assertIn("logs/studio-output.json", paths)
            self.assertIn("runtime-state/observation.json", paths)
            self.assertIn("producers/index.json", paths)
            index = json.loads(
                (assembler.run.directory / "producers/index.json").read_text(encoding="utf-8")
            )
            schema = json.loads(
                (Path(__file__).resolve().parents[1] / "schemas/release-producer-index.v1.schema.json").read_text(encoding="utf-8")
            )
            self.assertEqual([], validate_schema_instance(index, schema))

    def test_evidence_from_another_build_is_not_restamped(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            assembler = self.assembler(root)
            observation = Observation(
                run_id=assembler.run.run_id,
                started_at="2026-08-11T00:00:00Z",
                context="run",
                place={},
                evidence=[Evidence(
                    id="foreign",
                    probe="performance_budget",
                    category="performance",
                    status="PASS",
                    severity="critical",
                    message="wrong build",
                    source="studio-bridge",
                    validation_level="RUNTIME_VALIDATED",
                    build_hash="d" * 64,
                )],
            )
            with self.assertRaisesRegex(ReleaseArtifactError, "another build"):
                assembler.record_observation(observation)

    def test_scenario_only_emits_release_evidence_from_an_explicit_binding(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            scenario_path = root / "scenario.json"
            scenario_path.write_text(json.dumps({
                "id": "purchase-loop",
                "steps": [{"attach": {}}, {"navigate_to": {"target": "goal"}}],
                "releaseEvidence": [{
                    "id": "scenario.purchase-loop",
                    "probe": "button_interaction",
                    "category": "gameplay",
                    "severity": "critical",
                }],
            }), encoding="utf-8")
            assembler = self.assembler(root)
            result = ScenarioResult(
                scenario="purchase-loop",
                status="PASS",
                validation_level="E2E_VALIDATED",
                steps=[
                    StepResult(1, "attach", {}, "PASS"),
                    StepResult(2, "navigate_to", {}, "PASS"),
                ],
            )
            evidence = assembler.record_scenario(
                scenario_path,
                result=result,
                session_id="sess_exact",
                place_name="candidate.rbxlx",
            )
            self.assertEqual(["button_interaction"], [item.probe for item in evidence])
            self.assertEqual("studio-scenario", evidence[0].source)
            self.assertTrue(evidence[0].conclusive)
            receipt = json.loads(
                (assembler.run.directory / "scenarios/purchase-loop.json").read_text(encoding="utf-8")
            )
            schema = json.loads(
                (Path(__file__).resolve().parents[1] / "schemas/scenario-result-receipt.v1.schema.json").read_text(encoding="utf-8")
            )
            self.assertEqual([], validate_schema_instance(receipt, schema))

    def test_scenario_without_binding_is_preserved_but_cannot_invent_a_probe(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            scenario_path = root / "scenario.json"
            scenario_path.write_text(json.dumps({
                "id": "diagnostic-only",
                "steps": [{"wait": {"seconds": 0}}],
            }), encoding="utf-8")
            assembler = self.assembler(root)
            result = ScenarioResult(
                scenario="diagnostic-only",
                status="PASS",
                validation_level="NOT_VALIDATED",
                steps=[StepResult(1, "wait", {}, "PASS")],
            )
            evidence = assembler.record_scenario(
                scenario_path,
                result=result,
                session_id="sess_exact",
                place_name="candidate.rbxlx",
            )
            self.assertEqual([], evidence)
            receipt = json.loads(
                (assembler.run.directory / "scenarios/diagnostic-only.json").read_text(encoding="utf-8")
            )
            self.assertFalse(receipt["conclusive"])

    def _capture_manifest(self, capture_dir: Path, *, device_verified: bool = True) -> dict:
        png = capture_dir / "01-overview.png"
        png.parent.mkdir(parents=True, exist_ok=True)
        png.write_bytes(b"PNG producer bytes")
        shot = {
            "id": "overview",
            "file": png.name,
            "bytes": png.stat().st_size,
            "sha256": hashlib.sha256(png.read_bytes()).hexdigest(),
            "trustworthy": True,
            "integrityIssues": [],
            "runId": "release-artifacts",
            "buildHash": BUILD_HASH,
            "placeHash": PLACE_HASH,
            "specHash": SPEC_HASH,
            "sessionId": "sess_exact",
            "camera": {"before": {"position": [1, 2, 3]}, "after": {"position": [1, 2, 3]}},
            "device": {"requested": "desktop", "verified": device_verified},
            "resolution": {"requested": [1280, 720], "measuredViewport": [1280, 720]},
        }
        manifest = {
            "schemaVersion": 1,
            "runId": "release-artifacts",
            "buildHash": BUILD_HASH,
            "placeHash": PLACE_HASH,
            "specHash": SPEC_HASH,
            "sessionId": "sess_exact",
            "capturedAt": "2026-08-11T00:00:00Z",
            "requiredViewpoints": ["overview"],
            "capturedRequiredViewpoints": ["overview"],
            "missingRequiredViewpoints": [],
            "coverage": 1.0,
            "shots": [shot],
            "failures": [],
            "occludedShots": 0,
            "trustworthy": True,
        }
        (capture_dir / "manifest.json").write_text(
            json.dumps(manifest, indent=2, ensure_ascii=False) + "\n", encoding="utf-8"
        )
        return manifest

    def test_capture_is_admitted_only_after_physical_hash_and_identity_checks(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            assembler = self.assembler(root)
            manifest = self._capture_manifest(assembler.run.directory / "screenshots")
            evidence = assembler.record_capture("screenshots", manifest)
            self.assertIs(manifest, assembler.capture_manifest)
            self.assertEqual(["visual.viewpoint.overview.capture"], [item.probe for item in evidence])

    def test_unverified_device_preserves_capture_but_rejects_it_from_gate_input(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            assembler = self.assembler(root)
            manifest = self._capture_manifest(
                assembler.run.directory / "screenshots", device_verified=False
            )
            evidence = assembler.record_capture("screenshots", manifest)
            self.assertEqual([], evidence)
            self.assertIsNone(assembler.capture_manifest)
            self.assertTrue(any(item.get("code") == "E_CAPTURE_INTEGRITY" for item in assembler.command_errors))

    def test_capture_file_changed_after_manifest_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            assembler = self.assembler(root)
            manifest = self._capture_manifest(assembler.run.directory / "screenshots")
            (assembler.run.directory / "screenshots/01-overview.png").write_bytes(b"tampered")
            assembler.record_capture("screenshots", manifest)
            self.assertIsNone(assembler.capture_manifest)
            receipt = json.loads(
                (assembler.run.directory / "producers/capture.integration.json").read_text(encoding="utf-8")
            )
            self.assertTrue(any("hash differs" in issue for issue in receipt["issues"]))

    def test_quality_snapshot_writes_raw_payload_and_distinct_receipt(self) -> None:
        @dataclass
        class FakeMeasurement:
            run_id: str
            build_hash: str
            session_id: str
            snapshot: dict
            snapshot_sha256: str
            evidence: tuple[Evidence, ...]

            def receipt(self):
                return {"status": "COMPLETE", "conclusive": True}

        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            assembler = self.assembler(root)
            snapshot = {"capturedAt": "2026-08-11T00:00:00Z", "truncated": False}
            measurement = FakeMeasurement(
                assembler.run.run_id,
                BUILD_HASH,
                "sess_exact",
                snapshot,
                sha256_json(snapshot),
                (Evidence(
                    id="visual.density",
                    probe="visual.region.hub.density",
                    category="visual",
                    status="PASS",
                    severity="major",
                    message="measured",
                    source="studio-quality-validator",
                    validation_level="RUNTIME_VALIDATED",
                ),),
            )
            assembler.record_quality_snapshot(measurement)
            self.assertTrue((assembler.run.directory / "runtime-state/quality-snapshot.json").is_file())
            self.assertTrue((assembler.run.directory / "runtime-state/quality-snapshot-receipt.json").is_file())

    def test_post_scenario_logs_require_both_server_and_client_channels(self) -> None:
        class LogBridge:
            def call_response(self, method, _params=None, timeout=15):
                if method == "log.tail":
                    result = {
                        "available": True,
                        "counts": {"info": 1, "warning": 0, "error": 0},
                        "entries": [],
                    }
                else:
                    result = {"available": False, "reason": "no real player", "entries": []}
                return Response(
                    id=method,
                    ok=True,
                    result=result,
                    context="run",
                    place="candidate.rbxlx",
                    session="sess_exact",
                )

        with tempfile.TemporaryDirectory() as directory:
            assembler = self.assembler(Path(directory))
            execute_post_scenario_logs(
                assembler, LogBridge(), expected_session="sess_exact"
            )
            evidence = next(item for item in assembler.evidence if item.probe == "runtime_error")
            self.assertEqual("WARN", evidence.status)
            self.assertFalse(evidence.conclusive)
            self.assertEqual(0.0, evidence.coverage)


if __name__ == "__main__":
    unittest.main()
