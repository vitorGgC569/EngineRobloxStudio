from __future__ import annotations

import unittest
from pathlib import Path

from rqe.measurement_plan import compile_measurement_plan
from rqe.probe_registry import load_probe_registry
from rqe.project import Project


ROOT = Path(__file__).resolve().parents[1]


class ProbeProducerRegistryTests(unittest.TestCase):
    def setUp(self) -> None:
        self.project = Project.load(ROOT)
        self.registry = load_probe_registry(self.project)

    def test_release_integrated_runtime_probe_is_available(self) -> None:
        result = self.registry.resolve(
            "runtime_error",
            minimum_validation_level="RUNTIME_VALIDATED",
            allowed_sources=("studio-bridge",),
        )
        self.assertTrue(result.available, result.reasons)
        self.assertIn("runtime.output-errors", result.producer_ids)

    def test_fixture_only_probe_is_not_a_release_producer(self) -> None:
        result = self.registry.resolve(
            "card_gallery",
            minimum_validation_level="VISUALLY_VALIDATED",
        )
        self.assertFalse(result.available)
        self.assertTrue(any("FIXTURE_ONLY" in reason for reason in result.reasons))

    def test_partial_visual_code_is_not_mistaken_for_an_integrated_producer(self) -> None:
        result = self.registry.resolve(
            "visual.palette.conformance",
            minimum_validation_level="RUNTIME_VALIDATED",
            allowed_sources=("studio-quality-validator",),
        )
        self.assertFalse(result.available)
        self.assertTrue(any("not integrated" in reason for reason in result.reasons))

    def test_compiled_plan_lists_every_orphan_with_a_reason(self) -> None:
        plan = compile_measurement_plan(self.project)
        registry = plan.metadata["probeRegistry"]
        self.assertGreater(registry["requirements"], registry["available"])
        orphan = next(
            item for item in registry["orphans"]
            if item["requirementId"] == "card_gallery_is_visible"
        )
        self.assertEqual("card_gallery", orphan["probe"])
        self.assertTrue(orphan["reasons"])


if __name__ == "__main__":
    unittest.main()
