"""An infinite coin value must not be stored.

Executed as real Luau through the pinned runtime. addCoin asserts
value >= 1, and math.huge passes, so collect pays an infinite coin.
"""

from __future__ import annotations

import unittest
from pathlib import Path

from rqe.luau_harness import run_or_raise

ROOT = Path(__file__).resolve().parents[1]
FORGE = ROOT / "forge/luau/Forge"


def _run(libraries: list[Path], body: str) -> str:
    return run_or_raise(ROOT, libraries=libraries, body=body).stdout


class TestIdleInfiniteCoin(unittest.TestCase):
    def test_an_infinite_coin_value_is_refused(self) -> None:
        out = _run([FORGE / "Progression"], """
            local IdleGenerator = Require("IdleGenerator")
            local idle = IdleGenerator.new({
                clock = function()
                    return 0
                end,
            })
            local accepted = pcall(function()
                idle:addCoin("gold", math.huge)
            end)
            assert(accepted == false, "an infinite coin was accepted")
            idle:addCoin("gold", 5)
            local paid = idle:collect("gold")
            assert(paid == 5, "collect paid " .. tostring(paid))
            print('{"coin":true}')
        """)
        self.assertIn("coin", out)


if __name__ == "__main__":
    unittest.main()
