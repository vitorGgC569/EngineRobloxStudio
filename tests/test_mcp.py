"""MCP in both directions.

Server side: an agent that connects gets a typed, validated, provenance-stamped
surface, and a handler that fails says so rather than returning nothing.

Client side: the federation rule is the thing under test. Roblox's Studio MCP
server has privileges this bridge cannot have -- synthesised input above all --
and consuming it is only safe while nothing it returns can pass as our own
measurement.
"""

from __future__ import annotations

import io
import json
import queue
import threading
import time
import unittest
from pathlib import Path
from unittest.mock import patch

from rqe.mcp import protocol
from rqe.mcp.client import (
    ADOPTED_TOOLS,
    CircuitBreaker,
    FEDERATED_SOURCE,
    McpClientError,
    StdioPeer,
    StudioMcpClient,
)
from rqe.mcp.server import EngineMcpServer, Tool, ToolError
from rqe.mcp.tools import build_server


REPO = Path(__file__).resolve().parents[1]


# ---------------------------------------------------------------- protocol


class TestProtocol(unittest.TestCase):
    def test_a_message_is_one_line(self):
        encoded = protocol.encode({"jsonrpc": "2.0", "id": 1, "result": {}})
        self.assertTrue(encoded.endswith(b"\n"))
        self.assertEqual(encoded.count(b"\n"), 1)

    def test_a_wrong_jsonrpc_version_is_refused(self):
        with self.assertRaises(protocol.ProtocolError):
            protocol.decode('{"jsonrpc":"1.0","id":1,"result":{}}')

    def test_a_response_without_result_or_error_is_refused(self):
        with self.assertRaises(protocol.ProtocolError):
            protocol.parse_response({"jsonrpc": "2.0", "id": 1})

    def test_a_request_without_an_id_is_a_notification(self):
        request = protocol.parse_request({"jsonrpc": "2.0", "method": "x"})
        self.assertTrue(request.is_notification)


# ------------------------------------------------------------------ server


def _drive(server: EngineMcpServer, messages: list[dict]) -> list[dict]:
    payload = b"".join(protocol.encode(item) for item in messages)
    sink = io.BytesIO()
    server.serve(io.BytesIO(payload), sink)
    return [json.loads(line) for line in sink.getvalue().splitlines() if line.strip()]


