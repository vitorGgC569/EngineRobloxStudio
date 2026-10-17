"""ComboSequencer.new must refuse a buffer that can never hold a press.

Executed as real Luau through the pinned runtime, same harness as the mined
library specs. A negative window is not a buffer; 0.2 still chains a into b.
"""

from __future__ import annotations

import unittest
from pathlib import Path

from rqe.luau_harness import run_or_raise

ROOT = Path(__file__).resolve().parents[1]
FORGE = ROOT / "forge/luau/Forge"


def _run(libraries: list[Path], body: str) -> str:
    return run_or_raise(ROOT, libraries=libraries, body=body).stdout


class TestComboNegativeBuffer(unittest.TestCase):
    def test_negative_buffer_window_is_refused(self) -> None:
        """-1 is not a buffer, and 0.2 still advances a into b."""
        out = _run([FORGE / "Combat"], """
            local ComboSequencer = Require("ComboSequencer")
            local a = { name = "a", damage = 1, windup = 0, recovery = 0, nextWindow = 1 }
            local b = { name = "b", damage = 1, windup = 0, recovery = 0, nextWindow = 1 }
            local ok = pcall(function()
                ComboSequencer.new({ steps = { a, b }, bufferWindow = -1 })
            end)
            assert(ok == false, "negative bufferWindow was accepted")
            local combo = ComboSequencer.new({ steps = { a, b }, bufferWindow = 0.2 })
            combo:press(0)
            local nextStep = combo:advance("a", 0)
            assert(nextStep.name == "b", "advance name was " .. tostring(nextStep and nextStep.name))
            print('{"buffer":true}')
        """)
        assert "buffer" in out


if __name__ == "__main__":
    unittest.main()
