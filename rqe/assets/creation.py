"""Content-addressed contracts and coordination for original asset creation.

This module deliberately stops before publication.  A successful creation job
produces a locally validated :class:`AssetRecord` that is ready to enter the
existing publication pipeline.  It never claims that the asset is published,
moderated, integrated, runtime-visible, or production-ready.

Providers are typed adapters.  They may call an in-process implementation or
exchange files with a separate vertical worker, but the coordinator never runs
provider-supplied commands or trusts provider-supplied hashes.
"""

from __future__ import annotations

import hashlib
import json
import mimetypes
import os
import shutil
from contextlib import contextmanager
from dataclasses import dataclass, field, replace
from datetime import datetime, timezone
from enum import Enum
from pathlib import Path
from typing import Any, Callable, Iterator, Mapping, Protocol

from .codec import asset_from_dict
from .models import (
    AssetKind,
    AssetLicense,
    AssetPreview,
    AssetProvenance,
    AssetRecord,
    AssetRequirement,
    AssetState,
    CapabilityAvailability,
    CheckStatus,
    PipelineBlocker,
    PipelineOutcome,
)
from .validation import LocalAssetValidator, sha256_file


BRIEF_SCHEMA_VERSION = 1
RECEIPT_SCHEMA_VERSION = 1
SHA256_PATTERN_LENGTH = 64


class CreationContractError(ValueError):
    """A brief, provider result, receipt, or ledger object is inconsistent."""


class CreationProgress(str, Enum):
    QUEUED = "QUEUED"
    COMPLETE = "COMPLETE"
    BLOCKED = "BLOCKED"
    FAILED = "FAILED"


@dataclass(frozen=True)
class RightsDeclaration:
    name: str
    terms_url: str
    usage_scope: str
    verified: bool
    commercial_use: bool
    evidence: str
    attribution_required: bool = False
    attribution: str | None = None

    def __post_init__(self) -> None:
        _require_text(self.name, "rights.name")
        _require_text(self.terms_url, "rights.termsUrl")
        _require_text(self.usage_scope, "rights.usageScope")
        _require_text(self.evidence, "rights.evidence")
        if self.attribution_required and not (self.attribution or "").strip():
            raise CreationContractError(
                "rights.attribution is required when attributionRequired is true"
            )

    @classmethod
    def from_dict(cls, raw: Mapping[str, Any], *, path: str = "rights") -> "RightsDeclaration":
        _expect_keys(
            raw,
            required={
                "name",
                "termsUrl",
                "usageScope",
                "verified",
                "commercialUse",
                "evidence",
                "attributionRequired",
            },
            allowed={
                "name",
                "termsUrl",
                "usageScope",
                "verified",
                "commercialUse",
                "evidence",
                "attributionRequired",
                "attribution",
            },
            path=path,
        )
        return cls(
            name=_text(raw["name"], f"{path}.name"),
            terms_url=_text(raw["termsUrl"], f"{path}.termsUrl"),
            usage_scope=_text(raw["usageScope"], f"{path}.usageScope"),
            verified=_boolean(raw["verified"], f"{path}.verified"),
            commercial_use=_boolean(raw["commercialUse"], f"{path}.commercialUse"),
            evidence=_text(raw["evidence"], f"{path}.evidence"),
            attribution_required=_boolean(
                raw["attributionRequired"], f"{path}.attributionRequired"
            ),
            attribution=_optional_text(raw.get("attribution"), f"{path}.attribution"),
        )

    def to_dict(self) -> dict[str, Any]:
        result: dict[str, Any] = {
            "name": self.name,
            "termsUrl": self.terms_url,
            "usageScope": self.usage_scope,
            "verified": self.verified,
            "commercialUse": self.commercial_use,
            "evidence": self.evidence,
            "attributionRequired": self.attribution_required,
        }
        if self.attribution is not None:
            result["attribution"] = self.attribution
        return result

    def to_asset_license(self) -> AssetLicense:
        return AssetLicense(
            name=self.name,
            terms_url=self.terms_url,
            usage_scope=self.usage_scope,
            verified=self.verified,
            commercial_use=self.commercial_use,
            attribution_required=self.attribution_required,
            attribution=self.attribution,
            evidence=self.evidence,
        )


@dataclass(frozen=True)
class CreationReference:
    reference_id: str
    uri: str
    sha256: str
    media_type: str
    purpose: str
    source_provider: str
    source_uri: str
    retrieved_at: str
    rights: RightsDeclaration
    creator_id: str | None = None

    def __post_init__(self) -> None:
        for name, value in (
            ("referenceId", self.reference_id),
            ("uri", self.uri),
            ("mediaType", self.media_type),
            ("purpose", self.purpose),
            ("provenance.provider", self.source_provider),
            ("provenance.sourceUri", self.source_uri),
            ("provenance.retrievedAt", self.retrieved_at),
        ):
            _require_text(value, f"references[].{name}")
        _require_sha256(self.sha256, "references[].sha256")

    @classmethod
    def from_dict(cls, raw: Mapping[str, Any], *, index: int) -> "CreationReference":
        path = f"references[{index}]"
        _expect_keys(
            raw,
            required={
                "referenceId",
                "uri",
                "sha256",
                "mediaType",
                "purpose",
                "provenance",
                "rights",
            },
            allowed={
                "referenceId",
                "uri",
                "sha256",
                "mediaType",
                "purpose",
                "provenance",
                "rights",
            },
            path=path,
        )
        provenance = _mapping(raw["provenance"], f"{path}.provenance")
        _expect_keys(
            provenance,
            required={"provider", "sourceUri", "retrievedAt"},
            allowed={"provider", "sourceUri", "retrievedAt", "creatorId"},
            path=f"{path}.provenance",
        )
        return cls(
            reference_id=_text(raw["referenceId"], f"{path}.referenceId"),
            uri=_text(raw["uri"], f"{path}.uri"),
            sha256=_sha256(raw["sha256"], f"{path}.sha256"),
            media_type=_text(raw["mediaType"], f"{path}.mediaType"),
            purpose=_text(raw["purpose"], f"{path}.purpose"),
            source_provider=_text(
                provenance["provider"], f"{path}.provenance.provider"
            ),
            source_uri=_text(
                provenance["sourceUri"], f"{path}.provenance.sourceUri"
            ),
            retrieved_at=_text(
                provenance["retrievedAt"], f"{path}.provenance.retrievedAt"
            ),
            creator_id=_optional_text(
                provenance.get("creatorId"), f"{path}.provenance.creatorId"
            ),
            rights=RightsDeclaration.from_dict(
                _mapping(raw["rights"], f"{path}.rights"), path=f"{path}.rights"
            ),
        )

    def to_dict(self) -> dict[str, Any]:
        provenance: dict[str, Any] = {
            "provider": self.source_provider,
            "sourceUri": self.source_uri,
            "retrievedAt": self.retrieved_at,
        }
        if self.creator_id is not None:
            provenance["creatorId"] = self.creator_id
        return {
            "referenceId": self.reference_id,
            "uri": self.uri,
            "sha256": self.sha256,
            "mediaType": self.media_type,
            "purpose": self.purpose,
            "provenance": provenance,
            "rights": self.rights.to_dict(),
        }


