from __future__ import annotations

import json
import urllib.error
import urllib.request
from dataclasses import dataclass, field
from typing import Any, Protocol

from ..http_safety import HttpBoundaryError, json_limited
from ..hub.auth import BridgeAuthError, derive_role_token, validate_token
from ..security import SecurityBoundaryError, validate_hub_url


MAX_RPC_REQUEST_BYTES = 4 * 1024 * 1024
MAX_RPC_RESPONSE_BYTES = 8 * 1024 * 1024


class TransportError(RuntimeError):
    pass


class RpcTransport(Protocol):
    def call(self, method: str, params: dict[str, Any] | None = None) -> Any:
        ...


class HttpJsonRpcTransport:
    """Small dependency-free transport for a local Studio/MCP adapter."""

    def __init__(self, base_url: str, timeout: float = 15.0, token: str | None = None) -> None:
        try:
            self.base_url = validate_hub_url(base_url)
        except SecurityBoundaryError as exc:
            raise TransportError(str(exc)) from exc
        self.timeout = timeout
        try:
            self.token = derive_role_token(validate_token(token), "mutator") if token else None
        except BridgeAuthError as exc:
            raise TransportError(str(exc)) from exc

    def call(self, method: str, params: dict[str, Any] | None = None) -> Any:
        body = json.dumps({"jsonrpc": "2.0", "id": 1, "method": method, "params": params or {}}).encode("utf-8")
        if len(body) > MAX_RPC_REQUEST_BYTES:
            raise TransportError(f"Studio request exceeds {MAX_RPC_REQUEST_BYTES} bytes")
        headers = {"Content-Type": "application/json"}
        if self.token:
            headers["Authorization"] = f"Bearer {self.token}"
        request = urllib.request.Request(f"{self.base_url}/rpc", data=body, headers=headers, method="POST")
        try:
            with urllib.request.urlopen(request, timeout=self.timeout) as response:
                payload = json_limited(response, MAX_RPC_RESPONSE_BYTES, label="Studio RPC response")
        except (urllib.error.URLError, TimeoutError, HttpBoundaryError) as exc:
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
