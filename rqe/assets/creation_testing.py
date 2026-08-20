"""Deterministic test provider for the asset-creation contracts.

This provider only returns fixture files supplied by a test.  Its capability
level is STATICALLY_VALIDATED and it must never be presented as a real creation
service.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from pathlib import Path
from typing import Mapping

from .creation import (
    CreationProgress,
    CreationProviderCapabilities,
    CreationProviderRequest,
    ProviderCreationOutput,
    ProviderCreationResult,
)
from .models import AssetKind, CapabilityAvailability, PipelineBlocker, PipelineOutcome


@dataclass(frozen=True)
class FixtureCreation:
    path: Path
    media_type: str
    previews: tuple[Path, ...]
    metadata: Mapping[str, object] = field(default_factory=dict)
    is_placeholder: bool = False


class FakeCreationProvider:
    def __init__(
        self,
        *,
        name: str,
        tool: str,
        tool_version: str,
        model: str,
        model_version: str,
        fixtures: Mapping[AssetKind, FixtureCreation],
        availability: CapabilityAvailability = CapabilityAvailability.AVAILABLE,
        blockers: tuple[PipelineBlocker, ...] = (),
        forced_outcome: PipelineOutcome | None = None,
    ):
        self.name = name
        self.tool = tool
        self.tool_version = tool_version
        self.model = model
        self.model_version = model_version
        self.fixtures = dict(fixtures)
        self.availability = availability
        self.blockers = blockers
        self.forced_outcome = forced_outcome
        self.calls: list[CreationProviderRequest] = []

    def capabilities(self) -> CreationProviderCapabilities:
        return CreationProviderCapabilities(
            provider=self.name,
            kinds=tuple(sorted(self.fixtures, key=lambda kind: kind.value)),
            tool=self.tool,
            tool_version=self.tool_version,
            models={self.model: (self.model_version,)},
            availability=self.availability,
            validation_level="STATICALLY_VALIDATED",
            blockers=self.blockers,
        )

    def create(self, request: CreationProviderRequest) -> ProviderCreationResult:
        self.calls.append(request)
        if self.forced_outcome == PipelineOutcome.BLOCKED:
            return ProviderCreationResult(
                PipelineOutcome.BLOCKED,
                CreationProgress.BLOCKED,
                "fixture provider is blocked",
                blockers=self.blockers
                or (PipelineBlocker("fixture_blocked", "fixture provider is blocked"),),
                retryable=True,
            )
        if self.forced_outcome == PipelineOutcome.FAILED:
            return ProviderCreationResult(
                PipelineOutcome.FAILED,
                CreationProgress.FAILED,
                "fixture provider failed",
                blockers=self.blockers
                or (PipelineBlocker("fixture_failed", "fixture provider failed"),),
            )
        fixture = self.fixtures[request.brief.kind]
        return ProviderCreationResult(
            PipelineOutcome.PROGRESSED,
            CreationProgress.COMPLETE,
            "fixture bytes returned for contract testing",
            output=ProviderCreationOutput(
                path=fixture.path,
                media_type=fixture.media_type,
                preview_paths=fixture.previews,
                is_placeholder=fixture.is_placeholder,
                metadata=fixture.metadata,
            ),
            provider_job_id=f"fixture:{request.job_id}",
        )

