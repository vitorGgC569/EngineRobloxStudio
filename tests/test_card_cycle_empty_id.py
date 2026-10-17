"""CardCycle.new must refuse an empty card id.

Executed as real Luau through the pinned runtime, same harness as the mined
library specs. An empty id must fail; a real deck still deals slash or guard.
"""

from __future__ import annotations

import unittest
from pathlib import Path

from rqe.luau_harness import run_or_raise

ROOT = Path(__file__).resolve().parents[1]
FORGE = ROOT / "forge/luau/Forge"


def _run(libraries: list[Path], body: str) -> str:
    return run_or_raise(ROOT, libraries=libraries, body=body).stdout


class TestCardCycleEmptyId(unittest.TestCase):
    def test_empty_card_id_is_refused(self) -> None:
        """new rejects an empty id, and a real deck deals slash or guard."""
        out = _run([FORGE / "Match", FORGE / "Core"], """
            local CardCycle = Require("CardCycle")
            local okEmpty = pcall(function()
                CardCycle.new({ cards = { "", "slash" }, handSize = 1, seed = 1 })
            end)
            assert(okEmpty == false, "empty card was " .. tostring(okEmpty))
            local cycle = CardCycle.new({ cards = { "slash", "guard" }, handSize = 1, seed = 1 })
            local dealt = cycle:hand()[1]
            assert(dealt == "slash" or dealt == "guard", "hand was " .. tostring(dealt))
            print('{"card":true}')
        """)
        assert "card" in out


if __name__ == "__main__":
    unittest.main()
