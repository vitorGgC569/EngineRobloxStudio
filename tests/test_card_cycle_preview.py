"""CardCycle.new must leave one card for the preview.

Executed as real Luau through the pinned runtime, same harness as the mined
library specs. A one-card deck with handSize 1 must fail naming handSize; a
two-card deck still deals slash or guard.
"""

from __future__ import annotations

import unittest
from pathlib import Path

from rqe.luau_harness import run_or_raise

ROOT = Path(__file__).resolve().parents[1]
FORGE = ROOT / "forge/luau/Forge"


def _run(libraries: list[Path], body: str) -> str:
    return run_or_raise(ROOT, libraries=libraries, body=body).stdout


class TestCardCyclePreview(unittest.TestCase):
    def test_hand_must_leave_a_preview_card(self) -> None:
        """A one-card deck fails naming handSize, and two cards still deal."""
        out = _run([FORGE / "Match", FORGE / "Core"], """
            local CardCycle = Require("CardCycle")
            local okOne, err = pcall(function()
                CardCycle.new({ cards = { "only" }, handSize = 1, seed = 1 })
            end)
            assert(okOne == false, "one card was " .. tostring(okOne))
            assert(string.find(tostring(err), "handSize", 1, true) ~= nil, "error was " .. tostring(err))
            local cycle = CardCycle.new({ cards = { "slash", "guard" }, handSize = 1, seed = 1 })
            local dealt = cycle:hand()[1]
            assert(dealt == "slash" or dealt == "guard", "hand was " .. tostring(dealt))
            print('{"preview":true}')
        """)
        assert "preview" in out


if __name__ == "__main__":
    unittest.main()
