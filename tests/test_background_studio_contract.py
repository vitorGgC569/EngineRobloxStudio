from __future__ import annotations
from pathlib import Path

ROOT=Path(__file__).resolve().parents[1]

def read(rel: str) -> str:
    return (ROOT / rel).read_text(encoding="utf-8")

def test_background_playtest_is_native_only() -> None:
    playtest=read("forge/cli/playtest.py")
    assert "ensure_studio_session(" in playtest
    assert "allow_cold_launch=False" in playtest
    assert "allow_foreground_fallback=False" in playtest
    assert "_native_viewport_shot" in playtest
    assert "capture_native_viewpoint" in playtest
    assert "look.shoot" not in playtest
    assert "locate_viewport" not in playtest

def test_background_gametest_is_native_only() -> None:
    gametest=read("forge/cli/gametest.py")
    assert "ensure_studio_session(" in gametest
    assert "allow_cold_launch=False" in gametest
    assert "allow_foreground_fallback=False" in gametest
    assert "restart_for_bridge(" not in gametest

def test_watch_does_not_cold_reload_unless_explicit() -> None:
    forge=read("forge/forge.py")
    watch=read("forge/cli/watch.py")
    assert "hot_reload.classify" in forge
    assert "ensure_studio_session(" in forge
    assert "allow_cold_launch=False" in forge
    assert "allow_foreground_fallback=False" in forge
    assert "if not args.allow_cold_reload" in forge
    assert "coldReloadRequired" in watch

def test_capture_frame_is_native_first_and_legacy_opt_in() -> None:
    factory=read("rqe/mcp/factory_tools.py")
    capture=read("rqe/capture.py")
    dispatcher=read("apps/studio-plugin/src/Dispatcher.lua")
    command=read("apps/studio-plugin/src/Commands/Capture.lua")

    assert "capture_native_viewpoint" in factory
    assert 'allowLegacyWindowCapture' in factory
    assert 'bool(arguments.get("allowLegacyWindowCapture", False))' in factory
    assert '"StudioCaptureService"' in capture
    assert '"studio.capture_background"' in capture
    assert '["studio.capture_background"] = CaptureCommands.background' in dispatcher
    assert 'StudioCaptureService:CaptureScreenshot(options)' in command
    assert 'GetBuffer()' in command

def test_plugin_identity_is_explicit() -> None:
    config=read("apps/studio-plugin/src/Config.lua")
    bridge=read("apps/studio-plugin/src/Commands/Bridge.lua")
    transport=read("apps/studio-plugin/src/Transport.lua")
    protocol=read("rqe/hub/protocol.py")
    server=read("rqe/hub/server.py")

    assert "PLUGIN_BUILD_ID" in config
    assert "pluginBuildId" in bridge
    assert "pluginBuildId" in transport
    assert "plugin_build_id" in protocol
    assert "pluginBuildId" in server
