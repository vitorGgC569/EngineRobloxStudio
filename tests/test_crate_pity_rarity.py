"""A negative pity rarity floor must not be stored.

Executed as real Luau through the pinned runtime. CrateRoll.new keeps
minRarityForPity or 3. A negative number is truthy, so -1 is stored and
pity keeps every drop because rarity >= -1.
"""

from __future__ import annotations

import unittest
from pathlib import Path

from rqe.luau_harness import run_or_raise

ROOT = Path(__file__).resolve().parents[1]
FORGE = ROOT / "forge/luau/Forge"


def _run(libraries: list[Path], body: str) -> str:
    return run_or_raise(ROOT, libraries=libraries, body=body).stdout


class TestCratePityRarity(unittest.TestCase):
    def test_a_negative_pity_rarity_is_refused(self) -> None:
        out = _run([FORGE / "Progression"], """
            local CrateRoll = Require("CrateRoll")
            local drops = {
                { id = "common", weight = 1, rarity = 1 },
                { id = "rare", weight = 1, rarity = 3 },
            }
            local accepted = pcall(function()
                CrateRoll.new({ drops = drops, pityThreshold = 20, minRarityForPity = -1 })
            end)
            assert(accepted == false, "a negative rarity floor was accepted")
            local crate = CrateRoll.new({ drops = drops })
            local rolled = crate:roll(function()
                return 0
            end)
            assert(rolled.id == "common", "the default roll left the common pool, got " .. tostring(rolled.id))
            print('{"rarity":true}')
        """)
        self.assertIn("rarity", out)


if __name__ == "__main__":
    unittest.main()
