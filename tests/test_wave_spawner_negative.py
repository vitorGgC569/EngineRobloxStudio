"""A wave size cannot be negative.

WaveSpawner.tick folds playerCount straight into the size. A negative count
makes baseSize + floor(playerCount * perPlayerBonus * growth) negative, and
the returned size is that number.
"""

from __future__ import annotations

import unittest
from pathlib import Path

from rqe.luau_harness import run_or_raise

ROOT = Path(__file__).resolve().parents[1]
FORGE = ROOT / "forge/luau/Forge"


def _run(libraries: list[Path], body: str) -> str:
    return run_or_raise(ROOT, libraries=libraries, body=body).stdout


class TestWaveSpawnerNegative(unittest.TestCase):
    def test_negative_player_count_does_not_return_a_negative_size(self) -> None:
        out = _run([FORGE / "Match"], """
            local WaveSpawner = Require("WaveSpawner")
            local spawner = WaveSpawner.new({
                baseSize = 6,
                perPlayerBonus = 2,
                maxWaveSize = 24,
                maxAlive = 40,
                firstDelaySeconds = 0,
                clock = function() return 0 end,
            })
            local size = spawner:tick(-10, 0)
            assert(size ~= nil, "a due wave must still return a size")
            assert(size >= 0, "a wave cannot spawn a negative number of enemies")
            print('{"wave":' .. tostring(size) .. '}')
        """)
        assert "wave" in out


if __name__ == "__main__":
    unittest.main()
