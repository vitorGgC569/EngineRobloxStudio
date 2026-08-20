"""Content-addressed publication packages and a process-safe receipt ledger."""

from __future__ import annotations

import hashlib
import json
import os
import shutil
from contextlib import contextmanager
from dataclasses import dataclass, replace
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Iterator, Mapping

from .codec import asset_from_dict
from .models import (
    AssetRecord,
    AssetState,
    CreatorTarget,
    IntegrationTarget,
    PipelineBlocker,
    PipelineOutcome,
    PipelineResult,
)
from .providers.base import AssetProvider, PublishRequest
from .validation import sha256_file


def _now() -> str:
    return datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")


@dataclass(frozen=True)
class PublicationPackage:
    package_id: str
    provider: str
    asset: AssetRecord
    creator: CreatorTarget
    integrations: tuple[IntegrationTarget, ...]
    created_at: str

    @classmethod
    def build(
        cls,
        *,
        provider: str,
        asset: AssetRecord,
        creator: CreatorTarget,
        integrations: tuple[IntegrationTarget, ...] = (),
        created_at: str | None = None,
    ) -> "PublicationPackage":
        if asset.state != AssetState.VALIDATED:
            raise ValueError("publication packages require state=validated")
        path = Path(asset.local_path or "")
        if not path.is_file():
            raise ValueError("publication package local file does not exist")
        measured_hash = sha256_file(path)
        recorded_hash = asset.provenance.content_sha256 if asset.provenance else None
        if recorded_hash != measured_hash:
            raise ValueError(
                "publication content hash does not match validation provenance"
            )
        package_id = _identity_hash(provider, asset, creator, integrations)
        return cls(
            package_id,
            provider,
            asset,
            creator,
            integrations,
            created_at or _now(),
        )

    @classmethod
    def from_dict(
        cls,
        raw: Mapping[str, Any],
        *,
        verify_payload: bool = True,
    ) -> "PublicationPackage":
        """Restore a package without trusting its recorded identity.

        ``refresh`` can set ``verify_payload=False`` because it is a read-only
        poll of an already-dispatched operation and the immutable ledger owns
        the staged bytes.  Publication itself always verifies the local bytes.
        """

        if raw.get("schemaVersion") != 1:
            raise ValueError("publication package schemaVersion must be 1")
        creator_raw = raw.get("creator")
        asset_raw = raw.get("asset")
        integrations_raw = raw.get("integrations")
        if not isinstance(creator_raw, Mapping):
            raise ValueError("publication package creator must be an object")
        if not isinstance(asset_raw, Mapping):
            raise ValueError("publication package asset must be an object")
        if not isinstance(integrations_raw, list):
            raise ValueError("publication package integrations must be an array")
        creator = CreatorTarget(
            user_id=_optional_text(creator_raw.get("userId")),
            group_id=_optional_text(creator_raw.get("groupId")),
        )
        integrations: list[IntegrationTarget] = []
        for index, item in enumerate(integrations_raw):
            if not isinstance(item, Mapping):
                raise ValueError(f"publication integration {index} must be an object")
            integrations.append(
                IntegrationTarget(
                    target=str(item.get("target", "")),
                    property=str(item.get("property", "")),
                    expected_class=_optional_text(item.get("expectedClass")),
                )
            )
        package = cls(
            package_id=str(raw.get("packageId", "")),
            provider=str(raw.get("provider", "")),
            asset=asset_from_dict(asset_raw),
            creator=creator,
            integrations=tuple(integrations),
            created_at=str(raw.get("createdAt", "")),
        )
        package.verify_identity()
        if verify_payload:
            package.verify()
        return package

    def verify_identity(self) -> None:
        _safe_id(self.package_id)
        if not self.provider.strip():
            raise ValueError("publication package provider is required")
        if not self.created_at.strip():
            raise ValueError("publication package createdAt is required")
        current_id = _identity_hash(
            self.provider, self.asset, self.creator, self.integrations
        )
        if current_id != self.package_id:
            raise ValueError("publication package identity hash is inconsistent")

    def verify(self) -> None:
        self.verify_identity()
        if self.asset.state != AssetState.VALIDATED:
            raise ValueError("publication package asset is no longer validated")
        path = Path(self.asset.local_path or "")
        if not path.is_file():
            raise ValueError("publication package local file does not exist")
        expected = self.asset.provenance.content_sha256 if self.asset.provenance else None
        if not expected or sha256_file(path) != expected:
            raise ValueError("publication content hash changed after packaging")

    def to_dict(self) -> dict[str, Any]:
        return {
            "schemaVersion": 1,
            "packageId": self.package_id,
            "provider": self.provider,
            "createdAt": self.created_at,
            "creator": self.creator.to_dict(),
            "asset": self.asset.to_dict(),
            "integrations": [item.to_dict() for item in self.integrations],
        }


