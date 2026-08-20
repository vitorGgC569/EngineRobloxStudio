"""Operational facade for the reusable asset pipeline.

The lower-level modules deliberately separate discovery, validation,
publication, moderation and integration.  This facade preserves those states
while giving an agent one stable API and content-addressed receipts.  It never
mutates a game project and it has no global ``latest`` file.
"""

from __future__ import annotations

import hashlib
import json
import os
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Callable, Mapping, Sequence

from .drafts import LocalDraftRequest, create_local_draft
from .integration import IntegrationBundle, build_integration_bundle
from .manifest import AssetManifestReport, AssetManifestValidator
from .models import (
    AssetKind,
    AssetLicense,
    AssetPreview,
    AssetRequirement,
    CreatorTarget,
    IntegrationTarget,
    PipelineBlocker,
    PipelineOutcome,
    PipelineResult,
    SearchQuery,
    SearchResult,
)
from .providers.base import AssetProvider
from .publication import PublicationCoordinator, PublicationLedger, PublicationPackage
from .validation import LocalAssetValidator


def _now() -> str:
    return datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")


@dataclass(frozen=True)
class PreparedAsset:
    request_id: str
    request_sha256: str
    outcome: PipelineOutcome
    validation: Mapping[str, Any]
    package: PublicationPackage | None
    blockers: tuple[PipelineBlocker, ...] = ()

    def to_dict(self) -> dict[str, Any]:
        result: dict[str, Any] = {
            "schemaVersion": 1,
            "requestId": self.request_id,
            "requestSha256": self.request_sha256,
            "outcome": self.outcome.value,
            "validation": dict(self.validation),
            "blockers": [item.to_dict() for item in self.blockers],
        }
        if self.package is not None:
            result["packageId"] = self.package.package_id
            result["package"] = self.package.to_dict()
        return result


class AssetOperations:
    """One provider-bound, project-agnostic asset workspace."""

    def __init__(
        self,
        provider: AssetProvider,
        workspace: Path,
        *,
        validator: LocalAssetValidator | None = None,
        clock: Callable[[], str] = _now,
    ) -> None:
        self.provider = provider
        self.workspace = workspace.resolve()
        self.validator = validator or LocalAssetValidator()
        self.clock = clock

    def capabilities(self) -> dict[str, Any]:
        return self.provider.capabilities().to_dict()

    def search(self, query: SearchQuery) -> dict[str, Any]:
        result: SearchResult = self.provider.search(query)
        return {
            "schemaVersion": 1,
            "receiptType": "asset-search",
            "searchedAt": self.clock(),
            "query": {
                "text": query.text,
                "kinds": [kind.value for kind in query.kinds],
                "creatorId": query.creator_id,
                "limit": query.limit,
                "pageToken": query.page_token,
            },
            "result": result.to_dict(),
        }

    def record_receipt(
        self, category: str, payload: Mapping[str, Any]
    ) -> Path:
        if not category or any(
            character not in "abcdefghijklmnopqrstuvwxyz0123456789-_"
            for character in category
        ):
            raise ValueError("asset receipt category must be a safe lowercase identifier")
        digest = _canonical_hash(payload)
        path = self.workspace / category / f"{digest}.json"
        _write_immutable_json(path, payload)
        return path

    def prepare(self, raw: Mapping[str, Any], *, request_base: Path) -> PreparedAsset:
        parsed = _parse_work_request(raw, request_base=request_base)
        draft = create_local_draft(parsed["draft"])
        report = self.validator.validate(draft)
        request_hash = _canonical_hash(raw)
        package: PublicationPackage | None = None
        blockers: list[PipelineBlocker] = []
        if report.ok:
            package = PublicationPackage.build(
                provider=str(raw["provider"]),
                asset=report.asset,
                creator=parsed["creator"],
                integrations=parsed["integrations"],
                created_at=self.clock(),
            )
            outcome = PipelineOutcome.PROGRESSED
        else:
            outcome = (
                PipelineOutcome.BLOCKED if report.blocked else PipelineOutcome.FAILED
            )
            for check in report.checks:
                if check.status.value in {"FAIL", "BLOCKED"}:
                    blockers.append(
                        PipelineBlocker(check.code, check.message, check.status.value)
                    )
        return PreparedAsset(
            request_id=str(raw["requestId"]),
            request_sha256=request_hash,
            outcome=outcome,
            validation=report.to_dict(),
            package=package,
            blockers=tuple(blockers),
        )

    def prepare_file(self, request_path: Path) -> tuple[PreparedAsset, dict[str, Path]]:
        request_path = request_path.resolve()
        raw = _read_object(request_path)
        prepared = self.prepare(raw, request_base=request_path.parent)
        receipt_path = self.workspace / "preparations" / f"{prepared.request_sha256}.json"
        _write_immutable_json(receipt_path, prepared.to_dict())
        paths = {"preparation": receipt_path}
        if prepared.package is not None:
            package_path = (
                self.workspace
                / "packages"
                / f"{prepared.package.package_id}.json"
            )
            _write_immutable_json(package_path, prepared.package.to_dict())
            paths["package"] = package_path
        return prepared, paths

    def publish(
        self,
        package_path: Path,
        *,
        confirmation: str | None,
    ) -> PipelineResult:
        package = _load_package(package_path, verify_payload=True)
        if confirmation != package.package_id:
            return PipelineResult(
                PipelineOutcome.BLOCKED,
                package.asset,
                "external publication requires the exact content-addressed package ID",
                blockers=(
                    PipelineBlocker(
                        "publication_confirmation_required",
                        "pass --confirm-external-effect with this packageId",
                        package.package_id,
                    ),
                ),
            )
        coordinator = PublicationCoordinator(
            self.provider,
            PublicationLedger(self.workspace / "publication"),
        )
        return coordinator.publish(package)

    def refresh(self, package_path: Path) -> PipelineResult:
        package = _load_package(package_path, verify_payload=False)
        coordinator = PublicationCoordinator(
            self.provider,
            PublicationLedger(self.workspace / "publication"),
        )
        return coordinator.refresh(package)

    def validate_manifest(
        self, manifest_path: Path
    ) -> tuple[AssetManifestReport, IntegrationBundle | None]:
        report = AssetManifestValidator().validate_file(manifest_path.resolve())
        if not report.production_ready:
            return report, None
        raw = _read_object(manifest_path.resolve())
        return report, build_integration_bundle(raw)


