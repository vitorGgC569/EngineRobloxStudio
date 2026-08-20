"""Wire protocol for the RQE Studio Bridge.

The protocol is deliberately small and typed. Every command carries a
correlation id and a deadline; every response carries the Studio context it was
produced in, so an agent can never mistake an edit-mode answer for a runtime
answer, or a stale answer for a fresh one.
"""

from __future__ import annotations

import secrets
import time
from dataclasses import dataclass, field
from datetime import datetime, timezone
from typing import Any

PROTOCOL_VERSION = "rqe.bridge/1"

#: Studio contexts a response can originate from. ``edit`` is the Studio place
#: open in edit mode; ``run`` is a Play Solo / Run session; ``server`` and
#: ``client`` distinguish the two halves of a Play (server + client) session.
CONTEXTS = {"edit", "run", "server", "client", "unknown"}


class ErrorCode:
    """Stable error taxonomy shared by the hub, the plugin and the client."""

    UNKNOWN_METHOD = "E_UNKNOWN_METHOD"
    BAD_PARAMS = "E_BAD_PARAMS"
    NOT_FOUND = "E_NOT_FOUND"
    TIMEOUT = "E_TIMEOUT"
    EXEC = "E_EXEC"
    DISCONNECTED = "E_DISCONNECTED"
    PROTOCOL = "E_PROTOCOL"
    UNAUTHORIZED = "E_UNAUTHORIZED"
    UNSUPPORTED_CONTEXT = "E_UNSUPPORTED_CONTEXT"
    SCHEMA = "E_SCHEMA"
    LEASE_REQUIRED = "E_LEASE_REQUIRED"
    LEASE_CONFLICT = "E_LEASE_CONFLICT"
    LEASE_STALE = "E_LEASE_STALE"
    TARGET_MISMATCH = "E_TARGET_MISMATCH"


class BridgeError(RuntimeError):
    """Raised on the Python side when a bridge command cannot be fulfilled."""

    def __init__(self, code: str, message: str, details: dict[str, Any] | None = None) -> None:
        super().__init__(f"{code}: {message}")
        self.code = code
        self.message = message
        self.details = details or {}

    def to_dict(self) -> dict[str, Any]:
        return {"code": self.code, "message": self.message, "details": self.details}


def _now_iso() -> str:
    return datetime.now(timezone.utc).isoformat()


def new_command_id() -> str:
    return f"cmd_{secrets.token_hex(8)}"


def new_session_id() -> str:
    return f"sess_{secrets.token_hex(6)}"


@dataclass
class Command:
    """A single typed request routed to one Studio plugin session."""

    method: str
    params: dict[str, Any] = field(default_factory=dict)
    method_version: int = 1
    target: dict[str, Any] = field(default_factory=dict)
    lease: dict[str, Any] = field(default_factory=dict)
    id: str = field(default_factory=new_command_id)
    deadline_ms: int = 15000
    issued_at: str = field(default_factory=_now_iso)
    #: Monotonic stamp used by the hub to expire commands that were never polled.
    created_monotonic: float = field(default_factory=time.monotonic)

    def to_wire(self) -> dict[str, Any]:
        return {
            "protocol": PROTOCOL_VERSION,
            "id": self.id,
            "method": self.method,
            "methodVersion": self.method_version,
            "params": self.params,
            "target": self.target,
            "lease": self.lease,
            "deadlineMs": self.deadline_ms,
            "issuedAt": self.issued_at,
        }

    def expired(self, now: float | None = None) -> bool:
        current = time.monotonic() if now is None else now
        elapsed_ms = (current - self.created_monotonic) * 1000
        return elapsed_ms >= self.deadline_ms