class PublicationLedger:
    """Per-package receipts with exclusive claims; there is no global latest."""

    def __init__(self, root: Path):
        self.root = root
        self.packages = root / "packages"
        self.payloads = root / "payloads"
        self.receipts = root / "receipts"
        self.claims = root / "claims"
        for directory in (self.packages, self.payloads, self.receipts, self.claims):
            directory.mkdir(parents=True, exist_ok=True)

    def stage(self, package: PublicationPackage) -> AssetRecord:
        """Materialize the exact hash-bound bytes before external dispatch."""

        package.verify()
        package_path = self.packages / f"{_safe_id(package.package_id)}.json"
        if package_path.is_file():
            existing = json.loads(package_path.read_text(encoding="utf-8"))
            if (
                existing.get("packageId") != package.package_id
                or existing.get("provider") != package.provider
            ):
                raise ValueError("stored publication package identity is inconsistent")
        else:
            _atomic_json(package_path, package.to_dict())

        source = Path(package.asset.local_path or "")
        suffix = source.suffix.lower()
        if not suffix or any(not (character.isalnum() or character == ".") for character in suffix):
            raise ValueError("publication payload extension is unsafe")
        destination = self.payloads / f"{_safe_id(package.package_id)}{suffix}"
        expected = package.asset.provenance.content_sha256 if package.asset.provenance else None
        if destination.is_file():
            if sha256_file(destination) != expected:
                raise ValueError("staged publication payload failed its recorded hash")
        else:
            temporary = destination.with_name(f".{destination.name}.{os.getpid()}.tmp")
            shutil.copyfile(source, temporary)
            if sha256_file(temporary) != expected:
                temporary.unlink(missing_ok=True)
                raise ValueError("source changed while staging publication payload")
            os.replace(temporary, destination)
        return replace(package.asset, local_path=str(destination))

    def load(self, package_id: str) -> PipelineResult | None:
        path = self.receipts / f"{_safe_id(package_id)}.json"
        if not path.is_file():
            return None
        raw = json.loads(path.read_text(encoding="utf-8"))
        return _result_from_dict(raw["result"], cached=True)

    def save(self, package: PublicationPackage, result: PipelineResult) -> None:
        package_path = self.packages / f"{_safe_id(package.package_id)}.json"
        receipt_path = self.receipts / f"{_safe_id(package.package_id)}.json"
        package_payload = package.to_dict()
        if package_path.is_file():
            existing = json.loads(package_path.read_text(encoding="utf-8"))
            if existing.get("packageId") != package.package_id:
                raise ValueError("publication package identity collision")
        else:
            _atomic_json(package_path, package_payload)
        _atomic_json(
            receipt_path,
            {
                "schemaVersion": 1,
                "packageId": package.package_id,
                "recordedAt": _now(),
                "result": _result_to_dict(result),
            },
        )

    @contextmanager
    def claim(self, package_id: str) -> Iterator[bool]:
        path = self.claims / f"{_safe_id(package_id)}.lock"
        try:
            descriptor = os.open(path, os.O_CREAT | os.O_EXCL | os.O_WRONLY)
        except FileExistsError:
            yield False
            return
        try:
            with os.fdopen(descriptor, "w", encoding="utf-8") as stream:
                json.dump({"pid": os.getpid(), "claimedAt": _now()}, stream)
            yield True
        finally:
            path.unlink(missing_ok=True)


