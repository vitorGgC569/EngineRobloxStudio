"""An infinite wealth-band multiplier must not be stored.

`base * math.huge` is infinity, and a later roll of 0 against that weight
is NaN, so the first entry is skipped. Only a finite band multiplier may
be closed over.
"""

from __future__ import annotations

import unittest
from pathlib import Path

from rqe.luau_harness import run_or_raise

ROOT = Path(__file__).resolve().parents[1]
FORGE = ROOT / "forge/luau/Forge"


def _run(libraries: list[Path], body: str) -> str:
    return run_or_raise(ROOT, libraries=libraries, body=body).stdout


class TestLotteryInfiniteBand(unittest.TestCase):
    def test_huge_band_is_refused_and_a_finite_band_still_scales(self) -> None:
        out = _run([FORGE / "LiveOps"], """
            local Lottery = Require("Lottery")
            local ok = pcall(function()
                Lottery.wealthWeight(1, { { above = 0, mult = math.huge } })
            end)
            assert(ok == false, "huge band must be refused")
            local weight = Lottery.wealthWeight(1, { { above = 0, mult = 2 } })
            local value = weight({ wealth = 10 })
            assert(value == 2, "finite band must return 2, got " .. tostring(value))
            print('{"band":true}')
        """)
        assert "band" in out


if __name__ == "__main__":
    unittest.main()
