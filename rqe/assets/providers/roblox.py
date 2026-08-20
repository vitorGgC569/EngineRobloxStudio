"""Roblox Open Cloud adapter for discovery, thumbnails, and asset uploads.

The adapter mirrors the platform lifecycle instead of collapsing it: Create
Asset returns an asynchronous operation, and an asset is only ``approved``
when an operation/metadata response contains explicit approval evidence.

This module is tested against an injected HTTP transport.  Live endpoint
behaviour remains ``NOT_VALIDATED`` until a credentialed run records evidence.
"""

from __future__ import annotations

import hashlib
import json
from dataclasses import dataclass, field, replace
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Callable, Mapping, Sequence
from urllib.parse import urlencode

from ..http import (
    HttpRequest,
    HttpResponse,
    HttpTransport,
    UrllibTransport,
    json_body,
    multipart_body,
)
from ..models import (
    AssetKind,
    AssetLicense,
    AssetPreview,
    AssetProvenance,
    AssetRecord,
    AssetRequirement,
    AssetState,
    CapabilityAvailability,
    PipelineBlocker,
    PipelineOutcome,
    PipelineResult,
    PreviewResult,
    ProviderCapabilities,
    ProviderCapability,
    SearchQuery,
    SearchResult,
    state_from_moderation,
)
from .base import PublishRequest


_DEFAULT_API_ROOT = "https://apis.roblox.com"
_DEFAULT_THUMBNAILS_ROOT = "https://thumbnails.roblox.com"
_ASSET_TYPES = {
    AssetKind.MESH: "Model",  # Custom FBX/glTF/GLB uploads are Models, not raw Mesh.
    AssetKind.AUDIO: "Audio",
    AssetKind.ANIMATION: "Animation",
    AssetKind.ICON: "Decal",
}
_SEARCH_TYPES = {
    AssetKind.MESH: "Model",
    AssetKind.AUDIO: "Audio",
    AssetKind.ANIMATION: "Animation",
    AssetKind.ICON: "Image",
}


def _utc_now() -> str:
    return datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")


@dataclass(frozen=True)
class RobloxOpenCloudConfig:
    api_key: str | None = field(default=None, repr=False)
    oauth_token: str | None = field(default=None, repr=False)
    api_root: str = _DEFAULT_API_ROOT
    thumbnails_root: str = _DEFAULT_THUMBNAILS_ROOT
    timeout_seconds: float = 30.0
    user_agent: str = "roblox-quality-engine/assets-v1"

    def __post_init__(self) -> None:
        if self.api_key and self.oauth_token:
            raise ValueError("configure either api_key or oauth_token, not both")
        if self.api_key is not None and not self.api_key.strip():
            raise ValueError("api_key cannot be blank")
        if self.oauth_token is not None and not self.oauth_token.strip():
            raise ValueError("oauth_token cannot be blank")
        if self.timeout_seconds <= 0:
            raise ValueError("timeout_seconds must be positive")
        if not self.api_root.startswith("https://"):
            raise ValueError("api_root must use HTTPS")
        if not self.thumbnails_root.startswith("https://"):
            raise ValueError("thumbnails_root must use HTTPS")

    @property
    def has_credentials(self) -> bool:
        return bool(self.api_key or self.oauth_token)


