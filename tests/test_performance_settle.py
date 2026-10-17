import unittest

from rqe.observe import DEFAULT_OBSERVE_CONFIG, Observation, _settle_runtime


class _Response:
    def __init__(self, ok, result=None):
        self.ok = ok
        self.result = result


class _Bridge:
    def __init__(self, replies):
        self.replies = list(replies)
        self.calls = 0

    def call_response(self, method, params=None, timeout=10):
        self.calls += 1
        if not self.replies:
            return _Response(False)
        reply = self.replies.pop(0)
        return _Response(True, reply)


class _Collector:
    def __init__(self, bridge):
        self.bridge = bridge


def _config(**overrides):
    return {
        **DEFAULT_OBSERVE_CONFIG,
        "runtimeReadyTimeoutSeconds": 0.05,
        "runtimeSettleSeconds": 0.0,
        **overrides,
    }


def _observation(context="server"):
    return Observation(run_id="settle", started_at="now", context=context, place={})


class SettleRuntimeTests(unittest.TestCase):
    def test_a_nonempty_marker_ends_the_wait(self):
        bridge = _Bridge([{"properties": {"Value": "tidebound-server"}}])
        settle = _settle_runtime(_Collector(bridge), _observation(), _config())
        self.assertEqual(settle["readyValue"], "tidebound-server")
        self.assertEqual(settle["readyPolls"], 1)
        self.assertIsNotNone(settle["readyWaitedSeconds"])
        self.assertEqual(bridge.calls, 1)

    def test_an_empty_marker_value_is_not_ready(self):
        bridge = _Bridge([
            {"properties": {"Value": ""}},
            {"properties": {"Value": "tidebound-server"}},
        ])
        settle = _settle_runtime(_Collector(bridge), _observation(), _config())
        self.assertEqual(settle["readyValue"], "tidebound-server")
        self.assertEqual(settle["readyPolls"], 2)

    def test_a_missing_marker_polls_until_the_deadline(self):
        bridge = _Bridge([])
        settle = _settle_runtime(_Collector(bridge), _observation(), _config())
        self.assertIsNone(settle["readyValue"])
        self.assertIsNone(settle["readyWaitedSeconds"])
        self.assertGreater(bridge.calls, 0)

    def test_waiting_records_no_command_errors(self):
        observation = _observation()
        bridge = _Bridge([])
        _settle_runtime(_Collector(bridge), observation, _config())
        self.assertEqual(observation.errors, [])

    def test_edit_context_skips_the_wait_entirely(self):
        bridge = _Bridge([])
        settle = _settle_runtime(_Collector(bridge), _observation(context="edit"), _config())
        self.assertEqual(settle, {"skipped": "edit context"})
        self.assertEqual(bridge.calls, 0)

    def test_quiet_period_is_honored_after_the_marker(self):
        bridge = _Bridge([{"properties": {"Value": "ready"}}])
        settle = _settle_runtime(
            _Collector(bridge), _observation(), _config(runtimeSettleSeconds=0.05)
        )
        self.assertGreaterEqual(settle["settledSeconds"], 0.05)


if __name__ == "__main__":
    unittest.main()
