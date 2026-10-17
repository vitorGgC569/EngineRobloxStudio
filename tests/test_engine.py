import json
import shutil
import tempfile
import unittest
from pathlib import Path

from tests.support import copy_project
from rqe.audit import run_audit
from rqe.project import Project
from rqe.scanner import scan_structure


ROOT = Path(__file__).resolve().parents[1]


class EngineTests(unittest.TestCase):
    def test_headless_audit_is_diagnostic_and_cannot_release(self):
        report = run_audit(ROOT)
        self.assertFalse(report.release_allowed)
        # The diagnostic audit may now expose requirements it cannot prove;
        # only the immutable release gate is authoritative.
        self.assertGreaterEqual(report.summary["FAIL"], 0)
        self.assertGreaterEqual(report.summary["executed"], 27)
        self.assertTrue(
            any(
                item.probe == "contract_coverage"
                and item.status == "FAIL"
                and item.source == "probe-registry"
                for item in report.evidence
            )
        )
        self.assertTrue(any("diagnostic only" in reason for reason in report.release_reasons))
        for category in ("performance", "geometry", "ui"):
            self.assertEqual(report.scores[category], 0.0, category)
        # The shipped game-state fixture and the headless runtime are full of
        # healthy literals. Those probes must not come back as passes.
        healthy_literals = {
            "spawn_clearance", "path_exists", "objective_reachable", "floor_progression",
            "door_clearance", "stairs_validity", "interaction_distance", "camera_obstruction",
            "remote_security", "runtime_error", "persistence", "multiplayer_isolation",
            "asset_security", "visual_quality", "visual_snapshot_bundle",
            "performance_budget", "floating_objects", "ui_visibility",
        }
        for item in report.evidence:
            if item.source == "headless-runtime" and item.probe in healthy_literals:
                self.assertNotEqual(item.status, "PASS", item.probe)

    def test_floating_object_blocks_release(self):
        with tempfile.TemporaryDirectory() as directory:
            temp_root = Path(directory) / "project"
            copy_project(ROOT, temp_root)
            fixture_path = temp_root / "roblox/mvp/game-state.json"
            fixture = json.loads(fixture_path.read_text(encoding="utf-8"))
            fixture["geometry"]["floating"].append("TestRock")
            fixture_path.write_text(json.dumps(fixture), encoding="utf-8")
            report = run_audit(temp_root)
            self.assertFalse(report.release_allowed)
            self.assertTrue(any(item.probe == "floating_objects" and item.status == "FAIL" for item in report.evidence))

    def test_static_scanner_detects_suspicious_require(self):
        with tempfile.TemporaryDirectory() as directory:
            temp_root = Path(directory) / "project"
            copy_project(ROOT, temp_root)
            bad_script = temp_root / "roblox/mvp/src/ServerScriptService/BadAsset.server.lua"
            bad_script.write_text("local x = require(123456)\n", encoding="utf-8")
            project = Project.load(temp_root)
            _, static_scan = scan_structure(project)
            self.assertEqual(static_scan["suspiciousScripts"][0]["pattern"], "numeric_require")

    def test_static_scan_proves_purchase_remote_has_distance_guard(self):
        project = Project.load(ROOT)
        _, static_scan = scan_structure(project)
        self.assertTrue(static_scan["serverPurchaseDistanceGuard"])

    def test_asset_manifest_is_allocated_and_clean(self):
        manifest = json.loads((ROOT / "assets/asset-manifest.json").read_text(encoding="utf-8"))
        assets = manifest["assets"]
        keys = [asset["key"] for asset in assets]
        self.assertGreaterEqual(len(assets), 9)
        self.assertEqual(len(keys), len(set(keys)))
        for asset in assets:
            self.assertIn(asset["source"], {"native-procedural", "generated-raster"})
            self.assertEqual(asset["status"], "approved")
            self.assertEqual(asset["scriptScan"], "clean")
            self.assertTrue(asset["allocatedTo"])
            self.assertGreater(asset["maxInstances"], 0)
            self.assertTrue(asset["functionalProbe"])
            if asset.get("localFile"):
                self.assertTrue((ROOT / asset["localFile"]).exists())

    def test_invalid_asset_allocation_blocks_release(self):
        with tempfile.TemporaryDirectory() as directory:
            temp_root = Path(directory) / "project"
            copy_project(ROOT, temp_root)
            manifest_path = temp_root / "assets/asset-manifest.json"
            manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
            manifest["assets"][0]["allocatedTo"] = []
            manifest_path.write_text(json.dumps(manifest), encoding="utf-8")
            report = run_audit(temp_root)
            self.assertFalse(report.release_allowed)
            self.assertTrue(any(item.id == "security.asset_manifest" and item.status == "FAIL" for item in report.evidence))

    def test_generated_visual_assets_have_valid_dimensions(self):
        report = run_audit(ROOT)
        evidence = next(item for item in report.evidence if item.probe == "visual_asset_quality")
        self.assertEqual(evidence.status, "PASS")
        self.assertGreaterEqual(evidence.details["assetCount"], 4)


if __name__ == "__main__":
    unittest.main()
