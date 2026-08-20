from __future__ import annotations

from dataclasses import dataclass, field
from typing import Any


STATUSES = {"PASS", "WARN", "FAIL"}
SEVERITIES = {"critical", "major", "minor", "info"}
VALIDATION_LEVELS = (
    "NOT_VALIDATED",
    "STATICALLY_VALIDATED",
    "RUNTIME_VALIDATED",
    "VISUALLY_VALIDATED",
    "E2E_VALIDATED",
)


def validation_level_at_least(actual: str, required: str) -> bool:
    """Return whether ``actual`` carries at least as much proof as ``required``.

    Keeping this comparison in one place prevents individual gates from
    accidentally treating a static assertion as runtime evidence. Unknown
    labels are invalid rather than silently falling back to the weakest level.
    """

    if actual not in VALIDATION_LEVELS:
        raise ValueError(f"invalid validation level: {actual}")
    if required not in VALIDATION_LEVELS:
        raise ValueError(f"invalid validation level: {required}")
    return VALIDATION_LEVELS.index(actual) >= VALIDATION_LEVELS.index(required)


@dataclass
class Evidence:
    """One auditable assertion with machine-readable proof."""

    id: str
    probe: str
    category: str
    status: str
    severity: str
    message: str
    source: str
    validation_level: str
    details: dict[str, Any] = field(default_factory=dict)
    observed_at: str | None = None
    run_id: str | None = None
    build_hash: str | None = None
    coverage: float | None = None
    conclusive: bool = True
    truncated: bool = False

    def __post_init__(self) -> None:
        self.status = self.status.upper()
        if self.status not in STATUSES:
            raise ValueError(f"invalid status: {self.status}")
        if self.severity not in SEVERITIES:
            raise ValueError(f"invalid severity: {self.severity}")
        if self.validation_level not in VALIDATION_LEVELS:
            raise ValueError(f"invalid validation level: {self.validation_level}")
        if self.coverage is not None and not 0 <= self.coverage <= 1:
            raise ValueError(f"coverage must be between 0 and 1: {self.coverage}")

    def to_dict(self) -> dict[str, Any]:
        return {
            "id": self.id,
            "probe": self.probe,
            "category": self.category,
            "status": self.status,
            "severity": self.severity,
            "message": self.message,
            "details": self.details,
            "source": self.source,
            "validationLevel": self.validation_level,
            "observedAt": self.observed_at,
            "runId": self.run_id,
            "buildHash": self.build_hash,
            "coverage": self.coverage,
            "conclusive": self.conclusive,
            "truncated": self.truncated,
        }


@dataclass
class AuditReport:
    project: str
    generated_at: str
    evidence: list[Evidence]
    scores: dict[str, float]
    summary: dict[str, int]
    release_allowed: bool
    release_reasons: list[str]
    runtime_trace: dict[str, Any]
    static_scan: dict[str, Any]
    agent_session: dict[str, Any] = field(default_factory=dict)

    def to_dict(self) -> dict[str, Any]:
        return {
            "engine": {"name": "Roblox Quality Engine", "version": "0.1.0"},
            "project": self.project,
            "generatedAt": self.generated_at,
            "summary": self.summary,
            "scores": self.scores,
            "releaseAllowed": self.release_allowed,
            "releaseReasons": self.release_reasons,
            "evidence": [item.to_dict() for item in self.evidence],
            "runtimeTrace": self.runtime_trace,
            "staticScan": self.static_scan,
            "agentSession": self.agent_session,
        }
