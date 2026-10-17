from __future__ import annotations

from typing import Any

from ..project import Project
from ..runtime import MvpGameRuntime
from .models import AgentAction
from .transport import RpcTransport


class HeadlessGameAdapter:
    """A deterministic adapter used in CI and as the local bridge demo backend."""

    def __init__(self, project: Project, player_id: int = 101) -> None:
        self.project = project
        self.fixture = project.fixture
        self.player_id = player_id
        self.runtime = MvpGameRuntime()
        self.started = False
        self.location = "Spawn"
        self.position = [0.0, 3.0, 0.0]
        self.camera = {"lookVector": [0.0, 0.0, -1.0], "mode": "player_view"}
        self.frame = 0
        self.inventory_open = False

    def start(self) -> dict[str, Any]:
        self.runtime.spawn_player(self.player_id)
        self.started = True
        return self.observe("graybox")

    def stop(self) -> dict[str, Any]:
        self.started = False
        return {"success": True, "status": "stopped"}

    def _raw_state(self) -> dict[str, Any]:
        player = self.runtime.players[self.player_id]
        ui = [
            {"name": "CurrencyLabel", "text": f"${player.currency}", "visible": True},
            {"name": "InventoryButton", "text": "Inventory", "visible": True},
            {"name": "InventoryPanel", "text": "Inventory: " + ", ".join(player.inventory), "visible": self.inventory_open},
            {"name": "PurchasePrompt", "text": "[E] Buy mining pack - $100", "visible": self.location == "BasicPackStore"},
        ]
        nearby = []
        if self.location in {"MainPlaza", "BasicPackStore"}:
            nearby.append({"type": "ProximityPrompt", "name": "PurchasePrompt", "distance": 4.8, "actionText": "Buy mining pack"})
        return {
            "player": {
                "position": list(self.position),
                "health": 100,
                "velocity": [0.0, 0.0, 0.0],
                "grounded": True,
                "location": self.location,
                "currency": player.currency,
                "inventory": list(player.inventory),
                "plot": player.plot,
            },
            "camera": dict(self.camera),
            "visibleUi": ui,
            "nearby": nearby,
            "events": self.runtime.events[-5:],
            "consoleErrors": [],
            "screenshot": f"headless://frame/{self.frame:06d}.png",
        }

    def observe(self, mode: str = "blackbox") -> dict[str, Any]:
        raw = self._raw_state()
        self.frame += 1
        if mode == "blackbox":
            return {
                "mode": mode,
                "screenshot": raw["screenshot"],
                "visibleUi": [{"text": item["text"], "visible": item["visible"]} for item in raw["visibleUi"] if item["visible"]],
                "nearby": [{"type": item["type"], "name": item["name"], "distance": item["distance"], "actionText": item["actionText"]} for item in raw["nearby"]],
                "events": [{"event": item["event"], "success": item.get("success")} for item in raw["events"]],
            }
        if mode == "graybox":
            return {"mode": mode, **raw}
        if mode == "whitebox":
            return {
                "mode": mode,
                **raw,
                "diagnostics": {
                    "workspacePath": "Workspace.Map." + self.location,
                    "plotOwner": self.runtime.plots.get(self.runtime.players[self.player_id].plot),
                    "remotes": [{"name": "PurchaseBasicPack", "serverAuthoritative": True}],
                    "dataStoreKey": f"player_{self.player_id}",
                },
            }
        raise ValueError(f"unknown observation mode: {mode}")

    def execute(self, action: AgentAction) -> dict[str, Any]:
        if not self.started:
            return {"success": False, "reason": "game_not_started"}
        action_type = action.type
        params = action.params
        if action_type == "walk_to":
            return self.walk_to(str(params.get("target", "")), float(params.get("timeout", 8)), str(params.get("controller", "human")))
        if action_type == "interact":
            return self.interact(str(params.get("target", "")))
        if action_type in {"keyboard", "keyboard_sequence", "key_down", "key_up"}:
            keys = [params.get("key")] if action_type in {"keyboard", "key_down", "key_up"} else list(params.get("keys", []))
            if "E" in keys and self.location == "BasicPackStore":
                return self.interact("PurchasePrompt")
            if keys:
                self.location = "MainPlaza" if self.location == "Spawn" and "W" in keys else self.location
            return {"success": True, "controller": "human", "keys": keys, "durationMs": params.get("duration_ms", 250)}
        if action_type in {"mouse_click", "mouse_move"}:
            target = str(params.get("target", ""))
            if action_type == "mouse_click":
                return self.interact(target) if target else {"success": True, "clicked": [params.get("x"), params.get("y")]}
            return {"success": True, "moved": [params.get("x"), params.get("y")]}
        if action_type == "look":
            self.camera["lookVector"] = [params.get("dx", 0), params.get("dy", 0), -1]
            return {"success": True, "camera": self.camera}
        if action_type == "jump":
            return {"success": True, "groundedAfter": True}
        if action_type == "wait":
            return {"success": True, "elapsedMs": params.get("duration_ms", 250)}
        if action_type == "open_inventory":
            self.inventory_open = True
            return {"success": True, "opened": "InventoryPanel"}
        if action_type == "click_button":
            name = str(params.get("name", ""))
            if name.lower() in {"buy", "purchase", "purchaseprompt"}:
                return self.interact("PurchasePrompt")
            if name.lower() == "inventory":
                self.inventory_open = True
            return {"success": True, "clicked": name}
        if action_type == "disconnect":
            self.runtime.disconnect(self.player_id)
            return {"success": True, "status": "disconnected"}
        if action_type == "reconnect":
            self.runtime.reconnect(self.player_id)
            return {"success": True, "status": "reconnected"}
        return {"success": False, "reason": f"unsupported_action:{action_type}"}

    def walk_to(self, target: str, timeout: float = 8, controller: str = "human") -> dict[str, Any]:
        path_exists = bool(self.fixture.get("validation", {}).get("pathExists"))
        if not path_exists:
            return {"success": False, "reason": "character_blocked", "target": target, "attemptedActions": 17}
        route = self.fixture.get("validation", {}).get("path", [])
        self.location = target
        positions = {
            "Spawn": [0.0, 3.0, 0.0],
            "MainPlaza": [0.0, 3.0, -28.0],
            "BasicPackStore": [0.0, 3.0, -45.0],
            "PlayerPlot": [25.0, 3.0, -75.0],
        }
        self.position = positions.get(target, self.position)
        actions = [{"type": "keyboard_sequence", "keys": ["W", "W", "D", "W"]}] if controller == "human" else [{"type": "path_waypoint", "target": waypoint} for waypoint in route]
        return {"success": True, "controller": controller, "target": target, "elapsed": min(timeout, 3.27), "distance": 4.84, "route": route, "actions": actions}

    def interact(self, target: str) -> dict[str, Any]:
        if target not in {"PurchasePrompt", "BuyPack", "PurchaseBasicPack"}:
            return {"success": False, "reason": "interactable_not_found", "target": target}
        purchased = self.runtime.purchase_basic_pack(self.player_id)
        if purchased:
            return {"success": True, "target": target, "event": "package_purchased", "currencyDelta": -100, "inventoryDelta": 1}
        return {"success": False, "reason": "already_purchased_or_insufficient_funds", "target": target, "idempotent": True}

    def spawn_agents(self, count: int) -> list[dict[str, Any]]:
        agents = []
        for index in range(count):
            user_id = 101 + index
            player = self.runtime.spawn_player(user_id)
            agents.append({"agentId": index + 1, "userId": user_id, "plot": player.plot, "role": "player"})
        return agents

    def get_player(self) -> dict[str, Any]:
        return self._raw_state()["player"]

    def get_ui(self, mode: str = "graybox") -> list[dict[str, Any]]:
        return self.observe(mode).get("visibleUi", [])

    def inspect_nearby(self, mode: str = "graybox") -> list[dict[str, Any]]:
        return self.observe(mode).get("nearby", [])

    def raycast(self, origin: list[float], direction: list[float]) -> dict[str, Any]:
        return {"hit": False, "origin": origin, "direction": direction, "instance": None}


