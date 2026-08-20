from __future__ import annotations

import hashlib
from pathlib import Path

from rqe.assets.catalog import AssetCatalog
from rqe.assets.director import Budget, plan
from rqe.assets.models import (
    AssetKind,
    AssetLicense,
    AssetProvenance,
    AssetRecord,
    AssetState,
)
from rqe.sourcing import resolve_plan_sources


def _record(path: Path, *, cues: list[str], asset_id: str = "kenney-click") -> AssetRecord:
    digest = hashlib.sha256(path.read_bytes()).hexdigest()
    return AssetRecord(
        logical_id=asset_id,
        kind=AssetKind.AUDIO,
        display_name=asset_id,
        description="curated Kenney UI cue",
        state=AssetState.DRAFT,
        provider="kenney",
        license=AssetLicense(
            name="CC0",
            terms_url="https://creativecommons.org/publicdomain/zero/1.0/",
            usage_scope="commercial games",
            verified=True,
            commercial_use=True,
            attribution_required=False,
            evidence="Kenney asset page and support terms",
        ),
        provenance=AssetProvenance(
            provider="kenney",
            source_uri="https://kenney.nl/assets/ui-audio",
            retrieved_at="2026-08-13T00:00:00Z",
            content_sha256=digest,
        ),
        local_path=str(path),
        content_type="audio/wav",
        metadata={"sourceId": "kenney-audio", "semanticCues": cues},
    )


def _plan():
    return plan("resolver-game", budget=Budget(triangles=10_000), extra=[
        ("feedback-ui-confirm", "feedback", 1),
        ("feedback-ui-denied", "feedback", 1),
        ("hero", "hero", 1),
    ])


def test_hash_and_licence_bound_catalog_becomes_a_source_offer(tmp_path: Path):
    sound = tmp_path / "click.wav"
    sound.write_bytes(b"RIFF-real-enough-for-a-resolution-unit-test")
    catalog = AssetCatalog("kenney-ui-audio")
    catalog.add(_record(sound, cues=["ui-confirm", "ui-denied"]))

    result = resolve_plan_sources(_plan(), catalog)

    assert result.complete
    assert result.source_offers == {
        "feedback-ui-confirm": ("kenney-audio",),
        "feedback-ui-denied": ("kenney-audio",),
    }
    assert result.to_dict()["publication"]["productionReady"] is False
    assert all(
        item["integration"]["status"] == "NOT_VALIDATED"
        for item in result.to_dict()["bindings"]
    )


def test_filename_guessing_cannot_satisfy_a_semantic_need(tmp_path: Path):
    sound = tmp_path / "obviously-confirm.wav"
    sound.write_bytes(b"RIFF")
    catalog = AssetCatalog("kenney-ui-audio")
    catalog.add(_record(sound, cues=[]))

    result = resolve_plan_sources(_plan(), catalog)

    assert result.bindings == ()
    assert result.unresolved == ("feedback-ui-confirm", "feedback-ui-denied")


def test_modified_download_is_rejected_instead_of_offered(tmp_path: Path):
    sound = tmp_path / "click.wav"
    sound.write_bytes(b"original")
    record = _record(sound, cues=["ui-confirm"])
    sound.write_bytes(b"modified after connector receipt")
    catalog = AssetCatalog("kenney-ui-audio", {record.logical_id: record})

    result = resolve_plan_sources(_plan(), catalog)

    assert "feedback-ui-confirm" in result.unresolved
    assert any("do not match" in item["reason"] for item in result.rejected)


def test_unverified_commercial_rights_are_rejected(tmp_path: Path):
    sound = tmp_path / "click.wav"
    sound.write_bytes(b"original")
    record = _record(sound, cues=["ui-confirm"])
    bad = AssetRecord(**{
        **record.__dict__,
        "license": AssetLicense(
            name="CC0", terms_url="https://example.invalid", usage_scope="unknown",
            verified=False, commercial_use=True, attribution_required=False,
        ),
    })
    catalog = AssetCatalog("bad", {bad.logical_id: bad})

    result = resolve_plan_sources(_plan(), catalog)

    assert "feedback-ui-confirm" in result.unresolved
    assert any("licence" in item["reason"] for item in result.rejected)
