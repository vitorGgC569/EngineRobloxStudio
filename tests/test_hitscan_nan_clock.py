"""A hitscan shot cannot be recorded on a NaN clock.

tryFire writes the clock into lastFireAt whenever the cooldown check
does not fail. A NaN clock makes now - last < cooldown false, so the
shot is allowed and lastFireAt becomes NaN.
"""

from __future__ import annotations

import unittest
from pathlib import Path

from rqe.luau_harness import run_or_raise

ROOT = Path(__file__).resolve().parents[1]
FORGE = ROOT / "forge/luau/Forge"


def _run(libraries: list[Path], body: str) -> str:
    return run_or_raise(ROOT, libraries=libraries, body=body).stdout


class TestHitscanNanClock(unittest.TestCase):
    def test_nan_clock_does_not_fire(self) -> None:
        out = _run([FORGE / "Movement"], """
            local HitscanValidator = Require("HitscanValidator")
            local clock = 0/0
            local gun = HitscanValidator.new({
                cooldown = 0.1,
                clock = function()
                    return clock
                end,
            })
            local nanShot = gun:tryFire("a")
            assert(nanShot == false, "a NaN clock must not fire")
            clock = 0
            local shot = gun:tryFire("a")
            assert(shot == true, "a shot at clock 0 must fire")
            print('{"clock":0}')
        """)
        assert "clock" in out


if __name__ == "__main__":
    unittest.main()
