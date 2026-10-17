"""Memory tables returned by Perception.known must not stay live.

Executed as real Luau through the pinned runtime, same harness as the mined
library specs. Editing a position on the list known returns must not change
the next report.
"""

from __future__ import annotations

import unittest
from pathlib import Path

from rqe.luau_harness import run_or_raise

ROOT = Path(__file__).resolve().parents[1]
FORGE = ROOT / "forge/luau/Forge"


def _run(libraries: list[Path], body: str) -> str:
    return run_or_raise(ROOT, libraries=libraries, body=body).stdout


class TestPerceptionIsolation(unittest.TestCase):
    def test_returned_memory_does_not_rewrite_the_position(self) -> None:
        """The stored x stays 3 after the returned memory is edited."""
        out = _run([FORGE / "AI"], """
            local Perception = Require("Perception")
            local sensor = Perception.new({
                clock = function()
                    return 0
                end,
                fovDeg = 360,
                memorySeconds = 10,
            })
            sensor:observe({ x = 0, z = 0 }, {
                { key = "a", pos = { x = 3, z = 0 }, visible = true },
            })
            local first = sensor:known()
            first[1].pos.x = 99
            local second = sensor:known()
            assert(second[1].pos.x == 3, "known x was " .. tostring(second[1].pos.x))
            print('{"seen":true}')
        """)
        assert "seen" in out


if __name__ == "__main__":
    unittest.main()