@dataclass(frozen=True)
class GeneratorIdentity:
    prompt: str
    tool: str
    tool_version: str
    model: str
    model_version: str
    seed: int
    negative_prompt: str | None = None

    def __post_init__(self) -> None:
        for name, value in (
            ("prompt", self.prompt),
            ("tool", self.tool),
            ("toolVersion", self.tool_version),
            ("model", self.model),
            ("modelVersion", self.model_version),
        ):
            _require_text(value, f"generation.{name}")
        if isinstance(self.seed, bool) or not isinstance(self.seed, int):
            raise CreationContractError("generation.seed must be an integer")

    @classmethod
    def from_dict(cls, raw: Mapping[str, Any]) -> "GeneratorIdentity":
        _expect_keys(
            raw,
            required={"prompt", "tool", "toolVersion", "model", "modelVersion", "seed"},
            allowed={
                "prompt",
                "negativePrompt",
                "tool",
                "toolVersion",
                "model",
                "modelVersion",
                "seed",
            },
            path="generation",
        )
        seed = raw["seed"]
        if isinstance(seed, bool) or not isinstance(seed, int):
            raise CreationContractError("generation.seed must be an integer")
        return cls(
            prompt=_text(raw["prompt"], "generation.prompt"),
            negative_prompt=_optional_text(
                raw.get("negativePrompt"), "generation.negativePrompt"
            ),
            tool=_text(raw["tool"], "generation.tool"),
            tool_version=_text(raw["toolVersion"], "generation.toolVersion"),
            model=_text(raw["model"], "generation.model"),
            model_version=_text(raw["modelVersion"], "generation.modelVersion"),
            seed=seed,
        )

    def to_dict(self) -> dict[str, Any]:
        result: dict[str, Any] = {
            "prompt": self.prompt,
            "tool": self.tool,
            "toolVersion": self.tool_version,
            "model": self.model,
            "modelVersion": self.model_version,
            "seed": self.seed,
        }
        if self.negative_prompt is not None:
            result["negativePrompt"] = self.negative_prompt
        return result


@dataclass(frozen=True)
class CreationOutputSpec:
    file_name: str
    media_type: str
    validation_profile: str
    require_preview: bool
    placeholder_allowed: bool = False

    def __post_init__(self) -> None:
        for name, value in (
            ("fileName", self.file_name),
            ("mediaType", self.media_type),
            ("validationProfile", self.validation_profile),
        ):
            _require_text(value, f"output.{name}")
        if Path(self.file_name).name != self.file_name:
            raise CreationContractError("output.fileName must be a plain file name")
        if self.placeholder_allowed:
            raise CreationContractError(
                "output.placeholderAllowed must be false for creation jobs"
            )

    @classmethod
    def from_dict(cls, raw: Mapping[str, Any]) -> "CreationOutputSpec":
        _expect_keys(
            raw,
            required={
                "fileName",
                "mediaType",
                "validationProfile",
                "requirePreview",
                "placeholderAllowed",
            },
            allowed={
                "fileName",
                "mediaType",
                "validationProfile",
                "requirePreview",
                "placeholderAllowed",
            },
            path="output",
        )
        return cls(
            file_name=_text(raw["fileName"], "output.fileName"),
            media_type=_text(raw["mediaType"], "output.mediaType"),
            validation_profile=_text(
                raw["validationProfile"], "output.validationProfile"
            ),
            require_preview=_boolean(raw["requirePreview"], "output.requirePreview"),
            placeholder_allowed=_boolean(
                raw["placeholderAllowed"], "output.placeholderAllowed"
            ),
        )

    def to_dict(self) -> dict[str, Any]:
        return {
            "fileName": self.file_name,
            "mediaType": self.media_type,
            "validationProfile": self.validation_profile,
            "requirePreview": self.require_preview,
            "placeholderAllowed": self.placeholder_allowed,
        }


