"""The engine exposed as an MCP server.

Until now an agent reached this engine through a Python CLI. That is *our
script*, not an engine: it works for whoever wrote it and for nobody else. Once
`rqe` speaks MCP, any agent -- Claude Code, Codex, Cursor -- inherits the typed
surface with provenance already attached, and the difference between "a tool we
use" and "a platform others build on" stops being aspirational.

Three properties are load-bearing:

**Typed in, typed out.** Every tool declares a JSON Schema and its arguments are
validated against it before the handler runs. Roblox's own MCP tools return
prose; ours return structured content, because a caller that has to parse prose
is a caller that will parse it wrong.

**Provenance attached at the boundary.** Every result carries the source, the
schema version and a timestamp. An agent cannot accidentally launder an engine
answer into an unattributed claim.

**No silent success.** A handler that raises produces `isError`, not an empty
result. Absence of an answer is never an answer.
"""

from __future__ import annotations

import sys
import traceback
from dataclasses import dataclass, field
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, BinaryIO, Callable, Mapping

from . import protocol
from ..schema_validation import SchemaDefinitionError, validate_schema_instance


SERVER_NAME = "rqe-engine"
SERVER_VERSION = "1.0.0"
RESULT_SCHEMA_VERSION = 1


class ToolError(RuntimeError):
    """A tool ran and failed. Reported as `isError`, never as an empty result."""


@dataclass(frozen=True)
class Tool:
    name: str
    description: str
    input_schema: dict[str, Any]
    handler: Callable[[dict[str, Any]], Any]

    def descriptor(self) -> dict[str, Any]:
        return {
            "name": self.name,
            "description": self.description,
            "inputSchema": self.input_schema,
        }


@dataclass
class EngineMcpServer:
    """A minimal, synchronous MCP server over newline-delimited stdio."""

    root: Path
    tools: dict[str, Tool] = field(default_factory=dict)
    initialized: bool = False

    def __post_init__(self) -> None:
        # Resolved once, here, because every tool module relativises its output
        # paths against this root while the containment checks resolve theirs.
        # A relative or symlinked root makes those two disagree, and the whole
        # surface fails with "is not in the subpath of" on an otherwise correct
        # write.
        self.root = Path(self.root).resolve()

    def register(self, tool: Tool) -> None:
        if tool.name in self.tools:
            raise ValueError(f"tool {tool.name!r} is already registered")
        self.tools[tool.name] = tool

    # -- dispatch --------------------------------------------------------

    def handle(self, request: protocol.Request) -> protocol.Response | None:
        if request.method == "initialize":
            self.initialized = True
            return protocol.Response(id=request.id, result={
                "protocolVersion": protocol.PROTOCOL_VERSION,
                "capabilities": {"tools": {"listChanged": False}},
                "serverInfo": {"name": SERVER_NAME, "version": SERVER_VERSION},
            })

        if request.is_notification:
            # Notifications get no reply, by specification. `initialized` is the
            # one that matters; anything else is ignored rather than errored,
            # because a peer is allowed to tell us things we do not act on.
            return None

        if request.method == "tools/list":
            return protocol.Response(id=request.id, result={
                "tools": [tool.descriptor() for tool in self._sorted_tools()],
            })

        if request.method == "tools/call":
            return self._call(request)

        if request.method == "ping":
            return protocol.Response(id=request.id, result={})

        return protocol.Response(id=request.id, error=protocol.error(
            protocol.METHOD_NOT_FOUND, f"unknown method {request.method!r}"
        ))

    def _sorted_tools(self) -> list[Tool]:
        return [self.tools[name] for name in sorted(self.tools)]

    def _call(self, request: protocol.Request) -> protocol.Response:
        name = request.params.get("name")
        if not isinstance(name, str) or name not in self.tools:
            return protocol.Response(id=request.id, error=protocol.error(
                protocol.INVALID_PARAMS,
                f"unknown tool {name!r}",
                {"available": sorted(self.tools)},
            ))

        tool = self.tools[name]
        arguments = request.params.get("arguments") or {}
        if not isinstance(arguments, dict):
            return protocol.Response(id=request.id, error=protocol.error(
                protocol.INVALID_PARAMS, "arguments must be an object"
            ))

        try:
            issues = validate_schema_instance(arguments, tool.input_schema)
        except SchemaDefinitionError as exc:  # pragma: no cover - authoring bug
            return protocol.Response(id=request.id, error=protocol.error(
                protocol.INTERNAL_ERROR, f"tool {name!r} has an invalid schema: {exc}"
            ))
        if issues:
            return protocol.Response(id=request.id, error=protocol.error(
                protocol.INVALID_PARAMS,
                f"arguments do not match the schema for {name!r}",
                {"issues": [str(issue) for issue in issues]},
            ))

        try:
            payload = tool.handler(arguments)
        except ToolError as exc:
            return protocol.Response(id=request.id, result=_error_result(name, str(exc)))
        except Exception as exc:  # noqa: BLE001 - a handler bug must not kill the server
            return protocol.Response(id=request.id, result=_error_result(
                name, f"{type(exc).__name__}: {exc}", traceback.format_exc()
            ))

        return protocol.Response(id=request.id, result=_ok_result(name, payload))

    # -- transport -------------------------------------------------------

    def serve(self, stdin: BinaryIO | None = None, stdout: BinaryIO | None = None) -> int:
        """Read requests until the peer closes the stream."""

        source = stdin if stdin is not None else sys.stdin.buffer
        sink = stdout if stdout is not None else sys.stdout.buffer

        for raw in source:
            if not raw.strip():
                continue
            try:
                document = protocol.decode(raw)
                request = protocol.parse_request(document)
            except protocol.ProtocolError as exc:
                sink.write(protocol.encode(protocol.Response(
                    id=None, error=protocol.error(protocol.PARSE_ERROR, str(exc))
                ).to_dict()))
                sink.flush()
                continue

            response = self.handle(request)
            if response is not None:
                sink.write(protocol.encode(response.to_dict()))
                sink.flush()
        return 0


def _stamp() -> dict[str, Any]:
    return {
        "schemaVersion": RESULT_SCHEMA_VERSION,
        "source": SERVER_NAME,
        "producedAt": datetime.now(timezone.utc).isoformat(),
    }


def _ok_result(tool: str, payload: Any) -> dict[str, Any]:
    body = {"tool": tool, **_stamp(), "data": payload}
    return {
        # Text for agents that only read prose; structured content for anything
        # that intends to act on the answer.
        "content": [{"type": "text", "text": _summarise(tool, payload)}],
        "structuredContent": body,
        "isError": False,
    }


def _error_result(tool: str, message: str, detail: str | None = None) -> dict[str, Any]:
    body = {"tool": tool, **_stamp(), "error": message}
    if detail:
        body["detail"] = detail
    return {
        "content": [{"type": "text", "text": f"{tool} failed: {message}"}],
        "structuredContent": body,
        "isError": True,
    }


def _summarise(tool: str, payload: Any) -> str:
    if isinstance(payload, Mapping):
        keys = ", ".join(sorted(str(key) for key in payload))
        return f"{tool}: {keys}"
    if isinstance(payload, list):
        return f"{tool}: {len(payload)} item(s)"
    return f"{tool}: {payload}"
