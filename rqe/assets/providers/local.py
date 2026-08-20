"""Local catalog provider.

This provider is useful for generated drafts, previews, and deterministic
tests.  It intentionally cannot publish to Roblox and reports that capability
as unavailable instead of manufacturing a remote asset id.
"""

from __future__ import annotations

from ..catalog import AssetCatalog
from ..models import (
    AssetRecord,
    CapabilityAvailability,
    PipelineBlocker,
    PipelineOutcome,
    PipelineResult,
    PreviewResult,
    ProviderCapabilities,
    ProviderCapability,
    SearchQuery,
    SearchResult,
)
from .base import PublishRequest


class LocalCatalogProvider:
    name = "local-catalog"

    def __init__(self, catalog: AssetCatalog):
        self.catalog = catalog

    def capabilities(self) -> ProviderCapabilities:
        return ProviderCapabilities(
            provider=self.name,
            capabilities={
                "search": ProviderCapability(
                    "search",
                    CapabilityAvailability.AVAILABLE,
                    "local catalog is directly searchable",
                    validation_level="STATICALLY_VALIDATED",
                ),
                "previews": ProviderCapability(
                    "previews",
                    CapabilityAvailability.AVAILABLE,
                    "preview records are stored in the catalog",
                    validation_level="STATICALLY_VALIDATED",
                ),
                "upload": ProviderCapability(
                    "upload",
                    CapabilityAvailability.UNAVAILABLE,
                    "the local provider has no remote publication endpoint",
                    requirements=("select a remote publication provider",),
                    validation_level="STATICALLY_VALIDATED",
                ),
                "moderation": ProviderCapability(
                    "moderation",
                    CapabilityAvailability.UNAVAILABLE,
                    "local files do not carry Roblox moderation approval",
                    requirements=("publish through Roblox and await moderation",),
                    validation_level="STATICALLY_VALIDATED",
                ),
            },
        )

    def search(self, query: SearchQuery) -> SearchResult:
        assets = self.catalog.search(query)
        return SearchResult(
            provider=self.name,
            outcome=PipelineOutcome.PROGRESSED,
            assets=assets,
            raw_count=len(assets),
        )

    def previews(self, asset: AssetRecord) -> PreviewResult:
        return PreviewResult(
            provider=self.name,
            outcome=PipelineOutcome.PROGRESSED,
            previews=asset.previews,
        )

    def publish(self, request: PublishRequest) -> PipelineResult:
        return PipelineResult(
            outcome=PipelineOutcome.UNAVAILABLE,
            asset=request.asset,
            message="local provider cannot publish to Roblox",
            blockers=(
                PipelineBlocker(
                    "provider_has_no_upload",
                    "select a provider with a configured Roblox Assets API adapter",
                    "remote publication provider",
                ),
            ),
        )

    def refresh(self, asset: AssetRecord) -> PipelineResult:
        return PipelineResult(
            outcome=PipelineOutcome.UNAVAILABLE,
            asset=asset,
            message="local provider has no remote publication to refresh",
            blockers=(
                PipelineBlocker(
                    "provider_has_no_moderation",
                    "a local file cannot be marked Roblox-approved",
                    "Roblox moderation evidence",
                ),
            ),
        )
