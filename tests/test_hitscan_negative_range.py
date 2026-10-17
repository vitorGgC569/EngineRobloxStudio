"""A hitscan range cannot be negative.

new stores range or 1000. In Luau, -1 is truthy, so it is kept. checkHit
then treats every distance, including 0, as greater than -1, so a
point-blank hit is out of range.
"""

from __future__ import annotations

import unittest
from pathlib import Path

from rqe.luau_harness import run_or_raise

ROOT = Path(__file__).resolve().parents[1]
FORGE = ROOT / "forge/luau/Forge"


def _run(libraries: list[Path], body: str) -> str:
    return run_or_raise(ROOT, libraries=libraries, body=body).stdout


class TestHitscanNegativeRange(unittest.TestCase):
    def test_negative_range_is_refused(self) -> None:
        out = _run([FORGE / "Movement"], """
            local HitscanValidator = Require("HitscanValidator")
            local negativeOk = pcall(function()
                HitscanValidator.new({ range = -1, clock = function() return 0 end })
            end)
            assert(negativeOk == false, "a negative range must be refused")
            local gun = HitscanValidator.new({
                range = 100,
                cooldown = 0,
                clock = function() return 0 end,
            })
            local hit = gun:checkHit({ x = 0, y = 0, z = 0 }, { x = 10, y = 0, z = 0 })
            assert(hit == true, "a hit inside the range must count")
            print('{"range":100}')
        """)
        assert "range" in out


if __name__ == "__main__":
    unittest.main()
