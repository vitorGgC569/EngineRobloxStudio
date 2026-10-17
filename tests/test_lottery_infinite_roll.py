"""An infinite sample must not fall through to the last lottery entry.

`math.huge` is a number and equal to itself, so the NaN check lets it
through. `huge * total` stays infinite, every comparison fails, and roll
returns the last entry. A sample of 0 still hits the first weighted entry.
"""

from __future__ import annotations

import unittest
from pathlib import Path

from rqe.luau_harness import run_or_raise

ROOT = Path(__file__).resolve().parents[1]
FORGE = ROOT / "forge/luau/Forge"


def _run(libraries: list[Path], body: str) -> str:
    return run_or_raise(ROOT, libraries=libraries, body=body).stdout


class TestLotteryInfiniteRoll(unittest.TestCase):
    def test_huge_sample_returns_nil_and_zero_still_hits_the_first_entry(self) -> None:
        out = _run([FORGE / "LiveOps"], """
            local Lottery = Require("Lottery")
            local lottery = Lottery.new()
            lottery:add("rare", { weight = 1 })
            lottery:add("common", { weight = 1 })
            local huge = lottery:roll(function()
                return math.huge
            end, {})
            assert(huge == nil, "huge roll must return nil, got " .. tostring(huge))
            local zero = lottery:roll(function()
                return 0
            end, {})
            assert(zero == "rare", "zero roll must return rare, got " .. tostring(zero))
            print('{"hugeroll":true}')
        """)
        assert "hugeroll" in out


if __name__ == "__main__":
    unittest.main()
