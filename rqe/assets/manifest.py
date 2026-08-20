"""Production manifest validation for asset evidence and integration intent."""

from __future__ import annotations

import json
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Mapping, Sequence

from .codec import asset_from_dict
from .models import AssetRecord, AssetRequirement, AssetState, CheckStatus


@dataclass(frozen=True)
class ManifestIssue:
    code: str
    status: CheckStatus
    message: str
    asset_id: str | None = None
    details: Mapping[str, Any] = field(default_factory=dict)

    def to_dict(self) -> dict[str, Any]:
        result: dict[str, Any] = {
            "code": self.code,
            "status": self.status.value,
            "message": self.message,
            "details": dict(self.details),
        }
        if self.asset_id:
            result["assetId"] = self.asset_id
        return result


@dataclass(frozen=True)
class AssetManifestReport:
    manifest_id: str
    assets: tuple[AssetRecord, ...]
    integrations: tuple[Mapping[str, Any], ...]
    issues: tuple[ManifestIssue, ...]

    @property
    def ok(self) -> bool:
        return not any(
            item.status in {CheckStatus.FAIL, CheckStatus.BLOCKED}
            for item in self.issues
        )

    @property
    def production_ready(self) -> bool:
        return self.ok and all(
            asset.state == AssetState.APPROVED
            for asset in self.assets
            if asset.requirement == AssetRequirement.PRODUCTION_REQUIRED
        )

    def to_dict(self) -> dict[str, Any]:
        return {
            "manifestId": self.manifest_id,
            "ok": self.ok,
            "productionReady": self.production_ready,
            "issues": [item.to_dict() for item in self.issues],
        }


