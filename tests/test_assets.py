from __future__ import annotations

import json
import tempfile
import unittest
import wave
from dataclasses import replace
from pathlib import Path

from PIL import Image

from rqe.assets import (
    AssetKind,
    AssetLicense,
    AssetManifestValidator,
    AssetPreview,
    AssetProvenance,
    AssetRecord,
    AssetRequirement,
    AssetState,
    CreatorTarget,
    IntegrationTarget,
    LocalAssetValidator,
    LocalDraftRequest,
    PublicationCoordinator,
    PublicationLedger,
    PublicationPackage,
    build_integration_bundle,
    create_local_draft,
)
from rqe.assets.catalog import AssetCatalog
from rqe.assets.models import PipelineOutcome, SearchQuery
from rqe.assets.models import state_from_moderation
from rqe.assets.providers.base import PublishRequest
from rqe.assets.providers.local import LocalCatalogProvider
from rqe.assets.providers.roblox import RobloxOpenCloudConfig, RobloxOpenCloudProvider
from rqe.assets.testing import FakeHttpTransport


def _license(*, verified: bool = True) -> AssetLicense:
    return AssetLicense(
        name="Original work",
        terms_url="https://example.test/license/asset-1",
        usage_scope="commercial Roblox experience",
        verified=verified,
        commercial_use=True,
        evidence="rights-review/TICKET-1" if verified else None,
    )


def _png(path: Path, width: int = 32, height: int = 32) -> None:
    Image.new("RGBA", (width, height), (20, 40, 80, 255)).save(path)


def _glb(path: Path) -> None:
    payload = b'{"asset":{"version":"2.0"}}'
    payload += b" " * ((4 - len(payload) % 4) % 4)
    total = 12 + 8 + len(payload)
    path.write_bytes(
        b"glTF"
        + (2).to_bytes(4, "little")
        + total.to_bytes(4, "little")
        + len(payload).to_bytes(4, "little")
        + b"JSON"
        + payload
    )


def _draft(path: Path, kind: AssetKind = AssetKind.ICON, **metadata: object) -> AssetRecord:
    return create_local_draft(
        LocalDraftRequest(
            logical_id=f"asset-{kind.value}",
            kind=kind,
            display_name=f"Production {kind.value}",
            description=f"Measured {kind.value} payload",
            path=path,
            source_uri="generator://run/asset-1",
            source_provider="local-generator",
            license=_license(),
            requirement=AssetRequirement.PRODUCTION_REQUIRED,
            previews=(AssetPreview("file:///preview.png", "image/png"),),
            tool="test-generator",
            prompt="generic production asset",
            retrieved_at="2026-08-11T12:00:00Z",
            metadata=dict(metadata),
        )
    )


