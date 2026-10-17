from contextlib import contextmanager
import unittest

from rqe.hub.native_test import run_native_test


class Peer:
    def __init__(self):
        self.pinned_session = None
        self._active_lease = None
        self.state = {"started": False, "finished": False, "calls": [], "leases": set()}

    def pin_to_context(self, *_a, **_kw):
        self.pinned_session = "edit"
        return "edit"

    def status(self):
        sessions = [{"session": "edit", "context": "edit", "installationId": "local"}]
        if self.state["started"]:
            sessions += [{"session": name, "context": "server", "installationId": "local"}
                         for name in ("foreign", "owned")]
        return {"sessions": sessions}

    @contextmanager
    def lease_scope(self, **kwargs):
        session = kwargs["session_id"]
        self.state["leases"].add(session)
        try:
            yield {}
        finally:
            self.state["leases"].remove(session)

    def call(self, method, params, **_kwargs):
        self.state["calls"].append((self.pinned_session, method, params))
        if method == "studio.info":
            return {"context": "edit"}
        if method == "test.start":
            assert "edit" in self.state["leases"]
            self.state["started"] = True
            return {"id": "our-test"}
        if method == "test.status":
            if self.pinned_session == "edit":
                return {"job": {"id": "our-test", "status": "FINISHED" if self.state["finished"] else "RUNNING",
                                "result": self.state.get("result")}}
            return {"args": {"rqeTestId": "our-test" if self.pinned_session == "owned" else "someone-else"}}
        if method == "test.finish":
            assert self.pinned_session == "owned" and {"owned", "edit"} <= self.state["leases"]
            self.state.update(finished=True, result=params["result"])
            return {"ending": True}
        raise AssertionError(method)


class NativeTestTests(unittest.TestCase):
    def test_edit_peer_without_job_during_transition_still_requires_matching_runtime(self):
        from unittest.mock import patch
        real_call = Peer.call
        def transitioning(self, method, params, **kwargs):
            value = real_call(self, method, params, **kwargs)
            if self.pinned_session == "edit" and method == "test.status" and not self.state["finished"]:
                return {"editModeActive": False, "args": {"rqeTestId": "our-test"}}
            return value
        with patch.object(Peer, "call", transitioning):
            result = run_native_test(Peer())
        self.assertEqual(result["status"], "COMPLETED")
        self.assertEqual(result["runtimeSession"], "owned")

    def test_unrelated_server_is_observed_but_never_mutated(self):
        peer = Peer()
        result = run_native_test(peer)
        self.assertEqual(result["status"], "COMPLETED")
        self.assertEqual(result["runtimeSession"], "owned")
        self.assertEqual(result["claim"], "COMMAND_SUCCESS")
        self.assertFalse(result["authorizesRelease"])
        self.assertIsNone(peer.pinned_session)
        self.assertEqual(peer.state["leases"], set())
        self.assertFalse(any(s == "foreign" and m != "test.status" for s, m, _ in peer.state["calls"]))

    def test_exercise_failure_aborts_owned_test_and_releases_both_leases(self):
        peer = Peer()
        def fail(*_):
            raise RuntimeError("gameplay invariant failed")
        result = run_native_test(peer, exercise=fail)
        self.assertEqual(result["status"], "FAILED")
        self.assertIn("gameplay invariant", result["error"])
        self.assertEqual(peer.state["result"], {"aborted": True})
        self.assertEqual(peer.state["leases"], set())

    def test_runtime_identity_is_rechecked_before_exercise(self):
        peer = Peer()
        reads = 0
        from unittest.mock import patch
        real_call = Peer.call
        def replacing(self, method, params, **kwargs):
            nonlocal reads
            value = real_call(self, method, params, **kwargs)
            if self.pinned_session == "owned" and method == "test.status":
                reads += 1
                if reads > 1:
                    value["args"]["rqeTestId"] = "different-test"
            return value
        with patch.object(Peer, "call", replacing):
            result = run_native_test(peer, exercise=lambda *_: self.fail("must not exercise a different test"))
        self.assertEqual(result["status"], "FAILED")
        self.assertIn("runtime changed", result["error"])