class StudioGameAdapter:
    """Adapter for a local Studio relay or an official Studio MCP gateway.

    The transport is deliberately injected: production can provide an MCP
    connector, while CI can use RecordingTransport without launching Studio.
    """

    def __init__(self, transport: RpcTransport) -> None:
        self.transport = transport

    @staticmethod
    def _successful(value: Any) -> dict[str, Any]:
        """Normalize successful tool payloads without inventing tool details."""
        if isinstance(value, dict):
            result = dict(value)
            result.setdefault("success", True)
            return result
        if value is None:
            return {"success": True}
        return {"success": True, "result": value}

    @staticmethod
    def _console_errors(value: Any) -> list[Any]:
        if isinstance(value, dict):
            explicit = value.get("errors")
            if isinstance(explicit, list):
                return explicit
            entries = (
                value.get("entries")
                or value.get("messages")
                or value.get("output")
                or []
            )
        elif isinstance(value, list):
            entries = value
        elif isinstance(value, str):
            return [
                line for line in value.splitlines()
                if "error" in line.casefold()
            ]
        else:
            return []

        if not isinstance(entries, list):
            return []
        errors = []
        for entry in entries:
            if isinstance(entry, dict):
                severity = str(
                    entry.get("severity")
                    or entry.get("type")
                    or entry.get("messageType")
                    or ""
                ).casefold()
                if "error" in severity:
                    errors.append(entry)
            elif "error" in str(entry).casefold():
                errors.append(entry)
        return errors

    def start(self) -> dict[str, Any]:
        self.transport.call("playtest_start", {})
        return self.observe("graybox")

    def stop(self) -> dict[str, Any]:
        return self._successful(self.transport.call("playtest_stop", {}))

    def observe(self, mode: str = "blackbox") -> dict[str, Any]:
        screen = self.transport.call("screen_capture", {"camera": "player_view"})
        console = self.transport.call("console_read", {})
        state_raw = self.transport.call(
            "quality_probe_observe",
            {"mode": mode},
        )
        state = dict(state_raw) if isinstance(state_raw, dict) else {}
        if state_raw not in (None, {}) and not isinstance(state_raw, dict):
            state["probeResult"] = state_raw
        return {
            "mode": mode,
            **state,
            "screenshot": screen,
            "consoleErrors": self._console_errors(console),
        }

    def execute(self, action: AgentAction) -> dict[str, Any]:
        p = action.params
        if action.type in {"keyboard", "keyboard_sequence", "key_down", "key_up"}:
            return self._successful(self.transport.call(
                "user_keyboard_input",
                {
                    "keys": p.get("keys", [p.get("key")]),
                    "duration_ms": p.get("duration_ms", 250),
                },
            ))
        if action.type in {"mouse_click", "mouse_move"}:
            action_name = "click" if action.type == "mouse_click" else "move"
            return self._successful(self.transport.call(
                "user_mouse_input",
                {"action": action_name, **p},
            ))
        if action.type == "look":
            return self._successful(self.transport.call(
                "user_mouse_input",
                {"action": "move", **p},
            ))
        if action.type == "walk_to":
            return self._successful(self.transport.call(
                "character_navigation",
                {
                    "target": p.get("target"),
                    "timeout": p.get("timeout", 8),
                    "mode": p.get("controller", "human"),
                },
            ))
        if action.type == "interact":
            return self._successful(self.transport.call(
                "user_keyboard_input",
                {"keys": ["E"], "duration_ms": 150},
            ))
        return self._successful(
            self.transport.call("game_act", action.to_dict())
        )

    def get_player(self) -> dict[str, Any]:
        return self.transport.call("quality_probe_player", {}) or {}

    def get_ui(self, mode: str = "graybox") -> list[dict[str, Any]]:
        return (self.transport.call("quality_probe_ui", {"mode": mode}) or {}).get("visibleUi", [])

    def inspect_nearby(self, mode: str = "graybox") -> list[dict[str, Any]]:
        return self.transport.call("quality_probe_nearby", {"mode": mode}) or []

    def raycast(self, origin: list[float], direction: list[float]) -> dict[str, Any]:
        return self.transport.call("quality_probe_raycast", {"origin": origin, "direction": direction}) or {}
