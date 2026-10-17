"""A negative step must not rewind playtime already earned.

Executed as real Luau through the pinned runtime. PlaytimeLadder.tick
does state.elapsed += dt for any dt, so a player at 30 seconds can be
put back below a rung.
"""

from __future__ import annotations

import unittest
from pathlib import Path

from rqe.luau_harness import run_or_raise

ROOT = Path(__file__).resolve().parents[1]
FORGE = ROOT / "forge/luau/Forge"


def _run(libraries: list[Path], body: str) -> str:
    return run_or_raise(ROOT, libraries=libraries, body=body).stdout


class TestPlaytimeNegative(unittest.TestCase):
    def test_a_negative_step_does_not_rewind_elapsed(self) -> None:
        out = _run([FORGE / "Progression"], """
            local PlaytimeLadder = Require("PlaytimeLadder")
            local ladder = PlaytimeLadder.define("shift", {
                rungs = { { at = 10, reward = { coins = 1 } } },
            })
            local state = PlaytimeLadder.begin(ladder)
            local credited = PlaytimeLadder.tick(ladder, state, 30, true)
            assert(credited == 30, "a step of 30 credited " .. tostring(credited))
            assert(state.elapsed == 30, "elapsed after 30 is " .. tostring(state.elapsed))
            local rewound = PlaytimeLadder.tick(ladder, state, -100, true)
            assert(state.elapsed == 30, "elapsed became " .. tostring(state.elapsed))
            assert(rewound == 0, "a negative step credited " .. tostring(rewound))
            print('{"playtime":true}')
        """)
        self.assertIn("playtime", out)


if __name__ == "__main__":
    unittest.main()
