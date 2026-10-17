"""WaveSpawner.new must refuse a negative first delay.

Executed as real Luau through the pinned runtime, same harness as the mined
library specs. A delay of -1 must fail; a delay of 0 still spawns a base of 6.
"""

from __future__ import annotations

import unittest
from pathlib import Path

from rqe.luau_harness import run_or_raise

ROOT = Path(__file__).resolve().parents[1]
FORGE = ROOT / "forge/luau/Forge"


def _run(libraries: list[Path], body: str) -> str:
    return run_or_raise(ROOT, libraries=libraries, body=body).stdout


class TestWaveNegativeDelay(unittest.TestCase):
    def test_negative_first_delay_is_refused(self) -> None:
        """new rejects -1, and a delay of 0 ticks a wave of 6."""
        out = _run([FORGE / "Match"], """
            local WaveSpawner = Require("WaveSpawner")
            local okNegative = pcall(function()
                WaveSpawner.new({
                    firstDelaySeconds = -1,
                    clock = function()
                        return 0
                    end,
                })
            end)
            assert(okNegative == false, "new(-1) was " .. tostring(okNegative))
            local spawner = WaveSpawner.new({
                firstDelaySeconds = 0,
                baseSize = 6,
                clock = function()
                    return 100
                end,
            })
            local size = spawner:tick(0, 0)
            assert(size == 6, "wave size was " .. tostring(size))
            print('{"delay":true}')
        """)
        assert "delay" in out


if __name__ == "__main__":
    unittest.main()
