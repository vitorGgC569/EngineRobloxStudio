"""CardCycle.new must refuse an infinite seed.

Executed as real Luau through the pinned runtime, same harness as the mined
library specs. math.huge must fail naming seed; seed 1 still deals slash or guard.
"""

from __future__ import annotations

import unittest
from pathlib import Path

from rqe.luau_harness import run_or_raise

ROOT = Path(__file__).resolve().parents[1]
FORGE = ROOT / "forge/luau/Forge"


def _run(libraries: list[Path], body: str) -> str:
    return run_or_raise(ROOT, libraries=libraries, body=body).stdout


class TestCardCycleInfiniteSeed(unittest.TestCase):
    def test_infinite_seed_is_refused(self) -> None:
        """new rejects math.huge naming seed, and seed 1 still deals."""
        out = _run([FORGE / "Match", FORGE / "Core"], """
            local CardCycle = Require("CardCycle")
            local okHuge, err = pcall(function()
                CardCycle.new({ cards = { "slash", "guard" }, handSize = 1, seed = math.huge })
            end)
            assert(okHuge == false, "huge seed was " .. tostring(okHuge))
            assert(string.find(tostring(err), "seed", 1, true) ~= nil, "error was " .. tostring(err))
            local cycle = CardCycle.new({ cards = { "slash", "guard" }, handSize = 1, seed = 1 })
            local dealt = cycle:hand()[1]
            assert(dealt == "slash" or dealt == "guard", "hand was " .. tostring(dealt))
            print('{"seed":true}')
        """)
        assert "seed" in out


if __name__ == "__main__":
    unittest.main()