class PublicationCoordinator:
    """At-most-one Create Asset call for each content-addressed package."""

    def __init__(self, provider: AssetProvider, ledger: PublicationLedger):
        self.provider = provider
        self.ledger = ledger

    def publish(self, package: PublicationPackage) -> PipelineResult:
        if package.provider != self.provider.name:
            return PipelineResult(
                PipelineOutcome.FAILED,
                package.asset,
                f"package targets {package.provider}, provider is {self.provider.name}",
            )
        existing, load_error = self._load(package)
        if load_error is not None:
            return load_error
        if existing is not None:
            return existing
        with self.ledger.claim(package.package_id) as acquired:
            if not acquired:
                return PipelineResult(
                    PipelineOutcome.BLOCKED,
                    package.asset,
                    "another process owns this publication package",
                    blockers=(
                        PipelineBlocker(
                            "publication_in_progress",
                            "wait for the package receipt before retrying",
                        ),
                    ),
                    retryable=True,
                )
            existing, load_error = self._load(package)
            if load_error is not None:
                return load_error
            if existing is not None:
                return existing
            try:
                staged_asset = self.ledger.stage(package)
            except (OSError, ValueError, json.JSONDecodeError) as exc:
                return PipelineResult(
                    PipelineOutcome.FAILED,
                    package.asset,
                    "publication package could not be staged immutably",
                    blockers=(
                        PipelineBlocker("publication_package_invalid", str(exc)),
                    ),
                )
            result = self.provider.publish(
                PublishRequest(
                    asset=staged_asset,
                    creator=package.creator,
                    idempotency_key=package.package_id,
                )
            )
            # Missing credentials/service availability must remain retryable;
            # only evidence-bearing remote progress or terminal rejection gets
            # a durable receipt that suppresses a duplicate Create Asset call.
            if result.asset.state in {
                AssetState.UPLOADING,
                AssetState.PUBLISHED,
                AssetState.APPROVED,
                AssetState.REJECTED,
            }:
                self.ledger.save(package, result)
            return result

    def refresh(self, package: PublicationPackage) -> PipelineResult:
        if package.provider != self.provider.name:
            return PipelineResult(
                PipelineOutcome.FAILED,
                package.asset,
                f"package targets {package.provider}, provider is {self.provider.name}",
            )
        existing, load_error = self._load(package)
        if load_error is not None:
            return load_error
        if existing is None:
            return PipelineResult(
                PipelineOutcome.FAILED,
                package.asset,
                "publication package has no remote receipt",
                blockers=(
                    PipelineBlocker(
                        "publication_receipt_missing",
                        "call publish before refresh",
                    ),
                ),
            )
        if existing.asset.state in {AssetState.APPROVED, AssetState.REJECTED}:
            return existing
        with self.ledger.claim(package.package_id) as acquired:
            if not acquired:
                return PipelineResult(
                    PipelineOutcome.BLOCKED,
                    existing.asset,
                    "another process is refreshing this publication package",
                    blockers=(
                        PipelineBlocker(
                            "publication_in_progress",
                            "wait for the package receipt before retrying",
                        ),
                    ),
                    retryable=True,
                )
            result = self.provider.refresh(existing.asset)
            if result.asset != existing.asset or result.asset.state in {
                AssetState.APPROVED,
                AssetState.REJECTED,
            }:
                self.ledger.save(package, result)
            return result

    def _load(
        self, package: PublicationPackage
    ) -> tuple[PipelineResult | None, PipelineResult | None]:
        try:
            return self.ledger.load(package.package_id), None
        except (OSError, KeyError, TypeError, ValueError, json.JSONDecodeError) as exc:
            return None, PipelineResult(
                PipelineOutcome.FAILED,
                package.asset,
                "publication receipt is unreadable or inconsistent",
                blockers=(
                    PipelineBlocker("publication_receipt_invalid", str(exc)),
                ),
            )


def _result_to_dict(result: PipelineResult) -> dict[str, Any]:
    payload: dict[str, Any] = {
        "outcome": result.outcome.value,
        "asset": result.asset.to_dict(),
        "message": result.message,
        "blockers": [item.to_dict() for item in result.blockers],
        "cached": result.cached,
        "retryable": result.retryable,
    }
    if result.operation_id:
        payload["operationId"] = result.operation_id
    return payload


def _result_from_dict(raw: Mapping[str, Any], *, cached: bool) -> PipelineResult:
    blockers = tuple(
        PipelineBlocker(
            str(item.get("code", "unknown")),
            str(item.get("message", "")),
            str(item["requirement"]) if item.get("requirement") is not None else None,
        )
        for item in raw.get("blockers", [])
        if isinstance(item, Mapping)
    )
    asset_raw = raw.get("asset")
    if not isinstance(asset_raw, Mapping):
        raise ValueError("publication receipt has no asset")
    return PipelineResult(
        PipelineOutcome(str(raw["outcome"])),
        asset_from_dict(asset_raw),
        str(raw.get("message", "")),
        blockers,
        str(raw["operationId"]) if raw.get("operationId") is not None else None,
        cached=cached,
        retryable=raw.get("retryable") is True,
    )


def _safe_id(package_id: str) -> str:
    if len(package_id) != 64 or any(char not in "0123456789abcdef" for char in package_id):
        raise ValueError("package_id must be a lowercase SHA-256 hex digest")
    return package_id


def _optional_text(value: object) -> str | None:
    if not isinstance(value, str):
        return None
    stripped = value.strip()
    return stripped or None


def _identity_hash(
    provider: str,
    asset: AssetRecord,
    creator: CreatorTarget,
    integrations: tuple[IntegrationTarget, ...],
) -> str:
    content_hash = asset.provenance.content_sha256 if asset.provenance else None
    identity = {
        "schemaVersion": 1,
        "provider": provider,
        "asset": {
            "id": asset.logical_id,
            "kind": asset.kind.value,
            "displayName": asset.display_name,
            "description": asset.description,
            "contentType": asset.content_type,
            "contentSha256": content_hash,
            "metadata": dict(asset.metadata),
            "license": asset.license.to_dict() if asset.license else None,
        },
        "creator": creator.to_dict(),
        "integrations": [item.to_dict() for item in integrations],
    }
    canonical = json.dumps(
        identity,
        sort_keys=True,
        ensure_ascii=False,
        separators=(",", ":"),
    ).encode("utf-8")
    return hashlib.sha256(canonical).hexdigest()


def _atomic_json(path: Path, payload: Mapping[str, Any]) -> None:
    temporary = path.with_name(f".{path.name}.{os.getpid()}.tmp")
    temporary.write_text(
        json.dumps(payload, indent=2, sort_keys=True, ensure_ascii=False) + "\n",
        encoding="utf-8",
    )
    os.replace(temporary, path)
