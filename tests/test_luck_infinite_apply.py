"""An infinite luck multiplier must not scale a rare drop.

`math.huge > 1` is true, so apply multiplies the rare weight by infinity.
A multiplier of 2 still doubles that rare weight and leaves the common
weight alone.
"""

from __future__ import annotations

import unittest
from pathlib import Path

from rqe.luau_harness import run_or_raise

ROOT = Path(__file__).resolve().parents[1]
FORGE = ROOT / "forge/luau/Forge"


def _run(libraries: list[Path], body: str) -> str:
    return run_or_raise(ROOT, libraries=libraries, body=body).stdout


class TestLuckInfiniteApply(unittest.TestCase):
    def test_huge_multiplier_does_not_scale_and_two_still_doubles_rare(self) -> None:
        out = _run([FORGE / "LiveOps"], """
            local Luck = Require("Luck")
            local drops = {
                { id = "rare", weight = 1, rarity = 3 },
                { id = "common", weight = 1, rarity = 0 },
            }
            local huge = Luck.apply(drops, math.huge, 3)
            local rareHuge = nil
            for _, drop in huge do
                if drop.id == "rare" then
                    rareHuge = drop.weight
                end
            end
            assert(rareHuge == 1, "rare weight must stay 1, got " .. tostring(rareHuge))
            local scaled = Luck.apply(drops, 2, 3)
            local rareScaled, commonScaled = nil, nil
            for _, drop in scaled do
                if drop.id == "rare" then
                    rareScaled = drop.weight
                elseif drop.id == "common" then
                    commonScaled = drop.weight
                end
            end
            assert(rareScaled == 2 and commonScaled == 1, "scaled weights must be 2 and 1, got " .. tostring(rareScaled) .. " " .. tostring(commonScaled))
            print('{"apply":true}')
        """)
        assert "apply" in out


if __name__ == "__main__":
    unittest.main()
