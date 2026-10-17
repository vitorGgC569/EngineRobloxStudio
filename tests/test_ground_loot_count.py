"""A ground drop cannot store a zero or negative stack.

GroundLoot.drop kept any count, and pickup handed that count back, so a
caller could add a negative stack.
"""

from __future__ import annotations

import unittest
from pathlib import Path

from rqe.luau_harness import run_or_raise

ROOT = Path(__file__).resolve().parents[1]
FORGE = ROOT / "forge/luau/Forge"


def _run(libraries: list[Path], body: str) -> str:
    return run_or_raise(ROOT, libraries=libraries, body=body).stdout


class TestGroundLootCount(unittest.TestCase):
    def test_drop_rejects_non_positive_counts(self) -> None:
        out = _run([FORGE / "Tycoon"], """
            local GroundLoot = Require("GroundLoot")
            local loot = GroundLoot.new({ clock = function() return 0 end })
            local zeroOk = pcall(function()
                loot:drop("sword", 0)
            end)
            assert(zeroOk == false, "a count of 0 must be refused")
            local negativeOk = pcall(function()
                loot:drop("sword", -2)
            end)
            assert(negativeOk == false, "a negative count must be refused")
            local id = loot:drop("sword", 1)
            assert(type(id) == "string", "a count of 1 must return a drop id")
            local ok, _reason, _item, count = loot:pickup(id, 1)
            assert(ok == true and count == 1, "pickup must hand back one")
            print('{"loot":1}')
        """)
        assert "loot" in out


if __name__ == "__main__":
    unittest.main()
