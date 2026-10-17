"""A claimed reward must not rewrite the next claim.

Executed as real Luau through the pinned runtime. PlaytimeLadder.define
stores rung.reward by reference, and claim returns that same table, so
setting coins on the claimed reward changes what the next claim hands out.
"""

from __future__ import annotations

import unittest
from pathlib import Path

from rqe.luau_harness import run_or_raise

ROOT = Path(__file__).resolve().parents[1]
FORGE = ROOT / "forge/luau/Forge"


def _run(libraries: list[Path], body: str) -> str:
    return run_or_raise(ROOT, libraries=libraries, body=body).stdout


class TestPlaytimeRewardIsolation(unittest.TestCase):
    def test_editing_a_claimed_reward_does_not_rewrite_the_next_claim(self) -> None:
        out = _run([FORGE / "Progression"], """
            local PlaytimeLadder = Require("PlaytimeLadder")
            local ladder = PlaytimeLadder.define("alias", {
                rungs = { { at = 0, reward = { coins = 1 } } },
            })
            local state = PlaytimeLadder.begin(ladder)
            local reward = PlaytimeLadder.claim(ladder, state, "rung1")
            reward.coins = 99
            local again = PlaytimeLadder.begin(ladder)
            local second = PlaytimeLadder.claim(ladder, again, "rung1")
            assert(second.coins == 1, "the second claim saw " .. tostring(second.coins))
            print('{"reward":true}')
        """)
        self.assertIn("reward", out)


if __name__ == "__main__":
    unittest.main()
