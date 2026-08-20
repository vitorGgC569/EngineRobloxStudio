"""Provider contracts for local catalogs and remote asset services."""

from __future__ import annotations

from dataclasses import dataclass
from typing import Protocol

from ..models import (
    AssetRecord,
    CreatorTarget,
    PipelineResult,
    PreviewResult,
    ProviderCapabilities,
    SearchQuery,
    SearchResult,
)


@dataclass(frozen=True)
class PublishRequest:
    asset: AssetRecord
    creator: CreatorTarget
    idempotency_key: str


class AssetProvider(Protocol):
    """Smallest provider surface needed by the end-to-end pipeline.

    Providers report capability blockers before attempting external effects.
    A missing API key therefore cannot be mistaken for a publication success.
    """

    name: str

    def capabilities(self) -> ProviderCapabilities: ...

    def search(self, query: SearchQuery) -> SearchResult: ...

    def previews(self, asset: AssetRecord) -> PreviewResult: ...

    def publish(self, request: PublishRequest) -> PipelineResult: ...

    def refresh(self, asset: AssetRecord) -> PipelineResult: ...
