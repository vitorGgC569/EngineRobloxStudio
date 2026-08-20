"""Typed records shared by the asset discovery and publication pipeline.

The state machine is deliberately stricter than a typical upload helper.  An
HTTP 2xx only means that Roblox accepted an asynchronous operation; it does not
mean that an asset exists, passed moderation, or is usable by an experience.
Those facts have separate states and evidence.
"""

from __future__ import annotations

from dataclasses import dataclass, field, replace
from enum import Enum
from typing import Any, Mapping


class AssetKind(str, Enum):
    MESH = "mesh"
    AUDIO = "audio"
    ANIMATION = "animation"
    ICON = "icon"


class AssetState(str, Enum):
    DRAFT = "draft"
    VALIDATED = "validated"
    UPLOADING = "uploading"
    PUBLISHED = "published"
    APPROVED = "approved"
    REJECTED = "rejected"
    UNAVAILABLE = "unavailable"


class AssetRequirement(str, Enum):
    PRODUCTION_REQUIRED = "production-required"
    OPTIONAL = "optional"
    DEVELOPMENT = "development"


class PipelineOutcome(str, Enum):
    """Outcome of one pipeline stage, not of the whole asset lifecycle."""

    PROGRESSED = "PROGRESSED"
    BLOCKED = "BLOCKED"
    FAILED = "FAILED"
    UNAVAILABLE = "UNAVAILABLE"


class CapabilityAvailability(str, Enum):
    AVAILABLE = "AVAILABLE"
    BLOCKED = "BLOCKED"
    UNAVAILABLE = "UNAVAILABLE"


class CheckStatus(str, Enum):
    PASS = "PASS"
    WARN = "WARN"
    FAIL = "FAIL"
    BLOCKED = "BLOCKED"


_ALLOWED_TRANSITIONS: dict[AssetState, frozenset[AssetState]] = {
    AssetState.DRAFT: frozenset(
        {AssetState.VALIDATED, AssetState.REJECTED, AssetState.UNAVAILABLE}
    ),
    AssetState.VALIDATED: frozenset(
        {AssetState.UPLOADING, AssetState.REJECTED, AssetState.UNAVAILABLE}
    ),
    AssetState.UPLOADING: frozenset(
        {
            AssetState.PUBLISHED,
            AssetState.APPROVED,
            AssetState.REJECTED,
            AssetState.UNAVAILABLE,
        }
    ),
    AssetState.PUBLISHED: frozenset(
        {AssetState.APPROVED, AssetState.REJECTED, AssetState.UNAVAILABLE}
    ),
    AssetState.APPROVED: frozenset(),
    AssetState.REJECTED: frozenset({AssetState.DRAFT}),
    AssetState.UNAVAILABLE: frozenset({AssetState.DRAFT}),
}


@dataclass(frozen=True)
class AssetPreview:
    uri: str
    media_type: str
    label: str = "preview"
    width: int | None = None
    height: int | None = None
    sha256: str | None = None

    def to_dict(self) -> dict[str, Any]:
        result: dict[str, Any] = {
            "uri": self.uri,
            "mediaType": self.media_type,
            "label": self.label,
        }
        if self.width is not None:
            result["width"] = self.width
        if self.height is not None:
            result["height"] = self.height
        if self.sha256 is not None:
            result["sha256"] = self.sha256
        return result


@dataclass(frozen=True)
class AssetLicense:
    name: str
    terms_url: str
    usage_scope: str
    verified: bool
    commercial_use: bool | None = None
    attribution_required: bool | None = None
    attribution: str | None = None
    evidence: str | None = None

    def to_dict(self) -> dict[str, Any]:
        result: dict[str, Any] = {
            "name": self.name,
            "termsUrl": self.terms_url,
            "usageScope": self.usage_scope,
            "verified": self.verified,
        }
        if self.commercial_use is not None:
            result["commercialUse"] = self.commercial_use
        if self.attribution_required is not None:
            result["attributionRequired"] = self.attribution_required
        if self.attribution is not None:
            result["attribution"] = self.attribution
        if self.evidence is not None:
            result["evidence"] = self.evidence
        return result


