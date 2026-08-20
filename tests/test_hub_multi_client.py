"""Unit tests for Multi-Client session coordination and routing."""

import unittest
from rqe.hub.lifecycle import start_multi_client_session


class FakeMultiClientBridge:
    def __init__(self, sessions=None):
        self._sessions = sessions or [
            {"session": "sess_server", "context": "server", "role": "server", "polls": 5},
            {"session": "sess_client_1", "context": "client", "role": "client:1", "polls": 4},
            {"session": "sess_client_2", "context": "client", "role": "client:2", "polls": 4},
        ]
        self.calls = []

    def status(self):
        return {"sessions": self._sessions}

    def call(self, method, params=None, timeout=15):
        self.calls.append((method, params or {}))
        return {"ok": True}


class TestMultiClientLifecycle(unittest.TestCase):
    def test_start_multi_client_session_discovers_all_clients(self):
        bridge = FakeMultiClientBridge()
        result = start_multi_client_session(bridge, client_count=2, wait_seconds=5)
        self.assertTrue(result["started"])
        self.assertEqual(result["serverSession"], "sess_server")
        self.assertEqual(len(result["clientSessions"]), 2)
        self.assertIn("sess_client_1", result["clientSessions"])
        self.assertIn("sess_client_2", result["clientSessions"])

    def test_missing_bridge_reports_error(self):
        result = start_multi_client_session(None, client_count=2)
        self.assertFalse(result["started"])
        self.assertEqual(result["error"], "no bridge supplied")


if __name__ == "__main__":
    unittest.main()
