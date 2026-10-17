"""A saved claimed value that is not a table must not throw.

Executed as real Luau through the pinned runtime. PlaytimeLadder.begin
does `for key, value in restored.claimed or {}`. A saved 1 is truthy,
so the loop throws.
"""

from __future__ import annotations

import unittest
from pathlib import Path

from rqe.luau_harness import run_or_raise

ROOT = Path(__file__).resolve().parents[1]
FORGE = ROOT / "forge/luau/Forge"


def _run(libraries: list[Path], body: str) -> str:
    return run_or_raise(ROOT, libraries=libraries, body=body).stdout


class TestPlaytimeBadClaimed(unittest.TestCase):
    def test_a_non_table_claimed_value_does_not_throw(self) -> None:
        out = _run([FORGE / "Progression"], """
            local PlaytimeLadder = Require("PlaytimeLadder")
            local ladder = PlaytimeLadder.define("shift", {
                rungs = { { at = 0, reward = { coins = 1 } } },
            })
            local state
            local accepted = pcall(function()
                state = PlaytimeLadder.begin(ladder, { elapsed = 0, claimed = 1 })
            end)
            assert(accepted == true, "begin threw")
            assert(state.elapsed == 0, "elapsed became " .. tostring(state.elapsed))
            local claimed = PlaytimeLadder.begin(ladder, { elapsed = 0, claimed = { rung1 = true } })
            local reward = PlaytimeLadder.claim(ladder, claimed, "rung1")
            assert(reward == nil, "an already claimed rung paid out")
            print('{"claimed":true}')
        """)
        self.assertIn("claimed", out)


if __name__ == "__main__":
    unittest.main()
