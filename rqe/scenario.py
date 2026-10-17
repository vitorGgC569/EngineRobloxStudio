"""Scenario runner: gameplay tests against a real, running game.

The DSL keeps the shape the repository already had -- ordered steps, each
emitting PASS/FAIL -- and replaces its backend. Steps used to be answered by a
Python re-implementation of the game's rules; they are now answered by the game
itself, through a real player character in a real play session.

A step never invents a result. If the bridge cannot perform an action the step
fails with the reason the engine gave, because "we could not test this" and
"this does not work" must stay distinguishable.
"""

from __future__ import annotations

import json
import re
import time
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

from .hub.client import StudioBridge
from .hub.protocol import BridgeError

#: Steps that need a real player, and therefore a play session.
PLAYER_STEPS = {"attach", "navigate_to", "interact", "click", "input", "gui", "player_state", "remember", "aim_at"}

#: Step metadata, never treated as something to assert on. Scenarios are meant
#: to be read by humans, so `comment` has to be free to carry the intent.
RESERVED_STEP_KEYS = {"fatal", "step", "comment", "description", "name"}

SCENARIO_ID_PATTERN = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,95}$")

SUPPORTED_STEP_KEYS = (
    "reset",
    "attach",
    "spawn",
    "navigate_to",
    "interact",
    "click",
    "input",
    "remember",
    "aim_at",
    "release_camera",
    "assert",
    "wait",
    "gui",
    "expect_prompt_in_range",
)


def scenario_document_issues(scenario: Any) -> list[str]:
    """Return executable-contract defects without trying to run the scenario.

    Scenario JSON is product input.  A malformed or legacy DSL document must
    become an explicit blocked attempt; it must not disappear from a release
    merely because the runner could not interpret it.
    """

    if not isinstance(scenario, dict):
        return ["scenario document must be an object"]
    issues: list[str] = []
    identifier = scenario.get("id") or scenario.get("scenario")
    if not isinstance(identifier, str) or not SCENARIO_ID_PATTERN.fullmatch(identifier):
        issues.append("scenario id must be a safe 1..96 character identifier")
    steps = scenario.get("steps")
    if not isinstance(steps, list) or not steps:
        issues.append("scenario steps must be a non-empty array")
        return issues
    for index, step in enumerate(steps):
        if not isinstance(step, dict):
            issues.append(f"steps[{index}] must be an object")
            continue
        if "step" in step:
            kind = step.get("step")
            if kind not in SUPPORTED_STEP_KEYS:
                issues.append(f"steps[{index}] uses unsupported step {kind!r}")
            continue
        kinds = [key for key in SUPPORTED_STEP_KEYS if key in step]
        if len(kinds) != 1:
            issues.append(
                f"steps[{index}] must contain exactly one supported action; found {kinds}"
            )
    bindings = scenario.get("releaseEvidence", [])
    if not isinstance(bindings, list):
        issues.append("releaseEvidence must be an array when present")
    else:
        seen: set[str] = set()
        for index, binding in enumerate(bindings):
            if not isinstance(binding, dict):
                issues.append(f"releaseEvidence[{index}] must be an object")
                continue
            required = ("id", "probe", "category", "severity")
            missing = [key for key in required if not isinstance(binding.get(key), str) or not binding.get(key)]
            if missing:
                issues.append(
                    f"releaseEvidence[{index}] is missing string fields: {', '.join(missing)}"
                )
            evidence_id = binding.get("id")
            if isinstance(evidence_id, str):
                if evidence_id in seen:
                    issues.append(f"releaseEvidence id is duplicated: {evidence_id}")
                seen.add(evidence_id)
    return issues


@dataclass
class StepResult:
    index: int
    kind: str
    spec: dict[str, Any]
    status: str
    detail: dict[str, Any] = field(default_factory=dict)
    reason: str | None = None
    elapsed_ms: float = 0.0

    def to_dict(self) -> dict[str, Any]:
        return {
            "index": self.index,
            "step": self.kind,
            "spec": self.spec,
            "status": self.status,
            "reason": self.reason,
            "elapsedMs": round(self.elapsed_ms, 1),
            "detail": self.detail,
        }


