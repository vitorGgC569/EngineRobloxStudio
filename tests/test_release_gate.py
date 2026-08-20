from __future__ import annotations

import tempfile
import json
import hashlib
import unittest
from dataclasses import replace
from datetime import datetime, timedelta, timezone
from pathlib import Path

from rqe.measurement_plan import compile_measurement_plan
from rqe.models import Evidence
from rqe.project import Project
from rqe.provenance import sha256_json
from rqe.release_gate import evaluate_release
from rqe.run_artifacts import RunArtifacts


ROOT = Path(__file__).resolve().parents[1]
RUN_ID = "release-test"
BUILD_HASH = "a" * 64


class ReleaseGateTests(unittest.TestCase):
    def setUp(self) -> None:
        self.compiled_plan = compile_measurement_plan(Project.load(ROOT))
        # Gate mechanics are tested with an explicitly executable synthetic
        # plan. Producer-liveness behavior is covered separately below.
        self.plan = replace(
            self.compiled_plan,
            requirements=tuple(
                replace(
                    item,
                    producer_status="AVAILABLE",
                    producer_ids=("test.fake-producer",),
                    producer_reasons=(),
                )
                for item in self.compiled_plan.requirements
            ),
            # The shipped visual spec's thresholds are not projected from the
            # token set, and that divergence is a real blocker exercised in
            # tests/test_token_conformance.py. Held conforming here so these
            # tests measure gate mechanics rather than re-asserting it.
            metadata={
                **self.compiled_plan.metadata,
                "tokenConformance": {"status": "CONFORMS", "coverage": 1.0, "issues": []},
            },
        )
        self.now = datetime(2026, 8, 11, 18, 0, tzinfo=timezone.utc)

    def complete_evidence(self) -> list[Evidence]:
        evidence: list[Evidence] = []
        seen: set[str] = set()
        for requirement in self.plan.requirements:
            if requirement.probe in seen:
                continue
            seen.add(requirement.probe)
            evidence.append(Evidence(
                id=f"release.{requirement.probe}",
                probe=requirement.probe,
                category=requirement.category,
                status="PASS",
                severity=requirement.severity,
                message="measured",
                source=(
                    requirement.allowed_sources[0]
                    if requirement.allowed_sources
                    else (
                        "static-validator"
                        if requirement.minimum_validation_level == "STATICALLY_VALIDATED"
                        else "studio-bridge"
                    )
                ),
                validation_level=requirement.minimum_validation_level,
                observed_at=self.now.isoformat(),
                run_id=RUN_ID,
                build_hash=BUILD_HASH,
                coverage=1.0,
            ))
        # Structural is a required policy domain without a game requirement.
        evidence.append(Evidence(
            id="release.contract_schema",
            probe="contract_schema",
            category="structural",
            status="PASS",
            severity="critical",
            message="contract checked",
            source="contract-validator",
            validation_level="STATICALLY_VALIDATED",
            observed_at=self.now.isoformat(),
            run_id=RUN_ID,
            build_hash=BUILD_HASH,
            coverage=1.0,
        ))
        return evidence

    def visual_artifacts(self, *, grade: int = 5, claimed_score: float | None = None):
        spec_hash = self.plan.metadata["visualSpec"]["sha256"]
        place_hash = "b" * 64
        viewpoint = "release-view"
        manifest = {
            "schemaVersion": 1,
            "runId": RUN_ID,
            "buildHash": BUILD_HASH,
            "placeHash": place_hash,
            "specHash": spec_hash,
            "sessionId": "sess_release",
            "place": "release-test.rbxlx",
            "capturedAt": self.now.isoformat(),
            "captureType": "studio-window",
            "requiredViewpoints": [viewpoint],
            "capturedRequiredViewpoints": [viewpoint],
            "missingRequiredViewpoints": [],
            "coverage": 1.0,
            "shots": [{
                "id": viewpoint,
                "file": "01-release-view.png",
                "bytes": 100,
                "sha256": "c" * 64,
                "trustworthy": True,
                "integrityIssues": [],
                "runId": RUN_ID,
                "buildHash": BUILD_HASH,
                "placeHash": place_hash,
                "specHash": spec_hash,
                "sessionId": "sess_release",
                "camera": {"before": {"position": [1, 2, 3]}, "after": {"position": [1, 2, 3]}},
            }],
            "failures": [],
            "occludedShots": 0,
            "trustworthy": True,
        }
        average = float((grade - 1) * 25)
        review = {
            "schemaVersion": 1,
            "status": "COMPLETE",
            "validationLevel": "VISUALLY_VALIDATED",
            "runId": RUN_ID,
            "buildHash": BUILD_HASH,
            "placeHash": place_hash,
            "specHash": spec_hash,
            "captureManifestSha256": hashlib.sha256(
                (json.dumps(manifest, indent=2, ensure_ascii=False) + "\n").encode("utf-8")
            ).hexdigest(),
            "provider": "fake-vision",
            "model": "fake-v1",
            "modelHash": sha256_json({"provider": "fake-vision", "model": "fake-v1"}),
            "promptHash": "d" * 64,
            "reviewedViewpoints": [viewpoint],
            "assessments": [{
                "viewpoint": viewpoint,
                "rubric": [{
                    "criterion": "composition",
                    "grade": grade,
                    "rationale": "measured visual hierarchy",
                    "evidence": {"shotIds": [viewpoint]},
                }],
            }],
            "findings": [],
            "score": average if claimed_score is None else claimed_score,
            "scoring": {"rubricAverage": average, "findingPenalty": 0.0},
            "createdAt": self.now.isoformat(),
        }
        return manifest, review

    def evaluate(self, evidence: list[Evidence], **kwargs):
        capture_manifest, visual_review = self.visual_artifacts()
        options = {
            "capture_manifest": capture_manifest,
            "visual_review": visual_review,
            "now": self.now,
        }
        options.update(kwargs)
        return evaluate_release(
            self.plan,
            evidence,
            run_id=RUN_ID,
            build_hash=BUILD_HASH,
            **options,
        )

    def test_complete_positive_same_run_evidence_allows_release(self) -> None:
        result = self.evaluate(self.complete_evidence())
        self.assertTrue(result.release_allowed, result.blockers)
        self.assertEqual(set(result.scores), set(self.plan.required_categories))
        self.assertTrue(all(value == 100 for value in result.scores.values()))

    def test_unproducible_requirement_rejects_even_injected_positive_evidence(self) -> None:
        capture_manifest, visual_review = self.visual_artifacts()
        result = evaluate_release(
            self.compiled_plan,
            self.complete_evidence(),
            run_id=RUN_ID,
            build_hash=BUILD_HASH,
            capture_manifest=capture_manifest,
            visual_review=visual_review,
            now=self.now,
        )
        decision = next(
            item for item in result.decisions
            if item.requirement_id == "card_gallery_is_visible"
        )
        self.assertEqual("UNPRODUCIBLE", decision.status)
        self.assertTrue(any("FIXTURE_ONLY" in reason for reason in decision.reasons))

    def test_missing_runtime_coverage_blocks_release_instead_of_scoring_100(self) -> None:
        evidence = [item for item in self.complete_evidence() if item.probe != "objective_reachable"]
        result = self.evaluate(evidence)
        self.assertFalse(result.release_allowed)
        decision = next(item for item in result.decisions if item.probe == "objective_reachable")
        self.assertEqual(decision.status, "MISSING")
        self.assertLess(result.scores["navigation"], 100)

    def test_fixture_evidence_is_never_release_evidence(self) -> None:
        evidence = self.complete_evidence()
        target = next(item for item in evidence if item.probe == "path_exists")
        target.source = "headless-runtime"
        result = self.evaluate(evidence)
        self.assertFalse(result.release_allowed)
        self.assertTrue(any("forbidden source" in reason for reason in result.blockers))

    def test_evidence_from_another_build_is_rejected(self) -> None:
        evidence = self.complete_evidence()
        target = next(item for item in evidence if item.probe == "spawn_support")
        target.build_hash = "b" * 64
        result = self.evaluate(evidence)
        self.assertFalse(result.release_allowed)
        self.assertTrue(any("build hash" in reason for reason in result.blockers))

    def test_stale_evidence_is_rejected(self) -> None:
        evidence = self.complete_evidence()
        evidence[0].observed_at = (self.now - timedelta(days=8)).isoformat()
        result = self.evaluate(evidence)
        self.assertFalse(result.release_allowed)
        self.assertTrue(any("stale" in reason for reason in result.blockers))

    def test_truncated_or_inconclusive_measurement_blocks_release(self) -> None:
        evidence = self.complete_evidence()
        next(item for item in evidence if item.probe == "collision_overlap").truncated = True
        next(item for item in evidence if item.probe == "path_exists").conclusive = False
        result = self.evaluate(evidence)
        self.assertFalse(result.release_allowed)
        joined = "\n".join(result.blockers)
        self.assertIn("truncated", joined)
        self.assertIn("inconclusive", joined)

    def test_command_errors_and_untrustworthy_captures_block_release(self) -> None:
        capture_manifest, visual_review = self.visual_artifacts()
        capture_manifest["trustworthy"] = False
        result = evaluate_release(
            self.plan,
            self.complete_evidence(),
            run_id=RUN_ID,
            build_hash=BUILD_HASH,
            command_errors=[{"method": "client.logs", "error": "timeout"}],
            capture_manifest=capture_manifest,
            visual_review=visual_review,
            now=self.now,
        )
        self.assertFalse(result.release_allowed)
        self.assertTrue(any("command error" in reason for reason in result.blockers))
        self.assertTrue(any("occluded" in reason for reason in result.blockers))

    def test_visual_score_is_a_hard_floor(self) -> None:
        capture_manifest, visual_review = self.visual_artifacts(grade=4)
        result = self.evaluate(
            self.complete_evidence(),
            capture_manifest=capture_manifest,
            visual_review=visual_review,
        )
        self.assertFalse(result.release_allowed)
        self.assertTrue(any("visual review score" in reason for reason in result.blockers))

    def test_caller_cannot_inject_a_visual_score_disconnected_from_rubric(self) -> None:
        capture_manifest, visual_review = self.visual_artifacts(grade=1, claimed_score=100)
        result = self.evaluate(
            self.complete_evidence(),
            capture_manifest=capture_manifest,
            visual_review=visual_review,
        )
        self.assertFalse(result.release_allowed)
        self.assertTrue(any("not derived" in reason for reason in result.blockers))


