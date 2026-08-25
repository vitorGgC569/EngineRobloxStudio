"""MCP client: the engine consuming Roblox's built-in Studio MCP server.

Roblox ships an MCP server inside Studio with tools this bridge cannot have.
`user_keyboard_input` and `user_mouse_input` are the important ones: we measured
that `VirtualInputManager` is refused both in a LocalScript and in a plugin
(`lacking capability RobloxScript`), which left every GUI-driven requirement
permanently unmeasurable. Roblox's own server does it, because it runs at a
privilege level a third-party plugin does not get. `generate_mesh`,
`generate_material` and `search_asset` are the other reason to federate.

The rule for everything that comes back is fixed and non-negotiable:

    **Wrap, do not trust.**

A federated tool result arrives as untyped text. It is re-typed, stamped
`source="roblox-studio-mcp"`, bound to a run and a build, and marked
inconclusive when it cannot be parsed. Skipping that step would reintroduce
exactly the defect this platform was built to eliminate: an unverified string
that scores.
"""

from __future__ import annotations

import random
import subprocess
import threading
import time
from dataclasses import dataclass, field
from datetime import datetime, timezone
from typing import Any, Mapping, Sequence

from . import protocol
from .protocol import ProtocolError, Request, Response


#: Provenance stamp. Federated results are evidence from a peer we do not
#: control, and they must never be indistinguishable from our own measurements.
FEDERATED_SOURCE = "roblox-studio-mcp"

#: Tools worth adopting, and what each one closes. Declared rather than
#: discovered so an unexpected tool appearing upstream does not silently become
#: part of our measurement surface.
ADOPTED_TOOLS = {
    "user_keyboard_input": "synthesised keyboard input, which VirtualInputManager refuses us",
    "user_mouse_input": "synthesised mouse input, so GUI requirements stop being unmeasurable",
    "character_navigation": "player-driven traversal without our synthetic actor",
    "generate_mesh": "Cube 3D mesh generation",
    "generate_material": "PBR material generation",
    "generate_procedural_model": "multi-part model generation",
    "search_asset": "Creator Store discovery with metadata",
    "insert_asset": "asset insertion into the open place",
    "run_code": "arbitrary Luau against the open place",
    "execute_luau": "arbitrary Luau against the open place",
}


class McpClientError(RuntimeError):
    """The peer could not be reached or spoke incorrectly."""


@dataclass(frozen=True)
class ToolDescriptor:
    name: str
    description: str = ""
    input_schema: Mapping[str, Any] = field(default_factory=dict)

    @property
    def adopted(self) -> bool:
        return self.name in ADOPTED_TOOLS

    def to_dict(self) -> dict[str, Any]:
        return {
            "name": self.name,
            "description": self.description,
            "adopted": self.adopted,
            "closes": ADOPTED_TOOLS.get(self.name),
        }


@dataclass(frozen=True)
class FederatedResult:
    """A peer's answer, wrapped so it can never pass as our own measurement."""

    tool: str
    ok: bool
    text: str = ""
    structured: Any = None
    error: str | None = None
    observed_at: str = ""
    run_id: str = ""
    build_hash: str = ""

    @property
    def conclusive(self) -> bool:
        """A tool that ran is not the same as a tool that answered.

        Roblox's tools return prose. When nothing structured could be recovered,
        the result is admissible as a log line and inadmissible as a measurement,
        and this is the flag that keeps those apart.
        """

        return self.ok and self.structured is not None

    def to_evidence_detail(self) -> dict[str, Any]:
        return {
            "source": FEDERATED_SOURCE,
            "tool": self.tool,
            "ok": self.ok,
            "conclusive": self.conclusive,
            "observedAt": self.observed_at,
            "runId": self.run_id,
            "buildHash": self.build_hash,
            "error": self.error,
            "textLength": len(self.text),
        }


class StdioPeer:
    """A JSON-RPC peer over a pair of byte streams."""

    def __init__(self, stdin, stdout, *, on_close=None) -> None:
        self._stdin = stdin
        self._stdout = stdout
        self._on_close = on_close
        self._lock = threading.Lock()
        self._next_id = 0

    def close(self) -> None:
        if self._on_close is not None:
            self._on_close()

    def call(self, method: str, params: dict[str, Any] | None = None, *, timeout: float = 60.0) -> Response:
        with self._lock:
            self._next_id += 1
            request = Request(method=method, params=params or {}, id=self._next_id)
            self._stdin.write(protocol.encode(request.to_dict()))
            self._stdin.flush()

            while True:
                line = self._stdout.readline()
                if not line:
                    raise McpClientError(f"peer closed the stream while awaiting {method!r}")
                try:
                    document = protocol.decode(line)
                except ProtocolError:
                    # Anything unframed on this pipe means the peer is no longer
                    # speaking JSON-RPC. Skipping would hang; failing names it.
                    raise McpClientError(
                        f"peer wrote a non-JSON-RPC line while awaiting {method!r}: {line[:200]!r}"
                    )
                if "method" in document and "id" not in document:
                    continue  # a notification from the peer; not our answer
                if document.get("id") != request.id:
                    continue
                return protocol.parse_response(document)

    def notify(self, method: str, params: dict[str, Any] | None = None) -> None:
        with self._lock:
            self._stdin.write(protocol.encode(Request(method=method, params=params or {}).to_dict()))
            self._stdin.flush()


