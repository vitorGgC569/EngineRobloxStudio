"""A NaN timestep must not poison the velocity.

step computes 1 - exp(-rate * dt) for any dt. A NaN dt makes that factor
NaN, and the velocity stays NaN afterwards, so a later real step does
not move forward.
"""

from __future__ import annotations

import unittest
from pathlib import Path

from rqe.luau_harness import run_or_raise

ROOT = Path(__file__).resolve().parents[1]
FORGE = ROOT / "forge/luau/Forge"


def _run(libraries: list[Path], body: str) -> str:
    return run_or_raise(ROOT, libraries=libraries, body=body).stdout


class TestAccelNanStep(unittest.TestCase):
    def test_nan_dt_does_not_poison_a_later_step(self) -> None:
        out = _run([FORGE / "Movement"], """
            local AccelMove = Require("AccelMove")
            local mover = AccelMove.new({ maxSpeed = 16 })
            local skipped = mover:step({ x = 1, z = 0 }, 0/0)
            assert(skipped.x == 0, "a NaN step must leave the velocity at rest")
            local velocity = mover:step({ x = 1, z = 0 }, 1)
            assert(velocity.x > 0, "a later real step must still move forward")
            print('{"step":' .. tostring(velocity.x) .. '}')
        """)
        assert "step" in out


if __name__ == "__main__":
    unittest.main()
