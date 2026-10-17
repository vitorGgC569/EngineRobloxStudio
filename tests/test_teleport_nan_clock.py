"""A NaN clock must not be stored as the last jump time.

use reads the clock and writes it to lastUsedAt before checking that it
is finite. NaN < seconds is false, so the jump succeeds. Every later
real timestamp then computes NaN and the pad never cools down.
"""

from __future__ import annotations

import unittest
from pathlib import Path

from rqe.luau_harness import run_or_raise

ROOT = Path(__file__).resolve().parents[1]
FORGE = ROOT / "forge/luau/Forge"


def _run(libraries: list[Path], body: str) -> str:
    return run_or_raise(ROOT, libraries=libraries, body=body).stdout


class TestTeleportNanClock(unittest.TestCase):
    def test_nan_clock_does_not_jump_or_clear_cooldown(self) -> None:
        out = _run([FORGE / "Movement"], """
            local TeleportPads = Require("TeleportPads")
            local clock = 0
            local pads = TeleportPads.new(function()
                return clock
            end)
            pads:define("a", "b", 2)
            pads:define("b", "a", 2)
            local first = pads:use("a")
            assert(first == "b", "the first use must arrive at b")
            clock = 0/0
            local nanDest = pads:use("a")
            assert(nanDest == nil, "a NaN clock must not jump")
            clock = 0
            local later, reason = pads:use("a")
            assert(later == nil and reason == "pad_cooldown", "the real clock must still be cooling down")
            print('{"clock":"cooldown"}')
        """)
        assert "clock" in out


if __name__ == "__main__":
    unittest.main()