class AssetManifestValidator:
    """Refuse production-required assets without complete, current evidence."""

    def validate_file(self, path: Path) -> AssetManifestReport:
        try:
            payload = json.loads(path.read_text(encoding="utf-8"))
        except (OSError, UnicodeError, json.JSONDecodeError) as exc:
            return AssetManifestReport(
                path.stem,
                (),
                (),
                (
                    ManifestIssue(
                        "manifest.readable", CheckStatus.FAIL, str(exc)
                    ),
                ),
            )
        if not isinstance(payload, Mapping):
            return AssetManifestReport(
                path.stem,
                (),
                (),
                (
                    ManifestIssue(
                        "manifest.object",
                        CheckStatus.FAIL,
                        "asset manifest root must be an object",
                    ),
                ),
            )
        return self.validate(payload)

    def validate(self, manifest: Mapping[str, Any]) -> AssetManifestReport:
        issues: list[ManifestIssue] = []
        manifest_id = _text(manifest.get("manifestId")) or "<missing>"
        if manifest.get("schemaVersion") != 1:
            issues.append(
                ManifestIssue(
                    "manifest.schema_version",
                    CheckStatus.FAIL,
                    "schemaVersion must be 1",
                )
            )
        if manifest_id == "<missing>":
            issues.append(
                ManifestIssue(
                    "manifest.id", CheckStatus.FAIL, "manifestId is required"
                )
            )

        raw_assets = manifest.get("assets")
        if not _is_sequence(raw_assets):
            raw_assets = []
            issues.append(
                ManifestIssue(
                    "manifest.assets",
                    CheckStatus.FAIL,
                    "assets must be an array",
                )
            )
        raw_integrations = manifest.get("integrations", [])
        if not _is_sequence(raw_integrations):
            raw_integrations = []
            issues.append(
                ManifestIssue(
                    "manifest.integrations",
                    CheckStatus.FAIL,
                    "integrations must be an array",
                )
            )

        integrations: list[Mapping[str, Any]] = []
        integration_ids: set[str] = set()
        for index, raw in enumerate(raw_integrations):
            if not isinstance(raw, Mapping):
                issues.append(
                    ManifestIssue(
                        "integration.object",
                        CheckStatus.FAIL,
                        f"integration {index} must be an object",
                    )
                )
                continue
            asset_id = _text(raw.get("assetId"))
            target = _text(raw.get("target"))
            prop = _text(raw.get("property"))
            if not asset_id or not target or not prop:
                issues.append(
                    ManifestIssue(
                        "integration.complete",
                        CheckStatus.FAIL,
                        "integration requires assetId, target, and property",
                        asset_id=asset_id,
                        details={"index": index},
                    )
                )
                continue
            integrations.append(dict(raw))
            integration_ids.add(asset_id)

        assets: list[AssetRecord] = []
        asset_ids: set[str] = set()
        for index, raw in enumerate(raw_assets):
            if not isinstance(raw, Mapping):
                issues.append(
                    ManifestIssue(
                        "asset.object",
                        CheckStatus.FAIL,
                        f"asset {index} must be an object",
                    )
                )
                continue
            logical_id = _text(raw.get("id"))
            if logical_id and logical_id in asset_ids:
                issues.append(
                    ManifestIssue(
                        "asset.id_unique",
                        CheckStatus.FAIL,
                        "asset IDs must be unique",
                        logical_id,
                    )
                )
                continue
            try:
                asset = asset_from_dict(raw)
            except (KeyError, TypeError, ValueError) as exc:
                issues.append(
                    ManifestIssue(
                        "asset.parse",
                        CheckStatus.FAIL,
                        str(exc),
                        logical_id,
                        {"index": index},
                    )
                )
                continue
            assets.append(asset)
            asset_ids.add(asset.logical_id)
            if asset.requirement == AssetRequirement.PRODUCTION_REQUIRED:
                self._production_checks(asset, integration_ids, issues)

        for integration in integrations:
            asset_id = str(integration["assetId"])
            if asset_id not in asset_ids:
                issues.append(
                    ManifestIssue(
                        "integration.asset_exists",
                        CheckStatus.FAIL,
                        "integration references an unknown asset",
                        asset_id,
                    )
                )
        if not any(
            item.status in {CheckStatus.FAIL, CheckStatus.BLOCKED}
            for item in issues
        ):
            issues.append(
                ManifestIssue(
                    "manifest.production_evidence",
                    CheckStatus.PASS,
                    "all production-required assets have approval and integration evidence",
                )
            )
        return AssetManifestReport(
            manifest_id,
            tuple(assets),
            tuple(integrations),
            tuple(issues),
        )

    def _production_checks(
        self,
        asset: AssetRecord,
        integration_ids: set[str],
        issues: list[ManifestIssue],
    ) -> None:
        asset_id = asset.logical_id
        if asset.state != AssetState.APPROVED:
            issues.append(
                ManifestIssue(
                    "production.approved",
                    CheckStatus.BLOCKED,
                    f"production-required asset is {asset.state.value}, not approved",
                    asset_id,
                )
            )
        if not asset.remote_asset_id:
            issues.append(
                ManifestIssue(
                    "production.remote_asset_id",
                    CheckStatus.BLOCKED,
                    "production-required asset has no remote asset ID",
                    asset_id,
                )
            )
        moderation = (asset.moderation_state or "").upper()
        if moderation not in {"APPROVED", "MODERATION_STATE_APPROVED"}:
            issues.append(
                ManifestIssue(
                    "production.moderation_evidence",
                    CheckStatus.BLOCKED,
                    "explicit Roblox moderation approval is required",
                    asset_id,
                    {"moderationState": asset.moderation_state},
                )
            )
        license_record = asset.license
        if (
            license_record is None
            or not license_record.verified
            or not license_record.terms_url
            or not license_record.usage_scope
            or not license_record.evidence
        ):
            issues.append(
                ManifestIssue(
                    "production.license_evidence",
                    CheckStatus.BLOCKED,
                    "verified license terms, scope, and evidence are required",
                    asset_id,
                )
            )
        provenance = asset.provenance
        if (
            provenance is None
            or not provenance.provider
            or not provenance.source_uri
            or not provenance.retrieved_at
            or not (provenance.source_asset_id or provenance.content_sha256)
        ):
            issues.append(
                ManifestIssue(
                    "production.provenance_evidence",
                    CheckStatus.BLOCKED,
                    "provider, source URI, timestamp, and source ID/content hash are required",
                    asset_id,
                )
            )
        if not asset.previews or any(
            not preview.uri or not preview.media_type for preview in asset.previews
        ):
            issues.append(
                ManifestIssue(
                    "production.preview_evidence",
                    CheckStatus.BLOCKED,
                    "at least one named preview is required",
                    asset_id,
                )
            )
        if asset_id not in integration_ids:
            issues.append(
                ManifestIssue(
                    "production.integration_target",
                    CheckStatus.BLOCKED,
                    "at least one explicit integration target is required",
                    asset_id,
                )
            )


def _text(value: object) -> str | None:
    if not isinstance(value, str):
        return None
    value = value.strip()
    return value or None


def _is_sequence(value: object) -> bool:
    return isinstance(value, Sequence) and not isinstance(value, (str, bytes, bytearray))
