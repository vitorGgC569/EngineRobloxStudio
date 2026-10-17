"""Seasonal milestones must not stay shared with the caller.

Raising `at` on the table passed into `new` must not move the threshold
`milestonesReached` still uses.
"""

from __future__ import annotations

import unittest
from pathlib import Path

from rqe.luau_harness import run_or_raise

ROOT = Path(__file__).resolve().parents[1]
FORGE = ROOT / "forge/luau/Forge"


def _run(libraries: list[Path], body: str) -> str:
    return run_or_raise(ROOT, libraries=libraries, body=body).stdout


class TestSeasonalEventIsolation(unittest.TestCase):
    def test_raising_at_after_new_does_not_move_the_milestone(self) -> None:
        out = _run([FORGE / "LiveOps"], """
            local SeasonalEvent = Require("SeasonalEvent")
            local milestone = { at = 10, rewardId = "hat" }
            local event = SeasonalEvent.new({
                currencyName = "tickets",
                milestones = { milestone },
            })
            milestone.at = 1000
            local reached = event:milestonesReached(10, {})
            local found = false
            for _, rewardId in reached do
                if rewardId == "hat" then
                    found = true
                end
            end
            assert(found, "milestonesReached(10) must still contain hat")
            print('{"season":true}')
        """)
        assert "season" in out


if __name__ == "__main__":
    unittest.main()
