from __future__ import annotations

from rqe.bridge.adapters import StudioGameAdapter
from rqe.bridge.models import AgentAction
from rqe.bridge.studio_mcp import FederatedStudioTransport
from rqe.bridge.transport import RecordingTransport


def test_studio_adapter_accepts_official_multimodal_capture_and_list_console() -> None:
    frame={
        "content":[
            {"type":"image","data":"abc123","mimeType":"image/png"},
        ]
    }
    official=RecordingTransport(responses={
        "screen_capture":frame,
        "console_read":[
            {"severity":"Info","message":"ready"},
            {"severity":"Error","message":"client failed"},
        ],
    })
    extension=RecordingTransport(responses={
        "quality_probe_observe":{"visibleUi":[],"nearby":[]},
    })
    adapter=StudioGameAdapter(FederatedStudioTransport(official,extension))

    observed=adapter.observe("graybox")

    assert observed["screenshot"]==frame
    assert observed["visibleUi"]==[]
    assert observed["consoleErrors"]==[
        {"severity":"Error","message":"client failed"},
    ]


def test_studio_adapter_normalizes_text_console_and_scalar_action_result() -> None:
    official=RecordingTransport(responses={
        "screen_capture":"frame",
        "console_read":"INFO ready\nERROR bad client\nwarning only",
        "user_keyboard_input":"input delivered",
    })
    extension=RecordingTransport(responses={
        "quality_probe_observe":{},
    })
    adapter=StudioGameAdapter(FederatedStudioTransport(official,extension))

    observed=adapter.observe()
    result=adapter.execute(AgentAction("interact",{}))

    assert observed["consoleErrors"]==["ERROR bad client"]
    assert result=={"success":True,"result":"input delivered"}


def test_studio_adapter_keeps_extension_probes_off_official_transport() -> None:
    official=RecordingTransport(responses={
        "screen_capture":"frame",
        "console_read":{"errors":[]},
        "character_navigation":{"arrived":True},
    })
    extension=RecordingTransport(responses={
        "quality_probe_observe":{"visibleUi":[]},
        "quality_probe_player":{"health":100},
        "quality_probe_ui":{"visibleUi":[{"text":"GO"}]},
        "quality_probe_nearby":[{"name":"Door"}],
    })
    adapter=StudioGameAdapter(FederatedStudioTransport(official,extension))

    assert adapter.get_player()=={"health":100}
    assert adapter.get_ui()==[{"text":"GO"}]
    assert adapter.inspect_nearby()==[{"name":"Door"}]
    walk=adapter.execute(AgentAction(
        "walk_to",
        {"target":"Workspace.Door","timeout":3},
    ))
    assert walk["success"] is True
    assert walk["arrived"] is True

    official_methods=[call["method"] for call in official.calls]
    extension_methods=[call["method"] for call in extension.calls]
    assert "character_navigation" in official_methods
    assert "quality_probe_player" in extension_methods
    assert "quality_probe_player" not in official_methods
