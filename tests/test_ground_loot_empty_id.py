"""GroundLoot.drop must refuse an empty item id.

Executed as real Luau through the pinned runtime, same harness as the mined
library specs. An empty id must fail; a sword drop still picks up as one sword.
"""

from __future__ import annotations

import unittest
from pathlib import Path

from rqe.luau_harness import run_or_raise

ROOT = Path(__file__).resolve().parents[1]
FORGE = ROOT / "forge/luau/Forge"


def _run(libraries: list[Path], body: str) -> str:
    return run_or_raise(ROOT, libraries=libraries, body=body).stdout


class TestGroundLootEmptyId(unittest.TestCase):
    def test_empty_item_id_is_refused(self) -> None:
        """drop('') fails, and a sword drop picks up as one sword."""
        out = _run([FORGE / "Tycoon"], """
            local GroundLoot = Require("GroundLoot")
            local loot = GroundLoot.new({
                clock = function()
                    return 0
                end,
            })
            local okEmpty = pcall(function()
                loot:drop("", 1)
            end)
            assert(okEmpty == false, "empty drop was " .. tostring(okEmpty))
            local dropId = loot:drop("sword", 1)
            assert(type(dropId) == "string", "drop id was " .. tostring(dropId))
            local ok, _, itemId, count = loot:pickup(dropId, 1)
            assert(ok == true, "pickup was " .. tostring(ok))
            assert(itemId == "sword", "item id was " .. tostring(itemId))
            assert(count == 1, "count was " .. tostring(count))
            print('{"loot":true}')
        """)
        assert "loot" in out


if __name__ == "__main__":
    unittest.main()
