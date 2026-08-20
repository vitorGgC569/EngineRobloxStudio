from __future__ import annotations

import json
import urllib.error
import urllib.request
from dataclasses import dataclass, field
from typing import Any, Protocol


class TransportError(RuntimeError):
    pass


class RpcTransport(Protocol):
    def call(self, method: str, params: dict[str, Any] | None = None) -> Any:
        ...


class HttpJsonRpcTransport:
    """Small dependency-free transport for a local Studio/MCP adapter."""

    def __init__(self, base_url: str, timeout: float = 15.0, token: str | None = None) -> None:
        self.base_url = base_url.rstrip("/")
        self.timeout = timeout
        self.token = token

    def call(self, method: str, params: dict[str, Any] | None = None) -> Any:
        body = json.dumps({"jsonrpc": "2.0", "id": 1, "method": method, "params": params or {}}).encode("utf-8")
        headers = {"Content-Type": "application/json"}
        if self.token:
            headers["Authorization"] = f"Bearer {self.token}"
        request = urllib.request.Request(f"{self.base_url}/rpc", data=body, headers=headers, method="POST")
        try:
            with urllib.request.urlopen(request, timeout=self.timeout) as response:
                payload = json.loads(response.read().decode("utf-8"))
        except (urllib.error.URLError, TimeoutError, json.JSONDecodeError) as exc:
            raise TransportError(f"Studio transport failed for {method}: {exc}") from exc
        if "error" in payload:
            raise TransportError(str(payload["error"]))
        return payload.get("result")


@dataclass
class RecordingTransport:
    """Test double that preserves the exact Studio tool calls made by the bridge."""

    responses: dict[str, Any] = field(default_factory=dict)
    calls: list[dict[str, Any]] = field(default_factory=list)

    def call(self, method: str, params: dict[str, Any] | None = None) -> Any:
        call = {"method": method, "params": params or {}}
        self.calls.append(call)
        response = self.responses.get(method)
        return response() if callable(response) else response

