"""Data-driven changed-path to regression-scope selection."""

from __future__ import annotations

import fnmatch
import json
from dataclasses import dataclass
from pathlib import Path
from typing import Any

from .models import ValidationScope
from .ownership import canonical_write_path


class ImpactMapError(ValueError):
    pass


@dataclass(frozen=True)
class ImpactRule:
    id: str
    paths: tuple[str, ...]
    requirements: tuple[str, ...]
    checks: tuple[str, ...]
    stages: tuple[str, ...]
    full: bool = False


@dataclass(frozen=True)
class ImpactSelection:
    scope: ValidationScope
    changed_paths: tuple[str, ...]
    matched_rules: tuple[str, ...]
    unknown_paths: tuple[str, ...]
    requirements: tuple[str, ...]
    checks: tuple[str, ...]
    stages: tuple[str, ...]
    reasons: tuple[str, ...]


class ImpactSelector:
    def __init__(self, rules: tuple[ImpactRule, ...], full_stages: tuple[str, ...]) -> None:
        if not rules:
            raise ImpactMapError("impact map must define at least one rule")
        if not full_stages:
            raise ImpactMapError("impact map must define fullStages")
        self.rules = rules
        self.full_stages = full_stages

    @classmethod
    def from_file(cls, path: str | Path) -> "ImpactSelector":
        source = Path(path)
        try:
            payload = json.loads(source.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError) as exc:
            raise ImpactMapError(f"cannot read impact map {source}: {exc}") from exc
        return cls.from_dict(payload)

    @classmethod
    def from_dict(cls, payload: dict[str, Any]) -> "ImpactSelector":
        if not isinstance(payload, dict) or payload.get("schemaVersion") != 1:
            raise ImpactMapError("impact map schemaVersion must be 1")
        full_stages = cls._strings(payload.get("fullStages"), "fullStages")
        raw_rules = payload.get("rules")
        if not isinstance(raw_rules, list) or not raw_rules:
            raise ImpactMapError("impact map rules must be a non-empty array")

        rules: list[ImpactRule] = []
        identifiers: set[str] = set()
        for index, raw in enumerate(raw_rules):
            if not isinstance(raw, dict):
                raise ImpactMapError(f"rules[{index}] must be an object")
            identifier = raw.get("id")
            if not isinstance(identifier, str) or not identifier.strip():
                raise ImpactMapError(f"rules[{index}].id must be a non-empty string")
            if identifier in identifiers:
                raise ImpactMapError(f"duplicate impact rule id: {identifier}")
            identifiers.add(identifier)
            patterns = cls._strings(raw.get("paths"), f"rules[{index}].paths")
            normalized_patterns = tuple(pattern.replace("\\", "/").casefold() for pattern in patterns)
            rules.append(ImpactRule(
                id=identifier,
                paths=normalized_patterns,
                requirements=cls._strings(raw.get("requirements", []), f"rules[{index}].requirements", allow_empty=True),
                checks=cls._strings(raw.get("checks", []), f"rules[{index}].checks", allow_empty=True),
                stages=cls._strings(raw.get("stages", []), f"rules[{index}].stages", allow_empty=True),
                full=bool(raw.get("full", False)),
            ))
        return cls(tuple(rules), full_stages)

    @staticmethod
    def _strings(value: Any, label: str, *, allow_empty: bool = False) -> tuple[str, ...]:
        if not isinstance(value, list) or any(not isinstance(item, str) or not item.strip() for item in value):
            raise ImpactMapError(f"{label} must be an array of non-empty strings")
        if not allow_empty and not value:
            raise ImpactMapError(f"{label} must not be empty")
        return tuple(value)

    def select(self, changed_paths: list[str] | tuple[str, ...]) -> ImpactSelection:
        canonical_paths = tuple(sorted({canonical_write_path(path) for path in changed_paths}))
        matched_rule_ids: set[str] = set()
        unknown_paths: list[str] = []
        requirements: set[str] = set()
        checks: set[str] = set()
        stages: set[str] = set()
        force_full = False
        reasons: list[str] = []

        for changed_path in canonical_paths:
            path_rules = [
                rule
                for rule in self.rules
                if any(fnmatch.fnmatchcase(changed_path, pattern) for pattern in rule.paths)
            ]
            if not path_rules:
                unknown_paths.append(changed_path)
                reasons.append(f"{changed_path}: no impact rule; fail closed to FULL")
                force_full = True
                continue
            for rule in path_rules:
                matched_rule_ids.add(rule.id)
                requirements.update(rule.requirements)
                checks.update(rule.checks)
                stages.update(rule.stages)
                if rule.full:
                    force_full = True
                    reasons.append(f"{changed_path}: rule {rule.id} requires FULL")
                else:
                    reasons.append(f"{changed_path}: matched {rule.id}")

        scope = ValidationScope.FULL if force_full else ValidationScope.IMPACTED
        if scope is ValidationScope.FULL:
            stages.update(self.full_stages)
        return ImpactSelection(
            scope=scope,
            changed_paths=canonical_paths,
            matched_rules=tuple(sorted(matched_rule_ids)),
            unknown_paths=tuple(sorted(unknown_paths)),
            requirements=tuple(sorted(requirements)),
            checks=tuple(sorted(checks)),
            stages=tuple(sorted(stages)),
            reasons=tuple(reasons),
        )
