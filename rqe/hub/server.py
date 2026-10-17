"""The Bridge Hub: a local rendezvous between agents and Roblox Studio.

Roblox plugins cannot accept inbound connections, so the hub inverts the flow.
The plugin long-polls for work; agents enqueue typed commands and block on the
correlated response. This is the same shape Rojo uses, and it is the only
transport that works from inside Studio without external dependencies.

    agent ──POST /rpc──►  hub  ◄──POST /bridge/poll──  Studio plugin
                           │                                  │
                           └──── correlated Response ◄─POST /bridge/result
"""

from __future__ import annotations

import json
import ipaddress
import logging
import math
import secrets
import threading
import time
from collections import deque
from dataclasses import dataclass
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from typing import Any

from .auth import (
    BridgeAuthError,
    derive_role_tokens,
    load_bridge_token,
    role_for_command_effect,
    validate_token,
)
from .commands import CommandRegistry, CommandRegistryError, CommandValidationError, load_default_registry
from .protocol import (
    PROTOCOL_VERSION,
    BridgeError,
    Command,
    ErrorCode,
    Response,
    SessionInfo,
    new_session_id,
    rpc_error,
    rpc_result,
)
from ..workspace import hub_port

LOGGER = logging.getLogger("rqe.hub")

#: How long the hub holds a plugin poll open before answering with an empty
#: batch. Must stay comfortably below Roblox's own HTTP timeout.
#: How long a poll may hold open with no work.
#:
#: This is the latency of every command whose handler yields, and it is not
#: obvious why. Roblox serialises a plugin's HTTP: while the poll's GET is held
#: open, the POST carrying a finished result cannot leave. So a `client.*`
#: command -- which yields on `RemoteFunction:InvokeClient` -- finishes in
#: microseconds and then waits for the poll to expire before anyone hears about
#: it.
#:
#: Measured on one session, same commands, only this number changed:
#:
#:     hold 20.0   client.info 20.05s   (client answered in 0.030ms)
#:     hold  1.5   client.info  1.55s   (client answered in 0.030ms)
#:
#: The work was never the cost. Authoring is dozens of small calls, and at 20s
#: each that is half an hour to place five things.
#:
#: The trade is poll volume: 40 polls a minute instead of 3. On a loopback hub
#: that is nothing, and it buys a thirteenfold cut in the only latency a caller
#: ever feels.
DEFAULT_POLL_HOLD_SECONDS = 1.5

#: A session with no poll or heartbeat for this long is considered gone.
SESSION_STALE_SECONDS = 75.0

MAX_EVENTS = 2000
MAX_REQUEST_BODY_BYTES = 4 * 1024 * 1024
MAX_RESPONSE_BODY_BYTES = 8 * 1024 * 1024
MAX_SESSIONS = 32
MAX_QUEUE_PER_SESSION = 256
MAX_INFLIGHT_PER_SESSION = 32
MAX_EVENT_BATCH = 256
MAX_RESULT_BATCH = 128
MAX_EVENT_QUERY = 500
MAX_COMMAND_TIMEOUT_SECONDS = 300.0
MAX_REQUEST_LINE_BYTES = 8 * 1024
MAX_HEADER_BYTES = 32 * 1024
SOCKET_IO_TIMEOUT_SECONDS = 20.0
DEFAULT_RATE_LIMIT_PER_SECOND = 120.0
DEFAULT_RATE_LIMIT_BURST = 240


class RequestBodyTooLarge(ValueError):
    """Raised before an oversized HTTP body is read into memory."""


@dataclass(frozen=True)
class InflightAssignment:
    """The immutable dispatch receipt a response must match.

    A correlation id alone is insufficient: a Studio can re-register while a
    command is still running.  Binding the id to the session that actually
    polled it prevents an answer from a different DataModel being accepted.
    """

    command: Command
    session_id: str
    client_id: str
    effect: str
    dispatched_monotonic: float


@dataclass
class SessionLease:
    id: str
    fence: int
    run_id: str
    agent_id: str
    build_id: str
    session_id: str
    client_id: str
    acquired_monotonic: float
    expires_monotonic: float

    def expired(self, now: float | None = None) -> bool:
        return (now if now is not None else time.monotonic()) >= self.expires_monotonic

    def to_dict(self) -> dict[str, Any]:
        return {
            "leaseId": self.id,
            "fence": self.fence,
            "runId": self.run_id,
            "agentId": self.agent_id,
            "buildId": self.build_id,
            "session": self.session_id,
            "clientId": self.client_id,
            "remainingSeconds": round(max(0.0, self.expires_monotonic - time.monotonic()), 3),
        }


