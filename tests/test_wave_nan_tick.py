"""WaveSpawner.tick must ignore a NaN clock reading.

Executed as real Luau through the pinned runtime, same harness as the mined
library specs. After a real wave, a NaN reading must not start another, and a
later clock of 130 still does.
"""

from __future__ import annotations

import unittest
from pathlib import Path

from rqe.luau_harness import run_or_raise

ROOT = Path(__file__).resolve().parents[1]
FORGE = ROOT / "forge/luau/Forge"


def _run(libraries: list[Path], body: str) -> str:
    return run_or_raise(ROOT, libraries=libraries, body=body).stdout


class TestWaveNanTick(unittest.TestCase):
    def test_nan_tick_does_not_start_a_wave(self) -> None:
        """A NaN tick returns nil, and clock 130 still starts the next wave."""
        out = _run([FORGE / "Match"], """
            local WaveSpawner = Require("WaveSpawner")
            local clock = 100
            local spawner = WaveSpawner.new({
                firstDelaySeconds = 0,
                baseSize = 6,
                waveIntervalSeconds = 30,
                clock = function()
                    return clock
                end,
            })
            local first = spawner:tick(0, 0)
            assert(first == 6, "first wave was " .. tostring(first))
            clock = 0 / 0
            local nanTick = spawner:tick(0, 0)
            assert(nanTick == nil, "nan tick was " .. tostring(nanTick))
            clock = 130
            local later = spawner:tick(0, 0)
            assert(later == 6, "later wave was " .. tostring(later))
            print('{"tick":true}')
        """)
        assert "tick" in out


if __name__ == "__main__":
    unittest.main()
