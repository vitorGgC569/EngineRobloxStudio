from __future__ import annotations

from dataclasses import dataclass, field
from datetime import datetime, timezone
from typing import Any


MODES = {"blackbox", "graybox", "whitebox"}


@dataclass
class AgentAction:
    """An atomic or semantic action requested by an agent."""

    type: str
    params: dict[str, Any] = field(default_factory=dict)

    def to_dict(self) -> dict[str, Any]:
        return {"type": self.type, **self.params}


@dataclass
class ActionRecord:
    sequence: int
    before: dict[str, Any]
    action: dict[str, Any]
    after: dict[str, Any]
    result: str
    reason: str | None = None
    details: dict[str, Any] = field(default_factory=dict)
    timestamp: str = field(default_factory=lambda: datetime.now(timezone.utc).isoformat())

    def to_dict(self) -> dict[str, Any]:
        return {
            "sequence": self.sequence,
            "timestamp": self.timestamp,
            "before": self.before,
            "action": self.action,
            "after": self.after,
            "result": self.result,
            "reason": self.reason,
            "details": self.details,
        }

