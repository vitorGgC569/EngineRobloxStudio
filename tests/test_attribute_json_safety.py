"""Player and client attribute payloads must be JSON-safe before report.

HttpService:JSONEncode throws on a Vector3 or Color3. run.players has to map
each attribute through Serialize.value, the same way instance.attributes does.
The client LocalScript cannot require that module, so Client.invoke encodes
the whole result table on the server before returning it.
"""

from __future__ import annotations

from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
RUNTIME = ROOT / "apps" / "studio-plugin" / "src" / "Commands" / "Runtime.lua"
CLIENT = ROOT / "apps" / "studio-plugin" / "src" / "Commands" / "Client.lua"


def _players(source: str) -> str:
    start = source.index("function RuntimeCommands.players")
    end = source.index("return RuntimeCommands")
    return source[start:end]


def _invoke(source: str) -> str:
    start = source.index("function ClientCommands.invoke")
    end = source.index("function ClientCommands.info")
    return source[start:end]


def test_run_players_serializes_each_attribute() -> None:
    source = RUNTIME.read_text(encoding="utf-8")
    players = _players(source)

    assert "local Serialize = require(script.Parent.Parent.Serialize)" in source
    assert "attributes[key] = Serialize.value(value)" in players
    assert "attributes = player:GetAttributes()" not in players


def test_client_invoke_serializes_the_result_table() -> None:
    source = CLIENT.read_text(encoding="utf-8")
    invoke = _invoke(source)

    assert "local Serialize = require(script.Parent.Parent.Serialize)" in source
    encoded = invoke.index("result = Serialize.value(result)")
    returned = invoke.index("return result")
    assert encoded < returned
