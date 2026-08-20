from __future__ import annotations

import copy
import hashlib
import json
import shutil
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from rqe.production_capabilities import (
    CATALOG_RELATIVE_PATH,
    REQUIRED_PHASES,
    AdapterResolution,
    CapabilityCatalogError,
    CapabilitySelectionError,
    ProductionCapabilityCatalog,
    load_default_catalog,
    write_structured_receipt,
)
from rqe.schema_validation import validate_schema_instance


ROOT = Path(__file__).resolve().parents[1]


def _json(path: Path) -> dict:
    return json.loads(path.read_text(encoding="utf-8"))


def _write_json(path: Path, payload: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")


def _sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


class ProductionCapabilityCatalogTests(unittest.TestCase):
    def _temporary_catalog(self) -> tuple[tempfile.TemporaryDirectory, Path, dict, dict]:
        temporary = tempfile.TemporaryDirectory()
        root = Path(temporary.name)
        catalog = _json(ROOT / CATALOG_RELATIVE_PATH)
        manifest = _json(ROOT / "schemas/bridge-commands.v1.json")
        (root / "schemas").mkdir(parents=True, exist_ok=True)
        shutil.copyfile(
            ROOT / "schemas/production-capability-catalog.v1.schema.json",
            root / "schemas/production-capability-catalog.v1.schema.json",
        )
        return temporary, root, catalog, manifest

    def _materialize(self, root: Path, catalog: dict, manifest: dict) -> None:
        manifest_path = root / "schemas/bridge-commands.v1.json"
        _write_json(manifest_path, manifest)
        catalog["commandManifest"]["sha256"] = _sha256(manifest_path)
        _write_json(root / CATALOG_RELATIVE_PATH, catalog)

    def test_default_catalog_covers_every_phase_command_and_adapter(self) -> None:
        catalog = load_default_catalog()
        report = catalog.coverage_report()

        self.assertEqual(report["integrityStatus"], "PASS")
        self.assertEqual(report["validationLevel"], "STATICALLY_VALIDATED")
        self.assertFalse(report["authorizesRelease"])
        self.assertEqual(report["summary"]["phaseTotal"], len(REQUIRED_PHASES))
        # Derived from the manifest rather than hardcoded: a literal here has to
        # be edited every time a command is added, and an editor who reaches for
        # it out of habit can silently absorb a command that owns no capability.
        manifest = json.loads(
            (Path(__file__).resolve().parents[1] / "schemas" / "bridge-commands.v1.json")
            .read_text(encoding="utf-8")
        )
        self.assertEqual(report["summary"]["bridgeCommandTotal"], len(manifest["commands"]))
        self.assertEqual(report["summary"]["bridgeCommandCoverage"], 1.0)
        self.assertEqual(report["summary"]["adapterCoverage"], 1.0)
        self.assertEqual(report["bridgeCommands"]["unmapped"], [])
        self.assertEqual(report["bridgeCommands"]["unknown"], [])
        self.assertEqual(report["bridgeCommands"]["unsupported"], ["client.gui_click"])
        self.assertEqual(tuple(item["id"] for item in report["phases"]), REQUIRED_PHASES)

    def test_report_and_receipts_conform_to_their_versioned_schemas(self) -> None:
        catalog = load_default_catalog()
        report = catalog.coverage_report()
        receipt = catalog.select(capability_ids=["runtime.world.measure"])
        report_schema = _json(
            ROOT / "schemas/production-capability-coverage-report.v1.schema.json"
        )
        receipt_schema = _json(
            ROOT / "schemas/production-capability-selection-receipt.v1.schema.json"
        )

        self.assertEqual(validate_schema_instance(report, report_schema), [])
        self.assertEqual(validate_schema_instance(receipt, receipt_schema), [])

    def test_any_command_manifest_byte_drift_is_rejected(self) -> None:
        temporary, root, catalog, manifest = self._temporary_catalog()
        self.addCleanup(temporary.cleanup)
        self._materialize(root, catalog, manifest)
        manifest_path = root / "schemas/bridge-commands.v1.json"
        manifest_path.write_text(
            manifest_path.read_text(encoding="utf-8") + " ",
            encoding="utf-8",
        )

        with self.assertRaises(CapabilityCatalogError) as caught:
            ProductionCapabilityCatalog.load(root)
        self.assertIn("drifted", str(caught.exception))

    def test_new_registry_command_without_capability_owner_fails_closed(self) -> None:
        temporary, root, catalog, manifest = self._temporary_catalog()
        self.addCleanup(temporary.cleanup)
        manifest["commands"]["bridge.extra"] = copy.deepcopy(
            manifest["commands"]["bridge.ping"]
        )
        self._materialize(root, catalog, manifest)

        with self.assertRaises(CapabilityCatalogError) as caught:
            ProductionCapabilityCatalog.load(root)
        self.assertIn("unmapped registry commands: bridge.extra", str(caught.exception))

    def test_catalog_reference_to_nonexistent_command_fails_closed(self) -> None:
        temporary, root, catalog, manifest = self._temporary_catalog()
        self.addCleanup(temporary.cleanup)
        catalog["capabilities"][0]["bridgeCommands"].append(
            {"method": "bridge.does_not_exist", "required": True}
        )
        self._materialize(root, catalog, manifest)

        with self.assertRaises(CapabilityCatalogError) as caught:
            ProductionCapabilityCatalog.load(root)
        self.assertIn("nonexistent command", str(caught.exception))

    def test_unresolved_adapter_blocks_catalog_integrity(self) -> None:
        catalog = ProductionCapabilityCatalog.load(ROOT)
        real_resolver = __import__(
            "rqe.production_capabilities", fromlist=["resolve_python_adapter"]
        ).resolve_python_adapter

        def resolver(root: Path, symbol: str) -> AdapterResolution:
            if symbol == "rqe.project:Project":
                return AdapterResolution(symbol, False, None, None, "removed")
            return real_resolver(root, symbol)

        with patch("rqe.production_capabilities.resolve_python_adapter", side_effect=resolver):
            report = catalog.coverage_report()
            self.assertEqual(report["integrityStatus"], "BLOCKED")
            self.assertEqual(report["validationLevel"], "NOT_VALIDATED")
            with self.assertRaises(CapabilityCatalogError):
                catalog.assert_integrity()

    def test_available_selection_passes_but_never_authorizes_release(self) -> None:
        catalog = load_default_catalog()
        first = catalog.select(capability_ids=["runtime.world.measure"])
        second = catalog.select(capability_ids=["runtime.world.measure"])

        self.assertEqual(first["selectionStatus"], "PASS")
        self.assertEqual(first["coverage"]["readyCapabilityCoverage"], 1.0)
        self.assertFalse(first["authorizesRelease"])
        self.assertEqual(first["receiptValidationLevel"], "STATICALLY_VALIDATED")
        self.assertEqual(first["receiptId"], second["receiptId"])

    def test_gap_partial_and_excessive_validation_floor_block_selection(self) -> None:
        catalog = load_default_catalog()
        persistence = catalog.select(phases=["persistence"])
        studio = catalog.select(capability_ids=["studio.lifecycle.manage"])
        e2e_floor = catalog.select(
            capability_ids=["runtime.world.measure"],
            minimum_validation_level="E2E_VALIDATED",
        )

        for receipt in (persistence, studio, e2e_floor):
            self.assertEqual(receipt["selectionStatus"], "BLOCKED")
            self.assertLess(receipt["coverage"]["readyCapabilityCoverage"], 1.0)
            self.assertTrue(receipt["blockers"])

    def test_unknown_selector_does_not_fall_back_to_all_capabilities(self) -> None:
        catalog = load_default_catalog()
        with self.assertRaises(CapabilitySelectionError):
            catalog.select(phases=["imaginary"])
        with self.assertRaises(CapabilitySelectionError):
            catalog.select(capability_ids=["missing.capability"])

    def test_receipt_writer_rejects_any_release_authority_claim(self) -> None:
        catalog = load_default_catalog()
        receipt = catalog.select(capability_ids=["runtime.world.measure"])
        with tempfile.TemporaryDirectory() as directory:
            destination = Path(directory) / "selection.json"
            write_structured_receipt(destination, receipt)
            self.assertEqual(_json(destination)["receiptId"], receipt["receiptId"])
            forged = dict(receipt)
            forged["authorizesRelease"] = True
            with self.assertRaises(CapabilityCatalogError):
                write_structured_receipt(destination, forged)


if __name__ == "__main__":
    unittest.main()
