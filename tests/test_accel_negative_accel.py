"""An acceleration mover cannot be built with a negative moving rate.

new stores accelMoving or 8. In Luau, -1 is truthy, so it is kept. step
then computes 1 - exp(-rate * dt). A negative rate makes that factor
negative, so the velocity moves away from the target.
"""

from __future__ import annotations

import unittest
from pathlib import Path

from rqe.luau_harness import run_or_raise

ROOT = Path(__file__).resolve().parents[1]
FORGE = ROOT / "forge/luau/Forge"


def _run(libraries: list[Path], body: str) -> str:
    return run_or_raise(ROOT, libraries=libraries, body=body).stdout


class TestAccelNegativeAccel(unittest.TestCase):
    def test_negative_accel_moving_is_refused(self) -> None:
        out = _run([FORGE / "Movement"], """
            local AccelMove = Require("AccelMove")
            local negativeOk = pcall(function()
                AccelMove.new({ accelMoving = -1 })
            end)
            assert(negativeOk == false, "a negative moving rate must be refused")
            local mover = AccelMove.new({ maxSpeed = 16, accelMoving = 8 })
            local velocity = mover:step({ x = 1, z = 0 }, 1)
            assert(velocity.x > 0, "a forward wish must produce a forward velocity")
            print('{"accel":' .. tostring(velocity.x) .. '}')
        """)
        assert "accel" in out


if __name__ == "__main__":
    unittest.main()
