"""ComboSequencer.advance must refuse a clock that is not a time.

Executed as real Luau through the pinned runtime, same harness as the mined
library specs. NaN is not a clock; a press at 0 still chains a into b.
"""

from __future__ import annotations

import unittest
from pathlib import Path

from rqe.luau_harness import run_or_raise

ROOT = Path(__file__).resolve().parents[1]
FORGE = ROOT / "forge/luau/Forge"


def _run(libraries: list[Path], body: str) -> str:
    return run_or_raise(ROOT, libraries=libraries, body=body).stdout


class TestComboNanAdvance(unittest.TestCase):
    def test_nan_advance_is_refused(self) -> None:
        """NaN is not a clock, and advance at 0 still returns b."""
        out = _run([FORGE / "Combat"], """
            local ComboSequencer = Require("ComboSequencer")
            local a = { name = "a", damage = 1, windup = 0, recovery = 0, nextWindow = 1 }
            local b = { name = "b", damage = 1, windup = 0, recovery = 0, nextWindow = 1 }
            local combo = ComboSequencer.new({ steps = { a, b } })
            local ok = pcall(function()
                combo:advance("a", 0 / 0)
            end)
            assert(ok == false, "nan advance was accepted")
            combo:press(0)
            local nextStep = combo:advance("a", 0)
            assert(nextStep.name == "b", "advance name was " .. tostring(nextStep and nextStep.name))
            print('{"advance":true}')
        """)
        assert "advance" in out


if __name__ == "__main__":
    unittest.main()
