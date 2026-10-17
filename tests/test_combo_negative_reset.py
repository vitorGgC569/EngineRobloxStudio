"""ComboSequencer.new must refuse a reset window that times out at once.

Executed as real Luau through the pinned runtime, same harness as the mined
library specs. A negative timeout is not a window; 0.5 still chains a into b.
"""

from __future__ import annotations

import unittest
from pathlib import Path

from rqe.luau_harness import run_or_raise

ROOT = Path(__file__).resolve().parents[1]
FORGE = ROOT / "forge/luau/Forge"


def _run(libraries: list[Path], body: str) -> str:
    return run_or_raise(ROOT, libraries=libraries, body=body).stdout


class TestComboNegativeReset(unittest.TestCase):
    def test_negative_reset_timeout_is_refused(self) -> None:
        """-1 is not a reset window, and 0.5 still advances a into b."""
        out = _run([FORGE / "Combat"], """
            local ComboSequencer = Require("ComboSequencer")
            local a = { name = "a", damage = 1, windup = 0, recovery = 0, nextWindow = 1 }
            local b = { name = "b", damage = 1, windup = 0, recovery = 0, nextWindow = 1 }
            local ok = pcall(function()
                ComboSequencer.new({ steps = { a, b }, resetTimeout = -1 })
            end)
            assert(ok == false, "negative resetTimeout was accepted")
            local combo = ComboSequencer.new({ steps = { a, b }, resetTimeout = 0.5 })
            combo:press(0)
            local nextStep = combo:advance("a", 0)
            assert(nextStep.name == "b", "advance name was " .. tostring(nextStep and nextStep.name))
            print('{"combo":true}')
        """)
        assert "combo" in out


if __name__ == "__main__":
    unittest.main()
