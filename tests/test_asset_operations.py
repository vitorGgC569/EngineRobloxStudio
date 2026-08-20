from __future__ import annotations

import json
import tempfile
import unittest
from pathlib import Path

from PIL import Image

from rqe.assets.models import AssetKind, AssetState, PipelineOutcome, SearchQuery
from rqe.assets.operations import AssetOperations
from rqe.assets.providers.roblox import RobloxOpenCloudConfig, RobloxOpenCloudProvider
from rqe.assets.publication import PublicationPackage
from rqe.assets.testing import FakeHttpTransport


def _request(root: Path, *, verified: bool = True) -> dict:
    image = root / "generated-icon.png"
    Image.new("RGBA", (64, 64), (30, 80, 160, 255)).save(image)
    return {
        "schemaVersion": 1,
        "requestId": "asset-request-1",
        "provider": "roblox-open-cloud",
        "asset": {
            "id": "presentation.primary-icon",
            "kind": "icon",
            "displayName": "Primary icon",
            "description": "Original production icon",
            "path": image.name,
            "source": {
                "provider": "generator",
                "uri": "generator://campaign/task/icon",
                "retrievedAt": "2026-08-11T12:00:00Z",
                "tool": "test-generator",
                "prompt": "generic icon",
            },
            "license": {
                "name": "Original work",
                "termsUrl": "https://example.test/rights/original",
                "usageScope": "commercial Roblox experience",
                "verified": verified,
                "commercialUse": True,
                "evidence": "rights/approval-1",
            },
            "requirement": "production-required",
            "previews": [
                {
                    "uri": "https://preview.test/icon.png",
                    "mediaType": "image/png",
                    "label": "generated preview",
                }
            ],
            "metadata": {},
        },
        "creator": {"groupId": "42"},
        "integrations": [
            {
                "target": "presentation.primaryIcon",
                "property": "Image",
                "expectedClass": "ImageLabel",
            }
        ],
    }


class AssetOperationsTests(unittest.TestCase):
    def test_prepare_is_content_addressed_and_round_trips_package(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            request_path = root / "request.json"
            request_path.write_text(json.dumps(_request(root)), encoding="utf-8")
            provider = RobloxOpenCloudProvider(RobloxOpenCloudConfig())
            operations = AssetOperations(
                provider,
                root / "artifacts",
                clock=lambda: "2026-08-11T12:00:00Z",
            )
            prepared, paths = operations.prepare_file(request_path)
            self.assertEqual(PipelineOutcome.PROGRESSED, prepared.outcome)
            self.assertIn("package", paths)
            restored = PublicationPackage.from_dict(
                json.loads(paths["package"].read_text(encoding="utf-8"))
            )
            self.assertEqual(prepared.package, restored)
            self.assertFalse((root / "artifacts" / "latest.json").exists())

            repeated, repeated_paths = operations.prepare_file(request_path)
            self.assertEqual(prepared.package.package_id, repeated.package.package_id)
            self.assertEqual(paths, repeated_paths)

    def test_unknown_rights_block_package_creation(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            request_path = root / "request.json"
            request_path.write_text(
                json.dumps(_request(root, verified=False)), encoding="utf-8"
            )
            operations = AssetOperations(
                RobloxOpenCloudProvider(RobloxOpenCloudConfig()),
                root / "artifacts",
            )
            prepared, paths = operations.prepare_file(request_path)
            self.assertEqual(PipelineOutcome.BLOCKED, prepared.outcome)
            self.assertIsNone(prepared.package)
            self.assertNotIn("package", paths)
            self.assertTrue(
                any(blocker.code == "rights.verified" for blocker in prepared.blockers)
            )

    def test_upload_requires_exact_package_confirmation_before_http(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            request_path = root / "request.json"
            request_path.write_text(json.dumps(_request(root)), encoding="utf-8")
            transport = FakeHttpTransport()
            provider = RobloxOpenCloudProvider(
                RobloxOpenCloudConfig(api_key="test-key"), transport=transport
            )
            operations = AssetOperations(provider, root / "artifacts")
            prepared, paths = operations.prepare_file(request_path)

            blocked = operations.publish(paths["package"], confirmation=None)
            self.assertEqual(PipelineOutcome.BLOCKED, blocked.outcome)
            self.assertEqual([], transport.requests)

            transport.queue_json(200, {"path": "operations/upload-1"})
            dispatched = operations.publish(
                paths["package"], confirmation=prepared.package.package_id
            )
            self.assertEqual(PipelineOutcome.PROGRESSED, dispatched.outcome)
            self.assertEqual(AssetState.UPLOADING, dispatched.asset.state)
            self.assertEqual(1, len(transport.requests))

    def test_refresh_uses_staged_ledger_after_source_file_is_removed(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            request = _request(root)
            request_path = root / "request.json"
            request_path.write_text(json.dumps(request), encoding="utf-8")
            transport = FakeHttpTransport()
            transport.queue_json(200, {"path": "operations/upload-2"})
            provider = RobloxOpenCloudProvider(
                RobloxOpenCloudConfig(api_key="test-key"), transport=transport
            )
            operations = AssetOperations(provider, root / "artifacts")
            prepared, paths = operations.prepare_file(request_path)
            operations.publish(
                paths["package"], confirmation=prepared.package.package_id
            )
            (root / "generated-icon.png").unlink()
            transport.queue_json(
                200,
                {
                    "done": True,
                    "response": {
                        "assetId": "9002",
                        "moderationResult": {
                            "moderationState": "MODERATION_STATE_APPROVED"
                        },
                    },
                },
            )
            refreshed = operations.refresh(paths["package"])
            self.assertEqual(AssetState.APPROVED, refreshed.asset.state)
            self.assertEqual("9002", refreshed.asset.remote_asset_id)

    def test_search_receipt_preserves_name_description_and_preview(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            transport = FakeHttpTransport()
            transport.queue_json(
                200,
                {
                    "creatorStoreAssets": [
                        {
                            "asset": {
                                "id": "55",
                                "assetType": "Audio",
                                "displayName": "Factory Hum",
                                "description": "Loopable ambience",
                            },
                            "thumbnailUrl": "https://cdn.test/55.png",
                        }
                    ]
                },
            )
            operations = AssetOperations(
                RobloxOpenCloudProvider(
                    RobloxOpenCloudConfig(), transport=transport,
                    clock=lambda: "2026-08-11T12:00:00Z",
                ),
                root / "artifacts",
                clock=lambda: "2026-08-11T12:00:01Z",
            )
            receipt = operations.search(
                SearchQuery("factory", (AssetKind.AUDIO,))
            )
            path = operations.record_receipt("discovery", receipt)
            asset = receipt["result"]["assets"][0]
            self.assertEqual("Factory Hum", asset["displayName"])
            self.assertEqual("Loopable ambience", asset["description"])
            self.assertEqual("https://cdn.test/55.png", asset["previews"][0]["uri"])
            self.assertTrue(path.is_file())

    def test_tampered_package_identity_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            request_path = root / "request.json"
            request_path.write_text(json.dumps(_request(root)), encoding="utf-8")
            operations = AssetOperations(
                RobloxOpenCloudProvider(RobloxOpenCloudConfig()),
                root / "artifacts",
            )
            _, paths = operations.prepare_file(request_path)
            raw = json.loads(paths["package"].read_text(encoding="utf-8"))
            raw["asset"]["displayName"] = "tampered"
            with self.assertRaisesRegex(ValueError, "identity hash"):
                PublicationPackage.from_dict(raw)


if __name__ == "__main__":
    unittest.main()
