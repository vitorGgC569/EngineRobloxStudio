"""actor state must encode the owning player's attributes before report.

HttpService:JSONEncode throws on a Vector3 or Color3. describe used to assign
owner:GetAttributes() straight into the result. Each value has to go through
Serialize.value, and a rig with no owning player still reports nil.
"""

from __future__ import annotations

from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
ACTOR = ROOT / "apps" / "studio-plugin" / "src" / "Commands" / "Actor.lua"


def _describe(source: str) -> str:
    start = source.index("local function describe")
    end = source.index("function ActorCommands.spawn")
    return source[start:end]


def test_actor_describe_serializes_player_attributes() -> None:
    source = ACTOR.read_text(encoding="utf-8")
    describe = _describe(source)

    assert "local Serialize = require(script.Parent.Parent.Serialize)" in source
    assert "local playerAttributes: { [string]: any }? = nil" in describe
    assert "if owner ~= nil then" in describe
    assert "encoded[key] = Serialize.value(value)" in describe
    assert "playerAttributes = if owner then owner:GetAttributes() else nil" not in source
    assert "playerAttributes = owner:GetAttributes()" not in describe
