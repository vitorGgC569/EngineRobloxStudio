from __future__ import annotations

import copy
import hashlib
import json
import tempfile
import unittest
from pathlib import Path
from typing import Any

from rqe.product_truth import (
    ProductTruthError,
    assess_product_truth,
    required_calibration_targets,
)


ROOT = Path(__file__).resolve().parents[1]


def _hash(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def _write(path: Path, payload: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")


class ProductTruthFixture:
    PLACE_HASH = hashlib.sha256(b"candidate-place").hexdigest()

    def __init__(self, root: Path) -> None:
        self.root = root
        for filename in (
            "product-intent.v1.schema.json",
            "reference-benchmark.v1.schema.json",
            "visual-calibration-receipt.v1.schema.json",
            "runtime-product-identity-receipt.v1.schema.json",
        ):
            target = root / "schemas" / filename
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes((ROOT / "schemas" / filename).read_bytes())

        self.paths = {
            "intent": root / "product" / "intent.json",
            "contract": root / "contracts" / "game.json",
            "spec": root / "contracts" / "visual" / "spec.json",
            "benchmark": root / "product" / "references" / "benchmark.json",
            "calibration": root / "product" / "references" / "calibration.json",
            "runtime": root / "artifacts" / "run-001" / "runtime-identity.json",
            "source": root / "product" / "references" / "screens" / "reference.png",
        }
        self.paths["source"].parent.mkdir(parents=True, exist_ok=True)
        self.paths["source"].write_bytes(b"\x89PNG\r\nindependent-reference")

        self.contract = {
            "schemaVersion": 1,
            "contractId": "industrial-card-farm.release",
            "productId": "industrial-card-farm",
            "visualQuality": {
                "release": {"minimumScore": 82, "minimumRuleCoverage": 1.0}
            },
            "release_gate": {"minimum_visual_score": 82},
            "requirements": [
                {"id": "world_card_farm"},
                {"id": "ui_card_gallery"},
                {"id": "collect_card"},
            ],
            "productTruth": {
                "intentId": "industrial-card-farm.intent",
                "semanticBindings": {
                    "worldRoles": {"card-farm": ["world_card_farm"]},
                    "uiSurfaces": {"card-gallery": ["ui_card_gallery"]},
                    "gameplayVerbs": {"collect-card": ["collect_card"]},
                },
            },
        }
        self.spec = {
            "schemaVersion": 1,
            "specId": "industrial-card-farm.visual",
            "productId": "industrial-card-farm",
            "productTruth": {
                "intentId": "industrial-card-farm.intent",
                "calibrationId": "industrial-card-farm.visual-calibration",
                "semanticBindings": {
                    "worldRoles": {
                        "card-farm": {
                            "landmarkIds": ["farm"],
                            "regionSetIds": ["farm-regions"],
                            "viewpointIds": ["farm"],
                        }
                    },
                    "uiSurfaces": {
                        "card-gallery": {
                            "landmarkIds": [], "regionSetIds": [], "viewpointIds": ["gallery"]
                        }
                    },
                },
            },
            "classification": {"minimumClassifiedFraction": 0.98},
            "palette": {
                "maximumDeltaE": 11.5,
                "maximumOffPaletteFraction": 0.04,
                "swatches": [{"id": "primary", "rgb": [30, 120, 240]}],
            },
            "objectTypes": {
                "building": {
                    "minimumInstances": 6,
                    "maximumInstances": 30,
                    "scale": {
                        "minimumSize": [4, 5, 4],
                        "maximumSize": [90, 70, 90],
                        "maximumRelativeMad": 0.5,
                    },
                }
            },
            "regionProfiles": {
                "farm": {
                    "density": {
                        "minimumRootsPer1000SquareStuds": 2.5,
                        "maximumRootsPer1000SquareStuds": 18,
                        "minimumFootprintCoverage": 0.2,
                    },
                    "materialVariety": {
                        "minimumDistinctMaterials": 4,
                        "maximumDominantFraction": 0.65,
                    },
                }
            },
            "regionSets": {
                "farm-regions": {
                    "minimumRegions": 1,
                    "maximumRegions": 2,
                    "minimumProfileCoverage": 1.0,
                }
            },
            "landmarks": {
                "farm": {
                    "maximumDistance": 100,
                    "sampleSpacing": 10,
                    "eyeHeight": 5,
                    "raysPerAnchor": 9,
                    "minimumVisibleAnchorFraction": 0.8,
                    "maximumBlindSpotDegrees": 75,
                    "minimumRegionsVisibleFrom": 1,
                }
            },
            "viewpoints": {
                "farm": {
                    "resolution": [1920, 1080],
                    "camera": {"distance": 40, "height": 12, "fieldOfView": 70},
                    "rubric": {"composition": 0.3, "hierarchy": 0.25, "legibility": 0.2, "materiality": 0.1, "polish": 0.15},
                },
                "gallery": {
                    "resolution": [390, 844],
                    "camera": {"distance": 16, "height": 5, "fieldOfView": 72},
                    "rubric": {"composition": 0.15, "hierarchy": 0.2, "legibility": 0.4, "materiality": 0.1, "polish": 0.15},
                },
            },
            "evaluationStates": {
                "initial": {"minimumRuleCoverage": 1.0}
            },
        }
        targets = required_calibration_targets(self.contract, self.spec)
        observations = []
        thresholds = []
        for index, target in enumerate(targets):
            observation_id = f"obs_{index:03d}"
            metric_id = f"reference.metric.{index:03d}"
            scope = f"{target.artifact}:{target.pointer}"
            observations.append({
                "observationId": observation_id,
                "metricId": metric_id,
                "scope": scope,
                "value": target.value,
                "unit": "declared-unit",
                "method": "Measured from the frozen external reference snapshot.",
                "tool": "reference-annotator-v1",
                "observedAt": "2026-01-02T00:00:00Z",
                "sourceIds": ["reference_frame"],
                "confidence": 0.9,
                "candidateDerived": False,
            })
            thresholds.append({
                "thresholdId": f"threshold_{index:03d}",
                "metricId": metric_id,
                "scope": scope,
                "targetArtifact": target.artifact,
                "targetPointer": target.pointer,
                "operator": target.operator,
                "value": target.value,
                "unit": "declared-unit",
                "candidateDerived": False,
                "provenance": {
                    "benchmarkId": "industrial-card-farm.reference-v1",
                    "benchmarkSha256": "0" * 64,
                    "sourceObservationIds": [observation_id],
                    "derivationMethod": "reference-mean",
                    "derivationParameters": {"sampleCount": 1},
                    "tool": "visual-calibrator",
                    "toolVersion": "1.0.0",
                    "derivedAt": "2026-01-03T00:00:00Z",
                    "derivedBy": "product-quality",
                    "candidateDerived": False,
                },
            })
        self.benchmark = {
            "$schema": "../../schemas/reference-benchmark.v1.schema.json",
            "schemaVersion": 1,
            "benchmarkId": "industrial-card-farm.reference-v1",
            "revision": 1,
            "productId": "industrial-card-farm",
            "createdAt": "2026-01-01T00:00:00Z",
            "frozenAt": "2026-01-02T12:00:00Z",
            "candidateDerived": False,
            "independenceReceipt": {
                "decision": "INDEPENDENT",
                "basis": "external-published-product",
                "verifiedBy": "product-director",
                "verifiedAt": "2026-01-02T06:00:00Z",
                "excludedCandidateProductId": "industrial-card-farm",
                "candidateArtifactsUsed": False,
            },
            "sources": [{
                "sourceId": "reference_frame",
                "referenceProductId": "published-card-farm-reference",
                "label": "Approved reference frame",
                "sourceType": "screenshot",
                "originLocator": "https://example.invalid/reference",
                "acquiredAt": "2026-01-01T12:00:00Z",
                "snapshotPath": "product/references/screens/reference.png",
                "sha256": _hash(self.paths["source"]),
                "candidateDerived": False,
                "rights": {"status": "fair-use-analysis", "usageScope": "benchmark-only"},
            }],
            "observations": observations,
        }
        self.calibration = {
            "$schema": "../../schemas/visual-calibration-receipt.v1.schema.json",
            "schemaVersion": 1,
            "calibrationId": "industrial-card-farm.visual-calibration",
            "revision": 1,
            "productId": "industrial-card-farm",
            "benchmark": {
                "benchmarkId": "industrial-card-farm.reference-v1",
                "sha256": "0" * 64,
            },
            "methodology": {
                "calibratedAt": "2026-01-03T06:00:00Z",
                "calibratedBy": "product-quality",
                "freezeBeforeCandidateEvaluation": True,
                "candidateInputsUsed": False,
                "method": "Thresholds derived from the frozen independent reference observations.",
            },
            "thresholds": thresholds,
        }
        self.intent = {
            "$schema": "../schemas/product-intent.v1.schema.json",
            "schemaVersion": 1,
            "intentId": "industrial-card-farm.intent",
            "revision": 1,
            "productId": "industrial-card-farm",
            "title": "Industrial Card Farm",
            "productClass": {"genre": "collection tycoon", "templateFamily": "card-farm"},
            "pillars": [{"id": "collection", "description": "Collect readable cards."}],
            "audience": {"description": "Broad Roblox audience", "targetDevices": ["desktop", "phone"]},
            "coreLoop": ["Acquire a card, inspect it in the gallery, and reinvest."],
            "semantics": {
                "worldRoles": [{"id": "card-farm", "description": "The card production floor."}],
                "uiSurfaces": [{"id": "card-gallery", "description": "The player's collected-card gallery."}],
                "gameplayVerbs": [{"id": "collect-card", "description": "Collect a produced card."}],
            },
            "authorship": {
                "authorityKind": "human-product-director",
                "authorityId": "director-001",
                "approvedAt": "2026-01-04T00:00:00Z",
                "candidateDerived": False,
            },
            "calibrationPolicy": {
                "requireIndependentReferences": True,
                "forbidCandidateDerivedThresholds": True,
                "requireCompleteThresholdCoverage": True,
            },
            "bindings": {
                "contract": {"path": "contracts/game.json", "artifactId": "industrial-card-farm.release", "sha256": "0" * 64},
                "visualQualitySpec": {"path": "contracts/visual/spec.json", "artifactId": "industrial-card-farm.visual", "sha256": "0" * 64},
                "referenceBenchmark": {"path": "product/references/benchmark.json", "artifactId": "industrial-card-farm.reference-v1", "sha256": "0" * 64},
                "visualCalibration": {"path": "product/references/calibration.json", "artifactId": "industrial-card-farm.visual-calibration", "sha256": "0" * 64},
            },
        }
        self.runtime = {
            "$schema": "../../schemas/runtime-product-identity-receipt.v1.schema.json",
            "schemaVersion": 1,
            "receiptId": "runtime.identity.001",
            "runId": "run-001",
            "buildId": "build-001",
            "sessionId": "studio-session-001",
            "commandId": "command-identity-001",
            "source": "studio-bridge",
            "validationLevel": "RUNTIME_VALIDATED",
            "observedAt": "2026-01-05T00:00:00Z",
            "coverage": 1,
            "conclusive": True,
            "truncated": False,
            "measuredIdentity": {
                "productId": "industrial-card-farm",
                "contractId": "industrial-card-farm.release",
                "visualSpecId": "industrial-card-farm.visual",
            },
            "artifactHashes": {
                "productIntent": "0" * 64,
                "contract": "0" * 64,
                "visualQualitySpec": "0" * 64,
                "referenceBenchmark": "0" * 64,
                "visualCalibration": "0" * 64,
                "place": self.PLACE_HASH,
            },
        }
        self.expected: dict[str, str] = {}
        self.write_chain()

    def write_chain(self) -> None:
        _write(self.paths["contract"], self.contract)
        _write(self.paths["spec"], self.spec)
        self.benchmark["sources"][0]["sha256"] = _hash(self.paths["source"])
        _write(self.paths["benchmark"], self.benchmark)
        benchmark_hash = _hash(self.paths["benchmark"])
        self.calibration["benchmark"]["sha256"] = benchmark_hash
        for threshold in self.calibration["thresholds"]:
            threshold["provenance"]["benchmarkSha256"] = benchmark_hash
        _write(self.paths["calibration"], self.calibration)
        self.intent["bindings"]["contract"]["sha256"] = _hash(self.paths["contract"])
        self.intent["bindings"]["visualQualitySpec"]["sha256"] = _hash(self.paths["spec"])
        self.intent["bindings"]["referenceBenchmark"]["sha256"] = benchmark_hash
        self.intent["bindings"]["visualCalibration"]["sha256"] = _hash(self.paths["calibration"])
        _write(self.paths["intent"], self.intent)
        self.runtime["artifactHashes"].update({
            "productIntent": _hash(self.paths["intent"]),
            "contract": _hash(self.paths["contract"]),
            "visualQualitySpec": _hash(self.paths["spec"]),
            "referenceBenchmark": benchmark_hash,
            "visualCalibration": _hash(self.paths["calibration"]),
        })
        _write(self.paths["runtime"], self.runtime)
        self.expected = {
            "intent": _hash(self.paths["intent"]),
            "runtime": _hash(self.paths["runtime"]),
        }

    def assess(self, **overrides: Any):
        kwargs = {
            "expected_product_intent_sha256": self.expected["intent"],
            "expected_runtime_identity_sha256": self.expected["runtime"],
            "expected_run_id": "run-001",
            "expected_build_id": "build-001",
            "expected_place_sha256": self.PLACE_HASH,
        }
        kwargs.update(overrides)
        return assess_product_truth(
            self.root,
            "product/intent.json",
            "artifacts/run-001/runtime-identity.json",
            **kwargs,
        )


class ProductTruthTests(unittest.TestCase):
    def setUp(self) -> None:
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.fixture = ProductTruthFixture(Path(temporary.name))

    @staticmethod
    def _codes(assessment) -> set[str]:
        return {item.code for item in assessment.issues}

    def test_complete_independent_cross_bound_bundle_is_ready(self) -> None:
        assessment = self.fixture.assess()
        self.assertTrue(assessment.ready, assessment.to_dict())
        self.assertEqual("industrial-card-farm", assessment.bundle.product_id)
        self.assertGreater(len(assessment.bundle.required_calibration_targets), 30)
        assessment.bundle.verify_unchanged()

    def test_missing_immutable_intent_hash_blocks(self) -> None:
        assessment = self.fixture.assess(expected_product_intent_sha256=None)
        self.assertEqual("BLOCKED", assessment.status)
        self.assertIn("EXPECTED_HASH_MISSING", self._codes(assessment))

    def test_wrong_runtime_product_id_blocks_even_when_every_file_is_rehashed(self) -> None:
        self.fixture.runtime["measuredIdentity"]["productId"] = "different-product"
        self.fixture.write_chain()
        assessment = self.fixture.assess()
        self.assertIn("RUNTIME_PRODUCT_ID_MISMATCH", self._codes(assessment))

    def test_contract_for_a_different_product_blocks(self) -> None:
        self.fixture.contract["productId"] = "miners-ridge"
        self.fixture.write_chain()
        assessment = self.fixture.assess()
        self.assertIn("PRODUCT_ID_MISMATCH", self._codes(assessment))

    def test_wrong_game_semantics_block_even_with_matching_product_id(self) -> None:
        bindings = self.fixture.spec["productTruth"]["semanticBindings"]
        bindings["worldRoles"] = {
            "mine": {"landmarkIds": ["farm"], "regionSetIds": ["farm-regions"], "viewpointIds": ["farm"]}
        }
        self.fixture.write_chain()
        assessment = self.fixture.assess()
        self.assertIn("VISUAL_SEMANTIC_COVERAGE_MISMATCH", self._codes(assessment))

    def test_reference_product_cannot_be_the_candidate(self) -> None:
        self.fixture.benchmark["sources"][0]["referenceProductId"] = "industrial-card-farm"
        self.fixture.write_chain()
        assessment = self.fixture.assess()
        self.assertIn("REFERENCE_IS_CANDIDATE", self._codes(assessment))

    def test_candidate_derived_reference_is_rejected_by_owned_schema(self) -> None:
        self.fixture.benchmark["sources"][0]["candidateDerived"] = True
        self.fixture.write_chain()
        assessment = self.fixture.assess()
        self.assertIn("SCHEMA_VALIDATION_FAILED", self._codes(assessment))
        self.assertTrue(any("candidateDerived" in item.message for item in assessment.issues))

    def test_tampered_reference_snapshot_blocks(self) -> None:
        self.fixture.paths["source"].write_bytes(b"tampered")
        assessment = self.fixture.assess()
        self.assertIn("REFERENCE_SOURCE_HASH_MISMATCH", self._codes(assessment))

    def test_missing_one_calibration_target_blocks(self) -> None:
        self.fixture.calibration["thresholds"].pop()
        self.fixture.write_chain()
        assessment = self.fixture.assess()
        self.assertIn("CALIBRATION_COVERAGE_MISSING", self._codes(assessment))

    def test_threshold_copied_from_candidate_is_rejected(self) -> None:
        self.fixture.calibration["thresholds"][0]["candidateDerived"] = True
        self.fixture.write_chain()
        assessment = self.fixture.assess()
        self.assertIn("SCHEMA_VALIDATION_FAILED", self._codes(assessment))
        self.assertTrue(any("candidateDerived" in item.message for item in assessment.issues))

    def test_threshold_without_matching_reference_metric_blocks(self) -> None:
        self.fixture.calibration["thresholds"][0]["metricId"] = "unrelated.metric"
        self.fixture.write_chain()
        assessment = self.fixture.assess()
        self.assertIn("CALIBRATION_METRIC_MISMATCH", self._codes(assessment))

    def test_candidate_spec_value_cannot_drift_from_frozen_receipt(self) -> None:
        self.fixture.spec["objectTypes"]["building"]["minimumInstances"] = 1
        self.fixture.write_chain()
        assessment = self.fixture.assess()
        self.assertIn("CALIBRATION_VALUE_MISMATCH", self._codes(assessment))

    def test_rewriting_spec_and_receipt_together_cannot_forge_reference_derivation(self) -> None:
        pointer = "/objectTypes/building/minimumInstances"
        self.fixture.spec["objectTypes"]["building"]["minimumInstances"] = 1
        threshold = next(
            item for item in self.fixture.calibration["thresholds"]
            if item["targetArtifact"] == "visualQualitySpec" and item["targetPointer"] == pointer
        )
        threshold["value"] = 1
        self.fixture.write_chain()
        assessment = self.fixture.assess()
        self.assertIn("CALIBRATION_DERIVATION_MISMATCH", self._codes(assessment))

    def test_root_escape_in_a_binding_blocks(self) -> None:
        self.fixture.intent["bindings"]["contract"]["path"] = "../outside.json"
        self.fixture.write_chain()
        assessment = self.fixture.assess()
        self.assertIn("PATH_NOT_NORMALIZED", self._codes(assessment))

    def test_bundle_detects_post_validation_mutation(self) -> None:
        assessment = self.fixture.assess()
        self.assertTrue(assessment.ready, assessment.to_dict())
        self.fixture.paths["spec"].write_text("{}", encoding="utf-8")
        with self.assertRaises(ProductTruthError) as raised:
            assessment.bundle.verify_unchanged()
        self.assertIn("ARTIFACT_CHANGED", {item.code for item in raised.exception.issues})


if __name__ == "__main__":
    unittest.main()
