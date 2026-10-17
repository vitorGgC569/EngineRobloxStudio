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

import contextlib
import json
import logging
import sys
import threading
import time
import urllib.error
import urllib.request
import uuid
from typing import Any, Callable

from .auth import (
    BridgeAuthError,
    derive_role_token,
    load_bridge_token,
    role_for_command_effect,
)
from .protocol import PROTOCOL_VERSION, BridgeError, ErrorCode, Response
from ..security import SecurityBoundaryError, validate_hub_url
from ..workspace import hub_url as _hub_url


MAX_CLIENT_REQUEST_BYTES = 4 * 1024 * 1024
MAX_CLIENT_RESPONSE_BYTES = 8 * 1024 * 1024
LOGGER = logging.getLogger("rqe.hub.client")


def _bounded_response(response: Any) -> Any:
    declared = response.headers.get("Content-Length")
    if declared is not None:
        try:
            if int(declared) > MAX_CLIENT_RESPONSE_BYTES:
                raise BridgeError(ErrorCode.CAPACITY, "hub response exceeds the client byte limit")
        except ValueError as exc:
            raise BridgeError(ErrorCode.PROTOCOL, "hub returned an invalid Content-Length") from exc
    raw = response.read(MAX_CLIENT_RESPONSE_BYTES + 1)
    if len(raw) > MAX_CLIENT_RESPONSE_BYTES:
        raise BridgeError(ErrorCode.CAPACITY, "hub response exceeds the client byte limit")
    try:
        return json.loads(raw.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise BridgeError(ErrorCode.PROTOCOL, "hub returned invalid UTF-8 JSON") from exc


class StudioBridge:
    """Agent-facing handle on a live Studio session."""

    def __init__(
        self,
        base_url: str = "",
        token: str | None = None,
        timeout: float = 20.0,
        *,
        allow_arbitrary: bool = False,
    ) -> None:
        #: Empty means "wherever the hub is", resolved now rather than frozen
        #: into a default at import time.
        try:
            self.base_url = validate_hub_url(base_url or _hub_url())
        except SecurityBoundaryError as exc:
            raise BridgeAuthError(str(exc)) from exc
        if token is None:
            try:
                token = load_bridge_token()
            except BridgeAuthError:
                # Test/development hubs may deliberately run without auth. The
                # production CLI creates the credential during plugin install.
                token = None
        # ``token`` is the local root secret and never crosses HTTP. Every
        # request carries only the narrow capability its command effect needs.
        # Keeping arbitrary execution opt-in also forces each Python call site
        # to acknowledge when it is using the bridge's escape hatch.
        self._wire_tokens = {
            role: derive_role_token(token, role)
            for role in ("reader", "mutator", "executor", "publisher", "admin")
        } if token else {}
        self.token = self._wire_tokens.get("reader")  # compatibility: health credential
        self.admin_token = self._wire_tokens.get("admin")
        self.allow_arbitrary = bool(allow_arbitrary)
        self.timeout = timeout
        self._request_id = 0
        self._active_lease: dict[str, Any] | None = None
        #: When set, every call is routed to this session. Measurement sequences
        #: pin themselves: instance refs are session-scoped, so an unpinned
        #: sequence can compare a plot measured in the running game against one
        #: measured in the edit-mode place and never notice.
        self.pinned_session: str | None = None

    # ------------------------------------------------------------------ plumbing

    def _post(
        self,
        path: str,
        payload: dict[str, Any],
        timeout: float | None = None,
        *,
        role: str = "reader",
    ) -> Any:
        body = json.dumps(payload).encode("utf-8")
        if len(body) > MAX_CLIENT_REQUEST_BYTES:
            raise BridgeError(ErrorCode.CAPACITY, "bridge request exceeds the client byte limit")
        headers = {"Content-Type": "application/json"}
        credential = self._wire_tokens.get(role)
        if credential:
            headers["Authorization"] = f"Bearer {credential}"
        request = urllib.request.Request(f"{self.base_url}{path}", data=body, headers=headers, method="POST")
        try:
            with urllib.request.urlopen(request, timeout=timeout or self.timeout) as response:
                return _bounded_response(response)
        except urllib.error.HTTPError as exc:
            detail = exc.read(501).decode("utf-8", errors="replace")
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

    def pin_to_context(self, context: str, timeout: float = 30.0) -> str:
        """Pin to one exact edit/run/server/client context."""

        selected = str(context or "").strip().lower()
        if selected == "any":
            return self.pin_to_any(timeout=timeout)
        if selected == "running":
            return self.pin_to_running(timeout=timeout)
        if selected not in {"edit", "run", "server", "client"}:
            raise BridgeError(ErrorCode.BAD_PARAMS, f"unsupported Studio context {context!r}")
        response = self.call_response("bridge.ping", {"_context": selected}, timeout=timeout)
        if not response.session:
            raise BridgeError(ErrorCode.PROTOCOL, "hub did not report which session answered")
        self.pinned_session = response.session
        return response.session

    def unpin(self) -> None:
        self.pinned_session = None

    @property
    def active_lease(self) -> dict[str, Any] | None:
        """Current caller-owned fence, if an explicit lease scope is active."""

        return self._active_lease

    def renew_active_lease(self, ttl_seconds: float = 300.0) -> dict[str, Any]:
        if self._active_lease is None:
            raise BridgeError(ErrorCode.LEASE_REQUIRED, "no Studio lease scope is active")
        renewed = self.renew_lease(self._active_lease, ttl_seconds=ttl_seconds)
        self._active_lease.clear()
        self._active_lease.update(renewed)
        return self._active_lease

    def call_response(
        self,
        method: str,
        params: dict[str, Any] | None = None,
        timeout: float = 15.0,
        *,
        lease: dict[str, Any] | None = None,
    ) -> Response:
        """Like :meth:`call` but returns the full envelope including Studio context."""
        from .commands import CommandRegistryError, load_default_registry

        try:
            spec = load_default_registry(verify_dispatcher=False).require(method)
            role = role_for_command_effect(spec.effect)
        except CommandRegistryError:
            # Unknown calls get only read authority. The hub remains the source
            # of truth and will return E_UNKNOWN_METHOD without granting a
            # guessed mutation/execution capability.
            role = "reader"
        if role == "executor" and not self.allow_arbitrary:
            raise BridgeError(
                ErrorCode.UNAUTHORIZED,
                "arbitrary Studio execution is disabled for this client",
                {"method": method, "remedy": "construct StudioBridge with allow_arbitrary=True at an explicit operator-controlled call site"},
            )

        self._request_id += 1
        merged = {**(params or {}), "_timeout": timeout}
        effective_lease = lease if lease is not None else self._active_lease
        if effective_lease is not None:
            merged["_lease"] = effective_lease
        if self.pinned_session and "_session" not in merged and "_context" not in merged:
            merged["_session"] = self.pinned_session
        payload = {
            "jsonrpc": "2.0",
            "id": self._request_id,
            "method": method,
            "params": merged,
        }
        #: Timed here because this is the one seam every bridge command passes
        #: through. Counting round trips at each call site would miss the ones
        #: added tomorrow, which are exactly the ones worth counting.
        import time as _time

        from ..ledger import record_bridge_call

        _started = _time.perf_counter()
        try:
            envelope = self._post("/rpc", payload, timeout=timeout + 10, role=role)
        except BaseException:
            record_bridge_call(method, _time.perf_counter() - _started, ok=False)
            raise
        inner = envelope.get("result") if isinstance(envelope, dict) else None
        inner_ok = isinstance(inner, dict) and inner.get("ok") is True
        record_bridge_call(
            method,
            _time.perf_counter() - _started,
            ok="error" not in envelope and inner_ok,
        )

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
                return _bounded_response(response)
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
        }, role="admin")
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
        }, role="mutator")
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
        }, role="mutator")
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
        }, role="mutator")
        if "error" in envelope:
            error = envelope["error"]
            data = error.get("data") or {}
            raise BridgeError(str(data.get("code") or ErrorCode.EXEC), str(error.get("message")), data.get("details") or {})
        return envelope["result"]

    @contextlib.contextmanager
    def lease_scope(
        self,
        *,
        agent_id: str,
        run_id: str | None = None,
        build_id: str | None = None,
        session_id: str | None = None,
        context: str = "any",
        ttl_seconds: float = 300.0,
        pin_timeout: float = 30.0,
        release_required: bool = True,
    ):
        """Pin, acquire, fence and release one short Studio operation.

        Multi-step external orchestrators should acquire a lease explicitly and
        renew it between phases. This scope is for one high-level engine action
        whose implementation emits one or a few inseparable bridge commands.
        """

        previous_pin = self.pinned_session
        previous_lease = self._active_lease
        if previous_lease is not None:
            raise BridgeError(
                ErrorCode.LEASE_CONFLICT,
                "nested Studio lease scopes are not supported; reuse the active scope",
            )
        try:
            if session_id:
                self.pinned_session = str(session_id)
            elif context != "any":
                self.pin_to_context(context, timeout=pin_timeout)
            elif not self.pinned_session:
                self.pin_to_context(context, timeout=pin_timeout)
            target = self.pinned_session
            if not target:
                raise BridgeError(ErrorCode.BAD_PARAMS, "lease scope could not select a Studio session")
            owner_run = str(run_id or f"{agent_id}-{uuid.uuid4().hex}")
            owner_build = str(build_id or owner_run)
            lease = self.acquire_lease(
                run_id=owner_run,
                agent_id=str(agent_id),
                build_id=owner_build,
                session_id=target,
                ttl_seconds=ttl_seconds,
            )
            self._active_lease = lease
        except BaseException:
            self.pinned_session = previous_pin
            self._active_lease = previous_lease
            raise
        try:
            yield lease
        finally:
            body_failed = sys.exc_info()[0] is not None
            try:
                self.release_lease(lease)
            except Exception as exc:
                if not body_failed and release_required:
                    raise
                LOGGER.warning("could not release Studio lease after operation: %s", exc)
            finally:
                self.pinned_session = previous_pin
                self._active_lease = previous_lease

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

    def client_input(self, *, action: str, keys: list[str] | None = None, duration: float | None = None, x: float | None = None, y: float | None = None, text: str | None = None, player: str | None = None) -> dict[str, Any]:
        params: dict[str, Any] = {"action": action}
        if keys is not None:
            params["keys"] = list(keys)
        if duration is not None:
            params["duration"] = duration
        if x is not None:
            params["x"] = x
        if y is not None:
            params["y"] = y
        if text is not None:
            params["text"] = text
        if player is not None:
            params["player"] = player
        return self.call("client.input", params, timeout=20)

    def client_camera_set(self, position: list[float], look_at: list[float], field_of_view: float = 70.0, player: str | None = None) -> dict[str, Any]:
        params: dict[str, Any] = {
            "position": list(position),
            "lookAt": list(look_at),
            "fieldOfView": field_of_view,
        }
        if player is not None:
            params["player"] = player
        return self.call("client.camera_set", params, timeout=20)

    def client_camera_release(self, player: str | None = None) -> dict[str, Any]:
        return self.call(
            "client.camera_release",
            {"player": player} if player is not None else {},
            timeout=20,
        )

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
        installation_id: str | None = None,
        token: str | None = None,
    ) -> None:
        try:
            self.base_url = validate_hub_url(base_url)
        except SecurityBoundaryError as exc:
            raise BridgeAuthError(str(exc)) from exc
        self.handlers = handlers
        self.context = context
        self.client_id = client_id or f"sim-{id(self):x}"
        self.installation_id = installation_id or f"sim-install-{self.client_id}"
        self.token = derive_role_token(token, "plugin") if token else None
        self.session: str | None = None
        self.session_key: str | None = None
        self.resume_session: str | None = None
        self.resume_key: str | None = None
        self._stop = threading.Event()
        self._thread: threading.Thread | None = None

    def _post(self, path: str, payload: dict[str, Any], timeout: float = 40.0) -> Any:
        body = json.dumps(payload).encode("utf-8")
        if len(body) > MAX_CLIENT_REQUEST_BYTES:
            raise BridgeError(ErrorCode.CAPACITY, "plugin request exceeds the client byte limit")
        headers = {"Content-Type": "application/json"}
        if self.token:
            headers["Authorization"] = f"Bearer {self.token}"
        request = urllib.request.Request(f"{self.base_url}{path}", data=body, headers=headers, method="POST")
        with urllib.request.urlopen(request, timeout=timeout) as response:
            return _bounded_response(response)

    def connect(self) -> str:
        result = self._post(
            "/bridge/hello",
            {
                "protocol": PROTOCOL_VERSION,
                "clientId": self.client_id,
                "installationId": self.installation_id,
                "resumeSession": self.resume_session,
                "resumeKey": self.resume_key,
                "pluginVersion": "simulator-1.0",
                "studioVersion": "simulator",
                "placeName": "SimulatedPlace",
                "placeId": 0,
                "context": self.context,
            },
        )
        self.session = result["session"]
        self.session_key = result["sessionKey"]
        self.resume_session = self.session
        self.resume_key = self.session_key
        return self.session

    def _loop(self) -> None:
        while not self._stop.is_set():
            try:
                batch = self._post("/bridge/poll", {
                    "session": self.session,
                    "sessionKey": self.session_key,
                    "maxBatch": 8,
                })
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
                    self._post("/bridge/result", {
                        "session": self.session,
                        "sessionKey": self.session_key,
                        "results": results,
                    })
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
