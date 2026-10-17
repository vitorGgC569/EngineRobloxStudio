"""An infinite roll multiplier must not skip the first entry.

`0 * math.huge` is NaN, and NaN is not less than the accumulated weight, so
the first entry is skipped and the last one wins. A finite multiplier
still scales every weight the same way.
"""

from __future__ import annotations

import unittest
from pathlib import Path

from rqe.luau_harness import run_or_raise

ROOT = Path(__file__).resolve().parents[1]
FORGE = ROOT / "forge/luau/Forge"


def _run(libraries: list[Path], body: str) -> str:
    return run_or_raise(ROOT, libraries=libraries, body=body).stdout


class TestLotteryInfiniteMultiplier(unittest.TestCase):
    def test_huge_multiplier_does_not_skip_the_first_entry(self) -> None:
        out = _run([FORGE / "LiveOps"], """
            local Lottery = Require("Lottery")
            local lottery = Lottery.new()
            lottery:add("rare", { weight = 1 })
            lottery:add("common", { weight = 1 })
            local function zero()
                return 0
            end
            local huge = lottery:roll(zero, { multiplier = math.huge })
            assert(huge == "rare", "huge multiplier must return rare, got " .. tostring(huge))
            local scaled = lottery:roll(zero, { multiplier = 2 })
            assert(scaled == "rare", "finite multiplier must return rare, got " .. tostring(scaled))
            print('{"multiplier":true}')
        """)
        assert "multiplier" in out


if __name__ == "__main__":
    unittest.main()
