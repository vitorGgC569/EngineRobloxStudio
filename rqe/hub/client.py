"""Client side of the RQE Studio Bridge.

Two clients live here:

``StudioBridge``
    What agents, validators and the CLI use. It speaks JSON-RPC to the hub and
    raises :class:`BridgeError` instead of returning plausible-looking defaults,
    so a caller can never silently treat "Studio was not reachable" as "the
    measurement came back clean".

``PluginSimulator``
    A real HTTP client that performs the plugin half of the handshake. It exists
    so the hub can be tested end to end over a real socket without Studio. It is
    a test peer for the transport only -- it never fabricates DataModel data.
"""

from __future__ import annotations

import json
import threading
import time
import urllib.error
import urllib.request
from typing import Any, Callable

from .auth import BridgeAuthError, load_bridge_token
from .protocol import PROTOCOL_VERSION, BridgeError, ErrorCode, Response


class StudioBridge:
    """Agent-facing handle on a live Studio session."""

    def __init__(self, base_url: str = "http://127.0.0.1:8790", token: str | None = None, timeout: float = 20.0) -> None:
        self.base_url = base_url.rstrip("/")
        if token is None:
            try:
                token = load_bridge_token()
            except BridgeAuthError:
                # Test/development hubs may deliberately run without auth. The
                # production CLI creates the credential during plugin install.
                token = None
        self.token = token
        self.timeout = timeout
        self._request_id = 0
        #: When set, every call is routed to this session. Measurement sequences
        #: pin themselves: instance refs are session-scoped, so an unpinned
        #: sequence can compare a plot measured in the running game against one
        #: measured in the edit-mode place and never notice.
        self.pinned_session: str | None = None

    # ------------------------------------------------------------------ plumbing

    def _post(self, path: str, payload: dict[str, Any], timeout: float | None = None) -> Any:
        body = json.dumps(payload).encode("utf-8")
        headers = {"Content-Type": "application/json"}
        if self.token:
            headers["Authorization"] = f"Bearer {self.token}"
        request = urllib.request.Request(f"{self.base_url}{path}", data=body, headers=headers, method="POST")
        try:
            with urllib.request.urlopen(request, timeout=timeout or self.timeout) as response:
                return json.loads(response.read().decode("utf-8"))
        except urllib.error.HTTPError as exc:
            detail = exc.read().decode("utf-8", errors="replace")
            raise BridgeError(ErrorCode.EXEC, f"hub returned HTTP {exc.code} for {path}", {"body": detail[:500]}) from exc
        except (urllib.error.URLError, TimeoutError, ConnectionError) as exc:
            raise BridgeError(
                ErrorCode.DISCONNECTED,
                f"bridge hub is not reachable at {self.base_url}",
                {"hint": "start it with: python rqe.py studio serve", "cause": str(exc)},
            ) from exc

    def call(
        self,
        method: str,
        params: dict[str, Any] | None = None,
        timeout: float = 15.0,
        *,
        lease: dict[str, Any] | None = None,
    ) -> Any:
        """Run one command in Studio and return its result, or raise."""
        return self.call_response(method, params, timeout, lease=lease).unwrap()

    def pin_to_running(self, timeout: float = 30.0) -> str:
        """Pin every later call to the session running the game.

        Call this before a measurement sequence. Without it, consecutive reads
        can land on different DataModels and quietly mix two worlds.
        """
        response = self.call_response("bridge.ping", {"_context": "running"}, timeout=timeout)
        if not response.session:
            raise BridgeError(ErrorCode.PROTOCOL, "hub did not report which session answered")
        self.pinned_session = response.session
        return response.session

    def pin_to_any(self, timeout: float = 30.0) -> str:
        """Pin to whichever session answers, running or not.

        For work that is about the *place* rather than about a play session --
        photographing built geometry, reading the DataModel. The pin still
        matters: without one, consecutive calls can land on different Studio
        windows and quietly mix two places.
        """

        response = self.call_response("bridge.ping", {}, timeout=timeout)
        if not response.session:
            raise BridgeError(ErrorCode.PROTOCOL, "hub did not report which session answered")
        self.pinned_session = response.session
        return response.session

    def unpin(self) -> None:
        self.pinned_session = None

    def call_response(
        self,
        method: str,
        params: dict[str, Any] | None = None,
        timeout: float = 15.0,
        *,
        lease: dict[str, Any] | None = None,
    ) -> Response:
        """Like :meth:`call` but returns the full envelope including Studio context."""
        self._request_id += 1
        merged = {**(params or {}), "_timeout": timeout}
        if lease is not None:
            merged["_lease"] = lease
        if self.pinned_session and "_session" not in merged and "_context" not in merged:
            merged["_session"] = self.pinned_session
        payload = {
            "jsonrpc": "2.0",
            "id": self._request_id,
            "method": method,
            "params": merged,
        }
        envelope = self._post("/rpc", payload, timeout=timeout + 10)
        if "error" in envelope:
            error = envelope["error"]
            data = error.get("data") or {}
            raise BridgeError(str(data.get("code") or ErrorCode.EXEC), str(error.get("message")), data.get("details") or {})
        return Response(
            id=envelope["result"].get("id", ""),
            ok=bool(envelope["result"].get("ok")),
            result=envelope["result"].get("result"),
            error=envelope["result"].get("error"),
            elapsed_ms=float(envelope["result"].get("elapsedMs") or 0),
            context=str(envelope["result"].get("context") or "unknown"),
            place=str(envelope["result"].get("place") or ""),
            session=str(envelope["result"].get("session") or ""),
        )

    # -------------------------------------------------------------- hub queries

    def health(self) -> dict[str, Any]:
        headers = {"Authorization": f"Bearer {self.token}"} if self.token else {}
        request = urllib.request.Request(f"{self.base_url}/health", headers=headers)
        try:
            with urllib.request.urlopen(request, timeout=5) as response:
                return json.loads(response.read().decode("utf-8"))
        except (urllib.error.URLError, TimeoutError, ConnectionError) as exc:
            raise BridgeError(ErrorCode.DISCONNECTED, f"bridge hub is not reachable at {self.base_url}", {"cause": str(exc)}) from exc

    def status(self) -> dict[str, Any]:
        self._request_id += 1
        envelope = self._post("/rpc", {"jsonrpc": "2.0", "id": self._request_id, "method": "hub.status", "params": {}})
        return envelope.get("result", {})

    def drop_sessions(self, session_ids: list[str], reason: str = "studio terminated by the engine") -> list[str]:
        """Tell the hub these sessions are gone. Used after killing a Studio."""
        if not session_ids:
            return []
        self._request_id += 1
        envelope = self._post("/rpc", {
            "jsonrpc": "2.0",
            "id": self._request_id,
            "method": "hub.drop_sessions",
            "params": {"sessions": session_ids, "reason": reason},
        })
        return (envelope.get("result") or {}).get("dropped", [])

    def acquire_lease(
        self,
        *,
        run_id: str,
        agent_id: str,
        build_id: str,
        session_id: str | None = None,
        ttl_seconds: float = 30.0,
    ) -> dict[str, Any]:
        """Acquire an exclusive fenced lease on one exact Studio session."""

        target = session_id or self.pinned_session
        if not target:
            raise BridgeError(ErrorCode.BAD_PARAMS, "acquire_lease needs a session_id or pinned_session")
        self._request_id += 1
        envelope = self._post("/rpc", {
            "jsonrpc": "2.0",
            "id": self._request_id,
            "method": "hub.lease.acquire",
            "params": {
                "runId": run_id,
                "agentId": agent_id,
                "buildId": build_id,
                "session": target,
                "ttlSeconds": ttl_seconds,
            },
        })
        if "error" in envelope:
            error = envelope["error"]
            data = error.get("data") or {}
            raise BridgeError(str(data.get("code") or ErrorCode.EXEC), str(error.get("message")), data.get("details") or {})
        return envelope["result"]

    def renew_lease(self, lease: dict[str, Any], ttl_seconds: float = 30.0) -> dict[str, Any]:
        self._request_id += 1
        envelope = self._post("/rpc", {
            "jsonrpc": "2.0",
            "id": self._request_id,
            "method": "hub.lease.renew",
            "params": {**lease, "ttlSeconds": ttl_seconds},
        })
        if "error" in envelope:
            error = envelope["error"]
            data = error.get("data") or {}
            raise BridgeError(str(data.get("code") or ErrorCode.EXEC), str(error.get("message")), data.get("details") or {})
        return envelope["result"]

    def release_lease(self, lease: dict[str, Any]) -> dict[str, Any]:
        self._request_id += 1
        envelope = self._post("/rpc", {
            "jsonrpc": "2.0",
            "id": self._request_id,
            "method": "hub.lease.release",
            "params": lease,
        })
        if "error" in envelope:
            error = envelope["error"]
            data = error.get("data") or {}
            raise BridgeError(str(data.get("code") or ErrorCode.EXEC), str(error.get("message")), data.get("details") or {})
        return envelope["result"]

    def connected(self) -> bool:
        try:
            return bool(self.status().get("sessions"))
        except BridgeError:
            return False

    def wait_for_plugin(self, timeout: float = 60.0, poll_interval: float = 1.0) -> dict[str, Any]:
        """Block until a Studio plugin completes the handshake."""
        deadline = time.monotonic() + timeout
        last_error: BridgeError | None = None
        while time.monotonic() < deadline:
            try:
                status = self.status()
                if status.get("sessions"):
                    return status
            except BridgeError as exc:
                last_error = exc
            time.sleep(poll_interval)
        raise BridgeError(
            ErrorCode.DISCONNECTED,
            f"no Studio plugin connected within {timeout:.0f}s",
            {"lastError": last_error.to_dict() if last_error else None},
        )

    def wait_until_ready(self, timeout: float = 30.0, poll_interval: float = 0.5) -> dict[str, Any]:
        """Block until some session is holding a poll open.

        Needed after anything that changes the Studio context: the plugin tears
        down its session and re-registers, and a command issued inside that
        window lands on a session that is on its way out. Waiting for an open
        poll means the next command reaches a plugin that is genuinely listening.
        """
        deadline = time.monotonic() + timeout
        last: dict[str, Any] = {}
        while time.monotonic() < deadline:
            try:
                last = self.status()
            except BridgeError:
                time.sleep(poll_interval)
                continue
            if any(item.get("pollWaiting", 0) > 0 for item in last.get("sessions", [])):
                return last
            time.sleep(poll_interval)
        raise BridgeError(
            ErrorCode.DISCONNECTED,
            f"no plugin was listening within {timeout:.0f}s",
            {"status": last},
        )

    # ------------------------------------------------------- typed conveniences

    def ping(self) -> dict[str, Any]:
        return self.call("bridge.ping", timeout=10)

    def studio_info(self) -> dict[str, Any]:
        return self.call("studio.info", timeout=10)

    def tree(self, path: str = "game", depth: int = 2, max_nodes: int = 400) -> dict[str, Any]:
        return self.call("dm.tree", {"path": path, "depth": depth, "maxNodes": max_nodes})

    def properties(self, path: str, properties: list[str] | None = None) -> dict[str, Any]:
        return self.call("dm.properties", {"path": path, "properties": properties or []})

    def find(self, class_name: str | None = None, tag: str | None = None, name: str | None = None, root: str = "game.Workspace", limit: int = 200) -> dict[str, Any]:
        params: dict[str, Any] = {"root": root, "limit": limit}
        if class_name is not None:
            params["className"] = class_name
        if tag is not None:
            params["tag"] = tag
        if name is not None:
            params["name"] = name
        return self.call("dm.find", params)

    def raycast(self, origin: list[float], direction: list[float], ignore: list[str] | None = None) -> dict[str, Any]:
        return self.call("world.raycast", {"origin": origin, "direction": direction, "ignore": ignore or []})

    def ground_support(self, path: str, samples: int = 9, max_gap: float = 1.5) -> dict[str, Any]:
        return self.call("world.ground_support", {"path": path, "samples": samples, "maxGap": max_gap})

    def bounds(self, path: str) -> dict[str, Any]:
        return self.call("world.bounds", {"path": path})

    def overlaps(self, paths: list[str], tolerance: float = 0.0) -> dict[str, Any]:
        return self.call("world.overlaps", {"paths": paths, "tolerance": tolerance})

    def runtime_state(self) -> dict[str, Any]:
        return self.call("run.state", timeout=20)

    def run_start(self, settle_seconds: float = 2.0) -> dict[str, Any]:
        return self.call("run.start", {"settleSeconds": settle_seconds}, timeout=settle_seconds + 30)

    def run_stop(self) -> dict[str, Any]:
        return self.call("run.stop", timeout=30)

    def exec_luau(self, source: str, chunk_name: str = "rqe.exec", timeout: float = 30.0) -> dict[str, Any]:
        return self.call("bridge.exec", {"source": source, "chunkName": chunk_name}, timeout=timeout)

    def camera_focus(self, path: str, pitch_degrees: float = 35.0, yaw_degrees: float = 45.0, margin: float = 1.35) -> dict[str, Any]:
        return self.call("camera.focus", {"path": path, "pitchDegrees": pitch_degrees, "yawDegrees": yaw_degrees, "margin": margin})

    # ---------------------------------------------------------- playing the game

    def actor_attach(self, player: str | None = None) -> dict[str, Any]:
        return self.call("actor.attach", {"player": player} if player else {}, timeout=25)

    def actor_spawn(self, name: str | None = None, near: str | None = None) -> dict[str, Any]:
        params: dict[str, Any] = {}
        if name:
            params["name"] = name
        if near:
            params["near"] = near
        return self.call("actor.spawn", params, timeout=30)

    def actor_navigate_to(self, target: str, tolerance: float = 5.0, timeout: float = 60.0) -> dict[str, Any]:
        return self.call("actor.navigate_to", {"target": target, "tolerance": tolerance, "timeout": timeout}, timeout=timeout + 30)

    def actor_state(self) -> dict[str, Any]:
        return self.call("actor.state", timeout=20)

    def actor_prompts(self, radius: float = 60.0) -> dict[str, Any]:
        return self.call("actor.prompts", {"radius": radius}, timeout=30)

    def prompt_trigger(self, path: str, hold_seconds: float = 0.0) -> dict[str, Any]:
        return self.call("client.prompt_trigger", {"path": path, "holdSeconds": hold_seconds}, timeout=45)

    def gui_tree(self, include_hidden: bool = False) -> dict[str, Any]:
        return self.call("client.gui_tree", {"includeHidden": include_hidden}, timeout=30)

    def gui_click(self, path: str) -> dict[str, Any]:
        return self.call("client.gui_click", {"path": path}, timeout=40)

    def player_state(self) -> dict[str, Any]:
        return self.call("client.player_state", timeout=25)

    def logs(self, limit: int = 100, severity: str | None = None) -> dict[str, Any]:
        params: dict[str, Any] = {"limit": limit}
        if severity is not None:
            params["severity"] = severity
        return self.call("log.tail", params)


