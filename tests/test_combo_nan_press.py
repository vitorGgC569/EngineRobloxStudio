"""ComboSequencer.press must refuse a timestamp that is not a time.

Executed as real Luau through the pinned runtime, same harness as the mined
library specs. NaN is not a press; a press at 0 still chains a into b.
"""

from __future__ import annotations

import unittest
from pathlib import Path

from rqe.luau_harness import run_or_raise

ROOT = Path(__file__).resolve().parents[1]
FORGE = ROOT / "forge/luau/Forge"


def _run(libraries: list[Path], body: str) -> str:
    return run_or_raise(ROOT, libraries=libraries, body=body).stdout


class TestComboNanPress(unittest.TestCase):
    def test_nan_press_is_refused(self) -> None:
        """NaN is not a press, and a press at 0 still advances a into b."""
        out = _run([FORGE / "Combat"], """
            local ComboSequencer = Require("ComboSequencer")
            local a = { name = "a", damage = 1, windup = 0, recovery = 0, nextWindow = 1 }
            local b = { name = "b", damage = 1, windup = 0, recovery = 0, nextWindow = 1 }
            local combo = ComboSequencer.new({ steps = { a, b } })
            local ok = pcall(function()
                combo:press(0 / 0)
            end)
            assert(ok == false, "nan press was accepted")
            combo:press(0)
            local nextStep = combo:advance("a", 0)
            assert(nextStep.name == "b", "advance name was " .. tostring(nextStep and nextStep.name))
            print('{"press":true}')
        """)
        assert "press" in out


if __name__ == "__main__":
    unittest.main()
