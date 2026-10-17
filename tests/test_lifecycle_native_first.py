from __future__ import annotations

import contextlib
import unittest
from unittest.mock import Mock, patch

from rqe.hub import lifecycle


class _Bridge:
    def __init__(self, sessions):
        self._sessions=list(sessions)
        self.pinned_session=None

    def status(self):
        return {"sessions": list(self._sessions)}

    def lease_scope(self, **_kwargs):
        return contextlib.nullcontext({})

    def call(self, method, params=None, timeout=15):
        if method=="bridge.install_client":
            return {"installed": True}
        if method=="instance.children":
            return {"children":[{"name":"RQEClientBridge"}]}
        if method=="bridge.capabilities":
            return {"methods":[]}
        raise AssertionError(f"unexpected bridge call: {method}")


class NativeFirstLifecycleTests(unittest.TestCase):
    def test_start_does_not_focus_when_native_is_unavailable_by_default(self):
        bridge=_Bridge([{
            "session":"edit-1",
            "context":"edit",
            "polls":1,
        }])
        with patch.object(
            lifecycle,
            "_focus_studio",
            side_effect=AssertionError("foreground path must not run"),
        ) as focus:
            result=lifecycle.start_play_solo(
                bridge,
                wait_seconds=0.01,
                restart=False,
            )

        self.assertFalse(result["started"])
        self.assertFalse(result["foregroundFallbackUsed"])
        self.assertIn("foreground F5 fallback is disabled", result["reason"])
        focus.assert_not_called()

    def test_stop_does_not_focus_when_native_is_unavailable_by_default(self):
        bridge=_Bridge([])
        with patch.object(
            lifecycle,
            "_focus_studio",
            side_effect=AssertionError("foreground path must not run"),
        ) as focus:
            result=lifecycle.stop_play_solo(bridge,wait_seconds=0.01)

        self.assertFalse(result["stopped"])
        self.assertFalse(result["foregroundFallbackUsed"])
        self.assertIn("foreground Shift+F5 fallback is disabled", result["reason"])
        focus.assert_not_called()

    def test_restart_background_guard_minimizes_before_and_during_handshake(self):
        bridge=Mock()
        bridge.status.side_effect=[
            {"sessions":[]},
            {"sessions":[{
                "session":"fresh-edit",
                "context":"edit",
                "polls":1,
            }]},
        ]
        bridge.drop_sessions.return_value=[]

        with (
            patch.object(lifecycle,"ensure_hub",return_value={"alive":True}),
            patch.object(lifecycle,"stop_studio",return_value={
                "stopped":True,
                "wasRunning":False,
                "ownedPids":[],
            }),
            patch.object(lifecycle,"archive_recovery_files",return_value={
                "archived":0,"files":[],
            }),
            patch.object(lifecycle,"clear_place_lock",return_value=True),
            patch.object(lifecycle,"launch_studio",return_value={
                "launched":True,"pid":42,"background":True,
            }),
            patch.object(lifecycle,"minimize_studio",return_value=1) as minimize,
        ):
            result=lifecycle.restart_for_bridge(
                "place.rbxlx",
                "archive",
                bridge=bridge,
                wait_seconds=0.1,
                background=True,
            )

        self.assertTrue(result["handshake"]["sessions"])
        self.assertGreaterEqual(minimize.call_count,2)
        self.assertGreaterEqual(result["backgroundGuardMinimizations"],1)


if __name__=="__main__":
    unittest.main()
