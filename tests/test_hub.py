"""Transport tests for the Studio Bridge hub.

These run a real HTTP server on a real socket with a real plugin peer, so a pass
here means the handshake, long-poll, correlation, timeout and error paths work.
It does *not* mean Studio works: the peer is a simulator and is labeled as such.
"""

from __future__ import annotations

import http.client
import os
import subprocess
import tempfile
import threading
import time
import unittest
import json
import urllib.error
import urllib.request
from pathlib import Path
from typing import Any
from unittest.mock import Mock, patch

from rqe.hub import lifecycle
from rqe.hub.auth import BridgeAuthError, derive_role_token
from rqe.hub.client import PluginSimulator, StudioBridge
from rqe.hub.protocol import PROTOCOL_VERSION, BridgeError, ErrorCode
from rqe.hub.server import MAX_HEADER_BYTES, MAX_REQUEST_BODY_BYTES, BridgeHub, serve


class HubTestCase(unittest.TestCase):
    def setUp(self) -> None:
        self.hub = BridgeHub(
            poll_hold_seconds=1.0,
            allow_unauthenticated=True,
            enforce_manifest_leases=False,
        )
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
            "installationId": f"test-installation-{client_id}",
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

    def test_short_operation_lease_scope_pins_fences_and_releases(self) -> None:
        self.start_plugin({
            "bridge.ping": lambda _params: {"pong": True},
            "bridge.exec": lambda _params: {"returned": {"built": True}},
        })
        executor = StudioBridge(self.base_url, allow_arbitrary=True)
        with executor.lease_scope(agent_id="test-builder", context="edit", ttl_seconds=5) as lease:
            self.assertEqual(lease["session"], executor.pinned_session)
            result = executor.call(
                "bridge.exec",
                {"source": "return { built = true }"},
                timeout=3,
            )
            self.assertTrue(result["returned"]["built"])
            self.assertEqual(len(self.hub.status()["leases"]), 1)
        self.assertIsNone(executor.pinned_session)
        self.assertEqual(self.hub.status()["leases"], [])

    def test_short_operation_lease_scope_releases_after_body_failure(self) -> None:
        self.start_plugin({"bridge.ping": lambda _params: {"pong": True}})
        with self.assertRaisesRegex(RuntimeError, "body failed"):
            with self.bridge.lease_scope(agent_id="test-builder", context="edit", ttl_seconds=5):
                raise RuntimeError("body failed")
        self.assertEqual(self.hub.status()["leases"], [])

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

    def test_event_transport_owns_session_and_timestamp_envelope(self) -> None:
        session = self.register_direct(self.hub, "event-owner")
        result = self.hub.push_events(session, [{
            "kind": "log",
            "session": "attacker-selected-session",
            "receivedAt": 9_999_999_999.0,
        }])
        self.assertEqual(result["accepted"], 1)
        event = self.hub.events()[0]
        self.assertEqual(event["session"], session)
        self.assertLess(event["receivedAt"], 9_999_999_999.0)

    def test_manifest_build_selector_requires_a_lease_by_default(self) -> None:
        hub = BridgeHub(allow_unauthenticated=True, poll_hold_seconds=0.01)
        session = self.register_direct(hub, "manifest-lease")
        with self.assertRaises(BridgeError) as caught:
            hub.call("run.start", {"settleSeconds": 0}, timeout=1, session_id=session)
        self.assertEqual(caught.exception.code, ErrorCode.LEASE_REQUIRED)
        self.assertEqual(caught.exception.details["manifestBuildSelector"], "required")

    def test_session_queue_has_a_hard_capacity(self) -> None:
        hub = BridgeHub(
            allow_unauthenticated=True,
            enforce_manifest_leases=False,
            poll_hold_seconds=0.01,
            max_queue_per_session=1,
        )
        session = self.register_direct(hub, "queue-capacity")
        errors: list[BridgeError] = []

        def queued_caller() -> None:
            try:
                hub.call("world.summary", {}, timeout=0.15, session_id=session)
            except BridgeError as exc:
                errors.append(exc)

        thread = threading.Thread(target=queued_caller)
        thread.start()
        deadline = time.monotonic() + 1
        while hub.status()["queuedCommands"] == 0 and time.monotonic() < deadline:
            time.sleep(0.005)
        with self.assertRaises(BridgeError) as caught:
            hub.call("world.summary", {}, timeout=1, session_id=session)
        self.assertEqual(caught.exception.code, ErrorCode.CAPACITY)
        thread.join(timeout=1)
        self.assertEqual([item.code for item in errors], [ErrorCode.TIMEOUT])

    def test_oversized_http_body_is_rejected_before_it_is_read(self) -> None:
        connection = http.client.HTTPConnection("127.0.0.1", self.port, timeout=2)
        try:
            connection.putrequest("POST", "/rpc")
            connection.putheader("Content-Type", "application/json")
            connection.putheader("Content-Length", str(MAX_REQUEST_BODY_BYTES + 1))
            connection.endheaders()
            response = connection.getresponse()
            self.assertEqual(response.status, 413)
            response.read()
        finally:
            connection.close()

    def test_oversized_http_headers_are_rejected(self) -> None:
        connection = http.client.HTTPConnection("127.0.0.1", self.port, timeout=2)
        try:
            connection.putrequest("POST", "/rpc")
            connection.putheader("Content-Type", "application/json")
            connection.putheader("Content-Length", "2")
            connection.putheader("X-Fill", "x" * MAX_HEADER_BYTES)
            connection.endheaders(b"{}")
            response = connection.getresponse()
            self.assertEqual(response.status, 431)
            response.read()
        finally:
            connection.close()

    def test_hub_defaults_to_machine_authentication_and_loopback_binding(self) -> None:
        root = "machine-root-token-with-at-least-thirty-two-bytes-123456"
        with patch("rqe.hub.server.load_bridge_token", return_value=root):
            hub = BridgeHub()
        self.assertTrue(hub.authentication_required)
        reader = derive_role_token(root, "reader")
        plugin = derive_role_token(root, "plugin")
        self.assertTrue(hub.authorized(f"Bearer {reader}", "reader"))
        self.assertFalse(hub.authorized(f"Bearer {reader}", "plugin"))
        self.assertTrue(hub.authorized(f"Bearer {plugin}", "plugin"))
        with self.assertRaises(BridgeAuthError):
            serve(hub, host="0.0.0.0", port=0)

    def test_rpc_capabilities_are_enforced_from_the_command_effect(self) -> None:
        root = "capability-root-token-with-at-least-thirty-two-bytes-123456"
        hub = BridgeHub(token=root, poll_hold_seconds=0.03, enforce_manifest_leases=False)
        server = serve(hub, host="127.0.0.1", port=0)
        port = server.server_address[1]
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()

        def rpc(role: str, method: str, params: dict[str, Any] | None = None) -> dict[str, Any]:
            request = urllib.request.Request(
                f"http://127.0.0.1:{port}/rpc",
                data=json.dumps({
                    "jsonrpc": "2.0",
                    "id": 1,
                    "method": method,
                    "params": params or {},
                }).encode("utf-8"),
                headers={
                    "Content-Type": "application/json",
                    "Authorization": f"Bearer {derive_role_token(root, role)}",
                },
                method="POST",
            )
            with urllib.request.urlopen(request, timeout=2) as response:
                return json.loads(response.read().decode("utf-8"))

        try:
            denied_write = rpc("reader", "run.stop")
            self.assertEqual(denied_write["error"]["data"]["code"], ErrorCode.UNAUTHORIZED)
            self.assertEqual(denied_write["error"]["data"]["requiredCapability"], "mutator")

            denied_read = rpc("mutator", "world.summary")
            self.assertEqual(denied_read["error"]["data"]["code"], ErrorCode.UNAUTHORIZED)
            self.assertEqual(denied_read["error"]["data"]["requiredCapability"], "reader")

            denied_exec = rpc("reader", "bridge.exec", {"source": "return true"})
            self.assertEqual(denied_exec["error"]["data"]["code"], ErrorCode.UNAUTHORIZED)
            self.assertEqual(denied_exec["error"]["data"]["requiredCapability"], "executor")

            admin_status = rpc("admin", "hub.status")
            self.assertEqual(admin_status["result"]["credentialModel"], "derived-capability-v2")
        finally:
            server.shutdown()
            server.server_close()
            thread.join(timeout=3)

    def test_live_client_identity_requires_the_previous_session_proof(self) -> None:
        root = "continuity-root-token-with-at-least-thirty-two-bytes-123456"
        hub = BridgeHub(token=root, poll_hold_seconds=0.03)
        payload = {
            "protocol": PROTOCOL_VERSION,
            "clientId": "stable-studio-client",
            "installationId": "installation-identity-0001",
            "pluginVersion": "test",
            "studioVersion": "test",
            "placeName": "Place",
            "placeId": 1,
            "context": "edit",
        }
        first = hub.register(payload)
        self.assertNotIn("sessionKey", hub.status()["sessions"][0])

        with self.assertRaises(BridgeError) as collision:
            hub.register(payload)
        self.assertEqual(collision.exception.code, ErrorCode.SESSION_CONFLICT)

        with self.assertRaises(BridgeError) as wrong_installation:
            hub.register({
                **payload,
                "installationId": "installation-identity-9999",
                "resumeSession": first["session"],
                "resumeKey": first["sessionKey"],
            })
        self.assertEqual(wrong_installation.exception.code, ErrorCode.SESSION_CONFLICT)

        second = hub.register({
            **payload,
            "context": "run",
            "resumeSession": first["session"],
            "resumeKey": first["sessionKey"],
        })
        self.assertNotEqual(first["session"], second["session"])
        with self.assertRaises(BridgeError) as stale:
            hub.require_session_proof(first["session"], first["sessionKey"])
        self.assertEqual(stale.exception.code, ErrorCode.UNAUTHORIZED)
        hub.require_session_proof(second["session"], second["sessionKey"])

    def test_plugin_endpoints_require_the_ephemeral_session_proof(self) -> None:
        token = "proof-root-token-with-at-least-thirty-two-bytes-123456"
        hub = BridgeHub(token=token, poll_hold_seconds=0.03)
        server = serve(hub, host="127.0.0.1", port=0)
        port = server.server_address[1]
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        plugin = PluginSimulator(
            f"http://127.0.0.1:{port}",
            {},
            token=token,
        )
        try:
            plugin.connect()
            with self.assertRaises(urllib.error.HTTPError) as denied:
                plugin._post("/bridge/event", {
                    "session": plugin.session,
                    "sessionKey": "wrong-session-proof",
                    "events": [],
                })
            self.assertEqual(denied.exception.code, 401)
            self.assertEqual(len(hub.status()["sessions"]), 1)
        finally:
            plugin.stop()
            server.shutdown()
            server.server_close()
            thread.join(timeout=3)

    def test_rate_limit_is_bounded_per_authenticated_capability(self) -> None:
        token = "rate-root-token-with-at-least-thirty-two-bytes-123456"
        hub = BridgeHub(
            token=token,
            poll_hold_seconds=0.03,
            rate_limit_per_second=0.01,
            rate_limit_burst=1,
        )
        server = serve(hub, host="127.0.0.1", port=0)
        port = server.server_address[1]
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        request = urllib.request.Request(
            f"http://127.0.0.1:{port}/health",
            headers={"Authorization": f"Bearer {derive_role_token(token, 'reader')}"},
        )
        try:
            with urllib.request.urlopen(request, timeout=2) as response:
                self.assertEqual(response.status, 200)
            with self.assertRaises(urllib.error.HTTPError) as limited:
                urllib.request.urlopen(request, timeout=2)
            self.assertEqual(limited.exception.code, 429)
            self.assertEqual(limited.exception.headers.get("Retry-After"), "100")
        finally:
            server.shutdown()
            server.server_close()
            thread.join(timeout=3)

    def test_unsupported_manifest_command_is_rejected_by_the_hub_itself(self) -> None:
        with self.assertRaises(BridgeError) as caught:
            self.hub.call("client.gui_click", {"path": "game.Players"}, timeout=1)
        self.assertEqual(caught.exception.code, ErrorCode.UNAVAILABLE)

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
        hub = BridgeHub(
            poll_hold_seconds=0.02,
            allow_unauthenticated=True,
            enforce_manifest_leases=False,
        )
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
        hub = BridgeHub(
            poll_hold_seconds=0.02,
            allow_unauthenticated=True,
            enforce_manifest_leases=False,
        )
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
        hub = BridgeHub(
            poll_hold_seconds=0.02,
            require_mutation_leases=True,
            allow_unauthenticated=True,
            enforce_manifest_leases=False,
        )
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

        hub = BridgeHub(
            poll_hold_seconds=0.03,
            allow_unauthenticated=True,
            enforce_manifest_leases=False,
        )
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

        hub = BridgeHub(
            poll_hold_seconds=0.03,
            allow_unauthenticated=True,
            enforce_manifest_leases=False,
        )
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

        def expect_unauthorized(
            path: str,
            *,
            method: str = "POST",
            credential: str | None = None,
        ) -> None:
            data = json.dumps({}).encode("utf-8") if method == "POST" else None
            headers = {"Content-Type": "application/json"}
            if credential:
                headers["Authorization"] = f"Bearer {credential}"
            request = urllib.request.Request(
                base + path,
                data=data,
                headers=headers,
                method=method,
            )
            with self.assertRaises(urllib.error.HTTPError) as caught:
                urllib.request.urlopen(request, timeout=2)
            self.assertEqual(caught.exception.code, 401)

        try:
            expect_unauthorized("/health", method="GET")
            for endpoint in ("/bridge/hello", "/bridge/poll", "/bridge/result", "/bridge/event", "/rpc"):
                expect_unauthorized(endpoint)
            expect_unauthorized("/rpc", credential=token)
            expect_unauthorized("/bridge/hello", credential=derive_role_token(token, "reader"))
            expect_unauthorized("/rpc", credential=derive_role_token(token, "plugin"))

            admin_attempt = urllib.request.Request(
                base + "/rpc",
                data=json.dumps({
                    "jsonrpc": "2.0",
                    "id": 99,
                    "method": "hub.drop_sessions",
                    "params": {"sessions": ["missing"]},
                }).encode("utf-8"),
                headers={
                    "Content-Type": "application/json",
                    "Authorization": f"Bearer {derive_role_token(token, 'reader')}",
                },
                method="POST",
            )
            with urllib.request.urlopen(admin_attempt, timeout=2) as response:
                denied_admin = json.loads(response.read().decode("utf-8"))
            self.assertEqual(denied_admin["error"]["data"]["code"], ErrorCode.UNAUTHORIZED)

            plugin = PluginSimulator(
                base,
                {
                    "bridge.ping": lambda _params: {"authenticated": True},
                    "bridge.exec": lambda _params: {"explicit": True},
                },
                token=token,
            )
            plugin.start()
            try:
                bridge = StudioBridge(base, token=token)
                bridge.wait_for_plugin(timeout=3)
                self.assertTrue(bridge.health()["ok"])
                self.assertTrue(bridge.status()["authenticationRequired"])
                self.assertEqual(bridge.status()["credentialModel"], "derived-capability-v2")
                self.assertTrue(bridge.call("bridge.ping", timeout=3)["authenticated"])
                with self.assertRaises(BridgeError) as denied:
                    bridge.call("bridge.exec", {"source": "return true"}, timeout=3)
                self.assertEqual(denied.exception.code, ErrorCode.UNAUTHORIZED)

                executor = StudioBridge(base, token=token, allow_arbitrary=True)
                lease = executor.acquire_lease(
                    run_id="auth-test",
                    agent_id="operator",
                    build_id="build-1",
                    session_id=plugin.session,
                )
                self.assertTrue(
                    executor.call(
                        "bridge.exec",
                        {"source": "return true"},
                        timeout=3,
                        lease=lease,
                    )["explicit"]
                )
                self.assertEqual(bridge.drop_sessions(["missing"]), [])
            finally:
                plugin.stop()
        finally:
            server.shutdown()
            server.server_close()
            thread.join(timeout=3)


