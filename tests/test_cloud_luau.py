"""Open Cloud Luau execution, driven against a scripted transport.

No credentials are used and no request reaches Roblox. What is verified is the
part that matters for honesty: every way a task can fail to produce a usable
answer is a distinct, named, non-passing state, and none of them is silence.
"""

from __future__ import annotations

import json
import unittest

from rqe.assets.http import HttpRequest, HttpResponse
from rqe.cloud import (
    CloudConfig,
    LuauExecutionClient,
    LuauExecutionError,
    TaskState,
)


TASK_PATH = "universes/1/places/2/luau-execution-sessions/s1/tasks/t1"


def _response(status: int, payload: dict) -> HttpResponse:
    return HttpResponse(status=status, body=json.dumps(payload).encode("utf-8"))


class ScriptedTransport:
    """Answers by URL suffix, recording every request for inspection."""

    def __init__(self, states, *, logs=None, log_status=200, create_status=200, next_page=False):
        self.states = list(states)
        self.logs = logs if logs is not None else ["hello"]
        self.log_status = log_status
        self.create_status = create_status
        self.next_page = next_page
        self.requests: list[HttpRequest] = []

    def send(self, request: HttpRequest) -> HttpResponse:
        self.requests.append(request)
        if request.method == "POST":
            if self.create_status >= 400:
                return _response(self.create_status, {"error": {"message": "denied"}})
            return _response(200, {"path": TASK_PATH, "state": "QUEUED"})
        if request.url.endswith("/logs"):
            payload = {
                "luauExecutionSessionTaskLogs": [{"messages": self.logs}],
            }
            if self.next_page:
                payload["nextPageToken"] = "more"
            return _response(self.log_status, payload)
        return _response(200, self.states.pop(0) if self.states else {"state": "COMPLETE"})


class FakeClock:
    def __init__(self) -> None:
        self.now = 0.0

    def __call__(self) -> float:
        return self.now

    def sleep(self, seconds: float) -> None:
        self.now += seconds


def _client(transport, *, api_key="key", clock=None):
    clock = clock or FakeClock()
    return LuauExecutionClient(
        CloudConfig(universe_id="1", place_id="2", api_key=api_key),
        transport,
        sleep=clock.sleep,
        clock=clock,
    )


class TestCapabilities(unittest.TestCase):
    def test_missing_credentials_are_reported_as_a_blocker_not_a_failure(self):
        client = _client(ScriptedTransport([]), api_key=None)
        capabilities = client.capabilities()
        self.assertFalse(capabilities["available"])
        self.assertIn("luau-execution-sessions:write", capabilities["blockers"][0])

    def test_documented_ceilings_are_reported(self):
        capabilities = _client(ScriptedTransport([])).capabilities()
        self.assertEqual(capabilities["maxTaskSeconds"], 300)
        self.assertEqual(capabilities["maxConcurrentTasks"], 10)


class TestExecution(unittest.TestCase):
    def test_a_completed_task_returns_its_output_and_logs(self):
        transport = ScriptedTransport([
            {"state": "PROCESSING"},
            {"state": "COMPLETE", "output": {"results": [1, "two"]}},
        ])
        result = _client(transport).execute("return 1, 'two'")
        self.assertIs(result.state, TaskState.COMPLETE)
        self.assertEqual(result.output, (1, "two"))
        self.assertEqual(result.logs, ("hello",))
        self.assertTrue(result.ok)

    def test_the_api_key_is_sent_as_a_header_and_never_in_the_body(self):
        transport = ScriptedTransport([{"state": "COMPLETE", "output": {"results": []}}])
        _client(transport).execute("return true")
        post = transport.requests[0]
        self.assertEqual(post.headers["x-api-key"], "key")
        self.assertNotIn(b"key", post.body or b"")

    def test_a_failed_task_carries_the_error_and_is_not_ok(self):
        transport = ScriptedTransport([
            {"state": "FAILED", "error": {"message": "attempt to index nil"}},
        ])
        result = _client(transport).execute("return nil.x")
        self.assertIs(result.state, TaskState.FAILED)
        self.assertIn("attempt to index nil", result.error or "")
        self.assertFalse(result.ok)

    def test_a_timeout_says_the_task_may_still_be_mutating_the_place(self):
        """A client that gave up is not a task that stopped, and treating them
        as the same thing is how a second run measures a world the first one is
        still changing."""

        clock = FakeClock()
        transport = ScriptedTransport([{"state": "PROCESSING"}] * 50)
        result = _client(transport, clock=clock).execute(
            "while true do end", timeout_seconds=10, poll_interval=4
        )
        self.assertIs(result.state, TaskState.TIMEOUT)
        self.assertIn("may still be running", result.error or "")
        self.assertFalse(result.ok)

    def test_unreadable_logs_are_truncated_rather_than_empty(self):
        """'Printed nothing' and 'we could not find out what it printed' support
        very different conclusions."""

        transport = ScriptedTransport(
            [{"state": "COMPLETE", "output": {"results": []}}], log_status=500
        )
        result = _client(transport).execute("print('x')")
        self.assertTrue(result.truncated)
        self.assertFalse(result.ok)

    def test_paginated_logs_are_reported_as_truncated(self):
        transport = ScriptedTransport(
            [{"state": "COMPLETE", "output": {"results": []}}], next_page=True
        )
        result = _client(transport).execute("print('x')")
        self.assertTrue(result.truncated)
        self.assertFalse(result.ok)

    def test_no_credentials_blocks_before_any_request_is_made(self):
        transport = ScriptedTransport([])
        result = _client(transport, api_key=None).execute("return 1")
        self.assertIs(result.state, TaskState.BLOCKED)
        self.assertEqual(transport.requests, [])

    def test_a_rejected_creation_fails_rather_than_polling_forever(self):
        transport = ScriptedTransport([], create_status=403)
        result = _client(transport).execute("return 1")
        self.assertIs(result.state, TaskState.FAILED)
        self.assertIn("403", result.error or "")

    def test_an_unrecognised_state_fails_closed(self):
        transport = ScriptedTransport([{"state": "SOMETHING_NEW"}])
        result = _client(transport).execute("return 1")
        self.assertIs(result.state, TaskState.FAILED)
        self.assertIn("unrecognised", result.error or "")

    def test_a_timeout_above_the_documented_ceiling_is_refused_locally(self):
        with self.assertRaises(LuauExecutionError):
            _client(ScriptedTransport([])).execute("return 1", timeout_seconds=999)

    def test_an_empty_script_is_refused(self):
        with self.assertRaises(LuauExecutionError):
            _client(ScriptedTransport([])).execute("   ")


class TestEvidenceShape(unittest.TestCase):
    def test_the_detail_marks_a_truncated_result_inconclusive(self):
        transport = ScriptedTransport(
            [{"state": "COMPLETE", "output": {"results": []}}], next_page=True
        )
        detail = _client(transport).execute("print('x')").to_evidence_detail()
        self.assertTrue(detail["truncated"])
        self.assertFalse(detail["conclusive"])
        self.assertEqual(detail["source"], "open-cloud-luau")

    def test_a_clean_result_is_conclusive(self):
        transport = ScriptedTransport([{"state": "COMPLETE", "output": {"results": [7]}}])
        detail = _client(transport).execute("return 7").to_evidence_detail()
        self.assertTrue(detail["conclusive"])
        self.assertEqual(detail["outputCount"], 1)


if __name__ == "__main__":
    unittest.main()
