from __future__ import annotations

import copy
import json
import tempfile
import unittest
from pathlib import Path

from rqe.project import Project
from rqe.visual_spec import VisualSpecError, load_visual_spec


ROOT = Path(__file__).resolve().parents[1]


class VisualSpecTests(unittest.TestCase):
    def setUp(self) -> None:
        self.project = Project.load(ROOT, include_fixture=False)

    def test_repository_visual_spec_is_executable_and_complete(self) -> None:
        spec = load_visual_spec(self.project)
        self.assertEqual("miners-ridge.visual-quality", spec.spec_id)
        self.assertGreaterEqual(len(spec.rules), 30)
        probes = [rule.probe for rule in spec.rules]
        self.assertEqual(len(probes), len(set(probes)))
        self.assertIn("visual.viewpoint.mobile-store.capture", probes)
        self.assertIn("visual.region.plot-regions.density", probes)

    def test_unknown_field_fails_closed(self) -> None:
        project = self._temporary_project()
        data, path = self._visual_data(project)
        data["classification"]["minimumClassifiedFracton"] = 0.5
        path.write_text(json.dumps(data), encoding="utf-8")
        with self.assertRaisesRegex(VisualSpecError, "unknown property"):
            load_visual_spec(project)

    def test_unknown_region_profile_is_rejected(self) -> None:
        project = self._temporary_project()
        data, path = self._visual_data(project)
        data["regionSets"]["hub-regions"]["profile"] = "missing"
        path.write_text(json.dumps(data), encoding="utf-8")
        with self.assertRaisesRegex(VisualSpecError, "unknown profile"):
            load_visual_spec(project)

    def test_invalid_minimum_maximum_is_rejected(self) -> None:
        project = self._temporary_project()
        data, path = self._visual_data(project)
        data["regionProfiles"]["hub"]["density"]["minimumRootsPer1000SquareStuds"] = 100
        path.write_text(json.dumps(data), encoding="utf-8")
        with self.assertRaisesRegex(VisualSpecError, "density minimum exceeds maximum"):
            load_visual_spec(project)

    def test_rubric_weights_must_sum_to_one(self) -> None:
        project = self._temporary_project()
        data, path = self._visual_data(project)
        data["viewpoints"]["spawn"]["rubric"]["polish"] = 0.1
        path.write_text(json.dumps(data), encoding="utf-8")
        with self.assertRaisesRegex(VisualSpecError, "weights must sum to 1"):
            load_visual_spec(project)

    def test_contract_cannot_escape_to_an_external_visual_spec(self) -> None:
        project = self._temporary_project()
        project.contract["visualQuality"]["spec"] = "../../../outside.json"
        with self.assertRaisesRegex(VisualSpecError, "escapes the project root"):
            load_visual_spec(project)

    def _temporary_project(self) -> Project:
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        root = Path(temporary.name)
        for relative in (
            "rqe.project.json",
            "quality/quality-focus.json",
            "contracts/mining-tycoon.robloxqa.json",
            "contracts/visual/miners-ridge.visual-quality.v1.json",
            "contracts/scenarios/first-purchase-e2e.json",
            "contracts/scenarios/purchase-first-pack.json",
            "schemas/visual-quality-spec.v1.schema.json",
        ):
            source = ROOT / relative
            target = root / relative
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(source.read_bytes())
        return Project.load(root, include_fixture=False)

    @staticmethod
    def _visual_data(project: Project) -> tuple[dict, Path]:
        path = project.root / "contracts/visual/miners-ridge.visual-quality.v1.json"
        return copy.deepcopy(json.loads(path.read_text(encoding="utf-8"))), path


if __name__ == "__main__":
    unittest.main()
