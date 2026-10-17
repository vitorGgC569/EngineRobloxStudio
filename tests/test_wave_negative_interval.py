"""WaveSpawner.new must refuse a negative wave interval.

Executed as real Luau through the pinned runtime, same harness as the mined
library specs. An interval of -1 must fail; an interval of 30 still spawns a base of 6.
"""

from __future__ import annotations

import unittest
from pathlib import Path

from rqe.luau_harness import run_or_raise

ROOT = Path(__file__).resolve().parents[1]
FORGE = ROOT / "forge/luau/Forge"


def _run(libraries: list[Path], body: str) -> str:
    return run_or_raise(ROOT, libraries=libraries, body=body).stdout


class TestWaveNegativeInterval(unittest.TestCase):
    def test_negative_wave_interval_is_refused(self) -> None:
        """new rejects -1, and an interval of 30 ticks a wave of 6."""
        out = _run([FORGE / "Match"], """
            local WaveSpawner = Require("WaveSpawner")
            local okNegative = pcall(function()
                WaveSpawner.new({
                    waveIntervalSeconds = -1,
                    clock = function()
                        return 0
                    end,
                })
            end)
            assert(okNegative == false, "new(-1) was " .. tostring(okNegative))
            local spawner = WaveSpawner.new({
                waveIntervalSeconds = 30,
                baseSize = 6,
                firstDelaySeconds = 0,
                clock = function()
                    return 100
                end,
            })
            local size = spawner:tick(0, 0)
            assert(size == 6, "wave size was " .. tostring(size))
            print('{"interval":true}')
        """)
        assert "interval" in out


if __name__ == "__main__":
    unittest.main()
