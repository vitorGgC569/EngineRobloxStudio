from __future__ import annotations
import json
from pathlib import Path

ROOT=Path(__file__).resolve().parents[1]

def test_client_prediction_sampler_contract() -> None:
    client_source=(ROOT/"apps/studio-plugin/src/ClientSource.lua").read_text(encoding="utf-8")
    client_commands=(ROOT/"apps/studio-plugin/src/Commands/Client.lua").read_text(encoding="utf-8")
    dispatcher=(ROOT/"apps/studio-plugin/src/Dispatcher.lua").read_text(encoding="utf-8")
    schema=json.loads((ROOT/"schemas/bridge-commands.v1.json").read_text(encoding="utf-8"))
    command=schema["commands"]["client.prediction"]

    assert "function COMMANDS.prediction(params)" in client_source
    assert "RunService.Misprediction:Connect" in client_source
    assert "RunService:GetPredictionStatus(root)" in client_source
    assert "sampleSeconds must be between 0.1 and 5.0" in client_source
    assert 'source = "RunService.Misprediction/GetPredictionStatus"' in client_source

    assert "function ClientCommands.prediction" in client_commands
    assert 'ClientCommands.invoke("prediction", params)' in client_commands
    assert '["client.prediction"] = ClientCommands.prediction' in dispatcher

    assert command["effect"]=="read"
    assert command["idempotency"]=="safe-retry"
    assert set(command["contexts"])=={"run","server"}
    props=command["params"]["properties"]
    assert props["sampleSeconds"]["minimum"]==0.1
    assert props["sampleSeconds"]["maximum"]==5
