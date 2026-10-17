"""An infinite lottery weight must not enter the pool.

`math.huge` is a number, so add stores it. A later roll then skips that
entry and the last finite weight wins. Only a finite non-negative weight
may be inserted.
"""

from __future__ import annotations

import unittest
from pathlib import Path

from rqe.luau_harness import run_or_raise

ROOT = Path(__file__).resolve().parents[1]
FORGE = ROOT / "forge/luau/Forge"


def _run(libraries: list[Path], body: str) -> str:
    return run_or_raise(ROOT, libraries=libraries, body=body).stdout


class TestLotteryInfiniteWeight(unittest.TestCase):
    def test_huge_weight_is_refused_and_a_finite_entry_still_rolls(self) -> None:
        out = _run([FORGE / "LiveOps"], """
            local Lottery = Require("Lottery")
            local lottery = Lottery.new()
            local ok = pcall(function()
                lottery:add("rare", { weight = math.huge })
            end)
            assert(ok == false, "huge weight must be refused")
            lottery:add("common", { weight = 1 })
            local rolled = lottery:roll(function()
                return 0.5
            end, {})
            assert(rolled == "common", "roll must return common, got " .. tostring(rolled))
            print('{"weight":true}')
        """)
        assert "weight" in out


if __name__ == "__main__":
    unittest.main()
