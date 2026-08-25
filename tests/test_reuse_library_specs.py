"""Behavioral specs for the reuse library, executed as real Luau.

Compile-only proves syntax; these prove behavior. The critical modules --
spring motion, hit resolution, grid placement, quests, atomic debits and the
UiSpec contract -- run headlessly through the pinned Luau runtime with the
same require graph production uses.
"""

from __future__ import annotations

import unittest
from pathlib import Path

from rqe.luau_check import ToolchainUnavailable, ensure_compiler
from rqe.luau_harness import run_or_raise

ROOT = Path(__file__).resolve().parents[1]
FORGE = ROOT / "forge/luau/Forge"


def _run(libraries: list[Path], body: str) -> str:
    result = run_or_raise(ROOT, libraries=libraries, body=body)
    return result.stdout


class TestMotionSpring(unittest.TestCase):
    def test_underdamped_spring_converges_to_goal(self) -> None:
        out = _run([FORGE / "UI"], """
            local Motion = Require("Motion")
            local spring = Motion.newSpring(0, { goal = 10 })
            Motion.setGoal(spring, 100)
            for _ = 1, 600 do
                Motion.step(spring, 1/60)
            end
            assert(math.abs(spring.position - 100) < 0.5, "position: " .. tostring(spring.position))
            print(string.format('{"converged":true,"position":%.2f}', spring.position))
        """)
        assert "converged" in out

    def test_group_motor_steps_every_spring_and_reports_settled(self) -> None:
        out = _run([FORGE / "UI"], """
            local Motion = Require("Motion")
            local motor = Motion.newGroupMotor()
            Motion.groupAdd(motor, "x", 5)
            Motion.groupAdd(motor, "y", 7)
            Motion.groupSetGoal(motor, "x", 50)
            local positions
            for _ = 1, 900 do
                positions = Motion.groupStep(motor, 1/60)
            end
            assert(math.abs(positions.x - 50) < 0.5, "x: " .. tostring(positions.x))
            assert(Motion.groupSettled(motor), "motor should be settled")
            print('{"ok":true}')
        """)
        assert '"ok"' in out or "ok" in out


class TestDamagePipeline(unittest.TestCase):
    def test_block_chip_and_guardbreak_resolution(self) -> None:
        out = _run([FORGE / "Combat"], """
            local DamagePipeline = Require("DamagePipeline")
            local move = { damage = 20, guardbreak = false, blockstun = 0.8 }
            local blockedVictim = { blocking = true, facingDot = 0.9 }
            local result = DamagePipeline.resolve(move, nil, blockedVictim)
            assert(result.kind == "blocked", "kind: " .. tostring(result.kind))
            assert(result.damageDealt == 1 or result.chipDamage == 4,
                "chip: dealt=" .. tostring(result.damageDealt) .. " chip=" .. tostring(result.chipDamage))

            local breakMove = { damage = 20, guardbreak = true, stun = 2 }
            local broken = DamagePipeline.resolve(breakMove, nil, blockedVictim)
            assert(broken.kind == "hit", "guardbreak must hit, got " .. tostring(broken.kind))
            assert(broken.guardBroken == true, "guardBroken flag expected")

            local iframeVictim = { iframes = true }
            local missed = DamagePipeline.resolve(move, nil, iframeVictim)
            assert(missed.kind == "miss", "iframes must miss")
            print(string.format('{"pipeline":true,"chip":%d}', result.chipDamage))
        """)
        assert "pipeline" in out


class TestGridPlacement(unittest.TestCase):
    def test_snap_fit_place_and_collision_refusal(self) -> None:
        out = _run([FORGE / "Tycoon"], """
            local GridPlacement = Require("GridPlacement")
            local planner = GridPlacement.new({
                cellSize = 3,
                bounds = { minX = 0, minZ = 0, maxX = 30, maxZ = 30 },
                items = { { id = "dropper", footprintX = 2, footprintZ = 2 } },
            })
            local snapped = planner:snap({ x = 4.4, z = 2.1 })
            assert(snapped.x == 3 and snapped.z == 3, "snap: " .. tostring(snapped.x) .. "," .. tostring(snapped.z))
            local ok, reason = planner:fits("dropper", 0, snapped)
            assert(ok, reason)
            assert(planner:place("p1", "dropper", 0, snapped), "place must succeed")
            local ok2, reason2 = planner:fits("dropper", 0, snapped)
            assert(not ok2 and reason2 == "occupied", "expected occupied, got " .. tostring(reason2))
            print(string.format('{"placed":true,"refused":"%s"}', reason2))
        """)
        assert "placed" in out


class TestQuestEngine(unittest.TestCase):
    def test_count_objective_advances_stage_and_completes(self) -> None:
        out = _run([FORGE / "Progression"], """
            local QuestEngine = Require("QuestEngine")
            local engine = QuestEngine.new()
            engine:register({
                id = "mine_three",
                stages = {
                    { objective = { kind = "count", targetTag = "OreNode", goal = 3 } },
                    { objective = { kind = "count", targetTag = "Smelter", goal = 1 } },
                },
            })
            local state = engine:start("mine_three")
            for _ = 1, 3 do
                state = engine:reportEvent(state, "OreNode", true)
            end
            assert(engine:currentObjective(state).targetTag == "Smelter", "stage should advance")
            state = engine:reportEvent(state, "Smelter", true)
            assert(state.done, "quest should complete")
            print(string.format('{"done":%s}', tostring(state.done)))
        """)
        assert "done" in out


class TestBalanceAtomicDebit(unittest.TestCase):
    def test_debit_is_all_or_nothing(self) -> None:
        out = _run([FORGE / "Economy"], """
            local Balance = Require("Balance")
            local wallet = Balance.new({ currencies = { gold = {}, gems = {} } })
            wallet:credit({ gold = 100, gems = 2 })
            local ok = wallet:debit({ gold = 40, gems = 5 })
            assert(not ok, "insufficient gems must refuse the whole purchase")
            assert(wallet:get("gold") == 100, "gold must be untouched after refusal")
            local ok2 = wallet:debit({ gold = 40, gems = 1 })
            assert(ok2, "valid debit must pass")
            assert(wallet:get("gold") == 60, "gold must be debited exactly once")
            print(string.format('{"atomic":true,"gold":%d}', wallet:get("gold")))
        """)
        assert "atomic" in out


class TestVisualSpecContract(unittest.TestCase):
    def test_unknown_kind_missing_prop_and_raw_hex_are_refused(self) -> None:
        out = _run([FORGE / "UI"], """
            local VisualSpec = Require("VisualSpec")
            local bad = {
                kind = "frame",
                children = {
                    { kind = "button", props = { text = "Buy" } },
                    { kind = "label", props = { text = "Hi", color = "#FF00FF" } },
                    { kind = "teleporter", props = {} },
                },
            }
            local ok, problems = VisualSpec.validate(bad)
            assert(not ok, "spec must fail closed")
            local joined = table.concat(problems, ";")
            assert(joined:find("missing_prop", 1, true), joined)
            assert(joined:find("raw_hex_forbidden", 1, true), joined)
            assert(joined:find("unknown_kind", 1, true), joined)

            local good = {
                kind = "frame",
                name = "Shop",
                children = {
                    { kind = "button", props = { text = "Buy", variant = "primary" } },
                },
            }
            local okGood = VisualSpec.validate(good)
            assert(okGood, "well-formed spec must pass")
            print(string.format('{"conformance":true,"refused":%d}', #problems))
        """)
        assert "conformance" in out
