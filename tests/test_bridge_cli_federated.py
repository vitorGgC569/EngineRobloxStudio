from __future__ import annotations
from pathlib import Path

import rqe.cli as cli

ROOT=Path(__file__).resolve().parents[1]


def test_bridge_serve_parser_accepts_federated_studio_selection() -> None:
    args=cli.build_parser().parse_args([
        "bridge","serve",str(ROOT),
        "--backend","federated",
        "--studio-url","http://127.0.0.1:8765",
        "--studio-id","studio-abc",
        "--studio-place-name","EchoRiot",
        "--studio-place-id","12345",
    ])
    assert args.backend=="federated"
    assert args.studio_url=="http://127.0.0.1:8765"
    assert args.studio_id=="studio-abc"
    assert args.studio_place_name=="EchoRiot"
    assert args.studio_place_id==12345


def test_bridge_serve_legacy_default_stays_headless_without_studio_url() -> None:
    args=cli.build_parser().parse_args(["bridge","serve",str(ROOT)])
    assert args.backend is None
    assert args.studio_url is None


def test_federated_backend_requires_explicit_extension_url() -> None:
    args=cli.build_parser().parse_args([
        "bridge","serve",str(ROOT),"--backend","federated",
    ])
    try:
        cli._run_bridge(args)
    except SystemExit as exc:
        assert "--studio-url" in str(exc)
    else:
        raise AssertionError("federated backend must fail without --studio-url")


def test_federated_backend_composes_official_and_extension(monkeypatch) -> None:
    args=cli.build_parser().parse_args([
        "bridge","serve",str(ROOT),
        "--backend","federated",
        "--studio-url","http://127.0.0.1:8765",
        "--studio-id","studio-abc",
        "--studio-place-name","EchoRiot",
        "--studio-place-id","12345",
    ])

    seen={}

    class Official:
        def __init__(self, **kwargs):
            seen["official"]=kwargs
        def call(self,*_args,**_kwargs):
            return {}

    class Extension:
        def __init__(self,url,token=None):
            seen["extension"]={"url":url,"token":token}
        def call(self,*_args,**_kwargs):
            return {}

    class Adapter:
        def __init__(self,transport):
            seen["adapterTransport"]=transport

    class Bridge:
        OPERATIONS=[]
        def __init__(self,adapter,mode):
            seen["bridge"]={"adapter":adapter,"mode":mode}

    def fake_serve(bridge,port,token=None):
        seen["serve"]={"bridge":bridge,"port":port,"token":token}

    monkeypatch.setattr(cli,"RobloxStudioMcpTransport",Official)
    monkeypatch.setattr(cli,"HttpJsonRpcTransport",Extension)
    monkeypatch.setattr(cli,"StudioGameAdapter",Adapter)
    monkeypatch.setattr(cli,"GameAgentBridge",Bridge)
    monkeypatch.setattr(cli,"serve",fake_serve)

    result=cli._run_bridge(args)

    assert result==0
    assert seen["official"]=={
        "studio_id":"studio-abc",
        "place_name":"EchoRiot",
        "place_id":12345,
    }
    assert seen["extension"]["url"]=="http://127.0.0.1:8765"
    assert seen["bridge"]["mode"]=="graybox"
    assert seen["serve"]["port"]==8765
