from __future__ import annotations

import copy
import unittest
from pathlib import Path

from rqe.project import Project
from rqe.hub.protocol import Response
from rqe.quality import _delta_e_2000, evaluate_quality_snapshot
from rqe.quality_snapshot import (
    QualitySnapshotError,
    compile_quality_snapshot_params,
    measure_quality_snapshot,
)
from rqe.visual_spec import load_visual_spec


ROOT = Path(__file__).resolve().parents[1]
AXES = {"right": [1, 0, 0], "up": [0, 1, 0], "back": [0, 0, 1]}


def obb(center, size):
    return {"center": list(center), "size": list(size), **AXES}


def healthy_snapshot():
    regions = [
        {"ref": "hub", "path": "Workspace.Hub", "profile": "hub", "obb": obb((0, 8, 0), (100, 30, 100))},
        {"ref": "mine", "path": "Workspace.Mine", "profile": "mine", "obb": obb((160, 8, 0), (80, 30, 80))},
    ]
    for index, center in enumerate(((-120, 0, -70), (-120, 0, 70), (120, 0, -70), (120, 0, 70))):
        regions.append({"ref": f"plot-{index}", "path": f"Workspace.Plot{index}", "profile": "plot", "obb": obb((center[0], 8, center[2]), (50, 30, 50))})

    roots = []
    palette = ([115, 198, 88], [226, 92, 82], [248, 208, 74], [128, 133, 140])
    materials = [
        {"name": "Plastic", "surfaceArea": 25},
        {"name": "Concrete", "surfaceArea": 25},
        {"name": "Wood", "surfaceArea": 25},
        {"name": "Metal", "surfaceArea": 25},
    ]
    colors = [{"rgb": list(rgb), "surfaceArea": 25} for rgb in palette]
    type_counts = {"building": 4, "interactive": 14, "vegetation": 30}
    type_sizes = {"building": (20, 14, 20), "interactive": (10, 8, 10), "vegetation": (14, 10, 14)}
    centers_by_region = {
        "hub": [(x, z) for z in (-30, -10, 10, 30) for x in (-30, -10, 10, 30)],
        "mine": [(140 + x, z) for z in (-20, 0, 20) for x in (0, 20, 40)],
        "plot-0": [(-130, -75), (-110, -65), (-120, -55), (-130, -55)],
        "plot-1": [(-130, 65), (-110, 75), (-120, 85), (-130, 85)],
        "plot-2": [(110, -75), (130, -65), (120, -55), (110, -55)],
        "plot-3": [(110, 65), (130, 75), (120, 85), (110, 85)],
    }
    placements = [(region, point) for region, points in centers_by_region.items() for point in points]
    types = [kind for kind, count in type_counts.items() for _ in range(count)]
    for index, (kind, (region, (x, z))) in enumerate(zip(types, placements)):
        size = type_sizes[kind]
        y = 5 + (index % 4) * 4
        roots.append({
            "ref": f"root-{index}",
            "path": f"Workspace.Root{index}",
            "type": kind,
            "variant": f"variant-{index % 4}",
            "assetKey": f"asset-{kind}",
            "obb": obb((x, y, z), size),
            "materials": copy.deepcopy(materials),
            "colors": copy.deepcopy(colors),
        })
    visibility = []
    for landmark in ("spawn", "shop", "mine", "plot"):
        for region in ("hub", "mine"):
            visibility.append({"landmarkId": landmark, "regionRef": region, "sampled": 10, "visible": 9, "visibleFraction": 0.9, "maximumBlindSpotDegrees": 20, "conclusive": True})
    return {
        "schemaVersion": 1,
        "capturedAt": "2026-08-11T18:00:00+00:00",
        "truncated": False,
        "classification": {"eligible": len(roots), "classified": len(roots), "excluded": 0},
        "roots": roots,
        "regions": regions,
        "visibility": visibility,
    }