class RobloxOpenCloudProvider:
    name = "roblox-open-cloud"

    def __init__(
        self,
        config: RobloxOpenCloudConfig,
        *,
        transport: HttpTransport | None = None,
        clock: Callable[[], str] = _utc_now,
    ) -> None:
        self.config = config
        self.transport = transport or UrllibTransport()
        self.clock = clock

    def capabilities(self) -> ProviderCapabilities:
        remote = (
            CapabilityAvailability.AVAILABLE
            if self.config.has_credentials
            else CapabilityAvailability.BLOCKED
        )
        credential_reason = (
            "Open Cloud credential is configured; live behaviour still needs run evidence"
            if self.config.has_credentials
            else "an API key or OAuth token with asset read/write scope is required"
        )
        return ProviderCapabilities(
            provider=self.name,
            capabilities={
                "search": ProviderCapability(
                    "search",
                    CapabilityAvailability.AVAILABLE,
                    "Creator Store search documents unauthenticated access (Beta)",
                    validation_level="NOT_VALIDATED",
                ),
                "previews": ProviderCapability(
                    "previews",
                    CapabilityAvailability.AVAILABLE,
                    "asset thumbnail retrieval is documented Stable and unauthenticated",
                    validation_level="NOT_VALIDATED",
                ),
                "upload": ProviderCapability(
                    "upload",
                    remote,
                    credential_reason,
                    requirements=("asset:write/API-key Assets write", "creator target"),
                    validation_level="NOT_VALIDATED",
                ),
                "moderation": ProviderCapability(
                    "moderation",
                    remote,
                    credential_reason,
                    requirements=("asset:read/API-key Assets read", "Roblox approval"),
                    validation_level="NOT_VALIDATED",
                ),
                "experience-icon-publication": ProviderCapability(
                    "experience-icon-publication",
                    CapabilityAvailability.UNAVAILABLE,
                    "this adapter uploads icon image content as a Decal; "
                    "it does not assign an experience icon",
                    requirements=("separate documented universe icon workflow",),
                    validation_level="STATICALLY_VALIDATED",
                ),
            },
        )

    def search(self, query: SearchQuery) -> SearchResult:
        body: dict[str, object] = {
            "query": query.text,
            "maxPageSize": max(1, min(query.limit, 100)),
        }
        if query.kinds:
            body["assetTypes"] = [_SEARCH_TYPES[kind] for kind in query.kinds]
        if query.creator_id:
            body["creatorId"] = query.creator_id
        if query.page_token:
            body["pageToken"] = query.page_token
        response = self._send(
            HttpRequest(
                "POST",
                f"{self.config.api_root.rstrip('/')}/toolbox-service/v2/assets:search",
                headers=self._headers(json_request=True, credentials_optional=True),
                body=json_body(body),
                timeout_seconds=self.config.timeout_seconds,
            )
        )
        if isinstance(response, PipelineBlocker):
            return SearchResult(
                self.name, PipelineOutcome.BLOCKED, blockers=(response,)
            )
        if response.status < 200 or response.status >= 300:
            return SearchResult(
                self.name,
                _http_outcome(response.status),
                blockers=(_http_blocker(response, "Creator Store search"),),
            )
        try:
            payload = response.json()
        except (UnicodeError, json.JSONDecodeError) as exc:
            return SearchResult(
                self.name,
                PipelineOutcome.FAILED,
                blockers=(PipelineBlocker("invalid_search_response", str(exc)),),
            )
        if not isinstance(payload, Mapping):
            return SearchResult(
                self.name,
                PipelineOutcome.FAILED,
                blockers=(PipelineBlocker("invalid_search_response", "expected a JSON object"),),
            )
        rows = _find_rows(payload)
        records = tuple(
            record
            for row in rows
            if (record := self._search_record(row)) is not None
        )
        next_token = _first_string(payload, "nextPageToken", "nextCursor", "cursor")
        return SearchResult(
            provider=self.name,
            outcome=PipelineOutcome.PROGRESSED,
            assets=records,
            next_page_token=next_token,
            raw_count=len(rows),
        )

    def previews(self, asset: AssetRecord) -> PreviewResult:
        if not asset.remote_asset_id:
            return PreviewResult(
                self.name,
                PipelineOutcome.UNAVAILABLE,
                asset.previews,
                (
                    PipelineBlocker(
                        "remote_asset_id_missing",
                        "Roblox thumbnail lookup requires a remote asset ID",
                    ),
                ),
            )
        query = urlencode(
            {
                "assetIds": asset.remote_asset_id,
                "returnPolicy": "PlaceHolder",
                "size": "420x420",
                "format": "Png",
                "isCircular": "false",
            }
        )
        response = self._send(
            HttpRequest(
                "GET",
                f"{self.config.thumbnails_root.rstrip('/')}/v1/assets?{query}",
                headers={"User-Agent": self.config.user_agent},
                timeout_seconds=self.config.timeout_seconds,
            )
        )
        if isinstance(response, PipelineBlocker):
            return PreviewResult(
                self.name,
                PipelineOutcome.BLOCKED,
                asset.previews,
                (response,),
            )
        if not 200 <= response.status < 300:
            return PreviewResult(
                self.name,
                _http_outcome(response.status),
                asset.previews,
                (_http_blocker(response, "asset thumbnail"),),
            )
        try:
            payload = response.json()
        except (UnicodeError, json.JSONDecodeError) as exc:
            return PreviewResult(
                self.name,
                PipelineOutcome.FAILED,
                asset.previews,
                (PipelineBlocker("invalid_thumbnail_response", str(exc)),),
            )
        if not isinstance(payload, Mapping):
            return PreviewResult(
                self.name,
                PipelineOutcome.FAILED,
                asset.previews,
                (PipelineBlocker("invalid_thumbnail_response", "expected a JSON object"),),
            )
        previews = list(asset.previews)
        known = {item.uri for item in previews}
        for row in _find_rows(payload):
            uri = _first_string(row, "imageUrl", "imageUri", "thumbnailUrl")
            if uri and uri not in known:
                previews.append(
                    AssetPreview(uri=uri, media_type="image/png", label="Roblox thumbnail")
                )
                known.add(uri)
        if len(previews) == len(asset.previews) and not previews:
            return PreviewResult(
                self.name,
                PipelineOutcome.BLOCKED,
                (),
                (
                    PipelineBlocker(
                        "thumbnail_not_ready",
                        "Roblox returned no usable thumbnail URI",
                    ),
                ),
            )
        return PreviewResult(
            self.name,
            PipelineOutcome.PROGRESSED,
            tuple(previews),
        )

    def publish(self, request: PublishRequest) -> PipelineResult:
        asset = request.asset
        if asset.state != AssetState.VALIDATED:
            return PipelineResult(
                PipelineOutcome.FAILED,
                asset,
                "only locally validated assets can be uploaded",
                blockers=(
                    PipelineBlocker(
                        "asset_not_validated",
                        f"asset state is {asset.state.value}",
                        "state=validated",
                    ),
                ),
            )
        credential_block = self._credential_blocker()
        if credential_block:
            return PipelineResult(
                PipelineOutcome.BLOCKED,
                asset,
                "Roblox upload is blocked by missing credentials",
                blockers=(credential_block,),
            )
        path = Path(asset.local_path or "")
        if not path.is_file() or not asset.content_type:
            return PipelineResult(
                PipelineOutcome.FAILED,
                asset,
                "validated asset lost its local file or content type",
                blockers=(
                    PipelineBlocker(
                        "validated_payload_missing",
                        "rerun local validation before publication",
                        "local file and content type",
                    ),
                ),
            )
        boundary_hash = hashlib.sha256(request.idempotency_key.encode("utf-8")).hexdigest()[:32]
        boundary = f"rqe-{boundary_hash}"
        asset_type = str(asset.metadata.get("robloxAssetType") or _ASSET_TYPES[asset.kind])
        if asset_type not in {"Model", "Audio", "Animation", "Decal", "Image"}:
            return PipelineResult(
                PipelineOutcome.FAILED,
                asset,
                f"unsupported Roblox asset type override: {asset_type}",
            )
        request_payload: dict[str, object] = {
            "assetType": asset_type,
            "displayName": asset.display_name,
            "description": asset.description,
            "creationContext": {"creator": request.creator.to_open_cloud()},
        }
        try:
            content = path.read_bytes()
        except OSError as exc:
            return PipelineResult(
                PipelineOutcome.FAILED,
                asset,
                "validated publication payload is unreadable",
                blockers=(PipelineBlocker("publication_payload_unreadable", str(exc)),),
            )
        body = multipart_body(
            request_payload=request_payload,
            filename=path.name,
            content_type=asset.content_type,
            content=content,
            boundary=boundary,
        )
        response = self._send(
            HttpRequest(
                "POST",
                f"{self.config.api_root.rstrip('/')}/assets/v1/assets",
                headers={
                    **self._headers(),
                    "Content-Type": f"multipart/form-data; boundary={boundary}",
                    "Idempotency-Key": request.idempotency_key,
                },
                body=body,
                timeout_seconds=self.config.timeout_seconds,
            )
        )
        if isinstance(response, PipelineBlocker):
            return PipelineResult(
                PipelineOutcome.BLOCKED,
                asset,
                "Roblox upload transport did not complete",
                blockers=(response,),
                retryable=True,
            )
        if not 200 <= response.status < 300:
            return PipelineResult(
                _http_outcome(response.status),
                asset,
                f"Roblox rejected the Create Asset request with HTTP {response.status}",
                blockers=(_http_blocker(response, "Create Asset"),),
                retryable=response.status == 429 or response.status >= 500,
            )
        try:
            payload = response.json()
        except (UnicodeError, json.JSONDecodeError) as exc:
            return PipelineResult(
                PipelineOutcome.FAILED,
                asset,
                "Create Asset returned invalid JSON",
                blockers=(PipelineBlocker("invalid_upload_response", str(exc)),),
            )
        if not isinstance(payload, Mapping):
            return PipelineResult(
                PipelineOutcome.FAILED,
                asset,
                "Create Asset returned no operation object",
            )
        operation = _first_string(payload, "path", "operation", "operationId")
        if not operation:
            return PipelineResult(
                PipelineOutcome.FAILED,
                asset,
                "HTTP success had no operation identifier; publication is unproven",
                blockers=(
                    PipelineBlocker(
                        "operation_evidence_missing",
                        "Create Asset must return an operation path",
                    ),
                ),
            )
        provenance = replace(
            asset.provenance,
            provider=self.name,
            operation_id=operation,
        ) if asset.provenance else AssetProvenance(
            provider=self.name,
            source_uri=str(path),
            retrieved_at=self.clock(),
            operation_id=operation,
        )
        uploading = asset.transition(
            AssetState.UPLOADING,
            provider=self.name,
            provenance=provenance,
        )
        return PipelineResult(
            PipelineOutcome.PROGRESSED,
            uploading,
            "Create Asset accepted an asynchronous operation; approval is not yet proven",
            operation_id=operation,
            retryable=True,
        )

    def refresh(self, asset: AssetRecord) -> PipelineResult:
        credential_block = self._credential_blocker()
        if credential_block:
            return PipelineResult(
                PipelineOutcome.BLOCKED,
                asset,
                "asset status cannot be refreshed without credentials",
                blockers=(credential_block,),
            )
        if asset.state == AssetState.UPLOADING:
            operation = asset.provenance.operation_id if asset.provenance else None
            if not operation:
                return PipelineResult(
                    PipelineOutcome.FAILED,
                    asset,
                    "uploading asset has no operation identifier",
                    blockers=(PipelineBlocker("operation_evidence_missing", "cannot poll status"),),
                )
            operation_path = operation.lstrip("/")
            if not operation_path.startswith("operations/"):
                operation_path = f"operations/{operation_path}"
            url = f"{self.config.api_root.rstrip('/')}/assets/v1/{operation_path}"
        elif asset.state == AssetState.PUBLISHED and asset.remote_asset_id:
            url = f"{self.config.api_root.rstrip('/')}/assets/v1/assets/{asset.remote_asset_id}"
        elif asset.state in {AssetState.APPROVED, AssetState.REJECTED}:
            return PipelineResult(
                PipelineOutcome.PROGRESSED,
                asset,
                f"asset is already terminal: {asset.state.value}",
                cached=True,
            )
        else:
            return PipelineResult(
                PipelineOutcome.FAILED,
                asset,
                f"asset state {asset.state.value} has no remote status to refresh",
            )

        response = self._send(
            HttpRequest(
                "GET",
                url,
                headers=self._headers(),
                timeout_seconds=self.config.timeout_seconds,
            )
        )
        if isinstance(response, PipelineBlocker):
            return PipelineResult(
                PipelineOutcome.BLOCKED,
                asset,
                "Roblox status transport did not complete",
                blockers=(response,),
                retryable=True,
            )
        if not 200 <= response.status < 300:
            return PipelineResult(
                _http_outcome(response.status),
                asset,
                f"status request returned HTTP {response.status}",
                blockers=(_http_blocker(response, "asset status"),),
                retryable=response.status == 429 or response.status >= 500,
            )
        try:
            payload = response.json()
        except (UnicodeError, json.JSONDecodeError) as exc:
            return PipelineResult(
                PipelineOutcome.FAILED,
                asset,
                "status response was invalid JSON",
                blockers=(PipelineBlocker("invalid_status_response", str(exc)),),
            )
        if not isinstance(payload, Mapping):
            return PipelineResult(
                PipelineOutcome.FAILED,
                asset,
                "status response was not an object",
            )
        return self._interpret_status(asset, payload)

    def _interpret_status(
        self, asset: AssetRecord, payload: Mapping[str, Any]
    ) -> PipelineResult:
        if asset.state == AssetState.UPLOADING:
            if payload.get("error"):
                rejected = asset.transition(
                    AssetState.REJECTED,
                    moderation_state="UPLOAD_OPERATION_FAILED",
                )
                return PipelineResult(
                    PipelineOutcome.FAILED,
                    rejected,
                    "Roblox upload operation failed",
                    blockers=(
                        PipelineBlocker(
                            "upload_operation_failed", _safe_error(payload["error"])
                        ),
                    ),
                )
            if payload.get("done") is not True:
                return PipelineResult(
                    PipelineOutcome.BLOCKED,
                    asset,
                    "Roblox upload operation is still pending",
                    blockers=(PipelineBlocker("upload_pending", "poll the operation again"),),
                    operation_id=asset.provenance.operation_id if asset.provenance else None,
                    retryable=True,
                )

        raw_asset = payload.get("response") if asset.state == AssetState.UPLOADING else payload
        if not isinstance(raw_asset, Mapping):
            return PipelineResult(
                PipelineOutcome.FAILED,
                asset,
                "completed operation has no asset response; publication is unproven",
                blockers=(PipelineBlocker("asset_response_missing", "remote asset ID is absent"),),
            )
        remote_id = _first_string(raw_asset, "assetId", "id") or _id_from_path(
            _first_string(raw_asset, "path")
        )
        moderation = _moderation_state(raw_asset)
        if not remote_id:
            return PipelineResult(
                PipelineOutcome.FAILED,
                asset,
                "status response has no remote asset ID",
                blockers=(PipelineBlocker("remote_asset_id_missing", "publication is unproven"),),
            )
        desired = state_from_moderation(moderation)
        updated = asset.transition(
            desired,
            remote_asset_id=remote_id,
            moderation_state=moderation or "MODERATION_STATE_UNSPECIFIED",
        )
        if desired == AssetState.APPROVED:
            return PipelineResult(
                PipelineOutcome.PROGRESSED,
                updated,
                "Roblox returned explicit moderation approval",
            )
        if desired == AssetState.REJECTED:
            return PipelineResult(
                PipelineOutcome.FAILED,
                updated,
                "Roblox rejected the asset",
                blockers=(PipelineBlocker("moderation_rejected", moderation or "rejected"),),
            )
        return PipelineResult(
            PipelineOutcome.BLOCKED,
            updated,
            "asset exists but Roblox moderation approval is pending or unspecified",
            blockers=(
                PipelineBlocker(
                    "moderation_not_approved",
                    moderation or "no moderation state returned",
                    "MODERATION_STATE_APPROVED",
                ),
            ),
            retryable=True,
        )

    def _search_record(self, row: Mapping[str, Any]) -> AssetRecord | None:
        nested = row.get("asset")
        raw = nested if isinstance(nested, Mapping) else row
        remote_id = _first_string(raw, "assetId", "id") or _id_from_path(
            _first_string(raw, "path")
        )
        if not remote_id:
            return None
        kind = _kind_from_remote(
            _first_string(raw, "assetType", "type", "typeName")
        )
        if kind is None:
            return None
        name = _first_string(raw, "displayName", "name") or f"Roblox asset {remote_id}"
        description = _first_string(raw, "description") or (
            "No description returned by Creator Store search."
        )
        creator_raw = row.get("creator") or raw.get("creator")
        creator_id = None
        creator_name = None
        if isinstance(creator_raw, Mapping):
            creator_id = _first_string(creator_raw, "id", "userId", "groupId")
            creator_name = _first_string(creator_raw, "name", "displayName")
        preview_uri = _first_string(row, "thumbnailUrl", "imageUrl") or _first_string(
            raw, "thumbnailUrl", "imageUrl"
        )
        previews = (
            (AssetPreview(preview_uri, "image/png", "Creator Store preview"),)
            if preview_uri
            else ()
        )
        detail_uri = f"{self.config.api_root.rstrip('/')}/toolbox-service/v2/assets/{remote_id}"
        return AssetRecord(
            logical_id=f"roblox:{remote_id}",
            kind=kind,
            display_name=name,
            description=description,
            state=AssetState.PUBLISHED,
            provider=self.name,
            requirement=AssetRequirement.OPTIONAL,
            previews=previews,
            license=AssetLicense(
                name="Roblox Creator Store terms",
                terms_url="https://www.roblox.com/info/terms",
                usage_scope="Roblox Studio and experiences after acquisition and permission checks",
                verified=False,
                evidence=(
                    "search result only; acquisition and experience permission "
                    "were not verified"
                ),
            ),
            provenance=AssetProvenance(
                provider=self.name,
                source_uri=detail_uri,
                retrieved_at=self.clock(),
                source_asset_id=remote_id,
                creator_id=creator_id,
                creator_name=creator_name,
            ),
            remote_asset_id=remote_id,
            metadata={"searchResult": dict(row)},
        )

    def _headers(
        self, *, json_request: bool = False, credentials_optional: bool = False
    ) -> dict[str, str]:
        headers = {"Accept": "application/json", "User-Agent": self.config.user_agent}
        if json_request:
            headers["Content-Type"] = "application/json"
        if self.config.api_key:
            headers["x-api-key"] = self.config.api_key
        elif self.config.oauth_token:
            headers["Authorization"] = f"Bearer {self.config.oauth_token}"
        elif not credentials_optional:
            # Callers guard this condition; retaining no placeholder avoids
            # accidentally sending a string that resembles a credential.
            pass
        return headers

    def _credential_blocker(self) -> PipelineBlocker | None:
        if self.config.has_credentials:
            return None
        return PipelineBlocker(
            "roblox_credentials_missing",
            "configure an API key with Assets read/write or OAuth asset:read asset:write",
            "Roblox Open Cloud credential",
        )

    def _send(self, request: HttpRequest) -> HttpResponse | PipelineBlocker:
        try:
            return self.transport.send(request)
        except (OSError, TimeoutError) as exc:
            return PipelineBlocker("asset_http_unavailable", str(exc))


