from __future__ import annotations

import json
from pathlib import Path
from typing import Any

from .models import ActionRecord, AgentAction, MODES


class GameAgentBridge:
    """Public agent API: game.start/observe/act/... with evidence recording."""

    OPERATIONS = [
        "game.start", "game.stop", "game.observe", "game.act", "game.walk", "game.navigate_human", "game.navigate_pathfinding", "game.navigate_direct", "game.look",
        "game.interact", "game.find", "game.open_inventory", "game.click_button",
        "game.explore_area", "game.return_to_plot", "game.inspect_nearby", "game.get_ui", "game.get_player",
        "game.raycast", "game.run_scenario", "game.assert", "game.replay", "game.spawn_agents",
    ]

    def __init__(self, adapter: Any, mode: str = "blackbox") -> None:
        if mode not in MODES:
            raise ValueError(f"mode must be one of {sorted(MODES)}")
        self.adapter = adapter
        self.mode = mode
        self.memory: list[dict[str, Any]] = []
        self.action_records: list[ActionRecord] = []
        self.started = False
        self._initial_player: dict[str, Any] | None = None

    def start(self, mode: str | None = None) -> dict[str, Any]:
        if mode:
            if mode not in MODES:
                raise ValueError(f"mode must be one of {sorted(MODES)}")
            self.mode = mode
        result = self.adapter.start()
        self.started = True
        self._initial_player = dict(self.adapter.get_player())
        observation = self.observe()
        return {"success": True, "observation": observation, "adapterResult": result}

    def stop(self) -> dict[str, Any]:
        result = self.adapter.stop()
        self.started = False
        return result

    def observe(self, mode: str | None = None) -> dict[str, Any]:
        observation = self.adapter.observe(mode or self.mode)
        self.memory.append({"kind": "observation", "observation": observation})
        return observation

    def act(self, action: dict[str, Any] | AgentAction) -> dict[str, Any]:
        if isinstance(action, dict):
            payload = dict(action)
            action_type = str(payload.pop("type", payload.pop("action", "")))
            request = AgentAction(action_type, payload)
        else:
            request = action
        if not request.type:
            raise ValueError("action requires type")
        before = self.observe()
        result = self.adapter.execute(request)
        after = self.observe()
        success = bool(result.get("success"))
        record = ActionRecord(
            sequence=len(self.action_records) + 1,
            before=before,
            action=request.to_dict(),
            after=after,
            result="PASS" if success else "FAIL",
            reason=result.get("reason"),
            details=result,
        )
        self.action_records.append(record)
        self.memory.append({"kind": "action", "record": record.to_dict()})
        return {"success": success, "result": result, "evidence": record.to_dict()}

    def walk(self, target: str, timeout: float = 8) -> dict[str, Any]:
        return self.navigate_human(target, timeout)

    def navigate_human(self, target: str, timeout: float = 8) -> dict[str, Any]:
        return self.act({"type": "walk_to", "target": target, "timeout": timeout, "controller": "human"})

    def navigate_pathfinding(self, target: str, timeout: float = 8) -> dict[str, Any]:
        return self.act({"type": "walk_to", "target": target, "timeout": timeout, "controller": "pathfinding"})

    def navigate_direct(self, target: str) -> dict[str, Any]:
        if self.mode == "blackbox":
            return {"success": False, "reason": "direct_navigation_forbidden_in_blackbox"}
        return self.act({"type": "walk_to", "target": target, "timeout": 0, "controller": "direct"})

    def look(self, dx: float, dy: float) -> dict[str, Any]:
        return self.act({"type": "look", "dx": dx, "dy": dy})

    def interact(self, target: str = "PurchasePrompt") -> dict[str, Any]:
        return self.act({"type": "interact", "target": target})

    def find(self, query: str) -> list[dict[str, Any]]:
        nearby = self.adapter.inspect_nearby(self.mode)
        return [item for item in nearby if query.lower() in str(item.get("name", "")).lower() or query.lower() in str(item.get("actionText", "")).lower()]

    def open_inventory(self) -> dict[str, Any]:
        return self.act({"type": "open_inventory"})

    def click_button(self, name: str) -> dict[str, Any]:
        return self.act({"type": "click_button", "name": name})

    def explore_area(self, area: str = "MainPlaza") -> dict[str, Any]:
        return self.walk(area)

    def return_to_plot(self) -> dict[str, Any]:
        return self.walk("PlayerPlot")

    def inspect_nearby(self) -> list[dict[str, Any]]:
        return self.adapter.inspect_nearby(self.mode)

    def get_ui(self) -> list[dict[str, Any]]:
        return self.adapter.get_ui(self.mode)

    def get_player(self) -> dict[str, Any]:
        return self.adapter.get_player()

    def raycast(self, origin: list[float], direction: list[float]) -> dict[str, Any]:
        return self.adapter.raycast(origin, direction)

    def assert_state(self, assertion: dict[str, Any]) -> dict[str, Any]:
        player = self.adapter.get_player()
        assertion_type = assertion.get("type", assertion.get("assert", ""))
        passed = False
        details: dict[str, Any] = {"assertion": assertion}
        if assertion_type == "currency_equals":
            passed = player.get("currency") == assertion.get("value")
            details.update(expected=assertion.get("value"), actual=player.get("currency"))
        elif assertion_type == "currency_delta":
            initial = (self._initial_player or {}).get("currency")
            actual = player.get("currency", 0) - (initial or 0)
            passed = actual == assertion.get("value")
            details.update(expected=assertion.get("value"), actual=actual)
        elif assertion_type == "inventory_count":
            actual = len(player.get("inventory", []))
            passed = actual == assertion.get("value")
            details.update(expected=assertion.get("value"), actual=actual)
        elif assertion_type == "inventory_contains":
            passed = assertion.get("value") in player.get("inventory", [])
            details.update(expected=assertion.get("value"), actual=player.get("inventory", []))
        elif assertion_type == "visible_text":
            expected = str(assertion.get("value"))
            ui = self.adapter.get_ui("blackbox")
            passed = any(expected in str(item.get("text", "")) for item in ui)
            details.update(expected=expected, actual=ui)
        else:
            details["reason"] = "unsupported_assertion"
        self.memory.append({"kind": "assertion", "status": "PASS" if passed else "FAIL", "details": details})
        return {"success": passed, "status": "PASS" if passed else "FAIL", "details": details}

    def run_scenario(self, scenario: dict[str, Any]) -> dict[str, Any]:
        if not self.started:
            self.start(scenario.get("mode", self.mode))
        results: list[dict[str, Any]] = []
        for step in scenario.get("steps", []):
            if "action" in step:
                result = self.act(step["action"])
            elif "walk_to" in step:
                result = self.walk(step["walk_to"], step.get("timeout", 8))
            elif "interact" in step:
                result = self.interact(step["interact"])
            elif "assert" in step:
                result = self.assert_state(step["assert"])
            elif "observe" in step:
                result = {"success": True, "observation": self.observe(step.get("observe") or self.mode)}
            elif "wait" in step:
                result = self.act({"type": "wait", "duration_ms": step["wait"]})
            else:
                result = {"success": False, "reason": "unsupported_scenario_step", "step": step}
            expected_success = step.get("expectSuccess", True)
            step_passed = result.get("success", False) == expected_success
            results.append({"step": step, "result": result, "passed": step_passed})
            if not step_passed and step.get("fatal", True):
                break
        passed = bool(results) and all(item["passed"] for item in results)
        return {
            "scenario": scenario.get("id", "unnamed"),
            "mode": self.mode,
            "status": "PASS" if passed else "FAIL",
            "stepsExecuted": len(results),
            "steps": results,
            "actionRecords": [record.to_dict() for record in self.action_records],
            "memoryEntries": len(self.memory),
        }

    def replay(self, records: list[dict[str, Any]] | None = None) -> dict[str, Any]:
        records = records or [record.to_dict() for record in self.action_records]
        replayed: list[dict[str, Any]] = []
        for record in records:
            replayed.append(self.act(record["action"]))
        return {"status": "PASS" if all(item["success"] for item in replayed) else "FAIL", "actions": replayed}

    def spawn_agents(self, count: int, roles: list[str] | None = None) -> dict[str, Any]:
        if count < 1 or count > 8:
            return {"success": False, "reason": "count_must_be_between_1_and_8"}
        if hasattr(self.adapter, "spawn_agents"):
            agents = self.adapter.spawn_agents(count)
        else:
            agents = [{"agentId": index + 1, "role": (roles or ["player"])[index % len(roles or ["player"])]} for index in range(count)]
        self.memory.append({"kind": "spawn_agents", "agents": agents})
        return {"success": True, "agents": agents, "maxSupported": 8}

    def session(self) -> dict[str, Any]:
        return {
            "bridge": {"name": "Game Agent Bridge", "version": "0.1.0", "mode": self.mode},
            "started": self.started,
            "operations": self.OPERATIONS,
            "memory": self.memory,
            "actionRecords": [record.to_dict() for record in self.action_records],
        }

    def save_session(self, path: str | Path) -> Path:
        output = Path(path)
        output.parent.mkdir(parents=True, exist_ok=True)
        output.write_text(json.dumps(self.session(), indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
        return output

    def dispatch(self, method: str, params: dict[str, Any] | None = None) -> Any:
        params = params or {}
        routes = {
            "game.start": lambda: self.start(params.get("mode")),
            "game.stop": self.stop,
            "game.observe": lambda: self.observe(params.get("mode")),
            "game.act": lambda: self.act(params.get("action", params)),
            "game.walk": lambda: self.walk(params["target"], params.get("timeout", 8)),
            "game.navigate_human": lambda: self.navigate_human(params["target"], params.get("timeout", 8)),
            "game.navigate_pathfinding": lambda: self.navigate_pathfinding(params["target"], params.get("timeout", 8)),
            "game.navigate_direct": lambda: self.navigate_direct(params["target"]),
            "game.look": lambda: self.look(params.get("dx", 0), params.get("dy", 0)),
            "game.interact": lambda: self.interact(params.get("target", "PurchasePrompt")),
            "game.find": lambda: self.find(params.get("query", "")),
            "game.open_inventory": self.open_inventory,
            "game.click_button": lambda: self.click_button(params.get("name", "")),
            "game.explore_area": lambda: self.explore_area(params.get("area", "MainPlaza")),
            "game.return_to_plot": self.return_to_plot,
            "game.inspect_nearby": self.inspect_nearby,
            "game.get_ui": self.get_ui,
            "game.get_player": self.get_player,
            "game.raycast": lambda: self.raycast(params["origin"], params["direction"]),
            "game.run_scenario": lambda: self.run_scenario(params["scenario"]),
            "game.assert": lambda: self.assert_state(params["assertion"]),
            "game.replay": lambda: self.replay(params.get("records")),
            "game.spawn_agents": lambda: self.spawn_agents(params.get("count", 1), params.get("roles")),
        }
        if method not in routes:
            raise KeyError(f"unknown bridge operation: {method}")
        return routes[method]()
