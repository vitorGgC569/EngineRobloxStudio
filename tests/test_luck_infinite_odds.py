"""An infinite drop weight must not erase the real chance.

`math.huge` makes the odds total infinite, so a common weight of 1
divided by that total is 0. Two finite weights of 1 still split evenly.
"""

from __future__ import annotations

import unittest
from pathlib import Path

from rqe.luau_harness import run_or_raise

ROOT = Path(__file__).resolve().parents[1]
FORGE = ROOT / "forge/luau/Forge"


def _run(libraries: list[Path], body: str) -> str:
    return run_or_raise(ROOT, libraries=libraries, body=body).stdout


class TestLuckInfiniteOdds(unittest.TestCase):
    def test_huge_weight_is_ignored_and_two_finite_weights_split(self) -> None:
        out = _run([FORGE / "LiveOps"], """
            local Luck = Require("Luck")
            local huge = Luck.odds({
                { id = "rare", weight = math.huge },
                { id = "common", weight = 1 },
            })
            assert(huge.common == 1, "common must be 1, got " .. tostring(huge.common))
            local even = Luck.odds({
                { id = "rare", weight = 1 },
                { id = "common", weight = 1 },
            })
            assert(even.common == 0.5, "common must be 0.5, got " .. tostring(even.common))
            print('{"odds":true}')
        """)
        assert "odds" in out


if __name__ == "__main__":
    unittest.main()