class BridgeHub:
    """Session registry, command queue and response correlation."""

    def __init__(
        self,
        token: str | None = None,
        poll_hold_seconds: float = DEFAULT_POLL_HOLD_SECONDS,
        *,
        command_registry: CommandRegistry | None = None,
        require_mutation_leases: bool = False,
        enforce_manifest_leases: bool = True,
        allow_unauthenticated: bool = False,
        max_sessions: int = MAX_SESSIONS,
        max_queue_per_session: int = MAX_QUEUE_PER_SESSION,
        max_inflight_per_session: int = MAX_INFLIGHT_PER_SESSION,
        rate_limit_per_second: float = DEFAULT_RATE_LIMIT_PER_SECOND,
        rate_limit_burst: int = DEFAULT_RATE_LIMIT_BURST,
    ) -> None:
        if token is None and not allow_unauthenticated:
            token = load_bridge_token()
        root_token = validate_token(token) if token is not None else None
        self._role_tokens = derive_role_tokens(root_token) if root_token else {}
        self.authentication_required = bool(self._role_tokens)
        self.allow_unauthenticated = allow_unauthenticated
        self.poll_hold_seconds = poll_hold_seconds
        self.command_registry = command_registry or load_default_registry()
        if self.command_registry.protocol != PROTOCOL_VERSION:
            raise CommandRegistryError(
                f"command manifest speaks {self.command_registry.protocol!r}, "
                f"hub speaks {PROTOCOL_VERSION!r}"
            )
        self.require_mutation_leases = require_mutation_leases
        self.enforce_manifest_leases = enforce_manifest_leases
        for label, value in (
            ("max_sessions", max_sessions),
            ("max_queue_per_session", max_queue_per_session),
            ("max_inflight_per_session", max_inflight_per_session),
        ):
            if not isinstance(value, int) or isinstance(value, bool) or value < 1:
                raise ValueError(f"{label} must be a positive integer")
        self.max_sessions = max_sessions
        self.max_queue_per_session = max_queue_per_session
        self.max_inflight_per_session = max_inflight_per_session
        if (
            not isinstance(rate_limit_per_second, (int, float))
            or isinstance(rate_limit_per_second, bool)
            or not math.isfinite(float(rate_limit_per_second))
            or rate_limit_per_second <= 0
        ):
            raise ValueError("rate_limit_per_second must be a positive finite number")
        if not isinstance(rate_limit_burst, int) or isinstance(rate_limit_burst, bool) or rate_limit_burst < 1:
            raise ValueError("rate_limit_burst must be a positive integer")
        self.rate_limit_per_second = float(rate_limit_per_second)
        self.rate_limit_burst = rate_limit_burst
        self._condition = threading.Condition()
        self._sessions: dict[str, SessionInfo] = {}
        # Returned only to the plugin that completed hello. Status and logs
        # never expose these ephemeral continuity proofs.
        self._session_keys: dict[str, str] = {}
        self._queues: dict[str, deque[Command]] = {}
        self._inflight: dict[str, InflightAssignment] = {}
        # Callers may time out after Studio has already received a command.  In
        # that case the outcome is uncertain: forgetting the assignment would
        # let a second mutation overlap work that is still changing the same
        # DataModel.  Keep the dispatch receipt until Studio answers or the
        # session is explicitly retired, but do not retain a late response for
        # a caller that has already gone away.
        self._abandoned_inflight: set[str] = set()
        self._responses: dict[str, Response] = {}
        self._leases: dict[str, SessionLease] = {}
        self._next_fence = 0
        self._events: deque[dict[str, Any]] = deque(maxlen=MAX_EVENTS)
        self._rate_buckets: dict[str, tuple[float, float]] = {}
        self.started_at = time.time()

    def authorized_role(self, authorization: str, *roles: str) -> str | None:
        """Return the exact capability presented, without logging its token."""

        if not self.authentication_required:
            return "unauthenticated" if self.allow_unauthenticated else None
        received = authorization or ""
        for role in roles:
            expected_token = self._role_tokens.get(role)
            if expected_token is None:
                continue
            expected = f"Bearer {expected_token}"
            if secrets.compare_digest(received.encode("utf-8"), expected.encode("utf-8")):
                return role
        return None

    def authorized(self, authorization: str, *roles: str) -> bool:
        """Check one purpose-bound bearer credential without exposing secrets."""

        return self.authorized_role(authorization, *roles) is not None

    def consume_request_budget(self, role: str) -> tuple[bool, float]:
        """Token-bucket rate limit with a fixed, capability-sized key space."""

        now = time.monotonic()
        with self._condition:
            tokens, last = self._rate_buckets.get(
                role,
                (float(self.rate_limit_burst), now),
            )
            tokens = min(
                float(self.rate_limit_burst),
                tokens + max(0.0, now - last) * self.rate_limit_per_second,
            )
            if tokens < 1.0:
                self._rate_buckets[role] = (tokens, now)
                return False, (1.0 - tokens) / self.rate_limit_per_second
            self._rate_buckets[role] = (tokens - 1.0, now)
            return True, 0.0

    # ---------------------------------------------------------------- sessions

    def register(self, payload: dict[str, Any]) -> dict[str, Any]:
        protocol = str(payload.get("protocol") or "")
        if protocol != PROTOCOL_VERSION:
            raise BridgeError(
                ErrorCode.PROTOCOL,
                f"plugin speaks {protocol or 'an unknown protocol'}, hub speaks {PROTOCOL_VERSION}",
                {"pluginProtocol": protocol, "hubProtocol": PROTOCOL_VERSION},
            )
        client_id = str(payload.get("clientId") or "").strip()
        installation_id = str(payload.get("installationId") or "").strip()
        context = str(payload.get("context") or "edit")
        if not client_id or len(client_id) > 128:
            raise BridgeError(ErrorCode.BAD_PARAMS, "clientId must contain 1 to 128 characters")
        if (
            len(installation_id) < 16
            or len(installation_id) > 128
            or any(character in installation_id for character in "\r\n\0")
        ):
            raise BridgeError(
                ErrorCode.BAD_PARAMS,
                "installationId must contain 16 to 128 non-control characters",
            )
        if context not in {"edit", "run", "server", "client"}:
            raise BridgeError(ErrorCode.BAD_PARAMS, f"unsupported plugin context: {context}")
        session = SessionInfo(
            id=new_session_id(),
            plugin_version=str(payload.get("pluginVersion") or "unknown")[:128],
            plugin_build_id=str(payload.get("pluginBuildId") or "unknown")[:128],
            studio_version=str(payload.get("studioVersion") or "unknown")[:128],
            place_name=str(payload.get("placeName") or "")[:512],
            place_id=int(payload.get("placeId") or 0),
            context=context,
            client_id=client_id,
            installation_id=installation_id,
        )
        session_key = secrets.token_urlsafe(32)
        with self._condition:
            self._reap_locked()
            collisions = [
                existing
                for existing in self._sessions.values()
                if existing.client_id == session.client_id
            ]
            replacing = bool(collisions)
            if collisions and self.authentication_required:
                resume_session = str(payload.get("resumeSession") or "")
                resume_key = str(payload.get("resumeKey") or "")
                if len(collisions) != 1:
                    raise BridgeError(
                        ErrorCode.SESSION_CONFLICT,
                        "multiple live sessions claim the same client identity",
                    )
                previous = collisions[0]
                expected = self._session_keys.get(previous.id, "")
                valid_resume = (
                    previous.installation_id == installation_id
                    and resume_session == previous.id
                    and bool(expected)
                    and secrets.compare_digest(
                        resume_key.encode("utf-8"),
                        expected.encode("utf-8"),
                    )
                )
                if not valid_resume:
                    raise BridgeError(
                        ErrorCode.SESSION_CONFLICT,
                        "a live session already owns this client identity",
                        {"remedy": "resume with the previous session proof or wait for it to expire"},
                    )
            if not replacing and len(self._sessions) >= self.max_sessions:
                raise BridgeError(
                    ErrorCode.CAPACITY,
                    f"hub session capacity reached ({self.max_sessions})",
                )
            # Register first so the new queue exists to receive transferred work.
            self._sessions[session.id] = session
            self._session_keys[session.id] = session_key
            self._queues[session.id] = deque()
            # The same Studio re-registers when it switches edit <-> run. Retire
            # the abandoned session now instead of waiting for it to go stale,
            # or commands could be routed to a session that no longer polls.
            if session.client_id:
                superseded = [
                    key for key, existing in self._sessions.items()
                    if existing.client_id == session.client_id and key != session.id
                ]
                for key in superseded:
                    LOGGER.info("superseding session %s for client %s", key, session.client_id)
                    self._drop_session_locked(
                        key,
                        "superseded by a new handshake from the same Studio",
                        transfer_to=session.id,
                    )
            self._condition.notify_all()
        LOGGER.info("plugin connected: %s (%s, %s)", session.id, session.place_name, session.context)
        return {
            "session": session.id,
            "sessionKey": session_key,
            "protocol": PROTOCOL_VERSION,
            "pollHoldSeconds": self.poll_hold_seconds,
            "heartbeatSeconds": self.poll_hold_seconds / 2,
        }

    def require_session_proof(self, session_id: str, session_key: str) -> None:
        """Authenticate one plugin transport request to its exact session."""

        with self._condition:
            expected = self._session_keys.get(session_id, "")
            valid = (
                bool(expected)
                and isinstance(session_key, str)
                and secrets.compare_digest(
                    session_key.encode("utf-8"),
                    expected.encode("utf-8"),
                )
            )
        if not valid:
            raise BridgeError(
                ErrorCode.UNAUTHORIZED,
                "valid session proof required; re-run the plugin handshake",
            )

    def sessions(self) -> list[dict[str, Any]]:
        with self._condition:
            self._reap_locked()
            return [session.to_dict() for session in self._sessions.values()]

    # ------------------------------------------------------------------ leases

    @staticmethod
    def _lease_text(value: Any, field: str) -> str:
        if not isinstance(value, str) or not value.strip():
            raise BridgeError(ErrorCode.BAD_PARAMS, f"lease {field} must be a non-empty string")
        return value.strip()

    @staticmethod
    def _lease_ttl(value: Any) -> float:
        try:
            ttl = float(value)
        except (TypeError, ValueError) as exc:
            raise BridgeError(ErrorCode.BAD_PARAMS, "lease ttlSeconds must be a number") from exc
        if not 1.0 <= ttl <= 300.0:
            raise BridgeError(ErrorCode.BAD_PARAMS, "lease ttlSeconds must be between 1 and 300")
        return ttl

    def _reap_leases_locked(self, now: float | None = None) -> None:
        current = now if now is not None else time.monotonic()
        for lease_id, lease in list(self._leases.items()):
            if lease.expired(current) or lease.session_id not in self._sessions:
                self._leases.pop(lease_id, None)

    def acquire_lease(
        self,
        *,
        run_id: str,
        agent_id: str,
        build_id: str,
        session_id: str,
        ttl_seconds: float = 30.0,
    ) -> dict[str, Any]:
        """Acquire one exclusive, fenced lease on an exact session/build target."""

        run_id = self._lease_text(run_id, "runId")
        agent_id = self._lease_text(agent_id, "agentId")
        build_id = self._lease_text(build_id, "buildId")
        session_id = self._lease_text(session_id, "session")
        ttl = self._lease_ttl(ttl_seconds)
        with self._condition:
            self._reap_locked()
            session = self._sessions.get(session_id)
            if session is None:
                raise BridgeError(ErrorCode.NOT_FOUND, f"no connected plugin session {session_id}")
            self._reap_leases_locked()
            active = next((item for item in self._leases.values() if item.session_id == session_id), None)
            if active is not None:
                if (active.run_id, active.agent_id, active.build_id) == (run_id, agent_id, build_id):
                    # Idempotent reacquisition by the same owner renews without
                    # advancing the fence. A new owner always receives a higher
                    # fence, so a paused old agent cannot become current again.
                    active.expires_monotonic = time.monotonic() + ttl
                    return active.to_dict()
                raise BridgeError(
                    ErrorCode.LEASE_CONFLICT,
                    f"session {session_id} is leased by another run/agent",
                    {"target": active.to_dict()},
                )

            self._next_fence += 1
            now = time.monotonic()
            lease = SessionLease(
                id=f"lease_{secrets.token_hex(8)}",
                fence=self._next_fence,
                run_id=run_id,
                agent_id=agent_id,
                build_id=build_id,
                session_id=session_id,
                client_id=session.client_id,
                acquired_monotonic=now,
                expires_monotonic=now + ttl,
            )
            self._leases[lease.id] = lease
            self._condition.notify_all()
            return lease.to_dict()

    def renew_lease(
        self,
        *,
        lease_id: str,
        fence: int,
        run_id: str,
        agent_id: str,
        build_id: str,
        session_id: str,
        ttl_seconds: float = 30.0,
    ) -> dict[str, Any]:
        ttl = self._lease_ttl(ttl_seconds)
        with self._condition:
            lease = self._validate_lease_locked({
                "leaseId": lease_id,
                "fence": fence,
                "runId": run_id,
                "agentId": agent_id,
                "buildId": build_id,
                "session": session_id,
            }, session_id)
            lease.expires_monotonic = time.monotonic() + ttl
            self._condition.notify_all()
            return lease.to_dict()

    def release_lease(
        self,
        *,
        lease_id: str,
        fence: int,
        run_id: str,
        agent_id: str,
        build_id: str,
        session_id: str,
    ) -> dict[str, Any]:
        with self._condition:
            lease = self._validate_lease_locked({
                "leaseId": lease_id,
                "fence": fence,
                "runId": run_id,
                "agentId": agent_id,
                "buildId": build_id,
                "session": session_id,
            }, session_id)
            self._leases.pop(lease.id, None)
            self._condition.notify_all()
            return {"released": True, **lease.to_dict()}

    def _validate_lease_locked(self, metadata: dict[str, Any], session_id: str) -> SessionLease:
        if not isinstance(metadata, dict):
            raise BridgeError(ErrorCode.LEASE_REQUIRED, "a fenced lease object is required")
        lease_id = self._lease_text(metadata.get("leaseId"), "leaseId")
        try:
            fence = int(metadata.get("fence"))
        except (TypeError, ValueError) as exc:
            raise BridgeError(ErrorCode.BAD_PARAMS, "lease fence must be an integer") from exc
        run_id = self._lease_text(metadata.get("runId"), "runId")
        agent_id = self._lease_text(metadata.get("agentId"), "agentId")
        build_id = self._lease_text(metadata.get("buildId"), "buildId")
        target_session = self._lease_text(metadata.get("session"), "session")
        if target_session != session_id:
            raise BridgeError(
                ErrorCode.TARGET_MISMATCH,
                "lease target session does not match the dispatched session",
                {"leaseSession": target_session, "dispatchSession": session_id},
            )
        self._reap_leases_locked()
        lease = self._leases.get(lease_id)
        if lease is None:
            raise BridgeError(ErrorCode.LEASE_STALE, "lease is absent or expired", {"leaseId": lease_id, "fence": fence})
        expected = (lease.fence, lease.run_id, lease.agent_id, lease.build_id, lease.session_id)
        received = (fence, run_id, agent_id, build_id, target_session)
        if received != expected:
            raise BridgeError(
                ErrorCode.LEASE_STALE,
                "lease fence or target ownership is stale",
                {"expected": lease.to_dict(), "received": metadata},
            )
        return lease

    def _drop_session_locked(self, session_id: str, reason: str, transfer_to: str | None = None) -> None:
        """Remove a session, moving or failing whatever was queued for it.

        When the same Studio re-registers (edit <-> run), queued work is handed
        to the new session: it is the same Studio and the command never ran.
        In-flight commands are not transferred -- the plugin may already have
        executed them, and re-running a mutating command would be worse than
        reporting a failure.
        """
        self._sessions.pop(session_id, None)
        self._session_keys.pop(session_id, None)
        for lease_id, lease in list(self._leases.items()):
            if lease.session_id == session_id:
                self._leases.pop(lease_id, None)

        # An in-flight command may already have changed the DataModel, so it is
        # never transferred or re-run. Fail it immediately and state the
        # ambiguity instead of waiting for the caller timeout or accepting a
        # later answer from a replacement session.
        for command_id, assignment in list(self._inflight.items()):
            if assignment.session_id != session_id:
                continue
            self._inflight.pop(command_id, None)
            if command_id in self._abandoned_inflight:
                self._abandoned_inflight.discard(command_id)
                continue
            self._responses[command_id] = Response(
                id=command_id,
                ok=False,
                error={
                    "code": ErrorCode.DISCONNECTED,
                    "message": reason,
                    "details": {"session": session_id, "outcome": "unknown_after_dispatch"},
                },
                session=session_id,
            )

        queued = self._queues.pop(session_id, deque())
        target = self._queues.get(transfer_to) if transfer_to else None
        for command in queued:
            # A fenced command is bound to its exact session and build; moving it
            # would defeat the lease target. Legacy/unleased queued reads may be
            # moved to the same Studio's replacement session as before.
            if target is not None and not command.expired() and not command.lease:
                command.target["session"] = transfer_to
                target.append(command)
                continue
            self._responses[command.id] = Response(
                id=command.id,
                ok=False,
                error={"code": ErrorCode.DISCONNECTED, "message": reason},
            )

    def _reap_locked(self) -> None:
        stale = [key for key, session in self._sessions.items() if session.age_seconds() > SESSION_STALE_SECONDS]
        for key in stale:
            LOGGER.info("plugin session expired: %s", key)
            self._drop_session_locked(key, "plugin session expired before dispatch")
        self._reap_leases_locked()
        if stale:
            self._condition.notify_all()

    def _pick_session_locked(self, session_id: str | None, context: str | None = None) -> SessionInfo:
        self._reap_locked()
        if session_id:
            session = self._sessions.get(session_id)
            if session is None:
                raise BridgeError(ErrorCode.NOT_FOUND, f"no connected plugin session {session_id}")
            return session

        if context:
            # Some commands only mean something in a particular half of the
            # engine. `running` is the common case: gameplay commands are
            # meaningless against a Studio sitting in edit mode.
            if context == "running":
                matching = [item for item in self._sessions.values() if item.context != "edit"]
                description = "a running play session"
            else:
                matching = [item for item in self._sessions.values() if item.context == context]
                description = f"context '{context}'"
            if not matching:
                raise BridgeError(
                    ErrorCode.DISCONNECTED,
                    f"no connected session with {description}",
                    {
                        "available": sorted({item.context for item in self._sessions.values()}),
                        "hint": "start the game first: 'rqe studio play_solo' for a real player, or run.start for physics only",
                    },
                )
            return sorted(matching, key=lambda item: (item.poll_waiting == 0, item.poll_age_seconds() or item.age_seconds()))[0]
        if not self._sessions:
            raise BridgeError(
                ErrorCode.DISCONNECTED,
                "no Roblox Studio plugin is connected to the hub",
                {"hint": "open Studio with the RQE Studio Bridge plugin installed"},
            )
        # Liveness outranks context, and liveness means "is polling", not "said
        # hello". A Studio killed mid-playtest leaves a session that handshook
        # and looks young; routing to it produces timeouts while a healthy
        # plugin sits idle. A healthy plugin re-polls within one hold window.
        fresh_cutoff = self.poll_hold_seconds + 10
        candidates = [
            item for item in self._sessions.values()
            if item.polls > 0 and (item.poll_age_seconds() or 0) <= fresh_cutoff
        ]
        if not candidates:
            # Nothing has demonstrated liveness yet: fall back to anything that
            # at least contacted us recently, so a just-connected plugin still
            # works during the moment before its first poll lands.
            candidates = [item for item in self._sessions.values() if item.age_seconds() <= fresh_cutoff]
        if not candidates:
            candidates = list(self._sessions.values())

        # Rank, do not filter. An open poll is the strongest liveness signal, but
        # filtering on it discarded the context preference whenever the edit
        # session happened to be mid-poll and the run session was not -- which
        # sent gameplay commands to a Studio that was not running the game.
        ordered = sorted(
            candidates,
            key=lambda item: (
                item.poll_waiting == 0,
                item.context == "edit",
                item.poll_age_seconds() or item.age_seconds(),
            ),
        )
        return ordered[0]

    # ---------------------------------------------------------------- commands

    def _remove_queued_locked(self, session_id: str, command_id: str) -> bool:
        queue = self._queues.get(session_id)
        if not queue:
            return False
        kept = deque(command for command in queue if command.id != command_id)
        removed = len(kept) != len(queue)
        if removed:
            self._queues[session_id] = kept
        return removed

    def call(
        self,
        method: str,
        params: dict[str, Any] | None = None,
        timeout: float = 15.0,
        session_id: str | None = None,
        context: str | None = None,
        lease: dict[str, Any] | None = None,
    ) -> Response:
        """Enqueue a command for a plugin and block until it answers."""
        try:
            spec = self.command_registry.require(method)
        except CommandRegistryError as exc:
            raise BridgeError(
                ErrorCode.UNKNOWN_METHOD,
                f"no such command: {method}",
                {"available": list(self.command_registry.methods())},
            ) from exc
        if spec.availability != "supported":
            raise BridgeError(
                ErrorCode.UNAVAILABLE,
                f"{method} is declared {spec.availability} in the command manifest",
                {"methodVersion": spec.method_version, "availability": spec.availability},
            )
        command_params = {} if params is None else params
        try:
            spec.validate_params(command_params)
        except CommandValidationError as exc:
            raise BridgeError(ErrorCode.BAD_PARAMS, str(exc), {"issues": exc.issues, "methodVersion": spec.method_version}) from exc
        if (
            not isinstance(timeout, (int, float))
            or isinstance(timeout, bool)
            or not math.isfinite(float(timeout))
            or timeout <= 0
            or timeout > MAX_COMMAND_TIMEOUT_SECONDS
        ):
            raise BridgeError(
                ErrorCode.BAD_PARAMS,
                f"command timeout must be between 0 and {MAX_COMMAND_TIMEOUT_SECONDS:g} seconds",
            )

        # Playing the game and inspecting the player only exist while the game
        # runs. Pinning them to a running session stops a stray edit-mode
        # answer from being read as a gameplay result.
        if context is None and (method.startswith("client.") or method.startswith("actor.") or method == "run.players"):
            context = "running"
        with self._condition:
            session = self._pick_session_locked(session_id, context)
            if session.context not in spec.contexts:
                raise BridgeError(
                    ErrorCode.UNSUPPORTED_CONTEXT,
                    f"{method} v{spec.method_version} does not support context {session.context}",
                    {"allowed": sorted(spec.contexts), "session": session.id},
                )

            lease_record: SessionLease | None = None
            if lease is not None:
                lease_record = self._validate_lease_locked(lease, session.id)
            elif (
                (self.enforce_manifest_leases and spec.lease_targeted)
                or (self.require_mutation_leases and spec.mutates)
            ):
                raise BridgeError(
                    ErrorCode.LEASE_REQUIRED,
                    f"{method} requires an exclusive fenced lease",
                    {
                        "effect": spec.effect,
                        "session": session.id,
                        "manifestBuildSelector": spec.selector["build"],
                    },
                )

            command = Command(
                method=method,
                params=command_params,
                method_version=spec.method_version,
                target={
                    "session": session.id,
                    "clientId": session.client_id,
                    "runId": lease_record.run_id if lease_record else None,
                    "agentId": lease_record.agent_id if lease_record else None,
                    "buildId": lease_record.build_id if lease_record else None,
                },
                lease={"leaseId": lease_record.id, "fence": lease_record.fence} if lease_record else {},
                deadline_ms=int(timeout * 1000),
            )
            queue = self._queues[session.id]
            if len(queue) >= self.max_queue_per_session:
                raise BridgeError(
                    ErrorCode.CAPACITY,
                    f"session command queue capacity reached ({self.max_queue_per_session})",
                    {"session": session.id},
                )
            queue.append(command)
            session.commands_dispatched += 1
            self._condition.notify_all()
            deadline = time.monotonic() + timeout
            while command.id not in self._responses:
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    removed_before_dispatch = self._remove_queued_locked(session.id, command.id)
                    outcome = "not_dispatched" if removed_before_dispatch else "unknown_after_dispatch"
                    if not removed_before_dispatch and command.id in self._inflight:
                        self._abandoned_inflight.add(command.id)
                    raise BridgeError(
                        ErrorCode.TIMEOUT,
                        f"plugin did not answer {method} within {timeout:.1f}s",
                        {"commandId": command.id, "session": session.id, "outcome": outcome},
                    )
                self._condition.wait(remaining)
            return self._responses.pop(command.id)

    def _take_dispatchable_locked(
        self,
        session_id: str,
        queue: deque[Command],
        max_batch: int,
    ) -> list[Command]:
        """Take one write-like command or a parallel prefix of safe reads.

        Command effects are part of the versioned registry.  Reads may share a
        batch, but transient work, mutations, context transitions and arbitrary
        execution form an exclusive barrier.  FIFO is intentional: later reads
        cannot jump over a queued mutation and starve it forever.

        This is a concurrency barrier, not a frozen-world claim.  Runtime reads
        can still observe Heartbeat-driven changes; requirements needing one
        coherent epoch must use a typed compound snapshot command.
        """

        active = [
            assignment
            for assignment in self._inflight.values()
            if assignment.session_id == session_id
        ]
        if len(active) >= self.max_inflight_per_session:
            return []
        if any(assignment.effect != "read" for assignment in active):
            return []

        batch: list[Command] = []
        available = self.max_inflight_per_session - len(active)
        while queue and len(batch) < min(max_batch, available):
            command = queue[0]
            if command.expired():
                queue.popleft()
                self._responses[command.id] = Response(
                    id=command.id,
                    ok=False,
                    error={"code": ErrorCode.TIMEOUT, "message": "command expired in queue before the plugin polled"},
                )
                continue
            if command.target.get("session") != session_id:
                queue.popleft()
                self._responses[command.id] = Response(
                    id=command.id,
                    ok=False,
                    error={
                        "code": ErrorCode.TARGET_MISMATCH,
                        "message": "queued command target no longer matches the polling session",
                        "details": {"target": command.target, "pollingSession": session_id},
                    },
                )
                continue
            if command.lease:
                try:
                    self._validate_lease_locked({
                        "leaseId": command.lease.get("leaseId"),
                        "fence": command.lease.get("fence"),
                        "runId": command.target.get("runId"),
                        "agentId": command.target.get("agentId"),
                        "buildId": command.target.get("buildId"),
                        "session": command.target.get("session"),
                    }, session_id)
                except BridgeError as exc:
                    queue.popleft()
                    self._responses[command.id] = Response(
                        id=command.id,
                        ok=False,
                        error=exc.to_dict(),
                        session=session_id,
                    )
                    continue

            spec = self.command_registry.require(command.method)
            if spec.effect != "read" and (active or batch):
                break

            queue.popleft()
            self._inflight[command.id] = InflightAssignment(
                command=command,
                session_id=session_id,
                client_id=self._sessions[session_id].client_id,
                effect=spec.effect,
                dispatched_monotonic=time.monotonic(),
            )
            batch.append(command)
            if spec.effect != "read":
                break
        return batch

    def poll(self, session_id: str, max_batch: int = 8) -> dict[str, Any]:
        """Long-poll: hand the plugin any queued work, or hold until there is some."""
        with self._condition:
            session = self._sessions.get(session_id)
            if session is None:
                raise BridgeError(ErrorCode.NOT_FOUND, "unknown session; re-run the handshake", {"session": session_id})
            # Stamped once, here, because this is the moment the plugin actually
            # contacted us. Refreshing it inside the wait loop below would let
            # any other session's notify() rejuvenate a Studio that has already
            # been killed, so it would never go stale and would keep winning the
            # routing while its commands timed out.
            session.last_seen_monotonic = time.monotonic()
            session.last_poll_monotonic = session.last_seen_monotonic
            session.polls += 1
            max_batch = max(1, min(int(max_batch), 32))
            deadline = time.monotonic() + self.poll_hold_seconds
            queue = self._queues.setdefault(session_id, deque())
            session.poll_waiting += 1
            try:
                while True:
                    batch = self._take_dispatchable_locked(session_id, queue, max_batch)
                    if batch:
                        self._condition.notify_all()
                        return {"protocol": PROTOCOL_VERSION, "commands": [command.to_wire() for command in batch]}
                    remaining = deadline - time.monotonic()
                    if remaining <= 0:
                        return {"protocol": PROTOCOL_VERSION, "commands": []}
                    self._condition.wait(remaining)
                    if session_id not in self._sessions:
                        raise BridgeError(ErrorCode.DISCONNECTED, "session was reaped while polling")
                    queue = self._queues.setdefault(session_id, deque())
            finally:
                session.poll_waiting = max(0, session.poll_waiting - 1)
                self._condition.notify_all()

    def drop_sessions(self, session_ids: list[str], reason: str) -> list[str]:
        """Retire named sessions on the caller's authority.

        A caller that just terminated a Studio process knows those sessions are
        dead. The hub cannot know it on its own: a killed plugin's poll handler
        stays blocked until it tries to write, so the corpse keeps looking alive
        for up to one hold window and can still win the routing.
        """
        dropped: list[str] = []
        with self._condition:
            for session_id in session_ids:
                if session_id in self._sessions:
                    self._drop_session_locked(session_id, reason)
                    dropped.append(session_id)
            if dropped:
                LOGGER.info("retired %d session(s): %s", len(dropped), reason)
                self._condition.notify_all()
        return dropped

    def disconnected(self, session_id: str, reason: str) -> None:
        """Retire a session whose socket died, without waiting for it to go stale."""
        with self._condition:
            if session_id in self._sessions:
                LOGGER.info("session %s dropped: %s", session_id, reason)
                self._drop_session_locked(session_id, reason)
                self._condition.notify_all()

    def complete(self, session_id: str, results: list[dict[str, Any]]) -> dict[str, Any]:
        if not isinstance(results, list):
            raise BridgeError(ErrorCode.BAD_PARAMS, "results must be an array")
        if len(results) > MAX_RESULT_BATCH:
            raise BridgeError(
                ErrorCode.CAPACITY,
                f"result batch exceeds {MAX_RESULT_BATCH} entries",
            )
        accepted = 0
        rejected: list[dict[str, Any]] = []
        with self._condition:
            session = self._sessions.get(session_id)
            if session is None:
                raise BridgeError(ErrorCode.NOT_FOUND, "unknown session; re-run the handshake", {"session": session_id})
            session.last_seen_monotonic = time.monotonic()
            for payload in results:
                try:
                    response = Response.from_wire(payload)
                except BridgeError as exc:
                    # One malformed entry must not discard the rest of the batch.
                    LOGGER.warning("discarding malformed plugin result: %s", exc)
                    continue
                assignment = self._inflight.get(response.id)
                if assignment is None:
                    # A late answer to an already-timed-out command is dropped on
                    # purpose: the agent has moved on and must not see it later.
                    LOGGER.debug("dropping uncorrelated response %s", response.id)
                    rejected.append({"id": response.id, "code": ErrorCode.NOT_FOUND, "reason": "not_inflight"})
                    continue
                if assignment.session_id != session_id:
                    # Do not pop: the assigned session may still return the real
                    # answer. Correlation ids are global, but completion authority
                    # belongs only to the session that polled the command.
                    LOGGER.warning(
                        "rejecting response %s from session %s; dispatched to %s",
                        response.id,
                        session_id,
                        assignment.session_id,
                    )
                    rejected.append({
                        "id": response.id,
                        "code": ErrorCode.TARGET_MISMATCH,
                        "reason": "wrong_session",
                        "expectedSession": assignment.session_id,
                        "receivedSession": session_id,
                    })
                    continue
                self._inflight.pop(response.id, None)
                response.session = session_id
                if response.ok:
                    try:
                        self.command_registry.require(assignment.command.method).validate_result(response.result)
                    except (CommandRegistryError, CommandValidationError) as exc:
                        issues = exc.issues if isinstance(exc, CommandValidationError) else [str(exc)]
                        response = Response(
                            id=response.id,
                            ok=False,
                            error={
                                "code": ErrorCode.SCHEMA,
                                "message": f"plugin result failed {assignment.command.method} v{assignment.command.method_version} schema",
                                "details": {"issues": issues},
                            },
                            elapsed_ms=response.elapsed_ms,
                            context=response.context,
                            place=response.place,
                            session=session_id,
                        )
                if response.id in self._abandoned_inflight:
                    # The late answer resolves the scheduling barrier but its
                    # original caller already received an explicit uncertain
                    # timeout.  Retaining it would leak memory or let a future
                    # request consume evidence that belongs to another call.
                    self._abandoned_inflight.discard(response.id)
                else:
                    self._responses[response.id] = response
                session.commands_completed += 1
                accepted += 1
            self._condition.notify_all()
        return {"accepted": accepted, "rejected": rejected}

    # ------------------------------------------------------------------ events

    def push_events(self, session_id: str, events: list[dict[str, Any]]) -> dict[str, Any]:
        if not isinstance(events, list):
            raise BridgeError(ErrorCode.BAD_PARAMS, "events must be an array")
        if len(events) > MAX_EVENT_BATCH:
            raise BridgeError(
                ErrorCode.CAPACITY,
                f"event batch exceeds {MAX_EVENT_BATCH} entries",
            )
        accepted = 0
        with self._condition:
            session = self._sessions.get(session_id)
            if session is None:
                raise BridgeError(ErrorCode.NOT_FOUND, "unknown session; re-run the handshake", {"session": session_id})
            session.last_seen_monotonic = time.monotonic()
            for event in events:
                if isinstance(event, dict):
                    self._events.append({**event, "session": session_id, "receivedAt": time.time()})
                    accepted += 1
            self._condition.notify_all()
        return {"accepted": accepted}

    def events(self, since: float = 0.0, kind: str | None = None, limit: int = 200) -> list[dict[str, Any]]:
        if not math.isfinite(float(since)):
            raise BridgeError(ErrorCode.BAD_PARAMS, "event cursor must be finite")
        limit = max(1, min(int(limit), MAX_EVENT_QUERY))
        with self._condition:
            items = [event for event in self._events if event.get("receivedAt", 0) > since]
        if kind:
            items = [event for event in items if event.get("kind") == kind]
        return items[-limit:]

    def status(self) -> dict[str, Any]:
        with self._condition:
            self._reap_locked()
            self._reap_leases_locked()
            queued = sum(len(queue) for queue in self._queues.values())
            return {
                "protocol": PROTOCOL_VERSION,
                "commandSchemaVersion": self.command_registry.schema_version,
                "commandCount": len(self.command_registry),
                "authenticationRequired": self.authentication_required,
                "credentialModel": "derived-capability-v2" if self.authentication_required else "explicitly-disabled",
                "mutationLeasesEnforced": self.require_mutation_leases,
                "manifestLeasesEnforced": self.enforce_manifest_leases,
                "uptimeSeconds": round(time.time() - self.started_at, 1),
                "sessions": [session.to_dict() for session in self._sessions.values()],
                "leases": [lease.to_dict() for lease in sorted(self._leases.values(), key=lambda item: item.fence)],
                "queuedCommands": queued,
                "inflightCommands": len(self._inflight),
                "uncertainCommands": len(self._abandoned_inflight),
                "bufferedEvents": len(self._events),
            }