@dataclass(frozen=True)
class AssetProvenance:
    provider: str
    source_uri: str
    retrieved_at: str
    source_asset_id: str | None = None
    creator_id: str | None = None
    creator_name: str | None = None
    content_sha256: str | None = None
    operation_id: str | None = None
    tool: str | None = None
    prompt: str | None = None

    def to_dict(self) -> dict[str, Any]:
        result: dict[str, Any] = {
            "provider": self.provider,
            "sourceUri": self.source_uri,
            "retrievedAt": self.retrieved_at,
        }
        optional = {
            "sourceAssetId": self.source_asset_id,
            "creatorId": self.creator_id,
            "creatorName": self.creator_name,
            "contentSha256": self.content_sha256,
            "operationId": self.operation_id,
            "tool": self.tool,
            "prompt": self.prompt,
        }
        result.update({key: value for key, value in optional.items() if value is not None})
        return result


@dataclass(frozen=True)
class AssetRecord:
    logical_id: str
    kind: AssetKind
    display_name: str
    description: str
    state: AssetState
    provider: str
    requirement: AssetRequirement = AssetRequirement.OPTIONAL
    previews: tuple[AssetPreview, ...] = ()
    license: AssetLicense | None = None
    provenance: AssetProvenance | None = None
    local_path: str | None = None
    content_type: str | None = None
    remote_asset_id: str | None = None
    moderation_state: str | None = None
    metadata: Mapping[str, Any] = field(default_factory=dict)

    def transition(self, new_state: AssetState, **changes: Any) -> "AssetRecord":
        if new_state == self.state:
            return replace(self, **changes)
        if new_state not in _ALLOWED_TRANSITIONS[self.state]:
            raise ValueError(
                f"invalid asset transition: {self.state.value} -> {new_state.value}"
            )
        return replace(self, state=new_state, **changes)

    def to_dict(self) -> dict[str, Any]:
        result: dict[str, Any] = {
            "id": self.logical_id,
            "kind": self.kind.value,
            "displayName": self.display_name,
            "description": self.description,
            "state": self.state.value,
            "provider": self.provider,
            "requirement": self.requirement.value,
            "previews": [item.to_dict() for item in self.previews],
            "metadata": dict(self.metadata),
        }
        if self.license is not None:
            result["license"] = self.license.to_dict()
        if self.provenance is not None:
            result["provenance"] = self.provenance.to_dict()
        optional = {
            "localPath": self.local_path,
            "contentType": self.content_type,
            "remoteAssetId": self.remote_asset_id,
            "moderationState": self.moderation_state,
        }
        result.update({key: value for key, value in optional.items() if value is not None})
        return result


@dataclass(frozen=True)
class SearchQuery:
    text: str
    kinds: tuple[AssetKind, ...] = ()
    creator_id: str | None = None
    limit: int = 25
    page_token: str | None = None

    def __post_init__(self) -> None:
        if isinstance(self.limit, bool) or not 1 <= self.limit <= 100:
            raise ValueError("search limit must be between 1 and 100")


@dataclass(frozen=True)
class PipelineBlocker:
    code: str
    message: str
    requirement: str | None = None

    def to_dict(self) -> dict[str, Any]:
        result = {"code": self.code, "message": self.message}
        if self.requirement:
            result["requirement"] = self.requirement
        return result


@dataclass(frozen=True)
class SearchResult:
    provider: str
    outcome: PipelineOutcome
    assets: tuple[AssetRecord, ...] = ()
    next_page_token: str | None = None
    blockers: tuple[PipelineBlocker, ...] = ()
    raw_count: int = 0

    def to_dict(self) -> dict[str, Any]:
        result: dict[str, Any] = {
            "provider": self.provider,
            "outcome": self.outcome.value,
            "assets": [asset.to_dict() for asset in self.assets],
            "blockers": [item.to_dict() for item in self.blockers],
            "rawCount": self.raw_count,
        }
        if self.next_page_token:
            result["nextPageToken"] = self.next_page_token
        return result


@dataclass(frozen=True)
class PreviewResult:
    provider: str
    outcome: PipelineOutcome
    previews: tuple[AssetPreview, ...] = ()
    blockers: tuple[PipelineBlocker, ...] = ()

    def to_dict(self) -> dict[str, Any]:
        return {
            "provider": self.provider,
            "outcome": self.outcome.value,
            "previews": [item.to_dict() for item in self.previews],
            "blockers": [item.to_dict() for item in self.blockers],
        }