class StudioMcpClient:
    """Federated access to Roblox's built-in Studio MCP server."""

    def __init__(self, peer: StdioPeer, *, client_name: str = "rqe-engine") -> None:
        self.peer = peer
        self.client_name = client_name
        self._tools: tuple[ToolDescriptor, ...] | None = None
        self._server_info: dict[str, Any] = {}

    # -- lifecycle -------------------------------------------------------

    @classmethod
    def spawn(cls, command: Sequence[str], **kwargs: Any) -> "StudioMcpClient":
        process = subprocess.Popen(
            list(command),
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
        )
        peer = StdioPeer(process.stdin, process.stdout, on_close=process.terminate)
        return cls(peer, **kwargs)

    def initialize(self, *, timeout: float = 30.0) -> dict[str, Any]:
        response = self.peer.call(
            "initialize",
            {
                "protocolVersion": protocol.PROTOCOL_VERSION,
                "capabilities": {},
                "clientInfo": {"name": self.client_name, "version": "1.0.0"},
            },
            timeout=timeout,
        )
        if not response.ok:
            raise McpClientError(f"initialize failed: {response.error}")
        self._server_info = response.result if isinstance(response.result, dict) else {}
        self.peer.notify("notifications/initialized")
        return self._server_info

    def close(self) -> None:
        self.peer.close()

    # -- discovery -------------------------------------------------------

    def tools(self, *, refresh: bool = False) -> tuple[ToolDescriptor, ...]:
        if self._tools is not None and not refresh:
            return self._tools
        response = self.peer.call("tools/list")
        if not response.ok:
            raise McpClientError(f"tools/list failed: {response.error}")
        raw = (response.result or {}).get("tools", [])
        descriptors = []
        for item in raw if isinstance(raw, list) else []:
            if isinstance(item, dict) and isinstance(item.get("name"), str):
                descriptors.append(ToolDescriptor(
                    name=item["name"],
                    description=str(item.get("description") or ""),
                    input_schema=item.get("inputSchema") or {},
                ))
        self._tools = tuple(descriptors)
        return self._tools

    def coverage(self) -> dict[str, Any]:
        """Which adopted capabilities this peer actually offers.

        An adopted tool that is missing upstream is a capability we planned
        around and do not have. Reporting it beats discovering it from a call
        that returns `method not found` in the middle of a run.
        """

        available = {descriptor.name for descriptor in self.tools()}
        missing = sorted(set(ADOPTED_TOOLS) - available)
        return {
            "peerTools": len(available),
            "adoptedAvailable": sorted(set(ADOPTED_TOOLS) & available),
            "adoptedMissing": missing,
            "complete": not missing,
        }

    # -- invocation ------------------------------------------------------

    def call_tool(
        self,
        name: str,
        arguments: Mapping[str, Any] | None = None,
        *,
        run_id: str = "",
        build_hash: str = "",
        timeout: float = 120.0,
    ) -> FederatedResult:
        """Invoke a peer tool and wrap the answer."""

        observed_at = datetime.now(timezone.utc).isoformat()
        try:
            response = self.peer.call(
                "tools/call",
                {"name": name, "arguments": dict(arguments or {})},
                timeout=timeout,
            )
        except McpClientError as exc:
            return FederatedResult(
                tool=name, ok=False, error=str(exc),
                observed_at=observed_at, run_id=run_id, build_hash=build_hash,
            )

        if not response.ok:
            return FederatedResult(
                tool=name, ok=False,
                error=str((response.error or {}).get("message") or response.error),
                observed_at=observed_at, run_id=run_id, build_hash=build_hash,
            )

        result = response.result if isinstance(response.result, dict) else {}
        text = _text_of(result)
        # MCP signals a tool that ran and failed with isError, not with a
        # JSON-RPC error. Treating that as success is how a failed action gets
        # recorded as a completed one.
        if result.get("isError") is True:
            return FederatedResult(
                tool=name, ok=False, text=text, error=text or "tool reported an error",
                observed_at=observed_at, run_id=run_id, build_hash=build_hash,
            )

        return FederatedResult(
            tool=name,
            ok=True,
            text=text,
            structured=result.get("structuredContent"),
            observed_at=observed_at,
            run_id=run_id,
            build_hash=build_hash,
        )


