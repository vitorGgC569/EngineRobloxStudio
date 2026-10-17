"""A wealth band must name the threshold it applies above.

The closure compares wealth with band.above. A band that has no above
stores nil, and the comparison throws. A finite threshold still scales.
"""

from __future__ import annotations

import unittest
from pathlib import Path

from rqe.luau_harness import run_or_raise

ROOT = Path(__file__).resolve().parents[1]
FORGE = ROOT / "forge/luau/Forge"


def _run(libraries: list[Path], body: str) -> str:
    return run_or_raise(ROOT, libraries=libraries, body=body).stdout


class TestLotteryMissingAbove(unittest.TestCase):
    def test_missing_above_is_refused_and_a_finite_threshold_still_scales(self) -> None:
        out = _run([FORGE / "LiveOps"], """
            local Lottery = Require("Lottery")
            local ok = pcall(function()
                Lottery.wealthWeight(1, { { mult = 2 } })
            end)
            assert(ok == false, "missing above must be refused")
            local weight = Lottery.wealthWeight(1, { { above = 0, mult = 2 } })
            local value = weight({ wealth = 10 })
            assert(value == 2, "finite threshold must return 2, got " .. tostring(value))
            print('{"above":true}')
        """)
        assert "above" in out


if __name__ == "__main__":
    unittest.main()
