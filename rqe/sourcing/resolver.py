"""Bind connector-acquired bytes to semantic needs in an :class:`AssetPlan`.

Acquiring a pack and deciding to reuse it are different facts.  A zip full of
sounds proves only that bytes were downloaded; it does not prove which sound is
the purchase confirmation, that its licence permits a commercial game, or that
the file still matches the connector receipt.  This module closes that small
but important gap before the Asset Director is allowed to prefer a source.

It deliberately stops before Roblox publication.  Local WAV/OGG files cannot
be used as ``SoundId`` values in a shipped place, so a resolution is marked
``integration=NOT_VALIDATED`` until the existing asset publication pipeline
returns approved, hash-bound Roblox ids.
"""

from __future__ import annotations

import hashlib
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Iterable, Mapping, Sequence

from ..assets.catalog import AssetCatalog
from ..assets.models import AssetKind, AssetRecord
from .registry import LICENCES, SOURCES


SEMANTIC_CUES: dict[str, str] = {
    "feedback-ui-confirm": "ui-confirm",
    "feedback-ui-denied": "ui-denied",
    "feedback-purchase-success": "purchase-success",
    "feedback-reward": "reward",
}


@dataclass(frozen=True)
class SourceBinding:
    need_id: str
    source_id: str
    asset_id: str
    local_path: str
    content_sha256: str
    licence: str
    attribution_required: bool
    cue: str

    def to_dict(self) -> dict[str, Any]:
        return {
            "needId": self.need_id,
            "sourceId": self.source_id,
            "assetId": self.asset_id,
            "localPath": self.local_path,
            "contentSha256": self.content_sha256,
            "licence": self.licence,
            "attributionRequired": self.attribution_required,
            "cue": self.cue,
            "validationLevel": "STATICALLY_VALIDATED",
            "integration": {
                "status": "NOT_VALIDATED",
                "reason": (
                    "local source bytes are selected, but no approved Roblox "
                    "asset id is bound to this need"
                ),
            },
        }


@dataclass(frozen=True)
class SourceResolution:
    plan_id: str
    bindings: tuple[SourceBinding, ...]
    unresolved: tuple[str, ...]
    rejected: tuple[dict[str, str], ...]

    @property
    def source_offers(self) -> dict[str, tuple[str, ...]]:
        offers: dict[str, set[str]] = {}
        for binding in self.bindings:
            offers.setdefault(binding.need_id, set()).add(binding.source_id)
        return {
            need_id: tuple(sorted(sources))
            for need_id, sources in sorted(offers.items())
        }

    @property
    def complete(self) -> bool:
        return not self.unresolved

    def to_dict(self) -> dict[str, Any]:
        return {
            "schemaVersion": 1,
            "planId": self.plan_id,
            "complete": self.complete,
            "validationLevel": "STATICALLY_VALIDATED",
            "bindings": [item.to_dict() for item in self.bindings],
            "sourceOffers": [
                {"id": need_id, "sources": list(sources)}
                for need_id, sources in self.source_offers.items()
            ],
            "unresolved": list(self.unresolved),
            "rejected": list(self.rejected),
            "publication": {
                "status": "NOT_VALIDATED",
                "productionReady": False,
                "reason": (
                    "resolution proves local reuse only; Roblox publication, "
                    "moderation and exact-build integration are separate stages"
                ),
            },
        }


