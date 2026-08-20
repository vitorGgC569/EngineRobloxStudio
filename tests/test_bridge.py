import unittest
from pathlib import Path

from rqe.bridge.adapters import HeadlessGameAdapter, StudioGameAdapter
from rqe.bridge.core import GameAgentBridge
from rqe.bridge.rpc import BridgeRpcService
from rqe.bridge.transport import RecordingTransport
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
        service = BridgeRpcService(bridge, token="secret")
        denied = service.handle({"id": 1, "method": "game.start"}, "Bearer wrong")
        self.assertIn("error", denied)
        allowed = service.handle({"id": 2, "method": "game.start", "params": {"mode": "graybox"}}, "Bearer secret")
        self.assertIn("result", allowed)


if __name__ == "__main__":
    unittest.main()
