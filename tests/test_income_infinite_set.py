"""IncomeEngine.setMultiplier must refuse an infinite multiplier.

Executed as real Luau through the pinned runtime, same harness as the mined
library specs. math.huge must fail; a multiplier of 2 still makes the total 20.
"""

from __future__ import annotations

import unittest
from pathlib import Path

from rqe.luau_harness import run_or_raise

ROOT = Path(__file__).resolve().parents[1]
FORGE = ROOT / "forge/luau/Forge"


def _run(libraries: list[Path], body: str) -> str:
    return run_or_raise(ROOT, libraries=libraries, body=body).stdout


class TestIncomeInfiniteSet(unittest.TestCase):
    def test_infinite_setter_is_refused(self) -> None:
        """setMultiplier rejects math.huge, and a mul of 2 totals 20."""
        out = _run([FORGE / "Economy"], """
            local IncomeEngine = Require("IncomeEngine")
            local engine = IncomeEngine.new({ base = 10 })
            local okHuge = pcall(function()
                engine:setMultiplier("mul", math.huge)
            end)
            assert(okHuge == false, "huge setter was " .. tostring(okHuge))
            engine:setMultiplier("mul", 2)
            local total = engine:total()
            assert(total == 20, "total was " .. tostring(total))
            print('{"setter":true}')
        """)
        assert "setter" in out


if __name__ == "__main__":
    unittest.main()
