"""A hitscan hit cannot be accepted when a coordinate is NaN.

checkHit rejects a hit only when dist > range. A NaN coordinate makes
dist NaN, and NaN > range is false, so the hit is accepted.
"""

from __future__ import annotations

import unittest
from pathlib import Path

from rqe.luau_harness import run_or_raise

ROOT = Path(__file__).resolve().parents[1]
FORGE = ROOT / "forge/luau/Forge"


def _run(libraries: list[Path], body: str) -> str:
    return run_or_raise(ROOT, libraries=libraries, body=body).stdout


class TestHitscanNanPoint(unittest.TestCase):
    def test_nan_coordinate_is_not_a_hit(self) -> None:
        out = _run([FORGE / "Movement"], """
            local HitscanValidator = Require("HitscanValidator")
            local gun = HitscanValidator.new({
                range = 100,
                cooldown = 0,
                clock = function() return 0 end,
            })
            local nanHit = gun:checkHit({ x = 0, y = 0, z = 0 }, { x = 0/0, y = 0, z = 0 })
            assert(nanHit == false, "a NaN coordinate must not count as a hit")
            local hit = gun:checkHit({ x = 0, y = 0, z = 0 }, { x = 10, y = 0, z = 0 })
            assert(hit == true, "a hit at x = 10 must still count")
            print('{"point":10}')
        """)
        assert "point" in out


if __name__ == "__main__":
    unittest.main()