@dataclass(frozen=True)
class ValidationCheck:
    code: str
    status: CheckStatus
    message: str
    details: Mapping[str, Any] = field(default_factory=dict)

    def to_dict(self) -> dict[str, Any]:
        return {
            "code": self.code,
            "status": self.status.value,
            "message": self.message,
            "details": dict(self.details),
        }


@dataclass(frozen=True)
class ValidationReport:
    asset: AssetRecord
    checks: tuple[ValidationCheck, ...]

    @property
    def ok(self) -> bool:
        return not any(
            check.status in {CheckStatus.FAIL, CheckStatus.BLOCKED}
            for check in self.checks
        )

    @property
    def blocked(self) -> bool:
        return any(check.status == CheckStatus.BLOCKED for check in self.checks)

    def to_dict(self) -> dict[str, Any]:
        return {
            "ok": self.ok,
            "blocked": self.blocked,
            "asset": self.asset.to_dict(),
            "checks": [item.to_dict() for item in self.checks],
        }


@dataclass(frozen=True)
class ProviderCapability:
    name: str
    availability: CapabilityAvailability
    reason: str
    requirements: tuple[str, ...] = ()
    validation_level: str = "NOT_VALIDATED"

    def to_dict(self) -> dict[str, Any]:
        return {
            "name": self.name,
            "availability": self.availability.value,
            "reason": self.reason,
            "requirements": list(self.requirements),
            "validationLevel": self.validation_level,
        }


@dataclass(frozen=True)
class ProviderCapabilities:
    provider: str
    capabilities: Mapping[str, ProviderCapability]

    def get(self, name: str) -> ProviderCapability:
        return self.capabilities[name]

    def to_dict(self) -> dict[str, Any]:
        return {
            "provider": self.provider,
            "capabilities": {
                name: capability.to_dict()
                for name, capability in sorted(self.capabilities.items())
            },
        }


@dataclass(frozen=True)
class PipelineResult:
    outcome: PipelineOutcome
    asset: AssetRecord
    message: str
    blockers: tuple[PipelineBlocker, ...] = ()
    operation_id: str | None = None
    cached: bool = False
    retryable: bool = False

    def to_dict(self) -> dict[str, Any]:
        result: dict[str, Any] = {
            "outcome": self.outcome.value,
            "asset": self.asset.to_dict(),
            "message": self.message,
            "blockers": [item.to_dict() for item in self.blockers],
            "cached": self.cached,
            "retryable": self.retryable,
        }
        if self.operation_id is not None:
            result["operationId"] = self.operation_id
        return result


@dataclass(frozen=True)
class CreatorTarget:
    user_id: str | None = None
    group_id: str | None = None

    def __post_init__(self) -> None:
        if bool(self.user_id) == bool(self.group_id):
            raise ValueError("exactly one of user_id or group_id is required")
        value = self.user_id or self.group_id or ""
        if not value.isascii() or not value.isdigit() or int(value) <= 0:
            raise ValueError("creator user/group ID must be a positive decimal integer")

    def to_open_cloud(self) -> dict[str, str]:
        if self.user_id:
            return {"userId": self.user_id}
        return {"groupId": self.group_id or ""}

    def to_dict(self) -> dict[str, str]:
        if self.user_id:
            return {"userId": self.user_id}
        return {"groupId": self.group_id or ""}


@dataclass(frozen=True)
class IntegrationTarget:
    target: str
    property: str
    expected_class: str | None = None

    def __post_init__(self) -> None:
        if not self.target.strip() or not self.property.strip():
            raise ValueError("integration target and property are required")

    def to_dict(self) -> dict[str, str]:
        result = {"target": self.target, "property": self.property}
        if self.expected_class:
            result["expectedClass"] = self.expected_class
        return result


def state_from_moderation(value: str | None) -> AssetState:
    normalized = (value or "").upper()
    if normalized in {"APPROVED", "MODERATION_STATE_APPROVED"}:
        return AssetState.APPROVED
    if normalized in {
        "REJECTED",
        "FAILED",
        "MODERATION_STATE_REJECTED",
        "MODERATION_STATE_FAILED",
    }:
        return AssetState.REJECTED
    return AssetState.PUBLISHED
