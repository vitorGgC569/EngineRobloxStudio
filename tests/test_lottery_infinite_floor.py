"""An infinite wealth-band floor must not be stored.

`-math.huge` is a number and less than `math.huge`, so the current check
accepts it. Every finite wealth is at least that floor, so the band
always matches. A floor of 0 still scales.
"""

from __future__ import annotations

import unittest
from pathlib import Path

from rqe.luau_harness import run_or_raise

ROOT = Path(__file__).resolve().parents[1]
FORGE = ROOT / "forge/luau/Forge"


def _run(libraries: list[Path], body: str) -> str:
    return run_or_raise(ROOT, libraries=libraries, body=body).stdout


class TestLotteryInfiniteFloor(unittest.TestCase):
    def test_infinite_floor_is_refused_and_a_zero_floor_still_scales(self) -> None:
        out = _run([FORGE / "LiveOps"], """
            local Lottery = Require("Lottery")
            local ok = pcall(function()
                Lottery.wealthWeight(1, { { above = -math.huge, mult = 2 } })
            end)
            assert(ok == false, "infinite floor must be refused")
            local weight = Lottery.wealthWeight(1, { { above = 0, mult = 2 } })
            local value = weight({ wealth = 10 })
            assert(value == 2, "zero floor must return 2, got " .. tostring(value))
            print('{"floor":true}')
        """)
        assert "floor" in out


if __name__ == "__main__":
    unittest.main()
