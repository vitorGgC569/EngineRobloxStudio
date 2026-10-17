"""WaveSpawner.new must refuse a negative alive cap.

Executed as real Luau through the pinned runtime, same harness as the mined
library specs. A cap of -1 must fail; a cap of 40 still spawns a base of 6.
"""

from __future__ import annotations

import unittest
from pathlib import Path

from rqe.luau_harness import run_or_raise

ROOT = Path(__file__).resolve().parents[1]
FORGE = ROOT / "forge/luau/Forge"


def _run(libraries: list[Path], body: str) -> str:
    return run_or_raise(ROOT, libraries=libraries, body=body).stdout


class TestWaveNegativeAlive(unittest.TestCase):
    def test_negative_alive_cap_is_refused(self) -> None:
        """new rejects -1, and a cap of 40 ticks a wave of 6."""
        out = _run([FORGE / "Match"], """
            local WaveSpawner = Require("WaveSpawner")
            local okNegative = pcall(function()
                WaveSpawner.new({
                    maxAlive = -1,
                    clock = function()
                        return 0
                    end,
                })
            end)
            assert(okNegative == false, "new(-1) was " .. tostring(okNegative))
            local spawner = WaveSpawner.new({
                maxAlive = 40,
                baseSize = 6,
                firstDelaySeconds = 0,
                clock = function()
                    return 100
                end,
            })
            local size = spawner:tick(0, 0)
            assert(size == 6, "wave size was " .. tostring(size))
            print('{"alive":true}')
        """)
        assert "alive" in out


if __name__ == "__main__":
    unittest.main()