@dataclass(frozen=True)
class CreationBrief:
    brief_id: str
    logical_asset_id: str
    kind: AssetKind
    display_name: str
    description: str
    requirement: AssetRequirement
    provider: str
    generation: GeneratorIdentity
    references: tuple[CreationReference, ...]
    rights: RightsDeclaration
    output: CreationOutputSpec
    metadata: Mapping[str, Any] = field(default_factory=dict)
    schema_version: int = BRIEF_SCHEMA_VERSION

    def __post_init__(self) -> None:
        if self.schema_version != BRIEF_SCHEMA_VERSION:
            raise CreationContractError(
                f"creation brief schemaVersion must be {BRIEF_SCHEMA_VERSION}"
            )
        for name, value in (
            ("briefId", self.brief_id),
            ("asset.logicalId", self.logical_asset_id),
            ("asset.displayName", self.display_name),
            ("asset.description", self.description),
            ("provider", self.provider),
        ):
            _require_text(value, name)
        if not isinstance(self.metadata, Mapping):
            raise CreationContractError("metadata must be an object")
        ids = [item.reference_id for item in self.references]
        if len(ids) != len(set(ids)):
            raise CreationContractError("references[].referenceId must be unique")
        if self.requirement == AssetRequirement.PRODUCTION_REQUIRED and not self.output.require_preview:
            raise CreationContractError(
                "production-required creation briefs must require a preview"
            )

    @classmethod
    def from_dict(cls, raw: Mapping[str, Any]) -> "CreationBrief":
        _expect_keys(
            raw,
            required={
                "schemaVersion",
                "briefId",
                "asset",
                "provider",
                "generation",
                "references",
                "rights",
                "output",
                "metadata",
            },
            allowed={
                "schemaVersion",
                "briefId",
                "asset",
                "provider",
                "generation",
                "references",
                "rights",
                "output",
                "metadata",
            },
            path="brief",
        )
        if raw["schemaVersion"] != BRIEF_SCHEMA_VERSION:
            raise CreationContractError(
                f"creation brief schemaVersion must be {BRIEF_SCHEMA_VERSION}"
            )
        asset = _mapping(raw["asset"], "asset")
        _expect_keys(
            asset,
            required={"logicalId", "kind", "displayName", "description", "requirement"},
            allowed={"logicalId", "kind", "displayName", "description", "requirement"},
            path="asset",
        )
        references_raw = raw["references"]
        if not isinstance(references_raw, list):
            raise CreationContractError("references must be an array")
        metadata = _mapping(raw["metadata"], "metadata")
        try:
            kind = AssetKind(str(asset["kind"]))
            requirement = AssetRequirement(str(asset["requirement"]))
        except ValueError as exc:
            raise CreationContractError(str(exc)) from exc
        return cls(
            schema_version=BRIEF_SCHEMA_VERSION,
            brief_id=_text(raw["briefId"], "briefId"),
            logical_asset_id=_text(asset["logicalId"], "asset.logicalId"),
            kind=kind,
            display_name=_text(asset["displayName"], "asset.displayName"),
            description=_text(asset["description"], "asset.description"),
            requirement=requirement,
            provider=_text(raw["provider"], "provider"),
            generation=GeneratorIdentity.from_dict(
                _mapping(raw["generation"], "generation")
            ),
            references=tuple(
                CreationReference.from_dict(
                    _mapping(item, f"references[{index}]"), index=index
                )
                for index, item in enumerate(references_raw)
            ),
            rights=RightsDeclaration.from_dict(
                _mapping(raw["rights"], "rights"), path="rights"
            ),
            output=CreationOutputSpec.from_dict(_mapping(raw["output"], "output")),
            metadata=dict(metadata),
        )

    def to_dict(self) -> dict[str, Any]:
        return {
            "schemaVersion": self.schema_version,
            "briefId": self.brief_id,
            "asset": {
                "logicalId": self.logical_asset_id,
                "kind": self.kind.value,
                "displayName": self.display_name,
                "description": self.description,
                "requirement": self.requirement.value,
            },
            "provider": self.provider,
            "generation": self.generation.to_dict(),
            "references": [item.to_dict() for item in self.references],
            "rights": self.rights.to_dict(),
            "output": self.output.to_dict(),
            "metadata": dict(self.metadata),
        }

    @property
    def sha256(self) -> str:
        return _canonical_sha256(self.to_dict())

    @property
    def job_id(self) -> str:
        # The exact frozen brief is the job identity.  No timestamp or process
        # identity can turn the same generation request into another job.
        return self.sha256


@dataclass(frozen=True)
class CreationProviderCapabilities:
    provider: str
    kinds: tuple[AssetKind, ...]
    tool: str
    tool_version: str
    models: Mapping[str, tuple[str, ...]]
    availability: CapabilityAvailability
    validation_level: str = "NOT_VALIDATED"
    blockers: tuple[PipelineBlocker, ...] = ()

    def __post_init__(self) -> None:
        _require_text(self.provider, "capabilities.provider")
        if self.availability == CapabilityAvailability.AVAILABLE:
            _require_text(self.tool, "capabilities.tool")
            _require_text(self.tool_version, "capabilities.toolVersion")
        if not isinstance(self.models, Mapping):
            raise CreationContractError("capabilities.models must be an object")

    def to_dict(self) -> dict[str, Any]:
        return {
            "provider": self.provider,
            "kinds": sorted(kind.value for kind in self.kinds),
            "tool": self.tool,
            "toolVersion": self.tool_version,
            "models": {
                model: sorted(versions) for model, versions in sorted(self.models.items())
            },
            "availability": self.availability.value,
            "validationLevel": self.validation_level,
            "blockers": [item.to_dict() for item in self.blockers],
        }

    def check(self, brief: CreationBrief) -> tuple[PipelineBlocker, ...]:
        issues = list(self.blockers)
        if self.availability != CapabilityAvailability.AVAILABLE:
            if not issues:
                issues.append(
                    PipelineBlocker(
                        "creation_provider_unavailable",
                        f"provider {self.provider} is {self.availability.value}",
                    )
                )
            return tuple(issues)
        if brief.kind not in self.kinds:
            issues.append(
                PipelineBlocker(
                    "creation_kind_unsupported",
                    f"provider {self.provider} does not support {brief.kind.value}",
                )
            )
        identity = brief.generation
        if identity.tool != self.tool or identity.tool_version != self.tool_version:
            issues.append(
                PipelineBlocker(
                    "creation_tool_unavailable",
                    (
                        f"brief requires {identity.tool}@{identity.tool_version}; "
                        f"provider exposes {self.tool}@{self.tool_version}"
                    ),
                )
            )
        versions = self.models.get(identity.model)
        if versions is None or identity.model_version not in versions:
            issues.append(
                PipelineBlocker(
                    "creation_model_unavailable",
                    f"provider does not expose {identity.model}@{identity.model_version}",
                )
            )
        return tuple(issues)


@dataclass(frozen=True)
class CreationProviderRequest:
    job_id: str
    brief_sha256: str
    brief: CreationBrief

    def __post_init__(self) -> None:
        _require_sha256(self.job_id, "providerRequest.jobId")
        _require_sha256(self.brief_sha256, "providerRequest.briefSha256")
        if self.job_id != self.brief.job_id or self.brief_sha256 != self.brief.sha256:
            raise CreationContractError("provider request identity does not match its brief")

    def to_dict(self) -> dict[str, Any]:
        return {
            "schemaVersion": 1,
            "jobId": self.job_id,
            "briefSha256": self.brief_sha256,
            "provider": self.brief.provider,
            "brief": self.brief.to_dict(),
        }


@dataclass(frozen=True)
class ProviderCreationOutput:
    path: Path
    media_type: str
    preview_paths: tuple[Path, ...]
    is_placeholder: bool
    metadata: Mapping[str, Any] = field(default_factory=dict)

    def __post_init__(self) -> None:
        _require_text(self.media_type, "providerOutput.mediaType")
        if not isinstance(self.is_placeholder, bool):
            raise CreationContractError("providerOutput.isPlaceholder must be boolean")
        if not isinstance(self.metadata, Mapping):
            raise CreationContractError("providerOutput.metadata must be an object")


