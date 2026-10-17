"""A negative grace must not be stored.

Executed as real Luau through the pinned runtime. PlaytimeLadder.define
keeps graceSeconds or 20. -1 is truthy, so the first idle second already
stops the clock.
"""

from __future__ import annotations

import unittest
from pathlib import Path

from rqe.luau_harness import run_or_raise

ROOT = Path(__file__).resolve().parents[1]
FORGE = ROOT / "forge/luau/Forge"


def _run(libraries: list[Path], body: str) -> str:
    return run_or_raise(ROOT, libraries=libraries, body=body).stdout


class TestPlaytimeNegativeGrace(unittest.TestCase):
    def test_a_negative_grace_is_refused(self) -> None:
        out = _run([FORGE / "Progression"], """
            local PlaytimeLadder = Require("PlaytimeLadder")
            local accepted = pcall(function()
                PlaytimeLadder.define("badgrace", {
                    graceSeconds = -1,
                    rungs = { { at = 10, reward = { coins = 1 } } },
                })
            end)
            assert(accepted == false, "a negative grace was accepted")
            local ladder = PlaytimeLadder.define("shiftgrace", {
                graceSeconds = 20,
                rungs = { { at = 10, reward = { coins = 1 } } },
            })
            local state = PlaytimeLadder.begin(ladder)
            local credited = PlaytimeLadder.tick(ladder, state, 1, false)
            assert(credited == 1, "the first idle second credited " .. tostring(credited))
            assert(state.elapsed == 1, "elapsed is " .. tostring(state.elapsed))
            print('{"grace":true}')
        """)
        self.assertIn("grace", out)


if __name__ == "__main__":
    unittest.main()
