from __future__ import annotations

import argparse
from pathlib import Path
from unittest.mock import Mock, patch

from forge import forge as forge_cli
from forge.cli import hot_reload


def _args(tmp_path: Path, *, allow_cold_reload: bool) -> argparse.Namespace:
    return argparse.Namespace(
        project=str(tmp_path),
        output=None,
        timeout=30,
        poll=0.1,
        allow_cold_reload=allow_cold_reload,
    )


def _project(tmp_path: Path) -> tuple[Path, Path]:
    (tmp_path/"default.project.json").write_text("{}",encoding="utf-8")
    place=tmp_path/f"{tmp_path.name}.rbxlx"
    place.write_text("place",encoding="utf-8")
    script=tmp_path/"src"/"server"/"Main.lua"
    script.parent.mkdir(parents=True,exist_ok=True)
    script.write_text("return {}",encoding="utf-8")
    return place,script


def test_watch_hot_change_never_cold_restarts(tmp_path: Path) -> None:
    _place,script=_project(tmp_path)
    binding=hot_reload.SourceBinding(
        script.resolve(),"ServerScriptService.Main","ModuleScript"
    )
    bridge=Mock()
    bridge.status.return_value={"sessions":[]}

    observed={}
    def run_once(project,engine,rebuild,reload_studio,**kwargs):
        assert rebuild() is True
        observed.update(reload_studio([str(script)]))

    with (
        patch.object(forge_cli,"_resolve",return_value=tmp_path),
        patch.object(forge_cli,"cmd_build",return_value=0),
        patch("forge.cli.watch.run",side_effect=run_once),
        patch("forge.cli.hot_reload.bindings",return_value={script.resolve():binding}),
        patch("forge.cli.hot_reload.classify",return_value=([binding],[])),
        patch("forge.cli.hot_reload.apply",return_value=[{"path":binding.data_model_path}]),
        patch("rqe.hub.lifecycle.ensure_studio_session",return_value={"ready":True}),
        patch("rqe.hub.lifecycle.restart_for_bridge") as cold_restart,
        patch("rqe.hub.client.StudioBridge",return_value=bridge),
    ):
        assert forge_cli.cmd_watch(_args(tmp_path,allow_cold_reload=False))==0

    assert observed["hotReloaded"]==1
    assert observed["playRestarted"] is False
    cold_restart.assert_not_called()


def test_watch_cold_change_is_fail_closed_by_default(tmp_path: Path) -> None:
    _place,script=_project(tmp_path)
    manifest=tmp_path/"default.project.json"
    bridge=Mock()
    observed={}

    def run_once(project,engine,rebuild,reload_studio,**kwargs):
        assert rebuild() is True
        observed.update(reload_studio([str(manifest)]))

    with (
        patch.object(forge_cli,"_resolve",return_value=tmp_path),
        patch.object(forge_cli,"cmd_build",return_value=0),
        patch("forge.cli.watch.run",side_effect=run_once),
        patch("forge.cli.hot_reload.bindings",return_value={}),
        patch("forge.cli.hot_reload.classify",return_value=([],[manifest.resolve()])),
        patch("rqe.hub.lifecycle.restart_for_bridge") as cold_restart,
        patch("rqe.hub.client.StudioBridge",return_value=bridge),
    ):
        assert forge_cli.cmd_watch(_args(tmp_path,allow_cold_reload=False))==0

    assert observed["coldReloadRequired"] is True
    assert observed["coldChanges"]==[str(manifest.resolve())]
    cold_restart.assert_not_called()


def test_watch_cold_restart_requires_explicit_opt_in(tmp_path: Path) -> None:
    _place,_script=_project(tmp_path)
    manifest=tmp_path/"default.project.json"
    bridge=Mock()
    observed={}

    def run_once(project,engine,rebuild,reload_studio,**kwargs):
        assert rebuild() is True
        observed.update(reload_studio([str(manifest)]))

    with (
        patch.object(forge_cli,"_resolve",return_value=tmp_path),
        patch.object(forge_cli,"cmd_build",return_value=0),
        patch("forge.cli.watch.run",side_effect=run_once),
        patch("forge.cli.hot_reload.bindings",return_value={}),
        patch("forge.cli.hot_reload.classify",return_value=([],[manifest.resolve()])),
        patch(
            "rqe.hub.lifecycle.restart_for_bridge",
            return_value={"handshake":{"sessions":[{"session":"new"}]}},
        ) as cold_restart,
        patch("rqe.hub.client.StudioBridge",return_value=bridge),
    ):
        assert forge_cli.cmd_watch(_args(tmp_path,allow_cold_reload=True))==0

    cold_restart.assert_called_once()
    assert observed["handshake"]["sessions"][0]["session"]=="new"