def _find_rows(payload: Mapping[str, Any]) -> list[Mapping[str, Any]]:
    for key in ("creatorStoreAssets", "assets", "results", "data"):
        value = payload.get(key)
        if isinstance(value, Sequence) and not isinstance(value, (str, bytes, bytearray)):
            return [item for item in value if isinstance(item, Mapping)]
    return []


def _first_string(raw: Mapping[str, Any], *keys: str) -> str | None:
    for key in keys:
        value = raw.get(key)
        if isinstance(value, (str, int)) and not isinstance(value, bool):
            text = str(value).strip()
            if text:
                return text
    return None


def _id_from_path(path: str | None) -> str | None:
    if not path:
        return None
    tail = path.rstrip("/").rsplit("/", 1)[-1]
    return tail or None


def _kind_from_remote(value: str | None) -> AssetKind | None:
    normalized = (value or "").upper()
    if "AUDIO" in normalized:
        return AssetKind.AUDIO
    if "ANIMATION" in normalized:
        return AssetKind.ANIMATION
    if "DECAL" in normalized or "IMAGE" in normalized or "ICON" in normalized:
        return AssetKind.ICON
    if "MESH" in normalized or "MODEL" in normalized:
        return AssetKind.MESH
    return None


def _moderation_state(raw: Mapping[str, Any]) -> str | None:
    result = raw.get("moderationResult")
    if isinstance(result, Mapping):
        value = _first_string(result, "moderationState", "state")
        if value:
            return value
    return _first_string(raw, "moderationState")


def _http_outcome(status: int) -> PipelineOutcome:
    if status in {401, 403, 409, 429} or status >= 500:
        return PipelineOutcome.BLOCKED
    return PipelineOutcome.FAILED


def _http_blocker(response: HttpResponse, operation: str) -> PipelineBlocker:
    if response.status in {401, 403}:
        code = "roblox_authorization_blocked"
        message = (
            f"{operation} requires valid credentials, scopes, creator ownership, "
            "or permission"
        )
    elif response.status == 409:
        code = "roblox_operation_conflict"
        message = f"{operation} conflicts with current remote state"
    elif response.status == 429:
        code = "roblox_rate_limited"
        message = f"{operation} exceeded a Roblox quota or rate limit"
    elif response.status >= 500:
        code = "roblox_service_unavailable"
        message = f"{operation} is temporarily unavailable"
    else:
        code = "roblox_request_failed"
        message = f"{operation} failed with HTTP {response.status}"
    return PipelineBlocker(code, message)


def _safe_error(value: object) -> str:
    if isinstance(value, Mapping):
        return _first_string(value, "message", "code") or "remote operation error"
    return str(value)[:500]