@dataclass(frozen=True)
class ProviderCreationResult:
    outcome: PipelineOutcome
    status: CreationProgress
    message: str
    output: ProviderCreationOutput | None = None
    blockers: tuple[PipelineBlocker, ...] = ()
    provider_job_id: str | None = None
    retryable: bool = False

    def __post_init__(self) -> None:
        _require_text(self.message, "providerResult.message")
        expected = {
            PipelineOutcome.PROGRESSED: {CreationProgress.QUEUED, CreationProgress.COMPLETE},
            PipelineOutcome.BLOCKED: {CreationProgress.BLOCKED},
            PipelineOutcome.FAILED: {CreationProgress.FAILED},
        }
        if self.outcome not in expected:
            raise CreationContractError(
                "creation providers may return only PROGRESSED, BLOCKED, or FAILED"
            )
        if self.status not in expected[self.outcome]:
            raise CreationContractError(
                f"provider outcome {self.outcome.value} is inconsistent with {self.status.value}"
            )
        if self.status == CreationProgress.COMPLETE and self.output is None:
            raise CreationContractError("COMPLETE provider results require an output")
        if self.status != CreationProgress.COMPLETE and self.output is not None:
            raise CreationContractError(
                f"{self.status.value} provider results cannot carry an output"
            )


class CreationProvider(Protocol):
    name: str

    def capabilities(self) -> CreationProviderCapabilities: ...

    def create(self, request: CreationProviderRequest) -> ProviderCreationResult: ...


class CreationProviderRegistry:
    """Explicit provider registry; no implicit fallback provider exists."""

    def __init__(self, providers: tuple[CreationProvider, ...] = ()):
        self._providers: dict[str, CreationProvider] = {}
        for provider in providers:
            self.register(provider)

    def register(self, provider: CreationProvider) -> None:
        name = _require_text(provider.name, "provider.name")
        if name in self._providers:
            raise CreationContractError(f"creation provider {name!r} is already registered")
        capabilities = provider.capabilities()
        if capabilities.provider != name:
            raise CreationContractError(
                f"provider {name!r} returned capabilities for {capabilities.provider!r}"
            )
        self._providers[name] = provider

    def get(self, name: str) -> CreationProvider | None:
        return self._providers.get(name)

    def capabilities(self) -> tuple[CreationProviderCapabilities, ...]:
        return tuple(
            self._providers[name].capabilities() for name in sorted(self._providers)
        )


@dataclass(frozen=True)
class CreationReceipt:
    receipt_id: str
    job_id: str
    brief_sha256: str
    provider: str
    recorded_at: str
    outcome: PipelineOutcome
    status: CreationProgress
    message: str
    generator: Mapping[str, Any]
    rights: Mapping[str, Any]
    references: tuple[Mapping[str, Any], ...]
    blockers: tuple[Mapping[str, Any], ...]
    retryable: bool
    output: Mapping[str, Any] | None = None
    provider_job_id: str | None = None
    schema_version: int = RECEIPT_SCHEMA_VERSION

    @classmethod
    def build(
        cls,
        *,
        brief: CreationBrief,
        outcome: PipelineOutcome,
        status: CreationProgress,
        message: str,
        recorded_at: str,
        blockers: tuple[PipelineBlocker, ...] = (),
        retryable: bool = False,
        output: Mapping[str, Any] | None = None,
        provider_job_id: str | None = None,
    ) -> "CreationReceipt":
        base = {
            "schemaVersion": RECEIPT_SCHEMA_VERSION,
            "jobId": brief.job_id,
            "briefSha256": brief.sha256,
            "provider": brief.provider,
            "recordedAt": recorded_at,
            "outcome": outcome.value,
            "status": status.value,
            "message": message,
            "generator": brief.generation.to_dict(),
            "rights": brief.rights.to_dict(),
            "references": [item.to_dict() for item in brief.references],
            "blockers": [item.to_dict() for item in blockers],
            "retryable": retryable,
            "productionReady": False,
        }
        if output is not None:
            base["output"] = dict(output)
        if provider_job_id is not None:
            base["providerJobId"] = provider_job_id
        payload = {"receiptId": _canonical_sha256(base), **base}
        return cls.from_dict(payload)

    @classmethod
    def from_dict(cls, raw: Mapping[str, Any]) -> "CreationReceipt":
        required = {
            "schemaVersion",
            "receiptId",
            "jobId",
            "briefSha256",
            "provider",
            "recordedAt",
            "outcome",
            "status",
            "message",
            "generator",
            "rights",
            "references",
            "blockers",
            "retryable",
            "productionReady",
        }
        _expect_keys(
            raw,
            required=required,
            allowed=required | {"providerJobId", "output"},
            path="receipt",
        )
        if raw["schemaVersion"] != RECEIPT_SCHEMA_VERSION:
            raise CreationContractError(
                f"creation receipt schemaVersion must be {RECEIPT_SCHEMA_VERSION}"
            )
        if raw["productionReady"] is not False:
            raise CreationContractError(
                "a creation receipt alone can never set productionReady=true"
            )
        receipt_id = _sha256(raw["receiptId"], "receipt.receiptId")
        identity = dict(raw)
        identity.pop("receiptId", None)
        if _canonical_sha256(identity) != receipt_id:
            raise CreationContractError("creation receipt identity hash is inconsistent")
        try:
            outcome = PipelineOutcome(str(raw["outcome"]))
            status = CreationProgress(str(raw["status"]))
        except ValueError as exc:
            raise CreationContractError(str(exc)) from exc
        generator = _mapping(raw["generator"], "receipt.generator")
        rights = _mapping(raw["rights"], "receipt.rights")
        references = _mapping_sequence(raw["references"], "receipt.references")
        blockers = _mapping_sequence(raw["blockers"], "receipt.blockers")
        # Receipts are executable handoff contracts, not loose audit blobs.
        # Re-parse the copied brief fields so a self-consistent hash cannot
        # make a structurally invalid generator or rights claim admissible.
        GeneratorIdentity.from_dict(generator)
        RightsDeclaration.from_dict(rights, path="receipt.rights")
        for index, reference in enumerate(references):
            CreationReference.from_dict(reference, index=index)
        output_raw = raw.get("output")
        output = None if output_raw is None else dict(_mapping(output_raw, "receipt.output"))
        if status == CreationProgress.COMPLETE:
            if outcome != PipelineOutcome.PROGRESSED or output is None:
                raise CreationContractError("COMPLETE receipt requires PROGRESSED output")
            if output.get("readyForPublication") is not True:
                raise CreationContractError(
                    "COMPLETE receipt output must be readyForPublication"
                )
        elif output is not None:
            raise CreationContractError(
                f"{status.value} creation receipts cannot contain output"
            )
        expected_status = {
            PipelineOutcome.PROGRESSED: {CreationProgress.QUEUED, CreationProgress.COMPLETE},
            PipelineOutcome.BLOCKED: {CreationProgress.BLOCKED},
            PipelineOutcome.FAILED: {CreationProgress.FAILED},
        }
        if outcome not in expected_status or status not in expected_status[outcome]:
            raise CreationContractError("creation receipt outcome/status is inconsistent")
        job_id = _sha256(raw["jobId"], "receipt.jobId")
        brief_sha256 = _sha256(raw["briefSha256"], "receipt.briefSha256")
        if job_id != brief_sha256:
            raise CreationContractError(
                "creation receipt jobId must equal its content-addressed briefSha256"
            )
        return cls(
            schema_version=RECEIPT_SCHEMA_VERSION,
            receipt_id=receipt_id,
            job_id=job_id,
            brief_sha256=brief_sha256,
            provider=_text(raw["provider"], "receipt.provider"),
            recorded_at=_text(raw["recordedAt"], "receipt.recordedAt"),
            outcome=outcome,
            status=status,
            message=_text(raw["message"], "receipt.message"),
            generator=dict(generator),
            rights=dict(rights),
            references=tuple(dict(item) for item in references),
            blockers=tuple(dict(item) for item in blockers),
            retryable=_boolean(raw["retryable"], "receipt.retryable"),
            output=output,
            provider_job_id=_optional_text(
                raw.get("providerJobId"), "receipt.providerJobId"
            ),
        )

    def to_dict(self) -> dict[str, Any]:
        result: dict[str, Any] = {
            "schemaVersion": self.schema_version,
            "receiptId": self.receipt_id,
            "jobId": self.job_id,
            "briefSha256": self.brief_sha256,
            "provider": self.provider,
            "recordedAt": self.recorded_at,
            "outcome": self.outcome.value,
            "status": self.status.value,
            "message": self.message,
            "generator": dict(self.generator),
            "rights": dict(self.rights),
            "references": [dict(item) for item in self.references],
            "blockers": [dict(item) for item in self.blockers],
            "retryable": self.retryable,
            "productionReady": False,
        }
        if self.provider_job_id is not None:
            result["providerJobId"] = self.provider_job_id
        if self.output is not None:
            result["output"] = dict(self.output)
        return result


