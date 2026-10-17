"""A saved NaN elapsed must not be restored.

Executed as real Luau through the pinned runtime. PlaytimeLadder.begin
stores restored.elapsed or 0 for a lifetime ladder. NaN is truthy, so
later comparisons are false and the ladder never reaches a rung.
"""

from __future__ import annotations

import unittest
from pathlib import Path

from rqe.luau_harness import run_or_raise

ROOT = Path(__file__).resolve().parents[1]
FORGE = ROOT / "forge/luau/Forge"


def _run(libraries: list[Path], body: str) -> str:
    return run_or_raise(ROOT, libraries=libraries, body=body).stdout


class TestPlaytimeNanElapsed(unittest.TestCase):
    def test_a_saved_nan_elapsed_becomes_zero(self) -> None:
        out = _run([FORGE / "Progression"], """
            local PlaytimeLadder = Require("PlaytimeLadder")
            local keptLadder = PlaytimeLadder.define("kept", {
                scope = "lifetime",
                rungs = { { at = 10, reward = { coins = 1 } } },
            })
            local kept = PlaytimeLadder.begin(keptLadder, { elapsed = 5, claimed = {} })
            assert(kept.elapsed == 5, "saved elapsed became " .. tostring(kept.elapsed))
            local ladder = PlaytimeLadder.define("life", {
                scope = "lifetime",
                rungs = { { at = 10, reward = { coins = 1 } } },
            })
            local state = PlaytimeLadder.begin(ladder, { elapsed = 0/0, claimed = {} })
            assert(state.elapsed == 0, "saved NaN elapsed became " .. tostring(state.elapsed))
            PlaytimeLadder.tick(ladder, state, 10, true)
            assert(state.elapsed == 10, "elapsed after a step of 10 is " .. tostring(state.elapsed))
            print('{"elapsed":true}')
        """)
        self.assertIn("elapsed", out)


if __name__ == "__main__":
    unittest.main()
