"""WaveSpawner.tick must schedule from the clock reading it already checked.

Executed as real Luau through the pinned runtime, same harness as the mined
library specs. A second reading of NaN must not make the next tick start early.
"""

from __future__ import annotations

import unittest
from pathlib import Path

from rqe.luau_harness import run_or_raise

ROOT = Path(__file__).resolve().parents[1]
FORGE = ROOT / "forge/luau/Forge"


def _run(libraries: list[Path], body: str) -> str:
    return run_or_raise(ROOT, libraries=libraries, body=body).stdout


class TestWaveSecondClock(unittest.TestCase):
    def test_second_clock_reading_does_not_start_the_next_wave(self) -> None:
        """The first tick returns 6, and the next tick returns nil."""
        out = _run([FORGE / "Match"], """
            local WaveSpawner = Require("WaveSpawner")
            local sequence = { 100, 100, 0 / 0, 101 }
            local i = 0
            local spawner = WaveSpawner.new({
                firstDelaySeconds = 0,
                baseSize = 6,
                waveIntervalSeconds = 30,
                clock = function()
                    i += 1
                    return sequence[i]
                end,
            })
            local first = spawner:tick(0, 0)
            assert(first == 6, "first wave was " .. tostring(first))
            local second = spawner:tick(0, 0)
            assert(second == nil, "second tick was " .. tostring(second))
            print('{"second":true}')
        """)
        assert "second" in out


if __name__ == "__main__":
    unittest.main()
