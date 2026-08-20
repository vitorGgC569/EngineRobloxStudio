from __future__ import annotations

import json
import tempfile
import unittest
import wave
from dataclasses import replace
from pathlib import Path

from PIL import Image

from rqe.assets.creation import (
    CreationBrief,
    CreationCoordinator,
    CreationLedger,
    CreationOutputSpec,
    CreationProgress,
    CreationProviderRegistry,
    CreationReference,
    GeneratorIdentity,
    RightsDeclaration,
)
from rqe.assets.creation_testing import FakeCreationProvider, FixtureCreation
from rqe.assets.creation_worker import WorkerOutboxConfig, WorkerOutboxCreationProvider
from rqe.assets.models import (
    AssetKind,
    AssetRequirement,
    CapabilityAvailability,
    PipelineBlocker,
    PipelineOutcome,
)
from rqe.assets.validation import sha256_file
from rqe.schema_validation import validate_schema_instance


MEDIA = {
    AssetKind.MESH: ("model.gltf-binary", "model.glb", "model/gltf-binary"),
    AssetKind.AUDIO: ("audio.wav", "audio.wav", "audio/wav"),
    AssetKind.ANIMATION: ("animation.rbxmx", "animation.rbxmx", "model/x-rbxm"),
    AssetKind.ICON: ("icon.png", "icon.png", "image/png"),
}


def _rights(*, verified: bool = True) -> RightsDeclaration:
    return RightsDeclaration(
        name="Original work",
        terms_url="https://rights.example.test/original",
        usage_scope="commercial Roblox experiences",
        verified=verified,
        commercial_use=True,
        evidence="rights/review-42",
    )


def _brief(
    kind: AssetKind,
    provider: str,
    *,
    tool: str,
    model: str,
    reference_hash: str = "a" * 64,
) -> CreationBrief:
    _, file_name, media_type = MEDIA[kind]
    reference = CreationReference(
        reference_id="reference.style-1",
        uri="https://reference.example.test/style.png",
        sha256=reference_hash,
        media_type="image/png",
        purpose="visual direction only",
        source_provider="reference-library",
        source_uri="https://reference.example.test/style.png",
        retrieved_at="2026-08-11T10:00:00Z",
        creator_id="creator-7",
        rights=_rights(),
    )
    return CreationBrief(
        brief_id=f"brief.{kind.value}.v1",
        logical_asset_id=f"factory.{kind.value}.primary",
        kind=kind,
        display_name=f"Primary {kind.value}",
        description=f"Original {kind.value} for a generic production project",
        requirement=AssetRequirement.PRODUCTION_REQUIRED,
        provider=provider,
        generation=GeneratorIdentity(
            prompt=f"Create a polished generic {kind.value}",
            negative_prompt="placeholder, watermark",
            tool=tool,
            tool_version="1.2.3",
            model=model,
            model_version="2026-08",
            seed=7711,
        ),
        references=(reference,),
        rights=_rights(),
        output=CreationOutputSpec(
            file_name=file_name,
            media_type=media_type,
            validation_profile=f"roblox-{kind.value}-v1",
            require_preview=True,
            placeholder_allowed=False,
        ),
        metadata={"artDirection": "generic-test"},
    )


def _preview(path: Path) -> None:
    Image.new("RGBA", (32, 32), (20, 80, 140, 255)).save(path)


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


def _wav(path: Path) -> None:
    with wave.open(str(path), "wb") as stream:
        stream.setnchannels(1)
        stream.setsampwidth(2)
        stream.setframerate(22_050)
        stream.writeframes(b"\x00\x00" * 2_205)


def _asset_file(root: Path, kind: AssetKind) -> Path:
    root.mkdir(parents=True, exist_ok=True)
    _, file_name, _ = MEDIA[kind]
    path = root / file_name
    if kind == AssetKind.ICON:
        Image.new("RGBA", (64, 64), (30, 90, 180, 255)).save(path)
    elif kind == AssetKind.MESH:
        _glb(path)
    elif kind == AssetKind.AUDIO:
        _wav(path)
    else:
        path.write_text("<roblox></roblox>", encoding="utf-8")
    return path


def _fixture(root: Path, kind: AssetKind) -> FixtureCreation:
    root.mkdir(parents=True, exist_ok=True)
    preview = root / f"{kind.value}-preview.png"
    _preview(preview)
    metadata = {"studioAuthored": True} if kind == AssetKind.ANIMATION else {}
    return FixtureCreation(
        path=_asset_file(root, kind),
        media_type=MEDIA[kind][2],
        previews=(preview,),
        metadata=metadata,
    )


