"""A saved NaN loop count must not be restored.

Executed as real Luau through the pinned runtime. PlaytimeLadder.begin
stores restored.loops or 0. NaN is truthy, so a saved NaN loop count
is kept.
"""

from __future__ import annotations

import unittest
from pathlib import Path

from rqe.luau_harness import run_or_raise

ROOT = Path(__file__).resolve().parents[1]
FORGE = ROOT / "forge/luau/Forge"


def _run(libraries: list[Path], body: str) -> str:
    return run_or_raise(ROOT, libraries=libraries, body=body).stdout


class TestPlaytimeNanLoops(unittest.TestCase):
    def test_a_saved_nan_loop_count_becomes_zero(self) -> None:
        out = _run([FORGE / "Progression"], """
            local PlaytimeLadder = Require("PlaytimeLadder")
            local ladder = PlaytimeLadder.define("life", {
                scope = "lifetime",
                rungs = { { at = 10, reward = { coins = 1 } } },
            })
            local kept = PlaytimeLadder.begin(ladder, { elapsed = 0, loops = 3, claimed = {} })
            assert(kept.loops == 3, "saved loops became " .. tostring(kept.loops))
            local state = PlaytimeLadder.begin(ladder, { elapsed = 0, loops = 0/0, claimed = {} })
            assert(state.loops == 0, "saved NaN loops became " .. tostring(state.loops))
            print('{"loops":true}')
        """)
        self.assertIn("loops", out)


if __name__ == "__main__":
    unittest.main()
