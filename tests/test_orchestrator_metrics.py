from __future__ import annotations

import json
import tempfile
import unittest
from pathlib import Path
from typing import Any

from rqe.orchestrator.metrics import (
    MetricsError,
    build_dashboard_index,
    load_latest_pointer,
    write_latest_pointer,
)
from rqe.run_artifacts import RunArtifacts


BUILD_HASH = "b" * 64


def make_run(
    root: Path,
    run_id: str,
    *,
    status: str = "BLOCKED",
    release_allowed: bool = False,
    compatibility: str = "c" * 64,
    coverage: dict[str, float] | None = None,
    scores: dict[str, float] | None = None,
    blockers: list[str] | None = None,
    metrics: dict[str, Any] | None = None,
) -> Path:
    run = RunArtifacts.create(root, run_id)
    gate = {
        "releaseAllowed": release_allowed,
        "runId": run_id,
        "buildHash": BUILD_HASH,
        "coverage": coverage if coverage is not None else {"runtime": 1.0},
        "scores": scores if scores is not None else {"runtime": 100.0},
        "visualScore": None,
        "blockers": blockers or [],
        "requirements": [],
    }
    run.write_json("gate.json", gate)
    run.write_json("build-manifest.json", {
        "schemaVersion": 1,
        "buildId": BUILD_HASH,
        "hashes": {
            "contract": compatibility,
            "config": "3" * 64,
            "rojoProject": "4" * 64,
            "plugin": "5" * 64,
            "visualSpec": "6" * 64,
            "seed": 20260811,
        },
    })
    final: dict[str, Any] = {
        "status": status,
        "releaseAllowed": release_allowed,
        "buildId": BUILD_HASH,
        "gate": "gate.json",
        "provenance": "build-manifest.json",
    }
    if metrics is not None:
        final["metrics"] = metrics
    return run.finalize(final)


class DashboardMetricInvariantTests(unittest.TestCase):
    def test_unreported_cost_is_null_not_zero(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            make_run(root, "cost-unreported")

            index = build_dashboard_index(root)
            run = index["runs"][0]

            self.assertIsNone(run["metrics"]["cost"])
            self.assertNotEqual(run["metrics"]["cost"], 0)
            self.assertIsNone(run["metrics"]["durationMs"])
            self.assertIn("COST_UNREPORTED", {gap["code"] for gap in run["dataQualityGaps"]})
            self.assertIn("DURATION_UNREPORTED", {gap["code"] for gap in run["dataQualityGaps"]})

    def test_latest_pointer_is_atomic_shape_and_hash_bound(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory) / "artifacts"
            make_run(root, "pointer-run")
            index = build_dashboard_index(root)
            pointer_path = Path(directory) / "dashboard" / "latest.json"

            write_latest_pointer(pointer_path, index)
            payload = json.loads(pointer_path.read_text(encoding="utf-8"))
            self.assertEqual(set(payload), {"runId", "manifestSha256"})
            self.assertEqual(load_latest_pointer(pointer_path, index), payload)
            self.assertFalse(list(pointer_path.parent.glob("*.tmp")))

            payload["manifestSha256"] = "0" * 64
            pointer_path.write_text(json.dumps(payload), encoding="utf-8")
            with self.assertRaisesRegex(MetricsError, "does not bind"):
                load_latest_pointer(pointer_path, index)

    def test_flakiness_is_unknown_without_identical_fingerprint_repeats(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            make_run(root, "flaky-a", metrics={
                "checks": [{"checkId": "purchase", "fingerprint": "a" * 64, "status": "PASS"}],
            })
            make_run(root, "flaky-b", metrics={
                "checks": [{"checkId": "purchase", "fingerprint": "d" * 64, "status": "FAIL"}],
            })

            flakiness = build_dashboard_index(root)["flakiness"]

            self.assertEqual(flakiness["status"], "UNKNOWN")
            self.assertEqual(flakiness["comparableGroups"], 0)
            self.assertIsNone(flakiness["flipRate"])

    def test_identical_fingerprint_repeats_produce_measured_flakiness(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            fingerprint = "e" * 64
            make_run(root, "repeat-a", metrics={
                "checks": [{"checkId": "purchase", "fingerprint": fingerprint, "status": "PASS"}],
            })
            make_run(root, "repeat-b", metrics={
                "checks": [{"checkId": "purchase", "fingerprint": fingerprint, "status": "FAIL"}],
            })

            flakiness = build_dashboard_index(root)["flakiness"]

            self.assertEqual(flakiness["status"], "MEASURED")
            self.assertEqual(flakiness["comparableGroups"], 1)
            self.assertEqual(flakiness["flipRate"], 1.0)

    def test_regression_uses_previous_compatible_released_baseline(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            compatible = "1" * 64
            make_run(
                root,
                "baseline-compatible",
                status="RELEASED",
                release_allowed=True,
                compatibility=compatible,
                coverage={"runtime": 1.0},
                scores={"runtime": 100.0},
            )
            make_run(
                root,
                "baseline-incompatible",
                status="RELEASED",
                release_allowed=True,
                compatibility="2" * 64,
            )
            make_run(
                root,
                "current",
                compatibility=compatible,
                coverage={"runtime": 0.5},
                scores={"runtime": 70.0},
                blockers=["runtime regressed"],
            )

            index = build_dashboard_index(root)
            current = next(run for run in index["runs"] if run["runId"] == "current")

            self.assertEqual(current["regression"]["status"], "AVAILABLE")
            self.assertEqual(current["regression"]["baselineRunId"], "baseline-compatible")
            self.assertEqual(current["regression"]["coverageDelta"], {"runtime": -0.5})
            self.assertEqual(current["regression"]["qualityDelta"], {"runtime": -30.0})

    def test_tampered_hash_bound_artifact_is_rejected_from_the_index(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            make_run(root, "tampered")
            (root / "tampered" / "gate.json").write_text("{}\n", encoding="utf-8")

            index = build_dashboard_index(root)

            self.assertEqual(index["runs"], [])
            self.assertEqual(index["dataQuality"]["verifiedRuns"], 0)
            self.assertEqual(index["dataQuality"]["rejectedRuns"], 1)


if __name__ == "__main__":
    unittest.main()
