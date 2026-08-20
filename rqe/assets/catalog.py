"""In-memory catalog with lossless JSON serialization."""

from __future__ import annotations

from dataclasses import dataclass, field
from typing import Any, Iterable, Mapping, Sequence

from .codec import asset_from_dict
from .models import AssetKind, AssetRecord, SearchQuery


@dataclass
class AssetCatalog:
    catalog_id: str
    records: dict[str, AssetRecord] = field(default_factory=dict)

    @classmethod
    def from_dict(cls, raw: Mapping[str, Any]) -> "AssetCatalog":
        if raw.get("schemaVersion") != 1:
            raise ValueError("asset catalog schemaVersion must be 1")
        catalog_id = raw.get("catalogId")
        assets = raw.get("assets")
        if not isinstance(catalog_id, str) or not catalog_id.strip():
            raise ValueError("asset catalog requires catalogId")
        if not isinstance(assets, Sequence) or isinstance(
            assets, (str, bytes, bytearray)
        ):
            raise ValueError("asset catalog assets must be an array")
        catalog = cls(catalog_id)
        for index, item in enumerate(assets):
            if not isinstance(item, Mapping):
                raise ValueError(f"asset catalog entry {index} must be an object")
            catalog.add(asset_from_dict(item))
        return catalog

    def add(self, record: AssetRecord) -> None:
        existing = self.records.get(record.logical_id)
        if existing is not None and existing != record:
            raise ValueError(f"asset already exists in catalog: {record.logical_id}")
        self.records[record.logical_id] = record

    def upsert(self, record: AssetRecord) -> None:
        self.records[record.logical_id] = record

    def get(self, logical_id: str) -> AssetRecord | None:
        return self.records.get(logical_id)

    def search(self, query: SearchQuery) -> tuple[AssetRecord, ...]:
        needle = query.text.strip().casefold()
        allowed: set[AssetKind] = set(query.kinds)
        matches: list[AssetRecord] = []
        for record in self.records.values():
            if allowed and record.kind not in allowed:
                continue
            haystack = f"{record.display_name}\n{record.description}".casefold()
            if needle and needle not in haystack:
                continue
            matches.append(record)
        matches.sort(key=lambda item: (item.display_name.casefold(), item.logical_id))
        return tuple(matches[: max(0, min(query.limit, 100))])

    def extend(self, records: Iterable[AssetRecord]) -> None:
        for record in records:
            self.add(record)

    def to_dict(self) -> dict:
        return {
            "schemaVersion": 1,
            "catalogId": self.catalog_id,
            "assets": [
                self.records[key].to_dict() for key in sorted(self.records)
            ],
        }
