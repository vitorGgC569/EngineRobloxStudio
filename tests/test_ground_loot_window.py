"""A negative owner window must not be stored.

Executed as real Luau through the pinned runtime. GroundLoot.new keeps
`ownerWindow = config.ownerWindow or 10`, so a negative window makes
ownerUntil land in the past and a stranger picks the drop up at once.
"""

from __future__ import annotations

import unittest
from pathlib import Path

from rqe.luau_harness import run_or_raise

ROOT = Path(__file__).resolve().parents[1]
FORGE = ROOT / "forge/luau/Forge"


def _run(libraries: list[Path], body: str) -> str:
    return run_or_raise(ROOT, libraries=libraries, body=body).stdout


class TestGroundLootWindow(unittest.TestCase):
    def test_a_negative_owner_window_is_refused(self) -> None:
        out = _run([FORGE / "Tycoon"], """
            local GroundLoot = Require("GroundLoot")
            local accepted = pcall(function()
                GroundLoot.new({ ownerWindow = -1, clock = function() return 0 end })
            end)
            assert(accepted == false, "a negative owner window was accepted")
            local loot = GroundLoot.new({ ownerWindow = 10, clock = function() return 0 end })
            local id = loot:drop("sword", 1, 7)
            local ok = loot:pickup(id, 99)
            assert(ok == false, "a stranger picked the drop up")
            print('{"window":true}')
        """)
        self.assertIn("window", out)


if __name__ == "__main__":
    unittest.main()
