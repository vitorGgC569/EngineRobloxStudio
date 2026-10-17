"""Navigator.new must refuse an arrive radius that can never be reached.

Executed as real Luau through the pinned runtime, same harness as the mined
library specs. A negative radius is not a range; 3 still finishes on the point.
"""

from __future__ import annotations

import unittest
from pathlib import Path

from rqe.luau_harness import run_or_raise

ROOT = Path(__file__).resolve().parents[1]
FORGE = ROOT / "forge/luau/Forge"


def _run(libraries: list[Path], body: str) -> str:
    return run_or_raise(ROOT, libraries=libraries, body=body).stdout


class TestNavigatorNegativeArrive(unittest.TestCase):
    def test_negative_arrive_distance_is_refused(self) -> None:
        """-1 is not an arrive radius, and 3 finishes while standing on the point."""
        out = _run([FORGE / "AI"], """
            local Navigator = Require("Navigator")
            local ok = pcall(function()
                Navigator.new({
                    waypoints = { { x = 0, y = 0, z = 0 } },
                    arriveDistance = -1,
                    clock = function()
                        return 0
                    end,
                })
            end)
            assert(ok == false, "negative arriveDistance was accepted")
            local nav = Navigator.new({
                waypoints = { { x = 0, y = 0, z = 0 } },
                arriveDistance = 3,
                stuckSeconds = 2.5,
                clock = function()
                    return 0
                end,
            })
            nav:update({ x = 0, y = 0, z = 0 }, 0.1)
            assert(nav:finished() == true, "navigator did not arrive")
            print('{"arrive":true}')
        """)
        assert "arrive" in out


if __name__ == "__main__":
    unittest.main()
