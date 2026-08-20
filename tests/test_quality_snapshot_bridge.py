from __future__ import annotations

import copy
import json
import unittest
from pathlib import Path

from rqe.hub.commands import CommandValidationError, load_default_registry
from rqe.project import Project
from rqe.quality_snapshot import QualitySnapshotLimits, compile_quality_snapshot_params
from rqe.schema_validation import validate_schema_instance
from rqe.visual_spec import load_visual_spec
from tests.test_quality import healthy_snapshot


ROOT = Path(__file__).resolve().parents[1]


class QualitySnapshotBridgeContractTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.registry = load_default_registry()
        cls.command = cls.registry.require("quality.snapshot")
        cls.project = Project.load(ROOT, include_fixture=False)
        cls.spec = load_visual_spec(cls.project)
        cls.params = compile_quality_snapshot_params(cls.spec)

    def test_compiled_visual_spec_payload_matches_the_typed_command(self) -> None:
        self.command.validate_params(self.params)
        self.assertEqual(self.command.effect, "read")
        self.assertEqual(self.command.idempotency, "safe-retry")
        self.assertEqual(self.command.selector["session"], "required")
        self.assertEqual(self.command.selector["build"], "required")

    def test_acceptance_policy_cannot_cross_the_plugin_boundary(self) -> None:
        classification_policy = copy.deepcopy(self.params)
        classification_policy["classification"]["minimumClassifiedFraction"] = 0.98
        with self.assertRaises(CommandValidationError):
            self.command.validate_params(classification_policy)

        landmark_policy = copy.deepcopy(self.params)
        landmark_policy["landmarks"][0]["maximumBlindSpotDegrees"] = 90
        with self.assertRaises(CommandValidationError):
            self.command.validate_params(landmark_policy)

    def test_manifest_budgets_match_the_python_request_ceiling(self) -> None:
        limits = QualitySnapshotLimits().to_dict()
        self.assertEqual(
            limits,
            {
                "maxCandidates": 25_000,
                "maxRoots": 5_000,
                "maxRegions": 500,
                "maxVisibilitySamples": 20_000,
            },
        )
        self.command.validate_params({**self.params, "limits": limits})
        too_large = copy.deepcopy(self.params)
        too_large["limits"]["maxVisibilitySamples"] = 20_001
        with self.assertRaises(CommandValidationError):
            self.command.validate_params(too_large)

    def test_command_result_conforms_to_the_canonical_snapshot_schema(self) -> None:
        snapshot = healthy_snapshot()
        self.command.validate_result(snapshot)
        schema = json.loads(
            (ROOT / "schemas/quality-snapshot.v1.schema.json").read_text(encoding="utf-8")
        )
        self.assertEqual(validate_schema_instance(snapshot, schema), [])

        extra = copy.deepcopy(snapshot)
        extra["score"] = 100
        with self.assertRaises(CommandValidationError):
            self.command.validate_result(extra)
        self.assertTrue(validate_schema_instance(extra, schema))

    def test_plugin_cannot_self_select_its_classification_universe(self) -> None:
        source = (
            ROOT / "apps/studio-plugin/src/Commands/Quality.lua"
        ).read_text(encoding="utf-8")
        self.assertIn("workspace:GetDescendants()", source)
        self.assertIn("instance.Transparency < 1 or instance.CanQuery", source)
        self.assertIn("hasTagInAncestry(part, excludeTag)", source)
        self.assertIn("nearestRoot(part, rootBoundsByInstance)", source)
        self.assertNotIn("candidateSet", source)

    def test_landmark_anchors_are_destinations_not_observation_points(self) -> None:
        source = (
            ROOT / "apps/studio-plugin/src/Commands/Quality.lua"
        ).read_text(encoding="utf-8")
        self.assertIn("regionGrid(", source)
        self.assertIn("landmark.sampleSpacing", source)
        self.assertIn("playableSurface(region, plane, consumeRay)", source)
        self.assertIn("table.insert(destinations, destination)", source)
        self.assertIn("workspace:Raycast", source)
        self.assertNotIn("inside(region, anchor.point)", source)

    def test_plugin_contains_measurement_methodology_but_no_quality_thresholds(self) -> None:
        source = (
            ROOT / "apps/studio-plugin/src/Commands/Quality.lua"
        ).read_text(encoding="utf-8")
        for forbidden in (
            "minimumClassifiedFraction",
            "minimumVisibleAnchorFraction",
            "minimumRegionsVisibleFrom",
            "maximumOffPaletteFraction",
            "minimumRootsPer1000SquareStuds",
        ):
            self.assertNotIn(forbidden, source)


if __name__ == "__main__":
    unittest.main()
