from __future__ import annotations
from pathlib import Path

ROOT=Path(__file__).resolve().parents[1]

def test_forge_look_is_background_native() -> None:
    source=(ROOT/"forge/cli/look.py").read_text(encoding="utf-8")
    assert "capture_native_viewpoint" in source
    assert "StudioBridge" in source
    assert "pin_to_running" in source
    assert "pin_to_context" in source
    assert 'lookAt": list(centre)' in source
    assert '"target": list(centre)' not in source
    assert "Win32CaptureBackend" not in source
    assert "foreground()" not in source
