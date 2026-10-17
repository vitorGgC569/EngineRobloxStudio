"""Navigator.new must refuse a stuck window that fires on the first update.

Executed as real Luau through the pinned runtime, same harness as the mined
library specs. A negative window is not a delay; 2.5 still walks the waypoint.
"""

from __future__ import annotations

import unittest
from pathlib import Path

from rqe.luau_harness import run_or_raise

ROOT = Path(__file__).resolve().parents[1]
FORGE = ROOT / "forge/luau/Forge"


def _run(libraries: list[Path], body: str) -> str:
    return run_or_raise(ROOT, libraries=libraries, body=body).stdout


class TestNavigatorNegativeStuck(unittest.TestCase):
    def test_negative_stuck_seconds_is_refused(self) -> None:
        """-1 is not a stuck window, and 2.5 does not repath on the first update."""
        out = _run([FORGE / "AI"], """
            local Navigator = Require("Navigator")
            local ok = pcall(function()
                Navigator.new({
                    waypoints = { { x = 10, y = 0, z = 0 } },
                    stuckSeconds = -1,
                    clock = function()
                        return 0
                    end,
                })
            end)
            assert(ok == false, "negative stuckSeconds was accepted")
            local nav = Navigator.new({
                waypoints = { { x = 10, y = 0, z = 0 } },
                stuckSeconds = 2.5,
                clock = function()
                    return 0
                end,
                requestPath = function()
                    return { { x = 1, y = 0, z = 0 } }
                end,
            })
            local direction, repathed = nav:update({ x = 0, y = 0, z = 0 }, 0.1)
            assert(type(direction) == "table" and direction.x ~= 0, "update returned no direction")
            assert(repathed == false, "update asked for a new path")
            print('{"stuck":true}')
        """)
        assert "stuck" in out


if __name__ == "__main__":
    unittest.main()
