"""actor.activate must report a failed Tool:Activate as E_EXEC.

E_RUNTIME is not in the plugin error module or the hub ErrorCode list. A
command that ran and failed uses Errors.EXEC, the same code Session and Actor
already raise. The message stays the activation failure text.
"""

from __future__ import annotations

from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
PLAYER = ROOT / "apps" / "studio-plugin" / "src" / "Commands" / "Player.lua"


def _activate(source: str) -> str:
    start = source.index("function PlayerCommands.activate")
    end = source.index("return PlayerCommands")
    return source[start:end]


def test_activate_failure_raises_exec() -> None:
    source = PLAYER.read_text(encoding="utf-8")
    activate = _activate(source)

    assert "local Errors = require(script.Parent.Parent.Errors)" in source
    assert 'Errors.raise(Errors.EXEC, "activation failed: " .. tostring(failure))' in activate
    assert "E_RUNTIME" not in source
