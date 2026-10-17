"""Two rungs must not share an id.

Executed as real Luau through the pinned runtime. PlaytimeLadder.define
stores both rungs, and claim returns the first match, so the second rung
can never be taken.
"""

from __future__ import annotations

import unittest
from pathlib import Path

from rqe.luau_harness import run_or_raise

ROOT = Path(__file__).resolve().parents[1]
FORGE = ROOT / "forge/luau/Forge"


def _run(libraries: list[Path], body: str) -> str:
    return run_or_raise(ROOT, libraries=libraries, body=body).stdout


class TestPlaytimeDuplicateRung(unittest.TestCase):
    def test_a_duplicate_rung_id_is_refused(self) -> None:
        out = _run([FORGE / "Progression"], """
            local PlaytimeLadder = Require("PlaytimeLadder")
            local accepted = pcall(function()
                PlaytimeLadder.define("dup", {
                    rungs = {
                        { at = 0, id = "same", reward = { coins = 1 } },
                        { at = 10, id = "same", reward = { coins = 2 } },
                    },
                })
            end)
            assert(accepted == false, "a duplicate rung id was accepted")
            local ladder = PlaytimeLadder.define("named", {
                rungs = { { at = 0, reward = { coins = 1 } } },
            })
            local state = PlaytimeLadder.begin(ladder)
            local reward = PlaytimeLadder.claim(ladder, state, "rung1")
            assert(reward.coins == 1, "the generated id paid " .. tostring(reward and reward.coins))
            print('{"dup":true}')
        """)
        self.assertIn("dup", out)


if __name__ == "__main__":
    unittest.main()
