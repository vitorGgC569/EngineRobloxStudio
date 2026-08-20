"""Open Cloud Luau Execution: the engine's second execution surface.

Everything the platform measures today goes through one local Studio. That makes
throughput equal to one machine, makes CI impossible, and makes the two-games
generality proof serial.

Roblox runs Luau against a real place on its own infrastructure, with full
DataModel and engine access:

    POST /cloud/v2/universes/{u}/places/{p}/luau-execution-session-tasks
    GET  .../tasks/{task_id}
    GET  .../tasks/{task_id}/logs

Up to five minutes per task and ten concurrent tasks per place, with binary
payloads in and out. That is a second backend for the same command protocol --
and the reason the SDK is written as pure Luau with no Studio-only dependency in
its core.

Two rules carried over from the rest of this engine:

**Wrap, do not trust.** A task result arrives as untyped JSON. It is re-typed,
stamped with its own provenance, and bound to a run and build before it can
become evidence.

**Fail closed.** Missing credentials, a task that errors, a task that times out,
and truncated output are all distinct, named, non-passing states. None of them
is silence.
"""

from __future__ import annotations

import json
import time
from dataclasses import dataclass, field
from enum import Enum
from typing import Any, Mapping, Sequence

from ..assets.http import HttpRequest, HttpResponse, HttpTransport, UrllibTransport, json_body


DEFAULT_API_ROOT = "https://apis.roblox.com"

#: Documented ceilings. Held here so the client refuses work Roblox would reject
#: rather than discovering it as an opaque 4xx halfway through a run.
MAX_TASK_SECONDS = 300
MAX_CONCURRENT_TASKS_PER_PLACE = 10

REQUIRED_SCOPE = "luau-execution-sessions:write"


class TaskState(str, Enum):
    QUEUED = "QUEUED"
    PROCESSING = "PROCESSING"
    CANCELLED = "CANCELLED"
    COMPLETE = "COMPLETE"
    FAILED = "FAILED"
    #: Ours, not Roblox's: the client gave up waiting. Distinct from FAILED
    #: because the task may still be running and may still change the place.
    TIMEOUT = "TIMEOUT"
    #: Ours: the request never left, because there were no credentials.
    BLOCKED = "BLOCKED"


TERMINAL_STATES = frozenset({
    TaskState.CANCELLED, TaskState.COMPLETE, TaskState.FAILED,
    TaskState.TIMEOUT, TaskState.BLOCKED,
})


class LuauExecutionError(RuntimeError):
    """The client could not form a valid request."""


@dataclass(frozen=True)
class CloudConfig:
    universe_id: str
    place_id: str
    api_key: str | None = None
    api_root: str = DEFAULT_API_ROOT
    version_id: str | None = None

    def __post_init__(self) -> None:
        for field_name in ("universe_id", "place_id"):
            value = getattr(self, field_name)
            if not isinstance(value, str) or not value:
                raise LuauExecutionError(f"{field_name} is required")

    @property
    def has_credentials(self) -> bool:
        return bool(self.api_key)


@dataclass(frozen=True)
class TaskResult:
    """One execution, with everything needed to decide whether to trust it."""

    state: TaskState
    task_path: str = ""
    #: Values the script returned. Empty is a legitimate result, and is not the
    #: same as the script having failed.
    output: tuple[Any, ...] = ()
    logs: tuple[str, ...] = ()
    error: str | None = None
    blockers: tuple[str, ...] = ()
    #: True when Roblox reported more log lines than were retrieved. Truncated
    #: output cannot support a conclusion, so the gate treats it as inconclusive.
    truncated: bool = False
    duration_seconds: float = 0.0
    raw: Mapping[str, Any] = field(default_factory=dict)

    @property
    def ok(self) -> bool:
        return self.state is TaskState.COMPLETE and not self.truncated

    def to_evidence_detail(self) -> dict[str, Any]:
        return {
            "source": "open-cloud-luau",
            "state": self.state.value,
            "taskPath": self.task_path,
            "outputCount": len(self.output),
            "logLines": len(self.logs),
            "truncated": self.truncated,
            "conclusive": self.state is TaskState.COMPLETE and not self.truncated,
            "durationSeconds": round(self.duration_seconds, 3),
            "error": self.error,
            "blockers": list(self.blockers),
        }


