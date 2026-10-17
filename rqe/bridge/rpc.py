from __future__ import annotations

import ipaddress
import json
import logging
import math
import secrets
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from typing import Any

from .core import GameAgentBridge
from ..hub.auth import derive_role_token, load_bridge_token, validate_token


LOGGER = logging.getLogger("rqe.bridge.rpc")
MAX_REQUEST_BODY_BYTES = 4 * 1024 * 1024
MAX_RESPONSE_BODY_BYTES = 8 * 1024 * 1024
MAX_HEADER_BYTES = 32 * 1024
MAX_REQUEST_LINE_BYTES = 8 * 1024
SOCKET_TIMEOUT_SECONDS = 20.0


class RequestBodyTooLarge(ValueError):
    pass


class BridgeRpcService:
    def __init__(
        self,
        bridge: GameAgentBridge,
        token: str | None = None,
        *,
        allow_unauthenticated: bool = False,
        rate_per_second: float = 60.0,
        rate_burst: int = 120,
    ) -> None:
        self.bridge = bridge
        if token is None and not allow_unauthenticated:
            token = load_bridge_token()
        root = validate_token(token) if token is not None else None
        self.token = derive_role_token(root, "mutator") if root else None
        self.allow_unauthenticated = bool(allow_unauthenticated)
        if not math.isfinite(float(rate_per_second)) or rate_per_second <= 0:
            raise ValueError("rate_per_second must be positive and finite")
        if not isinstance(rate_burst, int) or isinstance(rate_burst, bool) or rate_burst < 1:
            raise ValueError("rate_burst must be a positive integer")
        self.rate_per_second = float(rate_per_second)
        self.rate_burst = rate_burst
        self._tokens = float(rate_burst)
        self._last_refill = time.monotonic()
        self._rate_lock = threading.Lock()

    def authorized(self, authorization: str | None) -> bool:
        if self.token is None:
            return self.allow_unauthenticated
        expected = f"Bearer {self.token}"
        return secrets.compare_digest(
            (authorization or "").encode("utf-8"),
            expected.encode("utf-8"),
        )

    def consume_budget(self) -> tuple[bool, float]:
        now = time.monotonic()
        with self._rate_lock:
            self._tokens = min(
                float(self.rate_burst),
                self._tokens + max(0.0, now - self._last_refill) * self.rate_per_second,
            )
            self._last_refill = now
            if self._tokens < 1.0:
                return False, (1.0 - self._tokens) / self.rate_per_second
            self._tokens -= 1.0
            return True, 0.0

    def handle(self, payload: dict[str, Any], authorization: str | None = None) -> dict[str, Any]:
        request_id = payload.get("id") if isinstance(payload, dict) else None
        if not self.authorized(authorization):
            return {"jsonrpc": "2.0", "id": request_id, "error": {"code": -32001, "message": "unauthorized"}}
        if not isinstance(payload, dict) or not isinstance(payload.get("method"), str):
            return {"jsonrpc": "2.0", "id": request_id, "error": {"code": -32600, "message": "invalid request"}}
        try:
            result = self.bridge.dispatch(payload["method"], payload.get("params"))
            return {"jsonrpc": "2.0", "id": request_id, "result": result}
        except Exception as exc:  # JSON-RPC boundary should never take down the relay.
            incident = secrets.token_hex(6)
            LOGGER.exception("game-agent bridge request failed (incident %s)", incident)
            return {
                "jsonrpc": "2.0",
                "id": request_id,
                "error": {"code": -32603, "message": "bridge operation failed", "data": {"incident": incident}},
            }


def _require_loopback_host(host: str) -> None:
    candidate = str(host).strip().strip("[]").lower()
    if candidate == "localhost":
        return
    try:
        if ipaddress.ip_address(candidate).is_loopback:
            return
    except ValueError:
        pass
    raise ValueError("Game Agent Bridge may bind only to loopback")


