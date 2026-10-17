"""Crate rolls must keep their own drop tables.

A caller who changes a weight after `new`, or edits the drop `roll` handed
back, must not rewrite the pool later rolls still use.
"""

from __future__ import annotations

import unittest
from pathlib import Path

from rqe.luau_harness import run_or_raise

ROOT = Path(__file__).resolve().parents[1]
FORGE = ROOT / "forge/luau/Forge"


def _run(libraries: list[Path], body: str) -> str:
    return run_or_raise(ROOT, libraries=libraries, body=body).stdout


class TestCrateRollIsolation(unittest.TestCase):
    def test_mutations_after_new_and_after_roll_do_not_change_later_rolls(self) -> None:
        out = _run([FORGE / "Progression"], """
            local CrateRoll = Require("CrateRoll")
            local common = { id = "common", weight = 1, rarity = 1 }
            local rare = { id = "rare", weight = 1, rarity = 3 }
            local crate = CrateRoll.new({
                drops = { common, rare },
                pityThreshold = 100,
            })
            common.weight = 0
            local function zero()
                return 0
            end
            local first = crate:roll(zero)
            assert(first.id == "common", "first roll must stay common, got " .. tostring(first.id))
            first.weight = 0
            local second = crate:roll(zero)
            assert(second.id == "common", "second roll must stay common, got " .. tostring(second.id))
            print('{"crate":true}')
        """)
        assert "crate" in out


if __name__ == "__main__":
    unittest.main()