def _text_of(result: Mapping[str, Any]) -> str:
    content = result.get("content")
    if not isinstance(content, list):
        return ""
    parts = [
        str(item.get("text", ""))
        for item in content
        if isinstance(item, dict) and item.get("type") == "text"
    ]
    return "\n".join(part for part in parts if part)


class CircuitBreaker:
    """Fail-closed gate: after N consecutive failures the peer is considered
    down for a cooldown instead of every caller paying the timeout again."""

    def __init__(
        self,
        *,
        threshold: int = 5,
        cooldown_seconds: float = 60.0,
        clock: Callable[[], float] = time.monotonic,
    ) -> None:
        self._threshold = max(1, threshold)
        self._cooldown = cooldown_seconds
        self._clock = clock
        self._consecutive_failures = 0
        self._opened_at: float | None = None

    def allow(self) -> tuple[bool, float]:
        """(allowed, seconds_until_retry)."""
        if self._opened_at is None:
            return True, 0.0
        elapsed = self._clock() - self._opened_at
        if elapsed >= self._cooldown:
            # half-open: one probe is allowed through.
            return True, 0.0
        return False, round(self._cooldown - elapsed, 3)

    def record_success(self) -> None:
        self._consecutive_failures = 0
        self._opened_at = None

    def record_failure(self) -> bool:
        """Returns True when this failure OPENED the breaker."""
        self._consecutive_failures += 1
        if self._consecutive_failures >= self._threshold and self._opened_at is None:
            self._opened_at = self._clock()
            return True
        return False

    def state(self) -> dict[str, Any]:
        allowed, retry_in = self.allow()
        return {
            "state": "closed" if self._opened_at is None else ("half-open" if allowed else "open"),
            "consecutiveFailures": self._consecutive_failures,
            "retryIn": retry_in,
        }


class ResilientSession:
    """A StudioMcpClient lifecycle with StarCode's reliability patterns:
    circuit breaker over consecutive failures, per-call watchdog (the peer's
    timeout), and reconnect with jittered backoff. The wrapped call contract
    is unchanged -- results stay FederatedResults either way."""

    def __init__(
        self,
        command: Sequence[str],
        *,
        breaker: CircuitBreaker | None = None,
        max_retries: int = 2,
        base_backoff: float = 0.5,
        jitter: float = 0.25,
        call_timeout: float = 60.0,
        client_name: str = "rqe-engine",
        clock: Callable[[], float] = time.monotonic,
        sleep: Callable[[float], None] = time.sleep,
    ) -> None:
        self._command = list(command)
        self._breaker = breaker or CircuitBreaker()
        self._max_retries = max_retries
        self._base_backoff = base_backoff
        self._jitter = jitter
        self._call_timeout = call_timeout
        self._client_name = client_name
        self._clock = clock
        self._sleep = sleep
        self._client: StudioMcpClient | None = None

    def _connect(self) -> StudioMcpClient:
        process = subprocess.Popen(
            self._command,
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
        )
        peer = StdioPeer(process.stdin, process.stdout, on_close=process.terminate)
        client = StudioMcpClient(peer, client_name=self._client_name)
        client.initialize(timeout=30.0)
        return client

    def _disconnect(self) -> None:
        if self._client is not None:
            try:
                self._client.close()
            except Exception:  # noqa: BLE001
                pass
            self._client = None

    def breaker_state(self) -> dict[str, Any]:
        return self._breaker.state()

    def call_tool(
        self,
        name: str,
        arguments: Mapping[str, Any] | None = None,
        *,
        run_id: str = "",
        build_hash: str = "",
    ) -> FederatedResult:
        observed_at = datetime.now(timezone.utc).isoformat()
        allowed, retry_in = self._breaker.allow()
        if not allowed:
            return FederatedResult(
                tool=name,
                ok=False,
                error=f"circuit open; retry in {retry_in}s",
                observed_at=observed_at,
                run_id=run_id,
                build_hash=build_hash,
            )

        last_error = ""
        for attempt in range(self._max_retries + 1):
            try:
                if self._client is None:
                    self._client = self._connect()
                result = self._client.call_tool(
                    name,
                    arguments,
                    run_id=run_id,
                    build_hash=build_hash,
                    timeout=self._call_timeout,
                )
                self._breaker.record_success()
                return result
            except McpClientError as exc:
                last_error = str(exc)
                self.opened_now = self._breaker.record_failure()
                self._disconnect()
                if attempt < self._max_retries:
                    backoff = self._base_backoff * (2**attempt)
                    self._sleep(backoff + random.uniform(0, self._jitter))

        return FederatedResult(
            tool=name,
            ok=False,
            error=f"exhausted {self._max_retries + 1} attempts: {last_error}",
            observed_at=observed_at,
            run_id=run_id,
            build_hash=build_hash,
        )

    def close(self) -> None:
        self._disconnect()
