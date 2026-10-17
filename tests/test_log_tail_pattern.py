"""log.tail must reject a malformed Luau pattern before reading the log.

A pattern of "(" is a legal schema string, and string.find throws "malformed
pattern" on it. That has to be E_BAD_PARAMS naming the field, not a crash
halfway through the history. Nil still means no filter. The walk itself must
not pcall the find and drop the line.
"""

from __future__ import annotations

from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
RUNTIME = ROOT / "apps" / "studio-plugin" / "src" / "Commands" / "Runtime.lua"


def _log_tail(source: str) -> str:
    start = source.index("function RuntimeCommands.logTail")
    end = source.index("function RuntimeCommands.players")
    return source[start:end]


def test_log_tail_validates_pattern_before_the_history_walk() -> None:
    source = RUNTIME.read_text(encoding="utf-8")
    log_tail = _log_tail(source)

    assert "local Errors = require(script.Parent.Parent.Errors)" in source
    assert 'Errors.raise(Errors.BAD_PARAMS, "pattern is not a valid Luau pattern")' in log_tail

    validation = log_tail.index('string.find("", pattern)')
    walk = log_tail.index("for index = #history")
    assert validation < walk
    assert "string.find(entry.message, pattern)" not in log_tail
    assert "pcall(function()" in log_tail[log_tail.index("if pattern ~= nil"):validation]
