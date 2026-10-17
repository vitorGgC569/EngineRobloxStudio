from __future__ import annotations
from pathlib import Path
from unittest.mock import patch

from rqe.hub import lifecycle


EXPECTED={"pluginVersion":"2.1.0","pluginBuildId":"native-background-2026-09-23.1"}
METHODS=["test.start","test.status","test.finish","studio.capture_background"]


class FakeBridge:
    def __init__(self,sessions,methods=METHODS):
        self._sessions=sessions
        self._methods=methods
        self.pinned_session=None
        self.calls=[]

    def status(self):
        return {"sessions":self._sessions}

    def call(self,method,params,timeout=15):
        self.calls.append((method,params,timeout))
        assert method=="bridge.capabilities"
        return {"methods":self._methods}


def session(name="echo-riot-dogfood",version="2.1.0",build="native-background-2026-09-23.1"):
    return {
        "session":"sess-edit",
        "context":"edit",
        "polls":4,
        "pluginVersion":version,
        "pluginBuildId":build,
        "place":{"name":name,"id":0},
    }


def owned(place:Path):
    return [{
        "pid":1234,
        "place":str(place.resolve()),
        "path":"C:/RobloxStudioBeta.exe",
        "startedAt":"2026-09-23T10:00:00Z",
    }]


def test_reuses_exact_place_and_current_plugin_without_restart(tmp_path:Path):
    place=tmp_path/"echo-riot-dogfood.rbxlx"
    bridge=FakeBridge([session()])

    with (
        patch("rqe.hub.install.plugin_build_identity",return_value=EXPECTED),
        patch.object(lifecycle,"_owned_studio_processes",return_value=(owned(place),[])),
        patch.object(lifecycle,"minimize_studio",return_value=1) as minimize,
        patch.object(lifecycle,"restart_for_bridge") as restart,
    ):
        result=lifecycle.ensure_studio_session(
            place,tmp_path/"recovery",bridge,
            background=True,allow_cold_launch=False,
        )

    assert result["ready"] is True
    assert result["reused"] is True
    assert result["coldLaunched"] is False
    assert bridge.pinned_session=="sess-edit"
    assert result["capabilitiesVerified"]==sorted(METHODS)
    minimize.assert_called_once()
    restart.assert_not_called()


def test_rejects_compatible_plugin_from_wrong_place_without_restart(tmp_path:Path):
    place=tmp_path/"echo-riot-dogfood.rbxlx"
    bridge=FakeBridge([session(name="some-other-game")])

    with (
        patch("rqe.hub.install.plugin_build_identity",return_value=EXPECTED),
        patch.object(lifecycle,"_owned_studio_processes",return_value=(owned(place),[])),
        patch.object(lifecycle,"minimize_studio") as minimize,
        patch.object(lifecycle,"restart_for_bridge") as restart,
    ):
        result=lifecycle.ensure_studio_session(
            place,tmp_path/"recovery",bridge,
            background=True,allow_cold_launch=False,
        )

    assert result["ready"] is False
    assert result["needsColdLaunch"] is True
    assert "no healthy edit bridge session" in result["reason"]
    assert bridge.pinned_session is None
    minimize.assert_not_called()
    restart.assert_not_called()


def test_rejects_stale_plugin_build_without_foreground_restart(tmp_path:Path):
    place=tmp_path/"echo-riot-dogfood.rbxlx"
    bridge=FakeBridge([session(build="old-build")])

    with (
        patch("rqe.hub.install.plugin_build_identity",return_value=EXPECTED),
        patch.object(lifecycle,"_owned_studio_processes",return_value=(owned(place),[])),
        patch.object(lifecycle,"minimize_studio") as minimize,
        patch.object(lifecycle,"restart_for_bridge") as restart,
    ):
        result=lifecycle.ensure_studio_session(
            place,tmp_path/"recovery",bridge,
            background=True,allow_cold_launch=False,
        )

    assert result["ready"] is False
    assert result["needsColdLaunch"] is True
    assert "does not match the installed plugin build" in result["reason"]
    minimize.assert_not_called()
    restart.assert_not_called()


def test_missing_native_capability_fails_closed_without_restart(tmp_path:Path):
    place=tmp_path/"echo-riot-dogfood.rbxlx"
    bridge=FakeBridge([session()],methods=["test.start","test.status","test.finish"])

    with (
        patch("rqe.hub.install.plugin_build_identity",return_value=EXPECTED),
        patch.object(lifecycle,"_owned_studio_processes",return_value=(owned(place),[])),
        patch.object(lifecycle,"minimize_studio") as minimize,
        patch.object(lifecycle,"restart_for_bridge") as restart,
    ):
        result=lifecycle.ensure_studio_session(
            place,tmp_path/"recovery",bridge,
            background=True,allow_cold_launch=False,
        )

    assert result["ready"] is False
    assert "missing native methods" in result["reason"]
    assert "studio.capture_background" in result["reason"]
    minimize.assert_not_called()
    restart.assert_not_called()