def make_handler(service: BridgeRpcService) -> type[BaseHTTPRequestHandler]:
    class Handler(BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"
        server_version = "RQEGameAgentBridge/2.0"
        sys_version = ""

        def setup(self) -> None:
            super().setup()
            self.connection.settimeout(SOCKET_TIMEOUT_SECONDS)

        def handle_one_request(self) -> None:
            try:
                self.raw_requestline = self.rfile.readline(MAX_REQUEST_LINE_BYTES + 1)
                if len(self.raw_requestline) > MAX_REQUEST_LINE_BYTES:
                    self.requestline = ""
                    self.request_version = ""
                    self.command = ""
                    self._send({"error": "request target is too long"}, 414)
                    self.close_connection = True
                    return
                if not self.raw_requestline:
                    self.close_connection = True
                    return
                if not self.parse_request():
                    return
                method_name = "do_" + self.command
                if not hasattr(self, method_name):
                    self._send({"error": "method not allowed"}, 405)
                    return
                getattr(self, method_name)()
                self.wfile.flush()
            except TimeoutError:
                self.close_connection = True

        def parse_request(self) -> bool:
            if not super().parse_request():
                return False
            total = len(self.raw_requestline) + sum(
                len(name.encode("utf-8")) + len(value.encode("utf-8")) + 4
                for name, value in self.headers.raw_items()
            )
            if total > MAX_HEADER_BYTES:
                self._send({"error": "request headers exceed limit"}, 431)
                self.close_connection = True
                return False
            return True

        def _send(self, payload: Any, status: int = 200, *, retry_after: float | None = None) -> None:
            body = json.dumps(payload, ensure_ascii=False).encode("utf-8")
            if len(body) > MAX_RESPONSE_BODY_BYTES:
                status = 507
                body = b'{"error":"response exceeds limit"}'
            self.send_response(status)
            self.send_header("Content-Type", "application/json; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Cache-Control", "no-store")
            self.send_header("X-Content-Type-Options", "nosniff")
            if retry_after is not None:
                self.send_header("Retry-After", str(max(1, math.ceil(retry_after))))
            self.end_headers()
            self.wfile.write(body)

        def _admit(self) -> bool:
            if not service.authorized(self.headers.get("Authorization")):
                self._send({"error": "unauthorized"}, 401)
                return False
            allowed, retry_after = service.consume_budget()
            if not allowed:
                self._send({"error": "rate limited"}, 429, retry_after=retry_after)
                return False
            return True

        def _read_json(self) -> dict[str, Any]:
            if self.headers.get("Transfer-Encoding"):
                raise ValueError("Transfer-Encoding is not supported")
            content_type = (self.headers.get("Content-Type") or "").split(";", 1)[0].strip().lower()
            if content_type != "application/json":
                raise ValueError("Content-Type must be application/json")
            declared = self.headers.get("Content-Length")
            if declared is None:
                raise ValueError("Content-Length is required")
            try:
                length = int(declared)
            except ValueError as exc:
                raise ValueError("Content-Length must be an integer") from exc
            if length > MAX_REQUEST_BODY_BYTES:
                self.close_connection = True
                raise RequestBodyTooLarge("request body exceeds limit")
            if length <= 0:
                raise ValueError("request body must not be empty")
            raw = self.rfile.read(length)
            if len(raw) != length:
                raise ValueError("request body ended before Content-Length")
            try:
                payload = json.loads(raw.decode("utf-8"))
            except UnicodeDecodeError as exc:
                raise ValueError("request body must be UTF-8") from exc
            if not isinstance(payload, dict):
                raise ValueError("request body must be a JSON object")
            return payload

        def do_GET(self) -> None:  # noqa: N802
            if not self._admit():
                return
            if self.path == "/health":
                self._send({"ok": True, "service": "game-agent-bridge"})
                return
            self._send({"error": "not found"}, 404)

        def do_POST(self) -> None:  # noqa: N802
            if self.path != "/rpc":
                self._send({"error": "not found"}, 404)
                return
            if not self._admit():
                return
            try:
                payload = self._read_json()
            except RequestBodyTooLarge:
                self._send({"error": "request body exceeds limit"}, 413)
                return
            except (UnicodeDecodeError, ValueError, json.JSONDecodeError):
                self._send({"error": "invalid JSON request"}, 400)
                return
            result = service.handle(payload, self.headers.get("Authorization"))
            self._send(result)

        def log_message(self, format: str, *args: Any) -> None:
            return

    return Handler


def create_server(
    bridge: GameAgentBridge,
    host: str = "127.0.0.1",
    port: int = 8765,
    token: str | None = None,
    *,
    allow_unauthenticated: bool = False,
    rate_per_second: float = 60.0,
    rate_burst: int = 120,
) -> ThreadingHTTPServer:
    _require_loopback_host(host)
    service = BridgeRpcService(
        bridge,
        token,
        allow_unauthenticated=allow_unauthenticated,
        rate_per_second=rate_per_second,
        rate_burst=rate_burst,
    )
    server = ThreadingHTTPServer((host, port), make_handler(service))
    server.daemon_threads = True
    return server


def serve(
    bridge: GameAgentBridge,
    host: str = "127.0.0.1",
    port: int = 8765,
    token: str | None = None,
    *,
    allow_unauthenticated: bool = False,
    rate_per_second: float = 60.0,
    rate_burst: int = 120,
) -> None:
    server = create_server(
        bridge,
        host,
        port,
        token,
        allow_unauthenticated=allow_unauthenticated,
        rate_per_second=rate_per_second,
        rate_burst=rate_burst,
    )
    try:
        server.serve_forever()
    finally:
        server.server_close()