@dataclass(frozen=True)
class CreationExecution:
    outcome: PipelineOutcome
    receipt: CreationReceipt
    blockers: tuple[PipelineBlocker, ...] = ()
    asset: AssetRecord | None = None
    cached: bool = False

    @property
    def ready_for_publication(self) -> bool:
        return (
            self.receipt.status == CreationProgress.COMPLETE
            and self.receipt.output is not None
            and self.receipt.output.get("readyForPublication") is True
            and self.asset is not None
            and self.asset.state == AssetState.VALIDATED
        )

    @property
    def production_ready(self) -> bool:
        # Creation is only one stage.  Publication, moderation, integration,
        # and runtime verification are outside this receipt's authority.
        return False


class CreationLedger:
    """Immutable per-job briefs, receipts, and content-addressed payloads."""

    def __init__(self, root: Path):
        self.root = root
        self.jobs = root / "jobs"
        self.objects = root / "objects"
        self.locks = root / "locks"
        for directory in (self.jobs, self.objects, self.locks):
            directory.mkdir(parents=True, exist_ok=True)

    def stage_brief(self, brief: CreationBrief) -> None:
        directory = self.jobs / _safe_sha256(brief.job_id)
        directory.mkdir(parents=True, exist_ok=True)
        path = directory / "brief.json"
        _write_once_json(path, brief.to_dict())
        stored = json.loads(path.read_text(encoding="utf-8"))
        if _canonical_sha256(stored) != brief.sha256:
            raise CreationContractError("stored creation brief was altered")

    def stage_file(self, source: Path) -> dict[str, Any]:
        if not source.is_file():
            raise CreationContractError(f"creation output does not exist: {source}")
        if source.stat().st_size <= 0:
            raise CreationContractError(f"creation output is empty: {source}")
        source_hash = sha256_file(source)
        suffix = source.suffix.lower()
        if not suffix or any(not (character.isalnum() or character == ".") for character in suffix):
            raise CreationContractError("creation output extension is unsafe")
        destination = self.objects / f"{source_hash}{suffix}"
        if destination.is_file():
            if sha256_file(destination) != source_hash:
                raise CreationContractError("content-addressed creation object was altered")
        else:
            temporary = destination.with_name(f".{destination.name}.{os.getpid()}.tmp")
            shutil.copyfile(source, temporary)
            if sha256_file(temporary) != source_hash:
                temporary.unlink(missing_ok=True)
                raise CreationContractError("creation source changed while staging")
            try:
                os.link(temporary, destination)
            except FileExistsError:
                if sha256_file(destination) != source_hash:
                    raise CreationContractError("creation object identity collision")
            finally:
                temporary.unlink(missing_ok=True)
        return {
            "path": destination.relative_to(self.root).as_posix(),
            "sha256": source_hash,
            "byteLength": destination.stat().st_size,
        }

    def record(self, receipt: CreationReceipt, *, complete: bool = False) -> None:
        directory = self.jobs / _safe_sha256(receipt.job_id)
        receipts = directory / "receipts"
        receipts.mkdir(parents=True, exist_ok=True)
        path = receipts / f"{_safe_sha256(receipt.receipt_id)}.json"
        _write_once_json(path, receipt.to_dict())
        if complete:
            marker = {
                "schemaVersion": 1,
                "jobId": receipt.job_id,
                "receiptId": receipt.receipt_id,
                "receiptSha256": sha256_file(path),
            }
            _write_once_json(directory / "complete.json", marker)

    def load_completed(self, job_id: str) -> CreationReceipt | None:
        directory = self.jobs / _safe_sha256(job_id)
        marker_path = directory / "complete.json"
        if not marker_path.is_file():
            return None
        marker = json.loads(marker_path.read_text(encoding="utf-8"))
        _expect_keys(
            marker,
            required={"schemaVersion", "jobId", "receiptId", "receiptSha256"},
            allowed={"schemaVersion", "jobId", "receiptId", "receiptSha256"},
            path="completion",
        )
        if marker["schemaVersion"] != 1 or marker["jobId"] != job_id:
            raise CreationContractError("creation completion marker is inconsistent")
        receipt_id = _sha256(marker["receiptId"], "completion.receiptId")
        receipt_path = directory / "receipts" / f"{receipt_id}.json"
        if not receipt_path.is_file():
            raise CreationContractError("creation completion receipt is missing")
        if sha256_file(receipt_path) != _sha256(
            marker["receiptSha256"], "completion.receiptSha256"
        ):
            raise CreationContractError("creation completion receipt was altered")
        receipt = CreationReceipt.from_dict(
            json.loads(receipt_path.read_text(encoding="utf-8"))
        )
        if receipt.job_id != job_id or receipt.receipt_id != receipt_id:
            raise CreationContractError("creation completion identity is inconsistent")
        self.verify_artifacts(receipt)
        return receipt

    def verify_artifacts(self, receipt: CreationReceipt) -> None:
        if receipt.output is None:
            return
        artifact = _mapping(receipt.output.get("artifact"), "receipt.output.artifact")
        self._verify_artifact(artifact, "receipt.output.artifact")
        previews = _mapping_sequence(
            receipt.output.get("previews"), "receipt.output.previews"
        )
        for index, preview in enumerate(previews):
            self._verify_artifact(preview, f"receipt.output.previews[{index}]")

    def absolute_object_path(self, relative: str) -> Path:
        return _resolve_beneath(self.root, relative)

    def _verify_artifact(self, raw: Mapping[str, Any], path: str) -> None:
        target = _resolve_beneath(self.root, _text(raw.get("path"), f"{path}.path"))
        expected = _sha256(raw.get("sha256"), f"{path}.sha256")
        if not target.is_file():
            raise CreationContractError(f"{path} resource is missing")
        if sha256_file(target) != expected:
            raise CreationContractError(f"{path} resource hash is inconsistent")
        size = raw.get("byteLength")
        if isinstance(size, bool) or not isinstance(size, int) or size <= 0:
            raise CreationContractError(f"{path}.byteLength must be a positive integer")
        if target.stat().st_size != size:
            raise CreationContractError(f"{path} resource length is inconsistent")

    @contextmanager
    def claim(self, job_id: str) -> Iterator[bool]:
        path = self.locks / f"{_safe_sha256(job_id)}.lock"
        try:
            descriptor = os.open(path, os.O_CREAT | os.O_EXCL | os.O_WRONLY)
        except FileExistsError:
            yield False
            return
        try:
            with os.fdopen(descriptor, "w", encoding="utf-8") as stream:
                json.dump({"pid": os.getpid()}, stream)
            yield True
        finally:
            path.unlink(missing_ok=True)


