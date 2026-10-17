"""watch.start must encode each attribute change before it is stored.

The old branch turned a Vector3 into a list and left every other Roblox value
raw. A Color3 change is then still in the record when watch.read reports it,
and HttpService:JSONEncode throws. Serialize.value covers both.
"""

from __future__ import annotations

from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
INSPECT = ROOT / "apps" / "studio-plugin" / "src" / "Commands" / "Inspect.lua"


def _watch_start(source: str) -> str:
    start = source.index("function InspectCommands.watchStart")
    end = source.index("function InspectCommands.watchRead")
    return source[start:end]


def test_watch_start_serializes_attribute_changes() -> None:
    source = INSPECT.read_text(encoding="utf-8")
    watch = _watch_start(source)

    assert "local Serialize = require(script.Parent.Parent.Serialize)" in source
    assert "value = Serialize.value(value)" in watch
    assert 'typeof(value) == "Vector3"' not in watch
    assert "else value" not in watch


def test_watch_start_serializes_the_initial_value() -> None:
    source = INSPECT.read_text(encoding="utf-8")
    watch = _watch_start(source)

    assert "initial = Serialize.value(thing:GetAttribute(attribute))" in watch
    assert "initial = thing:GetAttribute(attribute)" not in watch
