"""An acceleration mover cannot be built with a negative max speed.

new stores maxSpeed or 16. In Luau, -1 is truthy, so it is kept. step
then aims at a negative speed, so the velocity points backward.
"""

from __future__ import annotations

import unittest
from pathlib import Path

from rqe.luau_harness import run_or_raise

ROOT = Path(__file__).resolve().parents[1]
FORGE = ROOT / "forge/luau/Forge"


def _run(libraries: list[Path], body: str) -> str:
    return run_or_raise(ROOT, libraries=libraries, body=body).stdout


class TestAccelNegativeSpeed(unittest.TestCase):
    def test_negative_max_speed_is_refused(self) -> None:
        out = _run([FORGE / "Movement"], """
            local AccelMove = Require("AccelMove")
            local negativeOk = pcall(function()
                AccelMove.new({ maxSpeed = -1 })
            end)
            assert(negativeOk == false, "a negative max speed must be refused")
            local mover = AccelMove.new({ maxSpeed = 16 })
            local velocity = mover:step({ x = 1, z = 0 }, 1)
            assert(velocity.x > 0, "a forward wish must produce a forward velocity")
            print('{"speed":' .. tostring(velocity.x) .. '}')
        """)
        assert "speed" in out


if __name__ == "__main__":
    unittest.main()
