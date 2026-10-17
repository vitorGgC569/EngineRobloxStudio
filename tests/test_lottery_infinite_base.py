"""An infinite wealth-weight base must not be closed over.

`math.huge` is a number, so it is stored and every later roll of that
weight is infinite. A finite base still scales by the band.
"""

from __future__ import annotations

import unittest
from pathlib import Path

from rqe.luau_harness import run_or_raise

ROOT = Path(__file__).resolve().parents[1]
FORGE = ROOT / "forge/luau/Forge"


def _run(libraries: list[Path], body: str) -> str:
    return run_or_raise(ROOT, libraries=libraries, body=body).stdout


class TestLotteryInfiniteBase(unittest.TestCase):
    def test_huge_base_is_refused_and_a_finite_base_still_scales(self) -> None:
        out = _run([FORGE / "LiveOps"], """
            local Lottery = Require("Lottery")
            local ok = pcall(function()
                Lottery.wealthWeight(math.huge, { { above = 0, mult = 1 } })
            end)
            assert(ok == false, "huge base must be refused")
            local weight = Lottery.wealthWeight(1, { { above = 0, mult = 2 } })
            local value = weight({ wealth = 10 })
            assert(value == 2, "finite base must return 2, got " .. tostring(value))
            print('{"base":true}')
        """)
        assert "base" in out


if __name__ == "__main__":
    unittest.main()
