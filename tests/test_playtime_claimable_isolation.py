"""Listing claimable rungs must not rewrite the claim.

Executed as real Luau through the pinned runtime. PlaytimeLadder.claimable
inserts the stored rung, so setting coins on claimable()[1].reward changes
the reward claim later hands out.
"""

from __future__ import annotations

import unittest
from pathlib import Path

from rqe.luau_harness import run_or_raise

ROOT = Path(__file__).resolve().parents[1]
FORGE = ROOT / "forge/luau/Forge"


def _run(libraries: list[Path], body: str) -> str:
    return run_or_raise(ROOT, libraries=libraries, body=body).stdout


class TestPlaytimeClaimableIsolation(unittest.TestCase):
    def test_editing_a_waiting_reward_does_not_rewrite_the_claim(self) -> None:
        out = _run([FORGE / "Progression"], """
            local PlaytimeLadder = Require("PlaytimeLadder")
            local ladder = PlaytimeLadder.define("ready", {
                rungs = { { at = 0, reward = { coins = 1 } } },
            })
            local state = PlaytimeLadder.begin(ladder)
            local waiting = PlaytimeLadder.claimable(ladder, state)
            waiting[1].reward.coins = 99
            local reward = PlaytimeLadder.claim(ladder, state, "rung1")
            assert(reward.coins == 1, "the claim saw " .. tostring(reward.coins))
            print('{"claimable":true}')
        """)
        self.assertIn("claimable", out)


if __name__ == "__main__":
    unittest.main()
