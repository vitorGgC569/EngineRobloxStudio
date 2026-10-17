"""A ladder id must be a non-empty string.

Executed as real Luau through the pinned runtime. PlaytimeLadder.define
stores any id, including "". get("") then returns that ladder, and a
second define("") overwrites it.
"""

from __future__ import annotations

import unittest
from pathlib import Path

from rqe.luau_harness import run_or_raise

ROOT = Path(__file__).resolve().parents[1]
FORGE = ROOT / "forge/luau/Forge"


def _run(libraries: list[Path], body: str) -> str:
    return run_or_raise(ROOT, libraries=libraries, body=body).stdout


class TestPlaytimeEmptyLadderId(unittest.TestCase):
    def test_an_empty_ladder_id_is_refused(self) -> None:
        out = _run([FORGE / "Progression"], """
            local PlaytimeLadder = Require("PlaytimeLadder")
            local accepted = pcall(function()
                PlaytimeLadder.define("", {
                    rungs = { { at = 10, reward = { coins = 1 } } },
                })
            end)
            assert(accepted == false, "an empty ladder id was accepted")
            local ladder = PlaytimeLadder.define("shift", {
                rungs = { { at = 0, reward = { coins = 1 } } },
            })
            local state = PlaytimeLadder.begin(ladder)
            local reward = PlaytimeLadder.claim(ladder, state, "rung1")
            assert(reward.coins == 1, "the named ladder paid " .. tostring(reward and reward.coins))
            print('{"ladder":true}')
        """)
        self.assertIn("ladder", out)


if __name__ == "__main__":
    unittest.main()