class AssetCreationContractTests(unittest.TestCase):
    def test_brief_and_receipt_schemas_accept_real_contract_objects(self) -> None:
        root = Path(__file__).resolve().parents[1]
        brief = _brief(AssetKind.ICON, "provider-a", tool="tool-a", model="model-a")
        brief_schema = json.loads(
            (root / "schemas" / "asset-creation-brief.v1.schema.json").read_text(
                encoding="utf-8"
            )
        )
        self.assertEqual([], validate_schema_instance(brief.to_dict(), brief_schema))
        self.assertEqual(brief.sha256, brief.job_id)

        with tempfile.TemporaryDirectory() as directory:
            work = Path(directory)
            provider = FakeCreationProvider(
                name="provider-a",
                tool="tool-a",
                tool_version="1.2.3",
                model="model-a",
                model_version="2026-08",
                fixtures={AssetKind.ICON: _fixture(work, AssetKind.ICON)},
            )
            result = CreationCoordinator(
                CreationProviderRegistry((provider,)),
                CreationLedger(work / "ledger"),
                clock=lambda: "2026-08-11T12:00:00Z",
            ).execute(brief)
            receipt_schema = json.loads(
                (root / "schemas" / "asset-creation-receipt.v1.schema.json").read_text(
                    encoding="utf-8"
                )
            )
            self.assertEqual(
                [], validate_schema_instance(result.receipt.to_dict(), receipt_schema)
            )
            self.assertFalse(result.production_ready)
            self.assertTrue(result.ready_for_publication)

    def test_two_providers_are_explicitly_routed_and_all_four_kinds_validate(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            fixtures_a = {
                kind: _fixture(root / "a", kind)
                for kind in (AssetKind.ICON, AssetKind.MESH)
            }
            fixtures_b = {
                kind: _fixture(root / "b", kind)
                for kind in (AssetKind.AUDIO, AssetKind.ANIMATION)
            }
            provider_a = FakeCreationProvider(
                name="provider-a",
                tool="tool-a",
                tool_version="1.2.3",
                model="model-a",
                model_version="2026-08",
                fixtures=fixtures_a,
            )
            provider_b = FakeCreationProvider(
                name="provider-b",
                tool="tool-b",
                tool_version="1.2.3",
                model="model-b",
                model_version="2026-08",
                fixtures=fixtures_b,
            )
            registry = CreationProviderRegistry((provider_a, provider_b))
            coordinator = CreationCoordinator(registry, CreationLedger(root / "ledger"))

            results = []
            for kind in AssetKind:
                is_a = kind in fixtures_a
                results.append(
                    coordinator.execute(
                        _brief(
                            kind,
                            "provider-a" if is_a else "provider-b",
                            tool="tool-a" if is_a else "tool-b",
                            model="model-a" if is_a else "model-b",
                        )
                    )
                )
            self.assertTrue(all(item.ready_for_publication for item in results))
            self.assertTrue(all(not item.production_ready for item in results))
            self.assertEqual(2, len(provider_a.calls))
            self.assertEqual(2, len(provider_b.calls))
            self.assertEqual(
                ["provider-a", "provider-b"],
                [item.provider for item in registry.capabilities()],
            )

    def test_completed_job_is_idempotent_and_does_not_call_provider_twice(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            provider = FakeCreationProvider(
                name="provider-a",
                tool="tool-a",
                tool_version="1.2.3",
                model="model-a",
                model_version="2026-08",
                fixtures={AssetKind.ICON: _fixture(root, AssetKind.ICON)},
            )
            coordinator = CreationCoordinator(
                CreationProviderRegistry((provider,)), CreationLedger(root / "ledger")
            )
            brief = _brief(
                AssetKind.ICON, "provider-a", tool="tool-a", model="model-a"
            )
            first = coordinator.execute(brief)
            second = coordinator.execute(brief)
            self.assertEqual(first.receipt.receipt_id, second.receipt.receipt_id)
            self.assertTrue(second.cached)
            self.assertEqual(1, len(provider.calls))
            self.assertFalse((root / "ledger" / "latest.json").exists())

    def test_tampered_hash_bound_output_blocks_cached_success(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            provider = FakeCreationProvider(
                name="provider-a",
                tool="tool-a",
                tool_version="1.2.3",
                model="model-a",
                model_version="2026-08",
                fixtures={AssetKind.ICON: _fixture(root, AssetKind.ICON)},
            )
            coordinator = CreationCoordinator(
                CreationProviderRegistry((provider,)), CreationLedger(root / "ledger")
            )
            brief = _brief(
                AssetKind.ICON, "provider-a", tool="tool-a", model="model-a"
            )
            first = coordinator.execute(brief)
            artifact = root / "ledger" / first.receipt.output["artifact"]["path"]
            artifact.write_bytes(b"tampered")
            second = coordinator.execute(brief)
            self.assertEqual(PipelineOutcome.FAILED, second.outcome)
            self.assertEqual("creation_ledger_invalid", second.blockers[0].code)
            self.assertEqual(1, len(provider.calls))

    def test_placeholder_and_missing_preview_resource_never_become_ready(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            placeholder = replace(_fixture(root, AssetKind.ICON), is_placeholder=True)
            provider = FakeCreationProvider(
                name="provider-a",
                tool="tool-a",
                tool_version="1.2.3",
                model="model-a",
                model_version="2026-08",
                fixtures={AssetKind.ICON: placeholder},
            )
            brief = _brief(
                AssetKind.ICON, "provider-a", tool="tool-a", model="model-a"
            )
            result = CreationCoordinator(
                CreationProviderRegistry((provider,)), CreationLedger(root / "ledger-1")
            ).execute(brief)
            self.assertEqual(PipelineOutcome.FAILED, result.outcome)
            self.assertEqual("creation_placeholder_forbidden", result.blockers[0].code)
            self.assertFalse(result.ready_for_publication)

            missing = root / "missing-preview.png"
            fixture = replace(_fixture(root / "second", AssetKind.ICON), previews=(missing,))
            provider_2 = FakeCreationProvider(
                name="provider-a",
                tool="tool-a",
                tool_version="1.2.3",
                model="model-a",
                model_version="2026-08",
                fixtures={AssetKind.ICON: fixture},
            )
            result_2 = CreationCoordinator(
                CreationProviderRegistry((provider_2,)), CreationLedger(root / "ledger-2")
            ).execute(brief)
            self.assertEqual(PipelineOutcome.FAILED, result_2.outcome)
            self.assertEqual("creation_resource_invalid", result_2.blockers[0].code)
            self.assertFalse(result_2.ready_for_publication)

    def test_blocked_failed_and_progressed_have_no_invented_output(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            fixture = _fixture(root, AssetKind.ICON)
            brief = _brief(
                AssetKind.ICON, "provider-a", tool="tool-a", model="model-a"
            )
            for outcome, expected_status in (
                (PipelineOutcome.BLOCKED, CreationProgress.BLOCKED),
                (PipelineOutcome.FAILED, CreationProgress.FAILED),
            ):
                with self.subTest(outcome=outcome.value):
                    provider = FakeCreationProvider(
                        name="provider-a",
                        tool="tool-a",
                        tool_version="1.2.3",
                        model="model-a",
                        model_version="2026-08",
                        fixtures={AssetKind.ICON: fixture},
                        forced_outcome=outcome,
                    )
                    result = CreationCoordinator(
                        CreationProviderRegistry((provider,)),
                        CreationLedger(root / f"ledger-{outcome.value.lower()}"),
                    ).execute(brief)
                    self.assertEqual(outcome, result.outcome)
                    self.assertEqual(expected_status, result.receipt.status)
                    self.assertIsNone(result.receipt.output)

            progressed = FakeCreationProvider(
                name="provider-a",
                tool="tool-a",
                tool_version="1.2.3",
                model="model-a",
                model_version="2026-08",
                fixtures={AssetKind.ICON: fixture},
            )
            result = CreationCoordinator(
                CreationProviderRegistry((progressed,)),
                CreationLedger(root / "ledger-progressed"),
            ).execute(brief)
            self.assertEqual(PipelineOutcome.PROGRESSED, result.outcome)
            self.assertIsNotNone(result.receipt.output)


class AssetCreationWorkerTests(unittest.TestCase):
    def _provider(
        self,
        root: Path,
        *,
        tool_ready: bool,
        credentials_ready: bool,
    ) -> WorkerOutboxCreationProvider:
        return WorkerOutboxCreationProvider(
            WorkerOutboxConfig(
                name="vertical-worker",
                root=root / "outbox",
                kinds=tuple(AssetKind),
                tool="vertical-tool",
                tool_version="1.2.3",
                models={"vertical-model": ("2026-08",)},
                tool_ready=tool_ready,
                credentials_ready=credentials_ready,
                credential_reference="secret://asset-worker/api"
                if credentials_ready
                else None,
            )
        )

    def test_missing_credentials_and_missing_tool_are_explicitly_blocked(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            for tool_ready, credentials_ready, code in (
                (True, False, "creation_credentials_missing"),
                (False, True, "creation_tool_unavailable"),
            ):
                with self.subTest(code=code):
                    provider = self._provider(
                        root / code,
                        tool_ready=tool_ready,
                        credentials_ready=credentials_ready,
                    )
                    brief = _brief(
                        AssetKind.ICON,
                        "vertical-worker",
                        tool="vertical-tool",
                        model="vertical-model",
                    )
                    result = CreationCoordinator(
                        CreationProviderRegistry((provider,)),
                        CreationLedger(root / code / "ledger"),
                    ).execute(brief)
                    self.assertEqual(PipelineOutcome.BLOCKED, result.outcome)
                    self.assertIn(code, {item.code for item in result.blockers})
                    self.assertIsNone(result.receipt.output)
                    self.assertEqual([], list((root / code / "outbox" / "pending").glob("*.json")))

    def test_outbox_queues_once_then_consumes_typed_result_without_shell(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            provider = self._provider(root, tool_ready=True, credentials_ready=True)
            brief = _brief(
                AssetKind.ICON,
                "vertical-worker",
                tool="vertical-tool",
                model="vertical-model",
            )
            coordinator = CreationCoordinator(
                CreationProviderRegistry((provider,)), CreationLedger(root / "ledger")
            )
            queued = coordinator.execute(brief)
            self.assertEqual(PipelineOutcome.PROGRESSED, queued.outcome)
            self.assertEqual(CreationProgress.QUEUED, queued.receipt.status)
            self.assertIsNone(queued.receipt.output)
            request_path = provider.pending / f"{brief.job_id}.json"
            self.assertTrue(request_path.is_file())
            request_before = request_path.read_bytes()

            output = provider.output / "generated.png"
            preview = provider.output / "preview.png"
            _preview(output)
            _preview(preview)
            result_payload = {
                "schemaVersion": 1,
                "jobId": brief.job_id,
                "briefSha256": brief.sha256,
                "provider": "vertical-worker",
                "outcome": "PROGRESSED",
                "status": "COMPLETE",
                "message": "external worker produced bytes",
                "providerJobId": "vertical-job-1",
                "retryable": False,
                "blockers": [],
                "output": {
                    "artifactPath": "generated.png",
                    "mediaType": "image/png",
                    "previewPaths": ["preview.png"],
                    "isPlaceholder": False,
                    "metadata": {},
                },
            }
            (provider.results / f"{brief.job_id}.json").write_text(
                json.dumps(result_payload), encoding="utf-8"
            )
            completed = coordinator.execute(brief)
            self.assertTrue(completed.ready_for_publication)
            self.assertEqual(request_before, request_path.read_bytes())
            self.assertFalse(hasattr(provider, "command"))

    def test_worker_result_cannot_escape_output_root(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            provider = self._provider(root, tool_ready=True, credentials_ready=True)
            brief = _brief(
                AssetKind.ICON,
                "vertical-worker",
                tool="vertical-tool",
                model="vertical-model",
            )
            result_payload = {
                "schemaVersion": 1,
                "jobId": brief.job_id,
                "briefSha256": brief.sha256,
                "provider": "vertical-worker",
                "outcome": "PROGRESSED",
                "status": "COMPLETE",
                "message": "malicious path",
                "retryable": False,
                "blockers": [],
                "output": {
                    "artifactPath": "../escape.png",
                    "mediaType": "image/png",
                    "previewPaths": [],
                    "isPlaceholder": False,
                    "metadata": {},
                },
            }
            (provider.results / f"{brief.job_id}.json").write_text(
                json.dumps(result_payload), encoding="utf-8"
            )
            result = CreationCoordinator(
                CreationProviderRegistry((provider,)), CreationLedger(root / "ledger")
            ).execute(brief)
            self.assertEqual(PipelineOutcome.FAILED, result.outcome)
            self.assertIn("escapes outputRoot", result.receipt.message)


if __name__ == "__main__":
    unittest.main()
