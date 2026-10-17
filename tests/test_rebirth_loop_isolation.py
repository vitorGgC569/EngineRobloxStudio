"""A rebirth plan must keep its own copies of the reward tables.

RebirthLoop.new stored rewardsOnLife by reference, and execute inserted those
same tables into the plan. Editing the caller's count, or a previous plan's
award, changed the next execute.
"""

from __future__ import annotations

import unittest
from pathlib import Path

from rqe.luau_harness import run_or_raise

ROOT = Path(__file__).resolve().parents[1]
FORGE = ROOT / "forge/luau/Forge"


def _run(libraries: list[Path], body: str) -> str:
    return run_or_raise(ROOT, libraries=libraries, body=body).stdout


class TestRebirthLoopIsolation(unittest.TestCase):
    def test_reward_edits_do_not_change_later_awards(self) -> None:
        out = _run([FORGE / "Progression"], """
            local RebirthLoop = Require("RebirthLoop")
            local reward = { id = "gem", count = 1 }
            local loop = RebirthLoop.new({
                price = function(_life) return 10 end,
                rewardsOnLife = { [1] = { reward } },
            })
            reward.count = 99
            local first = loop:execute({ life = 0, balance = 10 })
            assert(first.awards[1].count == 1, "the first award must keep the count from new")
            first.awards[1].count = 5
            local second = loop:execute({ life = 0, balance = 10 })
            assert(second.awards[1].count == 1, "a later execute must not see the edited award")
            print('{"rebirth":1}')
        """)
        assert "rebirth" in out


if __name__ == "__main__":
    unittest.main()
