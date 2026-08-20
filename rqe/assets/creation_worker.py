"""Filesystem outbox adapter for a separately operated creation worker.

The adapter is intentionally passive: it writes a typed request and reads a
typed result.  It never accepts a command line, imports provider code, or starts
a subprocess.  A Blender/audio/animation/image service can therefore run under
its own account and sandbox while RQE retains content identity and validation.
"""

from __future__ import annotations

import json
import os
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Mapping

from .creation import (
    CreationContractError,
    CreationProgress,
    CreationProviderCapabilities,
    CreationProviderRequest,
    ProviderCreationOutput,
    ProviderCreationResult,
)
from .models import (
    AssetKind,
    CapabilityAvailability,
    PipelineBlocker,
    PipelineOutcome,
)


@dataclass(frozen=True)
class WorkerOutboxConfig:
    name: str
    root: Path
    kinds: tuple[AssetKind, ...]
    tool: str
    tool_version: str
    models: Mapping[str, tuple[str, ...]]
    tool_ready: bool
    credentials_ready: bool
    credential_reference: str | None = None
    validation_level: str = "NOT_VALIDATED"

    def __post_init__(self) -> None:
        if not self.name.strip():
            raise CreationContractError("worker provider name is required")
        if not isinstance(self.models, Mapping):
            raise CreationContractError("worker provider models must be an object")
        if self.credentials_ready and not (self.credential_reference or "").strip():
            raise CreationContractError(
                "credential_reference is required when credentials_ready is true"
            )


