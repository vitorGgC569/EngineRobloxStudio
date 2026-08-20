"""Build an immutable integration bundle; never mutate a game from a manifest."""

from __future__ import annotations

from dataclasses import dataclass
from typing import Any, Mapping

from .manifest import AssetManifestReport, AssetManifestValidator
from .models import AssetKind


@dataclass(frozen=True)
class IntegrationBinding:
    asset_id: str
    asset_kind: AssetKind
    target: str
    property: str
    content_uri: str
    expected_class: str | None = None

    def to_dict(self) -> dict[str, str]:
        result = {
            "assetId": self.asset_id,
            "assetKind": self.asset_kind.value,
            "target": self.target,
            "property": self.property,
            "contentUri": self.content_uri,
        }
        if self.expected_class:
            result["expectedClass"] = self.expected_class
        return result


@dataclass(frozen=True)
class IntegrationBundle:
    manifest_id: str
    bindings: tuple[IntegrationBinding, ...]

    def to_dict(self) -> dict[str, Any]:
        return {
            "schemaVersion": 1,
            "manifestId": self.manifest_id,
            "bindings": [binding.to_dict() for binding in self.bindings],
        }


def build_integration_bundle(
    manifest: Mapping[str, Any],
    *,
    validator: AssetManifestValidator | None = None,
) -> IntegrationBundle:
    report: AssetManifestReport = (validator or AssetManifestValidator()).validate(manifest)
    if not report.production_ready:
        blockers = ", ".join(
            issue.code for issue in report.issues if issue.status.value in {"FAIL", "BLOCKED"}
        )
        raise ValueError(f"asset manifest is not production-ready: {blockers}")
    by_id = {asset.logical_id: asset for asset in report.assets}
    bindings: list[IntegrationBinding] = []
    for raw in report.integrations:
        asset = by_id[str(raw["assetId"])]
        if not asset.remote_asset_id:
            raise ValueError(f"approved asset has no remote ID: {asset.logical_id}")
        bindings.append(
            IntegrationBinding(
                asset_id=asset.logical_id,
                asset_kind=asset.kind,
                target=str(raw["target"]),
                property=str(raw["property"]),
                content_uri=f"rbxassetid://{asset.remote_asset_id}",
                expected_class=str(raw["expectedClass"])
                if raw.get("expectedClass") is not None
                else None,
            )
        )
    return IntegrationBundle(report.manifest_id, tuple(bindings))