def resolve_plan_sources(
    plan: Any,
    catalogs: Sequence[AssetCatalog] | AssetCatalog,
) -> SourceResolution:
    """Resolve semantic media needs against connector-owned catalog records.

    Only explicit ``metadata.semanticCues`` participate.  Filename guessing is
    intentionally absent: choosing ``click_17.wav`` as a denial sound because
    it sorted near another click would turn deterministic ordering into art
    direction.
    """

    supplied = (catalogs,) if isinstance(catalogs, AssetCatalog) else tuple(catalogs)
    records = sorted(
        (record for catalog in supplied for record in catalog.records.values()),
        key=lambda item: (item.provider.casefold(), item.logical_id),
    )
    entries = tuple(getattr(plan, "entries", ()) or ())
    plan_id = str(getattr(plan, "world_id", "") or "")
    bindings: list[SourceBinding] = []
    unresolved: list[str] = []
    rejected: list[dict[str, str]] = []

    for entry in entries:
        need_id = str(getattr(entry, "id", ""))
        cue = SEMANTIC_CUES.get(need_id)
        if cue is None:
            continue
        candidates: list[tuple[AssetRecord, str]] = []
        for record in records:
            semantic = _semantic_cues(record.metadata)
            if cue not in semantic and need_id not in semantic:
                continue
            problem = _record_problem(record)
            if problem is not None:
                rejected.append({"needId": need_id, "assetId": record.logical_id,
                                 "reason": problem})
                continue
            source_id = _source_id(record)
            if source_id is None:
                rejected.append({
                    "needId": need_id,
                    "assetId": record.logical_id,
                    "reason": "record does not identify a registered audio source",
                })
                continue
            candidates.append((record, source_id))
        if not candidates:
            unresolved.append(need_id)
            continue

        # Connector metadata may rank curated candidates.  Stable ids break a
        # tie, so the same acquisition receipt always yields the same plan.
        candidates.sort(key=lambda item: (
            _cue_rank(item[0].metadata, cue), item[0].logical_id
        ))
        record, source_id = candidates[0]
        assert record.local_path is not None
        assert record.provenance is not None
        assert record.provenance.content_sha256 is not None
        assert record.license is not None
        bindings.append(SourceBinding(
            need_id=need_id,
            source_id=source_id,
            asset_id=record.logical_id,
            local_path=record.local_path,
            content_sha256=record.provenance.content_sha256,
            licence=record.license.name,
            attribution_required=record.license.attribution_required is True,
            cue=cue,
        ))

    return SourceResolution(
        plan_id=plan_id,
        bindings=tuple(bindings),
        unresolved=tuple(sorted(unresolved)),
        rejected=tuple(sorted(rejected, key=lambda item: (
            item["needId"], item["assetId"], item["reason"]
        ))),
    )


def _semantic_cues(metadata: Mapping[str, Any]) -> frozenset[str]:
    raw = metadata.get("semanticCues", ())
    if isinstance(raw, str):
        raw = (raw,)
    if not isinstance(raw, Iterable) or isinstance(raw, (bytes, bytearray, Mapping)):
        return frozenset()
    return frozenset(str(item).strip() for item in raw if str(item).strip())


def _source_id(record: AssetRecord) -> str | None:
    declared = record.metadata.get("sourceId")
    if isinstance(declared, str) and declared.strip():
        candidate = declared.strip()
    elif record.provider.casefold() == "kenney":
        candidate = "kenney-audio"
    else:
        candidate = record.provider.strip()
    known = {source.id: source for source in SOURCES}
    source = known.get(candidate)
    if source is None or source.kind != "audio" or not source.usable:
        return None
    return source.id


def _record_problem(record: AssetRecord) -> str | None:
    if record.kind != AssetKind.AUDIO:
        return "semantic cue is not an audio asset"
    if record.license is None:
        return "licence evidence is missing"
    licence = LICENCES.get(record.license.name)
    if (
        licence is None
        or not licence.commercial
        or not record.license.verified
        or record.license.commercial_use is not True
    ):
        return "licence is not verified for commercial use"
    if record.license.attribution_required != licence.attribution:
        return "recorded attribution requirement disagrees with sourcing policy"
    if record.local_path is None:
        return "local source path is missing"
    path = Path(record.local_path)
    if not path.is_file():
        return "local source file does not exist"
    if path.suffix.casefold() not in {".wav", ".ogg"}:
        return "local source file is not a supported Roblox audio input"
    expected = record.provenance.content_sha256 if record.provenance else None
    if not expected:
        return "content hash evidence is missing"
    if _sha256(path) != expected:
        return "local source bytes do not match connector provenance"
    return None


def _cue_rank(metadata: Mapping[str, Any], cue: str) -> int:
    ranks = metadata.get("cueRanks")
    if isinstance(ranks, Mapping):
        value = ranks.get(cue)
        if isinstance(value, int) and not isinstance(value, bool) and value >= 0:
            return value
    rank = metadata.get("cueRank", 1000)
    return rank if isinstance(rank, int) and not isinstance(rank, bool) else 1000


def _sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()
