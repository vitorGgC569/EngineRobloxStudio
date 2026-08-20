"""Lossless codecs for immutable asset records stored in manifests/ledgers."""

from __future__ import annotations

from typing import Any, Mapping

from .models import (
    AssetKind,
    AssetLicense,
    AssetPreview,
    AssetProvenance,
    AssetRecord,
    AssetRequirement,
    AssetState,
)


def asset_from_dict(raw: Mapping[str, Any]) -> AssetRecord:
    previews = tuple(
        AssetPreview(
            uri=str(item["uri"]),
            media_type=str(item["mediaType"]),
            label=str(item.get("label", "preview")),
            width=_optional_int(item.get("width")),
            height=_optional_int(item.get("height")),
            sha256=_optional_str(item.get("sha256")),
        )
        for item in _sequence(raw.get("previews"))
        if isinstance(item, Mapping)
    )

    license_raw = raw.get("license")
    license_record = None
    if isinstance(license_raw, Mapping):
        license_record = AssetLicense(
            name=str(license_raw.get("name", "")),
            terms_url=str(license_raw.get("termsUrl", "")),
            usage_scope=str(license_raw.get("usageScope", "")),
            verified=license_raw.get("verified") is True,
            commercial_use=_optional_bool(license_raw.get("commercialUse")),
            attribution_required=_optional_bool(
                license_raw.get("attributionRequired")
            ),
            attribution=_optional_str(license_raw.get("attribution")),
            evidence=_optional_str(license_raw.get("evidence")),
        )

    provenance_raw = raw.get("provenance")
    provenance = None
    if isinstance(provenance_raw, Mapping):
        provenance = AssetProvenance(
            provider=str(provenance_raw.get("provider", "")),
            source_uri=str(provenance_raw.get("sourceUri", "")),
            retrieved_at=str(provenance_raw.get("retrievedAt", "")),
            source_asset_id=_optional_str(provenance_raw.get("sourceAssetId")),
            creator_id=_optional_str(provenance_raw.get("creatorId")),
            creator_name=_optional_str(provenance_raw.get("creatorName")),
            content_sha256=_optional_str(provenance_raw.get("contentSha256")),
            operation_id=_optional_str(provenance_raw.get("operationId")),
            tool=_optional_str(provenance_raw.get("tool")),
            prompt=_optional_str(provenance_raw.get("prompt")),
        )

    metadata = raw.get("metadata", {})
    if not isinstance(metadata, Mapping):
        raise ValueError("asset metadata must be an object")
    return AssetRecord(
        logical_id=str(raw["id"]),
        kind=AssetKind(str(raw["kind"])),
        display_name=str(raw["displayName"]),
        description=str(raw["description"]),
        state=AssetState(str(raw["state"])),
        provider=str(raw["provider"]),
        requirement=AssetRequirement(str(raw.get("requirement", "optional"))),
        previews=previews,
        license=license_record,
        provenance=provenance,
        local_path=_optional_str(raw.get("localPath")),
        content_type=_optional_str(raw.get("contentType")),
        remote_asset_id=_optional_str(raw.get("remoteAssetId")),
        moderation_state=_optional_str(raw.get("moderationState")),
        metadata=dict(metadata),
    )


def _sequence(value: object) -> list[object] | tuple[object, ...]:
    return value if isinstance(value, (list, tuple)) else []


def _optional_str(value: object) -> str | None:
    return str(value) if value is not None else None


def _optional_int(value: object) -> int | None:
    return value if isinstance(value, int) and not isinstance(value, bool) else None


def _optional_bool(value: object) -> bool | None:
    return value if isinstance(value, bool) else None