@dataclass
class ScenarioResult:
    scenario: str
    status: str
    steps: list[StepResult] = field(default_factory=list)
    started_at: str = ""
    validation_level: str = "NOT_VALIDATED"
    command_errors: list[dict[str, Any]] = field(default_factory=list)

    def to_dict(self) -> dict[str, Any]:
        passed = sum(1 for step in self.steps if step.status == "PASS")
        return {
            "scenario": self.scenario,
            "status": self.status,
            "validationLevel": self.validation_level,
            "startedAt": self.started_at,
            "steps": {"total": len(self.steps), "passed": passed, "failed": len(self.steps) - passed},
            "results": [step.to_dict() for step in self.steps],
            "commandErrors": list(self.command_errors),
        }

    def terminal_summary(self) -> str:
        lines = [f"SCENARIO {self.scenario}  [{self.validation_level}]  {self.status}"]
        for step in self.steps:
            mark = "PASS" if step.status == "PASS" else "FAIL"
            detail = f" - {step.reason}" if step.reason else ""
            lines.append(f"  {mark}  {step.index}. {step.kind}{detail}")
        return "\n".join(lines)


def _compare(actual: Any, expected: Any) -> tuple[bool, str]:
    """Support `"> 100"`, `"<= 5"`, `"!= x"` and plain equality."""
    if isinstance(expected, str):
        for operator in (">=", "<=", "!=", ">", "<", "=="):
            if expected.startswith(operator):
                raw = expected[len(operator):].strip()
                lowered = raw.lower()
                if lowered == "nil":
                    target: Any = None
                elif lowered == "true":
                    target = True
                elif lowered == "false":
                    target = False
                else:
                    try:
                        target = float(raw)
                    except ValueError:
                        target = raw

                if operator in {"==", "!="}:
                    ok = actual == target if operator == "==" else actual != target
                else:
                    try:
                        left = float(actual)
                        right = float(target)
                        if operator == ">":
                            ok = left > right
                        elif operator == "<":
                            ok = left < right
                        elif operator == ">=":
                            ok = left >= right
                        else:
                            ok = left <= right
                    except (TypeError, ValueError):
                        ok = False
                return ok, f"expected {operator} {raw}, actual {actual}"
    return actual == expected, f"expected {expected!r}, actual {actual!r}"


