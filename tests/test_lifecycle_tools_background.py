from __future__ import annotations

from pathlib import Path
from unittest.mock import Mock, patch

from rqe.mcp.server import EngineMcpServer, ToolError
from rqe.mcp.lifecycle_tools import register_lifecycle_tools

ROOT = Path(__file__).resolve().parents[1]
PLACE = ROOT / ".tmp" / "test-lifecycle-tools-place.rbxlx"


def _server() -> EngineMcpServer:
    server = EngineMcpServer(ROOT)
    register_lifecycle_tools(server)
    return server


def setup_module() -> None:
    PLACE.parent.mkdir(parents=True, exist_ok=True)
    PLACE.write_text("<roblox />\n", encoding="utf-8")


def teardown_module() -> None:
    PLACE.unlink(missing_ok=True)


def test_studio_ensure_is_background_fail_closed_by_default() -> None:
    server = _server()
    bridge = object()
    result = {
        "ready": False,
        "reused": False,
        "coldLaunched": False,
        "needsColdLaunch": True,
        "reason": "no compatible session",
    }

    with (
        patch("rqe.mcp.lifecycle_tools._bridge", return_value=bridge),
        patch("rqe.hub.lifecycle.ensure_studio_session", return_value=result) as ensure,
    ):
        payload = server.tools["studio_ensure"].handler({
            "place": ".tmp/test-lifecycle-tools-place.rbxlx",
        })

    assert payload["ready"] is False
    assert payload["coldLaunched"] is False
    args, kwargs = ensure.call_args
    assert args[0] == PLACE.resolve()
    assert args[2] is bridge
    assert kwargs["background"] is True
    assert kwargs["allow_cold_launch"] is False


def test_studio_restart_passes_archive_and_bridge_explicitly() -> None:
    server = _server()
    bridge = object()
    restart = Mock(return_value={"handshake": {"sessions": []}})

    with (
        patch("rqe.mcp.lifecycle_tools._bridge", return_value=bridge),
        patch("rqe.hub.lifecycle.restart_for_bridge", restart),
    ):
        payload = server.tools["studio_restart"].handler({
            "place": ".tmp/test-lifecycle-tools-place.rbxlx",
            "archiveRoot": ".tmp/test-lifecycle-tools-recovery",
            "confirmDiscardUnsavedWork": True,
            "background": True,
            "waitSeconds": 37,
        })

    assert payload["place"] == ".tmp\\test-lifecycle-tools-place.rbxlx"
    args, kwargs = restart.call_args
    assert args[0] == PLACE.resolve()
    assert args[1] == (ROOT / ".tmp" / "test-lifecycle-tools-recovery").resolve()
    assert kwargs["bridge"] is bridge
    assert kwargs["wait_seconds"] == 37.0
    assert kwargs["background"] is True


def test_studio_restart_still_requires_destructive_confirmation() -> None:
    server = _server()
    try:
        server.tools["studio_restart"].handler({
            "place": ".tmp/test-lifecycle-tools-place.rbxlx",
        })
    except ToolError as exc:
        assert "confirmDiscardUnsavedWork=true" in str(exc)
    else:
        raise AssertionError("studio_restart must refuse without explicit confirmation")


def test_studio_open_requires_explicit_cold_launch_confirmation() -> None:
    server = _server()
    try:
        server.tools["studio_open"].handler({
            "place": ".tmp/test-lifecycle-tools-place.rbxlx",
            "background": True,
        })
    except ToolError as exc:
        assert "confirmColdLaunch=true" in str(exc)
        assert "studio_ensure" in str(exc)
    else:
        raise AssertionError("studio_open must refuse an unconfirmed cold launch")