def _load_package(path: Path, *, verify_payload: bool) -> PublicationPackage:
    return PublicationPackage.from_dict(
        _read_object(path.resolve()), verify_payload=verify_payload
    )


def _parse_work_request(
    raw: Mapping[str, Any], *, request_base: Path
) -> dict[str, Any]:
    _expect_keys(
        raw,
        required={"schemaVersion", "requestId", "provider", "asset", "creator", "integrations"},
        allowed={"schemaVersion", "requestId", "provider", "asset", "creator", "integrations"},
        label="asset work request",
    )
    if raw.get("schemaVersion") != 1:
        raise ValueError("asset work request schemaVersion must be 1")
    _required_text(raw.get("requestId"), "requestId")
    provider = _required_text(raw.get("provider"), "provider")
    if provider != "roblox-open-cloud":
        raise ValueError("asset work request provider must be roblox-open-cloud")
    asset_raw = _mapping(raw.get("asset"), "asset")
    _expect_keys(
        asset_raw,
        required={
            "id", "kind", "displayName", "description", "path", "source",
            "requirement", "previews", "metadata",
        },
        allowed={
            "id", "kind", "displayName", "description", "path", "source",
            "license", "requirement", "previews", "metadata",
        },
        label="asset",
    )
    source = _mapping(asset_raw.get("source"), "asset.source")
    _expect_keys(
        source,
        required={"provider", "uri"},
        allowed={"provider", "uri", "retrievedAt", "creatorId", "tool", "prompt"},
        label="asset.source",
    )
    license_record = _parse_license(asset_raw.get("license"))
    previews = _parse_previews(asset_raw.get("previews"))
    metadata = _mapping(asset_raw.get("metadata"), "asset.metadata")
    asset_path = Path(_required_text(asset_raw.get("path"), "asset.path"))
    if not asset_path.is_absolute():
        asset_path = request_base / asset_path

    creator_raw = _mapping(raw.get("creator"), "creator")
    _expect_keys(
        creator_raw,
        required=set(),
        allowed={"userId", "groupId"},
        label="creator",
    )
    creator = CreatorTarget(
        user_id=_optional_text(creator_raw.get("userId")),
        group_id=_optional_text(creator_raw.get("groupId")),
    )
    integrations_raw = raw.get("integrations")
    if not isinstance(integrations_raw, Sequence) or isinstance(
        integrations_raw, (str, bytes, bytearray)
    ):
        raise ValueError("integrations must be an array")
    integrations: list[IntegrationTarget] = []
    for index, item in enumerate(integrations_raw):
        entry = _mapping(item, f"integrations[{index}]")
        _expect_keys(
            entry,
            required={"target", "property"},
            allowed={"target", "property", "expectedClass"},
            label=f"integrations[{index}]",
        )
        integrations.append(
            IntegrationTarget(
                target=_required_text(entry.get("target"), f"integrations[{index}].target"),
                property=_required_text(entry.get("property"), f"integrations[{index}].property"),
                expected_class=_optional_text(entry.get("expectedClass")),
            )
        )
    try:
        kind = AssetKind(_required_text(asset_raw.get("kind"), "asset.kind"))
        requirement = AssetRequirement(
            _required_text(asset_raw.get("requirement"), "asset.requirement")
        )
    except ValueError as exc:
        raise ValueError(f"unsupported asset kind or requirement: {exc}") from exc
    draft = LocalDraftRequest(
        logical_id=_required_text(asset_raw.get("id"), "asset.id"),
        kind=kind,
        display_name=_required_text(asset_raw.get("displayName"), "asset.displayName"),
        description=_required_text(asset_raw.get("description"), "asset.description"),
        path=asset_path.resolve(),
        source_uri=_required_text(source.get("uri"), "asset.source.uri"),
        source_provider=_required_text(source.get("provider"), "asset.source.provider"),
        license=license_record,
        requirement=requirement,
        previews=previews,
        creator_id=_optional_text(source.get("creatorId")),
        tool=_optional_text(source.get("tool")),
        prompt=_optional_text(source.get("prompt")),
        retrieved_at=_optional_text(source.get("retrievedAt")),
        metadata=dict(metadata),
    )
    return {"draft": draft, "creator": creator, "integrations": tuple(integrations)}


