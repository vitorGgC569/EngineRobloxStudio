"""Own one native Studio test across edit/server session transitions.

The returned receipt proves test transport only. Gameplay validation belongs to
the supplied exercise, and never implicitly authorizes a release.
"""
from __future__ import annotations

import copy
import time
from typing import Any, Callable

from .client import StudioBridge


class NativeTestError(RuntimeError):
    pass


def _peer(bridge: StudioBridge, session: str) -> StudioBridge:
    # Copy capability credentials without re-reading another account's token.
    peer = copy.copy(bridge)
    peer.pinned_session = session
    peer._active_lease = None
    return peer


def run_native_test(
    bridge: StudioBridge, *, mode: str = "play", players: int = 2,
    args: dict[str, Any] | None = None, timeout: float = 120,
    exercise: Callable[[StudioBridge, dict[str, Any]], Any] | None = None,
) -> dict[str, Any]:
    if mode not in {"play", "run", "multiplayer"} or not 1 <= players <= 8:
        raise ValueError("invalid native test mode or player count")
    if not 5 <= timeout <= 240:
        raise ValueError("native test timeout must be between 5 and 240 seconds")
    # Never silently replace a caller's existing session or lease.
    if bridge._active_lease is not None:
        raise NativeTestError("native tests require their own edit and runtime leases")
    original_pin = bridge.pinned_session
    started = time.monotonic()
    deadline = started + timeout
    receipt: dict[str, Any] = {
        "source": "studio-bridge", "validationLevel": "NOT_VALIDATED",
        "authorizesRelease": False, "claim": "COMMAND_SUCCESS", "mode": mode,
    }
    runtime = None
    test_id = None
    finished = False

    def remaining() -> float:
        value = deadline - time.monotonic()
        if value <= 0:
            raise NativeTestError("native test timed out")
        return min(value, 15)

    try:
        edit_id = bridge.pinned_session or bridge.pin_to_context("edit", timeout=remaining())
        edit_info = bridge.call("studio.info", {}, timeout=remaining())
        if edit_info.get("context") != "edit":
            raise NativeTestError("native test must begin in the pinned edit session")
        initial_sessions = bridge.status().get("sessions", [])
        identity = next((s for s in initial_sessions if s["session"] == edit_id), None)
        if not identity or not identity.get("installationId"):
            raise NativeTestError("edit session has no installation identity")
        before = {s["session"] for s in initial_sessions}
        receipt["editSession"] = edit_id
        with bridge.lease_scope(agent_id="native-test", session_id=edit_id, ttl_seconds=300):
            job = bridge.call("test.start", {"mode": mode, "players": players, "args": args or {}}, timeout=remaining())
            test_id = job.get("id")
            if not test_id:
                raise NativeTestError("test.start returned no test identity; completion is uncertain")
            receipt["testId"] = test_id
            while runtime is None:
                remaining()
                state = bridge.call("test.status", {}, timeout=remaining()).get("job") or {}
                # Studio can report EditModeActive=false on the pinned edit
                # peer during ExecutePlayModeAsync. No job is a transition,
                # not evidence that a different job replaced ours. The runtime
                # must still prove its matching native test id below.
                if state and state.get("id") != test_id:
                    raise NativeTestError("native test identity changed in edit mode")
                if state.get("status") in {"ERROR", "FINISHED"}:
                    raise NativeTestError(f"test ended before a runtime was identified: {state}")
                matches = []
                for session in bridge.status().get("sessions", []):
                    if (session["session"] in before or session.get("context") not in {"server", "run"}
                            or session.get("installationId") != identity["installationId"]):
                        continue
                    candidate = _peer(bridge, session["session"])
                    try:
                        observed = candidate.call("test.status", {}, timeout=remaining())
                    except Exception:
                        continue
                    if (observed.get("args") or {}).get("rqeTestId") == test_id:
                        matches.append(candidate)
                if len(matches) > 1:
                    raise NativeTestError("multiple servers claim the same native test; refusing ambiguity")
                if matches:
                    runtime = matches[0]
                else:
                    time.sleep(min(0.25, remaining()))
            receipt["runtimeSession"] = runtime.pinned_session
            with runtime.lease_scope(agent_id="native-test", session_id=runtime.pinned_session, ttl_seconds=300):
                try:
                    # Identity is rechecked immediately before the exercise.
                    observed = runtime.call("test.status", {}, timeout=remaining())
                    if (observed.get("args") or {}).get("rqeTestId") != test_id:
                        raise NativeTestError("runtime changed before the test exercise")
                    result = exercise(runtime, receipt) if exercise else {"nativeTransportRoundTrip": True}
                    remaining()
                    runtime.call("test.finish", {"testId": test_id, "result": result}, timeout=remaining())
                    finished = True
                finally:
                    if not finished:
                        # test.finish independently checks the test id. Never
                        # run.stop an unrelated place after a failed handoff.
                        try:
                            runtime.call("test.finish", {"testId": test_id, "result": {"aborted": True}}, timeout=10)
                        except Exception as exc:
                            receipt["cleanupError"] = str(exc)
            while True:
                state = bridge.call("test.status", {}, timeout=remaining()).get("job") or {}
                if state and state.get("id") != test_id:
                    raise NativeTestError("native completion belongs to another test")
                if state.get("status") == "ERROR":
                    raise NativeTestError(str(state.get("error")))
                if state.get("status") == "FINISHED":
                    receipt.update(status="COMPLETED", result=state.get("result"), validationLevel="RUNTIME_VALIDATED")
                    break
                time.sleep(min(0.25, remaining()))
    except Exception as exc:
        receipt.update(status="FAILED", claim="NOT_VALIDATED", error=str(exc))
        if test_id and runtime is None:
            receipt["cleanupError"] = "No verified runtime was available to end this test safely."
    finally:
        bridge.pinned_session = original_pin
        receipt["elapsedSeconds"] = round(time.monotonic() - started, 3)
    return receipt
