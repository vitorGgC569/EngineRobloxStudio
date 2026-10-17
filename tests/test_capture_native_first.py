from __future__ import annotations

import contextlib
from pathlib import Path
from unittest.mock import Mock, patch

import pytest

from rqe.mcp.factory_tools import register_factory_tools
from rqe.mcp.server import EngineMcpServer


ROOT=Path(__file__).resolve().parents[1]


def _server():
    server=EngineMcpServer(ROOT)
    register_factory_tools(server)
    return server


def test_capture_frame_refuses_foreground_fallback_by_default(tmp_path):
    server=_server()
    handler=server.tools["capture_frame"].handler

    bridge=Mock()
    bridge.pin_to_running.return_value="sess-native"
    bridge.lease_scope.return_value=contextlib.nullcontext({})

    with (
        patch("rqe.hub.client.StudioBridge",return_value=bridge),
        patch(
            "rqe.capture.capture_native_viewpoint",
            side_effect=RuntimeError("native capture unavailable"),
        ),
        patch("rqe.capture.capture_viewpoint") as legacy,
    ):
        with pytest.raises(Exception) as caught:
            handler({
                "viewpoint":"native-only",
                "outputDir":str(tmp_path.relative_to(ROOT)) if tmp_path.is_relative_to(ROOT) else ".tmp/native-capture-test",
            })

    assert "legacy foreground/window capture is disabled" in str(caught.value)
    legacy.assert_not_called()


def test_capture_frame_schema_requires_explicit_legacy_opt_in():
    tool=_server().tools["capture_frame"]
    props=tool.input_schema["properties"]

    assert "allowLegacyWindowCapture" in props
    assert "includeUi" in props
    assert "explicit opt-in" in props["allowLegacyWindowCapture"]["description"]
