"""Typed state shared by orchestration adapters.

The orchestrator is deliberately stricter than an agent prompt.  A successful
impacted subset is useful repair feedback, but only a successful deterministic
FULL gate may authorize the terminal RELEASED state.
"""

from __future__ import annotations

import re
from dataclasses import dataclass, field
from enum import Enum
from typing import Any


IDENTIFIER = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,95}$")


class CampaignStage(str, Enum):
    CREATED = "CREATED"
    SPECIFYING = "SPECIFYING"
    PLANNED = "PLANNED"
    BUILDING = "BUILDING"
    INTEGRATING = "INTEGRATING"
    MEASURING = "MEASURING"
    PLAYING = "PLAYING"
    CAPTURING = "CAPTURING"
    EVALUATING = "EVALUATING"
    REPAIRING = "REPAIRING"
    REGRESSION_IMPACTED = "REGRESSION_IMPACTED"
    REGRESSION_FULL = "REGRESSION_FULL"
    RELEASED = "RELEASED"
    BLOCKED = "BLOCKED"
    INFRA_FAILED = "INFRA_FAILED"
    CANCELLED = "CANCELLED"


class TaskStatus(str, Enum):
    PENDING = "PENDING"
    RUNNING = "RUNNING"
    SUCCEEDED = "SUCCEEDED"
    FAILED = "FAILED"
    BLOCKED = "BLOCKED"
    UNSUPPORTED = "UNSUPPORTED"
    UNCERTAIN = "UNCERTAIN"
    CANCELLED = "CANCELLED"


class ValidationScope(str, Enum):
    IMPACTED = "IMPACTED"
    FULL = "FULL"


@dataclass(frozen=True)
class TaskSpec:
    """One schedulable unit with an explicit dependency and write surface."""

    id: str
    stage: CampaignStage
    role: str
    intent: str
    blocked_by: tuple[str, ...] = ()
    read_set: tuple[str, ...] = ()
    write_set: tuple[str, ...] = ()
    resource_claims: tuple[str, ...] = ()
    completion_checks: tuple[str, ...] = ()
    guard_required: bool = False
    metadata: dict[str, Any] = field(default_factory=dict, compare=False)

    def __post_init__(self) -> None:
        if not IDENTIFIER.fullmatch(self.id):
            raise ValueError(f"invalid task id: {self.id!r}")
        if not isinstance(self.stage, CampaignStage):
            raise ValueError(f"invalid task stage: {self.stage!r}")
        if not self.role.strip():
            raise ValueError("task role must not be empty")
        if not self.intent.strip():
            raise ValueError("task intent must not be empty")
        if self.id in self.blocked_by:
            raise ValueError(f"task {self.id!r} cannot depend on itself")
        if len(set(self.blocked_by)) != len(self.blocked_by):
            raise ValueError(f"task {self.id!r} has duplicate dependencies")
        for label, values in (
            ("blocked_by", self.blocked_by),
            ("read_set", self.read_set),
            ("write_set", self.write_set),
            ("resource_claims", self.resource_claims),
            ("completion_checks", self.completion_checks),
        ):
            if any(not isinstance(value, str) or not value.strip() for value in values):
                raise ValueError(f"task {self.id!r} has an invalid {label} entry")


@dataclass(frozen=True)
class ValidationOutcome:
    """Result of either fast impacted feedback or the complete release gate."""

    scope: ValidationScope
    checks_passed: bool
    deterministic_gate_allowed: bool
    blockers: tuple[str, ...] = ()

    def __post_init__(self) -> None:
        if not isinstance(self.scope, ValidationScope):
            raise ValueError(f"invalid validation scope: {self.scope!r}")

    @property
    def authorizes_release(self) -> bool:
        return (
            self.scope is ValidationScope.FULL
            and self.checks_passed
            and self.deterministic_gate_allowed
            and not self.blockers
        )


class TransitionError(RuntimeError):
    pass


_TERMINAL_STAGES = {
    CampaignStage.RELEASED,
    CampaignStage.BLOCKED,
    CampaignStage.INFRA_FAILED,
    CampaignStage.CANCELLED,
}

_TRANSITIONS: dict[CampaignStage, frozenset[CampaignStage]] = {
    CampaignStage.CREATED: frozenset({CampaignStage.SPECIFYING}),
    CampaignStage.SPECIFYING: frozenset({CampaignStage.PLANNED}),
    CampaignStage.PLANNED: frozenset({CampaignStage.BUILDING}),
    CampaignStage.BUILDING: frozenset({CampaignStage.INTEGRATING}),
    # Initial integration measures immediately.  A repair integration first
    # records that the complete regression cycle is beginning.
    CampaignStage.INTEGRATING: frozenset({CampaignStage.MEASURING, CampaignStage.REGRESSION_FULL}),
    CampaignStage.REGRESSION_FULL: frozenset({CampaignStage.MEASURING}),
    CampaignStage.MEASURING: frozenset({CampaignStage.PLAYING}),
    CampaignStage.PLAYING: frozenset({CampaignStage.CAPTURING}),
    CampaignStage.CAPTURING: frozenset({CampaignStage.EVALUATING}),
    CampaignStage.EVALUATING: frozenset({CampaignStage.RELEASED, CampaignStage.REPAIRING}),
    CampaignStage.REPAIRING: frozenset({CampaignStage.REGRESSION_IMPACTED}),
    CampaignStage.REGRESSION_IMPACTED: frozenset({CampaignStage.INTEGRATING}),
}


@dataclass
class CampaignStateMachine:
    """Small deterministic state machine; persistence is supplied by journal.py."""

    state: CampaignStage = CampaignStage.CREATED
    history: list[CampaignStage] = field(default_factory=lambda: [CampaignStage.CREATED])

    def transition(
        self,
        target: CampaignStage,
        *,
        validation: ValidationOutcome | None = None,
    ) -> CampaignStage:
        if self.state in _TERMINAL_STAGES:
            raise TransitionError(f"campaign is terminal in {self.state.value}")
        if not isinstance(target, CampaignStage):
            raise TransitionError(f"unknown campaign stage: {target!r}")

        # A campaign may fail loudly from any active stage.  These transitions
        # never imply that the requested product outcome was achieved.
        if target not in {CampaignStage.BLOCKED, CampaignStage.INFRA_FAILED, CampaignStage.CANCELLED}:
            allowed = _TRANSITIONS.get(self.state, frozenset())
            if target not in allowed:
                raise TransitionError(f"cannot transition {self.state.value} -> {target.value}")

        if target is CampaignStage.RELEASED:
            if validation is None or not validation.authorizes_release:
                raise TransitionError("RELEASED requires a successful deterministic FULL release gate")

        self.state = target
        self.history.append(target)
        return self.state