class StudioPowerShellEnvironmentTests(unittest.TestCase):
    """Windows PowerShell 5.1 treats an inherited PSModulePath as complete.

    A parent pwsh session stores the variable as ``PSMODULEPATH`` and points it
    at PowerShell 7 modules. ``powershell.exe`` then exits before
    ``Get-AuthenticodeSignature`` can run, and Studio restart reports that no
    signed executable exists. ``os.environ.copy()`` is a plain dict, so a later
    assignment to ``PSModulePath`` does not replace ``PSMODULEPATH``. Both
    verifier launches have to pass one Windows PowerShell system module path.
    """

    _PWSH_MODULES = r"C:\Program Files\PowerShell\7\Modules"
    _SYSTEM_ROOT = r"C:\Windows"
    _WINDOWS_MODULES = _SYSTEM_ROOT + r"\System32\WindowsPowerShell\v1.0\Modules"

    def _patched_environment(self):
        inherited = self._PWSH_MODULES + ";" + self._WINDOWS_MODULES
        return patch.dict(
            os.environ,
            {
                "PSMODULEPATH": inherited,
                "SYSTEMROOT": self._SYSTEM_ROOT,
                "PATH": self._SYSTEM_ROOT + r"\System32",
            },
            clear=False,
        )

    def _module_paths(self, env: dict[str, str]) -> list[str]:
        return [value for key, value in env.items() if key.lower() == "psmodulepath"]

    def test_signature_verifier_drops_inherited_powershell7_module_path(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            target = Path(directory) / "RobloxStudioBeta.exe"
            target.write_bytes(b"MZ")
            captured: dict[str, Any] = {}

            def fake_run(command, **kwargs):
                captured["command"] = command
                captured["env"] = kwargs["env"]
                payload = json.dumps({
                    "status": "Valid",
                    "signer": "CN=Roblox Corporation, O=Roblox Corporation",
                    "version": "0.655.0.655",
                })
                return subprocess.CompletedProcess(command, 0, stdout=payload, stderr="")

            with (
                self._patched_environment(),
                patch.object(lifecycle.os, "name", "nt"),
                patch.object(lifecycle.subprocess, "run", side_effect=fake_run),
            ):
                metadata = lifecycle._studio_binary_metadata(target)

        self.assertIn("powershell.exe", captured["command"][0].lower())
        self.assertIn("-Command", captured["command"])
        self.assertEqual(self._module_paths(captured["env"]), [self._WINDOWS_MODULES])
        self.assertNotIn(self._PWSH_MODULES, "\n".join(self._module_paths(captured["env"])))
        self.assertEqual(captured["env"]["RQE_VERIFY_EXECUTABLE"], str(target.resolve()))
        self.assertEqual(metadata["signatureStatus"], "Valid")
        self.assertIn("Roblox Corporation", metadata["signer"])

    def test_process_identity_drops_inherited_powershell7_module_path(self) -> None:
        captured: dict[str, Any] = {}

        def fake_run(command, **kwargs):
            captured["command"] = command
            captured["env"] = kwargs["env"]
            payload = json.dumps({
                "pid": 4242,
                "path": r"C:\Roblox\RobloxStudioBeta.exe",
                "startedAt": "2026-01-01T00:00:00.0000000Z",
            })
            return subprocess.CompletedProcess(command, 0, stdout=payload, stderr="")

        with (
            self._patched_environment(),
            patch.object(lifecycle.os, "name", "nt"),
            patch.object(lifecycle.subprocess, "run", side_effect=fake_run),
        ):
            identity = lifecycle._process_identity(4242)

        self.assertIn("powershell.exe", captured["command"][0].lower())
        self.assertEqual(self._module_paths(captured["env"]), [self._WINDOWS_MODULES])
        self.assertEqual(captured["env"]["RQE_PROCESS_ID"], "4242")
        self.assertEqual(identity["pid"], 4242)
        self.assertEqual(identity["startedAt"], "2026-01-01T00:00:00.0000000Z")


class StudioRestartVerificationOrderTests(unittest.TestCase):
    """Verifier failures name the PowerShell output and happen before stop."""

    def _executable(self, directory: str) -> Path:
        target = Path(directory) / "RobloxStudioBeta.exe"
        target.write_bytes(b"MZ")
        return target

    def _run_verifier(self, completed: subprocess.CompletedProcess) -> RuntimeError:
        with tempfile.TemporaryDirectory() as directory:
            target = self._executable(directory)

            def fake_run(command, **kwargs):
                return completed

            with (
                patch.object(lifecycle.os, "name", "nt"),
                patch.object(lifecycle.subprocess, "run", side_effect=fake_run),
            ):
                with self.assertRaises(RuntimeError) as caught:
                    lifecycle._studio_binary_metadata(target)
        return caught.exception

    def test_nonzero_powershell_keeps_exit_code_and_stderr(self) -> None:
        error = self._run_verifier(subprocess.CompletedProcess(
            ["powershell.exe"],
            4,
            stdout="",
            stderr="Import-Module : PowerShell 7 modules cannot load",
        ))
        message = str(error)
        self.assertIn("exit=4", message)
        self.assertIn("Import-Module : PowerShell 7 modules cannot load", message)
        self.assertEqual(error.verifier["context"], "powershell-exit")
        self.assertEqual(error.verifier["exitCode"], 4)
        self.assertIn("PowerShell 7 modules", error.verifier["output"])

    def test_empty_stderr_keeps_stdout_slice(self) -> None:
        error = self._run_verifier(subprocess.CompletedProcess(
            ["powershell.exe"],
            3,
            stdout="Get-AuthenticodeSignature is not recognized",
            stderr="   ",
        ))
        self.assertIn("exit=3", str(error))
        self.assertIn("Get-AuthenticodeSignature is not recognized", error.verifier["output"])

    def test_stderr_slice_is_short(self) -> None:
        noise = "A" * 80
        stderr = noise + ("B" * 200) + "TAILMARKER" + ("C" * 1500)
        error = self._run_verifier(subprocess.CompletedProcess(
            ["powershell.exe"],
            9,
            stdout="",
            stderr=stderr,
        ))
        self.assertLess(len(error.verifier["output"]), 500)
        self.assertIn(noise, error.verifier["output"])
        self.assertNotIn("TAILMARKER", error.verifier["output"])
        self.assertIn("exit=9", str(error))

    def test_invalid_json_keeps_verifier_output(self) -> None:
        error = self._run_verifier(subprocess.CompletedProcess(
            ["powershell.exe"],
            0,
            stdout="WARNING: not-json from the signature verifier",
            stderr="",
        ))
        self.assertIn("not-json from the signature verifier", str(error))
        self.assertEqual(error.verifier["context"], "invalid-json")
        self.assertIn("not-json", error.verifier["output"])

    def test_bad_signature_keeps_verifier_output(self) -> None:
        payload = json.dumps({
            "status": "NotSigned",
            "signer": "CN=Other Publisher",
            "version": "1.2.3",
        })
        error = self._run_verifier(subprocess.CompletedProcess(
            ["powershell.exe"],
            0,
            stdout=payload,
            stderr="",
        ))
        self.assertIn("NotSigned", str(error))
        self.assertIn("Other Publisher", str(error))
        self.assertEqual(error.verifier["context"], "bad-signature")
        self.assertIn("NotSigned", error.verifier["output"])

    def test_restart_does_not_stop_studio_when_verification_fails(self) -> None:
        stopped: list[tuple[Any, ...]] = []

        def stop_studio(*args, **kwargs):
            stopped.append((args, kwargs))
            return {"stopped": True, "wasRunning": True}

        def fake_run(command, **kwargs):
            return subprocess.CompletedProcess(
                command,
                4,
                stdout="",
                stderr="Import-Module : pwsh modules cannot load",
            )

        with tempfile.TemporaryDirectory() as directory:
            versions = Path(directory) / "Roblox" / "Versions" / "version-test"
            versions.mkdir(parents=True)
            (versions / "RobloxStudioBeta.exe").write_bytes(b"MZ")
            with (
                patch.dict(os.environ, {"LOCALAPPDATA": directory}, clear=False),
                patch.object(lifecycle.shutil, "which", return_value=None),
                patch.object(lifecycle.os, "name", "nt"),
                patch.object(lifecycle, "ensure_hub", return_value={"alive": True, "started": False}),
                patch.object(lifecycle.subprocess, "run", side_effect=fake_run),
                patch.object(lifecycle, "stop_studio", side_effect=stop_studio),
                patch.object(lifecycle, "archive_recovery_files", side_effect=AssertionError("must not archive")),
                patch.object(lifecycle, "launch_studio", side_effect=AssertionError("must not launch")),
            ):
                result = lifecycle.restart_for_bridge("place.rbxlx", "archive", bridge=None)

        self.assertEqual(stopped, [])
        self.assertTrue(result["blocked"])
        self.assertEqual(result["handshake"], {"waited": False, "sessions": []})
        self.assertEqual(result["verifier"]["context"], "powershell-exit")
        self.assertEqual(result["verifier"]["exitCode"], 4)
        self.assertIn("pwsh modules cannot load", result["verifier"]["output"])
        self.assertIn("exit=4", result["reason"])
        self.assertIn("pwsh modules cannot load", result["reason"])
        self.assertNotIn("stop", result)

    def test_restart_treats_stubbed_executable_failure_as_blocked(self) -> None:
        stopped: list[int] = []

        def stop_studio(*args, **kwargs):
            stopped.append(1)
            return {"stopped": True, "wasRunning": True}

        def fail_executable():
            error = FileNotFoundError(
                "no valid Roblox-signed Studio executable was found "
                "(context=powershell-exit, exit=4, output=Import-Module)"
            )
            setattr(error, "verifier", {
                "context": "powershell-exit",
                "exitCode": 4,
                "output": "Import-Module",
            })
            raise error

        with (
            patch.object(lifecycle, "ensure_hub", return_value={"alive": True}),
            patch.object(lifecycle, "studio_executable", side_effect=fail_executable),
            patch.object(lifecycle, "stop_studio", side_effect=stop_studio),
            patch.object(lifecycle, "archive_recovery_files", side_effect=AssertionError("must not archive")),
            patch.object(lifecycle, "launch_studio", side_effect=AssertionError("must not launch")),
        ):
            result = lifecycle.restart_for_bridge("place.rbxlx", "archive", bridge=None)

        self.assertEqual(stopped, [])
        self.assertTrue(result["blocked"])
        self.assertEqual(result["handshake"]["sessions"], [])
        self.assertEqual(result["verifier"]["exitCode"], 4)
        self.assertEqual(result["verifier"]["context"], "powershell-exit")
        self.assertIn("Import-Module", result["verifier"]["output"])


class StudioColdLaunchCapabilityTests(unittest.TestCase):
    """A cold launch is ready only when the new session has the required methods."""

    _REQUIRED = (
        "test.start",
        "test.status",
        "test.finish",
        "studio.capture_background",
    )

    def _ensure(
        self,
        restarted: dict[str, Any],
        methods: list[str] | None,
    ) -> tuple[Mock, Mock, dict[str, Any]]:
        bridge = Mock()
        bridge.status.return_value = {"sessions": []}
        if methods is None:
            bridge.call.side_effect = AssertionError("capabilities must not be called")
        else:
            bridge.call.return_value = {"methods": methods}
        with (
            patch.object(lifecycle, "_owned_studio_processes", return_value=([], [])),
            patch(
                "rqe.hub.install.plugin_build_identity",
                return_value={"pluginVersion": "test", "pluginBuildId": "sha256:test"},
            ),
            patch.object(lifecycle, "restart_for_bridge", return_value=restarted) as restart,
        ):
            result = lifecycle.ensure_studio_session(
                "place.rbxlx",
                "archive",
                bridge,
                allow_cold_launch=True,
            )
        return bridge, restart, result

    def test_handshake_missing_a_method_is_not_ready(self) -> None:
        present = [method for method in self._REQUIRED if method != "test.start"]
        bridge, restart, result = self._ensure(
            {"handshake": {"sessions": [{"session": "sess-cold", "polls": 1}]}},
            present,
        )
        restart.assert_called_once()
        bridge.call.assert_called_once()
        self.assertEqual(bridge.call.call_args.args[0], "bridge.capabilities")
        self.assertEqual(bridge.pinned_session, "sess-cold")
        self.assertFalse(result["ready"])
        self.assertFalse(result["reused"])
        self.assertTrue(result["coldLaunched"])
        self.assertEqual(
            result["reason"],
            "connected plugin is missing native methods: test.start",
        )

    def test_handshake_with_every_required_method_is_ready(self) -> None:
        bridge, restart, result = self._ensure(
            {"handshake": {"sessions": [{"session": "sess-cold", "polls": 1}]}},
            list(self._REQUIRED),
        )
        restart.assert_called_once()
        bridge.call.assert_called_once()
        self.assertEqual(bridge.pinned_session, "sess-cold")
        self.assertTrue(result["ready"])
        self.assertFalse(result["reused"])
        self.assertTrue(result["coldLaunched"])
        self.assertNotIn("missing native methods", result.get("reason", ""))

    def test_handshake_without_a_session_does_not_ask_capabilities(self) -> None:
        bridge, _restart, result = self._ensure(
            {"handshake": {"waited": True, "sessions": []}},
            None,
        )
        bridge.call.assert_not_called()
        self.assertFalse(result["ready"])
        self.assertFalse(result["reused"])
        self.assertTrue(result["coldLaunched"])

    def test_blocked_restart_stays_blocked_and_not_ready(self) -> None:
        blocked = {
            "blocked": True,
            "reason": "could not verify Studio executable",
            "verifier": {"context": "powershell-exit", "exitCode": 4, "output": "nope"},
            "handshake": {"waited": False, "sessions": [{"session": "sess-cold"}]},
        }
        bridge, _restart, result = self._ensure(blocked, None)
        bridge.call.assert_not_called()
        self.assertIs(result, blocked)
        self.assertTrue(result["blocked"])
        self.assertNotEqual(result.get("ready"), True)
        self.assertEqual(result["reason"], "could not verify Studio executable")


class StudioLocalPlaceReuseTests(unittest.TestCase):
    """A local file is always named Game. The process receipt identifies it."""

    _METHODS = [
        "test.start",
        "test.status",
        "test.finish",
        "studio.capture_background",
    ]

    def _session(self, session_id: str, name: str, place_id: int = 0) -> dict[str, Any]:
        return {
            "session": session_id,
            "context": "edit",
            "polls": 4,
            "pluginVersion": "2.0.0",
            "pluginBuildId": "sha256:test",
            "place": {"name": name, "id": place_id},
        }

    def _ensure(self, directory: str, sessions: list[dict[str, Any]]) -> dict[str, Any]:
        place = (Path(directory) / "beaconmile.rbxlx").resolve()
        owned = [{
            "pid": 42,
            "place": str(place),
            "path": r"C:\Roblox\RobloxStudioBeta.exe",
            "startedAt": "2026-01-01T00:00:00.0000000Z",
        }]
        bridge = Mock()
        bridge.status.return_value = {"sessions": sessions}
        bridge.call.return_value = {"methods": list(self._METHODS)}
        with (
            patch.object(lifecycle, "_owned_studio_processes", return_value=(owned, [])),
            patch.object(lifecycle, "minimize_studio", return_value=0),
            patch.object(lifecycle, "restart_for_bridge", side_effect=AssertionError("must not cold launch")),
            patch(
                "rqe.hub.install.plugin_build_identity",
                return_value={"pluginVersion": "2.0.0", "pluginBuildId": "sha256:test"},
            ),
        ):
            return lifecycle.ensure_studio_session(
                place,
                Path(directory) / "archive",
                bridge,
                allow_cold_launch=False,
            )

    def test_one_local_game_session_reuses_the_owned_process(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            result = self._ensure(directory, [self._session("sess-local", "Game")])
        self.assertTrue(result["ready"])
        self.assertTrue(result["reused"])
        self.assertFalse(result["coldLaunched"])
        self.assertEqual(result["session"], "sess-local")

    def test_two_local_game_sessions_are_not_guessed(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            result = self._ensure(directory, [
                self._session("sess-a", "Game"),
                self._session("sess-b", "Game"),
            ])
        self.assertFalse(result["ready"])
        self.assertTrue(result["needsColdLaunch"])


if __name__ == "__main__":
    unittest.main()
