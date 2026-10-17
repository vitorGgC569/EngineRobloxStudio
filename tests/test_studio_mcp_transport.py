from __future__ import annotations
from typing import Any

import pytest

from rqe.bridge.studio_mcp import (
    FederatedStudioTransport,
    NativeStudioMcpError,
    NativeStudioToolUnavailable,
    RobloxStudioMcpTransport,
)
from rqe.bridge.transport import RecordingTransport


def tool(name: str, *properties: str) -> dict[str, Any]:
    return {
        "name": name,
        "inputSchema": {
            "type": "object",
            "properties": {key: {} for key in properties},
            "additionalProperties": False,
        },
    }


class FakeMcp:
    def __init__(self) -> None:
        self.calls: list[tuple[str, dict[str, Any]]] = []
        self.closed = False
        self.tools = [
            tool("list_roblox_studios"),
            tool("start_stop_play", "studio_id", "is_start"),
            tool(
                "screen_capture",
                "studio_id",
                "capture_id",
                "camera_position",
                "look_at_position",
            ),
            tool("get_console_output", "studio_id"),
            tool(
                "search_game_tree",
                "studio_id",
                "keywords",
                "max_depth",
                "head_limit",
            ),
            tool(
                "character_navigation",
                "studio_id",
                "datamodel_type",
                "instance_path",
                "x",
                "y",
                "z",
                "speed_multiplier",
            ),
            tool(
                "user_keyboard_input",
                "studio_id",
                "datamodel_type",
                "actions",
            ),
            tool(
                "user_mouse_input",
                "studio_id",
                "datamodel_type",
                "actions",
            ),
        ]
        self.studios = [
            {"studio_id": "studio-a", "name": "EchoRiot", "place_id": 111},
            {"studio_id": "studio-b", "name": "OtherGame", "place_id": 222},
        ]

    def list_tools(self) -> list[dict[str, Any]]:
        return list(self.tools)

    def call_tool(self, name: str, arguments: dict[str, Any]) -> Any:
        self.calls.append((name, dict(arguments)))
        if name == "list_roblox_studios":
            return {"studios": list(self.studios)}
        if name == "search_game_tree":
            keyword=str(arguments.get("keywords") or "")
            return [
                {
                    "name":keyword,
                    "className":"Part",
                    "fullPath":f"Workspace.Hub.{keyword}",
                }
            ]
        return {"tool": name, "arguments": dict(arguments)}

    def close(self) -> None:
        self.closed = True


def test_selects_exact_studio_and_injects_studio_id() -> None:
    client = FakeMcp()
    transport = RobloxStudioMcpTransport(client, place_name="EchoRiot")

    result = transport.call("playtest_start", {"mode": "Play"})

    assert result["tool"] == "start_stop_play"
    assert result["arguments"] == {
        "studio_id": "studio-a",
        "is_start": True,
    }
    assert transport.studio_id == "studio-a"


def test_multiple_studios_never_choose_first_implicitly() -> None:
    transport = RobloxStudioMcpTransport(FakeMcp())
    with pytest.raises(NativeStudioMcpError, match="ambiguous"):
        transport.call("console_read", {})


def test_place_id_disambiguates_duplicate_names() -> None:
    client = FakeMcp()
    client.studios = [
        {"studio_id": "old", "name": "EchoRiot", "place_id": 100},
        {"studio_id": "wanted", "name": "EchoRiot", "place_id": 200},
    ]
    transport = RobloxStudioMcpTransport(
        client,
        place_name="EchoRiot",
        place_id=200,
    )

    result = transport.call("console_read", {})
    assert result["arguments"]["studio_id"] == "wanted"


def test_keyboard_canonical_shape_maps_to_official_actions() -> None:
    transport = RobloxStudioMcpTransport(FakeMcp(), studio_id="studio-a")
    result = transport.call(
        "user_keyboard_input",
        {"keys": ["E", "Space"], "duration_ms": 125},
    )

    args = result["arguments"]
    assert args["studio_id"] == "studio-a"
    assert args["datamodel_type"] == "Client"
    assert args["actions"] == [
        {"action": "keyPress", "key_code": "E"},
        {"action": "keyPress", "key_code": "Space"},
        {"action": "wait", "wait_time_ms": 125.0},
    ]


