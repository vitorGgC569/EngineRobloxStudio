from __future__ import annotations

import unittest
from pathlib import Path

from rqe.models import Evidence
from rqe.project import read_json
from rqe.schema_validation import validate_schema_instance


ROOT = Path(__file__).resolve().parents[1]


class EvidenceSchemaTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.schema = read_json(ROOT / "schemas/test-result.schema.json")

    def test_evidence_model_serializes_every_provenance_field(self) -> None:
        payload = Evidence(
            id="runtime.fps",
            probe="performance_budget",
            category="performance",
            status="PASS",
            severity="major",
            message="sampled",
            source="studio-bridge",
            validation_level="RUNTIME_VALIDATED",
            observed_at="2026-08-11T18:00:00+00:00",
            run_id="run-1",
            build_hash="a" * 64,
            coverage=1,
        ).to_dict()
        self.assertEqual([], validate_schema_instance(payload, self.schema))

    def test_missing_validation_level_or_source_is_rejected(self) -> None:
        payload = Evidence(
            id="runtime.fps",
            probe="performance_budget",
            category="performance",
            status="PASS",
            severity="major",
            message="sampled",
            source="studio-bridge",
            validation_level="RUNTIME_VALIDATED",
        ).to_dict()
        del payload["source"]
        del payload["validationLevel"]
        issues = [str(item) for item in validate_schema_instance(payload, self.schema)]
        self.assertTrue(any("source" in item and "required" in item for item in issues))
        self.assertTrue(any("validationLevel" in item and "required" in item for item in issues))

    def test_unknown_field_cannot_weaken_evidence_policy(self) -> None:
        payload = Evidence(
            id="runtime.fps",
            probe="performance_budget",
            category="performance",
            status="PASS",
            severity="major",
            message="sampled",
            source="studio-bridge",
            validation_level="RUNTIME_VALIDATED",
        ).to_dict()
        payload["validationLevl"] = "E2E_VALIDATED"
        issues = [str(item) for item in validate_schema_instance(payload, self.schema)]
        self.assertTrue(any("unknown property" in item for item in issues))


if __name__ == "__main__":
    unittest.main()
