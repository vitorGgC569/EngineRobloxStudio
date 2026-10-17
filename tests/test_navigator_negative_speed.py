"""Navigator.new must refuse a speed that walks progress backwards.

Executed as real Luau through the pinned runtime, same harness as the mined
library specs. A negative speed is not a pace; 16 still walks toward the point.
"""

from __future__ import annotations

import unittest
from pathlib import Path

from rqe.luau_harness import run_or_raise

ROOT = Path(__file__).resolve().parents[1]
FORGE = ROOT / "forge/luau/Forge"


def _run(libraries: list[Path], body: str) -> str:
    return run_or_raise(ROOT, libraries=libraries, body=body).stdout


class TestNavigatorNegativeSpeed(unittest.TestCase):
    def test_negative_expected_speed_is_refused(self) -> None:
        """-1 is not a speed, and 16 still points toward the waypoint."""
        out = _run([FORGE / "AI"], """
            local Navigator = Require("Navigator")
            local ok = pcall(function()
                Navigator.new({
                    waypoints = { { x = 10, y = 0, z = 0 } },
                    expectedSpeed = -1,
                    clock = function()
                        return 0
                    end,
                })
            end)
            assert(ok == false, "negative expectedSpeed was accepted")
            local nav = Navigator.new({
                waypoints = { { x = 10, y = 0, z = 0 } },
                expectedSpeed = 16,
                stuckSeconds = 2.5,
                arriveDistance = 3,
                clock = function()
                    return 0
                end,
            })
            local direction, repathed = nav:update({ x = 0, y = 0, z = 0 }, 0.1)
            assert(type(direction) == "table" and direction.x > 0, "direction x was " .. tostring(direction and direction.x))
            assert(repathed == false, "update asked for a new path")
            print('{"speed":true}')
        """)
        assert "speed" in out


if __name__ == "__main__":
    unittest.main()
