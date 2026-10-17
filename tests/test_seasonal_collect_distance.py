"""A negative collect distance must not refuse the target underfoot.

Executed as real Luau through the pinned runtime. SeasonalEvent.canCollect
returns distance <= maxDistance, so maxDistance -1 is false even when the
collector is standing on the target.
"""

from __future__ import annotations

import unittest
from pathlib import Path

from rqe.luau_harness import run_or_raise

ROOT = Path(__file__).resolve().parents[1]
FORGE = ROOT / "forge/luau/Forge"


def _run(libraries: list[Path], body: str) -> str:
    return run_or_raise(ROOT, libraries=libraries, body=body).stdout


class TestSeasonalCollectDistance(unittest.TestCase):
    def test_a_negative_max_distance_still_reaches_the_target(self) -> None:
        out = _run([FORGE / "LiveOps"], """
            local SeasonalEvent = Require("SeasonalEvent")
            local event = SeasonalEvent.new({ currencyName = "tickets" })
            local onTarget = event:canCollect({ x = 0, z = 0 }, { x = 0, z = 0 }, -1)
            assert(onTarget == true, "standing on the target was refused")
            local far = event:canCollect({ x = 0, z = 0 }, { x = 100, z = 0 }, 1)
            assert(far == false, "a far target was collected")
            print('{"reach":true}')
        """)
        self.assertIn("reach", out)


if __name__ == "__main__":
    unittest.main()