class CreationCoordinator:
    """Route one frozen brief and validate exact provider output bytes."""

    def __init__(
        self,
        registry: CreationProviderRegistry,
        ledger: CreationLedger,
        *,
        validator: LocalAssetValidator | None = None,
        clock: Callable[[], str] | None = None,
    ):
        self.registry = registry
        self.ledger = ledger
        self.validator = validator or LocalAssetValidator()
        self.clock = clock or _now

    def execute(self, brief: CreationBrief) -> CreationExecution:
        try:
            self.ledger.stage_brief(brief)
            completed = self.ledger.load_completed(brief.job_id)
        except (OSError, ValueError, json.JSONDecodeError) as exc:
            return self._failure(brief, "creation_ledger_invalid", str(exc))
        if completed is not None:
            try:
                asset = self._asset_from_receipt(completed)
            except (KeyError, TypeError, ValueError) as exc:
                return self._failure(
                    brief, "creation_receipt_asset_invalid", str(exc)
                )
            return CreationExecution(
                completed.outcome,
                completed,
                _blockers_from_receipt(completed),
                asset=asset,
                cached=True,
            )

        provider = self.registry.get(brief.provider)
        if provider is None:
            return self._blocked(
                brief,
                (
                    PipelineBlocker(
                        "creation_provider_unavailable",
                        f"creation provider {brief.provider!r} is not registered",
                    ),
                ),
            )
        capability_blockers = provider.capabilities().check(brief)
        if capability_blockers:
            return self._blocked(brief, capability_blockers)
        rights_blockers = self._rights_blockers(brief)
        if rights_blockers:
            return self._blocked(brief, rights_blockers)

        with self.ledger.claim(brief.job_id) as acquired:
            if not acquired:
                return self._blocked(
                    brief,
                    (
                        PipelineBlocker(
                            "creation_job_in_progress",
                            "another process owns this content-addressed creation job",
                        ),
                    ),
                    retryable=True,
                )
            try:
                completed = self.ledger.load_completed(brief.job_id)
                if completed is not None:
                    return CreationExecution(
                        completed.outcome,
                        completed,
                        _blockers_from_receipt(completed),
                        asset=self._asset_from_receipt(completed),
                        cached=True,
                    )
                provider_result = provider.create(
                    CreationProviderRequest(brief.job_id, brief.sha256, brief)
                )
            except (OSError, ValueError, json.JSONDecodeError) as exc:
                return self._failure(brief, "creation_provider_failed", str(exc))

            if provider_result.outcome == PipelineOutcome.BLOCKED:
                return self._blocked(
                    brief,
                    provider_result.blockers
                    or (
                        PipelineBlocker(
                            "creation_provider_blocked", provider_result.message
                        ),
                    ),
                    message=provider_result.message,
                    provider_job_id=provider_result.provider_job_id,
                    retryable=provider_result.retryable,
                )
            if provider_result.outcome == PipelineOutcome.FAILED:
                return self._failure(
                    brief,
                    "creation_provider_failed",
                    provider_result.message,
                    blockers=provider_result.blockers,
                    provider_job_id=provider_result.provider_job_id,
                    retryable=provider_result.retryable,
                )
            if provider_result.status == CreationProgress.QUEUED:
                receipt = CreationReceipt.build(
                    brief=brief,
                    outcome=PipelineOutcome.PROGRESSED,
                    status=CreationProgress.QUEUED,
                    message=provider_result.message,
                    recorded_at=self.clock(),
                    blockers=provider_result.blockers,
                    retryable=True,
                    provider_job_id=provider_result.provider_job_id,
                )
                self.ledger.record(receipt)
                return CreationExecution(
                    PipelineOutcome.PROGRESSED,
                    receipt,
                    provider_result.blockers,
                )
            return self._complete(brief, provider_result)

    def _complete(
        self, brief: CreationBrief, provider_result: ProviderCreationResult
    ) -> CreationExecution:
        candidate = provider_result.output
        if candidate is None:
            return self._failure(
                brief,
                "creation_output_missing",
                "provider reported completion without an output",
                provider_job_id=provider_result.provider_job_id,
            )
        if candidate.is_placeholder:
            return self._failure(
                brief,
                "creation_placeholder_forbidden",
                "provider output is explicitly marked as a placeholder",
                provider_job_id=provider_result.provider_job_id,
            )
        expected_suffix = Path(brief.output.file_name).suffix.casefold()
        if candidate.path.suffix.casefold() != expected_suffix:
            return self._failure(
                brief,
                "creation_output_extension_mismatch",
                f"provider output must use {expected_suffix}",
                provider_job_id=provider_result.provider_job_id,
            )
        if candidate.media_type != brief.output.media_type:
            return self._failure(
                brief,
                "creation_output_media_type_mismatch",
                f"provider returned {candidate.media_type!r}, expected {brief.output.media_type!r}",
                provider_job_id=provider_result.provider_job_id,
            )
        if brief.output.require_preview and not candidate.preview_paths:
            return self._failure(
                brief,
                "creation_preview_missing",
                "the creation brief requires at least one preview resource",
                provider_job_id=provider_result.provider_job_id,
            )

        try:
            artifact = self.ledger.stage_file(candidate.path)
            artifact["mediaType"] = candidate.media_type
            preview_artifacts: list[dict[str, Any]] = []
            for path in candidate.preview_paths:
                preview = self.ledger.stage_file(path)
                preview["mediaType"] = (
                    mimetypes.guess_type(path.name)[0] or "application/octet-stream"
                )
                preview_artifacts.append(preview)
        except (OSError, ValueError) as exc:
            return self._failure(
                brief,
                "creation_resource_invalid",
                str(exc),
                provider_job_id=provider_result.provider_job_id,
            )

        stored_path = self.ledger.absolute_object_path(str(artifact["path"]))
        previews = tuple(
            AssetPreview(
                uri=f"creation://{brief.job_id}/{item['path']}",
                media_type=str(item["mediaType"]),
                label=f"creation preview {index + 1}",
                sha256=str(item["sha256"]),
            )
            for index, item in enumerate(preview_artifacts)
        )
        metadata = {
            **dict(brief.metadata),
            **dict(candidate.metadata),
            "creation": {
                "briefId": brief.brief_id,
                "briefSha256": brief.sha256,
                "jobId": brief.job_id,
                "provider": brief.provider,
                "tool": brief.generation.tool,
                "toolVersion": brief.generation.tool_version,
                "model": brief.generation.model,
                "modelVersion": brief.generation.model_version,
                "seed": brief.generation.seed,
                "referenceHashes": [item.sha256 for item in brief.references],
                "isPlaceholder": False,
            },
        }
        draft = AssetRecord(
            logical_id=brief.logical_asset_id,
            kind=brief.kind,
            display_name=brief.display_name,
            description=brief.description,
            state=AssetState.DRAFT,
            provider="local-creation",
            requirement=brief.requirement,
            previews=previews,
            license=brief.rights.to_asset_license(),
            provenance=AssetProvenance(
                provider=brief.provider,
                source_uri=f"creation://jobs/{brief.job_id}",
                retrieved_at=self.clock(),
                content_sha256=str(artifact["sha256"]),
                operation_id=provider_result.provider_job_id,
                tool=f"{brief.generation.tool}@{brief.generation.tool_version}",
                prompt=brief.generation.prompt,
            ),
            local_path=str(stored_path),
            content_type=candidate.media_type,
            metadata=metadata,
        )
        report = self.validator.validate(draft)
        if not report.ok or report.asset.state != AssetState.VALIDATED:
            failed = any(check.status == CheckStatus.FAIL for check in report.checks)
            outcome = PipelineOutcome.FAILED if failed else PipelineOutcome.BLOCKED
            status = CreationProgress.FAILED if failed else CreationProgress.BLOCKED
            blockers = tuple(
                PipelineBlocker(check.code, check.message)
                for check in report.checks
                if check.status in {CheckStatus.FAIL, CheckStatus.BLOCKED}
            )
            receipt = CreationReceipt.build(
                brief=brief,
                outcome=outcome,
                status=status,
                message="created bytes did not satisfy the type-specific validation profile",
                recorded_at=self.clock(),
                blockers=blockers,
                retryable=False,
                provider_job_id=provider_result.provider_job_id,
            )
            self.ledger.record(receipt)
            return CreationExecution(outcome, receipt, blockers)

        # Store a portable record in the receipt.  Consumers materialize the
        # absolute local path through _asset_from_receipt; the path itself is
        # constrained to the ledger's content-addressed object store.
        asset_payload = report.asset.to_dict()
        asset_payload["localPath"] = artifact["path"]
        output = {
            "readyForPublication": True,
            "validationLevel": "STATICALLY_VALIDATED",
            "artifact": artifact,
            "previews": preview_artifacts,
            "asset": asset_payload,
            "validationProfile": brief.output.validation_profile,
            "validationChecks": [item.to_dict() for item in report.checks],
        }
        receipt = CreationReceipt.build(
            brief=brief,
            outcome=PipelineOutcome.PROGRESSED,
            status=CreationProgress.COMPLETE,
            message="creation output is hash-bound and ready for publication",
            recorded_at=self.clock(),
            blockers=provider_result.blockers,
            retryable=False,
            output=output,
            provider_job_id=provider_result.provider_job_id,
        )
        self.ledger.record(receipt, complete=True)
        return CreationExecution(
            PipelineOutcome.PROGRESSED,
            receipt,
            provider_result.blockers,
            asset=replace(report.asset, local_path=str(stored_path)),
        )

    def _asset_from_receipt(self, receipt: CreationReceipt) -> AssetRecord:
        if receipt.output is None:
            raise CreationContractError("completed creation receipt has no output")
        raw = dict(_mapping(receipt.output.get("asset"), "receipt.output.asset"))
        artifact = _mapping(receipt.output.get("artifact"), "receipt.output.artifact")
        raw["localPath"] = str(
            self.ledger.absolute_object_path(
                _text(artifact.get("path"), "receipt.output.artifact.path")
            )
        )
        asset = asset_from_dict(raw)
        if asset.state != AssetState.VALIDATED:
            raise CreationContractError("completed creation asset is not validated")
        expected_hash = _sha256(
            artifact.get("sha256"), "receipt.output.artifact.sha256"
        )
        if asset.provenance is None or asset.provenance.content_sha256 != expected_hash:
            raise CreationContractError(
                "completed creation asset provenance is not bound to its artifact"
            )
        return asset

    def _rights_blockers(self, brief: CreationBrief) -> tuple[PipelineBlocker, ...]:
        blockers: list[PipelineBlocker] = []
        if not brief.rights.verified or not brief.rights.commercial_use:
            blockers.append(
                PipelineBlocker(
                    "creation_rights_unverified",
                    "output rights must be verified for commercial Roblox use",
                )
            )
        for reference in brief.references:
            if not reference.rights.verified or not reference.rights.commercial_use:
                blockers.append(
                    PipelineBlocker(
                        "creation_reference_rights_unverified",
                        f"reference {reference.reference_id!r} lacks verified commercial rights",
                    )
                )
        return tuple(blockers)

    def _blocked(
        self,
        brief: CreationBrief,
        blockers: tuple[PipelineBlocker, ...],
        *,
        message: str = "asset creation is blocked",
        provider_job_id: str | None = None,
        retryable: bool = True,
    ) -> CreationExecution:
        receipt = CreationReceipt.build(
            brief=brief,
            outcome=PipelineOutcome.BLOCKED,
            status=CreationProgress.BLOCKED,
            message=message,
            recorded_at=self.clock(),
            blockers=blockers,
            retryable=retryable,
            provider_job_id=provider_job_id,
        )
        try:
            self.ledger.record(receipt)
        except (OSError, ValueError):
            pass
        return CreationExecution(PipelineOutcome.BLOCKED, receipt, blockers)

    def _failure(
        self,
        brief: CreationBrief,
        code: str,
        message: str,
        *,
        blockers: tuple[PipelineBlocker, ...] = (),
        provider_job_id: str | None = None,
        retryable: bool = False,
    ) -> CreationExecution:
        actual = blockers or (PipelineBlocker(code, message),)
        receipt = CreationReceipt.build(
            brief=brief,
            outcome=PipelineOutcome.FAILED,
            status=CreationProgress.FAILED,
            message=message or "asset creation failed",
            recorded_at=self.clock(),
            blockers=actual,
            retryable=retryable,
            provider_job_id=provider_job_id,
        )
        try:
            self.ledger.record(receipt)
        except (OSError, ValueError):
            pass
        return CreationExecution(PipelineOutcome.FAILED, receipt, actual)


