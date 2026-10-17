"""A ladder id must not be registered twice.

Executed as real Luau through the pinned runtime. PlaytimeLadder.define
assigns ladders[id] even when that id is already registered, so the
second definition replaces the first and get pays the new reward.
"""

from __future__ import annotations

import unittest
from pathlib import Path

from rqe.luau_harness import run_or_raise

ROOT = Path(__file__).resolve().parents[1]
FORGE = ROOT / "forge/luau/Forge"


def _run(libraries: list[Path], body: str) -> str:
    return run_or_raise(ROOT, libraries=libraries, body=body).stdout


class TestPlaytimeDuplicateLadder(unittest.TestCase):
    def test_a_second_define_of_the_same_id_is_refused(self) -> None:
        out = _run([FORGE / "Progression"], """
            local PlaytimeLadder = Require("PlaytimeLadder")
            PlaytimeLadder.define("shift", {
                rungs = { { at = 0, reward = { coins = 1 } } },
            })
            local accepted = pcall(function()
                PlaytimeLadder.define("shift", {
                    rungs = { { at = 0, reward = { coins = 9 } } },
                })
            end)
            assert(accepted == false, "a second define was accepted")
            local ladder = PlaytimeLadder.get("shift")
            local state = PlaytimeLadder.begin(ladder)
            local reward = PlaytimeLadder.claim(ladder, state, "rung1")
            assert(reward.coins == 1, "the claim paid " .. tostring(reward and reward.coins))
            print('{"twice":true}')
        """)
        self.assertIn("twice", out)


if __name__ == "__main__":
    unittest.main()
