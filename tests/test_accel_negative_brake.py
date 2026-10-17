"""An acceleration mover cannot be built with a negative braking rate.

new stores accelStopping or 6. In Luau, -1 is truthy, so it is kept. step
uses that rate when the desired direction is zero. A negative rate makes
1 - exp(-rate * dt) negative, so braking pushes the velocity away from zero.
"""

from __future__ import annotations

import unittest
from pathlib import Path

from rqe.luau_harness import run_or_raise

ROOT = Path(__file__).resolve().parents[1]
FORGE = ROOT / "forge/luau/Forge"


def _run(libraries: list[Path], body: str) -> str:
    return run_or_raise(ROOT, libraries=libraries, body=body).stdout


class TestAccelNegativeBrake(unittest.TestCase):
    def test_negative_accel_stopping_is_refused(self) -> None:
        out = _run([FORGE / "Movement"], """
            local AccelMove = Require("AccelMove")
            local negativeOk = pcall(function()
                AccelMove.new({ accelStopping = -1 })
            end)
            assert(negativeOk == false, "a negative braking rate must be refused")
            local mover = AccelMove.new({ maxSpeed = 16, accelStopping = 6 })
            local velocity = mover:step({ x = 0, z = 0 }, 1)
            assert(velocity.x == 0, "braking from rest must stay at rest")
            print('{"brake":0}')
        """)
        assert "brake" in out


if __name__ == "__main__":
    unittest.main()
