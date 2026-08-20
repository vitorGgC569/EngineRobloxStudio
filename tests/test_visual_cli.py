from __future__ import annotations

import argparse
import hashlib
import json
import tempfile
import unittest
from pathlib import Path

from rqe.openai_vision import OpenAIResponsesVisionProvider
from rqe.schema_validation import validate_schema_instance
from rqe.visual_cli import VisualCliError, run_visual_command


REPOSITORY_ROOT = Path(__file__).resolve().parents[1]
SPEC_PATH = REPOSITORY_ROOT / "contracts" / "visual" / "miners-ridge.visual-quality.v1.json"
VIEWPOINT = "spawn"
SECRET = "sk-cli-secret-must-not-be-written"


def _sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def _write_capture(root: Path) -> dict:
    png = root / "01-spawn.png"
    png.write_bytes(b"\x89PNG\r\n\x1a\nvisual-cli-fixture")
    data = png.read_bytes()
    spec_hash = _sha256(SPEC_PATH)
    manifest = {
        "schemaVersion": 1,
        "runId": "run-visual-cli",
        "buildHash": "a" * 64,
        "placeHash": "b" * 64,
        "specHash": spec_hash,
        "sessionId": "sess_visual_cli",
        "place": "VisualCli.rbxlx",
        "captureType": "studio-window",
        "requiredViewpoints": [VIEWPOINT],
        "capturedRequiredViewpoints": [VIEWPOINT],
        "missingRequiredViewpoints": [],
        "coverage": 1.0,
        "shots": [
            {
                "id": VIEWPOINT,
                "file": png.name,
                "bytes": len(data),
                "sha256": hashlib.sha256(data).hexdigest(),
                "trustworthy": True,
                "integrityIssues": [],
                "runId": "run-visual-cli",
                "buildHash": "a" * 64,
                "placeHash": "b" * 64,
                "specHash": spec_hash,
                "target": "game.Workspace.Map.Spawn",
                "camera": {"before": {"position": [1, 2, 3]}},
                "width": 40,
                "height": 24,
            }
        ],
        "failures": [],
        "occludedShots": 0,
        "trustworthy": True,
    }
    (root / "manifest.json").write_text(
        json.dumps(manifest, indent=2) + "\n", encoding="utf-8"
    )
    return manifest


class DynamicProvider:
    name = "fake-cli-vision"

    def __init__(self, *, model: str, **_kwargs) -> None:
        self.model = model
        self.calls = []

    def review(self, request):
        self.calls.append(request)
        return {
            "assessments": [
                {
                    "viewpoint": viewpoint,
                    "rubric": [
                        {
                            "criterion": criterion,
                            "grade": 4,
                            "rationale": f"Visible {criterion} is coherent.",
                            "evidence": {"shotIds": [viewpoint]},
                        }
                        for criterion in criteria
                    ],
                }
                for viewpoint, criteria in request.rubric_by_viewpoint.items()
            ],
            "findings": [],
        }


class RecordingFactory:
    def __init__(self) -> None:
        self.providers: list[DynamicProvider] = []

    def __call__(self, **kwargs):
        provider = DynamicProvider(**kwargs)
        self.providers.append(provider)
        return provider


def _args(root: Path, **overrides) -> argparse.Namespace:
    values = {
        "command": "visual",
        "visual_command": "review",
        "capture_manifest": str(root / "manifest.json"),
        "spec": str(SPEC_PATH),
        "rubric": None,
        "model": "explicit-cli-model",
        "prompt_file": None,
        "image_detail": "high",
        "timeout_seconds": 30.0,
        "output": str(root / "review-openai.json"),
    }
    values.update(overrides)
    return argparse.Namespace(**values)


class VisualCliTests(unittest.TestCase):
    def test_cli_derives_hash_bound_rubric_and_writes_only_explicit_output(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            _write_capture(root)
            factory = RecordingFactory()

            exit_code, payload = run_visual_command(
                _args(root), provider_factory=factory
            )

            persisted = json.loads((root / "review-openai.json").read_text(encoding="utf-8"))
            self.assertEqual(exit_code, 0)
            self.assertEqual(payload, persisted)
            self.assertEqual(payload["validationLevel"], "VISUALLY_VALIDATED")
            self.assertIs(payload["authorizesRelease"], False)
            self.assertEqual(payload["reviewedViewpoints"], [VIEWPOINT])
            self.assertEqual(
                list(factory.providers[0].calls[0].rubric_by_viewpoint[VIEWPOINT]),
                ["composition", "hierarchy", "legibility", "materiality", "polish"],
            )
            self.assertEqual(
                sorted(path.name for path in root.iterdir()),
                ["01-spawn.png", "manifest.json", "review-openai.json"],
            )

    def test_existing_output_is_refused_before_a_paid_provider_call(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            _write_capture(root)
            output = root / "review-openai.json"
            output.write_text('{"owned":"before"}\n', encoding="utf-8")
            factory = RecordingFactory()

            with self.assertRaisesRegex(VisualCliError, "already exists"):
                run_visual_command(_args(root), provider_factory=factory)

            self.assertEqual(factory.providers, [])
            self.assertEqual(
                json.loads(output.read_text(encoding="utf-8")), {"owned": "before"}
            )

    def test_explicit_rubric_cannot_diverge_from_hash_bound_spec(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            _write_capture(root)
            rubric = root / "rubric.json"
            rubric.write_text(
                json.dumps({"rubricByViewpoint": {VIEWPOINT: ["finish"]}}),
                encoding="utf-8",
            )
            factory = RecordingFactory()

            with self.assertRaisesRegex(VisualCliError, "differs"):
                run_visual_command(
                    _args(root, rubric=str(rubric)), provider_factory=factory
                )

            self.assertEqual(factory.providers, [])

    def test_missing_key_writes_a_not_validated_blocked_receipt_without_secret(self) -> None:
        class NoNetwork:
            def post_json(self, *_args, **_kwargs):
                raise AssertionError("missing credentials must prevent HTTP")

        def factory(**kwargs):
            return OpenAIResponsesVisionProvider(
                **kwargs,
                transport=NoNetwork(),
                environ={"RQE_OPENAI_API_KEY": SECRET},
            )

        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            _write_capture(root)

            exit_code, payload = run_visual_command(
                _args(root), provider_factory=factory
            )

            persisted_text = (root / "review-openai.json").read_text(encoding="utf-8")
            self.assertEqual(exit_code, 1)
            self.assertEqual(payload["status"], "BLOCKED")
            self.assertEqual(payload["validationLevel"], "NOT_VALIDATED")
            self.assertEqual(payload["reasonCode"], "OPENAI_API_KEY_MISSING")
            self.assertIs(payload["authorizesRelease"], False)
            self.assertNotIn(SECRET, persisted_text)
            schema = json.loads(
                (REPOSITORY_ROOT / "schemas" / "visual-review-attempt.v1.schema.json").read_text(
                    encoding="utf-8"
                )
            )
            self.assertEqual(validate_schema_instance(payload, schema), [])

    def test_spec_hash_mismatch_blocks_before_provider(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            manifest = _write_capture(root)
            manifest["specHash"] = "f" * 64
            (root / "manifest.json").write_text(
                json.dumps(manifest), encoding="utf-8"
            )
            factory = RecordingFactory()
            with self.assertRaisesRegex(VisualCliError, "spec file hash differs"):
                run_visual_command(_args(root), provider_factory=factory)
            self.assertEqual(factory.providers, [])


if __name__ == "__main__":
    unittest.main()
