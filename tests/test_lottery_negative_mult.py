"""A negative wealth-band multiplier must not be stored.

`-2` is a finite number, so the current check accepts it. The closure
then returns a negative weight that later counts as zero. A multiplier
of 2 still scales.
"""

from __future__ import annotations

import unittest
from pathlib import Path

from rqe.luau_harness import run_or_raise

ROOT = Path(__file__).resolve().parents[1]
FORGE = ROOT / "forge/luau/Forge"


def _run(libraries: list[Path], body: str) -> str:
    return run_or_raise(ROOT, libraries=libraries, body=body).stdout


class TestLotteryNegativeMult(unittest.TestCase):
    def test_negative_mult_is_refused_and_a_positive_mult_still_scales(self) -> None:
        out = _run([FORGE / "LiveOps"], """
            local Lottery = Require("Lottery")
            local ok = pcall(function()
                Lottery.wealthWeight(1, { { above = 0, mult = -2 } })
            end)
            assert(ok == false, "negative mult must be refused")
            local weight = Lottery.wealthWeight(1, { { above = 0, mult = 2 } })
            local value = weight({ wealth = 10 })
            assert(value == 2, "positive mult must return 2, got " .. tostring(value))
            print('{"mult":true}')
        """)
        assert "mult" in out


if __name__ == "__main__":
    unittest.main()