class TestEngineServer(unittest.TestCase):
    def setUp(self) -> None:
        self.server = build_server(REPO)

    def test_initialize_reports_the_protocol_and_server_identity(self):
        replies = _drive(self.server, [
            {"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {}},
        ])
        self.assertEqual(replies[0]["result"]["serverInfo"]["name"], "rqe-engine")
        self.assertEqual(replies[0]["result"]["protocolVersion"], protocol.PROTOCOL_VERSION)

    def test_notifications_get_no_reply(self):
        replies = _drive(self.server, [
            {"jsonrpc": "2.0", "method": "notifications/initialized"},
        ])
        self.assertEqual(replies, [])

    def test_every_tool_declares_a_schema(self):
        replies = _drive(self.server, [{"jsonrpc": "2.0", "id": 1, "method": "tools/list"}])
        tools = replies[0]["result"]["tools"]
        self.assertGreaterEqual(len(tools), 6)
        for tool in tools:
            self.assertIn("inputSchema", tool)
            self.assertEqual(tool["inputSchema"]["type"], "object")
            self.assertTrue(tool["description"])

    def test_the_producer_tool_exposes_honest_profiles_and_immutable_identity(self):
        reply = _drive(
            self.server,
            [{"jsonrpc": "2.0", "id": 1, "method": "tools/list"}],
        )[0]
        producer = next(
            item for item in reply["result"]["tools"] if item["name"] == "producer_run"
        )
        properties = producer["inputSchema"]["properties"]
        self.assertEqual(properties["profile"]["enum"], ["full", "static-no-geometry"])
        self.assertIn("pattern", properties["runId"])
        self.assertIn("immutable", producer["description"])

    def test_tools_are_listed_in_a_stable_order(self):
        """An agent diffing a tool list should see changes, not reshuffles."""

        names = [
            tool["name"]
            for tool in _drive(self.server, [{"jsonrpc": "2.0", "id": 1, "method": "tools/list"}])[0]["result"]["tools"]
        ]
        self.assertEqual(names, sorted(names))

    def test_a_result_carries_provenance(self):
        replies = _drive(self.server, [{
            "jsonrpc": "2.0", "id": 1, "method": "tools/call",
            "params": {"name": "engine_capabilities", "arguments": {}},
        }])
        body = replies[0]["result"]["structuredContent"]
        self.assertEqual(body["source"], "rqe-engine")
        self.assertEqual(body["tool"], "engine_capabilities")
        self.assertIn("producedAt", body)
        self.assertFalse(replies[0]["result"]["isError"])

    def test_arguments_are_validated_against_the_declared_schema(self):
        replies = _drive(self.server, [{
            "jsonrpc": "2.0", "id": 1, "method": "tools/call",
            "params": {"name": "tokens_inspect", "arguments": {"tokenSet": 5}},
        }])
        self.assertEqual(replies[0]["error"]["code"], protocol.INVALID_PARAMS)

    def test_an_unknown_tool_lists_the_available_ones(self):
        replies = _drive(self.server, [{
            "jsonrpc": "2.0", "id": 1, "method": "tools/call",
            "params": {"name": "nope", "arguments": {}},
        }])
        self.assertIn("available", replies[0]["error"]["data"])

    def test_a_failing_handler_reports_isError_rather_than_an_empty_result(self):
        """Absence of an answer is never an answer."""

        server = EngineMcpServer(root=REPO)

        def explode(_):
            raise ToolError("deliberate")

        server.register(Tool("boom", "always fails", {"type": "object", "properties": {}}, explode))
        replies = _drive(server, [{
            "jsonrpc": "2.0", "id": 1, "method": "tools/call",
            "params": {"name": "boom", "arguments": {}},
        }])
        self.assertTrue(replies[0]["result"]["isError"])
        self.assertIn("deliberate", replies[0]["result"]["structuredContent"]["error"])

    def test_an_unexpected_handler_exception_does_not_kill_the_server(self):
        server = EngineMcpServer(root=REPO)

        def explode(_):
            raise ZeroDivisionError("oops")

        server.register(Tool("boom", "bug", {"type": "object", "properties": {}}, explode))
        replies = _drive(server, [
            {"jsonrpc": "2.0", "id": 1, "method": "tools/call",
             "params": {"name": "boom", "arguments": {}}},
            {"jsonrpc": "2.0", "id": 2, "method": "ping"},
        ])
        self.assertTrue(replies[0]["result"]["isError"])
        self.assertNotIn("oops", json.dumps(replies[0]))
        self.assertNotIn("Traceback", json.dumps(replies[0]))
        self.assertEqual(replies[1]["id"], 2)

    def test_an_oversized_stdio_frame_is_rejected_and_the_next_frame_survives(self):
        from rqe.mcp.server import MAX_MCP_REQUEST_BYTES

        oversized = b"{" + (b"x" * MAX_MCP_REQUEST_BYTES) + b"}\n"
        valid = protocol.encode({"jsonrpc": "2.0", "id": 7, "method": "ping"})
        sink = io.BytesIO()
        EngineMcpServer(root=REPO).serve(io.BytesIO(oversized + valid), sink)
        replies = [json.loads(line) for line in sink.getvalue().splitlines()]
        self.assertEqual(replies[0]["error"]["code"], protocol.INVALID_REQUEST)
        self.assertEqual(replies[1]["id"], 7)

    def test_a_malformed_line_produces_a_parse_error_not_a_hang(self):
        sink = io.BytesIO()
        EngineMcpServer(root=REPO).serve(io.BytesIO(b"not json\n"), sink)
        reply = json.loads(sink.getvalue().splitlines()[0])
        self.assertEqual(reply["error"]["code"], protocol.PARSE_ERROR)

    def test_studio_is_reached_through_one_validated_entry_point(self):
        """Fifty-seven generated descriptors would be a second copy of the
        manifest that drifts. One `bridge_call` keeps the manifest sovereign."""

        names = {
            tool["name"]
            for tool in _drive(self.server, [{"jsonrpc": "2.0", "id": 1, "method": "tools/list"}])[0]["result"]["tools"]
        }
        self.assertIn("bridge_call", names)
        self.assertIn("bridge_lease", names)
        for leaked in ("instance_create", "world_raycast", "actor_spawn", "dm_find"):
            self.assertNotIn(leaked, names)

    def test_a_server_can_be_built_without_the_live_surface(self):
        from rqe.mcp.tools import build_server as build

        offline = build(REPO, include_bridge=False)
        self.assertNotIn("bridge_call", offline.tools)
        self.assertIn("tokens_inspect", offline.tools)

    def test_agent_tools_never_accept_a_credential_file_path(self):
        descriptors = {
            tool["name"]: tool
            for tool in _drive(
                self.server,
                [{"jsonrpc": "2.0", "id": 1, "method": "tools/list"}],
            )[0]["result"]["tools"]
        }
        for name in ("sourcing_publish", "sourcing_operation", "place_publish"):
            properties = descriptors[name]["inputSchema"].get("properties", {})
            self.assertNotIn("keyPath", properties)


class TestEngineToolsDoRealWork(unittest.TestCase):
    def setUp(self) -> None:
        self.server = build_server(REPO)

    def _call(self, name: str, arguments: dict) -> dict:
        replies = _drive(self.server, [{
            "jsonrpc": "2.0", "id": 1, "method": "tools/call",
            "params": {"name": name, "arguments": arguments},
        }])
        return replies[0]["result"]

    def test_tokens_inspect_returns_the_real_projection(self):
        result = self._call("tokens_inspect", {})
        data = result["structuredContent"]["data"]
        self.assertEqual(data["tokenSetId"], "brickfarm")
        self.assertIn("building", data["derivedThresholds"]["objectScale"])

    def test_tokens_conformance_reports_the_real_divergence(self):
        result = self._call("tokens_conformance", {
            "visualSpec": "contracts/visual/miners-ridge.visual-quality.v1.json",
        })
        data = result["structuredContent"]["data"]
        self.assertFalse(data["conforms"])

    def test_sdk_run_executes_luau(self):
        result = self._call("sdk_run", {
            "body": 'local Tokens = Require("Tokens") print(Tokens ~= nil)',
        })
        self.assertTrue(result["structuredContent"]["data"]["ok"])

    def test_pacing_simulate_runs_the_shipped_module(self):
        """The numbers an agent reasons about come from the code the game runs,
        not from a Python reimplementation of it."""

        result = self._call("pacing_simulate", {
            "tierCosts": [100, 300, 40000],
            "baseIncomePerSecond": 5,
            "incomeMultiplier": 1.5,
        })
        data = result["structuredContent"]["data"]
        self.assertEqual(data["worstAtTier"], "t3")
        self.assertTrue(data["problems"])

    def test_luau_compile_reports_a_clean_tree(self):
        result = self._call("luau_compile", {})
        data = result["structuredContent"]["data"]
        self.assertTrue(data["clean"], data["failures"])
        self.assertGreater(data["sources"], 30)

    def test_place_publish_refuses_paths_outside_the_workspace(self):
        result = self._call("place_publish", {
            "universeId": "1",
            "placeId": "2",
            "placeFile": "../outside.rbxlx",
        })
        self.assertTrue(result["isError"])
        self.assertIn("escapes", result["structuredContent"]["error"])

    def test_sourcing_adopt_needs_an_operator_approved_import_root(self):
        with patch.dict("os.environ", {"RQE_IMPORT_ROOTS": ""}):
            result = self._call("sourcing_adopt", {
                "path": str(REPO.parent),
                "source": "manual",
                "pack": "outside",
                "kind": "audio",
                "licence": "CC0",
            })
        self.assertTrue(result["isError"])
        self.assertIn("outside the workspace", result["structuredContent"]["error"])


# ------------------------------------------------------------------ client


class FakePeer:
    """A scripted MCP server on the other end of a pipe."""

    def __init__(self, tools=None, tool_result=None, *, raise_on_call=False):
        self.tools = tools if tools is not None else [
            {"name": name, "description": reason} for name, reason in ADOPTED_TOOLS.items()
        ]
        self.tool_result = tool_result or {
            "content": [{"type": "text", "text": "done"}],
            "structuredContent": {"clicked": True},
        }
        self.raise_on_call = raise_on_call
        self.calls: list[tuple[str, dict]] = []

    def to_streams(self):
        return _PipePair(self)


class _PipePair:
    """Turns a FakePeer into the readline/write interface StdioPeer expects."""

    def __init__(self, peer: FakePeer) -> None:
        self.peer = peer
        self._pending: list[bytes] = []

    # -- written to by StdioPeer
    def write(self, payload: bytes) -> None:
        document = protocol.decode(payload)
        method = document.get("method")
        identifier = document.get("id")
        if identifier is None:
            return
        if method == "initialize":
            result = {"serverInfo": {"name": "roblox-studio", "version": "1"}}
        elif method == "tools/list":
            result = {"tools": self.peer.tools}
        elif method == "tools/call":
            params = document.get("params", {})
            self.peer.calls.append((params.get("name"), params.get("arguments", {})))
            if self.peer.raise_on_call:
                self._pending.append(protocol.encode({
                    "jsonrpc": "2.0", "id": identifier,
                    "error": {"code": -32603, "message": "studio is not running"},
                }))
                return
            result = self.peer.tool_result
        else:
            result = {}
        self._pending.append(protocol.encode({"jsonrpc": "2.0", "id": identifier, "result": result}))

    def flush(self) -> None:
        return None

    # -- read from by StdioPeer
    def readline(self) -> bytes:
        return self._pending.pop(0) if self._pending else b""


def _client(peer: FakePeer) -> StudioMcpClient:
    pipe = peer.to_streams()
    return StudioMcpClient(StdioPeer(pipe, pipe))


class TestFederation(unittest.TestCase):
    def test_initialize_and_list_tools(self):
        peer = FakePeer()
        client = _client(peer)
        info = client.initialize()
        self.assertEqual(info["serverInfo"]["name"], "roblox-studio")
        self.assertGreaterEqual(len(client.tools()), 6)

    def test_the_input_tools_we_cannot_synthesise_are_adopted(self):
        """VirtualInputManager is refused in a LocalScript and in a plugin. This
        is the capability that stops GUI requirements being unmeasurable."""

        self.assertIn("user_mouse_input", ADOPTED_TOOLS)
        self.assertIn("user_keyboard_input", ADOPTED_TOOLS)
        descriptors = {item.name: item for item in _client(FakePeer()).tools()}
        self.assertTrue(descriptors["user_mouse_input"].adopted)

    def test_coverage_names_adopted_tools_the_peer_does_not_offer(self):
        peer = FakePeer(tools=[{"name": "run_code"}])
        client = _client(peer)
        coverage = client.coverage()
        self.assertFalse(coverage["complete"])
        self.assertIn("user_mouse_input", coverage["adoptedMissing"])

    def test_a_result_is_stamped_with_its_foreign_source(self):
        """Nothing from a peer may be indistinguishable from our own measurement."""

        client = _client(FakePeer())
        result = client.call_tool("user_mouse_input", {"x": 10}, run_id="run-1", build_hash="abc")
        detail = result.to_evidence_detail()
        self.assertEqual(detail["source"], FEDERATED_SOURCE)
        self.assertEqual(detail["runId"], "run-1")
        self.assertEqual(detail["buildHash"], "abc")
        self.assertTrue(detail["conclusive"])

    def test_prose_without_structure_is_inadmissible_as_a_measurement(self):
        """A tool that ran is not a tool that answered."""

        peer = FakePeer(tool_result={"content": [{"type": "text", "text": "probably fine"}]})
        result = _client(peer).call_tool("search_asset", {"query": "tree"})
        self.assertTrue(result.ok)
        self.assertFalse(result.conclusive)

    def test_a_tool_that_reports_isError_is_not_treated_as_success(self):
        """MCP signals a failed tool with isError, not a JSON-RPC error."""

        peer = FakePeer(tool_result={
            "content": [{"type": "text", "text": "no place open"}],
            "isError": True,
        })
        result = _client(peer).call_tool("insert_asset", {})
        self.assertFalse(result.ok)
        self.assertIn("no place open", result.error or "")

    def test_a_transport_level_error_is_captured_not_raised(self):
        result = _client(FakePeer(raise_on_call=True)).call_tool("run_code", {"code": "x"})
        self.assertFalse(result.ok)
        self.assertIn("studio is not running", result.error or "")

    def test_a_closed_stream_is_reported_rather_than_hanging(self):
        class Dead:
            def write(self, payload):
                return None

            def flush(self):
                return None

            def readline(self):
                return b""

        with self.assertRaises(McpClientError):
            StdioPeer(Dead(), Dead()).call("tools/list")

    def test_unframed_output_on_the_pipe_fails_loudly(self):
        """A subprocess writing a stack trace to stdout has broken the channel;
        skipping the line would turn that into a hang."""

        class Noisy:
            def __init__(self):
                self.sent = False

            def write(self, payload):
                return None

            def flush(self):
                return None

            def readline(self):
                if not self.sent:
                    self.sent = True
                    return b"thread 'main' panicked\n"
                return b""

        noisy = Noisy()
        with self.assertRaises(McpClientError) as caught:
            StdioPeer(noisy, noisy).call("tools/list")
        self.assertIn("non-JSON-RPC", str(caught.exception))

    def test_stdio_peer_enforces_a_real_deadline(self):
        release = threading.Event()

        class Blocking:
            def write(self, payload):
                return None

            def flush(self):
                return None

            def readline(self, size=-1):
                release.wait(2)
                return b""

        stream = Blocking()
        peer = StdioPeer(stream, stream, on_close=release.set)
        started = time.monotonic()
        try:
            with self.assertRaises(McpClientError) as caught:
                peer.call("tools/list", timeout=0.05)
            self.assertIn("timed out", str(caught.exception))
            self.assertLess(time.monotonic() - started, 0.5)
        finally:
            peer.close()

    def test_dedicated_reader_correlates_concurrent_out_of_order_responses(self):
        class Multiplexed:
            def __init__(self):
                self.requests: list[dict] = []
                self.responses: queue.Queue[bytes] = queue.Queue()
                self.lock = threading.Lock()

            def write(self, payload):
                request = protocol.decode(payload)
                with self.lock:
                    self.requests.append(request)
                    if len(self.requests) == 2:
                        for item in reversed(self.requests):
                            self.responses.put(protocol.encode({
                                "jsonrpc": "2.0",
                                "id": item["id"],
                                "result": {"method": item["method"]},
                            }))

            def flush(self):
                return None

            def readline(self, size=-1):
                return self.responses.get(timeout=2)

        stream = Multiplexed()
        peer = StdioPeer(stream, stream)
        answers: dict[str, str] = {}

        def invoke(method: str) -> None:
            answers[method] = peer.call(method, timeout=2).result["method"]

        threads = [threading.Thread(target=invoke, args=(name,)) for name in ("first", "second")]
        for thread in threads:
            thread.start()
        for thread in threads:
            thread.join(timeout=3)
            self.assertFalse(thread.is_alive())
        self.assertEqual(answers, {"first": "first", "second": "second"})

    def test_circuit_breaker_allows_only_one_half_open_probe(self):
        now = [0.0]
        breaker = CircuitBreaker(threshold=1, cooldown_seconds=10, clock=lambda: now[0])
        self.assertTrue(breaker.record_failure())
        now[0] = 11.0
        decisions: list[bool] = []
        barrier = threading.Barrier(8)

        def ask() -> None:
            barrier.wait()
            decisions.append(breaker.allow()[0])

        threads = [threading.Thread(target=ask) for _ in range(8)]
        for thread in threads:
            thread.start()
        for thread in threads:
            thread.join(timeout=2)
        self.assertEqual(decisions.count(True), 1)
        self.assertTrue(breaker.state()["probeInFlight"])


class TestBridgeTools(unittest.TestCase):
    """The live-Studio surface, exercised without a live Studio.

    No hub is running during tests, which is the point: an unreachable bridge
    must produce a named refusal, never an empty success.
    """

    def setUp(self) -> None:
        self.server = build_server(REPO)

    def _call(self, name: str, arguments: dict) -> dict:
        replies = _drive(self.server, [{
            "jsonrpc": "2.0", "id": 1, "method": "tools/call",
            "params": {"name": name, "arguments": arguments},
        }])
        return replies[0]["result"]

    def test_an_unreachable_hub_reports_reachable_false_rather_than_failing(self):
        """'The hub is down' is an answer an agent can act on."""

        result = self._call("bridge_status", {"hub": "http://127.0.0.1:9"})
        self.assertFalse(result["isError"])
        self.assertFalse(result["structuredContent"]["data"]["reachable"])

    def test_the_command_surface_is_grouped_into_families(self):
        data = self._call("bridge_commands", {})["structuredContent"]["data"]
        self.assertIn("instance", data["families"])
        self.assertIn("world", data["families"])
        self.assertIn("actor", data["families"])
        self.assertGreaterEqual(data["commandCount"], 57)

    def test_every_listed_command_declares_its_effect_and_idempotency(self):
        data = self._call("bridge_commands", {})["structuredContent"]["data"]
        for family in data["families"].values():
            for command in family:
                self.assertIn(command["effect"], {"read", "mutation", "context-transition", "transient", "arbitrary"})
                self.assertIn(command["idempotency"], {"safe-retry", "at-most-once", "naturally-idempotent"})
                self.assertEqual(set(command["selector"]), {"session", "build", "player"})

    def test_an_unknown_family_names_the_real_ones(self):
        result = self._call("bridge_commands", {"family": "nope"})
        self.assertTrue(result["isError"])
        self.assertIn("instance", result["structuredContent"]["error"])

    def test_parameters_are_validated_against_the_manifest_before_dispatch(self):
        """A bad call must fail locally, not after a network round trip into a
        live DataModel."""

        result = self._call("bridge_call", {"method": "instance.create", "params": {}})
        self.assertTrue(result["isError"])
        self.assertIn("invalid", result["structuredContent"]["error"])

    def test_an_unknown_method_is_refused(self):
        result = self._call("bridge_call", {"method": "instance.explode", "params": {}})
        self.assertTrue(result["isError"])

    def test_an_unsupported_command_is_not_dispatched(self):
        """`client.gui_click` is declared unsupported because
        VirtualInputManager refuses us; federation is the route, not this one."""

        result = self._call("bridge_call", {"method": "client.gui_click", "params": {"path": "x"}})
        self.assertTrue(result["isError"])
        self.assertIn("unsupported", result["structuredContent"]["error"])

    def test_arbitrary_bridge_execution_requires_operator_capability(self):
        with patch.dict("os.environ", {"RQE_MCP_ALLOW_ARBITRARY_CODE": ""}):
            result = self._call(
                "bridge_call",
                {"method": "bridge.exec", "params": {"source": "return true"}},
            )
        self.assertTrue(result["isError"])
        self.assertIn("operator", result["structuredContent"]["error"])
        self.assertIn("RQE_MCP_ALLOW_ARBITRARY_CODE", result["structuredContent"]["error"])

    def test_programming_run_escape_hatch_uses_the_same_capability_gate(self):
        with patch.dict("os.environ", {"RQE_MCP_ALLOW_ARBITRARY_CODE": ""}):
            result = self._call("run", {"source": "return true"})
        self.assertTrue(result["isError"])
        self.assertIn("RQE_MCP_ALLOW_ARBITRARY_CODE", result["structuredContent"]["error"])

    def test_a_dead_hub_produces_an_error_not_an_empty_result(self):
        result = self._call("bridge_call", {
            "method": "bridge.ping", "params": {}, "hub": "http://127.0.0.1:9",
            "timeoutSeconds": 1,
        })
        self.assertTrue(result["isError"])

    def test_lease_lifecycle_is_exposed_and_refuses_incomplete_identity(self):
        result = self._call("bridge_lease", {"operation": "acquire"})
        self.assertTrue(result["isError"])
        self.assertIn("runId", result["structuredContent"]["error"])


class TestInstancePrimitives(unittest.TestCase):
    """The family that removes the need for arbitrary Luau to build a world."""

    def setUp(self) -> None:
        from rqe.hub.commands import load_default_registry

        self.registry = load_default_registry(verify_dispatcher=False)

    def test_the_mutation_primitives_exist(self):
        for method in ("instance.create", "instance.update", "instance.delete", "instance.clone"):
            self.assertIn(method, self.registry.methods())

    def test_every_mutation_is_at_most_once(self):
        """Creating an instance twice is not the same as creating it once."""

        for method in ("instance.create", "instance.update", "instance.delete", "instance.clone"):
            spec = self.registry.require(method)
            self.assertEqual(spec.effect, "mutation", method)
            self.assertEqual(spec.idempotency, "at-most-once", method)

    def test_read_accessors_are_safe_to_retry(self):
        for method in ("instance.children", "instance.descendants", "instance.tags", "instance.attributes"):
            spec = self.registry.require(method)
            self.assertEqual(spec.effect, "read", method)
            self.assertEqual(spec.idempotency, "safe-retry", method)

    def test_create_requires_a_class_name(self):
        from rqe.hub.commands import CommandValidationError

        spec = self.registry.require("instance.create")
        with self.assertRaises(CommandValidationError):
            spec.validate_params({})
        spec.validate_params({"className": "Part"})

    def test_batch_size_is_bounded_in_the_schema(self):
        """An agent that miscomputes a loop bound should get a refusal, not a
        place with 400,000 parts in it."""

        from rqe.hub.commands import CommandValidationError

        spec = self.registry.require("instance.create")
        with self.assertRaises(CommandValidationError):
            spec.validate_params({"className": "Part", "count": 100000})

    def test_descendants_declares_a_truncation_flag(self):
        """A truncated answer that does not say so is how a count gets quoted as
        if it were complete."""

        spec = self.registry.require("instance.descendants")
        self.assertIn("truncated", spec.result_schema["required"])


if __name__ == "__main__":
    unittest.main()
