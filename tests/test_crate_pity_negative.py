"""A crate cannot be built with a negative pity threshold.

CrateRoll.new keeps pityThreshold or 20. A negative number is truthy, so
-1 is stored. pityCounter + 1 >= -1 is already true, and the first roll
is forced onto the rare pool.
"""

from __future__ import annotations

import unittest
from pathlib import Path

from rqe.luau_harness import run_or_raise

ROOT = Path(__file__).resolve().parents[1]
FORGE = ROOT / "forge/luau/Forge"


def _run(libraries: list[Path], body: str) -> str:
    return run_or_raise(ROOT, libraries=libraries, body=body).stdout


class TestCratePityNegative(unittest.TestCase):
    def test_negative_pity_threshold_is_refused(self) -> None:
        out = _run([FORGE / "Progression"], """
            local CrateRoll = Require("CrateRoll")
            local drops = {
                { id = "common", weight = 1, rarity = 1 },
                { id = "rare", weight = 1, rarity = 3 },
            }
            local negativeOk = pcall(function()
                CrateRoll.new({ drops = drops, pityThreshold = -1 })
            end)
            assert(negativeOk == false, "a negative pity threshold must be refused")
            local crate = CrateRoll.new({ drops = drops, pityThreshold = 20 })
            local rolled = crate:roll(function()
                return 0
            end)
            assert(rolled.id == "common", "the first roll must stay on the common pool")
            print('{"pity":"common"}')
        """)
        assert "pity" in out


if __name__ == "__main__":
    unittest.main()
