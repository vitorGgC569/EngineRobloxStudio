from __future__ import annotations
import json,re
from pathlib import Path

ROOT=Path(__file__).resolve().parents[1]

def test_bridge_schema_and_dispatcher_are_in_sync() -> None:
    dispatcher=(ROOT/"apps/studio-plugin/src/Dispatcher.lua").read_text(encoding="utf-8")
    schema=json.loads((ROOT/"schemas/bridge-commands.v1.json").read_text(encoding="utf-8"))

    registered=set(re.findall(r'\["([^"]+)"\]\s*=\s*[A-Za-z0-9_.]+',dispatcher))
    declared=set((schema.get("commands") or {}).keys())

    missing_from_schema=sorted(registered-declared)
    missing_from_dispatcher=sorted(declared-registered)

    assert not missing_from_schema, f"dispatcher methods missing from schema: {missing_from_schema}"
    assert not missing_from_dispatcher, f"schema methods missing from dispatcher: {missing_from_dispatcher}"

def test_native_background_surface_is_declared() -> None:
    schema=json.loads((ROOT/"schemas/bridge-commands.v1.json").read_text(encoding="utf-8"))
    commands=schema["commands"]
    for name in (
        "studio.capture_permission",
        "studio.capture_background",
        "test.start",
        "test.status",
        "test.finish",
        "test.leave",
    ):
        assert name in commands
