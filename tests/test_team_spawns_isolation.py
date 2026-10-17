"""Stored spawn points must stay sealed after register.

Executed as real Luau through the pinned runtime. A shallow clone of the
point list keeps each point shared with the caller, so moving x after
register changes the next pick.
"""

from __future__ import annotations

import unittest
from pathlib import Path

from rqe.luau_harness import run_or_raise

ROOT = Path(__file__).resolve().parents[1]
FORGE = ROOT / "forge/luau/Forge"


def _run(libraries: list[Path], body: str) -> str:
    return run_or_raise(ROOT, libraries=libraries, body=body).stdout


class TestTeamSpawnsIsolation(unittest.TestCase):
    def test_moving_a_point_after_register_does_not_move_the_pick(self) -> None:
        out = _run([FORGE / "Match"], """
            local TeamSpawns = Require("TeamSpawns")
            local spawns = TeamSpawns.new(function()
                return 0
            end)
            local point = { x = 4, y = 1, z = 2 }
            spawns:register("red", { point })
            point.x = 99
            local picked = spawns:pick("red")
            assert(picked, "pick")
            assert(picked.x == 4, "moving x after register changed the pick, got " .. tostring(picked.x))
            print('{"spawn":true}')
        """)
        self.assertIn("spawn", out)


if __name__ == "__main__":
    unittest.main()
