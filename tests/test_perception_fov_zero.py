"""A cone of 0 degrees must stay blind to a target off the facing axis.

`fovDeg or 180` treats an explicit 0 as missing and opens the sensor to a
full half-turn, so a target beside the facing direction gets remembered.
"""

from __future__ import annotations

import unittest
from pathlib import Path

from rqe.luau_harness import run_or_raise

ROOT = Path(__file__).resolve().parents[1]
FORGE = ROOT / "forge/luau/Forge"


def _run(libraries: list[Path], body: str) -> str:
    return run_or_raise(ROOT, libraries=libraries, body=body).stdout


class TestPerceptionFovZero(unittest.TestCase):
    def test_zero_fov_does_not_remember_a_target_off_to_the_side(self) -> None:
        out = _run([FORGE / "AI"], """
            local Perception = Require("Perception")
            local sensor = Perception.new({
                fovDeg = 0,
                clock = function()
                    return 0
                end,
                memorySeconds = 10,
            })
            sensor:setFacing(0, 1)
            sensor:observe({ x = 0, z = 0 }, {
                { key = "a", pos = { x = 5, z = 0 }, visible = true },
            })
            assert(#sensor:known() == 0, "zero fov must remember nothing, got " .. tostring(#sensor:known()))
            print('{"blind":true}')
        """)
        assert "blind" in out


if __name__ == "__main__":
    unittest.main()