@dataclass
class Response:
    """The result of a command as reported by the plugin."""

    id: str
    ok: bool
    result: Any = None
    error: dict[str, Any] | None = None
    elapsed_ms: float = 0.0
    context: str = "unknown"
    place: str = ""
    #: Which session answered. Lets a caller pin a measurement sequence to one
    #: DataModel: instance refs are session-scoped, so mixing answers from an
    #: edit and a run session silently compares two different worlds.
    session: str = ""
    received_at: str = field(default_factory=_now_iso)

    @classmethod
    def from_wire(cls, payload: dict[str, Any]) -> "Response":
        if not isinstance(payload, dict):
            raise BridgeError(ErrorCode.PROTOCOL, "response payload must be an object")
        command_id = payload.get("id")
        if not isinstance(command_id, str) or not command_id:
            raise BridgeError(ErrorCode.PROTOCOL, "response is missing a correlation id")
        context = str(payload.get("context") or "unknown")
        return cls(
            id=command_id,
            ok=bool(payload.get("ok")),
            result=payload.get("result"),
            error=payload.get("error") if isinstance(payload.get("error"), dict) else None,
            elapsed_ms=float(payload.get("elapsedMs") or 0.0),
            context=context if context in CONTEXTS else "unknown",
            place=str(payload.get("place") or ""),
        )

    def to_dict(self) -> dict[str, Any]:
        return {
            "id": self.id,
            "ok": self.ok,
            "result": self.result,
            "error": self.error,
            "elapsedMs": round(self.elapsed_ms, 3),
            "context": self.context,
            "place": self.place,
            "session": self.session,
            "receivedAt": self.received_at,
        }

    def unwrap(self) -> Any:
        """Return the result or raise the plugin-reported error."""
        if self.ok:
            return self.result
        error = self.error or {}
        raise BridgeError(
            str(error.get("code") or ErrorCode.EXEC),
            str(error.get("message") or "plugin reported an unspecified failure"),
            error.get("details") if isinstance(error.get("details"), dict) else {},
        )


@dataclass
class SessionInfo:
    """A connected Studio plugin."""

    id: str
    plugin_version: str
    studio_version: str
    place_name: str
    place_id: int
    context: str
    #: Stable per plugin instance. Lets the hub retire a session the same Studio
    #: abandoned when it switched between edit and run.
    client_id: str = ""
    connected_at: str = field(default_factory=_now_iso)
    last_seen_monotonic: float = field(default_factory=time.monotonic)
    #: Set only when the plugin actually asks for work. A handshake proves a
    #: process started; only a poll proves it is still there to receive a
    #: command, which is what routing must depend on.
    last_poll_monotonic: float | None = None
    polls: int = 0
    #: Poll requests currently held open. A healthy plugin nearly always has one
    #: in flight, so this is the sharpest liveness signal the hub has.
    poll_waiting: int = 0
    commands_dispatched: int = 0
    commands_completed: int = 0

    def age_seconds(self) -> float:
        return time.monotonic() - self.last_seen_monotonic

    def poll_age_seconds(self) -> float | None:
        if self.last_poll_monotonic is None:
            return None
        return time.monotonic() - self.last_poll_monotonic

    def to_dict(self) -> dict[str, Any]:
        return {
            "session": self.id,
            "clientId": self.client_id,
            "pluginVersion": self.plugin_version,
            "studioVersion": self.studio_version,
            "place": {"name": self.place_name, "id": self.place_id},
            "context": self.context,
            "connectedAt": self.connected_at,
            "lastSeenSeconds": round(self.age_seconds(), 2),
            "lastPollSeconds": round(self.poll_age_seconds(), 2) if self.poll_age_seconds() is not None else None,
            "polls": self.polls,
            "pollWaiting": self.poll_waiting,
            "commandsDispatched": self.commands_dispatched,
            "commandsCompleted": self.commands_completed,
        }


def rpc_error(request_id: Any, code: int, message: str, data: Any = None) -> dict[str, Any]:
    error: dict[str, Any] = {"code": code, "message": message}
    if data is not None:
        error["data"] = data
    return {"jsonrpc": "2.0", "id": request_id, "error": error}


def rpc_result(request_id: Any, result: Any) -> dict[str, Any]:
    return {"jsonrpc": "2.0", "id": request_id, "result": result}