class WorkerOutboxCreationProvider:
    """Exchange idempotent jobs with an external, allowlisted worker."""

    def __init__(self, config: WorkerOutboxConfig):
        self.config = config
        self.name = config.name
        self.pending = config.root / "pending"
        self.results = config.root / "results"
        self.output = config.root / "worker-output"
        for directory in (self.pending, self.results, self.output):
            directory.mkdir(parents=True, exist_ok=True)

    def capabilities(self) -> CreationProviderCapabilities:
        blockers: list[PipelineBlocker] = []
        if not self.config.tool_ready:
            blockers.append(
                PipelineBlocker(
                    "creation_tool_unavailable",
                    "the configured vertical creation tool is not ready",
                    "tool_ready",
                )
            )
        if not self.config.credentials_ready:
            blockers.append(
                PipelineBlocker(
                    "creation_credentials_missing",
                    "the vertical creation worker has no configured credential reference",
                    "credentials_ready",
                )
            )
        availability = (
            CapabilityAvailability.AVAILABLE
            if not blockers
            else CapabilityAvailability.BLOCKED
        )
        return CreationProviderCapabilities(
            provider=self.name,
            kinds=self.config.kinds,
            tool=self.config.tool,
            tool_version=self.config.tool_version,
            models=self.config.models,
            availability=availability,
            validation_level=self.config.validation_level,
            blockers=tuple(blockers),
        )

    def create(self, request: CreationProviderRequest) -> ProviderCreationResult:
        result_path = self.results / f"{request.job_id}.json"
        if result_path.is_file():
            return self._read_result(request, result_path)

        request_path = self.pending / f"{request.job_id}.json"
        payload = {
            **request.to_dict(),
            "workerContract": {
                "schemaVersion": 1,
                "resultPath": f"results/{request.job_id}.json",
                "outputRoot": "worker-output",
                "allowedOutcomes": ["PROGRESSED", "BLOCKED", "FAILED"],
            },
            # Only an opaque reference is exported.  Secret material never
            # enters a content-addressed job artifact.
            "credentialReference": self.config.credential_reference,
        }
        _write_once_json(request_path, payload)
        return ProviderCreationResult(
            PipelineOutcome.PROGRESSED,
            CreationProgress.QUEUED,
            "creation request is queued for the external worker",
            provider_job_id=request.job_id,
            retryable=True,
        )

    def _read_result(
        self, request: CreationProviderRequest, path: Path
    ) -> ProviderCreationResult:
        try:
            raw = json.loads(path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError) as exc:
            raise CreationContractError(f"worker result is unreadable: {exc}") from exc
        if not isinstance(raw, Mapping):
            raise CreationContractError("worker result must be an object")
        allowed = {
            "schemaVersion",
            "jobId",
            "briefSha256",
            "provider",
            "outcome",
            "status",
            "message",
            "providerJobId",
            "retryable",
            "blockers",
            "output",
        }
        required = {
            "schemaVersion",
            "jobId",
            "briefSha256",
            "provider",
            "outcome",
            "status",
            "message",
            "retryable",
            "blockers",
        }
        missing = required - set(raw)
        extras = set(raw) - allowed
        if missing or extras:
            raise CreationContractError(
                "worker result fields are inconsistent "
                f"(missing={sorted(missing)}, unknown={sorted(extras)})"
            )
        if raw["schemaVersion"] != 1:
            raise CreationContractError("worker result schemaVersion must be 1")
        if (
            raw["jobId"] != request.job_id
            or raw["briefSha256"] != request.brief_sha256
            or raw["provider"] != self.name
        ):
            raise CreationContractError("worker result identity does not match its request")
        try:
            outcome = PipelineOutcome(str(raw["outcome"]))
            status = CreationProgress(str(raw["status"]))
        except ValueError as exc:
            raise CreationContractError(str(exc)) from exc
        blockers_raw = raw["blockers"]
        if not isinstance(blockers_raw, list):
            raise CreationContractError("worker result blockers must be an array")
        blockers: list[PipelineBlocker] = []
        for index, item in enumerate(blockers_raw):
            if not isinstance(item, Mapping):
                raise CreationContractError(
                    f"worker result blockers[{index}] must be an object"
                )
            blockers.append(
                PipelineBlocker(
                    str(item.get("code", "worker_blocked")),
                    str(item.get("message", "")),
                    str(item["requirement"])
                    if item.get("requirement") is not None
                    else None,
                )
            )
        retryable = raw["retryable"]
        if not isinstance(retryable, bool):
            raise CreationContractError("worker result retryable must be boolean")
        output = None
        output_raw = raw.get("output")
        if output_raw is not None:
            if not isinstance(output_raw, Mapping):
                raise CreationContractError("worker result output must be an object")
            expected = {
                "artifactPath",
                "mediaType",
                "previewPaths",
                "isPlaceholder",
                "metadata",
            }
            if set(output_raw) != expected:
                raise CreationContractError(
                    "worker result output fields are inconsistent"
                )
            preview_raw = output_raw["previewPaths"]
            if not isinstance(preview_raw, list) or any(
                not isinstance(item, str) for item in preview_raw
            ):
                raise CreationContractError(
                    "worker result previewPaths must be an array of strings"
                )
            placeholder = output_raw["isPlaceholder"]
            if not isinstance(placeholder, bool):
                raise CreationContractError(
                    "worker result isPlaceholder must be boolean"
                )
            metadata = output_raw["metadata"]
            if not isinstance(metadata, Mapping):
                raise CreationContractError("worker result metadata must be an object")
            output = ProviderCreationOutput(
                path=self._output_path(str(output_raw["artifactPath"])),
                media_type=str(output_raw["mediaType"]),
                preview_paths=tuple(
                    self._output_path(item) for item in preview_raw
                ),
                is_placeholder=placeholder,
                metadata=dict(metadata),
            )
        return ProviderCreationResult(
            outcome=outcome,
            status=status,
            message=str(raw["message"]),
            output=output,
            blockers=tuple(blockers),
            provider_job_id=str(raw["providerJobId"])
            if raw.get("providerJobId") is not None
            else request.job_id,
            retryable=retryable,
        )

    def _output_path(self, relative: str) -> Path:
        candidate = Path(relative)
        if candidate.is_absolute():
            raise CreationContractError("worker output paths must be relative")
        root = self.output.resolve()
        resolved = (root / candidate).resolve()
        try:
            resolved.relative_to(root)
        except ValueError as exc:
            raise CreationContractError("worker output path escapes outputRoot") from exc
        return resolved


def _write_once_json(path: Path, payload: Mapping[str, Any]) -> None:
    encoded = json.dumps(
        payload, indent=2, sort_keys=True, ensure_ascii=False
    ).encode("utf-8") + b"\n"
    try:
        descriptor = os.open(path, os.O_CREAT | os.O_EXCL | os.O_WRONLY)
    except FileExistsError:
        if path.read_bytes() != encoded:
            raise CreationContractError("worker outbox request changed for the same job")
        return
    with os.fdopen(descriptor, "wb") as stream:
        stream.write(encoded)

