"""Transport tests for the Studio Bridge hub.

These run a real HTTP server on a real socket with a real plugin peer, so a pass
here means the handshake, long-poll, correlation, timeout and error paths work.
It does *not* mean Studio works: the peer is a simulator and is labeled as such.
"""

from __future__ import annotations

import threading
import time
import unittest
import json
import urllib.error
import urllib.request
from typing import Any

from rqe.hub.client import PluginSimulator, StudioBridge
from rqe.hub.protocol import PROTOCOL_VERSION, BridgeError, ErrorCode
from rqe.hub.server import BridgeHub, serve


class HubTestCase(unittest.TestCase):
    def setUp(self) -> None:
        self.hub = BridgeHub(poll_hold_seconds=1.0)
        self.server = serve(self.hub, host="127.0.0.1", port=0)
        self.port = self.server.server_address[1]
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()
        self.base_url = f"http://127.0.0.1:{self.port}"
        self.bridge = StudioBridge(self.base_url)
        self.plugin: PluginSimulator | None = None

    def tearDown(self) -> None:
        if self.plugin is not None:
            self.plugin.stop()
        self.server.shutdown()
        self.server.server_close()
        self.thread.join(timeout=3)

    def start_plugin(self, handlers, context: str = "edit") -> PluginSimulator:
        self.plugin = PluginSimulator(self.base_url, handlers, context=context)
        self.plugin.start()
        self.bridge.wait_for_plugin(timeout=10)
        return self.plugin

    @staticmethod
    def register_direct(hub: BridgeHub, client_id: str, context: str = "edit") -> str:
        return hub.register({
            "protocol": PROTOCOL_VERSION,
            "clientId": client_id,
            "pluginVersion": "test",
            "studioVersion": "test",
            "placeName": f"{client_id}.rbxlx",
            "placeId": 0,
            "context": context,
        })["session"]

    # ------------------------------------------------------------------- tests

    def test_health_is_served_before_any_plugin_connects(self) -> None:
        health = self.bridge.health()
        self.assertTrue(health["ok"])
        self.assertEqual(health["protocol"], PROTOCOL_VERSION)

    def test_call_without_plugin_reports_disconnected_instead_of_a_default(self) -> None:
        with self.assertRaises(BridgeError) as caught:
            self.bridge.call("bridge.ping", timeout=2)
        self.assertEqual(caught.exception.code, ErrorCode.DISCONNECTED)

    def test_round_trip_carries_params_and_studio_context(self) -> None:
        self.start_plugin({"dm.tree": lambda params: {"echo": params, "children": ["Workspace"]}})
        response = self.bridge.call_response("dm.tree", {"path": "game", "depth": 1})
        self.assertTrue(response.ok)
        self.assertEqual(response.result["echo"]["path"], "game")
        self.assertEqual(response.context, "edit")
        self.assertEqual(response.place, "SimulatedPlace")

    def test_plugin_error_surfaces_as_bridge_error_with_code(self) -> None:
        def explode(_params):
            raise RuntimeError("instance is not a BasePart")

        self.start_plugin({"world.bounds": explode})
        with self.assertRaises(BridgeError) as caught:
            self.bridge.call("world.bounds", {"path": "game.Workspace"})
        self.assertEqual(caught.exception.code, ErrorCode.EXEC)
        self.assertIn("not a BasePart", caught.exception.message)

    def test_plugin_result_that_violates_the_manifest_is_rejected(self) -> None:
        self.start_plugin({"world.summary": lambda _params: "not-an-object"})
        with self.assertRaises(BridgeError) as caught:
            self.bridge.call("world.summary")
        self.assertEqual(caught.exception.code, ErrorCode.SCHEMA)

    def test_invalid_params_are_rejected_before_they_enter_a_session_queue(self) -> None:
        session = self.register_direct(self.hub, "schema-target")
        with self.assertRaises(BridgeError) as caught:
            self.hub.call("world.raycast", {"origin": [0, 10, 0]}, timeout=1, session_id=session)
        self.assertEqual(caught.exception.code, ErrorCode.BAD_PARAMS)
        self.assertEqual(self.hub.status()["queuedCommands"], 0)
        self.assertEqual(self.hub.poll(session)["commands"], [])

    def test_typed_conveniences_omit_optional_nulls_rejected_by_the_contract(self) -> None:
        seen: dict[str, dict[str, Any]] = {}

        def remember(method: str):
            def handler(params: dict[str, Any]) -> dict[str, Any]:
                seen[method] = params
                return {"ok": True}
            return handler

        self.start_plugin({"dm.find": remember("dm.find"), "log.tail": remember("log.tail")})
        self.bridge.find()
        self.bridge.logs()
        self.assertEqual(seen["dm.find"], {"root": "game.Workspace", "limit": 200})
        self.assertEqual(seen["log.tail"], {"limit": 100})

    def test_unknown_method_is_rejected_by_the_plugin(self) -> None:
        self.start_plugin({"bridge.ping": lambda _params: {"pong": True}})
        with self.assertRaises(BridgeError) as caught:
            self.bridge.call("does.not.exist", timeout=5)
        self.assertEqual(caught.exception.code, ErrorCode.UNKNOWN_METHOD)

    def test_slow_command_times_out_and_is_not_delivered_late(self) -> None:
        def slow(_params):
            time.sleep(2.5)
            return {"late": True}

        self.start_plugin({"run.state": slow})
        with self.assertRaises(BridgeError) as caught:
            self.bridge.call("run.state", timeout=1)
        self.assertEqual(caught.exception.code, ErrorCode.TIMEOUT)
        # The late answer must be dropped rather than handed to the next caller.
        time.sleep(2.5)
        self.assertEqual(self.hub.status()["inflightCommands"], 0)

    def test_concurrent_calls_are_correlated_to_their_own_results(self) -> None:
        self.start_plugin({"dm.properties": lambda params: {"path": params["path"]}})
        results: dict[str, str] = {}
        errors: list[Exception] = []

        def worker(index: int) -> None:
            try:
                bridge = StudioBridge(self.base_url)
                value = bridge.call("dm.properties", {"path": f"game.Workspace.Part{index}"})
                results[f"Part{index}"] = value["path"]
            except Exception as exc:  # surfaced after the join
                errors.append(exc)

        threads = [threading.Thread(target=worker, args=(index,)) for index in range(6)]
        for thread in threads:
            thread.start()
        for thread in threads:
            thread.join(timeout=15)

        self.assertEqual(errors, [])
        self.assertEqual(len(results), 6)
        for index in range(6):
            self.assertEqual(results[f"Part{index}"], f"game.Workspace.Part{index}")

    def test_status_reports_the_connected_session(self) -> None:
        self.start_plugin({"bridge.ping": lambda _params: {"pong": True}}, context="run")
        status = self.bridge.status()
        self.assertEqual(len(status["sessions"]), 1)
        self.assertEqual(status["sessions"][0]["context"], "run")
        self.assertEqual(status["protocol"], PROTOCOL_VERSION)

    def test_protocol_mismatch_is_refused_at_the_handshake(self) -> None:
        plugin = PluginSimulator(self.base_url, {})
        original = plugin._post

        def downgrade(path, payload, timeout=40.0):
            if path == "/bridge/hello":
                payload = {**payload, "protocol": "rqe.bridge/0"}
            return original(path, payload, timeout)

        plugin._post = downgrade  # type: ignore[method-assign]
        with self.assertRaises(Exception):
            plugin.connect()

    def test_events_are_buffered_and_filterable(self) -> None:
        self.start_plugin({"bridge.ping": lambda _params: {"pong": True}})
        session = self.plugin.session
        self.hub.push_events(session, [
            {"kind": "log", "severity": "error", "message": "boom"},
            {"kind": "log", "severity": "info", "message": "fine"},
            {"kind": "heartbeat", "fps": 59.4},
        ])
        self.assertEqual(len(self.hub.events()), 3)
        self.assertEqual(len(self.hub.events(kind="log")), 2)
        self.assertEqual(self.hub.events(kind="heartbeat")[0]["fps"], 59.4)

    def test_same_studio_switching_context_supersedes_its_old_session(self) -> None:
        """A Studio entering run mode re-registers; the edit session must retire.

        Without this the hub can hold two sessions for one Studio and route a
        command to the half that stopped polling, which surfaces as a timeout.
        """
        edit = PluginSimulator(self.base_url, {"bridge.ping": lambda _p: {"from": "edit"}}, context="edit", client_id="studio-A")
        edit.start()
        self.bridge.wait_for_plugin(timeout=10)
        self.assertEqual(len(self.hub.status()["sessions"]), 1)

        edit.stop()
        run = PluginSimulator(self.base_url, {"bridge.ping": lambda _p: {"from": "run"}}, context="run", client_id="studio-A")
        run.start()
        try:
            deadline = time.monotonic() + 10
            sessions = self.hub.status()["sessions"]
            while len(sessions) != 1 and time.monotonic() < deadline:
                time.sleep(0.1)
                sessions = self.hub.status()["sessions"]
            self.assertEqual(len(sessions), 1, "the abandoned edit session should have been superseded")
            self.assertEqual(sessions[0]["context"], "run")
            self.assertEqual(self.bridge.call("bridge.ping", timeout=10)["from"], "run")
        finally:
            run.stop()

    def test_dropping_a_session_retires_it_and_frees_the_routing(self) -> None:
        """Regression: a Studio we killed must not keep winning the routing.

        Observed for real -- `studio restart` terminated Studio, but its poll
        handler stayed blocked until it tried to write, so the corpse still
        reported an open poll and absorbed the next command. The caller knows it
        killed that process, so it says so explicitly.
        """
        zombie = PluginSimulator(self.base_url, {"world.summary": lambda _p: {"from": "zombie"}}, client_id="killed")
        zombie.start()
        self.bridge.wait_for_plugin(timeout=10)
        zombie_session = zombie.session
        zombie.stop()

        live = PluginSimulator(self.base_url, {"world.summary": lambda _p: {"from": "live"}}, client_id="fresh")
        live.start()
        try:
            deadline = time.monotonic() + 10
            while len(self.hub.status()["sessions"]) < 2 and time.monotonic() < deadline:
                time.sleep(0.1)

            dropped = self.bridge.drop_sessions([zombie_session])
            self.assertEqual(dropped, [zombie_session])
            remaining = {item["session"] for item in self.hub.status()["sessions"]}
            self.assertNotIn(zombie_session, remaining)
            self.assertEqual(self.bridge.call("world.summary", timeout=10)["from"], "live")
        finally:
            live.stop()

    def test_other_traffic_does_not_keep_a_dead_session_alive(self) -> None:
        """Regression: a killed Studio must age out even while the hub is busy.

        Observed for real -- `last_seen` was refreshed every time the poll's
        condition variable woke, so any other session's activity rejuvenated a
        Studio that had already been killed. It stayed "fresh" forever, kept
        winning the routing, and every command sent to it timed out.
        """
        dead = PluginSimulator(self.base_url, {}, context="edit", client_id="ghost")
        dead.connect()  # handshake, then never polls again
        live = PluginSimulator(self.base_url, {"bridge.ping": lambda _p: {"ok": True}}, context="edit", client_id="alive")
        live.start()
        try:
            self.bridge.wait_for_plugin(timeout=10)
            # Generate steady traffic while the ghost ages. Status calls rather
            # than dispatched commands: this test is about whether a session
            # ages, and routing a command under load only adds a timing
            # dependency that has nothing to do with the behaviour under test.
            deadline = time.monotonic() + (self.hub.poll_hold_seconds + 11)
            while time.monotonic() < deadline:
                self.hub.status()
                time.sleep(0.2)

            ages = {item["clientId"]: item["lastSeenSeconds"] for item in self.hub.status()["sessions"]}
            self.assertIn("alive", ages)
            if "ghost" in ages:
                self.assertGreater(
                    ages["ghost"],
                    self.hub.poll_hold_seconds,
                    "a session that stopped polling must keep ageing",
                )
        finally:
            live.stop()

    def test_queued_work_survives_a_context_switch(self) -> None:
        """Regression: a command queued when Studio flips edit->run must survive.

        Observed for real -- `run.start` changed the context, the plugin
        re-registered, and the already-queued `world.summary` was failed with
        E_DISCONNECTED even though the same Studio was still right there.
        """
        handlers = {"world.summary": lambda _p: {"parts": 262}}
        edit = PluginSimulator(self.base_url, handlers, context="edit", client_id="studio-X")
        edit.connect()
        session = edit.session

        # Queue work while nobody is polling, then have the same Studio
        # re-register under a new context before it ever gets picked up.
        result: dict[str, Any] = {}
        errors: list[Exception] = []

        def caller() -> None:
            try:
                result["value"] = self.bridge.call("world.summary", timeout=20)
            except Exception as exc:
                errors.append(exc)

        thread = threading.Thread(target=caller)
        thread.start()
        time.sleep(0.5)

        run = PluginSimulator(self.base_url, handlers, context="run", client_id="studio-X")
        run.start()
        try:
            thread.join(timeout=25)
            self.assertEqual(errors, [], "queued command should have been transferred, not failed")
            self.assertEqual(result["value"]["parts"], 262)
            self.assertEqual(len(self.hub.status()["sessions"]), 1)
        finally:
            run.stop()
        self.assertIsNotNone(session)

    def test_a_live_edit_session_beats_a_dead_run_session(self) -> None:
        """Regression: a Studio that died in run mode must not win the routing.

        Observed for real -- Studio was killed during a playtest, restarted, and
        the hub kept routing to the abandoned "run" session because context was
        ranked above liveness. Every command timed out while a healthy plugin sat
        idle.
        """
        dead = PluginSimulator(self.base_url, {"bridge.ping": lambda _p: {"from": "dead"}}, context="run", client_id="old-studio")
        dead.connect()  # handshake only: it never polls, exactly like a killed Studio
        live = PluginSimulator(self.base_url, {"bridge.ping": lambda _p: {"from": "live"}}, context="edit", client_id="new-studio")
        live.start()
        try:
            self.bridge.wait_for_plugin(timeout=10)
            deadline = time.monotonic() + 10
            while len(self.hub.status()["sessions"]) < 2 and time.monotonic() < deadline:
                time.sleep(0.1)
            # Age out the dead session past the freshness window.
            time.sleep(self.hub.poll_hold_seconds + 10.5)
            self.assertEqual(self.bridge.call("bridge.ping", timeout=10)["from"], "live")
        finally:
            live.stop()

    def test_run_context_is_preferred_over_edit_context(self) -> None:
        edit_plugin = PluginSimulator(self.base_url, {"bridge.ping": lambda _p: {"from": "edit"}}, context="edit")
        edit_plugin.start()
        run_plugin = PluginSimulator(self.base_url, {"bridge.ping": lambda _p: {"from": "run"}}, context="run")
        run_plugin.start()
        try:
            self.bridge.wait_for_plugin(timeout=10)
            # A hello says a session exists; its first poll proves it can accept
            # work. Wait for that liveness signal before asserting preference,
            # otherwise the already-polling edit peer correctly wins the race.
            deadline = time.monotonic() + 10
            sessions = self.hub.status()["sessions"]
            while (
                not any(item["context"] == "run" and item["polls"] > 0 for item in sessions)
                and time.monotonic() < deadline
            ):
                time.sleep(0.1)
                sessions = self.hub.status()["sessions"]
            self.assertTrue(any(item["context"] == "run" and item["polls"] > 0 for item in sessions))
            response = self.bridge.call_response("bridge.ping", timeout=10)
            self.assertEqual(response.context, "run")
            self.assertEqual(response.result["from"], "run")
        finally:
            edit_plugin.stop()
            run_plugin.stop()

    def test_a_result_from_another_session_cannot_complete_the_command(self) -> None:
        """Correlation id possession does not grant completion authority."""

        assigned = self.register_direct(self.hub, "assigned")
        impostor = self.register_direct(self.hub, "impostor")
        outcome: dict[str, Any] = {}

        def caller() -> None:
            outcome["response"] = self.hub.call("world.summary", {}, timeout=5, session_id=assigned)

        thread = threading.Thread(target=caller)
        thread.start()
        command = self.hub.poll(assigned)["commands"][0]

        wrong = self.hub.complete(impostor, [{
            "id": command["id"],
            "ok": True,
            "result": {"from": "wrong-session"},
            "context": "edit",
        }])
        self.assertEqual(wrong["accepted"], 0)
        self.assertEqual(wrong["rejected"][0]["code"], ErrorCode.TARGET_MISMATCH)
        self.assertTrue(thread.is_alive(), "wrong-session completion must not wake the caller")

        right = self.hub.complete(assigned, [{
            "id": command["id"],
            "ok": True,
            "result": {"from": "assigned-session"},
            "context": "edit",
        }])
        self.assertEqual(right["accepted"], 1)
        thread.join(timeout=5)
        self.assertFalse(thread.is_alive())
        self.assertEqual(outcome["response"].result["from"], "assigned-session")

    def test_context_transition_reports_on_origin_session_before_rehandshake(self) -> None:
        """run.start/stop keep origin completion authority across the engine flip."""

        origin = self.register_direct(self.hub, "transition-studio", context="edit")
        outcome: dict[str, Any] = {}

        def caller() -> None:
            outcome["response"] = self.hub.call(
                "run.start", {"settleSeconds": 0}, timeout=5, session_id=origin,
            )

        thread = threading.Thread(target=caller)
        thread.start()
        command = self.hub.poll(origin)["commands"][0]
        accepted = self.hub.complete(origin, [{
            "id": command["id"],
            "ok": True,
            "result": {"started": True, "context": "run"},
            "context": "run",
        }])
        self.assertEqual(accepted["accepted"], 1)
        successor = self.register_direct(self.hub, "transition-studio", context="run")
        thread.join(timeout=5)

        self.assertFalse(thread.is_alive())
        self.assertEqual(outcome["response"].session, origin)
        self.assertEqual(outcome["response"].context, "run")
        self.assertNotEqual(successor, origin)
        self.assertEqual([item["session"] for item in self.hub.status()["sessions"]], [successor])

    def test_a_command_that_timed_out_in_queue_is_never_dispatched(self) -> None:
        hub = BridgeHub(poll_hold_seconds=0.02)
        session = self.register_direct(hub, "deadline")
        errors: list[BridgeError] = []

        def caller() -> None:
            try:
                hub.call("world.summary", {}, timeout=0.05, session_id=session)
            except BridgeError as exc:
                errors.append(exc)

        thread = threading.Thread(target=caller)
        thread.start()
        thread.join(timeout=2)
        self.assertEqual([error.code for error in errors], [ErrorCode.TIMEOUT])
        self.assertEqual(hub.status()["queuedCommands"], 0)
        self.assertEqual(hub.poll(session)["commands"], [])
        self.assertEqual(hub.status()["inflightCommands"], 0)

    def test_lease_fence_increases_and_rejects_another_owner(self) -> None:
        hub = BridgeHub(poll_hold_seconds=0.02)
        session = self.register_direct(hub, "lease-owner")
        first = hub.acquire_lease(
            run_id="run-a", agent_id="agent-a", build_id="build-a", session_id=session, ttl_seconds=30,
        )
        same = hub.acquire_lease(
            run_id="run-a", agent_id="agent-a", build_id="build-a", session_id=session, ttl_seconds=30,
        )
        self.assertEqual(same["leaseId"], first["leaseId"])
        self.assertEqual(same["fence"], first["fence"])

        with self.assertRaises(BridgeError) as caught:
            hub.acquire_lease(
                run_id="run-b", agent_id="agent-b", build_id="build-b", session_id=session, ttl_seconds=30,
            )
        self.assertEqual(caught.exception.code, ErrorCode.LEASE_CONFLICT)

        hub.release_lease(
            lease_id=first["leaseId"], fence=first["fence"], run_id="run-a", agent_id="agent-a",
            build_id="build-a", session_id=session,
        )
        second = hub.acquire_lease(
            run_id="run-b", agent_id="agent-b", build_id="build-b", session_id=session, ttl_seconds=30,
        )
        self.assertGreater(second["fence"], first["fence"])

    def test_lease_round_trip_is_available_to_agent_clients(self) -> None:
        self.start_plugin({"camera.set": lambda params: {"applied": params["position"]}})
        lease = self.bridge.acquire_lease(
            run_id="run-http", agent_id="agent-http", build_id="build-http", session_id=self.plugin.session,
        )
        renewed = self.bridge.renew_lease(lease, ttl_seconds=45)
        self.assertEqual(renewed["leaseId"], lease["leaseId"])
        self.assertEqual(renewed["fence"], lease["fence"])
        applied = self.bridge.call("camera.set", {"position": [1, 2, 3]}, lease=renewed)
        self.assertEqual(applied["applied"], [1, 2, 3])
        released = self.bridge.release_lease(renewed)
        self.assertTrue(released["released"])

    def test_mutation_requires_current_lease_and_is_checked_again_before_dispatch(self) -> None:
        hub = BridgeHub(poll_hold_seconds=0.02, require_mutation_leases=True)
        session = self.register_direct(hub, "leased-studio")
        with self.assertRaises(BridgeError) as caught:
            hub.call("camera.set", {"position": [0, 10, 0]}, timeout=1, session_id=session)
        self.assertEqual(caught.exception.code, ErrorCode.LEASE_REQUIRED)

        lease = hub.acquire_lease(
            run_id="release-1", agent_id="qa-agent", build_id="sha256:abc", session_id=session, ttl_seconds=30,
        )
        outcome: dict[str, Any] = {}

        def caller() -> None:
            outcome["response"] = hub.call(
                "camera.set",
                {"position": [0, 10, 0]},
                timeout=5,
                session_id=session,
                lease=lease,
            )

        thread = threading.Thread(target=caller)
        thread.start()
        deadline = time.monotonic() + 2
        while hub.status()["queuedCommands"] == 0 and time.monotonic() < deadline:
            time.sleep(0.01)
        self.assertEqual(hub.status()["queuedCommands"], 1)

        # The caller had a valid fence when it queued. Releasing it before poll
        # must still prevent Studio from receiving the stale mutation.
        hub.release_lease(
            lease_id=lease["leaseId"], fence=lease["fence"], run_id="release-1", agent_id="qa-agent",
            build_id="sha256:abc", session_id=session,
        )
        self.assertEqual(hub.poll(session)["commands"], [])
        thread.join(timeout=5)
        self.assertFalse(thread.is_alive())
        self.assertFalse(outcome["response"].ok)
        self.assertEqual(outcome["response"].error["code"], ErrorCode.LEASE_STALE)

        current = hub.acquire_lease(
            run_id="release-2", agent_id="qa-agent-2", build_id="sha256:def", session_id=session, ttl_seconds=30,
        )
        delivered: dict[str, Any] = {}

        def current_caller() -> None:
            delivered["response"] = hub.call(
                "camera.set", {"position": [1, 2, 3]}, timeout=5, session_id=session, lease=current,
            )

        current_thread = threading.Thread(target=current_caller)
        current_thread.start()
        command = hub.poll(session)["commands"][0]
        self.assertEqual(command["methodVersion"], 1)
        self.assertEqual(command["target"], {
            "session": session,
            "clientId": "leased-studio",
            "runId": "release-2",
            "agentId": "qa-agent-2",
            "buildId": "sha256:def",
        })
        self.assertEqual(command["lease"], {"leaseId": current["leaseId"], "fence": current["fence"]})
        hub.complete(session, [{
            "id": command["id"],
            "ok": True,
            "result": {"applied": True},
            "context": "edit",
        }])
        current_thread.join(timeout=5)
        self.assertTrue(delivered["response"].ok)

    def test_a_mutation_waits_for_all_parallel_reads_to_finish(self) -> None:
        """Safe reads share a batch; write-like work is an exclusive FIFO barrier."""

        hub = BridgeHub(poll_hold_seconds=0.03)
        session = self.register_direct(hub, "effect-scheduler")
        outcomes: dict[str, Any] = {}

        def call_read(label: str) -> None:
            outcomes[label] = hub.call("world.summary", {}, timeout=5, session_id=session)

        first = threading.Thread(target=call_read, args=("read-a",))
        second = threading.Thread(target=call_read, args=("read-b",))
        first.start()
        second.start()
        deadline = time.monotonic() + 2
        while hub.status()["queuedCommands"] < 2 and time.monotonic() < deadline:
            time.sleep(0.01)

        reads = hub.poll(session, max_batch=8)["commands"]
        self.assertEqual(len(reads), 2)

        def call_mutation() -> None:
            outcomes["mutation"] = hub.call(
                "camera.set", {"position": [1, 2, 3]}, timeout=5, session_id=session,
            )

        mutation = threading.Thread(target=call_mutation)
        mutation.start()
        deadline = time.monotonic() + 2
        while hub.status()["queuedCommands"] < 1 and time.monotonic() < deadline:
            time.sleep(0.01)

        self.assertEqual(hub.poll(session)["commands"], [])
        hub.complete(session, [{
            "id": reads[0]["id"], "ok": True, "result": {"read": "a"}, "context": "edit",
        }])
        self.assertEqual(hub.poll(session)["commands"], [])
        hub.complete(session, [{
            "id": reads[1]["id"], "ok": True, "result": {"read": "b"}, "context": "edit",
        }])

        write_batch = hub.poll(session)["commands"]
        self.assertEqual([item["method"] for item in write_batch], ["camera.set"])
        hub.complete(session, [{
            "id": write_batch[0]["id"], "ok": True, "result": {"applied": True}, "context": "edit",
        }])
        for thread in (first, second, mutation):
            thread.join(timeout=5)
            self.assertFalse(thread.is_alive())
        self.assertEqual(set(outcomes), {"read-a", "read-b", "mutation"})

    def test_a_timed_out_inflight_mutation_remains_uncertain_until_studio_answers(self) -> None:
        """A caller timeout cannot silently unlock overlapping Studio mutation."""

        hub = BridgeHub(poll_hold_seconds=0.03)
        session = self.register_direct(hub, "uncertain-mutation")
        errors: list[BridgeError] = []

        def first_call() -> None:
            try:
                hub.call("camera.set", {"position": [1, 2, 3]}, timeout=0.08, session_id=session)
            except BridgeError as exc:
                errors.append(exc)

        first = threading.Thread(target=first_call)
        first.start()
        first_command = hub.poll(session)["commands"][0]
        first.join(timeout=2)
        self.assertEqual([error.code for error in errors], [ErrorCode.TIMEOUT])
        self.assertEqual(errors[0].details["outcome"], "unknown_after_dispatch")
        self.assertEqual(hub.status()["uncertainCommands"], 1)
        self.assertEqual(hub.status()["inflightCommands"], 1)

        second_outcome: dict[str, Any] = {}

        def second_call() -> None:
            second_outcome["response"] = hub.call(
                "camera.set", {"position": [4, 5, 6]}, timeout=3, session_id=session,
            )

        second = threading.Thread(target=second_call)
        second.start()
        deadline = time.monotonic() + 2
        while hub.status()["queuedCommands"] < 1 and time.monotonic() < deadline:
            time.sleep(0.01)
        self.assertEqual(hub.poll(session)["commands"], [])

        # A late result is accepted only to resolve uncertainty and release the
        # barrier.  It is never repurposed as evidence for the timed-out caller.
        accepted = hub.complete(session, [{
            "id": first_command["id"], "ok": True, "result": {"applied": True}, "context": "edit",
        }])
        self.assertEqual(accepted["accepted"], 1)
        self.assertEqual(hub.status()["uncertainCommands"], 0)

        second_command = hub.poll(session)["commands"][0]
        hub.complete(session, [{
            "id": second_command["id"], "ok": True, "result": {"applied": True}, "context": "edit",
        }])
        second.join(timeout=3)
        self.assertFalse(second.is_alive())
        self.assertTrue(second_outcome["response"].ok)

    def test_authentication_protects_agent_and_every_plugin_endpoint(self) -> None:
        """A token cannot leave hello/poll/result/event as an unauthenticated back door."""

        token = "test-token-that-is-longer-than-thirty-two-bytes-123456"
        hub = BridgeHub(token=token, poll_hold_seconds=0.03)
        server = serve(hub, host="127.0.0.1", port=0)
        port = server.server_address[1]
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        base = f"http://127.0.0.1:{port}"

        def expect_unauthorized(path: str, *, method: str = "POST") -> None:
            data = json.dumps({}).encode("utf-8") if method == "POST" else None
            request = urllib.request.Request(
                base + path,
                data=data,
                headers={"Content-Type": "application/json"},
                method=method,
            )
            with self.assertRaises(urllib.error.HTTPError) as caught:
                urllib.request.urlopen(request, timeout=2)
            self.assertEqual(caught.exception.code, 401)

        try:
            expect_unauthorized("/health", method="GET")
            for endpoint in ("/bridge/hello", "/bridge/poll", "/bridge/result", "/bridge/event", "/rpc"):
                expect_unauthorized(endpoint)

            plugin = PluginSimulator(
                base,
                {"bridge.ping": lambda _params: {"authenticated": True}},
                token=token,
            )
            plugin.start()
            try:
                bridge = StudioBridge(base, token=token)
                bridge.wait_for_plugin(timeout=3)
                self.assertTrue(bridge.health()["ok"])
                self.assertTrue(bridge.status()["authenticationRequired"])
                self.assertTrue(bridge.call("bridge.ping", timeout=3)["authenticated"])
            finally:
                plugin.stop()
        finally:
            server.shutdown()
            server.server_close()
            thread.join(timeout=3)


if __name__ == "__main__":
    unittest.main()
