import http.client
import threading
import unittest
from pathlib import Path

from rqe.bridge.adapters import HeadlessGameAdapter, StudioGameAdapter
from rqe.bridge.core import GameAgentBridge
from rqe.bridge.rpc import MAX_REQUEST_BODY_BYTES, BridgeRpcService, create_server
from rqe.bridge.transport import RecordingTransport
from rqe.hub.auth import derive_role_token
from rqe.project import Project


ROOT = Path(__file__).resolve().parents[1]


class BridgeTests(unittest.TestCase):
    def setUp(self):
        self.project = Project.load(ROOT)

    def test_blackbox_agent_completes_human_purchase_scenario(self):
        bridge = GameAgentBridge(HeadlessGameAdapter(self.project), "blackbox")
        scenario = {
            "id": "test-human-purchase",
            "mode": "blackbox",
            "steps": [
                {"walk_to": "BasicPackStore"},
                {"assert": {"type": "visible_text", "value": "Buy mining pack"}},
                {"interact": "PurchasePrompt"},
                {"assert": {"type": "visible_text", "value": "$900"}},
                {"interact": "PurchasePrompt", "expectSuccess": False},
            ],
        }
        result = bridge.run_scenario(scenario)
        self.assertEqual(result["status"], "PASS")
        blackbox = bridge.observe("blackbox")
        self.assertNotIn("player", blackbox)
        self.assertTrue(all("Inventory:" not in item["text"] for item in blackbox["visibleUi"]))
        self.assertGreaterEqual(len(result["actionRecords"]), 3)

    def test_direct_navigation_is_not_a_blackbox_proof(self):
        bridge = GameAgentBridge(HeadlessGameAdapter(self.project), "blackbox")
        bridge.start()
        result = bridge.navigate_direct("BasicPackStore")
        self.assertFalse(result["success"])
        self.assertIn("forbidden", result["reason"])

    def test_whitebox_observation_exposes_diagnostics(self):
        bridge = GameAgentBridge(HeadlessGameAdapter(self.project), "whitebox")
        bridge.start()
        observation = bridge.observe()
        self.assertIn("player", observation)
        self.assertIn("diagnostics", observation)
        self.assertIn("remotes", observation["diagnostics"])

    def test_studio_adapter_maps_real_tool_operations(self):
        transport = RecordingTransport(responses={
            "playtest_start": {"started": True},
            "screen_capture": "frame.png",
            "console_read": {"errors": []},
            "quality_probe_observe": {"visibleUi": [], "nearby": []},
            "character_navigation": {"success": True},
        })
        adapter = StudioGameAdapter(transport)
        bridge = GameAgentBridge(adapter, "graybox")
        bridge.start()
        result = bridge.walk("BasicPackStore")
        self.assertTrue(result["success"])
        methods = [call["method"] for call in transport.calls]
        self.assertIn("playtest_start", methods)
        self.assertIn("screen_capture", methods)
        self.assertIn("console_read", methods)
        self.assertIn("character_navigation", methods)

    def test_rpc_service_rejects_bad_token_and_dispatches(self):
        bridge = GameAgentBridge(HeadlessGameAdapter(self.project))
        root_token = "test-game-agent-root-token-with-at-least-32-bytes"
        service = BridgeRpcService(bridge, token=root_token)
        denied = service.handle({"id": 1, "method": "game.start"}, "Bearer wrong")
        self.assertIn("error", denied)
        root_denied = service.handle({"id": 2, "method": "game.start"}, f"Bearer {root_token}")
        self.assertIn("error", root_denied)
        wire_token = derive_role_token(root_token, "mutator")
        allowed = service.handle(
            {"id": 3, "method": "game.start", "params": {"mode": "graybox"}},
            f"Bearer {wire_token}",
        )
        self.assertIn("result", allowed)

    def test_rpc_http_boundary_requires_wire_token_and_enforces_limits(self):
        root_token = "http-game-agent-root-token-with-at-least-32-bytes"
        bridge = GameAgentBridge(HeadlessGameAdapter(self.project))
        server = create_server(
            bridge,
            port=0,
            token=root_token,
            rate_per_second=0.001,
            rate_burst=1,
        )
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        port = server.server_address[1]
        wire_token = derive_role_token(root_token, "mutator")

        def request(
            method: str,
            path: str,
            *,
            authorization: str | None = None,
            body: bytes | None = None,
            declared_length: int | None = None,
        ) -> int:
            connection = http.client.HTTPConnection("127.0.0.1", port, timeout=2)
            try:
                connection.putrequest(method, path)
                if authorization is not None:
                    connection.putheader("Authorization", f"Bearer {authorization}")
                if body is not None or declared_length is not None:
                    connection.putheader("Content-Type", "application/json")
                    connection.putheader(
                        "Content-Length",
                        str(declared_length if declared_length is not None else len(body or b"")),
                    )
                connection.endheaders(body)
                response = connection.getresponse()
                response.read()
                return response.status
            finally:
                connection.close()

        try:
            self.assertEqual(request("GET", "/health"), 401)
            self.assertEqual(request("GET", "/health", authorization=root_token), 401)
            self.assertEqual(request("GET", "/health", authorization=wire_token), 200)
            self.assertEqual(request("GET", "/health", authorization=wire_token), 429)
        finally:
            server.shutdown()
            server.server_close()
            thread.join(timeout=3)

        limit_server = create_server(bridge, port=0, token=root_token)
        limit_thread = threading.Thread(target=limit_server.serve_forever, daemon=True)
        limit_thread.start()
        port = limit_server.server_address[1]
        try:
            self.assertEqual(
                request(
                    "POST",
                    "/rpc",
                    authorization=wire_token,
                    declared_length=MAX_REQUEST_BODY_BYTES + 1,
                ),
                413,
            )
        finally:
            limit_server.shutdown()
            limit_server.server_close()
            limit_thread.join(timeout=3)

    def test_rpc_http_boundary_refuses_non_loopback_binding(self):
        bridge = GameAgentBridge(HeadlessGameAdapter(self.project))
        with self.assertRaises(ValueError):
            create_server(
                bridge,
                host="0.0.0.0",
                port=0,
                token="binding-root-token-with-at-least-thirty-two-bytes",
            )


if __name__ == "__main__":
    unittest.main()
