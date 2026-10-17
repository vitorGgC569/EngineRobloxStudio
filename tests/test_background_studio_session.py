from __future__ import annotations

import contextlib
import json
from pathlib import Path
from unittest.mock import patch

from rqe.hub import lifecycle
from rqe.hub.install import plugin_build_identity
from rqe.hub.protocol import SessionInfo


ROOT=Path(__file__).resolve().parents[1]


class Bridge:
    def __init__(self,sessions,methods):
        self.sessions=list(sessions)
        self.methods=set(methods)
        self.pinned_session=None

    def status(self):
        return {"sessions":list(self.sessions)}

    def call(self,method,params=None,timeout=15):
        if method=="bridge.capabilities":
            identity=plugin_build_identity(ROOT)
            return {
                **identity,
                "methods":sorted(self.methods),
                "context":"edit",
            }
        raise AssertionError(method)


def test_plugin_build_identity_is_exposed_in_session_status():
    identity=plugin_build_identity(ROOT)
    info=SessionInfo(
        id="s",
        plugin_version=identity["pluginVersion"],
        plugin_build_id=identity["pluginBuildId"],
        studio_version="studio",
        place_name="place",
        place_id=0,
        context="edit",
    )
    payload=info.to_dict()
    assert payload["pluginVersion"]==identity["pluginVersion"]
    assert payload["pluginBuildId"]==identity["pluginBuildId"]


def test_ensure_reuses_matching_native_background_session(tmp_path):
    identity=plugin_build_identity(ROOT)
    place=(tmp_path/"game.rbxlx").resolve()
    place.write_text("<roblox/>",encoding="utf-8")
    bridge=Bridge([{
        "session":"edit-1",
        "context":"edit",
        "polls":10,
        **identity,
    }],{
        "test.start","test.status","test.finish","studio.capture_background"
    })
    owned=[{
        "pid":42,
        "place":str(place),
        "path":"RobloxStudioBeta.exe",
        "startedAt":"now",
    }]

    with (
        patch.object(lifecycle,"_owned_studio_processes",return_value=(owned,[])),
        patch.object(lifecycle,"minimize_studio",return_value=1),
        patch.object(lifecycle,"restart_for_bridge",side_effect=AssertionError("must not restart")),
        patch.object(lifecycle,"launch_studio",side_effect=AssertionError("must not launch")),
    ):
        result=lifecycle.ensure_studio_session(
            place,
            tmp_path/"archive",
            bridge,
            allow_cold_launch=False,
        )

    assert result["ready"] is True
    assert result["reused"] is True
    assert result["coldLaunched"] is False
    assert bridge.pinned_session=="edit-1"


def test_ensure_stale_session_fails_closed_without_launch(tmp_path):
    identity=plugin_build_identity(ROOT)
    place=(tmp_path/"game.rbxlx").resolve()
    place.write_text("<roblox/>",encoding="utf-8")
    bridge=Bridge([{
        "session":"old-edit",
        "context":"edit",
        "polls":5,
        "pluginVersion":"0.0.0",
        "pluginBuildId":"stale",
    }],set())
    owned=[{
        "pid":42,
        "place":str(place),
        "path":"RobloxStudioBeta.exe",
        "startedAt":"now",
    }]

    with (
        patch.object(lifecycle,"_owned_studio_processes",return_value=(owned,[])),
        patch.object(lifecycle,"restart_for_bridge",side_effect=AssertionError("must not restart")),
        patch.object(lifecycle,"launch_studio",side_effect=AssertionError("must not launch")),
    ):
        result=lifecycle.ensure_studio_session(
            place,
            tmp_path/"archive",
            bridge,
            allow_cold_launch=False,
        )

    assert result["ready"] is False
    assert result["needsColdLaunch"] is True
    assert result["coldLaunched"] is False
    assert identity["pluginBuildId"] in result["reason"]