class ImmutableRunArtifactTests(unittest.TestCase):
    def test_existing_run_id_and_existing_artifact_cannot_be_overwritten(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            run = RunArtifacts.create(root, "same-run")
            run.write_text("logs/client.txt", "first")
            with self.assertRaises(FileExistsError):
                run.write_text("logs/client.txt", "second")
            with self.assertRaises(FileExistsError):
                RunArtifacts.create(root, "same-run")

    def test_finalized_run_accepts_no_more_artifacts(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            run = RunArtifacts.create(Path(directory), "finished")
            run.finalize({"status": "BLOCKED"})
            with self.assertRaises(RuntimeError):
                run.write_json("late.json", {})

    def test_manifest_hash_binds_every_artifact_and_producer(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            run = RunArtifacts.create(Path(directory), "hashed-run")
            run.write_text("logs/client.txt", "measured", producer_task_id="qa-agent")
            manifest_path = run.finalize({"status": "BLOCKED"})
            manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
            self.assertEqual(2, manifest["schemaVersion"])
            self.assertEqual("qa-agent", manifest["artifacts"][0]["producerTaskId"])
            self.assertEqual(64, len(manifest["artifacts"][0]["sha256"]))
            self.assertEqual(64, len(manifest["manifestSha256"]))

    def test_registered_artifact_mutation_is_detected_before_finalize(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            run = RunArtifacts.create(Path(directory), "changed-run")
            path = run.write_text("evidence.json", "first")
            path.write_text("changed", encoding="utf-8")
            with self.assertRaisesRegex(RuntimeError, "changed before finalization"):
                run.finalize({"status": "BLOCKED"})


if __name__ == "__main__":
    unittest.main()
