from __future__ import annotations

import hashlib
import json
import tempfile
import unittest
from pathlib import Path

from PIL import Image

from rqe.visual_review import ReviewRequest, VisualReviewError, review_captures


RUN_ID = "run-visual"
BUILD_HASH = "c" * 64
PLACE_HASH = "e" * 64
SPEC_HASH = "d" * 64
VIEWPOINT = "world-overview"
RUBRIC = {VIEWPOINT: ["composition", "finish"]}


def _write_capture(root: Path) -> dict:
    png = root / "01-world-overview.png"
    Image.new("RGB", (40, 24), (12, 64, 96)).save(png, "PNG")
    data = png.read_bytes()
    manifest = {
        "schemaVersion": 1,
        "runId": RUN_ID,
        "buildHash": BUILD_HASH,
        "placeHash": PLACE_HASH,
        "specHash": SPEC_HASH,
        "sessionId": "sess_visual",
        "place": "VisualBuild.rbxlx",
        "captureType": "studio-window",
        "requiredViewpoints": [VIEWPOINT],
        "capturedRequiredViewpoints": [VIEWPOINT],
        "missingRequiredViewpoints": [],
        "coverage": 1.0,
        "shots": [{
            "id": VIEWPOINT,
            "file": png.name,
            "bytes": len(data),
            "sha256": hashlib.sha256(data).hexdigest(),
            "trustworthy": True,
            "integrityIssues": [],
            "runId": RUN_ID,
            "buildHash": BUILD_HASH,
            "placeHash": PLACE_HASH,
            "specHash": SPEC_HASH,
            "target": "game.Workspace.Map",
            "camera": {"before": {"position": [1, 2, 3]}},
            "width": 40,
            "height": 24,
        }],
        "failures": [],
        "occludedShots": 0,
        "trustworthy": True,
    }
    (root / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
    return manifest


def _clean_response() -> dict:
    return {
        "assessments": [{
            "viewpoint": VIEWPOINT,
            "rubric": [
                {
                    "criterion": "composition",
                    "grade": 5,
                    "rationale": "The route has a clear focal hierarchy.",
                    "evidence": {"shotIds": [VIEWPOINT]},
                },
                {
                    "criterion": "finish",
                    "grade": 5,
                    "rationale": "Visible surfaces and transitions are consistently finished.",
                    "evidence": {"shotIds": [VIEWPOINT]},
                },
            ],
        }],
        "findings": [],
    }


class FakeVisionProvider:
    name = "fake-vision"
    model = "fake-v1"

    def __init__(self, response: dict | None = None, error: Exception | None = None) -> None:
        self.response = response if response is not None else _clean_response()
        self.error = error
        self.calls: list[ReviewRequest] = []

    def review(self, request: ReviewRequest):
        self.calls.append(request)
        if self.error:
            raise self.error
        return self.response


class VisualReviewTests(unittest.TestCase):
    def test_untrustworthy_images_never_reach_the_provider(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            manifest = _write_capture(root)
            manifest["trustworthy"] = False
            provider = FakeVisionProvider()
            with self.assertRaisesRegex(VisualReviewError, "untrustworthy"):
                review_captures(manifest, root, RUBRIC, provider)
        self.assertEqual(provider.calls, [])

    def test_fake_provider_drives_a_hash_bound_complete_review(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            manifest = _write_capture(root)
            output = root / "visual-review"
            provider = FakeVisionProvider()
            review = review_captures(manifest, root, RUBRIC, provider, output_directory=output)
            request_artifact = json.loads((output / "request.json").read_text(encoding="utf-8"))
            review_artifact = json.loads((output / "review.json").read_text(encoding="utf-8"))
        self.assertEqual(len(provider.calls), 1)
        self.assertFalse(provider.calls[0].response_schema["additionalProperties"])
        self.assertEqual(review.score, 100.0)
        self.assertEqual(review.provider, "fake-vision")
        self.assertEqual(review.model, "fake-v1")
        self.assertEqual(len(review.model_hash), 64)
        self.assertEqual(review_artifact["validationLevel"], "VISUALLY_VALIDATED")
        self.assertEqual(review_artifact["captureManifestSha256"], request_artifact["captureManifestSha256"])
        self.assertEqual(len(review.prompt_hash), 64)
        self.assertNotIn("data", request_artifact["images"][0])

    def test_tampered_png_is_rejected_before_provider_call(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            manifest = _write_capture(root)
            (root / manifest["shots"][0]["file"]).write_bytes(b"tampered")
            provider = FakeVisionProvider()
            with self.assertRaisesRegex(VisualReviewError, "hash differs"):
                review_captures(manifest, root, RUBRIC, provider)
        self.assertEqual(provider.calls, [])

    def test_provider_cannot_inject_an_overall_score(self) -> None:
        response = _clean_response()
        response["score"] = 100
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            manifest = _write_capture(root)
            with self.assertRaisesRegex(VisualReviewError, "provider scores are forbidden"):
                review_captures(manifest, root, RUBRIC, FakeVisionProvider(response))

    def test_review_rejects_unknown_shot_citations(self) -> None:
        response = _clean_response()
        response["assessments"][0]["rubric"][0]["evidence"] = {"shotIds": ["invented-shot"]}
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            manifest = _write_capture(root)
            with self.assertRaisesRegex(VisualReviewError, "unknown shots"):
                review_captures(manifest, root, RUBRIC, FakeVisionProvider(response))

    def test_missing_rubric_dimension_makes_review_inconclusive(self) -> None:
        response = _clean_response()
        response["assessments"][0]["rubric"] = response["assessments"][0]["rubric"][:1]
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            manifest = _write_capture(root)
            with self.assertRaisesRegex(VisualReviewError, "rubric coverage"):
                review_captures(manifest, root, RUBRIC, FakeVisionProvider(response))

    def test_findings_are_advisory_and_do_not_change_the_rubric_score(self) -> None:
        response = _clean_response()
        response["assessments"][0]["rubric"][0]["grade"] = 4
        response["findings"] = [{
            "severity": "major",
            "category": "density",
            "location": "lower-right quadrant",
            "finding": "The playable route appears visually empty.",
            "suggestedAction": "Add two medium prop clusters framing the path.",
            "evidence": {"shotIds": [VIEWPOINT]},
        }]
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            manifest = _write_capture(root)
            review = review_captures(manifest, root, RUBRIC, FakeVisionProvider(response))
        # Severity is model-authored and uncalibrated. The finding remains in
        # the repair artifact, while blocking comes from independent rules.
        self.assertEqual(review.rubric_average, 87.5)
        self.assertEqual(review.finding_penalty, 0.0)
        self.assertEqual(review.score, 87.5)

    def test_provider_failure_is_fail_closed(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            manifest = _write_capture(root)
            with self.assertRaisesRegex(VisualReviewError, "vision provider failed"):
                review_captures(manifest, root, RUBRIC, FakeVisionProvider(error=RuntimeError("offline")))

    def test_rubric_must_exactly_match_required_viewpoints(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            manifest = _write_capture(root)
            provider = FakeVisionProvider()
            with self.assertRaisesRegex(VisualReviewError, "exactly match"):
                review_captures(manifest, root, {"other": ["finish"]}, provider)
        self.assertEqual(provider.calls, [])


if __name__ == "__main__":
    unittest.main()