class QualityRuleTests(unittest.TestCase):
    def setUp(self):
        self.project = Project.load(ROOT, include_fixture=False)
        self.spec = load_visual_spec(self.project)

    def evaluate(self, snapshot):
        return evaluate_quality_snapshot(
            self.project,
            self.spec,
            snapshot,
            run_id="quality-test",
            build_hash="a" * 64,
            observed_at="2026-08-11T18:00:00+00:00",
        )

    def test_reference_ciede2000_pair(self):
        self.assertAlmostEqual(2.0425, _delta_e_2000((50, 2.6772, -79.7751), (50, 0, -82.7485)), places=4)

    def test_healthy_snapshot_passes_every_deterministic_rule(self):
        evidence = self.evaluate(healthy_snapshot())
        failures = {item.probe: item.details for item in evidence if item.status != "PASS"}
        self.assertFalse(failures, failures)
        self.assertEqual(
            {rule.probe for rule in self.spec.rules if rule.minimum_validation_level == "RUNTIME_VALIDATED"},
            {item.probe for item in evidence},
        )

    def test_empty_world_is_rejected_not_rewarded(self):
        snapshot = healthy_snapshot()
        snapshot["classification"] = {"eligible": 0, "classified": 0, "excluded": 0}
        snapshot["roots"] = []
        evidence = self.evaluate(snapshot)
        self.assertEqual("FAIL", next(item for item in evidence if item.probe == "visual.classification.coverage").status)
        self.assertEqual("FAIL", next(item for item in evidence if item.probe == "visual.object.building.cardinality").status)

    def test_monotone_palette_and_out_of_scale_object_are_rejected(self):
        snapshot = healthy_snapshot()
        for root in snapshot["roots"]:
            root["colors"] = [{"rgb": [255, 0, 255], "surfaceArea": 100}]
        building = next(item for item in snapshot["roots"] if item["type"] == "building")
        building["obb"]["size"] = [500, 500, 500]
        evidence = self.evaluate(snapshot)
        self.assertEqual("FAIL", next(item for item in evidence if item.probe == "visual.palette.conformance").status)
        self.assertEqual("FAIL", next(item for item in evidence if item.probe == "visual.object.building.scale").status)

    def test_truncation_invalidates_all_rule_coverage(self):
        snapshot = healthy_snapshot()
        snapshot["truncated"] = True
        evidence = self.evaluate(snapshot)
        self.assertTrue(evidence)
        self.assertTrue(all(item.truncated and not item.conclusive and item.coverage == 0 for item in evidence))

    def test_snapshot_request_contains_measurement_inputs_but_no_acceptance_thresholds(self):
        params = compile_quality_snapshot_params(self.spec)
        serialized = repr(params)
        self.assertEqual(params["classification"]["rootTag"], "RQEVisualRoot")
        self.assertEqual([item["id"] for item in params["landmarks"]], ["mine", "plot", "shop", "spawn"])
        self.assertNotIn("minimumClassifiedFraction", serialized)
        self.assertNotIn("minimumVisibleAnchorFraction", serialized)
        self.assertNotIn("maximumBlindSpotDegrees", serialized)
        self.assertNotIn("minimumRegionsVisibleFrom", serialized)
        self.assertNotIn("minimumRootsPer1000SquareStuds", serialized)

    def test_snapshot_from_the_wrong_session_cannot_become_quality_evidence(self):
        class FakeBridge:
            pinned_session = "sess_expected"

            @staticmethod
            def call_response(method, params=None, timeout=15.0, lease=None):
                self.assertEqual(method, "quality.snapshot")
                return Response(
                    id="cmd_wrong_session",
                    ok=True,
                    result=healthy_snapshot(),
                    context="run",
                    session="sess_other",
                )

        with self.assertRaisesRegex(QualitySnapshotError, "expected pinned session"):
            measure_quality_snapshot(
                FakeBridge(),
                self.project,
                self.spec,
                run_id="quality-live-test",
                build_hash="b" * 64,
            )

    def test_runtime_snapshot_is_hash_bound_and_rejects_a_bad_world(self):
        bad = healthy_snapshot()
        bad["roots"] = []
        bad["classification"] = {"eligible": 20, "classified": 0, "excluded": 0}

        class FakeBridge:
            pinned_session = "sess_quality"

            @staticmethod
            def call_response(method, params=None, timeout=15.0, lease=None):
                return Response(
                    id="cmd_quality",
                    ok=True,
                    result=bad,
                    context="run",
                    session="sess_quality",
                )

        measurement = measure_quality_snapshot(
            FakeBridge(),
            self.project,
            self.spec,
            run_id="quality-live-test",
            build_hash="c" * 64,
        )
        self.assertEqual(len(measurement.request_sha256), 64)
        self.assertEqual(len(measurement.snapshot_sha256), 64)
        # A conclusive measurement may legitimately (and usefully) FAIL quality.
        self.assertTrue(measurement.conclusive)
        self.assertIn("visual.classification.coverage", measurement.receipt()["failedRules"])
        self.assertFalse(measurement.receipt()["authorizesRelease"])


if __name__ == "__main__":
    unittest.main()
