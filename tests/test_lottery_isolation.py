"""Wealth bands must stay sealed after wealthWeight.

Executed as real Luau through the pinned runtime. The weight function
closes over the caller's bands table, so zeroing a multiplier after add
makes the next roll return nothing.
"""

from __future__ import annotations

import unittest
from pathlib import Path

from rqe.luau_harness import run_or_raise

ROOT = Path(__file__).resolve().parents[1]
FORGE = ROOT / "forge/luau/Forge"


def _run(libraries: list[Path], body: str) -> str:
    return run_or_raise(ROOT, libraries=libraries, body=body).stdout


class TestLotteryIsolation(unittest.TestCase):
    def test_zeroing_a_band_after_add_does_not_empty_the_roll(self) -> None:
        out = _run([FORGE / "LiveOps"], """
            local Lottery = Require("Lottery")
            local bands = { { above = 0, mult = 1 } }
            local lottery = Lottery.new()
            lottery:add("gem", { weightFn = Lottery.wealthWeight(10, bands) })
            bands[1].mult = 0
            local rolled = lottery:roll(function()
                return 0
            end, { wealth = 0 })
            assert(rolled == "gem", "zeroing the band emptied the roll, got " .. tostring(rolled))
            print('{"lottery":true}')
        """)
        self.assertIn("lottery", out)


if __name__ == "__main__":
    unittest.main()
