"""JSON-RPC 2.0 over newline-delimited stdio, as MCP speaks it.

Kept separate from both the client and the server because the engine plays both
roles: it is a *client* of Roblox's built-in Studio MCP server, and a *server* to
whichever agent is driving it. One framing implementation, verified once.
"""

from __future__ import annotations

import json
from dataclasses import dataclass, field
from typing import Any, BinaryIO, Iterator


PROTOCOL_VERSION = "2025-06-18"
JSONRPC_VERSION = "2.0"

#: Standard JSON-RPC codes plus the one MCP adds for a tool that ran and failed.
PARSE_ERROR = -32700
INVALID_REQUEST = -32600
METHOD_NOT_FOUND = -32601
INVALID_PARAMS = -32602
INTERNAL_ERROR = -32603


class ProtocolError(RuntimeError):
    """The peer sent something that is not valid JSON-RPC."""


@dataclass(frozen=True)
class Request:
    method: str
    params: dict[str, Any] = field(default_factory=dict)
    id: Any = None

    @property
    def is_notification(self) -> bool:
        return self.id is None

    def to_dict(self) -> dict[str, Any]:
        payload: dict[str, Any] = {"jsonrpc": JSONRPC_VERSION, "method": self.method}
        if self.params:
            payload["params"] = self.params
        if self.id is not None:
            payload["id"] = self.id
        return payload


@dataclass(frozen=True)
class Response:
    id: Any
    result: Any = None
    error: dict[str, Any] | None = None

    @property
    def ok(self) -> bool:
        return self.error is None

    def to_dict(self) -> dict[str, Any]:
        payload: dict[str, Any] = {"jsonrpc": JSONRPC_VERSION, "id": self.id}
        if self.error is not None:
            payload["error"] = self.error
        else:
            payload["result"] = self.result if self.result is not None else {}
        return payload


def error(code: int, message: str, data: Any = None) -> dict[str, Any]:
    payload: dict[str, Any] = {"code": code, "message": message}
    if data is not None:
        payload["data"] = data
    return payload


def encode(message: dict[str, Any]) -> bytes:
    """One message, one line.

    `ensure_ascii` stays on: the transport is a byte pipe shared with whatever
    else a subprocess writes, and a non-ASCII payload that survives our encoder
    but not the peer's decoder is a failure nobody can reproduce.
    """

    return (json.dumps(message, ensure_ascii=True, separators=(",", ":")) + "\n").encode("utf-8")


def decode(line: bytes | str) -> dict[str, Any]:
    text = line.decode("utf-8") if isinstance(line, bytes) else line
    text = text.strip()
    if not text:
        raise ProtocolError("empty line")
    try:
        document = json.loads(text)
    except json.JSONDecodeError as exc:
        raise ProtocolError(f"not JSON: {exc}") from exc
    if not isinstance(document, dict):
        raise ProtocolError("a JSON-RPC message must be an object")
    if document.get("jsonrpc") != JSONRPC_VERSION:
        raise ProtocolError(f"unsupported jsonrpc version {document.get('jsonrpc')!r}")
    return document


def parse_response(document: dict[str, Any]) -> Response:
    if "error" in document:
        payload = document["error"]
        if not isinstance(payload, dict):
            raise ProtocolError("error member must be an object")
        return Response(id=document.get("id"), error=payload)
    if "result" not in document:
        raise ProtocolError("a response must carry result or error")
    return Response(id=document.get("id"), result=document["result"])


def parse_request(document: dict[str, Any]) -> Request:
    method = document.get("method")
    if not isinstance(method, str) or not method:
        raise ProtocolError("a request must name a method")
    params = document.get("params", {})
    if params is None:
        params = {}
    if not isinstance(params, dict):
        raise ProtocolError("params must be an object")
    return Request(method=method, params=params, id=document.get("id"))


def read_messages(stream: BinaryIO) -> Iterator[dict[str, Any]]:
    """Yield decoded messages, skipping blank lines.

    Non-JSON lines are *not* skipped. A subprocess that writes a stack trace to
    stdout has broken the channel, and continuing as though the stream were
    still framed would turn that into a hang instead of an error.
    """

    for raw in stream:
        if not raw.strip():
            continue
        yield decode(raw)
