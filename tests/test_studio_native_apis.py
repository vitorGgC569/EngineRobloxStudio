from __future__ import annotations
import json
from pathlib import Path

from rqe.luau_check import check_all

ROOT=Path(__file__).resolve().parents[1]


def test_native_studio_save_is_fail_closed() -> None:
    schema=json.loads((ROOT/"schemas"/"bridge-commands.v1.json").read_text(encoding="utf-8"))
    command=schema["commands"]["studio.save_place"]

    assert command["effect"]=="mutation"
    assert command["contexts"]==["edit"]
    assert command["idempotency"]=="at-most-once"
    assert command["params"]["required"]==["confirmOverwrite"]
    assert command["params"]["properties"]["placeId"]["minimum"]==1

    source=(ROOT/"apps/studio-plugin/src/Commands/Place.lua").read_text(encoding="utf-8")
    dispatcher=(ROOT/"apps/studio-plugin/src/Dispatcher.lua").read_text(encoding="utf-8")

    assert 'AssetService:SavePlaceAsync(request)' in source
    assert 'params.confirmOverwrite ~= true' in source
    assert 'not saveWithoutPublish and params.confirmPublish ~= true' in source
    assert 'RunService:IsRunning()' in source
    assert '["studio.save_place"] = PlaceCommands.save' in dispatcher


def test_native_multiplayer_and_multiplace_surface_is_guarded() -> None:
    schema=json.loads((ROOT/"schemas"/"bridge-commands.v1.json").read_text(encoding="utf-8"))
    commands=schema["commands"]

    add_players=commands["test.add_players"]
    assert add_players["contexts"]==["server","run"]
    assert add_players["effect"]=="context-transition"
    assert add_players["params"]["properties"]["count"]["maximum"]==8

    list_places=commands["studio.list_places"]
    assert list_places["effect"]=="read"
    assert list_places["contexts"]==["edit"]

    create_place=commands["studio.create_place"]
    assert create_place["effect"]=="mutation"
    assert create_place["idempotency"]=="at-most-once"
    assert set(create_place["params"]["required"])=={
        "confirmCreate","name","templatePlaceId"
    }

    testing=(ROOT/"apps/studio-plugin/src/Commands/Testing.lua").read_text(encoding="utf-8")
    place=(ROOT/"apps/studio-plugin/src/Commands/Place.lua").read_text(encoding="utf-8")
    assert 'native:AddPlayers(count)' in testing
    assert 'AssetService:GetGamePlacesAsync()' in place
    assert 'params.confirmCreate ~= true' in place
    assert 'AssetService:CreatePlaceAsync(name, templatePlaceId, description)' in place


def test_current_studio_plugin_native_api_surface_compiles() -> None:
    failures=check_all(
        ROOT,
        source_roots=("apps/studio-plugin",),
        allow_download=False,
    )
    assert not failures,[str(item) for item in failures[:20]]

    dispatcher=(ROOT/"apps/studio-plugin/src/Dispatcher.lua").read_text(encoding="utf-8")
    for method in (
        "test.start",
        "test.status",
        "test.finish",
        "test.add_players",
        "test.device",
        "studio.capture_background",
        "studio.save_place",
        "studio.list_places",
        "studio.create_place",
        "code.write",
    ):
        assert f'["{method}"]' in dispatcher,method
