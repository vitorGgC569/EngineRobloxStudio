from __future__ import annotations
import json
from pathlib import Path

ROOT=Path(__file__).resolve().parents[1]

def test_device_simulator_surface_matches_current_studio_api() -> None:
    testing=(ROOT/"apps/studio-plugin/src/Commands/Testing.lua").read_text(encoding="utf-8")
    dispatcher=(ROOT/"apps/studio-plugin/src/Dispatcher.lua").read_text(encoding="utf-8")
    schema=json.loads((ROOT/"schemas/bridge-commands.v1.json").read_text(encoding="utf-8"))
    commands=schema["commands"]

    for token in (
        "SetDeviceAsync",
        "SetResolutionAsync",
        "SetPixelDensityAsync",
        "SetOrientationAsync",
        "SetScalingModeAsync",
        "GetScalingModeAsync",
        "GetDeviceInfoAsync",
        "EmulatedTotalMemoryInMB",
    ):
        assert token in testing

    assert '["test.device_info"] = TestingCommands.deviceInfo' in dispatcher
    assert "test.device_info" in commands

    props=commands["test.device"]["params"]["properties"]
    assert props["scalingMode"]["enum"] == [
        "ScaleToPhysicalSize",
        "ActualResolution",
        "FitToWindow",
    ]
    assert props["memoryMb"]["minimum"]==0

    info=commands["test.device_info"]
    assert info["effect"]=="read"
    assert info["idempotency"]=="safe-retry"
    assert info["params"]["required"]==["deviceId"]

def test_device_info_is_json_safe() -> None:
    source=(ROOT/"apps/studio-plugin/src/Commands/Testing.lua").read_text(encoding="utf-8")
    assert "Serialize.value(infoOrError)" in source