class PluginSimulator:
    """The plugin half of the protocol, in Python, for transport tests.

    It performs the same handshake/poll/result cycle the Luau plugin performs,
    against a real socket. Handlers are supplied by the test: this class holds no
    DataModel knowledge and cannot stand in for Studio in a quality claim.
    """

    def __init__(
        self,
        base_url: str,
        handlers: dict[str, Callable[[dict[str, Any]], Any]],
        context: str = "edit",
        client_id: str | None = None,
        token: str | None = None,
    ) -> None:
        self.base_url = base_url.rstrip("/")
        self.handlers = handlers
        self.context = context
        self.client_id = client_id or f"sim-{id(self):x}"
        self.token = token
        self.session: str | None = None
        self._stop = threading.Event()
        self._thread: threading.Thread | None = None

    def _post(self, path: str, payload: dict[str, Any], timeout: float = 40.0) -> Any:
        body = json.dumps(payload).encode("utf-8")
        headers = {"Content-Type": "application/json"}
        if self.token:
            headers["Authorization"] = f"Bearer {self.token}"
        request = urllib.request.Request(f"{self.base_url}{path}", data=body, headers=headers, method="POST")
        with urllib.request.urlopen(request, timeout=timeout) as response:
            return json.loads(response.read().decode("utf-8"))

    def connect(self) -> str:
        result = self._post(
            "/bridge/hello",
            {
                "protocol": PROTOCOL_VERSION,
                "clientId": self.client_id,
                "pluginVersion": "simulator-1.0",
                "studioVersion": "simulator",
                "placeName": "SimulatedPlace",
                "placeId": 0,
                "context": self.context,
            },
        )
        self.session = result["session"]
        return self.session

    def _loop(self) -> None:
        while not self._stop.is_set():
            try:
                batch = self._post("/bridge/poll", {"session": self.session, "maxBatch": 8})
            except Exception:
                if self._stop.is_set():
                    return
                time.sleep(0.1)
                continue
            results = []
            for command in batch.get("commands", []):
                started = time.monotonic()
                handler = self.handlers.get(command["method"])
                if handler is None:
                    results.append({
                        "id": command["id"],
                        "ok": False,
                        "error": {"code": ErrorCode.UNKNOWN_METHOD, "message": command["method"]},
                        "context": self.context,
                    })
                    continue
                try:
                    value = handler(command.get("params", {}))
                    results.append({
                        "id": command["id"],
                        "ok": True,
                        "result": value,
                        "elapsedMs": (time.monotonic() - started) * 1000,
                        "context": self.context,
                        "place": "SimulatedPlace",
                    })
                except Exception as exc:
                    results.append({
                        "id": command["id"],
                        "ok": False,
                        "error": {"code": ErrorCode.EXEC, "message": str(exc)},
                        "context": self.context,
                    })
            if results:
                try:
                    self._post("/bridge/result", {"session": self.session, "results": results})
                except Exception:
                    pass

    def start(self) -> None:
        if self.session is None:
            self.connect()
        self._thread = threading.Thread(target=self._loop, daemon=True)
        self._thread.start()

    def stop(self) -> None:
        self._stop.set()
        if self._thread is not None:
            self._thread.join(timeout=2)
