from __future__ import annotations
import json
from pathlib import Path

ROOT=Path(__file__).resolve().parents[1]

def test_network_simulator_bridge_contract() -> None:
    testing=(ROOT/"apps/studio-plugin/src/Commands/Testing.lua").read_text(encoding="utf-8")
    dispatcher=(ROOT/"apps/studio-plugin/src/Dispatcher.lua").read_text(encoding="utf-8")
    schema=json.loads((ROOT/"schemas/bridge-commands.v1.json").read_text(encoding="utf-8"))

    for token in (
        "InboundNetworkMinDelayMs",
        "InboundNetworkJitterMs",
        "InboundNetworkLossPercent",
        "OutboundNetworkMinDelayMs",
        "OutboundNetworkJitterMs",
        "OutboundNetworkLossPercent",
        "home_wifi",
        "mobile_4g",
        "bad_3g",
    ):
        assert token in testing

    assert '["test.network"] = TestingCommands.network' in dispatcher
    assert '["test.network_status"] = TestingCommands.networkStatus' in dispatcher
    assert "test.network" in schema["commands"]
    assert "test.network_status" in schema["commands"]

    params=schema["commands"]["test.network"]["params"]["properties"]
    assert params["inboundLatencyMs"]["maximum"]==1000
    assert params["outboundLatencyMs"]["maximum"]==1000
    assert params["inboundJitterMs"]["maximum"]==1000
    assert params["outboundJitterMs"]["maximum"]==1000
    assert params["inboundLossPercent"]["maximum"]==0.5
    assert params["outboundLossPercent"]["maximum"]==0.5
    assert params["randomizeJoinInstanceOrder"]["type"]=="boolean"

    device_params=schema["commands"]["test.device"]["params"]["properties"]
    assert device_params["memoryMb"]["minimum"]==0
    assert device_params["memoryMb"]["maximum"]==262144
    assert "EmulatedTotalMemoryInMB" in testing
    assert "RandomizeJoinInstanceOrder" in testing

def test_network_presets_match_documented_values() -> None:
    testing=(ROOT/"apps/studio-plugin/src/Commands/Testing.lua").read_text(encoding="utf-8")
    assert "inboundLatencyMs = 30, inboundJitterMs = 12, inboundLossPercent = 0.20" in testing
    assert "outboundLatencyMs = 30, outboundJitterMs = 15, outboundLossPercent = 0.30" in testing
    assert "inboundLatencyMs = 45, inboundJitterMs = 20, inboundLossPercent = 0.40" in testing
    assert "outboundLatencyMs = 55, outboundJitterMs = 30, outboundLossPercent = 0.50" in testing
    assert "inboundLatencyMs = 150, inboundJitterMs = 70, inboundLossPercent = 0.50" in testing
    assert "outboundLatencyMs = 180, outboundJitterMs = 90, outboundLossPercent = 0.50" in testing


def test_join_order_and_low_memory_controls_are_exposed() -> None:
    testing=(ROOT/"apps/studio-plugin/src/Commands/Testing.lua").read_text(encoding="utf-8")
    schema=json.loads((ROOT/"schemas/bridge-commands.v1.json").read_text(encoding="utf-8"))

    assert "RandomizeJoinInstanceOrder" in testing
    assert "EmulatedTotalMemoryInMB" in testing
    assert "FreeMemoryMBytes" in testing

    network=schema["commands"]["test.network"]["params"]["properties"]
    device=schema["commands"]["test.device"]["params"]["properties"]
    assert network["randomizeJoinInstanceOrder"]["type"]=="boolean"
    assert device["memoryMb"]["minimum"]==0
    assert device["memoryMb"]["maximum"]>=65536
