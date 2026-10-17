from __future__ import annotations

import contextlib
from unittest.mock import patch

from rqe.hub import teamtest


class Bridge:
    def __init__(self):
        self.pinned_session=None
        self.phase="edit"
        self.players=0
        self.test_id="test-1"

    def status(self):
        if self.phase=="edit":
            return {"sessions":[{
                "session":"edit-1","context":"edit","polls":3
            }]}
        if self.phase=="run":
            return {"sessions":[{
                "session":"server-1","context":"server","polls":3
            }]}
        return {"sessions":[]}

    def lease_scope(self,**_kwargs):
        return contextlib.nullcontext({})

    def call(self,method,params=None,timeout=15):
        params=params or {}
        if method=="bridge.capabilities":
            return {"methods":["test.start","test.status","test.finish","test.add_players"]}
        if method=="test.start":
            self.phase="run"
            self.players=int(params["players"])
            return {"id":self.test_id,"mode":"multiplayer","status":"STARTING"}
        if method=="run.state":
            return {"playerCount":self.players}
        if method=="test.status":
            return {"editModeActive":False,"args":{"rqeTestId":self.test_id}}
        if method=="test.finish":
            self.phase="done"
            return {"ending":True,"testId":self.test_id}
        if method=="test.add_players":
            count=int(params["count"])
            self.players+=count
            return {"added":count,"source":"StudioTestService.AddPlayers"}
        raise AssertionError(method)


def test_teamtest_start_is_native_and_never_focuses():
    bridge=Bridge()
    with patch.object(teamtest,"editor_window",side_effect=AssertionError("no UI")):
        result=teamtest.start(bridge,clients=3,timeout=0.2)
    assert result["started"] is True
    assert result["native"] is True
    assert result["foregroundFallbackUsed"] is False
    assert result["players"]==3


def test_teamtest_stop_is_native_and_never_focuses():
    bridge=Bridge()
    bridge.phase="run"
    bridge.players=2
    with patch.object(teamtest,"editor_window",side_effect=AssertionError("no UI")):
        result=teamtest.stop(bridge,timeout=0.2)
    assert result["stopped"] is True
    assert result["native"] is True
    assert result["foregroundFallbackUsed"] is False


def test_teamtest_fails_closed_when_native_is_missing():
    bridge=Bridge()
    def call(method,params=None,timeout=15):
        if method=="bridge.capabilities":
            return {"methods":[]}
        raise AssertionError(method)
    bridge.call=call
    with patch.object(teamtest,"_start_legacy",side_effect=AssertionError("legacy forbidden")):
        result=teamtest.start(bridge,clients=2,timeout=0.01)
    assert result["started"] is False
    assert result["foregroundFallbackUsed"] is False
    assert "disabled" in result["reason"]


def test_teamtest_add_players_is_native_and_never_focuses():
    bridge=Bridge()
    bridge.phase="run"
    bridge.players=2
    with patch.object(teamtest,"editor_window",side_effect=AssertionError("no UI")):
        result=teamtest.add_players(bridge,count=2,timeout=0.2)
    assert result["added"] is True
    assert result["native"] is True
    assert result["foregroundFallbackUsed"] is False
    assert result["before"]==2
    assert result["players"]==4


def test_teamtest_add_players_fails_closed_without_capability():
    bridge=Bridge()
    bridge.phase="run"
    bridge.players=2
    original=bridge.call
    def call(method,params=None,timeout=15):
        if method=="bridge.capabilities":
            return {"methods":["test.status","test.finish"]}
        return original(method,params,timeout)
    bridge.call=call
    with patch.object(teamtest,"editor_window",side_effect=AssertionError("no UI")):
        result=teamtest.add_players(bridge,count=1,timeout=0.01)
    assert result["added"] is False
    assert result["foregroundFallbackUsed"] is False
    assert "test.add_players" in result["reason"]
