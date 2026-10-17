"""Milestone rewards must stay sealed after new and claim.

Executed as real Luau through the pinned runtime. The calendar stores the
caller's reward and claim hands that table back, so editing either one
changes the next grant.
"""

from __future__ import annotations

import unittest
from pathlib import Path

from rqe.luau_harness import run_or_raise

ROOT = Path(__file__).resolve().parents[1]
FORGE = ROOT / "forge/luau/Forge"


def _run(libraries: list[Path], body: str) -> str:
    return run_or_raise(ROOT, libraries=libraries, body=body).stdout


class TestDailyRewardIsolation(unittest.TestCase):
    def test_editing_a_reward_does_not_change_the_next_claim(self) -> None:
        out = _run([FORGE / "Progression"], """
            local DailyRewardCalendar = Require("DailyRewardCalendar")
            local reward = { id = "box" }
            local calendar = DailyRewardCalendar.new({
                milestones = { [1] = reward },
                now = function()
                    return 0
                end,
            })
            reward.id = "hacked"
            local _, granted = calendar:claim({ streak = 0 }, 0)
            assert(granted and granted.id == "box", "editing the caller's reward changed the grant, got " .. tostring(granted and granted.id))

            granted.id = "hacked"
            local _, again = calendar:claim({ streak = 0 }, 0)
            assert(again and again.id == "box", "editing the granted reward changed the next claim, got " .. tostring(again and again.id))
            print('{"daily":true}')
        """)
        self.assertIn("daily", out)


if __name__ == "__main__":
    unittest.main()
