"""Stored waypoints must stay sealed after new.

Executed as real Luau through the pinned runtime. A shallow clone of the
waypoint list keeps each point shared with the caller, and currentGoal
hands that live point back, so moving x changes the direction update walks.
"""

from __future__ import annotations

import unittest
from pathlib import Path

from rqe.luau_harness import run_or_raise

ROOT = Path(__file__).resolve().parents[1]
FORGE = ROOT / "forge/luau/Forge"


def _run(libraries: list[Path], body: str) -> str:
    return run_or_raise(ROOT, libraries=libraries, body=body).stdout


class TestNavigatorIsolation(unittest.TestCase):
    def test_moving_a_waypoint_after_new_does_not_turn_the_walk(self) -> None:
        out = _run([FORGE / "AI"], """
            local Navigator = Require("Navigator")
            local point = { x = 10, y = 0, z = 0 }
            local nav = Navigator.new({
                waypoints = { point },
                arriveDistance = 1,
                stuckSeconds = 100,
                clock = function()
                    return 0
                end,
            })
            point.x = 0
            local direction = nav:update({ x = 0, y = 0, z = 0 }, 0)
            assert(direction.x > 0.5, "moving x after new turned the walk, got " .. tostring(direction.x))

            nav:currentGoal().x = 0
            local again = nav:update({ x = 0, y = 0, z = 0 }, 0)
            assert(again.x > 0.5, "editing currentGoal turned the walk, got " .. tostring(again.x))
            print('{"nav":true}')
        """)
        self.assertIn("nav", out)


if __name__ == "__main__":
    unittest.main()
