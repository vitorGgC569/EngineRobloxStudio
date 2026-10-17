"""WaveSpawner.new must refuse a negative per-player bonus.

Executed as real Luau through the pinned runtime, same harness as the mined
library specs. A bonus of -1 must fail; a bonus of 2 still spawns a base of 6.
"""

from __future__ import annotations

import unittest
from pathlib import Path

from rqe.luau_harness import run_or_raise

ROOT = Path(__file__).resolve().parents[1]
FORGE = ROOT / "forge/luau/Forge"


def _run(libraries: list[Path], body: str) -> str:
    return run_or_raise(ROOT, libraries=libraries, body=body).stdout


class TestWaveNegativeBonus(unittest.TestCase):
    def test_negative_per_player_bonus_is_refused(self) -> None:
        """new rejects -1, and a bonus of 2 ticks a wave of 6."""
        out = _run([FORGE / "Match"], """
            local WaveSpawner = Require("WaveSpawner")
            local okNegative = pcall(function()
                WaveSpawner.new({
                    perPlayerBonus = -1,
                    clock = function()
                        return 0
                    end,
                })
            end)
            assert(okNegative == false, "new(-1) was " .. tostring(okNegative))
            local spawner = WaveSpawner.new({
                perPlayerBonus = 2,
                baseSize = 6,
                firstDelaySeconds = 0,
                clock = function()
                    return 100
                end,
            })
            local size = spawner:tick(0, 0)
            assert(size == 6, "wave size was " .. tostring(size))
            print('{"bonus":true}')
        """)
        assert "bonus" in out


if __name__ == "__main__":
    unittest.main()