def test_mouse_and_navigation_map_without_guessing_semantic_targets() -> None:
    transport = RobloxStudioMcpTransport(FakeMcp(), studio_id="studio-a")

    mouse = transport.call(
        "user_mouse_input",
        {"action": "click", "x": 120, "y": 240},
    )
    assert mouse["arguments"]["actions"] == [{
        "action": "mouseButtonClick",
        "x": 120,
        "y": 240,
        "mouse_button": "left",
    }]

    nav = transport.call(
        "character_navigation",
        {"target": "Workspace.Hub.QueueConsole", "speed_multiplier": 1.5},
    )
    assert nav["arguments"]["instance_path"] == "Workspace.Hub.QueueConsole"
    assert nav["arguments"]["speed_multiplier"] == 1.5

    semantic = transport.call(
        "character_navigation",
        {"target": "QueueConsole"},
    )
    assert semantic["arguments"]["instance_path"] == "Workspace.Hub.QueueConsole"


def test_semantic_navigation_rejects_ambiguous_exact_names() -> None:
    class AmbiguousMcp(FakeMcp):
        def call_tool(self, name: str, arguments: dict[str, Any]) -> Any:
            if name == "search_game_tree":
                self.calls.append((name, dict(arguments)))
                return [
                    {
                        "name": "Door",
                        "className": "Part",
                        "fullPath": "Workspace.Hub.Door",
                    },
                    {
                        "name": "Door",
                        "className": "Part",
                        "fullPath": "Workspace.Stage.Door",
                    },
                ]
            return super().call_tool(name, arguments)

    transport = RobloxStudioMcpTransport(
        AmbiguousMcp(),
        studio_id="studio-a",
    )
    with pytest.raises(NativeStudioMcpError, match="ambiguous"):
        transport.call("character_navigation", {"target": "Door"})


def test_screen_capture_generates_id_and_maps_camera_fields() -> None:
    transport = RobloxStudioMcpTransport(FakeMcp(), studio_id="studio-a")
    result = transport.call(
        "screen_capture",
        {
            "position": [1, 2, 3],
            "lookAt": [4, 5, 6],
            "camera": "player_view",  # canonical-only field; never forwarded
        },
    )
    args = result["arguments"]
    assert args["studio_id"] == "studio-a"
    assert args["capture_id"].startswith("rqe_capture_")
    assert args["camera_position"] == [1, 2, 3]
    assert args["look_at_position"] == [4, 5, 6]
    assert "camera" not in args


def test_capabilities_report_exact_selected_studio() -> None:
    transport = RobloxStudioMcpTransport(
        FakeMcp(),
        place_name="EchoRiot",
        place_id=111,
    )
    capabilities = transport.capabilities()
    assert capabilities["official"] is True
    assert capabilities["studioId"] == "studio-a"
    assert "screen_capture" in capabilities["tools"]
    assert "playtest_start" in capabilities["canonicalMethods"]


def test_federation_routes_official_and_rqe_extension_separately() -> None:
    official = RecordingTransport(responses={"screen_capture": "native-frame"})
    extension = RecordingTransport(
        responses={"quality_probe_observe": {"quality": "rqe"}}
    )
    transport = FederatedStudioTransport(official, extension)

    assert transport.call("screen_capture", {}) == "native-frame"
    assert transport.call("quality_probe_observe", {}) == {"quality": "rqe"}
    assert [c["method"] for c in official.calls] == ["screen_capture"]
    assert [c["method"] for c in extension.calls] == ["quality_probe_observe"]


class MissingOfficial:
    def call(self, method: str, params: dict[str, Any] | None = None) -> Any:
        raise NativeStudioToolUnavailable(method)


def test_official_missing_does_not_silently_fallback_by_default() -> None:
    extension = RecordingTransport(responses={"screen_capture": "legacy"})
    transport = FederatedStudioTransport(MissingOfficial(), extension)

    with pytest.raises(NativeStudioToolUnavailable):
        transport.call("screen_capture", {})
    assert extension.calls == []


def test_explicit_extension_fallback_is_available_for_compatibility() -> None:
    extension = RecordingTransport(responses={"screen_capture": "legacy"})
    transport = FederatedStudioTransport(
        MissingOfficial(),
        extension,
        allow_extension_fallback=True,
    )

    assert transport.call("screen_capture", {}) == "legacy"
    assert extension.calls[0]["method"] == "screen_capture"
