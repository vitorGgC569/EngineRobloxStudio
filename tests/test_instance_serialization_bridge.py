from __future__ import annotations
import json
from pathlib import Path

ROOT=Path(__file__).resolve().parents[1]

def test_native_instance_serialization_contract() -> None:
    source=(ROOT/"apps/studio-plugin/src/Commands/Serialization.lua").read_text(encoding="utf-8")
    dispatcher=(ROOT/"apps/studio-plugin/src/Dispatcher.lua").read_text(encoding="utf-8")
    schema=json.loads((ROOT/"schemas/bridge-commands.v1.json").read_text(encoding="utf-8"))
    commands=schema["commands"]

    assert 'SerializationService:SerializeInstancesAsync(roots)' in source
    assert 'SerializationService:DeserializeInstancesAsync(raw)' in source
    assert 'EncodingService:Base64Encode(raw)' in source
    assert 'EncodingService:Base64Decode(buffer.fromstring(dataBase64))' in source
    assert 'MAX_RAW_BYTES = 2 * 1024 * 1024' in source
    assert 'MAX_INSTANCES = 10000' in source
    assert 'History.record("RQE instance.deserialize"' in source
    assert 'RunService:IsRunning()' in source
    assert 'instance.deserialize is edit-mode only' in source
    assert 'ancestor/descendant overlap' in source
    assert 'instance.Parent == game' in source

    assert '["instance.serialize"] = SerializationCommands.serialize' in dispatcher
    assert '["instance.deserialize"] = SerializationCommands.deserialize' in dispatcher

    encode=commands["instance.serialize"]
    decode=commands["instance.deserialize"]
    assert encode["effect"]=="read"
    assert encode["idempotency"]=="safe-retry"
    assert set(encode["contexts"])=={"edit","run","server"}
    assert encode["params"]["properties"]["paths"]["maxItems"]==64

    assert decode["effect"]=="mutation"
    assert decode["idempotency"]=="at-most-once"
    assert decode["contexts"]==["edit"]
    assert decode["params"]["properties"]["dataBase64"]["maxLength"]<=2_800_000
