from __future__ import annotations

import json
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from typing import Any

from .core import GameAgentBridge


class BridgeRpcService:
    def __init__(self, bridge: GameAgentBridge, token: str | None = None) -> None:
        self.bridge = bridge
        self.token = token

    def handle(self, payload: dict[str, Any], authorization: str | None = None) -> dict[str, Any]:
        if self.token and authorization != f"Bearer {self.token}":
            return {"jsonrpc": "2.0", "id": payload.get("id"), "error": {"code": -32001, "message": "unauthorized"}}
        try:
            result = self.bridge.dispatch(payload["method"], payload.get("params"))
            return {"jsonrpc": "2.0", "id": payload.get("id"), "result": result}
        except Exception as exc:  # JSON-RPC boundary should never take down the relay.
            return {"jsonrpc": "2.0", "id": payload.get("id"), "error": {"code": -32603, "message": str(exc)}}


def serve(bridge: GameAgentBridge, host: str = "127.0.0.1", port: int = 8765, token: str | None = None) -> None:
    service = BridgeRpcService(bridge, token)

    class Handler(BaseHTTPRequestHandler):
        def do_GET(self) -> None:  # noqa: N802
            if self.path == "/health":
                body = json.dumps({"ok": True, "service": "game-agent-bridge"}).encode("utf-8")
                self.send_response(200)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)
                return
            self.send_error(404)

        def do_POST(self) -> None:  # noqa: N802
            if self.path != "/rpc":
                self.send_error(404)
                return
            try:
                length = int(self.headers.get("Content-Length", "0"))
                payload = json.loads(self.rfile.read(length).decode("utf-8"))
                result = service.handle(payload, self.headers.get("Authorization"))
                body = json.dumps(result, ensure_ascii=False).encode("utf-8")
                self.send_response(200)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)
            except (ValueError, json.JSONDecodeError) as exc:
                self.send_error(400, str(exc))

        def log_message(self, format: str, *args: Any) -> None:
            return

    server = ThreadingHTTPServer((host, port), Handler)
    server.serve_forever()
