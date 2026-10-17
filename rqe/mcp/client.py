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

import math
import os
from pathlib import Path
import sys
import queue
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
    "list_roblox_studios": "explicit Studio identity discovery",
    "screen_capture": "capture the selected Studio viewport",
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

MAX_PEER_MESSAGE_BYTES = 8 * 1024 * 1024
MAX_PEER_TIMEOUT_SECONDS = 300.0


class McpClientError(RuntimeError):
    """The peer could not be reached or spoke incorrectly."""


def studio_mcp_command() -> list[str]:
    """Locate Roblox's installed MCP entry point without launching Studio."""
    if os.name == "nt":
        path = Path(os.environ.get("LOCALAPPDATA", "")) / "Roblox" / "mcp.bat"
        if not path.is_file():
            raise McpClientError("Roblox MCP entry point is unavailable; enable MCP in Studio settings")
        return [os.environ.get("COMSPEC", "cmd.exe"), "/d", "/c", str(path.resolve())]
    if sys.platform == "darwin":
        path = Path("/Applications/RobloxStudio.app/Contents/MacOS/StudioMCP")
        if path.is_file():
            return [str(path)]
    raise McpClientError("Roblox Studio MCP is not installed on this platform")


def _spawn_process(command: Sequence[str]) -> subprocess.Popen[bytes]:
    options: dict[str, Any] = {
        "stdin": subprocess.PIPE,
        "stdout": subprocess.PIPE,
        "stderr": subprocess.DEVNULL,
    }
    if os.name == "nt":
        options["creationflags"] = subprocess.CREATE_NEW_PROCESS_GROUP | subprocess.CREATE_NO_WINDOW
    else:
        options["start_new_session"] = True
    return subprocess.Popen(list(command), **options)


