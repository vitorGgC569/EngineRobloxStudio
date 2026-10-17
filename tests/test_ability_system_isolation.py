"""Ability definitions must not stay shared with the caller.

Setting cooldown after `register`, or damage on the table `cast` handed
back, must not change later reads of the same ability.
"""

from __future__ import annotations

import unittest
from pathlib import Path

from rqe.luau_harness import run_or_raise

ROOT = Path(__file__).resolve().parents[1]
FORGE = ROOT / "forge/luau/Forge"


def _run(libraries: list[Path], body: str) -> str:
    return run_or_raise(ROOT, libraries=libraries, body=body).stdout


class TestAbilitySystemIsolation(unittest.TestCase):
    def test_cooldown_and_execution_data_stay_stable_after_mutation(self) -> None:
        out = _run([FORGE / "Combat"], """
            local AbilitySystem = Require("AbilitySystem")
            local system = AbilitySystem.new({
                now = function()
                    return 0
                end,
                guidFactory = function()
                    return "g1"
                end,
            })
            local def = { name = "slash", cooldown = 2, castTime = 0, executionData = { damage = 10 } }
            system:register("slash", def)
            def.cooldown = 0
            assert(system:cooldownOf("slash") == 2, "cooldownOf must stay 2, got " .. tostring(system:cooldownOf("slash")))
            local _, payload = system:cast("slash")
            payload.damage = 0
            system:resetCooldown("slash")
            local _, nextPayload = system:cast("slash")
            assert(nextPayload.damage == 10, "next cast damage must stay 10, got " .. tostring(nextPayload.damage))
            print('{"ability":true}')
        """)
        assert "ability" in out


if __name__ == "__main__":
    unittest.main()