def make_handler(hub: BridgeHub) -> type[BaseHTTPRequestHandler]:
    class Handler(BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"
        server_version = "RQEBridgeHub/1.0"

        # ------------------------------------------------------------- helpers

        def setup(self) -> None:
            super().setup()
            self.connection.settimeout(SOCKET_IO_TIMEOUT_SECONDS)

        def handle_one_request(self) -> None:
            """Stdlib request dispatch with a smaller request-line budget."""

            try:
                self.raw_requestline = self.rfile.readline(MAX_REQUEST_LINE_BYTES + 1)
                if len(self.raw_requestline) > MAX_REQUEST_LINE_BYTES:
                    self.requestline = ""
                    self.request_version = ""
                    self.command = ""
                    self.send_error(414, "request target is too long")
                    self.close_connection = True
                    return
                if not self.raw_requestline:
                    self.close_connection = True
                    return
                if not self.parse_request():
                    return
                method_name = "do_" + self.command
                if not hasattr(self, method_name):
                    self.send_error(501, f"unsupported method ({self.command!r})")
                    return
                getattr(self, method_name)()
                self.wfile.flush()
            except TimeoutError:
                self.close_connection = True

        def parse_request(self) -> bool:
            if not super().parse_request():
                return False
            total = len(self.raw_requestline)
            total += sum(
                len(name.encode("utf-8")) + len(value.encode("utf-8")) + 4
                for name, value in self.headers.raw_items()
            )
            if total > MAX_HEADER_BYTES:
                self.close_connection = True
                self._send(
                    {"error": {"code": ErrorCode.CAPACITY, "message": "request headers exceed the hub byte limit"}},
                    431,
                )
                return False
            return True

        def _authorized(self, *roles: str) -> bool:
            return hub.authorized(self.headers.get("Authorization") or "", *roles)

        def _authorize_and_budget(self, *roles: str) -> bool:
            role = hub.authorized_role(self.headers.get("Authorization") or "", *roles)
            if role is None:
                self._reject_unauthorized()
                return False
            allowed, retry_after = hub.consume_request_budget(role)
            if not allowed:
                self._send(
                    {"error": {"code": ErrorCode.RATE_LIMITED, "message": "bridge request rate exceeded"}},
                    429,
                    extra_headers={"Retry-After": str(max(1, math.ceil(retry_after)))},
                )
                return False
            return True

        def _reject_unauthorized(self) -> None:
            self._send({"error": {"code": ErrorCode.UNAUTHORIZED, "message": "authenticated bridge token required"}}, 401)

        def _send(
            self,
            payload: Any,
            status: int = 200,
            *,
            extra_headers: dict[str, str] | None = None,
        ) -> None:
            body = json.dumps(payload, ensure_ascii=False).encode("utf-8")
            if len(body) > MAX_RESPONSE_BODY_BYTES:
                status = 507
                body = json.dumps({
                    "error": {
                        "code": ErrorCode.CAPACITY,
                        "message": "response exceeds the hub byte limit",
                    }
                }).encode("utf-8")
            self.send_response(status)
            self.send_header("Content-Type", "application/json; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Cache-Control", "no-store")
            self.send_header("X-Content-Type-Options", "nosniff")
            for name, value in (extra_headers or {}).items():
                self.send_header(name, value)
            self.end_headers()
            self.wfile.write(body)

        def _read_json(self) -> dict[str, Any]:
            if self.headers.get("Transfer-Encoding"):
                raise ValueError("Transfer-Encoding is not supported; send Content-Length")
            content_type = (self.headers.get("Content-Type") or "").split(";", 1)[0].strip().lower()
            if content_type != "application/json":
                raise ValueError("Content-Type must be application/json")
            value = self.headers.get("Content-Length")
            if value is None:
                raise ValueError("Content-Length is required")
            try:
                length = int(value)
            except ValueError as exc:
                raise ValueError("Content-Length must be an integer") from exc
            if length > MAX_REQUEST_BODY_BYTES:
                self.close_connection = True
                raise RequestBodyTooLarge(
                    f"request body exceeds {MAX_REQUEST_BODY_BYTES} bytes"
                )
            if length <= 0:
                raise ValueError("request body must not be empty")
            try:
                raw = self.rfile.read(length).decode("utf-8")
            except UnicodeDecodeError as exc:
                raise ValueError("request body must be UTF-8") from exc
            payload = json.loads(raw)
            if not isinstance(payload, dict):
                raise ValueError("request body must be a JSON object")
            return payload

        # --------------------------------------------------------------- verbs

        def do_GET(self) -> None:  # noqa: N802
            if not self._authorize_and_budget("reader", "admin"):
                return
            if self.path == "/health":
                self._send({"ok": True, "service": "rqe-bridge-hub", "protocol": PROTOCOL_VERSION})
                return
            if self.path.startswith("/status"):
                self._send(hub.status())
                return
            self._send({"error": ErrorCode.NOT_FOUND, "path": self.path}, 404)

        def do_POST(self) -> None:  # noqa: N802
            # Authenticate before reading or parsing an attacker-controlled
            # request body. Plugin and command capabilities are purpose-bound.
            required_roles = (
                ("plugin",)
                if self.path.startswith("/bridge/")
                else ("reader", "mutator", "executor", "admin")
            )
            if not self._authorize_and_budget(*required_roles):
                return
            try:
                payload = self._read_json()
            except RequestBodyTooLarge as exc:
                self._send({"error": {"code": ErrorCode.CAPACITY, "message": str(exc)}}, 413)
                return
            except (ValueError, json.JSONDecodeError) as exc:
                self._send({"error": {"code": ErrorCode.PROTOCOL, "message": str(exc)}}, 400)
                return

            try:
                if self.path == "/bridge/hello":
                    self._send(hub.register(payload))
                elif self.path == "/bridge/poll":
                    session_id = str(payload.get("session", ""))
                    hub.require_session_proof(
                        session_id,
                        str(payload.get("sessionKey", "")),
                    )
                    result = hub.poll(session_id, int(payload.get("maxBatch", 8)))
                    try:
                        self._send(result)
                    except (ConnectionError, OSError) as exc:
                        # The plugin vanished while we held its poll. Retire the
                        # session now rather than letting it look alive for the
                        # full stale window and keep winning the routing.
                        hub.disconnected(session_id, f"socket closed while answering a poll: {exc}")
                        raise
                elif self.path == "/bridge/result":
                    session_id = str(payload.get("session", ""))
                    hub.require_session_proof(
                        session_id,
                        str(payload.get("sessionKey", "")),
                    )
                    self._send(hub.complete(session_id, payload.get("results", [])))
                elif self.path == "/bridge/event":
                    session_id = str(payload.get("session", ""))
                    hub.require_session_proof(
                        session_id,
                        str(payload.get("sessionKey", "")),
                    )
                    self._send(hub.push_events(session_id, payload.get("events", [])))
                elif self.path == "/rpc":
                    self._handle_rpc(payload)
                else:
                    self._send({"error": {"code": ErrorCode.NOT_FOUND, "message": self.path}}, 404)
            except BridgeError as exc:
                status = 401 if exc.code == ErrorCode.UNAUTHORIZED else 409
                self._send({"error": exc.to_dict()}, status)
            except Exception as exc:  # the hub must survive any single bad request
                incident = secrets.token_hex(6)
                LOGGER.exception("hub request failed (incident %s)", incident)
                self._send({
                    "error": {
                        "code": ErrorCode.EXEC,
                        "message": "internal hub error",
                        "incident": incident,
                    }
                }, 500)

        def _handle_rpc(self, payload: dict[str, Any]) -> None:
            method = payload.get("method")
            params = payload.get("params") or {}
            if not isinstance(method, str) or not method:
                self._send(rpc_error(payload.get("id"), -32600, "method is required"), 400)
                return
            if not isinstance(params, dict):
                self._send(rpc_error(payload.get("id"), -32602, "params must be an object"), 400)
                return

            def require_capability(role: str, label: str) -> bool:
                if self._authorized(role, "admin"):
                    return True
                self._send(
                    rpc_error(
                        payload.get("id"),
                        -32001,
                        f"{label} capability required",
                        {"code": ErrorCode.UNAUTHORIZED, "requiredCapability": role},
                    ),
                    200,
                )
                return False
            try:
                if method == "hub.status":
                    if not require_capability("reader", "read"):
                        return
                    self._send(rpc_result(payload.get("id"), hub.status()))
                    return
                if method == "hub.drop_sessions":
                    if not self._authorized("admin"):
                        self._send(
                            rpc_error(
                                payload.get("id"),
                                -32001,
                                "administrative credential required",
                                {"code": ErrorCode.UNAUTHORIZED},
                            ),
                            200,
                        )
                        return
                    dropped = hub.drop_sessions(list(params.get("sessions", [])), str(params.get("reason", "retired by the caller")))
                    self._send(rpc_result(payload.get("id"), {"dropped": dropped}))
                    return
                if method == "hub.events":
                    if not require_capability("reader", "read"):
                        return
                    result = hub.events(float(params.get("since", 0)), params.get("kind"), int(params.get("limit", 200)))
                    self._send(rpc_result(payload.get("id"), result))
                    return
                if method == "hub.lease.acquire":
                    if not require_capability("mutator", "mutation"):
                        return
                    result = hub.acquire_lease(
                        run_id=params.get("runId"),
                        agent_id=params.get("agentId"),
                        build_id=params.get("buildId"),
                        session_id=params.get("session"),
                        ttl_seconds=params.get("ttlSeconds", 30),
                    )
                    self._send(rpc_result(payload.get("id"), result))
                    return
                if method == "hub.lease.renew":
                    if not require_capability("mutator", "mutation"):
                        return
                    result = hub.renew_lease(
                        lease_id=params.get("leaseId"),
                        fence=params.get("fence"),
                        run_id=params.get("runId"),
                        agent_id=params.get("agentId"),
                        build_id=params.get("buildId"),
                        session_id=params.get("session"),
                        ttl_seconds=params.get("ttlSeconds", 30),
                    )
                    self._send(rpc_result(payload.get("id"), result))
                    return
                if method == "hub.lease.release":
                    if not require_capability("mutator", "mutation"):
                        return
                    result = hub.release_lease(
                        lease_id=params.get("leaseId"),
                        fence=params.get("fence"),
                        run_id=params.get("runId"),
                        agent_id=params.get("agentId"),
                        build_id=params.get("buildId"),
                        session_id=params.get("session"),
                    )
                    self._send(rpc_result(payload.get("id"), result))
                    return
                try:
                    command_spec = hub.command_registry.require(method)
                except CommandRegistryError:
                    command_spec = None
                if command_spec is not None:
                    role = role_for_command_effect(command_spec.effect)
                    if not require_capability(role, command_spec.effect):
                        return
                timeout = float(params.pop("_timeout", 15.0))
                session_id = params.pop("_session", None)
                context = params.pop("_context", None)
                lease = params.pop("_lease", None)
                response = hub.call(method, params, timeout=timeout, session_id=session_id, context=context, lease=lease)
                self._send(rpc_result(payload.get("id"), response.to_dict()))
            except BridgeError as exc:
                self._send(rpc_error(payload.get("id"), -32000, exc.message, exc.to_dict()), 200)

        def log_message(self, format: str, *args: Any) -> None:
            LOGGER.debug("%s - %s", self.address_string(), format % args)

    return Handler


def _require_loopback_host(host: str) -> None:
    candidate = str(host).strip().strip("[]").lower()
    if candidate == "localhost":
        return
    try:
        if ipaddress.ip_address(candidate).is_loopback:
            return
    except ValueError:
        pass
    raise BridgeAuthError(
        f"bridge hub may bind only to loopback; refused host {host!r}"
    )


def serve(hub: BridgeHub, host: str = "127.0.0.1", port: int | None = None) -> ThreadingHTTPServer:
    #: `None`, not `0`. Zero is already meaningful to the socket API -- it asks
    #: the operating system for a free ephemeral port, which is how every test
    #: in `test_hub.py` binds -- so overloading it to mean "the workspace's
    #: port" made nine of them try to share the real hub's 8790.
    #:
    #: `None` means "wherever this workspace's hub lives", resolved now rather
    #: than frozen into a default at import time: a second agent sets
    #: RQE_HUB_PORT and its hub, its clients and its preflight all agree
    #: without anyone editing twenty-six literals.
    if port is None:
        port = hub_port()
    _require_loopback_host(host)
    """Start the hub. Returns the server so callers can shut it down."""
    server = ThreadingHTTPServer((host, port), make_handler(hub))
    server.daemon_threads = True
    return server


def serve_forever(hub: BridgeHub, host: str = "127.0.0.1", port: int | None = None) -> None:
    if port is None:
        port = hub_port()
    server = serve(hub, host, port)
    LOGGER.info("RQE Bridge Hub listening on http://%s:%d (protocol %s)", host, port, PROTOCOL_VERSION)
    try:
        server.serve_forever()
    finally:
        server.server_close()