def _parse_license(value: object) -> AssetLicense | None:
    if value is None:
        return None
    raw = _mapping(value, "asset.license")
    _expect_keys(
        raw,
        required={"name", "termsUrl", "usageScope", "verified"},
        allowed={
            "name", "termsUrl", "usageScope", "verified", "commercialUse",
            "attributionRequired", "attribution", "evidence",
        },
        label="asset.license",
    )
    if not isinstance(raw.get("verified"), bool):
        raise ValueError("asset.license.verified must be boolean")
    for field in ("commercialUse", "attributionRequired"):
        if raw.get(field) is not None and not isinstance(raw.get(field), bool):
            raise ValueError(f"asset.license.{field} must be boolean")
    return AssetLicense(
        name=_required_text(raw.get("name"), "asset.license.name"),
        terms_url=_required_text(raw.get("termsUrl"), "asset.license.termsUrl"),
        usage_scope=_required_text(raw.get("usageScope"), "asset.license.usageScope"),
        verified=raw["verified"] is True,
        commercial_use=raw.get("commercialUse"),
        attribution_required=raw.get("attributionRequired"),
        attribution=_optional_text(raw.get("attribution")),
        evidence=_optional_text(raw.get("evidence")),
    )


def _parse_previews(value: object) -> tuple[AssetPreview, ...]:
    if not isinstance(value, Sequence) or isinstance(value, (str, bytes, bytearray)):
        raise ValueError("asset.previews must be an array")
    previews: list[AssetPreview] = []
    for index, item in enumerate(value):
        raw = _mapping(item, f"asset.previews[{index}]")
        _expect_keys(
            raw,
            required={"uri", "mediaType"},
            allowed={"uri", "mediaType", "label", "width", "height", "sha256"},
            label=f"asset.previews[{index}]",
        )
        width = raw.get("width")
        height = raw.get("height")
        if width is not None and (isinstance(width, bool) or not isinstance(width, int) or width <= 0):
            raise ValueError(f"asset.previews[{index}].width must be a positive integer")
        if height is not None and (isinstance(height, bool) or not isinstance(height, int) or height <= 0):
            raise ValueError(f"asset.previews[{index}].height must be a positive integer")
        previews.append(
            AssetPreview(
                uri=_required_text(raw.get("uri"), f"asset.previews[{index}].uri"),
                media_type=_required_text(raw.get("mediaType"), f"asset.previews[{index}].mediaType"),
                label=_optional_text(raw.get("label")) or "preview",
                width=width,
                height=height,
                sha256=_optional_text(raw.get("sha256")),
            )
        )
    return tuple(previews)


def _read_object(path: Path) -> dict[str, Any]:
    raw = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(raw, dict):
        raise ValueError(f"{path} must contain a JSON object")
    return raw


def _mapping(value: object, label: str) -> Mapping[str, Any]:
    if not isinstance(value, Mapping):
        raise ValueError(f"{label} must be an object")
    return value


def _expect_keys(
    raw: Mapping[str, Any], *, required: set[str], allowed: set[str], label: str
) -> None:
    missing = sorted(required - set(raw))
    unknown = sorted(set(raw) - allowed)
    if missing:
        raise ValueError(f"{label} missing required fields: {', '.join(missing)}")
    if unknown:
        raise ValueError(f"{label} has unknown fields: {', '.join(unknown)}")


def _required_text(value: object, label: str) -> str:
    text = _optional_text(value)
    if text is None:
        raise ValueError(f"{label} must be a non-empty string")
    return text


def _optional_text(value: object) -> str | None:
    if not isinstance(value, str):
        return None
    stripped = value.strip()
    return stripped or None


def _canonical_hash(payload: Mapping[str, Any]) -> str:
    encoded = json.dumps(
        payload, sort_keys=True, ensure_ascii=False, separators=(",", ":")
    ).encode("utf-8")
    return hashlib.sha256(encoded).hexdigest()


def _write_immutable_json(path: Path, payload: Mapping[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    encoded = json.dumps(
        payload, indent=2, sort_keys=True, ensure_ascii=False
    ) + "\n"
    if path.exists():
        if path.read_text(encoding="utf-8") != encoded:
            raise FileExistsError(f"immutable asset artifact already differs: {path}")
        return
    temporary = path.with_name(f".{path.name}.{os.getpid()}.tmp")
    try:
        with temporary.open("x", encoding="utf-8") as stream:
            stream.write(encoded)
        os.replace(temporary, path)
    finally:
        temporary.unlink(missing_ok=True)
