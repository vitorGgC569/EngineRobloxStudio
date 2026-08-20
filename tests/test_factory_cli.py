from __future__ import annotations

import json
import tempfile
import unittest
from pathlib import Path

from rqe.cli import build_parser, main
from rqe.factory_cli import FactoryCliError, run_factory_command
from rqe.schema_validation import validate_schema_instance
from tests.test_production_blueprint import blueprint, project_definition


ROOT = Path(__file__).resolve().parents[1]


class FactoryCliTests(unittest.TestCase):
    def _blueprint_file(self, directory: str, *product_ids: str) -> Path:
        path = Path(directory) / "portfolio.blueprint.json"
        path.write_text(
            json.dumps(blueprint(*(project_definition(item) for item in product_ids))),
            encoding="utf-8",
        )
        return path

    def test_parser_exposes_capability_and_factory_surfaces(self) -> None:
        parser = build_parser()

        report = parser.parse_args(["capabilities", "report"])
        selection = parser.parse_args(
            [
                "capabilities",
                "select",
                "--phase",
                "runtime",
                "--capability",
                "capture.camera.control",
            ]
        )
        inspection = parser.parse_args(["factory", "inspect", "portfolio.json"])
        compilation = parser.parse_args(["factory", "compile", "portfolio.json"])

        self.assertEqual(report.capabilities_command, "report")
        self.assertEqual(selection.phase, ["runtime"])
        self.assertEqual(selection.capability, ["capture.camera.control"])
        self.assertEqual(inspection.factory_command, "inspect")
        self.assertEqual(compilation.factory_command, "compile")

    def test_capability_report_preserves_integrity_readiness_separation(self) -> None:
        args = build_parser().parse_args(["capabilities", "report", str(ROOT)])

        exit_code, payload = run_factory_command(args)

        self.assertEqual(exit_code, 0)
        self.assertEqual(payload["integrityStatus"], "PASS")
        self.assertEqual(payload["productionReadiness"], "INCOMPLETE")
        self.assertFalse(payload["authorizesRelease"])
        self.assertEqual(payload["schemaVersion"], 1)

    def test_capability_selection_is_fail_closed_and_writes_only_explicitly(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            destination = Path(directory) / "runtime-selection.json"
            passing = build_parser().parse_args(
                [
                    "capabilities",
                    "select",
                    str(ROOT),
                    "--capability",
                    "runtime.world.measure",
                    "--output",
                    str(destination),
                ]
            )
            blocked = build_parser().parse_args(
                ["capabilities", "select", str(ROOT), "--phase", "persistence"]
            )

            passing_code, passing_payload = run_factory_command(passing)
            blocked_code, blocked_payload = run_factory_command(blocked)

            self.assertEqual(passing_code, 0)
            self.assertEqual(passing_payload["selectionStatus"], "PASS")
            self.assertTrue(destination.is_file())
            self.assertEqual(json.loads(destination.read_text(encoding="utf-8")), passing_payload)
            self.assertEqual(blocked_code, 1)
            self.assertEqual(blocked_payload["selectionStatus"], "BLOCKED")
            self.assertTrue(blocked_payload["blockers"])
            self.assertFalse(blocked_payload["authorizesRelease"])

    def test_inspection_is_deterministic_versioned_and_non_authoritative(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            source = self._blueprint_file(directory, "alpha-game", "beta-game")
            args = build_parser().parse_args(["factory", "inspect", str(source)])

            first_code, first = run_factory_command(args)
            second_code, second = run_factory_command(args)

        self.assertEqual(first_code, second_code, 0)
        self.assertEqual(first, second)
        self.assertEqual(first["summary"]["projectTotal"], 2)
        self.assertEqual(first["summary"]["subsystemTotal"], 4)
        self.assertFalse(first["authorizesRelease"])
        self.assertEqual(first["validationLevel"], "STATICALLY_VALIDATED")
        schema = json.loads(
            (ROOT / "schemas/production-blueprint-inspection.v1.schema.json").read_text(
                encoding="utf-8"
            )
        )
        self.assertEqual(validate_schema_instance(first, schema), [])

    def test_compile_writes_the_exact_deterministic_plan_without_executing_it(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            source = self._blueprint_file(directory, "alpha-game")
            destination = Path(directory) / "plans" / "alpha-plan.json"
            args = build_parser().parse_args(
                [
                    "factory",
                    "compile",
                    str(source),
                    "--output",
                    str(destination),
                ]
            )

            exit_code, payload = run_factory_command(args)

            self.assertEqual(exit_code, 0)
            self.assertTrue(destination.is_file())
            self.assertEqual(json.loads(destination.read_text(encoding="utf-8")), payload)
            self.assertEqual(payload["schemaVersion"], 1)
            self.assertEqual(payload["validationLevel"], "STATICALLY_VALIDATED")
            self.assertNotIn("releaseAllowed", payload)
            self.assertNotIn("authorizesRelease", payload)
            self.assertTrue(payload["planSha256"])

    def test_latest_destination_and_unknown_selector_are_explicit_errors(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            source = self._blueprint_file(directory, "alpha-game")
            latest = build_parser().parse_args(
                [
                    "factory",
                    "inspect",
                    str(source),
                    "--output",
                    str(Path(directory) / "latest.json"),
                ]
            )
            with self.assertRaisesRegex(FactoryCliError, "latest artifacts are forbidden"):
                run_factory_command(latest)

        self.assertEqual(
            main(
                [
                    "capabilities",
                    "select",
                    str(ROOT),
                    "--capability",
                    "does.not.exist",
                ]
            ),
            2,
        )


if __name__ == "__main__":
    unittest.main()