class LocalValidationTests(unittest.TestCase):
    def test_moderation_comparison_does_not_accept_not_approved(self) -> None:
        self.assertEqual(
            AssetState.PUBLISHED, state_from_moderation("MODERATION_STATE_NOT_APPROVED")
        )

    def test_validates_all_supported_logical_kinds(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            icon = root / "icon.png"
            _png(icon)
            mesh = root / "prop.glb"
            _glb(mesh)
            animation = root / "idle.rbxmx"
            animation.write_text("<roblox version=\"4\"></roblox>", encoding="utf-8")
            audio = root / "sound.wav"
            with wave.open(str(audio), "wb") as stream:
                stream.setnchannels(1)
                stream.setsampwidth(2)
                stream.setframerate(8_000)
                stream.writeframes(b"\0\0" * 800)

            cases = (
                _draft(icon, AssetKind.ICON),
                _draft(mesh, AssetKind.MESH),
                _draft(animation, AssetKind.ANIMATION, studioAuthored=True),
                _draft(audio, AssetKind.AUDIO),
            )
            validator = LocalAssetValidator()
            for case in cases:
                with self.subTest(kind=case.kind):
                    report = validator.validate(case)
                    self.assertTrue(report.ok, report.checks)
                    self.assertEqual(AssetState.VALIDATED, report.asset.state)
                    self.assertEqual(64, len(report.asset.provenance.content_sha256 or ""))
                    self.assertIsNotNone(report.asset.content_type)

    def test_unknown_rights_are_blocked_not_passed(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            icon = Path(directory) / "icon.png"
            _png(icon)
            draft = replace(_draft(icon), license=_license(verified=False))
            report = LocalAssetValidator().validate(draft)
            self.assertTrue(report.blocked)
            self.assertFalse(report.ok)
            self.assertEqual(AssetState.DRAFT, report.asset.state)

    def test_unsupported_payload_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "mesh.glb"
            path.write_bytes(b"not-a-glb")
            report = LocalAssetValidator().validate(_draft(path, AssetKind.MESH))
            self.assertFalse(report.ok)
            self.assertEqual(AssetState.REJECTED, report.asset.state)


class ProviderTests(unittest.TestCase):
    def _validated_icon(self, root: Path) -> AssetRecord:
        path = root / "icon.png"
        _png(path)
        report = LocalAssetValidator().validate(_draft(path))
        self.assertTrue(report.ok)
        return report.asset

    def test_local_catalog_never_claims_publication(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            asset = self._validated_icon(Path(directory))
            provider = LocalCatalogProvider(AssetCatalog("local", {asset.logical_id: asset}))
            found = provider.search(SearchQuery("production", (AssetKind.ICON,)))
            self.assertEqual((asset,), found.assets)
            result = provider.publish(PublishRequest(asset, CreatorTarget(user_id="1"), "key"))
            self.assertEqual(PipelineOutcome.UNAVAILABLE, result.outcome)
            self.assertEqual(AssetState.VALIDATED, result.asset.state)
            restored = AssetCatalog.from_dict(provider.catalog.to_dict())
            self.assertEqual(asset, restored.get(asset.logical_id))

    def test_missing_credentials_are_blocked_without_http(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            asset = self._validated_icon(Path(directory))
            transport = FakeHttpTransport()
            provider = RobloxOpenCloudProvider(
                RobloxOpenCloudConfig(), transport=transport
            )
            result = provider.publish(
                PublishRequest(asset, CreatorTarget(user_id="123"), "abc")
            )
            self.assertEqual(PipelineOutcome.BLOCKED, result.outcome)
            self.assertEqual([], transport.requests)
            self.assertEqual(AssetState.VALIDATED, result.asset.state)
            self.assertEqual(
                "BLOCKED", provider.capabilities().get("upload").availability.value
            )

    def test_fake_http_upload_pending_then_approved(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            asset = self._validated_icon(Path(directory))
            transport = FakeHttpTransport()
            transport.queue_json(200, {"path": "operations/upload-1"})
            transport.queue_json(200, {"path": "operations/upload-1", "done": False})
            transport.queue_json(
                200,
                {
                    "path": "operations/upload-1",
                    "done": True,
                    "response": {
                        "assetId": "9001",
                        "moderationResult": {
                            "moderationState": "MODERATION_STATE_APPROVED"
                        },
                    },
                },
            )
            provider = RobloxOpenCloudProvider(
                RobloxOpenCloudConfig(api_key="secret-test-key"),
                transport=transport,
            )
            uploaded = provider.publish(
                PublishRequest(asset, CreatorTarget(group_id="42"), "package-key")
            )
            self.assertEqual(PipelineOutcome.PROGRESSED, uploaded.outcome)
            self.assertEqual(AssetState.UPLOADING, uploaded.asset.state)
            request = transport.requests[0]
            self.assertIn("x-api-key", request.headers)
            self.assertIn(b'"groupId":"42"', request.body or b"")
            self.assertIn(b'filename="icon.png"', request.body or b"")

            pending = provider.refresh(uploaded.asset)
            self.assertEqual(PipelineOutcome.BLOCKED, pending.outcome)
            self.assertEqual(AssetState.UPLOADING, pending.asset.state)
            approved = provider.refresh(pending.asset)
            self.assertEqual(PipelineOutcome.PROGRESSED, approved.outcome)
            self.assertEqual(AssetState.APPROVED, approved.asset.state)
            self.assertEqual("9001", approved.asset.remote_asset_id)

    def test_http_403_is_a_blocker_not_a_success(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            asset = self._validated_icon(Path(directory))
            transport = FakeHttpTransport()
            transport.queue_json(403, {"message": "not authorized"})
            provider = RobloxOpenCloudProvider(
                RobloxOpenCloudConfig(api_key="wrong-scope"), transport=transport
            )
            result = provider.publish(
                PublishRequest(asset, CreatorTarget(user_id="7"), "package-key")
            )
            self.assertEqual(PipelineOutcome.BLOCKED, result.outcome)
            self.assertEqual(AssetState.VALIDATED, result.asset.state)
            self.assertEqual("roblox_authorization_blocked", result.blockers[0].code)

    def test_completed_upload_without_approval_remains_blocked(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            asset = self._validated_icon(Path(directory))
            transport = FakeHttpTransport()
            transport.queue_json(200, {"path": "operations/review"})
            transport.queue_json(
                200,
                {
                    "done": True,
                    "response": {
                        "assetId": "700",
                        "moderationResult": {
                            "moderationState": "MODERATION_STATE_REVIEWING"
                        },
                    },
                },
            )
            provider = RobloxOpenCloudProvider(
                RobloxOpenCloudConfig(api_key="test"), transport=transport
            )
            uploaded = provider.publish(
                PublishRequest(asset, CreatorTarget(user_id="1"), "package-key")
            )
            reviewed = provider.refresh(uploaded.asset)
            self.assertEqual(PipelineOutcome.BLOCKED, reviewed.outcome)
            self.assertEqual(AssetState.PUBLISHED, reviewed.asset.state)
            self.assertEqual("moderation_not_approved", reviewed.blockers[0].code)

    def test_thumbnail_failure_is_explicit(self) -> None:
        transport = FakeHttpTransport()
        transport.queue_json(503, {"message": "unavailable"})
        provider = RobloxOpenCloudProvider(
            RobloxOpenCloudConfig(), transport=transport
        )
        asset = AssetRecord(
            logical_id="roblox:7",
            kind=AssetKind.MESH,
            display_name="Asset",
            description="Existing asset",
            state=AssetState.PUBLISHED,
            provider="roblox-open-cloud",
            remote_asset_id="7",
        )
        result = provider.previews(asset)
        self.assertEqual(PipelineOutcome.BLOCKED, result.outcome)
        self.assertEqual("roblox_service_unavailable", result.blockers[0].code)

    def test_search_preserves_preview_and_unverified_acquisition(self) -> None:
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
                        "creator": {"id": "9", "name": "Creator"},
                        "thumbnailUrl": "https://cdn.test/55.png",
                    }
                ],
                "nextPageToken": "page-2",
            },
        )
        provider = RobloxOpenCloudProvider(
            RobloxOpenCloudConfig(),
            transport=transport,
            clock=lambda: "2026-08-11T12:00:00Z",
        )
        result = provider.search(SearchQuery("factory", (AssetKind.AUDIO,)))
        self.assertEqual(PipelineOutcome.PROGRESSED, result.outcome)
        self.assertEqual("page-2", result.next_page_token)
        self.assertEqual(1, len(result.assets))
        asset = result.assets[0]
        self.assertEqual(AssetKind.AUDIO, asset.kind)
        self.assertFalse(asset.license.verified)
        self.assertEqual("https://cdn.test/55.png", asset.previews[0].uri)


class PublicationAndManifestTests(unittest.TestCase):
    def _package(self, root: Path) -> PublicationPackage:
        path = root / "icon.png"
        _png(path)
        validated = LocalAssetValidator().validate(_draft(path)).asset
        return PublicationPackage.build(
            provider="roblox-open-cloud",
            asset=validated,
            creator=CreatorTarget(user_id="123"),
            integrations=(IntegrationTarget("presentation.primaryIcon", "Image"),),
            created_at="2026-08-11T12:00:00Z",
        )

    def test_package_is_content_addressed_and_upload_is_idempotent(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            package = self._package(root)
            same = PublicationPackage.build(
                provider=package.provider,
                asset=package.asset,
                creator=package.creator,
                integrations=package.integrations,
                created_at="2099-01-01T00:00:00Z",
            )
            self.assertEqual(package.package_id, same.package_id)

            transport = FakeHttpTransport()
            transport.queue_json(200, {"path": "operations/one"})
            provider = RobloxOpenCloudProvider(
                RobloxOpenCloudConfig(api_key="test"), transport=transport
            )
            coordinator = PublicationCoordinator(
                provider, PublicationLedger(root / "ledger")
            )
            first = coordinator.publish(package)
            second = coordinator.publish(package)
            self.assertEqual(AssetState.UPLOADING, first.asset.state)
            self.assertTrue(second.cached)
            self.assertEqual(1, len(transport.requests))
            self.assertFalse((root / "ledger" / "latest.json").exists())

    def test_changed_content_cannot_reuse_validated_package(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            package = self._package(root)
            Path(package.asset.local_path).write_bytes(b"changed")
            with self.assertRaisesRegex(ValueError, "content hash"):
                PublicationPackage.build(
                    provider=package.provider,
                    asset=package.asset,
                    creator=package.creator,
                )

            transport = FakeHttpTransport()
            provider = RobloxOpenCloudProvider(
                RobloxOpenCloudConfig(api_key="test"), transport=transport
            )
            result = PublicationCoordinator(
                provider, PublicationLedger(root / "ledger")
            ).publish(package)
            self.assertEqual(PipelineOutcome.FAILED, result.outcome)
            self.assertEqual("publication_package_invalid", result.blockers[0].code)
            self.assertEqual([], transport.requests)

    def test_production_manifest_blocks_pending_and_builds_only_approved(self) -> None:
        pending = {
            "schemaVersion": 1,
            "manifestId": "assets-build-1",
            "assets": [
                {
                    "id": "sound.core-loop",
                    "kind": "audio",
                    "displayName": "Core Loop",
                    "description": "Core-loop sound",
                    "state": "published",
                    "provider": "roblox-open-cloud",
                    "requirement": "production-required",
                    "previews": [],
                    "metadata": {},
                }
            ],
            "integrations": [],
        }
        report = AssetManifestValidator().validate(pending)
        self.assertFalse(report.production_ready)
        codes = {issue.code for issue in report.issues}
        self.assertIn("production.approved", codes)
        self.assertIn("production.license_evidence", codes)
        self.assertIn("production.integration_target", codes)

        approved_asset = AssetRecord(
            logical_id="sound.core-loop",
            kind=AssetKind.AUDIO,
            display_name="Core Loop",
            description="Core-loop sound",
            state=AssetState.APPROVED,
            provider="roblox-open-cloud",
            requirement=AssetRequirement.PRODUCTION_REQUIRED,
            previews=(AssetPreview("https://cdn.test/sound.png", "image/png"),),
            license=_license(),
            provenance=AssetProvenance(
                provider="roblox-open-cloud",
                source_uri="generator://run/sound",
                retrieved_at="2026-08-11T12:00:00Z",
                content_sha256="a" * 64,
                operation_id="operations/sound",
            ),
            remote_asset_id="991",
            moderation_state="MODERATION_STATE_APPROVED",
        )
        manifest = {
            "schemaVersion": 1,
            "manifestId": "assets-build-2",
            "assets": [approved_asset.to_dict()],
            "integrations": [
                {
                    "assetId": "sound.core-loop",
                    "target": "audio.coreLoop",
                    "property": "SoundId",
                    "expectedClass": "Sound",
                }
            ],
        }
        report = AssetManifestValidator().validate(manifest)
        self.assertTrue(report.production_ready, report.issues)
        bundle = build_integration_bundle(manifest)
        self.assertEqual("rbxassetid://991", bundle.bindings[0].content_uri)

    def test_asset_schemas_are_valid_json(self) -> None:
        root = Path(__file__).resolve().parents[1]
        for name in (
            "asset-manifest.schema.json",
            "asset-catalog.schema.json",
            "asset-publication-package.schema.json",
            "asset-work-request.v1.schema.json",
        ):
            with self.subTest(name=name):
                payload = json.loads((root / "schemas" / name).read_text(encoding="utf-8"))
                self.assertEqual("https://json-schema.org/draft/2020-12/schema", payload["$schema"])


if __name__ == "__main__":
    unittest.main()