def _blockers_from_receipt(receipt: CreationReceipt) -> tuple[PipelineBlocker, ...]:
    return tuple(
        PipelineBlocker(
            str(item.get("code", "creation_unknown")),
            str(item.get("message", "")),
            str(item["requirement"]) if item.get("requirement") is not None else None,
        )
        for item in receipt.blockers
    )


def _now() -> str:
    return datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")


def _canonical_json(value: Any) -> bytes:
    return json.dumps(
        value, sort_keys=True, ensure_ascii=False, separators=(",", ":")
    ).encode("utf-8")


def _canonical_sha256(value: Any) -> str:
    return hashlib.sha256(_canonical_json(value)).hexdigest()


def _require_sha256(value: str, path: str) -> str:
    if (
        not isinstance(value, str)
        or len(value) != SHA256_PATTERN_LENGTH
        or any(character not in "0123456789abcdef" for character in value)
    ):
        raise CreationContractError(f"{path} must be a lowercase SHA-256 digest")
    return value


def _safe_sha256(value: str) -> str:
    return _require_sha256(value, "id")


def _sha256(value: Any, path: str) -> str:
    if not isinstance(value, str):
        raise CreationContractError(f"{path} must be a string")
    return _require_sha256(value, path)


def _require_text(value: Any, path: str) -> str:
    if not isinstance(value, str) or not value.strip():
        raise CreationContractError(f"{path} must be a non-empty string")
    return value


