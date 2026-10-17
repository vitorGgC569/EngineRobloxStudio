from __future__ import annotations

from pathlib import Path

ROOT=Path(__file__).resolve().parents[1]


def text(path: str) -> str:
    return (ROOT/path).read_text(encoding="utf-8")


def test_recurring_playtest_is_native_background_only() -> None:
    source=text("forge/cli/playtest.py")
    assert "ensure_studio_session(" in source
    assert "allow_cold_launch=False" in source
    assert "allow_foreground_fallback=False" in source
    assert "capture_native_viewpoint" in source
    assert "StudioCaptureService" in source
    assert "look.shoot(" not in source
    assert "look.locate_viewport(" not in source
    assert "restart_for_bridge(" not in source
    assert "_focus_studio(" not in source


def test_recurring_gametest_is_native_background_only() -> None:
    source=text("forge/cli/gametest.py")
    assert "ensure_studio_session(" in source
    assert "allow_cold_launch=False" in source
    assert "allow_foreground_fallback=False" in source
    assert "restart_for_bridge(" not in source
    assert "_focus_studio(" not in source


def test_watch_cold_restart_is_explicit_opt_in_only() -> None:
    source=text("forge/forge.py")
    section=source.split("def cmd_watch",1)[1].split("def cmd_eyeball",1)[0]
    assert "hot_reload.classify" in section
    assert "hot_reload.apply" in section
    assert "if not args.allow_cold_reload" in section
    assert "restart_for_bridge(" in section
    assert "allow_foreground_fallback=False" in section


def test_cli_scenario_prefers_session_reuse_and_native_test_service() -> None:
    source=text("rqe/cli.py")
    section=source.split('if args.studio_command == "scenario":',1)[1]
    section=section.split('if args.studio_command == "play_solo":',1)[0]

    assert "ensure_studio_session(" in section
    assert "allow_cold_launch=bool(args.allow_cold_launch)" in section
    assert "stop_play_solo(" in section
    assert "allow_foreground_fallback=False" in section
    assert "start_play_solo(" in section
    assert "restart_for_bridge(" not in section
    assert "_focus_studio(" not in section


def test_capture_frame_legacy_window_backend_requires_opt_in() -> None:
    source=text("rqe/mcp/factory_tools.py")
    section=source.split("def capture_frame",1)[1].split("server.register(Tool(",1)[0]
    assert "capture_native_viewpoint" in section
    assert 'allowLegacyWindowCapture' in section
    assert "if not allow_legacy" in section


def test_multiplayer_public_path_is_native_and_foreground_fallback_is_explicit() -> None:
    source=text("rqe/hub/teamtest.py")
    public=source.split("def start(",1)[1]
    assert '"test.start"' in public
    assert '"mode": "multiplayer"' in public
    assert "allow_foreground_fallback: bool = False" in public
    assert 'legacy = _start_legacy' in public
    assert "if not allow_foreground_fallback" in public

    add_players=source.split("def add_players(",1)[1].split("def stop(",1)[0]
    assert '"test.add_players"' in add_players
    assert "_click(" not in add_players

    stop=source.split("def stop(",1)[1]
    assert '"test.finish"' in stop
    assert "allow_foreground_fallback: bool = False" in stop
