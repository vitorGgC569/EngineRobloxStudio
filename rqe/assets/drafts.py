"""Create explicit local drafts from generated or human-supplied files."""

from __future__ import annotations

from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path

from .models import (
    AssetKind,
    AssetLicense,
    AssetPreview,
    AssetProvenance,
    AssetRecord,
    AssetRequirement,
    AssetState,
)


def _now() -> str:
    return datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")


@dataclass(frozen=True)
class LocalDraftRequest:
    logical_id: str
    kind: AssetKind
    display_name: str
    description: str
    path: Path
    source_uri: str
    source_provider: str
    license: AssetLicense | None
    requirement: AssetRequirement = AssetRequirement.OPTIONAL
    previews: tuple[AssetPreview, ...] = ()
    creator_id: str | None = None
    tool: str | None = None
    prompt: str | None = None
    retrieved_at: str | None = None
    metadata: dict[str, object] | None = None


def create_local_draft(request: LocalDraftRequest) -> AssetRecord:
    """Record creation inputs without claiming that the payload is valid.

    The file may not exist yet and rights may be unverified; those conditions
    are intentionally deferred to :class:`LocalAssetValidator`, which emits
    FAIL/BLOCKED evidence rather than this factory silently rejecting a draft.
    """

    return AssetRecord(
        logical_id=request.logical_id,
        kind=request.kind,
        display_name=request.display_name,
        description=request.description,
        state=AssetState.DRAFT,
        provider="local-draft",
        requirement=request.requirement,
        previews=request.previews,
        license=request.license,
        provenance=AssetProvenance(
            provider=request.source_provider,
            source_uri=request.source_uri,
            retrieved_at=request.retrieved_at or _now(),
            creator_id=request.creator_id,
            tool=request.tool,
            prompt=request.prompt,
        ),
        local_path=str(request.path),
        metadata=dict(request.metadata or {}),
    )