def _terminate_process(process: subprocess.Popen[bytes], grace_seconds: float = 3.0) -> None:
    """Stop exactly the process RQE created, escalating only after a wait."""

    if process.poll() is None:
        process.terminate()
        try:
            process.wait(timeout=grace_seconds)
        except subprocess.TimeoutExpired:
            if os.name == "nt":
                # /PID scopes the tree cleanup to the process created above;
                # never use the global `/IM RobloxStudioBeta.exe` pattern.
                subprocess.run(
                    ["taskkill", "/PID", str(process.pid), "/T", "/F"],
                    stdout=subprocess.DEVNULL,
                    stderr=subprocess.DEVNULL,
                    check=False,
                    timeout=grace_seconds,
                )
            else:
                try:
                    os.killpg(process.pid, 9)
                except (ProcessLookupError, PermissionError):
                    process.kill()
            try:
                process.wait(timeout=grace_seconds)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait(timeout=grace_seconds)
    for stream in (process.stdin, process.stdout, process.stderr):
        if stream is not None:
            try:
                stream.close()
            except OSError:
                pass


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
    transport_error: bool = False

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
        self._write_lock = threading.Lock()
        self._state_lock = threading.RLock()
        self._next_id = 0
        self._pending: dict[Any, queue.Queue[Response | McpClientError]] = {}
        self._reader_thread: threading.Thread | None = None
        self._closed = False

    def close(self) -> None:
        with self._state_lock:
            if self._closed:
                return
            self._closed = True
            pending = list(self._pending.values())
            self._pending.clear()
        failure = McpClientError("peer was closed")
        for response_queue in pending:
            response_queue.put_nowait(failure)
        if self._on_close is not None:
            self._on_close()

    def _fail_pending(self, failure: McpClientError) -> None:
        with self._state_lock:
            pending = list(self._pending.values())
            self._pending.clear()
            self._reader_thread = None
        for response_queue in pending:
            response_queue.put_nowait(failure)

    def _read_loop(self) -> None:
        while True:
            try:
                line = self._stdout.readline(MAX_PEER_MESSAGE_BYTES + 1)
            except TypeError:
                # Small in-memory test streams often expose readline() without
                # the optional size argument. The post-read check still applies.
                line = self._stdout.readline()
            except Exception as exc:  # noqa: BLE001
                self._fail_pending(McpClientError(f"peer read failed: {type(exc).__name__}"))
                return
            if not line:
                self._fail_pending(McpClientError("peer closed the response stream"))
                return
            if len(line) > MAX_PEER_MESSAGE_BYTES:
                self._fail_pending(McpClientError("peer response exceeds the byte limit"))
                return
            try:
                document = protocol.decode(line)
            except (ProtocolError, UnicodeDecodeError, RecursionError):
                # Do not echo peer output: it may contain source, PII or a token.
                self._fail_pending(McpClientError("peer wrote non-JSON-RPC output"))
                return
            if "method" in document and "id" not in document:
                continue
            identifier = document.get("id")
            try:
                response = protocol.parse_response(document)
            except ProtocolError as exc:
                self._fail_pending(McpClientError(f"peer response is invalid: {exc}"))
                return
            with self._state_lock:
                response_queue = self._pending.pop(identifier, None)
                if response_queue is not None:
                    response_queue.put_nowait(response)
                if not self._pending:
                    self._reader_thread = None
                    return

    def _ensure_reader(self) -> None:
        with self._state_lock:
            if self._reader_thread is not None and self._reader_thread.is_alive():
                return
            reader = threading.Thread(target=self._read_loop, name="rqe-mcp-reader", daemon=True)
            self._reader_thread = reader
            reader.start()

    def call(self, method: str, params: dict[str, Any] | None = None, *, timeout: float = 60.0) -> Response:
        if (
            not isinstance(timeout, (int, float))
            or isinstance(timeout, bool)
            or not math.isfinite(float(timeout))
            or timeout <= 0
            or timeout > MAX_PEER_TIMEOUT_SECONDS
        ):
            raise McpClientError(
                f"timeout must be between 0 and {MAX_PEER_TIMEOUT_SECONDS:g} seconds"
            )
        with self._state_lock:
            if self._closed:
                raise McpClientError("peer is closed")
            self._next_id += 1
            request = Request(method=method, params=params or {}, id=self._next_id)
            response_queue: queue.Queue[Response | McpClientError] = queue.Queue(maxsize=1)
            self._pending[request.id] = response_queue
        encoded = protocol.encode(request.to_dict())
        if len(encoded) > MAX_PEER_MESSAGE_BYTES:
            with self._state_lock:
                self._pending.pop(request.id, None)
            raise McpClientError("peer request exceeds the byte limit")
        try:
            with self._write_lock:
                self._stdin.write(encoded)
                self._stdin.flush()
        except Exception as exc:  # noqa: BLE001
            with self._state_lock:
                self._pending.pop(request.id, None)
            raise McpClientError(f"peer write failed: {type(exc).__name__}") from exc
        self._ensure_reader()
        try:
            answer = response_queue.get(timeout=float(timeout))
        except queue.Empty as exc:
            with self._state_lock:
                self._pending.pop(request.id, None)
            raise McpClientError(f"peer timed out after {float(timeout):.3f}s awaiting {method!r}") from exc
        if isinstance(answer, McpClientError):
            raise answer
        return answer

    def notify(self, method: str, params: dict[str, Any] | None = None) -> None:
        encoded = protocol.encode(Request(method=method, params=params or {}).to_dict())
        if len(encoded) > MAX_PEER_MESSAGE_BYTES:
            raise McpClientError("peer notification exceeds the byte limit")
        with self._write_lock:
            if self._closed:
                raise McpClientError("peer is closed")
            self._stdin.write(encoded)
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
        process = _spawn_process(command)
        peer = StdioPeer(
            process.stdin,
            process.stdout,
            on_close=lambda: _terminate_process(process),
        )
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
                transport_error=True,
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
        self._half_open_probe = False
        self._lock = threading.RLock()

    def allow(self) -> tuple[bool, float]:
        """(allowed, seconds_until_retry)."""
        with self._lock:
            if self._opened_at is None:
                return True, 0.0
            elapsed = self._clock() - self._opened_at
            if elapsed >= self._cooldown:
                # Exactly one caller becomes the half-open probe. Others stay
                # refused until that probe records success or failure.
                if self._half_open_probe:
                    return False, 0.0
                self._half_open_probe = True
                return True, 0.0
            return False, round(self._cooldown - elapsed, 3)

    def record_success(self) -> None:
        with self._lock:
            self._consecutive_failures = 0
            self._opened_at = None
            self._half_open_probe = False

    def record_failure(self) -> bool:
        """Returns True when this failure OPENED the breaker."""
        with self._lock:
            self._consecutive_failures += 1
            if self._opened_at is not None:
                # A failed half-open probe starts a fresh cooldown window.
                self._opened_at = self._clock()
                self._half_open_probe = False
                return False
            if self._consecutive_failures >= self._threshold:
                self._opened_at = self._clock()
                self._half_open_probe = False
                return True
            return False

    def state(self) -> dict[str, Any]:
        with self._lock:
            if self._opened_at is None:
                state = "closed"
                retry_in = 0.0
            else:
                elapsed = self._clock() - self._opened_at
                state = "half-open" if elapsed >= self._cooldown else "open"
                retry_in = 0.0 if state == "half-open" else round(self._cooldown - elapsed, 3)
            return {
                "state": state,
                "probeInFlight": self._half_open_probe,
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
        process = _spawn_process(self._command)
        peer = StdioPeer(
            process.stdin,
            process.stdout,
            on_close=lambda: _terminate_process(process),
        )
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
                if result.transport_error:
                    raise McpClientError(result.error or "federated MCP transport failed")
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
