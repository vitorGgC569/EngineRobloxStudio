import json
from pathlib import Path
import unittest
from unittest.mock import Mock, patch

from rqe.mcp.client import FederatedResult, ToolDescriptor
from rqe.mcp.protocol import Request
from rqe.mcp.tools import build_server


class FederationExecutionTests(unittest.TestCase):
    def call(self, arguments):
        response=build_server(Path(__file__).resolve().parents[1]).handle(Request(
            id=1,method="tools/call",params={"name":"federated_call","arguments":arguments}))
        self.assertTrue(response.ok, response.error)
        return response.result["structuredContent"]["data"]

    def test_spawn_failure_is_an_explicit_tool_result(self):
        with patch("rqe.mcp.client.studio_mcp_command",side_effect=RuntimeError("missing peer")):
            result=self.call({"tool":"list_roblox_studios"})
        self.assertFalse(result["ok"])
        self.assertIn("missing peer",result["error"])

    def test_exact_studio_and_typed_peer_result_are_preserved(self):
        peer=Mock()
        peer.tools.return_value=(ToolDescriptor("user_keyboard_input",input_schema={"required":["studio_id","keys"]}),)
        peer.call_tool.return_value=FederatedResult(tool="user_keyboard_input",ok=True,structured={"accepted":True})
        with patch("rqe.mcp.client.studio_mcp_command",return_value=["fixture"]), \
             patch("rqe.mcp.client.StudioMcpClient.spawn",return_value=peer) as spawn:
            rejected=self.call({"tool":"user_keyboard_input","arguments":{"keys":["E"]}})
            self.assertFalse(rejected["ok"]);peer.call_tool.assert_not_called()
            accepted=self.call({"tool":"user_keyboard_input","arguments":{"studio_id":"exact","keys":["E"]}})
        self.assertEqual(spawn.call_args.args,(["fixture"],))
        self.assertEqual(accepted["structured"],{"accepted":True})
        self.assertEqual(accepted["source"],"roblox-studio-mcp")
        self.assertTrue(peer.close.called)


if __name__ == "__main__": unittest.main()
