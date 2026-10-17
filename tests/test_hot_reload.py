from __future__ import annotations

import contextlib
from pathlib import Path
from unittest.mock import Mock

from forge.cli import hot_reload


def test_sourcemap_flattens_source_to_datamodel_path(tmp_path: Path) -> None:
    project=tmp_path/"default.project.json"
    project.write_text("{}",encoding="utf-8")
    server=tmp_path/"src"/"server"/"init.server.lua"
    world=tmp_path/"src"/"server"/"World.lua"
    client=tmp_path/"src"/"client"/"init.client.lua"
    for path in (server,world,client):
        path.parent.mkdir(parents=True,exist_ok=True)
        path.write_text("-- source",encoding="utf-8")

    payload={
        "name":"g","className":"DataModel","children":[
            {"name":"ServerScriptService","className":"ServerScriptService","children":[
                {"name":"Game","className":"Script","filePaths":["src/server/init.server.lua"],"children":[
                    {"name":"World","className":"ModuleScript","filePaths":["src/server/World.lua"]}
                ]}
            ]},
            {"name":"StarterPlayer","className":"StarterPlayer","children":[
                {"name":"StarterPlayerScripts","className":"StarterPlayerScripts","children":[
                    {"name":"Game","className":"LocalScript","filePaths":["src/client/init.client.lua"]}
                ]}
            ]}
        ]
    }

    mapped=hot_reload.bindings(project,payload)
    assert mapped[server.resolve()].data_model_path=="ServerScriptService.Game"
    assert mapped[server.resolve()].kind=="server"
    assert mapped[world.resolve()].data_model_path=="ServerScriptService.Game.World"
    assert mapped[world.resolve()].kind=="module"
    assert mapped[client.resolve()].data_model_path=="StarterPlayer.StarterPlayerScripts.Game"
    assert mapped[client.resolve()].kind=="client"


def test_classify_fails_closed_for_deleted_or_unmapped_changes(tmp_path: Path) -> None:
    good=tmp_path/"Good.lua"
    good.write_text("return {}",encoding="utf-8")
    deleted=tmp_path/"Deleted.lua"
    manifest=tmp_path/"default.project.json"
    manifest.write_text("{}",encoding="utf-8")

    mapping={
        good.resolve():hot_reload.SourceBinding(
            source=good.resolve(),
            data_model_path="ReplicatedStorage.Good",
            class_name="ModuleScript",
        ),
        deleted.resolve():hot_reload.SourceBinding(
            source=deleted.resolve(),
            data_model_path="ReplicatedStorage.Deleted",
            class_name="ModuleScript",
        ),
    }

    hot,cold=hot_reload.classify([good,deleted,manifest],mapping)
    assert [item.source for item in hot]==[good.resolve()]
    assert set(cold)=={deleted.resolve(),manifest.resolve()}


def test_apply_uses_native_code_commands_in_edit_context(tmp_path: Path) -> None:
    module=tmp_path/"Module.lua"
    server=tmp_path/"Server.server.lua"
    module.write_text("return {v=2}",encoding="utf-8")
    server.write_text("print('ok')",encoding="utf-8")

    bridge=Mock()
    bridge.pin_to_context.return_value="sess-edit"
    bridge.lease_scope.return_value=contextlib.nullcontext({})
    def answer(method,params,timeout=30):
        if method=="code.compile":
            return {"compiles":True}
        return {"method":method,"path":params["path"]}
    bridge.call.side_effect=answer

    receipts=hot_reload.apply(bridge,[
        hot_reload.SourceBinding(module.resolve(),"ReplicatedStorage.Module","ModuleScript"),
        hot_reload.SourceBinding(server.resolve(),"ServerScriptService.Server","Script"),
    ])

    bridge.pin_to_context.assert_called_once_with("edit",timeout=15)
    calls=[call.args[0] for call in bridge.call.call_args_list]
    assert calls==["code.compile","code.compile","code.reload","code.write"]
    assert receipts[0]["method"]=="code.reload"
    assert receipts[1]["method"]=="code.write"
    assert bridge.call.call_args_list[3].args[1]["kind"]=="server"


def test_apply_compiles_whole_batch_before_mutating(tmp_path: Path) -> None:
    first=tmp_path/"First.lua"
    second=tmp_path/"Second.lua"
    first.write_text("return {}",encoding="utf-8")
    second.write_text("this is broken",encoding="utf-8")

    bridge=Mock()
    bridge.pin_to_context.return_value="sess-edit"
    bridge.lease_scope.return_value=contextlib.nullcontext({})

    compile_count=0
    def answer(method,params,timeout=30):
        nonlocal compile_count
        if method=="code.compile":
            compile_count+=1
            return {"compiles":compile_count==1,"error":"syntax error" if compile_count==2 else None}
        raise AssertionError(f"mutation should not run after compile failure: {method}")

    bridge.call.side_effect=answer

    try:
        hot_reload.apply(bridge,[
            hot_reload.SourceBinding(first.resolve(),"ReplicatedStorage.First","ModuleScript"),
            hot_reload.SourceBinding(second.resolve(),"ReplicatedStorage.Second","ModuleScript"),
        ])
    except RuntimeError as exc:
        assert "does not compile" in str(exc)
    else:
        raise AssertionError("expected compile failure")

    assert [call.args[0] for call in bridge.call.call_args_list]==[
        "code.compile","code.compile"
    ]
