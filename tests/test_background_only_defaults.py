from __future__ import annotations

import ast
import inspect
from pathlib import Path

from rqe.hub import lifecycle, teamtest

ROOT = Path(__file__).resolve().parents[1]

NORMAL_BACKGROUND_FILES = (
    ROOT / "forge" / "cli" / "look.py",
    ROOT / "forge" / "cli" / "playtest.py",
    ROOT / "forge" / "cli" / "watch.py",
    ROOT / "forge" / "cli" / "hot_reload.py",
    ROOT / "games" / "aetherworks" / "validate_art.py",
    ROOT / "games" / "aetherworks" / "validate_habitat.py",
)

FORBIDDEN_FOREGROUND_TOKENS = (
    "SetForegroundWindow",
    "keybd_event",
    "Win32CaptureBackend",
    "ImageGrab",
    "SwitchToThisWindow",
)


def test_normal_visual_and_watch_callers_are_background_native() -> None:
    for path in NORMAL_BACKGROUND_FILES:
        source = path.read_text(encoding="utf-8")
        ast.parse(source, filename=str(path))
        for token in FORBIDDEN_FOREGROUND_TOKENS:
            assert token not in source, f"{path.relative_to(ROOT)} uses foreground legacy token {token}"

    look = (ROOT / "forge" / "cli" / "look.py").read_text(encoding="utf-8")
    playtest = (ROOT / "forge" / "cli" / "playtest.py").read_text(encoding="utf-8")
    art = (ROOT / "games" / "aetherworks" / "validate_art.py").read_text(encoding="utf-8")
    habitat = (ROOT / "games" / "aetherworks" / "validate_habitat.py").read_text(encoding="utf-8")

    assert "capture_native_viewpoint" in look
    assert "capture_native_viewpoint" in playtest
    assert "capture_native_viewpoint" in art
    assert "capture_native_viewpoint" in habitat


def test_foreground_fallbacks_are_opt_in_only() -> None:
    for function in (
        lifecycle.start_play_solo,
        lifecycle.stop_play_solo,
        teamtest.start,
        teamtest.stop,
    ):
        parameter = inspect.signature(function).parameters["allow_foreground_fallback"]
        assert parameter.default is False, function.__qualname__

    # Adding clients has no foreground fallback parameter at all.
    assert "allow_foreground_fallback" not in inspect.signature(teamtest.add_players).parameters


def test_no_normal_caller_enables_foreground_fallback() -> None:
    for relative in ("rqe", "forge"):
        for path in (ROOT / relative).rglob("*.py"):
            source = path.read_text(encoding="utf-8", errors="replace")
            assert "allow_foreground_fallback=True" not in source, path.relative_to(ROOT)