def _text(value: Any, path: str) -> str:
    return _require_text(value, path)


def _optional_text(value: Any, path: str) -> str | None:
    if value is None:
        return None
    return _text(value, path)


def _boolean(value: Any, path: str) -> bool:
    if not isinstance(value, bool):
        raise CreationContractError(f"{path} must be boolean")
    return value


def _mapping(value: Any, path: str) -> Mapping[str, Any]:
    if not isinstance(value, Mapping):
        raise CreationContractError(f"{path} must be an object")
    return value


def _mapping_sequence(value: Any, path: str) -> tuple[Mapping[str, Any], ...]:
    if not isinstance(value, list):
        raise CreationContractError(f"{path} must be an array")
    result: list[Mapping[str, Any]] = []
    for index, item in enumerate(value):
        result.append(_mapping(item, f"{path}[{index}]"))
    return tuple(result)


def _expect_keys(
    raw: Mapping[str, Any],
    *,
    required: set[str],
    allowed: set[str],
    path: str,
) -> None:
    missing = required - set(raw)
    extras = set(raw) - allowed
    if missing:
        raise CreationContractError(
            f"{path} is missing required field(s): {', '.join(sorted(missing))}"
        )
    if extras:
        raise CreationContractError(
            f"{path} has unknown field(s): {', '.join(sorted(extras))}"
        )


def _write_once_json(path: Path, payload: Mapping[str, Any]) -> None:
    encoded = json.dumps(
        payload, indent=2, sort_keys=True, ensure_ascii=False
    ).encode("utf-8") + b"\n"
    path.parent.mkdir(parents=True, exist_ok=True)
    try:
        descriptor = os.open(path, os.O_CREAT | os.O_EXCL | os.O_WRONLY)
    except FileExistsError:
        existing = path.read_bytes()
        if existing != encoded:
            raise CreationContractError(f"immutable creation artifact changed: {path}")
        return
    with os.fdopen(descriptor, "wb") as stream:
        stream.write(encoded)


def _resolve_beneath(root: Path, relative: str) -> Path:
    candidate = Path(relative)
    if candidate.is_absolute():
        raise CreationContractError("creation artifact path must be relative")
    resolved_root = root.resolve()
    resolved = (resolved_root / candidate).resolve()
    try:
        resolved.relative_to(resolved_root)
    except ValueError as exc:
        raise CreationContractError("creation artifact path escapes its ledger") from exc
    return resolved
