"""Versioned liveness registry for release evidence producers.

A function existing somewhere in the repository is not enough.  A producer is
release-capable only when it is available, wired into the release runner,
strong enough for the requested validation level, and able to emit an allowed
source.  This closes the class of defect where a contract names a probe that
only a fixture or a disabled script can ever satisfy.
"""

from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path
from typing import Any

from .models import validation_level_at_least
from .project import Project, read_json
from .schema_validation import validate_schema_instance


class ProbeRegistryError(ValueError):
    pass


@dataclass(frozen=True)
class ProbeProducer:
    producer_id: str
    probe_pattern: str
    status: str
    stage: str
    implementation: str
    source: str
    maximum_validation_level: str
    release_integrated: bool
    contexts: tuple[str, ...]
    notes: str = ""

    def matches(self, probe: str) -> bool:
        if self.probe_pattern.endswith(".*"):
            return probe.startswith(self.probe_pattern[:-1])
        return probe == self.probe_pattern

    def to_dict(self) -> dict[str, Any]:
        return {
            "producerId": self.producer_id,
            "probePattern": self.probe_pattern,
            "status": self.status,
            "stage": self.stage,
            "implementation": self.implementation,
            "source": self.source,
            "maximumValidationLevel": self.maximum_validation_level,
            "releaseIntegrated": self.release_integrated,
            "contexts": list(self.contexts),
            "notes": self.notes,
        }


@dataclass(frozen=True)
class ProducerResolution:
    probe: str
    status: str
    producer_ids: tuple[str, ...]
    reasons: tuple[str, ...]

    @property
    def available(self) -> bool:
        return self.status == "AVAILABLE"

    def to_dict(self) -> dict[str, Any]:
        return {
            "probe": self.probe,
            "status": self.status,
            "producerIds": list(self.producer_ids),
            "reasons": list(self.reasons),
        }


@dataclass(frozen=True)
class ProbeRegistry:
    path: Path
    registry_id: str
    producers: tuple[ProbeProducer, ...]

    def resolve(
        self,
        probe: str,
        *,
        minimum_validation_level: str,
        allowed_sources: tuple[str, ...] = (),
    ) -> ProducerResolution:
        matches = [item for item in self.producers if item.matches(probe)]
        if not matches:
            return ProducerResolution(
                probe, "UNAVAILABLE", (), ("no producer is registered for this probe",)
            )

        eligible: list[ProbeProducer] = []
        reasons: list[str] = []
        for item in matches:
            item_reasons: list[str] = []
            if item.status != "AVAILABLE":
                item_reasons.append(f"status is {item.status}")
            if not item.release_integrated:
                item_reasons.append("not integrated into the immutable release runner")
            try:
                if not validation_level_at_least(
                    item.maximum_validation_level, minimum_validation_level
                ):
                    item_reasons.append(
                        f"maximum level {item.maximum_validation_level} is below {minimum_validation_level}"
                    )
            except ValueError as exc:
                item_reasons.append(str(exc))
            if allowed_sources and item.source not in allowed_sources:
                item_reasons.append(f"source {item.source!r} is not allowed")
            if item_reasons:
                reasons.append(f"{item.producer_id}: " + "; ".join(item_reasons))
            else:
                eligible.append(item)

        if eligible:
            return ProducerResolution(
                probe,
                "AVAILABLE",
                tuple(item.producer_id for item in eligible),
                (),
            )
        return ProducerResolution(
            probe,
            "UNAVAILABLE",
            tuple(item.producer_id for item in matches),
            tuple(reasons),
        )


def _inside(root: Path, relative: Any, label: str, *, base: Path | None = None) -> Path:
    if not isinstance(relative, str) or not relative or Path(relative).is_absolute():
        raise ProbeRegistryError(f"{label} must be a non-empty relative path")
    path = ((base or root) / relative).resolve()
    try:
        path.relative_to(root.resolve())
    except ValueError as exc:
        raise ProbeRegistryError(f"{label} escapes the project root") from exc
    if path.is_symlink() or not path.is_file():
        raise ProbeRegistryError(f"{label} is missing or is a symlink: {relative}")
    return path


def load_probe_registry(project: Project) -> ProbeRegistry:
    path = _inside(
        project.root,
        project.config.get("probeRegistry", "quality/probe-registry.v1.json"),
        "probe registry",
    )
    payload = read_json(path)
    schema_relative = payload.get("$schema")
    schema = read_json(_inside(
        project.root,
        schema_relative,
        "probe registry $schema",
        base=path.parent,
    ))
    issues = validate_schema_instance(payload, schema)
    if issues:
        raise ProbeRegistryError(
            "probe registry is invalid:\n- " + "\n- ".join(str(issue) for issue in issues)
        )
    ids = [item["producerId"] for item in payload["producers"]]
    if len(ids) != len(set(ids)):
        raise ProbeRegistryError("probe registry producerId values must be unique")
    producers = tuple(
        ProbeProducer(
            producer_id=item["producerId"],
            probe_pattern=item["probePattern"],
            status=item["status"],
            stage=item["stage"],
            implementation=item["implementation"],
            source=item["source"],
            maximum_validation_level=item["maximumValidationLevel"],
            release_integrated=item["releaseIntegrated"],
            contexts=tuple(item["contexts"]),
            notes=item.get("notes", ""),
        )
        for item in payload["producers"]
    )
    return ProbeRegistry(path, str(payload["registryId"]), producers)
