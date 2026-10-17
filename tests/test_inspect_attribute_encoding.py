"""dm.inspect must encode every attribute before the result is reported.

The old branch turned a Vector3 into a list and left every other Roblox value
raw. A Color3 attribute then makes HttpService:JSONEncode throw. Serialize.value
covers both, and the raw value must not be assigned through.
"""

from __future__ import annotations

from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
INSPECT = ROOT / "apps" / "studio-plugin" / "src" / "Commands" / "Inspect.lua"


def _inspect(source: str) -> str:
    start = source.index("function InspectCommands.inspect")
    end = source.index("function InspectCommands.watchStart")
    return source[start:end]


def test_inspect_serializes_attributes() -> None:
    source = INSPECT.read_text(encoding="utf-8")
    inspect = _inspect(source)

    assert "local Serialize = require(script.Parent.Parent.Serialize)" in source
    assert "attributes[name] = Serialize.value(value)" in inspect
    assert 'typeof(value) == "Vector3"' not in inspect
    assert "else value" not in inspect
