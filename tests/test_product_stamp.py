from __future__ import annotations

import json
import base64
import shutil
import subprocess
import tempfile
import unittest
import xml.etree.ElementTree as ET
from pathlib import Path

from rqe.hub.protocol import Response
from rqe.product_stamp import load_product_identity_stamp, stamped_rojo_project
from rqe.project import Project
from rqe.release import _evaluate_product_truth
from rqe.run_artifacts import RunArtifacts
from tests.test_product_truth import ProductTruthFixture


class ProductStampTests(unittest.TestCase):
    def setUp(self) -> None:
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.fixture = ProductTruthFixture(Path(temporary.name))
        self.fixture.contract["visualQuality"]["spec"] = "visual/spec.json"
        self.fixture.write_chain()
        self.project = Project(
            root=self.fixture.root,
            config={
                "productIntent": "product/intent.json",
                "contract": "contracts/game.json",
            },
            contract=self.fixture.contract,
            fixture=None,
        )

    def test_stamp_is_bound_to_active_product_documents(self) -> None:
        stamp = load_product_identity_stamp(self.project)
        self.assertEqual("industrial-card-farm", stamp.product_id)
        self.assertEqual("industrial-card-farm.release", stamp.contract_id)
        self.assertEqual(64, len(stamp.stamp_sha256))
        self.assertEqual(
            self.fixture.expected["intent"], stamp.hashes["productIntent"]
        )

    def test_stamped_rojo_project_builds_identity_configuration(self) -> None:
        if shutil.which("rojo") is None:
            self.skipTest("Rojo is not installed")
        stamp = load_product_identity_stamp(self.project)
        source_project = self.fixture.root / "minimal.project.json"
        source_project.write_text(
            json.dumps(
                {
                    "name": "IdentityFixture",
                    "tree": {
                        "$className": "DataModel",
                        "ReplicatedStorage": {"$className": "ReplicatedStorage"},
                    },
                }
            ),
            encoding="utf-8",
        )
        generated = self.fixture.root / "stamped.project.json"
        generated.write_text(
            json.dumps(stamped_rojo_project(source_project, stamp)),
            encoding="utf-8",
        )
        output = self.fixture.root / "candidate.rbxlx"
        completed = subprocess.run(
            ["rojo", "build", str(generated), "--output", str(output)],
            capture_output=True,
            text=True,
            timeout=30,
            check=False,
        )
        self.assertEqual(0, completed.returncode, completed.stderr)
        xml = output.read_text(encoding="utf-8")
        self.assertIn("RQEProductIdentity", xml)
        root = ET.fromstring(xml)
        encoded = root.find(".//BinaryString[@name='AttributesSerialize']")
        self.assertIsNotNone(encoded)
        attributes = base64.b64decode(encoded.text or "")
        self.assertIn(b"industrial-card-farm", attributes)
        self.assertIn(stamp.stamp_sha256.encode("ascii"), attributes)

    def test_measured_matching_identity_produces_release_evidence(self) -> None:
        stamp = load_product_identity_stamp(self.project)
        run = RunArtifacts.create(self.fixture.root / "artifacts", "release-001")
        response = Response(
            id="cmd_product_identity_1",
            ok=True,
            result={
                "available": True,
                "conclusive": True,
                "measuredIdentity": {
                    "productId": stamp.product_id,
                    "intentId": stamp.intent_id,
                    "contractId": stamp.contract_id,
                    "visualSpecId": stamp.visual_spec_id,
                },
                "artifactHashes": dict(stamp.hashes),
            },
            context="run",
            place="candidate.rbxlx",
            session="sess_exact_build",
        )
        evidence, assessment = _evaluate_product_truth(
            self.project,
            run,
            stamp=stamp,
            stamp_error=None,
            identity_response=response,
            build_id="build-001",
            place_sha256=self.fixture.PLACE_HASH,
        )
        self.assertTrue(assessment.ready, assessment.to_dict())
        self.assertEqual("PASS", evidence.status)
        self.assertEqual("RUNTIME_VALIDATED", evidence.validation_level)
        self.assertTrue(
            (run.directory / "product-truth/runtime-identity.json").is_file()
        )

    def test_wrong_runtime_product_blocks_even_with_a_valid_stamp(self) -> None:
        stamp = load_product_identity_stamp(self.project)
        run = RunArtifacts.create(self.fixture.root / "artifacts", "release-002")
        response = Response(
            id="cmd_product_identity_2",
            ok=True,
            result={
                "available": True,
                "conclusive": True,
                "measuredIdentity": {
                    "productId": "another-product",
                    "intentId": stamp.intent_id,
                    "contractId": stamp.contract_id,
                    "visualSpecId": stamp.visual_spec_id,
                },
                "artifactHashes": dict(stamp.hashes),
            },
            context="run",
            place="candidate.rbxlx",
            session="sess_exact_build",
        )
        evidence, assessment = _evaluate_product_truth(
            self.project,
            run,
            stamp=stamp,
            stamp_error=None,
            identity_response=response,
            build_id="build-001",
            place_sha256=self.fixture.PLACE_HASH,
        )
        self.assertFalse(assessment.ready)
        self.assertEqual("FAIL", evidence.status)
        self.assertIn(
            "RUNTIME_PRODUCT_ID_MISMATCH",
            {item.code for item in assessment.issues},
        )

    def test_project_without_product_intent_is_an_explicit_blocker(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            project = Project(root, {}, {}, None)
            run = RunArtifacts.create(root / "artifacts", "release-no-intent")
            evidence, assessment = _evaluate_product_truth(
                project,
                run,
                stamp=None,
                stamp_error=None,
                identity_response=None,
                build_id="build-no-intent",
                place_sha256="a" * 64,
            )
            self.assertEqual("FAIL", evidence.status)
            self.assertFalse(evidence.conclusive)
            self.assertIn(
                "PRODUCT_INTENT_NOT_CONFIGURED",
                {item.code for item in assessment.issues},
            )


if __name__ == "__main__":
    unittest.main()