class LuauExecutionClient:
    """Create, poll and read Open Cloud Luau tasks."""

    def __init__(
        self,
        config: CloudConfig,
        transport: HttpTransport | None = None,
        *,
        sleep=time.sleep,
        clock=time.monotonic,
    ) -> None:
        self.config = config
        self.transport = transport or UrllibTransport()
        self._sleep = sleep
        self._clock = clock

    # -- request plumbing ------------------------------------------------

    def _headers(self) -> dict[str, str]:
        headers = {"Content-Type": "application/json"}
        if self.config.api_key:
            headers["x-api-key"] = self.config.api_key
        return headers

    def _base(self) -> str:
        root = self.config.api_root.rstrip("/")
        base = f"{root}/cloud/v2/universes/{self.config.universe_id}/places/{self.config.place_id}"
        if self.config.version_id:
            base = f"{base}/versions/{self.config.version_id}"
        return base

    def _send(self, request: HttpRequest) -> HttpResponse | str:
        try:
            return self.transport.send(request)
        except Exception as exc:  # pragma: no cover - transport specific
            return f"transport error: {exc}"

    # -- public surface --------------------------------------------------

    def capabilities(self) -> dict[str, Any]:
        """What this client can do right now, and what stops it if not."""

        blockers: list[str] = []
        if not self.config.has_credentials:
            blockers.append(
                f"no Open Cloud API key; create one with the {REQUIRED_SCOPE} scope "
                "for this place on the Creator Dashboard"
            )
        return {
            "backend": "open-cloud-luau",
            "available": not blockers,
            "maxTaskSeconds": MAX_TASK_SECONDS,
            "maxConcurrentTasks": MAX_CONCURRENT_TASKS_PER_PLACE,
            "requiredScope": REQUIRED_SCOPE,
            "universeId": self.config.universe_id,
            "placeId": self.config.place_id,
            "blockers": blockers,
        }

    def execute(
        self,
        script: str,
        *,
        timeout_seconds: float = 120.0,
        poll_interval: float = 2.0,
        binary_input_ids: Sequence[str] = (),
    ) -> TaskResult:
        """Run `script` and wait for a terminal state."""

        if not isinstance(script, str) or not script.strip():
            raise LuauExecutionError("script must be a non-empty string")
        if timeout_seconds <= 0:
            raise LuauExecutionError("timeout_seconds must be positive")
        if timeout_seconds > MAX_TASK_SECONDS:
            raise LuauExecutionError(
                f"timeout_seconds {timeout_seconds} exceeds the documented "
                f"{MAX_TASK_SECONDS}s ceiling for a Luau execution task"
            )

        if not self.config.has_credentials:
            # Refused before the request is formed, so a missing key can never be
            # mistaken for a script that produced nothing.
            return TaskResult(
                state=TaskState.BLOCKED,
                blockers=tuple(self.capabilities()["blockers"]),
                error="no Open Cloud credentials",
            )

        started = self._clock()
        payload: dict[str, Any] = {"script": script}
        if binary_input_ids:
            payload["binaryInputs"] = [{"key": key} for key in binary_input_ids]

        created = self._send(HttpRequest(
            method="POST",
            url=f"{self._base()}/luau-execution-session-tasks",
            headers=self._headers(),
            body=json_body(payload),
            timeout_seconds=min(timeout_seconds, 60.0),
        ))
        if isinstance(created, str):
            return TaskResult(state=TaskState.FAILED, error=created)
        if created.status >= 400:
            return TaskResult(
                state=TaskState.FAILED,
                error=f"task creation returned HTTP {created.status}",
                raw=_safe_json(created),
            )

        document = _safe_json(created)
        task_path = str(document.get("path") or "")
        if not task_path:
            return TaskResult(
                state=TaskState.FAILED,
                error="task creation returned no task path",
                raw=document,
            )

        return self._await(task_path, started, timeout_seconds, poll_interval)

    def _await(self, task_path: str, started: float, timeout_seconds: float, poll_interval: float) -> TaskResult:
        root = self.config.api_root.rstrip("/")
        url = f"{root}/cloud/v2/{task_path.lstrip('/')}"
        document: dict[str, Any] = {}

        while True:
            elapsed = self._clock() - started
            if elapsed > timeout_seconds:
                return TaskResult(
                    state=TaskState.TIMEOUT,
                    task_path=task_path,
                    error=(
                        f"gave up after {elapsed:.1f}s; the task may still be running "
                        "and may still modify the place"
                    ),
                    duration_seconds=elapsed,
                    raw=document,
                )

            response = self._send(HttpRequest(method="GET", url=url, headers=self._headers()))
            if isinstance(response, str):
                return TaskResult(state=TaskState.FAILED, task_path=task_path, error=response)
            if response.status >= 400:
                return TaskResult(
                    state=TaskState.FAILED,
                    task_path=task_path,
                    error=f"task poll returned HTTP {response.status}",
                    raw=_safe_json(response),
                )

            document = _safe_json(response)
            raw_state = str(document.get("state") or "")
            try:
                state = TaskState(raw_state)
            except ValueError:
                return TaskResult(
                    state=TaskState.FAILED,
                    task_path=task_path,
                    error=f"unrecognised task state {raw_state!r}",
                    raw=document,
                )

            if state in TERMINAL_STATES:
                duration = self._clock() - started
                logs, truncated = self._logs(task_path)
                if state is TaskState.COMPLETE:
                    results = document.get("output", {}).get("results", [])
                    return TaskResult(
                        state=state,
                        task_path=task_path,
                        output=tuple(results) if isinstance(results, list) else (),
                        logs=logs,
                        truncated=truncated,
                        duration_seconds=duration,
                        raw=document,
                    )
                return TaskResult(
                    state=state,
                    task_path=task_path,
                    logs=logs,
                    truncated=truncated,
                    error=_error_text(document),
                    duration_seconds=duration,
                    raw=document,
                )

            self._sleep(poll_interval)

    def _logs(self, task_path: str) -> tuple[tuple[str, ...], bool]:
        root = self.config.api_root.rstrip("/")
        response = self._send(HttpRequest(
            method="GET",
            url=f"{root}/cloud/v2/{task_path.lstrip('/')}/logs",
            headers=self._headers(),
        ))
        if isinstance(response, str) or response.status >= 400:
            # Logs we could not read are reported as truncated rather than as an
            # empty log, because "the script printed nothing" and "we could not
            # find out what it printed" support very different conclusions.
            return (), True

        document = _safe_json(response)
        chunks = document.get("luauExecutionSessionTaskLogs", [])
        lines: list[str] = []
        if isinstance(chunks, list):
            for chunk in chunks:
                if isinstance(chunk, dict):
                    messages = chunk.get("messages", [])
                    if isinstance(messages, list):
                        lines.extend(str(item) for item in messages)
        truncated = bool(document.get("nextPageToken"))
        return tuple(lines), truncated


def _safe_json(response: HttpResponse) -> dict[str, Any]:
    try:
        document = response.json()
    except (ValueError, json.JSONDecodeError):
        return {}
    return document if isinstance(document, dict) else {}


def _error_text(document: Mapping[str, Any]) -> str:
    error = document.get("error")
    if isinstance(error, Mapping):
        return str(error.get("message") or error)
    if isinstance(error, str):
        return error
    return "task did not complete"
