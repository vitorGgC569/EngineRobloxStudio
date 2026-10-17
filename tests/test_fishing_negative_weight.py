"""A negative drop weight must not enter the pool.

Executed as real Luau through the pinned runtime. addDrop stores a
negative weight, rollLoot adds it into the total, and one carp of weight
1 disappears beside an eel of weight -5.
"""

from __future__ import annotations

import unittest
from pathlib import Path

from rqe.luau_harness import run_or_raise

ROOT = Path(__file__).resolve().parents[1]
FORGE = ROOT / "forge/luau/Forge"


def _run(libraries: list[Path], body: str) -> str:
    return run_or_raise(ROOT, libraries=libraries, body=body).stdout


class TestFishingNegativeWeight(unittest.TestCase):
    def test_a_negative_weight_is_refused_and_the_carp_remains(self) -> None:
        out = _run([FORGE / "Progression", FORGE / "Core"], """
            local FishingMinigame = Require("FishingMinigame")
            local game = FishingMinigame.new({
                drops = { { id = "carp", weight = 1, minProfessionLevel = 0, minRodTier = 1 } },
                seed = 1,
                now = function()
                    return 0
                end,
            })
            local accepted = pcall(function()
                game:addDrop({ id = "eel", weight = -5, minProfessionLevel = 0, minRodTier = 1 })
            end)
            assert(accepted == false, "a negative weight was accepted")
            local rolled = game:rollLoot(0, 1)
            assert(rolled == "carp", "the carp disappeared, got " .. tostring(rolled))
            print('{"fish":true}')
        """)
        self.assertIn("fish", out)


if __name__ == "__main__":
    unittest.main()
