"""WaveSpawner.new must refuse a NaN clock reading.

Executed as real Luau through the pinned runtime, same harness as the mined
library specs. A clock that returns NaN must fail; a clock of 100 still spawns a base of 6.
"""

from __future__ import annotations

import unittest
from pathlib import Path

from rqe.luau_harness import run_or_raise

ROOT = Path(__file__).resolve().parents[1]
FORGE = ROOT / "forge/luau/Forge"


def _run(libraries: list[Path], body: str) -> str:
    return run_or_raise(ROOT, libraries=libraries, body=body).stdout


class TestWaveNanClock(unittest.TestCase):
    def test_nan_clock_is_refused(self) -> None:
        """new rejects a NaN clock, and a clock of 100 ticks a wave of 6."""
        out = _run([FORGE / "Match"], """
            local WaveSpawner = Require("WaveSpawner")
            local okNan = pcall(function()
                WaveSpawner.new({
                    firstDelaySeconds = 0,
                    clock = function()
                        return 0 / 0
                    end,
                })
            end)
            assert(okNan == false, "new(nan) was " .. tostring(okNan))
            local spawner = WaveSpawner.new({
                firstDelaySeconds = 0,
                baseSize = 6,
                clock = function()
                    return 100
                end,
            })
            local size = spawner:tick(0, 0)
            assert(size == 6, "wave size was " .. tostring(size))
            print('{"clock":true}')
        """)
        assert "clock" in out


if __name__ == "__main__":
    unittest.main()
