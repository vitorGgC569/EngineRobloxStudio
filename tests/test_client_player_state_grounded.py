"""client.player_state must keep grounded false for an airborne humanoid.

`and`/`or` are left-associative. `humanoid and false or nil` evaluates to nil,
so a character in the air was reported as having no grounded value. Missing
humanoid stays nil; Air must stay false, matching run.state.
"""

from __future__ import annotations

from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
CLIENT = ROOT / "apps" / "studio-plugin" / "src" / "ClientSource.lua"
RUNTIME = ROOT / "apps" / "studio-plugin" / "src" / "Commands" / "Runtime.lua"

GROUNDED = "grounded = if humanoid then humanoid.FloorMaterial ~= Enum.Material.Air else nil,"


def test_client_player_state_preserves_grounded_false() -> None:
    source = CLIENT.read_text(encoding="utf-8")

    assert GROUNDED in source
    assert "FloorMaterial ~= Enum.Material.Air or nil" not in source


def test_run_state_grounded_matches_the_client_expression() -> None:
    source = RUNTIME.read_text(encoding="utf-8")
    assert GROUNDED in source