class ScenarioRunner:
    """Executes a scenario document against a live game."""

    def __init__(self, bridge: StudioBridge, reset_session: Any | None = None) -> None:
        self.bridge = bridge
        #: Callable that restarts the play session, giving a fresh player.
        #: Without it a `reset` step reports honestly that it cannot isolate.
        self.reset_session = reset_session
        self._baseline: dict[str, Any] = {}
        self._remembered: dict[str, Any] = {}
        self._reset_count = 0
        self._rejoin_validated = False
        self._attached_real_player = False

    def _player_attributes(self) -> dict[str, Any]:
        state = self.bridge.player_state()
        return dict(state.get("attributes") or {})

    def run(self, scenario: dict[str, Any]) -> ScenarioResult:
        self._attached_real_player = False
        self._baseline = {}
        self._remembered = {}
        self._reset_count = 0
        self._rejoin_validated = False
        result = ScenarioResult(
            scenario=str(scenario.get("id") or scenario.get("scenario") or "unnamed"),
            status="PASS",
            started_at=time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        )

        issues = scenario_document_issues(scenario)
        if issues:
            result.status = "FAIL"
            result.steps.append(StepResult(
                index=0,
                kind="preflight",
                spec={},
                status="FAIL",
                detail={"issues": issues},
                reason="; ".join(issues),
            ))
            return result

        lease_scope: Any | None = None
        lease: dict[str, Any] | None = getattr(self.bridge, "active_lease", None)
        owns_lease = False

        def close_lease() -> None:
            nonlocal lease_scope, lease, owns_lease
            if lease_scope is None or not owns_lease:
                return
            active = lease_scope
            lease_scope = None
            lease = None
            owns_lease = False
            active.__exit__(None, None, None)

        try:
            for index, step in enumerate(scenario.get("steps", []), start=1):
                kind, spec = self._normalise(step)
                started = time.monotonic()
                try:
                    # A reset destroys the DataModel the current fence names.
                    # Release it before restarting; the next action acquires a
                    # fresh fence on the newly running session.
                    if kind == "reset":
                        if owns_lease:
                            close_lease()
                        elif lease is not None and self.reset_session is not None:
                            raise BridgeError(
                                "E_LEASE_CONFLICT",
                                "a scenario cannot reset the session inside a caller-owned lease",
                            )
                    elif hasattr(self.bridge, "lease_scope"):
                        if lease is None:
                            candidate_scope = self.bridge.lease_scope(
                                agent_id=f"scenario-{result.scenario}",
                                context="running",
                                session_id=getattr(self.bridge, "pinned_session", None),
                                ttl_seconds=300.0,
                            )
                            lease = candidate_scope.__enter__()
                            lease_scope = candidate_scope
                            owns_lease = True
                        else:
                            renewed = self.bridge.renew_lease(lease, ttl_seconds=300.0)
                            lease.clear()
                            lease.update(renewed)
                    status, detail, reason = self._execute(kind, spec)
                except BridgeError as exc:
                    status, detail, reason = "FAIL", exc.to_dict(), f"{exc.code}: {exc.message}"
                    result.command_errors.append({
                        "step": index,
                        "action": kind,
                        "error": exc.to_dict(),
                    })
                except (KeyError, TypeError, ValueError) as exc:
                    status, detail, reason = (
                        "FAIL",
                        {"type": type(exc).__name__, "message": str(exc)},
                        f"invalid step parameters: {exc}",
                    )

                outcome = StepResult(
                    index=index,
                    kind=kind,
                    spec=spec,
                    status=status,
                    detail=detail,
                    reason=reason,
                    elapsed_ms=(time.monotonic() - started) * 1000,
                )
                result.steps.append(outcome)

                if status != "PASS":
                    result.status = "FAIL"
                    if spec.get("fatal", True):
                        break
        finally:
            try:
                close_lease()
            except BridgeError as exc:
                result.status = "FAIL"
                result.command_errors.append({
                    "step": len(result.steps),
                    "action": "lease.release",
                    "error": exc.to_dict(),
                })
            except Exception as exc:  # noqa: BLE001
                result.status = "FAIL"
                result.command_errors.append({
                    "step": len(result.steps),
                    "action": "lease.release",
                    "error": {"type": type(exc).__name__, "message": str(exc)},
                })

        kinds = {step.kind for step in result.steps}
        player_actions = {"navigate_to", "interact", "click", "input", "gui", "expect_prompt_in_range"}
        if self._attached_real_player and (kinds.intersection(player_actions) or self._rejoin_validated):
            result.validation_level = "E2E_VALIDATED"
        elif kinds.intersection({"spawn", "reset", "attach", "assert"}):
            result.validation_level = "RUNTIME_VALIDATED"

        return result

    @staticmethod
    def _normalise(step: dict[str, Any]) -> tuple[str, dict[str, Any]]:
        if "step" in step:
            return str(step["step"]), step
        for key in SUPPORTED_STEP_KEYS:
            if key in step:
                value = step[key]
                spec = dict(value) if isinstance(value, dict) else {"value": value}
                spec.update({k: v for k, v in step.items() if k != key})
                return key, spec
        return "unsupported", step

    def _execute(self, kind: str, spec: dict[str, Any]) -> tuple[str, dict[str, Any], str | None]:
        if kind == "reset":
            # Gameplay state persists across a scenario run: the second pass of
            # a purchase test starts with the item already owned and fails for
            # the wrong reason. A scenario that needs a clean player says so and
            # the runner restarts the session, so the result is reproducible
            # rather than order-dependent.
            if self.reset_session is None:
                return "FAIL", {}, "this scenario needs a fresh session, but no reset was configured"
            if hasattr(self.bridge, "unpin"):
                self.bridge.unpin()
            detail = self.reset_session()
            ok = bool(detail.get("started"))
            self._baseline = {}
            if ok:
                self._reset_count += 1
            return ("PASS" if ok else "FAIL"), detail, (None if ok else "could not start a fresh play session")

        if kind == "attach":
            # [[
            #     Attaching is a race, not a claim.
            #
            #     A Play Solo player exists a moment before their Character
            #     replicates, and the release run attaches as soon as the
            #     session appears — so this failed with "the player has no
            #     Character yet", the state scenario was marked FAIL, and every
            #     capture linked to it was rejected for having no passing
            #     scenario. The picture was fine; nothing had spawned yet.
            #
            #     Bounded, so a game that genuinely never spawns anybody still
            #     fails rather than hanging.
            # ]]
            deadline = time.monotonic() + float(spec.get("timeout", 25))
            detail: dict[str, Any] = {}
            while True:
                try:
                    detail = self.bridge.actor_attach(spec.get("player"))
                    break
                except Exception as exc:  # noqa: BLE001
                    if time.monotonic() >= deadline:
                        return "FAIL", {"error": str(exc)}, str(exc)
                    time.sleep(1.0)
            self._baseline = dict(detail.get("playerAttributes") or {})
            self._attached_real_player = bool(detail.get("isRealPlayer"))
            return ("PASS" if detail.get("isRealPlayer") else "FAIL"), detail, (
                None if detail.get("isRealPlayer") else "attached body is not a real player"
            )

        if kind == "spawn":
            detail = self.bridge.actor_spawn(spec.get("name"), spec.get("near"))
            return "PASS", detail, None

        if kind == "navigate_to":
            target = spec.get("target") or spec.get("value")
            detail = self.bridge.actor_navigate_to(
                str(target),
                float(spec.get("tolerance", 5)),
                float(spec.get("timeout", 60)),
            )
            ok = bool(detail.get("success"))
            return ("PASS" if ok else "FAIL"), detail, (None if ok else detail.get("reason") or "did not arrive")

        if kind == "interact":
            path = spec.get("prompt") or spec.get("target") or spec.get("value")
            detail = self.bridge.prompt_trigger(str(path), float(spec.get("holdSeconds", 0)))
            ok = bool(detail.get("triggered"))
            return ("PASS" if ok else "FAIL"), detail, (None if ok else detail.get("reason") or "prompt did not fire")

        if kind == "click":
            path = spec.get("path") or spec.get("value")
            detail = self.bridge.gui_click(str(path))
            ok = bool(detail.get("activated"))
            return ("PASS" if ok else "FAIL"), detail, (None if ok else detail.get("reason") or "button did not activate")

        if kind == "input":
            action = str(spec.get("action") or "")
            params: dict[str, Any] = {"action": action}
            if action == "keys":
                keys = spec.get("keys")
                if not isinstance(keys, list) or not keys or any(not isinstance(item, str) for item in keys):
                    return "FAIL", {}, "input keys must be a non-empty array of key names"
                params["keys"] = keys
                params["duration"] = float(spec.get("duration", 0.1))
            elif action == "click":
                params["x"] = float(spec["x"])
                params["y"] = float(spec["y"])
            elif action == "text":
                params["text"] = str(spec.get("text") or "")
            else:
                return "FAIL", {"action": action}, "input action must be keys, click or text"
            if spec.get("player") is not None:
                params["player"] = str(spec["player"])
            detail = self.bridge.client_input(**params)
            ok = bool(detail.get("delivered")) and detail.get("source") == "VirtualInput"
            return ("PASS" if ok else "FAIL"), detail, (None if ok else detail.get("reason") or "virtual input was not delivered")

        if kind == "aim_at":
            target = str(spec.get("target") or spec.get("value") or "")
            if not target:
                return "FAIL", {}, "aim_at requires a target path"
            actor = self.bridge.actor_state()
            bounds = self.bridge.bounds(target)
            position = actor.get("position")
            center = bounds.get("center")
            if not (
                isinstance(position, list) and len(position) == 3
                and isinstance(center, list) and len(center) == 3
            ):
                return "FAIL", {"actor": actor, "bounds": bounds}, "aim_at could not measure actor and target positions"
            dx = float(center[0]) - float(position[0])
            dy = float(center[1]) - float(position[1])
            dz = float(center[2]) - float(position[2])
            length = max((dx * dx + dy * dy + dz * dz) ** 0.5, 1e-6)
            nx, ny, nz = dx / length, dy / length, dz / length
            distance = float(spec.get("cameraDistance", 9.0))
            height = float(spec.get("cameraHeight", 4.0))
            camera_position = [
                float(position[0]) - nx * distance,
                float(position[1]) - ny * distance + height,
                float(position[2]) - nz * distance,
            ]
            detail = self.bridge.client_camera_set(
                camera_position,
                [float(center[0]), float(center[1]), float(center[2])],
                float(spec.get("fieldOfView", 70.0)),
                spec.get("player"),
            )
            detail = {**detail, "target": target, "targetCenter": center}
            ok = bool(detail.get("applied"))
            return ("PASS" if ok else "FAIL"), detail, (None if ok else "client camera did not apply")

        if kind == "release_camera":
            detail = self.bridge.client_camera_release(spec.get("player"))
            ok = bool(detail.get("released"))
            return ("PASS" if ok else "FAIL"), detail, (None if ok else "client camera did not release")

        if kind == "remember":
            attribute = str(spec.get("attribute") or "")
            name = str(spec.get("as") or attribute)
            if not attribute or not name:
                return "FAIL", {}, "remember requires attribute and a non-empty variable name"
            attributes = self._player_attributes()
            if attribute not in attributes:
                return "FAIL", {"attribute": attribute}, f"player attribute {attribute!r} is missing"
            self._remembered[name] = attributes[attribute]
            return "PASS", {"attribute": attribute, "as": name, "value": attributes[attribute]}, None

        if kind == "gui":
            detail = self.bridge.gui_tree(bool(spec.get("includeHidden", False)))
            expected = spec.get("visibleText")
            if expected is None:
                return "PASS", detail, None
            texts = [str(item.get("text") or "") for item in detail.get("elements", [])]
            ok = any(str(expected) in text for text in texts)
            return ("PASS" if ok else "FAIL"), {"expected": expected, "count": detail.get("count")}, (
                None if ok else f"no visible element contains {expected!r}"
            )

        if kind == "assert":
            return self._assert(spec)

        if kind == "wait":
            seconds = float(spec.get("seconds", spec.get("value", 1)))
            if seconds < 0 or seconds > 30:
                return "FAIL", {"requestedSeconds": seconds, "maximumSeconds": 30}, "wait must be between 0 and 30 seconds"
            time.sleep(seconds)
            return "PASS", {"requestedSeconds": seconds, "elapsedSeconds": seconds}, None

        if kind == "expect_prompt_in_range":
            detail = self.bridge.actor_prompts(float(spec.get("radius", 60)))
            wanted = str(spec.get("prompt") or spec.get("value") or "")
            matches = [item for item in detail.get("prompts", []) if wanted in item.get("path", "")]
            ok = bool(matches) and bool(matches[0].get("inRange"))
            return ("PASS" if ok else "FAIL"), {"matches": matches}, (
                None if ok else f"{wanted} is not within its activation distance"
            )

        return "FAIL", {"step": kind}, f"unsupported step: {kind}"

    def _assert(self, spec: dict[str, Any]) -> tuple[str, dict[str, Any], str | None]:
        attributes = self._player_attributes()
        failures: list[str] = []
        checked: dict[str, Any] = {}

        for key, expected in spec.items():
            if key in RESERVED_STEP_KEYS:
                continue
            if key == "delta":
                for attribute, wanted in (expected or {}).items():
                    before = self._baseline.get(attribute)
                    after = attributes.get(attribute)
                    try:
                        actual = float(after) - float(before)
                    except (TypeError, ValueError):
                        failures.append(f"{attribute}: cannot diff {before!r} -> {after!r}")
                        continue
                    ok, message = _compare(actual, wanted)
                    checked[f"delta.{attribute}"] = {"before": before, "after": after, "delta": actual}
                    if not ok:
                        failures.append(f"delta.{attribute}: {message}")
                continue

            if key == "rememberedDelta":
                for attribute, rule in (expected or {}).items():
                    if not isinstance(rule, dict):
                        failures.append(f"rememberedDelta.{attribute}: rule must be an object")
                        continue
                    name = str(rule.get("from") or attribute)
                    before = self._remembered.get(name)
                    after = attributes.get(attribute)
                    try:
                        actual_delta = float(after) - float(before)
                    except (TypeError, ValueError):
                        failures.append(f"rememberedDelta.{attribute}: cannot diff {before!r} -> {after!r}")
                        continue
                    wanted = rule.get("expect", "!= 0")
                    ok, message = _compare(actual_delta, wanted)
                    checked[f"rememberedDelta.{attribute}"] = {
                        "from": name, "before": before, "after": after, "delta": actual_delta,
                    }
                    if not ok:
                        failures.append(f"rememberedDelta.{attribute}: {message}")
                continue

            actual = attributes.get(key)
            ok, message = _compare(actual, expected)
            checked[key] = actual
            if not ok:
                failures.append(f"{key}: {message}")

        if not failures and self._reset_count > 0 and "rememberedDelta" in spec:
            self._rejoin_validated = True
        return ("PASS" if not failures else "FAIL"), {"attributes": checked, "failures": failures}, (
            None if not failures else "; ".join(failures)
        )


def load_scenario(path: str | Path) -> dict[str, Any]:
    return json.loads(Path(path).read_text(encoding="utf-8"))


def write_scenario_result(result: ScenarioResult, artifacts_dir: Path) -> Path:
    if not SCENARIO_ID_PATTERN.fullmatch(result.scenario):
        raise ValueError(f"unsafe scenario id: {result.scenario!r}")
    artifacts_dir.mkdir(parents=True, exist_ok=True)
    target = artifacts_dir / f"scenario-{result.scenario}.json"
    target.write_text(json.dumps(result.to_dict(), indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    return target
