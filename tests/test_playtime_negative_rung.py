"""A negative rung must not be claimable at elapsed 0.

Executed as real Luau through the pinned runtime. PlaytimeLadder.define
stores rung.at with no check. A fresh state has elapsed 0, and 0 >= -1,
so the rung is claimable before any time is spent.
"""

from __future__ import annotations

import unittest
from pathlib import Path

from rqe.luau_harness import run_or_raise

ROOT = Path(__file__).resolve().parents[1]
FORGE = ROOT / "forge/luau/Forge"


def _run(libraries: list[Path], body: str) -> str:
    return run_or_raise(ROOT, libraries=libraries, body=body).stdout


class TestPlaytimeNegativeRung(unittest.TestCase):
    def test_a_negative_rung_is_refused(self) -> None:
        out = _run([FORGE / "Progression"], """
            local PlaytimeLadder = Require("PlaytimeLadder")
            local accepted = pcall(function()
                PlaytimeLadder.define("badrung", {
                    rungs = { { at = -1, reward = { coins = 1 } } },
                })
            end)
            assert(accepted == false, "a negative rung was accepted")
            local ladder = PlaytimeLadder.define("goodrung", {
                rungs = { { at = 10, reward = { coins = 1 } } },
            })
            local state = PlaytimeLadder.begin(ladder)
            assert(#PlaytimeLadder.claimable(ladder, state) == 0, "a fresh ladder was already claimable")
            PlaytimeLadder.tick(ladder, state, 10, true)
            assert(#PlaytimeLadder.claimable(ladder, state) == 1, "the rung at 10 was not claimable")
            print('{"rung":true}')
        """)
        self.assertIn("rung", out)


if __name__ == "__main__":
    unittest.main()
